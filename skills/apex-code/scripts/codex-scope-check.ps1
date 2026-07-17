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
# ── WHY THIS SCRIPT NO LONGER REVERTS ANYTHING (2026-07-14) ────────────────────────────────────
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
# ── THREAT MODEL: A CARELESS CODER, NOT A HOSTILE ONE ──────────────────────────────────────────
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
    [string]$ExcludeRunId         # accepted for compatibility; no longer used (nothing is reverted)
)

$ErrorActionPreference = 'Stop'

# Multiple modes used to run the first matching branch, so -Snapshot -Check overwrote the evidence
# and exited clean without checking it. Refuse ambiguous mode requests before touching state.
$selectedModes = @()
if ($Snapshot) { $selectedModes += '-Snapshot' }
if ($Check) { $selectedModes += '-Check' }
if ($EncodingScan) { $selectedModes += '-EncodingScan' }
if ($selectedModes.Count -gt 1) {
    throw "Mode switches are mutually exclusive; specify exactly one of -Snapshot, -Check, or -EncodingScan (received $($selectedModes -join ', '))."
}

if (-not (Test-Path $Worktree)) { throw "Worktree not found: $Worktree" }
$repo = (Resolve-Path $Worktree).Path

# A git WARNING must never kill a dispatch. `& git ... 2>$null` under $ErrorActionPreference='Stop'
# wraps native stderr in a TERMINATING NativeCommandError in Windows PowerShell 5.1 -- so the
# redirect written to silence a warning is what makes it fatal. It killed an 11-minute Codex run
# over a message about an unreadable temp directory. git's EXIT CODE is the verdict, not its stderr.
function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $exitCodeSentinel = -987654
    $launchException = $null
    $output = @()
    try {
        # A launch failure in Windows PowerShell 5.1 can leave a stale prior zero in LASTEXITCODE.
        # Reset it and catch terminating launch errors so an unavailable git can never read as clean.
        $global:LASTEXITCODE = $exitCodeSentinel
        try {
            $output = @(& git -C $repo @GitArgs 2>$null)
        }
        catch {
            $launchException = $_.Exception
        }
        $exitCode = $global:LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    $command = "git $($GitArgs -join ' ')"
    if ($launchException) {
        throw "$command failed to launch in '$repo'. Refusing to report clean: $($launchException.Message)"
    }
    if ($exitCode -eq $exitCodeSentinel) {
        throw "$command failed to launch in '$repo' and did not set an exit code. Refusing to report clean."
    }
    if ($exitCode -ne 0) {
        throw "$command failed in '$repo' (exit $exitCode). Refusing to report clean."
    }
    return $output
}

