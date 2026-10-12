# codex-scope-check.ps1 - DETECT a Codex task's out-of-scope writes. Never remediate them.
#
# THE BUG THIS FIXES (from a real Artemis AFK run):
# A `codex exec` task wrote docs/status.md despite the dispatch brief saying "authorized set --
# touch nothing else". Two fixes do NOT work and were rejected:
#   1. Another prohibition in the brief. The rule was already there and was ignored.
#   2. A PreToolUse deny hook. It CANNOT SEE these writes -- the Codex subprocess does not ride
#      Claude Code's permission floor. `--sandbox workspace-write` is repo-wide, not spec-wide.
# The only observation point is the host, after the subprocess exits.
#
# -- WHY THIS SCRIPT NO LONGER REVERTS ANYTHING (2026-07-14) ------------------------------------
# It used to auto-revert: delete untracked violations, `git checkout --` tracked ones. That rests on
# one inference:
#
#     clean at snapshot + dirty now + not authorized  =>  THE CODER WROTE IT
#
# That inference is false the moment anything else writes to the tree, and this script can never
# enumerate every writer. In ONE DAY it destroyed:
#   * a sibling Codex coder's freshly-written files, mid-run (it had no concept of a sibling)
#   * a background planning agent's drafts, mid-dispatch (an agent that is not, and can never be,
#     in the ledger)
# Each incident produced a narrower rule -- "one coder per tree", then "no concurrent writers at
# all" -- and each was still wrong, because there is always one more kind of writer. Untracked
# deletes are unrecoverable: no blob, no object, nothing.
#
# Then the scaffolding to make the bad inference safe (sibling guards, liveness checks, PID-reuse
# handling, quarantine, retention) became the single largest source of defects in the harness.
# So: REMOVE THE CAUSE, don't add another rule. This script now DETECTS and REPORTS. It fails the
# dispatch loudly, which blocks the commit, and the host cleans up deliberately with full
# information. Detection was always the load-bearing half; remediation-by-guess was never safe.
#
# USAGE
#   Before dispatch:  codex-scope-check.ps1 -Snapshot -Worktree <repo> -Task <name>
#   After it exits:   codex-scope-check.ps1 -Check -Worktree <repo> -Task <name> -Authorized 'src/a.py','tests/b.py'
#   Encoding gate:    codex-scope-check.ps1 -EncodingScan -Worktree <repo> -Task <name> -Authorized 'src/a.py'
#
# EXITS
#   0  = in scope (or, for -EncodingScan, no double-encoded text).
#   1  = out-of-scope writes found. NOTHING was touched. They are still in the tree; deal with them.
#   66 = the -Authorized list itself looks wrong (nothing the task wrote is on it).
#   73 = -EncodingScan only: double-encoded text (mojibake) in the scanned files.
#
# -EncodingScan needs NO snapshot and is INDEPENDENT of scope: it answers "are the bytes corrupt?",
# not "did the coder stay in its lane". It exists because this is the one defect class a green test
# suite GUARANTEES you will not see -- the coder writes the same corrupted bytes into the expected
# string as into the source, so the assertion compares corrupt to corrupt and passes.
#
# -- THREAT MODEL: A CARELESS CODER, NOT A HOSTILE ONE -----------------------------------------
# This catches a coder that WANDERED outside its file list. It is not a security boundary against a
# coder trying to EVADE it, and pretending otherwise would be the same theatre the rest of this
# harness was built to end. Stated limits, so nobody trusts it for more than it does:
#
#   * A corrupted .git. If `git status` cannot run, git's own output is the only thing this script
#     sees, and it will report what git reports.
#   * Anything git itself cannot see. Paths outside the worktree; writes through a symlink that
#     points out of the repo.
#   * A coder that reverts its own out-of-scope write before exiting. There is no journal, only a
#     before/after comparison -- so a write that is undone leaves no trace.
#   * Timing-based attribution generally. This script concludes "the coder wrote it" from "it changed
#     during the dispatch". When anything ELSE writes concurrently -- a sibling coder, a background
#     agent, your editor -- that inference is wrong. It is why nothing is auto-reverted any more:
#     it destroyed a sibling's files and an agent's drafts in one day, acting on exactly this guess.
#
# The real defences against a coder acting in bad faith are elsewhere and are not this script's job:
# --sandbox, the review gate, and a human reading the diff before it is committed.
#
# BUILD OUTPUTS GRAMMAR (committed AGENTS.md at the snapshot HEAD only):
# Exact '## Build outputs' (0-3 leading spaces, trailing whitespace allowed), outside Markdown
# fences; the first nonblank line must open one fence with empty or 'text' info, closed before
# any notes. Prose is allowed only below that fence, before the next heading. An empty fence is
# valid; at most 32 repo-relative directory prefixes, one per nonblank line. No **, ?, [], {}, !,
# backslashes, absolute/drive paths, empty, '.', '..', or '.git' segments, leading/trailing '/', or '*' in
# the final segment. '*' matches within one segment; matching is OrdinalIgnoreCase and never
# excludes an ancestor. Duplicate headings or any invalid entry disable the entire declaration.
# Exclusions are content-blind: declared + ignored + untracked + not host-curated. The ignored
# precondition within a declared prefix may come from an untracked nested .gitignore or
# .git/info/exclude. Every other ignored path stays checked. Untracked -uall ?? leaves require
# full-content SHA-256 hashing in-process; this costs reading every untracked leaf's bytes.

[CmdletBinding()]
param(
    [switch]$Snapshot,
    [switch]$Check,
    [switch]$EncodingScan,
    [Parameter(Mandatory)][string]$Worktree,
    [Parameter(Mandatory)][string]$Task,
    [string[]]$Authorized = @(),
    [switch]$ReportOnly,          # accepted for compatibility; this script is always report-only now
    [string]$StateDirectory,
    [string]$WrittenPathsFile,
    [string]$ExcludeRunId,        # accepted for compatibility; no longer used (nothing is reverted)
    [string]$RuntimeExclusionRoot = (Join-Path $env:USERPROFILE '.claude')
)

$ErrorActionPreference = 'Stop'

# Escape Git paths for display; filesystem paths retain their backslash separators.
function ConvertTo-DisplayPath([string]$Path, [switch]$FileSystem) {
    $display = New-Object System.Text.StringBuilder
    foreach ($character in $Path.ToCharArray()) {
        $code = [int]$character
        if ($code -lt 0x20 -or $code -gt 0x7e -or ($code -eq 0x5c -and -not $FileSystem)) {
            [void]$display.Append(('\u{0:x4}' -f $code))
        } else {
            [void]$display.Append($character)
        }
    }
    return $display.ToString()
}

# Multiple modes used to run the first matching branch, so -Snapshot -Check overwrote the evidence
# and exited clean without checking it. Refuse ambiguous mode requests before touching state.
$selectedModes = @()
if ($Snapshot) { $selectedModes += '-Snapshot' }
if ($Check) { $selectedModes += '-Check' }
if ($EncodingScan) { $selectedModes += '-EncodingScan' }
if ($selectedModes.Count -gt 1) {
    throw "Mode switches are mutually exclusive; specify exactly one of -Snapshot, -Check, or -EncodingScan (received $($selectedModes -join ', '))."
}
if ($WrittenPathsFile -and -not $Check) {
    throw "-WrittenPathsFile is valid only with -Check."
}

