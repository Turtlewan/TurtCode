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
$previousApexStateDir = $env:APEX_STATE_DIR

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

function Invoke-DuplicatePathChild([string]$Command) {
    # Replace only the child's raw environment block; StringDictionary cannot hold both keys.
    $childScript = @'
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class DuplicatePathEnvironment { [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool SetEnvironmentStringsW(string block); }'
$entries = @([Environment]::GetEnvironmentVariables().GetEnumerator() | Where-Object {
    -not [string]::Equals($_.Key, 'Path', [StringComparison]::OrdinalIgnoreCase)
} | ForEach-Object { $_.Key + '=' + $_.Value })
$entries += @("Path=$env:Path", "PATH=$env:Path")
$block = [string]::Join([string][char]0, [string[]]$entries) + [char]0 + [char]0
if (-not [DuplicatePathEnvironment]::SetEnvironmentStringsW($block)) { throw 'Could not set duplicate Path/PATH environment.' }
$pathKeys = @([Environment]::GetEnvironmentVariables().Keys | Where-Object {
    [string]::Equals($_, 'Path', [StringComparison]::OrdinalIgnoreCase)
})
if ($pathKeys.Count -ne 2) { throw 'Child environment must contain both Path and PATH.' }
'@ + "`n" + $Command
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1)
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = [string]::Join("`n", ($output | ForEach-Object { [string]$_ }))
    }
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

function Write-FixtureFile {
    param([string]$RepoPath, [string]$Path, [string]$Content = "generated`r`n")
    $fullPath = [System.IO.Path]::Combine($RepoPath, $Path)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fullPath) | Out-Null
    [System.IO.File]::WriteAllText($fullPath, $Content, [System.Text.UTF8Encoding]::new($false))
}

function New-BuildOutputRepo {
    param(
        [string]$Name,
        [AllowNull()][string]$AgentsText = $null,
        [string[]]$Files = @('src/a.py', 'src/App/Program.cs', 'tests/App/ProgramTests.cs'),
        [string]$IgnoreText = "bin/`nobj/`n.hooks/`n"
    )
    $repoPath = New-TestRepo -Name $Name -Files $Files
    Write-FixtureFile -RepoPath $repoPath -Path '.gitignore' -Content $IgnoreText
    if (-not [string]::IsNullOrEmpty($AgentsText)) { Write-FixtureFile -RepoPath $repoPath -Path 'AGENTS.md' -Content $AgentsText }
    Invoke-TestGit -RepoPath $repoPath -GitArguments @('add', '-A')
    Invoke-TestGit -RepoPath $repoPath -GitArguments @('commit', '-q', '-m', 'fixture build-output declarations')
    return $repoPath
}

function New-AgentsFetchFailureShim {
    param([string]$Name, [ValidateSet('ls-tree', 'show')][string]$FailCommand, [string]$Head)
    $shimPath = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Force -Path $shimPath | Out-Null
    # Match only the committed-AGENTS fetch, leaving the separate HEAD inventory operational.
    $failLine = if ($FailCommand -ceq 'ls-tree') {
        'if "%~3"=="ls-tree" if "%~4"=="--full-tree" if "%~5"=="--name-only" if "%~9"=="AGENTS.md" exit /b 42'
    } else {
        ('if "%~3"=="show" if "%~4"=="{0}:AGENTS.md" exit /b 42' -f $Head)
    }
    [System.IO.File]::WriteAllLines((Join-Path $shimPath 'git.cmd'), [string[]]@(
        '@echo off', $failLine, ('"{0}" %*' -f $gitPath), 'exit /b %ERRORLEVEL%'
    ), [System.Text.Encoding]::ASCII)
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

function New-RuntimeMarkerRepo {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Files = @('src/a.py', 'skills/apex/SKILL.md')
    )

    $repoPath = New-TestRepo -Name $Name -Files $Files
    $ignorePath = Join-Path -Path $repoPath -ChildPath '.gitignore'
    [System.IO.File]::WriteAllText(
        $ignorePath,
        "/skills/synced/`n/skills/synced-foo/`n",
        [System.Text.UTF8Encoding]::new($false)
    )
    Invoke-TestGit -RepoPath $repoPath -GitArguments @('add', '--', '.gitignore')
    Invoke-TestGit -RepoPath $repoPath -GitArguments @('commit', '-q', '-m', 'add runtime marker ignores')
    return $repoPath
}

function Write-RuntimeMarkers {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [string]$Content = "marker`r`n"
    )

    foreach ($relativePath in @(
            'skills/synced/.bucket-u1',
            'skills/synced/u1/.last-complete-round',
            'skills/synced/u1/manifest.json'
        )) {
        $fullPath = Join-Path -Path $RepoPath -ChildPath $relativePath
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $fullPath) | Out-Null
        [System.IO.File]::WriteAllText($fullPath, $Content, [System.Text.Encoding]::ASCII)
    }
}

function Write-RuntimeMarkerSeed {
    param([Parameter(Mandatory = $true)][string]$RepoPath)

    Write-RuntimeMarkers -RepoPath $RepoPath
    $skillPath = Join-Path -Path $RepoPath -ChildPath 'skills/synced/u1/docs/SKILL.md'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $skillPath) | Out-Null
    [System.IO.File]::WriteAllText($skillPath, "seeded skill`r`n", [System.Text.Encoding]::ASCII)
}

