#!/usr/bin/env node
/**
 * PreToolUse Hook: Raw `codex exec` Hard-Block
 *
 * Forces every Codex dispatch through codex-dispatch.ps1. Contract: reads PreToolUse JSON from
 * stdin; writes a deny decision to stdout on match; exits 0 either way.
 *
 * ── Why this exists (2026-07-14) ──────────────────────────────────────────────────────────────
 * codex-dispatch.ps1 carries the ledger, the no-output watchdog, the scope check, `-Adopt`, and
 * (since today) the rule that the coder's own `.final` report — not the exit code — is the verdict.
 * All of it was written, tested, and then bypassed: THREE consecutive real builds dispatched with
 * a raw `codex exec`, and the ledger sat frozen while they ran.
 *
 * The bill came due on cap-deps-1b. The host's Bash call hit its own 10-minute ceiling and died
 * (exit 143 = SIGTERM). `codex exec` is not in that call's process group, so it kept running — and
 * kept WRITING — for another 3.5 minutes. The host read "my call died" as "the coder died",
 * announced a crash that never happened, and moved to recovery on a tree with a live writer on it.
 * Codex then reported `status: blocked` — it could not inspect, lint, or test what it had written —
 * and that report was never read. The code was committed, and the next spec was built on top of it.
 *
 * Every one of those failures has a mechanism in the wrapper that would have caught it: the
 * watchdog bounds the run so no arbitrary Bash timeout has to; `-Adopt` reports a LIVE run instead
 * of handing back a half-written tree; the ledger makes a running dispatch observable at all; the
 * `.final` read turns `blocked` into a hard stop. None of them fired, because none of them ran.
 *
 * apex-code has said "dispatch through the wrapper" in prose for weeks. Prose lost, three times.
 * This is rule 2 of the Iron Law — make it structurally impossible — and it is the same lesson
 * session 70 wrote down and then didn't apply: MECHANISM BEATS INSTRUCTION, including when you are
 * the one writing the instruction.
 * ──────────────────────────────────────────────────────────────────────────────────────────────
 */

'use strict';

var detection = require('./lib/destructive-detect');
var splitCommandSegments = detection.splitCommandSegments;
var tokenize = detection.tokenize;
var commandBasename = detection.commandBasename;

var input = '';
var stdinTimeout = setTimeout(function() { process.exit(0); }, 3000);
process.stdin.setEncoding('utf8');
process.stdin.on('data', function(chunk) { input += chunk; });
process.stdin.on('end', function() {
  clearTimeout(stdinTimeout);

  var data;
  try {
    data = JSON.parse(input);
  } catch (e) {
    process.exit(0);
  }

  var decision = handlePreToolUse(data);
  if (decision) {
    process.stdout.write(JSON.stringify(decision));
  }
  process.exit(0);
});

function deny(reason) {
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason: reason
    }
  };
}

/**
 * A raw dispatch is `codex` invoked with the `exec` subcommand IN COMMAND POSITION.
 *
 * Matching on command position rather than on the substring "codex exec" is the whole trick. A
 * substring match blocks `git commit -m "run codex exec via the wrapper"` and `grep -rn "codex
 * exec" docs/` — and a guard that blocks the commit describing it is a guard that gets switched
 * off. That defect is already on record for the destructive guard, which trips on its own commit
 * messages.
 *
 * THERE IS DELIBERATELY NO WRAPPER EXEMPTION. The first version exempted any command containing
 * the string "codex-dispatch.ps1" — so `codex exec --help # codex-dispatch.ps1` sailed through:
 * a SHELL COMMENT naming the wrapper disarmed the guard. The exemption was never needed, either.
 * The wrapper spawns Codex from inside PowerShell via CreateProcess; that child never passes
 * through this hook, and `powershell -File codex-dispatch.ps1 ...` contains no `codex exec` tokens
 * to match. An exemption that is unnecessary and bypassable should simply not exist.
 */

