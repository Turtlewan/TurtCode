# Regression suite for the 12 findings raised by the cross-family Codex review (2026-07-14).
#
# Every case here is a defect that got past 33 passing tests -- because the same agent wrote the code
# AND the tests, so they shared its blind spots exactly. That is the entire argument for reviewing
# across model families, and it is why these tests exist as a separate, adversarially-derived file.

$ErrorActionPreference = 'Stop'

$SP = $PSScriptRoot
$scopeCheck = Join-Path $SP 'codex-scope-check.ps1'
$treePin = Join-Path $SP 'tree-pin.ps1'
$dispatch = Join-Path $SP 'codex-dispatch.ps1'
$fakeCodex = Join-Path $SP 'dispatch-test-fakecodex.ps1'
$apexRoot = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'apex' } else { Join-Path $env:TEMP 'apex' }
$ledger = Join-Path (Join-Path $apexRoot 'progress') 'codex-run-ledger.jsonl'
$root = Join-Path $env:TEMP 'apex-review-findings'
$failures = 0

function Assert-Ok {
    param([bool]$Condition, [string]$Name, [string]$Detail)
    $mark = if ($Condition) { 'ok  ' } else { 'FAIL' }
    $colour = if ($Condition) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-54} {2}" -f $mark, $Name, $Detail) -ForegroundColor $colour
    if (-not $Condition) { $script:failures += 1 }
}

function New-Repo([string]$Path) {
    if (Test-Path $Path) { Remove-Item -Recurse -Force $Path }
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'src') | Out-Null
    Push-Location $Path
    git init -q
    git config user.email 't@t.t'; git config user.name 't'
    'orig' | Out-File -Encoding ascii src/a.py
    git add -A; git commit -q -m init
    Pop-Location
}

Write-Host "`n--- #7  coder writes INSIDE an untracked directory (scope check) ---" -ForegroundColor Cyan
# git collapses an untracked dir to one entry `?? scratch/`. Hashing it as a constant meant the
# subtree read as "byte-identical host work" and every write inside it was IGNORED.
$repo = Join-Path $root 'f7'
New-Repo $repo
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'scratch') | Out-Null
'host file' | Out-File -Encoding ascii (Join-Path $repo 'scratch/host.py')
& $scopeCheck -Snapshot -Worktree $repo -Task 't' -Authorized @('src/a.py') *> $null
'CODEX SNUCK THIS IN' | Out-File -Encoding ascii (Join-Path $repo 'scratch/evil.py')
Add-Content (Join-Path $repo 'src/a.py') 'in scope'
& $scopeCheck -Check -Worktree $repo -Task 't' -Authorized @('src/a.py') -ReportOnly *> $null
Assert-Ok ($LASTEXITCODE -ne 0) 'write inside an untracked dir is DETECTED' "exit $LASTEXITCODE (want non-zero)"

Write-Host "`n--- #8  tree-pin: content changing inside an untracked directory ---" -ForegroundColor Cyan
$repo = Join-Path $root 'f8'
New-Repo $repo
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'newdir') | Out-Null
'v1' | Out-File -Encoding ascii (Join-Path $repo 'newdir/file.py')
& $treePin -Pin -Worktree $repo -Label 'g' *> $null
'v2 REWRITTEN' | Out-File -Encoding ascii (Join-Path $repo 'newdir/file.py')
& $treePin -Verify -Worktree $repo -Label 'g' *> $null
Assert-Ok ($LASTEXITCODE -eq 69) 'tree-pin sees content change inside an untracked dir' "exit $LASTEXITCODE (want 69)"

