# Durable Codex dispatcher (ADR-033).
#
# Delivers a dispatch pack to `codex exec`, explicitly closes the child's stdin,
# and records the run in a durable JSONL ledger.  A no-output watchdog flags a
# stalled run but deliberately does not terminate it; process ownership remains
# with the caller.  `-Adopt` prints the newest matching run's worktree and diff.

[CmdletBinding()]
param(
    [string]$Spec,
    [string]$SpecSourcePath,
    [string]$Task,
    [string]$Worktree,
    [string]$BaseSha,
    [string]$Phase,
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')]
    [string]$Effort = 'medium',
    [ValidateRange(1, 16)]
    [int]$MachineCeiling = 4,
    [ValidateRange(1, 2147483647)]
    [int]$NoOutputTimeoutMin = 8,
    [switch]$Adopt,
    # Declares that this invocation owns the supplied linked worktree's lifecycle.
    [switch]$OwnedWorktree,
    # Reads and prints actionable creator-cleanup obligations without dispatching.
    [switch]$ListObligations,
    [string]$RunId,
    [switch]$Attended,
    [string]$AbandonRunId,
    [string]$AbandonReason,
    # The spec's '## Files to change' list. Given, the scope lock is ENFORCED (snapshot before
    # launch, diff + path-scoped revert after exit). Omitted, it is prose only -- and prose has
    # already failed: Codex has written outside a scope lock it was explicitly given.
    [string[]]$Authorized = @(),
    [switch]$SkipScopeCheck,
    # Deliberate escape: disables the scope lock; the reason is recorded in the ledger row.
    [switch]$ScopeUnlocked,
    # Records why the deliberate escape disabled the scope lock in the ledger row.
    [string]$ScopeUnlockedReason,
    # Two Codex workers in one working tree is a data race with a delete in it (see the guard below).
    # Wave-parallel dispatch requires ONE WORKTREE PER CONCURRENT TASK. This overrides the refusal
    # only when the caller also records why the unsafe sharing is deliberate.
    [switch]$AllowSharedWorktree,
    # Records why the live-worker refusal was deliberately overridden in the ledger row.
    [string]$AllowSharedWorktreeReason,
    # Read-only gates (review, end-gate) auto-pin the tree and VOID their verdict if it moves under
    # them. This disables that only when the caller records why the verdict may proceed unpinned.
    [switch]$NoTreePin,
    # Records why the read-only tree pin was deliberately disabled in the ledger row.
    [string]$NoTreePinReason,
    # Bootstrap/emergency escape: bypass the dispatch pre-flight, recorded loudly and in the ledger row.
    [switch]$SkipBaselineCheck,
    # -CriticalFilesConfirmed is set ONLY by the apex-code skill's Layer A step after a real attended
    # human confirmation -- a spec's `## Permissions` text never sets it.
    # -CriticalFilesConfirmedNote carries a free-text who/when string for the ledger.
    # -CriticalFilesScript and -TreePinScript are test-only overrides; empty values resolve the
    # corresponding helpers beside $PSScriptRoot so tests can dogfood fail-closed paths.
    # -ReviewedRunId is the run_id of the BUILD that a REVIEW dispatch is reviewing.
    [switch]$CriticalFilesConfirmed,
    [string]$CriticalFilesConfirmedNote,
    [string]$CriticalFilesScript,
    [string]$TreePinScript,
    [string]$ReviewedRunId,
    [string]$Prompt,
    # Selects the --output-schema codex is constrained to. A review/end-gate pass returns
    # findings, not a build completion; constraining it to the build schema (whose
    # additionalProperties is false and which has no `findings` property) makes its entire
    # result structurally inexpressible and silently drops it.
    [ValidateSet('completion', 'endgate', 'review')]
    [string]$Schema = 'completion',
    # A review/end-gate pass must not be able to edit the tree it is judging. The wrapper was
    # built for build dispatches, so it hardcoded workspace-write; the standing Sol end-gate
    # inherited it and has been running with repo write access despite the runbook's
    # "never auto-edits anything" guarantee.
    [ValidateSet('workspace-write', 'read-only')]
    [string]$Sandbox = 'workspace-write',
    [string]$ScratchDirectory = $env:TEMP,
    [string]$CodexExecutable = 'codex',
    [string[]]$CodexExecutableArgumentPrefix = @()
)

$ErrorActionPreference = 'Stop'
$script:pendingExitCode = 'unknown'
$script:abandonRequested = $PSBoundParameters.ContainsKey('AbandonRunId')
$script:attendedTelemetry = $(if ($PSBoundParameters.ContainsKey('Attended')) { [bool]$Attended } else { $null })

if (-not $ListObligations) {
# Exit 74 = caller-contract error, refused before any I/O; no state dir touched.
# -Phase cannot use ValidateSet: Windows PowerShell rejects an unknown value before this body runs
# and reports exit 1, which is already the wrapper's child-failure meaning.
if (-not $script:abandonRequested -and @('build', 'review') -cnotcontains $Phase) {
    Write-Host "[dispatch] REFUSED (exit 74): -Phase must be exactly 'build' or 'review' (got '$Phase')" -ForegroundColor Red
    exit 74
}
if ($script:abandonRequested -and [string]::IsNullOrWhiteSpace($AbandonReason)) {
    Write-Host '[dispatch] REFUSED (exit 74): -AbandonRunId requires a non-empty -AbandonReason' -ForegroundColor Red
    exit 74
}
if ($script:abandonRequested -and
        (-not $PSBoundParameters.ContainsKey('Attended') -or -not [bool]$Attended)) {
    Write-Host '[dispatch] REFUSED (exit 83): -AbandonRunId requires -Attended:$true' -ForegroundColor Red
    exit 83
}
if ($script:abandonRequested -and $Adopt) {
    Write-Host '[dispatch] REFUSED (exit 74): -AbandonRunId and -Adopt are mutually exclusive' -ForegroundColor Red
    exit 74
}
if ($ScopeUnlocked -and $Authorized.Count -gt 0) {
    Write-Host '[dispatch] REFUSED (exit 74): -ScopeUnlocked and -Authorized are mutually exclusive — pass one, not both' -ForegroundColor Red
    exit 74
}
if ($ScopeUnlocked -and [string]::IsNullOrWhiteSpace($ScopeUnlockedReason)) {
    Write-Host '[dispatch] REFUSED (exit 74): -ScopeUnlocked requires -ScopeUnlockedReason' -ForegroundColor Red
    exit 74
}
if ($AllowSharedWorktree -and [string]::IsNullOrWhiteSpace($AllowSharedWorktreeReason)) {
    Write-Host '[dispatch] REFUSED (exit 74): -AllowSharedWorktree requires -AllowSharedWorktreeReason' -ForegroundColor Red
    exit 74
}
if ($NoTreePin -and [string]::IsNullOrWhiteSpace($NoTreePinReason)) {
    Write-Host '[dispatch] REFUSED (exit 74): -NoTreePin requires -NoTreePinReason' -ForegroundColor Red
    exit 74
}

# Digest binding belongs only to review/read-only dispatches; post-hoc classification belongs only
# to scope-armed build/workspace-write dispatches. A build cannot opt into the review-side binding.
if (-not $Adopt -and $Phase -ceq 'build' -and $ReviewedRunId) {
    Write-Host '[dispatch] REFUSED (exit 74): -ReviewedRunId is meaningless for -Phase build' -ForegroundColor Red
    exit 74
}

# Phase, report schema, and sandbox are one caller contract. A build-shaped review can manufacture a
# review row without a verdict; a review-shaped build can manufacture a successful builder row while
# skipping the build gates. Refuse either report shape before shared state is even initialized, and
# preserve the existing safety normalization that forces a real review into read-only. Adoption
# replays an existing row and therefore does not create either kind of reservation.
if (-not $Adopt -and $Phase -ceq 'build' -and
        (($Schema -cne 'completion') -or ($Sandbox -cne 'workspace-write'))) {
    Write-Host "[dispatch] REFUSED (exit 74): -Phase build requires -Schema completion and -Sandbox workspace-write (got '$Schema/$Sandbox')" -ForegroundColor Red
    exit 74
}
if (-not $Adopt -and $Phase -ceq 'review' -and
        (@('review', 'endgate') -cnotcontains $Schema)) {
    Write-Host "[dispatch] REFUSED (exit 74): -Phase review requires -Schema review or endgate (got '$Schema')" -ForegroundColor Red
    exit 74
}
if (-not $Adopt -and $Phase -ceq 'review' -and $Sandbox -cne 'read-only') {
    Write-Host "[dispatch] -Phase/-Schema '$Phase/$Schema' forces -Sandbox read-only (a reviewer must not edit what it judges)." -ForegroundColor DarkGray
    $Sandbox = 'read-only'
}
}

function Get-UtcTimestamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

# One canonical value serves the main completion path and the adoption mirror. The durable ledger
# field is the contractual evidence; Write-Host below is only a best-effort human display whose
# rendering may wrap independently of the stored value.
$emptyConcernBlockerText = 'Coder reported done_with_concerns and named no unresolved item. Either report done, or name a concern.'

# Residual risk: when the ledger does not exist, apex-ledger-append.ps1 may create it first with
# Add-Content -Encoding utf8, which emits a BOM on Windows PowerShell 5.1. Readers tolerate that
# leading BOM; the hook is intentionally out of scope here.
function Write-Utf8NoBomText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Add-Utf8NoBomText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($Path, $Text, $encoding)
}

function Write-Utf8NoBomLines {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllLines($Path, $Lines, $encoding)
}

function Get-ModelFamily([string]$model) {
    $m = $model.ToLowerInvariant()
    if ($m -match 'codex' -or $m -match '^gpt') { return 'openai' }
    if ($m -match 'opus' -or $m -match 'sonnet' -or $m -match 'haiku' -or $m -match 'claude') { return 'anthropic' }
    return 'unknown'
}

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory)][string]$Value)

    return ($Value -replace '[<>:"/\\|?*]', '_')
}

function Get-SpecFrontmatterValue {
    param([Parameter(Mandatory)][string]$Key)

    # The in-worktree spec is authoritative. -SpecSourcePath is only the documented fallback for a
    # cross-tree dispatch whose spec is not present in the target tree.
    $specPath = Join-Path (Join-Path $Worktree 'docs\changes') "$Spec.md"
    if (-not (Test-Path -LiteralPath $specPath -PathType Leaf)) {
        $specPath = $SpecSourcePath
    }
    if ([string]::IsNullOrWhiteSpace($specPath) -or
            -not (Test-Path -LiteralPath $specPath -PathType Leaf)) {
        return $null
    }

    $lines = [System.IO.File]::ReadAllLines($specPath)
    if ($lines.Count -eq 0 -or $lines[0].Trim() -cne '---') { return $null }

    $frontmatterEnd = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ceq '---') {
            $frontmatterEnd = $i
            break
        }
    }
    if ($frontmatterEnd -lt 0) { return $null }

    $keyPattern = '^(?<indent>\s*)' + [regex]::Escape($Key) + '\s*:(?<value>.*)$'
    for ($i = 1; $i -lt $frontmatterEnd; $i++) {
        if ($lines[$i] -cnotmatch $keyPattern) { continue }

        $indent = $Matches.indent.Length
        $rawValue = ([string]$Matches.value).Trim()
        if ($rawValue.Length -gt 0) {
            if ($rawValue.StartsWith('[')) {
                if (-not $rawValue.EndsWith(']')) {
                    return '__APEX_FRONTMATTER_UNPARSEABLE__'
                }
                $flowBody = $rawValue.Substring(1, $rawValue.Length - 2).Trim()
                if ($flowBody.Length -eq 0) {
                    return ,([string[]]@())
                }
                $flowItems = @()
                foreach ($itemText in $flowBody.Split(',')) {
                    $item = $itemText.Trim()
                    if ($item.Length -eq 0 -or $item -match '[[\]{}]') {
                        return '__APEX_FRONTMATTER_UNPARSEABLE__'
                    }
                    if (($item.StartsWith("'") -and $item.EndsWith("'")) -or
                            ($item.StartsWith('"') -and $item.EndsWith('"'))) {
                        if ($item.Length -lt 2) { return '__APEX_FRONTMATTER_UNPARSEABLE__' }
                        $item = $item.Substring(1, $item.Length - 2)
                    }
                    $flowItems += [string]$item
                }
                return ,([string[]]$flowItems)
            }
            if ($rawValue -match '^[\[{]') {
                return '__APEX_FRONTMATTER_UNPARSEABLE__'
            }
            if (($rawValue.StartsWith("'") -and $rawValue.EndsWith("'")) -or
                    ($rawValue.StartsWith('"') -and $rawValue.EndsWith('"'))) {
                if ($rawValue.Length -lt 2) { return '__APEX_FRONTMATTER_UNPARSEABLE__' }
                $rawValue = $rawValue.Substring(1, $rawValue.Length - 2)
            }
            return [string]$rawValue
        }

        $sequenceItems = @()
        $sawSequenceLine = $false
        for ($j = $i + 1; $j -lt $frontmatterEnd; $j++) {
            $candidate = [string]$lines[$j]
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            $candidateIndent = $candidate.Length - $candidate.TrimStart().Length
            if ($candidateIndent -le $indent) { break }
            $sawSequenceLine = $true
            if ($candidate.Trim() -cnotmatch '^-\s+(?<item>.+)$') {
                return '__APEX_FRONTMATTER_UNPARSEABLE__'
            }
            $sequenceItem = ([string]$Matches.item).Trim()
            if ($sequenceItem.Length -eq 0 -or $sequenceItem -match '^[\[{]') {
                return '__APEX_FRONTMATTER_UNPARSEABLE__'
            }
            if (($sequenceItem.StartsWith("'") -and $sequenceItem.EndsWith("'")) -or
                    ($sequenceItem.StartsWith('"') -and $sequenceItem.EndsWith('"'))) {
                if ($sequenceItem.Length -lt 2) { return '__APEX_FRONTMATTER_UNPARSEABLE__' }
                $sequenceItem = $sequenceItem.Substring(1, $sequenceItem.Length - 2)
            }
            $sequenceItems += [string]$sequenceItem
        }
        if (-not $sawSequenceLine) {
            return '__APEX_FRONTMATTER_UNPARSEABLE__'
        }
        return ,([string[]]$sequenceItems)
    }

    return $null
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    # Quote with the CommandLineToArgvW / CreateProcess backslash rules.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

# The ledger is deliberately GLOBAL (lives beside the dispatcher, not the target repo): -Adopt
# must be able to find a crashed run without knowing in advance which repo it happened in. Each
# dispatch's own log, by contrast, belongs with the repo it built -- so it lives under the
# target -Worktree's own docs\progress, consistent with every other apex-code Codex log.
$dispatcherRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent

# The ledger and the logs live OUTSIDE EVERY REPO -- not merely outside the target repo.
#
# They used to sit under the dispatcher's own checkout (~/.claude/docs/progress/). That is fine until
# the tree being judged IS ~/.claude -- which is exactly what happens when this harness reviews
# itself, and what it has been doing all day. Then the ledger row, the status updates and the log all
# land inside the worktree under scope check, the harness's own writes read as unauthorized ones, and
# a clean authorized build exits 65.
#
# "Outside the target repo" was the wrong rule; it just moved the collision. The rule is: THE HARNESS
# MUST NOT WRITE INTO ANY TREE IT MIGHT JUDGE. A machine-local state directory, belonging to no repo,
# cannot collide with one.
$apexStateRoot = if ($env:APEX_STATE_DIR) { $env:APEX_STATE_DIR }
elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'apex' }
else { Join-Path $env:TEMP 'apex' }

# A caller can point APEX_STATE_DIR (or -ScratchDirectory) INSIDE a repo, which puts the harness's
# own artifacts back into a tree it may be judging -- the exact bug we just spent three rounds
# chasing, reintroduced through a parameter. Refuse it rather than trust the caller to know.
function Assert-NotInsideRepo {
    param([string]$Path, [string]$What)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try { [System.IO.Directory]::CreateDirectory($Path) | Out-Null } catch { return }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $top = (& git -C $Path rev-parse --show-toplevel 2>$null) } catch { $top = $null } finally { $ErrorActionPreference = $previous }
    if ($top) {
        throw "$What resolves inside a git worktree ($top). The harness must never write into a tree it might judge. Point it somewhere outside every repo."
    }
}
Assert-NotInsideRepo -Path $apexStateRoot -What 'The APEX state directory'

# The gate helpers keep their own state (the scope snapshot, the tree pin) and BOTH defaulted to
# $env:TEMP independently. A TEMP that happens to sit inside the worktree therefore put the snapshot
# and the pin straight back into the judged tree -- through the one door the validation above did not
# cover. Give them a validated directory instead of letting them each guess.
$harnessStateDir = Join-Path $apexStateRoot 'gates'
[System.IO.Directory]::CreateDirectory($harnessStateDir) | Out-Null

$ledgerDirectory = Join-Path $apexStateRoot 'progress'
$ledgerPath = Join-Path $ledgerDirectory 'codex-run-ledger.jsonl'

$schemaFile = switch ($Schema) {
    'endgate' { 'afk-endgate-schema.json' }
    'review' { 'codex-review-schema.json' }
    default { 'codex-completion-schema.json' }
}
$schemaPath = Join-Path $dispatcherRoot "skills\apex-code\references\$schemaFile"
$digestScript = if ($TreePinScript) { $TreePinScript } else { Join-Path $PSScriptRoot 'tree-pin.ps1' }
$ledgerMutex = [System.Threading.Mutex]::new($false, 'ApexCodexRunLedger')

function Invoke-WithLedgerLock {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [System.Threading.Mutex]$Mutex = $ledgerMutex
    )

    $acquired = $false
    try {
        try {
            $acquired = $Mutex.WaitOne([TimeSpan]::FromSeconds(30))
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) { throw 'Timed out waiting for the Codex run-ledger lock.' }
        & $Action
    } finally {
        if ($acquired) { $Mutex.ReleaseMutex() }
    }
}

# Carry the existing ledger over once, so -Adopt can still find a run recorded before the move.
# Initialization joins the same mutex protocol as every later ledger read and mutation; otherwise
# two first-use wrappers can race a copy with the capacity scan or with each other.
$legacyLedger = Join-Path (Join-Path $dispatcherRoot 'docs\progress') 'codex-run-ledger.jsonl'
Invoke-WithLedgerLock {
    if ((Test-Path -LiteralPath $legacyLedger) -and -not (Test-Path -LiteralPath $ledgerPath)) {
        [System.IO.Directory]::CreateDirectory($ledgerDirectory) | Out-Null
        Copy-Item -LiteralPath $legacyLedger -Destination $ledgerPath -Force
    }
}

function Invoke-LedgerFileReplace {
    param(
        [Parameter(Mandatory)][string]$TemporaryPath,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$Caller,
        [Parameter(Mandatory)][int]$RowsChanged
    )

    [System.IO.File]::Replace($TemporaryPath, $ledgerPath, $BackupPath)
    if (-not [string]::IsNullOrWhiteSpace($env:APEX_LEDGER_REPLACE_LOG)) {
        $replaceLogDirectory = Split-Path $env:APEX_LEDGER_REPLACE_LOG -Parent
        if (-not [string]::IsNullOrWhiteSpace($replaceLogDirectory)) {
            [System.IO.Directory]::CreateDirectory($replaceLogDirectory) | Out-Null
        }
        Add-Utf8NoBomText -Path $env:APEX_LEDGER_REPLACE_LOG -Text `
            (('{0}|{1}|{2}' -f (Get-UtcTimestamp), $Caller, $RowsChanged) +
                [Environment]::NewLine)
    }
}

function Set-LedgerLines {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Caller,
        [Parameter(Mandatory)][int]$RowsChanged
    )

    $replacementId = [guid]::NewGuid().ToString('N')
    $temporaryPath = "$($ledgerPath).$replacementId.tmp"
    $backupPath = "$($ledgerPath).$replacementId.bak"
    try {
        Write-Utf8NoBomLines -Path $temporaryPath -Lines $Lines
        Invoke-LedgerFileReplace -TemporaryPath $temporaryPath -BackupPath $backupPath `
            -Caller $Caller -RowsChanged $RowsChanged
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
        if (Test-Path -LiteralPath $backupPath) {
            Remove-Item -LiteralPath $backupPath -Force
        }
    }
}

