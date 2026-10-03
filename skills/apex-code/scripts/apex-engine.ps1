[CmdletBinding()]
param(
    [string]$SpecPath,
    [string]$Repo,
    [ValidateRange(1, 16)][int]$MaxParallel,
    [switch]$Attended,
    [string]$CriticalFilesConfirmedNote,
    [string]$WorktreeRoot,
    [string]$Resume,
    [string]$Teardown,
    [switch]$Discard,
    [string]$WrapperPath,
    [string]$StateRoot,
    [string]$CodexExecutable,
    [string[]]$CodexExecutableArgumentPrefix
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$script:EngineScriptRoot = $PSScriptRoot
$script:EngineState = $null
$script:EngineStatePath = $null
$script:EngineStateRoot = $null
$script:EngineWrapper = $null
$script:EngineWorktreeRoot = $null
$script:EngineLedgerPath = $null
$script:EngineAttended = [bool]$Attended
$script:EngineConfirmation = $CriticalFilesConfirmedNote
$script:EngineCodexExecutable = $CodexExecutable
$script:EngineCodexPrefix = [string[]]@($CodexExecutableArgumentPrefix)
$script:EngineMaxParallelBound = $PSBoundParameters.ContainsKey('MaxParallel')
$script:EngineWorktreeRootBound = $PSBoundParameters.ContainsKey('WorktreeRoot')
$script:EngineWrapperBound = $PSBoundParameters.ContainsKey('WrapperPath')
$script:EngineCodexBound = $PSBoundParameters.ContainsKey('CodexExecutable')
$script:EngineCodexPrefixBound = $PSBoundParameters.ContainsKey('CodexExecutableArgumentPrefix')
$script:EngineLockStream = $null
$script:EngineLockPath = $null
$script:EngineRetryDelaySeconds = 60
if ($env:APEX_ENGINE_TEST_RETRY_DELAY_SECONDS -match '^\d+$') {
    $script:EngineRetryDelaySeconds = [int]$env:APEX_ENGINE_TEST_RETRY_DELAY_SECONDS
}

. (Join-Path $PSScriptRoot 'engine-plan.ps1')
. (Join-Path $PSScriptRoot 'engine-git.ps1')
. (Join-Path $PSScriptRoot 'engine-dispatch.ps1')

$script:EngineTreePinScript = Join-Path $script:EngineScriptRoot 'tree-pin.ps1'
$script:EngineBaselineScript = Join-Path $script:EngineScriptRoot 'apex-baseline-check.ps1'
$script:EngineCriticalScript = Join-Path $script:EngineScriptRoot 'apex-critical-files.ps1'
# Hermetic tests may replace gate executables, but only after explicitly enabling test mode.
if ($env:APEX_ENGINE_TEST_MODE -ceq '1') {
    if ($env:APEX_ENGINE_TEST_TREE_PIN_PATH) { $script:EngineTreePinScript = [IO.Path]::GetFullPath($env:APEX_ENGINE_TEST_TREE_PIN_PATH) }
    if ($env:APEX_ENGINE_TEST_BASELINE_PATH) { $script:EngineBaselineScript = [IO.Path]::GetFullPath($env:APEX_ENGINE_TEST_BASELINE_PATH) }
    if ($env:APEX_ENGINE_TEST_CRITICAL_PATH) { $script:EngineCriticalScript = [IO.Path]::GetFullPath($env:APEX_ENGINE_TEST_CRITICAL_PATH) }
}

function Get-RunnerUtc { [DateTime]::UtcNow.ToString('o') }

function Get-RunnerProcessStamp {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $null }
    try { return $process.StartTime.ToUniversalTime().ToString('o') } catch { return 'unknown' }
}

function Open-RunnerRunLock {
    param([Parameter(Mandatory)][string]$RunDirectory)
    [void][IO.Directory]::CreateDirectory($RunDirectory)
    $script:EngineLockPath = Join-Path $RunDirectory 'engine.lock'
    try {
        $script:EngineLockStream = [IO.File]::Open($script:EngineLockPath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        $ownerText = 'unknown owner'
        $candidateState = Join-Path $RunDirectory 'engine-state.json'
        if (Test-Path -LiteralPath $candidateState -PathType Leaf) {
            try {
                $candidate = Get-Content -LiteralPath $candidateState -Raw | ConvertFrom-Json
                if ($candidate.PSObject.Properties['engine_owner']) {
                    $owner = $candidate.engine_owner
                    $ownerText = "pid $($owner.pid), start $($owner.start_time)"
                    if (Test-EngineProcessIs ([int]$owner.pid) ([string]$owner.start_time) -Strict) {
                        throw "Refusing run access: another live Engine owns this run ($ownerText)."
                    }
                }
            } catch {
                if ($_.Exception.Message -like 'Refusing run access:*') { throw }
            }
        }
        throw "Refusing run access: the exclusive Engine lock is held ($ownerText)."
    }
    $ownerDocument = [ordered]@{ pid = $PID; start_time = (Get-RunnerProcessStamp $PID); acquired_at = (Get-RunnerUtc) }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($ownerDocument | ConvertTo-Json -Compress))
    $script:EngineLockStream.SetLength(0)
    $script:EngineLockStream.Write($bytes, 0, $bytes.Length)
    $script:EngineLockStream.Flush($true)
    return [pscustomobject]$ownerDocument
}

function Close-RunnerRunLock {
    if ($null -ne $script:EngineLockStream) {
        try { $script:EngineLockStream.Dispose() } finally { $script:EngineLockStream = $null }
    }
}

function Get-RunnerPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@([char]92, [char]47))
    if (Test-Path -LiteralPath $full) { return (Get-Item -Force -LiteralPath $full).FullName.TrimEnd([char[]]@([char]92, [char]47)) }
    $probe = $full
    $suffix = New-Object 'Collections.Generic.List[string]'
    while ($probe -and -not (Test-Path -LiteralPath $probe)) {
        $leaf = Split-Path -Leaf $probe
        if ($leaf) { $suffix.Insert(0, $leaf) }
        $next = Split-Path -Parent $probe
        if (-not $next -or $next -eq $probe) { break }
        $probe = $next
    }
    if ($probe -and (Test-Path -LiteralPath $probe)) {
        $resolved = (Get-Item -Force -LiteralPath $probe).FullName
        foreach ($part in $suffix) { $resolved = Join-Path $resolved $part }
        return $resolved.TrimEnd([char[]]@([char]92, [char]47))
    }
    return $full
}

function Test-RunnerOutsideWorktree {
    param([Parameter(Mandatory)][string]$Path)
    $probe = Get-RunnerPath $Path
    while ($probe -and -not (Test-Path -LiteralPath $probe -PathType Container)) {
        $next = Split-Path -Parent $probe
        if (-not $next -or $next -eq $probe) { break }
        $probe = $next
    }
    if (-not $probe) { return $true }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $inside = @(& git -C $probe rev-parse --is-inside-work-tree 2>$null)
        return -not ($LASTEXITCODE -eq 0 -and (($inside -join '').Trim() -ceq 'true'))
    } catch { return $true } finally { $ErrorActionPreference = $old }
}

