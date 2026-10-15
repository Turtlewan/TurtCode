# Engine dispatch adapter. Dot-source this file; it deliberately has no script-level param block.
# PowerShell 5.1 only, with no module dependencies.

$script:EngineDispatchSchemaPath = Join-Path (Split-Path $PSScriptRoot -Parent) `
    'references\engine-event-schema.json'
if (-not (Get-Variable -Name EngineDispatchProcesses -Scope Script -ErrorAction SilentlyContinue)) {
    $script:EngineDispatchProcesses = @{}
}
if (-not (Get-Variable -Name EngineDispatchModes -Scope Script -ErrorAction SilentlyContinue)) {
    $script:EngineDispatchModes = @{}
}
if (-not (Get-Variable -Name EngineDispatchPollSeconds -Scope Script -ErrorAction SilentlyContinue)) {
    $script:EngineDispatchPollSeconds = 30
}
if (-not (Get-Variable -Name EngineDispatchMaxWaitSeconds -Scope Script -ErrorAction SilentlyContinue)) {
    $script:EngineDispatchMaxWaitSeconds = 14400
}
if (-not (Get-Variable -Name EngineDispatchTerminalReportWaitSeconds -Scope Script -ErrorAction SilentlyContinue)) {
    $script:EngineDispatchTerminalReportWaitSeconds = 10
}

function Get-EngineFullPath {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-EnginePathEqual {
    param([AllowNull()][string]$Left, [AllowNull()][string]$Right)
    if ($null -eq $Left -or $null -eq $Right) { return ($null -eq $Left -and $null -eq $Right) }
    try {
        return ([string]::Equals((Get-EngineFullPath $Left), (Get-EngineFullPath $Right),
            [System.StringComparison]::OrdinalIgnoreCase))
    } catch {
        return ([string]::Equals($Left, $Right, [System.StringComparison]::Ordinal))
    }
}

function Test-EngineOutsideGitWorktree {
    param([Parameter(Mandatory)][string]$Path)
    $probe = Get-EngineFullPath $Path
    if (-not (Test-Path -LiteralPath $probe -PathType Container)) { $probe = Split-Path $probe -Parent }
    while ($probe -and -not (Test-Path -LiteralPath $probe -PathType Container)) {
        $next = Split-Path $probe -Parent
        if ($next -eq $probe) { break }
        $probe = $next
    }
    if (-not $probe) { return $true }
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $inside = @(& git -C $probe rev-parse --is-inside-work-tree 2>$null)
        return -not ($LASTEXITCODE -eq 0 -and (([string[]]$inside -join '').Trim() -ceq 'true'))
    } catch {
        return $true
    } finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Write-EngineUtf8NoBom {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $parent = Split-Path $Path -Parent
    if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Write-EngineAtomicJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value,
        [switch]$Durable
    )
    $parent = Split-Path $Path -Parent
    if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $backup = "$Path.$([guid]::NewGuid().ToString('N')).bak"
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(
        [string]($Value | ConvertTo-Json -Depth 20 -Compress))
    try {
        $stream = [System.IO.FileStream]::new($temporary, [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush([bool]$Durable)
        } finally {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $Path, $backup)
        } else {
            [System.IO.File]::Move($temporary, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
    }
}

function ConvertTo-EngineHashtable {
    param([Parameter(Mandatory)][object]$Object)
    $result = @{}
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { $result[[string]$key] = $Object[$key] }
    } else {
        foreach ($property in $Object.PSObject.Properties) { $result[$property.Name] = $property.Value }
    }
    return $result
}

function Write-EngineDispatchArgs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArgsPath,
        [Parameter(Mandatory)][hashtable]$Parameters
    )

    $fullArgsPath = Get-EngineFullPath $ArgsPath
    if (-not (Test-EngineOutsideGitWorktree -Path $fullArgsPath)) {
        throw "Dispatch arguments must be written outside every Git worktree: $fullArgsPath"
    }
    $required = @('Phase', 'Spec', 'Task', 'Worktree', 'BaseSha', 'SpecSourcePath', 'Authorized',
        'Effort', 'Model', 'Prompt')
    foreach ($name in $required) {
        if (-not $Parameters.ContainsKey($name)) { throw "Dispatch argument set is missing -$name." }
    }
    if ([string]$Parameters.Phase -cne 'build') { throw 'Engine dispatches must use -Phase build.' }
    foreach ($name in @('Spec', 'Task', 'Worktree', 'BaseSha', 'SpecSourcePath', 'Effort', 'Model')) {
        if ([string]::IsNullOrWhiteSpace([string]$Parameters[$name])) {
            throw "Dispatch argument -$name must not be empty."
        }
    }
    if ($Parameters.Authorized -is [string] -or @($Parameters.Authorized).Count -eq 0) {
        throw 'Dispatch argument -Authorized must be a non-empty string array.'
    }
    $hasExecutable = $Parameters.ContainsKey('CodexExecutable') -and
        -not [string]::IsNullOrWhiteSpace([string]$Parameters.CodexExecutable)
    $hasExecutablePrefix = $Parameters.ContainsKey('CodexExecutableArgumentPrefix') -and
        $null -ne $Parameters.CodexExecutableArgumentPrefix -and
        @($Parameters.CodexExecutableArgumentPrefix).Count -gt 0 -and
        -not ($Parameters.CodexExecutableArgumentPrefix -is [string] -and
            [string]::IsNullOrWhiteSpace([string]$Parameters.CodexExecutableArgumentPrefix))
    if ($hasExecutablePrefix -and $Parameters.CodexExecutableArgumentPrefix -is [string]) {
        throw 'Dispatch argument -CodexExecutableArgumentPrefix must be a string array, not a scalar.'
    }
    $document = [ordered]@{}
    foreach ($key in ($Parameters.Keys | Sort-Object)) {
        if ($key -ceq 'CodexExecutable' -and -not $hasExecutable) { continue }
        if ($key -ceq 'CodexExecutableArgumentPrefix' -and -not $hasExecutablePrefix) { continue }
        if ($key -in @('Authorized', 'CodexExecutableArgumentPrefix')) {
            $document[$key] = [string[]]@($Parameters[$key] | ForEach-Object { [string]$_ })
        } else {
            $document[$key] = $Parameters[$key]
        }
    }
    Write-EngineUtf8NoBom -Path $fullArgsPath -Text ($document | ConvertTo-Json -Depth 20)
    return [pscustomobject]@{ args_path = $fullArgsPath }
}

function Start-EngineDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WrapperPath,
        [Parameter(Mandatory)][string]$ArgsPath,
        [Parameter(Mandatory)][string]$ChildOutputPath,
        [Parameter(Mandatory)][string]$StateRoot
    )

    $wrapper = Get-EngineFullPath $WrapperPath
    $argsFile = Get-EngineFullPath $ArgsPath
    $output = Get-EngineFullPath $ChildOutputPath
    $state = Get-EngineFullPath $StateRoot
    foreach ($outside in @($argsFile, $output, $state)) {
        if (-not (Test-EngineOutsideGitWorktree -Path $outside)) {
            throw "Engine dispatch state must stay outside every Git worktree: $outside"
        }
    }
    if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) { throw "Wrapper not found: $wrapper" }
    if (-not (Test-Path -LiteralPath $argsFile -PathType Leaf)) { throw "Arguments JSON not found: $argsFile" }
    [System.IO.Directory]::CreateDirectory((Split-Path $output -Parent)) | Out-Null
    [System.IO.Directory]::CreateDirectory($state) | Out-Null
    foreach ($oldPath in @($output, "$output.stderr", "$output.exit.json", "$output.invocation.json")) {
        if (Test-Path -LiteralPath $oldPath) { Remove-Item -LiteralPath $oldPath -Force }
    }

    $preview = Get-Content -LiteralPath $argsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $isAdopt = (@($preview.PSObject.Properties.Name) -ccontains 'Adopt' -and [bool]$preview.Adopt)
    Write-EngineUtf8NoBom -Path "$output.invocation.json" -Text `
        (([ordered]@{ adopt = [bool]$isAdopt; args_path = $argsFile } | ConvertTo-Json -Compress))

    $encode = {
        param([string]$Value)
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
    }
    $a64 = & $encode $argsFile
    $w64 = & $encode $wrapper
    $s64 = & $encode $state
    $o64 = & $encode $output
    $childScript = @"
