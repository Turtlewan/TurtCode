# Does the dispatcher route on the CODER'S REPORT, or on the exit code?
#
# The real Codex exits 0 while its own `.final` says `"status": "blocked"`. On cap-deps-1b
# (2026-07-14) that unread `blocked` -- "the sandbox can no longer launch helpers, so implementation
# cannot be inspected, corrected, or verified" -- was committed, and the next spec was built on top
# of it. Every case below exits the fake coder with 0. Only the report differs.

try {
    # Keep mutex-guarded fixture rows off the live run ledger.
    $stateRoot = Join-Path $env:TEMP ("apex-verdict-state-" + [guid]::NewGuid().ToString('N'))
    $oldApexStateDir = $env:APEX_STATE_DIR
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    $progressRoot = Join-Path $stateRoot 'progress'
    New-Item -ItemType Directory -Force -Path $progressRoot | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $progressRoot 'codex-run-ledger.jsonl') | Out-Null
    $env:APEX_STATE_DIR = $stateRoot
    $oldGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
    $oldXdgConfigHome = $env:XDG_CONFIG_HOME
    $testGitConfig = Join-Path $stateRoot 'gitconfig'
    New-Item -ItemType File -Force -Path $testGitConfig | Out-Null
    $env:GIT_CONFIG_GLOBAL = $testGitConfig
    $env:XDG_CONFIG_HOME = $stateRoot

    $ErrorActionPreference = 'Stop'

    $fakeCodex = Join-Path $PSScriptRoot 'dispatch-test-fakecodex.ps1'
    $dispatch = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
    $root = Join-Path $env:TEMP 'apex-verdict-test'

    $emptyConcernBlockerText = 'Coder reported done_with_concerns and named no unresolved item. Either report done, or name a concern.'

    # status | no-report | unresolved override | expected dispatcher exit | what it means
    $cases = @(
        @{ Name = 'done'; Status = 'done'; NoReport = $false; Expect = 0; Means = 'clean pass' }
        @{ Name = 'blocked'; Status = 'blocked'; NoReport = $false; Expect = 67; Means = 'HARD STOP (cap-deps-1b)' }
        @{ Name = 'concern'; Status = 'done_with_concerns'; NoReport = $false; Expect = 68; Means = 'finished, flagged doubts' }
        @{ Name = 'no-report'; Status = 'done'; NoReport = $true; Expect = 67; Means = 'exit 0, NO report -> blocked' }
        @{ Name = 'empty-array'; Status = 'done_with_concerns'; NoReport = $false; UnresolvedJson = '[]'; Expect = 67; CheckBlocker = $true; Means = 'empty concern is refused' }
        @{ Name = 'space'; Status = 'done_with_concerns'; NoReport = $false; UnresolvedJson = '[" "]'; Expect = 67; CheckBlocker = $true; Means = 'whitespace concern is refused' }
        @{ Name = 'empty-space'; Status = 'done_with_concerns'; NoReport = $false; UnresolvedJson = '["", " "]'; Expect = 67; CheckBlocker = $true; Means = 'blank concerns are refused' }
    )

    $failures = 0
    foreach ($case in $cases) {
        $repo = Join-Path $root ("r-" + $case.Name)
        if (Test-Path $repo) { Remove-Item -Recurse -Force $repo }
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'src') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'docs') | Out-Null

        Push-Location $repo
        git init -q
        git config user.email 't@t.t'; git config user.name 't'
        'orig' | Out-File -Encoding ascii src/a.py
        'HOST' | Out-File -Encoding ascii docs/status.md
        git add -A; git commit -q -m init
        $baseSha = (git rev-parse HEAD)
        Pop-Location

        $env:FAKE_CODEX_REPO = $repo
        $env:FAKE_CODEX_STATUS = $case.Status
        $env:FAKE_CODEX_NO_REPORT = if ($case.NoReport) { '1' } else { '0' }
        if ($case.UnresolvedJson) {
            $env:FAKE_CODEX_UNRESOLVED_JSON = $case.UnresolvedJson
        }
        else {
            Remove-Item Env:\FAKE_CODEX_UNRESOLVED_JSON -ErrorAction SilentlyContinue
        }

        # The shared fake writes multiple paths by design, so real scope enforcement cannot apply.
        $dispatchOutput = (& $dispatch `
            -Spec 'verdict' -Task ('t-' + $case.Status) -Phase 'build' -Worktree $repo -BaseSha $baseSha `
            -Prompt 'Implement it.' `
            -ScopeUnlocked `
            -ScopeUnlockedReason 'verdict-routing fixture: the shared fake writes multiple paths by design' `
            -CriticalFilesConfirmed `
            -CriticalFilesConfirmedNote 'fixture: no real file authorization' `
            -SkipBaselineCheck `
            -CodexExecutable 'powershell.exe' `
            -CodexExecutableArgumentPrefix @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeCodex) `
            *>&1 | Out-String)

        $actual = $LASTEXITCODE
        $caseLedgerRow = @([System.IO.File]::ReadAllLines((Join-Path $progressRoot 'codex-run-ledger.jsonl')) |
            ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { $_ | ConvertFrom-Json } } |
            Where-Object { [string]$_.row_kind -ceq 'dispatch' -and
                [string]$_.worktree -ceq $repo } | Select-Object -Last 1)[0]
        $ok = ($actual -eq $case.Expect -and
            (-not $case.CheckBlocker -or [string]$caseLedgerRow.blocker -ceq $emptyConcernBlockerText))
        if (-not $ok) { $failures += 1 }

        $label = "report=$($case.Status)$(if ($case.NoReport) { ' (no report)' })"
        $line = "  {0} {1,-34} coder exited 0, dispatcher exited {2,-3} (want {3,-3}) -- {4}" -f `
        $(if ($ok) { 'ok  ' } else { 'FAIL' }), $label, $actual, $case.Expect, $case.Means
        Write-Host $line -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    }

    Remove-Item Env:\FAKE_CODEX_STATUS, Env:\FAKE_CODEX_NO_REPORT, Env:\FAKE_CODEX_REPO, `
        Env:\FAKE_CODEX_UNRESOLVED_JSON -ErrorAction SilentlyContinue

    # Adoption mirrors the completion rule. Seed dead rows whose reports contain the three blank
    # shapes and prove that each is durably closed as blocked with the exact refusal evidence.
    foreach ($shape in @(
            @{ Name = 'empty-array'; Json = '[]' },
            @{ Name = 'space'; Json = '[" "]' },
            @{ Name = 'empty-space'; Json = '["", " "]' }
        )) {
        $repo = Join-Path $root ("adopt-" + $shape.Name)
        if (Test-Path $repo) { Remove-Item -Recurse -Force $repo }
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'src') | Out-Null
        Push-Location $repo
        git init -q
        git config user.email 't@t.t'; git config user.name 't'
        'orig' | Out-File -Encoding ascii src/a.py
        git add -A; git commit -q -m init
        $baseSha = (git rev-parse HEAD)
        $worktreeKey = ((git rev-parse --show-toplevel) -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
        Pop-Location

        $runId = [guid]::NewGuid().ToString('N')
        $reportPath = Join-Path $stateRoot ("adopt-$($shape.Name).json")
        $report = [ordered]@{
            status = 'done_with_concerns'; changed_files = @(); commands_run = @()
            deviations = @(); unresolved = @(); blocker = $null
        }
        switch ($shape.Name) {
            'space' { $report.unresolved = @(' ') }
            'empty-space' { $report.unresolved = @('', ' ') }
        }
        [System.IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Compress -Depth 8),
            [System.Text.UTF8Encoding]::new($false))
        $row = [ordered]@{
            run_id = $runId; row_kind = 'dispatch'; status = 'orphaned'
            spec = "verdict-adopt-$($shape.Name)"; task = 'adopt'; phase = 'build'
            worktree = $repo; worktree_key = $worktreeKey; base_sha = $baseSha
            schema = 'completion'; final_path = $reportPath; sandbox = 'workspace-write'
            started = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o')
            scope_armed = $false; scope_task = 'adopt-fixture'; authorized = @()
        }
        [System.IO.File]::AppendAllText((Join-Path $progressRoot 'codex-run-ledger.jsonl'),
            (($row | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine),
            [System.Text.UTF8Encoding]::new($false))

        $contractRunId = $null
        if ($shape.Name -ceq 'empty-array') {
            $contractRunId = [guid]::NewGuid().ToString('N')
            $contractRow = [ordered]@{}
            foreach ($property in $row.GetEnumerator()) { $contractRow[$property.Key] = $property.Value }
            $contractRow.run_id = $contractRunId
            $contractRow.spec = 'verdict-adopt-stdout-contract'
            [System.IO.File]::AppendAllText((Join-Path $progressRoot 'codex-run-ledger.jsonl'),
                (($contractRow | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine),
                [System.Text.UTF8Encoding]::new($false))
        }

        # Success output has its own contract: exactly one worktree path. The blocker display is
        # intentionally best-effort host UI, so suppress information-stream rendering in this test
        # and assert the contractual value from the durable ledger artifact below.
        $adoptStdout = @(& $dispatch -Adopt -RunId $runId -Spec "verdict-adopt-$($shape.Name)" -Task 'adopt' `
            -Phase build -Worktree $repo 6> $null)
        $actual = $LASTEXITCODE
        $adoptedRow = @([System.IO.File]::ReadAllLines((Join-Path $progressRoot 'codex-run-ledger.jsonl')) |
            ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { $_ | ConvertFrom-Json } } |
            Where-Object { [string]$_.run_id -ceq $runId -and [string]$_.row_kind -ceq 'dispatch' })[0]
        $ok = ($actual -eq 67 -and $adoptStdout.Count -eq 1 -and
            [string]$adoptStdout[0] -ceq $repo -and
            [string]$adoptedRow.report_status -ceq 'blocked' -and
            [string]$adoptedRow.blocker -ceq $emptyConcernBlockerText -and
            @($adoptedRow.unresolved).Count -eq 0)
        if (-not $ok) { $failures += 1 }
        Write-Host ("  {0} adopt blank concern {1,-12} exited {2} (want 67)" -f `
            $(if ($ok) { 'ok  ' } else { 'FAIL' }), $shape.Name, $actual) `
            -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })

        if ($contractRunId) {
            $contractStdout = @(& $dispatch -Adopt -RunId $contractRunId `
                -Spec 'verdict-adopt-stdout-contract' -Task 'adopt' -Phase build `
                -Worktree $repo 6> $null)
            $contractExit = $LASTEXITCODE
            $contractLedgerRow = @([System.IO.File]::ReadAllLines((Join-Path $progressRoot 'codex-run-ledger.jsonl')) |
                ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { $_ | ConvertFrom-Json } } |
                Where-Object { [string]$_.run_id -ceq $contractRunId -and
                    [string]$_.row_kind -ceq 'dispatch' })[0]
            $contractOk = ($contractExit -eq 67 -and $contractStdout.Count -eq 1 -and
                [string]$contractStdout[0] -ceq $repo -and
                [string]$contractLedgerRow.report_status -ceq 'blocked' -and
                [string]$contractLedgerRow.blocker -ceq $emptyConcernBlockerText)
            if (-not $contractOk) { $failures += 1 }
            Write-Host ("  {0} adopt stdout is path alone; blocker is exact in ledger artifact" -f `
                $(if ($contractOk) { 'ok  ' } else { 'FAIL' })) `
                -ForegroundColor $(if ($contractOk) { 'Green' } else { 'Red' })
        }
    }

    # A review report has no unresolved field. Its FLAG evidence must be synthesized during adoption
    # and must remain a concern (68), not trip the completion-only empty-concern refusal (67).
    $reviewRepo = Join-Path $root 'adopt-review-flag'
    if (Test-Path $reviewRepo) { Remove-Item -Recurse -Force $reviewRepo }
    New-Item -ItemType Directory -Force -Path $reviewRepo | Out-Null
    Push-Location $reviewRepo
    git init -q
    git config user.email 't@t.t'; git config user.name 't'
    'orig' | Out-File -Encoding ascii a.txt
    git add -A; git commit -q -m init
    $reviewBaseSha = (git rev-parse HEAD)
    $reviewWorktreeKey = ((git rev-parse --show-toplevel) -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
    Pop-Location
    $reviewRunId = [guid]::NewGuid().ToString('N')
    $reviewReportPath = Join-Path $stateRoot 'adopt-review-flag.json'
    $reviewReport = [ordered]@{
        verdict = 'FLAG'; findings = @(
            [ordered]@{ severity = 'P2'; file = 'a.txt'; line = 1; criterion = 'fake'; rationale = 'adjudicate' }
        )
    }
    [System.IO.File]::WriteAllText($reviewReportPath,
        ($reviewReport | ConvertTo-Json -Compress -Depth 8), [System.Text.UTF8Encoding]::new($false))
    $reviewRow = [ordered]@{
        run_id = $reviewRunId; row_kind = 'dispatch'; status = 'orphaned'
        spec = 'verdict-adopt-review-flag'; task = 'review'; phase = 'review'
        worktree = $reviewRepo; worktree_key = $reviewWorktreeKey; base_sha = $reviewBaseSha
        schema = 'review'; final_path = $reviewReportPath; sandbox = 'read-only'
        started = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o')
        scope_armed = $false; scope_task = 'review-fixture'; authorized = @()
    }
    [System.IO.File]::AppendAllText((Join-Path $progressRoot 'codex-run-ledger.jsonl'),
        (($reviewRow | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false))
    $null = @(& $dispatch -Adopt -RunId $reviewRunId -Spec 'verdict-adopt-review-flag' -Task 'review' `
        -Phase review -Worktree $reviewRepo 6> $null)
    $reviewActual = $LASTEXITCODE
    $reviewAdoptedRow = @([System.IO.File]::ReadAllLines((Join-Path $progressRoot 'codex-run-ledger.jsonl')) |
        ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { $_ | ConvertFrom-Json } } |
        Where-Object { [string]$_.run_id -ceq $reviewRunId -and [string]$_.row_kind -ceq 'dispatch' })[0]
    $reviewConcern = "Review verdict 'FLAG' -- 1 finding(s) to adjudicate."
    $reviewOk = ($reviewActual -eq 68 -and [string]$reviewAdoptedRow.report_status -ceq 'done_with_concerns' -and
        @($reviewAdoptedRow.unresolved).Count -eq 1 -and
        [string]$reviewAdoptedRow.unresolved[0] -ceq $reviewConcern)
    if (-not $reviewOk) { $failures += 1 }
    Write-Host ("  {0} review FLAG adoption exited {1} (want 68) with synthesized concern" -f `
        $(if ($reviewOk) { 'ok  ' } else { 'FAIL' }), $reviewActual) `
        -ForegroundColor $(if ($reviewOk) { 'Green' } else { 'Red' })

    # Exercise the real Add-LeaseCloseRow function in isolation: one lease plus one close sharing a
    # run_id is valid, while a forced second close for the same pair must throw before appending.
    $tokens = $null
    $parseErrors = $null
    $dispatchAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $dispatch, [ref]$tokens, [ref]$parseErrors)
    foreach ($functionName in @('Get-UtcTimestamp', 'Add-Utf8NoBomText', 'Invoke-WithLedgerLock', 'Add-LeaseCloseRow')) {
        $functionAst = @($dispatchAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $node.Name -ceq $functionName
                }, $true))[0]
        Invoke-Expression $functionAst.Extent.Text
    }
    $dedupRoot = Join-Path $stateRoot 'dedup'
    $ledgerDirectory = $dedupRoot
    $ledgerPath = Join-Path $dedupRoot 'ledger.jsonl'
    $logPath = Join-Path $dedupRoot 'run.log'
    $Effort = 'medium'
    $script:attendedTelemetry = $null
    New-Item -ItemType Directory -Force -Path $dedupRoot | Out-Null
    $leaseRunId = [guid]::NewGuid().ToString('N')
    $lease = [ordered]@{ run_id = $leaseRunId; row_kind = 'lease'; status = 'leasing' }
    [System.IO.File]::WriteAllText($ledgerPath,
        (($lease | ConvertTo-Json -Compress) + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false))
    $ledgerMutex = [System.Threading.Mutex]::new($false, "ApexVerdictDedup-$leaseRunId")
    $firstCloseThrew = $false
    try { Add-LeaseCloseRow -RunId $leaseRunId -Status 'refused-preflight' -RefusalExit 72 }
    catch { $firstCloseThrew = $true }
    $secondCloseError = $null
    try { Add-LeaseCloseRow -RunId $leaseRunId -Status 'refused-preflight' -RefusalExit 72 }
    catch { $secondCloseError = $_.Exception.Message }
    $dedupRows = @([System.IO.File]::ReadAllLines($ledgerPath) |
        ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { $_ | ConvertFrom-Json } })
    $expectedDedupError = "Refusing to append a second lease_close ledger row for run_id $leaseRunId."
    $dedupOk = (-not $firstCloseThrew -and $secondCloseError -ceq $expectedDedupError -and
        @($dedupRows | Where-Object { [string]$_.run_id -ceq $leaseRunId -and
                [string]$_.row_kind -ceq 'lease' }).Count -eq 1 -and
        @($dedupRows | Where-Object { [string]$_.run_id -ceq $leaseRunId -and
                [string]$_.row_kind -ceq 'lease_close' }).Count -eq 1)
    if (-not $dedupOk) { $failures += 1 }
    Write-Host ("  {0} lease then close succeeds; duplicate close is refused" -f `
        $(if ($dedupOk) { 'ok  ' } else { 'FAIL' })) `
        -ForegroundColor $(if ($dedupOk) { 'Green' } else { 'Red' })
    $ledgerMutex.Dispose()

    Write-Host ''
    if ($failures -eq 0) {
        Write-Host "ALL VERDICT, ADOPTION, AND LEDGER DEDUP CASES PASS." -ForegroundColor Green
        exit 0
    }
    Write-Host "$failures FAILURE(S)" -ForegroundColor Red
    exit 1
}
finally {
    if ($null -eq $oldApexStateDir) {
        Remove-Item Env:\APEX_STATE_DIR -ErrorAction SilentlyContinue
    }
    else {
        $env:APEX_STATE_DIR = $oldApexStateDir
    }
    if ($null -eq $oldGitConfigGlobal) {
        Remove-Item Env:\GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue
    }
    else {
        $env:GIT_CONFIG_GLOBAL = $oldGitConfigGlobal
    }
    if ($null -eq $oldXdgConfigHome) {
        Remove-Item Env:\XDG_CONFIG_HOME -ErrorAction SilentlyContinue
    }
    else {
        $env:XDG_CONFIG_HOME = $oldXdgConfigHome
    }
    if ($stateRoot -and (Test-Path $stateRoot)) {
        Remove-Item -Recurse -Force $stateRoot -ErrorAction SilentlyContinue
    }
}
