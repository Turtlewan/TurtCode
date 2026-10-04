function ConvertTo-EngineLfText {
    param([AllowEmptyString()][string]$Text)

    if ($null -eq $Text) { return '' }
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Invoke-EnginePlanNative {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ArgumentList
    )

    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    return [pscustomobject]@{
        exit_code = $exitCode
        output = $output
    }
}

function Get-EngineSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $bytes = $utf8.GetBytes((ConvertTo-EngineLfText -Text $Text))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-EngineSectionBody {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Heading
    )

    $pattern = '(?ms)^##[ \t]+' + [regex]::Escape($Heading) + '[ \t]*\n(?<Body>.*?)(?=^##[ \t]+|\z)'
    $match = [regex]::Match((ConvertTo-EngineLfText -Text $Text), $pattern)
    if (-not $match.Success) { return '' }
    return $match.Groups['Body'].Value.TrimEnd("`n")
}

function ConvertTo-EngineCanonicalRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if (-not [string]::Equals($full, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $full = $full.TrimEnd([char[]]@([char]92, [char]47))
    }
    return $full
}

function ConvertTo-EngineDisplayPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $Path.Replace([char]92, [char]47)
}

function New-EnginePlanSpec {
    param(
        [string]$Name,
        [string]$Path,
        [string]$Digest,
        [string]$Risk = 'medium',
        [string]$CoderModel = 'gpt-5.6-sol',
        [string]$CoderEffort = 'medium',
        [object]$MaxParallelCodex = $null,
        [string]$Intent = '',
        [string]$Assumptions = '',
        [object[]]$SpecialistContext = @()
    )

    return [pscustomobject][ordered]@{
        name = $Name
        path = $Path
        digest = $Digest
        risk = $Risk
        coder_model = $CoderModel
        coder_effort = $CoderEffort
        max_parallel_codex = $MaxParallelCodex
        intent = $Intent
        assumptions = $Assumptions
        specialist_context = @($SpecialistContext)
    }
}

function New-EngineRefusal {
    param(
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][object]$Spec
    )

    return [pscustomobject][ordered]@{
        allowed = $false
        refusal = $Reason
        spec = $Spec
        waves = @()
    }
}

function Test-EngineRelativeManifestPath {
    param([object]$Path)

    if (-not ($Path -is [string]) -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -match '\\' -or $Path.Contains(':') -or $Path.StartsWith('/') -or
        $Path.EndsWith('/') -or $Path.Contains('//')) { return $false }
    foreach ($segment in $Path.Split('/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or $segment -eq '..') { return $false }
    }
    return $true
}

function ConvertTo-EngineCanonicalManifestPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $segments = @($Path.Split('/') | ForEach-Object {
        $_.TrimEnd([char[]]@([char]46, [char]32)).ToLowerInvariant()
    })
    return ($segments -join '/')
}

function Test-EngineGitMetadataManifestPath {
    param([string]$Path)

    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if ($Path.Contains(':')) { return $true }
    foreach ($segment in $Path.Split('/')) {
        $canonicalSegment = $segment.TrimEnd([char[]]@([char]46, [char]32)).ToLowerInvariant()
        if ($canonicalSegment -ceq '.git' -or $canonicalSegment -cmatch '^git~[0-9]+$') { return $true }
    }
    return $false
}

function Test-EnginePathOverlap {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $a = ConvertTo-EngineCanonicalManifestPath -Path $Left.TrimEnd('/')
    $b = ConvertTo-EngineCanonicalManifestPath -Path $Right.TrimEnd('/')
    return $a -eq $b -or $a.StartsWith($b + '/') -or $b.StartsWith($a + '/')
}

function Get-EngineSpecialistContext {
    param([Parameter(Mandatory = $true)][string]$Text)

    $body = Get-EngineSectionBody -Text $Text -Heading 'Specialist Context'
    if ([string]::IsNullOrWhiteSpace($body)) { return }
    $matches = [regex]::Matches($body, '(?ms)^###[ \t]+[^\n]+\n.*?(?=^###[ \t]+|\z)')
    $items = New-Object 'System.Collections.Generic.List[object]'
    if ($matches.Count -eq 0) {
        if ($body.Trim() -notmatch '^\(?none\)?[.!]?$') { $items.Add($body.TrimEnd("`n")) }
    }
    else {
        foreach ($match in $matches) {
            $value = $match.Value.TrimEnd("`n")
            $parts = $value -split "`n", 2
            $subsectionBody = ''
            if ($parts.Count -gt 1) { $subsectionBody = $parts[1].Trim() }
            if ($subsectionBody -notmatch '^\(?none\)?[.!]?$') { $items.Add($value) }
        }
    }
    return $items.ToArray()
}