`$ErrorActionPreference = 'Stop'
function D([string]`$v) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$v)) }
`$argsPath = D '$a64'
`$wrapperPath = D '$w64'
`$env:APEX_STATE_DIR = D '$s64'
`$outputPath = D '$o64'
`$PSDefaultParameterValues['Out-File:Width'] = 32767
`$raw = Get-Content -LiteralPath `$argsPath -Raw -Encoding UTF8 | ConvertFrom-Json
`$splat = @{}
foreach (`$property in `$raw.PSObject.Properties) {
    if (`$property.Name -in @('Authorized', 'CodexExecutableArgumentPrefix')) {
        [string[]]`$typed = @(`$property.Value | ForEach-Object { [string]`$_ })
        `$splat[`$property.Name] = `$typed
    } else { `$splat[`$property.Name] = `$property.Value }
}
& `$wrapperPath @splat *> `$outputPath
exit `$LASTEXITCODE
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = "-NoProfile -NonInteractive -EncodedCommand $encoded"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw 'Failed to start dispatch child PowerShell.' }
    $startTime = $process.StartTime.ToUniversalTime().ToString('o')
    Write-EngineAtomicJson -Path "$output.invocation.json" -Value ([ordered]@{
        adopt = [bool]$isAdopt; args_path = $argsFile; start_time = $startTime
    })
    $script:EngineDispatchProcesses[[int]$process.Id] = $process
    $script:EngineDispatchModes[$output] = [bool]$isAdopt
    return [pscustomobject]@{
        pid = [int]$process.Id
        start_time = $startTime
        args_path = $argsFile
        child_output_path = $output
    }
}

function Get-EngineProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { if ([string]$key -ceq $Name) { return ,$Object[$key] } }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return ,$property.Value
}

function Test-EngineHasProperty {
    param([AllowNull()][object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { if ([string]$key -ceq $Name) { return $true } }
        return $false
    }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Test-EngineProcessIs {
    param([int]$ProcessId, [AllowNull()][string]$Stamp, [switch]$Strict)
    if ($ProcessId -le 0) { return $false }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    if ([string]::IsNullOrWhiteSpace($Stamp) -or $Stamp -ceq 'unknown') { return (-not $Strict) }
    try {
        $actual = $process.StartTime.ToUniversalTime()
        $expected = ([datetime]$Stamp).ToUniversalTime()
        return ([Math]::Abs(($actual - $expected).TotalMilliseconds) -lt 50)
    } catch {
        return (-not $Strict)
    }
}

function Get-EngineDescendantProcessIds {
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        if ($null -eq ('ApexEngineProcessTree' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class ApexEngineProcessTree
{
    private const uint TH32CS_SNAPPROCESS = 0x00000002;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PROCESSENTRY32
    {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32FirstW(IntPtr snapshot, ref PROCESSENTRY32 entry);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Process32NextW(IntPtr snapshot, ref PROCESSENTRY32 entry);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public static int[] Descendants(int rootProcessId)
    {
        var children = new Dictionary<int, List<int>>();
        IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == new IntPtr(-1)) return new int[0];
        try
        {
            var entry = new PROCESSENTRY32();
            entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
            if (Process32FirstW(snapshot, ref entry))
            {
                do
                {
                    int parent = unchecked((int)entry.th32ParentProcessID);
                    int child = unchecked((int)entry.th32ProcessID);
                    List<int> values;
                    if (!children.TryGetValue(parent, out values))
                    {
                        values = new List<int>();
                        children[parent] = values;
                    }
                    values.Add(child);
                    entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
                }
                while (Process32NextW(snapshot, ref entry));
            }
        }
        finally
        {
            CloseHandle(snapshot);
        }

        var result = new List<int>();
        var seen = new HashSet<int>();
        var pending = new Queue<int>();
        pending.Enqueue(rootProcessId);
        seen.Add(rootProcessId);
        while (pending.Count > 0)
        {
            int parent = pending.Dequeue();
            List<int> values;
            if (!children.TryGetValue(parent, out values)) continue;
            foreach (int child in values)
            {
                if (!seen.Add(child)) continue;
                result.Add(child);
                pending.Enqueue(child);
            }
        }
        return result.ToArray();
    }
}
'@
        }
        return [pscustomobject]@{
            process_ids = [int[]]([ApexEngineProcessTree]::Descendants($ProcessId))
        }
    } catch {
        return [pscustomobject]@{ process_ids = [int[]]@() }
    }
}

function Test-EngineLedgerRowLive {
    param([Parameter(Mandatory)][object]$Row)
    $pidValue = 0
    $launcherPidValue = 0
    if (Test-EngineHasProperty $Row 'pid') {
        [void][int]::TryParse([string](Get-EngineProperty $Row 'pid'), [ref]$pidValue)
    }
    if (Test-EngineHasProperty $Row 'launcher_pid') {
        [void][int]::TryParse([string](Get-EngineProperty $Row 'launcher_pid'), [ref]$launcherPidValue)
    }
    $pidStamp = if (Test-EngineHasProperty $Row 'pid_start') {
        [string](Get-EngineProperty $Row 'pid_start')
    } else { $null }
    $launcherStamp = if (Test-EngineHasProperty $Row 'launcher_start') {
        [string](Get-EngineProperty $Row 'launcher_start')
    } else { $null }

    if ($pidValue -gt 0 -and (Test-EngineProcessIs $pidValue $pidStamp -Strict)) { return $true }
    if ($launcherPidValue -gt 0 -and
            (Test-EngineProcessIs $launcherPidValue $launcherStamp -Strict)) { return $true }
    $unverifiable = ($pidValue -gt 0 -and (Test-EngineProcessIs $pidValue $pidStamp)) -or
        ($launcherPidValue -gt 0 -and (Test-EngineProcessIs $launcherPidValue $launcherStamp))
    if (-not $unverifiable) { return $false }
    if (Test-EngineHasProperty $Row 'started') {
        try {
            $age = (Get-Date).ToUniversalTime() -
                ([datetime](Get-EngineProperty $Row 'started')).ToUniversalTime()
            if ($age.TotalHours -gt 12) { return $false }
        } catch { }
    }
    return $true
}

function Test-EngineJsonType {
    param([AllowNull()][object]$Value, [Parameter(Mandatory)][string[]]$Allowed)
    foreach ($type in $Allowed) {
        switch -CaseSensitive ($type) {
            'null' { if ($null -eq $Value) { return $true } }
            'string' { if ($Value -is [string]) { return $true } }
            'boolean' { if ($Value -is [bool]) { return $true } }
            'integer' {
                if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
                    $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
                    $Value -is [int64] -or $Value -is [uint64]) { return $true }
            }
            'array' {
                if ($Value -is [System.Array] -or $Value -is [System.Collections.IList]) { return $true }
            }
            'object' {
                if ($null -ne $Value -and -not ($Value -is [string]) -and
                    -not ($Value -is [System.Array]) -and
                    ($Value -is [System.Collections.IDictionary] -or
                        $Value -is [System.Management.Automation.PSCustomObject])) { return $true }
            }
        }
    }
    return $false
}

function Test-EngineSchemaNode {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][object]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ref]$Diagnosis
    )
    $types = @()
    if (Test-EngineHasProperty $Rule 'type') {
        $types = @((Get-EngineProperty $Rule 'type') | ForEach-Object { [string]$_ })
    }
    if ($types.Count -gt 0 -and -not (Test-EngineJsonType -Value $Value -Allowed $types)) {
        $Diagnosis.Value = "$Path has the wrong type"
        return $false
    }
    if (Test-EngineHasProperty $Rule 'const') {
        $constant = Get-EngineProperty $Rule 'const'
        if (($null -eq $Value) -ne ($null -eq $constant) -or
                ($null -ne $Value -and [string]$Value -cne [string]$constant)) {
            $Diagnosis.Value = "$Path violates its schema const"
            return $false
        }
    }
    if (Test-EngineHasProperty $Rule 'enum') {
        $matched = $false
        foreach ($choice in @((Get-EngineProperty $Rule 'enum'))) {
            if ($null -eq $choice -and $null -eq $Value) { $matched = $true; break }
            if ($null -ne $choice -and $null -ne $Value -and [string]$choice -ceq [string]$Value) {
                $matched = $true; break
            }
        }
        if (-not $matched) { $Diagnosis.Value = "$Path is outside its schema enum"; return $false }
    }
    $pattern = Get-EngineProperty $Rule 'pattern'
    if ($null -ne $Value -and $pattern -and [string]$Value -cnotmatch [string]$pattern) {
        $Diagnosis.Value = "$Path violates its schema pattern"; return $false
    }
    $minLength = Get-EngineProperty $Rule 'minLength'
    if ($null -ne $Value -and $null -ne $minLength -and ([string]$Value).Length -lt [int]$minLength) {
        $Diagnosis.Value = "$Path violates its schema minimum length"; return $false
    }
    $maxLength = Get-EngineProperty $Rule 'maxLength'
    if ($null -ne $Value -and $null -ne $maxLength -and ([string]$Value).Length -gt [int]$maxLength) {
        $Diagnosis.Value = "$Path violates its schema maximum length"; return $false
    }

    $isObject = $null -ne $Value -and
        ($Value -is [System.Collections.IDictionary] -or
            $Value -is [System.Management.Automation.PSCustomObject])
    if ($isObject -and (Test-EngineHasProperty $Rule 'properties')) {
        $properties = Get-EngineProperty $Rule 'properties'
        $requiredKeys = @()
        if (Test-EngineHasProperty $Rule 'required') {
            $requiredKeys = @((Get-EngineProperty $Rule 'required'))
        }
        foreach ($required in $requiredKeys) {
            if (-not (Test-EngineHasProperty $Value ([string]$required))) {
                $Diagnosis.Value = "$Path is missing required key '$required'"
                return $false
            }
        }
        if ((Test-EngineHasProperty $Rule 'additionalProperties') -and
                (Get-EngineProperty $Rule 'additionalProperties') -eq $false) {
            $allowed = @($properties.PSObject.Properties.Name)
            $actual = if ($Value -is [System.Collections.IDictionary]) {
                @($Value.Keys | ForEach-Object { [string]$_ })
            } else { @($Value.PSObject.Properties.Name) }
            foreach ($name in $actual) {
                if ($allowed -cnotcontains $name) {
                    $Diagnosis.Value = "$Path has forbidden key '$name'"
                    return $false
                }
            }
        }
        foreach ($property in $properties.PSObject.Properties) {
            if (-not (Test-EngineHasProperty $Value $property.Name)) { continue }
            $child = Get-EngineProperty $Value $property.Name
            if (-not (Test-EngineSchemaNode -Value $child -Rule $property.Value `
                        -Path "$Path.$($property.Name)" -Diagnosis $Diagnosis)) { return $false }
        }
    }
    if (($Value -is [System.Array] -or $Value -is [System.Collections.IList])) {
        $maxItems = Get-EngineProperty $Rule 'maxItems'
        if ($null -ne $maxItems -and @($Value).Count -gt [int]$maxItems) {
            $Diagnosis.Value = "$Path has too many array items"; return $false
        }
        $itemRule = Get-EngineProperty $Rule 'items'
        if ($null -ne $itemRule) {
            $index = 0
            foreach ($item in @($Value)) {
                if (-not (Test-EngineSchemaNode -Value $item -Rule $itemRule `
                            -Path "$Path[$index]" -Diagnosis $Diagnosis)) { return $false }
                $index++
            }
        }
    }
    return $true
}

function Test-EngineSchemaDefinition {
    param(
        [Parameter(Mandatory)][object]$Event,
        [Parameter(Mandatory)][ValidateSet('dispatch_result', 'refusal')][string]$Definition,
        [Parameter(Mandatory)][ref]$Diagnosis
    )
    try { $schema = Get-Content -LiteralPath $script:EngineDispatchSchemaPath -Raw | ConvertFrom-Json }
    catch { $Diagnosis.Value = "protocol schema could not be read: $($_.Exception.Message)"; return $false }
    $def = $schema.'$defs'.$Definition
    if ($null -eq $def) { $Diagnosis.Value = "protocol schema definition missing: $Definition"; return $false }
    if (-not (Test-EngineSchemaNode -Value $Event -Rule $def `
                -Path "event (`$defs.$Definition)" -Diagnosis $Diagnosis)) { return $false }
    $code = Get-EngineProperty -Object $Event -Name 'exit_code'
    $runId = Get-EngineProperty -Object $Event -Name 'run_id'
    if ($Definition -ceq 'refusal') {
        if ($code -in @(71, 72, 74, 76, 79, 81, 83) -and $null -ne $runId) {
            $Diagnosis.Value = "refusal exit $code requires a null run_id"; return $false
        }
        if ($code -in @(75, 80, 124) -and [string]$runId -cnotmatch '^[0-9a-f]{32}$') {
            $Diagnosis.Value = "refusal exit $code requires a 32-character lowercase-hex run_id"; return $false
        }
        if ($code -eq 82 -and $null -ne $runId -and [string]$runId -cnotmatch '^[0-9a-f]{32}$') {
            $Diagnosis.Value = 'refusal exit 82 requires null or a 32-character lowercase-hex run_id'; return $false
        }
        if ($code -eq 78 -and $null -ne $runId -and ([string]$runId).Length -lt 22) {
            $Diagnosis.Value = 'refusal exit 78 requires null or a run_id at least 22 characters long'; return $false
        }
        if ($null -ne $code -and $null -ne (Get-EngineProperty -Object $Event -Name 'rule')) {
            $Diagnosis.Value = 'wrapper refusal events require a null rule'; return $false
        }
        # Keep the refusal contract's schema conditionals in force after the legacy checks above.
        foreach ($conditional in @((Get-EngineProperty $def 'allOf'))) {
            if (-not (Test-EngineHasProperty $conditional 'if')) { continue }
            $conditionDiagnosis = ''
            $condition = Get-EngineProperty $conditional 'if'
            $branchName = if (Test-EngineSchemaNode -Value $Event -Rule $condition `
                    -Path "event (`$defs.$Definition)" -Diagnosis ([ref]$conditionDiagnosis)) {
                'then'
            } else { 'else' }
            if (Test-EngineHasProperty $conditional $branchName) {
                $branch = Get-EngineProperty $conditional $branchName
                if (-not (Test-EngineSchemaNode -Value $Event -Rule $branch `
                            -Path "event (`$defs.$Definition)" -Diagnosis $Diagnosis)) { return $false }
            }
        }
    }
    return $true
}

function Test-EngineTerminalStatus {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$Status,
        [AllowNull()][object]$Event
    )
    $scopeMatch = [regex]::Match($Status, '^(?<base>.+)\+scope(?<scope>[0-9]+)$')
    $hasScope = $scopeMatch.Success
    $baseStatus = if ($hasScope) { $scopeMatch.Groups['base'].Value } else { $Status }
    $scopeText = if ($hasScope) { $scopeMatch.Groups['scope'].Value } else { '' }
    $normalizedScope = if ($hasScope) { $scopeText.TrimStart([char[]]@('0')) } else { '' }
    if ($hasScope -and $normalizedScope.Length -eq 0) { $normalizedScope = '0' }
    switch ($ExitCode) {
        0 { return (-not $hasScope -and $Status -in @('done', 'success', 'adopted-done')) }
        68 { return (-not $hasScope -and $Status -in @('done_with_concerns', 'adopted-done_with_concerns')) }
        67 {
            if (-not $hasScope) { return ($Status -in @('blocked', 'adopted-blocked', 'adopted-void')) }
            return ($baseStatus -in @('blocked', 'adopted-blocked'))
        }
        69 {
            if ($hasScope -or $Status -notin @('done', 'done_with_concerns', 'adopted-void', 'failed')) {
                return $false
            }
            return ($null -ne $Event -and (Test-EngineHasProperty $Event 'tree_moved') -and
                (Get-EngineProperty $Event 'tree_moved') -eq $true)
        }
        1 { return (-not $hasScope -and $Status -in @('failed', 'done', 'done_with_concerns')) }
        65 {
            if (-not $hasScope) { return ($Status -in @('done', 'done_with_concerns', 'failed')) }
            return ($baseStatus -in @('adopted-done', 'adopted-done_with_concerns') -and
                $normalizedScope -cne '0' -and $normalizedScope -cne '66')
        }
        66 {
            if (-not $hasScope) { return ($Status -in @('done', 'done_with_concerns', 'failed')) }
            return ($baseStatus -in @('adopted-done', 'adopted-done_with_concerns') -and
                $scopeText -ceq '66')
        }
        73 { return (-not $hasScope -and $Status -in @('done', 'done_with_concerns', 'failed', 'adopted-done', 'adopted-done_with_concerns')) }
        77 { return (-not $hasScope -and $Status -in @('done', 'done_with_concerns', 'failed', 'adopted-done', 'adopted-done_with_concerns')) }
        default { return $false }
    }
}

function Read-EngineLedgerRows {
    param([Parameter(Mandatory)][string]$LedgerPath)
    if (-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) { return @() }
    $rows = @()
    $mutex = [System.Threading.Mutex]::new($false, 'ApexCodexRunLedger')
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) }
        catch [System.Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Timed out waiting for the Codex run-ledger lock.' }
        if (-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) { return @() }
        foreach ($line in [System.IO.File]::ReadAllLines((Get-EngineFullPath $LedgerPath))) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $rows += ,($line | ConvertFrom-Json) } catch { }
        }
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    return @($rows)
}

