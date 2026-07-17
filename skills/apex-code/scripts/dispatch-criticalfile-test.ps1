# Loud-fail end-to-end coverage for codex-dispatch.ps1's critical-file gate
# and family-ledger fields. All repositories and state are disposable and live
# under one fresh directory outside this repository.

$ErrorActionPreference = 'Stop'

$dispatch = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
$fakeCodex = Join-Path $PSScriptRoot 'dispatch-test-fakecodex.ps1'
foreach ($required in @($dispatch, $fakeCodex)) {
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
$oldFakeStatus = $env:FAKE_CODEX_STATUS
$oldFakeNoReport = $env:FAKE_CODEX_NO_REPORT
$oldFakeVerdict = $env:FAKE_CODEX_VERDICT

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
    param([Parameter(Mandatory)][string]$Name)

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
        [hashtable]$FakeEnvironment = @{}
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
        CodexExecutableArgumentPrefix = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeCodex)
    }
    foreach ($entry in $ExtraParameters.GetEnumerator()) {
        $parameters[$entry.Key] = $entry.Value
    }

    foreach ($name in @('FAKE_CODEX_INSCOPE_ONLY', 'FAKE_CODEX_STATUS', 'FAKE_CODEX_NO_REPORT', 'FAKE_CODEX_VERDICT')) {
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
    $outputText = ($captured | Out-String)
    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
        Write-Host $outputText.TrimEnd()
    }
    Write-Host ("----- {0}: exit {1} -----" -f $CaseName, $exitCode) -ForegroundColor DarkCyan

    return [pscustomobject]@{
        ExitCode = $exitCode
        Rows = @(Get-LedgerRowsForSpec -Spec $Spec)
    }
}

