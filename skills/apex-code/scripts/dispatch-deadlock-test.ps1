# Regression test for the codex-dispatch.ps1 STDIN/STDOUT pipe deadlock.
#
# THE BUG: the wrapper wrote the whole prompt to codex's stdin synchronously and only began draining
# codex's stdout afterward. With a prompt larger than the OS pipe buffer and a child that streams
# stdout from launch (real `codex exec --json`), the two pipes deadlock: the wrapper hangs in
# StandardInput.Write, never records a pid, never writes the log, and the caller dies at its own
# timeout. Live signature (2026-07-14/15): ledger rows with pid=null and 0-byte logs.
#
# THE TEST: dispatch a LARGE prompt through a fake that floods stdout before reading stdin (the real
# ordering), in a background job with a hard timeout. A deadlocked wrapper never returns -> the job
# hits the timeout -> FAIL. A wrapper that services all three pipes concurrently returns, records a
# pid, and writes a non-empty log -> PASS. Runs in an ISOLATED state dir so it never touches the
# live ledger.

$ErrorActionPreference = 'Stop'

$dispatch  = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
$fakeCodex = Join-Path $PSScriptRoot 'dispatch-deadlock-fakecodex.ps1'
if (-not (Test-Path -LiteralPath $dispatch))  { throw "dispatcher not found: $dispatch" }
if (-not (Test-Path -LiteralPath $fakeCodex)) { throw "deadlock fake not found: $fakeCodex" }

$run      = [guid]::NewGuid().ToString('N').Substring(0, 8)
$SP       = Join-Path $env:TEMP "apex-deadlock-test-$run"
$repo     = Join-Path $SP 'repo'
$stateDir = Join-Path $SP 'state'
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'src') | Out-Null
New-Item -ItemType Directory -Force -Path $stateDir              | Out-Null

Push-Location $repo
git init -q
git config user.email 't@t.t'; git config user.name 't'
'orig' | Out-File -Encoding ascii src/a.py
git add -A; git commit -q -m init
$baseSha = (git rev-parse HEAD)
Pop-Location

# A prompt comfortably larger than the pipe buffer -- the whole point of the reproduction.
$bigPrompt = 'A' * 200000
$timeoutSec = 60

Write-Host "`n--- dispatching a $($bigPrompt.Length)-char prompt through the stdout-flooding fake ---`n" -ForegroundColor Cyan

$job = Start-Job -ScriptBlock {
    param($dispatch, $fakeCodex, $repo, $baseSha, $prompt, $stateDir)
    $env:APEX_STATE_DIR = $stateDir
    & $dispatch -Spec 'deadlock' -Task 'pipe' -Phase 'build' -Worktree $repo -BaseSha $baseSha `
        -Prompt $prompt -Authorized @('src/a.py') -SkipScopeCheck -SkipBaselineCheck -ScratchDirectory $stateDir `
        -CodexExecutable 'powershell.exe' `
        -CodexExecutableArgumentPrefix @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeCodex)
    $LASTEXITCODE
} -ArgumentList $dispatch, $fakeCodex, $repo, $baseSha, $bigPrompt, $stateDir

$finished = Wait-Job $job -Timeout $timeoutSec
$wedged = ($null -eq $finished)
if ($wedged) { Stop-Job $job } else { Receive-Job $job | Out-Null }
Remove-Job $job -Force -ErrorAction SilentlyContinue

# Read this run's ledger row FIRST -- it records the exact child pid, so cleanup can target only THIS
# run's fake. (A bare '*dispatch-deadlock-fakecodex*' command-line match would let concurrent test
# runs, or any unrelated invocation containing that text, kill one another -- flagged in review.)
$ledgerPath = Join-Path $stateDir 'progress\codex-run-ledger.jsonl'
$row = $null
if (Test-Path $ledgerPath) {
    $row = Get-Content $ledgerPath |
        Where-Object { $_ -match '"spec":\s*"deadlock"' } |
        Select-Object -Last 1 | ForEach-Object { $_ | ConvertFrom-Json }
}

# If the run wedged, kill ONLY this run's fake: prefer the pid the ledger recorded; fall back to a
# command-line match scoped to this run's unique temp path ($run) -- never a bare fakecodex match.
if ($wedged) {
    if ($row -and $row.pid) {
        Stop-Process -Id ([int]$row.pid) -Force -ErrorAction SilentlyContinue
    } else {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*dispatch-deadlock-fakecodex*' -and $_.CommandLine -like "*$run*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}
$logDir = Join-Path $stateDir 'progress\codex-logs'
$logBytes = 0
if (Test-Path $logDir) {
    $lf = Get-ChildItem $logDir -Filter 'codex-deadlock-pipe-*.log' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($lf) { $logBytes = $lf.Length }
}

$fail = 0
function Check($label, $cond, $detail) {
    $mark = if ($cond) { 'ok  ' } else { 'FAIL' }
    $col  = if ($cond) { 'Green' } else { 'Red' }
    if (-not $cond) { $script:fail++ }
    Write-Host ("  {0}  {1,-40} {2}" -f $mark, $label, $detail) -ForegroundColor $col
}

Write-Host "`n===== RESULTS =====" -ForegroundColor Cyan
Check 'dispatch did NOT wedge'  (-not $wedged)                       "returned within ${timeoutSec}s"
Check 'pid recorded in ledger'  ($row -and $row.pid)                 "pid=$($row.pid)"
Check 'log is non-empty'        ($logBytes -gt 0)                    "$logBytes bytes"
Check 'run reached terminal'    ($row -and $row.status -eq 'done')   "status=$($row.status)"

# Best-effort cleanup of the isolated scratch.
try { Remove-Item -Recurse -Force $SP -ErrorAction SilentlyContinue } catch {}

if ($fail -gt 0) { Write-Host "`n$fail check(s) FAILED`n" -ForegroundColor Red; exit 1 }
Write-Host "`nall checks passed`n" -ForegroundColor Green
exit 0
