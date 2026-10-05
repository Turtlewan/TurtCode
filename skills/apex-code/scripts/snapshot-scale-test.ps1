# Regression for the build-dispatch pre-launch hang: keep both the 600-leaf ?? case (full-content
# SHA-256 in-process) and the committed-.gitignore 600-file !! collapsed-directory case (recursive
# metadata digest). Neither may spawn git per untracked/cache file; both must detect an internal
# rename and snapshot in <15s. The ignored case retains the path-sensitive directory fingerprint.

$ErrorActionPreference = 'Stop'
$scope = Join-Path $PSScriptRoot 'codex-scope-check.ps1'
$tempRoot = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Temp'))
$parent = Join-Path $tempRoot ('snapscale-' + [guid]::NewGuid().ToString('N'))
$previousGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
$previousApexStateDir = $env:APEX_STATE_DIR
$fail = 0
$suiteExit = 1

function Check($Label, [bool]$Condition, $Detail) {
    $mark = if ($Condition) { 'ok  ' } else { 'FAIL' }
    $color = if ($Condition) { 'Green' } else { 'Red' }
    if (-not $Condition) { $script:fail++ }
    Write-Host ("  {0}  {1} -- {2}" -f $mark, $Label, $Detail) -ForegroundColor $color
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $launchException = $null
    $output = @()
    try {
        $global:LASTEXITCODE = -987654
        try { $output = @(& git -C $repo @GitArgs 2>&1) }
        catch { $launchException = $_.Exception }
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    if ($launchException -or $exitCode -ne 0) {
        throw "Fixture git $($GitArgs -join ' ') failed (exit $exitCode): $launchException $($output -join ' ')"
    }
    return ,$output
}

function Invoke-Scope {
    param([string]$Mode, [string]$Task)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = -987654
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scope $Mode -Worktree $repo -Task $Task -StateDirectory $state 2>&1)
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join [Environment]::NewLine) }
}

try {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $env:APEX_STATE_DIR = Join-Path $parent 'apex-state'
    $env:GIT_CONFIG_GLOBAL = Join-Path $parent 'gitconfig'
    $ignoreFile = Join-Path $parent 'global-ignore'
    [System.IO.File]::WriteAllText($ignoreFile, '', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($env:GIT_CONFIG_GLOBAL,
        ("[core]`n    excludesFile = {0}`n" -f ($ignoreFile -replace '\\', '/')),
        [System.Text.UTF8Encoding]::new($false))

    Write-Host "`n=== snapshot scale (600 ?? leaves and 600-file collapsed !! directory) ===" -ForegroundColor Cyan
    foreach ($kind in @('untracked', 'ignored')) {
        $repo = Join-Path $parent ($kind + '-repo')
        $state = Join-Path $parent ($kind + '-state')
        New-Item -ItemType Directory -Force -Path $repo | Out-Null
        Invoke-Git init -q | Out-Null
        Invoke-Git config user.email 'scale-test@example.invalid' | Out-Null
        Invoke-Git config user.name 'Snapshot Scale Test' | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo 'app.py'), "x=1`n", [System.Text.Encoding]::ASCII)
        if ($kind -ceq 'ignored') {
            [System.IO.File]::WriteAllText((Join-Path $repo '.gitignore'), "/buildcache/`n", [System.Text.Encoding]::ASCII)
        }
        Invoke-Git add -A | Out-Null
        Invoke-Git commit -q -m init | Out-Null
        $big = Join-Path $repo 'buildcache'
        New-Item -ItemType Directory -Force -Path $big | Out-Null
        for ($i = 0; $i -lt 600; $i++) {
            [System.IO.File]::WriteAllText((Join-Path $big "f$i.tmp"), "data$i")
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $snapshot = Invoke-Scope -Mode '-Snapshot' -Task $kind
        $sw.Stop()
        Check "$kind snapshot completes" ($snapshot.ExitCode -eq 0) $snapshot.Output
        Check "$kind snapshot <15s" ($sw.Elapsed.TotalSeconds -lt 15) ("{0:N2}s" -f $sw.Elapsed.TotalSeconds)
        if ($snapshot.ExitCode -ne 0) { continue }

        $snapshotPath = Join-Path $state ("scope-$kind.snapshot.json")
        $snapshotText = [System.IO.File]::ReadAllText($snapshotPath)
        $snap = $snapshotText | ConvertFrom-Json
        if ($kind -ceq 'untracked') {
            $rawLeaves = @($snap.states.PSObject.Properties | Where-Object { $_.Value -match '^work:raw:[0-9a-f]{64} index:-$' })
            Check '600 ?? leaves have in-process raw hashes' (@($snap.dirty).Count -eq 600 -and $rawLeaves.Count -eq 600) ("{0} paths, {1} raw hashes" -f @($snap.dirty).Count, $rawLeaves.Count)
        } else {
            Check '600 ignored files stay one !! directory row' (@($snap.dirty).Count -eq 1 -and $snap.statuses.'buildcache/' -ceq '!!' -and $snap.states.'buildcache/' -match '^work:dir:[0-9a-f]{64} index:-$') ([string]$snap.states.'buildcache/')
        }

        $unchanged = Invoke-Scope -Mode '-Check' -Task $kind
        Check "$kind unchanged tree is in scope" ($unchanged.ExitCode -eq 0) $unchanged.Output
        # A successful Check consumes evidence; restore it before testing the deterministic rename.
        [System.IO.File]::WriteAllText($snapshotPath, $snapshotText, [System.Text.UTF8Encoding]::new($false))
        Rename-Item -LiteralPath (Join-Path $big 'f0.tmp') -NewName 'renamed0.tmp'
        $renamed = Invoke-Scope -Mode '-Check' -Task $kind
        Check "$kind rename inside directory is detected" ($renamed.ExitCode -eq 1 -and $renamed.Output -match 'buildcache') $renamed.Output
    }
    $suiteExit = if ($fail -eq 0) { 0 } else { 1 }
} catch {
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    $suiteExit = 1
} finally {
    if ($null -eq $previousGitConfigGlobal) { Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue }
    else { $env:GIT_CONFIG_GLOBAL = $previousGitConfigGlobal }
    if ($null -eq $previousApexStateDir) { Remove-Item Env:APEX_STATE_DIR -ErrorAction SilentlyContinue }
    else { $env:APEX_STATE_DIR = $previousApexStateDir }
    $cleanupTarget = [System.IO.Path]::GetFullPath($parent)
    if (-not $cleanupTarget.StartsWith($tempRoot.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe fixture cleanup target: $cleanupTarget"
    }
    if (Test-Path -LiteralPath $cleanupTarget) { Remove-Item -LiteralPath $cleanupTarget -Recurse -Force }
}

if ($suiteExit -ne 0) { Write-Host "$fail snapshot-scale check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'ALL SNAPSHOT-SCALE TESTS PASS.' -ForegroundColor Green
exit 0
