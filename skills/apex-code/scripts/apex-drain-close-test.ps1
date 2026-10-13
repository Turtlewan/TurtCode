<# Hermetic synthetic artifacts and real Git/CLI probes; never launches a drain.
Fixture commits use plumbing, and cleanup is confined to the owned TEMP root. #>
param()
$ErrorActionPreference = 'Stop'
$closeTestPath = $env:Path
[Environment]::SetEnvironmentVariable('PATH',$null,'Process')
[Environment]::SetEnvironmentVariable('Path',$null,'Process')
[Environment]::SetEnvironmentVariable('Path',$closeTestPath,'Process')
$utf8 = [Text.UTF8Encoding]::new($false,$true)
$runner = Join-Path $PSScriptRoot 'apex-drain-close.ps1'
$testRoot = Join-Path $env:TEMP ('apex-drain-close-test-'+[guid]::NewGuid().ToString('N'))
$failures = 0; $checks = 0
$savedEnvironment = @{}
foreach ($name in @('APEX_DRAIN_TEST_MODE','APEX_STATE_DIR','LOCALAPPDATA','GIT_CONFIG_GLOBAL','GIT_CONFIG_NOSYSTEM','GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL')) { $savedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
# Import definitions only, as in apex-drain-test.ps1. Never execute the runner body.
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors -join "`n") }
foreach ($name in @('ConvertTo-CloseArgument','Invoke-CloseGit','Get-CloseGit','Get-CloseRoot','Get-CloseDigest')) {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if (-not $definition) { throw "missing fixture helper: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert-CloseTest($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Write-CloseFixture([string]$Path,[string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path,$Text,$utf8)
}
function Write-CloseFixtureJson([string]$Path,$Value) { Write-CloseFixture $Path ($Value | ConvertTo-Json -Depth 100) }
function Git([string]$Repo,[string[]]$Arguments) { Get-CloseGit $Repo $Arguments }
function Commit-CloseFixture([string]$Repo,[string[]]$Paths,[string]$Parent,[string]$Message='fixture') {
    foreach ($path in $Paths) {
        $full=Join-Path $Repo $path
        if ([IO.File]::Exists($full)) {
            $blob=Git $Repo @('hash-object','-w','--',$full)
            [void](Git $Repo @('update-index','--add','--cacheinfo',"100644,$blob,$path"))
        } else { [void](Git $Repo @('update-index','--force-remove','--',$path)) }
    }
    $tree=Git $Repo @('write-tree')
    $arguments=@('commit-tree',$tree,'-m',$Message)
    if ($Parent) { $arguments+=@('-p',$Parent) }
    $sha=Git $Repo $arguments
    [void](Git $Repo @('update-ref','HEAD',$sha))
    return $sha
}
function New-CloseFixture([string]$Name,[int[]]$RepoOrder=@(0),[int]$RepoCount=1,[string[]]$BuildPaths=@()) {
    $root=Join-Path $testRoot $Name; $stateRoot=Join-Path $root 'state'; $project=Join-Path $root 'project'
    $id='20261013-120000-abcdef'; $repos=@(); $bases=@(); $specs=@(); $engines=@(); $rows=@()
    [void][IO.Directory]::CreateDirectory((Join-Path $project 'docs/changes'))
    for ($n=0; $n -lt $RepoCount; $n++) {
        $repo=Join-Path $root "repo-$n"; [void][IO.Directory]::CreateDirectory($repo)
        [void](Git $repo @('init','-q','--initial-branch=main'))
        [void](Git $repo @('config','core.autocrlf','false'))
        Write-CloseFixture (Join-Path $repo 'base.txt') "base`n"
        Write-CloseFixture (Join-Path $repo 'deleted.txt') "delete me`n"
        $base=Commit-CloseFixture $repo @('base.txt','deleted.txt') ''
        $common=Git $repo @('rev-parse','--path-format=absolute','--git-common-dir')
        $worktree=Join-Path (Join-Path $root "repo-$n-wt") "drain-$id"
        [void](Git $repo @('worktree','add','-b',"codex/drain-$id",$worktree,'HEAD'))
        $repos += [pscustomobject]@{repo=$repo;common_dir=$common;branch="codex/drain-$id";worktree=$worktree;state='ready';ref_snapshot=''}
        $bases += $base
    }
    $hostCheck='- [ ] HOST checks '+[char]0x4e2d+[char]0x6587+' '+[char]0xd83d+[char]0xde80+"  `n  keep exact continuation  "
    for ($n=0; $n -lt $RepoOrder.Count; $n++) {
        $record=$repos[$RepoOrder[$n]]; $order=$n+1; $spec="spec-$order"; $engineId=('{0:x32}' -f $order)
        $path=Join-Path $project "docs/changes/$spec.md"
        $text=@"
# $spec
## Tasks
- [ ] **Task 1** - Build $spec.
- [ ] **Task 2 (HOST)** - Review documentation for $spec.
- [ ] **Task 3 (OWNER)** - Approve $spec.
- [ ] **Task 4 (HOST)** - Confirm final checklist.
``````text
- [ ] **Task 99 (HOST)** - fenced decoy.
``````
## Done-when
Acceptance belongs to Engine.
"@
        Write-CloseFixture $path $text
        $digest=Get-CloseDigest $path
        $parent=Git $record.worktree @('rev-parse','HEAD')
        $changed="src/quo'te "+[char]0x00e9+"-$order.txt"
        $paths=@($changed)
        if ($BuildPaths.Count) { $paths=@($BuildPaths) }
        foreach ($buildPath in $paths) { Write-CloseFixture (Join-Path $record.worktree $buildPath) "build $spec`n" }
        if ($order -eq 1) { Remove-Item -LiteralPath (Join-Path $record.worktree 'deleted.txt'); $paths += 'deleted.txt' }
        $commit=Commit-CloseFixture $record.worktree $paths $parent ("build $spec`n`nDrain-Spec: $spec`nEngine-Run: $engineId")
        $specs += [pscustomobject]@{order=$order;spec=$spec;repo=$record.repo;path=$path;digest=$digest;state='committed';diagnosis=$null;commit_sha=$commit;engine_run_id=$engineId;prelaunch_head=$parent}
        $attemptWorktree=Join-Path $root "task-$order" # May be preserved or already gone; no task-worktree probe needed.
        $wrapperId="wrapper-$order"; $endDigest=('a'*63)+($order % 10)
        $attempt=[pscustomobject]@{status='succeeded';wrapper_run_id=$wrapperId;worktree=$attemptWorktree;end_tree_digest=$endDigest}
        $engine=[pscustomobject]@{schema_version=1;run_id=$engineId;spec=[pscustomobject]@{name=$spec;original_digest=$digest};repo=$record.worktree;status='complete';base_sha=$parent;integration=[pscustomobject]@{tip=$commit};handoff=[pscustomobject]@{status='complete';journaled_paths=$paths};plan=[pscustomobject]@{host_checks=@([pscustomobject]@{text=$hostCheck},[pscustomobject]@{text='second assertion'})};tasks=@([pscustomobject]@{id='1';status='integrated';attempts=@([pscustomobject]@{status='failed';wrapper_run_id='old-failure'},$attempt)})}
        $engines += $engine
        $rows += [pscustomobject]@{row_kind='dispatch';phase='build';run_id=$wrapperId;spec=$spec;task='1';status='done';worktree=$attemptWorktree;worktree_key=$attemptWorktree.Replace('\','/').ToLowerInvariant();end_tree_digest=$endDigest}
        Write-CloseFixtureJson (Join-Path $stateRoot "$engineId/engine-state.json") $engine
    }
    $state=[pscustomobject]@{schema_version=1;drain_id=$id;state_root=$stateRoot;project=$project;status='complete';diagnosis=$null;repos=$repos;will_build=$specs;needs_you=@([pscustomobject]@{spec='owner-input';reason_code='host-work';reason='attended decision'})}
    $statePath=Join-Path $stateRoot "drains/$id/drain-state.json"
    Write-CloseFixtureJson $statePath $state
    Write-CloseFixture (Join-Path $stateRoot 'drains/drain.lock') 'existing lock bytes'
    $ledgerPath=Join-Path $stateRoot 'progress/codex-run-ledger.jsonl'
    Write-CloseFixture $ledgerPath ((@($rows | ForEach-Object {$_ | ConvertTo-Json -Compress -Depth 100}) -join "`n")+"`n")
    # An intentionally misleading report must never become an input.
    Write-CloseFixture (Join-Path $project "docs/drain/$id.md") 'status: stopped-integrity; destination: bogus'
    return [pscustomobject]@{root=$root;state_root=$stateRoot;state_path=$statePath;ledger_path=$ledgerPath;id=$id;state=$state;engines=$engines;rows=$rows;bases=$bases;host_check=$hostCheck}
}
function Get-CloseSnapshot([string]$Root) {
    # Includes durable artifacts, loose/packed refs, objects, reflogs, HEAD, indexes,
    # tracked files, reports, lock bytes, and the complete file inventory.
    $snapshot=@{}
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) { $snapshot[$file.FullName]=[Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName)) }
    return $snapshot
}
function Assert-CloseSnapshot($Before,$After) {
    Assert-CloseTest ($Before.Count -eq $After.Count) 'CLI created or removed a file'
    foreach ($path in $Before.Keys) { Assert-CloseTest ($After.ContainsKey($path) -and $Before[$path] -ceq $After[$path]) "CLI changed bytes: $path" }
}
function Start-CloseCli([string[]]$Arguments) {
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName='powershell.exe'; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.StandardOutputEncoding=$utf8; $info.StandardErrorEncoding=$utf8
    $info.Arguments=(@(@('-NoProfile','-File',$runner)+$Arguments | ForEach-Object {ConvertTo-CloseArgument $_}) -join ' ')
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$info
    [void]$process.Start()
    return [pscustomobject]@{process=$process;stdout=$process.StandardOutput.ReadToEndAsync();stderr=$process.StandardError.ReadToEndAsync()}
}
function Finish-CloseCli($Running) {
    try { $Running.process.WaitForExit(); return [pscustomobject]@{code=$Running.process.ExitCode;stdout=$Running.stdout.Result;stderr=$Running.stderr.Result} }
    finally { $Running.process.Dispose() }
}
function Invoke-CloseCli($Fixture,[switch]$Json,[string[]]$Arguments) {
    $before=Get-CloseSnapshot $Fixture.root
    if ($null -eq $Arguments) { $Arguments=@('-Plan',$Fixture.id,'-StateRoot',$Fixture.state_root); if ($Json) { $Arguments+='-Json' } }
    $result=Finish-CloseCli (Start-CloseCli $Arguments)
    Assert-CloseSnapshot $before (Get-CloseSnapshot $Fixture.root)
    return $result
}
function Assert-CloseRefusal($Fixture,[string]$Reason) {
    $result=Invoke-CloseCli $Fixture -Json
    Assert-CloseTest ($result.code -ne 0 -and $result.stdout -ceq '' -and $result.stderr -like "*$Reason*") ("JSON refusal ($Reason): "+($result | ConvertTo-Json -Compress))
    # Exercise every refusal through JSON; representative state, source, Git and
    # lock failures additionally prove the text stdout/stderr contract.
    if ($Reason -in @('ineligible','missing source','missing drain lock','original digest','destination HEAD moved','trailer')) {
        $result=Invoke-CloseCli $Fixture
        Assert-CloseTest ($result.code -ne 0 -and $result.stderr -ceq '' -and $result.stdout -like "*$Reason*") ("text refusal ($Reason): "+($result | ConvertTo-Json -Compress))
    }
}
function Case([string]$Name,[scriptblock]$Body) {
    $script:checks++
    try { & $Body; Write-Host "PASS $Name" }
    catch { $script:failures++; Write-Host "FAIL ${Name}: $($_.Exception.Message) $($_.ScriptStackTrace)" }
}
function Engine-Case([string]$Name,[scriptblock]$Mutation,[string]$Reason) {
    Case $Name {
        $path=Join-Path $single.state_root "$($single.state.will_build[0].engine_run_id)/engine-state.json"
        $saved=[IO.File]::ReadAllBytes($path)
        try { $engine=[IO.File]::ReadAllText($path,$utf8) | ConvertFrom-Json; & $Mutation $engine; Write-CloseFixtureJson $path $engine; Assert-CloseRefusal $single $Reason }
        finally { [IO.File]::WriteAllBytes($path,$saved) }
    }
}
function State-Case([string]$Name,[scriptblock]$Mutation,[string]$Reason,$Fixture=$single) {
    Case $Name {
        $saved=[IO.File]::ReadAllBytes($Fixture.state_path)
        try { $state=[IO.File]::ReadAllText($Fixture.state_path,$utf8) | ConvertFrom-Json; & $Mutation $state; Write-CloseFixtureJson $Fixture.state_path $state; Assert-CloseRefusal $Fixture $Reason }
        finally { [IO.File]::WriteAllBytes($Fixture.state_path,$saved) }
    }
}
function Ledger-Case([string]$Name,[scriptblock]$Mutation,[string]$Reason) {
    Case $Name {
        $saved=[IO.File]::ReadAllBytes($single.ledger_path)
        try { $rows=@([IO.File]::ReadAllLines($single.ledger_path,$utf8) | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }); $rows=@(& $Mutation $rows); Write-CloseFixture $single.ledger_path ((@($rows | ForEach-Object {$_ | ConvertTo-Json -Compress -Depth 100}) -join "`n")+"`n"); Assert-CloseRefusal $single $Reason }
        finally { [IO.File]::WriteAllBytes($single.ledger_path,$saved) }
    }
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $env:APEX_DRAIN_TEST_MODE='1'; $env:GIT_CONFIG_GLOBAL=Join-Path $testRoot 'gitconfig'; $env:GIT_CONFIG_NOSYSTEM='1'
    Write-CloseFixture $env:GIT_CONFIG_GLOBAL ''
    $env:GIT_AUTHOR_NAME='Close Test'; $env:GIT_AUTHOR_EMAIL='close@example.invalid'; $env:GIT_COMMITTER_NAME=$env:GIT_AUTHOR_NAME; $env:GIT_COMMITTER_EMAIL=$env:GIT_AUTHOR_EMAIL
    $single=New-CloseFixture 'single'
    $multi=New-CloseFixture 'multi' @(0,1,0) 3
    Case 'one repo: JSON source bindings, tasks, exact checks, review quoting and deleted blob absence' {
        $r=Invoke-CloseCli $single -Json
        Assert-CloseTest ($r.code -eq 0 -and $r.stderr -ceq '') ("eligible JSON: "+$r.stderr)
        Assert-CloseTest ($r.stdout -cnotmatch '[^\x00-\x7f]' -and $r.stdout.Contains('\u4e2d\u6587') -and $r.stdout.Contains('\ud83d\ude80')) 'ASCII JSON Unicode/surrogate escaping'
        $p=$r.stdout | ConvertFrom-Json; $repo=$p.repos[0]; $spec=$repo.committed_specs[0]
        Assert-CloseTest ($p.schema_version -eq 1 -and $p.drain_id -ceq $single.id -and $p.status -ceq 'complete' -and $p.eligible -and $null -eq $p.diagnosis) 'top-level plan identity'
        Assert-CloseTest ($repo.drain_base -ceq $single.bases[0] -and $repo.destination_branch -ceq 'main' -and $repo.drain_tip -ceq $single.state.will_build[0].commit_sha -and $repo.whole_queue_range -ceq ($repo.drain_base+'..'+$repo.drain_tip) -and -not $repo.nothing_to_integrate) 'Git derived repo fields'
        Assert-CloseTest ($spec.order -eq 1 -and $spec.spec -ceq 'spec-1' -and $spec.repo -ceq $single.state.repos[0].repo -and $spec.engine_run_id -ceq $single.engines[0].run_id -and $spec.integration_tip -ceq $single.engines[0].integration.tip) 'drain and Engine output bindings'
        Assert-CloseTest ($spec.host_tasks.Count -eq 2 -and $spec.host_tasks[0].id -ceq '2' -and $spec.host_tasks[0].title -ceq 'Task 2 (HOST) - Review documentation for spec-1.' -and $spec.host_tasks[1].id -ceq '4' -and $spec.owner_tasks[0].id -ceq '3') 'ordered HOST/OWNER task titles and fenced decoy exclusion'
        Assert-CloseTest ($spec.host_checks.Count -eq 2 -and $spec.host_checks[0] -ceq $single.host_check -and $spec.host_checks[1] -ceq 'second assertion') 'exact ordered multiline HOST assertions'
        Assert-CloseTest ($spec.review_parent -ceq $repo.drain_base -and $spec.review_target -ceq $spec.commit_sha -and ($spec.review_paths -join '|') -ceq ($spec.journaled_paths -join '|') -and $spec.review_command.Contains("':(literal)src/quo''te "+[char]0x00e9+"-1.txt'")) 'review identities and PowerShell literal quoting'
        Assert-CloseTest ($spec.wrapper_runs.Count -eq 1 -and $spec.wrapper_runs[0].task -ceq '1' -and $spec.wrapper_runs[0].wrapper_run_id -ceq 'wrapper-1' -and $spec.wrapper_runs[0].worktree_key -ceq $single.rows[0].worktree_key -and $spec.wrapper_runs[0].end_digest -ceq $single.rows[0].end_tree_digest) 'exact ledger family-gate fields'
        Assert-CloseTest ($p.needs_you[0].reason_code -ceq 'host-work' -and $null -eq $p.needs_you[0].repo) 'sorter needs_you remains top-level'
        $text=Invoke-CloseCli $single
        Assert-CloseTest ($text.code -eq 0 -and $text.stderr -ceq '' -and $text.stdout.Contains([string][char]0x4e2d) -and $text.stdout.Contains($spec.review_command) -and $text.stdout.Contains('owner approval')) 'UTF-8 text, review command and attended approval instructions'
        $textPlan=$text.stdout.Substring(0,$text.stdout.IndexOf("`neligible:")) | ConvertFrom-Json
        Assert-CloseTest (($textPlan | ConvertTo-Json -Depth 100 -Compress) -ceq ($p | ConvertTo-Json -Depth 100 -Compress)) 'text and JSON convey identical fields'
    }
    Case 'review command parses as one command with literal quote-class and wildcard paths' {
        $paths=@("src/ascii'quote.txt",'src/bracket[1].txt')
        foreach ($codePoint in 0x2018..0x201b) { $paths+=('src/smart'+[char]$codePoint+'quote.txt') }
        $fixture=New-CloseFixture 'review-literals' -BuildPaths $paths
        $r=Invoke-CloseCli $fixture -Json; Assert-CloseTest ($r.code -eq 0) $r.stderr
        $spec=($r.stdout | ConvertFrom-Json).repos[0].committed_specs[0]
        $expectedPaths=@($paths)+@('deleted.txt')
        Assert-CloseTest (($spec.journaled_paths -join '|') -ceq ($expectedPaths -join '|')) 'review fixture journaled paths'
        $tokens=$null; $errors=$null
        $commandAst=[Management.Automation.Language.Parser]::ParseInput($spec.review_command,[ref]$tokens,[ref]$errors)
        $commands=@($commandAst.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true))
        Assert-CloseTest ($errors.Count -eq 0 -and $commands.Count -eq 1 -and $commandAst.EndBlock.Statements.Count -eq 1) 'review command parses to a single command'
        $elements=$commands[0].CommandElements
        Assert-CloseTest ($elements.Count -eq (5+$expectedPaths.Count) -and $elements[0].Extent.Text -ceq 'git' -and $elements[1].Extent.Text -ceq 'diff' -and $elements[2].Extent.Text -ceq $spec.review_parent -and $elements[3].Extent.Text -ceq $spec.commit_sha -and $elements[4].Extent.Text -ceq '--') 'review command fixed arguments'
        for ($n=0; $n -lt $expectedPaths.Count; $n++) {
            Assert-CloseTest ($elements[5+$n] -is [Management.Automation.Language.StringConstantExpressionAst] -and $elements[5+$n].Value -ceq (':(literal)'+$expectedPaths[$n])) 'review path preserves literal text and pathspec magic'
        }
    }
    Case 'cross-reference bullets in Tasks leave HOST and OWNER task lists unchanged' {
        $path=$single.state.will_build[0].path; $enginePath=Join-Path $single.state_root "$($single.engines[0].run_id)/engine-state.json"
        $saved=[IO.File]::ReadAllBytes($path); $savedState=[IO.File]::ReadAllBytes($single.state_path); $savedEngine=[IO.File]::ReadAllBytes($enginePath)
        try {
            $before=Invoke-CloseCli $single -Json; Assert-CloseTest ($before.code -eq 0) $before.stderr
            $beforeSpec=($before.stdout | ConvertFrom-Json).repos[0].committed_specs[0]
            $text=$utf8.GetString($saved).Replace('## Done-when',"- Depends on Task 2`n  - Task 3 consumes the output from Task 1.`n## Done-when")
            Write-CloseFixture $path $text
            $s=$single.state | ConvertTo-Json -Depth 100 | ConvertFrom-Json; $s.will_build[0].digest=Get-CloseDigest $path
            $e=$single.engines[0] | ConvertTo-Json -Depth 100 | ConvertFrom-Json; $e.spec.original_digest=$s.will_build[0].digest
            Write-CloseFixtureJson $single.state_path $s; Write-CloseFixtureJson $enginePath $e
            $r=Invoke-CloseCli $single -Json; Assert-CloseTest ($r.code -eq 0) $r.stderr
            $afterSpec=($r.stdout | ConvertFrom-Json).repos[0].committed_specs[0]
            foreach ($field in @('host_tasks','owner_tasks')) {
                Assert-CloseTest (($afterSpec.$field | ConvertTo-Json -Depth 100 -Compress) -ceq ($beforeSpec.$field | ConvertTo-Json -Depth 100 -Compress)) 'cross-references do not change task lists'
            }
        } finally { [IO.File]::WriteAllBytes($path,$saved); [IO.File]::WriteAllBytes($single.state_path,$savedState); [IO.File]::WriteAllBytes($enginePath,$savedEngine) }
    }
    Case 'distinct integration commit with identical journaled blobs succeeds' {
        $fixture=New-CloseFixture 'identical-blobs'; $repo=$fixture.state.repos[0]; $spec=$fixture.state.will_build[0]
        $tree=Git $repo.worktree @('rev-parse',($spec.commit_sha+'^{tree}'))
        $tip=Git $repo.worktree @('commit-tree',$tree,'-p',$spec.commit_sha,'-m','distinct integration checkpoint')
        Assert-CloseTest ($tip -cne $spec.commit_sha) 'integration fixture uses a different commit'
        $fixture.engines[0].integration.tip=$tip
        Write-CloseFixtureJson (Join-Path $fixture.state_root "$($fixture.engines[0].run_id)/engine-state.json") $fixture.engines[0]
        $r=Invoke-CloseCli $fixture -Json; Assert-CloseTest ($r.code -eq 0) $r.stderr
        $output=($r.stdout | ConvertFrom-Json).repos[0].committed_specs[0]
        Assert-CloseTest ($output.integration_tip -ceq $tip -and $output.commit_sha -ceq $spec.commit_sha) 'blob identity accepts distinct integration commit'
    }
    Case 'journaled path present at both commits with different bytes refuses with path reason' {
        $fixture=New-CloseFixture 'different-blobs'; $repo=$fixture.state.repos[0]; $spec=$fixture.state.will_build[0]; $path=$fixture.engines[0].handoff.journaled_paths[0]
        Write-CloseFixture (Join-Path $repo.worktree $path) "different integration bytes`n"
        $tip=Commit-CloseFixture $repo.worktree @($path) $spec.commit_sha 'different integration checkpoint'
        [void](Git $repo.repo @('update-ref',('refs/heads/'+$repo.branch),$spec.commit_sha))
        $actual=Git $repo.worktree @('rev-parse',($spec.commit_sha+':'+$path)); $expected=Git $repo.worktree @('rev-parse',($tip+':'+$path))
        Assert-CloseTest ($actual -cne $expected) 'both fixture commits have different blobs for the path'
        $fixture.engines[0].integration.tip=$tip
        Write-CloseFixtureJson (Join-Path $fixture.state_root "$($fixture.engines[0].run_id)/engine-state.json") $fixture.engines[0]
        Assert-CloseRefusal $fixture ('journaled blob mismatch: '+$path)
    }
    Case 'multiple repos preserve interleaved order and empty repo has tip base without creation HEAD' {
        $state=$multi.state
        $state.will_build += [pscustomobject]@{order=4;spec='parked-spec';repo=$state.repos[2].repo;path=(Join-Path $state.project 'docs/changes/parked-spec.md');digest=('b'*64);state='parked';diagnosis='verify failed';engine_run_id=('f'*32);prelaunch_head=$null;commit_sha=$null}
        Write-CloseFixtureJson $multi.state_path $state
        $r=Invoke-CloseCli $multi -Json; Assert-CloseTest ($r.code -eq 0) $r.stderr
        $p=$r.stdout | ConvertFrom-Json
        Assert-CloseTest ($p.repos.Count -eq 3 -and ($p.repos[0].committed_specs.order -join ',') -ceq '1,3' -and $p.repos[1].committed_specs[0].order -eq 2) 'interleaved drain order grouped per common directory'
        $empty=$p.repos[2]
        Assert-CloseTest ($empty.committed_specs.Count -eq 0 -and $empty.drain_base -ceq $empty.drain_tip -and $empty.drain_base -ceq $multi.bases[2] -and $empty.whole_queue_range -ceq ($empty.drain_tip+'..'+$empty.drain_tip) -and $empty.destination_branch -ceq 'main' -and $empty.nothing_to_integrate -eq $false) 'empty repo provisional integration contract'
        Assert-CloseTest ($empty.noncommitted_specs[0].order -eq 4 -and $empty.noncommitted_specs[0].diagnosis -ceq 'verify failed' -and $empty.noncommitted_specs[0].engine_run_id -ceq ('f'*32) -and $null -eq $empty.noncommitted_specs[0].wrapper_runs) 'noncommitted Engine disposition has no family identity'
        $text=Invoke-CloseCli $multi
        Assert-CloseTest ($text.code -eq 0 -and $text.stdout.Contains($empty.worktree) -and $text.stdout.Contains('parked-spec')) 'multi-repo text includes empty repo and preserved Engine run'
    }
    Case 'entirely empty recorded repo remains actionable and empty drain collection is valid' {
        $empty=New-CloseFixture 'empty' @() 1
        $r=Invoke-CloseCli $empty -Json; Assert-CloseTest ($r.code -eq 0) $r.stderr
        $p=$r.stdout | ConvertFrom-Json; Assert-CloseTest ($p.repos[0].drain_base -ceq $p.repos[0].drain_tip -and -not $p.repos[0].nothing_to_integrate) 'zero-spec repo'
        $text=Invoke-CloseCli $empty
        Assert-CloseTest ($text.code -eq 0 -and $text.stdout.Contains('nothing_to_integrate') -and $text.stdout.Contains('close-out edits')) 'empty repo text explains provisional integration'
        $empty.state.repos=@(); Write-CloseFixtureJson $empty.state_path $empty.state
        $r=Invoke-CloseCli $empty -Json; Assert-CloseTest ($r.code -eq 0 -and ($r.stdout | ConvertFrom-Json).repos.Count -eq 0) 'zero-repo drain'
    }
    Case 'ambient Git tracing and redirection cannot write files' {
        $config=Join-Path $single.state.repos[0].common_dir 'config'; $savedConfig=[IO.File]::ReadAllBytes($config)
        $savedTrace=$env:GIT_TRACE; $savedRedirect=$env:GIT_REDIRECT_STDOUT
        $tracePath=Join-Path $single.root 'unexpected-trace.txt'; $eventPath=Join-Path $single.root 'unexpected-event.json'; $redirectPath=Join-Path $single.root 'unexpected-redirect.txt'
        try {
            [void](Git $single.state.repos[0].repo @('config','trace2.eventTarget',$eventPath))
            $env:GIT_TRACE=$tracePath; $env:GIT_REDIRECT_STDOUT=$redirectPath
            $r=Invoke-CloseCli $single -Json
            Assert-CloseTest ($r.code -eq 0 -and -not [IO.File]::Exists($tracePath) -and -not [IO.File]::Exists($eventPath) -and -not [IO.File]::Exists($redirectPath)) 'Git tracing/redirection disabled'
        } finally { $env:GIT_TRACE=$savedTrace; $env:GIT_REDIRECT_STDOUT=$savedRedirect; [IO.File]::WriteAllBytes($config,$savedConfig) }
    }
    foreach ($status in @('stopped-integrity','stopped-quota','launching','launch-failed','running','stopped-children-alive','Complete')) {
        State-Case "ineligible exact status $status" {param($s) $s.status=$status; $s.diagnosis='preserved diagnosis'}.GetNewClosure() 'ineligible'
    }
    Case 'stopped text contains facts with null actionable fields and inspection guidance' {
        $saved=[IO.File]::ReadAllBytes($multi.state_path)
        try {
            $s=[IO.File]::ReadAllText($multi.state_path,$utf8) | ConvertFrom-Json; $s.status='stopped-integrity'; $s.diagnosis='broken identity'; Write-CloseFixtureJson $multi.state_path $s
            $r=Invoke-CloseCli $multi
            Assert-CloseTest ($r.code -ne 0 -and $r.stdout.Contains('"eligible":  false') -and $r.stdout.Contains('broken identity') -and $r.stdout.Contains('parked-spec') -and $r.stdout.Contains('never resume stopped-integrity blindly')) 'stopped diagnosis and committed/noncommitted facts'
            $p=$r.stdout.Substring(0,$r.stdout.IndexOf("`neligible:")) | ConvertFrom-Json
            foreach ($repo in $p.repos) { Assert-CloseTest ($null -eq $repo.destination_branch -and $null -eq $repo.whole_queue_range -and $null -eq $repo.drain_tip) 'stopped repo targets unavailable'; foreach ($spec in $repo.committed_specs) { Assert-CloseTest ($null -eq $spec.review_command -and $null -eq $spec.review_target) 'stopped review targets unavailable' } }
        } finally { [IO.File]::WriteAllBytes($multi.state_path,$saved) }
    }
    State-Case 'schema identity' {param($s) $s.schema_version=2} 'stored drain roots'
    State-Case 'string schema cannot coerce to version one' {param($s) $s.schema_version='1'} 'stored drain roots'
    State-Case 'drain id identity' {param($s) $s.drain_id='20261013-120000-abcdea'} 'stored drain roots'
    State-Case 'state root identity' {param($s) $s.state_root=$single.root} 'stored drain roots'
    State-Case 'path escape' {param($s) $s.will_build[0].path=Join-Path $single.root 'escaped.md'} 'stored spec target'
    State-Case 'relative repo root' {param($s) $s.repos[0].repo='relative'} 'absolute'
    State-Case 'wrong common directory' {param($s) $s.repos[0].common_dir=$multi.state.repos[0].common_dir} 'stored repo target'
    State-Case 'wrong worktree' {param($s) $s.repos[0].worktree=$multi.state.repos[0].worktree} 'stored repo target'
    State-Case 'wrong branch' {param($s) $s.repos[0].branch='other'} 'stored repo target'
    State-Case 'repo not ready' {param($s) $s.repos[0].state='creating'} 'not ready'
    State-Case 'duplicate repo identity' {param($s) $s.repos+= $s.repos[0]} 'ambiguous repo'
    State-Case 'duplicate spec order' {param($s) $s.will_build[1].order=1} 'spec identity or order' $multi
    State-Case 'prelaunch parent differs from single Git parent' {param($s) $s.will_build[0].prelaunch_head=$s.will_build[0].commit_sha} 'prelaunch parent'
    State-Case 'broken per-repo later commit chain' {param($s) $s.will_build[2].prelaunch_head=$s.will_build[0].prelaunch_head} 'commit chain' $multi
    State-Case 'Engine id path escape' {param($s) $s.will_build[0].engine_run_id='../escape'} 'Engine run identity'
    Engine-Case 'Engine schema' {param($e) $e.schema_version=2} 'Engine identity'
    Engine-Case 'Engine run id' {param($e) $e.run_id='wrong'} 'Engine identity'
    Engine-Case 'numeric Engine run id cannot alias padded stored id' {param($e) $e.run_id=1} 'Engine identity'
    Engine-Case 'array Engine status cannot alias complete' {param($e) $e.status=@('complete')} 'Engine identity'
    Engine-Case 'Engine spec name' {param($e) $e.spec.name='wrong'} 'Engine identity'
    Engine-Case 'Engine repo' {param($e) $e.repo=$single.state.repos[0].repo} 'Engine identity'
    Engine-Case 'Engine incomplete' {param($e) $e.status='running'} 'Engine identity'
    Engine-Case 'Engine handoff incomplete' {param($e) $e.handoff.status='pending'} 'Engine identity'
    Engine-Case 'missing Engine digest' {param($e) $e.spec.PSObject.Properties.Remove('original_digest')} 'original digest'
    Engine-Case 'mismatched Engine digest' {param($e) $e.spec.original_digest='b'*64} 'original digest'
    Engine-Case 'missing Engine base' {param($e) $e.PSObject.Properties.Remove('base_sha')} 'base identity'
    Engine-Case 'mismatched Engine base' {param($e) $e.base_sha=$single.state.will_build[0].commit_sha} 'base identity'
    Engine-Case 'missing integration tip' {param($e) $e.integration.tip=$null} 'integration tip'
    Engine-Case 'unresolvable integration tip' {param($e) $e.integration.tip='0'*40} 'Git identity'
    Engine-Case 'changed journaled blobs including absent/present deletion' {param($e) $e.integration.tip=$single.bases[0]} 'blob mismatch'
    Engine-Case 'changed path set' {param($e) $e.handoff.journaled_paths=@($e.handoff.journaled_paths[0])} 'changed-path set'
    Engine-Case 'unsafe journaled path' {param($e) $e.handoff.journaled_paths=@('../escape')} 'unsafe'
    Engine-Case 'duplicate journaled path' {param($e) $e.handoff.journaled_paths+= $e.handoff.journaled_paths[0]} 'ambiguous journaled'
    Engine-Case 'task not integrated' {param($e) $e.tasks[0].status='succeeded'} 'integration mismatch'
    Engine-Case 'no successful attempt' {param($e) $e.tasks[0].attempts[1].status='failed'} 'successful Engine attempt'
    Engine-Case 'scalar attempts refuse' {param($e) $e.tasks[0].attempts=$e.tasks[0].attempts[1]} 'Engine attempts'
    Engine-Case 'attempt end digest mismatch' {param($e) $e.tasks[0].attempts[1].end_tree_digest='b'*64} 'end digest'
    Engine-Case 'missing attempt wrapper identity' {param($e) $e.tasks[0].attempts[1].wrapper_run_id=$null} 'wrapper run identity'
    Case 'integration uses the final succeeded attempt even when later attempts failed' {
        $path=Join-Path $single.state_root "$($single.engines[0].run_id)/engine-state.json"; $saved=[IO.File]::ReadAllBytes($path)
        try {
            $e=[IO.File]::ReadAllText($path,$utf8) | ConvertFrom-Json
            $e.tasks[0].attempts[0].status='succeeded'
            $e.tasks[0].attempts+= [pscustomobject]@{status='failed';wrapper_run_id='later-failure'}
            Write-CloseFixtureJson $path $e
            $r=Invoke-CloseCli $single -Json
            Assert-CloseTest ($r.code -eq 0 -and ($r.stdout | ConvertFrom-Json).repos[0].committed_specs[0].wrapper_runs[0].wrapper_run_id -ceq 'wrapper-1') 'final successful attempt binding'
        } finally { [IO.File]::WriteAllBytes($path,$saved) }
    }
    Ledger-Case 'missing exact ledger run' {param($rows) $rows[0].run_id='other'; $rows} 'ledger dispatch identity'
    Ledger-Case 'ambiguous exact ledger run' {param($rows) $rows; $rows[0]} 'ambiguous ledger'
    Ledger-Case 'ledger failed dispatch' {param($rows) $rows[0].status='failed'; $rows} 'success identity'
    Ledger-Case 'ledger spec identity mismatch' {param($rows) $rows[0].spec='other'; $rows} 'identity mismatch'
    Ledger-Case 'ledger task identity mismatch' {param($rows) $rows[0].task='2'; $rows} 'identity mismatch'
    Ledger-Case 'numeric ledger task cannot alias string Engine id' {param($rows) $rows[0].task=1; $rows} 'identity mismatch'
    Ledger-Case 'ledger phase identity mismatch' {param($rows) $rows[0].phase='review'; $rows} 'identity mismatch'
    Ledger-Case 'ledger worktree key mismatch' {param($rows) $rows[0].worktree_key=$single.root.Replace('\','/'); $rows} 'identity mismatch'
    Ledger-Case 'ledger worktree spelling cannot contradict key' {param($rows) $rows[0].worktree=$single.root; $rows} 'identity mismatch'
    Ledger-Case 'missing ledger key' {param($rows) $rows[0].worktree_key=$null; $rows} 'identity mismatch'
    Ledger-Case 'missing ledger digest' {param($rows) $rows[0].end_tree_digest=$null; $rows} 'unverifiable'
    Ledger-Case 'unverifiable ledger digest' {param($rows) $rows[0].end_tree_digest='unverifiable'; $rows} 'unverifiable'
    Ledger-Case 'ledger digest mismatch' {param($rows) $rows[0].end_tree_digest='b'*64; $rows} 'end digest'
    Case 'terminal ledger successes, canonical path comparison and newer unrelated row' {
        $saved=[IO.File]::ReadAllBytes($single.ledger_path)
        try {
            foreach ($status in @('done_with_concerns','success','adopted-done')) {
                $row=$single.rows[0] | ConvertTo-Json | ConvertFrom-Json; $row.status=$status; $row.worktree_key=$row.worktree_key.ToUpperInvariant()
                $later=$row | ConvertTo-Json | ConvertFrom-Json; $later.run_id='later-dispatch'; $later.end_tree_digest='b'*64
                Write-CloseFixture $single.ledger_path (($row | ConvertTo-Json -Compress)+"`n"+($later | ConvertTo-Json -Compress))
                $r=Invoke-CloseCli $single -Json; Assert-CloseTest ($r.code -eq 0 -and ($r.stdout | ConvertFrom-Json).repos[0].committed_specs[0].wrapper_runs[0].wrapper_run_id -ceq 'wrapper-1') 'exact successful dispatch with canonical worktree'
            }
        } finally { [IO.File]::WriteAllBytes($single.ledger_path,$saved) }
    }
    Case 'unrelated truncated ledger JSON is ignored and wanted truncated JSON refuses' {
        $saved=[IO.File]::ReadAllBytes($single.ledger_path)
        try {
            $original=$utf8.GetString($saved)
            Write-CloseFixture $single.ledger_path ($original+'{"run_id":"unrelated-dispatch","status":')
            $r=Invoke-CloseCli $single -Json; Assert-CloseTest ($r.code -eq 0) $r.stderr
            $spec=($r.stdout | ConvertFrom-Json).repos[0].committed_specs[0]
            Assert-CloseTest ($spec.wrapper_runs.Count -eq 1 -and $spec.wrapper_runs[0].wrapper_run_id -ceq $single.rows[0].run_id) 'unrelated malformed row leaves exact ledger binding unchanged'
            Write-CloseFixture $single.ledger_path ($original+'{"run_id":"'+$single.rows[0].run_id+'","status":')
            Assert-CloseRefusal $single 'malformed ledger row'
        } finally { [IO.File]::WriteAllBytes($single.ledger_path,$saved) }
    }
    Case 'missing/malformed drain, Engine and ledger sources' {
        foreach ($path in @($single.state_path,(Join-Path $single.state_root "$($single.engines[0].run_id)/engine-state.json"),$single.ledger_path)) {
            $saved=[IO.File]::ReadAllBytes($path)
            try { Remove-Item -LiteralPath $path; Assert-CloseRefusal $single 'missing source'; Write-CloseFixture $path '{bad'; Assert-CloseRefusal $single '' }
            finally { [IO.File]::WriteAllBytes($path,$saved) }
        }
    }
    Case 'recorded spec missing, changed, malformed tasks and UTF-8 normalization' {
        $path=$single.state.will_build[0].path; $original=[IO.File]::ReadAllBytes($path); $stateBytes=[IO.File]::ReadAllBytes($single.state_path)
        try {
            Remove-Item -LiteralPath $path; Assert-CloseRefusal $single ''
            [IO.File]::WriteAllBytes($path,$original); [IO.File]::AppendAllText($path,'changed',$utf8); Assert-CloseRefusal $single 'spec digest changed'
            foreach ($text in @("## Tasks`n- [ ] Task banana - broken`n", "## Tasks`n- [ ] **Task 1 (HOST)** - valid`n- [ ] **Task banana - broken`n", "## Tasks`n- [ ] **Task 1 (HOST)** - valid`n- [ ] Task 2 **broken title**`n", "## Wrong`n- [ ] **Task 2 (HOST)** - omitted section`n", "## Tasks`n- [ ] **Task 2 (HOST)** - one`n- [ ] **Task 2 (OWNER)** - two`n")) {
                Write-CloseFixture $path $text; $s=$single.state | ConvertTo-Json -Depth 100 | ConvertFrom-Json; $s.will_build[0].digest=Get-CloseDigest $path
                $e=$single.engines[0] | ConvertTo-Json -Depth 100 | ConvertFrom-Json; $e.spec.original_digest=$s.will_build[0].digest
                $enginePath=Join-Path $single.state_root "$($e.run_id)/engine-state.json"
                Write-CloseFixtureJson $single.state_path $s; Write-CloseFixtureJson $enginePath $e
                Assert-CloseRefusal $single 'spec'
            }
            [IO.File]::WriteAllBytes($single.state_path,$stateBytes); Write-CloseFixtureJson (Join-Path $single.state_root "$($single.engines[0].run_id)/engine-state.json") $single.engines[0]
            $text=$utf8.GetString($original).Replace("`r`n","`n").Replace("`n","`r`n")
            $bom=[byte[]]@(239,187,191)+$utf8.GetBytes($text); [IO.File]::WriteAllBytes($path,$bom)
            $r=Invoke-CloseCli $single -Json; Assert-CloseTest ($r.code -eq 0) 'BOM/CRLF normalized digest'
        } finally { [IO.File]::WriteAllBytes($path,$original); [IO.File]::WriteAllBytes($single.state_path,$stateBytes); Write-CloseFixtureJson (Join-Path $single.state_root "$($single.engines[0].run_id)/engine-state.json") $single.engines[0] }
    }
    Case 'detached, moved and same-SHA switched destination' {
        $repo=$single.state.repos[0].repo; $base=$single.bases[0]
        try {
            [void](Git $repo @('update-ref','--no-deref','HEAD',$base)); Assert-CloseRefusal $single 'detached'
            [void](Git $repo @('symbolic-ref','HEAD','refs/heads/main'))
            [void](Git $repo @('update-ref','refs/heads/main',$single.state.will_build[0].commit_sha)); Assert-CloseRefusal $single 'destination HEAD moved'
            [void](Git $repo @('update-ref','refs/heads/main',$base)); [void](Git $repo @('update-ref','refs/heads/approved-other',$base)); [void](Git $repo @('symbolic-ref','HEAD','refs/heads/approved-other'))
            $r=Invoke-CloseCli $single -Json; Assert-CloseTest ($r.code -eq 0 -and ($r.stdout | ConvertFrom-Json).repos[0].destination_branch -ceq 'approved-other') 'current symbolic destination, not ref_snapshot'
        } finally { [void](Git $repo @('update-ref','refs/heads/main',$base)); [void](Git $repo @('symbolic-ref','HEAD','refs/heads/main')) }
    }
    Case 'moved drain tip and worktree branch' {
        $repo=$single.state.repos[0]; $tip=$single.state.will_build[0].commit_sha
        try {
            [void](Git $repo.repo @('update-ref',('refs/heads/'+$repo.branch),$single.bases[0])); Assert-CloseRefusal $single 'moved drain tip'
            [void](Git $repo.repo @('update-ref',('refs/heads/'+$repo.branch),$tip)); [void](Git $repo.worktree @('symbolic-ref','HEAD','refs/heads/main')); Assert-CloseRefusal $single 'drain branch/worktree'
        } finally { [void](Git $repo.repo @('update-ref',('refs/heads/'+$repo.branch),$tip)); [void](Git $repo.worktree @('symbolic-ref','HEAD',('refs/heads/'+$repo.branch))) }
    }
    Case 'commit trailer mismatch and merge parent refusal' {
        $repo=$single.state.repos[0]; $spec=$single.state.will_build[0]; $saved=[IO.File]::ReadAllBytes($single.state_path); $tip=$spec.commit_sha
        try {
            $tree=Git $repo.worktree @('rev-parse',($tip+'^{tree}'))
            foreach ($kind in @('trailer','merge')) {
                $commitArguments=@('commit-tree',$tree,'-p',$spec.prelaunch_head,'-m','wrong trailers')
                if ($kind -eq 'merge') { $commitArguments+=@('-p',$tip) }
                $commit=Git $repo.worktree $commitArguments; [void](Git $repo.repo @('update-ref',('refs/heads/'+$repo.branch),$commit))
                $s=$single.state | ConvertTo-Json -Depth 100 | ConvertFrom-Json; $s.will_build[0].commit_sha=$commit; Write-CloseFixtureJson $single.state_path $s
                if ($kind -eq 'trailer') { Assert-CloseRefusal $single 'trailer' } else { Assert-CloseRefusal $single 'commit chain' }
            }
        } finally { [void](Git $repo.repo @('update-ref',('refs/heads/'+$repo.branch),$tip)); [IO.File]::WriteAllBytes($single.state_path,$saved) }
    }
    Case 'CLI allowlist, id syntax, production root selection and StateRoot test boundary' {
        foreach ($extra in @(@('-Plan','../escape','-Json'),@('-Plan',$single.id,'-StateRoot',$single.state_root,'-Json','-Run','other'),@('-Json'))) {
            $r=Invoke-CloseCli $single -Arguments $extra; Assert-CloseTest ($r.code -ne 0 -and $r.stdout -ceq '' -and $r.stderr) 'invalid CLI JSON refusal'
        }
        $env:APEX_DRAIN_TEST_MODE=$null
        $r=Invoke-CloseCli $single -Json; Assert-CloseTest ($r.code -ne 0 -and $r.stderr.Contains('test-only') -and $r.stdout -ceq '') 'production StateRoot denied'
        $env:APEX_STATE_DIR=$single.state_root
        $r=Invoke-CloseCli $single -Arguments @('-Plan',$single.id,'-Json'); Assert-CloseTest ($r.code -eq 0) 'production APEX_STATE_DIR resolution'
        $env:APEX_STATE_DIR=$null; $env:LOCALAPPDATA=$single.root
        # Rename only the owned fixture state root to exercise LOCALAPPDATA/apex.
        $env:APEX_DRAIN_TEST_MODE='1'
        $fallback=New-CloseFixture 'fallback' @() 0
        $fallback.state.state_root=Join-Path $fallback.root 'apex'; Write-CloseFixtureJson $fallback.state_path $fallback.state
        $source=[IO.Path]::GetFullPath($fallback.state_root); $target=[IO.Path]::GetFullPath($fallback.state.state_root)
        Assert-CloseTest ($source.StartsWith($testRoot+'\') -and $target.StartsWith($testRoot+'\')) 'fixture move confined to owned root'
        Move-Item -LiteralPath $source -Destination $target
        $env:LOCALAPPDATA=$fallback.root
        $r=Invoke-CloseCli $fallback -Arguments @('-Plan',$fallback.id,'-Json'); Assert-CloseTest ($r.code -eq 0) 'LOCALAPPDATA fallback'
        $env:APEX_DRAIN_TEST_MODE='1'
        $r=Invoke-CloseCli $single -Arguments @('-Plan',$single.id,'-StateRoot','relative','-Json'); Assert-CloseTest ($r.code -ne 0 -and $r.stderr.Contains('absolute') -and $r.stdout -ceq '') 'relative StateRoot refusal'
        $r=Invoke-CloseCli $single -Arguments @('-Plan',$single.id,'-StateRoot',$single.state.repos[0].repo,'-Json'); Assert-CloseTest ($r.code -ne 0 -and $r.stderr.Contains('outside every Git worktree') -and $r.stdout -ceq '') 'StateRoot in Git worktree refusal'
    }
    Case 'missing lock is never created' {
        $path=Join-Path $single.state_root 'drains/drain.lock'; $saved=[IO.File]::ReadAllBytes($path)
        try { Remove-Item -LiteralPath $path; Assert-CloseRefusal $single 'missing drain lock'; Assert-CloseTest (-not [IO.File]::Exists($path)) 'lock not created' }
        finally { [IO.File]::WriteAllBytes($path,$saved) }
    }
    Case 'stored reparse roots are refused before reading aliased artifacts' {
        $junction=Join-Path $single.root 'state-alias'
        [void](New-Item -ItemType Junction -Path $junction -Target $single.state_root)
        try {
            $r=Invoke-CloseCli $single -Arguments @('-Plan',$single.id,'-StateRoot',$junction,'-Json')
            Assert-CloseTest ($r.code -ne 0 -and $r.stdout -ceq '' -and $r.stderr.Contains('unsafe reparse path')) 'reparse StateRoot refused'
        } finally { [IO.Directory]::Delete($junction) }
    }
    Case 'exclusive lock exhaustion uses twenty half-second retries and releases on refusal' {
        $path=Join-Path $single.state_root 'drains/drain.lock'; $before=Get-CloseSnapshot $single.root
        $lock=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $clock=[Diagnostics.Stopwatch]::StartNew()
        try { $r=Finish-CloseCli (Start-CloseCli @('-Plan',$single.id,'-StateRoot',$single.state_root,'-Json')) }
        finally { $clock.Stop(); $lock.Dispose() }
        Assert-CloseTest ($r.code -ne 0 -and $r.stdout -ceq '' -and $r.stderr.Contains('drain lock busy') -and $clock.Elapsed.TotalSeconds -ge 10 -and $clock.Elapsed.TotalSeconds -lt 30) 'bounded lock refusal'
        Assert-CloseSnapshot $before (Get-CloseSnapshot $single.root)
        $probe=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $probe.Dispose()
    }
    Case 'brief lock contention retries through real CLI, then releases after success' {
        $path=Join-Path $single.state_root 'drains/drain.lock'; $before=Get-CloseSnapshot $single.root
        $lock=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try { $running=Start-CloseCli @('-Plan',$single.id,'-StateRoot',$single.state_root,'-Json'); Start-Sleep -Milliseconds 1800 }
        finally { $lock.Dispose() }
        $r=Finish-CloseCli $running; Assert-CloseTest ($r.code -eq 0 -and $r.stderr -ceq '') 'brief contention succeeds'
        Assert-CloseSnapshot $before (Get-CloseSnapshot $single.root)
        $probe=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $probe.Dispose()
    }
} finally {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process') }
    $resolved=[IO.Path]::GetFullPath($testRoot); $tempPrefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'fixture cleanup escaped TEMP' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures) { Write-Host "$failures of $checks close-out cases failed"; exit 1 }
Write-Host "All $checks close-out cases passed."; exit 0
