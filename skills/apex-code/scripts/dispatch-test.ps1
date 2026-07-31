# End-to-end coverage for codex-dispatch.ps1's scope and post-hoc build gates.
# Every repository and every piece of dispatcher state is disposable and outside this checkout.

$ErrorActionPreference = 'Stop'

$dispatch = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
$fakeCodex = Join-Path $PSScriptRoot 'dispatch-test-fakecodex.ps1'
$criticalFiles = Join-Path $PSScriptRoot 'apex-critical-files.ps1'
$treePin = Join-Path $PSScriptRoot 'tree-pin.ps1'
foreach ($required in @($dispatch, $fakeCodex, $criticalFiles, $treePin)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required test dependency not found: $required"
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("apex-dispatch-test-" + [guid]::NewGuid().ToString('N'))
$repoRoot = Join-Path $testRoot 'repos'
$stateRoot = Join-Path $testRoot 'state'
$scratchRoot = Join-Path $stateRoot 'scratch'
$ledgerPath = Join-Path (Join-Path $stateRoot 'progress') 'codex-run-ledger.jsonl'

$oldEnvironment = @{}
foreach ($name in @('APEX_STATE_DIR', 'FAKE_CODEX_REPO', 'FAKE_CODEX_INSCOPE_ONLY',
        'FAKE_CODEX_EXTRA_WRITE', 'FAKE_CODEX_STATUS', 'FAKE_CODEX_NO_REPORT', 'FAKE_CODEX_VERDICT',
        'FAKE_CODEX_READY_PATH', 'FAKE_CODEX_RELEASE_PATH', 'GIT_CONFIG_GLOBAL')) {
    $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

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

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $gitOutput = @(& git -C $Repo @GitArguments 2>&1)
        $gitExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($gitExit -ne 0) {
        throw "git -C $Repo $($GitArguments -join ' ') failed: $($gitOutput -join [Environment]::NewLine)"
    }
    return $gitOutput
}

function New-FixtureRepo {
    param([Parameter(Mandatory)][string]$Name)

    $repo = Join-Path $repoRoot $Name
    [System.IO.Directory]::CreateDirectory((Join-Path $repo 'src')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $repo 'docs')) | Out-Null
    Write-Utf8NoBom -Path (Join-Path $repo 'src\a.py') -Content "orig`n"
    Write-Utf8NoBom -Path (Join-Path $repo 'src\b.py') -Content "orig`n"
    Write-Utf8NoBom -Path (Join-Path $repo 'docs\status.md') -Content "HOST STATE`n"
    Write-Utf8NoBom -Path (Join-Path $repo 'AGENTS.md') -Content @'
## Verify commands

```
exit 0
```
'@
    Invoke-FixtureGit -Repo $repo -GitArguments @('init', '-q') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('config', 'user.email', 'dispatch-test@example.invalid') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('config', 'user.name', 'dispatch-test') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('add', '-A') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('commit', '-q', '-m', 'fixture') | Out-Null
    $head = @(Invoke-FixtureGit -Repo $repo -GitArguments @('rev-parse', 'HEAD'))

    return [pscustomobject]@{ Path = $repo; BaseSha = ([string]$head[0]).Trim() }
}

function New-FixtureWorktree {
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)][string]$Name,
        [switch]$Detached
    )

    $worktreeParent = Join-Path $testRoot 'linked-worktrees'
    [System.IO.Directory]::CreateDirectory($worktreeParent) | Out-Null
    $worktreePath = Join-Path $worktreeParent $Name
    $branch = "task5-$Name"
    $arguments = if ($Detached) {
        @('worktree', 'add', '-q', '--detach', $worktreePath, $Fixture.BaseSha)
    }
    else {
        @('worktree', 'add', '-q', '-b', $branch, $worktreePath, $Fixture.BaseSha)
    }
    Invoke-FixtureGit -Repo $Fixture.Path -GitArguments $arguments | Out-Null
    return [pscustomobject]@{
        Path = $worktreePath
        BaseSha = $Fixture.BaseSha
        MainRepo = $Fixture.Path
        Branch = $(if ($Detached) { '(detached)' } else { $branch })
    }
}

function Add-TestLedgerRow {
    param([Parameter(Mandatory)][hashtable]$Row)

    $parent = Split-Path $ledgerPath -Parent
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    [System.IO.File]::AppendAllText(
        $ledgerPath,
        ($Row | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Set-TestLedgerRowStatus {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Status
    )

    $lines = [System.IO.File]::ReadAllLines($ledgerPath)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
        $row = $lines[$i] | ConvertFrom-Json
        if ([string]$row.run_id -cne $RunId) { continue }
        $row.status = $Status
        $row | Add-Member -NotePropertyName 'ended' `
            -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force
        $lines[$i] = $row | ConvertTo-Json -Compress -Depth 8
        break
    }
    [System.IO.File]::WriteAllLines($ledgerPath, $lines, [System.Text.UTF8Encoding]::new($false))
}

function New-TestSiblingRow {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$Worktree,
        [Parameter(Mandatory)][ValidateSet('running', 'orphaned')][string]$Status,
        [string]$Spec = 'task5-seeded-sibling'
    )

    $worktreeKey = ([string](@(Invoke-FixtureGit -Repo $Worktree.Path `
                -GitArguments @('rev-parse', '--show-toplevel'))[0]) -replace '\\', '/'
        ).TrimEnd('/').ToLowerInvariant()
    $stamp = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    return @{
        run_id = $RunId
        row_kind = 'dispatch'
        status = $Status
        pid = $(if ($Status -ceq 'running') { $PID } else { $null })
        pid_start = $(if ($Status -ceq 'running') { $stamp } else { $null })
        launcher_pid = $(if ($Status -ceq 'running') { $PID } else { $null })
        launcher_start = $(if ($Status -ceq 'running') { $stamp } else { $null })
        worktree = $Worktree.Path
        worktree_key = $worktreeKey
        spec = $Spec
        task = 'seeded-sibling'
        phase = 'build'
        sandbox = 'workspace-write'
        effort = 'medium'
        started = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Get-LedgerRowsForSpec {
    param([Parameter(Mandatory)][string]$Spec)

    if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { return @() }
    $rows = @()
    foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $row = $line | ConvertFrom-Json
        if ([string]$row.spec -eq $Spec) { $rows += $row }
    }
    return @($rows)
}

function Get-LedgerRowByRunId {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$RowKind = 'dispatch'
    )

    if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { return $null }
    foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $row = $line | ConvertFrom-Json
        if ([string]$row.run_id -ceq $RunId -and [string]$row.row_kind -ceq $RowKind) {
            return $row
        }
    }
    return $null
}

function Test-HasProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)
    return ($null -ne $Object -and @($Object.PSObject.Properties.Name) -ccontains $Name)
}

function Test-CompleteTelemetryFields {
    param($Row)

    return (
        (Test-HasProperty -Object $Row -Name 'log_path') -and
        (Test-HasProperty -Object $Row -Name 'effort') -and
        (Test-HasProperty -Object $Row -Name 'attended') -and
        -not [string]::IsNullOrWhiteSpace([string]$Row.log_path) -and
        -not [string]::IsNullOrWhiteSpace([string]$Row.effort)
    )
}

