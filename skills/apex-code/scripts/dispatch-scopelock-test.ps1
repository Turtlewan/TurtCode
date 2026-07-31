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
$oldLedgerReplaceLog = $env:APEX_LEDGER_REPLACE_LOG
$oldGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
$oldXdgConfigHome = $env:XDG_CONFIG_HOME

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

function Invoke-WithFixtureLedgerLock {
    param([Parameter(Mandatory)][scriptblock]$Action)

    # The wrapper rewrites this file atomically with File.Replace while holding this named mutex.
    # The race fixtures poll concurrently, so their readers must join that same protocol; otherwise
    # ReadAllLines can collide with the replacement handle before either process has leaked anything.
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

function Get-LedgerRowsForSpec {
    param([Parameter(Mandatory)][string]$Spec)

    if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { return @() }
    $matches = @(Invoke-WithFixtureLedgerLock {
        foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $line | ConvertFrom-Json
            if ([string]$row.spec -eq $Spec) { $row }
        }
    })
    return @($matches)
}

function Get-LedgerRow {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$RowKind
    )

    if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { return $null }
    return Invoke-WithFixtureLedgerLock {
        foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $line | ConvertFrom-Json
            $existingRowKind = if (@($row.PSObject.Properties.Name) -ccontains 'row_kind') {
                [string]$row.row_kind
            }
            else {
                'dispatch'
            }
            if ([string]$row.run_id -ceq $RunId -and $existingRowKind -ceq $RowKind) {
                return $row
            }
        }
        return $null
    }
}

function Add-LedgerRows {
    param([Parameter(Mandatory)][object[]]$Rows)

    [System.IO.Directory]::CreateDirectory((Split-Path $ledgerPath -Parent)) | Out-Null
    $lines = @($Rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 })
    [System.IO.File]::AppendAllText(
        $ledgerPath,
        ($lines -join [Environment]::NewLine) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
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
    $outputText = ($captured | Out-String -Width 10000)
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

function ConvertTo-SingleQuotedPowerShellLiteral {
    param([Parameter(Mandatory)][string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function Start-AdoptProcess {
    param(
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$DigestScript
    )

    $commandParts = @(
        '&'
        (ConvertTo-SingleQuotedPowerShellLiteral -Value $dispatch)
        '-Spec'
        (ConvertTo-SingleQuotedPowerShellLiteral -Value $Spec)
        '-Task'
        (ConvertTo-SingleQuotedPowerShellLiteral -Value 'task-1')
        '-Phase'
        (ConvertTo-SingleQuotedPowerShellLiteral -Value 'build')
        '-Worktree'
        (ConvertTo-SingleQuotedPowerShellLiteral -Value $Repo)
        '-BaseSha'
        (ConvertTo-SingleQuotedPowerShellLiteral -Value $BaseSha)
        '-ScratchDirectory'
        (ConvertTo-SingleQuotedPowerShellLiteral -Value $scratchRoot)
        '-TreePinScript'
        (ConvertTo-SingleQuotedPowerShellLiteral -Value $DigestScript)
        '-Adopt'
        '-RunId'
        (ConvertTo-SingleQuotedPowerShellLiteral -Value $RunId)
        ';'
        'exit'
        '$LASTEXITCODE'
    )
    $encodedCommand = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes(($commandParts -join ' ')))
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Could not start raced adopter process.' }
    return [pscustomobject]@{
        Process = $process
        StandardOutput = $process.StandardOutput.ReadToEndAsync()
        StandardError = $process.StandardError.ReadToEndAsync()
    }
}

function Invoke-AbandonCase {
    param(
        [Parameter(Mandatory)][string]$CaseName,
        [Parameter(Mandatory)][string]$RunId,
        [hashtable]$ExtraParameters = @{}
    )

    $parameters = @{ AbandonRunId = $RunId }
    foreach ($entry in $ExtraParameters.GetEnumerator()) {
        $parameters[$entry.Key] = $entry.Value
    }
    Write-Host "`n===== CASE: $CaseName =====" -ForegroundColor Cyan
    $captured = @(& $dispatch @parameters *>&1)
    $exitCode = $LASTEXITCODE
    $outputText = ($captured | Out-String -Width 10000)
    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
        Write-Host $outputText.TrimEnd()
    }
    Write-Host ("----- {0}: exit {1} -----" -f $CaseName, $exitCode) -ForegroundColor DarkCyan
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $outputText }
}

function Start-AbandonProcess {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Reason
    )

    $commandParts = @(
        '&'
        (ConvertTo-SingleQuotedPowerShellLiteral -Value $dispatch)
        '-Attended'
        '-AbandonRunId'
        (ConvertTo-SingleQuotedPowerShellLiteral -Value $RunId)
        '-AbandonReason'
        (ConvertTo-SingleQuotedPowerShellLiteral -Value $Reason)
        ';'
        'exit'
        '$LASTEXITCODE'
    )
    $encodedCommand = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes(($commandParts -join ' ')))
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Could not start raced abandonment process.' }
    return [pscustomobject]@{
        Process = $process
        StandardOutput = $process.StandardOutput.ReadToEndAsync()
        StandardError = $process.StandardError.ReadToEndAsync()
    }
}

