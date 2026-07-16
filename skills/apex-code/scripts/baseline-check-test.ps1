# Tests for the M2a baseline-green gate: apex-baseline-check.ps1, the pre-commit hook, and the
# installer. Fully isolated -- every case runs in a throwaway temp repo; nothing touches the live
# harness, the live ledger, or ~/artemis. Unlike the older dispatch-test `Check` (which only PRINTS
# 'FAIL'), this runner ACCUMULATES failures and exits non-zero, so it is usable as a real gate.

$ErrorActionPreference = 'Stop'

$checker   = Join-Path $PSScriptRoot 'apex-baseline-check.ps1'
$installer = Join-Path $PSScriptRoot 'install-baseline-hook.ps1'
foreach ($p in @($checker, $installer)) { if (-not (Test-Path $p)) { throw "missing under test: $p" } }

# Native git (and hooks git forwards) write progress to stderr. Under EAP='Stop' PowerShell turns any
# native stderr line into a TERMINATING NativeCommandError, aborting the suite. Drop to 'Continue' --
# real .NET exceptions still terminate; git results are gated on $LASTEXITCODE, unaffected.
$ErrorActionPreference = 'Continue'

$root = Join-Path $env:TEMP ("apex-baseline-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $root | Out-Null

$script:fail = 0
function Check($label, $cond, $detail) {
    $mark = if ($cond) { 'ok  ' } else { 'FAIL' }
    $col  = if ($cond) { 'Green' } else { 'Red' }
    if (-not $cond) { $script:fail++ }
    Write-Host ("  {0}  {1,-48} {2}" -f $mark, $label, $detail) -ForegroundColor $col
}
function Write-File($path, $text) { [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false)) }

