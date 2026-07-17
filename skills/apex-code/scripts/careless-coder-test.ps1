# Round-3 regressions: holes a CARELESS coder falls through.
#
# Threat model, stated once: this harness defends against a coder that WANDERED out of scope, not one
# actively evading the guard. Every case below is something an honest, sloppy coder does by accident
# -- and every one exited 0 before this round.

$ErrorActionPreference = 'Stop'

$SP = $PSScriptRoot
$scopeCheck = Join-Path $SP 'codex-scope-check.ps1'
$dispatch = Join-Path $SP 'codex-dispatch.ps1'
$fakeCodex = Join-Path $SP 'dispatch-test-fakecodex.ps1'
$root = Join-Path $env:TEMP 'apex-careless'
$failures = 0

function Assert-Ok {
    param([bool]$Condition, [string]$Name, [string]$Detail)
    $mark = if ($Condition) { 'ok  ' } else { 'FAIL' }
    $colour = if ($Condition) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-50} {2}" -f $mark, $Name, $Detail) -ForegroundColor $colour
    if (-not $Condition) { $script:failures += 1 }
}

function New-Repo([string]$Path, [switch]$GreenBaseline) {
    if (Test-Path $Path) { Remove-Item -Recurse -Force $Path }
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'src') | Out-Null
    Push-Location $Path
    git init -q
    git config user.email 't@t.t'; git config user.name 't'
    'orig' | Out-File -Encoding ascii src/a.py
    'secret' | Out-File -Encoding ascii src/secret.txt
    'node_modules/' | Out-File -Encoding ascii .gitignore
    if ($GreenBaseline) {
        @(
            '## Verify commands'
            ''
            '```'
            'exit 0'
            '```'
        ) | Out-File -Encoding ascii AGENTS.md
    }
    git add -A; git commit -q -m init
    Pop-Location
}

Write-Host "`n--- #2  a write to a GITIGNORED path is still a write ---" -ForegroundColor Cyan
# `git status --porcelain` cannot see ignored files. A coder authorized for one file could drop a
# script, a hook, or a config into an ignored path and the check saw NOTHING and exited 0.
$repo = Join-Path $root 'ignored'
New-Repo $repo
New-Item -ItemType Directory -Force -Path (Join-Path $repo 'node_modules') | Out-Null
'pre-existing' | Out-File -Encoding ascii (Join-Path $repo 'node_modules/lib.js')
& $scopeCheck -Snapshot -Worktree $repo -Task 't' -Authorized @('src/a.py') *> $null
Add-Content (Join-Path $repo 'src/a.py') 'in scope'
'ROGUE' | Out-File -Encoding ascii (Join-Path $repo 'node_modules/rogue.js')   # ignored, unauthorized
& $scopeCheck -Check -Worktree $repo -Task 't' -Authorized @('src/a.py') *> $null
Assert-Ok ($LASTEXITCODE -ne 0) 'a new file under an IGNORED dir is detected' "exit $LASTEXITCODE (want non-zero)"

Write-Host "`n--- #5  a rename must be judged on BOTH sides ---" -ForegroundColor Cyan
# `git mv secret.txt allowed.txt`: porcelain reports `R secret.txt -> allowed.txt`. Keeping only the
# destination judged it solely on the AUTHORIZED name, so deleting the unauthorized source passed.
$repo = Join-Path $root 'rename'
New-Repo $repo
& $scopeCheck -Snapshot -Worktree $repo -Task 't' -Authorized @('src/a.py') *> $null
Push-Location $repo; git mv src/secret.txt src/a.py -f 2>$null; Pop-Location
& $scopeCheck -Check -Worktree $repo -Task 't' -Authorized @('src/a.py') *> $null
Assert-Ok ($LASTEXITCODE -ne 0) 'renaming an unauthorized file onto an authorized one is caught' "exit $LASTEXITCODE"

Write-Host "`n--- #4  DELETING host work is a change too ---" -ForegroundColor Cyan
# The old loop only walked paths dirty NOW. A path that VANISHES leaves git status entirely -- so a
# coder deleting the host's untracked draft was invisible and the check exited 0.
$repo = Join-Path $root 'deleted'
New-Repo $repo
'the host is still writing this' | Out-File -Encoding ascii (Join-Path $repo 'draft.txt')
& $scopeCheck -Snapshot -Worktree $repo -Task 't' -Authorized @('src/a.py') *> $null
Remove-Item (Join-Path $repo 'draft.txt') -Force        # the coder deletes it
Add-Content (Join-Path $repo 'src/a.py') 'in scope'
& $scopeCheck -Check -Worktree $repo -Task 't' -Authorized @('src/a.py') *> $null
Assert-Ok ($LASTEXITCODE -ne 0) "deleting the host's untracked draft is detected" "exit $LASTEXITCODE"

