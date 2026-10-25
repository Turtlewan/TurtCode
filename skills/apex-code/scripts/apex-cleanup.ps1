#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Apply,
    [string[]]$StateRoot = @((Join-Path $env:LOCALAPPDATA 'apex')),
    [string]$LedgerPath,
    [string]$TempRoot = $env:TEMP,
    [ValidateRange(0, [double]::MaxValue)][double]$MinAgeHours = 24,
    [string]$ReportPath,
    [string[]]$RemoveQuarantine
)

$script:CleanupTempBatchSize=500
$script:CleanupTempBatchSeconds=20

# Adapters are functions, deliberately replaceable only inside a dot-sourcing process.
# There are no test switches, environment bypasses, runner imports or index refreshes.
function New-CleanupPathMap { return [Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase) }
function Get-CleanupMonotonicSeconds { return [Diagnostics.Stopwatch]::GetTimestamp()/[double][Diagnostics.Stopwatch]::Frequency }
function ConvertTo-CleanupPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'empty path' }
    $value=$Path.Replace('/', '\')
    if (-not [IO.Path]::IsPathRooted($value)) { $value=Join-Path (Get-Location).ProviderPath $value }
    $p = [IO.Path]::GetFullPath($value)
    if ($p.Length -gt [IO.Path]::GetPathRoot($p).Length) { $p = $p.TrimEnd('\') }
    return $p
}
function Test-CleanupEqual { param([string]$A,[string]$B)
    return [string]::Equals((ConvertTo-CleanupPath $A),(ConvertTo-CleanupPath $B),[StringComparison]::OrdinalIgnoreCase)
}
function Test-CleanupUnder { param([string]$Path,[string]$Parent)
    $p = ConvertTo-CleanupPath $Path; $r = ConvertTo-CleanupPath $Parent
    return $p.StartsWith(($r.TrimEnd('\') + '\'),[StringComparison]::OrdinalIgnoreCase)
}
function ConvertTo-CleanupLiteral { param([string]$Path)
    $p = ConvertTo-CleanupPath $Path
    if ($p.StartsWith('\\?\')) { return $p }
    if ($p.StartsWith('\\')) { return '\\?\UNC\' + $p.Substring(2) }
    return '\\?\' + $p
}
function ConvertTo-CleanupAscii { param([AllowNull()][object]$Text)
    $value=[string]$Text
    if ($value -cnotmatch '[^\x20-\x7e]') { return $value }
    $b = New-Object Text.StringBuilder
    foreach ($ch in $value.ToCharArray()) {
        $n = [int]$ch
        if ($n -ge 32 -and $n -le 126) { [void]$b.Append($ch) }
        else { [void]$b.Append(('\u{0:x4}' -f $n)) }
    }
    return $b.ToString()
}
function ConvertTo-CleanupArgument { param([string]$Value)
    # CommandLineToArgvW quoting, including trailing backslashes.
    return '"' + ([regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')) + '"'
}
function Invoke-CleanupNative {
    param([string]$File,[string[]]$Arguments,[AllowNull()][byte[]]$InputBytes)
    $si = New-Object Diagnostics.ProcessStartInfo
    $si.FileName = $File
    $si.Arguments = (@($Arguments | ForEach-Object { ConvertTo-CleanupArgument $_ }) -join ' ')
    $si.UseShellExecute = $false; $si.CreateNoWindow = $true
    $si.RedirectStandardInput = $true; $si.RedirectStandardOutput = $true; $si.RedirectStandardError = $true
    $p = New-Object Diagnostics.Process; $p.StartInfo = $si
    $buffer = New-Object IO.MemoryStream
    try {
        # .NET Framework creates an AutoFlush stdin writer during Start; its
        # encoding must have no preamble even though we only write raw bytes.
        $stdinEncoding=$null
        try {
            $stdinEncoding=[Console]::InputEncoding
            [Console]::InputEncoding=New-Object Text.UTF8Encoding $false
        } catch { $stdinEncoding=$null } # Console-less hosts may reject encoding access.
        try { [void]$p.Start() }
        finally { if ($null -ne $stdinEncoding) { [Console]::InputEncoding=$stdinEncoding } }
        $outTask = $p.StandardOutput.BaseStream.CopyToAsync($buffer)
        $errTask = $p.StandardError.ReadToEndAsync()
        if ($InputBytes -and $InputBytes.Length) { $p.StandardInput.BaseStream.Write($InputBytes,0,$InputBytes.Length) }
        $p.StandardInput.Close(); $p.WaitForExit(); $outTask.GetAwaiter().GetResult()
        $err = $errTask.GetAwaiter().GetResult()
        return [pscustomobject]@{ Code=$p.ExitCode; Text=(New-Object Text.UTF8Encoding($false,$true)).GetString($buffer.ToArray()); Error=$err }
    } finally { $buffer.Dispose(); $p.Dispose() }
}
function Invoke-CleanupGit {
    param([string[]]$Arguments,[AllowNull()][byte[]]$InputBytes)
    Invoke-CleanupNative 'git.exe' (@('-c','core.fsmonitor=false') + $Arguments) $InputBytes
}
function Get-CleanupGit {
    param([string[]]$Arguments,[AllowNull()][byte[]]$InputBytes,[int[]]$Allowed=@(0))
    $r = Invoke-CleanupGit $Arguments $InputBytes
    if ($Allowed -notcontains $r.Code) { throw ('git ' + ($Arguments -join ' ') + ': ' + $r.Error + ' (exit ' + $r.Code + ')') }
    return $r
}
function Get-CleanupAttributes { param([string]$Path)
    [IO.File]::GetAttributes((ConvertTo-CleanupLiteral $Path))
}
function Get-CleanupEntries { param([string]$Path)
    $p = ConvertTo-CleanupLiteral $Path
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($p)) {
        $plain = if ($entry.StartsWith('\\?\UNC\')) { '\\' + $entry.Substring(8) } elseif ($entry.StartsWith('\\?\')) { $entry.Substring(4) } else { $entry }
        $a = [IO.File]::GetAttributes($entry)
        [pscustomobject]@{ Path=$plain; Name=[IO.Path]::GetFileName($plain); Attributes=$a
            Directory=[bool]($a -band [IO.FileAttributes]::Directory); Reparse=[bool]($a -band [IO.FileAttributes]::ReparsePoint)
            LastWriteTimeUtc=[IO.File]::GetLastWriteTimeUtc($entry) }
    }
}
function Test-CleanupExists { param([string]$Path)
    try { [void](Get-CleanupAttributes $Path); return $true }
    catch [IO.FileNotFoundException] { return $false }
    catch [IO.DirectoryNotFoundException] { return $false }
}
function Test-CleanupElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $id.Dispose() }
}
function Get-CleanupProcess { param([int]$ProcessId)
    try {
        $p = [Diagnostics.Process]::GetProcessById($ProcessId)
        try { return [pscustomobject]@{ Exists=$true; Start=$p.StartTime.ToUniversalTime().ToString('o') } }
        catch { return [pscustomobject]@{ Exists=$true; Start=$null } }
        finally { $p.Dispose() }
    } catch [ArgumentException] { return [pscustomobject]@{ Exists=$false; Start=$null } }
}
function Get-CleanupProcesses { Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object ProcessId,Name,CommandLine }
function Get-CleanupMutexName { return 'ApexCodexRunLedger' }
function Open-CleanupMutex { param([string]$Name) return New-Object Threading.Mutex($false,$Name) }
function Wait-CleanupMutex { param($Mutex) return $Mutex.WaitOne([TimeSpan]::FromSeconds(30)) }
function Send-CleanupLockNotification { param([string]$Phase,$Item) }
function Invoke-CleanupMutation {
    param([string]$Operation,[string]$Path,[string]$Destination)
    $p = ConvertTo-CleanupLiteral $Path
    switch ($Operation) {
        'rename' { [IO.Directory]::Move($p,(ConvertTo-CleanupLiteral $Destination)) }
        'directory' { [IO.Directory]::Delete($p,$false) }
        'file' { [IO.File]::Delete($p) }
        'writable' {
            $a = Get-CleanupAttributes $Path
            if ($a -band [IO.FileAttributes]::ReparsePoint) { throw ('refusing attributes on reparse point '+$Path) }
            [IO.File]::SetAttributes($p,($a -band (-bnot [IO.FileAttributes]::ReadOnly)))
        }
        default { throw "unknown mutation $Operation" }
    }
    if ($script:CleanupSession) { $script:CleanupSession.Mutated=$true; Reset-CleanupScopeProof $script:CleanupSession.Context }
}
function Invoke-CleanupAclCommand { param([string]$File,[string[]]$Arguments) Invoke-CleanupNative $File $Arguments $null }
function Add-CleanupError { param($Context,[string]$Text,[switch]$Records)
    if (-not $Context.Errors.Contains($Text)) { [void]$Context.Errors.Add($Text) }; if ($Records) { $Context.BadRecords=$true }
}
function New-CleanupItem { param($Context,[string]$Class,[string]$Path,$Repo,$Source,[string]$Branch)
    $key = if ($Class -eq 'branch') { 'branch|' + $Repo.Main + '|' + [BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($Path)) } else { ConvertTo-CleanupPath $Path }
    if (-not $Context.Items.ContainsKey($key)) {
        $Context.Items[$key]=[pscustomobject]@{ Key=$key; Class=$Class; Path=$Path; Repo=$Repo; Sources=([Collections.ArrayList]::new())
            Branch=$Branch; Registration=$null; Owned=$false; Verdict='KEEP'; Reason='not proven'; Removed=$false; Quarantine=$null; Root=$null; Aliases=([Collections.ArrayList]::new()); Snapshot=$Context }
        if ($Context.PSObject.Properties['ItemIndex']) { $Context.ItemIndex=$null } else { $Context | Add-Member NoteProperty ItemIndex $null }
        Reset-CleanupScopeProof $Context -Aliases
    }
    $i=$Context.Items[$key]
    if ($Source) { if (-not $i.Sources.Contains($Source)) { [void]$i.Sources.Add($Source) }; if ($Source.Root) { $i.Owned=$true } }
    if ($Branch -and -not $i.Branch) { $i.Branch=$Branch }
    if ($Class -ne 'branch') { Add-CleanupAlias $i $Path }
    return $i
}
function Reset-CleanupScopeProof { param($Context,[switch]$Aliases)
    if (-not $Context) { return }
    if ($Context.PSObject.Properties['ProtectedScopes']) { $Context.ProtectedScopes=$null }
    if ($Aliases -and $Context.PSObject.Properties['ScopeIndex']) { $Context.ScopeIndex=$null }
}
function Add-CleanupAlias { param($Item,[string]$Path)
    if (-not $Item.Aliases.Contains($Path)) {
        [void]$Item.Aliases.Add($Path)
        if ($Item.Class -eq 'worktree') { Reset-CleanupScopeProof $Item.Snapshot -Aliases }
    }
}
function Set-CleanupVerdict { param($Item,[string]$Verdict,[string]$Reason)
    if ($Item.Class -eq 'worktree') { Reset-CleanupScopeProof $Item.Snapshot }
    $Item.Verdict=$Verdict; $Item.Reason=$Reason
}
function Read-CleanupDocument { param([string]$Path)
    # Read on every refresh. Parsed objects are reusable only when these bytes agree;
    # file timestamps, locks and previous content proofs are never cache keys.
    $bytes=[IO.File]::ReadAllBytes((ConvertTo-CleanupLiteral $Path))
    $old=if ($null -ne $script:CleanupRecordCache) { $script:CleanupRecordCache[$Path] } else { $null }
    if ($old -and $bytes.Length -eq $old.Bytes.Length -and [Linq.Enumerable]::SequenceEqual([byte[]]$bytes,[byte[]]$old.Bytes)) { return $old }
    $stream=New-Object IO.MemoryStream(,$bytes)
    $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
    try { $text=$reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Dispose() }
    $doc=[pscustomobject]@{ Bytes=$bytes; Text=$text; Lines=$null; Data=$null; EngineParsed=$false; EngineError=$null }
    if ($null -ne $script:CleanupRecordCache) { $script:CleanupRecordCache[$Path]=$doc }
    return $doc
}
function Read-CleanupEngineData { param([string]$Path)
    $doc=Read-CleanupDocument $Path
    if (-not $doc.EngineParsed) {
        try {
            if (-not $doc.Text.TrimStart().StartsWith('{')) { throw 'expected object' }
            $doc.Data=$doc.Text | ConvertFrom-Json -ErrorAction Stop
        } catch { $doc.EngineError=$_ }
        $doc.EngineParsed=$true
    }
    if ($doc.EngineError) { throw $doc.EngineError }
    return $doc.Data
}
function Read-CleanupLines { param($Context,[string]$Path,[string]$Root,[string]$Kind)
    try {
        if (-not (Test-CleanupExists $Path)) { return }
        $doc=Read-CleanupDocument $Path
        if ($null -eq $doc.Lines) {
            $doc.Lines=[Collections.ArrayList]::new(); $lineNo=0
            foreach ($line in [regex]::Split($doc.Text,'\r\n|\n|\r')) {
                $lineNo++
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    if (-not $line.TrimStart().StartsWith('{')) { throw 'expected object' }
                    $data = $line | ConvertFrom-Json -ErrorAction Stop
                    if ($null -eq $data -or $data -isnot [System.Management.Automation.PSCustomObject]) { throw 'expected object' }
                    [void]$doc.Lines.Add([pscustomobject]@{ Data=$data; Line=$lineNo; Error=$null; Signature=$null })
                } catch { [void]$doc.Lines.Add([pscustomobject]@{ Data=$null; Line=$lineNo; Error=$_.Exception.Message }) }
            }
        }
        foreach ($line in $doc.Lines) {
            if ($line.Error) { Add-CleanupError $Context ("malformed $Kind $Path line $($line.Line): " + $line.Error) -Records:($Kind -eq 'ledger') }
            else { [pscustomobject]@{ Data=$line.Data; Root=$Root; Path=$Path; Kind=$Kind; Identity=($Path+'|'+$line.Line); RecordLine=$line } }
        }
    } catch { Add-CleanupError $Context ("unreadable $Kind ${Path}: " + $_.Exception.Message) -Records:($Kind -eq 'ledger') }
}
function Get-CleanupRegistrations { param([string]$Repo)
    $t=(Get-CleanupGit @('-C',$Repo,'worktree','list','--porcelain','-z')).Text
    $current=$null
    foreach ($part in $t.Split([char]0)) {
        if ($part.StartsWith('worktree ')) {
            if ($current) { $current }
            $current=[pscustomobject]@{ Path=$part.Substring(9); Head=''; Branch=''; Locked=$false; LockReason=''; Prunable=$false }
        } elseif ($current) {
            if ($part.StartsWith('HEAD ')) { $current.Head=$part.Substring(5) }
            elseif ($part.StartsWith('branch ')) { $current.Branch=$part.Substring(7) }
            elseif ($part -eq 'locked' -or $part.StartsWith('locked ')) { $current.Locked=$true; $current.LockReason=$part.Substring(6).Trim() }
            elseif ($part.StartsWith('prunable')) { $current.Prunable=$true }
        }
    }
    if ($current) { $current }
}
function Resolve-CleanupRepository { param($Context,[string]$Path)
    $p=ConvertTo-CleanupPath $Path
    if ($Context.RepoPaths.ContainsKey($p)) { return $Context.RepoPaths[$p] }
    if (-not (Test-CleanupExists $p)) {
        $r=[pscustomobject]@{ Main=$p; Common=$null; Missing=$true; Error=$null; Registrations=@(); MainHead=$null; MainBranch=$null }
        $Context.RepoPaths[$p]=$r; return $r
    }
    try {
        $common=(Get-CleanupGit @('-C',$p,'rev-parse','--path-format=absolute','--git-common-dir')).Text.TrimEnd("`r","`n")
        $common=ConvertTo-CleanupPath $common
        if ($Context.Repos.ContainsKey($common)) { $Context.RepoPaths[$p]=$Context.Repos[$common]; return $Context.Repos[$common] }
        $regs=@(Get-CleanupRegistrations $p)
        if (-not $regs.Count) { throw 'no main checkout' }
        $main=ConvertTo-CleanupPath $regs[0].Path
        $head=$regs[0].Head
        if (-not $head) { throw 'main checkout HEAD unavailable' }
        $r=[pscustomobject]@{ Main=$main; Common=$common; Missing=$false; Error=$null; Registrations=$regs; MainHead=$head; MainBranch=$regs[0].Branch }
        $Context.Repos[$common]=$r; $Context.RepoPaths[$p]=$r; return $r
    } catch {
        $r=[pscustomobject]@{ Main=$p; Common=$null; Missing=$false; Error=$_.Exception.Message; Registrations=@(); MainHead=$null; MainBranch=$null }
        $Context.RepoPaths[$p]=$r; Add-CleanupError $Context ("repository resolution $p : " + $r.Error); return $r
    }
}
function Add-CleanupRecordedPair { param($Context,$Repo,$Source,[string]$Worktree,[string]$Branch)
    if ($Branch -ceq '(detached)') { $Branch=$null }
    if ($Worktree) { [void](New-CleanupItem $Context 'worktree' (ConvertTo-CleanupPath $Worktree) $Repo $Source $Branch) }
    if ($Branch) {
        $ref=if ($Branch.StartsWith('refs/heads/')) { $Branch } else { 'refs/heads/' + $Branch }
        [void](New-CleanupItem $Context 'branch' $ref $Repo $Source $null)
    }
}
function Get-CleanupInventory {
    param([string[]]$StateRoots,[string]$Ledger,[string]$Temp,[double]$Age=24)
    $c=[pscustomobject]@{ Roots=@(); Ledger=$Ledger; Temp=(ConvertTo-CleanupPath $Temp); Age=$Age
        Rows=([Collections.ArrayList]::new()); Runs=([Collections.ArrayList]::new()); Journal=([Collections.ArrayList]::new())
        Items=(New-CleanupPathMap); Repos=(New-CleanupPathMap); RepoPaths=(New-CleanupPathMap); Errors=([Collections.ArrayList]::new()); BadRecords=$false }
    $roots=New-CleanupPathMap; foreach ($p in (@((Join-Path $env:LOCALAPPDATA 'apex'),$env:APEX_STATE_DIR)+$StateRoots)) {
        if ($p) { $n=ConvertTo-CleanupPath $p; $roots[$n]=$n }
    }
    $c.Roots=@($roots.Values); $ledgers=New-CleanupPathMap
    foreach ($root in $c.Roots) {
        $lp=Join-Path $root 'progress/codex-run-ledger.jsonl'; $ledgers[$lp]=$root
        foreach ($j in @(Read-CleanupLines $c (Join-Path $root 'cleanup/journal.jsonl') $root 'journal')) { [void]$c.Journal.Add($j) }
        try {
            if (-not (Test-CleanupExists $root)) { continue }
            foreach ($entry in @(Get-CleanupEntries $root)) {
                if (-not $entry.Directory -or $entry.Name -notmatch '^[0-9a-fA-F]{32}$') { continue }
                $item=New-CleanupItem $c 'history' $entry.Path $null $null $null; $item.Root=$root
                if ($entry.Reparse) { continue }
                $sp=Join-Path $entry.Path 'engine-state.json'
                if (-not (Test-CleanupExists $sp)) { continue }
                try {
                    $data=Read-CleanupEngineData $sp
                    if (-not $data.repo -or -not $data.run_id -or $data.run_id -cne $entry.Name) { throw 'missing/mismatched repo or run_id' }
                    $s=[pscustomobject]@{ Kind='engine'; Data=$data; Root=$root; Path=$sp }
                    [void]$c.Runs.Add($s); [void]$item.Sources.Add($s); $item.Owned=$true
                } catch { Add-CleanupError $c ("malformed engine-state ${sp}: " + $_.Exception.Message) -Records }
            }
        } catch { Add-CleanupError $c ("unreadable state root ${root}: " + $_.Exception.Message) -Records }
    }
    if ($Ledger) { $ledgers[(ConvertTo-CleanupPath $Ledger)]=$null }
    foreach ($lp in @($ledgers.Keys)) {
        $root=$ledgers[$lp]
        if (-not $root) { $root=@($c.Roots | Where-Object { Test-CleanupUnder $lp $_ } | Select-Object -First 1); if ($root.Count) { $root=$root[0] } else { $root=$null } }
        foreach ($s in @(Read-CleanupLines $c $lp $root 'ledger')) { [void]$c.Rows.Add($s) }
    }
    foreach ($s in $c.Rows) {
        if (-not $s.Data.teardown_main_repo) { continue }
        $r=Resolve-CleanupRepository $c ([string]$s.Data.teardown_main_repo)
        Add-CleanupRecordedPair $c $r $s ([string]$s.Data.teardown_worktree) ([string]$s.Data.teardown_branch)
    }
    foreach ($s in $c.Runs) {
        $r=Resolve-CleanupRepository $c ([string]$s.Data.repo)
        $c.Items[(ConvertTo-CleanupPath ([IO.Path]::GetDirectoryName($s.Path)))].Repo=$r
        Add-CleanupRecordedPair $c $r $s ([string]$s.Data.integration.worktree) ([string]$s.Data.integration.branch)
        foreach ($task in @($s.Data.tasks)) { foreach ($a in @($task.attempts)) { Add-CleanupRecordedPair $c $r $s ([string]$a.worktree) ([string]$a.branch) } }
    }
    foreach ($r in $c.Repos.Values) {
        foreach ($reg in @($r.Registrations | Select-Object -Skip 1)) {
            $i=New-CleanupItem $c 'worktree' (ConvertTo-CleanupPath $reg.Path) $r $null $reg.Branch
            $i.Registration=$reg; Add-CleanupAlias $i $reg.Path
        }
        try {
            $refs=(Get-CleanupGit @('-C',$r.Main,'for-each-ref','--format=%(refname)%00','refs/heads/codex/')).Text
            foreach ($ref in $refs.Split([char]0)) { $ref=$ref.Trim("`r","`n"); if ($ref) { [void](New-CleanupItem $c 'branch' $ref $r $null $null) } }
        } catch { Add-CleanupError $c $_.Exception.Message }
    }
    # Quarantine discovery includes journal-only parents, not merely live worktrees.
    $parents=New-CleanupPathMap; foreach ($p in (@($c.Roots)+@($c.Temp))) { $parents[$p]=$p }
    foreach ($r in $c.RepoPaths.Values) { $p=[IO.Path]::GetDirectoryName($r.Main); if ($p) { $parents[$p]=$p } }
    foreach ($i in @($c.Items.Values)) { if ($i.Class -eq 'worktree') { $p=[IO.Path]::GetDirectoryName($i.Path); $parents[$p]=$p } }
    foreach ($j in $c.Journal) {
        if ($j.Data.quarantine_path) { try { $p=[IO.Path]::GetDirectoryName((ConvertTo-CleanupPath $j.Data.quarantine_path)); $parents[$p]=$p } catch { Add-CleanupError $c ('invalid journal quarantine_path: ' + $_.Exception.Message) } }
    }
    $pattern='^(?:.*)?\.apex-cleanup-(quarantine|failed)-\d{8}T\d{6}Z-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    foreach ($p in $parents.Values) {
        try {
            if (-not (Test-CleanupExists $p)) { continue }
            $entries=@(Get-CleanupEntries $p)
            if (Test-CleanupEqual $p $c.Temp) { $tempEntries=$entries }
            foreach ($e in $entries) {
                if (-not $e.Directory -or $e.Name -notmatch $pattern) { continue }
                $failed=$Matches[1] -eq 'failed'; $i=New-CleanupItem $c 'quarantine' $e.Path $null $null $null
                # Quarantine status takes precedence over a stale ledger path or
                # a test-temp prefix. Ordinary Apply must never recover it.
                $i.Class='quarantine'; $i.Owned=$false
                $reason=if ($failed) { 'failed rollback: needs owner y/n' } else { 'interrupted quarantine: needs owner y/n' }
                $matchesJournal=@($c.Journal | Where-Object { $_.Data.quarantine_path -and (Test-CleanupEqual $_.Data.quarantine_path $e.Path) -and $_.Data.utc -and $_.Data.original_path -and $_.Data.class -and $_.Data.action -in @('quarantine','failed-rollback') })
                if ($matchesJournal.Count) {
                    foreach ($j in $matchesJournal) {
                        $reason+='; since ' + $j.Data.utc + '; was ' + $j.Data.class + ' ' + $j.Data.original_path
                        foreach ($id in @($j.Data.run_ids)) { if ($id) { $reason+='; run ' + $id } }
                        if ($j.Data.spec) { $reason+='; spec ' + $j.Data.spec }; if ($j.Data.branch) { $reason+='; branch ' + $j.Data.branch }
                    }
                } else { $reason+='; origin unknown; last write ' + $e.LastWriteTimeUtc.ToString('o') }
                Set-CleanupVerdict $i 'KEEP' $reason
            }
        } catch { Add-CleanupError $c ("unreadable inventory directory ${p}: " + $_.Exception.Message) }
    }
    try {
        if (Test-CleanupExists $c.Temp) {
            if ($null -eq $tempEntries) { $tempEntries=@(Get-CleanupEntries $c.Temp) }
            foreach ($e in $tempEntries) {
                if (-not $e.Directory -or $e.Name -notmatch '^(apex-scope-|apex-drain-test-|engine-test-|engine-test-machine-|apex-dispatch-preflight-test-|apex-task2-verify-|engine-dispatch-test-|apex-d4-state-|apex-scope-check-test-|apex-baseline-test-|apex-dispatch-test-|apex-dispatch-regression-)') { continue }
                if ($e.Name.StartsWith('apex-scope-') -or ([datetime]::UtcNow-$e.LastWriteTimeUtc).TotalHours -ge $Age) { $i=New-CleanupItem $c 'temp' $e.Path $null $null $null; $i.Owned=$true; $i.Root=$c.Temp }
            }
        }
    } catch { Add-CleanupError $c ('unreadable temp root: ' + $_.Exception.Message) }
    return $c
}
function Test-CleanupProcessIdentity {
    param($ProcessId,[string]$StartTime)
    if (-not $ProcessId) { return 'dead' }
    if (-not $StartTime -or $StartTime -eq 'unknown') { return 'unresolved' }
    try {
        $expected=[datetime]::Parse($StartTime,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $p=Get-CleanupProcess ([int]$ProcessId)
        if (-not $p.Exists) { return 'dead' }
        if (-not $p.Start) { return 'unresolved' }
        $actual=[datetime]::Parse($p.Start,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if ([math]::Abs(($actual-$expected).TotalMilliseconds) -lt 50) { return 'live' }
        return 'dead'
    } catch { return 'unresolved' }
}
function Add-CleanupIndexValue { param($Map,[string]$Key,$Value)
    if (-not $Map.ContainsKey($Key)) { $Map[$Key]=[Collections.ArrayList]::new() }
    [void]$Map[$Key].Add($Value)
}
function Get-CleanupRowIndex { param($Context)
    if ($Context.PSObject.Properties['RowIndex'] -and $Context.RowIndex) { return $Context.RowIndex }
    $index=[pscustomobject]@{ Runs=([Collections.Hashtable]::new([StringComparer]::Ordinal)); UserRuns=(New-CleanupPathMap)
        Paths=(New-CleanupPathMap); Closure=([Collections.Hashtable]::new([StringComparer]::Ordinal)); Inputs=(New-CleanupPathMap)
        Entries=([Collections.ArrayList]::new()); Identities=@{}; GuardRows=$null; FullScans=1; RowsVisited=0 }
    $order=0; $normalized=New-CleanupPathMap
    foreach ($s in $Context.Rows) {
        $index.RowsVisited++; $d=$s.Data; $id=[string]$d.run_id
        $entry=[pscustomobject]@{ Source=$s; Order=$order; Identity=$order; Keyed=$false }; $order++
        [void]$index.Entries.Add($entry)
        if ($s.Path -and -not $index.Inputs.ContainsKey($s.Path)) { $index.Inputs[(ConvertTo-CleanupPath $s.Path)]=$true }
        Add-CleanupIndexValue $index.Runs $id $s
        Add-CleanupIndexValue $index.UserRuns $id $entry
        if (-not $index.Closure.ContainsKey($id)) { $index.Closure[$id]=@{ Lease=$false; Dispatch=$false } }
        $kind=if ($d.row_kind) { [string]$d.row_kind } else { 'dispatch' }
        if ($kind -ceq 'lease_close') { $index.Closure[$id].Lease=$true }
        if ($kind -ceq 'dispatch' -and @('leasing','running','stalled','adopting','orphaned') -cnotcontains [string]$d.status) { $index.Closure[$id].Dispatch=$true }
        $seen=New-CleanupPathMap
        foreach ($p in @($d.worktree_key,$d.worktree,$d.teardown_worktree)) {
            if ($p) { try {
                if (-not $normalized.ContainsKey([string]$p)) { $normalized[[string]$p]=ConvertTo-CleanupPath $p }
                $key=$normalized[[string]$p]
                if (-not $seen.ContainsKey($key)) { Add-CleanupIndexValue $index.Paths $key $entry; $seen[$key]=$true }
            } catch {} }
        }
    }
    foreach ($s in $Context.Runs) { if ($s.Path) { $index.Inputs[(ConvertTo-CleanupPath $s.Path)]=$true } }
    $Context | Add-Member NoteProperty RowIndex $index -Force
    return $index
}
function Get-CleanupRowIdentity { param($Entry,$Index)
    # Preserve duplicate-payload equivalence once per matched row. Subsequent
    # lookups use its stable ordinal; unchanged record bytes retain the signature.
    if (-not $Entry.Keyed) {
        $s=$Entry.Source; $d=$s.Data
        $line=$s.RecordLine
        if ($line) {
            if ($null -eq $line.Signature) { $line.Signature=$d | ConvertTo-Json -Compress -Depth 20 }
            $signature=$line.Signature
        } else { $signature=$d | ConvertTo-Json -Compress -Depth 20 }
        $key=$s.Path+'|'+$signature
        if (-not $Index.Identities.ContainsKey($key)) { $Index.Identities[$key]=$Entry.Order }
        $Entry.Identity=$Index.Identities[$key]; $Entry.Keyed=$true
    }
    return $Entry.Identity
}
function Get-CleanupBranchKey { param($Repo,[string]$Branch)
    return (ConvertTo-CleanupPath $Repo.Main).ToLowerInvariant()+'|'+$Branch
}
function Add-CleanupAncestors { param($Map,[string]$Path,$Value)
    $parent=[IO.Path]::GetDirectoryName((ConvertTo-CleanupPath $Path))
    while ($parent) { Add-CleanupIndexValue $Map $parent $Value; $parent=[IO.Path]::GetDirectoryName($parent) }
}
function Get-CleanupItemIndex { param($Context)
    if ($Context.PSObject.Properties['ItemIndex'] -and $Context.ItemIndex) { return $Context.ItemIndex }
    $ix=[pscustomobject]@{ Classes=@{}; Branches=([Collections.Hashtable]::new([StringComparer]::Ordinal)); BranchProofs=([Collections.Hashtable]::new([StringComparer]::Ordinal)); Children=(New-CleanupPathMap)
        Registrations=(New-CleanupPathMap); EngineChildren=([Collections.Hashtable]::new([StringComparer]::Ordinal))
        Protected=(New-CleanupPathMap); Containers=([Collections.ArrayList]::new()) }
    foreach ($class in @('worktree','branch','history','temp','quarantine')) { $ix.Classes[$class]=[Collections.ArrayList]::new() }
    $order=0
    foreach ($i in $Context.Items.Values) {
        [void]$ix.Classes[$i.Class].Add($i)
        if ($i.Class -ne 'branch') { Add-CleanupAncestors $ix.Children $i.Path ([pscustomobject]@{ Item=$i; Order=$order }); [void]$ix.Containers.Add($i) }; $order++
        if ($i.Class -in @('worktree','branch')) {
            foreach ($s in $i.Sources) { if ($s.Kind -eq 'engine') { Add-CleanupIndexValue $ix.EngineChildren ((ConvertTo-CleanupPath $s.Root).ToLowerInvariant()+'|'+$s.Data.run_id) $i } }
        }
        if ($i.Class -ne 'worktree' -or -not $i.Repo) { continue }
        $refs=[Collections.Hashtable]::new([StringComparer]::Ordinal)
        if ($i.Branch) {
            $ref=if ($i.Branch.StartsWith('refs/heads/',[StringComparison]::Ordinal)) { $i.Branch } else { 'refs/heads/'+$i.Branch }
            $refs[$ref]=$true
            # Branch content proof historically folds the prefix, while user
            # association uses the ordinal form. Keep those indexes separate.
            Add-CleanupIndexValue $ix.BranchProofs (Get-CleanupBranchKey $i.Repo ('refs/heads/'+($i.Branch -replace '^refs/heads/',''))) $i
        }
        if ($i.Registration -and $i.Registration.Branch) { $refs[$i.Registration.Branch]=$true }
        foreach ($ref in $refs.Keys) { Add-CleanupIndexValue $ix.Branches (Get-CleanupBranchKey $i.Repo $ref) $i }
    }
    $order=0
    foreach ($r in $Context.Repos.Values) { foreach ($reg in $r.Registrations) { Add-CleanupAncestors $ix.Registrations $reg.Path ([pscustomobject]@{ Item=$reg; Order=$order }); $order++ } }
    foreach ($root in (@($Context.Roots)+@($Context.Temp)+@($Context.RepoPaths.Values | ForEach-Object { $_.Main }))) {
        $p=ConvertTo-CleanupPath $root
        if (-not $ix.Protected.ContainsKey($p)) { $ix.Protected[$p]=$root }
        $parent=[IO.Path]::GetDirectoryName($p)
        while ($parent) { if (-not $ix.Protected.ContainsKey($parent)) { $ix.Protected[$parent]=$root }; $parent=[IO.Path]::GetDirectoryName($parent) }
    }
    $Context | Add-Member NoteProperty ItemIndex $ix -Force
    return $ix
}
function Get-CleanupContainedValues { param($Map,[string]$Path,[string]$ActualPath)
    if (-not $ActualPath) { foreach ($entry in $Map[(ConvertTo-CleanupPath $Path)]) { $entry.Item }; return }
    $seen=@{}
    foreach ($p in @($Path,$ActualPath)) { foreach ($entry in $Map[(ConvertTo-CleanupPath $p)]) { $seen[$entry.Order]=$entry } }
    foreach ($entry in @($seen.Values | Sort-Object Order)) { $entry.Item }
}
function Get-CleanupContainedItems { param($Context,[string]$Path,[string]$ActualPath)
    Get-CleanupContainedValues (Get-CleanupItemIndex $Context).Children $Path $ActualPath
}
function Test-CleanupRowClosed { param($Source,$Context,[switch]$Legacy)
    $r=$Source.Data; if (-not $r.run_id) { return $false }
    $kind=if ($r.row_kind) { [string]$r.row_kind } else { 'dispatch' }
    # Reservations are updated/deleted by their writer; other rows cannot close them.
    if ($kind -ceq 'teardown_lease') { return ([string]$r.status -cne 'reserved') }
    $facts=(Get-CleanupRowIndex $Context).Closure[[string]$r.run_id]
    return [bool]($facts -and (($facts.Lease -and ($Legacy -or $kind -in @('lease','teardown_lease'))) -or ($facts.Dispatch -and ($Legacy -or $kind -notin @('lease','teardown_lease')))))
}
function Get-CleanupRowUsers { param($Source,$Context)
    $r=$Source.Data; $kind=if ($r.row_kind) { [string]$r.row_kind } else { 'dispatch' }
    if ($kind -notin @('lease','teardown_lease','dispatch')) { return }
    if (Test-CleanupRowClosed $Source $Context) { return }
    if ($kind -ceq 'teardown_lease' -and (-not $r.pid -or -not $r.pid_start)) {
        [pscustomobject]@{ Status='unresolved'; Text=('teardown_lease run ' + $r.run_id); Legacy=$false }
        return
    }
    foreach ($pair in @(@('pid','pid_start'),@('launcher_pid','launcher_start'))) {
        if ($kind -ceq 'teardown_lease' -and $pair[0] -ne 'pid') { continue }
        $id=$r.($pair[0]); $start=[string]$r.($pair[1])
        if (-not $id) { continue }
        if (-not $start -and (Test-CleanupRowClosed $Source $Context -Legacy)) { continue }
        $status=Test-CleanupProcessIdentity $id $start
        if ($status -ne 'dead') { [pscustomobject]@{ Status=$status; Text=("$kind run " + $r.run_id + ' PID ' + $id + ' start ' + $start); Legacy=(-not $start) } }
    }
    if (-not $r.pid -and -not $r.launcher_pid -and -not (Test-CleanupRowClosed $Source $Context -Legacy)) {
        [pscustomobject]@{ Status='unresolved'; Text=('dispatch/lease run ' + $r.run_id); Legacy=$true }
    }
}
function Get-CleanupEngineUsers { param($Source,$Context)
    $d=$Source.Data; $pairs=[Collections.ArrayList]::new()
    if (-not $d.engine_owner -or -not $d.engine_owner.pid) {
        [pscustomobject]@{ Status='unresolved'; Text=('engine owner run ' + $d.run_id); Legacy=$false }
    } else { [void]$pairs.Add(@($d.engine_owner.pid,$d.engine_owner.start_time,'engine owner')) }
    foreach ($t in @($d.tasks)) {
        foreach ($a in @($t.attempts)) {
            if ($a.child_pid) { [void]$pairs.Add(@($a.child_pid,$a.child_start_time,'attempt child')) }
            if ($a.wrapper_run_id) {
                $rows=(Get-CleanupRowIndex $Context).Runs[[string]$a.wrapper_run_id]
                if (-not $rows.Count) { [pscustomobject]@{ Status='unresolved'; Text=('wrapper run ' + $a.wrapper_run_id); Legacy=$false } }
                foreach ($row in $rows) { Get-CleanupRowUsers $row $Context }
            }
        }
        foreach ($a in @($t.acceptance)) { if ($a.child_pid) { [void]$pairs.Add(@($a.child_pid,$a.child_start_time,'task acceptance child')) } }
    }
    foreach ($a in @($d.spec_acceptance.checks)) { if ($a.child_pid) { [void]$pairs.Add(@($a.child_pid,$a.child_start_time,'spec acceptance child')) } }
    foreach ($pair in $pairs) {
        $status=Test-CleanupProcessIdentity $pair[0] ([string]$pair[1])
        if ($status -ne 'dead') { [pscustomobject]@{ Status=$status; Text=($pair[2] + ' run ' + $d.run_id + ' PID ' + $pair[0] + ' start ' + $pair[1]); Legacy=$false } }
    }
}
function Get-CleanupItemUsers { param($Item,$Context)
    $runIds=@{}; $worktrees=New-CleanupPathMap
    if ($Item.Class -eq 'worktree') { foreach ($a in $Item.Aliases) { $worktrees[(ConvertTo-CleanupPath $a)]=$true } }
    foreach ($s in $Item.Sources) {
        $runIds[[string]$s.Data.run_id]=$true
        if ($s.Kind -eq 'engine') { Get-CleanupEngineUsers $s $Context }
        else { Get-CleanupRowUsers $s $Context }
    }
    if ($Item.Class -eq 'branch') {
        foreach ($w in (Get-CleanupItemIndex $Context).Branches[(Get-CleanupBranchKey $Item.Repo $Item.Path)]) {
            $br=if ($w.Branch -and -not $w.Branch.StartsWith('refs/heads/')) { 'refs/heads/' + $w.Branch } else { $w.Branch }
            if ($br -ceq $Item.Path -or ($w.Registration -and $w.Registration.Branch -ceq $Item.Path)) {
                foreach ($a in $w.Aliases) { $worktrees[(ConvertTo-CleanupPath $a)]=$true }
                foreach ($s in $w.Sources) { if ($s.Kind -eq 'engine') { Get-CleanupEngineUsers $s $Context } }
            }
        }
    }
    $ix=Get-CleanupRowIndex $Context; $matches=@{}
    foreach ($id in $runIds.Keys) { foreach ($entry in $ix.UserRuns[$id]) { $matches[$entry.Order]=$entry } }
    foreach ($path in $worktrees.Keys) { foreach ($entry in $ix.Paths[$path]) { $matches[$entry.Order]=$entry } }
    $seen=@{}
    foreach ($entry in @($matches.Values | Sort-Object Order)) {
        $identity=Get-CleanupRowIdentity $entry $ix
        if ($seen.ContainsKey($identity)) { continue }; $seen[$identity]=$true
        Get-CleanupRowUsers $entry.Source $Context
    }
}
function Get-CleanupGuard { param($Context)
    $reasons=[Collections.ArrayList]::new()
    foreach ($s in $Context.Runs) { foreach ($u in @(Get-CleanupEngineUsers $s $Context)) { if ($u.Status -eq 'live') { [void]$reasons.Add(('live ' + $u.Text)) } } }
    $index=Get-CleanupRowIndex $Context
    if ($null -eq $index.GuardRows) {
        $index.FullScans++
        $index.GuardRows=[Collections.ArrayList]::new()
        foreach ($entry in $index.Entries) {
            $s=$entry.Source; $d=$s.Data; $kind=if ($d.row_kind) { [string]$d.row_kind } else { 'dispatch' }
            if ($kind -in @('dispatch','lease','teardown_lease') -and -not (Test-CleanupRowClosed $s $Context)) { [void]$index.GuardRows.Add($s) }
        }
    }
    foreach ($s in $index.GuardRows) { foreach ($u in @(Get-CleanupRowUsers $s $Context)) { if ($u.Status -eq 'live') { [void]$reasons.Add(('live ' + $u.Text)) } } }
    try {
        foreach ($p in @(Get-CleanupProcesses)) {
            if ([int]$p.ProcessId -eq $PID) { continue }
            $raw=[string]$p.CommandLine; $text=$raw; $unavailable=$false; $decoded=''
            if ([string]$p.Name -match '^(powershell|pwsh)(\.exe)?$') {
                # Lookahead keeps a preceding switch (for example -NoProfile) from
                # consuming the encoded-command option as its apparent argument.
                $tokens=[regex]::Matches($raw,'(?i)(?=(?:^|\s)"?[-/]([a-z]+)"?(?:(?:\s+|:)("[^"]*"|\S+))?)')
                foreach ($m in $tokens) {
                    $option=$m.Groups[1].Value.ToLowerInvariant()
                    if ($option -eq 'ec' -or 'encodedcommand'.StartsWith($option)) {
                        try {
                            if (-not $m.Groups[2].Success) { throw 'missing encoded payload' }
                            $bytes=[Convert]::FromBase64String($m.Groups[2].Value.Trim('"'))
                            if ($bytes.Length % 2) { throw 'odd UTF-16 payload' }
                            $decoded=(New-Object Text.UnicodeEncoding($false,$false,$true)).GetString($bytes); $text+=' ' + $decoded
                            if ($decoded -match '(?i)FromBase64String') { $unavailable=$true }
                        } catch { $unavailable=$true }
                    }
                }
            }
            if ($unavailable -or $text -match '(?i)(apex-engine\.ps1|codex-dispatch\.ps1|engine-dispatch\.ps1|apex-drain\.ps1|apex-cleanup\.ps1|\bexec"?\s+"?-p"?\s+"?apex-coder\b)') {
                $why=if ($unavailable) { 'unavailable process proof' } else { 'live runner process' }
                $detail=$raw; if ($decoded) { $detail+=' decoded ' + $decoded.Substring(0,[Math]::Min(200,$decoded.Length)) }
                [void]$reasons.Add(($why + ' PID ' + $p.ProcessId + ' ' + $detail))
            }
        }
    } catch { [void]$reasons.Add(('unavailable process-enumeration proof: ' + $_.Exception.Message)) }
    return $reasons.ToArray()
}
function Assert-CleanupGuard { param($Context,[switch]$Completion)
    $reasons=@(Get-CleanupGuard $Context)
    if ($reasons.Count) {
        if ($script:CleanupSession) { $script:CleanupSession.Trip=($reasons -join '; ') }
        if (-not $Completion) { throw ('CLEANUP_GUARD: ' + ($reasons -join '; ')) }
    }
}
function Test-CleanupAccessDenied { param($ErrorRecord)
    $e=$ErrorRecord.Exception
    while ($e) {
        if ($e -is [UnauthorizedAccessException] -or ($e.HResult -band 65535) -eq 5) { return $true }
        $e=$e.InnerException
    }
    return $false
}
function Test-CleanupDisposable { param([string]$Relative,[switch]$ScratchOnly)
    $components=$Relative.Replace('\','/').Split('/')
    # A file named node_modules is not itself a disposable directory.
    for ($n=0; $n -lt $components.Length-1; $n++) {
        $s=$components[$n]
        if ($s -ceq '.codex-scratch' -or $s.StartsWith('.codex-tmp',[StringComparison]::Ordinal)) { return $true }
        if (-not $ScratchOnly -and @('node_modules','.venv','__pycache__','.pytest_cache','.mypy_cache','.ruff_cache') -ccontains $s) { return $true }
    }
    return $false
}
function Test-CleanupAncestry { param([string]$Path)
    $p=ConvertTo-CleanupPath $Path
    while ($p) {
        try {
            $a=Get-CleanupAttributes $p
            if ($a -band [IO.FileAttributes]::ReparsePoint) { throw ('reparse point ' + $p) }
            if (-not ($a -band [IO.FileAttributes]::Directory)) { throw ('not a directory ' + $p) }
        } catch [IO.FileNotFoundException] {} catch [IO.DirectoryNotFoundException] {}
        $p=[IO.Path]::GetDirectoryName($p)
    }
}
function Test-CleanupProtected { param([string]$Path,$Context)
    return (Get-CleanupItemIndex $Context).Protected[(ConvertTo-CleanupPath $Path)]
}
function Test-CleanupDeletionBoundary {
    param($Item,$Context,[string]$ActualPath,[switch]$Owner,[switch]$Shallow,[string]$InspectionRetryDirectory)
    $path=if ($ActualPath) { $ActualPath } else { $Item.Path }
    $protected=Test-CleanupProtected $path $Context
    if ($protected) { return 'protected root ' + $protected }
    try {
        if ($Owner) {
            if ($Item.Class -ne 'quarantine' -or -not (Test-CleanupExists $path)) { return 'not an inventoried quarantine' }
            Test-CleanupAncestry $path; return $null
        }
        if (-not $Item.Owned) { return 'unknown owner' }
        $original=$Item.Path; $parent=[IO.Path]::GetDirectoryName($original); $name=[IO.Path]::GetFileName($original)
        switch ($Item.Class) {
            'worktree' {
                $pn=[IO.Path]::GetFileName($parent)
                $eligible=$pn -match '(?i)(-wt|-worktrees)$' -or $pn -ieq '.claude-wt'
                if (-not $eligible -and $Item.Repo) {
                    $rn=[IO.Path]::GetFileName($Item.Repo.Main); $rp=[IO.Path]::GetDirectoryName($Item.Repo.Main)
                    $eligible=(Test-CleanupEqual $parent $rp) -and ($name -match ('^(?i)' + [regex]::Escape($rn) + '-(wt|codex)-.+$'))
                }
                if (-not $eligible) { return 'worktree outside eligible parent/name boundary ' + $original }
            }
            'history' {
                if ($name -notmatch '^[0-9a-fA-F]{32}$' -or -not $Item.Root -or -not (Test-CleanupEqual $parent $Item.Root)) { return 'history boundary ' + $original }
            }
            'temp' {
                if (-not (Test-CleanupEqual $parent $Context.Temp) -or $name -notmatch '^(apex-scope-|apex-drain-test-|engine-test-|engine-test-machine-|apex-dispatch-preflight-test-|apex-task2-verify-|engine-dispatch-test-|apex-d4-state-|apex-scope-check-test-|apex-baseline-test-|apex-dispatch-test-|apex-dispatch-regression-)') { return 'temp boundary ' + $original }
            }
            default { return 'unsupported deletion boundary ' + $Item.Class }
        }
        Test-CleanupAncestry $path
        foreach ($other in @(Get-CleanupContainedItems $Context $original $ActualPath)) {
            if ($other.Class -eq 'branch' -or $other.Key -eq $Item.Key -or $other.Removed) { continue }
            if (Test-CleanupUnder $other.Path $original) { return 'contains repository or kept item ' + $other.Path }
            if ($ActualPath -and (Test-CleanupUnder $other.Path $ActualPath)) { return 'contains repository or kept item ' + $other.Path }
        }
        foreach ($reg in @(Get-CleanupContainedValues (Get-CleanupItemIndex $Context).Registrations $original $ActualPath)) {
            if ((Test-CleanupUnder $reg.Path $original) -or ($ActualPath -and (Test-CleanupUnder $reg.Path $ActualPath))) { return 'contains repository or kept item ' + $reg.Path }
        }
        if ($Shallow -or -not (Test-CleanupExists $path)) { return $null }
        $stack=New-Object 'Collections.Generic.Stack[string]'; $stack.Push($path)
        while ($stack.Count) {
            $dir=$stack.Pop()
            try { $entries=@(Get-CleanupEntries $dir) }
            catch {
                if (Test-CleanupAccessDenied $_) {
                    if ($InspectionRetryDirectory) { continue }
                    if (-not $script:CleanupSession -or -not $script:CleanupSession.Apply) { return 'unreadable: needs -Apply elevated inspection ' + $dir }
                    if ($script:CleanupSession.LockHeld) { return 'inspection repair required outside mutex ' + $dir }
                    Invoke-CleanupAclRetry $dir $Item $Context $path
                    $entries=@(Get-CleanupEntries $dir)
                } else { throw }
            }
            foreach ($e in $entries) {
                $relative=$e.Path.Substring($path.Length).TrimStart('\','/')
                if ($e.Name -ieq '.git') {
                    if (-not ($Item.Class -eq 'worktree' -and -not $e.Directory -and -not $e.Reparse -and (Test-CleanupEqual $dir $path))) { return 'contains repository or kept item ' + $e.Path }
                }
                if ($e.Directory -and $e.Name -match '\.apex-cleanup-(quarantine|failed)-\d{8}T\d{6}Z-') { return 'contains repository or kept item ' + $e.Path }
                if ($e.Reparse) {
                    if (-not (Test-CleanupDisposable ($relative + $(if ($e.Directory) { '/link' } else { '' })))) { return 'reparse point ' + $e.Path }
                    continue
                }
                if ($e.Directory) { $stack.Push($e.Path) }
            }
        }
        return $null
    } catch { throw ('boundary proof ' + $path + ': ' + $_.Exception.Message) }
}
function Get-CleanupInactivityReason { param($Item,$Context)
    $u=@(Get-CleanupItemUsers $Item $Context)
    if ($u.Count) {
        return (@($u | ForEach-Object { if ($_.Status -eq 'live') { 'live ' + $_.Text } else { 'unresolved process identity ' + $_.Text } }) -join '; ')
    }
    return $null
}
function Get-CleanupNul { param([string]$Text)
    foreach ($s in $Text.Split([char]0)) { if ($s.Length) { $s } }
}
function Get-CleanupTree { param([string]$Repo,[string]$Commit)
    $map=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $text=(Get-CleanupGit @('-C',$Repo,'ls-tree','-r','-z',$Commit)).Text
    foreach ($record in @(Get-CleanupNul $text)) {
        $tab=$record.IndexOf("`t"); if ($tab -lt 0) { throw 'unparseable ls-tree' }
        $meta=$record.Substring(0,$tab).Split(' ')
        $map[$record.Substring($tab+1)]=[pscustomobject]@{ Mode=$meta[0]; Type=$meta[1]; Hash=$meta[2] }
    }
    return ,$map
}
function ConvertTo-CleanupGitQuoted { param([string]$Path)
    # Always quote UTF-8 bytes. Octal quoting also handles newline/tab/quote paths.
    $b=New-Object Text.StringBuilder; [void]$b.Append('"')
    foreach ($v in [Text.Encoding]::UTF8.GetBytes($Path)) {
        if ($v -ge 32 -and $v -le 126 -and $v -ne 34 -and $v -ne 92) { [void]$b.Append([char]$v) }
        else { [void]$b.Append(('\' + [Convert]::ToString($v,8).PadLeft(3,'0'))) }
    }
    [void]$b.Append('"'); return $b.ToString()
}
function Test-CleanupDetachedRetention { param($Item,[string]$Head,[string]$MainHead)
    $ancestor=Get-CleanupGit @('-C',$Item.Repo.Main,'merge-base','--is-ancestor',$Head,$MainHead) $null @(0,1)
    if ($ancestor.Code -eq 0) { return $null }
    $own=@{}; foreach ($s in $Item.Sources) {
        if ($s.Kind -eq 'engine') {
            $pairs=@($s.Data.integration)+@($s.Data.tasks | ForEach-Object { @($_.attempts) })
            foreach ($pair in $pairs) {
                if ($pair.worktree -and $pair.branch -and (Test-CleanupEqual $pair.worktree $Item.Path)) { $own[('refs/heads/' + ([string]$pair.branch -replace '^refs/heads/',''))]=$true }
            }
        } elseif ($s.Data.teardown_branch) { $own[('refs/heads/' + ([string]$s.Data.teardown_branch -replace '^refs/heads/',''))]=$true }
    }
    $refs=(Get-CleanupGit @('-C',$Item.Repo.Main,'for-each-ref','--contains',$Head,'--format=%(refname)','refs/heads','refs/tags')).Text
    $retained=@($refs -split '\r?\n' | Where-Object { $_ -and -not $own.ContainsKey($_) })
    if (-not $retained.Count) { return 'unique detached commit ' + $Head }
    return $null
}
function Test-CleanupWorktree {
    param($Item,$Context)
    if (-not $Item.Owned) { return 'unknown owner' }
    if ($Item.Repo.Missing) { if (-not (Test-CleanupExists $Item.Path)) { Set-CleanupVerdict $Item 'GONE' 'recorded repository and worktree absent'; return $null }; return 'unknown owner (repository missing)' }
    if ($Item.Repo.Error) { throw $Item.Repo.Error }
    $reason=Get-CleanupInactivityReason $Item $Context; if ($reason) { return $reason }
    if ($Item.Registration -and $Item.Registration.Locked) { return 'locked worktree: ' + $(if ($Item.Registration.LockReason) { $Item.Registration.LockReason } else { 'no reason supplied' }) }
    $reason=Test-CleanupDeletionBoundary $Item $Context; if ($reason) { return $reason }
    $exists=Test-CleanupExists $Item.Path
    if (-not $exists) {
        if (-not $Item.Registration) { Set-CleanupVerdict $Item 'GONE' 'recorded worktree absent, no registration'; return $null }
        $branch=if ($Item.Registration.Branch) { $Item.Registration.Branch } else { $Item.Branch }
        if ($branch) {
            $ref=if ($branch.StartsWith('refs/heads/')) { $branch } else { 'refs/heads/' + $branch }
            $b=New-CleanupItem $Context 'branch' $ref $Item.Repo $null $null
            if (-not $b.Owned) { return 'unknown owner for missing worktree branch ' + $ref }
            $br=Test-CleanupBranch $b $Context -ForMissing; if ($br) { return $br }
        } # Detached registrations are proved from their retained administrative HEAD below.
        $found=@()
        $admin=Join-Path $Item.Repo.Common 'worktrees'
        if (Test-CleanupExists $admin) {
            foreach ($e in @(Get-CleanupEntries $admin)) {
                if (-not $e.Directory -or $e.Reparse) { continue }
                $pointer=Join-Path $e.Path 'gitdir'
                if (Test-CleanupExists $pointer) {
                    $target=[IO.File]::ReadAllText((ConvertTo-CleanupLiteral $pointer)).TrimEnd("`r","`n")
                    if (Test-CleanupEqual $target (Join-Path $Item.Path '.git')) { $found+=,$e.Path }
                }
            }
        }
        if ($found.Count -ne 1) { return 'missing worktree retained index unavailable' }
        if (-not $Item.Registration.Branch) {
            $retainedHead=(Get-CleanupGit @(('--git-dir='+$found[0]),'rev-parse','--verify','HEAD')).Text.Trim()
            $mainHead=(Get-CleanupGit @('-C',$Item.Repo.Main,'rev-parse','--verify','HEAD')).Text.Trim()
            $retained=Test-CleanupDetachedRetention $Item $retainedHead $mainHead
            if ($retained) { return $retained }
        }
        $r=Get-CleanupGit @(('--git-dir='+$found[0]),'diff-index','--cached','--quiet','HEAD') $null @(0,1)
        if ($r.Code -eq 1) { return 'staged content in missing worktree index' }
        return $null
    }
    $pointer=Join-Path $Item.Path '.git'
    if (-not (Test-CleanupExists $pointer)) {
        if ($Item.Registration) { return 'worktree metadata unavailable ' + $pointer }
        $stack=New-Object 'Collections.Generic.Stack[string]'; $stack.Push($Item.Path)
        while ($stack.Count) {
            foreach ($e in @(Get-CleanupEntries $stack.Pop())) {
                $rel=$e.Path.Substring($Item.Path.Length).TrimStart('\','/')
                if ($e.Directory -and (Test-CleanupDisposable ($rel+'/entry'))) { continue }
                return 'orphan contains non-disposable entry ' + $e.Path
            }
        }
        return $null
    }
    $top=(Get-CleanupGit @('-C',$Item.Path,'rev-parse','--show-toplevel')).Text.TrimEnd("`r","`n")
    if (-not (Test-CleanupEqual $top $Item.Path)) { return 'git work tree mismatch ' + (ConvertTo-CleanupPath $top) }
    $common=(Get-CleanupGit @('-C',$Item.Path,'rev-parse','--path-format=absolute','--git-common-dir')).Text.TrimEnd("`r","`n")
    if (-not (Test-CleanupEqual $common $Item.Repo.Common)) { return 'git work tree mismatch ' + (ConvertTo-CleanupPath $common) }
    # The filter gate precedes status, diff, hashes, and every content proof.
    $paths=@(Get-CleanupNul (Get-CleanupGit @('-C',$Item.Path,'ls-files','-z','--cached','--others','--exclude-standard')).Text)
    $nul=[string][char]0
    $inputBytes=[Text.Encoding]::UTF8.GetBytes(($paths -join $nul)+$(if ($paths.Count) { $nul } else { '' }))
    $attrs=@(Get-CleanupNul (Get-CleanupGit @('-C',$Item.Path,'check-attr','-z','--stdin','filter') $inputBytes).Text)
    if ($attrs.Count % 3) { throw 'unparseable check-attr output' }
    for ($n=0; $n -lt $attrs.Count; $n+=3) { if ($attrs[$n+2] -cnotin @('unspecified','unset')) { return 'filtered path: manual review ' + $attrs[$n] } }
    $head=(Get-CleanupGit @('-C',$Item.Path,'rev-parse','--verify','HEAD')).Text.Trim()
    $mainHead=(Get-CleanupGit @('-C',$Item.Repo.Main,'rev-parse','--verify','HEAD')).Text.Trim()
    $sym=Get-CleanupGit @('-C',$Item.Path,'symbolic-ref','-q','HEAD') $null @(0,1)
    if ($sym.Code -eq 1) {
        $retained=Test-CleanupDetachedRetention $Item $head $mainHead
        if ($retained) { return $retained }
    }
    $flags=@(Get-CleanupNul (Get-CleanupGit @('-C',$Item.Path,'ls-files','-v','--stage','-z')).Text)
    $bits=@($flags | Where-Object { $_[0] -cmatch '[a-z]' -or $_[0] -ceq 'S' })
    if ($bits.Count) { return (@($bits | ForEach-Object { $path=$_.Substring($_.IndexOf("`t")+1); if ($_[0] -ceq 'S') { 'skip-worktree ' + $path } else { 'assume-unchanged ' + $path } }) -join '; ') }
    $sparse=Get-CleanupGit @('-C',$Item.Path,'config','--bool','--get','core.sparseCheckout') $null @(0,1)
    if ($sparse.Text.Trim() -eq 'true') { return 'sparse-checkout enabled' }
    $sparsePath=(Get-CleanupGit @('-C',$Item.Path,'rev-parse','--path-format=absolute','--git-path','info/sparse-checkout')).Text.TrimEnd("`r","`n")
    if (Test-CleanupExists $sparsePath) { return 'sparse-checkout state ' + $sparsePath }
    $base=if ($head -ceq $mainHead) { $head } else { (Get-CleanupGit @('-C',$Item.Repo.Main,'merge-base',$head,$mainHead)).Text.Trim() }
    if (-not $base) { return 'missing merge-base' }
    $proof=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $status=@(Get-CleanupNul (Get-CleanupGit @('-C',$Item.Path,'status','--porcelain=v1','-z','-uall')).Text)
    for ($n=0;$n -lt $status.Count;$n++) {
        if ($status[$n].Length -lt 4) { throw 'unparseable status' }
        [void]$proof.Add($status[$n].Substring(3))
        if ($status[$n].Substring(0,2) -match '[RC]') { $n++; if ($n -ge $status.Count) { throw 'unparseable rename' }; [void]$proof.Add($status[$n]) }
    }
    # Porcelain's XY columns include every staged/index difference; hidden bits
    # have already been refused. Add committed changes from the merge base.
    if ($base -cne $head) { foreach ($p in @(Get-CleanupNul (Get-CleanupGit @('-C',$Item.Path,'diff','--name-only','-z','--no-renames',$base,$head)).Text)) { [void]$proof.Add($p) } }
    $ignored=@(Get-CleanupNul (Get-CleanupGit @('-C',$Item.Path,'ls-files','--others','--ignored','--exclude-standard','-z')).Text)
    foreach ($p in $ignored) { if (-not (Test-CleanupDisposable $p)) { return 'ignored non-cache file ' + $p } }
    $index=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($flag in $flags) {
        $record=$flag.Substring(2)
        $tab=$record.IndexOf("`t"); if ($tab -lt 0) { throw 'unparseable index' }; $m=$record.Substring(0,$tab).Split(' '); $p=$record.Substring($tab+1)
        if ($m[2] -ne '0') { return 'unmerged index stages ' + $p }
        if ($m[0] -notin @('100644','100755')) { return 'unsupported file type/submodule ' + $p }
        $index[$p]=$m[1]
    }
    if (-not $proof.Count) { return $null }
    $tree=Get-CleanupTree $Item.Repo.Main $mainHead
    $toHash=[Collections.ArrayList]::new(); $relevant=[Collections.ArrayList]::new()
    foreach ($p in $proof) {
        if (-not $index.ContainsKey($p) -and (Test-CleanupDisposable $p -ScratchOnly)) { continue }
        [void]$relevant.Add($p)
        if ($tree.ContainsKey($p) -and $tree[$p].Mode -notin @('100644','100755')) { return 'unsupported HEAD file type ' + $p }
        $expected=if ($tree.ContainsKey($p)) { $tree[$p].Hash } else { $null }
        if ($index.ContainsKey($p) -and $index[$p] -cne $expected) { return 'index differs from main HEAD ' + $p }
        $fp=Join-Path $Item.Path $p
        if (Test-CleanupExists $fp) {
            $a=Get-CleanupAttributes $fp
            if ($a -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) { return 'unsupported working file type ' + $p }
            [void]$toHash.Add($p)
        } elseif (-not $index.ContainsKey($p) -and $expected) { return 'working content absent from main HEAD path ' + $p }
    }
    if ($toHash.Count) {
        $quoted=@($toHash | ForEach-Object { ConvertTo-CleanupGitQuoted $_ }) -join "`n"
        $hashes=@((Get-CleanupGit @('-C',$Item.Path,'hash-object','--stdin-paths') ([Text.Encoding]::UTF8.GetBytes($quoted+"`n"))).Text.TrimEnd("`r","`n") -split '\r?\n')
        if ($hashes.Count -ne $toHash.Count) { throw 'unavailable working content proof' }
        for ($n=0;$n -lt $toHash.Count;$n++) {
            $p=[string]$toHash[$n]
            if (-not $tree.ContainsKey($p) -or $hashes[$n] -cne $tree[$p].Hash) { return 'Git-stored working content differs from main HEAD ' + $p }
        }
    }
    # Verify all main proof blobs exist without lazy fetching (one batch).
    $oids=@($relevant | Where-Object { $tree.ContainsKey($_) } | ForEach-Object { $tree[$_].Hash } | Select-Object -Unique)
    if ($oids.Count) {
        $check=(Get-CleanupGit @('-C',$Item.Repo.Main,'cat-file','--batch-check') ([Text.Encoding]::ASCII.GetBytes(($oids -join "`n")+"`n"))).Text
        if ($check -match '(?m) missing\r?$') { throw ('missing proof object: ' + $check.Trim()) }
    }
    return $null
}
function Test-CleanupBranch {
    param($Item,$Context,[switch]$ForMissing)
    if (-not $Item.Owned) { return 'unknown owner' }
    if ($Item.Repo.Missing) { Set-CleanupVerdict $Item 'GONE' 'recorded repository absent'; return $null }
    if ($Item.Repo.Error) { throw $Item.Repo.Error }
    if ($Item.Path -cnotmatch '^refs/heads/codex/.+') { return 'not a recorded codex/* branch ' + $Item.Path }
    if ($Item.Path -ceq $Item.Repo.MainBranch) { return 'main checkout current branch ' + $Item.Path }
    $reason=Get-CleanupInactivityReason $Item $Context; if ($reason) { return $reason }
    $r=Get-CleanupGit @('-C',$Item.Repo.Main,'rev-parse','--verify','--quiet',$Item.Path) $null @(0,1)
    if ($r.Code -eq 1) { Set-CleanupVerdict $Item 'GONE' 'recorded ref absent'; return $null }
    $tip=$r.Text.Trim(); if (-not $tip) { throw 'unavailable branch tip' }
    foreach ($w in (Get-CleanupItemIndex $Context).BranchProofs[(Get-CleanupBranchKey $Item.Repo $Item.Path)]) {
        if ($w.Class -ne 'worktree' -or -not $w.Repo -or -not (Test-CleanupEqual $w.Repo.Main $Item.Repo.Main) -or -not $w.Branch) { continue }
        $ref='refs/heads/' + ($w.Branch -replace '^refs/heads/','')
        if ($ref -ceq $Item.Path -and -not $ForMissing -and ($w.Verdict -eq 'FAILED' -or ($w.Verdict -eq 'KEEP' -and ($w.Registration -or $w.Quarantine -or (Test-CleanupExists $w.Path))))) { return 'branch associated with ' + $w.Verdict + ' worktree ' + $w.Path }
    }
    foreach ($reg in $Item.Repo.Registrations) {
        if ($reg.Branch -cne $Item.Path) { continue }
        $key=ConvertTo-CleanupPath $reg.Path
        if (-not $Context.Items.ContainsKey($key)) { return 'branch checked out by main or unknown worktree ' + $reg.Path }
        $w=$Context.Items[$key]
        if (-not $ForMissing -and $w.Verdict -in @('KEEP','FAILED')) { return 'branch checked out by ' + $w.Verdict + ' worktree ' + $w.Path }
        if ($ForMissing -and (Test-CleanupExists $w.Path)) { return 'branch checked out by surviving worktree ' + $w.Path }
    }
    $main=(Get-CleanupGit @('-C',$Item.Repo.Main,'rev-parse','--verify','HEAD')).Text.Trim()
    if ($tip -ceq $main) { return $null }
    $r=Get-CleanupGit @('-C',$Item.Repo.Main,'merge-base','--is-ancestor',$tip,$main) $null @(0,1)
    if ($r.Code -eq 0) { return $null }
    $base=(Get-CleanupGit @('-C',$Item.Repo.Main,'merge-base',$tip,$main)).Text.Trim()
    if (-not $base) { return 'missing merge-base for branch ' + $Item.Path }
    $paths=@(Get-CleanupNul (Get-CleanupGit @('-C',$Item.Repo.Main,'diff','--name-only','-z','--no-renames',$base,$tip)).Text)
    $tipTree=Get-CleanupTree $Item.Repo.Main $tip; $mainTree=Get-CleanupTree $Item.Repo.Main $main
    foreach ($p in $paths) {
        if ($tipTree.ContainsKey($p) -ne $mainTree.ContainsKey($p)) { return 'unique committed path ' + $p }
        if ($tipTree.ContainsKey($p) -and ($tipTree[$p].Hash -cne $mainTree[$p].Hash -or $tipTree[$p].Mode -cne $mainTree[$p].Mode)) { return 'unique committed path ' + $p }
    }
    return $null
}
function Test-CleanupRunDirectory {
    param($Item,$Context)
    if (-not (Test-CleanupExists $Item.Path)) { Set-CleanupVerdict $Item 'GONE' 'run directory absent'; return $null }
    if (-not $Item.Owned) { return 'unknown owner' }
    $reasons=[Collections.ArrayList]::new()
    $r=Get-CleanupInactivityReason $Item $Context; if ($r) { [void]$reasons.Add($r) }
    $r=Test-CleanupDeletionBoundary $Item $Context; if ($r) { [void]$reasons.Add($r) }
    $s=$Item.Sources[0]; $d=$s.Data
    if (-not $d.status -or -not $d.teardown -or -not $d.teardown.status -or -not $d.PSObject.Properties['tasks']) { [void]$reasons.Add('unverifiable run/teardown status or attempts') }
    foreach ($task in @($d.tasks)) { if (-not $task.PSObject.Properties['attempts']) { [void]$reasons.Add('unverifiable task attempts') } }
    $seenChildren=@{}
    foreach ($child in (Get-CleanupItemIndex $Context).EngineChildren[((ConvertTo-CleanupPath $s.Root).ToLowerInvariant()+'|'+$d.run_id)]) {
        if ($seenChildren.ContainsKey($child.Key)) { continue }; $seenChildren[$child.Key]=$true
        if ($child.Class -notin @('worktree','branch')) { continue }
        if (@($child.Sources | Where-Object { $_.Kind -eq 'engine' -and $_.Data.run_id -ceq $d.run_id -and (Test-CleanupEqual $_.Root $s.Root) }).Count -and $child.Verdict -ne 'GONE' -and -not $child.Removed) { [void]$reasons.Add(('non-GONE item ' + $child.Path)) }
    }
    $complete=$d.status -ceq 'complete' -and $d.teardown.status -ceq 'complete'
    if (-not $d.PSObject.Properties['handoff'] -or -not $d.handoff.PSObject.Properties['recovery_patch']) { [void]$reasons.Add('unverifiable recovery_patch') }
    elseif (-not $complete -and $null -ne $d.handoff.recovery_patch) { [void]$reasons.Add('recovery patch ' + $d.handoff.recovery_patch) }
    if (-not $complete -and -not $r) {
        $stack=New-Object 'Collections.Generic.Stack[string]'; $stack.Push($Item.Path)
        while ($stack.Count) { foreach ($e in @(Get-CleanupEntries $stack.Pop())) {
            if ($e.Reparse) { continue }; if ($e.Directory) { $stack.Push($e.Path) } elseif ($e.Name -like '*.patch') { [void]$reasons.Add(('recovery patch file ' + $e.Path)) }
        } }
    }
    if (([datetime]::UtcNow-[IO.File]::GetLastWriteTimeUtc((ConvertTo-CleanupLiteral $s.Path))).TotalDays -le 14) { [void]$reasons.Add('state younger than 14 days') }
    if (-not $d.base_sha -or -not $d.integration.tip -or -not $Item.Repo -or $Item.Repo.Missing) { [void]$reasons.Add('unverifiable integration tip/base/main repository') }
    elseif ($Item.Repo.Error) { throw $Item.Repo.Error }
    else {
        $tip=[string]$d.integration.tip
        if ($d.integration.branch) {
            $ref='refs/heads/' + ([string]$d.integration.branch -replace '^refs/heads/','')
            $live=Get-CleanupGit @('-C',$Item.Repo.Main,'rev-parse','--verify','--quiet',$ref) $null @(0,1)
            if ($live.Code -eq 0) { $tip=$live.Text.Trim() }
        }
        if ($tip -notmatch '^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$') { [void]$reasons.Add('unverifiable integration tip'); return $reasons -join '; ' }
        [void](Get-CleanupGit @('-C',$Item.Repo.Main,'cat-file','-e',($tip+'^{commit}')))
        if ($tip -cne [string]$d.base_sha) {
            $main=(Get-CleanupGit @('-C',$Item.Repo.Main,'rev-parse','--verify','HEAD')).Text.Trim()
            $a=Get-CleanupGit @('-C',$Item.Repo.Main,'merge-base','--is-ancestor',$tip,$main) $null @(0,1)
            if ($a.Code -ne 0) { [void]$reasons.Add(('non-integrated tip ' + $tip)) }
        }
    }
    if ($reasons.Count) { return $reasons -join '; ' }; return $null
}
function Get-CleanupScopeTag { param([string]$Path)
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $s=(ConvertTo-CleanupPath $Path).Replace('\','/').TrimEnd('/').ToLowerInvariant()
        return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))).Replace('-','').Substring(0,10).ToLowerInvariant()
    } finally { $sha.Dispose() }
}
function Get-CleanupScopeIndex { param($Context)
    if ($Context.PSObject.Properties['ScopeIndex'] -and $null -ne $Context.ScopeIndex) { return ,$Context.ScopeIndex }
    $index=New-CleanupPathMap
    if (-not $Context.PSObject.Properties['ScopeMemo']) { $Context | Add-Member NoteProperty ScopeMemo (New-CleanupPathMap) }
    $memo=$Context.ScopeMemo
    foreach ($w in (Get-CleanupItemIndex $Context).Classes.worktree) {
        foreach ($form in $w.Aliases) {
            $key=ConvertTo-CleanupPath $form
            if (-not $memo.ContainsKey($key)) { $memo[$key]=Get-CleanupScopeTag $form }
            Add-CleanupIndexValue $index ('apex-scope-'+$memo[$key]) ([pscustomobject]@{ Worktree=$w; Form=$form })
        }
    }
    $Context | Add-Member NoteProperty ScopeIndex $index -Force
    return ,$index
}
function Get-CleanupProtectedScopes { param($Context)
    if ($Context.PSObject.Properties['ProtectedScopes'] -and $null -ne $Context.ProtectedScopes) { return ,$Context.ProtectedScopes }
    $tags=Get-CleanupScopeIndex $Context; $protected=New-CleanupPathMap; $protects=@{}
    foreach ($tag in $tags.Keys) {
        foreach ($entry in $tags[$tag]) {
            $w=$entry.Worktree
            if (-not $protects.ContainsKey($w.Key)) {
                $protects[$w.Key]=(-not $w.Removed -and $w.Verdict -ne 'GONE' -and ($w.Verdict -in @('KEEP','FAILED') -or @(Get-CleanupItemUsers $w $Context).Count))
            }
            if ($protects[$w.Key]) { $protected[$tag]='protected worktree '+$w.Path+'; path form '+$entry.Form; break }
        }
    }
    $Context | Add-Member NoteProperty ProtectedScopes $protected -Force
    return ,$protected
}
function Set-CleanupRemoved { param($Item)
    $Item.Removed=$true
    if ($Item.Class -eq 'worktree') { Reset-CleanupScopeProof $Item.Snapshot }
}
function Test-CleanupTempDirectory {
    param($Item,$Context)
    if (-not (Test-CleanupExists $Item.Path)) { Set-CleanupVerdict $Item 'GONE' 'temp directory absent'; return $null }
    $r=Test-CleanupDeletionBoundary $Item $Context; if ($r) { return $r }
    $name=[IO.Path]::GetFileName($Item.Path)
    if ($name.StartsWith('apex-scope-')) {
        $protected=Get-CleanupProtectedScopes $Context
        if ($protected.ContainsKey($name)) { return $protected[$name] }
        $stack=New-Object 'Collections.Generic.Stack[string]'; $stack.Push($Item.Path)
        while ($stack.Count) { foreach ($e in @(Get-CleanupEntries $stack.Pop())) {
            if ($e.Reparse) { continue }
            if ($e.Directory) { $stack.Push($e.Path) }
            elseif (([datetime]::UtcNow-$e.LastWriteTimeUtc).TotalDays -le 7) { return 'recent scope file ' + $e.Path }
        } }
    } elseif (([datetime]::UtcNow-[IO.Directory]::GetLastWriteTimeUtc((ConvertTo-CleanupLiteral $Item.Path))).TotalHours -lt $Context.Age) { return 'temp younger than MinAgeHours' }
    return $null
}
function Set-CleanupProof { param($Item,$Context)
    if ($Item.Class -eq 'quarantine' -or $Item.Removed) { return }
    Set-CleanupVerdict $Item 'KEEP' 'not proven'
    try {
        $r=switch ($Item.Class) {
            'worktree' { Test-CleanupWorktree $Item $Context }
            'branch' { Test-CleanupBranch $Item $Context }
            'history' { Test-CleanupRunDirectory $Item $Context }
            'temp' { Test-CleanupTempDirectory $Item $Context }
        }
        if ($r) { Set-CleanupVerdict $Item 'KEEP' ([string]$r) }
        elseif ($Item.Verdict -ne 'GONE') { Set-CleanupVerdict $Item 'SAFE' 'inactivity, ownership, boundary and retained-content proof passed' }
    } catch { Set-CleanupVerdict $Item 'KEEP' ('proof error: ' + $_.Exception.Message); Add-CleanupError $Context $Item.Reason }
}
function Set-CleanupAllProofs { param($Context)
    foreach ($class in @('worktree','branch','history','temp')) {
        $ix=Get-CleanupItemIndex $Context
        if ($class -eq 'temp') { [void](Get-CleanupProtectedScopes $Context) }
        foreach ($i in @($ix.Classes[$class] | Sort-Object Path)) { Set-CleanupProof $i $Context }
    }
}
function Set-CleanupDetachProof { param($Item,$Context)
    if ($Item.Class -eq 'temp' -and [IO.Path]::GetFileName($Item.Path).StartsWith('apex-scope-')) {
        # Only matching path forms can protect this scope tag. Other temp classes
        # need containment and age, never Git content proofs for every worktree.
        $seen=@{}
        foreach ($entry in (Get-CleanupScopeIndex $Context)[[IO.Path]::GetFileName($Item.Path)]) {
            $w=$entry.Worktree
            if ($w.Removed -or $seen.ContainsKey($w.Key)) { continue }; $seen[$w.Key]=$true
            Set-CleanupProof $w $Context
        }
        [void](Get-CleanupProtectedScopes $Context)
    } elseif ($Item.Class -eq 'history') {
        # An existing child is enough to retain history; only absent children need
        # their GONE proof. Never assume proposed deletions will succeed.
        foreach ($w in @($Context.Items.Values | Where-Object { $_.Class -in @('worktree','branch') -and -not $_.Removed })) {
            if ($w.Class -eq 'branch' -or -not (Test-CleanupExists $w.Path)) { Set-CleanupProof $w $Context }
        }
    }
    Set-CleanupProof $Item $Context
}
function Invoke-CleanupLedgerLock { param($Item,[scriptblock]$Action)
    $mutex=$null; $held=$false
    try {
        Send-CleanupLockNotification 'before-lock' $Item
        $mutex=Open-CleanupMutex (Get-CleanupMutexName)
        try { $held=Wait-CleanupMutex $mutex } catch [Threading.AbandonedMutexException] { $held=$true }
        if (-not $held) { Set-CleanupVerdict $Item 'KEEP' 'lock unavailable: 30-second ledger mutex timeout'; return }
        $script:CleanupSession.LockHeld=$true
        Reset-CleanupScopeProof $script:CleanupSession.Context
        Send-CleanupLockNotification 'after-lock' $Item
        & $Action
    } finally {
        if ($script:CleanupSession) { Reset-CleanupScopeProof $script:CleanupSession.Context }
        $script:CleanupSession.LockHeld=$false
        if ($held) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}
function Get-CleanupFresh { param($Original)
    $s=$script:CleanupSession
    $fresh=Get-CleanupInventory $s.StateRoots $s.Ledger $s.Temp $s.Age
    foreach ($current in @($fresh.Items.Values)) {
        if (-not $s.Context.Items.ContainsKey($current.Key)) { continue }
        $old=$s.Context.Items[$current.Key]
        if ($old.Removed -and $fresh.Items.ContainsKey($old.Key)) { Set-CleanupRemoved $fresh.Items[$old.Key]; Set-CleanupVerdict $fresh.Items[$old.Key] 'GONE' 'removed this invocation' }
        if ($old.Verdict -eq 'FAILED' -and $fresh.Items.ContainsKey($old.Key)) { Set-CleanupVerdict $fresh.Items[$old.Key] 'FAILED' $old.Reason }
        if ($old.Quarantine -and -not $old.Removed -and $fresh.Items.ContainsKey($old.Key)) {
            $fresh.Items[$old.Key].Quarantine=$old.Quarantine
            Set-CleanupVerdict $fresh.Items[$old.Key] $old.Verdict $old.Reason
        }
    }
    foreach ($err in $fresh.Errors) { Add-CleanupError $s.Context $err }
    if ($fresh.BadRecords) { $s.Context.BadRecords=$true; throw 'record source unreadable/malformed; mutations suppressed' }
    return $fresh
}
function Assert-CleanupWritableDestination { param([string]$Path,$Context,[switch]$Journal)
    $p=ConvertTo-CleanupPath $Path
    Test-CleanupAncestry ([IO.Path]::GetDirectoryName($p))
    if (Test-CleanupExists $p) {
        $a=Get-CleanupAttributes $p
        if ($a -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) { throw ('unsafe output destination ' + $p) }
        if (-not $Journal) { throw ('report destination already exists ' + $p) }
    }
    if ((Get-CleanupRowIndex $Context).Inputs.ContainsKey($p)) { throw 'output overlaps protected input' }
    foreach ($root in @($Context.RepoPaths.Values | ForEach-Object { $_.Main })) {
        if ((Test-CleanupEqual $p $root) -or (Test-CleanupUnder $p $root)) { throw ('output overlaps main checkout ' + $root) }
    }
    # Preserve inventory order when more than one containing item can protect it.
    $containers=@{}; $ancestor=$p
    while ($ancestor) {
        if ($Context.Items.ContainsKey($ancestor)) { $containers[$ancestor]=$true }
        $ancestor=[IO.Path]::GetDirectoryName($ancestor)
    }
    if ($containers.Count) {
        foreach ($i in (Get-CleanupItemIndex $Context).Containers) {
            if ($containers.ContainsKey($i.Path)) { throw ('output overlaps cleanup item ' + $i.Path) }
        }
    }
    if (-not $Journal) {
        foreach ($root in $Context.Roots) {
            if ((Test-CleanupEqual $p (Join-Path $root 'cleanup/journal.jsonl')) -or (Test-CleanupEqual $p (Join-Path $root 'progress/codex-run-ledger.jsonl'))) { throw 'report overlaps protected journal/ledger' }
        }
    }
}
function Add-CleanupJournal { param($Record,$Context)
    $s=$script:CleanupSession
    $p=Join-Path $s.Primary 'cleanup/journal.jsonl'
    Assert-CleanupWritableDestination $p $Context -Journal
    [void][IO.Directory]::CreateDirectory((ConvertTo-CleanupLiteral ([IO.Path]::GetDirectoryName($p))))
    $text=($Record | ConvertTo-Json -Compress -Depth 20)+"`n"
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes($text)
    $stream=New-Object IO.FileStream((ConvertTo-CleanupLiteral $p),[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $s.Mutated=$true
}
function Get-CleanupQuarantineRecord { param($Item,[string]$Path,[string]$Action='quarantine',[string]$Previous)
    $r=[ordered]@{ utc=[datetime]::UtcNow.ToString('o'); action=$Action; original_path=$Item.Path; quarantine_path=$Path; class=$(if ($Item.Class -eq 'worktree' -and -not $Item.Registration) { 'orphan' } else { $Item.Class }) }
    if ($Previous) { $r.previous_quarantine_path=$Previous }
    if ($Item.Repo) { $r.repo=$Item.Repo.Main }; if ($Item.Branch) { $r.branch=$Item.Branch }
    $ids=@($Item.Sources | ForEach-Object { $_.Data.run_id } | Where-Object { $_ } | Select-Object -Unique)
    if ($ids.Count) { $r.run_ids=$ids }
    $spec=@($Item.Sources | ForEach-Object { if ($_.Kind -eq 'engine') { $_.Data.spec.name } else { $_.Data.spec } } | Where-Object { $_ } | Select-Object -Unique)
    if ($spec.Count) { $r.spec=$spec -join ', ' }
    return $r
}
function Get-CleanupQuarantinePath { param($Item,[string]$Kind='quarantine')
    $parent=[IO.Path]::GetDirectoryName($Item.Path); $prefix=''
    if ($Item.Class -eq 'worktree') {
        $pn=[IO.Path]::GetFileName($parent)
        if ($pn -notmatch '(?i)(-wt|-worktrees)$' -and $pn -ine '.claude-wt') { $prefix=[IO.Path]::GetFileName($Item.Path) }
    }
    return Join-Path $parent ($prefix+'.apex-cleanup-'+$Kind+'-'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString())
}
function Invoke-CleanupAclRetry {
    param([string]$Directory,$Item,$Context,[string]$ActualRoot,[switch]$Owner)
    $s=$script:CleanupSession
    if (-not $s -or -not $s.Apply -or $s.LockHeld -or $s.Trip -or $Context.BadRecords) { throw 'ACL repair unavailable' }
    if ($Item.Class -eq 'quarantine' -and -not $Owner) { throw 'earlier quarantine cannot be ACL repaired' }
    if (-not (Test-CleanupEqual $Directory $ActualRoot) -and -not (Test-CleanupUnder $Directory $ActualRoot)) { throw 'ACL directory outside eligible item' }
    if (Test-CleanupProtected $Directory $Context) { throw 'ACL directory is a protected root' }
    Test-CleanupAncestry $Directory
    $fresh=Get-CleanupGuardSnapshot $Context; Assert-CleanupGuard $fresh
    if ($Owner) { $reason=Test-CleanupDeletionBoundary $Item $fresh -Owner }
    else {
        # Repair authorizes only this verified directory, never recursive ACL tools.
        $parent=[IO.Path]::GetDirectoryName($Item.Path)
        if ($Item.Class -eq 'worktree') {
            $pn=[IO.Path]::GetFileName($parent); $rn=[IO.Path]::GetFileName($Item.Repo.Main)
            if ($pn -notmatch '(?i)(-wt|-worktrees)$' -and $pn -ine '.claude-wt' -and -not ((Test-CleanupEqual $parent ([IO.Path]::GetDirectoryName($Item.Repo.Main))) -and ([IO.Path]::GetFileName($Item.Path) -match ('^(?i)'+[regex]::Escape($rn)+'-(wt|codex)-')))) { throw 'ACL worktree boundary unavailable' }
        } elseif ($Item.Class -eq 'history') {
            if (-not (Test-CleanupEqual $parent $Item.Root) -or [IO.Path]::GetFileName($Item.Path) -notmatch '^[0-9a-fA-F]{32}$') { throw 'ACL history boundary unavailable' }
        } elseif ($Item.Class -eq 'temp') { if (-not (Test-CleanupEqual $parent $fresh.Temp)) { throw 'ACL temp boundary unavailable' } }
        else { throw 'ACL item boundary unavailable' }
        $reason=Get-CleanupInactivityReason $Item $fresh
    }
    if ($reason) { throw $reason }
    if (-not $Owner) {
        # Inspect all accessible boundaries again before changing permissions.
        # Skip denied directories; each gets its own verified, single-directory repair.
        $reason=Test-CleanupDeletionBoundary $Item $fresh $ActualRoot -InspectionRetryDirectory $Directory
        if ($reason) { throw ('CLEANUP_KEEP: '+$reason) }
    }
    $who=[Security.Principal.WindowsIdentity]::GetCurrent()
    try { $user=$who.Name } finally { $who.Dispose() }
    $r=Invoke-CleanupAclCommand 'takeown.exe' @('/f',$Directory)
    if ($r.Code -ne 0) { throw ('takeown failed: '+$r.Error) }
    $s.Mutated=$true; [void]$s.AclChanges.Add($Item.Path + ' : ' + $Directory)
    Assert-CleanupGuard (Get-CleanupGuardSnapshot $Context)
    $r=Invoke-CleanupAclCommand 'icacls.exe' @($Directory,'/grant',($user+':F'))
    if ($r.Code -ne 0) { throw ('icacls failed: '+$r.Error) }
}
function Get-CleanupGuardSnapshot { param($Context,$Focus)
    # Refresh every record source without executing Git or re-enumerating the temp tree.
    $fresh=[pscustomobject]@{ Rows=([Collections.ArrayList]::new()); Runs=([Collections.ArrayList]::new()); Roots=$Context.Roots
        Temp=$Context.Temp; Age=$Context.Age; Items=(New-CleanupPathMap); Repos=$Context.Repos; RepoPaths=$Context.RepoPaths
        Errors=([Collections.ArrayList]::new()); BadRecords=$false }
    $ix=Get-CleanupItemIndex $Context
    foreach ($class in @('worktree','branch','history','quarantine')) { foreach ($i in $ix.Classes[$class]) { $fresh.Items[$i.Key]=$i } }
    if ($Focus) { $fresh.Items[$Focus.Key]=$Focus }
    $paths=New-CleanupPathMap; foreach ($root in $Context.Roots) { $paths[(Join-Path $root 'progress/codex-run-ledger.jsonl')]=$root }; $paths[$script:CleanupSession.Ledger]=$null
    foreach ($path in $paths.Keys) { foreach ($row in @(Read-CleanupLines $fresh $path $paths[$path] 'ledger')) { [void]$fresh.Rows.Add($row) } }
    foreach ($root in $Context.Roots) {
        try {
            if (-not (Test-CleanupExists $root)) { continue }
            foreach ($e in @(Get-CleanupEntries $root)) {
                if (-not $e.Directory -or $e.Reparse -or $e.Name -notmatch '^[a-fA-F0-9]{32}$') { continue }
                $p=Join-Path $e.Path 'engine-state.json'; if (-not (Test-CleanupExists $p)) { continue }
                $data=Read-CleanupEngineData $p
                if (-not $data.run_id -or -not $data.repo) { throw 'malformed engine-state' }
                [void]$fresh.Runs.Add([pscustomobject]@{ Kind='engine'; Root=$root; Path=$p; Data=$data })
            }
        } catch { Add-CleanupError $fresh ('record refresh failed: '+$_.Exception.Message) -Records }
    }
    # Newly recorded nested paths must block deletion even before a Git registration exists.
    foreach ($source in (@($fresh.Rows)+@($fresh.Runs))) {
        $pathsToCheck=@($source.Data.teardown_worktree,$source.Data.worktree,$source.Data.worktree_key,$source.Data.integration.worktree)
        foreach ($t in @($source.Data.tasks)) { foreach ($a in @($t.attempts)) { $pathsToCheck+=,$a.worktree } }
        foreach ($p in $pathsToCheck) { if ($p) { [void](New-CleanupItem $fresh 'worktree' (ConvertTo-CleanupPath $p) $null $null $null) } }
    }
    if ($fresh.BadRecords) { throw 'record source unreadable/malformed during deletion' }
    return $fresh
}
function Assert-CleanupDeletion { param($Item,[string]$ActualRoot,[switch]$Owner,[switch]$Shallow)
    $s=$script:CleanupSession
    if (-not $s) { return } # Standalone walker used to dispose of a test-owned root.
    if ($s.LockHeld) { throw 'recursive deletion attempted under ledger mutex' }
    $fresh=Get-CleanupGuardSnapshot $s.Context $Item
    Assert-CleanupGuard $fresh -Completion:([bool]($Item.Quarantine -and -not $Owner))
    foreach ($old in @(Get-CleanupContainedItems $s.Context $Item.Path $ActualRoot)) {
        if ($old.Key -eq $Item.Key -or $old.Class -eq 'branch' -or $old.Removed) { continue }
        if ((Test-CleanupUnder $old.Path $Item.Path) -or (Test-CleanupUnder $old.Path $ActualRoot)) { throw ('contains repository or kept item '+$old.Path) }
    }
    $r=Test-CleanupDeletionBoundary $Item $fresh $ActualRoot -Owner:$Owner -Shallow:$Shallow
    if ($r) { throw ('CLEANUP_KEEP: '+$r) }
}
function Remove-CleanupDirectoryBottomUp {
    param([string]$Path,$Item,$Context,[string]$ActualRoot,[switch]$Owner,[switch]$Walking)
    if (-not $ActualRoot) { $ActualRoot=$Path }
    # One fresh guard/containment snapshot and full pre-scan per quarantine.
    # Walking checks only local boundaries; retries repeat the full validation.
    if ($Item -and -not $Walking) { Assert-CleanupDeletion $Item $ActualRoot -Owner:$Owner }
    if (-not (Test-CleanupExists $Path)) { return }
    if ($Item) { Test-CleanupAncestry $Path }
    $attrs=Get-CleanupAttributes $Path
    if ($attrs -band [IO.FileAttributes]::ReparsePoint) {
        # Do not clear attributes, inspect children or repair permissions on links.
        if ($attrs -band [IO.FileAttributes]::Directory) { Invoke-CleanupMutation 'directory' $Path }
        else { Invoke-CleanupMutation 'file' $Path }
        return
    }
    try { $entries=@(Get-CleanupEntries $Path) }
    catch {
        if (-not $Item -or -not (Test-CleanupAccessDenied $_)) { throw }
        Invoke-CleanupAclRetry $Path $Item $Context $ActualRoot -Owner:$Owner
        Assert-CleanupDeletion $Item $ActualRoot -Owner:$Owner
        $entries=@(Get-CleanupEntries $Path)
    }
    foreach ($entry in $entries) {
        if ($Item -and -not $Owner) {
            $relative=$entry.Path.Substring($ActualRoot.Length).TrimStart('\','/')
            if ($entry.Name -ieq '.git' -and -not ($Item.Class -eq 'worktree' -and -not $entry.Directory -and -not $entry.Reparse -and (Test-CleanupEqual $Path $ActualRoot))) { throw ('CLEANUP_KEEP: contains repository or kept item '+$entry.Path) }
            if ($entry.Directory -and $entry.Name -match '\.apex-cleanup-(quarantine|failed)-\d{8}T\d{6}Z-') { throw ('CLEANUP_KEEP: contains repository or kept item '+$entry.Path) }
            if ($entry.Reparse -and -not (Test-CleanupDisposable ($relative+$(if ($entry.Directory) { '/link' } else { '' })))) { throw ('CLEANUP_KEEP: reparse point '+$entry.Path) }
        }
        if ($entry.Directory -and -not $entry.Reparse) { Remove-CleanupDirectoryBottomUp $entry.Path $Item $Context $ActualRoot -Owner:$Owner -Walking; continue }
        if (-not $entry.Reparse -and ($entry.Attributes -band [IO.FileAttributes]::ReadOnly)) { Invoke-CleanupMutation 'writable' $entry.Path }
        $operation=if ($entry.Directory) { 'directory' } else { 'file' }
        # File access denial is not permission to repair an arbitrary stderr path.
        try { Invoke-CleanupMutation $operation $entry.Path }
        catch {
            if ($entry.Reparse -or -not $Item -or -not (Test-CleanupAccessDenied $_)) { throw }
            Invoke-CleanupAclRetry $Path $Item $Context $ActualRoot -Owner:$Owner
            Assert-CleanupDeletion $Item $ActualRoot -Owner:$Owner
            Invoke-CleanupMutation $operation $entry.Path
        }
    }
    if ($Item) { Test-CleanupAncestry $Path }
    $attrs=Get-CleanupAttributes $Path
    if ($attrs -band [IO.FileAttributes]::ReparsePoint) { throw ('directory changed to reparse point '+$Path) }
    if ($attrs -band [IO.FileAttributes]::ReadOnly) { Invoke-CleanupMutation 'writable' $Path }
    try { Invoke-CleanupMutation 'directory' $Path }
    catch {
        if (-not $Item -or -not (Test-CleanupAccessDenied $_)) { throw }
        Invoke-CleanupAclRetry $Path $Item $Context $ActualRoot -Owner:$Owner
        Assert-CleanupDeletion $Item $ActualRoot -Owner:$Owner
        Invoke-CleanupMutation 'directory' $Path
    }
}
function Get-CleanupPruneSet { param($Repo,$Context)
    $r=Get-CleanupGit @('-C',$Repo.Main,'worktree','prune','--dry-run','--expire','now','--verbose')
    $text=$r.Text + $r.Error
    $map=@{}; $admin=Join-Path $Repo.Common 'worktrees'
    if (Test-CleanupExists $admin) {
        foreach ($e in @(Get-CleanupEntries $admin)) {
            if (-not $e.Directory -or $e.Reparse) { continue }
            $p=Join-Path $e.Path 'gitdir'
            if (Test-CleanupExists $p) {
                $pointer=[IO.File]::ReadAllText((ConvertTo-CleanupLiteral $p)).TrimEnd("`r","`n")
                $map[$e.Name]=ConvertTo-CleanupPath ([IO.Path]::GetDirectoryName($pointer))
                $map[('worktrees/'+$e.Name)]=$map[$e.Name]
            }
        }
    }
    foreach ($line in @($text -split '\r?\n' | Where-Object { $_ })) {
        if ($line -notmatch '^Removing (.+?): .+$' -or -not $map.ContainsKey($Matches[1])) { throw ('unparseable prune dry-run: ' + $line) }
        $path=$map[$Matches[1]]
        if (-not $Context.Items.ContainsKey($path) -or $Context.Items[$path].Verdict -ne 'SAFE') { throw ('prune would affect unproven registration ' + $path) }
        $Context.Items[$path]
    }
}
function Undo-CleanupQuarantine { param($Item,$Context,[string]$Reason,[switch]$Policy)
    try {
        Invoke-CleanupMutation 'rename' $Item.Quarantine $Item.Path
        $Item.Quarantine=$null
        Set-CleanupVerdict $Item $(if ($Policy) { 'KEEP' } else { 'FAILED' }) $Reason
    } catch {
        $rollback=$_.Exception.Message; $old=$Item.Quarantine; $failed=Get-CleanupQuarantinePath $Item 'failed'
        $journaled=$false
        try {
            Add-CleanupJournal (Get-CleanupQuarantineRecord $Item $failed 'failed-rollback' $old) $Context
            $journaled=$true
            Invoke-CleanupMutation 'rename' $old $failed; $Item.Quarantine=$failed
            Set-CleanupVerdict $Item 'FAILED' ($Reason + '; rollback failed: ' + $rollback + '; retained ' + $failed)
        } catch {
            Set-CleanupVerdict $Item $(if ($journaled) { 'FAILED' } else { 'KEEP' }) ($Reason + '; rollback failed: ' + $rollback + '; journal/failed-rollback rename error: ' + $_.Exception.Message + '; retained ' + $old)
        }
        Add-CleanupError $Context $Item.Reason
    }
}
function Set-CleanupLockedDetach {
    param($Item,$Context,$fresh)
    $s=$script:CleanupSession
    Assert-CleanupGuard $fresh
    if (-not $fresh.Items.ContainsKey($Item.Key)) { Set-CleanupVerdict $Item 'GONE' 'absent on locked reproof'; return }
    # Worktree verdicts precede branch/history verdicts. No proof crosses a lock boundary.
    $live=$fresh.Items[$Item.Key]
    Set-CleanupDetachProof $live $fresh
    foreach ($err in $fresh.Errors) { Add-CleanupError $Context $err }
    if ($live.Verdict -ne 'SAFE') { Set-CleanupVerdict $Item $live.Verdict ('reproof: ' + $live.Reason); return }
    $Item.Repo=$live.Repo; $Item.Registration=$live.Registration
    if ($Item.Class -eq 'branch') {
        foreach ($reg in $live.Repo.Registrations) { if ($reg.Branch -ceq $Item.Path) { Set-CleanupVerdict $Item 'KEEP' ('branch still checked out ' + $reg.Path); return } }
        foreach ($w in (Get-CleanupItemIndex $fresh).BranchProofs[(Get-CleanupBranchKey $live.Repo $Item.Path)]) {
            if ($w.Class -eq 'worktree' -and $w.Repo -and (Test-CleanupEqual $w.Repo.Main $live.Repo.Main) -and $w.Branch -and ('refs/heads/'+($w.Branch -replace '^refs/heads/','')) -ceq $Item.Path -and -not $w.Removed -and (Test-CleanupExists $w.Path)) { Set-CleanupVerdict $Item 'KEEP' ('associated worktree not successfully removed ' + $w.Path); return }
        }
        Assert-CleanupGuard (Get-CleanupGuardSnapshot $fresh)
        [void](Get-CleanupGit @('-C',$live.Repo.Main,'branch','-D','--',($Item.Path.Substring(11))))
        $s.Mutated=$true; Set-CleanupRemoved $Item
        Set-CleanupVerdict $Item 'SAFE' 'proven branch removed under mutex'
        [void]$s.DetachGroups.Add(('branch ' + $Item.Path)); return
    }
    # Repeat the guard at the actual detach, after the potentially long content proof.
    Assert-CleanupGuard (Get-CleanupGuardSnapshot $fresh)
    if (Test-CleanupExists $Item.Path) {
        $q=Get-CleanupQuarantinePath $Item
        try { Add-CleanupJournal (Get-CleanupQuarantineRecord $Item $q) $fresh }
        catch { Set-CleanupVerdict $Item 'KEEP' ('journal error: ' + $_.Exception.Message); Add-CleanupError $Context $Item.Reason; return }
        Invoke-CleanupMutation 'rename' $Item.Path $q
        $Item.Quarantine=$q; $s.Mutated=$true
    }
    if ($Item.Class -eq 'worktree' -and $Item.Registration) {
        try {
            # Evaluate *all* prune candidates inside this same hold. A renamed worktree
            # retains its just-completed proof; other candidates receive a fresh proof.
            $pruneContext=Get-CleanupFresh $Item
            foreach ($w in (Get-CleanupItemIndex $pruneContext).Classes.worktree) {
                if ($w.Key -eq $Item.Key) { Set-CleanupVerdict $w 'SAFE' 'proven immediately before rename under this mutex' }
                else { Set-CleanupProof $w $pruneContext }
            }
            $set=@(Get-CleanupPruneSet $Item.Repo $pruneContext)
            if (-not @($set | Where-Object { $_.Key -eq $Item.Key }).Count) { throw 'prune dry-run did not authorize selected registration' }
            Assert-CleanupGuard $pruneContext
            [void](Get-CleanupGit @('-C',$Item.Repo.Main,'worktree','prune','--expire','now'))
            $remaining=@(Get-CleanupRegistrations $Item.Repo.Main)
            if (@($remaining | Where-Object { Test-CleanupEqual $_.Path $Item.Path }).Count -or (Test-CleanupExists $Item.Path)) {
                if ($Item.Quarantine) { Undo-CleanupQuarantine $Item $Context 'registration/original directory persists after prune' }
                else { Set-CleanupVerdict $Item 'FAILED' 'registration persists after prune' }
                Add-CleanupError $Context $Item.Reason; return
            }
            $paths=@($set | ForEach-Object { $_.Path })
            [void]$s.DetachGroups.Add(('prune registrations [' + ($paths -join '; ') + ']'))
            foreach ($other in $set) {
                if ($other.Key -eq $Item.Key -or -not $Context.Items.ContainsKey($other.Key)) { continue }
                $o=$Context.Items[$other.Key]
                if (@($remaining | Where-Object { Test-CleanupEqual $_.Path $other.Path }).Count -or (Test-CleanupExists $other.Path)) {
                    Set-CleanupVerdict $o 'FAILED' 'registration/original directory persists after grouped prune'; Add-CleanupError $Context $o.Reason; continue
                }
                Set-CleanupRemoved $o; Set-CleanupVerdict $o 'SAFE' 'redundant missing registration pruned in proven group'
            }
        } catch {
            $msg=$_.Exception.Message
            if ($msg.StartsWith('CLEANUP_GUARD:')) {
                if ($Item.Quarantine) { Undo-CleanupQuarantine $Item $Context 'guard tripped before registration detach; rename rolled back' -Policy }
                throw
            }
            if ($Item.Quarantine) { Undo-CleanupQuarantine $Item $Context $msg -Policy:($msg.StartsWith('prune would affect unproven registration')) }
            else { Set-CleanupVerdict $Item 'KEEP' $msg }
            if (-not $msg.StartsWith('prune would affect unproven registration')) { Add-CleanupError $Context $Item.Reason }
            return
        }
    } else { [void]$s.DetachGroups.Add(($Item.Class + ' ' + $Item.Path)) }
    Set-CleanupVerdict $Item 'SAFE' 'detached after fresh proof'
    if (-not $Item.Quarantine) { Set-CleanupRemoved $Item; $Item.Reason='redundant missing registration pruned' }
    Send-CleanupLockNotification 'after-detach' $Item
}
function Remove-CleanupItem {
    param($Item,$Context)
    $s=$script:CleanupSession
    $action={ Set-CleanupLockedDetach $Item $Context (Get-CleanupFresh $Item) }
    try {
        if ($Item.Reason -notlike '*inspection repair required outside mutex*') { Invoke-CleanupLedgerLock $Item $action }
        if ($Item.Reason -like '*inspection repair required outside mutex*' -and -not $s.Trip) {
            # The lock budget never includes permission repair. Inspect once
            # outside it, then acquire a new hold and repeat the entire proof.
            $inspection=Get-CleanupFresh $Item
            if ($inspection.Items.ContainsKey($Item.Key)) {
                $candidate=$inspection.Items[$Item.Key]; Set-CleanupDetachProof $candidate $inspection
                Set-CleanupVerdict $Item $candidate.Verdict $candidate.Reason
                foreach ($err in $inspection.Errors) { Add-CleanupError $Context $err }
                if ($candidate.Verdict -eq 'SAFE') { Invoke-CleanupLedgerLock $Item $action }
            }
        }
    } catch {
        if ($_.Exception.Message.StartsWith('CLEANUP_GUARD:')) { throw }
        Set-CleanupVerdict $Item $(if ($Item.Quarantine) { 'FAILED' } else { 'KEEP' }) ('detach error: ' + $_.Exception.Message)
        Add-CleanupError $Context $Item.Reason
    }
    if ($Item.Quarantine -and $Item.Verdict -eq 'SAFE') { Complete-CleanupQuarantine $Item $Context }
}
function Remove-CleanupTempBatch { param([object[]]$Items,$Context)
    $s=$script:CleanupSession
    $batch=[pscustomobject]@{ Started=$false; Next=0 }
    while ($batch.Next -lt $Items.Count -and -not $s.Trip -and -not $Context.BadRecords) {
        $batch.Started=$false; $first=$batch.Next
        $repairs=New-Object Collections.ArrayList
        try {
            Invoke-CleanupLedgerLock $Items[$first] {
                $batch.Started=$true
                # One full snapshot and new proof indexes per hold; parsed documents
                # are reused only after comparing freshly read bytes.
                $fresh=Get-CleanupFresh $Items[$first]
                # Inventory time is outside the item-processing budget.
                $started=Get-CleanupMonotonicSeconds
                [void](Get-CleanupProtectedScopes $fresh)
                while ($batch.Next -lt $Items.Count) {
                    if ($s.Trip -or $Context.BadRecords) { break }
                    if ($batch.Next -gt $first -and (Get-CleanupMonotonicSeconds)-$started -ge $script:CleanupTempBatchSeconds) { break }
                    $item=$Items[$batch.Next]
                    try {
                        Set-CleanupLockedDetach $item $Context $fresh
                        if ($item.Reason -like '*inspection repair required outside mutex*') { [void]$repairs.Add($item) }
                    } catch {
                        if ($_.Exception.Message.StartsWith('CLEANUP_GUARD:')) { throw }
                        Set-CleanupVerdict $item $(if ($item.Quarantine) { 'FAILED' } else { 'KEEP' }) ('detach error: '+$_.Exception.Message)
                        Add-CleanupError $Context $item.Reason
                        if ($Context.BadRecords -or $_.Exception.Message.StartsWith('record source unreadable/malformed')) { throw }
                    }
                    $batch.Next++
                }
            }
            if (-not $batch.Started) {
                foreach ($item in $Items[$first..($Items.Count-1)]) { Set-CleanupVerdict $item 'KEEP' $Items[$first].Reason }
                break
            }
        } catch {
            if (-not $_.Exception.Message.StartsWith('CLEANUP_GUARD:')) {
                for ($j=$batch.Next; $j -lt $Items.Count; $j++) {
                    if (-not $Items[$j].Quarantine) { Set-CleanupVerdict $Items[$j] 'KEEP' ('detach error: '+$_.Exception.Message) }
                }
            }
            throw
        } finally {
            # Even a guard trip finishes earlier successful detaches outside the lock.
            foreach ($item in $Items) {
                if ($item.Quarantine -and -not $item.Removed -and $item.Verdict -eq 'SAFE') { Complete-CleanupQuarantine $item $Context }
            }
        }
        foreach ($item in $repairs) {
            if ($s.Trip -or $Context.BadRecords) { break }
            # Reuse the per-item unlocked inspection, then a fresh locked reproof.
            Remove-CleanupItem $item $Context
        }
    }
}
function Complete-CleanupQuarantine { param($Item,$Context)
    try {
        Remove-CleanupDirectoryBottomUp $Item.Quarantine $Item $Context $Item.Quarantine
        if (Test-CleanupExists $Item.Quarantine) { throw 'quarantine still exists' }
        Set-CleanupRemoved $Item; Set-CleanupVerdict $Item 'SAFE' 'proven item quarantined and removed; recursive deletion outside mutex'
    } catch {
        $message=$_.Exception.Message
        if ($message.StartsWith('CLEANUP_KEEP:') -or $message -match 'contains repository or kept item|reparse point') { Set-CleanupVerdict $Item 'KEEP' ('retained ' + $Item.Quarantine + ': ' + $message) }
        else { Set-CleanupVerdict $Item 'FAILED' ('removal failed; retained ' + $Item.Quarantine + ': ' + $message); Add-CleanupError $Context $Item.Reason }
    }
}
function Remove-CleanupNamedQuarantines { param([string[]]$Names,$Context)
    $s=$script:CleanupSession; $unique=New-CleanupPathMap
    foreach ($name in $Names) {
        try { $p=ConvertTo-CleanupPath $name; $unique[$p]=$p }
        catch { Add-CleanupError $Context ('not an inventoried quarantine ' + $name) }
    }
    foreach ($p in @($unique.Values | Sort-Object)) {
        if ($s.Trip) { break }
        if (-not $Context.Items.ContainsKey($p) -or $Context.Items[$p].Class -ne 'quarantine') {
            $i=New-CleanupItem $Context 'quarantine' $p $null $null $null
            Set-CleanupVerdict $i 'KEEP' 'not an inventoried quarantine'; Add-CleanupError $Context ($i.Reason + ' ' + $p); continue
        }
        $i=$Context.Items[$p]
        $fresh=Get-CleanupGuardSnapshot $Context; Assert-CleanupGuard $fresh
        try { $reason=Test-CleanupDeletionBoundary $i $fresh -Owner }
        catch { $reason=$_.Exception.Message }
        if ($reason) { Set-CleanupVerdict $i 'KEEP' ('not an inventoried quarantine: ' + $reason); Add-CleanupError $Context $i.Reason; continue }
        try {
            # The named path is the owner's content authorization; no content proof occurs.
            Remove-CleanupDirectoryBottomUp $p $i $Context $p -Owner
            $s.Mutated=$true; Set-CleanupRemoved $i; Set-CleanupVerdict $i 'SAFE' 'owner authorized removal completed (no content proof)'
        } catch {
            if ($_.Exception.Message.StartsWith('CLEANUP_GUARD:')) { throw }
            $s.Mutated=$true; Set-CleanupVerdict $i 'FAILED' ('owner authorized removal failed: ' + $_.Exception.Message); Add-CleanupError $Context $i.Reason
        }
        try { Add-CleanupJournal ([ordered]@{ action='removed'; utc=[datetime]::UtcNow.ToString('o'); quarantine_path=$p; result=$i.Reason }) $Context }
        catch { Add-CleanupError $Context ('removed journal append error: ' + $_.Exception.Message) }
    }
}
function Write-CleanupReport {
    param($Context,[switch]$WriteFile,[string]$Destination)
    $lines=[Collections.ArrayList]::new()
    foreach ($i in @($Context.Items.Values | Sort-Object Class,Path)) { [void]$lines.Add((ConvertTo-CleanupAscii ($i.Verdict+' '+$i.Class+' '+$i.Path+' -- '+$i.Reason))) }
    foreach ($e in $Context.Errors) { [void]$lines.Add(('ERROR ' + (ConvertTo-CleanupAscii $e))) }
    foreach ($g in @(Get-CleanupGuard $Context)) { [void]$lines.Add(('GUARD ' + (ConvertTo-CleanupAscii $g))) }
    $s=$script:CleanupSession
    if ($s) {
        foreach ($a in $s.AclChanges) { [void]$lines.Add(('ACL CHANGED ' + (ConvertTo-CleanupAscii $a))) }
        foreach ($d in $s.DetachGroups) { [void]$lines.Add(('DETACH GROUP ' + (ConvertTo-CleanupAscii $d))) }
        if ($s.Trip) { [void]$lines.Add(('STOP ' + (ConvertTo-CleanupAscii $s.Trip))) }
    }
    $counts=@(); foreach ($v in @('SAFE','KEEP','GONE','FAILED')) { $counts+=($v+'='+@($Context.Items.Values | Where-Object { $_.Verdict -eq $v }).Count) }
    [void]$lines.Add(('COUNTS ' + ($counts -join ' ')))
    foreach ($line in $lines) { Write-Output $line }
    if ($WriteFile) {
        try {
            Assert-CleanupWritableDestination $Destination $Context
            [void][IO.Directory]::CreateDirectory((ConvertTo-CleanupLiteral ([IO.Path]::GetDirectoryName((ConvertTo-CleanupPath $Destination)))))
            $stream=New-Object IO.FileStream((ConvertTo-CleanupLiteral $Destination),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            try { $bytes=[Text.Encoding]::ASCII.GetBytes(($lines -join "`r`n")+"`r`n"); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
        } catch { $msg='report write failed: '+$_.Exception.Message; Add-CleanupError $Context $msg; Write-Output (ConvertTo-CleanupAscii $msg) }
    }
}
function Start-ApexCleanup {
    [CmdletBinding()]
    param([switch]$Apply,[string[]]$StateRoot=@((Join-Path $env:LOCALAPPDATA 'apex')),[string]$LedgerPath,
        [string]$TempRoot=$env:TEMP,[ValidateRange(0,[double]::MaxValue)][double]$MinAgeHours=24,[string]$ReportPath,[string[]]$RemoveQuarantine)
    $saved=@{}; foreach ($e in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) { if ($e.Key.StartsWith('GIT_',[StringComparison]::OrdinalIgnoreCase)) { $saved[$e.Key]=$e.Value } }
    $previousSession=$script:CleanupSession
    $previousRecordCache=$script:CleanupRecordCache
    $script:CleanupRecordCache=New-CleanupPathMap
    try {
        foreach ($name in @($saved.Keys)) { if ($name -notin @('GIT_CONFIG_NOSYSTEM','GIT_CONFIG_GLOBAL')) { [Environment]::SetEnvironmentVariable($name,$null,'Process') } }
        $env:GIT_NO_LAZY_FETCH='1'; $env:GIT_OPTIONAL_LOCKS='0'
        if ($RemoveQuarantine.Count -and -not $Apply) { Write-Output 'invalid argument: -RemoveQuarantine requires -Apply'; return 1 }
        if (-not $StateRoot.Count) { Write-Output 'invalid argument: StateRoot is empty'; return 1 }
        if (-not $LedgerPath) { $LedgerPath=Join-Path $StateRoot[0] 'progress/codex-run-ledger.jsonl' }
        # Version is always the first Git call, before inventory, proof or mutation.
        try {
            $version=Get-CleanupGit @('version')
            if ($version.Text -notmatch '^git version (\d+)\.(\d+)(?:\.|\s|$)' -or [int]$Matches[1] -lt 2 -or ([int]$Matches[1] -eq 2 -and [int]$Matches[2] -lt 44)) {
                Write-Output (ConvertTo-CleanupAscii ('unsupported Git version (requires 2.44): '+$version.Text.Trim())); return 1
            }
        } catch { Write-Output (ConvertTo-CleanupAscii ('Git version proof failed: '+$_.Exception.Message)); return 1 }
        if ($Apply -and -not (Test-CleanupElevated)) { Write-Output 'Apply requires an administrator token'; return 2 }
        $c=Get-CleanupInventory $StateRoot $LedgerPath $TempRoot $MinAgeHours
        $script:CleanupSession=[pscustomobject]@{ Apply=[bool]$Apply; StateRoots=$StateRoot; Primary=(ConvertTo-CleanupPath $StateRoot[0]); Ledger=$LedgerPath
            Temp=$TempRoot; Age=$MinAgeHours; Context=$c; Mutated=$false; LockHeld=$false; Trip=$null; AclChanges=([Collections.ArrayList]::new()); DetachGroups=([Collections.ArrayList]::new()) }
        $s=$script:CleanupSession
        if ($Apply) {
            try { Assert-CleanupGuard $c } catch { Write-CleanupReport $c; return 2 }
        }
        if ($Apply -and $c.BadRecords) { Write-CleanupReport $c; return 1 }
        if (-not $RemoveQuarantine.Count) { Set-CleanupAllProofs $c }
        else { foreach ($i in $c.Items.Values) { if ($i.Class -ne 'quarantine') { Set-CleanupVerdict $i 'KEEP' 'untouched: owner-removal-only invocation' } } }
        if ($Apply -and -not $c.BadRecords) {
            try {
                if ($RemoveQuarantine.Count) { Remove-CleanupNamedQuarantines $RemoveQuarantine $c }
                else {
                    # Engine groups first, then remaining worktrees/branches, history and temp.
                    $ordered=@($c.Items.Values | Sort-Object @{Expression={ if ($_.Class -in @('worktree','branch') -and @($_.Sources | Where-Object { $_.Kind -eq 'engine' }).Count) { 0 } elseif ($_.Class -eq 'worktree') { 1 } elseif ($_.Class -eq 'branch') { 2 } elseif ($_.Class -eq 'history') { 3 } else { 4 } }},@{Expression={ if ($_.Class -eq 'worktree') { 0 } else { 1 } }},Path)
                    foreach ($i in $ordered) {
                        if ($s.Trip) { break }
                        if ($i.Removed -or $i.Class -in @('quarantine','temp')) { continue }
                        if ($i.Class -eq 'history') {
                            $fresh=Get-CleanupFresh $i
                            if ($fresh.Items.ContainsKey($i.Key)) { $fi=$fresh.Items[$i.Key]; Set-CleanupDetachProof $fi $fresh; Set-CleanupVerdict $i $fi.Verdict $fi.Reason }
                        }
                        if ($i.Verdict -eq 'SAFE') { Remove-CleanupItem $i $c }
                    }
                    $temps=@($ordered | Where-Object { $_.Class -eq 'temp' -and -not $_.Removed })
                    for ($offset=0; $offset -lt $temps.Count -and -not $s.Trip -and -not $c.BadRecords; $offset+=$script:CleanupTempBatchSize) {
                        $last=[math]::Min($offset+$script:CleanupTempBatchSize,$temps.Count)-1
                        Remove-CleanupTempBatch $temps[$offset..$last] $c
                    }
                }
            } catch {
                if (-not $_.Exception.Message.StartsWith('CLEANUP_GUARD:')) { Add-CleanupError $c $_.Exception.Message }
            }
        }
        if ($s.Trip -and -not $s.Mutated) { Write-CleanupReport $c; return 2 }
        if ($s.Trip -and -not $RemoveQuarantine.Count) {
            foreach ($i in $c.Items.Values) { if ($i.Quarantine -and -not $i.Removed -and $i.Verdict -eq 'SAFE') { Complete-CleanupQuarantine $i $c } }
        }
        if ($Apply) {
            if (-not $ReportPath) { $ReportPath=Join-Path $s.Primary ('cleanup/'+[datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'.txt') }
            # A report is itself a mutation; guard it when no earlier change has occurred.
            if (-not $s.Mutated) { try { Assert-CleanupGuard (Get-CleanupGuardSnapshot $c) } catch { Write-CleanupReport $c; return 2 } }
            Write-CleanupReport $c -WriteFile -Destination $ReportPath
        } else { Write-CleanupReport $c }
        if ($s.Trip) { return 2 }
        if ($c.Errors.Count -or @($c.Items.Values | Where-Object { $_.Verdict -eq 'FAILED' }).Count) { return 1 }
        return 0
    } catch { Write-Output (ConvertTo-CleanupAscii ('cleanup input/proof error: '+$_.Exception.Message)); return 1 }
    finally {
        foreach ($e in @([Environment]::GetEnvironmentVariables('Process').Keys)) { if ($e.StartsWith('GIT_',[StringComparison]::OrdinalIgnoreCase)) { [Environment]::SetEnvironmentVariable($e,$null,'Process') } }
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name],'Process') }
        $script:CleanupSession=$previousSession
        $script:CleanupRecordCache=$previousRecordCache
    }
}
if ($MyInvocation.InvocationName -ne '.') {
    $result=@(Start-ApexCleanup @PSBoundParameters)
    if ($result.Count -gt 1) { $result[0..($result.Count-2)] | Write-Output }
    exit [int]$result[-1]
}
