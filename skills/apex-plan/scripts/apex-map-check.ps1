# Read-only system-map checker for Windows PowerShell 5.1.
# Usage: -Repo <absolute-directory> (-Stale | -Touches <path>... | -Owner <path>) [-Json]
# Exits: 0 fresh/lookup, 1 stale, 2 usage/parse/Git failure, 3 no sections.
# Parse arguments ourselves so even CLI binding errors have the documented exit 2,
# and powershell.exe -File can accept multiple space-separated -Touches arguments.
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:mode = ''
$script:jsonOutput = @($args | Where-Object { $_ -is [string] -and $_ -ieq '-Json' }).Count -gt 0
$script:repo = ''
$utf8 = New-Object System.Text.UTF8Encoding($false, $true)

function ConvertTo-Ascii([string]$Text, [switch]$JsonText) {
    $builder = New-Object System.Text.StringBuilder
    foreach ($c in $Text.ToCharArray()) {
        $n = [int]$c
        if ($n -gt 126 -or (-not $JsonText -and ($n -lt 32 -or $n -eq 92))) {
            [void]$builder.Append(('\u{0:x4}' -f $n))
        } else { [void]$builder.Append($c) }
    }
    return $builder.ToString()
}

function Write-Result([string[]]$Names, [string]$ErrorText = '') {
    if ($script:jsonOutput) {
        $result = [ordered]@{ mode = $script:mode; sections = @($Names) }
        if ($ErrorText) { $result['error'] = $ErrorText }
        Write-Output (ConvertTo-Ascii (ConvertTo-Json -InputObject $result -Compress -Depth 4) -JsonText)
    } elseif ($ErrorText) {
        if ($ErrorText -eq 'no map sections') { Write-Output $ErrorText }
        else { [Console]::Error.WriteLine((ConvertTo-Ascii $ErrorText)) }
    } else {
        foreach ($name in $Names) { Write-Output (ConvertTo-Ascii $name) }
    }
}

# Windows CommandLineToArgvW backslash/quote rules, as in codex-scope-check.ps1.
function ConvertTo-GitArgument([string]$Value, [switch]$AlwaysQuote) {
    if (-not $AlwaysQuote -and $Value.Length -gt 0 -and $Value -notmatch '[ \t"]') { return $Value }
    $quoted = New-Object System.Text.StringBuilder
    [void]$quoted.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) { $slashes++; continue }
        if ($character -eq [char]34) { [void]$quoted.Append([char]92, (2 * $slashes + 1)) }
        else { [void]$quoted.Append([char]92, $slashes) }
        [void]$quoted.Append($character)
        $slashes = 0
    }
    [void]$quoted.Append([char]92, (2 * $slashes))
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

