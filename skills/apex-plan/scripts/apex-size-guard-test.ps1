# Real index fixtures plus a byte-emitting Git executable for transport/parser faults.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$guard = Join-Path $PSScriptRoot 'apex-size-guard.ps1'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$scratch = Join-Path $repoRoot '.codex-scratch'
$testRoot = Join-Path $scratch ('size-guard-' + $PID + '-' + [guid]::NewGuid().ToString('N'))
$nonGitParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$nonGitRoot = Join-Path $nonGitParent ('size-guard-non-git-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$git = (Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$powershell = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$failures = New-Object 'Collections.Generic.List[string]'
$checks = 0
$fixtureNumber = 0

function Assert([string]$Name, [bool]$Condition) {
    $script:checks++
    if ($Condition) { Write-Host "PASS: $Name" }
    else { $failures.Add($Name); Write-Host "FAIL: $Name" }
}

function Quote-Argument([string]$Argument) {
    # Windows argv quoting, including a quoted path with trailing backslashes.
    return '"' + [regex]::Replace([regex]::Replace($Argument, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Invoke-Child([string]$Exe, [string[]]$Arguments, [hashtable]$Environment = @{}, [int]$Timeout = 150000) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    $info.Arguments = [string]::Join(' ', [string[]]@($Arguments | ForEach-Object { Quote-Argument $_ }))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    try { $childEnvironment = $info.get_EnvironmentVariables() }
    catch { $childEnvironment = $info.get_EnvironmentVariables() }
    $childEnvironment.Clear()
    foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        $childEnvironment[$entry.Key] = $entry.Value
    }
    foreach ($name in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
        'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_COMMON_DIR', 'GIT_NAMESPACE',
        'GIT_LITERAL_PATHSPECS', 'GIT_GLOB_PATHSPECS', 'GIT_NOGLOB_PATHSPECS', 'GIT_ICASE_PATHSPECS',
        'GIT_CONFIG', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM',
        'GIT_AUTHOR_DATE', 'GIT_COMMITTER_DATE')) { $childEnvironment.Remove($name) }
    $childEnvironment['GIT_CONFIG_NOSYSTEM'] = '1'
    $childEnvironment['GIT_CONFIG_GLOBAL'] = Join-Path $testRoot 'no-global-config'
    $childEnvironment['GIT_OPTIONAL_LOCKS'] = '0'
    $childEnvironment['GIT_NO_LAZY_FETCH'] = '1'
    $childEnvironment['GIT_AUTHOR_DATE'] = '2000-01-01T00:00:00Z'
    $childEnvironment['GIT_COMMITTER_DATE'] = '2000-01-01T00:00:00Z'
    foreach ($name in $Environment.Keys) { $childEnvironment[$name] = $Environment[$name] }
    $process = New-Object Diagnostics.Process
    $stdout = New-Object IO.MemoryStream
    $stderr = New-Object IO.MemoryStream
    try {
        $process.StartInfo = $info
        if (-not $process.Start()) { throw "Could not launch $Exe" }
        $process.StandardInput.Close()
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        if (-not $process.WaitForExit($Timeout)) { throw "Fixture child timed out: $Exe" }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask, $errTask), 5000)) {
            throw 'Fixture stream drain timed out'
        }
        return [pscustomobject]@{
            Code = $process.ExitCode; Out = $utf8.GetString($stdout.ToArray()); Err = $utf8.GetString($stderr.ToArray())
        }
    } finally {
        try { if (-not $process.HasExited) { $process.Kill() } } catch { }
        $process.Dispose(); $stdout.Dispose(); $stderr.Dispose()
    }
}

function Git([string]$Root, [string[]]$Arguments) {
    $result = Invoke-Child $git (@('-C', $Root, '-c', 'protocol.allow=never',
        '-c', 'user.name=Size Guard Test', '-c', 'user.email=size-guard@example.invalid') + $Arguments) @{} 30000
    if ($result.Code -ne 0) { throw "Fixture Git failed: $($Arguments -join ' '): $($result.Err)" }
    return $result.Out.TrimEnd([char]13, [char]10)
}

function Write-File([string]$Root, [string]$Path, [string]$Content) {
    $fullPath = Join-Path $Root $Path
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
    [IO.File]::WriteAllText($fullPath, $Content, $utf8)
}