Write-Host "`n--- #9  tree-pin: the INDEX changes, the worktree does not ---" -ForegroundColor Cyan
# A commit is built from the INDEX. Hashing only the working file lets someone stage a different
# blob after the gate opened, and the pin never notices.
$repo = Join-Path $root 'f9'
New-Repo $repo
Push-Location $repo
Add-Content src/a.py 'worktree change'
git add src/a.py                       # index == worktree
Add-Content src/a.py 'more, unstaged'  # now MM: index A, worktree B
Pop-Location
& $treePin -Pin -Worktree $repo -Label 'g' *> $null
Push-Location $repo
# Stage a DIFFERENT blob without touching the working file: index becomes C, worktree stays B.
'STAGED C' | Out-File -Encoding ascii .git-tmp-blob
$blob = (git hash-object -w .git-tmp-blob)
git update-index --cacheinfo 100644, $blob, src/a.py
Remove-Item .git-tmp-blob -Force
Pop-Location
& $treePin -Verify -Worktree $repo -Label 'g' *> $null
Assert-Ok ($LASTEXITCODE -eq 69) 'tree-pin sees a staged blob swap (worktree unchanged)' "exit $LASTEXITCODE (want 69)"

Write-Host "`n--- #2  worktree identity is canonical, not lexical ---" -ForegroundColor Cyan
# `-Worktree .` and the absolute path are the same tree. A lexical compare treats them as two, so
# the seatbelt lets a second coder in and the airbag then deletes its work.
$repo = Join-Path $root 'f2'
New-Repo $repo
$sibling = Start-Process powershell.exe -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 60' -PassThru -WindowStyle Hidden
try {
    $row = [ordered]@{
        run_id = 'idtest'; pid = $sibling.Id; launcher_pid = $sibling.Id
        worktree = $repo; worktree_key = ((& git -C $repo rev-parse --show-toplevel) -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
        spec = 's'; task = 'other'; phase = 'build'
        started = (Get-Date).ToUniversalTime().ToString('o'); status = 'running'
    }
    Add-Content -Path $ledger -Value ($row | ConvertTo-Json -Compress) -Encoding UTF8

    # Snapshot + check using a RELATIVE path -- a different spelling of the same tree.
    Push-Location $repo
    & $scopeCheck -Snapshot -Worktree '.' -Task 'mine' -Authorized @('src/a.py') *> $null
    'sibling work -- must survive' | Out-File -Encoding ascii (Join-Path $repo 'src/sibling.py')
    & $scopeCheck -Check -Worktree '.' -Task 'mine' -Authorized @('src/a.py') *> $null
    $exit = $LASTEXITCODE
    Pop-Location
    Assert-Ok ($exit -eq 1) 'out-of-scope paths reported, never reverted' "exit $exit (want 1)"
    Assert-Ok (Test-Path (Join-Path $repo 'src/sibling.py')) "  ...so a sibling's work SURVIVES by construction" 'no delete path exists'
} finally {
    Stop-Process -Id $sibling.Id -Force -ErrorAction SilentlyContinue
    $kept = [System.IO.File]::ReadAllLines($ledger) | Where-Object { $_ -notmatch 'idtest' }
    [System.IO.File]::WriteAllLines($ledger, [string[]]$kept, [System.Text.UTF8Encoding]::new($false))
}

Write-Host "`n--- #12  PID reuse must not wedge the guard forever ---" -ForegroundColor Cyan
# A stale row whose pid got recycled by an unrelated, OLDER process must NOT read as live.
$repo = Join-Path $root 'f12'
New-Repo $repo
$key = ((& git -C $repo rev-parse --show-toplevel) -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
# Our own process: alive, but it started long BEFORE this ledger row claims the run began.
$row = [ordered]@{
    run_id = 'pidreuse'; pid = $PID; launcher_pid = $PID
    worktree = $repo; worktree_key = $key
    spec = 's'; task = 'ghost'; phase = 'build'
    started = (Get-Date).ToUniversalTime().AddHours(1).ToString('o')   # row "started" AFTER the process did
    status = 'running'
}
try {
    Add-Content -Path $ledger -Value ($row | ConvertTo-Json -Compress) -Encoding UTF8
    & $scopeCheck -Snapshot -Worktree $repo -Task 'mine' -Authorized @('src/a.py') *> $null
    'stray' | Out-File -Encoding ascii (Join-Path $repo 'src/rogue.py')
    & $scopeCheck -Check -Worktree $repo -Task 'mine' -Authorized @('src/a.py') *> $null
    Assert-Ok ($LASTEXITCODE -eq 1) 'a real stray is DETECTED' "exit $LASTEXITCODE (want 1)"
    Assert-Ok (Test-Path (Join-Path $repo 'src/rogue.py')) '  ...and left in the tree, not destroyed' 'reported only'
} finally {
    $kept = [System.IO.File]::ReadAllLines($ledger) | Where-Object { $_ -notmatch 'pidreuse' }
    [System.IO.File]::WriteAllLines($ledger, [string[]]$kept, [System.Text.UTF8Encoding]::new($false))
}

Write-Host "`n--- #5  a scope result must NOT swallow the `blocked` hard stop ---" -ForegroundColor Cyan
# The coder says "blocked"; the scope check also fires. The old code overwrote status with
# 'scope-violation' and exited 65 -- so the host read "reverted, carry on" and committed
# code the coder had never verified.
$repo = Join-Path $root 'f5'
New-Repo $repo
$env:FAKE_CODEX_REPO = $repo
$env:FAKE_CODEX_STATUS = 'blocked'
$env:FAKE_CODEX_NO_REPORT = '0'
Push-Location $repo; $sha = (git rev-parse HEAD); Pop-Location
& $dispatch -Spec 'f5' -Task 't' -Phase 'build' -Worktree $repo -BaseSha $sha -Prompt 'go' `
    -Authorized @('src/a.py') `
    -CodexExecutable 'powershell.exe' `
    -CodexExecutableArgumentPrefix @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeCodex) *> $null
Assert-Ok ($LASTEXITCODE -eq 67) 'blocked + scope violation still exits 67, not 65' "exit $LASTEXITCODE (want 67)"
Remove-Item Env:\FAKE_CODEX_STATUS, Env:\FAKE_CODEX_NO_REPORT, Env:\FAKE_CODEX_REPO -ErrorAction SilentlyContinue

Write-Host "`n--- #11  two runs must not collide on one report file ---" -ForegroundColor Cyan
# spec=a-b/task=c and spec=a/task=b-c both produced codex-a-b-c.final. And the dispatcher DELETED any
# pre-existing report at launch -- so one run could destroy another's live verdict.
$repo = Join-Path $root 'f11'
New-Repo $repo
Push-Location $repo; $sha = (git rev-parse HEAD); Pop-Location
$env:FAKE_CODEX_REPO = $repo; $env:FAKE_CODEX_STATUS = 'done'; $env:FAKE_CODEX_NO_REPORT = '0'
$before = @(Get-ChildItem $env:TEMP -Filter 'codex-a*-*.final' -ErrorAction SilentlyContinue).Count
& $dispatch -Spec 'a-b' -Task 'c' -Phase 'build' -Worktree $repo -BaseSha $sha -Prompt 'go' -SkipScopeCheck `
    -CodexExecutable 'powershell.exe' -CodexExecutableArgumentPrefix @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeCodex) *> $null
& $dispatch -Spec 'a' -Task 'b-c' -Phase 'build' -Worktree $repo -BaseSha $sha -Prompt 'go' -SkipScopeCheck `
    -CodexExecutable 'powershell.exe' -CodexExecutableArgumentPrefix @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeCodex) *> $null
$after = @(Get-ChildItem $env:TEMP -Filter 'codex-a*-*.final' -ErrorAction SilentlyContinue).Count
Assert-Ok (($after - $before) -ge 2) 'the two ambiguous spec/task pairs wrote SEPARATE reports' "$($after - $before) new report(s)"
Remove-Item Env:\FAKE_CODEX_STATUS, Env:\FAKE_CODEX_NO_REPORT, Env:\FAKE_CODEX_REPO -ErrorAction SilentlyContinue

Write-Host "`n--- #10  tree-pin is WIRED IN: a read-only gate voids a moved tree ---" -ForegroundColor Cyan
# tree-pin used to be invoked by nothing at all -- it existed only as an instruction in SKILL.md.
$repo = Join-Path $root 'f10'
New-Repo $repo
Push-Location $repo; $sha = (git rev-parse HEAD); Pop-Location
# The fake coder WRITES to the tree; under a read-only review gate that must void the verdict.
$env:FAKE_CODEX_REPO = $repo; $env:FAKE_CODEX_STATUS = 'done'; $env:FAKE_CODEX_NO_REPORT = '0'
& $dispatch -Spec 'f10' -Task 'rev' -Phase 'review' -Worktree $repo -BaseSha $sha -Prompt 'review it' `
    -Sandbox 'read-only' -SkipScopeCheck `
    -CodexExecutable 'powershell.exe' -CodexExecutableArgumentPrefix @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeCodex) *> $null
