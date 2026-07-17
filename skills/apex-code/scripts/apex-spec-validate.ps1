<#
.SYNOPSIS
Deterministically validates an APEX change specification.

.DESCRIPTION
Runs four mechanical checks in a fixed order: FILES-COMPLETENESS,
NO-UNRESOLVED-MARKERS, TASK-CRITERIA-COVERAGE, and STRUCTURE. Exit 0 means
valid; exit 1 means one or more findings, each printed as
"FAIL <check>: <evidence>".

Fenced code-block content is IGNORED by all four checks alike (checks 1-3 scan only prose/tables/backtick-inline spans outside fences; check 4 STRUCTURE likewise does not count a required heading that appears only inside a fence).

FILES-COMPLETENESS mechanically classifies a token as a file path only when it
has a directory component and a 1-5 character alphanumeric extension. Runtime
and transient extensions (.exe, .dll, .bat, .cmd, .com, .log, .jsonl, .lock,
and .tmp) are mechanically exempt. Path matching is a case-insensitive,
separator-normalized, component-boundary suffix comparison.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SpecPath
)

$ErrorActionPreference = 'Stop'

$excludedExtensions = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($extension in @('.exe', '.dll', '.bat', '.cmd', '.com', '.log', '.jsonl', '.lock', '.tmp')) {
    [void]$excludedExtensions.Add($extension)
}

