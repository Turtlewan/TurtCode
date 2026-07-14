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
CASES.forEach(function(c) {
  var want = c[0];
  var cmd = c[1];
  var payload = JSON.stringify({ tool_name: 'Bash', tool_input: { command: cmd } });
  var out = cp.execSync('node "' + GUARD + '"', { input: payload }).toString();
  var got = out.indexOf('"deny"') >= 0 ? 'BLOCK' : 'ALLOW';
  var ok = got === want;
  if (!ok) failures += 1;
  console.log((ok ? '  ok    ' : '  FAIL  ') + '[' + got + '] ' + cmd.slice(0, 62));
});

console.log('');
if (failures === 0) {
  console.log('ALL ' + CASES.length + ' CASES PASS — no bypass, no false positive.');
  process.exit(0);
}
console.log(failures + ' FAILURE(S)');
process.exit(1);
