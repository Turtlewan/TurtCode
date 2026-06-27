#!/usr/bin/env node
/**
 * PreToolUse Hook: Destructive-Command Hard-Block
 *
 * Hard-blocks never-list destructive commands when running in coding mode
 * (DeepSeek backend). Returns `permissionDecision: deny` on EVERY attempt
 * for the never-list — no retry path, no fact-checklist, no model compliance
 * required. This guards the model least likely to honor prose hard-blocks.
 *
 * Never-list:
 *   - git push targeting main/master (any force variant)
 *   - git push --force (NOT --force-with-lease)
 *   - DROP TABLE / TRUNCATE / DELETE FROM (bare SQL)
 *   - rm -rf
 *   - git commit --no-verify / --amend
 *   - git reset --hard
 *   - git clean -f
 *   - git checkout -- (destructive checkout)
 *   - git rm -r (recursive rm via git)
 *   - git switch --discard-changes / --force / -C
 *
 * Detection functions lifted from ECC gateguard-fact-force.js (MIT).
 * State/speed-bump machinery discarded — this is a pure hard-block.
 *
 * Gates:
 *   - Coding-mode only: no-op unless ANTHROPIC_BASE_URL contains "deepseek" (archived)
 *     OR APEX_MODE=coding (the live Claude coding mode — Codex/Opus coder, ADR-027)
 *   - Recovery hatch: APEX_DESTRUCT_GUARD=off disables the guard
 *
 * Contract: reads PreToolUse JSON from stdin; writes deny decision JSON
 * to stdout on match; exits 0 either way.
 */

'use strict';

// ── SQL destroy patterns (stable regex) ──────────────────────────────
// Quoted strings are stripped before this regex runs so a commit message
// mentioning "drop table" does NOT trigger a false positive.
const DESTRUCTIVE_SQL_DD = /\b(drop\s+table|delete\s+from|truncate|dd\s+if=)\b/i;

// ── Detection functions (lifted from ECC gateguard-fact-force.js) ────

/**
 * Strip the contents of single- and double-quoted strings so phrases
 * mentioned inside a commit message or echoed argument do not trigger
 * the destructive detector.
 *
 * @param {string} input
 * @returns {string}
 */
function stripQuotedStrings(input) {
  return input
    .replace(/'(?:[^'\\]|\\.)*'/g, "''")
    .replace(/"(?:[^"\\]|\\.)*"/g, '""');
}

/**
 * Promote subshell delimiters to top-level segment separators so the
 * destructive check applies inside `$(...)` and backtick subshells.
 * Run iteratively to handle a layer of nesting.
 *
 * @param {string} input
 * @returns {string}
 */