function Add-LedgerRow {
    param(
        [Parameter(Mandatory)][hashtable]$Row,
        [System.Threading.Mutex]$Mutex = $ledgerMutex
    )

    Invoke-WithLedgerLock -Mutex $Mutex {
        [System.IO.Directory]::CreateDirectory($ledgerDirectory) | Out-Null
        $json = $Row | ConvertTo-Json -Compress -Depth 8
        Add-Utf8NoBomText -Path $ledgerPath -Text ($json + [Environment]::NewLine)
    }
}

function Add-LeaseCloseRow {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][AllowNull()][object]$RefusalExit
    )

    $closeRow = [ordered]@{
        run_id = $RunId
        row_kind = 'lease_close'
        status = $Status
        refusal_exit = $RefusalExit
        ended = (Get-UtcTimestamp)
        log_path = $logPath
        effort = $Effort
        attended = $script:attendedTelemetry
    }

    Invoke-WithLedgerLock {
        [System.IO.Directory]::CreateDirectory($ledgerDirectory) | Out-Null
        if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
            foreach ($ledgerLine in [System.IO.File]::ReadAllLines($ledgerPath)) {
                if ([string]::IsNullOrWhiteSpace($ledgerLine)) { continue }
                try { $existingRow = $ledgerLine | ConvertFrom-Json } catch { continue }
                if ([string]$existingRow.run_id -ceq $RunId -and
                        [string]$existingRow.row_kind -ceq [string]$closeRow.row_kind) {
                    throw "Refusing to append a second $([string]$closeRow.row_kind) ledger row for run_id $RunId."
                }
            }
        }
        $ledgerSeparator = ''
        if ((Test-Path -LiteralPath $ledgerPath) -and (Get-Item -LiteralPath $ledgerPath).Length -gt 0) {
            $ledgerText = [System.IO.File]::ReadAllText($ledgerPath)
            if (-not $ledgerText.EndsWith("`n") -and -not $ledgerText.EndsWith("`r")) {
                $ledgerSeparator = [Environment]::NewLine
            }
        }
        Add-Utf8NoBomText -Path $ledgerPath -Text (
            $ledgerSeparator + ($closeRow | ConvertTo-Json -Compress -Depth 8) +
                [Environment]::NewLine)
    }
}

function Get-OpenLeaseRunIds {
    param([AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$LedgerLines)

    $leaseRunIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)
    $closedRunIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal)

    $readLeaseRows = {
        foreach ($line in $LedgerLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $row = $line | ConvertFrom-Json } catch { continue }
            $leaseRunId = [string]$row.run_id
            if ([string]::IsNullOrWhiteSpace($leaseRunId)) { continue }
            if ([string]$row.row_kind -ceq 'lease') {
                [void]$leaseRunIds.Add($leaseRunId)
            }
            elseif ([string]$row.row_kind -ceq 'lease_close') {
                [void]$closedRunIds.Add($leaseRunId)
            }
        }
    }
    if ($PSBoundParameters.ContainsKey('LedgerLines')) {
        & $readLeaseRows
    }
    else {
        Invoke-WithLedgerLock {
            if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { return }
            $LedgerLines = [System.IO.File]::ReadAllLines($ledgerPath)
            & $readLeaseRows
        }
    }

    foreach ($closedRunId in $closedRunIds) {
        [void]$leaseRunIds.Remove($closedRunId)
    }
    return @($leaseRunIds)
}

function Exit-Dispatch([int]$Code) {
    $script:pendingExitCode = $Code
    exit $Code
}

function Update-LedgerRow {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$RowKind,
        [Parameter(Mandatory)][hashtable]$Changes,
        [System.Threading.Mutex]$Mutex = $ledgerMutex
    )

    Invoke-WithLedgerLock -Mutex $Mutex {
        if (-not (Test-Path -LiteralPath $ledgerPath)) {
            throw "Codex run ledger does not exist: $ledgerPath"
        }

        $updated = $false
        $outputLines = foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $row = $line | ConvertFrom-Json
            } catch {
                # The reservation scan already refuses fresh/unknown corruption. A TTL-expired
                # corpse must not make every later update impossible, so preserve its raw bytes while
                # updating a different, parseable row. If the requested row is the damaged one,
                # `$updated` remains false and the operation still fails closed below.
                $line
                continue
            }
            $existingRowKind = if (@($row.PSObject.Properties.Name) -ccontains 'row_kind') {
                [string]$row.row_kind
            } else {
                'dispatch'
            }
            if ($row.run_id -eq $RunId -and $existingRowKind -eq $RowKind) {
                foreach ($change in $Changes.GetEnumerator()) {
                    $row | Add-Member -NotePropertyName $change.Key -NotePropertyValue $change.Value -Force
                }
                $updated = $true
                $row | ConvertTo-Json -Compress -Depth 8
            } else {
                $line
            }
        }

        if (-not $updated) {
            throw "Codex run ledger row not found for run_id $RunId and row_kind $RowKind."
        }

        # A same-directory temporary file plus File.Replace makes a completed
        # status update atomic for readers; the named mutex serializes wrappers.
        Set-LedgerLines -Lines ([string[]]$outputLines) -Caller 'Update-LedgerRow' -RowsChanged 1
    }
}

function Invoke-AbandonRun {
    Write-Host '[dispatch] -AbandonRunId is an ATTENDED-ONLY escape: it waives scope/critical/digest/pin/encoding without running them. An AFK run must park instead.' -ForegroundColor Yellow
    $script:abandonMatch = $null
    Invoke-WithLedgerLock {
        if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) {
            Write-Host "[dispatch] REFUSED (exit 82): run_id '$AbandonRunId' was not found (observed status: not-found)." -ForegroundColor Red
            Exit-Dispatch 82
        }

        $ledgerLines = [System.IO.File]::ReadAllLines($ledgerPath)
        $matches = [System.Collections.Generic.List[object]]::new()
        for ($lineIndex = 0; $lineIndex -lt $ledgerLines.Count; $lineIndex++) {
            $line = $ledgerLines[$lineIndex]
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $candidate = $line | ConvertFrom-Json } catch { continue }
            $candidateRowKind = if (@($candidate.PSObject.Properties.Name) -ccontains 'row_kind') {
                [string]$candidate.row_kind
            }
            else {
                'dispatch'
            }
            if ([string]$candidate.run_id -ceq $AbandonRunId -and
                    @('dispatch', 'lease') -ccontains $candidateRowKind) {
                $matches.Add([pscustomobject]@{
                    Index = $lineIndex
                    Row = $candidate
                    RowKind = $candidateRowKind
                })
            }
        }

        if ($matches.Count -ne 1) {
            $observedStatus = if ($matches.Count -eq 0) { 'not-found' } else { 'ambiguous' }
            Write-Host "[dispatch] REFUSED (exit 82): run_id '$AbandonRunId' cannot be abandoned (observed status: $observedStatus)." -ForegroundColor Red
            Exit-Dispatch 82
        }

        $selected = $matches[0]
        $row = $selected.Row
        $observedStatus = [string]$row.status
        $recoverable = $observedStatus -ceq 'orphaned'
        if (@('leasing', 'running', 'stalled') -ccontains $observedStatus) {
            $recoverable = -not (Test-LedgerRowLive -Row $row)
        }
        if (-not $recoverable) {
            Write-Host "[dispatch] REFUSED (exit 82): run_id '$AbandonRunId' has observed status '$observedStatus' and is not a dead recoverable row." -ForegroundColor Red
            Exit-Dispatch 82
        }

        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & cmd /c exit 99
            $gitStatusLines = @(& git -C ([string]$row.worktree) status --porcelain 2>&1)
            $gitStatusExit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $gitStatusText = ([string[]]$gitStatusLines -join [Environment]::NewLine).Trim()
        if ($gitStatusExit -ne 0 -or -not [string]::IsNullOrWhiteSpace($gitStatusText)) {
            $gitStatusPreview = $gitStatusText
            if ($gitStatusPreview.Length -gt 200) {
                $gitStatusPreview = $gitStatusPreview.Substring(0, 200)
            }
            Write-Host "[dispatch] REFUSED (exit 82): recorded worktree is dirty or unreadable (git exit $gitStatusExit): $gitStatusPreview" -ForegroundColor Red
            Exit-Dispatch 82
        }

        $row | Add-Member -NotePropertyName 'status' -NotePropertyValue 'abandoned-unadopted' -Force
        $row | Add-Member -NotePropertyName 'ended' -NotePropertyValue (Get-UtcTimestamp) -Force
        $row | Add-Member -NotePropertyName 'abandon_reason' -NotePropertyValue $AbandonReason -Force
        $row | Add-Member -NotePropertyName 'waived_gates' `
            -NotePropertyValue @('scope', 'critical', 'digest', 'pin', 'encoding') -Force
        $ledgerLines[$selected.Index] = $row | ConvertTo-Json -Compress -Depth 8
        Set-LedgerLines -Lines ([string[]]$ledgerLines) -Caller 'AbandonRun' -RowsChanged 1
        $script:abandonMatch = $row
    }

    Write-Host ($script:abandonMatch | ConvertTo-Json -Compress -Depth 8)
    exit 0
}

function Get-UnresolvedWorktreeRows {
    param(
        [Parameter(Mandatory)][string]$WorktreeKey,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$LedgerLines,
        [string]$ExcludeRunId
    )

    $openLeaseRunIds = @(Get-OpenLeaseRunIds -LedgerLines $LedgerLines)
    $matches = @()
    foreach ($line in $LedgerLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $row = $line | ConvertFrom-Json } catch { continue }
        $rowStatus = [string]$row.status
        if (@('leasing', 'running', 'stalled', 'adopting', 'orphaned') -cnotcontains $rowStatus) {
            continue
        }
        if ($ExcludeRunId -and [string]$row.run_id -ceq $ExcludeRunId) { continue }
        if ([string]$row.worktree_key -cne $WorktreeKey) { continue }
        if ($rowStatus -ceq 'leasing' -and
                $openLeaseRunIds -cnotcontains [string]$row.run_id) {
            continue
        }
        $matches += $row
    }
    return @($matches)
}

# --- Worktree identity: CANONICAL, never lexical -------------------------------------------------
# Two dispatches into the same tree must recognise each other, or the sibling guards are decorative.
# String comparison cannot do that: `-Worktree .`, `C:\Users\User\.claude`, `c:/users/user/.claude`,
# a junction, and an 8.3 short path are five spellings of one directory. A ledger row written under
# one spelling is invisible to a scan using another -- so the seatbelt lets a second coder launch,
# and the airbag then fails to recognise it and deletes its work. Ask GIT for the identity: it
# resolves links and relative paths to the one true repo root.
function Get-WorktreeKey([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return '' }
    $top = $null
    try {
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $top = (& git -C $path rev-parse --show-toplevel 2>$null) } finally { $ErrorActionPreference = $previous }
    } catch { $top = $null }
    if (-not $top) {
        # Not a git repo (or git unavailable): fall back to the canonical filesystem path.
        try { $top = [System.IO.Path]::GetFullPath($path) } catch { $top = $path }
    }
    return (([string]$top) -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
}

# --- Liveness: a PID alone is NOT an identity ----------------------------------------------------
# Windows recycles PIDs. A stale `running` row whose PID has been reused by an unrelated long-lived
# process would make Get-Process succeed forever: every future dispatch exits 71 and every -Adopt
# exits 75, for a coder that died hours ago. So a PID only counts as OUR process if it also STARTED
# AT OR AFTER the moment we recorded the row. A recycled PID is necessarily younger than the row it
# is impersonating... but the reverse is what we can actually check: a process that started BEFORE
# the ledger row was written cannot be the child that row created.
# A PID IS NOT AN IDENTITY. A (pid, start-time) PAIR IS.
#
# Windows recycles PIDs. The first attempt at this compared the process's StartTime against the
# ledger row's `started` and accepted anything that began at-or-after it -- which is exactly
# BACKWARDS for the case it was meant to catch: a recycled PID starts LATER than the row, so it
# sailed through and an unrelated process read as a live coder forever. It also rejected a
# legitimate long-lived launcher that started before the row, which would have let a concurrent
# launch through. Wrong in both directions at once.
#
# So record the process's OWN start time when the pid is recorded, and require an exact match. A
# recycled pid necessarily has a different start time. There is nothing to infer.
function Get-ProcessStamp([int]$ProcessId) {
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    try { return $p.StartTime.ToUniversalTime().ToString('o') } catch { return 'unknown' }
}

function Test-ProcessIs {
    param([int]$ProcessId, [string]$Stamp, [switch]$Strict)

    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }

    # -Strict: POSITIVE identification only. Used to answer "is this definitely still our coder?",
    # which must never be overruled by a heuristic like the age rule.
    if (-not $Stamp -or $Stamp -eq 'unknown') { return (-not $Strict) }
    try {
        $actual = $p.StartTime.ToUniversalTime()
        $expected = ([datetime]$Stamp).ToUniversalTime()
        # The stamp is read from the process ITSELF at the moment its pid is recorded, so an exact
        # match is available -- no tolerance is needed, and a 2-second window is wide enough for
        # Windows to recycle a short-lived coder's pid onto an unrelated process started inside it,
        # which would then be positively identified as the coder (wedging dispatches at 71 and
        # adoption at 75). A 50ms window absorbs only serialization jitter.
        return ([math]::Abs(($actual - $expected).TotalMilliseconds) -lt 50)
    } catch {
        return (-not $Strict)   # protected process: cannot read StartTime. Fail SAFE unless -Strict.
    }
}

function Test-LedgerRowLive {
    param([Parameter(Mandatory)]$Row)

    # A VERIFIED process is live, however old the row is. The age rule below exists only to expire
    # rows we CANNOT verify -- it must never overrule positive evidence. Applying it first would
    # declare a legitimately long-running dispatch dead at the 12h mark and let a second coder launch
    # into the tree it is still writing, which is the exact collision this guard exists to prevent.
    if ($Row.pid -and (Test-ProcessIs -ProcessId ([int]$Row.pid) -Stamp ([string]$Row.pid_start) -Strict)) { return $true }
    if ($Row.launcher_pid -and (Test-ProcessIs -ProcessId ([int]$Row.launcher_pid) -Stamp ([string]$Row.launcher_start) -Strict)) { return $true }

    # Unverifiable (stamp 'unknown', or StartTime unreadable): fail SAFE and call it live -- but only
    # for a bounded time. Otherwise a recycled PID owned by a long-lived system process, or a row
    # whose stamp could never be read, refuses every future dispatch into that worktree until reboot.
    $unverifiable = ($Row.pid -and (Test-ProcessIs -ProcessId ([int]$Row.pid) -Stamp ([string]$Row.pid_start))) -or
                    ($Row.launcher_pid -and (Test-ProcessIs -ProcessId ([int]$Row.launcher_pid) -Stamp ([string]$Row.launcher_start)))
    if (-not $unverifiable) { return $false }

    if ($Row.started) {
        try {
            $age = (Get-Date).ToUniversalTime() - ([datetime]$Row.started).ToUniversalTime()
            if ($age.TotalHours -gt 12) { return $false }   # unverifiable AND ancient: a corpse.
        } catch { }
    }
    return $true
}

# Every dispatch still running in a given worktree. There is deliberately NO task-name exclusion:
# excluding by name meant two dispatches of the SAME task name into one tree each ignored the other
# and both launched -- the precise collision the guard exists to prevent. This is only ever called
# BEFORE this run's own row is written, so there is nothing of ours to exclude.
function Test-MalformedLedgerLineExpired {
    param([Parameter(Mandatory)][string]$Line)

    # Use the same 12-hour corpse ceiling as Test-LedgerRowLive. Only a timestamp positively
    # recovered from the damaged text may expire the uncertainty; missing or invalid evidence stays
    # live and therefore refuses.
    if ($Line -notmatch '"started"\s*:\s*"(?<ledgerStarted>[^"]+)"') { return $false }
    try {
        $age = (Get-Date).ToUniversalTime() - ([datetime]$Matches.ledgerStarted).ToUniversalTime()
        return ($age.TotalHours -gt 12)
    } catch {
        return $false
    }
}

function Test-MalformedLedgerLineCouldBelongToWorktree {
    param(
        [Parameter(Mandatory)][string]$Line,
        [Parameter(Mandatory)][string]$WorktreeKey
    )

    # A recovered different key proves the damaged row belongs to another tree. With no recoverable
    # identity it could be ours, so uncertainty fails closed. Legacy rows may have only `worktree`.
    if ($Line -match '"worktree_key"\s*:\s*"(?<ledgerWorktreeKey>[^"]*)"') {
        return ([string]$Matches.ledgerWorktreeKey -eq $WorktreeKey)
    }
    if ($Line -match '"worktree"\s*:\s*"(?<ledgerWorktree>(?:\\.|[^"\\])*)"') {
        try {
            $decodedWorktree = ConvertFrom-Json -InputObject ('"' + $Matches.ledgerWorktree + '"')
            return ((Get-WorktreeKey ([string]$decodedWorktree)) -eq $WorktreeKey)
        } catch {
            return $true
        }
    }
    return $true
}

function Get-LiveDispatches {
    param(
        [Parameter(Mandatory)][string]$WorktreeKey,
        [string]$ExcludeRunId,
        [AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$LedgerLines
    )

    if (-not $PSBoundParameters.ContainsKey('LedgerLines')) {
        $LedgerLines = @(Invoke-WithLedgerLock {
            if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { return }
            [System.IO.File]::ReadAllLines($ledgerPath)
        })
    }
    $live = @()
    $openLeaseRunIds = @(Get-OpenLeaseRunIds -LedgerLines $LedgerLines)
    foreach ($line in $LedgerLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $row = $line | ConvertFrom-Json
        } catch {
            if ((Test-MalformedLedgerLineCouldBelongToWorktree -Line $line -WorktreeKey $WorktreeKey) -and
                    -not (Test-MalformedLedgerLineExpired -Line $line)) {
                # Kept OUT of $live: -AllowSharedWorktree may override a known live worker, never an
                # unreadable reservation whose ownership and liveness cannot be established.
                if (-not $script:malformedLiveLedgerLine) { $script:malformedLiveLedgerLine = $line }
            }
            continue
        }
        # 'stalled' is STILL LIVE: the watchdog flags a quiet run and deliberately does NOT kill it.
        # 'adopting' is LIVE: adoption is still running that run's gates. Treating it as terminal
        # freed the worktree mid-adoption -- and if adoption then threw (a missing helper), the row
        # stayed 'adopting' forever while the next dispatch happily launched into the same tree.
        if (@('leasing', 'running', 'stalled', 'adopting') -cnotcontains [string]$row.status) { continue }
        if ($ExcludeRunId -and [string]$row.run_id -ceq $ExcludeRunId) { continue }
        if ([string]$row.status -ceq 'leasing' -and
                $openLeaseRunIds -cnotcontains [string]$row.run_id) { continue }
        if ([string]$row.worktree_key -ne $WorktreeKey) { continue }
        if (Test-LedgerRowLive -Row $row) { $live += $row }
    }
    return $live
}

function Invoke-CreatorGit {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & cmd /c exit 99
        $gitLines = @(& git @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $gitExit = $LASTEXITCODE
    }
    catch {
        $gitLines = @($_.Exception.Message)
        $gitExit = 99
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{
        Lines = [string[]]$gitLines
        ExitCode = [int]$gitExit
        Text = ([string[]]$gitLines -join [Environment]::NewLine).Trim()
    }
}

function Get-CreatorTeardownCommand {
    param(
        [Parameter(Mandatory)][string]$MainRepo,
        [Parameter(Mandatory)][string]$Worktree
    )

    return ('git -C "{0}" worktree remove "{1}"' -f $MainRepo, $Worktree)
}

function Save-CreatorTeardownRecord {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][hashtable]$Record,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$LedgerLines,
        [Parameter(Mandatory)][System.Threading.Mutex]$Mutex
    )

    $targetRowKind = $null
    foreach ($line in $LedgerLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $candidate = $line | ConvertFrom-Json } catch { continue }
        if ([string]$candidate.run_id -cne $RunId) { continue }
        $candidateKind = if (@($candidate.PSObject.Properties.Name) -ccontains 'row_kind') {
            [string]$candidate.row_kind
        }
        else {
            'dispatch'
        }
        if ($candidateKind -ceq 'dispatch') {
            $targetRowKind = 'dispatch'
            break
        }
        if ($candidateKind -ceq 'lease') {
            $targetRowKind = 'lease'
        }
        elseif ($candidateKind -ceq 'obligation' -and -not $targetRowKind) {
            # A teardown may record successfully and then throw. The outer catch retries with a
            # fresh ledger snapshot; target that existing event instead of appending a duplicate.
            $targetRowKind = 'obligation'
        }
    }

    if ($targetRowKind) {
        Update-LedgerRow -RunId $RunId -RowKind $targetRowKind -Changes $Record -Mutex $Mutex
        return
    }

    # Only the post-identity pre-lease/refusal exits are permitted to create a standalone obligation.
    if (@('79', '80', '81') -cnotcontains [string]$script:pendingExitCode) { return }
    $obligationRow = @{
        run_id = $RunId
        row_kind = 'obligation'
        spec = $Spec
        task = $Task
        refusal_exit = [int]$script:pendingExitCode
        ended = (Get-UtcTimestamp)
    }
    foreach ($field in $Record.GetEnumerator()) {
        $obligationRow[$field.Key] = $field.Value
    }
    Add-LedgerRow -Row $obligationRow -Mutex $Mutex
}

function Invoke-CreatorTeardown {
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$RunId
    )

    # Seed every structured field before the first fallible operation so the outer catch can write
    # the same actionable schema even when identity capture itself fails.
    $record = @{
        teardown_main_repo = ''
        teardown_sha = ''
        teardown_branch = ''
        teardown_worktree = $Worktree
        cleanup_obligation = ''
        branch_teardown_obligation = ''
    }
    $script:creatorTeardownRecord = $record

    if (Test-Path -LiteralPath $Worktree -PathType Container) {
        $record.teardown_worktree = (Resolve-Path -LiteralPath $Worktree).Path
    }

    # Capture all identity while the linked worktree still exists. The first porcelain record is the
    # main checkout; using the linked worktree itself as `git -C` for removal is self-referential.
    $worktreeList = Invoke-CreatorGit -Arguments @(
        '-C', $record.teardown_worktree, 'worktree', 'list', '--porcelain')
    if ($worktreeList.ExitCode -ne 0) {
        throw "git worktree list failed: $($worktreeList.Text)"
    }
    foreach ($line in $worktreeList.Lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        if ($line -cmatch '^worktree (.+)$') {
            $record.teardown_main_repo = [string]$Matches[1]
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($record.teardown_main_repo)) {
        throw 'git worktree list returned no main-repository worktree record.'
    }

    $head = Invoke-CreatorGit -Arguments @('-C', $record.teardown_worktree, 'rev-parse', 'HEAD')
    if ($head.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($head.Text)) {
        throw "git rev-parse HEAD failed: $($head.Text)"
    }
    $record.teardown_sha = $head.Text

    $branch = Invoke-CreatorGit -Arguments @(
        '-C', $record.teardown_worktree, 'symbolic-ref', '--quiet', '--short', 'HEAD')
    if ($branch.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($branch.Text)) {
        $record.teardown_branch = $branch.Text
    }
    else {
        $record.teardown_branch = '(detached)'
    }

    # This handle is intentionally independent of the script-level handle, which the outer finally
    # disposes before calling creator teardown.
    $teardownMutex = [System.Threading.Mutex]::new($false, 'ApexCodexRunLedger')
    try {
        Invoke-WithLedgerLock -Mutex $teardownMutex -Action {
            $ledgerLines = if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
                [System.IO.File]::ReadAllLines($ledgerPath)
            }
            else {
                [string[]]@()
            }

            # Check dirtiness and every sibling class during the same ledger hold. Shared-worktree
            # permission never grants permission to delete a live or adoptable sibling's tree.
            $statusResult = Invoke-CreatorGit -Arguments @(
                '-C', $record.teardown_worktree, 'status', '--porcelain')
            # Some managed hosts inject a global excludesFile that Git cannot read. Git reports that
            # warning on stderr while still returning zero; it is not porcelain dirtiness. Only the
            # documented two-column porcelain records count when exit is zero.
            $statusPorcelainLines = @($statusResult.Lines | Where-Object {
                    [string]$_ -cmatch '^[ MADRCU?!]{2} '
                })
            $statusPorcelainText =
                ([string[]]$statusPorcelainLines -join [Environment]::NewLine).TrimEnd()
            $siblingKey = Get-WorktreeKey $record.teardown_worktree
            $script:malformedLiveLedgerLine = $null
            $liveSiblings = @(Get-LiveDispatches -WorktreeKey $siblingKey -ExcludeRunId $RunId `
                -LedgerLines $ledgerLines)
            $unresolvedSiblings = @(Get-UnresolvedWorktreeRows -WorktreeKey $siblingKey `
                -ExcludeRunId $RunId -LedgerLines $ledgerLines)

            $refusalKind = $null
            $refusalDetail = ''
            if ($record.teardown_branch -ceq '(detached)') {
                $refusalKind = 'detached HEAD'
                $refusalDetail = if ($branch.Text) {
                    $branch.Text
                }
                else {
                    "git symbolic-ref exited $($branch.ExitCode)"
                }
            }
            elseif ($statusResult.ExitCode -ne 0 -or
                    -not [string]::IsNullOrWhiteSpace($statusPorcelainText)) {
                $refusalKind = 'dirty'
                $refusalDetail = if ($statusResult.ExitCode -ne 0 -and $statusResult.Text) {
                    $statusResult.Text
                }
                elseif ($statusPorcelainText) {
                    $statusPorcelainText
                }
                else {
                    "git status exited $($statusResult.ExitCode)"
                }
            }
            elseif ($script:malformedLiveLedgerLine) {
                throw 'an unreadable unresolved sibling ledger row may still own this worktree'
            }
            elseif ($liveSiblings.Count -gt 0) {
                $refusalKind = "live sibling $([string]$liveSiblings[0].run_id)"
                $refusalDetail = $statusPorcelainText
            }
            elseif ($unresolvedSiblings.Count -gt 0) {
                $refusalKind = "unresolved sibling $([string]$unresolvedSiblings[0].run_id)"
                $refusalDetail = $statusPorcelainText
            }

            if ($refusalKind) {
                if ($refusalDetail.Length -gt 200) {
                    $refusalDetail = $refusalDetail.Substring(0, 200)
                }
                $record.cleanup_obligation = "worktree $($record.teardown_worktree) retained: $refusalKind`: $refusalDetail"
                $record.branch_teardown_obligation = ''
                Save-CreatorTeardownRecord -RunId $RunId -Record $record `
                    -LedgerLines $ledgerLines -Mutex $teardownMutex
                Write-Host $record.cleanup_obligation -ForegroundColor Yellow
                Write-Host (Get-CreatorTeardownCommand -MainRepo $record.teardown_main_repo `
                    -Worktree $record.teardown_worktree) -ForegroundColor Yellow
                return
            }

            $removeResult = Invoke-CreatorGit -Arguments @(
                '-C', $record.teardown_main_repo, 'worktree', 'remove', $record.teardown_worktree)
            if ($removeResult.ExitCode -eq 0) {
                $record.cleanup_obligation = ''
                $record.branch_teardown_obligation = $record.teardown_branch
            }
            else {
                $record.cleanup_obligation = if ($removeResult.Text) {
                    $removeResult.Text
                }
                else {
                    "git worktree remove exited $($removeResult.ExitCode)"
                }
                $record.branch_teardown_obligation = ''
                Write-Host (Get-CreatorTeardownCommand -MainRepo $record.teardown_main_repo `
                    -Worktree $record.teardown_worktree) -ForegroundColor Yellow
            }
            Save-CreatorTeardownRecord -RunId $RunId -Record $record `
                -LedgerLines $ledgerLines -Mutex $teardownMutex
        }
    }
    finally {
        $teardownMutex.Dispose()
    }
}

