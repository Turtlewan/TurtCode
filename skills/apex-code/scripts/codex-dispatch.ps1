# Durable Codex dispatcher (ADR-033).
#
# Delivers a dispatch pack to `codex exec`, explicitly closes the child's stdin,
# and records the run in a durable JSONL ledger.  A no-output watchdog flags a
# stalled run but deliberately does not terminate it; process ownership remains
# with the caller.  `-Adopt` prints the newest matching run's worktree and diff.

[CmdletBinding()]
param(
    [string]$Spec,
    [string]$Task,
    [string]$Worktree,
    [string]$BaseSha,
    [string]$Phase,
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')]
    [string]$Effort = 'medium',
    [ValidateRange(1, 2147483647)]
    [int]$NoOutputTimeoutMin = 8,
    [switch]$Adopt,
    [string]$Prompt,
    [string]$ScratchDirectory = $env:TEMP,
    [string]$CodexExecutable = 'codex',
    [string[]]$CodexExecutableArgumentPrefix = @()
)

$ErrorActionPreference = 'Stop'

function Get-UtcTimestamp {
    return (Get-Date).ToUniversalTime().ToString('o')
}

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory)][string]$Value)

    return ($Value -replace '[<>:"/\\|?*]', '_')
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    # Quote with the CommandLineToArgvW / CreateProcess backslash rules.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

$dispatcherRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$progressDirectory = Join-Path $dispatcherRoot 'docs\progress'
$ledgerPath = Join-Path $progressDirectory 'codex-run-ledger.jsonl'
$schemaPath = Join-Path $dispatcherRoot 'skills\apex-code\references\codex-completion-schema.json'
$ledgerMutex = [System.Threading.Mutex]::new($false, 'ApexCodexRunLedger')

function Invoke-WithLedgerLock {
    param([Parameter(Mandatory)][scriptblock]$Action)

    $acquired = $false
    try {
        try {
            $acquired = $ledgerMutex.WaitOne([TimeSpan]::FromSeconds(30))
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) { throw 'Timed out waiting for the Codex run-ledger lock.' }
        & $Action
    } finally {
        if ($acquired) { $ledgerMutex.ReleaseMutex() }
    }
}

function Add-LedgerRow {
    param([Parameter(Mandatory)][hashtable]$Row)

    Invoke-WithLedgerLock {
        [System.IO.Directory]::CreateDirectory($progressDirectory) | Out-Null
        $json = $Row | ConvertTo-Json -Compress -Depth 8
        [System.IO.File]::AppendAllText(
            $ledgerPath,
            $json + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )
    }
}

function Update-LedgerRow {
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][hashtable]$Changes
    )

    Invoke-WithLedgerLock {
        if (-not (Test-Path -LiteralPath $ledgerPath)) {
            throw "Codex run ledger does not exist: $ledgerPath"
        }

        $updated = $false
        $outputLines = foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $line | ConvertFrom-Json
            if ($row.run_id -eq $RunId) {
                foreach ($change in $Changes.GetEnumerator()) {
                    $row | Add-Member -NotePropertyName $change.Key -NotePropertyValue $change.Value -Force
                }
                $updated = $true
                $row | ConvertTo-Json -Compress -Depth 8
            } else {
                $line
            }
        }

        if (-not $updated) { throw "Codex run ledger row not found for run_id $RunId." }

        # A same-directory temporary file plus File.Replace makes a completed
        # status update atomic for readers; the named mutex serializes wrappers.
        $replacementId = [guid]::NewGuid().ToString('N')
        $temporaryPath = "$($ledgerPath).$replacementId.tmp"
        $backupPath = "$($ledgerPath).$replacementId.bak"
        try {
            [System.IO.File]::WriteAllLines(
                $temporaryPath,
                [string[]]$outputLines,
                [System.Text.UTF8Encoding]::new($false)
            )
            [System.IO.File]::Replace($temporaryPath, $ledgerPath, $backupPath)
        } finally {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force
            }
            if (Test-Path -LiteralPath $backupPath) {
                Remove-Item -LiteralPath $backupPath -Force
            }
        }
    }
}

