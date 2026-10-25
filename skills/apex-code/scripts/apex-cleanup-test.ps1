#requires -Version 5.1
$ErrorActionPreference='Stop'
$clock=[Diagnostics.Stopwatch]::StartNew()
$production=Join-Path $PSScriptRoot 'apex-cleanup.ps1'
. $production
$originalNative=${function:Invoke-CleanupNative}
$script:CleanupSession=$null
$script:TestRoot=Join-Path $env:TEMP ('apex-task2-verify-'+[guid]::NewGuid().ToString('N'))
$script:MutexName='apex-cleanup-test-'+[guid]::NewGuid().ToString()
$script:Opened=New-Object Collections.ArrayList
$script:GitCalls=New-Object Collections.ArrayList
$script:AclCalls=New-Object Collections.ArrayList
$script:Mutations=New-Object Collections.ArrayList
$script:Processes=@(); $script:Identities=@{}; $script:Elevated=$true; $script:Hook=$null
$script:Fault=$null; $script:Version=$null; $script:Assertions=0
$script:FixtureGit=@{}
$script:FixtureObjects=@{}
$script:FixtureTopology=@{}
$script:FixturePaths=@{}
$script:FixtureIndex=@{}
$script:FixtureHashes=@{}
$script:FixtureAttributes=@{}
$originalMutation=${function:Invoke-CleanupMutation}
$originalEntries=${function:Get-CleanupEntries}; $originalAttributes=${function:Get-CleanupAttributes}
$originalWait=${function:Wait-CleanupMutex}; $originalJournal=${function:Add-CleanupJournal}
$originalProof=${function:Set-CleanupProof}; $script:LockEvents=New-Object Collections.ArrayList; $script:Acquisition=0
$savedEnvironment=@{}
foreach ($name in @('LOCALAPPDATA','APEX_STATE_DIR','TEMP','TMP')) { $savedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
$savedGit=@{}
foreach ($e in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) { if ($e.Key.StartsWith('GIT_',[StringComparison]::OrdinalIgnoreCase)) { $savedGit[$e.Key]=$e.Value } }
function Assert-Test { param([bool]$Condition,[string]$Message)
    $script:Assertions++; if (-not $Condition) { throw ('ASSERT: '+$Message) }
}
class CleanupTestRows : System.Collections.IEnumerable {
    [Collections.ArrayList]$Values
    [int]$Scans=0
    CleanupTestRows([Collections.ArrayList]$Rows) { $this.Values=$Rows }
    [Collections.IEnumerator] GetEnumerator() { $this.Scans++; return $this.Values.GetEnumerator() }
}
function Test-RowClosureReference { param($Source,$Context,[switch]$Legacy)
    # Frozen pre-index closure algorithm, including its case-sensitive comparisons.
    $r=$Source.Data; if (-not $r.run_id) { return $false }
    $kind=if ($r.row_kind) { [string]$r.row_kind } else { 'dispatch' }
    if ($kind -ceq 'teardown_lease') { return ([string]$r.status -cne 'reserved') }
    foreach ($s in $Context.Rows) {
        $d=$s.Data; if ([string]$d.run_id -cne [string]$r.run_id) { continue }
        $k=if ($d.row_kind) { [string]$d.row_kind } else { 'dispatch' }
        if ($k -ceq 'lease_close' -and ($Legacy -or $kind -in @('lease','teardown_lease'))) { return $true }
        if ($k -ceq 'dispatch' -and @('leasing','running','stalled','adopting','orphaned') -cnotcontains [string]$d.status -and ($Legacy -or $kind -notin @('lease','teardown_lease'))) { return $true }
    }
    return $false
}
function Test-CleanupCostShape {
    $scopeSeam=${function:Get-CleanupScopeTag}; $entrySeam=${function:Get-CleanupEntries}
    $savedSession=$script:CleanupSession; $savedCache=$script:CleanupRecordCache
    $script:CleanupRecordCache=New-CleanupPathMap
    $costRoot=Join-Path $script:TestRoot 'cost-shape'; $costState=Join-Path $costRoot 'state'
    $costTemp=Join-Path $costRoot 'temp'; $costLedger=Join-Path $costState 'progress/codex-run-ledger.jsonl'
    $script:CostTemp=$costTemp; $counts=@()
    function Get-CleanupScopeTag { param([string]$Path) $script:CostTags++; & $scopeSeam $Path }
    function Get-CleanupEntries { param([string]$Path)
        if (Test-CleanupEqual $Path $script:CostTemp) { $script:CostTempScans++ }
        & $entrySeam $Path
    }
    try {
        foreach ($size in @(@(10,4),@(100,8))) {
            $n=$size[0]; $w=$size[1]
            [void][IO.Directory]::CreateDirectory($costTemp)
            $paths=@(for ($j=0;$j -lt $w;$j++) {
                $p=Join-Path $costRoot ('cost-wt/w'+$j); [void][IO.Directory]::CreateDirectory($p); $p
            })
            $text=[Text.StringBuilder]::new()
            for ($j=0;$j -lt 4;$j++) {
                $p=$paths[$j]
                $extra=',"teardown_main_repo":"'+$script:Repo.Replace('\','/')+'"'
                [void]$text.AppendLine('{"row_kind":"dispatch","run_id":"cost-'+$j+'","status":"done","worktree_key":"'+$p.Replace('\','/')+'","worktree":"'+$p.Replace('\','/')+'","teardown_worktree":"'+$p.Replace('\','/')+'"'+$extra+'}')
            }
            Write-TestFile $costLedger $text.ToString()
            for ($j=0;$j -lt $n;$j++) { [void][IO.Directory]::CreateDirectory((Join-Path $costTemp ('apex-scope-cost-'+$j))) }
            $script:CostTags=0; $script:CostTempScans=0
            $listClock=[Diagnostics.Stopwatch]::StartNew()
            $c=Get-CleanupInventory @($costState) $costLedger $costTemp 24
            # Materialize synthetic ledger sources at the parser's existing seam.
            # The measured loops see all 2000 rows; parser byte-refresh checks below
            # use the real record file without repeatedly generating large JSON.
            if (-not $synthetic) {
                $synthetic=@(for ($j=4;$j -lt 2000;$j++) {
                    $p=Join-Path $costRoot ('unrelated/'+$j)
                    [pscustomobject]@{ Data=[pscustomobject]@{row_kind='dispatch';run_id=('cost-'+$j);status='done';worktree_key=$p;worktree=$p;teardown_worktree=$p}; Path=$costLedger; Root=$costState; Kind='ledger'; Identity=($costLedger+'|'+($j+1)) }
                })
            }
            foreach ($row in $synthetic) { [void]$c.Rows.Add($row) }
            foreach ($p in $paths) { [void](New-CleanupItem $c 'worktree' $p $null $null $null) }
            $rows=[CleanupTestRows]::new($c.Rows); $c.Rows=$rows
            Set-CleanupAllProofs $c
            foreach ($p in $paths) {
                $item=$c.Items[$p]; Add-CleanupAlias $item $p.Replace('\','/')
                Set-CleanupVerdict $item 'SAFE' 'cost fixture reproof'
                [void]@(Get-CleanupItemUsers $item $c)
            }
            [void](Get-CleanupProtectedScopes $c)
            [void]@(Get-CleanupGuard $c); [void]@(Get-CleanupGuard $c)
            $distinct=New-CleanupPathMap
            foreach ($p in $paths) { foreach ($form in $c.Items[$p].Aliases) { $distinct[(ConvertTo-CleanupPath $form)]=$true } }
            Assert-Test ($script:CostTags -le $distinct.Count) ("N=$n W=$w hashes bounded by distinct path forms: "+$script:CostTags)
            Assert-Test ($rows.Scans -le 2 -and $c.RowIndex.FullScans -le 3 -and $c.RowIndex.RowsVisited -eq 2000) ("N=$n W=$w full row scans bounded per snapshot: "+$rows.Scans)
            Assert-Test ($c.ItemIndex.Classes.temp.Count -eq $n -and $c.ItemIndex.Classes.worktree.Count -eq $w) 'cost fixture has real requested temp and worktree inventory sizes'
            foreach ($i in $c.ItemIndex.Classes.temp) { Assert-Test ($i.Verdict -eq 'SAFE') 'cost fixture empty scope verdict unchanged' }
            $counts+=,@($script:CostTags,$rows.Scans)
            Write-Output ("cleanup cost: N=$n W=$w R=2000 tags="+$script:CostTags+' row-enumerations='+$rows.Scans+' row-passes='+$c.RowIndex.FullScans+' list-ms='+[math]::Round($listClock.Elapsed.TotalMilliseconds))
            $target=$c.ItemIndex.Classes.temp[0]
            $script:CleanupSession=[pscustomobject]@{ StateRoots=@($costState); Ledger=$costLedger; Temp=$costTemp; Age=24; Context=$c; LockHeld=$false }
            $before=$script:CostTempScans; $doc=$script:CleanupRecordCache[$costLedger]
            $stamp=[IO.File]::GetLastWriteTimeUtc($costLedger)
            [IO.File]::SetLastWriteTimeUtc($costLedger,$stamp.AddHours(1))
            $fresh=Get-CleanupFresh $target; Set-CleanupDetachProof $fresh.Items[$target.Key] $fresh
            Assert-Test ($script:CostTempScans -eq $before+1 -and $fresh.ItemIndex.Classes.temp.Count -eq $n) 'fresh proof enumerates the full TEMP inventory once'
            Assert-Test ([object]::ReferenceEquals($doc,$script:CleanupRecordCache[$costLedger])) 'fresh unchanged bytes reuse parsed ledger despite timestamp change'
            if ($n -eq 100) {
                $changed=$text.ToString().Replace('"status":"done"','"status":"fail"')
                Write-TestFile $costLedger $changed; [IO.File]::SetLastWriteTimeUtc($costLedger,$stamp)
                $fresh=Get-CleanupFresh $target
                Assert-Test (-not [object]::ReferenceEquals($doc,$script:CleanupRecordCache[$costLedger]) -and $fresh.Rows[0].Data.status -ceq 'fail') 'same-length changed ledger bytes with old timestamp are reparsed'
            }
            $script:CleanupSession=$null; Remove-CleanupDirectoryBottomUp $costTemp
        }
        Assert-Test ($counts[1][0] -le 2*$counts[0][0] -and $counts[1][1] -eq $counts[0][1]) 'tenfold N and doubled W do not multiply hashes or ledger scans'
        $engine=Join-Path $costRoot 'engine.json'; Write-TestFile $engine '{"status":"parked"}'
        $data=Read-CleanupEngineData $engine; $doc=$script:CleanupRecordCache[$engine]; $stamp=[IO.File]::GetLastWriteTimeUtc($engine)
        [void](Read-CleanupEngineData $engine)
        Assert-Test ([object]::ReferenceEquals($data,(Read-CleanupEngineData $engine))) 'unchanged engine bytes reuse parsed object'
        Write-TestFile $engine '{"status":"failed"}'; [IO.File]::SetLastWriteTimeUtc($engine,$stamp)
        Assert-Test ((Read-CleanupEngineData $engine).status -ceq 'failed' -and -not [object]::ReferenceEquals($doc,$script:CleanupRecordCache[$engine])) 'engine refresh compares bytes with same length and timestamp'
        $p=$paths[0].Replace('\','/')
        $open='{"row_kind":"lease","run_id":"duplicate","status":"leasing","worktree":"'+$p+'"}'
        Write-TestFile $costLedger ($open+"`n"+$open.Replace(':',': ')+"`n"+$open.Replace('"leasing"','"leasing","extra":1')+"`n")
        $duplicates=Get-CleanupInventory @($costState) $costLedger $costTemp 24
        $item=New-CleanupItem $duplicates 'worktree' $paths[0] $null $null $null
        Assert-Test (@(Get-CleanupItemUsers $item $duplicates).Count -eq 2) 'identical parsed open rows collapse once while distinct payloads retain duplicate reason text'
        Write-TestFile $costLedger ($open+"`n"+$open.Replace('duplicate','DUPLICATE')+"`n"+'{"row_kind":"lease_close","run_id":"duplicate"}')
        $duplicates=Get-CleanupInventory @($costState) $costLedger $costTemp 24
        $item=New-CleanupItem $duplicates 'worktree' $paths[0] $null $null $null
        Assert-Test (@(Get-CleanupItemUsers $item $duplicates).Count -eq 0) 'case-insensitive payload de-duplication still precedes case-sensitive closure and process checks'
        [void](New-CleanupItem $duplicates 'worktree' $paths[1] $null $null $null)
        $collisionSeam=${function:Get-CleanupScopeTag}
        function Get-CleanupScopeTag { param([string]$Path) return '0000000000' }
        try {
            $ordered=@($duplicates.Items.Values | Where-Object Class -eq 'worktree')
            $map=Get-CleanupProtectedScopes $duplicates
            Assert-Test ($map['apex-scope-0000000000'] -ceq ('protected worktree '+$ordered[0].Path+'; path form '+$ordered[0].Aliases[0])) 'tag collision preserves inventory and alias first-match order'
            Set-CleanupVerdict $ordered[0] 'GONE' 'collision reproof'
            $map=Get-CleanupProtectedScopes $duplicates
            Assert-Test ($map['apex-scope-0000000000'] -ceq ('protected worktree '+$ordered[1].Path+'; path form '+$ordered[1].Aliases[0])) 'reproof selects the next protecting worktree in the same order'
        } finally { ${function:Get-CleanupScopeTag}=$collisionSeam }
        $nestedState=Join-Path $costTemp 'apex-scope-state'; $nestedLedger=Join-Path $nestedState 'progress/codex-run-ledger.jsonl'
        Write-TestFile $nestedLedger ''
        $focus=[pscustomobject]@{Path=(Join-Path $costTemp 'apex-scope-focus')}; [void][IO.Directory]::CreateDirectory($focus.Path)
        $focused=Get-CleanupInventory @($nestedState) $nestedLedger $costTemp 24
        $blocked=$false
        try { Assert-CleanupWritableDestination (Join-Path $nestedState 'cleanup/journal.jsonl') $focused -Journal }
        catch { $blocked=$_.Exception.Message -ceq ('output overlaps cleanup item '+$nestedState) }
        Assert-Test $blocked 'full inventory retains TEMP ancestors protecting a journal destination'
    } finally {
        ${function:Get-CleanupScopeTag}=$scopeSeam; ${function:Get-CleanupEntries}=$entrySeam
        $script:CleanupSession=$savedSession; $script:CleanupRecordCache=$savedCache
    }
}
function Test-CleanupTempBatches {
    $inventorySeam=${function:Get-CleanupInventory}; $journalSeam=${function:Add-CleanupJournal}
    $mutationSeam=${function:Invoke-CleanupMutation}; $guardSeam=${function:Get-CleanupGuardSnapshot}
    $ancestrySeam=${function:Test-CleanupAncestry}; $boundarySeam=${function:Test-CleanupDeletionBoundary}
    $tempProofSeam=${function:Test-CleanupTempDirectory}
    $clockSeam=${function:Get-CleanupMonotonicSeconds}
    $savedState=$script:State; $savedLedger=$script:Ledger; $savedTemp=$script:Temp
    $script:State=Join-Path $script:TestRoot 'batch-state'
    $script:Ledger=Join-Path $script:State 'progress/codex-run-ledger.jsonl'
    $script:Temp=Join-Path $script:TestRoot 'batch-temp'
    $script:BatchFresh=0
    $script:BatchJournal=@{}; $script:BatchRenames=0; $script:BatchFast=$true
    $script:BatchNow=$null; $script:BatchInventoryFailure=$false
    function Get-CleanupMonotonicSeconds {
        if ($null -ne $script:BatchNow) { return $script:BatchNow }
        & $clockSeam
    }
    function Get-CleanupInventory { param($StateRoots,$Ledger,$Temp,$Age)
        if ($script:CleanupSession -and $script:CleanupSession.LockHeld) {
            $script:BatchFresh++
            Assert-Test (Test-CleanupEqual $Temp $script:Temp) 'batch inventory uses fixture TEMP'
            if ($script:BatchInventoryFailure) { throw 'fixture batch inventory failed' }
            # Model a fresh inventory slower than the whole item budget, without sleeping.
            if ($null -ne $script:BatchNow) { $script:BatchNow+=($script:CleanupTempBatchSeconds+1) }
        }
        $snapshot=& $inventorySeam $StateRoots $Ledger $Temp $Age
        if ($script:BatchSiblingQuarantine -and $script:CleanupSession -and $script:CleanupSession.LockHeld) {
            $script:BatchDiscovered=($snapshot.Items.ContainsKey($script:BatchSiblingQuarantine) -and $snapshot.Items[$script:BatchSiblingQuarantine].Class -eq 'quarantine' -and
                @($snapshot.Journal | Where-Object { $_.Data.quarantine_path -ceq $script:BatchSiblingQuarantine }).Count -eq 1)
        }
        return $snapshot
    }
    function Get-CleanupGuardSnapshot { param($Context,$Focus)
        # Empty, immutable bulk fixture: skip repeated record I/O in the cost case.
        # Freshness and guard regressions below use the real snapshot adapter.
        if ($script:BatchFast) { return $Context }
        & $guardSeam $Context $Focus
    }
    function Test-CleanupTempDirectory { param($Item,$Context)
        if ($script:BatchFast) {
            # Only empty real directories participate in this counter fixture.
            Assert-Test ([IO.Directory]::Exists($Item.Path) -and
                [Linq.Enumerable]::Count([IO.Directory]::EnumerateFileSystemEntries($Item.Path)) -eq 0) 'bulk proof adapter sees a real empty fixture directory'
            return $null
        }
        & $tempProofSeam $Item $Context
    }
    function Test-CleanupDeletionBoundary {
        param($Item,$Context,$ActualPath,[switch]$Owner,[switch]$Shallow,$InspectionRetryDirectory)
        if ($script:BatchFast) {
            # Cost fixture contains only freshly created empty directories. Run
            # full production boundary/reparse checks in every smaller case.
            Assert-Test ($Item.Class -eq 'temp' -and $Item.Owned -and
                [string]::Equals([IO.Path]::GetDirectoryName($Item.Path),$script:Temp,[StringComparison]::OrdinalIgnoreCase)) 'bulk item is an owned direct child of fixture TEMP'
            return $null
        }
        & $boundarySeam @PSBoundParameters
    }
    function Test-CleanupAncestry { param($Path)
        if ($script:BatchFast) {
            Assert-Test ($Path.StartsWith($script:TestRoot,[StringComparison]::OrdinalIgnoreCase)) 'bulk ancestry limited to fresh fixture directories'
            return
        }
        & $ancestrySeam $Path
    }
    function Add-CleanupJournal { param($Record,$Context)
        if ($script:BatchFast) {
            # Real append before rename, without 501 durable disk flushes. The
            # smaller race/guard cases below exercise the production writer.
            $journal=Join-Path $script:State 'cleanup/journal.jsonl'
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($journal))
            [IO.File]::AppendAllText($journal,(($Record|ConvertTo-Json -Compress -Depth 20)+"`n"))
        } else { & $journalSeam $Record $Context }
        $script:BatchJournal[$Record.quarantine_path]=$Record.original_path
    }
    function Invoke-CleanupMutation { param($Operation,$Path,$Destination)
        if ($Operation -eq 'rename') {
            Assert-Test ($script:BatchJournal[$Destination] -ceq $Path) 'batch journal append completed before each rename'
            Assert-Test $script:CleanupSession.LockHeld 'batch rename under mutex'
            $script:BatchRenames++
        }
        & $mutationSeam $Operation $Path $Destination
    }
    try {
        [void][IO.Directory]::CreateDirectory($script:Temp); Set-TestLedger @()
        # Cross a real 500-item boundary while keeping native suite runtime bounded.
        $n=501
        $paths=@(for ($j=0;$j -lt $n;$j++) {
            $p=Join-Path $script:Temp ('apex-scope-batch-{0:d4}' -f $j)
            [void][IO.Directory]::CreateDirectory($p); $p
        })
        $eventFrom=$script:LockEvents.Count; $batchClock=[Diagnostics.Stopwatch]::StartNew()
        Assert-Test ((Invoke-TestCleanup -Apply) -eq 0) ('batch Apply exit zero: '+$script:LastText)
        Assert-Test ($script:BatchFresh -eq [math]::Ceiling($n/500)) 'one full fresh inventory per temp batch'
        Assert-Test ($script:BatchRenames -eq $n) 'every SAFE batch item quarantined'
        Assert-Test (@([IO.Directory]::EnumerateFileSystemEntries($script:Temp)).Count -eq 0) 'every SAFE batch quarantine deleted'
        $records=@([IO.File]::ReadAllLines((Join-Path $script:State 'cleanup/journal.jsonl')))
        Assert-Test ($records.Count -eq $n) 'one real journal line for each batch rename'
        $events=@($script:LockEvents | Select-Object -Skip $eventFrom)
        $groups=@($events | Where-Object Phase -eq 'after-detach' | Group-Object Acquisition | Sort-Object {[int]$_.Name})
        Assert-Test ($groups.Count -eq 2 -and $groups[0].Count -eq 500 -and $groups[1].Count -eq 1) 'batch holds contain 500 then one detach in order'
        Assert-Test ((@($events | Where-Object Phase -eq 'after-detach').Path -join '|') -ceq ($paths -join '|')) 'batch detaches preserve current sorted order'
        Assert-Test (@($events | Where-Object { $_.Phase -in @('directory','file') -and $_.Held }).Count -eq 0) 'batch deletion outside mutex'
        Write-Output ("cleanup batch: N=$n fresh-inventories="+$script:BatchFresh+' holds='+$groups.Count+' apply-ms='+[math]::Round($batchClock.Elapsed.TotalMilliseconds))
        $script:BatchFast=$false

        # Slow inventory is excluded; item processing still splits the hold, without sleeping.
        $paths=@(foreach ($name in @('a','b','c')) {
            $p=Join-Path $script:Temp ('apex-scope-timed-'+$name); [void][IO.Directory]::CreateDirectory($p); $p
        })
        $script:BatchNow=0
        $script:Hook={param($phase,$item)
            if ($phase -eq 'after-detach' -and $item.Class -eq 'temp') { $script:BatchNow+=11 }
        }
        $eventFrom=$script:LockEvents.Count; $freshFrom=$script:BatchFresh
        Assert-Test ((Invoke-TestCleanup -Apply) -eq 0) ('timed batch Apply: '+$script:LastText)
        $events=@($script:LockEvents | Select-Object -Skip $eventFrom)
        $groups=@($events | Where-Object Phase -eq 'after-detach' | Group-Object Acquisition | Sort-Object {[int]$_.Name})
        Assert-Test ($groups.Count -eq 2 -and $groups[0].Count -eq 2 -and $groups[1].Count -eq 1) 'slow inventory excluded: hold processes two items, then splits after 22 item seconds below count cap'
        Assert-Test ($script:BatchFresh-$freshFrom -eq 2) 'time split takes a new full inventory for each hold'
        Assert-Test ((@($events | Where-Object Phase -eq 'after-detach').Path -join '|') -ceq ($paths -join '|')) 'time split preserves detach order'
        Assert-Test (@($events | Where-Object { $_.Phase -in @('directory','file') -and $_.Held }).Count -eq 0) 'time-split deletion outside mutex'
        foreach ($p in $paths) { Assert-TestReportItem $p 'SAFE' 'quarantined and removed' }
        $script:Hook=$null; $script:BatchNow=$null

        $paths=@(foreach ($name in @('a','b','c')) {
            $p=Join-Path $script:Temp ('apex-scope-inventory-failure-'+$name); [void][IO.Directory]::CreateDirectory($p); $p
        })
        $script:BatchInventoryFailure=$true; $renamesFrom=$script:BatchRenames
        Assert-Test ((Invoke-TestCleanup -Apply) -eq 1) ('batch inventory failure exit one: '+$script:LastText)
        foreach ($p in $paths) {
            Assert-TestReportItem $p 'KEEP' 'detach error: fixture batch inventory failed'
            Assert-Test (Test-CleanupExists $p) 'inventory failure leaves each unprocessed batch item intact'
        }
        Assert-Test ($script:BatchRenames -eq $renamesFrom -and $script:LastText -notlike '*SAFE temp*') 'inventory failure reports no unprocessed SAFE temp items or renames'
        $script:BatchInventoryFailure=$false
        foreach ($p in $paths) { Remove-CleanupDirectoryBottomUp $p }

        $repairItem=Join-Path $script:Temp 'apex-scope-repair-a'
        $script:BatchDeniedDirectory=Join-Path $repairItem 'denied'
        $siblings=@(foreach ($name in @('b','c')) {
            $p=Join-Path $script:Temp ('apex-scope-repair-'+$name); [void][IO.Directory]::CreateDirectory($p); $p
        })
        [void][IO.Directory]::CreateDirectory($script:BatchDeniedDirectory)
        $script:BatchDenyActivated=$false; $script:BatchDenials=0; $aclFrom=$script:AclCalls.Count
        $script:Hook={param($phase,$item)
            if ($phase -eq 'after-lock' -and $item.Class -eq 'temp') { $script:BatchDenyActivated=$true }
        }
        $script:Fault={param($kind,$value)
            if ($kind -eq 'enumerate' -and $value -ceq $script:BatchDeniedDirectory -and $script:BatchDenyActivated -and
                -not @($script:AclCalls | Select-Object -Skip $aclFrom | Where-Object { $_.File -eq 'icacls.exe' -and $_.Args[0] -ceq $value }).Count) {
                $script:BatchDenials++
                throw (New-Object UnauthorizedAccessException('fixture batch subdirectory denied'))
            }
        }
        $eventFrom=$script:LockEvents.Count; $freshFrom=$script:BatchFresh
        Assert-Test ((Invoke-TestCleanup -Apply) -eq 0) ('batch inspection repair: '+$script:LastText)
        $events=@($script:LockEvents | Select-Object -Skip $eventFrom)
        $holds=@($events | Where-Object Phase -eq 'after-lock')
        Assert-Test ($script:BatchDenials -gt 0 -and $script:AclCalls.Count-$aclFrom -eq 2) 'batch subdirectory denial repaired with exactly one ACL pair'
        Assert-Test ($holds.Count -eq 2 -and $script:BatchFresh-$freshFrom -eq 2) 'batch repair reacquires one per-item hold with full fresh inventory'
        $detaches=@($events | Where-Object Phase -eq 'after-detach')
        Assert-Test ($detaches.Count -eq 3 -and $detaches[0].Path -ceq $siblings[0] -and $detaches[1].Path -ceq $siblings[1] -and
            $detaches[0].Acquisition -eq $holds[0].Acquisition -and $detaches[1].Acquisition -eq $holds[0].Acquisition -and
            $detaches[2].Path -ceq $repairItem -and $detaches[2].Acquisition -eq $holds[1].Acquisition) 'batch siblings detach together before deferred repair item'
        $aclEvents=@($events | Where-Object Phase -eq 'acl')
        Assert-Test ($aclEvents.Count -eq 2 -and @($aclEvents | Where-Object Held).Count -eq 0 -and
            $aclEvents[0].Acquisition -eq $holds[0].Acquisition) 'deferred ACL repair occurs after batch release and before reacquire'
        $proofs=@($events | Where-Object { $_.Phase -eq 'proof' -and $_.Path -ceq $repairItem })
        Assert-Test (@($proofs | Where-Object { -not $_.Held -and $_.Acquisition -eq $holds[0].Acquisition }).Count -gt 0 -and
            @($proofs | Where-Object { $_.Held -and $_.Acquisition -eq $holds[1].Acquisition }).Count -gt 0) 'deferred item inspected unlocked and fully reproved in new hold'
        Assert-Test (@($events | Where-Object { $_.Phase -in @('directory','file') -and $_.Held }).Count -eq 0) 'deferred repair deletion outside mutex'
        foreach ($p in (@($repairItem)+$siblings)) {
            Assert-TestReportItem $p 'SAFE' 'quarantined and removed'
            Assert-Test (-not (Test-CleanupExists $p)) 'repaired batch item and siblings deleted'
        }
        $script:Hook=$null; $script:Fault=$null

        foreach ($race in @('ledger','registration','journal')) {
            $script:RaceKind=$race; $script:RaceWritten=$false
            $script:RaceWorktree=Join-Path $script:TestRoot ('batch-protected-'+$race)
            $tag=Get-CleanupScopeTag $script:RaceWorktree
            $script:RaceTarget=Join-Path $script:Temp ('apex-scope-'+$tag)
            $unaffected=Join-Path $script:Temp ('apex-scope-unaffected-'+$race)
            foreach ($p in @($script:RaceTarget,$unaffected)) { [void][IO.Directory]::CreateDirectory($p) }
            Set-TestLedger @((New-TestObligation '' ''))
            $script:Hook={param($phase,$item)
                if ($phase -ne 'before-lock' -or $item.Class -ne 'temp' -or $script:RaceWritten) { return }
                $script:RaceWritten=$true
                switch ($script:RaceKind) {
                    'ledger' {
                        [void][IO.Directory]::CreateDirectory($script:RaceWorktree)
                        Set-TestLedger @((New-TestObligation $script:RaceWorktree ''))
                    }
                    'registration' {
                        [void](Test-Git @('-C',$script:Repo,'worktree','add','--detach',$script:RaceWorktree,$script:MainHead))
                    }
                    'journal' {
                        $script:RaceQuarantine=New-TestQuarantine $script:RaceTarget
                        $script:BatchSiblingQuarantine=New-TestQuarantine $script:Temp
                        $sibling=@{action='quarantine';utc='2020-01-01T00:00:00Z';class='temp';original_path='old';quarantine_path=$script:BatchSiblingQuarantine}
                        [IO.File]::AppendAllText((Join-Path $script:State 'cleanup/journal.jsonl'),(($sibling|ConvertTo-Json -Compress)+"`n"))
                        $record=@{action='quarantine';utc='2020-01-01T00:00:00Z';class='temp';original_path='old';quarantine_path=$script:RaceQuarantine}
                        [IO.File]::AppendAllText((Join-Path $script:State 'cleanup/journal.jsonl'),(($record|ConvertTo-Json -Compress)+"`n"))
                    }
                }
            }
            $freshFrom=$script:BatchFresh
            Assert-Test ((Invoke-TestCleanup -Apply) -eq 0) ('batch fresh '+$race+': '+$script:LastText)
            Assert-Test ($script:RaceWritten -and $script:BatchFresh-$freshFrom -eq 1) 'race inserted between initial inventory and single batch lock'
            Assert-TestReportItem $script:RaceTarget 'KEEP' $(if ($race -eq 'journal') {'contains repository or kept item'} else {'protected worktree '+$script:RaceWorktree})
            Assert-TestReportItem $unaffected 'SAFE' 'quarantined and removed'
            Assert-Test ((Test-CleanupExists $script:RaceTarget) -and -not (Test-CleanupExists $unaffected)) 'newly protected item retained while batch sibling proceeds'
            $script:Hook=$null
            if ($race -eq 'journal') {
                Assert-Test $script:BatchDiscovered 'full batch snapshot discovers newly journaled quarantine sibling in TEMP'
                Assert-Test (Test-CleanupExists $script:BatchSiblingQuarantine) 'batch never removes newly discovered earlier quarantine'
                Remove-CleanupDirectoryBottomUp $script:BatchSiblingQuarantine; $script:BatchSiblingQuarantine=$null
            }
            if ($race -eq 'registration') { [void](Test-Git @('-C',$script:Repo,'worktree','remove','--force',$script:RaceWorktree)) }
            elseif (Test-CleanupExists $script:RaceWorktree) { Remove-CleanupDirectoryBottomUp $script:RaceWorktree }
            Remove-CleanupDirectoryBottomUp $script:RaceTarget
        }

        Set-TestLedger @()
        $paths=@(foreach ($name in @('a','b','c')) {
            $p=Join-Path $script:Temp ('apex-scope-guard-'+$name); [void][IO.Directory]::CreateDirectory($p); $p
        })
        $script:Hook={param($phase,$item)
            if ($phase -eq 'after-detach' -and $item.Class -eq 'temp') {
                $script:Processes=@([pscustomobject]@{ProcessId=901099;Name='codex.exe';CommandLine='codex exec -p apex-coder fixture'})
            }
        }
        $freshFrom=$script:BatchFresh
        Assert-Test ((Invoke-TestCleanup -Apply) -eq 2) ('mid-batch guard exit two: '+$script:LastText)
        Assert-Test ($script:BatchFresh-$freshFrom -eq 1) 'mid-batch guard uses one full snapshot'
        Assert-TestReportItem $paths[0] 'SAFE' 'quarantined and removed'
        Assert-Test (-not (Test-CleanupExists $paths[0]) -and (Test-CleanupExists $paths[1]) -and (Test-CleanupExists $paths[2])) 'guard stops at next item and completes earlier quarantine'
        Assert-Test ($script:LastText.Contains('STOP ') -and $script:LastText.Contains('901099')) 'mid-batch guard report includes stop reason'
    } finally {
        $script:Hook=$null; $script:Processes=@(); $script:Fault=$null; $script:BatchSiblingQuarantine=$null
        ${function:Get-CleanupInventory}=$inventorySeam; ${function:Add-CleanupJournal}=$journalSeam
        ${function:Invoke-CleanupMutation}=$mutationSeam; ${function:Get-CleanupGuardSnapshot}=$guardSeam
        ${function:Test-CleanupAncestry}=$ancestrySeam; ${function:Test-CleanupDeletionBoundary}=$boundarySeam
        ${function:Test-CleanupTempDirectory}=$tempProofSeam
        ${function:Get-CleanupMonotonicSeconds}=$clockSeam
        $script:BatchNow=$null; $script:BatchInventoryFailure=$false
        $script:CleanupSession=$null
        foreach ($p in @($script:Temp,$script:State)) { if (Test-CleanupExists $p) { Remove-CleanupDirectoryBottomUp $p } }
        $script:State=$savedState; $script:Ledger=$savedLedger; $script:Temp=$savedTemp
    }
}
function Test-CleanupReviewRegressions {
    $branch='codex/history-reproof-error'
    [void](Test-Git @('-C',$script:Repo,'branch',$branch,$script:UniqueContentHead))
    Set-TestLedger @((New-TestObligation '' $branch))
    $state=New-TestState ('f'*32); $state.status='complete'; $state.teardown.status='complete'
    $statePath=Save-TestState $state -Old; $script:HistoryFaults=0
    $script:Fault={param($kind,$arguments)
        if ($kind -eq 'git' -and $script:CleanupSession.LockHeld -and $arguments -contains 'rev-parse' -and $arguments -contains 'refs/heads/codex/history-reproof-error') {
            $script:HistoryFaults++
            return [pscustomobject]@{Code=128;Text='';Error='history-only unrelated branch failure'}
        }
    }
    try {
        Assert-Test ((Invoke-TestCleanup -Apply) -eq 1) ('history reproof error reaches exit one: '+$script:LastText)
        Assert-Test ($script:HistoryFaults -gt 0 -and $script:LastText -like '*ERROR *history-only unrelated branch failure*') 'unrelated branch rev-parse failure in locked history reproof reaches report'
    } finally {
        $script:Fault=$null; Set-TestLedger @()
        [void](Test-Git @('-C',$script:Repo,'branch','-D',$branch))
        $dir=[IO.Path]::GetDirectoryName($statePath); if (Test-CleanupExists $dir) { Remove-CleanupDirectoryBottomUp $dir }
    }
    $c=Get-TestInventory; $repo=Resolve-CleanupRepository $c $script:Repo
    $path=Join-Path $script:TestRoot 'mixed-prefix-owner'
    $w=New-CleanupItem $c 'worktree' $path $repo $null 'Refs/Heads/codex/mixed'
    $b=New-CleanupItem $c 'branch' 'refs/heads/Refs/Heads/codex/mixed' $repo $null $null
    $row=New-TestLease $path; $script:Identities[901001]=[pscustomobject]@{Exists=$true;Start='2020-01-01T00:00:00Z'}
    [void]$c.Rows.Add([pscustomobject]@{Data=$row;Kind='ledger';Root=$script:State;Path=$script:Ledger;Identity='mixed-prefix'})
    try {
        Assert-Test (@(Get-CleanupItemUsers $b $c).Count -gt 0) 'differently cased recorded prefix associates with literal prefixed branch as before indexing'
        $normal=New-CleanupItem $c 'branch' 'refs/heads/codex/mixed' $repo $null $null
        Assert-Test (@(Get-CleanupItemUsers $normal $c).Count -eq 0) 'differently cased prefix does not associate with lowercase shortened branch'
        $ix=Get-CleanupItemIndex $c
        Assert-Test (-not $ix.Branches.ContainsKey((Get-CleanupBranchKey $repo $normal.Path)) -and $ix.BranchProofs.ContainsKey((Get-CleanupBranchKey $repo $normal.Path))) 'ordinal user association and legacy branch content proof retain their distinct prefix rules'
    } finally { $script:Identities.Remove(901001) }
}
function Wait-TestChild { param([Diagnostics.Process]$Process)
    if (-not $Process.WaitForExit(60000)) {
        try { if (-not $Process.HasExited) { $Process.Kill(); [void]$Process.WaitForExit(5000) } } catch {}
        Assert-Test $false ('native child timed out after 60s: '+$Process.StartInfo.FileName)
    }
}
function Invoke-TestNative { param([string]$File,[string[]]$Arguments,[byte[]]$InputBytes)
    $si=New-Object Diagnostics.ProcessStartInfo
    $si.FileName=if ($File -ceq 'git.exe') { $script:NativeGit } else { $File }; $si.Arguments=(@(foreach ($argument in $Arguments) { ConvertTo-CleanupArgument $argument }) -join ' ')
    $si.UseShellExecute=$false; $si.CreateNoWindow=$true
    $si.RedirectStandardInput=$true; $si.RedirectStandardOutput=$true; $si.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process; $p.StartInfo=$si; $buffer=New-Object IO.MemoryStream
    try {
        # Prevent the Framework stdin writer from emitting a console-encoding BOM.
        $stdinEncoding=$null
        try {
            $stdinEncoding=[Console]::InputEncoding
            [Console]::InputEncoding=New-Object Text.UTF8Encoding $false
        } catch { $stdinEncoding=$null }
        try { [void]$p.Start() }
        finally { if ($null -ne $stdinEncoding) { [Console]::InputEncoding=$stdinEncoding } }
        $outTask=$p.StandardOutput.BaseStream.CopyToAsync($buffer); $errTask=$p.StandardError.ReadToEndAsync()
        if ($InputBytes -and $InputBytes.Length) { $p.StandardInput.BaseStream.Write($InputBytes,0,$InputBytes.Length) }
        $p.StandardInput.Close(); Wait-TestChild $p; $outTask.GetAwaiter().GetResult()
        $err=$errTask.GetAwaiter().GetResult()
        return [pscustomobject]@{Code=$p.ExitCode;Text=(New-Object Text.UTF8Encoding($false,$true)).GetString($buffer.ToArray());Error=$err}
    } finally { $buffer.Dispose(); $p.Dispose() }
}
# Git for Windows' cmd launcher starts a second process for every query.
# Use the same installation's native binary for real fixture Git, without that hop.
$script:NativeGit=(Get-Command git.exe -CommandType Application | Select-Object -First 1).Source
$gitHome=Split-Path (Split-Path $script:NativeGit -Parent) -Parent
foreach ($arch in @('mingw64','mingw32')) {
    $nativeCandidate=Join-Path $gitHome ($arch+'/bin/git.exe')
    if ([IO.File]::Exists($nativeCandidate)) { $script:NativeGit=$nativeCandidate; break }
}
Assert-Test ($script:NativeGit -is [string] -and [IO.File]::Exists($script:NativeGit)) 'native Git is a single existing file'
function Clear-TestGitReplies {
    foreach ($cache in @($script:FixtureGit,$script:FixtureObjects,$script:FixtureTopology,$script:FixturePaths,
        $script:FixtureIndex,$script:FixtureAttributes)) { $cache.Clear() }
    # The native executable is fixed for this suite. Hash replies compare freshly
    # read input bytes, and configuration/attribute writers clear them explicitly.
    # Both retain every adapter assertion and fault hook on every lookup.
}
function Write-TestStage { param([string]$Text) Write-Output ($Text+' @ '+[math]::Round($clock.Elapsed.TotalSeconds,2)+'s') }
function Get-TestGitEnvironment {
    $map=@{}; foreach ($e in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) { if ($e.Key.StartsWith('GIT_',[StringComparison]::OrdinalIgnoreCase)) { $map[$e.Key]=$e.Value } }; return $map
}
function Restore-TestGitEnvironment { param($Map)
    foreach ($name in @((Get-TestGitEnvironment).Keys)) { [Environment]::SetEnvironmentVariable($name,$null,'Process') }
    foreach ($name in $Map.Keys) { [Environment]::SetEnvironmentVariable($name,$Map[$name],'Process') }
}
function Assert-TestGitEnvironment { param($Expected)
    $actual=Get-TestGitEnvironment
    Assert-Test ($actual.Count -eq $Expected.Count) 'complete GIT_ environment restored (count)'
    foreach ($key in $Expected.Keys) { Assert-Test ($actual[$key] -ceq $Expected[$key]) ('GIT_ environment restored: '+$key) }
}
function Test-Git { param([string[]]$Arguments)
    # The shared fixture repository changes only through this helper or mutation.
    $command=if ($Arguments[0] -eq '-C') { $Arguments[2] } elseif ($Arguments[0].StartsWith('--git-dir=')) { $Arguments[1] } else { $Arguments[0] }
    if ($command -in @('commit','checkout','config','reset')) { $script:ResetNeedsGit=$true }
    if ($command -in @('config','worktree','init','clone')) { $script:FixturePaths.Clear() }
    if ($command -eq 'config') { $script:FixtureHashes.Clear(); $script:FixtureAttributes.Clear() }
    if ($command -notin @('rev-parse','version','verify-pack')) { $script:FixtureGit.Clear(); $script:FixtureIndex.Clear() }
    if ($command -eq 'reset') {
        foreach ($key in @($script:FixtureTopology.Keys)) {
            if ($key.Contains('HEAD') -or $key.Contains('for-each-ref') -or $key.Contains('worktree')) { $script:FixtureTopology.Remove($key) }
        }
    } elseif ($command -notin @('add','update-index','read-tree','rev-parse','version','verify-pack')) { $script:FixtureTopology.Clear() }
    $saved=Get-TestGitEnvironment
    try {
        Restore-TestGitEnvironment @{}
        $env:GIT_OPTIONAL_LOCKS='0'; $env:GIT_CONFIG_NOSYSTEM='1'; $env:GIT_CONFIG_GLOBAL=$script:Config
        $r=Invoke-TestNative 'git.exe' $Arguments $null
        if ($r.Code -ne 0) { throw ('fixture Git failed: '+($Arguments -join ' ')+' '+$r.Error) }
        return $r.Text.TrimEnd("`r","`n")
    } finally { Restore-TestGitEnvironment $saved }
}
function Write-TestFile { param([string]$Path,[string]$Text)
    if ($Path -match '(?i)(?:^|[\\/])\.git(?:[\\/]|$)|config\.worktree$') { $script:FixtureTopology.Clear(); $script:FixturePaths.Clear(); $script:FixtureIndex.Clear(); $script:FixtureHashes.Clear(); $script:FixtureAttributes.Clear() }
    if ([IO.Path]::GetFileName($Path) -in @('.gitattributes','.gitignore')) { $script:FixtureIndex.Clear(); $script:FixtureHashes.Clear(); $script:FixtureAttributes.Clear() }
    if (-not ($script:State -and (Test-CleanupUnder $Path $script:State)) -and
        -not ($script:Reports -and (Test-CleanupUnder $Path $script:Reports))) { $script:FixtureGit.Clear() }
    [void][IO.Directory]::CreateDirectory((ConvertTo-CleanupLiteral ([IO.Path]::GetDirectoryName($Path))))
    [IO.File]::WriteAllText((ConvertTo-CleanupLiteral $Path),$Text,(New-Object Text.UTF8Encoding($false)))
}
function Set-TestLedger { param([object[]]$Rows=@())
    $text=@($Rows | ForEach-Object { $_ | ConvertTo-Json -Depth 30 -Compress }) -join "`n"
    Write-TestFile $script:Ledger ($text+$(if ($text) { "`n" } else { '' }))
}
function New-TestRow { param([string]$Worktree,[string]$Branch,[string]$Id='fixture')
    # codex-dispatch.ps1: ledgerRow + creator teardown record (Git porcelain uses /).
    return [pscustomobject]@{ row_kind='dispatch'; run_id=$Id; status='done'; pid=900001; pid_start='2001-01-01T00:00:00Z'
        launcher_pid=900003; launcher_start='2001-01-01T00:00:00Z'; worktree=$Worktree; worktree_key=$Worktree
        spec='fixture'; task='1'; base_sha=$script:BaseHead; head_sha=$script:MainHead; phase='build'; started='2001-01-01T00:00:00Z'
        log_path=$null; effort='high'; attended=$false; final_path=$null; schema=$null; sandbox='workspace-write'; baseline_skipped=$false
        scope_armed=$false; scope_task='fixture-1'; authorized=@(); scope_unlocked=$false; scope_unlocked_reason=''
        shared_worktree=$false; shared_worktree_reason=''; tree_pin_disabled=$false; tree_pin_disabled_reason=''; tree_pin_override=$false
        critical_files_confirmed=$false; critical_files_confirmed_note=''; model='fixture'; dispatch_kind=''; author_mode=$null
        builder_family='fixture'; reviewer_family=''; reviewed_run_id=''; reviewed_tree_digest=''; tree_pin_label=$null
        ended='2001-01-01T00:00:01Z'; teardown_main_repo=$script:Repo.Replace('\','/'); teardown_sha=$script:MainHead
        teardown_worktree=$Worktree; teardown_branch=$Branch; cleanup_obligation=''; branch_teardown_obligation='' }
}
function New-TestObligation { param([string]$Worktree,[string]$Branch,[string]$Id='obligation')
    # Save-CreatorTeardownRecord's standalone post-refusal obligation.
    return [pscustomobject]@{run_id=$Id;row_kind='obligation';spec='fixture';task='1';refusal_exit=79;ended='2001-01-01T00:00:01Z'
        teardown_main_repo=$script:Repo.Replace('\','/');teardown_sha=$script:MainHead;teardown_worktree=$Worktree;teardown_branch=$Branch
        cleanup_obligation='';branch_teardown_obligation=''}
}
function New-TestTeardownLease { param([string]$Worktree,[string]$Id='teardown')
    # Invoke-CreatorTeardown: teardownReservation, not a dispatch completion.
    return [pscustomobject]@{run_id=$Id;row_kind='teardown_lease';status='reserved';pid=901001;pid_start='2020-01-01T00:00:00Z'
        worktree=$Worktree;worktree_key=$Worktree;spec='fixture';task='1';phase='build';sandbox='workspace-write';effort='high';started='2020-01-01T00:00:00Z'}
}
function New-TestClose { param([string]$Id)
    return [pscustomobject]@{run_id=$Id;row_kind='lease_close';status='refused-preflight';refusal_exit=79;ended='2001-01-01T00:00:01Z';log_path=$null;effort='high';attended=$false}
}
function New-TestLease { param([string]$Worktree,[string]$Id='live')
    return [pscustomobject]@{run_id=$Id;launcher_pid=901001;launcher_start='2020-01-01T00:00:00Z';worktree=$Worktree;worktree_key=$Worktree
        spec='fixture';task='1';phase='build';sandbox='workspace-write';started='2020-01-01T00:00:00Z';log_path=$null;effort='high';attended=$false;row_kind='lease';status='leasing'}
}
function New-TestState { param([string]$Id=('a'*32),[string]$Worktree,[string]$Branch)
    # apex-engine.ps1 New-RunnerStateObject; only writer-owned values vary per case.
    return [pscustomobject]@{ run_id=$Id; repo=$script:Repo; status='parked'; base_sha=$script:MainHead
        schema_version=1;created_at='2001-01-01T00:00:00Z';updated_at='2001-01-01T00:00:00Z'
        state_path=(Join-Path $script:State ($Id+'/engine-state.json'));worktree_root=$script:TestRoot;wrapper_path='fixture';codex_executable=$null
        codex_executable_argument_prefix=@();no_output_timeout_min=10;accept_timeout_min=10
        spec=@{name='fixture';original_path=(Join-Path $script:TestRoot 'fixture.md');original_digest='fixture';snapshot_path=(Join-Path $script:State ($Id+'/spec.md'));snapshot_digest='fixture'}
        engine_owner=@{pid=900002;start_time='2001-01-01T00:00:00Z'}
        integration=@{worktree=$Worktree;branch=$Branch;tip=$script:MainHead}; tasks=@()
        max_parallel=1;capacity=$null;plan=$null;counters=@{dispatches=0;retries=0;capacity_retries=0;concerns=0};concerns=@();diagnosis=$null
        handoff=@{status='pending';started_at=$null;completed_at=$null;journaled_paths=@();mismatch_path=$null;recovery_patch=$null}
        teardown=@{status='pending';discard=$false;items=@()};transitions=@(@{at='2001-01-01T00:00:00Z';kind='created';detail=$null}) }
}
function New-TestAttempt {
    return [pscustomobject]@{number=1;status='prepared';effort='high';model='fixture';worktree=$script:Worktree;branch='codex/task'
        child_pid=$null;child_start_time=$null;wrapper_run_id=$null;exit_code=$null;event_path=$null
        args_path=(Join-Path $script:TestRoot 'dispatch-args.json');child_output_path=(Join-Path $script:TestRoot 'child.out')
        end_tree_digest=$null;diagnosis=$null;capacity_retries=0;process_retries=0}
}
function New-TestTask { param([object[]]$Attempts=@())
    return [pscustomobject]@{id='1';status='pending';diagnosis=$null;concerns=@();attempts=$Attempts}
}
function New-TestAcceptance {
    return [pscustomobject]@{id='fixture';status='pending';output_tail='';child_pid=901001;child_start_time='2020-01-01T00:00:00Z'}
}
function Save-TestState { param($State,[string]$Root=$script:State,[switch]$Old)
    $path=Join-Path $Root ($State.run_id+'/engine-state.json')
    Write-TestFile $path ($State | ConvertTo-Json -Depth 30)
    if ($Old) { [IO.File]::SetLastWriteTimeUtc($path,[datetime]::UtcNow.AddDays(-16)) }
    return $path
}
function Get-TestSnapshot { param([string]$Root=$script:TestRoot)
    $rows=New-Object 'Collections.Generic.List[string]'; $stack=New-Object 'Collections.Generic.Stack[string]'; $stack.Push($Root)
    if (-not (Test-CleanupEqual $Root $script:TestRoot)) { $rows.Add('ROOT|'+[int](Get-CleanupAttributes $Root)+'|'+[IO.Directory]::GetLastWriteTimeUtc((ConvertTo-CleanupLiteral $Root)).Ticks) }
    $hash=[Security.Cryptography.SHA256]::Create()
    try {
        while ($stack.Count) {
            $p=$stack.Pop()
            # Snapshot directly with .NET; retain byte/attribute/time and no-link traversal.
            foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries((ConvertTo-CleanupLiteral $p))) {
                $a=[IO.File]::GetAttributes($entry)
                $plain=if ($entry.StartsWith('\\?\UNC\')) { '\\'+$entry.Substring(8) } else { $entry.Substring(4) }
                $prefix=$plain.Substring($Root.Length)+'|'+[int]$a+'|'+[IO.File]::GetLastWriteTimeUtc($entry).Ticks
                if ($a -band [IO.FileAttributes]::ReparsePoint) { $rows.Add($prefix+'|LINK'); continue }
                if ($a -band [IO.FileAttributes]::Directory) { $rows.Add($prefix+'|DIR'); $stack.Push($plain) }
                else { $rows.Add($prefix+'|'+[BitConverter]::ToString($hash.ComputeHash([IO.File]::ReadAllBytes($entry)))) }
            }
        }
    } finally { $hash.Dispose() }
    return (@($rows | Sort-Object) -join "`n")
}
function Invoke-TestCleanup { param([switch]$Apply,[string[]]$Names,[string[]]$Roots=@($script:State),[string]$Report)
    Clear-TestGitReplies
    $script:DetachedPaths=New-CleanupPathMap
    $saved=Get-TestGitEnvironment
    try {
        $env:GIT_CONFIG_NOSYSTEM='1'; $env:GIT_CONFIG_GLOBAL=$script:Config
        $parameters=@{ StateRoot=$Roots; LedgerPath=$script:Ledger; TempRoot=$script:Temp; MinAgeHours=24 }
        if ($Apply) { $parameters.Apply=$true }
        if ($Names) { $parameters.RemoveQuarantine=$Names }
        if ($Report) { $parameters.ReportPath=$Report }
        elseif ($Apply) { $parameters.ReportPath=Join-Path $script:Reports ([guid]::NewGuid().ToString('N')+'.txt') }
        $result=@(Start-ApexCleanup @parameters)
        $script:LastText=(@($result | Select-Object -SkipLast 1) -join "`n")
        $script:LastCode=[int]$result[-1]
        Assert-TestGitEnvironment (Get-TestExpectedEnvironment $saved)
        return $script:LastCode
    } finally { Restore-TestGitEnvironment $saved }
}
function Get-TestExpectedEnvironment { param($Saved)
    $copy=@{}; foreach ($key in $Saved.Keys) { $copy[$key]=$Saved[$key] }
    $copy.GIT_CONFIG_NOSYSTEM='1'; $copy.GIT_CONFIG_GLOBAL=$script:Config; return $copy
}
function Get-TestInventory {
    Get-CleanupInventory @($script:State) $script:Ledger $script:Temp 24
}
function Get-TestProofInventory {
    Clear-TestGitReplies
    $saved=Get-TestGitEnvironment
    try {
        Restore-TestGitEnvironment @{GIT_CONFIG_NOSYSTEM='1';GIT_CONFIG_GLOBAL=$script:Config;GIT_NO_LAZY_FETCH='1';GIT_OPTIONAL_LOCKS='0'}
        $c=Get-TestInventory; Set-CleanupAllProofs $c; return $c
    } finally { Restore-TestGitEnvironment $saved }
}
function Assert-TestItem { param($Context,[string]$Path,[string]$Verdict,[string]$Reason)
    $i=$Context.Items[$Path]
    Assert-Test ($null -ne $i -and $i.Verdict -eq $Verdict -and $i.Reason.Contains($Reason)) ("$Verdict $Path reason $Reason; got "+$i.Verdict+' '+$i.Reason)
}
function Assert-TestReportItem { param([string]$Path,[string]$Verdict,[string]$Reason)
    $line=@($script:LastText -split "`n" | Where-Object { $_.StartsWith($Verdict+' ') -and $_.Contains($Path+' -- ') -and $_.Contains($Reason) })
    Assert-Test ($line.Count -eq 1) ("$Verdict $Path reason $Reason; report: "+$script:LastText)
}
function New-TestQuarantine { param([string]$Parent=$script:Temp,[string]$Prefix='')
    $q=Join-Path $Parent ($Prefix+'.apex-cleanup-quarantine-20200101T000000Z-'+[guid]::NewGuid())
    Write-TestFile (Join-Path $q 'owner.txt') 'owner content'; return $q
}
function Set-CleanupProof { param($Item,$Context)
    [void]$script:LockEvents.Add([pscustomobject]@{Phase='proof';Path=$Item.Path;Held=[bool]($script:CleanupSession -and $script:CleanupSession.LockHeld);Acquisition=$script:Acquisition})
    & $originalProof $Item $Context
}
function Test-WorktreeProof { param([string]$Verdict,[string]$Reason)
    Clear-TestGitReplies
    $saved=Get-TestGitEnvironment
    try {
        Restore-TestGitEnvironment @{ GIT_CONFIG_GLOBAL=$script:Config;GIT_CONFIG_NOSYSTEM='1';GIT_NO_LAZY_FETCH='1';GIT_OPTIONAL_LOCKS='0' }
        $c=Get-TestInventory; $i=$c.Items[(ConvertTo-CleanupPath $script:Worktree)]
        Assert-Test ($null -ne $i) 'recorded worktree inventoried'
        Set-CleanupProof $i $c
        Assert-Test ($i.Verdict -eq $Verdict) ("worktree expected $Verdict got " + $i.Verdict+' '+$i.Reason)
        if ($Verdict -eq 'SAFE' -and -not $Reason) { $Reason='boundary and retained-content proof passed' }
        if ($Reason) { Assert-Test ($i.Reason -like ('*'+$Reason+'*')) ('worktree reason '+$Reason+' got '+$i.Reason) }
        return $c
    } finally { Restore-TestGitEnvironment $saved }
}
function Reset-TestWorktree {
    $restoreIndex=$script:ResetIndex -and -not $script:ResetNeedsGit
    if (-not $restoreIndex) { [void](Test-Git @('-C',$script:Worktree,'reset','--hard',$script:BaseHead)) }
    $script:FixtureGit.Clear(); $script:FixtureIndex.Clear()
    foreach ($p in @('extra.txt','.gitattributes','.gitignore','node_modules','.codex-scratch','.codex-tmp-one')) {
        $path=Join-Path $script:Worktree $p
        if (Test-CleanupExists $path) {
            if ($p -eq '.gitattributes') { $script:FixtureHashes.Clear(); $script:FixtureAttributes.Clear() }
            $a=Get-CleanupAttributes $path
            if ($a -band [IO.FileAttributes]::Directory) { Remove-CleanupDirectoryBottomUp $path }
            else { $script:FixtureGit.Clear(); [IO.File]::Delete($path) }
        }
    }
    Write-TestFile (Join-Path $script:Worktree 'file.txt') "integrated`n"
    $indexPath=Join-Path $script:Repo '.git/worktrees/task/index'
    if ($restoreIndex) { [IO.File]::WriteAllBytes($indexPath,$script:ResetIndex) }
    else {
        [void](Test-Git @('-C',$script:Worktree,'add','--','file.txt'))
        $script:ResetIndex=[IO.File]::ReadAllBytes($indexPath)
    }
    $script:ResetNeedsGit=$false
}
function Invoke-CleanupNative { param([string]$File,[string[]]$Arguments,[byte[]]$InputBytes)
    $nativeFile=if ($File -ceq 'git.exe') { $script:NativeGit } else { $File }
    if (-not $script:ProductionGit -or $File -cne 'git.exe') { return & $originalNative $nativeFile $Arguments $InputBytes }
    Assert-Test ($File -ceq 'git.exe') 'production uses Git executable'
    $all=$Arguments
    $Arguments=$all[2..($all.Count-1)]
    $configFlags=0; foreach ($argument in $all) { if ($argument -ceq '-c') { $configFlags++ } }
    Assert-Test ($configFlags -eq 1 -and $all[0] -ceq '-c' -and $all[1] -ceq 'core.fsmonitor=false') 'exact production config flag contract'
    Assert-Test ($env:GIT_NO_LAZY_FETCH -ceq '1' -and $env:GIT_OPTIONAL_LOCKS -ceq '0') 'production Git environment'
    Assert-Test ($env:GIT_CONFIG_GLOBAL -ceq $script:Config -and $env:GIT_CONFIG_NOSYSTEM -ceq '1') 'fixture config preserved'
    foreach ($bad in @('GIT_DIR','GIT_INDEX_FILE','GIT_WORK_TREE')) { Assert-Test (-not [Environment]::GetEnvironmentVariable($bad,'Process')) ('hostile variable removed '+$bad) }
    [void]$script:GitCalls.Add([pscustomobject]@{Args=$all;Input=$InputBytes;Locked=[bool]($script:CleanupSession -and $script:CleanupSession.LockHeld)})
    if ($script:DetachedPaths -and $script:DetachedPaths.Count) {
        $script:AfterDetachGitChecks++
        if ($Arguments.Count -ge 2 -and $Arguments[0] -eq '-C') {
            Assert-Test (-not $script:DetachedPaths.ContainsKey($Arguments[1])) ('no Git proof against detached original '+$Arguments[1])
        }
    }
    if (($Arguments -contains 'prune' -and $Arguments -notcontains '--dry-run') -or ($Arguments -contains 'branch' -and $Arguments -contains '-D')) {
        Assert-Test ([bool]$script:CleanupSession.LockHeld) 'Git detach under ledger mutex'
        [void]$script:LockEvents.Add([pscustomobject]@{Phase='git-detach';Path=($Arguments -join ' ');Held=$true;Acquisition=$script:Acquisition})
    }
    if ($script:Version -and $Arguments.Count -eq 1 -and $Arguments[0] -eq 'version') { return [pscustomobject]@{Code=0;Text=$script:Version;Error=''} }
    if ($script:Fault) { $injected=& $script:Fault 'git' $Arguments; if ($injected) { return $injected } }
    if ($script:FixtureVersion -and $Arguments.Count -eq 1 -and $Arguments[0] -eq 'version') { return [pscustomobject]@{Code=0;Text=$script:FixtureVersion;Error=''} }
    $guardKey=$Arguments -join ([string][char]0)
    if ($InputBytes) { $guardKey+='|'+[Convert]::ToBase64String($InputBytes) }
    if ($script:GuardGit -and $script:GuardGit.ContainsKey($guardKey)) { return $script:GuardGit[$guardKey] }
    $key=$guardKey
    # Reuse replies only within one cleanup/proof invocation while fixtures are unchanged.
    # All adapters/assertions still run. Writes and lock notifications invalidate replies;
    # fault injection precedes replay, so command-error cases still reach production.
    $metadata=($Arguments -notcontains 'prune' -and $Arguments -notcontains 'branch')
    if ($Arguments -contains 'check-attr' -and $script:FixtureAttributes.ContainsKey($key)) { return $script:FixtureAttributes[$key] }
    # Raw bytes identify repeated hash inputs within the current invocation.
    # Keep uncommon Git path quoting on the native path rather than interpreting it.
    $hashInput=$false
    if ($Arguments -contains 'hash-object' -and $InputBytes) {
        $quotedPaths=[Text.Encoding]::UTF8.GetString($InputBytes)
        if ($quotedPaths -cmatch '\A(?:"[a-zA-Z0-9._/-]+"\n)+\z') {
            foreach ($line in $quotedPaths.TrimEnd("`n").Split("`n")) {
                $key+='|'+[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $Arguments[1] $line.Trim('"'))))
            }
            $hashInput=$true
            if ($script:FixtureHashes.ContainsKey($key)) { return $script:FixtureHashes[$key] }
        }
    }
    # Commit/tree queries contain full object IDs and cannot change during a fixture.
    $immutable=($Arguments -contains 'ls-tree' -or $Arguments -contains 'merge-base' -or
        $Arguments -contains 'diff' -or ($Arguments -contains 'cat-file' -and $Arguments -contains '--batch-check')) -and
        -not @($Arguments | Where-Object { $_ -eq 'HEAD' -or $_ -like 'refs/*' }).Count
    if ($immutable -and $script:FixtureObjects.ContainsKey($key)) { return $script:FixtureObjects[$key] }
    $indexOnly=($Arguments -contains 'check-attr' -or ($Arguments -contains 'ls-files' -and $Arguments -contains '--stage'))
    if ($indexOnly -and $script:FixtureIndex.ContainsKey($key)) { return $script:FixtureIndex[$key] }
    $fixedPath=($Arguments -contains 'rev-parse') -and
        ($Arguments -contains '--show-toplevel' -or $Arguments -contains '--git-common-dir' -or $Arguments -contains '--git-path')
    if ($fixedPath -and $script:FixturePaths.ContainsKey($key)) { return $script:FixturePaths[$key] }
    $topology=($Arguments -contains 'rev-parse' -or $Arguments -contains 'for-each-ref' -or
        $Arguments -contains 'symbolic-ref' -or $Arguments -contains 'config' -or
        ($Arguments -contains 'worktree' -and $Arguments -contains 'list'))
    if ($topology -and $script:FixtureTopology.ContainsKey($key)) { return $script:FixtureTopology[$key] }
    if ($metadata -and $script:FixtureGit.ContainsKey($key)) { return $script:FixtureGit[$key] }
    if (($Arguments -contains 'prune' -and $Arguments -notcontains '--dry-run') -or ($Arguments -contains 'branch' -and $Arguments -contains '-D')) { $script:FixtureGit.Clear(); $script:FixtureTopology.Clear() }
    $answer=& $originalNative $nativeFile $all $InputBytes
    if ($Arguments -contains 'check-attr' -and $answer.Code -eq 0) { $script:FixtureAttributes[$key]=$answer }
    if ($hashInput -and $answer.Code -eq 0) { $script:FixtureHashes[$key]=$answer }
    if ($metadata -and $answer.Code -eq 0) { $script:FixtureGit[$key]=$answer }
    if ($immutable -and $answer.Code -eq 0) { $script:FixtureObjects[$key]=$answer }
    if ($indexOnly -and $answer.Code -eq 0) { $script:FixtureIndex[$key]=$answer }
    if ($fixedPath -and $answer.Code -eq 0) { $script:FixturePaths[$key]=$answer }
    if ($topology -and $answer.Code -in @(0,1)) { $script:FixtureTopology[$key]=$answer }
    if ($script:CaptureGuardGit) { $script:GuardGit[$guardKey]=$answer }
    return $answer
}
function Test-CleanupElevated { return $script:Elevated }
function Get-CleanupProcess { param([int]$ProcessId)
    if ($script:Identities.ContainsKey($ProcessId)) { return $script:Identities[$ProcessId] }
    return [pscustomobject]@{Exists=$false;Start=$null}
}
function Get-CleanupProcesses { $script:ProcessCalls++; if ($script:Fault) { & $script:Fault 'processes' $null | Out-Null }; return $script:Processes }
function Get-CleanupMutexName { return $script:MutexName }
function Open-CleanupMutex { param([string]$Name)
    [void]$script:Opened.Add($Name)
    Assert-Test ($Name -ceq $script:MutexName -and $Name -cne 'ApexCodexRunLedger') 'only unique fixture mutex opened'
    return New-Object Threading.Mutex($false,$Name)
}
function Send-CleanupLockNotification { param([string]$Phase,$Item)
    if ($Phase -eq 'after-lock' -and $script:Hook) { $script:FixtureGit.Clear(); $script:FixtureTopology.Clear() }
    if ($Phase -eq 'after-lock') { $script:Acquisition++ }
    if ($Phase -eq 'after-detach') {
        $script:DetachedPaths[$Item.Path]=$true
        if ($Item.Quarantine) { $script:DetachedPaths[$Item.Quarantine]=$true }
    }
    [void]$script:LockEvents.Add([pscustomobject]@{Phase=$Phase;Path=$Item.Path;Held=[bool]$script:CleanupSession.LockHeld;Acquisition=$script:Acquisition})
    if ($script:Hook) { & $script:Hook $Phase $Item }
}
function Invoke-CleanupMutation { param([string]$Operation,[string]$Path,[string]$Destination)
    Assert-Test ((Test-CleanupUnder $Path $script:TestRoot) -or (Test-CleanupEqual $Path $script:TestRoot)) ('mutation in fixture '+$Path)
    $locked=[bool]($script:CleanupSession -and $script:CleanupSession.LockHeld)
    if ($Operation -in @('directory','file','writable')) { Assert-Test (-not $locked) 'recursive deletion/attribute clearing outside lock' }
    [void]$script:Mutations.Add([pscustomobject]@{Operation=$Operation;Path=$Path;Destination=$Destination;Locked=$locked})
    [void]$script:LockEvents.Add([pscustomobject]@{Phase=$Operation;Path=$Path;Held=$locked;Acquisition=$script:Acquisition})
    if ($Operation -eq 'rename') {
        # Invalidate before fault hooks too: a failed rename must not preserve stale topology.
        $script:FixtureTopology.Clear(); $script:FixturePaths.Clear()
        foreach ($key in @($script:FixtureGit.Keys)) {
            if ($key -match '\x00worktree\x00list\x00') { $script:FixtureGit.Remove($key) }
        }
    } elseif ([IO.Path]::GetFileName($Path) -eq '.git') { $script:FixtureTopology.Clear() }
    if ($script:Fault) { & $script:Fault 'mutation' @($Operation,$Path,$Destination) | Out-Null }
    & $originalMutation $Operation $Path $Destination
    if ($script:CleanupSession) { $script:CleanupSession.Mutated=$true }
    if ($script:Hook) { & $script:Hook ('mutation-'+$Operation) $Path }
}
function Invoke-CleanupAclCommand { param([string]$File,[string[]]$Arguments)
    [void]$script:LockEvents.Add([pscustomobject]@{Phase='acl';Path=($Arguments -join ' ');Held=[bool]$script:CleanupSession.LockHeld;Acquisition=$script:Acquisition})
    Assert-Test (-not $script:CleanupSession.LockHeld) 'ACL outside lock'
    Assert-Test ($Arguments -notcontains '/r' -and $Arguments -notcontains '/t') 'ACL non-recursive'
    [void]$script:AclCalls.Add([pscustomobject]@{File=$File;Args=$Arguments})
    return [pscustomobject]@{Code=0;Text='';Error=''}
}
function Get-CleanupEntries { param([string]$Path)
    if ($script:Fault) { & $script:Fault 'enumerate' $Path | Out-Null }
    & $originalEntries $Path
}
function Add-CleanupJournal { param($Record,$Context)
    if ($script:Fault) { & $script:Fault 'journal' $Record | Out-Null }
    & $originalJournal $Record $Context
}
try {
    [void][IO.Directory]::CreateDirectory($script:TestRoot)
    $env:LOCALAPPDATA=Join-Path $script:TestRoot 'local'; $env:APEX_STATE_DIR=Join-Path $script:TestRoot 'alternate'
    $env:TEMP=Join-Path $script:TestRoot 'temp'; $env:TMP=$env:TEMP
    $script:Config=Join-Path $script:TestRoot 'global.gitconfig'
    $hooks=Join-Path $script:TestRoot 'hooks'; [void][IO.Directory]::CreateDirectory($hooks)
    $excludeGlobal=Join-Path $script:TestRoot 'empty-excludes'; Write-TestFile $excludeGlobal ''
    Write-TestFile $script:Config ("[user]`n name = apex-test`n email = apex-test@example.invalid`n[commit]`n gpgsign = false`n[core]`n hooksPath = "+$hooks.Replace('\','/')+"`n excludesFile = "+$excludeGlobal.Replace('\','/')+"`n autocrlf = false`n[filter `"unused`"]`n clean = cat`n[filter `"unused-process`"]`n process = fixture-filter-must-not-run`n")
    $script:Repo=Join-Path $script:TestRoot 'main'; $script:State=Join-Path $script:TestRoot 'state'
    $script:Temp=$env:TEMP; $script:Ledger=Join-Path $script:State 'progress/codex-run-ledger.jsonl'
    $script:Reports=Join-Path $script:TestRoot 'reports'
    foreach ($p in @($script:Repo,$script:State,$script:Temp,$script:Reports,$env:APEX_STATE_DIR,(Join-Path $env:LOCALAPPDATA 'apex'))) { [void][IO.Directory]::CreateDirectory($p) }
    [void](Test-Git @('init','-b','main',$script:Repo))
    $script:ProductionGit=$true
    $saved=Get-TestGitEnvironment
    try {
        Restore-TestGitEnvironment @{GIT_CONFIG_NOSYSTEM='1';GIT_CONFIG_GLOBAL=$script:Config;GIT_NO_LAZY_FETCH='1';GIT_OPTIONAL_LOCKS='0'}
        $nativeVersion=Get-CleanupGit @('version')
        Assert-Test ($nativeVersion.Code -eq 0 -and $nativeVersion.Text -match '^git version \d+\.\d+') 'production native adapter version exit and decoded output'
        $script:FixtureVersion=$nativeVersion.Text
        $nativeProof=Get-CleanupGit @('-C',$script:Repo,'rev-parse','--show-toplevel')
        Assert-Test ($nativeProof.Code -eq 0 -and (Test-CleanupEqual $nativeProof.Text.TrimEnd("`r","`n") $script:Repo)) 'production native adapter proof exit and decoded output'
    } finally { Restore-TestGitEnvironment $saved }
    Write-TestFile (Join-Path $script:Repo 'file.txt') "base`n"
    [void](Test-Git @('-C',$script:Repo,'add','.')); [void](Test-Git @('-C',$script:Repo,'commit','-m','base'))
    $script:BaseHead=Test-Git @('-C',$script:Repo,'rev-parse','HEAD')
    $parent=Join-Path $script:TestRoot 'fixture-wt'; [void][IO.Directory]::CreateDirectory($parent)
    $script:Worktree=Join-Path $parent 'task'
    [void](Test-Git @('-C',$script:Repo,'worktree','add','-b','codex/task',$script:Worktree,$script:BaseHead))
    Write-TestFile (Join-Path $script:Repo 'file.txt') "integrated`n"
    Write-TestFile (Join-Path $script:Repo 'extra.txt') "known`n"
    [void](Test-Git @('-C',$script:Repo,'add','.')); [void](Test-Git @('-C',$script:Repo,'commit','-m','integrated'))
    $script:MainHead=Test-Git @('-C',$script:Repo,'rev-parse','HEAD')
    Set-TestLedger @((New-TestRow $script:Worktree 'codex/task'))
    Reset-TestWorktree
    Write-TestStage 'cleanup: byte/index/HEAD proofs and filter gates'
    $savedInputEncoding=$null; $bomInputEncodingSet=$false
    try {
        try {
            $savedInputEncoding=[Console]::InputEncoding
            [Console]::InputEncoding=New-Object Text.UTF8Encoding $true
            $bomInputEncodingSet=$true
        } catch { Write-Output 'SKIP cleanup BOM stdin proof: console InputEncoding unavailable' }
        if ($bomInputEncodingSet) {
            Assert-Test ([Console]::InputEncoding.GetPreamble().Length -eq 3) 'forced UTF-8 console encoding has BOM'
            # Bypass all reply caches so the SAFE proof reaches production stdin Git.
            $savedProductionGit=$script:ProductionGit; $script:ProductionGit=$false
            try { [void](Test-WorktreeProof 'SAFE' '') }
            finally { $script:ProductionGit=$savedProductionGit }
            Assert-Test ([Console]::InputEncoding.GetPreamble().Length -eq 3) 'production restores BOM console encoding'
            $bytes=[Text.Encoding]::UTF8.GetBytes("integrated`n")
            $hash=Invoke-TestNative 'git.exe' @('-C',$script:Repo,'hash-object','--stdin') $bytes
            $expected=Test-Git @('-C',$script:Repo,'rev-parse','HEAD:file.txt')
            Assert-Test ($hash.Code -eq 0 -and $hash.Text.TrimEnd("`r","`n") -ceq $expected) 'fixture helper stdin contains exactly supplied bytes under BOM console encoding'
            Assert-Test ([Console]::InputEncoding.GetPreamble().Length -eq 3) 'fixture helper restores BOM console encoding'
        }
    } finally { if ($bomInputEncodingSet) { [Console]::InputEncoding=$savedInputEncoding } }
    [void](Test-WorktreeProof 'SAFE' '')
    Write-TestFile (Join-Path $script:Worktree 'file.txt') "unique`n"
    [void](Test-WorktreeProof 'KEEP' 'file.txt')
    [void](Test-Git @('-C',$script:Worktree,'add','file.txt'))
    Write-TestFile (Join-Path $script:Worktree 'file.txt') "integrated`n"
    [void](Test-WorktreeProof 'KEEP' 'index differs*file.txt')
    Reset-TestWorktree
    foreach ($flag in @('assume-unchanged','skip-worktree')) {
        [void](Test-Git @('-C',$script:Worktree,'update-index',('--'+$flag),'file.txt'))
        Write-TestFile (Join-Path $script:Worktree 'file.txt') "hidden`n"
        [void](Test-WorktreeProof 'KEEP' ($flag+'*file.txt'))
        [void](Test-Git @('-C',$script:Worktree,'update-index',('--no-'+$flag),'file.txt')); Reset-TestWorktree
    }
    [void](Test-Git @('-C',$script:Worktree,'config','core.sparseCheckout','true'))
    [void](Test-WorktreeProof 'KEEP' 'sparse-checkout')
    [void](Test-Git @('-C',$script:Worktree,'config','core.sparseCheckout','false')); Reset-TestWorktree
    Write-TestFile (Join-Path $script:Worktree 'extra.txt') "unique`n"
    [void](Test-WorktreeProof 'KEEP' 'extra.txt')
    Write-TestFile (Join-Path $script:Worktree 'extra.txt') "known`n"
    [void](Test-WorktreeProof 'SAFE' '')
    $script:FixtureGit.Clear(); [IO.File]::Delete((Join-Path $script:Worktree 'extra.txt'))
    foreach ($assignment in @('file.txt','extra.txt','clean.txt')) {
        if ($assignment -eq 'clean.txt') {
            Write-TestFile (Join-Path $script:Worktree 'clean.txt') "clean`n"
            [void](Test-Git @('-C',$script:Worktree,'add','clean.txt')); [void](Test-Git @('-C',$script:Worktree,'commit','-m','clean tracked'))
            $script:UniqueContentHead=Test-Git @('-C',$script:Worktree,'rev-parse','HEAD')
        }
        if ($assignment -eq 'extra.txt') { Write-TestFile (Join-Path $script:Worktree 'extra.txt') "known`n" }
        Write-TestFile (Join-Path $script:Worktree '.gitattributes') ($assignment+" filter=unused`n")
        $from=$script:GitCalls.Count; [void](Test-WorktreeProof 'KEEP' ('filtered path: manual review '+$assignment))
        $calls=@($script:GitCalls | Select-Object -Skip $from)
        Assert-Test (-not @($calls | Where-Object { $_.Args -contains 'status' -or $_.Args -contains 'hash-object' }).Count) 'filter gate before status/hash'
        Reset-TestWorktree
    }
    foreach ($p in @('.codex-scratch/a','.codex-tmp-one/b')) { Write-TestFile (Join-Path $script:Worktree $p) 'disposable' }
    [void](Test-WorktreeProof 'SAFE' ''); Reset-TestWorktree
    Write-TestFile (Join-Path $script:Worktree '.gitignore') "secret`nnode_modules/`n"
    # Keep .gitignore integrated in index/HEAD by using info/exclude instead.
    $script:FixtureGit.Clear(); [IO.File]::Delete((Join-Path $script:Worktree '.gitignore'))
    $exclude=Join-Path $script:Repo '.git/info/exclude'; Write-TestFile $exclude "secret`nnode_modules/`n"
    Write-TestFile (Join-Path $script:Worktree 'secret') 'unique'
    [void](Test-WorktreeProof 'KEEP' 'ignored non-cache file secret'); $script:FixtureGit.Clear(); [IO.File]::Delete((Join-Path $script:Worktree 'secret'))
    Write-TestFile (Join-Path $script:Worktree 'node_modules/a') 'cache'
    [void](Test-WorktreeProof 'SAFE' ''); Reset-TestWorktree
    $script:FixtureGit.Clear(); [IO.File]::Delete((Join-Path $script:Worktree 'file.txt'))
    [void](Test-WorktreeProof 'SAFE' ''); Reset-TestWorktree
    [void](Test-Git @('-C',$script:Worktree,'config','core.autocrlf','true'))
    Write-TestFile (Join-Path $script:Worktree 'file.txt') "integrated`r`n"
    [void](Test-WorktreeProof 'SAFE' '')
    [void](Test-Git @('-C',$script:Worktree,'config','core.autocrlf','false')); Reset-TestWorktree

    [void](Test-Git @('-C',$script:Repo,'worktree','lock','--reason','fixture lock',$script:Worktree))
    [void](Test-WorktreeProof 'KEEP' 'fixture lock')
    [void](Test-Git @('-C',$script:Repo,'worktree','unlock',$script:Worktree))
    $redirect=Join-Path $script:TestRoot 'redirect'; Write-TestFile (Join-Path $redirect 'keep') 'redirect target'
    [void](Test-Git @('-C',$script:Repo,'config','extensions.worktreeConfig','true'))
    $worktreeConfig=Join-Path $script:Repo '.git/worktrees/task/config.worktree'
    [void](Test-Git @('config','--file',$worktreeConfig,'core.worktree',$redirect))
    $before=Get-TestSnapshot
    [void](Test-WorktreeProof 'KEEP' ('git work tree mismatch '+$redirect))
    Assert-Test ((Get-TestSnapshot) -ceq $before) 'redirected worktree and target byte-unchanged'
    [void](Test-Git @('config','--file',$worktreeConfig,'--unset','core.worktree'))
    [void](Test-Git @('-C',$script:Worktree,'commit','-m','equivalent unique commit'))
    $unique=Test-Git @('-C',$script:Worktree,'rev-parse','HEAD')
    [void](Test-Git @('-C',$script:Worktree,'checkout','--detach',$unique))
    [void](Test-WorktreeProof 'KEEP' ('unique detached commit '+$unique))
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 0 -and (Test-CleanupExists $script:Worktree)) 'unique detached Apply retained'
    [void](Test-Git @('-C',$script:Repo,'branch','retained/other',$unique))
    [void](Test-WorktreeProof 'SAFE' '')
    [void](Test-Git @('-C',$script:Worktree,'checkout','codex/task')); Reset-TestWorktree
    [void](Test-Git @('-C',$script:Repo,'branch','-D','retained/other'))

    Write-TestStage 'cleanup: no-write listing, environment isolation and native exit codes'
    $report=Join-Path $script:Reports 'must-not-exist.txt'
    $before=Get-TestSnapshot
    Assert-Test ((Invoke-TestCleanup -Report $report) -eq 0) ('list exit: '+$script:LastText)
    Assert-Test ((Get-TestSnapshot) -ceq $before) 'list changes no bytes/index/ref/registration/last-write metadata'
    Assert-Test (-not (Test-CleanupExists $report)) 'list does not create report'
    $decoy=Join-Path $script:TestRoot 'decoy'; [void][IO.Directory]::CreateDirectory($decoy)
    Write-TestFile (Join-Path $decoy 'index') 'decoy index'
    $saved=Get-TestGitEnvironment
    try {
        $env:GIT_DIR=$decoy; $env:GIT_WORK_TREE=$decoy; $env:GIT_INDEX_FILE=Join-Path $decoy 'index'; $env:GIT_FOO='hostile'
        $hostile=Get-TestGitEnvironment; $before=Get-TestSnapshot
        Assert-Test ((Invoke-TestCleanup) -eq 0) 'hostile environment list proves real fixture'
        Assert-TestGitEnvironment $hostile
        Assert-Test ((Get-TestSnapshot) -ceq $before) 'decoys and fixture unchanged'
    } finally { Restore-TestGitEnvironment $saved }
    foreach ($version in @('git version 2.43.9','not a Git version')) {
        $script:Version=$version
        foreach ($applyMode in @($false,$true)) {
            $from=$script:GitCalls.Count; $before=Get-TestSnapshot
            Assert-Test ((Invoke-TestCleanup -Apply:$applyMode) -eq 1) 'version refusal exit 1'
            Assert-Test ($script:LastText -like ('*'+$version+'*')) 'version refusal names reported version'
            Assert-Test (($script:GitCalls.Count-$from) -eq 1 -and $script:GitCalls[-1].Args[-1] -eq 'version') 'version only Git call'
            Assert-Test ((Get-TestSnapshot) -ceq $before) 'version refusal no mutation'
        }
    }
    $script:Version=$null; $script:Elevated=$false; $before=Get-TestSnapshot
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 2) 'elevation refusal exit 2'
    Assert-Test ((Get-TestSnapshot) -ceq $before) 'elevation refusal has no changes/report'
    $script:Elevated=$true
    # Independent read-only children share the same immutable repository fixture.
    $children=New-Object Collections.ArrayList; $before=Get-TestSnapshot
    try {
        foreach ($extra in @(@(),@('-MinAgeHours','-1'),@('-RemoveQuarantine',$script:Worktree))) {
            $saved=Get-TestGitEnvironment; $runtimeTemp=$env:TEMP; $runtimeTmp=$env:TMP
            try {
                Restore-TestGitEnvironment @{GIT_CONFIG_NOSYSTEM='1';GIT_CONFIG_GLOBAL=$script:Config}
                # Keep startup policy probes inside the harness, outside cleanup inputs.
                $env:TEMP=$script:TestRoot; $env:TMP=$script:TestRoot
                $args=@('-NoProfile','-File',$production,'-StateRoot',$script:State,'-LedgerPath',$script:Ledger,'-TempRoot',$script:Temp,'-ReportPath',$report)+$extra
                $si=New-Object Diagnostics.ProcessStartInfo
                $si.FileName='powershell.exe'; $si.Arguments=(@($args | ForEach-Object { ConvertTo-CleanupArgument $_ }) -join ' ')
                $si.UseShellExecute=$false; $si.CreateNoWindow=$true
                $si.RedirectStandardInput=$true; $si.RedirectStandardOutput=$true; $si.RedirectStandardError=$true
                $p=New-Object Diagnostics.Process; $p.StartInfo=$si
                [void]$children.Add([pscustomobject]@{Process=$p;Out=$null;Error=$null;Expected=$(if ($extra.Count) {1} else {0})})
                # Empty stdin must also stay empty under a BOM console encoding.
                $stdinEncoding=$null
                try {
                    $stdinEncoding=[Console]::InputEncoding
                    [Console]::InputEncoding=New-Object Text.UTF8Encoding $false
                } catch { $stdinEncoding=$null }
                try { [void]$p.Start() }
                finally { if ($null -ne $stdinEncoding) { [Console]::InputEncoding=$stdinEncoding } }
                $p.StandardInput.Close()
                $children[-1].Out=$p.StandardOutput.ReadToEndAsync(); $children[-1].Error=$p.StandardError.ReadToEndAsync()
            } finally { Restore-TestGitEnvironment $saved; $env:TEMP=$runtimeTemp; $env:TMP=$runtimeTmp }
        }
        foreach ($child in $children) { Wait-TestChild $child.Process }
        $after=Get-TestSnapshot
        if ($after -cne $before) { Compare-Object ($before -split "`n") ($after -split "`n") | ForEach-Object { Write-Output ($_.SideIndicator+' '+$_.InputObject) } }
        foreach ($child in $children) {
            $output=$child.Out.GetAwaiter().GetResult(); $errorText=$child.Error.GetAwaiter().GetResult()
            Assert-Test ($child.Process.ExitCode -eq $child.Expected) ('native list/invalid argument exit '+$child.Process.ExitCode+' '+$errorText+' '+$output)
            Assert-Test ($after -ceq $before) 'native list/invalid argument no writes'
        }
    } finally {
        foreach ($child in $children) {
            try { if (-not $child.Process.HasExited) { $child.Process.Kill(); [void]$child.Process.WaitForExit(5000) } } finally { $child.Process.Dispose() }
        }
    }

    Write-TestStage 'cleanup: identities, closure matching, process quiescence and root union'
    # These cases mutate only process/record fixtures. Replay the three unchanged
    # repository-inventory replies; every content query remains real Git. This
    # seam is disabled before any lock/detach test, so no detach proof is cached.
    $script:GuardGit=@{}; $script:CaptureGuardGit=$true; $saved=Get-TestGitEnvironment
    try { Restore-TestGitEnvironment @{GIT_CONFIG_NOSYSTEM='1';GIT_CONFIG_GLOBAL=$script:Config;GIT_NO_LAZY_FETCH='1';GIT_OPTIONAL_LOCKS='0'}; [void](Get-TestInventory) }
    finally { $script:CaptureGuardGit=$false; Restore-TestGitEnvironment $saved }
    $guardLocks=$script:Opened.Count
    $stamp='2020-01-01T00:00:00Z'; $script:Identities[901001]=[pscustomobject]@{Exists=$true;Start=$stamp}
    Assert-Test ((Test-CleanupProcessIdentity 901001 $stamp) -eq 'live') 'matching PID/start live'
    Assert-Test ((Test-CleanupProcessIdentity 901001 '2019-01-01T00:00:00Z') -eq 'dead') 'PID reuse dead'
    Assert-Test ((Test-CleanupProcessIdentity 901001 '') -eq 'unresolved') 'missing start unresolved'
    $live=New-TestRow $script:Worktree 'codex/task' 'live'; $live.status='running'; $live.pid=901001; $live.pid_start=$stamp
    Set-TestLedger @($live); [void](Test-WorktreeProof 'KEEP' 'live dispatch')
    $before=Get-TestSnapshot; Assert-Test ((Invoke-TestCleanup -Apply) -eq 2) 'live ledger guard'
    Assert-Test ((Get-TestSnapshot) -ceq $before) 'live guard no report/mutation'
    Set-TestLedger @($live,(New-TestRow '' '' 'other'))
    [void](Test-WorktreeProof 'KEEP' 'live dispatch')
    Set-TestLedger @($live,(New-TestRow '' '' 'live'))
    [void](Test-WorktreeProof 'SAFE' '')
    $live=New-TestLease $script:Worktree
    Set-TestLedger @((New-TestRow $script:Worktree 'codex/task'),$live,(New-TestClose 'live'))
    [void](Test-WorktreeProof 'SAFE' '')
    $live.launcher_start=$null; Set-TestLedger @((New-TestRow $script:Worktree 'codex/task'),$live)
    [void](Test-WorktreeProof 'KEEP' 'unresolved process identity')
    Set-TestLedger @((New-TestRow $script:Worktree 'codex/task'),$live,(New-TestClose 'other'))
    [void](Test-WorktreeProof 'KEEP' 'unresolved process identity')
    foreach ($close in @('lease_close','dispatch')) {
        $closeRow=if ($close -eq 'lease_close') { New-TestClose 'live' } else { New-TestRow '' '' 'live' }
        Set-TestLedger @((New-TestRow $script:Worktree 'codex/task'),$live,$closeRow)
        [void](Test-WorktreeProof 'SAFE' '')
    }
    Set-TestLedger @((New-TestRow $script:Worktree 'codex/task'))
    $runState=New-TestState -Worktree $script:Worktree -Branch 'codex/task'
    foreach ($kind in @('owner','attempt','task-acceptance','spec-acceptance','wrapper')) {
        $runState=New-TestState -Worktree $script:Worktree -Branch 'codex/task'
        switch ($kind) {
            'owner' { $runState.engine_owner=@{pid=901001;start_time=$stamp} }
            'attempt' { $attempt=New-TestAttempt; $attempt.child_pid=901001;$attempt.child_start_time=$stamp;$runState.tasks=@((New-TestTask @($attempt))) }
            'task-acceptance' { $task=New-TestTask; $task | Add-Member acceptance @((New-TestAcceptance)); $runState.tasks=@($task) }
            'spec-acceptance' { $runState | Add-Member spec_acceptance @{checks=@((New-TestAcceptance))} }
            'wrapper' { $attempt=New-TestAttempt;$attempt.wrapper_run_id='live';$runState.tasks=@((New-TestTask @($attempt))); $live=New-TestRow $script:Worktree 'codex/task' 'live'; $live.status='running';$live.pid=901001;$live.pid_start=$stamp; Set-TestLedger @((New-TestRow $script:Worktree 'codex/task'),$live) }
        }
        $path=Save-TestState $runState
        [void](Test-WorktreeProof 'KEEP' 'live')
        $before=Get-TestSnapshot; Assert-Test ((Invoke-TestCleanup -Apply) -eq 2) ('engine/child guard '+$kind)
        Assert-Test ((Get-TestSnapshot) -ceq $before) ('no changes for '+$kind)
        Remove-CleanupDirectoryBottomUp ([IO.Path]::GetDirectoryName($path))
        Set-TestLedger @((New-TestRow $script:Worktree 'codex/task'))
    }
    $processCases=New-Object Collections.ArrayList
    foreach ($scriptName in @('apex-engine.ps1','codex-dispatch.ps1','engine-dispatch.ps1','apex-drain.ps1','apex-cleanup.ps1')) { [void]$processCases.Add(@('powershell.exe',('powershell.exe -File '+$scriptName))) }
    foreach ($alias in @('-EncodedCommand','-enc','-ec','-e','-EnCoDeDcOmMaNd')) {
        $payload=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('& apex-engine.ps1'))
        [void]$processCases.Add(@('pwsh.exe',('pwsh.exe '+$alias+' '+$payload)))
    }
    [void]$processCases.Add(@('powershell.exe','powershell.exe -enc invalid!'))
    $nested='function D([string]$v) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($v)) }; $wrapperPath = D ''Y29kZXgtZGlzcGF0Y2gucHMx'''
    [void]$processCases.Add(@('powershell.exe',('powershell.exe -ec '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($nested)))))
    [void]$processCases.Add(@('anything.exe','anything.exe exec -p apex-coder'))
    [void]$processCases.Add(@('anything.exe','anything.exe "exec" "-p" "apex-coder"'))
    foreach ($pc in $processCases) {
        $script:Processes=@([pscustomobject]@{ProcessId=901003;Name=$pc[0];CommandLine=$pc[1]})
        $before=Get-TestSnapshot; Assert-Test ((Invoke-TestCleanup -Apply) -eq 2) ('process guard '+$pc[1])
        Assert-Test ($script:LastText -like '*901003*') 'process guard lists PID'
        Assert-Test ((Get-TestSnapshot) -ceq $before) 'process refusal no changes'
    }
    $script:Processes=@([pscustomobject]@{ProcessId=$PID;Name='powershell.exe';CommandLine='apex-cleanup.ps1'})
    foreach ($cmd in @('codex.exe','codex.exe app-server','codex.exe exec-server','codex.exe sandbox')) { $script:Processes+=,[pscustomobject]@{ProcessId=901010;Name='codex.exe';CommandLine=$cmd} }
    $saved=Get-TestGitEnvironment
    try {
        Restore-TestGitEnvironment @{GIT_CONFIG_NOSYSTEM='1';GIT_CONFIG_GLOBAL=$script:Config;GIT_NO_LAZY_FETCH='1';GIT_OPTIONAL_LOCKS='0'}
        Assert-Test (@(Get-CleanupGuard (Get-TestInventory)).Count -eq 0) 'current process and editor Codex do not trip'
    } finally { Restore-TestGitEnvironment $saved }; $script:Processes=@()
    foreach ($root in @((Join-Path $env:LOCALAPPDATA 'apex'),$env:APEX_STATE_DIR,(Join-Path $script:TestRoot 'explicit-two'))) {
        $runState=New-TestState; $runState.engine_owner=@{pid=901001;start_time=$stamp}; $path=Save-TestState $runState $root
        $before=Get-TestSnapshot
        Assert-Test ((Invoke-TestCleanup -Apply -Roots @($script:State,$root,$root)) -eq 2) 'all union roots guard'
        Assert-Test ((Get-TestSnapshot) -ceq $before) 'root union refusal no changes'
        Remove-CleanupDirectoryBottomUp ([IO.Path]::GetDirectoryName($path))
    }
    Assert-Test ($script:Opened.Count -eq $guardLocks) 'no mutex/detach occurs in guard-only inventory replay cases'
    $script:GuardGit=$null

    Write-TestStage 'cleanup: apply, locked reproof and quarantines'
    $script:Hook={param($phase,$item) if ($phase -eq 'after-lock') { Write-TestFile (Join-Path $script:Worktree 'file.txt') "changed-under-lock`n" }}
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 0) ('changed locked proof policy KEEP '+$script:LastText)
    Assert-Test ($script:LastText -like '*KEEP worktree*file.txt*') 'locked reproof retains changed file'
    Assert-Test (Test-CleanupExists $script:Worktree) 'changed worktree kept'
    $script:Hook=$null; Reset-TestWorktree
    $waitReady=New-Object Threading.ManualResetEvent($false); $release=New-Object Threading.ManualResetEvent($false)
    $worker=[powershell]::Create()
    [void]$worker.AddScript({param($name,$ready,$release,$file)
        $m=New-Object Threading.Mutex($false,$name); $held=$false
        try { $held=$m.WaitOne(5000); if (-not $held) { throw 'worker lock timeout' }; [void]$ready.Set(); if (-not $release.WaitOne(5000)) { throw 'worker signal timeout' }; [IO.File]::WriteAllText($file,"worker edit`n") }
        finally { if ($held) { $m.ReleaseMutex() }; $m.Dispose() }
    }).AddArgument($script:MutexName).AddArgument($waitReady).AddArgument($release).AddArgument((Join-Path $script:Worktree 'file.txt'))
    [void]$script:Opened.Add($script:MutexName)
    $async=$worker.BeginInvoke()
    try {
        Assert-Test ($waitReady.WaitOne(5000)) 'contention worker acquired unique mutex'
        $script:Hook={param($phase,$item) if ($phase -eq 'before-lock') { [void]$release.Set() }}
        Assert-Test ((Invoke-TestCleanup -Apply) -eq 0) 'contended locked reproof KEEP'
        Assert-Test ($script:LastText -like '*KEEP worktree*file.txt*') 'worker edit retained after acquisition'
        Assert-Test ($async.AsyncWaitHandle.WaitOne(5000)) 'bounded worker join'; [void]$worker.EndInvoke($async)
    } finally { $script:Hook=$null; [void]$release.Set(); $worker.Dispose(); $waitReady.Dispose(); $release.Dispose() }
    Reset-TestWorktree
    $beforeMain=Get-TestSnapshot $script:Repo
    $mainIndex=Join-Path $script:Repo '.git/index'
    $indexBefore=[Convert]::ToBase64String([IO.File]::ReadAllBytes($mainIndex)); $indexTime=[IO.File]::GetLastWriteTimeUtc($mainIndex)
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 0) ('safe apply '+$script:LastText)
    Assert-Test (-not (Test-CleanupExists $script:Worktree)) 'SAFE worktree removed'
    Assert-Test ($script:LastText -like '*SAFE branch*removed*') 'branch removed after worktree'
    Assert-Test ((Test-Git @('-C',$script:Repo,'rev-parse','HEAD')) -ceq $script:MainHead) 'main HEAD unchanged'
    Assert-Test (([IO.File]::ReadAllText((Join-Path $script:Repo 'file.txt'))) -ceq "integrated`n") 'main bytes unchanged'
    Assert-Test ([Convert]::ToBase64String([IO.File]::ReadAllBytes($mainIndex)) -ceq $indexBefore -and [IO.File]::GetLastWriteTimeUtc($mainIndex) -eq $indexTime) 'main index bytes/last-write unchanged'
    $journal=Join-Path $script:State 'cleanup/journal.jsonl'
    $journalBefore=[IO.File]::ReadAllText($journal)
    Assert-Test ($journalBefore -match '"action":"quarantine"') 'journal precedes detach'
    Assert-Test ($script:LastText -like '*DETACH GROUP prune registrations*') 'prune detach group reported'
    $quarantines=@()
    foreach ($location in @($parent,$script:State,$script:Temp)) {
        $q=Join-Path $location ('.apex-cleanup-quarantine-20200101T000000Z-'+[guid]::NewGuid())
        Write-TestFile (Join-Path $q 'unique.txt') 'owner data'
        $quarantines+=,$q
        $record=[ordered]@{utc='2020-01-01T00:00:00Z';action='quarantine';original_path=(Join-Path $location 'old');quarantine_path=$q;class='worktree';run_ids=@('one','two');spec='sample';branch='codex/old'}
        [IO.File]::AppendAllText($journal,(($record|ConvertTo-Json -Compress)+"`n"))
    }
    $q=Join-Path $script:TestRoot ('main-wt-old.apex-cleanup-failed-20200101T000000Z-'+[guid]::NewGuid()); Write-TestFile (Join-Path $q 'unique') 'failed'
    $quarantines+=,$q
    $record=@{utc='2020-01-01T00:00:00Z';action='failed-rollback';original_path=(Join-Path $script:TestRoot 'main-wt-old');previous_quarantine_path='old';quarantine_path=$q;class='worktree'}
    [IO.File]::AppendAllText($journal,(($record|ConvertTo-Json -Compress)+"`n"))
    $q=Join-Path $script:Temp ('.apex-cleanup-quarantine-20200101T000000Z-'+[guid]::NewGuid()); Write-TestFile (Join-Path $q 'unknown') 'unknown'
    $quarantines+=,$q
    $q=Join-Path (Join-Path $script:TestRoot 'journal-only') ('.apex-cleanup-quarantine-20200101T000000Z-'+[guid]::NewGuid()); Write-TestFile (Join-Path $q 'journal-only') 'only record'
    $quarantines+=,$q
    [IO.File]::AppendAllText($journal,((@{utc='2020-01-01T00:00:00Z';action='quarantine';original_path='old';quarantine_path=$q;class='orphan'}|ConvertTo-Json -Compress)+"`n"))
    Assert-Test ((Invoke-TestCleanup) -eq 0) 'quarantine list'
    Assert-Test ($script:LastText -like '*interrupted quarantine: needs owner y/n*since*run one*run two*spec sample*branch codex/old*') 'all quarantine provenance'
    Assert-Test ($script:LastText -like '*failed rollback: needs owner y/n*since*') 'failed provenance'
    Assert-Test ($script:LastText -like '*origin unknown; last write*') 'unknown provenance'
    $snapshots=@{}; foreach ($q in $quarantines) { $snapshots[$q]=Get-TestSnapshot $q }
    $aclFrom=$script:AclCalls.Count; Assert-Test ((Invoke-TestCleanup -Apply) -eq 0) 'ordinary apply preserves earlier quarantines'
    foreach ($q in $quarantines) { Assert-Test ((Get-TestSnapshot $q) -ceq $snapshots[$q]) 'earlier quarantine bytes/metadata preserved' }
    Assert-Test ($script:AclCalls.Count -eq $aclFrom) 'no ACL work on earlier quarantines'
    $from=$script:GitCalls.Count
    $target=$quarantines[-1]
    $relative=$target.Substring($script:TestRoot.Length+1)
    Push-Location $script:TestRoot
    try { Assert-Test ((Invoke-TestCleanup -Apply -Names @($relative,$target.ToUpperInvariant(),$target)) -eq 0) ('owner removal '+$script:LastText) }
    finally { Pop-Location }
    Assert-Test (-not (Test-CleanupExists $target)) 'relative/case/duplicate owner removal'
    Assert-Test (@($script:GitCalls | Select-Object -Skip $from | Where-Object { $_.Args -contains 'status' -or $_.Args -contains 'hash-object' -or $_.Args -contains 'prune' -or $_.Args -contains 'branch' }).Count -eq 0) 'owner removal no content/prune/branch calls'
    $removedLines=@([IO.File]::ReadAllLines($journal) | ForEach-Object { $_|ConvertFrom-Json } | Where-Object { $_.action -eq 'removed' -and (Test-CleanupEqual $_.quarantine_path $target) })
    Assert-Test ($removedLines.Count -eq 1 -and $removedLines[0].utc -and $removedLines[0].result) 'one removed journal line'
    Assert-Test ((Invoke-TestCleanup -Apply -Names @($quarantines[3],$script:Repo)) -eq 1) 'mixed owner values error but valid removed'
    Assert-Test (-not (Test-CleanupExists $quarantines[3])) 'failed rollback owner removal'
    Assert-Test (Test-CleanupExists $script:Repo) 'invalid main root preserved'
    Assert-Test ([IO.File]::ReadAllText($journal).StartsWith($journalBefore,[StringComparison]::Ordinal)) 'journal append-only prefix'
    # Completed cases need no lingering quarantines or journal rows in later inventories.
    foreach ($q in $quarantines) { if (Test-CleanupExists $q) { Remove-CleanupDirectoryBottomUp $q } }
    Write-TestFile $journal ''

    Write-TestStage 'cleanup: orphan/history/temp boundaries, link-safe real walker'
    # Policy cases share one minimal repository instead of repeatedly inventorying
    # every branch left by the independent commit-graph cases.
    $script:GraphRepo=$script:Repo; $script:PolicyRepo=Join-Path $script:TestRoot 'policy'
    [void](Test-Git @('clone','--single-branch','--branch','main','--shared',$script:GraphRepo,$script:PolicyRepo))
    $script:Repo=$script:PolicyRepo
    Set-TestLedger @()
    $orphan=Join-Path $parent 'orphan'; Write-TestFile (Join-Path $orphan 'unique') 'unique'
    Set-TestLedger @((New-TestRow $orphan ''))
    $oldWorktree=$script:Worktree; $script:Worktree=$orphan
    [void](Test-WorktreeProof 'KEEP' 'non-disposable entry')
    $script:FixtureGit.Clear(); [IO.File]::Delete((Join-Path $orphan 'unique')); [void](Test-WorktreeProof 'SAFE' '')
    Write-TestFile (Join-Path $orphan 'node_modules/cache') 'cache'; [void](Test-WorktreeProof 'SAFE' '')
    Write-TestFile (Join-Path $orphan 'node_modules/.git/config') 'nested'; [void](Test-WorktreeProof 'KEEP' 'contains repository or kept item')
    Remove-CleanupDirectoryBottomUp $orphan; Set-TestLedger @((New-TestRow $orphan ''))
    [void](Test-WorktreeProof 'GONE' '')
    $script:Worktree=$oldWorktree; Set-TestLedger @()
    $runState=New-TestState; $sp=Save-TestState $runState -Old
    Assert-Test ((Invoke-TestCleanup) -eq 0) 'old history list'
    Assert-Test ($script:LastText -like '*SAFE history*') 'independent old history safe'
    $runState.handoff.recovery_patch='save.patch'; [void](Save-TestState $runState -Old)
    Assert-Test ((Invoke-TestCleanup) -eq 0 -and $script:LastText -like '*KEEP history*recovery patch*') 'patch history keep'
    $runState.status='complete'; $runState.teardown.status='complete'; [void](Save-TestState $runState -Old)
    Assert-Test ((Invoke-TestCleanup) -eq 0 -and $script:LastText -like '*SAFE history*') 'complete patch waiver'
    Remove-CleanupDirectoryBottomUp ([IO.Path]::GetDirectoryName($sp))
    $young=Join-Path $script:Temp 'engine-test-young'; $old=Join-Path $script:Temp 'engine-test-old'; $other=Join-Path $script:Temp 'unrelated'
    foreach ($p in @($young,$old,$other)) { Write-TestFile (Join-Path $p 'file') 'temp' }
    [IO.Directory]::SetLastWriteTimeUtc($old,[datetime]::UtcNow.AddDays(-3))
    Assert-Test ((Invoke-TestCleanup) -eq 0) 'temp inventory'
    Assert-Test ($script:LastText -like '*SAFE temp*engine-test-old*' -and $script:LastText -notlike '*engine-test-young*' -and $script:LastText -notlike ('*temp '+$other+'*')) 'temp prefix/age selection'
    Write-TestFile (Join-Path $old '.git/config') 'repository'; [IO.Directory]::SetLastWriteTimeUtc($old,[datetime]::UtcNow.AddDays(-3))
    Assert-Test ((Invoke-TestCleanup) -eq 0 -and $script:LastText -like '*KEEP temp*contains repository or kept item*') 'temp nested repository keep'
    $scope=Join-Path $script:Temp 'apex-scope-empty'; [void][IO.Directory]::CreateDirectory($scope)
    Assert-Test ((Invoke-TestCleanup) -eq 0 -and $script:LastText -like '*SAFE temp*apex-scope-empty*') 'empty scope safe'
    Write-TestFile (Join-Path $scope 'recent') 'new'
    Assert-Test ((Invoke-TestCleanup) -eq 0 -and $script:LastText -like '*KEEP temp*recent scope file*recent*') 'recent scope keep'
    [IO.File]::SetLastWriteTimeUtc((Join-Path $scope 'recent'),[datetime]::UtcNow.AddDays(-8))
    Assert-Test ((Invoke-TestCleanup) -eq 0 -and $script:LastText -like '*SAFE temp*apex-scope-empty*') 'old scope safe'
    foreach ($p in @($young,$old,$other,$scope)) { Remove-CleanupDirectoryBottomUp $p }

    Write-TestStage 'cleanup: error isolation, guard completion, ACL inspection and rollback'
    $first=Join-Path $parent 'a-first'; $second=Join-Path $parent 'b-second'
    foreach ($p in @($first,$second)) { [void][IO.Directory]::CreateDirectory($p) }
    Set-TestLedger @((New-TestRow $first '' 'first'),(New-TestRow $second '' 'second'))
    $script:Hook={param($phase,$item)
        if ($phase -eq 'after-detach' -and (Test-CleanupEqual $item.Path $first)) {
            $lease=New-TestLease '' 'late'
            [IO.File]::AppendAllText($script:Ledger,(($lease|ConvertTo-Json -Compress)+"`n"))
        }
    }
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 2) ('mid-run guard completion '+$script:LastText)
    Assert-Test (-not (Test-CleanupExists $first) -and (Test-CleanupExists $second)) 'first quarantine finished, second untouched'
    Assert-Test ($script:LastText -like '*SAFE worktree*removed*' -and $script:LastText -like '*STOP*late*') 'completed removal and trip reported'
    $script:Hook=$null; Set-TestLedger @((New-TestRow $second '' 'second'))
    $script:DenyCount=0
    $script:Fault={param($kind,$value) if ($kind -eq 'enumerate' -and (Test-CleanupEqual $value $second) -and $script:DenyCount -eq 0) { $script:DenyCount++; throw (New-Object UnauthorizedAccessException('fixture denied')) }}
    Assert-Test ((Invoke-TestCleanup) -eq 0 -and $script:LastText -like '*unreadable: needs -Apply elevated inspection*') 'list access denial is policy KEEP'
    $script:DenyCount=0; $aclFrom=$script:AclCalls.Count
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 0) ('elevated inspection retry '+$script:LastText)
    Assert-Test ($script:AclCalls.Count-$aclFrom -eq 2) 'exactly one takeown/icacls repair pair'
    Assert-Test ($script:LastText -like '*ACL CHANGED*') 'inspection metadata changes reported'
    $script:Fault=$null
    # Persistent sibling denials clear only after that directory's own repair pair.
    $deniedItem=Join-Path $parent 'denied-siblings'
    $script:DeniedSiblings=@((Join-Path $deniedItem 'node_modules/a'),(Join-Path $deniedItem 'node_modules/b'))
    foreach ($p in $script:DeniedSiblings) { Write-TestFile (Join-Path $p 'cache') 'cache' }
    Set-TestLedger @((New-TestObligation $deniedItem '')); $aclFrom=$script:AclCalls.Count
    $script:Fault={param($kind,$value)
        if ($kind -eq 'enumerate' -and $script:DeniedSiblings -contains $value -and
            -not @($script:AclCalls | Select-Object -Skip $aclFrom | Where-Object { $_.File -eq 'icacls.exe' -and $_.Args[0] -eq $value }).Count) {
            throw (New-Object UnauthorizedAccessException('fixture sibling denied'))
        }
    }
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 0 -and -not (Test-CleanupExists $deniedItem)) 'two denied siblings repaired and item removed'
    foreach ($p in $script:DeniedSiblings) {
        $repairs=@($script:AclCalls | Select-Object -Skip $aclFrom | Where-Object { $_.Args -contains $p })
        Assert-Test ($repairs.Count -eq 2 -and $repairs[0].File -eq 'takeown.exe' -and $repairs[1].File -eq 'icacls.exe') 'each denied sibling gets its own repair pair'
    }
    $script:Fault=$null
    [void][IO.Directory]::CreateDirectory($second)
    Set-TestLedger @((New-TestRow $second '' 'second'))
    $script:Fault={param($kind,$value) if ($kind -eq 'journal' -and $value.action -eq 'quarantine') { throw 'fixture journal append denied' }}
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 1 -and (Test-CleanupExists $second) -and $script:LastText -like '*KEEP worktree*journal error*') 'journal failure prevents rename'
    $script:Fault=$null
    [IO.File]::AppendAllText($journal,"{malformed`n")
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 1 -and -not (Test-CleanupExists $second)) 'journal error permits independent SAFE mutation'
    Assert-Test ($script:LastText -like '*malformed journal*') 'journal parse error reported'
    # This fault is local to the parse-error case; later Apply exit codes stand alone.
    Write-TestFile $journal ''
    [void][IO.Directory]::CreateDirectory($second); Set-TestLedger @((New-TestRow $second '' 'second'))
    [IO.File]::AppendAllText($script:Ledger,"not json`n")
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 1 -and (Test-CleanupExists $second)) ('bad record sources suppress all target mutation: '+$script:LastCode+' '+$script:LastText)
    Set-TestLedger @()
    Remove-CleanupDirectoryBottomUp $second
    Set-TestLedger @($true)
    $scalarInventory=Get-TestInventory
    Assert-Test ($scalarInventory.BadRecords -and ($scalarInventory.Errors -join ' ') -like '*expected object*') 'scalar JSON is a malformed record and vetoes apply'
    Set-TestLedger @()
    [void][IO.Directory]::CreateDirectory($second); Set-TestLedger @((New-TestRow $second '' 'timeout'))
    function Wait-CleanupMutex { param($Mutex) return $false }
    try { Assert-Test ((Invoke-TestCleanup -Apply) -eq 0 -and (Test-CleanupExists $second) -and $script:LastText -like '*lock unavailable*') 'bounded timeout KEEP without mutation' }
    finally { ${function:Wait-CleanupMutex}=$originalWait }
    function Wait-CleanupMutex { param($Mutex) if (-not $Mutex.WaitOne(100)) { return $false }; throw (New-Object Threading.AbandonedMutexException('fixture abandoned')) }
    try { Assert-Test ((Invoke-TestCleanup -Apply) -eq 0 -and -not (Test-CleanupExists $second)) 'abandoned ownership still releases real fixture mutex' }
    finally { ${function:Wait-CleanupMutex}=$originalWait }
    [void][IO.Directory]::CreateDirectory($second); Set-TestLedger @((New-TestRow $second '' 'locked-live'))
    $lockedReport=Join-Path $script:Reports 'locked-live-refusal.txt'
    $script:Hook={param($phase,$item) if ($phase -eq 'after-lock') {
        $lease=New-TestLease '' 'locked-live-lease'
        [IO.File]::AppendAllText($script:Ledger,(($lease|ConvertTo-Json -Compress)+"`n"))
    }}
    Assert-Test ((Invoke-TestCleanup -Apply -Report $lockedReport) -eq 2 -and (Test-CleanupExists $second) -and -not (Test-CleanupExists $lockedReport)) 'new lease under held lock refuses before first mutation/report'
    $script:Hook=$null; Set-TestLedger @()
    Remove-CleanupDirectoryBottomUp $second
    $badProof=Join-Path $parent 'bad-proof'; $independent=Join-Path $parent 'independent'
    Write-TestFile (Join-Path $badProof '.git') 'gitdir: missing-metadata'
    [void][IO.Directory]::CreateDirectory($independent)
    Set-TestLedger @((New-TestRow $badProof '' 'bad-proof'),(New-TestRow $independent '' 'independent'))
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 1 -and (Test-CleanupExists $badProof) -and -not (Test-CleanupExists $independent)) 'per-item Git failure allows independent safe detach'
    Assert-Test ($script:LastText -like '*KEEP worktree*bad-proof*proof error*') 'per-item proof error names affected item'
    Remove-CleanupDirectoryBottomUp $badProof; Set-TestLedger @()
    $inspectionKeep=Join-Path $parent 'inspection-keep'; Write-TestFile (Join-Path $inspectionKeep 'unique.txt') 'unique keep bytes'
    Set-TestLedger @((New-TestRow $inspectionKeep '' 'inspection'))
    $script:DenyCount=0; $aclFrom=$script:AclCalls.Count
    $script:Fault={param($kind,$value) if ($kind -eq 'enumerate' -and (Test-CleanupEqual $value $inspectionKeep) -and $script:DenyCount -eq 0) { $script:DenyCount++; throw (New-Object UnauthorizedAccessException('fixture inspection denied')) }}
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 0 -and $script:LastText -like '*KEEP worktree*unique.txt*' -and $script:LastText -like '*ACL CHANGED*') 'inspection repair followed by content KEEP is reported'
    Assert-Test ([IO.File]::ReadAllText((Join-Path $inspectionKeep 'unique.txt')) -ceq 'unique keep bytes' -and $script:AclCalls.Count-$aclFrom -eq 2) 'KEEP content preserved after exactly one repair'
    $script:Fault=$null; Remove-CleanupDirectoryBottomUp $inspectionKeep; Set-TestLedger @()
    # Missing repositories are normal stale ownership records, not resolution errors.
    $missingRepo=Join-Path $script:TestRoot 'deleted-repo'; $absent=Join-Path $parent 'absent'
    $missingRow=New-TestRow $absent '' 'missing'; $missingRow.teardown_main_repo=$missingRepo; Set-TestLedger @($missingRow)
    $saved=Get-TestGitEnvironment
    try {
        Restore-TestGitEnvironment @{GIT_CONFIG_NOSYSTEM='1';GIT_CONFIG_GLOBAL=$script:Config;GIT_NO_LAZY_FETCH='1';GIT_OPTIONAL_LOCKS='0'}
        $inventory=Get-TestInventory; Set-CleanupProof $inventory.Items[$absent] $inventory
        Assert-Test ($inventory.Items[$absent].Verdict -eq 'GONE') 'missing repository absent item GONE'
        [void][IO.Directory]::CreateDirectory($absent)
        Clear-TestGitReplies
        $inventory=Get-TestInventory; Set-CleanupProof $inventory.Items[$absent] $inventory
        Assert-Test ($inventory.Items[$absent].Reason -eq 'unknown owner (repository missing)') 'missing repository surviving item KEEP'
    } finally { Restore-TestGitEnvironment $saved }
    Remove-CleanupDirectoryBottomUp $absent; Set-TestLedger @()

    # Worktree prune failures and rollback use real fixture metadata and in-process faults.
    $script:Worktree=Join-Path $parent 'rollback'
    [void](Test-Git @('-C',$script:Repo,'worktree','add','-b','codex/rollback',$script:Worktree,$script:MainHead))
    Set-TestLedger @((New-TestRow $script:Worktree 'codex/rollback'))
    $script:Fault={param($kind,$value) if ($kind -eq 'git' -and $value -contains 'prune' -and $value -notcontains '--dry-run') { return [pscustomobject]@{Code=0;Text='';Error=''} }}
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 1 -and (Test-CleanupExists $script:Worktree)) ('persisting registration rolls directory back: '+$script:LastText)
    Assert-Test ($script:LastText -like '*FAILED worktree*persists after prune*') 'rollback result FAILED'
    $script:RetainedBeforeFailed=$null; $mutationsFrom=$script:Mutations.Count
    $script:Fault={param($kind,$value)
        if ($kind -eq 'git' -and $value -contains 'prune' -and $value -notcontains '--dry-run') { return [pscustomobject]@{Code=0;Text='';Error=''} }
        if ($kind -eq 'mutation' -and $value[0] -eq 'rename' -and $value[1].Contains('.apex-cleanup-quarantine-') -and (Test-CleanupEqual $value[2] $script:Worktree)) { $script:RetainedBeforeFailed=$value[1]; throw 'fixture rollback denied' }
        if ($kind -eq 'journal' -and $value.action -eq 'failed-rollback') { throw 'fixture failed journal denied' }
    }
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 1) 'failed-rollback journal append failure exit one'
    Assert-TestReportItem $script:Worktree 'KEEP' 'fixture failed journal denied'
    Assert-Test (@($script:LastText -split "`n" | Where-Object { $_.StartsWith('ERROR ') }).Count -eq 1) 'rollback failure records exactly one final error'
    Assert-Test (Test-CleanupExists $script:RetainedBeforeFailed) 'journal failure retains current quarantine'
    Assert-Test (@($script:Mutations | Select-Object -Skip $mutationsFrom | Where-Object { $_.Destination -like '*.apex-cleanup-failed-*' }).Count -eq 0) 'failed journal prevents failed-name rename'
    Assert-Test ((Test-Git @('-C',$script:Repo,'rev-parse','refs/heads/codex/rollback')) -ceq $script:MainHead) 'journal failure preserves branch'
    $script:Fault=$null; [IO.Directory]::Move($script:RetainedBeforeFailed,$script:Worktree); Clear-TestGitReplies
    foreach ($sibling in @($false,$true)) {
        if ($sibling) {
            $newPath=Join-Path $script:TestRoot ([IO.Path]::GetFileName($script:Repo)+'-wt-rollback')
            [void](Test-Git @('-C',$script:Repo,'worktree','move',$script:Worktree,$newPath)); $script:Worktree=$newPath
            Set-TestLedger @((New-TestRow $script:Worktree 'codex/rollback'))
        }
        $script:Fault={param($kind,$value)
            if ($kind -eq 'git' -and $value -contains 'prune' -and $value -notcontains '--dry-run') { return [pscustomobject]@{Code=$(if ($sibling) {128} else {0});Text='';Error='fixture prune denied'} }
            if ($kind -eq 'mutation' -and $value[0] -eq 'rename' -and $value[1] -like '*.apex-cleanup-quarantine-*' -and (Test-CleanupEqual $value[2] $script:Worktree)) { throw 'fixture S3 rollback denied' }
        }
        Assert-Test ((Invoke-TestCleanup -Apply) -eq 1 -and $script:LastText -like '*FAILED worktree*rollback failed*retained*apex-cleanup-failed*') 'failed rollback retained under failed name'
        Assert-Test (@($script:LastText -split "`n" | Where-Object { $_.StartsWith('ERROR ') }).Count -eq 1) 'rollback failure records exactly one final error'
        $script:Fault=$null
        $lines=@([IO.File]::ReadAllLines($journal) | Where-Object { $_ -notlike '{malformed*' } | ForEach-Object { $_ | ConvertFrom-Json })
        $failed=@($lines | Where-Object { $_.action -eq 'failed-rollback' })[-1]
        Assert-Test ($failed.previous_quarantine_path -like '*.apex-cleanup-quarantine-*' -and $failed.quarantine_path -like '*.apex-cleanup-failed-*' -and (Test-CleanupEqual $failed.original_path $script:Worktree)) 'failed rollback journal exact attribution'
        Assert-Test ((Invoke-TestCleanup) -eq 0 -and $script:LastText -like '*failed rollback: needs owner y/n; since*') 'next list recognizes failed origin with a clean journal'
        # Restore the fixture explicitly, outside production, to test the sibling form too.
        [IO.Directory]::Move($failed.quarantine_path,$script:Worktree); Clear-TestGitReplies
    }
    $script:Fault=$null
    [void](Test-Git @('-C',$script:Repo,'worktree','remove','--force',$script:Worktree))
    [void](Test-Git @('-C',$script:Repo,'branch','-D','codex/rollback'))
    Set-TestLedger @()

    $missingOne=Join-Path $parent 'missing-one'; $missingTwo=Join-Path $parent 'missing-two'
    foreach ($pair in @(@($missingOne,'codex/missing-one'),@($missingTwo,'codex/missing-two'))) {
        [void](Test-Git @('-C',$script:Repo,'worktree','add','-b',$pair[1],$pair[0],$script:MainHead))
    }
    Write-TestFile (Join-Path $missingOne 'file.txt') 'retained staged content'
    [void](Test-Git @('-C',$missingOne,'add','file.txt'))
    foreach ($p in @($missingOne,$missingTwo)) { Remove-CleanupDirectoryBottomUp $p }
    Set-TestLedger @((New-TestRow $missingOne 'codex/missing-one'),(New-TestRow $missingTwo 'codex/missing-two'))
    $script:Worktree=$missingOne
    [void](Test-WorktreeProof 'KEEP' 'staged content in missing worktree index')
    $script:Fault={param($kind,$value) if ($kind -eq 'git' -and $value -contains 'diff-index') { return [pscustomobject]@{Code=128;Text='';Error='fixture diff-index error'} }}
    [void](Test-WorktreeProof 'KEEP' 'fixture diff-index error')
    Assert-Test ((Invoke-TestCleanup) -eq 1) 'diff-index command error exact exit one'
    Assert-TestReportItem $missingOne 'KEEP' 'fixture diff-index error'
    $script:Fault=$null
    [void](Test-Git @((('--git-dir='+(Join-Path $script:Repo '.git/worktrees/missing-one'))),'read-tree','HEAD'))
    [void](Test-WorktreeProof 'SAFE' '')
    $detachedMissing=Join-Path $parent 'missing-detached'
    [void](Test-Git @('-C',$script:Repo,'worktree','add','--detach',$detachedMissing,$unique))
    Remove-CleanupDirectoryBottomUp $detachedMissing
    Set-TestLedger @((New-TestObligation $detachedMissing '(detached)'))
    $script:Worktree=$detachedMissing
    [void](Test-WorktreeProof 'KEEP' ('unique detached commit '+$unique))
    [void](Test-Git @('-C',$script:Repo,'branch','retained/missing-detached',$unique))
    [void](Test-WorktreeProof 'SAFE' '')
    [void](Test-Git @('-C',$script:Repo,'branch','-D','retained/missing-detached'))
    # Include the now-proven detached registration in the grouped prune below.
    [void](Test-Git @((('--git-dir='+(Join-Path $script:Repo '.git/worktrees/missing-detached'))),'update-ref','HEAD',$script:MainHead))
    [void](Test-Git @((('--git-dir='+(Join-Path $script:Repo '.git/worktrees/missing-detached'))),'read-tree',$script:MainHead))
    Set-TestLedger @((New-TestRow $missingOne 'codex/missing-one'),(New-TestRow $missingTwo 'codex/missing-two'),(New-TestObligation $detachedMissing '(detached)'))
    $script:Worktree=$missingOne
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 0) 'proven missing registrations pruned without independent errors'
    Assert-Test ($script:LastText -like '*DETACH GROUP prune registrations*missing-one*missing-two*' -or $script:LastText -like '*DETACH GROUP prune registrations*missing-two*missing-one*') ('both missing registrations in one detach group: '+$script:LastText)
    $registered=Test-Git @('-C',$script:Repo,'worktree','list','--porcelain')
    Assert-Test ($registered -notlike '*missing-one*' -and $registered -notlike '*missing-two*') 'whole proven group pruned'
    $script:Worktree=Join-Path $parent 'unproven-prune'
    $unknown=Join-Path $parent 'unknown-prune'
    [void](Test-Git @('-C',$script:Repo,'worktree','add','-b','codex/proven',$script:Worktree,$script:MainHead))
    [void](Test-Git @('-C',$script:Repo,'worktree','add','-b','codex/unknown',$unknown,$script:MainHead))
    Remove-CleanupDirectoryBottomUp $unknown
    Set-TestLedger @((New-TestRow $script:Worktree 'codex/proven'))
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 0 -and (Test-CleanupExists $script:Worktree)) 'unproven prune registration retains/rolls back proven item'
    Assert-Test ($script:LastText -like '*KEEP worktree*prune would affect unproven registration*unknown-prune*') 'unproven registration named'
    $script:RetainedBeforeFailed=$null
    $script:Fault={param($kind,$value)
        if ($kind -eq 'mutation' -and $value[0] -eq 'rename' -and $value[1].Contains('.apex-cleanup-quarantine-') -and (Test-CleanupEqual $value[2] $script:Worktree)) { $script:RetainedBeforeFailed=$value[1]; throw 'fixture policy rollback denied' }
        if ($kind -eq 'journal' -and $value.action -eq 'failed-rollback') { throw 'fixture policy failed journal denied' }
    }
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 1) 'prune-unproven rollback journal failure exits one'
    Assert-TestReportItem $script:Worktree 'KEEP' 'fixture policy failed journal denied'
    Assert-Test (@($script:LastText -split "`n" | Where-Object { $_.StartsWith('ERROR ') }).Count -eq 1) 'rollback failure records exactly one final error'
    Assert-Test ($script:LastText -like '*ERROR *fixture policy failed journal denied*') 'policy rollback journal error reaches run errors'
    Assert-Test (Test-CleanupExists $script:RetainedBeforeFailed) 'policy journal failure retains quarantine'
    $script:Fault=$null; [IO.Directory]::Move($script:RetainedBeforeFailed,$script:Worktree); Clear-TestGitReplies
    Set-TestLedger @()
    [void](Test-Git @('-C',$script:Repo,'worktree','remove','--force',$script:Worktree))
    [void](Test-Git @('-C',$script:Repo,'worktree','prune','--expire','now'))

    Write-TestStage 'cleanup: adversarial boundary, owner and failure proofs'
    Write-TestFile $journal ''
    [void](Test-Git @('-C',$script:PolicyRepo,'branch','-D','codex/proven','codex/unknown'))
    $script:Repo=$script:PolicyRepo
    # Real writer shapes, including a teardown reservation without teardown fields.
    $probe=Join-Path $parent 'lease-probe'; [void][IO.Directory]::CreateDirectory($probe)
    $script:Worktree=$probe
    $obligation=New-TestObligation $probe ''; $lease=New-TestTeardownLease $probe
    Set-TestLedger @($obligation,$lease)
    [void](Test-WorktreeProof 'KEEP' 'live teardown_lease run teardown')
    $before=Get-TestSnapshot
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 2 -and (Get-TestSnapshot) -ceq $before -and $script:LastText.Contains('live teardown_lease run teardown')) 'teardown reservation machine guard, no report/mutation'
    Set-TestLedger @($obligation,$lease,(New-TestClose 'other'))
    [void](Test-WorktreeProof 'KEEP' 'live teardown_lease')
    $terminal=New-TestRow '' '' 'teardown'; Set-TestLedger @($obligation,$lease,$terminal)
    [void](Test-WorktreeProof 'KEEP' 'live teardown_lease')
    Set-TestLedger @($obligation,$lease,(New-TestClose 'teardown'))
    [void](Test-WorktreeProof 'KEEP' 'live teardown_lease')
    Set-TestLedger @($obligation,(New-TestClose 'teardown'),$lease)
    Assert-Test ((Invoke-TestCleanup) -eq 0) 'refused-preflight then teardown reservation list exit zero'
    Assert-TestReportItem $probe 'KEEP' 'live teardown_lease'
    $before=Get-TestSnapshot
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 2 -and (Get-TestSnapshot) -ceq $before) 'refused-preflight cannot close later reservation: machine guard before mutation/report'
    $lease.status='closed'; Set-TestLedger @($obligation,$lease)
    [void](Test-WorktreeProof 'SAFE' '')
    Set-TestLedger @($obligation); [void](Test-WorktreeProof 'SAFE' '')
    $lease.status='reserved'; $script:Identities[901001]=[pscustomobject]@{Exists=$false;Start=$null}
    Set-TestLedger @($obligation,$lease); [void](Test-WorktreeProof 'SAFE' '')
    $script:Identities[901001]=[pscustomobject]@{Exists=$true;Start='2020-01-01T00:00:00Z'}
    $lease.pid_start='2019-01-01T00:00:00Z'; Set-TestLedger @($obligation,$lease)
    [void](Test-WorktreeProof 'SAFE' '')
    $lease.pid_start=$null; Set-TestLedger @($obligation,$lease)
    [void](Test-WorktreeProof 'KEEP' 'unresolved process identity')
    Set-TestLedger @($obligation,$lease,(New-TestClose 'teardown')); [void](Test-WorktreeProof 'KEEP' 'unresolved process identity')
    foreach ($identity in @('missing-pid','launcher-only','no-identity')) {
        $incomplete=New-TestTeardownLease $probe
        $incomplete.PSObject.Properties.Remove('pid')
        if ($identity -ne 'missing-pid') { $incomplete.PSObject.Properties.Remove('pid_start') }
        if ($identity -eq 'launcher-only') {
            $incomplete | Add-Member launcher_pid 901001
            $incomplete | Add-Member launcher_start '2020-01-01T00:00:00Z'
        }
        Set-TestLedger @($obligation,$incomplete,(New-TestClose 'teardown'))
        [void](Test-WorktreeProof 'KEEP' 'unresolved process identity')
        $unrelated=Join-Path $parent 'teardown-independent'; [void][IO.Directory]::CreateDirectory($unrelated)
        Set-TestLedger @($obligation,$incomplete,(New-TestObligation $unrelated '' 'independent'))
        Assert-Test ((Invoke-TestCleanup -Apply) -eq 0 -and (Test-CleanupExists $probe) -and -not (Test-CleanupExists $unrelated)) ('unresolved teardown identity keeps named item and allows unrelated SAFE Apply: '+$identity)
        Assert-TestReportItem $probe 'KEEP' 'unresolved process identity'
        Assert-Test ($script:LastText -notlike '*STOP*') ('incomplete teardown identity never trips guard: '+$identity)
    }
    Set-TestLedger @(); Remove-CleanupDirectoryBottomUp $probe

    # Legacy unresolved users are item policy, not a machine-wide live-user trip.
    $legacy=New-TestRow $probe '' 'legacy'; $legacy.pid_start=$null; $legacy.launcher_pid=$null; $legacy.status='running'
    $independent=Join-Path $parent 'legacy-independent'
    foreach ($p in @($probe,$independent)) { [void][IO.Directory]::CreateDirectory($p) }
    Set-TestLedger @($legacy,(New-TestObligation $independent '' 'independent'))
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 0 -and (Test-CleanupExists $probe) -and -not (Test-CleanupExists $independent)) 'legacy KEEP allows unrelated SAFE Apply with exit zero'
    Assert-TestReportItem $probe 'KEEP' 'unresolved process identity'
    Assert-Test ($script:LastText -notlike '*STOP*') 'legacy unresolved row never trips guard'
    Set-TestLedger @(); Remove-CleanupDirectoryBottomUp $probe

    # Normalized identity de-duplicates recorded case variants.
    [void][IO.Directory]::CreateDirectory($probe)
    Set-TestLedger @((New-TestObligation $probe '' 'lower'),(New-TestObligation $probe.ToUpperInvariant() '' 'upper'))
    $c=Get-TestProofInventory
    Assert-Test (@($c.Items.Values | Where-Object { Test-CleanupEqual $_.Path $probe }).Count -eq 1 -and $c.Items[$probe].Sources.Count -eq 2) 'case-variant item has both referring sources'
    Assert-TestItem $c $probe 'SAFE' 'boundary and retained-content proof passed'
    Set-TestLedger @(); Remove-CleanupDirectoryBottomUp $probe

    $outside=Join-Path $script:TestRoot 'outside-parent'; [void][IO.Directory]::CreateDirectory($outside)
    Set-TestLedger @((New-TestObligation $outside ''))
    Assert-TestItem (Get-TestProofInventory) $outside 'KEEP' ('outside eligible parent/name boundary '+$outside)
    Set-TestLedger @((New-TestObligation $script:Repo ''))
    Assert-TestItem (Get-TestProofInventory) $script:Repo 'KEEP' ('protected root '+$script:Repo)
    $protectedParent=Join-Path $script:TestRoot 'protected-wt'; $protectedState=Join-Path $protectedParent 'state'
    [void][IO.Directory]::CreateDirectory($protectedState)
    Set-TestLedger @((New-TestObligation $protectedParent ''))
    Assert-Test ((Invoke-TestCleanup -Roots @($script:State,$protectedState)) -eq 0) 'protected ancestor list exit zero'
    Assert-TestReportItem $protectedParent 'KEEP' ('protected root '+$protectedState)
    Set-TestLedger @(); Remove-CleanupDirectoryBottomUp $outside; Remove-CleanupDirectoryBottomUp $protectedParent

    foreach ($cache in @('node_modules','.codex-scratch')) {
        $outer=Join-Path $parent ('outer-'+$cache.TrimStart('.')); $inner=Join-Path $outer ($cache+'/inner')
        Write-TestFile (Join-Path $inner 'unique') 'keep nested owner'
        Set-TestLedger @((New-TestObligation $outer '' 'outer'),(New-TestObligation $inner '' 'inner'))
        $c=Get-TestProofInventory
        Assert-TestItem $c $outer 'KEEP' ('contains repository or kept item '+$inner)
        Assert-TestItem $c $inner 'KEEP' ('outside eligible parent/name boundary '+$inner)
        Assert-Test ((Invoke-TestCleanup -Apply) -eq 0 -and (Test-CleanupExists $inner)) ('nested KEEP protected in '+$cache)
        Assert-TestReportItem $outer 'KEEP' $inner
        Set-TestLedger @(); Remove-CleanupDirectoryBottomUp $outer
    }
    # Both containment discoveries occur after the initial SAFE listing/proof.
    foreach ($race in @('record','git')) {
        [void][IO.Directory]::CreateDirectory($probe); Set-TestLedger @((New-TestObligation $probe ''))
        $script:Hook={param($phase,$item) if ($phase -eq 'after-lock') {
            if ($race -eq 'record') {
                $new=New-TestObligation (Join-Path $probe 'node_modules/new-owner') '' 'new-owner'
                [IO.File]::AppendAllText($script:Ledger,(($new|ConvertTo-Json -Compress)+"`n"))
            } else { Write-TestFile (Join-Path $probe 'node_modules/new/.git/config') 'new repository' }
        }}
        Assert-Test ((Invoke-TestCleanup -Apply) -eq 0 -and (Test-CleanupExists $probe)) ('locked containment race '+$race)
        Assert-TestReportItem $probe 'KEEP' 'contains repository or kept item'
        $script:Hook=$null; Set-TestLedger @(); Remove-CleanupDirectoryBottomUp $probe
    }
    # Top-level .git directory is a nested repository even on a recorded orphan.
    Write-TestFile (Join-Path $probe '.git/config') 'orphan repository'; Set-TestLedger @((New-TestObligation $probe ''))
    Assert-TestItem (Get-TestProofInventory) $probe 'KEEP' ('contains repository or kept item '+(Join-Path $probe '.git'))
    Set-TestLedger @(); Remove-CleanupDirectoryBottomUp $probe

    $oldContainer=Join-Path $script:Temp 'engine-test-keep-container'; $inner=Join-Path $oldContainer 'nested-wt/keep'
    Write-TestFile (Join-Path $inner 'unique') 'retained'; [IO.Directory]::SetLastWriteTimeUtc($oldContainer,[datetime]::UtcNow.AddDays(-3))
    Set-TestLedger @((New-TestObligation $inner ''))
    $c=Get-TestProofInventory
    Assert-TestItem $c $inner 'KEEP' 'non-disposable entry'
    Assert-TestItem $c $oldContainer 'KEEP' ('contains repository or kept item '+$inner)
    Set-TestLedger @(); Remove-CleanupDirectoryBottomUp $oldContainer

    # Git-only paths, refs, and filesystem-only history never acquire ownership.
    $unknown=Join-Path $parent 'unknown-owner'
    [void](Test-Git @('-C',$script:Repo,'worktree','add','-b','codex/unknown-owner',$unknown,$script:MainHead))
    $unknownRun=Join-Path $script:State ('b'*32); [void][IO.Directory]::CreateDirectory($unknownRun)
    Set-TestLedger @((New-TestObligation '' '' 'repo-only'))
    foreach ($form in @($unknown,$unknown.Replace('\','/'))) {
        $scope=Join-Path $script:Temp ('apex-scope-'+(Get-CleanupScopeTag $form)); [void][IO.Directory]::CreateDirectory($scope)
        $c=Get-TestProofInventory
        Assert-TestItem $c $unknown 'KEEP' 'unknown owner'
        Assert-TestItem $c $scope 'KEEP' ('protected worktree '+$unknown+'; path form ')
        Remove-CleanupDirectoryBottomUp $scope
    }
    $c=Get-TestProofInventory
    $unknownBranch=@($c.Items.Values | Where-Object { $_.Class -eq 'branch' -and $_.Path -ceq 'refs/heads/codex/unknown-owner' })[0]
    Assert-Test ($unknownBranch.Verdict -eq 'KEEP' -and $unknownBranch.Reason -eq 'unknown owner') 'Git-only branch KEEP unknown owner'
    Assert-TestItem $c $unknownRun 'KEEP' 'unknown owner'
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 0 -and (Test-CleanupExists $unknown) -and (Test-CleanupExists $unknownRun)) 'unrecorded Git and filesystem items untouched'
    Assert-TestReportItem $unknown 'KEEP' 'unknown owner'; Assert-TestReportItem $unknownRun 'KEEP' 'unknown owner'
    # A recorded KEEP worktree also protects its branch and scope in both aliases.
    Set-TestLedger @((New-TestObligation $unknown 'codex/unknown-owner'))
    Write-TestFile (Join-Path $unknown 'unique') 'unique'
    foreach ($form in @($unknown,$unknown.Replace('\','/'))) {
        $scope=Join-Path $script:Temp ('apex-scope-'+(Get-CleanupScopeTag $form)); [void][IO.Directory]::CreateDirectory($scope)
        $c=Get-TestProofInventory; Assert-TestItem $c $scope 'KEEP' ('protected worktree '+$unknown)
        Assert-Test ($c.Items[$unknown].Aliases.Contains($unknown) -and $c.Items[$unknown].Aliases.Contains($unknown.Replace('\','/'))) 'scope protection sees recorded and Git-registered path forms'
        Set-CleanupVerdict $c.Items[$unknown] 'GONE' 'test reproof transition'
        Assert-Test (-not (Get-CleanupProtectedScopes $c).ContainsKey([IO.Path]::GetFileName($scope))) 'GONE reproof invalidates protected tags'
        Set-CleanupDetachProof $c.Items[$scope] $c
        Assert-TestItem $c $scope 'KEEP' ('protected worktree '+$unknown+'; path form '+$c.Items[$unknown].Aliases[0])
        Assert-Test ($c.Items[$unknown].Verdict -eq 'KEEP') 'detach reproof rebuilds protection for recorded and registered forms'
        Set-CleanupRemoved $c.Items[$unknown]
        Assert-Test (-not (Get-CleanupProtectedScopes $c).ContainsKey([IO.Path]::GetFileName($scope))) 'Removed invalidates protected tags'
        $c.Items[$unknown].Removed=$false; Set-CleanupVerdict $c.Items[$unknown] 'KEEP' 'restored fixture'
        Assert-Test (@($c.Items.Values | Where-Object { $_.Class -eq 'branch' -and $_.Path -ceq 'refs/heads/codex/unknown-owner' -and $_.Verdict -eq 'KEEP' -and $_.Reason.Contains('KEEP worktree '+$unknown) }).Count -eq 1) 'branch checked out by KEEP worktree retained'
        Remove-CleanupDirectoryBottomUp $scope
    }
    Set-TestLedger @(); [void](Test-Git @('-C',$script:Repo,'worktree','remove','--force',$unknown)); Remove-CleanupDirectoryBottomUp $unknownRun

    $runState=New-TestState; $sp=Save-TestState $runState
    Assert-TestItem (Get-TestProofInventory) ([IO.Path]::GetDirectoryName($sp)) 'KEEP' 'younger than 14 days'
    $runState.integration.tip=$script:UniqueContentHead; [void](Save-TestState $runState -Old)
    Assert-TestItem (Get-TestProofInventory) ([IO.Path]::GetDirectoryName($sp)) 'KEEP' ('non-integrated tip '+$script:UniqueContentHead)
    # A held file denies the real state reader; unrelated SAFE item must remain.
    [void][IO.Directory]::CreateDirectory($probe); Set-TestLedger @((New-TestObligation $probe ''))
    $stream=New-Object IO.FileStream($sp,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        Assert-Test ((Invoke-TestCleanup -Apply) -eq 1 -and (Test-CleanupExists $probe)) 'unreadable engine-state suppresses mutations'
        Assert-Test ($script:LastText.Contains('engine-state '+$sp)) 'unreadable engine-state names exact source'
    } finally { $stream.Dispose() }
    Remove-CleanupDirectoryBottomUp ([IO.Path]::GetDirectoryName($sp)); Remove-CleanupDirectoryBottomUp $probe; Set-TestLedger @()

    # Junctions are real links within the fixture, including ancestor refusal.
    $linkTarget=Join-Path $script:TestRoot 'adversarial-link-target'; Write-TestFile (Join-Path $linkTarget 'keep') 'target bytes'
    $targetBefore=Get-TestSnapshot $linkTarget
    foreach ($cache in @('elsewhere','node_modules')) {
        [void][IO.Directory]::CreateDirectory($probe); $link=Join-Path $probe ($cache+'/link'); [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($link))
        [void](New-Item -ItemType Junction -Path $link -Target $linkTarget)
        Set-TestLedger @((New-TestObligation $probe ''))
        Assert-Test ((Invoke-TestCleanup -Apply) -eq 0) ('junction Apply exit '+$cache)
        if ($cache -eq 'elsewhere') { Assert-TestReportItem $probe 'KEEP' ('reparse point '+$link); Assert-Test (Test-CleanupExists $link) 'non-cache link remains' }
        else { Assert-TestReportItem $probe 'SAFE' 'quarantined and removed'; Assert-Test (-not (Test-CleanupExists $probe)) 'disposable link removed with item boundary active' }
        Assert-Test ((Get-TestSnapshot $linkTarget) -ceq $targetBefore) 'Apply link target bytes and metadata unchanged'
        Set-TestLedger @(); if (Test-CleanupExists $probe) { Remove-CleanupDirectoryBottomUp $probe }
    }
    $linkParent=Join-Path $script:TestRoot 'ancestor-wt'; [void](New-Item -ItemType Junction -Path $linkParent -Target $linkTarget)
    $through=Join-Path $linkParent 'child'; [void][IO.Directory]::CreateDirectory($through)
    Set-TestLedger @((New-TestObligation $through ''))
    Assert-TestItem (Get-TestProofInventory) $through 'KEEP' ('reparse point '+$linkParent)
    Set-TestLedger @(); [IO.Directory]::Delete($linkParent,$false)

    # Owner refusal values and both top-level and ancestor reparse links.
    foreach ($invalid in @($script:State,$script:Temp,$script:TestRoot,(Join-Path $script:Temp 'missing-value'))) {
        Assert-Test ((Invoke-TestCleanup -Apply -Names @($invalid)) -eq 1) ('owner invalid value exit '+$invalid)
        Assert-TestReportItem $invalid 'KEEP' 'not an inventoried quarantine'
    }
    $q=Join-Path $script:Temp ('.apex-cleanup-quarantine-20200101T000000Z-'+[guid]::NewGuid())
    [void](New-Item -ItemType Junction -Path $q -Target $linkTarget); $before=Get-TestSnapshot $linkTarget
    Assert-Test ((Invoke-TestCleanup -Apply -Names @($q)) -eq 1 -and (Test-CleanupExists $q)) 'owner top reparse refused'
    Assert-TestReportItem $q 'KEEP' ('reparse point '+$q)
    Assert-Test ((Get-TestSnapshot $linkTarget) -ceq $before) 'owner reparse target unchanged'; [IO.Directory]::Delete($q,$false)
    $q=New-TestQuarantine $linkTarget; [void](New-Item -ItemType Junction -Path $linkParent -Target $linkTarget)
    $through=Join-Path $linkParent ([IO.Path]::GetFileName($q))
    [IO.File]::AppendAllText($journal,((@{quarantine_path=$through}|ConvertTo-Json -Compress)+"`n"))
    $before=Get-TestSnapshot $linkTarget
    Assert-Test ((Invoke-TestCleanup -Apply -Names @($through)) -eq 1) 'owner ancestor reparse refused'
    Assert-TestReportItem $through 'KEEP' ('reparse point '+$linkParent)
    Assert-Test ((Get-TestSnapshot $linkTarget) -ceq $before) 'owner ancestor target unchanged'
    [IO.Directory]::Delete($linkParent,$false); Remove-CleanupDirectoryBottomUp $q

    $q1=New-TestQuarantine; $q2=New-TestQuarantine
    $script:Processes=@([pscustomobject]@{ProcessId=901099;Name='pwsh.exe';CommandLine='apex-engine.ps1'})
    $before=Get-TestSnapshot
    Assert-Test ((Invoke-TestCleanup -Apply -Names @($q1,$q2)) -eq 2 -and (Get-TestSnapshot) -ceq $before) 'owner guard before first removal has no changes/report'
    Assert-Test ($script:LastText.Contains('901099')) 'owner guard refusal names process'
    $script:Processes=@(); $script:Hook={param($phase,$value) if ($phase -eq 'mutation-directory' -and $value -in @($q1,$q2)) { $script:Processes=@([pscustomobject]@{ProcessId=901099;Name='pwsh.exe';CommandLine='apex-engine.ps1'}) }}
    $aclFrom=$script:AclCalls.Count
    Assert-Test ((Invoke-TestCleanup -Apply -Names @($q1,$q2)) -eq 2) 'owner guard between named removals exit two'
    $ordered=@(@($q1,$q2) | Sort-Object)
    Assert-TestReportItem $ordered[0] 'SAFE' 'owner authorized removal completed'
    Assert-TestReportItem $ordered[1] 'KEEP' 'needs owner y/n'
    Assert-Test (-not (Test-CleanupExists $ordered[0]) -and (Test-CleanupExists $ordered[1]) -and $script:AclCalls.Count -eq $aclFrom -and $script:LastText.Contains('901099')) 'owner stops second removal and ACL after trip'
    $script:Hook=$null; $script:Processes=@(); Remove-CleanupDirectoryBottomUp $ordered[1]

    # Inject process quiescence failures at the locked proof, actual detach,
    # and pre-deletion guard points, rather than only at entry.
    foreach ($guardPoint in @(2,3,4)) {
        $guardA=Join-Path $parent 'guard-a'; $guardB=Join-Path $parent 'guard-b'
        foreach ($p in @($guardA,$guardB)) { [void][IO.Directory]::CreateDirectory($p) }
        Set-TestLedger @((New-TestObligation $guardA '' 'guard-a'),(New-TestObligation $guardB '' 'guard-b'))
        $script:GuardVisits=0; $aclFrom=$script:AclCalls.Count
        $script:Fault={param($kind,$value) if ($kind -eq 'processes') {
            $script:GuardVisits++
            if ($script:GuardVisits -eq $guardPoint) { $script:Processes=@([pscustomobject]@{ProcessId=901098;Name='pwsh.exe';CommandLine='apex-cleanup.ps1'}) }
        }}
        $before=Get-TestSnapshot
        Assert-Test ((Invoke-TestCleanup -Apply) -eq 2) ('process guard at point '+$guardPoint)
        Assert-Test ($script:LastText.Contains('901098') -and $script:AclCalls.Count -eq $aclFrom) 'later guard reports process and performs no ACL repair'
        if ($guardPoint -lt 4) { Assert-Test ((Get-TestSnapshot) -ceq $before) 'locked/pre-detach guard has no changes/report' }
        else {
            Assert-TestReportItem $guardA 'SAFE' 'quarantined and removed'
            Assert-Test (-not (Test-CleanupExists $guardA) -and (Test-CleanupExists $guardB)) 'pre-deletion guard finishes only already-detached item'
        }
        $script:Fault=$null; $script:Processes=@(); Set-TestLedger @()
        foreach ($p in @($guardA,$guardB)) { if (Test-CleanupExists $p) { Remove-CleanupDirectoryBottomUp $p } }
    }
    $guardTemp=Join-Path $script:Temp 'engine-test-guard-temp'; Write-TestFile (Join-Path $guardTemp 'cache') 'old temp'
    [IO.Directory]::SetLastWriteTimeUtc($guardTemp,[datetime]::UtcNow.AddDays(-3)); $script:GuardVisits=0
    $script:Fault={param($kind,$value) if ($kind -eq 'processes') {
        $script:GuardVisits++; if ($script:GuardVisits -eq 4) { $script:Processes=@([pscustomobject]@{ProcessId=901098;Name='pwsh.exe';CommandLine='apex-cleanup.ps1'}) }
    }}
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 2) 'process guard immediately before temp deletion'
    Assert-TestReportItem $guardTemp 'SAFE' 'quarantined and removed'
    Assert-Test (-not (Test-CleanupExists $guardTemp) -and $script:LastText.Contains('901098')) 'temp quarantine completion reports trip'
    $script:Fault=$null; $script:Processes=@()

    # Owner ACL repair and continued deletion denial use the actual walker.
    foreach ($continued in @($false,$true)) {
        $q=New-TestQuarantine; $script:DenyCount=0; $aclFrom=$script:AclCalls.Count
        $script:Fault={param($kind,$value) if ($kind -eq 'mutation' -and $value[0] -eq 'file' -and (Test-CleanupUnder $value[1] $q) -and ($continued -or $script:DenyCount -eq 0)) { $script:DenyCount++; throw (New-Object UnauthorizedAccessException('owner deletion denied')) }}
        $expected=if ($continued) {1} else {0}
        Assert-Test ((Invoke-TestCleanup -Apply -Names @($q)) -eq $expected) ('owner ACL exact result '+$continued)
        Assert-TestReportItem $q $(if ($continued) {'FAILED'} else {'SAFE'}) $(if ($continued) {'owner deletion denied'} else {'owner authorized removal completed'})
        Assert-Test ($script:AclCalls.Count-$aclFrom -eq 2) 'owner denial one non-recursive repair pair'
        $script:Fault=$null; if (Test-CleanupExists $q) { Remove-CleanupDirectoryBottomUp $q }
    }
    $q=New-TestQuarantine
    $script:Fault={param($kind,$value) if ($kind -eq 'journal' -and $value.action -eq 'removed') { throw 'fixture owner journal denied' }}
    Assert-Test ((Invoke-TestCleanup -Apply -Names @($q)) -eq 1 -and -not (Test-CleanupExists $q)) 'owner completed deletion with journal failure exits one'
    Assert-TestReportItem $q 'SAFE' 'owner authorized removal completed'
    Assert-Test ($script:LastText.Contains('removed journal append error: fixture owner journal denied')) 'owner journal failure reason reported'
    $script:Fault=$null
    # Ordinary inspection denial remains KEEP, while independent SAFE is applied.
    foreach ($p in @($probe,$independent)) { [void][IO.Directory]::CreateDirectory($p) }
    Set-TestLedger @((New-TestObligation $probe ''),(New-TestObligation $independent '' 'independent'))
    $aclFrom=$script:AclCalls.Count
    $script:Fault={param($kind,$value) if ($kind -eq 'enumerate' -and (Test-CleanupEqual $value $probe)) { throw (New-Object UnauthorizedAccessException('continued inspection denied')) }}
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 1 -and -not (Test-CleanupExists $independent)) 'continued inspection denial does not veto independent deletion'
    Assert-TestReportItem $probe 'KEEP' 'continued inspection denied'
    Assert-Test ($script:AclCalls.Count-$aclFrom -eq 2) 'continued inspection only one repair attempt'
    $script:Fault=$null; Set-TestLedger @(); Remove-CleanupDirectoryBottomUp $probe
    foreach ($trip in @($false,$true)) {
        Write-TestFile (Join-Path $probe 'node_modules/file') 'cache'; Set-TestLedger @((New-TestObligation $probe ''))
        $aclFrom=$script:AclCalls.Count
        $script:Hook={param($phase,$item) if ($phase -eq 'after-detach' -and $trip) { $script:Processes=@([pscustomobject]@{ProcessId=901099;Name='pwsh.exe';CommandLine='apex-engine.ps1'}) }}
        $script:Fault={param($kind,$value) if ($kind -eq 'mutation' -and $value[0] -eq 'file' -and $value[1].Contains('.apex-cleanup-quarantine-')) { throw (New-Object UnauthorizedAccessException('continued deletion denied')) }}
        Assert-Test ((Invoke-TestCleanup -Apply) -eq $(if ($trip) {2} else {1})) ('continued deletion exact exit, trip='+$trip)
        Assert-TestReportItem $probe 'FAILED' $(if ($trip) {'ACL repair unavailable'} else {'continued deletion denied'})
        Assert-Test ($script:AclCalls.Count-$aclFrom -eq $(if ($trip) {0} else {2})) 'completion after trip makes zero ACL calls'
        if ($trip) { Assert-Test ($script:LastText.Contains('901099')) 'failed completion retains trip reason' }
        $script:Fault=$null; $script:Hook=$null; $script:Processes=@(); Set-TestLedger @()
    }

    # A newly inserted non-cache link must be seen before an ACL retry.
    Write-TestFile (Join-Path $probe 'node_modules/file') 'cache'; Set-TestLedger @((New-TestObligation $probe ''))
    $aclFrom=$script:AclCalls.Count; $script:RetryLink=$null
    $script:Fault={param($kind,$value) if ($kind -eq 'mutation' -and $value[0] -eq 'file' -and $value[1].Contains('.apex-cleanup-quarantine-')) {
        $root=[IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($value[1])); $script:RetryLink=Join-Path $root 'new-link'
        [void](New-Item -ItemType Junction -Path $script:RetryLink -Target $linkTarget)
        throw (New-Object UnauthorizedAccessException('retry with new link'))
    }}
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 0) 'non-cache reparse before retry is policy KEEP'
    Assert-TestReportItem $probe 'KEEP' ('reparse point '+$script:RetryLink)
    Assert-Test ($script:AclCalls.Count -eq $aclFrom) 'new reparse blocks all ACL commands'
    $script:Fault=$null; Set-TestLedger @()

    # Bounded guard cost: 64 files in 32 nested directories, one quarantine acquisition.
    $bulk=Join-Path $parent 'bulk'; for ($n=0;$n -lt 16;$n++) { for ($f=0;$f -lt 4;$f++) { Write-TestFile (Join-Path $bulk ("node_modules/d$n/deeper/f$f")) 'cache' } }
    Set-TestLedger @((New-TestObligation $bulk '')); $processFrom=$script:ProcessCalls; $gitFrom=$script:GitCalls.Count; $eventFrom=$script:LockEvents.Count
    $ledgerBefore=[IO.File]::ReadAllText($script:Ledger)
    Assert-Test ((Invoke-TestCleanup -Apply) -eq 0) 'nested bulk quarantine deletion exit zero'
    Assert-TestReportItem $bulk 'SAFE' 'quarantined and removed'
    Assert-Test ([IO.File]::ReadAllText($script:Ledger) -ceq $ledgerBefore) 'Apply never rewrites writer ledger records'
    Assert-Test ($script:ProcessCalls-$processFrom -le 8) ('process snapshots bounded by guard points: '+($script:ProcessCalls-$processFrom))
    $events=@($script:LockEvents | Select-Object -Skip $eventFrom)
    Assert-Test (@($events | Where-Object { $_.Phase -eq 'proof' -and $_.Held -and $_.Path -eq $bulk }).Count -eq 1) 'locked content proof recorded'
    Assert-Test (@($events | Where-Object { $_.Phase -eq 'rename' -and $_.Held -and $_.Path -eq $bulk }).Count -eq 1) 'detach rename under mutex'
    Assert-Test (@($events | Where-Object { $_.Phase -in @('file','directory','acl') -and $_.Held }).Count -eq 0) 'all deletion and ACL outside mutex'
    foreach ($group in @($script:LockEvents | Where-Object { $_.Phase -eq 'after-detach' -and $_.Held } | Group-Object Acquisition)) { Assert-Test (@($group.Group.Path | Select-Object -Unique).Count -eq 1) 'one named item detached per acquisition' }
    Assert-Test (@($script:LockEvents | Where-Object { $_.Phase -eq 'acl' }).Count -gt 0) 'ACL lock ownership actually recorded'
    Assert-Test ($script:AfterDetachGitChecks -gt 0) 'real production Git calls checked after registered detach'
    $bulkCalls=@($script:GitCalls | Select-Object -Skip $gitFrom)
    Assert-Test (@($bulkCalls | Where-Object { $_.Args -contains $bulk -and ($_.Args -contains 'status' -or $_.Args -contains 'hash-object') }).Count -eq 0) 'orphan quarantine never gets Git content proof after detach'
    Set-TestLedger @()

    $existingReport=Join-Path $script:Reports 'existing-report.txt'; Write-TestFile $existingReport 'preserve'
    Assert-Test ((Invoke-TestCleanup -Apply -Report $existingReport) -eq 1 -and $script:LastText.Contains('report write failed:')) 'report write failure exact exit and reason'
    Assert-Test ([IO.File]::ReadAllText($existingReport) -ceq 'preserve') 'report failure preserves existing path'
    # Sibling-form discovery has neither a journal nor a worktree at its parent.
    Set-TestLedger @((New-TestObligation '' ''))
    $siblingQ=New-TestQuarantine $script:TestRoot 'main-wt-discovery'
    Assert-TestItem (Get-TestProofInventory) $siblingQ 'KEEP' 'interrupted quarantine: needs owner y/n; origin unknown; last write'
    Set-TestLedger @()

    Write-TestStage 'cleanup: temp batches and review regressions'
    Test-CleanupTempBatches
    Test-CleanupReviewRegressions

    Write-TestStage 'cleanup: 36000-entry inventory'
    $now=[datetime]::UtcNow
    $scanWorktree=Join-Path $parent 'prescan'
    [void](Test-Git @('-C',$script:Repo,'worktree','add','-b','codex/prescan',$scanWorktree,$script:MainHead))
    Set-TestLedger @((New-TestObligation $scanWorktree 'codex/prescan'))
    $script:OldPrescan=New-CleanupPathMap; $script:OldVisits=New-CleanupPathMap
    $script:VirtualEntries=@(for ($n=0;$n -lt 36000;$n++) {
        $name=if ($n -lt 4) {'engine-test-old-prescan-'+$n} else {'engine-test-young-'+$n}
        $p=$script:Temp+'\'+$name
        if ($n -lt 4) { [void][IO.Directory]::CreateDirectory($p);[IO.Directory]::SetLastWriteTimeUtc($p,$now.AddDays(-3));$script:OldPrescan[$p]=$true }
        @{Path=$p;Name=$name;Directory=$true;Reparse=$false;Attributes=[IO.FileAttributes]::Directory;LastWriteTimeUtc=$(if ($n -lt 4) {$now.AddDays(-3)} else {$now})}
    })
    $beforeCalls=$script:GitCalls.Count
    $entriesSeam=${function:Get-CleanupEntries}
    function Get-CleanupEntries { param([string]$Path)
        if (Test-CleanupEqual $Path $script:Temp) { return $script:VirtualEntries }
        if ($script:OldPrescan.ContainsKey($Path)) { $script:OldVisits[$Path]=$true }
        & $originalEntries $Path
    }
    try {
        $inventory=Get-TestProofInventory
        Assert-Test (-not @($inventory.Items.Values | Where-Object { $_.Path -like '*engine-test-young-*' }).Count) '36000-entry inventory excludes young temp entries'
        foreach ($p in $script:OldPrescan.Keys) { Assert-TestItem $inventory $p 'SAFE' 'boundary and retained-content proof passed' }
        Assert-Test ($script:OldVisits.Count -eq 4) 'old entries in large inventory all pass through boundary pre-scan'
    }
    finally { ${function:Get-CleanupEntries}=$entriesSeam; $script:VirtualEntries=$null }
    $calls=@($script:GitCalls | Select-Object -Skip $beforeCalls)
    Assert-Test (@($calls | Where-Object { $_.Args -contains 'check-attr' }).Count -eq 1) 'exactly one check-attr per owned worktree, independent of 36000 entries'
    Assert-Test ($calls.Count -lt 35) 'large temp inventory has no Git process per entry'
    foreach ($p in $script:OldPrescan.Keys) { Remove-CleanupDirectoryBottomUp $p }
    Set-TestLedger @(); [void](Test-Git @('-C',$script:Repo,'worktree','remove','--force',$scanWorktree))

    Write-TestStage 'cleanup: indexed cost shape and closure equivalence'
    Test-CleanupCostShape
    foreach ($kind in @('','dispatch','lease','teardown_lease','obligation','LEASE','TEARDOWN_LEASE')) {
        foreach ($status in @('reserved','released')) {
            foreach ($close in @('lease_close','LEASE_CLOSE','leasing','running','stalled','adopting','orphaned','done','Running','','other-id')) {
                $row=[pscustomobject]@{ Data=[pscustomobject]@{ run_id='CaseSensitive'; row_kind=$kind; status=$status } }
                $closing=[pscustomobject]@{ Data=[pscustomobject]@{ run_id=$(if ($close -eq 'other-id') {'casesensitive'} else {'CaseSensitive'}); row_kind=$(if ($close -in @('lease_close','LEASE_CLOSE')) {$close} else {'dispatch'}); status=$close } }
                $context=[pscustomobject]@{ Rows=@($row,$closing) }
                foreach ($legacy in @($false,$true)) {
                    Assert-Test ((Test-CleanupRowClosed $row $context -Legacy:$legacy) -eq (Test-RowClosureReference $row $context -Legacy:$legacy)) ("closure equivalence kind=$kind status=$status close=$close legacy=$legacy")
                }
            }
        }
    }
    $noId=[pscustomobject]@{ Data=[pscustomobject]@{row_kind='teardown_lease';status='released'} }
    Assert-Test (-not (Test-CleanupRowClosed $noId ([pscustomobject]@{Rows=@($noId)}) -Legacy)) 'missing run_id remains open even for released teardown reservation'

    Write-TestStage 'cleanup: branch retention and missing promisor objects'
    $script:Repo=$script:GraphRepo
    foreach ($pair in @(@('codex/ancestor',$script:BaseHead),@('codex/equivalent',$unique),@('codex/unique',$script:UniqueContentHead))) {
        [void](Test-Git @('-C',$script:Repo,'branch',$pair[0],$pair[1]))
    }
    Set-TestLedger @((New-TestRow '' 'codex/ancestor'),(New-TestRow '' 'codex/equivalent'),(New-TestRow '' 'codex/unique'),(New-TestRow '' 'main'))
    [void](Invoke-TestCleanup)
    Assert-Test ($script:LastText -like '*SAFE branch refs/heads/codex/ancestor*' -and $script:LastText -like '*SAFE branch refs/heads/codex/equivalent*') 'ancestor and equivalent non-ancestor branches SAFE'
    Assert-Test ($script:LastText -like '*KEEP branch refs/heads/codex/unique*unique committed path clean.txt*') 'unique branch retained with path'
    Assert-Test ($script:LastText -like '*KEEP branch refs/heads/main*') 'main branch never eligible'
    Set-TestLedger @()
    $sourceRepo=$script:Repo; $partial=Join-Path $script:TestRoot 'partial'
    [void](Test-Git @('-C',$sourceRepo,'config','uploadpack.allowFilter','true'))
    [void](Test-Git @('clone','--single-branch','--branch','main','--filter=blob:none','--no-checkout',('file:///'+$sourceRepo.Replace('\','/')),$partial))
    # A main checkout is needed for ownership resolution, with its index initialized.
    [void](Test-Git @('-C',$partial,'reset','--hard',$script:MainHead))
    # Seed the base blob explicitly: linked-worktree lazy fetching during fixture
    # setup is not consistently supported by all Git for Windows releases.
    $baseBlob=Test-Git @('-C',$sourceRepo,'rev-parse',($script:BaseHead+':file.txt'))
    $blobRelative=$baseBlob.Substring(0,2)+'/'+$baseBlob.Substring(2)
    $blobDestination=Join-Path $partial ('.git/objects/'+$blobRelative)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($blobDestination))
    [IO.File]::Copy((Join-Path $sourceRepo ('.git/objects/'+$blobRelative)),$blobDestination,$true)
    $partialWorktree=Join-Path $parent 'partial'
    [void](Test-Git @('-C',$partial,'worktree','add','-b','codex/partial',$partialWorktree,$script:BaseHead))
    Write-TestFile (Join-Path $partialWorktree 'file.txt') "integrated`n"
    [void](Test-Git @('-C',$partialWorktree,'add','file.txt'))
    $blob=Test-Git @('-C',$sourceRepo,'rev-parse','HEAD:file.txt')
    $loose=Join-Path $partial ('.git/objects/'+$blob.Substring(0,2)+'/'+$blob.Substring(2))
    if (Test-CleanupExists $loose) { [IO.File]::SetAttributes($loose,[IO.FileAttributes]::Normal); $script:FixtureGit.Clear(); [IO.File]::Delete($loose) }
    foreach ($idx in @([IO.Directory]::EnumerateFiles((Join-Path $partial '.git/objects/pack'),'*.idx'))) {
        $objects=Test-Git @('-C',$partial,'verify-pack','-v',$idx)
        if ($objects -match '(?m)^[0-9a-f]+ blob ' -and $objects -notmatch '(?m)^[0-9a-f]+ (commit|tree) ') {
            foreach ($ext in @('.pack','.idx','.promisor','.rev')) { $p=[IO.Path]::ChangeExtension($idx,$ext); if ([IO.File]::Exists($p)) { [IO.File]::SetAttributes($p,[IO.FileAttributes]::Normal); $script:FixtureGit.Clear(); [IO.File]::Delete($p) } }
        }
    }
    $script:Repo=$partial; Set-TestLedger @((New-TestRow $partialWorktree 'codex/partial'))
    $sourceBefore=Get-TestSnapshot $sourceRepo; $objectsBefore=Get-TestSnapshot (Join-Path $partial '.git/objects')
    [void](Invoke-TestCleanup)
    Assert-Test ($script:LastText -like '*KEEP worktree*proof error*') 'missing promisor blob produces proof-error KEEP'
    Assert-Test ((Get-TestSnapshot $sourceRepo) -ceq $sourceBefore -and (Get-TestSnapshot (Join-Path $partial '.git/objects')) -ceq $objectsBefore) 'lazy fetch disabled: source/object directory byte-unchanged'
    $script:Repo=$sourceRepo; Set-TestLedger @()
    Assert-Test ((ConvertTo-CleanupAscii ('name'+[char]0x2603+[char]10)) -ceq 'name\u2603\u000a') 'ASCII escaping preserves printable paths'

    Write-TestStage 'cleanup: real junction/readonly/long-path deletion'
    # Genuine Windows junction, actual walker and deletion adapter, no mutation seam.
    $linkItem=Join-Path $script:TestRoot 'real-links'; $target=Join-Path $script:TestRoot 'link-target'
    Write-TestFile (Join-Path $target 'a') 'target bytes'; Write-TestFile (Join-Path $target 'b') 'other target'
    [void][IO.Directory]::CreateDirectory((Join-Path $linkItem 'node_modules'))
    $link=Join-Path $linkItem 'node_modules/external'
    [void](New-Item -ItemType Junction -Path $link -Target $target)
    $targetBefore=Get-TestSnapshot $target; $aclFrom=$script:AclCalls.Count
    ${function:Invoke-CleanupMutation}=$originalMutation; ${function:Get-CleanupEntries}=$originalEntries
    try {
        Remove-CleanupDirectoryBottomUp $linkItem
        Assert-Test (-not (Test-CleanupExists $linkItem)) 'real walker deletes link-containing fixture'
        Assert-Test ((Get-TestSnapshot $target) -ceq $targetBefore) 'junction target bytes/metadata preserved'
        # Reuse the completed promisor fixture, which has genuine loose Git objects.
        $realRepo=$partial; $looseCount=0
        foreach ($d in @(& $originalEntries (Join-Path $realRepo '.git/objects'))) {
            if ($d.Directory -and $d.Name -match '^[0-9a-f]{2}$') { foreach ($e in @(& $originalEntries $d.Path)) { if (-not $e.Directory) { $looseCount++; [IO.File]::SetAttributes($e.Path,([IO.FileAttributes]::ReadOnly)) } } }
        }
        Assert-Test ($looseCount -gt 0) 'shared real repository contains read-only loose objects'
        Remove-CleanupDirectoryBottomUp $realRepo
        Assert-Test (-not (Test-CleanupExists $realRepo)) 'real walker clears read-only loose objects'
        Assert-Test ($script:AclCalls.Count -eq $aclFrom) 'read-only never triggers ACL'
        $deep=Join-Path $script:TestRoot 'long'; $path=$deep
        for ($n=0;$n -lt 18;$n++) { $path=Join-Path $path 'abcdefghijklmnop' }
        Write-TestFile (Join-Path $path 'end') 'long path'
        Assert-Test ($path.Length -gt 260) 'long-path fixture actually long'
        Remove-CleanupDirectoryBottomUp $deep
        Assert-Test (-not (Test-CleanupExists $deep)) 'real extended-length bottom-up deletion'
    } finally { ${function:Invoke-CleanupMutation}=$originalMutation; ${function:Get-CleanupEntries}=$originalEntries }

    foreach ($file in @($production,$PSCommandPath)) {
        $text=[IO.File]::ReadAllText($file)
        Assert-Test ($text -cnotmatch '[^\x00-\x7f]') 'ASCII-only source'
        $recurseSwitch='-(?:r|re|rec|recu|recur|recurs|recurse)\b'
        $forbiddenDelete='(?im)\b(?:Remove-'+'Item|rm|ri|del|rmdir|rd|erase)\b[^;\r\n]*'+$recurseSwitch+'|\[(?:System\.)?IO\.Directory\]::Delete\([^;\r\n]*,\s*\$'+'true\s*\)|\b(?:rmdir|rd)\b[^;\r\n]*/'+'s\b'
        $forbiddenPrefix='(?i)Invoke-'+'Apex'
        $verbs=@(('Remove-'+'Item'),'rm','ri','del','rmdir','rd','erase')
        foreach ($verb in $verbs) {
            foreach ($switch in @('-r','-re','-Rec','-recu','-recur','-recurs','-Recurse')) {
                Assert-Test (($verb+' fixture '+$switch) -match $forbiddenDelete) 'recursive-switch spelling detected without executing it'
            }
        }
        $recursiveApi='[IO.Directory]::'+'Delete(''fixture'', $'+'true)'
        Assert-Test ($recursiveApi -match $forbiddenDelete) 'recursive Directory API detected'
        foreach ($verb in @('rmdir','rd')) { Assert-Test (($verb+' fixture /'+'s') -match $forbiddenDelete) 'native recursive switch detected' }
        $text=[regex]::Replace($text,'`\r?\n','')
        Assert-Test ($text -notmatch $forbiddenDelete) 'no unsafe recursive deletion literal'
        Assert-Test ($text -notmatch $forbiddenPrefix) 'no blocked prefix'
    }
    Assert-Test ($script:Opened.Count -gt 0 -and @($script:Opened | Where-Object { $_ -cne $script:MutexName -or $_ -ceq 'ApexCodexRunLedger' }).Count -eq 0) 'every opened mutex including worker is unique fixture name'
    Write-Output ('PASS cleanup hermetic suite: '+$script:Assertions+' assertions; '+[math]::Round($clock.Elapsed.TotalSeconds,2)+'s')
} catch {
    Write-Output ('FAIL cleanup hermetic suite: '+$_.Exception.Message)
    Write-Output $_.ScriptStackTrace
    exit 1
} finally {
    $script:CleanupSession=$null; $script:Fault=$null; $script:Hook=$null; $script:ProductionGit=$false
    ${function:Invoke-CleanupMutation}=$originalMutation; ${function:Get-CleanupEntries}=$originalEntries; ${function:Get-CleanupAttributes}=$originalAttributes
    try { if (Test-CleanupExists $script:TestRoot) { Remove-CleanupDirectoryBottomUp $script:TestRoot } }
    finally {
        foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process') }
        Restore-TestGitEnvironment $savedGit
        Assert-TestGitEnvironment $savedGit
    }
}
exit 0
