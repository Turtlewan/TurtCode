# Tree pin for review and commit gates.
#
# A gate reads the tree at time T and acts on a verdict at time T+n. Nothing pins T -- so if the
# tree moves in between, the verdict describes a tree that no longer exists.
#
# This is not hypothetical. On 2026-07-14 a reviewer was dispatched against a live working tree,
# read store.py at +2 lines, and returned a high-severity finding four minutes later. By then the
# tree was at +6 and the finding was already fixed. The finding was correct WHEN MADE and false ON
# ARRIVAL, and the only reason anyone noticed was that someone happened to re-run `git diff --stat`.
#
# Stale-and-already-fixed is the harmless direction. The dangerous direction is identical in
# mechanism: the reviewer reads, the tree changes, the reviewer returns CLEAN -- and the gate
# blesses code nobody ever looked at. Same shape at the commit gate: what you verified and what you
# commit must be the same tree.
#
#   -Pin    before opening a gate (dispatching a review, starting a verify)
#   -Verify when the verdict comes back, BEFORE acting on it
#
# Exit 0 = tree unchanged, the verdict is about this tree, proceed.
# Exit 69 = tree MOVED. The verdict is void. Do not commit it, do not trust it. Re-run the gate.

[CmdletBinding()]
param(
    [switch]$Pin,
    [switch]$Verify,
    [switch]$Digest,
    [Parameter(Mandatory)][string]$Worktree,
    # Extra trees pinned/verified in the SAME gate (an APEX change spans ~/apex and ~/.claude).
    [string[]]$PinAlso = @(),
    [string]$Label,
    [string]$PinDirectory = $env:TEMP,
    [string]$RuntimeExclusionRoot = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'

function ConvertTo-DetailPath([string]$Path, [switch]$FileSystem) {
    $escaped = New-Object System.Text.StringBuilder
    # Iterate UTF-16 code units so surrogate pairs are rendered as two escapes.
    foreach ($character in $Path.ToCharArray()) {
        $code = [int]$character
        if ($code -lt 0x20 -or $code -gt 0x7E -or ($code -eq 0x5C -and -not $FileSystem)) {
            [void]$escaped.Append(('\u{0:x4}' -f $code))
        } else {
            [void]$escaped.Append($character)
        }
    }
    return $escaped.ToString()
}

$modeCount = 0
foreach ($mode in @($Pin, $Verify, $Digest)) {
    if ($mode) { $modeCount++ }
}
if ($modeCount -ne 1) {
    throw 'Pass exactly one of -Pin, -Verify, or -Digest.'
}
if (($Pin -or $Verify) -and [string]::IsNullOrEmpty($Label)) {
    throw 'Pass -Label with -Pin or -Verify.'
}
if ($Digest -and @($PinAlso).Count -gt 0) {
    throw 'Pass no -PinAlso with -Digest.'
}
foreach ($root in (@($Worktree) + $PinAlso)) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Worktree does not exist: $(ConvertTo-DetailPath $root -FileSystem)"
    }
}

# The pin identity must include the WORKTREE, not just a lossy label. Two concurrent reviews of the
# same spec/task in DIFFERENT worktrees are explicitly allowed (that is the whole point of one
# worktree per task) -- and they shared one pin file. The second overwrote the first, so the first
# then verified its tree against the SECOND's pin and returned 0 on a tree that had moved.
$safeLabel = ($Label -replace '[<>:"/\\|?*]', '_')

