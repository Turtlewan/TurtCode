# Does the dispatcher route on the CODER'S REPORT, or on the exit code?
#
# The real Codex exits 0 while its own `.final` says `"status": "blocked"`. On cap-deps-1b
# (2026-07-14) that unread `blocked` -- "the sandbox can no longer launch helpers, so implementation
# cannot be inspected, corrected, or verified" -- was committed, and the next spec was built on top
# of it. Every case below exits the fake coder with 0. Only the report differs.

$ErrorActionPreference = 'Stop'

$fakeCodex = Join-Path $PSScriptRoot 'dispatch-test-fakecodex.ps1'
$dispatch = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
$root = Join-Path $env:TEMP 'apex-verdict-test'

# status | no-report | expected dispatcher exit | what it means
$cases = @(
    @{ Status = 'done'; NoReport = $false; Expect = 0; Means = 'clean pass' }
    @{ Status = 'blocked'; NoReport = $false; Expect = 67; Means = 'HARD STOP (cap-deps-1b)' }
    @{ Status = 'done_with_concerns'; NoReport = $false; Expect = 68; Means = 'finished, flagged doubts' }
    @{ Status = 'done'; NoReport = $true; Expect = 67; Means = 'exit 0, NO report -> blocked' }
)

$failures = 0
foreach ($case in $cases) {
    $repo = Join-Path $root ("r-" + $case.Status + "-" + $case.NoReport)
    if (Test-Path $repo) { Remove-Item -Recurse -Force $repo }
    New-Item -ItemType Directory -Force -Path (Join-Path $repo 'src') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $repo 'docs') | Out-Null

    Push-Location $repo
    git init -q
    git config user.email 't@t.t'; git config user.name 't'
    'orig' | Out-File -Encoding ascii src/a.py
    'HOST' | Out-File -Encoding ascii docs/status.md
    git add -A; git commit -q -m init
    $baseSha = (git rev-parse HEAD)
    Pop-Location

    $env:FAKE_CODEX_REPO = $repo
    $env:FAKE_CODEX_STATUS = $case.Status
    $env:FAKE_CODEX_NO_REPORT = if ($case.NoReport) { '1' } else { '0' }

    & $dispatch `
        -Spec 'verdict' -Task ('t-' + $case.Status) -Phase 'build' -Worktree $repo -BaseSha $baseSha `
        -Prompt 'Implement it.' `
        -SkipScopeCheck `
        -CodexExecutable 'powershell.exe' `
        -CodexExecutableArgumentPrefix @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeCodex) `
        *> $null

    $actual = $LASTEXITCODE
    $ok = ($actual -eq $case.Expect)
    if (-not $ok) { $failures += 1 }

    $label = "report=$($case.Status)$(if ($case.NoReport) { ' (no report)' })"
    $line = "  {0} {1,-34} coder exited 0, dispatcher exited {2,-3} (want {3,-3}) -- {4}" -f `
    $(if ($ok) { 'ok  ' } else { 'FAIL' }), $label, $actual, $case.Expect, $case.Means
    Write-Host $line -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}

Remove-Item Env:\FAKE_CODEX_STATUS, Env:\FAKE_CODEX_NO_REPORT, Env:\FAKE_CODEX_REPO -ErrorAction SilentlyContinue

Write-Host ''
if ($failures -eq 0) {
    Write-Host "ALL $($cases.Count) VERDICT CASES PASS -- the report is the verdict, not the exit code." -ForegroundColor Green
    exit 0
}
Write-Host "$failures FAILURE(S)" -ForegroundColor Red
exit 1
