[CmdletBinding()]
param([switch]$ChainsOnly)

$ErrorActionPreference = 'Stop'
$planner = Join-Path $PSScriptRoot 'engine-plan.ps1'
$baseline = Join-Path $PSScriptRoot 'apex-baseline-check.ps1'
$realValidator = Join-Path $PSScriptRoot 'apex-spec-validate.ps1'
$testRoot = Join-Path $env:TEMP ('engine-plan-test-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object System.Text.UTF8Encoding($false)
$failures = 0
$assertions = 0
$savedStateDir = $env:APEX_STATE_DIR
$savedGitConfigGlobal = $env:GIT_CONFIG_GLOBAL

function Get-MarkedRecipeBytes {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $text = $strictUtf8.GetString($bytes)
    $begins = [regex]::Matches($text, '(?m)^# BEGIN recipe-grammar lockstep(?=\r?$)')
    $ends = [regex]::Matches($text, '(?m)^# END recipe-grammar lockstep(?=\r?$)')
    if (@($begins).Count -ne 1 -or @($ends).Count -ne 1) {
        throw ('expected exactly one BEGIN and END marker line in ' + $Path)
    }
    $begin = $begins[0]
    $end = $ends[0]
    $bodyStart = $begin.Index + $begin.Length
    if ($end.Index -le $bodyStart -or [string]::IsNullOrWhiteSpace($text.Substring($bodyStart, $end.Index - $bodyStart))) {
        throw ('empty or reversed marked recipe span in ' + $Path)
    }
    $spanEnd = $end.Index + $end.Length
    if ($spanEnd -lt $text.Length -and $text[$spanEnd] -eq [char]13) { $spanEnd++ }
    if ($spanEnd -lt $text.Length -and $text[$spanEnd] -eq [char]10) { $spanEnd++ }
    $span = $text.Substring($begin.Index, $spanEnd - $begin.Index)
    $eols = @([regex]::Matches($span, '\r\n|\n|\r') | ForEach-Object { $_.Value })
    if (@($eols).Count -eq 0 -or $eols[0] -ceq "`r") { throw ('missing or unsupported EOL in ' + $Path) }
    foreach ($eol in $eols) {
        if ($eol -cne $eols[0]) { throw ('mixed EOL in marked recipe span in ' + $Path) }
    }
    $offset = $strictUtf8.GetByteCount($text.Substring(0, $begin.Index))
    $length = $strictUtf8.GetByteCount($span)
    $rawSpan = New-Object byte[] $length
    [System.Buffer]::BlockCopy($bytes, $offset, $rawSpan, 0, $length)
    return [pscustomobject]@{ Bytes = $rawSpan; Offset = $offset; Eol = $eols[0] }
}

function Test-RecipeLockstep {
    param([object]$Left, [object]$Right)
    $length = @($Left.Bytes).Count
    if ($Left.Eol -cne $Right.Eol -or $length -ne @($Right.Bytes).Count) { return $false }
    for ($i = 0; $i -lt $length; $i++) {
        if ($Left.Bytes[$i] -ne $Right.Bytes[$i]) { return $false }
    }
    return $true
}

function Invoke-BaselinePreflight {
    param([string]$Repo)
    $savedEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& powershell.exe -NoProfile -File $baseline -Preflight -Worktree $Repo 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }
    return [pscustomobject]@{ ExitCode = $code; Output = ($output -join "`n") }
}

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Invoke-GitQuiet {
    param([string]$Repo, [string[]]$Arguments)
    $savedEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $Repo @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }
    if ($code -ne 0) { throw ('git failed: ' + ($output -join ' | ')) }
    return ,$output
}

function New-TestRepo {
    param([string]$LinkedFrom, [string]$CloneFrom)
    $path = Join-Path $testRoot ('repo-' + [guid]::NewGuid().ToString('N'))
    if (-not [string]::IsNullOrEmpty($LinkedFrom)) {
        [void](Invoke-GitQuiet -Repo $LinkedFrom -Arguments @('worktree', 'add', '-q', '-b', ('linked-' + [guid]::NewGuid().ToString('N')), $path))
        return $path
    }
    if (-not [string]::IsNullOrEmpty($CloneFrom)) {
        [void](Invoke-GitQuiet -Repo $CloneFrom -Arguments @('clone', '-q', '--no-local', $CloneFrom, $path))
        return $path
    }
    [void](New-Item -ItemType Directory -Path $path -Force)
    [void](Invoke-GitQuiet -Repo $path -Arguments @('init', '-q'))
    Write-Utf8 -Path (Join-Path $path 'AGENTS.md') -Text (@(
        '# Test repository'
        ''
        '## Verify commands'
        ''
        '```'
        'node --check exact-one.js'
        'powershell.exe -NoProfile -File exact-two.ps1'
        '```'
        ''
        '## Preflight commands'
        ''
        '```'
        'node --check exact-one.js'
        '```'
    ) -join "`n")
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
        $savedEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $commit = @('fixture' | & git -C $Repo commit-tree $tree 2>&1 | ForEach-Object { $_.ToString() })[-1]
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $savedEap }
        if ($code -ne 0) { throw 'git commit-tree failed' }
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
    param([string]$Id, [object[]]$Files, [string[]]$Depends = @(), [string]$Effort, [object]$Chain)
    $task = [ordered]@{ id = $Id; repo = 'main'; files = @($Files); depends_on = @($Depends) }
    if (-not [string]::IsNullOrEmpty($Effort)) { $task['effort'] = $Effort }
    if ($PSBoundParameters.ContainsKey('Chain')) { $task['chain'] = $Chain }
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
        [string]$TaskLabelSeparator = '-',
        [string]$TaskFieldSeparator,
        [switch]$NoSpec,
        [switch]$OmitRisk,
        [string]$SpecIdentity,
        [switch]$NoManifest,
        [switch]$DuplicateManifest,
        [hashtable]$TaskTexts = @{},
        [string]$AcceptanceText
    )
    $front = New-Object 'System.Collections.Generic.List[string]'
    [void]$front.Add('---')
    if (-not $NoSpec) {
        if ([string]::IsNullOrEmpty($SpecIdentity)) { $SpecIdentity = $Name }
        [void]$front.Add('spec: ' + $SpecIdentity)
    }
    if (-not $OmitRisk -and $null -ne $Risk) { [void]$front.Add('risk: ' + $Risk) }
    if (-not [string]::IsNullOrEmpty($CoderModel)) { [void]$front.Add('coder_model: ' + $CoderModel) }
    if ($null -ne $CoderEffort) { [void]$front.Add('coder_effort: ' + $CoderEffort) }
    if ($null -ne $MaxParallelCodex) { [void]$front.Add('max_parallel_codex: ' + $MaxParallelCodex) }
    [void]$front.Add('---')

    $fileRows = New-Object 'System.Collections.Generic.List[string]'
    $listedFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $taskRows = New-Object 'System.Collections.Generic.List[string]'
    $acceptanceRows = New-Object 'System.Collections.Generic.List[string]'
    $emDash = [string][char]0x2014
    if ([string]::IsNullOrEmpty($TaskFieldSeparator)) { $TaskFieldSeparator = $emDash }
    foreach ($task in $Tasks) {
        foreach ($file in @($task.files)) {
            $spelling = $file.path.Replace([char]92, [char]47)
            if ($listedFiles.Add($spelling)) { [void]$fileRows.Add('| ' + $spelling + ' | ' + $file.op + ' | fixture |') }
        }
        $paths = @($task.files | ForEach-Object { $_.path }) -join ', '
        if ($TaskTexts.ContainsKey([string]$task.id)) { [void]$taskRows.Add(('- [ ] **Task {0}** - {1}' -f $task.id, $TaskTexts[[string]$task.id])) }
        else { [void]$taskRows.Add(('- [ ] **Task {0}** {1} Implement task {0} exactly. {2} files: {3} {2} done when: task {0} is complete.' -f $task.id, $TaskLabelSeparator, $TaskFieldSeparator, $paths)) }
        [void]$acceptanceRows.Add(('- [ ] Task {0} - task {0} is executable -> verify: run the fixture command.' -f $task.id))
    }
    if ($PSBoundParameters.ContainsKey('AcceptanceText')) { $acceptanceRows.Clear(); $acceptanceRows.Add($AcceptanceText) }
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
        [string]$RepoOverride,
        [switch]$LinkedWorktree
    )
    $repo = New-TestRepo
    $manifestRepo = $repo
    if ($LinkedWorktree) {
        Write-Utf8 -Path (Join-Path $repo 'src/existing.txt') -Text 'base'
        Set-TestCommit -Repo $repo -Paths @('AGENTS.md', 'src/existing.txt')
        $repo = New-TestRepo -LinkedFrom $manifestRepo
    }
    if ($null -eq $Tasks) { $Tasks = @(New-Task -Id '1' -Files @(New-File -Path 'src/new.txt')) }
    $manifest = New-ManifestJson -Repo $manifestRepo -Tasks $Tasks -TwoRepos:$TwoRepos -RepoOverride $RepoOverride
    $textArgs = @{ Name = $Name; Manifest = $manifest; Tasks = $Tasks }
    foreach ($key in $SpecOptions.Keys) { $textArgs[$key] = $SpecOptions[$key] }
    $specDir = Join-Path $testRoot ('spec-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $specDir -Force)
    $spec = Join-Path $specDir ($Name + '.md')
    Write-Utf8 -Path $spec -Text (New-SpecText @textArgs)
    return [pscustomobject]@{ Repo = $repo; ManifestRepo = $manifestRepo; Spec = $spec; Tasks = $Tasks; Manifest = $manifest }
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

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -cne $Expected) { throw ($Label + ': expected <' + $Expected + '>, got <' + $Actual + '>') }
}

function Get-PlannedTasks {
    param($Plan)
    if (-not $Plan.allowed) { throw $Plan.refusal }
    return @($Plan.waves | ForEach-Object { $_.tasks })
}

function Initialize-FixtureFiles {
    param($Fixture)
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($task in $Fixture.Tasks) {
        foreach ($file in $task.files) {
            if ($paths.Add($file.path) -and $file.op -cne 'create') { Write-Utf8 (Join-Path $Fixture.Repo $file.path) 'base' }
        }
    }
    $tracked = @('AGENTS.md') + @($paths | Where-Object { Test-Path -LiteralPath (Join-Path $Fixture.Repo $_) -PathType Leaf })
    Set-TestCommit $Fixture.Repo $tracked
}

function Assert-PlanRefusal {
    param([object[]]$Tasks, [string]$Reason, [int]$MaxParallel = 2)
    $plan = Invoke-Plan (New-Fixture -Tasks $Tasks) -MaxParallel $MaxParallel
    if ($plan.allowed -or $plan.refusal -cnotmatch $Reason) { throw ('expected refusal /' + $Reason + '/, got: ' + $plan.refusal) }
}

