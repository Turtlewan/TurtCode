# install-baseline-hook.ps1 (M2a)
#
# Installs the baseline-green pre-commit hook (templates/pre-commit-baseline) into a target git repo.
# It targets the hook git ACTUALLY runs: the directory from `git rev-parse --git-path hooks`, which is
# correct for a normal repo, a LINKED WORKTREE (where .git is a file pointing elsewhere), and a repo
# with core.hooksPath set. A differing existing hook is preserved to pre-commit.bak and only
# overwritten with -Force -- .git/hooks is not version-controlled, so a silent overwrite is unrecoverable.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repo,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Repo -PathType Container)) {
    throw "Repo does not exist: $Repo"
}

$template = Join-Path $PSScriptRoot '..\templates\pre-commit-baseline'
if (-not (Test-Path -LiteralPath $template -PathType Leaf)) {
    throw "Hook template not found: $template"
}

# Ask git where hooks live -- honours linked worktrees and core.hooksPath, which a hardcoded
# "<repo>/.git/hooks" does not (in a linked worktree .git is a FILE, not a directory).
$hooksRel = & git -C $Repo rev-parse --git-path hooks 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($hooksRel)) {
    throw "Not a git repository (or git unavailable): $Repo"
}
# --git-path returns a path relative to the repo working directory unless already absolute.
$hooksDir = if ([System.IO.Path]::IsPathRooted($hooksRel)) { $hooksRel } else { Join-Path $Repo $hooksRel }
[System.IO.Directory]::CreateDirectory($hooksDir) | Out-Null

$target = Join-Path $hooksDir 'pre-commit'
# Normalise to LF, no BOM -- git's sh must read it as a shell script.
$newContent = ([System.IO.File]::ReadAllText($template)) -replace "`r`n", "`n"

if (Test-Path -LiteralPath $target -PathType Leaf) {
    $existing = [System.IO.File]::ReadAllText($target)
    if (($existing -replace "`r`n", "`n") -eq $newContent) {
        Write-Host "[install-hook] already installed (identical) at $target" -ForegroundColor DarkGray
        exit 0
    }
    if (-not $Force) {
        Write-Host "[install-hook] a DIFFERING pre-commit hook already exists at $target." -ForegroundColor Yellow
        Write-Host "[install-hook] re-run with -Force to overwrite (the existing hook is backed up first), or merge by hand." -ForegroundColor Yellow
        exit 1
    }
    # -Force: preserve the old hook before overwriting -- never destroy it silently.
    Copy-Item -LiteralPath $target -Destination "$target.bak" -Force
    Write-Host "[install-hook] existing hook backed up to $target.bak" -ForegroundColor Yellow
}

[System.IO.File]::WriteAllText($target, $newContent, [System.Text.UTF8Encoding]::new($false))

# Mark executable where the filesystem honours it (harmless on Windows; needed on POSIX checkouts).
$chmod = Get-Command chmod -ErrorAction SilentlyContinue
if ($chmod) { & $chmod.Source '+x' $target 2>$null | Out-Null }

Write-Host "[install-hook] installed baseline pre-commit hook at $target" -ForegroundColor Green
exit 0
