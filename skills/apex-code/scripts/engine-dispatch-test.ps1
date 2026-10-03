$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$adapter = Join-Path $PSScriptRoot 'engine-dispatch.ps1'
$wrapper = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
$fakeCodex = Join-Path $PSScriptRoot 'dispatch-test-fakecodex.ps1'
. $adapter

$script:failures = 0
function Assert-EngineCase {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Condition, [string]$Detail)
    if ($Condition) { Write-Host "PASS: $Name" -ForegroundColor Green }
    else { $script:failures++; Write-Host "FAIL: $Name -- $Detail" -ForegroundColor Red }
}

function Write-TestText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $parent = Split-Path $Path -Parent
    if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-TestGit {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string[]]$Arguments)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $output = @(& git -C $Repo @Arguments 2>&1); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
    return @($output)
}

function New-TestSpecText {
    param([Parameter(Mandatory)][string]$Spec)
    return @"
---
spec: $Spec
status: draft
autonomy_level: L2
risk: low
coder_model: gpt-5.6-sol
coder_effort: medium
max_parallel_codex: 2
---
# Spec: dispatch fixture
## Intent
- Intent: exercise the Engine dispatch adapter.
## Assumptions
- PowerShell is available -> impact: Stop
## Prerequisites
- none
## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| src/a.py | modify | first typed path |
| src/two.py | create | second typed path |
## Tasks
- [ ] **Task 1:** edit both files -- files: src/a.py, src/two.py -- done when: both paths are written.
## Wave plan
Wave 1: [Task 1]
## Permissions
Approving this spec approves the file operations above.
## Specialist Context
### Security
(none)
## Documentation
(none)
## Acceptance Criteria
- [ ] **Task 1** -> verify: both paths are written.
## Progress
_(coding writes here)_
"@
}

function New-TestRepo {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Spec)
    [System.IO.Directory]::CreateDirectory((Join-Path $Path 'src')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $Path 'docs\changes')) | Out-Null
    Write-TestText (Join-Path $Path 'src\a.py') "original`n"
    Write-TestText (Join-Path $Path 'AGENTS.md') @'
## Verify commands

```
exit 0
```
'@
    Write-TestText (Join-Path $Path "docs\changes\$Spec.md") (New-TestSpecText $Spec)
    Invoke-TestGit $Path @('init', '-q') | Out-Null
    Invoke-TestGit $Path @('config', 'user.email', 'engine-dispatch@example.invalid') | Out-Null
    Invoke-TestGit $Path @('config', 'user.name', 'engine-dispatch') | Out-Null
    Invoke-TestGit $Path @('add', '-A') | Out-Null
    Invoke-TestGit $Path @('commit', '-q', '-m', 'fixture') | Out-Null
    return ([string](Invoke-TestGit $Path @('rev-parse', 'HEAD'))).Trim()
}

function Wait-TestRow {
    param([string]$Ledger, [string]$Repo, [string]$Spec, [int]$Seconds = 20)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $found = Find-EngineDispatchRow -LedgerPath $Ledger -Worktree $Repo -Spec $Spec -Task '1' -Phase 'build'
        if ($found.found -and [int]$found.row.pid -gt 0 -and
                $null -ne (Get-Process -Id ([int]$found.row.pid) -ErrorAction SilentlyContinue)) {
            return $found.row
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $null
}

$testRoot = Join-Path $env:TEMP ("engine-dispatch-test-" + [guid]::NewGuid().ToString('N'))
$stateRoot = Join-Path $testRoot 'state'
$ledgerPath = Join-Path $stateRoot 'progress\codex-run-ledger.jsonl'
$repo1 = Join-Path $testRoot 'repo-one'
$repo2 = Join-Path $testRoot 'repo-two'
$repo3 = Join-Path $testRoot 'repo-live'
$repo4 = Join-Path $testRoot 'repo-dead'
$repo5 = Join-Path $testRoot 'repo-prelaunch'
$spec = 'dispatch-fixture'
$testMarker = Split-Path $testRoot -Leaf
$oldState = $env:APEX_STATE_DIR
$oldGitConfig = $env:GIT_CONFIG_GLOBAL
$oldFakeRepo = $env:FAKE_CODEX_REPO
$oldInScope = $env:FAKE_CODEX_INSCOPE_ONLY
$oldExtra = $env:FAKE_CODEX_EXTRA_WRITE
$oldArgv = $env:FAKE_CODEX_ARGV_FILE
$oldRealFake = $env:ENGINE_REAL_FAKE
$machineLedger = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'apex\progress\codex-run-ledger.jsonl' } else { $null }

