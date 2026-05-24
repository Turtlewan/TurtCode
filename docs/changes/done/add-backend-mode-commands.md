# Add `coding-mode` / `planning-mode` PowerShell commands

**Status:** PENDING — execute in a DeepSeek (coding-mode) session.

## 1. Scope

Add two PowerShell functions (`coding-mode` and `planning-mode`) plus a helper (`backend-status`) to the user's PowerShell profile. They wrap `claude` with the correct `ANTHROPIC_BASE_URL` and `ANTHROPIC_API_KEY` so the user doesn't have to set env vars manually each time. API keys are read from persistent Windows user env vars set once via `setx`.

The DeepSeek key lives in `DEEPSEEK_API_KEY`. The Anthropic key lives in `ANTHROPIC_API_KEY_PLANNING` (a separate var so it doesn't conflict with the live `ANTHROPIC_API_KEY` the wrappers set at runtime).

## 2. Files to change

- **Create:** `C:\Users\User\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`
  - Parent directory `C:\Users\User\Documents\WindowsPowerShell` already exists.
  - File currently does not exist (`Test-Path $PROFILE` → False).

## 3. Exact changes

Write the following content to `$PROFILE` verbatim:

```powershell
function coding-mode {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ClaudeArgs)

    if (-not $env:DEEPSEEK_API_KEY) {
        Write-Host "ERROR: DEEPSEEK_API_KEY is not set." -ForegroundColor Red
        Write-Host "Set it once with:" -ForegroundColor Yellow
        Write-Host '  setx DEEPSEEK_API_KEY "sk-..."'
        Write-Host "Then open a new shell."
        return
    }

    $env:ANTHROPIC_BASE_URL = 'https://api.deepseek.com/anthropic'
    $env:ANTHROPIC_API_KEY  = $env:DEEPSEEK_API_KEY

    Write-Host "==> CODING mode (DeepSeek backend)" -ForegroundColor Cyan
    Write-Host "    ANTHROPIC_BASE_URL = $env:ANTHROPIC_BASE_URL"
    & claude @ClaudeArgs
}

function planning-mode {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ClaudeArgs)

    if (-not $env:ANTHROPIC_API_KEY_PLANNING) {
        Write-Host "ERROR: ANTHROPIC_API_KEY_PLANNING is not set." -ForegroundColor Red
        Write-Host "Set it once with:" -ForegroundColor Yellow
        Write-Host '  setx ANTHROPIC_API_KEY_PLANNING "sk-ant-..."'
        Write-Host "Then open a new shell."
        return
    }

    Remove-Item Env:ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
    $env:ANTHROPIC_API_KEY = $env:ANTHROPIC_API_KEY_PLANNING

    Write-Host "==> PLANNING mode (Anthropic backend)" -ForegroundColor Cyan
    Write-Host "    ANTHROPIC_BASE_URL = (unset - default Anthropic)"
    & claude @ClaudeArgs
}

function backend-status {
    $url = $env:ANTHROPIC_BASE_URL
    if (-not $url) { $url = '(unset - default Anthropic)' }
    $mode = if ($url -like '*deepseek*') { 'CODING (DeepSeek)' } else { 'PLANNING (Anthropic)' }
    Write-Host "ANTHROPIC_BASE_URL = $url"
    Write-Host "Mode               = $mode"
}
```

Notes for the executor:
- The PowerShell hook PreToolUse will allow this Write because the executor is on DeepSeek.
- Use `Write` (not `Edit`) since the file does not currently exist.
- Preserve exact quoting — the single-quoted strings around `setx` examples are intentional so `$env:` doesn't expand inside the help text.

## 4. Acceptance criteria

After execution, the user should be able to:

1. Open a new PowerShell session and verify the functions exist:
   ```powershell
   Get-Command coding-mode, planning-mode, backend-status
   ```
   All three should return `Function` entries.

2. Run `backend-status` and see the current backend reported.

3. Run `coding-mode` (with `DEEPSEEK_API_KEY` set) and confirm:
   - The cyan "==> CODING mode" banner appears.
   - `claude` launches.
   - Once inside Claude, the SessionStart hook context confirms DeepSeek is active.

4. Run `planning-mode` (with `ANTHROPIC_API_KEY_PLANNING` set) and confirm the equivalent for Anthropic.

5. Without the relevant key set, the command exits with a red error and the `setx` instruction — does NOT launch claude.

## 5. Commands to run

```powershell
# After the file is written, dot-source it in the current shell to test without restarting:
. $PROFILE

# Then verify:
Get-Command coding-mode, planning-mode, backend-status
backend-status
```

No build/test/lint steps — this is a profile script.

## 6. Risks / open questions

- **Existing `$PROFILE`**: This spec assumes `$PROFILE` does not exist (verified at spec time). If it does exist when the executor runs, **append** the functions rather than overwriting — re-read the file first and merge.
- **Execution policy**: If `Get-ExecutionPolicy` returns `Restricted`, the profile won't load. The executor should check and, if needed, advise the user to run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.
- **Key var naming**: Chose `ANTHROPIC_API_KEY_PLANNING` instead of `ANTHROPIC_API_KEY` to avoid colliding with the live var the wrappers set. If the user prefers reusing `ANTHROPIC_API_KEY` directly (and accepting that DeepSeek mode will overwrite it for the rest of the parent shell), simplify both functions accordingly.
- **`claude` resolution**: Both functions call `& claude @ClaudeArgs`. Assumes `claude` is on PATH. If the user installs via a different mechanism, swap in the absolute path.

## 7. One-time setup the user must do before the commands work

This is on the user, not the executor:

```powershell
# Set DeepSeek key
setx DEEPSEEK_API_KEY "sk-deepseek-..."

# Set Anthropic key (use a name that won't collide with the live var)
setx ANTHROPIC_API_KEY_PLANNING "sk-ant-..."

# Close and reopen PowerShell so the new env vars are visible.
```