function Get-EngineDefaultLedgerPath {
    $root = if ($env:APEX_STATE_DIR) { $env:APEX_STATE_DIR }
    elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'apex' }
    else { Join-Path $env:TEMP 'apex' }
    return Join-Path (Join-Path (Get-EngineFullPath $root) 'progress') 'codex-run-ledger.jsonl'
}

function Find-EngineDispatchRow {
    [CmdletBinding()]
    param(
        [string]$LedgerPath = (Get-EngineDefaultLedgerPath),
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][string]$Phase
    )
    $match = $null
    foreach ($row in @(Read-EngineLedgerRows -LedgerPath $LedgerPath)) {
        foreach ($requiredProperty in @('worktree', 'spec', 'task', 'phase')) {
            if (-not (Test-EngineHasProperty $row $requiredProperty)) { $row = $null; break }
        }
        if ($null -eq $row) { continue }
        $rowKind = if ((Test-EngineHasProperty $row 'row_kind') -and
                -not [string]::IsNullOrWhiteSpace([string](Get-EngineProperty $row 'row_kind'))) {
            [string](Get-EngineProperty $row 'row_kind')
        } else { 'dispatch' }
        if ($rowKind -cne 'dispatch') { continue }
        if (-not (Test-EnginePathEqual ([string](Get-EngineProperty $row 'worktree')) $Worktree)) { continue }
        if ([string](Get-EngineProperty $row 'spec') -cne $Spec -or
                [string](Get-EngineProperty $row 'task') -cne $Task -or
                [string](Get-EngineProperty $row 'phase') -cne $Phase) { continue }
        $match = $row
    }
    return [pscustomobject]@{ found = ($null -ne $match); row = $match }
}

