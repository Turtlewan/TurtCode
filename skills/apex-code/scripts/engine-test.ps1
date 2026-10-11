[CmdletBinding()]
param([switch]$AcceptanceOnly)

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $env:TEMP ('engine-test-' + [Guid]::NewGuid().ToString('N'))
$machineLocalRoot = Join-Path $env:TEMP ('engine-test-machine-' + [Guid]::NewGuid().ToString('N'))
$engine = Join-Path $PSScriptRoot 'apex-engine.ps1'
$schemaPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'references\engine-state-schema.json'
$utf8 = New-Object Text.UTF8Encoding($false)
$failures = 0
$oldState = $env:APEX_STATE_DIR
$oldLocalAppData = $env:LOCALAPPDATA
$oldRetry = $env:APEX_ENGINE_TEST_RETRY_DELAY_SECONDS
$oldGlobal = $env:GIT_CONFIG_GLOBAL
$oldTestMode = $env:APEX_ENGINE_TEST_MODE
$oldImportOnly = $env:APEX_ENGINE_TEST_IMPORT_ONLY
$oldScenario = $env:ENGINE_TEST_FAKE_SCENARIO
$oldDelay = $env:ENGINE_TEST_FAKE_DELAY
$oldBaselinePath = $env:APEX_ENGINE_TEST_BASELINE_PATH
$oldTreePinPath = $env:APEX_ENGINE_TEST_TREE_PIN_PATH
$oldCriticalPath = $env:APEX_ENGINE_TEST_CRITICAL_PATH
$oldIgnoreLedger = $env:APEX_ENGINE_TEST_IGNORE_RESUME_LEDGER
$oldCommitCrash = $env:APEX_ENGINE_TEST_CRASH_AFTER_WAVE_COMMIT
$oldLadderCrash = $env:APEX_ENGINE_TEST_CRASH_AFTER_VERIFICATION_FAILURE
$oldHandoffCrash = $env:APEX_ENGINE_TEST_FAIL_BEFORE_HANDOFF_JOURNAL
$oldIdentityFailure = $env:APEX_ENGINE_TEST_FAIL_INDEX_IDENTITY
$oldWriteTreeFailure = $env:APEX_ENGINE_TEST_FAIL_WRITE_TREE
$oldResidueCaptureFailure = $env:APEX_ENGINE_TEST_FAIL_RESIDUE_CAPTURE
$oldAgentsFetchFailure = $env:APEX_ENGINE_TEST_FAIL_AGENTS_FETCH
$oldAgentsFetchTrace = $env:APEX_ENGINE_TEST_AGENTS_FETCH_TRACE_PATH
$oldStageTrace = $env:APEX_ENGINE_TEST_STAGE_TRACE_PATH