function Invoke-ListObligations {
    $rows = @(Invoke-WithLedgerLock -Action {
        if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { return }
        $ledgerLines = [System.IO.File]::ReadAllLines($ledgerPath)
        foreach ($line in $ledgerLines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $row = $line | ConvertFrom-Json } catch { continue }
            $rowKind = if (@($row.PSObject.Properties.Name) -ccontains 'row_kind') {
                [string]$row.row_kind
            }
            else {
                'dispatch'
            }
            if (@('dispatch', 'lease', 'obligation') -cnotcontains $rowKind) { continue }
            if ([string]::IsNullOrWhiteSpace([string]$row.cleanup_obligation) -and
                    [string]::IsNullOrWhiteSpace([string]$row.branch_teardown_obligation)) {
                continue
            }
            $row
        }
    })

    foreach ($row in $rows) {
        Write-Host ("run_id: {0}" -f $row.run_id)
        Write-Host ("spec/task: {0}/{1}" -f $row.spec, $row.task)
        if (-not [string]::IsNullOrWhiteSpace([string]$row.cleanup_obligation)) {
            Write-Host ("cleanup_obligation: {0}" -f $row.cleanup_obligation)
            Write-Host (Get-CreatorTeardownCommand -MainRepo ([string]$row.teardown_main_repo) `
                -Worktree ([string]$row.teardown_worktree))
            if ([string]$row.teardown_branch -ceq '(detached)') {
                Write-Host ("teardown_sha: {0}" -f $row.teardown_sha)
            }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$row.branch_teardown_obligation) -and
                [string]$row.teardown_branch -cne '(detached)') {
            Write-Host ("branch_teardown_obligation: {0}" -f $row.branch_teardown_obligation)
            $branchDeleteFlag = ([string][char]45) + 'd'
            Write-Host ('git -C "{0}" branch {2} "{1}"' -f
                $row.teardown_main_repo, $row.teardown_branch, $branchDeleteFlag)
        }
        Write-Host ''
    }
}

function Test-CreatorRunTerminal {
    param([Parameter(Mandatory)][string]$RunId)

    $terminalState = [pscustomobject]@{
        Reached = (@('79', '80', '81') -ccontains [string]$script:pendingExitCode)
    }
    Invoke-WithLedgerLock -Action {
        if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { return }
        foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $row = $line | ConvertFrom-Json } catch { continue }
            if ([string]$row.run_id -cne $RunId) { continue }
            $rowKind = if (@($row.PSObject.Properties.Name) -ccontains 'row_kind') {
                [string]$row.row_kind
            }
            else {
                'dispatch'
            }
            if ($rowKind -ceq 'lease_close') {
                $terminalState.Reached = $true
                continue
            }
            if ($rowKind -ceq 'dispatch' -and
                    @('leasing', 'running', 'stalled', 'adopting', 'orphaned') -cnotcontains
                        [string]$row.status) {
                $terminalState.Reached = $true
            }
        }
    }
    return $terminalState.Reached
}

function Invoke-PostHocGates {
    param(
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$DigestScript,
        [switch]$ClassifyWritten,
        [string]$WrittenPathsFile,
        [string]$CriticalScript,
        [bool]$Confirmed = $false,
        [string]$BaselineHeadSha
    )

    $result = @{
        EndTreeDigest = 'unverifiable'
        CriticalViolation = $null
        HardBlock = $false
        CriticalPaths = @()
        Notes = @()
    }

    try {
        & cmd /c exit 99
        $digestLines = @(& $DigestScript -Digest -Worktree $Worktree)
        $digestExit = $LASTEXITCODE
        $digestOutput = ([string[]]$digestLines -join [Environment]::NewLine).Trim()
        if ($digestExit -eq 0 -and $digestOutput -cmatch '^[0-9a-f]{64}$') {
            $result.EndTreeDigest = $digestOutput
        }
        else {
            $result.Notes += "tree digest unverifiable (exit $digestExit)"
        }
    }
    catch {
        $result.Notes += "tree digest unverifiable: $($_.Exception.Message)"
    }

    if (-not $ClassifyWritten) {
        return $result
    }

    $result.CriticalViolation = $false
    if (-not [string]::IsNullOrWhiteSpace($BaselineHeadSha)) {
        try {
            & cmd /c exit 99
            $headLines = @(& git -C $Worktree rev-parse HEAD 2>$null)
            $headExit = $LASTEXITCODE
            $currentHead = ([string[]]$headLines -join [Environment]::NewLine).Trim()
            if ($headExit -ne 0 -or $currentHead -cnotmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') {
                $result.CriticalViolation = $true
                $result.Notes += 'HEAD unreadable -- written set unassessable'
                return $result
            }
            if ($currentHead -ne $BaselineHeadSha.Trim()) {
                $result.CriticalViolation = $true
                $result.Notes += 'head moved -- written set unassessable'
                return $result
            }
        }
        catch {
            $result.CriticalViolation = $true
            $result.Notes += "HEAD unreadable -- written set unassessable: $($_.Exception.Message)"
            return $result
        }
    }

    if ([string]::IsNullOrWhiteSpace($WrittenPathsFile) -or
            -not (Test-Path -LiteralPath $WrittenPathsFile -PathType Leaf)) {
        $result.CriticalViolation = $true
        $result.Notes += 'written paths file missing -- written set unassessable'
        return $result
    }

    try {
        $writtenPaths = @([System.IO.File]::ReadAllLines($WrittenPathsFile) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
    catch {
        $result.CriticalViolation = $true
        $result.Notes += "written paths file unreadable -- written set unassessable: $($_.Exception.Message)"
        return $result
    }

    if ($writtenPaths.Count -eq 0) {
        return $result
    }

    try {
        & cmd /c exit 99
        $classifierOutput = @(& $CriticalScript -Test -Paths $writtenPaths -Root $Worktree)
        $classifierExit = $LASTEXITCODE
        $result.CriticalPaths = @($classifierOutput | ForEach-Object { [string]$_ } |
            Where-Object { $_ -cmatch '^(CRITICAL |HARDBLOCK )' })

        switch ($classifierExit) {
            11 {
                $result.CriticalViolation = $true
                $result.HardBlock = $true
            }
            10 { $result.CriticalViolation = -not $Confirmed }
            0 { $result.CriticalViolation = $false }
            default {
                $result.CriticalViolation = $true
                $result.Notes += "critical classifier returned unexpected exit $classifierExit"
            }
        }
    }
    catch {
        $result.CriticalViolation = $true
        $result.Notes += "critical classifier failed: $($_.Exception.Message)"
    }

    return $result
}

function Invoke-Adopt {
    # Spec+Phase alone does not identify a run. Adoption CLOSES the row it selects and reports its
    # verdict as if it were the one you asked about -- so selecting the wrong row means closing an
    # unrelated run as `adopted`, exiting 0, and leaving the run you actually cared about live and
    # unterminated. Demand enough to be sure.
    if ([string]::IsNullOrWhiteSpace($Spec) -or [string]::IsNullOrWhiteSpace($Phase)) {
        throw '-Adopt requires -Spec and -Phase.'
    }
    if ([string]::IsNullOrWhiteSpace($Worktree)) {
        throw '-Adopt requires -Worktree: two runs of the same spec/phase can exist in different worktrees, and adopting the wrong one closes it and leaves yours live.'
    }
    if (-not (Test-Path -LiteralPath $ledgerPath)) {
        throw "Codex run ledger does not exist: $ledgerPath"
    }

    $script:adoptLiveMatch = $null
    $script:adoptAbandonedMatch = $null
    $match = Invoke-WithLedgerLock {
        $adoptKey = if ($Worktree) { Get-WorktreeKey $Worktree } else { $null }
        $matches = foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $line | ConvertFrom-Json
            if ($row.spec -ne $Spec -or $row.phase -ne $Phase) { continue }
            if ($RunId -and [string]$row.run_id -cne $RunId) { continue }
            if ([string]$row.row_kind -ceq 'lease') { continue }
            # Filter on EVERY identifier the caller supplied. Matching spec+phase alone could adopt a
            # different task, in a different worktree -- closing that row as `adopted` and exiting 0,
            # while the run actually asked about stayed live and unterminated.
            if ($Task -and $row.task -ne $Task) { continue }
            # A LEGACY row (migrated from before worktree_key existed) has no key. Deriving it from
            # the row's recorded worktree is right; treating "no key" as "matches anything" is how a
            # row from worktree B got adopted when worktree A was explicitly requested.
            $rowKey = if ($row.worktree_key) { [string]$row.worktree_key } elseif ($row.worktree) { Get-WorktreeKey ([string]$row.worktree) } else { '' }
            if ($rowKey -ne $adoptKey) { continue }
            # NEVER adopt a row that already reached a terminal state. Selecting "the newest row"
            # regardless of status meant a completed rerun B was re-closed as `adopted-done` while the
            # dead run A you were actually recovering stayed `running` forever. The exact
            # abandoned-unadopted match is retained only so an adopter that lost the selection-lock
            # race to -AbandonRunId returns adoption's refusal code instead of an unrelated exit 1.
            if ($row.status -notin @('running', 'stalled', 'adopting', 'orphaned')) {
                if ($RunId -and [string]$row.status -ceq 'abandoned-unadopted') {
                    $script:adoptAbandonedMatch = $row
                }
                continue
            }
            $row
        }
        $selected = if ($RunId) {
            @($matches) | Select-Object -First 1
        }
        else {
            $matches | Sort-Object { [datetime]$_.started } -Descending | Select-Object -First 1
        }
        if ($null -eq $selected) { return $null }

        # Test and claim under this SAME selection lock. Releasing it with the dead launcher/coder
        # PIDs still in place let a dispatcher launch into the tree and let a second adopter select
        # the same row. An adopting row is live too: another adopter is already running its gates.
        if (($selected.status -eq 'running' -or $selected.status -eq 'stalled' -or
                $selected.status -eq 'adopting') -and
                (Test-LedgerRowLive -Row $selected)) {
            $script:adoptLiveMatch = $selected
            return $selected
        }

        $adopterStamp = Get-ProcessStamp $PID
        $adopterIdentity = @{
            status = 'adopting'
            launcher_pid = $PID; launcher_start = $adopterStamp
            pid = $PID; pid_start = $adopterStamp
        }
        foreach ($telemetryField in @('log_path', 'effort', 'attended')) {
            if (@($selected.PSObject.Properties.Name) -ccontains $telemetryField) {
                $adopterIdentity[$telemetryField] = $selected.$telemetryField
            }
        }
        Update-LedgerRow -RunId ([string]$selected.run_id) -RowKind 'dispatch' -Changes $adopterIdentity
        foreach ($identityPart in $adopterIdentity.GetEnumerator()) {
            $selected | Add-Member -NotePropertyName $identityPart.Key -NotePropertyValue $identityPart.Value -Force
        }
        $selected
    }

    if ($null -eq $match) {
        if ($script:adoptAbandonedMatch) {
            Write-Host (
                "[adopt] REFUSED (exit 75): run_id '$RunId' has already been abandoned-unadopted."
            ) -ForegroundColor Yellow
            exit 75
        }
        throw "No Codex ledger row matches spec '$Spec' and phase '$Phase'."
    }

    # A dead dispatch call does NOT mean a dead coder. `codex exec` outlives the tool call that
    # launched it: a harness Bash timeout SIGTERMs the shell (exit 143), the child keeps working,
    # and a host that reads "my call died" as "the coder died" walks straight into recovery on a
    # tree that is still being written. On cap-deps-1b (2026-07-14) the coder kept writing for
    # 3.5 minutes after it was declared dead. Adopting a half-written tree is worse than waiting:
    # you verify and commit a torn build. So before showing anything, ask whether it is still alive.
    # This decision was made under the selection lock above. In particular, `adopting` means a first
    # adopter owns the row; treating only running/stalled as live let a second adopter race its gates.
    if ($script:adoptLiveMatch) {
        Write-Host "[adopt] THE CODER OR ADOPTER IS STILL RUNNING -- pid $($match.pid), status '$($match.status)'. Nothing to adopt." -ForegroundColor Yellow
        Write-Host "[adopt] Your dispatch CALL died; the coder did not. Do not verify, do not commit: the tree is still being written." -ForegroundColor Yellow
        Write-Host "[adopt] The completion signal is the report file, and only that file:" -ForegroundColor Yellow
        Write-Host "[adopt]   $($match.final_path)" -ForegroundColor Yellow
        Write-Host "[adopt] Wait for it to appear, then re-run -Adopt. To abandon instead, kill pid $($match.pid) deliberately." -ForegroundColor Yellow
        exit 75
    }

    # The coder is dead -- so ADOPT ITS VERDICT, not just its diff.
    #
    # This used to print `git diff base..HEAD` and exit with git's status. Two things wrong with
    # that. First, it never read the report: a child that exited `blocked` (or a review that returned
    # BLOCK) was adopted as a clean success. Second, `base..HEAD` shows only COMMITTED work, and the
    # coder is instructed never to commit -- so the diff was usually EMPTY. Adoption returned "no
    # changes, exit 0" for a run that had failed and left a tree full of them.
    #
    # (I claimed this was fixed in a review pack before I had written it. The reviewer read the code
    # instead of my summary, which is the only reason it is being fixed now.)
    Write-Output $match.worktree
    if ((@($match.PSObject.Properties.Name) -ccontains 'log_path') -and
            -not [string]::IsNullOrWhiteSpace([string]$match.log_path)) {
        Write-Host "[adopt] log: $($match.log_path)" -ForegroundColor DarkGray
    }
    else {
        Write-Host '[adopt] This ledger row has no recorded log_path.' -ForegroundColor DarkGray
    }

    $adoptStatus = 'unknown'
    $adoptUnresolved = @()
    $adoptBlocker = $null
    $adoptSchemaName = [string]$match.schema
    $adoptCompletionSchema = @('completion', 'codex-completion-schema.json') -ccontains $adoptSchemaName
    $adoptReviewSchema = @('review', 'codex-review-schema.json', 'endgate', 'afk-endgate-schema.json') -ccontains $adoptSchemaName
    if ($match.final_path -and (Test-Path -LiteralPath $match.final_path -PathType Leaf)) {
        try {
            $adoptReport = Get-Content -LiteralPath $match.final_path -Raw | ConvertFrom-Json
            $reportedAdoptStatus = [string]$adoptReport.status

            # Completion status is an exact, case-sensitive schema token. Review schemas carry no
            # status at all; applying this allowlist to them would block every legitimate CLEAN.
            if ($adoptCompletionSchema) {
                if (@('done', 'done_with_concerns', 'blocked') -ccontains $reportedAdoptStatus) {
                    $adoptStatus = $reportedAdoptStatus
                }
                else {
                    $adoptStatus = 'blocked'
                    Write-Host "[adopt] Invalid completion status '$reportedAdoptStatus'. Treating as blocked." -ForegroundColor Red
                }
            }
            else {
                $adoptStatus = 'unknown'
            }

            # A report saying `done` does not undo a process that FAILED. The main path records
            # status:'failed' with the child's exit code; adoption used to derive `done` from the
            # report alone and rewrite the row as adopted-done, exiting 0 on a run that had failed.
            if ($match.status -eq 'failed' -and $adoptStatus -eq 'done') {
                Write-Host "[adopt] The report says 'done' but the run FAILED (exit $($match.error)). The process outranks the claim." -ForegroundColor Red
                $adoptStatus = 'blocked'
            }
            if ($adoptReviewSchema -and $adoptReport.PSObject.Properties.Name -contains 'verdict') {
                # Match the MAIN path's rules exactly. This used to test `BLOCK*` (prefix) while the
                # main path tested `*BLOCK*` (substring), so an end-gate verdict of "P1: block
                # handoff" was unmatched here, left $adoptStatus 'unknown', and adopted as EXIT 0.
                # Two copies of one rule is one copy too many; they diverged, and the weaker one
                # failed open.
                $v = ([string]$adoptReport.verdict).ToUpperInvariant()

                # Findings OUTRANK the verdict string, exactly as on the main path. A report saying
                # `verdict: CLEAN` while carrying a BLOCK finding is contradicting itself, and
                # adoption used to believe the cheerful half and exit 0.
                $adoptFindings = 0
                if ($adoptReport.findings) {
                    $adoptFindings = @($adoptReport.findings | Where-Object {
                        $sev = ([string]$_.severity).ToUpperInvariant()
                        $sev -and $sev -ne 'CLEAN' -and $sev -ne 'NONE' -and $sev -ne 'INFO'
                    }).Count
                }
                $hasBlockingFinding = $false
                if ($adoptReport.findings) {
                    $hasBlockingFinding = @($adoptReport.findings | Where-Object {
                        ([string]$_.severity).ToUpperInvariant() -like '*BLOCK*'
                    }).Count -gt 0
                }

                if ($v -like '*BLOCK*' -or $hasBlockingFinding) { $adoptStatus = 'blocked' }
                elseif ($v -like '*FLAG*' -or $v -like 'P1*' -or $v -like 'P2*' -or $adoptFindings -gt 0) {
                    $adoptStatus = 'done_with_concerns'
                    $adoptUnresolved += "Review verdict '$([string]$adoptReport.verdict)' -- $adoptFindings finding(s) to adjudicate."
                }
                elseif ($v -eq 'CLEAN' -or $v -eq 'PASS' -or $v -eq 'OK') { if ($adoptStatus -eq 'unknown') { $adoptStatus = 'done' } }
                else { $adoptStatus = 'blocked' }   # unrecognised verdict: fail closed
            }
            elseif ($adoptReviewSchema) {
                # A review/end-gate status is not a verdict. Without verdict evidence the gate did
                # not run, even if a stray `status: done` property is present.
                $adoptStatus = 'blocked'
                Write-Host '[adopt] The review report carried no verdict. Treating as blocked.' -ForegroundColor Red
            }
            elseif (-not $adoptCompletionSchema) {
                $adoptStatus = 'blocked'
                Write-Host "[adopt] Unrecognised ledger schema '$adoptSchemaName'. Treating as blocked." -ForegroundColor Red
            }

            # Completion reports alone own `unresolved`. Filter before every Count test so blank
            # strings cannot masquerade as named concerns; review evidence is synthesized above.
            if ($adoptCompletionSchema) {
                $adoptUnresolved = @($adoptReport.unresolved | Where-Object {
                        -not [string]::IsNullOrWhiteSpace([string]$_)
                    })
                if ($adoptReport.blocker) { $adoptBlocker = [string]$adoptReport.blocker }

                # Same coupling as the main path: a blocker or unresolved work contradicts `done`.
                if ($adoptBlocker -and $adoptStatus -eq 'done') { $adoptStatus = 'blocked' }
                elseif ($adoptUnresolved.Count -gt 0 -and $adoptStatus -eq 'done') {
                    $adoptStatus = 'done_with_concerns'
                }
                if ($adoptStatus -eq 'done_with_concerns' -and $adoptUnresolved.Count -eq 0) {
                    $adoptStatus = 'blocked'
                    $adoptBlocker = $emptyConcernBlockerText
                }
            }
            foreach ($u in $adoptUnresolved) { Write-Host "[adopt] UNRESOLVED: $u" -ForegroundColor Yellow }
            if ($adoptBlocker) { Write-Host "[adopt] BLOCKER: $adoptBlocker" -ForegroundColor Red }
        } catch {
            $adoptStatus = 'blocked'
            Write-Host "[adopt] The report at $($match.final_path) is unparseable. Treating as blocked." -ForegroundColor Red
        }
    } else {
        Write-Host "[adopt] The coder is gone and wrote NO report. A missing verdict is not a passing one." -ForegroundColor Red
        $adoptStatus = 'blocked'
    }
    if ($adoptStatus -eq 'unknown') { $adoptStatus = 'blocked' }   # never adopt an unknown as a pass

    # Record the report verdict on the row already claimed as ADOPTING under the selection lock.
    # A row is only terminal once the gates that make it terminal have run.
    try {
        Update-LedgerRow -RunId ([string]$match.run_id) -RowKind 'dispatch' -Changes @{
            adopted = $true; report_status = $adoptStatus
            unresolved = $adoptUnresolved; blocker = $adoptBlocker
        }
    } catch {
        throw "[adopt] Could not durably record the adoption report status: $($_.Exception.Message)"
    }

    # The working tree, not just commits: the coder leaves its work UNCOMMITTED by contract.
    & git -C $match.worktree --no-pager diff $match.base_sha
    & git -C $match.worktree --no-pager status --porcelain

    # ADOPTION MUST RUN THE GATES THE DEAD WRAPPER NEVER GOT TO RUN.
    #
    # Adoption exists precisely because the wrapper died -- which means the scope check and the tree
    # pin it had armed never fired. Reading only the coder's self-report and exiting 0 accepts the
    # coder's word for the one thing it is least able to judge. A killed wrapper plus an
    # out-of-scope write plus a `done` report used to adopt as a clean success.
    $adoptScopeExit = 0
    $adoptScript = Join-Path $PSScriptRoot 'codex-scope-check.ps1'
    $adoptIsBuildPhase = ([string]$match.phase -ceq 'build')
    $adoptGates = $null
    $adoptCriticalViolation = $null
    if ($match.scope_armed -and -not (Test-Path $adoptScript)) {
        throw "This run armed a scope check, but codex-scope-check.ps1 is missing ($adoptScript). Refusing to adopt: an armed gate that cannot run must not be silently skipped."
    }
    if ($match.tree_pin_label -and -not (Test-Path (Join-Path $PSScriptRoot 'tree-pin.ps1'))) {
        throw "This run armed a tree pin, but tree-pin.ps1 is missing. Refusing to adopt: an unpinned gate can bless a tree that moved under it."
    }
    if ($match.scope_armed -and (Test-Path $adoptScript)) {
        if ($match.scope_exit -ne $null -and $match.ended) {
            # The original wrapper already ran this check and recorded its result; the snapshot is
            # one-shot and is gone. Re-running would throw "No snapshot". Reuse the recorded verdict
            # rather than crashing -- a gate that already ran is not a gate that was skipped.
            $adoptScopeExit = [int]$match.scope_exit
            Write-Host "[adopt] scope check already ran for this run: exit $adoptScopeExit (reusing its result)." -ForegroundColor DarkGray
            if ($adoptIsBuildPhase) {
                Write-Host '[adopt] post-hoc classification unavailable for pre-completed adopted run' -ForegroundColor Yellow
            }
        }
        else {
            $adoptWrittenPathsFile = Join-Path $harnessStateDir "adopt-written-$([string]$match.run_id).txt"
            try {
                if ($adoptIsBuildPhase) {
                    & $adoptScript -Check -Worktree $match.worktree -Task ([string]$match.scope_task) `
                        -Authorized @($match.authorized) -ExcludeRunId ([string]$match.run_id) `
                        -StateDirectory $harnessStateDir -WrittenPathsFile $adoptWrittenPathsFile | Write-Host
                }
                else {
                    & $adoptScript -Check -Worktree $match.worktree -Task ([string]$match.scope_task) `
                        -Authorized @($match.authorized) -ExcludeRunId ([string]$match.run_id) -StateDirectory $harnessStateDir | Write-Host
                }
                $adoptScopeExit = $LASTEXITCODE
            } catch {
                # Lockstep sibling: the main-path scope-check catch also fails closed on its build +
                # workspace-write post-hoc path; its exit is 77 unless outranked, while adopt exits 65.
                # No snapshot and no recorded result: the gate was armed and its evidence is gone, so
                # nothing can vouch for this run's scope. Fail closed.
                Write-Host "[adopt] The armed scope check cannot be replayed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "[adopt] Its evidence is gone, so nothing can vouch for this run's scope. Treating as a violation." -ForegroundColor Red
                $adoptScopeExit = 1
            }
            if ($adoptIsBuildPhase) {
                $adoptCriticalScript = if ($CriticalFilesScript) { $CriticalFilesScript } else { Join-Path $PSScriptRoot 'apex-critical-files.ps1' }
                # Adoption may use only the confirmation already recorded on the row. The adopt
                # invocation's own -CriticalFilesConfirmed switch is unrecorded and must never approve it.
                $adoptGates = Invoke-PostHocGates -Worktree ([string]$match.worktree) -DigestScript $digestScript `
                    -ClassifyWritten -WrittenPathsFile $adoptWrittenPathsFile `
                    -CriticalScript $adoptCriticalScript -Confirmed ([bool]$match.critical_files_confirmed)
                $adoptCriticalViolation = $adoptGates.CriticalViolation
            }
        }
        if ($adoptScopeExit -ne 0) {
            Write-Host "[adopt] The adopted run wrote OUTSIDE its authorized set (scope exit $adoptScopeExit)." -ForegroundColor Red
        }
    }

    if ($adoptIsBuildPhase -and $null -eq $adoptGates) {
        $adoptGates = Invoke-PostHocGates -Worktree ([string]$match.worktree) -DigestScript $digestScript
    }

    $adoptPinScript = Join-Path $PSScriptRoot 'tree-pin.ps1'
    if ($match.tree_pin_label -and (Test-Path $adoptPinScript)) {
        & $adoptPinScript -Verify -Worktree $match.worktree -Label ([string]$match.tree_pin_label) -PinDirectory $harnessStateDir | Write-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[adopt] The tree MOVED while this gate was open -- the adopted verdict is VOID." -ForegroundColor Red
            try {
                $adoptVoidChanges = @{ status = 'adopted-void'; ended = (Get-UtcTimestamp); adopted = $true }
                if ($adoptIsBuildPhase) {
                    $adoptVoidChanges['end_tree_digest'] = $adoptGates.EndTreeDigest
                    if ($null -ne $adoptCriticalViolation) {
                        $adoptVoidChanges['critical_violation'] = $adoptCriticalViolation
                    }
                }
                foreach ($telemetryField in @('log_path', 'effort', 'attended')) {
                    if (@($match.PSObject.Properties.Name) -ccontains $telemetryField) {
                        $adoptVoidChanges[$telemetryField] = $match.$telemetryField
                    }
                }
                Update-LedgerRow -RunId ([string]$match.run_id) -RowKind 'dispatch' -Changes $adoptVoidChanges
            } catch {
                throw "[adopt] Could not durably close the moved-tree ledger row: $($_.Exception.Message)"
            }
            # `blocked` outranks a void tree, exactly as on the main path. Exiting 69 first meant an
            # orphaned run that reported BLOCK *and* whose tree moved came back 69, and the caller
            # never learned it was blocked. Same contract, two implementations -- and they disagreed.
            if ($adoptStatus -eq 'blocked') {
                Write-Host "[adopt] BLOCKED (and the tree also moved). Do NOT commit." -ForegroundColor Red
                exit 67
            }
            exit 69
        }
    }

    # The encoding gate runs here too, and NOT because it is tidy: an adopted run's writes sit in the
    # tree exactly like a normal run's. Session 71 shipped "two copies of one rule, the weaker one
    # fails open" FOUR TIMES in this one file. Leaving -Adopt without this scan would be the fifth.
    # It needs no snapshot, so unlike the scope check it can always be re-run for real.
    # Same fail-closed rule as the main path. Two copies of one rule always diverge and the weaker one
    # fails open -- this file shipped that bug four times. If the helper is gone, neither path pretends.
    if (-not (Test-Path $adoptScript)) {
        throw "codex-scope-check.ps1 is missing ($adoptScript). Refusing to adopt without the encoding gate."
    }
    $adoptEncodingViolation = $false
    # Key this on the recorded sandbox, not phase: legacy/fabricated review rows may have written.
    if ([string]$match.sandbox -eq 'read-only') {
        Write-Host "[encoding] read-only adopt (review/end-gate): no coder writes to scan -- skipping." -ForegroundColor DarkGray
    }
    elseif ($match.worktree) {
        & $adoptScript -EncodingScan -Worktree ([string]$match.worktree) -Task ([string]$match.scope_task) `
            -Authorized @($match.authorized) | Write-Host
        if ($LASTEXITCODE -eq 73) { $adoptEncodingViolation = $true }
    }

    $adoptFinal = $adoptStatus
    if ($adoptScopeExit -ne 0) { $adoptFinal = "$adoptStatus+scope$adoptScopeExit" }
    try {
        $adoptTerminalChanges = @{
            status = "adopted-$adoptFinal"; ended = (Get-UtcTimestamp)
            scopeViolation = ($adoptScopeExit -ne 0); scope_exit = $adoptScopeExit
            encoding_violation = $adoptEncodingViolation
        }
        if ($adoptIsBuildPhase) {
            $adoptTerminalChanges['end_tree_digest'] = $adoptGates.EndTreeDigest
            if ($null -ne $adoptCriticalViolation) {
                $adoptTerminalChanges['critical_violation'] = $adoptCriticalViolation
            }
        }
        foreach ($telemetryField in @('log_path', 'effort', 'attended')) {
            if (@($match.PSObject.Properties.Name) -ccontains $telemetryField) {
                $adoptTerminalChanges[$telemetryField] = $match.$telemetryField
            }
        }
        Update-LedgerRow -RunId ([string]$match.run_id) -RowKind 'dispatch' -Changes $adoptTerminalChanges
    } catch {
        throw "[adopt] Could not durably close the ledger row: $($_.Exception.Message)"
    }

    Write-Host "[adopt] reported status: $adoptStatus" -ForegroundColor DarkGray
    if ($adoptStatus -eq 'blocked') {
        Write-Host "[adopt] BLOCKED: do not commit this, and do not build on top of it." -ForegroundColor Red
        exit 67
    }
    if ($adoptScopeExit -eq 66) { exit 66 }
    if ($adoptScopeExit -ne 0) { exit 65 }
    if ($adoptEncodingViolation) {
        Write-Host "[adopt] DOUBLE-ENCODED TEXT in the tree. Do NOT commit: the suite is green and WRONG." -ForegroundColor Red
        exit 73
    }
    if ($adoptCriticalViolation -eq $true) {
        Write-Host '[adopt] CRITICAL FILE VIOLATION in the post-hoc written set. Do NOT commit.' -ForegroundColor Red
        exit 77
    }
    if ($adoptStatus -eq 'done_with_concerns') { exit 68 }
    exit 0
}

if ($ListObligations) {
    Invoke-ListObligations
    exit 0
}

if ($script:abandonRequested) {
    Invoke-AbandonRun
}

if ($Adopt) {
    Invoke-Adopt
}

foreach ($required in @{
        Spec = $Spec; Task = $Task; Worktree = $Worktree; BaseSha = $BaseSha; Phase = $Phase; Prompt = $Prompt
    }.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
        throw "-$($required.Key) is required unless -Adopt is used."
    }
}

if (-not (Test-Path -LiteralPath $Worktree -PathType Container)) {
    throw "Worktree does not exist: $Worktree"
}
if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw "Codex completion schema does not exist: $schemaPath"
}

# --- ONE CODER PER WORKING TREE ---------------------------------------------------------------
# Two Codex workers in one tree is not "parallelism", it is a data race with a delete in it. Their
# writes interleave, and the first one to FINISH runs a scope check that cannot tell the other's
# in-progress files from its own out-of-scope writes -- so it reverts them. Untracked files, deleted
# outright, no git object, unrecoverable.
#
# Live: al-7c-quiet-gate (2026-07-14). Task 4 and Task 5 shared a tree; Task 4 finished first and
# DELETED Task 5's freshly-written files while Task 5 was still running and verifying against them.
# The scope check now refuses to revert while a sibling is live (exit 70) -- but that is the airbag.
# This is the seatbelt: don't have the collision.
#
# Wave-parallel dispatch (ADR-028) is still correct -- it just requires ONE WORKTREE PER CONCURRENT
# TASK (`git worktree add`), which is what -Worktree is for. Same repo path for two live tasks is
# the bug, and it is refused here rather than trusted to a rule someone has to remember.
#
# The scan and the ledger reservation are ONE ATOMIC OPERATION, under the same named mutex the
# ledger already uses. Scanning and then writing as two steps is a race in its own right: two
# dispatches can both complete the scan before either records a row, and both then launch into the
# tree the check was supposed to keep exclusive. Phase/schema/sandbox compatibility was already
# validated (and review write access normalized) at the no-I/O caller-contract boundary above.

# Exit 74 = refused before lease acquisition; NO ledger row/log for this run.
if ($Phase -eq 'build' -and $Sandbox -eq 'workspace-write' -and $Authorized.Count -eq 0 -and -not $ScopeUnlocked) {
    Write-Host '[dispatch] REFUSED (exit 74): workspace-write build has no -Authorized scope list — pass the spec''s ''## Files to change'' list, or -ScopeUnlocked -ScopeUnlockedReason "<why>" to bypass' -ForegroundColor Red
    exit 74
}

$worktreeKey = Get-WorktreeKey $Worktree

# Logs and pins are keyed by WORKTREE as well as spec/task, and each log also carries its run id.
# Concurrent dispatches in different worktrees are not just allowed, they are the prescribed way to
# run a wave -- and they were sharing one log file. Worse, a refused same-tree dispatch truncated the
# live run's log and reset its watchdog before the reservation check could stop it. A per-run path
# means this invocation can only ever truncate its own new log.
$wtSha = [System.Security.Cryptography.SHA256]::Create()
try {
    $worktreeTag = [System.BitConverter]::ToString(
        $wtSha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($worktreeKey))).Replace('-', '').Substring(0, 8).ToLower()
} finally { $wtSha.Dispose() }

# The dispatch log lives OUTSIDE the worktree, beside the ledger.
#
# It used to be written into the target repo (`<worktree>/docs/progress/codex-<spec>-<task>.log`),
# which forced the scope check to exempt its own state directory -- and every version of that
# exemption was a hole (a raw prefix match let `docs/progress-evil.md` through; a collapsed untracked
# `docs/` exempted the entire tree). When the exemption was finally deleted, this log became the bug:
# the wrapper creates it, snapshots the tree, then streams Codex's output INTO it -- so at check time
# the harness's own log reads as an unauthorized write and EVERY CLEAN BUILD EXITS 65.
#
# Worse, it was created BEFORE the sibling reservation, so a dispatch that got refused (71) had
# already mutated the tree -- and, with the same spec/task, truncated the LIVE run's log.
#
# The rule that keeps falling out of all of this: THE HARNESS MUST NOT WRITE INTO THE TREE IT IS
# JUDGING. Not a snapshot, not a log, not a pin. Then there is nothing to excuse, and no excuse to
# leak through. (Found by cross-family review; my own tests hid it, because the one test that would
# have caught the spurious 65 was already expecting a 65 for a different reason.)
$logDirectory = Join-Path $ledgerDirectory 'codex-logs'
[System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory($ledgerDirectory) | Out-Null
Assert-NotInsideRepo -Path $ScratchDirectory -What 'The -ScratchDirectory (which holds the .final report)'
[System.IO.Directory]::CreateDirectory($ScratchDirectory) | Out-Null
$safeSpec = ConvertTo-SafeFileName $Spec
$safeTask = ConvertTo-SafeFileName $Task
$runId = [guid]::NewGuid().ToString('N')
$logPath = Join-Path $logDirectory "codex-$safeSpec-$safeTask-$($worktreeTag)-$($runId.Substring(0,8)).log"

# The key under which this run's GATE EVIDENCE is filed. It carries the run id, so no two runs can
# ever read or overwrite each other's snapshot or pin -- however their spec/task names collapse.
$gateKey = "$safeSpec-$safeTask-$($runId.Substring(0,8))"

# The report path is UNIQUE PER RUN, and that is load-bearing.
#
# It used to be "codex-$safeSpec-$safeTask.final" in a shared scratch dir, which is wrong three ways:
#   * COLLISION. spec=a-b/task=c and spec=a/task=b-c both produce codex-a-b-c.final, and
#     ConvertTo-SafeFileName's lossy substitution adds more. Two runs, one filename.
#   * DESTRUCTION. To stop a crashed run being judged on the LAST run's verdict, the previous
#     version DELETED any pre-existing report at launch -- so a run starting in one worktree could
#     delete the live report of a run in ANOTHER worktree. And this change set now actively
#     ENCOURAGES concurrent worktrees. I built a footgun and then handed out more guns.
#   * The stale-report bug it was patching only exists BECAUSE the path was reused.
# A unique path kills all three: no collision, nothing to delete, and a missing report can only ever
# mean THIS run produced no verdict.
$finalPath = Join-Path $ScratchDirectory "codex-$safeSpec-$safeTask-$($runId.Substring(0,8)).final"

try {
$baselineSkipped = $false
$preflightPinLabel = $null
$preflightPinArmed = $false
$preflightTreePinScript = $null
$script:leaseRegistered = $false
$script:capacityRefusal = $null
$script:capacityConfigurationRefusal = $null
$script:capacityMachineWeight = 0
$script:capacitySpecWeight = 0
$script:capacityOccupants = @()
$script:newlyOrphanedRows = @()
$script:orphanRowsDeferred = 0

$thisRunWeight = if ($Phase -ceq 'build' -and $Sandbox -ceq 'workspace-write') {
    if ($Effort -ceq 'ultra') { 2 } else { 1 }
}
else {
    # Review/read-only dispatches still use a lease to guard their pre-launch refusal lifecycle, but
    # they do not consume build capacity.
    0
}

$specCeiling = 2
if ($thisRunWeight -gt 0) {
    $specCeilingValue = Get-SpecFrontmatterValue -Key 'max_parallel_codex'
    if ($specCeilingValue -is [string] -and
            $specCeilingValue -ceq '__APEX_FRONTMATTER_UNPARSEABLE__') {
        $script:capacityConfigurationRefusal =
            "max_parallel_codex is present but unparseable in the spec frontmatter"
    }
    elseif ($null -ne $specCeilingValue) {
        if ($specCeilingValue -isnot [string]) {
            $script:capacityConfigurationRefusal =
                'max_parallel_codex must be a scalar integer, not a YAML sequence'
        }
        else {
            try {
                $specCeiling = [int]$specCeilingValue
                if ($specCeiling -lt 1) { throw 'max_parallel_codex must be at least 1' }
            }
            catch {
                $script:capacityConfigurationRefusal =
                    "max_parallel_codex '$specCeilingValue' is not a positive integer"
            }
        }
    }
}

if ($script:capacityConfigurationRefusal) {
    Write-Host "[dispatch] REFUSED (exit 79): $($script:capacityConfigurationRefusal)." -ForegroundColor Red
    Exit-Dispatch 79
}

$leaseStarted = Get-UtcTimestamp
$launcherStart = Get-ProcessStamp $PID
$leaseRow = [ordered]@{
    run_id = $runId
    launcher_pid = $PID
    launcher_start = $launcherStart
    worktree = $Worktree
    worktree_key = $worktreeKey
    spec = $Spec
    task = $Task
    phase = $Phase
    sandbox = $Sandbox
    started = $leaseStarted
    log_path = $logPath
    effort = $Effort
    attended = $(if ($PSBoundParameters.ContainsKey('Attended')) { [bool]$Attended } else { $null })
    row_kind = 'lease'
    status = 'leasing'
}

# Orphan transition, capacity check, and lease append are one indivisible operation over THIS state
# root's ledger. The named mutex serializes all wrappers, but different APEX_STATE_DIR roots
# intentionally count different files and therefore enforce independent ceilings.
#
# Every writer, including ~/.claude/hooks/apex-ledger-append.ps1, blocks on ApexCodexRunLedger and
# gives up after 30 seconds. This mutex hold is therefore a hard latency budget, not a soft one.
Invoke-WithLedgerLock {
    [System.IO.Directory]::CreateDirectory($ledgerDirectory) | Out-Null
    $ledgerLines = if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
        [System.IO.File]::ReadAllLines($ledgerPath)
    }
    else {
        [string[]]@()
    }
    $openLeaseRunIds = @(Get-OpenLeaseRunIds -LedgerLines $ledgerLines)
    $orphanCandidates = [System.Collections.Generic.List[object]]::new()
    for ($lineIndex = 0; $lineIndex -lt $ledgerLines.Count; $lineIndex++) {
        $line = $ledgerLines[$lineIndex]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $row = $line | ConvertFrom-Json } catch { continue }

        $rowKind = if (@($row.PSObject.Properties.Name) -ccontains 'row_kind') {
            [string]$row.row_kind
        }
        else {
            'dispatch'
        }
        $rowStatus = [string]$row.status
        $unresolved = (
            ($rowKind -ceq 'dispatch' -and
                @('running', 'stalled', 'adopting') -ccontains $rowStatus) -or
            ($rowKind -ceq 'lease' -and $rowStatus -ceq 'leasing' -and
                $openLeaseRunIds -ccontains [string]$row.run_id)
        )
        if (-not $unresolved -or (Test-LedgerRowLive -Row $row)) { continue }

        $startedAt = [datetime]::MinValue
        if ($row.started) {
            try { $startedAt = ([datetime]$row.started).ToUniversalTime() } catch { }
        }
        $orphanCandidates.Add([pscustomobject]@{
            Index = $lineIndex
            Row = $row
            RowKind = $rowKind
            StartedAt = $startedAt
        })
    }

    $orphanBatch = @($orphanCandidates |
        Sort-Object -Property @{ Expression = 'StartedAt'; Ascending = $true },
            @{ Expression = 'Index'; Ascending = $true } |
        Select-Object -First 200)
    $script:orphanRowsDeferred = [Math]::Max(0, $orphanCandidates.Count - $orphanBatch.Count)
    if ($orphanBatch.Count -gt 0) {
        foreach ($candidate in $orphanBatch) {
            $candidate.Row.status = 'orphaned'
            $candidate.Row | Add-Member -NotePropertyName 'orphaned_at' `
                -NotePropertyValue (Get-UtcTimestamp) -Force
            if (@($candidate.Row.PSObject.Properties.Name) -ccontains 'ended') {
                $candidate.Row.PSObject.Properties.Remove('ended')
            }
            $ledgerLines[$candidate.Index] = $candidate.Row | ConvertTo-Json -Compress -Depth 8
            $script:newlyOrphanedRows += $candidate.Row
        }
        Set-LedgerLines -Lines ([string[]]$ledgerLines) -Caller 'OrphanScan' `
            -RowsChanged $orphanBatch.Count
    }

    $occupyingRows = @()
    $machineWeight = 0
    $specWeight = 0

    foreach ($line in $ledgerLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $row = $line | ConvertFrom-Json } catch { continue }
        $rowStatus = [string]$row.status
        if ([string]$row.phase -cne 'build' -or
                [string]$row.sandbox -cne 'workspace-write' -or
                @('leasing', 'running', 'stalled', 'adopting') -cnotcontains $rowStatus -or
                -not (Test-LedgerRowLive -Row $row)) {
            continue
        }
        if ($rowStatus -ceq 'leasing' -and
                $openLeaseRunIds -cnotcontains [string]$row.run_id) {
            continue
        }

        $rowWeight = if ([string]$row.effort -ceq 'ultra') { 2 } else { 1 }
        $machineWeight += $rowWeight
        if ([string]$row.spec -ceq $Spec) {
            $specWeight += $rowWeight
        }
        $occupyingRows += $row
    }

    $hitBounds = @()
    if (($machineWeight + $thisRunWeight) -gt $MachineCeiling) { $hitBounds += 'state-root' }
    if (($specWeight + $thisRunWeight) -gt $specCeiling) { $hitBounds += 'spec' }

    $script:capacityMachineWeight = $machineWeight
    $script:capacitySpecWeight = $specWeight
    $script:capacityOccupants = @($occupyingRows)
    if ($hitBounds.Count -gt 0) {
        $script:capacityRefusal = $hitBounds -join '+'
        return
    }

    foreach ($ledgerLine in $ledgerLines) {
        if ([string]::IsNullOrWhiteSpace($ledgerLine)) { continue }
        try { $existingRow = $ledgerLine | ConvertFrom-Json } catch { continue }
        if ([string]$existingRow.run_id -ceq [string]$leaseRow.run_id -and
                [string]$existingRow.row_kind -ceq [string]$leaseRow.row_kind) {
            throw "Refusing to append a second $([string]$leaseRow.row_kind) ledger row for run_id $([string]$leaseRow.run_id)."
        }
    }

    # LEASE-SCOPED refusals: 71, 72, 76, 78, 80, and 81 occur while this open lease exists and
    # close through the one outer finally. PRE-LEASE refusals: caller-contract 74 and at-capacity 79
    # occur before a lease row exists, so the same backstop appends nothing.
    $ledgerSeparator = ''
    if ((Test-Path -LiteralPath $ledgerPath) -and (Get-Item -LiteralPath $ledgerPath).Length -gt 0) {
        $ledgerText = [System.IO.File]::ReadAllText($ledgerPath)
        if (-not $ledgerText.EndsWith("`n") -and -not $ledgerText.EndsWith("`r")) {
            $ledgerSeparator = [Environment]::NewLine
        }
    }
    Add-Utf8NoBomText -Path $ledgerPath -Text (
        $ledgerSeparator + ($leaseRow | ConvertTo-Json -Compress -Depth 8) +
            [Environment]::NewLine)
    $script:leaseRegistered = $true
}

foreach ($orphanedRow in $script:newlyOrphanedRows) {
    $orphanedRowKind = if (@($orphanedRow.PSObject.Properties.Name) -ccontains 'row_kind') {
        [string]$orphanedRow.row_kind
    }
    else {
        'dispatch'
    }
    if ($orphanedRowKind -ceq 'lease') {
        Write-Host ((
            '[dispatch] ORPHANED LEASE {0} {2} nothing was dispatched; clear it with: ' +
            'powershell -NoProfile -ExecutionPolicy Bypass -File "{1}" -Attended ' +
            '-AbandonRunId {0} -AbandonReason "<why>"') -f
                $orphanedRow.run_id, $PSCommandPath, [char]0x2014) -ForegroundColor Yellow
    }
    else {
        Write-Host ((
            '[dispatch] ORPHANED RUN {0} {6} recover with: powershell -NoProfile ' +
            '-ExecutionPolicy Bypass -File "{1}" -Adopt -RunId {0} -Spec {2} ' +
            '-Phase {3} -Task {4} -Worktree "{5}"') -f
                $orphanedRow.run_id, $PSCommandPath, $orphanedRow.spec,
                $orphanedRow.phase, $orphanedRow.task, $orphanedRow.worktree,
                [char]0x2014) `
            -ForegroundColor Yellow
    }
}
if ($script:orphanRowsDeferred -gt 0) {
    Write-Host (
        '[dispatch] orphan scan deferred {0} additional dead unresolved row(s); ' +
        'the next dispatch scan will continue the bounded cleanup.' -f
            $script:orphanRowsDeferred) -ForegroundColor Yellow
}

