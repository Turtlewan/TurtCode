# Loud-fail coverage for single- and multi-root tree pins.

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'tree-pin.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("apex-tree-pin-test-$PID-" + [guid]::NewGuid().ToString('N'))
$failures = New-Object System.Collections.Generic.List[string]
$restoreGitConfigGlobal = $false
$savedGitConfigGlobal = $null
$savedApexStateDir = [Environment]::GetEnvironmentVariable('APEX_STATE_DIR', 'Process')

function Assert-Equal([string]$Name, $Expected, $Actual) {
    if ($Expected -ceq $Actual) {
        Write-Host "PASS: $Name" -ForegroundColor Green
    } else {
        $failures.Add("$Name -- expected '$Expected', got '$Actual'")
        Write-Host "FAIL: $Name -- expected '$Expected', got '$Actual'" -ForegroundColor Red
    }
}

function Assert-True([string]$Name, [bool]$Condition) {
    if ($Condition) {
        Write-Host "PASS: $Name" -ForegroundColor Green
    } else {
        $failures.Add($Name)
        Write-Host "FAIL: $Name" -ForegroundColor Red
    }
}

function Initialize-TestTree([string]$Path, [string]$FileName, [string]$Content) {
    New-Item -ItemType Directory -Path $Path | Out-Null
    & git -C $Path init --quiet
    if ($LASTEXITCODE -ne 0) { throw "git init failed for $Path" }
    & git -C $Path config core.autocrlf false
    if ($LASTEXITCODE -ne 0) { throw "git config failed for $Path" }
    [System.IO.File]::WriteAllText((Join-Path $Path $FileName), $Content, [System.Text.UTF8Encoding]::new($false))
    & git -C $Path add -- $FileName
    if ($LASTEXITCODE -ne 0) { throw "git add failed for $Path" }
    # Give every fixture a real HEAD: the fail-closed rev-parse guard must reject unborn HEAD, so
    # leaving fixtures merely staged would make their intended success paths invalid.
    $previousAuthorDate = [Environment]::GetEnvironmentVariable('GIT_AUTHOR_DATE', 'Process')
    $previousCommitterDate = [Environment]::GetEnvironmentVariable('GIT_COMMITTER_DATE', 'Process')
    try {
        [Environment]::SetEnvironmentVariable('GIT_AUTHOR_DATE', '2000-01-01T00:00:00Z', 'Process')
        [Environment]::SetEnvironmentVariable('GIT_COMMITTER_DATE', '2000-01-01T00:00:00Z', 'Process')
        & git -C $Path -c user.name='APEX tree-pin test' -c user.email='tree-pin-test@example.invalid' commit --quiet -m 'Initialize fixture'
        if ($LASTEXITCODE -ne 0) { throw "git commit failed for $Path" }
    } finally {
        [Environment]::SetEnvironmentVariable('GIT_AUTHOR_DATE', $previousAuthorDate, 'Process')
        [Environment]::SetEnvironmentVariable('GIT_COMMITTER_DATE', $previousCommitterDate, 'Process')
    }
}

function Write-Utf8File([string]$Path, [string]$Content) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Add-FixtureCommit($Fixture, [string[]]$Paths, [string]$Message, [switch]$Force) {
    $addArgs = @('-C', $Fixture.Root, 'add')
    if ($Force) { $addArgs += '-f' }
    $addArgs += '--'
    $addArgs += $Paths
    & git @addArgs
    if ($LASTEXITCODE -ne 0) { throw "git add failed for $($Fixture.Name) fixture" }
    & git -C $Fixture.Root -c user.name='APEX tree-pin test' -c user.email='tree-pin-test@example.invalid' commit --quiet -m $Message
    if ($LASTEXITCODE -ne 0) { throw "git commit failed for $($Fixture.Name) fixture" }
}

function Write-SyncedMarkers($Fixture, [string]$Suffix) {
    Write-Utf8File (Join-Path $Fixture.Root 'skills/synced/.bucket-u1') "bucket$Suffix`n"
    Write-Utf8File (Join-Path $Fixture.Root 'skills/synced/u1/.last-complete-round') "round$Suffix`n"
    Write-Utf8File (Join-Path $Fixture.Root 'skills/synced/u1/manifest.json') "{`"marker`":`"manifest$Suffix`"}`n"
}

function Write-SyncedSeed($Fixture) {
    Write-SyncedMarkers $Fixture '-seed'
    Write-Utf8File (Join-Path $Fixture.Root 'skills/synced/u1/docs/SKILL.md') "# Seeded skill`n"
}

function New-TestFixture([string]$Name, [string]$FileName, [string]$Content) {
    $root = Join-Path $testRoot $Name
    $pins = Join-Path $testRoot "$Name-pins"
    New-Item -ItemType Directory -Path $pins | Out-Null
    Initialize-TestTree $root $FileName $Content
    return [pscustomobject]@{ Name = $Name; Root = $root; Pins = $pins }
}

function Get-FixtureArgs($Fixture, [string]$RuntimeRoot) {
    return @(
        '-Worktree', $Fixture.Root,
        '-Label', $Fixture.Name,
        '-PinDirectory', $Fixture.Pins,
        '-RuntimeExclusionRoot', $RuntimeRoot
    )
}

function Invoke-TreePin([string[]]$Arguments) {
    # Expected fail-closed cases write a terminating error to stderr; collect that diagnostic
    # without letting the harness's Stop preference abort before it can assert the non-zero exit.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = [string]::Join("`n", ($output | ForEach-Object { [string]$_ }))
    }
}

function Get-BuildOutputsBlockBytes([string]$Path) {
    $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($Path))
    $block = [regex]::Match($text, '(?ms)^# BEGIN build-outputs lockstep\r?\n.*?^# END build-outputs lockstep')
    if (-not $block.Success) { throw "Missing build-outputs lockstep block in $Path" }
    return ,([System.Text.Encoding]::UTF8.GetBytes($block.Value))
}

function Assert-BuildOutputsLockstep([string]$TreePinPath, [string]$ScopePath, [string]$EnginePath) {
    $pinBytes = Get-BuildOutputsBlockBytes $TreePinPath
    $scopeBytes = Get-BuildOutputsBlockBytes $ScopePath
    $engineBytes = Get-BuildOutputsBlockBytes $EnginePath
    $pinBlock = [Convert]::ToBase64String($pinBytes)
    $scopeBlock = [Convert]::ToBase64String($scopeBytes)
    $engineBlock = [Convert]::ToBase64String($engineBytes)
    if ($pinBlock -cne $scopeBlock -or $pinBlock -cne $engineBlock -or $scopeBlock -cne $engineBlock) {
        throw 'Build-outputs lockstep blocks differ byte-for-byte'
    }
}

