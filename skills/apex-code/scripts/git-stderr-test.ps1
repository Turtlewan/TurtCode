# A git WARNING must never kill a dispatch.
#
# `& git ... 2>$null` reads like "suppress git's stderr". Under Windows PowerShell 5.1 with
# $ErrorActionPreference = 'Stop' it does the opposite: redirecting a native command's stderr wraps
# each line in a NativeCommandError ErrorRecord, which is then TERMINATING. The line written to
# silence the noise is the line that makes the noise fatal.
#
# Live failure, al-7c-quiet-gate (2026-07-14): Codex left a scratch dir the repo's .gitignore glob
# did not match. git walked into it, hit an unreadable pytest temp dir, and printed
#   warning: could not open directory '.codex-scratch-al7c-task2/temp/pytest-of-User/': Permission denied
# That WARNING threw. The scope check died. The dispatcher recorded `failed`. An eleven-minute Codex
# run was discarded over a cosmetic message about a temp directory -- and both tasks in the wave
# died the same way, each on the OTHER task's scratch dir.
#
# This test pins the fix: codex-scope-check.ps1 must route every git call through Invoke-Git, which
# drops EAP to 'Continue' around the native invocation. git writes to stderr routinely and benignly;
# its EXIT CODE is the verdict.

$ErrorActionPreference = 'Stop'

$scopeCheck = Join-Path $PSScriptRoot 'codex-scope-check.ps1'
$failures = 0

function Assert-Ok {
    param([bool]$Condition, [string]$Name, [string]$Detail)
    $mark = if ($Condition) { 'ok  ' } else { 'FAIL' }
    $colour = if ($Condition) { 'Green' } else { 'Red' }
    Write-Host ("  {0}  {1,-46} {2}" -f $mark, $Name, $Detail) -ForegroundColor $colour
    if (-not $Condition) { $script:failures += 1 }
}

# 1. No raw `& git` survives in the scope check -- every call must go through the helper.
$source = Get-Content -LiteralPath $scopeCheck -Raw
$rawCalls = [regex]::Matches($source, '&\s+git\s+-C\s+\$repo')
Assert-Ok ($rawCalls.Count -eq 1) 'all git calls routed through Invoke-Git' `
    "$($rawCalls.Count) raw call(s) -- only the helper's own may remain"
Assert-Ok ($source -match "function Invoke-Git") 'Invoke-Git helper present' 'defined'
Assert-Ok ($source -match "ErrorActionPreference = 'Continue'") 'helper drops EAP around the native call' "'Continue'"

# 2. The mechanism itself: a git command that writes to stderr must not throw under EAP='Stop'.
$repo = Join-Path $env:TEMP 'apex-gitstderr-test'
if (Test-Path $repo) { Remove-Item -Recurse -Force $repo }
New-Item -ItemType Directory -Force -Path $repo | Out-Null
Push-Location $repo
git init -q
git config user.email 't@t.t'; git config user.name 't'
'x' | Out-File -Encoding ascii f.txt
git add f.txt; git commit -q -m init
Pop-Location

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& git -C $repo @GitArgs 2>$null) } finally { $ErrorActionPreference = $previous }
}

# The OLD pattern throws. Proving that keeps this test honest: if a future PowerShell stops wrapping
# native stderr, this assertion fails loudly and the guard can be reconsidered -- rather than the
# fix silently becoming cargo cult.
$oldThrew = $false
try { & git -C $repo restore --source=HEAD -- 'no-such-file.txt' 2>$null } catch { $oldThrew = $true }
Assert-Ok $oldThrew 'the old pattern DOES throw on git stderr' 'EAP=Stop + 2>$null == terminating'

$newThrew = $false
try { Invoke-Git restore --source=HEAD -- 'no-such-file.txt' | Out-Null } catch { $newThrew = $true }
Assert-Ok (-not $newThrew) 'Invoke-Git survives git stderr' "git exit $LASTEXITCODE, dispatch lives"
Assert-Ok ($ErrorActionPreference -eq 'Stop') 'EAP restored after the helper returns' $ErrorActionPreference

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'ALL GIT-STDERR CASES PASS -- a git warning can no longer kill a dispatch.' -ForegroundColor Green
    exit 0
}
Write-Host "$failures FAILURE(S)" -ForegroundColor Red
exit 1
