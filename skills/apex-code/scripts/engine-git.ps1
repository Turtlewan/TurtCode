function Invoke-EngineGit {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $WorkingDirectory @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    [pscustomobject]@{
        ok        = ($exitCode -eq 0)
        exit_code = $exitCode
        output    = $output
        text      = (($output -join "`n").Trim())
    }
}

function Assert-EngineGitResult {
    param([Parameter(Mandatory = $true)]$Result, [Parameter(Mandatory = $true)][string]$Action)
    if (-not $Result.ok) {
        throw "$Action failed (git exit $($Result.exit_code)): $($Result.text)"
    }
}

function Get-EngineGitProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-EngineIdentity {
    param([Parameter(Mandatory = $true)]$Spec)
    $name = [string](Get-EngineGitProperty $Spec 'name')
    $runId = [string](Get-EngineGitProperty $Spec 'run_id')
    if ($name -cnotmatch '^[a-z0-9][a-z0-9-]{0,62}$') { throw 'Invalid Engine spec name.' }
    if ($runId -cnotmatch '^[0-9a-f]{8,}$') { throw 'Invalid Engine run_id.' }
    [pscustomobject]@{ name = $name; run_id = $runId; run8 = $runId.Substring(0, 8) }
}

function Get-EngineCanonicalRoot {
    param([Parameter(Mandatory = $true)][string]$Path)
    [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Get-EngineDefaultWorktreeRoot {
    param([Parameter(Mandatory = $true)][string]$Repo)
    $repoRoot = Get-EngineCanonicalRoot $Repo
    $parent = Split-Path -Parent $repoRoot
    $leaf = Split-Path -Leaf $repoRoot
    Join-Path $parent ($leaf + '-wt')
}

function ConvertTo-EngineRelativePath {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path) -or $Path.IndexOf([char]0) -ge 0) {
        throw "Invalid manifest path: $Path"
    }
    $rootFull = Get-EngineCanonicalRoot $Root
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull $Path))
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Manifest path escapes the repository: $Path"
    }
    $relative = $candidate.Substring($prefix.Length).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative -match '(^|/)\.\.(/|$)') {
        throw "Invalid manifest path: $Path"
    }
    $relative
}

function Get-EngineMainWorktree {
    param([Parameter(Mandatory = $true)][string]$Worktree)
    $result = Invoke-EngineGit $Worktree @('worktree', 'list', '--porcelain')
    Assert-EngineGitResult $result 'List worktrees'
    foreach ($line in $result.output) {
        if ($line.StartsWith('worktree ')) {
            return (Get-EngineCanonicalRoot $line.Substring(9))
        }
    }
    throw 'Git did not report a main worktree.'
}

function Test-EngineReparseAttribute {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-EngineWorkingPathSafety {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    try {
        $rootFull = Get-EngineCanonicalRoot $Root
        $relative = ConvertTo-EngineRelativePath $rootFull $RelativePath
        $parts = $relative -split '/'
        $current = $rootFull
        $rootItem = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -ne $rootItem -and (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return 'worktree root is a reparse point'
        }
        for ($index = 0; $index -lt $parts.Count; $index++) {
            $current = Join-Path $current $parts[$index]
            $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
            if ($null -eq $item) { continue }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                return "reparse point at $($parts[0..$index] -join '/')"
            }
            if (($index -eq ($parts.Count - 1)) -and $item.PSIsContainer) {
                return 'manifest path is a directory'
            }
            if (($index -lt ($parts.Count - 1)) -and -not $item.PSIsContainer) {
                return "non-directory ancestor at $($parts[0..$index] -join '/')"
            }
        }
        return $null
    } catch {
        return $_.Exception.Message
    }
}

function Get-EngineTreeEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    $result = Invoke-EngineGit $Repo @('ls-tree', $Commit, '--', $RelativePath)
    if (-not $result.ok) { throw "Inspect commit path failed: $($result.text)" }
    if ($result.output.Count -eq 0 -or [string]::IsNullOrWhiteSpace($result.output[0])) { return $null }
    $line = $result.output[0]
    if ($line -notmatch '^(?<mode>[0-9]{6})\s+(?<type>\S+)\s+(?<hash>[0-9a-f]+)\t') {
        throw "Unparseable git tree entry for $RelativePath"
    }
    [pscustomobject]@{ mode = $Matches.mode; type = $Matches.type; hash = $Matches.hash }
}

