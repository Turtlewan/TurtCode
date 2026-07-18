# Loud-fail end-to-end coverage for codex-dispatch.ps1's fail-closed scope lock.
# Every fixture repository and harness artifact lives under one fresh temp root, with
# APEX_STATE_DIR kept outside all fixture repositories.

$ErrorActionPreference = 'Stop'

$dispatch = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
$fakeCodex = Join-Path $PSScriptRoot 'dispatch-test-fakecodex.ps1'
foreach ($required in @($dispatch, $fakeCodex)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required test dependency not found: $required"
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("apex-dispatch-scopelock-test-" + [guid]::NewGuid().ToString('N'))
$repoRoot = Join-Path $testRoot 'repos'
$stateRoot = Join-Path $testRoot 'state'
$scratchRoot = Join-Path $stateRoot 'scratch'
$ledgerPath = Join-Path (Join-Path $stateRoot 'progress') 'codex-run-ledger.jsonl'
$logRoot = Join-Path (Join-Path $stateRoot 'progress') 'codex-logs'

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
        [switch]$GreenBaseline,
        [hashtable]$ExtraFiles = @{}
    )

    $repo = Join-Path $repoRoot $Name
    [System.IO.Directory]::CreateDirectory((Join-Path $repo 'src')) | Out-Null
    Write-Utf8NoBom -Path (Join-Path $repo 'src\a.py') -Content "original`n"
    Write-Utf8NoBom -Path (Join-Path $repo 'src\b.py') -Content "original`n"
    if ($GreenBaseline) {
        $greenRecipe = @'
## Verify commands

```
exit 0
```
'@
        Write-Utf8NoBom -Path (Join-Path $repo 'AGENTS.md') -Content $greenRecipe
    }
    foreach ($entry in $ExtraFiles.GetEnumerator()) {
        Write-Utf8NoBom -Path (Join-Path $repo $entry.Key) -Content ([string]$entry.Value)
    }

    Invoke-FixtureGit -Repo $repo -GitArguments @('init', '-q') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('config', 'user.email', 'dispatch-scopelock-test@example.invalid') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('config', 'user.name', 'dispatch-scopelock-test') | Out-Null
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

    return ("scopelock-{0}-{1}" -f $CaseName, [guid]::NewGuid().ToString('N'))
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

function Get-DispatchLogsForSpec {
    param([Parameter(Mandatory)][string]$Spec)

    if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) { return @() }
    $safeSpec = $Spec -replace '[<>:"/\\|?*]', '_'
    return @(Get-ChildItem -LiteralPath $logRoot -Filter "codex-$safeSpec-*" -File -ErrorAction SilentlyContinue)
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
        [Parameter(Mandatory)][string]$Repo,
        [hashtable]$ExtraParameters = @{},
        [hashtable]$FakeEnvironment = @{}
    )

    $parameters = @{
        Spec = $Spec
        Task = 'task-1'
        Phase = 'build'
        Worktree = $Repo
        BaseSha = (Get-FixtureHead -Repo $Repo)
        Prompt = "Scope-lock case: $CaseName"
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
    $env:FAKE_CODEX_REPO = $Repo
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
        Output = $outputText
        Rows = @(Get-LedgerRowsForSpec -Spec $Spec)
        Logs = @(Get-DispatchLogsForSpec -Spec $Spec)
    }
}

