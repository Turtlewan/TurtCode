<#
.SYNOPSIS
Deterministically validates an APEX change specification.

.DESCRIPTION
Runs six mechanical checks in a fixed order: FILES-COMPLETENESS,
NO-UNRESOLVED-MARKERS, TASK-CRITERIA-COVERAGE, STRUCTURE, EXEC-MANIFEST, and ACCEPTANCE-CHECK.
Exit 0 means valid; exit 1 means one or more findings, each printed as
"FAIL <check>: <evidence>".

Fenced code-block content is IGNORED by the original four checks alike (checks
1-3 scan only prose/tables/backtick-inline spans outside fences; check 4
STRUCTURE likewise does not count a required heading that appears only inside
a fence). Check 5 EXEC-MANIFEST reads the single fence in the optional
Execution manifest section. Check 6 ACCEPTANCE-CHECK reads only exact
powershell apex-accept fences under Acceptance Criteria.

FILES-COMPLETENESS mechanically classifies a token as a file path only when it
has a directory component and a 1-5 character alphanumeric extension. Runtime
and transient extensions (.exe, .dll, .bat, .cmd, .com, .log, .jsonl, .lock,
and .tmp) are mechanically exempt. Path matching is a case-insensitive,
separator-normalized, component-boundary suffix comparison.
#>
[CmdletBinding(DefaultParameterSetName = 'Validate')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Validate')]
    [string]$SpecPath,

    [Parameter(ParameterSetName = 'Version')]
    [switch]$Version
)

$SpecContractVersion = '1.3.0'
$ErrorActionPreference = 'Stop'

if ($Version) {
    Write-Output ('apex-spec-validate contract {0}' -f $SpecContractVersion)
    exit 0
}

Write-Host ('[spec-validate] contract {0}' -f $SpecContractVersion)

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

function Test-ManifestObjectProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject) {
        return $false
    }

    foreach ($property in $Object.PSObject.Properties) {
        if ([string]::Equals($property.Name, $Name, [System.StringComparison]::Ordinal)) {
            return $true
        }
    }

    return $false
}

function Get-ManifestObjectProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    foreach ($property in $Object.PSObject.Properties) {
        if ([string]::Equals($property.Name, $Name, [System.StringComparison]::Ordinal)) {
            return ,$property.Value
        }
    }

    return $null
}

function Test-ManifestInteger {
    param([object]$Value)

    return (($Value -is [sbyte]) -or
        ($Value -is [byte]) -or
        ($Value -is [int16]) -or
        ($Value -is [uint16]) -or
        ($Value -is [int32]) -or
        ($Value -is [uint32]) -or
        ($Value -is [int64]) -or
        ($Value -is [uint64]))
}

function Test-ManifestRepoRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf('\') -ge 0 -or $Path.Contains('//')) {
        return $false
    }

    $remainder = $null
    if ([regex]::IsMatch($Path, '^[A-Za-z]:/')) {
        $remainder = $Path.Substring(3)
    }
    elseif ($Path.StartsWith('/', [System.StringComparison]::Ordinal)) {
        $remainder = $Path.Substring(1)
    }
    else {
        return $false
    }

    if ($remainder.Length -eq 0) {
        return $true
    }
    if ($Path.EndsWith('/', [System.StringComparison]::Ordinal)) {
        return $false
    }

    foreach ($segment in $remainder.Split('/')) {
        if ($segment.Length -eq 0 -or $segment -eq '.' -or $segment -eq '..') {
            return $false
        }
    }

    return $true
}

function Test-ManifestRelativePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or
        $Path.IndexOf('\') -ge 0 -or
        $Path.StartsWith('/', [System.StringComparison]::Ordinal) -or
        [regex]::IsMatch($Path, '^[A-Za-z]:') -or
        $Path.Contains('//') -or
        $Path.EndsWith('/', [System.StringComparison]::Ordinal)) {
        return $false
    }

    foreach ($segment in $Path.Split('/')) {
        if ($segment.Length -eq 0 -or $segment -eq '.' -or $segment -eq '..') {
            return $false
        }
    }

    return $true
}

function Test-AbsolutePathToken {
    param([string]$Path)

    return ([regex]::IsMatch($Path, '^[A-Za-z]:[\\/]') -or $Path.StartsWith('/', [System.StringComparison]::Ordinal))
}

function ConvertTo-ManifestIdentity {
    param(
        [string]$Root,
        [string]$RelativePath
    )

    $rootWithoutTrailingSlash = $Root.TrimEnd('/')
    return ('{0}/{1}' -f $rootWithoutTrailingSlash, $RelativePath).ToLowerInvariant()
}

# Used only by chain rules; existing validator identities deliberately stay unchanged.
function ConvertTo-ChainCanonicalPath {
    param([string]$Path)

    $segments = @($Path.Split('/') | ForEach-Object {
        $_.TrimEnd([char[]]@([char]46, [char]32)).ToLowerInvariant()
    })
    return ($segments -join '/')
}

