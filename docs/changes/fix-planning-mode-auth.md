# Fix coding-mode model + planning-mode auth

**Status:** PENDING — execute in a DeepSeek (coding-mode) session.

## 1. Scope

Two fixes to the PowerShell profile functions:

1. `coding-mode` — add `--model deepseek-chat` so Claude Code uses the correct model instead of defaulting to Opus 4.7.
2. `planning-mode` — remove the `ANTHROPIC_API_KEY_PLANNING` requirement and instead unset `ANTHROPIC_API_KEY`, letting Claude Code fall back to the stored claude.ai login.

## 2. Files to change

- `C:\Users\User\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`

## 3. Exact changes

Replace the entire `coding-mode` function with:

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
    & claude --model deepseek-chat @ClaudeArgs
}
```

Replace the entire `planning-mode` function with:

```powershell
function planning-mode {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ClaudeArgs)

    Remove-Item Env:ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
    Remove-Item Env:ANTHROPIC_API_KEY  -ErrorAction SilentlyContinue

    Write-Host "==> PLANNING mode (claude.ai login)" -ForegroundColor Cyan
    Write-Host "    ANTHROPIC_BASE_URL = (unset - default Anthropic)"
    & claude @ClaudeArgs
}
```

Leave `backend-status` unchanged.

## 4. Acceptance criteria

1. `coding-mode` launches Claude showing `deepseek-chat` in the header (not Opus 4.7).
2. `planning-mode` launches Claude using the stored claude.ai login — no API key required.
3. `backend-status` still works correctly.

## 5. Commands to run

After editing, dot-source the profile to reload in the current shell:

```powershell
. $PROFILE
```

## 6. Risks / open questions

- None.