function Test-EngineCommitPathSafety {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    try {
        $relative = ConvertTo-EngineRelativePath $Repo $RelativePath
        $parts = $relative -split '/'
        for ($index = 0; $index -lt $parts.Count; $index++) {
            $candidate = $parts[0..$index] -join '/'
            $entry = Get-EngineTreeEntry $Repo $Commit $candidate
            if ($null -eq $entry) { continue }
            if ($index -lt ($parts.Count - 1)) {
                if ($entry.mode -ne '040000' -or $entry.type -ne 'tree') {
                    return "unsafe commit ancestor at $candidate"
                }
            } elseif ($entry.mode -eq '040000' -or $entry.type -eq 'tree') {
                return 'manifest path is a directory in commit'
            } elseif ($entry.mode -ne '100644' -and $entry.mode -ne '100755') {
                return "unsafe commit entry mode $($entry.mode)"
            }
        }
        return $null
    } catch {
        return $_.Exception.Message
    }
}

function Get-EngineBlobHash {
    param([string]$Repo, [string]$Commit, [string]$RelativePath)
    $entry = Get-EngineTreeEntry $Repo $Commit $RelativePath
    if ($null -eq $entry) { return $null }
    if ($entry.type -ne 'blob' -or ($entry.mode -ne '100644' -and $entry.mode -ne '100755')) {
        throw "Path is not a regular blob at ${Commit}:$RelativePath"
    }
    $result = Invoke-EngineGit $Repo @('rev-parse', "${Commit}:$RelativePath")
    Assert-EngineGitResult $result "Read commit blob $RelativePath"
    $hash = @($result.output | Where-Object { $_ -match '^[0-9a-f]{40,64}$' } | Select-Object -Last 1)
    if ($hash.Count -ne 1) { throw "Git did not return a blob hash for ${Commit}:$RelativePath" }
    $hash[0]
}

function Get-EngineFilteredWorkingHash {
    param([string]$Repo, [string]$RelativePath)
    $relative = ConvertTo-EngineRelativePath $Repo $RelativePath
    $full = Join-Path (Get-EngineCanonicalRoot $Repo) ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not [IO.File]::Exists($full)) { return $null }
    $result = Invoke-EngineGit $Repo @('hash-object', '--path', $relative, $full)
    Assert-EngineGitResult $result "Hash working file $relative"
    $hash = @($result.output | Where-Object { $_ -match '^[0-9a-f]{40,64}$' } | Select-Object -Last 1)
    if ($hash.Count -ne 1) { throw "Git did not return a filtered hash for $relative`: $($result.text)" }
    $hash[0]
}

function Get-EngineRawSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $bytes = $sha.ComputeHash($stream) } finally { $sha.Dispose() }
    } finally { $stream.Dispose() }
    (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-EngineFileRecord {
    param($File, [string]$Root)
    $path = [string](Get-EngineGitProperty $File 'path')
    $op = ([string](Get-EngineGitProperty $File 'op')).ToLowerInvariant()
    if ($op -notin @('create', 'modify', 'delete')) { throw "Invalid operation for $path`: $op" }
    [pscustomobject]@{ path = (ConvertTo-EngineRelativePath $Root $path); op = $op }
}

function Get-EnginePathSafetyFailure {
    param([string[]]$Roots, [string]$CommitRepo, [string[]]$Commits, [string]$Path)
    foreach ($root in @($Roots)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $reason = Test-EngineWorkingPathSafety $root $Path
        if ($null -ne $reason) { return "$root`: $reason" }
    }
    foreach ($commit in @($Commits)) {
        if ([string]::IsNullOrWhiteSpace($commit)) { continue }
        $reason = Test-EngineCommitPathSafety $CommitRepo $commit $Path
        if ($null -ne $reason) { return "$commit`: $reason" }
    }
    $null
}

function New-EngineIntegration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)]$Spec,
        [Parameter(Mandatory = $true)][string]$BaseSha,
        [string]$WorktreeRoot
    )
    $repoRoot = Get-EngineCanonicalRoot $Repo
    $identity = Get-EngineIdentity $Spec
    if ([string]::IsNullOrWhiteSpace($WorktreeRoot)) { $WorktreeRoot = Get-EngineDefaultWorktreeRoot $repoRoot }
    $worktreeRootFull = [IO.Path]::GetFullPath($WorktreeRoot)
    $branch = "codex/$($identity.name)-$($identity.run8)-integration"
    $worktree = Join-Path $worktreeRootFull "$($identity.name)-$($identity.run8)-integration"
    if (Test-Path -LiteralPath $worktree) { throw "Integration worktree already exists: $worktree" }
    [void][IO.Directory]::CreateDirectory($worktreeRootFull)
    $verifyBase = Invoke-EngineGit $repoRoot @('rev-parse', '--verify', "$BaseSha^{commit}")
    Assert-EngineGitResult $verifyBase 'Verify integration base'
    $add = Invoke-EngineGit $repoRoot @('worktree', 'add', '-b', $branch, $worktree, $verifyBase.text)
    Assert-EngineGitResult $add 'Create integration worktree'
    $head = Invoke-EngineGit $worktree @('rev-parse', 'HEAD')
    Assert-EngineGitResult $head 'Read integration HEAD'
    [pscustomobject]@{ worktree = (Get-EngineCanonicalRoot $worktree); branch = $branch; head_sha = $head.text }
}

