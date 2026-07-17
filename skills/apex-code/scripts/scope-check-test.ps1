[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$checkerPath = Join-Path -Path $PSScriptRoot -ChildPath 'codex-scope-check.ps1'
$testRoot = Join-Path -Path $env:TEMP -ChildPath ("apex-scope-check-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$powerShellPath = @(Get-Command powershell.exe -CommandType Application -ErrorAction Stop)[0].Source
$gitPath = @(Get-Command git.exe -CommandType Application -ErrorAction Stop)[0].Source
$failureCount = 0
$assertionCount = 0
$suiteExitCode = 1

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    $script:assertionCount++
    if ($Condition) {
        Write-Output ("PASS {0} -- {1}" -f $Name, $Detail)
        return
    }

    # A printed FAIL used to certify the suite because the runner always exited zero.
    $script:failureCount++
    Write-Output ("FAIL {0} -- {1}" -f $Name, $Detail)
}

function Invoke-TestGit {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string[]]$GitArguments
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = -987654
        $output = @(& $gitPath -C $RepoPath @GitArguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($exitCode -ne 0) {
        throw "Test fixture git command failed (exit $exitCode): git -C $RepoPath $($GitArguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }
}

function New-TestRepo {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Files = @('src/a.py')
    )

    $repoPath = Join-Path -Path $testRoot -ChildPath $Name
    New-Item -ItemType Directory -Force -Path $repoPath | Out-Null
    Invoke-TestGit -RepoPath $repoPath -GitArguments @('init', '-q')
    Invoke-TestGit -RepoPath $repoPath -GitArguments @('config', 'user.email', 'scope-test@example.invalid')
    Invoke-TestGit -RepoPath $repoPath -GitArguments @('config', 'user.name', 'Scope Check Test')

    foreach ($relativePath in $Files) {
        $fullPath = Join-Path -Path $repoPath -ChildPath $relativePath
        $parentPath = Split-Path -Parent $fullPath
        New-Item -ItemType Directory -Force -Path $parentPath | Out-Null
        [System.IO.File]::WriteAllText($fullPath, "orig`r`n", [System.Text.Encoding]::ASCII)
    }

    Invoke-TestGit -RepoPath $repoPath -GitArguments @('add', '-A')
    Invoke-TestGit -RepoPath $repoPath -GitArguments @('commit', '-q', '-m', 'init')
    return $repoPath
}

function Invoke-ScopeCheck {
    param(
        [Parameter(Mandatory = $true)][string[]]$CheckerArguments,
        [string]$PathOverride = ''
    )

    $previousPath = $env:PATH
    $previousPreference = $ErrorActionPreference
    if ($PathOverride) { $env:PATH = $PathOverride }
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = -987654
        $output = @(& $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $checkerPath @CheckerArguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
        $env:PATH = $previousPath
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output = ($output -join [Environment]::NewLine)
    }
}

function New-FailingGitShim {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FailCommand
    )

    $shimPath = Join-Path -Path $testRoot -ChildPath $Name
    New-Item -ItemType Directory -Force -Path $shimPath | Out-Null
    $shimFile = Join-Path -Path $shimPath -ChildPath 'git.cmd'
    $shim = @(
        '@echo off'
        (('if /I "%%~3"=="{0}" exit /b 42' -f $FailCommand) -replace '%%', '%')
        ('"{0}" %*' -f $gitPath)
        'exit /b %ERRORLEVEL%'
    )
    [System.IO.File]::WriteAllLines($shimFile, [string[]]$shim, [System.Text.Encoding]::ASCII)
    return $shimPath + [System.IO.Path]::PathSeparator + $env:PATH
}

