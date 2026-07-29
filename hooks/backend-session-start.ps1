# APEX SessionStart hook — single-session model (ADR-038).
#
# One session plans, builds, and verifies; apex-orchestrate routes by TASK, not by session.
#
# The injected session contract (routing, model roles, three files, specs) lives in
# apex-session-context.md next to this script — edit THAT file, not this one. This script only
# reads it and appends the latest handoff. The markdown file is the single home for session
# mechanics; ~/.claude/CLAUDE.md holds only cross-project preferences (2026-07-29 A+ split).

$ErrorActionPreference = 'Stop'

$ctxFile = Join-Path $PSScriptRoot 'apex-session-context.md'
$static = Get-Content $ctxFile -Raw

# --- Surface the latest handoff, if any ------------------------------------------------------
$handoffContent = ''
$handoffDir = Join-Path (Get-Location) 'docs/handoff'
if (Test-Path $handoffDir) {
    $latest = Get-ChildItem $handoffDir -Filter '*.md' -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) {
        $body = Get-Content $latest.FullName -Raw -ErrorAction SilentlyContinue
        $handoffContent = "`n`n---`n## Latest handoff ($($latest.Name)) -- drain it this session`n`n$body"
    }
}

$ctx = "$static$handoffContent"

$payload = @{
    hookSpecificOutput = @{
        hookEventName     = 'SessionStart'
        additionalContext = $ctx
    }
} | ConvertTo-Json -Compress -Depth 5

Write-Output $payload