function Get-EngineRowByRunId {
    param([Parameter(Mandatory)][string]$LedgerPath, [Parameter(Mandatory)][string]$RunId)
    $match = $null
    foreach ($row in @(Read-EngineLedgerRows -LedgerPath $LedgerPath)) {
        if (-not (Test-EngineHasProperty $row 'run_id')) { continue }
        $rowKind = if ((Test-EngineHasProperty $row 'row_kind') -and
                -not [string]::IsNullOrWhiteSpace([string](Get-EngineProperty $row 'row_kind'))) {
            [string](Get-EngineProperty $row 'row_kind')
        } else { 'dispatch' }
        if ($rowKind -ceq 'dispatch' -and
                [string](Get-EngineProperty $row 'run_id') -ceq $RunId) { $match = $row }
    }
    return $match
}

function New-EngineReadResult {
    param(
        [bool]$Ok, [int]$ExitCode, [string]$ChildOutputPath, [AllowNull()][string]$EventPath,
        [AllowNull()][object]$Event, [AllowNull()][string]$WrapperRunId,
        [AllowNull()][string]$EndTreeDigest, [AllowNull()][string]$Diagnosis
    )
    return [pscustomobject]@{
        ok = $Ok; exit_code = $ExitCode; child_output_path = $ChildOutputPath
        event_path = $EventPath; event = $Event; wrapper_run_id = $WrapperRunId
        end_tree_digest = $EndTreeDigest; diagnosis = $Diagnosis
    }
}