function Write-TestText {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function New-TestGateBaseline {
    param([string]$Path)
    Write-TestText $Path @'
param([switch]$Full, [string]$Worktree)
$counter = Join-Path $env:ENGINE_TEST_GATE_COUNTER 'baseline.txt'
$count = if (Test-Path $counter) { [int](Get-Content $counter -Raw) } else { 0 }
$count++; [IO.File]::WriteAllText($counter, [string]$count)
if ($env:ENGINE_TEST_BASELINE_SEQUENCE) {
    $sequence = @($env:ENGINE_TEST_BASELINE_SEQUENCE -split ',')
    if ($count -le $sequence.Count) { exit ([int]$sequence[$count - 1]) }
}
Write-Host "baseline diagnosis $env:ENGINE_TEST_BASELINE_EXIT"
exit ([int]$env:ENGINE_TEST_BASELINE_EXIT)
'@

}

function Invoke-TestGit {
    param([string]$Repo, [string[]]$Arguments)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $output = @(& git -C $Repo @Arguments 2>&1 | ForEach-Object { [string]$_ }); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { throw "git failed ($code): $($output -join ' | ')" }
    return ,$output
}

function Set-TestCommit {
    param([string]$Repo, [string[]]$Paths, [string]$Parent)
    foreach ($relative in $Paths) {
        $full = Join-Path $Repo ($relative.Replace('/', '\'))
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $hash = (Invoke-TestGit $Repo @('hash-object', '-w', '--', $full))[-1]
            [void](Invoke-TestGit $Repo @('update-index', '--add', '--cacheinfo', "100644,$hash,$relative"))
        } else { [void](Invoke-TestGit $Repo @('update-index', '--force-remove', '--', $relative)) }
    }
    $tree = (Invoke-TestGit $Repo @('write-tree'))[-1]
    $oldAuthorEmail = $env:GIT_AUTHOR_EMAIL; $oldAuthorName = $env:GIT_AUTHOR_NAME
    $oldCommitterEmail = $env:GIT_COMMITTER_EMAIL; $oldCommitterName = $env:GIT_COMMITTER_NAME
    try {
        $env:GIT_AUTHOR_EMAIL = 'engine@example.invalid'; $env:GIT_AUTHOR_NAME = 'Engine Test'
        $env:GIT_COMMITTER_EMAIL = 'engine@example.invalid'; $env:GIT_COMMITTER_NAME = 'Engine Test'
        $arguments = @('commit-tree', $tree)
        if ($Parent) { $arguments += @('-p', $Parent) }
        $commit = @('fixture' | & git -C $Repo @arguments 2>&1 | ForEach-Object { [string]$_ })[-1]
        if ($LASTEXITCODE -ne 0) { throw 'commit-tree failed' }
        [void](Invoke-TestGit $Repo @('update-ref', 'HEAD', $commit))
        return $commit
    } finally {
        $env:GIT_AUTHOR_EMAIL = $oldAuthorEmail; $env:GIT_AUTHOR_NAME = $oldAuthorName
        $env:GIT_COMMITTER_EMAIL = $oldCommitterEmail; $env:GIT_COMMITTER_NAME = $oldCommitterName
    }
}

function Assert-Test {
    param([string]$Name, [bool]$Condition, [string]$Detail)
    if ($Condition) { Write-Host "PASS: $Name"; return }
    $script:failures++
    Write-Host "FAIL: $Name -- $Detail" -ForegroundColor Red
}

function New-TestRepo {
    param([string]$Name, [string]$BuildOutput)
    $repo = Join-Path $testRoot $Name
    [void][IO.Directory]::CreateDirectory($repo)
    [void](Invoke-TestGit $repo @('init', '-q'))
    [void](Invoke-TestGit $repo @('config', 'core.autocrlf', 'true'))
    Write-TestText (Join-Path $repo '.gitignore') "*`n!residue-untracked.txt`n"
    Write-TestText (Join-Path $repo '.gitattributes') "*.py text`n"
    Write-TestText (Join-Path $repo 'src\a.py') "base-a`n"
    Write-TestText (Join-Path $repo 'verify.ps1') @'
$bad = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter '*.py' -File -ErrorAction SilentlyContinue |
    Select-String -SimpleMatch 'VERIFY_FAIL')
if ($bad.Count -gt 0) { Write-Host 'fixture verification failed'; exit 1 }
Write-Host 'fixture verification passed'
exit 0
'@
    Write-TestText (Join-Path $repo 'AGENTS.md') @'
# Engine fixture

## Verify commands

```powershell
powershell.exe -NoProfile -File verify.ps1
```

## Preflight commands

```powershell
powershell.exe -NoProfile -File verify.ps1
```

## Build outputs

```text
src/*/bin
```
'@
    $paths = @('.gitignore', '.gitattributes', 'src/a.py', 'verify.ps1', 'AGENTS.md')
    if ($BuildOutput) {
        # Keep parents visible so status and persisted diagnoses name the individual file.
        Write-TestText (Join-Path $repo '.gitignore') "src/*/bin/*.dat`nscratch/*.dat`n"
        Write-TestText (Join-Path $repo 'src/widget/bin/anchor.txt') "tracked anchor`n"
        Write-TestText (Join-Path $repo 'scratch/anchor.txt') "tracked anchor`n"
        $paths += @('src/widget/bin/anchor.txt', 'scratch/anchor.txt')
        $outputPath = 'src/widget/bin/generated.dat'
        if ($BuildOutput -in @('undeclared', 'working-only')) { $outputPath = 'scratch/generated.dat' }
        if ($BuildOutput -ceq 'unignored') { $outputPath = 'src/widget/bin/untracked.txt' }
        $agents = [IO.File]::ReadAllText((Join-Path $repo 'AGENTS.md'))
        $command = "[IO.File]::WriteAllBytes((Join-Path (Get-Location).Path '$outputPath'), [byte[]]@(0,255,13,10,128,65,0))"
        if ($BuildOutput -ceq 'working-only') {
            $command = "`$agentsPath = Join-Path (Get-Location).Path 'AGENTS.md'; [IO.File]::WriteAllText(`$agentsPath, ([IO.File]::ReadAllText(`$agentsPath).Replace('src/*/bin', 'src/*/bin' + [Environment]::NewLine + 'scratch')), (New-Object Text.UTF8Encoding(`$false))); " + $command
        }
        # Only the full verify fence produces output; dispatch preflight stays clean.
        $agents = $agents.Replace("## Verify commands`n`n``````powershell`npowershell.exe -NoProfile -File verify.ps1",
            "## Verify commands`n`n``````powershell`npowershell.exe -NoProfile -File verify.ps1`n$command")
        # Here-strings in this source can contain CRLF on Windows.
        $agents = $agents.Replace("## Verify commands`r`n`r`n``````powershell`r`npowershell.exe -NoProfile -File verify.ps1",
            "## Verify commands`r`n`r`n``````powershell`r`npowershell.exe -NoProfile -File verify.ps1`r`n$command")
        Write-TestText (Join-Path $repo 'AGENTS.md') $agents
    }
    [void](Set-TestCommit $repo $paths $null)
    return $repo
}

function Convert-TestPath {
    param([string]$Path)
    ([IO.Path]::GetFullPath($Path)).Replace('\', '/')
}

function New-TestSpec {
    param(
        [string]$Repo, [string]$Path, [switch]$Critical, [switch]$Single,
        [string]$FirstId = '1', [string]$SecondId = '2',
        [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')][string]$Effort = 'medium',
        [string]$Risk = 'medium', [switch]$TwoWave, [switch]$IgnoredFile,
        [string]$AcceptanceText, [switch]$Delete
    )
    $emDash = [string][char]0x2014
    $firstPath = if ($Critical) { '.github/workflows/build.yml' } else { 'src/a.py' }
    $firstOp = if ($Critical) { 'create' } else { 'modify' }
    if ($IgnoredFile) { $firstPath = 'src/widget/bin/payload.dat'; $firstOp = 'create' }
    if ($Delete) { $firstOp = 'delete' }
    $omitSecond = $Critical -or $Single
    $secondTask = if ($omitSecond) { '' } else { "- [ ] **Task $SecondId** - Create the second fixture file. $emDash files: src/b.py $emDash done when: the second fixture file exists." }
    $secondDepends = if ($TwoWave) { '["1"]' } else { '[]' }
    $secondManifest = if ($omitSecond) { '' } else { ", { `"id`": `"$SecondId`", `"repo`": `"main`", `"files`": [{ `"path`": `"src/b.py`", `"op`": `"create`" }], `"depends_on`": $secondDepends }" }
    $secondAcceptance = if ($omitSecond) { '' } else { "- [ ] Task $SecondId - second file is executable -> verify: run the fixture command." }
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    $repoJson = (Convert-TestPath $Repo).Replace('\', '\\').Replace('"', '\"')
    $text = @"
---
spec: $name
status: approved
autonomy_level: L2
risk: $Risk
coder_model: gpt-5.6-sol
coder_effort: $Effort
max_parallel_codex: 2
---

# Spec: Engine fixture

**Identity:** Build an Engine end-to-end fixture.

## Intent
- **Intent:** Build two scoped fixture files.
- **Invariants:** Keep writes within the fixture paths.
- **Non-goals:** No external access.

## Assumptions
- Windows PowerShell and Git are available.

## Prerequisites
- The fixture repository is initialized.

## Files to Change
| File | Operation | Notes |
|---|---|---|
| $firstPath | $firstOp | fixture |
    $(if (-not $omitSecond) { '| src/b.py | create | fixture |' })

## Execution manifest
``````json apex-manifest
{ "version": 1, "repos": { "main": "$repoJson" }, "tasks": [{ "id": "$FirstId", "repo": "main", "files": [{ "path": "$firstPath", "op": "$firstOp" }], "depends_on": [] }$secondManifest] }
``````

## Tasks
- [ ] **Task $FirstId** - Change the first fixture file. $emDash files: $firstPath $emDash done when: the first fixture file is changed.
$secondTask
## Wave plan
$(if ($TwoWave) { '- Wave 1: Task 1. Wave 2: Task 2.' } else { '- Tasks 1 and 2 are parallel.' })

## Permissions
- The manifest paths may be changed.

## Specialist Context
### Security
Keep fixture writes scoped.

### Accessibility
(none)

## Documentation
- No documentation changes.

## Acceptance Criteria
- [ ] Task $FirstId - first file is executable -> verify: run the fixture command.
$secondAcceptance

## Progress
- Test fixture.
"@
    if ($AcceptanceText) { $text = [regex]::Replace($text, '(?ms)(## Acceptance Criteria\r?\n).*?(?=\r?\n## Progress)', ('$1' + $AcceptanceText + "`n")) }
    Write-TestText $Path $text
}

function New-TestRoutingSpec {
    param(
        [string]$Repo, [string]$Path, [int]$TaskCount,
        [AllowNull()][object]$SpecCeiling = $null,
        [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')][string]$Effort = 'medium'
    )
    $emDash = [string][char]0x2014
    $manifestTasks = @()
    $fileRows = @()
    $taskRows = @()
    $acceptanceRows = @()
    for ($index = 1; $index -le $TaskCount; $index++) {
        $relative = "src/task-$index.py"
        $manifestTasks += [pscustomobject][ordered]@{
            id = [string]$index; repo = 'main'
            files = @([pscustomobject][ordered]@{ path = $relative; op = 'create' })
            depends_on = @(); effort = $Effort
        }
        $fileRows += "| $relative | create | routing fixture |"
        $taskRows += "- [ ] **Task $index** - Create routing fixture $index. $emDash files: $relative $emDash done when: the file exists."
        $acceptanceRows += "- [ ] Task $index - routing fixture exists -> verify: inspect the file."
    }
    $manifest = [ordered]@{
        version = 1; repos = [ordered]@{ main = (Convert-TestPath $Repo) }; tasks = $manifestTasks
    } | ConvertTo-Json -Depth 12 -Compress
    $ceilingLine = if ($null -ne $SpecCeiling) { "max_parallel_codex: $SpecCeiling`n" } else { '' }
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    $text = @"
---
spec: $name
status: approved
autonomy_level: L2
risk: medium
coder_model: gpt-5.6-sol
coder_effort: $Effort
${ceilingLine}---

# Spec: Engine routing fixture

**Identity:** Exercise Engine capacity routing.

## Intent
- **Intent:** Plan independent routing fixtures.
- **Invariants:** Keep writes within manifest paths.
- **Non-goals:** No external access.

## Assumptions
- Windows PowerShell and Git are available.

## Prerequisites
- The fixture repository is initialized.

## Files to Change
| File | Operation | Notes |
|---|---|---|
$($fileRows -join "`n")

## Execution manifest
``````json apex-manifest
$manifest
``````

## Tasks
$($taskRows -join "`n")

## Wave plan
- Independent tasks are split only by the effective slot cap.

## Permissions
- The manifest paths may be changed.

## Specialist Context
### Security
Keep fixture writes scoped.

### Accessibility
(none)

## Documentation
- No documentation changes.

## Acceptance Criteria
$($acceptanceRows -join "`n")

## Progress
- Test fixture.
"@
    Write-TestText $Path $text
}

function New-TestFakeCodex {
    param([string]$Path)
    Write-TestText $Path @'
$raw = $args
$prompt = [Console]::In.ReadToEnd()
$repo = $null; $final = $null
for ($i = 0; $i -lt $raw.Count - 1; $i++) {
    if ($raw[$i] -ceq '-C') { $repo = [string]$raw[$i + 1] }
    if ($raw[$i] -ceq '-o') { $final = [string]$raw[$i + 1] }
}
if (-not $repo -or -not $final -or [string]::IsNullOrWhiteSpace($prompt)) { exit 1 }
if ($env:ENGINE_TEST_FAKE_DELAY -match '^\d+$') { Start-Sleep -Seconds ([int]$env:ENGINE_TEST_FAKE_DELAY) }
$leaf = Split-Path -Leaf $repo
$task = if ($leaf -match '-(?<task>\d+)-a\d+$') { $Matches.task } else { $null }
$joined = $raw -join ' '
$effort = if ($joined -match 'model_reasoning_effort[^a-z]+(?<effort>low|medium|high|xhigh|max|ultra)') { $Matches.effort } else { 'medium' }
$scenario = if ($env:ENGINE_TEST_FAKE_SCENARIO) { $env:ENGINE_TEST_FAKE_SCENARIO } else { 'done' }
if ($scenario -ceq 'rate_limit_429') {
    [Console]::Out.WriteLine("{`"type`":`"thread.started`",`"thread_id`":`"019f7719-db8a-7710-8bda-11f65acd0899`"}")
    [Console]::Out.WriteLine("{`"type`":`"turn.started`"}")
    [Console]::Out.WriteLine("{`"type`":`"error`",`"message`":`"429 Too Many Requests: retry later`"}")
    [Console]::Out.WriteLine("{`"type`":`"turn.failed`",`"error`":{`"message`":`"request failed with status: 429`"}}")
    exit 1
}
if ($scenario -ceq 'usage_limit_jsonl') {
    [Console]::Out.WriteLine("{`"type`":`"thread.started`",`"thread_id`":`"019f7719-db8a-7710-8bda-11f65acd0899`"}")
    [Console]::Out.WriteLine("{`"type`":`"turn.started`"}")
    [Console]::Out.WriteLine("{`"type`":`"error`",`"message`":`"You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Jul 25th, 2026 11:24 AM.`"}")
    [Console]::Out.WriteLine("{`"type`":`"turn.failed`",`"error`":{`"message`":`"You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Jul 25th, 2026 11:24 AM.`"}}")
    exit 1
}
if ($scenario -ceq 'agent_message_quota_quote') {
    [Console]::Out.WriteLine("{`"type`":`"item.completed`",`"item`":{`"type`":`"agent_message`",`"text`":`"The captured diagnostic says: You've hit your usage limit. Visit settings for details.`"}}")
    exit 1
}
if ($scenario -ceq 'agent_message_command_429') {
    [Console]::Out.WriteLine("{`"type`":`"item.completed`",`"item`":{`"type`":`"agent_message`",`"text`":`"quoted 429 Too Many Requests`"}}")
    [Console]::Out.WriteLine("{`"type`":`"item.completed`",`"item`":{`"type`":`"command_execution`",`"aggregated_output`":`"status: 429`"}}")
    exit 1
}
if ($scenario -ceq 'process_failure') { [Console]::Error.WriteLine('ERROR: transport disconnected'); exit 1 }
if (-not $task) { exit 1 }
if ($task -ceq '1') {
    if ($scenario -ceq 'delete') {
        [IO.File]::Delete((Join-Path $repo 'src/a.py')); $changed = @('src/a.py')
    } elseif ($scenario -ceq 'linked-target') {
        [void][IO.Directory]::CreateDirectory((Join-Path $repo 'src/settings'))
        [IO.File]::WriteAllText((Join-Path $repo 'src/settings/item.py'), "linked payload`r`n", [Text.UTF8Encoding]::new($false))
        $changed = @('src/settings/item.py')
    } elseif ($scenario -ceq 'authorized-ignored') {
        [IO.File]::WriteAllBytes((Join-Path $repo 'src/widget/bin/payload.dat'), [byte[]]@(0,255,13,10,128,65,0))
        [IO.File]::WriteAllBytes((Join-Path $repo 'src/widget/bin/generated.dat'), [byte[]]@(42))
        $changed = @('src/widget/bin/payload.dat')
    } else {
        $payload = if ($scenario -ceq 'always_verify_fail') { 'VERIFY_FAIL-one' } else { 'fake-one' }
        [IO.File]::AppendAllText((Join-Path $repo 'src\a.py'), "$payload`r`n", [Text.UTF8Encoding]::new($false))
        $changed = @('src/a.py')
    }
} else {
    [IO.Directory]::CreateDirectory((Join-Path $repo 'src')) | Out-Null
    $payload = 'fake-two'
    if ($scenario -ceq 'always_verify_fail' -or ($scenario -ceq 'isolate12' -and $task -ceq '12' -and $effort -cne 'high')) {
        $payload = "VERIFY_FAIL-$task-$effort"
    }
    [IO.File]::WriteAllText((Join-Path $repo 'src\b.py'), "$payload`r`n", [Text.UTF8Encoding]::new($false))
    $changed = @('src/b.py')
}
$status = 'done'; $unresolved = @(); $deviations = @(); $blocker = $null
if ($scenario -ceq 'concerns') { $status = 'done_with_concerns'; $unresolved = @('fixture concern') }
if ($scenario -ceq 'blocked') { $status = 'blocked'; $blocker = 'fixture spec defect' }
if ($scenario -ceq 'final_mentions_rate_limiter') { $deviations = @('documentation mentions a rate limiter') }
$report = [ordered]@{
    status = $status; changed_files = $changed
    commands_run = @(@{ command = 'fixture'; result = 'pass'; detail = $null })
    deviations = $deviations; unresolved = $unresolved; blocker = $blocker
}
[IO.File]::WriteAllText($final, ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
exit 0
'@
    $commandPath = [IO.Path]::ChangeExtension($Path, '.cmd')
    Write-TestText $commandPath ("@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Path`" %*`r`n")
    return $commandPath
}

function Invoke-TestEngine {
    param([string[]]$Arguments)
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $engine @Arguments 2>&1 | ForEach-Object { [string]$_ }); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    [pscustomobject]@{ code = [int]$code; output = ($output -join "`n") }
}

function Invoke-TestEngineSplat {
    param([hashtable]$Parameters, [string]$Name)
    $jsonPath = Join-Path $testRoot ($Name + '-engine-parameters.json')
    $launcher = Join-Path $testRoot 'engine-launcher.ps1'
    Write-TestText $jsonPath ($Parameters | ConvertTo-Json -Depth 20)
    if (-not (Test-Path -LiteralPath $launcher)) { Write-TestText $launcher @'
param([string]$Engine, [string]$ParametersPath)
$raw = Get-Content -LiteralPath $ParametersPath -Raw | ConvertFrom-Json
$splat = @{}
foreach ($property in $raw.PSObject.Properties) {
    if ($property.Name -ceq 'CodexExecutableArgumentPrefix') {
        $splat[$property.Name] = [string[]]@($property.Value | ForEach-Object { [string]$_ })
    } else { $splat[$property.Name] = $property.Value }
}
& $Engine @splat
exit $LASTEXITCODE
'@ }
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -Engine $engine -ParametersPath $jsonPath 2>&1 | ForEach-Object { [string]$_ }); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $old }
    [pscustomobject]@{ code = [int]$code; output = ($output -join "`n") }
}

function Get-TestOnlyState {
    param([string]$Root)
    $files = @(Get-ChildItem -LiteralPath $Root -Filter engine-state.json -Recurse -File -ErrorAction SilentlyContinue)
    if ($files.Count -ne 1) { return $null }
    Get-Content -LiteralPath $files[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-TestOnlyStateFile {
    param([string]$Root)
    $files = @(Get-ChildItem -LiteralPath $Root -Filter engine-state.json -Recurse -File -ErrorAction SilentlyContinue)
    if ($files.Count -ne 1) { return $null }
    return $files[0]
}

function Get-TestFileSha256 {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-NoWaveReview {
    param([AllowNull()][object]$State)
    if ($null -eq $State -or -not $State.PSObject.Properties['wave_runtime']) { return $true }
    foreach ($property in $State.wave_runtime.PSObject.Properties) {
        if ($property.Value.PSObject.Properties['review']) { return $false }
    }
    return $true
}

function Invoke-TestScenario {
    param(
        [string]$Name, [string]$Scenario = 'done', [string]$Effort = 'medium',
        [switch]$Single, [string]$FirstId = '1', [string]$SecondId = '2',
        [string]$Risk = 'medium', [switch]$TwoWave,
        [AllowNull()][string]$BaselinePath, [AllowNull()][string]$TreePinPath,
        [AllowNull()][string]$CriticalPath, [string]$BuildOutput, [switch]$IgnoredFile,
        [AllowNull()][string]$AgentsFetchFailure, [AllowNull()][string]$AgentsFetchTrace,
        [string]$AcceptanceText, [switch]$Delete
    )
    $repoPath = New-TestRepo "$Name-repo" -BuildOutput $BuildOutput
    $specPath = Join-Path $testRoot "$Name.md"
    New-TestSpec $repoPath $specPath -Single:$Single -FirstId $FirstId -SecondId $SecondId -Effort $Effort `
        -Risk $Risk -TwoWave:$TwoWave -IgnoredFile:$IgnoredFile -AcceptanceText $AcceptanceText -Delete:$Delete
    $statePath = Join-Path $testRoot "$Name-state"
    $worktrees = Join-Path $testRoot "$Name-worktrees"
    $oldScenario = $env:ENGINE_TEST_FAKE_SCENARIO
    $oldBaselinePath = $env:APEX_ENGINE_TEST_BASELINE_PATH
    $oldTreePinPath = $env:APEX_ENGINE_TEST_TREE_PIN_PATH
    $oldCriticalPath = $env:APEX_ENGINE_TEST_CRITICAL_PATH
    $oldAgentsFetchFailure = $env:APEX_ENGINE_TEST_FAIL_AGENTS_FETCH
    $oldAgentsFetchTrace = $env:APEX_ENGINE_TEST_AGENTS_FETCH_TRACE_PATH
    $oldScenarioState = $env:APEX_STATE_DIR
    try {
        $env:ENGINE_TEST_FAKE_SCENARIO = $Scenario
        $env:APEX_STATE_DIR = $statePath
        if ($AgentsFetchFailure) { $env:APEX_ENGINE_TEST_FAIL_AGENTS_FETCH = $AgentsFetchFailure } else { Remove-Item Env:APEX_ENGINE_TEST_FAIL_AGENTS_FETCH -ErrorAction SilentlyContinue }
        if ($AgentsFetchTrace) { $env:APEX_ENGINE_TEST_AGENTS_FETCH_TRACE_PATH = $AgentsFetchTrace } else { Remove-Item Env:APEX_ENGINE_TEST_AGENTS_FETCH_TRACE_PATH -ErrorAction SilentlyContinue }
        if ($BaselinePath) { $env:APEX_ENGINE_TEST_BASELINE_PATH = $BaselinePath } else { Remove-Item Env:APEX_ENGINE_TEST_BASELINE_PATH -ErrorAction SilentlyContinue }
        if ($TreePinPath) { $env:APEX_ENGINE_TEST_TREE_PIN_PATH = $TreePinPath } else { Remove-Item Env:APEX_ENGINE_TEST_TREE_PIN_PATH -ErrorAction SilentlyContinue }
        if ($CriticalPath) { $env:APEX_ENGINE_TEST_CRITICAL_PATH = $CriticalPath } else { Remove-Item Env:APEX_ENGINE_TEST_CRITICAL_PATH -ErrorAction SilentlyContinue }
        $result = Invoke-TestEngineSplat @{
            SpecPath = $specPath; Repo = $repoPath; StateRoot = $statePath; WorktreeRoot = $worktrees
            CodexExecutable = 'powershell.exe'; CodexExecutableArgumentPrefix = $script:prefix
        } $Name
        [pscustomobject]@{
            result = $result; state = (Get-TestOnlyState $statePath); repo = $repoPath
            spec = $specPath; state_root = $statePath; worktree_root = $worktrees
        }
    } finally {
        $env:ENGINE_TEST_FAKE_SCENARIO = $oldScenario
        $env:APEX_ENGINE_TEST_BASELINE_PATH = $oldBaselinePath
        $env:APEX_ENGINE_TEST_TREE_PIN_PATH = $oldTreePinPath
        $env:APEX_ENGINE_TEST_CRITICAL_PATH = $oldCriticalPath
        $env:APEX_ENGINE_TEST_FAIL_AGENTS_FETCH = $oldAgentsFetchFailure
        $env:APEX_ENGINE_TEST_AGENTS_FETCH_TRACE_PATH = $oldAgentsFetchTrace
        $env:APEX_STATE_DIR = $oldScenarioState
    }
}

function Assert-TestBuildOutputPark {
    param([string]$Name, [object]$Case, [string]$Path, [string]$Cause = 'unexpected residue')
    # Read the durable journal again rather than relying on output or an in-memory diagnosis.
    $persisted = Get-TestOnlyState $Case.state_root
    $head = (Invoke-TestGit ([string]$persisted.integration.worktree) @('rev-parse', 'HEAD'))[-1]
    $commits = (Invoke-TestGit ([string]$persisted.integration.worktree) @('rev-list', '--count', "$($persisted.base_sha)..HEAD"))[-1]
    Assert-Test $Name ($Case.result.code -eq 1 -and $persisted.status -ceq 'parked' -and
        $persisted.diagnosis -match $Cause -and $persisted.diagnosis -match [regex]::Escape($Path) -and
        $persisted.integration.tip -ceq $persisted.base_sha -and $head -ceq $persisted.base_sha -and $commits -ceq '0') `
        "exit=$($Case.result.code); diagnosis=$($persisted.diagnosis); commits=$commits; $($Case.result.output)"
}

# Mirrors codex-dispatch.ps1 New-DispatchRefusalEvent exactly; these fixtures are used only for
# refusal codes that cannot be produced hermetically without a competing machine-global run.
function New-TestDispatchRefusalEvent {
    param([int]$ExitCode, [AllowNull()][string]$RunId, [string]$Detail, [string]$TaskId = '1', [string]$Repo = 'fixture')
    [pscustomobject][ordered]@{
        kind = 'refusal'; task_id = $TaskId; repo = $Repo; exit_code = $ExitCode
        rule = $null; detail = $Detail; synthesized = $false; tail = $null; run_id = $RunId
        final = $null; truncated = $false
    }
}

# Mirrors codex-dispatch.ps1 Set-PendingDispatchResultEvent/Write-PendingEvent fields.
function New-TestDispatchResultEvent {
    param([int]$ExitCode, [string]$Status = 'failed', [AllowNull()][object]$Final = $null,
        [string]$RunId = '11111111111111111111111111111111', [AllowNull()][string]$LogPath = $null)
    [pscustomobject][ordered]@{
        kind = 'dispatch_result'; task_id = '1'; repo = 'fixture'; run_id = $RunId; log_path = $LogPath
        status = $Status; report_status = $(if ($Final) { [string]$Final.status } else { $null })
        scopeViolation = $false; scope_exit = $null; encoding_violation = $false; critical_violation = $false
        violation_detail = $null; tree_moved = $false; final = $Final; concerns_md = $null
        scope_check = $null; truncated = @(); porcelain = $null; exit_code = $ExitCode
    }
}

function New-TestRouteContext {
    param([int]$AttemptCount = 1)
    $attempts = @()
    for ($n = 1; $n -le $AttemptCount; $n++) {
        $attempts += [pscustomobject][ordered]@{
            number = $n; status = 'running'; effort = 'medium'; model = 'gpt-5.6-sol'; worktree = $testRoot
            branch = "test-$n"; child_pid = $null; child_start_time = $null; wrapper_run_id = $null
            exit_code = $null; event_path = $null; args_path = (Join-Path $testRoot "route-$n.args.json")
            child_output_path = (Join-Path $testRoot "route-$n.out"); end_tree_digest = $null; diagnosis = $null
            capacity_retries = 0; process_retries = 0
        }
    }
    $taskState = [pscustomobject][ordered]@{ id = '1'; status = 'running'; diagnosis = $null; concerns = @(); attempts = $attempts }
    $taskPlan = [pscustomobject][ordered]@{ id = '1'; files = @(); effort = 'medium'; prompt = 'fixture' }
    $script:EngineStatePath = $null
    $script:EngineLedgerPath = Join-Path $testRoot 'route-ledger.jsonl'
    $script:EngineStateRoot = $testRoot
    $script:EngineWrapper = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
    $script:EngineState = [pscustomobject][ordered]@{
        run_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; status = 'running'; diagnosis = $null; repo = $testRoot
        spec = [pscustomobject]@{ name = 'fixture' }; integration = [pscustomobject]@{ worktree = $testRoot }
        counters = [pscustomobject]@{ dispatches = 0; retries = 0; capacity_retries = 0; concerns = 0 }
        concerns = @(); transitions = @(); tasks = @($taskState)
    }
    [pscustomobject]@{ plan = $taskPlan; task = $taskState; attempt = $attempts[-1] }
}

function New-TestResult {
    param([int]$ExitCode, [object]$Event, [AllowNull()][string]$Diagnosis = $null, [string]$Digest = 'test-digest')
    [pscustomobject]@{
        exit_code = $ExitCode; child_output_path = $null; event_path = $null; event = $Event
        wrapper_run_id = $(if ($Event -and $Event.run_id) { [string]$Event.run_id } else { $null })
        end_tree_digest = $Digest; diagnosis = $Diagnosis
    }
}

function Test-JsonKind {
    param($Value, [string]$Kind)
    switch ($Kind) {
        'object' { return $Value -is [pscustomobject] }
        'array' { return $Value -is [System.Array] }
        'string' { return $Value -is [string] }
        'integer' { return $Value -is [int] -or $Value -is [long] }
        'boolean' { return $Value -is [bool] }
        'null' { return $null -eq $Value }
    }
    return $true
}

function Test-Structure {
    param($Value, $Schema, [string]$At = '$')
    if ($Schema.PSObject.Properties['type']) {
        $types = @($Schema.type)
        $typeMatched = $false
        foreach ($type in $types) { if (Test-JsonKind $Value ([string]$type)) { $typeMatched = $true } }
        if (-not $typeMatched) { throw "$At has the wrong JSON type" }
    }
    if ($Schema.PSObject.Properties['enum'] -and $null -ne $Value -and @($Schema.enum) -cnotcontains $Value) { throw "$At is outside its enum" }
    if ($null -ne $Schema.PSObject.Properties['const'] -and $Value -ne $Schema.const) { throw "$At does not match const" }
    if ($Schema.PSObject.Properties['pattern'] -and $Value -is [string] -and $Value -cnotmatch [string]$Schema.pattern) { throw "$At does not match its pattern" }
    if ($null -ne $Value -and $Schema.PSObject.Properties['minimum'] -and
            [long]$Value -lt [long]$Schema.minimum) { throw "$At is below its minimum" }
    if ($null -ne $Value -and $Schema.PSObject.Properties['maximum'] -and
            [long]$Value -gt [long]$Schema.maximum) { throw "$At is above its maximum" }
    if ($Schema.PSObject.Properties['anyOf']) {
        $anyMatched = $false
        foreach ($candidate in @($Schema.anyOf)) {
            try { Test-Structure $Value $candidate $At; $anyMatched = $true; break } catch { }
        }
        if (-not $anyMatched) { throw "$At matches no anyOf branch" }
    }
    if ($Schema.PSObject.Properties['oneOf']) {
        $matched = 0
        $branchErrors = @()
        foreach ($candidate in @($Schema.oneOf)) {
            try { Test-Structure $Value $candidate $At; $matched++ }
            catch { $branchErrors += $_.Exception.Message }
        }
        if ($matched -ne 1) { throw "$At matches $matched oneOf branches: $($branchErrors -join '; ')" }
    }
    if ($Value -is [pscustomobject]) {
        if ($Schema.PSObject.Properties['required']) { foreach ($required in @($Schema.required)) {
            if (@($Value.PSObject.Properties.Name) -cnotcontains [string]$required) { throw "$At is missing $required" }
        } }
        if ($Schema.PSObject.Properties['properties']) {
            foreach ($property in $Value.PSObject.Properties) {
                $child = $Schema.properties.PSObject.Properties[$property.Name]
                if ($null -eq $child -and $Schema.PSObject.Properties['patternProperties']) {
                    foreach ($patternProperty in $Schema.patternProperties.PSObject.Properties) {
                        if ($property.Name -cmatch [string]$patternProperty.Name) { $child = $patternProperty; break }
                    }
                }
                if ($null -ne $child) { Test-Structure $property.Value $child.Value "$At.$($property.Name)" }
                elseif ($null -ne $Schema.PSObject.Properties['additionalProperties'] -and
                        $Schema.additionalProperties -eq $false) { throw "$At has unexpected key $($property.Name)" }
            }
        }
    } elseif ($Value -is [System.Array] -and $Schema.PSObject.Properties['items']) {
        for ($i = 0; $i -lt $Value.Count; $i++) { Test-Structure $Value[$i] $Schema.items "$At[$i]" }
    }
}

function Test-TestValueContainsRoot {
    param([AllowNull()][object]$Value, [string]$Root)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) {
        $normalizedValue = ([string]$Value).Replace('\', '/')
        $normalizedRoot = $Root.Replace('\', '/')
        return ($normalizedValue.IndexOf($normalizedRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    if ($Value -is [System.Array]) {
        foreach ($item in @($Value)) { if (Test-TestValueContainsRoot $item $Root) { return $true } }
        return $false
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if (Test-TestValueContainsRoot $property.Value $Root) { return $true }
        }
    }
    return $false
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $env:LOCALAPPDATA = $machineLocalRoot
    $env:GIT_CONFIG_GLOBAL = Join-Path $testRoot 'empty.gitconfig'
    Write-TestText $env:GIT_CONFIG_GLOBAL "[user]`nname = Engine Test`nemail = engine@example.invalid`n"
    $env:APEX_ENGINE_TEST_MODE = '1'
    Remove-Item Env:APEX_ENGINE_TEST_FAIL_AGENTS_FETCH, Env:APEX_ENGINE_TEST_AGENTS_FETCH_TRACE_PATH -ErrorAction SilentlyContinue
    # apex-engine.ps1 reads this test-only timing seam while it is imported.
    $env:APEX_ENGINE_TEST_RETRY_DELAY_SECONDS = '0'
    $env:APEX_ENGINE_TEST_IMPORT_ONLY = '1'
    . $engine
    Remove-Item Env:APEX_ENGINE_TEST_IMPORT_ONLY -ErrorAction SilentlyContinue

    $stateRoot = Join-Path $testRoot 'state'
    $worktreeRoot = Join-Path $testRoot 'worktrees'
    $env:APEX_STATE_DIR = $stateRoot
    $machineLedger = Join-Path $env:LOCALAPPDATA 'apex\progress\codex-run-ledger.jsonl'
    Write-TestText $machineLedger (([ordered]@{
        run_id = 'ffffffffffffffffffffffffffffffff'; status = 'done'; worktree = 'C:\foreign\worktree'
    } | ConvertTo-Json -Compress) + "`nnot-json`n")

    $repo = New-TestRepo 'repo'
    $spec = Join-Path $testRoot 'engine-fixture.md'
    New-TestSpec $repo $spec
    $fake = Join-Path $testRoot 'fake-codex.ps1'
    [void](New-TestFakeCodex $fake)
    $prefix = [string[]]@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fake)
    $run = Invoke-TestEngineSplat @{
        SpecPath = $spec; Repo = $repo; StateRoot = $stateRoot; WorktreeRoot = $worktreeRoot
        CodexExecutable = 'powershell.exe'; CodexExecutableArgumentPrefix = $prefix
    } 'main'
    $stateFiles = @(Get-ChildItem -LiteralPath $stateRoot -Filter engine-state.json -Recurse -File -ErrorAction SilentlyContinue)
    $state = if ($stateFiles.Count -eq 1) { Get-Content $stateFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    $childDiagnostics = ''
    if ($null -ne $state) { foreach ($task in @($state.tasks)) { foreach ($attempt in @($task.attempts)) {
        if (Test-Path -LiteralPath $attempt.child_output_path) { $childDiagnostics += "`n[$($task.id)/$($attempt.number)] " + [IO.File]::ReadAllText($attempt.child_output_path) }
    } } }
    Assert-Test 'real wrapper fake Codex two-path reachability and hand-off' `
        ($run.code -eq 0 -and $null -ne $state -and $state.status -ceq 'complete' -and
            (Test-Path (Join-Path $repo 'src\b.py')) -and ([IO.File]::ReadAllText((Join-Path $repo 'src\a.py')) -match 'fake-one')) `
        "exit=$($run.code); output=$($run.output); children=$childDiagnostics"
    $linkedMain = New-TestRepo 'linked-main'
    # Expose the declared nested create so the fixture's blanket ignore does not hide its parent.
    Write-TestText (Join-Path $linkedMain '.gitignore') "*`n!residue-untracked.txt`n!src/`n!src/settings/`n!src/settings/item.py`n"
    Write-TestText (Join-Path $linkedMain 'src/settings') "main settings`n"
    [void](Set-TestCommit $linkedMain @('.gitignore', 'src/settings') (Invoke-TestGit $linkedMain @('rev-parse', 'HEAD'))[-1])
    $linkedRoot = Join-Path $testRoot 'linked-selected'
    [void](Invoke-TestGit $linkedMain @('worktree', 'add', '-b', 'linked-selected', $linkedRoot))
    [void](Invoke-TestGit $linkedRoot @('rm', '--', 'src/settings'))
    [void](Set-TestCommit $linkedRoot @('src/settings') (Invoke-TestGit $linkedRoot @('rev-parse', 'HEAD'))[-1])
    $linkedBase = (Invoke-TestGit $linkedRoot @('rev-parse', 'HEAD'))[-1]
    $linkedSpec = Join-Path $testRoot 'linked-fixture.md'
    New-TestSpec $linkedMain $linkedSpec -Single
    $linkedText = [IO.File]::ReadAllText($linkedSpec).Replace('src/a.py', 'src/settings/item.py').Replace('| modify |', '| create |').Replace('"op": "modify"', '"op": "create"')
    Write-TestText $linkedSpec $linkedText
    $linkedStateRoot = Join-Path $testRoot 'linked-state'
    # Inspect main status without allowing Git to refresh its index stat cache.
    $mainStatusBefore = ((Invoke-TestGit $linkedMain @('--no-optional-locks', 'status', '--porcelain=v1', '-uall')) -join "`n")
    $mainHeadBefore = (Invoke-TestGit $linkedMain @('rev-parse', 'HEAD'))[-1]
    $mainIndexBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $linkedMain '.git/index')))
    $mainSettingsBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $linkedMain 'src/settings')))
    $savedLinkedScenario = $env:ENGINE_TEST_FAKE_SCENARIO
    try {
        $env:ENGINE_TEST_FAKE_SCENARIO = 'linked-target'
        $linkedRun = Invoke-TestEngineSplat @{
            SpecPath = $linkedSpec; Repo = $linkedRoot; StateRoot = $linkedStateRoot
            CodexExecutable = 'powershell.exe'; CodexExecutableArgumentPrefix = $prefix
        } 'linked-target'
    } finally { $env:ENGINE_TEST_FAKE_SCENARIO = $savedLinkedScenario }
    $linkedStateFiles = @(Get-ChildItem -LiteralPath $linkedStateRoot -Filter engine-state.json -Recurse -File)
    $linkedState = if ($linkedStateFiles.Count -eq 1) { Get-Content $linkedStateFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
    Assert-Test 'linked target complete fake Codex run' `
        ($linkedRun.code -eq 0 -and $null -ne $linkedState -and $linkedState.status -ceq 'complete') `
        "exit=$($linkedRun.code); output=$($linkedRun.output)"
    if ($null -ne $linkedState) {
        Assert-Test 'linked target state repo and base SHA' `
            ($linkedState.repo -ceq [IO.Path]::GetFullPath($linkedRoot) -and $linkedState.base_sha -ceq $linkedBase) 'selected root or linked HEAD was lost'
        $linkedAncestor = Invoke-EngineGit $linkedRoot @('merge-base', '--is-ancestor', $linkedBase, $linkedState.integration.branch)
        Assert-Test 'linked integration descends from selected HEAD' $linkedAncestor.ok 'integration branch does not descend from linked base'
        $linkedDefaultRoot = Join-Path (Split-Path -Parent $linkedRoot) ((Split-Path -Leaf $linkedRoot) + '-wt')
        Assert-Test 'linked default worktree root is selected sibling' `
            ((Split-Path -Parent $linkedState.integration.worktree) -ceq $linkedDefaultRoot -and (Test-Path -LiteralPath $linkedDefaultRoot)) 'default worktree root did not follow selected target'
    }
    Assert-Test 'linked hand-off creates declared file' `
        ((Test-Path -LiteralPath (Join-Path $linkedRoot 'src/settings/item.py')) -and [IO.File]::ReadAllText((Join-Path $linkedRoot 'src/settings/item.py')) -match 'linked payload') 'hand-off file missing from selected target'
    $mainIndexAfter = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $linkedMain '.git/index')))
    $mainSettingsAfter = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $linkedMain 'src/settings')))
    $mainHeadAfter = (Invoke-TestGit $linkedMain @('rev-parse', 'HEAD'))[-1]
    $mainStatusAfter = ((Invoke-TestGit $linkedMain @('--no-optional-locks', 'status', '--porcelain=v1', '-uall')) -join "`n")
    Assert-Test 'linked run preserves main HEAD index bytes tracked bytes and status' `
        ($mainHeadBefore -ceq $mainHeadAfter -and $mainIndexBefore -ceq $mainIndexAfter -and
            $mainSettingsBefore -ceq $mainSettingsAfter -and $mainStatusBefore -ceq $mainStatusAfter) 'main worktree changed during linked run'

    # The default verify recipe runs every case; this optional switch focuses development checks.
    if (-not $AcceptanceOnly) {
    $printedEvents = 0
    if ($null -ne $state) {
        foreach ($task in @($state.tasks)) { foreach ($attempt in @($task.attempts)) {
            if ($attempt.event_path -and (Test-Path -LiteralPath $attempt.event_path) -and
                    ([IO.File]::ReadAllText($attempt.child_output_path) -match '(?m)^\[event\] ')) { $printedEvents++ }
        } }
    }
    Assert-Test 'real-spec snapshot and printed wrapper event/ledger run_id' `
        ($null -ne $state -and (Test-Path $state.spec.snapshot_path) -and $state.spec.snapshot_path -match ([regex]::Escape($state.run_id)) -and
            $printedEvents -eq 2 -and @($state.tasks | ForEach-Object { $_.attempts[0].wrapper_run_id } | Where-Object { $_ -match '^[0-9a-f]{32}$' }).Count -eq 2) `
        'snapshot, events, or wrapper run ids were missing'
    $schemaOk = $true; $schemaError = ''
    try { Test-Structure $state (Get-Content $schemaPath -Raw | ConvertFrom-Json) } catch { $schemaOk = $false; $schemaError = $_.Exception.Message }
    Assert-Test 'PowerShell 5.1 structural state schema required keys/types/enums' $schemaOk $schemaError
    $v1Compatible = $true; $v1CompatibilityError = ''
    try {
        $v1State = ($state | ConvertTo-Json -Depth 100) | ConvertFrom-Json
        if ($v1State.PSObject.Properties['wave_runtime']) { $v1State.PSObject.Properties.Remove('wave_runtime') }
        if ($v1State.PSObject.Properties['capacity']) { $v1State.PSObject.Properties.Remove('capacity') }
        Test-Structure $v1State (Get-Content $schemaPath -Raw | ConvertFrom-Json)
    } catch { $v1Compatible = $false; $v1CompatibilityError = $_.Exception.Message }
    Assert-Test 'v1 schema compatibility' $v1Compatible $v1CompatibilityError

    # Import-only parameter binding and direct attempts keep timeout tests independent of
    # full Engine runs. Reuse the allowed plan from the schema-valid reachability fixture.
    $timeoutSchema = Get-Content $schemaPath -Raw | ConvertFrom-Json
    $timeoutFixtureRepo = $repo
    $timeoutFixtureStateRoot = $stateRoot
    $timeoutFixtureWorktreeRoot = $worktreeRoot
    $env:APEX_ENGINE_TEST_IMPORT_ONLY = '1'
    foreach ($invalidTimeout in @(0, 241)) {
        $rejected = $false
        try { . $engine -NoOutputTimeoutMin $invalidTimeout } catch { $rejected = $true }
        Assert-Test "timeout CLI rejects $invalidTimeout" $rejected 'ValidateRange accepted an out-of-range timeout'
    }
    $timeoutStates = @()
    foreach ($timeoutCase in @('default', 'explicit')) {
        $importParameters = @{ SpecPath = $spec }
        if ($timeoutCase -ceq 'explicit') { $importParameters.NoOutputTimeoutMin = 75 }
        . $engine @importParameters
        $repo = $timeoutFixtureRepo; $stateRoot = $timeoutFixtureStateRoot; $worktreeRoot = $timeoutFixtureWorktreeRoot
        $expectedTimeout = if ($timeoutCase -ceq 'explicit') { 75 } else { 30 }
        Assert-Test "$timeoutCase timeout binding flag" `
            ($script:EngineNoOutputTimeoutBound -eq ($timeoutCase -ceq 'explicit')) 'explicit binding flag was incorrect'
        $runDirectory = Join-Path $testRoot ("timeout-$timeoutCase")
        $script:EngineStatePath = Join-Path $runDirectory 'engine-state.json'
        $script:EngineWorktreeRoot = $worktreeRoot
        $script:EngineWrapper = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
        $newState = New-RunnerStateObject ([Guid]::NewGuid().ToString('N')) $runDirectory `
            $repo $state.base_sha 2 $state.capacity $state.plan $state.spec.name `
            $state.spec.original_digest $state.spec.snapshot_path $state.engine_owner
        Assert-Test "$timeoutCase new state records timeout" `
            ($newState.no_output_timeout_min -eq $expectedTimeout) 'new state lost its timeout'
        $timeoutStates += $newState
    }
    Remove-Item Env:APEX_ENGINE_TEST_IMPORT_ONLY -ErrorAction SilentlyContinue
    $legacyTimeoutState = ($timeoutStates[0] | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    $legacyTimeoutState.PSObject.Properties.Remove('no_output_timeout_min')
    foreach ($schemaState in @($timeoutStates[0], $timeoutStates[1], $legacyTimeoutState)) {
        $valid = $true; $detail = ''
        try { Test-Structure $schemaState $timeoutSchema } catch { $valid = $false; $detail = $_.Exception.Message }
        Assert-Test 'new/legacy timeout state passes schema' $valid $detail
    }
    foreach ($invalidTimeout in @(241, 0, 'not-an-integer')) {
        $invalidState = ($timeoutStates[0] | ConvertTo-Json -Depth 100) | ConvertFrom-Json
        $invalidState.no_output_timeout_min = $invalidTimeout
        $rejection = ''
        try { Test-Structure $invalidState $timeoutSchema } catch { $rejection = $_.Exception.Message }
        $expectedReason = if ($invalidTimeout -eq 241) { 'above its maximum' }
            elseif ($invalidTimeout -eq 0) { 'below its minimum' } else { 'wrong JSON type' }
        Assert-Test "timeout schema rejects $invalidTimeout" `
            ($rejection -like "*no_output_timeout_min*$expectedReason*") $rejection
    }
    $pinnedState = ($state | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    $pinnedState.plan.spec.coder_model = 'gpt-6.1-sol'
    foreach ($wave in @($pinnedState.plan.waves)) { foreach ($task in @($wave.tasks)) { $task.coder_model = 'gpt-6.1-sol' } }
    $pinnedState.tasks[0].attempts[0].model = 'gpt-6.1-sol'
    $pinnedValid = $true; $pinnedError = ''
    try { Test-Structure $pinnedState $timeoutSchema } catch { $pinnedValid = $false; $pinnedError = $_.Exception.Message }
    Assert-Test 'pinned gpt-6.1-sol passes all three state model enums' $pinnedValid $pinnedError

    $timeoutCriticalGate = ${function:Test-RunnerCriticalGate}
    $timeoutStartDispatch = ${function:Start-EngineDispatch}
    function Test-RunnerCriticalGate { param($TaskPlan, $TaskState) return $true }
    function Start-EngineDispatch {
        param($WrapperPath, $ArgsPath, $ChildOutputPath, $StateRoot)
        return [pscustomobject]@{ pid = $PID; start_time = '2001-02-03T04:05:06.0000000Z' }
    }
    try {
        foreach ($case in @('default', 'explicit', 'legacy', 'resume-bound', 'resume-unbound', 'resume-legacy-bound', 'resume-legacy-unbound')) {
            $sourceState = if ($case -ceq 'explicit') { $timeoutStates[1] }
                elseif ($case -like '*legacy*') { $legacyTimeoutState } else { $timeoutStates[0] }
            $script:EngineState = ($sourceState | ConvertTo-Json -Depth 100) | ConvertFrom-Json
            $expectedTimeout = if ($case -ceq 'explicit') { 75 } else { 30 }
            $script:EngineStateRoot = Join-Path $testRoot "timeout-$case-state"
            $script:EngineStatePath = Join-Path (Join-Path $script:EngineStateRoot $script:EngineState.run_id) 'engine-state.json'
            if ($case -like 'resume-*') {
                $script:EngineNoOutputTimeoutBound = $case -like '*-bound'
                $NoOutputTimeoutMin = 90
                if ($case -notlike '*legacy*') { $script:EngineState.no_output_timeout_min = 45 }
                Save-RunnerState
                $ready = Initialize-RunnerResume $script:EngineState.run_id
                $expectedTimeout = if ($script:EngineNoOutputTimeoutBound) { 90 }
                    elseif ($case -like '*legacy*') { 30 } else { 45 }
                $savedResume = Get-Content $script:EngineStatePath -Raw | ConvertFrom-Json
                $savedProperty = $savedResume.PSObject.Properties['no_output_timeout_min']
                Assert-Test "$case saves timeout choice" `
                    ($ready -and (($null -ne $savedProperty -and $savedProperty.Value -eq $expectedTimeout) -or
                        ($case -ceq 'resume-legacy-unbound' -and $null -eq $savedProperty))) 'resume lost persisted timeout choice'
            }
            $taskPlan = $script:EngineState.plan.waves[0].tasks[0]
            $taskState = $script:EngineState.tasks[0]
            $attempt = ($state.tasks[0].attempts[0] | ConvertTo-Json -Depth 100) | ConvertFrom-Json
            $attempt.worktree = $repo
            $attempt.args_path = Join-Path (Split-Path -Parent $script:EngineStatePath) 'dispatch-args.json'
            $attempt.child_output_path = Join-Path (Split-Path -Parent $script:EngineStatePath) 'child.out'
            $taskState.attempts = @($attempt)
            $child = Start-RunnerAttempt $taskPlan $taskState $attempt
            $dispatchArgs = Get-Content $attempt.args_path -Raw | ConvertFrom-Json
            Assert-Test "$case dispatches state timeout or legacy fallback" `
                ($null -ne $child -and $dispatchArgs.NoOutputTimeoutMin -eq $expectedTimeout) 'dispatch arguments have the wrong timeout'
            Close-RunnerRunLock
        }
    } finally {
        Close-RunnerRunLock
        Set-Item -LiteralPath Function:Test-RunnerCriticalGate -Value $timeoutCriticalGate
        Set-Item -LiteralPath Function:Start-EngineDispatch -Value $timeoutStartDispatch
        $env:APEX_ENGINE_TEST_IMPORT_ONLY = '1'
        . $engine
        $repo = $timeoutFixtureRepo; $stateRoot = $timeoutFixtureStateRoot; $worktreeRoot = $timeoutFixtureWorktreeRoot
        Remove-Item Env:APEX_ENGINE_TEST_IMPORT_ONLY -ErrorAction SilentlyContinue
    }

    # High-risk review pauses use the production tree-pin unless a case explicitly selects one of
    # the two digest-failure stubs below.
    Remove-Item Env:APEX_ENGINE_TEST_TREE_PIN_PATH -ErrorAction SilentlyContinue
    $realTreePin = Join-Path $PSScriptRoot 'tree-pin.ps1'
    $reviewRecordOne = Join-Path $testRoot 'review-one.txt'
    $reviewRecordTwo = Join-Path $testRoot 'review-two.txt'
    Write-TestText $reviewRecordOne "owner review one`n"
    Write-TestText $reviewRecordTwo "owner review two`n"

    $highTwoWave = Invoke-TestScenario -Name 'high-two-wave' -Risk high -TwoWave
    $highTwoWaveFile = Get-TestOnlyStateFile $highTwoWave.state_root
    $highPause = Get-TestOnlyState $highTwoWave.state_root
    $highReviewOne = $highPause.wave_runtime.'1'.review
    $highSchemaOk = $true; $highSchemaError = ''
    try { Test-Structure $highPause (Get-Content $schemaPath -Raw | ConvertFrom-Json) }
    catch { $highSchemaOk = $false; $highSchemaError = $_.Exception.Message }
    $reviewPin = Invoke-RunnerScript $realTreePin ([string[]]@('-Digest', '-Worktree', [string]$highPause.integration.worktree))
    $integrationCommitCount = [int](Invoke-TestGit $highPause.integration.worktree @('rev-list', '--count', "$($highPause.base_sha)..$($highPause.integration.tip)"))[-1]
    $mainAAtPause = [IO.File]::ReadAllText((Join-Path $highTwoWave.repo 'src\a.py'))
    $pauseLines = @($highTwoWave.result.output -split "`r?`n")
    $pauseTail = (($pauseLines | Select-Object -Last 15) -join "`n")
    $plainTransitionsBefore = @($highPause.transitions).Count
    $plainDispatchBefore = [int]$highPause.counters.dispatches
    $plainHighResume = Invoke-TestEngine @('-Resume', $highPause.run_id, '-StateRoot', $highTwoWave.state_root)
    $highPlain = Get-TestOnlyState $highTwoWave.state_root
    $plainNewTransitions = @($highPlain.transitions | Select-Object -Skip $plainTransitionsBefore)
    Assert-Test 'risk high pause after wave' `
        ($highTwoWave.result.code -eq 2 -and $highPause.status -ceq 'awaiting-review' -and
            $highReviewOne.tree_digest -cmatch '^[0-9a-f]{64}$' -and $reviewPin.exit_code -eq 0 -and
            [string]$reviewPin.output.Trim() -ceq [string]$highReviewOne.tree_digest -and
            $integrationCommitCount -eq 1 -and @($highPause.tasks[1].attempts).Count -eq 0 -and
            $mainAAtPause -notmatch 'fake-one' -and -not (Test-Path (Join-Path $highTwoWave.repo 'src\b.py')) -and
            $highSchemaOk -and $plainHighResume.code -eq 2 -and $highPlain.status -ceq 'awaiting-review' -and
            $highPlain.counters.dispatches -eq $plainDispatchBefore -and @($plainNewTransitions).Count -eq 1 -and
            [string]$plainNewTransitions[0].kind -ceq 'resumed' -and
            $pauseTail -match "Awaiting review: wave 1" -and
            $pauseTail -match [regex]::Escape("Review diff: $($highReviewOne.base)..$($highReviewOne.head)") -and
            $pauseTail -match [regex]::Escape("Review digest: $($highReviewOne.tree_digest)") -and
            $pauseTail -match 'Next: Opus Critic on that diff' -and
            $pauseTail -notmatch 'Next: Critic review, docs/owner commit') `
        "initial=$($highTwoWave.result.output); resume=$($plainHighResume.output); schema=$highSchemaError"

    $cleanWaveOne = Invoke-TestEngine @('-Resume', $highPlain.run_id, '-StateRoot', $highTwoWave.state_root,
        '-ReviewVerdict', 'clean', '-ReviewDigest', $highReviewOne.tree_digest, '-ReviewRecord', $reviewRecordOne)
    $waveTwoPause = Get-TestOnlyState $highTwoWave.state_root
    $waveTwoReview = $waveTwoPause.wave_runtime.'2'.review
    $waveTwoMainBeforeClean = Test-Path (Join-Path $highTwoWave.repo 'src\b.py')
    $waveTwoDispatches = [int]$waveTwoPause.counters.dispatches
    $waveTwoTransitions = @($waveTwoPause.transitions).Count
    $wrongWaveDigest = Invoke-TestEngine @('-Resume', $waveTwoPause.run_id, '-StateRoot', $highTwoWave.state_root,
        '-ReviewVerdict', 'clean', '-ReviewDigest', $highReviewOne.tree_digest, '-ReviewRecord', $reviewRecordTwo)
    $waveTwoRefused = Get-TestOnlyState $highTwoWave.state_root
    $waveTwoRefusalKinds = @($waveTwoRefused.transitions | Select-Object -Skip $waveTwoTransitions | ForEach-Object { [string]$_.kind })
    Write-TestText $reviewRecordTwo "owner review two revised`n"
    $cleanWaveTwo = Invoke-TestEngine @('-Resume', $waveTwoRefused.run_id, '-StateRoot', $highTwoWave.state_root,
        '-ReviewVerdict', 'clean', '-ReviewDigest', $waveTwoReview.tree_digest, '-ReviewRecord', $reviewRecordTwo)
    $twoWaveDone = Get-TestOnlyState $highTwoWave.state_root
    Assert-Test 'review clean continues to next wave' `
        ($cleanWaveOne.code -eq 2 -and $waveTwoPause.status -ceq 'awaiting-review' -and
            [string]$waveTwoPause.wave_runtime.'1'.review.status -ceq 'clean' -and
            [string]$waveTwoReview.status -ceq 'awaiting' -and @($waveTwoPause.tasks[1].attempts).Count -eq 1 -and
            -not $waveTwoMainBeforeClean -and
            $wrongWaveDigest.code -eq 1 -and $waveTwoRefused.status -ceq 'awaiting-review' -and
            ($waveTwoRefusalKinds -join ',') -ceq 'resumed,review-verdict-refused' -and
            $waveTwoRefused.counters.dispatches -eq $waveTwoDispatches -and
            $cleanWaveTwo.code -eq 0 -and $twoWaveDone.status -ceq 'complete' -and
            (Test-Path (Join-Path $highTwoWave.repo 'src\b.py'))) `
        "wave1=$($cleanWaveOne.output); wrong=$($wrongWaveDigest.output); wave2=$($cleanWaveTwo.output)"

    $originalReviewGate = ${function:Invoke-RunnerReviewGate}
    $originalRunnerWave = ${function:Invoke-RunnerWave}
    $originalRunnerHandoff = ${function:Invoke-RunnerHandoff}
    $savedEngineState = $script:EngineState; $savedEngineStatePath = $script:EngineStatePath
    $script:UnexpectedWaveCalls = 0; $script:UnexpectedHandoffCalls = 0
    function Invoke-RunnerReviewGate { param($Wave) 'clean'; 'leaked-output' }
    function Invoke-RunnerWave { param($Wave) $script:UnexpectedWaveCalls++; return $true }
    function Invoke-RunnerHandoff { $script:UnexpectedHandoffCalls++; return $true }
    try {
        $unexpectedGateState = ($twoWaveDone | ConvertTo-Json -Depth 100) | ConvertFrom-Json
        $unexpectedGateState.status = 'running'; $unexpectedGateState.handoff.status = 'pending'
        $unexpectedGateState.tasks[1].status = 'pending'
        $unexpectedGateAttempts = @($unexpectedGateState.tasks[1].attempts).Count
        $script:EngineState = $unexpectedGateState; $script:EngineStatePath = $null
        $unexpectedGateExit = Invoke-RunnerMainLoop
    } finally {
        Set-Item -LiteralPath Function:Invoke-RunnerReviewGate -Value $originalReviewGate
        Set-Item -LiteralPath Function:Invoke-RunnerWave -Value $originalRunnerWave
        Set-Item -LiteralPath Function:Invoke-RunnerHandoff -Value $originalRunnerHandoff
        $script:EngineState = $savedEngineState; $script:EngineStatePath = $savedEngineStatePath
    }
    Assert-Test 'unexpected review gate result parks before next wave' `
        ($unexpectedGateExit -eq 1 -and $unexpectedGateState.status -ceq 'parked' -and
            [string]$unexpectedGateState.diagnosis -ceq 'review gate returned unexpected result for wave 1' -and
            $script:UnexpectedWaveCalls -eq 0 -and $script:UnexpectedHandoffCalls -eq 0 -and
            @($unexpectedGateState.tasks[1].attempts).Count -eq $unexpectedGateAttempts) `
        "exit=$unexpectedGateExit; diagnosis=$($unexpectedGateState.diagnosis); waveCalls=$($script:UnexpectedWaveCalls); handoffCalls=$($script:UnexpectedHandoffCalls)"

    $binding = Invoke-TestScenario -Name 'review-binding' -Risk high -Single
    $bindingFile = Get-TestOnlyStateFile $binding.state_root
    $bindingPause = Get-TestOnlyState $binding.state_root
    $bindingDigest = [string]$bindingPause.wave_runtime.'1'.review.tree_digest
    $bindingEntryDiagnosis = $bindingPause.diagnosis
    $bindingTransitions = @($bindingPause.transitions).Count
    $bindingDispatches = [int]$bindingPause.counters.dispatches
    $wrongDigest = '0' * 64
    if ($wrongDigest -ceq $bindingDigest) { $wrongDigest = '1' * 64 }
    $wrongBinding = Invoke-TestEngine @('-Resume', $bindingPause.run_id, '-StateRoot', $binding.state_root,
        '-ReviewVerdict', 'clean', '-ReviewDigest', $wrongDigest, '-ReviewRecord', $reviewRecordOne)
    $afterWrongBinding = Get-TestOnlyState $binding.state_root
    $bindingKinds = @($afterWrongBinding.transitions | Select-Object -Skip $bindingTransitions | ForEach-Object { [string]$_.kind })
    $movedPath = Join-Path $afterWrongBinding.integration.worktree 'review-untracked.txt'
    Write-TestText $movedPath "moves the tree`n"
    $movedBinding = Invoke-TestEngine @('-Resume', $afterWrongBinding.run_id, '-StateRoot', $binding.state_root,
        '-ReviewVerdict', 'clean', '-ReviewDigest', $bindingDigest, '-ReviewRecord', $reviewRecordOne)
    $afterMovedBinding = Get-TestOnlyState $binding.state_root
    Remove-Item -LiteralPath $movedPath -Force
    $restoredBinding = Invoke-TestEngine @('-Resume', $afterMovedBinding.run_id, '-StateRoot', $binding.state_root)
    $afterRestoredBinding = Get-TestOnlyState $binding.state_root

    $digestFailureStub = Join-Path $testRoot 'review-digest-failure.ps1'
    Write-TestText $digestFailureStub @"
param([switch]`$Pin, [switch]`$Verify, [switch]`$Digest, [string]`$Worktree, [string]`$Label, [string]`$PinDirectory)
if (`$Digest -and (Split-Path -Leaf `$Worktree) -like '*-integration') { Write-Host 'digest fixture failed'; exit 23 }
`$forward = @('-Worktree', `$Worktree)
if (`$Pin) { `$forward = @('-Pin') + `$forward }
if (`$Verify) { `$forward = @('-Verify') + `$forward }
if (`$Digest) { `$forward = @('-Digest') + `$forward }
if (`$Label) { `$forward += @('-Label', `$Label) }
if (`$PinDirectory) { `$forward += @('-PinDirectory', `$PinDirectory) }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$realTreePin' @forward
exit `$LASTEXITCODE
"@
    $digestMalformedStub = Join-Path $testRoot 'review-digest-malformed.ps1'
    Write-TestText $digestMalformedStub @"
param([switch]`$Pin, [switch]`$Verify, [switch]`$Digest, [string]`$Worktree, [string]`$Label, [string]`$PinDirectory)
if (`$Digest -and (Split-Path -Leaf `$Worktree) -like '*-integration') { Write-Host 'not-a-digest'; exit 0 }
`$forward = @('-Worktree', `$Worktree)
if (`$Pin) { `$forward = @('-Pin') + `$forward }
if (`$Verify) { `$forward = @('-Verify') + `$forward }
if (`$Digest) { `$forward = @('-Digest') + `$forward }
if (`$Label) { `$forward += @('-Label', `$Label) }
if (`$PinDirectory) { `$forward += @('-PinDirectory', `$PinDirectory) }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$realTreePin' @forward
exit `$LASTEXITCODE
"@
    $digestFailure = Invoke-TestScenario -Name 'review-digest-failure' -Risk high -Single -TreePinPath $digestFailureStub
    $digestMalformed = Invoke-TestScenario -Name 'review-digest-malformed' -Risk high -Single -TreePinPath $digestMalformedStub
    $directHeadState = ($afterRestoredBinding | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    $directHeadState.wave_runtime.'1'.PSObject.Properties.Remove('review')
    $directHeadState.status = 'running'; $directHeadState.integration.tip = [string]$directHeadState.base_sha
    $script:EngineState = $directHeadState; $script:EngineStatePath = $null
    $script:EngineTreePinScript = $realTreePin
    $env:APEX_ENGINE_TEST_IMPORT_ONLY = '1'
    try { $directHeadResult = Invoke-RunnerReviewGate -Wave $directHeadState.plan.waves[0] }
    finally { Remove-Item Env:APEX_ENGINE_TEST_IMPORT_ONLY -ErrorAction SilentlyContinue }
    Assert-Test 'review digest binding' `
        ($wrongBinding.code -eq 1 -and $afterWrongBinding.status -ceq 'awaiting-review' -and
            $afterWrongBinding.diagnosis -eq $bindingEntryDiagnosis -and
            ($bindingKinds -join ',') -ceq 'resumed,review-verdict-refused' -and
            $afterWrongBinding.counters.dispatches -eq $bindingDispatches -and
            $movedBinding.code -eq 1 -and $afterMovedBinding.status -ceq 'parked' -and
            $afterMovedBinding.diagnosis -match 'integration tree moved while wave 1 awaited review' -and
            [string]$afterMovedBinding.wave_runtime.'1'.review.tree_digest -ceq $bindingDigest -and
            $restoredBinding.code -eq 2 -and $afterRestoredBinding.status -ceq 'awaiting-review' -and
            [string]$afterRestoredBinding.wave_runtime.'1'.review.tree_digest -ceq $bindingDigest -and
            $digestFailure.result.code -eq 1 -and $digestFailure.state.diagnosis -match 'review digest unavailable for wave 1: tree-pin exit 23' -and
            -not $digestFailure.state.wave_runtime.'1'.PSObject.Properties['review'] -and
            $digestMalformed.result.code -eq 1 -and $digestMalformed.state.diagnosis -match 'review digest unavailable for wave 1: tree-pin returned a malformed digest' -and
            -not $digestMalformed.state.wave_runtime.'1'.PSObject.Properties['review'] -and
            $directHeadResult -ceq 'parked' -and $directHeadState.diagnosis -match 'review digest unavailable for wave 1: integration HEAD differs' -and
            -not $directHeadState.wave_runtime.'1'.PSObject.Properties['review']) `
        "wrong=$($wrongBinding.output); moved=$($movedBinding.output); restored=$($restoredBinding.output); failure=$($digestFailure.result.output); malformed=$($digestMalformed.result.output); direct=$($directHeadState.diagnosis)"

    Remove-Item Env:APEX_ENGINE_TEST_TREE_PIN_PATH -ErrorAction SilentlyContinue
    $movedTip = Invoke-TestScenario -Name 'review-moved-tip' -Risk high -Single
    $movedTipFile = Get-TestOnlyStateFile $movedTip.state_root
    $movedTipBefore = Get-TestOnlyState $movedTip.state_root
    $movedTipReviewJson = $movedTipBefore.wave_runtime.'1'.review | ConvertTo-Json -Depth 20 -Compress
    $movedTipMainHash = Get-TestFileSha256 (Join-Path $movedTip.repo 'src\a.py')
    $extraPath = Join-Path $movedTipBefore.integration.worktree 'extra.txt'
    Write-TestText $extraPath "extra integration commit`n"
    $movedParent = (Invoke-TestGit $movedTipBefore.integration.worktree @('rev-parse', 'HEAD'))[-1]
    [void](Set-TestCommit $movedTipBefore.integration.worktree @('extra.txt') $movedParent)
    $movedTipResume = Invoke-TestEngine @('-Resume', $movedTipBefore.run_id, '-StateRoot', $movedTip.state_root,
        '-ReviewVerdict', 'clean', '-ReviewDigest', $movedTipBefore.wave_runtime.'1'.review.tree_digest,
        '-ReviewRecord', $reviewRecordOne)
    $movedTipAfter = Get-TestOnlyState $movedTip.state_root
    Assert-Test 'review resume refuses moved tip' `
        ($movedTipResume.code -eq 1 -and $movedTipAfter.status -ceq 'parked' -and
            $movedTipAfter.diagnosis -match 'integration branch tip mismatch' -and
            (($movedTipAfter.wave_runtime.'1'.review | ConvertTo-Json -Depth 20 -Compress) -ceq $movedTipReviewJson) -and
            $movedTipAfter.handoff.status -notin @('running', 'complete') -and
            (Get-TestFileSha256 (Join-Path $movedTip.repo 'src\a.py')) -ceq $movedTipMainHash) `
        $movedTipResume.output

    $rejectCase = Invoke-TestScenario -Name 'review-reject' -Risk high -Single
    $rejectPause = Get-TestOnlyState $rejectCase.state_root
    $rejectDigest = [string]$rejectPause.wave_runtime.'1'.review.tree_digest
    Write-TestText $reviewRecordOne "reject owner record`n"
    $rejectRun = Invoke-TestEngine @('-Resume', $rejectPause.run_id, '-StateRoot', $rejectCase.state_root,
        '-ReviewVerdict', 'reject', '-ReviewDigest', $rejectDigest, '-ReviewRecord', $reviewRecordOne)
    $afterReject = Get-TestOnlyState $rejectCase.state_root
    $rejectDispatches = [int]$afterReject.counters.dispatches
    $plainRejectRun = Invoke-TestEngine @('-Resume', $afterReject.run_id, '-StateRoot', $rejectCase.state_root)
    $plainRejected = Get-TestOnlyState $rejectCase.state_root
    $reusedEntryDiagnosis = [string]$plainRejected.diagnosis
    $reusedTransitionCount = @($plainRejected.transitions).Count
    $reusedRecordRun = Invoke-TestEngine @('-Resume', $plainRejected.run_id, '-StateRoot', $rejectCase.state_root,
        '-ReviewVerdict', 'clean', '-ReviewDigest', $rejectDigest, '-ReviewRecord', $reviewRecordOne)
    $afterReused = Get-TestOnlyState $rejectCase.state_root
    $reusedKinds = @($afterReused.transitions | Select-Object -Skip $reusedTransitionCount | ForEach-Object { [string]$_.kind })
    Write-TestText $reviewRecordTwo "clean owner decision for open findings`n"
    $cleanRejected = Invoke-TestEngine @('-Resume', $afterReused.run_id, '-StateRoot', $rejectCase.state_root,
        '-ReviewVerdict', 'clean', '-ReviewDigest', $rejectDigest, '-ReviewRecord', $reviewRecordTwo)
    $afterCleanRejected = Get-TestOnlyState $rejectCase.state_root
    Assert-Test 'review reject parks' `
        ($rejectRun.code -eq 1 -and $afterReject.status -ceq 'parked' -and
            $rejectRun.output -match [regex]::Escape("Next: inspect the diagnosis, then -Resume $($rejectPause.run_id) or -Teardown $($rejectPause.run_id) -Discard.") -and
            [string]$afterReject.wave_runtime.'1'.review.status -ceq 'rejected' -and
            @($afterReject.wave_runtime.'1'.review.verdicts).Count -eq 1 -and
            $plainRejectRun.code -eq 1 -and $plainRejected.status -ceq 'parked' -and
            $plainRejected.diagnosis -match 'resume requires -ReviewVerdict clean bound to' -and
            $plainRejected.counters.dispatches -eq $rejectDispatches -and
            $reusedRecordRun.code -eq 1 -and $afterReused.status -ceq 'parked' -and
            [string]$afterReused.diagnosis -ceq $reusedEntryDiagnosis -and
            ($reusedKinds -join ',') -ceq 'resumed,review-verdict-refused' -and
            @($afterReused.wave_runtime.'1'.review.verdicts).Count -eq 1 -and
            $cleanRejected.code -eq 0 -and $afterCleanRejected.status -ceq 'complete' -and
            [string]$afterCleanRejected.wave_runtime.'1'.review.status -ceq 'clean' -and
            @($afterCleanRejected.wave_runtime.'1'.review.verdicts).Count -eq 2) `
        "reject=$($rejectRun.output); plain=$($plainRejectRun.output); reused=$($reusedRecordRun.output); clean=$($cleanRejected.output)"

    $crashRepo = New-TestRepo 'review-crash-repo'
    $crashSpec = Join-Path $testRoot 'review-crash.md'
    New-TestSpec $crashRepo $crashSpec -Single -Risk high
    $crashStateRoot = Join-Path $testRoot 'review-crash-state'
    $crashWorktrees = Join-Path $testRoot 'review-crash-worktrees'
    $env:APEX_ENGINE_TEST_CRASH_AFTER_WAVE_COMMIT = '1'
    try {
        $crashRun = Invoke-TestEngineSplat @{
            SpecPath = $crashSpec; Repo = $crashRepo; StateRoot = $crashStateRoot; WorktreeRoot = $crashWorktrees
            CodexExecutable = 'powershell.exe'; CodexExecutableArgumentPrefix = $prefix
        } 'review-crash'
    } finally { Remove-Item Env:APEX_ENGINE_TEST_CRASH_AFTER_WAVE_COMMIT -ErrorAction SilentlyContinue }
    $crashFile = Get-TestOnlyStateFile $crashStateRoot
    $crashBefore = Get-TestOnlyState $crashStateRoot
    $crashHashBefore = Get-TestFileSha256 $crashFile.FullName
    $crashFlagRefusal = Invoke-TestEngine @('-Resume', $crashBefore.run_id, '-StateRoot', $crashStateRoot,
        '-ReviewVerdict', 'clean', '-ReviewDigest', ('a' * 64), '-ReviewRecord', $reviewRecordOne)
    $crashHashAfter = Get-TestFileSha256 $crashFile.FullName
    $crashResume = Invoke-TestEngine @('-Resume', $crashBefore.run_id, '-StateRoot', $crashStateRoot)
    $crashAfter = Get-TestOnlyState $crashStateRoot
    Assert-Test 'review survives crash-window adoption' `
        ($crashRun.code -eq 1 -and $crashFlagRefusal.code -eq 1 -and $crashHashBefore -ceq $crashHashAfter -and
            $crashResume.code -eq 2 -and $crashAfter.status -ceq 'awaiting-review' -and
            @($crashAfter.transitions | Where-Object { [string]$_.kind -ceq 'wave-commit-adopted' }).Count -eq 1 -and
            $crashAfter.handoff.status -ceq 'pending') `
        "crash=$($crashRun.output); flags=$($crashFlagRefusal.output); resume=$($crashResume.output)"

    $lowCase = Invoke-TestScenario -Name 'review-low' -Risk low -Single
    $lowFile = Get-TestOnlyStateFile $lowCase.state_root
    $lowState = Get-TestOnlyState $lowCase.state_root
    $mediumFlagRoot = Join-Path $testRoot 'review-medium-flags-state'
    $mediumFlagDirectory = Join-Path $mediumFlagRoot $state.run_id
    [void][IO.Directory]::CreateDirectory($mediumFlagDirectory)
    $mediumFlagFile = Join-Path $mediumFlagDirectory 'engine-state.json'
    $mediumFlagState = ($state | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    $mediumFlagState.status = 'paused'; $mediumFlagState.diagnosis = 'medium review flag fixture'
    $mediumFlagState.state_path = $mediumFlagFile
    Write-TestText $mediumFlagFile ($mediumFlagState | ConvertTo-Json -Depth 100)
    $mediumHashBefore = Get-TestFileSha256 $mediumFlagFile
    $lowFlags = Invoke-TestEngine @('-Resume', $mediumFlagState.run_id, '-StateRoot', $mediumFlagRoot,
        '-ReviewVerdict', 'clean', '-ReviewDigest', ('b' * 64), '-ReviewRecord', $reviewRecordOne)
    $mediumHashAfter = Get-TestFileSha256 $mediumFlagFile
    Assert-Test 'low-medium no pause' `
        ($lowCase.result.code -eq 0 -and $lowState.status -ceq 'complete' -and (Test-NoWaveReview $lowState) -and
            $state.status -ceq 'complete' -and (Test-NoWaveReview $state) -and
            $lowFlags.code -eq 1 -and $lowFlags.output -match 'high-risk run' -and $mediumHashBefore -ceq $mediumHashAfter) `
        $lowFlags.output
    $completeHashBefore = Get-TestFileSha256 $lowFile.FullName
    $completeResume = Invoke-TestEngine @('-Resume', $lowState.run_id, '-StateRoot', $lowCase.state_root)
    $completeHashAfter = Get-TestFileSha256 $lowFile.FullName
    Assert-Test 'non-mutating resume refusal' `
        ($completeResume.code -eq 1 -and $completeResume.output -match 'Run status cannot be resumed: complete' -and
            $completeHashBefore -ceq $completeHashAfter -and (Get-TestOnlyState $lowCase.state_root).status -ceq 'complete') `
        $completeResume.output

    $validationState = Get-TestOnlyState $binding.state_root
    $validationFile = Get-TestOnlyStateFile $binding.state_root
    $insideRecord = Join-Path $validationState.integration.worktree 'inside-review.txt'
    Write-TestText $insideRecord "inside`n"
    $invalidUtf8Record = Join-Path $testRoot 'invalid-review.bin'
    [IO.File]::WriteAllBytes($invalidUtf8Record, [byte[]]@(0xC3, 0x28))
    $utf16LeRecord = Join-Path $testRoot 'utf16le-review.txt'
    [IO.File]::WriteAllBytes($utf16LeRecord, [byte[]]@(0xFF, 0xFE, 0x72, 0x00, 0x65, 0x00, 0x76, 0x00, 0x69, 0x00, 0x65, 0x00, 0x77, 0x00))
    $missingRecord = Join-Path $testRoot 'missing-review.txt'
    $validationArguments = @(
        [string[]]@('-Resume', $validationState.run_id, '-StateRoot', $binding.state_root, '-ReviewVerdict', 'clean'),
        [string[]]@('-Resume', $validationState.run_id, '-StateRoot', $binding.state_root, '-ReviewVerdict', 'clean', '-ReviewDigest', 'bad', '-ReviewRecord', $reviewRecordOne),
        [string[]]@('-Resume', $validationState.run_id, '-StateRoot', $binding.state_root, '-ReviewVerdict', 'clean', '-ReviewDigest', $bindingDigest, '-ReviewRecord', 'relative.txt'),
        [string[]]@('-Resume', $validationState.run_id, '-StateRoot', $binding.state_root, '-ReviewVerdict', 'clean', '-ReviewDigest', $bindingDigest, '-ReviewRecord', 'C:review.txt'),
        [string[]]@('-Resume', $validationState.run_id, '-StateRoot', $binding.state_root, '-ReviewVerdict', 'clean', '-ReviewDigest', $bindingDigest, '-ReviewRecord', '\review.txt'),
        [string[]]@('-Resume', $validationState.run_id, '-StateRoot', $binding.state_root, '-ReviewVerdict', 'clean', '-ReviewDigest', $bindingDigest, '-ReviewRecord', $missingRecord),
        [string[]]@('-Resume', $validationState.run_id, '-StateRoot', $binding.state_root, '-ReviewVerdict', 'clean', '-ReviewDigest', $bindingDigest, '-ReviewRecord', $insideRecord),
        [string[]]@('-Resume', $validationState.run_id, '-StateRoot', $binding.state_root, '-ReviewVerdict', 'CLEAN', '-ReviewDigest', $bindingDigest, '-ReviewRecord', $reviewRecordOne),
        [string[]]@('-Resume', $validationState.run_id, '-StateRoot', $binding.state_root, '-ReviewVerdict', 'clean', '-ReviewDigest', $bindingDigest, '-ReviewRecord', $invalidUtf8Record),
        [string[]]@('-Resume', $validationState.run_id, '-StateRoot', $binding.state_root, '-ReviewVerdict', 'clean', '-ReviewDigest', $bindingDigest, '-ReviewRecord', $utf16LeRecord)
    )
    $validationOk = $true; $validationDetail = @(); $validationResults = @()
    foreach ($validationArgs in $validationArguments) {
        $beforeValidationHash = Get-TestFileSha256 $validationFile.FullName
        $validationResult = Invoke-TestEngine $validationArgs
        $afterValidationHash = Get-TestFileSha256 $validationFile.FullName
        if ($validationResult.code -ne 1 -or $validationResult.output -notmatch 'Engine refused' -or
                $beforeValidationHash -cne $afterValidationHash) { $validationOk = $false }
        $validationResults += $validationResult
        $validationDetail += "$($validationResult.code):$($validationResult.output)"
    }
    $newFlagStateRoot = Join-Path $testRoot 'new-review-flags-state'
    $newFlagsRun = Invoke-TestEngine @('-SpecPath', $binding.spec, '-Repo', $binding.repo, '-StateRoot', $newFlagStateRoot,
        '-WorktreeRoot', (Join-Path $testRoot 'new-review-flags-worktrees'), '-ReviewVerdict', 'clean',
        '-ReviewDigest', $bindingDigest, '-ReviewRecord', $reviewRecordOne)
    $teardownFlagHashBefore = Get-TestFileSha256 $validationFile.FullName
    $teardownFlagsRun = Invoke-TestEngine @('-Teardown', $validationState.run_id, '-StateRoot', $binding.state_root,
        '-ReviewVerdict', 'clean', '-ReviewDigest', $bindingDigest, '-ReviewRecord', $reviewRecordOne)
    $teardownFlagHashAfter = Get-TestFileSha256 $validationFile.FullName
    Assert-Test 'review flag validation' `
        ($validationOk -and $newFlagsRun.code -eq 1 -and $newFlagsRun.output -match 'Engine refused' -and
            $validationResults[3].output -match [regex]::Escape('-ReviewRecord must be an absolute normalized path.') -and
            $validationResults[4].output -match [regex]::Escape('-ReviewRecord must be an absolute normalized path.') -and
            @(Get-ChildItem -LiteralPath $newFlagStateRoot -Filter engine-state.json -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0 -and
            $teardownFlagsRun.code -eq 1 -and $teardownFlagsRun.output -match 'Engine refused' -and
            $teardownFlagHashBefore -ceq $teardownFlagHashAfter -and
            ($validationDetail -join "`n") -match "-ReviewVerdict must be exactly 'clean' or 'reject'") `
        (($validationDetail + @($newFlagsRun.output, $teardownFlagsRun.output)) -join "`n")

    $reviewSchemaDocument = Get-Content $schemaPath -Raw | ConvertFrom-Json
    $reviewSchemaOk = $true; $reviewSchemaFailures = @()
    try { Test-Structure $validationState $reviewSchemaDocument }
    catch { $reviewSchemaOk = $false; $reviewSchemaFailures += $_.Exception.Message }
    foreach ($completedReviewState in @(
        [pscustomobject]@{ name = 'two-wave clean verdict state'; state = $twoWaveDone },
        [pscustomobject]@{ name = 'rejected-then-clean verdict state'; state = $afterCleanRejected }
    )) {
        try { Test-Structure $completedReviewState.state $reviewSchemaDocument }
        catch { $reviewSchemaOk = $false; $reviewSchemaFailures += "$($completedReviewState.name): $($_.Exception.Message)" }
    }
    foreach ($schemaMutation in @('bad-verdict', 'missing-tree-digest', 'missing-record-sha', 'unexpected-runtime-key')) {
        $badReviewState = ($validationState | ConvertTo-Json -Depth 100) | ConvertFrom-Json
        if ($schemaMutation -ceq 'bad-verdict') {
            $badReviewState.wave_runtime.'1'.review.verdicts = @([pscustomobject]@{
                verdict = 'approve'; digest = ('a' * 64); record_path = $reviewRecordOne
                record_sha256 = ('b' * 64); at = 'now'
            })
        } elseif ($schemaMutation -ceq 'missing-tree-digest') {
            $badReviewState.wave_runtime.'1'.review.PSObject.Properties.Remove('tree_digest')
        } elseif ($schemaMutation -ceq 'missing-record-sha') {
            $badVerdict = [pscustomobject]@{ verdict = 'clean'; digest = ('a' * 64); record_path = $reviewRecordOne; at = 'now' }
            $badReviewState.wave_runtime.'1'.review.verdicts = @($badVerdict)
        } else {
            $badReviewState.wave_runtime.'1' | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
        }
        $rejectedBySchema = $false
        try { Test-Structure $badReviewState $reviewSchemaDocument }
        catch { $rejectedBySchema = $true }
        if (-not $rejectedBySchema) { $reviewSchemaFailures += $schemaMutation }
    }
    Assert-Test 'review schema' `
        ($v1Compatible -and $reviewSchemaOk -and @($reviewSchemaFailures).Count -eq 0) `
        ($reviewSchemaFailures -join '; ')

    $teardownReview = Invoke-TestScenario -Name 'awaiting-review-teardown' -Risk high -Single
    $teardownReviewFile = Get-TestOnlyStateFile $teardownReview.state_root
    $teardownReviewState = Get-TestOnlyState $teardownReview.state_root
    $teardownWithoutDiscard = Invoke-TestEngine @('-Teardown', $teardownReviewState.run_id, '-StateRoot', $teardownReview.state_root)
    $teardownRefusedState = Get-TestOnlyState $teardownReview.state_root
    $teardownWithDiscard = Invoke-TestEngine @('-Teardown', $teardownReviewState.run_id, '-Discard', '-StateRoot', $teardownReview.state_root)
    $teardownDoneState = Get-TestOnlyState $teardownReview.state_root
    Assert-Test 'awaiting-review teardown' `
        ($teardownWithoutDiscard.code -eq 1 -and $teardownWithoutDiscard.output -match 'awaiting-review' -and
            $teardownRefusedState.status -ceq 'awaiting-review' -and $teardownWithDiscard.code -eq 0 -and
            $teardownDoneState.teardown.status -ceq 'complete') `
        "without=$($teardownWithoutDiscard.output); with=$($teardownWithDiscard.output)"

    $originalHandoff = ${function:Invoke-EngineHandoff}
    $script:CapturedExpectedTip = $null; $script:CapturedHandoffCalls = 0
    function Invoke-EngineHandoff {
        param($Repo, $IntegrationWorktree, $BaseSha, $Files, $JournaledPaths, $OnFileJournaled, $StateDirectory, $ExpectedTip)
        $script:CapturedExpectedTip = [string]$ExpectedTip; $script:CapturedHandoffCalls++
        return [pscustomobject]@{ ok = $true; mismatch_path = $null; recovery_patch = $null }
    }
    try {
        $expectedTipState = ($twoWaveDone | ConvertTo-Json -Depth 100) | ConvertFrom-Json
        $expectedTipState.status = 'running'; $expectedTipState.handoff.status = 'pending'
        $expectedTipState.handoff.started_at = $null; $expectedTipState.handoff.completed_at = $null
        $script:EngineState = $expectedTipState; $script:EngineStatePath = Join-Path $testRoot 'handoff-expected\engine-state.json'
        $expectedTipCall = Invoke-RunnerHandoff
        $capturedExpectedTip = [string]$script:CapturedExpectedTip

        $mismatchedReviewState = ($twoWaveDone | ConvertTo-Json -Depth 100) | ConvertFrom-Json
        $mismatchedReviewState.status = 'running'; $mismatchedReviewState.handoff.status = 'pending'
        $mismatchedReviewState.wave_runtime.'2'.review.head = [string]$mismatchedReviewState.base_sha
        $script:EngineState = $mismatchedReviewState; $script:EngineStatePath = Join-Path $testRoot 'handoff-mismatch\engine-state.json'
        $callsBeforeMismatch = $script:CapturedHandoffCalls
        $mismatchedReviewCall = Invoke-RunnerHandoff

        $rejectedEarlierState = ($twoWaveDone | ConvertTo-Json -Depth 100) | ConvertFrom-Json
        $rejectedEarlierState.status = 'running'; $rejectedEarlierState.handoff.status = 'pending'
        $rejectedEarlierState.wave_runtime.'1'.review.status = 'rejected'
        $mainBeforeRejectedHandoff = Get-TestFileSha256 (Join-Path $highTwoWave.repo 'src\a.py')
        $script:EngineState = $rejectedEarlierState; $script:EngineStatePath = Join-Path $testRoot 'handoff-rejected\engine-state.json'
        $callsBeforeRejected = $script:CapturedHandoffCalls
        $rejectedEarlierCall = Invoke-RunnerHandoff
        $mainAfterRejectedHandoff = Get-TestFileSha256 (Join-Path $highTwoWave.repo 'src\a.py')
    } finally { Set-Item -LiteralPath Function:Invoke-EngineHandoff -Value $originalHandoff }
    Assert-Test 'hand-off refuses an unreviewed tip' `
        ($expectedTipCall -and $capturedExpectedTip -ceq [string]$expectedTipState.integration.tip -and
            -not $mismatchedReviewCall -and $mismatchedReviewState.status -ceq 'parked' -and
            $mismatchedReviewState.handoff.status -ceq 'pending' -and $script:CapturedHandoffCalls -eq $callsBeforeMismatch -and
            -not $rejectedEarlierCall -and $rejectedEarlierState.status -ceq 'parked' -and
            $rejectedEarlierState.handoff.status -ceq 'pending' -and $script:CapturedHandoffCalls -eq $callsBeforeRejected -and
            $mainBeforeRejectedHandoff -ceq $mainAfterRejectedHandoff) `
        "expected=$capturedExpectedTip; mismatch=$($mismatchedReviewState.diagnosis); rejected=$($rejectedEarlierState.diagnosis)"

    $capacityGate = Join-Path $testRoot 'capacity-critical-refusal.ps1'
    Write-TestText $capacityGate "param([switch]`$Test, [string[]]`$Paths, [string]`$Root)`nWrite-Host 'capacity plan captured'`nexit 11`n"
    $capacityCases = @()
    foreach ($capacityDefinition in @(
        [pscustomobject]@{ name = 'cli2-spec1-ultra'; cli = 2; spec = 1; effort = 'ultra'; tasks = 1 },
        [pscustomobject]@{ name = 'cli3-default'; cli = 3; spec = $null; effort = 'medium'; tasks = 5 },
        [pscustomobject]@{ name = 'spec6-machine4'; cli = $null; spec = 6; effort = 'medium'; tasks = 5 },
        [pscustomobject]@{ name = 'cli1-spec3'; cli = 1; spec = 3; effort = 'medium'; tasks = 5 }
    )) {
        $capacityRepoPath = New-TestRepo ("capacity-$($capacityDefinition.name)-repo")
        $capacitySpecPath = Join-Path $testRoot ("capacity-$($capacityDefinition.name).md")
        New-TestRoutingSpec $capacityRepoPath $capacitySpecPath $capacityDefinition.tasks $capacityDefinition.spec $capacityDefinition.effort
        $capacityRoot = Join-Path $testRoot ("capacity-$($capacityDefinition.name)-state")
        $capacityParameters = @{
            SpecPath = $capacitySpecPath; Repo = $capacityRepoPath; StateRoot = $capacityRoot
            WorktreeRoot = (Join-Path $testRoot ("capacity-$($capacityDefinition.name)-worktrees"))
            CodexExecutable = 'powershell.exe'; CodexExecutableArgumentPrefix = $prefix
        }
        if ($null -ne $capacityDefinition.cli) { $capacityParameters.MaxParallel = [int]$capacityDefinition.cli }
        $env:APEX_ENGINE_TEST_CRITICAL_PATH = $capacityGate
        try { $capacityRun = Invoke-TestEngineSplat $capacityParameters ("capacity-$($capacityDefinition.name)") }
        finally { Remove-Item Env:APEX_ENGINE_TEST_CRITICAL_PATH -ErrorAction SilentlyContinue }
        $capacityCases += [pscustomobject]@{
            definition = $capacityDefinition; result = $capacityRun; state = (Get-TestOnlyState $capacityRoot)
        }
    }
    $ultraCapacity = $capacityCases[0]
    $defaultCapacity = $capacityCases[1]
    $machineCapacity = $capacityCases[2]
    $cliOneCapacity = $capacityCases[3]
    $dispatchHasMachineCeiling = $false
    foreach ($attempt in @($state.tasks | ForEach-Object { @($_.attempts) })) {
        $dispatchDocument = Get-Content -LiteralPath $attempt.args_path -Raw | ConvertFrom-Json
        if ($dispatchDocument.PSObject.Properties['MachineCeiling']) { $dispatchHasMachineCeiling = $true }
    }
    $maxParallelOk = (
        $ultraCapacity.result.code -ne 0 -and $ultraCapacity.state.status -ceq 'refused' -and
        $ultraCapacity.state.diagnosis -match 'weight exceeds MaxParallel' -and
        $ultraCapacity.state.counters.dispatches -eq 0 -and
        $ultraCapacity.state.max_parallel -eq 1 -and $ultraCapacity.state.capacity.cli -eq 2 -and
        $ultraCapacity.state.capacity.spec_ceiling -eq 1 -and $ultraCapacity.state.capacity.machine_ceiling -eq 4 -and
        $defaultCapacity.state.max_parallel -eq 2 -and $defaultCapacity.state.capacity.cli -eq 3 -and
        $defaultCapacity.state.capacity.spec_ceiling -eq 2 -and
        (@($defaultCapacity.state.plan.waves | ForEach-Object { @($_.tasks).Count }) -join ',') -ceq '2,2,1' -and
        $machineCapacity.state.max_parallel -eq 4 -and $null -eq $machineCapacity.state.capacity.cli -and
        $machineCapacity.state.capacity.spec_ceiling -eq 6 -and
        (@($machineCapacity.state.plan.waves | ForEach-Object { @($_.tasks).Count }) -join ',') -ceq '4,1' -and
        $cliOneCapacity.state.max_parallel -eq 1 -and $cliOneCapacity.state.capacity.cli -eq 1 -and
        $cliOneCapacity.state.capacity.spec_ceiling -eq 3 -and
        (@($cliOneCapacity.state.plan.waves | ForEach-Object { @($_.tasks).Count }) -join ',') -ceq '1,1,1,1,1' -and
        -not $dispatchHasMachineCeiling)
    Assert-Test 'MaxParallel' $maxParallelOk (($capacityCases | ForEach-Object {
        "$($_.definition.name):$($_.result.code):$($_.state.max_parallel):$(@($_.state.plan.waves | ForEach-Object { @($_.tasks).Count }) -join ',')"
    }) -join '; ')
    $missingPlanFieldRejected = $false
    try {
        $badState = ($state | ConvertTo-Json -Depth 100) | ConvertFrom-Json
        $badState.plan.waves[0].tasks[0].PSObject.Properties.Remove('prompt_digest')
        Test-Structure $badState (Get-Content $schemaPath -Raw | ConvertFrom-Json)
    } catch { $missingPlanFieldRejected = $true }
    Assert-Test 'structural schema rejects state missing required immutable plan field' `
        $missingPlanFieldRejected 'state without plan.tasks[].prompt_digest passed structural checking'
    $missingPromptSourceRejected = $false
    try {
        $badPromptState = ($state | ConvertTo-Json -Depth 100) | ConvertFrom-Json
        $badPromptTask = $badPromptState.plan.waves[0].tasks[0]
        $badPromptTask.PSObject.Properties.Remove('prompt')
        $badPromptTask.PSObject.Properties.Remove('prompt_path')
        Test-Structure $badPromptState (Get-Content $schemaPath -Raw | ConvertFrom-Json)
    } catch { $missingPromptSourceRejected = $true }
    Assert-Test 'structural schema requires each immutable plan task prompt text or prompt path' `
        $missingPromptSourceRejected 'state task without prompt or prompt_path passed structural checking'

    $riskCriticalSpec = Join-Path $testRoot 'risk-critical-refused.md'
    New-TestSpec $repo $riskCriticalSpec -Single -Risk critical
    $riskCriticalStateRoot = Join-Path $testRoot 'risk-critical-refused-state'
    $riskCriticalRun = Invoke-TestEngine @('-SpecPath', $riskCriticalSpec, '-Repo', $repo,
        '-StateRoot', $riskCriticalStateRoot, '-WorktreeRoot', (Join-Path $testRoot 'risk-critical-refused-wt'))
    $riskCriticalState = Get-TestOnlyState $riskCriticalStateRoot
    $riskCriticalSchemaOk = $true; $riskCriticalSchemaError = ''
    try { Test-Structure $riskCriticalState (Get-Content $schemaPath -Raw | ConvertFrom-Json) }
    catch { $riskCriticalSchemaOk = $false; $riskCriticalSchemaError = $_.Exception.Message }
    Assert-Test 'risk critical refusal persists schema-valid loose refused plan' `
        ($riskCriticalRun.code -ne 0 -and $riskCriticalState.status -ceq 'refused' -and
            $riskCriticalState.plan.allowed -eq $false -and $riskCriticalState.plan.spec.risk -ceq 'critical' -and $riskCriticalSchemaOk) `
        "output=$($riskCriticalRun.output); schema=$riskCriticalSchemaError"

    $invalidEffortSpec = Join-Path $testRoot 'invalid-effort-refused.md'
    New-TestSpec $repo $invalidEffortSpec -Single
    Write-TestText $invalidEffortSpec (([IO.File]::ReadAllText($invalidEffortSpec)).Replace('coder_effort: medium', 'coder_effort: impossible'))
    $invalidEffortStateRoot = Join-Path $testRoot 'invalid-effort-refused-state'
    $invalidEffortRun = Invoke-TestEngine @('-SpecPath', $invalidEffortSpec, '-Repo', $repo,
        '-StateRoot', $invalidEffortStateRoot, '-WorktreeRoot', (Join-Path $testRoot 'invalid-effort-refused-wt'))
    $invalidEffortState = Get-TestOnlyState $invalidEffortStateRoot
    $invalidEffortSchemaOk = $true; $invalidEffortSchemaError = ''
    try { Test-Structure $invalidEffortState (Get-Content $schemaPath -Raw | ConvertFrom-Json) }
    catch { $invalidEffortSchemaOk = $false; $invalidEffortSchemaError = $_.Exception.Message }
    Assert-Test 'invalid coder effort refusal persists schema-valid loose refused plan' `
        ($invalidEffortRun.code -ne 0 -and $invalidEffortState.status -ceq 'refused' -and
            $invalidEffortState.plan.allowed -eq $false -and $invalidEffortState.plan.spec.coder_effort -ceq 'impossible' -and
            $invalidEffortSchemaOk) "output=$($invalidEffortRun.output); schema=$invalidEffortSchemaError"

    $allowedBadEffortRejected = $false
    try {
        $allowedBadEffort = ($state | ConvertTo-Json -Depth 100) | ConvertFrom-Json
        $allowedBadEffort.plan.spec.coder_effort = 'impossible'
        Test-Structure $allowedBadEffort (Get-Content $schemaPath -Raw | ConvertFrom-Json)
    } catch { $allowedBadEffortRejected = $true }
    Assert-Test 'allowed plan with invalid coder effort fails structural schema' `
        $allowedBadEffortRejected 'allowed plan with invalid coder_effort passed structural checking'

    $bytesEqual = $false
    if ($null -ne $state) {
        $integrationA = Join-Path $state.integration.worktree 'src\a.py'
        $bytesEqual = [Convert]::ToBase64String([IO.File]::ReadAllBytes($integrationA)) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $repo 'src\a.py')))
    }
    $filteredIdentity = $false; $hasCrlf = $false
    if ($null -ne $state) {
        $mainA = Join-Path $repo 'src\a.py'
        $filtered = Get-EngineFilteredWorkingHash -Repo $repo -RelativePath 'src/a.py'
        $committed = Get-EngineBlobHash -Repo $state.integration.worktree -Commit $state.integration.tip -RelativePath 'src/a.py'
        $filteredIdentity = ($filtered -ceq $committed -and $state.tasks[0].attempts[0].end_tree_digest -match '^[0-9a-f]{64}$')
        $hasCrlf = [IO.File]::ReadAllText($mainA).Contains("`r`n")
    }
    Assert-Test 'CRLF under real core.autocrlf/text filter preserves filtered identity and digest' `
        ($bytesEqual -and $filteredIdentity -and $hasCrlf) 'CRLF bytes, filtered Git identity, or wrapper digest did not hold'

    $inside = Invoke-TestEngine @('-SpecPath', $spec, '-Repo', $repo, '-StateRoot', (Join-Path $repo '.engine-state'), '-WorktreeRoot', (Join-Path $testRoot 'other-wt'))
    $invalidRun = Invoke-TestEngine @('-Resume', '..\escape', '-StateRoot', $stateRoot)
    Assert-Test 'canonical root and run-ID containment refusal before writes' `
        ($inside.code -ne 0 -and -not (Test-Path (Join-Path $repo '.engine-state')) -and $invalidRun.code -ne 0) `
        'inside-worktree state or traversal run id was accepted'

    $criticalRepo = New-TestRepo 'critical-repo'
    $criticalSpec = Join-Path $testRoot 'critical-fixture.md'
    New-TestSpec $criticalRepo $criticalSpec -Critical
    $criticalState = Join-Path $testRoot 'critical-state'
    $criticalRun = Invoke-TestEngineSplat @{
        SpecPath = $criticalSpec; Repo = $criticalRepo; StateRoot = $criticalState
        WorktreeRoot = (Join-Path $testRoot 'critical-wt'); CodexExecutable = 'powershell.exe'
        CodexExecutableArgumentPrefix = $prefix
    } 'critical'
    $criticalStateFile = @(Get-ChildItem $criticalState -Filter engine-state.json -Recurse -File)[0]
    $criticalJson = Get-Content $criticalStateFile.FullName -Raw | ConvertFrom-Json
    Assert-Test 'critical-file gate parks before task worktree dispatch' `
        ($criticalRun.code -ne 0 -and $criticalJson.status -ceq 'parked' -and $criticalJson.diagnosis -match 'critical-file' -and @($criticalJson.tasks[0].attempts).Count -eq 0) `
        $criticalRun.output

    $digestContext = New-TestRouteContext
    $digestContext.attempt.end_tree_digest = 'unverifiable'
    $digestOk = Confirm-RunnerBuildDigest $digestContext.attempt $digestContext.task
    Assert-Test 'literal unverifiable build digest parks distinctly from tree moved' `
        (-not $digestOk -and $script:EngineState.status -ceq 'parked' -and $script:EngineState.diagnosis -ceq 'unverifiable build digest') `
        "status=$($script:EngineState.status); diagnosis=$($script:EngineState.diagnosis)"

    # Routing tests replace only digest verification/adoption side effects; Route-RunnerResult itself
    # is the production function imported above.
    function Confirm-RunnerBuildDigest { param($Attempt, $TaskState) return $true }
    function Invoke-EngineAdopt { param($WrapperPath, $RunId, $Spec, $Task, $Worktree, $StateRoot, $ChildOutputPath) return $script:TestAdoptResult }

    $exit69Cases = [ordered]@{
        failed = 'tree moved between pre-flight and launch (exit 69)'
        'adopted-void' = 'adopted tree moved; verdict void (exit 69)'
        done = 'task tree moved during build (exit 69)'
        done_with_concerns = 'task tree moved during build (exit 69)'
    }
    $exit69Ok = $true
    foreach ($exit69Status in @($exit69Cases.Keys)) {
        $exit69Context = New-TestRouteContext
        $exit69Event = New-TestDispatchResultEvent -ExitCode 69 -Status $exit69Status
        $exit69Event.tree_moved = $true
        $exit69Route = Route-RunnerResult $exit69Context.plan $exit69Context.task $exit69Context.attempt (New-TestResult 69 $exit69Event)
        if ($exit69Route -cne 'park' -or $exit69Context.task.diagnosis -cne $exit69Cases[$exit69Status]) { $exit69Ok = $false }
    }
    $exit69Fallback = New-TestRouteContext
    $exit69FallbackEvent = New-TestDispatchResultEvent -ExitCode 73 -Status failed
    $exit69FallbackEvent | Add-Member -MemberType NoteProperty -Name error -Value 'fixture error'
    [void](Route-RunnerResult $exit69Fallback.plan $exit69Fallback.task $exit69Fallback.attempt (New-TestResult 73 $exit69FallbackEvent))
    Assert-Test 'exit-69 diagnosis' `
        ($exit69Ok -and $exit69Fallback.task.diagnosis -ceq 'wrapper exit 73 (status failed; error fixture error)') `
        $exit69Fallback.task.diagnosis

    $exit69Invalid = New-TestRouteContext
    $exit69InvalidEvent = New-TestDispatchResultEvent -ExitCode 69 -Status failed
    $exit69InvalidEvent.tree_moved = $true
    $exit69InvalidDiagnosis = 'exit/status correlation failed for exit 69'
    $exit69InvalidRoute = Route-RunnerResult $exit69Invalid.plan $exit69Invalid.task $exit69Invalid.attempt `
        (New-TestResult 69 $exit69InvalidEvent $exit69InvalidDiagnosis)
    Assert-Test 'exit-69 unvalidated event preserves validation diagnosis' `
        ($exit69InvalidRoute -ceq 'park' -and $exit69Invalid.task.diagnosis -ceq $exit69InvalidDiagnosis -and
            $exit69Invalid.task.diagnosis -cnotmatch 'tree moved') $exit69Invalid.task.diagnosis

    $blockedContext = New-TestRouteContext
    $blockedFinal = [pscustomobject]@{ status = 'blocked'; changed_files = @(); commands_run = @(); deviations = @(); unresolved = @(); blocker = 'spec defect' }
    $blockedEvent = New-TestDispatchResultEvent -ExitCode 1 -Status failed -Final $blockedFinal
    $blockedRoute = Route-RunnerResult $blockedContext.plan $blockedContext.task $blockedContext.attempt (New-TestResult 1 $blockedEvent)
    Assert-Test 'exit-1 blocked final parks as spec defect' `
        ($blockedRoute -ceq 'park' -and $blockedContext.task.diagnosis -ceq 'spec defect: final blocked') $blockedContext.task.diagnosis

    $quotaPositive = $true
    $quotaDetails = @()
    $plainQuotaLines = @(
        'prefix{"type":"turn.started"}}ERROR: You''ve hit your usage limit; retry later',
        'ERROR: You''ve hit your usage limit soon{"type":"turn.started"}'
    )
    for ($quotaIndex = 0; $quotaIndex -lt $plainQuotaLines.Count; $quotaIndex++) {
        $plainQuotaLog = Join-Path $testRoot "plain-quota-$quotaIndex.log"
        Write-TestText $plainQuotaLog $plainQuotaLines[$quotaIndex]
        $plainQuotaContext = New-TestRouteContext
        $plainQuotaEvent = New-TestDispatchResultEvent -ExitCode 1 -Status failed -LogPath $plainQuotaLog
        $plainQuotaRoute = Route-RunnerResult $plainQuotaContext.plan $plainQuotaContext.task $plainQuotaContext.attempt `
            (New-TestResult 1 $plainQuotaEvent)
        $plainQuotaOk = ($plainQuotaRoute -ceq 'park' -and $script:EngineState.status -ceq 'paused' -and
            $plainQuotaContext.task.status -ceq 'parked' -and $plainQuotaContext.task.diagnosis -ceq 'quota or rate limit')
        if (-not $plainQuotaOk) { $quotaPositive = $false }
        $quotaDetails += "plain-$quotaIndex=$plainQuotaRoute/$($script:EngineState.status)"
    }
    $jsonQuotaLines = @(
        'chunk-prefix{"type":"error","message":"You''ve hit your usage limit. Visit settings."}',
        '{"type":"turn.started"}interleaved chunk prefix{"type":"turn.failed","error":{"message":"You''ve hit your usage limit. Try later."}}',
        '{"type":"error","message":"429 Too Many Requests: slow down"}',
        '{"type":"turn.failed","error":{"message":"request failed; status: 429"}}'
    )
    for ($quotaIndex = 0; $quotaIndex -lt $jsonQuotaLines.Count; $quotaIndex++) {
        $jsonQuotaLog = Join-Path $testRoot "json-quota-$quotaIndex.log"
        Write-TestText $jsonQuotaLog $jsonQuotaLines[$quotaIndex]
        $jsonQuotaContext = New-TestRouteContext
        $jsonQuotaEvent = New-TestDispatchResultEvent -ExitCode 1 -Status failed -LogPath $jsonQuotaLog
        $jsonQuotaRoute = Route-RunnerResult $jsonQuotaContext.plan $jsonQuotaContext.task $jsonQuotaContext.attempt `
            (New-TestResult 1 $jsonQuotaEvent)
        $jsonQuotaOk = ($jsonQuotaRoute -ceq 'park' -and $script:EngineState.status -ceq 'paused' -and
            $jsonQuotaContext.task.diagnosis -ceq 'quota or rate limit')
        if (-not $jsonQuotaOk) { $quotaPositive = $false }
        $quotaDetails += "json-$quotaIndex=$jsonQuotaRoute/$($script:EngineState.status)"
    }

    $agentMessageLog = Join-Path $testRoot 'agent-message-child.log'
    Write-TestText $agentMessageLog '{"type":"item.completed","item":{"type":"agent_message","text":"The captured diagnostic says: You''ve hit your usage limit. Visit settings for details."}}'
    $agentMessageContext = New-TestRouteContext
    $agentMessageEvent = New-TestDispatchResultEvent -ExitCode 1 -Status failed -LogPath $agentMessageLog
    $agentMessageRoute = Route-RunnerResult $agentMessageContext.plan $agentMessageContext.task $agentMessageContext.attempt (New-TestResult 1 $agentMessageEvent)
    Assert-Test 'agent_message text quoting usage-limit sentence is not quota' `
        ($agentMessageRoute -ceq 'fresh-same-effort' -and $script:EngineState.status -ceq 'running') `
        "route=$agentMessageRoute status=$($script:EngineState.status)"

    $nonService429Log = Join-Path $testRoot 'agent-message-command-429.log'
    Write-TestText $nonService429Log @'
{"type":"item.completed","item":{"type":"agent_message","text":"quoted 429 Too Many Requests"}}
{"type":"item.completed","item":{"type":"command_execution","aggregated_output":"status: 429"}}
'@
    $nonService429Context = New-TestRouteContext
    $nonService429Event = New-TestDispatchResultEvent -ExitCode 1 -Status failed -LogPath $nonService429Log
    $nonService429Route = Route-RunnerResult $nonService429Context.plan $nonService429Context.task `
        $nonService429Context.attempt (New-TestResult 1 $nonService429Event)

    $selectedCapacityLog = Join-Path $testRoot 'selected-model-capacity.log'
    Write-TestText $selectedCapacityLog '{"type":"error","message":"Selected model is at capacity. Please try a different model."}'
    $selectedCapacityContext = New-TestRouteContext
    $selectedCapacityEvent = New-TestDispatchResultEvent -ExitCode 1 -Status failed -LogPath $selectedCapacityLog
    $selectedCapacityRoute = Route-RunnerResult $selectedCapacityContext.plan $selectedCapacityContext.task `
        $selectedCapacityContext.attempt (New-TestResult 1 $selectedCapacityEvent)
    $quotaNegative = ($agentMessageRoute -ceq 'fresh-same-effort' -and
        $nonService429Route -ceq 'fresh-same-effort' -and
        $selectedCapacityRoute -ceq 'fresh-same-effort' -and
        $selectedCapacityContext.attempt.diagnosis -ceq 'process failure')
    Assert-Test 'quota and 429' ($quotaPositive -and $quotaNegative) `
        (($quotaDetails + @("agent=$agentMessageRoute", "item429=$nonService429Route", "selected=$selectedCapacityRoute")) -join '; ')

    $mentionLog = Join-Path $testRoot 'ordinary-child.log'; Write-TestText $mentionLog "ordinary progress`n"
    $mentionContext = New-TestRouteContext
    $mentionFinal = [pscustomobject]@{ status = 'done'; changed_files = @(); commands_run = @(); deviations = @('mentions a rate limiter'); unresolved = @(); blocker = $null }
    $mentionEvent = New-TestDispatchResultEvent -ExitCode 1 -Status failed -Final $mentionFinal -LogPath $mentionLog
    $mentionRoute = Route-RunnerResult $mentionContext.plan $mentionContext.task $mentionContext.attempt (New-TestResult 1 $mentionEvent)
    Assert-Test 'coder final report mentioning rate limiter is not quota' `
        ($mentionRoute -ceq 'fresh-same-effort' -and $script:EngineState.status -ceq 'running') "route=$mentionRoute status=$($script:EngineState.status)"

    $processContext = New-TestRouteContext -AttemptCount 2
    $processContext.task.attempts[0].diagnosis = 'process failure'; $processContext.task.attempts[0].status = 'failed'
    $processEvent = New-TestDispatchResultEvent -ExitCode 1 -Status failed
    $processRoute = Route-RunnerResult $processContext.plan $processContext.task $processContext.attempt (New-TestResult 1 $processEvent)
    Assert-Test 'repeated process failure parks after exactly one same-effort redispatch' `
        ($processRoute -ceq 'park' -and $processContext.task.diagnosis -ceq 'process failure retry exhausted') $processContext.task.diagnosis

    $capacityContext = New-TestRouteContext
    Write-TestText $capacityContext.attempt.child_output_path "[dispatch] REFUSED (exit 79): build capacity is full.`n"
    $capacityEvent = New-TestDispatchRefusalEvent 79 $null 'build capacity is full' -Repo $testRoot
    $capacityRoutes = @()
    for ($capacityTry = 0; $capacityTry -le 10; $capacityTry++) {
        $capacityRoutes += Route-RunnerResult $capacityContext.plan $capacityContext.task $capacityContext.attempt (New-TestResult 79 $capacityEvent)
    }
    Assert-Test 'exit 79 non-permanent capacity retries ten times then parks' `
        (@($capacityRoutes | Where-Object { $_ -ceq 'same-attempt' }).Count -eq 10 -and $capacityRoutes[-1] -ceq 'park' -and
            $capacityContext.attempt.capacity_retries -eq 10) ($capacityRoutes -join ',')

    $permanentContext = New-TestRouteContext
    Write-TestText $permanentContext.attempt.child_output_path "[dispatch] REFUSED (exit 79): max_parallel_codex is invalid.`n[dispatch] PERMANENT: invalid capacity contract (do not re-queue).`n"
    $permanentEvent = New-TestDispatchRefusalEvent 79 $null 'max_parallel_codex is present but unparseable in the spec frontmatter' -Repo $testRoot
    $permanentRoute = Route-RunnerResult $permanentContext.plan $permanentContext.task $permanentContext.attempt (New-TestResult 79 $permanentEvent)
    Assert-Test 'exit 79 exact live-wrapper PERMANENT line parks immediately' `
        ($permanentRoute -ceq 'park' -and $permanentContext.attempt.capacity_retries -eq 0 -and
            $permanentContext.task.diagnosis -ceq 'permanent capacity refusal (exit 79)') $permanentContext.task.diagnosis

    $capacityRepo = New-TestRepo 'live-capacity-repo'
    $capacitySpec = Join-Path $testRoot 'live-capacity.md'
    New-TestSpec $capacityRepo $capacitySpec -Single
    Write-TestText $capacitySpec (([IO.File]::ReadAllText($capacitySpec)) -replace 'max_parallel_codex: 2', 'max_parallel_codex: invalid')
    $capacityStateRoot = Join-Path $testRoot 'live-capacity-state'
    $capacityArgs = Join-Path $capacityStateRoot 'dispatch-args.json'
    $capacityOutput = Join-Path $capacityStateRoot 'child.out'
    Write-EngineDispatchArgs -ArgsPath $capacityArgs -Parameters @{
        Phase = 'build'; Spec = 'live-capacity'; Task = '1'; Worktree = $capacityRepo
        BaseSha = (Invoke-TestGit $capacityRepo @('rev-parse', 'HEAD'))[-1]; SpecSourcePath = $capacitySpec
        Authorized = [string[]]@('src/a.py'); Effort = 'medium'; Model = 'gpt-5.6-sol'; Prompt = 'capacity fixture'
        ScratchDirectory = (Join-Path $capacityStateRoot 'scratch'); CodexExecutable = 'powershell.exe'
        CodexExecutableArgumentPrefix = $prefix
    } | Out-Null
    $capacityChild = Start-EngineDispatch -WrapperPath (Join-Path $PSScriptRoot 'codex-dispatch.ps1') `
        -ArgsPath $capacityArgs -ChildOutputPath $capacityOutput -StateRoot $capacityStateRoot
    $capacityLiveResult = Wait-EngineDispatch -ChildPid $capacityChild.pid -ChildOutputPath $capacityOutput `
        -LedgerPath (Join-Path $capacityStateRoot 'progress\codex-run-ledger.jsonl')
    $livePermanentContext = New-TestRouteContext
    $livePermanentContext.attempt.child_output_path = $capacityOutput
    $livePermanentRoute = Route-RunnerResult $livePermanentContext.plan $livePermanentContext.task `
        $livePermanentContext.attempt $capacityLiveResult
    Assert-Test 'real wrapper emits exact permanent-capacity refusal consumed by runner' `
        ($capacityLiveResult.exit_code -eq 79 -and $livePermanentRoute -ceq 'park' -and
            $livePermanentContext.attempt.capacity_retries -eq 0) `
        ([IO.File]::ReadAllText($capacityOutput))

    $adoptSuccessContext = New-TestRouteContext
    $blockingId = '22222222222222222222222222222222'
    $blockingEvent = New-TestDispatchRefusalEvent 80 $blockingId 'matching live run blocks dispatch' -Repo $testRoot
    $adoptFinal = [pscustomobject]@{ status = 'done'; changed_files = @('src/a.py'); commands_run = @(); deviations = @(); unresolved = @(); blocker = $null }
    $script:TestAdoptResult = New-TestResult 0 (New-TestDispatchResultEvent -ExitCode 0 -Status done -Final $adoptFinal -RunId $blockingId)
    $adoptSuccessRoute = Route-RunnerResult $adoptSuccessContext.plan $adoptSuccessContext.task $adoptSuccessContext.attempt (New-TestResult 80 $blockingEvent)
    Assert-Test 'exit 80 successful adoption integrates adopted result without redispatch' `
        ($adoptSuccessRoute -ceq 'success' -and $adoptSuccessContext.attempt.status -ceq 'succeeded') "route=$adoptSuccessRoute"

    $adoptFailureContext = New-TestRouteContext
    $adoptBlocked = [pscustomobject]@{ status = 'blocked'; changed_files = @(); commands_run = @(); deviations = @(); unresolved = @(); blocker = 'blocked' }
    $script:TestAdoptResult = New-TestResult 67 (New-TestDispatchResultEvent -ExitCode 67 -Status blocked -Final $adoptBlocked -RunId $blockingId)
    $adoptFailureRoute = Route-RunnerResult $adoptFailureContext.plan $adoptFailureContext.task $adoptFailureContext.attempt (New-TestResult 80 $blockingEvent)
    $retryAttempt = ($adoptFailureContext.attempt | Select-Object *)
    $retryAttempt.number = 2; $retryAttempt.status = 'running'; $retryAttempt.diagnosis = $null
    $adoptFailureContext.task.attempts = @($adoptFailureContext.attempt, $retryAttempt)
    $adoptSecondRoute = Route-RunnerResult $adoptFailureContext.plan $adoptFailureContext.task $retryAttempt (New-TestResult 80 $blockingEvent)
    Assert-Test 'exit 80 failed adoption permits one fresh dispatch then parks' `
        ($adoptFailureRoute -ceq 'fresh-same-effort' -and $adoptSecondRoute -ceq 'park') "first=$adoptFailureRoute second=$adoptSecondRoute"

    $pidStamp = Get-RunnerProcessStamp $PID
    Assert-Test 'PID identity requires live PID and matching process start time; zero is unknown' `
        ((Test-RunnerPidLive $PID $pidStamp) -and -not (Test-RunnerPidLive $PID ([DateTime]::UtcNow.AddDays(-1).ToString('o'))) -and
            -not (Test-RunnerPidLive 0 $null)) 'PID/start-time identity check accepted a recycled or unknown PID'

    $startTimeContext = New-TestRouteContext
    $startTimeContext.plan.files = @([pscustomobject]@{ path = 'src/a.py' })
    $startTimeContext.attempt.worktree = $repo
    $startTimeContext.attempt.args_path = Join-Path $testRoot 'start-time-dispatch-args.json'
    $startTimeContext.attempt.child_output_path = Join-Path $testRoot 'start-time-child.out'
    $script:EngineState.spec | Add-Member -NotePropertyName snapshot_path -NotePropertyValue $spec -Force
    $script:EngineState | Add-Member -NotePropertyName plan -NotePropertyValue ([pscustomobject]@{
        spec = [pscustomobject]@{ coder_model = 'gpt-5.6-sol' }
    }) -Force
    $script:EngineStatePath = Join-Path $testRoot 'start-time-state\engine-state.json'
    $suppliedStartTime = '2001-02-03T04:05:06.0000000Z'
    $script:StartStampProbeCount = 0
    $originalCriticalGate = ${function:Test-RunnerCriticalGate}
    $originalStartDispatch = ${function:Start-EngineDispatch}
    $originalStampProbe = ${function:Get-RunnerProcessStamp}
    $originalSaveRunnerState = ${function:Save-RunnerState}
    function Test-RunnerCriticalGate { param($TaskPlan, $TaskState) return $true }
    function Start-EngineDispatch {
        param($WrapperPath, $ArgsPath, $ChildOutputPath, $StateRoot)
        return [pscustomobject]@{ pid = $PID; start_time = $suppliedStartTime }
    }
    function Get-RunnerProcessStamp { param($ProcessId) $script:StartStampProbeCount++; return 'fallback-stamp' }
    function Save-RunnerState { return }
    try { $startTimeChild = Start-RunnerAttempt $startTimeContext.plan $startTimeContext.task $startTimeContext.attempt }
    finally {
        Set-Item -LiteralPath Function:Test-RunnerCriticalGate -Value $originalCriticalGate
        Set-Item -LiteralPath Function:Start-EngineDispatch -Value $originalStartDispatch
        Set-Item -LiteralPath Function:Get-RunnerProcessStamp -Value $originalStampProbe
        Set-Item -LiteralPath Function:Save-RunnerState -Value $originalSaveRunnerState
    }
    Assert-Test 'start_time' `
        ($null -ne $startTimeChild -and $startTimeContext.attempt.child_start_time -ceq $suppliedStartTime -and
            $script:StartStampProbeCount -eq 0) `
        "saved=$($startTimeContext.attempt.child_start_time); probes=$($script:StartStampProbeCount)"

    $gatePin = Join-Path $testRoot 'fake-tree-pin.ps1'
    $gateBaseline = Join-Path $testRoot 'fake-baseline.ps1'
    Write-TestText $gatePin @'
param([switch]$Pin, [switch]$Verify, [switch]$Digest, [string]$Worktree, [string]$Label, [string]$PinDirectory)
$kind = if ($Pin) { 'pin' } elseif ($Verify) { 'verify' } else { 'digest' }
$counter = Join-Path $env:ENGINE_TEST_GATE_COUNTER "$kind.txt"
$count = if (Test-Path $counter) { [int](Get-Content $counter -Raw) } else { 0 }
$count++; [IO.File]::WriteAllText($counter, [string]$count)
if ($Pin -and $env:ENGINE_TEST_PIN_EXIT) { Write-Host 'pin infrastructure diagnosis'; exit ([int]$env:ENGINE_TEST_PIN_EXIT) }
if ($Verify) {
    $sequence = @($env:ENGINE_TEST_VERIFY_SEQUENCE -split ',')
    $code = if ($count -le $sequence.Count -and $sequence[$count - 1] -match '^\d+$') { [int]$sequence[$count - 1] } else { 0 }
    if ($code -ne 0) { Write-Host "verify diagnosis $code"; exit $code }
}
Write-Host "$kind ok"; exit 0
'@
    New-TestGateBaseline $gateBaseline
    function Stage-EngineWave { param($TargetWorktree, $IntegrationWorktree, $Files) [pscustomobject]@{ ok = $script:TestStageOk; failures = @() } }
    $script:EngineTreePinScript = $gatePin; $script:EngineBaselineScript = $gateBaseline; $script:TestStageOk = $true
    $gateContext = New-TestRouteContext
    $gateRepo = New-TestRepo 'gate-unit-repo'
    $script:EngineState.repo = $gateRepo
    $script:EngineState.integration = [pscustomobject]@{ worktree = $gateRepo }
    $script:EngineState.run_id = '33333333333333333333333333333333'
    $script:EngineStatePath = Join-Path $testRoot 'gate-state\engine-state.json'
    [void][IO.Directory]::CreateDirectory((Split-Path $script:EngineStatePath -Parent))
    $gateCodes = @{}
    foreach ($baselineCode in @(0, 1, 3, 4, 9)) {
        $counterRoot = Join-Path $testRoot "gate-$baselineCode"; [void][IO.Directory]::CreateDirectory($counterRoot)
        $env:ENGINE_TEST_GATE_COUNTER = $counterRoot; $env:ENGINE_TEST_BASELINE_EXIT = [string]$baselineCode
        $env:ENGINE_TEST_VERIFY_SEQUENCE = '0'; Remove-Item Env:ENGINE_TEST_PIN_EXIT -ErrorAction SilentlyContinue
        $gateCodes[[string]$baselineCode] = Invoke-RunnerGate @() 1
    }
    Assert-Test 'baseline behavior distinguishes GREEN 0, RED 1, UNPARSEABLE 3, NO_RECIPE 4, and other' `
        ($gateCodes['0'].gate -ceq 'baseline' -and $gateCodes['0'].code -eq 0 -and $gateCodes['1'].code -eq 1 -and
            $gateCodes['3'].code -eq 3 -and $gateCodes['4'].code -eq 4 -and $gateCodes['9'].code -eq 9) 'baseline codes were collapsed'
    $script:TestStageOk = $false
    $stageFailure = Invoke-RunnerGate @() 1
    $script:TestStageOk = $true
    Assert-Test 'operation-precondition stage failure is classified as verify failure' `
        ($stageFailure.gate -ceq 'stage' -and $stageFailure.code -eq 1 -and $stageFailure.diagnosis -ceq 'operation precondition failure') `
        ($stageFailure | ConvertTo-Json -Compress)

    $pinCounter = Join-Path $testRoot 'gate-pin-fail'; [void][IO.Directory]::CreateDirectory($pinCounter)
    $env:ENGINE_TEST_GATE_COUNTER = $pinCounter; $env:ENGINE_TEST_BASELINE_EXIT = '0'; $env:ENGINE_TEST_PIN_EXIT = '1'; $env:ENGINE_TEST_VERIFY_SEQUENCE = '0'
    $pinFailure = Invoke-RunnerGate @() 1
    Assert-Test 'tree-pin infrastructure failure is not baseline RED and preserves exit/diagnosis' `
        ($pinFailure.gate -ceq 'pin' -and $pinFailure.code -eq 1 -and $pinFailure.diagnosis -match 'pin infrastructure diagnosis') `
        ($pinFailure | ConvertTo-Json -Compress)

    Remove-Item Env:ENGINE_TEST_PIN_EXIT -ErrorAction SilentlyContinue
    $repinCounter = Join-Path $testRoot 'gate-repin'; [void][IO.Directory]::CreateDirectory($repinCounter)
    $env:ENGINE_TEST_GATE_COUNTER = $repinCounter; $env:ENGINE_TEST_VERIFY_SEQUENCE = '69,0'
    $repin = Invoke-RunnerGate @() 1
    $repinCounts = @((Get-Content (Join-Path $repinCounter 'pin.txt') -Raw), (Get-Content (Join-Path $repinCounter 'verify.txt') -Raw), (Get-Content (Join-Path $repinCounter 'baseline.txt') -Raw))
    Assert-Test 'single-pass gate' `
        ($repin.gate -ceq 'verify' -and $repin.code -eq 69 -and
            $repinCounts[0] -eq '1' -and $repinCounts[1] -eq '1' -and $repinCounts[2] -eq '1') ($repinCounts -join ',')

    $twiceCounter = Join-Path $testRoot 'gate-moved-twice'; [void][IO.Directory]::CreateDirectory($twiceCounter)
    $env:ENGINE_TEST_GATE_COUNTER = $twiceCounter; $env:ENGINE_TEST_VERIFY_SEQUENCE = '69,69'
    $twice = Invoke-RunnerGate @() 1
    $otherCounter = Join-Path $testRoot 'gate-verify-other'; [void][IO.Directory]::CreateDirectory($otherCounter)
    $env:ENGINE_TEST_GATE_COUNTER = $otherCounter; $env:ENGINE_TEST_VERIFY_SEQUENCE = '24'
    $verifyOther = Invoke-RunnerGate @() 1
    Assert-Test 'single-pass moved and other verify failures park with their exact codes' `
        ($twice.gate -ceq 'verify' -and $twice.code -eq 69 -and $verifyOther.gate -ceq 'verify' -and $verifyOther.code -eq 24) `
        "twice=$($twice.code) other=$($verifyOther.code)"

    $env:APEX_ENGINE_TEST_FAIL_INDEX_IDENTITY = '1'
    try { $identityFailure = Invoke-RunnerGate @() 1 }
    finally { Remove-Item Env:APEX_ENGINE_TEST_FAIL_INDEX_IDENTITY -ErrorAction SilentlyContinue }
    Assert-Test 'git index identity failure returns verify park diagnosis instead of throwing' `
        ($identityFailure.gate -ceq 'verify' -and $identityFailure.code -eq 1 -and
            $identityFailure.diagnosis -match 'git index identity read before pin failed' -and
            $identityFailure.diagnosis -match 'git ls-files') ($identityFailure | ConvertTo-Json -Compress)
    Remove-Item Env:ENGINE_TEST_GATE_COUNTER, Env:ENGINE_TEST_BASELINE_EXIT, Env:ENGINE_TEST_VERIFY_SEQUENCE -ErrorAction SilentlyContinue

    $env:APEX_ENGINE_TEST_FAIL_INDEX_IDENTITY = '1'
    try { $identityFailureCase = Invoke-TestScenario -Name 'git-identity-failure' -Scenario 'done' -Single }
    finally { Remove-Item Env:APEX_ENGINE_TEST_FAIL_INDEX_IDENTITY -ErrorAction SilentlyContinue }
    Assert-Test 'git index identity failure parks Engine with the failed operation diagnosis' `
        ($identityFailureCase.result.code -ne 0 -and $identityFailureCase.state.status -ceq 'parked' -and
            $identityFailureCase.state.diagnosis -match '^verify gate exit 1: git index identity read before pin failed:' -and
            $identityFailureCase.state.diagnosis -match 'git ls-files' -and
            @($identityFailureCase.state.tasks[0].attempts).Count -eq 1) $identityFailureCase.result.output

    $env:APEX_ENGINE_TEST_FAIL_WRITE_TREE = '1'
    try { $commitIntentFailureCase = Invoke-TestScenario -Name 'commit-intent-capture-failure' -Scenario 'done' -Single }
    finally { Remove-Item Env:APEX_ENGINE_TEST_FAIL_WRITE_TREE -ErrorAction SilentlyContinue }
    $commitIntentFailureHead = (Invoke-TestGit ([string]$commitIntentFailureCase.state.integration.worktree) @('rev-parse', 'HEAD'))[-1]
    $commitIntentFailureRuntime = $commitIntentFailureCase.state.wave_runtime.'1'
    Assert-Test 'commit-intent capture failure parks' `
        ($commitIntentFailureCase.result.code -ne 0 -and $commitIntentFailureCase.state.status -ceq 'parked' -and
            $commitIntentFailureCase.state.diagnosis -ceq 'integration commit-intent capture failed for wave 1: git write-tree failed (test seam)' -and
            $commitIntentFailureCase.state.integration.tip -ceq $commitIntentFailureCase.state.base_sha -and
            $commitIntentFailureHead -ceq [string]$commitIntentFailureCase.state.integration.tip -and
            -not $commitIntentFailureRuntime.PSObject.Properties['commit_intent']) `
        $commitIntentFailureCase.result.output

    $env:APEX_ENGINE_TEST_FAIL_RESIDUE_CAPTURE = '1'
    try { $residueCaptureFailureCase = Invoke-TestScenario -Name 'residue-capture-failure' -Scenario 'done' -Single }
    finally { Remove-Item Env:APEX_ENGINE_TEST_FAIL_RESIDUE_CAPTURE -ErrorAction SilentlyContinue }
    $residueCaptureFailureHead = (Invoke-TestGit ([string]$residueCaptureFailureCase.state.integration.worktree) @('rev-parse', 'HEAD'))[-1]
    $residueCaptureHasIntent = $false
    if ($residueCaptureFailureCase.state.PSObject.Properties['wave_runtime'] -and
            $residueCaptureFailureCase.state.wave_runtime.PSObject.Properties['1']) {
        $residueCaptureHasIntent = $null -ne $residueCaptureFailureCase.state.wave_runtime.'1'.PSObject.Properties['commit_intent']
    }
    Assert-Test 'residue capture failure parks' `
        ($residueCaptureFailureCase.result.code -ne 0 -and $residueCaptureFailureCase.state.status -ceq 'parked' -and
            $residueCaptureFailureCase.state.diagnosis -ceq 'residue inventory capture failed for wave 1: residue inventory capture failed (test seam)' -and
            $residueCaptureFailureCase.state.integration.tip -ceq $residueCaptureFailureCase.state.base_sha -and
            $residueCaptureFailureHead -ceq [string]$residueCaptureFailureCase.state.integration.tip -and
            -not $residueCaptureHasIntent) `
        $residueCaptureFailureCase.result.output

    $concernsCase = Invoke-TestScenario -Name 'concerns-route' -Scenario 'concerns' -Single
    Assert-Test 'real wrapper final done_with_concerns integrates and records concern' `
        ($concernsCase.result.code -eq 0 -and $concernsCase.state.status -ceq 'complete' -and $concernsCase.state.counters.concerns -eq 1) `
        $concernsCase.result.output

    $blockedCase = Invoke-TestScenario -Name 'blocked-route' -Scenario 'blocked' -Single
    Assert-Test 'real wrapper blocked outcome parks without process retry' `
        ($blockedCase.result.code -ne 0 -and $blockedCase.state.status -ceq 'parked' -and
            @($blockedCase.state.tasks[0].attempts).Count -eq 1 -and $blockedCase.state.tasks[0].attempts[0].exit_code -eq 67) `
        $blockedCase.result.output

    $quotaCase = Invoke-TestScenario -Name 'rate-limit-429-route' -Scenario 'rate_limit_429' -Single
    Assert-Test 'real wrapper rate_limit_429 pauses on captured Codex JSONL without redispatch' `
        ($quotaCase.result.code -ne 0 -and $quotaCase.state.status -ceq 'paused' -and
            @($quotaCase.state.tasks[0].attempts).Count -eq 1) $quotaCase.result.output

    $usageLimitCase = Invoke-TestScenario -Name 'usage-limit-jsonl-route' -Scenario 'usage_limit_jsonl' -Single
    Assert-Test 'real wrapper usage-limit JSONL sample pauses and parks after exactly one attempt' `
        ($usageLimitCase.result.code -ne 0 -and $usageLimitCase.state.status -ceq 'paused' -and
            $usageLimitCase.state.diagnosis -ceq 'quota or rate limit' -and
            $usageLimitCase.state.tasks[0].status -ceq 'parked' -and
            $usageLimitCase.state.tasks[0].diagnosis -ceq 'quota or rate limit' -and
            @($usageLimitCase.state.tasks[0].attempts).Count -eq 1) $usageLimitCase.result.output

    $agentMessageCase = Invoke-TestScenario -Name 'agent-message-route' -Scenario 'agent_message_quota_quote' -Single
    Assert-Test 'real wrapper does not treat agent_message usage-limit quotation as quota' `
        ($agentMessageCase.result.code -ne 0 -and $agentMessageCase.state.status -ceq 'parked' -and
            $agentMessageCase.state.diagnosis -ceq 'process failure retry exhausted' -and
            @($agentMessageCase.state.tasks[0].attempts).Count -eq 2) $agentMessageCase.result.output

    $mentionCase = Invoke-TestScenario -Name 'mention-route' -Scenario 'final_mentions_rate_limiter' -Single
    Assert-Test 'real wrapper final body rate-limiter mention remains ordinary completion' `
        ($mentionCase.result.code -eq 0 -and $mentionCase.state.status -ceq 'complete') $mentionCase.result.output

    $processCase = Invoke-TestScenario -Name 'process-route' -Scenario 'process_failure' -Single
    Assert-Test 'real wrapper process failure makes one same-effort redispatch then parks' `
        ($processCase.result.code -ne 0 -and $processCase.state.status -ceq 'parked' -and
            @($processCase.state.tasks[0].attempts).Count -eq 2 -and
            @($processCase.state.tasks[0].attempts | Where-Object { $_.effort -ceq 'medium' }).Count -eq 2) `
        $processCase.result.output
    $env:ENGINE_TEST_FAKE_SCENARIO = 'done'
    $processResume = Invoke-TestEngine @('-Resume', $processCase.state.run_id, '-StateRoot', $processCase.state_root)
    Remove-Item Env:ENGINE_TEST_FAKE_SCENARIO -ErrorAction SilentlyContinue
    $processAfter = Get-TestOnlyState $processCase.state_root
    Assert-Test 'resume restarts parked process task at last attempt effort' `
        ($processResume.code -eq 0 -and $processAfter.status -ceq 'complete' -and
            @($processAfter.tasks[0].attempts).Count -eq 3 -and $processAfter.tasks[0].attempts[2].effort -ceq 'medium') `
        $processResume.output

    foreach ($baselineExit in @(3, 4, 9)) {
        $env:ENGINE_TEST_BASELINE_EXIT = [string]$baselineExit
        $baselineCase = Invoke-TestScenario -Name "baseline-$baselineExit" -Scenario 'done' -Single -BaselinePath $gateBaseline
        Assert-Test "baseline exit $baselineExit parks with exact code and never enters RED retry" `
            ($baselineCase.result.code -ne 0 -and $baselineCase.state.status -ceq 'parked' -and
                @($baselineCase.state.tasks[0].attempts).Count -eq 1 -and
                $baselineCase.state.diagnosis -match "baseline gate exit $baselineExit") `
            $baselineCase.result.output
    }
    Remove-Item Env:ENGINE_TEST_BASELINE_EXIT -ErrorAction SilentlyContinue

    $stageAwarePin = Join-Path $testRoot 'stage-aware-tree-pin.ps1'
    Write-TestText $stageAwarePin @'
param([switch]$Pin, [switch]$Verify, [switch]$Digest, [string]$Worktree, [string]$Label, [string]$PinDirectory)
if ($Digest) { & $env:ENGINE_TEST_REAL_TREE_PIN -Digest -Worktree $Worktree; exit $LASTEXITCODE }
if ($Pin) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git -C $Worktree diff --cached --quiet; $clean = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
    if ($clean -eq 0) { Write-Host 'index was not staged before pin'; exit 31 }
    [IO.File]::WriteAllText($env:ENGINE_TEST_STAGE_MARKER, 'staged')
    if ($env:ENGINE_TEST_STAGE_PIN_COUNT) {
        $count = if (Test-Path $env:ENGINE_TEST_STAGE_PIN_COUNT) { [int](Get-Content $env:ENGINE_TEST_STAGE_PIN_COUNT -Raw) } else { 0 }
        [IO.File]::WriteAllText($env:ENGINE_TEST_STAGE_PIN_COUNT, [string]($count + 1))
    }
    if ($env:ENGINE_TEST_STAGE_PIN_EXIT) { Write-Host 'stage-aware pin infrastructure failure'; exit ([int]$env:ENGINE_TEST_STAGE_PIN_EXIT) }
}
if ($Verify -and $env:ENGINE_TEST_STAGE_VERIFY_COUNT) {
    $count = if (Test-Path $env:ENGINE_TEST_STAGE_VERIFY_COUNT) { [int](Get-Content $env:ENGINE_TEST_STAGE_VERIFY_COUNT -Raw) } else { 0 }
    $count++; [IO.File]::WriteAllText($env:ENGINE_TEST_STAGE_VERIFY_COUNT, [string]$count)
    $sequence = @($env:ENGINE_TEST_STAGE_VERIFY_SEQUENCE -split ',')
    if ($count -le $sequence.Count -and $sequence[$count - 1] -match '^\d+$' -and [int]$sequence[$count - 1] -ne 0) {
        Write-Host "stage-aware verify failure $($sequence[$count - 1])"; exit ([int]$sequence[$count - 1])
    }
}
if ($Pin) { & $env:ENGINE_TEST_REAL_TREE_PIN -Pin -Worktree $Worktree -Label $Label -PinDirectory $PinDirectory; exit $LASTEXITCODE }
if ($Verify) { & $env:ENGINE_TEST_REAL_TREE_PIN -Verify -Worktree $Worktree -Label $Label -PinDirectory $PinDirectory; exit $LASTEXITCODE }
Write-Host 'stage-aware pin ok'; exit 0
'@
    $env:ENGINE_TEST_REAL_TREE_PIN = Join-Path $PSScriptRoot 'tree-pin.ps1'
    $env:ENGINE_TEST_STAGE_MARKER = Join-Path $testRoot 'stage-before-pin.marker'
    $stagedCase = Invoke-TestScenario -Name 'staged-pin' -Scenario 'done' -Single -TreePinPath $stageAwarePin
    Assert-Test 'Stage-EngineWave runs before pin and verified index is committed' `
        ($stagedCase.result.code -eq 0 -and $stagedCase.state.status -ceq 'complete' -and
            (Test-Path -LiteralPath $env:ENGINE_TEST_STAGE_MARKER)) $stagedCase.result.output

    $env:ENGINE_TEST_STAGE_MARKER = Join-Path $testRoot 'pin-infra.marker'
    $env:ENGINE_TEST_STAGE_PIN_EXIT = '23'
    $pinInfraCase = Invoke-TestScenario -Name 'pin-infra' -Scenario 'done' -Single -TreePinPath $stageAwarePin
    Remove-Item Env:ENGINE_TEST_STAGE_PIN_EXIT -ErrorAction SilentlyContinue
    Assert-Test 'runner parks tree-pin infrastructure exit 23 with pin diagnosis, never RED retry' `
        ($pinInfraCase.result.code -ne 0 -and $pinInfraCase.state.status -ceq 'parked' -and
            @($pinInfraCase.state.tasks[0].attempts).Count -eq 1 -and $pinInfraCase.state.diagnosis -match 'pin gate exit 23') `
        $pinInfraCase.result.output

    $env:ENGINE_TEST_STAGE_MARKER = Join-Path $testRoot 'verify-other.marker'
    $env:ENGINE_TEST_STAGE_VERIFY_COUNT = Join-Path $testRoot 'verify-other.count'
    $env:ENGINE_TEST_STAGE_VERIFY_SEQUENCE = '24'
    $verifyInfraCase = Invoke-TestScenario -Name 'verify-infra' -Scenario 'done' -Single -TreePinPath $stageAwarePin
    Assert-Test 'runner parks non-moved tree verify failure with its exact code' `
        ($verifyInfraCase.result.code -ne 0 -and $verifyInfraCase.state.status -ceq 'parked' -and
            @($verifyInfraCase.state.tasks[0].attempts).Count -eq 1 -and $verifyInfraCase.state.diagnosis -match 'verify gate exit 24') `
        $verifyInfraCase.result.output

    $env:ENGINE_TEST_STAGE_MARKER = Join-Path $testRoot 'repin-live.marker'
    $env:ENGINE_TEST_STAGE_PIN_COUNT = Join-Path $testRoot 'repin-live-pin.count'
    $env:ENGINE_TEST_STAGE_VERIFY_COUNT = Join-Path $testRoot 'repin-live-verify.count'
    $env:ENGINE_TEST_STAGE_VERIFY_SEQUENCE = '69,0'
    $repinLiveCase = Invoke-TestScenario -Name 'repin-live' -Scenario 'done' -Single -TreePinPath $stageAwarePin
    $repinLiveHead = (Invoke-TestGit ([string]$repinLiveCase.state.integration.worktree) @('rev-parse', 'HEAD'))[-1]
    Assert-Test 'runner parks first verify 69 after one pin baseline verify and zero integration commits' `
        ($repinLiveCase.result.code -ne 0 -and $repinLiveCase.state.status -ceq 'parked' -and
            (Get-Content $env:ENGINE_TEST_STAGE_PIN_COUNT -Raw) -eq '1' -and
            (Get-Content $env:ENGINE_TEST_STAGE_VERIFY_COUNT -Raw) -eq '1' -and
            $repinLiveHead -ceq [string]$repinLiveCase.state.integration.tip) $repinLiveCase.result.output

    $env:ENGINE_TEST_STAGE_MARKER = Join-Path $testRoot 'repin-exhaust.marker'
    $env:ENGINE_TEST_STAGE_PIN_COUNT = Join-Path $testRoot 'repin-exhaust-pin.count'
    $env:ENGINE_TEST_STAGE_VERIFY_COUNT = Join-Path $testRoot 'repin-exhaust-verify.count'
    $env:ENGINE_TEST_STAGE_VERIFY_SEQUENCE = '69,69'
    $repinExhaustCase = Invoke-TestScenario -Name 'repin-exhaust' -Scenario 'done' -Single -TreePinPath $stageAwarePin
    $repinExhaustHead = (Invoke-TestGit ([string]$repinExhaustCase.state.integration.worktree) @('rev-parse', 'HEAD'))[-1]
    Assert-Test 'runner second verify mutation case also parks after one pass with zero integration commits' `
        ($repinExhaustCase.result.code -ne 0 -and $repinExhaustCase.state.status -ceq 'parked' -and
            (Get-Content $env:ENGINE_TEST_STAGE_PIN_COUNT -Raw) -eq '1' -and
            (Get-Content $env:ENGINE_TEST_STAGE_VERIFY_COUNT -Raw) -eq '1' -and
            $repinExhaustHead -ceq [string]$repinExhaustCase.state.integration.tip) $repinExhaustCase.result.output

    $mutationBaseline = Join-Path $testRoot 'mutation-baseline.ps1'
    Write-TestText $mutationBaseline @'
param([switch]$Full, [string]$Worktree)
$path = Join-Path $Worktree 'src\a.py'
switch -CaseSensitive ($env:ENGINE_TEST_GATE_MUTATION) {
    'working' { [IO.File]::AppendAllText($path, "working mutation`n") }
    'index' {
        [IO.File]::WriteAllText((Join-Path $Worktree 'off-manifest.txt'), "index mutation`n")
        & git -C $Worktree add -f -- off-manifest.txt
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}
Write-Host 'mutation baseline complete'
exit 0
'@
    $mutationCases = @{}
    foreach ($mutationKind in @('working', 'index')) {
        $env:ENGINE_TEST_GATE_MUTATION = $mutationKind
        Remove-Item Env:ENGINE_TEST_STAGE_VERIFY_SEQUENCE, Env:ENGINE_TEST_STAGE_PIN_COUNT, Env:ENGINE_TEST_STAGE_VERIFY_COUNT -ErrorAction SilentlyContinue
        $mutationCases[$mutationKind] = Invoke-TestScenario -Name "verify-$mutationKind-mutation" -Scenario 'done' -Single `
            -TreePinPath $stageAwarePin -BaselinePath $mutationBaseline
    }
    Remove-Item Env:ENGINE_TEST_GATE_MUTATION -ErrorAction SilentlyContinue
    $workingMutationHead = (Invoke-TestGit ([string]$mutationCases['working'].state.integration.worktree) @('rev-parse', 'HEAD'))[-1]
    $indexMutationHead = (Invoke-TestGit ([string]$mutationCases['index'].state.integration.worktree) @('rev-parse', 'HEAD'))[-1]
    Assert-Test 'verify working-copy and index mutations park without changing integration.tip' `
        ($mutationCases['working'].state.diagnosis -match '^verify gate exit 69: integration verify changed the working tree:' -and
            $workingMutationHead -ceq [string]$mutationCases['working'].state.integration.tip -and
            $mutationCases['index'].state.diagnosis -ceq 'verify gate exit 69: integration verify changed the index' -and
            $indexMutationHead -ceq [string]$mutationCases['index'].state.integration.tip) `
        "working=$($mutationCases['working'].state.diagnosis); index=$($mutationCases['index'].state.diagnosis)"
    $headGateRepo = New-TestRepo 'head-gate-unit-repo'
    $headGateTip = (Invoke-TestGit $headGateRepo @('rev-parse', 'HEAD'))[-1]
    $script:EngineState.repo = $headGateRepo
    $script:EngineState.integration = [pscustomobject]@{ worktree = $headGateRepo; tip = $headGateTip }
    $script:EngineState.run_id = '44444444444444444444444444444444'
    $script:EngineState | Add-Member -MemberType NoteProperty -Name wave_runtime `
        -Value ([pscustomobject]@{ '1' = [pscustomobject]@{ residue_inventory = @() } }) -Force
    $originalInvokeRunnerScript = ${function:Invoke-RunnerScript}
    function Invoke-RunnerScript {
        param([string]$Path, [string[]]$Arguments)
        if ($Path -ceq $script:EngineBaselineScript) {
            Write-TestText (Join-Path $script:EngineState.integration.worktree 'src\a.py') "verify committed mutation`n"
            $parent = (Invoke-TestGit ([string]$script:EngineState.integration.worktree) @('rev-parse', 'HEAD'))[-1]
            [void](Set-TestCommit ([string]$script:EngineState.integration.worktree) @('src/a.py') $parent)
            return [pscustomobject]@{ exit_code = 0; output = 'baseline committed mutation' }
        }
        return [pscustomobject]@{ exit_code = 0; output = 'pin fixture ok' }
    }
    try { $headGate = Invoke-RunnerGate @() 1 }
    finally { Set-Item -LiteralPath Function:Invoke-RunnerScript -Value $originalInvokeRunnerScript }
    Assert-Test 'verify HEAD commit mutation parks without changing integration.tip' `
        ($headGate.gate -ceq 'verify' -and $headGate.diagnosis -ceq 'integration verify moved HEAD' -and
            $script:EngineState.integration.tip -ceq $headGateTip) ($headGate | ConvertTo-Json -Compress)

    $noIntentIntegration = [string]$mutationCases['working'].state.integration.worktree
    $noIntentParent = (Invoke-TestGit $noIntentIntegration @('rev-parse', 'HEAD'))[-1]
    [void](Set-TestCommit $noIntentIntegration @('src/a.py') $noIntentParent)
    $noIntentResume = Invoke-TestEngine @('-Resume', $mutationCases['working'].state.run_id, '-StateRoot', $mutationCases['working'].state_root)
    $noIntentAfter = Get-TestOnlyState $mutationCases['working'].state_root
    Assert-Test 'verify-created HEAD commit parks and is not adopted without commit intent' `
        ($noIntentResume.code -ne 0 -and $noIntentAfter.diagnosis -ceq 'integration branch tip mismatch' -and
            @($noIntentAfter.transitions | Where-Object { $_.kind -ceq 'wave-commit-adopted' }).Count -eq 0) `
        $noIntentResume.output

    $residueIntegration = [string]$repinExhaustCase.state.integration.worktree
    $residueInventoryBefore = [string[]]@($repinExhaustCase.state.wave_runtime.'1'.residue_inventory)
    Write-TestText (Join-Path $residueIntegration 'residue-untracked.txt') "untracked residue`n"
    Write-TestText (Join-Path $residueIntegration 'residue-ignored.tmp') "ignored residue`n"
    $env:APEX_ENGINE_TEST_TREE_PIN_PATH = $stageAwarePin
    $env:APEX_ENGINE_TEST_BASELINE_PATH = $gateBaseline
    $env:ENGINE_TEST_BASELINE_EXIT = '0'
    Remove-Item Env:ENGINE_TEST_STAGE_VERIFY_SEQUENCE, Env:ENGINE_TEST_STAGE_PIN_COUNT, Env:ENGINE_TEST_STAGE_VERIFY_COUNT -ErrorAction SilentlyContinue
    $residueResumePark = Invoke-TestEngine @('-Resume', $repinExhaustCase.state.run_id, '-StateRoot', $repinExhaustCase.state_root)
    $residueParked = Get-TestOnlyState $repinExhaustCase.state_root
    $residueParkedHead = (Invoke-TestGit $residueIntegration @('rev-parse', 'HEAD'))[-1]
    Remove-Item -LiteralPath (Join-Path $residueIntegration 'residue-untracked.txt'), (Join-Path $residueIntegration 'residue-ignored.tmp') -Force
    $residueResumeDone = Invoke-TestEngine @('-Resume', $repinExhaustCase.state.run_id, '-StateRoot', $repinExhaustCase.state_root)
    $residueDone = Get-TestOnlyState $repinExhaustCase.state_root
    $residueInventoryAfter = [string[]]@($residueDone.wave_runtime.'1'.residue_inventory)
    Assert-Test 'residue inventory' `
        ($residueResumePark.code -ne 0 -and
            $residueParked.diagnosis -match 'integration tree has untracked/ignored residue outside wave manifest:.*residue-ignored.tmp.*residue-untracked.txt' -and
            $residueParkedHead -ceq [string]$residueParked.integration.tip -and
            ($residueInventoryBefore -join "`n") -ceq ($residueInventoryAfter -join "`n") -and
            $residueResumeDone.code -eq 0 -and $residueDone.status -ceq 'complete') `
        "park=$($residueResumePark.output); done=$($residueResumeDone.output)"

    # Task 2: real-script reachability. Invoke-TestScenario clears both script overrides.
    $declaredPath = 'src/widget/bin/generated.dat'
    $undeclaredPath = 'scratch/generated.dat'
    $realDeclared = Invoke-TestScenario -Name 'build-output-real-declared' -Single -BuildOutput declared
    $realDeclaredState = Get-TestOnlyState $realDeclared.state_root
    $realPins = @(Get-ChildItem -LiteralPath $realDeclared.state_root -Filter 'apex-treepin-engine-*-wave-1-*.txt' -Recurse -File)
    $realDeclaredStatus = Invoke-TestGit ([string]$realDeclaredState.integration.worktree) @('status', '--porcelain', '-uall', '--ignored')
    Assert-Test 'build outputs real tree-pin and baseline declared ignored output completes/0' `
        ($realDeclared.result.code -eq 0 -and $realDeclaredState.status -ceq 'complete' -and @($realPins).Count -eq 1 -and
            ($realDeclaredStatus -join "`n") -match ('(?m)^!! ' + [regex]::Escape($declaredPath) + '$') -and
            [IO.File]::ReadAllText((Join-Path $realDeclaredState.integration.worktree 'src/a.py')) -match 'fake-one' -and
            @($realDeclaredState.wave_runtime.'1'.residue_inventory).Count -eq 0) $realDeclared.result.output
    $realUndeclared = Invoke-TestScenario -Name 'build-output-real-undeclared' -Single -BuildOutput undeclared
    Assert-TestBuildOutputPark 'build outputs real scripts undeclared output parks/1 with cause and path before commit' `
        $realUndeclared $undeclaredPath '(changed the working tree|unexpected residue)'
    $realUndeclaredPins = @(Get-ChildItem -LiteralPath $realUndeclared.state_root -Filter 'apex-treepin-engine-*-wave-1-*.txt' -Recurse -File)
    Assert-Test 'build outputs real undeclared case reached integration pin and committed verify fence' `
        (@($realUndeclaredPins).Count -eq 1 -and
            (Test-Path -LiteralPath (Join-Path $realUndeclared.state.integration.worktree $undeclaredPath))) $realUndeclared.result.output

    # Bypass only tree-pin for classification: retain real stage, baseline, index identity and residue scan.
    $buildOutputPin = Join-Path $testRoot 'build-output-tree-pin.ps1'
    $buildOutputPinText = @'
param([switch]$Pin, [switch]$Verify, [switch]$Digest, [string]$Worktree, [string]$Label, [string]$PinDirectory)
if ($Digest) { & '__REAL_TREE_PIN__' -Digest -Worktree $Worktree; exit $LASTEXITCODE }
Write-Host 'build-output classification pin stub'
exit 0
'@
    # Task build digests must still match the real wrapper; stub only integration Pin/Verify.
    Write-TestText $buildOutputPin ($buildOutputPinText.Replace('__REAL_TREE_PIN__',
        (Join-Path (Split-Path -Parent $engine) 'tree-pin.ps1').Replace("'", "''")))
    $singleFetchTrace = Join-Path $testRoot 'build-output-single-fetch.txt'
    $declaredControl = Invoke-TestScenario -Name 'build-output-residue-declared-control' -Single -BuildOutput declared `
        -TreePinPath $buildOutputPin -AgentsFetchTrace $singleFetchTrace
    $singleFetches = @(Get-Content -LiteralPath $singleFetchTrace)
    $controlState = Get-TestOnlyState $declaredControl.state_root
    $controlStatus = Invoke-TestGit ([string]$controlState.integration.worktree) @('status', '--porcelain', '-uall', '--ignored')
    Assert-Test 'build outputs residue declared exemption and one fetch across inventory and scan' `
        ($declaredControl.result.code -eq 0 -and $controlState.status -ceq 'complete' -and
            @($controlState.wave_runtime.'1'.residue_inventory).Count -eq 0 -and
            ($controlStatus -join "`n") -match ('(?m)^!! ' + [regex]::Escape($declaredPath) + '$') -and
            @($singleFetches).Count -eq 1 -and $singleFetches[0] -ceq $controlState.base_sha -and
            $declaredControl.result.output -notmatch '\[engine\] WARNING:') $declaredControl.result.output
    foreach ($kind in @('undeclared', 'working-only', 'unignored')) {
        $classification = Invoke-TestScenario -Name "build-output-residue-$kind" -Single -BuildOutput $kind -TreePinPath $buildOutputPin
        $badPath = if ($kind -ceq 'unignored') { 'src/widget/bin/untracked.txt' } else { $undeclaredPath }
        Assert-TestBuildOutputPark "build outputs residue $kind parks/1 with path and no integration commit" $classification $badPath
        if ($kind -ceq 'working-only') {
            $committedAgents = Invoke-TestGit ([string]$classification.state.integration.worktree) @('show', 'HEAD:AGENTS.md')
            Assert-Test 'build outputs working-tree-only declaration is absent from integration HEAD' `
                (($committedAgents -join "`n") -notmatch '(?m)^scratch$' -and
                    [IO.File]::ReadAllText((Join-Path $classification.state.integration.worktree 'AGENTS.md')) -match '(?m)^scratch\r?$') `
                $classification.result.output
        }
        if ($kind -ceq 'unignored') {
            $unignoredStatus = Invoke-TestGit ([string]$classification.state.integration.worktree) @('status', '--porcelain', '-uall', '--ignored')
            Assert-Test 'build outputs unignored file under declared prefix retains question-mark status' `
                (($unignoredStatus -join "`n") -match ('(?m)^\?\? ' + [regex]::Escape($badPath) + '$')) ($unignoredStatus -join "`n")
        }
    }

    foreach ($fetchFailure in @('ls-tree', 'show')) {
        $failureTrace = Join-Path $testRoot "build-output-$fetchFailure-fetch.txt"
        # Same committed declaration and path as the successful control: ONLY the fetch fails.
        $fetchCase = Invoke-TestScenario -Name "build-output-fetch-failure-$fetchFailure" -Single -BuildOutput declared `
            -TreePinPath $buildOutputPin -AgentsFetchFailure $fetchFailure -AgentsFetchTrace $failureTrace
        Assert-TestBuildOutputPark "build outputs $fetchFailure fetch failure disables declared exemption and parks/1" $fetchCase $declaredPath
        $failedFetches = @(Get-Content -LiteralPath $failureTrace)
        $warnings = @($fetchCase.result.output -split "`r?`n" | Where-Object { $_ -match '^\[engine\] WARNING: .*build-output declarations unavailable' })
        $failedAgents = Invoke-TestGit ([string]$fetchCase.state.integration.worktree) @('show', 'HEAD:AGENTS.md')
        $failedTree = Invoke-TestGit ([string]$fetchCase.state.integration.worktree) @('ls-tree', '-r', '--name-only', 'HEAD')
        $selectedOperation = if ($fetchFailure -ceq 'show') { 'show HEAD:AGENTS.md' } else { 'ls-tree AGENTS.md' }
        Assert-Test "build outputs $fetchFailure warns once per HEAD SHA and leaves other Git operations intact" `
            (@($failedFetches).Count -eq 1 -and $failedFetches[0] -ceq $fetchCase.state.base_sha -and
                @($warnings).Count -eq @($failedFetches | Select-Object -Unique).Count -and
                $warnings[0] -match [regex]::Escape("git $selectedOperation failed (test seam)") -and
                ($failedAgents -join "`n") -match '(?m)^src/\*/bin$' -and $failedTree -ccontains 'src/a.py' -and
                [IO.File]::ReadAllText((Join-Path $fetchCase.state.integration.worktree 'src/a.py')) -match 'fake-one') $fetchCase.result.output
    }

    $twoWaveTrace = Join-Path $testRoot 'build-output-two-wave-fetch.txt'
    $twoWaveOutputs = Invoke-TestScenario -Name 'build-output-cache-head-change' -TwoWave -BuildOutput declared `
        -TreePinPath $buildOutputPin -AgentsFetchTrace $twoWaveTrace
    $twoWaveFetches = @(Get-Content -LiteralPath $twoWaveTrace)
    $firstWaveCommit = (Invoke-TestGit ([string]$twoWaveOutputs.state.integration.worktree) @('rev-parse', "$($twoWaveOutputs.state.integration.tip)^"))[-1]
    Assert-Test 'build outputs declaration cache fetches once per integration HEAD and again after wave commit' `
        ($twoWaveOutputs.result.code -eq 0 -and $twoWaveOutputs.state.status -ceq 'complete' -and
            @($twoWaveFetches).Count -eq 2 -and $twoWaveFetches[0] -ceq $twoWaveOutputs.state.base_sha -and
            $twoWaveFetches[1] -ceq $firstWaveCommit -and $twoWaveFetches[0] -cne $twoWaveFetches[1] -and
            @($twoWaveOutputs.state.wave_runtime.'1'.residue_inventory).Count -eq 0 -and
            @($twoWaveOutputs.state.wave_runtime.'2'.residue_inventory).Count -eq 0) ($twoWaveFetches -join ', ')

    $authorizedIgnored = Invoke-TestScenario -Name 'build-output-manifest-ignored' -Scenario authorized-ignored -Single `
        -BuildOutput declared -IgnoredFile -TreePinPath $buildOutputPin
    $authorizedState = Get-TestOnlyState $authorizedIgnored.state_root
    $authorizedPath = 'src/widget/bin/payload.dat'
    $authorizedTaskPath = Join-Path $authorizedState.tasks[0].attempts[0].worktree $authorizedPath
    $authorizedIntegrationPath = Join-Path $authorizedState.integration.worktree $authorizedPath
    $authorizedTree = Invoke-TestGit ([string]$authorizedState.integration.worktree) @('ls-tree', '-r', '--name-only', $authorizedState.integration.tip)
    $authorizedBlob = Invoke-RunnerGitBytes ([string]$authorizedState.integration.worktree) "show $($authorizedState.integration.tip):$authorizedPath"
    $expectedBytes = [Convert]::ToBase64String([byte[]]@(0,255,13,10,128,65,0))
    $offManifestStatus = Invoke-TestGit ([string]$authorizedState.integration.worktree) @('status', '--porcelain', '-uall', '--ignored')
    Assert-Test 'build outputs manifest ignored file copies exact bytes and stages only authorized path' `
        ($authorizedIgnored.result.code -eq 0 -and $authorizedState.status -ceq 'complete' -and
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($authorizedTaskPath)) -ceq $expectedBytes -and
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($authorizedIntegrationPath)) -ceq $expectedBytes -and
            [Convert]::ToBase64String([byte[]]$authorizedBlob) -ceq $expectedBytes -and
            (Test-Path -LiteralPath (Join-Path $authorizedState.tasks[0].attempts[0].worktree $declaredPath)) -and
            $authorizedTree -ccontains $authorizedPath -and $authorizedTree -cnotcontains $declaredPath -and
            ($offManifestStatus -join "`n") -match ('(?m)^!! ' + [regex]::Escape($declaredPath) + '$')) $authorizedIgnored.result.output

    $offManifestIntegration = [string]$repinLiveCase.state.integration.worktree
    Write-TestText (Join-Path $offManifestIntegration 'off-manifest.txt') "staged outside manifest`n"
    [void](Invoke-TestGit $offManifestIntegration @('add', '-f', '--', 'off-manifest.txt'))
    $offManifestResume = Invoke-TestEngine @('-Resume', $repinLiveCase.state.run_id, '-StateRoot', $repinLiveCase.state_root)
    $offManifestAfter = Get-TestOnlyState $repinLiveCase.state_root
    $offManifestHead = (Invoke-TestGit $offManifestIntegration @('rev-parse', 'HEAD'))[-1]
    Assert-Test 'off-manifest git add on Resume is refused before integration commit' `
        ($offManifestResume.code -ne 0 -and
            $offManifestAfter.diagnosis -match 'integration index contains paths outside wave manifest: off-manifest.txt' -and
            $offManifestHead -ceq [string]$offManifestAfter.integration.tip) $offManifestResume.output
    $mainIntent = $state.wave_runtime.'1'.commit_intent
    $mainCommitTree = (Invoke-TestGit ([string]$state.integration.worktree) @('rev-parse', "$($state.integration.tip)^{tree}"))[-1]
    $mainCommitBase = (Invoke-TestGit ([string]$state.integration.worktree) @('rev-parse', "$($state.integration.tip)^"))[-1]
    Assert-Test 'commit intent and exact allowlist' `
        ($mainIntent.base -ceq $mainCommitBase -and $mainIntent.expected_tree -ceq $mainCommitTree -and
            $offManifestResume.code -ne 0 -and $offManifestAfter.diagnosis -match 'integration index contains paths outside wave manifest') `
        "intent=$($mainIntent | ConvertTo-Json -Compress); refusal=$($offManifestAfter.diagnosis)"
    Remove-Item Env:APEX_ENGINE_TEST_TREE_PIN_PATH, Env:APEX_ENGINE_TEST_BASELINE_PATH, Env:ENGINE_TEST_BASELINE_EXIT -ErrorAction SilentlyContinue
    Remove-Item Env:ENGINE_TEST_REAL_TREE_PIN, Env:ENGINE_TEST_STAGE_MARKER -ErrorAction SilentlyContinue
    Remove-Item Env:ENGINE_TEST_STAGE_PIN_COUNT, Env:ENGINE_TEST_STAGE_VERIFY_COUNT, Env:ENGINE_TEST_STAGE_VERIFY_SEQUENCE -ErrorAction SilentlyContinue

    $env:APEX_ENGINE_TEST_CRASH_AFTER_VERIFICATION_FAILURE = 'high'
    $ladderCrashCase = Invoke-TestScenario -Name 'ladder-crash-next-rung' -Scenario 'always_verify_fail' -Single -Effort low
    Remove-Item Env:APEX_ENGINE_TEST_CRASH_AFTER_VERIFICATION_FAILURE -ErrorAction SilentlyContinue
    $ladderCrashBefore = $ladderCrashCase.state
    $env:ENGINE_TEST_FAKE_SCENARIO = 'done'
    $ladderCrashResume = Invoke-TestEngine @('-Resume', $ladderCrashBefore.run_id, '-StateRoot', $ladderCrashCase.state_root)
    Remove-Item Env:ENGINE_TEST_FAKE_SCENARIO -ErrorAction SilentlyContinue
    $ladderCrashAfter = Get-TestOnlyState $ladderCrashCase.state_root
    Assert-Test 'low-to-xhigh crash-window ladder' `
        ($ladderCrashCase.result.code -ne 0 -and @($ladderCrashBefore.tasks[0].attempts).Count -eq 3 -and
            (@($ladderCrashBefore.tasks[0].attempts | ForEach-Object { [string]$_.effort }) -join ',') -ceq 'low,medium,high' -and
            $ladderCrashBefore.tasks[0].attempts[2].status -ceq 'failed' -and
            $ladderCrashBefore.tasks[0].attempts[2].diagnosis -ceq 'verification failure' -and
            $ladderCrashResume.code -eq 0 -and $ladderCrashAfter.status -ceq 'complete' -and
            (@($ladderCrashAfter.tasks[0].attempts | ForEach-Object { [string]$_.effort }) -join ',') -ceq 'low,medium,high,xhigh') `
        "before=$($ladderCrashCase.result.output); resume=$($ladderCrashResume.output)"

    $ladderCase = Invoke-TestScenario -Name 'ladder-low' -Scenario 'always_verify_fail' -Single -Effort low
    $ladderEfforts = @($ladderCase.state.tasks[0].attempts | ForEach-Object { [string]$_.effort })
    Assert-Test 'verify failure climbs low to medium to high to xhigh then exhausts' `
        ($ladderCase.state.status -ceq 'partial' -and ($ladderEfforts -join ',') -ceq 'low,medium,high,xhigh' -and
            @($ladderCase.state.tasks[0].attempts | Where-Object { $_.model -cne 'gpt-5.6-sol' }).Count -eq 0 -and
            $ladderCase.state.tasks[0].diagnosis -ceq 'verification effort ladder exhausted') `
        ($ladderEfforts -join ',')
    $ladderResume = Invoke-TestEngine @('-Resume', $ladderCase.state.run_id, '-StateRoot', $ladderCase.state_root)
    $ladderAfter = Get-TestOnlyState $ladderCase.state_root
    Assert-Test 'ladder-exhausted task remains exhausted across resume without cycling' `
        ($ladderResume.code -ne 0 -and @($ladderAfter.tasks[0].attempts).Count -eq 4 -and
            $ladderAfter.tasks[0].diagnosis -ceq 'verification effort ladder exhausted') $ladderResume.output

    foreach ($terminalEffort in @('max', 'ultra')) {
        $terminalCase = Invoke-TestScenario -Name "ladder-$terminalEffort" -Scenario 'always_verify_fail' -Single -Effort $terminalEffort
        Assert-Test "$terminalEffort effort is terminal and exhausts without a new rung" `
            ($terminalCase.state.status -ceq 'partial' -and @($terminalCase.state.tasks[0].attempts).Count -eq 1 -and
                $terminalCase.state.tasks[0].attempts[0].effort -ceq $terminalEffort) $terminalCase.result.output
    }

    $isolationCase = Invoke-TestScenario -Name 'single-failure-isolation' -Scenario 'isolate12' -FirstId '1' -SecondId '12'
    $taskOne = @($isolationCase.state.tasks | Where-Object { $_.id -ceq '1' })[0]
    $taskTwelve = @($isolationCase.state.tasks | Where-Object { $_.id -ceq '12' })[0]
    Assert-Test 'exactly one isolated multi-digit task 12 is retried on the ladder, not task 1' `
        ($isolationCase.result.code -eq 0 -and @($taskOne.attempts).Count -eq 1 -and
            @($taskTwelve.attempts).Count -eq 2 -and ($taskTwelve.attempts.effort -join ',') -ceq 'medium,high') `
        $isolationCase.result.output

    foreach ($handoffPath in @('src/a.py', 'src/b.py')) {
        $caseName = if ($handoffPath -ceq 'src/a.py') { 'write-before-journal' } else { 'partial-journal' }
        $env:APEX_ENGINE_TEST_FAIL_BEFORE_HANDOFF_JOURNAL = $handoffPath
        $handoffCase = Invoke-TestScenario -Name $caseName -Scenario 'done'
        Remove-Item Env:APEX_ENGINE_TEST_FAIL_BEFORE_HANDOFF_JOURNAL -ErrorAction SilentlyContinue
        $beforeCount = @($handoffCase.state.handoff.journaled_paths).Count
        $handoffResume = Invoke-TestEngine @('-Resume', $handoffCase.state.run_id, '-StateRoot', $handoffCase.state_root)
        $handoffAfter = Get-TestOnlyState $handoffCase.state_root
        $expectedBefore = if ($handoffPath -ceq 'src/a.py') { 0 } else { 1 }
        Assert-Test "$caseName hand-off resume journals already-written identity and completes" `
            ($handoffCase.result.code -ne 0 -and $beforeCount -eq $expectedBefore -and $handoffResume.code -eq 0 -and
                $handoffAfter.handoff.status -ceq 'complete' -and @($handoffAfter.handoff.journaled_paths).Count -eq 2) `
            "before=$beforeCount; $($handoffResume.output)"
    }

    $env:APEX_ENGINE_TEST_CRASH_AFTER_WAVE_COMMIT = '1'
    $commitCrash = Invoke-TestScenario -Name 'wave-commit-crash' -Scenario 'done' -Single
    Remove-Item Env:APEX_ENGINE_TEST_CRASH_AFTER_WAVE_COMMIT -ErrorAction SilentlyContinue
    $commitResume = Invoke-TestEngine @('-Resume', $commitCrash.state.run_id, '-StateRoot', $commitCrash.state_root)
    $commitAfter = Get-TestOnlyState $commitCrash.state_root
    Assert-Test 'resume adopts exact one-commit wave crash window and records committed wave' `
        ($commitCrash.result.code -ne 0 -and $commitResume.code -eq 0 -and $commitAfter.status -ceq 'complete' -and
            @($commitAfter.transitions | Where-Object { $_.kind -ceq 'wave-commit-adopted' }).Count -eq 1 -and
            @($commitAfter.tasks[0].attempts).Count -eq 1) $commitResume.output

    $env:APEX_ENGINE_TEST_CRASH_AFTER_WAVE_COMMIT = '1'
    $commitMismatch = Invoke-TestScenario -Name 'wave-commit-mismatch' -Scenario 'done' -Single
    Remove-Item Env:APEX_ENGINE_TEST_CRASH_AFTER_WAVE_COMMIT -ErrorAction SilentlyContinue
    $mismatchIntegration = [string]$commitMismatch.state.integration.worktree
    $mismatchParent = (Invoke-TestGit $mismatchIntegration @('rev-parse', 'HEAD'))[-1]
    Write-TestText (Join-Path $mismatchIntegration 'src\a.py') "unexpected second commit`r`n"
    [void](Set-TestCommit $mismatchIntegration @('src/a.py') $mismatchParent)
    $commitMismatchResume = Invoke-TestEngine @('-Resume', $commitMismatch.state.run_id, '-StateRoot', $commitMismatch.state_root)
    $commitMismatchAfter = Get-TestOnlyState $commitMismatch.state_root
    Assert-Test 'resume parks when integration tip is not exactly the verified one-commit crash window' `
        ($commitMismatch.result.code -ne 0 -and $commitMismatchResume.code -ne 0 -and
            $commitMismatchAfter.status -ceq 'parked' -and
            $commitMismatchAfter.diagnosis -ceq 'integration branch tip mismatch' -and
            @($commitMismatchAfter.transitions | Where-Object { $_.kind -ceq 'wave-commit-adopted' }).Count -eq 0) `
        $commitMismatchResume.output

    $criticalSequence = Join-Path $testRoot 'sequence-critical.ps1'
    Write-TestText $criticalSequence @'
param([switch]$Test, [string[]]$Paths, [string]$Root)
$count = if (Test-Path $env:ENGINE_TEST_CRITICAL_COUNTER) { [int](Get-Content $env:ENGINE_TEST_CRITICAL_COUNTER -Raw) } else { 0 }
$count++; [IO.File]::WriteAllText($env:ENGINE_TEST_CRITICAL_COUNTER, [string]$count)
$sequence = @($env:ENGINE_TEST_CRITICAL_SEQUENCE -split ',')
$code = if ($count -le $sequence.Count) { [int]$sequence[$count - 1] } else { 0 }
Write-Host "critical fixture diagnosis $code"
exit $code
'@
    $env:ENGINE_TEST_CRITICAL_COUNTER = Join-Path $testRoot 'critical-sequence.count'
    $env:ENGINE_TEST_CRITICAL_SEQUENCE = '0,11'
    $criticalSequenceCase = Invoke-TestScenario -Name 'critical-sequence' -Scenario 'done' -Single -CriticalPath $criticalSequence
    Assert-Test 'critical gate exit 11 preserves refused status and its own diagnosis on null-child path' `
        ($criticalSequenceCase.result.code -ne 0 -and $criticalSequenceCase.state.status -ceq 'refused' -and
            $criticalSequenceCase.state.diagnosis -match 'critical fixture diagnosis 11' -and
            @($criticalSequenceCase.state.tasks[0].attempts).Count -eq 1) $criticalSequenceCase.result.output
    Remove-Item Env:ENGINE_TEST_CRITICAL_COUNTER, Env:ENGINE_TEST_CRITICAL_SEQUENCE -ErrorAction SilentlyContinue

    $unknownState = ($state | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    $unknownTask = $unknownState.tasks[0]
    $unknownAttempt = $unknownTask.attempts[0]
    $unknownTask.status = 'running'; $unknownAttempt.status = 'running'; $unknownAttempt.child_pid = 0
    $unknownAttempt.child_start_time = $null; $unknownAttempt.child_output_path = Join-Path $testRoot 'missing-child.out'
    $script:EngineState = $unknownState; $script:EngineStatePath = $null; $script:EngineStateRoot = $stateRoot
    $script:EngineLedgerPath = Join-Path $testRoot 'missing-ledger.jsonl'; $script:EngineWrapper = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
    $env:APEX_ENGINE_TEST_IGNORE_RESUME_LEDGER = '1'
    $unknownWatch = [Diagnostics.Stopwatch]::StartNew()
    $unknownResume = Resume-RunnerAttempt $unknownState.plan.waves[0].tasks[0] $unknownTask $unknownAttempt
    $unknownWatch.Stop(); Remove-Item Env:APEX_ENGINE_TEST_IGNORE_RESUME_LEDGER -ErrorAction SilentlyContinue
    Assert-Test 'null or zero child PID is unknown and parks promptly without Wait-EngineDispatch busy-wait' `
        (-not $unknownResume -and $unknownWatch.Elapsed.TotalSeconds -lt 5 -and
            $unknownTask.diagnosis -match 'dead or unknown') "elapsed=$($unknownWatch.Elapsed); diagnosis=$($unknownTask.diagnosis)"

    # Simulate the owner commit required before proof-gated complete teardown.
    if ($null -ne $state) {
        $originalChildPid = $state.tasks[0].attempts[0].child_pid
        $originalChildStart = $state.tasks[0].attempts[0].child_start_time
        $state.tasks[0].attempts[0].child_pid = $PID
        $state.tasks[0].attempts[0].child_start_time = Get-RunnerProcessStamp $PID
        Write-TestText $stateFiles[0].FullName ($state | ConvertTo-Json -Depth 100)
        $livePidRefusal = Invoke-TestEngine @('-Teardown', $state.run_id, '-StateRoot', $stateRoot, '-WorktreeRoot', $worktreeRoot)
        $state.tasks[0].attempts[0].child_pid = $originalChildPid
        $state.tasks[0].attempts[0].child_start_time = $originalChildStart
        Write-TestText $stateFiles[0].FullName ($state | ConvertTo-Json -Depth 100)

        $ledgerPath = Join-Path $stateRoot 'progress\codex-run-ledger.jsonl'
        $ledgerBytes = [IO.File]::ReadAllBytes($ledgerPath)
        $lease = [ordered]@{
            row_kind = 'lease'; status = 'leasing'; worktree = $state.tasks[0].attempts[0].worktree
            spec = $state.spec.name; task = $state.tasks[0].id; phase = 'build'
            pid = $PID; pid_start = (Get-RunnerProcessStamp $PID)
        }
        [IO.File]::AppendAllText($ledgerPath, (($lease | ConvertTo-Json -Compress) + "`n"), $utf8)
        $liveRowRefusal = Invoke-TestEngine @('-Teardown', $state.run_id, '-StateRoot', $stateRoot, '-WorktreeRoot', $worktreeRoot)
        [IO.File]::WriteAllBytes($ledgerPath, $ledgerBytes)
        Write-TestText $stateFiles[0].FullName ($state | ConvertTo-Json -Depth 100)
        Assert-Test 'teardown refuses live recorded child PID and leasing ledger row' `
            ($livePidRefusal.code -ne 0 -and $livePidRefusal.output -match 'live recorded child_pid' -and
                $liveRowRefusal.code -ne 0 -and $liveRowRefusal.output -match 'live ledger row') `
            "pid=$($livePidRefusal.output); row=$($liveRowRefusal.output)"

        $parent = (Invoke-TestGit $repo @('rev-parse', 'HEAD'))[-1]
        [void](Set-TestCommit $repo @('src/a.py', 'src/b.py') $parent)
        $dirtyTaskWorktree = [string]$state.tasks[0].attempts[0].worktree
        Write-TestText (Join-Path $dirtyTaskWorktree 'src/widget/bin/teardown.dat') "declared ignored teardown output`n"
        $dirtyTaskStatus = Invoke-TestGit $dirtyTaskWorktree @('status', '--porcelain', '-uall', '--ignored')
        Assert-Test 'proof-gated teardown fixture has a declared ignored output in its task worktree' `
            (($dirtyTaskStatus -join "`n") -match '(?m)^!! src/widget/bin/') ($dirtyTaskStatus -join "`n")
        $completeTeardownResult = Invoke-TestEngine @('-Teardown', $state.run_id, '-StateRoot', $stateRoot, '-WorktreeRoot', $worktreeRoot)
        $afterTeardown = Get-Content $stateFiles[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Test 'complete teardown with proof and durable per-item journal' `
            ($completeTeardownResult.code -eq 0 -and $afterTeardown.teardown.status -ceq 'complete' -and @($afterTeardown.teardown.items).Count -eq 6 -and
                -not (Test-Path -LiteralPath $dirtyTaskWorktree) -and
                @($afterTeardown.teardown.items | Where-Object { $_.kind -ceq 'worktree' -and $_.value -ceq $dirtyTaskWorktree }).Count -eq 1) `
            "exit=$($completeTeardownResult.code); $($completeTeardownResult.output)"
    }

    # Kill the Engine parent after both real-wrapper children are durable. Resume must discover
    # their unique ledger rows, adopt/wait, validate the saved events, and finish the build.
    $resumeRepo = New-TestRepo 'resume-repo'
    $resumeSpec = Join-Path $testRoot 'resume-fixture.md'
    New-TestSpec $resumeRepo $resumeSpec
    $resumeStateRoot = Join-Path $testRoot 'resume-state'
    $resumeWorktrees = Join-Path $testRoot 'resume-worktrees'
    $resumeParametersPath = Join-Path $testRoot 'resume-engine-parameters.json'
    $resumeParameters = @{
        SpecPath = $resumeSpec; Repo = $resumeRepo; StateRoot = $resumeStateRoot; WorktreeRoot = $resumeWorktrees
        CodexExecutable = 'powershell.exe'; CodexExecutableArgumentPrefix = $prefix
    }
    Write-TestText $resumeParametersPath ($resumeParameters | ConvertTo-Json -Depth 20)
    $env:ENGINE_TEST_FAKE_DELAY = '6'
    $resumeParent = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $testRoot 'engine-launcher.ps1'), '-Engine', $engine, '-ParametersPath', $resumeParametersPath) `
        -PassThru -WindowStyle Hidden
    $resumeStateFile = $null; $resumeBefore = $null
    $resumeDeadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $resumeDeadline) {
        $candidate = @(Get-ChildItem -LiteralPath $resumeStateRoot -Filter engine-state.json -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($candidate.Count -eq 1) {
            try {
                $probe = Get-Content $candidate[0].FullName -Raw | ConvertFrom-Json
                if (@($probe.tasks | Where-Object { @($_.attempts).Count -gt 0 -and $null -ne $_.attempts[0].child_pid }).Count -eq 2) {
                    $resumeStateFile = $candidate[0]; $resumeBefore = $probe; break
                }
            } catch { }
        }
        Start-Sleep -Milliseconds 100
    }
    $ownerResumeRefusal = if ($null -ne $resumeBefore) {
        Invoke-TestEngine @('-Resume', $resumeBefore.run_id, '-StateRoot', $resumeStateRoot)
    } else { [pscustomobject]@{ code = 1; output = 'owner state not ready' } }
    $ownerDiscardRefusal = if ($null -ne $resumeBefore) {
        Invoke-TestEngine @('-Teardown', $resumeBefore.run_id, '-Discard', '-StateRoot', $resumeStateRoot)
    } else { [pscustomobject]@{ code = 1; output = 'owner state not ready' } }
    Assert-Test 'exclusive run lock refuses concurrent resume and discard against live PID/start owner' `
        ($ownerResumeRefusal.code -ne 0 -and $ownerDiscardRefusal.code -ne 0 -and
            $ownerResumeRefusal.output -match 'live Engine owns|exclusive Engine lock' -and
            $ownerDiscardRefusal.output -match 'live Engine owns|exclusive Engine lock') `
        "resume=$($ownerResumeRefusal.output); discard=$($ownerDiscardRefusal.output)"
    if (-not $resumeParent.HasExited) { Stop-Process -Id $resumeParent.Id -Force; $resumeParent.WaitForExit() }
    Remove-Item Env:ENGINE_TEST_FAKE_DELAY -ErrorAction SilentlyContinue
    $resumed = if ($null -ne $resumeBefore) {
        Invoke-TestEngine @('-Resume', $resumeBefore.run_id, '-StateRoot', $resumeStateRoot)
    } else { [pscustomobject]@{ code = 1; output = 'children were not durably recorded before the deadline' } }
    $resumeAfter = if ($null -ne $resumeStateFile) { Get-Content $resumeStateFile.FullName -Raw | ConvertFrom-Json } else { $null }
    Assert-Test 'killed in-flight parent resumes through ledger adoption and saved events' `
        ($resumed.code -eq 0 -and $null -ne $resumeAfter -and $resumeAfter.status -ceq 'complete' -and
            @($resumeAfter.tasks | Where-Object { $_.status -ceq 'integrated' }).Count -eq 2) `
        "exit=$($resumed.code); $($resumed.output)"
    if ($null -ne $resumeAfter -and $resumeAfter.status -ceq 'complete') {
        $resumeParentSha = (Invoke-TestGit $resumeRepo @('rev-parse', 'HEAD'))[-1]
        [void](Set-TestCommit $resumeRepo @('src/a.py', 'src/b.py') $resumeParentSha)
        $resumeTeardown = Invoke-TestEngine @('-Teardown', $resumeAfter.run_id, '-StateRoot', $resumeStateRoot)
        Assert-Test 'resumed run retains proof-gated teardown recovery paths' ($resumeTeardown.code -eq 0) $resumeTeardown.output
    }

    $parkedRepo = New-TestRepo 'parked-live-repo'
    $parkedSpec = Join-Path $testRoot 'parked-live.md'
    New-TestSpec $parkedRepo $parkedSpec -Single
    $parkedStateRoot = Join-Path $testRoot 'parked-live-state'
    $parkedWorktrees = Join-Path $testRoot 'parked-live-worktrees'
    $parkedParametersPath = Join-Path $testRoot 'parked-live-parameters.json'
    Write-TestText $parkedParametersPath (@{
        SpecPath = $parkedSpec; Repo = $parkedRepo; StateRoot = $parkedStateRoot; WorktreeRoot = $parkedWorktrees
        CodexExecutable = 'powershell.exe'; CodexExecutableArgumentPrefix = $prefix
    } | ConvertTo-Json -Depth 20)
    $env:ENGINE_TEST_FAKE_DELAY = '5'
    $parkedParent = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $testRoot 'engine-launcher.ps1'), '-Engine', $engine, '-ParametersPath', $parkedParametersPath) `
        -PassThru -WindowStyle Hidden
    $parkedStateFile = $null; $parkedBefore = $null; $parkedDeadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $parkedDeadline) {
        $candidate = @(Get-ChildItem -LiteralPath $parkedStateRoot -Filter engine-state.json -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($candidate.Count -eq 1) {
            try {
                $probe = Get-Content $candidate[0].FullName -Raw | ConvertFrom-Json
                if (@($probe.tasks[0].attempts).Count -eq 1 -and
                        (Test-RunnerPidLive $probe.tasks[0].attempts[0].child_pid $probe.tasks[0].attempts[0].child_start_time)) {
                    $parkedStateFile = $candidate[0]; $parkedBefore = $probe; break
                }
            } catch { }
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $parkedParent.HasExited) { Stop-Process -Id $parkedParent.Id -Force; $parkedParent.WaitForExit() }
    Remove-Item Env:ENGINE_TEST_FAKE_DELAY -ErrorAction SilentlyContinue
    if ($null -ne $parkedBefore) {
        $parkedBefore.status = 'parked'; $parkedBefore.diagnosis = 'simulated wait cap'
        $parkedBefore.tasks[0].status = 'parked'; $parkedBefore.tasks[0].diagnosis = 'simulated wait cap'
        $parkedBefore.tasks[0].attempts[0].status = 'parked'
        Write-TestText $parkedStateFile.FullName ($parkedBefore | ConvertTo-Json -Depth 100)
    }
    $env:APEX_ENGINE_TEST_IGNORE_RESUME_LEDGER = '1'
    $parkedResume = if ($null -ne $parkedBefore) {
        Invoke-TestEngine @('-Resume', $parkedBefore.run_id, '-StateRoot', $parkedStateRoot)
    } else { [pscustomobject]@{ code = 1; output = 'parked live child was not observed' } }
    Remove-Item Env:APEX_ENGINE_TEST_IGNORE_RESUME_LEDGER -ErrorAction SilentlyContinue
    $parkedAfter = if ($null -ne $parkedStateFile) { Get-Content $parkedStateFile.FullName -Raw | ConvertFrom-Json } else { $null }
    Assert-Test 'parked live-child with no visible row is waited and adopted before any new attempt' `
        ($parkedResume.code -eq 0 -and $null -ne $parkedAfter -and $parkedAfter.status -ceq 'complete' -and
            @($parkedAfter.tasks[0].attempts).Count -eq 1) $parkedResume.output

    $criticalJson.tasks[0].attempts = @([pscustomobject][ordered]@{
        number = 1; status = 'running'; effort = 'medium'; model = 'gpt-5.6-sol'
        worktree = $criticalJson.integration.worktree; branch = $criticalJson.integration.branch; child_pid = $PID
        child_start_time = (Get-RunnerProcessStamp $PID)
        wrapper_run_id = $null; exit_code = $null; event_path = $null
        args_path = (Join-Path (Split-Path $criticalStateFile.FullName -Parent) 'dummy-args.json')
        child_output_path = (Join-Path (Split-Path $criticalStateFile.FullName -Parent) 'dummy-child.out')
        end_tree_digest = $null; diagnosis = $null; capacity_retries = 0; process_retries = 0
    })
    Write-TestText $criticalStateFile.FullName ($criticalJson | ConvertTo-Json -Depth 100)
    $discardLiveRefusal = Invoke-TestEngine @('-Teardown', $criticalJson.run_id, '-Discard', '-StateRoot', $criticalState,
        '-WorktreeRoot', (Join-Path $testRoot 'critical-wt'))
    $criticalJson.tasks[0].attempts = @()
    $criticalJson.teardown.status = 'pending'
    Write-TestText $criticalStateFile.FullName ($criticalJson | ConvertTo-Json -Depth 100)
    $discardResult = Invoke-TestEngine @('-Teardown', $criticalJson.run_id, '-Discard', '-StateRoot', $criticalState,
        '-WorktreeRoot', (Join-Path $testRoot 'critical-wt'))
    $discardState = Get-Content $criticalStateFile.FullName -Raw | ConvertFrom-Json
    Assert-Test 'discard teardown for parked run with live-child refusal' `
        ($discardLiveRefusal.code -ne 0 -and $discardLiveRefusal.output -match 'live recorded child_pid' -and
            $discardResult.code -eq 0 -and $discardState.teardown.status -ceq 'complete') `
        $discardResult.output

    }
    if ($AcceptanceOnly) { $gateBaseline = Join-Path $testRoot 'fake-baseline.ps1'; New-TestGateBaseline $gateBaseline }

    # Import-only parameter binding and direct attempts keep acceptance timeout tests independent of
    # full Engine runs. Reuse the allowed plan from the schema-valid reachability fixture.
    $acceptTimeoutSchema = Get-Content $schemaPath -Raw | ConvertFrom-Json
    $acceptTimeoutFixtureRepo = $repo
    $acceptTimeoutFixtureStateRoot = $stateRoot
    $acceptTimeoutFixtureWorktreeRoot = $worktreeRoot
    $env:APEX_ENGINE_TEST_IMPORT_ONLY = '1'
    foreach ($invalidTimeout in @(0, 241)) {
        $rejected = $false
        try { . $engine -AcceptTimeoutMin $invalidTimeout } catch { $rejected = $true }
        Assert-Test "acceptance timeout CLI rejects $invalidTimeout" $rejected 'ValidateRange accepted an out-of-range acceptance timeout'
    }
    $acceptTimeoutStates = @()
    foreach ($acceptTimeoutCase in @('default', 'explicit')) {
        $importParameters = @{ SpecPath = $spec }
        if ($acceptTimeoutCase -ceq 'explicit') { $importParameters.AcceptTimeoutMin = 75 }
        . $engine @importParameters
        $repo = $acceptTimeoutFixtureRepo; $stateRoot = $acceptTimeoutFixtureStateRoot; $worktreeRoot = $acceptTimeoutFixtureWorktreeRoot
        $expectedTimeout = if ($acceptTimeoutCase -ceq 'explicit') { 75 } else { 60 }
        Assert-Test "$acceptTimeoutCase acceptance timeout binding flag" `
            ($script:EngineAcceptTimeoutBound -eq ($acceptTimeoutCase -ceq 'explicit')) 'explicit binding flag was incorrect'
        $runDirectory = Join-Path $testRoot ("acceptTimeout-$acceptTimeoutCase")
        $script:EngineStatePath = Join-Path $runDirectory 'engine-state.json'
        $script:EngineWorktreeRoot = $worktreeRoot
        $script:EngineWrapper = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
        $newState = New-RunnerStateObject ([Guid]::NewGuid().ToString('N')) $runDirectory `
            $repo $state.base_sha 2 $state.capacity $state.plan $state.spec.name `
            $state.spec.original_digest $state.spec.snapshot_path $state.engine_owner
        Assert-Test "$acceptTimeoutCase new state records acceptance timeout" `
            ($newState.accept_timeout_min -eq $expectedTimeout) 'new state lost its acceptance timeout'
        $acceptTimeoutStates += $newState
    }
    Remove-Item Env:APEX_ENGINE_TEST_IMPORT_ONLY -ErrorAction SilentlyContinue
    $legacyTimeoutState = ($acceptTimeoutStates[0] | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    $legacyTimeoutState.PSObject.Properties.Remove('accept_timeout_min')
    foreach ($schemaState in @($acceptTimeoutStates[0], $acceptTimeoutStates[1], $legacyTimeoutState)) {
        $valid = $true; $detail = ''
        try { Test-Structure $schemaState $acceptTimeoutSchema } catch { $valid = $false; $detail = $_.Exception.Message }
        Assert-Test 'new/legacy acceptance timeout state passes schema' $valid $detail
    }
    foreach ($invalidTimeout in @(241, 0, 'not-an-integer')) {
        $invalidState = ($acceptTimeoutStates[0] | ConvertTo-Json -Depth 100) | ConvertFrom-Json
        $invalidState.accept_timeout_min = $invalidTimeout
        $rejection = ''
        try { Test-Structure $invalidState $acceptTimeoutSchema } catch { $rejection = $_.Exception.Message }
        $expectedReason = if ($invalidTimeout -eq 241) { 'above its maximum' }
            elseif ($invalidTimeout -eq 0) { 'below its minimum' } else { 'wrong JSON type' }
        Assert-Test "acceptance timeout schema rejects $invalidTimeout" `
            ($rejection -like "*accept_timeout_min*$expectedReason*") $rejection
    }
    try {
        foreach ($case in @('default', 'explicit', 'legacy', 'resume-bound', 'resume-unbound', 'resume-legacy-bound', 'resume-legacy-unbound')) {
            $sourceState = if ($case -ceq 'explicit') { $acceptTimeoutStates[1] }
                elseif ($case -like '*legacy*') { $legacyTimeoutState } else { $acceptTimeoutStates[0] }
            $script:EngineState = ($sourceState | ConvertTo-Json -Depth 100) | ConvertFrom-Json
            $expectedTimeout = if ($case -ceq 'explicit') { 75 } else { 60 }
            $script:EngineStateRoot = Join-Path $testRoot "acceptTimeout-$case-state"
            $script:EngineStatePath = Join-Path (Join-Path $script:EngineStateRoot $script:EngineState.run_id) 'engine-state.json'
            if ($case -like 'resume-*') {
                $script:EngineAcceptTimeoutBound = $case -like '*-bound'
                $AcceptTimeoutMin = 90
                if ($case -notlike '*legacy*') { $script:EngineState.accept_timeout_min = 45 }
                Save-RunnerState
                $ready = Initialize-RunnerResume $script:EngineState.run_id
                $expectedTimeout = if ($script:EngineAcceptTimeoutBound) { 90 }
                    elseif ($case -like '*legacy*') { 60 } else { 45 }
                $savedResume = Get-Content $script:EngineStatePath -Raw | ConvertFrom-Json
                $savedProperty = $savedResume.PSObject.Properties['accept_timeout_min']
                Assert-Test "$case saves acceptance timeout choice" `
                    ($ready -and (($null -ne $savedProperty -and $savedProperty.Value -eq $expectedTimeout) -or
                        ($case -ceq 'resume-legacy-unbound' -and $null -eq $savedProperty))) 'resume lost persisted acceptance timeout choice'
            }
            $script:EngineState.integration.worktree = $acceptTimeoutFixtureRepo
            $record = New-RunnerAcceptanceRecord ("accept-timeout-$case")
            $env:APEX_ENGINE_TEST_ACCEPT_TIMEOUT_MS = '1000'
            $passed = Invoke-RunnerAcceptanceCheck ([pscustomobject]@{
                id = "accept-timeout-$case"; body = 'Start-Sleep -Seconds 30'
            }) $record
            Assert-Test "$case acceptance uses state timeout or legacy fallback and kills child" `
                (-not $passed -and $record.status -ceq 'failed' -and
                    $record.output_tail.EndsWith("timed out after $expectedTimeout min") -and
                    -not (Test-RunnerPidLive $record.child_pid $record.child_start_time)) $record.output_tail
            Remove-Item Env:APEX_ENGINE_TEST_ACCEPT_TIMEOUT_MS -ErrorAction SilentlyContinue
            Close-RunnerRunLock
        }
    } finally {
        Close-RunnerRunLock
        $env:APEX_ENGINE_TEST_IMPORT_ONLY = '1'
        . $engine
        $repo = $acceptTimeoutFixtureRepo; $stateRoot = $acceptTimeoutFixtureStateRoot; $worktreeRoot = $acceptTimeoutFixtureWorktreeRoot
        Remove-Item Env:APEX_ENGINE_TEST_IMPORT_ONLY -ErrorAction SilentlyContinue
    }


    # Real child checks: exits never terminate the Engine, output is bounded, and
    # timeouts kill the launcher and its descendants.
    $env:APEX_ENGINE_TEST_IMPORT_ONLY = '1'; . $engine
    Remove-Item Env:APEX_ENGINE_TEST_IMPORT_ONLY -ErrorAction SilentlyContinue
    $acceptRepo = New-TestRepo 'accept-child-repo'
    $script:EngineState = ($state | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    $script:EngineState.integration.worktree = $acceptRepo
    $script:EngineStatePath = Join-Path $testRoot 'accept-child-state/engine-state.json'
    foreach ($childCase in @(
        @{ name = 'exit-zero'; body = 'exit 0'; passed = $true },
        @{ name = 'throw'; body = "throw 'accept-throw'"; passed = $false },
        @{ name = 'exit-seven'; body = 'exit 7'; passed = $false },
        @{ name = 'native-exit'; body = 'cmd.exe /c exit 9; exit $LASTEXITCODE'; passed = $false }
    )) {
        $record = New-RunnerAcceptanceRecord $childCase.name
        $check = [pscustomobject]@{ id = $childCase.name; body = $childCase.body }
        $passed = Invoke-RunnerAcceptanceCheck $check $record
        Assert-Test ("acceptance child $($childCase.name)") ($passed -eq $childCase.passed -and
            $record.status -ceq $(if ($childCase.passed) { 'passed' } else { 'failed' })) ($record | ConvertTo-Json -Compress)
        Assert-Test 'acceptance script preserves body with Stop preference prepended' `
            ([IO.File]::ReadAllText((Join-Path $testRoot "accept-child-state/acceptance/$($childCase.name).ps1")) -ceq ("`$ErrorActionPreference = 'Stop'`n" + $childCase.body)) ''
    }
    $record = New-RunnerAcceptanceRecord 'tail'
    [void](Invoke-RunnerAcceptanceCheck ([pscustomobject]@{ id = 'tail'; body = "1..55 | ForEach-Object { Write-Output ('line-' + `$_) }; [Console]::Error.WriteLine('stderr-sentinel'); exit 7" }) $record)
    Assert-Test 'acceptance combined output last forty lines' (@($record.output_tail -split "`n").Count -eq 40 -and
        $record.output_tail.Contains('line-55') -and $record.output_tail.Contains('stderr-sentinel') -and -not $record.output_tail.Contains('line-1' + "`n")) $record.output_tail
    $record = New-RunnerAcceptanceRecord 'timeout'
    $env:APEX_ENGINE_TEST_ACCEPT_TIMEOUT_MS = '1000'
    [void](Invoke-RunnerAcceptanceCheck ([pscustomobject]@{ id = 'timeout'; body = 'Start-Sleep -Seconds 30' }) $record)
    Remove-Item Env:APEX_ENGINE_TEST_ACCEPT_TIMEOUT_MS -ErrorAction SilentlyContinue
    Assert-Test 'acceptance timeout fails kills process tree and ends with specified tail' ($record.status -ceq 'failed' -and
        $record.output_tail.EndsWith('timed out after 60 min') -and -not (Test-RunnerPidLive $record.child_pid $record.child_start_time)) $record.output_tail

    # Capture the actual WaitForExit argument without waiting minutes. Real children
    # above cover expiry and termination for new, resumed, and legacy states.
    function Start-Process {
        param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$PassThru)
        $process = [pscustomobject]@{ Id = $PID; StartTime = [DateTime]::Now; ExitCode = 0 }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
            param($Milliseconds)
            $script:acceptWaitMilliseconds = $Milliseconds
            return $true
        }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        return $process
    }
    try {
        foreach ($limitCase in @(
            @{ name = 'default'; minutes = 60; mode = '1'; override = ''; expected = 3600000 },
            @{ name = 'configured'; minutes = 75; mode = '1'; override = ''; expected = 4500000 },
            @{ name = 'legacy'; minutes = $null; mode = '1'; override = ''; expected = 3600000 },
            @{ name = 'maximum'; minutes = 240; mode = '1'; override = ''; expected = 14400000 },
            @{ name = 'capped'; minutes = 1; mode = '1'; override = '99999999'; expected = 60000 },
            @{ name = 'large-override'; minutes = 1; mode = '1'; override = '9999999999'; expected = 60000 },
            @{ name = 'shortened'; minutes = 75; mode = '1'; override = '1000'; expected = 1000 },
            @{ name = 'zero-override'; minutes = 1; mode = '1'; override = '0'; expected = 60000 },
            @{ name = 'invalid-override'; minutes = 1; mode = '1'; override = 'invalid'; expected = 60000 },
            @{ name = 'outside-test-mode'; minutes = 1; mode = '0'; override = '1000'; expected = 60000 }
        )) {
            $script:EngineState.PSObject.Properties.Remove('accept_timeout_min')
            if ($null -ne $limitCase.minutes) {
                $script:EngineState | Add-Member -NotePropertyName accept_timeout_min -NotePropertyValue $limitCase.minutes
            }
            $env:APEX_ENGINE_TEST_MODE = $limitCase.mode
            $env:APEX_ENGINE_TEST_ACCEPT_TIMEOUT_MS = $limitCase.override
            $script:acceptWaitMilliseconds = $null
            $record = New-RunnerAcceptanceRecord ("effective-limit-$($limitCase.name)")
            $passed = Invoke-RunnerAcceptanceCheck ([pscustomobject]@{ id = "effective-limit-$($limitCase.name)"; body = 'exit 0' }) $record
            Assert-Test "acceptance effective limit $($limitCase.name)" `
                ($passed -and $script:acceptWaitMilliseconds -eq $limitCase.expected) `
                "wait=$script:acceptWaitMilliseconds; tail=$($record.output_tail)"
        }
    } finally {
        Remove-Item Function:Start-Process
        $env:APEX_ENGINE_TEST_MODE = '1'
        Remove-Item Env:APEX_ENGINE_TEST_ACCEPT_TIMEOUT_MS -ErrorAction SilentlyContinue
        $script:EngineState.PSObject.Properties.Remove('accept_timeout_min')
    }

    # A baseline RED never executes the checks. A per-task file subset cannot run
    # another task's check, including the calls used by Find-RunnerWaveFailure.
    $script:EngineState.plan.waves = @([pscustomobject]@{ number = 1; tasks = @(
        [pscustomobject]@{ id = '1'; files = @([pscustomobject]@{ path = 'AGENTS.md'; op = 'modify' }); acceptance_checks = @([pscustomobject]@{ id = '1-1'; body = "[IO.File]::AppendAllText(`$env:ENGINE_TEST_ACCEPT_COUNTER, '1'); exit 0" }) },
        [pscustomobject]@{ id = '2'; files = @([pscustomobject]@{ path = 'verify.ps1'; op = 'modify' }); acceptance_checks = @([pscustomobject]@{ id = '2-1'; body = "[IO.File]::AppendAllText(`$env:ENGINE_TEST_ACCEPT_COUNTER, '2'); throw 'task two failure'" }) }
    ) })
    foreach ($task in $script:EngineState.tasks) { $task.PSObject.Properties.Remove('acceptance') }
    $env:ENGINE_TEST_ACCEPT_COUNTER = Join-Path $testRoot 'accept-selected.txt'
    $env:ENGINE_TEST_GATE_COUNTER = Join-Path $testRoot 'accept-baseline-count'; [void][IO.Directory]::CreateDirectory($env:ENGINE_TEST_GATE_COUNTER)
    $env:ENGINE_TEST_BASELINE_EXIT = '1'; $script:EngineBaselineScript = $gateBaseline
    $selectedFiles = @($script:EngineState.plan.waves[0].tasks[0].files)
    $skipGate = Invoke-RunnerGate $selectedFiles 1
    Assert-Test 'baseline failure skips tagged task checks' ($skipGate.gate -ceq 'baseline' -and $skipGate.code -eq 1 -and
        -not (Test-Path -LiteralPath $env:ENGINE_TEST_ACCEPT_COUNTER)) $skipGate.diagnosis
    $env:ENGINE_TEST_BASELINE_EXIT = '0'
    $oneGate = Invoke-RunnerGate $selectedFiles 1
    $twoGate = Invoke-RunnerGate @($script:EngineState.plan.waves[0].tasks[1].files) 1
    Assert-Test 'per-task gate selects only its manifest checks and returns failing task ID/tail' ($oneGate.code -eq 0 -and
        [IO.File]::ReadAllText($env:ENGINE_TEST_ACCEPT_COUNTER) -ceq '12' -and $twoGate.gate -ceq 'accept' -and
        $twoGate.code -eq 1 -and $twoGate.failing_task_id -ceq '2' -and $twoGate.output_tail -match 'task two failure') ($twoGate | ConvertTo-Json -Compress)
    $savedRestore = ${function:Restore-RunnerWave}; $savedCopy = ${function:Copy-EngineTaskFiles}
    function Restore-RunnerWave { param($Base, $Files) return $true }
    function Copy-EngineTaskFiles { param($TargetWorktree, $IntegrationWorktree, $TaskWorktree, $WaveBaseSha, $Files) [pscustomobject]@{ ok = $true } }
    $isolatedFailureGates = @{}
    try { $isolatedChecks = @(Find-RunnerWaveFailure $script:EngineState.plan.waves[0] $script:EngineState.base_sha @($script:EngineState.plan.waves[0].tasks | ForEach-Object { $_.files }) $isolatedFailureGates) }
    finally { Set-Item Function:Restore-RunnerWave $savedRestore; Set-Item Function:Copy-EngineTaskFiles $savedCopy }
    Assert-Test 'Find-RunnerWaveFailure per-task calls execute only that task checks' (($isolatedChecks -join ',') -ceq '2' -and
        [IO.File]::ReadAllText($env:ENGINE_TEST_ACCEPT_COUNTER) -ceq '1212' -and $isolatedFailureGates['2'].gate -ceq 'accept' -and
        $isolatedFailureGates['2'].output_tail -match 'task two failure') ($isolatedChecks -join ',')
    $script:EngineState.status = 'running'; $script:IsolationRestores = 0
    $script:EngineState.plan.waves[0].tasks[1].acceptance_checks[0].body = "[IO.File]::AppendAllText('AGENTS.md', 'check movement'); exit 0"
    function Restore-RunnerWave { param($Base, $Files) $script:IsolationRestores++; return $true }
    function Copy-EngineTaskFiles { param($TargetWorktree, $IntegrationWorktree, $TaskWorktree, $WaveBaseSha, $Files) [pscustomobject]@{ ok = $true } }
    try { [void](Find-RunnerWaveFailure $script:EngineState.plan.waves[0] $script:EngineState.base_sha @($script:EngineState.plan.waves[0].tasks | ForEach-Object { $_.files })) }
    finally { Set-Item Function:Restore-RunnerWave $savedRestore; Set-Item Function:Copy-EngineTaskFiles $savedCopy }
    Assert-Test 'per-task isolation integrity failure parks without restoring mutation' ($script:EngineState.status -ceq 'parked' -and
        $script:IsolationRestores -eq 2 -and [IO.File]::ReadAllText((Join-Path $acceptRepo 'AGENTS.md')).Contains('check movement')) $script:EngineState.diagnosis
    Remove-Item Env:ENGINE_TEST_GATE_COUNTER, Env:ENGINE_TEST_BASELINE_EXIT -ErrorAction SilentlyContinue

    $retryCriteria = @'
