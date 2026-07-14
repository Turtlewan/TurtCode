# codex-scope-check.ps1 - enforce a Codex task's scope lock from the HOST side.
#
# THE BUG THIS FIXES (status.md P1, from a real Artemis AFK run):
# A `codex exec` task wrote docs/status.md despite the dispatch brief saying "authorized set --
# touch nothing else". Two fixes do NOT work and were rejected:
#   1. Another prohibition in the brief. The rule was already there and was ignored. Adding a
#      louder one is not a mechanism.
#   2. A PreToolUse deny hook. It CANNOT SEE these writes at all -- the Codex subprocess does not
#      ride Claude Code's permission floor. `--sandbox workspace-write` is its only guardrail, and
#      that is repo-wide, not spec-wide.
# The only enforceable point is the host, after the subprocess exits.
#
# THE OTHER HALF OF THE BUG (equally important):
# A previous mitigation blanket-reverted status.md after each stage. That destroyed the planning
# host's CONCURRENT edits and then reported the host's own real ADRs as Codex "fabrications".
# So: never revert a file wholesale, and NEVER revert a path the host had already dirtied before
# dispatch. This script reverts only paths that were CLEAN at snapshot time and are unauthorized
# now. Anything else is reported, never touched.
#
# USAGE
#   Before dispatch:
#     codex-scope-check.ps1 -Snapshot -Worktree <repo> -Task <name>
#   After the subprocess exits:
#     codex-scope-check.ps1 -Check -Worktree <repo> -Task <name> -Authorized 'src/a.py','tests/b.py'
#     codex-scope-check.ps1 -Check ... -ReportOnly     # never revert; just tell me
#
# Exit 0 = in scope. Exit 1 = violations found (reverted or reported).

[CmdletBinding()]
param(
    [switch]$Snapshot,
    [switch]$Check,
    [Parameter(Mandatory)][string]$Worktree,
    [Parameter(Mandatory)][string]$Task,
    [string[]]$Authorized = @(),
    [switch]$ReportOnly,
    [string]$StateDirectory
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Worktree)) { throw "Worktree not found: $Worktree" }
$repo = (Resolve-Path $Worktree).Path

if (-not $StateDirectory) { $StateDirectory = Join-Path $repo 'docs/progress' }
if (-not (Test-Path $StateDirectory)) { New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null }
$snapPath = Join-Path $StateDirectory "scope-$Task.snapshot.json"

function Get-DirtySet {
    # porcelain v1: XY<space>path  (untracked = '??'). Rename lines are 'R  old -> new'.
    $out = & git -C $repo status --porcelain 2>$null
    $set = @{}
    foreach ($line in $out) {
        if (-not $line) { continue }
        $path = $line.Substring(3).Trim().Trim('"')
        if ($path -match '\s->\s') { $path = ($path -split '\s->\s')[-1].Trim().Trim('"') }
        $set[$path] = $line.Substring(0, 2)
    }
    return $set
}

function Normalize([string]$p) { return ($p -replace '\\', '/').Trim().TrimStart('./') }

# ---------------------------------------------------------------------------------- SNAPSHOT
if ($Snapshot) {
    $dirty = Get-DirtySet
    $state = [ordered]@{
        task     = $Task
        head     = (& git -C $repo rev-parse HEAD 2>$null)
        dirty    = @($dirty.Keys)
        takenUtc = (& git -C $repo log -1 --format=%cI 2>$null)  # no Get-Date: keep it git-sourced
    }
    $state | ConvertTo-Json -Depth 5 | Out-File -FilePath $snapPath -Encoding utf8
    Write-Host "[scope] snapshot for '$Task': HEAD=$($state.head.Substring(0,7)), $($state.dirty.Count) file(s) already dirty (host work - will never be reverted)."

    # --- RE-DISPATCH HAZARD -----------------------------------------------------------------------
    # If a file this task is AUTHORIZED to write is ALREADY dirty, the task's own work may already be
    # sitting in the tree -- from a previous dispatch that appeared to fail but wasn't a no-op.
    # The coder then cannot run its load-bearing test RED before the fix, because the fix is already
    # there. It can only verify what it finds. That is a rubber-stamp, not a build, and a coder less
    # honest than the one that reported it would simply say "done".
    #
    # Live: cap-deps-1a, 2026-07-14 -- "The complete scoped implementation and test file were already
    # present as uncommitted changes at initial inspection. Consequently, the load-bearing test could
    # not be run red against the then-current worktree before the fix."
    if ($Authorized.Count -gt 0) {
        $preAuth = @()
        foreach ($a in $Authorized) {
            foreach ($piece in ($a -split ',')) {
                $p = Normalize ($piece.Trim().Trim("'").Trim('"'))
                if ($p -and $dirty.ContainsKey($p)) { $preAuth += $p }
                elseif ($p) {
                    foreach ($k in $dirty.Keys) { if ((Normalize $k) -eq $p) { $preAuth += $p } }
                }
            }
        }
        if ($preAuth.Count -gt 0) {
            Write-Host ""
            Write-Host "[scope] RE-DISPATCH HAZARD - $($preAuth.Count) file(s) this task is authorized to write are ALREADY dirty:" -ForegroundColor Yellow
            foreach ($p in ($preAuth | Select-Object -Unique)) { Write-Host "      $p" }
            Write-Host "[scope] The task's work may already be in the tree from an earlier dispatch that only LOOKED like it failed." -ForegroundColor Yellow
            Write-Host "[scope] The coder cannot run its test RED against a tree that already contains the fix - it can only" -ForegroundColor Yellow
            Write-Host "[scope] verify what it finds. Reset these paths to the base SHA before re-dispatching, or accept that" -ForegroundColor Yellow
            Write-Host "[scope] this run VERIFIES rather than BUILDS - and say so in the decisions table." -ForegroundColor Yellow
            Write-Host ""
        }
    }
    exit 0
}

