# Fixture-driven producer-side event coverage for codex-dispatch.ps1.

$ErrorActionPreference = 'Stop'

$dispatch = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
$fakeCodex = Join-Path $PSScriptRoot 'dispatch-test-fakecodex.ps1'
$criticalFiles = Join-Path $PSScriptRoot 'apex-critical-files.ps1'
$treePin = Join-Path $PSScriptRoot 'tree-pin.ps1'
$schemaPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'references\orchestrator-protocol-schema.json'
foreach ($required in @($dispatch, $fakeCodex, $criticalFiles, $treePin, $schemaPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required event-test dependency not found: $required"
    }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("apex-dispatch-events-" + [guid]::NewGuid().ToString('N'))
$repo = Join-Path $testRoot 'repo'
$stateRoot = Join-Path $testRoot 'state'
$scratchRoot = Join-Path $stateRoot 'scratch'
$eventsRoot = Join-Path $stateRoot 'events'
$childScript = Join-Path $testRoot 'invoke-dispatch-event-case.ps1'
$oldStateRoot = $env:APEX_STATE_DIR
$oldFakeRepo = $env:FAKE_CODEX_REPO
$oldFakeInScope = $env:FAKE_CODEX_INSCOPE_ONLY
$oldGitConfig = $env:GIT_CONFIG_GLOBAL
$script:assertions = 0
$script:failures = 0

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $parent = Split-Path $Path -Parent
    if ($parent) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Assert-EventCase {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Condition, [string]$Detail)
    $script:assertions++
    if ($Condition) {
        Write-Host "PASS: $Name"
    }
    else {
        $script:failures++
        Write-Host "FAIL: $Name -- $Detail" -ForegroundColor Red
    }
}

function Get-ObjectPropertyNames([object]$Object) {
    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.Keys | ForEach-Object { [string]$_ })
    }
    return @($Object.PSObject.Properties.Name)
}

function Test-JsonValueType {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$ExpectedType
    )

    switch ($ExpectedType) {
        'null' { return $null -eq $Value }
        'string' { return $Value -is [string] }
        'integer' {
            return $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or
                $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or
                $Value -is [int64] -or $Value -is [uint64]
        }
        'boolean' { return $Value -is [bool] }
        'array' {
            return $Value -is [System.Collections.IList] -and $Value -isnot [string] -and
                $Value -isnot [System.Collections.IDictionary]
        }
        'object' {
            return $null -ne $Value -and
                ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject])
        }
        default { return $false }
    }
}

function Test-JsonValueEqual {
    param([AllowNull()][object]$Left, [AllowNull()][object]$Right)
    if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
    if ($Left -is [string] -and $Right -is [string]) { return $Left -ceq $Right }
    return $Left -eq $Right
}

function Test-EventSchemaNode {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][object]$Definition,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Errors
    )

    $definitionNames = @(Get-ObjectPropertyNames $Definition)
    if ($definitionNames -ccontains 'type') {
        $matchesType = $false
        foreach ($expectedType in @($Definition.type)) {
            if (Test-JsonValueType -Value $Value -ExpectedType ([string]$expectedType)) {
                $matchesType = $true
                break
            }
        }
        if (-not $matchesType) {
            $Errors.Add("$Path type expected $(@($Definition.type) -join '|')")
            return
        }
    }

    if ($definitionNames -ccontains 'enum') {
        $enumMatch = $false
        foreach ($candidate in @($Definition.enum)) {
            if (Test-JsonValueEqual -Left $Value -Right $candidate) { $enumMatch = $true; break }
        }
        if (-not $enumMatch) { $Errors.Add("$Path enum rejected '$Value'") }
    }
    if (($definitionNames -ccontains 'const') -and
            -not (Test-JsonValueEqual -Left $Value -Right $Definition.const)) {
        $Errors.Add("$Path const rejected '$Value'")
    }
    if ($Value -is [string]) {
        if (($definitionNames -ccontains 'pattern') -and $Value -cnotmatch [string]$Definition.pattern) {
            $Errors.Add("$Path pattern rejected '$Value'")
        }
        if (($definitionNames -ccontains 'minLength') -and $Value.Length -lt [int]$Definition.minLength) {
            $Errors.Add("$Path minLength rejected length $($Value.Length)")
        }
        if (($definitionNames -ccontains 'maxLength') -and $Value.Length -gt [int]$Definition.maxLength) {
            $Errors.Add("$Path maxLength rejected length $($Value.Length)")
        }
    }
    if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) {
        if (($definitionNames -ccontains 'maxItems') -and $Value.Count -gt [int]$Definition.maxItems) {
            $Errors.Add("$Path maxItems rejected count $($Value.Count)")
        }
        if ($definitionNames -ccontains 'items') {
            for ($index = 0; $index -lt $Value.Count; $index++) {
                Test-EventSchemaNode -Value $Value[$index] -Definition $Definition.items `
                    -Path "$Path[$index]" -Errors $Errors
            }
        }
    }
    if ($null -ne $Value -and
            ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject])) {
        $valueNames = @(Get-ObjectPropertyNames $Value)
        if ($definitionNames -ccontains 'required') {
            foreach ($requiredName in @($Definition.required)) {
                if ($valueNames -cnotcontains [string]$requiredName) {
                    $Errors.Add("$Path required property '$requiredName' is absent")
                }
            }
        }
        if (($definitionNames -ccontains 'additionalProperties') -and
                $Definition.additionalProperties -eq $false) {
            $allowed = if ($definitionNames -ccontains 'properties') {
                @(Get-ObjectPropertyNames $Definition.properties)
            }
            else { @() }
            foreach ($name in $valueNames) {
                if ($allowed -cnotcontains $name) { $Errors.Add("$Path additional property '$name'") }
            }
        }
        if ($definitionNames -ccontains 'properties') {
            foreach ($propertyDefinition in $Definition.properties.PSObject.Properties) {
                if ($valueNames -ccontains $propertyDefinition.Name) {
                    $propertyValue = $null
                    if ($Value -is [System.Collections.IDictionary]) {
                        $propertyValue = $Value[$propertyDefinition.Name]
                    }
                    else { $propertyValue = $Value.PSObject.Properties[$propertyDefinition.Name].Value }
                    Test-EventSchemaNode -Value $propertyValue `
                        -Definition $propertyDefinition.Value -Path "$Path.$($propertyDefinition.Name)" -Errors $Errors
                }
            }
        }
    }
}

