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

## Session model (ADR-038): ONE session

There is no planning mode and no coding mode. This session plans, builds, and verifies. There is no
APEX_MODE, no backend swap, no relaunch, and no write-guard -- you may edit any file directly.

## Model routing (ADR-045)

| Role | Who |
|------|-----|
| Host -- reason, plan, challenge only | this session (Fable 5). Dispatches everything below; makes no mechanical edits and writes no code. |
| Spec author | Opus -- a `model: opus` worker drafts specs/ADRs from the host's plan |
| Build orchestrator | Sonnet -- a `model: sonnet` worker runs waves, dispatches coders, routes exit codes |
| Coder | Codex `gpt-5.6-sol` -- dispatched per task as a `codex exec` subprocess (own auth, own quota; spends none of the Anthropic pool). Fallback on quota-out: Sonnet 5. |
| Checker | cross-family, both directions (ADR-032/034) -- Codex checks the host's plans/specs; Claude reviews Codex's code. An agent never reviews its own output. |

The session model is Fable 5 (expensive, capped share of the weekly pool). A dispatch that omits
`model:` inherits it -- always pin the model explicitly; never use fork-type subagents for
mechanical work (forks always inherit the session model).

## The three files (ADR-037)

- `~/.claude/CLAUDE.md`   -- cross-project preferences. Always loaded. <=200 lines.
- `<repo>/AGENTS.md`      -- the coder's contract for that repo: verify commands, conventions,
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
