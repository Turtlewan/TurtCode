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
    # Frozen bytes for this exact committed fixture and label; the deterministic commit timestamp
    # keeps the real-HEAD fingerprint stable across runs. Regenerated for fail-closed rev-parse.
    # SHA-256 of these fixture bytes: 3e631a4050935e36fbcf9cd7f276481f679e468c64efe466ea51d154370be2b1.
    $committedPinBase64 = 'YmVhNzJkY2IxOTNkOGJkYTlmYTk2ZjM5YTUwZGUxMTFiNjU2NjIzNDM0NDA0MzRjN2U5NWQwOTMxNTRlYjA5NwpIRUFEIDAyOWY0ODJhNzY3ODE1MDdhMzkyOTZiMWRhMmY5ZTZhMjY3OWY4NTA='
    $actualPinBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($singlePin.FullName))
    Assert-Equal 'single-root pin bytes match the committed-HEAD fixture' $committedPinBase64 $actualPinBase64

    $result = Invoke-TreePin (@('-Verify') + $singleArgs)
    Assert-Equal 'clean single root verifies with exit 0' 0 $result.ExitCode
    Assert-True 'single-root verify keeps the legacy confirmation format' ($result.Output -match '^\[tree-pin\] tree unchanged \([0-9a-f]{12}\) -- the verdict is about this tree\.$')
    [System.IO.File]::WriteAllText((Join-Path $singleRoot 'tracked.txt'), "fixture-content-moved`n", [System.Text.UTF8Encoding]::new($false))
    $result = Invoke-TreePin (@('-Verify') + $singleArgs)
    Assert-Equal 'moved single root verifies with exit 69' 69 $result.ExitCode
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
