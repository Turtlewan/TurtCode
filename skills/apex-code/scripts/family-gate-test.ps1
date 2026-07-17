[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$gatePath = Join-Path -Path $PSScriptRoot -ChildPath 'apex-family-gate.ps1'
$fixturePath = Join-Path -Path $env:TEMP -ChildPath ("apex-family-gate-test-{0}.jsonl" -f [Guid]::NewGuid().ToString('N'))
$suiteExitCode = 1

function New-FixtureRow {
    param(
        [Parameter(Mandatory = $true)][string]$Spec,
        [Parameter(Mandatory = $true)][string]$Task,
        [Parameter(Mandatory = $true)][string]$WorktreeKey,
        [Parameter(Mandatory = $true)][string]$Phase,
        [AllowEmptyString()][string]$RunId = '',
        [AllowEmptyString()][string]$BuilderFamily = '',
        [AllowEmptyString()][string]$ReviewerFamily = '',
        [AllowEmptyString()][string]$ReviewedRunId = '',
        [bool]$Attended = $false,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Started
    )

    [pscustomobject][ordered]@{
        spec = $Spec
        task = $Task
        worktree_key = $WorktreeKey
        phase = $Phase
        run_id = $RunId
        builder_family = $BuilderFamily
        reviewer_family = $ReviewerFamily
        reviewed_run_id = $ReviewedRunId
        attended = $Attended
        status = $Status
        started = $Started
    }
}

function New-TestCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$ExpectedExitCode,
        [Parameter(Mandatory = $true)][object[]]$Rows
    )

    [pscustomobject]@{
        Name = $Name
        ExpectedExitCode = $ExpectedExitCode
        Spec = "family-gate-test/$Name"
        Task = "task-$Name"
        WorktreeKey = "worktree-$Name"
        Rows = $Rows
    }
}

