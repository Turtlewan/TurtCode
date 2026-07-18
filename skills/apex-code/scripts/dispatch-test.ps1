# End-to-end test of codex-dispatch.ps1 with the scope check wired in.
# Driven from PowerShell so array params pass natively (the bash-array mangling is a caller bug,
# not a dispatcher bug -- but it bit twice today, so the real caller must pass arrays properly too).

$ErrorActionPreference = 'Stop'
$script:fails = 0

$dispatch = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
if (-not (Test-Path -LiteralPath $dispatch)) { throw "Dispatcher not found: $dispatch" }

# The fake lives BESIDE this test, in the repo. It used to be referenced out of a session scratchpad
# ($SP\fakecodex.ps1) that no longer exists -- a self-test reaching outside its own repo for the
# thing it is testing, which is how it quietly stopped running at all.
$fakeCodex = Join-Path $PSScriptRoot 'dispatch-test-fakecodex.ps1'
if (-not (Test-Path -LiteralPath $fakeCodex)) { throw "Fake codex not found: $fakeCodex" }

$SP   = Join-Path $env:TEMP 'apex-dispatch-test'
$repo = Join-Path $SP 'dt3'
$stateRoot = Join-Path $env:TEMP ("apex-dispatch-test-state-" + [guid]::NewGuid().ToString('N'))
$oldApexStateDir = $env:APEX_STATE_DIR
$locationPushed = $false

try {
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    $env:APEX_STATE_DIR = $stateRoot

    if (Test-Path $repo) { Remove-Item -Recurse -Force $repo }
    New-Item -ItemType Directory -Force -Path (Join-Path $repo 'src')  | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $repo 'docs') | Out-Null
    Push-Location $repo
    $locationPushed = $true

    git init -q
    git config user.email 't@t.t'; git config user.name 't'
    'orig'       | Out-File -Encoding ascii src/a.py
    'orig'       | Out-File -Encoding ascii src/b.py
    'HOST STATE' | Out-File -Encoding ascii docs/status.md
    New-Item -ItemType Directory -Force -Path docs/changes | Out-Null
    @'
---
spec: cap-test
status: draft
autonomy_level: L2
---
# Spec: fixture placeholder
## Intent
- Intent: fixture spec to satisfy pre-flight validation.
## Assumptions
- none -> impact: Low
## Prerequisites
- none
## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| src/a.py | modify | placeholder |
## Tasks
- [ ] **Task 1:** placeholder change -- files: src/a.py -- done when: file present.
## Wave plan
Wave 1: [Task 1]
## Permissions
Approving this spec approves the file operation above.
## Specialist Context
### Security
(none)
## Documentation
(none)
## Acceptance Criteria
- [ ] **Task 1** -> verify: the placeholder change is present.
## Progress
_(coding writes here)_
'@ | Out-File -Encoding utf8 docs/changes/cap-test.md
    @(
        '## Verify commands'
        ''
        '```'
        'exit 0'
        '```'
    ) | Out-File -Encoding ascii AGENTS.md
    git add -A; git commit -q -m init

    # The host is editing status.md RIGHT NOW, in the same tree. This must survive.
    Add-Content docs/status.md 'host ADR note'

    $env:FAKE_CODEX_REPO = $repo
    $baseSha = (git rev-parse HEAD)

    Write-Host "`n--- dispatching (authorized: src/a.py only) ---`n" -ForegroundColor Cyan

    & $dispatch `
        -Spec 'cap-test' -Task 't3' -Phase 'build' -Worktree $repo -BaseSha $baseSha `
        -Prompt 'Implement the deps field.' `
        -Authorized @('src/a.py') `
        -CodexExecutable 'powershell.exe' `
        -CodexExecutableArgumentPrefix @('-NoProfile','-ExecutionPolicy','Bypass','-File', $fakeCodex)

    $ec = $LASTEXITCODE

    Write-Host "`n===== RESULTS =====" -ForegroundColor Cyan
    # The dispatch log lives OUTSIDE the worktree now, beside the ledger. It used to be written into the
    # target repo -- which meant the scope check had to exempt its own state directory, and every version
    # of that exemption was a hole. Once the exemption was removed, the harness's own log read as an
    # unauthorized write and EVERY CLEAN BUILD EXITED 65. The harness must not write into the tree it is
    # judging.
    $logRoot = Join-Path (Join-Path $stateRoot 'progress') 'codex-logs'
    $log = Get-Content ((Get-ChildItem -Path $logRoot -Filter 'codex-cap-test-t3-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1).FullName) -Raw -ErrorAction SilentlyContinue

function Check($label, $cond, $detail) {
    $mark = if ($cond) { 'ok  ' } else { 'FAIL' }
    $col  = if ($cond) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-42} {2}" -f $mark, $label, $detail) -ForegroundColor $col
    if (-not $cond) { $script:fails += 1 }
}

    Check 'stdin delivered the prompt'   ($log -match 'got prompt')                  'fake codex read stdin'
    Check 'scope lock reached the prompt'($log -match 'scope lock present')          'belt-and-braces prose'
    Check 'authorized change KEPT'        ((Get-Content src/a.py -Raw) -match 'codex authorized')  'src/a.py'
    # The scope check DETECTS and reports; it no longer reverts. It destroyed real work twice by
    # inferring authorship from timing while other writers were live, so it now leaves the tree alone
    # and fails loudly instead. Both out-of-scope writes must therefore still be PRESENT -- and flagged.
    Check 'out-of-scope write still PRESENT' ((Get-Content src/b.py -Raw) -match 'OUT OF SCOPE')  'src/b.py -- detected, not destroyed'
    Check 'stray file still PRESENT'         (Test-Path src/rogue.py)                             'src/rogue.py -- detected, not destroyed'
    $st = Get-Content docs/status.md -Raw
    Check 'host status.md edit SURVIVED'  ($st -match 'host ADR note')               'the ADR-destroying bug'
    Check 'codex status.md write flagged' ($st -match 'codex clobbered')             'contested, not reverted'
    Check 'exit 65 (scope violation)'     ($ec -eq 65)                               "got $ec"

    Pop-Location
    $locationPushed = $false
}
finally {
    if ($locationPushed) { Pop-Location }
    if ($null -eq $oldApexStateDir) {
        Remove-Item Env:\APEX_STATE_DIR -ErrorAction SilentlyContinue
    }
    else {
        $env:APEX_STATE_DIR = $oldApexStateDir
    }
    if (Test-Path -LiteralPath $stateRoot) {
        Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:fails -gt 0) { exit 1 } else { exit 0 }
