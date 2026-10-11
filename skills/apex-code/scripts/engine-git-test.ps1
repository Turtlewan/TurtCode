$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot 'engine-git.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) { throw "ASSERT: $Message (expected '$Expected', got '$Actual')" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    try {
        & $Action
    } catch {
        if ($_.Exception.Message -match $Pattern) { return }
        throw "ASSERT: $Message (unexpected error '$($_.Exception.Message)')"
    }
    throw "ASSERT: $Message (no error was thrown)"
}

function Invoke-TestGit {
    param([string]$Repo, [string[]]$Arguments, [switch]$AllowFailure)
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $Repo @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if (-not $AllowFailure -and $code -ne 0) {
        throw "git $($Arguments -join ' ') failed ($code): $($output -join "`n")"
    }
    [pscustomobject]@{ code = $code; output = $output; text = (($output -join "`n").Trim()) }
}

function Write-TestBytes {
    param([string]$Path, [byte[]]$Bytes)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

function Get-Utf8Bytes {
    param([string]$Text)
    (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
}

function Test-ByteSequence {
    param([byte[]]$Bytes, [byte[]]$Sequence)
    if ($Sequence.Count -eq 0 -or $Bytes.Count -lt $Sequence.Count) { return $false }
    for ($offset = 0; $offset -le ($Bytes.Count - $Sequence.Count); $offset++) {
        $matches = $true
        for ($index = 0; $index -lt $Sequence.Count; $index++) {
            if ($Bytes[$offset + $index] -ne $Sequence[$index]) {
                $matches = $false
                break
            }
        }
        if ($matches) { return $true }
    }
    $false
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('engine-git-test-' + [Guid]::NewGuid().ToString('N'))
$repo = Join-Path $testRoot 'repo'
$worktreeRoot = Join-Path $testRoot 'worktrees'
$stateDirectory = Join-Path $testRoot 'state'
$outside = Join-Path $testRoot 'outside'
[void][IO.Directory]::CreateDirectory($repo)
[void][IO.Directory]::CreateDirectory($outside)
$oldState = $env:APEX_STATE_DIR
$oldGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
$oldGitConfigNoSystem = $env:GIT_CONFIG_NOSYSTEM
$isolatedGitConfig = Join-Path $testRoot 'empty-gitconfig'
[IO.File]::WriteAllBytes($isolatedGitConfig, [byte[]]@())
$env:GIT_CONFIG_GLOBAL = $isolatedGitConfig
$env:GIT_CONFIG_NOSYSTEM = '1'
$env:APEX_STATE_DIR = Join-Path $testRoot 'apex-state'

try {
    function Test-DotSourceStrictIsolation {
        Set-StrictMode -Off
        . (Join-Path $PSScriptRoot 'engine-git.ps1')
        try {
            $null = $undefinedAfterDotSource
            return $true
        } catch {
            return $false
        }
    }
    Assert-True (Test-DotSourceStrictIsolation) 'dot-sourcing engine-git does not change caller strict mode'
    Write-Output 'ok - dot-source strict-mode isolation'

    [void](Invoke-TestGit $repo @('init', '-b', 'main'))
    [void](Invoke-TestGit $repo @('config', 'user.name', 'Engine Test'))
    [void](Invoke-TestGit $repo @('config', 'user.email', 'engine@example.invalid'))
    [void](Invoke-TestGit $repo @('config', 'core.autocrlf', 'true'))
    [IO.File]::WriteAllText((Join-Path $repo '.gitignore'), "*`n", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $repo '.gitattributes'), "*.txt text`n", (New-Object Text.UTF8Encoding($false)))
    $baseModifyBytes = Get-Utf8Bytes "base modify`n"
    $baseDeleteBytes = [byte[]](0, 1, 2, 13, 10, 255)
    $binaryPath = 'modify' + [char]0x2014 + 'crlf.bin'
    $baseBinaryBytes = [byte[]](0, 65, 13, 10, 66, 13, 10, 255)
    $textCrlfPath = 'modify-crlf-utf8.dat'
    $baseTextCrlfBytes = [byte[]](0x61, 0xe2, 0x80, 0x94, 0x62, 13, 10, 0x63, 13, 10)
    Write-TestBytes (Join-Path $repo 'modify.txt') $baseModifyBytes
    Write-TestBytes (Join-Path $repo 'delete.bin') $baseDeleteBytes
    Write-TestBytes (Join-Path $repo $binaryPath) $baseBinaryBytes
    Write-TestBytes (Join-Path $repo $textCrlfPath) $baseTextCrlfBytes
    [void](Invoke-TestGit $repo @('-c', 'core.autocrlf=false', 'add', '-f', '--', '.gitignore', '.gitattributes', 'modify.txt', 'delete.bin', $binaryPath, $textCrlfPath))
    [void](Invoke-TestGit $repo @('commit', '-m', 'fixture base'))
    $baseSha = (Invoke-TestGit $repo @('rev-parse', 'HEAD')).text
    Assert-Equal "$textCrlfPath`: text: unspecified" (Invoke-TestGit $repo @('check-attr', 'text', '--', $textCrlfPath)).text 'CRLF UTF-8 fixture has no text attribute'

    $spec = [pscustomobject]@{ name = 'git-case'; run_id = '0123456789abcdef0123456789abcdef' }
    Assert-Throws { Get-EngineIdentity ([pscustomobject]@{ name = 'Git-case'; run_id = $spec.run_id }) } 'Invalid Engine spec name' 'spec name grammar is case-sensitive'
    Assert-Throws { Get-EngineIdentity ([pscustomobject]@{ name = $spec.name; run_id = '01234567ABCDEF89' }) } 'Invalid Engine run_id' 'run id grammar is case-sensitive'
    Write-Output 'ok - case-sensitive Engine identity'
    $integration = New-EngineIntegration -Repo $repo -Spec $spec -BaseSha $baseSha -WorktreeRoot $worktreeRoot
    $task = New-EngineTaskWorktree -Repo $repo -Spec $spec -TaskId '2' -Attempt 1 -IntegrationWorktree $integration.worktree -WorktreeRoot $worktreeRoot
    [void](Invoke-TestGit $repo @('config', 'core.autocrlf', 'false'))
    Write-TestBytes (Join-Path $integration.worktree '.gitignore') (Get-Utf8Bytes "*`n")
    Write-TestBytes (Join-Path $integration.worktree '.gitattributes') (Get-Utf8Bytes "*.txt text`n")
    Assert-Equal 'codex/git-case-01234567-integration' $integration.branch 'integration branch naming'
    Assert-Equal 'codex/git-case-01234567-2-a1' $task.branch 'task branch naming'
    Assert-Equal $baseSha $task.base_sha 'task starts at integration tip'

    $files = @(
        [pscustomobject]@{ path = 'created.txt'; op = 'create' },
        [pscustomobject]@{ path = 'modify.txt'; op = 'modify' },
        [pscustomobject]@{ path = 'delete.bin'; op = 'delete' },
        [pscustomobject]@{ path = $binaryPath; op = 'modify' },
        [pscustomobject]@{ path = $textCrlfPath; op = 'modify' }
    )
    $createdBytes = Get-Utf8Bytes "created ignored file`r`n"
    $modifiedBytes = Get-Utf8Bytes "task changed line`r`nsecond line`r`n"
    $modifiedBinaryBytes = [byte[]](0, 90, 13, 10, 89, 13, 10, 254)
    $modifiedTextCrlfBytes = [byte[]](0x61, 0xe2, 0x80, 0x94, 0x62, 13, 10, 0x64, 13, 10)
    Assert-True (($baseTextCrlfBytes -notcontains 0) -and ($modifiedTextCrlfBytes -notcontains 0)) 'CRLF UTF-8 text fixture contains no NUL bytes'
    Write-TestBytes (Join-Path $task.worktree 'created.txt') $createdBytes
    Write-TestBytes (Join-Path $task.worktree 'modify.txt') $modifiedBytes
    Write-TestBytes (Join-Path $task.worktree $binaryPath) $modifiedBinaryBytes
    Write-TestBytes (Join-Path $task.worktree $textCrlfPath) $modifiedTextCrlfBytes
    [IO.File]::Delete((Join-Path $task.worktree 'delete.bin'))

    $badFiles = @(
        [pscustomobject]@{ path = 'modify.txt'; op = 'create' },
        [pscustomobject]@{ path = 'missing.txt'; op = 'modify' },
        [pscustomobject]@{ path = 'missing-delete.txt'; op = 'delete' }
    )
    $badCopy = Copy-EngineTaskFiles -TargetWorktree $repo -IntegrationWorktree $integration.worktree -TaskWorktree $task.worktree -WaveBaseSha $baseSha -Files $badFiles
    Assert-True (-not $badCopy.ok) 'operation preconditions reject invalid base presence'
    Assert-Equal 3 $badCopy.failures.Count 'all operation precondition failures returned'
    Write-Output 'ok - modify/delete preconditions'

    $copy = Copy-EngineTaskFiles -TargetWorktree $repo -IntegrationWorktree $integration.worktree -TaskWorktree $task.worktree -WaveBaseSha $baseSha -Files $files
    Assert-True $copy.ok ($copy.failures | ConvertTo-Json -Compress)
    Assert-Equal 5 $copy.hashes.Count 'hash returned for every copied operation'
    Assert-Equal $null $copy.hashes[2].hash 'delete hash is null'
    Assert-Equal (Get-EngineRawSha256 (Join-Path $task.worktree 'created.txt')) $copy.hashes[0].hash 'create raw hash'
    Assert-Equal (Get-EngineRawSha256 (Join-Path $task.worktree 'modify.txt')) $copy.hashes[1].hash 'modify raw hash'
    Assert-Equal $copy.hashes[0].hash (Get-EngineRawSha256 (Join-Path $integration.worktree 'created.txt')) 'created bytes exactly copied'
    Assert-Equal $copy.hashes[1].hash (Get-EngineRawSha256 (Join-Path $integration.worktree 'modify.txt')) 'modified bytes exactly copied'
    Assert-Equal $copy.hashes[3].hash (Get-EngineRawSha256 (Join-Path $integration.worktree $binaryPath)) 'non-ASCII binary path bytes exactly copied'
    Assert-Equal $copy.hashes[4].hash (Get-EngineRawSha256 (Join-Path $integration.worktree $textCrlfPath)) 'CRLF UTF-8 text bytes exactly copied'
    Write-Output 'ok - raw-byte worktree hashes'

    $restore = Restore-EngineWave -TargetWorktree $repo -IntegrationWorktree $integration.worktree -WaveBaseSha $baseSha -Files $files
    Assert-True $restore.ok ($restore.failures | ConvertTo-Json -Compress)
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $integration.worktree 'created.txt'))) 'restore removes base-absent create'
    Assert-Equal (Get-EngineBlobHash $integration.worktree $baseSha 'modify.txt') (Get-EngineFilteredWorkingHash $integration.worktree 'modify.txt') 'restore filtered modify identity'
    Assert-True (Test-Path -LiteralPath (Join-Path $integration.worktree 'delete.bin')) 'restore recreates delete'
    $clean = Invoke-TestGit $integration.worktree @('diff', '--quiet') -AllowFailure
    Assert-Equal 0 $clean.code 'integration is clean after restore'
    Write-Output 'ok - wave restore'

    $junction = Join-Path $task.worktree 'linked'
    Write-TestBytes (Join-Path $outside 'payload.txt') (Get-Utf8Bytes 'outside')
    [void](New-Item -ItemType Junction -Path $junction -Target $outside)
    $unsafe = Copy-EngineTaskFiles -TargetWorktree $repo -IntegrationWorktree $integration.worktree -TaskWorktree $task.worktree -WaveBaseSha $baseSha -Files @([pscustomobject]@{ path = 'linked/payload.txt'; op = 'create' })
    Assert-True (-not $unsafe.ok) 'reparse ancestor is rejected'
    Assert-True ($unsafe.failures[0].reason -match 'reparse') 'reparse refusal is diagnosed'
    [IO.Directory]::Delete($junction)
    Write-Output 'ok - regular/reparse path'

    $copy = Copy-EngineTaskFiles -TargetWorktree $repo -IntegrationWorktree $integration.worktree -TaskWorktree $task.worktree -WaveBaseSha $baseSha -Files $files
    Assert-True $copy.ok 'second copy succeeds'
    $stage = Stage-EngineWave -TargetWorktree $repo -IntegrationWorktree $integration.worktree -Files $files
    Assert-True $stage.ok ($stage.failures | ConvertTo-Json -Compress)
    $allowedPaths = @($files | ForEach-Object { $_.path })
    Write-TestBytes (Join-Path $integration.worktree 'off-manifest.txt') (Get-Utf8Bytes "not in wave`n")
    [void](Invoke-TestGit $integration.worktree @('add', '-f', '--', 'off-manifest.txt'))
    Assert-Throws { Commit-EngineWave -IntegrationWorktree $integration.worktree -Message 'must reject extra path' -BaseSha $baseSha -AllowedPaths $allowedPaths } 'integration index contains paths outside wave manifest:.*off-manifest\.txt' 'off-manifest staged path is rejected'
    Assert-Equal $baseSha (Invoke-TestGit $integration.worktree @('rev-parse', 'HEAD')).text 'off-manifest refusal writes no commit'
    [void](Invoke-TestGit $integration.worktree @('rm', '--cached', '--', 'off-manifest.txt'))
    [IO.File]::Delete((Join-Path $integration.worktree 'off-manifest.txt'))
    $missingOnlyAllowedPaths = @($allowedPaths) + @('not-staged.txt')
    Assert-Throws { Commit-EngineWave -IntegrationWorktree $integration.worktree -Message 'must reject missing path' -BaseSha $baseSha -AllowedPaths $missingOnlyAllowedPaths } '^(?!.*outside wave manifest)integration index is missing wave-manifest paths:.*not-staged\.txt' 'missing-only staged paths receive their own diagnosis'
    Assert-Equal $baseSha (Invoke-TestGit $integration.worktree @('rev-parse', 'HEAD')).text 'missing-only refusal writes no commit'
    $caseVariantAllowedPaths = @($allowedPaths)
    $caseVariantAllowedPaths[0] = 'Created.txt'
    Assert-Throws { Commit-EngineWave -IntegrationWorktree $integration.worktree -Message 'must compare paths case-sensitively' -BaseSha $baseSha -AllowedPaths $caseVariantAllowedPaths } 'integration index contains paths outside wave manifest:.*created\.txt' 'allowed-path set comparison is case-sensitive'
    Assert-Equal $baseSha (Invoke-TestGit $integration.worktree @('rev-parse', 'HEAD')).text 'case mismatch refusal writes no commit'
    $wrongBaseSha = '0000000000000000000000000000000000000000'
    Assert-Throws { Commit-EngineWave -IntegrationWorktree $integration.worktree -Message 'must reject moved head' -BaseSha $wrongBaseSha -AllowedPaths $allowedPaths } 'Integration HEAD does not match wave base' 'HEAD mismatch is rejected'
    Assert-Equal $baseSha (Invoke-TestGit $integration.worktree @('rev-parse', 'HEAD')).text 'HEAD mismatch refusal writes no commit'
    Write-Output 'ok - off-manifest index and HEAD mismatch refusal'
    $preCommitHook = Join-Path $repo '.git\hooks\pre-commit'
    Write-TestBytes $preCommitHook (Get-Utf8Bytes "#!/bin/sh`nexit 1`n")
    $commit = Commit-EngineWave -IntegrationWorktree $integration.worktree -Message 'integrate test wave' -BaseSha $baseSha -AllowedPaths $allowedPaths
    [IO.File]::Delete($preCommitHook)
    $tip = $commit.head_sha
    $textDiffStat = (Invoke-TestGit $integration.worktree @('diff', '--numstat', $baseSha, $tip, '--', $textCrlfPath)).text
    Assert-True ($textDiffStat -match '^[0-9]+\s+[0-9]+\s+modify-crlf-utf8\.dat$') 'unattributed NUL-free CRLF UTF-8 fixture diffs as text'
    $committedTree = (Invoke-TestGit $integration.worktree @('rev-parse', 'HEAD^{tree}')).text
    Assert-Equal $committedTree (Invoke-TestGit $integration.worktree @('write-tree')).text 'commit tree matches verified index tree'
    $createdBlob = Get-EngineBlobHash $integration.worktree $tip 'created.txt'
    $modifiedBlob = Get-EngineBlobHash $integration.worktree $tip 'modify.txt'
    Assert-Equal $createdBlob (Get-EngineFilteredWorkingHash $integration.worktree 'created.txt') 'ignored create staged with filtered identity'
    Assert-Equal $modifiedBlob (Get-EngineFilteredWorkingHash $integration.worktree 'modify.txt') 'CRLF working file hashes to committed LF blob'
    $modifyRaw = [IO.File]::ReadAllBytes((Join-Path $integration.worktree 'modify.txt'))
    Assert-True (($modifyRaw -contains 13) -and ($modifyRaw -contains 10)) 'integration working file retains CRLF bytes'
    Assert-Equal (Get-EngineRawSha256 (Join-Path $task.worktree $binaryPath)) (Get-EngineRawSha256 (Join-Path $integration.worktree $binaryPath)) 'CRLF binary blob bytes survive integration commit'
    Assert-Equal (Get-EngineRawSha256 (Join-Path $task.worktree $textCrlfPath)) (Get-EngineRawSha256 (Join-Path $integration.worktree $textCrlfPath)) 'unattributed CRLF UTF-8 text blob bytes survive integration commit'
    Write-Output 'ok - blanket-ignore create'
    Write-Output 'ok - filtered blob identity with CRLF conversion'
    Write-Output 'ok - exact allowed-path set commit'
    Write-Output 'ok - verified-index commit binding and hook bypass'

    $taskHead = (Invoke-TestGit $task.worktree @('rev-parse', 'HEAD')).text
    Assert-Equal $baseSha $taskHead 'task HEAD was never committed'
    $taskIndex = Invoke-TestGit $task.worktree @('diff', '--cached', '--quiet') -AllowFailure
    Assert-Equal 0 $taskIndex.code 'task index was never staged'
    $mainHead = (Invoke-TestGit $repo @('rev-parse', 'HEAD')).text
    Assert-Equal $baseSha $mainHead 'main HEAD was not committed by integration operations'
    Write-Output 'ok - no-task-commit'

    $treeMismatchRepo = Join-Path $testRoot 'tree-mismatch-repo'
    [void][IO.Directory]::CreateDirectory($treeMismatchRepo)
    [void](Invoke-TestGit $treeMismatchRepo @('init', '-b', 'codex/tree-binding-integration'))
    [void](Invoke-TestGit $treeMismatchRepo @('config', 'user.name', 'Engine Test'))
    [void](Invoke-TestGit $treeMismatchRepo @('config', 'user.email', 'engine@example.invalid'))
    Write-TestBytes (Join-Path $treeMismatchRepo 'verified.txt') (Get-Utf8Bytes "base`n")
    [void](Invoke-TestGit $treeMismatchRepo @('add', '--', 'verified.txt'))
    [void](Invoke-TestGit $treeMismatchRepo @('commit', '-m', 'base'))
    $treeMismatchBaseSha = (Invoke-TestGit $treeMismatchRepo @('rev-parse', 'HEAD')).text
    Write-TestBytes (Join-Path $treeMismatchRepo 'verified.txt') (Get-Utf8Bytes "verified`n")
    [void](Invoke-TestGit $treeMismatchRepo @('add', '--', 'verified.txt'))
    $postCommitHook = Join-Path $treeMismatchRepo '.git\hooks\post-commit'
    $postCommitHookText = @'
#!/bin/sh
printf 'hook mutation\n' > hook-mutation.txt
git add -- hook-mutation.txt || exit 1
tree=$(git write-tree) || exit 1
parent=$(git rev-parse HEAD) || exit 1
commit=$(printf 'hook-mutated\n' | git commit-tree "$tree" -p "$parent") || exit 1
git update-ref HEAD "$commit"
'@
    Write-TestBytes $postCommitHook (Get-Utf8Bytes $postCommitHookText)
    Assert-Throws { Commit-EngineWave -IntegrationWorktree $treeMismatchRepo -Message 'must detect hook mutation' -BaseSha $treeMismatchBaseSha -AllowedPaths @('verified.txt') } 'does not match verified index tree' 'post-commit tree mutation is rejected'
    Write-Output 'ok - post-commit tree mismatch refusal'

    $handoffPreconditions = @(
        [pscustomobject]@{ path = 'modify.txt'; op = 'create' },
        [pscustomobject]@{ path = 'absent-at-base.bin'; op = 'modify' },
        [pscustomobject]@{ path = 'modify.txt'; op = 'delete' },
        [pscustomobject]@{ path = 'delete.bin'; op = 'modify' }
    )
    foreach ($invalidFile in $handoffPreconditions) {
        $preconditionResult = Invoke-EngineHandoff -Repo $repo -IntegrationWorktree $integration.worktree -BaseSha $baseSha -ExpectedTip $tip -Files @($invalidFile) -JournaledPaths @() -OnFileJournaled { param($path) throw "unexpected journal callback for $path" } -StateDirectory $stateDirectory
        Assert-True (-not $preconditionResult.ok) "handoff precondition returns ok=false for $($invalidFile.op) $($invalidFile.path)"
        Assert-Equal $invalidFile.path $preconditionResult.mismatch_path 'handoff precondition pins mismatch_path'
        Assert-True (Test-Path -LiteralPath $preconditionResult.recovery_patch) 'handoff precondition saves a recovery patch'
    }
    Write-Output 'ok - handoff base/tip precondition shape'

    Write-TestBytes (Join-Path $repo 'modify.txt') (Get-Utf8Bytes "foreign writer`r`n")
    $zeroJournal = New-Object System.Collections.ArrayList
    $zeroResult = Invoke-EngineHandoff -Repo $repo -IntegrationWorktree $integration.worktree -BaseSha $baseSha -ExpectedTip $tip -Files $files -JournaledPaths @() -OnFileJournaled { param($path) [void]$zeroJournal.Add($path) } -StateDirectory $stateDirectory
    Assert-True (-not $zeroResult.ok) 'pre-state mismatch refuses hand-off'
    Assert-Equal 'modify.txt' $zeroResult.mismatch_path 'mismatch path identifies foreign writer'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'created.txt'))) 'no earlier pending create was written'
    Assert-True (Test-Path -LiteralPath (Join-Path $repo 'delete.bin')) 'no later delete was written'
    Assert-Equal 0 $zeroJournal.Count 'zero-write refusal journals nothing'
    Assert-True (Test-Path -LiteralPath $zeroResult.recovery_patch) 'zero-write refusal creates recovery patch'
    $patchBytes = [IO.File]::ReadAllBytes($zeroResult.recovery_patch)
    $utf8EmDashCrlf = [byte[]](0x61, 0xe2, 0x80, 0x94, 0x62, 13, 10)
    Assert-True (Test-ByteSequence $patchBytes $utf8EmDashCrlf) 'recovery patch preserves exact UTF-8 em-dash and CRLF bytes for text diff'
    $rebuiltPatchPath = Join-Path $testRoot 'pipeline-rebuilt.patch'
    $patchUtf8 = New-Object Text.UTF8Encoding($false, $true)
    $rebuiltPatchBytes = $patchUtf8.GetBytes(([IO.File]::ReadAllLines($zeroResult.recovery_patch, $patchUtf8) -join "`n"))
    Write-TestBytes $rebuiltPatchPath $rebuiltPatchBytes
    Assert-True (-not (Test-ByteSequence $rebuiltPatchBytes $utf8EmDashCrlf)) 'line-array LF rebuild loses the CR bytes covered by this regression'
    Assert-True ((Get-EngineRawSha256 $zeroResult.recovery_patch) -ne (Get-EngineRawSha256 $rebuiltPatchPath)) 'line-array LF rebuild differs from the byte-faithful recovery patch'
    $patchTarget = Join-Path $testRoot 'patch-target'
    [void](Invoke-TestGit $testRoot @('-c', 'core.autocrlf=true', 'clone', '--no-hardlinks', '--branch', 'main', $repo, $patchTarget))
    [void](Invoke-TestGit $patchTarget @('config', 'core.autocrlf', 'true'))
    $patchCheck = Invoke-TestGit $patchTarget @('apply', '--check', '--', $zeroResult.recovery_patch) -AllowFailure
    Assert-Equal 0 $patchCheck.code 'recovery patch passes git apply --check against fresh main pre-state'
    [void](Invoke-TestGit $patchTarget @('apply', '--', $zeroResult.recovery_patch))
    foreach ($path in @('created.txt', 'modify.txt', $binaryPath, $textCrlfPath)) {
        Assert-Equal (Get-EngineRawSha256 (Join-Path $integration.worktree $path)) (Get-EngineRawSha256 (Join-Path $patchTarget $path)) "applied recovery bytes match integration for $path"
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $patchTarget 'delete.bin'))) 'applied recovery patch reproduces deletion'
    Write-Output 'ok - byte-faithful binary recovery patch'
    Write-Output 'ok - all-path pre-state zero-write refusal'

    Write-TestBytes (Join-Path $repo 'modify.txt') $baseModifyBytes
    $debugSafety = Get-EnginePathSafetyFailure @($repo, $integration.worktree) $repo @($baseSha, $tip) 'created.txt'
    Assert-Equal $null $debugSafety 'created handoff safety'
    Assert-Equal $null (Get-EngineBlobHash $repo $baseSha 'created.txt') 'created absent at base before crash'
    Assert-Equal $null (Get-EngineFilteredWorkingHash $repo 'created.txt') 'created absent in main before crash'
    Assert-Equal $createdBlob (Get-EngineBlobHash $integration.worktree $tip 'created.txt') 'created present at tip before crash'
    Assert-True (Test-EngineWorkingIdentity $repo 'created.txt' $null) 'null expected identity matches absent create'
    $crashSeen = $false
    $crashResult = $null
    try {
        $crashResult = Invoke-EngineHandoff -Repo $repo -IntegrationWorktree $integration.worktree -BaseSha $baseSha -ExpectedTip $tip -Files $files -JournaledPaths @() -OnFileJournaled { param($path) throw "simulated journal crash after $path" } -StateDirectory $stateDirectory
    } catch {
        $crashSeen = $true
    }
    $crashDebug = [pscustomobject]@{
        result = $crashResult
        exists = (Test-Path -LiteralPath (Join-Path $repo 'created.txt'))
        working_hash = (Get-EngineFilteredWorkingHash $repo 'created.txt')
        tip_hash = $createdBlob
    }
    Assert-True $crashSeen ("journal callback crash propagates; debug=" + ($crashDebug | ConvertTo-Json -Depth 5 -Compress))
    Assert-Equal $copy.hashes[0].hash (Get-EngineRawSha256 (Join-Path $repo 'created.txt')) 'file write precedes durable journal callback'
    $resumeJournal = New-Object System.Collections.ArrayList
    $resumed = Invoke-EngineHandoff -Repo $repo -IntegrationWorktree $integration.worktree -BaseSha $baseSha -ExpectedTip $tip -Files $files -JournaledPaths @() -OnFileJournaled { param($path) [void]$resumeJournal.Add($path) } -StateDirectory $stateDirectory
    Assert-True $resumed.ok 'write-before-journal hand-off resumes'
    Assert-Equal 5 $resumeJournal.Count 'resume journals already-applied path and remaining writes'
    Assert-Equal $modifiedBlob (Get-EngineFilteredWorkingHash $repo 'modify.txt') 'resumed modify matches tip'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'delete.bin'))) 'resumed delete matches tip'
    Write-Output 'ok - write-before-journal crash resume'

    if (Test-Path -LiteralPath (Join-Path $repo 'created.txt')) { [IO.File]::Delete((Join-Path $repo 'created.txt')) }
    Write-TestBytes (Join-Path $repo 'modify.txt') $baseModifyBytes
    Write-TestBytes (Join-Path $repo 'delete.bin') $baseDeleteBytes
    $guardCallbacks = New-Object System.Collections.ArrayList
    $guarded = Invoke-EngineHandoff -Repo $repo -IntegrationWorktree $integration.worktree -BaseSha $baseSha -ExpectedTip $tip -Files $files -JournaledPaths @() -OnFileJournaled {
        param($path)
        [void]$guardCallbacks.Add($path)
        if ($path -eq 'created.txt') { Write-TestBytes (Join-Path $repo 'modify.txt') (Get-Utf8Bytes "concurrent mutation`r`n") }
    } -StateDirectory $stateDirectory
    Assert-True (-not $guarded.ok) 'concurrent writer is refused'
    Assert-Equal 'modify.txt' $guarded.mismatch_path 'per-path recheck catches next path mutation'
    Assert-True (Test-Path -LiteralPath $guarded.recovery_patch) 'concurrent mismatch creates recovery patch'
    Assert-True (Test-Path -LiteralPath (Join-Path $repo 'delete.bin')) 'handoff stops on first concurrent mismatch'
    Write-Output 'ok - concurrent-writer guard'

    Write-TestBytes (Join-Path $repo 'modify.txt') $baseModifyBytes
    $finishJournal = New-Object System.Collections.ArrayList
    $finished = Invoke-EngineHandoff -Repo $repo -IntegrationWorktree $integration.worktree -BaseSha $baseSha -ExpectedTip $tip -Files $files -JournaledPaths @('created.txt') -OnFileJournaled { param($path) [void]$finishJournal.Add($path) } -StateDirectory $stateDirectory
    Assert-True $finished.ok 'handoff completes after guarded retry'
    Assert-Equal 5 $finished.completed.Count 'completed includes prior journal entries'
    $nullJournal = New-Object System.Collections.ArrayList
    $nullJournalResult = Invoke-EngineHandoff -Repo $repo -IntegrationWorktree $integration.worktree -BaseSha $baseSha -ExpectedTip $tip -Files $files -JournaledPaths $null -OnFileJournaled { param($path) [void]$nullJournal.Add($path) } -StateDirectory $stateDirectory
    Assert-True $nullJournalResult.ok 'null JournaledPaths is normalized to an empty array'
    Assert-Equal 5 $nullJournal.Count 'null JournaledPaths visits every already-applied path'
    Write-Output 'ok - null handoff journal normalization'
    Assert-Equal $tip (Invoke-TestGit $integration.worktree @('rev-parse', 'HEAD')).text 'integration live HEAD equals expected hand-off tip'
    Write-Output 'ok - hand-off expected tip'

    $proofBeforeCloseout = Test-EngineTeardownProof -Repo $repo -Spec $spec -Files $files -IntegrationTip $tip
    Assert-True (-not $proofBeforeCloseout.ok) 'proof requires main HEAD as well as working files'
    [void](Invoke-TestGit $repo @('update-ref', 'refs/heads/main', $tip, $baseSha))
    $proof = Test-EngineTeardownProof -Repo $repo -Spec $spec -Files $files -IntegrationTip $tip
    Assert-True $proof.ok ($proof.failures | ConvertTo-Json -Compress)
    Write-Output 'ok - proof'

    $movedPath = 'moved-tip.txt'
    Write-TestBytes (Join-Path $integration.worktree $movedPath) (Get-Utf8Bytes "unreviewed integration change`n")
    [void](Invoke-TestGit $integration.worktree @('add', '-f', '--', $movedPath))
    [void](Invoke-TestGit $integration.worktree @('commit', '-m', 'move integration tip'))
    $movedTip = (Invoke-TestGit $integration.worktree @('rev-parse', 'HEAD')).text
    Assert-True ($movedTip -cne $tip) 'extra integration commit moves HEAD beyond reviewed tip'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo $movedPath))) 'moved-tip fixture is absent from main before hand-off'
    $movedMessage = "integration HEAD $movedTip differs from reviewed tip $tip; hand-off refused"
    $snapshotState = {
        $entries = @(Get-ChildItem -LiteralPath $stateDirectory -Recurse -Force -File | ForEach-Object {
            [pscustomobject]@{
                name = $_.FullName.Substring($stateDirectory.Length + 1)
                bytes = $_.Length
            }
        } | Sort-Object -Property name)
        ConvertTo-Json -InputObject $entries -Compress
    }
    $mainHeadBeforeMovedRefusal = (Invoke-TestGit $repo @('rev-parse', 'HEAD')).text
    $stateBeforeMovedRefusal = & $snapshotState
    Assert-Throws {
        Invoke-EngineHandoff -Repo $repo -IntegrationWorktree $integration.worktree -BaseSha $tip -ExpectedTip $tip -Files @([pscustomobject]@{ path = $movedPath; op = 'create' }) -JournaledPaths @() -OnFileJournaled { param($path) throw "unexpected journal callback for $path" } -StateDirectory $stateDirectory
    } ([regex]::Escape($movedMessage)) 'moved integration tip is refused with the pinned diagnosis'
    $mainHeadAfterMovedRefusal = (Invoke-TestGit $repo @('rev-parse', 'HEAD')).text
    $stateAfterMovedRefusal = & $snapshotState
    Assert-Equal $mainHeadBeforeMovedRefusal $mainHeadAfterMovedRefusal 'moved-tip refusal preserves main HEAD'
    Assert-Equal $stateBeforeMovedRefusal $stateAfterMovedRefusal 'moved-tip refusal preserves sorted state names and byte sizes'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo $movedPath))) 'moved-tip refusal writes no hand-off file to main'
    Write-Output 'ok - hand-off moved tip refuses'

    $emptyRemoved = New-Object System.Collections.ArrayList
    $emptyTeardown = Remove-EngineRunWorktrees -Repo $repo -Spec $spec -Branches @() -Worktrees @() -OnItemRemoved { param($item) [void]$emptyRemoved.Add($item) }
    Assert-True $emptyTeardown.ok 'empty teardown collections succeed'
    Assert-Equal 0 $emptyTeardown.failures.Count 'empty teardown returns no failures'
    Assert-Equal 0 $emptyRemoved.Count 'empty teardown invokes no callbacks'
    Write-Output 'ok - empty teardown collections'

    [void](Invoke-TestGit $repo @('worktree', 'remove', '--force', '--', $task.worktree))
    $removed = New-Object System.Collections.ArrayList
    $teardown = Remove-EngineRunWorktrees -Repo $repo -Spec $spec -Branches @($task.branch, $integration.branch) -Worktrees @($task.worktree, $integration.worktree) -OnItemRemoved {
        param($item)
        if ($args.Count -ne 0 -or $item -isnot [pscustomobject] -or $item.kind -notin @('worktree', 'branch') -or [string]::IsNullOrWhiteSpace([string]$item.value)) {
            throw 'OnItemRemoved did not receive exactly one pinned item object.'
        }
        [void]$removed.Add($item)
    }
    Assert-True $teardown.ok ($teardown.failures | ConvertTo-Json -Compress)
    Assert-Equal 4 $removed.Count 'callback runs for absent/present worktrees and branches'
    Assert-Equal 2 @($removed | Where-Object { $_.kind -eq 'worktree' }).Count 'callback reports worktree items'
    Assert-Equal 2 @($removed | Where-Object { $_.kind -eq 'branch' }).Count 'callback reports branch items'
    $removedAgain = New-Object System.Collections.ArrayList
    $teardownAgain = Remove-EngineRunWorktrees -Repo $repo -Spec $spec -Branches @($task.branch, $integration.branch) -Worktrees @($task.worktree, $integration.worktree) -OnItemRemoved { param($item) [void]$removedAgain.Add($item) }
    Assert-True $teardownAgain.ok 'teardown is idempotent'
    Assert-Equal 4 $removedAgain.Count 'idempotent callbacks include already absent items'
    Write-Output 'ok - idempotent teardown'

    # Main's ancestor file must not veto a path that is safe in the selected target.
    Write-TestBytes (Join-Path $repo 'src/settings') (Get-Utf8Bytes "main settings`n")
    [void](Invoke-TestGit $repo @('add', '-f', '--', 'src/settings'))
    [void](Invoke-TestGit $repo @('commit', '-m', 'main ancestor fixture'))
    $target = Join-Path $testRoot 'linked-target'
    [void](Invoke-TestGit $repo @('worktree', 'add', '-b', 'linked-target', $target))
    [void](Invoke-TestGit $target @('rm', '--', 'src/settings'))
    [void](Invoke-TestGit $target @('commit', '-m', 'delete target ancestor'))
    $targetBase = (Invoke-TestGit $target @('rev-parse', 'HEAD')).text
    $targetSpec = [pscustomobject]@{ name = 'target-case'; run_id = 'abcdef0123456789abcdef0123456789' }
    $targetIntegration = New-EngineIntegration -Repo $target -Spec $targetSpec -BaseSha $targetBase -WorktreeRoot $worktreeRoot
    $targetTask = New-EngineTaskWorktree -Repo $target -Spec $targetSpec -TaskId '1' -Attempt 1 -IntegrationWorktree $targetIntegration.worktree -WorktreeRoot $worktreeRoot
    $targetFiles = @([pscustomobject]@{ path = 'src/settings/item.py'; op = 'create' })
    Write-TestBytes (Join-Path $targetTask.worktree 'src/settings/item.py') (Get-Utf8Bytes "created in target`n")
    $targetCopy = Copy-EngineTaskFiles -TargetWorktree $target -IntegrationWorktree $targetIntegration.worktree -TaskWorktree $targetTask.worktree -WaveBaseSha $targetBase -Files $targetFiles
    Assert-True $targetCopy.ok ($targetCopy.failures | ConvertTo-Json -Compress)
    $targetStage = Stage-EngineWave -TargetWorktree $target -IntegrationWorktree $targetIntegration.worktree -Files $targetFiles
    Assert-True $targetStage.ok ($targetStage.failures | ConvertTo-Json -Compress)
    Assert-True ([IO.File]::Exists((Join-Path $repo 'src/settings'))) 'main ancestor stays a file'
    Write-Output 'ok - selected target permits ancestor deleted only in linked branch'

    # Only the target has this obstruction; neither task nor integration may bypass it.
    Write-TestBytes (Join-Path $target 'target-only') (Get-Utf8Bytes 'obstruction')
    $blockedFiles = @([pscustomobject]@{ path = 'target-only/item.py'; op = 'create' })
    Write-TestBytes (Join-Path $targetTask.worktree 'target-only/item.py') (Get-Utf8Bytes 'task payload')
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $repo 'target-only'))) 'main has no target-only obstruction'
    $blockedCopy = Copy-EngineTaskFiles -TargetWorktree $target -IntegrationWorktree $targetIntegration.worktree -TaskWorktree $targetTask.worktree -WaveBaseSha $targetBase -Files $blockedFiles
    Assert-True (-not $blockedCopy.ok) 'copy refuses target-only non-directory ancestor'
    Assert-True ($blockedCopy.failures[0].reason -match 'non-directory ancestor' -and $blockedCopy.failures[0].reason.StartsWith($target)) 'copy identifies target obstruction'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $targetIntegration.worktree 'target-only'))) 'refused copy writes no integration path'
    Write-TestBytes (Join-Path $targetIntegration.worktree 'target-only/item.py') (Get-Utf8Bytes 'integration payload')
    $blockedStage = Stage-EngineWave -TargetWorktree $target -IntegrationWorktree $targetIntegration.worktree -Files $blockedFiles
    Assert-True (-not $blockedStage.ok) 'stage refuses target-only non-directory ancestor'
    Assert-True ($blockedStage.failures[0].reason -match 'non-directory ancestor' -and $blockedStage.failures[0].reason.StartsWith($target)) 'stage identifies target obstruction'
    Assert-Equal 0 (Invoke-TestGit $targetIntegration.worktree @('diff', '--cached', '--quiet', '--', 'target-only/item.py') -AllowFailure).code 'refused stage leaves blocked path unstaged'
    Write-Output 'ok - selected target rejects its own non-directory ancestor'

    Write-Output 'engine-git tests passed'
} finally {
    $env:APEX_STATE_DIR = $oldState
    $env:GIT_CONFIG_GLOBAL = $oldGitConfigGlobal
    $env:GIT_CONFIG_NOSYSTEM = $oldGitConfigNoSystem
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolvedTestRoot) -notmatch '^engine-git-test-[0-9a-f]{32}$') {
            throw "Refusing to clean unexpected test directory: $resolvedTestRoot"
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
