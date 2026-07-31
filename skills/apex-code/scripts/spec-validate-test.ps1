[CmdletBinding()]
param(
    [string]$CorpusManifestPath = 'fixtures/spec-corpus/expected.tsv'
)

$ErrorActionPreference = 'Stop'

$validator = Join-Path $PSScriptRoot 'apex-spec-validate.ps1'
$sweep = Join-Path $PSScriptRoot 'spec-contract-sweep.ps1'
if (-not [System.IO.Path]::IsPathRooted($CorpusManifestPath)) {
    $CorpusManifestPath = Join-Path $PSScriptRoot $CorpusManifestPath
}
$fixtureRoot = Join-Path $env:TEMP ('apex-spec-validate-test-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object System.Text.UTF8Encoding($false)
$failures = 0
$assertions = 0
$tripleBacktick = (([string][char]96) * 3) -join ''
$tripleTilde = '~' * 3
$quadrupleTilde = '~' * 4

function Write-Fixture {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $path = Join-Path $fixtureRoot ($Name + '.md')
    [System.IO.File]::WriteAllText($path, $Content, $utf8)
    return $path
}

function Invoke-Validator {
    param([Parameter(Mandatory = $true)][string]$SpecPath)

    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validator -SpecPath $SpecPath 2>&1 |
        ForEach-Object { $_.ToString() })
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

function Assert-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][int]$ExpectedExit,
        [string]$ExpectedFailure
    )

    $script:assertions++
    $result = Invoke-Validator -SpecPath (Write-Fixture -Name $Name -Content $Content)
    $exitMatches = $result.ExitCode -eq $ExpectedExit
    $failureMatches = $true
    if (-not [string]::IsNullOrEmpty($ExpectedFailure)) {
        $failureMatches = @($result.Output | Where-Object {
            $_ -match ('^' + [regex]::Escape($ExpectedFailure) + ':')
        }).Count -gt 0
    }

    if ($exitMatches -and $failureMatches) {
        Write-Host ('  PASS  {0}' -f $Name) -ForegroundColor Green
        return
    }

    $script:failures++
    Write-Host ('  FAIL  {0} (expected exit {1}, got {2})' -f $Name, $ExpectedExit, $result.ExitCode) -ForegroundColor Red
    if (-not $failureMatches) {
        Write-Host ('        missing output line beginning "{0}:"' -f $ExpectedFailure) -ForegroundColor Red
    }
    foreach ($line in $result.Output) {
        Write-Host ('        {0}' -f $line)
    }
}

function Get-CheckNameSet {
    param([string[]]$Output)

    return @(
        $Output |
            ForEach-Object {
                $match = [regex]::Match($_, '^FAIL (?<Check>[A-Z][A-Z0-9-]*):')
                if ($match.Success) {
                    $match.Groups['Check'].Value
                }
            } |
            Sort-Object -Unique
    )
}

function Assert-CorpusCase {
    param(
        [Parameter(Mandatory = $true)][string]$FixturePath,
        [Parameter(Mandatory = $true)][int]$ExpectedExit,
        [string[]]$ExpectedChecks = @()
    )

    $script:assertions++
    $result = Invoke-Validator -SpecPath $FixturePath
    $actualChecks = @(Get-CheckNameSet -Output $result.Output)
    $expectedCheckSet = @($ExpectedChecks | Sort-Object -Unique)
    $exitMatches = $result.ExitCode -eq $ExpectedExit
    $checksMatch = [string]::Equals(
        ($actualChecks -join ','),
        ($expectedCheckSet -join ','),
        [System.StringComparison]::Ordinal
    )

    if ($exitMatches -and $checksMatch) {
        Write-Host ('  PASS  corpus {0}' -f $FixturePath) -ForegroundColor Green
        return
    }

    $script:failures++
    Write-Host ('  FAIL  corpus {0}' -f $FixturePath) -ForegroundColor Red
    Write-Host (
        '        expected exit {0}, checks [{1}]; got exit {2}, checks [{3}]' -f
            $ExpectedExit,
            ($expectedCheckSet -join ', '),
            $result.ExitCode,
            ($actualChecks -join ', ')
    ) -ForegroundColor Red
}

function Invoke-Sweep {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$Exclude = @()
    )

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $sweep,
        '-Root', $Root
    )
    if ($Exclude.Count -gt 0) {
        $arguments += '-Exclude'
        $arguments += $Exclude
    }

    $output = @(& powershell.exe @arguments 2>&1 | ForEach-Object { $_.ToString() })
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