function Invoke-Git([string[]]$GitArgs) {
    $process = $null
    $stdout = New-Object System.IO.MemoryStream
    $stderr = New-Object System.IO.MemoryStream
    try {
        $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $extension = [IO.Path]::GetExtension($gitCommand.Source)
        $shim = $extension -ieq '.cmd' -or $extension -ieq '.bat'
        $arguments = @('-C', $script:repo, '-c', 'protocol.allow=never') + $GitArgs
        $quotedArgs = @($arguments | ForEach-Object { ConvertTo-GitArgument $_ -AlwaysQuote:$shim })
        $info = New-Object System.Diagnostics.ProcessStartInfo
        if ($shim) {
            $commandLine = (ConvertTo-GitArgument $gitCommand.Source -AlwaysQuote) + ' ' + ($quotedArgs -join ' ')
            if ([regex]::Matches($commandLine, '%').Count -ge 2) {
                throw 'cmd.exe shim arguments contain multiple percent characters.'
            }
            $info.FileName = $env:ComSpec
            $info.Arguments = '/d /v:off /s /c "' + $commandLine + '"'
        } else {
            $info.FileName = $gitCommand.Source
            $info.Arguments = $quotedArgs -join ' '
        }
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        # Rebuild case-insensitively, including hosts with duplicate Path/PATH keys.
        try { $childEnvironment = $info.get_EnvironmentVariables() }
        catch {
            if ($_.Exception.InnerException -isnot [ArgumentException]) { throw }
            $childEnvironment = $info.get_EnvironmentVariables()
        }
        $childEnvironment.Clear()
        foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
            $childEnvironment[$entry.Key] = $entry.Value
        }
        foreach ($key in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
                'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_COMMON_DIR', 'GIT_NAMESPACE',
                'GIT_LITERAL_PATHSPECS', 'GIT_GLOB_PATHSPECS', 'GIT_NOGLOB_PATHSPECS', 'GIT_ICASE_PATHSPECS')) {
            $childEnvironment.Remove($key)
        }
        $childEnvironment['GIT_OPTIONAL_LOCKS'] = '0'
        $childEnvironment['GIT_NO_LAZY_FETCH'] = '1'
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $info
        $timer = [Diagnostics.Stopwatch]::StartNew()
        if (-not $process.Start()) { throw 'Process.Start returned false.' }
        $process.StandardInput.Close()
        $stdoutDrain = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $stderrDrain = $process.StandardError.BaseStream.CopyToAsync($stderr)
        # The deadline covers both execution and pipe drainage. A child inheriting
        # a pipe must not keep the checker blocked after its parent exits.
        while (-not ($process.HasExited -and $stdoutDrain.IsCompleted -and $stderrDrain.IsCompleted)) {
            if ($timer.ElapsedMilliseconds -ge 120000) { throw 'Git timed out after 120 seconds.' }
            [Threading.Thread]::Sleep(10)
        }
        [void]$stdoutDrain.GetAwaiter().GetResult()
        [void]$stderrDrain.GetAwaiter().GetResult()
        $outText = $utf8.GetString($stdout.ToArray())
        $errText = $utf8.GetString($stderr.ToArray())
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outText; Error = $errText }
    } catch {
        throw "Git failure: $($_.Exception.Message)"
    } finally {
        if ($process) {
            try { if (-not $process.HasExited) { $process.Kill() } } catch { }
            $process.Dispose()
        }
        $stdout.Dispose()
        $stderr.Dispose()
    }
}

function Assert-Path([string]$Path, [switch]$Glob, [switch]$GitRecord) {
    if (-not $Path -or $Path -match '[\x00-\x1f\x7f\\:]' -or
            (-not $GitRecord -and $Path -match '\s') -or $Path.StartsWith('/') -or $Path.EndsWith('/')) {
        throw "Invalid repo-relative path: $Path"
    }
    foreach ($segment in $Path.Split('/')) {
        if ($segment -eq '' -or $segment -eq '.' -or $segment -eq '..') { throw "Invalid path segment: $Path" }
        if (-not $GitRecord) {
            if ($segment -match '["<>|?]' -or ($Glob -and $segment -match '[\[\]]') -or
                    (-not $Glob -and $segment.Contains('*')) -or
                    ($segment.Contains('**') -and $segment -ne '**')) { throw "Invalid glob/path: $Path" }
        }
    }
}

function Read-MapText([string]$Path) {
    $text = $utf8.GetString([IO.File]::ReadAllBytes($Path))
    if ($text.StartsWith([string][char]0xfeff, [StringComparison]::Ordinal)) { $text = $text.Substring(1) }
    return $text
}

function Read-Sections([string]$Path) {
    $lines = [regex]::Split((Read-MapText $Path), '\r\n|\n|\r')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -cmatch '^##(?: |$)') {
            if ($line -cnotmatch '^## (\S.*)$' -or $i + 1 -ge $lines.Count) { throw "Malformed section in $Path" }
            $name = $Matches[1]
            $i++
            $header = $lines[$i]
            $grammar = '^<!-- apex:map-section covers: (?<covers>.*?) contracts:(?: (?<contracts>.*?))? seams:(?: (?<seams>.*?))? verified:(?: (?<verified>.*?))? -->$'
            $match = [regex]::Match($header, $grammar)
            if (-not $match.Success -and $script:mode -eq 'stale') {
                # The sole tolerated defect: an absent verified field/value.
                $match = [regex]::Match($header, '^<!-- apex:map-section covers: (?<covers>.*?) contracts:(?: (?<contracts>.*?))? seams:(?: (?<seams>.*?))? -->$')
            }
            if (-not $match.Success) { throw "Malformed map header for $name" }
            $verified = $match.Groups['verified'].Value
            if ($verified -cnotmatch '^[0-9a-fA-F]{40}$' -and -not ($script:mode -eq 'stale' -and $verified -eq '')) {
                throw "Invalid verified SHA for $name"
            }
            $fields = @{}
            foreach ($field in @('covers', 'contracts', 'seams')) {
                $value = $match.Groups[$field].Value
                $tokens = @()
                if ($value -ne '') {
                    $tokens = @($value.Split(' '))
                    foreach ($token in $tokens) { Assert-Path $token -Glob }
                }
                $fields[$field] = $tokens
            }
            if ($fields['covers'].Count -eq 0) { throw "Empty covers for $name" }
            [pscustomobject]@{ Name = $name; Covers = $fields['covers']; Contracts = $fields['contracts']; Seams = $fields['seams']; Verified = $verified }
        } elseif ($line.Contains('apex:map-section')) { throw "Map header without an immediate section heading in $Path" }
    }
}