if ($script:capacityRefusal) {
    Write-Host (
        ("[dispatch] AT CAPACITY (exit 79): bound={0}; machineWeight={1}+thisRun={2}/{3}; " +
        "specWeight={4}+thisRun={2}/{5}") -f $script:capacityRefusal,
            $script:capacityMachineWeight, $thisRunWeight, $MachineCeiling,
            $script:capacitySpecWeight, $specCeiling) -ForegroundColor Red
    foreach ($occupant in $script:capacityOccupants) {
        Write-Host (
            "[dispatch]   occupying: spec={0} task={1} pid={2} effort={3}" -f
            $occupant.spec, $occupant.task, $occupant.pid, $occupant.effort) -ForegroundColor Red
    }
    Exit-Dispatch 79
}

# The pre-flight pin spans every pre-launch operation, including the shared-worktree reservation and
# scope snapshot. The outer finally at the end of the script removes this invocation's pin on every
# exit or throw in that span; the successful path disarms it immediately before starting the child.
    if ($Phase -eq 'build' -and $Sandbox -eq 'workspace-write') {
        # Exit 76 = lease-scoped critical-file refusal -- lease + close event, NO dispatch row/log.
        # Known limit: a bare non-critical directory grant (for example, -Authorized src) may contain
        # a critical descendant; directory-shaped grants are valid and exhaustive expansion is deferred.
        $criticalScript = if ($CriticalFilesScript) { $CriticalFilesScript } else { Join-Path $PSScriptRoot 'apex-critical-files.ps1' }
        if (-not (Test-Path -LiteralPath $criticalScript)) {
            Write-Host '[dispatch] REFUSED (exit 76): apex-critical-files.ps1 missing -- cannot verify critical-file safety' -ForegroundColor Red
            Exit-Dispatch 76
        }

        if ($ScopeUnlocked) {
            if (-not $CriticalFilesConfirmed) {
                Write-Host '[dispatch] REFUSED (exit 76): -ScopeUnlocked build has no declared file set -- critical-file safety is unverifiable, pass -CriticalFilesConfirmed (attended) or park' -ForegroundColor Red
                Exit-Dispatch 76
            }
            Write-Host '[dispatch] -ScopeUnlocked build CONFIRMED (attended) -- critical-file safety unverifiable by design, proceeding on human confirmation' -ForegroundColor Yellow
        }
        else {
            $critExit = $null
            $critLines = @()
            try {
                & cmd /c exit 99
                $critLines = @(& $criticalScript -Test -Paths $Authorized -Root $Worktree)
                $critExit = $LASTEXITCODE
            } catch {
                $critExit = $null
            }
            $critLines | ForEach-Object { Write-Host $_ }

            if ($critExit -eq 11) {
                Write-Host '[dispatch] REFUSED (exit 76): -Authorized names a permanent hard block (docs/audit) -- not confirmable, cannot build' -ForegroundColor Red
                Exit-Dispatch 76
            }
            elseif ($critExit -eq 10 -and -not $CriticalFilesConfirmed) {
                Write-Host '[dispatch] REFUSED (exit 76): -Authorized names critical file(s) and -CriticalFilesConfirmed is absent -- a spec cannot self-approve; confirm attended (apex-code Layer A) or park' -ForegroundColor Red
                Exit-Dispatch 76
            }
            elseif ($critExit -eq 10) {
                Write-Host "[dispatch] critical-file edit CONFIRMED (attended) -- note: $CriticalFilesConfirmedNote" -ForegroundColor Yellow
            }
            elseif ($critExit -ne 0) {
                Write-Host "[dispatch] REFUSED (exit 76): critical-file classifier failed to return a valid verdict (got '$critExit') -- failing closed" -ForegroundColor Red
                Exit-Dispatch 76
            }
        }

        if ($SkipBaselineCheck) {
            Write-Host '[dispatch] -SkipBaselineCheck: baseline/spec pre-flight BYPASSED (bootstrap/emergency)' -ForegroundColor Yellow
            $baselineSkipped = $true
        }
        else {
            $preflightBaselineScript = Join-Path $PSScriptRoot 'apex-baseline-check.ps1'
            $preflightTreePinScript = Join-Path $PSScriptRoot 'tree-pin.ps1'
            $preflightSpecValidateScript = Join-Path $PSScriptRoot 'apex-spec-validate.ps1'

            foreach ($helper in @($preflightBaselineScript, $preflightTreePinScript, $preflightSpecValidateScript)) {
                if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
                    Write-Host "[dispatch] REFUSED (exit 72): $helper missing -- cannot run the baseline/spec pre-flight" -ForegroundColor Red
                    # Exit 72 = required pre-flight gate refused while the capacity lease is open.
                    Exit-Dispatch 72
                }
            }

            # Spec/task components are glob-safe by construction; cleanup's only wildcard is its
            # deliberately appended trailing '*', so it cannot remove a sibling dispatch's pin.
            $specSafe = ($Spec -replace '[^A-Za-z0-9._-]', '_')
            $taskSafe = ($Task -replace '[^A-Za-z0-9._-]', '_')
            $preflightPinLabel = "preflight-$specSafe-$taskSafe-$PID-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
            & $preflightTreePinScript -Pin -Worktree $Worktree -Label $preflightPinLabel -PinDirectory $harnessStateDir | Write-Host
            $preflightPinArmed = ($LASTEXITCODE -eq 0)
            if (-not $preflightPinArmed) {
                Write-Host "[dispatch] REFUSED (exit 72): tree-pin failed to arm -- cannot guarantee the pre-flight tree" -ForegroundColor Red
                # Exit 72 = required pre-flight gate refused while the capacity lease is open.
                Exit-Dispatch 72
            }

            # Nested Join-Path calls preserve Windows PowerShell 5.1 compatibility.
            $specDirectory = Join-Path $Worktree 'docs\changes'
            $specFile = Join-Path $specDirectory "$Spec.md"
            if (Test-Path -LiteralPath $specFile -PathType Leaf) {
                $specFindings = @(& $preflightSpecValidateScript -SpecPath $specFile)
                $specValidateExit = $LASTEXITCODE
                foreach ($finding in $specFindings) { Write-Host $finding }
                if ($specValidateExit -eq 1) {
                    $findingText = if ($specFindings.Count -gt 0) { $specFindings -join '; ' } else { 'validator returned exit 1' }
                    Write-Host "[dispatch] REFUSED (exit 72): spec validation failed -- $findingText" -ForegroundColor Red
                    # Exit 72 = required pre-flight gate refused while the capacity lease is open.
                    Exit-Dispatch 72
                }
                if ($specValidateExit -ne 0) {
                    throw "apex-spec-validate returned unexpected exit code $specValidateExit"
                }
            }
            else {
                if ($PSBoundParameters.ContainsKey('SpecSourcePath')) {
                    $isDriveAbsolute = $SpecSourcePath -match '^[A-Za-z]:[\\/]'
                    $isUncPath = $SpecSourcePath -match '^\\\\'
                    if (-not ($isDriveAbsolute -or $isUncPath)) {
                        Write-Host "[dispatch] REFUSED (exit 72): -SpecSourcePath '$SpecSourcePath' violates the documented contract: expected a drive-absolute or UNC path" -ForegroundColor Red
                        # A cross-tree spec must have an unambiguous fully-qualified identity before validation.
                        Exit-Dispatch 72
                    }
                    if (-not (Test-Path -LiteralPath $SpecSourcePath -PathType Leaf)) {
                        Write-Host "[dispatch] REFUSED (exit 72): cross-tree spec source file does not exist: '$SpecSourcePath'" -ForegroundColor Red
                        # A cross-tree build must validate an existing leaf spec before dispatch.
                        Exit-Dispatch 72
                    }

                    $specSourceBasename = [System.IO.Path]::GetFileNameWithoutExtension($SpecSourcePath)
                    if (-not [string]::Equals($specSourceBasename, $Spec, [System.StringComparison]::OrdinalIgnoreCase)) {
                        Write-Host "[dispatch] REFUSED (exit 72): -Spec '$Spec' does not match cross-tree source basename '$specSourceBasename'" -ForegroundColor Red
                        # Bind a cross-tree source to the requested spec so another spec cannot be substituted.
                        Exit-Dispatch 72
                    }

                    $specFindings = @(& $preflightSpecValidateScript -SpecPath $SpecSourcePath)
                    $specValidateExit = $LASTEXITCODE
                    foreach ($finding in $specFindings) { Write-Host $finding }
                    if ($specValidateExit -eq 1) {
                        $findingText = if ($specFindings.Count -gt 0) { $specFindings -join '; ' } else { 'validator returned exit 1' }
                        Write-Host "[dispatch] REFUSED (exit 72): spec validation failed -- $findingText" -ForegroundColor Red
                        # A cross-tree spec that fails validation must refuse before dispatch transition.
                        Exit-Dispatch 72
                    }
                    if ($specValidateExit -ne 0) {
                        throw "apex-spec-validate returned unexpected exit code $specValidateExit"
                    }
                }
                else {
                    Write-Host "[dispatch] REFUSED (exit 72): no in-worktree spec at docs/changes/$Spec.md; pass -SpecSourcePath <absolute path> for a cross-tree build, or -SkipBaselineCheck for a deliberate bootstrap" -ForegroundColor Red
                    # A cross-tree build cannot proceed without an explicitly supplied spec to validate.
                    Exit-Dispatch 72
                }
            }

            # Validate the dispatch contract before executing any repository-provided recipe.
            & $preflightBaselineScript -Preflight -Worktree $Worktree
            $baselineExit = $LASTEXITCODE
            if ($baselineExit -in @(1, 3, 4)) {
                Write-Host "[dispatch] REFUSED (exit 72): red baseline -- apex-baseline-check exit $baselineExit" -ForegroundColor Red
                # Exit 72 = required pre-flight gate refused while the capacity lease is open.
                Exit-Dispatch 72
            }
            if ($baselineExit -ne 0) {
                throw "apex-baseline-check returned unexpected exit code $baselineExit"
            }

            $declaredRuntimePaths = Get-SpecFrontmatterValue -Key 'declared_runtime_paths'
            if ($declaredRuntimePaths -is [string] -and
                    $declaredRuntimePaths -ceq '__APEX_FRONTMATTER_UNPARSEABLE__') {
                Write-Host '[dispatch] REFUSED (exit 81): declared_runtime_paths present but unparseable' -ForegroundColor Red
                Exit-Dispatch 81
            }

            if ($null -ne $declaredRuntimePaths) {
                # This proves visibility in this worktree at this commit only. It says nothing about
                # other worktrees or the integration branch; later divergence there is out of scope.
                $invisibleRuntimePaths = @()
                foreach ($declaredRuntimePath in @($declaredRuntimePaths)) {
                    $lsFilesExit = $null
                    $checkIgnoreExit = $null
                    $previousErrorActionPreference = $ErrorActionPreference
                    $ErrorActionPreference = 'Continue'
                    try {
                        & cmd /c exit 99
                        try {
                            $null = @(& git -C $Worktree ls-files --error-unmatch -- $declaredRuntimePath 2>&1)
                        }
                        catch { }
                        $lsFilesExit = $LASTEXITCODE

                        & cmd /c exit 99
                        try {
                            $null = @(& git -C $Worktree check-ignore -q -- $declaredRuntimePath 2>&1)
                        }
                        catch { }
                        $checkIgnoreExit = $LASTEXITCODE
                    }
                    finally {
                        $ErrorActionPreference = $previousErrorActionPreference
                    }

                    if ($lsFilesExit -ne 0) {
                        $reason = if ($checkIgnoreExit -eq 0) {
                            'gitignored-invisible to worktrees'
                        }
                        else {
                            'declared path is not tracked at this commit'
                        }
                        $invisibleRuntimePaths += [pscustomobject]@{
                            Path = [string]$declaredRuntimePath
                            LsFilesExit = $lsFilesExit
                            CheckIgnoreExit = $checkIgnoreExit
                            Reason = $reason
                        }
                    }
                }

                if ($invisibleRuntimePaths.Count -gt 0) {
                    foreach ($offendingPath in $invisibleRuntimePaths) {
                        # A plain pipeline string preserves this per-path diagnostic byte-for-byte
                        # when a parent PowerShell process captures it. Write-Host produces a host
                        # information record whose rendering can wrap the path/reason/exit evidence.
                        Write-Output ("[dispatch] REFUSED (exit 81): declared_runtime_paths '{0}': {1} (ls-files exit {2}; check-ignore exit {3})" -f
                                $offendingPath.Path, $offendingPath.Reason, $offendingPath.LsFilesExit,
                                $offendingPath.CheckIgnoreExit)
                    }
                    Exit-Dispatch 81
                }
            }
        }
    }
    else {
        Write-Host '[dispatch] pre-flight skipped (phase/sandbox)' -ForegroundColor DarkGray
    }