try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    Write-TestText (Join-Path $testRoot 'gitconfig') ''
    $env:GIT_CONFIG_GLOBAL = Join-Path $testRoot 'gitconfig'
    $env:APEX_STATE_DIR = $stateRoot
    $base1 = New-TestRepo -Path $repo1 -Spec $spec
    $base2 = New-TestRepo -Path $repo2 -Spec $spec
    $base3 = New-TestRepo -Path $repo3 -Spec $spec
    $base4 = New-TestRepo -Path $repo4 -Spec $spec
    $base5 = New-TestRepo -Path $repo5 -Spec $spec
    $snapshot = Join-Path $stateRoot "$spec.md"
    Write-TestText $snapshot (New-TestSpecText $spec)
    $prefix = [string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeCodex)
    $common = @{
        Phase = 'build'; Spec = $spec; Task = '1'; BaseSha = $base1; SpecSourcePath = $snapshot
        Authorized = [string[]]@('src/a.py', 'src/two.py'); Effort = 'medium'; Model = 'gpt-5.6-sol'
        Prompt = "typed prompt with 'quotes', spaces, and`na second line"
        CodexExecutable = 'powershell.exe'; CodexExecutableArgumentPrefix = $prefix
        ScratchDirectory = (Join-Path $stateRoot 'scratch')
    }

    # Exercise the actual child JSON-to-splat bridge with and without the optional executable
    # overrides. The capture wrapper's own defaults stand in for the live wrapper defaults.
    $captureWrapper = Join-Path $testRoot 'capture-wrapper.ps1'
    Write-TestText $captureWrapper @'
[CmdletBinding()]
param(
    [string]$Phase, [string]$Spec, [string]$Task, [string]$Worktree, [string]$BaseSha,
    [string]$SpecSourcePath, [string[]]$Authorized, [string]$Effort, [string]$Model,
    [string]$Prompt, [string]$ScratchDirectory, [string]$CodexExecutable = 'codex',
    [AllowEmptyCollection()][string[]]$CodexExecutableArgumentPrefix = @()
)
[ordered]@{
    has_executable = $PSBoundParameters.ContainsKey('CodexExecutable')
    has_prefix = $PSBoundParameters.ContainsKey('CodexExecutableArgumentPrefix')
    executable = $CodexExecutable
    prefix = [string[]]@($CodexExecutableArgumentPrefix)
    prefix_type = $CodexExecutableArgumentPrefix.GetType().FullName
} | ConvertTo-Json -Compress
'@
    $defaultParameters = @{} + $common
    $defaultParameters.Worktree = $repo1
    $defaultParameters.Remove('CodexExecutable')
    $defaultParameters.Remove('CodexExecutableArgumentPrefix')
    $defaultArgs = Join-Path $stateRoot 'args\defaults.json'
    $defaultOutput = Join-Path $stateRoot 'children\defaults.out'
    Write-EngineDispatchArgs $defaultArgs $defaultParameters | Out-Null
    $defaultJson = Get-Content $defaultArgs -Raw | ConvertFrom-Json
    $defaultChild = Start-EngineDispatch $captureWrapper $defaultArgs $defaultOutput $stateRoot
    $defaultHandle = $script:EngineDispatchProcesses[$defaultChild.pid]
    $defaultCompleted = $defaultHandle.WaitForExit(10000)
    if ($defaultCompleted) { $script:EngineDispatchProcesses.Remove($defaultChild.pid) }
    $defaultCapture = if ($defaultCompleted) { Get-Content $defaultOutput -Raw | ConvertFrom-Json } else { $null }
    Assert-EngineCase 'optional executable keys omitted from JSON and child splat' `
        ($defaultCompleted -and
            @($defaultJson.PSObject.Properties.Name) -cnotcontains 'CodexExecutable' -and
            @($defaultJson.PSObject.Properties.Name) -cnotcontains 'CodexExecutableArgumentPrefix' -and
            -not $defaultCapture.has_executable -and -not $defaultCapture.has_prefix -and
            $defaultCapture.executable -ceq 'codex' -and @($defaultCapture.prefix).Count -eq 0) `
        'optional executable overrides were serialized or bound instead of using wrapper defaults'

    $typedCaptureArgs = Join-Path $stateRoot 'args\typed-capture.json'
    $typedCaptureOutput = Join-Path $stateRoot 'children\typed-capture.out'
    $typedParameters = @{} + $defaultParameters
    $typedParameters.CodexExecutable = 'powershell.exe'
    $typedParameters.CodexExecutableArgumentPrefix = $prefix
    Write-EngineDispatchArgs $typedCaptureArgs $typedParameters | Out-Null
    $typedCaptureChild = Start-EngineDispatch $captureWrapper $typedCaptureArgs $typedCaptureOutput $stateRoot
    $typedCaptureHandle = $script:EngineDispatchProcesses[$typedCaptureChild.pid]
    $typedCaptureCompleted = $typedCaptureHandle.WaitForExit(10000)
    if ($typedCaptureCompleted) { $script:EngineDispatchProcesses.Remove($typedCaptureChild.pid) }
    $typedCapture = if ($typedCaptureCompleted) { Get-Content $typedCaptureOutput -Raw | ConvertFrom-Json } else { $null }
    Assert-EngineCase 'optional executable keys reach child splat as typed values' `
        ($typedCaptureCompleted -and $typedCapture.has_executable -and $typedCapture.has_prefix -and
            $typedCapture.executable -ceq 'powershell.exe' -and
            @($typedCapture.prefix).Count -eq $prefix.Count -and
            $typedCapture.prefix_type -ceq 'System.String[]') `
        'explicit executable or string-array prefix lost its value/type in the child splat'

    $sleepWrapper = Join-Path $testRoot 'sleep-wrapper.ps1'
    Write-TestText $sleepWrapper @'