function Get-EngineVerifyFence {
    param([Parameter(Mandatory = $true)][string]$AgentsPath)

    if (-not (Test-Path -LiteralPath $AgentsPath -PathType Leaf)) { throw 'repo AGENTS.md is missing' }
    $text = ConvertTo-EngineLfText -Text ([System.IO.File]::ReadAllText($AgentsPath))
    $section = [regex]::Match($text, '(?ms)^##[ \t]+Verify commands[ \t]*\n(?<Body>.*?)(?=^##[ \t]+|\z)')
    if (-not $section.Success) { throw 'repo AGENTS.md has no Verify commands section' }
    $fence = [regex]::Match($section.Groups['Body'].Value, '(?ms)^(?<Open>`{3,}|~{3,})[^\n]*\n(?<Commands>.*?)^(?<Close>`{3,}|~{3,})[ \t]*$')
    if (-not $fence.Success) { throw 'repo AGENTS.md Verify commands section has no command fence' }
    return $fence.Value.TrimEnd("`n")
}

function Get-EngineTemplateParts {
    param([Parameter(Mandatory = $true)][string]$TemplatePath)

    if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) { throw 'live dispatch-pack.md is missing' }
    $text = ConvertTo-EngineLfText -Text ([System.IO.File]::ReadAllText($TemplatePath))
    $scratch = [regex]::Match($text, '(?m)^- Scratch:.*$')
    $surgical = [regex]::Match($text, '(?m)^- Surgical scope:.*$')
    $autonomySection = [regex]::Match($text, '(?ms)^## Autonomy clause[^\n]*\n(?<Body>.*?)(?=^## |\z)')
    $autonomy = [regex]::Match($autonomySection.Groups['Body'].Value, '(?ms)^"Follow AGENTS\.md\..*?credential\."[ \t]*$')
    $finalLine = [regex]::Match($text, '(?m)^- Final message: JSON per the completion contract.*(?:\n[ \t]+commands_run.*)?$')
    if (-not $scratch.Success -or -not $autonomy.Success) { throw 'live dispatch-pack.md required clauses are missing' }
    return [pscustomobject]@{
        Scratch = $scratch.Value
        Surgical = $surgical.Value
        Autonomy = $autonomy.Value.TrimEnd("`n")
        Final = $finalLine.Value.TrimEnd("`n")
    }
}

function Get-EngineTaskDeclarations {
    param([Parameter(Mandatory = $true)][string]$Text)

    $tasksBody = Get-EngineSectionBody -Text $Text -Heading 'Tasks'
    $matches = [regex]::Matches($tasksBody, '(?ms)^- \[[ xX]\][ \t]+\*\*Task[ \t]+(?<Id>[0-9]+[A-Za-z]?)(?:[^*]*)\*\*[ \t]*-[ \t]*(?<Text>.*?)(?=^- \[[ xX]\][ \t]+\*\*Task[ \t]+|\z)')
    $result = @{}
    foreach ($match in $matches) {
        $id = $match.Groups['Id'].Value.ToLowerInvariant()
        $taskText = $match.Groups['Text'].Value.TrimEnd("`n")
        $doneMatches = [regex]::Matches($taskText, '(?i)done[ -]when:[ \t]*(?<Done>[^\n]+)')
        $doneWhen = ''
        if ($doneMatches.Count -gt 0) { $doneWhen = $doneMatches[$doneMatches.Count - 1].Groups['Done'].Value.Trim() }
        $result[$id] = [pscustomobject]@{ Text = $taskText; DoneWhen = $doneWhen }
    }
    return $result
}

function Get-EngineAcceptanceLines {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$TaskId
    )

    $body = Get-EngineSectionBody -Text $Text -Heading 'Acceptance Criteria'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ($body -split "`n")) {
        if ($line -match ('(?i)\bTask[ \t]+' + [regex]::Escape($TaskId) + '(?![A-Za-z0-9])')) { $lines.Add($line) }
    }
    return $lines.ToArray()
}