function Stage-File([string]$Root, [string]$Path) {
    $blob = Git $Root @('hash-object', '-w', '--', $Path)
    [void](Git $Root @('update-index', '--add', '--cacheinfo', '100644', $blob, $Path))
    # Cacheinfo alone leaves stat data unset. Refresh for realistic residue counts.
    [void](Git $Root @('update-index', '--refresh'))
}

function Save-Head([string]$Root) {
    $tree = Git $Root @('write-tree')
    $commit = Git $Root @('commit-tree', $tree, '-m', 'Fixture HEAD')
    [void](Git $Root @('update-ref', 'HEAD', $commit))
    return $commit
}

function New-Repo([switch]$Unborn) {
    $script:fixtureNumber++
    $root = Join-Path $testRoot ("repo $fixtureNumber")
    [void][IO.Directory]::CreateDirectory($root)
    [void](Git $root @('init', '--quiet'))
    [void](Git $root @('config', 'core.autocrlf', 'false'))
    [void](Git $root @('config', 'core.excludesFile', (Join-Path $testRoot 'no-excludes')))
    if (-not $Unborn) {
        Write-File $root 'a.txt' "one`ntwo`nthree`n"
        Stage-File $root 'a.txt'
        [void](Save-Head $root)
    }
    return $root
}

function Ps-Literal([string]$Text) { return "'" + $Text.Replace("'", "''") + "'" }

function Guard([string]$Root, [string[]]$Prediction, [string[]]$Options = @(), [hashtable]$Environment = @{}, [switch]$Human) {
    # -EncodedCommand supports a real string array on Windows PowerShell 5.1.
    $command = '$ProgressPreference = ''SilentlyContinue''; & ' + (Ps-Literal $guard) + ' -Repo ' + (Ps-Literal $Root) + ' -Paths @(' +
        [string]::Join(',', [string[]]@($Prediction | ForEach-Object { Ps-Literal $_ })) + ')'
    if (-not $Human) { $command += ' -Json' }
    foreach ($option in $Options) { $command += ' ' + (Ps-Literal $option) }
    # Options must be command tokens, not quoted positional arguments.
    foreach ($name in @('MaxFiles', 'MaxLines')) {
        $command = $command.Replace("'-$name'", "-$name")
    }
    $command += '; exit $LASTEXITCODE'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $result = Invoke-Child $powershell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) $Environment
    Assert 'guard stdout is ASCII' ($result.Out -cnotmatch '[^\x00-\x7f]')
    Assert 'guard stderr is empty' ($result.Err.Length -eq 0)
    if ($result.Err.Length -gt 0) { Write-Host $result.Err }
    $data = $null
    if (-not $Human) { $data = ConvertFrom-Json $result.Out }
    return [pscustomobject]@{ Code = $result.Code; Text = $result.Out; Data = $data }
}

function Check-Result([string]$Name, $Result, [int]$Code, [int]$Files, [long]$Lines, [int]$Unstaged = 0, [int]$Untracked = 0) {
    $verdict = if ($Code -eq 0) { 'WITHIN' } else { 'OVER' }
    Assert "$Name exit/verdict" ($Result.Code -eq $Code -and $Result.Data.verdict -ceq $verdict)
    Assert "$Name staged counts" ($Result.Data.fileCount -eq $Files -and $Result.Data.lineCount -eq $Lines)
    Assert "$Name residue" ($Result.Data.warnings.unstaged -eq $Unstaged -and $Result.Data.warnings.untracked -eq $Untracked)
}