# ------------------------------------------------------------------------------------- CHECK
if (-not $Check) { throw "Specify -Snapshot or -Check." }
if (-not (Test-Path $snapPath)) { throw "No snapshot for task '$Task'. Run -Snapshot BEFORE dispatching, or the check cannot tell Codex's writes from the host's." }

$snap     = Get-Content $snapPath -Raw | ConvertFrom-Json
$preDirty = @{}
foreach ($p in @($snap.dirty)) { $preDirty[(Normalize $p)] = $true }

# Split on commas as well as on array elements. A caller invoking this from bash (or any shell that
# does not understand PowerShell array syntax) passes -Authorized 'a.py','b.py' as ONE string,
# "a.py,b.py" -- which then matches nothing, and every authorized file is misreported as a violation.
# Silent, and it would have broken the first real build.
$allowed = @{}
foreach ($a in $Authorized) {
    foreach ($piece in ($a -split ',')) {
        $p = $piece.Trim().Trim("'").Trim('"')
        if ($p) { $allowed[(Normalize $p)] = $true }
    }
}

$nowDirty = Get-DirtySet

# Codex must never commit. If HEAD moved, that is itself a violation worth shouting about.
$headNow = & git -C $repo rev-parse HEAD 2>$null
if ($headNow -ne $snap.head) {
    Write-Host "[scope] VIOLATION: HEAD moved during the task ($($snap.head.Substring(0,7)) -> $($headNow.Substring(0,7))). Codex is instructed never to commit. Not auto-reverting a commit - resolve by hand." -ForegroundColor Red
}

# This script's own state lives under $StateDirectory (docs/progress by default) and shows up as
# untracked. Without this guard it flags -- and DELETES -- its own snapshot. Found by the first
# test run, which is exactly what a test run is for.
$stateDirFull = (Resolve-Path $StateDirectory).Path
$stateRel = ''
if ($stateDirFull.StartsWith($repo)) {
    $stateRel = Normalize ($stateDirFull.Substring($repo.Length))
}

$violations = @()   # ours, and clean at snapshot -> safe to revert
$contested  = @()   # ours AND the host's -> REPORT, never revert

foreach ($path in $nowDirty.Keys) {
    $n = Normalize $path
    if ($allowed.ContainsKey($n)) { continue }                    # authorized - fine
    # Our own scratch dir. Note git COLLAPSES an untracked parent: if docs/ is itself untracked it
    # reports "docs/", not "docs/progress/scope-x.json" -- so match the collapsed parent too.
    if ($stateRel -and ($n.StartsWith($stateRel) -or $stateRel.StartsWith($n.TrimEnd('/') + '/'))) { continue }
    if ($preDirty.ContainsKey($n)) {
        # The host had this dirty BEFORE dispatch and it is not authorized. Codex may have written
        # to it as well -- this is precisely the status.md incident -- but the two edits cannot be
        # separated, so we must NOT revert. Reverting here is what destroyed the host's ADRs and
        # produced the false "codex fabricated ADRs" finding. Report it and let a human look.
        $contested += [pscustomobject]@{ Path = $path; Status = $nowDirty[$path] }
        continue
    }
    $violations += [pscustomobject]@{ Path = $path; Status = $nowDirty[$path] }
}