try {
    [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($scratchRoot) | Out-Null
    Write-Utf8NoBom -Path $unexpectedClassifier -Content 'exit 7'
    Write-Utf8NoBom -Path $noExitClassifier -Content 'return'
    $env:APEX_STATE_DIR = $stateRoot

    # Create every repository before dispatching so no Git process can disturb the deliberate
    # case 3 to case 8 LASTEXITCODE adjacency below.
    $fixtures = @{}
    foreach ($number in 1..10) {
        $fixtures[$number] = New-FixtureRepo -Name ("case-{0}" -f $number)
    }
    $fakeSink = New-FixtureRepo -Name 'case-3-fake-sink'

    $spec = 'critfile-hardblock-confirmed'
    $result = Invoke-DispatchCase -CaseName '1 HARD-BLOCK confirmed' -Spec $spec -Fixture $fixtures[1] `
        -Authorized @('docs/audit/x.md') -ExtraParameters @{ CriticalFilesConfirmed = $true }
    Assert-Case -Label 'case 1 hard block remains refused' `
        -Condition ($result.ExitCode -eq 76 -and $result.Rows.Count -eq 0) `
        -Detail ("exit={0}, rows={1}; expected exit=76, rows=0" -f $result.ExitCode, $result.Rows.Count)

    $spec = 'critfile-critical-unconfirmed'
    $result = Invoke-DispatchCase -CaseName '2 CRITICAL unconfirmed' -Spec $spec -Fixture $fixtures[2] `
        -Authorized @('config/.env')
    Assert-Case -Label 'case 2 unconfirmed critical file is refused' `
        -Condition ($result.ExitCode -eq 76 -and $result.Rows.Count -eq 0) `
        -Detail ("exit={0}, rows={1}; expected exit=76, rows=0" -f $result.ExitCode, $result.Rows.Count)

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
        -Condition ($result.ExitCode -eq 76 -and $result.Rows.Count -eq 0) `
        -Detail ("exit={0}, rows={1}; expected exit=76, rows=0" -f $result.ExitCode, $result.Rows.Count)

    $spec = 'critfile-critical-skip-baseline'
    $result = Invoke-DispatchCase -CaseName '4 CRITICAL unconfirmed with SkipBaselineCheck' -Spec $spec -Fixture $fixtures[4] `
        -Authorized @('config/.env') -ExtraParameters @{ SkipBaselineCheck = $true }
    Assert-Case -Label 'case 4 baseline bypass does not bypass critical gate' `
        -Condition ($result.ExitCode -eq 76 -and $result.Rows.Count -eq 0) `
        -Detail ("exit={0}, rows={1}; expected exit=76, rows=0" -f $result.ExitCode, $result.Rows.Count)

    $spec = 'critfile-scope-unlocked-unconfirmed'
    $result = Invoke-DispatchCase -CaseName '5 SCOPE-UNLOCKED unconfirmed' -Spec $spec -Fixture $fixtures[5] `
        -Authorized @() -ExtraParameters @{ ScopeUnlocked = $true; ScopeUnlockedReason = 'x' }
    Assert-Case -Label 'case 5 unconfirmed scope unlock is refused' `
        -Condition ($result.ExitCode -eq 76 -and $result.Rows.Count -eq 0) `
        -Detail ("exit={0}, rows={1}; expected exit=76, rows=0" -f $result.ExitCode, $result.Rows.Count)

    $spec = 'critfile-classifier-missing'
    $result = Invoke-DispatchCase -CaseName '6 missing classifier' -Spec $spec -Fixture $fixtures[6] `
        -Authorized @('src/a.py') -ExtraParameters @{ CriticalFilesScript = $missingClassifier }
    Assert-Case -Label 'case 6 missing classifier fails closed' `
        -Condition ($result.ExitCode -eq 76 -and $result.Rows.Count -eq 0) `
        -Detail ("exit={0}, rows={1}; expected exit=76, rows=0" -f $result.ExitCode, $result.Rows.Count)

    $spec = 'critfile-classifier-unexpected-code'
    $result = Invoke-DispatchCase -CaseName '7 classifier returns unexpected code' -Spec $spec -Fixture $fixtures[7] `
        -Authorized @('src/a.py') -ExtraParameters @{ CriticalFilesScript = $unexpectedClassifier }
    Assert-Case -Label 'case 7 unexpected classifier code maps to refusal' `
        -Condition ($result.ExitCode -eq 76 -and $result.Rows.Count -eq 0) `
        -Detail ("exit={0}, rows={1}; expected exit=76, rows=0" -f $result.ExitCode, $result.Rows.Count)

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
        } -FakeEnvironment @{ FAKE_CODEX_VERDICT = 'CLEAN' }
    $row = @($result.Rows) | Select-Object -First 1
    Assert-Case -Label 'case 10 review bypasses critical gate and records review linkage' `
        -Condition ($result.ExitCode -ne 76 -and $result.Rows.Count -eq 1 -and
            $row.reviewer_family -eq 'openai' -and [string]::IsNullOrEmpty([string]$row.builder_family) -and
            $row.reviewed_run_id -eq 'sentinel-123') `
        -Detail ("exit={0}, rows={1}, reviewer_family='{2}', builder_family='{3}', reviewed_run_id='{4}'" -f
            $result.ExitCode, $result.Rows.Count, $row.reviewer_family, $row.builder_family, $row.reviewed_run_id)
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
    Set-OptionalEnvironmentValue -Name 'FAKE_CODEX_STATUS' -Value $oldFakeStatus
    Set-OptionalEnvironmentValue -Name 'FAKE_CODEX_NO_REPORT' -Value $oldFakeNoReport
    Set-OptionalEnvironmentValue -Name 'FAKE_CODEX_VERDICT' -Value $oldFakeVerdict
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n===== CRITICAL-FILE SUITE SUMMARY =====" -ForegroundColor Cyan
Write-Host ("Cases: {0}; failures: {1}" -f $script:assertionCount, $script:failureCount)
if ($script:failureCount -gt 0) { exit 1 }
exit 0
