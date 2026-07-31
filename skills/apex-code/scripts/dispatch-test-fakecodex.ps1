# Fake `codex exec` for testing codex-dispatch.ps1 end-to-end.
# Reads the prompt from STDIN -- proving stdin delivery works, which is the exact bug that just bit
# the live build ("No prompt provided via stdin" after a `< /dev/null` clobbered the pipe).
# Then misbehaves precisely as the real Codex has: writes in-scope, out-of-scope, and to status.md.
#
# It also honours `-o <path>` and writes a completion report there, because THAT IS THE CONTRACT the
# dispatcher now routes on. The fake previously exited 0 and wrote no report at all -- so the
# dispatcher's `.final` handling was never once exercised by its own self-test, which is precisely
# how the exit-code-is-the-verdict bug survived. Set FAKE_CODEX_STATUS to drive the reported status
# ('done' | 'done_with_concerns' | 'blocked'), or FAKE_CODEX_NO_REPORT=1 to write nothing at all
# (the real 0xc0000142 shape: the process exits 0 having failed to produce a verdict).
# NO param() block, deliberately. Declaring one with [Parameter(ValueFromRemainingArguments)] makes
# this an ADVANCED function, which enables PowerShell's partial matching of common parameters -- and
# then `-o <path>` (which the dispatcher really does pass) dies with "the parameter name 'o' is
# ambiguous. Possible matches include: -OutVariable -OutBuffer." Raw $args takes the tokens as-is.
$PassThruArgs = $args

$prompt = [Console]::In.ReadToEnd()

if ([string]::IsNullOrWhiteSpace($prompt)) {
    Write-Output "FAKE-CODEX: FAIL - no prompt provided via stdin"
    exit 1
}

Write-Output "FAKE-CODEX: got prompt, $($prompt.Length) chars"
if ($prompt -match 'STANDING SCOPE LOCK') { Write-Output "FAKE-CODEX: scope lock present in prompt" }

# The real codex is given -C <repo>; this fake honours an env var instead.
$repo = $env:FAKE_CODEX_REPO
if (-not $repo) { Write-Output "FAKE-CODEX: FAIL - FAKE_CODEX_REPO unset"; exit 1 }
Set-Location $repo

Add-Content -Path 'src/a.py'       -Value 'codex authorized change'   # in scope   -> keep

# Opt-in test hook for post-hoc written-set cases. The value is deliberately repo-relative: callers
# choose one additional path while the default, unset flow remains byte-for-byte unchanged. Keep this
# before the in-scope-only return so focused fixtures can use it without enabling the fake's usual
# out-of-scope writes.
if ($env:FAKE_CODEX_EXTRA_WRITE) {
    $extraWritePath = Join-Path $repo $env:FAKE_CODEX_EXTRA_WRITE
    $extraWriteParent = Split-Path $extraWritePath -Parent
    if ($extraWriteParent) { [System.IO.Directory]::CreateDirectory($extraWriteParent) | Out-Null }
    Add-Content -LiteralPath $extraWritePath -Value 'codex extra write'
}

# A well-behaved coder that writes ONLY what it was authorized to write. Without this, the fake
# ALWAYS misbehaved -- so the suite had no test in which a build was supposed to come back CLEAN, and
# a bug that made every clean build fail was structurally invisible to it.
if ($env:FAKE_CODEX_INSCOPE_ONLY -eq '1') {
    Write-Output "FAKE-CODEX: in-scope only"
    $finalPathEarly = $null
    for ($j = 0; $j -lt $PassThruArgs.Count - 1; $j++) {
        if ($PassThruArgs[$j] -eq '-o') { $finalPathEarly = $PassThruArgs[$j + 1]; break }
    }
    if ($finalPathEarly) {
        $r = [ordered]@{
            status = 'done'; changed_files = @('src/a.py')
            commands_run = @(@{ command = 'pytest'; result = 'pass'; detail = $null })
            deviations = @(); unresolved = @(); blocker = $null
        }
        [System.IO.File]::WriteAllText($finalPathEarly, ($r | ConvertTo-Json -Depth 8),
            [System.Text.UTF8Encoding]::new($false))
    }
    Write-Output "FAKE-CODEX: done"
    exit 0
}
Add-Content -Path 'src/b.py'       -Value 'codex OUT OF SCOPE'        # out, clean -> revert
Set-Content  -Path 'src/rogue.py'  -Value 'codex stray file'          # out, new   -> delete
Add-Content -Path 'docs/status.md' -Value 'codex clobbered status.md' # host owns  -> CONTESTED, never revert