if (-not (Test-Path $Worktree)) { throw "Worktree not found: $(ConvertTo-DisplayPath $Worktree -FileSystem)" }
$repo = (Resolve-Path $Worktree).Path
if ($WrittenPathsFile) {
    $writtenPathsFull = [System.IO.Path]::GetFullPath($WrittenPathsFile)
    $repoPrefix = $repo.TrimEnd([char]92, [char]47) + [System.IO.Path]::DirectorySeparatorChar
    if ([string]::Equals($writtenPathsFull, $repo, [System.StringComparison]::OrdinalIgnoreCase) -or
            $writtenPathsFull.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "-WrittenPathsFile must resolve outside the worktree: $(ConvertTo-DisplayPath $WrittenPathsFile -FileSystem)"
    }
}

# Quote one argument using the Windows CommandLineToArgvW backslash/quote rules.
function ConvertTo-GitArgument([string]$Value, [switch]$AlwaysQuote) {
    if (-not $AlwaysQuote -and $Value.Length -gt 0 -and $Value -notmatch '[ \t"]') { return $Value }
    $quoted = New-Object System.Text.StringBuilder
    [void]$quoted.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) { $slashes++; continue }
        if ($character -eq [char]34) {
            [void]$quoted.Append([char]92, (2 * $slashes + 1))
        } else {
            [void]$quoted.Append([char]92, $slashes)
        }
        [void]$quoted.Append($character)
        $slashes = 0
    }
    [void]$quoted.Append([char]92, (2 * $slashes))
    [void]$quoted.Append('"')
    return $quoted.ToString()
}

# Read bytes rather than PowerShell's native text pipe; Git paths are strict UTF-8.
# stderr is drained concurrently but never changes the verdict: the exit code does.
function Invoke-Git {
    param(
        [switch]$NulRecords,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs
    )
    $exitCodeSentinel = -987654
    $global:LASTEXITCODE = $exitCodeSentinel
    $exitCode = $exitCodeSentinel
    $launchException = $null
    $output = @()
    $process = $null
    $stdout = New-Object System.IO.MemoryStream
    try {
        $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $extension = [System.IO.Path]::GetExtension($gitCommand.Source)
        $shim = [string]::Equals($extension, '.cmd', [StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($extension, '.bat', [StringComparison]::OrdinalIgnoreCase)
        $arguments = @('-C', $repo) + $GitArgs
        $quotedArgs = @($arguments | ForEach-Object { ConvertTo-GitArgument $_ -AlwaysQuote:$shim })
        $info = New-Object System.Diagnostics.ProcessStartInfo
        if ($shim) {
            $commandLine = (ConvertTo-GitArgument $gitCommand.Source -AlwaysQuote) + ' ' + ($quotedArgs -join ' ')
            if ([regex]::Matches($commandLine, '%').Count -ge 2) {
                throw 'cmd.exe shim command contains two or more percent (%) characters; percent expansion cannot be transported reliably.'
            }
            $info.FileName = $env:ComSpec
            $info.Arguments = '/d /v:off /s /c "' + $commandLine + '"'
        } else {
            $info.FileName = $gitCommand.Source
            $info.Arguments = $quotedArgs -join ' '
        }
        $info.UseShellExecute = $false
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        # Some launchers supply both Path and PATH. Framework's lazy environment
        # copy throws on that duplicate after initializing its dictionary; rebuild
        # the child copy with case-insensitive assignment without touching the parent.
        try { $childEnvironment = $info.get_EnvironmentVariables() }
        catch {
            if ($_.Exception.InnerException -isnot [ArgumentException]) { throw }
            $childEnvironment = $info.get_EnvironmentVariables()
        }
        $childEnvironment.Clear()
        foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
            $childEnvironment[$entry.Key] = $entry.Value
        }
        $childEnvironment['GIT_LITERAL_PATHSPECS'] = '1'
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $info
        if (-not $process.Start()) { throw 'Process.Start returned false.' }
        $process.StandardInput.Close()
        $stderrDrain = $process.StandardError.BaseStream.CopyToAsync([System.IO.Stream]::Null)
        $process.StandardOutput.BaseStream.CopyTo($stdout)
        [void]$stderrDrain.GetAwaiter().GetResult()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        $global:LASTEXITCODE = $exitCode
        $bytes = $stdout.ToArray()
        $offset = 0
        if (-not $NulRecords -and $bytes.Length -ge 3 -and
                $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
        $decoded = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, $offset, $bytes.Length - $offset)
        if ($decoded.Length -gt 0) {
            $separator = if ($NulRecords) { '\x00' } else { '\r\n|\r|\n' }
            $output = @([regex]::Split($decoded, $separator))
            if ($output[-1].Length -eq 0) { $output = @($output | Select-Object -SkipLast 1) }
        }
    } catch {
        $launchException = $_.Exception
    } finally {
        $stdout.Dispose()
        if ($process) { $process.Dispose() }
    }

    $command = "git $($GitArgs -join ' ')"
    if ($launchException) {
        throw "$(ConvertTo-DisplayPath $command) failed to launch in '$(ConvertTo-DisplayPath $repo -FileSystem)'. Refusing to report clean: $($launchException.Message)"
    }
    if ($exitCode -eq $exitCodeSentinel) {
        throw "$(ConvertTo-DisplayPath $command) failed to launch in '$(ConvertTo-DisplayPath $repo -FileSystem)' and did not set an exit code. Refusing to report clean."
    }
    if ($exitCode -ne 0) {
        throw "$(ConvertTo-DisplayPath $command) failed in '$(ConvertTo-DisplayPath $repo -FileSystem)' (exit $exitCode). Refusing to report clean."
    }
    return $output
}

# Authorized/spec input retains its legacy whitespace trimming.
function Normalize([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    $n = ($p -replace '\\', '/').Trim()
    while ($n.StartsWith('./', [StringComparison]::OrdinalIgnoreCase)) { $n = $n.Substring(2) }
    return $n.TrimEnd('/')
}

# Git records are already decoded paths; whitespace and U+FEFF are filename characters.
function Normalize-GitPath([string]$p) {
    if ([string]::IsNullOrEmpty($p)) { return '' }
    $n = $p -replace '\\', '/'
    while ($n.StartsWith('./', [StringComparison]::OrdinalIgnoreCase)) { $n = $n.Substring(2) }
    return $n.TrimEnd('/')
}

function Get-DirtySet {
    # Pair porcelain v1 -z rename/copy destinations with origins before filtering !!.
    # Keep raw keys, including the trailing slash of collapsed ignored directories.
    $set = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($ignoredOnly in @($false, $true)) {
        $argsForStatus = @('status', '--porcelain=v1', '-z')
        if ($ignoredOnly) { $argsForStatus += '--ignored=traditional' }
        else { $argsForStatus += '--untracked-files=all' }
        $records = @(Invoke-Git -NulRecords @argsForStatus)
        for ($i = 0; $i -lt $records.Count; $i++) {
            $record = $records[$i]
            if ($record.Length -lt 4 -or $record[2] -ne [char]32) { throw 'Invalid git status record. Refusing to report clean.' }
            $status = $record.Substring(0, 2)
            $path = $record.Substring(3)
            $origin = $null
            if ($status[0] -cin @('R', 'C') -or $status[1] -cin @('R', 'C')) {
                $i++
                if ($i -ge $records.Count) { throw 'Missing git rename/copy origin. Refusing to report clean.' }
                $origin = $records[$i]
            }
            if ($ignoredOnly -and $status -cne '!!') { continue }
            if ($null -ne $origin) { $set[$origin] = 'R-' }
            $set[$path] = $status
        }
    }
    return $set
}

# Hash CONTENT, not just the path.
#
# Knowing only which paths were dirty cannot answer the question the check asks -- did the coder
# write to this file? -- so host work the coder never opened was reported as a violation, and every
# wave-2 dispatch with an uncommitted wave 1 cried wolf. A guard that cries wolf is one you learn to
# wave through, and the next real violation ships.
#
# A DIRECTORY is hashed by its recursive contents. git COLLAPSES an untracked directory into one
# porcelain entry (`?? scratch/`); treating that as unhashable meant a coder could write ANY file
# under an untracked directory and be ignored entirely.
function Get-ContentHash([string]$relPath) {
    $full = [System.IO.Path]::Combine($repo, $relPath)

    if (Test-Path -LiteralPath $full -PathType Container) {
        # Fingerprint from each file's relative PATH + length + mtime, hashed IN-PROCESS. NEVER a git
        # subprocess per file: the old `git hash-object` per file spawned one process for EVERY file
        # under the entry, so an ignored node_modules / .venv / target (git status --ignored collapses
        # each to a single dir entry -- tens of thousands of files) spawned tens of thousands of git
        # processes and never returned, wedging every build dispatch before launch (session 9; reviews
        # skip the snapshot, which is why only -Phase build hung).
        #
        # Keeping the PATH is load-bearing: an aggregate of count+size+mtime alone misses a RENAME
        # inside the directory (all three unchanged). Path + length + mtime catch renames, adds,
        # deletes, and edits. Byte-identical with a deliberately preserved mtime is out of scope (a
        # careless coder, not a hostile one -- the gate's stated threat model).
        $parts = New-Object System.Collections.Generic.List[string]
        $skippedRuntimeMarkers = 0
        $enumErr = $null
        foreach ($file in (Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable enumErr |
                Sort-Object FullName)) {
            $rel = $file.FullName.Substring($repo.Length).TrimStart([char]92, [char]47) -replace '\\', '/'
            if ($applyRuntimeExclusions -and (Test-IsRuntimeMarker $rel)) {
                $skippedRuntimeMarkers++
                continue
            }
            $parts.Add("$rel|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)")
        }
        # A subtree we could not read must not fingerprint identically to one we could -- fold the
        # failure count in so a newly-unreadable subtree changes the hash rather than silently passing.
        if ($enumErr -and $enumErr.Count -gt 0) { $parts.Add("UNREADABLE|$($enumErr.Count)") }
        if ($parts.Count -eq 0 -and $skippedRuntimeMarkers -gt 0) { return 'dir:runtime-markers-only' }
        if ($parts.Count -eq 0) { return 'dir:empty' }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]::Join("`n", $parts))
            return 'dir:' + [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLower()
        } finally { $sha.Dispose() }
    }

    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return '-' }
    # A present file is not the legitimate absent-file '-' sentinel. Invoke-Git fails closed on
    # launch/exit errors, and an empty successful hash is still ambiguous, so refuse it too.
    $h = Invoke-Git hash-object '--' $relPath
    if (-not $h) { throw "git hash-object returned no hash for present file '$(ConvertTo-DisplayPath $relPath)'. Refusing to report it absent." }
    return ([string]$h).Trim()
}

