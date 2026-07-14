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
    exit 0
}

# ------------------------------------------------------------------------------------- CHECK
if (-not $Check) { throw "Specify -Snapshot or -Check." }
if (-not (Test-Path $snapPath)) { throw "No snapshot for task '$Task'. Run -Snapshot BEFORE dispatching, or the check cannot tell Codex's writes from the host's." }

$snap     = Get-Content $snapPath -Raw | ConvertFrom-Json
$preDirty = @{}
foreach ($p in @($snap.dirty)) { $preDirty[(Normalize $p)] = $true }

$allowed = @{}
foreach ($a in $Authorized) { $allowed[(Normalize $a)] = $true }

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
    if ($stateRel -and $n.StartsWith($stateRel)) { continue }     # our own scratch - ignore
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
