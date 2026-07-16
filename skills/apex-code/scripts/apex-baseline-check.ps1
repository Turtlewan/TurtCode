# apex-baseline-check.ps1 (M2b)
#
# Runs a repo's OWN declared recipe from its root AGENTS.md and reports green/red by exit code. The
# baseline-green pre-commit hook (templates/pre-commit-baseline) calls this with -Full to block a
# commit whose STAGED tree fails the full recipe. Dispatch pre-flight calls it with -Preflight; that
# mode uses a dedicated `## Preflight commands` block when present and otherwise runs the full
# `## Verify commands` recipe, as specified by ADR-040. Both modes use the same fail-closed parser.
#
# The opening fence selects the shell: `bash`/`sh` uses Git-for-Windows bash, `powershell`/`pwsh`
# uses Windows PowerShell, and `cmd`/`bat`/an unlabeled fence uses cmd.exe. Each non-empty,
# non-comment recipe line is passed whole to that shell; lines are never split on `&&`.
#
# SECURITY: this executes the repo-declared commands on the host, with the caller's privileges,
# OUTSIDE any sandbox. That is the same trust the host already places in AGENTS.md's recipe
# (apex-code runs it directly today); the hook only makes it non-skippable. AGENTS.md is trusted,
# planning-authored repo content. `git commit --no-verify` is the deliberate escape.
#
# Exit codes are the contract:
#   0  GREEN       -- every recipe line exited 0
#   1  RED         -- a recipe line failed (the failing line is printed)
#   3  UNPARSEABLE -- a selected heading has no runnable block, its shell is unsupported/unavailable
#   4  NO_RECIPE   -- AGENTS.md or every candidate recipe heading is absent

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Worktree,
    # -Full selects `## Verify commands`. -Preflight selects `## Preflight commands` when present
    # and otherwise falls back to the full `## Verify commands` recipe (ADR-040).
    [switch]$Full,
    [switch]$Preflight
)

$ErrorActionPreference = 'Stop'

# Exit codes as named constants (never bare numbers at the call sites).
$EXIT_GREEN = 0
$EXIT_RED = 1
$EXIT_UNPARSEABLE = 3
$EXIT_NO_RECIPE = 4

function Get-RecipeBlock {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string[]]$CandidateHeadings
    )

    $headingIndex = -1
    $selectedHeading = $null

    # Scan fence state once for the whole document. Both heading selection and recipe capture use
    # these results, so a heading-like line inside an earlier fenced example cannot be selected.
    $insideFence = New-Object 'bool[]' $Lines.Count
    $fenceLines = New-Object 'bool[]' $Lines.Count
    $fenceInfoStrings = New-Object 'string[]' $Lines.Count
    $fenceOpen = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $insideFence[$i] = $fenceOpen
        if ($Lines[$i] -match '^\s{0,3}```(?<Info>.*)$') {
            $fenceLines[$i] = $true
            $fenceInfoStrings[$i] = $Matches['Info'].Trim()
            $fenceOpen = -not $fenceOpen
        }
    }

    # Candidate order has priority over document order. This makes a declared preflight block win
    # even when the full recipe appears earlier in AGENTS.md.
    foreach ($candidate in $CandidateHeadings) {
        $headingPattern = '^\s{0,3}##\s*' + [regex]::Escape($candidate) + '\b'
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if (-not $insideFence[$i] -and $Lines[$i] -match $headingPattern) {
                $headingIndex = $i
                $selectedHeading = $candidate
                break
            }
        }
        if ($headingIndex -ge 0) { break }
    }

    if ($headingIndex -lt 0) {
        return [pscustomobject]@{
            HeadingFound = $false
            Heading = $null
            Commands = @()
            InfoString = $null
            FenceFound = $false
            FenceClosed = $false
            ParseError = $null
        }
    }

    $commands = @()
    $sawFence = $false
    $fenceClosed = $false
    $infoString = $null
    $parseError = $null

    for ($i = $headingIndex + 1; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if (-not $sawFence) {
            if ($fenceLines[$i] -and -not $insideFence[$i]) {
                $sawFence = $true
                $infoString = $fenceInfoStrings[$i]
                continue
            }

            # The recipe fence must be immediately adjacent to its heading. Blank lines are the
            # only permitted separation; prose, captions, and headings make the section ambiguous.
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $parseError = 'recipe fence not immediately adjacent to heading'
                break
            }
            continue
        }

        if (-not $fenceClosed) {
            if ($fenceLines[$i] -and $insideFence[$i]) {
                $fenceClosed = $true
                continue
            }

            if ($insideFence[$i]) {
                $trimmed = $line.Trim()
                if ($trimmed.Length -gt 0 -and -not $trimmed.StartsWith('#')) {
                    $commands += $trimmed
                }
            }
            continue
        }

        # Once the recipe closes, only prose is tolerated until the next heading. A second opening
        # fence in that span makes it unclear which fenced block is the declared recipe.
        if (-not $insideFence[$i] -and $line -match '^\s{0,3}#{1,6}\s') { break }
        if ($fenceLines[$i] -and -not $insideFence[$i]) {
            $parseError = 'ambiguous recipe: a second fence follows before the next heading'
            break
        }
    }

    return [pscustomobject]@{
        HeadingFound = $true
        Heading = $selectedHeading
        Commands = @($commands)
        InfoString = $infoString
        FenceFound = $sawFence
        FenceClosed = $fenceClosed
        ParseError = $parseError
    }
}

