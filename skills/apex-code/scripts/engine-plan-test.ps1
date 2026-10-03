[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$planner = Join-Path $PSScriptRoot 'engine-plan.ps1'
$realValidator = Join-Path $PSScriptRoot 'apex-spec-validate.ps1'
$testRoot = Join-Path $env:TEMP ('engine-plan-test-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object System.Text.UTF8Encoding($false)
$failures = 0
$assertions = 0

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Invoke-GitQuiet {
    param([string]$Repo, [string[]]$Arguments)
    $output = @(& git -C $Repo @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) { throw ('git failed: ' + ($output -join ' | ')) }
    return ,$output
}

function New-TestRepo {
    $path = Join-Path $testRoot ('repo-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $path -Force)
    [void](Invoke-GitQuiet -Repo $path -Arguments @('init', '-q'))
    Write-Utf8 -Path (Join-Path $path 'AGENTS.md') -Text @'
# Test repository

## Verify commands

```
node --check exact-one.js
powershell.exe -NoProfile -File exact-two.ps1
```

## Preflight commands

```
node --check exact-one.js
```
'@
    return $path
}

function Set-TestCommit {
    param([string]$Repo, [string[]]$Paths)
    foreach ($relative in $Paths) {
        $full = Join-Path $Repo ($relative.Replace('/', [char]92))
        $hash = (Invoke-GitQuiet -Repo $Repo -Arguments @('hash-object', '-w', '--', $full))[-1]
        [void](Invoke-GitQuiet -Repo $Repo -Arguments @('update-index', '--add', '--cacheinfo', ('100644,{0},{1}' -f $hash, $relative)))
    }
    $tree = (Invoke-GitQuiet -Repo $Repo -Arguments @('write-tree'))[-1]
    $oldEmail = $env:GIT_AUTHOR_EMAIL
    $oldName = $env:GIT_AUTHOR_NAME
    $oldCommitterEmail = $env:GIT_COMMITTER_EMAIL
    $oldCommitterName = $env:GIT_COMMITTER_NAME
    try {
        $env:GIT_AUTHOR_EMAIL = 'fixture@example.invalid'
        $env:GIT_AUTHOR_NAME = 'Fixture'
        $env:GIT_COMMITTER_EMAIL = 'fixture@example.invalid'
        $env:GIT_COMMITTER_NAME = 'Fixture'
        $commit = @('fixture' | & git -C $Repo commit-tree $tree 2>&1 | ForEach-Object { $_.ToString() })[-1]
        if ($LASTEXITCODE -ne 0) { throw 'git commit-tree failed' }
        [void](Invoke-GitQuiet -Repo $Repo -Arguments @('update-ref', 'HEAD', $commit))
    }
    finally {
        $env:GIT_AUTHOR_EMAIL = $oldEmail
        $env:GIT_AUTHOR_NAME = $oldName
        $env:GIT_COMMITTER_EMAIL = $oldCommitterEmail
        $env:GIT_COMMITTER_NAME = $oldCommitterName
    }
}

function ConvertTo-ForwardPath {
    param([string]$Path)
    return ([System.IO.Path]::GetFullPath($Path)).Replace([char]92, [char]47).TrimEnd('/')
}

function New-ManifestJson {
    param(
        [string]$Repo,
        [object[]]$Tasks,
        [switch]$TwoRepos,
        [string]$RepoOverride
    )
    $root = ConvertTo-ForwardPath -Path $Repo
    if (-not [string]::IsNullOrEmpty($RepoOverride)) { $root = $RepoOverride }
    $repos = [ordered]@{ main = $root }
    if ($TwoRepos) { $repos['other'] = $root }
    return ([ordered]@{ version = 1; repos = $repos; tasks = @($Tasks) } | ConvertTo-Json -Depth 10)
}

function New-Task {
    param([string]$Id, [object[]]$Files, [string[]]$Depends = @(), [string]$Effort)
    $task = [ordered]@{ id = $Id; repo = 'main'; files = @($Files); depends_on = @($Depends) }
    if (-not [string]::IsNullOrEmpty($Effort)) { $task['effort'] = $Effort }
    return [pscustomobject]$task
}

function New-File {
    param([string]$Path, [string]$Op = 'create')
    return [pscustomobject][ordered]@{ path = $Path; op = $Op }
}

function New-SpecText {
    param(
        [string]$Name,
        [string]$Manifest,
        [object[]]$Tasks,
        [string]$Risk = 'medium',
        [string]$CoderModel,
        [string]$CoderEffort = 'medium',
        [object]$MaxParallelCodex = $null,
        [string]$Intent = '- **Intent:** Build the fixture.',
        [string]$Assumptions = '- The fixture environment is available.',
        [string]$Specialist = "### Security`nKeep fixture writes scoped.`n`n### Accessibility`n(none)",
        [switch]$NoSpec,
        [string]$SpecIdentity,
        [switch]$NoManifest,
        [switch]$DuplicateManifest
    )
    $front = New-Object 'System.Collections.Generic.List[string]'
    [void]$front.Add('---')
    if (-not $NoSpec) {
        if ([string]::IsNullOrEmpty($SpecIdentity)) { $SpecIdentity = $Name }
        [void]$front.Add('spec: ' + $SpecIdentity)
    }
    if ($null -ne $Risk) { [void]$front.Add('risk: ' + $Risk) }
    if (-not [string]::IsNullOrEmpty($CoderModel)) { [void]$front.Add('coder_model: ' + $CoderModel) }
    if ($null -ne $CoderEffort) { [void]$front.Add('coder_effort: ' + $CoderEffort) }
    if ($null -ne $MaxParallelCodex) { [void]$front.Add('max_parallel_codex: ' + $MaxParallelCodex) }
    [void]$front.Add('---')

    $fileRows = New-Object 'System.Collections.Generic.List[string]'
    $taskRows = New-Object 'System.Collections.Generic.List[string]'
    $acceptanceRows = New-Object 'System.Collections.Generic.List[string]'
    $emDash = [string][char]0x2014
    foreach ($task in $Tasks) {
        foreach ($file in @($task.files)) { [void]$fileRows.Add('| ' + $file.path + ' | ' + $file.op + ' | fixture |') }
        $paths = @($task.files | ForEach-Object { $_.path }) -join ', '
        [void]$taskRows.Add(('- [ ] **Task {0}** - Implement task {0} exactly. {1} files: {2} {1} done when: task {0} is complete.' -f $task.id, $emDash, $paths))
        [void]$acceptanceRows.Add(('- [ ] Task {0} - task {0} is executable -> verify: run the fixture command.' -f $task.id))
    }
    $manifestBlock = ''
    if (-not $NoManifest) {
        $fence = (([string][char]96) * 3) -join ''
        $manifestBlock = $fence + "json apex-manifest`n$Manifest`n" + $fence
        if ($DuplicateManifest) { $manifestBlock += "`n`n" + $fence + "json apex-manifest`n$Manifest`n" + $fence }
    }
    return ((@($front.ToArray()) + @(
        '',
        '# Planner fixture',
        '',
        ('**Identity:** Fixture identity for ' + $Name + '.'),
        '',
        '## Intent',
        $Intent,
        '',
        '## Assumptions',
        $Assumptions,
        '',
        '## Prerequisites',
        '- Windows PowerShell is available.',
        '',
        '## Files to Change',
        '| File | Operation | Notes |',
        '|---|---|---|',
        ($fileRows.ToArray() -join "`n"),
        '',
        '## Execution manifest',
        $manifestBlock,
        '',
        '## Tasks',
        ($taskRows.ToArray() -join "`n"),
        '',
        '## Wave plan',
        'This prose is deliberately non-authoritative.',
        '',
        '## Permissions',
        '- The fixture paths may be changed.',
        '',
        '## Specialist Context',
        $Specialist,
        '',
        '## Documentation',
        '- No documentation changes are required.',
        '',
        '## Acceptance Criteria',
        ($acceptanceRows.ToArray() -join "`n"),
        '',
        '## Progress',
        '- Not started.'
    )) -join "`n") + "`n"
}

function New-Fixture {
    param(
        [string]$Name = 'fixture-plan',
        [object[]]$Tasks,
        [hashtable]$SpecOptions = @{},
        [switch]$TwoRepos,
        [string]$RepoOverride
    )
    $repo = New-TestRepo
    if ($null -eq $Tasks) { $Tasks = @(New-Task -Id '1' -Files @(New-File -Path 'src/new.txt')) }
    $manifest = New-ManifestJson -Repo $repo -Tasks $Tasks -TwoRepos:$TwoRepos -RepoOverride $RepoOverride
    $textArgs = @{ Name = $Name; Manifest = $manifest; Tasks = $Tasks }
    foreach ($key in $SpecOptions.Keys) { $textArgs[$key] = $SpecOptions[$key] }
    $specDir = Join-Path $testRoot ('spec-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $specDir -Force)
    $spec = Join-Path $specDir ($Name + '.md')
    Write-Utf8 -Path $spec -Text (New-SpecText @textArgs)
    return [pscustomobject]@{ Repo = $repo; Spec = $spec; Tasks = $Tasks; Manifest = $manifest }
}

function Invoke-Plan {
    param([object]$Fixture, [int]$MaxParallel = 2, [string]$Validator = $script:successValidator)
    return Get-EnginePlan -SpecPath $Fixture.Spec -Repo $Fixture.Repo -MaxParallel $MaxParallel -ValidatorPath $Validator
}

function Assert-Case {
    param([string]$Name, [scriptblock]$Test)
    $script:assertions++
    try {
        $passed = [bool](& $Test)
        if ($passed) { Write-Host ('  PASS  ' + $Name) -ForegroundColor Green; return }
        throw 'assertion returned false'
    }
    catch {
        $script:failures++
        Write-Host ('  FAIL  {0}: {1}' -f $Name, $_.Exception.Message) -ForegroundColor Red
    }
}

try {
    [void](New-Item -ItemType Directory -Path $testRoot -Force)
    $successValidator = Join-Path $testRoot 'validator-success.ps1'
    $failureValidator = Join-Path $testRoot 'validator-failure.ps1'
    Write-Utf8 -Path $successValidator -Text "param([string]`$SpecPath)`nWrite-Output VALIDATOR-SEAM`nexit 0`n"
    Write-Utf8 -Path $failureValidator -Text "param([string]`$SpecPath)`nWrite-Output REFUSED-BY-SEAM`nexit 17`n"
    . $planner

    Assert-Case 'dot-source preserves caller parameters EAP and StrictMode' {
        $child = Join-Path $testRoot 'dot-source-child.ps1'
        $escapedPlanner = $planner.Replace("'", "''")
        Write-Utf8 -Path $child -Text @"
param(
    [string]`$SpecPath,
    [string]`$Repo,
    [int]`$MaxParallel
)
`$ErrorActionPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
`$beforeEap = `$ErrorActionPreference
. '$escapedPlanner'
`$strictPreserved = `$false
try { `$null = `$variableThatMustNotExist }
catch { `$strictPreserved = `$true }
[pscustomobject]@{
    SpecPath = `$SpecPath
    Repo = `$Repo
    MaxParallel = `$MaxParallel
    ErrorActionPreference = [string]`$ErrorActionPreference
    StrictModePreserved = `$strictPreserved
    AddedJson = [bool](Test-Path Variable:Json)
    AddedValidatorPath = [bool](Test-Path Variable:ValidatorPath)
} | ConvertTo-Json -Compress
"@
        $output = @(& powershell.exe -NoProfile -File $child -SpecPath 'spec-sentinel' -Repo 'repo-sentinel' -MaxParallel 7)
        if ($LASTEXITCODE -ne 0) { return $false }
        $observed = ($output -join "`n") | ConvertFrom-Json
        $preserved = $observed.SpecPath -ceq 'spec-sentinel' -and $observed.Repo -ceq 'repo-sentinel' -and
            $observed.MaxParallel -eq 7 -and $observed.ErrorActionPreference -ceq 'SilentlyContinue' -and
            $observed.StrictModePreserved -and -not $observed.AddedJson -and -not $observed.AddedValidatorPath
        if (-not $preserved) { throw ('dot-source state changed: ' + ($observed | ConvertTo-Json -Compress)) }
        return $true
    }

    Assert-Case 'validator real success and pinned plan shape' {
        $fixture = New-Fixture
        $plan = Invoke-Plan -Fixture $fixture -Validator $realValidator
        if (-not $plan.allowed) {
            $debugText = [System.IO.File]::ReadAllText($fixture.Spec)
            throw ('baseline refusal: ' + $plan.refusal + ' task=' + (Get-EngineSectionBody -Text $debugText -Heading 'Tasks').Replace("`n", '|') + ' manifest=' + (Get-EngineSectionBody -Text $debugText -Heading 'Execution manifest').Replace("`n", '|'))
        }
        return $plan.allowed -and $null -eq $plan.refusal -and @($plan.waves).Count -eq 1 -and
            @($plan.waves[0].tasks).Count -eq 1 -and $plan.spec.name -eq 'fixture-plan'
    }
    Assert-Case 'validator nonzero refusal' {
        $fixture = New-Fixture
        $plan = Invoke-Plan -Fixture $fixture -Validator $failureValidator
        return -not $plan.allowed -and $plan.refusal -match 'exit 17' -and @($plan.waves).Count -eq 0
    }
    Assert-Case 'manifest missing and multiple refusal' {
        $missing = New-Fixture -SpecOptions @{ NoManifest = $true }
        $multiple = New-Fixture -SpecOptions @{ DuplicateManifest = $true }
        return -not (Invoke-Plan $missing).allowed -and -not (Invoke-Plan $multiple).allowed
    }
    Assert-Case 'frontmatter valid missing traversal and filename-mismatched spec identity' {
        $valid = New-Fixture
        $missing = New-Fixture -SpecOptions @{ NoSpec = $true }
        $traversal = New-Fixture -SpecOptions @{ SpecIdentity = '../fixture-plan' }
        $mismatch = New-Fixture -SpecOptions @{ SpecIdentity = 'other-plan' }
        $uppercase = New-Fixture -SpecOptions @{ SpecIdentity = 'Fixture-plan' }
        return (Invoke-Plan $valid).allowed -and -not (Invoke-Plan $missing).allowed -and
            -not (Invoke-Plan $traversal).allowed -and -not (Invoke-Plan $mismatch).allowed -and
            -not (Invoke-Plan $uppercase).allowed
    }
    Assert-Case 'frontmatter and Intent risk grammar' {
        $frontHigh = New-Fixture -SpecOptions @{ Risk = 'high' }
        $empty = New-Fixture -SpecOptions @{ Risk = '' }
        $other = New-Fixture -SpecOptions @{ Risk = 'critical' }
        $intentHigh = New-Fixture -SpecOptions @{ Intent = '- **Intent:** This line declares RISK: HIGH for execution.' }
        $near = New-Fixture -SpecOptions @{ Intent = '- **Intent:** This mentions risk: highly without declaring it.' }
        return -not (Invoke-Plan $frontHigh).allowed -and -not (Invoke-Plan $empty).allowed -and
            -not (Invoke-Plan $other).allowed -and -not (Invoke-Plan $intentHigh).allowed -and (Invoke-Plan $near).allowed
    }
    Assert-Case 'Non-goals risk token does not refuse' {
        $fixture = New-Fixture -SpecOptions @{ Intent = "- **Intent:** Build safely.`n- **Non-goals:** risk: high execution is excluded." }
        return (Invoke-Plan $fixture).allowed
    }
    Assert-Case 'prose risk token outside Intent does not refuse' {
        $fixture = New-Fixture -SpecOptions @{ Assumptions = '- Prose may literally say risk: high here.' }
        return (Invoke-Plan $fixture).allowed
    }
    Assert-Case 'pinned model defaults and allowlist' {
        $default = New-Fixture -SpecOptions @{ CoderModel = $null }
        $pinned = New-Fixture -SpecOptions @{ CoderModel = 'gpt-6-sol' }
        $alias = New-Fixture -SpecOptions @{ CoderModel = 'codex' }
        $bad = New-Fixture -SpecOptions @{ CoderModel = 'sonnet' }
        return (Invoke-Plan $default).spec.coder_model -ceq 'gpt-5.6-sol' -and
            (Invoke-Plan $pinned).spec.coder_model -ceq 'gpt-6-sol' -and
            (Invoke-Plan $alias).spec.coder_model -ceq 'gpt-5.6-sol' -and -not (Invoke-Plan $bad).allowed
    }
    Assert-Case 'multiple repo keys and repo mismatch refuse' {
        $multi = New-Fixture -TwoRepos
        $mismatch = New-Fixture -RepoOverride 'C:/definitely/not/the/test/repo'
        return -not (Invoke-Plan $multi).allowed -and -not (Invoke-Plan $mismatch).allowed
    }
    Assert-Case 'non-Git repo returns refusal without throwing' {
        $nonGit = Join-Path $testRoot ('not-git-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $nonGit -Force)
        $fixture = New-Fixture -RepoOverride (ConvertTo-ForwardPath -Path $nonGit)
        $plan = Get-EnginePlan -SpecPath $fixture.Spec -Repo $nonGit -MaxParallel 2 -ValidatorPath $successValidator
        return -not $plan.allowed -and $plan.refusal -ceq 'repo is not a Git worktree' -and @($plan.waves).Count -eq 0
    }
    Assert-Case 'differing same-name in-repo spec copy refuses' {
        $fixture = New-Fixture
        Write-Utf8 -Path (Join-Path $fixture.Repo 'docs/changes/fixture-plan.md') -Text 'different bytes'
        return -not (Invoke-Plan $fixture).allowed
    }
    Assert-Case 'UTF-8 LF canonical spec digest' {
        $unicodeIntent = '- **Intent:** Build caf' + [string][char]0x00E9 + ' safely.'
        $fixture = New-Fixture -Name 'utf8-plan' -SpecOptions @{ Intent = $unicodeIntent }
        $raw = [System.IO.File]::ReadAllText($fixture.Spec, $utf8)
        $canonical = ConvertTo-EngineLfText -Text $raw
        [System.IO.File]::WriteAllText($fixture.Spec, $canonical.Replace("`n", "`r`n"), $utf8)
        $plan = Invoke-Plan $fixture
        $expected = Get-EngineSha256 -Text $canonical
        if (-not $plan.allowed) { throw ('canonical digest fixture refused: ' + $plan.refusal) }
        if ($plan.spec.digest -ne $expected) {
            $strict = New-Object System.Text.UTF8Encoding($false, $true)
            $reread = [System.IO.File]::ReadAllText($fixture.Spec, $strict)
            throw ('digest mismatch expected ' + $expected + ' got ' + $plan.spec.digest + ' reread=' + (Get-EngineSha256 -Text $reread) + ' rawlen=' + $raw.Length + ' rereadlen=' + $reread.Length)
        }
        return $plan.allowed -and $plan.spec.digest -eq $expected
    }
    Assert-Case 'tracked and ignored existing create paths refuse' {
        $tracked = New-Fixture
        Write-Utf8 -Path (Join-Path $tracked.Repo 'src/new.txt') -Text 'tracked'
        Set-TestCommit -Repo $tracked.Repo -Paths @('src/new.txt')
        $ignored = New-Fixture
        Write-Utf8 -Path (Join-Path $ignored.Repo '.gitignore') -Text "*`n"
        Write-Utf8 -Path (Join-Path $ignored.Repo 'src/new.txt') -Text 'ignored'
        return -not (Invoke-Plan $tracked).allowed -and -not (Invoke-Plan $ignored).allowed
    }
    Assert-Case 'tracked but worktree-deleted create path refuses' {
        $fixture = New-Fixture
        $path = Join-Path $fixture.Repo 'src/new.txt'
        Write-Utf8 -Path $path -Text 'tracked at HEAD'
        Set-TestCommit -Repo $fixture.Repo -Paths @('src/new.txt')
        Remove-Item -LiteralPath $path -Force
        $porcelain = Invoke-GitQuiet -Repo $fixture.Repo -Arguments @('-c', 'core.excludesFile=/dev/null', 'status', '--porcelain', '--', 'src/new.txt')
        if (@($porcelain).Count -ne 1 -or $porcelain[0] -cnotmatch '^ D src/new\.txt$') { throw 'fixture did not produce the expected worktree deletion' }
        $plan = Invoke-Plan $fixture
        return -not $plan.allowed -and $plan.refusal -match 'create path already exists'
    }
    Assert-Case 'dirty modify and delete paths refuse' {
        $modifyTask = @(New-Task -Id '1' -Files @(New-File -Path 'src/existing.txt' -Op 'modify'))
        $fixture = New-Fixture -Tasks $modifyTask
        Write-Utf8 -Path (Join-Path $fixture.Repo 'src/existing.txt') -Text 'base'
        Set-TestCommit -Repo $fixture.Repo -Paths @('src/existing.txt')
        Write-Utf8 -Path (Join-Path $fixture.Repo 'src/existing.txt') -Text 'dirty'
        return -not (Invoke-Plan $fixture).allowed
    }
    Assert-Case 'regular path allowed and directory path refused' {
        $regular = New-Fixture
        $directory = New-Fixture
        [void](New-Item -ItemType Directory -Path (Join-Path $directory.Repo 'src/new.txt') -Force)
        return (Invoke-Plan $regular).allowed -and -not (Invoke-Plan $directory).allowed
    }
    Assert-Case 'reparse ancestor refuses create path' {
        $task = @(New-Task -Id '1' -Files @(New-File -Path 'link/new.txt'))
        $fixture = New-Fixture -Tasks $task
        $target = Join-Path $testRoot ('junction-target-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $target -Force)
        try { [void](New-Item -ItemType Junction -Path (Join-Path $fixture.Repo 'link') -Target $target -ErrorAction Stop) }
        catch { return $true }
        return -not (Invoke-Plan $fixture).allowed
    }
    Assert-Case 'cross-task canonical duplicate refuses' {
        $tasks = @(
            (New-Task -Id '1' -Files @(New-File -Path 'src/Same.txt'))
            (New-Task -Id '2' -Files @(New-File -Path 'src/same.txt'))
        )
        return -not (Invoke-Plan (New-Fixture -Tasks $tasks)).allowed
    }
    Assert-Case '.gitattributes leaf refuses' {
        $task = @(New-Task -Id '1' -Files @(New-File -Path 'nested/.GITATTRIBUTES'))
        return -not (Invoke-Plan (New-Fixture -Tasks $task)).allowed
    }
    Assert-Case 'dependency layering ignores prose Wave plan' {
        $tasks = @(
            (New-Task -Id '1' -Files @(New-File -Path 'a.txt'))
            (New-Task -Id '2' -Files @(New-File -Path 'b.txt'))
            (New-Task -Id '3' -Files @(New-File -Path 'c.txt') -Depends @('1', '2'))
        )
        $plan = Invoke-Plan -Fixture (New-Fixture -Tasks $tasks) -MaxParallel 2
        return $plan.allowed -and @($plan.waves).Count -eq 2 -and
            (@($plan.waves[0].tasks | ForEach-Object { $_.id }) -join ',') -eq '1,2' -and $plan.waves[1].tasks[0].id -eq '3'
    }
    Assert-Case 'frontmatter max parallel is reported while argument caps waves' {
        $tasks = @(
            (New-Task -Id '1' -Files @(New-File -Path 'one.txt'))
            (New-Task -Id '2' -Files @(New-File -Path 'two.txt'))
            (New-Task -Id '3' -Files @(New-File -Path 'three.txt'))
        )
        $declared = Invoke-Plan -Fixture (New-Fixture -Tasks $tasks -SpecOptions @{ MaxParallelCodex = 3 }) -MaxParallel 2
        $absent = Invoke-Plan -Fixture (New-Fixture) -MaxParallel 2
        return $declared.allowed -and $declared.spec.max_parallel_codex -eq 3 -and
            @($declared.waves).Count -eq 2 -and @($declared.waves[0].tasks).Count -eq 2 -and
            @($declared.waves[1].tasks).Count -eq 1 -and $null -eq $absent.spec.max_parallel_codex
    }
    Assert-Case 'ancestor overlap splits a topological layer' {
        $tasks = @(
            (New-Task -Id '1' -Files @(New-File -Path 'src'))
            (New-Task -Id '2' -Files @(New-File -Path 'src/child.txt'))
        )
        $plan = Invoke-Plan -Fixture (New-Fixture -Tasks $tasks) -MaxParallel 2
        return $plan.allowed -and @($plan.waves).Count -eq 2
    }
    Assert-Case 'oversize ultra task refuses' {
        $task = @(New-Task -Id '1' -Files @(New-File -Path 'ultra.txt') -Effort 'ultra')
        return -not (Invoke-Plan -Fixture (New-Fixture -Tasks $task) -MaxParallel 1).allowed
    }
    Assert-Case 'slot cap and manifest order are deterministic' {
        $tasks = @(
            (New-Task -Id '1' -Files @(New-File -Path 'one.txt'))
            (New-Task -Id '2' -Files @(New-File -Path 'two.txt') -Effort 'ultra')
            (New-Task -Id '3' -Files @(New-File -Path 'three.txt'))
        )
        $plan = Invoke-Plan -Fixture (New-Fixture -Tasks $tasks) -MaxParallel 2
        return $plan.allowed -and @($plan.waves).Count -eq 3 -and
            (@($plan.waves | ForEach-Object { $_.tasks[0].id }) -join ',') -eq '1,2,3'
    }
    Assert-Case 'exact live-template slots commands and prompt digest' {
        $fixture = New-Fixture -SpecOptions @{
            Intent = "- **Intent:** Preserve this intent verbatim.`n- **Invariants:** Keep order."
            Assumptions = '- Preserve this assumption verbatim.'
            Specialist = "### Security`nSECURITY-HAZARD-VERBATIM`n`n### Performance`nPERFORMANCE-HAZARD-VERBATIM`n`n### Accessibility`n(none)"
        }
        $plan = Invoke-Plan $fixture
        if (-not $plan.allowed) { throw ('prompt fixture refused: ' + $plan.refusal) }
        $task = $plan.waves[0].tasks[0]
        $checks = [ordered]@{
            text = $task.text -match 'Implement task 1 exactly'
            done = $task.done_when -eq 'task 1 is complete.'
            acceptance = @($task.acceptance).Count -eq 1
            security = $task.prompt.Contains('SECURITY-HAZARD-VERBATIM')
            performance = $task.prompt.Contains('PERFORMANCE-HAZARD-VERBATIM')
            no_accessibility = -not $task.prompt.Contains('### Accessibility')
            scratch = $task.prompt.Contains('- Scratch:')
            autonomy = $task.prompt.Contains('"Follow AGENTS.md.')
            command_one = $task.prompt.Contains('node --check exact-one.js')
            command_two = $task.prompt.Contains('powershell.exe -NoProfile -File exact-two.ps1')
            digest = $task.prompt_digest -eq (Get-EngineSha256 -Text $task.prompt)
        }
        if (@($checks.GetEnumerator() | Where-Object { -not $_.Value }).Count -gt 0) { throw ('prompt checks failed: ' + (($checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key }) -join ',')) }
        return $plan.allowed -and $task.text -match 'Implement task 1 exactly' -and
            $task.done_when -eq 'task 1 is complete.' -and @($task.acceptance).Count -eq 1 -and
            $task.prompt.Contains('SECURITY-HAZARD-VERBATIM') -and $task.prompt.Contains('PERFORMANCE-HAZARD-VERBATIM') -and
            -not $task.prompt.Contains('### Accessibility') -and $task.prompt.Contains('- Scratch:') -and
            $task.prompt.Contains('"Follow AGENTS.md.') -and $task.prompt.Contains('node --check exact-one.js') -and
            $task.prompt.Contains('powershell.exe -NoProfile -File exact-two.ps1') -and
            $task.prompt_digest -eq (Get-EngineSha256 -Text $task.prompt)
    }
    Assert-Case 'JSON CLI emits the pinned object' {
        $fixture = New-Fixture
        $json = @(& powershell.exe -NoProfile -File $planner -SpecPath $fixture.Spec -Repo $fixture.Repo -MaxParallel 2 -ValidatorPath $successValidator -Json 2>&1 | ForEach-Object { $_.ToString() })
        if ($LASTEXITCODE -ne 0) { return $false }
        $parsed = ($json -join "`n") | ConvertFrom-Json
        return $parsed.allowed -and $parsed.spec.name -eq 'fixture-plan' -and @($parsed.waves).Count -eq 1
    }
}
finally {
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [System.IO.Path]::GetFullPath($env:TEMP).TrimEnd([char[]]@([char]92, [char]47)) + [System.IO.Path]::DirectorySeparatorChar
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures -gt 0) {
    Write-Host ('engine-plan-test: FAIL ({0}/{1} failed)' -f $failures, $assertions) -ForegroundColor Red
    exit 1
}

Write-Host ('engine-plan-test: PASS ({0} cases)' -f $assertions) -ForegroundColor Green
exit 0
