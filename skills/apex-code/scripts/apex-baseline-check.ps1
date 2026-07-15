# apex-baseline-check.ps1 (M2a)
#
# Runs a repo's OWN verify recipe -- the fenced block under a `## Verify commands` heading in the
# repo's root AGENTS.md -- and reports green/red by exit code. The baseline-green pre-commit hook
# (templates/pre-commit-baseline) calls this with -Full to block a commit whose STAGED tree fails
# the full quad. M2b will add a fast -Preflight subset for the dispatch pre-flight; this file is the
# single parser both ends share, so the heading match is never re-implemented (two copies diverge and
# the weaker one fails open -- a lesson this harness has paid for repeatedly).
#
# SECURITY: this executes the repo-declared verify commands on the host, with the caller's privileges,
# OUTSIDE any sandbox. That is the same trust the host already places in AGENTS.md's verify recipe
# (apex-code runs it directly today); the hook only makes it non-skippable. AGENTS.md is trusted,
# planning-authored repo content. `git commit --no-verify` is the deliberate escape.
#
# Exit codes are the contract:
#   0  GREEN       -- every recipe line exited 0, OR there is no recipe (a logged skip, not a silent one)
#   1  RED         -- a recipe line failed (the failing line is printed)
#   3  UNPARSEABLE -- a `## Verify commands` heading exists but no runnable command block follows it

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Worktree,
    # Accepted for a stable call site: the hook calls `-Full`, and M2b adds `-Preflight` without
    # changing that. M2a runs the full recipe regardless.
    [switch]$Full
)

$ErrorActionPreference = 'Stop'

# Exit codes as named constants (never bare numbers at the call sites).
$EXIT_GREEN = 0
$EXIT_RED = 1
$EXIT_UNPARSEABLE = 3

if (-not (Test-Path -LiteralPath $Worktree -PathType Container)) {
    Write-Host "[baseline] worktree does not exist: $Worktree" -ForegroundColor Red
    exit $EXIT_RED
}

$agentsPath = Join-Path $Worktree 'AGENTS.md'
if (-not (Test-Path -LiteralPath $agentsPath -PathType Leaf)) {
    Write-Host "[baseline] no AGENTS.md in $Worktree -- no verify recipe, skipping." -ForegroundColor DarkGray
    exit $EXIT_GREEN
}

# Match the FIRST heading beginning `## Verify commands` (the real recipe carries a parenthetical
# suffix, e.g. "## Verify commands (brain default ...)", so this is a prefix match, not exact).
# Markdown allows a heading indented by up to 3 spaces, so tolerate that -- otherwise an indented but
# perfectly valid recipe reads as "no recipe" and skips (a fail-open).
$lines = [System.IO.File]::ReadAllLines($agentsPath)
$headingIndex = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s{0,3}##\s*Verify commands\b') { $headingIndex = $i; break }
}
if ($headingIndex -lt 0) {
    Write-Host "[baseline] AGENTS.md has no '## Verify commands' heading -- no verify recipe, skipping." -ForegroundColor DarkGray
    exit $EXIT_GREEN
}

# Capture the fenced ``` block that follows the heading. Each non-empty, non-comment line is one
# runnable command (a line may itself chain with &&). A new heading before any fence => no block.
$commands = @()
$inFence = $false
$sawFence = $false
for ($i = $headingIndex + 1; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    if ($line -match '^\s*```') {
        if (-not $inFence) { $inFence = $true; $sawFence = $true; continue }
        break   # closing fence -- recipe ends here
    }
    # ANY new heading (any level) before the opening fence means the section had no command block --
    # stop, so a later unrelated code block under a different heading is never grabbed as the recipe
    # (that would run the wrong commands, or pass a green unrelated block -- a fail-open).
    if (-not $inFence -and $line -match '^\s{0,3}#{1,6}\s') { break }
    if ($inFence) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -gt 0 -and -not $trimmed.StartsWith('#')) { $commands += $trimmed }
    }
}

if (-not $sawFence -or $commands.Count -eq 0) {
    # Fail closed: a heading that promises a recipe but carries no runnable block must not read as "green".
    Write-Host "[baseline] '## Verify commands' heading found but no runnable command block -- refusing (unparseable)." -ForegroundColor Red
    exit $EXIT_UNPARSEABLE
}

Write-Host "[baseline] running $($commands.Count) verify command(s) in $Worktree" -ForegroundColor Cyan
foreach ($cmd in $commands) {
    Write-Host "[baseline] > $cmd" -ForegroundColor DarkGray
    # Run each line in the TARGET worktree, preserving && semantics, via cmd.exe. The composed string
    # starts with `cd` (not a quote), so cmd.exe does not strip the quotes around the path.
    & cmd.exe /c "cd /d `"$Worktree`" && $cmd"
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Write-Host "[baseline] RED -- command failed (exit $code): $cmd" -ForegroundColor Red
        exit $EXIT_RED
    }
}
Write-Host "[baseline] GREEN -- all verify commands passed." -ForegroundColor Green
exit $EXIT_GREEN
