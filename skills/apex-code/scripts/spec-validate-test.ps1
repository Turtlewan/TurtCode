[CmdletBinding()]
param(
    [string]$CorpusManifestPath = 'fixtures/spec-corpus/expected.tsv',
    [switch]$ChainsOnly
)

$ErrorActionPreference = 'Stop'

$validator = Join-Path $PSScriptRoot 'apex-spec-validate.ps1'
$sweep = Join-Path $PSScriptRoot 'spec-contract-sweep.ps1'
if (-not [System.IO.Path]::IsPathRooted($CorpusManifestPath)) {
    $CorpusManifestPath = Join-Path $PSScriptRoot $CorpusManifestPath
}
$fixtureRoot = Join-Path (Join-Path $PSScriptRoot '../../../.codex-scratch') ('apex-spec-validate-test-' + [guid]::NewGuid().ToString('N'))
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

function New-ManifestFixture {
    param(
        [string]$FilesRows,
        [string]$TaskRows,
        [string]$ManifestBody,
        [string]$AcceptanceRows,
        [string]$Frontmatter = '',
        [object[]]$ManifestTasks,
        [hashtable]$FirstOps = @{},
        [hashtable]$Repos = @{ alpha = 'C:/work/alpha' }
    )

    if ($PSBoundParameters.ContainsKey('ManifestTasks')) {
        $manifestJson = @{ version = 1; repos = $Repos; tasks = @($ManifestTasks) } | ConvertTo-Json -Depth 20
        $ManifestBody = "~~~json apex-manifest`n$manifestJson`n~~~"
        $TaskRows = (@($ManifestTasks | ForEach-Object {
            $paths = @($_.files | ForEach-Object { '`' + $_.path + '`' }) -join ', '
            '- **Task {0}** - files: {1} - Update the implementation.' -f $_.id, $paths
        }) -join "`n")
        $AcceptanceRows = (@($ManifestTasks | ForEach-Object { '- [ ] Task {0}: behavior is verified.' -f $_.id }) -join "`n")
        if (-not $PSBoundParameters.ContainsKey('FilesRows')) {
            $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            $rows = @(foreach ($task in $ManifestTasks) {
                foreach ($file in $task.files) {
                    if (-not $seen.Add($file.path)) { continue }
                    $op = $file.op
                    if ($FirstOps.ContainsKey($file.path)) { $op = $FirstOps[$file.path] }
                    '| `{0}` | {1} | Update implementation. |' -f $file.path, $op
                }
            })
            $FilesRows = $rows -join "`n"
        }
    }

    $frontmatterBlock = ''
    if (-not [string]::IsNullOrWhiteSpace($Frontmatter)) {
        $frontmatterBlock = "---`n$Frontmatter`n---`n`n"
    }

    return (@"
${frontmatterBlock}# Execution manifest validation fixture

## Intent
Validate one execution manifest contract case.

## Assumptions
The validator is available.

## Prerequisites
Windows PowerShell is available.

## Files to Change
| File | Operation | Notes |
|---|---|---|
$FilesRows

## Execution manifest
$ManifestBody

## Tasks
$TaskRows

## Wave plan
Run tasks according to manifest dependencies.

## Permissions
May modify the listed files.

## Specialist Context
No specialist context is required.

## Documentation
No documentation changes are required.

## Acceptance Criteria
$AcceptanceRows

## Progress
Not started.
"@).Replace("`r`n", "`n")
}

function New-ChainTask {
    param(
        [string]$Id,
        [object]$Chain,
        [string[]]$Depends = @(),
        [string]$Path = 'src/shared.txt',
        [string]$Op = 'modify',
        [object[]]$Files,
        [string]$Repo = 'alpha'
    )

    if (-not $PSBoundParameters.ContainsKey('Files')) { $Files = @(@{ path = $Path; op = $Op }) }
    $task = @{ id = $Id; repo = $Repo; files = @($Files); depends_on = @($Depends) }
    if ($PSBoundParameters.ContainsKey('Chain')) { $task.chain = $Chain }
    return $task
}

function Assert-ChainFindings {
    param([string]$Name, [string]$Content, [string[]]$Expected = @())

    $result = Invoke-Validator -SpecPath (Write-Fixture -Name $Name -Content $Content)
    # Pin the entire legacy output too, excluding only the explicitly bumped banner.
    $actual = @($result.Output | Where-Object { $_ -cnotmatch '^\[spec-validate\] contract ' })
    $expectedExit = 0
    if ($Expected.Count -gt 0) { $expectedExit = 1 }
    Assert-SuiteCase -Name $Name -Passed (
        $result.ExitCode -eq $expectedExit -and
        [string]::Equals(($actual -join "`n"), ($Expected -join "`n"), [System.StringComparison]::Ordinal)
    ) -Details @('Expected:', ($Expected -join "`n"), 'Actual:', ($result.Output -join "`n"))
}

function Invoke-ChainRegressions {
    $shape = 'FAIL EXEC-MANIFEST: chain edit must form one linear dependency path (one head, one predecessor per later member, no branching, all members visited)'
    $one = New-ChainTask -Id 1 -Chain edit
    $two = New-ChainTask -Id 2 -Chain edit -Depends 1
    Assert-ChainFindings 'chain-optional-field-absent' (New-ManifestFixture -ManifestTasks @((New-ChainTask -Id 1)))
    Assert-ChainFindings 'chain-singleton' (New-ManifestFixture -ManifestTasks @($one))
    Assert-ChainFindings 'chain-shared-modify-modify' (New-ManifestFixture -ManifestTasks @($one, $two))
    $create = New-ChainTask -Id 1 -Chain edit -Op create
    Assert-ChainFindings 'chain-shared-create-modify' (New-ManifestFixture -ManifestTasks @($create, $two))
    Assert-ChainFindings 'chain-reversed-manifest-order' (New-ManifestFixture -ManifestTasks @($two, $create) -FirstOps @{ 'src/shared.txt' = 'create' })
    $laterFirst = @(
        (New-ChainTask -Id 1 -Chain edit -Path 'src/unique.txt'),
        (New-ChainTask -Id 2 -Chain edit -Depends 1 -Op create),
        (New-ChainTask -Id 3 -Chain edit -Depends 2)
    )
    Assert-ChainFindings 'chain-first-listing-by-later-member' (New-ManifestFixture -ManifestTasks $laterFirst)
    Assert-ChainFindings 'chain-independent-chains' (New-ManifestFixture -ManifestTasks @(
        $one, $two,
        (New-ChainTask -Id 3 -Chain other -Path 'src/other.txt' -Op create),
        (New-ChainTask -Id 4 -Chain other -Depends 3 -Path 'src/other.txt')
    ))
    Assert-ChainFindings 'chain-outside-dependencies' (New-ManifestFixture -ManifestTasks @(
        (New-ChainTask -Id 1 -Path 'src/outside.txt'),
        (New-ChainTask -Id 2 -Chain edit -Depends 1),
        (New-ChainTask -Id 3 -Chain edit -Depends 1,2)
    ))
    Assert-ChainFindings 'chain-unique-delete' (New-ManifestFixture -ManifestTasks @(
        (New-ChainTask -Id 1 -Chain edit -Op delete -Path 'src/removed.txt'), $two
    ))
    Assert-ChainFindings 'chain-outside-owner-same-op' (New-ManifestFixture -ManifestTasks @($one, $two, (New-ChainTask -Id 3)))
    Assert-ChainFindings 'chain-different-chains-exact-sharing' (New-ManifestFixture -ManifestTasks @($one, (New-ChainTask -Id 2 -Chain other)))
    Assert-ChainFindings 'chain-component-boundary' (New-ManifestFixture -ManifestTasks @(
        (New-ChainTask -Id 1 -Chain edit -Path 'src/a'), (New-ChainTask -Id 2 -Path 'src/ab/file.txt')
    ))
    Assert-ChainFindings 'chain-distinct-repo-roots' (New-ManifestFixture -ManifestTasks @(
        $create, (New-ChainTask -Id 2 -Chain edit -Depends 1 -Repo beta -Op delete)
    ) -Repos @{ alpha = 'C:/work/alpha'; beta = 'C:/work/beta' } -FilesRows (
        '| `C:/work/alpha/src/shared.txt` | create | First root. |' + "`n" +
        '| `C:/work/beta/src/shared.txt` | delete | Second root. |'
    ))
    Assert-ChainFindings 'chain-alias-repo-roots-share-identity' (New-ManifestFixture -ManifestTasks @(
        $create, (New-ChainTask -Id 2 -Chain edit -Depends 1 -Repo beta)
    ) -Repos @{ alpha = 'C:/work/alpha'; beta = 'C:/work/alpha' })

    $invalidNames = @($null, '', ' ', 7, $false, @('edit'), @{ name = 'edit' }, 'Edit', '-edit', 'edit_name', "edit`n")
    for ($i = 0; $i -lt $invalidNames.Count; $i++) {
        Assert-ChainFindings ('chain-invalid-name-' + $i) (New-ManifestFixture -ManifestTasks @(
            (New-ChainTask -Id 1 -Chain $invalidNames[$i])
        )) @('FAIL EXEC-MANIFEST: task 1 has invalid chain')
    }

    $shapes = @(
        @{ Name = 'two-heads-no-interleaving'; Tasks = @($one, (New-ChainTask -Id 2 -Chain edit)) },
        @{ Name = 'branch'; Tasks = @($one, $two, (New-ChainTask -Id 3 -Chain edit -Depends 1)) },
        @{ Name = 'join'; Tasks = @($one, (New-ChainTask -Id 2 -Chain edit), (New-ChainTask -Id 3 -Chain edit -Depends 1,2)) },
        @{ Name = 'extra-earlier-dependency'; Tasks = @($one, $two, (New-ChainTask -Id 3 -Chain edit -Depends 1,2)) }
    )
    foreach ($case in $shapes) {
        # Exact expected output also proves malformed chains produce no interleaving finding.
        Assert-ChainFindings ('chain-shape-' + $case.Name) (New-ManifestFixture -ManifestTasks $case.Tasks) @($shape)
    }
    Assert-ChainFindings 'chain-shape-cyclic-group' (New-ManifestFixture -ManifestTasks @(
        (New-ChainTask -Id 1 -Chain edit -Depends 2), $two
    )) @($shape, 'FAIL EXEC-MANIFEST: task dependencies contain a cycle')
    Assert-ChainFindings 'chain-shape-disconnected-cycle' (New-ManifestFixture -ManifestTasks @(
        $one, (New-ChainTask -Id 2 -Chain edit -Depends 3), (New-ChainTask -Id 3 -Chain edit -Depends 2)
    )) @($shape, 'FAIL EXEC-MANIFEST: task dependencies contain a cycle')
    Assert-ChainFindings 'chain-shape-invalid-retains-operation-comparison' (New-ManifestFixture -ManifestTasks @(
        $create, (New-ChainTask -Id 2 -Chain edit)
    )) @($shape, 'FAIL EXEC-MANIFEST: operation mismatch for manifest path src/shared.txt')
    foreach ($pair in @(@{ A = 'src./shared.txt'; B = 'src/shared.txt' }, @{ A = 'src/Shared.txt'; B = 'src/shared.txt' })) {
        Assert-ChainFindings ('chain-spelling-' + $pair.A.Replace('/', '-')) (New-ManifestFixture -ManifestTasks @(
            (New-ChainTask -Id 2 -Chain edit -Depends 1 -Path $pair.B),
            (New-ChainTask -Id 1 -Chain edit -Path $pair.A)
        )) @('FAIL EXEC-MANIFEST: chain edit lists one file with different spellings: {0}, {1}' -f $pair.A, $pair.B)
    }
    Assert-ChainFindings 'chain-shared-first-delete' (New-ManifestFixture -ManifestTasks @(
        (New-ChainTask -Id 1 -Chain edit -Op delete), $two
    )) @('FAIL EXEC-MANIFEST: chain edit shared path src/shared.txt requires first create|modify and later modify (task 1)')
    foreach ($op in @('create', 'delete')) {
        Assert-ChainFindings ('chain-shared-later-' + $op) (New-ManifestFixture -ManifestTasks @(
            $one, (New-ChainTask -Id 2 -Chain edit -Depends 1 -Op $op)
        )) @('FAIL EXEC-MANIFEST: chain edit shared path src/shared.txt requires first create|modify and later modify (task 2)')
    }
    Assert-ChainFindings 'chain-wrong-files-first-op' (New-ManifestFixture -ManifestTasks @($create, $two) -FirstOps @{ 'src/shared.txt' = 'modify' }) @(
        'FAIL EXEC-MANIFEST: operation mismatch for manifest path src/shared.txt',
        'FAIL EXEC-MANIFEST: operation mismatch for manifest path src/shared.txt'
    )
    foreach ($sameChain in @($true, $false)) {
        $other = New-ChainTask -Id 2 -Path 'src/dir/file.txt'
        if ($sameChain) { $other = New-ChainTask -Id 2 -Chain edit -Depends 1 -Path 'src/dir/file.txt' }
        Assert-ChainFindings ('chain-ancestor-overlap-' + $sameChain) (New-ManifestFixture -ManifestTasks @(
            (New-ChainTask -Id 1 -Chain edit -Path 'src/Dir.'), $other
        )) @('FAIL EXEC-MANIFEST: chain edit has ancestor/descendant path overlap: src/Dir., src/dir/file.txt')
    }
    # Original DAG: 1 -> 2 -> 3, plus 1 -> 3. Contracting chain members 1 and 3 creates edit <-> 2.
    Assert-ChainFindings 'chain-contracted-cycle-original-dag-valid' (New-ManifestFixture -ManifestTasks @(
        $one, (New-ChainTask -Id 2 -Depends 1 -Path 'src/outside.txt'),
        (New-ChainTask -Id 3 -Chain edit -Depends 1,2)
    )) @('FAIL EXEC-MANIFEST: chain edit has dependency interleaving after contraction')

    Assert-ChainFindings 'legacy-unchained-shared-same-op' (New-ManifestFixture -ManifestTasks @((New-ChainTask -Id 1), (New-ChainTask -Id 2)))
    Assert-ChainFindings 'legacy-unchained-shared-different-op' (New-ManifestFixture -ManifestTasks @(
        (New-ChainTask -Id 1 -Op create), (New-ChainTask -Id 2)
    )) @('FAIL EXEC-MANIFEST: operation mismatch for manifest path src/shared.txt')
    Assert-ChainFindings 'legacy-unchained-ancestor-overlap' (New-ManifestFixture -ManifestTasks @(
        (New-ChainTask -Id 1 -Path 'src/dir'), (New-ChainTask -Id 2 -Path 'src/dir/file.txt')
    ))
    Assert-ChainFindings 'legacy-finding-order-outside-owner-mismatch' (New-ManifestFixture -ManifestTasks @(
        $create, $two, (New-ChainTask -Id 3 -Depends 99)
    )) @('FAIL EXEC-MANIFEST: operation mismatch for manifest path src/shared.txt', 'FAIL EXEC-MANIFEST: task 3 has unknown coder dependency 99')
    Assert-ChainFindings 'legacy-unknown-dependency' (New-ManifestFixture -ManifestTasks @(
        (New-ChainTask -Id 1 -Depends 99)
    )) @('FAIL EXEC-MANIFEST: task 1 has unknown coder dependency 99')
    Assert-ChainFindings 'legacy-ordinary-cycle' (New-ManifestFixture -ManifestTasks @(
        (New-ChainTask -Id 1 -Depends 2), (New-ChainTask -Id 2 -Depends 1)
    )) @('FAIL EXEC-MANIFEST: task dependencies contain a cycle')
    Assert-ChainFindings 'legacy-self-cycle' (New-ManifestFixture -ManifestTasks @(
        (New-ChainTask -Id 1 -Depends 1)
    )) @('FAIL EXEC-MANIFEST: task dependencies contain a cycle')
    $base = New-ManifestFixture -ManifestTasks @((New-ChainTask -Id 1))
    Assert-ChainFindings 'legacy-files-completeness' ($base.Replace('Task 1: behavior is verified.', 'Task 1: `src/missing.txt` exists.')) @(
        'FAIL FILES-COMPLETENESS: src/missing.txt not in Files to Change',
        'FAIL FILES-COMPLETENESS: src/missing.txt not in Files to Change'
    )
    Assert-ChainFindings 'legacy-coder-manifest-id-equality' ($base.Replace('**Task 1**', '**Task 2**').Replace('Task 1:', 'Task 2:')) @(
        'FAIL EXEC-MANIFEST: coder task 2 is missing from manifest',
        'FAIL EXEC-MANIFEST: manifest task 1 is not a coder task'
    )
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

