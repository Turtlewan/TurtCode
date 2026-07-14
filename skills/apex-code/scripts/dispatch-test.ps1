# End-to-end test of codex-dispatch.ps1 with the scope check wired in.
# Driven from PowerShell so array params pass natively (the bash-array mangling is a caller bug,
# not a dispatcher bug -- but it bit twice today, so the real caller must pass arrays properly too).

$ErrorActionPreference = 'Stop'
$SP   = 'C:\Users\User\AppData\Local\Temp\claude\C--users-user-apex\97a47186-588e-4011-a69e-aab98ab8c5c7\scratchpad'
$repo = Join-Path $SP 'dt3'

if (Test-Path $repo) { Remove-Item -Recurse -Force $repo }
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'src')  | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'docs') | Out-Null
Push-Location $repo

git init -q
git config user.email 't@t.t'; git config user.name 't'
'orig'       | Out-File -Encoding ascii src/a.py
'orig'       | Out-File -Encoding ascii src/b.py
'HOST STATE' | Out-File -Encoding ascii docs/status.md
git add -A; git commit -q -m init

# The host is editing status.md RIGHT NOW, in the same tree. This must survive.
Add-Content docs/status.md 'host ADR note'

$env:FAKE_CODEX_REPO = $repo
$baseSha = (git rev-parse HEAD)

Write-Host "`n--- dispatching (authorized: src/a.py only) ---`n" -ForegroundColor Cyan

& 'C:\Users\User\.claude\skills\apex-code\scripts\codex-dispatch.ps1' `
    -Spec 'cap-test' -Task 't3' -Phase 'build' -Worktree $repo -BaseSha $baseSha `
    -Prompt 'Implement the deps field.' `
    -Authorized @('src/a.py') `
    -CodexExecutable 'powershell.exe' `
    -CodexExecutableArgumentPrefix @('-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $SP 'fakecodex.ps1'))

$ec = $LASTEXITCODE

Write-Host "`n===== RESULTS =====" -ForegroundColor Cyan
$log = Get-Content (Join-Path $repo 'docs/progress/codex-cap-test-t3.log') -Raw -ErrorAction SilentlyContinue

function Check($label, $cond, $detail) {
    $mark = if ($cond) { 'ok  ' } else { 'FAIL' }
    $col  = if ($cond) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-42} {2}" -f $mark, $label, $detail) -ForegroundColor $col
}

Check 'stdin delivered the prompt'   ($log -match 'got prompt')                  'fake codex read stdin'
Check 'scope lock reached the prompt'($log -match 'scope lock present')          'belt-and-braces prose'
Check 'authorized change KEPT'        ((Get-Content src/a.py -Raw) -match 'codex authorized')  'src/a.py'
Check 'out-of-scope REVERTED'         (-not ((Get-Content src/b.py -Raw) -match 'OUT OF SCOPE')) 'src/b.py'
Check 'stray file DELETED'            (-not (Test-Path src/rogue.py))            'src/rogue.py'
$st = Get-Content docs/status.md -Raw
Check 'host status.md edit SURVIVED'  ($st -match 'host ADR note')               'the ADR-destroying bug'
Check 'codex status.md write flagged' ($st -match 'codex clobbered')             'contested, not reverted'
Check 'exit 65 (scope violation)'     ($ec -eq 65)                               "got $ec"

Pop-Location