function Fault-Environment([byte[]]$Diff, [byte[]]$Status = $null, [string]$Mode = '') {
    $environment = @{
        Path = $shimDir + ';' + $env:Path; SG_REAL_GIT = $git; SG_MODE = $Mode
        SG_DIFF = [Convert]::ToBase64String($Diff)
    }
    if ($null -ne $Status) { $environment['SG_STATUS'] = [Convert]::ToBase64String($Status) }
    return $environment
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    # Compile a local git.exe. It forwards real commands and substitutes only selected
    # byte streams, so all CLI tests still traverse the production Git transport.
    $shimDir = Join-Path $testRoot 'shim'
    [void][IO.Directory]::CreateDirectory($shimDir)
    Add-Type -OutputAssembly (Join-Path $shimDir 'git.exe') -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;
public static class SizeGuardGitFixture {
    static string Quote(string a) {
        var b = new StringBuilder("\""); int n = 0;
        foreach (char c in a) {
            if (c == '\\') { n++; continue; }
            b.Append('\\', c == '"' ? 2 * n + 1 : n); b.Append(c); n = 0;
        }
        return b.Append('\\', 2 * n).Append('"').ToString();
    }
    static void Emit(string name) {
        byte[] bytes = Convert.FromBase64String(Environment.GetEnvironmentVariable(name));
        Stream s = Console.OpenStandardOutput(); s.Write(bytes, 0, bytes.Length); s.Flush();
    }
    public static int Main(string[] args) {
        string[] forbidden = { "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_LITERAL_PATHSPECS",
            "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS" };
        foreach (string name in forbidden) if (Environment.GetEnvironmentVariable(name) != null) return 90;
        if (Environment.GetEnvironmentVariable("GIT_OPTIONAL_LOCKS") != "0" ||
            Environment.GetEnvironmentVariable("GIT_NO_LAZY_FETCH") != "1") return 91;
        if (args.Length < 5 || args[0] != "-C" || args[2] != "-c" || args[3] != "protocol.allow=never") return 92;
        // Reading until EOF also verifies redirected stdin was closed immediately.
        if (Console.OpenStandardInput().ReadByte() != -1) return 93;
        string mode = Environment.GetEnvironmentVariable("SG_MODE") ?? "";
        if (mode == "fail") { Console.Error.Write("bounded fixture failure"); return 37; }
        if (mode == "hang") { System.Threading.Thread.Sleep(180000); return 0; }
        if (mode == "bad-stderr") {
            Console.OpenStandardError().WriteByte(255); return 0;
        }
        if (args[4] == "diff") {
            string[] expected = { "--cached", "--numstat", "-z", "--find-renames", "--ignore-submodules=none", "HEAD" };
            if (args.Length != 11) return 94;
            for (int i = 0; i < expected.Length; i++) if (args[i + 5] != expected[i]) return 95;
            if (mode == "drain") Console.Error.Write(new string('x', 262144));
            Emit("SG_DIFF"); return 0;
        }
        if (args[4] == "status" && Environment.GetEnvironmentVariable("SG_STATUS") != null) {
            Emit("SG_STATUS"); return 0;
        }
        var p = new Process(); var info = new ProcessStartInfo(Environment.GetEnvironmentVariable("SG_REAL_GIT"));
        string[] quoted = Array.ConvertAll(args, Quote); info.Arguments = string.Join(" ", quoted);
        info.UseShellExecute = false; info.CreateNoWindow = true;
        info.RedirectStandardInput = true; info.RedirectStandardOutput = true; info.RedirectStandardError = true;
        p.StartInfo = info;
        try {
            p.Start(); p.StandardInput.Close();
            Task o = p.StandardOutput.BaseStream.CopyToAsync(Console.OpenStandardOutput());
            Task e = p.StandardError.BaseStream.CopyToAsync(Console.OpenStandardError());
            if (!p.WaitForExit(30000)) { p.Kill(); return 96; }
            if (!Task.WaitAll(new Task[] { o, e }, 5000)) return 97;
            return p.ExitCode;
        } finally { p.Dispose(); }
    }
}
'@

    $root = New-Repo
    Write-File $root 'a.txt' "one`nTWO`nthree`n"
    Stage-File $root 'a.txt'
    $r = Guard $root @('a.txt')
    Check-Result 'staged text/default limits' $r 0 1 2
    Assert 'text per-path counts' ($r.Data.changes[0].added -eq 1 -and $r.Data.changes[0].deleted -eq 1 -and $r.Data.changes[0].lines -eq 2)
    Check-Result 'exact line limit' (Guard $root @('a.txt') @('-MaxLines', '2')) 0 1 2
    Check-Result 'over line limit' (Guard $root @('a.txt') @('-MaxLines', '1')) 1 1 2
    Check-Result 'over file limit' (Guard $root @('a.txt') @('-MaxFiles', '0')) 1 1 2
    $human = Guard $root @('a.txt') @() @{} -Human
    Assert 'human verdict and real counts' ($human.Code -eq 0 -and $human.Text.StartsWith("WITHIN`r`n") -and $human.Text.Contains('fileCount=1') -and $human.Text.Contains('lineCount=2'))

    Write-File $root 'new.txt' "new`nline`n"
    Stage-File $root 'new.txt'
    Check-Result 'new file/file limit' (Guard $root @('a.txt', 'new.txt')) 1 2 4
    Check-Result 'two files allowed' (Guard $root @('a.txt', 'new.txt') @('-MaxFiles', '2')) 0 2 4
    $r = Guard $root @('a.txt') @('-MaxFiles', '2')
    Check-Result 'whole index/outside prediction' $r 1 2 4
    Assert 'excess path list' (@($r.Data.outsidePaths).Count -eq 1 -and $r.Data.outsidePaths[0] -ceq 'new.txt')
    Check-Result 'prediction is case sensitive' (Guard $root @('A.txt', 'new.txt') @('-MaxFiles', '2')) 1 2 4

    # Later working-tree changes and individual untracked files affect warnings only.
    Write-File $root 'a.txt' ("working only`n" * 50)
    Write-File $root 'new.txt' ("unstaged new content`n" * 30)
    Write-File $root 'untracked/x.txt' "x`n"
    Write-File $root 'untracked/y.txt' "y`n"
    Check-Result 'residue excluded' (Guard $root @('a.txt', 'new.txt') @('-MaxFiles', '2')) 0 2 4 2 2

    $nested = New-Repo
    Write-File $nested 'a.txt' "one`nTWO`nthree`n"
    Stage-File $nested 'a.txt'
    $beforeNested = Guard $nested @('a.txt')
    Check-Result 'before nested repository residue' $beforeNested 0 1 2
    Write-File $nested 'sub/untracked.txt' "nested`n"
    [void](Git (Join-Path $nested 'sub') @('init', '--quiet'))
    $nestedStatus = Git $nested @('status', '--porcelain', '-z', '--untracked-files=all')
    Assert 'nested repository produces trailing-slash residue' ($nestedStatus.Contains('?? sub/' + [char]0))
    $r = Guard $nested @('a.txt')
    Check-Result 'nested repository residue is warnings only' $r 0 1 2 0 1
    Assert 'nested residue preserves staged verdict and exit code' ($r.Code -eq $beforeNested.Code -and
        $r.Data.verdict -ceq $beforeNested.Data.verdict -and $r.Data.warnings.untracked -gt 0)

    $rename = New-Repo
    Write-File $rename 'renamed.txt' "one`ntwo`nthree`n"
    Remove-Item -LiteralPath (Join-Path $rename 'a.txt')
    [void](Git $rename @('update-index', '--force-remove', '--', 'a.txt'))
    Stage-File $rename 'renamed.txt'
    $r = Guard $rename @('a.txt', 'renamed.txt')
    Check-Result 'rename counts once/both paths' $r 0 1 0
    Assert 'rename path pair' ($r.Data.paths.Count -eq 2 -and $r.Data.changes[0].oldPath -ceq 'a.txt' -and $r.Data.changes[0].path -ceq 'renamed.txt')
    foreach ($missing in @('a.txt', 'renamed.txt')) {
        $other = if ($missing -eq 'a.txt') { 'renamed.txt' } else { 'a.txt' }
        $r = Guard $rename @($other)
        Check-Result "rename missing $missing" $r 1 1 0
        Assert "rename excess $missing" ($r.Data.outsidePaths[0] -ceq $missing)
    }
    Check-Result 'rename at zero line limit' (Guard $rename @('a.txt', 'renamed.txt') @('-MaxLines', '0')) 0 1 0

    $deleted = New-Repo
    Remove-Item -LiteralPath (Join-Path $deleted 'a.txt')
    [void](Git $deleted @('update-index', '--force-remove', '--', 'a.txt'))
    Check-Result 'staged deletion' (Guard $deleted @('a.txt')) 0 1 3

    $binary = New-Repo
    [IO.File]::WriteAllBytes((Join-Path $binary 'binary.dat'), [byte[]]@(0, 1, 2, 255))
    Stage-File $binary 'binary.dat'
    $r = Guard $binary @('binary.dat')
    Check-Result 'binary is OVER' $r 1 1 0
    Assert 'binary path line count' ($r.Data.changes[0].path -ceq 'binary.dat' -and $r.Data.changes[0].lines -ceq 'binary' -and $r.Data.binaryFileCount -eq 1)
    Write-File $binary 'a.txt' "one`nTWO`nthree`n"
    Stage-File $binary 'a.txt'
    Check-Result 'binary plus text retains real text count' (Guard $binary @('binary.dat', 'a.txt') @('-MaxFiles', '2')) 1 2 2

    $unicode = New-Repo
    $unicodePath = 'caf' + [char]0x00e9 + '-' + [char]0x4e2d + '-' + [char]::ConvertFromUtf32(0x1f642) + '.txt'
    Write-File $unicode $unicodePath "hello`n"
    Stage-File $unicode $unicodePath
    $r = Guard $unicode @($unicodePath)
    Check-Result 'Unicode path' $r 0 1 1
    Assert 'JSON Unicode roundtrip/ASCII escaping' ($r.Data.paths[0] -ceq $unicodePath -and $r.Text.Contains('\u00e9') -and $r.Text.Contains('\u4e2d') -and $r.Text.Contains('\ud83d\ude42'))
    $r = Guard $unicode @('elsewhere.txt')
    Check-Result 'Unicode excess path' $r 1 1 1
    Assert 'Unicode outside prediction roundtrip' ($r.Data.outsidePaths[0] -ceq $unicodePath)
    $human = Guard $unicode @($unicodePath) @() @{} -Human
    Assert 'human Unicode escaping' ($human.Code -eq 0 -and $human.Text.Contains('\u00e9') -and $human.Text.Contains('\ud83d\ude42'))
    $indexPath = Join-Path $unicode '.git/index'
    $indexBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath))
    $indexTime = [IO.File]::GetLastWriteTimeUtc($indexPath)
    $headBefore = Git $unicode @('rev-parse', 'HEAD')
    $r = Guard ($unicode + '\') @($unicodePath)
    Check-Result 'trailing repo separator' $r 0 1 1
    Assert 'guard leaves HEAD and index bytes/timestamp untouched' ($indexBefore -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($indexPath)) -and
        $indexTime -eq [IO.File]::GetLastWriteTimeUtc($indexPath) -and $headBefore -ceq (Git $unicode @('rev-parse', 'HEAD')))
    $metachar = New-Repo
    $metacharPath = "[id] & quote'.txt"
    Write-File $metachar $metacharPath "one`n"
    Stage-File $metachar $metacharPath
    Check-Result 'literal metacharacter path' (Guard $metachar @($metacharPath)) 0 1 1

    # The native -File form must consume multiple prediction arguments and retain
    # exit 2 for argument errors (PowerShell's built-in binder normally returns 1).
    Write-File $metachar 'second.txt' "two`n"
    Stage-File $metachar 'second.txt'
    $native = Invoke-Child $powershell @('-NoProfile', '-File', $guard, '-Repo', $metachar,
        '-Paths', $metacharPath, 'second.txt', '-MaxFiles', '2', '-Json')
    $nativeData = ConvertFrom-Json $native.Out
    Assert 'native CLI multiple Paths' ($native.Code -eq 0 -and $nativeData.fileCount -eq 2 -and $nativeData.paths[0] -ceq $metacharPath)
    foreach ($arguments in @(@('-Json', '-MaxLines'), @('-Json', '-Repo'), @('-Json', '-Unknown'),
        @('-Json', '-Json'), @('-Json', '-MaxFiles', '1', '-MaxFiles', '2'), @('-Repo', '-Json'))) {
        $native = Invoke-Child $powershell (@('-NoProfile', '-File', $guard) + $arguments)
        $nativeData = ConvertFrom-Json $native.Out
        Assert 'native CLI malformed arguments fail closed' ($native.Code -eq 2 -and $nativeData.verdict -ceq 'ERROR')
    }
    $native = Invoke-Child $powershell @('-NoProfile', '-File', $guard, '-Json', '-Repo', $metachar,
        '-Paths', $metacharPath, 'second.txt', '-MaxLinez', '5')
    $nativeData = ConvertFrom-Json $native.Out
    Assert 'unknown flag after Paths fails closed' ($native.Code -eq 2 -and $nativeData.error.Contains('Unexpected argument'))
    $dash = New-Repo
    Write-File $dash '-dash.txt' "dash`n"
    Stage-File $dash '-dash.txt'
    Check-Result 'literal dash path in array' (Guard $dash @('-dash.txt')) 0 1 1
    $native = Invoke-Child $powershell @('-NoProfile', '-File', $guard, '-Json', '-Repo', $dash, '-Paths', '--', '-dash.txt')
    $nativeData = ConvertFrom-Json $native.Out
    Assert 'native CLI literal dash path' ($native.Code -eq 0 -and $nativeData.paths[0] -ceq '-dash.txt')
    foreach ($limits in @('-MaxFiles 1 -MaxLines 10', '-MaxFiles ([long]1) -MaxLines ([uint32]10)', '-MaxLines 1.5')) {
        $command = '$ProgressPreference = ''SilentlyContinue''; & ' + (Ps-Literal $guard) +
            ' -Json -Repo ' + (Ps-Literal $dash) + ' -Paths @(''-dash.txt'') ' + $limits + '; exit $LASTEXITCODE'
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $numeric = Invoke-Child $powershell @('-NoProfile', '-EncodedCommand', $encoded)
        $numericData = ConvertFrom-Json $numeric.Out
        if ($limits -eq '-MaxLines 1.5') {
            Assert 'typed fractional PowerShell limit rejected' ($numeric.Code -eq 2 -and $numericData.verdict -ceq 'ERROR')
        } else {
            Assert 'unquoted integral PowerShell limits accepted' ($numeric.Code -eq 0 -and $numericData.fileCount -eq 1 -and $numericData.lineCount -eq 1)
        }
    }

    $link = New-Repo
    $firstCommit = Git $link @('rev-parse', 'HEAD')
    [void](Git $link @('update-index', '--add', '--cacheinfo', '160000', $firstCommit, 'module'))
    [void](Save-Head $link)
    $secondCommit = Git $link @('rev-parse', 'HEAD')
    [void](Git $link @('update-index', '--cacheinfo', '160000', $secondCommit, 'module'))
    [void](Git $link @('config', 'diff.ignoreSubmodules', 'all'))
    $r = Guard $link @('module')
    Assert 'gitlink measured despite ignoreSubmodules=all' ($r.Code -eq 0 -and $r.Data.fileCount -eq 1 -and $r.Data.lineCount -eq 2 -and $r.Data.paths[0] -ceq 'module')

    $other = New-Repo
    $poison = @{
        GIT_DIR = Join-Path $other '.git'; GIT_INDEX_FILE = Join-Path $other '.git/index'
        GIT_WORK_TREE = $other; GIT_OBJECT_DIRECTORY = Join-Path $other '.git/objects'
        GIT_ALTERNATE_OBJECT_DIRECTORIES = Join-Path $other '.git/objects'; GIT_COMMON_DIR = Join-Path $other '.git'
        GIT_NAMESPACE = 'wrong'; GIT_LITERAL_PATHSPECS = '1'; GIT_GLOB_PATHSPECS = '1'
        GIT_NOGLOB_PATHSPECS = '1'; GIT_ICASE_PATHSPECS = '1'; GIT_OPTIONAL_LOCKS = '1'; GIT_NO_LAZY_FETCH = '0'
    }
    Check-Result 'parent repository variables ignored' (Guard $unicode @($unicodePath) @() $poison) 0 1 1

    $clean = New-Repo
    Write-File $clean 'a.txt' "unstaged`n"
    Write-File $clean 'untracked.txt' "untracked`n"
    $r = Guard $clean @('a.txt')
    Assert 'zero staged changes despite residue' ($r.Code -eq 2 -and $r.Data.error.Contains('no staged changes'))
    $unborn = New-Repo -Unborn
    Write-File $unborn 'new.txt' "new`n"
    Stage-File $unborn 'new.txt'
    $r = Guard $unborn @('new.txt')
    Assert 'unborn HEAD fails closed' ($r.Code -eq 2 -and $r.Data.verdict -ceq 'ERROR')

    foreach ($prediction in @('', '/absolute', '../outside', 'dir/../file', './a.txt', 'dir//file', 'dir\file', 'C:relative')) {
        $r = Guard $unicode @($prediction)
        Assert "invalid prediction $prediction" ($r.Code -eq 2)
    }
    foreach ($options in @(@('-MaxFiles', '-1'), @('-MaxLines', '1.5'), @('-MaxFiles', '9223372036854775808'), @('-MaxLines', 'abc'), @('-MaxLines', "1`n"))) {
        $r = Guard $unicode @($unicodePath) $options
        Assert "invalid limits $($options -join ' ')" ($r.Code -eq 2)
    }
    $r = Guard 'relative' @('a.txt')
    Assert 'relative repo rejected' ($r.Code -eq 2)
    [void][IO.Directory]::CreateDirectory($nonGitRoot)
    $r = Guard $nonGitRoot @('a.txt') @() @{ GIT_CEILING_DIRECTORIES = $nonGitParent }
    Assert 'non-Git directory rejected' ($r.Code -eq 2)
    $r = Guard (Join-Path $testRoot 'missing') @('a.txt')
    Assert 'nonexistent repo rejected' ($r.Code -eq 2)
    $r = Guard $unicode @()
    Assert 'missing Paths rejected' ($r.Code -eq 2)

    $nul = [string][char]0
    $valid = $utf8.GetBytes("1`t0`ta.txt" + $nul)
    $renameChain = "0`t0`t${nul}a.txt${nul}b.txt${nul}0`t0`t${nul}b.txt${nul}c.txt$nul"
    $r = Guard $unicode @('a.txt', 'b.txt', 'c.txt') @('-MaxFiles', '2') (Fault-Environment $utf8.GetBytes($renameChain) ([byte[]]@()))
    Check-Result 'rename rows sharing source/destination path' $r 0 2 0
    Assert 'shared rename path is listed once' ($r.Data.paths.Count -eq 3)
    $faults = [ordered]@{
        'negative count' = "-1`t0`ta.txt$nul"
        'nonnumeric count' = "x`t0`ta.txt$nul"
        'count with newline' = "1`n`t0`ta.txt$nul"
        'mixed binary counts' = "-`t0`ta.txt$nul"
        'count overflow' = "9223372036854775808`t0`ta.txt$nul"
        'row sum overflow' = "9223372036854775807`t1`ta.txt$nul"
        'missing NUL' = "1`t0`ta.txt"
        'missing TAB' = "1`ta.txt$nul"
        'empty record' = $nul
        'trailing garbage' = "1`t0`ta.txt${nul}garbage"
        'rename missing destination' = "0`t0`t${nul}a.txt$nul"
        'rename empty source' = "0`t0`t${nul}${nul}b.txt$nul"
        'duplicate path' = "1`t0`ta.txt${nul}1`t0`ta.txt$nul"
        'total overflow' = "9223372036854775807`t0`ta.txt${nul}1`t0`tb.txt$nul"
    }
    foreach ($name in $faults.Keys) {
        $r = Guard $unicode @('a.txt', 'b.txt') @() (Fault-Environment $utf8.GetBytes($faults[$name]))
        Assert "malformed numstat: $name" ($r.Code -eq 2 -and $r.Data.verdict -ceq 'ERROR')
    }
    foreach ($bad in @([byte[]]@(255), [byte[]]@(195, 40), [byte[]]@(237, 160, 128))) {
        $bytes = [byte[]]($utf8.GetBytes("1`t0`t") + $bad + @(0))
        $r = Guard $unicode @('a.txt') @() (Fault-Environment $bytes)
        Assert 'invalid UTF-8 numstat path' ($r.Code -eq 2)
    }
    $bytes = [byte[]]($utf8.GetBytes("0`t0`t${nul}a.txt${nul}") + @(255, 0))
    $r = Guard $unicode @('a.txt') @() (Fault-Environment $bytes)
    Assert 'invalid UTF-8 rename destination' ($r.Code -eq 2)
    foreach ($status in @(' M a.txt', "x! a.txt$nul", "R  new.txt$nul", "?? $nul")) {
        $r = Guard $unicode @('a.txt') @() (Fault-Environment $valid $utf8.GetBytes($status))
        Assert 'malformed status fails closed' ($r.Code -eq 2)
    }
    $statusBytes = [byte[]]($utf8.GetBytes('?? ') + @(255, 0))
    $r = Guard $unicode @('a.txt') @() (Fault-Environment $valid $statusBytes)
    Assert 'invalid UTF-8 status path' ($r.Code -eq 2)

    # Synthetic paths include characters unavailable in Windows filenames.
    $escapedPath = 'quote"slash\tab' + [char]9 + 'line' + [char]10 + [char]0x00e9
    # Backslashes are not canonical repo-relative separators on this platform.
    $escapedPath = $escapedPath.Replace('\', '')
    $r = Guard $unicode @($escapedPath) @() (Fault-Environment $utf8.GetBytes("1`t0`t$escapedPath$nul") ([byte[]]@()))
    Check-Result 'JSON special characters' $r 0 1 1
    Assert 'JSON control/quote roundtrip' ($r.Data.paths[0] -ceq $escapedPath -and $r.Text.Contains('\t') -and $r.Text.Contains('\n') -and $r.Text.Contains('\"'))
    $human = Guard $unicode @($escapedPath) @() (Fault-Environment $utf8.GetBytes("1`t0`t$escapedPath$nul") ([byte[]]@())) -Human
    Assert 'human control characters escaped' ($human.Code -eq 0 -and $human.Text.Contains('\t') -and $human.Text.Contains('\n') -and $human.Text.Contains('\"'))

    $environment = Fault-Environment $valid ([byte[]]@())
    foreach ($name in $poison.Keys) { $environment[$name] = $poison[$name] }
    Check-Result 'transport environment/stdin/command contract' (Guard $unicode @('a.txt') @() $environment) 0 1 1
    foreach ($extension in @('cmd', 'bat')) {
        $batchDir = Join-Path $testRoot ('shim-' + $extension)
        $batch = '@echo off' + "`r`n" + (Quote-Argument (Join-Path $shimDir 'git.exe')) + ' %*' +
            "`r`n" + 'exit /b %errorlevel%' + "`r`n"
        Write-File $batchDir ('git.' + $extension) $batch
        $batchEnvironment = Fault-Environment $valid ([byte[]]@())
        $batchEnvironment['Path'] = $batchDir + ';' + $env:Path
        Check-Result "$extension shim transport contract" (Guard $unicode @('a.txt') @() $batchEnvironment) 0 1 1
    }
    Check-Result 'concurrent large stderr drain' (Guard $unicode @('a.txt') @() (Fault-Environment $valid ([byte[]]@()) 'drain')) 0 1 1
    $r = Guard $unicode @('a.txt') @() (Fault-Environment $valid ([byte[]]@()) 'bad-stderr')
    Assert 'invalid UTF-8 stderr fails closed' ($r.Code -eq 2)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $r = Guard $unicode @('a.txt') @() (Fault-Environment $valid ([byte[]]@()) 'fail')
    Assert 'bounded Git nonzero failure' ($r.Code -eq 2 -and $r.Data.error.Contains('37') -and $timer.Elapsed.TotalSeconds -lt 20)
    $r = Guard $unicode @('a.txt') @() @{ Path = $shimDir + '\missing' }
    Assert 'Git launch failure' ($r.Code -eq 2)
    Write-Output 'Testing the fixed 120-second Git timeout...'
    $timer.Restart()
    $r = Guard $unicode @('a.txt') @() (Fault-Environment $valid ([byte[]]@()) 'hang')
    Assert 'Git timeout exits 2 within bound' ($r.Code -eq 2 -and $r.Data.error.Contains('timed out') -and $timer.Elapsed.TotalSeconds -ge 120 -and $timer.Elapsed.TotalSeconds -lt 145)
    $shimPath = Join-Path $shimDir 'git.exe'
    Assert 'timed-out Git child killed' (@(Get-Process -Name git -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $shimPath }).Count -eq 0)

    foreach ($path in @($guard, $PSCommandPath)) {
        Assert 'source file is ASCII-only' (@([IO.File]::ReadAllBytes($path) | Where-Object { $_ -gt 127 }).Count -eq 0)
    }
} catch {
    $failures.Add($_.Exception.ToString())
    Write-Output "FAIL: $($_.Exception.Message) at $($_.InvocationInfo.PositionMessage)"
} finally {
    # Only remove this invocation's verified descendant of the sanctioned scratch root.
    $absolute = [IO.Path]::GetFullPath($testRoot)
    $allowed = [IO.Path]::GetFullPath($scratch).TrimEnd([char]92) + '\'
    if (-not $absolute.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    if (Test-Path -LiteralPath $absolute) { Remove-Item -LiteralPath $absolute -Recurse -Force }
    $nonGitAbsolute = [IO.Path]::GetFullPath($nonGitRoot)
    $tempAllowed = $nonGitParent.TrimEnd([char]92) + '\'
    if (-not $nonGitAbsolute.StartsWith($tempAllowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe non-Git fixture cleanup path' }
    if (Test-Path -LiteralPath $nonGitAbsolute) { Remove-Item -LiteralPath $nonGitAbsolute -Recurse -Force }
}

if ($failures.Count -gt 0) {
    Write-Output "$($failures.Count) failure(s) in $checks checks:"
    $failures | ForEach-Object { Write-Output $_ }
    exit 1
}
Write-Output "All $checks size-guard checks passed."
exit 0