param(
    [string]$Phase, [string]$Spec, [string]$Task, [string]$Worktree, [string]$BaseSha,
    [string]$SpecSourcePath, [string[]]$Authorized, [string]$Effort, [string]$Model,
    [string]$Prompt, [string]$ScratchDirectory, [int]$SleepSeconds
)
Start-Sleep -Seconds $SleepSeconds
'@
    $sleepParameters = @{} + $defaultParameters
    $sleepParameters.SleepSeconds = 10
    $sleepArgs = Join-Path $stateRoot 'args\sleep.json'
    $sleepOutput = Join-Path $stateRoot 'children\sleep.out'
    Write-EngineDispatchArgs $sleepArgs $sleepParameters | Out-Null
    $sleepChild = Start-EngineDispatch $sleepWrapper $sleepArgs $sleepOutput $stateRoot
    $waitClock = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = Wait-EngineDispatch $sleepChild.pid $sleepOutput $ledgerPath -MaxWaitSeconds 1
    $waitClock.Stop()
    Assert-EngineCase 'fresh child wait obeys configurable four-hour cap' `
        ($timedOut.exit_code -eq -1 -and $timedOut.diagnosis -match 'cap; attempt must be parked' -and
            $waitClock.Elapsed.TotalSeconds -lt 5) `
        "exit=$($timedOut.exit_code), elapsed=$($waitClock.Elapsed.TotalSeconds), diagnosis=$($timedOut.diagnosis)"
    $sleepHandle = $script:EngineDispatchProcesses[$sleepChild.pid]
    if ($null -ne $sleepHandle -and -not $sleepHandle.HasExited) { $sleepHandle.Kill(); $sleepHandle.WaitForExit() }
    $script:EngineDispatchProcesses.Remove($sleepChild.pid)

    $adoptSleepWrapper = Join-Path $testRoot 'adopt-sleep-wrapper.ps1'
    Write-TestText $adoptSleepWrapper @'
