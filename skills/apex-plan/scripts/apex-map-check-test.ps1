# Hermetic CLI integration fixtures for Windows PowerShell 5.1.
# All writes, including Git plumbing, are confined to .codex-scratch below the build repo.
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$checker = Join-Path $PSScriptRoot 'apex-map-check.ps1'
$buildRepo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$scratch = Join-Path $buildRepo '.codex-scratch'
$testRoot = Join-Path $scratch ('map-check-' + [Guid]::NewGuid().ToString('N'))
$gitExe = (Get-Command git.exe -CommandType Application | Select-Object -First 1).Source
$psExe = (Get-Command powershell.exe -CommandType Application | Select-Object -First 1).Source
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$script:count = 0
$suiteExit = 1

function Quote-Argument([string]$Value) {
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($c in $Value.ToCharArray()) {
        if ($c -eq [char]92) { $slashes++; continue }
        if ($c -eq [char]34) { [void]$builder.Append([char]92, (2 * $slashes + 1)) }
        else { [void]$builder.Append([char]92, $slashes) }
        [void]$builder.Append($c)
        $slashes = 0
    }
    [void]$builder.Append([char]92, (2 * $slashes))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Run-Process([string]$Exe, [string[]]$Arguments, [hashtable]$Overrides = @{}, [int]$Timeout = 20000) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Exe
    $info.Arguments = (@($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    try { $childEnv = $info.get_EnvironmentVariables() }
    catch { $childEnv = $info.get_EnvironmentVariables() }
    $childEnv.Clear()
    foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) { $childEnv[$entry.Key] = $entry.Value }
    foreach ($key in @($childEnv.Keys)) {
        if ($key -like 'GIT_*') { $childEnv.Remove($key) }
    }
    $childEnv['GIT_CONFIG_NOSYSTEM'] = '1'
    $childEnv['GIT_CONFIG_GLOBAL'] = Join-Path $testRoot 'empty-config'
    $childEnv['GIT_TERMINAL_PROMPT'] = '0'
    $childEnv['GIT_AUTHOR_NAME'] = 'Map Test'
    $childEnv['GIT_AUTHOR_EMAIL'] = 'map-test@example.invalid'
    $childEnv['GIT_COMMITTER_NAME'] = 'Map Test'
    $childEnv['GIT_COMMITTER_EMAIL'] = 'map-test@example.invalid'
    foreach ($key in $Overrides.Keys) { $childEnv[$key] = $Overrides[$key] }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $outStream = New-Object IO.MemoryStream
    $errStream = New-Object IO.MemoryStream
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) { throw 'Fixture process failed to start.' }
        $process.StandardInput.Close()
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($outStream)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($errStream)
        while (-not ($process.HasExited -and $outTask.IsCompleted -and $errTask.IsCompleted)) {
            if ($timer.ElapsedMilliseconds -ge $Timeout) { throw "Fixture process exceeded ${Timeout}ms." }
            [Threading.Thread]::Sleep(10)
        }
        [void]$outTask.GetAwaiter().GetResult()
        [void]$errTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            Code = $process.ExitCode
            Out = $utf8.GetString($outStream.ToArray()).Replace("`r`n", "`n").TrimEnd([char]10)
            Err = $utf8.GetString($errStream.ToArray())
            Milliseconds = $timer.ElapsedMilliseconds
        }
    } finally {
        try { if (-not $process.HasExited) { $process.Kill() } } catch { }
        $process.Dispose()
        $outStream.Dispose()
        $errStream.Dispose()
    }
}

function Git([string]$Repo, [string[]]$Arguments) {
    $r = Run-Process $gitExe (@('-C', $Repo, '-c', 'protocol.allow=never', '-c', 'core.autocrlf=false') + $Arguments)
    if ($r.Code -ne 0) { throw "Fixture Git exit $($r.Code): $($Arguments -join ' '): $($r.Err)" }
    return $r.Out
}