$started = Get-UtcTimestamp
$headSha = ''
$previous = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $headResult = (& git -C $Worktree rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -eq 0) { $headSha = ([string]$headResult).Trim() }
} catch {
    $headSha = ''
} finally {
    $ErrorActionPreference = $previous
}
$coderModel = 'gpt-5.6-sol'
$ledgerRow = [ordered]@{
    run_id = $runId
    pid = $null
    # The LAUNCHER's pid, recorded BEFORE the child exists. Between Add-LedgerRow and the moment the
    # child's pid is known, `pid` is null -- and a sibling scanning in that window would see no live
    # process and conclude the tree was free, then revert the very files this run is about to write.
    # The launcher is alive for the whole dispatch, so it closes that window.
    launcher_pid = $PID
    launcher_start = (Get-ProcessStamp $PID)
    pid_start = $null
    worktree = $Worktree
    worktree_key = $worktreeKey   # canonical: git's repo root, not the caller's spelling of the path
    spec = $Spec
    task = $Task
    base_sha = $BaseSha
    head_sha = $headSha
    phase = $Phase
    started = $started
    log_path = $logPath
    effort = $Effort
    attended = $(if ($PSBoundParameters.ContainsKey('Attended')) { [bool]$Attended } else { $null })
    final_path = $finalPath
    schema = $schemaFile
    sandbox = $Sandbox
    baseline_skipped = [bool]$baselineSkipped
    # What this run ARMED, so -Adopt can run the gates the dead wrapper never reached.
    scope_armed = ($Authorized.Count -gt 0)
    scope_task = $gateKey
    authorized = @($Authorized)
    scope_unlocked = [bool]$ScopeUnlocked
    scope_unlocked_reason = $(if ($ScopeUnlocked) { $ScopeUnlockedReason } else { '' })
    shared_worktree = [bool]$AllowSharedWorktree
    shared_worktree_reason = $(if ($AllowSharedWorktree) { $AllowSharedWorktreeReason } else { '' })
    tree_pin_disabled = [bool]$NoTreePin
    tree_pin_disabled_reason = $(if ($NoTreePin) { $NoTreePinReason } else { '' })
    tree_pin_override = ([bool]$TreePinScript -and [bool]$ReviewedRunId)
    critical_files_confirmed = [bool]$CriticalFilesConfirmed
    critical_files_confirmed_note = $(if ($CriticalFilesConfirmed) { $CriticalFilesConfirmedNote } else { '' })
    builder_family = $(if ($Phase -eq 'build') { Get-ModelFamily $coderModel } else { '' })
    reviewer_family = $(if ($Phase -eq 'review' -or $Schema -eq 'review' -or $Schema -eq 'endgate') { Get-ModelFamily $coderModel } else { '' })
    reviewed_run_id = $(if ($Phase -eq 'review' -or $Schema -eq 'review' -or $Schema -eq 'endgate') { $ReviewedRunId } else { '' })
    reviewed_tree_digest = ''
    tree_pin_label = $null
    row_kind = 'dispatch'
    status = 'running'
}