try {
    [void](New-Item -ItemType Directory -Path $testRoot -Force)
    $env:APEX_STATE_DIR = Join-Path $testRoot 'state'
    $env:GIT_CONFIG_GLOBAL = Join-Path $testRoot 'gitconfig'
    Write-Utf8 -Path $env:GIT_CONFIG_GLOBAL -Text ''
    $successValidator = Join-Path $testRoot 'validator-success.ps1'
    $failureValidator = Join-Path $testRoot 'validator-failure.ps1'
    Write-Utf8 -Path $successValidator -Text "param([string]`$SpecPath)`nWrite-Output VALIDATOR-SEAM`nexit 0`n"
    Write-Utf8 -Path $failureValidator -Text "param([string]`$SpecPath)`nWrite-Output REFUSED-BY-SEAM`nexit 17`n"
    . $planner

    Assert-Case 'chain shared create/modify union, unique file/delete, exact text and prompt/digest' {
        $tasks = @(
            (New-Task '1' @((New-File 'shared.txt'), (New-File 'unique.txt')) -Chain 'work'),
            (New-Task '2' @((New-File 'shared.txt' 'modify'), (New-File 'old.txt' 'delete')) -Depends '1' -Chain 'work' -Effort 'high')
        )
        $member1Text = "First instructions.  `n  keep spaces. done when: first"
        $member2Text = "Second instructions.`n done when: second"
        $fixture = New-Fixture -Tasks $tasks -SpecOptions @{ TaskTexts = @{ '1' = $member1Text; '2' = $member2Text } }
        Initialize-FixtureFiles $fixture
        $plan = Invoke-Plan $fixture
        $merged = @(Get-PlannedTasks $plan)
        Assert-Equal $merged.Count 1 'merged count'
        $task = $merged[0]
        Assert-Equal ($task.members -join ',') '1,2' 'members'
        Assert-Equal ($task.files.path -join ',') 'shared.txt,unique.txt,old.txt' 'union order'
        Assert-Equal ($task.files.op -join ',') 'create,create,delete' 'union operations'
        Assert-Equal $task.effort 'high' 'effort'
        Assert-Equal $task.text ('Part 1 (Task 1):' + "`n" + $member1Text + "`n`n" + 'Part 2 (Task 2):' + "`n" + $member2Text) 'text bytes'
        Assert-Equal $task.done_when 'first; then second' 'completion bytes'
        Assert-Equal ($task.acceptance -join "`n") "- [ ] Task 1 - task 1 is executable -> verify: run the fixture command.`n- [ ] Task 2 - task 2 is executable -> verify: run the fixture command." 'acceptance order'
        $template = Get-EngineTemplateParts (Join-Path (Split-Path -Parent $PSScriptRoot) 'references/dispatch-pack.md')
        $expected = New-EnginePrompt -Task $task -Identity '**Identity:** Fixture identity for fixture-plan.' -RepoPath $fixture.Repo -Intent $plan.spec.intent -Assumptions $plan.spec.assumptions -SpecialistContext $plan.spec.specialist_context -VerifyFence (Get-EngineVerifyFence (Join-Path $fixture.Repo 'AGENTS.md')) -Template $template
        Assert-Equal $task.prompt $expected 'generated prompt bytes'
        Assert-Equal $task.prompt_digest (Get-EngineSha256 $task.prompt) 'raw digest'
        Assert-Equal ([regex]::Matches([IO.File]::ReadAllText($fixture.Spec), '(?m)^\| shared\.txt \| create \| fixture \|$').Count) 1 'one shared Files-to-Change row with first op'
        # Seed only the unique delete; the shared create must remain absent.
        $reversed = New-Fixture -Tasks @($tasks[1], $tasks[0])
        Write-Utf8 (Join-Path $reversed.Repo 'old.txt') 'base'
        Set-TestCommit $reversed.Repo @('AGENTS.md', 'old.txt')
        $reverseTask = @(Get-PlannedTasks (Invoke-Plan $reversed))[0]
        Assert-Equal ($reverseTask.members -join ',') '1,2' 'reversed create/modify order'
        Assert-Equal ($reverseTask.files.op -join ',') 'create,create,delete' 'chain-order first operation'
        return -not $task.PSObject.Properties['chain']
    }
    Assert-Case 'shared modify/modify reversed manifest, late shared listing, stable emitted order' {
        $tasks = @(
            (New-Task '3' @((New-File 'shared.txt' 'modify'), (New-File 'tail.txt')) -Chain 'work' -Depends '2'),
            (New-Task '8' @((New-File 'independent.txt'))),
            (New-Task '1' @((New-File 'head.txt')) -Chain 'work'),
            (New-Task '2' @((New-File 'shared.txt' 'modify'), (New-File 'middle.txt')) -Chain 'work' -Depends '1')
        )
        $fixture = New-Fixture -Tasks $tasks
        Initialize-FixtureFiles $fixture
        $planned = @(Get-PlannedTasks (Invoke-Plan $fixture))
        Assert-Equal ($planned.id -join ',') '1,8' 'first manifest position'
        Assert-Equal ($planned[0].members -join ',') '1,2,3' 'chain order'
        Assert-Equal ($planned[0].files.path -join ',') 'head.txt,shared.txt,middle.txt,tail.txt' 'file order'
        Assert-Equal $planned[0].files[1].op 'modify' 'first op'
        return -not $planned[1].PSObject.Properties['members']
    }
    Assert-Case 'single-member and independent chains retain normalized IDs and resolved maximum effort' {
        $tasks = @(
            (New-Task '1A' @((New-File 'one.txt')) -Chain 'solo' -Effort 'low'),
            (New-Task '2' @((New-File 'two.txt')) -Chain 'other' -Effort 'max'),
            (New-Task '3' @((New-File 'three.txt')) -Chain 'other' -Depends '2')
        )
        $plan = Invoke-Plan (New-Fixture -Tasks $tasks -SpecOptions @{ CoderEffort = 'ultra' })
        $planned = @(Get-PlannedTasks $plan)
        Assert-Equal ($planned.id -join ',') '1a,2' 'IDs'
        Assert-Equal ($planned[0].members -join ',') '1a' 'singleton'
        Assert-Equal $planned[0].text "Part 1 (Task 1a):`nImplement task 1A exactly. $([char]0x2014) files: one.txt $([char]0x2014) done when: task 1A is complete." 'singleton text'
        Assert-Equal $planned[1].effort 'ultra' 'default resolved before maximum'
        Assert-Equal $plan.waves.Count 2 'slot weight creates separate waves'
        Assert-Equal $plan.waves[1].tasks.Count 1 'ultra consumes two slots'
        $plan = Invoke-Plan (New-Fixture -Tasks $tasks -SpecOptions @{ CoderEffort = 'ultra' }) -MaxParallel 1
        return -not $plan.allowed -and $plan.refusal -ceq 'task 3 weight exceeds MaxParallel'
    }
    Assert-Case 'external prerequisites, head/non-head dependents and cross-chain dependencies rewrite stably' {
        $tasks = @(
            (New-Task '1' @((New-File '1.txt')) -Chain 'a' -Depends @('8','9')),
            (New-Task '2' @((New-File '2.txt')) -Chain 'a' -Depends @('1','9','8')),
            (New-Task '3' @((New-File '3.txt')) -Chain 'b' -Depends @('2','1','9')),
            (New-Task '4' @((New-File '4.txt')) -Chain 'b' -Depends @('3','2')),
            (New-Task '5' @((New-File '5.txt')) -Depends @('4','3','2','1')),
            (New-Task '8' @((New-File '8.txt'))), (New-Task '9' @((New-File '9.txt')))
        )
        $planned = @(Get-PlannedTasks (Invoke-Plan (New-Fixture -Tasks $tasks)))
        Assert-Equal (($planned | Where-Object id -eq '1').depends_on -join ',') '8,9' 'member union'
        Assert-Equal (($planned | Where-Object id -eq '3').depends_on -join ',') '1,9' 'cross chain'
        Assert-Equal (($planned | Where-Object id -eq '5').depends_on -join ',') '3,1' 'external dependents'
        return $true
    }
    Assert-Case 'completion empty values and missing done-when matches preserve exact join bytes' {
        foreach ($case in @(
            @{ Values = @('first','second'); Expected = 'first; then second' },
            @{ Values = @('','second'); Expected = 'second' },
            @{ Values = @('first','','second'); Expected = 'first; then second' },
            @{ Values = @('first',''); Expected = 'first' },
            @{ Values = @('',''); Expected = '' }
        )) {
            $tasks = @(); $texts = @{}
            for ($i = 0; $i -lt $case.Values.Count; $i++) {
                $id = [string]($i + 1); $depends = @(); if ($i -gt 0) { $depends = @([string]$i) }
                $tasks += New-Task $id @((New-File ($id + '.txt'))) -Chain 'done' -Depends $depends
                # Empty members alternate an empty parsed match and no match at all.
                $texts[$id] = if ($case.Values[$i] -ne '') { 'body done when: ' + $case.Values[$i] } elseif ($i % 2 -eq 0) { 'body done when:   ' } else { 'body with no completion field' }
            }
            $task = @(Get-PlannedTasks (Invoke-Plan (New-Fixture -Tasks $tasks -SpecOptions @{ TaskTexts = $texts })))[0]
            Assert-Equal $task.done_when $case.Expected 'completion bytes'
        }
        return $true
    }
    Assert-Case 'acceptance stable union and distinct identical-body checks preserve IDs labels attribution' {
        $tasks = @((New-Task '1' @((New-File 'one.txt')) -Chain 'checks'), (New-Task '2' @((New-File 'two.txt')) -Chain 'checks' -Depends '1'))
        $criteria = @'
- [ ] Task 1 and Task 2 shared host criterion
- [ ] Task 1 - tagged one
```powershell apex-accept
Write-Output same
```
- [ ] Task 2 - tagged two
```powershell apex-accept
Write-Output same
```
- [ ] spec criterion
```powershell apex-accept
Write-Output spec
```
'@
        $fixture = New-Fixture -Tasks $tasks -SpecOptions @{ AcceptanceText = $criteria }
        $before = Get-EngineAcceptanceLines ([IO.File]::ReadAllText($fixture.Spec)) -ManifestIds @('1','2')
        $plan = Invoke-Plan $fixture
        $task = @(Get-PlannedTasks $plan)[0]
        Assert-Equal $task.acceptance.Count 1 'stable host union'
        Assert-Equal ($task.acceptance_checks.id -join ',') '1-1,2-1' 'distinct check IDs'
        for ($i = 0; $i -lt 2; $i++) {
            Assert-Equal $task.acceptance_checks[$i].task '1' 'merged attribution'
            Assert-Equal $task.acceptance_checks[$i].label $before.checks[$i].label 'label unchanged'
            Assert-Equal $task.acceptance_checks[$i].body $before.checks[$i].body 'body unchanged'
        }
        Assert-Equal ($plan.spec_acceptance_checks | ConvertTo-Json -Depth 5 -Compress) ($before.checks[2] | ConvertTo-Json -Depth 5 -Compress) 'spec-level check'
        Assert-Equal $task.prompt_digest (Get-EngineSha256 $task.prompt) 'raw digest'
        return ([regex]::Matches($task.prompt, 'Write-Output same').Count -eq 2) -and -not $task.prompt.Contains('Write-Output spec')
    }
    Assert-Case 'schema members array/string optional and all merged task properties admitted' {
        $schema = Get-Content (Join-Path $PSScriptRoot '../references/engine-state-schema.json') -Raw | ConvertFrom-Json
        $taskSchema = $schema.properties.plan.oneOf[0].properties.waves.items.properties.tasks.items
        Assert-Equal $taskSchema.properties.members.type 'array' 'members type'
        Assert-Equal $taskSchema.properties.members.items.type 'string' 'member type'
        if ($taskSchema.required -contains 'members' -or $taskSchema.additionalProperties -ne $false) { throw 'schema strictness changed' }
        $task = @(Get-PlannedTasks (Invoke-Plan (New-Fixture -Tasks @((New-Task '1' @((New-File 'one.txt')) -Chain 'solo')))))[0]
        foreach ($property in $task.PSObject.Properties.Name) { if (-not $taskSchema.properties.PSObject.Properties[$property]) { throw ('unknown schema property ' + $property) } }
        return $true
    }
    Assert-Case 'invalid chain metadata refuses without string coercion' {
        foreach ($value in @($null, '', ' ', 'Upper', 'a_b', '-a', "a`n", @('a'), 1)) {
            Assert-PlanRefusal @((New-Task '1' @((New-File 'one.txt')) -Chain $value)) '^task 1 chain is invalid$'
        }
        return $true
    }
    Assert-Case 'chain multiple heads, branch, join, disconnected, cycles and non-predecessor edges refuse under permissive validator' {
        foreach ($edges in @(
            @{ '1'=@(); '2'=@() },
            @{ '1'=@(); '2'=@('1'); '3'=@('1') },
            @{ '1'=@(); '2'=@('1'); '3'=@('1','2') },
            @{ '1'=@(); '2'=@('3'); '3'=@('2') },
            @{ '1'=@('2'); '2'=@('1') },
            @{ '1'=@(); '2'=@('1'); '3'=@('2'); '4'=@('3','1') },
            @{ '1'=@(); '2'=@('1','1') }
        )) {
            $tasks = @(); foreach ($id in @($edges.Keys | Sort-Object)) { $tasks += New-Task $id @((New-File ($id + '.txt'))) -Chain 'shape' -Depends $edges[$id] }
            Assert-PlanRefusal $tasks '^(chain shape |execution manifest dependency graph contains a cycle$)'
        }
        return $true
    }
    Assert-Case 'shared operations reject first delete and later delete/create including case-variant identities' {
        foreach ($ops in @(@('delete','modify'), @('create','delete'), @('modify','delete'), @('create','create'), @('modify','create'))) {
            foreach ($laterPath in @('shared.txt','SHARED.TXT','shared.txt.')) {
                Assert-PlanRefusal @((New-Task '1' @((New-File 'shared.txt' $ops[0])) -Chain 'ops'), (New-Task '2' @((New-File $laterPath $ops[1])) -Chain 'ops' -Depends '1')) '^chain ops has invalid shared-path operations:'
            }
        }
        return $true
    }
    Assert-Case 'source duplicate paths and sharing outside a chain preserve ownership refusal' {
        foreach ($laterPath in @('shared.txt','SHARED.TXT','shared.txt.')) {
            Assert-PlanRefusal @((New-Task '1' @((New-File 'shared.txt'), (New-File $laterPath 'modify')) -Chain 'same')) '^canonical manifest path appears in more than one task:'
        }
        foreach ($chain in @($null, 'different')) {
            $second = New-Task '2' @((New-File 'shared.txt' 'modify')) -Depends '1'
            if ($null -ne $chain) { $second | Add-Member chain $chain }
            Assert-PlanRefusal @((New-Task '1' @((New-File 'shared.txt')) -Chain 'same'), $second) '^canonical manifest path appears in more than one task:'
        }
        return $true
    }
    Assert-Case 'ancestor/descendant overlaps remain forbidden within merged tasks and across chains' {
        foreach ($secondChain in @('same','other')) {
            Assert-PlanRefusal @((New-Task '1' @((New-File 'parent')) -Chain 'same'), (New-Task '2' @((New-File 'parent/child')) -Chain $secondChain -Depends '1')) '^manifest paths overlap \(ancestor/descendant\): parent, parent/child$'
        }
        Assert-PlanRefusal @((New-Task '1' @((New-File 'parent'), (New-File 'parent/child')) -Chain 'same')) '^manifest paths overlap'
        return $true
    }
    Assert-Case 'original unknown/self dependency validation precedes rewriting and shape checks' {
        foreach ($invalid in @('9','2')) {
            Assert-PlanRefusal @((New-Task '1' @((New-File 'parent')) -Chain 'original'), (New-Task '2' @((New-File 'parent/child')) -Chain 'original' -Depends @('1',$invalid))) ('^task 2 has an invalid dependency ' + $invalid + '$')
        }
        return $true
    }
    Assert-Case 'original cycle generic, acyclic contraction interleaving specific with encounter-order names' {
        Assert-PlanRefusal @((New-Task '1' @((New-File '1.txt')) -Chain 'work'), (New-Task '2' @((New-File '2.txt')) -Chain 'work' -Depends @('1','3')), (New-Task '3' @((New-File '3.txt')) -Depends '1')) '^chain work requires interleaving with task 3$'
        Assert-PlanRefusal @((New-Task '1' @((New-File '1.txt')) -Chain 'work' -Depends '3'), (New-Task '2' @((New-File '2.txt')) -Chain 'work' -Depends '1'), (New-Task '3' @((New-File '3.txt')) -Depends '2')) '^execution manifest dependency graph contains a cycle$'
        Assert-PlanRefusal @((New-Task '4' @((New-File '4.txt')) -Chain 'b' -Depends '3'), (New-Task '2' @((New-File '2.txt')) -Chain 'a' -Depends @('1','3')), (New-Task '1' @((New-File '1.txt')) -Chain 'a'), (New-Task '3' @((New-File '3.txt')) -Chain 'b' -Depends '1')) '^chain b requires interleaving with task 2$'
        return $true
    }
    Assert-Case 'unchained overlap precedes cycle and duplicate ownership precedes later ultra weight' {
        Assert-PlanRefusal @((New-Task '1' @((New-File 'parent')) -Depends '2'), (New-Task '2' @((New-File 'parent/child')) -Depends '1')) '^manifest paths overlap \(ancestor/descendant\): parent, parent/child$'
        Assert-PlanRefusal @((New-Task '1' @((New-File 'same.txt' 'modify'))), (New-Task '2' @((New-File 'same.txt' 'modify'))), (New-Task '3' @((New-File '3.txt')) -Effort 'ultra')) '^canonical manifest path appears in more than one task: same.txt$' -MaxParallel 1
        return $true
    }
    Assert-Case 'chain pass-one path/op/effort/ID safety guards survive permissive validator' {
        foreach ($path in @('../escape', '/absolute', 'src/../escape', '.git/config', 'src/.GiT/config', '.gitattributes')) {
            Assert-PlanRefusal @((New-Task '1' @((New-File $path)) -Chain 'guard')) '(manifest path|\.gitattributes)'
        }
        Assert-PlanRefusal @((New-Task '1' @((New-File 'one.txt' 'rename')) -Chain 'guard')) '^manifest operation is invalid'
        Assert-PlanRefusal @((New-Task '1' @((New-File 'one.txt')) -Chain 'guard' -Effort 'bogus')) '^task 1 effort is invalid$'
        Assert-PlanRefusal @((New-Task '1' @((New-File 'one.txt')) -Chain 'guard'), (New-Task '1' @((New-File 'two.txt')) -Chain 'guard')) '^duplicate manifest task id: 1$'
        Assert-PlanRefusal @((New-Task '1' @((New-File 'one.txt')) -Chain 'guard' -Effort 'ultra')) '^task 1 weight exceeds MaxParallel$' -MaxParallel 1
        return $true
    }
    Assert-Case 'contracted file union preserves directory, regular-file-ancestor, create-existence and dirty guards' {
        $fixture = New-Fixture -Tasks @((New-Task '1' @((New-File 'shared.txt')) -Chain 'guard'), (New-Task '2' @((New-File 'shared.txt' 'modify')) -Chain 'guard' -Depends '1'))
        Write-Utf8 (Join-Path $fixture.Repo 'shared.txt') 'existing'
        Assert-Equal (Invoke-Plan $fixture).refusal 'create path already exists (tracked or ignored): shared.txt' 'first op existence guard'
        $fixture = New-Fixture -Tasks @((New-Task '1' @((New-File 'directory')) -Chain 'guard'), (New-Task '2' @((New-File 'directory' 'modify')) -Chain 'guard' -Depends '1'))
        [void](New-Item -ItemType Directory -Path (Join-Path $fixture.Repo 'directory'))
        Assert-Equal (Invoke-Plan $fixture).refusal 'manifest path is a directory: directory' 'directory guard'
        $fixture = New-Fixture -Tasks @((New-Task '1' @((New-File 'parent/child.txt')) -Chain 'guard'))
        Write-Utf8 (Join-Path $fixture.Repo 'parent') 'regular file'
        Assert-Equal (Invoke-Plan $fixture).refusal 'manifest path ancestor is a file: parent/child.txt' 'file ancestor guard'
        $fixture = New-Fixture -Tasks @((New-Task '1' @((New-File 'shared.txt' 'modify')) -Chain 'guard'), (New-Task '2' @((New-File 'shared.txt' 'modify')) -Chain 'guard' -Depends '1'))
        Initialize-FixtureFiles $fixture
        Write-Utf8 (Join-Path $fixture.Repo 'shared.txt') 'dirty'
        Assert-Equal (Invoke-Plan $fixture).refusal 'modify/delete path is dirty: shared.txt' 'dirty guard'
        return $true
    }
    Assert-Case 'Intent full-text comment removal handles same-line/multiline headings and preserves prompt metadata' {
        foreach ($intent in @('<!-- risk: high --> safe <!-- risk: high --> prose', "<!-- risk: high`n## hidden heading`n-->`nPlain prose.", "Start <!-- risk: high`ncomment continues --> end", "Start <!-- risk:`nhigh --> end")) {
            $fixture = New-Fixture -SpecOptions @{ Intent = $intent }
            $plan = Invoke-Plan $fixture
            $task = @(Get-PlannedTasks $plan)[0]
            $originalIntent = Get-EngineSectionBody ([IO.File]::ReadAllText($fixture.Spec)) 'Intent'
            Assert-Equal $plan.spec.intent $originalIntent 'original metadata'
            if (-not $task.prompt.Contains("- Intent:`n$originalIntent")) { throw 'comment-bearing Intent changed in prompt' }
            Assert-Equal $plan.spec.digest (Get-EngineSha256 ([IO.File]::ReadAllText($fixture.Spec))) 'original spec digest'
        }
        foreach ($intent in @('Visible risk: high', '<!-- unfinished risk: high', "<!-- risk: high -->`nVisible risk: high", "<!-- unfinished`nrisk: high")) {
            $plan = Invoke-Plan (New-Fixture -SpecOptions @{ Intent = $intent })
            Assert-Equal $plan.refusal 'Intent declares risk: high but frontmatter risk is not high' 'visible or unterminated risk'
        }
        return $true
    }

    Assert-Case 'embedded pre-change unchained serialized plan and prompt bytes, raw digests' {
        # Captured before chain support. Only fixture-root substitutions vary; all other bytes are pinned.
        $expectedJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('ew0KICAgICJhbGxvd2VkIjogIHRydWUsDQogICAgInJlZnVzYWwiOiAgbnVsbCwNCiAgICAic3BlYyI6ICB7DQogICAgICAgICAgICAgICAgICJuYW1lIjogICJmaXh0dXJlLXBsYW4iLA0KICAgICAgICAgICAgICAgICAicGF0aCI6ICAiPFNQRUM+IiwNCiAgICAgICAgICAgICAgICAgImRpZ2VzdCI6ICAiPFNQRUNfRElHRVNUPiIsDQogICAgICAgICAgICAgICAgICJyaXNrIjogICJtZWRpdW0iLA0KICAgICAgICAgICAgICAgICAiY29kZXJfbW9kZWwiOiAgImdwdC02LjEtc29sIiwNCiAgICAgICAgICAgICAgICAgImNvZGVyX2VmZm9ydCI6ICAibWVkaXVtIiwNCiAgICAgICAgICAgICAgICAgIm1heF9wYXJhbGxlbF9jb2RleCI6ICBudWxsLA0KICAgICAgICAgICAgICAgICAiaW50ZW50IjogICItICoqSW50ZW50OioqIEJ1aWxkIHRoZSBmaXh0dXJlLiIsDQogICAgICAgICAgICAgICAgICJhc3N1bXB0aW9ucyI6ICAiLSBUaGUgZml4dHVyZSBlbnZpcm9ubWVudCBpcyBhdmFpbGFibGUuIiwNCiAgICAgICAgICAgICAgICAgInNwZWNpYWxpc3RfY29udGV4dCI6ICBbDQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICIjIyMgU2VjdXJpdHlcbktlZXAgZml4dHVyZSB3cml0ZXMgc2NvcGVkLiINCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBdDQogICAgICAgICAgICAgfSwNCiAgICAid2F2ZXMiOiAgWw0KICAgICAgICAgICAgICAgICAgew0KICAgICAgICAgICAgICAgICAgICAgICJudW1iZXIiOiAgMSwNCiAgICAgICAgICAgICAgICAgICAgICAidGFza3MiOiAgWw0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgew0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICJpZCI6ICAiMSIsDQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgInJlcG8iOiAgIm1haW4iLA0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICJmaWxlcyI6ICBbDQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICB7DQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgInBhdGgiOiAgInNyYy9uZXcudHh0IiwNCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAib3AiOiAgImNyZWF0ZSINCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIH0NCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgXSwNCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiZGVwZW5kc19vbiI6ICBbDQoNCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBdLA0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICJlZmZvcnQiOiAgIm1lZGl1bSIsDQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgInRleHQiOiAgIkltcGxlbWVudCB0YXNrIDEgZXhhY3RseS4g4oCUIGZpbGVzOiBzcmMvbmV3LnR4dCDigJQgZG9uZSB3aGVuOiB0YXNrIDEgaXMgY29tcGxldGUuIiwNCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiZG9uZV93aGVuIjogICJ0YXNrIDEgaXMgY29tcGxldGUuIiwNCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiYWNjZXB0YW5jZSI6ICBbDQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICItIFsgXSBUYXNrIDEgLSB0YXNrIDEgaXMgZXhlY3V0YWJsZSAtXHUwMDNlIHZlcmlmeTogcnVuIHRoZSBmaXh0dXJlIGNvbW1hbmQuIg0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIF0sDQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgImFjY2VwdGFuY2VfY2hlY2tzIjogIFsNCg0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBdLA0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICJwcm9tcHQiOiAgIiMjIEdvYWxcbkltcGxlbWVudCB0YXNrIDEgZXhhY3RseS4g4oCUIGZpbGVzOiBzcmMvbmV3LnR4dCDigJQgZG9uZSB3aGVuOiB0YXNrIDEgaXMgY29tcGxldGUuXG5Eb25lIHdoZW46IHRhc2sgMSBpcyBjb21wbGV0ZS5cblxuIyMgQ29udGV4dFxuLSBTcGVjOiAqKklkZW50aXR5OioqIEZpeHR1cmUgaWRlbnRpdHkgZm9yIGZpeHR1cmUtcGxhbi5cbi0gUmVwbzogPFJFUE8+XG4tIEZpbGVzIGZvciB0aGlzIHRhc2sgKGF1dGhvcml6ZWQgc2V0IC0gdG91Y2ggbm90aGluZyBlbHNlKTpcbi0gc3JjL25ldy50eHQgKGNyZWF0ZSlcbi0gSW50ZW50OlxuLSAqKkludGVudDoqKiBCdWlsZCB0aGUgZml4dHVyZS5cbi0gQXNzdW1wdGlvbnM6XG4tIFRoZSBmaXh0dXJlIGVudmlyb25tZW50IGlzIGF2YWlsYWJsZS5cblxuIyMgQ29uc3RyYWludHNcbi0gU3VyZ2ljYWwgc2NvcGU6IG9ubHkgdGhlIGZpbGVzIGxpc3RlZCBhYm92ZTsgYGdpdCBzdGF0dXMgLS1wb3JjZWxhaW4gLXVhbGxgIG11c3Qgc2hvdyBubyBwYXRoIG91dHNpZGUgdGhlbSB0aGF0IHdhcyBub3QgYWxyZWFkeSBkaXJ0eSB3aGVuIHlvdSBzdGFydGVkLiAoTk9UIGBnaXQgZGlmZiAtLXN0YXRgIOKAlCBhIGZpbGUgeW91IENSRUFURSBpcyB1bnRyYWNrZWQsIHNvIGl0IG5ldmVyIGFwcGVhcnMgdGhlcmUsIGFuZCB5b3UgbWF5IG5vdCBgZ2l0IGFkZGAgaXQgaW50byB2aWV3Lilcbi0gQXV0aG9yaXplZCBwYXRoczpcbi0gc3JjL25ldy50eHQgKGNyZWF0ZSlcbi0gU2NyYXRjaDogaWYgeW91IG5lZWQgYSBzY3JhdGNoIGRpcmVjdG9yeSwgY3JlYXRlIGAuY29kZXgtc2NyYXRjaC9gIGF0IHRoZSByZXBvIHJvb3QgYW5kIG5vd2hlcmUgZWxzZSDigJQgaXQgaXMgdGhlIG9ubHkgc2FuY3Rpb25lZCBuYW1lLiBgLnNjcmF0Y2hgLCBgLmFwZXgtdG1wYCBhbmQgYC5zYW5kYm94LWNhY2hlYCBhcmUgREVQUkVDQVRFRDogdGhleSBhcmUgc3RpbGwgZXhjbHVkZWQgZnJvbSB0aGUgc2NvcGUgY2hlY2sgb24gZXhpc3RpbmcgcmVwb3MsIHNvIHRoZXkgcmFpc2Ugbm8gdmlvbGF0aW9uLCBidXQgdGhleSBtYXkgbG9zZSB0aGF0IGV4Y2x1c2lvbiBpbiBhIGZ1dHVyZSByZXZpc2lvbiDigJQgZG8gbm90IHVzZSB0aGVtIGZvciBuZXcgd29yay4gQW55IG90aGVyIGludmVudGVkIG9yIHRhc2stc3VmZml4ZWQgdmFyaWFudCAoYC5jb2RleC1zY3JhdGNoLXRhc2syYCkgSVMgcmVwb3J0ZWQgYXMgYW4gb3V0LW9mLXNjb3BlIHdyaXRlLiBJZiB0aGlzIHJlcG8gZG9lcyBub3QgZ2l0aWdub3JlIGAuY29kZXgtc2NyYXRjaC9gLCBpdCB3aWxsIGZsYWcgYXMgYSBzY29wZSB2aW9sYXRpb24g4oCUIHJlcG9ydCB0aGF0LCBhbmQgZG8gTk9UIGFkZCBnaXRpZ25vcmUgZW50cmllcyB5b3Vyc2VsZi5cbiMjIyBTZWN1cml0eVxuS2VlcCBmaXh0dXJlIHdyaXRlcyBzY29wZWQuXG5cIkZvbGxvdyBBR0VOVFMubWQuIFN1cmdpY2FsIHNjb3BlIOKAlCB0b3VjaCBvbmx5IHRoZSBsaXN0ZWQgZmlsZXMuIFdvcmsgYXV0b25vbW91c2x5IHRvXG5jb21wbGV0aW9uOiBydW4gb25seSB0aGlzIHRhc2tcdTAwMjdzIHRhZ2dlZCBjaGVja3MgKG5ldmVyIHRoZSByZXBvc2l0b3J5IHZlcmlmeSByZWNpcGUpLCBhbmQgaWYgYSB0ZXN0IGZhaWxzIC8gbGludCBlcnJvcnMgLyB5b3UgaGl0IGEgcHJvYmxlbSwgZml4IGl0XG5hbmQgcmUtcnVuIOKAlCBkbyBub3Qgc3RvcCB0byBhc2suIE9ubHkgZW5kIHdoZW4gdGhlIGFjY2VwdGFuY2UgY3JpdGVyaW9uIHBhc3Nlcywgb3IgeW91IGFyZVxuZ2VudWluZWx5IGJsb2NrZWQg4oCUIHRoZW4gc2F5IGV4YWN0bHkgd2hhdCBibG9ja2VkIHlvdS4gU2FmZSBsb2NhbCBjaG9pY2UgKG1ha2UgaXQsIGxvZyBpdCBpblxuZGV2aWF0aW9ucyk6IHdoaWNoIGV4aXN0aW5nIHBhdHRlcm4gdG8gbWlycm9yLCBhIGxvY2FsIG5hbWUuIEJsb2NrZXIgKHJlcG9ydCBpbiBgYmxvY2tlcmAsIGRvblx1MDAyN3RcbmltcHJvdmlzZSk6IGFuIGFjY2VwdGFuY2UgY3JpdGVyaW9uIHRoYXQgY2Fubm90IHBhc3MgYXMgd3JpdHRlbiwgYSBuZWVkZWQgZmlsZSBvdXRzaWRlIHRoZVxuYXV0aG9yaXplZCBzZXQsIGEgbWlzc2luZyBjcmVkZW50aWFsLlwiXG5cbiMjIERvbmUtd2hlblxuLSBEb25lIHdoZW46IHRhc2sgMSBpcyBjb21wbGV0ZS5cbi0gWyBdIFRhc2sgMSAtIHRhc2sgMSBpcyBleGVjdXRhYmxlIC1cdTAwM2UgdmVyaWZ5OiBydW4gdGhlIGZpeHR1cmUgY29tbWFuZC5cbi0gVmVyaWZ5OiB0aGlzIHRhc2sgaGFzIG5vIHRhZ2dlZCBjaGVja3M7IGRvIG5vdCBydW4gdGhlIHJlcG9zaXRvcnkgdmVyaWZ5IHJlY2lwZSAodGhlIEVuZ2luZSBydW5zIGl0IGFmdGVyIGludGVncmF0aW9uKS5cbi0gRmluYWwgbWVzc2FnZTogSlNPTiBwZXIgdGhlIGNvbXBsZXRpb24gY29udHJhY3QgKC0tb3V0cHV0LXNjaGVtYSk6IHN0YXR1cywgY2hhbmdlZF9maWxlcyxcbiAgY29tbWFuZHNfcnVuICgrcmVzdWx0cyksIGRldmlhdGlvbnMsIHVucmVzb2x2ZWQsIGJsb2NrZXIuIiwNCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAicHJvbXB0X2RpZ2VzdCI6ICAiPFBST01QVF9ESUdFU1Q+Ig0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgfQ0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBdDQogICAgICAgICAgICAgICAgICB9DQogICAgICAgICAgICAgIF0sDQogICAgInNwZWNfYWNjZXB0YW5jZV9jaGVja3MiOiAgWw0KDQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgXSwNCiAgICAiaG9zdF9jaGVja3MiOiAgWw0KICAgICAgICAgICAgICAgICAgICAgICAgew0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICJsYWJlbCI6ICAiLSBbIF0gVGFzayAxIC0iLA0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICJ0ZXh0IjogICItIFsgXSBUYXNrIDEgLSB0YXNrIDEgaXMgZXhlY3V0YWJsZSAtXHUwMDNlIHZlcmlmeTogcnVuIHRoZSBmaXh0dXJlIGNvbW1hbmQuIg0KICAgICAgICAgICAgICAgICAgICAgICAgfQ0KICAgICAgICAgICAgICAgICAgICBdDQp9'))
        $expectedPrompt = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('IyMgR29hbApJbXBsZW1lbnQgdGFzayAxIGV4YWN0bHkuIOKAlCBmaWxlczogc3JjL25ldy50eHQg4oCUIGRvbmUgd2hlbjogdGFzayAxIGlzIGNvbXBsZXRlLgpEb25lIHdoZW46IHRhc2sgMSBpcyBjb21wbGV0ZS4KCiMjIENvbnRleHQKLSBTcGVjOiAqKklkZW50aXR5OioqIEZpeHR1cmUgaWRlbnRpdHkgZm9yIGZpeHR1cmUtcGxhbi4KLSBSZXBvOiA8UkVQTz4KLSBGaWxlcyBmb3IgdGhpcyB0YXNrIChhdXRob3JpemVkIHNldCAtIHRvdWNoIG5vdGhpbmcgZWxzZSk6Ci0gc3JjL25ldy50eHQgKGNyZWF0ZSkKLSBJbnRlbnQ6Ci0gKipJbnRlbnQ6KiogQnVpbGQgdGhlIGZpeHR1cmUuCi0gQXNzdW1wdGlvbnM6Ci0gVGhlIGZpeHR1cmUgZW52aXJvbm1lbnQgaXMgYXZhaWxhYmxlLgoKIyMgQ29uc3RyYWludHMKLSBTdXJnaWNhbCBzY29wZTogb25seSB0aGUgZmlsZXMgbGlzdGVkIGFib3ZlOyBgZ2l0IHN0YXR1cyAtLXBvcmNlbGFpbiAtdWFsbGAgbXVzdCBzaG93IG5vIHBhdGggb3V0c2lkZSB0aGVtIHRoYXQgd2FzIG5vdCBhbHJlYWR5IGRpcnR5IHdoZW4geW91IHN0YXJ0ZWQuIChOT1QgYGdpdCBkaWZmIC0tc3RhdGAg4oCUIGEgZmlsZSB5b3UgQ1JFQVRFIGlzIHVudHJhY2tlZCwgc28gaXQgbmV2ZXIgYXBwZWFycyB0aGVyZSwgYW5kIHlvdSBtYXkgbm90IGBnaXQgYWRkYCBpdCBpbnRvIHZpZXcuKQotIEF1dGhvcml6ZWQgcGF0aHM6Ci0gc3JjL25ldy50eHQgKGNyZWF0ZSkKLSBTY3JhdGNoOiBpZiB5b3UgbmVlZCBhIHNjcmF0Y2ggZGlyZWN0b3J5LCBjcmVhdGUgYC5jb2RleC1zY3JhdGNoL2AgYXQgdGhlIHJlcG8gcm9vdCBhbmQgbm93aGVyZSBlbHNlIOKAlCBpdCBpcyB0aGUgb25seSBzYW5jdGlvbmVkIG5hbWUuIGAuc2NyYXRjaGAsIGAuYXBleC10bXBgIGFuZCBgLnNhbmRib3gtY2FjaGVgIGFyZSBERVBSRUNBVEVEOiB0aGV5IGFyZSBzdGlsbCBleGNsdWRlZCBmcm9tIHRoZSBzY29wZSBjaGVjayBvbiBleGlzdGluZyByZXBvcywgc28gdGhleSByYWlzZSBubyB2aW9sYXRpb24sIGJ1dCB0aGV5IG1heSBsb3NlIHRoYXQgZXhjbHVzaW9uIGluIGEgZnV0dXJlIHJldmlzaW9uIOKAlCBkbyBub3QgdXNlIHRoZW0gZm9yIG5ldyB3b3JrLiBBbnkgb3RoZXIgaW52ZW50ZWQgb3IgdGFzay1zdWZmaXhlZCB2YXJpYW50IChgLmNvZGV4LXNjcmF0Y2gtdGFzazJgKSBJUyByZXBvcnRlZCBhcyBhbiBvdXQtb2Ytc2NvcGUgd3JpdGUuIElmIHRoaXMgcmVwbyBkb2VzIG5vdCBnaXRpZ25vcmUgYC5jb2RleC1zY3JhdGNoL2AsIGl0IHdpbGwgZmxhZyBhcyBhIHNjb3BlIHZpb2xhdGlvbiDigJQgcmVwb3J0IHRoYXQsIGFuZCBkbyBOT1QgYWRkIGdpdGlnbm9yZSBlbnRyaWVzIHlvdXJzZWxmLgojIyMgU2VjdXJpdHkKS2VlcCBmaXh0dXJlIHdyaXRlcyBzY29wZWQuCiJGb2xsb3cgQUdFTlRTLm1kLiBTdXJnaWNhbCBzY29wZSDigJQgdG91Y2ggb25seSB0aGUgbGlzdGVkIGZpbGVzLiBXb3JrIGF1dG9ub21vdXNseSB0bwpjb21wbGV0aW9uOiBydW4gb25seSB0aGlzIHRhc2sncyB0YWdnZWQgY2hlY2tzIChuZXZlciB0aGUgcmVwb3NpdG9yeSB2ZXJpZnkgcmVjaXBlKSwgYW5kIGlmIGEgdGVzdCBmYWlscyAvIGxpbnQgZXJyb3JzIC8geW91IGhpdCBhIHByb2JsZW0sIGZpeCBpdAphbmQgcmUtcnVuIOKAlCBkbyBub3Qgc3RvcCB0byBhc2suIE9ubHkgZW5kIHdoZW4gdGhlIGFjY2VwdGFuY2UgY3JpdGVyaW9uIHBhc3Nlcywgb3IgeW91IGFyZQpnZW51aW5lbHkgYmxvY2tlZCDigJQgdGhlbiBzYXkgZXhhY3RseSB3aGF0IGJsb2NrZWQgeW91LiBTYWZlIGxvY2FsIGNob2ljZSAobWFrZSBpdCwgbG9nIGl0IGluCmRldmlhdGlvbnMpOiB3aGljaCBleGlzdGluZyBwYXR0ZXJuIHRvIG1pcnJvciwgYSBsb2NhbCBuYW1lLiBCbG9ja2VyIChyZXBvcnQgaW4gYGJsb2NrZXJgLCBkb24ndAppbXByb3Zpc2UpOiBhbiBhY2NlcHRhbmNlIGNyaXRlcmlvbiB0aGF0IGNhbm5vdCBwYXNzIGFzIHdyaXR0ZW4sIGEgbmVlZGVkIGZpbGUgb3V0c2lkZSB0aGUKYXV0aG9yaXplZCBzZXQsIGEgbWlzc2luZyBjcmVkZW50aWFsLiIKCiMjIERvbmUtd2hlbgotIERvbmUgd2hlbjogdGFzayAxIGlzIGNvbXBsZXRlLgotIFsgXSBUYXNrIDEgLSB0YXNrIDEgaXMgZXhlY3V0YWJsZSAtPiB2ZXJpZnk6IHJ1biB0aGUgZml4dHVyZSBjb21tYW5kLgotIFZlcmlmeTogdGhpcyB0YXNrIGhhcyBubyB0YWdnZWQgY2hlY2tzOyBkbyBub3QgcnVuIHRoZSByZXBvc2l0b3J5IHZlcmlmeSByZWNpcGUgKHRoZSBFbmdpbmUgcnVucyBpdCBhZnRlciBpbnRlZ3JhdGlvbikuCi0gRmluYWwgbWVzc2FnZTogSlNPTiBwZXIgdGhlIGNvbXBsZXRpb24gY29udHJhY3QgKC0tb3V0cHV0LXNjaGVtYSk6IHN0YXR1cywgY2hhbmdlZF9maWxlcywKICBjb21tYW5kc19ydW4gKCtyZXN1bHRzKSwgZGV2aWF0aW9ucywgdW5yZXNvbHZlZCwgYmxvY2tlci4='))
        $expectedSpec = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('LS0tCnNwZWM6IGZpeHR1cmUtcGxhbgpyaXNrOiBtZWRpdW0KY29kZXJfZWZmb3J0OiBtZWRpdW0KLS0tCgojIFBsYW5uZXIgZml4dHVyZQoKKipJZGVudGl0eToqKiBGaXh0dXJlIGlkZW50aXR5IGZvciBmaXh0dXJlLXBsYW4uCgojIyBJbnRlbnQKLSAqKkludGVudDoqKiBCdWlsZCB0aGUgZml4dHVyZS4KCiMjIEFzc3VtcHRpb25zCi0gVGhlIGZpeHR1cmUgZW52aXJvbm1lbnQgaXMgYXZhaWxhYmxlLgoKIyMgUHJlcmVxdWlzaXRlcwotIFdpbmRvd3MgUG93ZXJTaGVsbCBpcyBhdmFpbGFibGUuCgojIyBGaWxlcyB0byBDaGFuZ2UKfCBGaWxlIHwgT3BlcmF0aW9uIHwgTm90ZXMgfAp8LS0tfC0tLXwtLS18Cnwgc3JjL25ldy50eHQgfCBjcmVhdGUgfCBmaXh0dXJlIHwKCiMjIEV4ZWN1dGlvbiBtYW5pZmVzdApgYGBqc29uIGFwZXgtbWFuaWZlc3QKew0KICAgICJ2ZXJzaW9uIjogIDEsDQogICAgInJlcG9zIjogIHsNCiAgICAgICAgICAgICAgICAgICJtYWluIjogICI8UkVQTz4iDQogICAgICAgICAgICAgIH0sDQogICAgInRhc2tzIjogIFsNCiAgICAgICAgICAgICAgICAgIHsNCiAgICAgICAgICAgICAgICAgICAgICAiaWQiOiAgIjEiLA0KICAgICAgICAgICAgICAgICAgICAgICJyZXBvIjogICJtYWluIiwNCiAgICAgICAgICAgICAgICAgICAgICAiZmlsZXMiOiAgWw0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgew0KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICJwYXRoIjogICJzcmMvbmV3LnR4dCIsDQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIm9wIjogICJjcmVhdGUiDQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICB9DQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIF0sDQogICAgICAgICAgICAgICAgICAgICAgImRlcGVuZHNfb24iOiAgWw0KDQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgXQ0KICAgICAgICAgICAgICAgICAgfQ0KICAgICAgICAgICAgICBdDQp9CmBgYAoKIyMgVGFza3MKLSBbIF0gKipUYXNrIDEqKiAtIEltcGxlbWVudCB0YXNrIDEgZXhhY3RseS4g4oCUIGZpbGVzOiBzcmMvbmV3LnR4dCDigJQgZG9uZSB3aGVuOiB0YXNrIDEgaXMgY29tcGxldGUuCgojIyBXYXZlIHBsYW4KVGhpcyBwcm9zZSBpcyBkZWxpYmVyYXRlbHkgbm9uLWF1dGhvcml0YXRpdmUuCgojIyBQZXJtaXNzaW9ucwotIFRoZSBmaXh0dXJlIHBhdGhzIG1heSBiZSBjaGFuZ2VkLgoKIyMgU3BlY2lhbGlzdCBDb250ZXh0CiMjIyBTZWN1cml0eQpLZWVwIGZpeHR1cmUgd3JpdGVzIHNjb3BlZC4KCiMjIyBBY2Nlc3NpYmlsaXR5Cihub25lKQoKIyMgRG9jdW1lbnRhdGlvbgotIE5vIGRvY3VtZW50YXRpb24gY2hhbmdlcyBhcmUgcmVxdWlyZWQuCgojIyBBY2NlcHRhbmNlIENyaXRlcmlhCi0gWyBdIFRhc2sgMSAtIHRhc2sgMSBpcyBleGVjdXRhYmxlIC0+IHZlcmlmeTogcnVuIHRoZSBmaXh0dXJlIGNvbW1hbmQuCgojIyBQcm9ncmVzcwotIE5vdCBzdGFydGVkLgo='))
        $fixture = New-Fixture
        $repo = ConvertTo-ForwardPath $fixture.Repo
        $expectedPrompt = $expectedPrompt.Replace('<REPO>', $repo)
        $expectedSpec = $expectedSpec.Replace('<REPO>', $repo)
        Assert-Equal ([IO.File]::ReadAllText($fixture.Spec)) $expectedSpec 'spec fixture bytes'
        $plan = Invoke-Plan $fixture
        $task = @(Get-PlannedTasks $plan)[0]
        Assert-Equal $task.prompt $expectedPrompt 'pre-change prompt bytes'
        Assert-Equal $task.prompt_digest (Get-EngineSha256 $expectedPrompt) 'raw pre-change prompt digest'
        $expectedJson = $expectedJson.Replace('<SPEC_DIGEST>', (Get-EngineSha256 $expectedSpec)).Replace('<PROMPT_DIGEST>', (Get-EngineSha256 $expectedPrompt))
        $actualJson = ($plan | ConvertTo-Json -Depth 30).Replace($repo, '<REPO>').Replace($fixture.Spec.Replace('\','\\'), '<SPEC>')
        Assert-Equal $actualJson $expectedJson 'pre-change serialized bytes'
        return $true
    }

    if (-not $ChainsOnly) {
    Assert-Case 'real validator compatible shared modify/modify chain' {
        $fixture = New-Fixture -Tasks @((New-Task '1' @((New-File 'shared.txt' 'modify')) -Chain 'real'), (New-Task '2' @((New-File 'shared.txt' 'modify')) -Chain 'real' -Depends '1'))
        Initialize-FixtureFiles $fixture
        $task = @(Get-PlannedTasks (Invoke-Plan $fixture -Validator $realValidator))[0]
        return ($task.members -join ',') -ceq '1,2' -and $task.files.Count -eq 1
    }

    # Shared in-memory prompt inputs: no payload quotes legacy instructions unless a case says so.
    $promptTemplate = [pscustomobject]@{ Surgical = '- Surgical scope: fixture'; Scratch = '- Scratch: local'; Autonomy = 'Follow AGENTS.md; run the verify recipe, then finish.'; Final = '- Final message: fixture' }
    $promptArgs = @{ Identity = 'fixture'; RepoPath = (Get-Location).Path; Intent = 'fixture'; Assumptions = 'fixture'; SpecialistContext = @(); VerifyFence = ('```text' + "`nRECIPE-COMMAND-SENTINEL`n" + '```'); Template = $promptTemplate }
    $ownVerify = "- Verify: run only this task's tagged checks above; do not run the repository verify recipe (the Engine runs it after integration)."
    $noneVerify = '- Verify: this task has no tagged checks; do not run the repository verify recipe (the Engine runs it after integration).'
    $engineClause = "run only this task's tagged checks (never the repository verify recipe)"

    Assert-Case 'real-validator declaration heading matrix and equivalent prompt bytes' {
        $rows = New-Object 'System.Collections.Generic.List[object]'
        $index = 0
        foreach ($bullet in @('-', '*', '+', '1.', '1)')) {
            foreach ($checkbox in @('', '[ ] ', '[x] ', '[X] ')) {
                foreach ($form in @('title', '-', [string][char]0x2013, [string][char]0x2014)) {
                    $rows.Add([pscustomobject]@{ Bullet = $bullet; Checkbox = $checkbox; Form = $form; Id = @('1', '1a')[$index % 2]; Indent = @('', " `t")[$index % 2]; BoldSpace = @('', " `t")[[int][Math]::Floor($index / 2) % 2] })
                    $index++
                }
            }
        }
        foreach ($row in $rows) {
            $id = $row.Id; $bullet = $row.Bullet; $checkbox = $row.Checkbox
            $form = $row.Form; $indent = $row.Indent; $boldSpace = $row.BoldSpace
            $fixture = New-Fixture -Tasks @(New-Task -Id $id -Files @(New-File -Path 'heading.txt'))
            $payload = "Alpha. files: heading.txt $([char]0x2014) done when: complete."
            $heading = if ($form -ceq 'title') { "**${boldSpace}Task $id - Alpha.** files: heading.txt $([char]0x2014) done when: complete." } else { "**${boldSpace}Task $id** $form $payload" }
            $source = [IO.File]::ReadAllText($fixture.Spec)
            $source = [regex]::Replace($source, '(?m)^- \[ \] \*\*Task [^\n]+', ($indent + $bullet + ' ' + $checkbox + $heading))
            Write-Utf8 $fixture.Spec $source
            $plan = Invoke-Plan -Fixture $fixture -Validator $realValidator
            if (-not $plan.allowed) { throw ('heading refused (including missing declaration): ' + $heading + ': ' + $plan.refusal) }
            $task = $plan.waves[0].tasks[0]
            if ($task.text -cne $payload -or $task.done_when -cne 'complete.') { throw 'heading extraction differs' }
            $expectedTask = [pscustomobject]@{ text = $payload; done_when = 'complete.'; files = $task.files; acceptance = $task.acceptance; acceptance_checks = $task.acceptance_checks }
            $template = Get-EngineTemplateParts (Join-Path (Split-Path -Parent $PSScriptRoot) 'references/dispatch-pack.md')
            $expected = New-EnginePrompt -Task $expectedTask -Identity '**Identity:** Fixture identity for fixture-plan.' -RepoPath $fixture.Repo -Intent $plan.spec.intent -Assumptions $plan.spec.assumptions -SpecialistContext $plan.spec.specialist_context -VerifyFence (Get-EngineVerifyFence (Join-Path $fixture.Repo 'AGENTS.md')) -Template $template
            if ($task.prompt -cne $expected) { throw 'equivalent heading prompt bytes differ' }
        }
        return $true
    }
    Assert-Case 'bare current-form bytes punctuation continuation and last completion' {
        foreach ($separator in @('-', [string][char]0x2013, [string][char]0x2014)) {
            foreach ($punctuation in @('- keep', ': keep', '. keep', ([string][char]0x2014 + ' keep'))) {
                $expected = "$punctuation done when: first.`n `tcontinuation  `n  done-when: last.  "
                $source = "## Tasks`r`n- [ ] **Task 1** $separator $($expected.Replace("`n", "`r`n"))`r`n`r`n## Other`r`n"
                $decl = Get-EngineTaskDeclarations $source
                if ($decl['1'].Text -cne $expected -or $decl['1'].DoneWhen -cne 'last.') { throw 'current-form bytes changed' }
                $task = [pscustomobject]@{ text = $decl['1'].Text; done_when = $decl['1'].DoneWhen; files = @([pscustomobject]@{ path = 'fixture.txt'; op = 'modify' }); acceptance = @(); acceptance_checks = @() }
                $prompt = New-EnginePrompt -Task $task @promptArgs
                # Explicit pre-change prompt layout for the same inputs; only the prescribed edits are allowed.
                $oldPrompt = @('## Goal', $expected, 'Done when: last.', '', '## Context', '- Spec: fixture', ('- Repo: ' + (ConvertTo-EngineDisplayPath $promptArgs.RepoPath)), "- Files for this task (authorized set - touch nothing else):`n- fixture.txt (modify)", "- Intent:`nfixture", "- Assumptions:`nfixture", '', '## Constraints', "- Surgical scope: fixture`n- Authorized paths:`n- fixture.txt (modify)`n- Scratch: local`n$($promptTemplate.Autonomy)", '', '## Done-when', "- Done when: last.`n- Verify: run the exact build-repo recipe commands:`n$($promptArgs.VerifyFence)`n- Final message: fixture") -join "`n"
                $expectedPrompt = $oldPrompt.Replace('run the verify recipe', $engineClause).Replace("- Verify: run the exact build-repo recipe commands:`n$($promptArgs.VerifyFence)", $noneVerify)
                if ($prompt -cne $expectedPrompt) { throw 'unexpected prompt byte change' }
                if ((Get-EngineSha256 $prompt) -ceq (Get-EngineSha256 $oldPrompt)) { throw 'old digest retained' }
            }
        }
        return $true
    }
    Assert-Case 'HOST OWNER boundaries fence decoys and exact section classification' {
        foreach ($kind in @('(HOST)', 'OWNER')) {
            foreach ($fence in @('````', '~~~~')) {
                $fixture = New-Fixture -Tasks @((New-Task -Id '1' -Files @(New-File 'one.txt')), (New-Task -Id '2' -Files @(New-File 'two.txt')))
                $body = "- [ ] **Task 1** - Alpha. files: one.txt $([char]0x2014) done when: first.`n  done when: own last.`n  $fence`n## Other`n- [ ] **Task 8** - fenced payload`n  $fence`n- [ ] **Task 9 $kind** - HOST-PAYLOAD done when: host marker.`n- [ ] **Task 2** - Beta. files: two.txt $([char]0x2014) done when: second.`n"
                $source = [regex]::Replace([IO.File]::ReadAllText($fixture.Spec), '(?ms)(## Tasks\n).*?(?=## Wave plan)', ('$1' + $body + "`n"))
                $source += "`n## Other`n- [ ] **Task 7** - outside payload`n"
                Write-Utf8 $fixture.Spec $source
                $plan = Invoke-Plan $fixture
                if (-not $plan.allowed) { throw $plan.refusal }
                $tasks = @($plan.waves | ForEach-Object { $_.tasks })
                $decl = Get-EngineTaskDeclarations $source
                if (($tasks.id -join ',') -cne '1,2' -or $decl.Count -ne 2 -or $tasks[0].text.Contains('HOST-PAYLOAD') -or $tasks[0].prompt.Contains('HOST-PAYLOAD') -or $tasks[0].done_when -cne 'own last.' -or -not $tasks[0].text.Contains('fenced payload') -or $tasks[1].done_when -cne 'second.') { throw 'boundary or completion leak' }
            }
        }
        foreach ($title in @('owner', 'HOMEOWNER', '(HOSTILE)')) {
            $decl = Get-EngineTaskDeclarations "## tasks`n- **Task 8** decoy`n ## Tasks`n- **Task 7** decoy`n## Tasks`n- **Task 1 $title** body`n## Other`n- **Task 9** decoy"
            if ($decl.Count -ne 1 -or $decl['1'].Text -cne "$title body") { throw 'case-sensitive classification failed' }
        }
        $modified = Get-EngineTaskDeclarations "## Tasks`n- [ ] **Task 1 (modify)** - : payload"
        if ($modified['1'].Text -cne '(modify) : payload') { throw 'in-bold title remainder lost' }
        # A shorter, wrong-character or non-whitespace suffix cannot close the opener.
        foreach ($fence in @('````', '~~~~')) {
            $other = if ($fence[0] -eq [char]96) { '~~~~' } else { '````' }
            $source = "## Tasks`n- **Task 1** body`n$fence`n$($fence.Substring(1))`n$other`n$fence suffix`n- **Task 8** decoy`n$fence`n## Other`n"
            $decl = Get-EngineTaskDeclarations $source
            if ($decl.Count -ne 1 -or -not $decl['1'].Text.Contains('Task 8')) { throw 'invalid fence closer accepted' }
        }
        return $true
    }
    Assert-Case 'own tagged checks Verify variants quoted payload and immutable template' {
        $savedAutonomy = $promptTemplate.Autonomy
        $livePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'references/dispatch-pack.md'
        $liveBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($livePath))
        $liveAutonomy = (Get-EngineTemplateParts $livePath).Autonomy
        foreach ($quoted in @($false, $true)) {
            foreach ($count in @(0, 1, 2, -1)) {
                $quote = if ($quoted) { 'run the verify recipe; run the exact build-repo recipe commands' } else { 'safe fixture payload' }
                $task = [pscustomobject]@{ text = "Alpha $quote"; done_when = 'complete'; files = @(); acceptance = @("criterion $quote"); acceptance_checks = @() }
                if ($count -eq -1) { $task.PSObject.Properties.Remove('acceptance_checks') }
                elseif ($count -gt 0) { $task.acceptance_checks = @(1..$count | ForEach-Object { [pscustomobject]@{ body = "Write-Output '$quote check $_'`n  # continuation  " } }) }
                $prompt = New-EnginePrompt -Task $task @promptArgs
                $verify = if ($count -gt 0) { $ownVerify } else { $noneVerify }
                if (@($prompt -split "`n" | Where-Object { $_ -ceq $verify }).Count -ne 1 -or $prompt.Contains($promptArgs.VerifyFence) -or $prompt.Contains('RECIPE-COMMAND-SENTINEL')) { throw 'Verify selection or recipe leak' }
                foreach ($check in @($task.acceptance_checks)) {
                    if ($null -ne $check -and -not $prompt.Contains("``````powershell apex-accept`n$($check.body)`n``````")) { throw 'tagged body changed' }
                }
                if (@([regex]::Matches($prompt, '(?m)^```powershell apex-accept$')).Count -ne [Math]::Max(0, $count)) { throw 'foreign tagged check embedded' }
                if (-not $prompt.Contains($task.text) -or -not $prompt.Contains($task.acceptance[0])) { throw 'quoted payload changed' }
                $injected = @($prompt -split "`n" | Where-Object { $_.StartsWith('Follow AGENTS.md;', [StringComparison]::Ordinal) -or $_.StartsWith('- Verify:', [StringComparison]::Ordinal) }) -join "`n"
                if ($injected -cne ($savedAutonomy.Replace('run the verify recipe', $engineClause) + "`n" + $verify)) { throw 'injected clauses differ' }
                $inspect = if ($quoted) { $injected } else { $prompt }
                foreach ($legacy in @('run the verify recipe', 'run the exact build-repo recipe commands')) {
                    if ($inspect.Contains($legacy)) { throw 'legacy instruction leaked' }
                }
                if ([regex]::Matches($prompt, [regex]::Escape($engineClause)).Count -ne 1 -or $promptTemplate.Autonomy -cne $savedAutonomy) { throw 'autonomy mutation or replacement count' }
            }
        }
        if ($liveAutonomy -cne (Get-EngineTemplateParts $livePath).Autonomy -or $liveBytes -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($livePath))) { throw 'live template changed' }
        return $true
    }
    Assert-Case 'planned tasks embed only their own multiple tagged bodies' {
        $fixture = New-Fixture -Tasks @((New-Task -Id '1' -Files @(New-File 'one.txt')), (New-Task -Id '2' -Files @(New-File 'two.txt')))
        $criteria = New-Object 'System.Collections.Generic.List[string]'
        foreach ($label in @('Task 1 - first', 'Task 1 - second', 'Task 2 - third', 'spec fixture')) {
            $criteria.Add("- [ ] $label`n``````powershell apex-accept`nWrite-Output '$label sentinel'`n  # keep whitespace  `n``````")
        }
        $source = [regex]::Replace([IO.File]::ReadAllText($fixture.Spec), '(?ms)(## Acceptance Criteria\n).*?(?=\n## Progress)', ('$1' + ($criteria.ToArray() -join "`n") + "`n"))
        Write-Utf8 $fixture.Spec $source
        $plan = Invoke-Plan $fixture
        if (-not $plan.allowed) { throw $plan.refusal }
        $tasks = @($plan.waves | ForEach-Object { $_.tasks })
        foreach ($task in $tasks) {
            if (@($task.prompt -split "`n" | Where-Object { $_ -ceq $ownVerify }).Count -ne 1) { throw 'missing own Verify line' }
            foreach ($check in $task.acceptance_checks) {
                if (-not $task.prompt.Contains("``````powershell apex-accept`n$($check.body)`n``````")) { throw 'own body bytes changed' }
            }
            $foreign = @($tasks | Where-Object { $_.id -cne $task.id } | ForEach-Object { $_.acceptance_checks }) + @($plan.spec_acceptance_checks)
            foreach ($check in $foreign) { if ($task.prompt.Contains($check.body)) { throw 'foreign body leaked' } }
            # These payloads contain neither legacy instruction string nor recipe commands.
            foreach ($value in @('node --check exact-one.js', 'powershell.exe -NoProfile -File exact-two.ps1', 'run the verify recipe', 'run the exact build-repo recipe commands')) {
                if ($task.prompt.Contains($value)) { throw 'repository verification leaked' }
            }
        }
        return @($tasks[0].acceptance_checks).Count -eq 2 -and @($tasks[1].acceptance_checks).Count -eq 1
    }
    Assert-Case 'autonomy drift direct throw and planning refusal without executable waves' {
        $original = (Get-Item Function:Get-EngineTemplateParts).ScriptBlock
        $fixture = New-Fixture
        $savedAutonomy = $promptTemplate.Autonomy
        try {
            foreach ($bad in @('Follow AGENTS.md; finish.', 'run the verify recipe; run the verify recipe', 'Run the verify recipe')) {
                $promptTemplate.Autonomy = $bad
                $task = [pscustomobject]@{ text = 'Alpha'; done_when = 'complete'; files = @(); acceptance = @() }
                $message = ''
                try { $null = New-EnginePrompt -Task $task @promptArgs } catch { $message = $_.Exception.Message }
                if ($message -notmatch 'live dispatch-pack.md autonomy drift' -or -not $message.Contains("exact-once substring 'run the verify recipe'")) { throw 'direct drift throw missing' }
                $stubTemplate = $promptTemplate
                Set-Item Function:Get-EngineTemplateParts -Value { param($TemplatePath) return $stubTemplate }.GetNewClosure()
                $plan = Invoke-Plan $fixture
                if ($plan.allowed -or @($plan.waves).Count -ne 0 -or $plan.refusal -cne $message) { throw 'drift did not refuse planning' }
            }
        } finally {
            Set-Item Function:Get-EngineTemplateParts -Value $original
            $promptTemplate.Autonomy = $savedAutonomy
        }
        return $true
    }

    Assert-Case 'raw UTF-8 marked blocks include unique markers and identical EOL and bytes' {
        $baselineBlock = Get-MarkedRecipeBytes -Path $baseline
        $plannerBlock = Get-MarkedRecipeBytes -Path $planner
        return Test-RecipeLockstep -Left $baselineBlock -Right $plannerBlock
    }
    Assert-Case 'mutated scratch copy fails the same raw-byte lockstep comparison' {
        $baselineBlock = Get-MarkedRecipeBytes -Path $baseline
        $plannerBlock = Get-MarkedRecipeBytes -Path $planner
        if (-not (Test-RecipeLockstep -Left $baselineBlock -Right $plannerBlock)) { throw 'live blocks already differ' }
        $scratch = Join-Path $testRoot 'mutated-engine-plan.ps1'
        $scratchBytes = [System.IO.File]::ReadAllBytes($planner)
        # Change the first body byte, preserving the markers, length, and EOL. Never run this copy.
        $mutationOffset = $plannerBlock.Offset + $utf8.GetByteCount('# BEGIN recipe-grammar lockstep' + $plannerBlock.Eol)
        $scratchBytes[$mutationOffset] = $scratchBytes[$mutationOffset] -bxor 1
        [System.IO.File]::WriteAllBytes($scratch, $scratchBytes)
        $scratchBlock = Get-MarkedRecipeBytes -Path $scratch
        return -not (Test-RecipeLockstep -Left $baselineBlock -Right $scratchBlock)
    }

    $fence = '```'
    $heading = '## Verify commands'
    $plainFence = @($fence, 'exit 0', $fence)
    $indentedFence = @('  ```cmd', '   exit 0', ' ```')
    $extraFence = @(' ```powershell extra', '  [void]$PSVersionTable; exit 0', '   ```')
    $decoy = @('```text', $heading, 'exit 0', $fence)
    $adjacencyDiagnostic = "[baseline] UNPARSEABLE -- '## Verify commands': recipe fence not immediately adjacent to heading."
    $parityRows = @(
        [pscustomobject]@{ Name = 'exact heading'; Lines = @($heading) + $indentedFence; Code = 0; Class = 'Accepted'; Fence = ($indentedFence -join "`n") }
        [pscustomobject]@{ Name = 'suffixed near-miss'; Lines = @('## Verify commands (deprecated)') + $plainFence; Code = 4; Class = 'NoHeading' }
        [pscustomobject]@{ Name = 'prose before fence'; Lines = @($heading, 'Caption before recipe') + $plainFence; Code = 3; Class = 'ParseError'; Diagnostic = $adjacencyDiagnostic }
        [pscustomobject]@{ Name = 'fenced decoy plus real heading'; Lines = $decoy + @('', $heading, '') + $indentedFence; Code = 0; Class = 'Accepted'; Fence = ($indentedFence -join "`n") }
        [pscustomobject]@{ Name = 'powershell extra'; Lines = @($heading) + $extraFence; Code = 0; Class = 'Accepted'; Fence = ($extraFence -join "`n") }
        [pscustomobject]@{ Name = 'unsupported shell'; Lines = @($heading, '```python', 'exit 0', $fence); Code = 3; Class = 'UnsupportedShell'; Diagnostic = "[baseline] UNPARSEABLE -- unsupported fence info-string 'python'." }
        [pscustomobject]@{ Name = 'empty fence'; Lines = @($heading, $fence, $fence); Code = 3; Class = 'NoRunnableCommands' }
        [pscustomobject]@{ Name = 'comment-only fence'; Lines = @($heading, $fence, '  # no commands', '', $fence); Code = 3; Class = 'NoRunnableCommands' }
        [pscustomobject]@{ Name = 'prose after close'; Lines = @($heading) + $plainFence + @('Prose after the recipe.'); Code = 0; Class = 'Accepted'; Fence = ($plainFence -join "`n") }
        [pscustomobject]@{ Name = 'decoy-only fenced heading'; Lines = $decoy; Code = 4; Class = 'NoHeading' }
        [pscustomobject]@{ Name = 'tilde fence'; Lines = @($heading, '~~~', 'exit 0', '~~~'); Code = 3; Class = 'ParseError'; Diagnostic = $adjacencyDiagnostic }
        [pscustomobject]@{ Name = 'unclosed fence'; Lines = @($heading, $fence, 'exit 0'); Code = 3; Class = 'UnclosedFence' }
        [pscustomobject]@{ Name = 'four-backtick opener'; Lines = @($heading, '````powershell', 'exit 0', $fence); Code = 3; Class = 'UnsupportedShell'; Diagnostic = "[baseline] UNPARSEABLE -- unsupported fence info-string '" + [char]96 + "powershell'." }
        [pscustomobject]@{ Name = 'second fence before next heading'; Lines = @($heading) + $plainFence + @('') + $plainFence; Code = 3; Class = 'ParseError'; Diagnostic = "[baseline] UNPARSEABLE -- '## Verify commands': ambiguous recipe: a second fence follows before the next heading." }
        [pscustomobject]@{ Name = 'info-string content without later closer'; Lines = @($heading, $fence, 'exit 0', '```python'); Code = 3; Class = 'UnclosedFence' }
        [pscustomobject]@{ Name = 'empty python fence'; Lines = @($heading, '```python', $fence); Code = 3; Class = 'NoRunnableCommands' }
    )
    $classExitCodes = @{ NoHeading = 4; ParseError = 3; UnclosedFence = 3; NoRunnableCommands = 3; UnsupportedShell = 3 }
    $classDiagnostics = @{
        NoHeading = '[baseline] NO_RECIPE -- AGENTS.md has none of the requested recipe headings: Preflight commands, Verify commands.'
        UnclosedFence = "[baseline] UNPARSEABLE -- '## Verify commands' recipe fence is not closed before EOF."
        NoRunnableCommands = "[baseline] UNPARSEABLE -- '## Verify commands' found but no runnable command block follows it."
    }
    Assert-Case 'parity matrix has all sixteen Verify-only rows' { return @($parityRows).Count -eq 16 }
    foreach ($row in $parityRows) {
        Assert-Case ('real baseline Preflight and planner parity: ' + $row.Name) {
            $fixture = New-Fixture
            $agentsPath = Join-Path $fixture.Repo 'AGENTS.md'
            # CRLF on disk also proves that selected/prompt fence strings use LF joining.
            Write-Utf8 -Path $agentsPath -Text ($row.Lines -join "`r`n")
            $observedBaseline = Invoke-BaselinePreflight -Repo $fixture.Repo
            $plan = Get-EnginePlan -SpecPath $fixture.Spec -Repo $fixture.Repo -MaxParallel 2 -ValidatorPath $realValidator
            if ($observedBaseline.ExitCode -ne $row.Code) {
                throw ('expected baseline exit {0}, got {1}: {2}' -f $row.Code, $observedBaseline.ExitCode, $observedBaseline.Output)
            }
            if ([bool]$plan.allowed -ne ($observedBaseline.ExitCode -eq 0)) { throw ('accept/reject mismatch: ' + $plan.refusal) }
            if ($row.Code -eq 0) {
                $selectedFence = Get-EngineVerifyFence -AgentsPath $agentsPath
                if ($selectedFence -cne $row.Fence) { throw 'selected FenceText differs from exact source fence' }
                $tasks = @($plan.waves | ForEach-Object { $_.tasks })
                if (@($tasks).Count -eq 0) { throw 'accepted plan has no task prompts' }
                foreach ($task in $tasks) {
                    # These fixture payloads contain no recipe commands or legacy instruction strings.
                    $verify = '- Verify: this task has no tagged checks; do not run the repository verify recipe (the Engine runs it after integration).'
                    if (@($task.prompt -split "`n" | Where-Object { $_ -ceq $verify }).Count -ne 1 -or
                        $task.prompt.Contains($row.Fence) -or $task.prompt.Contains('run the verify recipe') -or
                        $task.prompt.Contains('run the exact build-repo recipe commands')) { throw 'task-specific Verify or recipe omission failed' }
                }
            }
            else {
                if ($classExitCodes[$row.Class] -ne $observedBaseline.ExitCode) { throw 'classification does not map to baseline exit' }
                $expectedReasonPrefix = 'repo AGENTS.md: ' + $row.Class + ' (baseline exit ' + $observedBaseline.ExitCode + '): '
                if (-not $plan.refusal.StartsWith($expectedReasonPrefix, [System.StringComparison]::Ordinal)) {
                    throw ('expected distinct classification and exit mapping: ' + $plan.refusal)
                }
                $diagnostic = $classDiagnostics[$row.Class]
                if ($null -ne $row.PSObject.Properties['Diagnostic']) { $diagnostic = $row.Diagnostic }
                if (@($observedBaseline.Output -split "`n") -cnotcontains $diagnostic) { throw ('baseline classification diagnostic mismatch: ' + $observedBaseline.Output) }
                if ($observedBaseline.Output -match '\[baseline\] > ') { throw 'rejected recipe executed a command' }
                if (@($plan.waves).Count -ne 0) { throw 'rejected plan has executable waves' }
            }
            return $true
        }
    }
    Assert-Case 'zero-byte AGENTS retains baseline binding failure and distinct planner refusal' {
        $fixture = New-Fixture
        $agentsPath = Join-Path $fixture.Repo 'AGENTS.md'
        [IO.File]::WriteAllBytes($agentsPath, [byte[]]@())
        if (-not ((Get-Item -LiteralPath $agentsPath).Length -eq 0)) { throw 'fixture is not zero bytes' }
        $observedBaseline = Invoke-BaselinePreflight -Repo $fixture.Repo
        $plan = Get-EnginePlan -SpecPath $fixture.Spec -Repo $fixture.Repo -MaxParallel 2 -ValidatorPath $realValidator
        return $observedBaseline.ExitCode -eq 1 -and
            ($observedBaseline.Output -replace '\s+',' ') -match "Cannot bind argument to parameter 'Lines' because it is an empty array" -and
            $observedBaseline.Output -notmatch '\[baseline\] > ' -and
            -not $plan.allowed -and $plan.refusal -ceq 'repo AGENTS.md is empty' -and
            $plan.refusal -notmatch 'NoHeading|ParseError|UnclosedFence|NoRunnableCommands|UnsupportedShell|Accepted|baseline exit' -and
            @($plan.waves).Count -eq 0
    }

    Assert-Case 'dot-source preserves caller parameters EAP and StrictMode' {
        $child = Join-Path $testRoot 'dot-source-child.ps1'
        $escapedPlanner = $planner.Replace("'", "''")
        Write-Utf8 -Path $child -Text (@(
            "param("
            "    [string]`$SpecPath,"
            "    [string]`$Repo,"
            "    [int]`$MaxParallel"
            ")"
            "`$ErrorActionPreference = 'SilentlyContinue'"
            "Set-StrictMode -Version 2.0"
            "`$beforeEap = `$ErrorActionPreference"
            ". '$escapedPlanner'"
            "`$strictPreserved = `$false"
            "try { `$null = `$variableThatMustNotExist }"
            "catch { `$strictPreserved = `$true }"
            "[pscustomobject]@{"
            "    SpecPath = `$SpecPath"
            "    Repo = `$Repo"
            "    MaxParallel = `$MaxParallel"
            "    ErrorActionPreference = [string]`$ErrorActionPreference"
            "    StrictModePreserved = `$strictPreserved"
            "    AddedJson = [bool](Test-Path Variable:Json)"
            "    AddedValidatorPath = [bool](Test-Path Variable:ValidatorPath)"
            "} | ConvertTo-Json -Compress"
        ) -join "`n")
        $savedEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = @(& powershell.exe -NoProfile -File $child -SpecPath 'spec-sentinel' -Repo 'repo-sentinel' -MaxParallel 7)
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $savedEap }
        if ($code -ne 0) { return $false }
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
    Assert-Case 'risk high grammar' {
        $frontHigh = Invoke-Plan (New-Fixture -SpecOptions @{ Risk = 'high' })
        $frontHighIntent = Invoke-Plan (New-Fixture -SpecOptions @{ Risk = 'high'; Intent = '- **Intent:** This line declares RISK: HIGH for execution.' })
        $mediumIntent = Invoke-Plan (New-Fixture -SpecOptions @{ Risk = 'medium'; Intent = '- **Intent:** This line declares RISK: HIGH for execution.' })
        $absentIntent = Invoke-Plan (New-Fixture -SpecOptions @{ OmitRisk = $true; Intent = '- **Intent:** This line declares RISK: HIGH for execution.' })
        $empty = Invoke-Plan (New-Fixture -SpecOptions @{ Risk = '' })
        $other = Invoke-Plan (New-Fixture -SpecOptions @{ Risk = 'critical' })
        $nearFront = Invoke-Plan (New-Fixture -SpecOptions @{ Risk = 'highly' })
        $titleFront = Invoke-Plan (New-Fixture -SpecOptions @{ Risk = 'High' })
        $upperFront = Invoke-Plan (New-Fixture -SpecOptions @{ Risk = 'HIGH' })
        $near = New-Fixture -SpecOptions @{ Intent = '- **Intent:** This mentions risk: highly without declaring it.' }
        return $frontHigh.allowed -and $frontHigh.spec.risk -ceq 'high' -and
            $frontHighIntent.allowed -and $frontHighIntent.spec.risk -ceq 'high' -and
            -not $mediumIntent.allowed -and $mediumIntent.refusal -ceq 'Intent declares risk: high but frontmatter risk is not high' -and
            -not $absentIntent.allowed -and $absentIntent.refusal -ceq 'Intent declares risk: high but frontmatter risk is not high' -and
            -not $empty.allowed -and $empty.refusal -ceq 'frontmatter risk must be low, medium or high' -and
            -not $other.allowed -and $other.refusal -ceq 'frontmatter risk must be low, medium or high' -and
            -not $nearFront.allowed -and $nearFront.refusal -ceq 'frontmatter risk must be low, medium or high' -and
            -not $titleFront.allowed -and $titleFront.refusal -ceq 'frontmatter risk must be low, medium or high' -and
            -not $upperFront.allowed -and $upperFront.refusal -ceq 'frontmatter risk must be low, medium or high' -and (Invoke-Plan $near).allowed
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
        $default = Invoke-Plan (New-Fixture -SpecOptions @{ CoderModel = $null })
        $legacyPinned = Invoke-Plan (New-Fixture -SpecOptions @{ CoderModel = ('gpt-5.6' + '-sol') })
        $pinned = Invoke-Plan (New-Fixture -SpecOptions @{ CoderModel = 'gpt-6-sol' })
        $newPinned = Invoke-Plan (New-Fixture -SpecOptions @{ CoderModel = 'gpt-6.1-sol' })
        $alias = Invoke-Plan (New-Fixture -SpecOptions @{ CoderModel = 'codex' })
        $bad = Invoke-Plan (New-Fixture -SpecOptions @{ CoderModel = 'sonnet' })
        return $default.allowed -and $default.spec.coder_model -ceq 'gpt-6.1-sol' -and
            -not $legacyPinned.allowed -and
            $pinned.allowed -and $pinned.spec.coder_model -ceq 'gpt-6-sol' -and
            $newPinned.allowed -and $newPinned.spec.coder_model -ceq 'gpt-6.1-sol' -and
            $alias.allowed -and $alias.spec.coder_model -ceq 'gpt-6.1-sol' -and -not $bad.allowed
    }
    Assert-Case 'multiple repo keys and repo mismatch refuse' {
        $multi = New-Fixture -TwoRepos
        $mismatch = New-Fixture -RepoOverride 'C:/definitely/not/the/test/repo'
        return -not (Invoke-Plan $multi).allowed -and -not (Invoke-Plan $mismatch).allowed
    }
    Assert-Case 'linked branch worktree accepts with executable waves and target prompt' {
        $fixture = New-Fixture -LinkedWorktree
        $plan = Invoke-Plan $fixture
        return $plan.allowed -and @($plan.waves).Count -gt 0 -and
            @($plan.waves[0].tasks).Count -gt 0 -and $plan.waves[0].tasks[0].prompt.Contains((ConvertTo-ForwardPath $fixture.Repo))
    }
    Assert-Case 'linked create decision ignores a path existing only in the main tree' {
        $fixture = New-Fixture -LinkedWorktree
        Write-Utf8 -Path (Join-Path $fixture.ManifestRepo 'src/new.txt') -Text 'main only'
        $plan = Invoke-Plan $fixture
        return $plan.allowed -and @($plan.waves).Count -gt 0 -and
            -not (Test-Path -LiteralPath (Join-Path $fixture.Repo 'src/new.txt')) -and
            [IO.File]::ReadAllText((Join-Path $fixture.ManifestRepo 'src/new.txt')) -ceq 'main only'
    }
    Assert-Case 'linked create path existing only in the linked tree refuses' {
        $fixture = New-Fixture -LinkedWorktree
        Write-Utf8 -Path (Join-Path $fixture.Repo 'src/new.txt') -Text 'linked only'
        $plan = Invoke-Plan $fixture
        return -not $plan.allowed -and $plan.refusal -match 'create path already exists' -and
            -not (Test-Path -LiteralPath (Join-Path $fixture.ManifestRepo 'src/new.txt'))
    }
    Assert-Case 'linked create path tracked only on the linked branch refuses even when deleted' {
        $fixture = New-Fixture -LinkedWorktree
        $path = Join-Path $fixture.Repo 'src/new.txt'
        Write-Utf8 -Path $path -Text 'linked HEAD only'
        Set-TestCommit -Repo $fixture.Repo -Paths @('src/new.txt')
        Remove-Item -LiteralPath $path -Force
        $plan = Invoke-Plan $fixture
        return -not $plan.allowed -and $plan.refusal -match 'create path already exists' -and
            -not (Test-Path -LiteralPath (Join-Path $fixture.ManifestRepo 'src/new.txt'))
    }
    Assert-Case 'linked modify and delete decisions use linked dirtiness and ignore main dirtiness' {
        foreach ($op in @('modify', 'delete')) {
            $tasks = @(New-Task -Id '1' -Files @(New-File -Path 'src/existing.txt' -Op $op))
            $fixture = New-Fixture -LinkedWorktree -Tasks $tasks
            $mainPath = Join-Path $fixture.ManifestRepo 'src/existing.txt'
            Write-Utf8 -Path $mainPath -Text 'main dirty'
            $cleanPlan = Invoke-Plan $fixture
            Write-Utf8 -Path (Join-Path $fixture.Repo 'src/existing.txt') -Text 'linked dirty'
            $dirtyPlan = Invoke-Plan $fixture
            if (-not $cleanPlan.allowed -or @($cleanPlan.waves).Count -eq 0 -or $dirtyPlan.allowed -or
                $dirtyPlan.refusal -cne 'modify/delete path is dirty: src/existing.txt' -or
                [IO.File]::ReadAllText($mainPath) -cne 'main dirty') { return $false }
        }
        return $true
    }
    Assert-Case 'separate clone of manifest repository refuses with identity reason' {
        $fixture = New-Fixture -LinkedWorktree
        $clone = New-TestRepo -CloneFrom $fixture.ManifestRepo
        $plan = Get-EnginePlan -SpecPath $fixture.Spec -Repo $clone -MaxParallel 2 -ValidatorPath $successValidator
        return -not $plan.allowed -and $plan.refusal -ceq 'execution manifest repo does not match -Repo' -and @($plan.waves).Count -eq 0
    }
    Assert-Case 'manifest subdirectory refuses with identity reason' {
        $fixture = New-Fixture -LinkedWorktree
        $manifest = New-ManifestJson -Repo (Join-Path $fixture.ManifestRepo 'src') -Tasks $fixture.Tasks
        Write-Utf8 -Path $fixture.Spec -Text (New-SpecText -Name 'fixture-plan' -Manifest $manifest -Tasks $fixture.Tasks)
        $plan = Invoke-Plan $fixture
        return -not $plan.allowed -and $plan.refusal -ceq 'execution manifest repo does not match -Repo'
    }
    Assert-Case 'missing manifest directory refuses with identity reason' {
        $fixture = New-Fixture -LinkedWorktree
        $manifest = New-ManifestJson -Repo (Join-Path $fixture.ManifestRepo 'missing') -Tasks $fixture.Tasks
        Write-Utf8 -Path $fixture.Spec -Text (New-SpecText -Name 'fixture-plan' -Manifest $manifest -Tasks $fixture.Tasks)
        $plan = Invoke-Plan $fixture
        return -not $plan.allowed -and $plan.refusal -ceq 'execution manifest repo does not match -Repo'
    }
    Assert-Case 'Repo subdirectory of linked tree refuses with worktree-root reason' {
        $fixture = New-Fixture -LinkedWorktree
        $plan = Get-EnginePlan -SpecPath $fixture.Spec -Repo (Join-Path $fixture.Repo 'src') -MaxParallel 2 -ValidatorPath $successValidator
        return -not $plan.allowed -and $plan.refusal -ceq '-Repo must be the Git worktree root'
    }
    Assert-Case 'canonical string-equal root retains case-insensitive and trailing-separator acceptance' {
        $fixture = New-Fixture
        $manifest = New-ManifestJson -Repo $fixture.Repo -RepoOverride ((ConvertTo-ForwardPath $fixture.Repo).ToUpperInvariant() + '/') -Tasks $fixture.Tasks
        Write-Utf8 -Path $fixture.Spec -Text (New-SpecText -Name 'fixture-plan' -Manifest $manifest -Tasks $fixture.Tasks)
        $plan = Invoke-Plan $fixture
        return $plan.allowed -and @($plan.waves).Count -gt 0
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
    Assert-Case '.git metadata paths refuse before worktree creation' {
        $paths = @('.git/config', 'sub/.git/hooks/pre-commit', '.GIT/x', '.git./x', 'git~1/config', 'a/.git')
        foreach ($path in $paths) {
            $task = @(New-Task -Id '1' -Files @(New-File -Path $path))
            $fixture = New-Fixture -Tasks $task
            $worktreesPath = Join-Path $fixture.Repo '.git/worktrees'
            if (Test-Path -LiteralPath $worktreesPath) { throw ('fixture unexpectedly has linked worktrees for ' + $path) }
            $plan = Invoke-Plan $fixture
            if ($plan.allowed -or $plan.refusal -cne ('manifest path contains a .git segment: ' + $path)) {
                throw ('unexpected refusal for ' + $path + ': ' + $plan.refusal)
            }
            if (Test-Path -LiteralPath $worktreesPath) { throw ('planner created a worktree before refusing ' + $path) }
        }
        return $true
    }
    Assert-Case 'colon path refuses as Git metadata path' {
        $path = 'src/file.txt:stream'
        $task = @(New-Task -Id '1' -Files @(New-File -Path $path))
        $plan = Invoke-Plan (New-Fixture -Tasks $task)
        return -not $plan.allowed -and $plan.refusal -ceq ('manifest path contains a .git segment: ' + $path)
    }
    Assert-Case 'safe dot-prefixed paths are allowed' {
        $task = @(New-Task -Id '1' -Files @(
            (New-File -Path '.github/workflows/x.yml')
            (New-File -Path '.gitignore')
            (New-File -Path '.gitkeep')
        ))
        return (Invoke-Plan (New-Fixture -Tasks $task)).allowed
    }
    Assert-Case 'within-task ancestor overlap refuses' {
        $task = @(New-Task -Id '1' -Files @(
            (New-File -Path 'src')
            (New-File -Path 'src/child.txt')
        ))
        $plan = Invoke-Plan (New-Fixture -Tasks $task)
        return -not $plan.allowed -and $plan.refusal -ceq 'manifest paths overlap (ancestor/descendant): src, src/child.txt'
    }
    Assert-Case 'cross-task ancestor overlap refuses' {
        $tasks = @(
            (New-Task -Id '1' -Files @(New-File -Path 'src'))
            (New-Task -Id '2' -Files @(New-File -Path 'src/child.txt'))
        )
        $plan = Invoke-Plan (New-Fixture -Tasks $tasks)
        return -not $plan.allowed -and $plan.refusal -ceq 'manifest paths overlap (ancestor/descendant): src, src/child.txt'
    }
    Assert-Case 'case-variant ancestor overlap refuses' {
        $tasks = @(
            (New-Task -Id '1' -Files @(New-File -Path 'SRC'))
            (New-Task -Id '2' -Files @(New-File -Path 'src/x'))
        )
        $plan = Invoke-Plan (New-Fixture -Tasks $tasks)
        return -not $plan.allowed -and $plan.refusal -ceq 'manifest paths overlap (ancestor/descendant): SRC, src/x'
    }
    Assert-Case 'trimmed segment canonical duplicates refuse' {
        $leafTasks = @(
            (New-Task -Id '1' -Files @(New-File -Path 'foo.'))
            (New-Task -Id '2' -Files @(New-File -Path 'foo'))
        )
        $nestedTasks = @(
            (New-Task -Id '1' -Files @(New-File -Path 'foo./a'))
            (New-Task -Id '2' -Files @(New-File -Path 'foo/a'))
        )
        return -not (Invoke-Plan (New-Fixture -Tasks $leafTasks)).allowed -and
            -not (Invoke-Plan (New-Fixture -Tasks $nestedTasks)).allowed
    }
    Assert-Case 'path prefix with non-segment suffix does not overlap' {
        $tasks = @(
            (New-Task -Id '1' -Files @(New-File -Path 'src'))
            (New-Task -Id '2' -Files @(New-File -Path 'src-suffix/child.txt'))
        )
        return (Invoke-Plan (New-Fixture -Tasks $tasks)).allowed
    }
    Assert-Case 'regular-file ancestor refuses' {
        $task = @(New-Task -Id '1' -Files @(New-File -Path 'parent/child.txt'))
        $fixture = New-Fixture -Tasks $task
        Write-Utf8 -Path (Join-Path $fixture.Repo 'parent') -Text 'not a directory'
        $plan = Invoke-Plan $fixture
        return -not $plan.allowed -and $plan.refusal -ceq 'manifest path ancestor is a file: parent/child.txt'
    }
    Assert-Case 'task IDs allow 32 characters and refuse 33' {
        $id32 = '12345678901234567890123456789012'
        $id33 = '123456789012345678901234567890123'
        $allowedTask = @(New-Task -Id $id32 -Files @(New-File -Path 'id32.txt'))
        $refusedTask = @(New-Task -Id $id33 -Files @(New-File -Path 'id33.txt'))
        $allowed = Invoke-Plan (New-Fixture -Tasks $allowedTask)
        $refused = Invoke-Plan (New-Fixture -Tasks $refusedTask)
        return $allowed.allowed -and -not $refused.allowed -and
            $refused.refusal -ceq 'manifest task id exceeds 32 characters: 1234567890123456...'
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
    Assert-Case 'ancestor overlap refuses instead of splitting a topological layer' {
        $tasks = @(
            (New-Task -Id '1' -Files @(New-File -Path 'src'))
            (New-Task -Id '2' -Files @(New-File -Path 'src/child.txt'))
        )
        $plan = Invoke-Plan -Fixture (New-Fixture -Tasks $tasks) -MaxParallel 2
        return -not $plan.allowed -and @($plan.waves).Count -eq 0 -and
            $plan.refusal -ceq 'manifest paths overlap (ancestor/descendant): src, src/child.txt'
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
    Assert-Case 'template em-dash task label and fields are planned' {
        $path = 'src/em-dash.txt'
        $emDash = [string][char]0x2014
        $fixture = New-Fixture -Tasks @(New-Task -Id '1' -Files @(New-File -Path $path)) -SpecOptions @{
            TaskLabelSeparator = $emDash
            TaskFieldSeparator = $emDash
        }
        $plan = Invoke-Plan $fixture
        if (-not $plan.allowed) { throw ('em-dash fixture refused: ' + $plan.refusal) }
        $task = $plan.waves[0].tasks[0]
        return $task.text.Contains('files: ' + $path) -and
            @($task.files).Count -eq 1 -and $task.files[0].path -ceq $path -and
            $task.done_when -ceq 'task 1 is complete.'
    }
    Assert-Case 'en-dash task label with em-dash fields is planned' {
        $path = 'src/en-dash.txt'
        $enDash = [string][char]0x2013
        $emDash = [string][char]0x2014
        $fixture = New-Fixture -Tasks @(New-Task -Id '1' -Files @(New-File -Path $path)) -SpecOptions @{
            TaskLabelSeparator = $enDash
            TaskFieldSeparator = $emDash
        }
        $plan = Invoke-Plan $fixture
        if (-not $plan.allowed) { throw ('en-dash fixture refused: ' + $plan.refusal) }
        $task = $plan.waves[0].tasks[0]
        return $task.text.Contains('files: ' + $path) -and
            @($task.files).Count -eq 1 -and $task.files[0].path -ceq $path -and
            $task.done_when -ceq 'task 1 is complete.'
    }
    Assert-Case 'ASCII-hyphen task label is planned' {
        $path = 'src/ascii-hyphen.txt'
        $emDash = [string][char]0x2014
        $fixture = New-Fixture -Tasks @(New-Task -Id '1' -Files @(New-File -Path $path)) -SpecOptions @{
            TaskLabelSeparator = '-'
            TaskFieldSeparator = $emDash
        }
        $plan = Invoke-Plan $fixture
        if (-not $plan.allowed) { throw ('ASCII-hyphen fixture refused: ' + $plan.refusal) }
        $task = $plan.waves[0].tasks[0]
        return $task.text.Contains('files: ' + $path) -and
            @($task.files).Count -eq 1 -and $task.files[0].path -ceq $path -and
            $task.done_when -ceq 'task 1 is complete.'
    }
    Assert-Case 'all-none specialist context produces prompts for every task' {
        $tasks = @(
            (New-Task -Id '1' -Files @(New-File -Path 'none-one.txt'))
            (New-Task -Id '2' -Files @(New-File -Path 'none-two.txt'))
        )
        $specialist = "### Security`n(none)`n`n### Performance`n(none)`n`n### Accessibility`n(none)"
        $plan = Invoke-Plan (New-Fixture -Tasks $tasks -SpecOptions @{ Specialist = $specialist })
        if (-not $plan.allowed) { throw ('all-none specialist fixture refused: ' + $plan.refusal) }
        $plannedTasks = @($plan.waves | ForEach-Object { $_.tasks })
        return $plannedTasks.Count -eq $tasks.Count -and
            @($plannedTasks | Where-Object { [string]::IsNullOrWhiteSpace($_.prompt) }).Count -eq 0
    }
    Assert-Case 'exact live-template slots commands and prompt digest' {
        # Own task/acceptance payloads contain neither recipe commands nor either legacy substring.
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
            autonomy = $task.prompt.Contains("run only this task's tagged checks (never the repository verify recipe)") -and -not $task.prompt.Contains('run the verify recipe') -and -not $task.prompt.Contains('run the exact build-repo recipe commands')
            command_one = -not $task.prompt.Contains('node --check exact-one.js')
            command_two = -not $task.prompt.Contains('powershell.exe -NoProfile -File exact-two.ps1')
            digest = $task.prompt_digest -eq (Get-EngineSha256 -Text $task.prompt)
        }
        if (@($checks.GetEnumerator() | Where-Object { -not $_.Value }).Count -gt 0) { throw ('prompt checks failed: ' + (($checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key }) -join ',')) }
        return $plan.allowed -and $task.text -match 'Implement task 1 exactly' -and
            $task.done_when -eq 'task 1 is complete.' -and @($task.acceptance).Count -eq 1 -and
            $task.prompt.Contains('SECURITY-HAZARD-VERBATIM') -and $task.prompt.Contains('PERFORMANCE-HAZARD-VERBATIM') -and
            -not $task.prompt.Contains('### Accessibility') -and $task.prompt.Contains('- Scratch:') -and
            $task.prompt.Contains("run only this task's tagged checks (never the repository verify recipe)") -and -not $task.prompt.Contains('node --check exact-one.js') -and
            -not $task.prompt.Contains('powershell.exe -NoProfile -File exact-two.ps1') -and
            -not $task.prompt.Contains('run the verify recipe') -and -not $task.prompt.Contains('run the exact build-repo recipe commands') -and
            $task.prompt_digest -eq (Get-EngineSha256 -Text $task.prompt)
    }
    $vectors = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'references/accept-grammar-vectors.json') -Raw | ConvertFrom-Json
    foreach ($vector in $vectors) {
        Assert-Case ('shared acceptance grammar: ' + $vector.text) {
            $refused = @(Get-EngineAcceptanceGrammarRefusals $vector.text).Count -gt 0
            return $refused -eq ($vector.expected -ceq 'refuse')
        }
    }
    Assert-Case 'tagged criterion binding IDs verbatim HOST text labels and prompt' {
        $fixture = New-Fixture
        $acceptanceText = @'
- [X] Task 1 - tagged fixture
```powershell apex-accept
Write-Output 'task one'
exit 0
```
- [ ] unlabelled spec fixture
```powershell apex-accept
Write-Output 'spec check'
```
- [ ] Task 1 - retained HOST criterion
  retained continuation
- [ ] Task 9 - HOST-only criterion
```powershell
Set-Location C:/untagged
```
'@
        $acceptanceText = $acceptanceText.Replace('retained HOST criterion', 'retained HOST criterion  ')
        $text = [IO.File]::ReadAllText($fixture.Spec)
        $text = [regex]::Replace($text, '(?ms)(## Acceptance Criteria\n).*?(?=\n## Progress)', ('$1' + $acceptanceText + "`n"))
        $text += "`n## Other`n``````powershell apex-accept`nSet-Location C:/outside`n```````n"
        Write-Utf8 $fixture.Spec $text
        $plan = Invoke-Plan $fixture
        if (-not $plan.allowed) { throw $plan.refusal }
        $check = $plan.waves[0].tasks[0].acceptance_checks[0]
        return $check.id -ceq '1-1' -and $check.task -ceq '1' -and $check.label -ceq '- [X] Task 1 -' -and
            $check.body -ceq "Write-Output 'task one'`nexit 0" -and
            $plan.spec_acceptance_checks[0].id -ceq 'spec-1' -and $null -eq $plan.spec_acceptance_checks[0].task -and
            $null -eq $plan.spec_acceptance_checks[0].label -and @($plan.host_checks).Count -eq 2 -and
            $plan.host_checks[0].text -ceq "- [ ] Task 1 - retained HOST criterion  `n  retained continuation" -and
            $plan.host_checks[0].label -ceq '- [ ] Task 1 -' -and
            $plan.host_checks[1].text.Contains('Set-Location C:/untagged') -and
            $plan.waves[0].tasks[0].prompt.Contains("``````powershell apex-accept`n$($check.body)`n``````")
    }
    foreach ($label in @('Task 1 and Task 2', 'Task 12', 'Task 9 (HOST)')) {
        Assert-Case ('tagged leading label refusal: ' + $label) {
            $fixture = New-Fixture
            $text = [IO.File]::ReadAllText($fixture.Spec)
            $criterion = "- [ ] $label - bad binding`n``````powershell apex-accept`nexit 0`n```````n"
            Write-Utf8 $fixture.Spec ([regex]::Replace($text, '(?ms)(## Acceptance Criteria\n).*?(?=\n## Progress)', ('$1' + $criterion)))
            $plan = Invoke-Plan $fixture
            return -not $plan.allowed -and $plan.refusal -match '(unknown manifest task|compound or invalid task label)'
        }
    }
    Assert-Case 'tagged valid HOST task label absent from execution manifest refuses' {
        $fixture = New-Fixture
        $text = [IO.File]::ReadAllText($fixture.Spec)
        $text = $text.Replace('## Wave plan', "- [ ] **Task 9 (HOST)** - owner review.`n`n## Wave plan")
        $criterion = "- [ ] Task 9 - HOST review`n``````powershell apex-accept`nexit 0`n```````n"
        Write-Utf8 $fixture.Spec ([regex]::Replace($text, '(?ms)(## Acceptance Criteria\n).*?(?=\n## Progress)', ('$1' + $criterion)))
        $plan = Invoke-Plan $fixture
        return -not $plan.allowed -and $plan.refusal -ceq 'tagged acceptance check has unknown manifest task: 9'
    }
    Assert-Case 'only exact tag and actual Acceptance Criteria heading execute' {
        $text = @'
```markdown
## Acceptance Criteria
```powershell apex-accept
Set-Location C:/fake
```
## Acceptance Criteria
- [ ] ordinary criterion
```PowerShell apex-accept
Set-Location C:/untagged
```
- [ ] also ordinary
```powershell apex-accept extra
Set-Location C:/untagged
```
'@
        $parsed = Get-EngineAcceptanceLines $text -ManifestIds @('1')
        return @($parsed.checks).Count -eq 0 -and @($parsed.host_checks).Count -eq 2
    }
    Assert-Case 'JSON CLI emits the pinned object' {
        $fixture = New-Fixture
        $savedEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $json = @(& powershell.exe -NoProfile -File $planner -SpecPath $fixture.Spec -Repo $fixture.Repo -MaxParallel 2 -ValidatorPath $successValidator -Json 2>&1 | ForEach-Object { $_.ToString() })
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $savedEap }
        if ($code -ne 0) { return $false }
        $parsed = ($json -join "`n") | ConvertFrom-Json
        return $parsed.allowed -and $parsed.spec.name -eq 'fixture-plan' -and @($parsed.waves).Count -eq 1
    }
    }
}
finally {
    $env:APEX_STATE_DIR = $savedStateDir
    $env:GIT_CONFIG_GLOBAL = $savedGitConfigGlobal
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
