# Measure the proposed commit, never the working-tree diff. Windows PowerShell 5.1.
param()

# Parse inside the error boundary: PowerShell's parameter binder otherwise exits 1
# for missing values, and -File in 5.1 cannot bind multiple CLI tokens to string[].
$scriptArguments = $args
$Repo = $null
$Paths = @()
$MaxFiles = '1'
$MaxLines = '10'
$Json = $false
foreach ($token in $scriptArguments) {
    if ($token -is [string] -and $token -ceq '--') { break }
    if ($token -is [string] -and $token -ieq '-Json') { $Json = $true }
}

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:StrictUtf8 = New-Object Text.UTF8Encoding($false, $true)

function ConvertTo-AsciiJson($Value) {
    $serialized = ConvertTo-Json -InputObject $Value -Depth 12 -Compress
    return [regex]::Replace($serialized, '[^\x00-\x7f]', {
        param($match)
        '\u{0:x4}' -f [int][char]$match.Value
    })
}

function Write-Result($Result) {
    if ($Json) { Write-Output (ConvertTo-AsciiJson $Result); return }
    Write-Output $Result.verdict
    foreach ($key in $Result.Keys) {
        if ($key -ne 'verdict') {
            Write-Output ($key + '=' + (ConvertTo-AsciiJson $Result[$key]))
        }
    }
}

function ConvertTo-GitArgument([string]$Argument) {
    # .NET Framework has no ArgumentList; use CommandLineToArgvW quoting.
    $encoded = New-Object Text.StringBuilder
    [void]$encoded.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) { $slashes++; continue }
        if ($character -eq [char]34) {
            [void]$encoded.Append([char]92, (2 * $slashes + 1))
        } else {
            [void]$encoded.Append([char]92, $slashes)
        }
        [void]$encoded.Append($character)
        $slashes = 0
    }
    [void]$encoded.Append([char]92, (2 * $slashes))
    [void]$encoded.Append('"')
    return $encoded.ToString()
}

function Invoke-GuardGit([string[]]$GitArgs) {
    $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $extension = [IO.Path]::GetExtension($gitCommand.Source)
    $shim = $extension -ieq '.cmd' -or $extension -ieq '.bat'
    $info = New-Object Diagnostics.ProcessStartInfo
    $arguments = @('-C', $Repo, '-c', 'protocol.allow=never') + $GitArgs
    $quotedArgs = @($arguments | ForEach-Object { ConvertTo-GitArgument $_ })
    if ($shim) {
        $commandLine = (ConvertTo-GitArgument $gitCommand.Source) + ' ' + ($quotedArgs -join ' ')
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
    $info.StandardOutputEncoding = $script:StrictUtf8
    $info.StandardErrorEncoding = $script:StrictUtf8
    # Framework can encounter duplicate Path/PATH keys in launcher environments.
    try { $childEnvironment = $info.get_EnvironmentVariables() }
    catch {
        if ($_.Exception.InnerException -isnot [ArgumentException]) { throw }
        $childEnvironment = $info.get_EnvironmentVariables()
    }
    $childEnvironment.Clear()
    foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $childEnvironment[$entry.Key] = $entry.Value
    }
    foreach ($name in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
        'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_COMMON_DIR', 'GIT_NAMESPACE',
        'GIT_LITERAL_PATHSPECS', 'GIT_GLOB_PATHSPECS', 'GIT_NOGLOB_PATHSPECS', 'GIT_ICASE_PATHSPECS')) {
        $childEnvironment.Remove($name)
    }
    $childEnvironment['GIT_OPTIONAL_LOCKS'] = '0'
    $childEnvironment['GIT_NO_LAZY_FETCH'] = '1'
    $process = New-Object Diagnostics.Process
    $stdout = New-Object IO.MemoryStream
    $stderr = New-Object IO.MemoryStream
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $process.StartInfo = $info
        if (-not $process.Start()) { throw 'Git failed to start' }
        $process.StandardInput.Close()
        # Drain bytes concurrently, then decode strictly (including stderr on success).
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        if (-not $process.WaitForExit(120000)) { throw 'Git timed out after 120 seconds' }
        $remaining = [int][Math]::Max(0, 120000 - $timer.ElapsedMilliseconds)
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask, $errTask), $remaining)) {
            throw 'Git stream drains timed out after 120 seconds'
        }
        $outputText = $script:StrictUtf8.GetString($stdout.ToArray())
        $errorText = $script:StrictUtf8.GetString($stderr.ToArray())
        if ($process.ExitCode -ne 0) {
            throw "Git exit $($process.ExitCode): $($errorText.Trim())"
        }
        return $outputText
    } finally {
        try { if (-not $process.HasExited) { $process.Kill() } } catch { }
        $process.Dispose()
        $stdout.Dispose()
        $stderr.Dispose()
        $timer.Stop()
    }
}

