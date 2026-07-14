# A scope check must NEVER delete a running sibling coder's work.
#
# The pre-dirty guard protects the HOST. It has no concept of a sibling coder -- and a sibling's
# brand-new files pass every test for an out-of-scope write: clean at snapshot (they did not exist
# yet), dirty now, not on this task's authorized list. So the check deletes them. Untracked files,
# Remove-Item -Recurse, no git object. Gone.
#
# Live: al-7c-quiet-gate (2026-07-14). Task 4 and Task 5 ran in parallel in ONE working tree. Task 4
# finished first and deleted Task 5's freshly-written files WHILE TASK 5 WAS STILL RUNNING -- which
# then carried on verifying against a tree that no longer held its code.
#
# Two mechanisms, tested here:
#   seatbelt (exit 71) -- the dispatcher refuses to launch into a tree that already has a live coder
#   airbag   (exit 70) -- the scope check refuses to revert while a sibling is live

$ErrorActionPreference = 'Stop'

$scopeCheck = Join-Path $PSScriptRoot 'codex-scope-check.ps1'
$apexRoot = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'apex' } else { Join-Path $env:TEMP 'apex' }
$ledger = Join-Path (Join-Path $apexRoot 'progress') 'codex-run-ledger.jsonl'
$repo = Join-Path $env:TEMP 'apex-sibling-test'
$failures = 0

function Assert-Ok {
    param([bool]$Condition, [string]$Name, [string]$Detail)
    $mark = if ($Condition) { 'ok  ' } else { 'FAIL' }
    $colour = if ($Condition) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-48} {2}" -f $mark, $Name, $Detail) -ForegroundColor $colour
    if (-not $Condition) { $script:failures += 1 }
}

if (Test-Path $repo) { Remove-Item -Recurse -Force $repo }
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'src') | Out-Null
Push-Location $repo
git init -q
git config user.email 't@t.t'; git config user.name 't'
'orig' | Out-File -Encoding ascii src/task4.py
git add -A; git commit -q -m init
Pop-Location

# A REAL live process to stand in for the sibling coder. Its PID must actually resolve, because the
# guard checks liveness -- a stale ledger row with a dead PID must NOT block anything.
$sibling = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 90' `
    -PassThru -WindowStyle Hidden

try {
    # Task 4 snapshots. Task 5's files do not exist yet -- that is the whole trap.
    & $scopeCheck -Snapshot -Worktree $repo -Task 'task4' -Authorized @('src/task4.py') *> $null

    # Ledger row: task5 is RUNNING in the SAME worktree, with a live pid.
    $row = [ordered]@{
        run_id = 'siblingtest'; pid = $sibling.Id; worktree = $repo
        spec = 'al-7c-quiet-gate'; task = 'task5'; phase = 'build'
        started = (Get-Date).ToUniversalTime().ToString('o'); status = 'running'
    }
    Add-Content -Path $ledger -Value ($row | ConvertTo-Json -Compress) -Encoding UTF8

    # Task 5 writes its files. Task 4 writes its own, in scope.
    'task5 WORK -- must survive' | Out-File -Encoding ascii (Join-Path $repo 'src/task5.py')
    'task5 test  -- must survive' | Out-File -Encoding ascii (Join-Path $repo 'src/test_task5.py')
    Add-Content (Join-Path $repo 'src/task4.py') 'task4 output'

    # Task 4's scope check fires while task5 is still alive.
    & $scopeCheck -Check -Worktree $repo -Task 'task4' -Authorized @('src/task4.py') *> $null
    $exit = $LASTEXITCODE

    # The airbag is GONE, because the scope check no longer reverts ANYTHING. A live sibling's files
    # are reported as out-of-scope (they are, from this task's point of view) -- and left alone. The
    # protection is now structural rather than conditional: there is no code path that can delete
    # them, so there is no guard left to fail.
    Assert-Ok ($exit -eq 1) 'out-of-scope paths are REPORTED, never reverted' "exit $exit (want 1)"
    Assert-Ok (Test-Path (Join-Path $repo 'src/task5.py')) "sibling's src/task5.py SURVIVED" 'not deleted'
    Assert-Ok (Test-Path (Join-Path $repo 'src/test_task5.py')) "sibling's src/test_task5.py SURVIVED" 'not deleted'
    Assert-Ok ((Get-Content (Join-Path $repo 'src/task4.py') -Raw) -match 'task4 output') "task4's own in-scope work intact" 'kept'
} finally {
    Stop-Process -Id $sibling.Id -Force -ErrorAction SilentlyContinue
    # Drop the synthetic row so it cannot block a real dispatch later.
    $kept = [System.IO.File]::ReadAllLines($ledger) | Where-Object { $_ -notmatch 'siblingtest' }
    [System.IO.File]::WriteAllLines($ledger, [string[]]$kept, [System.Text.UTF8Encoding]::new($false))
}

# Once the sibling is DEAD, the guard must stand down and the check must bite normally again --
# otherwise a stale ledger row would disarm scope enforcement forever.
& $scopeCheck -Snapshot -Worktree $repo -Task 'task4b' -Authorized @('src/task4.py') *> $null
'stray' | Out-File -Encoding ascii (Join-Path $repo 'src/rogue.py')
& $scopeCheck -Check -Worktree $repo -Task 'task4b' -Authorized @('src/task4.py') *> $null
Assert-Ok ($LASTEXITCODE -eq 1) 'a real stray is still DETECTED' "exit $LASTEXITCODE (want 1)"
Assert-Ok (Test-Path (Join-Path $repo 'src/rogue.py')) '  ...and left in the tree for a human' 'reported, not destroyed'

Write-Host ''
if ($failures -eq 0) {
    Write-Host "ALL SIBLING-GUARD CASES PASS -- a live coder's work is never reverted; real strays still are." -ForegroundColor Green
    exit 0
}
Write-Host "$failures FAILURE(S)" -ForegroundColor Red
exit 1