function Test-Glob([string]$Pattern, [string]$Path) {
    if (-not $Pattern.Contains('*')) {
        return $Path -ceq $Pattern -or $Path.StartsWith($Pattern + '/', [StringComparison]::Ordinal)
    }
    $expression = New-Object System.Text.StringBuilder
    [void]$expression.Append('\A')
    for ($i = 0; $i -lt $Pattern.Length; $i++) {
        if ($Pattern[$i] -eq '*') {
            if ($i + 1 -lt $Pattern.Length -and $Pattern[$i + 1] -eq '*') {
                $i++
                if ($i + 1 -lt $Pattern.Length -and $Pattern[$i + 1] -eq '/') {
                    [void]$expression.Append('(?:[^/]+/)*')
                    $i++
                } else { [void]$expression.Append('.*') }
            } else { [void]$expression.Append('[^/]*') }
        } else { [void]$expression.Append([regex]::Escape([string]$Pattern[$i])) }
    }
    [void]$expression.Append('\z')
    return [regex]::IsMatch($Path, $expression.ToString(), [Text.RegularExpressions.RegexOptions]::CultureInvariant)
}

function Assert-Diff([string]$Text) {
    if ($Text -eq '') { return }
    if (-not $Text.EndsWith([string][char]0)) { throw 'Git failure: unterminated name-status output.' }
    $records = $Text.Split([char]0)
    for ($i = 0; $i -lt $records.Count - 1; $i++) {
        $status = $records[$i]
        if ($status -cnotmatch '^(?:[ADTUXB]|M(?:100|0[0-9]{2})?|[CR](?:100|0[0-9]{2}))$') { throw 'Git failure: malformed name-status record.' }
        $paths = if ($status[0] -eq 'R' -or $status[0] -eq 'C') { 2 } else { 1 }
        for ($j = 0; $j -lt $paths; $j++) {
            $i++
            if ($i -ge $records.Count - 1) { throw 'Git failure: missing name-status path.' }
            Assert-Path $records[$i] -GitRecord
        }
    }
}

