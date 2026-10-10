# End-to-end coverage for codex-dispatch.ps1's draft-spec authoring path.
# Every fixture repository and harness artifact lives under one fresh temp root,
# while APEX_STATE_DIR is a sibling of (and therefore outside) all fixture repositories.

$ErrorActionPreference = 'Stop'

$dispatch = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
$fakeCodex = Join-Path $PSScriptRoot 'dispatch-test-fakecodex.ps1'
foreach ($required in @($dispatch, $fakeCodex)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required test dependency not found: $required"
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("apex-dispatch-author-test-" + [guid]::NewGuid().ToString('N'))
$repoRoot = Join-Path $testRoot 'repos'
$stateRoot = Join-Path $testRoot 'state'
$scratchRoot = Join-Path $stateRoot 'scratch'
$ledgerPath = Join-Path (Join-Path $stateRoot 'progress') 'codex-run-ledger.jsonl'

$oldEnvironment = @{}
foreach ($name in @(
        'APEX_STATE_DIR',
        'FAKE_CODEX_REPO',
        'FAKE_CODEX_ARGV_FILE',
        'FAKE_CODEX_AUTHOR_PATH',
        'FAKE_CODEX_AUTHOR_NO_WRITE',
        'FAKE_CODEX_AUTHOR_AS_DIR',
        'FAKE_CODEX_AUTHOR_AS_SYMLINK',
        'FAKE_CODEX_AUTHOR_FAIL_EXIT',
        'FAKE_CODEX_EXTRA_WRITE',
        'FAKE_CODEX_NO_REPORT',
        'FAKE_CODEX_INSCOPE_ONLY'
    )) {
    $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

$script:failureCount = 0
$script:assertionCount = 0
$script:skipCount = 0

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )

    $parent = Split-Path $Path -Parent
    if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Set-OptionalEnvironmentValue {
    param([Parameter(Mandatory)][string]$Name, [AllowNull()][string]$Value)

    if ($null -eq $Value) {
        Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
    }
    else {
        Set-Item -LiteralPath "Env:$Name" -Value $Value
    }
}

function Clear-FakeCodexEnvironment {
    foreach ($name in @(
            'FAKE_CODEX_ARGV_FILE',
            'FAKE_CODEX_AUTHOR_PATH',
            'FAKE_CODEX_AUTHOR_NO_WRITE',
            'FAKE_CODEX_AUTHOR_AS_DIR',
            'FAKE_CODEX_AUTHOR_AS_SYMLINK',
            'FAKE_CODEX_AUTHOR_FAIL_EXIT',
            'FAKE_CODEX_EXTRA_WRITE',
            'FAKE_CODEX_NO_REPORT',
            'FAKE_CODEX_INSCOPE_ONLY'
        )) {
        Set-OptionalEnvironmentValue -Name $name -Value $null
    }
}

function Invoke-FixtureGit {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string[]]$GitArguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $gitOutput = @(& git -C $Repo @GitArguments 2>&1)
        $gitExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($gitExitCode -ne 0) {
        throw "git -C $Repo $($GitArguments -join ' ') failed: $($gitOutput -join [Environment]::NewLine)"
    }
    return $gitOutput
}

function New-FixtureRepo {
    param([Parameter(Mandatory)][string]$Name)

    $repo = Join-Path $repoRoot $Name
    [System.IO.Directory]::CreateDirectory((Join-Path $repo 'src')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $repo 'docs\drafts')) | Out-Null
    Write-Utf8NoBom -Path (Join-Path $repo 'src\a.py') -Content "original`n"
    Write-Utf8NoBom -Path (Join-Path $repo 'docs\status.md') -Content "fixture state`n"
    Write-Utf8NoBom -Path (Join-Path $repo 'docs\drafts\keep.md') -Content "tracked draft placeholder`n"

    Invoke-FixtureGit -Repo $repo -GitArguments @('init', '-q') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('config', 'user.email', 'dispatch-author-test@example.invalid') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('config', 'user.name', 'dispatch-author-test') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('add', '-A') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('commit', '-q', '-m', 'fixture') | Out-Null
    return $repo
}

function Get-FixtureHead {
    param([Parameter(Mandatory)][string]$Repo)

    $head = @(Invoke-FixtureGit -Repo $Repo -GitArguments @('rev-parse', 'HEAD'))
    return ([string]$head[0]).Trim()
}

function Get-GitObjectId {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Path
    )

    $objectId = @(Invoke-FixtureGit -Repo $Repo -GitArguments @('hash-object', '--', $Path))
    return ([string]$objectId[0]).Trim()
}

function Invoke-WithFixtureLedgerLock {
    param([Parameter(Mandatory)][scriptblock]$Action)

    $fixtureLedgerMutex = [System.Threading.Mutex]::new($false, 'ApexCodexRunLedger')
    $acquired = $false
    try {
        try {
            $acquired = $fixtureLedgerMutex.WaitOne([TimeSpan]::FromSeconds(30))
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) { throw 'Timed out waiting for the fixture run-ledger lock.' }
        & $Action
    }
    finally {
        if ($acquired) { $fixtureLedgerMutex.ReleaseMutex() }
        $fixtureLedgerMutex.Dispose()
    }
}

function Get-TestLedgerLines {
    $lines = @(Invoke-WithFixtureLedgerLock {
        if (-not (Test-Path -LiteralPath $ledgerPath -PathType Leaf)) { return }
        [System.IO.File]::ReadAllLines($ledgerPath)
    })
    return [string[]]$lines
}

function Get-LedgerRowsForSpec {
    param([Parameter(Mandatory)][string]$Spec)

    $matches = @()
    foreach ($line in (Get-TestLedgerLines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $row = $line | ConvertFrom-Json
        if ([string]$row.spec -ceq $Spec) { $matches += $row }
    }
    return @($matches)
}

function Get-LedgerRowsForRun {
    param([Parameter(Mandatory)][string]$RunId)

    $matches = @()
    foreach ($line in (Get-TestLedgerLines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $row = $line | ConvertFrom-Json
        if ([string]$row.run_id -ceq $RunId) { $matches += $row }
    }
    return @($matches)
}

function Set-TestDispatchRowOrphaned {
    param([Parameter(Mandatory)][string]$RunId)

    Invoke-WithFixtureLedgerLock {
        $lines = [System.IO.File]::ReadAllLines($ledgerPath)
        for ($index = $lines.Count - 1; $index -ge 0; $index--) {
            if ([string]::IsNullOrWhiteSpace($lines[$index])) { continue }
            $row = $lines[$index] | ConvertFrom-Json
            if ([string]$row.run_id -cne $RunId -or [string]$row.row_kind -cne 'dispatch') {
                continue
            }
            $row.status = 'orphaned'
            $lines[$index] = $row | ConvertTo-Json -Compress -Depth 8
            [System.IO.File]::WriteAllLines(
                $ledgerPath,
                $lines,
                [System.Text.UTF8Encoding]::new($false)
            )
            return
        }
        throw "No dispatch ledger row found for run_id '$RunId'."
    }
}

function Assert-Case {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Detail
    )

    $script:assertionCount++
    if ($Condition) {
        Write-Host ("PASS  {0} -- {1}" -f $Label, $Detail) -ForegroundColor Green
    }
    else {
        $script:failureCount++
        Write-Host ("FAIL  {0} -- {1}" -f $Label, $Detail) -ForegroundColor Red
    }
}

function Write-SkippedCase {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Reason
    )

    $script:skipCount++
    Write-Host ("SKIP  {0} -- {1}" -f $Label, $Reason) -ForegroundColor Yellow
}