Assert-Ok ($LASTEXITCODE -eq 69) 'a review whose tree moved returns VOID (69), not its verdict' "exit $LASTEXITCODE (want 69)"
Remove-Item Env:\FAKE_CODEX_STATUS, Env:\FAKE_CODEX_NO_REPORT, Env:\FAKE_CODEX_REPO -ErrorAction SilentlyContinue

Write-Host "`n--- #13  a misattributed revert must be RECOVERABLE (quarantine, never destroy) ---" -ForegroundColor Cyan
# Live, 2026-07-14: a background PLANNING agent was writing docs/drafts/ while a Codex dispatch ran.
# Its drafts were clean at snapshot, dirty at check, and unauthorized -- so the scope check deleted
# them. Untracked, no git object, gone. The check can never enumerate every writer, so being wrong
# has to be survivable: it quarantines before it removes.
$repo = Join-Path $root 'f13'
New-Repo $repo
# docs/ must be TRACKED, as it is in a real repo -- otherwise git collapses the whole tree to
# `?? docs/`, which the check already skips because its own state dir lives under docs/progress.
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'docs') | Out-Null
Push-Location $repo
'readme' | Out-File -Encoding ascii docs/README.md
git add docs/README.md; git commit -q -m docs
Pop-Location
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'docs/drafts') | Out-Null
& $scopeCheck -Snapshot -Worktree $repo -Task 'q' -Authorized @('src/a.py') *> $null
# A background agent (NOT the coder, NOT in the ledger) writes a draft mid-dispatch.
'precious draft the agent is still writing' | Out-File -Encoding ascii (Join-Path $repo 'docs/drafts/durability-1.md')
Add-Content (Join-Path $repo 'src/a.py') 'coder, in scope'
& $scopeCheck -Check -Worktree $repo -Task 'q' -Authorized @('src/a.py') *> $null

# Quarantine is moot: the check does not remove anything at all now, so the agent's draft is simply
# never touched. The strongest possible outcome, and it needs no machinery to hold.
$draft = Join-Path $repo 'docs/drafts/durability-1.md'
Assert-Ok (Test-Path $draft) "a background agent's draft is NOT destroyed" 'still in the tree'
if (Test-Path $draft) {
    Assert-Ok (((Get-Content $draft -Raw) -match 'precious draft')) '  ...with its content intact' 'byte-for-byte'
}
Assert-Ok ($LASTEXITCODE -eq 1) '  ...and it IS reported as out-of-scope' "exit $LASTEXITCODE (want 1)"

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'ALL REVIEW-FINDING REGRESSIONS PASS.' -ForegroundColor Green
    exit 0
}
Write-Host "$failures FAILURE(S)" -ForegroundColor Red
exit 1
