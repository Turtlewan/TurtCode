#!/usr/bin/env node
/**
 * Bypass suite for codex-dispatch-guard.js.
 *
 * Every BLOCK case below was a live bypass found by the cross-family Codex review (2026-07-14).
 * The guard blocked exactly one shape -- the one its author tested -- and waved through every other
 * way of spelling the same command, including a SHELL COMMENT naming the wrapper. A guard with a
 * trivial bypass is theatre.
 *
 * The ALLOW cases are the other half: a guard that blocks `git commit -m "...codex exec..."` or
 * `grep "codex exec"` is a guard that gets switched off. Both halves have to hold at once.
 */
'use strict';

var cp = require('child_process');
var fs = require('fs');
var os = require('os');
var path = require('path');

var GUARD = path.join(__dirname, 'codex-dispatch-guard.js');

var CASES = [
  // --- must BLOCK: the original shape ---
  ['BLOCK', 'printf %s "$PACK" | codex exec -m gpt-5.6-sol -C C:/Users/User/artemis'],
  ['BLOCK', 'codex exec --sandbox workspace-write -p apex-coder'],
  ['BLOCK', 'cat pack.txt | codex exec'],
  ['BLOCK', 'node C:/npm/node_modules/@openai/codex/bin/codex.js exec --json'],
  ['BLOCK', 'CODEX_HOME=/tmp codex exec -m gpt-5.6-sol'],

  // --- must BLOCK: bypasses the review found ---
  ['BLOCK', 'codex exec --help # codex-dispatch.ps1'],          // shell comment disarmed the guard
  ['BLOCK', 'powershell -c "codex exec -m gpt-5.6-sol"'],       // quoted payload
  ['BLOCK', "sh -c 'codex exec --json'"],                       // single-quoted payload
  ['BLOCK', 'cmd.exe /c codex exec --sandbox workspace-write'], // unquoted nested shell
  ['BLOCK', 'npx codex exec -p apex-coder'],                    // transparent runner
  ['BLOCK', '& "codex" exec -m gpt-5.6-sol'],                   // PowerShell call operator
  ['BLOCK', 'env FOO=1 codex exec'],                            // env prefix
  ['BLOCK', 'bash -c "npx codex exec --json"'],                 // runner inside a nested shell
  ['BLOCK', 'ls; codex exec -p apex-coder'],                    // second segment
  ['BLOCK', 'pwsh -Command "codex exec"'],                      // pwsh + -Command

  // --- must BLOCK: round-3 bypasses (cross-family review) ---
  ['BLOCK', 'powershell.exe -enc YwBvAGQAZQB4ACAAZQB4AGUAYwAgAC0ALQBoAGUAbABwAA=='],
  ['BLOCK', "iex 'codex exec --help'"],
  ['BLOCK', 'npm exec -- codex exec --help'],
  ['BLOCK', 'npm exec codex exec'],
  ['BLOCK', 'yarn exec codex exec'],

  // --- must BLOCK: round-4 (things a NORMAL user would plausibly type) ---
  ['BLOCK', 'wsl codex exec --json'],                                        // no payload flag at all
  ['BLOCK', 'wsl -d Ubuntu -u root -- codex exec'],                          // wsl's own options
  ['BLOCK', 'wsl --distribution Ubuntu -- codex exec --json'],               // LONG option + value
  ['BLOCK', 'wsl --user root codex exec'],
  ['BLOCK', '& "C:\\Users\\User\\AppData\\Roaming\\npm\\codex.cmd" exec --json'],  // quoted Windows path
  ['BLOCK', '"C:\\Program Files\\codex\\codex.exe" exec'],

  // --- must BLOCK: round-6 (scriptblocks are command carriers) ---
  ['BLOCK', 'Start-Job { codex exec --json }'],
  ['BLOCK', 'Invoke-Command -ScriptBlock { codex exec }'],
  ['BLOCK', '1..3 | % { codex exec }'],

  // --- must BLOCK: round-7 (Start-Process launches the raw dispatch) ---
  ['BLOCK', 'Start-Process codex exec'],
  ['BLOCK', 'Start-Process -FilePath codex -ArgumentList exec'],

  // --- must BLOCK: round-8 (string evaluator + joined Start-Process argument carrier) ---
  ['BLOCK', "eval 'codex exec'"],
  ['BLOCK', 'eval "codex exec --json"'],
  ['BLOCK', "Start-Process codex -ArgumentList 'exec -m gpt-5.6-sol'"],

  // --- must ALLOW: the wrapper, and anything that merely MENTIONS the command ---
  ['ALLOW', "powershell -File C:/Users/User/.claude/skills/apex-code/scripts/codex-dispatch.ps1 -Spec s -Task t"],
  ['ALLOW', 'codex --version'],
  ['ALLOW', 'codex login status'],
  ['ALLOW', 'git commit -m "feat: dispatch via codex exec wrapper"'],
  ['ALLOW', 'grep -rn "codex exec" docs/'],
  ['ALLOW', 'echo "do not run codex exec directly"'],
  ['ALLOW', 'rg "codex exec" --glob "*.md"'],
  ['ALLOW', 'ls ~/.claude/skills/apex-code/scripts/'],
  // A nested shell that merely PRINTS the string must still be allowed -- the recursion re-parses
  // the payload as a command, and `echo` is not codex.
  ['ALLOW', 'bash -c "echo codex exec is blocked"'],
  ['ALLOW', 'powershell -NoProfile -File C:/Users/User/.claude/skills/apex-code/scripts/dispatch-test.ps1'],
  ['ALLOW', 'npm run build'],
  ['ALLOW', 'npm exec -- eslint .'],
  ['ALLOW', 'iex (Get-Content build.ps1 -Raw)'],
  ['ALLOW', 'Start-Process notepad'],
  ['ALLOW', 'Start-Process -FilePath powershell -ArgumentList "-File","build.ps1"'],
];

