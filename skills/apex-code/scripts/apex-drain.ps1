<#
Serial, durable unattended Engine orchestration. Engine artifacts remain Engine-owned.
TestHooks (APEX_DRAIN_TEST_MODE=1 only): LaunchWorker receives a splattable
hashtable with Run and StateRoot; AfterCheckpoint receives name and persisted
state; ChildAlive receives a PID/start-time identity. Hooks are never serialized.
#>
[CmdletBinding()]
param([string]$Project, [string]$Run, [string]$StateRoot, [string]$Resume, [hashtable]$TestHooks)
$ErrorActionPreference = 'Stop'
$script:DrainScript = $PSCommandPath
$script:DrainScripts = $PSScriptRoot
$script:DrainState = $null
$script:DrainDirectory = $null
$script:DrainHooks = $TestHooks
. (Join-Path $PSScriptRoot 'engine-plan.ps1')
. (Join-Path $PSScriptRoot 'engine-git.ps1')
. (Join-Path $PSScriptRoot 'engine-dispatch.ps1')

function Get-DrainNow {
    if ($script:DrainHooks.UtcNow) { return ([datetime](& $script:DrainHooks.UtcNow)).ToUniversalTime() }
    return [datetime]::UtcNow
}
function Wait-DrainMinutes([double]$Minutes) {
    if ($script:DrainHooks.SleepMinutes) { & $script:DrainHooks.SleepMinutes $Minutes | Out-Null }
    else { Start-Sleep -Milliseconds ([int]($Minutes * 60000)) }
}
function Get-DrainIdentity([int]$ProcessId) {
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($p) { try { return [pscustomobject]@{ pid = $ProcessId; start_time = $p.StartTime.ToUniversalTime().ToString('o') } } catch {} }
    return $null
}
function Test-DrainAlive($Identity) {
    if (-not $Identity -or -not $Identity.pid -or -not $Identity.start_time) { return $false }
    if ($script:DrainHooks.ChildAlive) { return [bool](& $script:DrainHooks.ChildAlive $Identity) }
    $actual = Get-DrainIdentity ([int]$Identity.pid)
    return ($actual -and ([datetime]$actual.start_time -eq [datetime]$Identity.start_time))
}
function Get-DrainRoot([string]$Path) {
    if (-not $Path -or $Path -notmatch '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+)') { throw 'paths must be absolute' }
    return ConvertTo-EngineCanonicalRoot $Path
}
function Assert-DrainOutside([string]$Path) {
    $probe = $Path
    while (-not (Test-Path -LiteralPath $probe -PathType Container)) {
        $next = Split-Path -Parent $probe
        if (-not $next -or $next -eq $probe) { return }
        $probe = $next
    }
    $r = Invoke-EnginePlanNative 'git' @('-C', $probe, 'rev-parse', '--is-inside-work-tree')
    if ($r.exit_code -eq 0 -and ($r.output -join '').Trim() -eq 'true') { throw "StateRoot must be outside every Git worktree: $Path" }
}
function Write-DrainAtomic([string]$Path, [string]$Text) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}
function Read-DrainJson([string]$Path) { return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json) }
function Get-DrainEngine($Spec, $State = $script:DrainState) {
    if ($Spec.engine_run_id) { return Read-DrainJson (Join-Path $State.state_root "$($Spec.engine_run_id)/engine-state.json") }
    return $null
}
function Get-DrainResumeCommand($State) { return 'powershell.exe -NoProfile -File "' + $script:DrainScript + '" -Resume ' + $State.drain_id }
function Write-DrainReport($State) {
    $lines = @('# Drain ' + $State.drain_id, '', "Project: $($State.project)", "Started UTC: $($State.started_at)", "Updated UTC: $($State.updated_at)", "Status: $($State.status)", '', 'Resume: `' + (Get-DrainResumeCommand $State) + '`', '', 'Quota budget: 300 minutes', "quota_waited_minutes: $($State.quota_waited_minutes)", "quota_budget_resets: $($State.quota_budget_resets)")
    $lines += "StateRoot: $($State.state_root)"
    foreach ($reset in @($State.quota_resets)) { if ($reset) {$lines += "Quota budget reset $($reset.number) at UTC $($reset.at_utc): quota_waited_minutes=0"} }
    if ($State.diagnosis) { $lines += "Diagnosis: $($State.diagnosis)" }
    if ($State.status -eq 'stopped-integrity') { $lines += 'Owner: inspect the worktrees and preserved Engine runs; do not resume this drain.' }
    foreach ($repo in @($State.repos)) { $lines += "Repo: $($repo.repo) | branch: $($repo.branch) | worktree: $($repo.worktree)" }
    $lines += @('', '## WILL BUILD', '', '| Order | Spec | State | Commit SHA | Engine run id | Diagnosis |', '|---|---|---|---|---|---|')
    foreach ($s in @($State.will_build)) { $lines += "| $($s.order) | $($s.spec) | $($s.state) | $($s.commit_sha) | $($s.engine_run_id) | $(([string]$s.diagnosis).Replace('|','/')) |" }
    $lines += @('', '## NEEDS YOU', '')
    foreach ($s in @($State.needs_you)) { $lines += "- $($s.spec): $($s.reason_code) - $($s.reason)" }
    foreach ($s in @($State.will_build | Where-Object state -ne 'committed')) {
        $lines += "- $($s.spec): $($s.state) - $($s.diagnosis)"
        if ($s.engine_run_id) { $lines += '  Engine resume: `powershell.exe -NoProfile -File "' + (Join-Path $script:DrainScripts 'apex-engine.ps1') + '" -Resume ' + $s.engine_run_id + ' -StateRoot "' + $State.state_root + '"`' }
    }
    $lines += @('', '## HOST checks (attended)', '')
    foreach ($s in @($State.will_build | Where-Object state -eq 'committed')) {
        $e = Get-DrainEngine $s $State
        foreach ($check in @($e.plan.host_checks)) { if ($check.text) { $lines += "- $($s.spec): $($check.text)" } }
    }
    $lines += @('', 'Attended wave-3 close-out: inspect preserved Engine runs, perform HOST checks, and close out with the owner. The drain does not execute these checks.')
    $directory = Join-Path $State.project 'docs/drain'
    [void][IO.Directory]::CreateDirectory($directory)
    Write-DrainAtomic (Join-Path $directory ($State.drain_id + '.md')) ($lines -join "`n")
}
function Save-DrainState($State = $script:DrainState, [string]$Directory = $script:DrainDirectory) {
    $State.updated_at = (Get-DrainNow).ToString('o')
    Write-DrainAtomic (Join-Path $Directory 'drain-state.json') ($State | ConvertTo-Json -Depth 100)
    Write-DrainReport $State
}
function Invoke-DrainCheckpoint([string]$Name) {
    Save-DrainState
    if ($script:DrainHooks.AfterCheckpoint) { & $script:DrainHooks.AfterCheckpoint $Name $script:DrainState | Out-Null }
}
function Stop-DrainIntegrity([string]$Reason) {
    $script:DrainState.status = 'stopped-integrity'; $script:DrainState.diagnosis = $Reason
    Save-DrainState
    throw "Drain integrity: $Reason"
}
function Open-DrainLock([string]$Path) { return [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
function ConvertTo-DrainArgument([string]$Value) {
    # CommandLineToArgvW quoting, including backslashes immediately before quotes/end.
    return '"' + [regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1') + '"'
}
function Invoke-DrainGit([string]$Repo, [string[]]$Arguments, [switch]$AllowFailure) {
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName='git.exe';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false,$true)
    $info.Arguments=(@(@('--literal-pathspecs','-c','core.hooksPath=NUL','-c','core.quotepath=false','-C',$Repo)+$Arguments | ForEach-Object {ConvertTo-DrainArgument $_}) -join ' ')
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    try {
        [void]$process.Start();$stderr=$process.StandardError.ReadToEndAsync();$stdout=$process.StandardOutput.ReadToEnd();$process.WaitForExit()
        $r=[pscustomobject]@{exit_code=$process.ExitCode;output=@($stdout.TrimEnd([char[]]@([char]13,[char]10)) -split '\r?\n');raw_output=$stdout;error=$stderr.Result}
    } finally {$process.Dispose()}
    if ($r.exit_code -ne 0 -and -not $AllowFailure) { throw "git failed: $($Arguments -join ' '): $($r.error)" }
    return $r
}
function Get-DrainGit([string]$Repo, [string[]]$Arguments) {
    $r=Invoke-DrainGit $Repo $Arguments
    if ($Arguments -contains '-z') {return $r.raw_output}
    return ($r.output -join "`n")
}
function Get-DrainCommon([string]$Repo) { return Get-DrainRoot (Get-DrainGit $Repo @('rev-parse', '--path-format=absolute', '--git-common-dir')).Trim() }
function Assert-DrainStoredRoots($State) {
    $projectRoot=Get-DrainRoot $State.project
    if (-not (Test-EnginePathEqual $projectRoot $State.project)) {throw 'noncanonical stored project'}
    foreach ($repo in @($State.repos)) {
        $root=Get-DrainRoot $repo.repo
        $expected=Join-Path (Join-Path (Split-Path -Parent $root) ((Split-Path -Leaf $root)+'-wt')) ('drain-'+$State.drain_id)
        if ($repo.branch -cne ('codex/drain-'+$State.drain_id) -or -not (Test-EnginePathEqual (Get-DrainRoot $repo.worktree) $expected) -or -not (Test-EnginePathEqual (Get-DrainRoot $repo.common_dir) (Get-DrainCommon $root))) {throw 'stored repo target outside recorded canonical roots'}
    }
    $changes=Join-Path $projectRoot 'docs/changes'
    foreach ($spec in @($State.will_build)) {
        $path=Get-DrainRoot $spec.path
        if (-not (Test-EnginePathEqual (Split-Path -Parent $path) $changes) -or $spec.digest -notmatch '^[0-9a-f]{64}$' -or @($State.repos | Where-Object {Test-EnginePathEqual $_.common_dir (Get-DrainCommon (Get-DrainRoot $spec.repo))}).Count -ne 1) {throw 'stored spec target outside recorded canonical roots'}
        if ($spec.engine_run_id -and $spec.engine_run_id -notmatch '^[0-9a-f]{32}$') {throw 'invalid stored Engine run identity'}
    }
}
function Test-DrainEngineLive($Engine, [string]$Root) {
    if (-not $Engine) { return $false }
    if (Test-DrainAlive $Engine.engine_owner) { return $true }
    $checks = @($Engine.spec_acceptance.checks)
    $rows = @(Read-EngineLedgerRows (Join-Path $Root 'progress/codex-run-ledger.jsonl'))
    foreach ($task in @($Engine.tasks)) {
        $checks += @($task.acceptance)
        foreach ($attempt in @($task.attempts)) {
            if (Test-DrainAlive ([pscustomobject]@{pid=$attempt.child_pid;start_time=$attempt.child_start_time})) { return $true }
            foreach ($row in $rows) {
                if ($row.spec -ceq $Engine.spec.name -and $row.task -ceq $task.id -and $row.worktree -and $attempt.worktree -and (Test-EnginePathEqual $row.worktree $attempt.worktree) -and (Test-EngineLedgerRowLive $row)) { return $true }
            }
        }
    }
    foreach ($check in $checks) { if ($check -and (Test-DrainAlive ([pscustomobject]@{pid=$check.child_pid;start_time=$check.child_start_time}))) { return $true } }
    return $false
}
function Find-DrainCorrelation($Spec, $State = $script:DrainState) {
    if (-not $Spec.launching) { return @() }
    $found = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $State.state_root -Directory)) {
        $path = Join-Path $directory.FullName 'engine-state.json'
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $e = Read-DrainJson $path
        $wt = @($State.repos | Where-Object { Test-EnginePathEqual $_.common_dir (Get-DrainCommon $Spec.repo) })[0].worktree
        if ([datetime]$e.created_at -ge ([datetime]$Spec.launching.at_utc).AddSeconds(-5) -and (Test-EnginePathEqual $e.spec.original_path $Spec.path) -and (Test-EnginePathEqual $e.repo $wt)) {
            if ($e.run_id -notmatch '^[0-9a-f]{32}$' -or $directory.Name -cne $e.run_id) {throw 'invalid correlated Engine run identity'}
            $found += $e
        }
    }
    return $found
}
function Test-DrainReservationLive($State) {
    if ($State.status -eq 'complete') { return $false }
    if (Test-DrainAlive $State.owner) { return $true }
    if ($State.status -eq 'launching' -and (Test-DrainAlive $State.start)) { return $true }
    foreach ($s in @($State.will_build)) {
        if (Test-DrainAlive $s.engine_child) { return $true }
        $engines = if ($s.engine_run_id) { @(Get-DrainEngine $s $State) } else { @(Find-DrainCorrelation $s $State) }
        foreach ($e in $engines) { if (Test-DrainEngineLive $e $State.state_root) { return $true } }
    }
    return $false
}
function Assert-DrainReservations([string]$Root, [string]$Exclude) {
    $abandoned=@()
    foreach ($dir in @(Get-ChildItem -LiteralPath (Join-Path $Root 'drains') -Directory)) {
        $path = Join-Path $dir.FullName 'drain-state.json'
        if (-not (Test-Path -LiteralPath $path)) {
            $reservation=Join-Path $dir.FullName 'reservation.json'
            if (-not (Test-Path -LiteralPath $reservation)) {throw 'unreadable drain reservation'}
            $s=Read-DrainJson $reservation
            if ($s.drain_id -cne $dir.Name -or -not (Test-EnginePathEqual $s.state_root $Root)) {throw 'invalid drain reservation'}
            if ((Test-DrainAlive $s.start) -or (Test-DrainAlive $s.owner)) {throw "StateRoot has live drain $($s.drain_id)"}
            $now=(Get-DrainNow).ToString('o')
            foreach ($entry in @{status='launch-failed';diagnosis='abandoned launcher';owner=$null;started_at=$now;updated_at=$now;quota_waited_minutes=0;quota_budget_resets=0;quota_resets=@();will_build=@();needs_you=@();repos=@()}.GetEnumerator()) {
                $s | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
            }
            Save-DrainState $s $dir.FullName
        }
        $s = Read-DrainJson $path
        if ($s.drain_id -eq $Exclude) { continue }
        if (Test-DrainReservationLive $s) { throw "StateRoot has live drain $($s.drain_id)" }
        if ($s.status -eq 'launching') { $abandoned += [pscustomobject]@{state=$s;directory=$dir.FullName} }
    }
    foreach ($candidate in $abandoned) {$candidate.state.status='launch-failed';$candidate.state.diagnosis='abandoned launcher';Save-DrainState $candidate.state $candidate.directory}
}
function Open-DrainRepoLocks($State) {
    $locks = @()
    try {
        $commonDirectories=[string[]]@($State.repos | ForEach-Object {$_.common_dir})
        [Array]::Sort($commonDirectories,[StringComparer]::OrdinalIgnoreCase)
        foreach ($commonDirectory in $commonDirectories) {
            $repo=@($State.repos | Where-Object common_dir -eq $commonDirectory)[0]
            try { $locks += Open-DrainLock (Join-Path $repo.common_dir 'apex-drain.lock') } catch { throw 'build repo locked' }
            $record = Join-Path $repo.common_dir 'apex-drain-owner.json'
            if (Test-Path -LiteralPath $record) {
                try {
                    $owner = Read-DrainJson $record
                    if (-not $owner.state_root -or $owner.drain_id -notmatch '^\d{8}-\d{6}-[0-9a-f]{6}$') { throw 'invalid owner' }
                    [void](Get-DrainRoot $owner.state_root)
                    if ((Test-EnginePathEqual $owner.state_root $State.state_root) -and $owner.drain_id -eq $State.drain_id) { continue }
                    $other = Read-DrainJson (Join-Path $owner.state_root "drains/$($owner.drain_id)/drain-state.json")
                    if (-not $other.status) { throw 'invalid state' }
                } catch { throw 'build repo owned by unknown drain' }
                if ($other.status -ne 'complete') { throw "build repo owned by drain $($owner.drain_id)" }
            }
        }
        return ,$locks
    } catch { foreach ($l in $locks) { $l.Dispose() }; throw }
}
function Set-DrainRepoOwnership {
    foreach ($r in $script:DrainState.repos) { Write-DrainAtomic (Join-Path $r.common_dir 'apex-drain-owner.json') (@{state_root=$script:DrainState.state_root;drain_id=$script:DrainState.drain_id} | ConvertTo-Json) }
}
function Get-DrainDigest([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 255 -and $bytes[1] -eq 254) -or ($bytes[0] -eq 254 -and $bytes[1] -eq 255))) { throw 'UTF-16/32 spec is not permitted' }
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 254 -and $bytes[3] -eq 255) { throw 'UTF-32 spec is not permitted' }
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { $offset = 3 }
    $text = [Text.UTF8Encoding]::new($false,$true).GetString($bytes,$offset,$bytes.Length-$offset).Replace("`r`n","`n").Replace("`r","`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Initialize-DrainRepos {
    Set-DrainRepoOwnership
    foreach ($r in $script:DrainState.repos) {
        if ($r.state -eq 'ready') { continue }
        if (@($r.ref_snapshot -split "`n" | Where-Object { $_ -like "refs/heads/$($r.branch) *" }).Count) { Stop-DrainIntegrity 'drain branch existed in start ref snapshot' }
        if ($r.state -ne 'creating') { $r.state = 'creating'; Save-DrainState }
        $list = Get-DrainGit $r.repo @('worktree','list','--porcelain')
        $matching = $null
        foreach ($block in ($list -split "`n`n")) {
            $pathMatch = [regex]::Match($block,'(?m)^worktree (.+)$')
            if ($pathMatch.Success -and (Test-EnginePathEqual $pathMatch.Groups[1].Value $r.worktree)) { $matching = $block }
        }
        $branchExists = (Invoke-DrainGit $r.repo @('show-ref','--verify',"refs/heads/$($r.branch)") -AllowFailure).exit_code -eq 0
        if ($matching) {
            if ($matching -notmatch ('(?m)^branch ' + [regex]::Escape('refs/heads/' + $r.branch) + '$') -or (Get-DrainCommon $r.worktree) -ne $r.common_dir) { Stop-DrainIntegrity 'non-matching drain worktree' }
        } else {
            if (Test-Path -LiteralPath $r.worktree) { Stop-DrainIntegrity 'drain worktree path occupied' }
            if ($branchExists) { [void](Invoke-DrainGit $r.repo @('worktree','add',$r.worktree,$r.branch)) }
            else { [void](Invoke-DrainGit $r.repo @('worktree','add','-b',$r.branch,$r.worktree,'HEAD')) }
            Invoke-DrainCheckpoint 'repo-creating'
        }
        $r.state = 'ready'; Save-DrainState
    }
}
function Assert-DrainHead($Spec, $Repo) {
    if ((Get-DrainGit $Repo.worktree @('rev-parse','HEAD')).Trim() -ne $Spec.prelaunch_head -or (Get-DrainGit $Repo.worktree @('symbolic-ref','-q','HEAD')).Trim() -ne ('refs/heads/' + $Repo.branch)) { Stop-DrainIntegrity "HEAD or symbolic branch moved for $($Spec.spec)" }
}
function Get-DrainManifest($Engine) { return @($Engine.plan.waves | ForEach-Object { $_.tasks | ForEach-Object { $_.files | ForEach-Object { $_.path } } } | Sort-Object -Unique) }
function Restore-DrainManifest($Spec, $Repo, $Engine) {
    Assert-DrainHead $Spec $Repo
    $paths = @(Get-DrainManifest $Engine)
    foreach ($path in $paths) {
        $unsafe = Test-EngineWorkingPathSafety $Repo.worktree $path
        if ($unsafe) { Stop-DrainIntegrity "unsafe manifest path ${path}: $unsafe" }
    }
    foreach ($path in $paths) {
        $entry = Invoke-DrainGit $Repo.worktree @('rev-parse','--verify',"HEAD:$path") -AllowFailure
        if ($entry.exit_code -eq 0) { [void](Invoke-DrainGit $Repo.worktree @('restore','--source=HEAD','--staged','--worktree','--',$path)) }
        else {
            [void](Invoke-DrainGit $Repo.worktree @('update-index','--force-remove','--',$path))
            $full = Join-Path $Repo.worktree $path
            if ([IO.File]::Exists($full)) { [IO.File]::Delete($full) }
        }
    }
    Assert-DrainHead $Spec $Repo
    if ((Get-DrainGit $Repo.worktree @('status','--porcelain','-z','--ignored','-uall')) -cne $Spec.prelaunch_status) { Stop-DrainIntegrity "recovery residue for $($Spec.spec)" }
    $Spec.state = $Spec.recovery_outcome; Save-DrainState
}
function Reject-DrainSpec($Spec, $Repo, $Engine, [string]$Reason, [string]$Outcome = 'parked') {
    $Spec.rejection_reason = $Reason; $Spec.diagnosis = $Reason; $Spec.recovery_outcome = $Outcome; $Spec.state = 'recovering'
    Invoke-DrainCheckpoint 'recovery-started'
    Restore-DrainManifest $Spec $Repo $Engine
}
function Test-DrainBlobIdentity($Repo, $Engine, [switch]$Head) {
    foreach ($path in @($Engine.handoff.journaled_paths)) {
        $expected = Invoke-DrainGit $Repo.worktree @('rev-parse','--verify',"$($Engine.integration.tip):$path") -AllowFailure
        if ($Head) { $actual = Invoke-DrainGit $Repo.worktree @('rev-parse','--verify',"HEAD:$path") -AllowFailure }
        else {
            $unsafe = Test-EngineWorkingPathSafety $Repo.worktree $path
            if ($unsafe) { Stop-DrainIntegrity "unsafe identity path ${path}: $unsafe" }
            $full = Join-Path $Repo.worktree $path
            $actual = if ([IO.File]::Exists($full)) { Invoke-DrainGit $Repo.worktree @('hash-object','--',$full) } else { [pscustomobject]@{exit_code=1;output=@()} }
        }
        if (($expected.exit_code -eq 0) -ne ($actual.exit_code -eq 0)) { return $false }
        if ($expected.exit_code -eq 0 -and ($expected.output -join '') -cne ($actual.output -join '')) { return $false }
    }
    return $true
}
function Get-DrainStatusRecords([string]$Status) {
    $parts=$Status.Split([char]0)
    for ($i=0;$i -lt $parts.Count;$i++) {
        $line=$parts[$i]
        if (-not $line) {continue}
        $paths=@($line.Substring(3));$record=$line
        if ($line.Substring(0,2) -match '[RC]') {
            $i++;$paths+= $parts[$i];$record += "`0"+$parts[$i]
        }
        [pscustomobject]@{record=$record;paths=$paths}
    }
}
function Test-DrainResidue($Spec, $Repo, $Engine) {
    $baseline = @(Get-DrainStatusRecords $Spec.prelaunch_status | ForEach-Object {$_.record})
    foreach ($row in @(Get-DrainStatusRecords (Get-DrainGit $Repo.worktree @('status','--porcelain','-z','--ignored','-uall')))) {
        if ($baseline -ccontains $row.record) { continue }
        foreach ($path in $row.paths) {
            if (@($Engine.handoff.journaled_paths) -cnotcontains $path) { return $false }
        }
    }
    return $true
}
function Recognize-DrainCommit($Spec, $Repo, $Engine) {
    $head = (Get-DrainGit $Repo.worktree @('rev-parse','HEAD')).Trim()
    $message = Get-DrainGit $Repo.worktree @('log','-1','--format=%B')
    if ($message -notmatch ('(?m)^Drain-Spec: ' + [regex]::Escape($Spec.spec) + '$') -or $message -notmatch ('(?m)^Engine-Run: ' + [regex]::Escape($Spec.engine_run_id) + '$')) { return $false }
    $parents = (Get-DrainGit $Repo.worktree @('rev-list','--parents','-n','1',$head)).Trim() -split ' '
    $changed = @((Get-DrainGit $Repo.worktree @('diff-tree','--no-commit-id','--name-only','-z','-r',$head)) -split "`0" | Where-Object { $_ } | Sort-Object)
    $journal = @($Engine.handoff.journaled_paths | Sort-Object)
    if ($parents.Count -ne 2 -or $parents[1] -ne $Spec.prelaunch_head -or ($changed -join "`0") -cne ($journal -join "`0") -or -not (Test-DrainBlobIdentity $Repo $Engine -Head)) { Stop-DrainIntegrity 'trailer commit identity mismatch' }
    $Spec.commit_sha = $head; $Spec.state = 'committed'; Save-DrainState
    return $true
}
function Complete-DrainSpec($Spec, $Repo, $Engine) {
    $Spec.state = 'finalizing'; Save-DrainState
    Assert-DrainHead $Spec $Repo
    if (-not (Test-DrainResidue $Spec $Repo $Engine)) { Reject-DrainSpec $Spec $Repo $Engine 'fence-residue'; Stop-DrainIntegrity 'outside-manifest residue' }
    $d1 = @(& powershell.exe -NoProfile -File (Join-Path $script:DrainScripts 'tree-pin.ps1') -Digest -Worktree $Repo.worktree)[-1]
    if ($LASTEXITCODE -ne 0) { Stop-DrainIntegrity 'tree digest failed' }
    $Spec | Add-Member -NotePropertyName fence_d1 -NotePropertyValue $d1 -Force
    Save-DrainState
    & powershell.exe -NoProfile -File (Join-Path $script:DrainScripts 'apex-baseline-check.ps1') -Worktree $Repo.worktree -Full | Out-Host
    $fenceCode = $LASTEXITCODE
    Assert-DrainHead $Spec $Repo
    $d2 = @(& powershell.exe -NoProfile -File (Join-Path $script:DrainScripts 'tree-pin.ps1') -Digest -Worktree $Repo.worktree)[-1]
    if ($LASTEXITCODE -ne 0) { Stop-DrainIntegrity 'tree digest failed' }
    $Spec | Add-Member -NotePropertyName fence_d2 -NotePropertyValue $d2 -Force
    Save-DrainState
    if (-not (Test-DrainResidue $Spec $Repo $Engine)) { Reject-DrainSpec $Spec $Repo $Engine 'fence-residue'; Stop-DrainIntegrity 'outside-manifest residue' }
    if ($d1 -cne $d2) { Reject-DrainSpec $Spec $Repo $Engine 'fence-mutated-tree'; return }
    if ($fenceCode -ne 0) { Reject-DrainSpec $Spec $Repo $Engine 'fence-red'; return }
    Assert-DrainHead $Spec $Repo
    if (-not (Test-DrainBlobIdentity $Repo $Engine)) { Reject-DrainSpec $Spec $Repo $Engine 'verify-identity-mismatch'; return }
    $paths = @($Engine.handoff.journaled_paths)
    foreach ($path in $paths) {
        if ([IO.File]::Exists((Join-Path $Repo.worktree $path))) { [void](Invoke-DrainGit $Repo.worktree @('add','-f','--',$path)) }
        else { [void](Invoke-DrainGit $Repo.worktree @('rm','--cached','--',$path)) }
    }
    $message = Join-Path $script:DrainDirectory 'commit-message.txt'
    Write-DrainAtomic $message ("Drain: $($Spec.spec)`n`nDrain-Spec: $($Spec.spec)`nEngine-Run: $($Spec.engine_run_id)`n")
    Assert-DrainHead $Spec $Repo
    [void](Invoke-DrainGit $Repo.worktree (@('commit','--no-verify','-F',$message,'--') + $paths))
    Invoke-DrainCheckpoint 'commit-created'
    if (-not (Test-DrainBlobIdentity $Repo $Engine -Head)) { Stop-DrainIntegrity 'post-commit identity mismatch' }
    $Spec.commit_sha = (Get-DrainGit $Repo.worktree @('rev-parse','HEAD')).Trim(); $Spec.state = 'committed'; Save-DrainState
}
function Wait-DrainQuiescence($Spec, [switch]$PreserveState) {
    if (-not $PreserveState) {$Spec.state='quiescing';Save-DrainState}
    $waited = 0.0
    while ($true) {
        $e = Get-DrainEngine $Spec
        # Restarted workers wait for the Engine itself without a time limit.
        # Only liveness remaining after its exit consumes the quiescence budget.
        if ((Test-DrainAlive $e.engine_owner) -or (-not $e -and (Test-DrainAlive $Spec.engine_child))) {
            Wait-DrainMinutes 0.5; $waited=0.0; continue
        }
        if (-not (Test-DrainAlive $Spec.engine_child) -and -not (Test-DrainEngineLive $e $script:DrainState.state_root)) {
            # The owner can finish between the state read and the identity scan.
            # Refresh after proving quiescence so a stale running snapshot cannot
            # cause a Resume of a run that has just completed.
            $e=Get-DrainEngine $Spec
            if (-not (Test-DrainEngineLive $e $script:DrainState.state_root)) {return $e}
        }
        if ($waited -ge 255) {
            $script:DrainState.status = 'stopped-children-alive'; $Spec.diagnosis = 'recorded children or ledger rows remain alive'; Save-DrainState
            throw 'children still alive; no process killed'
        }
        Wait-DrainMinutes 0.5; $waited += 0.5
    }
}
function Start-DrainEngine($Spec, $Repo, [switch]$ResumeEngine) {
    $parameters = @{StateRoot=$script:DrainState.state_root}
    if ($ResumeEngine) { $parameters.Resume = $Spec.engine_run_id }
    else {
        $parameters.SpecPath = $Spec.path; $parameters.Repo = $Repo.worktree; $parameters.AcceptTimeoutMin = 240
        if ($env:APEX_DRAIN_TEST_MODE -ceq '1' -and $script:DrainState.codex_executable) {
            $parameters.CodexExecutable = $script:DrainState.codex_executable
            $parameters.CodexExecutableArgumentPrefix = @($script:DrainState.codex_executable_argument_prefix)
        }
    }
    $json = ($parameters | ConvertTo-Json -Depth 10 -Compress).Replace("'","''")
    $engine = (Join-Path $script:DrainScripts 'apex-engine.ps1').Replace("'","''")
    $log = Join-Path $script:DrainDirectory ($Spec.spec + '.engine.log')
    $logLiteral=$log.Replace("'","''")
    # The child owns its log stream. Parent-owned redirect pumps would survive an
    # in-process test interruption and can retain the file across worker recovery.
    $command = "`$p=@{};`$o='$json'|ConvertFrom-Json;foreach(`$v in `$o.PSObject.Properties){`$p[`$v.Name]=`$v.Value};if(`$p.ContainsKey('CodexExecutableArgumentPrefix')){`$p.CodexExecutableArgumentPrefix=[string[]]`$p.CodexExecutableArgumentPrefix};& '$engine' @p *> '$logLiteral';exit `$LASTEXITCODE"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $child = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru
    $Spec.engine_child = Get-DrainIdentity $child.Id
    $Spec.state = 'engine-running'; Invoke-DrainCheckpoint 'engine-launched'
    $child.WaitForExit()
    Invoke-DrainCheckpoint 'engine-complete'
}
function Invoke-DrainSpec($Spec, $Repo) {
    # Admission excludes this drain's identities because this worker waits for
    # them, including identities retained by specs with durable final outcomes.
    if ($Spec.engine_run_id -or $Spec.engine_child) {[void](Wait-DrainQuiescence $Spec -PreserveState)}
    if (@('committed','parked','skipped','spec-changed') -contains $Spec.state) { return }
    if ($Spec.engine_run_id) {
        $e = Get-DrainEngine $Spec
        if ($Spec.state -eq 'recovering') { Restore-DrainManifest $Spec $Repo $e; return }
        if (Recognize-DrainCommit $Spec $Repo $e) { return }
        if ($Spec.state -eq 'finalizing') {
            if ($Spec.rejection_reason) { Stop-DrainIntegrity 'finalizing has persisted rejection' }
            Complete-DrainSpec $Spec $Repo $e; return
        }
    }
    if ($Spec.state -eq 'pending') {
        foreach ($name in @($Spec.prerequisites)) {
            $dependency = @($script:DrainState.will_build | Where-Object spec -eq $name)
            if ($dependency.Count -and $dependency[0].state -ne 'committed') { $Spec.state='skipped';$Spec.diagnosis="blocked by $name";Save-DrainState;return }
        }
        if ((Get-DrainDigest $Spec.path) -cne $Spec.digest) { $Spec.state='spec-changed';$Spec.diagnosis='sorter digest changed';Save-DrainState;return }
        if (Get-DrainGit $Repo.worktree @('status','--porcelain','-z','-uno')) { Stop-DrainIntegrity 'dirty tracked prelaunch baseline' }
        $Spec.prelaunch_head = (Get-DrainGit $Repo.worktree @('rev-parse','HEAD')).Trim()
        $Spec.prelaunch_status = Get-DrainGit $Repo.worktree @('status','--porcelain','-z','--ignored','-uall')
        $Spec.launching = [pscustomobject]@{at_utc=(Get-DrainNow).ToString('o')};$Spec.state='launching'
        Invoke-DrainCheckpoint 'pre-engine-start'
        Start-DrainEngine $Spec $Repo
    }
    if (-not $Spec.engine_run_id) {
        $minutes = 0
        do {
            $matches = @(Find-DrainCorrelation $Spec)
            if ($matches.Count -gt 1) { Stop-DrainIntegrity "ambiguous Engine correlation for $($Spec.spec)" }
            if ($matches.Count -eq 1) { $Spec.engine_run_id=$matches[0].run_id;Save-DrainState;break }
            if ($Spec.engine_child) {
                if (Test-DrainAlive $Spec.engine_child) { Wait-DrainMinutes 0.5; continue }
                $log = Join-Path $script:DrainDirectory ($Spec.spec + '.engine.log')
                $reason = if (Test-Path -LiteralPath $log) { @([IO.File]::ReadAllLines($log) | Where-Object { $_ -like '*Engine refused:*' }) -join ' ' } else { '' }
                $Spec.state='parked';$Spec.diagnosis= $(if ($reason) {$reason} else {'Engine refused: no correlated state'});Save-DrainState;return
            }
            if ($minutes -ge 15) { Stop-DrainIntegrity "no Engine correlation for $($Spec.spec) after 15 minutes" }
            Wait-DrainMinutes 0.5; $minutes += 0.5
        } while ($true)
    }
    while ($true) {
        $e = Wait-DrainQuiescence $Spec
        if ($e.spec.original_digest -cne $Spec.digest) { Reject-DrainSpec $Spec $Repo $e 'correlated original digest changed' 'spec-changed';return }
        switch ($e.status) {
            'complete' { Complete-DrainSpec $Spec $Repo $e; return }
            'paused' {
                if ($e.diagnosis -cne 'quota or rate limit') { Reject-DrainSpec $Spec $Repo $e $e.diagnosis;return }
                $Spec.state='quota-wait';Save-DrainState
                if ($script:DrainState.quota_waited_minutes -ge 300) { $script:DrainState.status='stopped-quota';Save-DrainState;throw 'quota budget exhausted' }
                $schedule = @(15,30,60,60,60,75);$sum=0;$delay=0
                foreach ($item in $schedule) { $sum += $item; if ($sum -gt $script:DrainState.quota_waited_minutes) { $delay=$sum-$script:DrainState.quota_waited_minutes;break } }
                Wait-DrainMinutes $delay
                $script:DrainState.quota_waited_minutes += $delay;Save-DrainState
                [void](Wait-DrainQuiescence $Spec)
                Start-DrainEngine $Spec $Repo -ResumeEngine
            }
            'running' {
                if ($Spec.engine_resume_attempted) { Reject-DrainSpec $Spec $Repo $e 'engine resume did not converge';return }
                $Spec.engine_resume_attempted=[pscustomobject]@{at_utc=(Get-DrainNow).ToString('o')}
                Invoke-DrainCheckpoint 'engine-resume-issued'
                Start-DrainEngine $Spec $Repo -ResumeEngine
            }
            default { Reject-DrainSpec $Spec $Repo $e $(if ($e.status -eq 'awaiting-review') { 'attended review required' } else { [string]$e.diagnosis }); return }
        }
    }
}
function Invoke-DrainWorker {
    $lock = $null; $repoLocks = @(); $acquired = $false
    for ($retry=0;$retry -le 20;$retry++) {
        try { $lock=Open-DrainLock (Join-Path $script:DrainState.state_root 'drains/drain.lock');$acquired=$true;break } catch { if ($retry -lt 20) { Wait-DrainMinutes (0.5/60) } }
    }
    if (-not $acquired) {
        $script:DrainState=Read-DrainJson (Join-Path $script:DrainDirectory 'drain-state.json')
        if ($script:DrainState.status -eq 'launching') { $script:DrainState.status='launch-failed';$script:DrainState.diagnosis='drain lock busy';Save-DrainState }
        throw 'drain lock busy'
    }
    $advisory = Join-Path $script:DrainState.state_root 'drains/drain.lock.owner.json'
    try {
        $script:DrainState=Read-DrainJson (Join-Path $script:DrainDirectory 'drain-state.json')
        if ($script:DrainState.status -ne 'launching') { throw 'late worker refused: state is not launching' }
        $repoLocks=Open-DrainRepoLocks $script:DrainState
        Assert-DrainReservations $script:DrainState.state_root $script:DrainState.drain_id
        $script:DrainState.owner=Get-DrainIdentity $PID;$script:DrainState.status='running';Save-DrainState
        Write-DrainAtomic $advisory (@{drain_id=$script:DrainState.drain_id;pid=$script:DrainState.owner.pid;start_time=$script:DrainState.owner.start_time} | ConvertTo-Json)
        Initialize-DrainRepos
        foreach ($s in @($script:DrainState.will_build | Sort-Object order)) {
            $common=Get-DrainCommon $s.repo;$repo=@($script:DrainState.repos | Where-Object common_dir -eq $common)[0]
            Invoke-DrainSpec $s $repo
        }
        $script:DrainState.status='complete';Save-DrainState
        foreach ($r in $script:DrainState.repos) {
            $path=Join-Path $r.common_dir 'apex-drain-owner.json'
            $owner=Read-DrainJson $path
            if ($owner.drain_id -eq $script:DrainState.drain_id -and (Test-EnginePathEqual $owner.state_root $script:DrainState.state_root)) { [IO.File]::Delete($path) }
        }
    } finally {
        if (Test-Path -LiteralPath $advisory) {
            $a=Read-DrainJson $advisory
            if ($a.drain_id -eq $script:DrainState.drain_id) { [IO.File]::Delete($advisory) }
        }
        foreach ($l in $repoLocks) { $l.Dispose() };$lock.Dispose()
    }
}
function Launch-DrainWorker {
    $arguments=@{Run=$script:DrainState.drain_id;StateRoot=$script:DrainState.state_root}
    if ($script:DrainHooks.LaunchWorker) { & $script:DrainHooks.LaunchWorker $arguments | Out-Host;return }
    $ps='powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $script:DrainScript + '" -Run ' + $script:DrainState.drain_id + ' -StateRoot "' + $script:DrainState.state_root + '"'
    $log=Join-Path $script:DrainDirectory 'worker.log'
    $command='cmd.exe /c "' + $ps + ' > "' + $log + '" 2>&1"'
    $result=Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$command}
    if ($result.ReturnValue -ne 0) { throw "worker creation failed: $($result.ReturnValue)" }
}
function Confirm-DrainWorker {
    for ($poll=0;$poll -le 120;$poll++) {
        $s=Read-DrainJson (Join-Path $script:DrainDirectory 'drain-state.json')
        if ($s.drain_id -cne $script:DrainState.drain_id) {throw 'confirmation state drain id mismatch'}
        if (Test-DrainAlive $s.owner) { return $true }
        if ($s.owner -and $s.owner.pid -gt 0 -and $s.owner.start_time -and ($s.status -eq 'complete' -or $s.status -like 'stopped-*')) { return $true }
        $path=Join-Path $s.state_root 'drains/drain.lock.owner.json'
        if (Test-Path -LiteralPath $path) { $a=Read-DrainJson $path;if ($a.drain_id -eq $s.drain_id -and (Test-DrainAlive $a)) { return $true } }
        if ($s.status -eq 'launch-failed') { return $false }
        if ($poll -lt 120) { Wait-DrainMinutes (0.5/60) }
    }
    return $false
}