try {
    if (-not (Test-Path -LiteralPath $gatePath -PathType Leaf)) {
        throw "Gate script was not found at '$gatePath'."
    }

    $cases = @(
        New-TestCase -Name 'cross-family-bound' -ExpectedExitCode 0 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/cross-family-bound' -Task 'task-cross-family-bound' -WorktreeKey 'worktree-cross-family-bound' -Phase 'build' -RunId 'build-cross-family' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-01T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/cross-family-bound' -Task 'task-cross-family-bound' -WorktreeKey 'worktree-cross-family-bound' -Phase 'review' -RunId 'review-cross-family' -BuilderFamily '' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-cross-family' -Attended $false -Status 'done' -Started '2026-01-01T00:01:00Z'
        )
        New-TestCase -Name 'same-family-no-human' -ExpectedExitCode 12 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/same-family-no-human' -Task 'task-same-family-no-human' -WorktreeKey 'worktree-same-family-no-human' -Phase 'build' -RunId 'build-same-family' -BuilderFamily 'anthropic' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-02T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/same-family-no-human' -Task 'task-same-family-no-human' -WorktreeKey 'worktree-same-family-no-human' -Phase 'review' -RunId 'review-same-family' -BuilderFamily '' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-same-family' -Attended $false -Status 'done' -Started '2026-01-02T00:01:00Z'
        )
        New-TestCase -Name 'human-review-bound' -ExpectedExitCode 0 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/human-review-bound' -Task 'task-human-review-bound' -WorktreeKey 'worktree-human-review-bound' -Phase 'build' -RunId 'build-human-bound' -BuilderFamily 'anthropic' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-03T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/human-review-bound' -Task 'task-human-review-bound' -WorktreeKey 'worktree-human-review-bound' -Phase 'review' -RunId 'review-human-same-family' -BuilderFamily '' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-human-bound' -Attended $false -Status 'done' -Started '2026-01-03T00:01:00Z'
            New-FixtureRow -Spec 'family-gate-test/human-review-bound' -Task 'task-human-review-bound' -WorktreeKey 'worktree-human-review-bound' -Phase 'human-review' -RunId 'human-review-bound' -BuilderFamily '' -ReviewerFamily '' -ReviewedRunId 'build-human-bound' -Attended $true -Status 'done' -Started '2026-01-03T00:02:00Z'
        )
        New-TestCase -Name 'stale-review-of-earlier-build' -ExpectedExitCode 12 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/stale-review-of-earlier-build' -Task 'task-stale-review-of-earlier-build' -WorktreeKey 'worktree-stale-review-of-earlier-build' -Phase 'build' -RunId 'build-stale-earlier' -BuilderFamily 'anthropic' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-04T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/stale-review-of-earlier-build' -Task 'task-stale-review-of-earlier-build' -WorktreeKey 'worktree-stale-review-of-earlier-build' -Phase 'review' -RunId 'review-stale-earlier' -BuilderFamily '' -ReviewerFamily 'openai' -ReviewedRunId 'build-stale-earlier' -Attended $false -Status 'done' -Started '2026-01-04T00:01:00Z'
            New-FixtureRow -Spec 'family-gate-test/stale-review-of-earlier-build' -Task 'task-stale-review-of-earlier-build' -WorktreeKey 'worktree-stale-review-of-earlier-build' -Phase 'build' -RunId 'build-stale-later' -BuilderFamily 'anthropic' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-04T01:00:00Z'
        )
        New-TestCase -Name 'unbound-review' -ExpectedExitCode 12 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/unbound-review' -Task 'task-unbound-review' -WorktreeKey 'worktree-unbound-review' -Phase 'build' -RunId 'build-unbound' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'success' -Started '2026-01-05T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/unbound-review' -Task 'task-unbound-review' -WorktreeKey 'worktree-unbound-review' -Phase 'review' -RunId 'review-unbound' -BuilderFamily '' -ReviewerFamily 'anthropic' -ReviewedRunId 'some-other-build' -Attended $false -Status 'done' -Started '2026-01-05T00:01:00Z'
        )
        New-TestCase -Name 'failed-attempt-build-ignored' -ExpectedExitCode 12 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/failed-attempt-build-ignored' -Task 'task-failed-attempt-build-ignored' -WorktreeKey 'worktree-failed-attempt-build-ignored' -Phase 'build' -RunId 'build-failed-attempt' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'failed' -Started '2026-01-06T01:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/failed-attempt-build-ignored' -Task 'task-failed-attempt-build-ignored' -WorktreeKey 'worktree-failed-attempt-build-ignored' -Phase 'build' -RunId 'build-done-attempt' -BuilderFamily 'anthropic' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done_with_concerns' -Started '2026-01-06T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/failed-attempt-build-ignored' -Task 'task-failed-attempt-build-ignored' -WorktreeKey 'worktree-failed-attempt-build-ignored' -Phase 'review' -RunId 'review-done-attempt' -BuilderFamily '' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-done-attempt' -Attended $false -Status 'done' -Started '2026-01-06T00:01:00Z'
        )
        New-TestCase -Name 'crashed-reviewer' -ExpectedExitCode 12 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/crashed-reviewer' -Task 'task-crashed-reviewer' -WorktreeKey 'worktree-crashed-reviewer' -Phase 'build' -RunId 'build-crashed-reviewer' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'adopted-done' -Started '2026-01-07T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/crashed-reviewer' -Task 'task-crashed-reviewer' -WorktreeKey 'worktree-crashed-reviewer' -Phase 'review' -RunId 'review-crashed' -BuilderFamily '' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-crashed-reviewer' -Attended $false -Status 'failed' -Started '2026-01-07T00:01:00Z'
        )
        New-TestCase -Name 'unattended-human' -ExpectedExitCode 12 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/unattended-human' -Task 'task-unattended-human' -WorktreeKey 'worktree-unattended-human' -Phase 'build' -RunId 'build-unattended-human' -BuilderFamily 'anthropic' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-08T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/unattended-human' -Task 'task-unattended-human' -WorktreeKey 'worktree-unattended-human' -Phase 'human-review' -RunId 'human-review-unattended' -BuilderFamily '' -ReviewerFamily '' -ReviewedRunId 'build-unattended-human' -Attended $false -Status 'done' -Started '2026-01-08T00:01:00Z'
        )
        New-TestCase -Name 'unknown-reviewer-family' -ExpectedExitCode 12 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/unknown-reviewer-family' -Task 'task-unknown-reviewer-family' -WorktreeKey 'worktree-unknown-reviewer-family' -Phase 'build' -RunId 'build-unknown-reviewer' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-09T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/unknown-reviewer-family' -Task 'task-unknown-reviewer-family' -WorktreeKey 'worktree-unknown-reviewer-family' -Phase 'review' -RunId 'review-unknown-family' -BuilderFamily '' -ReviewerFamily 'unknown' -ReviewedRunId 'build-unknown-reviewer' -Attended $false -Status 'done' -Started '2026-01-09T00:01:00Z'
        )
        New-TestCase -Name 'empty-selected-run_id' -ExpectedExitCode 13 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/empty-selected-run_id' -Task 'task-empty-selected-run_id' -WorktreeKey 'worktree-empty-selected-run_id' -Phase 'build' -RunId '   ' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-10T00:00:00Z'
        )
        New-TestCase -Name 'unknown-builder-family' -ExpectedExitCode 13 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/unknown-builder-family' -Task 'task-unknown-builder-family' -WorktreeKey 'worktree-unknown-builder-family' -Phase 'build' -RunId 'build-unknown-builder' -BuilderFamily 'unknown' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-11T00:00:00Z'
        )
        New-TestCase -Name 'only-non-terminal' -ExpectedExitCode 13 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/only-non-terminal' -Task 'task-only-non-terminal' -WorktreeKey 'worktree-only-non-terminal' -Phase 'build' -RunId 'build-running' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'running' -Started '2026-01-12T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/only-non-terminal' -Task 'task-only-non-terminal' -WorktreeKey 'worktree-only-non-terminal' -Phase 'build' -RunId 'build-stalled' -BuilderFamily 'anthropic' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'stalled' -Started '2026-01-12T00:01:00Z'
            New-FixtureRow -Spec 'family-gate-test/only-non-terminal' -Task 'task-only-non-terminal' -WorktreeKey 'worktree-only-non-terminal' -Phase 'build' -RunId 'build-recorded' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'recorded' -Started '2026-01-12T00:02:00Z'
            New-FixtureRow -Spec 'family-gate-test/only-non-terminal' -Task 'task-only-non-terminal' -WorktreeKey 'worktree-only-non-terminal' -Phase 'build' -RunId 'build-failed' -BuilderFamily 'anthropic' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'failed' -Started '2026-01-12T00:03:00Z'
            New-FixtureRow -Spec 'family-gate-test/only-non-terminal' -Task 'task-only-non-terminal' -WorktreeKey 'worktree-only-non-terminal' -Phase 'build' -RunId 'build-blocked' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'blocked' -Started '2026-01-12T00:04:00Z'
        )
    )

    $fixtureRows = @($cases | ForEach-Object { $_.Rows })
    $jsonLines = @($fixtureRows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 4 })
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllLines($fixturePath, [string[]]$jsonLines, $utf8NoBom)

    Write-Output "Using one shared fixture ledger under TEMP with unique spec, task, and worktree_key values per case."
    Write-Output "Fixture ledger: $fixturePath"

    $failures = @()
    foreach ($case in $cases) {
        $gateOutput = @(
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gatePath `
                -Spec $case.Spec `
                -Task $case.Task `
                -WorktreeKey $case.WorktreeKey `
                -LedgerPath $fixturePath 2>&1
        )
        $actualExitCode = $LASTEXITCODE

        if ($actualExitCode -eq $case.ExpectedExitCode) {
            Write-Output ("PASS {0} -- expected {1}, got {2}" -f $case.Name, $case.ExpectedExitCode, $actualExitCode)
        }
        else {
            $failure = [pscustomobject]@{
                Name = $case.Name
                Expected = $case.ExpectedExitCode
                Actual = $actualExitCode
                Output = ($gateOutput -join [Environment]::NewLine)
            }
            $failures += $failure
            Write-Output ("FAIL {0} -- expected {1}, got {2}" -f $case.Name, $case.ExpectedExitCode, $actualExitCode)
            if (-not [string]::IsNullOrWhiteSpace($failure.Output)) {
                Write-Output ("  Gate output: {0}" -f $failure.Output)
            }
        }
    }

    if ($failures.Count -gt 0) {
        Write-Output ("FAILED -- {0} of {1} family gate cases failed." -f $failures.Count, $cases.Count)
        $suiteExitCode = 1
    }
    else {
        Write-Output ("PASS -- all {0} family gate cases passed." -f $cases.Count)
        $suiteExitCode = 0
    }
}
catch {
    Write-Output ("FATAL -- family gate test suite could not complete: {0}" -f $_.Exception.Message)
    $suiteExitCode = 1
}
finally {
    if (Test-Path -LiteralPath $fixturePath -PathType Leaf) {
        try {
            Remove-Item -LiteralPath $fixturePath -Force -ErrorAction Stop
        }
        catch {
            Write-Output ("FATAL -- could not remove temporary fixture ledger: {0}" -f $_.Exception.Message)
            $suiteExitCode = 1
        }
    }
}

exit $suiteExitCode
