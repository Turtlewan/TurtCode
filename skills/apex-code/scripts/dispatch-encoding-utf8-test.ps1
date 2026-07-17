# Regression tests for two codex-dispatch.ps1 wrapper fixes (session 73):
#   (1) stdin is written as explicit UTF-8 bytes, so a prompt with non-ASCII (em-dash) reaches codex
#       intact instead of being rejected as "input is not valid UTF-8".
#   (2) the encoding scan is SKIPPED on a read-only (review/end-gate) dispatch, so a review no longer
#       fails on pre-existing mojibake in the owner's dirty tree (e.g. transcript .err files).
# Fully isolated: throwaway repos, isolated APEX_STATE_DIR, powershell.exe fakes (no real codex).
# Dispatches are called DIRECTLY (the wrapper's own watchdog bounds them); the fakes exit in <1s.

$ErrorActionPreference = 'Continue'
$dispatch = Join-Path $PSScriptRoot 'codex-dispatch.ps1'
$scopeCheck = Join-Path $PSScriptRoot 'codex-scope-check.ps1'
if (-not (Test-Path $dispatch)) { throw "missing: $dispatch" }

# Parent is NOT a git repo; the repo and the state dir are siblings under it (the state dir must not
# resolve inside a git worktree, or the wrapper refuses to write there).
$parent = Join-Path $env:TEMP ("apex-wrapfix-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $parent | Out-Null
function Write-Utf8($path, $text) { [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false)) }

$script:fail = 0
function Check($label, $cond, $detail) {
    $mark = if ($cond) { 'ok  ' } else { 'FAIL' }; $col = if ($cond) { 'Green' } else { 'Red' }
    if (-not $cond) { $script:fail++ }
    Write-Host ("  {0}  {1,-46} {2}" -f $mark, $label, $detail) -ForegroundColor $col
}

Write-Host "`n=== codex-dispatch.ps1 wrapper fixes ===" -ForegroundColor Cyan