function New-EngineTaskWorktree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)]$Spec,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][int]$Attempt,
        [Parameter(Mandatory = $true)][string]$IntegrationWorktree,
        [string]$WorktreeRoot
    )
    $repoRoot = Get-EngineCanonicalRoot $Repo
    $identity = Get-EngineIdentity $Spec
    if ($TaskId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $Attempt -lt 1) { throw 'Invalid task worktree identity.' }
    if ([string]::IsNullOrWhiteSpace($WorktreeRoot)) { $WorktreeRoot = Get-EngineDefaultWorktreeRoot $repoRoot }
    $worktreeRootFull = [IO.Path]::GetFullPath($WorktreeRoot)
    $suffix = "$($identity.name)-$($identity.run8)-$TaskId-a$Attempt"
    $branch = "codex/$suffix"
    $worktree = Join-Path $worktreeRootFull $suffix
    if (Test-Path -LiteralPath $worktree) { throw "Task worktree already exists: $worktree" }
    $base = Invoke-EngineGit $IntegrationWorktree @('rev-parse', 'HEAD')
    Assert-EngineGitResult $base 'Read integration tip'
    [void][IO.Directory]::CreateDirectory($worktreeRootFull)
    $add = Invoke-EngineGit $repoRoot @('worktree', 'add', '-b', $branch, $worktree, $base.text)
    Assert-EngineGitResult $add 'Create task worktree'
    [pscustomobject]@{ worktree = (Get-EngineCanonicalRoot $worktree); branch = $branch; base_sha = $base.text }
}

