[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$gatePath = Join-Path -Path $PSScriptRoot -ChildPath 'apex-family-gate.ps1'
$fixturePath = Join-Path -Path $env:TEMP -ChildPath ("apex-family-gate-test-{0}.jsonl" -f [Guid]::NewGuid().ToString('N'))
$legacyReserializedPath = Join-Path -Path $env:TEMP -ChildPath ("apex-family-gate-legacy-reserialized-{0}.jsonl" -f [Guid]::NewGuid().ToString('N'))
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
        [Parameter(Mandatory = $true)][string]$Started,
        [System.Collections.IDictionary]$ExtraFields
    )

    $row = [ordered]@{
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

    if ($PSBoundParameters.ContainsKey('ExtraFields')) {
        foreach ($key in $ExtraFields.Keys) {
            $row[$key] = $ExtraFields[$key]
        }
    }

    [pscustomobject]$row
}

function ConvertTo-FixtureJsonLines {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows
    )

    @($Rows | ForEach-Object {
        if ($_ -is [string]) {
            $_
        }
        else {
            $_ | ConvertTo-Json -Compress -Depth 4
        }
    })
}

function New-TestCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$ExpectedExitCode,
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [string]$ExpectedOutputSubstring = ''
    )

    [pscustomobject]@{
        Name = $Name
        ExpectedExitCode = $ExpectedExitCode
        Spec = "family-gate-test/$Name"
        Task = "task-$Name"
        WorktreeKey = "worktree-$Name"
        Rows = $Rows
        ExpectedOutputSubstring = $ExpectedOutputSubstring
    }
}

