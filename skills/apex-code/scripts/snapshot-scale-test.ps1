# Regression for the build-dispatch pre-launch HANG (session 9): codex-scope-check.ps1 -Snapshot
# fingerprinted a dirty DIRECTORY by spawning `git hash-object` PER FILE, so an ignored node_modules
# /.venv/target (tens of thousands of files, collapsed to one `git status --ignored` entry) spawned
# tens of thousands of git processes and never returned -- wedging every build dispatch before launch.
# The fix aggregates file metadata in one enumeration. This test proves a large untracked directory
# is snapshotted FAST (the old per-file-subprocess path would blow the bound), and the fingerprint is
# the metadata form.

$ErrorActionPreference = 'Continue'
$scope = Join-Path $PSScriptRoot 'codex-scope-check.ps1'
$parent = Join-Path $env:TEMP ("snapscale-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$repo = Join-Path $parent 'repo'; $state = Join-Path $parent 'state'
New-Item -ItemType Directory -Force -Path $repo | Out-Null
New-Item -ItemType Directory -Force -Path $state | Out-Null

Push-Location $repo
git init -q; git config user.email 't@t.t'; git config user.name 't'
'x=1' | Out-File -Encoding ascii app.py
git add -A; git commit -q -m init
# A large untracked directory -- 600 files. Under the OLD per-file `git hash-object` this is 600
# subprocess spawns (~30-60s+); the metadata aggregate does it in well under a second.
$big = Join-Path $repo 'buildcache'
New-Item -ItemType Directory -Force -Path $big | Out-Null
for ($i = 0; $i -lt 600; $i++) { [System.IO.File]::WriteAllText((Join-Path $big "f$i.tmp"), "data$i") }
Pop-Location

$fail = 0
function Check($label, $cond, $detail) {
    $mark = if ($cond) { 'ok  ' } else { 'FAIL' }; $col = if ($cond) { 'Green' } else { 'Red' }
    if (-not $cond) { $script:fail++ }
    Write-Host ("  {0}  {1,-44} {2}" -f $mark, $label, $detail) -ForegroundColor $col
}

Write-Host "`n=== snapshot scale (no per-file git subprocess) ===" -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scope -Snapshot -Worktree $repo -Task 'scale' -StateDirectory $state *> $null
$snapExit = $LASTEXITCODE
$sw.Stop()
$secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
Check 'snapshot of a 600-file untracked dir completes' ($snapExit -eq 0) "exit=$snapExit"
Check 'and does so FAST (< 15s; old path would not)' ($sw.Elapsed.TotalSeconds -lt 15) "took ${secs}s"

# Unchanged tree -> in scope (before == after, so the new hash is stable and comparable).
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scope -Check -Worktree $repo -Task 'scale' -Authorized @('app.py') -StateDirectory $state *> $null
Check 'unchanged tree is in scope (0)' ($LASTEXITCODE -eq 0) "check exit=$LASTEXITCODE"

# DETERMINISTIC path-sensitivity (not timing-dependent): rename a file inside the unauthorized dir. A
# rename preserves count, total size, and mtime, so an aggregate fingerprint MISSES it and passes --
# the exact hole a first version of this fix had. The path-inclusive fingerprint sees the directory
# change and flags an out-of-scope write (exit 65). Fails against an aggregate-only implementation.
Rename-Item (Join-Path $big 'f0.tmp') (Join-Path $big 'renamed0.tmp')
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scope -Check -Worktree $repo -Task 'scale' -Authorized @('app.py') -StateDirectory $state *> $null
# Non-zero = the change was DETECTED (a real scope violation), not silently passed as clean-0. That is
# the property the aggregate fingerprint lost; path-inclusive restores it.
Check 'a RENAME inside the dir is detected (not clean)' ($LASTEXITCODE -ne 0) "check exit=$LASTEXITCODE"

try { Remove-Item -Recurse -Force $parent -ErrorAction SilentlyContinue } catch {}
Write-Host ""
if ($script:fail -gt 0) { Write-Host "$($script:fail) check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "ALL SNAPSHOT-SCALE TESTS PASS." -ForegroundColor Green
exit 0