function Copy-EngineTaskFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IntegrationWorktree,
        [Parameter(Mandatory = $true)][string]$TaskWorktree,
        [Parameter(Mandatory = $true)][string]$WaveBaseSha,
        [Parameter(Mandatory = $true)][object[]]$Files
    )
    $failures = New-Object System.Collections.ArrayList
    $hashes = New-Object System.Collections.ArrayList
    $main = Get-EngineMainWorktree $IntegrationWorktree
    foreach ($file in $Files) {
        $pathForFailure = [string](Get-EngineGitProperty $file 'path')
        try {
            $record = Get-EngineFileRecord $file $IntegrationWorktree
            $path = $record.path
            $reason = Get-EnginePathSafetyFailure @($main, $IntegrationWorktree, $TaskWorktree) $IntegrationWorktree @($WaveBaseSha) $path
            if ($null -ne $reason) { throw $reason }
            $baseHash = Get-EngineBlobHash $IntegrationWorktree $WaveBaseSha $path
            $taskPath = Join-Path (Get-EngineCanonicalRoot $TaskWorktree) ($path.Replace('/', '\'))
            if ($record.op -eq 'create' -and $null -ne $baseHash) { throw 'create path is present at wave base' }
            if ($record.op -ne 'create' -and $null -eq $baseHash) { throw "$($record.op) path is absent at wave base" }
            if ($record.op -eq 'delete') {
                if (Test-Path -LiteralPath $taskPath) { throw 'delete path is present after task build' }
                $integrationPath = Join-Path (Get-EngineCanonicalRoot $IntegrationWorktree) ($path.Replace('/', '\'))
                if ([IO.File]::Exists($integrationPath)) { [IO.File]::Delete($integrationPath) }
                [void]$hashes.Add([pscustomobject]@{ path = $path; hash = $null })
            } else {
                if (-not [IO.File]::Exists($taskPath)) { throw "$($record.op) path is absent after task build" }
                $integrationPath = Join-Path (Get-EngineCanonicalRoot $IntegrationWorktree) ($path.Replace('/', '\'))
                $parent = Split-Path -Parent $integrationPath
                if (-not (Test-Path -LiteralPath $parent)) { [void][IO.Directory]::CreateDirectory($parent) }
                [IO.File]::WriteAllBytes($integrationPath, [IO.File]::ReadAllBytes($taskPath))
                $sourceHash = Get-EngineRawSha256 $taskPath
                $destinationHash = Get-EngineRawSha256 $integrationPath
                if ($sourceHash -ne $destinationHash) { throw 'raw byte hash mismatch after copy' }
                [void]$hashes.Add([pscustomobject]@{ path = $path; hash = $sourceHash })
            }
        } catch {
            [void]$failures.Add([pscustomobject]@{ path = $pathForFailure; reason = $_.Exception.Message })
        }
    }
    [pscustomobject]@{ ok = ($failures.Count -eq 0); failures = @($failures); hashes = @($hashes) }
}

function Restore-EngineWave {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IntegrationWorktree,
        [Parameter(Mandatory = $true)][string]$WaveBaseSha,
        [Parameter(Mandatory = $true)][object[]]$Files
    )
    $failures = New-Object System.Collections.ArrayList
    $main = Get-EngineMainWorktree $IntegrationWorktree
    foreach ($file in $Files) {
        $rawPath = [string](Get-EngineGitProperty $file 'path')
        try {
            $record = Get-EngineFileRecord $file $IntegrationWorktree
            $path = $record.path
            $reason = Get-EnginePathSafetyFailure @($main, $IntegrationWorktree) $IntegrationWorktree @($WaveBaseSha) $path
            if ($null -ne $reason) { throw $reason }
            $baseHash = Get-EngineBlobHash $IntegrationWorktree $WaveBaseSha $path
            $full = Join-Path (Get-EngineCanonicalRoot $IntegrationWorktree) ($path.Replace('/', '\'))
            if ($null -eq $baseHash) {
                $cached = Invoke-EngineGit $IntegrationWorktree @('ls-files', '--error-unmatch', '--', $path)
                if ($cached.ok) {
                    $removeIndex = Invoke-EngineGit $IntegrationWorktree @('rm', '-f', '--cached', '--', $path)
                    Assert-EngineGitResult $removeIndex "Remove $path from integration index"
                }
                if ([IO.File]::Exists($full)) { [IO.File]::Delete($full) }
                if (Test-Path -LiteralPath $full) { throw 'path remains after restore' }
            } else {
                $restore = Invoke-EngineGit $IntegrationWorktree @('restore', '--source', $WaveBaseSha, '--staged', '--worktree', '--', $path)
                Assert-EngineGitResult $restore "Restore $path"
                $workingHash = Get-EngineFilteredWorkingHash $IntegrationWorktree $path
                if ($workingHash -ne $baseHash) { throw 'restored working file does not match wave base blob' }
                $index = Invoke-EngineGit $IntegrationWorktree @('rev-parse', ":$path")
                Assert-EngineGitResult $index "Read restored index for $path"
                if ($index.text -ne $baseHash) { throw 'restored index does not match wave base blob' }
            }
        } catch {
            [void]$failures.Add([pscustomobject]@{ path = $rawPath; reason = $_.Exception.Message })
        }
    }
    [pscustomobject]@{ ok = ($failures.Count -eq 0); failures = @($failures) }
}

function Stage-EngineWave {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IntegrationWorktree,
        [Parameter(Mandatory = $true)][object[]]$Files
    )
    $failures = New-Object System.Collections.ArrayList
    $main = Get-EngineMainWorktree $IntegrationWorktree
    $head = (Invoke-EngineGit $IntegrationWorktree @('rev-parse', 'HEAD'))
    Assert-EngineGitResult $head 'Read integration HEAD'
    foreach ($file in $Files) {
        $rawPath = [string](Get-EngineGitProperty $file 'path')
        try {
            $record = Get-EngineFileRecord $file $IntegrationWorktree
            $reason = Get-EnginePathSafetyFailure @($main, $IntegrationWorktree) $IntegrationWorktree @($head.text) $record.path
            if ($null -ne $reason) { throw $reason }
            if ($record.op -eq 'delete') {
                $result = Invoke-EngineGit $IntegrationWorktree @('rm', '-f', '--', $record.path)
            } else {
                $result = Invoke-EngineGit $IntegrationWorktree @('add', '-f', '--', $record.path)
            }
            Assert-EngineGitResult $result "Stage $($record.path)"
        } catch {
            [void]$failures.Add([pscustomobject]@{ path = $rawPath; reason = $_.Exception.Message })
        }
    }
    [pscustomobject]@{ ok = ($failures.Count -eq 0); failures = @($failures) }
}

function Commit-EngineWave {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IntegrationWorktree,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$BaseSha,
        [Parameter(Mandatory = $true)][string[]]$AllowedPaths
    )
    $branchResult = Invoke-EngineGit $IntegrationWorktree @('symbolic-ref', '--short', 'HEAD')
    Assert-EngineGitResult $branchResult 'Read integration branch'
    if ($branchResult.text -notmatch '^codex/.+-integration$') { throw 'Wave commits are allowed only on an Engine integration branch.' }
    $baseHead = Invoke-EngineGit $IntegrationWorktree @('rev-parse', 'HEAD')
    Assert-EngineGitResult $baseHead 'Read integration HEAD before commit'
    if ($baseHead.text -cne $BaseSha) {
        throw "Integration HEAD does not match wave base (expected $BaseSha, got $($baseHead.text))."
    }
    $unstaged = Invoke-EngineGit $IntegrationWorktree @('diff', '--quiet')
    if ($unstaged.exit_code -ne 0) { throw 'Integration worktree has unstaged tracked changes.' }
    $staged = Invoke-EngineGit $IntegrationWorktree @('diff', '--cached', '--quiet')
    if ($staged.exit_code -eq 0) { throw 'Integration index has no verified changes to commit.' }
    if ($staged.exit_code -ne 1) { throw "Cannot inspect integration index: $($staged.text)" }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'git.exe'
    $startInfo.WorkingDirectory = $IntegrationWorktree
    $startInfo.Arguments = "diff --cached --name-only --no-renames -z $BaseSha"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false, $true)
    $startInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false, $true)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Inspect integration index paths failed to start git.' }
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $pathExitCode = $process.ExitCode
        $pathOutput = $stdoutTask.Result
        $pathError = $stderrTask.Result
    } finally {
        $process.Dispose()
    }
    if ($pathExitCode -ne 0) { throw "Inspect integration index paths failed (git exit $pathExitCode): $($pathError.Trim())" }
    $indexedPaths = @($pathOutput -split [char]0 | Where-Object { $_.Length -gt 0 })
    $allowedSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($allowedPath in @($AllowedPaths)) { [void]$allowedSet.Add([string]$allowedPath) }
    $indexedSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($indexedPath in @($indexedPaths)) { [void]$indexedSet.Add([string]$indexedPath) }
    $pathDifferences = New-Object System.Collections.ArrayList
    foreach ($indexedPath in @($indexedPaths)) {
        if (-not $allowedSet.Contains($indexedPath)) { [void]$pathDifferences.Add($indexedPath) }
    }
    foreach ($allowedPath in @($AllowedPaths)) {
        if (-not $indexedSet.Contains($allowedPath)) { [void]$pathDifferences.Add("missing: $allowedPath") }
    }
    if ($pathDifferences.Count -gt 0) {
        throw "integration index contains paths outside wave manifest: $(@($pathDifferences) -join ', ')"
    }
    $verifiedTree = Invoke-EngineGit $IntegrationWorktree @('write-tree')
    Assert-EngineGitResult $verifiedTree 'Capture verified integration index tree'
    $commit = Invoke-EngineGit $IntegrationWorktree @('commit', '--no-verify', '-m', $Message)
    Assert-EngineGitResult $commit 'Commit integration wave'
    $head = Invoke-EngineGit $IntegrationWorktree @('rev-parse', 'HEAD')
    Assert-EngineGitResult $head 'Read committed integration HEAD'
    $committedTree = Invoke-EngineGit $IntegrationWorktree @('rev-parse', 'HEAD^{tree}')
    Assert-EngineGitResult $committedTree 'Read committed integration tree'
    if ($committedTree.text -ne $verifiedTree.text) {
        throw "Committed integration tree does not match verified index tree (expected $($verifiedTree.text), got $($committedTree.text))."
    }
    [pscustomobject]@{ head_sha = $head.text; branch = $branchResult.text }
}

function Test-EngineWorkingIdentity {
    param([string]$Repo, [string]$Path, [AllowNull()][object]$ExpectedHash)
    $actual = Get-EngineFilteredWorkingHash $Repo $Path
    if ($null -eq $ExpectedHash) { return ($null -eq $actual) }
    ($actual -eq $ExpectedHash)
}

function New-EngineRecoveryPatch {
    param(
        [string]$IntegrationWorktree,
        [string]$BaseSha,
        [string]$IntegrationTip,
        [string[]]$RemainingPaths,
        [string[]]$JournaledPaths,
        [string]$StateDirectory
    )
    if ([string]::IsNullOrWhiteSpace($StateDirectory)) { return $null }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($StateDirectory))
    $stem = 'handoff-recovery-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff') + '-' + [Guid]::NewGuid().ToString('N')
    $patchPath = [IO.Path]::GetFullPath((Join-Path $StateDirectory ($stem + '.patch')))
    $journalPath = Join-Path $StateDirectory ($stem + '.journal.json')
    $arguments = @('diff', '--binary', "--output=$patchPath", $BaseSha, $IntegrationTip, '--') + @($RemainingPaths)
    $diff = Invoke-EngineGit $IntegrationWorktree $arguments
    Assert-EngineGitResult $diff 'Create hand-off recovery patch'
    $utf8 = New-Object Text.UTF8Encoding($false)
    $journalArray = [object[]]@($JournaledPaths)
    [IO.File]::WriteAllText($journalPath, (ConvertTo-Json -InputObject $journalArray -Compress), $utf8)
    $patchPath
}