// Runners that PREFIX a real command without changing it: `npx codex exec`, `env FOO=1 codex exec`.
// NOTE: npm/pnpm/yarn are deliberately NOT here. They take a SUBCOMMAND (`yarn exec codex exec`), so
// treating them as transparent prefixes consumed only the runner token and left `exec` in command
// position -- detection stopped there and the invocation was allowed. They belong to PACKAGE_RUNNERS.
// npx/bunx ARE transparent: `npx codex exec` runs codex directly.
var TRANSPARENT_RUNNERS = /^(?:npx|bunx|env|xargs|nohup|time|command|sudo|doas|start|winpty)$/;

// These take a COMMAND STRING as an argument -- `iex 'codex exec'`. Listing them as transparent
// prefixes meant the guard skipped the runner and then looked at the QUOTED STRING as if it were an
// executable, found no match, and allowed it. Their argument must be re-parsed as a command.
var STRING_EVALUATORS = /^(?:iex|invoke-expression)$/;

// Launchers: the command they run is an ARGUMENT. `Start-Process codex exec` and its explicit
// spelling `Start-Process -FilePath codex -ArgumentList exec` both launch a raw dispatch.
var PROCESS_LAUNCHERS = /^(?:start-process|saps)$/;

// `npm exec -- codex exec` / `npm exec codex exec`: npm's OWN `exec` subcommand sits in command
// position, so skipping only the `npm` token stopped detection dead at `exec`.
var PACKAGE_RUNNERS = /^(?:npm|pnpm|yarn)$/;

// Options belonging to a transparent runner, not to the command it runs: `npx --yes codex exec`,
// `cmd /c start /b codex exec`. Skipping only the runner token left its flags in command position,
// so the codex token was never first and the whole invocation slipped through.
var RUNNER_OPTIONS = /^(?:-{1,2}[A-Za-z0-9][^\s]*|\/[A-Za-z])$/;

// Shells that carry their payload as a STRING argument: `powershell -c "codex exec ..."`.
// Their payload must be re-parsed, or the guard is trivially bypassed by one layer of quoting.
var NESTED_SHELLS = /^(?:powershell|pwsh|cmd|sh|bash|zsh|dash|wsl)$/;

var SHELL_PAYLOAD_FLAG = /^(?:-c|\/c|\/k|-Command|-EncodedCommand|-e)$/i;

function isCodexExe(exe) {
  return /^codex(?:\.js|\.cmd|\.ps1)?$/.test(exe);
}