function New-EnginePrompt {
    param(
        [Parameter(Mandatory = $true)][object]$Task,
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$Intent,
        [Parameter(Mandatory = $true)][string]$Assumptions,
        [Parameter(Mandatory = $true)][object[]]$SpecialistContext,
        [Parameter(Mandatory = $true)][string]$VerifyFence,
        [Parameter(Mandatory = $true)][object]$Template
    )

    $fileLines = @($Task.files | ForEach-Object { '- {0} ({1})' -f $_.path, $_.op }) -join "`n"
    $acceptance = @($Task.acceptance) -join "`n"
    $hazards = @($SpecialistContext) -join "`n`n"
    $constraintLines = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrEmpty($Template.Surgical)) { $constraintLines.Add($Template.Surgical) }
    $constraintLines.Add("- Authorized paths:`n$fileLines")
    $constraintLines.Add($Template.Scratch)
    if (-not [string]::IsNullOrWhiteSpace($hazards)) { $constraintLines.Add($hazards) }
    $constraintLines.Add($Template.Autonomy)

    $doneLines = New-Object 'System.Collections.Generic.List[string]'
    $doneLines.Add('- Done when: ' + $Task.done_when)
    if (-not [string]::IsNullOrWhiteSpace($acceptance)) { $doneLines.Add($acceptance) }
    $doneLines.Add("- Verify: run the exact build-repo recipe commands:`n" + $VerifyFence)
    if (-not [string]::IsNullOrEmpty($Template.Final)) { $doneLines.Add($Template.Final) }

    $prompt = @(
        '## Goal',
        $Task.text,
        ('Done when: ' + $Task.done_when),
        '',
        '## Context',
        ('- Spec: ' + $Identity),
        ('- Repo: ' + (ConvertTo-EngineDisplayPath -Path $RepoPath)),
        "- Files for this task (authorized set - touch nothing else):`n$fileLines",
        "- Intent:`n$Intent",
        "- Assumptions:`n$Assumptions",
        '',
        '## Constraints',
        ($constraintLines.ToArray() -join "`n"),
        '',
        '## Done-when',
        ($doneLines.ToArray() -join "`n")
    ) -join "`n"
    return (ConvertTo-EngineLfText -Text $prompt).TrimEnd("`n")
}