function Test-ArgvModel {
    param(
        [Parameter(Mandatory)][string]$ArgvPath,
        [Parameter(Mandatory)][string]$ExpectedModel
    )

    if (-not (Test-Path -LiteralPath $ArgvPath -PathType Leaf)) { return $false }
    $argv = @([System.IO.File]::ReadAllLines($ArgvPath))
    for ($index = 0; $index -lt ($argv.Count - 1); $index++) {
        if ($argv[$index] -ceq '-m') { return $argv[$index + 1] -ceq $ExpectedModel }
    }
    return $false
}

function ConvertTo-OutputText {
    param([object[]]$Captured)

    return (@($Captured | ForEach-Object {
        if ($_ -is [System.Management.Automation.InformationRecord]) {
            [string]$_.MessageData
        }
        else {
            [string]$_
        }
    }) -join [Environment]::NewLine)
}

function Invoke-MklinkCommand {
    param(
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$Target,
        [switch]$Junction
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Junction) {
            $commandOutput = @(& cmd.exe /c mklink /J "`"$Link`"" "`"$Target`"" 2>&1)
        }
        else {
            $commandOutput = @(& cmd.exe /c mklink "`"$Link`"" "`"$Target`"" 2>&1)
        }
        $commandExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $commandExit
        Output = @($commandOutput)
    }
}

function Invoke-DispatchCase {
    param(
        [Parameter(Mandatory)][string]$CaseName,
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$Repo,
        [string]$AuthorizedPath = "docs/drafts/$Spec.md",
        [hashtable]$ExtraParameters = @{},
        [hashtable]$FakeEnvironment = @{},
        [switch]$OmitPhase,
        [switch]$NonAuthor
    )

    $argvPath = Join-Path $testRoot "$CaseName.argv.txt"
    if (Test-Path -LiteralPath $argvPath) {
        Remove-Item -LiteralPath $argvPath -Force
    }

    Clear-FakeCodexEnvironment
    $env:FAKE_CODEX_REPO = $Repo
    $env:FAKE_CODEX_ARGV_FILE = $argvPath
    if (-not $NonAuthor) { $env:FAKE_CODEX_AUTHOR_PATH = $AuthorizedPath }
    foreach ($entry in $FakeEnvironment.GetEnumerator()) {
        Set-OptionalEnvironmentValue -Name $entry.Key -Value ([string]$entry.Value)
    }

    $baseSha = if ($ExtraParameters.ContainsKey('BaseSha')) {
        [string]$ExtraParameters['BaseSha']
    }
    else {
        Get-FixtureHead -Repo $Repo
    }
    $parameters = @{
        Spec = $Spec
        Task = $(if ($NonAuthor) { 'task-1' } else { 'author' })
        Phase = 'build'
        Worktree = $Repo
        BaseSha = $baseSha
        Prompt = "Dispatch author test case: $CaseName"
        Authorized = @($(if ($NonAuthor) { 'src/a.py' } else { $AuthorizedPath }))
        ScratchDirectory = $scratchRoot
        CodexExecutable = 'powershell.exe'
        CodexExecutableArgumentPrefix = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeCodex)
    }
    if ($OmitPhase) { $parameters.Remove('Phase') }
    if (-not $NonAuthor) { $parameters['AuthorSpec'] = $true }
    foreach ($entry in $ExtraParameters.GetEnumerator()) {
        $parameters[$entry.Key] = $entry.Value
    }

    Write-Host "`n===== CASE: $CaseName =====" -ForegroundColor Cyan
    $captured = @(& $dispatch @parameters *>&1)
    $exitCode = $LASTEXITCODE
    $outputText = ConvertTo-OutputText -Captured $captured
    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
        Write-Host $outputText.TrimEnd()
    }
    Write-Host ("----- {0}: exit {1} -----" -f $CaseName, $exitCode) -ForegroundColor DarkCyan

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $outputText
        Rows = @(Get-LedgerRowsForSpec -Spec $Spec)
        ArgvPath = $argvPath
    }
}