function Test-CompleteTeardownFields {
    param($Row)

    if ($null -eq $Row) { return $false }
    foreach ($name in @('teardown_main_repo', 'teardown_sha', 'teardown_branch',
            'teardown_worktree', 'cleanup_obligation', 'branch_teardown_obligation')) {
        if (-not (Test-HasProperty -Object $Row -Name $name)) { return $false }
    }
    return (
        -not [string]::IsNullOrWhiteSpace([string]$Row.teardown_main_repo) -and
        -not [string]::IsNullOrWhiteSpace([string]$Row.teardown_sha) -and
        -not [string]::IsNullOrWhiteSpace([string]$Row.teardown_branch) -and
        -not [string]::IsNullOrWhiteSpace([string]$Row.teardown_worktree)
    )
}

function Test-ByteEqual {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)

    $a = [System.IO.File]::ReadAllBytes($Left)
    $b = [System.IO.File]::ReadAllBytes($Right)
    if ($a.Length -ne $b.Length) { return $false }
    for ($i = 0; $i -lt $a.Length; $i++) {
        if ($a[$i] -ne $b[$i]) { return $false }
    }
    return $true
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

function New-ScopeStubDispatcher {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('missing-written-paths', 'throw-on-check')][string]$Mode
    )

    $root = Join-Path $testRoot $Name
    $scripts = Join-Path $root 'skills\apex-code\scripts'
    $references = Join-Path $root 'skills\apex-code\references'
    [System.IO.Directory]::CreateDirectory($scripts) | Out-Null
    [System.IO.Directory]::CreateDirectory($references) | Out-Null
    Copy-Item -LiteralPath $dispatch -Destination (Join-Path $scripts 'codex-dispatch.ps1')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\references\codex-completion-schema.json') `
        -Destination (Join-Path $references 'codex-completion-schema.json')

    $checkBody = if ($Mode -eq 'throw-on-check') {
        "throw 'forced scope-check failure'"
    }
    else {
        "Write-Host '[scope-stub] deliberately omitted WrittenPathsFile'; exit 0"
    }
    Write-Utf8NoBom -Path (Join-Path $scripts 'codex-scope-check.ps1') -Content @"
[CmdletBinding()]
param(
    [switch]`$Snapshot, [switch]`$Check, [switch]`$EncodingScan,
    [string]`$Worktree, [string]`$Task, [string[]]`$Authorized = @(),
    [string]`$StateDirectory, [string]`$WrittenPathsFile, [string]`$ExcludeRunId
)
if (`$Snapshot) { exit 0 }
if (`$EncodingScan) { exit 0 }
if (`$Check) { $checkBody }
exit 0
"@
    return (Join-Path $scripts 'codex-dispatch.ps1')
}

function Invoke-DispatchCase {
    param(
        [Parameter(Mandatory)][string]$CaseName,
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)]$Fixture,
        [string[]]$Authorized = @('src/a.py'),
        [hashtable]$ExtraParameters = @{},
        [hashtable]$FakeEnvironment = @{},
        [string]$DispatcherPath = $dispatch,
        [string]$FakePath = $fakeCodex
    )

    $parameters = @{
        Spec = $Spec
        Task = 'dispatch-test'
        Phase = 'build'
        Worktree = $Fixture.Path
        BaseSha = $Fixture.BaseSha
        Prompt = "Dispatcher test case: $CaseName"
        Authorized = @($Authorized)
        ScratchDirectory = $scratchRoot
        CodexExecutable = 'powershell.exe'
        CodexExecutableArgumentPrefix = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FakePath)
        CriticalFilesScript = $criticalFiles
        TreePinScript = $treePin
        SkipBaselineCheck = $true
    }
    foreach ($entry in $ExtraParameters.GetEnumerator()) { $parameters[$entry.Key] = $entry.Value }

    foreach ($name in @('FAKE_CODEX_INSCOPE_ONLY', 'FAKE_CODEX_EXTRA_WRITE', 'FAKE_CODEX_STATUS',
            'FAKE_CODEX_NO_REPORT', 'FAKE_CODEX_VERDICT')) {
        Set-OptionalEnvironmentValue -Name $name -Value $null
    }
    $env:FAKE_CODEX_REPO = $Fixture.Path
    foreach ($entry in $FakeEnvironment.GetEnumerator()) {
        Set-OptionalEnvironmentValue -Name $entry.Key -Value ([string]$entry.Value)
    }

    Write-Host "`n===== CASE: $CaseName =====" -ForegroundColor Cyan
    $captured = @(& $DispatcherPath @parameters *>&1)
    $exitCode = $LASTEXITCODE
    $outputText = @($captured | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if (-not [string]::IsNullOrWhiteSpace($outputText)) { Write-Host $outputText.TrimEnd() }
    Write-Host ("----- {0}: exit {1} -----" -f $CaseName, $exitCode) -ForegroundColor DarkCyan

    return [pscustomobject]@{
        ExitCode = $exitCode
        Rows = @(Get-LedgerRowsForSpec -Spec $Spec)
        Output = $outputText
    }
}