function Assert-RelativePath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path) -or $Path.Contains([string][char]0) -or
        $Path.StartsWith('/') -or $Path.Contains('\') -or $Path -match '^[A-Za-z]:' -or
        @($Path.Split('/') | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
        throw 'Invalid repo-relative path'
    }
    [void]$script:StrictUtf8.GetByteCount($Path)
}

function Read-NulRecord([string]$Text, [ref]$Offset) {
    $end = $Text.IndexOf([char]0, $Offset.Value)
    if ($end -lt 0) { throw 'Bad NUL record framing' }
    $record = $Text.Substring($Offset.Value, $end - $Offset.Value)
    $Offset.Value = $end + 1
    return $record
}

function Read-Numstat([string]$Text) {
    $offset = 0
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $changes = New-Object 'Collections.Generic.List[object]'
    while ($offset -lt $Text.Length) {
        $record = Read-NulRecord $Text ([ref]$offset)
        $first = $record.IndexOf([char]9)
        $second = $record.IndexOf([char]9, [Math]::Max(0, $first + 1))
        if ($first -le 0 -or $second -le $first + 1) { throw 'Bad numstat record framing' }
        $addedText = $record.Substring(0, $first)
        $deletedText = $record.Substring($first + 1, $second - $first - 1)
        $path = $record.Substring($second + 1)
        $oldPath = $null
        if ($path.Length -eq 0) {
            $oldPath = Read-NulRecord $Text ([ref]$offset)
            $path = Read-NulRecord $Text ([ref]$offset)
            Assert-RelativePath $oldPath
            if ($oldPath -ceq $path) { throw 'Bad rename record framing' }
        }
        Assert-RelativePath $path
        # A file row (including a rename) is counted once, not once per pathname.
        # A pathname can be a rename source in one row and destination in another.
        if (-not $seen.Add($path + [char]0 + $oldPath)) { throw 'Duplicate numstat row' }
        $binary = $addedText -ceq '-' -and $deletedText -ceq '-'
        [long]$added = 0
        [long]$deleted = 0
        if (-not $binary) {
            if ($addedText -cnotmatch '\A[0-9]+\z' -or $deletedText -cnotmatch '\A[0-9]+\z' -or
                -not [long]::TryParse($addedText, [ref]$added) -or
                -not [long]::TryParse($deletedText, [ref]$deleted) -or
                $added -gt [long]::MaxValue - $deleted) { throw 'Bad numstat counts' }
        }
        $lines = if ($binary) { 'binary' } else { $added + $deleted }
        $changes.Add([pscustomobject][ordered]@{
            path = $path; oldPath = $oldPath; added = $(if ($binary) { '-' } else { $added })
            deleted = $(if ($binary) { '-' } else { $deleted }); lines = $lines
        })
    }
    return $changes.ToArray()
}

function Read-Residue([string]$Text) {
    $offset = 0
    $unstaged = 0
    $untracked = 0
    while ($offset -lt $Text.Length) {
        $record = Read-NulRecord $Text ([ref]$offset)
        if ($record.Length -lt 4 -or $record[2] -ne [char]32) { throw 'Bad status record framing' }
        $xy = $record.Substring(0, 2)
        # Residue paths are opaque warning data, including directory entries ending in '/'.
        if ($xy -ceq '??') { $untracked++; continue }
        if ($xy -ceq '!!') { throw 'Unexpected ignored status record' }
        if ($xy -cnotmatch '^[ MADRCUT][ MADRCUT]$' -or $xy -ceq '  ') { throw 'Bad status code' }
        if ($xy.Contains('R') -or $xy.Contains('C')) {
            $original = Read-NulRecord $Text ([ref]$offset)
            if ($original.Length -eq 0) { throw 'Bad status record framing' }
        }
        if ($xy[1] -ne [char]32) { $unstaged++ }
    }
    return [ordered]@{ unstaged = $unstaged; untracked = $untracked }
}