try {
    if ($PSBoundParameters.ContainsKey('TestHooks') -and $env:APEX_DRAIN_TEST_MODE -cne '1') { throw 'TestHooks require APEX_DRAIN_TEST_MODE=1' }
    if (-not $script:DrainHooks) { $script:DrainHooks=@{} }
    foreach ($key in $script:DrainHooks.Keys) { if ($key -notin @('LaunchWorker','UtcNow','SleepMinutes','ChildAlive','AfterCheckpoint','CodexExecutable','CodexExecutableArgumentPrefix')) { throw "unknown TestHooks key: $key" } }
    if (($PSBoundParameters.ContainsKey('Run') -and -not $Run) -or ($PSBoundParameters.ContainsKey('Resume') -and -not $Resume)) {throw 'drain id is required'}
    if ($PSBoundParameters.ContainsKey('StateRoot') -and -not $Run) {throw 'StateRoot is worker-only'}
    if (($Run -and ($Project -or $Resume)) -or (-not $Run -and -not $Resume -and -not $Project) -or ($StateRoot -and -not $Run)) { throw 'mixed or missing drain mode; StateRoot is worker-only' }
    if ($Run -or $Resume) { $id=if ($Run) {$Run} else {$Resume};if ($id -notmatch '^\d{8}-\d{6}-[0-9a-f]{6}$') { throw 'invalid drain id' } }
    if (-not $Run) { $StateRoot=if ($env:APEX_STATE_DIR) {$env:APEX_STATE_DIR} else {Join-Path $env:LOCALAPPDATA 'apex'} }
    $StateRoot=Get-DrainRoot $StateRoot;Assert-DrainOutside $StateRoot
    if ($PSBoundParameters.ContainsKey('Project')) { $Project=Get-DrainRoot $Project;if (-not (Test-Path -LiteralPath $Project -PathType Container)) { throw 'Project does not exist' } }
    if ($Run -or $Resume) {
        $script:DrainDirectory=Join-Path $StateRoot "drains/$id"
        $script:DrainState=Read-DrainJson (Join-Path $script:DrainDirectory 'drain-state.json')
        if ($script:DrainState.schema_version -ne 1 -or $script:DrainState.drain_id -ne $id -or -not (Test-EnginePathEqual $script:DrainState.state_root $StateRoot)) { throw 'invalid stored drain roots or identity' }
        Assert-DrainStoredRoots $script:DrainState
        if ($Project -and -not (Test-EnginePathEqual $Project $script:DrainState.project)) { throw 'Resume Project differs from stored project' }
        if ($Run) { Invoke-DrainWorker;exit 0 }
    } else {
        $planText=@(& powershell.exe -NoProfile -File (Join-Path $PSScriptRoot 'apex-drain-plan.ps1') -Project $Project -Json)
        if ($LASTEXITCODE -ne 0) { throw ($planText -join "`n") }
        $plan=($planText -join "`n") | ConvertFrom-Json
        if ($plan.schema_version -ne 1) { throw 'unsupported sorter schema' }
        $id=(Get-DrainNow).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)
        $specs=@(foreach ($s in $plan.will_build) {
            [pscustomobject][ordered]@{order=$s.order;spec=$s.spec;path=$s.path;repo=$s.repo;digest=$s.digest;prerequisites=@($s.prerequisites);state='pending';diagnosis=$null;rejection_reason=$null;recovery_outcome=$null;launching=$null;engine_child=$null;engine_run_id=$null;engine_resume_attempted=$null;prelaunch_head=$null;prelaunch_status=$null;commit_sha=$null}
        })
        $repos=@();$seen=@{}
        foreach ($s in $specs) {
            $common=Get-DrainCommon $s.repo
            if ($seen.ContainsKey($common)) { continue };$seen[$common]=$true
            $repos += [pscustomobject]@{repo=$s.repo;common_dir=$common;branch="codex/drain-$id";worktree=(Join-Path (Join-Path (Split-Path -Parent $s.repo) ((Split-Path -Leaf $s.repo)+'-wt')) "drain-$id");state='pending';ref_snapshot=(Get-DrainGit $s.repo @('for-each-ref','--format=%(refname) %(objectname)'))}
        }
        $script:DrainState=[pscustomobject][ordered]@{schema_version=1;drain_id=$id;project=$Project;state_root=$StateRoot;started_at=(Get-DrainNow).ToString('o');updated_at=(Get-DrainNow).ToString('o');status='launching';start=(Get-DrainIdentity $PID);owner=$null;quota_waited_minutes=0;quota_budget_resets=0;quota_resets=@();will_build=$specs;needs_you=@($plan.needs_you);repos=$repos;diagnosis=$null;codex_executable=$script:DrainHooks.CodexExecutable;codex_executable_argument_prefix=@($script:DrainHooks.CodexExecutableArgumentPrefix)}
        $script:DrainDirectory=Join-Path $StateRoot "drains/$id"
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $StateRoot 'drains'))
    try { $lock=Open-DrainLock (Join-Path $StateRoot 'drains/drain.lock') } catch { throw 'StateRoot drain lock busy' }
    $repoLocks=@()
    try {
        Assert-DrainReservations $StateRoot $(if ($Resume) {$id} else {''})
        if ($Resume) {
            $script:DrainState=Read-DrainJson (Join-Path $script:DrainDirectory 'drain-state.json')
            $s=$script:DrainState
            if (Test-DrainAlive $s.owner) { throw 'drain has live worker' }
            if ($s.status -eq 'launching') {
                if (Test-DrainAlive $s.start) { throw 'drain has live start identity' }
                $s.status='launch-failed';$s.diagnosis='abandoned launcher';Save-DrainState
            }
            if ($s.status -notin @('running','launch-failed','stopped-quota','stopped-children-alive')) { throw "cannot resume $($s.status); owner must inspect" }
        }
        $repoLocks=Open-DrainRepoLocks $script:DrainState
        if (-not $Resume) {
            foreach ($r in $script:DrainState.repos) { $r.ref_snapshot=Get-DrainGit $r.repo @('for-each-ref','--format=%(refname) %(objectname)') }
            [void][IO.Directory]::CreateDirectory($script:DrainDirectory)
            $reservation=Join-Path $script:DrainDirectory 'reservation.json'
            $stream=[IO.File]::Open($reservation,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            try { $bytes=[Text.Encoding]::UTF8.GetBytes((@{schema_version=1;drain_id=$id;state_root=$StateRoot;project=$Project;start=$script:DrainState.start} | ConvertTo-Json));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true) } finally {$stream.Dispose()}
        } elseif ($script:DrainState.status -eq 'stopped-quota') {
            $script:DrainState.quota_waited_minutes=0;$script:DrainState.quota_budget_resets++
            if (-not $script:DrainState.PSObject.Properties['quota_resets']) {$script:DrainState | Add-Member -NotePropertyName quota_resets -NotePropertyValue @()}
            $script:DrainState.quota_resets=@($script:DrainState.quota_resets)+[pscustomobject]@{number=$script:DrainState.quota_budget_resets;at_utc=(Get-DrainNow).ToString('o')}
        }
        $script:DrainState.status='launching';$script:DrainState.start=Get-DrainIdentity $PID;$script:DrainState.diagnosis=$null
        Save-DrainState
        Set-DrainRepoOwnership
    } catch {
        if ($script:DrainDirectory -and (Test-Path -LiteralPath (Join-Path $script:DrainDirectory 'drain-state.json'))) { $script:DrainState.diagnosis=$_.Exception.Message;Save-DrainState }
        elseif ($_.Exception.Message -like 'build repo owned*' -or $_.Exception.Message -eq 'build repo locked') { $script:DrainState.status='launch-failed';$script:DrainState.diagnosis=$_.Exception.Message;Write-DrainReport $script:DrainState }
        throw
    } finally {foreach ($l in $repoLocks) {$l.Dispose()};$lock.Dispose()}
    Write-Output 'WILL BUILD'
    foreach ($s in $script:DrainState.will_build) { Write-Output "$($s.order). $($s.spec)" }
    Write-Output 'NEEDS YOU'
    foreach ($s in $script:DrainState.needs_you) { Write-Output "$($s.spec): $($s.reason)" }
    try { Launch-DrainWorker } catch {
        $launchReason=$_.Exception.Message;$failureLock=$null
        try {$failureLock=Open-DrainLock (Join-Path $StateRoot 'drains/drain.lock')} catch {throw "worker launch unconfirmed; drain lock busy: $launchReason"}
        try {
            $script:DrainState=Read-DrainJson (Join-Path $script:DrainDirectory 'drain-state.json')
            if ($script:DrainState.status -eq 'launching') {$script:DrainState.status='launch-failed';$script:DrainState.diagnosis=$launchReason;Save-DrainState}
        } finally {$failureLock.Dispose()}
        throw $launchReason
    }
    if (-not (Confirm-DrainWorker)) {
        $lock=$null
        try {$lock=Open-DrainLock (Join-Path $StateRoot 'drains/drain.lock')} catch {throw 'worker launch unconfirmed; drain lock busy'}
        try {
            $script:DrainState=Read-DrainJson (Join-Path $script:DrainDirectory 'drain-state.json')
            if ($script:DrainState.status -eq 'launching') {$script:DrainState.status='launch-failed';$script:DrainState.diagnosis='worker launch unconfirmed';Save-DrainState}
        } finally {$lock.Dispose()}
        throw 'worker launch unconfirmed'
    }
    Write-Output "Drain id: $id"
    Write-Output "Report: $(Join-Path $script:DrainState.project "docs/drain/$id.md")"
    Write-Output "Resume: $(Get-DrainResumeCommand $script:DrainState)"
    exit 0
} catch { Write-Output $_.Exception.Message;exit 1 }
