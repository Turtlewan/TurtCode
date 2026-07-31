# Regression tests for codex-dispatch.ps1 encoding fixes:
#   (1) stdin is written as explicit UTF-8 bytes, so a prompt with non-ASCII (em-dash) reaches codex
#       intact instead of being rejected as "input is not valid UTF-8".
#   (2) the encoding scan is SKIPPED on a read-only (review/end-gate) dispatch, so a review no longer
#       fails on pre-existing mojibake in the owner's dirty tree (e.g. transcript .err files).
#   (3) wrapper-owned ledger and concerns writes are UTF-8 without a BOM and round-trip byte-exactly.
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

function Test-ByteArraysEqual($left, $right) {
    if ($null -eq $left -or $null -eq $right -or $left.Length -ne $right.Length) { return $false }
    for ($i = 0; $i -lt $left.Length; $i++) {
        if ($left[$i] -ne $right[$i]) { return $false }
    }
    return $true
}

function Test-StartsWithUtf8Bom($bytes) {
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

Write-Host "`n=== codex-dispatch.ps1 wrapper fixes ===" -ForegroundColor Cyan
$encodingConstructorMatches = @(Select-String -LiteralPath $dispatch -Pattern 'UTF8Encoding')
Check 'one UTF-8 encoder construction per write helper' `
    ($encodingConstructorMatches.Count -eq 3) "matches=$($encodingConstructorMatches.Count)"

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
if ($final) { $r = [ordered]@{ status='done_with_concerns'; changed_files=@(); commands_run=@(); deviations=@(); unresolved=@(('verify ' + [char]0x2014 + ' bytes')); blocker=$null }; [System.IO.File]::WriteAllText($final, ($r | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false)) }
exit 0
'@
$repo1 = Join-Path $parent 'utf8-repo'; New-Item -ItemType Directory -Force -Path $repo1 | Out-Null
Push-Location $repo1
try { git init -q; git config user.email 't@t.t'; git config user.name 't'; Write-Utf8 (Join-Path $repo1 'seed.txt') 'x'; git add -A; git commit -q -m init; $sha1 = (git rev-parse HEAD) } finally { Pop-Location }
$state1 = Join-Path $parent 'utf8-state'; New-Item -ItemType Directory -Force -Path $state1 | Out-Null
$marker = Join-Path $parent 'utf8-marker.txt'
$emDash = [char]0x2014
$utf8Spec = "utf8$emDash spec"
$utf8Task = "task$emDash name"
$env:APEX_STATE_DIR = $state1; $env:UTF8_MARKER = $marker
& $dispatch -Spec $utf8Spec -Task $utf8Task -Phase 'build' -Worktree $repo1 -BaseSha $sha1 -Prompt ("Implement it $emDash with an em-dash.") -Authorized @('src/a.py') -SkipScopeCheck -SkipBaselineCheck `
    -CodexExecutable 'powershell.exe' -CodexExecutableArgumentPrefix @('-NoProfile','-ExecutionPolicy','Bypass','-File',$utf8Fake) -ScratchDirectory $state1 *> $null
$markerVal = if (Test-Path $marker) { [System.IO.File]::ReadAllText($marker) } else { '(none)' }
Check 'non-ASCII prompt reaches child as valid UTF-8' ($markerVal -eq 'UTF8-OK') "marker=$markerVal"

$ledger1 = Join-Path $state1 'progress\codex-run-ledger.jsonl'
$ledgerBytes = if (Test-Path -LiteralPath $ledger1) {
    [System.IO.File]::ReadAllBytes($ledger1)
}
else {
    [byte[]]@()
}
$strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
$ledgerText = $null
$ledgerRoundTrips = $false
try {
    $ledgerText = $strictUtf8.GetString($ledgerBytes)
    $ledgerRoundTrips = Test-ByteArraysEqual $ledgerBytes ($strictUtf8.GetBytes($ledgerText))
}
catch { }
$dispatchRow = @($ledgerText -split "`r?`n" | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { return }
        try { $_ | ConvertFrom-Json } catch { }
    } | Where-Object {
        $_.row_kind -ceq 'dispatch' -and $_.spec -ceq $utf8Spec -and $_.task -ceq $utf8Task
    } | Select-Object -First 1)
Check 'ledger starts without UTF-8 BOM' (-not (Test-StartsWithUtf8Bom $ledgerBytes)) "bytes=$($ledgerBytes.Length)"
Check 'ledger UTF-8 round-trips byte-identically' ($ledgerRoundTrips -and $dispatchRow.Count -eq 1) "matching rows=$($dispatchRow.Count)"