function Resolve-BashExecutable {
    $bashCommands = @(Get-Command bash.exe -CommandType Application -All -ErrorAction SilentlyContinue)
    foreach ($bashCommand in $bashCommands) {
        # System32\bash.exe is the WSL launcher, not a host-native shell. It may be first on PATH
        # even when Git-for-Windows supplies the bash.exe required by this contract.
        if ($bashCommand.Source -notmatch '(?i)(?:\\Windows\\(?:System32|Sysnative)|\\Microsoft\\WindowsApps)\\bash\.exe$') {
            return $bashCommand.Source
        }
    }

    $gitCommand = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $gitCommand) { return $null }

    $gitExecPath = (& $gitCommand.Source --exec-path 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($gitExecPath)) { return $null }

    $bashCandidates = @(
        (Join-Path $gitExecPath '..\..\..\bin\bash.exe'),
        (Join-Path $gitExecPath '..\..\bin\bash.exe'),
        (Join-Path (Split-Path -Parent $gitCommand.Source) '..\bin\bash.exe')
    )
    foreach ($candidate in $bashCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Invoke-RecipeBlock {
    param(
        [Parameter(Mandatory)]$Recipe,
        [Parameter(Mandatory)][string]$TargetWorktree
    )

    $languageTag = ''
    if (-not [string]::IsNullOrWhiteSpace($Recipe.InfoString)) {
        $languageTag = ($Recipe.InfoString -split '\s+', 2)[0].ToLowerInvariant()
    }

    $bashPath = $null
    switch ($languageTag) {
        { $_ -in @('bash', 'sh') } {
            $bashPath = Resolve-BashExecutable
            if ([string]::IsNullOrWhiteSpace($bashPath)) {
                Write-Host "[baseline] UNPARSEABLE -- '$languageTag' recipe requires bash.exe, but it was not found on PATH or beside Git-for-Windows." -ForegroundColor Red
                exit $EXIT_UNPARSEABLE
            }
            break
        }
        { $_ -in @('', 'cmd', 'bat', 'powershell', 'pwsh') } { break }
        default {
            Write-Host "[baseline] UNPARSEABLE -- unsupported fence info-string '$($Recipe.InfoString)'." -ForegroundColor Red
            exit $EXIT_UNPARSEABLE
        }
    }

    Write-Host "[baseline] running $($Recipe.Commands.Count) $($Recipe.Heading) command(s) in $TargetWorktree" -ForegroundColor Cyan
    foreach ($cmd in $Recipe.Commands) {
        Write-Host "[baseline] > $cmd" -ForegroundColor DarkGray
        switch ($languageTag) {
            { $_ -in @('bash', 'sh') } {
                $bashWorktree = $TargetWorktree.Replace("'", "'\''")
                & $bashPath -lc "cd '$bashWorktree' && $cmd"
                break
            }
            { $_ -in @('powershell', 'pwsh') } {
                $powershellWorktree = $TargetWorktree.Replace("'", "''")
                & powershell.exe -NoProfile -Command "Set-Location -LiteralPath '$powershellWorktree'; $cmd"
                break
            }
            default {
                # Back-compatible cmd.exe path. The composed string starts with `cd` (not a quote),
                # so cmd.exe does not strip the quotes around the worktree path.
                & cmd.exe /c "cd /d `"$TargetWorktree`" && $cmd"
                break
            }
        }

        $code = $LASTEXITCODE
        if ($code -ne 0) {
            Write-Host "[baseline] RED -- command failed (exit $code): $cmd" -ForegroundColor Red
            exit $EXIT_RED
        }
    }

    Write-Host '[baseline] GREEN -- all verify commands passed.' -ForegroundColor Green
    exit $EXIT_GREEN
}

if (-not (Test-Path -LiteralPath $Worktree -PathType Container)) {
    Write-Host "[baseline] worktree does not exist: $Worktree" -ForegroundColor Red
    exit $EXIT_RED
}

if ($Full -and $Preflight) {
    Write-Host '[baseline] UNPARSEABLE -- choose either -Full or -Preflight, not both.' -ForegroundColor Red
    exit $EXIT_UNPARSEABLE
}

$agentsPath = Join-Path $Worktree 'AGENTS.md'
if (-not (Test-Path -LiteralPath $agentsPath -PathType Leaf)) {
    Write-Host "[baseline] NO_RECIPE -- no AGENTS.md in $Worktree." -ForegroundColor DarkGray
    exit $EXIT_NO_RECIPE
}

$candidateHeadings = @('Verify commands')
if ($Preflight) {
    $candidateHeadings = @('Preflight commands', 'Verify commands')
}

$lines = [System.IO.File]::ReadAllLines($agentsPath)
$recipe = Get-RecipeBlock -Lines $lines -CandidateHeadings $candidateHeadings
if (-not $recipe.HeadingFound) {
    Write-Host "[baseline] NO_RECIPE -- AGENTS.md has none of the requested recipe headings: $($candidateHeadings -join ', ')." -ForegroundColor DarkGray
    exit $EXIT_NO_RECIPE
}

if (-not [string]::IsNullOrWhiteSpace($recipe.ParseError)) {
    Write-Host "[baseline] UNPARSEABLE -- '## $($recipe.Heading)': $($recipe.ParseError)." -ForegroundColor Red
    exit $EXIT_UNPARSEABLE
}

if ($recipe.FenceFound -and -not $recipe.FenceClosed) {
    Write-Host "[baseline] UNPARSEABLE -- '## $($recipe.Heading)' recipe fence is not closed before EOF." -ForegroundColor Red
    exit $EXIT_UNPARSEABLE
}

if (-not $recipe.FenceFound -or $recipe.Commands.Count -eq 0) {
    Write-Host "[baseline] UNPARSEABLE -- '## $($recipe.Heading)' found but no runnable command block follows it." -ForegroundColor Red
    exit $EXIT_UNPARSEABLE
}

Invoke-RecipeBlock -Recipe $recipe -TargetWorktree $Worktree