function Invoke-Adopt {
    if ([string]::IsNullOrWhiteSpace($Spec) -or [string]::IsNullOrWhiteSpace($Phase)) {
        throw '-Adopt requires -Spec and -Phase.'
    }
    if (-not (Test-Path -LiteralPath $ledgerPath)) {
        throw "Codex run ledger does not exist: $ledgerPath"
    }

    $match = Invoke-WithLedgerLock {
        $matches = foreach ($line in [System.IO.File]::ReadAllLines($ledgerPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $line | ConvertFrom-Json
            if ($row.spec -eq $Spec -and $row.phase -eq $Phase) { $row }
        }
        $matches | Sort-Object { [datetime]$_.started } -Descending | Select-Object -First 1
    }

    if ($null -eq $match) {
        throw "No Codex ledger row matches spec '$Spec' and phase '$Phase'."
    }

    Write-Output $match.worktree
    & git -C $match.worktree diff "$($match.base_sha)..HEAD"
    exit $LASTEXITCODE
}

if ($Adopt) {
    Invoke-Adopt
}

foreach ($required in @{
        Spec = $Spec; Task = $Task; Worktree = $Worktree; BaseSha = $BaseSha; Phase = $Phase; Prompt = $Prompt
    }.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Value)) {
        throw "-$($required.Key) is required unless -Adopt is used."
    }
}

if (-not (Test-Path -LiteralPath $Worktree -PathType Container)) {
    throw "Worktree does not exist: $Worktree"
}
if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw "Codex completion schema does not exist: $schemaPath"
}

[System.IO.Directory]::CreateDirectory($progressDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory($ScratchDirectory) | Out-Null
$safeSpec = ConvertTo-SafeFileName $Spec
$safeTask = ConvertTo-SafeFileName $Task
$logPath = Join-Path $progressDirectory "codex-$safeSpec-$safeTask.log"
$finalPath = Join-Path $ScratchDirectory "codex-$safeSpec-$safeTask.final"
[System.IO.File]::WriteAllText($logPath, [string]::Empty, [System.Text.UTF8Encoding]::new($false))

$runId = [guid]::NewGuid().ToString('N')
$started = Get-UtcTimestamp
$ledgerRow = [ordered]@{
    run_id = $runId
    pid = $null
    worktree = $Worktree
    spec = $Spec
    task = $Task
    base_sha = $BaseSha
    phase = $Phase
    started = $started
    log_path = $logPath
    status = 'running'
}
Add-LedgerRow $ledgerRow

$arguments = @(
    'exec', '-p', 'apex-coder', '--sandbox', 'workspace-write', '-m', 'gpt-5.6-terra',
    '-c', "model_reasoning_effort=$Effort", '-C', $Worktree, '--json', '--output-schema',
    $schemaPath, '-o', $finalPath, '--color', 'never'
) | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }

# ProcessStartInfo uses CreateProcess rather than PowerShell command resolution.
# The npm installation exposes `codex` to PowerShell as codex.ps1; invoke its
# node entry point directly because a .cmd shim is not executable with
# UseShellExecute = $false.
$resolvedCodexExecutable = $CodexExecutable
$prefixArguments = @($CodexExecutableArgumentPrefix | ForEach-Object {
        ConvertTo-ProcessArgument ([string]$_)
    })
$resolvedArguments = $prefixArguments + $arguments
if ($CodexExecutable -eq 'codex') {
    $codexCommand = @(Get-Command codex -CommandType Application, ExternalScript -ErrorAction Stop)[0]
    if ($codexCommand.CommandType -eq 'ExternalScript') {
        $npmBinDirectory = Split-Path $codexCommand.Source -Parent
        $nodePath = Join-Path $npmBinDirectory 'node.exe'
        $codexEntryPoint = Join-Path $npmBinDirectory 'node_modules\@openai\codex\bin\codex.js'
        if (-not (Test-Path -LiteralPath $codexEntryPoint -PathType Leaf)) {
            throw "The PowerShell Codex command has no node entry point: $codexEntryPoint"
        }
        $resolvedCodexExecutable = if (Test-Path -LiteralPath $nodePath -PathType Leaf) { $nodePath } else { 'node' }
        $resolvedArguments = @((ConvertTo-ProcessArgument $codexEntryPoint)) + $prefixArguments + $arguments
    } else {
        $resolvedCodexExecutable = $codexCommand.Source
    }
}

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $resolvedCodexExecutable
$startInfo.Arguments = [string]::Join(' ', [string[]]$resolvedArguments)
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$appendLogText = {
    param([string]$Text)
    if ($Text.Length -gt 0) {
        [System.IO.File]::AppendAllText($logPath, $Text, [System.Text.UTF8Encoding]::new($false))
    }
}

