[CmdletBinding()]
param()

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
        [string]$TaskLabelSeparator = '-',
        [string]$TaskFieldSeparator,
        [switch]$NoSpec,
        [switch]$OmitRisk,
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
    if (-not $OmitRisk -and $null -ne $Risk) { [void]$front.Add('risk: ' + $Risk) }
    if (-not [string]::IsNullOrEmpty($CoderModel)) { [void]$front.Add('coder_model: ' + $CoderModel) }
    if ($null -ne $CoderEffort) { [void]$front.Add('coder_effort: ' + $CoderEffort) }
    if ($null -ne $MaxParallelCodex) { [void]$front.Add('max_parallel_codex: ' + $MaxParallelCodex) }
    [void]$front.Add('---')

    $fileRows = New-Object 'System.Collections.Generic.List[string]'
    $taskRows = New-Object 'System.Collections.Generic.List[string]'
    $acceptanceRows = New-Object 'System.Collections.Generic.List[string]'
    $emDash = [string][char]0x2014
    if ([string]::IsNullOrEmpty($TaskFieldSeparator)) { $TaskFieldSeparator = $emDash }
    foreach ($task in $Tasks) {
        foreach ($file in @($task.files)) { [void]$fileRows.Add('| ' + $file.path + ' | ' + $file.op + ' | fixture |') }
        $paths = @($task.files | ForEach-Object { $_.path }) -join ', '
        [void]$taskRows.Add(('- [ ] **Task {0}** {1} Implement task {0} exactly. {2} files: {3} {2} done when: task {0} is complete.' -f $task.id, $TaskLabelSeparator, $TaskFieldSeparator, $paths))
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
                    $promptFences = [regex]::Matches($task.prompt,
                        '(?ms)^- Verify: run the exact build-repo recipe commands:\n(?<Fence>.*?)(?=\n- Final message:|\z)')
                    if (@($promptFences).Count -ne 1 -or $promptFences[0].Groups['Fence'].Value -cne $row.Fence) {
                        throw 'prompt fence differs from exact source fence (including info string and whitespace)'
                    }
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
