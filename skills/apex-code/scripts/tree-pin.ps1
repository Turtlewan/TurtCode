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
    [Parameter(Mandatory)][string]$Worktree,
    # Extra trees pinned/verified in the SAME gate (an APEX change spans ~/apex and ~/.claude).
    [string[]]$PinAlso = @(),
    [Parameter(Mandatory)][string]$Label,
    [string]$PinDirectory = $env:TEMP
)

$ErrorActionPreference = 'Stop'

if ($Pin -eq $Verify) {
    throw 'Pass exactly one of -Pin or -Verify.'
}
foreach ($root in (@($Worktree) + $PinAlso)) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Worktree does not exist: $root"
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
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs
    )
    # Fail closed if git cannot launch or reports an error. Checking $LASTEXITCODE without first
    # resetting it leaves a stale 0 in Windows PowerShell 5.1 after a launch failure, which made an
    # empty fingerprint look valid and allowed Verify to pass without inspecting a repository.
    $exitCodeSentinel = [int]::MinValue
    $previous = $ErrorActionPreference
    # Keep native stderr non-terminating so an exit-0 warning is not mistaken for a git failure;
    # the sentinel catches non-terminating launch failures and the catch handles terminating ones.
    $ErrorActionPreference = 'Continue'
    # Native processes update the global automatic variable in Windows PowerShell 5.1; assigning
    # an unqualified name here would create a function-local value that stays at the sentinel.
    $global:LASTEXITCODE = $exitCodeSentinel
    try {
        $output = @(& git -C $Root @GitArgs 2>$null)
        $exitCode = $global:LASTEXITCODE
    } catch {
        throw "git failed or could not launch in '$Root' ($([string]::Join(' ', $GitArgs))): $($_.Exception.Message)"
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -eq $exitCodeSentinel) {
        throw "git did not report an exit status in '$Root' ($([string]::Join(' ', $GitArgs)))."
    }
    if ($exitCode -ne 0) {
        throw "git exited with status $exitCode in '$Root' ($([string]::Join(' ', $GitArgs)))."
    }
    return $output
}

# A DIRECTORY is hashed by its recursive contents, never written off as unhashable.
#
# git COLLAPSES an untracked directory into one porcelain entry: `?? newdir/`. Returning a constant
# for it means the fingerprint is identical before and after a coder rewrites every file inside it --
# so Verify returns 0 and the gate blesses content the reviewer never saw. The pin then certifies
# precisely the blind spot it was built to eliminate.
function Get-PathDigest([string]$Root, [string]$relPath) {
    $full = Join-Path $Root $relPath

    if (Test-Path -LiteralPath $full -PathType Container) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($file in (Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue |
                Sort-Object FullName)) {
            $rel = $file.FullName.Substring((Resolve-Path $Root).Path.Length).TrimStart('\', '/') -replace '\\', '/'
            $h = Invoke-Git $Root hash-object -- $rel
            if (-not $h) { $h = "size:$($file.Length)" }
            $parts.Add("$rel $(([string]$h).Trim())")
        }
        if ($parts.Count -eq 0) { return 'dir:empty' }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]::Join("`n", $parts))
            return 'dir:' + [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLower()
        } finally { $sha.Dispose() }
    }

    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return '-' }
    $h = Invoke-Git $Root hash-object -- $relPath
    if (-not $h) { return '-' }
    return ([string]$h).Trim()
}

# The INDEX is part of the tree's state, and a commit is made from the index -- not from the files.
# Hashing only the working-tree blob leaves a hole: with HEAD=O, index=A, worktree=B, porcelain
# reads `MM` and the pin records B. Stage a different blob C (git update-index / git apply --cached)
# and porcelain still reads `MM` and the pin still records B -- Verify returns 0 while the commit
# now contains unreviewed C. So pin what will actually be committed, not just what is on disk.
function Get-IndexDigest([string]$Root, [string]$relPath) {
    $entry = Invoke-Git $Root ls-files -s -- $relPath
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

function Get-TreeFingerprint([string]$Root) {
    $lines = @()

    # Committed state matters too: a commit landing mid-gate moves the baseline under the verdict.
    $head = Invoke-Git $Root rev-parse HEAD
    $lines += "HEAD $head"

    $status = Invoke-Git $Root status --porcelain
    foreach ($entry in ($status | Sort-Object)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        # Residual limit: git C-quoted path unescaping (core.quotePath evasion) remains out of scope;
        # this intentionally preserves the existing trim-only behavior while fixing git failures.
        $path = $entry.Substring(3).Trim().Trim('"')
        # Renames read as "old -> new"; the post-rename path is the one on disk.
        if ($path -match '\s->\s(.+)$') { $path = $Matches[1].Trim().Trim('"') }
        $lines += "$($entry.Substring(0,2)) $path work:$(Get-PathDigest $Root $path) index:$(Get-IndexDigest $Root $path)"
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
        Fingerprint = Get-TreeFingerprint $worktreeFull
    }
})

