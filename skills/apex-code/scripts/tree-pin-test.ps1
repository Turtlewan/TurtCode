# Loud-fail coverage for single- and multi-root tree pins.

$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'tree-pin.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("apex-tree-pin-test-$PID-" + [guid]::NewGuid().ToString('N'))
$failures = New-Object System.Collections.Generic.List[string]

function Assert-Equal([string]$Name, $Expected, $Actual) {
    if ($Expected -eq $Actual) {
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
    Assert-True 'v1-format pin requests a re-pin' ($result.Output -match '^pin predates digest scheme v2 — re-pin$')
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
} catch {
    $failures.Add("suite error: $($_.Exception.Message)")
    Write-Host "FAIL: suite error: $($_.Exception.Message)" -ForegroundColor Red
} finally {
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
