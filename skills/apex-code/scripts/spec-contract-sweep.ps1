[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Root,

    [string[]]$Path = @('docs/drafts', 'docs/changes'),

    [string[]]$Exclude = @()
)

$ErrorActionPreference = 'Stop'
$validatorPath = Join-Path $PSScriptRoot 'apex-spec-validate.ps1'

if (-not [System.IO.Directory]::Exists($Root)) {
    exit 2
}

$rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
$existingPaths = New-Object 'System.Collections.Generic.List[string]'
foreach ($pathEntry in $Path) {
    $candidatePath = Join-Path $rootPath $pathEntry
    if ([System.IO.Directory]::Exists($candidatePath)) {
        $existingPaths.Add([System.IO.Path]::GetFullPath($candidatePath))
    }
}

if ($existingPaths.Count -eq 0) {
    exit 2
}

$versionOutput = @(& powershell.exe -NoProfile -File $validatorPath -Version 2>&1)
$versionMatch = [regex]::Match(
    ($versionOutput -join [Environment]::NewLine),
    '(?m)^apex-spec-validate contract (?<Version>\S+)\s*$'
)
if (($LASTEXITCODE -ne 0) -or (-not $versionMatch.Success)) {
    throw 'Unable to obtain the spec contract version from the validator.'
}
$contractVersion = $versionMatch.Groups['Version'].Value

$specsByPath = New-Object 'System.Collections.Generic.Dictionary[string,System.IO.FileInfo]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($existingPath in $existingPaths) {
    foreach ($spec in [System.IO.Directory]::GetFiles($existingPath, '*.md', [System.IO.SearchOption]::TopDirectoryOnly)) {
        $specInfo = New-Object System.IO.FileInfo($spec)
        if (-not $specsByPath.ContainsKey($specInfo.FullName)) {
            $specsByPath.Add($specInfo.FullName, $specInfo)
        }
    }
}

$specRecords = foreach ($spec in $specsByPath.Values) {
    $relativePath = $spec.FullName.Substring($rootPath.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
    [pscustomobject]@{
        File = $spec
        RelativePath = $relativePath
    }
}
$specRecords = @($specRecords | Sort-Object -Property RelativePath)

$passCount = 0
$failCount = 0
$errorCount = 0

foreach ($specRecord in $specRecords) {
    $isExcluded = $false
    foreach ($excludeEntry in $Exclude) {
        $normalizedExclude = $excludeEntry.Replace('\', '/')
        if (($specRecord.File.Name -like $excludeEntry) -or ($specRecord.RelativePath -like $normalizedExclude)) {
            $isExcluded = $true
            break
        }
    }

    if ($isExcluded) {
        Write-Output ('SKIP {0} (excluded)' -f $specRecord.RelativePath)
        continue
    }

    $childOutput = @(& powershell.exe -NoProfile -File $validatorPath -SpecPath $specRecord.File.FullName 2>&1)
    $childExitCode = $LASTEXITCODE

    if (($childExitCode -ne 0) -and ($childExitCode -ne 1)) {
        $errorCount++
        Write-Output ('ERROR {0}: exit {1}' -f $specRecord.RelativePath, $childExitCode)
        continue
    }

    $findings = @(
        $childOutput |
            ForEach-Object { $_.ToString() } |
            Where-Object { $_ -match '^FAIL [A-Z][A-Z0-9-]*: ' }
    )

    if ($childExitCode -eq 0) {
        $passCount++
        Write-Output ('PASS {0}' -f $specRecord.RelativePath)
        continue
    }

    $failCount++
    Write-Output ('FAIL {0}: {1}' -f $specRecord.RelativePath, ($findings -join '; '))
}

Write-Output (
    'SWEEP contract {0} - {1} specs, {2} pass, {3} fail, {4} error' -f
        $contractVersion,
        $specRecords.Count,
        $passCount,
        $failCount,
        $errorCount
)
exit 0
