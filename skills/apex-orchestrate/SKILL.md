---
skill: apex-orchestrate
backend: claude
version: 1.7.1
last_updated: 2026-07-10
sources:
  - APEX Design Specification 2026-05-24
  - GSD (Get Shit Done) — github.com/gsd-build/get-shit-done
  - ADR-027 — Codex-primary coding, Opus fallback, DeepSeek archived
staleness_threshold: 30d
description: >
  APEX session orchestrator — runs first every session: reads docs/status.md, surfaces
  in-flight work, sets autonomy level, and routes the task to apex-plan / apex-code /
  apex-debug. One session plans and builds (ADR-038) — there are no modes. Also handles
  pause/resume.
---

# APEX Orchestrator

Run at the start of every session. Orient, route, hand off — nothing else.
You contain zero domain knowledge, and neither does APEX — it is model-native (ADR-036).
APEX carries only workflow, state, and gates.

## Context discipline

Delegate deep work to fresh-context subagents and persist decisions to artifacts
(docs/status.md, handoffs) — the main window stays lean and state survives session boundaries.

### Dispatch return contract (invariant — ADR-015)

The fork boundary protects the main window only if children return *small*. Every dispatched
child gets a **bounded return contract**:
- A child that explores widely (research, stocktake, any deep/exploratory dispatch) **writes its
  full output to disk and returns only a ≤1–2k-token summary or a pointer** — never its raw
  working output.
- A child that produces a verdict/status (workers, reviewers, council voices) returns the **fixed
  structured shape** its dispatcher specified, nothing more.

The orchestrator never absorbs a child's full transcript. This is a named dispatch invariant
alongside *evaluator-independence* (apex-governance) — preserve it for any new dispatch site.

### Strategic compaction — compact at phase boundaries, not arbitrary thresholds

Auto-compaction fires at an arbitrary % and often mid-task, losing live state. For the *main*
session, prefer a deliberate `/compact` at a logical boundary instead:

- **Compact after** research→planning, planning→implementation, a completed milestone, or a
  failed/dead-end approach (clear the wrong reasoning before retrying).
- **Don't compact mid-implementation** — losing file paths, names, and partial state is costly.
- **Safe to compact because these survive:** CLAUDE.md, the In-Flight / status.md, handoff docs,
  memory files, git state, files on disk. **Lost:** intermediate reasoning, prior file reads, tool
  history. So **write durable state to its artifact first**, then compact. (From ECC `strategic-compact`.)

## Step 1: Orient

Read `docs/status.md`.

If not found:
→ Invoke apex-init first. Then return here after bootstrap completes.

Extract from docs/status.md:
- token_profile (default: balanced if missing)
- autonomy_level (default: L2 if missing)
- In-Flight table (any interrupted sessions)

## Step 2: Surface in-flight work

If In-Flight table has any rows:
"You were in the middle of [what] ([state]). Want to continue, or set it aside?"

Wait for response. If "continue" → follow resume workflow below.
If "set aside" → clear that row from In-Flight, continue normally.

## Step 3: Detect pause/resume signals

Pause signals: "stopping for now", "pausing", "I'll continue later", "taking a break", "pause here", "stopping", "pause"

Resume signals: "resuming", "picking up", "continue where we left off", "back", "let's continue", "where were we", "resume build", "resume"

On pause → run pause workflow for current mode (see below).
On resume → read In-Flight table, surface what was in progress, continue.

## Step 3.5: (removed — there are no modes)

APEX used to detect planning vs coding from `ANTHROPIC_BASE_URL` + `APEX_MODE` and route to a
**separate session**. That existed for one reason: reaching DeepSeek required a session-level
base-URL swap, so the coder was physically unreachable from a planning session.

**The coder is Codex, dispatched as a `codex exec` subprocess** — reachable from any session, on its
own auth and quota. The constraint is gone, so **the mode split is gone with it** (ADR-038). One
session plans, builds, and verifies. There is no `APEX_MODE`, no backend swap, no relaunch, and no
write-guard.

Route by **task** (Step 4), not by session.

## Step 4: Route

Match the user's message to this table. If multiple match, route to the most specific.

| Signal | Route to |
|--------|----------|
| plan / design / architect / spec / think about / let's build / what if | apex-plan |
| build / implement / code / write / execute / start build | apex-code |
| debug / investigate / root cause / broken / bug / not working | apex-debug |
| review this spec / review the plan | apex-plan (dispatched spec review) |
| code review / audit built code | dispatch the `apex-reviewer` agent on the changed files (advisory — there is no standalone review skill) |
| audit the skills / skill stocktake | apex-refresh (--stocktake) |
| deep dive / research deeply / explore options | apex-deep-dive |
| refresh / update skill / knowledge is stale | apex-refresh |
| next / what's next / next step / what should I work on / where are we | auto-detect (see below) |

