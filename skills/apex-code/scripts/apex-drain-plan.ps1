<#
.SYNOPSIS
Creates a read-only plan for Markdown files in a project's top-level docs/changes queue.

.PARAMETER Project
Absolute path to the project directory containing docs/changes.

.PARAMETER Json
Emit the plan as JSON.

.OUTPUTS
Exit code 0 indicates success; exit code 1 indicates an input or planning failure.

.NOTES
Reads the queue and referenced build repositories without changing their files or Git indexes.
#>
[CmdletBinding()]
param([string]$Project, [switch]$Json)

$ErrorActionPreference = 'Stop'
$savedLocks = [Environment]::GetEnvironmentVariable('GIT_OPTIONAL_LOCKS', 'Process')
function Test-DrainAbsolute([string]$Path) {
    return ($Path -match '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+(?:[\\/]|$))')
}
try {
    if (-not $Project -or -not (Test-DrainAbsolute $Project)) { throw 'Project must be an absolute existing directory' }
    $Project = [IO.Path]::GetFullPath($Project)
    if (-not (Test-Path -LiteralPath $Project -PathType Container)) { throw 'Project directory does not exist' }
    $changes = Join-Path $Project 'docs/changes'
    if (-not (Test-Path -LiteralPath $changes -PathType Container)) { throw 'Project docs/changes directory does not exist' }
    # Snapshot the queue once. No recursive discovery or writes occur below.
    $files = @(Get-ChildItem -LiteralPath $changes -Force -File -Filter '*.md')
    [Environment]::SetEnvironmentVariable('GIT_OPTIONAL_LOCKS', '0', 'Process')
    . (Join-Path $PSScriptRoot 'engine-plan.ps1')

    function Set-DrainReason($Entry, [string]$Code, [string]$Reason, $Blocker = $null) {
        if (-not $Entry.reason_code) {
            $Entry.reason_code = $Code; $Entry.reason = $Reason; $Entry.blocked_by = $Blocker
        }
    }
    function Sort-DrainOrdinal([string[]]$Names) {
        $copy = [string[]]@($Names)
        [Array]::Sort($copy, [StringComparer]::Ordinal)
        return $copy
    }
    $entries = @{}
    foreach ($file in $files) {
        $entry = [pscustomobject]@{ spec = $file.BaseName; path = $file.FullName; filename = $file.Name
            repo = $null; risk = $null; digest = $null; prerequisites = @(); host_work = $false
            reason_code = $null; reason = $null; blocked_by = $null; edges = @(); cycle = $false }
        $entries[$file.BaseName] = $entry
        try {
            $decoder = New-Object System.Text.UTF8Encoding($false, $true)
            try { $text = $decoder.GetString([IO.File]::ReadAllBytes($file.FullName)).TrimStart([char]0xFEFF).Replace("`r`n", "`n") }
            catch { throw 'spec is not valid UTF-8 or could not be read' }
            $front = [regex]::Match($text, '\A---[ \t]*\n(?<Body>.*?)\n---[ \t]*(?:\n|\z)', 'Singleline')
            if (-not $front.Success) { throw 'frontmatter is unreadable: missing opening or closing delimiter' }
            $identities = [regex]::Matches($front.Groups['Body'].Value, '(?m)^spec:[ \t]*(?<Name>.*?)[ \t]*$')
            if ($identities.Count -ne 1 -or -not $identities[0].Groups['Name'].Value.Trim()) { throw 'frontmatter spec identity is missing, empty or duplicated' }
            $identity = $identities[0].Groups['Name'].Value.Trim().Trim([char]39, [char]34)
            if ([string]::IsNullOrEmpty($identity)) { throw 'frontmatter spec identity is empty' }
            $entry.spec = $identity
            $keys = @{}
            foreach ($line in ($front.Groups['Body'].Value -split "`n")) {
                $pair = [regex]::Match($line, '^(?<Key>[A-Za-z0-9_]+):[ \t]*(?<Value>.*?)[ \t]*$')
                if ($pair.Success) {
                    $key = $pair.Groups['Key'].Value
                    if ($keys.ContainsKey($key)) { throw ('unreadable frontmatter: duplicate frontmatter key: ' + $key) }
                    $keys[$key] = $true
                }
            }
            $section = [regex]::Match($text, '(?ms)^##[ \t]+Execution manifest[ \t]*\n(?<Body>.*?)(?=^##[ \t]+|\z)')
            $blocks = @([regex]::Matches($section.Groups['Body'].Value, '(?ms)^(?<Fence>`{3,}|~{3,})json apex-manifest[ \t]*\n(?<Json>.*?)^\k<Fence>[ \t]*$'))
            if (-not $section.Success) { throw 'Execution manifest section is missing' }
            if ($blocks.Count -eq 0) { throw 'execution manifest block is missing; exactly one is required' }
            if ($blocks.Count -ne 1) { throw ('execution manifest block is duplicated (found {0}); exactly one is required' -f $blocks.Count) }
            try { $manifest = $blocks[0].Groups['Json'].Value | ConvertFrom-Json -ErrorAction Stop }
            catch { throw 'execution manifest JSON is invalid' }
            if (-not ($manifest.repos -is [pscustomobject])) { throw 'execution manifest repos must be an object with exactly one repo key' }
            $repos = @($manifest.repos.PSObject.Properties)
            if ($repos.Count -ne 1) { throw ('execution manifest must contain exactly one repo key (found {0})' -f $repos.Count) }
            $entry.repo = [string]$repos[0].Value
            if (-not (Test-DrainAbsolute $entry.repo) -or -not (Test-Path -LiteralPath $entry.repo -PathType Container)) { throw 'build repository path must be absolute and existing' }
            $root = Invoke-EnginePlanNative -FilePath 'git' -ArgumentList @('-C', $entry.repo, 'rev-parse', '--show-toplevel')
            if ($root.exit_code -ne 0) { throw 'build repository is not a Git worktree' }
            if (-not [string]::Equals((ConvertTo-EngineCanonicalRoot $entry.repo), (ConvertTo-EngineCanonicalRoot $root.output[-1]), [StringComparison]::OrdinalIgnoreCase)) { throw 'build repository must be the Git worktree root' }
            $head = Invoke-EnginePlanNative -FilePath 'git' -ArgumentList @('-C', $entry.repo, 'rev-parse', '--verify', 'HEAD')
            if ($head.exit_code -ne 0) { throw 'build repository has no commit' }
            $probe = Get-EnginePlan -SpecPath $entry.path -Repo $entry.repo -MaxParallel 4
            $ceiling = 2
            if ($null -ne $probe.spec.max_parallel_codex) { $ceiling = [int]$probe.spec.max_parallel_codex }
            $plan = Get-EnginePlan -SpecPath $entry.path -Repo $entry.repo -MaxParallel ([Math]::Min($ceiling, 4))
            $entry.digest = $plan.spec.digest; $entry.risk = $plan.spec.risk
            if (-not $probe.allowed) { throw $probe.refusal }
            if (-not $plan.allowed) { throw $plan.refusal }
            if ($entry.risk -ceq 'high') { Set-DrainReason $entry 'risk-high' 'spec risk is high' }
            else {
                $classifier = Join-Path $PSScriptRoot 'apex-critical-files.ps1'
                if (-not (Test-Path -LiteralPath $classifier -PathType Leaf)) { Set-DrainReason $entry 'classifier-error' 'critical-file classifier is missing' }
                else {
                    try {
                        $paths = @($plan.waves | ForEach-Object { $_.tasks | ForEach-Object { $_.files | ForEach-Object { $_.path } } })
                        $result = Invoke-EnginePlanNative -FilePath 'powershell.exe' -ArgumentList (@('-NoProfile', '-File', $classifier, '-Test', '-Root', $entry.repo, '-Paths') + $paths)
                        $code = switch ($result.exit_code) { 11 { 'hard-block' }; 10 { 'critical-file' }; 0 { $null }; default { 'classifier-error' } }
                        if ($code) { Set-DrainReason $entry $code ('classifier exit {0}: {1}' -f $result.exit_code, ($result.output -join ' | ')) }
                    }
                    catch { Set-DrainReason $entry 'classifier-error' ('classifier failed: ' + $_.Exception.Message) }
                }
            }
        }
        catch { Set-DrainReason $entry 'engine-refused' $_.Exception.Message }
        # Parse these independently, so refused specs still retain graph metadata.
        if ($null -ne $text) {
            $clean = [regex]::Replace($text, '(?s)<!--.*?-->', '')
            $prereq = [regex]::Match($clean, '(?ms)^##[ \t]+Prerequisites[ \t]*\n(?<Body>.*?)(?=^##[ \t]+|\z)')
            if ($prereq.Success) {
                $lines = @($prereq.Groups['Body'].Value -split "`n" | Where-Object { $_.Trim() })
                if (-not ($lines.Count -eq 1 -and @('none', '(none)', 'None') -ccontains $lines[0])) {
                    if ($lines.Count -eq 0) { Set-DrainReason $entry 'prerequisites-unparseable' 'Prerequisites section is empty' }
                    foreach ($line in $lines) {
                        $match = [regex]::Match($line, '^- `(?<Name>[a-z0-9][a-z0-9-]{0,62})`(?: (?:-|\u2014) .+)?$')
                        if (-not $match.Success) { Set-DrainReason $entry 'prerequisites-unparseable' ('cannot parse prerequisite: ' + $line) }
                        else { $entry.prerequisites += $match.Groups['Name'].Value }
                    }
                }
            }
            $fence = $null
            $inTasks = $false
            foreach ($line in ($text -split "`n")) {
                $fm = [regex]::Match($line, '^[ ]{0,3}(?<Fence>`{3,}|~{3,})(?<Trailing>.*)$')
                if ($null -ne $fence) {
                    if ($fm.Success) {
                        $candidate = $fm.Groups['Fence'].Value
                        if ($candidate[0] -eq $fence[0] -and $candidate.Length -ge $fence.Length -and $fm.Groups['Trailing'].Value -match '^[ \t]*$') { $fence = $null }
                    }
                    continue
                }
                if ($fm.Success) { $fence = $fm.Groups['Fence'].Value; continue }
                $heading = [regex]::Match($line, '^##[ \t]+(?<Heading>.*?)[ \t]*$')
                if ($heading.Success) { $inTasks = $heading.Groups['Heading'].Value -ceq 'Tasks'; continue }
                if (-not $inTasks) { continue }
                $decl = [regex]::Match($line, '^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?\*\*\s*(?<Title>Task\s+(?<Id>[0-9]+[A-Za-z]?)(?=\b).*?)\*\*')
                if ($decl.Success) {
                    $title = $decl.Groups['Title'].Value
                    if ($title.Contains('(HOST)') -or [regex]::IsMatch($title, '\bOWNER\b', [Text.RegularExpressions.RegexOptions]::CultureInvariant)) { $entry.host_work = $true }
                }
            }
        }
        $text = $null
    }
    foreach ($entry in $entries.Values) {
        foreach ($name in $entry.prerequisites) {
            if (Test-Path -LiteralPath (Join-Path $changes ('done/' + $name + '.md')) -PathType Leaf) { continue }
            if ($entries.ContainsKey($name)) { $entry.edges += $name }
            else { Set-DrainReason $entry 'prerequisite-missing' ('prerequisite is missing: ' + $name) }
        }
    }
    # Reachability identifies SCC membership and gathers all blockers, rather than
    # propagating a single intermediate reason that would hide competing branches.
    function Get-DrainReachable($Entry, [switch]$PassedOnly) {
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        foreach ($name in $Entry.edges) { $pending.Push($name) }
        while ($pending.Count) {
            $name = $pending.Pop()
            if ($PassedOnly -and $entries[$name].reason_code) { continue }
            if ($seen.Add($name)) { foreach ($next in $entries[$name].edges) { $pending.Push($next) } }
        }
        return ,$seen
    }
    foreach ($entry in $entries.Values) {
        if (-not $entry.reason_code) { $entry.cycle = (Get-DrainReachable $entry -PassedOnly).Contains([IO.Path]::GetFileNameWithoutExtension($entry.path)) }
    }
    $roots = @{}
    foreach ($name in $entries.Keys) { if ($entries[$name].reason_code -or $entries[$name].host_work) { $roots[$name] = $true } }
    foreach ($entry in $entries.Values) {
        if ($entry.reason_code) { continue }
        if ($entry.cycle) { Set-DrainReason $entry 'dependency-cycle' 'spec belongs to a prerequisite cycle'; continue }
        $reachable = Get-DrainReachable $entry
        $blockers = @(foreach ($name in $reachable) { if ($roots.ContainsKey($name)) { $entries[$name].spec } })
        if ($blockers.Count) {
            $blocker = @(Sort-DrainOrdinal $blockers)[0]
            Set-DrainReason $entry 'prerequisite-blocked' ('prerequisite needs owner work: ' + $blocker) $blocker
        }
        else {
            $cycles = @(foreach ($name in $reachable) { if ($entries[$name].cycle) { $entries[$name].spec } })
            if ($cycles.Count) {
                $blocker = @(Sort-DrainOrdinal $cycles)[0]
                Set-DrainReason $entry 'prerequisite-blocked' ('prerequisite cycle: ' + $blocker) $blocker
            }
        }
    }
    $remaining = @{}
    foreach ($name in $entries.Keys) { if (-not $entries[$name].reason_code) { $remaining[$name] = $entries[$name] } }
    $will = @(); $needs = @()
    while ($remaining.Count) {
        $ready = @(foreach ($name in $remaining.Keys) { if (@($remaining[$name].edges | Where-Object { $remaining.ContainsKey($_) }).Count -eq 0) { $name + '.md' } })
        if (-not $ready.Count) { throw 'internal error: unresolved prerequisite cycle' }
        $name = [IO.Path]::GetFileNameWithoutExtension(@(Sort-DrainOrdinal $ready)[0])
        $entry = $remaining[$name]
        $will += [pscustomobject][ordered]@{ order = $will.Count + 1; spec = $entry.spec; path = $entry.path; repo = $entry.repo; risk = $entry.risk; digest = $entry.digest; prerequisites = @($entry.prerequisites); host_work = $entry.host_work }
        $remaining.Remove($name)
    }
    foreach ($filename in @(Sort-DrainOrdinal @($files.Name))) {
        $entry = $entries[[IO.Path]::GetFileNameWithoutExtension($filename)]
        if ($entry.reason_code) { $needs += [pscustomobject][ordered]@{ spec = $entry.spec; path = $entry.path; reason_code = $entry.reason_code; reason = $entry.reason; blocked_by = $entry.blocked_by } }
    }
    if ($Json) {
        $jsonText = [pscustomobject][ordered]@{ schema_version = 1; project = $Project; generated_at = [DateTime]::UtcNow.ToString('o'); will_build = @($will); needs_you = @($needs) } | ConvertTo-Json -Depth 12
        # Escape UTF-16 code units before the console can best-fit map them.
        [regex]::Replace($jsonText, '[^\x00-\x7e]', [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            '\u{0:x4}' -f [int][char]$match.Value
        })
    }
    else {
        Write-Output 'WILL BUILD'
        foreach ($entry in $will) { Write-Output ('{0}. {1} repo={2} risk={3} host_work={4}' -f $entry.order, $entry.spec, $entry.repo, $entry.risk, $entry.host_work) }
        Write-Output 'NEEDS YOU'
        foreach ($entry in $needs) { Write-Output ('{0}: {1} - {2}' -f $entry.spec, $entry.reason_code, $entry.reason) }
    }
}
catch { Write-Output $_.Exception.Message; exit 1 }
finally { [Environment]::SetEnvironmentVariable('GIT_OPTIONAL_LOCKS', $savedLocks, 'Process') }
exit 0
