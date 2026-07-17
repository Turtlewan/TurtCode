<#
.SYNOPSIS
Validates that a completed build has independent review recorded in the run ledger.

.DESCRIPTION
Exit contract: 0 means the selected build has a bound cross-family review or a
bound attended human review; 12 means a valid selected build exists but neither
acceptable review exists; 13 means the gate cannot vouch because no valid
selected build exists. Unknown or empty families and empty run_id values can
NEVER satisfy this gate under any circumstance.

This script reads recorded FACTS bound to the selected build through
reviewed_run_id. It is never a live self-check and never trusts a caller-chosen
diff or SHA. This prevents a motivated caller from pointing the gate at a
different build's review to launder a same-family completion.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Spec,

    [Parameter(Mandatory = $true)]
    [string]$Task,

    [Parameter(Mandatory = $true)]
    [string]$WorktreeKey,

    [string]$LedgerPath = ''
)

$terminalSuccessStatuses = @(
    'done',
    'done_with_concerns',
    'success',
    'adopted-done'
)

if ([string]::IsNullOrWhiteSpace($LedgerPath)) {
    if (-not [string]::IsNullOrWhiteSpace($env:APEX_STATE_DIR)) {
        $stateRoot = $env:APEX_STATE_DIR
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $stateRoot = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'apex'
    }
    else {
        $stateRoot = Join-Path -Path $env:TEMP -ChildPath 'apex'
    }

    $LedgerPath = Join-Path -Path $stateRoot -ChildPath 'progress\codex-run-ledger.jsonl'
}

if (-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) {
    Write-Output "Cannot vouch: ledger file was not found at '$LedgerPath'."
    exit 13
}

$matchingRows = @()

try {
    foreach ($line in [System.IO.File]::ReadLines($LedgerPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $row = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }

        if (($row.spec -ceq $Spec) -and
            ($row.task -ceq $Task) -and
            ($row.worktree_key -ceq $WorktreeKey)) {
            $matchingRows += $row
        }
    }
}
catch {
    Write-Output "Cannot vouch: ledger file could not be read at '$LedgerPath'."
    exit 13
}

$terminalRows = @(
    $matchingRows | Where-Object {
        $terminalSuccessStatuses -ccontains [string]$_.status
    }
)

$buildRows = @(
    $terminalRows | Where-Object {
        $_.phase -ceq 'build'
    }
)

if ($buildRows.Count -eq 0) {
    Write-Output 'Cannot vouch: no terminal-success build was found for the requested spec, task, and worktree.'
    exit 13
}

$selectedBuild = $buildRows |
    Sort-Object -Property {
        $parsedStarted = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse(
                [string]$_.started,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
                [ref]$parsedStarted)) {
            $parsedStarted.UtcDateTime.Ticks
        }
        else {
            [DateTimeOffset]::MinValue.UtcDateTime.Ticks
        }
    } |
    Select-Object -Last 1

$selRunId = [string]$selectedBuild.run_id
$builderFamily = [string]$selectedBuild.builder_family

if ([string]::IsNullOrWhiteSpace($selRunId)) {
    Write-Output 'Cannot vouch: the selected terminal-success build has an empty run_id.'
    exit 13
}

if (($builderFamily -cne 'openai') -and ($builderFamily -cne 'anthropic')) {
    Write-Output "Cannot vouch: the selected terminal-success build has unknown or invalid builder family '$builderFamily'."
    exit 13
}

$hasCrossFamilyReview = $false
$hasAttendedHumanReview = $false

foreach ($row in $terminalRows) {
    $reviewedRunId = [string]$row.reviewed_run_id
    $isBoundToSelectedBuild = (-not [string]::IsNullOrWhiteSpace($reviewedRunId)) -and
        ($reviewedRunId -ceq $selRunId)

    if (-not $isBoundToSelectedBuild) {
        continue
    }

    if ($row.phase -ceq 'review') {
        $reviewerFamily = [string]$row.reviewer_family
        $isKnownReviewerFamily = ($reviewerFamily -ceq 'openai') -or
            ($reviewerFamily -ceq 'anthropic')

        if ($isKnownReviewerFamily -and ($reviewerFamily -cne $builderFamily)) {
            $hasCrossFamilyReview = $true
        }
    }
    elseif (($row.phase -ceq 'human-review') -and
        ($row.attended -is [bool]) -and
        ($row.attended -eq $true)) {
        $hasAttendedHumanReview = $true
    }
}

if ($hasCrossFamilyReview -or $hasAttendedHumanReview) {
    exit 0
}

Write-Output "Refused: selected build '$selRunId' has builder family '$builderFamily' but no bound cross-family review or attended human review."
exit 12