# --- Test 1: stdin reaches the child as valid UTF-8 -----------------------------------------------
$utf8Fake = Join-Path $parent 'utf8-fake.ps1'
Write-Utf8 $utf8Fake @'
$in = [System.Console]::OpenStandardInput()
$ms = New-Object System.IO.MemoryStream
$buf = New-Object byte[] 4096
while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
$bytes = $ms.ToArray()
# Byte-exact: decode with throwOnInvalidBytes and reject a trailing BOM. A prior fix appended EF BB BF
# by closing the StreamWriter; a "Contains(em-dash)" check would have missed it. This catches both.
$result = 'BAD'
try {
    $text = ([System.Text.UTF8Encoding]::new($false, $true)).GetString($bytes)
    $trailingBom = ($bytes.Length -ge 3 -and $bytes[$bytes.Length-3] -eq 0xEF -and $bytes[$bytes.Length-2] -eq 0xBB -and $bytes[$bytes.Length-1] -eq 0xBF)
    if ($text.Contains([char]0x2014) -and -not $trailingBom) { $result = 'UTF8-OK' }
} catch { $result = 'INVALID-UTF8' }
[System.IO.File]::WriteAllText($env:UTF8_MARKER, $result, [System.Text.UTF8Encoding]::new($false))
$final = $null; for ($i = 0; $i -lt $args.Count - 1; $i++) { if ($args[$i] -eq '-o') { $final = $args[$i + 1]; break } }
if ($final) { $r = [ordered]@{ status='done'; changed_files=@(); commands_run=@(); deviations=@(); unresolved=@(); blocker=$null }; [System.IO.File]::WriteAllText($final, ($r | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false)) }
exit 0
'@
$repo1 = Join-Path $parent 'utf8-repo'; New-Item -ItemType Directory -Force -Path $repo1 | Out-Null
Push-Location $repo1
try { git init -q; git config user.email 't@t.t'; git config user.name 't'; Write-Utf8 (Join-Path $repo1 'seed.txt') 'x'; git add -A; git commit -q -m init; $sha1 = (git rev-parse HEAD) } finally { Pop-Location }
$state1 = Join-Path $parent 'utf8-state'; New-Item -ItemType Directory -Force -Path $state1 | Out-Null
$marker = Join-Path $parent 'utf8-marker.txt'
$emDash = [char]0x2014
$env:APEX_STATE_DIR = $state1; $env:UTF8_MARKER = $marker
& $dispatch -Spec 'utf8' -Task 't' -Phase 'build' -Worktree $repo1 -BaseSha $sha1 -Prompt ("Implement it $emDash with an em-dash.") -Authorized @('src/a.py') -SkipScopeCheck -SkipBaselineCheck `
    -CodexExecutable 'powershell.exe' -CodexExecutableArgumentPrefix @('-NoProfile','-ExecutionPolicy','Bypass','-File',$utf8Fake) -ScratchDirectory $state1 *> $null
$markerVal = if (Test-Path $marker) { [System.IO.File]::ReadAllText($marker) } else { '(none)' }
Check 'non-ASCII prompt reaches child as valid UTF-8' ($markerVal -eq 'UTF8-OK') "marker=$markerVal"

# --- Test 2: encoding scan is skipped on a read-only review ---------------------------------------
$revFake = Join-Path $parent 'review-fake.ps1'
Write-Utf8 $revFake @'
[System.Console]::In.ReadToEnd() | Out-Null
$final = $null; for ($i = 0; $i -lt $args.Count - 1; $i++) { if ($args[$i] -eq '-o') { $final = $args[$i + 1]; break } }
if ($final) { $r = [ordered]@{ verdict='CLEAN'; findings=@([ordered]@{ severity='CLEAN'; file='x'; line=1; criterion='x'; rationale='clean' }) }; [System.IO.File]::WriteAllText($final, ($r | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false)) }
exit 0
'@
$repo2 = Join-Path $parent 'review-repo'; New-Item -ItemType Directory -Force -Path (Join-Path $repo2 'src') | Out-Null
Push-Location $repo2
try {
    git init -q; git config user.email 't@t.t'; git config user.name 't'
    Write-Utf8 (Join-Path $repo2 'src\clean.py') "x = 1"
    git add -A; git commit -q -m init
    # A DIRTY (untracked) source file carrying a double-encoded em-dash (U+00E2 U+20AC U+201D) -- the
    # exact form M1's own detector catches (3-byte lead + 2 CP1252 continuations).
    $moji = [char]0x00E2 + [char]0x20AC + [char]0x201D
    Write-Utf8 (Join-Path $repo2 'src\corrupt.py') "x = 1  # $moji`n"
    $baseSha = (git rev-parse HEAD)
} finally { Pop-Location }
$state2 = Join-Path $parent 'review-state'; New-Item -ItemType Directory -Force -Path $state2 | Out-Null

# Guard against a tautological pass: prove the dirty tree WOULD flag if the scan actually ran (the
# wrapper calls -EncodingScan with -Task, so the guard must too, or the helper refuses to bind).
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scopeCheck -EncodingScan -Worktree $repo2 -Task 'guard' *> $null
Check 'the dirty tree WOULD flag if scanned (non-tautological)' ($LASTEXITCODE -eq 73) 'scope-check -EncodingScan = 73'

$env:APEX_STATE_DIR = $state2
& $dispatch -Spec 'rev' -Task 't' -Phase 'review' -Schema 'review' -Sandbox 'read-only' -Worktree $repo2 -BaseSha $baseSha `
    -Prompt 'review please' -CodexExecutable 'powershell.exe' -CodexExecutableArgumentPrefix @('-NoProfile','-ExecutionPolicy','Bypass','-File',$revFake) -ScratchDirectory $state2 *> $null
$revExit = $LASTEXITCODE
# A CLEAN read-only review over a dirty mojibake tree should exit 0 -- not 73 (the bug), and not some
# other unrelated failure. Assert the exact success code, not merely "not 73".
Check 'read-only review over mojibake tree exits 0 (was 73)' ($revExit -eq 0) "review exit=$revExit"

try { Remove-Item -Recurse -Force $parent -ErrorAction SilentlyContinue } catch {}
Write-Host ""
if ($script:fail -gt 0) { Write-Host "$($script:fail) check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "ALL WRAPPER-FIX TESTS PASS." -ForegroundColor Green
exit 0