function Test-EventAgainstSchemaDef {
    param(
        [Parameter(Mandatory)][object]$Event,
        [Parameter(Mandatory)][ValidateSet('dispatch_result', 'refusal')][string]$DefName
    )

    # This is the complete Task 8 keyword contract. Structure traversal uses properties/items;
    # validation deliberately enforces exactly these named JSON Schema keywords.
    $enforcedKeywords = @(
        'required', 'additionalProperties', 'type', 'enum', 'const', 'pattern',
        'minLength', 'maxLength', 'maxItems'
    )
    if ($enforcedKeywords.Count -ne 9) { throw 'The event schema keyword contract changed unexpectedly.' }

    # Load the selected $def for every check so the fixtures can never validate against a copied constant.
    $schema = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json
    $definition = $schema.'$defs'.$DefName
    if ($null -eq $definition) { throw "Schema definition '$DefName' was not found in $schemaPath" }

    $errors = [System.Collections.Generic.List[string]]::new()
    Test-EventSchemaNode -Value $Event -Definition $definition -Path '$' -Errors $errors

    # The refusal allOf conditionals bind run_id presence/shape to exit_code. Evaluate the
    # conditions and validate each matching then block directly from the runtime schema object.
    if ($DefName -ceq 'refusal') {
        foreach ($conditional in @($definition.allOf)) {
            $conditionErrors = [System.Collections.Generic.List[string]]::new()
            Test-EventSchemaNode -Value $Event -Definition $conditional.if -Path '$.allOf.if' `
                -Errors $conditionErrors
            if ($conditionErrors.Count -eq 0) {
                Test-EventSchemaNode -Value $Event -Definition $conditional.then -Path '$.allOf.then' `
                    -Errors $errors
            }
        }
    }

    $script:lastSchemaErrors = @($errors)
    return $errors.Count -eq 0
}

function New-ProductionRefusalFixture {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowNull()][object]$RunId,
        [Parameter(Mandatory)][string]$Detail,
        [bool]$Synthesized = $false,
        [AllowNull()][string]$Tail = $null
    )

    return [pscustomobject](New-DispatchRefusalEvent -ExitCode $ExitCode `
        -RunIdentity $RunId -Detail $Detail -Synthesized $Synthesized -Tail $Tail `
        -TaskId 'event-task' -Repo $repo)
}

function New-ProductionCompletionFinal {
    param([Parameter(Mandatory)][ValidateSet('done', 'done_with_concerns', 'blocked')][string]$Status)
    $unresolved = @()
    $blocker = $null
    if ($Status -ceq 'blocked') {
        $unresolved = @('fixture unresolved')
        $blocker = 'fixture blocker'
    }
    # Field-for-field with ConvertTo-BoundedCompletionEventFinal.
    return [pscustomobject][ordered]@{
        status = $Status
        changed_files = @('src/a.py')
        commands_run = @([pscustomobject][ordered]@{
                command = 'fixture command'; result = 'pass'; detail = $null
            })
        deviations = @()
        unresolved = $unresolved
        blocker = $blocker
    }
}

