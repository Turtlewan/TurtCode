# Loud-fail end-to-end coverage for codex-dispatch.ps1's build pre-flight.
# Every fixture repository and every harness artifact lives under one fresh temp root,
# while APEX_STATE_DIR is a sibling of (and therefore outside) all fixture repositories.

$ErrorActionPreference = 'Stop'

$dispatch = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
$fakeCodex = Join-Path $PSScriptRoot 'dispatch-test-fakecodex.ps1'
foreach ($required in @($dispatch, $fakeCodex)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required test dependency not found: $required"
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("apex-dispatch-preflight-test-" + [guid]::NewGuid().ToString('N'))
$repoRoot = Join-Path $testRoot 'repos'
$stateRoot = Join-Path $testRoot 'state'
$scratchRoot = Join-Path $stateRoot 'scratch'
$ledgerPath = Join-Path (Join-Path $stateRoot 'progress') 'codex-run-ledger.jsonl'
$gatesRoot = Join-Path $stateRoot 'gates'

$oldApexStateDir = $env:APEX_STATE_DIR
$oldFakeRepo = $env:FAKE_CODEX_REPO
$oldFakeInScopeOnly = $env:FAKE_CODEX_INSCOPE_ONLY
$oldFakeStatus = $env:FAKE_CODEX_STATUS
$oldFakeNoReport = $env:FAKE_CODEX_NO_REPORT
$oldFakeVerdict = $env:FAKE_CODEX_VERDICT
$faultDispatch = $null

$script:failureCount = 0
$script:assertionCount = 0

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path $Path -Parent
    if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Set-OptionalEnvironmentValue {
    param([Parameter(Mandatory)][string]$Name, [AllowNull()][string]$Value)

    if ($null -eq $Value) {
        Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
    }
    else {
        Set-Item -LiteralPath "Env:$Name" -Value $Value
    }
}

function Invoke-FixtureGit {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string[]]$GitArguments
    )

    # This host can emit a non-fatal inaccessible-global-ignore warning on stderr.
    # Capture it, but judge the fixture operation by Git's exit code.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $gitOutput = @(& git -C $Repo @GitArguments 2>&1)
        $gitExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($gitExitCode -ne 0) {
        throw "git -C $Repo $($GitArguments -join ' ') failed: $($gitOutput -join [Environment]::NewLine)"
    }
    return $gitOutput
}

function New-FixtureRepo {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][string]$AgentsContent,
        [hashtable]$ExtraFiles = @{}
    )

    $repo = Join-Path $repoRoot $Name
    [System.IO.Directory]::CreateDirectory((Join-Path $repo 'src')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $repo 'docs')) | Out-Null
    Write-Utf8NoBom -Path (Join-Path $repo 'src\a.py') -Content "original`n"
    Write-Utf8NoBom -Path (Join-Path $repo 'src\b.py') -Content "original`n"
    Write-Utf8NoBom -Path (Join-Path $repo 'docs\status.md') -Content "fixture state`n"
    if (-not [string]::IsNullOrEmpty($AgentsContent)) {
        Write-Utf8NoBom -Path (Join-Path $repo 'AGENTS.md') -Content $AgentsContent
    }
    foreach ($entry in $ExtraFiles.GetEnumerator()) {
        Write-Utf8NoBom -Path (Join-Path $repo $entry.Key) -Content ([string]$entry.Value)
    }

    Invoke-FixtureGit -Repo $repo -GitArguments @('init', '-q') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('config', 'user.email', 'dispatch-preflight-test@example.invalid') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('config', 'user.name', 'dispatch-preflight-test') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('add', '-A') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('commit', '-q', '-m', 'fixture') | Out-Null
    return $repo
}

function Get-FixtureHead {
    param([Parameter(Mandatory)][string]$Repo)

    $head = @(Invoke-FixtureGit -Repo $Repo -GitArguments @('rev-parse', 'HEAD'))
    return ([string]$head[0]).Trim()
}

function New-UniqueSpec {
    param([Parameter(Mandatory)][string]$CaseName)

    return ("preflight-{0}-{1}" -f $CaseName, [guid]::NewGuid().ToString('N'))
}

function New-GreenFixtureSpec {
    param(
        [Parameter(Mandatory)][string]$Spec,
        [int]$MaxParallelCodex = 0,
        [AllowNull()][string]$AdditionalFrontmatter
    )

    $maxParallelLine = if ($MaxParallelCodex -gt 0) {
        "max_parallel_codex: $MaxParallelCodex`n"
    } else { '' }
    $additionalFrontmatterLines = if ([string]::IsNullOrEmpty($AdditionalFrontmatter)) {
        ''
    }
    else {
        $AdditionalFrontmatter.TrimEnd("`r", "`n") + "`n"
    }
    return @"
---
spec: $Spec
status: draft
autonomy_level: L2
$maxParallelLine$additionalFrontmatterLines---
# Spec: fixture placeholder
## Intent
- Intent: fixture spec to satisfy pre-flight validation.
## Assumptions
- none -> impact: Low
## Prerequisites
- none
## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| src/a.py | modify | placeholder |
## Tasks
- [ ] **Task 1:** placeholder change -- files: src/a.py -- done when: file present.
## Wave plan
Wave 1: [Task 1]
## Permissions
Approving this spec approves the file operation above.
## Specialist Context
### Security
(none)
## Documentation
(none)
## Acceptance Criteria
- [ ] **Task 1** -> verify: the placeholder change is present.
## Progress
_(coding writes here)_
"@
}

function Invoke-WithFixtureLedgerLock {
    param([Parameter(Mandatory)][scriptblock]$Action)

    # The wrapper rewrites this file atomically with File.Replace while holding this named mutex.
    # Fixture reads and mutations must join that protocol so they cannot hold a stale file handle or
    # overwrite a wrapper row while concurrent capacity holders are updating the shared ledger.
    $fixtureLedgerMutex = [System.Threading.Mutex]::new($false, 'ApexCodexRunLedger')
    $acquired = $false
    try {
        try {
            $acquired = $fixtureLedgerMutex.WaitOne([TimeSpan]::FromSeconds(30))
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) { throw 'Timed out waiting for the fixture run-ledger lock.' }
        & $Action
    }
    finally {
        if ($acquired) { $fixtureLedgerMutex.ReleaseMutex() }
        $fixtureLedgerMutex.Dispose()
    }
}

function Get-TestLedgerLines {
    $lines = @(Invoke-WithFixtureLedgerLock {
        if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { return }
        [System.IO.File]::ReadAllLines($ledgerPath)
    })
    return [string[]]$lines
}

function Get-LedgerRowsForSpec {
    param([Parameter(Mandatory)][string]$Spec)

    $matches = @()
    foreach ($line in (Get-TestLedgerLines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $row = $line | ConvertFrom-Json
        if ([string]$row.spec -eq $Spec) { $matches += $row }
    }
    return @($matches)
}

function Test-LeaseScopedRefusal {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][int]$ExitCode
    )

    $leaseRows = @($Result.Rows | Where-Object { [string]$_.row_kind -ceq 'lease' })
    if ($leaseRows.Count -ne 1) { return $false }
    $runId = [string]$leaseRows[0].run_id
    $runRows = @(
        foreach ($line in (Get-TestLedgerLines)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $line | ConvertFrom-Json
            if ([string]$row.run_id -ceq $runId) { $row }
        }
    )
    $dispatchRows = @($runRows | Where-Object { [string]$_.row_kind -ceq 'dispatch' })
    $closeRows = @($runRows | Where-Object { [string]$_.row_kind -ceq 'lease_close' })
    $logExists = Test-Path -LiteralPath ([string]$leaseRows[0].log_path) -PathType Leaf
    return ($dispatchRows.Count -eq 0 -and $closeRows.Count -eq 1 -and
        -not $logExists -and
        [string]$closeRows[0].status -ceq 'refused-preflight' -and
        [int]$closeRows[0].refusal_exit -eq $ExitCode)
}

function Test-UnknownLeaseClosure {
    param([Parameter(Mandatory)]$Result)

    $leaseRows = @($Result.Rows | Where-Object { [string]$_.row_kind -ceq 'lease' })
    if ($leaseRows.Count -ne 1) { return $false }
    $runId = [string]$leaseRows[0].run_id
    $runRows = @(
        foreach ($line in (Get-TestLedgerLines)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $line | ConvertFrom-Json
            if ([string]$row.run_id -ceq $runId) { $row }
        }
    )
    $dispatchRows = @($runRows | Where-Object { [string]$_.row_kind -ceq 'dispatch' })
    $closeRows = @($runRows | Where-Object { [string]$_.row_kind -ceq 'lease_close' })
    return ($dispatchRows.Count -eq 0 -and $closeRows.Count -eq 1 -and
        [string]$closeRows[0].status -ceq 'refused-preflight' -and
        [string]$closeRows[0].refusal_exit -ceq 'unknown')
}