Write-Host "`n--- #20  an authorized DIRECTORY authorizes its descendants ---" -ForegroundColor Cyan
# Exact-match-only flagged src/a.py as out of scope when the spec authorized `src`. A guard that
# cries wolf on correct behaviour is one people learn to route around.
$repo = Join-Path $root 'dirauth'
New-Repo $repo
& $scopeCheck -Snapshot -Worktree $repo -Task 't' -Authorized @('src') *> $null
Add-Content (Join-Path $repo 'src/a.py') 'legit'
& $scopeCheck -Check -Worktree $repo -Task 't' -Authorized @('src') *> $null
Assert-Ok ($LASTEXITCODE -eq 0) 'editing src/a.py under -Authorized @(src) is IN scope' "exit $LASTEXITCODE (want 0)"

Write-Host "`n--- #9  an unknown gate verdict FAILS CLOSED ---" -ForegroundColor Cyan
# `default { $reportStatus = 'done' }` meant an unrecognised verdict -- or an end-gate returning
# "P1: block handoff" -- came back as SUCCESS. A gate whose unknown states mean "pass" is not a gate.
$repo = Join-Path $root 'verdict'
New-Repo $repo
Push-Location $repo; $sha = (git rev-parse HEAD); Pop-Location
$env:FAKE_CODEX_REPO = $repo; $env:FAKE_CODEX_NO_REPORT = '0'
$env:FAKE_CODEX_STATUS = 'done'
$env:FAKE_CODEX_VERDICT = 'P1: block handoff'      # schema-valid, unrecognised
& $dispatch -Spec 'v' -Task 'gate' -Phase 'review' -Worktree $repo -BaseSha $sha -Prompt 'go' `
    -Schema review -SkipScopeCheck -NoTreePin -NoTreePinReason 'verdict-only review fixture' `
    -CodexExecutable 'powershell.exe' `
    -CodexExecutableArgumentPrefix @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeCodex) *> $null
Assert-Ok ($LASTEXITCODE -eq 67) 'an unrecognised verdict blocks (67), never passes' "exit $LASTEXITCODE (want 67)"
Remove-Item Env:\FAKE_CODEX_VERDICT, Env:\FAKE_CODEX_STATUS, Env:\FAKE_CODEX_NO_REPORT, Env:\FAKE_CODEX_REPO -ErrorAction SilentlyContinue

Write-Host "`n--- #1  A CLEAN, IN-SCOPE BUILD MUST EXIT 0 ---" -ForegroundColor Cyan
# The harness used to write its own dispatch log INTO the target repo. Once the scope check's
# self-exemption was (rightly) removed, that log -- created, snapshotted, then streamed into --
# read as an unauthorized write, so EVERY CLEAN BUILD EXITED 65. The harness must not write into the
# tree it is judging. Nothing in the suite caught it: the one test that would have was already
# expecting a 65 for a different reason. This is the test that would have.
$repo = Join-Path $root 'clean'
New-Repo $repo -GreenBaseline
Push-Location $repo; $sha = (git rev-parse HEAD); Pop-Location
$env:FAKE_CODEX_REPO = $repo
$env:FAKE_CODEX_STATUS = 'done'
$env:FAKE_CODEX_NO_REPORT = '0'
$env:FAKE_CODEX_INSCOPE_ONLY = '1'      # write ONLY the authorized file
& $dispatch -Spec 'clean' -Task 'c1' -Phase 'build' -Worktree $repo -BaseSha $sha -Prompt 'go' `
    -Authorized @('src/a.py') `
    -CodexExecutable 'powershell.exe' `
    -CodexExecutableArgumentPrefix @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeCodex) *> $null
Assert-Ok ($LASTEXITCODE -eq 0) 'a clean in-scope build exits 0' "exit $LASTEXITCODE (want 0)"
Assert-Ok (-not (Test-Path (Join-Path $repo 'docs'))) 'the harness wrote NOTHING into the worktree' 'no docs/progress/'
Remove-Item Env:\FAKE_CODEX_INSCOPE_ONLY, Env:\FAKE_CODEX_STATUS, Env:\FAKE_CODEX_NO_REPORT, Env:\FAKE_CODEX_REPO -ErrorAction SilentlyContinue

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'ALL CARELESS-CODER CASES PASS.' -ForegroundColor Green
    exit 0
}
Write-Host "$failures FAILURE(S)" -ForegroundColor Red
exit 1