$inlineCodeRegex = New-Object System.Text.RegularExpressions.Regex('`+([^`]+?)`+', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
$gitRefRegex = New-Object System.Text.RegularExpressions.Regex('^(?:HEAD|[0-9A-Fa-f]{7,40}):', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
$fileExtensionRegex = New-Object System.Text.RegularExpressions.Regex('\.[A-Za-z0-9]{1,5}$', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
$headingRegex = New-Object System.Text.RegularExpressions.Regex('^##\s+(.+?)\s*$', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
# Close the fail-open where tilde fences, mismatched fence characters, and shorter closers exposed fenced structure.
$fenceRegex = New-Object System.Text.RegularExpressions.Regex('^[ ]{0,3}(?<Fence>`{3,}|~{3,})(?<Trailing>.*)$', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)

function ConvertTo-NormalizedToken {
    param([string]$Token)

    if ($null -eq $Token) {
        return ''
    }

    $value = $Token.TrimStart([char[]]@([char]96))
    $value = $value.TrimEnd([char[]]@(
        [char]96,
        [char]44,
        [char]59,
        [char]58,
        [char]46,
        [char]41,
        [char]40,
        [char]39,
        [char]34
    ))
    $value = $gitRefRegex.Replace($value, '', 1)
    return $value
}

function Get-NormalizedTokens {
    param([string]$Text)

    $tokens = New-Object 'System.Collections.Generic.List[string]'

    foreach ($match in $inlineCodeRegex.Matches($Text)) {
        foreach ($word in [regex]::Split($match.Groups[1].Value, '\s+')) {
            $normalized = ConvertTo-NormalizedToken -Token $word
            if ($normalized.Length -gt 0) {
                $tokens.Add($normalized)
            }
        }
    }

    foreach ($word in [regex]::Split($Text, '\s+')) {
        $normalized = ConvertTo-NormalizedToken -Token $word
        if ($normalized.Length -gt 0) {
            $tokens.Add($normalized)
        }
    }

    return $tokens.ToArray()
}

function Test-FilePathWord {
    param([string]$Token)

    if (($Token.IndexOf('/') -lt 0) -and ($Token.IndexOf('\') -lt 0)) {
        return $false
    }

    $lastSlash = [Math]::Max($Token.LastIndexOf('/'), $Token.LastIndexOf('\'))
    $baseName = $Token.Substring($lastSlash + 1)
    $extensionMatch = $fileExtensionRegex.Match($baseName)
    if (-not $extensionMatch.Success) {
        return $false
    }

    return -not $excludedExtensions.Contains($extensionMatch.Value)
}

function Test-BareFileName {
    param([string]$Token)

    if (($Token.IndexOf('/') -ge 0) -or ($Token.IndexOf('\') -ge 0)) {
        return $false
    }

    $extensionMatch = $fileExtensionRegex.Match($Token)
    if (-not $extensionMatch.Success) {
        return $false
    }

    return -not $excludedExtensions.Contains($extensionMatch.Value)
}

function ConvertTo-ComparablePath {
    param([string]$Path)

    return $Path.Replace('\', '/').ToLowerInvariant()
}

function Test-PathSuffixMatch {
    param(
        [string]$Left,
        [string]$Right
    )

    $leftPath = ConvertTo-ComparablePath -Path $Left
    $rightPath = ConvertTo-ComparablePath -Path $Right

    if ([string]::Equals($leftPath, $rightPath, [System.StringComparison]::Ordinal)) {
        return $true
    }

    # A bare basename never suffix-matches a path with directory components.
    if (($leftPath.IndexOf('/') -lt 0) -or ($rightPath.IndexOf('/') -lt 0)) {
        return $false
    }

    if ($leftPath.Length -lt $rightPath.Length) {
        return $rightPath.EndsWith('/' + $leftPath, [System.StringComparison]::Ordinal)
    }

    return $leftPath.EndsWith('/' + $rightPath, [System.StringComparison]::Ordinal)
}

function Add-Finding {
    param(
        [string]$Check,
        [string]$Evidence
    )

    $script:findings.Add(('FAIL {0}: {1}' -f $Check, $Evidence))
}

if (-not [System.IO.File]::Exists($SpecPath)) {
    Write-Output ('FAIL STRUCTURE: spec file not found {0}' -f $SpecPath)
    exit 1
}

try {
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $content = [System.IO.File]::ReadAllText($SpecPath, $utf8)
}
catch {
    Write-Output ('FAIL STRUCTURE: unable to read spec {0}' -f $SpecPath)
    exit 1
}

$lines = [regex]::Split($content, "`r`n|`n|`r")
$outsideFenceLines = New-Object 'System.Collections.Generic.List[object]'
$inFence = $false
$unclosedFenceLine = $null
$fenceCharacter = $null
$fenceLength = 0
$currentSection = ''

for ($index = 0; $index -lt $lines.Count; $index++) {
    $line = $lines[$index]

    $fenceMatch = $fenceRegex.Match($line)
    if ($inFence) {
        if ($fenceMatch.Success) {
            $candidateFence = $fenceMatch.Groups['Fence'].Value
            $hasOnlyTrailingSpaces = [regex]::IsMatch($fenceMatch.Groups['Trailing'].Value, '^ *$')
            if (($candidateFence[0] -eq $fenceCharacter) -and
                ($candidateFence.Length -ge $fenceLength) -and
                $hasOnlyTrailingSpaces) {
                $inFence = $false
                $unclosedFenceLine = $null
                $fenceCharacter = $null
                $fenceLength = 0
            }
        }
        continue
    }

    if ($fenceMatch.Success) {
        $openingFence = $fenceMatch.Groups['Fence'].Value
        $inFence = $true
        $unclosedFenceLine = $index + 1
        $fenceCharacter = $openingFence[0]
        $fenceLength = $openingFence.Length
        continue
    }

    $headingMatch = $headingRegex.Match($line)
    if ($headingMatch.Success) {
        $currentSection = $headingMatch.Groups[1].Value
    }

    $outsideFenceLines.Add([pscustomobject]@{
        LineNumber = $index + 1
        Text = $line
        Section = $currentSection
    })
}

$findings = New-Object 'System.Collections.Generic.List[string]'

# (1) FILES-COMPLETENESS
$filesToChange = New-Object 'System.Collections.Generic.List[string]'
foreach ($lineRecord in $outsideFenceLines) {
    if (-not [string]::Equals($lineRecord.Section, 'Files to Change', [System.StringComparison]::Ordinal)) {
        continue
    }

    $entryText = $lineRecord.Text
    if ($entryText -match '^\s*\|') {
        $cells = $entryText.Split('|')
        if ($cells.Count -gt 1) {
            $entryText = $cells[1]
        }
    }

    foreach ($token in Get-NormalizedTokens -Text $entryText) {
        if ((Test-FilePathWord -Token $token) -or (Test-BareFileName -Token $token)) {
            $filesToChange.Add($token)
        }
    }
}

$scanTexts = New-Object 'System.Collections.Generic.List[string]'
$emDashDelimiter = ' ' + [char]0x2014 + ' '
foreach ($lineRecord in $outsideFenceLines) {
    if ([string]::Equals($lineRecord.Section, 'Acceptance Criteria', [System.StringComparison]::Ordinal) -or
        [string]::Equals($lineRecord.Section, 'Permissions', [System.StringComparison]::Ordinal)) {
        $scanTexts.Add($lineRecord.Text)
        continue
    }

    if ([string]::Equals($lineRecord.Section, 'Tasks', [System.StringComparison]::Ordinal) -and
        [regex]::IsMatch($lineRecord.Text, '^\s*(?:[-*+]|\d+[.)])\s+')) {
        $markerIndex = $lineRecord.Text.IndexOf('files:', [System.StringComparison]::OrdinalIgnoreCase)
        if ($markerIndex -ge 0) {
            $afterMarker = $lineRecord.Text.Substring($markerIndex + 'files:'.Length)
            $delimiterIndex = $afterMarker.IndexOf($emDashDelimiter, [System.StringComparison]::Ordinal)
            if ($delimiterIndex -ge 0) {
                $afterMarker = $afterMarker.Substring(0, $delimiterIndex)
            }
            $scanTexts.Add($afterMarker)
        }
    }
}

foreach ($scanText in $scanTexts) {
    foreach ($token in Get-NormalizedTokens -Text $scanText) {
        if (-not (Test-FilePathWord -Token $token)) {
            continue
        }

        $matched = $false
        foreach ($fileEntry in $filesToChange) {
            if (Test-PathSuffixMatch -Left $token -Right $fileEntry) {
                $matched = $true
                break
            }
        }

        if (-not $matched) {
            Add-Finding -Check 'FILES-COMPLETENESS' -Evidence ('{0} not in Files to Change' -f $token)
        }
    }
}

# (2) NO-UNRESOLVED-MARKERS
# Close the fail-open where lowercase spellings of the existing unresolved-marker tokens passed validation.
$markerRegex = New-Object System.Text.RegularExpressions.Regex(
    '(?<![A-Za-z0-9_])(?:TBD|TODO|FIXME)(?![A-Za-z0-9_])|(?<!\?)\?\?\?(?!\?)|<placeholder>',
    ([System.Text.RegularExpressions.RegexOptions]::CultureInvariant -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
)
foreach ($lineRecord in $outsideFenceLines) {
    foreach ($match in $markerRegex.Matches($lineRecord.Text)) {
        Add-Finding -Check 'NO-UNRESOLVED-MARKERS' -Evidence ('{0} at line {1}' -f $match.Value, $lineRecord.LineNumber)
    }
}

# (3) TASK-CRITERIA-COVERAGE
$declaredTasks = New-Object 'System.Collections.Generic.List[string]'
$criterionTasks = New-Object 'System.Collections.Generic.List[string]'
$declaredSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$criterionSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$taskHeadingRegex = New-Object System.Text.RegularExpressions.Regex(
    '^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?\*\*\s*(Task\s+[0-9]+[A-Za-z]?)\b',
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
)
$taskReferenceRegex = New-Object System.Text.RegularExpressions.Regex(
    '\bTask\s+[0-9]+[A-Za-z]?\b',
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
)

foreach ($lineRecord in $outsideFenceLines) {
    if ([string]::Equals($lineRecord.Section, 'Tasks', [System.StringComparison]::Ordinal)) {
        $taskMatch = $taskHeadingRegex.Match($lineRecord.Text)
        if ($taskMatch.Success -and $declaredSet.Add($taskMatch.Groups[1].Value)) {
            $declaredTasks.Add($taskMatch.Groups[1].Value)
        }
    }

    if ([string]::Equals($lineRecord.Section, 'Acceptance Criteria', [System.StringComparison]::Ordinal)) {
        foreach ($taskMatch in $taskReferenceRegex.Matches($lineRecord.Text)) {
            if ($criterionSet.Add($taskMatch.Value)) {
                $criterionTasks.Add($taskMatch.Value)
            }
        }
    }
}

foreach ($taskLabel in $declaredTasks) {
    if (-not $criterionSet.Contains($taskLabel)) {
        Add-Finding -Check 'TASK-CRITERIA-COVERAGE' -Evidence ('{0} uncovered' -f $taskLabel)
    }
}
foreach ($taskLabel in $criterionTasks) {
    if (-not $declaredSet.Contains($taskLabel)) {
        Add-Finding -Check 'TASK-CRITERIA-COVERAGE' -Evidence ('{0} uncovered' -f $taskLabel)
    }
}

# (4) STRUCTURE
$requiredHeadings = @(
    '## Intent',
    '## Assumptions',
    '## Prerequisites',
    '## Files to Change',
    '## Tasks',
    '## Wave plan',
    '## Permissions',
    '## Specialist Context',
    '## Documentation',
    '## Acceptance Criteria',
    '## Progress'
)

if ($null -ne $unclosedFenceLine) {
    Add-Finding -Check 'STRUCTURE' -Evidence ('unterminated code fence at line {0}' -f $unclosedFenceLine)
}

foreach ($requiredHeading in $requiredHeadings) {
    $found = $false
    foreach ($lineRecord in $outsideFenceLines) {
        if ([string]::Equals($lineRecord.Text.TrimEnd(), $requiredHeading, [System.StringComparison]::Ordinal)) {
            $found = $true
            break
        }
    }

    if (-not $found) {
        Add-Finding -Check 'STRUCTURE' -Evidence ('missing heading {0}' -f $requiredHeading)
    }
}

$filesToChangeTableState = [pscustomobject]@{ SeenPipeRow = $false }
$nonEmptySections = @(
    [pscustomobject]@{
        Name = 'Files to Change'
        Section = 'Files to Change'
        QualifyingLine = {
            param($text)

            if (-not [regex]::IsMatch($text, '^\s*\|')) {
                return $false
            }

            if (-not $filesToChangeTableState.SeenPipeRow) {
                $filesToChangeTableState.SeenPipeRow = $true
                return $false
            }

            if ([regex]::IsMatch($text, '^\s*\|[\s\-:|]+\|?\s*$')) {
                return $false
            }

            foreach ($token in Get-NormalizedTokens -Text $text) {
                if ((Test-FilePathWord -Token $token) -or (Test-BareFileName -Token $token)) {
                    return $true
                }
            }

            return $false
        }
    },
    [pscustomobject]@{
        Name = '## Tasks'
        Section = 'Tasks'
        QualifyingLine = { param($text) $taskHeadingRegex.IsMatch($text) }
    },
    [pscustomobject]@{
        Name = '## Acceptance Criteria'
        Section = 'Acceptance Criteria'
        QualifyingLine = { param($text) [regex]::IsMatch($text, '^\s*(?:[-*+]|\d+[.)])\s+') }
    },
    [pscustomobject]@{
        Name = '## Permissions'
        Section = 'Permissions'
        QualifyingLine = { param($text) -not [string]::IsNullOrWhiteSpace($text) }
    }
)

foreach ($sectionRule in $nonEmptySections) {
    $hasQualifyingLine = $false
    foreach ($lineRecord in $outsideFenceLines) {
        if (-not [string]::Equals($lineRecord.Section, $sectionRule.Section, [System.StringComparison]::Ordinal)) {
            continue
        }

        if ($headingRegex.IsMatch($lineRecord.Text)) {
            continue
        }

        if (& $sectionRule.QualifyingLine $lineRecord.Text) {
            $hasQualifyingLine = $true
            break
        }
    }

    if (-not $hasQualifyingLine) {
        Add-Finding -Check 'STRUCTURE' -Evidence ('empty section {0}' -f $sectionRule.Name)
    }
}

foreach ($finding in $findings) {
    Write-Output $finding
}

if ($findings.Count -gt 0) {
    exit 1
}

exit 0