function Invoke-RunnerGitText {
    param([string]$Root, [Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $lines = @(& git -C $Root @Arguments 2>&1); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { throw "git failed ($code): $($lines -join ' | ')" }
    return (($lines | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Invoke-RunnerScript {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Arguments)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    [pscustomobject]@{ exit_code = [int]$code; output = (($output | ForEach-Object { [string]$_ }) -join "`n") }
}

function Add-RunnerTransition {
    param([string]$Kind, [AllowNull()][string]$Detail)
    $script:EngineState.transitions = @($script:EngineState.transitions) + [pscustomobject][ordered]@{
        at = Get-RunnerUtc; kind = $Kind; detail = $Detail
    }
}

function Save-RunnerState {
    if ($null -eq $script:EngineState -or -not $script:EngineStatePath) { return }
    $script:EngineState.updated_at = Get-RunnerUtc
    $directory = Split-Path -Parent $script:EngineStatePath
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory ('.engine-state-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $directory ('.engine-state-' + [Guid]::NewGuid().ToString('N') + '.bak')
    $json = $script:EngineState | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $script:EngineStatePath -PathType Leaf) {
        try { [IO.File]::Replace($temporary, $script:EngineStatePath, $backup, $true) }
        finally { if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force } }
    } else { [IO.File]::Move($temporary, $script:EngineStatePath) }
}

function Set-RunnerParked {
    param([string]$Diagnosis, [AllowNull()][object]$TaskState)
    if ($null -ne $TaskState) { $TaskState.status = 'parked'; $TaskState.diagnosis = $Diagnosis }
    $script:EngineState.status = 'parked'; $script:EngineState.diagnosis = $Diagnosis
    Add-RunnerTransition 'parked' $Diagnosis
    Save-RunnerState
}

function Set-RunnerRefused {
    param([string]$Diagnosis, [AllowNull()][object]$TaskState)
    if ($null -ne $TaskState) { $TaskState.status = 'parked'; $TaskState.diagnosis = $Diagnosis }
    $script:EngineState.status = 'refused'; $script:EngineState.diagnosis = $Diagnosis
    Add-RunnerTransition 'refused' $Diagnosis
    Save-RunnerState
}

function Test-RunnerCriticalGate {
    param([object]$TaskPlan, [object]$TaskState)
    $critical = Invoke-RunnerScript $script:EngineCriticalScript `
        ([string[]](@('-Test', '-Paths') + @($TaskPlan.files | ForEach-Object { [string]$_.path }) + @('-Root', [string]$script:EngineState.repo)))
    $criticalDiagnosis = "critical-file gate exit $($critical.exit_code)"
    if (-not [string]::IsNullOrWhiteSpace([string]$critical.output)) { $criticalDiagnosis += ": $($critical.output.Trim())" }
    if ($critical.exit_code -eq 11) { Set-RunnerRefused $criticalDiagnosis $TaskState; return $false }
    if ($critical.exit_code -eq 10 -and (-not $script:EngineAttended -or [string]::IsNullOrWhiteSpace($script:EngineConfirmation))) {
        Set-RunnerParked $criticalDiagnosis $TaskState; return $false
    }
    if ($critical.exit_code -notin @(0, 10)) { Set-RunnerParked $criticalDiagnosis $TaskState; return $false }
    return $true
}

function Get-RunnerTaskPlan {
    param([string]$Id)
    foreach ($wave in @($script:EngineState.plan.waves)) {
        foreach ($task in @($wave.tasks)) { if ([string]$task.id -ceq $Id) { return $task } }
    }
    throw "Task is absent from immutable plan: $Id"
}

function Get-RunnerTaskState {
    param([string]$Id)
    foreach ($task in @($script:EngineState.tasks)) { if ([string]$task.id -ceq $Id) { return $task } }
    throw "Task state is absent: $Id"
}

function Get-RunnerAllFiles {
    $files = @()
    foreach ($wave in @($script:EngineState.plan.waves)) {
        foreach ($task in @($wave.tasks)) { $files += @($task.files) }
    }
    return [object[]]$files
}

function Get-RunnerDigest {
    param([string]$Path)
    $strict = New-Object Text.UTF8Encoding($false, $true)
    Get-EngineSha256 -Text ([IO.File]::ReadAllText($Path, $strict))
}

function Test-RunnerPidLive {
    param([AllowNull()][object]$PidValue, [AllowNull()][object]$StartTime)
    $parsedPid = 0
    if ($null -eq $PidValue -or -not [int]::TryParse([string]$PidValue, [ref]$parsedPid) -or $parsedPid -le 0) { return $false }
    return (Test-EngineProcessIs $parsedPid ([string]$StartTime) -Strict)
}

function Get-RunnerRowStatusTerminal {
    param([AllowNull()][object]$Row)
    if ($null -eq $Row -or -not $Row.PSObject.Properties['status']) { return $false }
    $status = [string]$Row.status
    return ($status -match '^(done|success|done_with_concerns|failed|blocked|abandoned|void|adopted-)')
}

function New-RunnerAttempt {
    param([object]$TaskPlan, [object]$TaskState, [string]$Effort)
    if (-not (Test-RunnerCriticalGate $TaskPlan $TaskState)) { return $null }

    $number = @($TaskState.attempts).Count + 1
    $identity = [pscustomobject]@{ name = [string]$script:EngineState.spec.name; run_id = [string]$script:EngineState.run_id }
    try {
        $created = New-EngineTaskWorktree -Repo $script:EngineState.repo -Spec $identity -TaskId $TaskPlan.id `
            -Attempt $number -IntegrationWorktree $script:EngineState.integration.worktree -WorktreeRoot $script:EngineWorktreeRoot
    } catch { Set-RunnerParked "task worktree creation failed: $($_.Exception.Message)" $TaskState; return $null }
    $attemptDirectory = Join-Path (Split-Path -Parent $script:EngineStatePath) ("attempt-$($TaskPlan.id)-$number")
    [void][IO.Directory]::CreateDirectory($attemptDirectory)
    $attempt = [pscustomobject][ordered]@{
        number = $number; status = 'prepared'; effort = $Effort; model = [string]$script:EngineState.plan.spec.coder_model
        worktree = $created.worktree; branch = $created.branch; child_pid = $null; child_start_time = $null; wrapper_run_id = $null
        exit_code = $null; event_path = $null; args_path = (Join-Path $attemptDirectory 'dispatch-args.json')
        child_output_path = (Join-Path $attemptDirectory 'child.out'); end_tree_digest = $null; diagnosis = $null
        capacity_retries = 0; process_retries = 0
    }
    $TaskState.attempts = @($TaskState.attempts) + $attempt
    $TaskState.status = 'running'; $TaskState.diagnosis = $null
    Add-RunnerTransition 'attempt-prepared' "$($TaskPlan.id)/$number/$Effort"
    Save-RunnerState
    return $attempt
}

function Start-RunnerAttempt {
    param([object]$TaskPlan, [object]$TaskState, [object]$Attempt)
    if (-not (Test-RunnerCriticalGate $TaskPlan $TaskState)) { return $null }
    $parameters = @{
        Phase = 'build'; Spec = [string]$script:EngineState.spec.name; Task = [string]$TaskPlan.id
        Worktree = [string]$Attempt.worktree; BaseSha = (Invoke-RunnerGitText $Attempt.worktree 'rev-parse' 'HEAD')
        SpecSourcePath = [string]$script:EngineState.spec.snapshot_path
        Authorized = [string[]]@($TaskPlan.files | ForEach-Object { [string]$_.path })
        Effort = [string]$Attempt.effort; Model = [string]$Attempt.model; Prompt = [string]$TaskPlan.prompt
        ScratchDirectory = (Join-Path (Split-Path -Parent $script:EngineStatePath) 'wrapper-scratch')
    }
    if ($script:EngineAttended) { $parameters.Attended = $true }
    if (-not [string]::IsNullOrWhiteSpace($script:EngineConfirmation)) {
        $parameters.CriticalFilesConfirmed = $true
        $parameters.CriticalFilesConfirmedNote = $script:EngineConfirmation
    }
    if (-not [string]::IsNullOrWhiteSpace($script:EngineCodexExecutable)) {
        $parameters.CodexExecutable = $script:EngineCodexExecutable
        if ($script:EngineCodexPrefix.Count -gt 0) { $parameters.CodexExecutableArgumentPrefix = [string[]]$script:EngineCodexPrefix }
    }
    Write-EngineDispatchArgs -ArgsPath $Attempt.args_path -Parameters $parameters | Out-Null
    $Attempt.status = 'running'; $script:EngineState.counters.dispatches++
    Save-RunnerState
    try {
        $child = Start-EngineDispatch -WrapperPath $script:EngineWrapper -ArgsPath $Attempt.args_path `
            -ChildOutputPath $Attempt.child_output_path -StateRoot $script:EngineStateRoot
        $Attempt.child_pid = [int]$child.pid
        $Attempt.child_start_time = Get-RunnerProcessStamp ([int]$child.pid)
        Add-RunnerTransition 'dispatch-started' "$($TaskPlan.id)/$($Attempt.number)/pid=$($Attempt.child_pid)"
        Save-RunnerState
        return $child
    } catch {
        $Attempt.status = 'failed'; $Attempt.diagnosis = "dispatch launch failed: $($_.Exception.Message)"
        Save-RunnerState
        return $null
    }
}

function Update-RunnerAttemptResult {
    param([object]$Attempt, [object]$Result)
    $Attempt.exit_code = [int]$Result.exit_code
    $Attempt.event_path = if ($Result.event_path) { [string]$Result.event_path } else { $null }
    $Attempt.wrapper_run_id = if ($Result.wrapper_run_id) { [string]$Result.wrapper_run_id } else { $Attempt.wrapper_run_id }
    $Attempt.end_tree_digest = if ($Result.end_tree_digest) { [string]$Result.end_tree_digest } else { $null }
    $Attempt.diagnosis = if ($Result.diagnosis) { [string]$Result.diagnosis } else { $null }
    Save-RunnerState
}

function Test-RunnerQuotaResult {
    param([object]$Result, [object]$Attempt)
    # The real wrapper captures the Codex child's stdout/stderr in event.log_path. Its merged log
    # is assembled from independently drained chunks, so a JSONL event may begin mid-line. Match
    # only the exact service-event prefixes (plus the legacy plain stderr diagnostic): never the
    # prompt, event tail, item/agent_message text, or coder final report.
    $logPath = $null
    try { if ($Result.event -and $Result.event.log_path) { $logPath = [string]$Result.event.log_path } } catch { }
    if (-not $logPath -or -not (Test-Path -LiteralPath $logPath -PathType Leaf)) { return $false }
    try { $lines = [IO.File]::ReadAllLines($logPath) } catch { return $false }
    foreach ($line in @($lines)) {
        if ($line.Contains('{"type":"error","message":"You''ve hit your usage limit') -or
                $line.Contains('{"type":"turn.failed","error":{"message":"You''ve hit your usage limit') -or
                $line -cmatch '^(?:ERROR:\s*)?You''ve hit your usage limit(?:[\s\.:].*)?$') {
            return $true
        }
    }
    return $false
}

function Test-RunnerBlockedResult {
    param([object]$Result, [object]$Attempt)
    try {
        return ($Result.event -and
            (([string]$Result.event.report_status -ceq 'blocked') -or
             ($Result.event.final -and [string]$Result.event.final.status -ceq 'blocked')))
    } catch { return $false }
}

function Confirm-RunnerBuildDigest {
    param([object]$Attempt, [object]$TaskState)
    if ([string]$Attempt.end_tree_digest -ceq 'unverifiable' -or [string]::IsNullOrWhiteSpace([string]$Attempt.end_tree_digest)) {
        Set-RunnerParked 'unverifiable build digest' $TaskState; return $false
    }
    $digestResult = Invoke-RunnerScript $script:EngineTreePinScript `
        @('-Digest', '-Worktree', [string]$Attempt.worktree)
    if ($digestResult.exit_code -ne 0 -or $digestResult.output.Trim() -cne [string]$Attempt.end_tree_digest) {
        Set-RunnerParked 'tree moved' $TaskState; return $false
    }
    return $true
}

function Route-RunnerResult {
    param([object]$TaskPlan, [object]$TaskState, [object]$Attempt, [object]$Result, [switch]$Adopted)
    Update-RunnerAttemptResult $Attempt $Result
    if ($Result.diagnosis) { $Attempt.status = 'parked'; Set-RunnerParked ([string]$Result.diagnosis) $TaskState; return 'park' }
    $code = [int]$Result.exit_code
    if ($code -in @(0, 68)) {
        if (-not (Confirm-RunnerBuildDigest $Attempt $TaskState)) { return 'park' }
        $Attempt.status = 'succeeded'
        if ($code -eq 68) {
            $concern = "task $($TaskPlan.id) completed with concerns"
            $TaskState.concerns = @($TaskState.concerns) + $concern
            $script:EngineState.concerns = @($script:EngineState.concerns) + $concern
            $script:EngineState.counters.concerns++
        }
        Save-RunnerState
        return 'success'
    }
    if ($code -eq 79) {
        $detail = ''
        try { $detail = [string]$Result.event.detail } catch { }
        $wrapperOutput = ''
        try { if (Test-Path -LiteralPath $Attempt.child_output_path -PathType Leaf) { $wrapperOutput = [IO.File]::ReadAllText($Attempt.child_output_path) } } catch { }
        $permanentLine = '[dispatch] PERMANENT: invalid capacity contract (do not re-queue).'
        $permanent = ($detail -ceq $permanentLine) -or
            (@($wrapperOutput -split "`r?`n") -ccontains $permanentLine)
        if ($permanent) { $Attempt.status = 'parked'; Set-RunnerParked 'permanent capacity refusal (exit 79)' $TaskState; return 'park' }
        if ([int]$Attempt.capacity_retries -ge 10) { $Attempt.status = 'parked'; Set-RunnerParked 'capacity retry limit exhausted (exit 79)' $TaskState; return 'park' }
        $Attempt.capacity_retries++; $script:EngineState.counters.capacity_retries++; Save-RunnerState
        if ($script:EngineRetryDelaySeconds -gt 0) { Start-Sleep -Seconds $script:EngineRetryDelaySeconds }
        return 'same-attempt'
    }
    if ($code -eq 80 -and -not $Adopted) {
        if (@($TaskState.attempts | Where-Object { [string]$_.diagnosis -ceq 'blocking adoption failed' }).Count -gt 0) {
            $Attempt.status = 'parked'; Set-RunnerParked 'blocking adoption retry exhausted (exit 80)' $TaskState; return 'park'
        }
        $blockingId = $null
        try { $blockingId = [string]$Result.event.run_id } catch { }
        if ($blockingId -notmatch '^[0-9a-f]{32}$') { Set-RunnerParked 'exit 80 did not identify a valid blocking run' $TaskState; return 'park' }
        $adopt = Invoke-EngineAdopt -WrapperPath $script:EngineWrapper -RunId $blockingId -Spec $script:EngineState.spec.name `
            -Task $TaskPlan.id -Worktree $Attempt.worktree -StateRoot $script:EngineStateRoot `
            -ChildOutputPath ($Attempt.child_output_path + '.blocking-adopt')
        $adoptRoute = Route-RunnerResult $TaskPlan $TaskState $Attempt $adopt -Adopted
        if ($adoptRoute -ceq 'success') { return 'success' }
        if ($adoptRoute -ceq 'park') {
            # A blocked/failed adoption gets exactly one fresh dispatch. A malformed adoption stays parked.
            if ($script:EngineState.status -cne 'paused' -and $adopt.exit_code -in @(1, 67, 69)) {
                $Attempt.diagnosis = 'blocking adoption failed'
                $script:EngineState.status = 'running'; $script:EngineState.diagnosis = $null
                $TaskState.status = 'running'; $TaskState.diagnosis = $null; Save-RunnerState
                return 'fresh-same-effort'
            }
            return 'park'
        }
        return 'fresh-same-effort'
    }
    if ($code -eq 1) {
        if (Test-RunnerQuotaResult $Result $Attempt) {
            $Attempt.status = 'parked'; $TaskState.status = 'parked'; $TaskState.diagnosis = 'quota or rate limit'
            $script:EngineState.status = 'paused'; $script:EngineState.diagnosis = 'quota or rate limit'
            Add-RunnerTransition 'paused' 'quota or rate limit'; Save-RunnerState; return 'park'
        }
        if (Test-RunnerBlockedResult $Result $Attempt) { $Attempt.status = 'parked'; Set-RunnerParked 'spec defect: final blocked' $TaskState; return 'park' }
        $prior = @($TaskState.attempts | Where-Object { [string]$_.diagnosis -ceq 'process failure' }).Count
        $Attempt.status = 'failed'; $Attempt.diagnosis = 'process failure'; Save-RunnerState
        if ($prior -lt 1) { return 'fresh-same-effort' }
        Set-RunnerParked 'process failure retry exhausted' $TaskState; return 'park'
    }
    $Attempt.status = 'parked'
    $diagnosis = if ($Result.diagnosis) { [string]$Result.diagnosis } else { "wrapper exit $code" }
    Set-RunnerParked $diagnosis $TaskState
    return 'park'
}

function Invoke-RunnerTaskUntilBuilt {
    param([object]$TaskPlan, [object]$TaskState, [string]$Effort)
    $nextEffort = $Effort
    while ($script:EngineState.status -ceq 'running') {
        $attempt = New-RunnerAttempt $TaskPlan $TaskState $nextEffort
        if ($null -eq $attempt) { return $false }
        while ($true) {
            $child = Start-RunnerAttempt $TaskPlan $TaskState $attempt
            if ($null -eq $child) {
                if ($script:EngineState.status -ceq 'running') {
                    $diagnosis = if ($attempt.diagnosis) { [string]$attempt.diagnosis } else { 'dispatch did not start' }
                    Set-RunnerParked $diagnosis $TaskState
                }
                return $false
            }
            $result = Wait-EngineDispatch -ChildPid $child.pid -ChildOutputPath $attempt.child_output_path -LedgerPath $script:EngineLedgerPath
            $route = Route-RunnerResult $TaskPlan $TaskState $attempt $result
            if ($route -ceq 'success') { return $true }
            if ($route -ceq 'same-attempt') { continue }
            if ($route -ceq 'fresh-same-effort') { $script:EngineState.counters.retries++; break }
            return $false
        }
    }
    return $false
}

function Read-RunnerRecordedResult {
    param([object]$TaskPlan, [object]$Attempt)
    if (-not (Test-Path -LiteralPath ([string]$Attempt.child_output_path) -PathType Leaf)) { return $null }
    try {
        $eventLines = @([IO.File]::ReadAllLines([string]$Attempt.child_output_path) |
            Where-Object { $_ -cmatch '^\[event\] .+\.event\.json\s*$' })
        if ($eventLines.Count -ne 1) { return $null }
        $eventPath = ($eventLines[0] -replace '^\[event\] ', '').Trim()
        if (-not (Test-Path -LiteralPath $eventPath -PathType Leaf)) { return $null }
        $event = Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json
        $read = Read-EngineDispatchEvent -ChildOutputPath $Attempt.child_output_path `
            -ExitCode ([int]$event.exit_code) -TaskId ([string]$TaskPlan.id) `
            -Worktree ([string]$Attempt.worktree) -LedgerPath $script:EngineLedgerPath
        return [pscustomobject]@{
            exit_code = [int]$event.exit_code; child_output_path = [string]$Attempt.child_output_path
            event_path = $read.event_path; event = $read.event; wrapper_run_id = $read.wrapper_run_id
            end_tree_digest = $read.end_tree_digest; diagnosis = $read.diagnosis
        }
    } catch { return $null }
}

function Find-RunnerAttemptRow {
    param([object]$TaskPlan, [object]$Attempt)
    if ($env:APEX_ENGINE_TEST_MODE -ceq '1' -and $env:APEX_ENGINE_TEST_IGNORE_RESUME_LEDGER -ceq '1') {
        return [pscustomobject]@{ found = $false; row = $null }
    }
    return (Find-EngineDispatchRow -LedgerPath $script:EngineLedgerPath -Worktree $Attempt.worktree `
        -Spec $script:EngineState.spec.name -Task $TaskPlan.id -Phase build)
}

function Test-RunnerAttemptNeedsReconcile {
    param([object]$TaskPlan, [object]$Attempt)
    if ([string]$Attempt.status -ceq 'running') { return $true }
    $stamp = if ($Attempt.PSObject.Properties['child_start_time']) { $Attempt.child_start_time } else { $null }
    if (Test-RunnerPidLive $Attempt.child_pid $stamp) { return $true }
    $found = Find-RunnerAttemptRow $TaskPlan $Attempt
    return ($found.found -and -not (Get-RunnerRowStatusTerminal $found.row))
}

function Resume-RunnerAttempt {
    param([object]$TaskPlan, [object]$TaskState, [object]$Attempt)
    if (-not (Test-Path -LiteralPath ([string]$Attempt.worktree) -PathType Container)) {
        Set-RunnerParked 'recorded task worktree is missing' $TaskState; return $false
    }
    try { $branch = Invoke-RunnerGitText $Attempt.worktree 'symbolic-ref' '--short' 'HEAD' }
    catch { Set-RunnerParked 'recorded task worktree branch cannot be read' $TaskState; return $false }
    if ($branch -cne [string]$Attempt.branch) { Set-RunnerParked 'recorded task worktree branch mismatch' $TaskState; return $false }
    $found = Find-RunnerAttemptRow $TaskPlan $Attempt
    $result = Read-RunnerRecordedResult $TaskPlan $Attempt
    if ($found.found) {
        if ($found.row.PSObject.Properties['run_id']) { $Attempt.wrapper_run_id = [string]$found.row.run_id; Save-RunnerState }
        if ($null -eq $result) {
            $live = Wait-EngineLiveRow -WrapperPath $script:EngineWrapper -Row $found.row -Spec $script:EngineState.spec.name `
                -Task $TaskPlan.id -Worktree $Attempt.worktree -StateRoot $script:EngineStateRoot `
                -ChildOutputPath ($Attempt.child_output_path + '.resume-adopt') -WaitStartedAt ([DateTime]::UtcNow)
            if ($live.status -ceq 'terminal') { $result = $live.result }
            else { Set-RunnerParked ([string]$live.diagnosis) $TaskState; return $false }
        }
    } elseif ($null -eq $result) {
        $stamp = if ($Attempt.PSObject.Properties['child_start_time']) { $Attempt.child_start_time } else { $null }
        if (Test-RunnerPidLive $Attempt.child_pid $stamp) {
            $result = Wait-EngineDispatch -ChildPid ([int]$Attempt.child_pid) `
                -ChildOutputPath $Attempt.child_output_path -LedgerPath $script:EngineLedgerPath
        } else {
            Set-RunnerParked 'recorded child is dead or unknown and has no ledger row or event' $TaskState
            return $false
        }
    }
    $route = Route-RunnerResult $TaskPlan $TaskState $Attempt $result
    if ($route -ceq 'success') { return $true }
    if ($route -in @('fresh-same-effort', 'same-attempt')) {
        return Invoke-RunnerTaskUntilBuilt $TaskPlan $TaskState ([string]$Attempt.effort)
    }
    return $false
}

function Get-RunnerNextEffort {
    param([string]$Effort)
    switch -CaseSensitive ($Effort) { 'low' { 'medium' } 'medium' { 'high' } 'high' { 'xhigh' } default { $null } }
}

function Invoke-RunnerGate {
    param([object[]]$Files, [int]$WaveNumber)
    $stage = Stage-EngineWave -IntegrationWorktree $script:EngineState.integration.worktree -Files $Files
    if (-not $stage.ok) { return [pscustomobject]@{ code = 1; diagnosis = 'operation precondition failure'; moved = $false; gate = 'stage' } }
    $label = "engine-$($script:EngineState.run_id)-wave-$WaveNumber"
    for ($pass = 0; $pass -lt 2; $pass++) {
        $pin = Invoke-RunnerScript $script:EngineTreePinScript `
            @('-Pin', '-Worktree', [string]$script:EngineState.integration.worktree, '-Label', $label, '-PinDirectory', (Split-Path -Parent $script:EngineStatePath))
        if ($pin.exit_code -ne 0) { return [pscustomobject]@{ code = $pin.exit_code; diagnosis = $pin.output; moved = $false; gate = 'pin' } }
        $baseline = Invoke-RunnerScript $script:EngineBaselineScript `
            @('-Full', '-Worktree', [string]$script:EngineState.integration.worktree)
        $verify = Invoke-RunnerScript $script:EngineTreePinScript `
            @('-Verify', '-Worktree', [string]$script:EngineState.integration.worktree, '-Label', $label, '-PinDirectory', (Split-Path -Parent $script:EngineStatePath))
        if ($verify.exit_code -eq 0) { return [pscustomobject]@{ code = $baseline.exit_code; diagnosis = $baseline.output; moved = $false; gate = 'baseline' } }
        if ($verify.exit_code -ne 69) { return [pscustomobject]@{ code = $verify.exit_code; diagnosis = $verify.output; moved = $false; gate = 'verify' } }
        if ($pass -eq 1) { return [pscustomobject]@{ code = 69; diagnosis = 'integration tree moved twice'; moved = $true; gate = 'verify' } }
    }
}

function Restore-RunnerWave {
    param([string]$Base, [object[]]$Files)
    $restored = Restore-EngineWave -IntegrationWorktree $script:EngineState.integration.worktree -WaveBaseSha $Base -Files $Files
    return [bool]$restored.ok
}

function Find-RunnerWaveFailure {
    param([object]$Wave, [string]$WaveBase, [object[]]$WaveFiles)
    [void](Restore-RunnerWave $WaveBase $WaveFiles)
    $failed = @()
    foreach ($taskPlan in @($Wave.tasks)) {
        $taskState = Get-RunnerTaskState $taskPlan.id
        $attempt = @($taskState.attempts)[-1]
        $copy = Copy-EngineTaskFiles -IntegrationWorktree $script:EngineState.integration.worktree `
            -TaskWorktree $attempt.worktree -WaveBaseSha $WaveBase -Files ([object[]]@($taskPlan.files))
        if (-not $copy.ok) { $failed += $taskPlan.id }
        else {
            $gate = Invoke-RunnerGate ([object[]]@($taskPlan.files)) ([int]$Wave.number)
            if ($gate.code -ne 0) { $failed += $taskPlan.id }
        }
        [void](Restore-RunnerWave $WaveBase $WaveFiles)
    }
    return [string[]]$failed
}

function Invoke-RunnerWave {
    param([object]$Wave)
    $waveBase = Invoke-RunnerGitText $script:EngineState.integration.worktree 'rev-parse' 'HEAD'
    $waveFiles = [object[]]@($Wave.tasks | ForEach-Object { @($_.files) })

    # Launch all not-yet-built tasks before waiting, preserving one worktree per child.
    $launched = @()
    foreach ($taskPlan in @($Wave.tasks)) {
        $taskState = Get-RunnerTaskState $taskPlan.id
        if ($taskState.status -ceq 'integrated') { continue }
        $successful = @($taskState.attempts | Where-Object { $_.status -ceq 'succeeded' })
        if ($successful.Count -gt 0) { continue }
        $attempts = @($taskState.attempts)
        $lastAttempt = if ($attempts.Count -gt 0) { $attempts[-1] } else { $null }
        if ($null -ne $lastAttempt -and (Test-RunnerAttemptNeedsReconcile $taskPlan $lastAttempt)) {
            # A wait-cap park does not kill the wrapper. Reconcile that exact child/row before
            # considering any new worktree or dispatch for the task.
            $lastAttempt.status = 'running'; $taskState.status = 'running'; $taskState.diagnosis = $null
            Save-RunnerState
            if (-not (Resume-RunnerAttempt $taskPlan $taskState $lastAttempt)) { return $false }
            continue
        }
        if ([string]$taskState.diagnosis -ceq 'verification effort ladder exhausted') {
            $script:EngineState.status = 'partial'; $script:EngineState.diagnosis = [string]$taskState.diagnosis
            Save-RunnerState; return $false
        }
        $resumeEffort = [string]$taskPlan.effort
        if ($null -ne $lastAttempt -and [string]$lastAttempt.status -ceq 'failed' -and
                [string]$lastAttempt.diagnosis -ceq 'verification failure') {
            # The verified attempt is saved failed before the next rung is created. A crash in that
            # window must resume at the next rung, not repeat the plan's starting effort.
            $resumeEffort = Get-RunnerNextEffort ([string]$lastAttempt.effort)
            if (-not $resumeEffort) {
                $taskState.status = 'failed'; $taskState.diagnosis = 'verification effort ladder exhausted'
                $script:EngineState.status = 'partial'; $script:EngineState.diagnosis = $taskState.diagnosis
                Add-RunnerTransition 'partial' $taskState.diagnosis; Save-RunnerState; return $false
            }
        } elseif ($null -ne $lastAttempt -and [string]$taskState.status -in @('parked', 'failed')) {
            $resumeEffort = [string]$lastAttempt.effort
        }
        $attempt = New-RunnerAttempt $taskPlan $taskState $resumeEffort
        if ($null -eq $attempt) { return $false }
        $child = Start-RunnerAttempt $taskPlan $taskState $attempt
        if ($null -eq $child) {
            if ($script:EngineState.status -ceq 'running') {
                $diagnosis = if ($attempt.diagnosis) { [string]$attempt.diagnosis } else { 'dispatch did not start' }
                Set-RunnerParked $diagnosis $taskState
            }
            return $false
        }
        $launched += [pscustomobject]@{ plan = $taskPlan; state = $taskState; attempt = $attempt; child = $child }
    }
    foreach ($item in $launched) {
        $result = Wait-EngineDispatch -ChildPid $item.child.pid -ChildOutputPath $item.attempt.child_output_path -LedgerPath $script:EngineLedgerPath
        $route = Route-RunnerResult $item.plan $item.state $item.attempt $result
        while ($route -in @('same-attempt', 'fresh-same-effort')) {
            if ($route -ceq 'same-attempt') {
                $child = Start-RunnerAttempt $item.plan $item.state $item.attempt
                if ($null -eq $child) { return $false }
                $result = Wait-EngineDispatch $child.pid $item.attempt.child_output_path $script:EngineLedgerPath
                $route = Route-RunnerResult $item.plan $item.state $item.attempt $result
            } else {
                if (-not (Invoke-RunnerTaskUntilBuilt $item.plan $item.state ([string]$item.attempt.effort))) { return $false }
                $route = 'success'
            }
        }
        if ($route -cne 'success') { return $false }
    }

    while ($script:EngineState.status -ceq 'running') {
        [void](Restore-RunnerWave $waveBase $waveFiles)
        $copyFailures = @()
        foreach ($taskPlan in @($Wave.tasks)) {
            $taskState = Get-RunnerTaskState $taskPlan.id
            $attempt = @($taskState.attempts | Where-Object { $_.status -ceq 'succeeded' })[-1]
            $copied = Copy-EngineTaskFiles -IntegrationWorktree $script:EngineState.integration.worktree `
                -TaskWorktree $attempt.worktree -WaveBaseSha $waveBase -Files ([object[]]@($taskPlan.files))
            if (-not $copied.ok) { $copyFailures += $taskPlan.id }
        }
        $failureIds = [string[]]$copyFailures
        $gate = $null
        if ($failureIds.Count -eq 0) { $gate = Invoke-RunnerGate $waveFiles ([int]$Wave.number) }
        if ($failureIds.Count -eq 0 -and $gate.code -eq 0) {
            try { $commit = Commit-EngineWave -IntegrationWorktree $script:EngineState.integration.worktree -Message "APEX Engine $($script:EngineState.spec.name) wave $($Wave.number)" }
            catch { Set-RunnerParked "wave commit failed: $($_.Exception.Message)" $null; return $false }
            # Test-only crash-window seam: the commit exists, but its state transition does not.
            if ($env:APEX_ENGINE_TEST_MODE -ceq '1' -and $env:APEX_ENGINE_TEST_CRASH_AFTER_WAVE_COMMIT -ceq '1') {
                throw 'simulated crash after wave commit before journal'
            }
            $script:EngineState.integration.tip = $commit.head_sha
            foreach ($taskPlan in @($Wave.tasks)) { (Get-RunnerTaskState $taskPlan.id).status = 'integrated' }
            Add-RunnerTransition 'wave-integrated' "$($Wave.number)/$($commit.head_sha)"; Save-RunnerState
            return $true
        }
        if ($null -ne $gate -and [string]$gate.gate -in @('pin', 'verify')) {
            Set-RunnerParked "$($gate.gate) gate exit $($gate.code): $($gate.diagnosis)" $null; return $false
        }
        if ($null -ne $gate -and [string]$gate.gate -ceq 'baseline' -and $gate.code -ne 1) {
            Set-RunnerParked "baseline gate exit $($gate.code): $($gate.diagnosis)" $null; return $false
        }
        if ($failureIds.Count -eq 0) {
            if (@($Wave.tasks).Count -eq 1) { $failureIds = @([string]$Wave.tasks[0].id) }
            else { $failureIds = @(Find-RunnerWaveFailure $Wave $waveBase $waveFiles) }
        }
        if ($failureIds.Count -ne 1) {
            $script:EngineState.status = 'partial'; $script:EngineState.diagnosis = 'ambiguous wave verification failure'
            Add-RunnerTransition 'partial' $script:EngineState.diagnosis; Save-RunnerState; return $false
        }
        $failedPlan = Get-RunnerTaskPlan $failureIds[0]; $failedState = Get-RunnerTaskState $failureIds[0]
        $currentAttempt = @($failedState.attempts | Where-Object { $_.status -ceq 'succeeded' })[-1]
        $next = Get-RunnerNextEffort ([string]$currentAttempt.effort)
        if (-not $next) {
            $failedState.status = 'failed'; $failedState.diagnosis = 'verification effort ladder exhausted'
            $script:EngineState.status = 'partial'; $script:EngineState.diagnosis = $failedState.diagnosis
            Add-RunnerTransition 'partial' $failedState.diagnosis; Save-RunnerState; return $false
        }
        $currentAttempt.status = 'failed'; $currentAttempt.diagnosis = 'verification failure'
        $script:EngineState.counters.retries++; Save-RunnerState
        if ($env:APEX_ENGINE_TEST_MODE -ceq '1' -and
                $env:APEX_ENGINE_TEST_CRASH_AFTER_VERIFICATION_FAILURE -ceq '1') {
            throw 'simulated crash after verification failure before next rung'
        }
        if (-not (Invoke-RunnerTaskUntilBuilt $failedPlan $failedState $next)) { return $false }
    }
    return $false
}

function Invoke-RunnerHandoff {
    $script:EngineState.handoff.status = 'running'
    if (-not $script:EngineState.handoff.started_at) { $script:EngineState.handoff.started_at = Get-RunnerUtc }
    Add-RunnerTransition 'handoff-started' $null; Save-RunnerState
    $callback = {
        param($Path)
        # Hermetic crash-window seam. Task 2 calls this only after the file write and verification,
        # so throwing here simulates loss between the write and Engine's durable journal update.
        if ($env:APEX_ENGINE_TEST_MODE -ceq '1' -and
                [string]$env:APEX_ENGINE_TEST_FAIL_BEFORE_HANDOFF_JOURNAL -ceq [string]$Path) {
            throw "simulated hand-off crash before journaling $Path"
        }
        if (@($script:EngineState.handoff.journaled_paths) -notcontains [string]$Path) {
            $script:EngineState.handoff.journaled_paths = @($script:EngineState.handoff.journaled_paths) + [string]$Path
        }
        Add-RunnerTransition 'handoff-file' ([string]$Path)
        Save-RunnerState
    }
    $result = Invoke-EngineHandoff -Repo $script:EngineState.repo -IntegrationWorktree $script:EngineState.integration.worktree `
        -BaseSha $script:EngineState.base_sha -Files (Get-RunnerAllFiles) `
        -JournaledPaths ([string[]]@($script:EngineState.handoff.journaled_paths)) -OnFileJournaled $callback `
        -StateDirectory (Split-Path -Parent $script:EngineStatePath)
    if (-not $result.ok) {
        $script:EngineState.handoff.status = 'partial'; $script:EngineState.handoff.mismatch_path = $result.mismatch_path
        $script:EngineState.handoff.recovery_patch = $result.recovery_patch; $script:EngineState.status = 'partial'
        $script:EngineState.diagnosis = "hand-off mismatch: $($result.mismatch_path)"
        Add-RunnerTransition 'handoff-partial' $script:EngineState.diagnosis; Save-RunnerState; return $false
    }
    $script:EngineState.handoff.status = 'complete'; $script:EngineState.handoff.completed_at = Get-RunnerUtc
    $script:EngineState.status = 'complete'; $script:EngineState.diagnosis = $null
    Add-RunnerTransition 'complete' 'hand-off complete'; Save-RunnerState
    return $true
}

function Write-RunnerSummary {
    Write-Host "State: $($script:EngineStatePath)"
    $taskSummaries = @()
    foreach ($task in @($script:EngineState.tasks)) {
        $last = @($task.attempts | Select-Object -Last 1)
        $run = if ($last.Count -gt 0 -and $last[0].wrapper_run_id) { $last[0].wrapper_run_id } else { '-' }
        $tree = if ($last.Count -gt 0) { $last[0].worktree } else { '-' }
        $taskSummaries += "$($task.id)=$($task.status),wrapper=$run,worktree=$tree"
    }
    if ($taskSummaries.Count -gt 0) { Write-Host ('Tasks: ' + ($taskSummaries -join '; ')) }
    Write-Host "Wrapper spec: $($script:EngineState.spec.name)"
    Write-Host "Ledger: $($script:EngineLedgerPath)"
    if ($script:EngineState.diagnosis) { Write-Host "Diagnosis: $($script:EngineState.diagnosis)" }
    Write-Host 'Next: Critic review, docs/owner commit, then -Teardown <runId>.'
    Write-Host "Run: $($script:EngineState.status)"
}

function Invoke-RunnerTeardown {
    param([string]$RunId)
    $runDirectory = Join-Path $script:EngineStateRoot $RunId
    $script:EngineStatePath = Join-Path $runDirectory 'engine-state.json'
    if (-not (Test-Path -LiteralPath $script:EngineStatePath -PathType Leaf)) { throw "Engine state not found: $script:EngineStatePath" }
    $owner = Open-RunnerRunLock $runDirectory
    $script:EngineState = Get-Content -LiteralPath $script:EngineStatePath -Raw | ConvertFrom-Json
    $script:EngineLedgerPath = Join-Path $script:EngineStateRoot 'progress\codex-run-ledger.jsonl'
    if ($script:EngineState.run_id -cne $RunId) { throw 'State run_id does not match its directory.' }
    $script:EngineState.engine_owner = $owner; Save-RunnerState
    foreach ($task in @($script:EngineState.tasks)) {
        foreach ($attempt in @($task.attempts)) {
            $stamp = if ($attempt.PSObject.Properties['child_start_time']) { $attempt.child_start_time } else { $null }
            if (Test-RunnerPidLive $attempt.child_pid $stamp) { throw "Refusing teardown: task $($task.id) has a live recorded child_pid." }
            foreach ($row in @(Read-EngineLedgerRows -LedgerPath $script:EngineLedgerPath)) {
                if (-not $row.PSObject.Properties['worktree'] -or -not $row.PSObject.Properties['spec'] -or
                        -not $row.PSObject.Properties['task']) { continue }
                if (-not (Test-EnginePathEqual ([string]$row.worktree) ([string]$attempt.worktree)) -or
                        [string]$row.spec -cne [string]$script:EngineState.spec.name -or
                        [string]$row.task -cne [string]$task.id) { continue }
                if (-not (Get-RunnerRowStatusTerminal $row)) { throw "Refusing teardown: task $($task.id) has a non-terminal ledger row." }
            }
        }
    }
    if ($script:EngineState.status -ceq 'complete') {
        if ($Discard) { throw '-Discard is not valid for a complete run.' }
        if ($script:EngineState.handoff.status -cne 'complete' -or @($script:EngineState.handoff.journaled_paths).Count -ne @(Get-RunnerAllFiles).Count) {
            throw 'Complete teardown requires a full hand-off journal.'
        }
        $proof = Test-EngineTeardownProof -Repo $script:EngineState.repo `
            -Spec ([pscustomobject]@{ name = $script:EngineState.spec.name; run_id = $RunId }) `
            -Files (Get-RunnerAllFiles) -IntegrationTip $script:EngineState.integration.tip
        if (-not $proof.ok) { throw 'Complete teardown proof failed.' }
    } elseif (-not $Discard) { throw 'Partial, parked, paused, or refused teardown requires -Discard.' }
    $branches = @(); $worktrees = @()
    if ($script:EngineState.integration.branch) { $branches += [string]$script:EngineState.integration.branch }
    if ($script:EngineState.integration.worktree) { $worktrees += [string]$script:EngineState.integration.worktree }
    foreach ($task in @($script:EngineState.tasks)) { foreach ($attempt in @($task.attempts)) { $branches += [string]$attempt.branch; $worktrees += [string]$attempt.worktree } }
    $script:EngineState.teardown.status = 'running'; $script:EngineState.teardown.discard = [bool]$Discard; Save-RunnerState
    $callback = {
        param($Item)
        $script:EngineState.teardown.items = @($script:EngineState.teardown.items) + [pscustomobject][ordered]@{
            kind = [string]$Item.kind; value = [string]$Item.value; removed_at = Get-RunnerUtc
        }
        Add-RunnerTransition 'teardown-item' "$($Item.kind):$($Item.value)"; Save-RunnerState
    }
    $removed = Remove-EngineRunWorktrees -Repo $script:EngineState.repo `
        -Spec ([pscustomobject]@{ name = $script:EngineState.spec.name; run_id = $RunId }) `
        -Branches ([string[]]$branches) -Worktrees ([string[]]$worktrees) -OnItemRemoved $callback
    if (-not $removed.ok) { $script:EngineState.teardown.status = 'failed'; Save-RunnerState; throw 'Engine teardown removal failed.' }
    $script:EngineState.teardown.status = 'complete'; Add-RunnerTransition 'teardown-complete' $null; Save-RunnerState
    Write-RunnerSummary
}

function Initialize-RunnerNewState {
    if (-not $SpecPath -or -not $Repo) { throw '-SpecPath and -Repo are required for a new run.' }
    if (-not [IO.Path]::IsPathRooted($SpecPath) -or -not [IO.Path]::IsPathRooted($Repo)) { throw '-SpecPath and -Repo must be absolute.' }
    $effective = if ($script:EngineMaxParallelBound) { $MaxParallel } else { 2 }
    $plan = Get-EnginePlan -SpecPath $SpecPath -Repo $Repo -MaxParallel $effective
    if (-not $script:EngineMaxParallelBound -and $plan.allowed -and $null -ne $plan.spec.max_parallel_codex -and
            [int]$plan.spec.max_parallel_codex -ne $effective) {
        $effective = [int]$plan.spec.max_parallel_codex
        $plan = Get-EnginePlan -SpecPath $SpecPath -Repo $Repo -MaxParallel $effective
    }
    $runId = [Guid]::NewGuid().ToString('N')
    $runDirectory = Join-Path $script:EngineStateRoot $runId
    $script:EngineStatePath = Join-Path $runDirectory 'engine-state.json'
    $owner = Open-RunnerRunLock $runDirectory
    $repoRoot = Get-RunnerPath $Repo
    $baseSha = Invoke-RunnerGitText $repoRoot 'rev-parse' 'HEAD'
    if (-not $plan.allowed) {
        [void][IO.Directory]::CreateDirectory($runDirectory)
        $name = if ($plan.spec.name -match '^[a-z0-9][a-z0-9-]{0,62}$') { [string]$plan.spec.name } else { 'refused' }
        $digest = if ($plan.spec.digest -match '^[0-9a-f]{64}$') { [string]$plan.spec.digest } else { '0' * 64 }
        $script:EngineState = New-RunnerStateObject $runId $runDirectory $repoRoot $baseSha $effective $plan $name $digest $null $owner
        $script:EngineState.status = 'refused'; $script:EngineState.diagnosis = [string]$plan.refusal
        Add-RunnerTransition 'refused' ([string]$plan.refusal); Save-RunnerState; return $false
    }
    [void][IO.Directory]::CreateDirectory($runDirectory)
    $snapshot = Join-Path $runDirectory ($plan.spec.name + '.md')
    [IO.File]::WriteAllBytes($snapshot, [IO.File]::ReadAllBytes((Get-RunnerPath $SpecPath)))
    $snapshotDigest = Get-RunnerDigest $snapshot
    if ($snapshotDigest -cne [string]$plan.spec.digest) { throw 'Spec snapshot digest changed during copy.' }
    foreach ($wave in @($plan.waves)) { foreach ($task in @($wave.tasks)) {
        if (-not $task.PSObject.Properties['coder_model']) {
            $task | Add-Member -NotePropertyName coder_model -NotePropertyValue ([string]$plan.spec.coder_model)
        }
    } }
    $script:EngineState = New-RunnerStateObject $runId $runDirectory $repoRoot $baseSha $effective $plan $plan.spec.name $plan.spec.digest $snapshot $owner
    Save-RunnerState # base_sha and immutable plan are durable before New-EngineIntegration.
    try {
        $integration = New-EngineIntegration -Repo $repoRoot `
            -Spec ([pscustomobject]@{ name = $plan.spec.name; run_id = $runId }) -BaseSha $baseSha -WorktreeRoot $script:EngineWorktreeRoot
    } catch { Set-RunnerParked "integration worktree creation failed: $($_.Exception.Message)" $null; return $false }
    $script:EngineState.integration.worktree = $integration.worktree
    $script:EngineState.integration.branch = $integration.branch
    $script:EngineState.integration.tip = $integration.head_sha
    Add-RunnerTransition 'integration-created' $integration.branch; Save-RunnerState
    return $true
}

function New-RunnerStateObject {
    param($RunId, $RunDirectory, $RepoRoot, $BaseSha, $Effective, $Plan, $Name, $Digest, $Snapshot, $Owner)
    $tasks = @()
    foreach ($wave in @($Plan.waves)) { foreach ($task in @($wave.tasks)) {
        $tasks += [pscustomobject][ordered]@{ id = [string]$task.id; status = 'pending'; diagnosis = $null; concerns = @(); attempts = @() }
    } }
    $now = Get-RunnerUtc
    [pscustomobject][ordered]@{
        schema_version = 1; run_id = $RunId; status = 'running'; created_at = $now; updated_at = $now
        engine_owner = $Owner
        state_path = $script:EngineStatePath; worktree_root = $script:EngineWorktreeRoot
        wrapper_path = $script:EngineWrapper; codex_executable = $(if ($script:EngineCodexExecutable) { $script:EngineCodexExecutable } else { $null })
        codex_executable_argument_prefix = [string[]]@($script:EngineCodexPrefix)
        spec = [pscustomobject][ordered]@{ name = $Name; original_path = (Get-RunnerPath $SpecPath); original_digest = $Digest; snapshot_path = $Snapshot; snapshot_digest = $Digest }
        repo = $RepoRoot; base_sha = $BaseSha
        integration = [pscustomobject][ordered]@{ worktree = $null; branch = $null; tip = $null }
        max_parallel = [int]$Effective; plan = $Plan; tasks = [object[]]$tasks
        counters = [pscustomobject][ordered]@{ dispatches = 0; retries = 0; capacity_retries = 0; concerns = 0 }
        concerns = @(); diagnosis = $null
        handoff = [pscustomobject][ordered]@{ status = 'pending'; started_at = $null; completed_at = $null; journaled_paths = @(); mismatch_path = $null; recovery_patch = $null }
        teardown = [pscustomobject][ordered]@{ status = 'pending'; discard = $false; items = @() }
        transitions = @([pscustomobject][ordered]@{ at = $now; kind = 'created'; detail = $null })
    }
}

function Test-RunnerCommitMatchesWave {
    param([object]$Wave, [string]$RecordedTip, [string]$ActualTip)
    try {
        $parent = Invoke-RunnerGitText $script:EngineState.integration.worktree 'rev-parse' "$ActualTip^"
        if ($parent -cne $RecordedTip) { return $false }
        $changedText = Invoke-RunnerGitText $script:EngineState.integration.worktree 'diff-tree' '--no-commit-id' '--name-only' '-r' $ActualTip
        $changed = @($changedText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $expected = @($Wave.tasks | ForEach-Object { @($_.files | ForEach-Object { [string]$_.path }) })
        if ($changed.Count -ne $expected.Count) { return $false }
        foreach ($path in $expected) { if ($changed -cnotcontains $path) { return $false } }
        foreach ($taskPlan in @($Wave.tasks)) {
            $taskState = Get-RunnerTaskState ([string]$taskPlan.id)
            $successful = @($taskState.attempts | Where-Object { [string]$_.status -ceq 'succeeded' })
            if ($successful.Count -eq 0) { return $false }
            $attempt = $successful[-1]
            foreach ($file in @($taskPlan.files)) {
                $path = [string]$file.path
                $commitHash = Get-EngineBlobHash -Repo $script:EngineState.integration.worktree -Commit $ActualTip -RelativePath $path
                if ([string]$file.op -ceq 'delete') {
                    if ($null -ne $commitHash -or (Test-Path -LiteralPath (Join-Path $attempt.worktree ($path.Replace('/', '\'))))) { return $false }
                } else {
                    $attemptHash = Get-EngineFilteredWorkingHash -Repo $attempt.worktree -RelativePath $path
                    if (-not $attemptHash -or $commitHash -cne $attemptHash) { return $false }
                }
            }
        }
        return $true
    } catch { return $false }
}

function Invoke-RunnerAdoptCrashWindowCommit {
    param([string]$RecordedTip, [string]$ActualTip)
    $candidates = @()
    foreach ($wave in @($script:EngineState.plan.waves)) {
        $states = @($wave.tasks | ForEach-Object { Get-RunnerTaskState ([string]$_.id) })
        if (@($states | Where-Object { [string]$_.status -cne 'integrated' }).Count -eq 0) { continue }
        $verified = $true
        foreach ($state in $states) {
            if (@($state.attempts | Where-Object { [string]$_.status -ceq 'succeeded' }).Count -eq 0) { $verified = $false }
        }
        if ($verified) { $candidates += $wave }
    }
    if ($candidates.Count -ne 1 -or -not (Test-RunnerCommitMatchesWave $candidates[0] $RecordedTip $ActualTip)) { return $false }
    $wave = $candidates[0]
    $script:EngineState.integration.tip = $ActualTip
    foreach ($taskPlan in @($wave.tasks)) { (Get-RunnerTaskState ([string]$taskPlan.id)).status = 'integrated' }
    Add-RunnerTransition 'wave-commit-adopted' "$($wave.number)/$ActualTip"
    Save-RunnerState
    return $true
}

function Initialize-RunnerResume {
    param([string]$RunId)
    $runDirectory = Join-Path $script:EngineStateRoot $RunId
    $script:EngineStatePath = Join-Path $runDirectory 'engine-state.json'
    if (-not (Test-Path -LiteralPath $script:EngineStatePath -PathType Leaf)) { throw "Engine state not found: $script:EngineStatePath" }
    $owner = Open-RunnerRunLock $runDirectory
    $script:EngineState = Get-Content -LiteralPath $script:EngineStatePath -Raw | ConvertFrom-Json
    if ([string]$script:EngineState.run_id -cne $RunId) { throw 'State run_id does not match its directory.' }
    if ([string]$script:EngineState.status -notin @('running', 'partial', 'parked', 'paused')) { throw "Run status cannot be resumed: $($script:EngineState.status)" }
    $script:EngineState.engine_owner = $owner; Save-RunnerState
    if (-not $script:EngineWorktreeRootBound) { $script:EngineWorktreeRoot = Get-RunnerPath ([string]$script:EngineState.worktree_root) }
    if (-not $script:EngineWrapperBound) { $script:EngineWrapper = Get-RunnerPath ([string]$script:EngineState.wrapper_path) }
    if (-not $script:EngineCodexBound) { $script:EngineCodexExecutable = [string]$script:EngineState.codex_executable }
    if (-not $script:EngineCodexPrefixBound) { $script:EngineCodexPrefix = [string[]]@($script:EngineState.codex_executable_argument_prefix) }
    if (-not (Test-RunnerOutsideWorktree $script:EngineWorktreeRoot)) { throw 'Recorded worktree root is inside a Git worktree.' }
    if (-not (Test-Path -LiteralPath $script:EngineWrapper -PathType Leaf)) { throw "Recorded wrapper is missing: $script:EngineWrapper" }
    try { $digest = Get-RunnerDigest ([string]$script:EngineState.spec.original_path) }
    catch { $digest = $null }
    if ($digest -cne [string]$script:EngineState.spec.original_digest) {
        Set-RunnerParked 'original spec digest mismatch on resume' $null; return $false
    }
    if ((Get-RunnerDigest ([string]$script:EngineState.spec.snapshot_path)) -cne [string]$script:EngineState.spec.snapshot_digest) {
        Set-RunnerParked 'spec snapshot digest mismatch on resume' $null; return $false
    }
    if ($script:EngineState.integration.worktree) {
        if (-not (Test-Path -LiteralPath ([string]$script:EngineState.integration.worktree) -PathType Container)) { Set-RunnerParked 'integration worktree is missing' $null; return $false }
        $tip = Invoke-RunnerGitText $script:EngineState.integration.worktree 'rev-parse' 'HEAD'
        if ($script:EngineState.integration.tip -and $tip -cne [string]$script:EngineState.integration.tip) {
            if (-not (Invoke-RunnerAdoptCrashWindowCommit ([string]$script:EngineState.integration.tip) $tip)) {
                Set-RunnerParked 'integration branch tip mismatch' $null; return $false
            }
        }
    }
    $script:EngineState.status = 'running'; $script:EngineState.diagnosis = $null
    Add-RunnerTransition 'resumed' $null; Save-RunnerState
    return $true
}

# Allows engine-test.ps1 to exercise routing functions directly. It is inert unless the explicit
# test-mode import flag is present, and never changes production invocation behavior.
if ($env:APEX_ENGINE_TEST_MODE -ceq '1' -and $env:APEX_ENGINE_TEST_IMPORT_ONLY -ceq '1') { return }

try {
    if ($Resume -and $Teardown) { throw 'Choose either -Resume or -Teardown.' }
    foreach ($candidate in @($Resume, $Teardown)) {
        if ($candidate -and $candidate -cnotmatch '^[0-9a-f]{32}$') { throw 'Resume/Teardown run IDs must be 32 lowercase hexadecimal characters.' }
    }
    if (-not $StateRoot) {
        if ($env:APEX_STATE_DIR) { $StateRoot = $env:APEX_STATE_DIR }
        else { $StateRoot = Join-Path $env:LOCALAPPDATA 'apex' }
    }
    if (-not $Repo -and -not ($Resume -or $Teardown)) { throw '-Repo is required for a new run.' }
    if (-not $WorktreeRoot) {
        if ($Repo) { $repoDefault = Get-RunnerPath $Repo; $WorktreeRoot = Join-Path (Split-Path -Parent $repoDefault) ((Split-Path -Leaf $repoDefault) + '-wt') }
        else { $WorktreeRoot = Join-Path (Split-Path -Parent (Get-RunnerPath $StateRoot)) 'engine-worktrees' }
    }
    $script:EngineStateRoot = Get-RunnerPath $StateRoot
    $script:EngineWorktreeRoot = Get-RunnerPath $WorktreeRoot
    foreach ($outside in @($script:EngineStateRoot, $script:EngineWorktreeRoot)) {
        if (-not (Test-RunnerOutsideWorktree $outside)) { throw "Engine root must be outside every Git worktree: $outside" }
    }
    $script:EngineWrapper = Get-RunnerPath $(if ($WrapperPath) { $WrapperPath } else { Join-Path $PSScriptRoot 'codex-dispatch.ps1' })
    if (-not (Test-Path -LiteralPath $script:EngineWrapper -PathType Leaf)) { throw "Wrapper not found: $script:EngineWrapper" }
    $script:EngineLedgerPath = Join-Path $script:EngineStateRoot 'progress\codex-run-ledger.jsonl'

    if ($Teardown) { Invoke-RunnerTeardown $Teardown; exit 0 }
    $ready = if ($Resume) { Initialize-RunnerResume $Resume } else { Initialize-RunnerNewState }
    if (-not $ready) { Write-RunnerSummary; exit 1 }

    foreach ($wave in @($script:EngineState.plan.waves)) {
        $pending = @($wave.tasks | Where-Object { (Get-RunnerTaskState $_.id).status -cne 'integrated' })
        if ($pending.Count -gt 0 -and -not (Invoke-RunnerWave $wave)) { Write-RunnerSummary; exit 1 }
    }
    if ($script:EngineState.handoff.status -cne 'complete') {
        if (-not (Invoke-RunnerHandoff)) { Write-RunnerSummary; exit 1 }
    } else { $script:EngineState.status = 'complete'; Save-RunnerState }
    Write-RunnerSummary
    exit 0
} catch {
    if ($null -ne $script:EngineState) {
        if ($Teardown) {
            $script:EngineState.teardown.status = 'failed'
            Add-RunnerTransition 'teardown-refused' $_.Exception.Message
            Write-Host "Teardown refused: $($_.Exception.Message)"
        } else {
            $script:EngineState.status = 'parked'; $script:EngineState.diagnosis = $_.Exception.Message
            Add-RunnerTransition 'exception' $_.Exception.Message
        }
        try { Save-RunnerState } catch { }
        Write-RunnerSummary
    } else { Write-Host "Engine refused: $($_.Exception.Message)" }
    exit 1
} finally {
    Close-RunnerRunLock
}