function New-BuildOutputFixture([string]$Name, [string]$AgentsText) {
    $fixture = New-TestFixture $Name '.gitignore' "src/*/bin/`nsrc/*/obj/`n"
    Write-Utf8File (Join-Path $fixture.Root 'AGENTS.md') $AgentsText
    Add-FixtureCommit $fixture @('AGENTS.md') 'Declare fixture build outputs'
    return $fixture
}

function New-AgentsFetchFailureShim([string]$Name, [string]$FailCommand) {
    $shimRoot = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path $shimRoot | Out-Null
    $gitPath = (Get-Command git.exe -ErrorAction Stop).Source
    $failLine = if ($FailCommand -ceq 'ls-tree') {
        'if "%~3"=="ls-tree" if "%~4"=="--full-tree" if "%~5"=="--name-only" if "%~8"=="AGENTS.md" exit /b 42'
    } else {
        'if "%~3"=="show" if "%~4"=="HEAD:AGENTS.md" exit /b 42'
    }
    [System.IO.File]::WriteAllLines((Join-Path $shimRoot 'git.cmd'), [string[]]@(
        '@echo off', $failLine, ('"{0}" %*' -f $gitPath), 'exit /b %ERRORLEVEL%'
    ), [System.Text.Encoding]::ASCII)
    return $shimRoot
}