function Invoke-EngineHandoff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$IntegrationWorktree,
        [Parameter(Mandatory = $true)][string]$BaseSha,
        [Parameter(Mandatory = $true)][string]$ExpectedTip,
        [Parameter(Mandatory = $true)][object[]]$Files,
        [string[]]$JournaledPaths = @(),
        [Parameter(Mandatory = $true)][scriptblock]$OnFileJournaled,
        [Parameter(Mandatory = $true)][string]$StateDirectory
    )
    if ($null -eq $JournaledPaths) { $JournaledPaths = @() }
    $repoRoot = Get-EngineCanonicalRoot $Repo
    $integrationRoot = Get-EngineCanonicalRoot $IntegrationWorktree
    $tipResult = Invoke-EngineGit $integrationRoot @('rev-parse', 'HEAD')
    Assert-EngineGitResult $tipResult 'Read integration tip for hand-off'
    $tip = $tipResult.text
    if ($tip -cne $ExpectedTip) {
        throw "integration HEAD $tip differs from reviewed tip $ExpectedTip; hand-off refused"
    }
    $completed = New-Object System.Collections.ArrayList
    $journalSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $records = New-Object System.Collections.ArrayList
    $manifestSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $Files) {
        $record = Get-EngineFileRecord $file $repoRoot
        if (-not $manifestSet.Add($record.path)) { throw "Duplicate hand-off path: $($record.path)" }
        [void]$records.Add($record)
    }
    foreach ($journaled in @($JournaledPaths)) {
        $canonical = ConvertTo-EngineRelativePath $repoRoot $journaled
        if (-not $manifestSet.Contains($canonical)) { throw "Journaled path is not in the hand-off manifest: $canonical" }
        if ($journalSet.Add($canonical)) { [void]$completed.Add($canonical) }
    }
    $pending = New-Object System.Collections.ArrayList

    foreach ($record in @($records)) {
        if ($journalSet.Contains($record.path)) { continue }
        $reason = Get-EnginePathSafetyFailure @($repoRoot, $integrationRoot) $repoRoot @($BaseSha, $tip) $record.path
        if ($null -ne $reason) {
            $remaining = @($records | ForEach-Object { $_.path } | Where-Object { -not $journalSet.Contains($_) })
            $patch = New-EngineRecoveryPatch $integrationRoot $BaseSha $tip $remaining @($completed) $StateDirectory
            return [pscustomobject]@{ ok = $false; completed = @($completed); mismatch_path = $record.path; recovery_patch = $patch }
        }
        $baseHash = Get-EngineBlobHash $repoRoot $BaseSha $record.path
        $tipHash = Get-EngineBlobHash $integrationRoot $tip $record.path
        $preconditionFailed =
            ($record.op -eq 'create' -and $null -ne $baseHash) -or
            ($record.op -ne 'create' -and $null -eq $baseHash) -or
            ($record.op -eq 'delete' -and $null -ne $tipHash) -or
            ($record.op -ne 'delete' -and $null -eq $tipHash)
        if ($preconditionFailed) {
            $remaining = @($records | ForEach-Object { $_.path } | Where-Object { -not $journalSet.Contains($_) })
            $patch = New-EngineRecoveryPatch $integrationRoot $BaseSha $tip $remaining @($completed) $StateDirectory
            return [pscustomobject]@{ ok = $false; completed = @($completed); mismatch_path = $record.path; recovery_patch = $patch }
        }
        if (-not (Test-EngineWorkingIdentity $integrationRoot $record.path $tipHash)) {
            $remaining = @($records | ForEach-Object { $_.path } | Where-Object { -not $journalSet.Contains($_) })
            $patch = New-EngineRecoveryPatch $integrationRoot $BaseSha $tip $remaining @($completed) $StateDirectory
            return [pscustomobject]@{ ok = $false; completed = @($completed); mismatch_path = $record.path; recovery_patch = $patch }
        }
        $currentHash = Get-EngineFilteredWorkingHash $repoRoot $record.path
        if (($null -eq $tipHash -and $null -eq $currentHash) -or ($null -ne $tipHash -and $currentHash -eq $tipHash)) {
            & $OnFileJournaled $record.path
            [void]$journalSet.Add($record.path)
            [void]$completed.Add($record.path)
        } elseif (($null -eq $baseHash -and $null -eq $currentHash) -or ($null -ne $baseHash -and $currentHash -eq $baseHash)) {
            [void]$pending.Add([pscustomobject]@{ record = $record; base_hash = $baseHash; tip_hash = $tipHash })
        } else {
            $remaining = @($records | ForEach-Object { $_.path } | Where-Object { -not $journalSet.Contains($_) })
            $patch = New-EngineRecoveryPatch $integrationRoot $BaseSha $tip $remaining @($completed) $StateDirectory
            return [pscustomobject]@{ ok = $false; completed = @($completed); mismatch_path = $record.path; recovery_patch = $patch }
        }
    }

    foreach ($item in @($pending)) {
        $record = $item.record
        $reason = Get-EnginePathSafetyFailure @($repoRoot, $integrationRoot) $repoRoot @($BaseSha, $tip) $record.path
        if ($null -ne $reason) {
            $remaining = @($pending | ForEach-Object { $_.record.path } | Where-Object { -not $journalSet.Contains($_) })
            $patch = New-EngineRecoveryPatch $integrationRoot $BaseSha $tip $remaining @($completed) $StateDirectory
            return [pscustomobject]@{ ok = $false; completed = @($completed); mismatch_path = $record.path; recovery_patch = $patch }
        }
        if (-not (Test-EngineWorkingIdentity $repoRoot $record.path $item.base_hash)) {
            $remaining = @($pending | ForEach-Object { $_.record.path } | Where-Object { -not $journalSet.Contains($_) })
            $patch = New-EngineRecoveryPatch $integrationRoot $BaseSha $tip $remaining @($completed) $StateDirectory
            return [pscustomobject]@{ ok = $false; completed = @($completed); mismatch_path = $record.path; recovery_patch = $patch }
        }
        $destination = Join-Path $repoRoot ($record.path.Replace('/', '\'))
        if ($record.op -eq 'delete') {
            if ([IO.File]::Exists($destination)) { [IO.File]::Delete($destination) }
        } else {
            $source = Join-Path $integrationRoot ($record.path.Replace('/', '\'))
            $parent = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $parent)) { [void][IO.Directory]::CreateDirectory($parent) }
            [IO.File]::WriteAllBytes($destination, [IO.File]::ReadAllBytes($source))
        }
        $reason = Get-EnginePathSafetyFailure @($repoRoot, $integrationRoot) $repoRoot @($BaseSha, $tip) $record.path
        if ($null -ne $reason) {
            $remaining = @($pending | ForEach-Object { $_.record.path } | Where-Object { -not $journalSet.Contains($_) })
            $patch = New-EngineRecoveryPatch $integrationRoot $BaseSha $tip $remaining @($completed) $StateDirectory
            return [pscustomobject]@{ ok = $false; completed = @($completed); mismatch_path = $record.path; recovery_patch = $patch }
        }
        if (-not (Test-EngineWorkingIdentity $repoRoot $record.path $item.tip_hash)) {
            $remaining = @($pending | ForEach-Object { $_.record.path } | Where-Object { -not $journalSet.Contains($_) })
            $patch = New-EngineRecoveryPatch $integrationRoot $BaseSha $tip $remaining @($completed) $StateDirectory
            return [pscustomobject]@{ ok = $false; completed = @($completed); mismatch_path = $record.path; recovery_patch = $patch }
        }
        & $OnFileJournaled $record.path
        [void]$journalSet.Add($record.path)
        [void]$completed.Add($record.path)
    }
    [pscustomobject]@{ ok = $true; completed = @($completed); mismatch_path = $null; recovery_patch = $null }
}

function Test-EngineTeardownProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)]$Spec,
        [Parameter(Mandatory = $true)][object[]]$Files,
        [Parameter(Mandatory = $true)][string]$IntegrationTip
    )
    [void](Get-EngineIdentity $Spec)
    $repoRoot = Get-EngineCanonicalRoot $Repo
    $head = Invoke-EngineGit $repoRoot @('rev-parse', 'HEAD')
    Assert-EngineGitResult $head 'Read main HEAD for teardown proof'
    $failures = New-Object System.Collections.ArrayList
    foreach ($file in $Files) {
        $rawPath = [string](Get-EngineGitProperty $file 'path')
        try {
            $record = Get-EngineFileRecord $file $repoRoot
            $reason = Get-EnginePathSafetyFailure @($repoRoot) $repoRoot @($head.text, $IntegrationTip) $record.path
            if ($null -ne $reason) { throw $reason }
            $headHash = Get-EngineBlobHash $repoRoot $head.text $record.path
            $tipHash = Get-EngineBlobHash $repoRoot $IntegrationTip $record.path
            $workingHash = Get-EngineFilteredWorkingHash $repoRoot $record.path
            if ($record.op -eq 'delete') {
                if ($null -ne $headHash -or $null -ne $tipHash -or $null -ne $workingHash) { throw 'delete path is not absent from main HEAD, working tree, and integration tip' }
            } else {
                if ($null -eq $tipHash -or $headHash -ne $tipHash -or $workingHash -ne $tipHash) { throw 'main HEAD and filtered working file do not match integration tip' }
            }
        } catch {
            [void]$failures.Add([pscustomobject]@{ path = $rawPath; reason = $_.Exception.Message })
        }
    }
    [pscustomobject]@{ ok = ($failures.Count -eq 0); failures = @($failures) }
}