- [ ] Task 1 - first task check
```powershell apex-accept
exit 0
```
- [ ] Task 2 - second task check
```powershell apex-accept
if (-not (Test-Path -LiteralPath $env:ENGINE_TEST_ACCEPT_COUNTER)) {
    [IO.File]::WriteAllText($env:ENGINE_TEST_ACCEPT_COUNTER, 'failed once')
    throw 'task-two-acceptance-sentinel'
}
exit 0
```
- [ ] Task 1 - HOST review remains visible
'@
    $env:ENGINE_TEST_ACCEPT_COUNTER = Join-Path $testRoot 'accept-retry-counter'
    $env:APEX_ENGINE_TEST_CRASH_AFTER_VERIFICATION_FAILURE = 'low'
    $acceptRetry = Invoke-TestScenario -Name 'accept-retry' -Effort low -AcceptanceText $retryCriteria
    Remove-Item Env:APEX_ENGINE_TEST_CRASH_AFTER_VERIFICATION_FAILURE -ErrorAction SilentlyContinue
    $acceptFailed = Get-TestOnlyState $acceptRetry.state_root
    Assert-Test 'acceptance failure journals tail failed attempt diagnosis before crash' ($acceptFailed.tasks[1].attempts[0].status -ceq 'failed' -and
        $acceptFailed.tasks[1].attempts[0].diagnosis -ceq 'verification failure' -and
        $acceptFailed.tasks[1].attempts[0].acceptance_output_tail -match 'task-two-acceptance-sentinel') $acceptRetry.result.output
    $retryResume = Invoke-TestEngine @('-Resume', $acceptFailed.run_id, '-StateRoot', $acceptRetry.state_root)
    $acceptAfter = Get-TestOnlyState $acceptRetry.state_root
    $retryPrompt = (Get-Content -LiteralPath $acceptAfter.tasks[1].attempts[1].args_path -Raw -Encoding UTF8 | ConvertFrom-Json).Prompt
    $frozenPrompt = $acceptAfter.plan.waves[0].tasks[1].prompt
    $retryAssertions = [ordered]@{
        completed = $retryResume.code -eq 0 -and $acceptAfter.status -ceq 'complete'
        first_task_once = @($acceptAfter.tasks[0].attempts).Count -eq 1
        second_task_retried = @($acceptAfter.tasks[1].attempts).Count -eq 2
        next_effort = $acceptAfter.tasks[1].attempts[1].effort -ceq 'medium'
        prompt_prefix = $retryPrompt.Contains('Previous acceptance check output:')
        prompt_tail = $retryPrompt.Contains($acceptFailed.tasks[1].attempts[0].acceptance_output_tail)
        frozen = -not $frozenPrompt.Contains('Previous acceptance check output:') -and $frozenPrompt -ceq $acceptFailed.plan.waves[0].tasks[1].prompt
        frozen_digest = (Get-EngineSha256 -Text $frozenPrompt) -ceq $acceptAfter.plan.waves[0].tasks[1].prompt_digest
    }
    Assert-Test 'two-task acceptance failure retries only failing task and appends tail to next prompt' `
        (@($retryAssertions.GetEnumerator() | Where-Object { -not $_.Value }).Count -eq 0) `
        (($retryAssertions | ConvertTo-Json -Compress) + '; ' + $retryResume.output)
    Assert-Test 'complete run prints HOST checks and exact next line' ($retryResume.output.Contains('HOST checks:') -and
        $retryResume.output.Contains('- [ ] Task 1 - HOST review remains visible') -and
        $retryResume.output.Contains("Next: run HOST checks, review, commit, then -Teardown $($acceptAfter.run_id).")) $retryResume.output
    $completeStatus = Invoke-TestEngine @('-Resume', $acceptAfter.run_id, '-StateRoot', $acceptRetry.state_root)
    Assert-Test 'complete status output retains HOST checks' ($completeStatus.output.Contains('HOST checks:') -and $completeStatus.output.Contains('HOST review remains visible')) $completeStatus.output

    # The second attempt fails baseline without running checks. Exercise both
    # direct single-task routing and the multi-task isolation fallback.
    $staleTailCriteria = @'
