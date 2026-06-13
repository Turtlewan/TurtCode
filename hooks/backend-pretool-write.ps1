# Planning-mode write guard (PreToolUse: Write|Edit).
# In PLANNING mode (Anthropic backend), code edits are blocked EXCEPT in the
# APEX project itself / its ~/.claude system files. Doc files (.md/.markdown/.txt)
# are always allowed. Anything else falls through to an "ask" so the user can
# grant a deliberate one-off. CODING mode (DeepSeek) never blocks.
$ErrorActionPreference = 'Stop'

# --- Coding backend (DeepSeek): never blocks ---
$url = $env:ANTHROPIC_BASE_URL
if ($url -like '*deepseek*') { exit 0 }

# --- Read PreToolUse payload from stdin ---
$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }

$filePath = [string]$payload.tool_input.file_path
$cwd      = [string]$payload.cwd
if (-not $cwd) { $cwd = (Get-Location).Path }
if (-not $filePath) { exit 0 }

# Normalise separators for matching (-like is case-insensitive)
$fp = ($filePath -replace '/','\')
$wd = ($cwd -replace '/','\')

# --- Doc files: always allowed in planning mode ---
if ($fp -match '\.(md|markdown|txt)$') { exit 0 }

# --- APEX is exempt: the apex project, or its ~/.claude system files ---
$apexRoot   = 'C:\Users\User\apex'
$claudeRoot = 'C:\Users\User\.claude'
if ($wd -eq $apexRoot -or $wd -like "$apexRoot\*") { exit 0 }
if ($fp -like "$claudeRoot\*")                     { exit 0 }

# --- Otherwise: planning mode editing a code file outside APEX -> ask ---
$reason = "Planning mode (Anthropic backend). DEFAULT: throw this to a DeepSeek coding session -- '$filePath' is a non-doc file outside the APEX project, and code edits belong in coding mode. Approve this prompt ONLY to explicitly request the special planning-mode edit for this one action."
$out = @{
  hookSpecificOutput = @{
    hookEventName            = 'PreToolUse'
    permissionDecision       = 'ask'
    permissionDecisionReason = $reason
  }
} | ConvertTo-Json -Compress -Depth 5
Write-Output $out
exit 0
