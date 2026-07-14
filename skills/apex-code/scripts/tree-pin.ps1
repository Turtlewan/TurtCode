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
    [Parameter(Mandatory)][string]$Label,
    [string]$PinDirectory = $env:TEMP
)

$ErrorActionPreference = 'Stop'

if ($Pin -eq $Verify) {
    throw 'Pass exactly one of -Pin or -Verify.'
}
if (-not (Test-Path -LiteralPath $Worktree -PathType Container)) {
    throw "Worktree does not exist: $Worktree"
}

# The pin identity must include the WORKTREE, not just a lossy label. Two concurrent reviews of the
# same spec/task in DIFFERENT worktrees are explicitly allowed (that is the whole point of one
# worktree per task) -- and they shared one pin file. The second overwrote the first, so the first
# then verified its tree against the SECOND's pin and returned 0 on a tree that had moved.
$worktreeFull = (Resolve-Path -LiteralPath $Worktree).Path
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes(($worktreeFull -replace '\\', '/').TrimEnd('/').ToLowerInvariant())
    $worktreeTag = [System.BitConverter]::ToString($sha.ComputeHash($keyBytes)).Replace('-', '').Substring(0, 10).ToLower()
} finally { $sha.Dispose() }

$safeLabel = ($Label -replace '[<>:"/\\|?*]', '_')
$pinPath = Join-Path $PinDirectory "apex-treepin-$safeLabel-$worktreeTag.txt"

# The pin must cover CONTENT, not just which files are dirty. A reviewer that read store.py at +2
# and returns after it grows to +6 sees the same `git status` line either way -- the filename never
# changed, only what is inside it. `git status --porcelain` alone would have missed today's move
# entirely. Hash the content of every tracked-but-modified and untracked file.
function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& git -C $Worktree @GitArgs 2>$null) } finally { $ErrorActionPreference = $previous }
}

# A DIRECTORY is hashed by its recursive contents, never written off as unhashable.
#
# git COLLAPSES an untracked directory into one porcelain entry: `?? newdir/`. Returning a constant
# for it means the fingerprint is identical before and after a coder rewrites every file inside it --
# so Verify returns 0 and the gate blesses content the reviewer never saw. The pin then certifies
# precisely the blind spot it was built to eliminate.
function Get-PathDigest([string]$relPath) {
    $full = Join-Path $Worktree $relPath

    if (Test-Path -LiteralPath $full -PathType Container) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($file in (Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue |
                Sort-Object FullName)) {
            $rel = $file.FullName.Substring((Resolve-Path $Worktree).Path.Length).TrimStart('\', '/') -replace '\\', '/'
            $h = Invoke-Git hash-object -- $rel
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
    $h = Invoke-Git hash-object -- $relPath
    if (-not $h) { return '-' }
    return ([string]$h).Trim()
}

# The INDEX is part of the tree's state, and a commit is made from the index -- not from the files.
# Hashing only the working-tree blob leaves a hole: with HEAD=O, index=A, worktree=B, porcelain
# reads `MM` and the pin records B. Stage a different blob C (git update-index / git apply --cached)
# and porcelain still reads `MM` and the pin still records B -- Verify returns 0 while the commit
# now contains unreviewed C. So pin what will actually be committed, not just what is on disk.
function Get-IndexDigest([string]$relPath) {
    $entry = Invoke-Git ls-files -s -- $relPath
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

function Get-TreeFingerprint {
    $lines = @()

    # Committed state matters too: a commit landing mid-gate moves the baseline under the verdict.
    $head = Invoke-Git rev-parse HEAD
    $lines += "HEAD $head"

    $status = Invoke-Git status --porcelain
    foreach ($entry in ($status | Sort-Object)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $path = $entry.Substring(3).Trim().Trim('"')
        # Renames read as "old -> new"; the post-rename path is the one on disk.
        if ($path -match '\s->\s(.+)$') { $path = $Matches[1].Trim().Trim('"') }
        $lines += "$($entry.Substring(0,2)) $path work:$(Get-PathDigest $path) index:$(Get-IndexDigest $path)"
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

$fingerprint = Get-TreeFingerprint

if ($Pin) {
    [System.IO.File]::WriteAllText($pinPath, $fingerprint.Digest + "`n" + $fingerprint.Detail,
        [System.Text.UTF8Encoding]::new($false))
    Write-Host "[tree-pin] pinned $($fingerprint.Digest.Substring(0,12)) for '$Label'" -ForegroundColor DarkGray
    exit 0
}

if (-not (Test-Path -LiteralPath $pinPath -PathType Leaf)) {
    Write-Host "[tree-pin] NO PIN for '$Label'. The gate was opened without pinning the tree, so nothing can vouch for the verdict." -ForegroundColor Red
    exit 69
}

$pinnedDigest = ([System.IO.File]::ReadAllLines($pinPath))[0]
if ($pinnedDigest -eq $fingerprint.Digest) {
    Write-Host "[tree-pin] tree unchanged ($($pinnedDigest.Substring(0,12))) -- the verdict is about this tree." -ForegroundColor DarkGray
    exit 0
}

$pinnedDetail = [string]::Join("`n", ([System.IO.File]::ReadAllLines($pinPath) | Select-Object -Skip 1))
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
$before = & $parseDetail $pinnedDetail
$after = & $parseDetail $fingerprint.Detail

Write-Host ''
Write-Host "[tree-pin] THE TREE MOVED WHILE THE GATE WAS OPEN. The verdict for '$Label' is VOID." -ForegroundColor Red
foreach ($path in ($before.Keys + $after.Keys | Sort-Object -Unique)) {
    if (-not $after.ContainsKey($path)) { Write-Host "[tree-pin]   GONE:    $path" -ForegroundColor Red }
    elseif (-not $before.ContainsKey($path)) { Write-Host "[tree-pin]   NEW:     $path" -ForegroundColor Red }
    elseif ($before[$path] -ne $after[$path]) { Write-Host "[tree-pin]   CHANGED: $path" -ForegroundColor Red }
}
Write-Host "[tree-pin] Someone or something wrote to the tree after the gate opened -- a live coder, a" -ForegroundColor Red
Write-Host "[tree-pin] concurrent agent, or a hand-edit. Do NOT act on this verdict. Find the writer," -ForegroundColor Red
Write-Host "[tree-pin] let it finish, re-pin, and re-run the gate." -ForegroundColor Red
Write-Host ''
exit 69