# The pin must cover CONTENT, not just which files are dirty. A reviewer that read store.py at +2
# and returns after it grows to +6 sees the same `git status` line either way -- the filename never
# changed, only what is inside it. `git status --porcelain` alone would have missed today's move
# entirely. Hash the content of every tracked-but-modified and untracked file.
function Invoke-Git {
    param(
        [string]$Root,
        [switch]$NulRecords,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs
    )
    # Fail closed without relying on a stale native $LASTEXITCODE after a launch failure.
    $exitCodeSentinel = [int]::MinValue
    $exitCode = $exitCodeSentinel
    # .NET Framework has no ArgumentList. Encode arguments using CommandLineToArgvW's rule.
    function ConvertTo-GitArgument([AllowEmptyString()][string]$Argument, [bool]$AlwaysQuote = $false) {
        if (-not $AlwaysQuote -and $Argument.Length -gt 0 -and $Argument -notmatch '[ "\t]') {
            return $Argument
        }
        $encoded = New-Object System.Text.StringBuilder
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
    $process = New-Object System.Diagnostics.Process
    $stdout = New-Object System.IO.MemoryStream
    try {
        $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $arguments = @('-C', $Root) + $GitArgs
        $extension = [System.IO.Path]::GetExtension($gitCommand.Source)
        $isShim = [string]::Equals($extension, '.cmd', [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($extension, '.bat', [StringComparison]::OrdinalIgnoreCase)
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        if ($isShim) {
            # Quote every token to protect cmd metacharacters, then enclose the whole /s command.
            $commandLine = (ConvertTo-GitArgument $gitCommand.Source $true) + ' ' +
                [string]::Join(' ', [string[]]@($arguments | ForEach-Object { ConvertTo-GitArgument $_ $true }))
            if ([regex]::Matches($commandLine, '%').Count -ge 2) {
                throw 'percent expansion is unsafe for a cmd.exe shim command line containing two or more percent characters'
            }
            $startInfo.FileName = $env:ComSpec
            $startInfo.Arguments = '/d /v:off /s /c "' + $commandLine + '"'
        } else {
            $startInfo.FileName = $gitCommand.Source
            $startInfo.Arguments = [string]::Join(' ', [string[]]@($arguments | ForEach-Object { ConvertTo-GitArgument $_ }))
        }
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        # Some launchers supply both Path and PATH. Framework's lazy environment
        # copy throws on that duplicate after initializing its dictionary; rebuild
        # the child copy with case-insensitive assignment without touching the parent.
        try { $childEnvironment = $startInfo.get_EnvironmentVariables() }
        catch {
            if ($_.Exception.InnerException -isnot [ArgumentException]) { throw }
            $childEnvironment = $startInfo.get_EnvironmentVariables()
        }
        $childEnvironment.Clear()
        foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
            $childEnvironment[$entry.Key] = $entry.Value
        }
        $childEnvironment['GIT_LITERAL_PATHSPECS'] = '1'
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'process did not start' }
        $process.StandardInput.Close()
        # Drain stderr concurrently; exit-0 warnings remain harmless and discarded.
        $stderrDrain = $process.StandardError.BaseStream.CopyToAsync([System.IO.Stream]::Null)
        $process.StandardOutput.BaseStream.CopyTo($stdout)
        [void]$stderrDrain.GetAwaiter().GetResult()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        $bytes = $stdout.ToArray()
    } catch {
        throw "git failed or could not launch in '$(ConvertTo-DetailPath $Root -FileSystem)' ($([string]::Join(' ', $GitArgs))): $($_.Exception.Message)"
    } finally {
        $stdout.Dispose()
        $process.Dispose()
    }
    if ($exitCode -eq $exitCodeSentinel) {
        throw "git did not report an exit status in '$(ConvertTo-DetailPath $Root -FileSystem)' ($([string]::Join(' ', $GitArgs)))."
    }
    if ($exitCode -ne 0) {
        throw "git exited with status $exitCode in '$(ConvertTo-DetailPath $Root -FileSystem)' ($([string]::Join(' ', $GitArgs)))."
    }
    $offset = 0
    if (-not $NulRecords -and $bytes.Length -ge 3 -and
            $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
    } catch {
        throw "git stdout UTF-8 decoding failed in '$(ConvertTo-DetailPath $Root -FileSystem)' ($([string]::Join(' ', $GitArgs))): $($_.Exception.Message)"
    }
    if ($text.Length -eq 0) { return @() }
    $separator = if ($NulRecords) { '\0' } else { '\r\n|\r|\n' }
    $output = @($text -split $separator)
    if ($output[-1].Length -eq 0) { $output = @($output | Select-Object -SkipLast 1) }
    return $output
}

# BEGIN build-outputs lockstep
function ConvertFrom-BuildOutputsSection {
    param([AllowEmptyString()][string]$Text)

    $lines = @($Text -split '\r?\n')
    $headings = New-Object System.Collections.Generic.List[int]
    $insideFence = New-Object 'bool[]' $lines.Count
    $fenceChar = ''
    $fenceLength = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $insideFence[$i] = $fenceLength -gt 0
        if ($fenceLength -gt 0) {
            $closePattern = '^ {0,3}' + [regex]::Escape($fenceChar) + '{' + $fenceLength + ',}[ \t]*$'
            if ($lines[$i] -match $closePattern) { $fenceLength = 0 }
            continue
        }
        if ($lines[$i] -match '^ {0,3}(?<Fence>`{3,}|~{3,})(?<Info>.*)$') {
            $fenceChar = $Matches['Fence'].Substring(0, 1)
            $fenceLength = $Matches['Fence'].Length
            continue
        }
        if ($lines[$i] -cmatch '^ {0,3}## Build outputs[ \t]*$') { $headings.Add($i) }
    }

    $entries = New-Object System.Collections.Generic.List[string]
    $reason = $null
    $errorLine = 0
    if ($headings.Count -gt 1) {
        $reason = 'duplicate exact heading'
        $errorLine = $headings[1] + 1
    } elseif ($headings.Count -eq 1) {
        $heading = $headings[0]
        $opened = $false
        $closed = $false
        $openingLine = $heading + 1
        for ($i = $heading + 1; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $errorLine = $i + 1
            if (-not $opened) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($line -notmatch '^ {0,3}(?<Fence>`{3,}|~{3,})(?<Info>.*)$') {
                    $reason = 'fence must be the first nonblank line after the heading'
                    break
                }
                $fenceChar = $Matches['Fence'].Substring(0, 1)
                $fenceLength = $Matches['Fence'].Length
                $info = $Matches['Info'].Trim()
                if ($info -cne '' -and $info -cne 'text') {
                    $reason = "fence info must be empty or 'text'"
                    break
                }
                $opened = $true
                $openingLine = $i + 1
                continue
            }
            if ($closed) {
                if (-not $insideFence[$i] -and $line -match '^ {0,3}#{1,6}(?:[ \t]+|$)') { break }
                if ($line -match '^ {0,3}(?:`{3,}|~{3,})') {
                    $reason = 'only one fence is allowed before the next heading'
                    break
                }
                continue
            }
            $closePattern = '^ {0,3}' + [regex]::Escape($fenceChar) + '{' + $fenceLength + ',}[ \t]*$'
            if ($line -match $closePattern) { $closed = $true; continue }
            $entry = $line.Trim()
            if ($entry.Length -eq 0) { continue }
            if ($entries.Count -ge 32) { $reason = 'more than 32 entries'; break }
            if ($entry.Contains('**') -or $entry -match '[?\[\]{}!]' -or $entry.Contains('\')) {
                $reason = 'unsupported wildcard or backslash'; break
            }
            if ($entry.StartsWith('/') -or $entry.EndsWith('/') -or $entry.Contains(':')) {
                $reason = 'path must be repo-relative without leading/trailing slash or drive'; break
            }
            $segments = @($entry -split '/')
            $invalidSegment = $false
            foreach ($segment in $segments) {
                if ($segment.Length -eq 0 -or $segment -ceq '.' -or $segment -ceq '..' -or
                        [string]::Equals($segment, '.git', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $invalidSegment = $true; break
                }
            }
            if ($invalidSegment) { $reason = 'empty, dot, parent, or .git segment'; break }
            if ($segments[-1].Contains('*')) { $reason = "'*' is forbidden in the final segment"; break }
            $entries.Add($entry)
        }
        if (-not $reason -and (-not $opened -or -not $closed)) {
            $reason = 'missing or unclosed fence'
            $errorLine = $openingLine
        }
    }
    $warning = $null
    if ($reason) {
        $entries.Clear()
        $warning = "AGENTS.md '## Build outputs' unparseable (line ${errorLine}: $reason); no build-output exclusions applied"
    }
    return [pscustomobject]@{ Entries = @($entries.ToArray()); Warning = $warning }
}

function Test-IsDeclaredBuildOutputPath {
    param([string]$Path, [AllowEmptyCollection()][string[]]$Entries)

    $pathSegments = @($Path -split '/')
    foreach ($entry in @($Entries)) {
        $patternSegments = @($entry -split '/')
        if ($pathSegments.Count -lt $patternSegments.Count) { continue }
        $matchesPrefix = $true
        for ($i = 0; $i -lt $patternSegments.Count; $i++) {
            # Match literals ordinally, including the literal pieces surrounding a single-segment
            # '*'. Regex IgnoreCase alone uses culture-sensitive casing and is not this contract.
            $pieces = @($patternSegments[$i] -split '\*')
            $segment = $pathSegments[$i]
            $position = 0
            if (-not $segment.StartsWith($pieces[0], [System.StringComparison]::OrdinalIgnoreCase)) {
                $matchesPrefix = $false; break
            }
            $position = $pieces[0].Length
            if ($pieces.Count -eq 1) {
                if ($position -ne $segment.Length) { $matchesPrefix = $false; break }
                continue
            }
            for ($j = 1; $j -lt $pieces.Count - 1; $j++) {
                $found = $segment.IndexOf($pieces[$j], $position, [System.StringComparison]::OrdinalIgnoreCase)
                if ($found -lt 0) { $matchesPrefix = $false; break }
                $position = $found + $pieces[$j].Length
            }
            if (-not $matchesPrefix) { break }
            $lastPiece = $pieces[-1]
            if (-not $segment.EndsWith($lastPiece, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $segment.Length - $lastPiece.Length -lt $position) {
                $matchesPrefix = $false; break
            }
        }
        if ($matchesPrefix) { return $true }
    }
    return $false
}
# END build-outputs lockstep

# Fetch each root through this script's fail-closed adapter; a failed lookup is not an absent file.
function Get-DeclaredBuildOutputs([string]$Root) {
    $entries = @()
    $agentsAtHead = @(Invoke-Git $Root -NulRecords ls-tree --full-tree --name-only -z HEAD '--' AGENTS.md)
    $hasAgents = $false
    foreach ($path in $agentsAtHead) {
        if ([string]::Equals($path, 'AGENTS.md', [StringComparison]::OrdinalIgnoreCase)) { $hasAgents = $true }
    }
    if ($hasAgents) {
        $agentsText = [string]::Join("`n", [string[]]@(Invoke-Git $Root show HEAD:AGENTS.md))
        $declaration = ConvertFrom-BuildOutputsSection -Text $agentsText
        $entries = @($declaration.Entries)
        if (($Pin -or $Verify) -and $declaration.Warning) {
            Write-Host "[tree-pin] WARNING: $($declaration.Warning)" -ForegroundColor Yellow
        }
    }
    return ,$entries
}

# A DIRECTORY is hashed by its recursive contents, never written off as unhashable.
#
# git COLLAPSES an untracked directory into one porcelain entry: `?? newdir/`. Returning a constant
# for it means the fingerprint is identical before and after a coder rewrites every file inside it --
# so Verify returns 0 and the gate blesses content the reviewer never saw. The pin then certifies
# precisely the blind spot it was built to eliminate.
function Test-IsRuntimeMarker([string]$NormalizedPath) {
    $prefix = 'skills/synced/'
    if (-not $NormalizedPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $suffix = $NormalizedPath.Substring($prefix.Length)
    $separator = $suffix.IndexOf('/', [StringComparison]::OrdinalIgnoreCase)
    if ($separator -lt 0) {
        return $suffix.StartsWith('.bucket-', [StringComparison]::OrdinalIgnoreCase) -and $suffix.Length -gt 8
    }
    if ($separator -eq 0) { return $false }
    $marker = $suffix.Substring($separator + 1)
    return [string]::Equals($marker, '.last-complete-round', [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($marker, 'manifest.json', [StringComparison]::OrdinalIgnoreCase)
}

function Get-PathDigest([string]$Root, [string]$relPath, [bool]$SkipRuntimeMarkers = $false,
        [string[]]$DeclaredIgnoredRows = @()) {
    $full = Join-Path $Root $relPath

    if (Test-Path -LiteralPath $full -PathType Container) {
        # Keep this digest field-for-field aligned with Get-ContentHash in codex-scope-check.ps1.
        $parts = New-Object System.Collections.Generic.List[string]
        $skippedRuntimeMarkers = 0
        $enumErr = $null
        foreach ($file in (Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable enumErr |
                Sort-Object FullName)) {
            $rel = $file.FullName.Substring($Root.Length).TrimStart([char]92, [char]47) -replace '\\', '/'
            if ($SkipRuntimeMarkers -and (Test-IsRuntimeMarker $rel)) {
                $skippedRuntimeMarkers++
                continue
            }
            # Only actual declared !! rows can hide files in a collapsed ?? directory.
            $isDeclaredIgnored = $false
            foreach ($ignoredRow in @($DeclaredIgnoredRows)) {
                if ([string]::Equals($rel, $ignoredRow, [System.StringComparison]::OrdinalIgnoreCase) -or
                        $rel.StartsWith($ignoredRow + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isDeclaredIgnored = $true
                    break
                }
            }
            if ($isDeclaredIgnored) { continue }
            $parts.Add("$rel|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)")
        }
        # A subtree we could not read must not fingerprint identically to one we could.
        if ($enumErr -and $enumErr.Count -gt 0) { $parts.Add("UNREADABLE|$($enumErr.Count)") }
        if ($parts.Count -eq 0 -and $skippedRuntimeMarkers -gt 0) { return $null }
        if ($parts.Count -eq 0) { return 'dir:empty' }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]::Join("`n", $parts))
            return 'dir:' + [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLower()
        } finally { $sha.Dispose() }
    }

    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return '-' }
    # A file can exist and still be unreadable: a live process may hold it with FileShare.None, and
    # `--ignored=traditional` puts exactly those runtime lock files in scope. `git hash-object` then
    # exits 128 and Invoke-Git throws, which took the WHOLE pin down -- so no gate could open against
    # a repo whose app was running. (Artemis, 2026-07-27: the launcher holds
    # artemis-supervisor-<port>.lock for the life of the supervised brain.)
    #
    # Mirror what the directory branch above already does for an unreadable subtree: degrade to a
    # metadata fingerprint rather than crashing, and never let it collide with a real hash. Size and
    # mtime still move if the file's content moves, so Verify keeps its teeth; a file that becomes
    # readable also changes digest FORM, which reads as a moved tree -- the fail-safe direction.
    try {
        $h = Invoke-Git $Root hash-object '--' $relPath
    } catch {
        # Only tolerate genuine unreadability. Any other git failure is still a hard error, or this
        # catch would quietly swallow a broken repository and hand back a valid-looking pin.
        $readable = $false
        try {
            $probe = [System.IO.File]::Open($full, 'Open', 'Read', 'ReadWrite')
            $probe.Dispose()
            $readable = $true
        } catch { $readable = $false }
        if ($readable) { throw }
        $info = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        if ($null -eq $info) { return 'unreadable:gone' }
        return "unreadable:$($info.Length):$($info.LastWriteTimeUtc.Ticks)"
    }
    if (-not $h) { return '-' }
    return ([string]$h).Trim()
}

# The INDEX is part of the tree's state, and a commit is made from the index -- not from the files.
# Hashing only the working-tree blob leaves a hole: with HEAD=O, index=A, worktree=B, porcelain
# reads `MM` and the pin records B. Stage a different blob C (git update-index / git apply --cached)
# and porcelain still reads `MM` and the pin still records B -- Verify returns 0 while the commit
# now contains unreviewed C. So pin what will actually be committed, not just what is on disk.
function Get-IndexDigest([string]$Root, [string]$relPath) {
    $entry = Invoke-Git $Root ls-files -s '--' $relPath
    if (-not $entry) { return '-' }
    # `<mode> <sha> <stage>\t<path>`. Record the MODE and the STAGE as well as the blob: a
    # `git update-index --chmod=+x` changes what gets committed (a file becomes executable) while
    # leaving both blobs identical, so a sha-only digest verified clean on a tree whose next commit
    # differs. The stage catches an unresolved merge conflict for the same reason.
    $fields = ([string]$entry).Split(@(' ', "`t"), [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($fields.Count -ge 3) { return "$($fields[0]):$($fields[1]):$($fields[2])" }
    if ($fields.Count -ge 2) { return "$($fields[0]):$($fields[1])" }
    return '-'
}

function Get-TreeFingerprint([string]$Root, [bool]$ApplyRuntimeExclusions) {
    $lines = @()

    # Committed state matters too: a commit landing mid-gate moves the baseline under the verdict.
    $head = Invoke-Git $Root rev-parse HEAD
    $lines += "HEAD $head"

    $declaredBuildOutputs = Get-DeclaredBuildOutputs $Root
    $records = @(Invoke-Git $Root -NulRecords status --porcelain=v1 -z --ignored=traditional)
    # Pair rename/copy origins before any filtering. -z puts the destination first.
    $status = @(for ($i = 0; $i -lt $records.Count; $i++) {
        $entry = $records[$i]
        if ([string]::IsNullOrEmpty($entry)) { continue }
        if ($entry.Length -lt 4 -or $entry[2] -ne [char]32) { throw 'Malformed git status record' }
        $xy = $entry.Substring(0, 2)
        $path = $entry.Substring(3)
        $sortKey = $entry
        if ($xy -match '[RC]') {
            $i++
            if ($i -ge $records.Count -or [string]::IsNullOrEmpty($records[$i])) {
                throw 'Missing git rename/copy origin record'
            }
            $sortKey = "$xy $($records[$i]) -> $path"
        }
        [pscustomobject]@{ Entry = $entry; SortKey = $sortKey }
    })
    $declaredIgnoredRows = @(foreach ($entry in @($status)) {
        if ($entry.Entry.StartsWith('!! ', [StringComparison]::Ordinal)) {
            $ignoredPath = ($entry.Entry.Substring(3) -replace '\\', '/').TrimEnd('/')
            if (Test-IsDeclaredBuildOutputPath -Path $ignoredPath -Entries $declaredBuildOutputs) {
                $ignoredPath
            }
        }
    })
    # Mirrored by codex-scope-check.ps1's -Check runtime-path exclusion; keep both lists in sync.
    # Scope-check discriminates on ref presence (index OR HEAD, so host-curated paths stay checked),
    # rather than the `!!` status class used here.
    $runtimeExclusions = @(
        'sessions',
        'projects',
        'backups',
        'jobs',
        'shell-snapshots',
        'todos',
        'file-history',
        'history.jsonl',
        '.last-update-result.json'
    )
    # Build-TOOL caches, excluded in EVERY worktree (unlike $runtimeExclusions above, which is
    # ~/.claude-only). These are written by the gate's own pre-flight: apex-baseline-check runs
    # mypy and pytest BETWEEN the pin and the verify, so their caches are guaranteed to move and the
    # gate could never pass on a project repo. Observed 2026-07-27 in artemis: dispatch exit 69 with
    # CHANGED .mypy_cache/ + .pytest_cache/ after a GREEN baseline -- a self-inflicted deadlock that
    # blocks every build dispatch into a fresh worktree.
    #
    # Safe to exclude: a tool cache is derived output. It cannot carry code a coder wrote, so it can
    # never be the blind spot the pin exists to close. Ignored (`!!`) entries only -- a repo that
    # TRACKS one of these names is still fingerprinted.
    $toolCacheExclusions = @(
        '.mypy_cache',
        '.pytest_cache',
        '.ruff_cache',
        '__pycache__',
        '.coverage',
        'node_modules/.cache',
        '.venv'
    )
    foreach ($row in ($status | Sort-Object SortKey)) {
        $entry = $row.Entry
        if ([string]::IsNullOrEmpty($entry)) { continue }
        $xy = $entry.Substring(0,2)
        $path = $entry.Substring(3)
        $normalizedPath = ($path -replace '\\', '/').TrimEnd('/')
        if ($ApplyRuntimeExclusions -and $xy -eq '!!') {
            $excluded = $false
            foreach ($prefix in $runtimeExclusions) {
                if ([string]::Equals($normalizedPath, $prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
                        $normalizedPath.StartsWith($prefix + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $excluded = $true
                    break
                }
            }
            if ($excluded) { continue }
            if (-not $path.EndsWith('/', [StringComparison]::OrdinalIgnoreCase) -and
                    (Test-Path -LiteralPath (Join-Path $Root $path) -PathType Leaf) -and
                    (Test-IsRuntimeMarker $normalizedPath)) {
                continue
            }
        }
        # Tool caches: every worktree, ignored entries only.
        if ($xy -eq '!!') {
            $isToolCache = $false
            foreach ($prefix in $toolCacheExclusions) {
                if ([string]::Equals($normalizedPath, $prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
                        $normalizedPath.StartsWith($prefix + '/', [System.StringComparison]::OrdinalIgnoreCase) -or
                        $normalizedPath.EndsWith('/' + $prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
                        $normalizedPath.IndexOf('/' + $prefix + '/', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $isToolCache = $true
                    break
                }
            }
            if ($isToolCache) { continue }
        }
        if ($xy -ceq '!!' -and (Test-IsDeclaredBuildOutputPath -Path $normalizedPath -Entries $declaredBuildOutputs)) {
            continue
        }
        $directoryExclusions = @()
        if ($xy -ceq '??') { $directoryExclusions = $declaredIgnoredRows }
        $work = Get-PathDigest $Root $path ($ApplyRuntimeExclusions -and $xy -eq '!!') $directoryExclusions
        if ($null -eq $work) { continue }
        $lines += "$xy $path work:$work index:$(Get-IndexDigest $Root $path)"
    }

    $joined = [string]::Join("`n", $lines)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLower()
    } finally {
        $sha.Dispose()
    }
    return [pscustomobject]@{ Digest = $digest; Detail = $joined }
}

$resolvedRuntimeExclusionRoot = $null
if (Test-Path -LiteralPath $RuntimeExclusionRoot -PathType Container) {
    $resolvedRuntimeExclusionRoot = (Resolve-Path -LiteralPath $RuntimeExclusionRoot).Path.TrimEnd('\', '/')
}

$trees = @(foreach ($root in (@($Worktree) + $PinAlso)) {
    $worktreeFull = (Resolve-Path -LiteralPath $root).Path
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $keyBytes = [System.Text.Encoding]::UTF8.GetBytes(($worktreeFull -replace '\\', '/').TrimEnd('/').ToLowerInvariant())
        $worktreeTag = [System.BitConverter]::ToString($sha.ComputeHash($keyBytes)).Replace('-', '').Substring(0, 10).ToLower()
    } finally { $sha.Dispose() }

    [pscustomobject]@{
        Root = $worktreeFull
        PinPath = Join-Path $PinDirectory "apex-treepin-$safeLabel-$worktreeTag.txt"
        Fingerprint = Get-TreeFingerprint $worktreeFull ($null -ne $resolvedRuntimeExclusionRoot -and
            [string]::Equals($worktreeFull.TrimEnd('\', '/'), $resolvedRuntimeExclusionRoot, [System.StringComparison]::OrdinalIgnoreCase))
    }
})

if ($Digest) {
    $trees[0].Fingerprint.Digest
    exit 0
}

if ($Pin) {
    foreach ($tree in $trees) {
        [System.IO.File]::WriteAllText($tree.PinPath, "treepin-v2`n" + $tree.Fingerprint.Digest + "`n" + $tree.Fingerprint.Detail,
            [System.Text.UTF8Encoding]::new($false))
        if ($trees.Count -eq 1) {
            Write-Host "[tree-pin] pinned $($tree.Fingerprint.Digest.Substring(0,12)) for '$Label'" -ForegroundColor DarkGray
        } else {
            Write-Host "[tree-pin] pinned $($tree.Fingerprint.Digest.Substring(0,12)) for '$Label' in '$(ConvertTo-DetailPath $tree.Root -FileSystem)'" -ForegroundColor DarkGray
        }
    }
    exit 0
}

# The porcelain status prefix is two columns WITH SIGNIFICANT SPACES (" M", "?? ", "A "), so the
# prefix must be matched as two arbitrary characters -- not two non-space ones.
$parseDetail = {
    param([string]$Detail)
    $map = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $Detail -split "`n") {
        if ($line -match '^(.{2}) (.+) (work:\S+ index:\S+)$') { $map[$Matches[2]] = $Matches[3] }
    }
    return $map
}

$failed = $false
foreach ($tree in $trees) {
    if (-not (Test-Path -LiteralPath $tree.PinPath -PathType Leaf)) {
        if ($trees.Count -eq 1) {
            Write-Host "[tree-pin] NO PIN for '$Label'. The gate was opened without pinning the tree, so nothing can vouch for the verdict." -ForegroundColor Red
        } else {
            Write-Host "[tree-pin] NO PIN for '$Label' in '$(ConvertTo-DetailPath $tree.Root -FileSystem)'. The gate was opened without pinning this tree, so nothing can vouch for the verdict." -ForegroundColor Red
        }
        $failed = $true
        continue
    }

    $pinLines = [System.IO.File]::ReadAllLines($tree.PinPath)
    if ($pinLines.Count -eq 0 -or $pinLines[0] -ne 'treepin-v2') {
        Write-Host 'pin predates digest scheme v2 -- re-pin'
        $failed = $true
        continue
    }
    $pinnedDigest = $pinLines[1]
    if ($pinnedDigest -eq $tree.Fingerprint.Digest) {
        if ($trees.Count -eq 1) {
            Write-Host "[tree-pin] tree unchanged ($($pinnedDigest.Substring(0,12))) -- the verdict is about this tree." -ForegroundColor DarkGray
        } else {
            Write-Host "[tree-pin] tree unchanged ($($pinnedDigest.Substring(0,12))) in '$(ConvertTo-DetailPath $tree.Root -FileSystem)' -- the verdict is about this tree." -ForegroundColor DarkGray
        }
        continue
    }

    $pinnedDetail = [string]::Join("`n", ($pinLines | Select-Object -Skip 2))
    $before = & $parseDetail $pinnedDetail
    $after = & $parseDetail $tree.Fingerprint.Detail

    Write-Host ''
    Write-Host "[tree-pin] THE TREE MOVED WHILE THE GATE WAS OPEN. The verdict for '$Label' is VOID." -ForegroundColor Red
    if ($trees.Count -gt 1) { Write-Host "[tree-pin] Root: $(ConvertTo-DetailPath $tree.Root -FileSystem)" -ForegroundColor Red }
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in ($before.Keys + $after.Keys)) { [void]$paths.Add($path) }
    foreach ($path in ($paths | Sort-Object)) {
        $displayPath = ConvertTo-DetailPath $path
        if (-not $after.ContainsKey($path)) { Write-Host "[tree-pin]   GONE:    $displayPath" -ForegroundColor Red }
        elseif (-not $before.ContainsKey($path)) { Write-Host "[tree-pin]   NEW:     $displayPath" -ForegroundColor Red }
        elseif ($before[$path] -ne $after[$path]) { Write-Host "[tree-pin]   CHANGED: $displayPath" -ForegroundColor Red }
    }
    Write-Host "[tree-pin] Someone or something wrote to the tree after the gate opened -- a live coder, a" -ForegroundColor Red
    Write-Host "[tree-pin] concurrent agent, or a hand-edit. Do NOT act on this verdict. Find the writer," -ForegroundColor Red
    Write-Host "[tree-pin] let it finish, re-pin, and re-run the gate." -ForegroundColor Red
    Write-Host ''
    $failed = $true
}

if ($failed) { exit 69 }
exit 0
