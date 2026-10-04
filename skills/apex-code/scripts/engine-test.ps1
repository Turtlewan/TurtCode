[CmdletBinding()]
param()

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

function Write-TestText {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
    [IO.File]::WriteAllText($Path, $Text, $utf8)
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
    param([string]$Name)
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
'@
    [void](Set-TestCommit $repo @('.gitignore', '.gitattributes', 'src/a.py', 'verify.ps1', 'AGENTS.md') $null)
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
        [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')][string]$Effort = 'medium'
    )
    $emDash = [string][char]0x2014
    $firstPath = if ($Critical) { '.github/workflows/build.yml' } else { 'src/a.py' }
    $firstOp = if ($Critical) { 'create' } else { 'modify' }
    $omitSecond = $Critical -or $Single
    $secondTask = if ($omitSecond) { '' } else { "- [ ] **Task $SecondId** - Create the second fixture file. $emDash files: src/b.py $emDash done when: the second fixture file exists." }
    $secondManifest = if ($omitSecond) { '' } else { ", { `"id`": `"$SecondId`", `"repo`": `"main`", `"files`": [{ `"path`": `"src/b.py`", `"op`": `"create`" }], `"depends_on`": [] }" }
    $secondAcceptance = if ($omitSecond) { '' } else { "- [ ] Task $SecondId - second file is executable -> verify: run the fixture command." }
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    $repoJson = (Convert-TestPath $Repo).Replace('\', '\\').Replace('"', '\"')
    $text = @"
---
spec: $name
status: approved
autonomy_level: L2
risk: medium
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
- Tasks 1 and 2 are parallel.

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
    $payload = if ($scenario -ceq 'always_verify_fail') { 'VERIFY_FAIL-one' } else { 'fake-one' }
    [IO.File]::AppendAllText((Join-Path $repo 'src\a.py'), "$payload`r`n", [Text.UTF8Encoding]::new($false))
    $changed = @('src/a.py')
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
    Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
}

function Invoke-TestScenario {
    param(
        [string]$Name, [string]$Scenario = 'done', [string]$Effort = 'medium',
        [switch]$Single, [string]$FirstId = '1', [string]$SecondId = '2',
        [AllowNull()][string]$BaselinePath, [AllowNull()][string]$TreePinPath,
        [AllowNull()][string]$CriticalPath
    )
    $repoPath = New-TestRepo "$Name-repo"
    $specPath = Join-Path $testRoot "$Name.md"
    New-TestSpec $repoPath $specPath -Single:$Single -FirstId $FirstId -SecondId $SecondId -Effort $Effort
    $statePath = Join-Path $testRoot "$Name-state"
    $worktrees = Join-Path $testRoot "$Name-worktrees"
    $oldScenario = $env:ENGINE_TEST_FAKE_SCENARIO
    $oldBaselinePath = $env:APEX_ENGINE_TEST_BASELINE_PATH
    $oldTreePinPath = $env:APEX_ENGINE_TEST_TREE_PIN_PATH
    $oldCriticalPath = $env:APEX_ENGINE_TEST_CRITICAL_PATH
    try {
        $env:ENGINE_TEST_FAKE_SCENARIO = $Scenario
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
    }
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
        run_id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; status = 'running'; diagnosis = $null
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
    $state = if ($stateFiles.Count -eq 1) { Get-Content $stateFiles[0].FullName -Raw | ConvertFrom-Json } else { $null }
    $childDiagnostics = ''
    if ($null -ne $state) { foreach ($task in @($state.tasks)) { foreach ($attempt in @($task.attempts)) {
        if (Test-Path -LiteralPath $attempt.child_output_path) { $childDiagnostics += "`n[$($task.id)/$($attempt.number)] " + [IO.File]::ReadAllText($attempt.child_output_path) }
    } } }
    Assert-Test 'real wrapper fake Codex two-path reachability and hand-off' `
        ($run.code -eq 0 -and $null -ne $state -and $state.status -ceq 'complete' -and
            (Test-Path (Join-Path $repo 'src\b.py')) -and ([IO.File]::ReadAllText((Join-Path $repo 'src\a.py')) -match 'fake-one')) `
        "exit=$($run.code); output=$($run.output); children=$childDiagnostics"
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

    $riskHighSpec = Join-Path $testRoot 'risk-high-refused.md'
    New-TestSpec $repo $riskHighSpec -Single
    Write-TestText $riskHighSpec (([IO.File]::ReadAllText($riskHighSpec)).Replace('risk: medium', 'risk: high'))
    $riskHighStateRoot = Join-Path $testRoot 'risk-high-refused-state'
    $riskHighRun = Invoke-TestEngine @('-SpecPath', $riskHighSpec, '-Repo', $repo,
        '-StateRoot', $riskHighStateRoot, '-WorktreeRoot', (Join-Path $testRoot 'risk-high-refused-wt'))
    $riskHighState = Get-TestOnlyState $riskHighStateRoot
    $riskHighSchemaOk = $true; $riskHighSchemaError = ''
    try { Test-Structure $riskHighState (Get-Content $schemaPath -Raw | ConvertFrom-Json) }
    catch { $riskHighSchemaOk = $false; $riskHighSchemaError = $_.Exception.Message }
    Assert-Test 'risk high refusal persists schema-valid loose refused plan' `
        ($riskHighRun.code -ne 0 -and $riskHighState.status -ceq 'refused' -and
            $riskHighState.plan.allowed -eq $false -and $riskHighState.plan.spec.risk -ceq 'high' -and $riskHighSchemaOk) `
        "output=$($riskHighRun.output); schema=$riskHighSchemaError"

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
    Write-TestText $gateBaseline @'
param([switch]$Full, [string]$Worktree)
$counter = Join-Path $env:ENGINE_TEST_GATE_COUNTER 'baseline.txt'
$count = if (Test-Path $counter) { [int](Get-Content $counter -Raw) } else { 0 }
$count++; [IO.File]::WriteAllText($counter, [string]$count)
Write-Host "baseline diagnosis $env:ENGINE_TEST_BASELINE_EXIT"
exit ([int]$env:ENGINE_TEST_BASELINE_EXIT)
'@
    function Stage-EngineWave { param($IntegrationWorktree, $Files) [pscustomobject]@{ ok = $script:TestStageOk; failures = @() } }
    $script:EngineTreePinScript = $gatePin; $script:EngineBaselineScript = $gateBaseline; $script:TestStageOk = $true
    $gateContext = New-TestRouteContext
    $gateRepo = New-TestRepo 'gate-unit-repo'
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
        }
        [IO.File]::AppendAllText($ledgerPath, (($lease | ConvertTo-Json -Compress) + "`n"), $utf8)
        $liveRowRefusal = Invoke-TestEngine @('-Teardown', $state.run_id, '-StateRoot', $stateRoot, '-WorktreeRoot', $worktreeRoot)
        [IO.File]::WriteAllBytes($ledgerPath, $ledgerBytes)
        Write-TestText $stateFiles[0].FullName ($state | ConvertTo-Json -Depth 100)
        Assert-Test 'teardown refuses live recorded child PID and leasing ledger row' `
            ($livePidRefusal.code -ne 0 -and $livePidRefusal.output -match 'live recorded child_pid' -and
                $liveRowRefusal.code -ne 0 -and $liveRowRefusal.output -match 'non-terminal ledger row') `
            "pid=$($livePidRefusal.output); row=$($liveRowRefusal.output)"

        $parent = (Invoke-TestGit $repo @('rev-parse', 'HEAD'))[-1]
        [void](Set-TestCommit $repo @('src/a.py', 'src/b.py') $parent)
        $completeTeardownResult = Invoke-TestEngine @('-Teardown', $state.run_id, '-StateRoot', $stateRoot, '-WorktreeRoot', $worktreeRoot)
        $afterTeardown = Get-Content $stateFiles[0].FullName -Raw | ConvertFrom-Json
        Assert-Test 'complete teardown with proof and durable per-item journal' `
            ($completeTeardownResult.code -eq 0 -and $afterTeardown.teardown.status -ceq 'complete' -and @($afterTeardown.teardown.items).Count -eq 6) `
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
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $machineLocalRoot) { Remove-Item -LiteralPath $machineLocalRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures -gt 0) { Write-Host "engine-test: $failures failure(s)" -ForegroundColor Red; exit 1 }
Write-Host 'engine-test: all cases passed' -ForegroundColor Green
exit 0