# The INDEX is what a commit is built from. A staged blob can differ from the working file (`MM`),
# so a check that only looks at the working tree misses an unauthorized change that is already
# staged -- and `git add` is exactly what a coder does before it thinks it is done.
function Get-IndexHash([string]$relPath) {
    # Empty output with a successful ls-files call legitimately means the path is not in the index;
    # Invoke-Git now throws on launch/exit failure instead of collapsing either error to this '-'.
    $entry = Invoke-Git ls-files -s '--' $relPath
    if (-not $entry) { return '-' }
    $fields = ([string]$entry).Split(@(' ', "`t"), [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($fields.Count -ge 2) { return "$($fields[0]):$($fields[1])" }   # mode:sha -- a chmod is a change too
    return '-'
}

function Get-PathState([string]$relPath, [string]$Status) {
    if ($Status -ceq '??') {
        $full = [System.IO.Path]::Combine($repo, $relPath)
        # Nested repositories can remain ?? containers even with -uall. Keep their recursive
        # metadata digest; neither a container nor an untracked leaf has an index entry.
        if ($relPath.EndsWith('/', [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $full -PathType Container)) {
            return "work:$(Get-ContentHash $relPath) index:-"
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return 'work:- index:-' }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $stream = $null
        try {
            $stream = New-Object IO.FileStream($full, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $hex = [System.BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
            return "work:raw:$hex index:-"
        } finally {
            if ($stream) { $stream.Dispose() }
            $sha.Dispose()
        }
    }
    return "work:$(Get-ContentHash $relPath) index:$(Get-IndexHash $relPath)"
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

# The snapshot lives OUTSIDE the worktree.
#
# It used to sit in `docs/progress/`, inside the repo -- which meant the check had to exempt its own
# state directory from its own scan, and that exemption then became a hole: an untracked `docs/`
# collapses to a single `?? docs/` entry, and exempting it exempted EVERYTHING under docs/, so a
# coder could write docs/rogue.md unseen. Every attempt to write the exemption more precisely just
# moved the hole around.
#
# So don't create the problem: keep transient state out of the tree being examined, and the check has
# nothing of its own to make an excuse for. (Removal over prohibition -- APEX's own rule, applied to
# APEX.) Keyed by worktree so parallel worktrees never share a snapshot.
if (-not $StateDirectory) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $keyBytes = [System.Text.Encoding]::UTF8.GetBytes(($repo -replace '\\', '/').TrimEnd('/').ToLowerInvariant())
        $repoTag = [System.BitConverter]::ToString($sha.ComputeHash($keyBytes)).Replace('-', '').Substring(0, 10).ToLower()
    } finally { $sha.Dispose() }
    $StateDirectory = Join-Path $env:TEMP "apex-scope-$repoTag"
}
if (-not (Test-Path $StateDirectory)) { New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null }
$snapPath = Join-Path $StateDirectory "scope-$Task.snapshot.json"
if ($WrittenPathsFile -and
        [string]::Equals([System.IO.Path]::GetFullPath($WrittenPathsFile),
            [System.IO.Path]::GetFullPath($snapPath), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "-WrittenPathsFile must not resolve to the snapshot path: $(ConvertTo-DisplayPath $WrittenPathsFile -FileSystem)"
}

# --------------------------------------------------------------------------- ENCODING SCAN
# Codex-on-Windows double-encodes non-ASCII it writes into source: an em-dash goes in as U+2014 and
# comes out as mojibake (UTF-8 read as CP1252, then re-encoded as UTF-8).
#
# WHY A MACHINE HAS TO DO THIS: **the test suite cannot catch it, by construction.** The coder writes
# the SAME corrupted bytes into the expected string as into the source, so the assertion compares
# corrupt to corrupt and passes. A fully green suite is exactly what this bug looks like. It bit
# twice on 2026-07-10 alone (ask-presence-alias, then fix-build-stream-transport) and both times the
# tests were green. Greppable in a second; invisible to every gate we had.
#
# NO AUTHORSHIP INFERENCE. This reports "there is double-encoded text in this tree", not "the coder
# wrote it" -- the same discipline that made the scope check stop reverting. Timing lies; the host
# reads the paths and decides.
#
# NO OVERRIDE SWITCH. Every exemption written into this harness became a hole someone walked through.
# A hit is a hit; even a false positive contains a mojibake signature worth inspecting.
if ($EncodingScan) {
    # --- THE DETECTOR, derived from the encoding rather than from the one example we had ----------
    # Mojibake = UTF-8 bytes decoded as CP1252/Latin-1, then re-encoded as UTF-8. Read the byte
    # structure and the signature falls out:
    #
    #   * a 2-byte UTF-8 sequence has lead 0xC2-0xDF -> Latin-1 UPPERCASE (U+00C2 A-circumflex ..
    #     U+00DF sharp-s), followed by EXACTLY ONE continuation byte (0x80-0xBF).
    #     e-acute (C3 A9) double-encodes to A-tilde + copyright.
    #   * a 3- or 4-byte sequence has lead 0xE0-0xF4 -> Latin-1 LOWERCASE (U+00E0 .. U+00F4),
    #     followed by TWO or THREE continuation bytes.
    #     em-dash (E2 80 94) double-encodes to a-circumflex + euro + right-double-quote.
    #     CJK, Cyrillic and emoji all live here.
    #
    # The first cut listed only U+00C2/C3/E2 as leads -- the 2-byte leads plus the one lead from the
    # em-dash in the bug report. It therefore MISSED double-encoded Cyrillic, CJK and emoji: a
    # mojibake detector that misses most mojibake, because it was written from a single example
    # instead of from the encoding.
    #
    # WHY THE CONTINUATION COUNT IS NOT UNIFORM. Widening the leads to the whole range re-introduces
    # a false positive: a LEGITIMATE lowercase e-acute followed by a non-breaking space (U+00E9 U+00A0)
    # looks like lead+continuation. But a real 3-byte double-encode ALWAYS emits two continuations.
    # So: uppercase lead + 1 continuation, lowercase lead + 2. That distinction is not a heuristic --
    # it is the byte structure of UTF-8, and it makes accented prose safe while catching CJK.
    #
    # BUILT FROM CODE POINTS, NOT LITERALS, ON PURPOSE. Windows PowerShell 5.1 decodes a BOM-less
    # .ps1 as ANSI, so a literal character class here would itself be re-decoded -- a mojibake
    # detector corrupted by mojibake. ASCII-only source cannot be misread.
    $lead2 = -join (@(0x00C2..0x00DF) | ForEach-Object { [char]$_ })   # 2-byte leads (uppercase)
    $lead3 = -join (@(0x00E0..0x00F4) | ForEach-Object { [char]$_ })   # 3/4-byte leads (lowercase)

    # CP1252's mapping of continuation bytes 0x80-0xBF. Bytes 0x80-0x9F map to punctuation (euro,
    # smart quotes, dashes); 0xA0-0xBF map to themselves in Latin-1. Unmapped CP1252 bytes decode to
    # the raw C1 controls, which the 0x0080-0x009F range already covers.
    $tailCodes = @(0x0080..0x00BF) + @(
        0x20AC, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039,
        0x0152, 0x017D, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122,
        0x0161, 0x203A, 0x0153, 0x017E, 0x0178
    )
    $tail = -join ($tailCodes | ForEach-Object { [char]$_ })

    $T  = '[' + $tail + ']'
    $L2 = '[' + $lead2 + ']'
    $L3 = '[' + $lead3 + ']'
    $mojibake = "(?:$L2$T)|(?:$L3$T$T)"

    # --- WHAT GETS SCANNED ------------------------------------------------------------------------
    # The first cut scanned every dirty file and produced 180 hits on a real tree, ALL noise:
    #   * docs/progress/*.log -- the WRAPPER'S OWN Codex transcripts, which contain mojibake because
    #     they faithfully RECORD it. The harness writing into a tree it then judges, all over again.
    #   * prose ABOUT this bug -- handoffs, memories, this script's own comments and SKILL.md's exit
    #     table all quote the corrupt sequence as the EXAMPLE. The gate flagged its own documentation,
    #     so a dispatch authorized to edit the harness could never come back clean.
    #
    # A gate that fires on every run gets switched off, and then it protects nothing. So: PRECISION,
    # never an override switch -- every exemption in this harness became a hole someone walked through.
    #
    # PROSE IS EXCLUDED BY EXTENSION. That is a real, stated limit, not a dodge: the failure this gate
    # exists for -- a green suite that proves nothing, because the coder wrote the same corrupt bytes
    # into the EXPECTED string as into the source -- is a CODE failure. Mojibake in a .md is cosmetic
    # and a human reading the diff will see it. Mojibake in a string literal is invisible and ships.
    $proseExtensions = '\.(md|markdown|txt|rst|adoc)$'

    # ROOT-ANCHORED. The first cut used (^|/)docs/progress/, which also excluded a legitimate source
    # path like src/docs/progress/parser.ps1, and excluded every .lock and .map file -- hiding real
    # corruption in them. Exclude the harness's own artifacts, and nothing else.
    $artifactPattern = '^(\.git|node_modules)/|^docs/progress/|\.(log|jsonl)$'

    $dirty = Get-DirtySet

    # Authorized entries may be DIRECTORIES (scope authorization supports them), and git collapses a
    # new untracked directory to "?? dir/". The first cut treated every entry as a leaf and silently
    # skipped both -- so corruption anywhere under an authorized or newly-created directory sailed
    # through and exited 0. Expand a directory to the files beneath it.
    $script:expandFailures = @()
    function Expand-ScanPath([string]$rel) {
        $full = Join-Path $repo $rel
        if (Test-Path -LiteralPath $full -PathType Leaf) { return @($rel) }
        if (Test-Path -LiteralPath $full -PathType Container) {
            # -ErrorAction SilentlyContinue would swallow an inaccessible SUBTREE: those files simply
            # never enter the scan set, nothing reaches the unreadable handler, and the gate exits 0
            # having never looked at them. That is the fail-open class this gate exists to not be.
            # Collect the enumeration errors instead and fail on them.
            $enumErrors = @()
            $kids = Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable enumErrors
            foreach ($e in $enumErrors) { $script:expandFailures += ("$rel -> " + $e.Exception.Message) }
            return @($kids | ForEach-Object {
                Normalize ($_.FullName.Substring($repo.Length).TrimStart([char]92, [char]47))
            })
        }
        # NOT an error, and deliberately so. -Authorized is the spec's '## Files to change' list, and
        # AGENTS.md tells the coder outright: "file in spec BUT you don't need to touch it -> skip it".
        # An authorized file that was never created is the NORMAL case on most dispatches. Failing here
        # would fire the gate on nearly every run -- and a gate that fires every run gets switched off,
        # which is how we lose it. Absence is silent; unreadability (above) is fatal.
        return @()
    }

    $candidates = @()
    if ($Authorized.Count -gt 0) {
        foreach ($a in $Authorized) {
            foreach ($piece in ($a -split ',')) {
                $q = Normalize ($piece.Trim().Trim([char]39).Trim([char]34))
                if ($q) { $candidates += $q }
            }
        }
    }
    else {
        $candidates = @($dirty.Keys | Where-Object { $dirty[$_] -ne 'R-' -and $dirty[$_] -notmatch 'D' })
    }

    $scanSet = @()
    foreach ($c in ($candidates | Select-Object -Unique)) { $scanSet += (Expand-ScanPath $c) }
    $scanSet = @($scanSet | Select-Object -Unique |
        Where-Object { $_ -and $_ -notmatch $artifactPattern -and $_ -notmatch $proseExtensions })

    # --- SCAN. Anything it cannot verify is a FAILURE, never a silent skip -------------------------
    # The first cut swallowed a read error with `continue` and then reported "clean". A gate that
    # silently skips is worse than no gate: it reads as a pass.
    $hits = @()
    $unreadable = @()
    foreach ($rel in $scanSet) {
        $full = Join-Path $repo $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }

        try { $bytes = [System.IO.File]::ReadAllBytes($full) }
        catch { $unreadable += $rel; continue }

        # UTF-16 IS VALID SOURCE, especially on Windows (PowerShell has shipped UTF-16LE .ps1 files for
        # years). The NUL-byte heuristic below would classify every one of them as binary and skip it
        # wholesale -- reporting clean on a file it never read. Decode by BOM first, so UTF-16 text is
        # scanned as text rather than silently dropped.
        $text = $null
        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
        }
        elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
        }
        else {
            # A NUL byte in the first 8k is git's own binary heuristic. Genuine binaries are not scanned:
            # decoded as UTF-8 they yield arbitrary chars that can match by accident.
            $probe = [Math]::Min($bytes.Length, 8192)
            $isBinary = $false
            for ($k = 0; $k -lt $probe; $k++) { if ($bytes[$k] -eq 0) { $isBinary = $true; break } }
            if ($isBinary) { continue }
            $text = [System.Text.UTF8Encoding]::new($false).GetString($bytes)
        }
        $fileLines = $text -split "`r?`n"
        for ($i = 0; $i -lt $fileLines.Count; $i++) {
            # -cmatch, NOT -match. PowerShell's -match is CASE-INSENSITIVE by default, and this whole
            # rule rests on the uppercase/lowercase lead distinction: 2-byte leads land on Latin-1
            # UPPERCASE (one continuation), 3-byte leads on LOWERCASE (two). Case-insensitively, a
            # legitimate lowercase e-acute (U+00E9) folds to U+00C9 -- inside the uppercase lead range --
            # so `cafe-acute + non-breaking space` matched the 2-byte rule and reported clean prose as
            # corrupt. The distinction the detector is built on only exists under a case-SENSITIVE match.
            if ($fileLines[$i] -cmatch $mojibake) {
                $hits += [pscustomobject]@{ Path = $rel; Line = $i + 1; Text = $fileLines[$i].Trim() }
            }
        }
    }

    # Everything the gate could not READ -- an unreadable file, or a directory subtree it could not
    # enumerate -- is a hard failure, never a silent skip. A gate that quietly does not look at
    # something and then says "clean" is worse than no gate: it reads as a pass.
    $cannotVerify = @($unreadable) + @($script:expandFailures)
    if ($cannotVerify.Count -gt 0) {
        Write-Host ""
        Write-Host "[encoding] CANNOT VERIFY $($cannotVerify.Count) path(s):" -ForegroundColor Red
        foreach ($u in $cannotVerify) { Write-Host "      $(ConvertTo-DisplayPath $u)" -ForegroundColor Red }
        Write-Host "[encoding] A gate that cannot read a path must not report it clean." -ForegroundColor Red
        exit 73
    }

    if ($hits.Count -eq 0) {
        Write-Host "[encoding] clean: no double-encoded text in $($scanSet.Count) scanned path(s)."
        exit 0
    }

    Write-Host ""
    Write-Host "[encoding] MOJIBAKE - $($hits.Count) line(s) carry double-encoded text:" -ForegroundColor Red
    foreach ($h in ($hits | Select-Object -First 40)) {
        Write-Host ("      {0}:{1}  {2}" -f (ConvertTo-DisplayPath $h.Path), $h.Line, $h.Text) -ForegroundColor Red
    }
    if ($hits.Count -gt 40) { Write-Host "      ... and $($hits.Count - 40) more" -ForegroundColor Red }
    Write-Host ""
    Write-Host "[encoding] The tests do NOT catch this: the same corrupted bytes go into the expected" -ForegroundColor Yellow
    Write-Host "[encoding] string, so a green suite proves nothing. Fix the bytes, then re-verify." -ForegroundColor Yellow
    Write-Host ""
    exit 73
}

$resolvedRuntimeExclusionRoot = $null
if (Test-Path -LiteralPath $RuntimeExclusionRoot -PathType Container) {
    $resolvedRuntimeExclusionRoot = (Resolve-Path -LiteralPath $RuntimeExclusionRoot).Path.TrimEnd('\', '/')
}
$applyRuntimeExclusions = ($null -ne $resolvedRuntimeExclusionRoot -and
    [string]::Equals($repo.TrimEnd('\', '/'), $resolvedRuntimeExclusionRoot, [System.StringComparison]::OrdinalIgnoreCase))

# Lockstep: identical in tree-pin.ps1 and codex-scope-check.ps1.
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

# ---------------------------------------------------------------------------------- SNAPSHOT
if ($Snapshot) {
    $dirty = Get-DirtySet
    $states = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    $statuses = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $dirty.Keys) {
        $states[$p] = Get-PathState $p ([string]$dirty[$p])
        $statuses[$p] = [string]$dirty[$p]
    }

    $state = [ordered]@{
        format   = 2
        task     = $Task
        head     = (Invoke-Git rev-parse HEAD)
        dirty    = @($dirty.Keys)
        states   = $states
        statuses = $statuses
        takenUtc = (Invoke-Git log -1 --format=%cI)   # no Get-Date: keep it git-sourced
    }
    [System.IO.File]::WriteAllText($snapPath, ($state | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
    Write-Host "[scope] snapshot for '$Task': HEAD=$($state.head.Substring(0,7)), $($dirty.Count) path(s) already dirty (host work)."

    # --- RE-DISPATCH HAZARD ---------------------------------------------------------------------
    # If a file this task is AUTHORIZED to write is ALREADY dirty, the task's own work may already be
    # in the tree from a previous dispatch that appeared to fail but wasn't a no-op. The coder then
    # cannot run its load-bearing test RED before the fix, because the fix is already there. It can
    # only verify what it finds. That is a rubber-stamp, not a build -- and a coder less honest than
    # the one that reported it would simply say "done".
    #
    # Live: cap-deps-1a, 2026-07-14 -- "The complete scoped implementation and test file were already
    # present as uncommitted changes at initial inspection. Consequently, the load-bearing test could
    # not be run red against the then-current worktree before the fix."
    if ($Authorized.Count -gt 0) {
        $preAuth = @()
        foreach ($a in $Authorized) {
            foreach ($piece in ($a -split ',')) {
                $p = Normalize ($piece.Trim().Trim("'").Trim('"'))
                if (-not $p) { continue }
                foreach ($k in $dirty.Keys) { if ([string]::Equals((Normalize-GitPath $k), $p, [StringComparison]::OrdinalIgnoreCase)) { $preAuth += $p } }
            }
        }
        if ($preAuth.Count -gt 0) {
            Write-Host ""
            Write-Host "[scope] RE-DISPATCH HAZARD - $($preAuth.Count) file(s) this task may write are ALREADY dirty:" -ForegroundColor Yellow
            foreach ($p in ($preAuth | Select-Object -Unique)) { Write-Host "      $(ConvertTo-DisplayPath $p)" }
            Write-Host "[scope] The task's work may already be in the tree from an earlier dispatch that only LOOKED" -ForegroundColor Yellow
            Write-Host "[scope] like it failed. The coder cannot run its test RED against a tree that already contains" -ForegroundColor Yellow
            Write-Host "[scope] the fix - it can only verify what it finds. Reset these paths to the base SHA before" -ForegroundColor Yellow
            Write-Host "[scope] re-dispatching, or accept that this run VERIFIES rather than BUILDS - and say so." -ForegroundColor Yellow
            Write-Host ""
        }
    }
    exit 0
}

# ------------------------------------------------------------------------------------- CHECK
if (-not $Check) { throw "Specify -Snapshot or -Check." }
if (-not (Test-Path $snapPath)) {
    throw "No snapshot for task '$Task'. Run -Snapshot BEFORE dispatching, or the check cannot tell the coder's writes from the host's."
}

$snap = Get-Content $snapPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not ($snap.PSObject.Properties.Name -ccontains 'format') -or
        -not ($snap.format -is [int] -or $snap.format -is [long]) -or $snap.format -cne 2) {
    throw "snapshot for '$Task' predates scope snapshot format 2 (leaf enumeration); re-run -Snapshot"
}

$preState = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
if ($snap.PSObject.Properties.Name -contains 'states' -and $snap.states) {
    foreach ($prop in $snap.states.PSObject.Properties) { $preState[(Normalize-GitPath $prop.Name)] = [string]$prop.Value }
}
$preDirty = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
foreach ($p in @($snap.dirty)) { $preDirty[(Normalize-GitPath $p)] = $true }
$preStatus = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
if ($snap.PSObject.Properties.Name -contains 'statuses' -and $snap.statuses) {
    foreach ($prop in $snap.statuses.PSObject.Properties) { $preStatus[(Normalize-GitPath $prop.Name)] = [string]$prop.Value }
}

# Split on commas as well as array elements: a caller invoking this from bash passes
# -Authorized 'a.py','b.py' as ONE string "a.py,b.py", which then matches nothing -- and every
# authorized file reads as a violation.
$allowed = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
foreach ($a in $Authorized) {
    foreach ($piece in ($a -split ',')) {
        $p = Normalize ($piece.Trim().Trim("'").Trim('"'))
        if ($p) { $allowed[$p] = $true }
    }
}

$nowDirty = Get-DirtySet
$nowByNorm = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
foreach ($p in $nowDirty.Keys) {
    $nowByNorm[(Normalize-GitPath $p)] = [pscustomobject]@{ Path = [string]$p; Status = [string]$nowDirty[$p] }
}
$violations = @()   # the coder wrote these, and they are not authorized
$untouched = @()    # dirty before the dispatch AND byte-identical since: not the coder's

# This script's own state lives under $StateDirectory and shows up as untracked. Compare by PATH
# SEGMENT, never by raw string prefix: a prefix match on "docs/progress" also swallows
# "docs/progress-evil.md", which is a hole a coder could drive an unauthorized file through.
$stateRel = ''
$stateFull = (Resolve-Path $StateDirectory).Path
if ($stateFull.StartsWith($repo, [StringComparison]::OrdinalIgnoreCase)) {
    # Trim the leading separator EXPLICITLY. Slicing the repo prefix off leaves "\docs\progress",
    # and the old Normalize happened to strip that leading slash only because `TrimStart('./')`
    # strips every leading '.' and '/' CHARACTER -- the same sloppiness that made `.env` normalize
    # to `env`. Fixing that bug exposed this accidental dependency on it: the state dir stopped
    # matching itself, and the check flagged its own snapshot file as an out-of-scope write.
    $stateRel = Normalize ($stateFull.Substring($repo.Length).TrimStart('\', '/'))
}

# There is no state-path exemption, because there is no state in the tree to exempt. The snapshot
# now lives in TEMP (see above). The exemption that used to be here was a raw prefix match --
# `docs/progress-evil.md` slipped through it, and an untracked `docs/` collapsed to one entry made it
# exempt the entire directory. An excuse the guard has to make for itself is an excuse a coder can
# use too.
function Test-IsStatePath([string]$n) { return $false }

# An authorized DIRECTORY authorizes its descendants. Exact-match-only meant `-Authorized @('src')`
# flagged the coder's legitimate edit of `src/a.py` as out of scope -- and a guard that cries wolf on
# correct behaviour is one people route around.
# Case-INSENSITIVE, because Windows paths are. A case-sensitive compare meant `-Authorized SRC`
# authorized nothing under `src/`, and a coder's perfectly legitimate edit to src/a.py was reported
# out of scope -- the guard failing the build for doing exactly what it was told to do.
function Test-IsAuthorized([string]$n) {
    foreach ($a in $allowed.Keys) {
        if ([string]::Equals($n, $a, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($n.StartsWith($a + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# Examine the UNION of "dirty now" and "dirty at snapshot". A path that VANISHES is invisible to a
# now-only scan: the coder deleting a host's untracked draft, or restoring a host-modified file back
# to HEAD, removes it from `git status` entirely -- so the old loop saw nothing and exited 0 while
# host work was destroyed. Absence is a change too.
$allPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($p in $nowByNorm.Keys) { [void]$allPaths.Add($p) }
foreach ($p in $preDirty.Keys) { [void]$allPaths.Add($p) }

# Lockstep coupling: mirrors tree-pin.ps1 $runtimeExclusions plus its match/root gate. Unlike
# tree-pin's `!!` status-class gate, this side discriminates on ref presence (index OR HEAD via
# Test-IsHostCurated), so host-curated runtime files (including committed files the coder deletes or
# renames) stay checked while fixture ?? runtime files are excluded. Both files must stay in sync.
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
function Test-IsRuntimePath([string]$NormalizedPath) {
    foreach ($prefix in $runtimeExclusions) {
        if ([string]::Equals($NormalizedPath, $prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
                $NormalizedPath.StartsWith($prefix + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Test-IsRuntimeMarkerFile([string]$n) {
    if (-not (Test-IsRuntimeMarker $n)) { return $false }

    $full = [System.IO.Path]::Combine($repo, $n)
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        if ($nowByNorm.ContainsKey($n)) {
            $rawNowPath = ([string]$nowByNorm[$n].Path) -replace '\\', '/'
            if ($rawNowPath.EndsWith('/', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        return $true
    }

    if (Test-Path -LiteralPath $full) { return $false }
    foreach ($d in @($snap.dirty)) {
        $rawSnapshotPath = ([string]$d) -replace '\\', '/'
        if ([string]::Equals((Normalize-GitPath $d), $n, [StringComparison]::OrdinalIgnoreCase) -and -not $rawSnapshotPath.EndsWith('/', [StringComparison]::OrdinalIgnoreCase) -and
                $preState.ContainsKey($n) -and ([string]$preState[$n]) -match '^work:(?:raw:)?[0-9a-f]+ index:') {
            return $true
        }
    }
    return $false
}

function Test-IsMarkerOnlyTransition([string]$n) {
    if (-not ([string]::Equals($n, 'skills', [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($n, 'skills/synced', [System.StringComparison]::OrdinalIgnoreCase) -or
            $n.StartsWith('skills/synced/', [System.StringComparison]::OrdinalIgnoreCase))) {
        return $false
    }

    $currentState = Get-ContentHash $n
    if ($currentState -ne '-' -and $currentState -ne 'dir:runtime-markers-only') { return $false }
    if (-not $preState.ContainsKey($n)) { return $true }

    $snapshotState = [string]$preState[$n]
    return ($snapshotState.StartsWith('work:dir:runtime-markers-only ', [System.StringComparison]::Ordinal) -or
        $snapshotState.StartsWith('work:- ', [System.StringComparison]::Ordinal))
}

# Three-way name state:
#   SANCTIONED: .codex-scratch is the only scratch directory name a coder may create.
#   DEPRECATED-BUT-EXCLUDED: .scratch, .apex-tmp, and .sandbox-cache remain excluded only to reduce
#   noise in existing repos; do not use them for new work, and a future revision may stop excluding them.
#   TOOL CACHES: .pytest_cache, .mypy_cache, and .ruff_cache are shared at tree-pin.ps1 parity.
# Everything else flags, including invented prefixes and task-suffixed variants.
$derivedCacheExclusions = @(
    '.codex-scratch',
    '.scratch',
    '.apex-tmp',
    '.sandbox-cache',
    '.pytest_cache',
    '.mypy_cache',
    '.ruff_cache'
)
# These tree-pin.ps1 entries are deliberately NOT shared with scope-check's exact exclusion list.
$derivedCacheDivergence = @('.venv', 'node_modules/.cache', '__pycache__', '.coverage')
function Test-IsDerivedCachePath([string]$NormalizedPath) {
    foreach ($prefix in $derivedCacheExclusions) {
        if ([string]::Equals($NormalizedPath, $prefix, [System.StringComparison]::OrdinalIgnoreCase) -or
                $NormalizedPath.StartsWith($prefix + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

$applyDerivedCacheExclusions = $true
$applyDeclaredBuildOutputExclusions = $true

function Test-IsIgnoredUntrackedTransition([string]$n) {
    $wasPresentAtSnapshot = $preDirty.ContainsKey($n)
    $isPresentNow = $nowByNorm.ContainsKey($n)
    $ignoredNow = $isPresentNow -and $nowByNorm[$n].Status -ceq '!!'
    return ((-not $wasPresentAtSnapshot -and $ignoredNow) -or
        ($wasPresentAtSnapshot -and $preStatus.ContainsKey($n) -and $preStatus[$n] -ceq '!!' -and
            ($ignoredNow -or -not $isPresentNow)))
}

$curatedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$curatedDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
function Test-IsHostCurated([string]$n) {
    return $curatedFiles.Contains($n) -or $curatedDirs.Contains($n)
}

try {
    $indexInventory = [string]::Join("`0", [string[]]@(Invoke-Git -NulRecords ls-files -z))
    $headInventory = [string]::Join("`0", [string[]]@(Invoke-Git -NulRecords ls-tree -r --name-only -z HEAD))
    foreach ($inventory in @($indexInventory, $headInventory)) {
        foreach ($entry in ($inventory -split "`0")) {
            if ($entry.Length -eq 0) { continue }
            $curatedPath = Normalize-GitPath $entry
            if (-not $curatedPath) { continue }
            [void]$curatedFiles.Add($curatedPath)

            $segments = @($curatedPath -split '/')
            for ($i = 1; $i -lt $segments.Count; $i++) {
                [void]$curatedDirs.Add([string]::Join('/', [string[]]$segments[0..($i - 1)]))
            }
        }
    }
} catch {
    $applyRuntimeExclusions = $false
    $applyDerivedCacheExclusions = $false
    Write-Host "[scope] WARNING: runtime inventory could not be built, so nothing was excluded." -ForegroundColor Yellow
}

# Fetch through this script's fail-closed adapter, outside the shared pure-function block. A
# failed lookup is not an absent file; disable only this class and keep all other checks running.
$declaredBuildOutputs = @()
try {
    $agentsAtHead = @(Invoke-Git -NulRecords ls-tree --full-tree --name-only -z $snap.head '--' AGENTS.md)
    if (@($agentsAtHead | Where-Object { [string]::Equals($_, 'AGENTS.md', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        $agentsText = [string]::Join("`n", [string[]]@(Invoke-Git show "$($snap.head):AGENTS.md"))
        $declaration = ConvertFrom-BuildOutputsSection -Text $agentsText
        $declaredBuildOutputs = @($declaration.Entries)
        if ($declaration.Warning) { Write-Host "[scope] WARNING: $($declaration.Warning)" -ForegroundColor Yellow }
    }
} catch {
    $applyDeclaredBuildOutputExclusions = $false
    Write-Host "[scope] WARNING: AGENTS.md build-output declarations unavailable ($($_.Exception.Message)); declared class disabled" -ForegroundColor Yellow
}

$collectWritten = [bool]$WrittenPathsFile
$writtenSet = $null
$runtimeExcludedCount = 0
$derivedCacheExcludedCount = 0
$declaredBuildOutputExcludedCount = 0
if ($collectWritten) {
    # Lockstep sibling: the non-collecting branch differs only by omitting writtenSet accumulation;
    # keep its GONE/untouched/isDirty classification line-for-line identical to this branch.
    $writtenSet = New-Object System.Collections.Generic.List[string]
    foreach ($n in $allPaths) {
        if ($applyRuntimeExclusions -and -not (Test-IsHostCurated $n) -and ((Test-IsRuntimePath $n) -or (Test-IsRuntimeMarkerFile $n) -or (Test-IsMarkerOnlyTransition $n))) {
            $runtimeExcludedCount++
            continue
        }
        if ($applyDerivedCacheExclusions -and -not (Test-IsHostCurated $n) -and (Test-IsIgnoredUntrackedTransition $n)) {
            if (Test-IsDerivedCachePath $n) {
                $derivedCacheExcludedCount++
                continue
            }
            if ($applyDeclaredBuildOutputExclusions -and (Test-IsDeclaredBuildOutputPath -Path $n -Entries $declaredBuildOutputs)) {
                $declaredBuildOutputExcludedCount++
                continue
            }
        }
        if (Test-IsAuthorized $n) {
            $wasDirty = $preDirty.ContainsKey($n)
            $isDirty = $nowByNorm.ContainsKey($n)

            if ($wasDirty -and -not $isDirty) {
                [void]$writtenSet.Add($n)
            } elseif ($isDirty -and -not ($preDirty.ContainsKey($n) -and $preState.ContainsKey($n) -and
                    (Get-PathState $n $nowByNorm[$n].Status) -ceq $preState[$n])) {
                [void]$writtenSet.Add($n)
            }
            continue
        }
        if (Test-IsStatePath $n) { continue }

        $wasDirty = $preDirty.ContainsKey($n)
        $isDirty = $nowByNorm.ContainsKey($n)
        $statusNow = '??'
        if ($isDirty) { $statusNow = $nowByNorm[$n].Status }

        if ($wasDirty -and -not $isDirty) {
            # It was dirty before the dispatch and is not dirty now: something reverted or deleted host
            # work. USUALLY the coder -- and silent destruction is the worst kind of out-of-scope write,
            # so it is reported. But the HOST tidying up its own draft mid-dispatch produces exactly the
            # same signature, and this script cannot tell them apart (the same timing-attribution limit
            # that made auto-revert unsafe). So it is reported as GONE and named, for a human to judge --
            # never silently, and never acted on.
            $violations += [pscustomobject]@{ Path = $n; Status = 'GONE' }
            [void]$writtenSet.Add($n)
            continue
        }

        if ($wasDirty -and $preState.ContainsKey($n)) {
            if ((Get-PathState $n $statusNow) -ceq $preState[$n]) {
                # Byte-identical since the snapshot, working tree AND index. The coder was never in here:
                # it is host work (typically an uncommitted earlier wave, or docs/status.md).
                $untouched += $n
                continue
            }
        }

        if ($isDirty) {
            $violations += [pscustomobject]@{ Path = $n; Status = $statusNow }
            [void]$writtenSet.Add($n)
        }
    }
} else {
    # Lockstep sibling: the collecting branch differs only by writtenSet accumulation;
    # keep its GONE/untouched/isDirty classification line-for-line identical to this branch.
    foreach ($n in $allPaths) {
        if ($applyRuntimeExclusions -and -not (Test-IsHostCurated $n) -and ((Test-IsRuntimePath $n) -or (Test-IsRuntimeMarkerFile $n) -or (Test-IsMarkerOnlyTransition $n))) {
            $runtimeExcludedCount++
            continue
        }
        if ($applyDerivedCacheExclusions -and -not (Test-IsHostCurated $n) -and (Test-IsIgnoredUntrackedTransition $n)) {
            if (Test-IsDerivedCachePath $n) {
                $derivedCacheExcludedCount++
                continue
            }
            if ($applyDeclaredBuildOutputExclusions -and (Test-IsDeclaredBuildOutputPath -Path $n -Entries $declaredBuildOutputs)) {
                $declaredBuildOutputExcludedCount++
                continue
            }
        }
        if (Test-IsAuthorized $n) { continue }
        if (Test-IsStatePath $n) { continue }

        $wasDirty = $preDirty.ContainsKey($n)
        $isDirty = $nowByNorm.ContainsKey($n)
        $statusNow = '??'
        if ($isDirty) { $statusNow = $nowByNorm[$n].Status }

        if ($wasDirty -and -not $isDirty) {
            # It was dirty before the dispatch and is not dirty now: something reverted or deleted host
            # work. USUALLY the coder -- and silent destruction is the worst kind of out-of-scope write,
            # so it is reported. But the HOST tidying up its own draft mid-dispatch produces exactly the
            # same signature, and this script cannot tell them apart (the same timing-attribution limit
            # that made auto-revert unsafe). So it is reported as GONE and named, for a human to judge --
            # never silently, and never acted on.
            $violations += [pscustomobject]@{ Path = $n; Status = 'GONE' }
            continue
        }

        if ($wasDirty -and $preState.ContainsKey($n)) {
            if ((Get-PathState $n $statusNow) -ceq $preState[$n]) {
                # Byte-identical since the snapshot, working tree AND index. The coder was never in here:
                # it is host work (typically an uncommitted earlier wave, or docs/status.md).
                $untouched += $n
                continue
            }
        }

        if ($isDirty) { $violations += [pscustomobject]@{ Path = $n; Status = $statusNow } }
    }
}

if ($runtimeExcludedCount -gt 0) {
    Write-Host "[scope] $runtimeExcludedCount runtime path(s) excluded (session churn under runtime dirs; index/HEAD-tracked paths still checked)."
}
if ($derivedCacheExcludedCount -gt 0) {
    Write-Host "[scope] $derivedCacheExcludedCount derived-cache path(s) excluded (ignored + untracked + exact-list; every other ignored path is still checked)."
}
if ($declaredBuildOutputExcludedCount -gt 0) {
    Write-Host "[scope] $declaredBuildOutputExcludedCount declared build-output path(s) excluded (AGENTS.md '## Build outputs' at HEAD; ignored + untracked + declared; every other ignored path is still checked)."
}

if ($WrittenPathsFile) {
    $expandedWritten = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $writtenSet) {
        $full = [System.IO.Path]::Combine($repo, $entry)
        if (Test-Path -LiteralPath $full -PathType Container) {
            [void]$expandedWritten.Add($entry)
            foreach ($file in (Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable enumErr)) {
                $rel = $file.FullName.Substring($repo.Length).TrimStart([char]92, [char]47) -replace '\\', '/'
                [void]$expandedWritten.Add($rel)
            }
        } else {
            [void]$expandedWritten.Add($entry)
        }
    }
    # Keep the existing sort order, but deduplicate path identities ordinally.
    $writtenUnique = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sorted = @($expandedWritten | Sort-Object | Where-Object { $writtenUnique.Add($_) })
    try {
        [System.IO.File]::WriteAllLines($WrittenPathsFile, [string[]]$sorted, [System.Text.UTF8Encoding]::new($false))
    } catch {
        throw "Failed to write -WrittenPathsFile '$(ConvertTo-DisplayPath $WrittenPathsFile -FileSystem)': $($_.Exception.Message)"
    }
}

# The coder is instructed never to commit. If HEAD moved, it did -- and a commit is not something a
# report can walk back: it is IN the history, and the next spec builds on it. Printing a warning and
# exiting 0 (as this script used to) means the dispatcher returns success on a tree the coder
# rewrote the history of.
$headNow = Invoke-Git rev-parse HEAD
$headMoved = ($headNow -ne $snap.head)

function Show-Untouched {
    if ($untouched.Count -eq 0) { return }
    Write-Host "[scope] $($untouched.Count) unauthorized path(s) were already dirty and are byte-identical since the" -ForegroundColor DarkGray
    Write-Host "[scope] snapshot - host work, not the coder's. Ignored." -ForegroundColor DarkGray
}

if ($headMoved) {
    Write-Host ""
    Write-Host "[scope] VIOLATION: HEAD MOVED during '$Task' ($($snap.head.Substring(0,7)) -> $($headNow.Substring(0,7)))." -ForegroundColor Red
    Write-Host "[scope] The coder is instructed never to commit. It committed. Nothing here is auto-undone -" -ForegroundColor Red
    Write-Host "[scope] resolve it by hand before anything builds on this history." -ForegroundColor Red
}

if ($violations.Count -eq 0 -and -not $headMoved) {
    Write-Host "[scope] '$Task' clean - every path the coder changed is in the authorized set." -ForegroundColor Green
    Show-Untouched
    Remove-Item $snapPath -Force -ErrorAction SilentlyContinue
    exit 0
}

# --- MANGLED-ALLOWLIST GUARD ------------------------------------------------------------------
# A wrong -Authorized list does not merely fail to protect: it makes every real file the coder wrote
# read as a violation. The tell: a task that did real work always writes at least one file it WAS
# authorized to write. If it wrote several and not one is on the list, the LIST is wrong, not the
# coder. Say so distinctly, so nobody "fixes" the coder.
# Count hits with the SAME rule that grants authorization. Using exact-key matching here while
# Test-IsAuthorized honoured directories meant an authorized `src/a.py` under `-Authorized src` was
# correctly excluded from violations but did NOT count as a hit -- so the malformed-list guard fired
# and told the caller to fix a list that was perfectly valid. Two rules for one question, and they
# disagreed.
$authorizedHits = 0
foreach ($path in $nowDirty.Keys) { if (Test-IsAuthorized (Normalize-GitPath $path)) { $authorizedHits++ } }
if ($violations.Count -gt 1 -and $authorizedHits -eq 0 -and $allowed.Count -gt 0 -and -not $headMoved) {
    Write-Host ""
    Write-Host "[scope] THE AUTHORIZED LIST LOOKS WRONG, not the coder." -ForegroundColor Red
    Write-Host "[scope] The task wrote $($violations.Count) path(s) and NOT ONE is on the authorized list. A task that" -ForegroundColor Red
    Write-Host "[scope] did real work always touches at least one file it was allowed to touch -- so this is almost" -ForegroundColor Red
    Write-Host "[scope] certainly a malformed -Authorized (e.g. an array passed as one comma-joined string)." -ForegroundColor Red
    Write-Host ""
    Write-Host "[scope] Authorized ($($allowed.Count)):" -ForegroundColor Yellow
    foreach ($a in $allowed.Keys) { Write-Host "      $(ConvertTo-DisplayPath $a)" }
    Write-Host "[scope] Written ($($violations.Count)):" -ForegroundColor Yellow
    foreach ($v in $violations) { Write-Host ("      {0}  {1}" -f $v.Status, (ConvertTo-DisplayPath $v.Path)) }
    Show-Untouched
    exit 66
}

Write-Host ""
Write-Host "[scope] OUT OF SCOPE - '$Task' wrote $($violations.Count) path(s) outside its authorized set:" -ForegroundColor Red
foreach ($v in $violations) { Write-Host ("    {0}  {1}" -f $v.Status, (ConvertTo-DisplayPath $v.Path)) -ForegroundColor Red }
Write-Host ""
Write-Host "[scope] NOTHING WAS TOUCHED. These changes are still in the tree, exactly as the coder left them." -ForegroundColor Yellow
Write-Host "[scope] This script does not revert: it inferred authorship from timing, and timing lies whenever" -ForegroundColor Yellow
Write-Host "[scope] anything else is writing (a sibling coder, a background agent, your own editor). Guessing" -ForegroundColor Yellow
Write-Host "[scope] wrong used to DELETE work that could not be recovered. Look at the list and decide." -ForegroundColor Yellow
Write-Host ""
Write-Host "[scope] Usually this is a SPEC DEFECT: the task needed a file its spec did not list. Surface it to" -ForegroundColor Yellow
Write-Host "[scope] planning - do not just re-run." -ForegroundColor Yellow
Show-Untouched
Remove-Item $snapPath -Force -ErrorAction SilentlyContinue
exit 1