# A repo with a standard '## Verify commands' block from an array of command lines.
# $recipeLines = $null -> no heading; @() -> heading but no fenced block (unparseable).
function New-Repo($name, $recipeLines) {
    $repo = Join-Path $root $name
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    if ($null -ne $recipeLines) {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('# AGENTS'); [void]$sb.AppendLine('## Verify commands (test recipe)')
        if ($recipeLines.Count -gt 0) {
            [void]$sb.AppendLine('```'); foreach ($l in $recipeLines) { [void]$sb.AppendLine($l) }; [void]$sb.AppendLine('```')
        }
        Write-File (Join-Path $repo 'AGENTS.md') $sb.ToString()
    }
    return $repo
}
# A repo with an arbitrary AGENTS.md body (for parser edge cases).
function New-RawRepo($name, $agentsText) {
    $repo = Join-Path $root $name
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    if ($null -ne $agentsText) { Write-File (Join-Path $repo 'AGENTS.md') $agentsText }
    return $repo
}
function Invoke-Checker($repo, [switch]$Preflight) {
    $mode = if ($Preflight) { '-Preflight' } else { '-Full' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker $mode -Worktree $repo *> $null
    return $LASTEXITCODE
}

Write-Host "`n=== apex-baseline-check.ps1 ===" -ForegroundColor Cyan
Check 'green recipe exits 0' ((Invoke-Checker (New-Repo 'green' @('echo baseline-ok'))) -eq 0) 'echo -> 0'
Check 'red recipe (-Full runs all lines) exits 1' ((Invoke-Checker (New-Repo 'red' @('echo lint-ok','exit 1'))) -eq 1) 'later line fails'
Check 'no AGENTS.md file (norecipe) -> NO_RECIPE 4' ((Invoke-Checker (New-Repo 'norecipe' $null)) -eq 4) 'missing file -> 4'
$noAg = Join-Path $root 'noagents'; New-Item -ItemType Directory -Force -Path $noAg | Out-Null
Check 'no AGENTS.md file -> NO_RECIPE 4' ((Invoke-Checker $noAg) -eq 4) 'missing file -> 4'
$headingless = New-RawRepo 'headingless' "# AGENTS`n## Notes`n`nnothing here"
Check 'AGENTS.md without Verify heading -> NO_RECIPE 4' ((Invoke-Checker $headingless) -eq 4) 'heading absent -> 4'
Check 'heading, no fenced block -> exit 3' ((Invoke-Checker (New-Repo 'unparseable' @())) -eq 3) 'fail closed'

# Fail-open guards (Codex review): a non-level-2 heading before the fence must NOT let a later
# unrelated block become the recipe; an indented-but-valid heading must still be found.
$fence = '```'
$rawHeadingBeforeFence = @('# AGENTS', '## Verify commands', '### Notes', $fence, ' echo should-not-run', $fence) -join "`n"
Check 'heading before fence -> exit 3 (no fall-through)' ((Invoke-Checker (New-RawRepo 'heading-before' $rawHeadingBeforeFence)) -eq 3) 'no unrelated block grabbed'
$rawIndented = @('# AGENTS', '   ## Verify commands', $fence, ' echo ok', $fence) -join "`n"
Check 'indented (<=3sp) heading still found' ((Invoke-Checker (New-RawRepo 'indented' $rawIndented)) -eq 0) 'not a silent skip'

# cwd is -Worktree, not the caller's CWD.
$r = New-Repo 'cwd' @('if not exist cwd-marker.txt exit 1'); Write-File (Join-Path $r 'cwd-marker.txt') 'x'
Push-Location $env:TEMP; try { $cwdExit = Invoke-Checker $r } finally { Pop-Location }
Check 'recipe runs in -Worktree not caller CWD' ($cwdExit -eq 0) 'marker found -> 0'

# Fence info strings select the shell. Each command uses syntax that fails in the other shells.
$rawBash = @('# AGENTS', '## Verify commands', '```bash', '[ -n "$BASH_VERSION" ]', '```') -join "`n"
Check 'bash fence runs bash-only syntax' ((Invoke-Checker (New-RawRepo 'shell-bash' $rawBash)) -eq 0) 'bash test -> 0'
$rawPowerShell = @('# AGENTS', '## Verify commands', '```powershell', 'if (-not $PSVersionTable) { exit 1 }', '```') -join "`n"
Check 'powershell fence runs PowerShell-only syntax' ((Invoke-Checker (New-RawRepo 'shell-powershell' $rawPowerShell)) -eq 0) 'PowerShell conditional -> 0'
$rawCmd = @('# AGENTS', '## Verify commands', $fence, 'if "%CD%"=="" exit 1', $fence) -join "`n"
Check 'unlabeled fence runs cmd-only syntax' ((Invoke-Checker (New-RawRepo 'shell-cmd' $rawCmd)) -eq 0) 'cmd conditional -> 0'

# -Preflight prefers its dedicated block, falls back to Verify, and fails closed on an empty block.
$preflightRepo = New-RawRepo 'preflight-dedicated' (@(
    '# AGENTS', '## Verify commands', $fence, 'echo verify>verify-marker.txt', $fence,
    '## Preflight commands', $fence, 'echo preflight>preflight-marker.txt', $fence
) -join "`n")
$preflightExit = Invoke-Checker $preflightRepo -Preflight
$dedicatedRan = (Test-Path (Join-Path $preflightRepo 'preflight-marker.txt')) -and
    -not (Test-Path (Join-Path $preflightRepo 'verify-marker.txt'))
Check '-Preflight runs dedicated Preflight block' (($preflightExit -eq 0) -and $dedicatedRan) 'preflight marker only'
$preflightFallback = New-Repo 'preflight-fallback' @('echo fallback>fallback-marker.txt')
$fallbackExit = Invoke-Checker $preflightFallback -Preflight
Check '-Preflight falls back to Verify block' (($fallbackExit -eq 0) -and (Test-Path (Join-Path $preflightFallback 'fallback-marker.txt'))) 'fallback marker -> 0'
$emptyPreflight = New-RawRepo 'preflight-empty' (@(
    '# AGENTS', '## Preflight commands', $fence, $fence,
    '## Verify commands', $fence, 'echo should-not-run>verify-marker.txt', $fence
) -join "`n")
Check 'empty Preflight block -> exit 3' ((Invoke-Checker $emptyPreflight -Preflight) -eq 3) 'no runnable preflight command'

# Heading search ignores fenced examples; malformed and ambiguous recipe fences fail closed.
$decoyRepo = New-RawRepo 'decoy-heading' (@(
    '# AGENTS', '## Example', $fence, '## Verify commands', 'echo decoy>decoy-marker.txt', $fence,
    '## Verify commands', $fence, 'echo real>real-marker.txt', $fence
) -join "`n")
$decoyExit = Invoke-Checker $decoyRepo
$realOnly = (Test-Path (Join-Path $decoyRepo 'real-marker.txt')) -and
    -not (Test-Path (Join-Path $decoyRepo 'decoy-marker.txt'))
Check 'fenced decoy heading ignored; real recipe runs' (($decoyExit -eq 0) -and $realOnly) 'real marker only'
$unclosed = @('# AGENTS', '## Verify commands', $fence, 'echo should-not-run') -join "`n"
Check 'unclosed recipe fence -> exit 3' ((Invoke-Checker (New-RawRepo 'unclosed-fence' $unclosed)) -eq 3) 'EOF before close'

$captioned = @(
    '# AGENTS', '## Verify commands', 'Example:', $fence, 'echo decoy', $fence,
    $fence, 'echo real', $fence
) -join "`n"
Check 'caption between heading and fences -> exit 3' ((Invoke-Checker (New-RawRepo 'captioned-fences' $captioned)) -eq 3) 'adjacency enforced'
$twoFences = @(
    '# AGENTS', '## Verify commands', $fence, 'echo first', $fence,
    $fence, 'echo second', $fence, '## Notes'
) -join "`n"
Check 'two bare fences before next heading -> exit 3' ((Invoke-Checker (New-RawRepo 'two-fences' $twoFences)) -eq 3) 'single-fence enforced'
$blankAdjacent = @('# AGENTS', '## Verify commands', '', '   ', $fence, 'echo ok', $fence) -join "`n"
Check 'blank lines before one fence still run' ((Invoke-Checker (New-RawRepo 'blank-adjacent' $blankAdjacent)) -eq 0) 'blank adjacency -> 0'

Write-Host "`n=== pre-commit hook (STAGED-snapshot) + installer ===" -ForegroundColor Cyan

# Build a git repo whose recipe checks data.txt for "GOOD"; seed data.txt=GOOD and install the hook.
function New-DataRepo($name) {
    $repo = New-Repo $name @('findstr /c:"GOOD" data.txt')
    Push-Location $repo
    try {
        git init -q; git config user.email 't@t.t'; git config user.name 't'; git config core.autocrlf false
        Write-File (Join-Path $repo 'data.txt') 'GOOD'
        git add -A; git commit -q -m init
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Repo $repo *> $null
    } finally { Pop-Location }
    return $repo
}

# Installer put the hook where git runs it.
$repo = New-DataRepo 'hook-install'
$hp = (& git -C $repo rev-parse --git-path hooks).Trim(); if (-not [System.IO.Path]::IsPathRooted($hp)) { $hp = Join-Path $repo $hp }
Check 'installer wrote pre-commit at git hooks path' (Test-Path -LiteralPath (Join-Path $hp 'pre-commit')) 'present'

# Basic green: staged GOOD -> commit succeeds.
$repo = New-DataRepo 'hook-green'
Push-Location $repo; try {
    Write-File (Join-Path $repo 'data.txt') 'GOOD-again'; Write-File (Join-Path $repo 'note.txt') 'x'
    # keep recipe passing: data.txt still contains GOOD
    Write-File (Join-Path $repo 'data.txt') 'GOOD2'; git add data.txt note.txt
    git commit -q -m green 2>$null; $greenOk = ($LASTEXITCODE -eq 0)
} finally { Pop-Location }
Check 'green staged commit succeeds' $greenOk 'hook allows'

# Basic red: staged BAD -> commit blocked.
$repo = New-DataRepo 'hook-red'
Push-Location $repo; try {
    Write-File (Join-Path $repo 'data.txt') 'BAD'; git add data.txt
    git commit -q -m red 2>$null; $redBlocked = ($LASTEXITCODE -ne 0)
} finally { Pop-Location }
Check 'red staged commit is blocked' $redBlocked 'hook exits non-zero'

# FALSE-GREEN guard (Codex BLOCK): stage BAD, then edit working copy back to GOOD. index != working
# on the SAME file -> the hook must REFUSE up front, never commit the red index behind a green worktree.
$repo = New-DataRepo 'hook-false-green'
Push-Location $repo; try {
    Write-File (Join-Path $repo 'data.txt') 'BAD'; git add data.txt      # staged = red
    Write-File (Join-Path $repo 'data.txt') 'GOOD'                       # working = green (unstaged)
    git commit -q -m sneak 2>$null; $falseGreenBlocked = ($LASTEXITCODE -ne 0)
    $stagedStillBad = ((git show ":data.txt") -match 'BAD')
} finally { Pop-Location }
Check 'false-green (staged red, working green) is BLOCKED' ($falseGreenBlocked -and $stagedStillBad) 'overlap guard, not committed'

# STAGED-snapshot proven + no false-red: commit a clean staged file while an UNRELATED file is dirty
# (would fail the recipe on the working tree). The hook stashes the dirty file, verifies the staged
# tree (green), commits, and restores the dirty file.
$repo = New-DataRepo 'hook-staged'
Push-Location $repo; try {
    Write-File (Join-Path $repo 'other.txt') 'unrelated'; git add other.txt   # staged, green
    Write-File (Join-Path $repo 'data.txt') 'BAD'                              # unstaged dirt (would be red on worktree)
    git commit -q -m "clean staged despite dirty tree" 2>$null; $stagedCommitOk = ($LASTEXITCODE -eq 0)
    $dirtyRestored = ([System.IO.File]::ReadAllText((Join-Path $repo 'data.txt')) -eq 'BAD')
} finally { Pop-Location }
Check 'staged-snapshot: clean commit ok despite dirty tree' $stagedCommitOk 'no false-red'
Check 'unstaged dirt restored after commit' $dirtyRestored 'stash/pop clean (no overlap)'

# Symmetric case: RED staged WITH unrelated untracked dirt -> the stash path must still block, and
# the dirt must be restored (proves blocking goes through stash, not only the direct no-stash path).
$repo = New-DataRepo 'hook-red-dirty'
Push-Location $repo; try {
    Write-File (Join-Path $repo 'data.txt') 'BAD'; git add data.txt        # staged red
    Write-File (Join-Path $repo 'scratch.txt') 'wip'                        # unrelated untracked dirt
    git commit -q -m "red with dirt" 2>$null; $redDirtyBlocked = ($LASTEXITCODE -ne 0)
    $dirtKept = (Test-Path (Join-Path $repo 'scratch.txt'))
} finally { Pop-Location }
Check 'red staged + dirty tree still blocked, dirt kept' ($redDirtyBlocked -and $dirtKept) 'stash path blocks + restores'

# Installer: refuse a differing hook without -Force; with -Force back up AND actually overwrite.
$repo = New-Repo 'hook-backup' @('echo ok')
Push-Location $repo; try {
    git init -q; git config user.email 't@t.t'; git config user.name 't'
    $hp2 = (& git -C $repo rev-parse --git-path hooks).Trim(); if (-not [System.IO.Path]::IsPathRooted($hp2)) { $hp2 = Join-Path $repo $hp2 }
    New-Item -ItemType Directory -Force -Path $hp2 | Out-Null
    Write-File (Join-Path $hp2 'pre-commit') "#!/bin/sh`necho pre-existing"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Repo $repo *> $null; $refused = ($LASTEXITCODE -ne 0)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Repo $repo -Force *> $null; $forcedOk = ($LASTEXITCODE -eq 0)
    $bak = Join-Path $hp2 'pre-commit.bak'
    $bakHasOld = (Test-Path $bak) -and ([System.IO.File]::ReadAllText($bak) -match 'pre-existing')
    $liveIsTemplate = ([System.IO.File]::ReadAllText((Join-Path $hp2 'pre-commit')) -match 'apex baseline hook')
} finally { Pop-Location }
Check 'installer refuses a differing hook without -Force' $refused 'exit non-zero'
Check 'installer -Force backs up old AND installs new' ($forcedOk -and $bakHasOld -and $liveIsTemplate) 'both, not one'

# Linked worktree: the hook git ACTUALLY runs there blocks a red commit (execution, not just presence).
$repo = New-Repo 'wt-main' @('findstr /c:"GOOD" data.txt')
Push-Location $repo; try {
    git init -q; git config user.email 't@t.t'; git config user.name 't'
    Write-File (Join-Path $repo 'data.txt') 'GOOD'; git add -A; git commit -q -m init
    $wt = Join-Path $root 'wt-linked'; git worktree add -q $wt 2>$null
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Repo $wt *> $null; $wtInstallOk = ($LASTEXITCODE -eq 0)
} finally { Pop-Location }
Push-Location $wt; try {
    Write-File (Join-Path $wt 'data.txt') 'BAD'; git add data.txt
    git commit -q -m "red in worktree" 2>$null; $wtBlocked = ($LASTEXITCODE -ne 0)
} finally { Pop-Location }
Check 'installed hook EXECUTES in a linked worktree' ($wtInstallOk -and $wtBlocked) 'red commit blocked there'

# core.hooksPath: installer targets the configured dir, not a hardcoded .git/hooks.
$repo = New-Repo 'hookspath' @('echo ok')
Push-Location $repo; try {
    git init -q; git config user.email 't@t.t'; git config user.name 't'
    $custom = Join-Path $repo '.customhooks'; git config core.hooksPath $custom
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Repo $repo *> $null
    $inCustom = Test-Path -LiteralPath (Join-Path $custom 'pre-commit')
} finally { Pop-Location }
Check 'installer honours core.hooksPath' $inCustom 'not a hardcoded .git/hooks'

try { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue } catch {}
Write-Host ""
if ($script:fail -gt 0) { Write-Host "$($script:fail) check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "ALL BASELINE-CHECK TESTS PASS." -ForegroundColor Green
exit 0
