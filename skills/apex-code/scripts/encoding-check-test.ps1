# RED/GREEN tests for -EncodingScan in codex-scope-check.ps1.
#
# TWO THINGS THIS SUITE HAS TO GET RIGHT, both learned the hard way:
#
# 1. EVERY CASE MUST BE ABLE TO FAIL. The first version "proved" artifact exclusion with a case that
#    scanned one clean file -- so the excluded log was out of scope anyway, and the case passed with the
#    exclusion code DELETED. 84 harness tests once passed while every clean build would have exited 65.
#    A test that cannot fail is decoration. Each exclusion case below is built so the ONLY corrupt bytes
#    in the scanned set are in the excluded file: delete the exclusion and the case goes red.
#
# 2. THE FALSE-POSITIVE CASES MATTER MORE THAN THE DETECTION CASES. The first detector detected
#    perfectly and was still useless: it scanned the whole dirty tree, so the wrapper's own Codex
#    transcripts (which faithfully RECORD mojibake) tripped it on every dispatch, and it flagged its own
#    documentation. A gate that fires every run gets switched off, and then it protects nothing.
$ErrorActionPreference = 'Stop'

$scope = "C:\Users\User\.claude\skills\apex-code\scripts\codex-scope-check.ps1"
$root  = Join-Path $env:TEMP ("enc-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $root | Out-Null

$utf8 = [System.Text.UTF8Encoding]::new($false)
$fail = 0

# A git WARNING must not kill this script. Under EAP=Stop, PowerShell 5.1 wraps native stderr in a
# TERMINATING NativeCommandError -- the trap that killed an 11-minute Codex run, and that killed the
# first draft of this very test. git's EXIT CODE is the verdict, not its stderr.
function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & git @GitArgs 2>$null | Out-Null } finally { $ErrorActionPreference = $previous }
}

function Scan {
    param([string[]]$Authorized = @())
    # Comma-JOINED, not separate tokens: `powershell -File s.ps1 -Authorized a.py b.py` binds only the
    # first token to the array param and silently DROPS the rest. The wrapper calls the script
    # in-process, where array binding is native; the script also splits on commas defensively.
    $a = @('-EncodingScan', '-Worktree', $root, '-Task', 't1')
    if ($Authorized.Count -gt 0) { $a += @('-Authorized', ($Authorized -join ',')) }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scope @a | Out-Null
    return $LASTEXITCODE
}

function Check([string]$label, [bool]$ok) {
    if ($ok) { Write-Host "  PASS  $label" -ForegroundColor Green }
    else     { Write-Host "  FAIL  $label" -ForegroundColor Red; $script:fail++ }
}

function Put([string]$rel, [string]$content) {
    $full = Join-Path $root $rel
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($full, $content, $utf8)
}
function Drop([string]$rel) { Remove-Item -LiteralPath (Join-Path $root $rel) -Force -ErrorAction SilentlyContinue }

# --- The real artifacts, built from code points (never literals: this file may be decoded as ANSI) ---
$mojiDash   = [char]0x00E2 + [char]0x20AC + [char]0x201D            # em-dash U+2014: 3-byte lead + 2
$mojiEacute = [char]0x00C3 + [char]0x00A9                           # e-acute U+00E9: 2-byte lead + 1
$mojiCJK    = [char]0x00E4 + [char]0x00B8 + [char]0x00AD            # CJK U+4E2D: a lead the first cut never listed
$mojiCyr    = [char]0x00D0 + [char]0x0178                           # Cyrillic U+041F: ditto
# LEGITIMATE non-ASCII that must never trip: real em-dash, accent, CJK, emoji (surrogate pair).
$legit      = [char]0x2014 + [char]0x00E9 + [char]0x4E2D + [char]0x6587 + [char]0xD83D + [char]0xDE00
# LEGITIMATE accented letter followed by a non-breaking space. This is the false positive that forced
# the lowercase-lead-needs-TWO-continuations rule: under a naive lead+1 rule it reads as mojibake.
$legitNbsp  = "caf" + [char]0x00E9 + [char]0x00A0 + "au lait"

