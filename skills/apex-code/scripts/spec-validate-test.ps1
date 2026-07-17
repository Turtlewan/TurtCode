$ErrorActionPreference = 'Stop'

$validator = Join-Path $PSScriptRoot 'apex-spec-validate.ps1'
$fixtureRoot = Join-Path $env:TEMP ('apex-spec-validate-test-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object System.Text.UTF8Encoding($false)
$failures = 0
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
}
finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'ALL 19 CASES PASS' -ForegroundColor Green
    exit 0
}

Write-Host ('{0} CASE(S) FAILED' -f $failures) -ForegroundColor Red
exit 1