try {
    $lookupPaths = @()
    $seen = @{}
    for ($i = 0; $i -lt $args.Count; $i++) {
        $option = [string]$args[$i]
        if ($option -notin @('-Repo', '-Stale', '-Touches', '-Owner', '-Json') -or $seen.ContainsKey($option)) {
            throw "Invalid or repeated argument: $option"
        }
        $seen[$option] = $true
        switch ($option) {
            '-Json' { $script:jsonOutput = $true }
            '-Repo' {
                $i++
                if ($i -ge $args.Count) { throw '-Repo requires an absolute directory.' }
                $script:repo = [string]$args[$i]
            }
            '-Stale' {
                if ($script:mode) { throw 'Modes are mutually exclusive.' }
                $script:mode = 'stale'
            }
            '-Owner' {
                if ($script:mode) { throw 'Modes are mutually exclusive.' }
                $script:mode = 'owner'
                $i++
                if ($i -ge $args.Count) { throw '-Owner requires one path.' }
                $lookupPaths = @(foreach ($path in @($args[$i])) { [string]$path })
                if ($lookupPaths.Count -eq 0) { throw '-Owner requires one path.' }
            }
            '-Touches' {
                if ($script:mode) { throw 'Modes are mutually exclusive.' }
                $script:mode = 'touches'
                while ($i + 1 -lt $args.Count -and -not ([string]$args[$i + 1]).StartsWith('-')) {
                    $i++
                    foreach ($path in @($args[$i])) { $lookupPaths += [string]$path }
                }
                if ($lookupPaths.Count -eq 0) { throw '-Touches requires at least one path.' }
            }
        }
    }
    if (-not $script:mode -or -not $script:repo -or -not [IO.Path]::IsPathRooted($script:repo) -or
            $script:repo -notmatch '^(?:[a-zA-Z]:[\\/]|[\\/]{2})' -or
            -not (Test-Path -LiteralPath $script:repo -PathType Container)) {
        throw 'Usage: -Repo <absolute-directory> (-Stale | -Touches <path>... | -Owner <path>) [-Json]'
    }
    $script:repo = (Resolve-Path -LiteralPath $script:repo).ProviderPath
    foreach ($path in $lookupPaths) { Assert-Path $path }
    $mapPath = Join-Path $script:repo 'docs/system-map.md'
    $sections = @()
    if (Test-Path -LiteralPath $mapPath) { $sections = @(Read-Sections $mapPath) }
    else {
        $mapDirectory = Join-Path $script:repo 'docs/system-map'
        $indexPath = Join-Path $mapDirectory 'index.md'
        if (Test-Path -LiteralPath $indexPath) {
            foreach ($line in ([regex]::Split((Read-MapText $indexPath), '\r\n|\n|\r'))) {
                if ($line -match '^\s*-') {
                    if ($line -cnotmatch '^- (\S+\.md)$') { throw 'Malformed split-map index entry.' }
                    $file = $Matches[1]
                    Assert-Path $file
                    if ($file -ceq 'index.md') { throw 'Split-map index cannot reference itself.' }
                    $splitPath = Join-Path $mapDirectory $file
                    if (-not (Test-Path -LiteralPath $splitPath -PathType Leaf)) { throw "Missing split-map file: $file" }
                    $sections += @(Read-Sections $splitPath)
                }
            }
        }
    }
    if ($sections.Count -eq 0) { Write-Result @() 'no map sections'; exit 3 }
    $names = @()
    foreach ($section in $sections) {
        if ($script:mode -eq 'stale') {
            $staleSection = -not $section.Verified
            if (-not $staleSection) {
                $resolved = Invoke-Git @('rev-parse', '--verify', '--quiet', ($section.Verified + '^{commit}'))
                if ($resolved.ExitCode -eq 1 -and $resolved.Output -eq '') { $staleSection = $true }
                elseif ($resolved.ExitCode -ne 0) { throw "Git failure: rev-parse exit $($resolved.ExitCode)." }
                elseif ($resolved.Output -cnotmatch '^[0-9a-fA-F]{40}\r?\n$') { throw 'Git failure: malformed rev-parse output.' }
                if (-not $staleSection) {
                    $ancestor = Invoke-Git @('merge-base', '--is-ancestor', $section.Verified, 'HEAD')
                    if ($ancestor.ExitCode -eq 1) { $staleSection = $true }
                    elseif ($ancestor.ExitCode -ne 0) { throw "Git failure: merge-base exit $($ancestor.ExitCode)." }
                    elseif ($ancestor.Output -ne '') { throw 'Git failure: malformed merge-base output.' }
                }
                if (-not $staleSection) {
                    $diffArgs = @('diff', '--name-status', '-z', '--find-renames', '--ignore-submodules=none', ($section.Verified + '..HEAD'), '--')
                    foreach ($cover in $section.Covers) { $diffArgs += ':(glob)' + $cover }
                    $diff = Invoke-Git $diffArgs
                    if ($diff.ExitCode -ne 0) { throw "Git failure: diff exit $($diff.ExitCode)." }
                    Assert-Diff $diff.Output
                    $staleSection = $diff.Output -ne ''
                }
            }
            if ($staleSection) { $names += $section.Name }
        } else {
            $patterns = if ($script:mode -eq 'owner') { $section.Covers } else { @($section.Contracts) + @($section.Seams) }
            $found = $false
            foreach ($pattern in $patterns) {
                foreach ($path in $lookupPaths) { if (Test-Glob $pattern $path) { $found = $true } }
            }
            if ($found) { $names += $section.Name }
        }
    }
    Write-Result $names
    if ($script:mode -eq 'stale' -and $names.Count -gt 0) { exit 1 }
    exit 0
} catch {
    Write-Result @() $_.Exception.Message
    exit 2
}