function Put([string]$Repo, [string]$Path, [string]$Text) {
    $full = Join-Path $Repo $Path
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    [IO.File]::WriteAllText($full, $Text, $utf8)
}

function New-Repo([string]$Name) {
    $repo = Join-Path $testRoot $Name
    [void][IO.Directory]::CreateDirectory($repo)
    [void](Git $repo @('init', '-q'))
    return $repo
}

# Build real trees and commits with plumbing; no add, commit, checkout, or reset.
function Save-Tree([string]$Repo, [hashtable]$Files, [string]$Parent = '', [switch]$Detached) {
    [void](Git $Repo @('read-tree', '--empty'))
    foreach ($path in $Files.Keys) {
        Put $Repo $path $Files[$path]
        $blob = Git $Repo @('hash-object', '-w', '--', (Join-Path $Repo $path))
        [void](Git $Repo @('update-index', '--add', '--cacheinfo', '100644', $blob, $path))
    }
    $tree = Git $Repo @('write-tree')
    $arguments = @('commit-tree', $tree, '-m', 'fixture')
    if ($Parent) { $arguments += @('-p', $Parent) }
    $sha = Git $Repo $arguments
    if (-not $Detached) { [void](Git $Repo @('update-ref', 'HEAD', $sha)) }
    return $sha
}

function Header([string]$Name, [string]$Covers, [string]$Sha, [string]$Contracts = '', [string]$Seams = '') {
    return "## $Name`n<!-- apex:map-section covers: $Covers contracts: $Contracts seams: $Seams verified: $Sha -->`n"
}

