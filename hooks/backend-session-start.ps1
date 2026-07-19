# APEX SessionStart hook — single-session model (ADR-038).
#
# There is ONE mode. APEX used to detect planning vs coding from ANTHROPIC_BASE_URL / APEX_MODE and
# route to a SEPARATE session, because reaching DeepSeek required a session-level base-URL swap.
# The coder is now Codex, dispatched as a `codex exec` SUBPROCESS from any session — so that
# constraint is gone, and with it the mode split, the launchers, and the write-guard.
#
# One session plans, builds, and verifies. apex-orchestrate routes by TASK, not by session.

$ErrorActionPreference = 'Stop'

$route = @'
=== APEX SESSION ROUTING (do this FIRST) ===
Your FIRST action this session MUST be to invoke the apex-orchestrate skill via the Skill tool --
BEFORE answering the user, asking clarifying questions, or starting any task. This applies even if
the user opens with a concrete task: route first, then act.

apex-orchestrate will read docs/status.md (bootstrapping via apex-init if it is missing), surface
in-flight work, and route you to apex-plan / apex-code / apex-debug. Do not skip it and do not do
its job for it.

Once apex-orchestrate has run, BEGIN your first user-visible reply with this exact line:
[APEX] Using APEX system
That banner is the proof the orchestrator ran. If you are about to reply WITHOUT it, you skipped
apex-orchestrate -- stop and invoke it first.
'@

$policy = @'
## Session model (ADR-038): ONE session

There is no planning mode and no coding mode. This session plans, builds, and verifies. There is no
APEX_MODE, no backend swap, no relaunch, and no write-guard -- you may edit any file directly.

## The coder

Codex (`gpt-5.6-sol`) is the PRIMARY coder, dispatched PER TASK as a `codex exec` subprocess from
this session. It has its own auth and its own quota -- dispatching it is not a session switch and
spends none of the Anthropic pool. Sonnet 5 is the FALLBACK coder (a fresh `model: sonnet` worker in this
same session) when Codex quota is exhausted.

Reviews are CROSS-FAMILY (ADR-032/034): Codex builds -> Claude reviews; a Claude fallback builds -> Codex
reviews. An agent never reviews its own output.

## The three files (ADR-037)

- `~/.claude/CLAUDE.md`   -- cross-project preferences. Always loaded. <=200 lines.
- `<repo>/AGENTS.md`      -- the coder's contract for this repo: verify commands, conventions,
                             layout, hard rules. Codex reads it natively on every `codex exec`;
                             you read it before dispatching a build. <32 KiB (Codex silently
                             truncates past that, with no warning).
- `<repo>/docs/status.md` -- LIVE STATE ONLY. Rewritten, never appended. <=100 lines. A finished
                             row is DELETED, not marked done.

History lives in `git log` (what changed), `docs/handoff/` (what the build learned),
`docs/technical/adr/` (why), and memory (durable facts). Never in status.md.

## Specs

Specs are execution scripts in `docs/changes/*.md`: one-line identity, exact files per task,
step->verify acceptance criteria, no *why* inline (that lives in an ADR). Write one before a
non-trivial build; execute it; move it to `docs/changes/done/` when it passes.
'@

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

$ctx = "$route`n`n$policy$handoffContent"

$payload = @{
    hookSpecificOutput = @{
        hookEventName     = 'SessionStart'
        additionalContext = $ctx
    }
} | ConvertTo-Json -Compress -Depth 5

Write-Output $payload