- [ ] Task 1 - task check fails once
```powershell apex-accept
if (-not (Test-Path -LiteralPath $env:ENGINE_TEST_ACCEPT_COUNTER)) {
    [IO.File]::WriteAllText($env:ENGINE_TEST_ACCEPT_COUNTER, 'failed once')
    throw ('attempt-one-' + 'stale-tail-sentinel')
}
exit 0
```
'@
    foreach ($singleTask in @($true, $false)) {
        $caseName = if ($singleTask) { 'accept-stale-tail-single' } else { 'accept-stale-tail-isolation' }
        $env:ENGINE_TEST_ACCEPT_COUNTER = Join-Path $testRoot "$caseName-check"
        $env:ENGINE_TEST_GATE_COUNTER = Join-Path $testRoot "$caseName-baseline"
        [void][IO.Directory]::CreateDirectory($env:ENGINE_TEST_GATE_COUNTER)
        $env:ENGINE_TEST_BASELINE_EXIT = '0'
        $env:ENGINE_TEST_BASELINE_SEQUENCE = if ($singleTask) { '0,1,0' } else { '0,1,1,0,0' }
        $caseCriteria = if ($singleTask) { $staleTailCriteria } else { $staleTailCriteria + "`n- [ ] Task 2 - HOST reviews second task`n" }
        try {
            $staleTailCase = Invoke-TestScenario -Name $caseName -Single:$singleTask -Effort low `
                -AcceptanceText $caseCriteria -BaselinePath $gateBaseline
            $staleAttempts = @($staleTailCase.state.tasks[0].attempts)
            $thirdPrompt = if ($staleAttempts.Count -eq 3) {
                (Get-Content -LiteralPath $staleAttempts[2].args_path -Raw -Encoding UTF8 | ConvertFrom-Json).Prompt
            } else { '' }
            $secondTail = if ($staleAttempts.Count -ge 2 -and $staleAttempts[1].PSObject.Properties['acceptance_output_tail']) {
                [string]$staleAttempts[1].acceptance_output_tail
            } else { '' }
            Assert-Test "$caseName baseline failure never reuses a prior attempt acceptance tail" `
                ($staleTailCase.result.code -eq 0 -and $staleTailCase.state.status -ceq 'complete' -and
                $staleAttempts.Count -eq 3 -and $staleAttempts[0].acceptance_output_tail -match 'attempt-one-stale-tail-sentinel' -and
                $staleAttempts[1].status -ceq 'failed' -and $staleAttempts[1].diagnosis -ceq 'verification failure' -and
                [string]::IsNullOrEmpty($secondTail) -and -not $thirdPrompt.Contains('attempt-one-stale-tail-sentinel') -and
                -not $thirdPrompt.Contains('Previous acceptance check output:')) $staleTailCase.result.output
        } finally {
            Remove-Item Env:ENGINE_TEST_BASELINE_SEQUENCE, Env:ENGINE_TEST_GATE_COUNTER, Env:ENGINE_TEST_BASELINE_EXIT -ErrorAction SilentlyContinue
        }
    }

    $specCriteria = @'