function ConvertTo-AbsoluteManifestIdentity {
    param([string]$Path)

    return $Path.Replace('\', '/').TrimEnd('/').ToLowerInvariant()
}

function ConvertFrom-MarkdownCell {
    param([string]$Text)

    $value = $Text.Trim()
    if ($value.Length -ge 2 -and $value[0] -eq [char]96 -and $value[$value.Length - 1] -eq [char]96) {
        $value = $value.Substring(1, $value.Length - 2).Trim()
    }
    return $value
}

function Get-TaskFileTokens {
    param([string]$Text)

    $tokens = New-Object 'System.Collections.Generic.List[string]'
    $markerIndex = $Text.LastIndexOf('files:', [System.StringComparison]::OrdinalIgnoreCase)
    if ($markerIndex -lt 0) {
        return $tokens.ToArray()
    }

    $fileText = $Text.Substring($markerIndex + 'files:'.Length)
    $delimiterIndex = $fileText.IndexOf((' ' + [char]0x2014 + ' '), [System.StringComparison]::Ordinal)
    if ($delimiterIndex -ge 0) {
        $fileText = $fileText.Substring(0, $delimiterIndex)
    }

    $inlineMatches = $inlineCodeRegex.Matches($fileText)
    if ($inlineMatches.Count -gt 0) {
        foreach ($match in $inlineMatches) {
            foreach ($part in $match.Groups[1].Value.Split(',')) {
                $value = $part.Trim()
                if ($value.Length -gt 0) {
                    $tokens.Add($value)
                }
            }
        }
        return $tokens.ToArray()
    }

    foreach ($part in $fileText.Split(',')) {
        $value = (ConvertTo-NormalizedToken -Token $part.Trim())
        if ($value.Length -gt 0 -and
            (($value.IndexOf('/') -ge 0) -or ($value.IndexOf('\') -ge 0) -or $fileExtensionRegex.IsMatch($value))) {
            $tokens.Add($value)
        }
    }

    return $tokens.ToArray()
}

if (-not [System.IO.File]::Exists($SpecPath)) {
    Write-Output ('FAIL STRUCTURE: spec file not found {0}' -f $SpecPath)
    exit 1
}

# Trusted checks: this grammar guards accidental paths/location changes, not execution.
function Get-AcceptanceGrammarRefusals {
    param([string]$Text)
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$parseErrors)
    foreach ($command in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        if ($name -imatch '^(cd|Set-Location|Push-Location)$') {
            'prohibited location command {0}' -f $name
        }
    }
    $previous = $null
    foreach ($token in $tokens) {
        if ($token.Kind -in @('Generic', 'Identifier', 'StringLiteral', 'StringExpandable')) {
            $quoted = $token.Kind -in @('StringLiteral', 'StringExpandable')
            $value = $token.Text
            if ($quoted) { $value = $token.Value }
            $patternOperand = $quoted -and ($previous -in @('Imatch', 'Inotmatch', 'Cmatch', 'Cnotmatch'))
            if (-not $patternOperand -and $value -match '^(?:[A-Za-z]:[\\/]|\\\\|/)') {
                'prohibited path token {0}' -f $token.Text
            }
        }
        if ($token.Kind -notin @('NewLine', 'Comment', 'LineContinuation')) { $previous = $token.Kind.ToString() }
    }
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
$acceptanceSection = ''
$acceptanceLeadingLine = ''
$acceptanceManifestIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$executionManifestSectionPresent = $false
$executionManifestFences = New-Object 'System.Collections.Generic.List[object]'
$activeExecutionManifestFence = $null
$acceptanceFences = New-Object 'System.Collections.Generic.List[object]'
$activeAcceptanceFence = $null

for ($index = 0; $index -lt $lines.Count; $index++) {
    $line = $lines[$index]

    $fenceMatch = $fenceRegex.Match($line)
    if ($inFence) {
        if ($fenceMatch.Success) {
            $candidateFence = $fenceMatch.Groups['Fence'].Value
            $hasOnlyTrailingSpaces = [regex]::IsMatch($fenceMatch.Groups['Trailing'].Value, '^[ \t]*$')
            if (($candidateFence[0] -eq $fenceCharacter) -and
                ($candidateFence.Length -ge $fenceLength) -and
                $hasOnlyTrailingSpaces) {
                $inFence = $false
                $unclosedFenceLine = $null
                $fenceCharacter = $null
                $fenceLength = 0
                $activeExecutionManifestFence = $null
                $activeAcceptanceFence = $null
                continue
            }
        }
        if ($null -ne $activeAcceptanceFence) { $activeAcceptanceFence.Lines.Add($line) }
        if (-not $fenceMatch.Success -and $null -ne $activeExecutionManifestFence) {
            $activeExecutionManifestFence.Lines.Add($line)
        }
        continue
    }

    if ($fenceMatch.Success) {
        $openingFence = $fenceMatch.Groups['Fence'].Value
        $inFence = $true
        $unclosedFenceLine = $index + 1
        $fenceCharacter = $openingFence[0]
        $fenceLength = $openingFence.Length
        if ([string]::Equals($currentSection, 'Execution manifest', [System.StringComparison]::Ordinal)) {
            $activeExecutionManifestFence = [pscustomobject]@{
                LineNumber = $index + 1
                InfoString = $fenceMatch.Groups['Trailing'].Value.Trim()
                Lines = New-Object 'System.Collections.Generic.List[string]'
            }
            $executionManifestFences.Add($activeExecutionManifestFence)
        }
        if ([string]::Equals($acceptanceSection, 'Acceptance Criteria', [System.StringComparison]::Ordinal) -and
            [string]::Equals($fenceMatch.Groups['Trailing'].Value.Trim(), 'powershell apex-accept', [System.StringComparison]::Ordinal)) {
            $activeAcceptanceFence = [pscustomobject]@{
                LineNumber = $index + 1
                LeadingLine = $acceptanceLeadingLine
                Lines = New-Object 'System.Collections.Generic.List[string]'
            }
            $acceptanceFences.Add($activeAcceptanceFence)
        }
        continue
    }

    # Mirror Get-EngineAcceptanceLines: blanks, continuations, and fences keep
    # the most recent bullet/numbered criterion current until a criterion or H2.
    if ($line -match '^ {0,3}##[ \t]+(.+?)[ \t]*$') {
        $acceptanceSection = $Matches[1]; $acceptanceLeadingLine = ''
    } elseif ($acceptanceSection -ceq 'Acceptance Criteria' -and $line -match '^(?:- |[0-9]+[.)] )') {
        $acceptanceLeadingLine = $line
    }

    $headingMatch = $headingRegex.Match($line)
    if ($headingMatch.Success) {
        $currentSection = $headingMatch.Groups[1].Value
        if ([string]::Equals($currentSection, 'Execution manifest', [System.StringComparison]::Ordinal)) {
            $executionManifestSectionPresent = $true
        }
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

# (5) EXEC-MANIFEST
if ($executionManifestSectionPresent) {
    try {
        if ($executionManifestFences.Count -ne 1) {
            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('Execution manifest section must contain exactly one fenced block; found {0}' -f $executionManifestFences.Count)
        }
        else {
            $manifestFence = $executionManifestFences[0]
            if (-not [string]::Equals($manifestFence.InfoString, 'json apex-manifest', [System.StringComparison]::Ordinal)) {
                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('fence at line {0} must use info string json apex-manifest' -f $manifestFence.LineNumber)
            }
            else {
                $manifest = $null
                $manifestParsed = $true
                try {
                    $manifest = ($manifestFence.Lines.ToArray() -join "`n") | ConvertFrom-Json -ErrorAction Stop
                }
                catch {
                    $manifestParsed = $false
                    Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('malformed JSON in fence at line {0}' -f $manifestFence.LineNumber)
                }

                if ($manifestParsed) {
                    $shapeValid = $true
                    if (-not ($manifest -is [pscustomobject])) {
                        Add-Finding -Check 'EXEC-MANIFEST' -Evidence 'manifest root must be a JSON object'
                        $shapeValid = $false
                    }

                    $versionValue = $null
                    $hasVersion = $shapeValid -and (Test-ManifestObjectProperty -Object $manifest -Name 'version')
                    if ($hasVersion) {
                        $versionValue = Get-ManifestObjectProperty -Object $manifest -Name 'version'
                    }
                    else {
                        Add-Finding -Check 'EXEC-MANIFEST' -Evidence 'missing version'
                        $shapeValid = $false
                    }
                    if ($hasVersion -and ((-not (Test-ManifestInteger -Value $versionValue)) -or $versionValue -ne 1)) {
                        Add-Finding -Check 'EXEC-MANIFEST' -Evidence 'version must be integer 1'
                        $shapeValid = $false
                    }

                    $repoRoots = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
                    $reposValue = $null
                    if ($manifest -is [pscustomobject] -and (Test-ManifestObjectProperty -Object $manifest -Name 'repos')) {
                        $reposValue = Get-ManifestObjectProperty -Object $manifest -Name 'repos'
                    }
                    if (-not ($reposValue -is [pscustomobject]) -or $reposValue.PSObject.Properties.Count -eq 0) {
                        Add-Finding -Check 'EXEC-MANIFEST' -Evidence 'repos must be a nonempty JSON object'
                        $shapeValid = $false
                    }
                    else {
                        foreach ($repoProperty in $reposValue.PSObject.Properties) {
                            if ([string]::IsNullOrWhiteSpace($repoProperty.Name) -or
                                -not ($repoProperty.Value -is [string]) -or
                                -not (Test-ManifestRepoRoot -Path $repoProperty.Value)) {
                                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('repo {0} must have an absolute canonical forward-slash root' -f $repoProperty.Name)
                                $shapeValid = $false
                                continue
                            }
                            if ($repoRoots.ContainsKey($repoProperty.Name)) {
                                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('duplicate repo key {0}' -f $repoProperty.Name)
                                $shapeValid = $false
                                continue
                            }
                            $repoRoots.Add($repoProperty.Name, $repoProperty.Value)
                        }
                    }

                    $tasksValue = $null
                    if ($manifest -is [pscustomobject] -and (Test-ManifestObjectProperty -Object $manifest -Name 'tasks')) {
                        $tasksValue = Get-ManifestObjectProperty -Object $manifest -Name 'tasks'
                    }
                    if (-not ($tasksValue -is [System.Array])) {
                        Add-Finding -Check 'EXEC-MANIFEST' -Evidence 'tasks must be a JSON array'
                        $shapeValid = $false
                        $tasksValue = @()
                    }

                    $taskDeclarationRegex = New-Object System.Text.RegularExpressions.Regex(
                        '^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?\*\*\s*(?<Title>Task\s+(?<Id>[0-9]+[A-Za-z]?)(?=\b).*?)\*\*',
                        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
                    )
                    $ownerWordRegex = New-Object System.Text.RegularExpressions.Regex(
                        '\bOWNER\b',
                        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
                    )
                    $taskDeclarations = New-Object 'System.Collections.Generic.List[object]'
                    foreach ($lineRecord in $outsideFenceLines) {
                        if (-not [string]::Equals($lineRecord.Section, 'Tasks', [System.StringComparison]::Ordinal)) {
                            continue
                        }
                        $declarationMatch = $taskDeclarationRegex.Match($lineRecord.Text)
                        if (-not $declarationMatch.Success) {
                            continue
                        }

                        $title = $declarationMatch.Groups['Title'].Value
                        $isHostOwner = ($title.IndexOf('(HOST)', [System.StringComparison]::Ordinal) -ge 0) -or $ownerWordRegex.IsMatch($title)
                        $taskDeclarations.Add([pscustomobject]@{
                            Id = $declarationMatch.Groups['Id'].Value.ToLowerInvariant()
                            Title = $title
                            IsHostOwner = $isHostOwner
                            Files = @(Get-TaskFileTokens -Text $lineRecord.Text)
                            LineNumber = $lineRecord.LineNumber
                        })
                    }

                    $coderDeclarations = New-Object 'System.Collections.Generic.List[object]'
                    $hostOwnerDeclarations = New-Object 'System.Collections.Generic.List[object]'
                    $coderIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($declaration in $taskDeclarations) {
                        if ($declaration.IsHostOwner) {
                            $hostOwnerDeclarations.Add($declaration)
                        }
                        else {
                            $coderDeclarations.Add($declaration)
                            if (-not $coderIds.Add($declaration.Id)) {
                                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('duplicate coder task ID {0}' -f $declaration.Id)
                            }
                        }
                    }

                    $allowedEfforts = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
                    foreach ($effortName in @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')) {
                        [void]$allowedEfforts.Add($effortName)
                    }
                    $frontmatterEffort = 'medium'
                    $frontmatterEffortPresent = $false
                    if ($lines.Count -gt 0 -and [string]::Equals($lines[0].Trim(), '---', [System.StringComparison]::Ordinal)) {
                        for ($frontmatterIndex = 1; $frontmatterIndex -lt $lines.Count; $frontmatterIndex++) {
                            if ([string]::Equals($lines[$frontmatterIndex].Trim(), '---', [System.StringComparison]::Ordinal)) {
                                break
                            }
                            $effortMatch = [regex]::Match($lines[$frontmatterIndex], '^coder_effort:\s*(.*?)\s*$')
                            if ($effortMatch.Success) {
                                $frontmatterEffort = $effortMatch.Groups[1].Value.Trim().Trim([char[]]@([char]39, [char]34))
                                $frontmatterEffortPresent = $true
                            }
                        }
                    }

                    $manifestTasks = New-Object 'System.Collections.Generic.List[object]'
                    $manifestIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                    $manifestIdRegex = New-Object System.Text.RegularExpressions.Regex('^[0-9]+[A-Za-z]?$', [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
                    $usesDefaultEffort = $false

                    foreach ($taskValue in $tasksValue) {
                        if (-not ($taskValue -is [pscustomobject])) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence 'each tasks entry must be a JSON object'
                            $shapeValid = $false
                            continue
                        }

                        $idValue = $null
                        if (Test-ManifestObjectProperty -Object $taskValue -Name 'id') {
                            $idValue = Get-ManifestObjectProperty -Object $taskValue -Name 'id'
                        }
                        if (-not ($idValue -is [string]) -or -not $manifestIdRegex.IsMatch($idValue)) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence 'task id must match a Tasks number with an optional letter suffix'
                            $shapeValid = $false
                            continue
                        }
                        $canonicalId = $idValue.ToLowerInvariant()
                        [void]$acceptanceManifestIds.Add($canonicalId)
                        if (-not $manifestIds.Add($canonicalId)) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('duplicate manifest task ID {0}' -f $idValue)
                            $shapeValid = $false
                        }

                        $repoValue = $null
                        if (Test-ManifestObjectProperty -Object $taskValue -Name 'repo') {
                            $repoValue = Get-ManifestObjectProperty -Object $taskValue -Name 'repo'
                        }
                        if (-not ($repoValue -is [string]) -or [string]::IsNullOrWhiteSpace($repoValue) -or -not $repoRoots.ContainsKey($repoValue)) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('task {0} has missing or unknown repo' -f $idValue)
                            $shapeValid = $false
                        }

                        $filesValue = $null
                        if (Test-ManifestObjectProperty -Object $taskValue -Name 'files') {
                            $filesValue = Get-ManifestObjectProperty -Object $taskValue -Name 'files'
                        }
                        if (-not ($filesValue -is [System.Array]) -or $filesValue.Count -eq 0) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('task {0} files must be a nonempty JSON array' -f $idValue)
                            $shapeValid = $false
                            $filesValue = @()
                        }

                        $dependsValue = $null
                        if (Test-ManifestObjectProperty -Object $taskValue -Name 'depends_on') {
                            $dependsValue = Get-ManifestObjectProperty -Object $taskValue -Name 'depends_on'
                        }
                        if (-not ($dependsValue -is [System.Array])) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('task {0} depends_on must be a JSON array' -f $idValue)
                            $shapeValid = $false
                            $dependsValue = @()
                        }

                        $effortValue = $frontmatterEffort
                        if (Test-ManifestObjectProperty -Object $taskValue -Name 'effort') {
                            $effortValue = Get-ManifestObjectProperty -Object $taskValue -Name 'effort'
                        }
                        else {
                            $usesDefaultEffort = $true
                        }
                        if (-not ($effortValue -is [string]) -or -not $allowedEfforts.Contains($effortValue)) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('task {0} effort must be low, medium, high, xhigh, max, or ultra' -f $idValue)
                            $shapeValid = $false
                        }

                        $manifestFiles = New-Object 'System.Collections.Generic.List[object]'
                        $taskPathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                        foreach ($fileValue in $filesValue) {
                            if (-not ($fileValue -is [pscustomobject])) {
                                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('task {0} files entries must be JSON objects' -f $idValue)
                                $shapeValid = $false
                                continue
                            }
                            $pathValue = $null
                            $opValue = $null
                            if (Test-ManifestObjectProperty -Object $fileValue -Name 'path') {
                                $pathValue = Get-ManifestObjectProperty -Object $fileValue -Name 'path'
                            }
                            if (Test-ManifestObjectProperty -Object $fileValue -Name 'op') {
                                $opValue = Get-ManifestObjectProperty -Object $fileValue -Name 'op'
                            }
                            if (-not ($pathValue -is [string]) -or -not (Test-ManifestRelativePath -Path $pathValue)) {
                                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('task {0} has a noncanonical file path' -f $idValue)
                                $shapeValid = $false
                                continue
                            }
                            if (-not ($opValue -is [string]) -or $opValue -cnotmatch '^(?:create|modify|delete)$') {
                                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('task {0} file {1} has invalid op' -f $idValue, $pathValue)
                                $shapeValid = $false
                                continue
                            }
                            if (-not $taskPathSet.Add($pathValue)) {
                                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('task {0} repeats file path {1}' -f $idValue, $pathValue)
                                $shapeValid = $false
                                continue
                            }
                            $manifestFiles.Add([pscustomobject]@{ Path = $pathValue; Op = $opValue })
                        }

                        $dependencies = New-Object 'System.Collections.Generic.List[string]'
                        $dependencySet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                        foreach ($dependencyValue in $dependsValue) {
                            if (-not ($dependencyValue -is [string]) -or -not $manifestIdRegex.IsMatch($dependencyValue)) {
                                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('task {0} has an invalid dependency ID' -f $idValue)
                                $shapeValid = $false
                                continue
                            }
                            $canonicalDependency = $dependencyValue.ToLowerInvariant()
                            if (-not $dependencySet.Add($canonicalDependency)) {
                                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('task {0} repeats dependency {1}' -f $idValue, $dependencyValue)
                                $shapeValid = $false
                                continue
                            }
                            $dependencies.Add($canonicalDependency)
                        }

                        $chainValue = $null
                        if (Test-ManifestObjectProperty -Object $taskValue -Name 'chain') {
                            $chainValue = Get-ManifestObjectProperty -Object $taskValue -Name 'chain'
                            # .NET's $ also matches before a final LF; the entire name must match.
                            if (-not ($chainValue -is [string]) -or $chainValue -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or $chainValue.Contains("`n")) {
                                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('task {0} has invalid chain' -f $idValue)
                                $chainValue = $null
                            }
                        }

                        $manifestTasks.Add([pscustomobject]@{
                            Id = $canonicalId
                            Repo = $repoValue
                            Files = $manifestFiles
                            DependsOn = $dependencies
                            Effort = $effortValue
                            Chain = $chainValue
                        })
                    }

                    if ($usesDefaultEffort -and $frontmatterEffortPresent -and -not $allowedEfforts.Contains($frontmatterEffort)) {
                        Add-Finding -Check 'EXEC-MANIFEST' -Evidence 'frontmatter coder_effort used by the manifest is invalid'
                        $shapeValid = $false
                    }

                    foreach ($coderId in $coderIds) {
                        if (-not $manifestIds.Contains($coderId)) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('coder task {0} is missing from manifest' -f $coderId)
                        }
                    }
                    foreach ($manifestId in $manifestIds) {
                        if (-not $coderIds.Contains($manifestId)) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('manifest task {0} is not a coder task' -f $manifestId)
                        }
                    }

                    $manifestTaskById = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($manifestTask in $manifestTasks) {
                        if (-not $manifestTaskById.ContainsKey($manifestTask.Id)) {
                            $manifestTaskById.Add($manifestTask.Id, $manifestTask)
                        }
                    }

                    # Derive chain order from known in-chain dependency edges, never JSON order.
                    $chains = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
                    foreach ($task in $manifestTasks) {
                        if ($null -eq $task.Chain) { continue }
                        if (-not $chains.ContainsKey($task.Chain)) {
                            $chains.Add($task.Chain, [pscustomobject]@{
                                Members = (New-Object 'System.Collections.Generic.List[object]')
                                Order = (New-Object 'System.Collections.Generic.List[object]')
                                Valid = $true
                                SharedOps = (New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal))
                            })
                        }
                        $chains[$task.Chain].Members.Add($task)
                    }
                    foreach ($chainName in $chains.Keys) {
                        $chain = $chains[$chainName]
                        $heads = New-Object 'System.Collections.Generic.List[object]'
                        $successors = @{}
                        foreach ($member in $chain.Members) {
                            $predecessors = @($member.DependsOn | Where-Object {
                                $manifestTaskById.ContainsKey($_) -and $manifestTaskById[$_].Chain -ceq $chainName
                            })
                            if ($predecessors.Count -eq 0) { $heads.Add($member) }
                            elseif ($predecessors.Count -ne 1) { $chain.Valid = $false }
                            foreach ($predecessor in $predecessors) {
                                if ($successors.ContainsKey($predecessor)) { $chain.Valid = $false }
                                else { $successors[$predecessor] = $member }
                            }
                        }
                        if ($heads.Count -ne 1) { $chain.Valid = $false }
                        if ($chain.Valid) {
                            $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                            $current = $heads[0]
                            while ($null -ne $current -and $visited.Add($current.Id)) {
                                $chain.Order.Add($current)
                                if ($successors.ContainsKey($current.Id)) { $current = $successors[$current.Id] }
                                else { $current = $null }
                            }
                            if ($null -ne $current -or $visited.Count -ne $chain.Members.Count) { $chain.Valid = $false }
                        }
                        if (-not $chain.Valid) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('chain {0} must form one linear dependency path (one head, one predecessor per later member, no branching, all members visited)' -f $chainName)
                            continue
                        }

                        $listings = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
                        foreach ($member in $chain.Order) {
                            if (-not ($member.Repo -is [string]) -or -not $repoRoots.ContainsKey($member.Repo)) { continue }
                            foreach ($file in $member.Files) {
                                $identity = ConvertTo-ChainCanonicalPath -Path ($repoRoots[$member.Repo].TrimEnd('/') + '/' + $file.Path)
                                if (-not $listings.ContainsKey($identity)) {
                                    $listings.Add($identity, (New-Object 'System.Collections.Generic.List[object]'))
                                }
                                $listings[$identity].Add([pscustomobject]@{ TaskId = $member.Id; Path = $file.Path.Replace('\', '/'); Op = $file.Op })
                            }
                        }
                        foreach ($identity in $listings.Keys) {
                            $entries = $listings[$identity]
                            if ($entries.Count -lt 2) { continue }
                            $first = $entries[0]
                            $chain.SharedOps.Add($identity, $first.Op)
                            for ($i = 0; $i -lt $entries.Count; $i++) {
                                $entry = $entries[$i]
                                if (-not [string]::Equals($first.Path, $entry.Path, [System.StringComparison]::Ordinal)) {
                                    Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('chain {0} lists one file with different spellings: {1}, {2}' -f $chainName, $first.Path, $entry.Path)
                                }
                                if (($i -eq 0 -and $entry.Op -cnotmatch '^(create|modify)$') -or ($i -gt 0 -and $entry.Op -cne 'modify')) {
                                    Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('chain {0} shared path {1} requires first create|modify and later modify (task {2})' -f $chainName, $entry.Path, $entry.TaskId)
                                }
                            }
                        }
                    }

                    $coderOwnedIdentities = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                    $manifestFileRecords = New-Object 'System.Collections.Generic.List[object]'
                    foreach ($manifestTask in $manifestTasks) {
                        if (-not ($manifestTask.Repo -is [string]) -or -not $repoRoots.ContainsKey($manifestTask.Repo)) {
                            continue
                        }
                        $taskRoot = $repoRoots[$manifestTask.Repo]
                        foreach ($manifestFile in $manifestTask.Files) {
                            $identity = ConvertTo-ManifestIdentity -Root $taskRoot -RelativePath $manifestFile.Path
                            [void]$coderOwnedIdentities.Add($identity)
                            $manifestFileRecords.Add([pscustomobject]@{
                                Identity = $identity
                                Path = $manifestFile.Path
                                Op = $manifestFile.Op
                                TaskId = $manifestTask.Id
                                Chain = $manifestTask.Chain
                                ChainIdentity = (ConvertTo-ChainCanonicalPath -Path ($taskRoot.TrimEnd('/') + '/' + $manifestFile.Path))
                            })
                        }
                    }

                    for ($i = 0; $i -lt $manifestFileRecords.Count; $i++) {
                        $left = $manifestFileRecords[$i]
                        for ($j = $i + 1; $j -lt $manifestFileRecords.Count; $j++) {
                            $right = $manifestFileRecords[$j]
                            if ($null -eq $left.Chain -and $null -eq $right.Chain) { continue }
                            if ($left.ChainIdentity.StartsWith($right.ChainIdentity + '/', [System.StringComparison]::OrdinalIgnoreCase) -or
                                $right.ChainIdentity.StartsWith($left.ChainIdentity + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
                                $overlapChain = $left.Chain
                                if ($null -eq $overlapChain) { $overlapChain = $right.Chain }
                                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('chain {0} has ancestor/descendant path overlap: {1}, {2}' -f $overlapChain, $left.Path, $right.Path)
                            }
                        }
                    }

                    foreach ($coderDeclaration in $coderDeclarations) {
                        if (-not $manifestTaskById.ContainsKey($coderDeclaration.Id)) {
                            continue
                        }
                        $manifestTask = $manifestTaskById[$coderDeclaration.Id]
                        if (-not ($manifestTask.Repo -is [string]) -or -not $repoRoots.ContainsKey($manifestTask.Repo)) {
                            continue
                        }
                        $declaredFileIdentities = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                        foreach ($declaredFile in $coderDeclaration.Files) {
                            if (Test-AbsolutePathToken -Path $declaredFile) {
                                [void]$declaredFileIdentities.Add((ConvertTo-AbsoluteManifestIdentity -Path $declaredFile))
                            }
                            elseif (Test-ManifestRelativePath -Path $declaredFile) {
                                [void]$declaredFileIdentities.Add((ConvertTo-ManifestIdentity -Root $repoRoots[$manifestTask.Repo] -RelativePath $declaredFile))
                            }
                        }

                        $manifestTaskIdentities = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                        foreach ($manifestFile in $manifestTask.Files) {
                            [void]$manifestTaskIdentities.Add((ConvertTo-ManifestIdentity -Root $repoRoots[$manifestTask.Repo] -RelativePath $manifestFile.Path))
                        }
                        $sameFiles = $declaredFileIdentities.Count -gt 0 -and $declaredFileIdentities.Count -eq $manifestTaskIdentities.Count
                        if ($sameFiles) {
                            foreach ($identity in $manifestTaskIdentities) {
                                if (-not $declaredFileIdentities.Contains($identity)) {
                                    $sameFiles = $false
                                    break
                                }
                            }
                        }
                        if (-not $sameFiles) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('task {0} manifest files do not equal its Tasks files list' -f $coderDeclaration.Id)
                        }
                    }

                    $hostOwnedIdentities = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($hostDeclaration in $hostOwnerDeclarations) {
                        foreach ($hostFile in $hostDeclaration.Files) {
                            if (Test-AbsolutePathToken -Path $hostFile) {
                                [void]$hostOwnedIdentities.Add((ConvertTo-AbsoluteManifestIdentity -Path $hostFile))
                            }
                            elseif (Test-ManifestRelativePath -Path $hostFile) {
                                foreach ($repoRoot in $repoRoots.Values) {
                                    [void]$hostOwnedIdentities.Add((ConvertTo-ManifestIdentity -Root $repoRoot -RelativePath $hostFile))
                                }
                            }
                        }
                    }

                    $allOwnedIdentities = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($identity in $coderOwnedIdentities) { [void]$allOwnedIdentities.Add($identity) }
                    foreach ($identity in $hostOwnedIdentities) { [void]$allOwnedIdentities.Add($identity) }

                    $filesTableRows = New-Object 'System.Collections.Generic.List[object]'
                    foreach ($lineRecord in $outsideFenceLines) {
                        if (-not [string]::Equals($lineRecord.Section, 'Files to Change', [System.StringComparison]::Ordinal) -or
                            -not [regex]::IsMatch($lineRecord.Text, '^\s*\|')) {
                            continue
                        }
                        if ([regex]::IsMatch($lineRecord.Text, '^\s*\|[\s\-:|]+\|?\s*$')) {
                            continue
                        }
                        $cells = $lineRecord.Text.Split('|')
                        if ($cells.Count -lt 3) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('invalid Files to Change row at line {0}' -f $lineRecord.LineNumber)
                            continue
                        }
                        $tablePath = ConvertFrom-MarkdownCell -Text $cells[1]
                        $tableOp = ConvertFrom-MarkdownCell -Text $cells[2]
                        if ([string]::Equals($tablePath, 'File', [System.StringComparison]::OrdinalIgnoreCase) -and
                            [string]::Equals($tableOp, 'operation', [System.StringComparison]::OrdinalIgnoreCase)) {
                            continue
                        }
                        if ([string]::IsNullOrWhiteSpace($tablePath)) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('missing Files to Change path at line {0}' -f $lineRecord.LineNumber)
                            continue
                        }
                        if ($tableOp -cnotmatch '^(?:create|modify|delete)$') {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('invalid Files to Change operation for {0}' -f $tablePath)
                            continue
                        }
                        $filesTableRows.Add([pscustomobject]@{
                            Path = $tablePath
                            Op = $tableOp
                            LineNumber = $lineRecord.LineNumber
                            Identity = $null
                        })
                    }

                    foreach ($tableRow in $filesTableRows) {
                        if (Test-AbsolutePathToken -Path $tableRow.Path) {
                            $tableRow.Identity = ConvertTo-AbsoluteManifestIdentity -Path $tableRow.Path
                        }
                        elseif (-not (Test-ManifestRelativePath -Path $tableRow.Path)) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('noncanonical Files to Change path {0}' -f $tableRow.Path)
                        }
                        else {
                            $candidateIdentities = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                            foreach ($repoRoot in $repoRoots.Values) {
                                $candidateIdentity = ConvertTo-ManifestIdentity -Root $repoRoot -RelativePath $tableRow.Path
                                if ($allOwnedIdentities.Contains($candidateIdentity)) {
                                    [void]$candidateIdentities.Add($candidateIdentity)
                                }
                            }
                            if ($candidateIdentities.Count -ne 1) {
                                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('relative Files to Change path {0} is orphaned or ambiguous' -f $tableRow.Path)
                            }
                            else {
                                foreach ($candidateIdentity in $candidateIdentities) {
                                    $tableRow.Identity = $candidateIdentity
                                }
                            }
                        }

                        if ($null -ne $tableRow.Identity -and
                            -not $coderOwnedIdentities.Contains($tableRow.Identity) -and
                            -not $hostOwnedIdentities.Contains($tableRow.Identity)) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('Files to Change path {0} is not owned by a coder or host/owner task' -f $tableRow.Path)
                        }
                    }

                    foreach ($manifestFileRecord in $manifestFileRecords) {
                        $matchingRows = @($filesTableRows | Where-Object { $null -ne $_.Identity -and [string]::Equals($_.Identity, $manifestFileRecord.Identity, [System.StringComparison]::OrdinalIgnoreCase) })
                        if ($matchingRows.Count -eq 0) {
                            Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('manifest path {0} is missing from Files to Change' -f $manifestFileRecord.Path)
                            continue
                        }
                        $expectedOp = $manifestFileRecord.Op
                        if ($null -ne $manifestFileRecord.Chain) {
                            $chain = $chains[$manifestFileRecord.Chain]
                            if ($chain.Valid -and $chain.SharedOps.ContainsKey($manifestFileRecord.ChainIdentity)) {
                                $expectedOp = $chain.SharedOps[$manifestFileRecord.ChainIdentity]
                            }
                        }
                        foreach ($matchingRow in $matchingRows) {
                            if (-not [string]::Equals($matchingRow.Op, $expectedOp, [System.StringComparison]::Ordinal)) {
                                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('operation mismatch for manifest path {0}' -f $manifestFileRecord.Path)
                            }
                        }
                    }

                    foreach ($manifestTask in $manifestTasks) {
                        foreach ($dependency in $manifestTask.DependsOn) {
                            if (-not $coderIds.Contains($dependency)) {
                                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('task {0} has unknown coder dependency {1}' -f $manifestTask.Id, $dependency)
                            }
                        }
                    }

                    $remainingTasks = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($manifestTask in $manifestTasks) { [void]$remainingTasks.Add($manifestTask.Id) }
                    $removedTask = $true
                    while ($removedTask -and $remainingTasks.Count -gt 0) {
                        $removedTask = $false
                        $remainingSnapshot = @($remainingTasks | ForEach-Object { $_ })
                        foreach ($remainingId in $remainingSnapshot) {
                            if (-not $manifestTaskById.ContainsKey($remainingId)) {
                                [void]$remainingTasks.Remove($remainingId)
                                $removedTask = $true
                                continue
                            }
                            $hasRemainingDependency = $false
                            foreach ($dependency in $manifestTaskById[$remainingId].DependsOn) {
                                if ($remainingTasks.Contains($dependency)) {
                                    $hasRemainingDependency = $true
                                    break
                                }
                            }
                            if (-not $hasRemainingDependency) {
                                [void]$remainingTasks.Remove($remainingId)
                                $removedTask = $true
                            }
                        }
                    }
                    if ($remainingTasks.Count -gt 0) {
                        Add-Finding -Check 'EXEC-MANIFEST' -Evidence 'task dependencies contain a cycle'
                    }

                    # Contract valid chains only, dropping only edges internal to those chains.
                    $nodeById = @{}
                    $contractedDependencies = @{}
                    foreach ($task in $manifestTasks) {
                        $node = $task.Id
                        if ($null -ne $task.Chain -and $chains[$task.Chain].Valid) { $node = 'chain:' + $task.Chain }
                        $nodeById[$task.Id] = $node
                        if (-not $contractedDependencies.ContainsKey($node)) {
                            $contractedDependencies[$node] = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                        }
                    }
                    foreach ($task in $manifestTasks) {
                        $node = $nodeById[$task.Id]
                        foreach ($dependency in $task.DependsOn) {
                            if (-not $manifestTaskById.ContainsKey($dependency)) { continue }
                            $dependencyNode = $nodeById[$dependency]
                            if ($node -eq $dependencyNode -and $node.StartsWith('chain:')) { continue }
                            [void]$contractedDependencies[$node].Add($dependencyNode)
                        }
                    }
                    foreach ($chainName in $chains.Keys) {
                        if (-not $chains[$chainName].Valid) { continue }
                        $start = 'chain:' + $chainName
                        $pending = New-Object 'System.Collections.Generic.Stack[string]'
                        foreach ($dependency in $contractedDependencies[$start]) { $pending.Push($dependency) }
                        $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
                        while ($pending.Count -gt 0) {
                            $node = $pending.Pop()
                            if ($node -eq $start) {
                                Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('chain {0} has dependency interleaving after contraction' -f $chainName)
                                break
                            }
                            if (-not $visited.Add($node)) { continue }
                            foreach ($dependency in $contractedDependencies[$node]) { $pending.Push($dependency) }
                        }
                    }
                }
            }
        }
    }
    catch {
        Add-Finding -Check 'EXEC-MANIFEST' -Evidence ('invalid manifest data: {0}' -f $_.Exception.Message)
    }
}

# (6) ACCEPTANCE-CHECK: only exact tagged fences in Acceptance Criteria opt in.
foreach ($check in $acceptanceFences) {
    foreach ($reason in Get-AcceptanceGrammarRefusals -Text ($check.Lines -join "`n")) {
        Add-Finding -Check 'ACCEPTANCE-CHECK' -Evidence ('line {0}: {1}' -f $check.LineNumber, $reason)
    }
    if ($check.LeadingLine -match '^- \[[ xX]\] Task\b') {
        if ($check.LeadingLine -cnotmatch '^- \[[ xX]\] Task (\d+[a-z]?) -') {
            Add-Finding -Check 'ACCEPTANCE-CHECK' -Evidence ('line {0}: compound or malformed task label' -f $check.LineNumber)
        }
        elseif (-not $acceptanceManifestIds.Contains($Matches[1])) {
            Add-Finding -Check 'ACCEPTANCE-CHECK' -Evidence ('line {0}: unknown manifest task ID {1} (HOST tasks cannot bind)' -f $check.LineNumber, $Matches[1])
        }
    }
}

foreach ($finding in $findings) {
    Write-Output $finding
}

if ($findings.Count -gt 0) {
    exit 1
}

exit 0