try {
    [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
    $env:APEX_STATE_DIR = $stateRoot

    $spec = New-UniqueSpec -CaseName 'no-scope'
    $repo = New-FixtureRepo -Name 'no-scope'
    $result = Invoke-DispatchCase -CaseName 'build without scope list' -Spec $spec -Repo $repo
    Assert-Case -Label 'no-scope exit' -Condition ($result.ExitCode -eq 74) -Detail "expected 74, got $($result.ExitCode)"
    Assert-Case -Label 'no-scope ledger' -Condition ($result.Rows.Count -eq 0) -Detail "expected zero rows, got $($result.Rows.Count)"
    Assert-Case -Label 'no-scope log' -Condition ($result.Logs.Count -eq 0) -Detail "expected zero logs, got $($result.Logs.Count)"
    Assert-Case -Label 'no-scope refusal precedence' -Condition ($result.Output -match 'workspace-write build has no -Authorized scope list') -Detail 'scope refusal ran before baseline pre-flight'

    $spec = New-UniqueSpec -CaseName 'both-flags'
    $repo = New-FixtureRepo -Name 'both-flags'
    $result = Invoke-DispatchCase -CaseName 'Authorized plus ScopeUnlocked' -Spec $spec -Repo $repo -ExtraParameters @{
        Authorized = @('src/a.py')
        ScopeUnlocked = $true
        ScopeUnlockedReason = 'x'
    }
    Assert-Case -Label 'both-flags exit' -Condition ($result.ExitCode -eq 74) -Detail "expected 74, got $($result.ExitCode)"
    Assert-Case -Label 'both-flags ledger' -Condition ($result.Rows.Count -eq 0) -Detail "expected zero rows, got $($result.Rows.Count)"

    $spec = New-UniqueSpec -CaseName 'missing-reason'
    $repo = New-FixtureRepo -Name 'missing-reason'
    $result = Invoke-DispatchCase -CaseName 'ScopeUnlocked without reason' -Spec $spec -Repo $repo -ExtraParameters @{
        ScopeUnlocked = $true
    }
    Assert-Case -Label 'missing-reason exit' -Condition ($result.ExitCode -eq 74) -Detail "expected 74, got $($result.ExitCode)"
    Assert-Case -Label 'missing-reason ledger' -Condition ($result.Rows.Count -eq 0) -Detail "expected zero rows, got $($result.Rows.Count)"

    $spec = New-UniqueSpec -CaseName 'review-both'
    $repo = New-FixtureRepo -Name 'review-both'
    $result = Invoke-DispatchCase -CaseName 'review with both flags' -Spec $spec -Repo $repo -ExtraParameters @{
        Phase = 'review'
        Authorized = @('src/a.py')
        ScopeUnlocked = $true
        ScopeUnlockedReason = 'x'
    }
    Assert-Case -Label 'review both-flags exit' -Condition ($result.ExitCode -eq 74) -Detail "expected 74, got $($result.ExitCode)"
    Assert-Case -Label 'review both-flags ledger' -Condition ($result.Rows.Count -eq 0) -Detail "expected zero rows, got $($result.Rows.Count)"

    $spec = New-UniqueSpec -CaseName 'unlocked'
    $repo = New-FixtureRepo -Name 'unlocked' -GreenBaseline -ExtraFiles @{
        "docs\changes\$spec.md" = (New-FixtureSpec -Spec $spec)
    }
    $result = Invoke-DispatchCase -CaseName 'deliberately unlocked build' -Spec $spec -Repo $repo -ExtraParameters @{
        ScopeUnlocked = $true
        ScopeUnlockedReason = 'bootstrap alpha'
        CriticalFilesConfirmed = $true
    } -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $row = if ($result.Rows.Count -eq 1) { $result.Rows[0] } else { $null }
    $fakeLogText = if ($result.Logs.Count -gt 0) { Get-Content -LiteralPath $result.Logs[0].FullName -Raw } else { '' }
    Assert-Case -Label 'unlocked proceeds' -Condition ($result.ExitCode -ne 74) -Detail "expected not 74, got $($result.ExitCode)"
    Assert-Case -Label 'unlocked reaches fake coder' -Condition ($fakeLogText -match 'FAKE-CODEX: got prompt') -Detail 'dispatch log proves the fake coder received the prompt'
    Assert-Case -Label 'unlocked loud note' -Condition ($result.Output -match 'scope lock DELIBERATELY DISABLED.*bootstrap alpha') -Detail 'deliberate bypass and reason were printed'
    Assert-Case -Label 'unlocked ledger presence' -Condition ($result.Rows.Count -eq 1) -Detail "expected one row, got $($result.Rows.Count)"
    Assert-Case -Label 'unlocked ledger flag' -Condition ($null -ne $row -and $row.scope_unlocked -eq $true) -Detail "scope_unlocked=$($row.scope_unlocked)"
    Assert-Case -Label 'unlocked ledger reason' -Condition ($null -ne $row -and $row.scope_unlocked_reason -eq 'bootstrap alpha') -Detail "scope_unlocked_reason=$($row.scope_unlocked_reason)"

    $spec = New-UniqueSpec -CaseName 'review-exempt'
    $repo = New-FixtureRepo -Name 'review-exempt'
    $result = Invoke-DispatchCase -CaseName 'review without scope flags' -Spec $spec -Repo $repo -ExtraParameters @{
        Phase = 'review'
        Schema = 'review'
        NoTreePin = $true
        NoTreePinReason = 'scope exemption fixture'
    } -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    Assert-Case -Label 'review no-scope exempt' -Condition ($result.ExitCode -ne 74) -Detail "expected not 74, got $($result.ExitCode)"
    Assert-Case -Label 'review forced read-only' -Condition ($result.Rows.Count -eq 1 -and $result.Rows[0].sandbox -eq 'read-only') -Detail "sandbox=$($result.Rows[0].sandbox)"
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

Write-Host "`n===== SCOPE-LOCK SUITE SUMMARY =====" -ForegroundColor Cyan
Write-Host ("Assertions: {0}; failures: {1}" -f $script:assertionCount, $script:failureCount)
if ($script:failureCount -gt 0) {
    Write-Host 'dispatch-scopelock-test.ps1 FAILED' -ForegroundColor Red
    exit 1
}

Write-Host 'dispatch-scopelock-test.ps1 PASSED' -ForegroundColor Green
exit 0
