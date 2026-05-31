---
skill: apex-orchestrate
backend: claude
version: 1.1.3
last_updated: 2026-05-31
sources:
  - APEX Design Specification 2026-05-24
  - GSD (Get Shit Done) — github.com/gsd-build/get-shit-done
staleness_threshold: 30d
description: >
  APEX session orchestrator — runs first every session: reads docs/status.md,
  surfaces in-flight work, detects planning vs coding mode from ANTHROPIC_BASE_URL,
  sets autonomy level, and routes to apex-plan or apex-code. Also handles pause/resume.
---

# APEX Orchestrator

Run at the start of every session. Orient, route, hand off — nothing else.
You contain zero domain knowledge. All domain knowledge lives in specialist skills.

## Why this works — context rot principle

As a session grows, token windows fill and quality degrades ("context rot"). APEX prevents this by:
- Starting each specialist, worker, and agent with a fresh scoped context (~200k tokens)
- Keeping the main orchestrator window at 30–40% by delegating to subagents
- Storing decisions in persistent artifacts (docs/status.md, handoff docs) so context survives session boundaries

New agents load project vision + decisions before acting — they don't rely on conversation memory.

## Step 1: Orient

Read `docs/status.md`.

If not found:
→ Invoke apex-init first. Then return here after bootstrap completes.

Extract from docs/status.md:
- token_profile (default: balanced if missing)
- autonomy_level (default: L2 if missing)
- specialists_default (domains always active for this project)
- stack_skills (bound stack skills in play; default: [] if missing — coding reads their Verification Recipe per ADR-005/006)
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

## Step 4: Route

Match the user's message to this table. If multiple match, route to the most specific.

| Signal | Route to |
|--------|----------|
| plan / design / architect / spec / think about / let's build / what if | apex-plan |
| build / implement / code / write / execute / start build | apex-code |
| debug / investigate / root cause / broken / bug / not working | apex-debug |
| review / audit / check quality / code review | apex-review |
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

## Step 5: Load domain specialists (alongside primary route)

Scan user message + spec content for domain keywords from ~/.claude/registry/domains.md.

For each matched domain:
- In planning mode: load domain's SKILL.md into context
- In coding mode: load domain's impl.md into context

Rules:
- Multiple specialists can be active simultaneously
- Specialists do not call each other — all coordination routes through you
- Specialists may flag that another domain should be consulted; you decide whether to act
- Also activate any domain in specialists_default regardless of keywords

## Step 6: State active context

After routing, always output one line:
"Running at L{n} | Profile: {profile} | Mode: {planning/coding}"

---

## Pause Workflow — Planning Mode

Triggered when pause signal detected during a planning session.

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

## Pause Workflow — Coding Mode

Triggered when pause signal detected during a coding session.

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
"Running at L{n} | Profile: {profile} | Mode: {planning/coding}"

If user says "set level L{n}" or "run at L{n}" or "drop to L{n}":
1. Update the autonomy_level in docs/status.md
2. Confirm: "Autonomy level set to L{n}. {one-sentence summary of what this enables/restricts}"

If a spec has autonomy_level in its metadata:
→ Use that level for this build, ignoring the session default
→ Confirm: "Running spec at L{n} (overrides session default L{m})"

If user asks what level they're at: read docs/status.md and report it.

## Hard block enforcement (orchestrator level)

If a user requests any of these actions, refuse and explain — regardless of level:
- "push to main" → "This is a permanent hard block. Push to a branch and create a PR instead."
- "merge the PR" → "This is a permanent hard block. Merge via the GitHub UI after your review."
- "drop the users table" → "This is a permanent hard block. Use a migration to remove the table safely."

Log the refusal to the handoff's ## Decisions Made section.
