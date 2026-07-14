# Prove the mangled-allowlist guard: a WRONG -Authorized must never revert the coder's real work.
$ErrorActionPreference = 'Stop'
$SP   = 'C:\Users\User\AppData\Local\Temp\claude\C--users-user-apex\97a47186-588e-4011-a69e-aab98ab8c5c7\scratchpad'
$repo = Join-Path $SP 'dt4'
$chk  = 'C:\Users\User\.claude\skills\apex-code\scripts\codex-scope-check.ps1'

if (Test-Path $repo) { Remove-Item -Recurse -Force $repo }
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'src') | Out-Null
Push-Location $repo
git init -q; git config user.email 't@t.t'; git config user.name 't'
'orig' | Out-File -Encoding ascii src/a.py
'orig' | Out-File -Encoding ascii src/b.py
'orig' | Out-File -Encoding ascii src/c.py
git add -A; git commit -q -m init

& $chk -Snapshot -Worktree $repo -Task 'mangled' | Out-Null

# The coder does REAL, CORRECT work on all three authorized files.
Add-Content src/a.py 'REAL WORK'
Add-Content src/b.py 'REAL WORK'
Add-Content src/c.py 'REAL WORK'

Write-Host "`n--- coder wrote 3 files, all legitimately in scope ---"
Write-Host "--- but the host passes a MANGLED -Authorized (typo'd paths) ---`n" -ForegroundColor Yellow

& $chk -Check -Worktree $repo -Task 'mangled' -Authorized @('srcc/a.py','srcc/b.py','srcc/c.py')
$ec = $LASTEXITCODE

Write-Host "`n===== RESULTS =====" -ForegroundColor Cyan
function Check($label, $cond, $detail) {
    $m = if ($cond) { 'ok  ' } else { 'FAIL' }
    $c = if ($cond) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-40} {2}" -f $m, $label, $detail) -ForegroundColor $c
}
Check 'exit 66 (refused, not reverted)' ($ec -eq 66) "got $ec"
Check "src/a.py REAL WORK survived" ((Get-Content src/a.py -Raw) -match 'REAL WORK') 'not destroyed'
Check "src/b.py REAL WORK survived" ((Get-Content src/b.py -Raw) -match 'REAL WORK') 'not destroyed'
Check "src/c.py REAL WORK survived" ((Get-Content src/c.py -Raw) -match 'REAL WORK') 'not destroyed'
Pop-Location