function Add-TestLedgerRow {
    param([Parameter(Mandatory)][hashtable]$Row)

    Invoke-WithFixtureLedgerLock {
        [System.IO.File]::AppendAllText(
            $ledgerPath,
            ($Row | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
}

function Set-TestLedgerRowStatus {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Status
    )

    Invoke-WithFixtureLedgerLock {
        $updatedLines = foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $line | ConvertFrom-Json
            if ([string]$row.run_id -ceq $RunId) {
                $row | Add-Member -NotePropertyName status -NotePropertyValue $Status -Force
                $row | ConvertTo-Json -Compress -Depth 8
            }
            else {
                $line
            }
        }
        [System.IO.File]::WriteAllLines(
            $ledgerPath,
            $updatedLines,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
}

function Assert-Case {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Detail
    )

    $script:assertionCount++
    if ($Condition) {
        Write-Host ("PASS  {0} -- {1}" -f $Label, $Detail) -ForegroundColor Green
    }
    else {
        $script:failureCount++
        Write-Host ("FAIL  {0} -- {1}" -f $Label, $Detail) -ForegroundColor Red
    }
}

function Assert-PreflightPinCleaned {
    param(
        [Parameter(Mandatory)][string]$CaseName,
        [Parameter(Mandatory)][string]$Spec
    )

    $specSafe = $Spec -replace '[^A-Za-z0-9._-]', '_'
    $leftovers = @()
    if (Test-Path -LiteralPath $gatesRoot -PathType Container) {
        $leftovers = @(Get-ChildItem -LiteralPath $gatesRoot -Filter "apex-treepin-preflight-$specSafe-*" -File -ErrorAction SilentlyContinue)
    }
    Assert-Case -Label "$CaseName pin cleanup" -Condition ($leftovers.Count -eq 0) -Detail ("{0} preflight pin file(s) remain" -f $leftovers.Count)
}

function Assert-NoCodexLog {
    param(
        [Parameter(Mandatory)][string]$CaseName,
        [Parameter(Mandatory)][string]$Spec
    )

    $specSafe = $Spec -replace '[^A-Za-z0-9._-]', '_'
    $logDirectory = Join-Path (Split-Path $ledgerPath -Parent) 'codex-logs'
    $logs = @()
    if (Test-Path -LiteralPath $logDirectory -PathType Container) {
        $logs = @(Get-ChildItem -LiteralPath $logDirectory -Filter "codex-$specSafe-*" -File -ErrorAction SilentlyContinue)
    }
    Assert-Case -Label "$CaseName codex log" -Condition ($logs.Count -eq 0) -Detail ("{0} matching codex log file(s) found" -f $logs.Count)
}

function Invoke-DispatchCase {
    param(
        [Parameter(Mandatory)][string]$CaseName,
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$FakeRepo,
        [hashtable]$ExtraParameters = @{},
        [hashtable]$FakeEnvironment = @{},
        [switch]$CaptureInformationStream,
        [string]$DispatchPath = $dispatch
    )

    $parameters = @{
        Spec = $Spec
        Task = 'task-7'
        Phase = 'build'
        Worktree = $Repo
        BaseSha = (Get-FixtureHead -Repo $Repo)
        Prompt = "Task 7 pre-flight case: $CaseName"
        Authorized = @('src/a.py')
        ScratchDirectory = $scratchRoot
        CodexExecutable = 'powershell.exe'
        CodexExecutableArgumentPrefix = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeCodex)
    }
    foreach ($entry in $ExtraParameters.GetEnumerator()) {
        $parameters[$entry.Key] = $entry.Value
    }

    foreach ($name in @('FAKE_CODEX_INSCOPE_ONLY', 'FAKE_CODEX_STATUS', 'FAKE_CODEX_NO_REPORT', 'FAKE_CODEX_VERDICT')) {
        Set-OptionalEnvironmentValue -Name $name -Value $null
    }
    $env:FAKE_CODEX_REPO = $FakeRepo
    foreach ($entry in $FakeEnvironment.GetEnumerator()) {
        Set-OptionalEnvironmentValue -Name $entry.Key -Value ([string]$entry.Value)
    }

    Write-Host "`n===== CASE: $CaseName =====" -ForegroundColor Cyan
    if ($CaptureInformationStream) {
        $captured = @(& $DispatchPath @parameters 6>&1)
        $outputText = (@($captured | ForEach-Object {
            if ($_ -is [System.Management.Automation.InformationRecord]) {
                [string]$_.MessageData
            }
            else {
                [string]$_
            }
        }) -join [Environment]::NewLine)
    }
    else {
        $captured = @(& $DispatchPath @parameters *>&1)
        $outputText = (@($captured | ForEach-Object {
            if ($_ -is [System.Management.Automation.InformationRecord]) {
                [string]$_.MessageData
            }
            else {
                [string]$_
            }
        }) -join [Environment]::NewLine)
    }
    $exitCode = $LASTEXITCODE
    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
        Write-Host $outputText.TrimEnd()
    }
    Write-Host ("----- {0}: exit {1} -----" -f $CaseName, $exitCode) -ForegroundColor DarkCyan

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $outputText
        Rows = @(Get-LedgerRowsForSpec -Spec $Spec)
    }
}

function Start-HeldDispatch {
    param(
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$FakePath,
        [Parameter(Mandatory)][int]$MachineCeiling,
        [ValidateSet('medium', 'ultra')][string]$Effort = 'medium'
    )

    $baseSha = Get-FixtureHead -Repo $Repo
    return Start-Job -ScriptBlock {
        param($Dispatch, $StateRoot, $ScratchRoot, $Spec, $Repo, $BaseSha, $FakePath, $MachineCeiling, $Effort)
        $env:APEX_STATE_DIR = $StateRoot
        $captured = @(& $Dispatch -Spec $Spec -Task 'capacity-hold' -Phase 'build' -Worktree $Repo `
            -BaseSha $BaseSha -Prompt 'hold capacity' -Authorized @('src/a.py') -SkipBaselineCheck `
            -MachineCeiling $MachineCeiling -Effort $Effort -ScratchDirectory $ScratchRoot `
            -CodexExecutable 'powershell.exe' `
            -CodexExecutableArgumentPrefix @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FakePath) *>&1)
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($captured | Out-String) }
    } -ArgumentList $dispatch, $stateRoot, $scratchRoot, $Spec, $Repo, $baseSha, $FakePath, $MachineCeiling, $Effort
}