function Read-EngineDispatchEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ChildOutputPath,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$Worktree,
        [string]$LedgerPath = (Get-EngineDefaultLedgerPath)
    )
    $output = Get-EngineFullPath $ChildOutputPath
    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
        return New-EngineReadResult $false $ExitCode $output $null $null $null $null 'child output is missing'
    }
    $eventPaths = @()
    foreach ($line in [System.IO.File]::ReadAllLines($output)) {
        if ($line -cmatch '^\[event\] (?<path>.+\.event\.json)\s*$') { $eventPaths += $Matches.path.Trim() }
    }
    if ($eventPaths.Count -ne 1) {
        return New-EngineReadResult $false $ExitCode $output $null $null $null $null `
            "expected exactly one printed [event] path, found $($eventPaths.Count)"
    }
    try { $eventPath = Get-EngineFullPath $eventPaths[0] } catch {
        return New-EngineReadResult $false $ExitCode $output $eventPaths[0] $null $null $null 'printed event path is invalid'
    }
    if (-not (Test-Path -LiteralPath $eventPath -PathType Leaf)) {
        return New-EngineReadResult $false $ExitCode $output $eventPath $null $null $null 'printed event file is missing'
    }
    $expectedEvents = Get-EngineFullPath (Join-Path (Split-Path (Get-EngineFullPath $LedgerPath) -Parent | Split-Path -Parent) 'events')
    if (-not (Test-EnginePathEqual (Split-Path $eventPath -Parent) $expectedEvents)) {
        return New-EngineReadResult $false $ExitCode $output $eventPath $null $null $null `
            'printed event path is outside the ledger state root events directory'
    }
    try { $event = Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json }
    catch { return New-EngineReadResult $false $ExitCode $output $eventPath $null $null $null "event JSON is malformed: $($_.Exception.Message)" }
    $kind = [string](Get-EngineProperty $event 'kind')
    if ($kind -cnotin @('dispatch_result', 'refusal')) {
        return New-EngineReadResult $false $ExitCode $output $eventPath $event $null $null 'event kind is not recognized'
    }
    $schemaDiagnosis = ''
    if (-not (Test-EngineSchemaDefinition -Event $event -Definition $kind -Diagnosis ([ref]$schemaDiagnosis))) {
        return New-EngineReadResult $false $ExitCode $output $eventPath $event $null $null $schemaDiagnosis
    }
    if ([int]$event.exit_code -ne $ExitCode) {
        return New-EngineReadResult $false $ExitCode $output $eventPath $event $null $null `
            "process exit $ExitCode does not match event exit $($event.exit_code)"
    }
    $isAdopt = $false
    if ($script:EngineDispatchModes.ContainsKey($output)) { $isAdopt = [bool]$script:EngineDispatchModes[$output] }
    elseif (Test-Path -LiteralPath "$output.invocation.json" -PathType Leaf) {
        try { $isAdopt = [bool](Get-Content "$output.invocation.json" -Raw | ConvertFrom-Json).adopt } catch { }
    }
    if ($kind -ceq 'refusal' -and $ExitCode -eq 75 -and -not $isAdopt) {
        return New-EngineReadResult $false $ExitCode $output $eventPath $event $null $null `
            'build dispatch cannot produce adopt-only exit 75'
    }

    $row = $null
    $wrapperRunId = $null
    $digest = $null
    if ($kind -ceq 'dispatch_result') {
        $row = Get-EngineRowByRunId -LedgerPath $LedgerPath -RunId ([string]$event.run_id)
        if ($null -eq $row) {
            return New-EngineReadResult $false $ExitCode $output $eventPath $event $null $null `
                'terminal event has no matching dispatch ledger row'
        }
        $wrapperRunId = [string](Get-EngineProperty $row 'run_id')
        if ([string]$event.run_id -cne $wrapperRunId) {
            return New-EngineReadResult $false $ExitCode $output $eventPath $event $wrapperRunId $null 'terminal run_id mismatch'
        }
        if (-not (Test-EngineHasProperty $row 'status') -or
                -not (Test-EngineTerminalStatus -ExitCode $ExitCode -Status ([string]$event.status) -Event $event) -or
                -not (Test-EngineTerminalStatus -ExitCode $ExitCode `
                    -Status ([string](Get-EngineProperty $row 'status')) -Event $event)) {
            return New-EngineReadResult $false $ExitCode $output $eventPath $event $wrapperRunId $null `
                "exit/status correlation failed for exit $ExitCode"
        }
        if ((Test-EngineHasProperty $row 'task') -and
                [string]$event.task_id -cne [string](Get-EngineProperty $row 'task') -or
                [string]$event.task_id -cne $TaskId) {
            return New-EngineReadResult $false $ExitCode $output $eventPath $event $wrapperRunId $null 'event task does not match dispatch context'
        }
        if ((Test-EngineHasProperty $row 'worktree') -and
                -not (Test-EnginePathEqual ([string]$event.repo) `
                    ([string](Get-EngineProperty $row 'worktree'))) -or
                -not (Test-EnginePathEqual ([string]$event.repo) $Worktree)) {
            return New-EngineReadResult $false $ExitCode $output $eventPath $event $wrapperRunId $null 'event repo does not match dispatch worktree'
        }
        if (Test-EngineHasProperty $row 'end_tree_digest') {
            $digest = [string](Get-EngineProperty $row 'end_tree_digest')
        }
    } else {
        $runId = if ($null -eq $event.run_id) { $null } else { [string]$event.run_id }
        if ($ExitCode -in @(71, 72, 74, 76, 79, 81, 83)) {
            if ([string]$event.task_id -cne $TaskId) {
                return New-EngineReadResult $false $ExitCode $output $eventPath $event $null $null `
                    'refusal task does not match dispatch context'
            }
            if (-not (Test-EnginePathEqual ([string]$event.repo) $Worktree)) {
                return New-EngineReadResult $false $ExitCode $output $eventPath $event $null $null `
                    'refusal repo does not match dispatch worktree'
            }
        }
        if ($runId) { $row = Get-EngineRowByRunId $LedgerPath $runId }
        if ($null -ne $row) {
            $wrapperRunId = [string](Get-EngineProperty $row 'run_id')
            if (Test-EngineHasProperty $row 'end_tree_digest') {
                $digest = [string](Get-EngineProperty $row 'end_tree_digest')
            }
        }
    }
    return New-EngineReadResult $true $ExitCode $output $eventPath $event $wrapperRunId $digest $null
}