function New-ProductionDispatchResultFixture {
    param(
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][int]$ExitCode,
        [AllowNull()][object]$ReportStatus,
        [AllowNull()][object]$Final,
        [bool]$TreeMoved = $false,
        [AllowNull()][string]$Concerns = $null,
        [AllowNull()][string]$Porcelain = $null,
        [switch]$Abandon
    )

    $scopeExit = if ($Abandon) { $null } else { 0 }
    $criticalViolation = if ($Abandon) { $null } else { $false }
    Set-PendingDispatchResultEvent -TaskId 'event-task' -Repo $repo `
        -RunIdentity '0123456789abcdef0123456789abcdef' `
        -LogPath (Join-Path $stateRoot 'fixture.log') -LedgerStatus $Status `
        -ReportStatus $ReportStatus -ScopeViolation $false -ScopeExit $scopeExit `
        -EncodingViolation $false -CriticalViolation $criticalViolation -ViolationDetail $null `
        -TreeMoved $TreeMoved -Final $Final -ConcernsText $Concerns -ScopeCheckText $null `
        -PorcelainText $Porcelain -ErrorText $null -EventPhase 'build'
    if ($Abandon) {
        $script:pendingDispatchResultEvent.truncated = @(
            @($script:pendingDispatchResultEvent.truncated) +
                @('scopeViolation', 'encoding_violation', 'critical_violation', 'tree_moved') |
                Select-Object -Unique | Select-Object -First 12)
    }
    $event = [ordered]@{}
    foreach ($entry in $script:pendingDispatchResultEvent.GetEnumerator()) {
        $event[$entry.Key] = $entry.Value
    }
    $event['exit_code'] = $ExitCode
    return [pscustomobject]$event
}

function Assert-SchemaFixture {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object]$Event,
        [Parameter(Mandatory)][ValidateSet('dispatch_result', 'refusal')][string]$DefName
    )
    $valid = Test-EventAgainstSchemaDef -Event $Event -DefName $DefName
    Assert-EventCase -Name $Name -Condition $valid -Detail ($script:lastSchemaErrors -join '; ')
}

function Invoke-EventCase {
    param([Parameter(Mandatory)][ValidateSet('refusal74', 'garbage82', 'completion')][string]$Case)

    $before = if (Test-Path -LiteralPath $eventsRoot) {
        @([System.IO.Directory]::EnumerateFiles($eventsRoot, '*.event.json'))
    }
    else { @() }
    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $childScript -Case $Case 2>&1)
    $exitCode = $LASTEXITCODE
    $after = if (Test-Path -LiteralPath $eventsRoot) {
        @([System.IO.Directory]::EnumerateFiles($eventsRoot, '*.event.json'))
    }
    else { @() }
    $newFiles = @($after | Where-Object { $before -cnotcontains $_ })
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = (@($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
        Files = $newFiles
        Event = $(if ($newFiles.Count -eq 1) { Get-Content -Raw -LiteralPath $newFiles[0] | ConvertFrom-Json } else { $null })
    }
}

function Get-ProductionFunctionSource {
    param([Parameter(Mandatory)][string[]]$Names)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $dispatch, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw "Could not parse production dispatcher: $(@($parseErrors.Message) -join '; ')"
    }
    $sources = @()
    foreach ($name in $Names) {
        $functionAst = $ast.Find({
            param($node)
            return $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -ceq $name
        }, $true)
        if ($null -eq $functionAst) { throw "Production $name function was not found." }
        $sources += $functionAst.Extent.Text
    }
    return $sources -join [Environment]::NewLine
}

# Dependencies used when the production writer is loaded in isolation for collision coverage.
function Write-Utf8NoBomText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-WithLedgerLock {
    param([Parameter(Position = 0, Mandatory)][scriptblock]$Action)
    return & $Action
}