function Show-Contested {
    if ($contested.Count -eq 0) { return }
    Write-Host ""
    Write-Host "[scope] CONTESTED - unauthorized, but the host had these dirty before dispatch:" -ForegroundColor Yellow
    foreach ($c in $contested) { Write-Host ("    {0}  {1}" -f $c.Status, $c.Path) }
    Write-Host "[scope] NOT reverted - a blanket revert would destroy the host's concurrent work." -ForegroundColor Yellow
    Write-Host "[scope] Inspect by hand: the task may have written a file it was never authorized to touch." -ForegroundColor Yellow
}

# --- MANGLED-ALLOWLIST GUARD ------------------------------------------------------------------
# A wrong -Authorized list does not merely fail to protect: it REVERTS THE CODER'S REAL WORK. That
# is strictly worse than no check at all, and it is one quoting slip away (an array passed as one
# comma-joined string matches nothing, so every file the task wrote reads as a violation).
#
# The tell: a task that did real work always writes at least one file it WAS authorized to write.
# If it wrote several files and not one of them is on the list, the list is wrong -- not the coder.
# Refuse to revert, say so loudly, and exit distinctly.
$authorizedHits = 0
foreach ($path in $nowDirty.Keys) {
    if ($allowed.ContainsKey((Normalize $path))) { $authorizedHits++ }
}
if ($violations.Count -gt 1 -and $authorizedHits -eq 0 -and $allowed.Count -gt 0) {
    Write-Host ""
    Write-Host "[scope] REFUSING TO REVERT - the authorized list looks wrong, not the coder." -ForegroundColor Red
    Write-Host "[scope] The task wrote $($violations.Count) file(s) and NOT ONE is on the authorized list." -ForegroundColor Red
    Write-Host "[scope] A task that did real work always touches at least one file it was allowed to touch," -ForegroundColor Red
    Write-Host "[scope] so this is almost certainly a malformed -Authorized (e.g. an array passed as one" -ForegroundColor Red
    Write-Host "[scope] comma-joined string). Reverting here would destroy the build." -ForegroundColor Red
    Write-Host ""
    Write-Host "[scope] Authorized ($($allowed.Count)):" -ForegroundColor Yellow
    foreach ($a in $allowed.Keys) { Write-Host "      $a" }
    Write-Host "[scope] Written ($($violations.Count)):" -ForegroundColor Yellow
    foreach ($v in $violations) { Write-Host ("      {0}  {1}" -f $v.Status, $v.Path) }
    Write-Host ""
    Write-Host "[scope] Nothing was reverted. Fix the list and re-check, or inspect by hand." -ForegroundColor Yellow
    exit 66
}

if ($violations.Count -eq 0) {
    if ($contested.Count -eq 0) {
        Write-Host "[scope] '$Task' clean - every changed file is in the authorized set." -ForegroundColor Green
        Remove-Item $snapPath -Force -ErrorAction SilentlyContinue
        exit 0
    }
    Show-Contested
    Remove-Item $snapPath -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Host ""
Write-Host "[scope] SCOPE VIOLATION - '$Task' wrote $($violations.Count) file(s) outside its authorized set:" -ForegroundColor Red
foreach ($v in $violations) { Write-Host ("    {0}  {1}" -f $v.Status, $v.Path) }
Write-Host ""

if ($ReportOnly) {
    Write-Host "[scope] -ReportOnly: nothing reverted. The tree still contains the out-of-scope writes." -ForegroundColor Yellow
    exit 1
}

foreach ($v in $violations) {
    $full = Join-Path $repo $v.Path
    if ($v.Status -eq '??') {
        Remove-Item -LiteralPath $full -Force -Recurse -ErrorAction SilentlyContinue
        Write-Host "    reverted (deleted untracked): $($v.Path)"
    }
    else {
        # Path-scoped restore. Never `git checkout -- .`, never a wholesale file revert of
        # something the host was also editing (those were excluded above).
        & git -C $repo checkout -- $v.Path 2>$null
        Write-Host "    reverted (restored tracked):  $($v.Path)"
    }
}

Write-Host ""
Show-Contested
Write-Host ""
Write-Host "[scope] Reverted $($violations.Count) out-of-scope path(s)." -ForegroundColor Yellow
Write-Host "[scope] This is a SPEC DEFECT, not a coder failure: the task needed a file its spec did not authorize." -ForegroundColor Yellow
Write-Host "[scope] Log it to the decisions table and surface it to planning - do not just re-run." -ForegroundColor Yellow
Remove-Item $snapPath -Force -ErrorAction SilentlyContinue
exit 1