$singleRepoManifest = @'
~~~json apex-manifest
{
  "version": 1,
  "repos": { "alpha": "C:/work/alpha" },
  "tasks": [
    { "id": "1", "repo": "alpha", "files": [{ "path": "src/one.ps1", "op": "modify" }], "depends_on": [] }
  ]
}
~~~
'@.Replace("`r`n", "`n")

$singleRepoFiles = '| `src/one.ps1` | modify | Update the implementation. |'
$singleRepoTasks = '- **Task 1** - files: `src/one.ps1` - Update the implementation.'
$singleRepoCriteria = '- [ ] Task 1: `src/one.ps1` is updated.'
$validSingleRepo = New-ManifestFixture `
    -FilesRows $singleRepoFiles `
    -TaskRows $singleRepoTasks `
    -ManifestBody $singleRepoManifest `
    -AcceptanceRows $singleRepoCriteria

$twoTaskManifest = @'
~~~json apex-manifest
{
  "version": 1,
  "repos": { "alpha": "C:/work/alpha" },
  "tasks": [
    { "id": "1", "repo": "alpha", "files": [{ "path": "src/one.ps1", "op": "modify" }], "depends_on": [], "effort": "xhigh" },
    { "id": "2", "repo": "alpha", "files": [{ "path": "src/two.ps1", "op": "create" }], "depends_on": ["1"] }
  ]
}
~~~
'@.Replace("`r`n", "`n")