function Get-EnginePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SpecPath,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][int]$MaxParallel,
        [string]$ValidatorPath
    )

    $emptySpec = New-EnginePlanSpec -Name $null -Path $SpecPath -Digest $null -MaxParallelCodex $null
    if ($MaxParallel -lt 1) { return New-EngineRefusal -Reason 'max_parallel must be at least 1' -Spec $emptySpec }
    if (-not [System.IO.Path]::IsPathRooted($SpecPath)) { return New-EngineRefusal -Reason 'spec path must be absolute' -Spec $emptySpec }
    if (($SpecPath -split '[\\/]') -contains '..') { return New-EngineRefusal -Reason 'spec path traversal is not allowed' -Spec $emptySpec }

    try { $fullSpecPath = [System.IO.Path]::GetFullPath($SpecPath) }
    catch { return New-EngineRefusal -Reason 'spec path is invalid' -Spec $emptySpec }
    $emptySpec.path = $fullSpecPath
    if (-not (Test-Path -LiteralPath $fullSpecPath -PathType Leaf)) { return New-EngineRefusal -Reason 'spec file is missing' -Spec $emptySpec }
    if (-not [System.IO.Path]::IsPathRooted($Repo)) { return New-EngineRefusal -Reason 'repo path must be absolute' -Spec $emptySpec }
    try { $repoRoot = ConvertTo-EngineCanonicalRoot -Path $Repo }
    catch { return New-EngineRefusal -Reason 'repo path is invalid' -Spec $emptySpec }
    if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) { return New-EngineRefusal -Reason 'repo root is missing' -Spec $emptySpec }

    try {
        $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
        $specText = ConvertTo-EngineLfText -Text ([System.IO.File]::ReadAllText($fullSpecPath, $utf8Strict))
        $specDigest = Get-EngineSha256 -Text $specText
    }
    catch { return New-EngineRefusal -Reason 'spec is not valid UTF-8' -Spec $emptySpec }

    $frontmatter = @{}
    $specLines = @($specText -split "`n")
    $frontmatterLines = New-Object 'System.Collections.Generic.List[string]'
    if ($specLines.Count -gt 0 -and $specLines[0].Trim() -eq '---') {
        for ($frontmatterIndex = 1; $frontmatterIndex -lt $specLines.Count; $frontmatterIndex++) {
            if ($specLines[$frontmatterIndex].Trim() -eq '---') { break }
            $frontmatterLines.Add($specLines[$frontmatterIndex])
        }
        foreach ($line in $frontmatterLines) {
            $keyValue = [regex]::Match($line, '^(?<Key>[A-Za-z0-9_]+):[ \t]*(?<Value>.*?)[ \t]*$')
            if ($keyValue.Success) {
                $key = $keyValue.Groups['Key'].Value
                if ($frontmatter.ContainsKey($key)) { return New-EngineRefusal -Reason ('duplicate frontmatter key: ' + $key) -Spec $emptySpec }
                $value = $keyValue.Groups['Value'].Value.Trim()
                if ($value.Length -ge 2 -and (($value[0] -eq [char]39 -and $value[$value.Length - 1] -eq [char]39) -or ($value[0] -eq [char]34 -and $value[$value.Length - 1] -eq [char]34))) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
                $frontmatter[$key] = $value
            }
        }
    }

    $name = $null
    if ($frontmatter.ContainsKey('spec')) { $name = [string]$frontmatter['spec'] }
    $emptySpec.name = $name
    $emptySpec.digest = $specDigest
    if ([string]::IsNullOrEmpty($name)) { return New-EngineRefusal -Reason 'frontmatter spec identity is missing or empty' -Spec $emptySpec }
    if ($name -cnotmatch '^[a-z0-9][a-z0-9-]{0,62}$') { return New-EngineRefusal -Reason 'frontmatter spec identity is invalid or contains traversal' -Spec $emptySpec }
    if (-not [string]::Equals($name, [System.IO.Path]::GetFileNameWithoutExtension($fullSpecPath), [System.StringComparison]::Ordinal)) {
        return New-EngineRefusal -Reason 'frontmatter spec identity does not match the filename' -Spec $emptySpec
    }

    $frontmatterRefusal = $null
    $risk = 'medium'
    if ($frontmatter.ContainsKey('risk')) {
        $risk = [string]$frontmatter['risk']
        $emptySpec.risk = $risk
        if ($risk -cne 'low' -and $risk -cne 'medium') { $frontmatterRefusal = 'frontmatter risk must be low or medium' }
    }
    else { $emptySpec.risk = $risk }
    $model = 'gpt-5.6-sol'
    if ($frontmatter.ContainsKey('coder_model')) {
        $declaredModel = [string]$frontmatter['coder_model']
        if (@('codex', 'gpt-5.6-sol', 'gpt-6-sol') -cnotcontains $declaredModel) {
            $emptySpec.coder_model = $declaredModel
            if ($null -eq $frontmatterRefusal) { $frontmatterRefusal = 'frontmatter coder_model is not an allowed Codex model' }
        }
        elseif ($declaredModel -ceq 'codex') {
            $model = 'gpt-5.6-sol'
            $emptySpec.coder_model = $model
        }
        else {
            $model = $declaredModel
            $emptySpec.coder_model = $model
        }
    }
    else { $emptySpec.coder_model = $model }
    $effort = 'medium'
    if ($frontmatter.ContainsKey('coder_effort')) { $effort = [string]$frontmatter['coder_effort'] }
    $emptySpec.coder_effort = $effort
    if ($null -eq $frontmatterRefusal -and @('low', 'medium', 'high', 'xhigh', 'max', 'ultra') -cnotcontains $effort) { $frontmatterRefusal = 'frontmatter coder_effort is invalid' }

    $declaredMaxParallel = $null
    if ($frontmatter.ContainsKey('max_parallel_codex')) {
        $maxParallelText = [string]$frontmatter['max_parallel_codex']
        $parsedMaxParallel = 0
        if ($maxParallelText -cnotmatch '^[1-9][0-9]*$' -or -not [int]::TryParse($maxParallelText, [ref]$parsedMaxParallel)) {
            if ($null -eq $frontmatterRefusal) { $frontmatterRefusal = 'frontmatter max_parallel_codex must be a positive integer' }
        }
        else {
            $declaredMaxParallel = $parsedMaxParallel
            $emptySpec.max_parallel_codex = $declaredMaxParallel
        }
    }

    $intent = Get-EngineSectionBody -Text $specText -Heading 'Intent'
    $assumptions = Get-EngineSectionBody -Text $specText -Heading 'Assumptions'
    $specialist = @(Get-EngineSpecialistContext -Text $specText)
    $emptySpec.intent = $intent
    $emptySpec.assumptions = $assumptions
    $emptySpec.specialist_context = @($specialist)
    if ($null -ne $frontmatterRefusal) { return New-EngineRefusal -Reason $frontmatterRefusal -Spec $emptySpec }
    foreach ($line in ($intent -split "`n")) {
        if ($line -match '(?i)non-goals?' ) { continue }
        if ($line -match '(?i)(?<![A-Za-z0-9_])risk:[ \t]+high(?![A-Za-z0-9_])') {
            return New-EngineRefusal -Reason 'Intent declares risk: high' -Spec $emptySpec
        }
    }
    $planSpec = New-EnginePlanSpec -Name $name -Path $fullSpecPath -Digest $specDigest -Risk $risk -CoderModel $model -CoderEffort $effort -MaxParallelCodex $declaredMaxParallel -Intent $intent -Assumptions $assumptions -SpecialistContext $specialist

    if ([string]::IsNullOrWhiteSpace($ValidatorPath)) { $ValidatorPath = Join-Path $PSScriptRoot 'apex-spec-validate.ps1' }
    if (-not [System.IO.Path]::IsPathRooted($ValidatorPath)) { $ValidatorPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $ValidatorPath)) }
    if (-not (Test-Path -LiteralPath $ValidatorPath -PathType Leaf)) { return New-EngineRefusal -Reason 'validator is missing' -Spec $planSpec }
    $validatorResult = Invoke-EnginePlanNative -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ValidatorPath, '-SpecPath', $fullSpecPath)
    if ($validatorResult.exit_code -ne 0) {
        $detail = ($validatorResult.output -join ' | ')
        return New-EngineRefusal -Reason ('validator refused the spec (exit {0}): {1}' -f $validatorResult.exit_code, $detail) -Spec $planSpec
    }

    $manifestSection = [regex]::Match($specText, '(?ms)^##[ \t]+Execution manifest[ \t]*\n(?<Body>.*?)(?=^##[ \t]+|\z)')
    if (-not $manifestSection.Success) { return New-EngineRefusal -Reason 'exactly one execution manifest is required' -Spec $planSpec }
    $manifestFences = [regex]::Matches($manifestSection.Groups['Body'].Value, '(?ms)^(?<Fence>`{3,}|~{3,})json apex-manifest[ \t]*\n(?<Json>.*?)^\k<Fence>[ \t]*$')
    if ($manifestFences.Count -ne 1) { return New-EngineRefusal -Reason 'exactly one execution manifest is required' -Spec $planSpec }
    try { $manifest = $manifestFences[0].Groups['Json'].Value | ConvertFrom-Json -ErrorAction Stop }
    catch { return New-EngineRefusal -Reason 'execution manifest JSON is invalid' -Spec $planSpec }
    if (-not ($manifest -is [pscustomobject])) { return New-EngineRefusal -Reason 'execution manifest root must be an object' -Spec $planSpec }
    if (-not $manifest.PSObject.Properties['version'] -or -not ($manifest.version -is [int]) -or $manifest.version -ne 1) {
        return New-EngineRefusal -Reason 'execution manifest version must be integer 1' -Spec $planSpec
    }
    if (-not $manifest.PSObject.Properties['repos'] -or -not ($manifest.repos -is [pscustomobject])) {
        return New-EngineRefusal -Reason 'execution manifest repos must be an object' -Spec $planSpec
    }
    if (-not $manifest.PSObject.Properties['tasks'] -or -not ($manifest.tasks -is [System.Array])) {
        return New-EngineRefusal -Reason 'execution manifest tasks must be an array' -Spec $planSpec
    }

    $repoProperties = @($manifest.repos.PSObject.Properties)
    if ($repoProperties.Count -ne 1) { return New-EngineRefusal -Reason 'execution manifest must contain exactly one repo key' -Spec $planSpec }
    $repoKey = $repoProperties[0].Name
    $manifestRepoText = [string]$repoProperties[0].Value
    try { $manifestRepo = ConvertTo-EngineCanonicalRoot -Path $manifestRepoText }
    catch { return New-EngineRefusal -Reason 'execution manifest repo root is invalid' -Spec $planSpec }
    if (-not [string]::Equals($manifestRepo, $repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return New-EngineRefusal -Reason 'execution manifest repo does not match -Repo' -Spec $planSpec
    }
    $gitRootResult = Invoke-EnginePlanNative -FilePath 'git' -ArgumentList @('-c', 'core.excludesFile=/dev/null', '-C', $repoRoot, 'rev-parse', '--show-toplevel')
    if ($gitRootResult.exit_code -ne 0) { return New-EngineRefusal -Reason 'repo is not a Git worktree' -Spec $planSpec }
    try { $gitRoot = ConvertTo-EngineCanonicalRoot -Path $gitRootResult.output[$gitRootResult.output.Count - 1] }
    catch { return New-EngineRefusal -Reason 'Git repo root could not be resolved' -Spec $planSpec }
    if (-not [string]::Equals($gitRoot, $repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return New-EngineRefusal -Reason '-Repo must be the Git worktree root' -Spec $planSpec
    }

    $copyRoot = Join-Path $repoRoot 'docs/changes'
    if (Test-Path -LiteralPath $copyRoot -PathType Container) {
        try { $copies = @(Get-ChildItem -LiteralPath $copyRoot -Recurse -Force -File -Filter ($name + '.md')) }
        catch { return New-EngineRefusal -Reason 'in-repo spec copies could not be inspected' -Spec $planSpec }
        foreach ($copy in $copies) {
            if ([string]::Equals($copy.FullName, $fullSpecPath, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            try { $copyDigest = Get-EngineSha256 -Text ([System.IO.File]::ReadAllText($copy.FullName, $utf8Strict)) }
            catch { return New-EngineRefusal -Reason 'in-repo spec copy is not valid UTF-8' -Spec $planSpec }
            if ($copyDigest -ne $specDigest) { return New-EngineRefusal -Reason 'differing same-name in-repo spec copy exists' -Spec $planSpec }
        }
    }

    $taskDeclarations = Get-EngineTaskDeclarations -Text $specText
    $taskObjects = New-Object 'System.Collections.Generic.List[object]'
    $taskById = @{}
    $pathOwner = @{}
    $allPaths = New-Object 'System.Collections.Generic.List[string]'
    $operations = @{}
    foreach ($manifestTask in @($manifest.tasks)) {
        if (-not ($manifestTask -is [pscustomobject]) -or
            -not $manifestTask.PSObject.Properties['id'] -or
            -not $manifestTask.PSObject.Properties['repo'] -or
            -not $manifestTask.PSObject.Properties['files'] -or
            -not ($manifestTask.files -is [System.Array]) -or
            -not $manifestTask.PSObject.Properties['depends_on'] -or
            -not ($manifestTask.depends_on -is [System.Array])) {
            return New-EngineRefusal -Reason 'execution manifest task shape is invalid' -Spec $planSpec
        }
        $id = ([string]$manifestTask.id).ToLowerInvariant()
        if ($id -cnotmatch '^[0-9]+[a-z]?$') { return New-EngineRefusal -Reason ('manifest task id is invalid: ' + $id) -Spec $planSpec }
        if ($id.Length -gt 32) { return New-EngineRefusal -Reason ('manifest task id exceeds 32 characters: ' + $id.Substring(0, 16) + '...') -Spec $planSpec }
        if ($taskById.ContainsKey($id)) { return New-EngineRefusal -Reason ('duplicate manifest task id: ' + $id) -Spec $planSpec }
        if ([string]$manifestTask.repo -cne $repoKey) { return New-EngineRefusal -Reason ('task ' + $id + ' uses an unknown repo key') -Spec $planSpec }
        if (-not $taskDeclarations.ContainsKey($id)) { return New-EngineRefusal -Reason ('task declaration is missing for manifest task ' + $id) -Spec $planSpec }
        $taskEffort = $effort
        if ($manifestTask.PSObject.Properties['effort']) { $taskEffort = [string]$manifestTask.effort }
        if (@('low', 'medium', 'high', 'xhigh', 'max', 'ultra') -cnotcontains $taskEffort) { return New-EngineRefusal -Reason ('task ' + $id + ' effort is invalid') -Spec $planSpec }
        $weight = 1
        if ($taskEffort -ceq 'ultra') { $weight = 2 }
        if ($weight -gt $MaxParallel) { return New-EngineRefusal -Reason ('task ' + $id + ' weight exceeds MaxParallel') -Spec $planSpec }

        $files = New-Object 'System.Collections.Generic.List[object]'
        foreach ($manifestFile in @($manifestTask.files)) {
            $relative = [string]$manifestFile.path
            $op = [string]$manifestFile.op
            if (Test-EngineGitMetadataManifestPath -Path $relative) { return New-EngineRefusal -Reason ('manifest path contains a .git segment: ' + $relative) -Spec $planSpec }
            if (-not (Test-EngineRelativeManifestPath -Path $relative)) { return New-EngineRefusal -Reason ('manifest path is invalid or contains traversal: ' + $relative) -Spec $planSpec }
            if (@('create', 'modify', 'delete') -cnotcontains $op) { return New-EngineRefusal -Reason ('manifest operation is invalid for ' + $relative) -Spec $planSpec }
            if ([string]::Equals([System.IO.Path]::GetFileName($relative), '.gitattributes', [System.StringComparison]::OrdinalIgnoreCase)) {
                return New-EngineRefusal -Reason '.gitattributes is not an authorized manifest path' -Spec $planSpec
            }
            $canonical = ConvertTo-EngineCanonicalManifestPath -Path $relative
            if ($pathOwner.ContainsKey($canonical)) {
                return New-EngineRefusal -Reason ('canonical manifest path appears in more than one task: ' + $relative) -Spec $planSpec
            }
            $pathOwner[$canonical] = $id
            $operations[$canonical] = $op
            $allPaths.Add($relative)
            $files.Add([pscustomobject][ordered]@{ path = $relative; op = $op })
        }
        if ($files.Count -eq 0) { return New-EngineRefusal -Reason ('task ' + $id + ' has no manifest paths') -Spec $planSpec }
        $dependencies = @($manifestTask.depends_on | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $decl = $taskDeclarations[$id]
        $acceptance = @(Get-EngineAcceptanceLines -Text $specText -TaskId $id)
        $taskObject = [pscustomobject][ordered]@{
            id = $id
            repo = $repoKey
            files = $files.ToArray()
            depends_on = @($dependencies)
            effort = $taskEffort
            text = $decl.Text
            done_when = $decl.DoneWhen
            acceptance = @($acceptance)
            prompt = $null
            prompt_digest = $null
        }
        $taskObjects.Add($taskObject)
        $taskById[$id] = $taskObject
    }
    if ($taskObjects.Count -eq 0) { return New-EngineRefusal -Reason 'execution manifest has no tasks' -Spec $planSpec }

    for ($leftIndex = 0; $leftIndex -lt $allPaths.Count; $leftIndex++) {
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $allPaths.Count; $rightIndex++) {
            $leftPath = $allPaths[$leftIndex]
            $rightPath = $allPaths[$rightIndex]
            if (Test-EnginePathOverlap -Left $leftPath -Right $rightPath) {
                return New-EngineRefusal -Reason ('manifest paths overlap (ancestor/descendant): ' + $leftPath + ', ' + $rightPath) -Spec $planSpec
            }
        }
    }

    foreach ($task in $taskObjects) {
        foreach ($dependency in @($task.depends_on)) {
            if (-not $taskById.ContainsKey($dependency) -or $dependency -eq $task.id) {
                return New-EngineRefusal -Reason ('task ' + $task.id + ' has an invalid dependency ' + $dependency) -Spec $planSpec
            }
        }
    }

    foreach ($relative in $allPaths) {
        $full = [System.IO.Path]::GetFullPath((Join-Path $repoRoot ($relative.Replace('/', [char]92))))
        $prefix = $repoRoot.TrimEnd([char[]]@([char]92, [char]47)) + [System.IO.Path]::DirectorySeparatorChar
        if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return New-EngineRefusal -Reason ('manifest path escapes repo: ' + $relative) -Spec $planSpec }
        $current = $full
        while ($current.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $item = $null
            try { $item = Get-Item -Force -LiteralPath $current -ErrorAction Stop }
            catch { $item = $null }
            if ($null -ne $item) {
                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return New-EngineRefusal -Reason ('manifest path is at or under a reparse point: ' + $relative) -Spec $planSpec }
                if ([string]::Equals($current, $full, [System.StringComparison]::OrdinalIgnoreCase) -and $item.PSIsContainer) { return New-EngineRefusal -Reason ('manifest path is a directory: ' + $relative) -Spec $planSpec }
                if (-not [string]::Equals($current, $full, [System.StringComparison]::OrdinalIgnoreCase) -and -not $item.PSIsContainer) { return New-EngineRefusal -Reason ('manifest path ancestor is a file: ' + $relative) -Spec $planSpec }
            }
            if ([string]::Equals($current, $repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) { break }
            $parent = Split-Path -Parent $current
            if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) { break }
            $current = $parent
        }
        $key = ConvertTo-EngineCanonicalManifestPath -Path $relative
        if ($operations[$key] -eq 'create' -and (Test-Path -LiteralPath $full)) {
            return New-EngineRefusal -Reason ('create path already exists (tracked or ignored): ' + $relative) -Spec $planSpec
        }
    }

    $statusArgs = @('-c', 'core.excludesFile=/dev/null', '-C', $repoRoot, 'status', '--porcelain', '-uall', '--ignored', '--') + $allPaths.ToArray()
    $statusResult = Invoke-EnginePlanNative -FilePath 'git' -ArgumentList $statusArgs
    $statusOutput = @($statusResult.output)
    if ($statusResult.exit_code -ne 0) { return New-EngineRefusal -Reason ('git status failed: ' + ($statusOutput -join ' | ')) -Spec $planSpec }
    if ($statusOutput.Count -gt 0) {
        foreach ($line in $statusOutput) {
            $reported = $line
            if ($line.Length -ge 4) { $reported = $line.Substring(3).Trim('"') }
            $reported = $reported.Replace([char]92, [char]47)
            foreach ($relative in $allPaths) {
                if ([string]::Equals($reported, $relative, [System.StringComparison]::OrdinalIgnoreCase)) {
                    if ($operations[(ConvertTo-EngineCanonicalManifestPath -Path $relative)] -eq 'create') {
                        return New-EngineRefusal -Reason ('create path already exists (tracked or ignored): ' + $relative) -Spec $planSpec
                    }
                    else {
                        return New-EngineRefusal -Reason ('modify/delete path is dirty: ' + $relative) -Spec $planSpec
                    }
                }
            }
        }
    }
    foreach ($relative in $allPaths) {
        if ($operations[$relative.ToLowerInvariant()] -eq 'create') {
            $catFileResult = Invoke-EnginePlanNative -FilePath 'git' -ArgumentList @('-c', 'core.excludesFile=/dev/null', '-C', $repoRoot, 'cat-file', '-e', ('HEAD:' + $relative))
            if ($catFileResult.exit_code -eq 0) {
                return New-EngineRefusal -Reason ('create path already exists (tracked or ignored): ' + $relative) -Spec $planSpec
            }
            continue
        }
        $pathStatusArgs = @('-c', 'core.excludesFile=/dev/null', '-C', $repoRoot, 'status', '--porcelain', '-uall', '--ignored', '--', $relative)
        $pathStatusResult = Invoke-EnginePlanNative -FilePath 'git' -ArgumentList $pathStatusArgs
        $pathStatus = @($pathStatusResult.output)
        if ($pathStatusResult.exit_code -ne 0) { return New-EngineRefusal -Reason ('git status failed for ' + $relative + ': ' + ($pathStatus -join ' | ')) -Spec $planSpec }
        if ($pathStatus.Count -gt 0) { return New-EngineRefusal -Reason ('modify/delete path is dirty: ' + $relative) -Spec $planSpec }
    }

    try {
        $verifyFence = Get-EngineVerifyFence -AgentsPath (Join-Path $repoRoot 'AGENTS.md')
        $template = Get-EngineTemplateParts -TemplatePath (Join-Path (Split-Path -Parent $PSScriptRoot) 'references/dispatch-pack.md')
    }
    catch { return New-EngineRefusal -Reason $_.Exception.Message -Spec $planSpec }
    $identityMatch = [regex]::Match($specText, '(?m)^(?<Line>.*\*\*Identity:\*\*.*)$')
    $identity = $name
    if ($identityMatch.Success) { $identity = $identityMatch.Groups['Line'].Value }
    foreach ($task in $taskObjects) {
        $task.prompt = New-EnginePrompt -Task $task -Identity $identity -RepoPath $repoRoot -Intent $intent -Assumptions $assumptions -SpecialistContext $specialist -VerifyFence $verifyFence -Template $template
        $task.prompt_digest = Get-EngineSha256 -Text $task.prompt
    }

    $remaining = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($task in $taskObjects) { [void]$remaining.Add($task.id) }
    $completed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $layers = New-Object 'System.Collections.Generic.List[object]'
    while ($remaining.Count -gt 0) {
        $layer = New-Object 'System.Collections.Generic.List[object]'
        foreach ($task in $taskObjects) {
            if (-not $remaining.Contains($task.id)) { continue }
            $ready = $true
            foreach ($dependency in @($task.depends_on)) { if (-not $completed.Contains($dependency)) { $ready = $false; break } }
            if ($ready) { $layer.Add($task) }
        }
        if ($layer.Count -eq 0) { return New-EngineRefusal -Reason 'execution manifest dependency graph contains a cycle' -Spec $planSpec }
        $layers.Add($layer.ToArray())
        foreach ($task in $layer) { [void]$remaining.Remove($task.id); [void]$completed.Add($task.id) }
    }

    $waves = New-Object 'System.Collections.Generic.List[object]'
    $waveNumber = 1
    foreach ($layer in $layers) {
        $currentTasks = New-Object 'System.Collections.Generic.List[object]'
        $currentWeight = 0
        foreach ($task in @($layer)) {
            $weight = 1
            if ($task.effort -ceq 'ultra') { $weight = 2 }
            if ($currentTasks.Count -gt 0 -and ($currentWeight + $weight) -gt $MaxParallel) {
                $waves.Add([pscustomobject][ordered]@{ number = $waveNumber; tasks = $currentTasks.ToArray() })
                $waveNumber++
                $currentTasks = New-Object 'System.Collections.Generic.List[object]'
                $currentWeight = 0
            }
            $currentTasks.Add($task)
            $currentWeight += $weight
        }
        if ($currentTasks.Count -gt 0) {
            $waves.Add([pscustomobject][ordered]@{ number = $waveNumber; tasks = $currentTasks.ToArray() })
            $waveNumber++
        }
    }

    return [pscustomobject][ordered]@{
        allowed = $true
        refusal = $null
        spec = $planSpec
        waves = $waves.ToArray()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $cliSpecPath = $null
    $cliRepo = $null
    $cliMaxParallel = 0
    $cliValidatorPath = $null
    $cliJson = $false
    $cliArguments = @($args)
    for ($cliIndex = 0; $cliIndex -lt $cliArguments.Count; $cliIndex++) {
        $cliName = [string]$cliArguments[$cliIndex]
        if ($cliName -ceq '-Json') {
            $cliJson = $true
            continue
        }
        if (@('-SpecPath', '-Repo', '-MaxParallel', '-ValidatorPath') -cnotcontains $cliName -or $cliIndex + 1 -ge $cliArguments.Count) {
            throw 'CLI usage: engine-plan.ps1 -SpecPath <absolute> -Repo <absolute> -MaxParallel <int> [-ValidatorPath <absolute>] [-Json]'
        }
        $cliIndex++
        $cliValue = [string]$cliArguments[$cliIndex]
        switch -CaseSensitive ($cliName) {
            '-SpecPath' { $cliSpecPath = $cliValue }
            '-Repo' { $cliRepo = $cliValue }
            '-MaxParallel' {
                if (-not [int]::TryParse($cliValue, [ref]$cliMaxParallel)) { $cliMaxParallel = 0 }
            }
            '-ValidatorPath' { $cliValidatorPath = $cliValue }
        }
    }
    if ([string]::IsNullOrWhiteSpace($cliSpecPath) -or [string]::IsNullOrWhiteSpace($cliRepo) -or $cliMaxParallel -lt 1) {
        throw 'CLI usage: engine-plan.ps1 -SpecPath <absolute> -Repo <absolute> -MaxParallel <int> [-ValidatorPath <absolute>] [-Json]'
    }
    $result = Get-EnginePlan -SpecPath $cliSpecPath -Repo $cliRepo -MaxParallel $cliMaxParallel -ValidatorPath $cliValidatorPath
    if ($cliJson) { $result | ConvertTo-Json -Depth 20 -Compress }
    else { $result }
}