try {
    if (-not $process.Start()) { throw 'Failed to start codex exec.' }

    # ADR-033's load-bearing behavior: write the whole dispatch pack and close
    # the redirected stdin immediately, so Codex never inherits a wedged stdin.
    $process.StandardInput.Write($Prompt)
    $process.StandardInput.Close()
    Update-LedgerRow -RunId $runId -Changes @{ pid = $process.Id }

    # Read both redirected streams asynchronously without PowerShell event
    # handlers.  Windows PowerShell invokes those handlers on threads without a
    # runspace, while these .NET tasks keep the JSON log live for the watchdog.
    $bufferSize = 4096
    $stdoutBuffer = New-Object char[] $bufferSize
    $stderrBuffer = New-Object char[] $bufferSize
    $stdoutTask = $process.StandardOutput.ReadAsync($stdoutBuffer, 0, $bufferSize)
    $stderrTask = $process.StandardError.ReadAsync($stderrBuffer, 0, $bufferSize)
    $stdoutClosed = $false
    $stderrClosed = $false
    $stalled = $false
    $nextWatchCheck = (Get-Date).AddSeconds(15)
    while (-not $process.HasExited) {
        if ($stdoutTask.IsCompleted) {
            $stdoutCount = $stdoutTask.Result
            if ($stdoutCount -gt 0) {
                & $appendLogText ([string]::new($stdoutBuffer, 0, $stdoutCount))
                $stdoutTask = $process.StandardOutput.ReadAsync($stdoutBuffer, 0, $bufferSize)
            } else {
                $stdoutClosed = $true
            }
        }
        if ($stderrTask.IsCompleted) {
            $stderrCount = $stderrTask.Result
            if ($stderrCount -gt 0) {
                & $appendLogText ([string]::new($stderrBuffer, 0, $stderrCount))
                $stderrTask = $process.StandardError.ReadAsync($stderrBuffer, 0, $bufferSize)
            } else {
                $stderrClosed = $true
            }
        }

        Start-Sleep -Seconds 1
        $process.Refresh()
        if ($process.HasExited) { break }

        if ((Get-Date) -ge $nextWatchCheck) {
            $lastWrite = (Get-Item -LiteralPath $logPath).LastWriteTime
            if (((Get-Date) - $lastWrite).TotalMinutes -ge $NoOutputTimeoutMin) {
                Update-LedgerRow -RunId $runId -Changes @{ status = 'stalled'; stalled = (Get-UtcTimestamp) }
                $stalled = $true
                break
            }
            $nextWatchCheck = (Get-Date).AddSeconds(15)
        }
    }

    if ($stalled) {
        # Do not kill the child: the caller owns that decision.
        exit 124
    }

    $process.WaitForExit()
    while (-not ($stdoutClosed -and $stderrClosed)) {
        if (-not $stdoutClosed -and $stdoutTask.IsCompleted) {
            $stdoutCount = $stdoutTask.Result
            if ($stdoutCount -gt 0) {
                & $appendLogText ([string]::new($stdoutBuffer, 0, $stdoutCount))
                $stdoutTask = $process.StandardOutput.ReadAsync($stdoutBuffer, 0, $bufferSize)
            } else {
                $stdoutClosed = $true
            }
        }
        if (-not $stderrClosed -and $stderrTask.IsCompleted) {
            $stderrCount = $stderrTask.Result
            if ($stderrCount -gt 0) {
                & $appendLogText ([string]::new($stderrBuffer, 0, $stderrCount))
                $stderrTask = $process.StandardError.ReadAsync($stderrBuffer, 0, $bufferSize)
            } else {
                $stderrClosed = $true
            }
        }
        if (-not ($stdoutClosed -and $stderrClosed)) { Start-Sleep -Milliseconds 25 }
    }
    $exitCode = $process.ExitCode
    $status = if ($exitCode -eq 0) { 'done' } else { 'failed' }
    Update-LedgerRow -RunId $runId -Changes @{ status = $status; ended = (Get-UtcTimestamp) }
    exit $exitCode
} catch {
    # A launch/setup failure has no child exit code, but it is still durable.
    Update-LedgerRow -RunId $runId -Changes @{ status = 'failed'; ended = (Get-UtcTimestamp); error = $_.Exception.Message }
    throw
} finally {
    $process.Dispose()
    $ledgerMutex.Dispose()
}
