# Loud-fail end-to-end coverage for codex-dispatch.ps1's critical-file gate
# and family-ledger fields. All repositories and state are disposable and live
# under one fresh directory outside this repository.

$ErrorActionPreference = 'Stop'

$dispatch = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
$fakeCodex = Join-Path $PSScriptRoot 'dispatch-test-fakecodex.ps1'
$criticalFiles = Join-Path $PSScriptRoot 'apex-critical-files.ps1'
$scopeCheck = Join-Path $PSScriptRoot 'codex-scope-check.ps1'
foreach ($required in @($dispatch, $fakeCodex, $criticalFiles, $scopeCheck)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required test dependency not found: $required"
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("apex-critfile-test-" + [guid]::NewGuid().ToString('N'))
$repoRoot = Join-Path $testRoot 'repos'
$stateRoot = Join-Path $testRoot 'state'
$scratchRoot = Join-Path $stateRoot 'scratch'
$ledgerPath = Join-Path (Join-Path $stateRoot 'progress') 'codex-run-ledger.jsonl'
$unexpectedClassifier = Join-Path $testRoot 'classifier-exit-7.ps1'
$noExitClassifier = Join-Path $testRoot 'classifier-no-exit.ps1'
$missingClassifier = Join-Path $testRoot 'classifier-does-not-exist.ps1'

$oldApexStateDir = $env:APEX_STATE_DIR
$oldFakeRepo = $env:FAKE_CODEX_REPO
$oldFakeInScopeOnly = $env:FAKE_CODEX_INSCOPE_ONLY
$oldFakeExtraWrite = $env:FAKE_CODEX_EXTRA_WRITE
$oldFakeStatus = $env:FAKE_CODEX_STATUS
$oldFakeNoReport = $env:FAKE_CODEX_NO_REPORT
$oldFakeVerdict = $env:FAKE_CODEX_VERDICT
$oldGitConfigGlobal = $env:GIT_CONFIG_GLOBAL

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

function New-FixtureSpec {
    param([Parameter(Mandatory)][string]$Spec)

    return @"
---
spec: $Spec
status: draft
autonomy_level: L2
---
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
        [hashtable]$ExtraFiles = @{}
    )

    $repo = Join-Path $repoRoot $Name
    [System.IO.Directory]::CreateDirectory((Join-Path $repo 'src')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $repo 'docs')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $repo 'config')) | Out-Null
    Write-Utf8NoBom -Path (Join-Path $repo 'src\a.py') -Content "original`n"
    Write-Utf8NoBom -Path (Join-Path $repo 'src\b.py') -Content "original`n"
    Write-Utf8NoBom -Path (Join-Path $repo 'docs\status.md') -Content "fixture state`n"
    Write-Utf8NoBom -Path (Join-Path $repo 'config\.env') -Content "FIXTURE_ONLY=1`n"
    Write-Utf8NoBom -Path (Join-Path $repo 'AGENTS.md') -Content @'
## Verify commands

```
exit 0
```
'@
    foreach ($entry in $ExtraFiles.GetEnumerator()) {
        Write-Utf8NoBom -Path (Join-Path $repo $entry.Key) -Content ([string]$entry.Value)
    }

    Invoke-FixtureGit -Repo $repo -GitArguments @('init', '-q') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('config', 'user.email', 'dispatch-criticalfile-test@example.invalid') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('config', 'user.name', 'dispatch-criticalfile-test') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('add', '-A') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('commit', '-q', '-m', 'fixture') | Out-Null
    $head = @(Invoke-FixtureGit -Repo $repo -GitArguments @('rev-parse', 'HEAD'))

    return [pscustomobject]@{
        Path = $repo
        BaseSha = ([string]$head[0]).Trim()
    }
}

function Get-LedgerRowsForSpec {
    param([Parameter(Mandatory)][string]$Spec)

    if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { return @() }
    $matches = @()
    foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
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
        foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $line | ConvertFrom-Json
            if ([string]$row.run_id -ceq $runId) { $row }
        }
    )
    $dispatchRows = @($runRows | Where-Object { [string]$_.row_kind -ceq 'dispatch' })
    $closeRows = @($runRows | Where-Object { [string]$_.row_kind -ceq 'lease_close' })
    return ($dispatchRows.Count -eq 0 -and $closeRows.Count -eq 1 -and
        [string]$closeRows[0].status -ceq 'refused-preflight' -and
        [int]$closeRows[0].refusal_exit -eq $ExitCode)
}

function Set-LedgerRowProperty {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()]$Value,
        [switch]$Remove
    )

    $rewritten = New-Object System.Collections.Generic.List[string]
    foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $row = $line | ConvertFrom-Json
        if ([string]$row.run_id -ceq $RunId) {
            if ($Remove) {
                $row.PSObject.Properties.Remove($Name)
            }
            else {
                $row | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
            }
        }
        $rewritten.Add(($row | ConvertTo-Json -Depth 20 -Compress))
    }
    [System.IO.File]::WriteAllLines($ledgerPath, $rewritten.ToArray(), [System.Text.UTF8Encoding]::new($false))
}