function Check([string]$Name, [string]$Repo, [string[]]$Arguments, [int]$Code, [string]$Output = '',
        [hashtable]$Overrides = @{}, [int]$Timeout = 20000) {
    $r = Run-Process $psExe (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checker, '-Repo', $Repo) + $Arguments) $Overrides $Timeout
    if ($r.Code -ne $Code -or $r.Out -cne $Output) {
        $map = Join-Path $Repo 'docs/system-map.md'
        $mapText = if (Test-Path -LiteralPath $map) { [IO.File]::ReadAllText($map) } else { '(split)' }
        throw "$Name expected exit $Code stdout [$Output], got exit $($r.Code) stdout [$($r.Out)] stderr [$($r.Err)] map [$mapText]"
    }
    if (($r.Out + $r.Err) -match '[^\x00-\x7f]') { throw "$Name emitted non-ASCII output." }
    $script:count++
    [Console]::WriteLine("PASS $Name")
    return $r
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    [IO.File]::WriteAllText((Join-Path $testRoot 'empty-config'), '', $utf8)
    foreach ($source in @($checker, $PSCommandPath)) {
        if (@([IO.File]::ReadAllBytes($source) | Where-Object { $_ -gt 127 }).Count) { throw 'Script source must be ASCII-only.' }
    }
    $arrayRepo = Join-Path $testRoot 'array-lookups'
    $arraySha = 'a' * 40
    Put $arrayRepo 'docs/system-map.md' ((Header 'First' 'p1' $arraySha 'a/x.ps1') + (Header 'Second' 'p2' $arraySha 'b/y.ps1'))
    $ownerOutput = @(& $checker -Repo $arrayRepo -Owner @('p1', 'p2') -Json)
    if ($LASTEXITCODE -ne 0 -or ($ownerOutput -join "`n") -cne '{"mode":"owner","sections":["First","Second"]}') {
        throw 'In-process Owner array must look up both paths.'
    }
    $script:count++
    [Console]::WriteLine('PASS in-process Owner array looks up both paths')
    $touchesOutput = @(& $checker -Repo $arrayRepo -Touches @('a/x.ps1', 'b/y.ps1') -Json)
    if ($LASTEXITCODE -ne 0 -or ($touchesOutput -join "`n") -cne '{"mode":"touches","sections":["First","Second"]}') {
        throw 'In-process Touches array must look up both paths.'
    }
    $script:count++
    [Console]::WriteLine('PASS in-process Touches array looks up both paths')
    $repo = New-Repo 'single map with spaces in repo path'
    $base = Save-Tree $repo @{ 'src/file.txt' = 'base'; 'src/file[1].txt' = 'base'; 'keep.txt' = 'keep'; 'dir/deep/file' = 'base'; 'a/b' = 'base'; 'a/x/y/b' = 'base' }
    Put $repo 'docs/system-map.md' (Header 'Core' 'src/**' $base 'api/*.json' '**/bridge/*')
    [void](Check 'fresh single map' $repo @('-Stale') 0)
    Put $repo 'docs/system-map.md' ([string][char]0xfeff + (Header 'Core' 'src/**' $base 'api/*.json' '**/bridge/*'))
    [void](Check 'UTF8 BOM map' $repo @('-Stale') 0)
    [void](Check 'literal glob owner' $repo @('-Owner', 'src/file.txt') 0 'Core')
    [void](Check 'literal bracket lookup path' $repo @('-Owner', 'src/file[1].txt') 0 'Core')
    [void](Check 'owner excludes contracts' $repo @('-Owner', 'api/x.json') 0)
    [void](Check 'owner excludes seams' $repo @('-Owner', 'bridge/x') 0)
    [void](Check 'touches excludes covers' $repo @('-Touches', 'src/file.txt') 0)
    [void](Check 'touches contracts' $repo @('-Touches', 'api/x.json') 0 'Core')
    [void](Check 'literal brackets in touched path' $repo @('-Touches', 'api/x[1].json') 0 'Core')
    [void](Check 'star does not cross segments' $repo @('-Touches', 'api/deep/x.json') 0)
    [void](Check 'leading doublestar zero directories' $repo @('-Touches', 'bridge/x') 0 'Core')
    [void](Check 'leading doublestar many directories' $repo @('-Touches', 'a/b/bridge/x') 0 'Core')
    [void](Check 'multiple touches paths' $repo @('-Touches', 'unrelated', 'api/x.json', '-Json') 0 '{"mode":"touches","sections":["Core"]}')
    [void](Check 'empty JSON result' $repo @('-Stale', '-Json') 0 '{"mode":"stale","sections":[]}')
    $next = Save-Tree $repo @{ 'src/file.txt' = 'changed'; 'keep.txt' = 'keep'; 'dir/deep/file' = 'changed'; 'a/b' = 'changed'; 'a/x/y/b' = 'changed' } $base
    [void](Check 'changed cover' $repo @('-Stale') 1 'Core')
    Put $repo 'docs/system-map.md' ((Header 'Literal directory' 'dir' $base) + (Header 'Trailing glob' 'dir/**' $base) + (Header 'Middle glob' 'a/**/b' $base))
    [void](Check 'directory and doublestar stale agreement' $repo @('-Stale') 1 "Literal directory`nTrailing glob`nMiddle glob")
    [void](Check 'literal directory owner agreement' $repo @('-Owner', 'dir/deep/file') 0 "Literal directory`nTrailing glob")
    [void](Check 'literal exact directory' $repo @('-Owner', 'dir') 0 'Literal directory')
    [void](Check 'middle doublestar zero directories' $repo @('-Owner', 'a/b') 0 'Middle glob')
    [void](Check 'middle doublestar many directories' $repo @('-Owner', 'a/x/y/b') 0 'Middle glob')
    [void](Check 'middle doublestar anchored' $repo @('-Owner', 'a/x/y/b/child') 0)
    Put $repo 'docs/system-map.md' (Header 'Deleted' 'src/file.txt' $next)
    $deleted = Save-Tree $repo @{ 'keep.txt' = 'keep' } $next
    [void](Check 'deleted cover remains visible' $repo @('-Stale') 1 'Deleted')
    Put $repo 'docs/system-map.md' (Header 'Rename source' 'keep.txt' $deleted)
    $renamed = Save-Tree $repo @{ 'moved.txt' = 'keep' } $deleted
    [void](Check 'renamed away from cover' $repo @('-Stale') 1 'Rename source')
    Put $repo 'docs/system-map.md' (Header 'Rename destination' 'moved.txt' $deleted)
    [void](Check 'renamed into cover' $repo @('-Stale') 1 'Rename destination')
    Put $repo 'docs/system-map.md' (Header 'Both rename paths' 'keep.txt moved.txt' $deleted)
    $renameRecords = Git $repo @('diff', '--name-status', '-z', '--find-renames', ($deleted + '..HEAD'), '--', ':(glob)keep.txt', ':(glob)moved.txt')
    if (-not $renameRecords.StartsWith("R100`0", [StringComparison]::Ordinal)) { throw 'Fixture must produce a real two-path rename record.' }
    [void](Check 'real NUL rename record and multiple covers' $repo @('-Stale') 1 'Both rename paths')
    $renameRepo = New-Repo 'inexact-rename'
    $renameBody = [string]::Join("`n", [string[]]@(1..100 | ForEach-Object { 'line ' + $_ }))
    $renameBase = Save-Tree $renameRepo @{ 'old/file' = $renameBody }
    [void](Save-Tree $renameRepo @{ 'new/file' = $renameBody.Replace('line 50', 'changed 50') } $renameBase)
    $inexactRecords = Git $renameRepo @('diff', '--name-status', '-z', '--find-renames', ($renameBase + '..HEAD'))
    if ($inexactRecords -cnotmatch '^R0[0-9]{2}\x00') { throw 'Fixture must produce an inexact three-digit rename score.' }
    Put $renameRepo 'docs/system-map.md' (Header 'Edited rename' '**' $renameBase)
    [void](Check 'real edited rename score' $renameRepo @('-Stale') 1 'Edited rename')
    Put $repo 'docs/system-map.md' (Header 'Unknown' 'src/**' ('f' * 40))
    [void](Check 'unknown SHA stale' $repo @('-Stale') 1 'Unknown')
    $otherSha = Save-Tree $repo @{ 'other.txt' = 'other' } '' -Detached
    Put $repo 'docs/system-map.md' (Header 'Other history' 'src/**' $otherSha)
    [void](Check 'valid non ancestor stale' $repo @('-Stale') 1 'Other history')
    Put $repo 'docs/system-map.md' (Header 'Missing value' 'src/**' '')
    [void](Check 'missing SHA stale' $repo @('-Stale') 1 'Missing value')
    [void](Check 'missing SHA rejected by lookup' $repo @('-Owner', 'src/a') 2)
    Put $repo 'docs/system-map.md' "## Missing field`n<!-- apex:map-section covers: src/** contracts:  seams:  -->`n"
    [void](Check 'missing verified field stale' $repo @('-Stale') 1 'Missing field')

    $split = New-Repo 'split'
    $splitSha = Save-Tree $split @{ 'module/file' = 'base' }
    Put $split 'docs/system-map/index.md' "# System map`n- first[1].md`n- second.md`n"
    Put $split 'docs/system-map/first[1].md' (Header 'First' 'module' $splitSha 'contract' 'seam')
    Put $split 'docs/system-map/second.md' (Header 'Second' 'module/**' $splitSha 'contract/**' 'seam/**')
    [void](Check 'split fresh' $split @('-Stale') 0)
    [void](Check 'split owner' $split @('-Owner', 'module/file') 0 "First`nSecond")
    [void](Check 'split touches' $split @('-Touches', 'contract/file', 'seam') 0 "First`nSecond")
    Put $split 'docs/system-map.md' (Header 'Root wins' 'root' $splitSha)
    Put $split 'docs/system-map/index.md' "- missing.md`n"
    [void](Check 'root map precedence' $split @('-Owner', 'root') 0 'Root wins')
    [IO.File]::Delete((Join-Path $split 'docs/system-map.md'))
    [void](Check 'missing split file' $split @('-Stale') 2)
    foreach ($entry in @('- ../outside.md', '- /absolute.md', '- C:/absolute.md', '- has spaces.md', '- first.md trailing', '- first*.md', '- index.md', '  - first.md')) {
        Put $split 'docs/system-map/index.md' ($entry + "`n")
        [void](Check ('invalid index ' + $entry) $split @('-Stale') 2)
    }

    $freshMap = Header 'Fresh' 'moved.txt' $renamed
    Put $repo 'docs/system-map.md' $freshMap
    $foreign = New-Repo 'foreign'
    [void](Save-Tree $foreign @{ 'foreign.txt' = 'foreign' })
    $poison = @{ GIT_DIR = Join-Path $foreign '.git'; GIT_INDEX_FILE = Join-Path $foreign '.git/index'; GIT_WORK_TREE = $foreign;
        GIT_OBJECT_DIRECTORY = Join-Path $foreign '.git/objects'; GIT_ALTERNATE_OBJECT_DIRECTORIES = 'missing'; GIT_COMMON_DIR = 'missing';
        GIT_NAMESPACE = 'unrelated'; GIT_LITERAL_PATHSPECS = '1'; GIT_GLOB_PATHSPECS = '1'; GIT_NOGLOB_PATHSPECS = '1'; GIT_ICASE_PATHSPECS = '1' }
    [void](Check 'parent repository and pathspec pollution removed' $repo @('-Stale') 0 '' $poison)
    Put $repo 'docs/system-map.md' (Header 'Changed' 'src/**' $base)
    [void](Check 'polluted parent still sees target changes' $repo @('-Stale') 1 'Changed' $poison)
    Put $repo 'docs/system-map.md' $freshMap
    $badConfig = Join-Path $testRoot 'bad-config'
    [IO.File]::WriteAllText($badConfig, '[broken', $utf8)
    [void](Check 'broken Git configuration' $repo @('-Stale') 2 '' @{ GIT_CONFIG_GLOBAL = $badConfig })

    $unicodeName = 'Unicode ' + [char]0x96ea + ' "quote" ' + [char]92 + ' slash'
    $unicodePath = 'u/' + [char]0x96ea + '.txt'
    $uRepo = New-Repo 'unicode'
    $uBase = Save-Tree $uRepo @{ $unicodePath = 'base' }
    [void](Save-Tree $uRepo @{ $unicodePath = 'changed' } $uBase)
    Put $uRepo 'docs/system-map.md' (Header $unicodeName 'u/**' $uBase)
    [void](Check 'Unicode NUL Git path and escaped name' $uRepo @('-Stale') 1 'Unicode \u96ea "quote" \u005c slash')
    $json = Check 'ASCII JSON escaping' $uRepo @('-Stale', '-Json') 1 '{"mode":"stale","sections":["Unicode \u96ea \"quote\" \\ slash"]}'
    $decoded = ConvertFrom-Json $json.Out
    if ($decoded.sections[0] -cne $unicodeName) { throw 'JSON name failed to round-trip.' }
    [void](Check 'Unicode lookup path' $uRepo @('-Owner', $unicodePath) 0 'Unicode \u96ea "quote" \u005c slash')

    $invalidHeaders = @(
        "## Bad`n`n<!-- apex:map-section covers: src contracts:  seams:  verified: $base -->",
        "## Bad`n<!-- apex:map-section covers:  contracts:  seams:  verified: $base -->",
        "## Bad`n<!-- apex:map-section covers: src contracts:  seams:  verified: xyz -->",
        "## Bad`n<!-- apex:map-section covers: src seams:  contracts:  verified: $base -->",
        "## Bad`n<!-- apex:map-section covers: src contracts:  seams:  verified: $base extra: no -->",
        "<!-- apex:map-section covers: src contracts:  seams:  verified: $base -->",
        "## Bad`n<!-- apex:map-section covers: src  other contracts:  seams:  verified: $base -->"
    )
    $case = 0
    foreach ($header in $invalidHeaders) {
        Put $repo 'docs/system-map.md' $header
        [void](Check "malformed header $case" $repo @('-Stale') 2)
        $case++
    }
    foreach ($path in @('/absolute', 'C:/absolute', '../up', 'a/../b', './local', 'a//b', 'a/', 'a\b', 'a/**b', 'a/?', 'a/[x]')) {
        Put $repo 'docs/system-map.md' (Header 'Bad path' $path $base)
        [void](Check ('invalid map path ' + $path) $repo @('-Stale') 2)
    }
    # Spaces are separate tokens in map headers, so reject a quoted path with spaces.
    Put $repo 'docs/system-map.md' (Header 'Bad space' '"has spaces"' $base)
    [void](Check 'quoted path with spaces' $repo @('-Stale') 2)
    Put $repo 'docs/system-map.md' '<!-- apex:system-map -->'
    [void](Check 'stub no sections' $repo @('-Stale') 3 'no map sections')
    [void](Check 'stub JSON' $repo @('-Stale', '-Json') 3 '{"mode":"stale","sections":[],"error":"no map sections"}')
    Put $repo 'docs/system-map.md' '# Empty map'
    [void](Check 'zero sections' $repo @('-Owner', 'src/a') 3 'no map sections')
    [IO.File]::WriteAllBytes((Join-Path $repo 'docs/system-map.md'), [byte[]]@(0xc3, 0x28))
    [void](Check 'invalid map UTF8' $repo @('-Stale') 2)
    Put $repo 'docs/system-map.md' $freshMap
    foreach ($arguments in @(@(), @('-Stale', '-Owner', 'src'), @('-Touches'), @('-Owner'), @('-Owner', '../src'), @('-Owner', 'has spaces'), @('-Bogus'), @('-Stale', '-Stale'))) {
        [void](Check ('usage ' + ($arguments -join ' ')) $repo $arguments 2)
    }
    [void](Check 'relative Repo rejected' '.' @('-Stale') 2)
    [void](Check 'usage JSON even after early parse failure' $repo @('-Stale', '-Owner', 'src', '-Json') 2 '{"mode":"stale","sections":[],"error":"Modes are mutually exclusive."}')

    # A fake PATH executable controls exit codes/bytes and asserts the transport
    # contract. It is compiled only inside this disposable fixture directory.
    $shimDir = Join-Path $testRoot 'exe-shim'
    [void][IO.Directory]::CreateDirectory($shimDir)
    $shimSource = @'