# Resolve the referenced build before reserving anything. This lookup is deliberately stricter than
# a prefix/status-family match: an adopted build with a scope suffix is not a bindable review target.
$script:reviewedBuildFound = $false
$script:reviewedEndTreeDigestPresent = $false
$script:reviewedEndTreeDigest = ''
if (-not [string]::IsNullOrEmpty($ReviewedRunId)) {
    Invoke-WithLedgerLock {
        if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { return }

        foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $row = $line | ConvertFrom-Json } catch { continue }

            if ($row.run_id -ceq $ReviewedRunId -and $row.phase -ceq 'build' -and
                    @('done', 'done_with_concerns', 'success', 'adopted-done') -ccontains [string]$row.status) {
                $script:reviewedBuildFound = $true
                $script:reviewedEndTreeDigestPresent =
                    (@($row.PSObject.Properties.Name) -ccontains 'end_tree_digest')
                if ($script:reviewedEndTreeDigestPresent) {
                    $script:reviewedEndTreeDigest = [string]$row.end_tree_digest
                }
                break
            }
        }
    }

    if (-not $script:reviewedBuildFound) {
        Write-Host "[dispatch] REFUSED (exit 78): reviewed build '$ReviewedRunId' was not found in an exact terminal-success build row." -ForegroundColor Red
        Exit-Dispatch 78
    }
}

# head_sha is the reservation-time HEAD. The pre-flight pin covers movement to launch on the normal
# path; under -SkipBaselineCheck this comparison is advisory only.
if (-not [string]::IsNullOrWhiteSpace($BaseSha) -and
        -not [string]::IsNullOrWhiteSpace($headSha) -and $BaseSha -ne $headSha) {
    Write-Host "[dispatch] WARN: -BaseSha '$BaseSha' differs from reservation-time HEAD '$headSha'; proceeding." -ForegroundColor Yellow
}

# --- ONE CODER PER WORKING TREE: scan and reserve, ATOMICALLY ----------------------------------
# Two Codex workers in one tree is not "parallelism", it is a data race with a delete in it. Their
# writes interleave, and the first one to FINISH runs a scope check that cannot tell the other's
# in-progress files from its own out-of-scope writes -- so it reverts them. Untracked files, deleted
# outright, no git object, unrecoverable. Live: al-7c-quiet-gate (2026-07-14), where Task 4 deleted
# Task 5's freshly-written files while Task 5 was still running. The scope check now refuses to
# revert while a sibling is live (exit 70) -- that is the airbag. This is the seatbelt.
#
# Scan-then-write as two steps is itself a race: both dispatches finish the scan before either
# records a row, and both launch. So the scan and the reservation happen inside ONE hold of the
# ledger mutex -- the check is only as exclusive as the write that follows it.
#
# Wave-parallel dispatch (ADR-028) is still correct. It just requires ONE WORKTREE PER CONCURRENT
# TASK (`git worktree add`), which is what -Worktree is for.
$script:refused = $null
$script:malformedRefusal = $null
$script:unresolvedRefusal = $null
Invoke-WithLedgerLock {
    $script:malformedLiveLedgerLine = $null
    $reservationLedgerLines = if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
        [System.IO.File]::ReadAllLines($ledgerPath)
    }
    else {
        [string[]]@()
    }
    $liveHere = @(Get-LiveDispatches -WorktreeKey $worktreeKey -ExcludeRunId $runId `
        -LedgerLines $reservationLedgerLines)
    if ($script:malformedLiveLedgerLine) {
        $script:malformedRefusal = $script:malformedLiveLedgerLine
        return
    }
    if ($liveHere.Count -gt 0 -and -not $AllowSharedWorktree) {
        $script:refused = $liveHere
        return
    }
    $unresolvedHere = @(Get-UnresolvedWorktreeRows -WorktreeKey $worktreeKey `
        -ExcludeRunId $runId -LedgerLines $reservationLedgerLines)
    if ($AllowSharedWorktree -and $liveHere.Count -gt 0) {
        $liveSiblingIds = @($liveHere | ForEach-Object { [string]$_.run_id })
        $unresolvedHere = @($unresolvedHere | Where-Object {
                $liveSiblingIds -cnotcontains [string]$_.run_id
            })
    }
    if ($unresolvedHere.Count -gt 0) {
        $script:unresolvedRefusal = $unresolvedHere[0]
        return
    }
    $ledgerChanges = @{}
    foreach ($ledgerField in $ledgerRow.GetEnumerator()) {
        $ledgerChanges[$ledgerField.Key] = $ledgerField.Value
    }
    Update-LedgerRow -RunId $runId -RowKind 'lease' -Changes $ledgerChanges
    # The lease row is now the launched run's dispatch row. It is no longer eligible for refusal
    # closure, even if a later launch/setup operation throws.
    $script:leaseRegistered = $false
}

if ($script:malformedRefusal) {
    $badLedgerLine = [string]$script:malformedRefusal
    if ($badLedgerLine.Length -gt 240) { $badLedgerLine = $badLedgerLine.Substring(0, 240) + '...' }
    Write-Host "[dispatch] REFUSED (exit 71): a ledger line could not be parsed: $badLedgerLine" -ForegroundColor Red
    Write-Host '[dispatch] Its reservation may still be live. Repair or expire the row before dispatching into this worktree.' -ForegroundColor Red
    Exit-Dispatch 71
}

if ($script:refused) {
    Write-Host ''
    Write-Host "[dispatch] REFUSING TO LAUNCH - a Codex worker is already running in this working tree:" -ForegroundColor Red
    foreach ($l in $script:refused) { Write-Host ("      {0}/{1}  pid {2}  status {3}" -f $l.spec, $l.task, $l.pid, $l.status) -ForegroundColor Red }
    Write-Host "[dispatch] Two coders in one tree is a data race with a DELETE in it: whichever finishes first" -ForegroundColor Red
    Write-Host "[dispatch] runs a scope check that cannot tell the other's in-progress files from its own" -ForegroundColor Red
    Write-Host "[dispatch] out-of-scope writes, and reverts them. That destroyed real work on 2026-07-14." -ForegroundColor Red
    Write-Host ''
    Write-Host "[dispatch] Give each concurrent task its OWN worktree:" -ForegroundColor Yellow
    Write-Host "[dispatch]     git worktree add ../wt-$safeTask $BaseSha" -ForegroundColor Yellow
    Write-Host "[dispatch] then pass it as -Worktree. Or dispatch serially. -AllowSharedWorktree with a recorded reason overrides." -ForegroundColor Yellow
    Write-Host ''
    Exit-Dispatch 71
}

if ($script:unresolvedRefusal) {
    $blockedRow = $script:unresolvedRefusal
    Write-Host (
        "[dispatch] REFUSED (exit 80): worktree has unresolved run_id={0}, status={1}." -f
            $blockedRow.run_id, $blockedRow.status) -ForegroundColor Red
    Write-Host (
        ('[dispatch] adopt: powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" ' +
        '-Adopt -RunId {1} -Spec {2} -Phase {3} -Task {4} -Worktree "{5}"') -f
            $PSCommandPath, $blockedRow.run_id, $blockedRow.spec, $blockedRow.phase,
            $blockedRow.task, $blockedRow.worktree) -ForegroundColor Yellow
    Write-Host (
        ('[dispatch] abandon: powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" ' +
        '-Attended -AbandonRunId {1} -AbandonReason "<why>"') -f
            $PSCommandPath, $blockedRow.run_id) -ForegroundColor Yellow
    Exit-Dispatch 80
}

Write-Utf8NoBomText -Path $logPath -Text ([string]::Empty)

if ($AllowSharedWorktree) {
    Write-Host "[dispatch] -AllowSharedWorktree: LIVE-WORKER REFUSAL DELIBERATELY OVERRIDDEN -- reason: $AllowSharedWorktreeReason" -ForegroundColor Yellow
}
if ($NoTreePin) {
    Write-Host "[dispatch] -NoTreePin: READ-ONLY TREE PIN DELIBERATELY DISABLED -- reason: $NoTreePinReason" -ForegroundColor Yellow
}

# --- Host-side scope enforcement (snapshot) -------------------------------------------------------
# The prose scope lock below is NOT the enforcement. It is a courtesy. Codex has been given that
# rule, in those words, and has written outside its scope anyway -- prohibitions do not enforce.
# The mechanism is codex-scope-check.ps1: snapshot the dirty set BEFORE launch, diff it AFTER exit,
# revert anything unauthorized that was clean at snapshot time. Wiring it into the dispatcher --
# rather than documenting it as a step for the host to remember -- is the whole point. A procedure a
# human has to remember is the procedure that gets skipped at 2am.
$scopeCheckScript = Join-Path $PSScriptRoot 'codex-scope-check.ps1'
$scopeCheckArmed = $false
if ($Authorized.Count -gt 0) {
    if (-not (Test-Path $scopeCheckScript)) {
        # A gate that quietly disappears when its file is missing is not a gate. The caller ASKED for
        # scope enforcement; running the build without it and reporting success is the worst possible
        # answer. Refuse.
        Update-LedgerRow -RunId $runId -RowKind 'dispatch' -Changes @{ status = 'failed'; ended = (Get-UtcTimestamp); error = 'codex-scope-check.ps1 missing' }
        throw "-Authorized was given but codex-scope-check.ps1 is missing ($scopeCheckScript). Refusing to dispatch without the enforcement that was asked for."
    }
    else {
        & $scopeCheckScript -Snapshot -Worktree $Worktree -Task $gateKey -StateDirectory $harnessStateDir -Authorized $Authorized | Write-Host
        $scopeCheckArmed = $true
    }
}
elseif ($ScopeUnlocked) {
    Write-Host "[dispatch] -ScopeUnlocked: scope lock DELIBERATELY DISABLED for this dispatch -- reason: $ScopeUnlockedReason" -ForegroundColor Yellow
}
elseif (-not $SkipScopeCheck) {
    Write-Host "[dispatch] NOTE: no -Authorized file list given, so the scope lock is prose only and unenforced." -ForegroundColor Yellow
    Write-Host "[dispatch]       Pass -Authorized with the spec's '## Files to change' list to enforce it, or -SkipScopeCheck to silence this." -ForegroundColor Yellow
}