$concerns1 = if ($dispatchRow.Count -eq 1) { "$($dispatchRow[0].final_path).concerns.md" } else { '' }
$concernsBytes = if (-not [string]::IsNullOrWhiteSpace($concerns1) -and
        (Test-Path -LiteralPath $concerns1)) {
    [System.IO.File]::ReadAllBytes($concerns1)
}
else {
    [byte[]]@()
}
$concernsText = $null
$concernsRoundTrips = $false
try {
    $concernsText = $strictUtf8.GetString($concernsBytes)
    $concernsRoundTrips = Test-ByteArraysEqual $concernsBytes ($strictUtf8.GetBytes($concernsText))
}
catch { }
$expectedHeading = "# Coder-reported concerns -- $utf8Spec / $utf8Task"
Check 'concerns starts without UTF-8 BOM' (-not (Test-StartsWithUtf8Bom $concernsBytes)) "bytes=$($concernsBytes.Length)"
Check 'concerns UTF-8 round-trips byte-identically' `
    ($concernsRoundTrips -and $concernsText.StartsWith($expectedHeading)) "path=$concerns1"

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

# --- Tests 3-6: adoption keys the encoding scan off the recorded sandbox --------------------------
function New-AdoptMojibakeRepo($name) {
    $repo = Join-Path $parent $name
    New-Item -ItemType Directory -Force -Path (Join-Path $repo 'src') | Out-Null
    Push-Location $repo
    try {
        git init -q; git config user.email 't@t.t'; git config user.name 't'
        git config core.excludesFile (Join-Path $repo '.git\info\exclude')
        Write-Utf8 (Join-Path $repo 'src\clean.py') "x = 1"
        git add -A; git commit -q -m init
        Write-Utf8 (Join-Path $repo 'src\corrupt.py') "x = 1  # $moji`n"
    } finally { Pop-Location }
    return $repo
}