try {
    $builderSource = Get-ProductionFunctionSource -Names @(
        'ConvertTo-BoundedEventString',
        'ConvertTo-BoundedCompletionEventFinal',
        'Set-PendingDispatchResultEvent',
        'New-DispatchRefusalEvent')
    Invoke-Expression $builderSource

    [System.IO.Directory]::CreateDirectory((Join-Path $repo 'src')) | Out-Null
    [System.IO.Directory]::CreateDirectory($scratchRoot) | Out-Null
    Write-Utf8NoBom -Path (Join-Path $repo 'src\a.py') -Text "original`n"
    Write-Utf8NoBom -Path (Join-Path $repo 'AGENTS.md') -Text @'
## Verify commands

```
exit 0
```
'@
    Write-Utf8NoBom -Path (Join-Path $testRoot 'gitconfig') -Text ''
    $env:GIT_CONFIG_GLOBAL = Join-Path $testRoot 'gitconfig'
    & git -C $repo init -q
    & git -C $repo config user.email 'dispatch-events@example.invalid'
    & git -C $repo config user.name 'dispatch-events'
    & git -C $repo add -A
    & git -C $repo commit -q -m fixture
    $baseSha = ([string](& git -C $repo rev-parse HEAD)).Trim()

    $env:APEX_STATE_DIR = $stateRoot
    $env:FAKE_CODEX_REPO = $repo
    $env:FAKE_CODEX_INSCOPE_ONLY = '1'
    $env:APEX_EVENT_TEST_DISPATCH = $dispatch
    $env:APEX_EVENT_TEST_REPO = $repo
    $env:APEX_EVENT_TEST_BASE = $baseSha
    $env:APEX_EVENT_TEST_SCRATCH = $scratchRoot
    $env:APEX_EVENT_TEST_FAKE = $fakeCodex
    $env:APEX_EVENT_TEST_CRITICAL = $criticalFiles
    $env:APEX_EVENT_TEST_TREEPIN = $treePin

    Write-Utf8NoBom -Path $childScript -Text @'
param([Parameter(Mandatory)][string]$Case)
$common = @{
    Spec = 'event-smoke'; Task = 'event-task'; Worktree = $env:APEX_EVENT_TEST_REPO
    BaseSha = $env:APEX_EVENT_TEST_BASE; Phase = 'build'; Prompt = 'event smoke'
    ScratchDirectory = $env:APEX_EVENT_TEST_SCRATCH
}
switch ($Case) {
    'refusal74' { & $env:APEX_EVENT_TEST_DISPATCH @common }
    'garbage82' {
        & $env:APEX_EVENT_TEST_DISPATCH -AbandonRunId 'zzz' -AbandonReason 'event smoke' -Attended
    }
    'completion' {
        $common.Authorized = @('src/a.py')
        $common.SkipBaselineCheck = $true
        $common.CodexExecutable = 'powershell.exe'
        $common.CodexExecutableArgumentPrefix = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $env:APEX_EVENT_TEST_FAKE)
        $common.CriticalFilesScript = $env:APEX_EVENT_TEST_CRITICAL
        $common.TreePinScript = $env:APEX_EVENT_TEST_TREEPIN
        & $env:APEX_EVENT_TEST_DISPATCH @common
    }
}
exit $LASTEXITCODE
'@

    $refusal = Invoke-EventCase -Case refusal74
    Assert-EventCase -Name 'event-refusal-valid-smoke exit74' -Condition ($refusal.ExitCode -eq 74) -Detail "exit=$($refusal.ExitCode); $($refusal.Output)"
    Assert-EventCase -Name 'event-refusal-valid-smoke one file' -Condition ($refusal.Files.Count -eq 1) -Detail ($refusal.Files -join ', ')
    Assert-EventCase -Name 'event-refusal-valid-smoke event line' -Condition ($refusal.Output -match '(?m)^\[event\] .+\.event\.json$') -Detail $refusal.Output
    if ($null -ne $refusal.Event) {
        Assert-SchemaFixture -Name 'event-refusal-valid-smoke schema' -Event $refusal.Event -DefName refusal
    }

    # event-refusal-garbage-id-null-runid
    $garbage = Invoke-EventCase -Case garbage82
    Assert-EventCase -Name 'event-refusal-garbage-id-null-runid exit82' -Condition ($garbage.ExitCode -eq 82) -Detail "exit=$($garbage.ExitCode); $($garbage.Output)"
    Assert-EventCase -Name 'event-refusal-garbage-id-null-runid one file' -Condition ($garbage.Files.Count -eq 1) -Detail ($garbage.Files -join ', ')
    if ($null -ne $garbage.Event) {
        Assert-SchemaFixture -Name 'event-refusal-garbage-id-null-runid schema' -Event $garbage.Event -DefName refusal
        Assert-EventCase -Name 'event-refusal-garbage-id-null-runid real exit' -Condition ([int]$garbage.Event.exit_code -eq 82) -Detail ([string]$garbage.Event.exit_code)
        Assert-EventCase -Name 'event-refusal-garbage-id-null-runid null id' -Condition ($null -eq $garbage.Event.run_id) -Detail ([string]$garbage.Event.run_id)
        Assert-EventCase -Name 'event-refusal-garbage-id-null-runid not synthesized' -Condition (-not [bool]$garbage.Event.synthesized) -Detail ([string]$garbage.Event.synthesized)
        Assert-EventCase -Name 'event-refusal-garbage-id-null-runid raw input' -Condition ([string]$garbage.Event.detail -match "run_id 'zzz'") -Detail ([string]$garbage.Event.detail)
    }

    $completion = Invoke-EventCase -Case completion
    Assert-EventCase -Name 'event-dispatch-result-valid-smoke exit0' -Condition ($completion.ExitCode -eq 0) -Detail $completion.Output
    Assert-EventCase -Name 'event-dispatch-result-valid-smoke one file' -Condition ($completion.Files.Count -eq 1) -Detail ($completion.Files -join ', ')
    Assert-EventCase -Name 'event-dispatch-result-valid-smoke event line' -Condition ($completion.Output -match '(?m)^\[event\] .+\.event\.json$') -Detail $completion.Output
    if ($null -ne $completion.Event) {
        Assert-SchemaFixture -Name 'event-dispatch-result-valid-smoke schema' -Event $completion.Event -DefName dispatch_result
        Assert-EventCase -Name 'event-dispatch-result-valid-smoke report preserved' `
            -Condition ([string]$completion.Event.final.status -ceq 'done') -Detail ([string]$completion.Event.final.status)
    }

    # Enumerated refusal matrix: every build-phase-reachable exit plus 78's schema-only malformed-id shape.
    $refusalFixtures = @(
        [pscustomobject]@{ Name = 'event-refusal-valid-exit71'; Exit = 71; RunId = $null; Synthesized = $true; Detail = "worktree '$repo' is occupied by 1 live Codex worker(s)" },
        [pscustomobject]@{ Name = 'event-refusal-valid-exit72'; Exit = 72; RunId = $null; Synthesized = $false; Detail = '[dispatch] REFUSED (exit 72): fixture pre-flight failure.' },
        [pscustomobject]@{ Name = 'event-refusal-valid-exit74'; Exit = 74; RunId = $null; Synthesized = $false; Detail = '[dispatch] REFUSED (exit 74): -Authorized is required for build phase.' },
        [pscustomobject]@{ Name = 'event-refusal-valid-exit75'; Exit = 75; RunId = '11111111111111111111111111111111'; Synthesized = $false; Detail = '[adopt] REFUSED (exit 75): no matching run was found.' },
        [pscustomobject]@{ Name = 'event-refusal-valid-exit76'; Exit = 76; RunId = $null; Synthesized = $false; Detail = '[dispatch] REFUSED (exit 76): critical path confirmation is required.' },
        [pscustomobject]@{ Name = 'event-refusal-valid-exit79'; Exit = 79; RunId = $null; Synthesized = $false; Detail = '[dispatch] REFUSED (exit 79): invalid max_parallel_codex contract.' },
        [pscustomobject]@{ Name = 'event-refusal-valid-exit80'; Exit = 80; RunId = '22222222222222222222222222222222'; Synthesized = $false; Detail = '[dispatch] REFUSED (exit 80): unresolved sibling run blocks this worktree.' },
        [pscustomobject]@{ Name = 'event-refusal-valid-exit81'; Exit = 81; RunId = $null; Synthesized = $false; Detail = '[dispatch] REFUSED (exit 81): declared_runtime_paths entry is invalid.' },
        [pscustomobject]@{ Name = 'event-refusal-valid-exit82'; Exit = 82; RunId = '33333333333333333333333333333333'; Synthesized = $false; Detail = '[abandon] REFUSED (exit 82): run was not found.' },
        [pscustomobject]@{ Name = 'event-refusal-valid-exit83'; Exit = 83; RunId = $null; Synthesized = $false; Detail = '[abandon] REFUSED (exit 83): attended confirmation is required.' },
        [pscustomobject]@{ Name = 'event-refusal-valid-exit124'; Exit = 124; RunId = '44444444444444444444444444444444'; Synthesized = $true; Detail = "run_id '44444444444444444444444444444444' produced no output for 1 minute(s) and remains live" }
    )
    foreach ($fixture in $refusalFixtures) {
        $event = New-ProductionRefusalFixture -ExitCode $fixture.Exit -RunId $fixture.RunId `
            -Detail $fixture.Detail -Synthesized $fixture.Synthesized
        Assert-SchemaFixture -Name $fixture.Name -Event $event -DefName refusal
    }

    # Exit 78 is review-only in v1, so no production wrapper terminal can build this event yet.
    # This is the sole hand-constructed schema-shape fixture in the enumerated matrix.
    $exit78Shape = [pscustomobject][ordered]@{
        kind = 'refusal'; task_id = 'event-task'; repo = $repo; exit_code = 78; rule = $null
        detail = "[dispatch] REFUSED (exit 78): reviewed run_id 'zzz' was not found."
        synthesized = $false; tail = $null; run_id = $null; final = $null; truncated = $false
    }
    Assert-SchemaFixture -Name 'event-refusal-valid-exit78-malformed-id-schema-shape' `
        -Event $exit78Shape -DefName refusal

    # Prove that the checker enforces the conditional pattern rather than merely length/type.
    $badPattern = New-ProductionRefusalFixture -ExitCode 75 `
        -RunId 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -Detail '[adopt] REFUSED (exit 75): malformed fixture.'
    $badPatternAccepted = Test-EventAgainstSchemaDef -Event $badPattern -DefName refusal
    Assert-EventCase -Name 'event-schema-pattern-rejects-malformed-runid' `
        -Condition (-not $badPatternAccepted) -Detail '31-hex run_id unexpectedly passed the 75 conditional.'

    # Enumerated completion matrix: one fixture per producer completion status.
    foreach ($fixture in @(
            [pscustomobject]@{ Name = 'event-dispatch-result-valid-done'; Status = 'done'; Exit = 0 },
            [pscustomobject]@{ Name = 'event-dispatch-result-valid-done_with_concerns'; Status = 'done_with_concerns'; Exit = 0 },
            [pscustomobject]@{ Name = 'event-dispatch-result-valid-blocked'; Status = 'blocked'; Exit = 67 })) {
        $final = New-ProductionCompletionFinal -Status $fixture.Status
        $event = New-ProductionDispatchResultFixture -Status $fixture.Status -ExitCode $fixture.Exit `
            -ReportStatus $fixture.Status -Final $final `
            -Concerns $(if ($fixture.Status -ceq 'done_with_concerns') { 'fixture concern' } else { $null })
        Assert-SchemaFixture -Name $fixture.Name -Event $event -DefName dispatch_result
    }

    # Enumerated adoption matrix: four terminal rows plus both distinct exit-75 outcomes.
    foreach ($fixture in @(
            [pscustomobject]@{ Name = 'event-dispatch-result-valid-adopted-done'; Status = 'adopted-done'; Report = 'done'; Exit = 0; Moved = $false },
            [pscustomobject]@{ Name = 'event-dispatch-result-valid-adopted-done_with_concerns'; Status = 'adopted-done_with_concerns'; Report = 'done_with_concerns'; Exit = 0; Moved = $false },
            [pscustomobject]@{ Name = 'event-dispatch-result-valid-adopted-blocked'; Status = 'adopted-blocked'; Report = 'blocked'; Exit = 67; Moved = $false },
            [pscustomobject]@{ Name = 'event-dispatch-result-valid-adopted-void'; Status = 'adopted-void'; Report = 'done'; Exit = 69; Moved = $true })) {
        $final = New-ProductionCompletionFinal -Status $fixture.Report
        $event = New-ProductionDispatchResultFixture -Status $fixture.Status -ExitCode $fixture.Exit `
            -ReportStatus $fixture.Report -Final $final -TreeMoved $fixture.Moved `
            -Porcelain $(if ($fixture.Moved) { ' M src/a.py' } else { $null })
        Assert-SchemaFixture -Name $fixture.Name -Event $event -DefName dispatch_result
    }
    $adoptStillLive = New-ProductionRefusalFixture -ExitCode 75 `
        -RunId '55555555555555555555555555555555' -Synthesized $true `
        -Detail "run_id '55555555555555555555555555555555' remains live with status 'running' and pid 4242"
    Assert-SchemaFixture -Name 'event-refusal-valid-adopt-75-still-live' `
        -Event $adoptStillLive -DefName refusal
    $adoptAlreadyAbandoned = New-ProductionRefusalFixture -ExitCode 75 `
        -RunId '66666666666666666666666666666666' `
        -Detail "[adopt] REFUSED (exit 75): run_id '66666666666666666666666666666666' is already abandoned."
    Assert-SchemaFixture -Name 'event-refusal-valid-adopt-75-already-abandoned' `
        -Event $adoptAlreadyAbandoned -DefName refusal

    # Enumerated abandon-success emission.
    $abandonEvent = New-ProductionDispatchResultFixture -Status 'abandoned-unadopted' `
        -ExitCode 0 -ReportStatus $null -Final $null -Porcelain ' M src/a.py' -Abandon
    Assert-SchemaFixture -Name 'event-dispatch-result-valid-abandon-success' `
        -Event $abandonEvent -DefName dispatch_result

    # Load the production writer itself for filename behavior, with only its lock/text dependencies stubbed.
    $writerSource = Get-ProductionFunctionSource -Names @('Write-DispatchEvent')
    Invoke-Expression $writerSource
    $collisionFields = [ordered]@{
        kind = 'refusal'; task_id = 'event-task'; repo = $repo; exit_code = 75; rule = $null
        detail = '[adopt] REFUSED (exit 75): collision fixture.'; synthesized = $false; tail = $null
        run_id = '77777777777777777777777777777777'; final = $null; truncated = $false
    }
    $eventsDirectory = Join-Path $testRoot 'identity-collision'
    [System.IO.Directory]::CreateDirectory($eventsDirectory) | Out-Null
    $previousFiles = @()
    $createdOrder = @()
    for ($emission = 1; $emission -le 3; $emission++) {
        Write-DispatchEvent -Fields $collisionFields
        $currentFiles = @([System.IO.Directory]::EnumerateFiles($eventsDirectory, '*.event.json'))
        $newFiles = @($currentFiles | Where-Object { $previousFiles -cnotcontains $_ })
        if ($newFiles.Count -eq 1) { $createdOrder += [System.IO.Path]::GetFileName($newFiles[0]) }
        $previousFiles = $currentFiles
    }
    $expectedOrder = @(1..3 | ForEach-Object { "77777777777777777777777777777777-$_.event.json" })
    Assert-EventCase -Name 'event-filename-collision-distinct' `
        -Condition ($previousFiles.Count -eq 3 -and
            (@($createdOrder) -join '|') -ceq (@($expectedOrder) -join '|')) `
        -Detail "created=$($createdOrder -join ', ')"
    Assert-EventCase -Name 'event-filename-collision-highest-n-last' `
        -Condition ($createdOrder[-1] -ceq $expectedOrder[-1]) -Detail ($createdOrder -join ', ')

    # Instrument only the production writer's entropy sources: both calls start at the same
    # millisecond/random4, while the colliding second call's retry draws a fresh suffix.
    $fixedTimestampLine = '$timestamp = (Get-Date).ToUniversalTime().ToString(''yyyyMMddTHHmmssfffZ'')'
    $fixedTimestampReplacement = '$timestamp = ''20260802T010203004Z'''
    $randomLine = '$random4 = ([System.BitConverter]::ToString($randomBytes)).Replace(''-'', '''').ToLowerInvariant()'
    $randomReplacement = '$script:identitylessDraws++; $random4 = if ($attempt -eq 1) { ''abcd'' } else { ''ef01'' }'
    $instrumentedWriter = $writerSource.Replace(
        'function Write-DispatchEvent', 'function Write-InstrumentedDispatchEvent')
    $instrumentedWriter = $instrumentedWriter.Replace($fixedTimestampLine, $fixedTimestampReplacement)
    $instrumentedWriter = $instrumentedWriter.Replace($randomLine, $randomReplacement)
    Assert-EventCase -Name 'event-filename-identityless-instrumentation-applied' `
        -Condition ($instrumentedWriter -cnotmatch [regex]::Escape($fixedTimestampLine) -and
            $instrumentedWriter -cnotmatch [regex]::Escape($randomLine)) `
        -Detail 'Production entropy-source anchors were not both instrumented.'
    Invoke-Expression $instrumentedWriter
    $eventsDirectory = Join-Path $testRoot 'identityless-collision'
    [System.IO.Directory]::CreateDirectory($eventsDirectory) | Out-Null
    $identitylessFields = [ordered]@{
        kind = 'refusal'; task_id = 'event-task'; repo = $repo; exit_code = 74; rule = $null
        detail = '[dispatch] REFUSED (exit 74): collision fixture.'; synthesized = $false; tail = $null
        run_id = $null; final = $null; truncated = $false
    }
    $script:identitylessDraws = 0
    Write-InstrumentedDispatchEvent -Fields $identitylessFields
    $firstIdentitylessPath = Join-Path $eventsDirectory '20260802T010203004Z-74-abcd.event.json'
    $firstIdentitylessHash = if (Test-Path -LiteralPath $firstIdentitylessPath) {
        (Get-FileHash -LiteralPath $firstIdentitylessPath -Algorithm SHA256).Hash
    }
    else { $null }
    Write-InstrumentedDispatchEvent -Fields $identitylessFields
    $secondIdentitylessPath = Join-Path $eventsDirectory '20260802T010203004Z-74-ef01.event.json'
    $identitylessFiles = @([System.IO.Directory]::EnumerateFiles($eventsDirectory, '*.event.json'))
    $firstIdentitylessHashAfter = if (Test-Path -LiteralPath $firstIdentitylessPath) {
        (Get-FileHash -LiteralPath $firstIdentitylessPath -Algorithm SHA256).Hash
    }
    else { $null }
    Assert-EventCase -Name 'event-filename-identityless-collision-retry' `
        -Condition ($identitylessFiles.Count -eq 2 -and $script:identitylessDraws -eq 3 -and
            (Test-Path -LiteralPath $firstIdentitylessPath) -and
            (Test-Path -LiteralPath $secondIdentitylessPath)) `
        -Detail "files=$($identitylessFiles -join ', '); draws=$script:identitylessDraws"
    Assert-EventCase -Name 'event-filename-identityless-neither-overwritten' `
        -Condition ($null -ne $firstIdentitylessHash -and
            $firstIdentitylessHash -ceq $firstIdentitylessHashAfter) `
        -Detail "before=$firstIdentitylessHash after=$firstIdentitylessHashAfter"
}
finally {
    $env:APEX_STATE_DIR = $oldStateRoot
    $env:FAKE_CODEX_REPO = $oldFakeRepo
    $env:FAKE_CODEX_INSCOPE_ONLY = $oldFakeInScope
    $env:GIT_CONFIG_GLOBAL = $oldGitConfig
    foreach ($name in @('APEX_EVENT_TEST_DISPATCH', 'APEX_EVENT_TEST_REPO', 'APEX_EVENT_TEST_BASE',
            'APEX_EVENT_TEST_SCRATCH', 'APEX_EVENT_TEST_FAKE', 'APEX_EVENT_TEST_CRITICAL',
            'APEX_EVENT_TEST_TREEPIN')) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host "dispatch-events-test: $script:assertions assertions, $script:failures failures"
if ($script:failures -gt 0) { exit 1 }
exit 0

# COVERAGE ENUMERATION (Task 7)
# Generated after the review-fix build from codex-dispatch.ps1. This accounting lives here so the
# disposable fixture AGENTS.md Verify commands fence contains command lines only.
#
# Exit-Dispatch raw hits: 62. The definition at line 891 is not a call site; call-site count: 61.
# - 782: adopt failure dispatch_result (build in scope; review dynamically excluded).
# - 1073, 1101, 1113, 1133: abandon refusals, exit 82 (in scope).
# - 1192: abandon success dispatch_result (in scope; a review row is dynamically excluded).
# - 2073, 2079, 2085, 2108: adopt refusals, exit 75 (build in scope; review dynamically excluded).
# - 2388, 2400, 2470, 2472, 2473, 2476, 2480, 2482, 2483: adopt dispatch_result terminals
#   (build in scope; review dynamically excluded).
# - 2494: unattended abandon refusal, exit 83 (in scope).
# - 2542: post-setup caller-contract refusal, exit 74 (in scope).
# - 2654: invalid capacity-contract refusal, exit 79 (in scope).
# - 2809: duplicate lease reservation refusal, exit 72 (in scope).
# - 2878: capacity refusal, exit 79 (in scope).
# - 2891, 2897, 2915, 2919, 2926: critical-file refusals, exit 76 (in scope).
# - 2943, 2957, 2971, 2975, 2985, 2990, 2997, 3007, 3011, 3017, 3027, 3031:
#   baseline/spec pre-flight refusals, exit 72 (in scope).
# - 3038, 3096: declared-runtime-path refusals, exit 81 (in scope).
# - 3193: reviewed-build lookup refusal, exit 78 (EXCLUDED 1: every review-phase terminal).
# - 3271: malformed-ledger refusal, exit 71 (in scope).
# - 3287: live-sibling refusal, exit 71 (in scope).
# - 3307: unresolved-run refusal, exit 80 (in scope).
# - 3337, 3505: post-reservation failed dispatch_result setup terminals, exit 1 (in scope).
# - 3540: launch-boundary moved-tree dispatch_result, exit 69 (in scope).
# - 3643: stalled dispatch refusal, exit 124 (in scope).
# - 3995, 4001, 4011, 4017, 4025, 4034, 4038, 4049, 4051: build completion
#   dispatch_result terminals (in scope; the same sites are dynamically excluded for review).
# - 4057: caught launch/gate failure dispatch_result, exit 1 (in scope).
#
# Bare exit statements outside Exit-Dispatch: 14. (Its own exit at line 988 is omitted by rule.)
# - 95, 99, 103, 107, 111, 115, 119, 126, 137, 142: EXCLUDED 3, pre-state/pre-reservation
#   caller validation; no event directory or run identity exists.
# - 2488: EXCLUDED 2, -ListObligations report exit.
# - 3403, 3432, 3439: EXCLUDED 1, review-phase exit-78 terminals.
#
# Throw-pattern hits outside Exit-Dispatch: 29. Helper-local throws at lines 944 and 966 are omitted
# by rule because both take the emitter's caught best-effort failure path.
# Actual uncaught setup/infrastructure throws on process paths:
# - 347, 385, 1002, 1058: EXCLUDED 3, state-root/ledger setup or ledger-unreadable failures.
# - 1933, 1936, 1940, 2088, 2090: EXCLUDED 3, adopt selection/setup before a row is claimed.
# - 2507, 2512, 2515: EXCLUDED 3, parameter/worktree/schema setup before reservation.
# - 3369: EXCLUDED 1, read-only/review tree-pin setup.
# Caught/non-terminal throw-pattern hits (listed because the mandated Select-String also returns them):
# - 486: duplicate lease-close guard; its callers catch and report it.
# - 845, 851: event-writer collision exhaustion; caught by the writer's best-effort failure path.
# - 1534, 1544, 1549, 1626: creator-teardown internals; invoked post-terminal and caught by teardown.
# - 2641: local capacity-frontmatter parse sentinel, caught at the same site.
# - 3493: executable resolution, caught and routed through Exit-Dispatch at line 3505.
# - 3550, 3888: launch/gate failures, caught and routed through Exit-Dispatch at line 4057.
# Comment-only matches from the mechanical throw pattern (not statements): 1480, 2297, 2883, 3476, 4061.