try {
    if (-not (Test-Path -LiteralPath $checkerPath -PathType Leaf)) {
        throw "Scope checker was not found at '$checkerPath'."
    }
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    $env:APEX_STATE_DIR = Join-Path $testRoot 'apex-state'
    $fixtureGitConfig = Join-Path $testRoot 'fixture.gitconfig'
    $fixtureGitIgnore = Join-Path $testRoot 'fixture-global-ignore'
    [System.IO.File]::WriteAllText($fixtureGitIgnore, '', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($fixtureGitConfig,
        ("[core]`n    excludesFile = {0}`n" -f ($fixtureGitIgnore -replace '\\', '/')),
        [System.Text.UTF8Encoding]::new($false))
    $env:GIT_CONFIG_GLOBAL = $fixtureGitConfig

    # Git must not inherit the job host's remoting pipe as stdin.
    $jobRepo = New-TestRepo -Name 'job-stdin'
    Write-FixtureFile -RepoPath $jobRepo -Path 'untracked.txt'
    $jobState = Join-Path $testRoot 'state-job-stdin'
    $job = Start-Job -ScriptBlock {
        param($Checker, $Repo, $State)
        $ErrorActionPreference = 'Stop'
        & $Checker -Snapshot -Worktree $Repo -Task 'job-stdin' -StateDirectory $State
    } -ArgumentList $checkerPath, $jobRepo, $jobState
    try {
        $finished = Wait-Job -Job $job -Timeout 60
        if ($null -eq $finished) { Stop-Job -Job $job }
        $completed = $null -ne $finished -and $job.State -eq 'Completed'
        Assert-True -Name 'Snapshot job completes within 60 seconds' -Condition $completed -Detail ("job state: {0}" -f $job.State)
        if ($null -ne $finished) {
            $jobErrors = @()
            $jobOutput = @(Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrors)
            Assert-True -Name 'Snapshot job succeeds and writes its snapshot' -Condition ($completed -and $jobErrors.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $jobState 'scope-job-stdin.snapshot.json'))) -Detail ("job errors: {0}; {1}" -f $jobErrors.Count, (($jobOutput + $jobErrors) -join [Environment]::NewLine))
        }
    } finally {
        Remove-Job -Job $job -Force
    }

    # Test the same adapter used by the CLI; stop immediately on argument failure.
    $scopeSource = [IO.File]::ReadAllText($checkerPath)
    $displayStart = $scopeSource.IndexOf('function ConvertTo-DisplayPath')
    $displayEnd = $scopeSource.IndexOf('# Multiple modes')
    Invoke-Expression $scopeSource.Substring($displayStart, $displayEnd - $displayStart)
    $displayFixture = 'C:\Users\' + [char]0x00e9 + "`t"
    Assert-True -Name 'filesystem display preserves separators and escapes Unicode/control characters' -Condition ((ConvertTo-DisplayPath $displayFixture -FileSystem) -ceq 'C:\Users\\u00e9\u0009') -Detail 'filesystem backslashes remain literal'
    Assert-True -Name 'Git display still escapes backslash characters' -Condition ((ConvertTo-DisplayPath $displayFixture) -ceq 'C:\u005cUsers\u005c\u00e9\u0009') -Detail 'Git backslashes remain escaped'
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($checkerPath, [ref]$tokens, [ref]$parseErrors)
    $markerFunction = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-IsRuntimeMarker' }, $true)
    . ([scriptblock]::Create($markerFunction.Extent.Text))
    $savedCulture = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
        Assert-True -Name 'runtime marker membership uses ordinal case folding under Turkish culture' -Condition (Test-IsRuntimeMarker 'SKILLS/SYNCED/u1/MANIFEST.JSON') -Detail 'uppercase manifest is a marker'
        Assert-True -Name 'bucket marker membership uses ordinal case folding under Turkish culture' -Condition (Test-IsRuntimeMarker 'SKILLS/SYNCED/.BUCKET-u1') -Detail 'uppercase bucket is a marker'
        Assert-True -Name 'runtime marker suffix keeps distinct Unicode names distinct' -Condition (-not (Test-IsRuntimeMarker ('skills/synced/u1/man' + [char]0xFEFF + 'ifest.json'))) -Detail 'embedded U+FEFF is filename content'
        Assert-True -Name 'runtime marker prefix rejects a Kelvin-sign look-alike' -Condition (-not (Test-IsRuntimeMarker ('s' + [char]0x212A + 'ills/synced/u1/manifest.json'))) -Detail 'U+212A does not match ASCII k'
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture }
    $helperStart = $scopeSource.IndexOf('function ConvertTo-GitArgument')
    $helperEnd = $scopeSource.IndexOf('# Authorized/spec')
    Invoke-Expression $scopeSource.Substring($helperStart, $helperEnd - $helperStart)
    function Start-PathSnapshot([string]$Fixture, [string]$Name, [string]$ShimPath = '') {
        $stateDir = Join-Path $testRoot ('state-path-' + $Name)
        $result = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $Fixture, '-Task', $Name, '-StateDirectory', $stateDir) -PathOverride $ShimPath
        Assert-True -Name "$Name snapshot" -Condition ($result.ExitCode -eq 0) -Detail $result.Output | Out-Host
        return $stateDir
    }
    function Check-PathFixture([string]$Fixture, [string]$Name, [string]$State, [string]$Allow = '', [string]$ShimPath = '') {
        $arguments = @('-Check', '-Worktree', $Fixture, '-Task', $Name, '-StateDirectory', $State)
        if ($Allow) { $arguments += @('-Authorized', $Allow) }
        return Invoke-ScopeCheck -CheckerArguments $arguments -PathOverride $ShimPath
    }
    function Test-ExactViolation([string]$Output, [string]$Path) {
        $displayPath = [regex]::Replace($Path, '[^\x20-\x7e]|\\', {
            param($match)
            '\u{0:x4}' -f [int][char]$match.Value
        })
        return @($Output -split '\r\n|\r|\n' | Where-Object {
            $_.Length -ge 8 -and $_.StartsWith('    ') -and
            [string]::Equals($_.Substring(8), $displayPath, [StringComparison]::Ordinal)
        }).Count -gt 0
    }

    # Log every positional argument; the shim forwards the original %* unchanged.
    $transportDir = Join-Path $testRoot 'transport shim'
    New-Item -ItemType Directory -Path $transportDir | Out-Null
    $transportLog = Join-Path $testRoot 'transport-args.txt'
    $transportRecorder = Join-Path $transportDir 'record.ps1'
    $recorderText = 'param([string]$Log, [Parameter(ValueFromRemainingArguments=$true)][string[]]$Received); [IO.File]::AppendAllText($Log, (ConvertTo-Json -Compress -InputObject @($Received)) + "`n", [Text.UTF8Encoding]::new($false))'
    [IO.File]::WriteAllText($transportRecorder, $recorderText, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllLines((Join-Path $transportDir 'git.cmd'), [string[]]@(
        '@echo off',
        ('"{0}" -NoProfile -File "{1}" "{2}" %*' -f $powerShellPath, $transportRecorder, $transportLog),
        ('"{0}" %*' -f $gitPath), 'exit /b %ERRORLEVEL%'
    ), [Text.Encoding]::ASCII)
    $transportPath = $transportDir + [IO.Path]::PathSeparator + $env:PATH
    $transportRepo = New-TestRepo -Name 'transport' -Files @('a&b.txt')
    $duplicateState = Join-Path $testRoot 'state-duplicate-path'
    $duplicatePath = Invoke-DuplicatePathChild ("& '{0}' -Snapshot -Worktree '{1}' -Task duplicate-path -StateDirectory '{2}'" -f $checkerPath.Replace("'", "''"), $transportRepo.Replace("'", "''"), $duplicateState.Replace("'", "''"))
    Assert-True -Name 'Snapshot succeeds with duplicate Path/PATH environment' -Condition ($duplicatePath.ExitCode -eq 0 -and (Test-Path -LiteralPath (Join-Path $duplicateState 'scope-duplicate-path.snapshot.json'))) -Detail $duplicatePath.Output
    $repo = $transportRepo
    $gitError = ''
    try { $null = Invoke-Git invalid-command-for-display-test }
    catch { $gitError = $_.Exception.Message }
    Assert-True -Name 'Git failure displays filesystem separators literally' -Condition ($gitError.Contains($repo) -and -not $gitError.Contains('\u005c')) -Detail $gitError
    $transportState = Start-PathSnapshot $transportRepo 'transport' $transportPath
    $recordedCalls = @([IO.File]::ReadAllLines($transportLog) | ForEach-Object { ,(ConvertFrom-Json $_) })
    $logCalls = @($recordedCalls | Where-Object { $_[2] -ceq 'log' })
    $transportSnap = Get-Content -LiteralPath (Join-Path $transportState 'scope-transport.snapshot.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $expectedTime = @(& $gitPath -C $transportRepo log -1 '--format=%cI')[0]
    Assert-True -Name 'shim format percent and argument positions' -Condition ($logCalls.Count -eq 1 -and $logCalls[0][4] -ceq '--format=%cI' -and $transportSnap.takenUtc -ceq $expectedTime) -Detail 'log format is exactly --format=%cI and takenUtc equals real git'
    Write-FixtureFile $transportRepo 'a&b.txt' 'changed ampersand'
    $result = Check-PathFixture $transportRepo 'transport' $transportState 'a&b.txt' $transportPath
    Assert-True -Name 'shim literal ampersand authorized' -Condition ($result.ExitCode -eq 0) -Detail $result.Output
    $transportState = Start-PathSnapshot $transportRepo 'transport-deny' $transportPath
    Write-FixtureFile $transportRepo 'a&b.txt' 'changed again'
    $result = Check-PathFixture $transportRepo 'transport-deny' $transportState '' $transportPath
    Assert-True -Name 'shim literal ampersand checked' -Condition ($result.ExitCode -eq 1 -and (Test-ExactViolation $result.Output 'a&b.txt')) -Detail $result.Output

    foreach ($quoteSetting in @('true', 'false')) {
        $unicodePath = 'src/' + [char]0x00e9 + '.py'
        $spacePath = 'src/internal space.py'
        $bracketPath = 'src/[id].py'
        $oldPath = 'src/' + [char]0x00e9 + ' old [id].py'
        $newPath = 'src/' + [char]0x00e9 + ' new [id].py'
        $repo = New-TestRepo -Name "decoded-$quoteSetting" -Files @($unicodePath, $spacePath, $bracketPath, $oldPath, 'untouched.txt')
        Invoke-TestGit $repo @('config', 'core.quotepath', $quoteSetting)
        Write-FixtureFile $repo $unicodePath 'unique unicode blob'
        Invoke-TestGit $repo @('add', '--', $unicodePath)
        Invoke-TestGit $repo @('commit', '-q', '-m', 'distinct unicode blob')
        $ownBlob = @(& $gitPath -C $repo rev-parse "HEAD:$unicodePath")[0]
        $indexed = @(Invoke-Git ls-files -s '--' $unicodePath)
        if ($indexed.Count -ne 1 -or ($indexed[0] -split '\s+')[1] -cne $ownBlob) {
            throw "BLOCKED: ls-files -s -- src/U+00E9.py Unicode argument round-trip failed ($quoteSetting)."
        }
        $hashed = @(Invoke-Git hash-object '--' $unicodePath)
        if ($hashed.Count -ne 1 -or $hashed[0] -cne $ownBlob) {
            throw "BLOCKED: hash-object -- src/U+00E9.py Unicode argument round-trip failed ($quoteSetting)."
        }
        Assert-True -Name "Unicode argument round-trips $quoteSetting" -Condition $true -Detail 'ls-files -s and hash-object select their own distinct blob'
        $name = "decoded-allow-$quoteSetting"
        $stateDir = Start-PathSnapshot $repo $name
        foreach ($path in @($unicodePath, $spacePath, $bracketPath)) { Write-FixtureFile $repo $path "changed $path" }
        $result = Check-PathFixture $repo $name $stateDir 'src'
        Assert-True -Name "$name authorized" -Condition ($result.ExitCode -eq 0 -and -not (Test-ExactViolation $result.Output 'untouched.txt')) -Detail $result.Output
        $name = "decoded-deny-$quoteSetting"
        $stateDir = Start-PathSnapshot $repo $name
        foreach ($path in @($unicodePath, $spacePath, $bracketPath)) { Write-FixtureFile $repo $path "changed again $path" }
        Invoke-TestGit $repo @('mv', '--', $oldPath, $newPath)
        $renameSnapPath = Join-Path $stateDir ("scope-$name.snapshot.json")
        $renameSnapBytes = [IO.File]::ReadAllBytes($renameSnapPath)
        $unicodeSnap = Get-Content -LiteralPath $renameSnapPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True -Name "Unicode snapshot own indexed blob $quoteSetting" -Condition ($unicodeSnap.states.PSObject.Properties[$unicodePath].Value.EndsWith("index:100644:$ownBlob", [StringComparison]::Ordinal)) -Detail "snapshot uses the own indexed Unicode blob"
        $result = Check-PathFixture $repo $name $stateDir
        $accurate = $result.ExitCode -eq 1
        foreach ($path in @($unicodePath, $spacePath, $bracketPath, $oldPath, $newPath)) { $accurate = $accurate -and (Test-ExactViolation $result.Output $path) }
        Assert-True -Name "$name real paths and both rename sides" -Condition ($accurate -and -not (Test-ExactViolation $result.Output 'untouched.txt')) -Detail $result.Output
        foreach ($allowedSide in @($oldPath, $newPath)) {
            [IO.File]::WriteAllBytes($renameSnapPath, $renameSnapBytes)
            $result = Check-PathFixture $repo $name $stateDir $allowedSide
            $deniedSide = if ($allowedSide -ceq $oldPath) { $newPath } else { $oldPath }
            Assert-True -Name "$name rename authorization $allowedSide" -Condition ($result.ExitCode -eq 1 -and (Test-ExactViolation $result.Output $deniedSide) -and -not (Test-ExactViolation $result.Output $allowedSide)) -Detail $result.Output
        }
    }

    foreach ($prefix in @(' ', ([string][char]0xFEFF))) {
        $label = if ($prefix -ceq ' ') { 'leading-space' } else { 'leading-feff' }
        $variant = $prefix + 'keep.txt'
        $repo = New-TestRepo -Name $label -Files @('keep.txt', $variant)
        Write-FixtureFile $repo $variant 'distinct variant content'
        Invoke-TestGit $repo @('add', '-A')
        Invoke-TestGit $repo @('commit', '-q', '-m', 'distinct variant')
        $firstRecords = @(Invoke-Git -NulRecords ls-files -z '--' $variant)
        Assert-True -Name "$label first NUL record preserves prefix" -Condition ($firstRecords.Count -eq 1 -and [string]::Equals($firstRecords[0], $variant, [StringComparison]::Ordinal)) -Detail 'the first filename retains its whitespace or U+FEFF prefix'
        $stateDir = Start-PathSnapshot $repo "$label-only"
        Write-FixtureFile $repo 'keep.txt' 'only keep edited'
        $result = Check-PathFixture $repo "$label-only" $stateDir 'keep.txt'
        Assert-True -Name "$label keep only" -Condition ($result.ExitCode -eq 0 -and -not (Test-ExactViolation $result.Output $variant)) -Detail $result.Output
        $stateDir = Start-PathSnapshot $repo "$label-both"
        Write-FixtureFile $repo 'keep.txt' 'keep edited again'
        Write-FixtureFile $repo $variant 'variant edited'
        $dirtyState = Start-PathSnapshot $repo "$label-records"
        $dirtySnap = Get-Content -LiteralPath (Join-Path $dirtyState "scope-$label-records.snapshot.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-True -Name "$label distinct dirty records" -Condition ($dirtySnap.dirty.Count -eq 2 -and @($dirtySnap.dirty | Where-Object { [string]::Equals($_, $variant, [StringComparison]::Ordinal) }).Count -eq 1) -Detail 'both exact paths survive snapshot serialization'
        $bothSnapshotPath = Join-Path $stateDir "scope-$label-both.snapshot.json"
        $bothSnapshotBytes = [IO.File]::ReadAllBytes($bothSnapshotPath)
        $result = Check-PathFixture $repo "$label-both" $stateDir 'keep.txt'
        Assert-True -Name "$label exact unauthorized path" -Condition ($result.ExitCode -eq 1 -and (Test-ExactViolation $result.Output $variant) -and -not (Test-ExactViolation $result.Output 'keep.txt')) -Detail $result.Output
        [IO.File]::WriteAllBytes($bothSnapshotPath, $bothSnapshotBytes)
        $writtenPath = Join-Path $testRoot "$label-written.txt"
        $result = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $repo, '-Task', "$label-both", '-StateDirectory', $stateDir, '-Authorized', 'keep.txt', '-WrittenPathsFile', $writtenPath)
        # Decode raw bytes so a first U+FEFF filename is not consumed as a BOM.
        $writtenText = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($writtenPath))
        $writtenRecords = @([regex]::Split($writtenText, '\r\n|\r|\n'))
        if ($writtenRecords[-1].Length -eq 0) { $writtenRecords = @($writtenRecords | Select-Object -SkipLast 1) }
        Assert-True -Name "$label written paths remain distinct" -Condition ($result.ExitCode -eq 1 -and $writtenRecords.Count -eq 2 -and @($writtenRecords | Where-Object { [string]::Equals($_, 'keep.txt', [StringComparison]::Ordinal) }).Count -eq 1 -and @($writtenRecords | Where-Object { [string]::Equals($_, $variant, [StringComparison]::Ordinal) }).Count -eq 1) -Detail 'WrittenPathsFile contains both exact filenames'
    }

    $nbsp = [string][char]0x00A0
    $repo = New-TestRepo -Name 'whitespace-only' -Files @('keep.txt')
    $nbspAccepted = $true
    try { Write-FixtureFile $repo $nbsp 'whitespace filename' }
    catch { $nbspAccepted = $false; Write-Output "SKIP whitespace-only filesystem rejection: $($_.Exception.Message)" }
    if ($nbspAccepted) {
        Invoke-TestGit $repo @('add', '-A')
        Invoke-TestGit $repo @('commit', '-q', '-m', 'whitespace path')
        Write-FixtureFile $repo $nbsp 'host edit'
        $stateDir = Start-PathSnapshot $repo 'nbsp'
        $nbspSnap = Get-Content -LiteralPath (Join-Path $stateDir 'scope-nbsp.snapshot.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-FixtureFile $repo $nbsp 'dispatch edit'
        $result = Check-PathFixture $repo 'nbsp' $stateDir
        Assert-True -Name 'whitespace-only path survives snapshot and check' -Condition ($nbspSnap.dirty.Count -eq 1 -and [string]::Equals($nbspSnap.dirty[0], $nbsp, [StringComparison]::Ordinal) -and $result.ExitCode -eq 1 -and (Test-ExactViolation $result.Output $nbsp)) -Detail $result.Output
    }

    $repo = New-TestRepo -Name 'glob-collision' -Files @('0.txt', '[0a].txt')
    Write-FixtureFile $repo '[0a].txt' 'unique bracket blob'
    Invoke-TestGit $repo @('add', '-A')
    Invoke-TestGit $repo @('commit', '-q', '-m', 'distinct glob collision')
    $bracketBlob = @(& $gitPath -C $repo rev-parse 'HEAD:[0a].txt')[0]
    $indexed = @(Invoke-Git ls-files -s '--' '[0a].txt')
    Assert-True -Name 'glob collision own indexed blob' -Condition ($indexed.Count -eq 1 -and ($indexed[0] -split '\s+')[1] -ceq $bracketBlob) -Detail ($indexed -join ', ')
    Write-FixtureFile $repo '[0a].txt' 'host bracket edit'
    $stateDir = Start-PathSnapshot $repo 'glob'
    $globSnap = Get-Content -LiteralPath (Join-Path $stateDir 'scope-glob.snapshot.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Name 'glob collision snapshot indexed blob' -Condition ($globSnap.states.'[0a].txt'.EndsWith("index:100644:$bracketBlob", [StringComparison]::Ordinal)) -Detail $globSnap.states.'[0a].txt'
    Write-FixtureFile $repo '[0a].txt' 'dispatch bracket edit'
    $result = Check-PathFixture $repo 'glob' $stateDir
    Assert-True -Name 'glob collision attribution' -Condition ($result.ExitCode -eq 1 -and (Test-ExactViolation $result.Output '[0a].txt') -and -not (Test-ExactViolation $result.Output '0.txt')) -Detail $result.Output

    $crDeclaration = '## Build outputs' + "`r" + '```text' + "`r" + 'generated' + "`r" + '```' + "`r"
    $repo = New-BuildOutputRepo -Name 'cr-only-agents' -AgentsText $crDeclaration -IgnoreText "generated/`n"
    $stateDir = Start-PathSnapshot $repo 'cr-only'
    Write-FixtureFile $repo 'generated/output.txt' 'ignored declared output'
    $result = Check-PathFixture $repo 'cr-only' $stateDir
    Assert-True -Name 'CR-only show preserves build declaration' -Condition ($result.ExitCode -eq 0 -and $result.Output -match '1 declared build-output path') -Detail $result.Output

    $repo = New-TestRepo -Name 'percent-path' -Files @('%OS%.txt')
    $stateDir = Start-PathSnapshot $repo 'percent-real'
    Write-FixtureFile $repo '%OS%.txt' 'percent edit'
    $result = Check-PathFixture $repo 'percent-real' $stateDir '%OS%.txt'
    Assert-True -Name 'real exe percent path' -Condition ($result.ExitCode -eq 0) -Detail $result.Output
    $stateDir = Start-PathSnapshot $repo 'percent-shim-check'
    Write-FixtureFile $repo '%OS%.txt' 'percent edited again'
    $result = Check-PathFixture $repo 'percent-shim-check' $stateDir '' $transportPath
    Assert-True -Name 'shim percent check fails closed' -Condition ($result.ExitCode -ne 0 -and $result.Output -match 'failed to launch' -and $result.Output -match 'percent') -Detail $result.Output
    $result = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $repo, '-Task', 'percent-shim-snapshot', '-StateDirectory', $stateDir) -PathOverride $transportPath
    Assert-True -Name 'shim percent snapshot fails closed' -Condition ($result.ExitCode -ne 0 -and $result.Output -match 'failed to launch' -and $result.Output -match 'percent') -Detail $result.Output

    $invalidDir = Join-Path $testRoot 'invalid-utf8-shim'
    New-Item -ItemType Directory -Path $invalidDir | Out-Null
    $invalidBytes = Join-Path $invalidDir 'invalid.bin'
    [IO.File]::WriteAllBytes($invalidBytes, [byte[]]@(0xFF, 0x41))
    [IO.File]::WriteAllLines((Join-Path $invalidDir 'git.cmd'), [string[]]@(
        '@echo off', ('if "%~3"=="status" (type "{0}" & exit /b 0)' -f $invalidBytes),
        ('"{0}" %*' -f $gitPath), 'exit /b %ERRORLEVEL%'
    ), [Text.Encoding]::ASCII)
    $invalidPath = $invalidDir + [IO.Path]::PathSeparator + $env:PATH
    $result = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $repo, '-Task', 'invalid-utf8', '-StateDirectory', $stateDir) -PathOverride $invalidPath
    Assert-True -Name 'invalid UTF-8 status refuses verdict' -Condition ($result.ExitCode -ne 0 -and $result.Output -match 'failed to launch' -and $result.Output -match 'Refusing to report clean') -Detail $result.Output
    $result = Check-PathFixture $repo 'percent-shim-check' $stateDir '' $invalidPath
    Assert-True -Name 'invalid UTF-8 direct check refuses verdict' -Condition ($result.ExitCode -ne 0 -and $result.Output -match 'failed to launch' -and $result.Output -match 'Refusing to report clean') -Detail $result.Output

    # Exercise the shared pure functions without invoking the checker or adding a dot-sourced
    # module. End-to-end fixtures below separately prove committed provenance and status gating.
    $checkerText = [System.IO.File]::ReadAllText($checkerPath)
    $buildOutputBlock = [regex]::Match($checkerText, '(?ms)^# BEGIN build-outputs lockstep\r?\n.*?^# END build-outputs lockstep')
    if (-not $buildOutputBlock.Success) { throw 'Missing build-outputs lockstep block' }
    $buildOutputProbes = @'
$validText = "## Build outputs`n``````text`nsrc/*/bin`n```````n"
$parsed = ConvertFrom-BuildOutputsSection -Text $validText
[pscustomobject]@{ Name = 'parser valid declaration'; Pass = @($parsed.Entries).Count -eq 1 -and -not $parsed.Warning; Detail = $validText }
foreach ($probe in @(
    @{ Path = 'SRC/App/BIN'; Match = $true },
    @{ Path = 'src/App/bin/output.dll'; Match = $true },
    @{ Path = 'src/bin'; Match = $false },
    @{ Path = 'src/App'; Match = $false },
    @{ Path = 'src/App/sub/bin'; Match = $false },
    @{ Path = 'src/App/binary'; Match = $false }
)) {
    $matched = Test-IsDeclaredBuildOutputPath -Path $probe.Path -Entries $parsed.Entries
    [pscustomobject]@{ Name = ('parser segment prefix ' + $probe.Path); Pass = $matched -eq $probe.Match; Detail = "expected $($probe.Match), got $matched" }
}
$wildEntries = @('src/App*/pre*post/bin')
foreach ($probe in @(
    @{ Path = 'src/Application/pre-middle-post/bin/x'; Match = $true },
    @{ Path = 'src/App/prepost/bin'; Match = $true },
    @{ Path = 'src/Application/pre/middle/post/bin'; Match = $false }
)) {
    $matched = Test-IsDeclaredBuildOutputPath -Path $probe.Path -Entries $wildEntries
    [pscustomobject]@{ Name = ('parser within-segment star ' + $probe.Path); Pass = $matched -eq $probe.Match; Detail = "expected $($probe.Match), got $matched" }
}
foreach ($entry in @('src/[App]/bin', 'src/{App}/bin', 'src/!App/bin', './bin', 'src/./bin', 'src/../bin', 'src/.GIT/bin', '//server/share/bin', 'src//bin')) {
    $parsed = ConvertFrom-BuildOutputsSection -Text ("## Build outputs`n```````n$entry`n```````n")
    [pscustomobject]@{ Name = ('parser rejects ' + $entry); Pass = @($parsed.Entries).Count -eq 0 -and [bool]$parsed.Warning; Detail = [string]$parsed.Warning }
}
foreach ($info in @('powershell', 'TEXT')) {
    $parsed = ConvertFrom-BuildOutputsSection -Text ("## Build outputs`n``````$info`nsrc/*/bin`n```````n")
    [pscustomobject]@{ Name = ('parser rejects fence info ' + $info); Pass = @($parsed.Entries).Count -eq 0 -and [bool]$parsed.Warning; Detail = [string]$parsed.Warning }
}
foreach ($entryCount in @(32, 33)) {
    $entries = @(for ($entryIndex = 0; $entryIndex -lt $entryCount; $entryIndex++) { "output$entryIndex" })
    $parsed = ConvertFrom-BuildOutputsSection -Text ("## Build outputs`n```````n" + ($entries -join "`n") + "`n```````n")
    $expectedCount = if ($entryCount -eq 32) { 32 } else { 0 }
    [pscustomobject]@{ Name = ("parser entry bound $entryCount"); Pass = @($parsed.Entries).Count -eq $expectedCount -and [bool]$parsed.Warning -eq ($entryCount -eq 33); Detail = ("entries={0}; warning={1}" -f @($parsed.Entries).Count, $parsed.Warning) }
}
foreach ($text in @('', "## Build outputs example`n", "## build outputs`n", "## Build Outputs`n", "##  Build outputs`n", "~~~markdown`n## Build outputs`n~~~`n")) {
    $parsed = ConvertFrom-BuildOutputsSection -Text $text
    [pscustomobject]@{ Name = 'parser absent or fenced heading'; Pass = @($parsed.Entries).Count -eq 0 -and -not $parsed.Warning; Detail = ('text: ' + $text) }
}
$parsed = ConvertFrom-BuildOutputsSection -Text "## Build outputs`n``````text`nsrc/*/bin`n"
[pscustomobject]@{ Name = 'parser unclosed fence'; Pass = @($parsed.Entries).Count -eq 0 -and [bool]$parsed.Warning; Detail = [string]$parsed.Warning }
$parsed = ConvertFrom-BuildOutputsSection -Text ($validText + "## Another section`n``````text`nother prose`n```````n")
[pscustomobject]@{ Name = 'parser fence after next heading allowed'; Pass = @($parsed.Entries).Count -eq 1 -and -not $parsed.Warning; Detail = [string]$parsed.Warning }
'@
    foreach ($probe in @(& ([scriptblock]::Create($buildOutputBlock.Value + "`n" + $buildOutputProbes)))) {
        Assert-True -Name $probe.Name -Condition $probe.Pass -Detail ('pure block: ' + $probe.Detail)
    }

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
    # A BOM-free snapshot must explicitly read UTF-8 in PowerShell 5.1. Otherwise a quoted
    # non-ASCII host filename is decoded with the ANSI code page and spuriously re-attributed.
    $unicodeHostPath = 'host-' + [char]0x00E9 + '.txt'
    Write-FixtureFile -RepoPath $authorizedUntouchedRepo -Path $unicodeHostPath
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

    # (9) A new untracked directory emits only the enumerated leaf paths.
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
    Assert-WrittenPaths -Name 'written paths new-directory reports sensitive leaf' -Path $newDirectoryFile -Expected @('scratch/nested/.env')

    # (10) A vanished untracked directory retains each snapshot leaf's identity.
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
    Assert-WrittenPaths -Name 'written paths gone-directory emits vanished leaf' -Path $goneDirectoryFile -Expected @('host-scratch/draft.txt')

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

    # (16) A modified untracked leaf does not attribute its unchanged siblings.
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
    Assert-WrittenPaths -Name 'written paths modified-directory names changed leaf' -Path $modifiedDirectoryFile -Expected @('scratch/nested/b.txt')

    # (17) Leaf enumeration identifies a deleted untracked leaf exactly.
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
    Assert-WrittenPaths -Name 'written paths deleted-leaf names deleted leaf' -Path $deletedLeafFile -Expected @('scratch/nested/delete.txt')

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
    Assert-WrittenPaths -Name 'runtime root pin attributes leaf' -Path $runtimePinFile -Expected @('projects/session-x.jsonl')

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

    # Runtime exclusion (10): ?? to staged A is changed; the other runtime leaf remains churn.
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
    Assert-WrittenPaths -Name 'runtime staged leaf remains attributed' -Path $runtimeCollapsedFile -Expected @('projects/a.jsonl')

    # Runtime exclusion (10b): an ignored /projects/ token is curated by an indexed descendant.
    $runtimeIgnoredRepo = New-IgnoredCacheRepo -Name 'runtime-ignored-curated' -IgnoredNames @('projects')
    Write-FixtureFile -RepoPath $runtimeIgnoredRepo -Path 'projects/a.jsonl' -Content "a`r`n"
    Write-FixtureFile -RepoPath $runtimeIgnoredRepo -Path 'projects/b.jsonl' -Content "b`r`n"
    $runtimeIgnoredState = Join-Path $testRoot 'state-runtime-ignored-curated'
    $runtimeIgnoredFile = Join-Path $testRoot 'written-runtime-ignored-curated.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeIgnoredRepo, '-Task', 'runtime-ignored-curated', '-StateDirectory', $runtimeIgnoredState))
    $runtimeIgnoredSnap = Get-Content -LiteralPath (Join-Path $runtimeIgnoredState 'scope-runtime-ignored-curated.snapshot.json') -Raw | ConvertFrom-Json
    Assert-True -Name 'runtime ignored curated fixture starts with collapsed !! projects token' -Condition ($runtimeIgnoredSnap.statuses.'projects/' -ceq '!!') -Detail (@($runtimeIgnoredSnap.dirty) -join ', ')
    Invoke-TestGit -RepoPath $runtimeIgnoredRepo -GitArguments @('add', '-f', '--', 'projects/a.jsonl')
    Write-FixtureFile -RepoPath $runtimeIgnoredRepo -Path 'projects/b.jsonl' -Content "b changed`r`n"
    $runtimeIgnored = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeIgnoredRepo, '-Task', 'runtime-ignored-curated', '-StateDirectory', $runtimeIgnoredState, '-RuntimeExclusionRoot', $runtimeIgnoredRepo, '-WrittenPathsFile', $runtimeIgnoredFile)
    Assert-True -Name 'runtime ignored indexed descendant keeps collapsed snapshot token checked' -Condition ($runtimeIgnored.ExitCode -eq 1 -and $runtimeIgnored.Output -match '(?m)^\s*GONE\s+projects(?:/|\s|$)') -Detail $runtimeIgnored.Output
    Assert-WrittenPaths -Name 'runtime ignored curated token and descendants attributed' -Path $runtimeIgnoredFile -Expected @('projects', 'projects/a.jsonl', 'projects/b.jsonl')

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
    Assert-WrittenPaths -Name 'runtime ls-files inventory failure attributes churn' -Path $runtimeLsFilesFile -Expected @('projects/session-x.jsonl')
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
    Assert-WrittenPaths -Name 'runtime ls-tree inventory failure attributes churn' -Path $runtimeLsTreeFile -Expected @('projects/session-x.jsonl')
    Assert-True -Name 'runtime ls-tree inventory failure is loud' -Condition ($runtimeLsTree.Output -match 'runtime inventory could not be built') -Detail $runtimeLsTree.Output
    Assert-True -Name 'runtime 13 failed declarations lookup is distinct from absent AGENTS' -Condition ($runtimeLsTree.Output -match '\[scope\] WARNING: .*build-output declarations unavailable \(.*exit 42.*\); declared class disabled') -Detail $runtimeLsTree.Output

    # Runtime (13) committed-AGENTS failures disable only the declared class. Keep runtime and
    # derived exclusions active, and keep the original runtime-13 leaf expectation above.
    $buildOutputsText = @'
