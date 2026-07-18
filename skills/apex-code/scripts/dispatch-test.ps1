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
        'FAKE_CODEX_EXTRA_WRITE', 'FAKE_CODEX_STATUS', 'FAKE_CODEX_NO_REPORT', 'FAKE_CODEX_VERDICT')) {
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

function Test-HasProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)
    return ($null -ne $Object -and @($Object.PSObject.Properties.Name) -ccontains $Name)
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

try {
    [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($scratchRoot) | Out-Null
    $env:APEX_STATE_DIR = $stateRoot

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
