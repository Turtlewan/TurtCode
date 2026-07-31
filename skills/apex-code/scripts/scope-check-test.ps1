[CmdletBinding()]
param(
    [ValidateSet('', 'ExtraDerivedCacheExclusion', 'ExtraToolCacheExclusion', 'RenameSanctionedDirectory')]
    [string]$LockstepProbe = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$checkerPath = Join-Path -Path $PSScriptRoot -ChildPath 'codex-scope-check.ps1'
$testRoot = Join-Path -Path $env:TEMP -ChildPath ("apex-scope-check-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$powerShellPath = @(Get-Command powershell.exe -CommandType Application -ErrorAction Stop)[0].Source
$gitPath = @(Get-Command git.exe -CommandType Application -ErrorAction Stop)[0].Source
$failureCount = 0
$assertionCount = 0
$suiteExitCode = 1
$previousGitConfigGlobal = $env:GIT_CONFIG_GLOBAL

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
        [string]$PathOverride = '',
        [string]$CheckerPath = $checkerPath
    )

    $previousPath = $env:PATH
    $previousPreference = $ErrorActionPreference
    if ($PathOverride) { $env:PATH = $PathOverride }
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = -987654
        $output = @(& $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $CheckerPath @CheckerArguments 2>&1)
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

function New-IgnoredCacheRepo {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$IgnoredNames = @(
            '.codex-scratch',
            '.scratch',
            '.apex-tmp',
            '.sandbox-cache',
            '.pytest_cache',
            '.mypy_cache',
            '.ruff_cache',
            '.secret-hooks'
        )
    )

    # Isolate fixtures from the caller's global excludesFile. Otherwise a host ignore rule can
    # silently turn the load-bearing ?? cases into !! and make the tests machine-dependent.
    $scratchGitConfig = Join-Path -Path $testRoot -ChildPath 'derived-cache.gitconfig'
    $scratchGitIgnore = Join-Path -Path $testRoot -ChildPath 'derived-cache-global-ignore'
    [System.IO.File]::WriteAllText($scratchGitIgnore, '', [System.Text.UTF8Encoding]::new($false))
    $scratchGitIgnoreConfigPath = $scratchGitIgnore -replace '\\', '/'
    [System.IO.File]::WriteAllText(
        $scratchGitConfig,
        "[core]`n    excludesFile = $scratchGitIgnoreConfigPath`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    $env:GIT_CONFIG_GLOBAL = $scratchGitConfig

    $repoPath = New-TestRepo -Name $Name
    $ignorePath = Join-Path -Path $repoPath -ChildPath '.gitignore'
    $ignoreContent = if ($IgnoredNames.Count -gt 0) {
        (@($IgnoredNames | ForEach-Object { "/$_/" }) -join "`n") + "`n"
    } else {
        ''
    }
    [System.IO.File]::WriteAllText($ignorePath, $ignoreContent, [System.Text.UTF8Encoding]::new($false))
    Invoke-TestGit -RepoPath $repoPath -GitArguments @('add', '--', '.gitignore')
    Invoke-TestGit -RepoPath $repoPath -GitArguments @('commit', '-q', '-m', 'add fixture ignores')
    return $repoPath
}

function Get-PsArrayLiteral {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $text = [System.IO.File]::ReadAllText($Path)
    $assignmentPattern = '(?s)\$' + [regex]::Escape($Name) + '\s*=\s*@\((?<body>.*?)\)'
    $assignment = [regex]::Match($text, $assignmentPattern)
    if (-not $assignment.Success) { return @() }

    $body = $assignment.Groups['body'].Value
    $entryPattern = @'
(?x)
(?:'(?<single>(?:[^']|'')*)'|"(?<double>(?:[^"`]|`.)*)")
'@
    $entries = @(
        foreach ($entry in [regex]::Matches($body, $entryPattern)) {
            if ($entry.Groups['single'].Success) {
                $entry.Groups['single'].Value.Replace("''", "'")
            }
            else {
                $entry.Groups['double'].Value -replace '`(["`$])', '$1'
            }
        }
    )

    # This helper intentionally accepts only a literal list. Expressions, variables, or a malformed
    # quote make the parse fail closed rather than returning a plausible partial list.
    $residue = [regex]::Replace($body, $entryPattern, '')
    $residue = [regex]::Replace($residue, '(?m)#.*$', '')
    $residue = $residue -replace '[,\s]', ''
    if ($residue.Length -ne 0) { return @() }
    return $entries
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

    # Runtime exclusion (1): new session churn under the configured runtime root is not attributed.
    $runtimeChurnRepo = New-TestRepo -Name 'runtime-untracked-churn'
    $runtimeChurnState = Join-Path -Path $testRoot -ChildPath 'state-runtime-untracked-churn'
    $runtimeChurnFile = Join-Path -Path $testRoot -ChildPath 'written-runtime-untracked-churn.txt'
    $runtimeChurnSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeChurnRepo, '-Task', 'runtime-untracked-churn', '-StateDirectory', $runtimeChurnState)
    Assert-True -Name 'runtime untracked churn snapshot succeeds' -Condition ($runtimeChurnSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeChurnSnapshot.ExitCode)
    $runtimeChurnLeaf = Join-Path -Path $runtimeChurnRepo -ChildPath 'projects/session-x.jsonl'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runtimeChurnLeaf) | Out-Null
    [System.IO.File]::WriteAllText($runtimeChurnLeaf, "session churn`r`n", [System.Text.Encoding]::ASCII)
    $runtimeChurn = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeChurnRepo, '-Task', 'runtime-untracked-churn', '-StateDirectory', $runtimeChurnState, '-RuntimeExclusionRoot', $runtimeChurnRepo, '-WrittenPathsFile', $runtimeChurnFile)
    Assert-True -Name 'runtime untracked churn exits clean' -Condition ($runtimeChurn.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $runtimeChurn.ExitCode, $runtimeChurn.Output)
    Assert-WrittenPaths -Name 'runtime untracked churn emits neither token nor leaf' -Path $runtimeChurnFile -Expected @()

    # Runtime exclusion (2): an index/HEAD-tracked runtime file remains attributable.
    $runtimeTrackedRepo = New-TestRepo -Name 'runtime-tracked-file' -Files @('projects/keep.txt')
    $runtimeTrackedState = Join-Path -Path $testRoot -ChildPath 'state-runtime-tracked-file'
    $runtimeTrackedFile = Join-Path -Path $testRoot -ChildPath 'written-runtime-tracked-file.txt'
    $runtimeTrackedSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeTrackedRepo, '-Task', 'runtime-tracked-file', '-StateDirectory', $runtimeTrackedState)
    Assert-True -Name 'runtime tracked file snapshot succeeds' -Condition ($runtimeTrackedSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeTrackedSnapshot.ExitCode)
    Add-Content -LiteralPath (Join-Path $runtimeTrackedRepo 'projects/keep.txt') -Value 'CODER WORK' -Encoding ASCII
    $runtimeTracked = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeTrackedRepo, '-Task', 'runtime-tracked-file', '-StateDirectory', $runtimeTrackedState, '-RuntimeExclusionRoot', $runtimeTrackedRepo, '-WrittenPathsFile', $runtimeTrackedFile)
    Assert-True -Name 'runtime tracked file exits non-zero' -Condition ($runtimeTracked.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $runtimeTracked.ExitCode)
    Assert-WrittenPaths -Name 'runtime tracked file remains attributed' -Path $runtimeTrackedFile -Expected @('projects/keep.txt')

    # Runtime exclusion (3): matching is pinned to the configured root, not merely the path name.
    $runtimePinRepo = New-TestRepo -Name 'runtime-root-pin'
    $runtimePinState = Join-Path -Path $testRoot -ChildPath 'state-runtime-root-pin'
    $runtimePinFile = Join-Path -Path $testRoot -ChildPath 'written-runtime-root-pin.txt'
    $runtimePinSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimePinRepo, '-Task', 'runtime-root-pin', '-StateDirectory', $runtimePinState)
    Assert-True -Name 'runtime root pin snapshot succeeds' -Condition ($runtimePinSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimePinSnapshot.ExitCode)
    $runtimePinLeaf = Join-Path -Path $runtimePinRepo -ChildPath 'projects/session-x.jsonl'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runtimePinLeaf) | Out-Null
    [System.IO.File]::WriteAllText($runtimePinLeaf, "session churn`r`n", [System.Text.Encoding]::ASCII)
    $runtimePin = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimePinRepo, '-Task', 'runtime-root-pin', '-StateDirectory', $runtimePinState, '-WrittenPathsFile', $runtimePinFile)
    Assert-True -Name 'runtime root pin exits non-zero away from configured root' -Condition ($runtimePin.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $runtimePin.ExitCode)
    Assert-WrittenPaths -Name 'runtime root pin attributes token and expanded leaf' -Path $runtimePinFile -Expected @('projects', 'projects/session-x.jsonl')

    # Runtime exclusion (4): ordinary untracked source remains attributable at the runtime root.
    $runtimeNoOverRepo = New-TestRepo -Name 'runtime-no-over-exclusion'
    $runtimeNoOverState = Join-Path -Path $testRoot -ChildPath 'state-runtime-no-over-exclusion'
    $runtimeNoOverFile = Join-Path -Path $testRoot -ChildPath 'written-runtime-no-over-exclusion.txt'
    $runtimeNoOverSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeNoOverRepo, '-Task', 'runtime-no-over-exclusion', '-StateDirectory', $runtimeNoOverState)
    Assert-True -Name 'runtime no-over-exclusion snapshot succeeds' -Condition ($runtimeNoOverSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeNoOverSnapshot.ExitCode)
    [System.IO.File]::WriteAllText((Join-Path $runtimeNoOverRepo 'src/rogue.py'), "rogue`r`n", [System.Text.Encoding]::ASCII)
    $runtimeNoOver = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeNoOverRepo, '-Task', 'runtime-no-over-exclusion', '-StateDirectory', $runtimeNoOverState, '-RuntimeExclusionRoot', $runtimeNoOverRepo, '-WrittenPathsFile', $runtimeNoOverFile)
    Assert-True -Name 'runtime no-over-exclusion exits non-zero' -Condition ($runtimeNoOver.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $runtimeNoOver.ExitCode)
    Assert-WrittenPaths -Name 'runtime no-over-exclusion attributes source path' -Path $runtimeNoOverFile -Expected @('src/rogue.py')

    # Runtime exclusion (5): the exclusion count is loud without relying on console width.
    Assert-True -Name 'runtime exclusion count note is loud' -Condition ($runtimeChurn.Output -match 'runtime path\(s\) excluded') -Detail $runtimeChurn.Output

    # Runtime exclusion (6): the non-collecting attribution branch applies the same exclusion.
    $runtimeNoCollectRepo = New-TestRepo -Name 'runtime-no-written-paths'
    $runtimeNoCollectState = Join-Path -Path $testRoot -ChildPath 'state-runtime-no-written-paths'
    $runtimeNoCollectSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeNoCollectRepo, '-Task', 'runtime-no-written-paths', '-StateDirectory', $runtimeNoCollectState)
    Assert-True -Name 'runtime no-written-paths snapshot succeeds' -Condition ($runtimeNoCollectSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeNoCollectSnapshot.ExitCode)
    $runtimeNoCollectLeaf = Join-Path -Path $runtimeNoCollectRepo -ChildPath 'projects/session-x.jsonl'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runtimeNoCollectLeaf) | Out-Null
    [System.IO.File]::WriteAllText($runtimeNoCollectLeaf, "session churn`r`n", [System.Text.Encoding]::ASCII)
    $runtimeNoCollect = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeNoCollectRepo, '-Task', 'runtime-no-written-paths', '-StateDirectory', $runtimeNoCollectState, '-RuntimeExclusionRoot', $runtimeNoCollectRepo)
    Assert-True -Name 'runtime no-written-paths exits clean' -Condition ($runtimeNoCollect.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $runtimeNoCollect.ExitCode, $runtimeNoCollect.Output)
    Assert-True -Name 'runtime no-written-paths prints clean verdict' -Condition ($runtimeNoCollect.Output -match '(?m)^\[scope\].* clean -') -Detail $runtimeNoCollect.Output

    # Runtime exclusion (7): runtime churn present at snapshot and gone at check is excluded too.
    $runtimeGoneRepo = New-TestRepo -Name 'runtime-gone'
    $runtimeGoneState = Join-Path -Path $testRoot -ChildPath 'state-runtime-gone'
    $runtimeGoneFile = Join-Path -Path $testRoot -ChildPath 'written-runtime-gone.txt'
    $runtimeGoneDirectory = Join-Path -Path $runtimeGoneRepo -ChildPath 'projects'
    New-Item -ItemType Directory -Force -Path $runtimeGoneDirectory | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $runtimeGoneDirectory 'session-x.jsonl'), "session churn`r`n", [System.Text.Encoding]::ASCII)
    $runtimeGoneSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeGoneRepo, '-Task', 'runtime-gone', '-StateDirectory', $runtimeGoneState)
    Assert-True -Name 'runtime gone snapshot succeeds' -Condition ($runtimeGoneSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeGoneSnapshot.ExitCode)
    Remove-Item -LiteralPath $runtimeGoneDirectory -Recurse -Force
    $runtimeGone = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeGoneRepo, '-Task', 'runtime-gone', '-StateDirectory', $runtimeGoneState, '-RuntimeExclusionRoot', $runtimeGoneRepo, '-WrittenPathsFile', $runtimeGoneFile)
    Assert-True -Name 'runtime gone exits clean' -Condition ($runtimeGone.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $runtimeGone.ExitCode, $runtimeGone.Output)
    Assert-WrittenPaths -Name 'runtime gone emits no path' -Path $runtimeGoneFile -Expected @()
    Assert-True -Name 'runtime gone prints no GONE line' -Condition ($runtimeGone.Output -notmatch '(?m)^\s*GONE\s+projects(?:/|$)') -Detail $runtimeGone.Output

    # Runtime exclusion (8): a staged deletion remains curated through the HEAD inventory.
    $runtimeDeletionRepo = New-TestRepo -Name 'runtime-tracked-deletion' -Files @('projects/keep.txt')
    $runtimeDeletionState = Join-Path -Path $testRoot -ChildPath 'state-runtime-tracked-deletion'
    $runtimeDeletionFile = Join-Path -Path $testRoot -ChildPath 'written-runtime-tracked-deletion.txt'
    $runtimeDeletionSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeDeletionRepo, '-Task', 'runtime-tracked-deletion', '-StateDirectory', $runtimeDeletionState)
    Assert-True -Name 'runtime tracked deletion snapshot succeeds' -Condition ($runtimeDeletionSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeDeletionSnapshot.ExitCode)
    Invoke-TestGit -RepoPath $runtimeDeletionRepo -GitArguments @('rm', '--', 'projects/keep.txt')
    [string[]]$runtimeDeletionIndexEntries = @(& $gitPath -C $runtimeDeletionRepo ls-files -- 'projects/keep.txt')
    $runtimeDeletionIndexExit = $LASTEXITCODE
    Assert-True -Name 'runtime tracked deletion is absent from index before check' -Condition ($runtimeDeletionIndexExit -eq 0 -and $runtimeDeletionIndexEntries.Count -eq 0) -Detail ("exit {0}, entries [{1}]" -f $runtimeDeletionIndexExit, ($runtimeDeletionIndexEntries -join ', '))
    $runtimeDeletion = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeDeletionRepo, '-Task', 'runtime-tracked-deletion', '-StateDirectory', $runtimeDeletionState, '-RuntimeExclusionRoot', $runtimeDeletionRepo, '-WrittenPathsFile', $runtimeDeletionFile)
    Assert-True -Name 'runtime tracked deletion exits non-zero' -Condition ($runtimeDeletion.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $runtimeDeletion.ExitCode)
    Assert-WrittenPaths -Name 'runtime tracked deletion remains attributed from HEAD' -Path $runtimeDeletionFile -Expected @('projects/keep.txt')

    # Runtime exclusion (9): inventory lookup treats metacharacters as literal set members.
    $runtimeMetaRepo = New-TestRepo -Name 'runtime-metacharacter' -Files @('projects/file[1].txt')
    $runtimeMetaState = Join-Path -Path $testRoot -ChildPath 'state-runtime-metacharacter'
    $runtimeMetaFile = Join-Path -Path $testRoot -ChildPath 'written-runtime-metacharacter.txt'
    $runtimeMetaSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMetaRepo, '-Task', 'runtime-metacharacter', '-StateDirectory', $runtimeMetaState)
    Assert-True -Name 'runtime metacharacter snapshot succeeds' -Condition ($runtimeMetaSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeMetaSnapshot.ExitCode)
    Add-Content -LiteralPath (Join-Path $runtimeMetaRepo 'projects/file[1].txt') -Value 'CODER WORK' -Encoding ASCII
    $runtimeMeta = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMetaRepo, '-Task', 'runtime-metacharacter', '-StateDirectory', $runtimeMetaState, '-RuntimeExclusionRoot', $runtimeMetaRepo, '-WrittenPathsFile', $runtimeMetaFile)
    Assert-True -Name 'runtime metacharacter exits non-zero' -Condition ($runtimeMeta.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $runtimeMeta.ExitCode)
    Assert-WrittenPaths -Name 'runtime metacharacter remains attributed literally' -Path $runtimeMetaFile -Expected @('projects/file[1].txt')

    # Runtime exclusion (10): a collapsed directory token is curated by an indexed descendant.
    $runtimeCollapsedRepo = New-TestRepo -Name 'runtime-collapsed-directory'
    $runtimeCollapsedState = Join-Path -Path $testRoot -ChildPath 'state-runtime-collapsed-directory'
    $runtimeCollapsedFile = Join-Path -Path $testRoot -ChildPath 'written-runtime-collapsed-directory.txt'
    $runtimeCollapsedDirectory = Join-Path -Path $runtimeCollapsedRepo -ChildPath 'projects'
    New-Item -ItemType Directory -Force -Path $runtimeCollapsedDirectory | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $runtimeCollapsedDirectory 'a.jsonl'), "a`r`n", [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText((Join-Path $runtimeCollapsedDirectory 'b.jsonl'), "b`r`n", [System.Text.Encoding]::ASCII)
    $runtimeCollapsedSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeCollapsedRepo, '-Task', 'runtime-collapsed-directory', '-StateDirectory', $runtimeCollapsedState)
    Assert-True -Name 'runtime collapsed directory snapshot succeeds' -Condition ($runtimeCollapsedSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeCollapsedSnapshot.ExitCode)
    Invoke-TestGit -RepoPath $runtimeCollapsedRepo -GitArguments @('add', '-f', '--', 'projects/a.jsonl')
    $runtimeCollapsed = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeCollapsedRepo, '-Task', 'runtime-collapsed-directory', '-StateDirectory', $runtimeCollapsedState, '-RuntimeExclusionRoot', $runtimeCollapsedRepo, '-WrittenPathsFile', $runtimeCollapsedFile)
    Assert-True -Name 'runtime collapsed directory exits non-zero' -Condition ($runtimeCollapsed.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $runtimeCollapsed.ExitCode)
    Assert-WrittenPaths -Name 'runtime collapsed directory token remains attributed' -Path $runtimeCollapsedFile -Expected @('projects', 'projects/a.jsonl', 'projects/b.jsonl')

    # Runtime exclusion (11): rename attribution keeps the HEAD source and index destination.
    $runtimeRenameRepo = New-TestRepo -Name 'runtime-rename' -Files @('projects/keep.txt')
    $runtimeRenameState = Join-Path -Path $testRoot -ChildPath 'state-runtime-rename'
    $runtimeRenameFile = Join-Path -Path $testRoot -ChildPath 'written-runtime-rename.txt'
    $runtimeRenameSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeRenameRepo, '-Task', 'runtime-rename', '-StateDirectory', $runtimeRenameState)
    Assert-True -Name 'runtime rename snapshot succeeds' -Condition ($runtimeRenameSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeRenameSnapshot.ExitCode)
    Invoke-TestGit -RepoPath $runtimeRenameRepo -GitArguments @('mv', '--', 'projects/keep.txt', 'projects/renamed.txt')
    $runtimeRename = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeRenameRepo, '-Task', 'runtime-rename', '-StateDirectory', $runtimeRenameState, '-RuntimeExclusionRoot', $runtimeRenameRepo, '-WrittenPathsFile', $runtimeRenameFile)
    Assert-True -Name 'runtime rename exits non-zero' -Condition ($runtimeRename.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $runtimeRename.ExitCode)
    Assert-WrittenPaths -Name 'runtime rename attributes source and destination' -Path $runtimeRenameFile -Expected @('projects/keep.txt', 'projects/renamed.txt')

    # Runtime exclusion (12): an ls-files inventory failure disables all exclusion for this check.
    $runtimeLsFilesRepo = New-TestRepo -Name 'runtime-ls-files-failure'
    $runtimeLsFilesState = Join-Path -Path $testRoot -ChildPath 'state-runtime-ls-files-failure'
    $runtimeLsFilesFile = Join-Path -Path $testRoot -ChildPath 'written-runtime-ls-files-failure.txt'
    $runtimeLsFilesSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeLsFilesRepo, '-Task', 'runtime-ls-files-failure', '-StateDirectory', $runtimeLsFilesState)
    Assert-True -Name 'runtime ls-files failure snapshot succeeds normally' -Condition ($runtimeLsFilesSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeLsFilesSnapshot.ExitCode)
    $runtimeLsFilesLeaf = Join-Path -Path $runtimeLsFilesRepo -ChildPath 'projects/session-x.jsonl'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runtimeLsFilesLeaf) | Out-Null
    [System.IO.File]::WriteAllText($runtimeLsFilesLeaf, "session churn`r`n", [System.Text.Encoding]::ASCII)
    $runtimeLsFilesShim = New-FailingGitShim -Name 'shim-runtime-ls-files' -FailCommand 'ls-files'
    $runtimeLsFiles = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeLsFilesRepo, '-Task', 'runtime-ls-files-failure', '-StateDirectory', $runtimeLsFilesState, '-RuntimeExclusionRoot', $runtimeLsFilesRepo, '-WrittenPathsFile', $runtimeLsFilesFile) -PathOverride $runtimeLsFilesShim
    Assert-True -Name 'runtime ls-files inventory failure exits non-zero' -Condition ($runtimeLsFiles.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $runtimeLsFiles.ExitCode)
    Assert-WrittenPaths -Name 'runtime ls-files inventory failure attributes churn' -Path $runtimeLsFilesFile -Expected @('projects', 'projects/session-x.jsonl')
    Assert-True -Name 'runtime ls-files inventory failure is loud' -Condition ($runtimeLsFiles.Output -match 'runtime inventory could not be built') -Detail $runtimeLsFiles.Output

    # Runtime exclusion (13): an ls-tree HEAD inventory failure is fail-closed in the same way.
    $runtimeLsTreeRepo = New-TestRepo -Name 'runtime-ls-tree-failure'
    $runtimeLsTreeState = Join-Path -Path $testRoot -ChildPath 'state-runtime-ls-tree-failure'
    $runtimeLsTreeFile = Join-Path -Path $testRoot -ChildPath 'written-runtime-ls-tree-failure.txt'
    $runtimeLsTreeSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeLsTreeRepo, '-Task', 'runtime-ls-tree-failure', '-StateDirectory', $runtimeLsTreeState)
    Assert-True -Name 'runtime ls-tree failure snapshot succeeds normally' -Condition ($runtimeLsTreeSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeLsTreeSnapshot.ExitCode)
    $runtimeLsTreeLeaf = Join-Path -Path $runtimeLsTreeRepo -ChildPath 'projects/session-x.jsonl'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runtimeLsTreeLeaf) | Out-Null
    [System.IO.File]::WriteAllText($runtimeLsTreeLeaf, "session churn`r`n", [System.Text.Encoding]::ASCII)
    $runtimeLsTreeShim = New-FailingGitShim -Name 'shim-runtime-ls-tree' -FailCommand 'ls-tree'
    $runtimeLsTree = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeLsTreeRepo, '-Task', 'runtime-ls-tree-failure', '-StateDirectory', $runtimeLsTreeState, '-RuntimeExclusionRoot', $runtimeLsTreeRepo, '-WrittenPathsFile', $runtimeLsTreeFile) -PathOverride $runtimeLsTreeShim
    Assert-True -Name 'runtime ls-tree inventory failure exits non-zero' -Condition ($runtimeLsTree.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $runtimeLsTree.ExitCode)
    Assert-WrittenPaths -Name 'runtime ls-tree inventory failure attributes churn' -Path $runtimeLsTreeFile -Expected @('projects', 'projects/session-x.jsonl')
    Assert-True -Name 'runtime ls-tree inventory failure is loud' -Condition ($runtimeLsTree.Output -match 'runtime inventory could not be built') -Detail $runtimeLsTree.Output

    # Derived-cache (1): ignored scratch created during dispatch is excluded and emits nothing.
    $derivedScratchRepo = New-IgnoredCacheRepo -Name 'derived-scratch-created'
    $derivedScratchState = Join-Path $testRoot 'state-derived-scratch-created'
    $derivedScratchFile = Join-Path $testRoot 'written-derived-scratch-created.txt'
    $derivedScratchSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $derivedScratchRepo, '-Task', 'derived-scratch-created', '-StateDirectory', $derivedScratchState)
    Assert-True -Name 'derived-cache 1 snapshot succeeds' -Condition ($derivedScratchSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $derivedScratchSnapshot.ExitCode)
    $derivedScratchLeaf = Join-Path $derivedScratchRepo '.codex-scratch/log.txt'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $derivedScratchLeaf) | Out-Null
    [System.IO.File]::WriteAllText($derivedScratchLeaf, "log`r`n", [System.Text.Encoding]::ASCII)
    $derivedScratch = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $derivedScratchRepo, '-Task', 'derived-scratch-created', '-StateDirectory', $derivedScratchState, '-WrittenPathsFile', $derivedScratchFile)
    Assert-True -Name 'derived-cache 1 ignored scratch exits clean' -Condition ($derivedScratch.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $derivedScratch.ExitCode, $derivedScratch.Output)
    Assert-WrittenPaths -Name 'derived-cache 1 ignored scratch emits no paths' -Path $derivedScratchFile -Expected @()

    # Derived-cache (2): a repo-root tool cache receives the same exact-name treatment.
    $derivedPytestRepo = New-IgnoredCacheRepo -Name 'derived-pytest-created'
    $derivedPytestState = Join-Path $testRoot 'state-derived-pytest-created'
    $derivedPytestSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $derivedPytestRepo, '-Task', 'derived-pytest-created', '-StateDirectory', $derivedPytestState)
    $derivedPytestLeaf = Join-Path $derivedPytestRepo '.pytest_cache/v/cache/lastfailed'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $derivedPytestLeaf) | Out-Null
    [System.IO.File]::WriteAllText($derivedPytestLeaf, "{}`r`n", [System.Text.Encoding]::ASCII)
    $derivedPytest = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $derivedPytestRepo, '-Task', 'derived-pytest-created', '-StateDirectory', $derivedPytestState)
    Assert-True -Name 'derived-cache 2 ignored pytest cache exits clean' -Condition ($derivedPytestSnapshot.ExitCode -eq 0 -and $derivedPytest.ExitCode -eq 0) -Detail ("snapshot {0}, check {1}: {2}" -f $derivedPytestSnapshot.ExitCode, $derivedPytest.ExitCode, $derivedPytest.Output)

    # Derived-cache (3): ignored-only is insufficient when the root token is not on the exact list.
    $derivedUnknownRepo = New-IgnoredCacheRepo -Name 'derived-unknown-name'
    $derivedUnknownState = Join-Path $testRoot 'state-derived-unknown-name'
    $derivedUnknownFile = Join-Path $testRoot 'written-derived-unknown-name.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $derivedUnknownRepo, '-Task', 'derived-unknown-name', '-StateDirectory', $derivedUnknownState))
    $derivedUnknownLeaf = Join-Path $derivedUnknownRepo '.secret-hooks/post-commit'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $derivedUnknownLeaf) | Out-Null
    [System.IO.File]::WriteAllText($derivedUnknownLeaf, "hook`r`n", [System.Text.Encoding]::ASCII)
    $derivedUnknown = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $derivedUnknownRepo, '-Task', 'derived-unknown-name', '-StateDirectory', $derivedUnknownState, '-WrittenPathsFile', $derivedUnknownFile)
    Assert-True -Name 'derived-cache 3 unlisted ignored path exits non-zero' -Condition ($derivedUnknown.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $derivedUnknown.ExitCode)
    Assert-WrittenPaths -Name 'derived-cache 3 unlisted ignored path is attributed' -Path $derivedUnknownFile -Expected @('.secret-hooks', '.secret-hooks/post-commit')

    # Derived-cache (4): index/HEAD curation wins over an exact ignored cache name.
    $derivedTrackedRepo = New-IgnoredCacheRepo -Name 'derived-tracked-cache'
    $derivedTrackedLeaf = Join-Path $derivedTrackedRepo '.pytest_cache/keep.txt'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $derivedTrackedLeaf) | Out-Null
    [System.IO.File]::WriteAllText($derivedTrackedLeaf, "orig`r`n", [System.Text.Encoding]::ASCII)
    Invoke-TestGit -RepoPath $derivedTrackedRepo -GitArguments @('add', '-f', '--', '.pytest_cache/keep.txt')
    Invoke-TestGit -RepoPath $derivedTrackedRepo -GitArguments @('commit', '-q', '-m', 'track cache fixture')
    $derivedTrackedState = Join-Path $testRoot 'state-derived-tracked-cache'
    $derivedTrackedFile = Join-Path $testRoot 'written-derived-tracked-cache.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $derivedTrackedRepo, '-Task', 'derived-tracked-cache', '-StateDirectory', $derivedTrackedState))
    Add-Content -LiteralPath $derivedTrackedLeaf -Value 'CODER WORK' -Encoding ASCII
    $derivedTracked = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $derivedTrackedRepo, '-Task', 'derived-tracked-cache', '-StateDirectory', $derivedTrackedState, '-WrittenPathsFile', $derivedTrackedFile)
    Assert-True -Name 'derived-cache 4 tracked cache exits non-zero' -Condition ($derivedTracked.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $derivedTracked.ExitCode)
    Assert-WrittenPaths -Name 'derived-cache 4 tracked cache is attributed' -Path $derivedTrackedFile -Expected @('.pytest_cache/keep.txt')

    # Derived-cache (5): ignored scratch present at snapshot may disappear without a GONE verdict.
    $derivedGoneRepo = New-IgnoredCacheRepo -Name 'derived-gone'
    $derivedGoneDirectory = Join-Path $derivedGoneRepo '.codex-scratch'
    New-Item -ItemType Directory -Force -Path $derivedGoneDirectory | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $derivedGoneDirectory 'log.txt'), "log`r`n", [System.Text.Encoding]::ASCII)
    $derivedGoneState = Join-Path $testRoot 'state-derived-gone'
    $derivedGoneFile = Join-Path $testRoot 'written-derived-gone.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $derivedGoneRepo, '-Task', 'derived-gone', '-StateDirectory', $derivedGoneState))
    Remove-Item -LiteralPath $derivedGoneDirectory -Recurse -Force
    $derivedGone = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $derivedGoneRepo, '-Task', 'derived-gone', '-StateDirectory', $derivedGoneState, '-WrittenPathsFile', $derivedGoneFile)
    Assert-True -Name 'derived-cache 5 snapshot cache deletion exits clean without GONE' -Condition ($derivedGone.ExitCode -eq 0 -and $derivedGone.Output -notmatch '(?m)^\s*GONE\s+\.codex-scratch(?:/|$)') -Detail ("exit {0}: {1}" -f $derivedGone.ExitCode, $derivedGone.Output)
    Assert-WrittenPaths -Name 'derived-cache 5 snapshot cache deletion emits no paths' -Path $derivedGoneFile -Expected @()

    # Derived-cache (6): the names are anchored at the repository root.
    $derivedNestedRepo = New-IgnoredCacheRepo -Name 'derived-nested' -IgnoredNames @('src/.codex-scratch')
    $derivedNestedState = Join-Path $testRoot 'state-derived-nested'
    $derivedNestedFile = Join-Path $testRoot 'written-derived-nested.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $derivedNestedRepo, '-Task', 'derived-nested', '-StateDirectory', $derivedNestedState))
    $derivedNestedLeaf = Join-Path $derivedNestedRepo 'src/.codex-scratch/x'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $derivedNestedLeaf) | Out-Null
    [System.IO.File]::WriteAllText($derivedNestedLeaf, "x`r`n", [System.Text.Encoding]::ASCII)
    $derivedNested = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $derivedNestedRepo, '-Task', 'derived-nested', '-StateDirectory', $derivedNestedState, '-WrittenPathsFile', $derivedNestedFile)
    Assert-True -Name 'derived-cache 6 nested exact-name directory exits non-zero' -Condition ($derivedNested.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $derivedNested.ExitCode)
    Assert-WrittenPaths -Name 'derived-cache 6 nested exact-name directory is attributed' -Path $derivedNestedFile -Expected @('src/.codex-scratch', 'src/.codex-scratch/x')

    # Derived-cache (7): exclusion is deliberately visible in the check transcript.
    Assert-True -Name 'derived-cache 7 exclusion count note is loud' -Condition ($derivedScratch.Output -match 'derived-cache path\(s\) excluded') -Detail $derivedScratch.Output

    # Derived-cache (8): the non-WrittenPathsFile branch uses the identical predicate.
    $derivedNoCollectRepo = New-IgnoredCacheRepo -Name 'derived-no-written-paths'
    $derivedNoCollectState = Join-Path $testRoot 'state-derived-no-written-paths'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $derivedNoCollectRepo, '-Task', 'derived-no-written-paths', '-StateDirectory', $derivedNoCollectState))
    $derivedNoCollectLeaf = Join-Path $derivedNoCollectRepo '.codex-scratch/log.txt'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $derivedNoCollectLeaf) | Out-Null
    [System.IO.File]::WriteAllText($derivedNoCollectLeaf, "log`r`n", [System.Text.Encoding]::ASCII)
    $derivedNoCollect = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $derivedNoCollectRepo, '-Task', 'derived-no-written-paths', '-StateDirectory', $derivedNoCollectState)
    Assert-True -Name 'derived-cache 8 non-collecting branch exits clean' -Condition ($derivedNoCollect.ExitCode -eq 0 -and $derivedNoCollect.Output -match '(?m)^\[scope\].* clean -') -Detail ("exit {0}: {1}" -f $derivedNoCollect.ExitCode, $derivedNoCollect.Output)

    # Derived-cache (9): inventory failure disables this exclusion class fail-closed.
    $derivedInventoryRepo = New-IgnoredCacheRepo -Name 'derived-inventory-failure'
    $derivedInventoryState = Join-Path $testRoot 'state-derived-inventory-failure'
    $derivedInventoryFile = Join-Path $testRoot 'written-derived-inventory-failure.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $derivedInventoryRepo, '-Task', 'derived-inventory-failure', '-StateDirectory', $derivedInventoryState))
    $derivedInventoryLeaf = Join-Path $derivedInventoryRepo '.codex-scratch/log.txt'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $derivedInventoryLeaf) | Out-Null
    [System.IO.File]::WriteAllText($derivedInventoryLeaf, "log`r`n", [System.Text.Encoding]::ASCII)
    $derivedInventoryShim = New-FailingGitShim -Name 'shim-derived-ls-files' -FailCommand 'ls-files'
    $derivedInventory = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $derivedInventoryRepo, '-Task', 'derived-inventory-failure', '-StateDirectory', $derivedInventoryState, '-WrittenPathsFile', $derivedInventoryFile) -PathOverride $derivedInventoryShim
    Assert-True -Name 'derived-cache 9 inventory failure exits non-zero and is loud' -Condition ($derivedInventory.ExitCode -ne 0 -and $derivedInventory.Output -match 'runtime inventory could not be built') -Detail ("exit {0}: {1}" -f $derivedInventory.ExitCode, $derivedInventory.Output)
    Assert-WrittenPaths -Name 'derived-cache 9 inventory failure re-attributes scratch' -Path $derivedInventoryFile -Expected @('.codex-scratch', '.codex-scratch/log.txt')

    # Derived-cache (10): ACCEPTED CONTENT-BLINDNESS GAP. Exclusion is by name; contents, including
    # executable-class files, are never examined by ANY control.
    $derivedExecutableRepo = New-IgnoredCacheRepo -Name 'derived-executable-gap'
    $derivedExecutableState = Join-Path $testRoot 'state-derived-executable-gap'
    $derivedExecutableFile = Join-Path $testRoot 'written-derived-executable-gap.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $derivedExecutableRepo, '-Task', 'derived-executable-gap', '-StateDirectory', $derivedExecutableState))
    $derivedExecutableLeaf = Join-Path $derivedExecutableRepo '.codex-scratch/hook.ps1'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $derivedExecutableLeaf) | Out-Null
    [System.IO.File]::WriteAllText($derivedExecutableLeaf, "Write-Host gap`r`n", [System.Text.Encoding]::ASCII)
    $derivedExecutable = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $derivedExecutableRepo, '-Task', 'derived-executable-gap', '-StateDirectory', $derivedExecutableState, '-WrittenPathsFile', $derivedExecutableFile)
    Assert-True -Name 'derived-cache 10 accepted executable content-blindness gap exits clean' -Condition ($derivedExecutable.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $derivedExecutable.ExitCode, $derivedExecutable.Output)
    Assert-WrittenPaths -Name 'derived-cache 10 accepted executable content-blindness gap emits no paths' -Path $derivedExecutableFile -Expected @()

    # Derived-cache (11): exact name alone is insufficient; current status must be !!, not ??.
    $derivedQuestionRepo = New-IgnoredCacheRepo -Name 'derived-current-question' -IgnoredNames @()
    $derivedQuestionState = Join-Path $testRoot 'state-derived-current-question'
    $derivedQuestionFile = Join-Path $testRoot 'written-derived-current-question.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $derivedQuestionRepo, '-Task', 'derived-current-question', '-StateDirectory', $derivedQuestionState))
    $derivedQuestionLeaf = Join-Path $derivedQuestionRepo '.codex-scratch/log.txt'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $derivedQuestionLeaf) | Out-Null
    [System.IO.File]::WriteAllText($derivedQuestionLeaf, "log`r`n", [System.Text.Encoding]::ASCII)
    $derivedQuestion = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $derivedQuestionRepo, '-Task', 'derived-current-question', '-StateDirectory', $derivedQuestionState, '-WrittenPathsFile', $derivedQuestionFile)
    Assert-True -Name 'derived-cache 11 nonignored exact name exits non-zero' -Condition ($derivedQuestion.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $derivedQuestion.ExitCode)
    Assert-WrittenPaths -Name 'derived-cache 11 nonignored exact name is attributed' -Path $derivedQuestionFile -Expected @('.codex-scratch', '.codex-scratch/log.txt')

    # Derived-cache (12): a snapshot-present ?? exact name cannot use the deletion arm.
    $derivedPreQuestionRepo = New-IgnoredCacheRepo -Name 'derived-snapshot-question' -IgnoredNames @()
    $derivedPreQuestionDirectory = Join-Path $derivedPreQuestionRepo '.codex-scratch'
    New-Item -ItemType Directory -Force -Path $derivedPreQuestionDirectory | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $derivedPreQuestionDirectory 'log.txt'), "log`r`n", [System.Text.Encoding]::ASCII)
    $derivedPreQuestionState = Join-Path $testRoot 'state-derived-snapshot-question'
    $derivedPreQuestionFile = Join-Path $testRoot 'written-derived-snapshot-question.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $derivedPreQuestionRepo, '-Task', 'derived-snapshot-question', '-StateDirectory', $derivedPreQuestionState))
    Remove-Item -LiteralPath $derivedPreQuestionDirectory -Recurse -Force
    $derivedPreQuestion = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $derivedPreQuestionRepo, '-Task', 'derived-snapshot-question', '-StateDirectory', $derivedPreQuestionState, '-WrittenPathsFile', $derivedPreQuestionFile)
    Assert-True -Name 'derived-cache 12 snapshot question-status deletion exits non-zero' -Condition ($derivedPreQuestion.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $derivedPreQuestion.ExitCode)
    Assert-WrittenPaths -Name 'derived-cache 12 snapshot question-status deletion is attributed' -Path $derivedPreQuestionFile -Expected @('.codex-scratch')

    # Derived-cache (13): git's collapsed ignored-directory key carries a trailing slash.
    $derivedSlashRepo = New-IgnoredCacheRepo -Name 'derived-trailing-slash'
    $derivedSlashState = Join-Path $testRoot 'state-derived-trailing-slash'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $derivedSlashRepo, '-Task', 'derived-trailing-slash', '-StateDirectory', $derivedSlashState))
    $derivedSlashLeaf = Join-Path $derivedSlashRepo '.codex-scratch/x'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $derivedSlashLeaf) | Out-Null
    [System.IO.File]::WriteAllText($derivedSlashLeaf, "x`r`n", [System.Text.Encoding]::ASCII)
    [string[]]$derivedSlashPorcelain = @(& $gitPath -C $derivedSlashRepo status --porcelain=v1 --ignored)
    $derivedSlash = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $derivedSlashRepo, '-Task', 'derived-trailing-slash', '-StateDirectory', $derivedSlashState)
    Assert-True -Name 'derived-cache 13 trailing-slash porcelain key is excluded' -Condition (($derivedSlashPorcelain -contains '!! .codex-scratch/') -and $derivedSlash.ExitCode -eq 0) -Detail ("porcelain [{0}], exit {1}: {2}" -f ($derivedSlashPorcelain -join ', '), $derivedSlash.ExitCode, $derivedSlash.Output)

    # Derived-cache (14): old snapshots without statuses fail closed even for a still-ignored cache.
    $derivedOldRepo = New-IgnoredCacheRepo -Name 'derived-old-snapshot'
    $derivedOldDirectory = Join-Path $derivedOldRepo '.codex-scratch'
    New-Item -ItemType Directory -Force -Path $derivedOldDirectory | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $derivedOldDirectory 'before.txt'), "before`r`n", [System.Text.Encoding]::ASCII)
    $derivedOldState = Join-Path $testRoot 'state-derived-old-snapshot'
    $derivedOldFile = Join-Path $testRoot 'written-derived-old-snapshot.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $derivedOldRepo, '-Task', 'derived-old-snapshot', '-StateDirectory', $derivedOldState))
    $derivedOldSnapshotPath = Join-Path $derivedOldState 'scope-derived-old-snapshot.snapshot.json'
    $derivedOldSnapshot = Get-Content -LiteralPath $derivedOldSnapshotPath -Raw | ConvertFrom-Json
    $derivedOldFormat = [ordered]@{
        task = $derivedOldSnapshot.task
        head = $derivedOldSnapshot.head
        dirty = @($derivedOldSnapshot.dirty)
        states = $derivedOldSnapshot.states
        takenUtc = $derivedOldSnapshot.takenUtc
    }
    $derivedOldFormat | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $derivedOldSnapshotPath -Encoding utf8
    [System.IO.File]::WriteAllText((Join-Path $derivedOldDirectory 'after.txt'), "after`r`n", [System.Text.Encoding]::ASCII)
    $derivedOld = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $derivedOldRepo, '-Task', 'derived-old-snapshot', '-StateDirectory', $derivedOldState, '-WrittenPathsFile', $derivedOldFile)
    Assert-True -Name 'derived-cache 14 old snapshot without statuses exits non-zero' -Condition ($derivedOld.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $derivedOld.ExitCode)
    Assert-WrittenPaths -Name 'derived-cache 14 old snapshot without statuses is attributed' -Path $derivedOldFile -Expected @('.codex-scratch', '.codex-scratch/after.txt', '.codex-scratch/before.txt')

    # LOCKSTEP COVERAGE BOUNDARY: this block catches LIST and PRESCRIPTION drift plus per-entry
    # behaviour. Guard-LOGIC weakening is caught by Task 2 cases (3), (4), (6), (11), (12), and
    # (14). Parse and probe only scratch copies: no authorized or read-only source is mutated.
    $lockstepRoot = Join-Path $testRoot 'lockstep-copies'
    New-Item -ItemType Directory -Force -Path $lockstepRoot | Out-Null
    $lockstepChecker = Join-Path $lockstepRoot 'codex-scope-check.ps1'
    $lockstepTreePin = Join-Path $lockstepRoot 'tree-pin.ps1'
    $lockstepDispatchPack = Join-Path $lockstepRoot 'dispatch-pack.md'
    Copy-Item -LiteralPath $checkerPath -Destination $lockstepChecker
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tree-pin.ps1') -Destination $lockstepTreePin
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'references/dispatch-pack.md') -Destination $lockstepDispatchPack

    if ($LockstepProbe -eq 'ExtraDerivedCacheExclusion') {
        $probeText = [System.IO.File]::ReadAllText($lockstepChecker)
        $probeText = $probeText -replace "(?s)(\`$derivedCacheExclusions\s*=\s*@\(.*?)(\r?\n\))", "`$1,`r`n    '.lockstep-probe-cache'`$2"
        [System.IO.File]::WriteAllText($lockstepChecker, $probeText, [System.Text.UTF8Encoding]::new($false))
    }
    elseif ($LockstepProbe -eq 'ExtraToolCacheExclusion') {
        $probeText = [System.IO.File]::ReadAllText($lockstepTreePin)
        $probeText = $probeText -replace "(?s)(\`$toolCacheExclusions\s*=\s*@\(.*?)(\r?\n\s*\))", "`$1,`r`n        '.lockstep-probe-tool-cache'`$2"
        [System.IO.File]::WriteAllText($lockstepTreePin, $probeText, [System.Text.UTF8Encoding]::new($false))
    }
    elseif ($LockstepProbe -eq 'RenameSanctionedDirectory') {
        $probeText = [System.IO.File]::ReadAllText($lockstepDispatchPack).Replace('.codex-scratch/', '.codex-work/')
        [System.IO.File]::WriteAllText($lockstepDispatchPack, $probeText, [System.Text.UTF8Encoding]::new($false))
    }

    [string[]]$lockstepDerived = @(Get-PsArrayLiteral -Path $lockstepChecker -Name 'derivedCacheExclusions')
    [string[]]$lockstepDivergence = @(Get-PsArrayLiteral -Path $lockstepChecker -Name 'derivedCacheDivergence')
    [string[]]$lockstepTool = @(Get-PsArrayLiteral -Path $lockstepTreePin -Name 'toolCacheExclusions')
    Assert-True -Name 'lockstep parse derivedCacheExclusions is nonempty' -Condition ($lockstepDerived.Count -gt 0) -Detail ("parsed [{0}]" -f ($lockstepDerived -join ', '))
    Assert-True -Name 'lockstep parse derivedCacheDivergence is nonempty' -Condition ($lockstepDivergence.Count -gt 0) -Detail ("parsed [{0}]" -f ($lockstepDivergence -join ', '))
    Assert-True -Name 'lockstep parse toolCacheExclusions is nonempty' -Condition ($lockstepTool.Count -gt 0) -Detail ("parsed [{0}]" -f ($lockstepTool -join ', '))

    $derivedLookup = @{}
    foreach ($name in $lockstepDerived) { $derivedLookup[$name.ToLowerInvariant()] = $true }
    $divergenceLookup = @{}
    foreach ($name in $lockstepDivergence) { $divergenceLookup[$name.ToLowerInvariant()] = $true }

    [string[]]$overlap = @($lockstepDerived | Where-Object { $divergenceLookup.ContainsKey($_.ToLowerInvariant()) })
    Assert-True -Name 'lockstep derived exclusion and divergence lists are disjoint' -Condition ($overlap.Count -eq 0) -Detail ("overlap [{0}]" -f ($overlap -join ', '))
    foreach ($name in $lockstepTool) {
        $key = $name.ToLowerInvariant()
        Assert-True -Name ("lockstep tool-cache coverage {0}" -f $name) -Condition ($derivedLookup.ContainsKey($key) -or $divergenceLookup.ContainsKey($key)) -Detail 'tree-pin entry must be an exclusion or an explicit divergence'
    }

    # Mechanical coverage: every parsed exclusion gets both predicate arms in fresh repositories.
    for ($entryIndex = 0; $entryIndex -lt $lockstepDerived.Count; $entryIndex++) {
        $name = $lockstepDerived[$entryIndex]

        $ignoredRepo = New-IgnoredCacheRepo -Name ("lockstep-ignored-{0}" -f $entryIndex) -IgnoredNames @($name)
        $ignoredState = Join-Path $testRoot ("state-lockstep-ignored-{0}" -f $entryIndex)
        [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $ignoredRepo, '-Task', ("lockstep-ignored-{0}" -f $entryIndex), '-StateDirectory', $ignoredState) -CheckerPath $lockstepChecker)
        $ignoredLeaf = Join-Path $ignoredRepo ($name + '/created-during-dispatch.txt')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ignoredLeaf) | Out-Null
        [System.IO.File]::WriteAllText($ignoredLeaf, "derived`r`n", [System.Text.Encoding]::ASCII)
        $ignoredResult = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $ignoredRepo, '-Task', ("lockstep-ignored-{0}" -f $entryIndex), '-StateDirectory', $ignoredState) -CheckerPath $lockstepChecker
        Assert-True -Name ("lockstep per-entry ignored dispatch exclusion {0}" -f $name) -Condition ($ignoredResult.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $ignoredResult.ExitCode, $ignoredResult.Output)

        $questionRepo = New-IgnoredCacheRepo -Name ("lockstep-question-{0}" -f $entryIndex) -IgnoredNames @()
        $questionState = Join-Path $testRoot ("state-lockstep-question-{0}" -f $entryIndex)
        [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $questionRepo, '-Task', ("lockstep-question-{0}" -f $entryIndex), '-StateDirectory', $questionState) -CheckerPath $lockstepChecker)
        $questionLeaf = Join-Path $questionRepo ($name + '/created-during-dispatch.txt')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $questionLeaf) | Out-Null
        [System.IO.File]::WriteAllText($questionLeaf, "untracked`r`n", [System.Text.Encoding]::ASCII)
        [string[]]$questionStatus = @(& $gitPath -C $questionRepo status --porcelain=v1 --untracked-files=all -- $name)
        $questionResult = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $questionRepo, '-Task', ("lockstep-question-{0}" -f $entryIndex), '-StateDirectory', $questionState) -CheckerPath $lockstepChecker
        Assert-True -Name ("lockstep per-entry question-status flags {0}" -f $name) -Condition (@($questionStatus | Where-Object { $_ -match '^\?\?' }).Count -gt 0 -and $questionResult.ExitCode -ne 0) -Detail ("status [{0}], exit {1}: {2}" -f ($questionStatus -join ', '), $questionResult.ExitCode, $questionResult.Output)
    }

    $dispatchText = [System.IO.File]::ReadAllText($lockstepDispatchPack)
    [string[]]$sanctionedNames = @(
        foreach ($match in [regex]::Matches($dispatchText, '(?im)(?:create\s+|exactly one sanctioned scratch directory name:\s*)`(?<name>\.[^`/]+)(?:/)?`[^\r\n]*(?:sanctioned name)?')) {
            $match.Groups['name'].Value
        }
    ) | Sort-Object -Unique
    Assert-True -Name 'lockstep prescription sole sanctioned scratch directory' -Condition ($sanctionedNames.Count -eq 1 -and $sanctionedNames[0] -ceq '.codex-scratch') -Detail ("sanctioned names [{0}]" -f ($sanctionedNames -join ', '))
    $prescriptionPaired = $sanctionedNames.Count -eq 1 -and
        $sanctionedNames[0] -ceq '.codex-scratch' -and
        $derivedLookup.ContainsKey($sanctionedNames[0].ToLowerInvariant())
    Assert-True -Name 'lockstep prescription pairs sanctioned name with derived exclusions' -Condition $prescriptionPaired -Detail ("sanctioned [{0}], derived exclusions [{1}]" -f ($sanctionedNames -join ', '), ($lockstepDerived -join ', '))

    [string[]]$deprecatedNames = @('.scratch', '.apex-tmp', '.sandbox-cache')
    foreach ($deprecatedName in @('.scratch', '.apex-tmp', '.sandbox-cache')) {
        $escapedDeprecated = [regex]::Escape($deprecatedName)
        $deprecatedMentions = @([regex]::Matches($dispatchText, "``$escapedDeprecated/?``"))
        $nonDeprecatedMentions = @(
            foreach ($mention in $deprecatedMentions) {
                $contextStart = [Math]::Max(0, $mention.Index - 200)
                $contextLength = [Math]::Min($dispatchText.Length - $contextStart, $mention.Length + 400)
                if ($dispatchText.Substring($contextStart, $contextLength) -notmatch '(?i)DEPRECATED') {
                    $mention.Value
                }
            }
        )
        $onlyDeprecatedExamples = $nonDeprecatedMentions.Count -eq 0
        Assert-True -Name ("lockstep prescription deprecated-only {0}" -f $deprecatedName) -Condition ($onlyDeprecatedExamples -and $sanctionedNames -notcontains $deprecatedName) -Detail ("found {0} mention(s), {1} outside deprecated context; sanctioned [{2}]" -f $deprecatedMentions.Count, $nonDeprecatedMentions.Count, ($sanctionedNames -join ', '))
    }

    $toolLookup = @{}
    foreach ($name in $lockstepTool) { $toolLookup[$name.ToLowerInvariant()] = $true }
    foreach ($name in $lockstepDerived) {
        $classified = $sanctionedNames -contains $name -or
            $deprecatedNames -contains $name -or
            $toolLookup.ContainsKey($name.ToLowerInvariant())
        Assert-True -Name ("lockstep derived exclusion classification {0}" -f $name) -Condition $classified -Detail 'entry must come from the sole sanctioned prescription, deprecated examples, or the parsed tool-cache list'
    }

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
    if ($null -eq $previousGitConfigGlobal) {
        Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue
    } else {
        $env:GIT_CONFIG_GLOBAL = $previousGitConfigGlobal
    }
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