function Add-FabricatedLedgerRow {
    param([Parameter(Mandatory)]$Row)

    $parent = Split-Path $ledgerPath -Parent
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $json = ($Row | ConvertTo-Json -Depth 20 -Compress) + [Environment]::NewLine
    [System.IO.File]::AppendAllText($ledgerPath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Get-WorktreeKeyLocal {
    param([Parameter(Mandatory)][string]$Path)
    $top = @(Invoke-FixtureGit -Repo $Path -GitArguments @('rev-parse', '--show-toplevel'))
    return (([string]$top[0]) -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
}

function New-ControlledDigestScript {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Digest
    )

    $path = Join-Path $testRoot "$Name.ps1"
    Write-Utf8NoBom -Path $path -Content "Write-Output '$Digest'`nexit 0`n"
    return $path
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

function Invoke-DispatchCase {
    param(
        [Parameter(Mandatory)][string]$CaseName,
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)]$Fixture,
        [string]$FakeRepo,
        [string[]]$Authorized = @('src/a.py'),
        [hashtable]$ExtraParameters = @{},
        [hashtable]$FakeEnvironment = @{},
        [string]$FakePath = $fakeCodex
    )

    $parameters = @{
        Spec = $Spec
        Task = 'critical-file-gate'
        Phase = 'build'
        Worktree = $Fixture.Path
        BaseSha = $Fixture.BaseSha
        Prompt = "Critical-file dispatch case: $CaseName"
        Authorized = @($Authorized)
        ScratchDirectory = $scratchRoot
        CodexExecutable = 'powershell.exe'
        CodexExecutableArgumentPrefix = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FakePath)
    }
    foreach ($entry in $ExtraParameters.GetEnumerator()) {
        $parameters[$entry.Key] = $entry.Value
    }

    foreach ($name in @('FAKE_CODEX_INSCOPE_ONLY', 'FAKE_CODEX_EXTRA_WRITE', 'FAKE_CODEX_STATUS', 'FAKE_CODEX_NO_REPORT', 'FAKE_CODEX_VERDICT')) {
        Set-OptionalEnvironmentValue -Name $name -Value $null
    }
    if ([string]::IsNullOrWhiteSpace($FakeRepo)) { $FakeRepo = $Fixture.Path }
    $env:FAKE_CODEX_REPO = $FakeRepo
    foreach ($entry in $FakeEnvironment.GetEnumerator()) {
        Set-OptionalEnvironmentValue -Name $entry.Key -Value ([string]$entry.Value)
    }

    Write-Host "`n===== CASE: $CaseName =====" -ForegroundColor Cyan
    $captured = @(& $dispatch @parameters *>&1)
    $exitCode = $LASTEXITCODE
    $outputText = @($captured | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
        Write-Host $outputText.TrimEnd()
    }
    Write-Host ("----- {0}: exit {1} -----" -f $CaseName, $exitCode) -ForegroundColor DarkCyan

    return [pscustomobject]@{
        ExitCode = $exitCode
        Rows = @(Get-LedgerRowsForSpec -Spec $Spec)
        Output = $outputText
    }
}

