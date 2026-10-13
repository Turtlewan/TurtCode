[CmdletBinding()]
param([ValidateSet('core','recovery','resume','safety')][string]$Case)
$ErrorActionPreference='Stop'
$suiteClock=[Diagnostics.Stopwatch]::StartNew()
# The host may supply duplicate case variants in its Windows environment block.
# Start-Process in Windows PowerShell 5.1 cannot construct that environment.
$drainTestPath=$env:Path
[Environment]::SetEnvironmentVariable('PATH',$null,'Process')
[Environment]::SetEnvironmentVariable('Path',$null,'Process')
[Environment]::SetEnvironmentVariable('Path',$drainTestPath,'Process')
$runner=Join-Path $PSScriptRoot 'apex-drain.ps1'
$utf8=[Text.UTF8Encoding]::new($false)
$testRoot=Join-Path $env:TEMP ('apex-drain-test-'+[guid]::NewGuid().ToString('N'))
$savedEnvironment=@{}
foreach ($name in @('APEX_STATE_DIR','APEX_DRAIN_TEST_MODE','APEX_ENGINE_TEST_MODE','APEX_ENGINE_TEST_RETRY_DELAY_SECONDS','ENGINE_TEST_FAKE_SCENARIO','GIT_CONFIG_GLOBAL','APEX_ENGINE_TEST_BASELINE_PATH','APEX_ENGINE_TEST_IGNORE_RESUME_LEDGER')) { $savedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
$global:ApexDrainTest_failures=0;$global:ApexDrainTest_fixture=$null
# Reuse the Engine's hermetic fixture generators, importing function ASTs only.
# The Engine suite itself is never executed by a tagged drain group.
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'engine-test.ps1'),[ref]$tokens,[ref]$errors)
foreach ($name in @('Write-TestText','Invoke-TestGit','Set-TestCommit','New-TestRepo','Convert-TestPath','New-TestSpec','New-TestFakeCodex')) {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if (-not $definition) { throw "Engine fixture helper missing: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
# Verify identities with the production UTF-8 argument/output implementation.
$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors)
foreach ($name in @('ConvertTo-DrainArgument','Invoke-DrainGit','Test-DrainBlobIdentity','Get-DrainStatusRecords')) {
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert-DrainTest($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Read-TestJson([string]$Path) { [IO.File]::ReadAllText($Path) | ConvertFrom-Json }
function Write-TestJson([string]$Path,$Value) { Write-TestText $Path ($Value | ConvertTo-Json -Depth 100) }
function Invoke-DrainTestGitUtf8([string]$Repo,[string[]]$Arguments,[switch]$NullSeparated) {
    # Decode path output locally; never change the process console encoding.
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName='git.exe';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false,$true)
    $info.Arguments=(@(@('-C',$Repo)+$Arguments | ForEach-Object {
        '"'+[regex]::Replace([regex]::Replace($_,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
    }) -join ' ')
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    try {
        [void]$process.Start();$stderr=$process.StandardError.ReadToEndAsync()
        $stdout=$process.StandardOutput.ReadToEnd();$process.WaitForExit()
        if ($process.ExitCode -ne 0) {throw "git failed ($($process.ExitCode)): $($stderr.Result)"}
        if ($NullSeparated) {$output=@($stdout.Split([char[]]@([char]0),[StringSplitOptions]::RemoveEmptyEntries))}
        else {$output=@($stdout.TrimEnd([char[]]@([char]13,[char]10)) -split '\r?\n')}
        return ,$output
    } finally {$process.Dispose()}
}
function New-DrainFixture([string]$Name,[int]$Count=1,[string]$Scenario='done') {
    $repo=New-TestRepo ($Name+'-repo')
    $bare=Join-Path $testRoot ($Name+'-remote.git')
    [void](Invoke-TestGit $testRoot @('init','--bare',$bare))
    [void](Invoke-TestGit $repo @('remote','add','origin',$bare))
    $project=Join-Path $testRoot ($Name+'-project')
    [void][IO.Directory]::CreateDirectory((Join-Path $project 'docs/changes'))
    for ($n=1;$n -le $Count;$n++) {
        $path=Join-Path $project ("docs/changes/spec-$n.md")
        New-TestSpec $repo $path -Single
        $text=[IO.File]::ReadAllText($path)
        $text=[regex]::Replace($text,'(?ms)(## Prerequisites\r?\n).*?(?=\r?\n## Files to Change)',('$1'+"none`n"))
        Write-TestText $path $text
    }
    $stateRoot=Join-Path $testRoot ($Name+'-state')
    $env:APEX_STATE_DIR=$stateRoot;$env:ENGINE_TEST_FAKE_SCENARIO=$Scenario
    $snapshot=@{}
    $common=(Invoke-DrainTestGitUtf8 $repo @('rev-parse','--path-format=absolute','--git-common-dir'))[-1]
    foreach ($path in @('HEAD','index','logs/HEAD')) { $full=Join-Path $common $path; $snapshot[$path]=[Convert]::ToBase64String([IO.File]::ReadAllBytes($full)) }
    $refs=Invoke-TestGit $repo @('for-each-ref','--format=%(refname) %(objectname)')
    $reflogs=@{}
    foreach ($line in $refs) { $ref=($line -split ' ')[0];$path=Join-Path $common ('logs/'+$ref);if (Test-Path -LiteralPath $path) {$reflogs[$ref]=[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))} }
    $tracked=@{}
    foreach ($path in (Invoke-DrainTestGitUtf8 $repo @('ls-files','-z') -NullSeparated)) { $tracked[$path]=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $repo $path))) }
    $global:ApexDrainTest_fixture=[pscustomobject]@{name=$Name;repo=$repo;project=$project;state_root=$stateRoot;bare=$bare;common=$common;snapshot=$snapshot;refs=$refs;reflogs=$reflogs;tracked=$tracked;remote_refs=((Invoke-TestGit $bare @('for-each-ref','--format=%(refname) %(objectname)')) -join "`n");id=$null;state=$null;hooks=$null}
    $hooks=@{
        CodexExecutable='powershell.exe';CodexExecutableArgumentPrefix=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$global:ApexDrainTest_fake)
        UtcNow={ [datetime]::UtcNow }
        SleepMinutes={param($minutes) if ($minutes -eq 0.5) {Start-Sleep -Milliseconds 200} elseif ($minutes -lt 0.5) {Start-Sleep -Milliseconds 30} }
        ChildAlive={param($identity)
            if ($identity.pid -eq $PID) {return $false}
            $p=Get-Process -Id $identity.pid -ErrorAction SilentlyContinue
            if (-not $p) {return $false};try {return $p.StartTime.ToUniversalTime() -eq ([datetime]$identity.start_time).ToUniversalTime()} catch {return $false}
        }
    }
    $hooks.LaunchWorker={param($arguments) & $runner @arguments -TestHooks $hooks | Out-Host }.GetNewClosure()
    $global:ApexDrainTest_fixture.hooks=$hooks
    return $global:ApexDrainTest_fixture
}
function Get-DrainTestState($Fixture=$global:ApexDrainTest_fixture) {
    $paths=@(Get-ChildItem -LiteralPath (Join-Path $Fixture.state_root 'drains') -Directory)
    if ($Fixture.id) {$paths=@($paths | Where-Object Name -eq $Fixture.id)}
    Assert-DrainTest ($paths.Count -eq 1) 'exactly one reservation'
    $Fixture.id=$paths[0].Name;$Fixture.state=Read-TestJson (Join-Path $paths[0].FullName 'drain-state.json')
    return $Fixture.state
}
function Invoke-DrainTestStart($Fixture=$global:ApexDrainTest_fixture) {
    $output=@(& $runner -Project $Fixture.project -TestHooks $Fixture.hooks)
    $code=$LASTEXITCODE
    $s=Get-DrainTestState $Fixture
    [pscustomobject]@{code=$code;output=$output;state=$s}
}
function Invoke-DrainTestResume($Fixture=$global:ApexDrainTest_fixture) {
    $output=@(& $runner -Resume $Fixture.id -Project $Fixture.project -TestHooks $Fixture.hooks)
    $code=$LASTEXITCODE;$s=Get-DrainTestState $Fixture
    [pscustomobject]@{code=$code;output=$output;state=$s}
}
function Assert-DrainBoundaries($Fixture=$global:ApexDrainTest_fixture) {
    $s=Get-DrainTestState $Fixture
    Assert-DrainTest (((Invoke-TestGit $Fixture.bare @('for-each-ref','--format=%(refname) %(objectname)')) -join "`n") -ceq $Fixture.remote_refs) 'bare origin ref snapshot changed'
    foreach ($line in $Fixture.refs) {
        $parts=$line -split ' ';$actual=(Invoke-TestGit $Fixture.repo @('rev-parse',$parts[0]))[-1]
        Assert-DrainTest ($actual -ceq $parts[1]) "pre-existing ref changed: $($parts[0])"
    }
    foreach ($path in $Fixture.snapshot.Keys) { Assert-DrainTest ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $Fixture.common $path))) -ceq $Fixture.snapshot[$path]) "main $path changed" }
    foreach ($ref in $Fixture.reflogs.Keys) { Assert-DrainTest ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $Fixture.common ('logs/'+$ref)))) -ceq $Fixture.reflogs[$ref]) "pre-existing reflog changed: $ref" }
    foreach ($path in $Fixture.tracked.Keys) { Assert-DrainTest ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $Fixture.repo $path))) -ceq $Fixture.tracked[$path]) "main tracked bytes changed: $path" }
    $allowed=@($s.repos.branch)
    foreach ($line in (Invoke-TestGit $Fixture.repo @('for-each-ref','--format=%(refname) %(objectname)'))) {
        if ($Fixture.refs -ccontains $line) {continue}
        $ref=($line -split ' ')[0]
        Assert-DrainTest ($ref -in @($allowed | ForEach-Object {'refs/heads/'+$_}) -or $ref -match '^refs/heads/codex/spec-\d+-[0-9a-f]{8}-') "unexpected new ref: $ref"
    }
    $report=[IO.File]::ReadAllText((Join-Path $Fixture.project "docs/drain/$($Fixture.id).md"))
    foreach ($field in @($s.drain_id,$s.project,$s.started_at,$s.updated_at,'Status:','WILL BUILD','NEEDS YOU','300 minutes','quota_waited_minutes:','quota_budget_resets:','wave-3 close-out')) { Assert-DrainTest ($report.Contains($field)) "report missing $field" }
    foreach ($r in $s.repos) { Assert-DrainTest ($report.Contains($r.branch) -and $report.Contains($r.worktree)) 'report repo fields' }
}
function Invoke-DrainCase([string]$Name,[scriptblock]$Body) {
    try { & $Body;Assert-DrainBoundaries;Write-Host "PASS $Name" -ForegroundColor Green }
    catch { $global:ApexDrainTest_failures++;Write-Host "FAIL ${Name}: $($_.Exception.Message) $($_.ScriptStackTrace)" -ForegroundColor Red }
}
function Set-DrainCrash([string]$Checkpoint) {
    $global:ApexDrainTest_crashCheckpoint=$Checkpoint;$global:ApexDrainTest_crashed=$false
    $global:ApexDrainTest_fixture.hooks.AfterCheckpoint={param($name,$state) if ($name -eq $global:ApexDrainTest_crashCheckpoint -and -not $global:ApexDrainTest_crashed) {$global:ApexDrainTest_crashed=$true;throw "fixture crash: $name"} }
}
function Set-DrainFullFence([string]$Body) {
    $verify=Join-Path $global:ApexDrainTest_fixture.repo 'verify.ps1'
    Write-TestText $verify $Body
    [void](Set-TestCommit $global:ApexDrainTest_fixture.repo @('verify.ps1') (Invoke-TestGit $global:ApexDrainTest_fixture.repo @('rev-parse','HEAD'))[-1])
    # Updating the fixture before start establishes a new immutable boundary snapshot.
    $global:ApexDrainTest_fixture.refs=Invoke-TestGit $global:ApexDrainTest_fixture.repo @('for-each-ref','--format=%(refname) %(objectname)')
    foreach ($path in @('HEAD','index','logs/HEAD')) {$global:ApexDrainTest_fixture.snapshot[$path]=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $global:ApexDrainTest_fixture.common $path)))}
    foreach ($ref in $global:ApexDrainTest_fixture.reflogs.Keys | ForEach-Object {$_}) {$global:ApexDrainTest_fixture.reflogs[$ref]=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $global:ApexDrainTest_fixture.common ('logs/'+$ref))))}
    $global:ApexDrainTest_fixture.tracked['verify.ps1']=[Convert]::ToBase64String([IO.File]::ReadAllBytes($verify))
}
function Refresh-DrainBoundary {
    $f=$global:ApexDrainTest_fixture
    $f.refs=Invoke-TestGit $f.repo @('for-each-ref','--format=%(refname) %(objectname)')
    foreach ($path in @('HEAD','index','logs/HEAD')) {$f.snapshot[$path]=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $f.common $path)))}
    $f.reflogs=@{};$f.tracked=@{}
    foreach ($line in $f.refs) {$ref=($line -split ' ')[0];$path=Join-Path $f.common ('logs/'+$ref);if (Test-Path -LiteralPath $path) {$f.reflogs[$ref]=[Convert]::ToBase64String([IO.File]::ReadAllBytes($path))}}
    foreach ($path in (Invoke-DrainTestGitUtf8 $f.repo @('ls-files','-z') -NullSeparated)) {$f.tracked[$path]=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $f.repo $path)))}
}
try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $env:APEX_DRAIN_TEST_MODE='1';$env:APEX_ENGINE_TEST_MODE='1';$env:APEX_ENGINE_TEST_RETRY_DELAY_SECONDS='0'
    $env:GIT_CONFIG_GLOBAL=Join-Path $testRoot 'gitconfig'
    $emptyIgnore=Join-Path $testRoot 'empty-ignore';Write-TestText $emptyIgnore ''
    Write-TestText $env:GIT_CONFIG_GLOBAL ("[user]`nname = Drain Fixture`nemail = drain@example.invalid`n[safe]`ndirectory = *`n[core]`nautocrlf = false`nexcludesFile = " + $emptyIgnore.Replace('\','/') + "`n")
    $global:ApexDrainTest_fake=Join-Path $testRoot 'fake-codex.ps1';[void](New-TestFakeCodex $global:ApexDrainTest_fake)
    if (-not $Case -or $Case -eq 'core') {
        $gitJob=$null
        try {
            $jobRepo=Join-Path $testRoot 'git-job-repo'
            [void][IO.Directory]::CreateDirectory($jobRepo)
            [void](Invoke-TestGit $jobRepo @('init','-q'))
            Write-TestText (Join-Path $jobRepo 'job-untracked.txt') 'untracked job fixture'
            $gitJob=Start-Job -ArgumentList $runner,$jobRepo -ScriptBlock {
                param($Runner,$Repo)
                $ErrorActionPreference='Stop'
                $tokens=$null;$errors=$null
                $ast=[Management.Automation.Language.Parser]::ParseFile($Runner,[ref]$tokens,[ref]$errors)
                foreach ($name in @('ConvertTo-DrainArgument','Invoke-DrainGit')) {
                    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
                    if (-not $definition) {throw "Drain Git helper missing: $name"}
                    . ([scriptblock]::Create($definition.Extent.Text))
                }
                Invoke-DrainGit $Repo @('status','--porcelain=v1','-z','--untracked-files=all')
            }
            $completed=Wait-Job -Job $gitJob -Timeout 60
            Assert-DrainTest ($null -ne $completed) 'drain Git job timed out after 60 seconds'
            Assert-DrainTest ($gitJob.State -eq 'Completed') 'drain Git job did not complete successfully'
            $result=Receive-Job -Job $gitJob -ErrorAction Stop
            Assert-DrainTest ($result.exit_code -eq 0) 'drain Git job exit code'
            Assert-DrainTest ($result.raw_output.Contains("?? job-untracked.txt`0")) 'drain Git job returns untracked status record'
            Write-Host 'PASS drain Git returns untracked status from a bounded job' -ForegroundColor Green
        } catch {
            $global:ApexDrainTest_failures++
            Write-Host "FAIL drain Git job: $($_.Exception.Message) $($_.ScriptStackTrace)" -ForegroundColor Red
        } finally {
            if ($gitJob) {
                if ($gitJob.State -notin @('Completed','Failed','Stopped')) {Stop-Job -Job $gitJob}
                Remove-Job -Job $gitJob
            }
        }
        foreach ($specialPath in @('src/with space.py','app/[id]/page.tsx')) {
            $global:ApexDrainTest_specialPath=$specialPath
            Invoke-DrainCase "literal NUL-separated manifest path $specialPath" {
                $f=New-DrainFixture $(if ($global:ApexDrainTest_specialPath.Contains(' ')) {'space-path'} else {'literal-path'})
                Set-DrainCrash 'repo-creating';[void](Invoke-DrainTestStart)
                $s=Get-DrainTestState;$wt=$s.repos[0].worktree
                Write-TestText (Join-Path $wt 'app/i/page.tsx') 'ignored sibling baseline'
                $f.hooks.AfterCheckpoint={param($name,$state)
                    if ($name -eq 'engine-complete') {
                        $path=@(Get-ChildItem -Path (Join-Path $state.state_root '*/engine-state.json') -File)[0].FullName
                        $e=Read-TestJson $path;$relative=$global:ApexDrainTest_specialPath
                        # Extend the real ASCII handoff to isolate drain path handling.
                        Write-TestText (Join-Path $e.integration.worktree $relative) "special path blob`n"
                        $e.integration.tip=Set-TestCommit $e.integration.worktree @($relative) $e.integration.tip
                        Write-TestText (Join-Path $state.repos[0].worktree $relative) "special path blob`n"
                        $e.plan.waves[0].tasks[0].files=@($e.plan.waves[0].tasks[0].files)+[pscustomobject]@{path=$relative;op='create'}
                        $e.handoff.journaled_paths=@($e.handoff.journaled_paths)+$relative;Write-TestJson $path $e
                    }
                }
                $r=Invoke-DrainTestResume
                Assert-DrainTest ($r.state.status -eq 'complete' -and $r.state.will_build[0].state -eq 'committed') 'special manifest path commits without residue or integrity stop'
                $paths=Invoke-DrainTestGitUtf8 $wt @('diff-tree','--no-commit-id','--name-only','-z','-r','HEAD') -NullSeparated
                Assert-DrainTest ($paths.Count -eq 2 -and $paths -ccontains $global:ApexDrainTest_specialPath -and $paths -ccontains 'src/a.py') 'commit contains exactly journaled paths, excludes glob sibling'
                $e=Read-TestJson (Join-Path $f.state_root "$($r.state.will_build[0].engine_run_id)/engine-state.json")
                Assert-DrainTest (Test-DrainBlobIdentity $r.state.repos[0] $e -Head) 'production HEAD blob verification for special path'
                Assert-DrainTest ([IO.File]::ReadAllText((Join-Path $wt 'app/i/page.tsx')) -ceq 'ignored sibling baseline') 'sibling bytes preserved'
            }
        }
        Invoke-DrainCase 'NUL porcelain rename records consume both literal paths' {
            $f=New-DrainFixture 'rename-records' 0;[void](Invoke-DrainTestStart)
            $rows=@(Get-DrainStatusRecords ("R  new name`0old name`0?? next file`0"))
            Assert-DrainTest ($rows.Count -eq 2 -and $rows[0].paths.Count -eq 2 -and $rows[0].paths[1] -ceq 'old name' -and $rows[1].paths[0] -ceq 'next file') 'rename source consumed without corrupting next record'
        }
        Invoke-DrainCase 'drain git disables installed commit hooks' {
            $f=New-DrainFixture 'disabled-hooks'
            $global:ApexDrainTest_hookMarker=Join-Path $testRoot 'hook-marker.txt'
            $f.hooks.AfterCheckpoint={param($name,$state)
                if ($name -eq 'engine-complete') {
                    $hookBody="#!/bin/sh`nprintf invoked > '"+$global:ApexDrainTest_hookMarker.Replace('\','/')+"'`nexit 1`n"
                    foreach ($hook in @('pre-commit','prepare-commit-msg')) {Write-TestText (Join-Path $global:ApexDrainTest_fixture.common ('hooks/'+$hook)) $hookBody}
                    # prepare-commit-msg also runs with --no-verify, discriminating hooksPath.
                    $config=(Invoke-DrainGit $state.repos[0].worktree @('config','--get','core.hooksPath')).output -join ''
                    Assert-DrainTest ($config -ceq 'NUL') 'production git carries core.hooksPath=NUL'
                }
            }
            $r=Invoke-DrainTestStart
            Assert-DrainTest ($r.state.will_build[0].state -eq 'committed' -and -not (Test-Path -LiteralPath $global:ApexDrainTest_hookMarker)) 'commit succeeds without running failing marker hooks'
        }
        Invoke-DrainCase 'dependent specs, serial commits and preserved Engine artifacts' {
            $f=New-DrainFixture 'dependent' 2
            $path=Join-Path $f.project 'docs/changes/spec-2.md';$text=[IO.File]::ReadAllText($path).Replace("none`n",'- `spec-1`'+"`n");Write-TestText $path $text
            $r=Invoke-DrainTestStart
            Assert-DrainTest ($r.code -eq 0 -and $r.state.status -eq 'complete') ('drain did not complete: '+($r.output -join ' | '))
            Assert-DrainTest (@($r.state.will_build | Where-Object state -eq 'committed').Count -eq 2) 'two committed specs'
            $wt=$r.state.repos[0].worktree
            foreach ($s in $r.state.will_build) {
                $e=Read-TestJson (Join-Path $f.state_root "$($s.engine_run_id)/engine-state.json")
                Assert-DrainTest ($e.repo -eq $wt -and (Test-Path -LiteralPath $e.integration.worktree)) 'Engine artifacts preserved at drain target'
                $msg=Invoke-TestGit $wt @('show','-s','--format=%B',$s.commit_sha)
                Assert-DrainTest (($msg -join "`n").Contains("Drain-Spec: $($s.spec)") -and ($msg -join "`n").Contains("Engine-Run: $($s.engine_run_id)")) 'both commit trailers'
                Assert-DrainTest ((Invoke-TestGit $wt @('rev-parse',"$($s.commit_sha):src/a.py"))[-1] -eq (Invoke-TestGit $wt @('rev-parse',"$($e.integration.tip):src/a.py"))[-1]) 'committed blob identity'
                Assert-DrainTest (((Invoke-DrainTestGitUtf8 $wt @('diff-tree','--no-commit-id','--name-only','-z','-r',$s.commit_sha) -NullSeparated) -join "`n") -eq 'src/a.py') 'path scoped commit'
            }
            Assert-DrainTest (-not (Test-Path -LiteralPath (Join-Path $f.common 'apex-drain-owner.json'))) 'owner removed at complete'
        }
        Invoke-DrainCase 'linked manifest roots share a drain worktree' {
            $f=New-DrainFixture 'linked' 2
            $linked=Join-Path $testRoot 'linked-manifest'
            [void](Invoke-TestGit $f.repo @('worktree','add','--detach',$linked,'HEAD'))
            $path=Join-Path $f.project 'docs/changes/spec-2.md'
            Write-TestText $path ([IO.File]::ReadAllText($path).Replace((Convert-TestPath $f.repo),(Convert-TestPath $linked)))
            $r=Invoke-DrainTestStart
            Assert-DrainTest ($r.state.status -eq 'complete' -and @($r.state.repos).Count -eq 1) 'one shared common-dir group'
            foreach ($s in $r.state.will_build) {$e=Read-TestJson (Join-Path $f.state_root "$($s.engine_run_id)/engine-state.json");Assert-DrainTest ($e.repo -eq $r.state.repos[0].worktree) 'shared Engine target'}
        }
        Invoke-DrainCase 'BOM CRLF digest and report HOST checks' {
            $f=New-DrainFixture 'bom'
            $path=Join-Path $f.project 'docs/changes/spec-1.md'
            $text=[IO.File]::ReadAllText($path).Replace("## Progress","- [ ] HOST fixture sign-off; never execute this check.`n`n## Progress").Replace("`r`n","`n").Replace("`n","`r`n")
            [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($true))
            $r=Invoke-DrainTestStart
            Assert-DrainTest ($r.state.will_build[0].state -eq 'committed') 'BOM CRLF preserved sorter digest'
            $e=Read-TestJson (Join-Path $f.state_root "$($r.state.will_build[0].engine_run_id)/engine-state.json")
            $report=[IO.File]::ReadAllText((Join-Path $f.project "docs/drain/$($f.id).md"))
            Assert-DrainTest (@($e.plan.host_checks | Where-Object {$_.text -like '*HOST fixture sign-off*'}).Count -eq 1 -and $report.Contains('HOST fixture sign-off')) 'untagged HOST check appears in report'
        }
        Invoke-DrainCase 'project is its own build repo and exact sorter NEEDS YOU survives' {
            $f=New-DrainFixture 'project-build' 2
            $changes=Join-Path $f.repo 'docs/changes';[void][IO.Directory]::CreateDirectory($changes)
            foreach ($n in @(1,2)) {Copy-Item -LiteralPath (Join-Path $f.project "docs/changes/spec-$n.md") -Destination (Join-Path $changes "spec-$n.md")}
            $path=Join-Path $changes 'spec-2.md';Write-TestText $path ([IO.File]::ReadAllText($path).Replace('risk: medium','risk: high'))
            [void](Set-TestCommit $f.repo @('docs/changes/spec-1.md','docs/changes/spec-2.md') (Invoke-TestGit $f.repo @('rev-parse','HEAD'))[-1])
            $f.project=$f.repo;Refresh-DrainBoundary
            $r=Invoke-DrainTestStart
            Assert-DrainTest ($r.state.status -eq 'complete' -and @($r.state.will_build).Count -eq 1 -and $r.state.will_build[0].state -eq 'committed' -and @($r.state.needs_you).Count -eq 1 -and $r.state.needs_you[0].spec -eq 'spec-2' -and $r.state.needs_you[0].reason_code -eq 'risk-high') 'sorter ordered build and owner list retained exactly'
            Assert-DrainTest (Test-Path -LiteralPath (Join-Path $f.repo "docs/drain/$($f.id).md")) 'only project report added to main tree'
            foreach ($repo in @($f.repo,$r.state.repos[0].worktree)) {
                $hooks=(Invoke-DrainTestGitUtf8 $repo @('rev-parse','--path-format=absolute','--git-path','hooks'))[-1]
                Assert-DrainTest (@(Get-ChildItem -LiteralPath $hooks -File | Where-Object Name -notlike '*.sample').Count -eq 0) 'boundary fixture has no installed hooks'
            }
        }
    }
    if (-not $Case -or $Case -eq 'recovery') {
        Invoke-DrainCase 'park restores all manifest paths including staged-edited and ignored creates' {
            $f=New-DrainFixture 'all-path-recovery' 1 'blocked'
            Write-TestText (Join-Path $f.repo 'src/delete.py') "delete baseline`n"
            [void](Set-TestCommit $f.repo @('src/delete.py') (Invoke-TestGit $f.repo @('rev-parse','HEAD'))[-1]);Refresh-DrainBoundary
            $path=Join-Path $f.project 'docs/changes/spec-1.md';$text=[IO.File]::ReadAllText($path)
            $text=$text.Replace('| src/a.py | modify | fixture |',"| src/a.py | modify | fixture |`n| src/delete.py | delete | fixture |`n| src/new.py | create | fixture |`n| src/ignored.py | create | fixture |")
            $text=$text.Replace('"path": "src/a.py", "op": "modify"','"path": "src/a.py", "op": "modify" }, { "path": "src/delete.py", "op": "delete" }, { "path": "src/new.py", "op": "create" }, { "path": "src/ignored.py", "op": "create"')
            $text=$text.Replace('files: src/a.py','files: src/a.py, src/delete.py, src/new.py, src/ignored.py');Write-TestText $path $text
            $f.hooks.AfterCheckpoint={param($name,$state)
                if ($name -eq 'engine-complete') {
                    $wt=$state.repos[0].worktree
                    [IO.File]::AppendAllText((Join-Path $wt 'src/a.py'),'touched');[IO.File]::Delete((Join-Path $wt 'src/delete.py'))
                    Write-TestText (Join-Path $wt 'src/new.py') 'staged create'
                    $blob=(Invoke-TestGit $wt @('hash-object','-w','--','src/new.py'))[-1]
                    [void](Invoke-TestGit $wt @('update-index','--add','--cacheinfo',"100644,$blob,src/new.py"))
                    [IO.File]::AppendAllText((Join-Path $wt 'src/new.py'),'edited after staging')
                    Write-TestText (Join-Path $wt 'src/ignored.py') 'blanket ignored create'
                }
            }
            $r=Invoke-DrainTestStart;$wt=$r.state.repos[0].worktree
            Assert-DrainTest ($r.state.status -eq 'complete' -and $r.state.will_build[0].state -eq 'parked') 'parked run recovered'
            Assert-DrainTest (-not (Test-Path -LiteralPath (Join-Path $wt 'src/new.py')) -and -not (Test-Path -LiteralPath (Join-Path $wt 'src/ignored.py')) -and (Test-Path -LiteralPath (Join-Path $wt 'src/delete.py'))) 'created deleted and staged paths restored'
            Assert-DrainTest (-not ((Invoke-DrainTestGitUtf8 $wt @('status','--porcelain','--ignored','-uall','-z') -NullSeparated) -join '')) 'exact prelaunch status restored'
        }
        foreach ($unicodeMode in @('mutate','noop')) {
        $global:ApexDrainTest_unicodeMode=$unicodeMode
        Invoke-DrainCase "non-ASCII fence $unicodeMode binds blobs even with equal digests" {
            $f=New-DrainFixture ('unicode-identity-'+$global:ApexDrainTest_unicodeMode)
            $global:ApexDrainTest_unicodePath='src/'+[char]0x00e9+'.py'
            Write-TestText (Join-Path $f.repo $global:ApexDrainTest_unicodePath) "base-a`n"
            [void](Set-TestCommit $f.repo @($global:ApexDrainTest_unicodePath) (Invoke-TestGit $f.repo @('rev-parse','HEAD'))[-1])
            # Engine requires every wave-manifest path to change in its commit.
            # Complete the real ASCII-only task first, then extend the drain-facing
            # handoff fixture with an unchanged baseline path; no coder writes it.
            $f.hooks.AfterCheckpoint={param($name,$state)
                if ($name -eq 'engine-complete') {
                    $paths=@(Get-ChildItem -Path (Join-Path $state.state_root '*/engine-state.json') -File)
                    Assert-DrainTest ($paths.Count -eq 1) 'one completed Engine handoff fixture'
                    $path=$paths[0].FullName;$e=Read-TestJson $path
                    Assert-DrainTest ($e.status -eq 'complete' -and $e.handoff.status -eq 'complete' -and (@($e.handoff.journaled_paths) -join "`n") -ceq 'src/a.py') 'real ASCII Engine task completed cleanly'
                    Assert-DrainTest (((Invoke-DrainTestGitUtf8 $e.integration.worktree @('diff','--name-only','-z',$e.base_sha,$e.integration.tip) -NullSeparated) -join "`n") -ceq 'src/a.py') 'Engine changed only ASCII path'
                    $file=[pscustomobject]@{path=$global:ApexDrainTest_unicodePath;op='modify'}
                    $e.plan.waves[0].tasks[0].files=@($e.plan.waves[0].tasks[0].files)+$file
                    $e.handoff.journaled_paths=@($e.handoff.journaled_paths)+$file.path
                    Write-TestJson $path $e
                    # Seed an MM index row only in the drain worktree. The working
                    # blob still matches integration before the fence; the quoted
                    # status row stays MM while the fence changes its working bytes.
                    $wt=$state.repos[0].worktree
                    $expected=(Invoke-DrainGit $wt @('rev-parse',"$($e.integration.tip):$($file.path)")).output[-1]
                    Assert-DrainTest ((Invoke-DrainGit $wt @('hash-object','--',$file.path)).output[-1] -ceq $expected) 'production Unicode working blob matches integration before fence'
                    $staged=(Invoke-TestGit $wt @('hash-object','-w','--','src/a.py'))[-1]
                    [void](Invoke-TestGit $wt @('update-index','--cacheinfo',"100644,$staged,$($file.path)"))
                    Assert-DrainTest ((Invoke-DrainTestGitUtf8 $wt @('status','--porcelain','-z') -NullSeparated) -ccontains ('MM '+$file.path)) 'drain-only Unicode index fixture is dirty before D1'
                }
            }
            # Source uses numeric characters so Windows PowerShell's UTF-8-without-BOM parser cannot best-fit it.
            if ($global:ApexDrainTest_unicodeMode -eq 'mutate') {Set-DrainFullFence "if ((Split-Path -Leaf `$PSScriptRoot) -like 'drain-*') {[IO.File]::AppendAllText((Join-Path `$PSScriptRoot ('src/'+[char]0x00e9+'.py')),'mutated')};exit 0"}
            else {Set-DrainFullFence 'exit 0'}
            Refresh-DrainBoundary
            $r=Invoke-DrainTestStart
            if ($global:ApexDrainTest_unicodeMode -eq 'noop') {
                Assert-DrainTest ($r.state.status -eq 'complete' -and $r.state.will_build[0].state -eq 'committed' -and $r.state.will_build[0].fence_d1 -eq $r.state.will_build[0].fence_d2) 'same forged Unicode journal commits with no-op fence'
                $e=Read-TestJson (Join-Path $f.state_root "$($r.state.will_build[0].engine_run_id)/engine-state.json")
                Assert-DrainTest (Test-DrainBlobIdentity $r.state.repos[0] $e -Head) 'production UTF-8 HEAD blobs equal integration for every journal path'
                return
            }
            Assert-DrainTest ($r.state.will_build[0].state -eq 'parked' -and $r.state.will_build[0].rejection_reason -eq 'fence-mutated-tree' -and $r.state.will_build[0].fence_d1 -cne $r.state.will_build[0].fence_d2 -and -not $r.state.will_build[0].commit_sha) 'Unicode mutation changes the fence digest and parks without a commit'
            Assert-DrainTest ($r.state.status -eq 'complete' -and $r.state.will_build[0].fence_d1) 'full fence ran and recovery completed'
            foreach ($path in @('src/a.py',$global:ApexDrainTest_unicodePath)) {
                Assert-DrainTest (([IO.File]::ReadAllText((Join-Path $r.state.repos[0].worktree $path))).Replace("`r`n","`n") -ceq "base-a`n") "manifest restored: $path"
            }
        }
        }
        Invoke-DrainCase 'park restores manifest and skips dependent while independent continues' {
            $f=New-DrainFixture 'park' 3 'blocked'
            $path=Join-Path $f.project 'docs/changes/spec-2.md';Write-TestText $path ([IO.File]::ReadAllText($path).Replace("none`n",'- `spec-1`'+"`n"))
            $f.hooks.AfterCheckpoint={param($name,$state) if ($name -eq 'recovery-started') {$env:ENGINE_TEST_FAKE_SCENARIO='done'} }
            $r=Invoke-DrainTestStart
            Assert-DrainTest ($r.state.status -eq 'complete' -and $r.state.will_build[0].state -eq 'parked' -and $r.state.will_build[1].state -eq 'skipped' -and $r.state.will_build[2].state -eq 'committed') 'park / skip / independent progression'
        }
        foreach ($mode in @('red','mutate','residue','move','switch')) {
            $global:ApexDrainTest_fenceMode=$mode
            Invoke-DrainCase "full fence $mode" {
                $f=New-DrainFixture ('fence-'+$global:ApexDrainTest_fenceMode)
                # Engine gates pass; only the drain worktree's full fence exercises this boundary.
                $action=switch ($global:ApexDrainTest_fenceMode) {
                    'red' {'exit 1'}
                    'mutate' {"[IO.File]::AppendAllText((Join-Path `$PSScriptRoot 'src/a.py'),'fence mutation')"}
                    'residue' {"[void][IO.Directory]::CreateDirectory((Join-Path `$PSScriptRoot '.pytest_cache'));[IO.File]::WriteAllText((Join-Path `$PSScriptRoot '.pytest_cache/x'),'cache')"}
                    'move' {"`$tree=(& git write-tree);`$sha=('fence move' | & git commit-tree `$tree -p HEAD);& git update-ref HEAD `$sha"}
                    'switch' {"& git symbolic-ref HEAD refs/heads/fixture-other"}
                }
                if ($global:ApexDrainTest_fenceMode -eq 'switch') {[void](Invoke-TestGit $f.repo @('update-ref','refs/heads/fixture-other',(Invoke-TestGit $f.repo @('rev-parse','HEAD'))[-1]))}
                Set-DrainFullFence ("if ((Split-Path -Leaf `$PSScriptRoot) -like 'drain-*') { $action };exit 0")
                if ($global:ApexDrainTest_fenceMode -eq 'switch') {[void](Invoke-TestGit $f.repo @('update-ref','refs/heads/fixture-other',(Invoke-TestGit $f.repo @('rev-parse','HEAD'))[-1]));Refresh-DrainBoundary}
                $r=Invoke-DrainTestStart
                if ($global:ApexDrainTest_fenceMode -in @('red','mutate')) {
                    Assert-DrainTest ($r.state.will_build[0].state -eq 'parked') 'fence rejection parks'
                    Assert-DrainTest (([IO.File]::ReadAllText((Join-Path $r.state.repos[0].worktree 'src/a.py'))).Replace("`r`n","`n") -eq "base-a`n") 'manifest restored'
                    Assert-DrainTest ($r.state.will_build[0].rejection_reason -eq $(if ($global:ApexDrainTest_fenceMode -eq 'red') {'fence-red'} else {'fence-mutated-tree'})) 'fence reason'
                } else {
                    Assert-DrainTest ($r.state.status -eq 'stopped-integrity') 'unsafe fence stops integrity'
                    if ($global:ApexDrainTest_fenceMode -eq 'residue') {Assert-DrainTest ($r.state.will_build[0].rejection_reason -eq 'fence-residue' -and $r.state.will_build[0].fence_d1 -eq $r.state.will_build[0].fence_d2) 'ignored cache residue caught despite equal tree digests'}
                    if ($global:ApexDrainTest_fenceMode -in @('move','switch')) {Assert-DrainTest (-not $r.state.will_build[0].recovery_outcome -and ([IO.File]::ReadAllText((Join-Path $r.state.repos[0].worktree 'src/a.py'))).Contains('fake-one')) 'HEAD movement detected before recovery writes'}
                }
            }
        }
        Invoke-DrainCase 'recovery preflights every manifest reparse point before writes' {
            $f=New-DrainFixture 'junction' 1 'blocked'
            $outside=Join-Path $testRoot 'junction-outside';[void][IO.Directory]::CreateDirectory($outside);Write-TestText (Join-Path $outside 'a.py') 'untouched'
            $global:ApexDrainTest_junctionOutside=$outside
            $f.hooks.AfterCheckpoint={param($name,$state)
                if ($name -eq 'recovery-started') {
                    $src=Join-Path $state.repos[0].worktree 'src'
                    Rename-Item -LiteralPath $src -NewName 'src-before-junction'
                    [void](New-Item -ItemType Junction -Path $src -Target $global:ApexDrainTest_junctionOutside)
                }
            }
            $r=Invoke-DrainTestStart
            Assert-DrainTest ($r.state.status -eq 'stopped-integrity' -and [IO.File]::ReadAllText((Join-Path $outside 'a.py')) -eq 'untouched') 'no write through junction'
            # Remove the fixture junction itself before eventual recursive fixture cleanup.
            [IO.Directory]::Delete((Join-Path $r.state.repos[0].worktree 'src'))
        }
        Invoke-DrainCase 'unsafe other manifest ancestor refuses the entire restore set' {
            $f=New-DrainFixture 'other-junction' 1 'blocked'
            $path=Join-Path $f.project 'docs/changes/spec-1.md';New-TestSpec $f.repo $path
            $text=[IO.File]::ReadAllText($path).Replace('src/b.py','src/other/b.py')
            $text=[regex]::Replace($text,'(?ms)(## Prerequisites\r?\n).*?(?=\r?\n## Files to Change)',('$1'+"none`n"));Write-TestText $path $text
            $global:ApexDrainTest_otherOutside=Join-Path $testRoot 'other-junction-outside';[void][IO.Directory]::CreateDirectory($global:ApexDrainTest_otherOutside)
            Write-TestText (Join-Path $global:ApexDrainTest_otherOutside 'b.py') 'outside untouched'
            $f.hooks.AfterCheckpoint={param($name,$state)
                if ($name -eq 'recovery-started') {
                    $wt=$state.repos[0].worktree;[IO.File]::AppendAllText((Join-Path $wt 'src/a.py'),'must remain touched')
                    [void](New-Item -ItemType Junction -Path (Join-Path $wt 'src/other') -Target $global:ApexDrainTest_otherOutside)
                }
            }
            $r=Invoke-DrainTestStart;$wt=$r.state.repos[0].worktree
            Assert-DrainTest ($r.state.status -eq 'stopped-integrity' -and ([IO.File]::ReadAllText((Join-Path $wt 'src/a.py'))).Contains('must remain touched') -and [IO.File]::ReadAllText((Join-Path $global:ApexDrainTest_otherOutside 'b.py')) -eq 'outside untouched') 'all paths preflighted before any recovery write'
            [IO.Directory]::Delete((Join-Path $wt 'src/other'))
        }
    }
    if (-not $Case -or $Case -eq 'resume') {
        Invoke-DrainCase 'restart waits uncapped for live recorded Engine owner' {
            $f=New-DrainFixture 'live-owner-uncapped';Set-DrainCrash 'engine-complete';[void](Invoke-DrainTestStart)
            $s=Get-DrainTestState
            $global:ApexDrainTest_ownerStatePath=@(Get-ChildItem -Path (Join-Path $f.state_root '*/engine-state.json') -File)[0].FullName
            $e=Read-TestJson $global:ApexDrainTest_ownerStatePath
            $s.will_build[0].engine_run_id=$e.run_id;$s.will_build[0].state='engine-running'
            Write-TestJson (Join-Path $f.state_root "drains/$($f.id)/drain-state.json") $s
            $e.status='running';$e.engine_owner=[pscustomobject]@{pid=424243;start_time='2000-01-01T00:00:00Z'}
            Write-TestJson $global:ApexDrainTest_ownerStatePath $e
            $global:ApexDrainTest_ownerWaits=0;$global:ApexDrainTest_ownerClock=[datetime]::UtcNow
            $f.hooks.UtcNow={$global:ApexDrainTest_ownerClock}
            $f.hooks.ChildAlive={param($identity) return $identity.pid -eq 424243 -and $global:ApexDrainTest_ownerWaits -lt 520}
            $f.hooks.SleepMinutes={param($minutes)
                $global:ApexDrainTest_ownerWaits++;$global:ApexDrainTest_ownerClock=$global:ApexDrainTest_ownerClock.AddMinutes($minutes)
                if ($global:ApexDrainTest_ownerWaits -eq 519) {
                    $current=Get-DrainTestState
                    Assert-DrainTest ($current.status -eq 'running' -and $current.will_build[0].state -eq 'engine-running') 'still waiting for owner beyond 255 minutes'
                }
                if ($global:ApexDrainTest_ownerWaits -eq 520) {
                    $e=Read-TestJson $global:ApexDrainTest_ownerStatePath;$e.status='complete';$e.engine_owner=$null
                    Write-TestJson $global:ApexDrainTest_ownerStatePath $e
                }
            }
            $r=Invoke-DrainTestResume
            Assert-DrainTest ($global:ApexDrainTest_ownerWaits -eq 520 -and $r.state.status -eq 'complete' -and $r.state.will_build[0].state -eq 'committed' -and -not $r.state.will_build[0].engine_resume_attempted) 'owner exits after 260 minutes and original Engine handoff commits'
        }
        foreach ($kind in @('single-dead-resume','resume-marker-crash')) {
            $global:ApexDrainTest_deadResumeKind=$kind
            Invoke-DrainCase "running dead owner $kind" {
                $f=New-DrainFixture $global:ApexDrainTest_deadResumeKind 2
                $global:ApexDrainTest_resumeLaunches=0;$global:ApexDrainTest_heldEngineLock=$null;$global:ApexDrainTest_injectedRunning=$false;$global:ApexDrainTest_markerCrashed=$false
                $f.hooks.AfterCheckpoint={param($name,$state)
                    if ($name -eq 'engine-launched' -and $state.will_build[0].engine_resume_attempted -and $state.will_build[0].state -eq 'engine-running') {$global:ApexDrainTest_resumeLaunches++}
                    if ($name -eq 'engine-complete' -and -not $global:ApexDrainTest_injectedRunning) {
                        $global:ApexDrainTest_injectedRunning=$true
                        $dir=@(Get-ChildItem -LiteralPath $state.state_root -Directory | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'engine-state.json')})[0].FullName
                        $path=Join-Path $dir 'engine-state.json';$e=Read-TestJson $path;$e.status='running';$e.engine_owner=[pscustomobject]@{pid=999999;start_time='2000-01-01T00:00:00Z'};Write-TestJson $path $e
                        if ($global:ApexDrainTest_deadResumeKind -eq 'single-dead-resume') {$global:ApexDrainTest_heldEngineLock=[IO.File]::Open((Join-Path $dir 'engine.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
                    }
                    if ($name -eq 'engine-resume-issued' -and $global:ApexDrainTest_deadResumeKind -eq 'resume-marker-crash' -and -not $global:ApexDrainTest_markerCrashed) {$global:ApexDrainTest_markerCrashed=$true;throw 'crash at durable resume marker'}
                }
                try {
                    $r=Invoke-DrainTestStart
                    if ($global:ApexDrainTest_deadResumeKind -eq 'resume-marker-crash') {$r=Invoke-DrainTestResume}
                    Assert-DrainTest ($r.state.status -eq 'complete' -and $r.state.will_build[0].state -eq 'parked' -and $r.state.will_build[0].diagnosis -eq 'engine resume did not converge' -and $r.state.will_build[1].state -eq 'committed') 'dead running owner parks and independent advances'
                    Assert-DrainTest ($r.state.will_build[0].engine_resume_attempted -and $global:ApexDrainTest_resumeLaunches -eq $(if ($global:ApexDrainTest_deadResumeKind -eq 'single-dead-resume') {1} else {0})) 'exactly one durable Engine resume attempt'
                } finally {if ($global:ApexDrainTest_heldEngineLock) {$global:ApexDrainTest_heldEngineLock.Dispose()}}
            }
        }
        foreach ($checkpoint in @('repo-creating','engine-launched','engine-complete','commit-created')) {
            $global:ApexDrainTest_nextCheckpoint=$checkpoint
            Invoke-DrainCase "restart at $checkpoint converges" {
                $f=New-DrainFixture ('crash-'+$global:ApexDrainTest_nextCheckpoint)
                Set-DrainCrash $global:ApexDrainTest_nextCheckpoint
                [void](Invoke-DrainTestStart)
                $r=Invoke-DrainTestResume
                Assert-DrainTest ($r.state.status -eq 'complete' -and $r.state.will_build[0].state -eq 'committed') ('restart failed: '+($r.output -join ' | '))
                Assert-DrainTest (@(Get-ChildItem -LiteralPath $f.state_root -Directory | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'engine-state.json')}).Count -eq 1) 'no duplicate Engine run'
                Assert-DrainTest ((Invoke-TestGit $r.state.repos[0].worktree @('rev-list','--count',($r.state.will_build[0].prelaunch_head+'..HEAD')))[-1] -eq '1') 'no duplicate drain commit'
            }
        }
        Invoke-DrainCase 'crash in finalizing reruns the entire full fence' {
            $f=New-DrainFixture 'finalizing-crash'
            $global:ApexDrainTest_fenceCounter=Join-Path $testRoot 'finalizing-fence-count.txt'
            $counterLiteral=$global:ApexDrainTest_fenceCounter.Replace("'","''")
            Set-DrainFullFence ("if ((Split-Path -Leaf `$PSScriptRoot) -like 'drain-*') {`$count=0;if (Test-Path -LiteralPath '$counterLiteral') {`$count=[int][IO.File]::ReadAllText('$counterLiteral')};[IO.File]::WriteAllText('$counterLiteral',[string](`$count+1))};exit 0")
            $global:ApexDrainTest_finalizingCrashed=$false
            $f.hooks.AfterCheckpoint={param($name,$state)
                if ($name -eq 'engine-complete' -and -not $global:ApexDrainTest_finalizingCrashed) {
                    $global:ApexDrainTest_finalizingCrashed=$true
                    $dir=@(Get-ChildItem -LiteralPath $state.state_root -Directory | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'engine-state.json')})[0].FullName
                    $e=Read-TestJson (Join-Path $dir 'engine-state.json');$state.will_build[0].engine_run_id=$e.run_id;$state.will_build[0].state='finalizing'
                    Write-TestJson (Join-Path $state.state_root "drains/$($state.drain_id)/drain-state.json") $state
                    & powershell.exe -NoProfile -File (Join-Path $PSScriptRoot 'apex-baseline-check.ps1') -Worktree $state.repos[0].worktree -Full | Out-Host
                    throw 'crash after untrusted partial finalization'
                }
            }
            [void](Invoke-DrainTestStart);$r=Invoke-DrainTestResume
            Assert-DrainTest ($r.state.status -eq 'complete' -and [int][IO.File]::ReadAllText($global:ApexDrainTest_fenceCounter) -eq 2) 'full fence reran from scratch after finalizing crash'
        }
        Invoke-DrainCase 'quota resumes once through canonical StateRoot' {
            $f=New-DrainFixture 'quota' 1 'usage_limit_jsonl'
            $global:ApexDrainTest_quotaDelays=@()
            $global:ApexDrainTest_decoyState=Join-Path $testRoot 'quota-decoy-state'
            $f.hooks.SleepMinutes={param($minutes) if ($minutes -ge 15) {$global:ApexDrainTest_quotaDelays += $minutes;$env:ENGINE_TEST_FAKE_SCENARIO='done';$env:APEX_STATE_DIR=$global:ApexDrainTest_decoyState} else {Start-Sleep -Milliseconds 30} }
            try {$r=Invoke-DrainTestStart} finally {$env:APEX_STATE_DIR=$f.state_root}
            Assert-DrainTest ($r.state.status -eq 'complete' -and $r.state.quota_waited_minutes -eq 15 -and $global:ApexDrainTest_quotaDelays[0] -eq 15) 'quota wait and canonical resume completed'
            Assert-DrainTest (-not (Test-Path -LiteralPath $global:ApexDrainTest_decoyState)) 'Engine resume ignores inherited decoy StateRoot'
        }
        Invoke-DrainCase 'quota cap and explicit fresh budget' {
            $f=New-DrainFixture 'quota-cap' 1 'usage_limit_jsonl'
            $global:ApexDrainTest_quotaDelays=@()
            $f.hooks.SleepMinutes={param($minutes) if ($minutes -ge 15) {$global:ApexDrainTest_quotaDelays += $minutes} else {Start-Sleep -Milliseconds 30} }
            $r=Invoke-DrainTestStart
            Assert-DrainTest ($r.state.status -eq 'stopped-quota' -and $r.state.quota_waited_minutes -eq 300 -and ($global:ApexDrainTest_quotaDelays -join ',') -eq '15,30,60,60,60,75') 'exact quota schedule and cap'
            $env:ENGINE_TEST_FAKE_SCENARIO='done'
            $r=Invoke-DrainTestResume
            Assert-DrainTest ($r.state.status -eq 'complete' -and $r.state.quota_budget_resets -eq 1 -and $r.state.quota_waited_minutes -eq 15) 'fresh quota budget recorded'
        }
        Invoke-DrainCase 'prelaunch digest race rejects correlated Engine snapshot' {
            $f=New-DrainFixture 'digest-race'
            $f.hooks.AfterCheckpoint={param($name,$state) if ($name -eq 'pre-engine-start') {[IO.File]::AppendAllText($state.will_build[0].path,"`n<!-- race -->`n")} }
            $r=Invoke-DrainTestStart
            Assert-DrainTest ($r.state.will_build[0].state -eq 'spec-changed' -and $r.state.will_build[0].engine_run_id -and -not $r.state.will_build[0].engine_resume_attempted) 'digest race preserves run without resume'
        }
        Invoke-DrainCase 'sorter snapshot changed before comparison parks without Engine' {
            $f=New-DrainFixture 'changed-before-comparison'
            $f.hooks.AfterCheckpoint={param($name,$state) if ($name -eq 'repo-creating') {[IO.File]::AppendAllText($state.will_build[0].path,"`n<!-- changed after snapshot -->`n")} }
            $r=Invoke-DrainTestStart
            Assert-DrainTest ($r.state.status -eq 'complete' -and $r.state.will_build[0].state -eq 'spec-changed' -and -not $r.state.will_build[0].engine_run_id) 'changed sorter snapshot is never launched'
        }
        foreach ($kind in @('extra-parent','wrong-parent','wrong-paths')) {
            $global:ApexDrainTest_trailerKind=$kind
            Invoke-DrainCase "trailer recognition refuses $kind" {
                $f=New-DrainFixture ('trailer-'+$global:ApexDrainTest_trailerKind)
                $global:ApexDrainTest_trailerCrashed=$false
                $f.hooks.AfterCheckpoint={param($name,$state)
                    if ($name -eq 'commit-created' -and -not $global:ApexDrainTest_trailerCrashed) {
                        $global:ApexDrainTest_trailerCrashed=$true;$s=$state.will_build[0];$wt=$state.repos[0].worktree
                        $e=Read-TestJson (Join-Path $state.state_root "$($s.engine_run_id)/engine-state.json")
                        $tree=(Invoke-TestGit $wt @('rev-parse','HEAD^{tree}'))[-1]
                        $parents=@('-p',$s.prelaunch_head)
                        if ($global:ApexDrainTest_trailerKind -eq 'extra-parent') {$parents+=@('-p',$e.integration.tip)}
                        if ($global:ApexDrainTest_trailerKind -eq 'wrong-parent') {$parents=@('-p',$e.integration.tip)}
                        if ($global:ApexDrainTest_trailerKind -eq 'wrong-paths') {
                            Write-TestText (Join-Path $wt 'src/extra.py') 'extra'
                            $blob=(Invoke-TestGit $wt @('hash-object','-w','--','src/extra.py'))[-1]
                            [void](Invoke-TestGit $wt @('update-index','--add','--cacheinfo',"100644,$blob,src/extra.py"));$tree=(Invoke-TestGit $wt @('write-tree'))[-1]
                        }
                        $message="fixture trailer`n`nDrain-Spec: $($s.spec)`nEngine-Run: $($s.engine_run_id)`n"
                        $sha=@($message | & git -C $wt commit-tree $tree @parents)[-1]
                        [void](Invoke-TestGit $wt @('update-ref',"refs/heads/$($state.repos[0].branch)",$sha))
                        throw 'crash after forged trailer HEAD'
                    }
                }
                [void](Invoke-DrainTestStart);$r=Invoke-DrainTestResume
                Assert-DrainTest ($r.state.status -eq 'stopped-integrity' -and -not $r.state.will_build[0].commit_sha) 'invalid trailer ancestry/path set never recognized'
            }
        }
        Invoke-DrainCase 'persisted start snapshot forbids adopting pre-existing branch' {
            $f=New-DrainFixture 'snapshot-branch';Set-DrainCrash 'repo-creating';[void](Invoke-DrainTestStart)
            $s=Get-DrainTestState;$s.repos[0].ref_snapshot += "`nrefs/heads/$($s.repos[0].branch) $((Invoke-TestGit $f.repo @('rev-parse','HEAD'))[-1])"
            Write-TestJson (Join-Path $f.state_root "drains/$($f.id)/drain-state.json") $s
            $r=Invoke-DrainTestResume;Assert-DrainTest ($r.state.status -eq 'stopped-integrity') 'branch from start snapshot never adopted'
        }
        foreach ($outcome in @('parked','spec-changed')) {
            $global:ApexDrainTest_recoveryOutcome=$outcome
            Invoke-DrainCase "durable recovery resumes into $outcome" {
                $f=New-DrainFixture ('recover-crash-'+$global:ApexDrainTest_recoveryOutcome) 1 $(if ($global:ApexDrainTest_recoveryOutcome -eq 'parked') {'blocked'} else {'done'})
                Set-DrainCrash 'recovery-started'
                if ($global:ApexDrainTest_recoveryOutcome -eq 'spec-changed') {
                    $f.hooks.AfterCheckpoint={param($name,$state)
                        if ($name -eq 'pre-engine-start') {[IO.File]::AppendAllText($state.will_build[0].path,"`n<!-- race -->`n")}
                        if ($name -eq 'recovery-started' -and -not $global:ApexDrainTest_crashed) {$global:ApexDrainTest_crashed=$true;throw 'recovery crash'}
                    }
                }
                [void](Invoke-DrainTestStart)
                $r=Invoke-DrainTestResume
                Assert-DrainTest ($r.state.status -eq 'complete' -and $r.state.will_build[0].state -eq $global:ApexDrainTest_recoveryOutcome -and -not $r.state.will_build[0].commit_sha) 'persisted recovery outcome takes precedence'
            }
        }
        Invoke-DrainCase 'launch intent with zero correlation stops after bounded rescan' {
            $f=New-DrainFixture 'no-correlation';Set-DrainCrash 'pre-engine-start'
            [void](Invoke-DrainTestStart);$r=Invoke-DrainTestResume
            Assert-DrainTest ($r.state.status -eq 'stopped-integrity' -and $r.state.diagnosis -like '*spec-1*15 minutes*') 'zero correlation integrity stop'
        }
    }
    if (-not $Case -or $Case -eq 'safety') {
        Invoke-DrainCase 'stateless abandoned reservation permits later start' {
            $f=New-DrainFixture 'stateless-reservation' 0
            $abandonedId='20260101-000000-abcdea';$dir=Join-Path $f.state_root "drains/$abandonedId"
            [void][IO.Directory]::CreateDirectory($dir)
            Write-TestJson (Join-Path $dir 'reservation.json') @{schema_version=1;drain_id=$abandonedId;project=$f.project;state_root=$f.state_root;start=@{pid=999999;start_time='2000-01-01T00:00:00Z'}}
            $output=@(& $runner -Project $f.project -TestHooks $f.hooks);$code=$LASTEXITCODE
            $abandoned=Read-TestJson (Join-Path $dir 'drain-state.json')
            Assert-DrainTest ($code -eq 0 -and $abandoned.status -eq 'launch-failed' -and $abandoned.diagnosis -eq 'abandoned launcher') 'stateless reservation reconciled under lock'
            $f.id=@(Get-ChildItem -LiteralPath (Join-Path $f.state_root 'drains') -Directory | Where-Object Name -ne $abandonedId)[0].Name
            Assert-DrainTest ((Get-DrainTestState).status -eq 'complete') 'later start completes after stateless abandonment'
        }
        Invoke-DrainCase 'empty queue production WMI detached worker' {
            $f=New-DrainFixture 'wmi-empty' 0
            $f.hooks.Remove('LaunchWorker')
            $r=Invoke-DrainTestStart
            Assert-DrainTest ($r.code -eq 0) ('WMI launch was not confirmed: '+($r.output -join ' | '))
            for ($n=0;$n -lt 120 -and $r.state.status -ne 'complete';$n++) {Start-Sleep -Milliseconds 500;$r.state=Get-DrainTestState}
            Assert-DrainTest ($r.state.status -eq 'complete' -and $r.state.owner.pid -ne $PID -and -not @($r.state.will_build).Count) 'real detached worker owns and completes empty queue'
            Assert-DrainTest (Test-Path -LiteralPath (Join-Path $f.state_root "drains/$($f.id)/worker.log")) 'production worker log'
        }
        Invoke-DrainCase 'empty queue terminal confirmation' {
            $f=New-DrainFixture 'empty' 0
            $r=Invoke-DrainTestStart
            Assert-DrainTest ($r.code -eq 0 -and $r.state.status -eq 'complete' -and $r.state.owner.pid -eq $PID) 'terminal owner confirmation'
        }
        Invoke-DrainCase 'live recorded Engine child blocks start and cross-StateRoot ownership' {
            $f=New-DrainFixture 'live-child';Set-DrainCrash 'engine-launched'
            [void](Invoke-DrainTestStart)
            $s=Get-DrainTestState;$global:ApexDrainTest_liveIdentity=$s.will_build[0].engine_child
            $f.hooks.ChildAlive={param($identity) return $identity.pid -eq $global:ApexDrainTest_liveIdentity.pid -and $identity.start_time -eq $global:ApexDrainTest_liveIdentity.start_time}
            $output=@(& $runner -Project $f.project -TestHooks $f.hooks);Assert-DrainTest ($LASTEXITCODE -ne 0 -and ($output -join ' ') -like '*live drain*') 'same StateRoot live child blocks'
            $env:APEX_STATE_DIR=Join-Path $testRoot 'other-state'
            $output=@(& $runner -Project $f.project -TestHooks $f.hooks);Assert-DrainTest ($LASTEXITCODE -ne 0 -and ($output -join ' ') -like "*owned by drain $($f.id)*") 'cross-StateRoot durable owner blocks'
            $env:APEX_STATE_DIR=$f.state_root
            Assert-DrainTest (Test-Path -LiteralPath (Join-Path $f.common 'apex-drain-owner.json')) 'dead worker ownership persists'
        }
        Invoke-DrainCase 'live launching identity and busy StateRoot lock' {
            $f=New-DrainFixture 'launch-owner' 0
            $f.hooks.LaunchWorker={param($arguments) Write-TestJson (Join-Path $arguments.StateRoot 'drains/drain.lock.owner.json') @{drain_id='20260101-000000-abcdef';pid=$PID;start_time=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')} }
            $f.hooks.ChildAlive={param($identity) return $identity.pid -eq $PID}
            # A start identity does not confirm a worker.
            $output=@(& $runner -Project $f.project -TestHooks $f.hooks)
            $s=Get-DrainTestState;Assert-DrainTest ($LASTEXITCODE -ne 0 -and $s.status -eq 'launch-failed') 'start identity alone cannot confirm'
            Assert-DrainTest ($s.owner -eq $null) 'other drain advisory owner cannot confirm this reservation'
            $s.status='launching';Write-TestJson (Join-Path $f.state_root "drains/$($f.id)/drain-state.json") $s
            $output=@(& $runner -Project $f.project -TestHooks $f.hooks);Assert-DrainTest (($output -join ' ') -like '*live drain*') 'live start blocks second reservation'
            $lock=[IO.File]::Open((Join-Path $f.state_root 'drains/drain.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try {
                $output=@(& $runner -Run $f.id -StateRoot $f.state_root -TestHooks $f.hooks)
                $s=Get-DrainTestState;Assert-DrainTest ($s.status -eq 'launch-failed' -and $s.diagnosis -eq 'drain lock busy') 'busy worker bounded retry marks only own launching state'
            } finally {$lock.Dispose()}
        }
        foreach ($entry in @('start','resume')) {
            $global:ApexDrainTest_abandonedEntry=$entry
            Invoke-DrainCase "abandoned launcher reconciles on $entry" {
                $f=New-DrainFixture ('abandoned-'+$global:ApexDrainTest_abandonedEntry) 0
                $f.hooks.LaunchWorker={param($arguments)}
                [void](Invoke-DrainTestStart)
                $s=Get-DrainTestState;$s.status='launching';$s.start=[pscustomobject]@{pid=999999;start_time='2000-01-01T00:00:00Z'}
                Write-TestJson (Join-Path $f.state_root "drains/$($f.id)/drain-state.json") $s
                $f.hooks.LaunchWorker={param($arguments) & $runner @arguments -TestHooks $global:ApexDrainTest_fixture.hooks | Out-Host}
                if ($global:ApexDrainTest_abandonedEntry -eq 'resume') {
                    $r=Invoke-DrainTestResume;Assert-DrainTest ($r.state.status -eq 'complete') 'abandoned launching resume admitted'
                } else {
                    $output=@(& $runner -Project $f.project -TestHooks $f.hooks)
                    $s=Read-TestJson (Join-Path $f.state_root "drains/$($f.id)/drain-state.json")
                    Assert-DrainTest ($s.status -eq 'launch-failed' -and $s.diagnosis -eq 'abandoned launcher') 'start scan durably reconciles abandoned launching state'
                    $global:ApexDrainTest_newDrain=@(Get-ChildItem -LiteralPath (Join-Path $f.state_root 'drains') -Directory | Where-Object Name -ne $f.id)[0]
                    Assert-DrainTest ((Read-TestJson (Join-Path $global:ApexDrainTest_newDrain.FullName 'drain-state.json')).status -eq 'complete') 'new drain allowed after abandonment'
                    Assert-DrainTest (([IO.File]::ReadAllText((Join-Path $f.project "docs/drain/$($f.id).md"))).Contains('launch-failed')) 'abandonment report rewritten'
                }
            }
        }
        Invoke-DrainCase 'brief lock contention retries successfully' {
            $f=New-DrainFixture 'brief-lock' 0;$f.hooks.LaunchWorker={param($arguments)};[void](Invoke-DrainTestStart)
            $s=Get-DrainTestState;$s.status='launching';Write-TestJson (Join-Path $f.state_root "drains/$($f.id)/drain-state.json") $s
            $global:ApexDrainTest_briefLock=[IO.File]::Open((Join-Path $f.state_root 'drains/drain.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $global:ApexDrainTest_briefRetries=0
            $f.hooks.SleepMinutes={param($minutes) $global:ApexDrainTest_briefRetries++;if ($global:ApexDrainTest_briefRetries -eq 4) {$global:ApexDrainTest_briefLock.Dispose()} }
            try {$output=@(& $runner -Run $f.id -StateRoot $f.state_root -TestHooks $f.hooks);$s=Get-DrainTestState;Assert-DrainTest ($s.status -eq 'complete' -and $global:ApexDrainTest_briefRetries -eq 4) 'bounded retry survives short scan hold'} finally {$global:ApexDrainTest_briefLock.Dispose()}
        }
        Invoke-DrainCase 'cross-reservation child blocks resume admission' {
            $f=New-DrainFixture 'resume-other-child' 0;[void](Invoke-DrainTestStart)
            $s=Get-DrainTestState;$s.status='stopped-quota';Write-TestJson (Join-Path $f.state_root "drains/$($f.id)/drain-state.json") $s
            $other=($s | ConvertTo-Json -Depth 100) | ConvertFrom-Json
            $other.drain_id='20260101-000000-abcdef';$other.status='stopped-children-alive';$other.owner=[pscustomobject]@{pid=424242;start_time='2000-01-01T00:00:00Z'}
            $dir=Join-Path $f.state_root "drains/$($other.drain_id)";[void][IO.Directory]::CreateDirectory($dir);Write-TestJson (Join-Path $dir 'drain-state.json') $other
            $f.hooks.ChildAlive={param($identity) return $identity.pid -eq 424242}
            $r=Invoke-DrainTestResume
            Assert-DrainTest ($r.code -ne 0 -and ($r.output -join ' ') -like '*live drain 20260101-000000-abcdef*' -and $r.state.quota_budget_resets -eq 0) 'resume excludes only its own identity set'
        }
        Invoke-DrainCase 'unknown durable repo owner refuses' {
            $f=New-DrainFixture 'unknown-owner';Set-DrainCrash 'repo-creating';[void](Invoke-DrainTestStart)
            Write-TestJson (Join-Path $f.common 'apex-drain-owner.json') @{state_root=(Join-Path $testRoot 'missing-owner-state');drain_id='20260101-000000-abcdef'}
            $r=Invoke-DrainTestResume
            Assert-DrainTest ($r.code -ne 0 -and ($r.output -join ' ') -like '*build repo owned by unknown drain*') 'missing owner state refuses'
            $report=[IO.File]::ReadAllText((Join-Path $f.project "docs/drain/$($f.id).md"));Assert-DrainTest ($report.Contains('build repo owned by unknown drain')) 'ownership report diagnosis'
        }
        Invoke-DrainCase 'StateRoot inside Git worktree rejected without side effects' {
            $f=New-DrainFixture 'inside' 0
            $env:APEX_STATE_DIR=Join-Path $f.repo 'inside-state'
            $output=@(& $runner -Project $f.project -TestHooks $f.hooks)
            Assert-DrainTest ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath $env:APEX_STATE_DIR) -and -not (Test-Path -LiteralPath (Join-Path $f.project 'docs/drain'))) 'inside start no side effects'
            $env:APEX_STATE_DIR=$f.state_root;[void](Invoke-DrainTestStart)
            $env:APEX_STATE_DIR=Join-Path $f.repo 'inside-state'
            $output=@(& $runner -Resume $f.id -TestHooks $f.hooks)
            Assert-DrainTest ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath $env:APEX_STATE_DIR)) 'inside resume no side effects'
            $env:APEX_STATE_DIR=$f.state_root
        }
        Invoke-DrainCase 'dirty tracked drain baseline refuses new Engine' {
            $f=New-DrainFixture 'dirty-baseline';Set-DrainCrash 'repo-creating';[void](Invoke-DrainTestStart)
            $s=Get-DrainTestState;[IO.File]::AppendAllText((Join-Path $s.repos[0].worktree 'src/a.py'),'dirty')
            $r=Invoke-DrainTestResume
            Assert-DrainTest ($r.state.status -eq 'stopped-integrity' -and $r.state.diagnosis -eq 'dirty tracked prelaunch baseline' -and -not $r.state.will_build[0].engine_run_id) 'dirty baseline stops before launch'
        }
        Invoke-DrainCase 'ignored and untracked prelaunch entries remain allowed and recorded' {
            $f=New-DrainFixture 'allowed-baseline';Set-DrainCrash 'repo-creating';[void](Invoke-DrainTestStart)
            $s=Get-DrainTestState;$wt=$s.repos[0].worktree
            Write-TestText (Join-Path $wt 'cache.tmp') 'ignored baseline'
            Write-TestText (Join-Path $wt 'residue-untracked.txt') 'untracked baseline'
            $r=Invoke-DrainTestResume
            Assert-DrainTest ($r.state.status -eq 'complete' -and $r.state.will_build[0].state -eq 'committed' -and $r.state.will_build[0].prelaunch_status.Contains('!! cache.tmp') -and $r.state.will_build[0].prelaunch_status.Contains('?? residue-untracked.txt')) 'prelaunch ignored/untracked allowed and retained'
            Assert-DrainTest ([IO.File]::ReadAllText((Join-Path $wt 'cache.tmp')) -eq 'ignored baseline') 'baseline ignored bytes preserved'
        }
        Invoke-DrainCase 'ambiguous correlation stops without commit' {
            $f=New-DrainFixture 'ambiguous'
            $f.hooks.AfterCheckpoint={param($name,$state)
                if ($name -eq 'engine-complete') {
                    $dir=@(Get-ChildItem -LiteralPath $state.state_root -Directory | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'engine-state.json')})[0].FullName
                    $e=Read-TestJson (Join-Path $dir 'engine-state.json');$e.run_id=[guid]::NewGuid().ToString('N')
                    $other=Join-Path $state.state_root $e.run_id;[void][IO.Directory]::CreateDirectory($other);Write-TestJson (Join-Path $other 'engine-state.json') $e
                }
            }
            $r=Invoke-DrainTestStart
            Assert-DrainTest ($r.state.status -eq 'stopped-integrity' -and $r.state.diagnosis -like '*ambiguous*' -and -not $r.state.will_build[0].commit_sha) 'multiple correlation matches stop integrity'
        }
        foreach ($ledgerKind in @('ends','cap')) {
            $global:ApexDrainTest_ledgerKind=$ledgerKind
            Invoke-DrainCase "dead launcher live ledger $ledgerKind" {
                $f=New-DrainFixture ('ledger-'+$global:ApexDrainTest_ledgerKind)
                $global:ApexDrainTest_ledgerInjected=$false;$global:ApexDrainTest_ledgerWaits=0
                $f.hooks.AfterCheckpoint={param($name,$state)
                    if ($name -eq 'engine-complete') {
                        $dir=@(Get-ChildItem -LiteralPath $state.state_root -Directory | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'engine-state.json')})[0].FullName
                        $e=Read-TestJson (Join-Path $dir 'engine-state.json');$attempt=$e.tasks[0].attempts[-1]
                        $global:ApexDrainTest_ledgerPath=Join-Path $state.state_root 'progress/codex-run-ledger.jsonl'
                        $row=@{spec=$e.spec.name;task=$e.tasks[0].id;worktree=$attempt.worktree;pid=$PID;pid_start=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');launcher_pid=999999;launcher_start='2000-01-01T00:00:00Z';started=[datetime]::UtcNow.ToString('o');run_id=[guid]::NewGuid().ToString('N');status='running'}
                        [IO.File]::AppendAllText($global:ApexDrainTest_ledgerPath,($row|ConvertTo-Json -Compress)+"`n")
                        $global:ApexDrainTest_ledgerInjected=$true
                    }
                }
                $f.hooks.SleepMinutes={param($minutes)
                    if ($global:ApexDrainTest_ledgerInjected) {
                        $global:ApexDrainTest_ledgerWaits++
                        if ($global:ApexDrainTest_ledgerKind -eq 'ends' -and $global:ApexDrainTest_ledgerWaits -eq 3) {
                            $rows=@([IO.File]::ReadAllLines($global:ApexDrainTest_ledgerPath));$row=$rows[-1]|ConvertFrom-Json;$row.pid=0;$row.pid_start=$null;$row.status='done';$rows[-1]=$row|ConvertTo-Json -Compress;Write-TestText $global:ApexDrainTest_ledgerPath ($rows -join "`n")
                        }
                    }
                }
                $r=Invoke-DrainTestStart
                if ($global:ApexDrainTest_ledgerKind -eq 'ends') {Assert-DrainTest ($r.state.status -eq 'complete' -and $global:ApexDrainTest_ledgerWaits -eq 3) 'matching live ledger prevents advance until row ends'}
                else {Assert-DrainTest ($r.state.status -eq 'stopped-children-alive' -and $global:ApexDrainTest_ledgerWaits -ge 510) 'ledger quiescence cap with no kill'}
            }
        }
        Invoke-DrainCase 'quiescence cap waits but never kills' {
            $f=New-DrainFixture 'children-cap';$global:ApexDrainTest_holdChild=$false
            $f.hooks.AfterCheckpoint={param($name,$state)
                if ($name -eq 'engine-complete') {
                    $path=@(Get-ChildItem -Path (Join-Path $state.state_root '*/engine-state.json') -File)[0].FullName
                    $e=Read-TestJson $path;$attempt=$e.tasks[0].attempts[-1]
                    $attempt.child_pid=424244;$attempt.child_start_time='2000-01-01T00:00:00Z';Write-TestJson $path $e
                    $global:ApexDrainTest_holdChild=$true
                    $global:ApexDrainTest_liveIdentity=[pscustomobject]@{pid=$attempt.child_pid;start_time=$attempt.child_start_time}
                }
            }
            $f.hooks.ChildAlive={param($identity) if ($global:ApexDrainTest_holdChild -and $identity.pid -eq $global:ApexDrainTest_liveIdentity.pid) {return $true};if ($identity.pid -eq $PID) {return $false};$p=Get-Process -Id $identity.pid -ErrorAction SilentlyContinue;return ($p -and $p.StartTime.ToUniversalTime() -eq ([datetime]$identity.start_time).ToUniversalTime())}
            $f.hooks.SleepMinutes={param($minutes)}
            $r=Invoke-DrainTestStart
            Assert-DrainTest ($r.state.status -eq 'stopped-children-alive' -and -not $r.state.will_build[0].commit_sha) 'quiescence cap preserves uncommitted run'
            $output=@(& $runner -Project $f.project -TestHooks $f.hooks);Assert-DrainTest (($output -join ' ') -like '*live drain*') 'stopped children blocks new start'
        }
    }
} finally {
    $suiteClock.Stop()
    Write-Host ('Elapsed minutes: {0:N2}' -f $suiteClock.Elapsed.TotalMinutes)
    if ($Case -and $suiteClock.Elapsed.TotalMinutes -ge 30) {$global:ApexDrainTest_failures++;Write-Host 'Tagged case group exceeded 30 minutes' -ForegroundColor Red}
    foreach ($name in $savedEnvironment.Keys) {[Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process')}
    # All fixtures and Engine-default worktrees are descendants of this verified temp root.
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith(([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)) {throw 'fixture cleanup escaped TEMP'}
    if ($global:ApexDrainTest_failures -eq 0) {Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
    else {Write-Host "Failed fixture artifacts: $resolved"}
}
if ($global:ApexDrainTest_failures) {Write-Host "$global:ApexDrainTest_failures drain test failures";exit 1}
Write-Host 'All drain cases passed.';exit 0
