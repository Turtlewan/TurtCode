# An UNCOMMITTED EARLIER WAVE must not read as a scope violation.
#
# The snapshot used to record only WHICH paths were dirty, never their content. That cannot answer
# the question the check actually asks -- did the coder write to this file? -- so it lumped together:
#   (a) host work the coder never opened, and
#   (b) the coder writing into a file the host was also editing (the real status.md incident)
# and reported both as CONTESTED, which exits 65.
#
# Live: al-7c-quiet-gate task3 (2026-07-14) exited 65 flagging SEVEN files the coder never touched --
# wave 1's output, still uncommitted. The host agent then blamed itself and resolved to "commit every
# wave", i.e. to commit unreviewed work to appease a broken guard. That is the tool bending the human.
#
# Worse than the noise: a GENUINE violation hides among the false ones. Case 3 below is the one that
# matters -- it proves the guard still bites when the coder really does write out of scope.

$ErrorActionPreference = 'Stop'

$scopeCheck = Join-Path $PSScriptRoot 'codex-scope-check.ps1'
$root = Join-Path $env:TEMP 'apex-wave-scope-test'
$failures = 0

function New-Repo {
    param([string]$Path)
    if (Test-Path $Path) { Remove-Item -Recurse -Force $Path }
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'src') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'docs') | Out-Null
    Push-Location $Path
    git init -q
    git config user.email 't@t.t'; git config user.name 't'
    'orig' | Out-File -Encoding ascii src/wave1.py
    'orig' | Out-File -Encoding ascii src/wave2.py
    'orig' | Out-File -Encoding ascii src/task3.py
    'HOST' | Out-File -Encoding ascii docs/status.md
    git add -A; git commit -q -m init
    Pop-Location
}

function Assert-Exit {
    param([int]$Actual, [int]$Expected, [string]$Name, [string]$Detail)
    $ok = ($Actual -eq $Expected)
    $mark = if ($ok) { 'ok  ' } else { 'FAIL' }
    $colour = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-52} exit {2} (want {3})  {4}" -f $mark, $Name, $Actual, $Expected, $Detail) -ForegroundColor $colour
    if (-not $ok) { $script:failures += 1 }
}

# --- Case 1: task3's real situation -- wave 1+2 uncommitted, coder stays in scope --------------
$repo = Join-Path $root 'case1'
New-Repo $repo
Add-Content (Join-Path $repo 'src/wave1.py') 'wave1 output'     # earlier wave, UNCOMMITTED
Add-Content (Join-Path $repo 'src/wave2.py') 'wave2 output'     # earlier wave, UNCOMMITTED
Add-Content (Join-Path $repo 'docs/status.md') 'host note'      # host's own edit
& $scopeCheck -Snapshot -Worktree $repo -Task 'task3' -Authorized @('src/task3.py') *> $null
Add-Content (Join-Path $repo 'src/task3.py') 'task3 output'     # the coder, strictly in scope
& $scopeCheck -Check -Worktree $repo -Task 'task3' -Authorized @('src/task3.py') *> $null
Assert-Exit $LASTEXITCODE 0 'uncommitted earlier wave is NOT a violation' 'the false 65'

# --- Case 2: the coder writes INTO a host-dirty file -> genuinely contested --------------------
$repo = Join-Path $root 'case2'
New-Repo $repo
Add-Content (Join-Path $repo 'docs/status.md') 'host note'      # host dirty before dispatch
& $scopeCheck -Snapshot -Worktree $repo -Task 't' -Authorized @('src/task3.py') *> $null
Add-Content (Join-Path $repo 'docs/status.md') 'CODEX CLOBBER'  # coder writes into it too
Add-Content (Join-Path $repo 'src/task3.py') 'in scope'
& $scopeCheck -Check -Worktree $repo -Task 't' -Authorized @('src/task3.py') *> $null
Assert-Exit $LASTEXITCODE 1 'coder writing INTO host-dirty file still flags' 'the status.md incident'

# --- Case 3: the guard must still bite a real out-of-scope write ------------------------------
$repo = Join-Path $root 'case3'
New-Repo $repo
Add-Content (Join-Path $repo 'src/wave1.py') 'wave1 output'     # uncommitted earlier wave (noise)
& $scopeCheck -Snapshot -Worktree $repo -Task 't' -Authorized @('src/task3.py') *> $null
Add-Content (Join-Path $repo 'src/task3.py') 'in scope'
Add-Content (Join-Path $repo 'src/wave2.py') 'CODEX OUT OF SCOPE'   # clean at snapshot -> revert
& $scopeCheck -Check -Worktree $repo -Task 't' -Authorized @('src/task3.py') *> $null
Assert-Exit $LASTEXITCODE 1 'a REAL out-of-scope write still caught' 'not buried by the noise'
# Nothing is reverted any more: the check reports and fails. Both files stay exactly as they were.
$strayPresent = (Get-Content (Join-Path $repo 'src/wave2.py') -Raw) -match 'OUT OF SCOPE'
$waveSafe = (Get-Content (Join-Path $repo 'src/wave1.py') -Raw) -match 'wave1 output'
Assert-Exit ([int](-not $strayPresent)) 0 '  ...the stray is REPORTED, not destroyed' 'src/wave2.py intact'
Assert-Exit ([int](-not $waveSafe)) 0 '  ...and the uncommitted wave is untouched' 'src/wave1.py intact'

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'ALL WAVE-SCOPE CASES PASS -- host work is not a violation; real violations still bite.' -ForegroundColor Green
    exit 0
}
Write-Host "$failures FAILURE(S)" -ForegroundColor Red
exit 1
