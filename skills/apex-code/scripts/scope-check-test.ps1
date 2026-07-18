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

function Assert-WrittenPaths {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Expected
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Assert-True -Name $Name -Condition $false -Detail ("written-paths file does not exist: {0}" -f $Path)
        return
    }

    [string[]]$actual = [System.IO.File]::ReadAllLines($Path)
    [string[]]$expectedSorted = @($Expected | Sort-Object -Unique)
    $equal = $actual.Count -eq $expectedSorted.Count
    if ($equal) {
        for ($i = 0; $i -lt $actual.Count; $i++) {
            if ($actual[$i] -cne $expectedSorted[$i]) {
                $equal = $false
                break
            }
        }
    }

    Assert-True -Name $Name -Condition $equal -Detail ("expected [{0}], got [{1}]" -f
        ($expectedSorted -join ', '), ($actual -join ', '))
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

    # (1) An authorized write is attributed and emitted even though the scope verdict is clean.
    $authorizedWriteRepo = New-TestRepo -Name 'emit-authorized-write'
    $authorizedWriteState = Join-Path -Path $testRoot -ChildPath 'state-emit-authorized-write'
    $authorizedWriteFile = Join-Path -Path $testRoot -ChildPath 'written-authorized-write.txt'
    $authorizedWriteSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $authorizedWriteRepo, '-Task', 'emit-authorized-write', '-StateDirectory', $authorizedWriteState)
    Assert-True -Name 'written paths authorized-write snapshot succeeds' -Condition ($authorizedWriteSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $authorizedWriteSnapshot.ExitCode)
    Add-Content -LiteralPath (Join-Path $authorizedWriteRepo 'src/a.py') -Value 'CODER WORK' -Encoding ASCII
    $authorizedWrite = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $authorizedWriteRepo, '-Task', 'emit-authorized-write', '-StateDirectory', $authorizedWriteState, '-Authorized', 'src/a.py', '-WrittenPathsFile', $authorizedWriteFile)
    Assert-True -Name 'written paths authorized write exits clean' -Condition ($authorizedWrite.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $authorizedWrite.ExitCode, $authorizedWrite.Output)
    Assert-WrittenPaths -Name 'written paths authorized write emits normalized path' -Path $authorizedWriteFile -Expected @('src/a.py')

    # (2) A violation still emits its path before the non-zero scope exit.
    $outOfScopeRepo = New-TestRepo -Name 'emit-out-of-scope'
    $outOfScopeState = Join-Path -Path $testRoot -ChildPath 'state-emit-out-of-scope'
    $outOfScopeFile = Join-Path -Path $testRoot -ChildPath 'written-out-of-scope.txt'
    $outOfScopeSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $outOfScopeRepo, '-Task', 'emit-out-of-scope', '-StateDirectory', $outOfScopeState)
    Assert-True -Name 'written paths out-of-scope snapshot succeeds' -Condition ($outOfScopeSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $outOfScopeSnapshot.ExitCode)
    Add-Content -LiteralPath (Join-Path $outOfScopeRepo 'src/a.py') -Value 'UNAUTHORIZED WORK' -Encoding ASCII
    $outOfScope = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $outOfScopeRepo, '-Task', 'emit-out-of-scope', '-StateDirectory', $outOfScopeState, '-WrittenPathsFile', $outOfScopeFile)
    Assert-True -Name 'written paths out-of-scope exits non-zero' -Condition ($outOfScope.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $outOfScope.ExitCode)
    Assert-WrittenPaths -Name 'written paths out-of-scope emits on failure' -Path $outOfScopeFile -Expected @('src/a.py')

    # (3) Removing a host-dirty untracked file produces GONE and is attributed.
    $goneRepo = New-TestRepo -Name 'emit-gone'
    $goneState = Join-Path -Path $testRoot -ChildPath 'state-emit-gone'
    $goneFile = Join-Path -Path $testRoot -ChildPath 'written-gone.txt'
    $goneDraft = Join-Path -Path $goneRepo -ChildPath 'host-draft.txt'
    [System.IO.File]::WriteAllText($goneDraft, "host draft`r`n", [System.Text.Encoding]::ASCII)
    $goneSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $goneRepo, '-Task', 'emit-gone', '-StateDirectory', $goneState)
    Assert-True -Name 'written paths GONE snapshot succeeds' -Condition ($goneSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $goneSnapshot.ExitCode)
    Remove-Item -LiteralPath $goneDraft -Force
    $gone = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $goneRepo, '-Task', 'emit-gone', '-StateDirectory', $goneState, '-WrittenPathsFile', $goneFile)
    Assert-True -Name 'written paths GONE exits non-zero' -Condition ($gone.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $gone.ExitCode)
    Assert-True -Name 'written paths GONE reports status' -Condition ($gone.Output -match 'GONE\s+host-draft\.txt') -Detail $gone.Output
    Assert-WrittenPaths -Name 'written paths GONE emits removed path' -Path $goneFile -Expected @('host-draft.txt')

    # (4) Byte-identical host work is untouched and must not be attributed.
    $hostUntouchedRepo = New-TestRepo -Name 'emit-host-untouched'
    Add-Content -LiteralPath (Join-Path $hostUntouchedRepo 'src/a.py') -Value 'HOST WORK' -Encoding ASCII
    $hostUntouchedState = Join-Path -Path $testRoot -ChildPath 'state-emit-host-untouched'
    $hostUntouchedFile = Join-Path -Path $testRoot -ChildPath 'written-host-untouched.txt'
    $hostUntouchedSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $hostUntouchedRepo, '-Task', 'emit-host-untouched', '-StateDirectory', $hostUntouchedState)
    Assert-True -Name 'written paths host-untouched snapshot succeeds' -Condition ($hostUntouchedSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $hostUntouchedSnapshot.ExitCode)
    $hostUntouched = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $hostUntouchedRepo, '-Task', 'emit-host-untouched', '-StateDirectory', $hostUntouchedState, '-WrittenPathsFile', $hostUntouchedFile)
    Assert-True -Name 'written paths host-untouched exits clean' -Condition ($hostUntouched.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $hostUntouched.ExitCode, $hostUntouched.Output)
    Assert-WrittenPaths -Name 'written paths host-untouched is excluded' -Path $hostUntouchedFile -Expected @()

    # (5) No coder writes still creates a real, empty artifact.
    $emptyRepo = New-TestRepo -Name 'emit-empty'
    $emptyState = Join-Path -Path $testRoot -ChildPath 'state-emit-empty'
    $emptyFile = Join-Path -Path $testRoot -ChildPath 'written-empty.txt'
    $emptySnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $emptyRepo, '-Task', 'emit-empty', '-StateDirectory', $emptyState)
    Assert-True -Name 'written paths empty snapshot succeeds' -Condition ($emptySnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $emptySnapshot.ExitCode)
    $empty = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $emptyRepo, '-Task', 'emit-empty', '-StateDirectory', $emptyState, '-WrittenPathsFile', $emptyFile)
    Assert-True -Name 'written paths empty exits clean' -Condition ($empty.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $empty.ExitCode, $empty.Output)
    Assert-WrittenPaths -Name 'written paths empty file exists and has no lines' -Path $emptyFile -Expected @()
    Assert-True -Name 'written paths empty file has zero bytes' -Condition ((Get-Item -LiteralPath $emptyFile).Length -eq 0) -Detail ("expected 0 bytes, got {0}" -f (Get-Item -LiteralPath $emptyFile).Length)

    # (6) The emission target is check-only.
    $withoutCheckRepo = New-TestRepo -Name 'emit-without-check'
    $withoutCheckState = Join-Path -Path $testRoot -ChildPath 'state-emit-without-check'
    $withoutCheckFile = Join-Path -Path $testRoot -ChildPath 'written-without-check.txt'
    $withoutCheck = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $withoutCheckRepo, '-Task', 'emit-without-check', '-StateDirectory', $withoutCheckState, '-WrittenPathsFile', $withoutCheckFile)
    Assert-True -Name 'written paths without Check throws' -Condition ($withoutCheck.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $withoutCheck.ExitCode)
    Assert-True -Name 'written paths without Check has diagnostic' -Condition ($withoutCheck.Output -match 'valid only with -Check') -Detail $withoutCheck.Output
    Assert-True -Name 'written paths without Check creates no artifact' -Condition (-not (Test-Path -LiteralPath $withoutCheckFile)) -Detail 'unexpected written-paths file was created'

    # (7) Pre-dirty authorized work that did not change is still host work.
    $authorizedUntouchedRepo = New-TestRepo -Name 'emit-authorized-untouched'
    Add-Content -LiteralPath (Join-Path $authorizedUntouchedRepo 'src/a.py') -Value 'HOST AUTHORIZED WORK' -Encoding ASCII
    $authorizedUntouchedState = Join-Path -Path $testRoot -ChildPath 'state-emit-authorized-untouched'
    $authorizedUntouchedFile = Join-Path -Path $testRoot -ChildPath 'written-authorized-untouched.txt'
    $authorizedUntouchedSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $authorizedUntouchedRepo, '-Task', 'emit-authorized-untouched', '-StateDirectory', $authorizedUntouchedState)
    Assert-True -Name 'written paths authorized-untouched snapshot succeeds' -Condition ($authorizedUntouchedSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $authorizedUntouchedSnapshot.ExitCode)
    $authorizedUntouched = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $authorizedUntouchedRepo, '-Task', 'emit-authorized-untouched', '-StateDirectory', $authorizedUntouchedState, '-Authorized', 'src/a.py', '-WrittenPathsFile', $authorizedUntouchedFile)
    Assert-True -Name 'written paths authorized-untouched exits clean' -Condition ($authorizedUntouched.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $authorizedUntouched.ExitCode, $authorizedUntouched.Output)
    Assert-WrittenPaths -Name 'written paths authorized-untouched is excluded' -Path $authorizedUntouchedFile -Expected @()

    # (8) Emission must precede the malformed-allowlist exit 66 slot.
    $exit66Repo = New-TestRepo -Name 'emit-exit-66' -Files @('src/a.py', 'src/b.py', 'src/c.py')
    $exit66State = Join-Path -Path $testRoot -ChildPath 'state-emit-exit-66'
    $exit66File = Join-Path -Path $testRoot -ChildPath 'written-exit-66.txt'
    $exit66Snapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $exit66Repo, '-Task', 'emit-exit-66', '-StateDirectory', $exit66State)
    Assert-True -Name 'written paths exit-66 snapshot succeeds' -Condition ($exit66Snapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $exit66Snapshot.ExitCode)
    foreach ($relativePath in @('src/a.py', 'src/b.py', 'src/c.py')) {
        Add-Content -LiteralPath (Join-Path $exit66Repo $relativePath) -Value 'CODER WORK' -Encoding ASCII
    }
    $exit66 = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $exit66Repo, '-Task', 'emit-exit-66', '-StateDirectory', $exit66State, '-Authorized', 'elsewhere/one.py,elsewhere/two.py', '-WrittenPathsFile', $exit66File)
    Assert-True -Name 'written paths malformed allowlist exits 66' -Condition ($exit66.ExitCode -eq 66) -Detail ("expected 66, got {0}: {1}" -f $exit66.ExitCode, $exit66.Output)
    Assert-WrittenPaths -Name 'written paths malformed allowlist still emits' -Path $exit66File -Expected @('src/a.py', 'src/b.py', 'src/c.py')

    # (9) A newly collapsed directory emits both its token and all current leaf paths.
    $newDirectoryRepo = New-TestRepo -Name 'emit-new-directory'
    $newDirectoryState = Join-Path -Path $testRoot -ChildPath 'state-emit-new-directory'
    $newDirectoryFile = Join-Path -Path $testRoot -ChildPath 'written-new-directory.txt'
    $newDirectorySnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $newDirectoryRepo, '-Task', 'emit-new-directory', '-StateDirectory', $newDirectoryState)
    Assert-True -Name 'written paths new-directory snapshot succeeds' -Condition ($newDirectorySnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $newDirectorySnapshot.ExitCode)
    $sensitiveLeaf = Join-Path -Path $newDirectoryRepo -ChildPath 'scratch/nested/.env'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sensitiveLeaf) | Out-Null
    [System.IO.File]::WriteAllText($sensitiveLeaf, "secret=true`r`n", [System.Text.Encoding]::ASCII)
    $newDirectory = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $newDirectoryRepo, '-Task', 'emit-new-directory', '-StateDirectory', $newDirectoryState, '-WrittenPathsFile', $newDirectoryFile)
    Assert-True -Name 'written paths new-directory exits non-zero' -Condition ($newDirectory.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $newDirectory.ExitCode)
    Assert-WrittenPaths -Name 'written paths new-directory expands sensitive leaf' -Path $newDirectoryFile -Expected @('scratch', 'scratch/nested/.env')

    # (10) A vanished collapsed directory has no leaves to enumerate, but keeps its token.
    $goneDirectoryRepo = New-TestRepo -Name 'emit-gone-directory'
    $goneDirectoryState = Join-Path -Path $testRoot -ChildPath 'state-emit-gone-directory'
    $goneDirectoryFile = Join-Path -Path $testRoot -ChildPath 'written-gone-directory.txt'
    $goneDirectoryPath = Join-Path -Path $goneDirectoryRepo -ChildPath 'host-scratch'
    New-Item -ItemType Directory -Force -Path $goneDirectoryPath | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $goneDirectoryPath 'draft.txt'), "host draft`r`n", [System.Text.Encoding]::ASCII)
    $goneDirectorySnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $goneDirectoryRepo, '-Task', 'emit-gone-directory', '-StateDirectory', $goneDirectoryState)
    Assert-True -Name 'written paths gone-directory snapshot succeeds' -Condition ($goneDirectorySnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $goneDirectorySnapshot.ExitCode)
    Remove-Item -LiteralPath $goneDirectoryPath -Recurse -Force
    $goneDirectory = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $goneDirectoryRepo, '-Task', 'emit-gone-directory', '-StateDirectory', $goneDirectoryState, '-WrittenPathsFile', $goneDirectoryFile)
    Assert-True -Name 'written paths gone-directory exits non-zero' -Condition ($goneDirectory.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $goneDirectory.ExitCode)
    Assert-WrittenPaths -Name 'written paths gone-directory emits bare token' -Path $goneDirectoryFile -Expected @('host-scratch')

    # (11) The emitted UTF-8 file must not carry a BOM.
    $noBomRepo = New-TestRepo -Name 'emit-no-bom'
    $noBomState = Join-Path -Path $testRoot -ChildPath 'state-emit-no-bom'
    $noBomFile = Join-Path -Path $testRoot -ChildPath 'written-no-bom.txt'
    $noBomSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $noBomRepo, '-Task', 'emit-no-bom', '-StateDirectory', $noBomState)
    Assert-True -Name 'written paths no-BOM snapshot succeeds' -Condition ($noBomSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $noBomSnapshot.ExitCode)
    Add-Content -LiteralPath (Join-Path $noBomRepo 'src/a.py') -Value 'CODER WORK' -Encoding ASCII
    $noBom = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $noBomRepo, '-Task', 'emit-no-bom', '-StateDirectory', $noBomState, '-Authorized', 'src/a.py', '-WrittenPathsFile', $noBomFile)
    Assert-True -Name 'written paths no-BOM check succeeds' -Condition ($noBom.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $noBom.ExitCode, $noBom.Output)
    [byte[]]$noBomBytes = [System.IO.File]::ReadAllBytes($noBomFile)
    $startsWithBom = $noBomBytes.Length -ge 3 -and $noBomBytes[0] -eq 0xEF -and $noBomBytes[1] -eq 0xBB -and $noBomBytes[2] -eq 0xBF
    Assert-True -Name 'written paths file has no UTF-8 BOM' -Condition (-not $startsWithBom) -Detail ("first bytes: {0}" -f (($noBomBytes | Select-Object -First 3 | ForEach-Object { $_.ToString('X2') }) -join ' '))

    # (12) An unwritable target fails loudly and cannot be mistaken for a clean check.
    $writeFailureRepo = New-TestRepo -Name 'emit-write-failure'
    $writeFailureState = Join-Path -Path $testRoot -ChildPath 'state-emit-write-failure'
    $writeFailureFile = Join-Path -Path $testRoot -ChildPath 'nonexistent-parent/written.txt'
    $writeFailureSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $writeFailureRepo, '-Task', 'emit-write-failure', '-StateDirectory', $writeFailureState)
    Assert-True -Name 'written paths write-failure snapshot succeeds' -Condition ($writeFailureSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $writeFailureSnapshot.ExitCode)
    $writeFailure = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $writeFailureRepo, '-Task', 'emit-write-failure', '-StateDirectory', $writeFailureState, '-WrittenPathsFile', $writeFailureFile)
    Assert-True -Name 'written paths write failure exits non-zero' -Condition ($writeFailure.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $writeFailure.ExitCode)
    Assert-True -Name 'written paths write failure is loud' -Condition ($writeFailure.Output -match 'Failed to write -WrittenPathsFile') -Detail $writeFailure.Output
    Assert-True -Name 'written paths write failure does not report clean' -Condition ($writeFailure.Output -notmatch "\[scope\].* clean -") -Detail $writeFailure.Output

    # (13) The artifact must resolve outside the worktree.
    $containmentRepo = New-TestRepo -Name 'emit-containment'
    $containmentState = Join-Path -Path $testRoot -ChildPath 'state-emit-containment'
    $containmentFile = Join-Path -Path $containmentRepo -ChildPath 'written-inside.txt'
    $containmentSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $containmentRepo, '-Task', 'emit-containment', '-StateDirectory', $containmentState)
    Assert-True -Name 'written paths containment snapshot succeeds' -Condition ($containmentSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $containmentSnapshot.ExitCode)
    $containment = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $containmentRepo, '-Task', 'emit-containment', '-StateDirectory', $containmentState, '-WrittenPathsFile', $containmentFile)
    Assert-True -Name 'written paths under worktree throws' -Condition ($containment.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $containment.ExitCode)
    Assert-True -Name 'written paths under worktree has diagnostic' -Condition ($containment.Output -match 'outside the worktree') -Detail $containment.Output
    Assert-True -Name 'written paths under worktree creates no artifact' -Condition (-not (Test-Path -LiteralPath $containmentFile)) -Detail 'unexpected in-worktree artifact was created'

    # (14) An authorized path present at snapshot and gone now is attributed.
    $authorizedDeletionRepo = New-TestRepo -Name 'emit-authorized-deletion'
    $authorizedDeletionState = Join-Path -Path $testRoot -ChildPath 'state-emit-authorized-deletion'
    $authorizedDeletionFile = Join-Path -Path $testRoot -ChildPath 'written-authorized-deletion.txt'
    $authorizedDeletionDraft = Join-Path -Path $authorizedDeletionRepo -ChildPath 'authorized-draft.txt'
    [System.IO.File]::WriteAllText($authorizedDeletionDraft, "authorized draft`r`n", [System.Text.Encoding]::ASCII)
    $authorizedDeletionSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $authorizedDeletionRepo, '-Task', 'emit-authorized-deletion', '-StateDirectory', $authorizedDeletionState)
    Assert-True -Name 'written paths authorized-deletion snapshot succeeds' -Condition ($authorizedDeletionSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $authorizedDeletionSnapshot.ExitCode)
    Remove-Item -LiteralPath $authorizedDeletionDraft -Force
    $authorizedDeletion = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $authorizedDeletionRepo, '-Task', 'emit-authorized-deletion', '-StateDirectory', $authorizedDeletionState, '-Authorized', 'authorized-draft.txt', '-WrittenPathsFile', $authorizedDeletionFile)
    Assert-True -Name 'written paths authorized deletion exits clean' -Condition ($authorizedDeletion.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $authorizedDeletion.ExitCode, $authorizedDeletion.Output)
    Assert-WrittenPaths -Name 'written paths authorized deletion emits path' -Path $authorizedDeletionFile -Expected @('authorized-draft.txt')

    # (15) Reverting an authorized host-dirty tracked file to HEAD is also a GONE transition.
    $authorizedRevertRepo = New-TestRepo -Name 'emit-authorized-revert'
    $authorizedRevertState = Join-Path -Path $testRoot -ChildPath 'state-emit-authorized-revert'
    $authorizedRevertFile = Join-Path -Path $testRoot -ChildPath 'written-authorized-revert.txt'
    $authorizedRevertPath = Join-Path -Path $authorizedRevertRepo -ChildPath 'src/a.py'
    Add-Content -LiteralPath $authorizedRevertPath -Value 'HOST WORK' -Encoding ASCII
    $authorizedRevertSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $authorizedRevertRepo, '-Task', 'emit-authorized-revert', '-StateDirectory', $authorizedRevertState)
    Assert-True -Name 'written paths authorized-revert snapshot succeeds' -Condition ($authorizedRevertSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $authorizedRevertSnapshot.ExitCode)
    [System.IO.File]::WriteAllText($authorizedRevertPath, "orig`r`n", [System.Text.Encoding]::ASCII)
    $authorizedRevert = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $authorizedRevertRepo, '-Task', 'emit-authorized-revert', '-StateDirectory', $authorizedRevertState, '-Authorized', 'src/a.py', '-WrittenPathsFile', $authorizedRevertFile)
    Assert-True -Name 'written paths authorized revert exits clean' -Condition ($authorizedRevert.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $authorizedRevert.ExitCode, $authorizedRevert.Output)
    Assert-WrittenPaths -Name 'written paths authorized revert emits path' -Path $authorizedRevertFile -Expected @('src/a.py')

    # (16) A modified leaf in a pre-existing collapsed directory expands to every current leaf.
    $modifiedDirectoryRepo = New-TestRepo -Name 'emit-modified-directory'
    $modifiedDirectoryState = Join-Path -Path $testRoot -ChildPath 'state-emit-modified-directory'
    $modifiedDirectoryFile = Join-Path -Path $testRoot -ChildPath 'written-modified-directory.txt'
    $modifiedDirectoryPath = Join-Path -Path $modifiedDirectoryRepo -ChildPath 'scratch'
    New-Item -ItemType Directory -Force -Path (Join-Path $modifiedDirectoryPath 'nested') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $modifiedDirectoryPath 'a.txt'), "one`r`n", [System.Text.Encoding]::ASCII)
    $modifiedLeaf = Join-Path $modifiedDirectoryPath 'nested/b.txt'
    [System.IO.File]::WriteAllText($modifiedLeaf, "two`r`n", [System.Text.Encoding]::ASCII)
    $modifiedDirectorySnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $modifiedDirectoryRepo, '-Task', 'emit-modified-directory', '-StateDirectory', $modifiedDirectoryState)
    Assert-True -Name 'written paths modified-directory snapshot succeeds' -Condition ($modifiedDirectorySnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $modifiedDirectorySnapshot.ExitCode)
    Add-Content -LiteralPath $modifiedLeaf -Value 'CODER WORK' -Encoding ASCII
    $modifiedDirectory = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $modifiedDirectoryRepo, '-Task', 'emit-modified-directory', '-StateDirectory', $modifiedDirectoryState, '-WrittenPathsFile', $modifiedDirectoryFile)
    Assert-True -Name 'written paths modified-directory exits non-zero' -Condition ($modifiedDirectory.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $modifiedDirectory.ExitCode)
    Assert-WrittenPaths -Name 'written paths modified-directory expands current leaves' -Path $modifiedDirectoryFile -Expected @('scratch', 'scratch/a.txt', 'scratch/nested/b.txt')

    # (17) A deleted leaf is unidentifiable, so emit the directory token and remaining leaves.
    $deletedLeafRepo = New-TestRepo -Name 'emit-deleted-leaf'
    $deletedLeafState = Join-Path -Path $testRoot -ChildPath 'state-emit-deleted-leaf'
    $deletedLeafFile = Join-Path -Path $testRoot -ChildPath 'written-deleted-leaf.txt'
    $deletedLeafDirectory = Join-Path -Path $deletedLeafRepo -ChildPath 'scratch'
    New-Item -ItemType Directory -Force -Path (Join-Path $deletedLeafDirectory 'nested') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $deletedLeafDirectory 'keep.txt'), "keep`r`n", [System.Text.Encoding]::ASCII)
    $deletedLeafPath = Join-Path $deletedLeafDirectory 'nested/delete.txt'
    [System.IO.File]::WriteAllText($deletedLeafPath, "delete`r`n", [System.Text.Encoding]::ASCII)
    $deletedLeafSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $deletedLeafRepo, '-Task', 'emit-deleted-leaf', '-StateDirectory', $deletedLeafState)
    Assert-True -Name 'written paths deleted-leaf snapshot succeeds' -Condition ($deletedLeafSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $deletedLeafSnapshot.ExitCode)
    Remove-Item -LiteralPath $deletedLeafPath -Force
    $deletedLeaf = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $deletedLeafRepo, '-Task', 'emit-deleted-leaf', '-StateDirectory', $deletedLeafState, '-WrittenPathsFile', $deletedLeafFile)
    Assert-True -Name 'written paths deleted-leaf exits non-zero' -Condition ($deletedLeaf.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $deletedLeaf.ExitCode)
    Assert-WrittenPaths -Name 'written paths deleted-leaf documents expansion limit' -Path $deletedLeafFile -Expected @('scratch', 'scratch/keep.txt')

    # (18) Without the switch, authorized paths stay on the legacy no-hash fast path and output is exact.
    $noSwitchRepo = New-TestRepo -Name 'emit-no-switch'
    $noSwitchState = Join-Path -Path $testRoot -ChildPath 'state-emit-no-switch'
    $noSwitchSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $noSwitchRepo, '-Task', 'emit-no-switch', '-StateDirectory', $noSwitchState)
    Assert-True -Name 'written paths no-switch snapshot succeeds' -Condition ($noSwitchSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $noSwitchSnapshot.ExitCode)
    Add-Content -LiteralPath (Join-Path $noSwitchRepo 'src/a.py') -Value 'AUTHORIZED WORK' -Encoding ASCII
    $noSwitchPath = New-FailingGitShim -Name 'shim-no-switch-hash' -FailCommand 'hash-object'
    $noSwitch = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $noSwitchRepo, '-Task', 'emit-no-switch', '-StateDirectory', $noSwitchState, '-Authorized', 'src/a.py') -PathOverride $noSwitchPath
    $noSwitchExpectedOutput = "[scope] 'emit-no-switch' clean - every path the coder changed is in the authorized set."
    Assert-True -Name 'written paths no-switch keeps legacy exit' -Condition ($noSwitch.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $noSwitch.ExitCode, $noSwitch.Output)
    Assert-True -Name 'written paths no-switch keeps byte-identical output' -Condition ($noSwitch.Output -ceq $noSwitchExpectedOutput) -Detail ("expected [{0}], got [{1}]" -f $noSwitchExpectedOutput, $noSwitch.Output)

    # (19) The output file cannot alias and overwrite the snapshot evidence.
    $snapshotAliasRepo = New-TestRepo -Name 'emit-snapshot-alias'
    $snapshotAliasState = Join-Path -Path $testRoot -ChildPath 'state-emit-snapshot-alias'
    $snapshotAliasTask = 'emit-snapshot-alias'
    $snapshotAliasFile = Join-Path -Path $snapshotAliasState -ChildPath ("scope-{0}.snapshot.json" -f $snapshotAliasTask)
    $snapshotAliasSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $snapshotAliasRepo, '-Task', $snapshotAliasTask, '-StateDirectory', $snapshotAliasState)
    Assert-True -Name 'written paths snapshot-alias snapshot succeeds' -Condition ($snapshotAliasSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $snapshotAliasSnapshot.ExitCode)
    $snapshotAlias = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $snapshotAliasRepo, '-Task', $snapshotAliasTask, '-StateDirectory', $snapshotAliasState, '-WrittenPathsFile', $snapshotAliasFile)
    Assert-True -Name 'written paths snapshot alias throws' -Condition ($snapshotAlias.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $snapshotAlias.ExitCode)
    Assert-True -Name 'written paths snapshot alias has diagnostic' -Condition ($snapshotAlias.Output -match 'must not resolve to the snapshot path') -Detail $snapshotAlias.Output
    Assert-True -Name 'written paths snapshot alias preserves evidence' -Condition (Test-Path -LiteralPath $snapshotAliasFile -PathType Leaf) -Detail 'snapshot evidence was removed or overwritten'

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