/** Does one already-tokenized command invoke codex with the `exec` subcommand? */
function tokensAreCodexExec(tokens, depth) {
  var i = 0;

  // Strip leading env assignments, the PowerShell call operator (`& "codex" exec`), and any
  // transparent runner (`npx codex exec`, `env FOO=1 codex exec`). Loop: they can stack.
  for (;;) {
    while (i < tokens.length &&
           (/^[A-Za-z_][A-Za-z0-9_]*=/.test(tokens[i]) || tokens[i] === '&' || tokens[i] === '&&')) {
      i += 1;
    }
    if (i < tokens.length && TRANSPARENT_RUNNERS.test(commandBasename(tokens[i]))) {
      i += 1;
      // Skip the runner's OWN options too: `npx --yes codex exec`, `start /b codex exec`.
      while (i < tokens.length && RUNNER_OPTIONS.test(tokens[i])) { i += 1; }
      continue;
    }
    break;
  }
  if (i >= tokens.length) return false;

  var exe = commandBasename(tokens[i]);
  var rest = tokens.slice(i + 1);

  // `Start-Process codex exec` -- skip the cmdlet's own parameter NAMES (-FilePath, -ArgumentList,
  // -NoNewWindow ...) and re-read what remains as a command.
  if (PROCESS_LAUNCHERS.test(exe) && depth < 3) {
    var launched = [];
    for (var q = 0; q < rest.length; q += 1) {
      if (/^-/.test(rest[q])) continue;          // a parameter name, not the command
      launched.push(rest[q]);
    }
    if (launched.length && tokensAreCodexExec(launched, depth + 1)) return true;
    return false;
  }

  // `iex 'codex exec'` -- the argument IS a command. Re-parse it.
  if (STRING_EVALUATORS.test(exe) && depth < 3) {
    for (var v = 0; v < rest.length; v += 1) {
      if (isRawCodexExec(rest[v], depth + 1)) return true;
    }
    return false;
  }

  // `npm exec -- codex exec ...` -- skip npm's own subcommand and the `--` separator, then re-parse.
  if (PACKAGE_RUNNERS.test(exe) && depth < 3) {
    var w = 0;
    while (w < rest.length && (rest[w] === 'exec' || rest[w] === 'run' || rest[w] === '--' ||
                               RUNNER_OPTIONS.test(rest[w]))) { w += 1; }
    if (w < rest.length && tokensAreCodexExec(rest.slice(w), depth + 1)) return true;
    return false;
  }

  // `node .../@openai/codex/bin/codex.js exec` — how the npm install is really invoked, and how
  // the wrapper itself resolves it.
  if (/^node$/.test(exe)) {
    for (var j = 0; j < rest.length; j += 1) {
      if (/^codex\.js$/.test(commandBasename(rest[j]))) {
        return hasBareExec(rest.slice(j + 1));
      }
    }
    return false;
  }

  // A nested shell carries the real command in its argument: `cmd /c codex exec ...` (unquoted) or
  // `powershell -c "codex exec ..."` (quoted — handled by the quoted-payload recursion below).
  if (NESTED_SHELLS.test(exe) && depth < 3) {
    for (var k = 0; k < rest.length; k += 1) {
      if (SHELL_PAYLOAD_FLAG.test(rest[k])) {
        if (tokensAreCodexExec(rest.slice(k + 1), depth + 1)) return true;
      }
    }
    // `wsl codex exec --json` takes its command DIRECTLY, with no payload flag at all — so a scan
    // that only looked after `-c`/`/c` found nothing and allowed it. Re-parse the remaining tokens
    // as a command, skipping wsl's own options (`wsl -d Ubuntu -u root -- codex exec`).
    var m = 0;
    while (m < rest.length && (RUNNER_OPTIONS.test(rest[m]) || rest[m] === '--')) {
      // Options that take a VALUE must consume it, or the value lands in command position and
      // parsing stops there: `wsl --distribution Ubuntu -- codex exec` stopped at `Ubuntu`. The
      // long forms were missed because only `-d`/`-u` were handled -- and `--distribution` is what
      // a normal Windows user actually types.
      if (/^(?:-d|-u|-e|--distribution|--user|--exec|--cd|--shell-type)$/i.test(rest[m]) && m + 1 < rest.length) {
        m += 1;
      }
      m += 1;
    }
    if (m < rest.length && tokensAreCodexExec(rest.slice(m), depth + 1)) return true;
    return false;
  }

  if (!isCodexExe(exe)) return false;
  return hasBareExec(rest);
}

/** `exec` must appear as a bare subcommand token, never as a flag's value. */
function hasBareExec(tokens) {
  for (var i = 0; i < tokens.length; i += 1) {
    if (tokens[i] === 'exec') return true;
  }
  return false;
}

/** Quoted strings in the RAW command — a nested shell's payload lives here. */
function extractQuotedPayloads(raw) {
  var out = [];
  var re = /'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)"/g;
  var m;
  while ((m = re.exec(raw)) !== null) {
    out.push(m[1] !== undefined ? m[1] : m[2]);
  }
  return out;
}

/** Does the raw command invoke a shell that could be carrying a quoted payload? */
function mentionsNestedShell(raw) {
  var segments = splitCommandSegments(raw);
  for (var i = 0; i < segments.length; i += 1) {
    var tokens = tokenize(segments[i]);
    for (var j = 0; j < tokens.length; j += 1) {
      if (NESTED_SHELLS.test(commandBasename(tokens[j]))) return true;
    }
  }
  return false;
}