var failures = 0;
var assertions = 0;

function childEnv(overrides) {
  var env = Object.assign({}, process.env);
  delete env.APEX_CODEX_GUARD;
  delete env.APEX_GUARD_DISABLE_REASON;
  delete env.APEX_GUARD_AUDIT_LOG;
  delete env.APEX_GUARD_STDIN_TIMEOUT_MS;
  return Object.assign(env, overrides || {});
}

function runGuard(payload, env) {
  var result = cp.spawnSync(process.execPath, [GUARD], {
    input: payload,
    encoding: 'utf8',
    env: childEnv(env)
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error('guard exited ' + result.status + ': ' + result.stderr);
  }
  return result.stdout;
}

function decisionFrom(stdout) {
  if (!stdout.trim()) return null;
  var parsed = JSON.parse(stdout);
  return parsed && parsed.hookSpecificOutput && parsed.hookSpecificOutput.permissionDecision;
}

function record(ok, label) {
  assertions += 1;
  if (!ok) failures += 1;
  console.log((ok ? '  ok    ' : '  FAIL  ') + label);
}

function assertDeny(label, payload, env) {
  var decision = null;
  try {
    decision = decisionFrom(runGuard(payload, env));
  } catch (e) {
    record(false, '[ERROR] ' + label + ' (' + e.message + ')');
    return;
  }
  record(decision === 'deny', '[' + (decision === 'deny' ? 'BLOCK' : 'ALLOW') + '] ' + label);
}

function readAuditRows(file) {
  if (!fs.existsSync(file)) return [];
  var content = fs.readFileSync(file, 'utf8').trim();
  return content ? content.split(/\r?\n/).map(JSON.parse) : [];
}

CASES.forEach(function(c) {
  var want = c[0];
  var cmd = c[1];
  var payload = JSON.stringify({ tool_name: 'Bash', tool_input: { command: cmd } });
  var got = 'ERROR';
  try {
    got = decisionFrom(runGuard(payload)) === 'deny' ? 'BLOCK' : 'ALLOW';
  } catch (e) {
    record(false, '[ERROR] ' + cmd.slice(0, 62) + ' (' + e.message + ')');
    return;
  }
  record(got === want, '[' + got + '] ' + cmd.slice(0, 62));
});

// Fail closed on input that was not received or could not be validated.
assertDeny('malformed JSON stdin', '{');
assertDeny('empty stdin', '');
assertDeny(
  'malformed shape: command is an object',
  JSON.stringify({ tool_name: 'Bash', tool_input: { command: { raw: 'codex exec' } } })
);

// The kill-switch requires a reason, audits every recognized disable attempt, and fails closed if
// its audit record cannot be appended.
var auditRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-dispatch-guard-'));
var auditLog = path.join(auditRoot, 'guard-audit.log');
var rawPayload = JSON.stringify({
  tool_name: 'Bash',
  tool_input: { command: 'codex exec --json' }
});

assertDeny('kill-switch without reason', rawPayload, {
  APEX_CODEX_GUARD: 'off',
  APEX_GUARD_DISABLE_REASON: '',
  APEX_GUARD_AUDIT_LOG: auditLog
});
var auditRows = readAuditRows(auditLog);
record(
  auditRows.length === 1 && auditRows[0].guard === 'codex-dispatch-guard' &&
    auditRows[0].reason === null && auditRows[0].honored === false &&
    auditRows[0].subject === 'codex exec --json',
  '[AUDIT] reasonless disable attempt records honored:false'
);

var reasonedOut = runGuard(rawPayload, {
  APEX_CODEX_GUARD: 'off',
  APEX_GUARD_DISABLE_REASON: 'maintenance window',
  APEX_GUARD_AUDIT_LOG: auditLog
});
auditRows = readAuditRows(auditLog);
record(
  decisionFrom(reasonedOut) !== 'deny' && auditRows.length === 2 &&
    auditRows[1].guard === 'codex-dispatch-guard' &&
    auditRows[1].reason === 'maintenance window' && auditRows[1].honored === true &&
    auditRows[1].subject === 'codex exec --json',
  '[ALLOW+AUDIT] reasoned disable attempt records honored:true'
);

assertDeny('kill-switch audit append failure', rawPayload, {
  APEX_CODEX_GUARD: 'off',
  APEX_GUARD_DISABLE_REASON: 'maintenance window',
  APEX_GUARD_AUDIT_LOG: auditRoot
});

function finish() {
  fs.rmSync(auditRoot, { recursive: true, force: true });
  console.log('');
  if (failures === 0) {
    console.log('ALL ' + assertions + ' ASSERTIONS PASS — no bypass, false positive, or fail-open path.');
    process.exit(0);
  }
  console.log(failures + ' FAILURE(S)');
  process.exit(1);
}

// Leave stdin open: only the guard's own timeout may close this child with a deny decision.
var heldOpen = cp.spawn(process.execPath, [GUARD], {
  env: childEnv({ APEX_GUARD_STDIN_TIMEOUT_MS: '40' }),
  stdio: ['pipe', 'pipe', 'pipe']
});
var heldStdout = '';
var heldStderr = '';
var heldFinished = false;
var heldWatchdog = setTimeout(function() {
  if (heldFinished) return;
  heldFinished = true;
  heldOpen.kill();
  record(false, '[TIMEOUT] held-open stdin did not produce a timely decision');
  finish();
}, 2000);
heldOpen.stdout.setEncoding('utf8');
heldOpen.stderr.setEncoding('utf8');
heldOpen.stdout.on('data', function(chunk) { heldStdout += chunk; });
heldOpen.stderr.on('data', function(chunk) { heldStderr += chunk; });
heldOpen.on('close', function(code) {
  if (heldFinished) return;
  heldFinished = true;
  clearTimeout(heldWatchdog);
  var decision = null;
  try {
    decision = decisionFrom(heldStdout);
  } catch (e) {
    record(false, '[ERROR] held-open stdin output (' + e.message + ')');
    finish();
    return;
  }
  record(
    code === 0 && decision === 'deny',
    '[' + (decision === 'deny' ? 'BLOCK' : 'ALLOW') + '] held-open stdin timeout' +
      (heldStderr ? ' (' + heldStderr.trim() + ')' : '')
  );
  finish();
});