function Wait-ForOccupyingDispatches {
    param(
        [Parameter(Mandatory)][string[]]$Specs,
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $rows = @(
            foreach ($line in (Get-TestLedgerLines)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $row = $line | ConvertFrom-Json
                if ($Specs -ccontains [string]$row.spec -and
                        @('running', 'stalled', 'adopting') -ccontains [string]$row.status -and $row.pid) {
                    $row
                }
            }
        )
        $present = @($rows | ForEach-Object { [string]$_.spec } | Select-Object -Unique)
        if (@($Specs | Where-Object { $present -cnotcontains $_ }).Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $false
}

$greenRecipe = @'
## Verify commands

```
exit 0
```
'@

$redRecipe = @'
## Verify commands

```
exit 1
```
'@

$unparseableRecipe = @'
## Verify commands

This heading deliberately has no fenced command block.
'@

$movedTreeRecipe = @'
## Verify commands

```powershell
Add-Content -LiteralPath 'src/a.py' -Value 'baseline mutation'
```
'@

try {
    $capacityJobs = @()
    [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($scratchRoot) | Out-Null
    # Pre-create the empty isolated ledger so the wrapper cannot import any legacy ledger.
    Invoke-WithFixtureLedgerLock {
        [System.IO.Directory]::CreateDirectory((Split-Path $ledgerPath -Parent)) | Out-Null
        Write-Utf8NoBom -Path $ledgerPath -Content ''
    }
    $env:APEX_STATE_DIR = $stateRoot

    $spec = New-UniqueSpec -CaseName 'red'
    $repo = New-FixtureRepo -Name 'red' -AgentsContent $redRecipe `
        -ExtraFiles @{ "docs\changes\$spec.md" = (New-GreenFixtureSpec -Spec $spec) }
    $result = Invoke-DispatchCase -CaseName 'RED baseline' -Spec $spec -Repo $repo -FakeRepo $repo
    Assert-Case -Label 'RED baseline exit' -Condition ($result.ExitCode -eq 72) -Detail "expected 72, got $($result.ExitCode)"
    Assert-Case -Label 'RED baseline ledger' -Condition (Test-LeaseScopedRefusal -Result $result -ExitCode 72) -Detail 'one lease and one exit-72 close; no dispatch row'
    Assert-PreflightPinCleaned -CaseName 'RED baseline' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'unparseable'
    $repo = New-FixtureRepo -Name 'unparseable' -AgentsContent $unparseableRecipe `
        -ExtraFiles @{ "docs\changes\$spec.md" = (New-GreenFixtureSpec -Spec $spec) }
    $result = Invoke-DispatchCase -CaseName 'UNPARSEABLE recipe' -Spec $spec -Repo $repo -FakeRepo $repo
    Assert-Case -Label 'UNPARSEABLE exit' -Condition ($result.ExitCode -eq 72) -Detail "expected 72, got $($result.ExitCode)"
    Assert-Case -Label 'UNPARSEABLE ledger' -Condition (Test-LeaseScopedRefusal -Result $result -ExitCode 72) -Detail 'one lease and one exit-72 close; no dispatch row'
    Assert-PreflightPinCleaned -CaseName 'UNPARSEABLE' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'no-recipe'
    $repo = New-FixtureRepo -Name 'no-recipe' -AgentsContent $null `
        -ExtraFiles @{ "docs\changes\$spec.md" = (New-GreenFixtureSpec -Spec $spec) }
    $result = Invoke-DispatchCase -CaseName 'NO_RECIPE' -Spec $spec -Repo $repo -FakeRepo $repo
    Assert-Case -Label 'NO_RECIPE exit' -Condition ($result.ExitCode -eq 72) -Detail "expected 72, got $($result.ExitCode)"
    Assert-Case -Label 'NO_RECIPE ledger' -Condition (Test-LeaseScopedRefusal -Result $result -ExitCode 72) -Detail 'one lease and one exit-72 close; no dispatch row'
    Assert-PreflightPinCleaned -CaseName 'NO_RECIPE' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'validator-fail'
    $invalidSpec = @"
# Invalid fixture spec

## Intent
Exercise dispatch-side validation.
## Assumptions
None.
## Prerequisites
None.
## Files to Change
| File | Purpose |
|---|---|
| src/a.py | In-scope fixture file. |
## Tasks
- **Task 1** Implement fixture -- files: ``src/a.py``
## Wave plan
One wave.
## Permissions
Fixture-only writes.
## Specialist Context
None.
## Documentation
None.
## Acceptance Criteria
- [ ] Task 1 verifies ``src/missing.py`` even though it is absent from Files to Change.
## Progress
Not started.
"@
    $specRelativePath = "docs\changes\$spec.md"
    $repo = New-FixtureRepo -Name 'validator-fail' -AgentsContent $greenRecipe -ExtraFiles @{ $specRelativePath = $invalidSpec }
    $result = Invoke-DispatchCase -CaseName 'SPEC-VALIDATOR FAIL' -Spec $spec -Repo $repo -FakeRepo $repo
    Assert-Case -Label 'validator-fail exit' -Condition ($result.ExitCode -eq 72) -Detail "expected 72, got $($result.ExitCode)"
    Assert-Case -Label 'validator-fail ledger' -Condition (Test-LeaseScopedRefusal -Result $result -ExitCode 72) -Detail 'one lease and one exit-72 close; no dispatch row'
    Assert-Case -Label 'validator-fail evidence' -Condition ($result.Output -match 'FAIL FILES-COMPLETENESS') -Detail 'dispatcher printed the validator finding'
    Assert-Case -Label 'validator-fail precedes baseline' -Condition ($result.Output -notmatch '\[baseline\]') -Detail 'invalid spec was refused before any repository recipe ran'
    Assert-PreflightPinCleaned -CaseName 'validator-fail' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'runtime-force-track'
    $runtimePath = 'runtime/ignored-tool.bin'
    $runtimeSpec = New-GreenFixtureSpec -Spec $spec -AdditionalFrontmatter @"
declared_runtime_paths:
  - $runtimePath
"@
    $repo = New-FixtureRepo -Name 'runtime-force-track' -AgentsContent $greenRecipe -ExtraFiles @{
        '.gitignore' = "$runtimePath`n"
        ($runtimePath -replace '/', '\') = "ignored runtime tool`n"
        "docs\changes\$spec.md" = $runtimeSpec
    }
    $result = Invoke-DispatchCase -CaseName 'DECLARED runtime ignored' -Spec $spec -Repo $repo -FakeRepo $repo `
        -CaptureInformationStream
    Assert-Case -Label 'runtime ignored exits 81 cleanly' `
        -Condition ($result.ExitCode -eq 81) -Detail "expected 81, got $($result.ExitCode)"
    Assert-Case -Label 'runtime ignored lease-only refusal' `
        -Condition (Test-LeaseScopedRefusal -Result $result -ExitCode 81) `
        -Detail 'no dispatch row/log and exactly one refused-preflight refusal_exit=81 close'
    Assert-Case -Label 'runtime ignored diagnostic' `
        -Condition ($result.Output -match [regex]::Escape($runtimePath) -and
            $result.Output -match 'gitignored-invisible to worktrees' -and
            $result.Output -match 'ls-files exit 1; check-ignore exit 0') `
        -Detail 'offending path, reason, and both exit codes are printed'
    Assert-PreflightPinCleaned -CaseName 'runtime ignored' -Spec $spec

    Invoke-FixtureGit -Repo $repo -GitArguments @('add', '-f', '--', $runtimePath) | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('commit', '-q', '-m', 'force-track runtime path') | Out-Null
    $result = Invoke-DispatchCase -CaseName 'DECLARED runtime force-tracked' -Spec $spec -Repo $repo `
        -FakeRepo $repo -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $forceTrackedDispatchRows = @($result.Rows | Where-Object { [string]$_.row_kind -ceq 'dispatch' })
    Assert-Case -Label 'runtime force-tracked passes check' `
        -Condition ($result.ExitCode -eq 0 -and $forceTrackedDispatchRows.Count -eq 1) `
        -Detail "expected successful dispatch after git add -f tracking; exit=$($result.ExitCode)"
    Assert-PreflightPinCleaned -CaseName 'runtime force-tracked' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'runtime-three'
    $middleRuntimePath = 'runtime/middle-invisible.bin'
    $runtimeSpec = New-GreenFixtureSpec -Spec $spec -AdditionalFrontmatter @"
declared_runtime_paths:
  - src/a.py
  - $middleRuntimePath
  - src/b.py
"@
    $repo = New-FixtureRepo -Name 'runtime-three' -AgentsContent $greenRecipe -ExtraFiles @{
        '.gitignore' = "$middleRuntimePath`n"
        ($middleRuntimePath -replace '/', '\') = "invisible middle entry`n"
        "docs\changes\$spec.md" = $runtimeSpec
    }
    $result = Invoke-DispatchCase -CaseName 'DECLARED runtime three paths' -Spec $spec -Repo $repo -FakeRepo $repo
    $runtimeRefusalLines = @($result.Output -split "`r?`n" | Where-Object {
            $_ -match "REFUSED \(exit 81\): declared_runtime_paths '"
        })
    Assert-Case -Label 'runtime block sequence preserves all entries' `
        -Condition ($result.ExitCode -eq 81 -and $runtimeRefusalLines.Count -eq 1 -and
            $runtimeRefusalLines[0] -match [regex]::Escape($middleRuntimePath) -and
            $runtimeRefusalLines[0] -notmatch 'src/a\.py|src/b\.py') `
        -Detail 'three-entry string[] names only the invisible middle path'
    Assert-Case -Label 'runtime three-path lease-only refusal' `
        -Condition (Test-LeaseScopedRefusal -Result $result -ExitCode 81) `
        -Detail 'exit 81 closes exactly once without a dispatch row/log'
    Assert-PreflightPinCleaned -CaseName 'runtime three paths' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'runtime-untracked'
    $untrackedRuntimePath = 'runtime/untracked-tool.bin'
    $runtimeSpec = New-GreenFixtureSpec -Spec $spec -AdditionalFrontmatter @"
declared_runtime_paths:
  - $untrackedRuntimePath
"@
    $repo = New-FixtureRepo -Name 'runtime-untracked' -AgentsContent $greenRecipe `
        -ExtraFiles @{ "docs\changes\$spec.md" = $runtimeSpec }
    Write-Utf8NoBom -Path (Join-Path $repo ($untrackedRuntimePath -replace '/', '\')) `
        -Content "untracked runtime tool`n"
    $result = Invoke-DispatchCase -CaseName 'DECLARED runtime untracked' -Spec $spec -Repo $repo -FakeRepo $repo `
        -CaptureInformationStream
    Assert-Case -Label 'runtime untracked-not-ignored exits 81' `
        -Condition ($result.ExitCode -eq 81 -and
            $result.Output -match [regex]::Escape($untrackedRuntimePath) -and
            $result.Output -match 'declared path is not tracked at\s+this commit' -and
            $result.Output -match 'ls-files exit 1;\s+check-ignore exit 1') `
        -Detail 'existing untracked path is refused with both nonzero exit codes'
    Assert-Case -Label 'runtime untracked lease-only refusal' `
        -Condition (Test-LeaseScopedRefusal -Result $result -ExitCode 81) `
        -Detail 'exit 81 closes exactly once without a dispatch row/log'
    Assert-PreflightPinCleaned -CaseName 'runtime untracked' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'runtime-missing'
    $missingRuntimePath = 'runtime/does-not-exist.bin'
    $runtimeSpec = New-GreenFixtureSpec -Spec $spec -AdditionalFrontmatter @"
declared_runtime_paths:
  - $missingRuntimePath
"@
    $repo = New-FixtureRepo -Name 'runtime-missing' -AgentsContent $greenRecipe `
        -ExtraFiles @{ "docs\changes\$spec.md" = $runtimeSpec }
    $result = Invoke-DispatchCase -CaseName 'DECLARED runtime missing' -Spec $spec -Repo $repo -FakeRepo $repo `
        -CaptureInformationStream
    Assert-Case -Label 'runtime missing exits 81' `
        -Condition ($result.ExitCode -eq 81 -and
            $result.Output -match [regex]::Escape($missingRuntimePath) -and
            $result.Output -match 'declared path is not tracked at\s+this commit') `
        -Detail 'nonexistent declared path fails closed'
    Assert-Case -Label 'runtime missing lease-only refusal' `
        -Condition (Test-LeaseScopedRefusal -Result $result -ExitCode 81) `
        -Detail 'exit 81 closes exactly once without a dispatch row/log'
    Assert-PreflightPinCleaned -CaseName 'runtime missing' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'runtime-malformed'
    $runtimeSpec = New-GreenFixtureSpec -Spec $spec `
        -AdditionalFrontmatter 'declared_runtime_paths: [runtime/incomplete'
    $repo = New-FixtureRepo -Name 'runtime-malformed' -AgentsContent $greenRecipe `
        -ExtraFiles @{ "docs\changes\$spec.md" = $runtimeSpec }
    $result = Invoke-DispatchCase -CaseName 'DECLARED runtime malformed' -Spec $spec -Repo $repo -FakeRepo $repo
    Assert-Case -Label 'runtime malformed exits 81' `
        -Condition ($result.ExitCode -eq 81 -and
            $result.Output -match 'declared_runtime_paths present but unparseable') `
        -Detail 'malformed value uses the explicit unparseable refusal'
    Assert-Case -Label 'runtime malformed lease-only refusal' `
        -Condition (Test-LeaseScopedRefusal -Result $result -ExitCode 81) `
        -Detail 'exit 81 closes exactly once without a dispatch row/log'
    Assert-PreflightPinCleaned -CaseName 'runtime malformed' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'runtime-empty'
    $runtimeSpec = New-GreenFixtureSpec -Spec $spec `
        -AdditionalFrontmatter 'declared_runtime_paths: []'
    $repo = New-FixtureRepo -Name 'runtime-empty' -AgentsContent $greenRecipe `
        -ExtraFiles @{ "docs\changes\$spec.md" = $runtimeSpec }
    $result = Invoke-DispatchCase -CaseName 'DECLARED runtime empty list' -Spec $spec -Repo $repo `
        -FakeRepo $repo -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    Assert-Case -Label 'runtime empty list performs no check' `
        -Condition ($result.ExitCode -eq 0) -Detail "expected success, got $($result.ExitCode)"
    Assert-PreflightPinCleaned -CaseName 'runtime empty list' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'moved-tree'
    $greenSpec = New-GreenFixtureSpec -Spec $spec
    $repo = New-FixtureRepo -Name 'moved-tree' -AgentsContent $movedTreeRecipe -ExtraFiles @{ "docs\changes\$spec.md" = $greenSpec }
    $result = Invoke-DispatchCase -CaseName 'MOVED-TREE at launch' -Spec $spec -Repo $repo -FakeRepo $repo
    $movedRow = if ($result.Rows.Count -eq 1) { $result.Rows[0] } else { $null }
    Assert-Case -Label 'moved-tree exit' -Condition ($result.ExitCode -eq 69) -Detail "expected 69, got $($result.ExitCode)"
    Assert-Case -Label 'moved-tree ledger presence' -Condition ($result.Rows.Count -eq 1) -Detail "expected one row, got $($result.Rows.Count)"
    Assert-Case -Label 'moved-tree row status' -Condition ($null -ne $movedRow -and $movedRow.status -eq 'failed') -Detail "expected failed, got $($movedRow.status)"
    Assert-Case -Label 'moved-tree row error' -Condition ($null -ne $movedRow -and $movedRow.error -match 'tree moved under the pre-flight pin') -Detail "error=$($movedRow.error)"
    Assert-PreflightPinCleaned -CaseName 'moved-tree' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'green'
    $greenSpec = New-GreenFixtureSpec -Spec $spec
    $repo = New-FixtureRepo -Name 'green' -AgentsContent $greenRecipe -ExtraFiles @{ "docs\changes\$spec.md" = $greenSpec }
    $result = Invoke-DispatchCase -CaseName 'GREEN baseline' -Spec $spec -Repo $repo -FakeRepo $repo -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    Assert-Case -Label 'GREEN proceeds' -Condition ($result.ExitCode -notin @(72, 69)) -Detail "exit $($result.ExitCode) is not a gate refusal"
    Assert-Case -Label 'GREEN success' -Condition ($result.ExitCode -eq 0) -Detail "expected fake coder success 0, got $($result.ExitCode)"
    Assert-Case -Label 'GREEN ledger presence' -Condition ($result.Rows.Count -eq 1) -Detail "expected one row, got $($result.Rows.Count)"
    Assert-PreflightPinCleaned -CaseName 'GREEN' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'cross-tree-no-source'
    $repo = New-FixtureRepo -Name 'cross-tree-no-source' -AgentsContent $greenRecipe
    $result = Invoke-DispatchCase -CaseName 'CROSS-TREE no SpecSourcePath' -Spec $spec -Repo $repo -FakeRepo $repo
    Assert-Case -Label 'cross-tree-no-source exit' -Condition ($result.ExitCode -eq 72) -Detail "expected 72, got $($result.ExitCode)"
    Assert-Case -Label 'cross-tree-no-source ledger' -Condition (Test-LeaseScopedRefusal -Result $result -ExitCode 72) -Detail 'one lease and one exit-72 close; no dispatch row'
    Assert-NoCodexLog -CaseName 'cross-tree-no-source' -Spec $spec
    Assert-PreflightPinCleaned -CaseName 'cross-tree-no-source' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'cross-tree-valid'
    $greenSpec = New-GreenFixtureSpec -Spec $spec -AdditionalFrontmatter @'
declared_runtime_paths:
  - src/a.py
'@
    $specSourcePath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $testRoot 'external-specs\valid') "$spec.md"))
    Write-Utf8NoBom -Path $specSourcePath -Content $greenSpec
    $repo = New-FixtureRepo -Name 'cross-tree-valid' -AgentsContent $greenRecipe
    $result = Invoke-DispatchCase -CaseName 'CROSS-TREE valid SpecSourcePath' -Spec $spec -Repo $repo -FakeRepo $repo -ExtraParameters @{ SpecSourcePath = $specSourcePath } -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    Assert-Case -Label 'cross-tree-valid exit' -Condition ($result.ExitCode -eq 0) -Detail "expected fake coder success 0, got $($result.ExitCode)"
    Assert-Case -Label 'cross-tree-valid ledger' -Condition ($result.Rows.Count -eq 1) -Detail "expected one row, got $($result.Rows.Count)"
    Assert-PreflightPinCleaned -CaseName 'cross-tree-valid' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'cross-tree-missing'
    $specSourcePath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $testRoot 'external-specs\missing') "$spec.md"))
    $repo = New-FixtureRepo -Name 'cross-tree-missing' -AgentsContent $greenRecipe
    $result = Invoke-DispatchCase -CaseName 'CROSS-TREE missing SpecSourcePath' -Spec $spec -Repo $repo -FakeRepo $repo -ExtraParameters @{ SpecSourcePath = $specSourcePath }
    Assert-Case -Label 'cross-tree-missing exit' -Condition ($result.ExitCode -eq 72) -Detail "expected 72, got $($result.ExitCode)"
    Assert-Case -Label 'cross-tree-missing ledger' -Condition (Test-LeaseScopedRefusal -Result $result -ExitCode 72) -Detail 'one lease and one exit-72 close; no dispatch row'
    Assert-NoCodexLog -CaseName 'cross-tree-missing' -Spec $spec
    Assert-PreflightPinCleaned -CaseName 'cross-tree-missing' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'cross-tree-invalid'
    $specSourcePath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $testRoot 'external-specs\invalid') "$spec.md"))
    Write-Utf8NoBom -Path $specSourcePath -Content $invalidSpec
    $repo = New-FixtureRepo -Name 'cross-tree-invalid' -AgentsContent $greenRecipe
    $result = Invoke-DispatchCase -CaseName 'CROSS-TREE invalid SpecSourcePath' -Spec $spec -Repo $repo -FakeRepo $repo -ExtraParameters @{ SpecSourcePath = $specSourcePath }
    Assert-Case -Label 'cross-tree-invalid exit' -Condition ($result.ExitCode -eq 72) -Detail "expected 72, got $($result.ExitCode)"
    Assert-Case -Label 'cross-tree-invalid ledger' -Condition (Test-LeaseScopedRefusal -Result $result -ExitCode 72) -Detail 'one lease and one exit-72 close; no dispatch row'
    Assert-Case -Label 'cross-tree-invalid evidence' -Condition ($result.Output -match 'FAIL FILES-COMPLETENESS') -Detail 'dispatcher printed the validator finding'
    Assert-NoCodexLog -CaseName 'cross-tree-invalid' -Spec $spec
    Assert-PreflightPinCleaned -CaseName 'cross-tree-invalid' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'cross-tree-mismatch'
    $sourceSpec = New-UniqueSpec -CaseName 'cross-tree-other-name'
    $greenSpec = New-GreenFixtureSpec -Spec $sourceSpec
    $specSourcePath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $testRoot 'external-specs\mismatch') "$sourceSpec.md"))
    Write-Utf8NoBom -Path $specSourcePath -Content $greenSpec
    $repo = New-FixtureRepo -Name 'cross-tree-mismatch' -AgentsContent $greenRecipe
    $result = Invoke-DispatchCase -CaseName 'CROSS-TREE basename mismatch' -Spec $spec -Repo $repo -FakeRepo $repo -ExtraParameters @{ SpecSourcePath = $specSourcePath }
    Assert-Case -Label 'cross-tree-mismatch exit' -Condition ($result.ExitCode -eq 72) -Detail "expected 72, got $($result.ExitCode)"
    Assert-Case -Label 'cross-tree-mismatch ledger' -Condition (Test-LeaseScopedRefusal -Result $result -ExitCode 72) -Detail 'one lease and one exit-72 close; no dispatch row'
    Assert-NoCodexLog -CaseName 'cross-tree-mismatch' -Spec $spec
    Assert-PreflightPinCleaned -CaseName 'cross-tree-mismatch' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'cross-tree-relative'
    $specSourcePath = "docs\changes\$spec.md"
    $repo = New-FixtureRepo -Name 'cross-tree-relative' -AgentsContent $greenRecipe
    $result = Invoke-DispatchCase -CaseName 'CROSS-TREE relative SpecSourcePath' -Spec $spec -Repo $repo -FakeRepo $repo -ExtraParameters @{ SpecSourcePath = $specSourcePath }
    Assert-Case -Label 'cross-tree-relative exit' -Condition ($result.ExitCode -eq 72) -Detail "expected 72, got $($result.ExitCode)"
    Assert-Case -Label 'cross-tree-relative ledger' -Condition (Test-LeaseScopedRefusal -Result $result -ExitCode 72) -Detail 'one lease and one exit-72 close; no dispatch row'
    Assert-NoCodexLog -CaseName 'cross-tree-relative' -Spec $spec
    Assert-PreflightPinCleaned -CaseName 'cross-tree-relative' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'cross-tree-precedence'
    $greenSpec = New-GreenFixtureSpec -Spec $spec
    $specSourcePath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $testRoot 'external-specs\precedence') "$spec.md"))
    Write-Utf8NoBom -Path $specSourcePath -Content $invalidSpec
    $repo = New-FixtureRepo -Name 'cross-tree-precedence' -AgentsContent $greenRecipe -ExtraFiles @{ "docs\changes\$spec.md" = $greenSpec }
    $result = Invoke-DispatchCase -CaseName 'IN-WORKTREE spec precedence' -Spec $spec -Repo $repo -FakeRepo $repo -ExtraParameters @{ SpecSourcePath = $specSourcePath } -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    Assert-Case -Label 'cross-tree-precedence exit' -Condition ($result.ExitCode -eq 0) -Detail "expected fake coder success 0, got $($result.ExitCode)"
    Assert-Case -Label 'cross-tree-precedence ledger' -Condition ($result.Rows.Count -eq 1) -Detail "expected one row, got $($result.Rows.Count)"
    Assert-PreflightPinCleaned -CaseName 'cross-tree-precedence' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'cross-tree-drive-relative'
    $specSourcePath = "C:relative\path\$spec.md"
    $repo = New-FixtureRepo -Name 'cross-tree-drive-relative' -AgentsContent $greenRecipe
    $result = Invoke-DispatchCase -CaseName 'CROSS-TREE drive-relative SpecSourcePath' -Spec $spec -Repo $repo -FakeRepo $repo -ExtraParameters @{ SpecSourcePath = $specSourcePath }
    Assert-Case -Label 'cross-tree-drive-relative exit' -Condition ($result.ExitCode -eq 72) -Detail "expected 72, got $($result.ExitCode)"
    Assert-Case -Label 'cross-tree-drive-relative ledger' -Condition (Test-LeaseScopedRefusal -Result $result -ExitCode 72) -Detail 'one lease and one exit-72 close; no dispatch row'
    Assert-NoCodexLog -CaseName 'cross-tree-drive-relative' -Spec $spec
    Assert-PreflightPinCleaned -CaseName 'cross-tree-drive-relative' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'cross-tree-case-variant'
    $greenSpec = New-GreenFixtureSpec -Spec $spec
    $caseVariantSpec = $spec.ToUpperInvariant()
    $specSourcePath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $testRoot 'external-specs\case-variant') "$caseVariantSpec.md"))
    Write-Utf8NoBom -Path $specSourcePath -Content $greenSpec
    $repo = New-FixtureRepo -Name 'cross-tree-case-variant' -AgentsContent $greenRecipe
    $result = Invoke-DispatchCase -CaseName 'CROSS-TREE case-variant basename' -Spec $spec -Repo $repo -FakeRepo $repo -ExtraParameters @{ SpecSourcePath = $specSourcePath } -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    Assert-Case -Label 'cross-tree-case-variant exit' -Condition ($result.ExitCode -eq 0) -Detail "expected fake coder success 0, got $($result.ExitCode)"
    Assert-Case -Label 'cross-tree-case-variant ledger' -Condition ($result.Rows.Count -eq 1) -Detail "expected one row, got $($result.Rows.Count)"
    Assert-PreflightPinCleaned -CaseName 'cross-tree-case-variant' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'review'
    $repo = New-FixtureRepo -Name 'review-red-recipe' -AgentsContent $redRecipe
    $reviewSink = New-FixtureRepo -Name 'review-fake-sink' -AgentsContent $greenRecipe
    $result = Invoke-DispatchCase -CaseName 'REVIEW phase skips build gate' -Spec $spec -Repo $repo -FakeRepo $reviewSink -ExtraParameters @{ Phase = 'review'; Schema = 'review' } -FakeEnvironment @{ FAKE_CODEX_VERDICT = 'BLOCK' }
    Assert-Case -Label 'review gate skipped' -Condition ($result.ExitCode -ne 72) -Detail "red recipe did not produce exit 72 (got $($result.ExitCode))"
    Assert-Case -Label 'review skip note' -Condition ($result.Output -match 'pre-flight skipped \(phase/sandbox\)') -Detail 'dispatcher explicitly skipped the build pre-flight'
    Assert-Case -Label 'review reaches fake verdict' -Condition ($result.ExitCode -eq 67) -Detail "expected fake BLOCK verdict exit 67, got $($result.ExitCode)"
    Assert-Case -Label 'review ledger presence' -Condition ($result.Rows.Count -eq 1) -Detail "expected one row, got $($result.Rows.Count)"
    Assert-Case -Label 'review ledger status' -Condition ($result.Rows.Count -eq 1 -and $result.Rows[0].status -eq 'blocked') -Detail "status=$($result.Rows[0].status)"
    Assert-Case -Label 'review forced read-only' -Condition ($result.Rows.Count -eq 1 -and $result.Rows[0].sandbox -eq 'read-only') -Detail "sandbox=$($result.Rows[0].sandbox)"
    Assert-Case -Label 'review tree pinned' -Condition ($result.Output -match '\[tree-pin\] pinned' -and $result.Output -match '\[tree-pin\] tree unchanged') -Detail 'review pin armed and verified'
    Assert-PreflightPinCleaned -CaseName 'review' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'skip-baseline'
    $skipSpec = New-GreenFixtureSpec -Spec $spec -AdditionalFrontmatter @'
declared_runtime_paths:
  - runtime/missing-but-bypassed.bin
'@
    $repo = New-FixtureRepo -Name 'skip-baseline' -AgentsContent $redRecipe `
        -ExtraFiles @{ "docs\changes\$spec.md" = $skipSpec }
    $result = Invoke-DispatchCase -CaseName 'SkipBaselineCheck bypass' -Spec $spec -Repo $repo -FakeRepo $repo -ExtraParameters @{ SkipBaselineCheck = $true } -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    Assert-Case -Label 'skip-baseline proceeds' -Condition ($result.ExitCode -ne 72) -Detail "red recipe bypassed the baseline (exit $($result.ExitCode))"
    Assert-Case -Label 'skip-baseline success' -Condition ($result.ExitCode -eq 0) -Detail "expected fake coder success 0, got $($result.ExitCode)"
    Assert-Case -Label 'skip-baseline ledger presence' -Condition ($result.Rows.Count -eq 1) -Detail "expected one row, got $($result.Rows.Count)"
    Assert-Case -Label 'skip-baseline ledger flag' -Condition ($result.Rows.Count -eq 1 -and $result.Rows[0].baseline_skipped -eq $true) -Detail "baseline_skipped=$($result.Rows[0].baseline_skipped)"
    Assert-Case -Label 'skip-baseline loud note' -Condition ($result.Output -match 'baseline/spec pre-flight BYPASSED') -Detail 'bypass note was printed'
    Assert-PreflightPinCleaned -CaseName 'skip-baseline' -Spec $spec

    # Task 2A contract: known lease-scoped refusals preserve their contractual exit code and append
    # exactly one matching close event. The close helper also verifies that no dispatch row or log
    # was created for the refused run.
    $spec = New-UniqueSpec -CaseName 'exit-76'
    $repo = New-FixtureRepo -Name 'exit-76' -AgentsContent $greenRecipe
    $missingCriticalScript = Join-Path $testRoot 'missing-critical-file-classifier.ps1'
    $result = Invoke-DispatchCase -CaseName 'LEASE refusal exit 76' -Spec $spec -Repo $repo `
        -FakeRepo $repo -ExtraParameters @{
            CriticalFilesScript = $missingCriticalScript
            SkipBaselineCheck = $true
        }
    Assert-Case -Label 'exit 76 contract and close telemetry' `
        -Condition ($result.ExitCode -eq 76 -and (Test-LeaseScopedRefusal -Result $result -ExitCode 76)) `
        -Detail ("exit={0}; one refusal_exit=76 close; no dispatch row/log" -f $result.ExitCode)

    $spec = New-UniqueSpec -CaseName 'exit-78'
    $repo = New-FixtureRepo -Name 'exit-78' -AgentsContent $greenRecipe
    $result = Invoke-DispatchCase -CaseName 'LEASE refusal exit 78' -Spec $spec -Repo $repo `
        -FakeRepo $repo -ExtraParameters @{
            Phase = 'review'
            Schema = 'review'
            ReviewedRunId = 'missing-reviewed-build'
        }
    Assert-Case -Label 'exit 78 contract and close telemetry' `
        -Condition ($result.ExitCode -eq 78 -and (Test-LeaseScopedRefusal -Result $result -ExitCode 78)) `
        -Detail ("exit={0}; one refusal_exit=78 close; no dispatch row/log" -f $result.ExitCode)

    $spec = New-UniqueSpec -CaseName 'exit-71'
    $repo = New-FixtureRepo -Name 'exit-71' -AgentsContent $greenRecipe
    $fixtureTop = @(
        Invoke-FixtureGit -Repo $repo -GitArguments @('rev-parse', '--show-toplevel')
    )[0]
    $fixtureWorktreeKey = (([string]$fixtureTop) -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
    $fixtureProcessStamp = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    $seededSiblingRunId = [guid]::NewGuid().ToString('N')
    Add-TestLedgerRow -Row ([ordered]@{
        run_id = $seededSiblingRunId
        row_kind = 'dispatch'
        status = 'running'
        pid = $PID
        pid_start = $fixtureProcessStamp
        launcher_pid = $PID
        launcher_start = $fixtureProcessStamp
        worktree = $repo
        worktree_key = $fixtureWorktreeKey
        spec = $spec
        task = 'seeded-live-sibling'
        phase = 'build'
        sandbox = 'workspace-write'
        effort = 'medium'
        started = [DateTime]::UtcNow.ToString('o')
    })
    $result = Invoke-DispatchCase -CaseName 'LEASE refusal exit 71' -Spec $spec -Repo $repo `
        -FakeRepo $repo -ExtraParameters @{ SkipBaselineCheck = $true }
    Assert-Case -Label 'exit 71 contract and close telemetry' `
        -Condition ($result.ExitCode -eq 71 -and (Test-LeaseScopedRefusal -Result $result -ExitCode 71)) `
        -Detail ("exit={0}; one refusal_exit=71 close; no refused-run dispatch row/log" -f $result.ExitCode)
    Set-TestLedgerRowStatus -RunId $seededSiblingRunId -Status 'done'

    $spec = New-UniqueSpec -CaseName 'allowshared-adopting-still-80'
    $repo = New-FixtureRepo -Name 'allowshared-adopting-still-80' -AgentsContent $greenRecipe
    $fixtureTop = @(
        Invoke-FixtureGit -Repo $repo -GitArguments @('rev-parse', '--show-toplevel')
    )[0]
    $fixtureWorktreeKey = (([string]$fixtureTop) -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
    $fixtureProcessStamp = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    $adoptingSiblingRunId = [guid]::NewGuid().ToString('N')
    Add-TestLedgerRow -Row ([ordered]@{
        run_id = $adoptingSiblingRunId
        row_kind = 'dispatch'
        status = 'adopting'
        pid = $PID
        pid_start = $fixtureProcessStamp
        launcher_pid = $PID
        launcher_start = $fixtureProcessStamp
        worktree = $repo
        worktree_key = $fixtureWorktreeKey
        spec = $spec
        task = 'seeded-adopting-sibling'
        phase = 'build'
        sandbox = 'workspace-write'
        effort = 'medium'
        started = [DateTime]::UtcNow.ToString('o')
    })
    $adoptingResult = Invoke-DispatchCase -CaseName 'allowshared-adopting-still-80' -Spec $spec `
        -Repo $repo -FakeRepo $repo -ExtraParameters @{
            SkipBaselineCheck = $true
            AllowSharedWorktree = $true
            AllowSharedWorktreeReason = 'prove adoption remains un-overridable'
        }
    Assert-Case -Label 'allowshared-adopting-still-80' `
        -Condition ($adoptingResult.ExitCode -eq 80 -and
            $adoptingResult.Output -match 'status=adopting' -and
            (Test-LeaseScopedRefusal -Result $adoptingResult -ExitCode 80)) `
        -Detail ("exit={0}; adopting sibling remains unresolved" -f $adoptingResult.ExitCode)
    Set-TestLedgerRowStatus -RunId $adoptingSiblingRunId -Status 'done'

    $runningSiblingRunId = [guid]::NewGuid().ToString('N')
    Add-TestLedgerRow -Row ([ordered]@{
        run_id = $runningSiblingRunId
        row_kind = 'dispatch'
        status = 'running'
        pid = $PID
        pid_start = $fixtureProcessStamp
        launcher_pid = $PID
        launcher_start = $fixtureProcessStamp
        worktree = $repo
        worktree_key = $fixtureWorktreeKey
        spec = $spec
        task = 'seeded-running-sibling'
        phase = 'build'
        sandbox = 'workspace-write'
        effort = 'medium'
        started = [DateTime]::UtcNow.ToString('o')
    })
    $runningResult = Invoke-DispatchCase -CaseName 'allowshared-running-still-launches' -Spec $spec `
        -Repo $repo -FakeRepo $repo -ExtraParameters @{
            SkipBaselineCheck = $true
            AllowSharedWorktree = $true
            AllowSharedWorktreeReason = 'prove running sibling remains shareable'
        } -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    Assert-Case -Label 'allowshared running sibling still launches' `
        -Condition ($runningResult.ExitCode -eq 0 -and
            @($runningResult.Rows | Where-Object {
                    [string]$_.row_kind -ceq 'dispatch' -and
                    [string]$_.task -ceq 'task-7' -and
                    [string]$_.status -ceq 'done'
                }).Count -eq 1) `
        -Detail ("exit={0}; shared dispatch completed" -f $runningResult.ExitCode)
    Set-TestLedgerRowStatus -RunId $runningSiblingRunId -Status 'done'

    # Fault-inject a throw immediately after the atomic lease append. Running the instrumented copy
    # in a child PowerShell proves the wrapper's real unhandled-exception code while keeping this
    # suite alive to inspect the close row.
    $faultDispatch = Join-Path $PSScriptRoot (
        "codex-dispatch-unknown-fault-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
    $dispatchSource = [System.IO.File]::ReadAllText($dispatch)
    $faultAnchor = 'if ($script:capacityRefusal) {'
    $faultIndex = $dispatchSource.IndexOf($faultAnchor, [System.StringComparison]::Ordinal)
    if ($faultIndex -lt 0) { throw "Could not find lease fault-injection anchor in $dispatch" }
    $faultSource = $dispatchSource.Insert(
        $faultIndex,
        "throw 'forced uninstrumented guarded-region failure'`r`n`r`n")
    Write-Utf8NoBom -Path $faultDispatch -Content $faultSource

    $spec = New-UniqueSpec -CaseName 'unknown-close'
    $repo = New-FixtureRepo -Name 'unknown-close' -AgentsContent $greenRecipe
    $faultErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $faultCaptured = @(
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $faultDispatch `
                -Spec $spec -Task 'task-7' -Phase 'build' -Worktree $repo `
                -BaseSha (Get-FixtureHead -Repo $repo) -Prompt 'forced guarded throw' `
                -Authorized 'src/a.py' -ScratchDirectory $scratchRoot *>&1
        )
        $faultExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $faultErrorActionPreference
    }
    $faultResult = [pscustomobject]@{
        ExitCode = $faultExitCode
        Output = ($faultCaptured | Out-String)
        Rows = @(Get-LedgerRowsForSpec -Spec $spec)
    }
    Assert-Case -Label 'uninstrumented throw uses unknown close sentinel' `
        -Condition ($faultResult.ExitCode -eq 1 -and (Test-UnknownLeaseClosure -Result $faultResult)) `
        -Detail ("exit={0}; one refusal_exit=unknown close and no dispatch row" -f $faultResult.ExitCode)
    Remove-Item -LiteralPath $faultDispatch -Force
    $faultDispatch = $null

    $holdFake = Join-Path $testRoot 'capacity-hold-fake.ps1'
    Write-Utf8NoBom -Path $holdFake -Content @'
$passThruArgs = $args
[void][Console]::In.ReadToEnd()
Start-Sleep -Seconds 12
$finalPath = $null
for ($i = 0; $i -lt $passThruArgs.Count - 1; $i++) {
    if ($passThruArgs[$i] -eq '-o') { $finalPath = $passThruArgs[$i + 1]; break }
}
$report = [ordered]@{
    status = 'done'; changed_files = @(); commands_run = @()
    deviations = @(); unresolved = @(); blocker = $null
}
[System.IO.File]::WriteAllText($finalPath, ($report | ConvertTo-Json -Depth 8),
    [System.Text.UTF8Encoding]::new($false))
exit 0
'@

    # State-root cap: two live wrappers pass the same atomic check; N+1 is refused before leasing.
    $machineSpecs = @('capacity-machine-a', 'capacity-machine-b')
    $machineRepos = @()
    foreach ($machineSpec in $machineSpecs) {
        $machineRepos += New-FixtureRepo -Name $machineSpec -AgentsContent $greenRecipe `
            -ExtraFiles @{ "docs\changes\$machineSpec.md" = (New-GreenFixtureSpec -Spec $machineSpec -MaxParallelCodex 4) }
    }
    foreach ($index in 0..1) {
        $job = Start-HeldDispatch -Spec $machineSpecs[$index] -Repo $machineRepos[$index] `
            -FakePath $holdFake -MachineCeiling 2
        $capacityJobs += $job
    }
    $machineReady = Wait-ForOccupyingDispatches -Specs $machineSpecs
    Assert-Case -Label 'machine cap holders are concurrent' -Condition $machineReady -Detail 'two build wrappers occupy one shared state root'

    $surplusSpec = 'capacity-machine-surplus'
    $surplusRepo = New-FixtureRepo -Name $surplusSpec -AgentsContent $greenRecipe `
        -ExtraFiles @{ "docs\changes\$surplusSpec.md" = (New-GreenFixtureSpec -Spec $surplusSpec -MaxParallelCodex 4) }
    $beforeCapacityBytes = Invoke-WithFixtureLedgerLock {
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ledgerPath))
    }
    $surplus = Invoke-DispatchCase -CaseName 'MACHINE capacity surplus' -Spec $surplusSpec `
        -Repo $surplusRepo -FakeRepo $surplusRepo -ExtraParameters @{ SkipBaselineCheck = $true; MachineCeiling = 2 }
    $afterCapacityBytes = Invoke-WithFixtureLedgerLock {
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ledgerPath))
    }
    Assert-Case -Label 'machine cap surplus exits 79 pre-lease' `
        -Condition ($surplus.ExitCode -eq 79 -and $surplus.Rows.Count -eq 0 -and
            $surplus.Output -match 'bound=state-root') `
        -Detail ("exit={0}, rows={1}, machine bound named={2}" -f $surplus.ExitCode, $surplus.Rows.Count,
            ($surplus.Output -match 'bound=state-root'))
    Assert-Case -Label 'capacity refusal preserves ledger bytes' `
        -Condition ($beforeCapacityBytes -ceq $afterCapacityBytes) `
        -Detail 'every pre-existing line remains byte-identical and no refusal row is appended'

    $invalidCapacitySpec = 'capacity-invalid-contract'
    $invalidCapacityRepo = New-FixtureRepo -Name $invalidCapacitySpec -AgentsContent $greenRecipe `
        -ExtraFiles @{
            "docs\changes\$invalidCapacitySpec.md" = (New-GreenFixtureSpec -Spec $invalidCapacitySpec `
                -AdditionalFrontmatter 'max_parallel_codex: [1, 2')
        }
    $invalidCapacity = Invoke-DispatchCase -CaseName 'exit79-invalid-contract-marker' `
        -Spec $invalidCapacitySpec -Repo $invalidCapacityRepo -FakeRepo $invalidCapacityRepo `
        -ExtraParameters @{ SkipBaselineCheck = $true; MachineCeiling = 2 }
    $permanentCapacityMarker = '[dispatch] PERMANENT: invalid capacity contract (do not re-queue).'
    $invalidCapacityLines = @($invalidCapacity.Output -split '\r?\n')
    $atCapacityLines = @($surplus.Output -split '\r?\n')
    Assert-Case -Label 'exit79-invalid-contract-marker' `
        -Condition ($invalidCapacity.ExitCode -eq 79 -and
            $invalidCapacityLines -ccontains $permanentCapacityMarker -and
            $atCapacityLines -cnotcontains $permanentCapacityMarker) `
        -Detail ("invalid exit={0}, marker present={1}; at-capacity marker absent={2}" -f
            $invalidCapacity.ExitCode,
            ($invalidCapacityLines -ccontains $permanentCapacityMarker),
            ($atCapacityLines -cnotcontains $permanentCapacityMarker))

    Wait-Job -Job $capacityJobs | Out-Null
    $machineJobResults = @($capacityJobs | Receive-Job)
    Assert-Case -Label 'machine cap holders complete' `
        -Condition (@($machineJobResults | Where-Object { $_.ExitCode -ne 0 }).Count -eq 0) `
        -Detail 'both admitted wrappers completed normally'
    Remove-Job -Job $capacityJobs -Force
    $capacityJobs = @()

    # Per-spec caps are independent. Add an ultra holder to fill the four-slot machine budget, then
    # prove a review still passes capacity while a further build is refused by the machine bound.
    $specA = 'capacity-spec-a'
    $specB = 'capacity-spec-b'
    $specC = 'capacity-ultra'
    $repoA = New-FixtureRepo -Name $specA -AgentsContent $greenRecipe `
        -ExtraFiles @{ "docs\changes\$specA.md" = (New-GreenFixtureSpec -Spec $specA -MaxParallelCodex 1) }
    $repoB = New-FixtureRepo -Name $specB -AgentsContent $greenRecipe `
        -ExtraFiles @{ "docs\changes\$specB.md" = (New-GreenFixtureSpec -Spec $specB -MaxParallelCodex 1) }
    $repoC = New-FixtureRepo -Name $specC -AgentsContent $greenRecipe `
        -ExtraFiles @{ "docs\changes\$specC.md" = (New-GreenFixtureSpec -Spec $specC -MaxParallelCodex 2) }
    $capacityJobs += Start-HeldDispatch -Spec $specA -Repo $repoA -FakePath $holdFake -MachineCeiling 4
    $capacityJobs += Start-HeldDispatch -Spec $specB -Repo $repoB -FakePath $holdFake -MachineCeiling 4
    $perSpecReady = Wait-ForOccupyingDispatches -Specs @($specA, $specB)
    Assert-Case -Label 'different max-one specs run concurrently' -Condition $perSpecReady `
        -Detail 'spec A and spec B each hold their independent max_parallel_codex=1 slot'

    $sameSpecSurplus = Invoke-DispatchCase -CaseName 'PER-SPEC capacity surplus' -Spec $specA `
        -Repo $repoA -FakeRepo $repoA -ExtraParameters @{
            SkipBaselineCheck = $true; MachineCeiling = 4; AllowSharedWorktree = $true
            AllowSharedWorktreeReason = 'capacity test must reach the per-spec bound first'
        }
    Assert-Case -Label 'same-spec surplus exits 79 pre-lease' `
        -Condition ($sameSpecSurplus.ExitCode -eq 79 -and
            @($sameSpecSurplus.Rows | Where-Object { $_.task -ne 'capacity-hold' }).Count -eq 0 -and
            $sameSpecSurplus.Output -match 'bound=spec') `
        -Detail ("exit={0}, spec bound named={1}" -f $sameSpecSurplus.ExitCode,
            ($sameSpecSurplus.Output -match 'bound=spec'))

    $capacityJobs += Start-HeldDispatch -Spec $specC -Repo $repoC -FakePath $holdFake `
        -MachineCeiling 4 -Effort ultra
    $ultraReady = Wait-ForOccupyingDispatches -Specs @($specA, $specB, $specC)
    Assert-Case -Label 'ultra run admitted at weight two' -Condition $ultraReady `
        -Detail 'two regular holders plus one ultra holder occupy all four weighted slots'

    $reviewSpec = 'capacity-review-free'
    $reviewRepo = New-FixtureRepo -Name $reviewSpec -AgentsContent $redRecipe
    $reviewSink = New-FixtureRepo -Name 'capacity-review-sink' -AgentsContent $greenRecipe
    $reviewResult = Invoke-DispatchCase -CaseName 'REVIEW does not consume build capacity' -Spec $reviewSpec `
        -Repo $reviewRepo -FakeRepo $reviewSink -ExtraParameters @{
            Phase = 'review'; Schema = 'review'; MachineCeiling = 4; NoTreePin = $true
            NoTreePinReason = 'capacity-only fixture'
        } -FakeEnvironment @{ FAKE_CODEX_VERDICT = 'BLOCK' }
    Assert-Case -Label 'review passes a full build cap' `
        -Condition ($reviewResult.ExitCode -eq 67 -and
            @($reviewResult.Rows | Where-Object { [string]$_.row_kind -ceq 'dispatch' }).Count -eq 1) `
        -Detail ("exit={0}; review reached verdict instead of exit 79" -f $reviewResult.ExitCode)

    $machineFullSpec = 'capacity-machine-full'
    $machineFullRepo = New-FixtureRepo -Name $machineFullSpec -AgentsContent $greenRecipe `
        -ExtraFiles @{ "docs\changes\$machineFullSpec.md" = (New-GreenFixtureSpec -Spec $machineFullSpec -MaxParallelCodex 4) }
    $machineFull = Invoke-DispatchCase -CaseName 'WEIGHTED machine capacity surplus' -Spec $machineFullSpec `
        -Repo $machineFullRepo -FakeRepo $machineFullRepo `
        -ExtraParameters @{ SkipBaselineCheck = $true; MachineCeiling = 4 }
    Assert-Case -Label 'ultra consumes two machine slots' `
        -Condition ($machineFull.ExitCode -eq 79 -and $machineFull.Rows.Count -eq 0 -and
            $machineFull.Output -match 'machineWeight=4' -and $machineFull.Output -match 'effort=ultra') `
        -Detail ("exit={0}, weighted total shown={1}, ultra occupant shown={2}" -f $machineFull.ExitCode,
            ($machineFull.Output -match 'machineWeight=4'), ($machineFull.Output -match 'effort=ultra'))

    Wait-Job -Job $capacityJobs | Out-Null
    $multiSpecJobResults = @($capacityJobs | Receive-Job)
    Assert-Case -Label 'multi-spec holders complete' `
        -Condition (@($multiSpecJobResults | Where-Object { $_.ExitCode -ne 0 }).Count -eq 0) `
        -Detail 'both max-one runs and the ultra run completed normally'
    Remove-Job -Job $capacityJobs -Force
    $capacityJobs = @()

    # Caller-contract exit 74 remains before identity/lease creation and leaves no ledger artifact.
    $preLeaseSpec = 'capacity-prelease-74'
    $preLeaseRepo = New-FixtureRepo -Name $preLeaseSpec -AgentsContent $greenRecipe
    $preLease = Invoke-DispatchCase -CaseName 'PRE-LEASE caller contract' -Spec $preLeaseSpec `
        -Repo $preLeaseRepo -FakeRepo $preLeaseRepo -ExtraParameters @{ Authorized = @() }
    Assert-Case -Label 'plain exit 74 leaves zero rows' `
        -Condition ($preLease.ExitCode -eq 74 -and $preLease.Rows.Count -eq 0) `
        -Detail ("exit={0}, rows={1}" -f $preLease.ExitCode, $preLease.Rows.Count)

    Write-Host "`nSKIP  OPTIONAL exit-71 pin cleanup -- reviewer-traced to the outer preflight arm-to-launch try/finally in codex-dispatch.ps1." -ForegroundColor Yellow
}
catch {
    $script:failureCount++
    Write-Host "`nFAIL  suite setup/execution threw: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}
finally {
    if ($faultDispatch -and (Test-Path -LiteralPath $faultDispatch -PathType Leaf)) {
        Remove-Item -LiteralPath $faultDispatch -Force -ErrorAction SilentlyContinue
    }
    if ($capacityJobs.Count -gt 0) {
        $capacityJobs | Stop-Job -ErrorAction SilentlyContinue
        $capacityJobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    Set-OptionalEnvironmentValue -Name 'APEX_STATE_DIR' -Value $oldApexStateDir
    Set-OptionalEnvironmentValue -Name 'FAKE_CODEX_REPO' -Value $oldFakeRepo
    Set-OptionalEnvironmentValue -Name 'FAKE_CODEX_INSCOPE_ONLY' -Value $oldFakeInScopeOnly
    Set-OptionalEnvironmentValue -Name 'FAKE_CODEX_STATUS' -Value $oldFakeStatus
    Set-OptionalEnvironmentValue -Name 'FAKE_CODEX_NO_REPORT' -Value $oldFakeNoReport
    Set-OptionalEnvironmentValue -Name 'FAKE_CODEX_VERDICT' -Value $oldFakeVerdict
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n===== PREFLIGHT SUITE SUMMARY =====" -ForegroundColor Cyan
Write-Host ("Assertions: {0}; failures: {1}" -f $script:assertionCount, $script:failureCount)
if ($script:failureCount -gt 0) {
    Write-Host 'dispatch-preflight-test.ps1 FAILED' -ForegroundColor Red
    exit 1
}

Write-Host 'dispatch-preflight-test.ps1 PASSED' -ForegroundColor Green
exit 0