/**
 * Split into segments of TOKENS, quote-aware.
 *
 * The shared splitCommandSegments() BLANKS quoted content ("" / ''), which loses a quoted
 * executable (`& "codex" exec`). The obvious patch -- strip all quote characters and re-parse --
 * is much worse, and it fired immediately: it promotes quoted DATA into command position, so a test
 * file, a commit message or a doc containing `'npx --yes codex exec'` as an example gets blocked.
 * (It blocked the very command that was adding these test cases.)
 *
 * Doing it properly: track quote state, keep each quoted run INSIDE its own token, and strip the
 * quotes from that token afterwards. Then `& "codex" exec` yields the token `codex` in command
 * position, while `grep -rn "codex exec" docs/` yields ONE token `codex exec` as grep's argument --
 * which can never be a command. Both halves fall out of the same rule.
 */
function tokenizeSegments(raw) {
  var segments = [];
  var tokens = [];
  var current = '';
  var quote = null;
  var hadQuote = false;

  function endToken() {
    if (current.length || hadQuote) { tokens.push(current); }
    current = '';
    hadQuote = false;
  }
  function endSegment() {
    endToken();
    if (tokens.length) segments.push(tokens);
    tokens = [];
  }

  for (var i = 0; i < raw.length; i += 1) {
    var ch = raw[i];

    if (quote) {
      // Only \" is an escape. Treating EVERY backslash as an escape ate the separators in a Windows
      // path, so `& "C:\Users\...\codex.cmd" exec` tokenized to `C:Users...codex.cmd` and
      // commandBasename never saw `codex.cmd`. A quoted Windows path is the most normal thing a user
      // could type here, and it walked straight past the guard.
      if (ch === '\\' && raw[i + 1] === '"') { current += '"'; i += 1; continue; }
      if (ch === quote) { quote = null; continue; }
      current += ch;
      continue;
    }

    if (ch === '"' || ch === "'") { quote = ch; hadQuote = true; continue; }
    if (ch === '#') { while (i < raw.length && raw[i] !== '\n') { i += 1; } endToken(); continue; }
    // A PowerShell SCRIPTBLOCK is a command carrier: `Start-Job { codex exec }`,
    // `Invoke-Command -ScriptBlock { codex exec }`, `1..3 | % { codex exec }`. Braces did not end a
    // segment, so the block's contents never reached a first-token check and the whole thing was
    // allowed -- and backgrounding a raw dispatch with Start-Job is precisely the lost-wrapper
    // failure this hook exists to prevent.
    if (ch === '{' || ch === '}') { endSegment(); continue; }
    if (ch === ';' || ch === '|' || ch === '&' || ch === '\n' || ch === '(' || ch === ')') { endSegment(); continue; }
    if (ch === ' ' || ch === '\t' || ch === '\r') { endToken(); continue; }
    current += ch;
  }
  endSegment();
  return segments;
}

function isRawCodexExec(command, depth) {
  depth = depth || 0;
  if (depth > 3) return false;

  var segments = tokenizeSegments(command);
  for (var i = 0; i < segments.length; i += 1) {
    if (tokensAreCodexExec(segments[i], depth)) return true;
  }

  // A nested shell carries its real command as a STRING argument (`powershell -c "codex exec"`).
  // That argument is one token above, so it must be re-parsed as a command -- but ONLY when a shell
  // is genuinely in command position, which is what keeps `grep "codex exec"` allowed.
  for (var s = 0; s < segments.length; s += 1) {
    var toks = segments[s];
    if (!toks.length) continue;
    var exe = commandBasename(toks[0]);
    if (!NESTED_SHELLS.test(exe)) continue;
    for (var t = 1; t < toks.length; t += 1) {
      if (SHELL_PAYLOAD_FLAG.test(toks[t]) && t + 1 < toks.length) {
        if (isRawCodexExec(toks[t + 1], depth + 1)) return true;
      }
    }
  }

  // -EncodedCommand: base64 is not obfuscation the guard gets to ignore.
  var decoded = decodeEncodedCommands(command);
  for (var e = 0; e < decoded.length; e += 1) {
    if (isRawCodexExec(decoded[e], depth + 1)) return true;
  }

  return false;
}