try {
    if (-not (Test-Path -LiteralPath $checkerPath -PathType Leaf)) {
        throw "Scope checker was not found at '$checkerPath'."
    }
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

    # Preserve the old ad hoc scenario as a real accumulated test case.
    $mangledRepo = New-TestRepo -Name 'mangled-allowlist' -Files @('src/a.py', 'src/b.py', 'src/c.py')
    $mangledState = Join-Path -Path $testRoot -ChildPath 'state-mangled'
    $snapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $mangledRepo, '-Task', 'mangled', '-StateDirectory', $mangledState)
    Assert-True -Name 'mangled snapshot succeeds' -Condition ($snapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $snapshot.ExitCode)
    foreach ($relativePath in @('src/a.py', 'src/b.py', 'src/c.py')) {
        Add-Content -LiteralPath (Join-Path $mangledRepo $relativePath) -Value 'REAL WORK' -Encoding ASCII
    }
    $mangled = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $mangledRepo, '-Task', 'mangled', '-StateDirectory', $mangledState, '-Authorized', 'srcc/a.py,srcc/b.py,srcc/c.py')
    Assert-True -Name 'mangled allowlist is refused' -Condition ($mangled.ExitCode -eq 66) -Detail ("expected 66, got {0}" -f $mangled.ExitCode)
    foreach ($relativePath in @('src/a.py', 'src/b.py', 'src/c.py')) {
        $survived = (Get-Content -LiteralPath (Join-Path $mangledRepo $relativePath) -Raw) -match 'REAL WORK'
        Assert-True -Name ("{0} real work survives refusal" -f $relativePath) -Condition $survived -Detail 'work was not reverted'
    }

    # Two modes previously ran the first branch, overwrote evidence, and returned success.
    $modeRepo = New-TestRepo -Name 'mode-exclusion'
    $modeState = Join-Path -Path $testRoot -ChildPath 'state-mode'
    $modeResult = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Check', '-Worktree', $modeRepo, '-Task', 'mode-exclusion', '-StateDirectory', $modeState)
    Assert-True -Name 'mode switches are mutually exclusive' -Condition ($modeResult.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $modeResult.ExitCode)
    Assert-True -Name 'mode refusal has a diagnostic' -Condition ($modeResult.Output -match 'mutually exclusive|exactly one mode') -Detail $modeResult.Output

    # A failed hash used to become the same '-' sentinel as an absent file and report host work clean.
    $hashRepo = New-TestRepo -Name 'hash-failure'
    Add-Content -LiteralPath (Join-Path $hashRepo 'src/a.py') -Value 'HOST WORK' -Encoding ASCII
    $hashState = Join-Path -Path $testRoot -ChildPath 'state-hash'
    $hashPath = New-FailingGitShim -Name 'shim-hash' -FailCommand 'hash-object'
    $hashResult = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $hashRepo, '-Task', 'hash-failure', '-StateDirectory', $hashState) -PathOverride $hashPath
    Assert-True -Name 'git hash-object error fails closed' -Condition ($hashResult.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $hashResult.ExitCode)
    Assert-True -Name 'git hash-object error has a diagnostic' -Condition ($hashResult.Output -match 'git hash-object.*failed|failed.*git hash-object') -Detail $hashResult.Output

    # The index half of path state must fail closed under the same rule.
    $indexRepo = New-TestRepo -Name 'index-failure'
    Add-Content -LiteralPath (Join-Path $indexRepo 'src/a.py') -Value 'HOST WORK' -Encoding ASCII
    $indexState = Join-Path -Path $testRoot -ChildPath 'state-index'
    $indexPath = New-FailingGitShim -Name 'shim-index' -FailCommand 'ls-files'
    $indexResult = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $indexRepo, '-Task', 'index-failure', '-StateDirectory', $indexState) -PathOverride $indexPath
    Assert-True -Name 'git ls-files error fails closed' -Condition ($indexResult.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $indexResult.ExitCode)
    Assert-True -Name 'git ls-files error has a diagnostic' -Condition ($indexResult.Output -match 'git ls-files.*failed|failed.*git ls-files') -Detail $indexResult.Output

    if ($failureCount -gt 0) {
        Write-Output ("FAILED -- {0} of {1} scope-check assertions failed." -f $failureCount, $assertionCount)
        $suiteExitCode = 1
    }
    else {
        Write-Output ("PASS -- all {0} scope-check assertions passed." -f $assertionCount)
        $suiteExitCode = 0
    }
}
catch {
    Write-Output ("FATAL -- scope-check test suite could not complete: {0}" -f $_.Exception.Message)
    $suiteExitCode = 1
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        try {
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
        }
        catch {
            Write-Output ("FATAL -- could not remove temporary scope-check fixtures: {0}" -f $_.Exception.Message)
            $suiteExitCode = 1
        }
    }
}

exit $suiteExitCode
