# Fake `codex exec` for testing codex-dispatch.ps1 end-to-end.
# Reads the prompt from STDIN -- proving stdin delivery works, which is the exact bug that just bit
# the live build ("No prompt provided via stdin" after a `< /dev/null` clobbered the pipe).
# Then misbehaves precisely as the real Codex has: writes in-scope, out-of-scope, and to status.md.
param()

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
Add-Content -Path 'src/b.py'       -Value 'codex OUT OF SCOPE'        # out, clean -> revert
Set-Content  -Path 'src/rogue.py'  -Value 'codex stray file'          # out, new   -> delete
Add-Content -Path 'docs/status.md' -Value 'codex clobbered status.md' # host owns  -> CONTESTED, never revert

Write-Output "FAKE-CODEX: done"
exit 0