try {
    Push-Location $root
    Invoke-Git init -q
    Invoke-Git config user.email "t@t"
    Invoke-Git config user.name "t"
    Put 'README.md' "base`n"
    Invoke-Git add README.md
    Invoke-Git commit -qm base

    # ------------------------------------------------------------------------ detection + no-FP
    Put 'clean.py' "t = `"$legit`"`n"
    Check "legit UTF-8 (em-dash, accent, CJK, emoji) -> 0" ((Scan @('clean.py')) -eq 0)

    Put 'nbsp.py' "t = `"$legitNbsp`"`n"
    Check "legit accented letter + non-breaking space -> 0 (the FP that shaped the rule)" ((Scan @('nbsp.py')) -eq 0)
    Drop 'nbsp.py'

    Put 'dash.py' "t = `"$mojiDash`"`n"
    Check "double-encoded em-dash -> 73" ((Scan @('dash.py')) -eq 73)
    Drop 'dash.py'

    Put 'eacute.py' "t = `"$mojiEacute`"`n"
    Check "double-encoded e-acute (2-byte lead) -> 73" ((Scan @('eacute.py')) -eq 73)
    Drop 'eacute.py'

    Put 'cjk.py' "t = `"$mojiCJK`"`n"
    Check "double-encoded CJK -> 73 (the first detector missed this entirely)" ((Scan @('cjk.py')) -eq 73)
    Drop 'cjk.py'

    Put 'cyr.py' "t = `"$mojiCyr`"`n"
    Check "double-encoded Cyrillic -> 73 (ditto)" ((Scan @('cyr.py')) -eq 73)
    Drop 'cyr.py'

    # --------------------------------------------------------------- artifact + prose exclusion
    # Constructed so the ONLY corrupt bytes in the scanned set are in the excluded file.
    Put 'docs/progress/codex-x-1.log' "stream $mojiDash`n"
    Check "mojibake in the wrapper's OWN docs/progress log, nothing else corrupt -> 0" ((Scan) -eq 0)

    Put 'NOTES.md' "the bug looks like $mojiDash in source`n"
    Check "mojibake QUOTED in prose (.md), nothing else corrupt -> 0" ((Scan) -eq 0)

    # A legitimate source path that merely CONTAINS the segments docs/progress must NOT be excluded.
    # The first artifact regex was unanchored, so src/docs/progress/... was silently skipped.
    Put 'src/docs/progress/parser.py' "t = `"$mojiDash`"`n"
    Check "src/docs/progress/parser.py NOT excluded (regex is root-anchored) -> 73" ((Scan) -eq 73)
    Drop 'src/docs/progress/parser.py'

    # ------------------------------------------------------------------------ directory expansion
    # -Authorized may name a DIRECTORY, and git collapses a new untracked dir to "?? dir/". The first
    # cut treated both as leaf files and skipped them, so anything beneath went unscanned.
    Put 'pkg/mod/deep.py' "t = `"$mojiDash`"`n"
    Check "mojibake under an AUTHORIZED DIRECTORY -> 73" ((Scan @('pkg')) -eq 73)
    Check "mojibake under a NEW UNTRACKED DIRECTORY, unarmed -> 73" ((Scan) -eq 73)
    Drop 'pkg/mod/deep.py'

    # ------------------------------------------------------------------------------ scope boundary
    # Mojibake outside the authorized set is the scope check's business (exit 65), not this gate's.
    Put 'stray.py' "t = `"$mojiDash`"`n"
    Check "mojibake outside the authorized set -> 0 (left to the scope check)" ((Scan @('clean.py')) -eq 0)
    Drop 'stray.py'

    # -------------------------------------------------------------------------------- UTF-16 source
    # UTF-16LE .ps1 files are normal on Windows. The NUL-byte binary heuristic classified them as
    # binary and skipped them wholesale -- reporting clean on a file never read. Decode by BOM first.
    $u16 = [System.Text.Encoding]::Unicode
    $pre = [byte[]](0xFF, 0xFE)
    [System.IO.File]::WriteAllBytes((Join-Path $root 'utf16-bad.ps1'), ($pre + $u16.GetBytes("`$t = `"$mojiDash`"`n")))
    Check "mojibake in UTF-16LE source is SCANNED, not skipped as binary -> 73" ((Scan @('utf16-bad.ps1')) -eq 73)
    Drop 'utf16-bad.ps1'

    [System.IO.File]::WriteAllBytes((Join-Path $root 'utf16-ok.ps1'), ($pre + $u16.GetBytes("`$t = `"$legit`"`n")))
    Check "clean UTF-16LE source -> 0 (no false positive from the BOM path)" ((Scan @('utf16-ok.ps1')) -eq 0)
    Drop 'utf16-ok.ps1'

    # A genuine binary must still be skipped, not decoded into accidental matches.
    [System.IO.File]::WriteAllBytes((Join-Path $root 'blob.bin'), [byte[]](0x00, 0xE2, 0x80, 0x94, 0x00, 0xFF))
    Check "a genuine binary (NUL bytes, no BOM) is skipped -> 0" ((Scan @('blob.bin')) -eq 0)
    Drop 'blob.bin'

    # ------------------------------------------------------------------------------- fails CLOSED
    # An unreadable authorized file must NOT report clean. A gate that silently skips reads as a pass.
    Put 'locked.py' "t = 1`n"
    $stream = [System.IO.File]::Open((Join-Path $root 'locked.py'), 'Open', 'Read', 'None')
    try   { Check "an UNREADABLE authorized file -> 73, never a silent clean" ((Scan @('locked.py')) -eq 73) }
    finally { $stream.Dispose() }

    # An AUTHORIZED FILE THAT WAS NEVER CREATED is normal, not an error: AGENTS.md tells the coder
    # "file in spec BUT you don't need to touch it -> skip it". Failing here would fire the gate on
    # nearly every dispatch, and a gate that fires every run gets switched off.
    Check "an authorized file the coder never created -> 0 (absence is normal)" ((Scan @('never-written.py')) -eq 0)
}
finally {
    Pop-Location
    Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}

Write-Host ""
if ($fail -eq 0) { Write-Host "ALL PASS" -ForegroundColor Green; exit 0 }
Write-Host "$fail FAILED" -ForegroundColor Red
exit 1