/**
 * `powershell -File script.ps1` runs a script this hook cannot see the contents of. We do NOT try to
 * read it: that would be a TOCTOU (the file can change between the check and the run) and a
 * filesystem dependency in a hook that must stay fast and pure. Instead the dispatcher itself is the
 * backstop -- it refuses a second coder in a live worktree, reads the report rather than the exit
 * code, and records every run in the ledger. A script that dispatches Codex without the wrapper is
 * indistinguishable from any other program that does; the hook's job is to stop the ROUTINE bypass
 * (a hand-typed `codex exec`), not to be an unbypassable sandbox. Claiming otherwise would be the
 * same theatre this guard was written to end.
 */

/*
 * There is DELIBERATELY no self-test exemption either.
 *
 * There was one, and it was the same bug as the wrapper exemption, shipped a second time in this
 * same file after the first was deleted for exactly that reason: a raw substring test, so
 * `codex exec --json # dispatch-test.ps1` was exempted by a SHELL COMMENT. Rewriting it to match on
 * command position only moved the hole -- `codex exec ; powershell -File dispatch-test.ps1` would
 * have exempted the whole command.
 *
 * And it was never needed. The self-tests drive a FAKE codex through the dispatcher
 * (`powershell -File dispatch-test.ps1`); they contain no `codex exec` tokens, so nothing matches
 * and nothing needs excusing. Removing one instance of a bug class is not removing the class. The
 * exemption is gone, not fixed.
 */

/**
 * `-EncodedCommand <base64>` is a PowerShell payload in UTF-16LE base64. Decode it and re-parse:
 * otherwise one `[Convert]::ToBase64String` is the entire bypass.
 */
function decodeEncodedCommands(raw) {
  var out = [];
  // PowerShell accepts ANY unambiguous prefix: -e, -en, -enc, -enco ... -encodedcommand.
  var re = /(?:-e|-en|-enc|-enco|-encod|-encode|-encoded|-encodedc|-encodedco|-encodedcom|-encodedcomm|-encodedcomma|-encodedcomman|-encodedcommand)\s+([A-Za-z0-9+/=]{8,})/gi;
  var m;
  while ((m = re.exec(raw)) !== null) {
    try {
      var buf = Buffer.from(m[1], 'base64');
      out.push(buf.toString('utf16le'));
      out.push(buf.toString('utf8'));
    } catch (e) { /* not valid base64: ignore */ }
  }
  return out;
}

function handlePreToolUse(data) {
  var disableVal = String(process.env.APEX_CODEX_GUARD || '').trim().toLowerCase();
  if (disableVal === 'off' || disableVal === '0' || disableVal === 'false') {
    return null;
  }

  if (data.tool_name !== 'Bash' && data.tool_name !== 'PowerShell') {
    return null;
  }

  var command = (data.tool_input && data.tool_input.command) || '';
  if (!command) {
    return null;
  }

  if (isRawCodexExec(command, 0)) {
    return deny(
      'Raw `codex exec` is blocked: every Codex dispatch must go through codex-dispatch.ps1.\n' +
      'The raw path has no ledger, no watchdog, no scope check, and no -Adopt — so a dispatch is ' +
      'invisible while it runs, an exit code gets mistaken for the coder\'s verdict, and a dead ' +
      'tool call gets mistaken for a dead coder (it is not: `codex exec` outlives the call that ' +
      'launched it, and keeps writing).\n' +
      'Use: ~/.claude/skills/apex-code/scripts/codex-dispatch.ps1 ' +
      '-Spec <spec> -Task <task> -Worktree <repo> -BaseSha <sha> -Phase build ' +
      '-Authorized <the spec\'s "Files to change" list> -Prompt <pack>\n' +
      'Its exit codes are the contract: 0 done · 65 scope violation · 67 BLOCKED (do not commit) · ' +
      '68 done_with_concerns · 75 still running · 124 stalled.'
    );
  }

  return null;
}