[CmdletBinding()]
param(
    [switch]$Adopt, [string]$RunId, [string]$Spec, [string]$Task,
    [string]$Worktree, [string]$Phase
)
[System.IO.File]::WriteAllText((Join-Path $Worktree 'adopt-child.pid'), [string]$PID)
Start-Sleep -Seconds 20
'@
    $adoptPidPath = Join-Path $repo5 'adopt-child.pid'
    $adoptTimedOut = Invoke-EngineAdopt -WrapperPath $adoptSleepWrapper `
        -RunId 'dddddddddddddddddddddddddddddddd' -Spec $spec -Task '1' -Worktree $repo5 `
        -StateRoot $stateRoot -ChildOutputPath (Join-Path $stateRoot 'children\adopt-timeout.out') `
        -AdoptWaitSeconds 1
    $adoptPid = if (Test-Path -LiteralPath $adoptPidPath) { [int](Get-Content $adoptPidPath -Raw) } else { 0 }
    Assert-EngineCase 'adopt wait has its own timeout and kills its child' `
        ($adoptTimedOut.exit_code -eq -1 -and
            $adoptTimedOut.diagnosis -match '1-second adopt cap' -and
            $adoptTimedOut.diagnosis -match 'was killed' -and
            $adoptPid -gt 0 -and
            $null -eq (Get-Process -Id $adoptPid -ErrorAction SilentlyContinue) -and
            -not $script:EngineDispatchProcesses.ContainsKey($adoptPid)) `
        "pid=$adoptPid; exit=$($adoptTimedOut.exit_code); diagnosis=$($adoptTimedOut.diagnosis)"

    $args1 = Join-Path $stateRoot 'args\one.json'
    $args2 = Join-Path $stateRoot 'args\two.json'
    $output1 = Join-Path $stateRoot 'children\one.out'
    $output2 = Join-Path $stateRoot 'children\two.out'
    $argv1 = Join-Path $stateRoot 'children\one.argv'
    $argv2 = Join-Path $stateRoot 'children\two.argv'
    $p1 = @{} + $common; $p1.Worktree = $repo1
    $p2 = @{} + $common; $p2.Worktree = $repo2; $p2.BaseSha = $base2
    $written1 = Write-EngineDispatchArgs -ArgsPath $args1 -Parameters $p1
    $written2 = Write-EngineDispatchArgs -ArgsPath $args2 -Parameters $p2
    $roundTrip = Get-Content $written1.args_path -Raw | ConvertFrom-Json
    Assert-EngineCase 'JSON typed-array two-path dispatch' `
        ($roundTrip.Authorized -is [System.Array] -and @($roundTrip.Authorized).Count -eq 2 -and
            $roundTrip.CodexExecutableArgumentPrefix -is [System.Array] -and
            @($roundTrip.CodexExecutableArgumentPrefix).Count -eq 5) `
        'Authorized or executable prefix lost array shape'

    $env:FAKE_CODEX_INSCOPE_ONLY = '1'; $env:FAKE_CODEX_EXTRA_WRITE = 'src/two.py'
    $env:FAKE_CODEX_REPO = $repo1; $env:FAKE_CODEX_ARGV_FILE = $argv1
    $child1 = Start-EngineDispatch -WrapperPath $wrapper -ArgsPath $args1 -ChildOutputPath $output1 -StateRoot $stateRoot
    $env:FAKE_CODEX_REPO = $repo2; $env:FAKE_CODEX_ARGV_FILE = $argv2
    $child2 = Start-EngineDispatch -WrapperPath $wrapper -ArgsPath $args2 -ChildOutputPath $output2 -StateRoot $stateRoot
    Assert-EngineCase 'concurrent child launch' ($child1.pid -ne $child2.pid -and
        $script:EngineDispatchProcesses.ContainsKey($child1.pid) -and
        $script:EngineDispatchProcesses.ContainsKey($child2.pid)) 'both wave children were not live handles before the first wait'

    $result1 = Wait-EngineDispatch -ChildPid $child1.pid -ChildOutputPath $child1.child_output_path -LedgerPath $ledgerPath
    $result2 = Wait-EngineDispatch -ChildPid $child2.pid -ChildOutputPath $child2.child_output_path -LedgerPath $ledgerPath
    Assert-EngineCase 'ChildPid wait and printed-event read' `
        ($result1.exit_code -eq 0 -and -not $result1.diagnosis -and
            $result1.event.kind -ceq 'dispatch_result' -and $result2.exit_code -eq 0 -and
            -not $result2.diagnosis) "one=$($result1.exit_code)/$($result1.diagnosis): $((Get-Content $output1 -Raw -ErrorAction SilentlyContinue)); two=$($result2.exit_code)/$($result2.diagnosis): $((Get-Content $output2 -Raw -ErrorAction SilentlyContinue))"
    Assert-EngineCase 'typed prefix reached fake Codex' `
        ((Test-Path $argv1) -and (Test-Path $argv2) -and
            (Get-Content $argv1 -Raw) -match '--output-schema') 'fake Codex did not receive the typed executable prefix invocation'
    Assert-EngineCase 'two authorized paths round trip through real wrapper' `
        ((Get-Content (Join-Path $repo1 'src\a.py') -Raw) -match 'codex authorized change' -and
            (Test-Path (Join-Path $repo1 'src\two.py')) -and
            (Get-Content (Join-Path $repo2 'src\a.py') -Raw) -match 'codex authorized change' -and
            (Test-Path (Join-Path $repo2 'src\two.py'))) 'one or more authorized writes did not survive scope enforcement'

    $found = Find-EngineDispatchRow -LedgerPath $ledgerPath -Worktree $repo1 -Spec $spec -Task '1' -Phase 'build'
    Assert-EngineCase 'ledger lookup exact worktree spec task phase' `
        ($found.found -and [string]$found.row.run_id -ceq [string]$result1.wrapper_run_id) 'newest exact dispatch row was not selected'
    $missingPhaseRow = [ordered]@{
        row_kind = 'dispatch'; run_id = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
        worktree = $repo1; spec = $spec; task = '1'; status = 'running'
    }
    [System.IO.File]::AppendAllText($ledgerPath,
        (($missingPhaseRow | ConvertTo-Json -Compress) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false))
    $missingPhaseSkipped = $false
    try {
        $afterMissingPhase = Find-EngineDispatchRow -LedgerPath $ledgerPath -Worktree $repo1 `
            -Spec $spec -Task '1' -Phase 'build'
        $missingPhaseSkipped = ($afterMissingPhase.found -and
            [string]$afterMissingPhase.row.run_id -ceq [string]$result1.wrapper_run_id)
    } catch { $missingPhaseSkipped = $false }
    Assert-EngineCase 'ledger row missing phase is skipped under strict mode' $missingPhaseSkipped `
        'a malformed row threw or displaced the newest complete matching row'

    # A row exists before the wrapper has launched Codex and filled in pid/pid_start. Its verified
    # launcher identity is authoritative during that window, and -Adopt must report it as live.
    $prelaunchRunId = 'ffffffffffffffffffffffffffffffff'
    $prelaunchStamp = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    $prelaunchRow = [ordered]@{
        row_kind = 'dispatch'; run_id = $prelaunchRunId; worktree = $repo5; spec = $spec
        task = '1'; phase = 'build'; status = 'running'; started = (Get-Date).ToUniversalTime().ToString('o')
        launcher_pid = $PID; launcher_start = $prelaunchStamp; pid = $null; pid_start = $null
        final_path = (Join-Path $stateRoot 'prelaunch.final.md')
    }
    [System.IO.File]::AppendAllText($ledgerPath,
        (($prelaunchRow | ConvertTo-Json -Compress) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false))
    $script:EngineDispatchPollSeconds = 1; $script:EngineDispatchMaxWaitSeconds = 1
    $prelaunchResult = Wait-EngineLiveRow -WrapperPath $wrapper -Row ([pscustomobject]$prelaunchRow) `
        -Spec $spec -Task '1' -Worktree $repo5 -StateRoot $stateRoot `
        -ChildOutputPath (Join-Path $stateRoot 'children\prelaunch-adopt.out') `
        -WaitStartedAt ((Get-Date).ToUniversalTime().AddSeconds(-2)) -AdoptWaitSeconds 30
    Assert-EngineCase 'pre-launch null PID remains live through verified launcher' `
        ($prelaunchResult.status -ceq 'parked' -and $prelaunchResult.result.exit_code -eq 75 -and
            $prelaunchResult.result.event.detail -match 'remains live' -and
            $prelaunchResult.diagnosis -notmatch 'dead') `
        "$($prelaunchResult.status): $($prelaunchResult.diagnosis); result=$($prelaunchResult.result.diagnosis)"
    $script:EngineDispatchMaxWaitSeconds = 30

    $explicitTable = @(
        @{ E = 0; S = 'done' }, @{ E = 0; S = 'success' }, @{ E = 0; S = 'adopted-done+scope2' },
        @{ E = 68; S = 'done_with_concerns' }, @{ E = 68; S = 'adopted-done_with_concerns+scope1' },
        @{ E = 67; S = 'blocked' }, @{ E = 67; S = 'adopted-blocked' }, @{ E = 67; S = 'adopted-void+scope3' },
        @{ E = 69; S = 'done' }, @{ E = 69; S = 'done_with_concerns' }, @{ E = 69; S = 'adopted-void' },
        @{ E = 1; S = 'failed' }, @{ E = 1; S = 'done' }, @{ E = 1; S = 'done_with_concerns' },
        @{ E = 65; S = 'done' }, @{ E = 66; S = 'done_with_concerns' }, @{ E = 73; S = 'failed' }, @{ E = 77; S = 'failed' }
    )
    $tableOk = $true
    foreach ($pair in $explicitTable) { if (-not (Test-EngineTerminalStatus $pair.E $pair.S)) { $tableOk = $false } }
    if (Test-EngineTerminalStatus 0 'failed') { $tableOk = $false }
    if (Test-EngineTerminalStatus 68 'done') { $tableOk = $false }
    Assert-EngineCase 'explicit exit/status table including adopted suffixes' $tableOk 'an allowed status was rejected or a disallowed status was accepted'

    if (-not $result1.event_path) { throw 'successful fixture did not produce an event path; see preceding failure' }
    $eventRaw = [System.IO.File]::ReadAllText($result1.event_path)
    $eventObject = $eventRaw | ConvertFrom-Json
    $eventObject.task_id = 'wrong-task'
    Write-TestText $result1.event_path ($eventObject | ConvertTo-Json -Depth 20)
    $badContext = Read-EngineDispatchEvent -ChildOutputPath $output1 -ExitCode 0 -TaskId '1' -Worktree $repo1 -LedgerPath $ledgerPath
    Assert-EngineCase 'mismatched generated event rejected' (-not $badContext.ok) $badContext.diagnosis
    Write-TestText $result1.event_path $eventRaw
    $eventObject = $eventRaw | ConvertFrom-Json
    $eventObject.PSObject.Properties.Remove('status')
    Write-TestText $result1.event_path ($eventObject | ConvertTo-Json -Depth 20)
    $badShape = Read-EngineDispatchEvent -ChildOutputPath $output1 -ExitCode 0 -TaskId '1' -Worktree $repo1 -LedgerPath $ledgerPath
    Assert-EngineCase 'dispatch_result schema definition required keys' (-not $badShape.ok -and $badShape.diagnosis -match 'required key') $badShape.diagnosis
    Write-TestText $result1.event_path $eventRaw
    $badExit = Read-EngineDispatchEvent -ChildOutputPath $output1 -ExitCode 68 -TaskId '1' -Worktree $repo1 -LedgerPath $ledgerPath
    Assert-EngineCase 'schema and process-exit correlation' (-not $badExit.ok -and $badExit.diagnosis -match 'process exit') $badExit.diagnosis

    # Produce a refusal through the real wrapper (not a handwritten event), then validate and mutate it.
    $refusalArgs = Join-Path $stateRoot 'args\refusal.json'
    $refusalOutput = Join-Path $stateRoot 'children\refusal.out'
    $refusalParameters = [ordered]@{
        Phase = 'build'; Spec = $spec; Task = '1'; Worktree = $repo1; BaseSha = $base1
        SpecSourcePath = $snapshot; Effort = 'medium'; Model = 'gpt-5.6-sol'; Prompt = 'refusal fixture'
        CodexExecutable = 'powershell.exe'; CodexExecutableArgumentPrefix = $prefix
        ScratchDirectory = (Join-Path $stateRoot 'scratch')
    }
    Write-TestText $refusalArgs ($refusalParameters | ConvertTo-Json -Depth 20)
    $refusalChild = Start-EngineDispatch -WrapperPath $wrapper -ArgsPath $refusalArgs `
        -ChildOutputPath $refusalOutput -StateRoot $stateRoot
    $refusalResult = Wait-EngineDispatch -ChildPid $refusalChild.pid -ChildOutputPath $refusalOutput -LedgerPath $ledgerPath
    $refusalRead = Read-EngineDispatchEvent -ChildOutputPath $refusalOutput -ExitCode $refusalResult.exit_code `
        -TaskId '1' -Worktree $repo1 -LedgerPath $ledgerPath
    Assert-EngineCase 'refusal schema definition selected by kind' `
        ($refusalResult.exit_code -eq 74 -and $refusalRead.ok -and $refusalRead.event.kind -ceq 'refusal') `
        "exit=$($refusalResult.exit_code); $($refusalRead.diagnosis)"
    if ($refusalRead.event_path) {
        $refusalRaw = [System.IO.File]::ReadAllText($refusalRead.event_path)
        $refusalObject = $refusalRaw | ConvertFrom-Json
        $refusalObject.run_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        Write-TestText $refusalRead.event_path ($refusalObject | ConvertTo-Json -Depth 20)
        $badConditional = Read-EngineDispatchEvent -ChildOutputPath $refusalOutput -ExitCode 74 `
            -TaskId '1' -Worktree $repo1 -LedgerPath $ledgerPath
        Assert-EngineCase 'refusal per-exit conditional correlation' `
            (-not $badConditional.ok -and $badConditional.diagnosis -match 'null run_id') $badConditional.diagnosis
        Write-TestText $refusalRead.event_path $refusalRaw

        foreach ($refusalCode in @(71, 72, 74, 76, 79, 81, 83)) {
            $wrongTaskRefusal = $refusalRaw | ConvertFrom-Json
            $wrongTaskRefusal.exit_code = $refusalCode
            $wrongTaskRefusal.task_id = 'wrong-task'
            Write-TestText $refusalRead.event_path ($wrongTaskRefusal | ConvertTo-Json -Depth 20)
            $wrongTaskRead = Read-EngineDispatchEvent -ChildOutputPath $refusalOutput `
                -ExitCode $refusalCode -TaskId '1' -Worktree $repo1 -LedgerPath $ledgerPath
            Assert-EngineCase "null-run-id refusal exit $refusalCode rejects another task context" `
                (-not $wrongTaskRead.ok -and $wrongTaskRead.diagnosis -match 'task.*dispatch context') `
                $wrongTaskRead.diagnosis

            $wrongRepoRefusal = $refusalRaw | ConvertFrom-Json
            $wrongRepoRefusal.exit_code = $refusalCode
            $wrongRepoRefusal.repo = $repo2
            Write-TestText $refusalRead.event_path ($wrongRepoRefusal | ConvertTo-Json -Depth 20)
            $wrongRepoRead = Read-EngineDispatchEvent -ChildOutputPath $refusalOutput `
                -ExitCode $refusalCode -TaskId '1' -Worktree $repo1 -LedgerPath $ledgerPath
            Assert-EngineCase "null-run-id refusal exit $refusalCode rejects another repo context" `
                (-not $wrongRepoRead.ok -and $wrongRepoRead.diagnosis -match 'repo.*dispatch worktree') `
                $wrongRepoRead.diagnosis
        }
        Write-TestText $refusalRead.event_path $refusalRaw

        # These codes name an existing ledger row, but 80 specifically names another task's
        # BLOCKING row. A refusal therefore correlates only the schema's run_id rule, never the
        # selected row's task/worktree identity.
        foreach ($refusalCode in @(75, 80, 124)) {
            $fixture = $refusalRaw | ConvertFrom-Json
            $fixture.exit_code = $refusalCode
            $fixture.run_id = [string]$result1.wrapper_run_id
            $fixture.task_id = 'blocking-other-task'
            $fixture.repo = $repo2
            $fixture.rule = $null
            $fixture.detail = if ($refusalCode -eq 75) {
                "run_id '$($fixture.run_id)' remains live"
            } elseif ($refusalCode -eq 80) {
                "worktree has unresolved run_id=$($fixture.run_id)"
            } else {
                "run_id '$($fixture.run_id)' produced no output and remains live"
            }
            $fixture.synthesized = ($refusalCode -in @(75, 124))
            $fixturePath = Join-Path $stateRoot "events\$($fixture.run_id)-review-$refusalCode.event.json"
            $fixtureOutput = Join-Path $stateRoot "children\refusal-$refusalCode.out"
            Write-TestText $fixturePath ($fixture | ConvertTo-Json -Depth 20)
            Write-TestText $fixtureOutput ("[event] $fixturePath" + [Environment]::NewLine)
            if ($refusalCode -eq 75) {
                Write-TestText "$fixtureOutput.invocation.json" '{"adopt":true}'
            }
            $fixtureRead = Read-EngineDispatchEvent -ChildOutputPath $fixtureOutput `
                -ExitCode $refusalCode -TaskId '1' -Worktree $repo1 -LedgerPath $ledgerPath
            Assert-EngineCase "refusal exit $refusalCode uses ledger-id rule without task/repo equality" `
                ($fixtureRead.ok -and $fixtureRead.wrapper_run_id -ceq [string]$result1.wrapper_run_id) `
                $fixtureRead.diagnosis
        }
    }

    # A slow fake creates a genuinely live wrapper row. Wait-EngineLiveRow must observe a real
    # exit-75 refusal, poll final_path, and re-adopt the same run to a terminal real event.
    $slowFake = Join-Path $testRoot 'slow-fake.ps1'
    Write-TestText $slowFake @'
$pass = $args
$prompt = [Console]::In.ReadToEnd()
Start-Sleep -Seconds ([int]$env:ENGINE_FAKE_DELAY)
$prompt | & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $env:ENGINE_REAL_FAKE @pass
exit $LASTEXITCODE
'@
    $env:ENGINE_REAL_FAKE = $fakeCodex
    $env:ENGINE_FAKE_DELAY = '10'
    $env:FAKE_CODEX_REPO = $repo3; $env:FAKE_CODEX_ARGV_FILE = ''
    $slowParameters = @{} + $common
    $slowParameters.Worktree = $repo3; $slowParameters.BaseSha = $base3
    $slowParameters.CodexExecutableArgumentPrefix = [string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $slowFake)
    $slowArgs = Join-Path $stateRoot 'args\slow.json'
    $slowOutput = Join-Path $stateRoot 'children\slow.out'
    Write-EngineDispatchArgs $slowArgs $slowParameters | Out-Null
    $slowChild = Start-EngineDispatch $wrapper $slowArgs $slowOutput $stateRoot
    $slowRow = Wait-TestRow $ledgerPath $repo3 $spec
    Assert-EngineCase 'live adoption row discovered' ($null -ne $slowRow -and [string]$slowRow.status -in @('running', 'stalled')) 'no live row appeared'
    if ($null -ne $slowRow) {
        $script:EngineDispatchPollSeconds = 1; $script:EngineDispatchMaxWaitSeconds = 30
        $liveResult = Wait-EngineLiveRow -WrapperPath $wrapper -Row $slowRow -Spec $spec -Task '1' `
            -Worktree $repo3 -StateRoot $stateRoot -ChildOutputPath (Join-Path $stateRoot 'children\live-adopt.out') `
            -WaitStartedAt (Get-Date).ToUniversalTime()
        Assert-EngineCase 'live PID exit-75 poll and re-adopt' `
            ($liveResult.status -ceq 'terminal' -and $liveResult.result.exit_code -eq 0 -and
                -not $liveResult.result.diagnosis) "$($liveResult.status): $($liveResult.diagnosis); result=$($liveResult.result.diagnosis)"
    }
    $null = Wait-EngineDispatch $slowChild.pid $slowOutput $ledgerPath

    # Repeat with a killed real fake-Codex PID. The adapter must re-adopt once and return a failed
    # attempt rather than mistaking a dead row without .final for a live wait.
    $env:ENGINE_FAKE_DELAY = '20'
    $env:FAKE_CODEX_REPO = $repo4
    $deadParameters = @{} + $slowParameters
    $deadParameters.Worktree = $repo4; $deadParameters.BaseSha = $base4
    $deadArgs = Join-Path $stateRoot 'args\dead.json'
    $deadOutput = Join-Path $stateRoot 'children\dead.out'
    Write-EngineDispatchArgs $deadArgs $deadParameters | Out-Null
    $deadChild = Start-EngineDispatch $wrapper $deadArgs $deadOutput $stateRoot
    $deadRow = Wait-TestRow $ledgerPath $repo4 $spec
    if ($null -ne $deadRow -and [int]$deadRow.pid -gt 0) {
        Stop-Process -Id ([int]$deadRow.pid) -Force -ErrorAction SilentlyContinue
        for ($i = 0; $i -lt 30 -and (Get-Process -Id ([int]$deadRow.pid) -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 100 }
        $deadResult = Wait-EngineLiveRow -WrapperPath $wrapper -Row $deadRow -Spec $spec -Task '1' `
            -Worktree $repo4 -StateRoot $stateRoot -ChildOutputPath (Join-Path $stateRoot 'children\dead-adopt.out') `
            -WaitStartedAt (Get-Date).ToUniversalTime()
        Assert-EngineCase 'dead PID without final re-adopts as failed attempt' `
            ($deadResult.status -ceq 'failed' -and $deadResult.diagnosis -match 'dead') `
            "$($deadResult.status): $($deadResult.diagnosis)"
    } else {
        Assert-EngineCase 'dead PID without final re-adopts as failed attempt' $false 'no live row/PID appeared'
    }
    $null = Wait-EngineDispatch $deadChild.pid $deadOutput $ledgerPath

    $machineMarkerFound = $false
    if ($machineLedger -and (Test-Path -LiteralPath $machineLedger -PathType Leaf)) {
        $machineMutex = [System.Threading.Mutex]::new($false, 'ApexCodexRunLedger')
        $machineMutexAcquired = $false
        try {
            try { $machineMutexAcquired = $machineMutex.WaitOne([TimeSpan]::FromSeconds(30)) }
            catch [System.Threading.AbandonedMutexException] { $machineMutexAcquired = $true }
            if (-not $machineMutexAcquired) { throw 'Timed out waiting to inspect the machine ledger.' }
            foreach ($machineLine in [System.IO.File]::ReadAllLines($machineLedger)) {
                if ($machineLine.Contains($testMarker)) { $machineMarkerFound = $true; break }
            }
        } finally {
            if ($machineMutexAcquired) { $machineMutex.ReleaseMutex() }
            $machineMutex.Dispose()
        }
    }
    Assert-EngineCase 'machine-ledger isolation' (-not $machineMarkerFound) `
        "the default machine ledger contains this test's unique marker '$testMarker'"
} catch {
    $script:failures++
    Write-Host "FAIL: unexpected exception -- $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
} finally {
    $env:APEX_STATE_DIR = $oldState
    $env:GIT_CONFIG_GLOBAL = $oldGitConfig
    $env:FAKE_CODEX_REPO = $oldFakeRepo
    $env:FAKE_CODEX_INSCOPE_ONLY = $oldInScope
    $env:FAKE_CODEX_EXTRA_WRITE = $oldExtra
    $env:FAKE_CODEX_ARGV_FILE = $oldArgv
    $env:ENGINE_REAL_FAKE = $oldRealFake
    Remove-Item Env:ENGINE_FAKE_DELAY -ErrorAction SilentlyContinue
    if ($testRoot -and (Test-Path -LiteralPath $testRoot) -and
            (Get-EngineFullPath $testRoot).StartsWith((Get-EngineFullPath $env:TEMP), [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:failures -gt 0) {
    Write-Host "engine-dispatch-test: $script:failures failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host 'engine-dispatch-test: all cases passed' -ForegroundColor Green
exit 0