function Invoke-AdoptCase {
    param(
        [Parameter(Mandatory)][string]$CaseName,
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$RunId
    )

    Clear-FakeCodexEnvironment
    $env:FAKE_CODEX_REPO = $Repo

    Write-Host "`n===== CASE: $CaseName =====" -ForegroundColor Cyan
    $captured = @(& $dispatch -Adopt -RunId $RunId -Spec $Spec -Phase 'build' `
        -Task 'author' -Worktree $Repo -ScratchDirectory $scratchRoot *>&1)
    $exitCode = $LASTEXITCODE
    $outputText = ConvertTo-OutputText -Captured $captured
    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
        Write-Host $outputText.TrimEnd()
    }
    Write-Host ("----- {0}: exit {1} -----" -f $CaseName, $exitCode) -ForegroundColor DarkCyan

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $outputText
    }
}

function Invoke-InvalidModelCase {
    param(
        [Parameter(Mandatory)][string]$CaseName,
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Model
    )

    $argvPath = Join-Path $testRoot "$CaseName.argv.txt"
    if (Test-Path -LiteralPath $argvPath) {
        Remove-Item -LiteralPath $argvPath -Force
    }
    Clear-FakeCodexEnvironment
    $env:FAKE_CODEX_REPO = $Repo
    $env:FAKE_CODEX_ARGV_FILE = $argvPath

    Write-Host "`n===== CASE: $CaseName =====" -ForegroundColor Cyan
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $captured = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dispatch `
            -Spec $Spec -Task 'task-1' -Phase 'build' -Worktree $Repo `
            -BaseSha (Get-FixtureHead -Repo $Repo) -Prompt "Invalid model test: $CaseName" `
            -Authorized 'src/a.py' -SkipBaselineCheck -Model $Model *>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $outputText = ConvertTo-OutputText -Captured $captured
    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
        Write-Host $outputText.TrimEnd()
    }
    Write-Host ("----- {0}: exit {1} -----" -f $CaseName, $exitCode) -ForegroundColor DarkCyan

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $outputText
        Rows = @(Get-LedgerRowsForSpec -Spec $Spec)
        ArgvPath = $argvPath
    }
}

function Test-LeaseScopedAuthorRefusal {
    param([Parameter(Mandatory)]$Result)

    $leaseRows = @($Result.Rows | Where-Object { [string]$_.row_kind -ceq 'lease' })
    if ($leaseRows.Count -ne 1) { return $false }
    $runRows = @(Get-LedgerRowsForRun -RunId ([string]$leaseRows[0].run_id))
    $closeRows = @($runRows | Where-Object { [string]$_.row_kind -ceq 'lease_close' })
    $dispatchRows = @($Result.Rows | Where-Object { [string]$_.row_kind -ceq 'dispatch' })
    return ($closeRows.Count -eq 1 -and
        [string]$closeRows[0].status -ceq 'refused-preflight' -and
        [int]$closeRows[0].refusal_exit -eq 74 -and
        $dispatchRows.Count -eq 0)
}

function Assert-AuthorRefusal {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$Message,
        [string]$DigestRepo,
        [string]$DigestPath,
        [string]$DigestBefore
    )

    Assert-Case -Label "$Label nonzero" -Condition ($Result.ExitCode -ne 0) `
        -Detail ("exit={0}" -f $Result.ExitCode)
    Assert-Case -Label $Label -Condition ($Result.ExitCode -eq 74) -Detail 'exit=74'
    Assert-Case -Label "$Label message" `
        -Condition ($Result.Output.Contains($Message)) `
        -Detail "output contains the case-specific refusal: $Message"
    Assert-Case -Label "$Label no state" `
        -Condition ($Result.Rows.Count -eq 0 -and
            -not (Test-Path -LiteralPath $Result.ArgvPath)) `
        -Detail 'zero ledger rows and no fake argv file were created'
    if (-not [string]::IsNullOrEmpty($DigestPath)) {
        $digestAfter = Get-GitObjectId -Repo $DigestRepo -Path $DigestPath
        Assert-Case -Label "$Label digest" -Condition ($digestAfter -ceq $DigestBefore) `
            -Detail 'the pre-existing draft git object id is unchanged'
    }
}

[System.IO.Directory]::CreateDirectory($repoRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($scratchRoot) | Out-Null
[System.IO.Directory]::CreateDirectory((Split-Path $ledgerPath -Parent)) | Out-Null
Write-Utf8NoBom -Path $ledgerPath -Content ''
$env:APEX_STATE_DIR = $stateRoot

try {
    $fakeAuthorContent = "---`nspec: fake-author`n---`n# Spec: fake author draft`n"

    # A create author dispatch skips only the spec-dependent gates and records its author metadata.
    $caseName = 'author-create-happy'
    $spec = 'new-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = 'docs/drafts/new-spec.md'
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath -ExtraParameters @{ Model = 'gpt-6-sol'; Effort = 'high' }
    $draftPath = Join-Path $repo 'docs\drafts\new-spec.md'
    $dispatchRows = @($result.Rows | Where-Object { [string]$_.row_kind -ceq 'dispatch' })
    $row = if ($dispatchRows.Count -eq 1) { $dispatchRows[0] } else { $null }
    Assert-Case -Label 'author-create-happy' -Condition ($result.ExitCode -eq 0) `
        -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-create-happy draft content' `
        -Condition ((Test-Path -LiteralPath $draftPath -PathType Leaf) -and
            [System.IO.File]::ReadAllText($draftPath) -ceq $fakeAuthorContent) `
        -Detail 'the authorized draft contains the fake author content'
    Assert-Case -Label 'author-create-happy argv' `
        -Condition (Test-ArgvModel -ArgvPath $result.ArgvPath -ExpectedModel 'gpt-6-sol') `
        -Detail '-m is immediately followed by gpt-6-sol'
    Assert-Case -Label 'author-create-happy ledger' `
        -Condition ($null -ne $row -and
            [string]$row.dispatch_kind -ceq 'author' -and
            [string]$row.author_mode -ceq 'create' -and
            [string]$row.model -ceq 'gpt-6-sol' -and
            [string]$row.phase -ceq 'build' -and
            [string]$row.task -ceq 'author' -and
            [string]$row.builder_family -ceq 'openai' -and
            [bool]$row.baseline_skipped) `
        -Detail 'the dispatch row records author/create/openai and the skipped baseline'
    Assert-Case -Label 'author-create-happy gates' `
        -Condition ($result.Output.Contains('[tree-pin] pinned') -and
            $result.Output.Contains("preflight-$spec") -and
            $result.Output.Contains('-AuthorSpec: spec, baseline and frontmatter pre-flight steps skipped')) `
        -Detail 'tree pin, unique preflight label, and author skip line were printed'

    # The additive model allowlist entry is passed to Codex and recorded case-exactly.
    $caseName = 'author-create-gpt-6.1-sol'
    $spec = 'new-spec-6-1'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = 'docs/drafts/new-spec-6-1.md'
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath -ExtraParameters @{ Model = 'gpt-6.1-sol'; Effort = 'high' }
    $draftPath = Join-Path $repo 'docs\drafts\new-spec-6-1.md'
    $dispatchRows = @($result.Rows | Where-Object { [string]$_.row_kind -ceq 'dispatch' })
    $row = if ($dispatchRows.Count -eq 1) { $dispatchRows[0] } else { $null }
    Assert-Case -Label 'author-create-gpt-6.1-sol' -Condition ($result.ExitCode -eq 0) `
        -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-create-gpt-6.1-sol draft content' `
        -Condition ((Test-Path -LiteralPath $draftPath -PathType Leaf) -and
            [System.IO.File]::ReadAllText($draftPath) -ceq $fakeAuthorContent) `
        -Detail 'the authorized draft contains the fake author content'
    Assert-Case -Label 'author-create-gpt-6.1-sol argv' `
        -Condition (Test-ArgvModel -ArgvPath $result.ArgvPath -ExpectedModel 'gpt-6.1-sol') `
        -Detail '-m is immediately followed by gpt-6.1-sol'
    Assert-Case -Label 'author-create-gpt-6.1-sol ledger' `
        -Condition ($null -ne $row -and
            [string]$row.dispatch_kind -ceq 'author' -and
            [string]$row.author_mode -ceq 'create' -and
            [string]$row.model -ceq 'gpt-6.1-sol' -and
            [string]$row.phase -ceq 'build' -and
            [string]$row.task -ceq 'author' -and
            [string]$row.builder_family -ceq 'openai' -and
            [bool]$row.baseline_skipped) `
        -Detail 'the dispatch row records the exact gpt-6.1-sol model and author metadata'
    Assert-Case -Label 'author-create-gpt-6.1-sol gates' `
        -Condition ($result.Output.Contains('[tree-pin] pinned') -and
            $result.Output.Contains("preflight-$spec") -and
            $result.Output.Contains('-AuthorSpec: spec, baseline and frontmatter pre-flight steps skipped')) `
        -Detail 'tree pin, unique preflight label, and author skip line were printed'

    # The additive model allowlist entry is passed to Codex and recorded case-exactly.
    $caseName = 'author-create-gpt-6-luna'
    $spec = 'new-spec-luna'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = 'docs/drafts/new-spec-luna.md'
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath -ExtraParameters @{ Model = 'gpt-6-luna'; Effort = 'high' }
    $draftPath = Join-Path $repo 'docs\drafts\new-spec-luna.md'
    $dispatchRows = @($result.Rows | Where-Object { [string]$_.row_kind -ceq 'dispatch' })
    $row = if ($dispatchRows.Count -eq 1) { $dispatchRows[0] } else { $null }
    Assert-Case -Label 'author-create-gpt-6-luna' -Condition ($result.ExitCode -eq 0) `
        -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-create-gpt-6-luna draft content' `
        -Condition ((Test-Path -LiteralPath $draftPath -PathType Leaf) -and
            [System.IO.File]::ReadAllText($draftPath) -ceq $fakeAuthorContent) `
        -Detail 'the authorized draft contains the fake author content'
    Assert-Case -Label 'author-create-gpt-6-luna argv' `
        -Condition (Test-ArgvModel -ArgvPath $result.ArgvPath -ExpectedModel 'gpt-6-luna') `
        -Detail '-m is immediately followed by gpt-6-luna'
    Assert-Case -Label 'author-create-gpt-6-luna ledger' `
        -Condition ($null -ne $row -and
            [string]$row.dispatch_kind -ceq 'author' -and
            [string]$row.author_mode -ceq 'create' -and
            [string]$row.model -ceq 'gpt-6-luna' -and
            [string]$row.phase -ceq 'build' -and
            [string]$row.task -ceq 'author' -and
            [string]$row.builder_family -ceq 'openai' -and
            [bool]$row.baseline_skipped) `
        -Detail 'the dispatch row records the exact gpt-6-luna model and author metadata'
    Assert-Case -Label 'author-create-gpt-6-luna gates' `
        -Condition ($result.Output.Contains('[tree-pin] pinned') -and
            $result.Output.Contains("preflight-$spec") -and
            $result.Output.Contains('-AuthorSpec: spec, baseline and frontmatter pre-flight steps skipped')) `
        -Detail 'tree pin, unique preflight label, and author skip line were printed'

    # A revise author dispatch binds the existing untracked draft by its git object id.
    $caseName = 'author-revise-happy'
    $spec = 'rev-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = 'docs/drafts/rev-spec.md'
    $draftPath = Join-Path $repo 'docs\drafts\rev-spec.md'
    Write-Utf8NoBom -Path $draftPath -Content "original draft`n"
    $expectedDigest = Get-GitObjectId -Repo $repo -Path $authorPath
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath -ExtraParameters @{ ExpectedDigest = $expectedDigest }
    $dispatchRows = @($result.Rows | Where-Object { [string]$_.row_kind -ceq 'dispatch' })
    $row = if ($dispatchRows.Count -eq 1) { $dispatchRows[0] } else { $null }
    Assert-Case -Label 'author-revise-happy' -Condition ($result.ExitCode -eq 0) `
        -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-revise-happy draft content' `
        -Condition ((Test-Path -LiteralPath $draftPath -PathType Leaf) -and
            [System.IO.File]::ReadAllText($draftPath) -ceq $fakeAuthorContent) `
        -Detail 'the authorized draft contains the fake author content'
    Assert-Case -Label 'author-revise-happy ledger' `
        -Condition ($null -ne $row -and [string]$row.author_mode -ceq 'revise') `
        -Detail 'the dispatch row records revise mode'

    # The critical-file hook moves the revise digest after the lease but before the tree pin.
    $caseName = 'author-revise-toctou'
    $spec = 'revise-race-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = "docs/drafts/$spec.md"
    $draftPath = Join-Path $repo "docs\drafts\$spec.md"
    Write-Utf8NoBom -Path $draftPath -Content "original draft`n"
    $expectedDigest = Get-GitObjectId -Repo $repo -Path $authorPath
    $criticalStub = Join-Path $testRoot "$caseName-critical.ps1"
    Write-Utf8NoBom -Path $criticalStub -Content @"
param([switch]`$Test, [string[]]`$Paths, [string]`$Root)
Add-Content -LiteralPath (Join-Path `$Root 'docs\drafts\$spec.md') -Value 'raced'
exit 0
"@
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath -ExtraParameters @{
            ExpectedDigest = $expectedDigest
            CriticalFilesScript = $criticalStub
        }
    Assert-Case -Label 'author-revise-toctou nonzero' -Condition ($result.ExitCode -ne 0) `
        -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-revise-toctou' -Condition ($result.ExitCode -eq 74) `
        -Detail 'exit=74'
    Assert-Case -Label 'author-revise-toctou message' `
        -Condition ($result.Output.Contains('changed before the pre-flight pin armed') -and
            $result.Output.Contains("revise target '$authorPath'")) `
        -Detail 'the revise race and literal author path were named'
    Assert-Case -Label 'author-revise-toctou no launch' `
        -Condition (-not (Test-Path -LiteralPath $result.ArgvPath)) `
        -Detail 'the fake Codex argv file is absent'
    Assert-Case -Label 'author-revise-toctou lease close' `
        -Condition (Test-LeaseScopedAuthorRefusal -Result $result) `
        -Detail 'the sole lease closed refused-preflight/74 and no dispatch row exists'

    # The critical-file hook creates the target after the lease but before the tree pin.
    $caseName = 'author-create-toctou'
    $spec = 'race-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = 'docs/drafts/race-spec.md'
    $criticalStub = Join-Path $testRoot "$caseName-critical.ps1"
    Write-Utf8NoBom -Path $criticalStub -Content @"
param([switch]`$Test, [string[]]`$Paths, [string]`$Root)
[System.IO.File]::WriteAllText((Join-Path `$Root 'docs\drafts\race-spec.md'), 'raced', [System.Text.UTF8Encoding]::new(`$false))
exit 0
"@
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath -ExtraParameters @{ CriticalFilesScript = $criticalStub }
    Assert-Case -Label 'author-create-toctou nonzero' -Condition ($result.ExitCode -ne 0) `
        -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-create-toctou' -Condition ($result.ExitCode -eq 74) `
        -Detail 'exit=74'
    Assert-Case -Label 'author-create-toctou message' `
        -Condition ($result.Output.Contains('appeared before the pre-flight pin armed') -and
            $result.Output.Contains("create target '$authorPath'")) `
        -Detail 'the create race and literal author path were named'
    Assert-Case -Label 'author-create-toctou no launch' `
        -Condition (-not (Test-Path -LiteralPath $result.ArgvPath)) `
        -Detail 'the fake Codex argv file is absent'
    Assert-Case -Label 'author-create-toctou lease close' `
        -Condition (Test-LeaseScopedAuthorRefusal -Result $result) `
        -Detail 'the sole lease closed refused-preflight/74 and no dispatch row exists'

    # A normal build without a recipe keeps the existing baseline refusal.
    $caseName = 'author-control-nonauthor-72'
    $spec = 'control-nonauthor'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo -NonAuthor
    Assert-Case -Label 'author-control-nonauthor-72 nonzero' -Condition ($result.ExitCode -ne 0) `
        -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-control-nonauthor-72' -Condition ($result.ExitCode -eq 72) `
        -Detail 'the ordinary build retained exit 72'

    # A normal build defaults to gpt-6.1-sol and gains only the additive ledger keys.
    $caseName = 'author-default-model-argv'
    $spec = 'default-model'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo -NonAuthor `
        -ExtraParameters @{ SkipBaselineCheck = $true } `
        -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }
    $dispatchRows = @($result.Rows | Where-Object { [string]$_.row_kind -ceq 'dispatch' })
    $row = if ($dispatchRows.Count -eq 1) { $dispatchRows[0] } else { $null }
    Assert-Case -Label 'author-default-model-argv' -Condition ($result.ExitCode -eq 0) `
        -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-default-model-argv argv' `
        -Condition (Test-ArgvModel -ArgvPath $result.ArgvPath -ExpectedModel 'gpt-6.1-sol') `
        -Detail '-m is immediately followed by gpt-6.1-sol'
    Assert-Case -Label 'author-default-model-argv ledger' `
        -Condition ($null -ne $row -and
            [string]$row.model -ceq 'gpt-6.1-sol' -and
            [string]$row.dispatch_kind -ceq '' -and
            [string]$row.author_mode -ceq '' -and
            [bool]$row.baseline_skipped) `
        -Detail 'the ordinary row records gpt-6.1-sol and empty author fields'

    # ValidateSet rejects models outside the exact supported set before the script body runs.
    $caseName = 'author-model-outside-set'
    $spec = 'model-outside-set'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-InvalidModelCase -CaseName $caseName -Spec $spec -Repo $repo `
        -Model 'gpt-5.6-luna'
    Assert-Case -Label 'author-model-outside-set nonzero' -Condition ($result.ExitCode -ne 0) `
        -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-model-outside-set' -Condition ($result.ExitCode -eq 1) `
        -Detail 'parameter binding returned exit 1'
    Assert-Case -Label 'author-model-outside-set message' `
        -Condition ($result.Output.Contains('Model')) `
        -Detail 'the binding error names Model'
    Assert-Case -Label 'author-model-outside-set no state' `
        -Condition ($result.Rows.Count -eq 0 -and
            -not (Test-Path -LiteralPath $result.ArgvPath)) `
        -Detail 'zero ledger rows and no fake argv file were created'

    # ValidateSet is case-sensitive, so a mixed-case spelling is also a binding error.
    $caseName = 'author-model-mixed-case'
    $spec = 'model-mixed-case'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-InvalidModelCase -CaseName $caseName -Spec $spec -Repo $repo `
        -Model 'GPT-6-SOL'
    Assert-Case -Label 'author-model-mixed-case nonzero' -Condition ($result.ExitCode -ne 0) `
        -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-model-mixed-case' -Condition ($result.ExitCode -eq 1) `
        -Detail 'parameter binding returned exit 1'
    Assert-Case -Label 'author-model-mixed-case no state' `
        -Condition ($result.Rows.Count -eq 0 -and
            -not (Test-Path -LiteralPath $result.ArgvPath)) `
        -Detail 'zero ledger rows and no fake argv file were created'

    # The new model allowlist entry also remains case-sensitive.
    $caseName = 'author-model-6-1-mixed-case'
    $spec = 'model-6-1-mixed-case'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-InvalidModelCase -CaseName $caseName -Spec $spec -Repo $repo `
        -Model 'GPT-6.1-SOL'
    Assert-Case -Label 'author-model-6-1-mixed-case nonzero' -Condition ($result.ExitCode -ne 0) `
        -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-model-6-1-mixed-case' -Condition ($result.ExitCode -eq 1) `
        -Detail 'parameter binding returned exit 1'
    Assert-Case -Label 'author-model-6-1-mixed-case no state' `
        -Condition ($result.Rows.Count -eq 0 -and
            -not (Test-Path -LiteralPath $result.ArgvPath)) `
        -Detail 'zero ledger rows and no fake argv file were created'

    # The new model allowlist entry also remains case-sensitive.
    $caseName = 'author-model-luna-mixed-case'
    $spec = 'model-luna-mixed-case'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-InvalidModelCase -CaseName $caseName -Spec $spec -Repo $repo `
        -Model 'GPT-6-LUNA'
    Assert-Case -Label 'author-model-luna-mixed-case nonzero' -Condition ($result.ExitCode -ne 0) `
        -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-model-luna-mixed-case' -Condition ($result.ExitCode -eq 1) `
        -Detail 'parameter binding returned exit 1'
    Assert-Case -Label 'author-model-luna-mixed-case no state' `
        -Condition ($result.Rows.Count -eq 0 -and
            -not (Test-Path -LiteralPath $result.ArgvPath)) `
        -Detail 'zero ledger rows and no fake argv file were created'

    # A second draft is detected after the run and is deliberately left for inspection.
    $caseName = 'author-second-file-scope-violation'
    $spec = 'second-file-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = "docs/drafts/$spec.md"
    $extraPath = 'docs/drafts/other.md'
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath `
        -FakeEnvironment @{ FAKE_CODEX_EXTRA_WRITE = $extraPath }
    Assert-Case -Label 'author-second-file-scope-violation nonzero' `
        -Condition ($result.ExitCode -ne 0) -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-second-file-scope-violation' `
        -Condition ($result.ExitCode -eq 65) -Detail 'exit=65'
    Assert-Case -Label 'author-second-file-scope-violation preserves write' `
        -Condition (Test-Path -LiteralPath (Join-Path $repo 'docs\drafts\other.md') -PathType Leaf) `
        -Detail 'the unauthorized second draft remains present'

    # Two unauthorized writes and no authorized hit retain scope-check exit 66.
    $caseName = 'author-two-unauthorized-66'
    $spec = 'two-unauthorized-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = "docs/drafts/$spec.md"
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath -FakeEnvironment @{
            FAKE_CODEX_AUTHOR_NO_WRITE = '1'
            FAKE_CODEX_EXTRA_WRITE = 'docs/drafts/stray-a.md;docs/drafts/stray-b.md'
        }
    Assert-Case -Label 'author-two-unauthorized-66 nonzero' `
        -Condition ($result.ExitCode -ne 0) -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-two-unauthorized-66' `
        -Condition ($result.ExitCode -eq 66) -Detail 'exit=66'
    Assert-Case -Label 'author-two-unauthorized-66 message' `
        -Condition ($result.Output.Contains('AUTHOR SCOPE VIOLATION')) `
        -Detail 'the author scope violation was reported'
    Assert-Case -Label 'author-two-unauthorized-66 preserves writes' `
        -Condition ((Test-Path -LiteralPath (Join-Path $repo 'docs\drafts\stray-a.md') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $repo 'docs\drafts\stray-b.md') -PathType Leaf) -and
            -not (Test-Path -LiteralPath (Join-Path $repo "docs\drafts\$spec.md"))) `
        -Detail 'both unauthorized files remain and the authorized draft is absent'

    # A failed child with an exact author write and no report follows the child-failure route.
    $caseName = 'author-child-fail-no-report-1'
    $spec = 'child-fail-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = "docs/drafts/$spec.md"
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath `
        -FakeEnvironment @{ FAKE_CODEX_AUTHOR_FAIL_EXIT = '3' }
    Assert-Case -Label 'author-child-fail-no-report-1 nonzero' `
        -Condition ($result.ExitCode -ne 0) -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-child-fail-no-report-1' `
        -Condition ($result.ExitCode -eq 1) -Detail 'exit=1'
    Assert-Case -Label 'author-child-fail-no-report-1 message' `
        -Condition ($result.Output.Contains('child failed (exit 3)') -and
            -not $result.Output.Contains('AUTHOR SCOPE VIOLATION')) `
        -Detail 'the child failure was reported without an author scope violation'

    # A directory at the authorized path is not the one required regular file.
    $caseName = 'author-dir-escape'
    $spec = 'dir-escape-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = "docs/drafts/$spec.md"
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath `
        -FakeEnvironment @{ FAKE_CODEX_AUTHOR_AS_DIR = '1' }
    Assert-Case -Label 'author-dir-escape nonzero' `
        -Condition ($result.ExitCode -ne 0) -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-dir-escape' `
        -Condition ($result.ExitCode -eq 65) -Detail 'exit=65'
    Assert-Case -Label 'author-dir-escape message' `
        -Condition ($result.Output.Contains('AUTHOR SCOPE VIOLATION')) `
        -Detail 'the author scope violation was reported'

    # A successful child with neither a report nor an author write is coerced to blocked first.
    $caseName = 'author-no-write-blocked-67'
    $spec = 'no-write-blocked-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = "docs/drafts/$spec.md"
    $draftPath = Join-Path $repo "docs\drafts\$spec.md"
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath -FakeEnvironment @{
            FAKE_CODEX_AUTHOR_NO_WRITE = '1'
            FAKE_CODEX_NO_REPORT = '1'
        }
    Assert-Case -Label 'author-no-write-blocked-67 nonzero' `
        -Condition ($result.ExitCode -ne 0) -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-no-write-blocked-67' `
        -Condition ($result.ExitCode -eq 67) -Detail 'exit=67'
    Assert-Case -Label 'author-no-write-blocked-67 no draft' `
        -Condition (-not (Test-Path -LiteralPath $draftPath)) `
        -Detail 'the authorized draft is absent'

    # A done report with no write reaches the exact-one-file author scope refusal.
    $caseName = 'author-no-write-done-65'
    $spec = 'no-write-done-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = "docs/drafts/$spec.md"
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath `
        -FakeEnvironment @{ FAKE_CODEX_AUTHOR_NO_WRITE = '1' }
    Assert-Case -Label 'author-no-write-done-65 nonzero' `
        -Condition ($result.ExitCode -ne 0) -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label 'author-no-write-done-65' `
        -Condition ($result.ExitCode -eq 65) -Detail 'exit=65'
    Assert-Case -Label 'author-no-write-done-65 message' `
        -Condition ($result.Output.Contains('AUTHOR SCOPE VIOLATION') -and
            $result.Output.Contains('(none)')) `
        -Detail 'the empty written set was reported as an author scope violation'

    # Probe file-symlink support once and share the result with both symlink cases.
    $symlinkProbeTarget = Join-Path $testRoot 'symlink-probe-target.txt'
    $symlinkProbeLink = Join-Path $testRoot 'symlink-probe-link.txt'
    Write-Utf8NoBom -Path $symlinkProbeTarget -Content 'probe target'
    $symlinkProbe = Invoke-MklinkCommand -Link $symlinkProbeLink -Target $symlinkProbeTarget
    $symlinkProbeOutput = @($symlinkProbe.Output)
    $symlinkProbeExit = $symlinkProbe.ExitCode
    $symlinkProbeReason = (@($symlinkProbeOutput | ForEach-Object { [string]$_ }) -join ' ').Trim()

    if ($symlinkProbeExit -ne 0) {
        Write-SkippedCase -Label 'author-symlink-target' `
            -Reason "cannot create symlinks on this host: $symlinkProbeReason"
    }
    else {
        # A post-run file symlink at the authorized path is not a regular author result.
        $caseName = 'author-symlink-target'
        $spec = 'symlink-target-spec'
        $repo = New-FixtureRepo -Name $caseName
        $authorPath = "docs/drafts/$spec.md"
        $outsideTarget = Join-Path $testRoot "$caseName-outside.txt"
        $authorFullPath = Join-Path $repo "docs\drafts\$spec.md"
        $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
            -AuthorizedPath $authorPath `
            -FakeEnvironment @{ FAKE_CODEX_AUTHOR_AS_SYMLINK = $outsideTarget }
        $authorItem = if (Test-Path -LiteralPath $authorFullPath) {
            Get-Item -LiteralPath $authorFullPath -Force
        }
        else { $null }
        Assert-Case -Label 'author-symlink-target nonzero' `
            -Condition ($result.ExitCode -ne 0) -Detail ("exit={0}" -f $result.ExitCode)
        Assert-Case -Label 'author-symlink-target' `
            -Condition ($result.ExitCode -eq 65) -Detail 'exit=65'
        Assert-Case -Label 'author-symlink-target message' `
            -Condition ($result.Output.Contains('AUTHOR SCOPE VIOLATION') -and
                -not $result.Output.Contains('(none)') -and
                -not $result.Output.Contains('FAKE-CODEX: FAIL')) `
            -Detail 'the symlink is named as a write and the fake created it successfully'
        Assert-Case -Label 'author-symlink-target reparse point' `
            -Condition ($null -ne $authorItem -and
                [bool]($authorItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) `
            -Detail 'the authorized path exists as a reparse point'
    }

    if ($symlinkProbeExit -ne 0) {
        Write-SkippedCase -Label 'author-reparse-revise-symlink-74' `
            -Reason "cannot create symlinks on this host: $symlinkProbeReason"
    }
    else {
        # An existing revise target that is a symlink is refused before a lease is written.
        $caseName = 'author-reparse-revise-symlink-74'
        $spec = 'link-spec'
        $repo = New-FixtureRepo -Name $caseName
        $authorPath = 'docs/drafts/link-spec.md'
        $authorFullPath = Join-Path $repo 'docs\drafts\link-spec.md'
        $outsideTarget = Join-Path $testRoot "$caseName-target.txt"
        Write-Utf8NoBom -Path $outsideTarget -Content 'original'
        $linkResult = Invoke-MklinkCommand -Link $authorFullPath -Target $outsideTarget
        if ($linkResult.ExitCode -ne 0) {
            throw "File-symlink probe passed but case setup failed: $($linkResult.Output -join ' ')"
        }
        $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
            -AuthorizedPath $authorPath `
            -ExtraParameters @{ ExpectedDigest = ('a' * 40) }
        Assert-Case -Label 'author-reparse-revise-symlink-74 nonzero' `
            -Condition ($result.ExitCode -ne 0) -Detail ("exit={0}" -f $result.ExitCode)
        Assert-Case -Label 'author-reparse-revise-symlink-74' `
            -Condition ($result.ExitCode -eq 74) -Detail 'exit=74'
        Assert-Case -Label 'author-reparse-revise-symlink-74 message' `
            -Condition ($result.Output.Contains("-AuthorSpec path 'docs/drafts/link-spec.md' is a reparse point (symlink or junction)")) `
            -Detail 'the revise target reparse point was named'
        Assert-Case -Label 'author-reparse-revise-symlink-74 no state' `
            -Condition ($result.Rows.Count -eq 0 -and
                -not (Test-Path -LiteralPath $result.ArgvPath)) `
            -Detail 'zero ledger rows and no fake argv file were created'
        Assert-Case -Label 'author-reparse-revise-symlink-74 target unchanged' `
            -Condition ([System.IO.File]::ReadAllText($outsideTarget) -ceq 'original') `
            -Detail 'the link target still contains its original content'
    }

    if ($symlinkProbeExit -ne 0) {
        Write-SkippedCase -Label 'author-reparse-dangling-symlink-74' `
            -Reason "cannot create symlinks on this host: $symlinkProbeReason"
    }
    else {
        # GetAttributes must identify a dangling link without following its absent target.
        $caseName = 'author-reparse-dangling-symlink-74'
        $spec = 'dang-spec'
        $repo = New-FixtureRepo -Name $caseName
        $authorPath = 'docs/drafts/dang-spec.md'
        $authorFullPath = Join-Path $repo 'docs\drafts\dang-spec.md'
        $missingTarget = Join-Path $testRoot 'dangling-target-does-not-exist.md'
        $linkResult = Invoke-MklinkCommand -Link $authorFullPath -Target $missingTarget
        if ($linkResult.ExitCode -ne 0) {
            throw "File-symlink probe passed but dangling-link setup failed: $($linkResult.Output -join ' ')"
        }
        $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
            -AuthorizedPath $authorPath
        Assert-Case -Label 'author-reparse-dangling-symlink-74 nonzero' `
            -Condition ($result.ExitCode -ne 0) -Detail ("exit={0}" -f $result.ExitCode)
        Assert-Case -Label 'author-reparse-dangling-symlink-74' `
            -Condition ($result.ExitCode -eq 74) -Detail 'exit=74'
        Assert-Case -Label 'author-reparse-dangling-symlink-74 message' `
            -Condition ($result.Output.Contains("-AuthorSpec path 'docs/drafts/dang-spec.md' is a reparse point (symlink or junction)")) `
            -Detail 'the dangling target reparse point was named'
        Assert-Case -Label 'author-reparse-dangling-symlink-74 no state' `
            -Condition ($result.Rows.Count -eq 0 -and
                -not (Test-Path -LiteralPath $result.ArgvPath)) `
            -Detail 'zero ledger rows and no fake argv file were created'
        Assert-Case -Label 'author-reparse-dangling-symlink-74 target absent' `
            -Condition (-not (Test-Path -LiteralPath $missingTarget)) `
            -Detail 'the dangling link target remains absent'
    }

    # Probe junction support independently; unlike file symlinks this normally needs no elevation.
    $junctionProbeTarget = Join-Path $testRoot 'junction-probe-target'
    $junctionProbeLink = Join-Path $testRoot 'junction-probe-link'
    [System.IO.Directory]::CreateDirectory($junctionProbeTarget) | Out-Null
    $junctionProbe = Invoke-MklinkCommand -Link $junctionProbeLink -Target $junctionProbeTarget -Junction
    $junctionProbeOutput = @($junctionProbe.Output)
    $junctionProbeExit = $junctionProbe.ExitCode
    $junctionProbeReason = (@($junctionProbeOutput | ForEach-Object { [string]$_ }) -join ' ').Trim()

    if ($junctionProbeExit -ne 0) {
        Write-SkippedCase -Label 'author-reparse-drafts-junction-74' `
            -Reason "cannot create junctions on this host: $junctionProbeReason"
    }
    else {
        # An existing ancestor junction is refused before a lease or dispatch row is written.
        $caseName = 'author-reparse-drafts-junction-74'
        $spec = 'jn-spec'
        $repo = New-FixtureRepo -Name $caseName
        $authorPath = 'docs/drafts/jn-spec.md'
        $draftsPath = Join-Path $repo 'docs\drafts'
        $junctionTarget = Join-Path $testRoot "$caseName-target"
        Move-Item -LiteralPath $draftsPath -Destination $junctionTarget
        $junctionResult = Invoke-MklinkCommand -Link $draftsPath -Target $junctionTarget -Junction
        if ($junctionResult.ExitCode -ne 0) {
            throw "Junction probe passed but case setup failed: $($junctionResult.Output -join ' ')"
        }
        $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
            -AuthorizedPath $authorPath
        Assert-Case -Label 'author-reparse-drafts-junction-74 nonzero' `
            -Condition ($result.ExitCode -ne 0) -Detail ("exit={0}" -f $result.ExitCode)
        Assert-Case -Label 'author-reparse-drafts-junction-74' `
            -Condition ($result.ExitCode -eq 74) -Detail 'exit=74'
        Assert-Case -Label 'author-reparse-drafts-junction-74 message' `
            -Condition ($result.Output.Contains("-AuthorSpec path 'docs/drafts' is a reparse point (symlink or junction)")) `
            -Detail 'the drafts ancestor junction was named'
        Assert-Case -Label 'author-reparse-drafts-junction-74 no state' `
            -Condition ($result.Rows.Count -eq 0 -and
                -not (Test-Path -LiteralPath $result.ArgvPath)) `
            -Detail 'zero ledger rows and no fake argv file were created'
        Assert-Case -Label 'author-reparse-drafts-junction-74 no draft' `
            -Condition (-not (Test-Path -LiteralPath (Join-Path $junctionTarget 'jn-spec.md'))) `
            -Detail 'the junction target contains no created author draft'
    }

    # The task reservation is case-insensitive for a plain build.
    $caseName = 'author-reserved-mixedcase-74'
    $spec = 'reserved-mixedcase-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo -NonAuthor `
        -ExtraParameters @{ Task = 'Author'; SkipBaselineCheck = $true }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message '-Task author is reserved for -AuthorSpec dispatches'

    # Adoption must re-run the author exact-one-regular-file check for an orphaned author row.
    $caseName = 'author-adopt-nowrite-nonzero'
    $spec = 'adopt-nowrite-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = "docs/drafts/$spec.md"
    $authorFullPath = Join-Path $repo "docs\drafts\$spec.md"
    $fixtureResult = Invoke-DispatchCase -CaseName "$caseName-fixture" -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath
    $fixtureRow = @($fixtureResult.Rows | Where-Object {
            [string]$_.row_kind -ceq 'dispatch'
        }) | Select-Object -Last 1
    Assert-Case -Label "$caseName fixture" `
        -Condition ($fixtureResult.ExitCode -eq 0 -and $null -ne $fixtureRow -and
            [string]$fixtureRow.dispatch_kind -ceq 'author') `
        -Detail 'a genuine completed author dispatch row was created'
    if ($null -eq $fixtureRow) { throw "$caseName could not construct an author dispatch row." }
    Set-TestDispatchRowOrphaned -RunId ([string]$fixtureRow.run_id)
    Remove-Item -LiteralPath $authorFullPath -Force
    $result = Invoke-AdoptCase -CaseName $caseName -Spec $spec -Repo $repo `
        -RunId ([string]$fixtureRow.run_id)
    Assert-Case -Label $caseName -Condition ($result.ExitCode -ne 0) `
        -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label "$caseName message" `
        -Condition ($result.Output.Contains('AUTHOR SCOPE VIOLATION')) `
        -Detail 'adoption rejected the absent author target'

    $caseName = 'author-adopt-dir-nonzero'
    $spec = 'adopt-dir-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = "docs/drafts/$spec.md"
    $authorFullPath = Join-Path $repo "docs\drafts\$spec.md"
    $fixtureResult = Invoke-DispatchCase -CaseName "$caseName-fixture" -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath
    $fixtureRow = @($fixtureResult.Rows | Where-Object {
            [string]$_.row_kind -ceq 'dispatch'
        }) | Select-Object -Last 1
    Assert-Case -Label "$caseName fixture" `
        -Condition ($fixtureResult.ExitCode -eq 0 -and $null -ne $fixtureRow -and
            [string]$fixtureRow.dispatch_kind -ceq 'author') `
        -Detail 'a genuine completed author dispatch row was created'
    if ($null -eq $fixtureRow) { throw "$caseName could not construct an author dispatch row." }
    Set-TestDispatchRowOrphaned -RunId ([string]$fixtureRow.run_id)
    Remove-Item -LiteralPath $authorFullPath -Force
    [System.IO.Directory]::CreateDirectory($authorFullPath) | Out-Null
    $result = Invoke-AdoptCase -CaseName $caseName -Spec $spec -Repo $repo `
        -RunId ([string]$fixtureRow.run_id)
    Assert-Case -Label $caseName -Condition ($result.ExitCode -ne 0) `
        -Detail ("exit={0}" -f $result.ExitCode)
    Assert-Case -Label "$caseName message" `
        -Condition ($result.Output.Contains('AUTHOR SCOPE VIOLATION')) `
        -Detail 'adoption rejected a directory at the author target'

    # Caller-contract refusals must all fail before a lease or child launch.
    $caseName = 'author-refuse-phase-review'
    $spec = 'phase-review-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -ExtraParameters @{ Phase = 'review' }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message "-AuthorSpec implies -Phase build -Schema completion -Sandbox workspace-write (got 'review/completion/workspace-write')"

    $caseName = 'author-refuse-schema-review'
    $spec = 'schema-review-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo -OmitPhase `
        -ExtraParameters @{ Schema = 'review' }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message "-AuthorSpec implies -Phase build -Schema completion -Sandbox workspace-write (got '/review/workspace-write')"

    $caseName = 'author-refuse-sandbox-readonly'
    $spec = 'sandbox-readonly-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo -OmitPhase `
        -ExtraParameters @{ Sandbox = 'read-only' }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message "-AuthorSpec implies -Phase build -Schema completion -Sandbox workspace-write (got '/completion/read-only')"

    $caseName = 'author-refuse-zero-paths'
    $spec = 'zero-paths-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -ExtraParameters @{ Authorized = @() }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message '-AuthorSpec requires exactly one -Authorized path (got 0)'

    $caseName = 'author-refuse-two-paths'
    $spec = 'two-paths-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -ExtraParameters @{ Authorized = @('docs/drafts/a-spec.md', 'docs/drafts/b-spec.md') }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message '-AuthorSpec requires exactly one -Authorized path (got 2)'

    $caseName = 'author-refuse-outside-changes'
    $spec = 'outside-changes-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = 'docs/changes/x.md'
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message "-AuthorSpec path 'docs/changes/x.md' must match"

    $caseName = 'author-refuse-outside-uppercase'
    $spec = 'outside-uppercase-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = 'docs/drafts/Upper.md'
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message "-AuthorSpec path 'docs/drafts/Upper.md' must match"

    $caseName = 'author-refuse-outside-subdir'
    $spec = 'outside-subdir-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = 'docs/drafts/sub/x.md'
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message "-AuthorSpec path 'docs/drafts/sub/x.md' must match"

    $caseName = 'author-refuse-trailing-newline'
    $spec = 'trailing-newline-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = "docs/drafts/nl-spec.md`n"
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message "docs/drafts/nl-spec.md`n' must match"

    $caseName = 'author-refuse-skip-baseline'
    $spec = 'skip-baseline-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -ExtraParameters @{ SkipBaselineCheck = $true }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message '-AuthorSpec cannot be combined with -SkipBaselineCheck'

    $caseName = 'author-refuse-scope-unlocked'
    $spec = 'scope-unlocked-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -ExtraParameters @{ ScopeUnlocked = $true; ScopeUnlockedReason = 'x' }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message '-AuthorSpec cannot be combined with -ScopeUnlocked'

    $caseName = 'author-refuse-shared-worktree'
    $spec = 'shared-worktree-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -ExtraParameters @{ AllowSharedWorktree = $true; AllowSharedWorktreeReason = 'x' }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message '-AuthorSpec cannot be combined with -AllowSharedWorktree'

    $caseName = 'author-refuse-adopt'
    $spec = 'adopt-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -ExtraParameters @{ Adopt = $true }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message '-AuthorSpec cannot be combined with -Adopt'

    $caseName = 'author-refuse-list-obligations'
    $spec = 'list-obligations-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -ExtraParameters @{ ListObligations = $true }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message '-AuthorSpec cannot be combined with -ListObligations'

    $caseName = 'author-refuse-abandon'
    $spec = 'abandon-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -ExtraParameters @{ AbandonRunId = ('a' * 32); AbandonReason = 'x' }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message '-AuthorSpec cannot be combined with -AbandonRunId'

    $caseName = 'author-refuse-task-not-author'
    $spec = 'task-not-author-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -ExtraParameters @{ Task = 'task-1' }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message "-AuthorSpec requires -Task author (got 'task-1')"

    $caseName = 'author-refuse-spec-mismatch'
    $spec = 'other-name'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = 'docs/drafts/new-spec.md'
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message "-AuthorSpec requires -Spec to equal the draft name 'new-spec' (got 'other-name')"

    $caseName = 'author-refuse-reserved-task-nonauthor'
    $spec = 'reserved-task-nonauthor-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo -NonAuthor `
        -ExtraParameters @{ Task = 'author'; SkipBaselineCheck = $true }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message '-Task author is reserved for -AuthorSpec dispatches'

    $caseName = 'author-refuse-digest-without-author'
    $spec = 'digest-without-author-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo -NonAuthor `
        -ExtraParameters @{ ExpectedDigest = ('a' * 40) }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message '-ExpectedDigest is only valid with -AuthorSpec'

    $caseName = 'author-refuse-digest-malformed'
    $spec = 'digest-malformed-spec'
    $repo = New-FixtureRepo -Name $caseName
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -ExtraParameters @{ ExpectedDigest = 'XYZ' }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message "-ExpectedDigest 'XYZ' is not a lowercase hex git object id"

    # Disk-state refusals still happen before a lease and leave existing content untouched.
    $caseName = 'author-refuse-create-tracked'
    $spec = 'keep'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = 'docs/drafts/keep.md'
    Remove-Item -LiteralPath (Join-Path $repo 'docs\drafts\keep.md') -Force
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message "-AuthorSpec create target 'docs/drafts/keep.md' is tracked in git"

    $caseName = 'author-refuse-drafts-untracked-parent'
    $spec = 'untracked-parent-spec'
    $repo = New-FixtureRepo -Name $caseName
    Invoke-FixtureGit -Repo $repo -GitArguments @('rm', '-q', '--', 'docs/drafts/keep.md') | Out-Null
    Invoke-FixtureGit -Repo $repo -GitArguments @('commit', '-q', '-m', 'remove tracked draft placeholder') | Out-Null
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message '-AuthorSpec needs at least one tracked file under docs/drafts/'

    $caseName = 'author-refuse-revise-target-missing'
    $spec = 'revise-target-missing-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = 'docs/drafts/revise-target-missing-spec.md'
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath -ExtraParameters @{ ExpectedDigest = ('a' * 40) }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message 'does not exist -- omit -ExpectedDigest to create it'

    $caseName = 'author-refuse-revise-digest-missing'
    $spec = 'revise-digest-missing-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = 'docs/drafts/revise-digest-missing-spec.md'
    Write-Utf8NoBom -Path (Join-Path $repo 'docs\drafts\revise-digest-missing-spec.md') `
        -Content "existing draft`n"
    $digestBefore = Get-GitObjectId -Repo $repo -Path $authorPath
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message 'already exists -- a revise dispatch requires -ExpectedDigest' `
        -DigestRepo $repo -DigestPath $authorPath -DigestBefore $digestBefore

    $caseName = 'author-refuse-revise-digest-mismatch'
    $spec = 'revise-digest-mismatch-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = 'docs/drafts/revise-digest-mismatch-spec.md'
    Write-Utf8NoBom -Path (Join-Path $repo 'docs\drafts\revise-digest-mismatch-spec.md') `
        -Content "existing draft`n"
    $digestBefore = Get-GitObjectId -Repo $repo -Path $authorPath
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath -ExtraParameters @{ ExpectedDigest = ('a' * 40) }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message 'does not match -ExpectedDigest aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' `
        -DigestRepo $repo -DigestPath $authorPath -DigestBefore $digestBefore

    $caseName = 'author-refuse-target-is-directory'
    $spec = 'dir-spec'
    $repo = New-FixtureRepo -Name $caseName
    $authorPath = 'docs/drafts/dir-spec.md'
    [System.IO.Directory]::CreateDirectory((Join-Path $repo 'docs\drafts\dir-spec.md')) | Out-Null
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -AuthorizedPath $authorPath
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message "-AuthorSpec target 'docs/drafts/dir-spec.md' exists but is not a file"

    $caseName = 'author-refuse-git-failure'
    $spec = 'git-failure-spec'
    $repo = New-FixtureRepo -Name $caseName
    $fixtureHead = Get-FixtureHead -Repo $repo
    $gitDirectory = Join-Path $repo '.git'
    $missingGitDirectory = Join-Path $testRoot 'missing-gitdir'
    Remove-Item -LiteralPath $gitDirectory -Recurse -Force
    Write-Utf8NoBom -Path $gitDirectory -Content "gitdir: $missingGitDirectory`n"
    $result = Invoke-DispatchCase -CaseName $caseName -Spec $spec -Repo $repo `
        -ExtraParameters @{ BaseSha = $fixtureHead }
    Assert-AuthorRefusal -Label $caseName -Result $result `
        -Message '-AuthorSpec could not verify'
}
catch {
    $script:failureCount++
    Write-Host "`nFAIL  suite setup/execution threw: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
}
finally {
    foreach ($name in @(
            'APEX_STATE_DIR',
            'FAKE_CODEX_REPO',
            'FAKE_CODEX_ARGV_FILE',
            'FAKE_CODEX_AUTHOR_PATH',
            'FAKE_CODEX_AUTHOR_NO_WRITE',
            'FAKE_CODEX_AUTHOR_AS_DIR',
            'FAKE_CODEX_AUTHOR_AS_SYMLINK',
            'FAKE_CODEX_AUTHOR_FAIL_EXIT',
            'FAKE_CODEX_EXTRA_WRITE',
            'FAKE_CODEX_NO_REPORT',
            'FAKE_CODEX_INSCOPE_ONLY'
        )) {
        Set-OptionalEnvironmentValue -Name $name -Value $oldEnvironment[$name]
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n===== AUTHOR SUITE SUMMARY =====" -ForegroundColor Cyan
Write-Host ("Assertions: {0}; failures: {1}; skips: {2}" -f
    $script:assertionCount, $script:failureCount, $script:skipCount)
if ($script:failureCount -gt 0) {
    Write-Host 'dispatch-author-test.ps1 FAILED' -ForegroundColor Red
    exit 1
}

Write-Host 'dispatch-author-test.ps1 PASSED' -ForegroundColor Green
exit 0