function Remove-EngineRunWorktrees {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)]$Spec,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Branches,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Worktrees,
        [Parameter(Mandatory = $true)][scriptblock]$OnItemRemoved
    )
    $repoRoot = Get-EngineCanonicalRoot $Repo
    $identity = Get-EngineIdentity $Spec
    $prefix = "codex/$($identity.name)-$($identity.run8)-"
    $branchSet = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($branch in @($Branches)) {
        if (-not $branch.StartsWith($prefix, [StringComparison]::Ordinal) -or $branch.Length -le $prefix.Length -or $branch -match '[\s~^:?*\[]') {
            throw "Refusing unrecorded Engine branch: $branch"
        }
        [void]$branchSet.Add($branch)
    }
    $listed = Invoke-EngineGit $repoRoot @('worktree', 'list', '--porcelain')
    Assert-EngineGitResult $listed 'List worktrees for teardown'
    $registered = @{}
    $currentPath = $null
    $currentBranch = $null
    foreach ($line in $listed.output) {
        if ($line.StartsWith('worktree ')) {
            if ($null -ne $currentPath) { $registered[$currentPath.ToLowerInvariant()] = $currentBranch }
            $currentPath = Get-EngineCanonicalRoot $line.Substring(9)
            $currentBranch = $null
        }
        elseif ($line.StartsWith('branch refs/heads/') -and $null -ne $currentPath) {
            $currentBranch = $line.Substring(18)
        } elseif ([string]::IsNullOrWhiteSpace($line) -and $null -ne $currentPath) {
            $registered[$currentPath.ToLowerInvariant()] = $currentBranch
            $currentPath = $null
            $currentBranch = $null
        }
    }
    if ($null -ne $currentPath) { $registered[$currentPath.ToLowerInvariant()] = $currentBranch }
    $worktreeRecords = @()
    foreach ($worktree in @($Worktrees)) {
        $full = Get-EngineCanonicalRoot $worktree
        $leaf = Split-Path -Leaf $full
        $expectedPrefix = "$($identity.name)-$($identity.run8)-"
        if (-not $leaf.StartsWith($expectedPrefix, [StringComparison]::Ordinal)) { throw "Refusing non-matching Engine worktree: $full" }
        $expectedBranch = 'codex/' + $leaf
        if (-not $branchSet.Contains($expectedBranch)) { throw "Worktree has no matching recorded branch: $full" }
        $key = $full.ToLowerInvariant()
        if ($registered.ContainsKey($key) -and $registered[$key] -ne $expectedBranch) { throw "Worktree branch mismatch: $full" }
        if (-not $registered.ContainsKey($key) -and (Test-Path -LiteralPath $full)) { throw "Refusing unregistered worktree path: $full" }
        [void]($worktreeRecords += [pscustomobject]@{ path = $full; branch = $expectedBranch; registered = $registered.ContainsKey($key) })
    }
    $failures = New-Object System.Collections.ArrayList
    foreach ($item in $worktreeRecords) {
        try {
            if ($item.registered) {
                $remove = Invoke-EngineGit $repoRoot @('worktree', 'remove', '--force', '--', $item.path)
                Assert-EngineGitResult $remove "Remove worktree $($item.path)"
            }
            & $OnItemRemoved ([pscustomobject]@{ kind = 'worktree'; value = $item.path })
        } catch {
            [void]$failures.Add([pscustomobject]@{ path = $item.path; reason = $_.Exception.Message })
        }
    }
    foreach ($branch in @($Branches)) {
        try {
            $exists = Invoke-EngineGit $repoRoot @('show-ref', '--verify', '--quiet', "refs/heads/$branch")
            if ($exists.exit_code -eq 0) {
                $remove = Invoke-EngineGit $repoRoot @('branch', '-D', '--', $branch)
                Assert-EngineGitResult $remove "Remove branch $branch"
            } elseif ($exists.exit_code -ne 1) {
                throw "Cannot inspect branch $branch`: $($exists.text)"
            }
            & $OnItemRemoved ([pscustomobject]@{ kind = 'branch'; value = $branch })
        } catch {
            [void]$failures.Add([pscustomobject]@{ path = $branch; reason = $_.Exception.Message })
        }
    }
    [pscustomobject]@{ ok = ($failures.Count -eq 0); failures = @($failures) }
}
