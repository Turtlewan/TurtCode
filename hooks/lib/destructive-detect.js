'use strict';

const DESTRUCTIVE_SQL_DD = /\b(drop\s+(table|schema|database)|delete\s+from|truncate|dd\s+if=)\b/i;

// Heads that only READ. A destructive-looking string in their arguments is data, not an action --
// `grep "<sql>" migrations/` must not be blocked. Anything NOT on this list gets its RAW
// (quotes-intact) command tested against DESTRUCTIVE_SQL_DD. See isDestructiveBash.
const READONLY_HEADS = new Set([
  'grep', 'rg', 'ag', 'cat', 'bat', 'less', 'more', 'head', 'tail', 'echo', 'printf',
  'find', 'ls', 'dir', 'wc', 'diff', 'awk', 'jq', 'git', 'type', 'get-content', 'select-string'
]);

function stripQuotedStrings(input) {
  return input
    .replace(/'(?:[^'\\]|\\.)*'/g, "''")
    .replace(/"(?:[^"\\]|\\.)*"/g, '""');
}

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

function splitCommandSegments(input) {
  const stripped = explodeSubshells(stripQuotedStrings(input));
  return stripped
    .split(/[;|&]+/)
    .map(function(segment) { return segment.replace(/(^|\s)#.*/, '$1').trim(); })
    .filter(Boolean);
}

function tokenize(segment) {
  return segment.split(/\s+/).filter(Boolean);
}

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

function commandBasename(token) {
  if (!token) return '';
  return token.replace(/^.*[\\/]/, '').replace(/\.exe$/i, '').toLowerCase();
}

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

function isDestructiveGit(tokens) {
  var sub = findGitSubcommand(tokens);
  if (!sub) return false;
  var command = sub.command;
  var rest = sub.rest;

  // Declared permanent hard blocks in apex-governance that this guard did not actually enforce
  // until 2026-07-14. They were prose, not mechanism.
  if (command === 'merge') {
    // `git merge --abort` / `--quit` are recovery, not a merge.
    return rest.indexOf('--abort') < 0 && rest.indexOf('--quit') < 0;
  }

  if (command === 'branch') {
    return rest.some(function(t) {
      return t === '-d' || t === '-D' || t === '--delete' || t === '-dr' || t === '-Dr';
    });
  }

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
        var refNoPlus = t.slice(1);
        var ci = refNoPlus.indexOf(':');
        var dst = ci >= 0 ? refNoPlus.slice(ci + 1) : refNoPlus;
        if (dst === 'main' || dst === 'master') mainOrMaster = true;
      } else if (!t.startsWith('-')) {
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

function isDestructiveBash(command) {
  var raw = String(command || '');
  var flattened = explodeSubshells(stripQuotedStrings(raw));
  if (DESTRUCTIVE_SQL_DD.test(flattened)) return true;

  var segments = splitCommandSegments(raw);
  for (var si = 0; si < segments.length; si++) {
    var segment = segments[si];
    if (DESTRUCTIVE_SQL_DD.test(stripQuotedStrings(segment))) return true;

    var tokens = tokenize(segment);
    if (isDestructiveRm(tokens)) return true;
    if (isDestructiveGit(tokens)) return true;
  }

  // Quoted-SQL check, on the RAW command.
  //
  // This guard was dead until 2026-07-14. DESTRUCTIVE_SQL_DD was only ever tested against
  // stripQuotedStrings(...) output -- and splitCommandSegments() strips quotes before it segments --
  // so `psql -c "<statement>"`, which is how every SQL client is actually invoked, was never seen.
  // apex-governance declared these permanent hard blocks; the mechanism enforced none of them.
  //
  // Gate on the command heads so that READING about a statement stays legal (`grep`, `cat`, `echo`,
  // `git log -S`). If any head could actually execute it, test the raw string.
  var executes = segments.some(function(seg) {
    var tk = tokenize(seg);
    return tk.length > 0 && !READONLY_HEADS.has(commandBasename(tk[0]));
  });
  if (executes && DESTRUCTIVE_SQL_DD.test(raw)) return true;

  return false;
}

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

function isNetworkCommand(tokens) {
  var head = commandBasename(tokens[0]);
  return head === 'curl' || head === 'wget' || head === 'iwr' || head === 'irm' ||
    head === 'invoke-webrequest' || head === 'invoke-restmethod';
}

function hasUploadOrBodyFlag(tokens) {
  for (var ti = 1; ti < tokens.length; ti++) {
    var token = String(tokens[ti] || '').toLowerCase();
    var next = String(tokens[ti + 1] || '').toLowerCase();

    if (token === '-t' || token === '-f' || token === '-d' ||
        token.indexOf('-t') === 0 || token.indexOf('-f') === 0 || token.indexOf('-d') === 0 ||
        token === '--upload-file' || token.indexOf('--upload-file=') === 0 ||
        token === '--data' || token.indexOf('--data') === 0 ||
        token === '-body' || token.indexOf('-body:') === 0 ||
        token === '-infile' || token.indexOf('-infile:') === 0) {
      return true;
    }

    if (token === '-x' && (next === 'post' || next === 'put')) return true;
    if (/^-x(?:post|put)$/.test(token)) return true;
    if (token === '-method' && (next === 'post' || next === 'put')) return true;
    if (/^-method:(?:post|put)$/.test(token)) return true;
  }
  return false;
}

function isSecretRead(substitution) {
  return /\b(?:cat|type|get-content)\b[^\r\n;|&]*(?:\.env\b|(?:secret|credential)[^\s;|&]*)/i.test(substitution);
}

function hasSecretCommandSubstitution(command) {
  var raw = String(command || '');
  var substitution = /\$\(([^)]*)\)|\x60([^\x60]*)\x60/g;
  var match;
  while ((match = substitution.exec(raw))) {
    if (isSecretRead(match[1] || match[2] || '')) return true;
  }
  return false;
}

function isExfiltrationBash(command) {
  var raw = String(command || '');
  var segments = splitCommandSegments(raw);
  var hasSecretSubstitution = hasSecretCommandSubstitution(raw);
  for (var si = 0; si < segments.length; si++) {
    var segment = segments[si];
    var tokens = tokenize(segment);
    if (!isNetworkCommand(tokens)) continue;
    if (hasUploadOrBodyFlag(tokens) || hasSecretSubstitution) {
      return true;
    }
  }
  return false;
}

function isRemoteCodeExec(command) {
  var flattened = explodeSubshells(stripQuotedStrings(String(command || '')));
  return /(?:^|[;|&\s])(?:[^\s;|&]*[\\/])?(?:curl|wget|iwr|irm|invoke-[a-z0-9-]+)(?:\.exe)?\b[^;|&]*\|\s*(?:[^\s;|&]*[\\/])?(?:bash|sh|zsh|pwsh|powershell|iex|invoke-expression|node|python)(?:\.exe)?\b/i.test(flattened);
}

// The AFK-only helpers (isAfkTarget / isCriticalPath / isAfkFlagWrite / SAFE_AFK_COMMANDS /
// isSafeAfkBash and their private support functions) were removed 2026-07-14.
//
// They existed solely for the `!afk` permission gate, which was reverted (ADR-033 Reversal) --
// after that, nothing called them. isCriticalPath also carried a real bug: it substring-matched
// "auth" inside "author", so any path containing the word "author" was treated as auth code.
// Dead code in a safety library is worse than no code: it looks like a control and enforces
// nothing. The two checks worth keeping -- isExfiltrationBash and isRemoteCodeExec -- were
// stranded in here too, reachable only from isSafeAfkBash; they are now wired into the live
// destructive-command-guard.

module.exports = {
  isDestructiveBash: isDestructiveBash,
  isReadOnlyGitIntrospection: isReadOnlyGitIntrospection,
  isExfiltrationBash: isExfiltrationBash,
  isRemoteCodeExec: isRemoteCodeExec,
  // Shared shell-parsing primitives. Exported so a second guard does not grow a fourth private
  // copy of quote/segment handling -- divergent copies are how the SQL never-list ended up
  // testing against the wrong side of the quote-stripping and never matching a single statement.
  splitCommandSegments: splitCommandSegments,
  tokenize: tokenize,
  commandBasename: commandBasename
};