function Wait-EngineDispatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ChildPid,
        [Parameter(Mandatory)][string]$ChildOutputPath,
        [string]$LedgerPath = (Get-EngineDefaultLedgerPath),
        [ValidateRange(1, 2147483)][int]$MaxWaitSeconds = $script:EngineDispatchMaxWaitSeconds
    )
    $output = Get-EngineFullPath $ChildOutputPath
    $exitPath = "$output.exit.json"
    $exitCode = $null
    if ($script:EngineDispatchProcesses.ContainsKey($ChildPid)) {
        $process = $script:EngineDispatchProcesses[$ChildPid]
        $completed = $process.WaitForExit([int]([long]$MaxWaitSeconds * 1000))
        if (-not $completed) {
            return [pscustomobject]@{ exit_code = -1; child_output_path = $output; event_path = $null
                event = $null; wrapper_run_id = $null; end_tree_digest = $null
                diagnosis = "child dispatch wait exceeded the $MaxWaitSeconds-second cap; attempt must be parked" }
        }
        $exitCode = [int]$process.ExitCode
        $script:EngineDispatchProcesses.Remove($ChildPid)
        Write-EngineUtf8NoBom -Path $exitPath -Text (([ordered]@{ exit_code = $exitCode } | ConvertTo-Json -Compress))
    } elseif (Test-Path -LiteralPath $exitPath -PathType Leaf) {
        try { $exitCode = [int](Get-Content $exitPath -Raw | ConvertFrom-Json).exit_code } catch { }
    } else {
        $dispatchStamp = $null
        try {
            $invocation = Get-Content -LiteralPath "$output.invocation.json" -Raw | ConvertFrom-Json
            if ($null -ne $invocation.PSObject.Properties['start_time']) {
                $dispatchStamp = [string]$invocation.start_time
            }
        } catch { }
        $started = Get-Date
        while ($null -eq $exitCode) {
            if (-not (Test-EngineProcessIs $ChildPid $dispatchStamp -Strict)) { break }
            if (((Get-Date) - $started).TotalSeconds -ge $MaxWaitSeconds) { break }
            Start-Sleep -Seconds ([Math]::Max(1, [int]$script:EngineDispatchPollSeconds))
            if (Test-Path -LiteralPath $exitPath -PathType Leaf) {
                try { $exitCode = [int](Get-Content $exitPath -Raw | ConvertFrom-Json).exit_code } catch { }
            }
        }
    }
    if ($null -eq $exitCode) {
        # A resumed parent cannot recover Windows' historical process exit code. The wrapper's
        # immutable event supplies it; Read-EngineDispatchEvent still validates every other edge.
        try {
            $eventLine = @([System.IO.File]::ReadAllLines($output) | Where-Object { $_ -cmatch '^\[event\] .+\.event\.json\s*$' })
            if ($eventLine.Count -eq 1) {
                $path = ($eventLine[0] -replace '^\[event\] ', '').Trim()
                $exitCode = [int](Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).exit_code
            }
        } catch { }
    }
    if ($null -eq $exitCode) {
        return [pscustomobject]@{ exit_code = -1; child_output_path = $output; event_path = $null
            event = $null; wrapper_run_id = $null; end_tree_digest = $null
            diagnosis = 'child exit code could not be recovered' }
    }
    $task = $null; $worktree = $null
    try {
        $meta = Get-Content -LiteralPath "$output.invocation.json" -Raw | ConvertFrom-Json
        $argDoc = Get-Content -LiteralPath ([string]$meta.args_path) -Raw -Encoding UTF8 | ConvertFrom-Json
        $task = [string]$argDoc.Task; $worktree = [string]$argDoc.Worktree
    } catch { }
    if (-not $task -or -not $worktree) {
        return [pscustomobject]@{ exit_code = [int]$exitCode; child_output_path = $output; event_path = $null
            event = $null; wrapper_run_id = $null; end_tree_digest = $null
            diagnosis = 'dispatch invocation metadata is missing or malformed' }
    }
    $read = Read-EngineDispatchEvent -ChildOutputPath $output -ExitCode ([int]$exitCode) `
        -TaskId $task -Worktree $worktree -LedgerPath $LedgerPath
    return [pscustomobject]@{
        exit_code = [int]$exitCode; child_output_path = $output; event_path = $read.event_path
        event = $read.event; wrapper_run_id = $read.wrapper_run_id
        end_tree_digest = $read.end_tree_digest; diagnosis = $read.diagnosis
    }
}

function Invoke-EngineAdopt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WrapperPath,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$ChildOutputPath,
        [ValidateRange(1, 2147483)][int]$AdoptWaitSeconds = 600
    )
    $output = Get-EngineFullPath $ChildOutputPath
    $timeoutRoot = Join-Path (Get-EngineFullPath $StateRoot) 'engine-adopt-timeouts'
    $timeoutMarker = Join-Path $timeoutRoot "$RunId.json"
    $previousDiagnosis = "previous adopter of run $RunId timed out; not re-adopting (finish or -AbandonRunId it, then remove marker)"
    if (Test-Path -LiteralPath $timeoutMarker -PathType Leaf) {
        return [pscustomobject]@{
            exit_code = -1; child_output_path = $output; event_path = $null; event = $null
            wrapper_run_id = $RunId; end_tree_digest = $null; diagnosis = $previousDiagnosis
            adopt_timed_out = $true
        }
    }
    $argsPath = "$output.adopt.args.json"
    $parameters = [ordered]@{
        Adopt = $true; RunId = $RunId; Spec = $Spec; Task = $Task; Worktree = $Worktree
        Phase = 'build'
    }
    Write-EngineUtf8NoBom -Path $argsPath -Text ($parameters | ConvertTo-Json -Depth 8)
    $started = Start-EngineDispatch -WrapperPath $WrapperPath -ArgsPath $argsPath `
        -ChildOutputPath $output -StateRoot $StateRoot
    $ledger = Join-Path (Join-Path (Get-EngineFullPath $StateRoot) 'progress') 'codex-run-ledger.jsonl'
    $result = Wait-EngineDispatch -ChildPid $started.pid -ChildOutputPath $output -LedgerPath $ledger `
        -MaxWaitSeconds $AdoptWaitSeconds
    if ($result.exit_code -eq -1 -and
            $script:EngineDispatchProcesses.ContainsKey([int]$started.pid)) {
        $process = $script:EngineDispatchProcesses[[int]$started.pid]
        $timedOutAt = (Get-Date).ToUniversalTime().ToString('o')
        $killDiagnosis = $null
        $taskkillExit = $null
        $taskkillText = @()
        $descendantProcesses = @()
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            if (-not $process.HasExited) {
                $descendantSnapshot = Get-EngineDescendantProcessIds -ProcessId ([int]$started.pid)
                foreach ($descendantPid in @($descendantSnapshot.process_ids)) {
                    $descendant = Get-Process -Id ([int]$descendantPid) -ErrorAction SilentlyContinue
                    if ($null -eq $descendant) { continue }
                    try { $null = $descendant.StartTime; $descendantProcesses += $descendant }
                    catch { $descendant.Dispose() }
                }
                $taskkillText = @(& taskkill.exe /PID ([string]$started.pid) /T /F 2>&1)
                $taskkillExit = $LASTEXITCODE
                if ($taskkillExit -ne 0) {
                    for ($descendantIndex = $descendantProcesses.Count - 1;
                            $descendantIndex -ge 0; $descendantIndex--) {
                        if (-not $descendantProcesses[$descendantIndex].HasExited) {
                            $descendantProcesses[$descendantIndex].Kill()
                            $null = $descendantProcesses[$descendantIndex].WaitForExit(5000)
                        }
                    }
                    if (-not $process.HasExited) { $process.Kill() }
                }
                $adopterExited = $process.WaitForExit(5000)
                if (-not $adopterExited) {
                    $process.Refresh()
                    $adopterExited = $process.HasExited
                }
                if (-not $adopterExited) {
                    $adopterExited = $process.WaitForExit(5000)
                }
                if (-not $adopterExited) {
                    $killDiagnosis = 'timed-out adopt child did not exit after it was killed'
                } elseif ($taskkillExit -ne 0) {
                    $killDiagnosis = "taskkill exited $taskkillExit; timed-out adopt process tree was killed by process fallback: $([string[]]$taskkillText -join ' ')"
                }
            }
        } catch {
            $killDiagnosis = "timed-out adopt child could not be killed: $($_.Exception.Message)"
        } finally {
            foreach ($descendantProcess in @($descendantProcesses)) { $descendantProcess.Dispose() }
            $ErrorActionPreference = $oldPreference
            $script:EngineDispatchProcesses.Remove([int]$started.pid)
        }
        Write-EngineAtomicJson -Path $timeoutMarker -Durable -Value ([ordered]@{
            run_id = $RunId; adopter_pid = [int]$started.pid; adopter_start = [string]$started.start_time
            timed_out_at = $timedOutAt; adopt_wait_seconds = [int]$AdoptWaitSeconds
        })
        if ($null -eq $result.PSObject.Properties['adopt_timed_out']) {
            $result | Add-Member -NotePropertyName adopt_timed_out -NotePropertyValue $true
        } else {
            $result.adopt_timed_out = $true
        }
        $result.diagnosis = if ($killDiagnosis) {
            "adopt child wait exceeded the $AdoptWaitSeconds-second adopt cap; $killDiagnosis"
        } else {
            "adopt child wait exceeded the $AdoptWaitSeconds-second adopt cap; timed-out adopt child was killed"
        }
    }
    return $result
}

function Wait-EngineLiveRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WrapperPath,
        [Parameter(Mandatory)][object]$Row,
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$Task,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$ChildOutputPath,
        [Parameter(Mandatory)][datetime]$WaitStartedAt,
        [ValidateRange(1, 2147483)][int]$AdoptWaitSeconds = 600
    )
    foreach ($requiredProperty in @('spec', 'task', 'worktree', 'phase', 'run_id')) {
        if (-not (Test-EngineHasProperty $Row $requiredProperty)) {
            return [pscustomobject]@{ status = 'parked'; result = $null
                diagnosis = "live ledger row is missing $requiredProperty" }
        }
    }
    if ([string](Get-EngineProperty $Row 'spec') -cne $Spec -or
            [string](Get-EngineProperty $Row 'task') -cne $Task -or
            -not (Test-EnginePathEqual ([string](Get-EngineProperty $Row 'worktree')) $Worktree) -or
            [string](Get-EngineProperty $Row 'phase') -cne 'build') {
        return [pscustomobject]@{ status = 'parked'; result = $null; diagnosis = 'live ledger row does not match dispatch context' }
    }
    $runId = [string](Get-EngineProperty $Row 'run_id')
    if ($runId -cnotmatch '^[0-9a-f]{32}$') {
        return [pscustomobject]@{ status = 'parked'; result = $null; diagnosis = 'live ledger row has an invalid run_id' }
    }
    $attempt = 0
    $finalObservedAt = $null
    while ($true) {
        $attempt++
        $adoptOutput = if ($attempt -eq 1) { $ChildOutputPath } else { "$ChildOutputPath.$attempt" }
        # The producer can close its row in the narrow interval after final_path appears and before
        # this poll launches -Adopt. The wrapper no longer adopts an already-terminal row, so route
        # the real event it just emitted instead of manufacturing a second terminal artifact.
        $ledgerPath = Join-Path (Join-Path (Get-EngineFullPath $StateRoot) 'progress') 'codex-run-ledger.jsonl'
        $currentRow = Get-EngineRowByRunId -LedgerPath $ledgerPath -RunId $runId
        $currentFinal = if ($null -ne $currentRow -and (Test-EngineHasProperty $currentRow 'final_path')) {
            [string](Get-EngineProperty $currentRow 'final_path')
        } else { '' }
        $currentStatus = if ($null -ne $currentRow -and (Test-EngineHasProperty $currentRow 'status')) {
            [string](Get-EngineProperty $currentRow 'status')
        } else { '' }
        if ($currentFinal -and (Test-Path -LiteralPath $currentFinal -PathType Leaf) -and
                $null -ne $currentRow -and
                $currentStatus -in @('leasing', 'running', 'stalled', 'adopting', 'orphaned')) {
            if ($null -eq $finalObservedAt) { $finalObservedAt = (Get-Date).ToUniversalTime() }
            $settleSeconds = [Math]::Max(2, [int]$script:EngineDispatchPollSeconds)
            if (((Get-Date).ToUniversalTime() - $finalObservedAt).TotalSeconds -lt $settleSeconds) {
                Start-Sleep -Seconds ([Math]::Max(1, [int]$script:EngineDispatchPollSeconds))
                continue
            }
        }
        if ($currentFinal -and (Test-Path -LiteralPath $currentFinal -PathType Leaf) -and
                $currentStatus -and
                $currentStatus -notin @('leasing', 'running', 'stalled', 'adopting', 'orphaned')) {
            $eventsRoot = Join-Path (Get-EngineFullPath $StateRoot) 'events'
            $terminalEvent = $null
            foreach ($candidate in @(Get-ChildItem -LiteralPath $eventsRoot -Filter "$runId-*.event.json" `
                        -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
                try { $candidateEvent = Get-Content -LiteralPath $candidate.FullName -Raw | ConvertFrom-Json }
                catch { continue }
                if ([string]$candidateEvent.kind -ceq 'dispatch_result' -and
                        [string]$candidateEvent.run_id -ceq $runId) {
                    $terminalEvent = [pscustomobject]@{ Path = $candidate.FullName; Event = $candidateEvent }
                    break
                }
            }
            if ($null -ne $terminalEvent) {
                Write-EngineUtf8NoBom -Path $adoptOutput -Text ("[event] $($terminalEvent.Path)" + [Environment]::NewLine)
                $routed = Read-EngineDispatchEvent -ChildOutputPath $adoptOutput `
                    -ExitCode ([int]$terminalEvent.Event.exit_code) -TaskId $Task -Worktree $Worktree `
                    -LedgerPath $ledgerPath
                $routedResult = [pscustomobject]@{
                    exit_code = [int]$terminalEvent.Event.exit_code; child_output_path = $adoptOutput
                    event_path = $routed.event_path; event = $routed.event
                    wrapper_run_id = $routed.wrapper_run_id; end_tree_digest = $routed.end_tree_digest
                    diagnosis = $routed.diagnosis
                }
                if ($routed.ok) {
                    return [pscustomobject]@{ status = 'terminal'; result = $routedResult; diagnosis = $null }
                }
                return [pscustomobject]@{ status = 'failed'; result = $routedResult; diagnosis = $routed.diagnosis }
            }
            if (((Get-Date).ToUniversalTime() - $WaitStartedAt.ToUniversalTime()).TotalSeconds -ge
                    $script:EngineDispatchMaxWaitSeconds) {
                return [pscustomobject]@{ status = 'parked'; result = $null
                    diagnosis = 'terminal ledger row did not publish its event before the four-hour wait cap' }
            }
            Start-Sleep -Seconds ([Math]::Max(1, [int]$script:EngineDispatchPollSeconds))
            continue
        }
        $result = Invoke-EngineAdopt -WrapperPath $WrapperPath -RunId $runId -Spec $Spec -Task $Task `
            -Worktree $Worktree -StateRoot $StateRoot -ChildOutputPath $adoptOutput `
            -AdoptWaitSeconds $AdoptWaitSeconds
        if ($null -ne $result.PSObject.Properties['adopt_timed_out'] -and
                [bool]$result.adopt_timed_out) {
            return [pscustomobject]@{ status = 'parked'; result = $result; diagnosis = $result.diagnosis }
        }
        $event = if ($null -ne $result.PSObject.Properties['event']) { $result.event } else { $null }
        $detail = if ($null -ne $event -and $null -ne $event.PSObject.Properties['detail']) {
            [string]$event.detail
        } else { '' }
        $eventRunId = if ($null -ne $event -and $null -ne $event.PSObject.Properties['run_id']) {
            [string]$event.run_id
        } else { '' }
        $alreadyTerminalMatch = ($result.exit_code -eq 75 -and $eventRunId -ceq $runId -and
            $detail -match 'is already terminal')
        if ($result.exit_code -ne 75 -or $alreadyTerminalMatch) {
            # Adoption can outlive the process identity observed at the top of this poll. Re-read
            # before using local liveness to classify a non-75 result, so a launcher that exited
            # during adoption cannot leave the stale pre-adopt verdict in control.
            $postAdoptRow = Get-EngineRowByRunId -LedgerPath $ledgerPath -RunId $runId
            $postAdoptFinal = if ($null -ne $postAdoptRow -and
                    (Test-EngineHasProperty $postAdoptRow 'final_path')) {
                [string](Get-EngineProperty $postAdoptRow 'final_path')
            } else { '' }
            $postAdoptLive = ($null -ne $postAdoptRow -and
                (Test-EngineLedgerRowLive $postAdoptRow))
            if (-not $postAdoptLive -and
                    (-not $postAdoptFinal -or
                        -not (Test-Path -LiteralPath $postAdoptFinal -PathType Leaf))) {
                return [pscustomobject]@{ status = 'failed'; result = $result
                    diagnosis = 'recorded dispatch process is dead and no final report exists' }
            }
            if ($alreadyTerminalMatch -and $postAdoptFinal -and
                    (Test-Path -LiteralPath $postAdoptFinal -PathType Leaf)) {
                # Re-enter at the top so the terminal event, rather than the refusal, controls the
                # result. The wrapper made the terminal decision under the ledger lock.
                continue
            }
            if ($alreadyTerminalMatch) {
                # A terminal ledger update can become visible just before its final/event files.
                # Give that publication a short bounded window; never let the raw exit-75 refusal
                # masquerade as the terminal result merely because the recorded PID is still live.
                $terminalReportDeadline = (Get-Date).ToUniversalTime().AddSeconds(
                    [int]$script:EngineDispatchTerminalReportWaitSeconds)
                $terminalFinalPublished = $false
                while ((Get-Date).ToUniversalTime() -lt $terminalReportDeadline) {
                    Start-Sleep -Milliseconds 100
                    $postAdoptRow = Get-EngineRowByRunId -LedgerPath $ledgerPath -RunId $runId
                    $postAdoptFinal = if ($null -ne $postAdoptRow -and
                            (Test-EngineHasProperty $postAdoptRow 'final_path')) {
                        [string](Get-EngineProperty $postAdoptRow 'final_path')
                    } else { '' }
                    if ($postAdoptFinal -and
                            (Test-Path -LiteralPath $postAdoptFinal -PathType Leaf)) {
                        $terminalFinalPublished = $true
                        break
                    }
                    $eventsRoot = Join-Path (Get-EngineFullPath $StateRoot) 'events'
                    $publishedEvent = $null
                    foreach ($candidate in @(Get-ChildItem -LiteralPath $eventsRoot `
                                -Filter "$runId-*.event.json" -File -ErrorAction SilentlyContinue |
                                Sort-Object LastWriteTimeUtc -Descending)) {
                        try { $candidateEvent = Get-Content -LiteralPath $candidate.FullName -Raw | ConvertFrom-Json }
                        catch { continue }
                        if ([string]$candidateEvent.kind -ceq 'dispatch_result' -and
                                [string]$candidateEvent.run_id -ceq $runId) {
                            $publishedEvent = [pscustomobject]@{ Path = $candidate.FullName; Event = $candidateEvent }
                            break
                        }
                    }
                    if ($null -ne $publishedEvent) {
                        Write-EngineUtf8NoBom -Path $adoptOutput `
                            -Text ("[event] $($publishedEvent.Path)" + [Environment]::NewLine)
                        $routed = Read-EngineDispatchEvent -ChildOutputPath $adoptOutput `
                            -ExitCode ([int]$publishedEvent.Event.exit_code) -TaskId $Task `
                            -Worktree $Worktree -LedgerPath $ledgerPath
                        $routedResult = [pscustomobject]@{
                            exit_code = [int]$publishedEvent.Event.exit_code
                            child_output_path = $adoptOutput; event_path = $routed.event_path
                            event = $routed.event; wrapper_run_id = $routed.wrapper_run_id
                            end_tree_digest = $routed.end_tree_digest; diagnosis = $routed.diagnosis
                        }
                        if ($routed.ok) {
                            return [pscustomobject]@{ status = 'terminal'; result = $routedResult; diagnosis = $null }
                        }
                        return [pscustomobject]@{ status = 'failed'; result = $routedResult; diagnosis = $routed.diagnosis }
                    }
                }
                if ($terminalFinalPublished) { continue }
                return [pscustomobject]@{ status = 'failed'; result = $result
                    diagnosis = 'terminal row has no final report' }
            }
            if ($result.diagnosis) {
                return [pscustomobject]@{ status = 'failed'; result = $result; diagnosis = $result.diagnosis }
            }
            return [pscustomobject]@{ status = 'terminal'; result = $result; diagnosis = $null }
        }
        $liveMatch = ($eventRunId -ceq $runId -and $detail -match 'remains live')
        if (-not $liveMatch) {
            return [pscustomobject]@{ status = 'parked'; result = $result
                diagnosis = 'adopt refusal did not identify the matching live dispatch row' }
        }
        # The wrapper makes this decision under the ledger lock. Its positive "remains live"
        # verdict therefore outranks a local process check made immediately before the adopt call.
        if (((Get-Date).ToUniversalTime() - $WaitStartedAt.ToUniversalTime()).TotalSeconds -ge
                $script:EngineDispatchMaxWaitSeconds) {
            return [pscustomobject]@{ status = 'parked'; result = $result
                diagnosis = 'live dispatch wait exceeded four hours' }
        }
        Start-Sleep -Seconds ([Math]::Max(1, [int]$script:EngineDispatchPollSeconds))
    }
}