# --- Tree pin: WIRED IN, not written down ------------------------------------------------------
# A read-only gate (a review, an end-gate) reads the tree at time T and returns a verdict at T+n.
# If the tree moves in between, the verdict describes a tree that no longer exists -- and the
# dangerous direction is a CLEAN verdict on code that nobody actually reviewed.
#
# tree-pin.ps1 was written for exactly this and then WIRED INTO NOTHING: it lived only as a step in
# apex-code's SKILL.md for the host to remember. That is precisely the mistake this session spent
# the whole day correcting in everything else -- "mechanism beats instruction, including when you
# are the one writing the instruction" -- committed by the person writing that sentence. Caught by
# the cross-family review, which is the entire reason an agent does not review its own work.
$treePinScript = Join-Path $PSScriptRoot 'tree-pin.ps1'
$treePinLabel = $gateKey
$treePinArmed = $false
$reviewTreePinPath = $null
$isReadOnlyGate = ($Sandbox -eq 'read-only' -or $Phase -eq 'review')
if ((-not $NoTreePin) -and $isReadOnlyGate -and -not (Test-Path $treePinScript)) {
    Update-LedgerRow -RunId $runId -RowKind 'dispatch' -Changes @{ status = 'failed'; ended = (Get-UtcTimestamp); error = 'tree-pin.ps1 missing' }
    throw "A read-only gate must be pinned, but tree-pin.ps1 is missing ($treePinScript). Refusing: an unpinned gate can bless a tree that moved under it. Pass -NoTreePin -NoTreePinReason '<why>' to opt out deliberately."
}
if ((-not $NoTreePin) -and $isReadOnlyGate -and (Test-Path $treePinScript)) {
    & $treePinScript -Pin -Worktree $Worktree -Label $treePinLabel -PinDirectory $harnessStateDir | Write-Host
    $treePinArmed = ($LASTEXITCODE -eq 0)
    if ($treePinArmed) {
        # Keep this coupled to tree-pin.ps1: safeLabel is line 60; worktreeTag/path are lines 209-219;
        # treepin-v2 serialization (digest on LINE 2) is lines 230-233.
        $safeTreePinLabel = ($treePinLabel -replace '[<>:"/\\|?*]', '_')
        $worktreeFull = (Resolve-Path -LiteralPath $Worktree).Path
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $keyBytes = [System.Text.Encoding]::UTF8.GetBytes(
                ($worktreeFull -replace '\\', '/').TrimEnd('/').ToLowerInvariant())
            $worktreeTag = [System.BitConverter]::ToString($sha.ComputeHash($keyBytes)).Replace('-', '').Substring(0, 10).ToLower()
        }
        finally { $sha.Dispose() }
        $reviewTreePinPath = Join-Path $harnessStateDir "apex-treepin-$safeTreePinLabel-$worktreeTag.txt"
        try { Update-LedgerRow -RunId $runId -RowKind 'dispatch' -Changes @{ tree_pin_label = $treePinLabel } } catch { }
    }
}

# -NoTreePin governs only pin arming, not review-to-build binding. With a pin, read the digest that
# the -Pin call just stored so the compared tree and pinned tree are the same object (no TOCTOU gap).
if ($isReadOnlyGate -and -not [string]::IsNullOrEmpty($ReviewedRunId)) {
    if (-not $script:reviewedEndTreeDigestPresent) {
        Write-Host "[dispatch] WARN: reviewed build '$ReviewedRunId' predates end_tree_digest; proceeding without digest binding." -ForegroundColor Yellow
    }
    elseif ([string]::IsNullOrWhiteSpace($script:reviewedEndTreeDigest) -or
            $script:reviewedEndTreeDigest -ceq 'unverifiable') {
        Update-LedgerRow -RunId $runId -RowKind 'dispatch' -Changes @{
            status = 'failed'; ended = (Get-UtcTimestamp); digest_mismatch = $true
        }
        Write-Host "[dispatch] REFUSED (exit 78): reviewed build '$ReviewedRunId' has no verifiable end_tree_digest." -ForegroundColor Red
        exit 78
    }
    else {
        $live = ''
        try {
            if ($treePinArmed) {
                $pinLines = [System.IO.File]::ReadAllLines($reviewTreePinPath)
                if ($pinLines.Count -ge 2 -and $pinLines[0] -ceq 'treepin-v2') {
                    $live = [string]$pinLines[1]
                }
            }
            elseif ($NoTreePin) {
                & cmd /c exit 99
                $liveLines = @(& $digestScript -Digest -Worktree $Worktree)
                $liveExit = $LASTEXITCODE
                if ($liveExit -eq 0) {
                    $live = ([string[]]$liveLines -join [Environment]::NewLine).Trim()
                }
            }
        }
        catch {
            $live = ''
        }

        if ($live -cnotmatch '^[0-9A-Fa-f]{64}$') {
            Update-LedgerRow -RunId $runId -RowKind 'dispatch' -Changes @{
                status = 'failed'; ended = (Get-UtcTimestamp); digest_mismatch = $true
            }
            Write-Host '[dispatch] REFUSED (exit 78): the live review tree digest is unreadable or unverifiable.' -ForegroundColor Red
            exit 78
        }
        if ($live -cne $script:reviewedEndTreeDigest) {
            Update-LedgerRow -RunId $runId -RowKind 'dispatch' -Changes @{
                status = 'failed'; ended = (Get-UtcTimestamp); digest_mismatch = $true
            }
            Write-Host "[dispatch] REFUSED (exit 78): the live review tree does not match reviewed build '$ReviewedRunId'." -ForegroundColor Red
            exit 78
        }

        Update-LedgerRow -RunId $runId -RowKind 'dispatch' -Changes @{ reviewed_tree_digest = $live }
    }
}

# Standing scope lock, appended to EVERY dispatch. Belt-and-braces only -- see above.
# A planning host commonly edits docs/status.md in the same working tree while a build runs; Codex
# has repeatedly rewritten it out of scope-lock, and a blanket revert of it has already destroyed
# concurrent owner planning work once.
$scopeLock = @'

---
STANDING SCOPE LOCK (applies to every dispatch; overrides anything above that conflicts):
- Do NOT read, write, edit, or create docs/status.md. It is owned by the planning host, who is very
  likely editing it RIGHT NOW in this same working tree. Any write you make to it destroys their
  work. If you believe it needs updating, say so in your final report instead.
- Do NOT edit any file outside the scope this dispatch named. That includes other specs under
  docs/changes/, other runbooks, and any doc you were not explicitly asked to change.
- Do NOT run `git commit`, `git add`, `git push`, `git checkout --`, `git reset`, or `git stash`.
  The host integrates and commits; you only leave changes in the working tree.
'@
$Prompt = $Prompt + $scopeLock



$arguments = @(
    'exec', '-p', 'apex-coder', '--sandbox', $Sandbox, '-m', $coderModel,
    '-c', "model_reasoning_effort=$Effort", '-C', $Worktree, '--json', '--output-schema',
    $schemaPath, '-o', $finalPath, '--color', 'never'
) | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }

# ProcessStartInfo uses CreateProcess rather than PowerShell command resolution.
# The npm installation exposes `codex` to PowerShell as codex.ps1; invoke its
# node entry point directly because a .cmd shim is not executable with
# UseShellExecute = $false.
# Everything from here on can throw, and the ledger row already says `running`. A throw between the
# reservation and the main try left that row `running` FOREVER -- and a permanently-live phantom row
# makes every future dispatch into this worktree exit 71, wedging the harness until someone edits the
# ledger by hand. (I claimed this was fixed in a review pack before writing it; it was not.)
try {
    $resolvedCodexExecutable = $CodexExecutable
    $prefixArguments = @($CodexExecutableArgumentPrefix | ForEach-Object {
            ConvertTo-ProcessArgument ([string]$_)
        })
    $resolvedArguments = $prefixArguments + $arguments
    if ($CodexExecutable -eq 'codex') {
        $codexCommand = @(Get-Command codex -CommandType Application, ExternalScript -ErrorAction Stop)[0]
        if ($codexCommand.CommandType -eq 'ExternalScript') {
            $npmBinDirectory = Split-Path $codexCommand.Source -Parent
            $nodePath = Join-Path $npmBinDirectory 'node.exe'
            $codexEntryPoint = Join-Path $npmBinDirectory 'node_modules\@openai\codex\bin\codex.js'
            if (-not (Test-Path -LiteralPath $codexEntryPoint -PathType Leaf)) {
                throw "The PowerShell Codex command has no node entry point: $codexEntryPoint"
            }
            $resolvedCodexExecutable = if (Test-Path -LiteralPath $nodePath -PathType Leaf) { $nodePath } else { 'node' }
            $resolvedArguments = @((ConvertTo-ProcessArgument $codexEntryPoint)) + $prefixArguments + $arguments
        } else {
            $resolvedCodexExecutable = $codexCommand.Source
        }
    }
} catch {
    Update-LedgerRow -RunId $runId -RowKind 'dispatch' -Changes @{ status = 'failed'; ended = (Get-UtcTimestamp); error = $_.Exception.Message }
    throw
}

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $resolvedCodexExecutable
$startInfo.Arguments = [string]::Join(' ', [string[]]$resolvedArguments)
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$appendLogText = {
    param([string]$Text)
    if ($Text.Length -gt 0) {
        Add-Utf8NoBomText -Path $logPath -Text $Text
    }
}

if ($preflightPinArmed) {
    & $preflightTreePinScript -Verify -Worktree $Worktree -Label $preflightPinLabel -PinDirectory $harnessStateDir | Write-Host
    $preflightVerifyExit = $LASTEXITCODE
    if ($preflightVerifyExit -ne 0) {
        Update-LedgerRow -RunId $runId -RowKind 'dispatch' -Changes @{ status = 'failed'; ended = (Get-UtcTimestamp); error = 'tree moved under the pre-flight pin' }
        Write-Host '[dispatch] REFUSED (exit 69): tree moved between pre-flight and launch -- the verified tree is not the tree the coder would get' -ForegroundColor Red
        # Exit 69 = the pinned tree moved, so the launch-boundary verdict is void.
        exit 69
    }

    $safe = ($preflightPinLabel -replace '[<>:"/\\|?*]', '_')
    $preflightPinGlob = Join-Path $harnessStateDir "apex-treepin-$safe-*.txt"
    Remove-Item -Path $preflightPinGlob -Force -ErrorAction SilentlyContinue
    $preflightPinArmed = $false
}

