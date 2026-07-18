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
        [hashtable]$FakeEnvironment = @{}
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
    }
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
    [System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory((Split-Path $ledgerPath -Parent)) | Out-Null
    [System.IO.Directory]::CreateDirectory($scratchRoot) | Out-Null
    # Pre-create the empty isolated ledger so the wrapper cannot import any legacy ledger.
    Write-Utf8NoBom -Path $ledgerPath -Content ''
    $env:APEX_STATE_DIR = $stateRoot

    $spec = New-UniqueSpec -CaseName 'red'
    $repo = New-FixtureRepo -Name 'red' -AgentsContent $redRecipe
    $result = Invoke-DispatchCase -CaseName 'RED baseline' -Spec $spec -Repo $repo -FakeRepo $repo
    Assert-Case -Label 'RED baseline exit' -Condition ($result.ExitCode -eq 72) -Detail "expected 72, got $($result.ExitCode)"
    Assert-Case -Label 'RED baseline ledger' -Condition ($result.Rows.Count -eq 0) -Detail "expected zero rows, got $($result.Rows.Count)"
    Assert-PreflightPinCleaned -CaseName 'RED baseline' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'unparseable'
    $repo = New-FixtureRepo -Name 'unparseable' -AgentsContent $unparseableRecipe
    $result = Invoke-DispatchCase -CaseName 'UNPARSEABLE recipe' -Spec $spec -Repo $repo -FakeRepo $repo
    Assert-Case -Label 'UNPARSEABLE exit' -Condition ($result.ExitCode -eq 72) -Detail "expected 72, got $($result.ExitCode)"
    Assert-Case -Label 'UNPARSEABLE ledger' -Condition ($result.Rows.Count -eq 0) -Detail "expected zero rows, got $($result.Rows.Count)"
    Assert-PreflightPinCleaned -CaseName 'UNPARSEABLE' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'no-recipe'
    $repo = New-FixtureRepo -Name 'no-recipe' -AgentsContent $null
    $result = Invoke-DispatchCase -CaseName 'NO_RECIPE' -Spec $spec -Repo $repo -FakeRepo $repo
    Assert-Case -Label 'NO_RECIPE exit' -Condition ($result.ExitCode -eq 72) -Detail "expected 72, got $($result.ExitCode)"
    Assert-Case -Label 'NO_RECIPE ledger' -Condition ($result.Rows.Count -eq 0) -Detail "expected zero rows, got $($result.Rows.Count)"
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
    Assert-Case -Label 'validator-fail ledger' -Condition ($result.Rows.Count -eq 0) -Detail "expected zero rows, got $($result.Rows.Count)"
    Assert-Case -Label 'validator-fail evidence' -Condition ($result.Output -match 'FAIL FILES-COMPLETENESS') -Detail 'dispatcher printed the validator finding'
    Assert-PreflightPinCleaned -CaseName 'validator-fail' -Spec $spec

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
    Assert-Case -Label 'cross-tree-no-source ledger' -Condition ($result.Rows.Count -eq 0) -Detail "expected zero rows, got $($result.Rows.Count)"
    Assert-NoCodexLog -CaseName 'cross-tree-no-source' -Spec $spec
    Assert-PreflightPinCleaned -CaseName 'cross-tree-no-source' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'cross-tree-valid'
    $greenSpec = New-GreenFixtureSpec -Spec $spec
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
    Assert-Case -Label 'cross-tree-missing ledger' -Condition ($result.Rows.Count -eq 0) -Detail "expected zero rows, got $($result.Rows.Count)"
    Assert-NoCodexLog -CaseName 'cross-tree-missing' -Spec $spec
    Assert-PreflightPinCleaned -CaseName 'cross-tree-missing' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'cross-tree-invalid'
    $specSourcePath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $testRoot 'external-specs\invalid') "$spec.md"))
    Write-Utf8NoBom -Path $specSourcePath -Content $invalidSpec
    $repo = New-FixtureRepo -Name 'cross-tree-invalid' -AgentsContent $greenRecipe
    $result = Invoke-DispatchCase -CaseName 'CROSS-TREE invalid SpecSourcePath' -Spec $spec -Repo $repo -FakeRepo $repo -ExtraParameters @{ SpecSourcePath = $specSourcePath }
    Assert-Case -Label 'cross-tree-invalid exit' -Condition ($result.ExitCode -eq 72) -Detail "expected 72, got $($result.ExitCode)"
    Assert-Case -Label 'cross-tree-invalid ledger' -Condition ($result.Rows.Count -eq 0) -Detail "expected zero rows, got $($result.Rows.Count)"
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
    Assert-Case -Label 'cross-tree-mismatch ledger' -Condition ($result.Rows.Count -eq 0) -Detail "expected zero rows, got $($result.Rows.Count)"
    Assert-NoCodexLog -CaseName 'cross-tree-mismatch' -Spec $spec
    Assert-PreflightPinCleaned -CaseName 'cross-tree-mismatch' -Spec $spec

    $spec = New-UniqueSpec -CaseName 'cross-tree-relative'
    $specSourcePath = "docs\changes\$spec.md"
    $repo = New-FixtureRepo -Name 'cross-tree-relative' -AgentsContent $greenRecipe
    $result = Invoke-DispatchCase -CaseName 'CROSS-TREE relative SpecSourcePath' -Spec $spec -Repo $repo -FakeRepo $repo -ExtraParameters @{ SpecSourcePath = $specSourcePath }
    Assert-Case -Label 'cross-tree-relative exit' -Condition ($result.ExitCode -eq 72) -Detail "expected 72, got $($result.ExitCode)"
    Assert-Case -Label 'cross-tree-relative ledger' -Condition ($result.Rows.Count -eq 0) -Detail "expected zero rows, got $($result.Rows.Count)"
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
    Assert-Case -Label 'cross-tree-drive-relative ledger' -Condition ($result.Rows.Count -eq 0) -Detail "expected zero rows, got $($result.Rows.Count)"
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
    $repo = New-FixtureRepo -Name 'skip-baseline' -AgentsContent $redRecipe
    $result = Invoke-DispatchCase -CaseName 'SkipBaselineCheck bypass' -Spec $spec -Repo $repo -FakeRepo $repo -ExtraParameters @{ SkipBaselineCheck = $true } -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    Assert-Case -Label 'skip-baseline proceeds' -Condition ($result.ExitCode -ne 72) -Detail "red recipe bypassed the baseline (exit $($result.ExitCode))"
    Assert-Case -Label 'skip-baseline success' -Condition ($result.ExitCode -eq 0) -Detail "expected fake coder success 0, got $($result.ExitCode)"
    Assert-Case -Label 'skip-baseline ledger presence' -Condition ($result.Rows.Count -eq 1) -Detail "expected one row, got $($result.Rows.Count)"
    Assert-Case -Label 'skip-baseline ledger flag' -Condition ($result.Rows.Count -eq 1 -and $result.Rows[0].baseline_skipped -eq $true) -Detail "baseline_skipped=$($result.Rows[0].baseline_skipped)"
    Assert-Case -Label 'skip-baseline loud note' -Condition ($result.Output -match 'baseline/spec pre-flight BYPASSED') -Detail 'bypass note was printed'
    Assert-PreflightPinCleaned -CaseName 'skip-baseline' -Spec $spec

    Write-Host "`nSKIP  OPTIONAL exit-71 pin cleanup -- reviewer-traced to the outer preflight arm-to-launch try/finally in codex-dispatch.ps1." -ForegroundColor Yellow
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

Write-Host "`n===== PREFLIGHT SUITE SUMMARY =====" -ForegroundColor Cyan
Write-Host ("Assertions: {0}; failures: {1}" -f $script:assertionCount, $script:failureCount)
if ($script:failureCount -gt 0) {
    Write-Host 'dispatch-preflight-test.ps1 FAILED' -ForegroundColor Red
    exit 1
}

Write-Host 'dispatch-preflight-test.ps1 PASSED' -ForegroundColor Green
exit 0