function Get-PinPath([string]$Root, [string]$Label, [string]$PinDirectory) {
    $worktreeFull = (Resolve-Path -LiteralPath $Root).Path
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $keyBytes = [System.Text.Encoding]::UTF8.GetBytes(($worktreeFull -replace '\\', '/').TrimEnd('/').ToLowerInvariant())
        $tag = [System.BitConverter]::ToString($sha.ComputeHash($keyBytes)).Replace('-', '').Substring(0, 10).ToLower()
    } finally { $sha.Dispose() }
    $safeLabel = ($Label -replace '[<>:"/\\|?*]', '_')
    return Join-Path $PinDirectory "apex-treepin-$safeLabel-$tag.txt"
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null

    $savedGitConfigGlobal = [Environment]::GetEnvironmentVariable('GIT_CONFIG_GLOBAL', 'Process')
    $restoreGitConfigGlobal = $true
    $isolatedGlobalIgnore = Join-Path $testRoot 'empty-global-ignore'
    $isolatedGlobalConfig = Join-Path $testRoot 'isolated-global.gitconfig'
    Write-Utf8File $isolatedGlobalIgnore ''
    $isolatedGlobalIgnoreForConfig = $isolatedGlobalIgnore -replace '\\', '/'
    Write-Utf8File $isolatedGlobalConfig "[core]`n    excludesFile = $isolatedGlobalIgnoreForConfig`n"
    $env:GIT_CONFIG_GLOBAL = $isolatedGlobalConfig
    $env:APEX_STATE_DIR = Join-Path $testRoot 'state'

    $rootOne = Join-Path $testRoot 'root-one'
    $rootTwo = Join-Path $testRoot 'root-two'
    $multiPins = Join-Path $testRoot 'multi-pins'
    New-Item -ItemType Directory -Path $multiPins | Out-Null
    Initialize-TestTree $rootOne 'tracked.txt' "root-one`n"
    Initialize-TestTree $rootTwo 'tracked.txt' "root-two`n"

    # Regression: the old empty-output fingerprint made a non-repository Pin exit 0. Any git error
    # in fingerprint construction must now fail closed with a diagnostic and a non-zero exit.
    $nonGitRoot = Join-Path $testRoot 'not-a-git-directory'
    $nonGitPins = Join-Path $testRoot 'non-git-pins'
    New-Item -ItemType Directory -Path $nonGitRoot, $nonGitPins | Out-Null
    $result = Invoke-TreePin (@('-Pin', '-Worktree', $nonGitRoot, '-Label', 'non-git', '-PinDirectory', $nonGitPins))
    Assert-True 'non-git directory fails closed with a non-zero exit' ($result.ExitCode -ne 0)
    Assert-True 'non-git failure reports the git invocation' ($result.Output -match 'git')

    $multiArgs = @('-Worktree', $rootOne, '-PinAlso', $rootTwo, '-Label', 'multi-root', '-PinDirectory', $multiPins)
    $result = Invoke-TreePin (@('-Pin') + $multiArgs)
    Assert-Equal 'pinning two roots exits 0' 0 $result.ExitCode
    Assert-Equal 'pinning two roots writes two pin files' 2 @(Get-ChildItem -LiteralPath $multiPins -File).Count

    $result = Invoke-TreePin (@('-Verify') + $multiArgs)
    Assert-Equal 'two clean roots verify with exit 0' 0 $result.ExitCode

    [System.IO.File]::WriteAllText((Join-Path $rootTwo 'tracked.txt'), "root-two-moved`n", [System.Text.UTF8Encoding]::new($false))
    $result = Invoke-TreePin (@('-Verify') + $multiArgs)
    Assert-Equal 'one moved root verifies with exit 69' 69 $result.ExitCode
    Assert-True 'moved-root failure names that root' ($result.Output -match [regex]::Escape((Resolve-Path -LiteralPath $rootTwo).Path))

    [System.IO.File]::WriteAllText((Join-Path $rootTwo 'tracked.txt'), "root-two`n", [System.Text.UTF8Encoding]::new($false))
    $result = Invoke-TreePin (@('-Pin') + $multiArgs)
    Assert-Equal 'repinning restored roots exits 0' 0 $result.ExitCode
    $rootOnePin = Get-PinPath $rootOne 'multi-root' $multiPins
    $rootTwoPin = Get-PinPath $rootTwo 'multi-root' $multiPins
    Remove-Item -LiteralPath $rootTwoPin -Force
    Assert-True 'primary root pin remains after deleting additional root pin' (Test-Path -LiteralPath $rootOnePin -PathType Leaf)
    $result = Invoke-TreePin (@('-Verify') + $multiArgs)
    Assert-Equal 'missing additional-root pin verifies with exit 69' 69 $result.ExitCode
    Assert-True 'missing-pin failure names the additional root' ($result.Output -match [regex]::Escape((Resolve-Path -LiteralPath $rootTwo).Path))

    $singleRoot = Join-Path $testRoot 'single-root'
    $singlePins = Join-Path $testRoot 'single-pins'
    New-Item -ItemType Directory -Path $singlePins | Out-Null
    Initialize-TestTree $singleRoot 'tracked.txt' "fixture-content`n"
    $singleArgs = @('-Worktree', $singleRoot, '-Label', 'single-root-byte-fixture', '-PinDirectory', $singlePins)
    $result = Invoke-TreePin (@('-Pin') + $singleArgs)
    Assert-Equal 'single-root pin exits 0' 0 $result.ExitCode
    Assert-True 'single-root pin keeps the legacy confirmation format' ($result.Output -match "^\[tree-pin\] pinned [0-9a-f]{12} for 'single-root-byte-fixture'$")

    $singlePin = Get-ChildItem -LiteralPath $singlePins -File | Select-Object -First 1
    Assert-Equal 'single-root pin keeps the worktree-tagged file name' (Split-Path -Leaf (Get-PinPath $singleRoot 'single-root-byte-fixture' $singlePins)) $singlePin.Name
    # Frozen bytes for this exact committed fixture and label; the deterministic commit timestamp
    # keeps the real-HEAD fingerprint stable across runs. Regenerated for fail-closed rev-parse.
    # SHA-256 of these fixture bytes: 1aaafd4bd1b85e7a79af5da2aa662d2754c6bfcb99dad653ee4f85cb95be0813.
    $committedPinBase64 = 'dHJlZXBpbi12MgpiZWE3MmRjYjE5M2Q4YmRhOWZhOTZmMzlhNTBkZTExMWI2NTY2MjM0MzQ0MDQzNGM3ZTk1ZDA5MzE1NGViMDk3CkhFQUQgMDI5ZjQ4MmE3Njc4MTUwN2EzOTI5NmIxZGEyZjllNmEyNjc5Zjg1MA=='
    $actualPinBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($singlePin.FullName))
    Assert-Equal 'single-root pin bytes match the committed-HEAD fixture' $committedPinBase64 $actualPinBase64

    $result = Invoke-TreePin (@('-Verify') + $singleArgs)
    Assert-Equal 'clean single root verifies with exit 0' 0 $result.ExitCode
    Assert-True 'single-root verify keeps the legacy confirmation format' ($result.Output -match '^\[tree-pin\] tree unchanged \([0-9a-f]{12}\) -- the verdict is about this tree\.$')
    [System.IO.File]::WriteAllText((Join-Path $singleRoot 'tracked.txt'), "fixture-content-moved`n", [System.Text.UTF8Encoding]::new($false))
    $result = Invoke-TreePin (@('-Verify') + $singleArgs)
    Assert-Equal 'moved single root verifies with exit 69' 69 $result.ExitCode

    # Ignored churn outside the runtime-noise allowlist remains review-relevant.
    $fixture = New-TestFixture 'ignored-outside' '.gitignore' "/cache/`n"
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'ignored-outside baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'cache/new.txt') "outside`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'new ignored file outside runtime exclusions moves the tree' 69 $result.ExitCode

    # A newly-created ignored runtime directory is filtered only on the runtime tree.
    $fixture = New-TestFixture 'ignored-projects' '.gitignore' "/projects/`n"
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'excluded ignored-dir baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'projects/session.json') "runtime noise`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'new ignored file under excluded runtime dir verifies unchanged' 0 $result.ExitCode

    $fixture = New-TestFixture 'ignored-unchanged' '.gitignore' "/cache/`n"
    Write-Utf8File (Join-Path $fixture.Root 'cache/preexisting.txt') "stable`n"
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'pre-existing ignored dir pins successfully' 0 $result.ExitCode
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'pre-existing ignored dir unchanged verifies with exit 0' 0 $result.ExitCode

    # Pins without the v2 scheme marker fail closed with tree-pin's re-pin diagnostic.
    $fixture = New-TestFixture 'v1-pin' 'tracked.txt' "v1 fixture`n"
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'v1 fixture starts from a successful v2 pin' 0 $result.ExitCode
    $pinPath = Get-PinPath $fixture.Root $fixture.Name $fixture.Pins
    $v2Lines = [System.IO.File]::ReadAllLines($pinPath)
    [System.IO.File]::WriteAllText($pinPath, [string]::Join("`n", ($v2Lines | Select-Object -Skip 1)),
        [System.Text.UTF8Encoding]::new($false))
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'v1-format pin verifies with exit 69' 69 $result.ExitCode
    Assert-True 'v1-format pin requests a re-pin' ($result.Output -match '^pin predates digest scheme v2 -- re-pin$')
    Assert-True 'v1-format pin does not render the tree-moved banner' ($result.Output -notmatch 'THE TREE MOVED')

    $fixture = New-TestFixture 'fresh-v2' 'tracked.txt' "fresh fixture`n"
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'fresh v2 pin exits 0' 0 $result.ExitCode
    $freshPinPath = Get-PinPath $fixture.Root $fixture.Name $fixture.Pins
    Assert-Equal 'fresh pin starts with the v2 scheme marker' 'treepin-v2' ([System.IO.File]::ReadAllLines($freshPinPath)[0])
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'fresh v2 pin immediately verifies with exit 0' 0 $result.ExitCode

    $fixture = New-TestFixture 'v2-detail' 'tracked.txt' "before`n"
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'v2 detail fixture pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'tracked.txt') "after with different bytes`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'v2-vs-v2 move verifies with exit 69' 69 $result.ExitCode
    Assert-True 'v2-vs-v2 move renders a detail line' ($result.Output -match '(?m)^\[tree-pin\]\s+(CHANGED|NEW|GONE):')

    # Status, not path alone, controls exclusion: a tracked rename into projects/ still moves.
    $fixture = New-TestFixture 'tracked-rename' 'tracked.txt' "rename me`n"
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'tracked-rename baseline pin exits 0' 0 $result.ExitCode
    New-Item -ItemType Directory -Path (Join-Path $fixture.Root 'projects') | Out-Null
    & git -C $fixture.Root mv -- tracked.txt projects/tracked.txt
    if ($LASTEXITCODE -ne 0) { throw 'git mv failed for tracked-rename fixture' }
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'tracked rename into excluded dir moves the tree' 69 $result.ExitCode

    # A collapsed ignored directory uses one in-process metadata digest, which changes on inner churn.
    $fixture = New-TestFixture 'ignored-inner-move' '.gitignore' "/cache/`n"
    Write-Utf8File (Join-Path $fixture.Root 'cache/item.txt') "short`n"
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'collapsed ignored-dir baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'cache/item.txt') "decisively longer content`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'content mutation inside collapsed ignored dir moves the tree' 69 $result.ExitCode

    $fixture = New-TestFixture 'history-exact' '.gitignore' "/history.jsonl`n"
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'history exact-file baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'history.jsonl') "event-one`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'ignored history.jsonl churn is excluded' 0 $result.ExitCode

    $fixture = New-TestFixture 'projects-near-miss' '.gitignore' "/projectsX/`n"
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'projectsX baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'projectsX/item.txt') "near miss`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'ignored projectsX near-miss moves the tree' 69 $result.ExitCode

    $fixture = New-TestFixture 'untracked-projects' 'tracked.txt' "tracked`n"
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'untracked-under-prefix baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'projects/item.txt') "untracked`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'question-mark untracked file under excluded prefix moves the tree' 69 $result.ExitCode

    $fixture = New-TestFixture 'nested-projects' '.gitignore' "/nested/projects/`n"
    Write-Utf8File (Join-Path $fixture.Root 'nested/.keep') "tracked parent`n"
    & git -C $fixture.Root add -- nested/.keep
    if ($LASTEXITCODE -ne 0) { throw 'git add failed for nested-projects fixture' }
    & git -C $fixture.Root -c user.name='APEX tree-pin test' -c user.email='tree-pin-test@example.invalid' commit --quiet -m 'Track nested parent'
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed for nested-projects fixture' }
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'nested-projects baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'nested/projects/item.txt') "nested`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'nested projects ignored path is not root-excluded' 69 $result.ExitCode

    $fixture = New-TestFixture 'off-runtime-root' '.gitignore' "/projects/`n"
    $differentRuntimeRoot = Join-Path $testRoot 'different-runtime-root'
    New-Item -ItemType Directory -Path $differentRuntimeRoot | Out-Null
    $argsForCase = Get-FixtureArgs $fixture $differentRuntimeRoot
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'different-runtime-root baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'projects/item.txt') "not runtime tree`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'ignored projects churn off the runtime tree moves the tree' 69 $result.ExitCode

    # Synced runtime markers are filtered only when they are ignored regular files under the
    # configured runtime root. Isolate the fixtures from any user-level global excludes first.

    $fixture = New-TestFixture 'synced-marker-rewrites' '.gitignore' "/skills/synced/`n/skills/synced-foo/`n"
    Write-Utf8File (Join-Path $fixture.Root 'skills/apex/SKILL.md') "# APEX skill`n"
    Add-FixtureCommit $fixture @('skills/apex/SKILL.md') 'Track APEX skill'
    Write-SyncedSeed $fixture
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'synced marker rewrites baseline pin exits 0' 0 $result.ExitCode
    Write-SyncedMarkers $fixture '-rewritten-with-longer-content'
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'rewriting all synced runtime markers verifies unchanged' 0 $result.ExitCode

    $fixture = New-TestFixture 'synced-created-after-pin' '.gitignore' "/skills/synced/`n/skills/synced-foo/`n"
    Write-Utf8File (Join-Path $fixture.Root 'skills/apex/SKILL.md') "# APEX skill`n"
    Add-FixtureCommit $fixture @('skills/apex/SKILL.md') 'Track APEX skill'
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'synced markers absent baseline pin exits 0' 0 $result.ExitCode
    Write-SyncedMarkers $fixture '-created-after-pin'
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'creating only synced runtime markers verifies unchanged' 0 $result.ExitCode

    $fixture = New-TestFixture 'synced-root-skill' '.gitignore' "/skills/synced/`n/skills/synced-foo/`n"
    Write-Utf8File (Join-Path $fixture.Root 'skills/apex/SKILL.md') "# APEX skill`n"
    Add-FixtureCommit $fixture @('skills/apex/SKILL.md') 'Track APEX skill'
    Write-SyncedSeed $fixture
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'synced root skill baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'skills/synced/SKILL.md') "# Root synced skill`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'new root synced SKILL.md moves the tree' 69 $result.ExitCode

    $fixture = New-TestFixture 'synced-nested-skill' '.gitignore' "/skills/synced/`n/skills/synced-foo/`n"
    Write-Utf8File (Join-Path $fixture.Root 'skills/apex/SKILL.md') "# APEX skill`n"
    Add-FixtureCommit $fixture @('skills/apex/SKILL.md') 'Track APEX skill'
    Write-SyncedSeed $fixture
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'synced nested skill baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'skills/synced/u1/x/SKILL.md') "# Nested synced skill`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'new nested synced SKILL.md moves the tree' 69 $result.ExitCode

    $fixture = New-TestFixture 'synced-nested-script' '.gitignore' "/skills/synced/`n/skills/synced-foo/`n"
    Write-Utf8File (Join-Path $fixture.Root 'skills/apex/SKILL.md') "# APEX skill`n"
    Add-FixtureCommit $fixture @('skills/apex/SKILL.md') 'Track APEX skill'
    Write-SyncedSeed $fixture
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'synced nested script baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'skills/synced/u1/x/scripts/a.py') "print('synced')`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'new nested synced script moves the tree' 69 $result.ExitCode

    $fixture = New-TestFixture 'synced-deep-manifest' '.gitignore' "/skills/synced/`n/skills/synced-foo/`n"
    Write-Utf8File (Join-Path $fixture.Root 'skills/apex/SKILL.md') "# APEX skill`n"
    Add-FixtureCommit $fixture @('skills/apex/SKILL.md') 'Track APEX skill'
    Write-SyncedSeed $fixture
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'synced deep manifest baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'skills/synced/u1/docs/manifest.json') "{`"tooDeep`":true}`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'too-deep synced manifest moves the tree' 69 $result.ExitCode

    $fixture = New-TestFixture 'synced-delete-docs' '.gitignore' "/skills/synced/`n/skills/synced-foo/`n"
    Write-Utf8File (Join-Path $fixture.Root 'skills/apex/SKILL.md') "# APEX skill`n"
    Add-FixtureCommit $fixture @('skills/apex/SKILL.md') 'Track APEX skill'
    Write-SyncedSeed $fixture
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'synced docs deletion baseline pin exits 0' 0 $result.ExitCode
    Remove-Item -LiteralPath (Join-Path $fixture.Root 'skills/synced/u1/docs') -Recurse -Force
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'deleting synced docs moves the tree' 69 $result.ExitCode

    $fixture = New-TestFixture 'synced-near-miss-root' '.gitignore' "/skills/synced/`n/skills/synced-foo/`n"
    Write-Utf8File (Join-Path $fixture.Root 'skills/apex/SKILL.md') "# APEX skill`n"
    Add-FixtureCommit $fixture @('skills/apex/SKILL.md') 'Track APEX skill'
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'synced near-miss root baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'skills/synced-foo/.bucket-u1') "near-miss bucket`n"
    Write-Utf8File (Join-Path $fixture.Root 'skills/synced-foo/u1/manifest.json') "{`"nearMiss`":true}`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'markers under synced-foo move the tree' 69 $result.ExitCode

    $fixture = New-TestFixture 'synced-off-runtime-root' '.gitignore' "/skills/synced/`n/skills/synced-foo/`n"
    Write-Utf8File (Join-Path $fixture.Root 'skills/apex/SKILL.md') "# APEX skill`n"
    Add-FixtureCommit $fixture @('skills/apex/SKILL.md') 'Track APEX skill'
    Write-SyncedSeed $fixture
    $syncedDifferentRuntimeRoot = Join-Path $testRoot 'synced-separate-runtime-root'
    New-Item -ItemType Directory -Path $syncedDifferentRuntimeRoot | Out-Null
    $argsForCase = Get-FixtureArgs $fixture $syncedDifferentRuntimeRoot
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'synced off-runtime-root baseline pin exits 0' 0 $result.ExitCode
    Write-SyncedMarkers $fixture '-rewritten-off-runtime-root-with-longer-content'
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'synced marker rewrites off the runtime root move the tree' 69 $result.ExitCode

    $fixture = New-TestFixture 'synced-tracked-marker' '.gitignore' "/skills/synced/`n/skills/synced-foo/`n"
    Write-Utf8File (Join-Path $fixture.Root 'skills/apex/SKILL.md') "# APEX skill`n"
    Add-FixtureCommit $fixture @('skills/apex/SKILL.md') 'Track APEX skill'
    Write-SyncedSeed $fixture
    Add-FixtureCommit $fixture @('skills/synced/u1/manifest.json') 'Track synced manifest' -Force
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'tracked synced marker baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'skills/synced/u1/manifest.json') "{`"marker`":`"tracked manifest rewritten with longer content`"}`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'rewriting a tracked synced marker moves the tree' 69 $result.ExitCode

    $fixture = New-TestFixture 'synced-ignored-leaves' '.gitignore' "/skills/synced/`n/skills/synced-foo/`n"
    Write-Utf8File (Join-Path $fixture.Root 'skills/apex/SKILL.md') "# APEX skill`n"
    Add-FixtureCommit $fixture @('skills/apex/SKILL.md') 'Track APEX skill'
    Write-SyncedSeed $fixture
    Add-FixtureCommit $fixture @('skills/synced/u1/docs/SKILL.md') 'Track seeded synced skill' -Force
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'individual ignored marker leaves baseline pin exits 0' 0 $result.ExitCode
    Write-SyncedMarkers $fixture '-rewritten-as-individual-ignored-leaves'
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'rewriting individual ignored marker leaves verifies unchanged' 0 $result.ExitCode

    $fixture = New-TestFixture 'synced-untracked-markers' '.gitignore' ''
    Write-Utf8File (Join-Path $fixture.Root 'skills/apex/SKILL.md') "# APEX skill`n"
    Add-FixtureCommit $fixture @('skills/apex/SKILL.md') 'Track APEX skill'
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'untracked synced markers baseline pin exits 0' 0 $result.ExitCode
    Write-SyncedMarkers $fixture '-untracked'
    $syncedStatusLines = @(& git -C $fixture.Root status --porcelain --ignored=traditional -- skills/synced)
    if ($LASTEXITCODE -ne 0) { throw 'git status failed for synced-untracked-markers fixture' }
    Assert-True 'untracked synced marker status contains only question-mark entries' (
        $syncedStatusLines.Count -gt 0 -and
        @($syncedStatusLines | Where-Object { $_ -notmatch '^\?\? ' }).Count -eq 0)
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'untracked synced markers move the tree' 69 $result.ExitCode

    $fixture = New-TestFixture 'synced-bucket-directory' '.gitignore' "/skills/synced/`n/skills/synced-foo/`n"
    Write-Utf8File (Join-Path $fixture.Root 'skills/apex/SKILL.md') "# APEX skill`n"
    Add-FixtureCommit $fixture @('skills/apex/SKILL.md') 'Track APEX skill'
    Write-Utf8File (Join-Path $fixture.Root 'skills/synced/u1/docs/SKILL.md') "# Tracked synced skill`n"
    Add-FixtureCommit $fixture @('skills/synced/u1/docs/SKILL.md') 'Track synced skill' -Force
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'bucket directory baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'skills/synced/.bucket-u1/SKILL.md') "# Not a marker file`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'bucket-named directory moves the tree' 69 $result.ExitCode

    $fixture = New-TestFixture 'synced-manifest-directory' '.gitignore' "/skills/synced/`n/skills/synced-foo/`n"
    Write-Utf8File (Join-Path $fixture.Root 'skills/apex/SKILL.md') "# APEX skill`n"
    Add-FixtureCommit $fixture @('skills/apex/SKILL.md') 'Track APEX skill'
    Write-Utf8File (Join-Path $fixture.Root 'skills/synced/u1/docs/SKILL.md') "# Tracked synced skill`n"
    Add-FixtureCommit $fixture @('skills/synced/u1/docs/SKILL.md') 'Track synced skill' -Force
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'manifest directory baseline pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'skills/synced/u1/manifest.json/run.ps1') "Write-Host 'not a marker file'`n"
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'manifest-named directory moves the tree' 69 $result.ExitCode

    # Read the sibling WORKING-TREE sources; no commit/ref/SHA lookup substitutes for these files.
    $scopePath = Join-Path $PSScriptRoot 'codex-scope-check.ps1'
    $enginePath = Join-Path $PSScriptRoot 'apex-engine.ps1'
    Assert-BuildOutputsLockstep $scriptPath $scopePath $enginePath
    Assert-True 'build-output marker blocks are byte-equal across working-tree Engine, scope-check, and tree-pin' $true
    $scratchPin = Join-Path $testRoot 'mutated-tree-pin.ps1'
    Copy-Item -LiteralPath $scriptPath -Destination $scratchPin
    $scratchText = [System.IO.File]::ReadAllText($scratchPin).Replace('duplicate exact heading', 'mutated exact heading')
    Write-Utf8File $scratchPin $scratchText
    $mutationRejected = $false
    try { Assert-BuildOutputsLockstep $scratchPin $scopePath $enginePath } catch { $mutationRejected = $true }
    Assert-True 'three-way lockstep check rejects a mutated scratch copy' $mutationRejected

    # Execute only the shared pure functions to inspect parser results without invoking tree-pin.
    $pureBlock = [System.Text.Encoding]::UTF8.GetString((Get-BuildOutputsBlockBytes $scriptPath))
    . ([scriptblock]::Create($pureBlock))
    $fence = '```'
    $validAgents = "# Fixture`n## Build outputs`n$fence`nsrc/*/bin`nsrc/*/obj`n$fence`n"
    $templatePath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'apex-orchestrate/templates/AGENTS-template.md'
    $templateDeclaration = ConvertFrom-BuildOutputsSection -Text ([System.IO.File]::ReadAllText($templatePath))
    Assert-Equal 'real AGENTS template has zero build-output entries' 0 @($templateDeclaration.Entries).Count
    Assert-True 'real AGENTS template has no build-output warning' ([string]::IsNullOrEmpty($templateDeclaration.Warning))
    $exampleAgents = "# Fixture`n~~~~markdown`n## Build outputs`n$fence`nsrc/*/obj`n$fence`n~~~~`n"
    $exampleDeclaration = ConvertFrom-BuildOutputsSection -Text $exampleAgents
    Assert-Equal 'fenced-example heading has zero entries' 0 @($exampleDeclaration.Entries).Count
    Assert-True 'fenced-example heading has no warning' ([string]::IsNullOrEmpty($exampleDeclaration.Warning))

    foreach ($declared in @($true, $false)) {
        $name = if ($declared) { 'declared-ignored-obj' } else { 'undeclared-ignored-obj' }
        $agentsText = if ($declared) { $validAgents } else { '# No declaration' }
        $fixture = New-BuildOutputFixture $name $agentsText
        Write-Utf8File (Join-Path $fixture.Root 'src/App/App.cs') "tracked source`n"
        Add-FixtureCommit $fixture @('src/App/App.cs') 'Track project source'
        Write-Utf8File (Join-Path $fixture.Root 'src/App/obj/output.txt') 'before'
        $argsForCase = Get-FixtureArgs $fixture $fixture.Root
        $result = Invoke-TreePin (@('-Pin') + $argsForCase)
        Assert-Equal "$name pin exits 0" 0 $result.ExitCode
        Write-Utf8File (Join-Path $fixture.Root 'src/App/obj/output.txt') 'longer output after pin'
        $result = Invoke-TreePin (@('-Verify') + $argsForCase)
        $expected = if ($declared) { 0 } else { 69 }
        Assert-Equal "$name write verification" $expected $result.ExitCode
    }

    $fixture = New-BuildOutputFixture 'new-project' $validAgents
    Write-Utf8File (Join-Path $fixture.Root 'src/New/App.cs') 'untracked source'
    Write-Utf8File (Join-Path $fixture.Root 'src/New/bin/output.txt') 'before'
    $projectStatus = @(& git -C $fixture.Root status --porcelain --ignored=traditional)
    if ($LASTEXITCODE -ne 0) { throw 'git status failed for new-project fixture' }
    Assert-True 'new project is a collapsed question-mark directory' ($projectStatus -ccontains '?? src/')
    Assert-True 'new project has an actual ignored bin row' ($projectStatus -ccontains '!! src/New/bin/')
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'new project pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'src/New/bin/output.txt') 'longer ignored output'
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'declared ignored bin write inside collapsed question-mark directory verifies 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'src/New/App.cs') 'changed source with more bytes'
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'source write inside collapsed question-mark directory verifies 69' 69 $result.ExitCode

    $fixture = New-BuildOutputFixture 'tracked-bin' $validAgents
    Write-Utf8File (Join-Path $fixture.Root 'src/App/bin/run.ps1') 'tracked executable'
    Add-FixtureCommit $fixture @('src/App/bin/run.ps1') 'Track bin executable' -Force
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'tracked bin pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'src/App/bin/run.ps1') 'changed tracked executable'
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'tracked bin edit verifies 69 despite declaration' 69 $result.ExitCode

    # The declaration must be committed, and only ignored rows qualify for exclusion.
    $fixture = New-BuildOutputFixture 'uncommitted-declaration' '# No declaration'
    Write-Utf8File (Join-Path $fixture.Root 'AGENTS.md') $validAgents
    Write-Utf8File (Join-Path $fixture.Root 'src/App/obj/output.txt') 'before'
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'uncommitted declaration pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'src/App/obj/output.txt') 'longer output'
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'working-tree-only declaration does not exclude ignored output' 69 $result.ExitCode

    $fixture = New-TestFixture 'unignored-bin' 'AGENTS.md' $validAgents
    Write-Utf8File (Join-Path $fixture.Root 'src/App/bin/run.ps1') 'unignored source'
    $argsForCase = Get-FixtureArgs $fixture $fixture.Root
    $result = Invoke-TreePin (@('-Pin') + $argsForCase)
    Assert-Equal 'unignored bin pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $fixture.Root 'src/App/bin/run.ps1') 'changed unignored source'
    $result = Invoke-TreePin (@('-Verify') + $argsForCase)
    Assert-Equal 'declared but unignored bin edit verifies 69' 69 $result.ExitCode

    $malformedAgents = "## Build outputs`n$fence`nsrc/*/obj`n**/bin`n$fence`n"
    $duplicateAgents = $validAgents + "## Build outputs`n$fence`nsrc/*/obj`n$fence`n"
    foreach ($case in @(
            [pscustomobject]@{ Name = 'malformed'; Text = $malformedAgents; Warn = $true },
            [pscustomobject]@{ Name = 'duplicate'; Text = $duplicateAgents; Warn = $true },
            [pscustomobject]@{ Name = 'fenced-example'; Text = $exampleAgents; Warn = $false })) {
        $declaration = ConvertFrom-BuildOutputsSection -Text $case.Text
        Assert-Equal "$($case.Name) parser applies no exclusions" 0 @($declaration.Entries).Count
        $fixture = New-BuildOutputFixture $case.Name $case.Text
        Write-Utf8File (Join-Path $fixture.Root 'src/App/App.cs') 'source'
        Add-FixtureCommit $fixture @('src/App/App.cs') 'Track source'
        Write-Utf8File (Join-Path $fixture.Root 'src/App/obj/output.txt') 'before'
        $argsForCase = Get-FixtureArgs $fixture $fixture.Root
        $result = Invoke-TreePin @('-Digest', '-Worktree', $fixture.Root)
        Assert-Equal "$($case.Name) Digest exits 0" 0 $result.ExitCode
        Assert-True "$($case.Name) Digest prints only one 64-hex digest" ($result.Output -cmatch '\A[0-9a-f]{64}\z')
        $result = Invoke-TreePin (@('-Pin') + $argsForCase)
        Assert-Equal "$($case.Name) Pin exits 0" 0 $result.ExitCode
        $warningCount = if ($case.Warn) { 1 } else { 0 }
        Assert-Equal "$($case.Name) Pin warning count" $warningCount ([regex]::Matches($result.Output, '\[tree-pin\] WARNING:').Count)
        Write-Utf8File (Join-Path $fixture.Root 'src/App/obj/output.txt') 'longer output after pin'
        $result = Invoke-TreePin (@('-Verify') + $argsForCase)
        Assert-Equal "$($case.Name) ignored output write verifies 69" 69 $result.ExitCode
        Assert-Equal "$($case.Name) Verify warning count" $warningCount ([regex]::Matches($result.Output, '\[tree-pin\] WARNING:').Count)
    }

    # A committed-AGENTS fetch failure must throw; no valid pin/digest may escape.
    $fetchFixture = New-BuildOutputFixture 'agents-fetch-failure' $validAgents
    foreach ($fetchCommand in @('ls-tree', 'show')) {
        $shimRoot = New-AgentsFetchFailureShim ('shim-' + $fetchCommand) $fetchCommand
        $savedPath = $env:PATH
        try {
            $env:PATH = $shimRoot + [System.IO.Path]::PathSeparator + $savedPath
            foreach ($mode in @('-Pin', '-Verify', '-Digest')) {
                $result = Invoke-TreePin (@($mode) + (Get-FixtureArgs $fetchFixture $fetchFixture.Root))
                Assert-True "$fetchCommand committed AGENTS fetch failure throws for $mode" ($result.ExitCode -ne 0 -and $result.ExitCode -ne 69)
                Assert-True "$fetchCommand fetch failure reports native exit 42 for $mode" ($result.Output -match 'git exited with status 42')
            }
            Assert-Equal "$fetchCommand fetch failure creates no pin" 0 @(Get-ChildItem -LiteralPath $fetchFixture.Pins -File).Count
        } finally { $env:PATH = $savedPath }
    }

    # PinAlso roots must load their own committed declarations.
    $declaredRoot = New-BuildOutputFixture 'multi-declared' $validAgents
    $undeclaredRoot = New-BuildOutputFixture 'multi-undeclared' '# No declaration'
    foreach ($fixture in @($declaredRoot, $undeclaredRoot)) {
        Write-Utf8File (Join-Path $fixture.Root 'src/App/App.cs') 'source'
        Add-FixtureCommit $fixture @('src/App/App.cs') 'Track source'
        Write-Utf8File (Join-Path $fixture.Root 'src/App/obj/output.txt') 'before'
    }
    $multiBuildArgs = @('-Worktree', $declaredRoot.Root, '-PinAlso', $undeclaredRoot.Root,
        '-Label', 'multi-build', '-PinDirectory', $declaredRoot.Pins)
    $result = Invoke-TreePin (@('-Pin') + $multiBuildArgs)
    Assert-Equal 'multi-root build declarations Pin exits 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $declaredRoot.Root 'src/App/obj/output.txt') 'longer declared output'
    $result = Invoke-TreePin (@('-Verify') + $multiBuildArgs)
    Assert-Equal 'multi-root declared output write verifies 0' 0 $result.ExitCode
    Write-Utf8File (Join-Path $undeclaredRoot.Root 'src/App/obj/output.txt') 'longer undeclared output'
    $result = Invoke-TreePin (@('-Verify') + $multiBuildArgs)
    Assert-Equal 'additional root undeclared output write verifies 69' 69 $result.ExitCode

    # Digest is a compute-only, single-tree interface: one bare digest and no pin artifact.
    $fixture = New-TestFixture 'digest-contract' 'tracked.txt' "digest fixture`n"
    $digestArgs = @(
        '-Worktree', $fixture.Root,
        '-PinDirectory', $fixture.Pins,
        '-RuntimeExclusionRoot', $fixture.Root
    )
    $firstDigest = Invoke-TreePin (@('-Digest') + $digestArgs)
    Assert-Equal 'digest shape exits 0' 0 $firstDigest.ExitCode
    Assert-True 'digest shape is exactly one bare lowercase SHA-256 line' ($firstDigest.Output -match '^[0-9a-f]{64}$')
    Assert-Equal 'digest shape mints no pin artifact' 0 @(Get-ChildItem -LiteralPath $fixture.Pins -Filter 'apex-treepin-*' -File).Count

    $secondDigest = Invoke-TreePin (@('-Digest') + $digestArgs)
    Assert-Equal 'second unchanged digest exits 0' 0 $secondDigest.ExitCode
    Assert-Equal 'unchanged tree produces byte-identical digests' $firstDigest.Output $secondDigest.Output

    Write-Utf8File (Join-Path $fixture.Root 'tracked.txt') "digest fixture with changed bytes`n"
    $changedDigest = Invoke-TreePin (@('-Digest') + $digestArgs)
    Assert-Equal 'digest after tracked content mutation exits 0' 0 $changedDigest.ExitCode
    Assert-True 'tracked content mutation changes the digest' ($changedDigest.Output -ne $secondDigest.Output)

    # No tree mutation occurs between these calls, so stdout and the persisted pin must agree.
    $equivalentDigest = Invoke-TreePin (@('-Digest') + $digestArgs)
    $pinArgs = @(
        '-Worktree', $fixture.Root,
        '-Label', $fixture.Name,
        '-PinDirectory', $fixture.Pins,
        '-RuntimeExclusionRoot', $fixture.Root
    )
    $equivalentPin = Invoke-TreePin (@('-Pin') + $pinArgs)
    Assert-Equal 'digest/pin equivalence digest exits 0' 0 $equivalentDigest.ExitCode
    Assert-Equal 'digest/pin equivalence pin exits 0' 0 $equivalentPin.ExitCode
    $equivalentPinPath = Get-PinPath $fixture.Root $fixture.Name $fixture.Pins
    $equivalentPinLines = [System.IO.File]::ReadAllLines($equivalentPinPath)
    Assert-Equal 'digest stdout equals the digest stored in the pin' $equivalentDigest.Output $equivalentPinLines[1]

    # Every mode combination other than exactly one must fail with the mode guard diagnostic.
    $exactlyOneMessage = 'Pass exactly one of -Pin, -Verify, or -Digest.'
    $guardArgs = @(
        '-Worktree', $fixture.Root,
        '-Label', 'digest-guards',
        '-PinDirectory', $fixture.Pins,
        '-RuntimeExclusionRoot', $fixture.Root
    )
    $result = Invoke-TreePin (@('-Pin', '-Digest') + $guardArgs)
    Assert-True 'Pin plus Digest throws' ($result.ExitCode -ne 0)
    Assert-True 'Pin plus Digest reports the exactly-one error' ($result.Output -match [regex]::Escape($exactlyOneMessage))
    $result = Invoke-TreePin (@('-Verify', '-Digest') + $guardArgs)
    Assert-True 'Verify plus Digest throws' ($result.ExitCode -ne 0)
    Assert-True 'Verify plus Digest reports the exactly-one error' ($result.Output -match [regex]::Escape($exactlyOneMessage))
    $result = Invoke-TreePin (@('-Pin', '-Verify', '-Digest') + $guardArgs)
    Assert-True 'Pin plus Verify plus Digest throws' ($result.ExitCode -ne 0)
    Assert-True 'Pin plus Verify plus Digest reports the exactly-one error' ($result.Output -match [regex]::Escape($exactlyOneMessage))
    $result = Invoke-TreePin $guardArgs
    Assert-True 'no mode throws' ($result.ExitCode -ne 0)
    Assert-True 'no mode reports the exactly-one error' ($result.Output -match [regex]::Escape($exactlyOneMessage))

    $result = Invoke-TreePin (@('-Digest', '-PinAlso', $rootTwo) + $digestArgs)
    Assert-True 'Digest with non-empty PinAlso throws' ($result.ExitCode -ne 0)
    Assert-True 'Digest with non-empty PinAlso reports the single-tree error' ($result.Output -match [regex]::Escape('Pass no -PinAlso with -Digest.'))

    # Digest and Pin must apply the same runtime exclusions when the fixture is the runtime root.
    $fixture = New-TestFixture 'digest-runtime-exclusion' '.gitignore' "/projects/`n"
    $runtimeDigestArgs = @(
        '-Worktree', $fixture.Root,
        '-PinDirectory', $fixture.Pins,
        '-RuntimeExclusionRoot', $fixture.Root
    )
    $runtimePinArgs = @(
        '-Worktree', $fixture.Root,
        '-Label', $fixture.Name,
        '-PinDirectory', $fixture.Pins,
        '-RuntimeExclusionRoot', $fixture.Root
    )
    $runtimeDigestBefore = Invoke-TreePin (@('-Digest') + $runtimeDigestArgs)
    $runtimePinBefore = Invoke-TreePin (@('-Pin') + $runtimePinArgs)
    Assert-Equal 'runtime-exclusion baseline digest exits 0' 0 $runtimeDigestBefore.ExitCode
    Assert-Equal 'runtime-exclusion baseline pin exits 0' 0 $runtimePinBefore.ExitCode
    $runtimePinPath = Get-PinPath $fixture.Root $fixture.Name $fixture.Pins
    $runtimePinDigestBefore = ([System.IO.File]::ReadAllLines($runtimePinPath))[1]

    Write-Utf8File (Join-Path $fixture.Root 'projects/session.json') "runtime churn`n"
    $runtimeDigestAfter = Invoke-TreePin (@('-Digest') + $runtimeDigestArgs)
    $runtimePinAfter = Invoke-TreePin (@('-Pin') + $runtimePinArgs)
    Assert-Equal 'runtime-exclusion post-churn digest exits 0' 0 $runtimeDigestAfter.ExitCode
    Assert-Equal 'runtime-exclusion post-churn pin exits 0' 0 $runtimePinAfter.ExitCode
    $runtimePinDigestAfter = ([System.IO.File]::ReadAllLines($runtimePinPath))[1]
    Assert-Equal 'excluded runtime churn does not move Digest output' $runtimeDigestBefore.Output $runtimeDigestAfter.Output
    Assert-Equal 'excluded runtime churn does not move the Pin digest' $runtimePinDigestBefore $runtimePinDigestAfter

    # Label remains mandatory for the two artifact-oriented modes.
    $labelArgs = @(
        '-Worktree', $fixture.Root,
        '-PinDirectory', $fixture.Pins,
        '-RuntimeExclusionRoot', $fixture.Root
    )
    $labelMessage = 'Pass -Label with -Pin or -Verify.'
    $result = Invoke-TreePin (@('-Pin') + $labelArgs)
    Assert-True 'Pin without Label throws' ($result.ExitCode -ne 0)
    Assert-True 'Pin without Label reports the label-required error' ($result.Output -match [regex]::Escape($labelMessage))
    $result = Invoke-TreePin (@('-Verify') + $labelArgs)
    Assert-True 'Verify without Label throws' ($result.ExitCode -ne 0)
    Assert-True 'Verify without Label reports the label-required error' ($result.Output -match [regex]::Escape($labelMessage))
} catch {
    $failures.Add("suite error: $($_.Exception.Message)")
    Write-Host "FAIL: suite error: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    [Environment]::SetEnvironmentVariable('APEX_STATE_DIR', $savedApexStateDir, 'Process')
    if ($restoreGitConfigGlobal) {
        if ($null -eq $savedGitConfigGlobal) {
            Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue
        } else {
            $env:GIT_CONFIG_GLOBAL = $savedGitConfigGlobal
        }
    }
    if ((Test-Path -LiteralPath $testRoot) -and
            $testRoot.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host "$($failures.Count) tree-pin test failure(s):" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host ''
Write-Host 'All tree-pin tests passed.' -ForegroundColor Green
exit 0