function Assert-SuiteCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [string[]]$Details = @()
    )

    $script:assertions++
    if ($Passed) {
        Write-Host ('  PASS  {0}' -f $Name) -ForegroundColor Green
        return
    }

    $script:failures++
    Write-Host ('  FAIL  {0}' -f $Name) -ForegroundColor Red
    foreach ($detail in $Details) {
        Write-Host ('        {0}' -f $detail) -ForegroundColor Red
    }
}

$good = @'
# Minimal validation fixture

## Intent
Validate a minimal complete specification.

## Assumptions
The validator is available.

## Prerequisites
Windows PowerShell is available.

## Files to Change
| File | Change |
|---|---|
| `src/good.ps1` | Add the implementation. |

## Tasks
- **Task 1** - files: `src/good.ps1` - Add the implementation.

## Wave plan
Run Task 1.

## Permissions
May modify `src/good.ps1`.

## Specialist Context
No specialist context is required.

## Documentation
No documentation changes are required.

## Acceptance Criteria
- [ ] Task 1: `src/good.ps1` exists.

## Progress
Not started.
'@

$noNamedFiles = @'
# No-file validation fixture

## Intent
Validate structural handling when no artifact is named.

## Assumptions
The validator is available.

## Prerequisites
Windows PowerShell is available.

## Files to Change
__FILES_TABLE__

## Tasks
- **Task 1** - Perform the task.

## Wave plan
Run Task 1.

## Permissions
The described work is allowed.

## Specialist Context
No specialist context is required.

## Documentation
No documentation changes are required.

## Acceptance Criteria
- [ ] Task 1: the behavior is verified.

## Progress
Not started.
'@