try {
    [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
    $env:APEX_STATE_DIR = $stateRoot
    $env:GIT_CONFIG_GLOBAL = Join-Path $testRoot 'gitconfig'
    Write-Utf8NoBom -Path $env:GIT_CONFIG_GLOBAL -Content ''
    $env:XDG_CONFIG_HOME = Join-Path $testRoot 'xdg'
    [System.IO.Directory]::CreateDirectory($env:XDG_CONFIG_HOME) | Out-Null

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

    $spec = New-UniqueSpec -CaseName 'orphan-batch'
    $repo = New-FixtureRepo -Name 'orphan-batch'
    $baseSha = Get-FixtureHead -Repo $repo
    $worktreeKey = ([string]@(Invoke-FixtureGit -Repo $repo -GitArguments @('rev-parse', '--show-toplevel'))[0]).
        Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    $deadStamp = ([datetime]::UtcNow.AddDays(-2)).ToString('o')
    $runningRunId = [guid]::NewGuid().ToString('N')
    $stalledRunId = [guid]::NewGuid().ToString('N')
    $openLeaseRunId = [guid]::NewGuid().ToString('N')
    $closedLeaseRunId = [guid]::NewGuid().ToString('N')
    $runningFinalPath = Join-Path $scratchRoot "$runningRunId.final"
    $seedRows = @(
        [ordered]@{
            run_id = $runningRunId; row_kind = 'dispatch'; status = 'running'
            launcher_pid = 2147483646; launcher_start = $deadStamp
            pid = 2147483645; pid_start = $deadStamp
            worktree = $repo; worktree_key = $worktreeKey
            spec = $spec; task = 'task-1'; phase = 'build'; sandbox = 'workspace-write'
            started = $deadStamp; effort = 'medium'; base_sha = $baseSha
            final_path = $runningFinalPath; schema = 'codex-completion-schema.json'
            scope_armed = $false; scope_task = 'orphan-recovery'; authorized = @()
            critical_files_confirmed = $false
        },
        [ordered]@{
            run_id = $stalledRunId; row_kind = 'dispatch'; status = 'stalled'
            launcher_pid = 2147483646; launcher_start = $deadStamp
            pid = 2147483645; pid_start = $deadStamp
            worktree = $repo; worktree_key = $worktreeKey
            spec = $spec; task = 'task-2'; phase = 'build'; sandbox = 'workspace-write'
            started = ([datetime]::UtcNow.AddDays(-1)).ToString('o'); effort = 'medium'
        },
        [ordered]@{
            run_id = $openLeaseRunId; row_kind = 'lease'; status = 'leasing'
            launcher_pid = 2147483646; launcher_start = $deadStamp
            worktree = $repo; worktree_key = $worktreeKey
            spec = $spec; task = 'task-3'; phase = 'build'; sandbox = 'workspace-write'
            started = ([datetime]::UtcNow.AddHours(-12)).ToString('o'); effort = 'medium'
        }
    )
    $closedLeaseRow = [ordered]@{
        run_id = $closedLeaseRunId; row_kind = 'lease'; status = 'leasing'
        launcher_pid = 2147483646; launcher_start = $deadStamp
        worktree = $repo; worktree_key = $worktreeKey
        spec = $spec; task = 'closed-lease'; phase = 'build'; sandbox = 'workspace-write'
        started = $deadStamp; effort = 'medium'
    }
    $closedLeaseCloseRow = [ordered]@{
        run_id = $closedLeaseRunId; row_kind = 'lease_close'
        status = 'refused-preflight'; ended = ([datetime]::UtcNow.AddDays(-1)).ToString('o')
    }
    $seedLines = @($seedRows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 })
    $closedLeaseLine = $closedLeaseRow | ConvertTo-Json -Compress -Depth 8
    $closedLeaseCloseLine = $closedLeaseCloseRow | ConvertTo-Json -Compress -Depth 8
    $seedLines += $closedLeaseLine
    $seedLines += $closedLeaseCloseLine
    [System.IO.File]::AppendAllText(
        $ledgerPath,
        ($seedLines -join [Environment]::NewLine) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )

    $replaceLogPath = Join-Path $stateRoot 'ledger-replace.log'
    $env:APEX_LEDGER_REPLACE_LOG = $replaceLogPath
    $missingCriticalScript = Join-Path $testRoot 'missing-critical-script.ps1'
    $result = Invoke-DispatchCase -CaseName 'dead rows become orphaned in one batch' `
        -Spec $spec -Repo $repo -ExtraParameters @{
            ScopeUnlocked = $true
            ScopeUnlockedReason = 'orphan scan fixture'
            CriticalFilesScript = $missingCriticalScript
        }
    Assert-Case -Label 'orphan scan reaches post-lease refusal' -Condition ($result.ExitCode -eq 76) -Detail "expected 76, got $($result.ExitCode)"

    $runningRow = Get-LedgerRow -RunId $runningRunId -RowKind 'dispatch'
    $stalledRow = Get-LedgerRow -RunId $stalledRunId -RowKind 'dispatch'
    $openLeaseRow = Get-LedgerRow -RunId $openLeaseRunId -RowKind 'lease'
    foreach ($orphanResult in @(
            [pscustomobject]@{ Label = 'running'; Row = $runningRow },
            [pscustomobject]@{ Label = 'stalled'; Row = $stalledRow },
            [pscustomobject]@{ Label = 'open lease'; Row = $openLeaseRow }
        )) {
        $hasEnded = $null -ne $orphanResult.Row -and
            @($orphanResult.Row.PSObject.Properties.Name) -ccontains 'ended'
        Assert-Case -Label "$($orphanResult.Label) becomes orphaned" `
            -Condition ($null -ne $orphanResult.Row -and
                [string]$orphanResult.Row.status -ceq 'orphaned' -and
                -not [string]::IsNullOrWhiteSpace([string]$orphanResult.Row.orphaned_at) -and
                -not $hasEnded) `
            -Detail "status=$($orphanResult.Row.status); ended present=$hasEnded"
    }

    $ledgerLinesAfterScan = [System.IO.File]::ReadAllLines($ledgerPath)
    Assert-Case -Label 'closed lease row bytes preserved' `
        -Condition ($ledgerLinesAfterScan -ccontains $closedLeaseLine) `
        -Detail 'the refused-and-closed lease line is byte-for-byte unchanged'
    Assert-Case -Label 'lease close row bytes preserved' `
        -Condition ($ledgerLinesAfterScan -ccontains $closedLeaseCloseLine) `
        -Detail 'the matching lease_close line is byte-for-byte unchanged'
    $closedLeaseAfterScan = Get-LedgerRow -RunId $closedLeaseRunId -RowKind 'lease'
    Assert-Case -Label 'closed lease is not orphaned' `
        -Condition ($null -ne $closedLeaseAfterScan -and
            [string]$closedLeaseAfterScan.status -ceq 'leasing' -and
            @($closedLeaseAfterScan.PSObject.Properties.Name) -cnotcontains 'orphaned_at') `
        -Detail "status=$($closedLeaseAfterScan.status)"

    $replaceLogLines = @([System.IO.File]::ReadAllLines($replaceLogPath))
    Assert-Case -Label 'three rows use one rewrite pass' `
        -Condition ($replaceLogLines.Count -eq 1 -and $replaceLogLines[0] -match '\|OrphanScan\|3$') `
        -Detail "replace log: $($replaceLogLines -join '; ')"
    Assert-Case -Label 'dispatch recovery line printed' `
        -Condition ($result.Output -match "\[dispatch\] ORPHANED RUN $runningRunId .* -Adopt -RunId $runningRunId ") `
        -Detail 'the line identifies the exact orphaned dispatch'
    Assert-Case -Label 'lease recovery line printed' `
        -Condition ($result.Output -match "\[dispatch\] ORPHANED LEASE $openLeaseRunId .* -Attended -AbandonRunId $openLeaseRunId ") `
        -Detail 'the line identifies the exact orphaned lease'

    $replaceCountBeforeRescan = $replaceLogLines.Count
    $rescanSpec = New-UniqueSpec -CaseName 'orphan-idempotent'
    $rescanResult = Invoke-DispatchCase -CaseName 'orphan scan is idempotent' `
        -Spec $rescanSpec -Repo $repo -ExtraParameters @{
            ScopeUnlocked = $true
            ScopeUnlockedReason = 'orphan rescan fixture'
            CriticalFilesScript = $missingCriticalScript
        }
    $replaceCountAfterRescan = @([System.IO.File]::ReadAllLines($replaceLogPath)).Count
    Assert-Case -Label 'idempotent rescan exit' -Condition ($rescanResult.ExitCode -eq 76) -Detail "expected 76, got $($rescanResult.ExitCode)"
    Assert-Case -Label 'idempotent rescan performs no rewrite' `
        -Condition ($replaceCountAfterRescan -eq $replaceCountBeforeRescan) `
        -Detail "replace lines before=$replaceCountBeforeRescan after=$replaceCountAfterRescan"

    $dispatchRecoveryLine = @($result.Output -split '\r?\n' |
        Where-Object { $_ -match "\[dispatch\] ORPHANED RUN $runningRunId " })[0]
    $dispatchRecoveryCommand = $dispatchRecoveryLine.Substring(
        $dispatchRecoveryLine.IndexOf('powershell -NoProfile'))
    $dispatchRecoveryOutput = @(& ([scriptblock]::Create($dispatchRecoveryCommand)) *>&1)
    $dispatchRecoveryExit = $LASTEXITCODE
    $recoveredDispatch = Get-LedgerRow -RunId $runningRunId -RowKind 'dispatch'
    Assert-Case -Label 'printed dispatch recovery command runs verbatim' `
        -Condition ($dispatchRecoveryExit -eq 67 -and
            [string]$recoveredDispatch.status -ceq 'adopted-blocked') `
        -Detail "exit=$dispatchRecoveryExit status=$($recoveredDispatch.status); output=$($dispatchRecoveryOutput -join ' ')"

    $leaseRecoveryLine = @($result.Output -split '\r?\n' |
        Where-Object { $_ -match "\[dispatch\] ORPHANED LEASE $openLeaseRunId " })[0]
    $leaseRecoveryCommand = $leaseRecoveryLine.Substring(
        $leaseRecoveryLine.IndexOf('powershell -NoProfile'))
    $leaseRecoveryOutput = @(& ([scriptblock]::Create($leaseRecoveryCommand)) *>&1)
    $leaseRecoveryExit = $LASTEXITCODE
    $recoveredLease = Get-LedgerRow -RunId $openLeaseRunId -RowKind 'lease'
    Assert-Case -Label 'printed lease recovery command runs verbatim' `
        -Condition ($leaseRecoveryExit -eq 0 -and
            [string]$recoveredLease.status -ceq 'abandoned-unadopted' -and
            (@($recoveredLease.waived_gates) -join ',') -ceq 'scope,critical,digest,pin,encoding' -and
            -not [string]::IsNullOrWhiteSpace([string]$recoveredLease.abandon_reason)) `
        -Detail "exit=$leaseRecoveryExit status=$($recoveredLease.status); output=$($leaseRecoveryOutput -join ' ')"

    $spec = New-UniqueSpec -CaseName 'adopt-exact-row'
    $repo = New-FixtureRepo -Name 'adopt-exact-row'
    $baseSha = Get-FixtureHead -Repo $repo
    $worktreeKey = ([string]@(Invoke-FixtureGit -Repo $repo -GitArguments @('rev-parse', '--show-toplevel'))[0]).
        Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    $olderRunId = [guid]::NewGuid().ToString('N')
    $newerRunId = [guid]::NewGuid().ToString('N')
    $leaseRunId = [guid]::NewGuid().ToString('N')
    $adoptFixtureBase = [ordered]@{
        launcher_pid = 2147483646; launcher_start = $deadStamp
        pid = 2147483645; pid_start = $deadStamp
        worktree = $repo; worktree_key = $worktreeKey
        spec = $spec; task = 'task-1'; phase = 'build'; sandbox = 'workspace-write'
        effort = 'medium'; base_sha = $baseSha; schema = 'codex-completion-schema.json'
        scope_armed = $false; scope_task = 'adopt-exact-row'; authorized = @()
        critical_files_confirmed = $false
    }
    $olderDispatch = [ordered]@{} + $adoptFixtureBase
    $olderDispatch['run_id'] = $olderRunId
    $olderDispatch['row_kind'] = 'dispatch'
    $olderDispatch['status'] = 'orphaned'
    $olderDispatch['started'] = ([datetime]::UtcNow.AddHours(-3)).ToString('o')
    $olderDispatch['orphaned_at'] = ([datetime]::UtcNow.AddHours(-2)).ToString('o')
    $olderDispatch['final_path'] = Join-Path $scratchRoot "$olderRunId.final"
    $newerDispatch = [ordered]@{} + $adoptFixtureBase
    $newerDispatch['run_id'] = $newerRunId
    $newerDispatch['row_kind'] = 'dispatch'
    $newerDispatch['status'] = 'orphaned'
    $newerDispatch['started'] = ([datetime]::UtcNow.AddHours(-2)).ToString('o')
    $newerDispatch['orphaned_at'] = ([datetime]::UtcNow.AddHours(-1)).ToString('o')
    $newerDispatch['final_path'] = Join-Path $scratchRoot "$newerRunId.final"
    $newestLease = [ordered]@{} + $adoptFixtureBase
    $newestLease['run_id'] = $leaseRunId
    $newestLease['row_kind'] = 'lease'
    $newestLease['status'] = 'orphaned'
    $newestLease['started'] = ([datetime]::UtcNow.AddHours(-1)).ToString('o')
    $newestLease['orphaned_at'] = ([datetime]::UtcNow.AddMinutes(-30)).ToString('o')
    Add-LedgerRows -Rows @($olderDispatch, $newerDispatch, $newestLease)

    $result = Invoke-DispatchCase -CaseName 'RunId adopts exact older orphan' `
        -Spec $spec -Repo $repo -ExtraParameters @{
            Adopt = $true
            RunId = $olderRunId
        }
    $olderAfterExactAdopt = Get-LedgerRow -RunId $olderRunId -RowKind 'dispatch'
    $newerAfterExactAdopt = Get-LedgerRow -RunId $newerRunId -RowKind 'dispatch'
    Assert-Case -Label 'RunId exact-row adoption exit' `
        -Condition ($result.ExitCode -eq 67) `
        -Detail "expected blocked fixture exit 67, got $($result.ExitCode)"
    Assert-Case -Label 'RunId selects older named row' `
        -Condition ([string]$olderAfterExactAdopt.status -ceq 'adopted-blocked') `
        -Detail "older status=$($olderAfterExactAdopt.status)"
    Assert-Case -Label 'RunId ignores newer matching row' `
        -Condition ([string]$newerAfterExactAdopt.status -ceq 'orphaned') `
        -Detail "newer status=$($newerAfterExactAdopt.status)"

    $result = Invoke-DispatchCase -CaseName 'orphan adoption excludes newest lease row' `
        -Spec $spec -Repo $repo -ExtraParameters @{ Adopt = $true }
    $newerAfterNewestAdopt = Get-LedgerRow -RunId $newerRunId -RowKind 'dispatch'
    $leaseAfterAdopt = Get-LedgerRow -RunId $leaseRunId -RowKind 'lease'
    Assert-Case -Label 'orphan dispatch reaches existing adopt gates' `
        -Condition ($result.ExitCode -eq 67 -and
            [string]$newerAfterNewestAdopt.status -ceq 'adopted-blocked') `
        -Detail "exit=$($result.ExitCode) dispatch status=$($newerAfterNewestAdopt.status)"
    Assert-Case -Label 'orphan lease is not selectable' `
        -Condition ([string]$leaseAfterAdopt.status -ceq 'orphaned' -and
            @($leaseAfterAdopt.PSObject.Properties.Name) -cnotcontains 'adopted') `
        -Detail "lease status=$($leaseAfterAdopt.status)"

    $spec = New-UniqueSpec -CaseName 'adopt-race'
    $repo = New-FixtureRepo -Name 'adopt-race'
    $baseSha = Get-FixtureHead -Repo $repo
    $worktreeKey = ([string]@(Invoke-FixtureGit -Repo $repo -GitArguments @('rev-parse', '--show-toplevel'))[0]).
        Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    $raceRunId = [guid]::NewGuid().ToString('N')
    $raceRow = [ordered]@{
        run_id = $raceRunId; row_kind = 'dispatch'; status = 'orphaned'
        launcher_pid = 2147483646; launcher_start = $deadStamp
        pid = 2147483645; pid_start = $deadStamp
        worktree = $repo; worktree_key = $worktreeKey
        spec = $spec; task = 'task-1'; phase = 'build'; sandbox = 'workspace-write'
        started = ([datetime]::UtcNow.AddHours(-2)).ToString('o')
        orphaned_at = ([datetime]::UtcNow.AddHours(-1)).ToString('o')
        effort = 'medium'; base_sha = $baseSha
        final_path = (Join-Path $scratchRoot "$raceRunId.final")
        schema = 'codex-completion-schema.json'
        scope_armed = $false; scope_task = 'adopt-race'; authorized = @()
        critical_files_confirmed = $false
    }
    Add-LedgerRows -Rows @($raceRow)
    $slowDigestScript = Join-Path $testRoot 'slow-digest.ps1'
    Write-Utf8NoBom -Path $slowDigestScript -Content @'
[CmdletBinding()]
param([switch]$Digest, [Parameter(Mandatory)][string]$Worktree)
if (-not $Digest) { throw 'This fixture supports only -Digest.' }
Start-Sleep -Seconds 3
'0000000000000000000000000000000000000000000000000000000000000000'
'@
    $raceAdopter1 = Start-AdoptProcess -Spec $spec -Repo $repo -BaseSha $baseSha `
        -RunId $raceRunId -DigestScript $slowDigestScript
    $raceAdopter2 = Start-AdoptProcess -Spec $spec -Repo $repo -BaseSha $baseSha `
        -RunId $raceRunId -DigestScript $slowDigestScript
    $raceAdopter1.Process.WaitForExit()
    $raceAdopter2.Process.WaitForExit()
    $raceAdopter1.Process.Refresh()
    $raceAdopter2.Process.Refresh()
    $raceExitCodes = @($raceAdopter1.Process.ExitCode, $raceAdopter2.Process.ExitCode)
    $raceOutputs = @(
        ([string]$raceAdopter1.StandardOutput.Result + [string]$raceAdopter1.StandardError.Result),
        ([string]$raceAdopter2.StandardOutput.Result + [string]$raceAdopter2.StandardError.Result)
    )
    $raceLiveRefusalCount = @($raceOutputs | Where-Object {
        $_ -match "status 'adopting'\. Nothing to adopt\."
    }).Count
    $raceAfter = Get-LedgerRow -RunId $raceRunId -RowKind 'dispatch'
    Assert-Case -Label 'raced adopters have one winner and one exit 75 loser' `
        -Condition ((@($raceExitCodes | Sort-Object) -join ',') -ceq '67,75' -and
            $raceLiveRefusalCount -eq 1) `
        -Detail "exit codes=$($raceExitCodes -join ','); adopting refusals=$raceLiveRefusalCount"
    Assert-Case -Label 'raced orphan closes exactly once' `
        -Condition ([string]$raceAfter.status -ceq 'adopted-blocked' -and
            $raceAfter.adopted -eq $true -and
            @((Get-LedgerRowsForSpec -Spec $spec)).Count -eq 1) `
        -Detail "status=$($raceAfter.status) rows=$(@((Get-LedgerRowsForSpec -Spec $spec)).Count)"

    $spec = New-UniqueSpec -CaseName 'unresolved-worktree'
    $repo = New-FixtureRepo -Name 'unresolved-worktree' -GreenBaseline -ExtraFiles @{
        "docs\changes\$spec.md" = (New-FixtureSpec -Spec $spec)
    }
    $baseSha = Get-FixtureHead -Repo $repo
    $worktreeKey = ([string]@(Invoke-FixtureGit -Repo $repo -GitArguments @('rev-parse', '--show-toplevel'))[0]).
        Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    $unresolvedRunId = [guid]::NewGuid().ToString('N')
    Add-LedgerRows -Rows @([ordered]@{
        run_id = $unresolvedRunId; row_kind = 'dispatch'; status = 'orphaned'
        launcher_pid = 2147483646; launcher_start = $deadStamp
        pid = 2147483645; pid_start = $deadStamp
        worktree = $repo; worktree_key = $worktreeKey
        spec = $spec; task = 'task-1'; phase = 'build'; sandbox = 'workspace-write'
        started = $deadStamp; orphaned_at = ([datetime]::UtcNow.AddDays(-1)).ToString('o')
        effort = 'medium'; base_sha = $baseSha
    })
    $result = Invoke-DispatchCase -CaseName 'orphaned worktree refuses redispatch' `
        -Spec $spec -Repo $repo -ExtraParameters @{
            Authorized = @('src/a.py')
        }
    $unresolvedRows = @(Get-LedgerRowsForSpec -Spec $spec)
    $refusalRows = @($unresolvedRows | Where-Object {
        [string]$_.row_kind -ceq 'lease_close' -and
        [string]$_.status -ceq 'refused-preflight' -and
        [int]$_.refusal_exit -eq 80
    })
    $newLeaseRows = @($unresolvedRows | Where-Object { [string]$_.row_kind -ceq 'lease' })
    if ($newLeaseRows.Count -eq 1) {
        $matchingClose = Get-LedgerRow -RunId ([string]$newLeaseRows[0].run_id) -RowKind 'lease_close'
        if ($null -ne $matchingClose -and
                [string]$matchingClose.status -ceq 'refused-preflight' -and
                [int]$matchingClose.refusal_exit -eq 80) {
            $refusalRows = @($matchingClose)
        }
    }
    $newDispatchRows = @($unresolvedRows | Where-Object {
        [string]$_.row_kind -ceq 'dispatch' -and [string]$_.run_id -cne $unresolvedRunId
    })
    Assert-Case -Label 'unresolved worktree exits exact refusal 80' `
        -Condition ($result.ExitCode -eq 80) -Detail "expected 80, got $($result.ExitCode)"
    Assert-Case -Label 'exit 80 writes no dispatch row or log' `
        -Condition ($newDispatchRows.Count -eq 0 -and $result.Logs.Count -eq 0) `
        -Detail "new dispatch rows=$($newDispatchRows.Count) logs=$($result.Logs.Count)"
    Assert-Case -Label 'exit 80 has exactly one outer-finally refusal close' `
        -Condition ($refusalRows.Count -eq 1) -Detail "refused-preflight/80 rows=$($refusalRows.Count)"
    Assert-Case -Label 'exit 80 prints both recovery commands and observed row' `
        -Condition ($result.Output -match "run_id=$unresolvedRunId, status=orphaned" -and
            $result.Output -match "-Adopt -RunId $unresolvedRunId " -and
            $result.Output -match "-AbandonRunId $unresolvedRunId " -and
            $result.Output -notmatch '-File "\{0\}"') `
        -Detail 'run id, status, adopt command, and abandonment command are present'

    $sharedResult = Invoke-DispatchCase -CaseName 'shared-worktree cannot override unresolved row' `
        -Spec $spec -Repo $repo -ExtraParameters @{
            Authorized = @('src/a.py')
            AllowSharedWorktree = $true
            AllowSharedWorktreeReason = 'must not waive exit 80'
        }
    Assert-Case -Label 'AllowSharedWorktree does not override exit 80' `
        -Condition ($sharedResult.ExitCode -eq 80) `
        -Detail "expected 80, got $($sharedResult.ExitCode)"

    $spec = New-UniqueSpec -CaseName 'abandon'
    $repo = New-FixtureRepo -Name 'abandon' -GreenBaseline -ExtraFiles @{
        "docs\changes\$spec.md" = (New-FixtureSpec -Spec $spec)
    }
    $baseSha = Get-FixtureHead -Repo $repo
    $worktreeKey = ([string]@(Invoke-FixtureGit -Repo $repo -GitArguments @('rev-parse', '--show-toplevel'))[0]).
        Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    $abandonRunId = [guid]::NewGuid().ToString('N')
    Add-LedgerRows -Rows @([ordered]@{
        run_id = $abandonRunId; row_kind = 'dispatch'; status = 'orphaned'
        launcher_pid = 2147483646; launcher_start = $deadStamp
        pid = 2147483645; pid_start = $deadStamp
        worktree = $repo; worktree_key = $worktreeKey
        spec = $spec; task = 'task-1'; phase = 'build'; sandbox = 'workspace-write'
        started = $deadStamp; orphaned_at = ([datetime]::UtcNow.AddDays(-1)).ToString('o')
        effort = 'medium'; base_sha = $baseSha
    })

    foreach ($reasonCase in @(
            [pscustomobject]@{ Label = 'missing'; Parameters = @{ Attended = $true } },
            [pscustomobject]@{ Label = 'empty'; Parameters = @{ Attended = $true; AbandonReason = '' } },
            [pscustomobject]@{ Label = 'whitespace'; Parameters = @{ Attended = $true; AbandonReason = '   ' } }
        )) {
        $ledgerBefore = [System.IO.File]::ReadAllText($ledgerPath)
        $reasonResult = Invoke-AbandonCase -CaseName "$($reasonCase.Label) abandonment reason" `
            -RunId $abandonRunId -ExtraParameters $reasonCase.Parameters
        $ledgerAfter = [System.IO.File]::ReadAllText($ledgerPath)
        Assert-Case -Label "$($reasonCase.Label) abandonment reason exits 74 without mutation" `
            -Condition ($reasonResult.ExitCode -eq 74 -and $ledgerAfter -ceq $ledgerBefore) `
            -Detail "exit=$($reasonResult.ExitCode) ledger unchanged=$($ledgerAfter -ceq $ledgerBefore)"
    }

    foreach ($attendanceCase in @(
            [pscustomobject]@{ Label = 'omitted'; Parameters = @{ AbandonReason = 'operator decision' } },
            [pscustomobject]@{ Label = 'explicit false'; Parameters = @{
                Attended = $false; AbandonReason = 'operator decision'
            } }
        )) {
        $ledgerBefore = [System.IO.File]::ReadAllText($ledgerPath)
        $attendanceResult = Invoke-AbandonCase -CaseName "$($attendanceCase.Label) attendance" `
            -RunId $abandonRunId -ExtraParameters $attendanceCase.Parameters
        $ledgerAfter = [System.IO.File]::ReadAllText($ledgerPath)
        Assert-Case -Label "$($attendanceCase.Label) attendance exits 83 without mutation" `
            -Condition ($attendanceResult.ExitCode -eq 83 -and $ledgerAfter -ceq $ledgerBefore) `
            -Detail "exit=$($attendanceResult.ExitCode) ledger unchanged=$($ledgerAfter -ceq $ledgerBefore)"
    }

    Write-Utf8NoBom -Path (Join-Path $repo 'operator-draft.txt') -Content "not committed`n"
    $ledgerBeforeDirtyAbandon = [System.IO.File]::ReadAllText($ledgerPath)
    $dirtyAbandon = Invoke-AbandonCase -CaseName 'dirty orphan cannot be abandoned' `
        -RunId $abandonRunId -ExtraParameters @{
            Attended = $true
            AbandonReason = 'operator inspected recovery'
        }
    $ledgerAfterDirtyAbandon = [System.IO.File]::ReadAllText($ledgerPath)
    Assert-Case -Label 'dirty dispatch abandonment exits 82 without mutation' `
        -Condition ($dirtyAbandon.ExitCode -eq 82 -and
            $ledgerAfterDirtyAbandon -ceq $ledgerBeforeDirtyAbandon -and
            $dirtyAbandon.Output -match 'operator-draft\.txt') `
        -Detail "exit=$($dirtyAbandon.ExitCode) ledger unchanged=$($ledgerAfterDirtyAbandon -ceq $ledgerBeforeDirtyAbandon)"

    Remove-Item -LiteralPath (Join-Path $repo 'operator-draft.txt') -Force
    $cleanAbandon = Invoke-AbandonCase -CaseName 'clean orphan abandonment' `
        -RunId $abandonRunId -ExtraParameters @{
            Attended = $true
            AbandonReason = 'operator accepts gate waiver'
        }
    $abandonedRow = Get-LedgerRow -RunId $abandonRunId -RowKind 'dispatch'
    Assert-Case -Label 'clean abandonment records explicit gate waiver' `
        -Condition ($cleanAbandon.ExitCode -eq 0 -and
            [string]$abandonedRow.status -ceq 'abandoned-unadopted' -and
            -not [string]::IsNullOrWhiteSpace([string]$abandonedRow.ended) -and
            [string]$abandonedRow.abandon_reason -ceq 'operator accepts gate waiver' -and
            (@($abandonedRow.waived_gates) -join ',') -ceq 'scope,critical,digest,pin,encoding') `
        -Detail "exit=$($cleanAbandon.ExitCode) status=$($abandonedRow.status) gates=$(@($abandonedRow.waived_gates) -join ',')"
    Assert-Case -Label 'abandonment prints attended-only doctrine verbatim' `
        -Condition ($cleanAbandon.Output -match [regex]::Escape(
            '[dispatch] -AbandonRunId is an ATTENDED-ONLY escape: it waives scope/critical/digest/pin/encoding without running them. An AFK run must park instead.')) `
        -Detail 'verbatim doctrine line is present'

    $result = Invoke-DispatchCase -CaseName 'dispatch after clean abandonment' `
        -Spec $spec -Repo $repo -ExtraParameters @{ Authorized = @('src/a.py') } `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    Assert-Case -Label 'clean abandoned worktree can dispatch again' `
        -Condition ($result.ExitCode -eq 0 -and $result.Logs.Count -eq 1) `
        -Detail "exit=$($result.ExitCode) logs=$($result.Logs.Count)"

    $leaseRepo = New-FixtureRepo -Name 'dirty-lease-abandon'
    $leaseKey = ([string]@(Invoke-FixtureGit -Repo $leaseRepo -GitArguments @('rev-parse', '--show-toplevel'))[0]).
        Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    $dirtyLeaseRunId = [guid]::NewGuid().ToString('N')
    Add-LedgerRows -Rows @([ordered]@{
        run_id = $dirtyLeaseRunId; row_kind = 'lease'; status = 'orphaned'
        launcher_pid = 2147483646; launcher_start = $deadStamp
        worktree = $leaseRepo; worktree_key = $leaseKey
        spec = (New-UniqueSpec -CaseName 'dirty-lease'); task = 'task-1'
        phase = 'build'; sandbox = 'workspace-write'; started = $deadStamp; effort = 'medium'
    })
    Write-Utf8NoBom -Path (Join-Path $leaseRepo 'dirty.txt') -Content "dirty lease tree`n"
    $leaseLedgerBefore = [System.IO.File]::ReadAllText($ledgerPath)
    $dirtyLeaseResult = Invoke-AbandonCase -CaseName 'dirty lease cannot be abandoned' `
        -RunId $dirtyLeaseRunId -ExtraParameters @{
            Attended = $true
            AbandonReason = 'lease recovery'
        }
    $leaseLedgerAfter = [System.IO.File]::ReadAllText($ledgerPath)
    Assert-Case -Label 'lease rows receive the same clean-tree guard' `
        -Condition ($dirtyLeaseResult.ExitCode -eq 82 -and $leaseLedgerAfter -ceq $leaseLedgerBefore) `
        -Detail "exit=$($dirtyLeaseResult.ExitCode) ledger unchanged=$($leaseLedgerAfter -ceq $leaseLedgerBefore)"

    $guardRepo = New-FixtureRepo -Name 'abandon-status-guards'
    $guardKey = ([string]@(Invoke-FixtureGit -Repo $guardRepo -GitArguments @('rev-parse', '--show-toplevel'))[0]).
        Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    $terminalRunId = [guid]::NewGuid().ToString('N')
    $adoptingRunId = [guid]::NewGuid().ToString('N')
    $liveRunId = [guid]::NewGuid().ToString('N')
    $liveStamp = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    Add-LedgerRows -Rows @(
        [ordered]@{
            run_id = $terminalRunId; row_kind = 'dispatch'; status = 'done'
            worktree = $guardRepo; worktree_key = $guardKey; started = $deadStamp
        },
        [ordered]@{
            run_id = $adoptingRunId; row_kind = 'dispatch'; status = 'adopting'
            launcher_pid = 2147483646; launcher_start = $deadStamp
            pid = 2147483645; pid_start = $deadStamp
            worktree = $guardRepo; worktree_key = $guardKey; started = $deadStamp
        },
        [ordered]@{
            run_id = $liveRunId; row_kind = 'dispatch'; status = 'running'
            pid = $PID; pid_start = $liveStamp
            worktree = $guardRepo; worktree_key = $guardKey
            started = ([datetime]::UtcNow.ToString('o'))
        }
    )
    foreach ($guardCase in @(
            [pscustomobject]@{ Label = 'terminal'; RunId = $terminalRunId; Status = 'done' },
            [pscustomobject]@{ Label = 'adopting'; RunId = $adoptingRunId; Status = 'adopting' },
            [pscustomobject]@{ Label = 'live'; RunId = $liveRunId; Status = 'running' }
        )) {
        $guardLedgerBefore = [System.IO.File]::ReadAllText($ledgerPath)
        $guardResult = Invoke-AbandonCase -CaseName "$($guardCase.Label) row guard" `
            -RunId $guardCase.RunId -ExtraParameters @{
                Attended = $true
                AbandonReason = 'must refuse'
            }
        $guardLedgerAfter = [System.IO.File]::ReadAllText($ledgerPath)
        Assert-Case -Label "$($guardCase.Label) row exits 82 without mutation" `
            -Condition ($guardResult.ExitCode -eq 82 -and
                $guardLedgerAfter -ceq $guardLedgerBefore -and
                $guardResult.Output -match [regex]::Escape($guardCase.Status)) `
            -Detail "exit=$($guardResult.ExitCode) ledger unchanged=$($guardLedgerAfter -ceq $guardLedgerBefore)"
    }

    $spec = New-UniqueSpec -CaseName 'adopt-abandon-race'
    $repo = New-FixtureRepo -Name 'adopt-abandon-race'
    $baseSha = Get-FixtureHead -Repo $repo
    $worktreeKey = ([string]@(Invoke-FixtureGit -Repo $repo -GitArguments @('rev-parse', '--show-toplevel'))[0]).
        Replace('\', '/').TrimEnd('/').ToLowerInvariant()
    $adoptAbandonRunId = [guid]::NewGuid().ToString('N')
    Add-LedgerRows -Rows @([ordered]@{
        run_id = $adoptAbandonRunId; row_kind = 'dispatch'; status = 'orphaned'
        launcher_pid = 2147483646; launcher_start = $deadStamp
        pid = 2147483645; pid_start = $deadStamp
        worktree = $repo; worktree_key = $worktreeKey
        spec = $spec; task = 'task-1'; phase = 'build'; sandbox = 'workspace-write'
        started = $deadStamp; orphaned_at = ([datetime]::UtcNow.AddHours(-1)).ToString('o')
        effort = 'medium'; base_sha = $baseSha
        final_path = (Join-Path $scratchRoot "$adoptAbandonRunId.final")
        schema = 'codex-completion-schema.json'
        scope_armed = $false; scope_task = 'adopt-abandon-race'; authorized = @()
        critical_files_confirmed = $false
    })
    $slowDigestScript = Join-Path $testRoot 'slow-adopt-abandon-digest.ps1'
    Write-Utf8NoBom -Path $slowDigestScript -Content @'
[CmdletBinding()]
param([switch]$Digest, [Parameter(Mandatory)][string]$Worktree)
if (-not $Digest) { throw 'This fixture supports only -Digest.' }
Start-Sleep -Seconds 3
'0000000000000000000000000000000000000000000000000000000000000000'
'@
    $adoptWinner = Start-AdoptProcess -Spec $spec -Repo $repo -BaseSha $baseSha `
        -RunId $adoptAbandonRunId -DigestScript $slowDigestScript
    $claimDeadline = [datetime]::UtcNow.AddSeconds(5)
    do {
        $claimedRow = Get-LedgerRow -RunId $adoptAbandonRunId -RowKind 'dispatch'
        if ([string]$claimedRow.status -ceq 'adopting') { break }
        Start-Sleep -Milliseconds 50
    } while ([datetime]::UtcNow -lt $claimDeadline)
    $abandonLoser = Start-AbandonProcess -RunId $adoptAbandonRunId -Reason 'race loser'
    $adoptWinner.Process.WaitForExit()
    $abandonLoser.Process.WaitForExit()
    $adoptWinner.Process.Refresh()
    $abandonLoser.Process.Refresh()
    $adoptOutput = [string]$adoptWinner.StandardOutput.Result + [string]$adoptWinner.StandardError.Result
    $abandonOutput = [string]$abandonLoser.StandardOutput.Result + [string]$abandonLoser.StandardError.Result
    $raceAfter = Get-LedgerRow -RunId $adoptAbandonRunId -RowKind 'dispatch'
    Assert-Case -Label 'concurrent adopt and abandon leave one winner' `
        -Condition ($adoptWinner.Process.ExitCode -eq 67 -and
            $abandonLoser.Process.ExitCode -eq 82 -and
            [string]$raceAfter.status -ceq 'adopted-blocked' -and
            @((Get-LedgerRowsForSpec -Spec $spec)).Count -eq 1) `
        -Detail "adopt exit=$($adoptWinner.Process.ExitCode) abandon exit=$($abandonLoser.Process.ExitCode) status=$($raceAfter.status)"
    Assert-Case -Label 'adopt-abandon loser reports adopting refusal' `
        -Condition ($abandonOutput -match "observed status 'adopting'") `
        -Detail "abandon output=$abandonOutput"

    $abandonFirstRunId = [guid]::NewGuid().ToString('N')
    $abandonFirstRow = [ordered]@{} + $raceRow
    $abandonFirstRow['run_id'] = $abandonFirstRunId
    $abandonFirstRow['spec'] = $spec
    $abandonFirstRow['worktree'] = $repo
    $abandonFirstRow['worktree_key'] = $worktreeKey
    $abandonFirstRow['status'] = 'orphaned'
    $abandonFirstRow['final_path'] = Join-Path $scratchRoot "$abandonFirstRunId.final"
    Add-LedgerRows -Rows @($abandonFirstRow)
    $abandonWinnerResult = Invoke-AbandonCase -CaseName 'abandon wins selection lock' `
        -RunId $abandonFirstRunId -ExtraParameters @{
            Attended = $true
            AbandonReason = 'race winner'
        }
    $adoptLoserResult = Invoke-DispatchCase -CaseName 'adopter loses to abandonment' `
        -Spec $spec -Repo $repo -ExtraParameters @{
            Adopt = $true
            RunId = $abandonFirstRunId
        }
    $abandonFirstAfter = Get-LedgerRow -RunId $abandonFirstRunId -RowKind 'dispatch'
    Assert-Case -Label 'abandon-first race gives adopter its refusal code' `
        -Condition ($abandonWinnerResult.ExitCode -eq 0 -and
            $adoptLoserResult.ExitCode -eq 75 -and
            [string]$abandonFirstAfter.status -ceq 'abandoned-unadopted') `
        -Detail "abandon exit=$($abandonWinnerResult.ExitCode) adopt exit=$($adoptLoserResult.ExitCode) status=$($abandonFirstAfter.status)"

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
    Set-OptionalEnvironmentValue -Name 'APEX_LEDGER_REPLACE_LOG' -Value $oldLedgerReplaceLog
    Set-OptionalEnvironmentValue -Name 'GIT_CONFIG_GLOBAL' -Value $oldGitConfigGlobal
    Set-OptionalEnvironmentValue -Name 'XDG_CONFIG_HOME' -Value $oldXdgConfigHome
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