function explodeSubshells(input) {
  let out = input;
  for (let i = 0; i < 4; i += 1) {
    const before = out;
    out = out.replace(/\$\(([^()`]*)\)/g, ';$1;');
    out = out.replace(/`([^`]*)`/g, ';$1;');
    if (out === before) break;
  }
  return out;
}

/**
 * Split a command line into top-level segments at unquoted shell
 * separators (`;`, `|`, `&`, `&&`, `||`) and across subshells
 * (`$(...)` / backticks). Quoted strings are stripped first so
 * separators inside quotes are not split on. Per-segment comments
 * are also stripped.
 *
 * @param {string} input
 * @returns {string[]}
 */
function splitCommandSegments(input) {
  const stripped = explodeSubshells(stripQuotedStrings(input));
  return stripped
    .split(/[;|&]+/)
    .map(function(segment) { return segment.replace(/(^|\s)#.*/, '$1').trim(); })
    .filter(Boolean);
}

/**
 * Tokenize a single command segment by whitespace. Quoted strings
 * are already collapsed to empty quotes by stripQuotedStrings, so
 * naive whitespace splitting is sufficient.
 *
 * @param {string} segment
 * @returns {string[]}
 */
function tokenize(segment) {
  return segment.split(/\s+/).filter(Boolean);
}

/**
 * Tokenize a short allowlisted shell command while preserving quoted
 * arguments. Only used for read-only git introspection commands.
 *
 * @param {string} input
 * @returns {string[] | null}
 */
function tokenizeAllowlistedShellWords(input) {
  var tokens = [];
  var current = '';
  var quote = null;
  var escaped = false;

  for (var ci = 0; ci < String(input || '').length; ci++) {
    var char = String(input || '')[ci];

    if (escaped) {
      current += char;
      escaped = false;
      continue;
    }

    if (char === '\\') {
      escaped = true;
      continue;
    }

    if (quote) {
      if (char === quote) {
        quote = null;
      } else {
        current += char;
      }
      continue;
    }

    if (char === '"' || char === "'") {
      quote = char;
      continue;
    }

    if (/\s/.test(char)) {
      if (current) {
        tokens.push(current);
        current = '';
      }
      continue;
    }

    current += char;
  }

  if (escaped) current += '\\';
  if (quote) return null;
  if (current) tokens.push(current);
  return tokens;
}

/**
 * Strip a leading path and trailing `.exe` from a command token so
 * `/usr/bin/git`, `git.exe`, and `GIT` all normalize to `git`.
 *
 * @param {string} token
 * @returns {string}
 */
function commandBasename(token) {
  if (!token) return '';
  return token.replace(/^.*[\\/]/, '').replace(/\.exe$/i, '').toLowerCase();
}

/**
 * Detect `rm` invocations that recursively force-delete files. Handles
 * combined (`-rf`, `-fr`, `-Rf`) and split (`-r -f`) flag forms.
 *
 * @param {string[]} tokens
 * @returns {boolean}
 */
function isDestructiveRm(tokens) {
  if (tokens.length === 0 || commandBasename(tokens[0]) !== 'rm') return false;
  var hasR = false;
  var hasF = false;
  for (var ti = 1; ti < tokens.length; ti++) {
    var t = tokens[ti];
    if (t === '--recursive') { hasR = true; continue; }
    if (t === '--force') { hasF = true; continue; }
    if (!t.startsWith('-') || t.startsWith('--')) continue;
    var body = t.slice(1);
    if (/[rR]/.test(body)) hasR = true;
    if (/f/.test(body)) hasF = true;
  }
  return hasR && hasF;
}

/**
 * Locate the git subcommand within a token list, skipping over git's
 * global options like `-c key=value`, `-C <path>`, `--git-dir=...`,
 * `--work-tree=...`, `--namespace=...`, `--super-prefix=...`.
 *
 * @param {string[]} tokens
 * @returns {{ command: string, rest: string[] } | null}
 */
function findGitSubcommand(tokens) {
  if (tokens.length === 0 || commandBasename(tokens[0]) !== 'git') return null;
  var valueConsumingShort = new Set(['-c', '-C']);
  var valueConsumingLong = new Set(['--git-dir', '--work-tree', '--namespace', '--super-prefix']);
  var i = 1;
  while (i < tokens.length) {
    var t = tokens[i];
    if (valueConsumingShort.has(t) || valueConsumingLong.has(t)) {
      i += 2;
      continue;
    }
    if (t.startsWith('--git-dir=') || t.startsWith('--work-tree=') || t.startsWith('--namespace=') || t.startsWith('--super-prefix=')) {
      i += 1;
      continue;
    }
    if (t.startsWith('-')) {
      i += 1;
      continue;
    }
    return { command: t.toLowerCase(), rest: tokens.slice(i + 1) };
  }
  return null;
}

/**
 * Detect destructive git invocations. Extends ECC's gateguard detection
 * with push-to-main/master refspec checking and --no-verify flag.
 *
 * @param {string[]} tokens
 * @returns {boolean}
 */
function isDestructiveGit(tokens) {
  var sub = findGitSubcommand(tokens);
  if (!sub) return false;
  var command = sub.command;
  var rest = sub.rest;

  if (command === 'reset') {
    return rest.indexOf('--hard') >= 0;
  }

  if (command === 'checkout') {
    return rest.indexOf('--') >= 0;
  }

  if (command === 'clean') {
    return rest.some(function(t) {
      if (t === '--force') return true;
      if (!t.startsWith('-') || t.startsWith('--')) return false;
      return t.slice(1).indexOf('f') >= 0;
    });
  }

  if (command === 'push') {
    var withLease = false;
    var bareForce = false;
    var plusRefspecForce = false;
    var mainOrMaster = false;

    for (var ri = 0; ri < rest.length; ri++) {
      var t = rest[ri];
      if (t === '--force-with-lease' || t.startsWith('--force-with-lease=')) {
        withLease = true;
      } else if (t === '--force' || t.startsWith('--force=')) {
        bareForce = true;
      } else if (t.startsWith('-') && !t.startsWith('--') && t.slice(1).indexOf('f') >= 0) {
        bareForce = true;
      } else if (t.startsWith('+') && t.length > 1 && /^\+(?:[a-zA-Z_/.:]|HEAD)/.test(t)) {
        // Force-push refspec prefix (e.g. +main, +HEAD:branch)
        plusRefspecForce = true;
        // Also check if the refspec targets main/master
        var refNoPlus = t.slice(1);
        var ci = refNoPlus.indexOf(':');
        var dst = ci >= 0 ? refNoPlus.slice(ci + 1) : refNoPlus;
        if (dst === 'main' || dst === 'master') mainOrMaster = true;
      } else if (!t.startsWith('-')) {
        // Plain refspec — check if it targets main or master
        var colonIdx = t.indexOf(':');
        var target = colonIdx >= 0 ? t.slice(colonIdx + 1) : t;
        if (target === 'main' || target === 'master') {
          mainOrMaster = true;
        }
      }
    }

    var isForcePush = bareForce || (plusRefspecForce && !withLease);
    return isForcePush || mainOrMaster;
  }

  if (command === 'commit') {
    return rest.indexOf('--amend') >= 0 || rest.indexOf('--no-verify') >= 0;
  }

  if (command === 'rm') {
    var hasR = false;
    for (var rmi = 0; rmi < rest.length; rmi++) {
      var rmt = rest[rmi];
      if (!rmt.startsWith('-') || rmt.startsWith('--')) continue;
      if (/[rR]/.test(rmt.slice(1))) hasR = true;
    }
    return hasR;
  }

  if (command === 'switch') {
    return rest.some(function(t) {
      if (t === '--discard-changes' || t === '--force') return true;
      if (!t.startsWith('-') || t.startsWith('--')) return false;
      var body = t.slice(1);
      return /[fC]/.test(body);
    });
  }

  return false;
}

/**
 * Decide whether a bash command line contains a destructive action
 * the guard should hard-block.
 *
 * @param {string} command
 * @returns {boolean}
 */
function isDestructiveBash(command) {
  var raw = String(command || '');

  // Check SQL/DELETE patterns on quote-stripped, subshell-flattened input
  var flattened = explodeSubshells(stripQuotedStrings(raw));
  if (DESTRUCTIVE_SQL_DD.test(flattened)) return true;

  // Split into segments and check each for destructive rm/git commands
  var segments = splitCommandSegments(raw);
  for (var si = 0; si < segments.length; si++) {
    var segment = segments[si];
    // Re-check SQL patterns per-segment (catches across split boundaries)
    if (DESTRUCTIVE_SQL_DD.test(stripQuotedStrings(segment))) return true;
    var tokens = tokenize(segment);
    if (isDestructiveRm(tokens)) return true;
    if (isDestructiveGit(tokens)) return true;
  }
  return false;
}

/**
 * Allowlist for read-only git introspection commands that must
 * never be blocked. Rejects commands with shell control characters.
 *
 * @param {string} command
 * @returns {boolean}
 */
function isReadOnlyGitIntrospection(command) {
  var trimmed = String(command || '').trim();
  if (!trimmed || /[\r\n;&|><`$()]/.test(trimmed)) {
    return false;
  }

  var segments = splitCommandSegments(trimmed);
  if (segments.length !== 1) {
    return false;
  }

  var tokens = tokenizeAllowlistedShellWords(trimmed);
  if (!tokens) {
    return false;
  }
  if (commandBasename(tokens[0]) !== 'git' || tokens.length < 2) {
    return false;
  }

  var subcommand = tokens[1].toLowerCase();
  var args = tokens.slice(2);

  if (subcommand === 'status') {
    return args.every(function(arg) { return ['--porcelain', '--short', '--branch'].indexOf(arg) >= 0; });
  }

  if (subcommand === 'diff') {
    return args.length <= 1 && args.every(function(arg) { return ['--name-only', '--name-status'].indexOf(arg) >= 0; });
  }

  if (subcommand === 'log') {
    return args.every(function(arg) { return arg === '--oneline' || /^--max-count=\d+$/.test(arg); });
  }

  if (subcommand === 'show') {
    return args.length === 1 && !args[0].startsWith('--') && /^[a-zA-Z0-9._:\/ -]+$/.test(args[0]);
  }

  if (subcommand === 'branch') {
    return args.length === 1 && args[0] === '--show-current';
  }

  if (subcommand === 'rev-parse') {
    return args.length === 2 && args[0] === '--abbrev-ref' && /^head$/i.test(args[1]);
  }

  return false;
}

// ── Main handler ─────────────────────────────────────────────────────

var input = '';
var stdinTimeout = setTimeout(function() { process.exit(0); }, 3000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', function(chunk) { input += chunk; });
process.stdin.on('end', function() {
  clearTimeout(stdinTimeout);

  try {
    var data = JSON.parse(input);
    var result = handlePreToolUse(data);
    if (result) {
      process.stdout.write(JSON.stringify(result));
    }
  } catch (_) {
    // Parse error or unexpected input — allow the tool call
  }

  process.exit(0);
});

/**
 * Main decision logic for the PreToolUse hook.
 *
 * @param {object} data - Parsed JSON from stdin (the tool call payload)
 * @returns {object|null} null to allow; { hookSpecificOutput: {...} } to deny
 */
function handlePreToolUse(data) {
  // ── Recovery hatch ──────────────────────────────────────────────
  var disableVal = String(process.env.APEX_DESTRUCT_GUARD || '').trim().toLowerCase();
  if (disableVal === '0' || disableVal === 'false' || disableVal === 'off' || disableVal === 'disabled') {
    return null;
  }

  // ── Coding-mode gate: fire in a coding session — DeepSeek (archived, ADR-027) OR
  //    Claude coding mode (APEX_MODE=coding, where the Codex/Opus coder now runs). Without the
  //    APEX_MODE branch the floor was inert after the ADR-027 move off DeepSeek. ────
  var baseUrl = String(process.env.ANTHROPIC_BASE_URL || '');
  var codingMode = baseUrl.indexOf('deepseek') >= 0 ||
    String(process.env.APEX_MODE || '').toLowerCase() === 'coding';
  if (!codingMode) {
    return null;
  }

  // ── Only guard Bash tool calls ──────────────────────────────────
  if (data.tool_name !== 'Bash') {
    return null;
  }

  var command = (data.tool_input && data.tool_input.command) || '';
  if (!command) {
    return null;
  }

  // ── Allow read-only git introspection ───────────────────────────
  if (isReadOnlyGitIntrospection(command)) {
    return null;
  }

  // ── Check for destructive commands ──────────────────────────────
  if (isDestructiveBash(command)) {
    return {
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: 'This command is on the APEX destructive-command never-list and is blocked in coding mode. If you need to run it deliberately, restart with APEX_DESTRUCT_GUARD=off set in the environment.'
      }
    };
  }

  // ── Allow all other commands ────────────────────────────────────
  return null;
}