try {
    if (-not (Test-Path -LiteralPath $gatePath -PathType Leaf)) {
        throw "Gate script was not found at '$gatePath'."
    }

    $legacyCases = @(
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
        # The prior exit-12 expectation encoded the fail-open fallback to an older successful build.
        New-TestCase -Name 'failed-attempt-build-ignored' -ExpectedExitCode 13 -Rows @(
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
        # Closes the fail-open where a newer running build was hidden behind an older reviewed build.
        New-TestCase -Name 'newest-non-terminal-masking' -ExpectedExitCode 13 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/newest-non-terminal-masking' -Task 'task-newest-non-terminal-masking' -WorktreeKey 'worktree-newest-non-terminal-masking' -Phase 'build' -RunId 'build-mask-old' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-13T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/newest-non-terminal-masking' -Task 'task-newest-non-terminal-masking' -WorktreeKey 'worktree-newest-non-terminal-masking' -Phase 'review' -RunId 'review-mask-old' -BuilderFamily '' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-mask-old' -Attended $false -Status 'done' -Started '2026-01-13T00:01:00Z'
            New-FixtureRow -Spec 'family-gate-test/newest-non-terminal-masking' -Task 'task-newest-non-terminal-masking' -WorktreeKey 'worktree-newest-non-terminal-masking' -Phase 'build' -RunId 'build-mask-new-running' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'running' -Started '2026-01-13T01:00:00Z'
        )
        # Closes the fail-open where a query-matching row without phase vanished before selection.
        New-TestCase -Name 'missing-required-field' -ExpectedExitCode 13 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/missing-required-field' -Task 'task-missing-required-field' -WorktreeKey 'worktree-missing-required-field' -Phase 'build' -RunId 'build-missing-old' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-14T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/missing-required-field' -Task 'task-missing-required-field' -WorktreeKey 'worktree-missing-required-field' -Phase 'review' -RunId 'review-missing-old' -BuilderFamily '' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-missing-old' -Attended $false -Status 'done' -Started '2026-01-14T00:01:00Z'
            [pscustomobject][ordered]@{
                spec = 'family-gate-test/missing-required-field'
                task = 'task-missing-required-field'
                worktree_key = 'worktree-missing-required-field'
                run_id = 'build-missing-phase'
                builder_family = 'openai'
                status = 'running'
                started = '2026-01-14T01:00:00Z'
            }
        )
        # Closes the fail-open where a malformed spec-scoped line was silently skipped.
        New-TestCase -Name 'malformed-newest-row' -ExpectedExitCode 13 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/malformed-newest-row' -Task 'task-malformed-newest-row' -WorktreeKey 'worktree-malformed-newest-row' -Phase 'build' -RunId 'build-malformed-old' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-15T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/malformed-newest-row' -Task 'task-malformed-newest-row' -WorktreeKey 'worktree-malformed-newest-row' -Phase 'review' -RunId 'review-malformed-old' -BuilderFamily '' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-malformed-old' -Attended $false -Status 'done' -Started '2026-01-15T00:01:00Z'
            '{"spec":"family-gate-test/malformed-newest-row","task":"task-malformed-newest-row"'
        )
        # Closes the fail-open where an invalid timestamp sorted behind an older reviewed build.
        New-TestCase -Name 'invalid-started' -ExpectedExitCode 13 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/invalid-started' -Task 'task-invalid-started' -WorktreeKey 'worktree-invalid-started' -Phase 'build' -RunId 'build-invalid-old' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-16T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/invalid-started' -Task 'task-invalid-started' -WorktreeKey 'worktree-invalid-started' -Phase 'review' -RunId 'review-invalid-old' -BuilderFamily '' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-invalid-old' -Attended $false -Status 'done' -Started '2026-01-16T00:01:00Z'
            New-FixtureRow -Spec 'family-gate-test/invalid-started' -Task 'task-invalid-started' -WorktreeKey 'worktree-invalid-started' -Phase 'build' -RunId 'build-invalid-new' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started 'invalid'
        )
        # Closes the correctness defect where Windows path casing drift produced a false no-build result.
        New-TestCase -Name 'casing-drift' -ExpectedExitCode 0 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/casing-drift' -Task 'task-casing-drift' -WorktreeKey 'WORKTREE-CASING-DRIFT' -Phase 'build' -RunId 'build-casing' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-17T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/casing-drift' -Task 'task-casing-drift' -WorktreeKey 'WORKTREE-CASING-DRIFT' -Phase 'review' -RunId 'review-casing' -BuilderFamily '' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-casing' -Attended $false -Status 'done' -Started '2026-01-17T00:01:00Z'
        )
        # Locks equal-timestamp selection to append order rather than a random run_id ordering.
        New-TestCase -Name 'equal-started-append-order' -ExpectedExitCode 12 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/equal-started-append-order' -Task 'task-equal-started-append-order' -WorktreeKey 'worktree-equal-started-append-order' -Phase 'build' -RunId 'zzzz-older-build' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-18T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/equal-started-append-order' -Task 'task-equal-started-append-order' -WorktreeKey 'worktree-equal-started-append-order' -Phase 'review' -RunId 'review-equal-old' -BuilderFamily '' -ReviewerFamily 'anthropic' -ReviewedRunId 'zzzz-older-build' -Attended $false -Status 'done' -Started '2026-01-18T00:01:00Z'
            New-FixtureRow -Spec 'family-gate-test/equal-started-append-order' -Task 'task-equal-started-append-order' -WorktreeKey 'worktree-equal-started-append-order' -Phase 'build' -RunId 'aaaa-newer-build' -BuilderFamily 'openai' -ReviewerFamily '' -ReviewedRunId '' -Attended $false -Status 'done' -Started '2026-01-18T00:00:00Z'
        )
    )

    $newCases = @(
        New-TestCase -Name 'tree-moved-true-review' -ExpectedExitCode 12 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/tree-moved-true-review' -Task 'task-tree-moved-true-review' -WorktreeKey 'worktree-tree-moved-true-review' -Phase 'build' -RunId 'build-tree-moved-true' -BuilderFamily 'openai' -Status 'done' -Started '2026-01-19T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/tree-moved-true-review' -Task 'task-tree-moved-true-review' -WorktreeKey 'worktree-tree-moved-true-review' -Phase 'review' -RunId 'review-tree-moved-true' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-tree-moved-true' -Status 'done' -Started '2026-01-19T00:01:00Z' -ExtraFields ([ordered]@{ tree_moved = $true })
        )
        New-TestCase -Name 'scope-violation-true-review' -ExpectedExitCode 12 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/scope-violation-true-review' -Task 'task-scope-violation-true-review' -WorktreeKey 'worktree-scope-violation-true-review' -Phase 'build' -RunId 'build-scope-violation-true' -BuilderFamily 'openai' -Status 'done' -Started '2026-01-20T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/scope-violation-true-review' -Task 'task-scope-violation-true-review' -WorktreeKey 'worktree-scope-violation-true-review' -Phase 'review' -RunId 'review-scope-violation-true' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-scope-violation-true' -Status 'done' -Started '2026-01-20T00:01:00Z' -ExtraFields ([ordered]@{ scopeViolation = $true })
        )
        New-TestCase -Name 'encoding-violation-true-review' -ExpectedExitCode 0 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/encoding-violation-true-review' -Task 'task-encoding-violation-true-review' -WorktreeKey 'worktree-encoding-violation-true-review' -Phase 'build' -RunId 'build-encoding-violation-true' -BuilderFamily 'openai' -Status 'done' -Started '2026-01-21T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/encoding-violation-true-review' -Task 'task-encoding-violation-true-review' -WorktreeKey 'worktree-encoding-violation-true-review' -Phase 'review' -RunId 'review-encoding-violation-true' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-encoding-violation-true' -Status 'done' -Started '2026-01-21T00:01:00Z' -ExtraFields ([ordered]@{ encoding_violation = $true })
        )
        New-TestCase -Name 'void-markers-false-review' -ExpectedExitCode 0 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/void-markers-false-review' -Task 'task-void-markers-false-review' -WorktreeKey 'worktree-void-markers-false-review' -Phase 'build' -RunId 'build-void-markers-false' -BuilderFamily 'openai' -Status 'done' -Started '2026-01-22T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/void-markers-false-review' -Task 'task-void-markers-false-review' -WorktreeKey 'worktree-void-markers-false-review' -Phase 'review' -RunId 'review-void-markers-false' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-void-markers-false' -Status 'done' -Started '2026-01-22T00:01:00Z' -ExtraFields ([ordered]@{ tree_moved = $false; scopeViolation = $false })
        )
        New-TestCase -Name 'tree-moved-null-review' -ExpectedExitCode 0 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/tree-moved-null-review' -Task 'task-tree-moved-null-review' -WorktreeKey 'worktree-tree-moved-null-review' -Phase 'build' -RunId 'build-tree-moved-null' -BuilderFamily 'openai' -Status 'done' -Started '2026-01-23T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/tree-moved-null-review' -Task 'task-tree-moved-null-review' -WorktreeKey 'worktree-tree-moved-null-review' -Phase 'review' -RunId 'review-tree-moved-null' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-tree-moved-null' -Status 'done' -Started '2026-01-23T00:01:00Z' -ExtraFields ([ordered]@{ tree_moved = $null })
        )
        New-TestCase -Name 'scope-violation-null-review' -ExpectedExitCode 0 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/scope-violation-null-review' -Task 'task-scope-violation-null-review' -WorktreeKey 'worktree-scope-violation-null-review' -Phase 'build' -RunId 'build-scope-violation-null' -BuilderFamily 'openai' -Status 'done' -Started '2026-01-24T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/scope-violation-null-review' -Task 'task-scope-violation-null-review' -WorktreeKey 'worktree-scope-violation-null-review' -Phase 'review' -RunId 'review-scope-violation-null' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-scope-violation-null' -Status 'done' -Started '2026-01-24T00:01:00Z' -ExtraFields ([ordered]@{ scopeViolation = $null })
        )
        New-TestCase -Name 'marked-plus-clean-review' -ExpectedExitCode 0 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/marked-plus-clean-review' -Task 'task-marked-plus-clean-review' -WorktreeKey 'worktree-marked-plus-clean-review' -Phase 'build' -RunId 'build-marked-plus-clean' -BuilderFamily 'openai' -Status 'done' -Started '2026-01-25T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/marked-plus-clean-review' -Task 'task-marked-plus-clean-review' -WorktreeKey 'worktree-marked-plus-clean-review' -Phase 'review' -RunId 'review-marked' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-marked-plus-clean' -Status 'done' -Started '2026-01-25T00:01:00Z' -ExtraFields ([ordered]@{ tree_moved = $true })
            New-FixtureRow -Spec 'family-gate-test/marked-plus-clean-review' -Task 'task-marked-plus-clean-review' -WorktreeKey 'worktree-marked-plus-clean-review' -Phase 'review' -RunId 'review-clean' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-marked-plus-clean' -Status 'done' -Started '2026-01-25T00:02:00Z'
        )
        New-TestCase -Name 'marked-plus-human-review' -ExpectedExitCode 0 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/marked-plus-human-review' -Task 'task-marked-plus-human-review' -WorktreeKey 'worktree-marked-plus-human-review' -Phase 'build' -RunId 'build-marked-plus-human' -BuilderFamily 'openai' -Status 'done' -Started '2026-01-26T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/marked-plus-human-review' -Task 'task-marked-plus-human-review' -WorktreeKey 'worktree-marked-plus-human-review' -Phase 'review' -RunId 'review-marked-human-case' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-marked-plus-human' -Status 'done' -Started '2026-01-26T00:01:00Z' -ExtraFields ([ordered]@{ tree_moved = $true })
            New-FixtureRow -Spec 'family-gate-test/marked-plus-human-review' -Task 'task-marked-plus-human-review' -WorktreeKey 'worktree-marked-plus-human-review' -Phase 'human-review' -RunId 'human-review-after-marked' -ReviewedRunId 'build-marked-plus-human' -Attended $true -Status 'done' -Started '2026-01-26T00:02:00Z'
        )
        New-TestCase -Name 'digest-mismatch' -ExpectedExitCode 12 -ExpectedOutputSubstring "tree digest is missing, unverifiable, or disagrees with the build's" -Rows @(
            New-FixtureRow -Spec 'family-gate-test/digest-mismatch' -Task 'task-digest-mismatch' -WorktreeKey 'worktree-digest-mismatch' -Phase 'build' -RunId 'build-digest-mismatch' -BuilderFamily 'openai' -Status 'done' -Started '2026-01-28T00:00:00Z' -ExtraFields ([ordered]@{ end_tree_digest = 'digest-build' })
            New-FixtureRow -Spec 'family-gate-test/digest-mismatch' -Task 'task-digest-mismatch' -WorktreeKey 'worktree-digest-mismatch' -Phase 'review' -RunId 'review-digest-mismatch' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-digest-mismatch' -Status 'done' -Started '2026-01-28T00:01:00Z' -ExtraFields ([ordered]@{ reviewed_tree_digest = 'digest-review' })
        )
        New-TestCase -Name 'build-digest-empty' -ExpectedExitCode 12 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/build-digest-empty' -Task 'task-build-digest-empty' -WorktreeKey 'worktree-build-digest-empty' -Phase 'build' -RunId 'build-digest-empty' -BuilderFamily 'openai' -Status 'done' -Started '2026-01-29T00:00:00Z' -ExtraFields ([ordered]@{ end_tree_digest = '' })
            New-FixtureRow -Spec 'family-gate-test/build-digest-empty' -Task 'task-build-digest-empty' -WorktreeKey 'worktree-build-digest-empty' -Phase 'review' -RunId 'review-build-digest-empty' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-digest-empty' -Status 'done' -Started '2026-01-29T00:01:00Z' -ExtraFields ([ordered]@{ reviewed_tree_digest = 'digest-match' })
        )
        New-TestCase -Name 'review-digest-whitespace' -ExpectedExitCode 12 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/review-digest-whitespace' -Task 'task-review-digest-whitespace' -WorktreeKey 'worktree-review-digest-whitespace' -Phase 'build' -RunId 'build-review-digest-whitespace' -BuilderFamily 'openai' -Status 'done' -Started '2026-01-30T00:00:00Z' -ExtraFields ([ordered]@{ end_tree_digest = 'digest-match' })
            New-FixtureRow -Spec 'family-gate-test/review-digest-whitespace' -Task 'task-review-digest-whitespace' -WorktreeKey 'worktree-review-digest-whitespace' -Phase 'review' -RunId 'review-digest-whitespace' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-review-digest-whitespace' -Status 'done' -Started '2026-01-30T00:01:00Z' -ExtraFields ([ordered]@{ reviewed_tree_digest = '   ' })
        )
        New-TestCase -Name 'build-digest-unverifiable' -ExpectedExitCode 12 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/build-digest-unverifiable' -Task 'task-build-digest-unverifiable' -WorktreeKey 'worktree-build-digest-unverifiable' -Phase 'build' -RunId 'build-digest-unverifiable' -BuilderFamily 'openai' -Status 'done' -Started '2026-01-31T00:00:00Z' -ExtraFields ([ordered]@{ end_tree_digest = 'unverifiable' })
            New-FixtureRow -Spec 'family-gate-test/build-digest-unverifiable' -Task 'task-build-digest-unverifiable' -WorktreeKey 'worktree-build-digest-unverifiable' -Phase 'review' -RunId 'review-build-digest-unverifiable' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-digest-unverifiable' -Status 'done' -Started '2026-01-31T00:01:00Z' -ExtraFields ([ordered]@{ reviewed_tree_digest = 'digest-match' })
        )
        New-TestCase -Name 'review-digest-unverifiable' -ExpectedExitCode 12 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/review-digest-unverifiable' -Task 'task-review-digest-unverifiable' -WorktreeKey 'worktree-review-digest-unverifiable' -Phase 'build' -RunId 'build-review-digest-unverifiable' -BuilderFamily 'openai' -Status 'done' -Started '2026-02-01T00:00:00Z' -ExtraFields ([ordered]@{ end_tree_digest = 'digest-match' })
            New-FixtureRow -Spec 'family-gate-test/review-digest-unverifiable' -Task 'task-review-digest-unverifiable' -WorktreeKey 'worktree-review-digest-unverifiable' -Phase 'review' -RunId 'review-digest-unverifiable' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-review-digest-unverifiable' -Status 'done' -Started '2026-02-01T00:01:00Z' -ExtraFields ([ordered]@{ reviewed_tree_digest = 'unverifiable' })
        )
        New-TestCase -Name 'digest-match' -ExpectedExitCode 0 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/digest-match' -Task 'task-digest-match' -WorktreeKey 'worktree-digest-match' -Phase 'build' -RunId 'build-digest-match' -BuilderFamily 'openai' -Status 'done' -Started '2026-02-02T00:00:00Z' -ExtraFields ([ordered]@{ end_tree_digest = 'digest-equal' })
            New-FixtureRow -Spec 'family-gate-test/digest-match' -Task 'task-digest-match' -WorktreeKey 'worktree-digest-match' -Phase 'review' -RunId 'review-digest-match' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-digest-match' -Status 'done' -Started '2026-02-02T00:01:00Z' -ExtraFields ([ordered]@{ reviewed_tree_digest = 'digest-equal' })
        )
        New-TestCase -Name 'review-digest-absent' -ExpectedExitCode 0 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/review-digest-absent' -Task 'task-review-digest-absent' -WorktreeKey 'worktree-review-digest-absent' -Phase 'build' -RunId 'build-review-digest-absent' -BuilderFamily 'openai' -Status 'done' -Started '2026-02-03T00:00:00Z' -ExtraFields ([ordered]@{ end_tree_digest = 'digest-build-only' })
            New-FixtureRow -Spec 'family-gate-test/review-digest-absent' -Task 'task-review-digest-absent' -WorktreeKey 'worktree-review-digest-absent' -Phase 'review' -RunId 'review-digest-absent' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-review-digest-absent' -Status 'done' -Started '2026-02-03T00:01:00Z'
        )
        New-TestCase -Name 'build-digest-absent' -ExpectedExitCode 0 -Rows @(
            New-FixtureRow -Spec 'family-gate-test/build-digest-absent' -Task 'task-build-digest-absent' -WorktreeKey 'worktree-build-digest-absent' -Phase 'build' -RunId 'build-digest-absent' -BuilderFamily 'openai' -Status 'done' -Started '2026-02-04T00:00:00Z'
            New-FixtureRow -Spec 'family-gate-test/build-digest-absent' -Task 'task-build-digest-absent' -WorktreeKey 'worktree-build-digest-absent' -Phase 'review' -RunId 'review-build-digest-absent' -ReviewerFamily 'anthropic' -ReviewedRunId 'build-digest-absent' -Status 'done' -Started '2026-02-04T00:01:00Z' -ExtraFields ([ordered]@{ reviewed_tree_digest = 'digest-review-only' })
        )
    )
    $cases = @($legacyCases) + @($newCases)

    $legacyFixtureRows = @($legacyCases | ForEach-Object { $_.Rows })
    $legacyJsonLines = ConvertTo-FixtureJsonLines -Rows $legacyFixtureRows
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllLines($legacyReserializedPath, [string[]]$legacyJsonLines, $utf8NoBom)

    $failures = @()
    $expectedLegacySerializationHash = '5B5802C3ABC47D948F583A2D930946BCF718037AB69502616161631829AF13F4'
    $actualLegacySerializationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $legacyReserializedPath).Hash
    if ($actualLegacySerializationHash -ceq $expectedLegacySerializationHash) {
        Write-Output "PASS legacy-byte-compat -- reserialization matches the canonical SHA-256."
    }
    else {
        $failures += [pscustomobject]@{
            Name = 'legacy-byte-compat'
            Expected = $expectedLegacySerializationHash
            Actual = $actualLegacySerializationHash
            Output = ''
        }
        Write-Output ("FAIL legacy-byte-compat -- expected SHA-256 {0}, got {1}" -f $expectedLegacySerializationHash, $actualLegacySerializationHash)
    }

    $markers = @('tree_moved', 'scopeViolation', 'encoding_violation')
    $states = @(
        [pscustomobject]@{ Name = 'true'; Value = $true; Expected = 'true' }
        [pscustomobject]@{ Name = 'false'; Value = $false; Expected = 'false' }
        [pscustomobject]@{ Name = 'null'; Value = $null; Expected = 'null' }
    )
    foreach ($marker in $markers) {
        foreach ($state in $states) {
            $extraFields = [ordered]@{}
            $extraFields[$marker] = $state.Value
            $emissionRow = New-FixtureRow -Spec 'family-gate-test/emission' -Task 'task-emission' -WorktreeKey 'worktree-emission' -Phase 'review' -Status 'done' -Started '2026-01-27T00:00:00Z' -ExtraFields $extraFields
            $normalizedJson = (($emissionRow | ConvertTo-Json -Compress -Depth 4) -replace '\s', '')
            $expectedFragment = '"{0}":{1}' -f $marker, $state.Expected
            if ($normalizedJson.Contains($expectedFragment)) {
                Write-Output ("PASS emission-{0}-{1} -- contains {2}" -f $marker, $state.Name, $expectedFragment)
            }
            else {
                $failures += [pscustomobject]@{ Name = "emission-$marker-$($state.Name)"; Expected = $expectedFragment; Actual = $normalizedJson; Output = '' }
            }
        }

        $omittedRow = New-FixtureRow -Spec 'family-gate-test/emission' -Task 'task-emission' -WorktreeKey 'worktree-emission' -Phase 'review' -Status 'done' -Started '2026-01-27T00:00:00Z'
        $normalizedOmittedJson = (($omittedRow | ConvertTo-Json -Compress -Depth 4) -replace '\s', '')
        if (-not $normalizedOmittedJson.Contains(('"{0}":' -f $marker))) {
            Write-Output ("PASS emission-{0}-omitted -- key is absent" -f $marker)
        }
        else {
            $failures += [pscustomobject]@{ Name = "emission-$marker-omitted"; Expected = 'key absent'; Actual = $normalizedOmittedJson; Output = '' }
        }
    }

    $fixtureRows = @($cases | ForEach-Object { $_.Rows })
    # Preserve intentionally malformed raw lines so the gate's scoped parse-failure behavior is exercised.
    $jsonLines = ConvertTo-FixtureJsonLines -Rows $fixtureRows
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllLines($fixturePath, [string[]]$jsonLines, $utf8NoBom)

    Write-Output "Using one shared fixture ledger under TEMP with unique spec, task, and worktree_key values per case."
    Write-Output "Fixture ledger: $fixturePath"

    foreach ($case in $cases) {
        $gateOutput = @(
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gatePath `
                -Spec $case.Spec `
                -Task $case.Task `
                -WorktreeKey $case.WorktreeKey `
                -LedgerPath $fixturePath 2>&1
        )
        $actualExitCode = $LASTEXITCODE
        $gateOutputText = $gateOutput -join [Environment]::NewLine
        $outputMatches = [string]::IsNullOrEmpty($case.ExpectedOutputSubstring) -or
            ($gateOutputText.IndexOf($case.ExpectedOutputSubstring, [StringComparison]::Ordinal) -ge 0)

        if (($actualExitCode -eq $case.ExpectedExitCode) -and $outputMatches) {
            Write-Output ("PASS {0} -- expected {1}, got {2}" -f $case.Name, $case.ExpectedExitCode, $actualExitCode)
        }
        else {
            $failure = [pscustomobject]@{
                Name = $case.Name
                Expected = $case.ExpectedExitCode
                Actual = $actualExitCode
                Output = $gateOutputText
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
    if (Test-Path -LiteralPath $legacyReserializedPath -PathType Leaf) {
        try {
            Remove-Item -LiteralPath $legacyReserializedPath -Force -ErrorAction Stop
        }
        catch {
            Write-Output ("FATAL -- could not remove temporary legacy reserialization: {0}" -f $_.Exception.Message)
            $suiteExitCode = 1
        }
    }
}

exit $suiteExitCode
