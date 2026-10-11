[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $env:TEMP ('apex-drain-plan-test-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($false)
$savedState = $env:APEX_STATE_DIR
$savedGlobal = $env:GIT_CONFIG_GLOBAL
$savedLocks = $env:GIT_OPTIONAL_LOCKS
$sorter = Join-Path $PSScriptRoot 'apex-drain-plan.ps1'
$assertions = 0
function Write-Utf8 {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Invoke-GitQuiet {
    param([string]$Repo, [string[]]$Arguments)
    $savedEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $Repo @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedEap }
    if ($code -ne 0) { throw ('git failed: ' + ($output -join ' | ')) }
    return ,$output
}

function New-TestRepo {
    $path = Join-Path $testRoot ('repo-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $path -Force)
    [void](Invoke-GitQuiet -Repo $path -Arguments @('init', '-q'))
    Write-Utf8 -Path (Join-Path $path 'AGENTS.md') -Text (@(
        '# Test repository'
        ''
        '## Verify commands'
        ''
        '```'
        'node --check exact-one.js'
        'powershell.exe -NoProfile -File exact-two.ps1'
        '```'
        ''
        '## Preflight commands'
        ''
        '```'
        'node --check exact-one.js'
        '```'
    ) -join "`n")
    return $path
}

function Set-TestCommit {
    param([string]$Repo, [string[]]$Paths)
    foreach ($relative in $Paths) {
        $full = Join-Path $Repo ($relative.Replace('/', [char]92))
        $hash = (Invoke-GitQuiet -Repo $Repo -Arguments @('hash-object', '-w', '--', $full))[-1]
        [void](Invoke-GitQuiet -Repo $Repo -Arguments @('update-index', '--add', '--cacheinfo', ('100644,{0},{1}' -f $hash, $relative)))
    }
    $tree = (Invoke-GitQuiet -Repo $Repo -Arguments @('write-tree'))[-1]
    $oldEmail = $env:GIT_AUTHOR_EMAIL
    $oldName = $env:GIT_AUTHOR_NAME
    $oldCommitterEmail = $env:GIT_COMMITTER_EMAIL
    $oldCommitterName = $env:GIT_COMMITTER_NAME
    try {
        $env:GIT_AUTHOR_EMAIL = 'fixture@example.invalid'
        $env:GIT_AUTHOR_NAME = 'Fixture'
        $env:GIT_COMMITTER_EMAIL = 'fixture@example.invalid'
        $env:GIT_COMMITTER_NAME = 'Fixture'
        $savedEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $commit = @('fixture' | & git -C $Repo commit-tree $tree 2>&1 | ForEach-Object { $_.ToString() })[-1]
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $savedEap }
        if ($code -ne 0) { throw 'git commit-tree failed' }
        [void](Invoke-GitQuiet -Repo $Repo -Arguments @('update-ref', 'HEAD', $commit))
    }
    finally {
        $env:GIT_AUTHOR_EMAIL = $oldEmail
        $env:GIT_AUTHOR_NAME = $oldName
        $env:GIT_COMMITTER_EMAIL = $oldCommitterEmail
        $env:GIT_COMMITTER_NAME = $oldCommitterName
    }
}

function ConvertTo-ForwardPath {
    param([string]$Path)
    return ([System.IO.Path]::GetFullPath($Path)).Replace([char]92, [char]47).TrimEnd('/')
}

function New-ManifestJson {
    param(
        [string]$Repo,
        [object[]]$Tasks,
        [switch]$TwoRepos,
        [string]$RepoOverride
    )
    $root = ConvertTo-ForwardPath -Path $Repo
    if (-not [string]::IsNullOrEmpty($RepoOverride)) { $root = $RepoOverride }
    $repos = [ordered]@{ main = $root }
    if ($TwoRepos) { $repos['other'] = $root }
    return ([ordered]@{ version = 1; repos = $repos; tasks = @($Tasks) } | ConvertTo-Json -Depth 10)
}

function New-Task {
    param([string]$Id, [object[]]$Files, [string[]]$Depends = @(), [string]$Effort)
    $task = [ordered]@{ id = $Id; repo = 'main'; files = @($Files); depends_on = @($Depends) }
    if (-not [string]::IsNullOrEmpty($Effort)) { $task['effort'] = $Effort }
    return [pscustomobject]$task
}

function New-File {
    param([string]$Path, [string]$Op = 'create')
    return [pscustomobject][ordered]@{ path = $Path; op = $Op }
}

function New-SpecText {
    param(
        [string]$Name,
        [string]$Manifest,
        [object[]]$Tasks,
        [string]$Risk = 'medium',
        [string]$CoderModel,
        [string]$CoderEffort = 'medium',
        [object]$MaxParallelCodex = $null,
        [string]$Intent = '- **Intent:** Build the fixture.',
        [string]$Assumptions = '- The fixture environment is available.',
        [string]$Specialist = "### Security`nKeep fixture writes scoped.`n`n### Accessibility`n(none)",
        [string]$TaskLabelSeparator = '-',
        [string]$TaskFieldSeparator,
        [switch]$NoSpec,
        [switch]$OmitRisk,
        [string]$SpecIdentity,
        [switch]$NoManifest,
        [switch]$DuplicateManifest
    )
    $front = New-Object 'System.Collections.Generic.List[string]'
    [void]$front.Add('---')
    if (-not $NoSpec) {
        if ([string]::IsNullOrEmpty($SpecIdentity)) { $SpecIdentity = $Name }
        [void]$front.Add('spec: ' + $SpecIdentity)
    }
    if (-not $OmitRisk -and $null -ne $Risk) { [void]$front.Add('risk: ' + $Risk) }
    if (-not [string]::IsNullOrEmpty($CoderModel)) { [void]$front.Add('coder_model: ' + $CoderModel) }
    if ($null -ne $CoderEffort) { [void]$front.Add('coder_effort: ' + $CoderEffort) }
    if ($null -ne $MaxParallelCodex) { [void]$front.Add('max_parallel_codex: ' + $MaxParallelCodex) }
    [void]$front.Add('---')

    $fileRows = New-Object 'System.Collections.Generic.List[string]'
    $taskRows = New-Object 'System.Collections.Generic.List[string]'
    $acceptanceRows = New-Object 'System.Collections.Generic.List[string]'
    $emDash = [string][char]0x2014
    if ([string]::IsNullOrEmpty($TaskFieldSeparator)) { $TaskFieldSeparator = $emDash }
    foreach ($task in $Tasks) {
        foreach ($file in @($task.files)) { [void]$fileRows.Add('| ' + $file.path + ' | ' + $file.op + ' | fixture |') }
        $paths = @($task.files | ForEach-Object { $_.path }) -join ', '
        [void]$taskRows.Add(('- [ ] **Task {0}** {1} Implement task {0} exactly. {2} files: {3} {2} done when: task {0} is complete.' -f $task.id, $TaskLabelSeparator, $TaskFieldSeparator, $paths))
        [void]$acceptanceRows.Add(('- [ ] Task {0} - task {0} is executable -> verify: run the fixture command.' -f $task.id))
    }
    $manifestBlock = ''
    if (-not $NoManifest) {
        $fence = (([string][char]96) * 3) -join ''
        $manifestBlock = $fence + "json apex-manifest`n$Manifest`n" + $fence
        if ($DuplicateManifest) { $manifestBlock += "`n`n" + $fence + "json apex-manifest`n$Manifest`n" + $fence }
    }
    return ((@($front.ToArray()) + @(
        '',
        '# Planner fixture',
        '',
        ('**Identity:** Fixture identity for ' + $Name + '.'),
        '',
        '## Intent',
        $Intent,
        '',
        '## Assumptions',
        $Assumptions,
        '',
        '## Prerequisites',
        'none',
        '',
        '## Files to Change',
        '| File | Operation | Notes |',
        '|---|---|---|',
        ($fileRows.ToArray() -join "`n"),
        '',
        '## Execution manifest',
        $manifestBlock,
        '',
        '## Tasks',
        ($taskRows.ToArray() -join "`n"),
        '',
        '## Wave plan',
        'This prose is deliberately non-authoritative.',
        '',
        '## Permissions',
        '- The fixture paths may be changed.',
        '',
        '## Specialist Context',
        $Specialist,
        '',
        '## Documentation',
        '- No documentation changes are required.',
        '',
        '## Acceptance Criteria',
        ($acceptanceRows.ToArray() -join "`n"),
        '',
        '## Progress',
        '- Not started.'
    )) -join "`n") + "`n"
}

function New-Fixture {
    param(
        [string]$Name = 'fixture-plan',
        [object[]]$Tasks,
        [hashtable]$SpecOptions = @{},
        [switch]$TwoRepos,
        [string]$RepoOverride
    )
    $repo = New-TestRepo
    if ($null -eq $Tasks) { $Tasks = @(New-Task -Id '1' -Files @(New-File -Path 'src/new.txt')) }
    $manifest = New-ManifestJson -Repo $repo -Tasks $Tasks -TwoRepos:$TwoRepos -RepoOverride $RepoOverride
    $textArgs = @{ Name = $Name; Manifest = $manifest; Tasks = $Tasks }
    foreach ($key in $SpecOptions.Keys) { $textArgs[$key] = $SpecOptions[$key] }
    $specDir = Join-Path $testRoot ('spec-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $specDir -Force)
    $spec = Join-Path $specDir ($Name + '.md')
    Write-Utf8 -Path $spec -Text (New-SpecText @textArgs)
    return [pscustomobject]@{ Repo = $repo; Spec = $spec; Tasks = $Tasks; Manifest = $manifest }
}

function Assert($Condition, [string]$Message) {
    $script:assertions++
    if (-not $Condition) { throw ('assertion failed: ' + $Message) }
}
function New-Project {
    $project = Join-Path $testRoot ('project-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path (Join-Path $project 'docs/changes/done') -Force)
    return $project
}
function Add-Queued {
    param([string]$Project, [string]$Name, [string[]]$Prerequisites = @(),
        [hashtable]$Options = @{}, [string]$Path = 'src/new.txt', [string]$Title,
        [switch]$Unborn, [object[]]$Tasks)
    $fixture = New-Fixture -Name $Name -SpecOptions $Options -Tasks $Tasks
    if (-not $Unborn) { Set-TestCommit -Repo $fixture.Repo -Paths @('AGENTS.md') }
    if ($null -eq $Tasks -and $Path -ne 'src/new.txt') {
        $fixture.Tasks = @(New-Task -Id '1' -Files @(New-File -Path $Path))
        $fixture.Manifest = New-ManifestJson -Repo $fixture.Repo -Tasks $fixture.Tasks
        $args = @{ Name = $Name; Manifest = $fixture.Manifest; Tasks = $fixture.Tasks }
        foreach ($key in $Options.Keys) { $args[$key] = $Options[$key] }
        Write-Utf8 $fixture.Spec (New-SpecText @args)
    }
    $text = [IO.File]::ReadAllText($fixture.Spec)
    $prereq = 'none'
    if ($Prerequisites.Count) { $prereq = @($Prerequisites | ForEach-Object { '- `' + $_ + '`' }) -join "`n" }
    $text = $text.Replace("## Prerequisites`nnone", "## Prerequisites`n$prereq")
    if ($Title) { $text = $text.Replace('**Task 1**', ('**' + $Title + '**')) }
    $destination = Join-Path $Project ('docs/changes/' + $Name + '.md')
    Write-Utf8 $destination $text
    $fixture.Spec = $destination
    return $fixture
}
function Get-Snapshot {
    # Includes all .git files, especially index, as well as queued project files.
    $snapshot = @{}
    foreach ($file in Get-ChildItem -LiteralPath $testRoot -Recurse -Force -File) {
        $snapshot[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $snapshot
}
function Invoke-Drain {
    param([string]$Project, [string]$Script = $sorter, [switch]$Text, [switch]$Failure, [switch]$AsciiJson)
    $before = Get-Snapshot
    $oldEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $arguments = @('-NoProfile', '-File', $Script, '-Project', $Project)
        if (-not $Text) { $arguments += '-Json' }
        # Keep the child's default console encoding to exercise host code pages.
        $output = @(& powershell.exe @arguments 2>&1 | ForEach-Object { $_.ToString() })
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldEap }
    $after = Get-Snapshot
    Assert ($before.Count -eq $after.Count) 'sorter creates/deletes no fixture files'
    foreach ($key in $before.Keys) { Assert ($before[$key] -ceq $after[$key]) ('unchanged fixture bytes: ' + $key) }
    if ($Failure) { Assert ($code -eq 1 -and ($output -join '').Length -gt 0) 'input failure exits 1 with message'; return }
    Assert ($code -eq 0) ('sorter exit zero: ' + ($output -join ' | '))
    if ($Text) { return ($output -join "`n") }
    $rawJson = $output -join "`n"
    if ($AsciiJson) { Assert ($rawJson -notmatch '[^\x00-\x7e]') 'raw JSON contains only ASCII code units' }
    $report = $rawJson | ConvertFrom-Json
    Assert ($report.schema_version -eq 1) 'schema version'
    Assert ($report.project -eq [IO.Path]::GetFullPath($Project)) 'project path'
    Assert ($report.generated_at -match 'Z$') 'UTC timestamp'
    Assert ($report.will_build -is [Array] -and $report.needs_you -is [Array]) 'JSON list shape'
    foreach ($entry in $report.will_build) {
        Assert (($entry.PSObject.Properties.Name -join ',') -ceq 'order,spec,path,repo,risk,digest,prerequisites,host_work') 'will-build shape'
        Assert ($entry.digest -match '^[a-f0-9]{64}$') 'plan digest retained'
    }
    foreach ($entry in $report.needs_you) {
        Assert (($entry.PSObject.Properties.Name -join ',') -ceq 'spec,path,reason_code,reason,blocked_by') 'needs-you shape without digest'
        Assert (-not [string]::IsNullOrEmpty($entry.reason)) 'human refusal reason'
    }
    return $report
}
function Expect-Reason($Report, [string]$Name, [string]$Code, $Blocker = $null, [string]$ReasonPattern) {
    $entry = @($Report.needs_you | Where-Object { $_.spec -ceq $Name })
    Assert ($entry.Count -eq 1) ('one refusal for ' + $Name)
    Assert ($entry[0].reason_code -ceq $Code) ($Name + ' reason: ' + $entry[0].reason)
    Assert ($entry[0].blocked_by -ceq $Blocker) ($Name + ' blocker: ' + $entry[0].blocked_by)
    if ($ReasonPattern) { Assert ($entry[0].reason -match $ReasonPattern) ($Name + ' specific reason: ' + $entry[0].reason) }
}

try {
    [void](New-Item -ItemType Directory -Path $testRoot)
    $env:APEX_STATE_DIR = Join-Path $testRoot 'state'
    $env:GIT_CONFIG_GLOBAL = Join-Path $testRoot 'empty-gitconfig'
    Write-Utf8 $env:GIT_CONFIG_GLOBAL ''
    $env:GIT_OPTIONAL_LOCKS = 'false'
    $project = New-Project
    $empty = Invoke-Drain $project
    Assert ($empty.will_build.Count -eq 0 -and $empty.needs_you.Count -eq 0) 'empty queue'
    $text = Invoke-Drain $project -Text
    Assert ($text -ceq "WILL BUILD`nNEEDS YOU") 'empty text sections'
    Invoke-Drain 'relative' -Failure
    Invoke-Drain (Join-Path $testRoot 'missing') -Failure
    Invoke-Drain $testRoot -Failure
    Invoke-Drain 'C:relative' -Failure
    Write-Output 'PASS: empty queue and input failures'

    # Preplanner failures, with readable identity retained and unreadable fallback.
    $cases = @(
        @{ Name = 'no-manifest'; Options = @{ NoManifest = $true }; Pattern = 'manifest' },
        @{ Name = 'duplicate-manifest'; Options = @{ DuplicateManifest = $true }; Pattern = 'manifest' },
        @{ Name = 'no-spec'; Options = @{ NoSpec = $true }; Pattern = 'frontmatter' },
        @{ Name = 'empty-spec'; Options = @{ SpecIdentity = '""' }; Pattern = 'frontmatter spec identity is empty' },
        @{ Name = 'unborn'; Unborn = $true; Pattern = 'build repository has no commit' }
    )
    foreach ($case in $cases) { [void](Add-Queued $project $case.Name -Options $case.Options -Unborn:([bool]$case.Unborn)) }
    [void](Add-Queued $project 'engine-first' -Options @{NoManifest=$true; Risk='high'} -Prerequisites @('absent'))
    foreach ($name in @('bad-json','zero-repos','several-repos','no-front','open-front','bad-utf8','utf16','missing-repo','not-git','subdir','dirty','identity','duplicate-spec')) {
        $f = Add-Queued $project $name
        $body = [IO.File]::ReadAllText($f.Spec)
        switch ($name) {
            'bad-json' { $body = $body.Replace($f.Manifest, '{ nope }') }
            'zero-repos' { $m = $f.Manifest | ConvertFrom-Json; $m.repos = [pscustomobject]@{}; $body = $body.Replace($f.Manifest, ($m | ConvertTo-Json -Depth 10)) }
            'several-repos' { $body = $body.Replace($f.Manifest, (New-ManifestJson $f.Repo $f.Tasks -TwoRepos)) }
            'no-front' { $body = $body.Substring(4) }
            'open-front' { $body = $body.Replace("`n---`n", "`n") }
            'bad-utf8' { [IO.File]::WriteAllBytes($f.Spec, [byte[]]@(255,254,255)); $body = $null }
            'utf16' { [IO.File]::WriteAllText($f.Spec,$body,[Text.Encoding]::Unicode); $body = $null }
            'missing-repo' { $body = $body.Replace((ConvertTo-ForwardPath $f.Repo), (ConvertTo-ForwardPath (Join-Path $testRoot 'missing-build'))) }
            'not-git' { $p = Join-Path $testRoot 'plain'; [void](New-Item -ItemType Directory $p); $body = $body.Replace((ConvertTo-ForwardPath $f.Repo), (ConvertTo-ForwardPath $p)) }
            'subdir' { $p = Join-Path $f.Repo 'sub'; [void](New-Item -ItemType Directory $p); $body = $body.Replace((ConvertTo-ForwardPath $f.Repo), (ConvertTo-ForwardPath $p)) }
            'dirty' {
                Write-Utf8 (Join-Path $f.Repo 'src/new.txt') 'tracked'
                Set-TestCommit $f.Repo @('src/new.txt')
                Write-Utf8 (Join-Path $f.Repo 'src/new.txt') 'dirty'
                $body = $body.Replace('"create"','"modify"').Replace('| create |','| modify |')
            }
            'identity' { $body = $body.Replace('spec: identity', 'spec: readable-name') }
            'duplicate-spec' { $body = $body.Replace('spec: duplicate-spec', "spec: duplicate-spec`nspec: other") }
        }
        if ($null -ne $body) { Write-Utf8 $f.Spec $body }
    }
    $report = Invoke-Drain $project
    foreach ($case in $cases) { Expect-Reason $report $case.Name 'engine-refused' -ReasonPattern $case.Pattern }
    Expect-Reason $report 'engine-first' 'engine-refused' -ReasonPattern 'manifest'
    foreach ($pair in @(
        @('bad-json','JSON'), @('zero-repos','one repo key'), @('several-repos','one repo key'),
        @('no-front','frontmatter'), @('open-front','frontmatter'), @('bad-utf8','UTF-8'), @('utf16','UTF-8|frontmatter'),
        @('missing-repo','absolute and existing'), @('not-git','Git worktree'), @('subdir','worktree root'),
        @('dirty','dirty'), @('readable-name','filename'), @('duplicate-spec','duplicated'))) {
        Expect-Reason $report $pair[0] 'engine-refused' -ReasonPattern $pair[1]
    }
    Write-Output 'PASS: preplanner and planner refusals'

    $project = New-Project
    [void](Add-Queued $project 'high' -Options @{Risk='high'} -Path 'docs/audit/new.md' -Prerequisites @('missing'))
    [void](Add-Queued $project 'hard' -Path 'docs/audit/new.md' -Prerequisites @('missing'))
    [void](Add-Queued $project 'hard-before-critical' -Tasks @(New-Task '1' @(New-File 'docs/audit/new.md'; New-File 'package.json')))
    [void](Add-Queued $project 'critical' -Path 'package.json' -Prerequisites @('missing'))
    $f = Add-Queued $project 'parse' -Prerequisites @('missing')
    Write-Utf8 $f.Spec ([IO.File]::ReadAllText($f.Spec).Replace('- `missing`', "- `missing``ninvalid"))
    [void](Add-Queued $project 'missing' -Prerequisites @('absent'))
    [void](Add-Queued $project 'z' -Options @{Risk='high'})
    [void](Add-Queued $project 'b' -Prerequisites @('z'))
    [void](Add-Queued $project 'c' -Options @{Risk='high'})
    [void](Add-Queued $project 'd' -Prerequisites @('b','c'))
    [void](Add-Queued $project 'transitive' -Prerequisites @('b'))
    [void](Add-Queued $project 'cycle-a' -Prerequisites @('cycle-b','z'))
    [void](Add-Queued $project 'cycle-b' -Prerequisites @('cycle-a'))
    [void](Add-Queued $project 'self' -Prerequisites @('self'))
    [void](Add-Queued $project 'x-a' -Prerequisites @('x-b'))
    [void](Add-Queued $project 'x-b' -Prerequisites @('x-a'))
    [void](Add-Queued $project 'y-a' -Prerequisites @('y-b'))
    [void](Add-Queued $project 'y-b' -Prerequisites @('y-a'))
    [void](Add-Queued $project 'cycles-dependent' -Prerequisites @('y-a','x-b'))
    [void](Add-Queued $project 'cycle-with-root-dependent' -Prerequisites @('cycle-a'))
    $hostTitles = @('Task 2 (HOST) followed by more title text', 'Task 2 OWNER-run', 'Task 2 (critical, OWNER-run)')
    for ($i=0; $i -lt $hostTitles.Count; $i++) {
        $f = Add-Queued $project ('host-' + $i)
        # Host work is deliberately outside the execution manifest, as required
        # by the live validator; the ordinary Task 1 remains buildable.
        $body = [IO.File]::ReadAllText($f.Spec)
        $body = $body.Replace('## Wave plan', ('- [ ] **' + $hostTitles[$i] + '** - files: `host/bookkeeping.md` - Record bookkeeping.' + "`n`n## Wave plan"))
        $body = $body.Replace('| src/new.txt | create | fixture |', "| src/new.txt | create | fixture |`n| host/bookkeeping.md | modify | host |")
        $body = $body.Replace('## Progress', "- [ ] Task 2: host/bookkeeping.md is updated.`n`n## Progress")
        Write-Utf8 $f.Spec $body
        [void](Add-Queued $project ('host-dependent-' + $i) -Prerequisites @('host-' + $i))
    }
    $f = Add-Queued $project 'body-host'
    Write-Utf8 $f.Spec ([IO.File]::ReadAllText($f.Spec).Replace('Implement task 1 exactly.', 'Implement task 1 exactly. (HOST) OWNER'))
    [void](Add-Queued $project 'done-satisfied' -Prerequisites @('finished'))
    Write-Utf8 (Join-Path $project 'docs/changes/done/finished.md') 'done'
    $f = Add-Queued $project 'comments'
    Write-Utf8 $f.Spec ([IO.File]::ReadAllText($f.Spec).Replace("## Prerequisites`nnone", "## Prerequisites`n<!-- ignored`n- nonsense`n-->`nNone"))
    [void](Add-Queued $project 'tie-2')
    [void](Add-Queued $project 'tie-10')
    [void](Add-Queued $project 'after-tie' -Prerequisites @('tie-2','tie-10'))
    $report = Invoke-Drain $project
    foreach ($pair in @(@('high','risk-high'),@('hard','hard-block'),@('critical','critical-file'),@('parse','prerequisites-unparseable'),@('missing','prerequisite-missing'))) { Expect-Reason $report $pair[0] $pair[1] }
    Expect-Reason $report 'hard-before-critical' 'hard-block'
    Expect-Reason $report 'b' 'prerequisite-blocked' 'z'
    Expect-Reason $report 'd' 'prerequisite-blocked' 'c'
    Expect-Reason $report 'transitive' 'prerequisite-blocked' 'z'
    foreach ($name in @('cycle-a','cycle-b','self','x-a','x-b','y-a','y-b')) { Expect-Reason $report $name 'dependency-cycle' }
    Expect-Reason $report 'cycles-dependent' 'prerequisite-blocked' 'x-a'
    Expect-Reason $report 'cycle-with-root-dependent' 'prerequisite-blocked' 'z'
    for ($i=0; $i -lt 3; $i++) {
        Assert (@($report.will_build | Where-Object { $_.spec -eq ('host-' + $i) -and $_.host_work }).Count -eq 1) ('HOST/OWNER title preserved on WILL BUILD: host-' + $i + ' ' + ($report.needs_you | Where-Object spec -eq ('host-' + $i) | ConvertTo-Json -Compress))
        Expect-Reason $report ('host-dependent-' + $i) 'prerequisite-blocked' ('host-' + $i)
    }
    Assert (-not ($report.will_build | Where-Object spec -eq 'body-host').host_work) 'body prose does not set host_work'
    Assert (@($report.will_build | Where-Object spec -eq 'done-satisfied').Count -eq 1) 'done prerequisite satisfied'
    Assert (@($report.will_build | Where-Object spec -eq 'finished').Count -eq 0) 'done files excluded from queue'
    $ordered = @($report.will_build.spec)
    Assert ([Array]::IndexOf($ordered,'tie-10') -lt [Array]::IndexOf($ordered,'tie-2')) 'ordinal filename ties'
    Assert ([Array]::IndexOf($ordered,'after-tie') -gt [Array]::IndexOf($ordered,'tie-2')) 'prerequisite before dependent'
    $text = Invoke-Drain $project -Text
    Assert ($text -match 'WILL BUILD' -and $text -match 'NEEDS YOU' -and $text -match 'repo=.*risk=.*host_work=' -and $text -match 'risk-high') 'text report fields'
    Write-Output 'PASS: precedence, graph blockers, cycles, titles and order'

    $project = New-Project
    # Put an em dash in the emitted case path as well as its prerequisite text.
    $project = Join-Path $project ('em-dash-' + [char]0x2014)
    Write-Utf8 (Join-Path $project 'docs/changes/done/finished.md') 'done'
    $mojibakeDash = [string][char]0xE2 + [char]0x20AC + [char]0x201D
    $prerequisiteCases = @(
        @{Name='none-lower'; Body='none'; Allowed=$true},
        @{Name='none-upper'; Body='None'; Allowed=$true},
        @{Name='none-parens'; Body='(none)'; Allowed=$true},
        @{Name='missing-section'; Body=$null; Allowed=$false; EngineRefused=$true},
        @{Name='annotated'; Body='- `finished` - explanatory text'; Allowed=$true},
        @{Name='em-dash'; Body=('- `finished` ' + [char]0x2014 + ' explanatory text'); Allowed=$true},
        @{Name='mojibake'; Body=('- `finished` ' + $mojibakeDash + ' explanatory text'); Allowed=$false},
        @{Name='blank-section'; Body=''; Allowed=$false},
        @{Name='uppercase-none'; Body='NONE'; Allowed=$false},
        @{Name='mixed-none'; Body="none`n- ``finished``"; Allowed=$false},
        @{Name='unquoted'; Body='- finished'; Allowed=$false},
        @{Name='invalid-name'; Body='- `Finished`'; Allowed=$false},
        @{Name='trailing'; Body='- `finished` extra'; Allowed=$false}
    )
    foreach ($case in $prerequisiteCases) {
        $f = Add-Queued $project $case.Name
        $body = [IO.File]::ReadAllText($f.Spec)
        if ($null -eq $case.Body) { $body = $body.Replace("## Prerequisites`nnone`n", '') }
        else { $body = $body.Replace("## Prerequisites`nnone", ("## Prerequisites`n" + $case.Body)) }
        Write-Utf8 $f.Spec $body
    }
    $f = Add-Queued $project 'fenced-host'
    $fence = [string][char]96 * 3
    Write-Utf8 $f.Spec ([IO.File]::ReadAllText($f.Spec).Replace('## Tasks', ("## Tasks`n$fence" + "text`n- [ ] **Task 9 (HOST)**`n$fence")))
    [void](Add-Queued $project 'lowercase-owner' -Title 'Task 1 owner-run')
    [void](Add-Queued $project 'owner-substring' -Title 'Task 1 HOMEOWNER')
    $report = Invoke-Drain $project -AsciiJson
    $mojibakeReason = ($report.needs_you | Where-Object spec -eq 'mojibake').reason
    Assert ($mojibakeReason.Contains([string][char]0x201D)) 'mojibake reason retains original right double quotation mark'
    Assert ($mojibakeReason -ceq ('cannot parse prerequisite: ' + ($prerequisiteCases | Where-Object Name -eq 'mojibake').Body)) 'mojibake reason round-trips exactly'
    Assert (($report.will_build | Where-Object spec -eq 'em-dash').path -ceq (Join-Path $project 'docs/changes/em-dash.md')) 'em-dash case path round-trips exactly'
    foreach ($case in $prerequisiteCases) {
        if ($case.Allowed) { Assert (@($report.will_build | Where-Object spec -eq $case.Name).Count -eq 1) ($case.Name + ' grammar allowed') }
        elseif ($case.EngineRefused) { Expect-Reason $report $case.Name 'engine-refused' -ReasonPattern 'missing heading' }
        else { Expect-Reason $report $case.Name 'prerequisites-unparseable' }
    }
    foreach ($name in @('fenced-host','lowercase-owner','owner-substring')) { Assert (-not ($report.will_build | Where-Object spec -eq $name).host_work) ($name + ' no host marker') }
    Write-Output 'PASS: prerequisite grammar and fenced title exclusions'

    $project = New-Project
    $tasks = @(New-Task '1' @(New-File 'src/ultra.txt') -Effort 'ultra'; New-Task '2' @(New-File 'src/ordinary.txt'))
    $f = Add-Queued $project 'capacity-one' -Tasks $tasks -Options @{MaxParallelCodex=1}
    . (Join-Path $PSScriptRoot 'engine-plan.ps1')
    $probe = Get-EnginePlan $f.Spec $f.Repo 4
    $final = Get-EnginePlan $f.Spec $f.Repo 1
    Assert ($probe.allowed -and -not $final.allowed) ('probe/replan fixture actually distinguishes ceilings: probe=' + $probe.refusal + '; final=' + $final.refusal)
    $report = Invoke-Drain $project
    Expect-Reason $report 'capacity-one' 'engine-refused' -ReasonPattern 'weight exceeds MaxParallel'
    $f = Add-Queued $project 'capacity-two' -Tasks $tasks -Options @{MaxParallelCodex=2}
    $report = Invoke-Drain $project
    $expected = Get-EnginePlan $f.Spec $f.Repo 2
    Assert (($report.will_build | Where-Object spec -eq 'capacity-two').digest -ceq $expected.spec.digest) 'final plan digest parity'
    Write-Output 'PASS: probe/replan parity'

    # Entire sibling layout is copied; only the classifier is removed/replaced.
    $skill = Join-Path $testRoot 'copied-skill'
    [void](New-Item -ItemType Directory $skill)
    Copy-Item -LiteralPath $PSScriptRoot -Destination (Join-Path $skill 'scripts') -Recurse
    Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'references') -Destination (Join-Path $skill 'references') -Recurse
    $copied = Join-Path $skill 'scripts/apex-drain-plan.ps1'
    $classifier = Join-Path $skill 'scripts/apex-critical-files.ps1'
    Remove-Item -LiteralPath $classifier
    $project = New-Project
    [void](Add-Queued $project 'classifier-missing' -Prerequisites @('absent'))
    $report = Invoke-Drain $project -Script $copied
    Expect-Reason $report 'classifier-missing' 'classifier-error' -ReasonPattern 'missing'
    Write-Utf8 $classifier "Write-Output 'classifier fixture exploded'; exit 23"
    $report = Invoke-Drain $project -Script $copied
    Expect-Reason $report 'classifier-missing' 'classifier-error' -ReasonPattern 'classifier fixture exploded'
    Assert ($env:GIT_OPTIONAL_LOCKS -ceq 'false') 'parent locks environment preserved'
    # Invoke in-process too: child process checks alone cannot prove finally restoration.
    $inProcess = @(& $sorter -Project $project -Json) -join "`n"
    Assert ($env:GIT_OPTIONAL_LOCKS -ceq 'false') 'in-process locks restored'
    $ignored = @(& $sorter -Project 'relative' -Json)
    Assert ($LASTEXITCODE -eq 1 -and $env:GIT_OPTIONAL_LOCKS -ceq 'false') 'failure restores in-process locks'
    $env:GIT_OPTIONAL_LOCKS = $null
    $inProcess = @(& $sorter -Project $project -Json) -join "`n"
    Assert ($null -eq [Environment]::GetEnvironmentVariable('GIT_OPTIONAL_LOCKS','Process')) 'absent locks restored'
    Write-Output ('PASS: {0} assertions' -f $assertions)
}
finally {
    $env:APEX_STATE_DIR = $savedState
    $env:GIT_CONFIG_GLOBAL = $savedGlobal
    $env:GIT_OPTIONAL_LOCKS = $savedLocks
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe test cleanup path' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