# Strip a leading "./" -- and ONLY that. `.TrimStart('./')` strips every leading '.' and '/'
# CHARACTER, so `.env` normalized to `env`: authorize `env` and the coder could write `.env` and be
# waved through. TrimStart takes a character SET, not a prefix.
function Normalize([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    $n = ($p -replace '\\', '/').Trim()
    while ($n.StartsWith('./')) { $n = $n.Substring(2) }
    return $n.TrimEnd('/')
}

function Get-DirtySet {
    # porcelain v1: XY<space>path  (untracked = '??'). Rename lines are 'R  old -> new'.
    #
    # --ignored=traditional ALSO lists ignored paths (collapsed to the directory where possible).
    # Without it, `git status` is blind to anything .gitignore matches -- so a coder authorized for
    # one file could create an ignored one (a hook, a script, a config) and the check would exit 0
    # having seen nothing. Ignored entries appear in BOTH the snapshot and the check, so a
    # pre-existing node_modules/ is byte-identical and ignored as host state; only a NEW or CHANGED
    # ignored path shows up as a violation.
    $out = Invoke-Git status --porcelain --ignored=traditional

    # git's EXIT CODE is the verdict. Without this check a FAILED `git status` (corrupt index, locked
    # .git, not a repo) returns nothing, every caller reads "no dirty paths", and the scope check and
    # the encoding gate both report CLEAN on a tree they never actually looked at. A gate that fails
    # open is worse than no gate, because it reads as a pass.
    if ($LASTEXITCODE -ne 0) {
        throw "git status failed in '$repo' (exit $LASTEXITCODE). Refusing to report a clean tree that was never read."
    }

    $set = @{}
    foreach ($line in $out) {
        if (-not $line) { continue }
        $status = $line.Substring(0, 2)
        $path = $line.Substring(3).Trim()

        # BOTH SIDES of a rename matter. Keeping only the destination meant
        # `git mv secret.txt allowed.txt` was judged solely on `allowed.txt` -- which is authorized --
        # so deleting the unauthorized source passed the check.
        if ($path -match '\s->\s') {
            $parts = $path -split '\s->\s'
            $set[(Unquote-GitPath $parts[0])] = 'R-'   # the source: it was REMOVED
            $set[(Unquote-GitPath $parts[-1])] = $status
            continue
        }
        $set[(Unquote-GitPath $path)] = $status
    }
    return $set
}

# git C-quotes any path with unusual bytes (default core.quotePath=true): "src/\303\251.txt".
# Trimming the quote characters alone leaves the backslash escapes, so the path never resolves to a
# real file and hashes as "missing" -- identical before and after, which reads as "untouched".
function Unquote-GitPath([string]$p) {
    $p = $p.Trim()
    if (-not ($p.StartsWith('"') -and $p.EndsWith('"'))) { return $p }
    $inner = $p.Substring(1, $p.Length - 2)
    $bytes = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $inner.Length; $i++) {
        if ($inner[$i] -ne '\') { $bytes.Add([byte][char]$inner[$i]); continue }
        $i++
        if ($i -ge $inner.Length) { break }
        switch ($inner[$i]) {
            'n' { $bytes.Add(10) }
            't' { $bytes.Add(9) }
            'r' { $bytes.Add(13) }
            '"' { $bytes.Add(34) }
            '\' { $bytes.Add(92) }
            default {
                if ($inner[$i] -match '[0-7]' -and $i + 2 -lt $inner.Length) {
                    $bytes.Add([Convert]::ToByte($inner.Substring($i, 3), 8))
                    $i += 2
                } else { $bytes.Add([byte][char]$inner[$i]) }
            }
        }
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes.ToArray())
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
    $full = Join-Path $repo $relPath

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
        $enumErr = $null
        foreach ($file in (Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue -ErrorVariable enumErr |
                Sort-Object FullName)) {
            $rel = $file.FullName.Substring($repo.Length).TrimStart([char]92, [char]47) -replace '\\', '/'
            $parts.Add("$rel|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)")
        }
        # A subtree we could not read must not fingerprint identically to one we could -- fold the
        # failure count in so a newly-unreadable subtree changes the hash rather than silently passing.
        if ($enumErr -and $enumErr.Count -gt 0) { $parts.Add("UNREADABLE|$($enumErr.Count)") }
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
    $h = Invoke-Git hash-object -- $relPath
    if (-not $h) { throw "git hash-object returned no hash for present file '$relPath'. Refusing to report it absent." }
    return ([string]$h).Trim()
}

# The INDEX is what a commit is built from. A staged blob can differ from the working file (`MM`),
# so a check that only looks at the working tree misses an unauthorized change that is already
# staged -- and `git add` is exactly what a coder does before it thinks it is done.
function Get-IndexHash([string]$relPath) {
    # Empty output with a successful ls-files call legitimately means the path is not in the index;
    # Invoke-Git now throws on launch/exit failure instead of collapsing either error to this '-'.
    $entry = Invoke-Git ls-files -s -- $relPath
    if (-not $entry) { return '-' }
    $fields = ([string]$entry).Split(@(' ', "`t"), [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($fields.Count -ge 2) { return "$($fields[0]):$($fields[1])" }   # mode:sha -- a chmod is a change too
    return '-'
}

function Get-PathState([string]$relPath) {
    return "work:$(Get-ContentHash $relPath) index:$(Get-IndexHash $relPath)"
}

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

# --------------------------------------------------------------------------- ENCODING SCAN
# Codex-on-Windows double-encodes non-ASCII it writes into source: an em-dash goes in as U+2014 and
# comes out as `â€"` (the UTF-8 bytes read back as CP1252, then re-encoded as UTF-8).
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
# A hit is a hit; if it is a false positive, that is a file with `â€` in it, which is worth a look.
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
        foreach ($u in $cannotVerify) { Write-Host "      $u" -ForegroundColor Red }
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
        Write-Host ("      {0}:{1}  {2}" -f $h.Path, $h.Line, $h.Text) -ForegroundColor Red
    }
    if ($hits.Count -gt 40) { Write-Host "      ... and $($hits.Count - 40) more" -ForegroundColor Red }
    Write-Host ""
    Write-Host "[encoding] The tests do NOT catch this: the same corrupted bytes go into the expected" -ForegroundColor Yellow
    Write-Host "[encoding] string, so a green suite proves nothing. Fix the bytes, then re-verify." -ForegroundColor Yellow
    Write-Host ""
    exit 73
}

# ---------------------------------------------------------------------------------- SNAPSHOT
if ($Snapshot) {
    $dirty = Get-DirtySet
    $states = [ordered]@{}
    foreach ($p in $dirty.Keys) { $states[$p] = Get-PathState $p }

    $state = [ordered]@{
        task     = $Task
        head     = (Invoke-Git rev-parse HEAD)
        dirty    = @($dirty.Keys)
        states   = $states
        takenUtc = (Invoke-Git log -1 --format=%cI)   # no Get-Date: keep it git-sourced
    }
    $state | ConvertTo-Json -Depth 5 | Out-File -FilePath $snapPath -Encoding utf8
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
                foreach ($k in $dirty.Keys) { if ((Normalize $k) -eq $p) { $preAuth += $p } }
            }
        }
        if ($preAuth.Count -gt 0) {
            Write-Host ""
            Write-Host "[scope] RE-DISPATCH HAZARD - $($preAuth.Count) file(s) this task may write are ALREADY dirty:" -ForegroundColor Yellow
            foreach ($p in ($preAuth | Select-Object -Unique)) { Write-Host "      $p" }
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

$snap = Get-Content $snapPath -Raw | ConvertFrom-Json

$preState = @{}
if ($snap.PSObject.Properties.Name -contains 'states' -and $snap.states) {
    foreach ($prop in $snap.states.PSObject.Properties) { $preState[(Normalize $prop.Name)] = [string]$prop.Value }
}
$preDirty = @{}
foreach ($p in @($snap.dirty)) { $preDirty[(Normalize $p)] = $true }

# Split on commas as well as array elements: a caller invoking this from bash passes
# -Authorized 'a.py','b.py' as ONE string "a.py,b.py", which then matches nothing -- and every
# authorized file reads as a violation.
$allowed = @{}
foreach ($a in $Authorized) {
    foreach ($piece in ($a -split ',')) {
        $p = Normalize ($piece.Trim().Trim("'").Trim('"'))
        if ($p) { $allowed[$p] = $true }
    }
}

$nowDirty = Get-DirtySet
$violations = @()   # the coder wrote these, and they are not authorized
$untouched = @()    # dirty before the dispatch AND byte-identical since: not the coder's

# This script's own state lives under $StateDirectory and shows up as untracked. Compare by PATH
# SEGMENT, never by raw string prefix: a prefix match on "docs/progress" also swallows
# "docs/progress-evil.md", which is a hole a coder could drive an unauthorized file through.
$stateRel = ''
$stateFull = (Resolve-Path $StateDirectory).Path
if ($stateFull.StartsWith($repo)) {
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
        if ($n -ieq $a) { return $true }
        if ($n.StartsWith($a + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# Examine the UNION of "dirty now" and "dirty at snapshot". A path that VANISHES is invisible to a
# now-only scan: the coder deleting a host's untracked draft, or restoring a host-modified file back
# to HEAD, removes it from `git status` entirely -- so the old loop saw nothing and exited 0 while
# host work was destroyed. Absence is a change too.
$allPaths = New-Object System.Collections.Generic.HashSet[string]
foreach ($p in $nowDirty.Keys) { [void]$allPaths.Add((Normalize $p)) }
foreach ($p in $preDirty.Keys) { [void]$allPaths.Add($p) }

foreach ($n in $allPaths) {
    if (Test-IsAuthorized $n) { continue }
    if (Test-IsStatePath $n) { continue }

    $wasDirty = $preDirty.ContainsKey($n)
    $isDirty = $false
    $statusNow = '??'
    foreach ($k in $nowDirty.Keys) {
        if ((Normalize $k) -eq $n) { $isDirty = $true; $statusNow = $nowDirty[$k]; break }
    }

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
        if ((Get-PathState $n) -eq $preState[$n]) {
            # Byte-identical since the snapshot, working tree AND index. The coder was never in here:
            # it is host work (typically an uncommitted earlier wave, or docs/status.md).
            $untouched += $n
            continue
        }
    }

    if ($isDirty) { $violations += [pscustomobject]@{ Path = $n; Status = $statusNow } }
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
foreach ($path in $nowDirty.Keys) { if (Test-IsAuthorized (Normalize $path)) { $authorizedHits++ } }
if ($violations.Count -gt 1 -and $authorizedHits -eq 0 -and $allowed.Count -gt 0 -and -not $headMoved) {
    Write-Host ""
    Write-Host "[scope] THE AUTHORIZED LIST LOOKS WRONG, not the coder." -ForegroundColor Red
    Write-Host "[scope] The task wrote $($violations.Count) path(s) and NOT ONE is on the authorized list. A task that" -ForegroundColor Red
    Write-Host "[scope] did real work always touches at least one file it was allowed to touch -- so this is almost" -ForegroundColor Red
    Write-Host "[scope] certainly a malformed -Authorized (e.g. an array passed as one comma-joined string)." -ForegroundColor Red
    Write-Host ""
    Write-Host "[scope] Authorized ($($allowed.Count)):" -ForegroundColor Yellow
    foreach ($a in $allowed.Keys) { Write-Host "      $a" }
    Write-Host "[scope] Written ($($violations.Count)):" -ForegroundColor Yellow
    foreach ($v in $violations) { Write-Host ("      {0}  {1}" -f $v.Status, $v.Path) }
    Show-Untouched
    exit 66
}

Write-Host ""
Write-Host "[scope] OUT OF SCOPE - '$Task' wrote $($violations.Count) path(s) outside its authorized set:" -ForegroundColor Red
foreach ($v in $violations) { Write-Host ("    {0}  {1}" -f $v.Status, $v.Path) -ForegroundColor Red }
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