- [ ] Task 1 - HOST fixture criterion
- [ ] first spec check
```powershell apex-accept
[IO.File]::AppendAllText($env:ENGINE_TEST_ACCEPT_COUNTER, 'first')
exit 0
```
- [ ] second spec check
```powershell apex-accept
if ($env:ENGINE_TEST_SPEC_FAIL -eq '1') { throw 'spec-failure-sentinel' }
exit 0
```
'@
    $env:ENGINE_TEST_ACCEPT_COUNTER = Join-Path $testRoot 'spec-passed-counter'
    $env:ENGINE_TEST_SPEC_FAIL = '1'
    $specFailure = Invoke-TestScenario -Name 'spec-accept-failure' -Single -AcceptanceText $specCriteria
    Remove-Item Env:ENGINE_TEST_SPEC_FAIL -ErrorAction SilentlyContinue
    $specBefore = Get-TestOnlyState $specFailure.state_root
    Assert-Test 'post-commit spec failure parks with durable records and no handoff' ($specFailure.result.code -eq 1 -and
        $specBefore.status -ceq 'parked' -and $specBefore.tasks[0].status -ceq 'integrated' -and
        $specBefore.spec_acceptance.status -ceq 'failed' -and $specBefore.spec_acceptance.checks[0].status -ceq 'passed' -and
        $specBefore.spec_acceptance.checks[1].status -ceq 'failed' -and $specBefore.handoff.status -ceq 'pending' -and
        $specBefore.integration.tip -cne $specBefore.base_sha) $specFailure.result.output
    $specResume = Invoke-TestEngine @('-Resume', $specBefore.run_id, '-StateRoot', $specFailure.state_root)
    $specAfter = Get-TestOnlyState $specFailure.state_root
    Assert-Test 'spec Resume skips passed checks clears stale tail and completes' ($specResume.code -eq 0 -and
        $specAfter.spec_acceptance.status -ceq 'passed' -and $specAfter.spec_acceptance.checks[1].output_tail -ceq '' -and
        [IO.File]::ReadAllText($env:ENGINE_TEST_ACCEPT_COUNTER) -ceq 'first' -and $specAfter.counters.dispatches -eq 1) $specResume.output
    $pendingSpec = ($specAfter | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    $pendingSpec.status = 'parked'; $pendingSpec.spec_acceptance.status = 'pending'
    $pendingSpec.spec_acceptance.checks[1].status = 'pending'; $pendingSpec.spec_acceptance.checks[1].output_tail = 'stale pending tail'
    Write-TestText (Get-TestOnlyStateFile $specFailure.state_root).FullName ($pendingSpec | ConvertTo-Json -Depth 100)
    $pendingResume = Invoke-TestEngine @('-Resume', $pendingSpec.run_id, '-StateRoot', $specFailure.state_root)
    $specAfter = Get-TestOnlyState $specFailure.state_root
    Assert-Test 'spec pending Resume clears previous tail and reruns only pending check' ($pendingResume.code -eq 0 -and
        $specAfter.spec_acceptance.status -ceq 'passed' -and $specAfter.spec_acceptance.checks[1].output_tail -ceq '' -and
        [IO.File]::ReadAllText($env:ENGINE_TEST_ACCEPT_COUNTER) -ceq 'first') $pendingResume.output

    $deleteCriteria = "- [ ] Task 1 - HOST reviews deletion`n- [ ] deleted fixture stays absent`n``````powershell apex-accept`n[IO.File]::AppendAllText(`$env:APEX_ENGINE_TEST_STAGE_TRACE_PATH, 'spec' + [char]10)`nif (Test-Path src/a.py) { throw 'delete still present' }; exit 0`n```````n"
    $env:ENGINE_TEST_GATE_COUNTER = Join-Path $testRoot 'spec-delete-baseline'; [void][IO.Directory]::CreateDirectory($env:ENGINE_TEST_GATE_COUNTER)
    $env:ENGINE_TEST_BASELINE_EXIT = '0'
    $env:APEX_ENGINE_TEST_STAGE_TRACE_PATH = Join-Path $testRoot 'spec-delete-stage-trace.txt'
    try {
        $deleteAccept = Invoke-TestScenario -Name 'spec-accept-delete' -Scenario delete -Single -Delete -AcceptanceText $deleteCriteria -BaselinePath $gateBaseline
    } finally { $env:APEX_ENGINE_TEST_STAGE_TRACE_PATH = $oldStageTrace }
    Assert-Test 'post-commit spec check accepts manifest delete without staging or repeating baseline' ($deleteAccept.result.code -eq 0 -and
        $deleteAccept.state.spec_acceptance.status -ceq 'passed' -and -not (Test-Path (Join-Path $deleteAccept.state.integration.worktree 'src/a.py')) -and
        (Get-Content (Join-Path $env:ENGINE_TEST_GATE_COUNTER 'baseline.txt') -Raw) -ceq '1' -and
        [IO.File]::ReadAllText((Join-Path $testRoot 'spec-delete-stage-trace.txt')) -ceq "stage`nspec`n") $deleteAccept.result.output
    Remove-Item Env:ENGINE_TEST_GATE_COUNTER, Env:ENGINE_TEST_BASELINE_EXIT -ErrorAction SilentlyContinue

    foreach ($mutation in @('working', 'index', 'head', 'residue', 'pin')) {
        $body = switch ($mutation) {
            'working' { "[IO.File]::AppendAllText('src/a.py', 'movement')" }
            'index' { "git update-index --force-remove src/a.py; if (`$LASTEXITCODE) { throw 'native' }" }
            'head' { "git update-ref HEAD HEAD^; if (`$LASTEXITCODE) { throw 'native' }" }
            'residue' { "[IO.File]::WriteAllText('residue-untracked.txt', 'residue')" }
            'pin' { 'exit 0' }
        }
        $criteria = "- [ ] Task 1 - HOST reviews fixture`n- [ ] spec integrity fixture`n``````powershell apex-accept`n$body`n```````n"
        $pinPath = $null
        if ($mutation -ceq 'pin') {
            $pinPath = Join-Path $testRoot 'spec-pin-fail.ps1'
            Write-TestText $pinPath @'
param([switch]$Pin, [switch]$Verify, [switch]$Digest, [string]$Worktree, [string]$Label, [string]$PinDirectory)
if ($Pin -and $Label.EndsWith('-spec')) { Write-Output 'spec pin failed'; exit 23 }
& $env:ENGINE_TEST_REAL_TREE_PIN @PSBoundParameters
exit $LASTEXITCODE
'@
            $env:ENGINE_TEST_REAL_TREE_PIN = Join-Path $PSScriptRoot 'tree-pin.ps1'
        }
        $movement = Invoke-TestScenario -Name "spec-accept-$mutation" -Single -AcceptanceText $criteria -TreePinPath $pinPath
        Assert-Test "spec $mutation failure journals failed check/spec before parking without restoration" ($movement.result.code -eq 1 -and
            $movement.state.status -ceq 'parked' -and $movement.state.spec_acceptance.status -ceq 'failed' -and
            $movement.state.spec_acceptance.checks[0].status -ceq 'failed' -and $movement.state.integration.tip -cne $movement.state.base_sha -and
            $movement.state.handoff.status -ceq 'pending') $movement.result.output
        if ($mutation -ceq 'working') { Assert-Test 'spec working movement is retained' ([IO.File]::ReadAllText((Join-Path $movement.state.integration.worktree 'src/a.py')).Contains('movement')) '' }
        if ($mutation -ceq 'residue') { Assert-Test 'spec residue is retained' (Test-Path (Join-Path $movement.state.integration.worktree 'residue-untracked.txt')) '' }
        if ($mutation -in @('working', 'index')) {
            $movementResume = Invoke-TestEngine @('-Resume', $movement.state.run_id, '-StateRoot', $movement.state_root)
            $movementAgain = Get-TestOnlyState $movement.state_root
            Assert-Test "spec Resume refuses unrepaired $mutation tree instead of pinning it as new baseline" ($movementResume.code -eq 1 -and
                $movementAgain.spec_acceptance.status -ceq 'failed' -and $movementAgain.spec_acceptance.checks[0].status -ceq 'failed' -and
                $movementAgain.diagnosis -match 'differs from final wave commit') $movementResume.output
        }
    }
    Remove-Item Env:ENGINE_TEST_REAL_TREE_PIN -ErrorAction SilentlyContinue

    # A recorded running check survives the parent crash; Resume kills the old
    # launcher tree using both PID and stamp before executing the frozen check.
    $runningCriteria = @'
- [ ] Task 1 - crash child fixture
```powershell apex-accept
if ($env:ENGINE_TEST_ACCEPT_SLEEP -eq '1') { Start-Sleep -Seconds 60 }
exit 0
```
'@
    $env:ENGINE_TEST_ACCEPT_SLEEP = '1'; $env:APEX_ENGINE_TEST_CRASH_DURING_ACCEPTANCE = '1-1'
    $runningCrash = Invoke-TestScenario -Name 'accept-running-crash' -Single -AcceptanceText $runningCriteria
    Remove-Item Env:APEX_ENGINE_TEST_CRASH_DURING_ACCEPTANCE, Env:ENGINE_TEST_ACCEPT_SLEEP -ErrorAction SilentlyContinue
    $runningRecord = $runningCrash.state.tasks[0].acceptance[0]
    $wasLive = Test-RunnerPidLive $runningRecord.child_pid $runningRecord.child_start_time
    $descendantDeadline = (Get-Date).AddSeconds(5); $descendants = @()
    while ((Get-Date) -lt $descendantDeadline -and $descendants.Count -eq 0) {
        $descendants = @((Get-EngineDescendantProcessIds ([int]$runningRecord.child_pid)).process_ids | ForEach-Object {
            [pscustomobject]@{ pid_value = $_; stamp = (Get-RunnerProcessStamp $_) }
        })
        if ($descendants.Count -eq 0) { Start-Sleep -Milliseconds 100 }
    }
    $runningResume = Invoke-TestEngine @('-Resume', $runningCrash.state.run_id, '-StateRoot', $runningCrash.state_root)
    $runningAfter = Get-TestOnlyState $runningCrash.state_root
    Assert-Test 'running check crash saves PID/stamp then Resume kills original tree and reruns' ($wasLive -and
        $runningRecord.status -ceq 'running' -and $runningResume.code -eq 0 -and
        -not (Test-RunnerPidLive $runningRecord.child_pid $runningRecord.child_start_time) -and
        $runningAfter.tasks[0].acceptance[0].status -ceq 'passed' -and $runningAfter.counters.dispatches -eq 1) $runningResume.output
    Assert-Test 'running check Resume kills recorded launcher descendants' ($descendants.Count -gt 0 -and
        @($descendants | Where-Object { Test-RunnerPidLive $_.pid_value $_.stamp }).Count -eq 0) ($descendants | ConvertTo-Json -Compress)

    # Optional additions enforce exact object shapes; stripped schema-v1 states
    # still resume and teardown with the original rules.
    $acceptSchema = Get-Content $schemaPath -Raw | ConvertFrom-Json
    foreach ($newState in @($acceptAfter, $specAfter)) {
        $shapeError = ''; try { Test-Structure $newState $acceptSchema } catch { $shapeError = $_.Exception.Message }
        Assert-Test 'acceptance state optional exact schema shapes' ([string]::IsNullOrEmpty($shapeError)) $shapeError
    }
    foreach ($shape in @('plan-check', 'host-check', 'task-record', 'spec-record', 'spec-runtime')) {
        $invalid = ($acceptAfter | ConvertTo-Json -Depth 100) | ConvertFrom-Json
        $target = switch ($shape) {
            'plan-check' { $invalid.plan.waves[0].tasks[0].acceptance_checks[0] }
            'host-check' { $invalid.plan.host_checks[0] }
            'task-record' { $invalid.tasks[0].acceptance[0] }
            'spec-record' { $invalid = ($specAfter | ConvertTo-Json -Depth 100) | ConvertFrom-Json; $invalid.spec_acceptance.checks[0] }
            'spec-runtime' { $invalid = ($specAfter | ConvertTo-Json -Depth 100) | ConvertFrom-Json; $invalid.spec_acceptance }
        }
        $target | Add-Member -NotePropertyName unexpected -NotePropertyValue 'reject'
        $errorText = ''; try { Test-Structure $invalid $acceptSchema } catch { $errorText = $_.Exception.Message }
        Assert-Test "acceptance $shape forbids additional properties" ($errorText -match 'unexpected key') $errorText
    }

    # Complete discard permits repaired main trees, but its reason guard precedes
    # adoption. Exercise dead-row adoption using the real teardown ordering and
    # deterministic adopter results, without another model dispatch.
    $script:EngineState = ($acceptAfter | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    $script:EngineStatePath = (Get-TestOnlyStateFile $acceptRetry.state_root).FullName
    $script:EngineStateRoot = $acceptRetry.state_root
    $script:EngineState.handoff.journaled_paths = @(); Save-RunnerState
    $adoptCount = 0; $originalAdopt = ${function:Invoke-EngineAdopt}; $originalRows = ${function:Read-EngineLedgerRows}
    $originalRemove = ${function:Remove-EngineRunWorktrees}
    $script:TeardownTestRow = [pscustomobject]@{ run_id = ('e' * 32); status = 'running'; pid = 0; launcher_pid = 0;
        spec = $acceptAfter.spec.name; task = '1'; worktree = $acceptAfter.tasks[0].attempts[0].worktree }
    function Read-EngineLedgerRows { param($LedgerPath) return @($script:TeardownTestRow) }
    function Invoke-EngineAdopt {
        param($WrapperPath, $RunId, $Spec, $Task, $Worktree, $StateRoot, $ChildOutputPath)
        $script:adoptCount++
        Assert-Test 'teardown adopter receives attempt identities and run-local output' ($Spec -ceq $script:TeardownTestRow.spec -and
            $Task -ceq $script:TeardownTestRow.task -and $RunId -ceq $script:TeardownTestRow.run_id -and
            $Worktree -ceq $script:TeardownTestRow.worktree -and $ChildOutputPath.StartsWith((Split-Path $script:EngineStatePath -Parent))) $ChildOutputPath
        if ($script:AdoptTestMode -ceq 'success') { $script:TeardownTestRow.status = 'adopted-done' }
        [pscustomobject]@{ exit_code = $(if ($script:AdoptTestMode -ceq 'nonzero') { 1 } else { 0 }); adopt_timed_out = ($script:AdoptTestMode -ceq 'timeout') }
    }
    function Remove-EngineRunWorktrees { param($Repo, $Spec, $Branches, $Worktrees, $OnItemRemoved) [pscustomobject]@{ ok = $true } }
    $Discard = $true
    try {
        foreach ($reasonText in @('', '   ')) {
            $Reason = $reasonText; $refusal = ''
            try { Invoke-RunnerTeardown $acceptAfter.run_id } catch { $refusal = $_.Exception.Message } finally { Close-RunnerRunLock }
            Assert-Test 'missing complete discard reason refuses before adoption' ($refusal -match 'non-empty -Reason' -and $script:adoptCount -eq 0) $refusal
        }
        $Reason = 'owner repaired the main tree'; $script:AdoptTestMode = 'success'
        $script:TeardownTestRow.status = 'done'; $script:TeardownTestRow.pid = $PID
        $script:TeardownTestRow | Add-Member -NotePropertyName pid_start -NotePropertyValue (Get-RunnerProcessStamp $PID) -Force
        $liveTerminalRefusal = ''
        try { Invoke-RunnerTeardown $acceptAfter.run_id } catch { $liveTerminalRefusal = $_.Exception.Message } finally { Close-RunnerRunLock }
        Assert-Test 'teardown tests PID liveness even for terminal matching ledger row' ($liveTerminalRefusal -match 'live ledger row' -and $script:adoptCount -eq 0) $liveTerminalRefusal
        $script:TeardownTestRow.pid = 0
        foreach ($adoptMode in @('timeout', 'nonzero', 'nonterminal', 'success')) {
            $script:AdoptTestMode = $adoptMode; $script:TeardownTestRow.status = 'running'; $refusal = ''
            try { Invoke-RunnerTeardown $acceptAfter.run_id } catch { $refusal = $_.Exception.Message } finally { Close-RunnerRunLock }
            Assert-Test "complete discard dead-row adoption $adoptMode" `
                ($(if ($adoptMode -ceq 'success') { $refusal -ceq '' -and $script:EngineState.teardown.reason -ceq $Reason }
                else { $refusal -match 'adoption failed' })) $refusal
        }
    } finally {
        Close-RunnerRunLock; $Discard = $false; $Reason = $null
        Set-Item Function:Invoke-EngineAdopt $originalAdopt; Set-Item Function:Read-EngineLedgerRows $originalRows
        Set-Item Function:Remove-EngineRunWorktrees $originalRemove
    }
    $invalidReason = Invoke-TestEngine @('-Reason', 'invalid')
    $invalidReasonTeardown = Invoke-TestEngine @('-Teardown', $acceptAfter.run_id, '-StateRoot', $acceptRetry.state_root, '-Reason', 'invalid')
    Assert-Test 'Reason CLI requires Teardown and Discard' ($invalidReason.code -eq 1 -and $invalidReason.output.Contains('-Reason requires both') -and
        $invalidReasonTeardown.code -eq 1 -and $invalidReasonTeardown.output.Contains('-Reason requires both')) $invalidReasonTeardown.output
    $mainHead = (Invoke-TestGit $acceptRetry.repo @('rev-parse', 'HEAD'))[-1]
    Assert-Test 'complete discard fixture main HEAD differs from integration tip' ($mainHead -cne $acceptAfter.integration.tip) ''
    $repairDiscard = Invoke-TestEngine @('-Teardown', $acceptAfter.run_id, '-Discard', '-Reason', 'repaired close-out', '-StateRoot', $acceptRetry.state_root)
    $repairState = Get-TestOnlyState $acceptRetry.state_root
    Assert-Test 'complete repaired discard bypasses proof journals reason and tears down' ($repairDiscard.code -eq 0 -and
        $repairState.teardown.status -ceq 'complete' -and $repairState.teardown.reason -ceq 'repaired close-out') $repairDiscard.output
    $reasonSchemaError = ''; try { Test-Structure $repairState $acceptSchema } catch { $reasonSchemaError = $_.Exception.Message }
    Assert-Test 'complete discard reason passes schema' ($reasonSchemaError -ceq '') $reasonSchemaError

    $legacy = ($runningAfter | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    $legacy.plan.PSObject.Properties.Remove('spec_acceptance_checks'); $legacy.plan.PSObject.Properties.Remove('host_checks')
    foreach ($wave in $legacy.plan.waves) { foreach ($task in $wave.tasks) { $task.PSObject.Properties.Remove('acceptance_checks') } }
    foreach ($task in $legacy.tasks) { $task.PSObject.Properties.Remove('acceptance'); foreach ($attempt in $task.attempts) { $attempt.PSObject.Properties.Remove('acceptance_output_tail') } }
    $legacy.PSObject.Properties.Remove('spec_acceptance'); $legacy.teardown.PSObject.Properties.Remove('reason'); $legacy.status = 'parked'
    Write-TestText (Get-TestOnlyStateFile $runningCrash.state_root).FullName ($legacy | ConvertTo-Json -Depth 100)
    $legacySchemaError = ''; try { Test-Structure $legacy $acceptSchema } catch { $legacySchemaError = $_.Exception.Message }
    $legacyResume = Invoke-TestEngine @('-Resume', $legacy.run_id, '-StateRoot', $runningCrash.state_root)
    $legacyParent = (Invoke-TestGit $runningCrash.repo @('rev-parse', 'HEAD'))[-1]
    [void](Set-TestCommit $runningCrash.repo @('src/a.py') $legacyParent)
    $legacyDiscard = Invoke-TestEngine @('-Teardown', $legacy.run_id, '-StateRoot', $runningCrash.state_root)
    Assert-Test 'legacy schema-v1 state without additions Resume and Teardown' ($legacySchemaError -ceq '' -and
        $legacyResume.code -eq 0 -and $legacyDiscard.code -eq 0) "$legacySchemaError; $($legacyResume.output); $($legacyDiscard.output)"

    $script:EngineState = ($specAfter | ConvertTo-Json -Depth 100) | ConvertFrom-Json
    $script:EngineStatePath = (Get-TestOnlyStateFile $specFailure.state_root).FullName
    $script:EngineLedgerPath = Join-Path $specFailure.state_root 'progress/codex-run-ledger.jsonl'
    foreach ($summaryCase in @(
        @{ status = 'complete'; teardown = 'pending'; next = "Next: run HOST checks, review, commit, then -Teardown $($specAfter.run_id)." },
        @{ status = 'parked'; teardown = 'pending'; next = "Next: inspect the diagnosis, then -Resume $($specAfter.run_id) or -Teardown $($specAfter.run_id) -Discard." },
        @{ status = 'partial'; teardown = 'pending'; next = "Next: inspect failed tasks, then -Resume $($specAfter.run_id) or -Teardown $($specAfter.run_id) -Discard." },
        @{ status = 'refused'; teardown = 'pending'; next = 'Next: fix the inputs and start a new run' },
        @{ status = 'complete'; teardown = 'complete'; next = 'Next: teardown complete; no further action.' },
        @{ status = 'complete'; teardown = 'failed'; next = "Next: resolve teardown refusal, then retry -Teardown $($specAfter.run_id); after repair use -Discard -Reason <text>." }
    )) {
        $script:EngineState.status = $summaryCase.status; $script:EngineState.teardown.status = $summaryCase.teardown
        $printed = @(Write-RunnerSummary 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
        Assert-Test "summary $($summaryCase.status)/$($summaryCase.teardown) exact next line" ($printed.Contains($summaryCase.next)) $printed
    }
    Remove-Item Env:ENGINE_TEST_ACCEPT_COUNTER, Env:ENGINE_TEST_SPEC_FAIL -ErrorAction SilentlyContinue

    $testRunIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($engineStateFile in @(Get-ChildItem -LiteralPath $testRoot -Filter engine-state.json -Recurse -File -ErrorAction SilentlyContinue)) {
        try { $engineStateDocument = Get-Content -LiteralPath $engineStateFile.FullName -Raw | ConvertFrom-Json }
        catch { continue }
        if ($engineStateDocument.PSObject.Properties['run_id'] -and $engineStateDocument.run_id) {
            [void]$testRunIds.Add([string]$engineStateDocument.run_id)
        }
        if ($engineStateDocument.PSObject.Properties['tasks']) {
            foreach ($engineTask in @($engineStateDocument.tasks)) {
                if (-not $engineTask.PSObject.Properties['attempts']) { continue }
                foreach ($engineAttempt in @($engineTask.attempts)) {
                    if ($engineAttempt.PSObject.Properties['wrapper_run_id'] -and $engineAttempt.wrapper_run_id) {
                        [void]$testRunIds.Add([string]$engineAttempt.wrapper_run_id)
                    }
                }
            }
        }
    }
    foreach ($testLedger in @(Get-ChildItem -LiteralPath $testRoot -Filter codex-run-ledger.jsonl -Recurse -File -ErrorAction SilentlyContinue)) {
        foreach ($testLedgerLine in @([IO.File]::ReadAllLines($testLedger.FullName))) {
            try { $testLedgerRow = $testLedgerLine | ConvertFrom-Json }
            catch { continue }
            foreach ($identityName in @('run_id', 'wrapper_run_id')) {
                if ($testLedgerRow.PSObject.Properties[$identityName] -and $testLedgerRow.$identityName) {
                    [void]$testRunIds.Add([string]$testLedgerRow.$identityName)
                }
            }
        }
    }
    $machineViolations = @()
    if (Test-Path -LiteralPath $machineLedger -PathType Leaf) {
        foreach ($machineLine in @([IO.File]::ReadAllLines($machineLedger))) {
            try { $machineRow = $machineLine | ConvertFrom-Json }
            catch { continue }
            $machineRunId = $null
            if ($machineRow.PSObject.Properties['run_id']) { $machineRunId = [string]$machineRow.run_id }
            if (($machineRunId -and $testRunIds.Contains($machineRunId)) -or
                    (Test-TestValueContainsRoot $machineRow $testRoot)) {
                $machineViolations += $machineLine
            }
        }
    }
    Assert-Test 'machine-ledger isolation' ($machineViolations.Count -eq 0) ($machineViolations -join "`n")
} catch {
    $failures++
    Write-Host "FAIL: unexpected exception -- $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
} finally {
    Remove-Item Env:ENGINE_TEST_GATE_COUNTER, Env:ENGINE_TEST_BASELINE_EXIT, Env:ENGINE_TEST_VERIFY_SEQUENCE,
        Env:ENGINE_TEST_PIN_EXIT, Env:ENGINE_TEST_REAL_TREE_PIN, Env:ENGINE_TEST_STAGE_MARKER,
        Env:ENGINE_TEST_STAGE_PIN_EXIT, Env:ENGINE_TEST_STAGE_PIN_COUNT, Env:ENGINE_TEST_STAGE_VERIFY_COUNT,
        Env:ENGINE_TEST_STAGE_VERIFY_SEQUENCE, Env:ENGINE_TEST_CRITICAL_COUNTER, Env:ENGINE_TEST_CRITICAL_SEQUENCE `
        -ErrorAction SilentlyContinue
    Remove-Item Env:APEX_ENGINE_TEST_CRASH_AFTER_VERIFICATION_FAILURE -ErrorAction SilentlyContinue
    Remove-Item Env:APEX_ENGINE_TEST_ACCEPT_TIMEOUT_MS, Env:APEX_ENGINE_TEST_CRASH_DURING_ACCEPTANCE,
        Env:ENGINE_TEST_ACCEPT_COUNTER, Env:ENGINE_TEST_ACCEPT_SLEEP, Env:ENGINE_TEST_SPEC_FAIL, Env:ENGINE_TEST_BASELINE_SEQUENCE -ErrorAction SilentlyContinue
    $env:APEX_ENGINE_TEST_STAGE_TRACE_PATH = $oldStageTrace
    $env:APEX_STATE_DIR = $oldState
    $env:LOCALAPPDATA = $oldLocalAppData
    $env:APEX_ENGINE_TEST_RETRY_DELAY_SECONDS = $oldRetry
    $env:GIT_CONFIG_GLOBAL = $oldGlobal
    $env:APEX_ENGINE_TEST_MODE = $oldTestMode
    $env:APEX_ENGINE_TEST_IMPORT_ONLY = $oldImportOnly
    $env:ENGINE_TEST_FAKE_SCENARIO = $oldScenario
    $env:ENGINE_TEST_FAKE_DELAY = $oldDelay
    $env:APEX_ENGINE_TEST_BASELINE_PATH = $oldBaselinePath
    $env:APEX_ENGINE_TEST_TREE_PIN_PATH = $oldTreePinPath
    $env:APEX_ENGINE_TEST_CRITICAL_PATH = $oldCriticalPath
    $env:APEX_ENGINE_TEST_IGNORE_RESUME_LEDGER = $oldIgnoreLedger
    $env:APEX_ENGINE_TEST_CRASH_AFTER_WAVE_COMMIT = $oldCommitCrash
    $env:APEX_ENGINE_TEST_CRASH_AFTER_VERIFICATION_FAILURE = $oldLadderCrash
    $env:APEX_ENGINE_TEST_FAIL_BEFORE_HANDOFF_JOURNAL = $oldHandoffCrash
    $env:APEX_ENGINE_TEST_FAIL_INDEX_IDENTITY = $oldIdentityFailure
    $env:APEX_ENGINE_TEST_FAIL_WRITE_TREE = $oldWriteTreeFailure
    $env:APEX_ENGINE_TEST_FAIL_RESIDUE_CAPTURE = $oldResidueCaptureFailure
    $env:APEX_ENGINE_TEST_FAIL_AGENTS_FETCH = $oldAgentsFetchFailure
    $env:APEX_ENGINE_TEST_AGENTS_FETCH_TRACE_PATH = $oldAgentsFetchTrace
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $machineLocalRoot) { Remove-Item -LiteralPath $machineLocalRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures -gt 0) { Write-Host "engine-test: $failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'engine-test: all cases passed' -ForegroundColor Green
exit 0