try {
    [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($scratchRoot) | Out-Null
    $scratchGitConfig = Join-Path $testRoot 'gitconfig'
    $scratchGitIgnore = Join-Path $testRoot 'gitignore'
    Write-Utf8NoBom -Path $scratchGitIgnore -Content ''
    $scratchGitIgnoreConfigPath = $scratchGitIgnore -replace '\\', '/'
    Write-Utf8NoBom -Path $scratchGitConfig -Content "[core]`n    excludesFile = $scratchGitIgnoreConfigPath`n"
    $env:GIT_CONFIG_GLOBAL = $scratchGitConfig
    Write-Utf8NoBom -Path $unexpectedClassifier -Content 'exit 7'
    Write-Utf8NoBom -Path $noExitClassifier -Content 'return'
    $cleanReviewFake = Join-Path $testRoot 'clean-review-fake.ps1'
    Write-Utf8NoBom -Path $cleanReviewFake -Content @'
$passThruArgs = $args
[void][Console]::In.ReadToEnd()
$finalPath = $null
for ($i = 0; $i -lt $passThruArgs.Count - 1; $i++) {
    if ($passThruArgs[$i] -eq '-o') { $finalPath = $passThruArgs[$i + 1]; break }
}
$report = [ordered]@{ verdict = 'CLEAN'; findings = @() }
[System.IO.File]::WriteAllText($finalPath, ($report | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
exit 0
'@
    $env:APEX_STATE_DIR = $stateRoot

    # Create every repository before dispatching so no Git process can disturb the deliberate
    # case 3 to case 8 LASTEXITCODE adjacency below.
    $fixtures = @{}
    foreach ($number in 1..19) {
        $extraFiles = @{}
        if ($number -eq 3) {
            $extraFiles['docs\changes\critfile-critical-confirmed.md'] = New-FixtureSpec -Spec 'critfile-critical-confirmed'
        }
        elseif ($number -eq 9) {
            $extraFiles['docs\changes\critfile-noncritical-build.md'] = New-FixtureSpec -Spec 'critfile-noncritical-build'
        }
        $fixtures[$number] = New-FixtureRepo -Name ("case-{0}" -f $number) -ExtraFiles $extraFiles
    }
    $fakeSink = New-FixtureRepo -Name 'case-3-fake-sink'
    $reviewSink = New-FixtureRepo -Name 'review-fake-sink'

    $spec = 'critfile-hardblock-confirmed'
    $result = Invoke-DispatchCase -CaseName '1 HARD-BLOCK confirmed' -Spec $spec -Fixture $fixtures[1] `
        -Authorized @('docs/audit/x.md') -ExtraParameters @{ CriticalFilesConfirmed = $true }
    Assert-Case -Label 'case 1 hard block remains refused' `
        -Condition ($result.ExitCode -eq 76 -and (Test-LeaseScopedRefusal -Result $result -ExitCode 76)) `
        -Detail ("exit={0}, spec rows={1}; expected lease+close and no dispatch" -f $result.ExitCode, $result.Rows.Count)

    $spec = 'critfile-critical-unconfirmed'
    $result = Invoke-DispatchCase -CaseName '2 CRITICAL unconfirmed' -Spec $spec -Fixture $fixtures[2] `
        -Authorized @('config/.env')
    Assert-Case -Label 'case 2 unconfirmed critical file is refused' `
        -Condition ($result.ExitCode -eq 76 -and (Test-LeaseScopedRefusal -Result $result -ExitCode 76)) `
        -Detail ("exit={0}, spec rows={1}; expected lease+close and no dispatch" -f $result.ExitCode, $result.Rows.Count)

    $spec = 'critfile-absolute-host-state-unconfirmed'
    $absoluteStatusPath = Join-Path $fixtures[11].Path 'docs\status.md'
    $expectedCriticalLine = "CRITICAL $(Join-Path 'docs' 'status.md'): host-state"
    $result = Invoke-DispatchCase -CaseName '11 absolute host-state grant unconfirmed' -Spec $spec `
        -Fixture $fixtures[11] -Authorized @($absoluteStatusPath)
    Assert-Case -Label 'case 11 absolute host-state grant is refused by classifier' `
        -Condition ($result.ExitCode -eq 76 -and (Test-LeaseScopedRefusal -Result $result -ExitCode 76) -and
            $result.Output.Contains($expectedCriticalLine)) `
        -Detail ("exit={0}, rows={1}, output contains '{2}'={3}; expected lease refusal and output match=True" -f
            $result.ExitCode, $result.Rows.Count, $expectedCriticalLine, $result.Output.Contains($expectedCriticalLine))

    # The shared fake always edits src/a.py. Direct that fake-only write to a disposable sink so
    # this case can keep the required config/.env-only authorization and finish with exit 0.
    $spec = 'critfile-critical-confirmed'
    $result = Invoke-DispatchCase -CaseName '3 CRITICAL confirmed' -Spec $spec -Fixture $fixtures[3] `
        -FakeRepo $fakeSink.Path -Authorized @('config/.env') -ExtraParameters @{
            CriticalFilesConfirmed = $true
            CriticalFilesConfirmedNote = 'attended tester'
        } -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $row = @($result.Rows) | Select-Object -First 1
    Assert-Case -Label 'case 3 confirmed critical file proceeds and is recorded' `
        -Condition ($result.ExitCode -ne 76 -and $result.Rows.Count -eq 1 -and
            $row.critical_files_confirmed -eq $true -and
            $row.critical_files_confirmed_note -eq 'attended tester') `
        -Detail ("exit={0}, rows={1}, confirmed={2}, note='{3}'" -f $result.ExitCode, $result.Rows.Count,
            $row.critical_files_confirmed, $row.critical_files_confirmed_note)

    # This MUST remain immediately after case 3. No native command runs between the successful
    # dispatcher exit and this invocation, so a classifier that merely returns would expose a
    # stale PowerShell 5.1 LASTEXITCODE of 0 unless the dispatcher resets its sentinel correctly.
    $spec = 'critfile-classifier-no-exit'
    $result = Invoke-DispatchCase -CaseName '8 classifier returns without exit' -Spec $spec -Fixture $fixtures[8] `
        -Authorized @('src/a.py') -ExtraParameters @{ CriticalFilesScript = $noExitClassifier }
    Assert-Case -Label 'case 8 no-exit classifier fails closed after exit 0' `
        -Condition ($result.ExitCode -eq 76 -and (Test-LeaseScopedRefusal -Result $result -ExitCode 76)) `
        -Detail ("exit={0}, spec rows={1}; expected lease+close and no dispatch" -f $result.ExitCode, $result.Rows.Count)

    $spec = 'critfile-critical-skip-baseline'
    $result = Invoke-DispatchCase -CaseName '4 CRITICAL unconfirmed with SkipBaselineCheck' -Spec $spec -Fixture $fixtures[4] `
        -Authorized @('config/.env') -ExtraParameters @{ SkipBaselineCheck = $true }
    Assert-Case -Label 'case 4 baseline bypass does not bypass critical gate' `
        -Condition ($result.ExitCode -eq 76 -and (Test-LeaseScopedRefusal -Result $result -ExitCode 76)) `
        -Detail ("exit={0}, spec rows={1}; expected lease+close and no dispatch" -f $result.ExitCode, $result.Rows.Count)

    $spec = 'critfile-scope-unlocked-unconfirmed'
    $result = Invoke-DispatchCase -CaseName '5 SCOPE-UNLOCKED unconfirmed' -Spec $spec -Fixture $fixtures[5] `
        -Authorized @() -ExtraParameters @{ ScopeUnlocked = $true; ScopeUnlockedReason = 'x' }
    Assert-Case -Label 'case 5 unconfirmed scope unlock is refused' `
        -Condition ($result.ExitCode -eq 76 -and (Test-LeaseScopedRefusal -Result $result -ExitCode 76)) `
        -Detail ("exit={0}, spec rows={1}; expected lease+close and no dispatch" -f $result.ExitCode, $result.Rows.Count)

    $spec = 'critfile-classifier-missing'
    $result = Invoke-DispatchCase -CaseName '6 missing classifier' -Spec $spec -Fixture $fixtures[6] `
        -Authorized @('src/a.py') -ExtraParameters @{ CriticalFilesScript = $missingClassifier }
    Assert-Case -Label 'case 6 missing classifier fails closed' `
        -Condition ($result.ExitCode -eq 76 -and (Test-LeaseScopedRefusal -Result $result -ExitCode 76)) `
        -Detail ("exit={0}, spec rows={1}; expected lease+close and no dispatch" -f $result.ExitCode, $result.Rows.Count)

    $spec = 'critfile-classifier-unexpected-code'
    $result = Invoke-DispatchCase -CaseName '7 classifier returns unexpected code' -Spec $spec -Fixture $fixtures[7] `
        -Authorized @('src/a.py') -ExtraParameters @{ CriticalFilesScript = $unexpectedClassifier }
    Assert-Case -Label 'case 7 unexpected classifier code maps to refusal' `
        -Condition ($result.ExitCode -eq 76 -and (Test-LeaseScopedRefusal -Result $result -ExitCode 76)) `
        -Detail ("exit={0}, spec rows={1}; expected lease+close and no dispatch" -f $result.ExitCode, $result.Rows.Count)

    $spec = 'critfile-noncritical-build'
    $result = Invoke-DispatchCase -CaseName '9 NON-critical build' -Spec $spec -Fixture $fixtures[9] `
        -Authorized @('src/a.py') -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $row = @($result.Rows) | Select-Object -First 1
    Assert-Case -Label 'case 9 non-critical build proceeds with builder family' `
        -Condition ($result.ExitCode -ne 76 -and $result.Rows.Count -eq 1 -and
            $row.critical_files_confirmed -eq $false -and $row.builder_family -eq 'openai') `
        -Detail ("exit={0}, rows={1}, confirmed={2}, builder_family='{3}'" -f $result.ExitCode,
            $result.Rows.Count, $row.critical_files_confirmed, $row.builder_family)

    $spec = 'critfile-review-ledger-fields'
    $result = Invoke-DispatchCase -CaseName '10 REVIEW dispatch' -Spec $spec -Fixture $fixtures[10] `
        -Authorized @() -ExtraParameters @{
            Phase = 'review'
            Schema = 'review'
            ReviewedRunId = 'sentinel-123'
            NoTreePin = $true
            NoTreePinReason = 'review ledger fixture'
        } -FakeEnvironment @{ FAKE_CODEX_VERDICT = 'CLEAN' }
    Assert-Case -Label 'case 10 missing ReviewedRunId target closes its lease' `
        -Condition ($result.ExitCode -eq 78 -and (Test-LeaseScopedRefusal -Result $result -ExitCode 78)) `
        -Detail ("exit={0}, spec rows={1}; expected lease+close and no dispatch" -f $result.ExitCode, $result.Rows.Count)

    # Seed each binding case through a real BUILD dispatch so the source row has the same terminal
    # shape and real end_tree_digest as production. The review fake writes into a separate sink so it
    # cannot move the tree being reviewed.
    $spec = 'critfile-review-digest-mismatch'
    $buildTreePinScript = Join-Path $PSScriptRoot 'tree-pin.ps1'
    $build = Invoke-DispatchCase -CaseName '12a seed real build for mismatch' -Spec $spec -Fixture $fixtures[12] `
        -ExtraParameters @{ SkipBaselineCheck = $true; TreePinScript = $buildTreePinScript } `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $buildRow = @($build.Rows | Where-Object { $_.phase -eq 'build' }) | Select-Object -First 1
    Assert-Case -Label 'build with TreePinScript records an override' `
        -Condition ($build.ExitCode -eq 0 -and $build.Rows.Count -eq 1 -and
            $buildRow.tree_pin_override -eq $true) `
        -Detail ("build={0}, rows={1}, override={2}" -f $build.ExitCode,
            $build.Rows.Count, $buildRow.tree_pin_override)
    $liveDigest = [string]$buildRow.end_tree_digest
    $differentDigest = if ($liveDigest -ceq ('f' * 64)) { 'e' * 64 } else { 'f' * 64 }
    Set-LedgerRowProperty -RunId ([string]$buildRow.run_id) -Name 'end_tree_digest' -Value $differentDigest
    $digestScript = New-ControlledDigestScript -Name 'mismatch-live-digest' -Digest $liveDigest
    $result = Invoke-DispatchCase -CaseName '12b review digest mismatch' -Spec $spec -Fixture $fixtures[12] `
        -FakeRepo $reviewSink.Path -Authorized @() -ExtraParameters @{
            Phase = 'review'; Schema = 'review'; ReviewedRunId = [string]$buildRow.run_id
            NoTreePin = $true; NoTreePinReason = 'controlled mismatch'; TreePinScript = $digestScript
        } -FakeEnvironment @{ FAKE_CODEX_VERDICT = 'CLEAN' }
    $reviewRows = @($result.Rows | Where-Object { $_.phase -eq 'review' })
    $reviewRow = $reviewRows | Select-Object -First 1
    Assert-Case -Label 'review digest mismatch reserves once then fails closed' `
        -Condition ($build.ExitCode -eq 0 -and $liveDigest -cmatch '^[0-9a-f]{64}$' -and
            $result.ExitCode -eq 78 -and $result.Rows.Count -eq 2 -and $reviewRows.Count -eq 1 -and
            $reviewRow.status -eq 'failed' -and $reviewRow.digest_mismatch -eq $true -and
            $reviewRow.tree_pin_override -eq $true) `
        -Detail ("build={0}, review={1}, rows={2}, review_rows={3}, status={4}, mismatch={5}, override={6}" -f
            $build.ExitCode, $result.ExitCode, $result.Rows.Count, $reviewRows.Count, $reviewRow.status,
            $reviewRow.digest_mismatch, $reviewRow.tree_pin_override)

    $spec = 'critfile-review-digest-match'
    $build = Invoke-DispatchCase -CaseName '13a seed real build for match' -Spec $spec -Fixture $fixtures[13] `
        -ExtraParameters @{ SkipBaselineCheck = $true } `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $buildRow = @($build.Rows | Where-Object { $_.phase -eq 'build' }) | Select-Object -First 1
    Assert-Case -Label 'build without TreePinScript records no override' `
        -Condition ($build.ExitCode -eq 0 -and $build.Rows.Count -eq 1 -and
            $buildRow.tree_pin_override -eq $false) `
        -Detail ("build={0}, rows={1}, override={2}" -f $build.ExitCode,
            $build.Rows.Count, $buildRow.tree_pin_override)
    $digestScript = New-ControlledDigestScript -Name 'matching-live-digest' -Digest ([string]$buildRow.end_tree_digest)
    $result = Invoke-DispatchCase -CaseName '13b review digest match' -Spec $spec -Fixture $fixtures[13] `
        -FakeRepo $reviewSink.Path -FakePath $cleanReviewFake -Authorized @() -ExtraParameters @{
            Phase = 'review'; Schema = 'review'; ReviewedRunId = [string]$buildRow.run_id
            NoTreePin = $true; NoTreePinReason = 'controlled match'; TreePinScript = $digestScript
        } -FakeEnvironment @{ FAKE_CODEX_VERDICT = 'CLEAN' }
    $reviewRow = @($result.Rows | Where-Object { $_.phase -eq 'review' }) | Select-Object -First 1
    Assert-Case -Label 'matching review records the build digest and proceeds' `
        -Condition ($build.ExitCode -eq 0 -and $result.ExitCode -eq 0 -and $result.Rows.Count -eq 2 -and
            $reviewRow.reviewed_tree_digest -ceq [string]$buildRow.end_tree_digest -and
            $reviewRow.tree_pin_override -eq $true) `
        -Detail ("build={0}, review={1}, build_digest={2}, reviewed_digest={3}" -f $build.ExitCode,
            $result.ExitCode, $buildRow.end_tree_digest, $reviewRow.reviewed_tree_digest)

    $spec = 'critfile-review-digest-unverifiable'
    $build = Invoke-DispatchCase -CaseName '14a seed real build for unverifiable' -Spec $spec -Fixture $fixtures[14] `
        -ExtraParameters @{ SkipBaselineCheck = $true } `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $buildRow = @($build.Rows | Where-Object { $_.phase -eq 'build' }) | Select-Object -First 1
    Set-LedgerRowProperty -RunId ([string]$buildRow.run_id) -Name 'end_tree_digest' -Value 'unverifiable'
    $digestScript = New-ControlledDigestScript -Name 'unverifiable-unused-digest' -Digest ('a' * 64)
    $result = Invoke-DispatchCase -CaseName '14b review referenced digest unverifiable' -Spec $spec `
        -Fixture $fixtures[14] -FakeRepo $reviewSink.Path -Authorized @() -ExtraParameters @{
            Phase = 'review'; Schema = 'review'; ReviewedRunId = [string]$buildRow.run_id
            NoTreePin = $true; NoTreePinReason = 'unverifiable source'; TreePinScript = $digestScript
        } -FakeEnvironment @{ FAKE_CODEX_VERDICT = 'CLEAN' }
    $reviewRow = @($result.Rows | Where-Object { $_.phase -eq 'review' }) | Select-Object -First 1
    Assert-Case -Label 'unverifiable referenced digest exits 78 after reservation' `
        -Condition ($build.ExitCode -eq 0 -and $result.ExitCode -eq 78 -and $result.Rows.Count -eq 2 -and
            $reviewRow.status -eq 'failed' -and $reviewRow.digest_mismatch -eq $true) `
        -Detail ("build={0}, review={1}, rows={2}, status={3}, mismatch={4}" -f $build.ExitCode,
            $result.ExitCode, $result.Rows.Count, $reviewRow.status, $reviewRow.digest_mismatch)

    $spec = 'critfile-review-digest-legacy'
    $build = Invoke-DispatchCase -CaseName '15a seed real build for legacy row' -Spec $spec -Fixture $fixtures[15] `
        -ExtraParameters @{ SkipBaselineCheck = $true } `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $buildRow = @($build.Rows | Where-Object { $_.phase -eq 'build' }) | Select-Object -First 1
    Set-LedgerRowProperty -RunId ([string]$buildRow.run_id) -Name 'end_tree_digest' -Remove
    $digestScript = New-ControlledDigestScript -Name 'legacy-unused-digest' -Digest ('b' * 64)
    $result = Invoke-DispatchCase -CaseName '15b legacy build row without digest' -Spec $spec `
        -Fixture $fixtures[15] -FakeRepo $reviewSink.Path -FakePath $cleanReviewFake -Authorized @() -ExtraParameters @{
            Phase = 'review'; Schema = 'review'; ReviewedRunId = [string]$buildRow.run_id
            NoTreePin = $true; NoTreePinReason = 'legacy source'; TreePinScript = $digestScript
        } -FakeEnvironment @{ FAKE_CODEX_VERDICT = 'CLEAN' }
    $reviewRow = @($result.Rows | Where-Object { $_.phase -eq 'review' }) | Select-Object -First 1
    Assert-Case -Label 'legacy absent digest warns and proceeds' `
        -Condition ($build.ExitCode -eq 0 -and $result.ExitCode -eq 0 -and $result.Rows.Count -eq 2 -and
            $result.Output.Contains('predates end_tree_digest') -and $reviewRow.status -eq 'done') `
        -Detail ("build={0}, review={1}, rows={2}, warned={3}, status={4}" -f $build.ExitCode,
            $result.ExitCode, $result.Rows.Count, $result.Output.Contains('predates end_tree_digest'), $reviewRow.status)

    # Fabricated dead build rows exercise both adoption gate paths. The live-replay row has a real
    # scope snapshot and a post-snapshot critical write; its recorded confirmation must be used even
    # though the adopt invocation itself carries no confirmation switch.
    $spec = 'critfile-adopt-live-replay'
    $scopeTask = 'fabricated-adopt-live-replay'
    $gateState = Join-Path $stateRoot 'gates'
    [System.IO.Directory]::CreateDirectory($gateState) | Out-Null
    & $scopeCheck -Snapshot -Worktree $fixtures[16].Path -Task $scopeTask -StateDirectory $gateState -Authorized @('src') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "scope snapshot for adopt replay failed with exit $LASTEXITCODE" }
    Add-Content -LiteralPath (Join-Path $fixtures[16].Path 'src\package-lock.json') -Value 'adopted critical write'
    $reportPath = Join-Path $testRoot 'adopt-live-report.json'
    Write-Utf8NoBom -Path $reportPath -Content '{"status":"done","changed_files":["src/package-lock.json"],"commands_run":[],"deviations":[],"unresolved":[],"blocker":null}'
    $runId = 'fabricated-adopt-live-run'
    Add-FabricatedLedgerRow -Row ([ordered]@{
        run_id = $runId; pid = $null; launcher_pid = $null; worktree = $fixtures[16].Path
        worktree_key = (Get-WorktreeKeyLocal $fixtures[16].Path); spec = $spec; task = 'critical-file-gate'
        base_sha = $fixtures[16].BaseSha; phase = 'build'; started = '2026-01-01T00:00:00Z'
        final_path = $reportPath; schema = 'completion'; sandbox = 'workspace-write'; status = 'running'
        scope_armed = $true; scope_task = $scopeTask; authorized = @('src'); tree_pin_label = $null
        critical_files_confirmed = $true; critical_files_confirmed_note = 'recorded attended confirmation'
    })
    $result = Invoke-DispatchCase -CaseName '16 adopt build with live scope replay' -Spec $spec `
        -Fixture $fixtures[16] -ExtraParameters @{ Adopt = $true; CriticalFilesScript = $criticalFiles }
    $row = @($result.Rows) | Select-Object -First 1
    Assert-Case -Label 'adopt live replay records digest and honors row confirmation' `
        -Condition ($result.ExitCode -eq 0 -and $row.status -eq 'adopted-done' -and
            $row.end_tree_digest -cmatch '^[0-9a-f]{64}$' -and $row.critical_violation -eq $false) `
        -Detail ("exit={0}, status={1}, digest={2}, critical={3}" -f $result.ExitCode, $row.status,
            $row.end_tree_digest, $row.critical_violation)

    $spec = 'critfile-adopt-recorded-verdict'
    $reportPath = Join-Path $testRoot 'adopt-recorded-report.json'
    Write-Utf8NoBom -Path $reportPath -Content '{"status":"done","changed_files":[],"commands_run":[],"deviations":[],"unresolved":[],"blocker":null}'
    Add-FabricatedLedgerRow -Row ([ordered]@{
        run_id = 'fabricated-adopt-recorded-run'; pid = $null; launcher_pid = $null; worktree = $fixtures[17].Path
        worktree_key = (Get-WorktreeKeyLocal $fixtures[17].Path); spec = $spec; task = 'critical-file-gate'
        base_sha = $fixtures[17].BaseSha; phase = 'build'; started = '2026-01-01T00:00:00Z'
        final_path = $reportPath; schema = 'completion'; sandbox = 'workspace-write'; status = 'running'
        ended = '2026-01-01T00:01:00Z'; scope_armed = $true; scope_task = 'recorded-scope'
        authorized = @('src/a.py'); scope_exit = 0; tree_pin_label = $null; critical_files_confirmed = $false
    })
    $result = Invoke-DispatchCase -CaseName '17 adopt build with recorded scope verdict' -Spec $spec `
        -Fixture $fixtures[17] -ExtraParameters @{ Adopt = $true; CriticalFilesScript = $criticalFiles }
    $row = @($result.Rows) | Select-Object -First 1
    Assert-Case -Label 'adopt recorded-verdict branch records digest without fabricated classification' `
        -Condition ($result.ExitCode -eq 0 -and $row.status -eq 'adopted-done' -and
            $row.end_tree_digest -cmatch '^[0-9a-f]{64}$' -and
            -not (@($row.PSObject.Properties.Name) -ccontains 'critical_violation') -and
            $result.Output.Contains('post-hoc classification unavailable for pre-completed adopted run')) `
        -Detail ("exit={0}, status={1}, digest={2}, has_critical={3}, note={4}" -f $result.ExitCode,
            $row.status, $row.end_tree_digest, (@($row.PSObject.Properties.Name) -ccontains 'critical_violation'),
            $result.Output.Contains('post-hoc classification unavailable for pre-completed adopted run'))

    $spec = 'critfile-review-pinfirst-bind'
    $build = Invoke-DispatchCase -CaseName '18a seed real build for pin-first bind' -Spec $spec -Fixture $fixtures[18] `
        -ExtraParameters @{ SkipBaselineCheck = $true } `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $buildRow = @($build.Rows | Where-Object { $_.phase -eq 'build' }) | Select-Object -First 1
    $result = Invoke-DispatchCase -CaseName '18b review binds via real pin file' -Spec $spec -Fixture $fixtures[18] `
        -FakeRepo $reviewSink.Path -FakePath $cleanReviewFake -Authorized @() -ExtraParameters @{
            Phase = 'review'; Schema = 'review'; ReviewedRunId = [string]$buildRow.run_id
        } -FakeEnvironment @{ FAKE_CODEX_VERDICT = 'CLEAN' }
    $reviewRow = @($result.Rows | Where-Object { $_.phase -eq 'review' }) | Select-Object -First 1
    Assert-Case -Label 'pin-first review binds via real pin file' `
        -Condition ($build.ExitCode -eq 0 -and $result.ExitCode -eq 0 -and $result.Rows.Count -eq 2 -and
            $reviewRow.reviewed_tree_digest -ceq [string]$buildRow.end_tree_digest -and
            $reviewRow.tree_pin_override -eq $false) `
        -Detail ("build={0}, review={1}, rows={2}, build_digest={3}, reviewed_digest={4}, override={5}" -f
            $build.ExitCode, $result.ExitCode, $result.Rows.Count, $buildRow.end_tree_digest,
            $reviewRow.reviewed_tree_digest, $reviewRow.tree_pin_override)

    $spec = 'critfile-adopt-critical-unconfirmed'
    $scopeTask = 'fabricated-adopt-77-replay'
    $gateState = Join-Path $stateRoot 'gates'
    [System.IO.Directory]::CreateDirectory($gateState) | Out-Null
    & $scopeCheck -Snapshot -Worktree $fixtures[19].Path -Task $scopeTask -StateDirectory $gateState -Authorized @('src') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "scope snapshot for adopt replay failed with exit $LASTEXITCODE" }
    $lockfilePath = Join-Path (Join-Path $fixtures[19].Path 'src') 'package-lock.json'
    Add-Content -LiteralPath $lockfilePath -Value 'adopted critical write'
    $reportPath = Join-Path $testRoot 'adopt-critical-unconfirmed-report.json'
    Write-Utf8NoBom -Path $reportPath -Content '{"status":"done","changed_files":["src/package-lock.json"],"commands_run":[],"deviations":[],"unresolved":[],"blocker":null}'
    $runId = 'fabricated-adopt-critical-unconfirmed-run'
    Add-FabricatedLedgerRow -Row ([ordered]@{
        run_id = $runId; pid = $null; launcher_pid = $null; worktree = $fixtures[19].Path
        worktree_key = (Get-WorktreeKeyLocal $fixtures[19].Path); spec = $spec; task = 'critical-file-gate'
        base_sha = $fixtures[19].BaseSha; phase = 'build'; started = '2026-01-01T00:00:00Z'
        final_path = $reportPath; schema = 'completion'; sandbox = 'workspace-write'; status = 'running'
        scope_armed = $true; scope_task = $scopeTask; authorized = @('src'); tree_pin_label = $null
        critical_files_confirmed = $false
    })
    $result = Invoke-DispatchCase -CaseName '19 adopt live replay unconfirmed critical' -Spec $spec `
        -Fixture $fixtures[19] -ExtraParameters @{ Adopt = $true; CriticalFilesScript = $criticalFiles }
    $row = @($result.Rows) | Select-Object -First 1
    Assert-Case -Label 'adopt live replay unconfirmed critical exits 77' `
        -Condition ($result.ExitCode -eq 77 -and $row.status -eq 'adopted-done' -and
            $row.critical_violation -eq $true) `
        -Detail ("exit={0}, status={1}, critical={2}" -f $result.ExitCode, $row.status,
            $row.critical_violation)
}
catch {
    $script:failureCount++
    Write-Host "`nFAIL  suite setup/execution threw: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}
finally {
    Set-OptionalEnvironmentValue -Name 'APEX_STATE_DIR' -Value $oldApexStateDir
    Set-OptionalEnvironmentValue -Name 'FAKE_CODEX_REPO' -Value $oldFakeRepo
    Set-OptionalEnvironmentValue -Name 'FAKE_CODEX_INSCOPE_ONLY' -Value $oldFakeInScopeOnly
    Set-OptionalEnvironmentValue -Name 'FAKE_CODEX_EXTRA_WRITE' -Value $oldFakeExtraWrite
    Set-OptionalEnvironmentValue -Name 'FAKE_CODEX_STATUS' -Value $oldFakeStatus
    Set-OptionalEnvironmentValue -Name 'FAKE_CODEX_NO_REPORT' -Value $oldFakeNoReport
    Set-OptionalEnvironmentValue -Name 'FAKE_CODEX_VERDICT' -Value $oldFakeVerdict
    Set-OptionalEnvironmentValue -Name 'GIT_CONFIG_GLOBAL' -Value $oldGitConfigGlobal
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n===== CRITICAL-FILE SUITE SUMMARY =====" -ForegroundColor Cyan
Write-Host ("Cases: {0}; failures: {1}" -f $script:assertionCount, $script:failureCount)
if ($script:failureCount -gt 0) { exit 1 }
exit 0