## Build outputs
```text
src/*/bin
src/*/obj
tests/*/bin
tests/*/obj
```
Generated output directories only.
'@
    foreach ($fetchCommand in @('ls-tree', 'show')) {
        $fetchTask = 'runtime-13-agents-' + $fetchCommand
        $fetchRepo = New-BuildOutputRepo -Name $fetchTask -AgentsText $buildOutputsText -IgnoreText "bin/`nobj/`n.codex-scratch/`n"
        $fetchState = Join-Path $testRoot ('state-' + $fetchTask)
        $fetchFile = Join-Path $testRoot ('written-' + $fetchTask + '.txt')
        $fetchSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $fetchRepo, '-Task', $fetchTask, '-StateDirectory', $fetchState)
        Assert-True -Name ($fetchTask + ' snapshot succeeds') -Condition ($fetchSnapshot.ExitCode -eq 0) -Detail $fetchSnapshot.Output
        Write-FixtureFile -RepoPath $fetchRepo -Path 'projects/session-x.jsonl'
        Write-FixtureFile -RepoPath $fetchRepo -Path '.codex-scratch/log.txt'
        Write-FixtureFile -RepoPath $fetchRepo -Path 'src/App/bin/output.dll'
        Write-FixtureFile -RepoPath $fetchRepo -Path 'src/a.py' -Content "unauthorized source write`r`n"
        $fetchSnap = Get-Content -LiteralPath (Join-Path $fetchState ("scope-$fetchTask.snapshot.json")) -Raw | ConvertFrom-Json
        $fetchSnapPath = Join-Path $fetchState ("scope-$fetchTask.snapshot.json")
        $fetchSnapText = [System.IO.File]::ReadAllText($fetchSnapPath)
        $fetchShim = New-AgentsFetchFailureShim -Name ('shim-' + $fetchTask) -FailCommand $fetchCommand -Head $fetchSnap.head
        foreach ($collectFetch in @($true, $false)) {
            [System.IO.File]::WriteAllText($fetchSnapPath, $fetchSnapText, [System.Text.UTF8Encoding]::new($false))
            $fetchArguments = @('-Check', '-Worktree', $fetchRepo, '-Task', $fetchTask, '-StateDirectory', $fetchState, '-RuntimeExclusionRoot', $fetchRepo)
            if ($collectFetch) { $fetchArguments += @('-WrittenPathsFile', $fetchFile) }
            $fetchResult = Invoke-ScopeCheck -CheckerArguments $fetchArguments -PathOverride $fetchShim
            Assert-True -Name ("{0} disable-and-warn collecting={1}" -f $fetchTask, $collectFetch) -Condition ($fetchResult.ExitCode -eq 1 -and @([regex]::Matches($fetchResult.Output, '\[scope\] WARNING: .*build-output declarations unavailable \(.*exit 42.*\); declared class disabled')).Count -eq 1 -and $fetchResult.Output -notmatch 'runtime inventory could not be built') -Detail $fetchResult.Output
            Assert-True -Name ("{0} other classes continue collecting={1}" -f $fetchTask, $collectFetch) -Condition ($fetchResult.Output -match '1 runtime path\(s\) excluded' -and $fetchResult.Output -match '1 derived-cache path\(s\) excluded' -and $fetchResult.Output -match 'src/a.py' -and $fetchResult.Output -match 'src/App/bin') -Detail $fetchResult.Output
        }
        Assert-WrittenPaths -Name ($fetchTask + ' only declared output and source attributed') -Path $fetchFile -Expected @('src/a.py', 'src/App/bin', 'src/App/bin/output.dll')
    }

    # Runtime marker (1): rewrites inside a collapsed ignored directory do not move scope state.
    $runtimeMarkerRewriteRepo = New-RuntimeMarkerRepo -Name 'runtime-marker-rewrite'
    Write-RuntimeMarkerSeed -RepoPath $runtimeMarkerRewriteRepo
    [string[]]$runtimeMarkerRewriteStatus = @(& $gitPath -C $runtimeMarkerRewriteRepo status --porcelain --ignored=traditional)
    Assert-True -Name 'runtime marker 1 fixture is one collapsed ignored entry' -Condition ($runtimeMarkerRewriteStatus -contains '!! skills/synced/') -Detail ("status [{0}]" -f ($runtimeMarkerRewriteStatus -join ', '))
    $runtimeMarkerRewriteState = Join-Path $testRoot 'state-runtime-marker-rewrite'
    $runtimeMarkerRewriteFile = Join-Path $testRoot 'written-runtime-marker-rewrite.txt'
    $runtimeMarkerRewriteSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerRewriteRepo, '-Task', 'runtime-marker-rewrite', '-StateDirectory', $runtimeMarkerRewriteState, '-RuntimeExclusionRoot', $runtimeMarkerRewriteRepo)
    Assert-True -Name 'runtime marker 1 snapshot ordering succeeds' -Condition ($runtimeMarkerRewriteSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $runtimeMarkerRewriteSnapshot.ExitCode, $runtimeMarkerRewriteSnapshot.Output)
    Write-RuntimeMarkers -RepoPath $runtimeMarkerRewriteRepo -Content "marker rewritten with longer content`r`n"
    $runtimeMarkerRewrite = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerRewriteRepo, '-Task', 'runtime-marker-rewrite', '-StateDirectory', $runtimeMarkerRewriteState, '-RuntimeExclusionRoot', $runtimeMarkerRewriteRepo, '-WrittenPathsFile', $runtimeMarkerRewriteFile)
    Assert-True -Name 'runtime marker 1 rewrites exit clean' -Condition ($runtimeMarkerRewrite.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $runtimeMarkerRewrite.ExitCode, $runtimeMarkerRewrite.Output)
    Assert-WrittenPaths -Name 'runtime marker 1 rewrites emit no paths' -Path $runtimeMarkerRewriteFile -Expected @()

    # Runtime marker (2): a newly created marker-only tree is excluded and reported as excluded.
    $runtimeMarkerCreatedRepo = New-RuntimeMarkerRepo -Name 'runtime-marker-created'
    $runtimeMarkerCreatedState = Join-Path $testRoot 'state-runtime-marker-created'
    $runtimeMarkerCreatedFile = Join-Path $testRoot 'written-runtime-marker-created.txt'
    $runtimeMarkerCreatedSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerCreatedRepo, '-Task', 'runtime-marker-created', '-StateDirectory', $runtimeMarkerCreatedState, '-RuntimeExclusionRoot', $runtimeMarkerCreatedRepo)
    Assert-True -Name 'runtime marker 2 snapshot succeeds' -Condition ($runtimeMarkerCreatedSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeMarkerCreatedSnapshot.ExitCode)
    Write-RuntimeMarkers -RepoPath $runtimeMarkerCreatedRepo
    $runtimeMarkerCreated = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerCreatedRepo, '-Task', 'runtime-marker-created', '-StateDirectory', $runtimeMarkerCreatedState, '-RuntimeExclusionRoot', $runtimeMarkerCreatedRepo, '-WrittenPathsFile', $runtimeMarkerCreatedFile)
    Assert-True -Name 'runtime marker 2 creation exits clean' -Condition ($runtimeMarkerCreated.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $runtimeMarkerCreated.ExitCode, $runtimeMarkerCreated.Output)
    Assert-WrittenPaths -Name 'runtime marker 2 creation emits no paths' -Path $runtimeMarkerCreatedFile -Expected @()
    Assert-True -Name 'runtime marker 2 reports excluded paths' -Condition ($runtimeMarkerCreated.Output -match 'runtime path\(s\) excluded') -Detail $runtimeMarkerCreated.Output

    # Runtime marker (3): deleting a marker-only tree is excluded without a GONE verdict.
    $runtimeMarkerGoneRepo = New-RuntimeMarkerRepo -Name 'runtime-marker-gone'
    Write-RuntimeMarkers -RepoPath $runtimeMarkerGoneRepo
    $runtimeMarkerGoneState = Join-Path $testRoot 'state-runtime-marker-gone'
    $runtimeMarkerGoneFile = Join-Path $testRoot 'written-runtime-marker-gone.txt'
    $runtimeMarkerGoneSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerGoneRepo, '-Task', 'runtime-marker-gone', '-StateDirectory', $runtimeMarkerGoneState, '-RuntimeExclusionRoot', $runtimeMarkerGoneRepo)
    Assert-True -Name 'runtime marker 3 snapshot succeeds' -Condition ($runtimeMarkerGoneSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeMarkerGoneSnapshot.ExitCode)
    Remove-Item -LiteralPath (Join-Path $runtimeMarkerGoneRepo 'skills/synced') -Recurse -Force
    $runtimeMarkerGone = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerGoneRepo, '-Task', 'runtime-marker-gone', '-StateDirectory', $runtimeMarkerGoneState, '-RuntimeExclusionRoot', $runtimeMarkerGoneRepo, '-WrittenPathsFile', $runtimeMarkerGoneFile)
    Assert-True -Name 'runtime marker 3 deletion exits clean without GONE' -Condition ($runtimeMarkerGone.ExitCode -eq 0 -and $runtimeMarkerGone.Output -notmatch '(?m)^\s*GONE\s+skills/synced(?:/|$)') -Detail ("exit {0}: {1}" -f $runtimeMarkerGone.ExitCode, $runtimeMarkerGone.Output)
    Assert-WrittenPaths -Name 'runtime marker 3 deletion emits no paths' -Path $runtimeMarkerGoneFile -Expected @()

    # Runtime marker (4): a root SKILL.md remains attributable inside the collapsed directory.
    $runtimeMarkerRootSkillRepo = New-RuntimeMarkerRepo -Name 'runtime-marker-root-skill'
    Write-RuntimeMarkerSeed -RepoPath $runtimeMarkerRootSkillRepo
    $runtimeMarkerRootSkillState = Join-Path $testRoot 'state-runtime-marker-root-skill'
    $runtimeMarkerRootSkillFile = Join-Path $testRoot 'written-runtime-marker-root-skill.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerRootSkillRepo, '-Task', 'runtime-marker-root-skill', '-StateDirectory', $runtimeMarkerRootSkillState, '-RuntimeExclusionRoot', $runtimeMarkerRootSkillRepo))
    [System.IO.File]::WriteAllText((Join-Path $runtimeMarkerRootSkillRepo 'skills/synced/SKILL.md'), "new skill`r`n", [System.Text.Encoding]::ASCII)
    $runtimeMarkerRootSkill = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerRootSkillRepo, '-Task', 'runtime-marker-root-skill', '-StateDirectory', $runtimeMarkerRootSkillState, '-RuntimeExclusionRoot', $runtimeMarkerRootSkillRepo, '-WrittenPathsFile', $runtimeMarkerRootSkillFile)
    [string[]]$runtimeMarkerRootSkillWritten = if (Test-Path -LiteralPath $runtimeMarkerRootSkillFile -PathType Leaf) { [System.IO.File]::ReadAllLines($runtimeMarkerRootSkillFile) } else { @() }
    Assert-True -Name 'runtime marker 4 root skill is attributed' -Condition ($runtimeMarkerRootSkill.ExitCode -ne 0 -and $runtimeMarkerRootSkillWritten -contains 'skills/synced/SKILL.md') -Detail ("exit {0}, paths [{1}]" -f $runtimeMarkerRootSkill.ExitCode, ($runtimeMarkerRootSkillWritten -join ', '))

    # Runtime marker (5): a nested SKILL.md remains attributable.
    $runtimeMarkerNestedSkillRepo = New-RuntimeMarkerRepo -Name 'runtime-marker-nested-skill'
    Write-RuntimeMarkerSeed -RepoPath $runtimeMarkerNestedSkillRepo
    $runtimeMarkerNestedSkillState = Join-Path $testRoot 'state-runtime-marker-nested-skill'
    $runtimeMarkerNestedSkillFile = Join-Path $testRoot 'written-runtime-marker-nested-skill.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerNestedSkillRepo, '-Task', 'runtime-marker-nested-skill', '-StateDirectory', $runtimeMarkerNestedSkillState, '-RuntimeExclusionRoot', $runtimeMarkerNestedSkillRepo))
    $runtimeMarkerNestedSkillPath = Join-Path $runtimeMarkerNestedSkillRepo 'skills/synced/u1/x/SKILL.md'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runtimeMarkerNestedSkillPath) | Out-Null
    [System.IO.File]::WriteAllText($runtimeMarkerNestedSkillPath, "nested skill`r`n", [System.Text.Encoding]::ASCII)
    $runtimeMarkerNestedSkill = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerNestedSkillRepo, '-Task', 'runtime-marker-nested-skill', '-StateDirectory', $runtimeMarkerNestedSkillState, '-RuntimeExclusionRoot', $runtimeMarkerNestedSkillRepo, '-WrittenPathsFile', $runtimeMarkerNestedSkillFile)
    [string[]]$runtimeMarkerNestedSkillWritten = if (Test-Path -LiteralPath $runtimeMarkerNestedSkillFile -PathType Leaf) { [System.IO.File]::ReadAllLines($runtimeMarkerNestedSkillFile) } else { @() }
    Assert-True -Name 'runtime marker 5 nested skill is attributed' -Condition ($runtimeMarkerNestedSkill.ExitCode -ne 0 -and $runtimeMarkerNestedSkillWritten -contains 'skills/synced/u1/x/SKILL.md') -Detail ("exit {0}, paths [{1}]" -f $runtimeMarkerNestedSkill.ExitCode, ($runtimeMarkerNestedSkillWritten -join ', '))

    # Runtime marker (6): a nested script remains attributable.
    $runtimeMarkerScriptRepo = New-RuntimeMarkerRepo -Name 'runtime-marker-script'
    Write-RuntimeMarkerSeed -RepoPath $runtimeMarkerScriptRepo
    $runtimeMarkerScriptState = Join-Path $testRoot 'state-runtime-marker-script'
    $runtimeMarkerScriptFile = Join-Path $testRoot 'written-runtime-marker-script.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerScriptRepo, '-Task', 'runtime-marker-script', '-StateDirectory', $runtimeMarkerScriptState, '-RuntimeExclusionRoot', $runtimeMarkerScriptRepo))
    $runtimeMarkerScriptPath = Join-Path $runtimeMarkerScriptRepo 'skills/synced/u1/x/scripts/a.py'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runtimeMarkerScriptPath) | Out-Null
    [System.IO.File]::WriteAllText($runtimeMarkerScriptPath, "print('x')`r`n", [System.Text.Encoding]::ASCII)
    $runtimeMarkerScript = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerScriptRepo, '-Task', 'runtime-marker-script', '-StateDirectory', $runtimeMarkerScriptState, '-RuntimeExclusionRoot', $runtimeMarkerScriptRepo, '-WrittenPathsFile', $runtimeMarkerScriptFile)
    [string[]]$runtimeMarkerScriptWritten = if (Test-Path -LiteralPath $runtimeMarkerScriptFile -PathType Leaf) { [System.IO.File]::ReadAllLines($runtimeMarkerScriptFile) } else { @() }
    Assert-True -Name 'runtime marker 6 nested script is attributed' -Condition ($runtimeMarkerScript.ExitCode -ne 0 -and $runtimeMarkerScriptWritten -contains 'skills/synced/u1/x/scripts/a.py') -Detail ("exit {0}, paths [{1}]" -f $runtimeMarkerScript.ExitCode, ($runtimeMarkerScriptWritten -join ', '))

    # Runtime marker (7): deleting seeded non-marker content remains attributable.
    $runtimeMarkerDocsGoneRepo = New-RuntimeMarkerRepo -Name 'runtime-marker-docs-gone'
    Write-RuntimeMarkerSeed -RepoPath $runtimeMarkerDocsGoneRepo
    $runtimeMarkerDocsGoneState = Join-Path $testRoot 'state-runtime-marker-docs-gone'
    $runtimeMarkerDocsGoneFile = Join-Path $testRoot 'written-runtime-marker-docs-gone.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerDocsGoneRepo, '-Task', 'runtime-marker-docs-gone', '-StateDirectory', $runtimeMarkerDocsGoneState, '-RuntimeExclusionRoot', $runtimeMarkerDocsGoneRepo))
    Remove-Item -LiteralPath (Join-Path $runtimeMarkerDocsGoneRepo 'skills/synced/u1/docs') -Recurse -Force
    $runtimeMarkerDocsGone = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerDocsGoneRepo, '-Task', 'runtime-marker-docs-gone', '-StateDirectory', $runtimeMarkerDocsGoneState, '-RuntimeExclusionRoot', $runtimeMarkerDocsGoneRepo, '-WrittenPathsFile', $runtimeMarkerDocsGoneFile)
    [string[]]$runtimeMarkerDocsGoneWritten = if (Test-Path -LiteralPath $runtimeMarkerDocsGoneFile -PathType Leaf) { [System.IO.File]::ReadAllLines($runtimeMarkerDocsGoneFile) } else { @() }
    Assert-True -Name 'runtime marker 7 deleted docs are attributed' -Condition ($runtimeMarkerDocsGone.ExitCode -ne 0 -and $runtimeMarkerDocsGoneWritten -contains 'skills/synced') -Detail ("exit {0}, paths [{1}]" -f $runtimeMarkerDocsGone.ExitCode, ($runtimeMarkerDocsGoneWritten -join ', '))

    # Runtime marker (8): marker names outside skills/synced are not excluded.
    $runtimeMarkerSiblingRepo = New-RuntimeMarkerRepo -Name 'runtime-marker-sibling'
    $runtimeMarkerSiblingState = Join-Path $testRoot 'state-runtime-marker-sibling'
    $runtimeMarkerSiblingFile = Join-Path $testRoot 'written-runtime-marker-sibling.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerSiblingRepo, '-Task', 'runtime-marker-sibling', '-StateDirectory', $runtimeMarkerSiblingState, '-RuntimeExclusionRoot', $runtimeMarkerSiblingRepo))
    $runtimeMarkerSiblingPath = Join-Path $runtimeMarkerSiblingRepo 'skills/synced-foo/u1/manifest.json'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runtimeMarkerSiblingPath) | Out-Null
    [System.IO.File]::WriteAllText($runtimeMarkerSiblingPath, "marker`r`n", [System.Text.Encoding]::ASCII)
    $runtimeMarkerSibling = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerSiblingRepo, '-Task', 'runtime-marker-sibling', '-StateDirectory', $runtimeMarkerSiblingState, '-RuntimeExclusionRoot', $runtimeMarkerSiblingRepo, '-WrittenPathsFile', $runtimeMarkerSiblingFile)
    [string[]]$runtimeMarkerSiblingWritten = if (Test-Path -LiteralPath $runtimeMarkerSiblingFile -PathType Leaf) { [System.IO.File]::ReadAllLines($runtimeMarkerSiblingFile) } else { @() }
    Assert-True -Name 'runtime marker 8 sibling path is attributed' -Condition ($runtimeMarkerSibling.ExitCode -ne 0 -and $runtimeMarkerSiblingWritten -contains 'skills/synced-foo/u1/manifest.json') -Detail ("exit {0}, paths [{1}]" -f $runtimeMarkerSibling.ExitCode, ($runtimeMarkerSiblingWritten -join ', '))

    # Runtime marker (9): marker rewrites are attributable away from the configured runtime root.
    $runtimeMarkerWrongRootRepo = New-RuntimeMarkerRepo -Name 'runtime-marker-wrong-root'
    Write-RuntimeMarkerSeed -RepoPath $runtimeMarkerWrongRootRepo
    $runtimeMarkerWrongRootState = Join-Path $testRoot 'state-runtime-marker-wrong-root'
    $runtimeMarkerWrongRootSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerWrongRootRepo, '-Task', 'runtime-marker-wrong-root', '-StateDirectory', $runtimeMarkerWrongRootState)
    Assert-True -Name 'runtime marker 9 snapshot succeeds' -Condition ($runtimeMarkerWrongRootSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeMarkerWrongRootSnapshot.ExitCode)
    Write-RuntimeMarkers -RepoPath $runtimeMarkerWrongRootRepo -Content "marker rewritten with longer content`r`n"
    $runtimeMarkerWrongRoot = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerWrongRootRepo, '-Task', 'runtime-marker-wrong-root', '-StateDirectory', $runtimeMarkerWrongRootState)
    Assert-True -Name 'runtime marker 9 rewrites outside root exit non-zero' -Condition ($runtimeMarkerWrongRoot.ExitCode -ne 0) -Detail ("expected non-zero, got {0}: {1}" -f $runtimeMarkerWrongRoot.ExitCode, $runtimeMarkerWrongRoot.Output)

    # Runtime marker (10): an index/HEAD-tracked manifest remains attributable.
    $runtimeMarkerTrackedRepo = New-TestRepo -Name 'runtime-marker-tracked' -Files @('src/a.py', 'skills/apex/SKILL.md', 'skills/synced/u1/manifest.json')
    $runtimeMarkerTrackedState = Join-Path $testRoot 'state-runtime-marker-tracked'
    $runtimeMarkerTrackedFile = Join-Path $testRoot 'written-runtime-marker-tracked.txt'
    $runtimeMarkerTrackedSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerTrackedRepo, '-Task', 'runtime-marker-tracked', '-StateDirectory', $runtimeMarkerTrackedState, '-RuntimeExclusionRoot', $runtimeMarkerTrackedRepo)
    Assert-True -Name 'runtime marker 10 snapshot succeeds' -Condition ($runtimeMarkerTrackedSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeMarkerTrackedSnapshot.ExitCode)
    Add-Content -LiteralPath (Join-Path $runtimeMarkerTrackedRepo 'skills/synced/u1/manifest.json') -Value 'tracked change' -Encoding ASCII
    $runtimeMarkerTracked = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerTrackedRepo, '-Task', 'runtime-marker-tracked', '-StateDirectory', $runtimeMarkerTrackedState, '-RuntimeExclusionRoot', $runtimeMarkerTrackedRepo, '-WrittenPathsFile', $runtimeMarkerTrackedFile)
    Assert-True -Name 'runtime marker 10 tracked manifest exits non-zero' -Condition ($runtimeMarkerTracked.ExitCode -ne 0) -Detail ("expected non-zero, got {0}" -f $runtimeMarkerTracked.ExitCode)
    Assert-WrittenPaths -Name 'runtime marker 10 tracked manifest is attributed' -Path $runtimeMarkerTrackedFile -Expected @('skills/synced/u1/manifest.json')

    # Runtime marker (11): untracked marker leaves are excluded beside a tracked synced skill.
    $runtimeMarkerLeavesRepo = New-TestRepo -Name 'runtime-marker-leaves' -Files @('src/a.py', 'skills/synced/u1/docs/SKILL.md')
    $runtimeMarkerLeavesState = Join-Path $testRoot 'state-runtime-marker-leaves'
    $runtimeMarkerLeavesFile = Join-Path $testRoot 'written-runtime-marker-leaves.txt'
    $runtimeMarkerLeavesSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerLeavesRepo, '-Task', 'runtime-marker-leaves', '-StateDirectory', $runtimeMarkerLeavesState, '-RuntimeExclusionRoot', $runtimeMarkerLeavesRepo)
    Assert-True -Name 'runtime marker 11 snapshot succeeds' -Condition ($runtimeMarkerLeavesSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeMarkerLeavesSnapshot.ExitCode)
    Write-RuntimeMarkers -RepoPath $runtimeMarkerLeavesRepo
    $runtimeMarkerLeaves = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerLeavesRepo, '-Task', 'runtime-marker-leaves', '-StateDirectory', $runtimeMarkerLeavesState, '-RuntimeExclusionRoot', $runtimeMarkerLeavesRepo, '-WrittenPathsFile', $runtimeMarkerLeavesFile)
    Assert-True -Name 'runtime marker 11 untracked leaves exit clean' -Condition ($runtimeMarkerLeaves.ExitCode -eq 0) -Detail ("expected 0, got {0}: {1}" -f $runtimeMarkerLeaves.ExitCode, $runtimeMarkerLeaves.Output)
    Assert-WrittenPaths -Name 'runtime marker 11 untracked leaves emit no paths' -Path $runtimeMarkerLeavesFile -Expected @()

    # Runtime marker (12): the non-collecting branch also reports a clean marker rewrite.
    $runtimeMarkerNoWrittenRepo = New-RuntimeMarkerRepo -Name 'runtime-marker-no-written'
    Write-RuntimeMarkerSeed -RepoPath $runtimeMarkerNoWrittenRepo
    $runtimeMarkerNoWrittenState = Join-Path $testRoot 'state-runtime-marker-no-written'
    $runtimeMarkerNoWrittenSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerNoWrittenRepo, '-Task', 'runtime-marker-no-written', '-StateDirectory', $runtimeMarkerNoWrittenState, '-RuntimeExclusionRoot', $runtimeMarkerNoWrittenRepo)
    Assert-True -Name 'runtime marker 12 snapshot succeeds' -Condition ($runtimeMarkerNoWrittenSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeMarkerNoWrittenSnapshot.ExitCode)
    Write-RuntimeMarkers -RepoPath $runtimeMarkerNoWrittenRepo -Content "marker rewritten with longer content`r`n"
    $runtimeMarkerNoWritten = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerNoWrittenRepo, '-Task', 'runtime-marker-no-written', '-StateDirectory', $runtimeMarkerNoWrittenState, '-RuntimeExclusionRoot', $runtimeMarkerNoWrittenRepo)
    Assert-True -Name 'runtime marker 12 non-collecting branch exits clean' -Condition ($runtimeMarkerNoWritten.ExitCode -eq 0 -and $runtimeMarkerNoWritten.Output -match '(?m)^\[scope\].* clean -') -Detail ("exit {0}: {1}" -f $runtimeMarkerNoWritten.ExitCode, $runtimeMarkerNoWritten.Output)

    # Runtime marker (13): scope-check and tree-pin exclusions and marker helpers stay in lockstep.
    $runtimeMarkerTreePinPath = Join-Path $PSScriptRoot 'tree-pin.ps1'
    foreach ($runtimeMarkerListName in @('runtimeExclusions')) {
        [string[]]$runtimeMarkerCheckerList = @(Get-PsArrayLiteral -Path $checkerPath -Name $runtimeMarkerListName)
        [string[]]$runtimeMarkerTreePinList = @(Get-PsArrayLiteral -Path $runtimeMarkerTreePinPath -Name $runtimeMarkerListName)
        Assert-True -Name ("runtime marker 13 checker {0} parses non-empty" -f $runtimeMarkerListName) -Condition ($runtimeMarkerCheckerList.Count -gt 0) -Detail ("entries [{0}]" -f ($runtimeMarkerCheckerList -join ', '))
        Assert-True -Name ("runtime marker 13 tree-pin {0} parses non-empty" -f $runtimeMarkerListName) -Condition ($runtimeMarkerTreePinList.Count -gt 0) -Detail ("entries [{0}]" -f ($runtimeMarkerTreePinList -join ', '))
        Assert-True -Name ("runtime marker 13 {0} counts match" -f $runtimeMarkerListName) -Condition ($runtimeMarkerCheckerList.Count -eq $runtimeMarkerTreePinList.Count) -Detail ("checker {0}, tree-pin {1}" -f $runtimeMarkerCheckerList.Count, $runtimeMarkerTreePinList.Count)
        $runtimeMarkerListsEqual = $runtimeMarkerCheckerList.Count -eq $runtimeMarkerTreePinList.Count
        if ($runtimeMarkerListsEqual) {
            for ($runtimeMarkerListIndex = 0; $runtimeMarkerListIndex -lt $runtimeMarkerCheckerList.Count; $runtimeMarkerListIndex++) {
                if ($runtimeMarkerCheckerList[$runtimeMarkerListIndex] -cne $runtimeMarkerTreePinList[$runtimeMarkerListIndex]) {
                    $runtimeMarkerListsEqual = $false
                    break
                }
            }
        }
        Assert-True -Name ("runtime marker 13 {0} order matches" -f $runtimeMarkerListName) -Condition $runtimeMarkerListsEqual -Detail ("checker [{0}], tree-pin [{1}]" -f ($runtimeMarkerCheckerList -join ', '), ($runtimeMarkerTreePinList -join ', '))
    }

    $markerDefinitions = @(foreach ($markerScript in @($checkerPath, $runtimeMarkerTreePinPath)) {
        $markerAst = [Management.Automation.Language.Parser]::ParseFile($markerScript, [ref]$tokens, [ref]$parseErrors)
        $definition = $markerAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-IsRuntimeMarker' }, $true)
        $definition.Extent.Text -replace '\r\n', "`n"
    })
    Assert-True -Name 'runtime marker 13 ordinal helper definitions match' -Condition ($markerDefinitions[0] -ceq $markerDefinitions[1]) -Detail 'both scripts use the same ordinal marker membership logic'

    # Runtime marker (14): a directory named like a bucket marker is never leaf-excluded.
    $runtimeMarkerBucketDirectoryRepo = New-RuntimeMarkerRepo -Name 'runtime-marker-bucket-directory' -Files @('src/a.py', 'skills/apex/SKILL.md', 'skills/synced/u1/docs/SKILL.md')
    $runtimeMarkerBucketDirectoryState = Join-Path $testRoot 'state-runtime-marker-bucket-directory'
    $runtimeMarkerBucketDirectoryFile = Join-Path $testRoot 'written-runtime-marker-bucket-directory.txt'
    $runtimeMarkerBucketDirectorySnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerBucketDirectoryRepo, '-Task', 'runtime-marker-bucket-directory', '-StateDirectory', $runtimeMarkerBucketDirectoryState, '-RuntimeExclusionRoot', $runtimeMarkerBucketDirectoryRepo)
    Assert-True -Name 'runtime marker 14 snapshot succeeds' -Condition ($runtimeMarkerBucketDirectorySnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeMarkerBucketDirectorySnapshot.ExitCode)
    $runtimeMarkerBucketDirectoryPath = Join-Path $runtimeMarkerBucketDirectoryRepo 'skills/synced/.bucket-u1/SKILL.md'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runtimeMarkerBucketDirectoryPath) | Out-Null
    [System.IO.File]::WriteAllText($runtimeMarkerBucketDirectoryPath, "not a marker`r`n", [System.Text.Encoding]::ASCII)
    $runtimeMarkerBucketDirectory = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerBucketDirectoryRepo, '-Task', 'runtime-marker-bucket-directory', '-StateDirectory', $runtimeMarkerBucketDirectoryState, '-RuntimeExclusionRoot', $runtimeMarkerBucketDirectoryRepo, '-WrittenPathsFile', $runtimeMarkerBucketDirectoryFile)
    [string[]]$runtimeMarkerBucketDirectoryWritten = if (Test-Path -LiteralPath $runtimeMarkerBucketDirectoryFile -PathType Leaf) { [System.IO.File]::ReadAllLines($runtimeMarkerBucketDirectoryFile) } else { @() }
    $runtimeMarkerBucketDirectoryHasPath = @($runtimeMarkerBucketDirectoryWritten | Where-Object { $_.StartsWith('skills/synced/.bucket-u1', [System.StringComparison]::Ordinal) }).Count -gt 0
    Assert-True -Name 'runtime marker 14 bucket directory is attributed' -Condition ($runtimeMarkerBucketDirectory.ExitCode -ne 0 -and $runtimeMarkerBucketDirectoryHasPath) -Detail ("exit {0}, paths [{1}]" -f $runtimeMarkerBucketDirectory.ExitCode, ($runtimeMarkerBucketDirectoryWritten -join ', '))

    # Runtime marker (15): a directory named manifest.json is never leaf-excluded.
    $runtimeMarkerManifestDirectoryRepo = New-RuntimeMarkerRepo -Name 'runtime-marker-manifest-directory' -Files @('src/a.py', 'skills/apex/SKILL.md', 'skills/synced/u1/docs/SKILL.md')
    $runtimeMarkerManifestDirectoryState = Join-Path $testRoot 'state-runtime-marker-manifest-directory'
    $runtimeMarkerManifestDirectoryFile = Join-Path $testRoot 'written-runtime-marker-manifest-directory.txt'
    $runtimeMarkerManifestDirectorySnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerManifestDirectoryRepo, '-Task', 'runtime-marker-manifest-directory', '-StateDirectory', $runtimeMarkerManifestDirectoryState, '-RuntimeExclusionRoot', $runtimeMarkerManifestDirectoryRepo)
    Assert-True -Name 'runtime marker 15 snapshot succeeds' -Condition ($runtimeMarkerManifestDirectorySnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeMarkerManifestDirectorySnapshot.ExitCode)
    $runtimeMarkerManifestDirectoryPath = Join-Path $runtimeMarkerManifestDirectoryRepo 'skills/synced/u1/manifest.json/run.ps1'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $runtimeMarkerManifestDirectoryPath) | Out-Null
    [System.IO.File]::WriteAllText($runtimeMarkerManifestDirectoryPath, "Write-Output 'run'`r`n", [System.Text.Encoding]::ASCII)
    $runtimeMarkerManifestDirectory = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerManifestDirectoryRepo, '-Task', 'runtime-marker-manifest-directory', '-StateDirectory', $runtimeMarkerManifestDirectoryState, '-RuntimeExclusionRoot', $runtimeMarkerManifestDirectoryRepo, '-WrittenPathsFile', $runtimeMarkerManifestDirectoryFile)
    [string[]]$runtimeMarkerManifestDirectoryWritten = if (Test-Path -LiteralPath $runtimeMarkerManifestDirectoryFile -PathType Leaf) { [System.IO.File]::ReadAllLines($runtimeMarkerManifestDirectoryFile) } else { @() }
    $runtimeMarkerManifestDirectoryHasPath = @($runtimeMarkerManifestDirectoryWritten | Where-Object { $_.StartsWith('skills/synced/u1/manifest.json', [System.StringComparison]::Ordinal) }).Count -gt 0
    Assert-True -Name 'runtime marker 15 manifest directory is attributed' -Condition ($runtimeMarkerManifestDirectory.ExitCode -ne 0 -and $runtimeMarkerManifestDirectoryHasPath) -Detail ("exit {0}, paths [{1}]" -f $runtimeMarkerManifestDirectory.ExitCode, ($runtimeMarkerManifestDirectoryWritten -join ', '))

    # Runtime marker (16): removing an individually listed marker leaf is excluded without GONE.
    $runtimeMarkerLeafGoneRepo = New-RuntimeMarkerRepo -Name 'runtime-marker-leaf-gone' -Files @('src/a.py', 'skills/apex/SKILL.md', 'skills/synced/u1/docs/SKILL.md')
    Write-RuntimeMarkers -RepoPath $runtimeMarkerLeafGoneRepo
    [System.IO.File]::WriteAllText((Join-Path $runtimeMarkerLeafGoneRepo 'skills/synced/u1/notes.md'), "notes`r`n", [System.Text.Encoding]::ASCII)
    [string[]]$runtimeMarkerLeafGoneStatus = @(& $gitPath -C $runtimeMarkerLeafGoneRepo status --porcelain --ignored=traditional)
    Assert-True -Name 'runtime marker 16 manifest is an individual ignored entry' -Condition ($runtimeMarkerLeafGoneStatus -contains '!! skills/synced/u1/manifest.json') -Detail ("status [{0}]" -f ($runtimeMarkerLeafGoneStatus -join ', '))
    $runtimeMarkerLeafGoneState = Join-Path $testRoot 'state-runtime-marker-leaf-gone'
    $runtimeMarkerLeafGoneFile = Join-Path $testRoot 'written-runtime-marker-leaf-gone.txt'
    $runtimeMarkerLeafGoneSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerLeafGoneRepo, '-Task', 'runtime-marker-leaf-gone', '-StateDirectory', $runtimeMarkerLeafGoneState, '-RuntimeExclusionRoot', $runtimeMarkerLeafGoneRepo)
    Assert-True -Name 'runtime marker 16 snapshot succeeds' -Condition ($runtimeMarkerLeafGoneSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeMarkerLeafGoneSnapshot.ExitCode)
    Remove-Item -LiteralPath (Join-Path $runtimeMarkerLeafGoneRepo 'skills/synced/u1/manifest.json') -Force
    $runtimeMarkerLeafGone = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerLeafGoneRepo, '-Task', 'runtime-marker-leaf-gone', '-StateDirectory', $runtimeMarkerLeafGoneState, '-RuntimeExclusionRoot', $runtimeMarkerLeafGoneRepo, '-WrittenPathsFile', $runtimeMarkerLeafGoneFile)
    Assert-True -Name 'runtime marker 16 removed marker exits clean without GONE' -Condition ($runtimeMarkerLeafGone.ExitCode -eq 0 -and $runtimeMarkerLeafGone.Output -notmatch '(?m)^\s*GONE\s+skills/synced/u1/manifest\.json') -Detail ("exit {0}: {1}" -f $runtimeMarkerLeafGone.ExitCode, $runtimeMarkerLeafGone.Output)
    Assert-WrittenPaths -Name 'runtime marker 16 removed marker emits no paths' -Path $runtimeMarkerLeafGoneFile -Expected @()

    # Runtime marker (17): removing an individually listed non-marker leaf remains attributable.
    $runtimeMarkerNoteGoneRepo = New-RuntimeMarkerRepo -Name 'runtime-marker-note-gone' -Files @('src/a.py', 'skills/apex/SKILL.md', 'skills/synced/u1/docs/SKILL.md')
    Write-RuntimeMarkers -RepoPath $runtimeMarkerNoteGoneRepo
    [System.IO.File]::WriteAllText((Join-Path $runtimeMarkerNoteGoneRepo 'skills/synced/u1/notes.md'), "notes`r`n", [System.Text.Encoding]::ASCII)
    $runtimeMarkerNoteGoneState = Join-Path $testRoot 'state-runtime-marker-note-gone'
    $runtimeMarkerNoteGoneFile = Join-Path $testRoot 'written-runtime-marker-note-gone.txt'
    $runtimeMarkerNoteGoneSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $runtimeMarkerNoteGoneRepo, '-Task', 'runtime-marker-note-gone', '-StateDirectory', $runtimeMarkerNoteGoneState, '-RuntimeExclusionRoot', $runtimeMarkerNoteGoneRepo)
    Assert-True -Name 'runtime marker 17 snapshot succeeds' -Condition ($runtimeMarkerNoteGoneSnapshot.ExitCode -eq 0) -Detail ("expected 0, got {0}" -f $runtimeMarkerNoteGoneSnapshot.ExitCode)
    Remove-Item -LiteralPath (Join-Path $runtimeMarkerNoteGoneRepo 'skills/synced/u1/notes.md') -Force
    $runtimeMarkerNoteGone = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $runtimeMarkerNoteGoneRepo, '-Task', 'runtime-marker-note-gone', '-StateDirectory', $runtimeMarkerNoteGoneState, '-RuntimeExclusionRoot', $runtimeMarkerNoteGoneRepo, '-WrittenPathsFile', $runtimeMarkerNoteGoneFile)
    [string[]]$runtimeMarkerNoteGoneWritten = if (Test-Path -LiteralPath $runtimeMarkerNoteGoneFile -PathType Leaf) { [System.IO.File]::ReadAllLines($runtimeMarkerNoteGoneFile) } else { @() }
    Assert-True -Name 'runtime marker 17 removed note is attributed with GONE' -Condition ($runtimeMarkerNoteGone.ExitCode -ne 0 -and $runtimeMarkerNoteGone.Output -match '(?m)^\s*GONE\s+skills/synced/u1/notes\.md' -and $runtimeMarkerNoteGoneWritten -contains 'skills/synced/u1/notes.md') -Detail ("exit {0}, paths [{1}]: {2}" -f $runtimeMarkerNoteGone.ExitCode, ($runtimeMarkerNoteGoneWritten -join ', '), $runtimeMarkerNoteGone.Output)

    # An open writer that permits readers must not prevent hashing an untracked leaf.
    $writerRepo = New-TestRepo -Name 'snapshot-open-writer'
    Write-FixtureFile -RepoPath $writerRepo -Path 'open.txt' -Content 'writer-held bytes'
    $writerState = Join-Path $testRoot 'state-open-writer'
    $writer = New-Object IO.FileStream((Join-Path $writerRepo 'open.txt'), 'Open', 'Write', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $writerSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $writerRepo, '-Task', 'open-writer', '-StateDirectory', $writerState)
        Assert-True -Name 'snapshot hashes untracked leaf while writer is open' -Condition ($writerSnapshot.ExitCode -eq 0) -Detail $writerSnapshot.Output
        if ($writerSnapshot.ExitCode -eq 0) {
            $writerSnap = Get-Content -LiteralPath (Join-Path $writerState 'scope-open-writer.snapshot.json') -Raw | ConvertFrom-Json
            $writerSha = [System.Security.Cryptography.SHA256]::Create()
            try { $writerHash = [BitConverter]::ToString($writerSha.ComputeHash([Text.Encoding]::UTF8.GetBytes('writer-held bytes'))).Replace('-', '').ToLowerInvariant() }
            finally { $writerSha.Dispose() }
            Assert-True -Name 'open writer snapshot retains exact raw hash' -Condition ($writerSnap.states.'open.txt' -ceq "work:raw:$writerHash index:-") -Detail $writerSnap.states.'open.txt'
        }
    } finally { $writer.Dispose() }

    # Root declarations apply from a subdirectory, even with conflicting nested instructions.
    $subdirRepo = New-BuildOutputRepo -Name 'build-subdirectory-agents' -AgentsText "## Build outputs`n```````nchild/bin`nchild/deeper/bin`n```````n" -Files @('child/Program.cs', 'child/deeper/Program.cs')
    Write-FixtureFile -RepoPath $subdirRepo -Path 'child/AGENTS.md' -Content "## Build outputs`n```````nobj`n```````n"
    Invoke-TestGit -RepoPath $subdirRepo -GitArguments @('add', '--', 'child/AGENTS.md')
    Invoke-TestGit -RepoPath $subdirRepo -GitArguments @('commit', '-q', '-m', 'conflicting nested declarations')
    foreach ($subdir in @('child', 'child/deeper')) {
        $subdirWorktree = Join-Path $subdirRepo $subdir
        $subdirTask = 'subdir-' + $subdir.Replace('/', '-')
        $subdirState = Join-Path $testRoot ('state-' + $subdirTask)
        $subdirWritten = Join-Path $testRoot ($subdirTask + '.txt')
        $subdirSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $subdirWorktree, '-Task', $subdirTask, '-StateDirectory', $subdirState)
        Assert-True -Name ($subdirTask + ' snapshot succeeds') -Condition ($subdirSnapshot.ExitCode -eq 0) -Detail $subdirSnapshot.Output
        Write-FixtureFile -RepoPath $subdirWorktree -Path 'bin/output.dll'
        Write-FixtureFile -RepoPath $subdirWorktree -Path 'obj/cache'
        $subdirResult = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $subdirWorktree, '-Task', $subdirTask, '-StateDirectory', $subdirState, '-WrittenPathsFile', $subdirWritten)
        Assert-True -Name ($subdirTask + ' uses root declarations') -Condition ($subdirResult.ExitCode -eq 1 -and $subdirResult.Output -match '\[scope\] 1 declared build-output path\(s\) excluded') -Detail $subdirResult.Output
        Assert-WrittenPaths -Name ($subdirTask + ' nested declaration is not used') -Path $subdirWritten -Expected @($subdir + '/obj')
        Remove-Item -LiteralPath (Join-Path $subdirWorktree 'bin'), (Join-Path $subdirWorktree 'obj') -Recurse -Force
    }

    # Grammar pointers stay below the filled recipe and outside the Build outputs fence.
    $templatePath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'apex-orchestrate/templates/AGENTS-template.md'
    $templateText = [IO.File]::ReadAllText($templatePath)
    $filledTemplateText = [regex]::Replace($templateText, '(?s)<!-- apex:agents:verify -->.*?If the stack is TBD at init, leave this marker as the stub\.}', "```````necho ok>marker.txt`n``````")
    $templateChecker = Join-Path $PSScriptRoot 'apex-baseline-check.ps1'
    foreach ($templateCase in @(
            @{ Name = 'unfilled'; Text = $templateText; Exit = 3 },
            @{ Name = 'filled'; Text = $filledTemplateText; Exit = 0 })) {
        $templateRepo = New-TestRepo -Name ('grammar-template-' + $templateCase.Name)
        Write-FixtureFile -RepoPath $templateRepo -Path 'AGENTS.md' -Content $templateCase.Text
        $templatePreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $templateOutput = @(& $powerShellPath -NoProfile -File $templateChecker -Full -Worktree $templateRepo 2>&1)
            $templateExit = $LASTEXITCODE
        } finally { $ErrorActionPreference = $templatePreference }
        Assert-True -Name ($templateCase.Name + ' real template recipe exit') -Condition ($templateExit -eq $templateCase.Exit) -Detail ($templateOutput -join [Environment]::NewLine)
        Assert-True -Name ($templateCase.Name + ' real template marker') -Condition ((Test-Path -LiteralPath (Join-Path $templateRepo 'marker.txt')) -eq ($templateCase.Exit -eq 0)) -Detail 'only filled template executes its command'
    }

    # Task 3 A: authorizing four new-directory leaves never attributes their parent containers.
    $leafRepo = New-TestRepo -Name 'build-A-leaves'
    $leafState = Join-Path $testRoot 'state-build-A-leaves'
    $leafFile = Join-Path $testRoot 'written-build-A-leaves.txt'
    $leafSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $leafRepo, '-Task', 'build-A-leaves', '-StateDirectory', $leafState)
    Assert-True -Name 'A leaf snapshot succeeds' -Condition ($leafSnapshot.ExitCode -eq 0) -Detail $leafSnapshot.Output
    $leafPaths = @('src/App/Program.cs', 'tests/App/ProgramTests.cs', 'tools/new/run.ps1', 'data/new/sample.txt')
    foreach ($leafPath in $leafPaths) { Write-FixtureFile -RepoPath $leafRepo -Path $leafPath }
    $leafResult = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $leafRepo, '-Task', 'build-A-leaves', '-StateDirectory', $leafState, '-Authorized', ($leafPaths -join ','), '-WrittenPathsFile', $leafFile)
    Assert-True -Name 'A four authorized leaves exit 0' -Condition ($leafResult.ExitCode -eq 0) -Detail $leafResult.Output
    Assert-WrittenPaths -Name 'A exactly four written leaves' -Path $leafFile -Expected $leafPaths

    # A nested repository remains a ?? container with a recursive digest and no index subprocess.
    $nestedRepo = New-TestRepo -Name 'build-nested-container'
    $nestedChild = New-TestRepo -Name 'build-nested-container/vendor/child'
    $nestedState = Join-Path $testRoot 'state-build-nested-container'
    $nestedShim = New-FailingGitShim -Name 'shim-nested-no-ls-files' -FailCommand 'ls-files'
    $nestedSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $nestedRepo, '-Task', 'nested-container', '-StateDirectory', $nestedState) -PathOverride $nestedShim
    Assert-True -Name 'nested ?? container snapshot needs no ls-files' -Condition ($nestedSnapshot.ExitCode -eq 0) -Detail $nestedSnapshot.Output
    $nestedSnapPath = Join-Path $nestedState 'scope-nested-container.snapshot.json'
    $nestedSnap = Get-Content -LiteralPath $nestedSnapPath -Raw | ConvertFrom-Json
    $nestedRow = @($nestedSnap.dirty | Where-Object { $_ -ceq 'vendor/child/' })
    $nestedHash = [string]$nestedSnap.states.'vendor/child/'
    Assert-True -Name 'nested repository stays a ?? container with directory digest' -Condition ($nestedRow.Count -eq 1 -and $nestedSnap.statuses.'vendor/child/' -ceq '??' -and $nestedHash -match '^work:dir:[0-9a-f]{64} index:-$') -Detail $nestedHash
    Write-FixtureFile -RepoPath $nestedChild -Path 'src/a.py' -Content "internal changed file, different length`r`n"
    $nestedChangedSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $nestedRepo, '-Task', 'nested-container-after', '-StateDirectory', $nestedState) -PathOverride $nestedShim
    Assert-True -Name 'nested changed snapshot succeeds' -Condition ($nestedChangedSnapshot.ExitCode -eq 0) -Detail $nestedChangedSnapshot.Output
    $nestedAfter = Get-Content -LiteralPath (Join-Path $nestedState 'scope-nested-container-after.snapshot.json') -Raw | ConvertFrom-Json
    Assert-True -Name 'nested internal edit changes recursive digest' -Condition ($nestedAfter.states.'vendor/child/' -cne $nestedHash) -Detail $nestedAfter.states.'vendor/child/'
    $nestedResult = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $nestedRepo, '-Task', 'nested-container', '-StateDirectory', $nestedState)
    Assert-True -Name 'nested internal edit is reported' -Condition ($nestedResult.ExitCode -eq 1 -and $nestedResult.Output -match 'vendor/child') -Detail $nestedResult.Output

    # Task 3 B/B0/C/D/E/F/G1/G2/K/M: all exercise both lockstep classification branches.
    $singleBuildOutputText = "## Build outputs`n``````text`nsrc/*/bin`n```````n"
    $matrix = @(
        @{ Name = 'B'; Agents = $buildOutputsText; Paths = @('src/App/bin/output.dll', 'src/App/obj/cache', 'tests/App/bin/output.dll', 'tests/App/obj/cache'); Exit = 0; Excluded = 4; Written = @() },
        @{ Name = 'B0'; Agents = ''; Paths = @('src/App/bin/output.dll', 'src/App/obj/cache'); Exit = 1; Excluded = 0; Written = @('src/App/bin', 'src/App/bin/output.dll', 'src/App/obj', 'src/App/obj/cache') },
        @{ Name = 'C'; Agents = $buildOutputsText; Paths = @('src/App/bin/output.dll', 'src/App/Evil.cs'); Exit = 1; Excluded = 1; Written = @('src/App/Evil.cs') },
        @{ Name = 'D'; Agents = $buildOutputsText; Paths = @('src/App/bin/output.dll', 'src/App/.hooks/x'); Exit = 1; Excluded = 1; Written = @('src/App/.hooks', 'src/App/.hooks/x') },
        @{ Name = 'E'; Agents = $buildOutputsText; Paths = @('src/App/bin/run.sh'); Files = @('src/a.py', 'src/App/bin/run.sh'); Exit = 1; Excluded = 0; Written = @('src/App/bin/run.sh') },
        @{ Name = 'F'; Agents = $buildOutputsText; Paths = @('src/App/bin/output.dll'); Ignore = ''; Exit = 1; Excluded = 0; Written = @('src/App/bin/output.dll') },
        @{ Name = 'G1'; Agents = ''; MidRunAgents = $buildOutputsText; Paths = @('src/App/bin/output.dll'); Exit = 1; Excluded = 0; Written = @('AGENTS.md', 'src/App/bin', 'src/App/bin/output.dll') },
        @{ Name = 'G2'; Agents = "## Rules`nOriginal committed rules.`n"; MidRunAgents = $buildOutputsText; Paths = @('src/App/bin/output.dll'); Exit = 1; Excluded = 0; Written = @('AGENTS.md', 'src/App/bin', 'src/App/bin/output.dll') },
        @{ Name = 'K'; Agents = $singleBuildOutputText; Files = @('src/a.py', 'src/App/Program.cs', 'src/App/sub/Keep.cs'); Paths = @('src/bin/output.dll', 'src/App/sub/bin/output.dll'); Exit = 1; Excluded = 0; Written = @('src/bin', 'src/bin/output.dll', 'src/App/sub/bin', 'src/App/sub/bin/output.dll') },
        @{ Name = 'M'; Agents = "## Build outputs`n``````text`nsrc/*/bin`n../x`n```````n"; Paths = @('src/App/bin/output.dll'); Exit = 1; Excluded = 0; Warning = $true; Written = @('src/App/bin', 'src/App/bin/output.dll') }
    )
    $malformedEntries = @('**/bin', 'src/*', '../x', 'src/?/bin', '.git/hooks', 'src/*/bin/', '/bin', 'src\*\bin', 'C:/x', 'src//bin')
    for ($badIndex = 0; $badIndex -lt $malformedEntries.Count; $badIndex++) {
        $matrix += @{ Name = ('H-{0}' -f $badIndex); Agents = ("## Build outputs`n``````text`n{0}`n```````n" -f $malformedEntries[$badIndex]); Paths = @('src/App/bin/output.dll'); Exit = 1; Excluded = 0; Warning = $true; Written = @('src/App/bin', 'src/App/bin/output.dll') }
    }
    $matrix += @(
        @{ Name = 'H-prose'; Agents = "## Build outputs`nProse before fence.`n``````text`nsrc/*/bin`n```````n"; Paths = @('src/App/bin/output.dll'); Exit = 1; Excluded = 0; Warning = $true; Written = @('src/App/bin', 'src/App/bin/output.dll') },
        @{ Name = 'H-fenced-example'; Agents = "````````markdown`n## Build outputs`n``````text`nsrc/*/bin`n```````n`````````n"; Paths = @('src/App/bin/output.dll'); Exit = 1; Excluded = 0; Written = @('src/App/bin', 'src/App/bin/output.dll') },
        @{ Name = 'H-duplicate'; Agents = ($singleBuildOutputText + $singleBuildOutputText); Paths = @('src/App/bin/output.dll'); Exit = 1; Excluded = 0; Warning = $true; Written = @('src/App/bin', 'src/App/bin/output.dll') },
        @{ Name = 'H-empty'; Agents = "## Build outputs`n```````n```````nNotes below.`n"; Paths = @('src/App/bin/output.dll'); Exit = 1; Excluded = 0; Written = @('src/App/bin', 'src/App/bin/output.dll') },
        @{ Name = 'H-second-fence'; Agents = ($singleBuildOutputText + "``````text`nother/bin`n```````n"); Paths = @('src/App/bin/output.dll'); Exit = 1; Excluded = 0; Warning = $true; Written = @('src/App/bin', 'src/App/bin/output.dll') }
    )
    foreach ($fixture in $matrix) {
        $fixtureTask = 'build-' + $fixture.Name
        $fixtureOptions = @{ Name = $fixtureTask; AgentsText = $fixture.Agents }
        if ($fixture.ContainsKey('Files')) { $fixtureOptions.Files = $fixture.Files }
        if ($fixture.ContainsKey('Ignore')) { $fixtureOptions.IgnoreText = $fixture.Ignore }
        $fixtureRepo = New-BuildOutputRepo @fixtureOptions
        $fixtureState = Join-Path $testRoot ('state-' + $fixtureTask)
        $fixtureFile = Join-Path $testRoot ('written-' + $fixtureTask + '.txt')
        $fixtureSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $fixtureRepo, '-Task', $fixtureTask, '-StateDirectory', $fixtureState)
        Assert-True -Name ($fixtureTask + ' snapshot succeeds') -Condition ($fixtureSnapshot.ExitCode -eq 0) -Detail $fixtureSnapshot.Output
        $fixtureSnapPath = Join-Path $fixtureState ("scope-$fixtureTask.snapshot.json")
        $fixtureSnapText = [System.IO.File]::ReadAllText($fixtureSnapPath)
        foreach ($fixturePath in $fixture.Paths) { Write-FixtureFile -RepoPath $fixtureRepo -Path $fixturePath -Content "build changed content`r`n" }
        if ($fixture.ContainsKey('MidRunAgents')) { Write-FixtureFile -RepoPath $fixtureRepo -Path 'AGENTS.md' -Content $fixture.MidRunAgents }
        foreach ($collectFixture in @($true, $false)) {
            # Successful checks consume the snapshot; restore the same evidence for the twin branch.
            [System.IO.File]::WriteAllText($fixtureSnapPath, $fixtureSnapText, [System.Text.UTF8Encoding]::new($false))
            $fixtureArguments = @('-Check', '-Worktree', $fixtureRepo, '-Task', $fixtureTask, '-StateDirectory', $fixtureState)
            if ($collectFixture) { $fixtureArguments += @('-WrittenPathsFile', $fixtureFile) }
            if ($fixture.ContainsKey('MidRunAgents')) { $fixtureArguments += @('-Authorized', 'AGENTS.md') }
            $fixtureResult = Invoke-ScopeCheck -CheckerArguments $fixtureArguments
            $fixtureLabel = "{0} collecting={1}" -f $fixtureTask, $collectFixture
            Assert-True -Name ($fixtureLabel + ' exit') -Condition ($fixtureResult.ExitCode -eq $fixture.Exit) -Detail $fixtureResult.Output
            $warningCount = @([regex]::Matches($fixtureResult.Output, "\[scope\] WARNING: AGENTS.md '## Build outputs' unparseable \(line \d+: .*\); no build-output exclusions applied")).Count
            $expectedWarningCount = if ($fixture.ContainsKey('Warning')) { 1 } else { 0 }
            Assert-True -Name ($fixtureLabel + ' single fail-closed warning or no warning') -Condition ($warningCount -eq $expectedWarningCount) -Detail $fixtureResult.Output
            if ($fixture.Excluded -gt 0) {
                Assert-True -Name ($fixtureLabel + ' declared exclusion count') -Condition ($fixtureResult.Output.Contains(("{0} declared build-output path(s) excluded" -f $fixture.Excluded))) -Detail $fixtureResult.Output
            } else {
                Assert-True -Name ($fixtureLabel + ' no declared exclusions') -Condition ($fixtureResult.Output -notmatch 'declared build-output path\(s\) excluded') -Detail $fixtureResult.Output
            }
            foreach ($expectedPath in $fixture.Written) {
                if ($expectedPath -ceq 'AGENTS.md' -or $expectedPath.EndsWith('/output.dll') -or $expectedPath.EndsWith('/cache') -or $expectedPath.EndsWith('/x')) { continue }
                Assert-True -Name ($fixtureLabel + ' names ' + $expectedPath) -Condition ($fixtureResult.Output.Contains($expectedPath)) -Detail $fixtureResult.Output
            }
        }
        Assert-WrittenPaths -Name ($fixtureTask + ' written paths') -Path $fixtureFile -Expected $fixture.Written
    }

    # V: snapshots are format 2; absent and other formats throw before any written artifact.
    $versionRepo = New-TestRepo -Name 'build-V-format'
    Write-FixtureFile -RepoPath $versionRepo -Path 'scratch/leaf.txt'
    $versionState = Join-Path $testRoot 'state-build-V-format'
    $versionTask = 'build-V-format'
    $versionNoHashShim = New-FailingGitShim -Name 'shim-V-no-hash-object' -FailCommand 'hash-object'
    $versionSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $versionRepo, '-Task', $versionTask, '-StateDirectory', $versionState) -PathOverride $versionNoHashShim
    Assert-True -Name 'V snapshot succeeds' -Condition ($versionSnapshot.ExitCode -eq 0) -Detail $versionSnapshot.Output
    $versionPath = Join-Path $versionState 'scope-build-V-format.snapshot.json'
    $versionSnap = Get-Content -LiteralPath $versionPath -Raw | ConvertFrom-Json
    Assert-True -Name 'V snapshot format is 2 and leaf uses raw SHA-256' -Condition ($versionSnap.format -ceq 2 -and $versionSnap.states.'scratch/leaf.txt' -match '^work:raw:[0-9a-f]{64} index:-$') -Detail ([string]$versionSnap.format + ' ' + $versionSnap.states.'scratch/leaf.txt')
    $versionNoIndexShim = New-FailingGitShim -Name 'shim-V-no-ls-files' -FailCommand 'ls-files'
    $versionNoIndexSnapshot = Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $versionRepo, '-Task', 'build-V-no-index', '-StateDirectory', $versionState) -PathOverride $versionNoIndexShim
    Assert-True -Name 'V ?? leaf snapshot needs no ls-files' -Condition ($versionNoIndexSnapshot.ExitCode -eq 0) -Detail $versionNoIndexSnapshot.Output
    foreach ($oldVersion in @('absent', '1', '3', 'string', 'array', 'empty-array', 'null')) {
        $oldFormat = [ordered]@{ task = $versionSnap.task; head = $versionSnap.head; dirty = @($versionSnap.dirty); states = $versionSnap.states; statuses = $versionSnap.statuses; takenUtc = $versionSnap.takenUtc }
        switch -CaseSensitive ($oldVersion) {
            'absent' { }
            'string' { $oldFormat.format = '2' }
            'array' { $oldFormat.format = @(2) }
            'empty-array' { $oldFormat.format = @() }
            'null' { $oldFormat.format = $null }
            default { $oldFormat.format = [int]$oldVersion }
        }
        [System.IO.File]::WriteAllText($versionPath, ($oldFormat | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
        $versionFile = Join-Path $testRoot ("written-version-$oldVersion.txt")
        $versionResult = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $versionRepo, '-Task', $versionTask, '-StateDirectory', $versionState, '-WrittenPathsFile', $versionFile)
        $versionMessage = "snapshot for '$versionTask' predates scope snapshot format 2 (leaf enumeration); re-run -Snapshot"
        Assert-True -Name ("V {0} format throws named re-Snapshot message" -f $oldVersion) -Condition ($versionResult.ExitCode -ne 0 -and $versionResult.Output.Contains($versionMessage) -and -not (Test-Path -LiteralPath $versionFile)) -Detail $versionResult.Output
    }

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
    Assert-WrittenPaths -Name 'derived-cache 11 nonignored exact name is attributed' -Path $derivedQuestionFile -Expected @('.codex-scratch/log.txt')

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
    Assert-WrittenPaths -Name 'derived-cache 12 snapshot question-status deletion is attributed' -Path $derivedPreQuestionFile -Expected @('.codex-scratch/log.txt')

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

    # Derived-cache (14): format-2 snapshots stripped of statuses exercise the transition guard.
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
        format = 2
        task = $derivedOldSnapshot.task
        head = $derivedOldSnapshot.head
        dirty = @($derivedOldSnapshot.dirty)
        states = $derivedOldSnapshot.states
        takenUtc = $derivedOldSnapshot.takenUtc
    }
    $derivedOldFormat | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $derivedOldSnapshotPath -Encoding utf8
    [System.IO.File]::WriteAllText((Join-Path $derivedOldDirectory 'after.txt'), "after`r`n", [System.Text.Encoding]::ASCII)
    $derivedOld = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $derivedOldRepo, '-Task', 'derived-old-snapshot', '-StateDirectory', $derivedOldState, '-WrittenPathsFile', $derivedOldFile)
    Assert-True -Name 'derived-cache 14 format-2 snapshot without statuses exits non-zero' -Condition ($derivedOld.ExitCode -eq 1) -Detail ("expected 1, got {0}" -f $derivedOld.ExitCode)
    Assert-WrittenPaths -Name 'derived-cache 14 format-2 snapshot without statuses is attributed' -Path $derivedOldFile -Expected @('.codex-scratch', '.codex-scratch/after.txt', '.codex-scratch/before.txt')

    # Declared-class twin of (14): the same format-2/statuses-stripped evidence must not exclude.
    $declaredGuardRepo = New-BuildOutputRepo -Name 'declared-status-guard' -AgentsText $singleBuildOutputText
    Write-FixtureFile -RepoPath $declaredGuardRepo -Path 'src/App/bin/before.txt'
    $declaredGuardState = Join-Path $testRoot 'state-declared-status-guard'
    $declaredGuardFile = Join-Path $testRoot 'written-declared-status-guard.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $declaredGuardRepo, '-Task', 'declared-status-guard', '-StateDirectory', $declaredGuardState))
    $declaredGuardPath = Join-Path $declaredGuardState 'scope-declared-status-guard.snapshot.json'
    $declaredGuardSnap = Get-Content -LiteralPath $declaredGuardPath -Raw | ConvertFrom-Json
    $declaredGuardFormat = [ordered]@{ format = 2; task = $declaredGuardSnap.task; head = $declaredGuardSnap.head; dirty = @($declaredGuardSnap.dirty); states = $declaredGuardSnap.states; takenUtc = $declaredGuardSnap.takenUtc }
    [System.IO.File]::WriteAllText($declaredGuardPath, ($declaredGuardFormat | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
    $declaredGuardText = [System.IO.File]::ReadAllText($declaredGuardPath)
    Write-FixtureFile -RepoPath $declaredGuardRepo -Path 'src/App/bin/after.txt'
    foreach ($collectGuard in @($true, $false)) {
        [System.IO.File]::WriteAllText($declaredGuardPath, $declaredGuardText, [System.Text.UTF8Encoding]::new($false))
        $guardArguments = @('-Check', '-Worktree', $declaredGuardRepo, '-Task', 'declared-status-guard', '-StateDirectory', $declaredGuardState)
        if ($collectGuard) { $guardArguments += @('-WrittenPathsFile', $declaredGuardFile) }
        $declaredGuard = Invoke-ScopeCheck -CheckerArguments $guardArguments
        Assert-True -Name ("declared-class 14 format-2 statuses guard collecting={0}" -f $collectGuard) -Condition ($declaredGuard.ExitCode -eq 1 -and $declaredGuard.Output -notmatch 'declared build-output path\(s\) excluded') -Detail $declaredGuard.Output
    }
    Assert-WrittenPaths -Name 'declared-class 14 without statuses retains attribution' -Path $declaredGuardFile -Expected @('src/App/bin', 'src/App/bin/after.txt', 'src/App/bin/before.txt')

    # Inventory failure disables the declared class as well as the root-derived class.
    $declaredInventoryRepo = New-BuildOutputRepo -Name 'declared-inventory-guard' -AgentsText $singleBuildOutputText -IgnoreText "bin/`n.codex-scratch/`n"
    $declaredInventoryState = Join-Path $testRoot 'state-declared-inventory-guard'
    $declaredInventoryFile = Join-Path $testRoot 'written-declared-inventory-guard.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $declaredInventoryRepo, '-Task', 'declared-inventory-guard', '-StateDirectory', $declaredInventoryState))
    Write-FixtureFile -RepoPath $declaredInventoryRepo -Path 'src/App/bin/output.dll'
    Write-FixtureFile -RepoPath $declaredInventoryRepo -Path '.codex-scratch/log.txt'
    $declaredInventoryShim = New-FailingGitShim -Name 'shim-declared-inventory' -FailCommand 'ls-files'
    $declaredInventory = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $declaredInventoryRepo, '-Task', 'declared-inventory-guard', '-StateDirectory', $declaredInventoryState, '-WrittenPathsFile', $declaredInventoryFile) -PathOverride $declaredInventoryShim
    Assert-True -Name 'declared-class inventory failure disables both classes' -Condition ($declaredInventory.ExitCode -eq 1 -and $declaredInventory.Output -match 'runtime inventory could not be built' -and $declaredInventory.Output -notmatch '(?:declared build-output|derived-cache) path\(s\) excluded') -Detail $declaredInventory.Output
    Assert-WrittenPaths -Name 'declared-class inventory failure retains both attributions' -Path $declaredInventoryFile -Expected @('.codex-scratch', '.codex-scratch/log.txt', 'src/App/bin', 'src/App/bin/output.dll')

    # A still-ignored declared prefix and its deletion are excluded in both branches.
    $declaredGoneRepo = New-BuildOutputRepo -Name 'declared-gone-guard' -AgentsText $singleBuildOutputText
    Write-FixtureFile -RepoPath $declaredGoneRepo -Path 'src/App/bin/before.txt'
    $declaredGoneState = Join-Path $testRoot 'state-declared-gone-guard'
    $declaredGoneFile = Join-Path $testRoot 'written-declared-gone-guard.txt'
    [void](Invoke-ScopeCheck -CheckerArguments @('-Snapshot', '-Worktree', $declaredGoneRepo, '-Task', 'declared-gone-guard', '-StateDirectory', $declaredGoneState))
    $declaredGonePath = Join-Path $declaredGoneState 'scope-declared-gone-guard.snapshot.json'
    $declaredGoneText = [System.IO.File]::ReadAllText($declaredGonePath)
    Write-FixtureFile -RepoPath $declaredGoneRepo -Path 'src/App/bin/before.txt' -Content "changed ignored contents`r`n"
    $declaredStill = Invoke-ScopeCheck -CheckerArguments @('-Check', '-Worktree', $declaredGoneRepo, '-Task', 'declared-gone-guard', '-StateDirectory', $declaredGoneState, '-WrittenPathsFile', $declaredGoneFile)
    Assert-True -Name 'declared-class still ignored transition excluded' -Condition ($declaredStill.ExitCode -eq 0 -and $declaredStill.Output -match '1 declared build-output path\(s\) excluded') -Detail $declaredStill.Output
    $declaredGoneDirectory = [System.IO.Path]::GetFullPath((Join-Path $declaredGoneRepo 'src/App/bin'))
    if (-not $declaredGoneDirectory.StartsWith($testRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe declared fixture removal target' }
    Remove-Item -LiteralPath $declaredGoneDirectory -Recurse -Force
    foreach ($collectGone in @($true, $false)) {
        [System.IO.File]::WriteAllText($declaredGonePath, $declaredGoneText, [System.Text.UTF8Encoding]::new($false))
        $goneArguments = @('-Check', '-Worktree', $declaredGoneRepo, '-Task', 'declared-gone-guard', '-StateDirectory', $declaredGoneState)
        if ($collectGone) { $goneArguments += @('-WrittenPathsFile', $declaredGoneFile) }
        $declaredGone = Invoke-ScopeCheck -CheckerArguments $goneArguments
        Assert-True -Name ("declared-class ignored deletion collecting={0}" -f $collectGone) -Condition ($declaredGone.ExitCode -eq 0 -and $declaredGone.Output -match '1 declared build-output path\(s\) excluded' -and $declaredGone.Output -notmatch '\sGONE\s') -Detail $declaredGone.Output
    }
    Assert-WrittenPaths -Name 'declared-class ignored deletion emits no paths' -Path $declaredGoneFile -Expected @()

    # LOCKSTEP COVERAGE BOUNDARY: this block catches LIST and PRESCRIPTION drift plus per-entry
    # behaviour. Guard-LOGIC weakening is caught by derived-cache cases (3), (4), (6), (11), (12),
    # and format-2/statuses-stripped (14), plus its declared-class twin. Probe only scratch copies.
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
    if ($null -eq $previousApexStateDir) {
        Remove-Item Env:APEX_STATE_DIR -ErrorAction SilentlyContinue
    } else {
        $env:APEX_STATE_DIR = $previousApexStateDir
    }
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