$twoTaskFiles = @'
| `src/one.ps1` | modify | Update the first implementation. |
| `src/two.ps1` | create | Add the second implementation. |
'@.Replace("`r`n", "`n").TrimEnd()
$twoTaskRows = @'
- **Task 1** - files: `src/one.ps1` - Update the first implementation.
- **Task 2** - files: `src/two.ps1` - Add the second implementation.
'@.Replace("`r`n", "`n").TrimEnd()
$twoTaskCriteria = @'
- [ ] Task 1: `src/one.ps1` is updated.
- [ ] Task 2: `src/two.ps1` is created.
'@.Replace("`r`n", "`n").TrimEnd()
$validEffortAndDefault = New-ManifestFixture `
    -FilesRows $twoTaskFiles `
    -TaskRows $twoTaskRows `
    -ManifestBody $twoTaskManifest `
    -AcceptanceRows $twoTaskCriteria `
    -Frontmatter 'coder_effort: high'

$versionOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validator -Version 2>&1 |
    ForEach-Object { $_.ToString() })
$versionExitCode = $LASTEXITCODE
$versionMatch = [regex]::Match(($versionOutput -join "`n"), '(?m)^apex-spec-validate contract (?<Version>[^\s]+)$')
if ($versionExitCode -ne 0 -or -not $versionMatch.Success) {
    throw ('Unable to derive validator contract version: {0}' -f ($versionOutput -join [Environment]::NewLine))
}
$contractVersion = $versionMatch.Groups['Version'].Value

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null

    Invoke-ChainRegressions
    if (-not $ChainsOnly) {
    Assert-Case 'good-minimal' $good 0

    $noManifestBaseline = [string]::Copy($good)
    Assert-Case 'no-manifest-baseline' $noManifestBaseline 0

    Assert-Case 'manifest-valid-single-repo' $validSingleRepo 0

    # The shared corpus is also consumed by the Engine planner's tests.
    $grammarPath = Join-Path $PSScriptRoot '../references/accept-grammar-vectors.json'
    $grammarVectors = Get-Content -LiteralPath $grammarPath -Raw | ConvertFrom-Json
    $vectorIndex = 0
    foreach ($vector in $grammarVectors) {
        if ($vector.expected -notin @('accept', 'refuse')) { throw 'Invalid grammar corpus expectation' }
        $vectorIndex++
        $block = "${tripleBacktick}powershell apex-accept`n" + $vector.text + "`n${tripleBacktick}"
        $fixture = $validSingleRepo.Replace($singleRepoCriteria, $singleRepoCriteria + "`n- [ ] Shared grammar check.`n" + $block)
        $expectedExit = 0
        $expectedFailure = ''
        if ($vector.expected -eq 'refuse') { $expectedExit = 1; $expectedFailure = 'FAIL ACCEPTANCE-CHECK' }
        Assert-Case ('accept-grammar-{0}' -f $vectorIndex) $fixture $expectedExit $expectedFailure
    }
    $safeBlock = "${tripleBacktick}powershell apex-accept`nWrite-Output ok`n${tripleBacktick}"
    $badBlock = "${tripleBacktick}powershell apex-accept`nSet-Location 'C:/outside'`n${tripleBacktick}"
    $taskCriterion = '- [ ] Task 1 - check passes.'
    Assert-Case 'accept-task-binding' ($validSingleRepo.Replace($singleRepoCriteria, $taskCriterion + "`n" + $safeBlock)) 0
    Assert-Case 'accept-compound-label' ($validSingleRepo.Replace($singleRepoCriteria, '- [ ] Task 1 and Task 2 - check passes.' + "`n" + $safeBlock)) 1 'FAIL ACCEPTANCE-CHECK'
    Assert-Case 'accept-unknown-label' ($validSingleRepo.Replace($singleRepoCriteria, '- [ ] Task 9 - check passes.' + "`n" + $safeBlock)) 1 'FAIL ACCEPTANCE-CHECK'
    Assert-Case 'accept-spec-level' ($validSingleRepo.Replace($singleRepoCriteria, $singleRepoCriteria + "`n- [ ] All checks pass.`n" + $safeBlock)) 0
    Assert-Case 'accept-nonleading-label' ($validSingleRepo.Replace($singleRepoCriteria, $singleRepoCriteria + "`n- [ ] Review Task 1 results.`n" + $safeBlock)) 0
    Assert-Case 'accept-label-not-immediately-preceding' ($validSingleRepo.Replace($singleRepoCriteria, '- [ ] Task 1 and Task 1 - check passes.' + "`n`n" + $safeBlock)) 1 'FAIL ACCEPTANCE-CHECK'
    Assert-Case 'accept-task-binding-after-blank' ($validSingleRepo.Replace($singleRepoCriteria, $taskCriterion + "`n`n" + $safeBlock)) 0
    Assert-Case 'accept-unknown-label-after-continuation' ($validSingleRepo.Replace($singleRepoCriteria, '- [ ] Task 9 - check passes.' + "`n  Continued criterion.`n" + $safeBlock)) 1 'FAIL ACCEPTANCE-CHECK'
    Assert-Case 'accept-spec-level-after-blank' ($validSingleRepo.Replace($singleRepoCriteria, $singleRepoCriteria + "`n- [ ] All checks pass.`n`n" + $safeBlock)) 0
    Assert-Case 'accept-numbered-criterion-replaces-task-label' ($validSingleRepo.Replace($singleRepoCriteria, '- [ ] Task 1 and Task 1 - HOST review.' + "`n1. Spec-level check.`n  Continued criterion.`n`n" + $safeBlock)) 0
    Assert-Case 'accept-label-survives-untagged-fence' ($validSingleRepo.Replace($singleRepoCriteria, '- [ ] Task 9 - check passes.' + "`n" + $safeBlock.Replace('powershell apex-accept', 'text') + "`n`n" + $safeBlock)) 1 'FAIL ACCEPTANCE-CHECK'
    Assert-Case 'accept-lowercase-malformed-label' ($validSingleRepo.Replace($singleRepoCriteria, $singleRepoCriteria + "`n- [ ] task 1 - check passes.`n`n" + $safeBlock)) 1 'FAIL ACCEPTANCE-CHECK'
    foreach ($tag in @('powershell', 'PowerShell apex-accept', 'powershell Apex-Accept', 'powershell apex-accept extra', "powershell`t ap ex-accept")) {
        $untaggedBlock = $badBlock.Replace('powershell apex-accept', $tag)
        Assert-Case ('accept-untagged-{0}' -f [array]::IndexOf(@('powershell', 'PowerShell apex-accept', 'powershell Apex-Accept', 'powershell apex-accept extra', "powershell`t ap ex-accept"), $tag)) ($validSingleRepo.Replace($singleRepoCriteria, $singleRepoCriteria + "`n- [ ] Untagged check.`n" + $untaggedBlock)) 0
    }
    Assert-Case 'accept-other-section' ($validSingleRepo.Replace('No specialist context is required.', $badBlock)) 0
    Assert-Case 'accept-tilde-tagged' ($validSingleRepo.Replace($singleRepoCriteria, $singleRepoCriteria + "`n" + $badBlock.Replace($tripleBacktick, $tripleTilde))) 1 'FAIL ACCEPTANCE-CHECK'

    $twoRepoManifest = @'
~~~json apex-manifest
{
  "version": 1,
  "repos": { "alpha": "C:/work/alpha", "beta": "D:/work/beta" },
  "tasks": [
    { "id": "1", "repo": "alpha", "files": [{ "path": "src/one.ps1", "op": "modify" }], "depends_on": [] },
    { "id": "2", "repo": "beta", "files": [{ "path": "src/two.ps1", "op": "create" }], "depends_on": ["1"] }
  ]
}
~~~
'@.Replace("`r`n", "`n")
    $twoRepoFiles = @'
| `C:/work/alpha/src/one.ps1` | modify | Update the first repository. |
| `D:/work/beta/src/two.ps1` | create | Add to the second repository. |
'@.Replace("`r`n", "`n").TrimEnd()
    $twoRepoTasks = @'
- **Task 1** - files: `C:/work/alpha/src/one.ps1` - Update the first repository.
- **Task 2** - files: `D:/work/beta/src/two.ps1` - Add to the second repository.
'@.Replace("`r`n", "`n").TrimEnd()
    $validTwoRepo = New-ManifestFixture -FilesRows $twoRepoFiles -TaskRows $twoRepoTasks -ManifestBody $twoRepoManifest -AcceptanceRows $twoTaskCriteria
    Assert-Case 'manifest-valid-two-repo-absolute-files' $validTwoRepo 0

    $hostFiles = $singleRepoFiles + "`n| ``host/status.md`` | modify | HOST-owned bookkeeping. |"
    $hostTasks = $singleRepoTasks + "`n- **Task 2 (HOST)** - files: ``host/status.md`` - Record bookkeeping."
    $hostCriteria = $singleRepoCriteria + "`n- [ ] Task 2: ``host/status.md`` is updated."
    $validHostOnly = New-ManifestFixture -FilesRows $hostFiles -TaskRows $hostTasks -ManifestBody $singleRepoManifest -AcceptanceRows $hostCriteria
    Assert-Case 'manifest-valid-host-only-file' $validHostOnly 0
    Assert-Case 'accept-host-label' ($validHostOnly.Replace($hostCriteria, $hostCriteria + "`n- [ ] Task 2 - HOST check.`n" + $safeBlock)) 1 'FAIL ACCEPTANCE-CHECK'

    $ownerRunTasks = $singleRepoTasks + "`n- **Task 2 OWNER-run** - files: ``owner/status.md`` - Record bookkeeping."
    $ownerFiles = $singleRepoFiles + "`n| ``owner/status.md`` | modify | OWNER-owned bookkeeping. |"
    $ownerCriteria = $singleRepoCriteria + "`n- [ ] Task 2: ``owner/status.md`` is updated."
    $validOwnerRun = New-ManifestFixture -FilesRows $ownerFiles -TaskRows $ownerRunTasks -ManifestBody $singleRepoManifest -AcceptanceRows $ownerCriteria
    Assert-Case 'manifest-valid-owner-only-owner-run' $validOwnerRun 0

    $criticalOwnerTasks = $ownerRunTasks.Replace('Task 2 OWNER-run', 'Task 2 (critical, OWNER-run)')
    $validCriticalOwner = New-ManifestFixture -FilesRows $ownerFiles -TaskRows $criticalOwnerTasks -ManifestBody $singleRepoManifest -AcceptanceRows $ownerCriteria
    Assert-Case 'manifest-valid-owner-only-critical-owner-run' $validCriticalOwner 0

    $suffixManifest = $singleRepoManifest.Replace('"id": "1"', '"id": "1a"')
    $suffixTasks = $singleRepoTasks.Replace('Task 1', 'Task 1A')
    $suffixCriteria = $singleRepoCriteria.Replace('Task 1', 'Task 1A')
    $validSuffixId = New-ManifestFixture -FilesRows $singleRepoFiles -TaskRows $suffixTasks -ManifestBody $suffixManifest -AcceptanceRows $suffixCriteria
    Assert-Case 'manifest-valid-case-insensitive-letter-suffix-id' $validSuffixId 0

    Assert-Case 'manifest-valid-effort-plus-default-effort' $validEffortAndDefault 0

    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
    $specTemplatePath = Join-Path $repoRoot 'skills\apex-orchestrate\templates\spec-template.md'
    if (-not (Test-Path -LiteralPath $specTemplatePath -PathType Leaf)) {
        throw ('Spec template is missing: {0}' -f $specTemplatePath)
    }

    $specTemplate = [System.IO.File]::ReadAllText($specTemplatePath, $utf8).Replace("`r`n", "`n")
    foreach ($requiredText in @('~/.claude/skills/apex-code/references/spec-contract.md', 'powershell apex-accept', 'integration-root cwd', 'immediately preceding', 'Compound task labels', 'unknown task IDs', 'HOST tasks', 'spec level', 'author-written, Critic-reviewed, owner-promoted', 'unsandboxed', 'same trust as the AGENTS.md verify fence', 'guards accidents', 'confines execution', 'Tree/index movement or residue parks the run without restoration', 'Throw on failure', '$LASTEXITCODE')) {
        Assert-SuiteCase -Name ('template-accept-guidance-' + $requiredText) -Passed ($specTemplate.Contains($requiredText)) -Details @('Missing executable-check guidance: ' + $requiredText)
    }
    $filesSection = [regex]::Match(
        $specTemplate,
        '(?ms)^## Files to Change[ \t]*\n(?<Body>.*?)(?=^## |\z)'
    )
    if (-not $filesSection.Success) {
        throw ('Could not extract the ## Files to Change section from {0}' -f $specTemplatePath)
    }

    $templateFileRows = @(
        [regex]::Matches($filesSection.Groups['Body'].Value, '(?m)^\|.*\|[ \t]*$') |
            ForEach-Object { $_.Value }
    )
    if ($templateFileRows.Count -lt 3) {
        throw ('Could not extract example Files to Change table rows from {0}' -f $specTemplatePath)
    }
    $templateExampleFiles = ($templateFileRows | Select-Object -Skip 2) -join "`n"
    if ([string]::IsNullOrWhiteSpace($templateExampleFiles)) {
        throw ('Could not extract example Files to Change table rows from {0}' -f $specTemplatePath)
    }

    $manifestSection = [regex]::Match(
        $specTemplate,
        '(?ms)^## Execution manifest[ \t]*\n(?<Body>.*?)(?=^## |\z)'
    )
    $templateManifestBlocks = @()
    if ($manifestSection.Success) {
        $templateManifestBlocks = @(
            [regex]::Matches(
                $manifestSection.Groups['Body'].Value,
                '(?ms)^```json apex-manifest[ \t]*\n.*?^```[ \t]*$'
            ) | ForEach-Object { $_.Value }
        )
    }
    if ($templateManifestBlocks.Count -ne 1) {
        throw ('Expected one example apex-manifest block under ## Execution manifest in {0}; found {1}' -f $specTemplatePath, $templateManifestBlocks.Count)
    }
    $templateExampleManifest = $templateManifestBlocks[0] + "`n"

    $tasksSection = [regex]::Match(
        $specTemplate,
        '(?ms)^## Tasks[ \t]*\n(?<Body>.*?)(?=^## |\z)'
    )
    $templateTaskLines = @()
    if ($tasksSection.Success) {
        $templateTaskLines = @(
            [regex]::Matches(
                $tasksSection.Groups['Body'].Value,
                '(?m)^-[ \t]+\[ \][ \t]+\*\*Task [0-9]+\*\*.*$'
            ) | ForEach-Object { $_.Value }
        )
    }
    if ($templateTaskLines.Count -eq 0) {
        throw ('Could not extract example **Task N** lines under ## Tasks from {0}' -f $specTemplatePath)
    }
    $templateExampleTasks = $templateTaskLines -join "`n"

    $templateExampleValues = [ordered]@{
        '{absolute/forward-slash/repo/root}' = $repoRoot.Replace('\', '/')
        '{path/to/a.ts, path/to/b.ts}'       = 'src/a.ts, src/b.ts'
        '{path/to/a.ts}'                     = 'src/a.ts'
        '{path/to/b.ts}'                     = 'src/b.ts'
        '{path/to/c.ts}'                     = 'src/c.ts'
        '{path/to/d.ts}'                     = 'src/d.ts'
        '{what changes}'                     = 'Apply the template example change.'
        '{description}'                      = 'Implement the template example'
        '{observable outcome}'               = 'the template example is complete.'
    }
    foreach ($placeholder in $templateExampleValues.Keys) {
        $replacement = $templateExampleValues[$placeholder]
        $templateExampleFiles = $templateExampleFiles.Replace($placeholder, $replacement)
        $templateExampleManifest = $templateExampleManifest.Replace($placeholder, $replacement)
        $templateExampleTasks = $templateExampleTasks.Replace($placeholder, $replacement)
    }
    $templateExampleCriteria = @'
- [ ] Task 1: `src/a.ts` and `src/b.ts` are ready.
- [ ] Task 2: `src/c.ts` is updated.
- [ ] Task 3: `src/d.ts` is removed.
'@.Replace("`r`n", "`n").TrimEnd()
    $validTemplateExample = New-ManifestFixture -FilesRows $templateExampleFiles -TaskRows $templateExampleTasks -ManifestBody $templateExampleManifest -AcceptanceRows $templateExampleCriteria
    Assert-Case 'manifest-valid-template-instantiated-example' $validTemplateExample 0

    $zeroBlocks = $validSingleRepo.Replace($singleRepoManifest, 'No manifest fence is present.')
    Assert-Case 'manifest-zero-blocks' $zeroBlocks 1 'FAIL EXEC-MANIFEST'

    $multipleBlocks = $validSingleRepo.Replace($singleRepoManifest, ($singleRepoManifest.TrimEnd() + "`n`n" + $singleRepoManifest.TrimEnd()))
    Assert-Case 'manifest-multiple-blocks' $multipleBlocks 1 'FAIL EXEC-MANIFEST'

    $wrongInfoString = $validSingleRepo.Replace('~~~json apex-manifest', '~~~json')
    Assert-Case 'manifest-wrong-info-string-inside-section' $wrongInfoString 1 'FAIL EXEC-MANIFEST'

    $strayOutsideSection = $zeroBlocks + "`n## Notes`n" + $singleRepoManifest
    Assert-Case 'manifest-stray-fence-outside-section' $strayOutsideSection 1 'FAIL EXEC-MANIFEST'

    $malformedJson = $validSingleRepo.Replace('"version": 1,', '"version": 1,,')
    Assert-Case 'manifest-malformed-json' $malformedJson 1 'FAIL EXEC-MANIFEST'

    $rootWrongType = $validSingleRepo.Replace(($singleRepoManifest.TrimEnd()), "~~~json apex-manifest`n[]`n~~~")
    Assert-Case 'manifest-root-wrong-type' $rootWrongType 1 'FAIL EXEC-MANIFEST'

    $missingVersion = $validSingleRepo.Replace("  `"version`": 1,`n", '')
    Assert-Case 'manifest-missing-version' $missingVersion 1 'FAIL EXEC-MANIFEST'

    $nonintegerVersion = $validSingleRepo.Replace('"version": 1', '"version": 1.5')
    Assert-Case 'manifest-noninteger-version' $nonintegerVersion 1 'FAIL EXEC-MANIFEST'

    $wrongVersion = $validSingleRepo.Replace('"version": 1', '"version": 2')
    Assert-Case 'manifest-wrong-version' $wrongVersion 1 'FAIL EXEC-MANIFEST'

    $missingRepos = $validSingleRepo.Replace("  `"repos`": { `"alpha`": `"C:/work/alpha`" },`n", '')
    Assert-Case 'manifest-missing-repos' $missingRepos 1 'FAIL EXEC-MANIFEST'

    $wrongTypeRepos = $validSingleRepo.Replace('"repos": { "alpha": "C:/work/alpha" }', '"repos": []')
    Assert-Case 'manifest-wrong-type-repos' $wrongTypeRepos 1 'FAIL EXEC-MANIFEST'

    $missingTasks = $validSingleRepo.Replace('"tasks": [', '"not_tasks": [')
    Assert-Case 'manifest-missing-tasks' $missingTasks 1 'FAIL EXEC-MANIFEST'

    $wrongTypeTasks = $validSingleRepo.Replace("`"tasks`": [`n    { `"id`": `"1`", `"repo`": `"alpha`", `"files`": [{ `"path`": `"src/one.ps1`", `"op`": `"modify`" }], `"depends_on`": [] }`n  ]", '"tasks": {}')
    Assert-Case 'manifest-wrong-type-tasks' $wrongTypeTasks 1 'FAIL EXEC-MANIFEST'

    $wrongTypeTaskEntry = $validSingleRepo.Replace('{ "id": "1", "repo": "alpha", "files": [{ "path": "src/one.ps1", "op": "modify" }], "depends_on": [] }', '"not-an-object"')
    Assert-Case 'manifest-wrong-type-task-entry' $wrongTypeTaskEntry 1 'FAIL EXEC-MANIFEST'

    $malformedId = $validSingleRepo.Replace('"id": "1"', '"id": "task-1"')
    Assert-Case 'manifest-malformed-id' $malformedId 1 'FAIL EXEC-MANIFEST'

    $duplicateManifestId = $validEffortAndDefault.Replace('"id": "2"', '"id": "1"')
    Assert-Case 'manifest-duplicate-id' $duplicateManifestId 1 'FAIL EXEC-MANIFEST'

    $duplicateCoderRows = $singleRepoTasks + "`n" + $singleRepoTasks
    $duplicateCoderCriteria = $singleRepoCriteria
    $duplicateCoderId = New-ManifestFixture -FilesRows $singleRepoFiles -TaskRows $duplicateCoderRows -ManifestBody $singleRepoManifest -AcceptanceRows $duplicateCoderCriteria
    Assert-Case 'manifest-duplicate-coder-task-id' $duplicateCoderId 1 'FAIL EXEC-MANIFEST'

    $missingCoderEntry = $validEffortAndDefault.Replace("    { `"id`": `"2`", `"repo`": `"alpha`", `"files`": [{ `"path`": `"src/two.ps1`", `"op`": `"create`" }], `"depends_on`": [`"1`"] }`n", '')
    Assert-Case 'manifest-missing-coder-entry' $missingCoderEntry 1 'FAIL EXEC-MANIFEST'

    $extraCoderEntry = $validSingleRepo.Replace('"id": "1"', '"id": "2"')
    Assert-Case 'manifest-extra-coder-entry' $extraCoderEntry 1 'FAIL EXEC-MANIFEST'

    $lowercaseHostTasks = $hostTasks.Replace('(HOST)', '(host)')
    $lowercaseHost = New-ManifestFixture -FilesRows $hostFiles -TaskRows $lowercaseHostTasks -ManifestBody $singleRepoManifest -AcceptanceRows $hostCriteria
    Assert-Case 'manifest-unmarked-lowercase-host-title' $lowercaseHost 1 'FAIL EXEC-MANIFEST'

    $homeownerTasks = $ownerRunTasks.Replace('OWNER-run', 'HOMEOWNER')
    $falseHomeowner = New-ManifestFixture -FilesRows $ownerFiles -TaskRows $homeownerTasks -ManifestBody $singleRepoManifest -AcceptanceRows $ownerCriteria
    Assert-Case 'manifest-false-owner-marker-homeowner' $falseHomeowner 1 'FAIL EXEC-MANIFEST'

    $hostileTasks = $hostTasks.Replace('(HOST)', '(HOSTILE)')
    $falseHostile = New-ManifestFixture -FilesRows $hostFiles -TaskRows $hostileTasks -ManifestBody $singleRepoManifest -AcceptanceRows $hostCriteria
    Assert-Case 'manifest-false-host-marker-hostile' $falseHostile 1 'FAIL EXEC-MANIFEST'

    $missingRepoField = $validSingleRepo.Replace('"id": "1", "repo": "alpha",', '"id": "1",')
    Assert-Case 'manifest-missing-task-repo' $missingRepoField 1 'FAIL EXEC-MANIFEST'

    $wrongTypeRepoField = $validSingleRepo.Replace('"repo": "alpha"', '"repo": 1')
    Assert-Case 'manifest-wrong-type-task-repo' $wrongTypeRepoField 1 'FAIL EXEC-MANIFEST'

    $emptyTaskFiles = $validSingleRepo.Replace('"files": [{ "path": "src/one.ps1", "op": "modify" }]', '"files": []')
    Assert-Case 'manifest-empty-task-files' $emptyTaskFiles 1 'FAIL EXEC-MANIFEST'

    $wrongTypeTaskFiles = $validSingleRepo.Replace('"files": [{ "path": "src/one.ps1", "op": "modify" }]', '"files": {}')
    Assert-Case 'manifest-wrong-type-task-files' $wrongTypeTaskFiles 1 'FAIL EXEC-MANIFEST'

    $wrongTypeFileEntry = $validSingleRepo.Replace('{ "path": "src/one.ps1", "op": "modify" }', '"src/one.ps1"')
    Assert-Case 'manifest-wrong-type-file-entry' $wrongTypeFileEntry 1 'FAIL EXEC-MANIFEST'

    $missingTaskPath = $validSingleRepo.Replace('"path": "src/one.ps1", ', '')
    Assert-Case 'manifest-missing-task-path-field' $missingTaskPath 1 'FAIL EXEC-MANIFEST'

    $missingTaskOp = $validSingleRepo.Replace(', "op": "modify"', '')
    Assert-Case 'manifest-missing-task-op-field' $missingTaskOp 1 'FAIL EXEC-MANIFEST'

    $wrongTypeDependsOn = $validSingleRepo.Replace('"depends_on": []', '"depends_on": {}')
    Assert-Case 'manifest-wrong-type-depends-on' $wrongTypeDependsOn 1 'FAIL EXEC-MANIFEST'

    $missingDependsOn = $validSingleRepo.Replace(', "depends_on": []', '')
    Assert-Case 'manifest-missing-depends-on' $missingDependsOn 1 'FAIL EXEC-MANIFEST'

    $unequalTaskRows = $singleRepoTasks.Replace('`src/one.ps1`', '`src/one.ps1`, `src/two.ps1`')
    $unequalTaskFiles = New-ManifestFixture -FilesRows $twoTaskFiles -TaskRows $unequalTaskRows -ManifestBody $singleRepoManifest -AcceptanceRows $singleRepoCriteria
    Assert-Case 'manifest-unequal-task-files' $unequalTaskFiles 1 'FAIL EXEC-MANIFEST'

    $missingFilesToChangePath = $validSingleRepo.Replace($singleRepoFiles, '| | modify | Missing path. |')
    Assert-Case 'manifest-missing-files-to-change-path' $missingFilesToChangePath 1 'FAIL EXEC-MANIFEST'

    $operationMismatch = $validSingleRepo.Replace('| `src/one.ps1` | modify |', '| `src/one.ps1` | create |')
    Assert-Case 'manifest-operation-mismatch' $operationMismatch 1 'FAIL EXEC-MANIFEST'

    $invalidOperation = $validSingleRepo.Replace('| `src/one.ps1` | modify |', '| `src/one.ps1` | update |')
    Assert-Case 'manifest-invalid-files-to-change-operation' $invalidOperation 1 'FAIL EXEC-MANIFEST'

    $invalidManifestOperation = $validSingleRepo.Replace('"op": "modify"', '"op": "update"')
    Assert-Case 'manifest-invalid-task-operation' $invalidManifestOperation 1 'FAIL EXEC-MANIFEST'

    $orphanFiles = $singleRepoFiles + "`n| ``src/orphan.ps1`` | create | Not owned by any task. |"
    $orphanRelativePath = New-ManifestFixture -FilesRows $orphanFiles -TaskRows $singleRepoTasks -ManifestBody $singleRepoManifest -AcceptanceRows $singleRepoCriteria
    Assert-Case 'manifest-orphan-relative-files-to-change-path' $orphanRelativePath 1 'FAIL EXEC-MANIFEST'

    $ambiguousManifest = @'
~~~json apex-manifest
{
  "version": 1,
  "repos": { "alpha": "C:/work/alpha", "beta": "D:/work/beta" },
  "tasks": [
    { "id": "1", "repo": "alpha", "files": [{ "path": "src/shared.ps1", "op": "modify" }], "depends_on": [] },
    { "id": "2", "repo": "beta", "files": [{ "path": "src/shared.ps1", "op": "modify" }], "depends_on": [] }
  ]
}
~~~
'@.Replace("`r`n", "`n")
    $ambiguousTasks = @'
- **Task 1** - files: `C:/work/alpha/src/shared.ps1` - Update alpha.
- **Task 2** - files: `D:/work/beta/src/shared.ps1` - Update beta.
'@.Replace("`r`n", "`n").TrimEnd()
    $ambiguousFiles = '| `src/shared.ps1` | modify | Ambiguous between repositories. |'
    $ambiguousRelativePath = New-ManifestFixture -FilesRows $ambiguousFiles -TaskRows $ambiguousTasks -ManifestBody $ambiguousManifest -AcceptanceRows $twoTaskCriteria
    Assert-Case 'manifest-ambiguous-relative-files-to-change-path' $ambiguousRelativePath 1 'FAIL EXEC-MANIFEST'

    $unknownRepo = $validSingleRepo.Replace('"repo": "alpha"', '"repo": "missing"')
    Assert-Case 'manifest-unknown-repo' $unknownRepo 1 'FAIL EXEC-MANIFEST'

    $unknownDependency = $validSingleRepo.Replace('"depends_on": []', '"depends_on": ["9"]')
    Assert-Case 'manifest-unknown-dependency' $unknownDependency 1 'FAIL EXEC-MANIFEST'

    $selfCycle = $validSingleRepo.Replace('"depends_on": []', '"depends_on": ["1"]')
    Assert-Case 'manifest-self-cycle' $selfCycle 1 'FAIL EXEC-MANIFEST'

    $longerCycle = $validEffortAndDefault.Replace('"depends_on": [], "effort": "xhigh"', '"depends_on": ["2"], "effort": "xhigh"')
    Assert-Case 'manifest-longer-cycle' $longerCycle 1 'FAIL EXEC-MANIFEST'

    $invalidEffort = $validSingleRepo.Replace('"depends_on": []', '"depends_on": [], "effort": "extreme"')
    Assert-Case 'manifest-invalid-effort' $invalidEffort 1 'FAIL EXEC-MANIFEST'

    $invalidDefaultEffort = New-ManifestFixture -FilesRows $singleRepoFiles -TaskRows $singleRepoTasks -ManifestBody $singleRepoManifest -AcceptanceRows $singleRepoCriteria -Frontmatter 'coder_effort: extreme'
    Assert-Case 'manifest-invalid-default-effort' $invalidDefaultEffort 1 'FAIL EXEC-MANIFEST'

    $noncanonicalRepoRoot = $validSingleRepo.Replace('C:/work/alpha', 'C:/work/../alpha')
    Assert-Case 'manifest-noncanonical-repo-root' $noncanonicalRepoRoot 1 'FAIL EXEC-MANIFEST'

    $noncanonicalTaskPath = $validSingleRepo.Replace('"path": "src/one.ps1"', '"path": "src/../one.ps1"')
    Assert-Case 'manifest-noncanonical-task-path' $noncanonicalTaskPath 1 'FAIL EXEC-MANIFEST'

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
    $expectedSummary = 'SWEEP contract {0} - {1} specs, {2} pass, {3} fail, 0 error' -f `
        $contractVersion, $manifestRows.Count, $expectedPassCount, $expectedFailCount
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
    $expectedExcludedSummary = 'SWEEP contract {0} - {1} specs, {2} pass, {3} fail, 0 error' -f `
        $contractVersion, $manifestRows.Count, $excludedPassCount, $excludedFailCount
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
