# Planning-mode write guard (PreToolUse: Write|Edit).
# In PLANNING mode (Anthropic backend), code edits are blocked EXCEPT in the
# APEX project itself / its ~/.claude system files. Doc files (.md/.markdown/.txt)
# are always allowed. Anything else falls through to an "ask" so the user can
# grant a deliberate one-off. CODING mode (DeepSeek) never blocks.
$ErrorActionPreference = 'Stop'

# --- Coding backend (DeepSeek): never blocks. ARCHIVED (ADR-027) — DeepSeek is parked, so this
#     branch is inert/recovery-only; the Opus fallback coder runs via APEX_MODE=coding below. ---
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

# --- AFK bypass (ADR-033): when AFK is armed, stand down and defer to afk-gate.js's own
#     critical-file judgment -- UNLESS this target is itself critical, in which case this
#     guard's ask still applies (defense in depth; afk-gate.js falls through on critical
#     paths too, so the two must agree or a critical file loses ask coverage entirely).
#     This is what makes AFK mode-independent (works armed in a planning-mode session, not
#     just coding-mode) instead of being silently overridden by this hook's "ask". ---
function Test-AfkArmed {
  $flagPath = Join-Path $env:USERPROFILE '.claude\afk.on'
  if (-not (Test-Path $flagPath)) { return $false }
  $token = $null; $expires = $null
  Get-Content $flagPath | ForEach-Object {
    if ($_ -match '^\s*token\s*=\s*(.+)$')   { $token   = $Matches[1].Trim() }
    if ($_ -match '^\s*expires\s*=\s*(.+)$') { $expires = $Matches[1].Trim() }
  }
  if (-not $token -or -not $expires) { return $false }
  try { $expiresAt = [DateTime]::Parse($expires, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal) }
  catch { return $false }
  return $expiresAt -gt (Get-Date).ToUniversalTime()
}

function Test-AfkCriticalPath {
  param([string]$Normalized)
  $basename = Split-Path $Normalized -Leaf
  if ($basename -match '\.env(\..*)?$')                       { return $true }
  if ($Normalized -match '(^|\\)migrations(\\|$)')             { return $true }
  if ($Normalized -match '(^|\\)alembic\\versions(\\|$)')      { return $true }
  if ($Normalized -match 'auth' -or $Normalized -match 'guard') { return $true }
  if ($Normalized -match '(^|\\)\.github\\workflows(\\|$)')    { return $true }
  if ($basename -eq '.gitlab-ci.yml')                          { return $true }
  if ($Normalized -match '(^|\\)\.circleci(\\|$)')             { return $true }
  if ($basename -match '^azure-pipelines')                     { return $true }
  $manifests = @('package.json','package-lock.json','pnpm-lock.yaml','yarn.lock',
    'pyproject.toml','poetry.lock','cargo.toml','cargo.lock','go.mod','go.sum')
  if ($manifests -contains $basename -or $basename -match '^requirements.*\.txt$') { return $true }
  if ($basename -eq '.npmrc' -or $basename -eq '.netrc')       { return $true }
  if ($Normalized -match '(^|\\)\.ssh(\\|$)')                  { return $true }
  if ($basename -match '^id_rsa' -or $basename -match '\.(pem|key)$') { return $true }
  if ($Normalized -match 'secret' -or $Normalized -match 'credential') { return $true }
  if ($Normalized -match '(^|\\)\.claude\\hooks(\\|$)')                { return $true }
  if ($basename -eq 'settings.json' -and $Normalized -match '\\\.claude\\') { return $true }
  return $false
}

if (Test-AfkArmed) {
  $normalized = $fp.ToLowerInvariant()
  if (-not (Test-AfkCriticalPath $normalized)) { exit 0 }
}

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
