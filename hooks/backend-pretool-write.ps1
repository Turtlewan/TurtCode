# Planning-mode write guard (PreToolUse: Write|Edit).
# In PLANNING mode (Anthropic backend), code edits are blocked EXCEPT in the
# APEX project itself / its ~/.claude system files. Doc files (.md/.markdown/.txt)
# are always allowed. Anything else falls through to an "ask" so the user can
# grant a deliberate one-off. CODING mode (DeepSeek) never blocks.
$ErrorActionPreference = 'Stop'

# --- Coding backend (DeepSeek): never blocks ---
$url = $env:ANTHROPIC_BASE_URL
if ($url -like '*deepseek*') { exit 0 }

# --- Claude coding mode (ADR-025): the explicit APEX_MODE=coding signal on the
#     Anthropic backend relaxes the write-guard exactly like the DeepSeek backend.
#     Scoped STRICTLY to this env var — when APEX_MODE is unset (planning), every
#     line below runs unchanged, so planning-mode gating is byte-identical to before.
#     Precedence (ADR-025): `deepseek` URL wins (handled above) → APEX_MODE=coding →
#     planning. Relaxing here only when the var equals 'coding' keeps the planning
#     safety net intact. ---
if ($env:APEX_MODE -eq 'coding') { exit 0 }

# --- Read PreToolUse payload from stdin ---
$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }
try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }

$filePath = [string]$payload.tool_input.file_path
if (-not $filePath) { exit 0 }

# Normalise separators for matching (-like is case-insensitive)
$fp = ($filePath -replace '/','\')

# --- Doc files: always allowed in planning mode ---
if ($fp -match '\.(md|markdown|txt)$') { exit 0 }

# --- APEX is exempt by FILE PATH (not cwd): the apex project's own files, or
#     its ~/.claude system files. A code file anywhere else falls through to
#     "ask" even when the session's cwd happens to be the APEX project. ---
$apexRoot   = 'C:\Users\User\apex'
$claudeRoot = 'C:\Users\User\.claude'
if ($fp -like "$apexRoot\*")   { exit 0 }
if ($fp -like "$claudeRoot\*") { exit 0 }

# --- Cheap-mockup design artifacts (ADR-020 / apex-ui-ux-design cheap-mode loop):
#     logic-free view-layer mockups are an allowed planning-mode write class.
#     Any project's docs/research/mockups/ is a throwaway design scratch area. ---
if ($fp -like '*docs\research\mockups\*') { exit 0 }

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