using System;
using System.Threading;
public static class MapTestGit {
    public static int Main(string[] args) {
        if (args.Length < 5 || args[0] != "-C" || args[2] != "-c" || args[3] != "protocol.allow=never") return 90;
        if (Environment.GetEnvironmentVariable("GIT_OPTIONAL_LOCKS") != "0" || Environment.GetEnvironmentVariable("GIT_NO_LAZY_FETCH") != "1") return 91;
        foreach (string key in new string[] {"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS"})
            if (Environment.GetEnvironmentVariable(key) != null) return 92;
        if (Console.OpenStandardInput().ReadByte() != -1) return 93;
        string behavior = Environment.GetEnvironmentVariable("APEX_MAP_TEST_GIT");
        if (behavior == "timeout") { Thread.Sleep(180000); return 0; }
        if (behavior == "invalid-utf8") { Console.OpenStandardOutput().Write(new byte[] {0xc3, 0x28}, 0, 2); return 0; }
        if (behavior == "invalid-stderr") { Console.OpenStandardError().Write(new byte[] {0xff}, 0, 1); return 0; }
        string command = args[4];
        if (behavior == "rev-128") return 128;
        if (behavior == "rev-7") return 7;
        if (behavior == "rev-one-output") { Console.Write("unexpected"); return 1; }
        if (command == "rev-parse") { Console.WriteLine(Environment.GetEnvironmentVariable("APEX_MAP_TEST_SHA")); return 0; }
        if (command == "merge-base") {
            if (behavior == "merge-128") return 128;
            if (behavior == "merge-7") return 7;
            return 0;
        }
        if (command == "diff") {
            if (behavior == "diff-1") return 1;
            if (behavior == "diff-128") return 128;
            if (behavior == "malformed-diff") { Console.Write("M\0unterminated"); return 0; }
            if (behavior == "missing-rename-path") { Console.Write("R100\0one\0"); return 0; }
            if (behavior == "bad-status") { Console.Write("BAD\0file\0"); return 0; }
            if (behavior == "drain") { Console.Error.Write(new string('x', 200000)); Console.Write("M\0file\0"); return 0; }
            return 0;
        }
        return 94;
    }
}
'@
    Add-Type -TypeDefinition $shimSource -OutputAssembly (Join-Path $shimDir 'git.exe') -OutputType ConsoleApplication
    $overrides = @{ PATH = $shimDir; APEX_MAP_TEST_SHA = $renamed; APEX_MAP_TEST_GIT = 'fresh' }
    [void](Check 'transport assertions' $repo @('-Stale') 0 '' $overrides)
    foreach ($behavior in @('rev-128', 'rev-7', 'rev-one-output', 'merge-128', 'merge-7', 'diff-1', 'diff-128',
            'invalid-utf8', 'invalid-stderr', 'malformed-diff', 'missing-rename-path', 'bad-status')) {
        $overrides['APEX_MAP_TEST_GIT'] = $behavior
        [void](Check ('forced Git failure ' + $behavior) $repo @('-Stale') 2 '' $overrides)
    }
    $overrides['APEX_MAP_TEST_GIT'] = 'drain'
    [void](Check 'stdout and stderr drained concurrently' $repo @('-Stale') 1 'Fresh' $overrides)
    [void](Check 'Git launch missing from PATH' $repo @('-Stale') 2 '' @{ PATH = $testRoot })
    # Exercise .cmd shim resolution independently of the compiled executable.
    $cmdDir = Join-Path $testRoot 'cmd-shim'
    [void][IO.Directory]::CreateDirectory($cmdDir)
    [IO.File]::WriteAllText((Join-Path $cmdDir 'git.cmd'), "@echo off`r`nexit /b 7`r`n", [Text.Encoding]::ASCII)
    [void](Check 'bounded cmd shim Git failure' $repo @('-Stale') 2 '' @{ PATH = $cmdDir })
    $overrides['APEX_MAP_TEST_GIT'] = 'timeout'
    Write-Output 'Running the real 120-second Git deadline fixture.'
    $timed = Check 'bounded Git timeout' $repo @('-Stale') 2 '' $overrides 140000
    if ($timed.Milliseconds -lt 120000 -or $timed.Milliseconds -ge 140000 -or $timed.Err -notmatch 'timed out') {
        throw 'Git timeout did not enforce the documented 120-second deadline.'
    }
    Write-Output ("PASS all {0} CLI fixtures" -f $script:count)
    $suiteExit = 0
} catch {
    [Console]::Error.WriteLine("FAIL $($_.Exception.Message)")
} finally {
    # Verify the fully resolved target before any recursive cleanup on Windows.
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $scratchPrefix = [IO.Path]::GetFullPath($scratch).TrimEnd([char]92) + [char]92
    if (-not $resolvedRoot.StartsWith($scratchPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing cleanup outside .codex-scratch.'
    }
    if (Test-Path -LiteralPath $resolvedRoot) { Remove-Item -LiteralPath $resolvedRoot -Recurse -Force }
}
exit $suiteExit