try {
    $seenOptions = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    for ($i = 0; $i -lt $scriptArguments.Count; $i++) {
        $option = $scriptArguments[$i]
        if ($option -isnot [string] -or $option -notmatch '\A-(Repo|Paths|MaxFiles|MaxLines|Json)\z') {
            throw 'Unexpected argument'
        }
        if (-not $seenOptions.Add($option)) { throw "Duplicate argument: $option" }
        if ($option -ieq '-Json') { $Json = $true; continue }
        if ($option -ieq '-Paths') {
            $pathList = New-Object 'Collections.Generic.List[string]'
            while ($i + 1 -lt $scriptArguments.Count) {
                $next = $scriptArguments[$i + 1]
                if ($next -is [string] -and $next -match '\A-(Repo|Paths|MaxFiles|MaxLines|Json)\z') { break }
                # Prevent a misspelled limit flag from silently becoming a prediction.
                # Arrays preserve literal dash-prefixed paths; native callers can use
                # -Paths -- <paths> after supplying all other options.
                if ($next -is [string] -and $next -ceq '--') {
                    $i++
                    while ($i + 1 -lt $scriptArguments.Count) {
                        $i++
                        $value = $scriptArguments[$i]
                        if ($value -isnot [string]) { throw 'Paths must contain strings' }
                        $pathList.Add($value)
                    }
                    break
                }
                if ($next -is [string] -and $next.StartsWith('-')) { throw "Unexpected argument: $next" }
                $i++
                foreach ($value in @($next)) {
                    if ($value -isnot [string]) { throw 'Paths must contain strings' }
                    $pathList.Add($value)
                }
            }
            $Paths = $pathList.ToArray()
            continue
        }
        if ($i + 1 -ge $scriptArguments.Count -or
            ($scriptArguments[$i + 1] -is [string] -and
                $scriptArguments[$i + 1] -match '\A-(Repo|Paths|MaxFiles|MaxLines|Json)\z')) {
            throw "Missing value for $option"
        }
        $i++
        $value = $scriptArguments[$i]
        if ($option -ieq '-Repo') {
            if ($value -isnot [string]) { throw 'Repo must be a string' }
        } else {
            # Unquoted PowerShell numeric literals arrive as integer objects.
            $integerTypes = @('Byte', 'SByte', 'Int16', 'UInt16', 'Int32', 'UInt32', 'Int64', 'UInt64')
            if ($value -isnot [string] -and $integerTypes -notcontains ([Convert]::GetTypeCode($value).ToString())) {
                throw 'MaxFiles and MaxLines must be integers'
            }
            $value = [Convert]::ToString($value, [Globalization.CultureInfo]::InvariantCulture)
        }
        switch ($option) {
            '-Repo' { $Repo = $value }
            '-MaxFiles' { $MaxFiles = $value }
            '-MaxLines' { $MaxLines = $value }
        }
    }
    if ([string]::IsNullOrEmpty($Repo) -or
        $Repo -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+(?:\\|$))' -or
        -not [IO.Directory]::Exists($Repo)) { throw 'Repo must be an existing absolute directory' }
    [void]$script:StrictUtf8.GetByteCount($Repo)
    [long]$fileLimit = 0
    [long]$lineLimit = 0
    if ($MaxFiles -cnotmatch '\A[0-9]+\z' -or -not [long]::TryParse($MaxFiles, [ref]$fileLimit) -or
        $MaxLines -cnotmatch '\A[0-9]+\z' -or -not [long]::TryParse($MaxLines, [ref]$lineLimit)) {
        throw 'MaxFiles and MaxLines must be nonnegative integers within Int64 range'
    }
    if ($null -eq $Paths -or $Paths.Count -eq 0) { throw 'Paths must contain predicted repo-relative paths' }
    $predicted = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($path in $Paths) { Assert-RelativePath $path; [void]$predicted.Add($path) }
    $head = Invoke-GuardGit @('rev-parse', '--verify', 'HEAD^{commit}')
    if ($head -cnotmatch '\A[0-9a-f]{40}(?:[0-9a-f]{24})?\r?\n\z') { throw 'Invalid HEAD commit response' }
    $numstat = Invoke-GuardGit @('diff', '--cached', '--numstat', '-z', '--find-renames', '--ignore-submodules=none', 'HEAD')
    $changes = @(Read-Numstat $numstat)
    if ($changes.Count -eq 0) { throw 'no staged changes' }
    $warnings = Read-Residue (Invoke-GuardGit @('status', '--porcelain', '-z', '--untracked-files=all'))
    $stagedPaths = New-Object 'Collections.Generic.List[string]'
    $seenPaths = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $outsidePaths = New-Object 'Collections.Generic.List[string]'
    [long]$lineCount = 0
    $binaryFileCount = 0
    foreach ($change in $changes) {
        if ($change.lines -ceq 'binary') { $binaryFileCount++ }
        else {
            if ($lineCount -gt [long]::MaxValue - $change.lines) { throw 'Numstat total overflow' }
            $lineCount += $change.lines
        }
        foreach ($path in @($change.oldPath, $change.path)) {
            if ($null -eq $path) { continue }
            if (-not $seenPaths.Add($path)) { continue }
            $stagedPaths.Add($path)
            if (-not $predicted.Contains($path)) { $outsidePaths.Add($path) }
        }
    }
    $within = $changes.Count -le $fileLimit -and $lineCount -le $lineLimit -and
        $binaryFileCount -eq 0 -and $outsidePaths.Count -eq 0
    Write-Result ([ordered]@{
        verdict = $(if ($within) { 'WITHIN' } else { 'OVER' })
        fileCount = $changes.Count; lineCount = $lineCount; binaryFileCount = $binaryFileCount
        maxFiles = $fileLimit; maxLines = $lineLimit; paths = @($stagedPaths.ToArray())
        outsidePaths = @($outsidePaths.ToArray()); changes = @($changes); warnings = $warnings
    })
    if ($within) { exit 0 }
    exit 1
} catch {
    Write-Result ([ordered]@{ verdict = 'ERROR'; error = $_.Exception.Message })
    exit 2
}
