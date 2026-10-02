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

**That is a harness fact, not a licence.** "No write-guard" means nothing mechanically blocks a
write; ADR-045 still governs what the host *does*: the host reasons, plans, and challenges, and
makes no mechanical edits and writes no code. Host bookkeeping writes -- `docs/status.md`, the
handoff, known-limits, ADR back-fills, memory -- are state-keeping, not build work, and remain the
host's job. Everything else dispatches.

## Model routing (ADR-045)

| Role | Who |
|------|-----|
| Host -- reason, plan, challenge only | this session (Opus 5.5, medium effort). Dispatches everything below; makes no mechanical edits and writes no code. |
| Spec author | gpt-6-sol via the wrapper's `-AuthorSpec` (apex-plan, Writing the spec; ADR-048) |
| Build orchestrator | Opus 5.5 -- the dispatched `apex-build-orchestrator` agent owns the BUILD PHASE of an ATTENDED build: task selection, wave sequencing, dispatch parameters, exit-code routing, verify adjudication, integration order (owner amendment 2026-07-29; v1 shipped 2026-08-02). Close-out and unattended/AFK builds stay HOST-executed per `~/.claude/skills/apex-code/SKILL.md`. |
| Coder | Codex `gpt-5.6-sol` -- dispatched per task as a `codex exec` subprocess (own auth, own quota; spends none of the Anthropic pool). Fallback on quota-out: Sonnet 5. |
| Checker | Claude `apex-critic` serves both `mode: spec` and `mode: code`. Every Agent tool dispatch passes `model: sonnet` for Low, Medium, and doc-only reviews or `model: opus` for High; the Agent tool's `model:` parameter takes precedence over the agent file's default frontmatter `model: sonnet`. Both Sol reads (the pre-draft architecture pass and post-readiness cold read) run only for Deep Details specs at Medium or High risk; Low, doc-only, Light, and Bug Fix skip them. Codex-built code gets no extra Sol cross-family pass. An agent never reviews its own output. |

The session model is Opus 5.5 at medium effort. A dispatch that omits
`model:` inherits it -- always pin the model explicitly; never use fork-type subagents for
mechanical work (forks always inherit the session model).

Tightened 2026-07-29 (ADR-046 D1): the host's build-time role is mechanics only -- launching and
monitoring subprocesses strictly from the orchestrator's wave plan, executing the git operations it
directs (worktree commit, path-scoped integration, the user-approved per-spec commit), and
returning status/exit codes. Task selection, sequencing, routing, verification adjudication, and retries are orchestrator-owned. V1 (shipped 2026-08-02): on an ATTENDED build those duties run inside the dispatched `apex-build-orchestrator` agent, which emits one directive per turn and executes nothing; CLOSE-OUT -- the review chain, the docs agents, the family gate, spec archival -- is HOST-executed per `~/.claude/skills/apex-code/SKILL.md` and is not in that agent's protocol; and an UNATTENDED/AFK build keeps the current host path until v2.

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
