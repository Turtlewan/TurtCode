$ErrorActionPreference = 'Stop'

$url = $env:ANTHROPIC_BASE_URL
if (-not $url) { $url = '(unset - default Anthropic)' }
$isDeepSeek = $url -like '*deepseek*'
# Mode precedence (ADR-025): `deepseek` URL wins -> DeepSeek coding; else APEX_MODE=coding
# -> Claude coding; else planning. Claude coding is only considered on a non-DeepSeek backend.
$isClaudeCoding = (-not $isDeepSeek) -and ($env:APEX_MODE -eq 'coding')

$handoffContent = ''

if ($isDeepSeek) {
    $mode = 'CODING'
    $backend = 'DeepSeek'
    $model = $env:ANTHROPIC_MODEL
    if ($model -and $model -like '*pro*') { $coderTier = 'pro' } else { $coderTier = 'flash' }
    $policy = @"
Mode: CODING (DeepSeek backend -- ARCHIVED, ADR-027: DeepSeek is parked; primary coder is Codex. This branch is inert / recovery-only.)
Coder tier: $coderTier (ANTHROPIC_MODEL: $(if ($model) { $model } else { '(unset - default flash)' }))
You MAY: edit source code, run build/test/lint commands, complete implementation tasks.
You SHOULD: look for technical change specs in docs/changes/*.md (or wherever the user keeps them) and execute them. After completing each spec, update its status (e.g., mark Done at top, or move the file to docs/changes/done/).
"@
} elseif ($isClaudeCoding) {
    # Claude coding mode (ADR-025/027) — the OPUS FALLBACK coder path. Anthropic backend +
    # APEX_MODE=coding. Codex (gpt-5.6-terra) is the PRIMARY coder, dispatched per task as a
    # `codex exec` subprocess from this host; Opus builds inline only when Codex quota is out.
    $coderTier = ''
    $mode = 'CODING'
    $backend = 'Anthropic (Claude coding mode -- Codex primary coder)'
    $model = $env:ANTHROPIC_MODEL
    $coderModel = if ($model) { $model } else { 'Sonnet 5 (default host -- ADR-032; set via /model or ANTHROPIC_MODEL)' }
    $policy = @"
Mode: CODING (Claude coding mode -- Anthropic backend + APEX_MODE=coding)
Host model: $coderModel. The host orchestrates dispatch and runs the verify loop (ADR-032). Codex (gpt-5.6-terra) is the primary coder, dispatched per task via `codex exec`; verify-fail escalation and the Opus quota-out fallback are handled per apex-code section Model fallback. No backend swap.
You MAY: edit source code, run build/test/lint commands, complete implementation tasks. The planning write-guard is relaxed in this mode.
You SHOULD: look for technical change specs in docs/changes/*.md and execute them, same as any coding session. After completing each spec, update its status (mark Done at top, or move it to docs/changes/done/).
SOFT POOL GUARD (ADR-027, scoped to the Opus fallback only -- Sonnet hosting draws a separate bucket): Opus building draws the SAME scarce Max weekly pool as planning, with NO programmatic cap. Treat an Opus-fallback build as a budgeted exception -- prefer parking or splitting the build over draining the shared pool, surface remaining planning headroom before a large fallback build, and track usage via /status. Mode discipline, not a hard block.
"@
} else {
    $coderTier = ''
    $mode = 'PLANNING'
    $backend = 'Anthropic (Opus or other Claude model)'
    $policy = @"
Mode: PLANNING (Anthropic backend)
You SHOULD NOT routinely edit source code files. The PreToolUse hook gates Write/Edit on non-.md files behind an APPROVAL PROMPT (permissionDecision 'ask' -- not a hard block); the APEX project + ~/.claude pass silently. Default: defer code edits to a coding session (APEX_MODE=coding; Codex-primary -- ADR-027).
You SHOULD: produce technical change specs as Markdown files under docs/changes/<short-name>.md. A spec is an execution script, not a design doc â€” rich on the *what*, stripped of the *why*. Each spec must include:
  1. Identity: one line â€” what this builds (+ optional ADR/discussion link). No rationale paragraph; no *why* inline.
  2. Files to change: full paths; every task names its exact files.
  3. Exact changes: code-level detail (signatures, new functions, modifications). Pseudocode or full snippets.
  4. Acceptance criteria: step -> verify, one runnable check per task.
  5. Commands to run: build, test, lint.
Resolve all risks/open questions before the spec is ready -- do not include a Risks section.
A later coding session (Codex-primary) will execute these specs.

(apex-orchestrate -> apex-plan will summarise the latest handoff doc, injected below, and list any pending specs in docs/changes/. Let the skill drive this -- do not pre-empt it.)
"@

    # Look for the latest handoff doc in the current project
    $handoffDir = Join-Path (Get-Location) 'docs/handoff'
    if (Test-Path $handoffDir) {
        $latest = Get-ChildItem $handoffDir -Filter '*.md' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
            $handoffContent = "`n`n---`n## Latest handoff doc: $($latest.Name)`n`n" + (Get-Content $latest.FullName -Raw)
        }
    }
    if (-not $handoffContent) {
        $handoffContent = "`n`n---`n## No handoff doc found`nThis appears to be a new project or the first planning session. No prior build context available."
    }
}

$route = @"
=== APEX SESSION ROUTING (do this FIRST) ===
Your FIRST action this session MUST be to invoke the apex-orchestrate skill via the Skill tool -- BEFORE answering the user, asking clarifying questions, or starting any task. This applies even if the user opens with a concrete task: route first, then act.
apex-orchestrate will read docs/status.md (bootstrapping a new project via apex-init if it is missing), surface any in-flight work, confirm the backend/mode below, and route you to apex-plan or apex-code. Do not skip it and do not do its job for it.
Once apex-orchestrate has run, BEGIN your first user-visible reply with this exact line so it is visible that APEX is active:
[APEX] Using APEX system -- $mode mode
This banner is the proof the orchestrator ran. If you are about to reply WITHOUT it, you skipped apex-orchestrate -- stop and invoke it first.
"@

$tierLine = if ($coderTier) { "`n## coder_tier: $coderTier" } else { '' }
$ctx = "$route`n## Active LLM backend: $backend`n## ANTHROPIC_BASE_URL: $url$tierLine`n`n$policy$handoffContent"

$payload = @{
    hookSpecificOutput = @{
        hookEventName     = 'SessionStart'
        additionalContext = $ctx
    }
} | ConvertTo-Json -Compress -Depth 5

Write-Output $payload