try {
    if (-not $process.Start()) { throw 'Failed to start codex exec.' }

    # Record the pid the INSTANT the child exists -- before writing stdin. The prompt write below is
    # asynchronous precisely because it can block, and a blocked write must never hide that the child
    # was launched: a null pid in the ledger reads as "reserved but never launched" and wedges the
    # shared-worktree guard for every future dispatch into this tree.
    Update-LedgerRow -RunId $runId -RowKind 'dispatch' -Changes @{ pid = $process.Id; pid_start = (Get-ProcessStamp $process.Id) }

    # Service ALL THREE pipes concurrently. A synchronous StandardInput.Write($Prompt) here deadlocks
    # the wrapper: `codex exec --json` streams events to stdout from launch, so for a prompt larger
    # than the OS stdin pipe buffer (~64 KB on Windows) codex fills its stdout pipe -- which nobody is
    # draining yet -- and stops reading stdin, so the write never returns and the drain loop below is
    # never reached. The live signature was exact: a reserved ledger row with the pid recorded but a
    # 0-byte log, and a caller that died at its own timeout. So: start the stdout/stderr reads FIRST,
    # write the prompt ASYNCHRONOUSLY, and close stdin once the write drains. (The original fake codex
    # hid this for months because it drained stdin to EOF before emitting any stdout -- the one
    # ordering under which the deadlock cannot happen. dispatch-deadlock-test.ps1 reproduces it.)
    #
    # The buffer is large and the poll is short (below) so real-size output -- megabytes of JSON over
    # a build -- actually ferries: at the old 4096 chars per 1-second tick it drained at ~4 KB/s, slow
    # enough to keep codex's stdout pipe full and re-open the very window this fix closes.
    $bufferSize = 65536
    $stdoutBuffer = New-Object char[] $bufferSize
    $stderrBuffer = New-Object char[] $bufferSize
    $stdoutTask = $process.StandardOutput.ReadAsync($stdoutBuffer, 0, $bufferSize)
    $stderrTask = $process.StandardError.ReadAsync($stderrBuffer, 0, $bufferSize)
    # ADR-033's load-bearing behavior is preserved -- the WHOLE dispatch pack is written and stdin is
    # closed so Codex never waits on more input -- but asynchronously, so it cannot block the reads.
    #
    # Write EXPLICIT UTF-8 BYTES to the raw pipe. StandardInput is a StreamWriter whose encoding is the
    # ambient code page (CP1252 on a typical Windows console), so a prompt carrying any non-ASCII --
    # and an em-dash is in nearly every spec -- reached codex mis-encoded, and codex, which reads stdin
    # as UTF-8, rejected the ENTIRE prompt: "input is not valid UTF-8 (invalid byte at offset N)".
    # Writing bytes to BaseStream bypasses the writer's encoding. We then close the BaseStream directly
    # (below), NOT the StreamWriter: closing the writer flushes ITS preamble, and a BOM-bearing ambient
    # encoding appends EF BB BF after the prompt, so stdin would no longer be byte-exact (caught in
    # cross-family review). The final $process.Dispose() is guarded, since it re-disposes that writer
    # over the now-closed stream.
    $promptBytes = [System.Text.Encoding]::UTF8.GetBytes($Prompt)
    $stdinTask = $process.StandardInput.BaseStream.WriteAsync($promptBytes, 0, $promptBytes.Length)
    $stdinClosed = $false
    $stdoutClosed = $false
    $stderrClosed = $false
    $stalled = $false
    $nextWatchCheck = (Get-Date).AddSeconds(15)
    while (-not $process.HasExited) {
        # Close stdin as soon as the async write drains, so Codex sees EOF and proceeds. Observe the
        # task first (only once completed, so this never blocks) to swallow a broken-pipe fault from a
        # child that exited early.
        if (-not $stdinClosed -and $stdinTask.IsCompleted) {
            try { $null = $stdinTask.GetAwaiter().GetResult() } catch {}
            try { $process.StandardInput.BaseStream.Close() } catch {}
            $stdinClosed = $true
        }
        if ($stdoutTask.IsCompleted) {
            $stdoutCount = $stdoutTask.Result
            if ($stdoutCount -gt 0) {
                & $appendLogText ([string]::new($stdoutBuffer, 0, $stdoutCount))
                $stdoutTask = $process.StandardOutput.ReadAsync($stdoutBuffer, 0, $bufferSize)
            } else {
                $stdoutClosed = $true
            }
        }
        if ($stderrTask.IsCompleted) {
            $stderrCount = $stderrTask.Result
            if ($stderrCount -gt 0) {
                & $appendLogText ([string]::new($stderrBuffer, 0, $stderrCount))
                $stderrTask = $process.StandardError.ReadAsync($stderrBuffer, 0, $bufferSize)
            } else {
                $stderrClosed = $true
            }
        }

        Start-Sleep -Milliseconds 50
        $process.Refresh()
        if ($process.HasExited) { break }

        if ((Get-Date) -ge $nextWatchCheck) {
            $lastWrite = (Get-Item -LiteralPath $logPath).LastWriteTime
            if (((Get-Date) - $lastWrite).TotalMinutes -ge $NoOutputTimeoutMin) {
                Update-LedgerRow -RunId $runId -RowKind 'dispatch' -Changes @{ status = 'stalled'; stalled = (Get-UtcTimestamp) }
                $stalled = $true
                break
            }
            $nextWatchCheck = (Get-Date).AddSeconds(15)
        }
    }

    if ($stalled) {
        # Do not kill the child: the caller owns that decision.
        exit 124
    }

    # The child has exited. Close stdin if the write never drained (child died before consuming it),
    # so the pipe handle is released before we wait. The process is already gone, so this cannot block.
    if (-not $stdinClosed) { try { $process.StandardInput.BaseStream.Close() } catch {}; $stdinClosed = $true }

    $process.WaitForExit()
    while (-not ($stdoutClosed -and $stderrClosed)) {
        if (-not $stdoutClosed -and $stdoutTask.IsCompleted) {
            $stdoutCount = $stdoutTask.Result
            if ($stdoutCount -gt 0) {
                & $appendLogText ([string]::new($stdoutBuffer, 0, $stdoutCount))
                $stdoutTask = $process.StandardOutput.ReadAsync($stdoutBuffer, 0, $bufferSize)
            } else {
                $stdoutClosed = $true
            }
        }
        if (-not $stderrClosed -and $stderrTask.IsCompleted) {
            $stderrCount = $stderrTask.Result
            if ($stderrCount -gt 0) {
                & $appendLogText ([string]::new($stderrBuffer, 0, $stderrCount))
                $stderrTask = $process.StandardError.ReadAsync($stderrBuffer, 0, $bufferSize)
            } else {
                $stderrClosed = $true
            }
        }
        if (-not ($stdoutClosed -and $stderrClosed)) { Start-Sleep -Milliseconds 25 }
    }
    $exitCode = $process.ExitCode
    $status = if ($exitCode -eq 0) { 'done' } else { 'failed' }

    # --- The completion report is the verdict; the exit code is not -------------------------------
    # Codex exits 0 even when its own report says `blocked`. A dispatcher that reads the exit code
    # reads "success" -- so the host commits code the coder never inspected, formatted, linted, or
    # tested, and then builds the next spec on top of it. That is exactly what happened to
    # cap-deps-1b (2026-07-14): exit 0, `.final` said `"status": "blocked"`, and the blocker was
    # "the sandbox can no longer launch helpers, so implementation cannot be inspected, corrected,
    # or verified". Nobody read it. Read `.final` (what -o captures) -- never the log, never the
    # exit code alone.
    $reportStatus = $null
    $unresolved = @()
    $deviations = @()
    $blocker = $null
    $reviewVerdict = $null
    if (Test-Path -LiteralPath $finalPath -PathType Leaf) {
        try {
            $report = Get-Content -LiteralPath $finalPath -Raw | ConvertFrom-Json
            $reportedCompletionStatus = [string]$report.status
            if ($Schema -ceq 'completion') {
                # The completion schema has exactly three status tokens. PowerShell's normal
                # membership operators are case-insensitive, so use -ccontains deliberately: DONE
                # is not the schema token `done`, and an empty or invented status is not success.
                if (@('done', 'done_with_concerns', 'blocked') -ccontains $reportedCompletionStatus) {
                    $reportStatus = $reportedCompletionStatus
                }
                else {
                    $reportStatus = 'blocked'
                    $blocker = "Invalid completion status '$reportedCompletionStatus'. Failing closed."
                }
            }
            else {
                # A stray status on a review is not gate evidence. Only its verdict may close it.
                $reportStatus = $null
            }

            # A REVIEW report has no `status` -- it has `verdict` (BLOCK / FLAG / CLEAN), and its
            # findings live in `findings`. Reading only `status` left it empty, so $status stayed
            # 'done' and the dispatcher EXITED 0 ON A BLOCKING REVIEW.
            #
            # This is not hypothetical: the two cross-family reviews of this very harness both
            # returned BLOCK and both exited 0. The only reason the findings were acted on is that
            # the host read the report by hand. A mechanism built to stop people trusting exit codes
            # was itself trusting an exit code. (Found by the second of those reviews.)
            if ($Schema -cne 'completion' -and ($report.PSObject.Properties.Name -contains 'verdict')) {
                $reviewVerdict = [string]$report.verdict
                # Count only findings that ACTUALLY flag something. codex-review.md tells a clean
                # reviewer to return a single CLEAN finding -- counting that as a concern made exit 0
                # unreachable for a reviewer following its own instructions, which trains everyone to
                # ignore 68.
                $findingCount = 0
                if ($report.findings) {
                    $findingCount = @($report.findings | Where-Object {
                        $sev = ([string]$_.severity).ToUpperInvariant()
                        $sev -and $sev -ne 'CLEAN' -and $sev -ne 'NONE' -and $sev -ne 'INFO'
                    }).Count
                }
                $v = $reviewVerdict.ToUpperInvariant()

                # FAIL CLOSED on anything not recognisably clean.
                #
                # The first version had `default { $reportStatus = 'done' }` -- so an unrecognised
                # verdict, a lowercase one, a missing one, or an end-gate returning
                # `"verdict": "P1: block handoff"` all came back as SUCCESS. A gate whose unknown
                # states mean "pass" is not a gate. And any findings at all mean there is something
                # to read, whatever the verdict string says.
                # A BLOCK-severity FINDING outranks a cheerful verdict string. Adoption already did
                # this; the main path only counted findings without looking at their severity -- so a
                # report saying `verdict: CLEAN` while carrying a BLOCK finding exited 68 instead of
                # 67. Two copies of one rule, and the weaker copy fails open. Again.
                $hasBlockingFinding = $false
                if ($report.findings) {
                    $hasBlockingFinding = @($report.findings | Where-Object {
                        ([string]$_.severity).ToUpperInvariant() -like '*BLOCK*'
                    }).Count -gt 0
                }

                if ($v -like '*BLOCK*' -or $hasBlockingFinding) {
                    $reportStatus = 'blocked'
                    $blocker = "Review verdict '$reviewVerdict' -- $findingCount finding(s), at least one BLOCK. Read them; do not commit."
                } elseif ($v -like '*FLAG*' -or $v -like 'P1*' -or $v -like 'P2*') {
                    $reportStatus = 'done_with_concerns'
                    $unresolved += "Review verdict '$reviewVerdict' -- $findingCount finding(s) to adjudicate."
                } elseif ($v -eq 'CLEAN' -or $v -eq 'PASS' -or $v -eq 'OK') {
                    if ($findingCount -gt 0) {
                        $reportStatus = 'done_with_concerns'
                        $unresolved += "Verdict says '$reviewVerdict' but $findingCount finding(s) were returned. Read them."
                    } elseif (-not $reportStatus) { $reportStatus = 'done' }
                } else {
                    $reportStatus = 'blocked'
                    $blocker = "Unrecognised review verdict '$reviewVerdict' ($findingCount finding(s)). Failing closed: an unknown gate state is not a pass."
                }
            }
            elseif ($Schema -cne 'completion') {
                # A review/end-gate report with NO verdict says nothing at all. A stray status field
                # cannot substitute for the verdict that the family gate is meant to consume.
                $reportStatus = 'blocked'
                $blocker = 'The review report carried no verdict. A gate that said nothing did not pass.'
            }

            if ($Schema -ceq 'completion') {
                $unresolved = @($report.unresolved | Where-Object {
                        -not [string]::IsNullOrWhiteSpace([string]$_)
                    })
            }
            if ($report.deviations) { $deviations = @($report.deviations) }
            if ($report.blocker) { $blocker = [string]$report.blocker }

            # The schema does not COUPLE `status` to `blocker`/`unresolved`, so a careless coder can
            # return `status: done` while also naming a blocker ("tests could not run") and listing
            # unresolved work. The wrapper printed those and exited 0 -- which is exactly the
            # cap-deps-1b failure wearing a different field. The status is the coder's CLAIM; the
            # blocker and the unresolved list are its EVIDENCE. Believe the evidence.
            if ($blocker -and $reportStatus -eq 'done') {
                $reportStatus = 'blocked'
            }
            elseif ($unresolved.Count -gt 0 -and $reportStatus -eq 'done') {
                $reportStatus = 'done_with_concerns'
            }
        } catch {
            $reportStatus = 'blocked'
            $blocker = "Unparseable completion report: $($_.Exception.Message)"
        }
    } elseif ($exitCode -eq 0) {
        # Exit 0 with no report is not a success. It is a dispatch that produced no verdict, and a
        # missing verdict must never read as a passing one.
        $reportStatus = 'blocked'
        $blocker = 'Codex exited 0 without writing a completion report.'
    }

    # Only completion reports own `unresolved`; review concerns are synthesized from verdict evidence.
    if ($Schema -ceq 'completion' -and
            $reportStatus -eq 'done_with_concerns' -and $unresolved.Count -eq 0) {
        $reportStatus = 'blocked'
        $blocker = $emptyConcernBlockerText
    }

    if ($reportStatus -eq 'blocked') { $status = 'blocked' }
    elseif ($reportStatus -eq 'done_with_concerns' -and $status -eq 'done') { $status = 'done_with_concerns' }

    # --- Host-side scope enforcement (check) ------------------------------------------------------
    # Runs on EVERY exit path, including a failed task -- a task that failed may still have written
    # files it was never authorized to touch, and those are exactly the ones nobody goes looking for.
    # The scope result is its OWN axis. It must never overwrite the coder's verdict.
    #
    # The first version assigned $status = 'scope-violation' on ANY non-zero scope exit -- which
    # silently destroyed the `blocked` hard stop, the headline fix of this whole change set: a coder
    # reporting `blocked` plus any scope result exited 65 instead of 67, so the host read
    # "scope violation, reverted" and committed code the coder never verified. It also announced
    # "out-of-scope paths were reverted" for exit 70 and 72, where NOTHING was reverted.
    #
    # Two independent facts (did the coder finish? did it stay in scope?) need two variables.
    $scopeViolation = $false
    $scopeExit = 0
    $criticalViolation = $false
    $criticalHardBlock = $false
    $criticalPaths = @()
    $scopeCheckThrew = $false
    $writtenPathsFile = Join-Path $harnessStateDir "written-$runId.txt"
    $scopeCheckErrorNote = $null
    if ($scopeCheckArmed) {
        try {
            & $scopeCheckScript -Check -Worktree $Worktree -Task $gateKey -Authorized $Authorized `
                -ExcludeRunId $runId -StateDirectory $harnessStateDir `
                -WrittenPathsFile $writtenPathsFile | Write-Host
            $scopeExit = $LASTEXITCODE
            if ($scopeExit -ne 0) { $scopeViolation = $true }

            # The scope check DETECTS; it never reverts (it destroyed real work twice when it did, by
            # inferring authorship from timing while other writers were live). So nothing here may claim
            # anything was cleaned up: the out-of-scope changes are still in the tree, for a human.
            switch ($scopeExit) {
                0 { }
                66 {
                    Write-Host "[dispatch] The -Authorized list looks wrong, not the coder. See above." -ForegroundColor Red
                }
                default {
                    Write-Host "[dispatch] Task '$Task' wrote OUTSIDE its authorized set. Nothing was reverted - the changes" -ForegroundColor Red
                    Write-Host "[dispatch] are still in the tree. Usually a SPEC DEFECT: the task needed a file its spec did" -ForegroundColor Red
                    Write-Host "[dispatch] not list. Surface it to planning; do not just re-run." -ForegroundColor Red
                }
            }
        }
        catch {
            # Lockstep sibling: the adopt live-replay catch fails closed via exit 65; here that intent
            # applies only to the build + workspace-write post-hoc path (exit 77 unless outranked).
            $scopeCheckThrew = $true
            $scopeCheckErrorNote = "scope_check_error: $($_.Exception.Message)"
            Write-Host "[dispatch] $scopeCheckErrorNote" -ForegroundColor Yellow
        }
    }

    # --- Encoding gate: the one defect a green test suite GUARANTEES you will not see ---------------
    # Codex-on-Windows double-encodes non-ASCII into source (em-dash -> a-circumflex/euro/quote). The
    # suite cannot catch it: the coder writes the same corrupted bytes into the EXPECTED string, so
    # the assertion compares corrupt to corrupt and passes. It bit twice on 2026-07-10, green both
    # times. This is its own axis, like scope -- it says nothing about whether the coder finished.
    #
    # Runs on every WRITE dispatch, not just scope-armed ones: corruption does not care what was
    # authorized, and a failed task can still have written mojibake before it died.
    #
    # But NOT on a read-only dispatch (a review or end-gate). The reviewer's sandbox forbids writes, so
    # there is no coder output to scan -- and a review passes no -Authorized, so the scan falls back to
    # the WHOLE dirty tree and flags the owner's pre-existing mojibake (e.g. transcript `.err` files the
    # harness itself wrote), failing a valid review on bytes the reviewer never touched. Skipping here
    # is not an exemption: read-only means there is nothing of the coder's to check.
    # FAIL CLOSED if the helper is gone. The first cut wrapped this in `if (Test-Path ...)`, so a
    # missing script meant the gate silently did not run and the dispatch exited 0 -- the guarantee
    # quietly downgraded to "scanned when convenient". The scope check already throws here; this matches.
    if (-not (Test-Path $scopeCheckScript)) {
        throw "codex-scope-check.ps1 is missing ($scopeCheckScript). Refusing to finish a dispatch without the encoding gate: a gate that silently does not run reads as a pass."
    }
    $encodingViolation = $false
    if ($Sandbox -eq 'read-only') {
        Write-Host "[encoding] read-only dispatch (review/end-gate): no coder writes to scan -- skipping." -ForegroundColor DarkGray
    }
    else {
        & $scopeCheckScript -EncodingScan -Worktree $Worktree -Task $gateKey -Authorized $Authorized | Write-Host
        if ($LASTEXITCODE -eq 73) { $encodingViolation = $true }
    }

    # Did the tree move while this read-only gate was open? If so the verdict is about a tree that no
    # longer exists, and a CLEAN verdict would be a rubber stamp on unreviewed code.
    $treeMoved = $false
    if ($treePinArmed) {
        & $treePinScript -Verify -Worktree $Worktree -Label $treePinLabel -PinDirectory $harnessStateDir | Write-Host
        if ($LASTEXITCODE -ne 0) { $treeMoved = $true }
    }

    $gates = @{
        EndTreeDigest = ''
        CriticalViolation = $null
        HardBlock = $false
        CriticalPaths = @()
        Notes = @()
    }
    if ($Phase -eq 'build' -and $Sandbox -eq 'workspace-write') {
        if ($scopeCheckArmed) {
            $gates = Invoke-PostHocGates -Worktree $Worktree -DigestScript $digestScript `
                -ClassifyWritten -WrittenPathsFile $writtenPathsFile `
                -CriticalScript $(if ($CriticalFilesScript) { $CriticalFilesScript } else { Join-Path $PSScriptRoot 'apex-critical-files.ps1' }) `
                -Confirmed $CriticalFilesConfirmed -BaselineHeadSha $headSha
            $criticalViolation = ($gates.CriticalViolation -eq $true) -or $scopeCheckThrew
            $criticalPaths = $gates.CriticalPaths
            $criticalHardBlock = $gates.HardBlock
        }
        else {
            $gates = Invoke-PostHocGates -Worktree $Worktree -DigestScript $digestScript
            $criticalViolation = $null
            if ($ScopeUnlocked) {
                Write-Host '[dispatch] scope-unlocked: written set unavailable; pre-flight -CriticalFilesConfirmed was already required' -ForegroundColor Yellow
            }
        }
    }
    else {
        $criticalViolation = $null
    }

    $terminalChanges = @{
        status = $status; ended = (Get-UtcTimestamp)
        scopeViolation = $scopeViolation; scope_exit = $scopeExit; tree_moved = $treeMoved
        encoding_violation = $encodingViolation
        end_tree_digest = $gates.EndTreeDigest
        report_status = $reportStatus; unresolved = $unresolved; deviations = $deviations; blocker = $blocker
    }
    if ($null -ne $criticalViolation) {
        $terminalChanges['critical_violation'] = $criticalViolation
    }
    Update-LedgerRow -RunId $runId -RowKind 'dispatch' -Changes $terminalChanges

    # The coder's own account of what it could not finish is the single highest-value input to the
    # review that follows -- and it is exactly what got dropped on cap-deps-1b, leaving the reviewer
    # to re-derive the coder's doubts from scratch. Print it where the host cannot miss it, and
    # leave it on disk next to the report so the review dispatch can paste it in verbatim.
    if ($unresolved.Count -gt 0 -or $deviations.Count -gt 0 -or $blocker) {
        $concernsPath = "$finalPath.concerns.md"
        $concernsLines = @("# Coder-reported concerns -- $Spec / $Task", '', "Reported status: **$reportStatus**", '')
        if ($blocker) { $concernsLines += @('## Blocker', '', $blocker, '') }
        if ($unresolved.Count -gt 0) { $concernsLines += @('## Unresolved', '') + ($unresolved | ForEach-Object { "- $_" }) + @('') }
        if ($deviations.Count -gt 0) { $concernsLines += @('## Deviations', '') + ($deviations | ForEach-Object { "- $_" }) + @('') }
        Write-Utf8NoBomLines -Path $concernsPath -Lines ([string[]]$concernsLines)

        Write-Host ''
        Write-Host "[dispatch] The coder reported '$reportStatus'. Its own words -- carry these into the review:" -ForegroundColor Yellow
        if ($blocker) { Write-Host "[dispatch]   BLOCKER: $blocker" -ForegroundColor Red }
        foreach ($item in $unresolved) { Write-Host "[dispatch]   UNRESOLVED: $item" -ForegroundColor Yellow }
        foreach ($item in $deviations) { Write-Host "[dispatch]   DEVIATION:  $item" -ForegroundColor Yellow }
        Write-Host "[dispatch]   -> $concernsPath" -ForegroundColor Yellow
        Write-Host ''
    }

    Write-Host "[dispatch] report: $finalPath" -ForegroundColor DarkGray

    # `blocked` outranks EVERYTHING, including a moved tree. The contract says so, and the previous
    # ordering contradicted it: a blocked report plus any tree movement exited 69 and never reached
    # the 67 branch, so the hard stop was lost to the void. A void verdict still means "do not act";
    # a blocked coder means "do not commit" -- and the second is the one that ships bad code.
    if ($status -eq 'blocked') {
        Write-Host "[dispatch] BLOCKED: the coder did not complete this task. Do NOT commit and do NOT build on top of it." -ForegroundColor Red
        Write-Host "[dispatch] Clear every unresolved item with a host re-verify first." -ForegroundColor Red
        if ($treeMoved) { Write-Host "[dispatch] (The tree ALSO moved under this gate. Both are true; blocked is the worse one.)" -ForegroundColor Red }
        if ($scopeViolation) { Write-Host "[dispatch] (Also flagged out-of-scope writes: scope-check exit $scopeExit. Nothing was reverted.)" -ForegroundColor Red }
        exit 67
    }

    if ($treeMoved) {
        Write-Host "[dispatch] THE TREE MOVED while this gate was open. The verdict is VOID -- do not act on it." -ForegroundColor Red
        Write-Host "[dispatch] Find the writer (a live coder, a concurrent agent, a hand-edit), let it finish, re-run the gate." -ForegroundColor Red
        exit 69
    }

    # EXIT PRECEDENCE, most severe first. Each of these is an independent fact, and the exit code can
    # only carry one -- so the most dangerous one to ignore wins, and the rest are printed above and
    # recorded in the ledger. `blocked` outranks everything: a coder saying "I could not verify, or
    # even re-read, what I wrote" is worse news than where it wrote it.
    # The -Authorized list being wrong is a DIFFERENT failure from the coder wandering out of scope,
    # and the host must route it differently (fix the spec, not the coder). Collapsing it into 65 made
    # the documented 66 unreachable.
    if ($scopeExit -eq 66) { exit 66 }

    # A scope violation is a real failure WHATEVER the child's exit code was. Gating this on
    # `$exitCode -eq 0` meant a child that wrote out of scope AND exited 2 passed exit 2 straight
    # through -- outside the documented exit space entirely, and with the scope route hidden. A child
    # failure does not excuse an out-of-scope write; it is usually how you get one.
    if ($scopeViolation) { exit 65 }

    if ($criticalViolation -eq $true) {
        Write-Host '[dispatch] CRITICAL FILE VIOLATION in the post-hoc written set. Do NOT commit.' -ForegroundColor Red
        if ($criticalHardBlock) {
            $criticalPathText = if ($criticalPaths.Count -gt 0) { $criticalPaths -join ', ' } else { '(classifier named no paths)' }
            Write-Host "[dispatch] HARD-BLOCK critical path(s): $criticalPathText" -ForegroundColor Red
        }
        exit 77
    }

    # Corrupted bytes in the tree. Ranked BELOW a scope violation deliberately: a scope violation is a
    # SPEC defect and re-routes the whole task through planning -- and when that task is re-dispatched,
    # this scan runs again and re-catches the mojibake. Encoding is a mechanical byte fix; scope is
    # structural. Both are printed above and both are in the ledger, whichever one the exit code carries.
    if ($encodingViolation) {
        Write-Host "[dispatch] DOUBLE-ENCODED TEXT in the tree. Do NOT commit: the suite is green and WRONG." -ForegroundColor Red
        exit 73
    }

    # `done_with_concerns` is not `done`. It exits distinctly so the host must decide, not skim.
    if ($status -eq 'done_with_concerns') { exit 68 }

    # A CHILD's exit code must never be passed through into the wrapper's RESERVED space. Codex
    # exiting 67 (for its own reasons) is not "the coder reported blocked"; a caller reading the
    # contract would act on a verdict that was never given. Remap anything that collides.
    # The wrapper's exit space is a CONTRACT:
    # 0/1/65/66/67/68/69/71/75/77/78/79/80/81/82/83/124. Passing an arbitrary child
    # code straight through breaks it -- a child exiting 2 told the caller nothing the contract can
    # express, and a child exiting 67 claimed a `blocked` verdict it never gave.
    if ($exitCode -ne 0) {
        Write-Host "[dispatch] child failed (exit $exitCode); reporting 1 (child failure)." -ForegroundColor Yellow
        exit 1
    }
    exit 0
} catch {
    # A launch/setup failure has no child exit code, but it is still durable.
    Update-LedgerRow -RunId $runId -RowKind 'dispatch' -Changes @{ status = 'failed'; ended = (Get-UtcTimestamp); error = $_.Exception.Message }
    throw
} finally {
    # Guarded: we close the child's stdin via BaseStream (see the prompt-write note), so Dispose here
    # re-disposes the StandardInput StreamWriter over an already-closed stream, which would otherwise
    # throw out of this finally and mask the exit code.
    try { $process.Dispose() } catch {}
}
} finally {
    # Single refusal backstop: append a close event if and only if this run still has an OPEN lease
    # (a row_kind:lease row with no row_kind:lease_close partner). Pre-lease refusals therefore append
    # nothing, and a transitioned dispatch cannot be closed as a refusal.
    if ($script:leaseRegistered) {
        try {
            $openLeaseRunIds = @(Get-OpenLeaseRunIds)
            if ($openLeaseRunIds -ccontains $runId) {
                Add-LeaseCloseRow -RunId $runId -Status 'refused-preflight' -RefusalExit $script:pendingExitCode
            }
        }
        catch {
            Write-Host "[dispatch] refusal lease-close backstop failed: $($_.Exception.Message)" -ForegroundColor Red
        }
        finally {
            $script:leaseRegistered = $false
        }
    }
    if ($treePinArmed -and -not [string]::IsNullOrWhiteSpace($reviewTreePinPath)) {
        Remove-Item -LiteralPath $reviewTreePinPath -Force -ErrorAction SilentlyContinue
        $treePinArmed = $false
    }
    if ($preflightPinArmed) {
        $safe = ($preflightPinLabel -replace '[<>:"/\\|?*]', '_')
        $preflightPinGlob = Join-Path $harnessStateDir "apex-treepin-$safe-*.txt"
        Remove-Item -Path $preflightPinGlob -Force -ErrorAction SilentlyContinue
        $preflightPinArmed = $false
    }
    $creatorTeardownTerminal = $false
    try {
        if ($OwnedWorktree) {
            $creatorTeardownTerminal = Test-CreatorRunTerminal -RunId $runId
        }
    }
    catch {
        Write-Host "[dispatch] creator teardown terminal-state check failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        $ledgerMutex.Dispose()
    }

    if ($OwnedWorktree -and $creatorTeardownTerminal) {
        try {
            Invoke-CreatorTeardown -Worktree $Worktree -RunId $runId
        }
        catch {
            $teardownException = $_.Exception.Message
            Write-Host "[dispatch] creator teardown failed: $teardownException" -ForegroundColor Red

            $catchRecord = $script:creatorTeardownRecord
            if ($null -eq $catchRecord) {
                $catchRecord = @{
                    teardown_main_repo = ''
                    teardown_sha = ''
                    teardown_branch = ''
                    teardown_worktree = $Worktree
                    cleanup_obligation = ''
                    branch_teardown_obligation = ''
                }
            }
            $catchRecord.cleanup_obligation =
                "worktree $($catchRecord.teardown_worktree) retained: teardown failure: $teardownException"
            $catchRecord.branch_teardown_obligation = ''

            if (-not [string]::IsNullOrWhiteSpace([string]$catchRecord.teardown_main_repo)) {
                Write-Host (Get-CreatorTeardownCommand `
                    -MainRepo ([string]$catchRecord.teardown_main_repo) `
                    -Worktree ([string]$catchRecord.teardown_worktree)) -ForegroundColor Yellow
            }

            # Recording the catch path also needs a post-disposal handle. Failures here are reported
            # but cannot replace the wrapper's already-selected exit code.
            $catchMutex = [System.Threading.Mutex]::new($false, 'ApexCodexRunLedger')
            try {
                Invoke-WithLedgerLock -Mutex $catchMutex -Action {
                    $catchLedgerLines = if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
                        [System.IO.File]::ReadAllLines($ledgerPath)
                    }
                    else {
                        [string[]]@()
                    }
                    Save-CreatorTeardownRecord -RunId $runId -Record $catchRecord `
                        -LedgerLines $catchLedgerLines -Mutex $catchMutex
                }
            }
            catch {
                Write-Host "[dispatch] creator teardown obligation recording failed: $($_.Exception.Message)" -ForegroundColor Red
            }
            finally {
                $catchMutex.Dispose()
            }
        }
    }
}