if ($Pin) {
    foreach ($tree in $trees) {
        [System.IO.File]::WriteAllText($tree.PinPath, $tree.Fingerprint.Digest + "`n" + $tree.Fingerprint.Detail,
            [System.Text.UTF8Encoding]::new($false))
        if ($trees.Count -eq 1) {
            Write-Host "[tree-pin] pinned $($tree.Fingerprint.Digest.Substring(0,12)) for '$Label'" -ForegroundColor DarkGray
        } else {
            Write-Host "[tree-pin] pinned $($tree.Fingerprint.Digest.Substring(0,12)) for '$Label' in '$($tree.Root)'" -ForegroundColor DarkGray
        }
    }
    exit 0
}

# The porcelain status prefix is two columns WITH SIGNIFICANT SPACES (" M", "?? ", "A "), so the
# prefix must be matched as two arbitrary characters -- not two non-space ones.
$parseDetail = {
    param([string]$Detail)
    $map = @{}
    foreach ($line in $Detail -split "`n") {
        if ($line -match '^(.{2})\s+(.+?)\s+(work:\S+\s+index:\S+)$') { $map[$Matches[2]] = $Matches[3] }
    }
    return $map
}

$failed = $false
foreach ($tree in $trees) {
    if (-not (Test-Path -LiteralPath $tree.PinPath -PathType Leaf)) {
        if ($trees.Count -eq 1) {
            Write-Host "[tree-pin] NO PIN for '$Label'. The gate was opened without pinning the tree, so nothing can vouch for the verdict." -ForegroundColor Red
        } else {
            Write-Host "[tree-pin] NO PIN for '$Label' in '$($tree.Root)'. The gate was opened without pinning this tree, so nothing can vouch for the verdict." -ForegroundColor Red
        }
        $failed = $true
        continue
    }

    $pinnedDigest = ([System.IO.File]::ReadAllLines($tree.PinPath))[0]
    if ($pinnedDigest -eq $tree.Fingerprint.Digest) {
        if ($trees.Count -eq 1) {
            Write-Host "[tree-pin] tree unchanged ($($pinnedDigest.Substring(0,12))) -- the verdict is about this tree." -ForegroundColor DarkGray
        } else {
            Write-Host "[tree-pin] tree unchanged ($($pinnedDigest.Substring(0,12))) in '$($tree.Root)' -- the verdict is about this tree." -ForegroundColor DarkGray
        }
        continue
    }

    $pinnedDetail = [string]::Join("`n", ([System.IO.File]::ReadAllLines($tree.PinPath) | Select-Object -Skip 1))
    $before = & $parseDetail $pinnedDetail
    $after = & $parseDetail $tree.Fingerprint.Detail

    Write-Host ''
    Write-Host "[tree-pin] THE TREE MOVED WHILE THE GATE WAS OPEN. The verdict for '$Label' is VOID." -ForegroundColor Red
    if ($trees.Count -gt 1) { Write-Host "[tree-pin] Root: $($tree.Root)" -ForegroundColor Red }
    foreach ($path in ($before.Keys + $after.Keys | Sort-Object -Unique)) {
        if (-not $after.ContainsKey($path)) { Write-Host "[tree-pin]   GONE:    $path" -ForegroundColor Red }
        elseif (-not $before.ContainsKey($path)) { Write-Host "[tree-pin]   NEW:     $path" -ForegroundColor Red }
        elseif ($before[$path] -ne $after[$path]) { Write-Host "[tree-pin]   CHANGED: $path" -ForegroundColor Red }
    }
    Write-Host "[tree-pin] Someone or something wrote to the tree after the gate opened -- a live coder, a" -ForegroundColor Red
    Write-Host "[tree-pin] concurrent agent, or a hand-edit. Do NOT act on this verdict. Find the writer," -ForegroundColor Red
    Write-Host "[tree-pin] let it finish, re-pin, and re-run the gate." -ForegroundColor Red
    Write-Host ''
    $failed = $true
}

if ($failed) { exit 69 }
exit 0