# --- write the completion report to wherever -o pointed ------------------------------------------
# The real Codex exits 0 even when this report says `blocked`. That divergence is the whole reason
# the dispatcher must read the report and not the exit code, so the fake reproduces it exactly.
$finalPath = $null
for ($i = 0; $i -lt $PassThruArgs.Count - 1; $i++) {
    if ($PassThruArgs[$i] -eq '-o') { $finalPath = $PassThruArgs[$i + 1]; break }
}

$reportStatus = if ($env:FAKE_CODEX_STATUS) { $env:FAKE_CODEX_STATUS } else { 'done' }

# A REVIEW report has no `status` -- it has `verdict` and `findings`. The dispatcher read only
# `status`, so a BLOCKING review left status empty, defaulted to done, and EXITED 0. This fake could
# not reproduce that because it only ever emitted completion reports -- so the harness's own tests
# were structurally incapable of catching the bug. FAKE_CODEX_VERDICT emits the review shape.
if ($finalPath -and $env:FAKE_CODEX_VERDICT -and $env:FAKE_CODEX_NO_REPORT -ne '1') {
    $review = [ordered]@{
        verdict  = $env:FAKE_CODEX_VERDICT
        findings = @(
            [ordered]@{ severity = 'BLOCK'; file = 'src/a.py'; line = 1; criterion = 'fake'; rationale = 'fake finding' }
        )
    }
    [System.IO.File]::WriteAllText($finalPath, ($review | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false))
    Write-Output "FAKE-CODEX: wrote REVIEW report (verdict=$($env:FAKE_CODEX_VERDICT)) to $finalPath"
    Write-Output "FAKE-CODEX: done"
    exit 0
}

if ($finalPath -and $env:FAKE_CODEX_NO_REPORT -ne '1') {
    $report = [ordered]@{
        status        = $reportStatus
        changed_files = @('src/a.py')
        commands_run  = @(@{ command = 'pytest'; result = 'pass'; detail = $null })
        deviations    = @()
        unresolved    = @()
        blocker       = $null
    }
    if ($reportStatus -eq 'blocked') {
        $report.commands_run = @(@{ command = 'pytest'; result = 'not_run'; detail = 'sandbox helper failed' })
        $report.unresolved = @('Run lint, mypy, and the test suite.', 'A final inspection pass is still required.')
        $report.deviations = @('uv sync was not run.')
        $report.blocker = 'The Windows sandbox can no longer launch helpers (0xc0000142).'
    } elseif ($reportStatus -eq 'done_with_concerns') {
        $report.unresolved = @('Live WSL2 tests require host re-verification.')
    }
    if ($env:FAKE_CODEX_UNRESOLVED_JSON) {
        switch -CaseSensitive ($env:FAKE_CODEX_UNRESOLVED_JSON) {
            '[]' { $report.unresolved = @() }
            '[" "]' { $report.unresolved = @(' ') }
            '["", " "]' { $report.unresolved = @('', ' ') }
            default { throw "Unsupported FAKE_CODEX_UNRESOLVED_JSON fixture: $env:FAKE_CODEX_UNRESOLVED_JSON" }
        }
    }
    [System.IO.File]::WriteAllText($finalPath, ($report | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false))
    Write-Output "FAKE-CODEX: wrote report ($reportStatus) to $finalPath"
}

Write-Output "FAKE-CODEX: done"
exit 0