function Invoke-AdoptCase {
    param(
        [Parameter(Mandatory)][string]$CaseName,
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)][string]$RunId
    )

    Write-Host "`n===== CASE: $CaseName =====" -ForegroundColor Cyan
    $captured = @(& $dispatch -Adopt -Spec $Spec -Task $Task -Phase $Phase `
        -Worktree $Fixture.Path -RunId $RunId -ScratchDirectory $scratchRoot *>&1)
    $exitCode = $LASTEXITCODE
    $outputText = @($captured | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if (-not [string]::IsNullOrWhiteSpace($outputText)) { Write-Host $outputText.TrimEnd() }
    Write-Host ("----- {0}: exit {1} -----" -f $CaseName, $exitCode) -ForegroundColor DarkCyan

    return [pscustomobject]@{
        ExitCode = $exitCode
        Row = Get-LedgerRowByRunId -RunId $RunId
        Output = $outputText
    }
}

try {
    [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($scratchRoot) | Out-Null
    $env:APEX_STATE_DIR = $stateRoot
    $testGitConfig = Join-Path $testRoot 'gitconfig'
    $testGitIgnore = Join-Path $testRoot 'gitignore'
    Write-Utf8NoBom -Path $testGitIgnore -Content ''
    $testGitIgnoreConfigPath = $testGitIgnore -replace '\\', '/'
    Write-Utf8NoBom -Path $testGitConfig -Content "[core]`n    excludesFile = $testGitIgnoreConfigPath`n"
    $env:GIT_CONFIG_GLOBAL = $testGitConfig

    $missingWrittenDispatcher = New-ScopeStubDispatcher -Name 'stub-missing-written' -Mode 'missing-written-paths'
    $throwingScopeDispatcher = New-ScopeStubDispatcher -Name 'stub-throwing-scope' -Mode 'throw-on-check'

    $commitFake = Join-Path $testRoot 'fake-commit.ps1'
    Write-Utf8NoBom -Path $commitFake -Content @'
$passThruArgs = $args
[void][Console]::In.ReadToEnd()
$repo = $env:FAKE_CODEX_REPO
Add-Content -LiteralPath (Join-Path $repo 'src\a.py') -Value 'fake committed change'
& git -C $repo add -- src/a.py
& git -C $repo commit -q -m 'fake coder commit'
$finalPath = $null
for ($i = 0; $i -lt $passThruArgs.Count - 1; $i++) {
    if ($passThruArgs[$i] -eq '-o') { $finalPath = $passThruArgs[$i + 1]; break }
}
$report = [ordered]@{ status = 'done'; changed_files = @('src/a.py'); commands_run = @(); deviations = @(); unresolved = @(); blocker = $null }
[System.IO.File]::WriteAllText($finalPath, ($report | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
exit 0
'@

    # Existing default fake flow, with the new knob explicitly absent. Build reference files by
    # applying the old operations to copies, then compare bytes after a real dispatch.
    $fixture = New-FixtureRepo -Name 'default-flow'
    $expected = Join-Path $testRoot 'default-expected'
    [System.IO.Directory]::CreateDirectory($expected) | Out-Null
    Copy-Item -LiteralPath (Join-Path $fixture.Path 'src\a.py') -Destination (Join-Path $expected 'a.py')
    Copy-Item -LiteralPath (Join-Path $fixture.Path 'src\b.py') -Destination (Join-Path $expected 'b.py')
    Copy-Item -LiteralPath (Join-Path $fixture.Path 'docs\status.md') -Destination (Join-Path $expected 'status.md')
    Add-Content -LiteralPath (Join-Path $expected 'a.py') -Value 'codex authorized change'
    Add-Content -LiteralPath (Join-Path $expected 'b.py') -Value 'codex OUT OF SCOPE'
    Set-Content -LiteralPath (Join-Path $expected 'rogue.py') -Value 'codex stray file'
    Add-Content -LiteralPath (Join-Path $expected 'status.md') -Value 'codex clobbered status.md'
    $result = Invoke-DispatchCase -CaseName 'default fake regression' -Spec 'dispatch-default-flow' -Fixture $fixture
    $defaultBytesMatch =
        (Test-ByteEqual (Join-Path $fixture.Path 'src\a.py') (Join-Path $expected 'a.py')) -and
        (Test-ByteEqual (Join-Path $fixture.Path 'src\b.py') (Join-Path $expected 'b.py')) -and
        (Test-ByteEqual (Join-Path $fixture.Path 'src\rogue.py') (Join-Path $expected 'rogue.py')) -and
        (Test-ByteEqual (Join-Path $fixture.Path 'docs\status.md') (Join-Path $expected 'status.md'))
    Assert-Case -Label 'default fake flow remains byte-identical with knob unset' `
        -Condition ($result.ExitCode -eq 65 -and $defaultBytesMatch -and -not $env:FAKE_CODEX_EXTRA_WRITE) `
        -Detail ("exit={0}, byte_match={1}, knob='{2}'" -f $result.ExitCode, $defaultBytesMatch, $env:FAKE_CODEX_EXTRA_WRITE)

    $fixture = New-FixtureRepo -Name 'hardblock-confirmed'
    $result = Invoke-DispatchCase -CaseName 'hard-block write remains fatal when confirmed' `
        -Spec 'dispatch-hardblock-confirmed' -Fixture $fixture -Authorized @('src') `
        -ExtraParameters @{ CriticalFilesConfirmed = $true; CriticalFilesConfirmedNote = 'attended test' } `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1'; FAKE_CODEX_EXTRA_WRITE = 'src/docs/audit/x.md' }
    $row = @($result.Rows) | Select-Object -Last 1
    Assert-Case -Label 'post-hoc hard block outranks confirmation' `
        -Condition ($result.ExitCode -eq 77 -and $row.critical_violation -eq $true -and $row.scope_exit -eq 0) `
        -Detail ("exit={0}, critical={1}, scope_exit={2}" -f $result.ExitCode, $row.critical_violation, $row.scope_exit)

    $fixture = New-FixtureRepo -Name 'critical-unconfirmed'
    $result = Invoke-DispatchCase -CaseName 'post-hoc critical unconfirmed' -Spec 'dispatch-critical-unconfirmed' `
        -Fixture $fixture -Authorized @('src') `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1'; FAKE_CODEX_EXTRA_WRITE = 'src/package-lock.json' }
    $row = @($result.Rows) | Select-Object -Last 1
    Assert-Case -Label 'post-hoc exit-10 unconfirmed maps to 77' `
        -Condition ($result.ExitCode -eq 77 -and $row.critical_violation -eq $true) `
        -Detail ("exit={0}, critical={1}" -f $result.ExitCode, $row.critical_violation)

    $fixture = New-FixtureRepo -Name 'critical-confirmed'
    $result = Invoke-DispatchCase -CaseName 'post-hoc critical confirmed' -Spec 'dispatch-critical-confirmed' `
        -Fixture $fixture -Authorized @('src') `
        -ExtraParameters @{ CriticalFilesConfirmed = $true; CriticalFilesConfirmedNote = 'attended test' } `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1'; FAKE_CODEX_EXTRA_WRITE = 'src/package-lock.json' }
    $row = @($result.Rows) | Select-Object -Last 1
    Assert-Case -Label 'post-hoc exit-10 confirmed proceeds' `
        -Condition ($result.ExitCode -eq 0 -and $row.critical_violation -eq $false) `
        -Detail ("exit={0}, critical={1}" -f $result.ExitCode, $row.critical_violation)

    $fixture = New-FixtureRepo -Name 'head-move'
    $result = Invoke-DispatchCase -CaseName 'fake coder commits' -Spec 'dispatch-head-move' -Fixture $fixture `
        -FakePath $commitFake
    $row = @($result.Rows) | Select-Object -Last 1
    Assert-Case -Label 'HEAD move keeps scope precedence over post-hoc 77' `
        -Condition ($result.ExitCode -eq 65 -and $row.critical_violation -eq $true -and $row.scopeViolation -eq $true) `
        -Detail ("exit={0}, critical={1}, scopeViolation={2}" -f $result.ExitCode, $row.critical_violation, $row.scopeViolation)

    $fixture = New-FixtureRepo -Name 'missing-written-paths'
    $result = Invoke-DispatchCase -CaseName 'scope check omits written-paths file' `
        -Spec 'dispatch-missing-written-paths' -Fixture $fixture -DispatcherPath $missingWrittenDispatcher `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $row = @($result.Rows) | Select-Object -Last 1
    Assert-Case -Label 'missing written-paths evidence fails closed at 77' `
        -Condition ($result.ExitCode -eq 77 -and $row.critical_violation -eq $true) `
        -Detail ("exit={0}, critical={1}" -f $result.ExitCode, $row.critical_violation)

    $fixture = New-FixtureRepo -Name 'scope-throw'
    $result = Invoke-DispatchCase -CaseName 'scope check throws' -Spec 'dispatch-scope-throw' `
        -Fixture $fixture -DispatcherPath $throwingScopeDispatcher `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $row = @($result.Rows) | Select-Object -Last 1
    Assert-Case -Label 'scope-check throw records critical failure and exits 77' `
        -Condition ($result.ExitCode -eq 77 -and $row.critical_violation -eq $true -and
            $result.Output.Contains('scope_check_error: forced scope-check failure')) `
        -Detail ("exit={0}, critical={1}, error_note={2}" -f $result.ExitCode, $row.critical_violation,
            $result.Output.Contains('scope_check_error: forced scope-check failure'))

    $fixture = New-FixtureRepo -Name 'blocked-scope-throw'
    $result = Invoke-DispatchCase -CaseName 'blocked coder plus scope throw' -Spec 'dispatch-blocked-scope-throw' `
        -Fixture $fixture -DispatcherPath $throwingScopeDispatcher `
        -FakeEnvironment @{ FAKE_CODEX_STATUS = 'blocked' }
    $row = @($result.Rows) | Select-Object -Last 1
    Assert-Case -Label 'blocked coder retains exit-67 precedence and critical evidence' `
        -Condition ($result.ExitCode -eq 67 -and $row.status -eq 'blocked' -and $row.critical_violation -eq $true) `
        -Detail ("exit={0}, status={1}, critical={2}" -f $result.ExitCode, $row.status, $row.critical_violation)

    $classifierMarker = Join-Path $testRoot 'stateful-classifier.marker'
    $statefulClassifier = Join-Path $testRoot 'stateful-classifier.ps1'
    Write-Utf8NoBom -Path $statefulClassifier -Content @"
if (Test-Path -LiteralPath '$classifierMarker') { exit 7 }
[System.IO.File]::WriteAllText('$classifierMarker', 'preflight')
exit 0
"@
    $fixture = New-FixtureRepo -Name 'classifier-unexpected-posthoc'
    $result = Invoke-DispatchCase -CaseName 'classifier changes verdict after pre-flight' `
        -Spec 'dispatch-classifier-unexpected-posthoc' -Fixture $fixture `
        -ExtraParameters @{ CriticalFilesScript = $statefulClassifier } `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $row = @($result.Rows) | Select-Object -Last 1
    Assert-Case -Label 'unexpected post-hoc classifier exit maps to 77' `
        -Condition ($result.ExitCode -eq 77 -and $row.critical_violation -eq $true -and
            (Test-Path -LiteralPath $classifierMarker)) `
        -Detail ("exit={0}, critical={1}, marker={2}" -f $result.ExitCode, $row.critical_violation,
            (Test-Path -LiteralPath $classifierMarker))

    $fixture = New-FixtureRepo -Name 'scope-unlocked'
    $result = Invoke-DispatchCase -CaseName 'scope-unlocked build' -Spec 'dispatch-scope-unlocked' `
        -Fixture $fixture -Authorized @() -ExtraParameters @{
            ScopeUnlocked = $true; ScopeUnlockedReason = 'focused test'; CriticalFilesConfirmed = $true
        } -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $row = @($result.Rows) | Select-Object -Last 1
    Assert-Case -Label 'scope-unlocked build omits critical_violation and prints note' `
        -Condition ($result.ExitCode -eq 0 -and -not (Test-HasProperty $row 'critical_violation') -and
            $result.Output.Contains('scope-unlocked: written set unavailable')) `
        -Detail ("exit={0}, has_critical={1}, note={2}" -f $result.ExitCode,
            (Test-HasProperty $row 'critical_violation'), $result.Output.Contains('scope-unlocked: written set unavailable'))

    $fixture = New-FixtureRepo -Name 'lock-collision'
    $result = Invoke-DispatchCase -CaseName '.lock classifier collision' -Spec 'dispatch-lock-collision' `
        -Fixture $fixture -Authorized @('src') `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1'; FAKE_CODEX_EXTRA_WRITE = 'src/cache.lock' }
    $row = @($result.Rows) | Select-Object -Last 1
    Assert-Case -Label 'in-scope .lock is classified post-hoc and exits 77' `
        -Condition ($result.ExitCode -eq 77 -and $row.scope_exit -eq 0 -and $row.critical_violation -eq $true) `
        -Detail ("exit={0}, scope_exit={1}, critical={2}" -f $result.ExitCode, $row.scope_exit, $row.critical_violation)

    $fixture = New-FixtureRepo -Name 'build-reviewed-run-id'
    $result = Invoke-DispatchCase -CaseName 'build rejects ReviewedRunId' -Spec 'dispatch-build-reviewed-id' `
        -Fixture $fixture -ExtraParameters @{ ReviewedRunId = 'build-does-not-review' }
    Assert-Case -Label 'build plus ReviewedRunId is caller-contract exit 74' `
        -Condition ($result.ExitCode -eq 74 -and $result.Rows.Count -eq 0) `
        -Detail ("exit={0}, rows={1}" -f $result.ExitCode, $result.Rows.Count)

    $fixture = New-FixtureRepo -Name 'base-drift'
    $bogusBase = ('f' * 40)
    $result = Invoke-DispatchCase -CaseName 'bogus BaseSha drift warning' -Spec 'dispatch-base-drift' `
        -Fixture $fixture -ExtraParameters @{ BaseSha = $bogusBase } `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $row = @($result.Rows) | Select-Object -Last 1
    Assert-Case -Label 'bogus BaseSha warns and records reservation HEAD' `
        -Condition ($result.ExitCode -eq 0 -and $result.Output.Contains('differs from reservation-time HEAD') -and
            $row.base_sha -eq $bogusBase -and $row.head_sha -eq $fixture.BaseSha) `
        -Detail ("exit={0}, warned={1}, head_sha={2}" -f $result.ExitCode,
            $result.Output.Contains('differs from reservation-time HEAD'), $row.head_sha)

    $digestFailure = Join-Path $testRoot 'digest-failure.ps1'
    Write-Utf8NoBom -Path $digestFailure -Content 'exit 9'
    $fixture = New-FixtureRepo -Name 'digest-failure'
    $result = Invoke-DispatchCase -CaseName 'forced build digest failure' -Spec 'dispatch-digest-failure' `
        -Fixture $fixture -ExtraParameters @{ TreePinScript = $digestFailure } `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $row = @($result.Rows) | Select-Object -Last 1
    Assert-Case -Label 'build digest failure records unverifiable' `
        -Condition ($result.ExitCode -eq 0 -and $row.end_tree_digest -ceq 'unverifiable') `
        -Detail ("exit={0}, end_tree_digest='{1}'" -f $result.ExitCode, $row.end_tree_digest)

    # Creator-owned teardown uses real linked worktrees. A fake that produces a valid completion
    # without editing the tree lets each case control dirtiness independently.
    $noWriteFake = Join-Path $testRoot 'fake-no-write.ps1'
    Write-Utf8NoBom -Path $noWriteFake -Content @'
$passThruArgs = $args
[void][Console]::In.ReadToEnd()
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

    # Hold a real dispatch after its lease has become a running row so the persisted in-flight shape
    # is inspected independently of the terminal rewrite.
    $telemetryWaitFake = Join-Path $testRoot 'fake-telemetry-wait.ps1'
    Write-Utf8NoBom -Path $telemetryWaitFake -Content @'
$passThruArgs = $args
[void][Console]::In.ReadToEnd()
$finalPath = $null
for ($i = 0; $i -lt $passThruArgs.Count - 1; $i++) {
    if ($passThruArgs[$i] -eq '-o') { $finalPath = $passThruArgs[$i + 1]; break }
}
[System.IO.File]::WriteAllText($env:FAKE_CODEX_READY_PATH, 'ready', [System.Text.UTF8Encoding]::new($false))
$deadline = [datetime]::UtcNow.AddSeconds(20)
while (-not (Test-Path -LiteralPath $env:FAKE_CODEX_RELEASE_PATH)) {
    if ([datetime]::UtcNow -ge $deadline) { exit 9 }
    Start-Sleep -Milliseconds 50
}
$report = [ordered]@{
    status = 'done'; changed_files = @(); commands_run = @()
    deviations = @(); unresolved = @(); blocker = $null
}
[System.IO.File]::WriteAllText($finalPath, ($report | ConvertTo-Json -Depth 8),
    [System.Text.UTF8Encoding]::new($false))
exit 0
'@

    $fixture = New-FixtureRepo -Name 'telemetry-running'
    $runningSpec = 'task6-telemetry-running'
    $readyPath = Join-Path $testRoot 'telemetry-ready.flag'
    $releasePath = Join-Path $testRoot 'telemetry-release.flag'
    $runningJob = Start-Job -ScriptBlock {
        param($dispatcher, $fake, $critical, $pin, $state, $scratch, $repo, $base,
            $specName, $ready, $release)
        $env:APEX_STATE_DIR = $state
        $env:FAKE_CODEX_REPO = $repo
        $env:FAKE_CODEX_READY_PATH = $ready
        $env:FAKE_CODEX_RELEASE_PATH = $release
        $captured = @(& $dispatcher -Spec $specName -Task 'dispatch-test' -Phase 'build' `
            -Worktree $repo -BaseSha $base -Prompt 'telemetry running-row test' `
            -Authorized @('src/a.py') -ScratchDirectory $scratch -CodexExecutable 'powershell.exe' `
            -CodexExecutableArgumentPrefix @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fake) `
            -CriticalFilesScript $critical -TreePinScript $pin -SkipBaselineCheck `
            -Effort 'xhigh' -Attended:$false *>&1)
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = (@($captured | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
        }
    } -ArgumentList $dispatch, $telemetryWaitFake, $criticalFiles, $treePin, $stateRoot,
        $scratchRoot, $fixture.Path, $fixture.BaseSha, $runningSpec, $readyPath, $releasePath

    $runningRow = $null
    $runningDeadline = [datetime]::UtcNow.AddSeconds(20)
    do {
        try {
            $runningRow = @(Get-LedgerRowsForSpec -Spec $runningSpec |
                Where-Object { [string]$_.row_kind -ceq 'dispatch' -and [string]$_.status -ceq 'running' }) |
                Select-Object -Last 1
        }
        catch [System.IO.IOException] {
            $runningRow = $null
        }
        if ($runningRow -and (Test-Path -LiteralPath $readyPath -PathType Leaf)) { break }
        Start-Sleep -Milliseconds 100
    } while ([datetime]::UtcNow -lt $runningDeadline)

    Assert-Case -Label 'running dispatch row carries bound-false telemetry shape' `
        -Condition ((Test-CompleteTelemetryFields $runningRow) -and
            [string]$runningRow.effort -ceq 'xhigh' -and $runningRow.attended -eq $false) `
        -Detail ("status='{0}', log='{1}', effort='{2}', attended_property={3}, attended='{4}'" -f
            $runningRow.status, $runningRow.log_path, $runningRow.effort,
            (Test-HasProperty -Object $runningRow -Name 'attended'), $runningRow.attended)

    Write-Utf8NoBom -Path $releasePath -Content 'release'
    $completedJob = Wait-Job -Job $runningJob -Timeout 30
    if (-not $completedJob) { Stop-Job -Job $runningJob }
    $runningJobResult = @(Receive-Job -Job $runningJob) | Select-Object -Last 1
    Remove-Job -Job $runningJob -Force
    $terminalRow = @(Get-LedgerRowsForSpec -Spec $runningSpec |
        Where-Object { [string]$_.row_kind -ceq 'dispatch' }) | Select-Object -Last 1
    Assert-Case -Label 'terminal dispatch row preserves bound-false telemetry unchanged' `
        -Condition ($runningJobResult.ExitCode -eq 0 -and
            (Test-CompleteTelemetryFields $terminalRow) -and
            [string]$terminalRow.log_path -ceq [string]$runningRow.log_path -and
            [string]$terminalRow.effort -ceq 'xhigh' -and $terminalRow.attended -eq $false) `
        -Detail ("exit={0}, status='{1}', same_log={2}, effort='{3}', attended='{4}'" -f
            $runningJobResult.ExitCode, $terminalRow.status,
            ([string]$terminalRow.log_path -ceq [string]$runningRow.log_path),
            $terminalRow.effort, $terminalRow.attended)

    $fixture = New-FixtureRepo -Name 'telemetry-adopt-wrapper'
    $wrapperSpec = 'task6-adopt-wrapper'
    $result = Invoke-DispatchCase -CaseName 'wrapper telemetry for adoption' -Spec $wrapperSpec `
        -Fixture $fixture -FakePath $noWriteFake `
        -ExtraParameters @{ Effort = 'high'; Attended = $true }
    $wrapperRow = @($result.Rows | Where-Object { [string]$_.row_kind -ceq 'dispatch' }) |
        Select-Object -Last 1
    Assert-Case -Label 'terminal wrapper row carries bound-true telemetry shape' `
        -Condition ($result.ExitCode -eq 0 -and (Test-CompleteTelemetryFields $wrapperRow) -and
            [string]$wrapperRow.effort -ceq 'high' -and $wrapperRow.attended -eq $true) `
        -Detail ("exit={0}, log='{1}', effort='{2}', attended='{3}'" -f
            $result.ExitCode, $wrapperRow.log_path, $wrapperRow.effort, $wrapperRow.attended)

    $wrapperRunId = [string]$wrapperRow.run_id
    $wrapperLogPath = [string]$wrapperRow.log_path
    Set-TestLedgerRowStatus -RunId $wrapperRunId -Status 'orphaned'
    $adoptResult = Invoke-AdoptCase -CaseName 'adopt wrapper telemetry row' -Spec $wrapperSpec `
        -Task 'dispatch-test' -Phase 'build' -Fixture $fixture -RunId $wrapperRunId
    Assert-Case -Label 'adoption preserves wrapper telemetry and prints its log path' `
        -Condition ($adoptResult.ExitCode -eq 0 -and
            (Test-CompleteTelemetryFields $adoptResult.Row) -and
            [string]$adoptResult.Row.log_path -ceq $wrapperLogPath -and
            [string]$adoptResult.Row.effort -ceq 'high' -and $adoptResult.Row.attended -eq $true -and
            $adoptResult.Output.Contains($wrapperLogPath)) `
        -Detail ("exit={0}, same_log={1}, effort='{2}', attended='{3}', printed_log={4}" -f
            $adoptResult.ExitCode, ([string]$adoptResult.Row.log_path -ceq $wrapperLogPath),
            $adoptResult.Row.effort, $adoptResult.Row.attended,
            $adoptResult.Output.Contains($wrapperLogPath))

    $legacyFixture = New-FixtureRepo -Name 'telemetry-adopt-legacy'
    $legacyRunId = 'task6-legacy-no-telemetry'
    Add-TestLedgerRow -Row @{
        run_id = $legacyRunId; row_kind = 'dispatch'; status = 'orphaned'
        pid = $null; launcher_pid = $null; worktree = $legacyFixture.Path
        spec = 'task6-adopt-legacy'; task = 'legacy-adopt'; phase = 'review'
        sandbox = 'read-only'; base_sha = $legacyFixture.BaseSha; schema = 'review'
        started = (Get-Date).ToUniversalTime().AddMinutes(-2).ToString('o')
    }
    $legacyAdopt = Invoke-AdoptCase -CaseName 'adopt legacy row without telemetry' `
        -Spec 'task6-adopt-legacy' -Task 'legacy-adopt' -Phase 'review' `
        -Fixture $legacyFixture -RunId $legacyRunId
    $legacyStillAbsent = -not (Test-HasProperty -Object $legacyAdopt.Row -Name 'log_path') -and
        -not (Test-HasProperty -Object $legacyAdopt.Row -Name 'effort') -and
        -not (Test-HasProperty -Object $legacyAdopt.Row -Name 'attended')
    Assert-Case -Label 'legacy adoption does not synthesize absent telemetry fields' `
        -Condition ($legacyAdopt.ExitCode -eq 67 -and $legacyStillAbsent -and
            $legacyAdopt.Output.Contains('no recorded log_path')) `
        -Detail ("exit={0}, fields_absent={1}, missing_log_reported={2}" -f
            $legacyAdopt.ExitCode, $legacyStillAbsent,
            $legacyAdopt.Output.Contains('no recorded log_path'))

    $main = New-FixtureRepo -Name 'owned-success-main'
    $ownedSuccess = New-FixtureWorktree -Fixture $main -Name 'owned-success'
    $result = Invoke-DispatchCase -CaseName 'owned clean worktree removal' `
        -Spec 'task5-owned-success' -Fixture $ownedSuccess -FakePath $noWriteFake `
        -ExtraParameters @{ OwnedWorktree = $true }
    $row = @($result.Rows | Where-Object { [string]$_.row_kind -ceq 'dispatch' }) |
        Select-Object -Last 1
    Assert-Case -Label 'owned clean real worktree is removed and branch obligation retained' `
        -Condition ($result.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $ownedSuccess.Path) -and
            (Test-CompleteTeardownFields $row) -and
            [string]$row.cleanup_obligation -ceq '' -and
            [string]$row.branch_teardown_obligation -ceq $ownedSuccess.Branch -and
            (([string]$row.teardown_main_repo -replace '\\', '/') -ceq
                ([string]$ownedSuccess.MainRepo -replace '\\', '/'))) `
        -Detail ("exit={0}, exists={1}, main='{2}', branch_obligation='{3}'" -f
            $result.ExitCode, (Test-Path -LiteralPath $ownedSuccess.Path),
            $row.teardown_main_repo, $row.branch_teardown_obligation)
    $successBranchCommand = 'git -C "{0}" branch -d "{1}"' -f
        $row.teardown_main_repo, $row.teardown_branch

    $main = New-FixtureRepo -Name 'owned-dirty-main'
    $ownedDirty = New-FixtureWorktree -Fixture $main -Name 'owned-dirty'
    Write-Utf8NoBom -Path (Join-Path $ownedDirty.Path 'untracked.txt') -Content "retain me`n"
    $result = Invoke-DispatchCase -CaseName 'owned dirty worktree refusal' `
        -Spec 'task5-owned-dirty' -Fixture $ownedDirty -FakePath $noWriteFake `
        -ExtraParameters @{ OwnedWorktree = $true }
    $row = @($result.Rows | Where-Object { [string]$_.row_kind -ceq 'dispatch' }) |
        Select-Object -Last 1
    Assert-Case -Label 'dirty owned worktree is retained with complete structured obligation' `
        -Condition ($result.ExitCode -eq 0 -and (Test-Path -LiteralPath $ownedDirty.Path) -and
            (Test-CompleteTeardownFields $row) -and
            [string]$row.cleanup_obligation -like '*dirty*untracked.txt*') `
        -Detail ("exit={0}, exists={1}, obligation='{2}'" -f
            $result.ExitCode, (Test-Path -LiteralPath $ownedDirty.Path), $row.cleanup_obligation)

    $main = New-FixtureRepo -Name 'owned-live-main'
    $ownedLive = New-FixtureWorktree -Fixture $main -Name 'owned-live'
    $liveSiblingId = 'task5-live-sibling'
    Add-TestLedgerRow -Row (New-TestSiblingRow -RunId $liveSiblingId -Worktree $ownedLive `
        -Status 'running')
    $result = Invoke-DispatchCase -CaseName 'owned shared worktree live sibling refusal' `
        -Spec 'task5-owned-live' -Fixture $ownedLive -FakePath $noWriteFake `
        -ExtraParameters @{
            OwnedWorktree = $true
            AllowSharedWorktree = $true
            AllowSharedWorktreeReason = 'task5 teardown safety test'
        }
    $liveRefusalRow = @($result.Rows |
        Where-Object { [string]$_.row_kind -ceq 'dispatch' }) | Select-Object -Last 1
    Assert-Case -Label 'AllowSharedWorktree never permits teardown over a live sibling' `
        -Condition ($result.ExitCode -eq 0 -and (Test-Path -LiteralPath $ownedLive.Path) -and
            (Test-CompleteTeardownFields $liveRefusalRow) -and
            [string]$liveRefusalRow.cleanup_obligation -like "*live sibling $liveSiblingId*") `
        -Detail ("exit={0}, exists={1}, obligation='{2}'" -f
            $result.ExitCode, (Test-Path -LiteralPath $ownedLive.Path),
            $liveRefusalRow.cleanup_obligation)
    Set-TestLedgerRowStatus -RunId $liveSiblingId -Status 'done'

    $main = New-FixtureRepo -Name 'owned-orphan-main'
    $ownedOrphan = New-FixtureWorktree -Fixture $main -Name 'owned-orphan'
    $orphanSiblingId = 'task5-orphan-sibling'
    Add-TestLedgerRow -Row (New-TestSiblingRow -RunId $orphanSiblingId -Worktree $ownedOrphan `
        -Status 'orphaned')
    $result = Invoke-DispatchCase -CaseName 'owned orphan sibling refusal' `
        -Spec 'task5-owned-orphan' -Fixture $ownedOrphan -FakePath $noWriteFake `
        -ExtraParameters @{ OwnedWorktree = $true }
    $orphanLeaseRow = @($result.Rows |
        Where-Object { [string]$_.row_kind -ceq 'lease' }) | Select-Object -Last 1
    $orphanCloseRow = Get-LedgerRowByRunId -RunId ([string]$orphanLeaseRow.run_id) `
        -RowKind 'lease_close'
    Assert-Case -Label 'orphaned sibling retains tree and obligation lands on lease only' `
        -Condition ($result.ExitCode -eq 80 -and (Test-Path -LiteralPath $ownedOrphan.Path) -and
            (Test-CompleteTeardownFields $orphanLeaseRow) -and
            [string]$orphanLeaseRow.cleanup_obligation -like
                "*unresolved sibling $orphanSiblingId*" -and
            -not (Test-HasProperty -Object $orphanCloseRow -Name 'cleanup_obligation')) `
        -Detail ("exit={0}, exists={1}, lease_obligation='{2}', close_has_obligation={3}" -f
            $result.ExitCode, (Test-Path -LiteralPath $ownedOrphan.Path),
            $orphanLeaseRow.cleanup_obligation,
            (Test-HasProperty -Object $orphanCloseRow -Name 'cleanup_obligation'))
    Assert-Case -Label 'refused lease and lease_close carry unreported-null telemetry shape' `
        -Condition ((Test-CompleteTelemetryFields $orphanLeaseRow) -and
            (Test-CompleteTelemetryFields $orphanCloseRow) -and
            [string]$orphanLeaseRow.log_path -ceq [string]$orphanCloseRow.log_path -and
            [string]$orphanLeaseRow.effort -ceq 'medium' -and
            [string]$orphanCloseRow.effort -ceq 'medium' -and
            $null -eq $orphanLeaseRow.attended -and $null -eq $orphanCloseRow.attended) `
        -Detail ("lease_log='{0}', close_log='{1}', lease_effort='{2}', close_effort='{3}', lease_attended='{4}', close_attended='{5}'" -f
            $orphanLeaseRow.log_path, $orphanCloseRow.log_path,
            $orphanLeaseRow.effort, $orphanCloseRow.effort,
            $orphanLeaseRow.attended, $orphanCloseRow.attended)

    $main = New-FixtureRepo -Name 'owned-detached-main'
    $ownedDetached = New-FixtureWorktree -Fixture $main -Name 'owned-detached' -Detached
    $result = Invoke-DispatchCase -CaseName 'owned detached HEAD refusal' `
        -Spec 'task5-owned-detached' -Fixture $ownedDetached -FakePath $noWriteFake `
        -ExtraParameters @{ OwnedWorktree = $true }
    $row = @($result.Rows | Where-Object { [string]$_.row_kind -ceq 'dispatch' }) |
        Select-Object -Last 1
    Assert-Case -Label 'detached owned worktree is retained with marker and sha' `
        -Condition ($result.ExitCode -eq 0 -and (Test-Path -LiteralPath $ownedDetached.Path) -and
            (Test-CompleteTeardownFields $row) -and
            [string]$row.teardown_branch -ceq '(detached)' -and
            [string]$row.teardown_sha -ceq $ownedDetached.BaseSha -and
            [string]$row.cleanup_obligation -like '*detached HEAD*') `
        -Detail ("exit={0}, exists={1}, branch='{2}', sha='{3}'" -f
            $result.ExitCode, (Test-Path -LiteralPath $ownedDetached.Path),
            $row.teardown_branch, $row.teardown_sha)

    $main = New-FixtureRepo -Name 'owned-refused-main'
    $ownedRefused = New-FixtureWorktree -Fixture $main -Name 'owned-refused'
    $missingClassifier = Join-Path $testRoot 'missing-critical-classifier.ps1'
    $result = Invoke-DispatchCase -CaseName 'owned lease-scoped preflight refusal' `
        -Spec 'task5-owned-refused' -Fixture $ownedRefused -FakePath $noWriteFake `
        -ExtraParameters @{
            OwnedWorktree = $true
            CriticalFilesScript = $missingClassifier
        }
    $refusedLease = @($result.Rows |
        Where-Object { [string]$_.row_kind -ceq 'lease' }) | Select-Object -Last 1
    Assert-Case -Label 'terminal refused-preflight lease still tears down clean never-built tree' `
        -Condition ($result.ExitCode -eq 76 -and -not (Test-Path -LiteralPath $ownedRefused.Path) -and
            (Test-CompleteTeardownFields $refusedLease) -and
            [string]$refusedLease.cleanup_obligation -ceq '' -and
            [string]$refusedLease.branch_teardown_obligation -ceq $ownedRefused.Branch) `
        -Detail ("exit={0}, exists={1}, cleanup='{2}', branch='{3}'" -f
            $result.ExitCode, (Test-Path -LiteralPath $ownedRefused.Path),
            $refusedLease.cleanup_obligation, $refusedLease.branch_teardown_obligation)

    # Force Add-LeaseCloseRow's real duplicate guard to throw from the refusal backstop. The first
    # injected call closes the lease; the original call then attempts the forbidden second append.
    $backstopFailureDispatcher = New-ScopeStubDispatcher `
        -Name 'stub-backstop-append-failure' -Mode 'missing-written-paths'
    $backstopFailureSource = [System.IO.File]::ReadAllText($backstopFailureDispatcher)
    $backstopAppendLine =
        "            Add-LeaseCloseRow -RunId `$runId -Status 'refused-preflight' -RefusalExit `$script:pendingExitCode"
    $backstopFailureFixtureSource = $backstopFailureSource.Replace(
        $backstopAppendLine,
        $backstopAppendLine + [Environment]::NewLine + $backstopAppendLine)
    if ($backstopFailureFixtureSource -ceq $backstopFailureSource) {
        throw 'Could not construct the refusal backstop append-failure fixture.'
    }
    Write-Utf8NoBom -Path $backstopFailureDispatcher -Content $backstopFailureFixtureSource
    $result = Invoke-DispatchCase -CaseName 'refusal survives lease-close backstop append failure' `
        -Spec 'task2a-backstop-append-failure' -Fixture $fixture -FakePath $noWriteFake `
        -DispatcherPath $backstopFailureDispatcher `
        -ExtraParameters @{ CriticalFilesScript = $missingClassifier }
    Assert-Case -Label 'lease-close backstop failure cannot mask contractual refusal exit' `
        -Condition ($result.ExitCode -eq 76 -and
            $result.Output.Contains('[dispatch] refusal lease-close backstop failed:')) `
        -Detail ("exit={0}, loud_failure={1}" -f $result.ExitCode,
            $result.Output.Contains('[dispatch] refusal lease-close backstop failed:'))

    # Drive the production declared_runtime_paths refusal. The spec is valid, but its declared
    # runtime artifact is absent from the commit, so the real pre-flight site returns exit 81.
    $main = New-FixtureRepo -Name 'owned-exit81-main'
    $exit81Spec = 'task5-owned-exit81'
    $exit81RuntimePath = 'runtime/invisible-tool.bin'
    Write-Utf8NoBom -Path (Join-Path $main.Path "docs\changes\$exit81Spec.md") -Content @"
---
spec: $exit81Spec
status: draft
autonomy_level: L2
declared_runtime_paths:
  - $exit81RuntimePath
---
# Spec: fixture placeholder
## Intent
- Intent: exercise the production exit-81 teardown path.
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
    Invoke-FixtureGit -Repo $main.Path -GitArguments @('add', '-A') | Out-Null
    Invoke-FixtureGit -Repo $main.Path -GitArguments @('commit', '-q', '-m', 'add exit-81 spec') | Out-Null
    $main.BaseSha = ([string]@(Invoke-FixtureGit -Repo $main.Path `
                -GitArguments @('rev-parse', 'HEAD'))[0]).Trim()
    $ownedExit81 = New-FixtureWorktree -Fixture $main -Name 'owned-exit81'
    $result = Invoke-DispatchCase -CaseName 'owned exit-81 clean preflight refusal' `
        -Spec $exit81Spec -Fixture $ownedExit81 -FakePath $noWriteFake `
        -ExtraParameters @{
            OwnedWorktree = $true
            SkipBaselineCheck = $false
        }
    $exit81Lease = @($result.Rows |
        Where-Object { [string]$_.row_kind -ceq 'lease' }) | Select-Object -Last 1
    Assert-Case -Label 'exit 81 removes an owned clean never-built worktree' `
        -Condition ($result.ExitCode -eq 81 -and -not (Test-Path -LiteralPath $ownedExit81.Path) -and
            (Test-CompleteTeardownFields $exit81Lease) -and
            [string]$exit81Lease.cleanup_obligation -ceq '' -and
            [string]$exit81Lease.branch_teardown_obligation -ceq $ownedExit81.Branch -and
            $result.Output.Contains($exit81RuntimePath)) `
        -Detail ("exit={0}, exists={1}, cleanup='{2}', branch='{3}', runtime_evidence={4}" -f
            $result.ExitCode, (Test-Path -LiteralPath $ownedExit81.Path),
            $exit81Lease.cleanup_obligation, $exit81Lease.branch_teardown_obligation,
            $result.Output.Contains($exit81RuntimePath))

    $main = New-FixtureRepo -Name 'owned-prelease-main'
    $ownedPrelease = New-FixtureWorktree -Fixture $main -Name 'owned-prelease'
    $capacitySiblingId = 'task5-capacity-sibling'
    Add-TestLedgerRow -Row (New-TestSiblingRow -RunId $capacitySiblingId `
        -Worktree $ownedPrelease -Status 'running' -Spec 'task5-capacity-occupant')
    $result = Invoke-DispatchCase -CaseName 'owned prelease at-capacity refusal obligation' `
        -Spec 'task5-owned-prelease' -Fixture $ownedPrelease -FakePath $noWriteFake `
        -ExtraParameters @{ OwnedWorktree = $true; MachineCeiling = 1 }
    $standaloneObligation = @($result.Rows |
        Where-Object { [string]$_.row_kind -ceq 'obligation' }) | Select-Object -Last 1
    Assert-Case -Label 'pre-lease exit 79 retains tree in standalone obligation event' `
        -Condition ($result.ExitCode -eq 79 -and (Test-Path -LiteralPath $ownedPrelease.Path) -and
            (Test-CompleteTeardownFields $standaloneObligation) -and
            [int]$standaloneObligation.refusal_exit -eq 79 -and
            [string]$standaloneObligation.cleanup_obligation -like
                "*live sibling $capacitySiblingId*") `
        -Detail ("exit={0}, exists={1}, kind='{2}', refusal_exit={3}, obligation='{4}'" -f
            $result.ExitCode, (Test-Path -LiteralPath $ownedPrelease.Path),
            $standaloneObligation.row_kind, $standaloneObligation.refusal_exit,
            $standaloneObligation.cleanup_obligation)
    Set-TestLedgerRowStatus -RunId $capacitySiblingId -Status 'done'

    # Make creator teardown append its standalone obligation and then throw. The outer catch retries
    # the same (run_id, row_kind) record, which must update/ignore the first event rather than append.
    $recordThenThrowDispatcher = New-ScopeStubDispatcher `
        -Name 'stub-record-then-throw' -Mode 'missing-written-paths'
    $recordThenThrowSource = [System.IO.File]::ReadAllText($recordThenThrowDispatcher)
    $postRecordLine = '                Write-Host $record.cleanup_obligation -ForegroundColor Yellow'
    $recordThenThrowFixtureSource = $recordThenThrowSource.Replace(
        $postRecordLine, "                throw 'forced post-record creator teardown failure'")
    if ($recordThenThrowFixtureSource -ceq $recordThenThrowSource) {
        throw 'Could not construct the record-then-throw creator teardown fixture.'
    }
    Write-Utf8NoBom -Path $recordThenThrowDispatcher -Content $recordThenThrowFixtureSource
    $main = New-FixtureRepo -Name 'owned-record-then-throw-main'
    $ownedRecordThenThrow = New-FixtureWorktree -Fixture $main -Name 'owned-record-then-throw'
    $recordThenThrowSiblingId = 'task8-record-then-throw-sibling'
    Add-TestLedgerRow -Row (New-TestSiblingRow -RunId $recordThenThrowSiblingId `
        -Worktree $ownedRecordThenThrow -Status 'running' -Spec 'task8-record-then-throw-occupant')
    $result = Invoke-DispatchCase -CaseName 'record then throw standalone obligation' `
        -Spec 'task8-record-then-throw' -Fixture $ownedRecordThenThrow -FakePath $noWriteFake `
        -DispatcherPath $recordThenThrowDispatcher `
        -ExtraParameters @{ OwnedWorktree = $true; MachineCeiling = 1 }
    $recordThenThrowObligations = @($result.Rows |
        Where-Object { [string]$_.row_kind -ceq 'obligation' })
    Assert-Case -Label 'record-then-throw retry leaves exactly one standalone obligation' `
        -Condition ($result.ExitCode -eq 79 -and $recordThenThrowObligations.Count -eq 1 -and
            (Test-CompleteTeardownFields $recordThenThrowObligations[0])) `
        -Detail ("exit={0}, obligation_count={1}" -f
            $result.ExitCode, $recordThenThrowObligations.Count)
    Set-TestLedgerRowStatus -RunId $recordThenThrowSiblingId -Status 'done'

    Write-Host "`n===== CASE: parameterless obligation listing =====" -ForegroundColor Cyan
    $listOutputLines = @(& $dispatch -ListObligations *>&1 | ForEach-Object { $_.ToString() })
    $listExit = $LASTEXITCODE
    $listOutput = $listOutputLines -join [Environment]::NewLine
    if ($listOutput) { Write-Host $listOutput }
    $liveRemovalCommand = 'git -C "{0}" worktree remove "{1}"' -f
        $liveRefusalRow.teardown_main_repo, $liveRefusalRow.teardown_worktree
    $standaloneRemovalCommand = 'git -C "{0}" worktree remove "{1}"' -f
        $standaloneObligation.teardown_main_repo, $standaloneObligation.teardown_worktree
    Assert-Case -Label 'ListObligations needs no dispatch parameters and uses structured commands' `
        -Condition ($listExit -eq 0 -and $listOutput.Contains($liveSiblingId) -and
            $listOutput.Contains($liveRemovalCommand) -and
            $listOutput.Contains([string]$standaloneObligation.run_id) -and
            $listOutput.Contains($standaloneRemovalCommand) -and
            $listOutput.Contains($successBranchCommand)) `
        -Detail ("exit={0}, live_command={1}, standalone_command={2}, branch_command={3}" -f
            $listExit, $listOutput.Contains($liveRemovalCommand),
            $listOutput.Contains($standaloneRemovalCommand),
            $listOutput.Contains($successBranchCommand))

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $commandOneOutput = @(& powershell.exe -NoProfile -Command $liveRemovalCommand 2>&1)
        $commandOneExit = $LASTEXITCODE
        $commandTwoOutput = @(& powershell.exe -NoProfile -Command $standaloneRemovalCommand 2>&1)
        $commandTwoExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    Assert-Case -Label 'listed sibling and standalone commands are copy-paste runnable as-is' `
        -Condition ($commandOneExit -eq 0 -and $commandTwoExit -eq 0 -and
            -not (Test-Path -LiteralPath $ownedLive.Path) -and
            -not (Test-Path -LiteralPath $ownedPrelease.Path)) `
        -Detail ("sibling_exit={0} ({1}); standalone_exit={2} ({3})" -f
            $commandOneExit, ($commandOneOutput -join '; '),
            $commandTwoExit, ($commandTwoOutput -join '; '))

    $forbiddenTeardownPatterns = @(Select-String -Path $dispatch `
        -Pattern 'worktree remove.*--force|branch -[dD]')
    Assert-Case -Label 'dispatcher contains no force-remove or branch-delete invocation' `
        -Condition ($forbiddenTeardownPatterns.Count -eq 0) `
        -Detail ("forbidden_matches={0}" -f $forbiddenTeardownPatterns.Count)
}
catch {
    $script:failureCount++
    Write-Host "`nFAIL  suite setup/execution threw: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}
finally {
    foreach ($name in $oldEnvironment.Keys) {
        Set-OptionalEnvironmentValue -Name $name -Value $oldEnvironment[$name]
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n===== DISPATCH SUITE SUMMARY =====" -ForegroundColor Cyan
Write-Host ("Assertions: {0}; failures: {1}" -f $script:assertionCount, $script:failureCount)
if ($script:failureCount -gt 0) { exit 1 }
exit 0
