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
$requiredFields = @('phase', 'status', 'started', 'spec', 'task', 'worktree_key')

try {
    $lineIndex = 0
    foreach ($line in [System.IO.File]::ReadLines($LedgerPath)) {
        $lineIndex++
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $row = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            # Fail closed only for spec-scoped corruption; otherwise one bad spec would poison every gate.
            # Residual: a corrupt line containing this spec name blocks its gate until the ledger is cleaned.
            if ($line.IndexOf($Spec, [StringComparison]::Ordinal) -ge 0) {
                Write-Output "Cannot vouch: malformed ledger row $lineIndex may belong to spec '$Spec'."
                exit 13
            }
            continue
        }

        $propertyNames = @($row.PSObject.Properties.Name)
        if (($propertyNames -cnotcontains 'spec') -or ($row.spec -cne $Spec)) {
            continue
        }

        # Missing identity fields on a spec-scoped row are ambiguous, so do not let an older build mask it.
        if ($propertyNames -cnotcontains 'task') {
            Write-Output "Cannot vouch: ledger row $lineIndex for spec '$Spec' is missing required field 'task'."
            exit 13
        }
        if ($row.task -cne $Task) {
            continue
        }
        if ($propertyNames -cnotcontains 'worktree_key') {
            Write-Output "Cannot vouch: ledger row $lineIndex for spec '$Spec' and task '$Task' is missing required field 'worktree_key'."
            exit 13
        }

        # Windows path casing drift must still match; the former -ceq caused spurious no-build failures.
        if ([string]$row.worktree_key -ine $WorktreeKey) {
            continue
        }

        # Validate before phase/status filtering so a malformed newest row cannot disappear behind an older build.
        foreach ($requiredField in $requiredFields) {
            if (($propertyNames -cnotcontains $requiredField) -or
                [string]::IsNullOrWhiteSpace([string]$row.$requiredField)) {
                Write-Output "Cannot vouch: matching ledger row $lineIndex is missing or empty required field '$requiredField'."
                exit 13
            }
        }

        $matchingRows += [pscustomobject]@{
            Row = $row
            LedgerLineIndex = $lineIndex
            StartedTicks = $null
        }
    }
}
catch {
    Write-Output "Cannot vouch: ledger file could not be read at '$LedgerPath'."
    exit 13
}

# Select from every build attempt first; filtering success earlier let a newer failed/running build be masked.
$buildRows = @(
    $matchingRows | Where-Object {
        $_.Row.phase -ceq 'build'
    }
)

if ($buildRows.Count -eq 0) {
    Write-Output 'Cannot vouch: no build was found for the requested spec, task, and worktree.'
    exit 13
}

foreach ($buildRow in $buildRows) {
    $parsedStarted = [DateTimeOffset]::MinValue
    # Invalid timestamps used to sort first and let an older reviewed build win; reject them explicitly.
    if (-not [DateTimeOffset]::TryParse(
            [string]$buildRow.Row.started,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
            [ref]$parsedStarted)) {
        Write-Output "Cannot vouch: matching build on ledger row $($buildRow.LedgerLineIndex) has an invalid started value."
        exit 13
    }
    $buildRow.StartedTicks = $parsedStarted.UtcDateTime.Ticks
}

# Ledger append order breaks timestamp ties; a random run_id could otherwise select an older attempt.
$selectedBuildRecord = $buildRows |
    Sort-Object -Property StartedTicks, LedgerLineIndex |
    Select-Object -Last 1
$selectedBuild = $selectedBuildRecord.Row

# The newest attempt governs. Never fall back from a non-terminal/failed build to an older reviewed build.
if ($terminalSuccessStatuses -cnotcontains [string]$selectedBuild.status) {
    Write-Output "Cannot vouch: newest build '$([string]$selectedBuild.run_id)' is not terminal-success (status '$([string]$selectedBuild.status)')."
    exit 13
}

$terminalRows = @(
    $matchingRows | Where-Object {
        $terminalSuccessStatuses -ccontains [string]$_.Row.status
    } | ForEach-Object {
        $_.Row
    }
)

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