$good = $good.Replace("`r`n", "`n")
$noNamedFiles = $noNamedFiles.Replace("`r`n", "`n")

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

    Assert-Case 'good-minimal' $good 0

    $missingByPath = $good.Replace('Task 1: `src/good.ps1` exists.', 'Task 1: src/missing.ps1 exists.')
    Assert-Case 'missing-file-by-path' $missingByPath 1 'FAIL FILES-COMPLETENESS'

    $missingInline = $good.Replace('Task 1: `src/good.ps1` exists.', 'Task 1: the output at `src/missing.ps1`, must exist.')
    Assert-Case 'missing-file-backticked-comma' $missingInline 1 'FAIL FILES-COMPLETENESS'

    $marker = $good.Replace('No specialist context is required.', 'TBD before implementation.')
    Assert-Case 'unresolved-marker' $marker 1 'FAIL NO-UNRESOLVED-MARKERS'

    # Regression coverage closes the fail-open where lowercase unresolved markers passed validation.
    $lowercaseMarker = $good.Replace('No specialist context is required.', 'todo before implementation.')
    Assert-Case 'lowercase-unresolved-marker' $lowercaseMarker 1 'FAIL NO-UNRESOLVED-MARKERS'

    $uncoveredTask = $good.Replace('- **Task 1** - files: `src/good.ps1` - Add the implementation.', "- **Task 1** - files: ``src/good.ps1`` - Add the implementation.`r`n- **Task 2** - Review the implementation.")
    Assert-Case 'task-without-criterion' $uncoveredTask 1 'FAIL TASK-CRITERIA-COVERAGE'

    $missingHeading = $good.Replace("## Assumptions`nThe validator is available.`n`n", '')
    Assert-Case 'missing-required-heading' $missingHeading 1 'FAIL STRUCTURE'

    $unterminatedFence = $good + "`n${tripleBacktick}powershell`nWrite-Output 'never closed'`n"
    Assert-Case 'unterminated-code-fence' $unterminatedFence 1 'FAIL STRUCTURE'

    $emptyFiles = $good.Replace("| File | Change |`n|---|---|`n| ``src/good.ps1`` | Add the implementation. |`n", '')
    Assert-Case 'empty-files-to-change' $emptyFiles 1 'FAIL STRUCTURE'

    $emptyTasks = $good.Replace('- **Task 1** - files: `src/good.ps1` - Add the implementation.', 'Task details are intentionally absent.')
    Assert-Case 'empty-tasks' $emptyTasks 1 'FAIL STRUCTURE'

    $emptyCriteria = $good.Replace('- [ ] Task 1: `src/good.ps1` exists.', 'Criterion details are intentionally absent.')
    Assert-Case 'empty-acceptance-criteria' $emptyCriteria 1 'FAIL STRUCTURE'

    $emptyPermissions = $good.Replace("## Permissions`nMay modify ``src/good.ps1``.`n`n", "## Permissions`n`n")
    Assert-Case 'empty-permissions' $emptyPermissions 1 'FAIL STRUCTURE'

    $fencedPermissions = $tripleBacktick + "text`n## Permissions`nMay modify ``src/good.ps1``.`n" + $tripleBacktick + "`n`n"
    $fencedHeading = $good.Replace("## Permissions`nMay modify ``src/good.ps1``.`n`n", $fencedPermissions)
    Assert-Case 'heading-only-inside-fence' $fencedHeading 1 'FAIL STRUCTURE'

    # Regression coverage closes the fail-open where tilde-fenced structure was counted as real structure.
    $tildeFencedOnly = $tripleTilde + "`n" + $good + "`n" + $tripleTilde + "`n"
    Assert-Case 'tilde-fenced-only-structure' $tildeFencedOnly 1 'FAIL STRUCTURE'

    $shortTildeDoesNotClose = $quadrupleTilde + "`n" + $tripleTilde + "`n" + $good + "`n" + $quadrupleTilde + "`n"
    Assert-Case 'shorter-tilde-does-not-close' $shortTildeDoesNotClose 1 'FAIL STRUCTURE'

    $headerOnly = $noNamedFiles.Replace('__FILES_TABLE__', "| File | Change |`n|---|---|")
    Assert-Case 'files-disguise-header-separator-only' $headerOnly 1 'FAIL STRUCTURE'

    $barePipe = $noNamedFiles.Replace('__FILES_TABLE__', "| File | Change |`n|---|---|`n|")
    Assert-Case 'files-disguise-bare-pipe-row' $barePipe 1 'FAIL STRUCTURE'

    $naRow = $noNamedFiles.Replace('__FILES_TABLE__', "| File | Change |`n|---|---|`n| N/A |")
    Assert-Case 'files-disguise-na-row' $naRow 1 'FAIL STRUCTURE'

    $pseudoFenceText = '    ' + $tripleBacktick + "text`nTBD remains visible because the fences are indented four spaces.`n    " + $tripleBacktick
    $pseudoFence = $good.Replace('No specialist context is required.', $pseudoFenceText)
    Assert-Case 'indented-pseudo-fence-marker' $pseudoFence 1 'FAIL NO-UNRESOLVED-MARKERS'

    $manifestFullPath = [System.IO.Path]::GetFullPath($CorpusManifestPath)
    $corpusRoot = Split-Path -Parent $manifestFullPath
    $manifestRows = @(
        [System.IO.File]::ReadAllLines($manifestFullPath, $utf8) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object {
                $fields = $_ -split "`t", -1
                if ($fields.Count -ne 3) {
                    throw ('Invalid corpus manifest row: {0}' -f $_)
                }

                $expectedChecks = @()
                if ($fields[2] -ne '-') {
                    $expectedChecks = @($fields[2] -split ',' | ForEach-Object { $_.Trim() })
                }

                [pscustomobject]@{
                    RelativePath = $fields[0]
                    ExpectedExit = [int]$fields[1]
                    ExpectedChecks = $expectedChecks
                }
            }
    )

    foreach ($manifestRow in $manifestRows) {
        $fixturePath = Join-Path $corpusRoot $manifestRow.RelativePath
        Assert-CorpusCase `
            -FixturePath $fixturePath `
            -ExpectedExit $manifestRow.ExpectedExit `
            -ExpectedChecks $manifestRow.ExpectedChecks
    }

    $hashesBefore = @{}
    foreach ($corpusFile in [System.IO.Directory]::GetFiles($corpusRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
        $hashesBefore[$corpusFile] = (Get-FileHash -LiteralPath $corpusFile -Algorithm SHA256).Hash
    }

    $expectedPassCount = @($manifestRows | Where-Object { $_.ExpectedExit -eq 0 }).Count
    $expectedFailCount = @($manifestRows | Where-Object { $_.ExpectedExit -eq 1 }).Count
    $sweepResult = Invoke-Sweep -Root $corpusRoot
    $reportLines = @($sweepResult.Output | Where-Object { $_ -match '^(?:PASS|FAIL|ERROR|SKIP) ' })
    $reportPathsMatch = $reportLines.Count -eq $manifestRows.Count
    foreach ($manifestRow in $manifestRows) {
        $normalizedFixturePath = $manifestRow.RelativePath.Replace('\', '/')
        $escapedFixturePath = [regex]::Escape($normalizedFixturePath)
        $matchingReportLines = @($reportLines | Where-Object {
            $_ -match ('^(?:PASS {0}$|(?:FAIL|ERROR) {0}:)' -f $escapedFixturePath)
        })
        if ($matchingReportLines.Count -ne 1) {
            $reportPathsMatch = $false
            break
        }
    }
    $expectedSummary = 'SWEEP contract 1.0.0 - {0} specs, {1} pass, {2} fail, 0 error' -f `
        $manifestRows.Count, $expectedPassCount, $expectedFailCount
    $hashesAfter = @{}
    foreach ($corpusFile in [System.IO.Directory]::GetFiles($corpusRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
        $hashesAfter[$corpusFile] = (Get-FileHash -LiteralPath $corpusFile -Algorithm SHA256).Hash
    }
    $hashesUnchanged = ($hashesBefore.Count -eq $hashesAfter.Count)
    foreach ($corpusFile in $hashesBefore.Keys) {
        if ((-not $hashesAfter.ContainsKey($corpusFile)) -or ($hashesAfter[$corpusFile] -ne $hashesBefore[$corpusFile])) {
            $hashesUnchanged = $false
            break
        }
    }
    $sweepPassed = (
        ($sweepResult.ExitCode -eq 0) -and
        $reportPathsMatch -and
        ($sweepResult.Output -contains $expectedSummary) -and
        $hashesUnchanged
    )
    Assert-SuiteCase -Name 'corpus-sweep' -Passed $sweepPassed -Details @(
        ('expected exit 0, got {0}' -f $sweepResult.ExitCode),
        ('expected {0} report lines, got {1}' -f $manifestRows.Count, $reportLines.Count),
        ('one report line per manifest fixture: {0}' -f $reportPathsMatch),
        ('expected summary "{0}"' -f $expectedSummary),
        ('corpus hashes unchanged: {0}' -f $hashesUnchanged),
        ($sweepResult.Output -join [Environment]::NewLine)
    )

    $excludedRow = $manifestRows[0]
    $excludedFixtureName = Split-Path -Leaf $excludedRow.RelativePath
    $excludedPassCount = $expectedPassCount
    $excludedFailCount = $expectedFailCount
    if ($excludedRow.ExpectedExit -eq 0) {
        $excludedPassCount--
    }
    else {
        $excludedFailCount--
    }
    $excludedSweepResult = Invoke-Sweep -Root $corpusRoot -Exclude $excludedFixtureName
    $normalizedExcludedPath = $excludedRow.RelativePath.Replace('\', '/')
    $expectedSkip = 'SKIP {0} (excluded)' -f $normalizedExcludedPath
    $expectedExcludedSummary = 'SWEEP contract 1.0.0 - {0} specs, {1} pass, {2} fail, 0 error' -f `
        $manifestRows.Count, $excludedPassCount, $excludedFailCount
    $excludedSweepPassed = (
        ($excludedSweepResult.ExitCode -eq 0) -and
        ($excludedSweepResult.Output -contains $expectedSkip) -and
        ($excludedSweepResult.Output -contains $expectedExcludedSummary) -and
        (@($excludedSweepResult.Output | Where-Object {
            $_ -match '^(?:PASS|FAIL|ERROR) ' -and $_ -like ('*' + $normalizedExcludedPath + '*')
        }).Count -eq 0)
    )
    Assert-SuiteCase -Name 'corpus-sweep-exclude' -Passed $excludedSweepPassed -Details @(
        ('expected exit 0, got {0}' -f $excludedSweepResult.ExitCode),
        ('expected skip "{0}"' -f $expectedSkip),
        ('expected summary "{0}"' -f $expectedExcludedSummary),
        ($excludedSweepResult.Output -join [Environment]::NewLine)
    )

    $missingRoot = Join-Path $fixtureRoot 'missing-corpus-root'
    $missingRootResult = Invoke-Sweep -Root $missingRoot
    Assert-SuiteCase `
        -Name 'corpus-sweep-missing-root' `
        -Passed ($missingRootResult.ExitCode -eq 2) `
        -Details @('expected exit 2, got {0}' -f $missingRootResult.ExitCode)
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host ('ALL {0} CASES PASS' -f $assertions) -ForegroundColor Green
    exit 0
}

Write-Host ('{0} CASE(S) FAILED' -f $failures) -ForegroundColor Red
exit 1