# (a) A dead read-only review row skips the adopt encoding scan and adopts its CLEAN report.
$adoptRepoA = New-AdoptMojibakeRepo 'adopt-read-only-repo'
$adoptStateA = Join-Path $parent 'adopt-read-only-state'
$adoptProgressA = Join-Path $adoptStateA 'progress'
New-Item -ItemType Directory -Force -Path $adoptProgressA | Out-Null
$adoptReportA = Join-Path $adoptStateA 'review-final.json'
Write-Utf8 $adoptReportA (([ordered]@{ verdict='CLEAN'; findings=@() }) | ConvertTo-Json -Compress -Depth 8)
$adoptRunA = 'adopt-encoding-read-only'
$adoptRowA = [ordered]@{
    run_id = $adoptRunA; spec = 'adopt-ro'; task = 'case-a'; phase = 'review'; status = 'stalled'
    started = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
    pid = $null; launcher_pid = $null; worktree = $adoptRepoA; authorized = @()
    scope_task = 'adopt-read-only-scope'; final_path = $adoptReportA; schema = 'review'; sandbox = 'read-only'
}
$adoptLedgerA = Join-Path $adoptProgressA 'codex-run-ledger.jsonl'
[System.IO.File]::AppendAllText($adoptLedgerA, (($adoptRowA | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
$env:APEX_STATE_DIR = $adoptStateA
$adoptOutputA = (& $dispatch -Adopt -Phase 'review' -Spec 'adopt-ro' -Task 'case-a' -Worktree $adoptRepoA *>&1 | Out-String)
$adoptExitA = $LASTEXITCODE
$adoptSavedA = Get-Content -LiteralPath $adoptLedgerA | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.run_id -eq $adoptRunA } | Select-Object -First 1
Check 'adopt read-only row exits 0' ($adoptExitA -eq 0) "adopt exit=$adoptExitA"
Check 'adopt read-only row has no encoding violation' ($null -ne $adoptSavedA -and $adoptSavedA.encoding_violation -ne $true) "encoding_violation=$($adoptSavedA.encoding_violation)"
Check 'adopt read-only row logs scan skip' ($adoptOutputA.Contains('[encoding] read-only adopt')) 'stdout contains read-only adopt note'

# (b) A dead workspace-write build row scans its own dirty fixture and records the violation.
$adoptRepoB = New-AdoptMojibakeRepo 'adopt-workspace-write-repo'
$adoptStateB = Join-Path $parent 'adopt-workspace-write-state'
$adoptProgressB = Join-Path $adoptStateB 'progress'
New-Item -ItemType Directory -Force -Path $adoptProgressB | Out-Null
$adoptReportB = Join-Path $adoptStateB 'completion-final.json'
Write-Utf8 $adoptReportB (([ordered]@{ status='done'; changed_files=@(); commands_run=@(); deviations=@(); unresolved=@(); blocker=$null }) | ConvertTo-Json -Compress -Depth 8)
$adoptRunB = 'adopt-encoding-workspace-write'
$adoptRowB = [ordered]@{
    run_id = $adoptRunB; spec = 'adopt-ww'; task = 'case-b'; phase = 'build'; status = 'stalled'
    started = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
    pid = $null; launcher_pid = $null; worktree = $adoptRepoB; authorized = @()
    scope_task = 'adopt-workspace-write-scope'; final_path = $adoptReportB; schema = 'completion'; sandbox = 'workspace-write'
}
$adoptLedgerB = Join-Path $adoptProgressB 'codex-run-ledger.jsonl'
[System.IO.File]::AppendAllText($adoptLedgerB, (($adoptRowB | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
$env:APEX_STATE_DIR = $adoptStateB
& $dispatch -Adopt -Phase 'build' -Spec 'adopt-ww' -Task 'case-b' -Worktree $adoptRepoB *> $null
$adoptExitB = $LASTEXITCODE
$adoptSavedB = Get-Content -LiteralPath $adoptLedgerB | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.run_id -eq $adoptRunB } | Select-Object -First 1
Check 'adopt workspace-write row exits 73' ($adoptExitB -eq 73) "adopt exit=$adoptExitB"
Check 'adopt workspace-write row records violation' ($null -ne $adoptSavedB -and $adoptSavedB.encoding_violation -eq $true) "encoding_violation=$($adoptSavedB.encoding_violation)"

# (c) The guard is sandbox-keyed: a review row with write access still scans and fails.
$adoptRepoC = New-AdoptMojibakeRepo 'adopt-review-write-repo'
$adoptStateC = Join-Path $parent 'adopt-review-write-state'
$adoptProgressC = Join-Path $adoptStateC 'progress'
New-Item -ItemType Directory -Force -Path $adoptProgressC | Out-Null
$adoptReportC = Join-Path $adoptStateC 'review-final.json'
Write-Utf8 $adoptReportC (([ordered]@{ verdict='CLEAN'; findings=@() }) | ConvertTo-Json -Compress -Depth 8)
$adoptRunC = 'adopt-encoding-review-write'
$adoptRowC = [ordered]@{
    run_id = $adoptRunC; spec = 'adopt-review-write'; task = 'case-c'; phase = 'review'; status = 'stalled'
    started = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
    pid = $null; launcher_pid = $null; worktree = $adoptRepoC; authorized = @()
    scope_task = 'adopt-review-write-scope'; final_path = $adoptReportC; schema = 'review'; sandbox = 'workspace-write'
}
$adoptLedgerC = Join-Path $adoptProgressC 'codex-run-ledger.jsonl'
[System.IO.File]::AppendAllText($adoptLedgerC, (($adoptRowC | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
$env:APEX_STATE_DIR = $adoptStateC
& $dispatch -Adopt -Phase 'review' -Spec 'adopt-review-write' -Task 'case-c' -Worktree $adoptRepoC *> $null
$adoptExitC = $LASTEXITCODE
$adoptSavedC = Get-Content -LiteralPath $adoptLedgerC | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.run_id -eq $adoptRunC } | Select-Object -First 1
Check 'adopt review/write row exits 73' ($adoptExitC -eq 73) "adopt exit=$adoptExitC"
Check 'adopt review/write row records violation' ($null -ne $adoptSavedC -and $adoptSavedC.encoding_violation -eq $true) "encoding_violation=$($adoptSavedC.encoding_violation)"

# (d) A legacy/fabricated row with no sandbox property fails closed by running the scan.
$adoptRepoD = New-AdoptMojibakeRepo 'adopt-no-sandbox-repo'
$adoptStateD = Join-Path $parent 'adopt-no-sandbox-state'
$adoptProgressD = Join-Path $adoptStateD 'progress'
New-Item -ItemType Directory -Force -Path $adoptProgressD | Out-Null
$adoptReportD = Join-Path $adoptStateD 'completion-final.json'
Write-Utf8 $adoptReportD (([ordered]@{ status='done'; changed_files=@(); commands_run=@(); deviations=@(); unresolved=@(); blocker=$null }) | ConvertTo-Json -Compress -Depth 8)
$adoptRunD = 'adopt-encoding-no-sandbox'
$adoptRowD = [ordered]@{
    run_id = $adoptRunD; spec = 'adopt-no-sandbox'; task = 'case-d'; phase = 'build'; status = 'stalled'
    started = (Get-Date).ToUniversalTime().AddHours(-1).ToString('o')
    pid = $null; launcher_pid = $null; worktree = $adoptRepoD; authorized = @()
    scope_task = 'adopt-no-sandbox-scope'; final_path = $adoptReportD; schema = 'completion'
}
$adoptLedgerD = Join-Path $adoptProgressD 'codex-run-ledger.jsonl'
[System.IO.File]::AppendAllText($adoptLedgerD, (($adoptRowD | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
$env:APEX_STATE_DIR = $adoptStateD
& $dispatch -Adopt -Phase 'build' -Spec 'adopt-no-sandbox' -Task 'case-d' -Worktree $adoptRepoD *> $null
$adoptExitD = $LASTEXITCODE
$adoptSavedD = Get-Content -LiteralPath $adoptLedgerD | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.run_id -eq $adoptRunD } | Select-Object -First 1
Check 'adopt sandbox-absent row exits 73' ($adoptExitD -eq 73) "adopt exit=$adoptExitD"
Check 'adopt sandbox-absent row records violation' ($null -ne $adoptSavedD -and $adoptSavedD.encoding_violation -eq $true) "encoding_violation=$($adoptSavedD.encoding_violation)"

try { Remove-Item -Recurse -Force $parent -ErrorAction SilentlyContinue } catch {}
Write-Host ""
if ($script:fail -gt 0) { Write-Host "$($script:fail) check(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "ALL WRAPPER-FIX TESTS PASS." -ForegroundColor Green
exit 0
