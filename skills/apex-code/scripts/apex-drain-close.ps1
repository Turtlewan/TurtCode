<# Read-only, attended close-out plan. The durable state and Git are the sources;
the Markdown drain report is never read. This command performs no close-out work. #>
param([string]$Plan, [switch]$Json, [string]$StateRoot)
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
[Console]::OutputEncoding = $utf8
# Windows PowerShell's ProcessStartInfo cannot copy duplicate PATH/Path keys.
$closePath = $env:Path
[Environment]::SetEnvironmentVariable('PATH',$null,'Process')
[Environment]::SetEnvironmentVariable('Path',$null,'Process')
[Environment]::SetEnvironmentVariable('Path',$closePath,'Process')
. (Join-Path $PSScriptRoot 'engine-dispatch.ps1')

function ConvertTo-CloseArgument([string]$Value) {
    return '"' + [regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1') + '"'
}
function Invoke-CloseGit([string]$Repo, [string[]]$Arguments, [switch]$AllowFailure) {
    # No shell, optional index locks, hooks, replacement objects, or lazy fetches.
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = 'git.exe'; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $utf8; $info.StandardErrorEncoding = $utf8
    $info.EnvironmentVariables['GIT_OPTIONAL_LOCKS'] = '0'
    $info.EnvironmentVariables['GIT_NO_REPLACE_OBJECTS'] = '1'
    $info.EnvironmentVariables['GIT_NO_LAZY_FETCH'] = '1'
    foreach ($key in @('GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE','GIT_OBJECT_DIRECTORY','GIT_ALTERNATE_OBJECT_DIRECTORIES','GIT_NAMESPACE','GIT_GRAFT_FILE','GIT_SHALLOW_FILE','GIT_REDIRECT_STDOUT','GIT_REDIRECT_STDERR','GIT_REDIRECT_STDIN')) { $info.EnvironmentVariables.Remove($key) }
    foreach ($key in @($info.EnvironmentVariables.Keys)) {
        if ($key.StartsWith('GIT_TRACE',[StringComparison]::OrdinalIgnoreCase)) { $info.EnvironmentVariables.Remove($key) }
    }
    $info.Arguments = (@(@('--literal-pathspecs','-c','core.hooksPath=NUL','-c','core.quotepath=false','-c','i18n.logOutputEncoding=UTF-8','-c','trace2.normalTarget=0','-c','trace2.eventTarget=0','-c','trace2.perfTarget=0','-C',$Repo) + $Arguments | ForEach-Object { ConvertTo-CloseArgument $_ }) -join ' ')
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    try {
        [void]$process.Start(); $errorRead = $process.StandardError.ReadToEndAsync()
        $output = $process.StandardOutput.ReadToEnd(); $process.WaitForExit()
        $result = [pscustomobject]@{ code=$process.ExitCode; text=$output.TrimEnd([char[]]@([char]13,[char]10)); raw=$output; error=$errorRead.Result }
    } finally { $process.Dispose() }
    if ($result.code -ne 0 -and -not $AllowFailure) { throw "Git identity probe failed: $($Arguments -join ' ')" }
    return $result
}
function Get-CloseGit([string]$Repo, [string[]]$Arguments) { return (Invoke-CloseGit $Repo $Arguments).text }
function Get-CloseRoot([string]$Path) {
    if (-not $Path -or $Path -notmatch '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+)') { throw 'paths must be canonical absolute roots' }
    $full = [IO.Path]::GetFullPath($Path)
    $isVolumeRoot = $full -eq [IO.Path]::GetPathRoot($full)
    if (-not $isVolumeRoot) { $full = $full.TrimEnd('\','/') }
    $spelling = $Path.Replace('\','/')
    if (-not $isVolumeRoot) { $spelling = $spelling.TrimEnd('/') }
    if (-not [string]::Equals($full.Replace('\','/'), $spelling, [StringComparison]::OrdinalIgnoreCase)) { throw 'noncanonical stored root' }
    # Reject junctions/symlinks in every existing ancestor, including artifact files.
    $probe = $full
    while ($probe) {
        if ([IO.File]::Exists($probe) -or [IO.Directory]::Exists($probe)) {
            if ([IO.File]::GetAttributes($probe) -band [IO.FileAttributes]::ReparsePoint) { throw "unsafe reparse path: $Path" }
        }
        $next = [IO.Path]::GetDirectoryName($probe)
        if ($next -eq $probe) { break }; $probe = $next
    }
    return $full
}
function Read-CloseText([string]$Path) {
    [void](Get-CloseRoot $Path)
    if (-not [IO.File]::Exists($Path)) { throw "missing source: $Path" }
    # ReadAllText auto-detects UTF-16 BOMs even with an explicit UTF-8 encoding.
    # Decode bytes strictly so every artifact obeys the UTF-8 read boundary.
    $bytes = [IO.File]::ReadAllBytes($Path); $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { $offset = 3 }
    return $utf8.GetString($bytes,$offset,$bytes.Length-$offset)
}
function Read-CloseJson([string]$Path) {
    $value = Read-CloseText $Path | ConvertFrom-Json
    if ($value -isnot [pscustomobject]) { throw "malformed source object: $Path" }
    return $value
}
function Assert-CloseString($Value, [string]$Label) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { throw "malformed $Label" }
}
function Test-CloseVersion($Value) { return (($Value -is [int] -or $Value -is [long]) -and $Value -eq 1) }
function Get-CloseDigest([string]$Path) {
    [void](Get-CloseRoot $Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 255 -and $bytes[1] -eq 254) -or ($bytes[0] -eq 254 -and $bytes[1] -eq 255))) { throw 'UTF-16/32 spec is not permitted' }
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 254 -and $bytes[3] -eq 255) { throw 'UTF-32 spec is not permitted' }
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { $offset = 3 }
    $text = $utf8.GetString($bytes,$offset,$bytes.Length-$offset).Replace("`r`n","`n").Replace("`r","`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($text)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Get-CloseTasks([string]$Text) {
    $hostTasks = @(); $ownerTasks = @(); $ids = @{}; $fence = $null; $inTasks = $false; $sections = 0; $count = 0
    foreach ($line in ($Text.Replace("`r`n","`n").Replace("`r","`n") -split "`n")) {
        $fm = [regex]::Match($line, '^[ ]{0,3}(?<Fence>`{3,}|~{3,})(?<Trailing>.*)$')
        if ($null -ne $fence) {
            if ($fm.Success -and $fm.Groups['Fence'].Value[0] -eq $fence[0] -and $fm.Groups['Fence'].Value.Length -ge $fence.Length -and $fm.Groups['Trailing'].Value -match '^[ \t]*$') { $fence = $null }
            continue
        }
        if ($fm.Success) { $fence = $fm.Groups['Fence'].Value; continue }
        if ($line -match '^##[ \t]+(.*?)[ \t]*$') { $inTasks = $Matches[1] -ceq 'Tasks'; if ($inTasks) { $sections++ }; continue }
        if (-not $inTasks) { continue }
        $decl = [regex]::Match($line, '^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?\*\*\s*(?<Title>Task\s+(?<Id>[0-9]+[A-Za-z]?)(?=\b).*?)\*\*(?<Rest>.*)$')
        if (-not $decl.Success) {
            if ($line -match '^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?(?:\*\*\s*Task\b|Task\s+\S+\s+\*\*)') { throw 'unparseable spec Tasks declaration' }
            continue
        }
        $id = $decl.Groups['Id'].Value.ToLowerInvariant()
        if ($ids.ContainsKey($id)) { throw 'ambiguous spec task identity' }; $ids[$id] = $true; $count++
        $title = $decl.Groups['Title'].Value + $decl.Groups['Rest'].Value.TrimEnd()
        $task = [pscustomobject][ordered]@{ id=$id; title=$title }
        if ($decl.Groups['Title'].Value -cmatch '\bOWNER\b') { $ownerTasks += $task }
        elseif ($decl.Groups['Title'].Value.Contains('(HOST)')) { $hostTasks += $task }
    }
    if ($sections -ne 1 -or $count -eq 0 -or $null -ne $fence) { throw 'unparseable spec Tasks list' }
    return [pscustomobject]@{ host_tasks=$hostTasks; owner_tasks=$ownerTasks }
}
function Assert-CloseCommit($Value, [string]$Label) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { throw "invalid $Label commit identity" }
}
function Get-CloseCommon([string]$Repo) {
    return Get-CloseRoot (Get-CloseGit $Repo @('rev-parse','--path-format=absolute','--git-common-dir'))
}
function Assert-CloseWorktreeRoot([string]$Repo) {
    [void](Get-CloseRoot $Repo)
    if (-not (Test-EnginePathEqual $Repo (Get-CloseGit $Repo @('rev-parse','--show-toplevel')))) { throw 'recorded repo is not a Git worktree root' }
}
function Get-CloseRecordedSpec($Spec) {
    return [pscustomobject][ordered]@{ order=$Spec.order; spec=$Spec.spec; repo=$Spec.repo; state=$Spec.state; diagnosis=$Spec.diagnosis; engine_run_id=$Spec.engine_run_id }
}
function New-ClosePlan($State) {
    Assert-CloseString $State.state_root 'stored state root'
    if (-not (Test-CloseVersion $State.schema_version) -or $State.drain_id -isnot [string] -or $State.drain_id -cne $Plan -or -not (Test-EnginePathEqual (Get-CloseRoot $State.state_root) $StateRoot)) { throw 'invalid stored drain roots or identity' }
    if (-not ($State.repos -is [array]) -or -not ($State.will_build -is [array]) -or -not ($State.needs_you -is [array]) -or $State.status -isnot [string] -or [string]::IsNullOrWhiteSpace($State.status)) { throw 'malformed drain collections or status' }
    Assert-CloseString $State.project 'stored project'
    $project = Get-CloseRoot $State.project
    $repos = @(); $commonSeen = @{}; $orderSeen = @{}; $specSeen = @{}; $runSeen = @{}
    foreach ($record in $State.repos) {
        if ($record -isnot [pscustomobject]) { throw 'malformed stored repo' }
        foreach ($field in @('repo','common_dir','worktree','branch','state')) { Assert-CloseString $record.$field ('stored repo '+$field) }
        Assert-CloseWorktreeRoot $record.repo
        $common = Get-CloseCommon $record.repo
        $expected = Join-Path (Join-Path (Split-Path -Parent $record.repo) ((Split-Path -Leaf $record.repo)+'-wt')) ('drain-'+$Plan)
        if (-not (Test-EnginePathEqual (Get-CloseRoot $record.common_dir) $common) -or -not (Test-EnginePathEqual (Get-CloseRoot $record.worktree) $expected) -or $record.branch -cne "codex/drain-$Plan") { throw 'stored repo target outside recorded canonical roots' }
        if ($commonSeen.ContainsKey($common)) { throw 'ambiguous repo common directory' }; $commonSeen[$common] = $record
        $repos += [pscustomobject][ordered]@{ repo=$record.repo; common_dir=$record.common_dir; worktree=$record.worktree; drain_branch=$record.branch; drain_base=$null; destination_branch=$null; drain_tip=$null; whole_queue_range=$null; nothing_to_integrate=$null; committed_specs=@(); noncommitted_specs=@() }
    }
    foreach ($spec in @($State.will_build | Sort-Object order)) {
        if ($spec -isnot [pscustomobject]) { throw 'malformed stored spec' }
        foreach ($field in @('spec','path','repo','digest','state')) { Assert-CloseString $spec.$field ('stored spec '+$field) }
        if ($spec.order -isnot [int] -and $spec.order -isnot [long]) { throw 'invalid spec order' }
        if ($spec.order -lt 1 -or $orderSeen.ContainsKey([string]$spec.order) -or $specSeen.ContainsKey([string]$spec.spec) -or $spec.spec -cnotmatch '^[a-z0-9][a-z0-9-]{0,62}$') { throw 'ambiguous drain spec identity or order' }
        $orderSeen[[string]$spec.order]=$true; $specSeen[[string]$spec.spec]=$true
        $path = Get-CloseRoot $spec.path
        if (-not (Test-EnginePathEqual (Split-Path -Parent $path) (Join-Path $project 'docs/changes')) -or $spec.digest -cnotmatch '^[0-9a-f]{64}$') { throw 'stored spec target outside recorded canonical roots' }
        Assert-CloseWorktreeRoot $spec.repo
        $specCommon = Get-CloseCommon $spec.repo
        $repoMatches = @($repos | Where-Object { Test-EnginePathEqual $_.common_dir $specCommon })
        if ($repoMatches.Count -ne 1) { throw 'unregistered spec repo identity' }
        if ($null -ne $spec.engine_run_id -and $spec.engine_run_id -isnot [string]) { throw 'invalid stored Engine run identity' }
        if ($spec.engine_run_id) {
            if ($spec.engine_run_id -cnotmatch '^[0-9a-f]{32}$' -or $runSeen.ContainsKey([string]$spec.engine_run_id)) { throw 'ambiguous stored Engine run identity' }
            $runSeen[[string]$spec.engine_run_id]=$true
        }
        if ($spec.state -ceq 'committed') {
            $repoMatches[0].committed_specs += [pscustomobject][ordered]@{ order=$spec.order; spec=$spec.spec; repo=$spec.repo; commit_sha=$spec.commit_sha; engine_run_id=$spec.engine_run_id; journaled_paths=$null; integration_tip=$null; host_tasks=$null; owner_tasks=$null; host_checks=$null; review_parent=$null; review_target=$null; review_paths=$null; review_command=$null; wrapper_runs=$null }
        } else { $repoMatches[0].noncommitted_specs += Get-CloseRecordedSpec $spec }
    }
    $result = [pscustomobject][ordered]@{ schema_version=1; drain_id=$State.drain_id; status=$State.status; eligible=($State.status -ceq 'complete'); diagnosis=$State.diagnosis; repos=$repos; needs_you=@($State.needs_you | ForEach-Object { [pscustomobject][ordered]@{spec=$_.spec;reason_code=$_.reason_code;reason=$_.reason} }) }
    if (-not $result.eligible) { return $result }
    $ledgerLines = @()
    if (@($State.will_build | Where-Object state -CEQ 'committed').Count) {
        $ledgerLines = (Read-CloseText (Join-Path $StateRoot 'progress/codex-run-ledger.jsonl')) -split '\r?\n'
    }
    $wrapperSeen = @{}
    foreach ($repo in $repos) {
        $record = $commonSeen[(Get-CloseCommon $repo.repo)]
        if ($record.state -cne 'ready') { throw "repo not ready: $($repo.repo)" }
        Assert-CloseWorktreeRoot $repo.worktree
        if (-not (Test-EnginePathEqual (Get-CloseCommon $repo.worktree) $repo.common_dir)) { throw 'drain worktree common directory mismatch' }
        $registered = @()
        foreach ($block in ((Get-CloseGit $repo.repo @('worktree','list','--porcelain')) -split '\n\n')) {
            $match = [regex]::Match($block,'(?m)^worktree (.+)$')
            if ($match.Success -and (Test-EnginePathEqual $match.Groups[1].Value $repo.worktree)) { $registered += $block }
        }
        if ($registered.Count -ne 1 -or $registered[0] -cnotmatch ('(?m)^branch '+[regex]::Escape('refs/heads/'+$repo.drain_branch)+'$') -or (Get-CloseGit $repo.worktree @('symbolic-ref','-q','HEAD')) -cne ('refs/heads/'+$repo.drain_branch)) { throw 'unregistered or moved drain branch/worktree' }
        $repo.drain_tip = Get-CloseGit $repo.repo @('rev-parse','--verify',('refs/heads/'+$repo.drain_branch+'^{commit}'))
        if ((Get-CloseGit $repo.worktree @('rev-parse','HEAD')) -cne $repo.drain_tip) { throw 'moved drain tip' }
        $repo.drain_base = $repo.drain_tip
        $previous = $null
        foreach ($item in $repo.committed_specs) {
            $source = @($State.will_build | Where-Object spec -CEQ $item.spec)[0]
            Assert-CloseCommit $source.commit_sha 'spec'; Assert-CloseCommit $source.prelaunch_head 'prelaunch'
            $parents = (Get-CloseGit $repo.worktree @('rev-list','--parents','-n','1',$source.commit_sha)) -split ' '
            if ($parents.Count -ne 2 -or $parents[0] -cne $source.commit_sha -or $parents[1] -cne $source.prelaunch_head -or ($previous -and $parents[1] -cne $previous)) { throw "broken commit chain or prelaunch parent: $($item.spec)" }
            if (-not $previous) { $repo.drain_base = $source.prelaunch_head }
            $previous = $source.commit_sha
            $message = Get-CloseGit $repo.worktree @('log','-1','--format=%B',$source.commit_sha)
            foreach ($trailer in @(@{key='Drain-Spec';value=$source.spec},@{key='Engine-Run';value=$source.engine_run_id})) {
                $values = @([regex]::Matches($message,('(?m)^'+$trailer.key+': (.*)$')))
                if ($values.Count -ne 1 -or $values[0].Groups[1].Value -cne $trailer.value) { throw "commit trailer identity mismatch: $($item.spec)" }
            }
            if (-not $source.engine_run_id) { throw 'missing Engine run identity' }
            $engine = Read-CloseJson (Join-Path $StateRoot "$($source.engine_run_id)/engine-state.json")
            if (-not (Test-CloseVersion $engine.schema_version) -or $engine.run_id -isnot [string] -or $engine.run_id -cne $source.engine_run_id -or $engine.spec -isnot [pscustomobject] -or $engine.spec.name -isnot [string] -or $engine.spec.name -cne $source.spec -or $engine.repo -isnot [string] -or -not (Test-EnginePathEqual (Get-CloseRoot $engine.repo) $repo.worktree) -or $engine.status -isnot [string] -or $engine.status -cne 'complete' -or $engine.handoff -isnot [pscustomobject] -or $engine.handoff.status -isnot [string] -or $engine.handoff.status -cne 'complete') { throw "Engine identity or completion mismatch: $($item.spec)" }
            if ($engine.spec.original_digest -isnot [string] -or $engine.spec.original_digest -cne $source.digest) { throw 'Engine original digest mismatch' }
            if ($engine.base_sha -isnot [string] -or $engine.base_sha -cne $source.prelaunch_head) { throw 'Engine base identity mismatch' }
            if ((Get-CloseDigest $source.path) -cne $source.digest) { throw 'recorded spec digest changed' }
            $tasks = Get-CloseTasks (Read-CloseText $source.path)
            $item.host_tasks=$tasks.host_tasks; $item.owner_tasks=$tasks.owner_tasks
            if ($engine.plan -isnot [pscustomobject] -or $engine.plan.host_checks -isnot [array]) { throw 'malformed Engine host checks' }
            $item.host_checks = @($engine.plan.host_checks | ForEach-Object { if ($_ -isnot [pscustomobject] -or $_.text -isnot [string]) { throw 'malformed HOST check text' }; $_.text })
            if ($engine.integration -isnot [pscustomobject]) { throw 'invalid integration tip commit identity' }
            Assert-CloseCommit $engine.integration.tip 'integration tip'
            if ((Get-CloseGit $repo.worktree @('rev-parse','--verify',($engine.integration.tip+'^{commit}'))) -cne $engine.integration.tip) { throw 'integration tip identity mismatch' }
            $item.integration_tip = $engine.integration.tip
            if ($engine.handoff.journaled_paths -isnot [array]) { throw 'malformed journaled paths' }
            $pathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($path in $engine.handoff.journaled_paths) {
                if ($path -isnot [string] -or -not $path -or $path -match '[\\:\x00-\x1f]' -or $path.StartsWith('/') -or @($path -split '/' | Where-Object { $_ -in @('','..','.','.git') }).Count -or -not $pathSet.Add($path)) { throw 'unsafe or ambiguous journaled path' }
                $actual = Invoke-CloseGit $repo.worktree @('rev-parse','--verify',($source.commit_sha+':'+$path)) -AllowFailure
                $expected = Invoke-CloseGit $repo.worktree @('rev-parse','--verify',($engine.integration.tip+':'+$path)) -AllowFailure
                if (($actual.code -eq 0) -ne ($expected.code -eq 0) -or ($actual.code -eq 0 -and $actual.text -cne $expected.text)) { throw "journaled blob mismatch: $path" }
            }
            $changed = (Invoke-CloseGit $repo.worktree @('diff-tree','--no-commit-id','--no-renames','--name-only','-z','-r',$source.commit_sha)).raw.Split([char[]]@([char]0),[StringSplitOptions]::RemoveEmptyEntries)
            if (-not $pathSet.SetEquals([string[]]$changed)) { throw 'commit changed-path set differs from journaled paths' }
            $item.journaled_paths = @($engine.handoff.journaled_paths)
            $item.review_paths = $item.journaled_paths
            $item.review_parent = Get-CloseGit $repo.worktree @('rev-parse',($source.commit_sha+'^'))
            $item.review_target = $source.commit_sha
            $item.review_command = 'git diff '+$item.review_parent+' '+$source.commit_sha+' --'+(@($item.journaled_paths | ForEach-Object { " ':(literal)"+[regex]::Replace($_,'[\x27\u2018-\u201b]','$0$0')+"'" }) -join '')
            if ($engine.tasks -isnot [array] -or $engine.tasks.Count -eq 0) { throw 'missing Engine integrated tasks' }
            $item.wrapper_runs = @(); $taskSeen = @{}
            foreach ($task in $engine.tasks) {
                if ($task -isnot [pscustomobject] -or $task.id -isnot [string] -or -not $task.id -or $taskSeen.ContainsKey([string]$task.id) -or $task.status -isnot [string] -or $task.status -cne 'integrated') { throw 'Engine task identity or integration mismatch' }; $taskSeen[[string]$task.id]=$true
                if ($task.attempts -isnot [array]) { throw 'malformed Engine attempts' }
                $successful = @($task.attempts | Where-Object { $_ -is [pscustomobject] -and $_.status -is [string] -and $_.status -ceq 'succeeded' })
                if (-not $successful.Count) { throw 'missing successful Engine attempt' }; $attempt = $successful[-1]
                if ($attempt.wrapper_run_id -isnot [string] -or -not $attempt.wrapper_run_id -or $wrapperSeen.ContainsKey([string]$attempt.wrapper_run_id)) { throw 'ambiguous wrapper run identity' }; $wrapperSeen[[string]$attempt.wrapper_run_id]=$true
                Assert-CloseString $attempt.worktree 'Engine attempt worktree'
                [void](Get-CloseRoot $attempt.worktree)
                # Run id is exact: do not select the newest spec/task dispatch.
                $rows = @(); $lineNumber = 0
                foreach ($line in $ledgerLines) {
                    $lineNumber++
                    # Ignore unrelated rows, including incomplete concurrent writes.
                    if (-not $line.Contains($attempt.wrapper_run_id)) { continue }
                    try { $row = $line | ConvertFrom-Json } catch { throw "malformed ledger row $lineNumber" }
                    if ($row -isnot [pscustomobject]) { throw "malformed ledger row $lineNumber" }
                    if ($row.row_kind -is [string] -and $row.row_kind -ceq 'dispatch' -and $row.run_id -is [string] -and $row.run_id -ceq $attempt.wrapper_run_id) { $rows += $row }
                }
                if ($rows.Count -ne 1) { throw 'missing or ambiguous ledger dispatch identity' }; $row = $rows[0]
                if ($row.phase -isnot [string] -or $row.phase -cne 'build' -or $row.spec -isnot [string] -or $row.spec -cne $source.spec -or $row.task -isnot [string] -or $row.task -cne $task.id -or $row.status -isnot [string] -or $row.status -cnotin @('done','done_with_concerns','success','adopted-done') -or $row.worktree_key -isnot [string] -or -not $row.worktree_key -or -not (Test-EnginePathEqual (Get-CloseRoot $row.worktree_key) $attempt.worktree) -or ($row.worktree -and ($row.worktree -isnot [string] -or -not (Test-EnginePathEqual (Get-CloseRoot $row.worktree) $attempt.worktree)))) { throw 'ledger task/worktree/success identity mismatch' }
                if ($row.end_tree_digest -isnot [string] -or $attempt.end_tree_digest -isnot [string] -or $row.end_tree_digest -cnotmatch '^[0-9a-fA-F]{64}$' -or $attempt.end_tree_digest -cnotmatch '^[0-9a-fA-F]{64}$' -or $row.end_tree_digest -cne $attempt.end_tree_digest) { throw 'ledger end digest mismatch or unverifiable' }
                $item.wrapper_runs += [pscustomobject][ordered]@{ task=$task.id; wrapper_run_id=$row.run_id; worktree_key=$row.worktree_key; end_digest=$row.end_tree_digest }
            }
        }
        if ($previous -and $previous -cne $repo.drain_tip) { throw 'moved drain tip after last committed spec' }
        if ((Invoke-CloseGit $repo.worktree @('merge-base','--is-ancestor',$repo.drain_base,$repo.drain_tip) -AllowFailure).code -ne 0) { throw 'drain base is not an ancestor of drain tip' }
        $destination = Invoke-CloseGit $repo.repo @('symbolic-ref','-q','HEAD') -AllowFailure
        if ($destination.code -ne 0 -or $destination.text -cnotmatch '^refs/heads/.+') { throw 'destination worktree is detached' }
        if ((Get-CloseGit $repo.repo @('rev-parse','HEAD')) -cne $repo.drain_base) { throw 'destination HEAD moved from drain base' }
        $repo.destination_branch = $destination.text.Substring(11)
        $repo.whole_queue_range = $repo.drain_base+'..'+$repo.drain_tip
        # Provisional for empty repos: HOST confirms no close-out edits before skipping.
        $repo.nothing_to_integrate = $false
    }
    return $result
}
function Write-CloseText($Value) {
    # The same named fields and exact check strings as JSON, rendered without ASCII escaping.
    [Console]::WriteLine(($Value | ConvertTo-Json -Depth 100))
    [Console]::WriteLine('eligible: '+$Value.eligible.ToString().ToLowerInvariant())
    if (-not $Value.eligible) {
        if ($Value.status -ceq 'stopped-integrity') { [Console]::WriteLine('HOST: inspect the preserved drain; never resume stopped-integrity blindly.') }
        else { [Console]::WriteLine('HOST: resume or inspect the preserved drain before close-out.') }
    } else {
        foreach ($repo in $Value.repos) {
            [Console]::WriteLine('Repo worktree: '+$repo.worktree)
            foreach ($spec in $repo.committed_specs) {
                [Console]::WriteLine('Spec '+$spec.order+': '+$spec.spec)
                [Console]::WriteLine('review_command: '+$spec.review_command)
                foreach ($task in $spec.host_tasks) { [Console]::WriteLine('HOST task '+$task.id+': '+$task.title) }
                foreach ($task in $spec.owner_tasks) { [Console]::WriteLine('OWNER task '+$task.id+': '+$task.title) }
                [Console]::WriteLine('host_checks (acceptance assertions):')
                foreach ($check in $spec.host_checks) { [Console]::WriteLine($check) }
            }
        }
        [Console]::WriteLine('HOST: run the ordered HOST/OWNER tasks; host_checks are acceptance assertions. Review each immutable build checkpoint with its review_command from that repo worktree. Confirm the family gate selects the listed wrapper run before appending review rows; stop for the owner if it differs.')
        [Console]::WriteLine('HOST: obtain owner approval of paths, full diff, and message before each close-out commit. For a build-only repo obtain approval of its current drain_tip SHA. Confirm all repo destinations still name the approved branches at drain_base before fast-forwarding the whole_queue_range. Mark an empty repo nothing_to_integrate only after confirming it receives no close-out edits. Preserved noncommitted Engine runs need attended disposition. This command performs none of these actions.')
    }
}

$lock = $null
try {
    if ($args.Count -or $Plan -cnotmatch '^\d{8}-\d{6}-[0-9a-f]{6}$') { throw 'accepts only -Plan <drain-id> [-Json]' }
    if ($PSBoundParameters.ContainsKey('StateRoot') -and $env:APEX_DRAIN_TEST_MODE -cne '1') { throw 'StateRoot is test-only' }
    if (-not $PSBoundParameters.ContainsKey('StateRoot')) { $StateRoot = if ($env:APEX_STATE_DIR) { $env:APEX_STATE_DIR } else { Join-Path $env:LOCALAPPDATA 'apex' } }
    $StateRoot = Get-CloseRoot $StateRoot
    $probe = $StateRoot
    while (-not (Test-Path -LiteralPath $probe -PathType Container)) { $next=Split-Path -Parent $probe; if (-not $next -or $next -eq $probe) { throw 'missing StateRoot' }; $probe=$next }
    $inside = Invoke-CloseGit $probe @('rev-parse','--is-inside-work-tree') -AllowFailure
    if ($inside.code -eq 0 -and $inside.text -ceq 'true') { throw 'StateRoot must be outside every Git worktree' }
    $lockPath = Get-CloseRoot (Join-Path $StateRoot 'drains/drain.lock')
    if (-not [IO.File]::Exists($lockPath)) { throw 'missing drain lock' }
    for ($retry=0; $retry -le 20; $retry++) {
        try { $lock=[IO.File]::Open($lockPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None); break }
        catch { if ($retry -lt 20) { Start-Sleep -Milliseconds 500 } }
    }
    if (-not $lock) { throw 'drain lock busy' }
    $state = Read-CloseJson (Join-Path $StateRoot "drains/$Plan/drain-state.json")
    $output = New-ClosePlan $state
    if (-not $output.eligible) {
        if (-not $Json) { Write-CloseText $output }
        throw "drain is ineligible: status $($state.status); $($state.diagnosis)"
    }
    if ($Json) {
        $serialized = $output | ConvertTo-Json -Depth 100
        [Console]::WriteLine([regex]::Replace($serialized,'[^\x00-\x7f]',[Text.RegularExpressions.MatchEvaluator]{ param($match) '\u{0:x4}' -f [int][char]$match.Value }))
    } else { Write-CloseText $output }
    $exitCode = 0
} catch {
    $reason = $_.Exception.Message.Replace("`r",' ').Replace("`n",' ')
    if ($Json) { [Console]::Error.WriteLine($reason) } else { [Console]::WriteLine($reason) }
    $exitCode = 1
} finally { if ($null -ne $lock) { $lock.Dispose() } }
exit $exitCode