If ambiguous: ask one clarifying question before routing. Never guess.

### Auto-detect next step

When signal matches "next / what's next / what should I work on":
1. Read docs/status.md
2. If In-Flight table has rows → surface those first: "You were mid-build on {spec}. Continue?"
3. Else if docs/changes/ has ready specs → "Your next step: build {spec-name}"
4. Else if docs/drafts/ has in-progress specs → "You have an unfinished spec: {name}. Finish it?"
5. Else → "Nothing queued. What do you want to plan next?"

## Step 5: (removed — there is no domain-specialist layer)

APEX shipped 36 domain skills (security, frontend, k8s, auth, …) and a keyword registry that
loaded them. **Both were deleted on 2026-07-14 (ADR-036).** They encoded knowledge a frontier model
already has, and the keyword table duplicated Claude Code's own description-matching.

Do not scan for domain keywords. Do not look for `~/.claude/registry/domains.md` — it is gone. Do
not re-create either; if a domain genuinely needs a rule the model lacks, that is a bug report
against the model's output, and it belongs in the project's own `AGENTS.md` or a spec — not in a
new global skill (see apex-skill-author § The Iron Law).

**Domain expertise still happens** — it just isn't loaded from a file:
- **Drafting:** the model applies it directly.
- **Review:** `apex-plan` dispatches `apex-spec-reviewer` in a fresh context (optionally with a
  `lens`, e.g. "security"); `apex-code` dispatches `apex-wave-reviewer` after high-risk waves. The
  value there is **evaluator-independence**, not a rulebook — a fresh adversarial reader, not a
  checklist. Cross-family routing holds (Codex builds → Claude reviews; ADR-032/034).

## Step 6: State active context

After routing, always output one line:
"Running at L{n} | Coder: Codex `gpt-5.6-sol` (Opus fallback)"

---

## Pause Workflow — mid-plan

Triggered by a pause signal while drafting a spec.

1. Save current draft to docs/drafts/{spec-name}.md
   Add a ## Where I stopped section at the bottom:
   ```
   ## Where I stopped
   - Decision reached: {what was agreed}
   - Next question to resolve: {what comes next}
   - Open items: {list}
   ```
2. Update docs/status.md In-Flight table:
   | {spec-name} | planning | 📋 draft | docs/drafts/{spec-name}.md | "{next open item}" | — |
3. Confirm to user:
   "Draft saved to docs/drafts/{spec-name}.md. Say 'resuming' next time and I'll pick up from: {next open item}."

---

## Pause Workflow — mid-build

Triggered by a pause signal while executing a spec.

1. Complete the current task — never stop mid-task
2. Update ## Progress checkboxes in the spec (check completed tasks)
3. Run git status — identify uncommitted changes
4. Update docs/status.md In-Flight table:
   | {spec-name} | coding | 🔄 in-progress | docs/changes/{spec-name}.md | task {n}/{total} | {comma-separated uncommitted files} |
5. Confirm to user:
   "Paused after task {n}/{total}. Uncommitted changes: {files}. Say 'resume build' to continue."

---

## Routing notes

- "start build [spec-name]" → apex-code with that specific spec
- "start build" with no spec → apex-code reads docs/changes/ and picks the first ready spec, confirms with user
- A spec in docs/drafts/ is NOT ready — surface it and ask if user wants to finish it first
- A spec in docs/changes/ IS ready — can be built immediately

## Rate limit / quota recovery

If Claude Code hits a rate limit or quota cap mid-session:
1. Complete the current atomic task if possible — never stop mid-task
2. Run the pause workflow for the active mode
3. The In-Flight table captures the exact stopped position
4. When quota resets, say "resume" — APEX reads the checkpoint and continues from where it stopped

No manual state tracking needed. The In-Flight table is the checkpoint.

---

## Governance rules

At every session start, state the active level:
"Running at L{n} | Coder: Codex `gpt-5.6-sol` (Opus fallback)"

If user says "set level L{n}" or "run at L{n}" or "drop to L{n}":
1. Update the autonomy_level in docs/status.md
2. Confirm: "Autonomy level set to L{n}. {one-sentence summary of what this enables/restricts}"

If a spec has autonomy_level in its metadata:
→ Use that level for this build, ignoring the session default
→ Confirm: "Running spec at L{n} (overrides session default L{m})"

If user asks what level they're at: read docs/status.md and report it.

## Hard block enforcement (orchestrator level)

**apex-governance owns the canonical hard-block list** — consult it; never maintain a separate
copy here. Most-hit examples (refuse and explain, regardless of level):
- "push to main" → "This is a permanent hard block. Push to a branch and create a PR instead."
- "merge the PR" → "This is a permanent hard block. Merge via the GitHub UI after your review."
- "drop the users table" → "This is a permanent hard block. Use a migration to remove the table safely."

Log the refusal to the handoff's ## Decisions Made section.
