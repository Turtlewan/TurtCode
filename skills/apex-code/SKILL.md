---
skill: apex-code
backend: claude
version: 1.8.0
last_updated: 2026-06-02
sources:
  - APEX Design Specification 2026-05-24
  - GSD (Get Shit Done) — github.com/gsd-build/get-shit-done
  - docs/technical/adr/ADR-006-buildability-layer-verification-inversion.md
  - docs/technical/adr/ADR-010-multi-pass-review.md
staleness_threshold: 30d
description: >
  APEX coding-mode workflow (DeepSeek) — executes docs/changes/ specs: session start,
  AFK build vs edit mode, Karpathy pre-flight, wave-parallel dispatch, fork routing,
  and the stack-agnostic recipe-driven verify loop (reads the stack_skills Verification
  Recipe, runs it per task, recovers on failure). Loads when building/executing a spec.
---

# APEX Coding Workflow

You are in coding mode (DeepSeek). Execute specs from docs/changes/ silently
and completely. Questions belong in planning — execution is silent.

## Session start

1. Run `git log --oneline -10` — see what landed recently without loading prose docs
2. Read docs/status.md — check In-Flight table; note token_profile, autonomy_level, and `stack_skills` (the bound stack skills, in the top frontmatter). Stop at the CODING block; do not read the PLANNING block.
3. List docs/changes/*.md — these are ready specs
4. Report: "Stack: {stack_skills or 'none'}. Ready specs: {list or 'none'}. In-progress: {spec name and progress, or 'none'}."

**Context discipline:** When executing a spec, read only that spec and the files it explicitly lists.
Never load docs/handoff/, other pending specs, or ambient project documentation.

If no ready specs: "No specs in docs/changes/. Switch to planning mode to create one."

## Two execution modes

### AFK Build Mode

Triggered by: "start build", "start build {spec-name}", "build {spec-name}", "run {spec-name}"

Pre-flight:
1. Read the full spec — every section
2. Read token_profile and autonomy_level from spec metadata
   (falls back to docs/status.md, then registry defaults)
3. Read ## Permissions section — this is the complete list of permitted actions
4. Pre-authorise all listed operations for this session
5. Package legitimacy check: for any new packages introduced by this spec,
   verify the name is correct (typosquat check) and the package is actively maintained.
   If uncertain: log to Blocked Actions, do not install, flag for human review.

6. **Karpathy Pre-Flight** — runs before any task is started:

   **a. Assumption verification (Think Before Coding)**
   Read every item in `## Assumptions`. For each:
   - Verify it against the codebase now (read the relevant file or run a check command)
   - If assumption holds → proceed
   - If assumption is wrong AND impact is `Stop` → halt, log to decisions table, report to user:
     "Pre-flight failed: assumption '{X}' is wrong. Spec needs revision. Stopping build."
   - If assumption is wrong AND impact is `Caution` → log to decisions table, note the deviation, proceed
   - If assumption is wrong AND impact is `Low` → log, proceed
   - If ## Assumptions section is missing → note it in decisions log, proceed (spec was written before this rule)

   **b. Simplicity sweep (Simplicity First)**
   For each task in ## Tasks, before implementing:
   - Estimate: could this task be done with significantly less code than the spec implies?
   - If yes: implement the simpler version. Log the decision:
     "Task N: simplified from [spec approach] to [simpler approach] — same acceptance criteria met."
   - Simpler is always preferred if acceptance criteria are still satisfied.
   - If spec says 200 lines and 50 lines does the job: write 50. Document why.

   **c. Surgical scope lock (Surgical Changes)**
   List every file you intend to touch. Cross-reference against ## Files to Change.
   - File in spec AND you need to touch it → proceed
   - File NOT in spec AND you need to touch it → log to blocked actions, do NOT touch it,
     flag in handoff as "needed but out of spec scope"
   - File in spec BUT you don't need to touch it → skip it (don't touch files that don't need changing)
   This scope lock persists for the entire build. Re-check before touching any file.

   **d. Per-task done-criteria (Goal-Driven Execution)**
   Before starting each task, state the done-criteria from the spec's "done when:" clause.
   If "done when:" is missing from the task: derive it from the acceptance criteria.
   After completing the task: verify the criterion before checking it off. No exceptions.
   "The task is done when it's verified, not when the code is written."

7. **Wave Analysis** — runs after Karpathy Pre-Flight, before the first file is touched:

   For every pair of tasks (A, B) in ## Tasks, check all three:
   - **File conflict**: both tasks write to the same file path → B depends on A
   - **Output dependency**: B's inputs are produced by A (stated in spec or inferable) → B depends on A
   - **Shared state**: both tasks modify the same schema, migration, or shared config file → B depends on A

   Group tasks with no dependencies on each other into the same wave.

   Log the wave plan before execution begins:
   `"Wave 1: [task N, task M] | Wave 2: [task P] | ..."`

   Dispatch rule:
   - Wave with **2+ independent tasks** → spawn one code-worker agent per task; dispatch all in parallel; wait for all to complete before starting the next wave
   - Wave with **1 task** → execute that task directly (no agent spawn)
   - All tasks sequential (every wave has exactly 1 task) → execute directly in order; no agents needed

**Task granularity** is fixed at spec authoring time by apex-plan — do not re-decompose
tasks during Wave Analysis. If a task appears too coarse to verify atomically after
completion, treat it as a GRAY fork and route back to planning.

Context note: each worker agent starts with a fresh ~200k context scoped to its assigned tasks.
The main window stays lean. All shared state flows through spec files and git history — not handoff docs or conversation memory.

During execution:
- Execute waves in the order produced by Wave Analysis
- Within each wave: apply the dispatch rule (parallel agents or direct execution)
- After each wave completes: run the wave domain review (see § Wave domain review) before starting the next wave
- After completing each task: check it off in ## Progress
- **In-task micro-ambiguity** (which existing pattern to follow, a name, a local detail that
  does NOT change the spec's approach): make the conservative choice, log it in the decisions table.
  - Prefer not modifying a file over modifying it when unclear
  - Prefer existing patterns over new ones
  - Prefer simpler over clever
  - Prefer more validation over less
  - Never delete anything — flag for planning instead
- **A fork** (the spec cannot be executed as written, or a materially better path exists) is
  NOT micro-ambiguity. Do not "conservatively guess" it — route it through **Forks** (below).
- When a needed action is NOT in ## Permissions: that is a BIG fork (see Forks) — do NOT
  perform the action; capture-at-halt, log it in Blocked Actions, continue with independent tasks.

## Verification — run the stack's recipe (not hardcoded commands)

apex-code is a **stack-agnostic runner**: it owns the *loop*; the stack skill owns the
*commands*. There are **no npm/test/lint/build commands baked into this skill** — get them from
the recipe (ADR-006).

**Universal coding rules (load once, every build):**
Read `~/.claude/skills/apex-coding-principles/impl.md` in full before writing any code.
These rules apply to all files in this build, regardless of stack.

**Load the bound impl.md core (once, at pre-flight) — not the whole file:**
1. Read `stack_skills` from status.md (session start).
2. For each bound stack skill, load **only its impl.md always-load core**, by section name:
   `## NEVER do` + `## ALWAYS do` (hard rules to obey while writing), the `## Verification Recipe`,
   and a compact `## Common errors → fix` table if present. **Do not load the whole impl.md** —
   pattern walk-throughs and long reference tables stay unread. The **effective recipe = the union
   of every bound skill's Recipe layers** (language + framework) — e.g.
   `stack_skills: [apex-python, apex-django]` → Python checks **+** Django checks.
3. **On-demand references:** when an impl.md points a pattern to `references/<file>.md` with a load
   condition ("read when the task touches X"), load that file **only** while a task matches the
   condition, then move on. Match the condition mechanically — never pre-load references "just in case."
4. **No stack skill bound (`stack_skills: []`):** fall back to the spec's `## Commands to run`;
   if the spec has none, run the obvious per-ecosystem typecheck/test/build best-effort and
   **log the gap** (no recipe available) in the decisions table.

**Run it (per task — task-level granularity):**
- After completing a task, run the recipe commands in order (typecheck → lint → test → build,
  per the recipe). The spec's per-feature delta (e.g. a new test) **supplements** the recipe; it
  does not replace it.
- This *is* the per-task done-criteria check (Karpathy step d) — a task is done when the recipe
  passes, not when the code is written.

**Verify-fail recovery loop (reuse apex-debug discipline):**
- On a failing command: read the **exact** error → form **one** hypothesis → make the smallest
  fix → re-run the recipe. One hypothesis at a time; never shotgun multiple changes.
- Converge before moving to the next task. If it won't converge after a few honest attempts,
  treat it as a fork (capture-at-halt, route per Forks).

**context7 at the write step:** before writing non-trivial code against the active stack/
framework, consult **context7** for its current API/syntax — getting it right first means fewer
recovery iterations.

## Wave domain review — selective dispatch

Runs after each wave's recipe passes, before the next wave starts. Skipped entirely for
waves that touch no high-risk domain — proceed directly to next wave.

**Step 1 — domain check (file-path substring match, case-insensitive):**

Collect all file paths written in this wave. Check each path and filename against:

| Domain   | Trigger substrings (path or filename)                                      |
|----------|----------------------------------------------------------------------------|
| auth     | `/auth/`, `/session/`, `auth`, `session`, `jwt`, `oauth`, `login`, `signup`, `password` |
| security | `/security/`, `/crypto/`, `guard`, `middleware`, `sanitize`, `encrypt`, `hash` |
| data     | `/migrations/`, `/schema/`, `migration`, `schema`, `seed`                  |

If no file matches any row → skip. Proceed to next wave.

**Step 2 — dispatch (santa-method dual-pass, in parallel — ADR-010):**

The matched domains (auth/security/data) are the critical subset, so each is reviewed by **two**
independent `apex-wave-reviewer` instances by default — a missed violation here is shipped-code
defect-grade. For each matched domain dispatch **two** reviewers in parallel, each with identical
inputs:
- `changed_files`: list of file paths written in this wave
- `domain_impl_path`: `~/.claude/skills/apex-{domain}/impl.md`
- `acceptance_criteria`: the "done when:" clauses for this wave's tasks

The two passes run in isolated contexts — do not share state between them.

**Single-pass override:** if the spec frontmatter sets `risk: low`, dispatch **one** reviewer per
matched domain instead of two (the planner judged it low-stakes despite touching a critical path).
`risk: high` or absent → dual-pass (the default).

Wait for all dispatched reviewers to complete before proceeding.

**Step 2b — union the dual pass (per matched domain):** combine the domain's two verdicts into one,
taking the worst:
- **BLOCK** if *either* pass returns BLOCK
- else **FLAG** if *either* pass returns FLAG
- else **CLEAN** (only when *both* passes are CLEAN)

Union the two findings lists; dedupe findings that point at the same file+rule. Use this single
unioned verdict in Step 3. (Single-pass override → the one verdict is used as-is.)

**Step 3 — handle findings (unioned verdict per domain):**

| Verdict | Action |
|---------|--------|
| CLEAN   | Proceed to next wave |
| FLAG    | Log to decisions table: `"Wave {N} {domain} review: {finding}"`. Proceed to next wave. |
| BLOCK   | Re-run the specific task that produced the violation with the unioned finding prepended to its context. Re-run the recipe. Re-dispatch **both** passes for this domain (one retry only). If still BLOCK after re-union: BIG fork — capture-at-halt, mark spec blocked. Do not attempt a second retry. |

The one-retry cap on BLOCK is a hard limit. A second BLOCK means the issue requires planning judgment — do not loop.

## Forks — when the spec is wrong or not optimum

A *fork* = the spec as written can't be executed, or a materially better path exists.
Classify it mechanically (check the tests in order), then route:

**SMALL — fix in place, log a deviation, continue.** ALL of these must hold:
- the fix stays within the spec's ## Files to Change, AND
- adds no dependency, no new file, no schema/API/data-contract change, AND
- keeps the spec's approach (same implementation shape), AND
- touches no critical file (*.env, migration, auth middleware, CI/CD).
→ Make the fix. Log it in the Decisions table as a deviation. Continue.

**BIG — stop this spec, mark it blocked, route to planning.** ANY of these holds:
- needs a file not in the spec, or a new dependency, OR
- changes the spec's approach / scope / architecture, OR
- changes a schema, public API, or data contract, OR
- is a security / auth / data-loss decision.
→ Capture-at-halt (below). Do NOT implement the fix. The spec is `blocked`.

**GRAY — pause and ask the user to route.** You cannot cleanly place it in SMALL or BIG
(e.g. it changes the approach but the impact is unclear, or several valid fixes trade off
differently).
→ At autonomy **L2**: capture-at-halt, then **pause and ask the user which way to route.**
  Never guess at a gray fork. (The ask-line is set by autonomy_level; L2 = ask on gray.)

**AFK behaviour at a BIG or GRAY fork — park, don't halt the whole build:**
- Forked task is **isolable** (no other task in the build depends on it) → **park only that
  task**, keep executing the independent tasks in the wave/build.
- **Halt the whole build only if** everything downstream depends on the forked decision.
- Never substitute a guess for the parked decision.

**Capture-at-halt — hard requirement, do it the moment you park/block a task, before anything else:**
1. Append to `docs/progress/{spec-name}.md`:
   `Task N {blocked|parked}: {what the spec says} → {why it can't be done as-is} → {the decision planning/user must make}.`
2. Update `docs/status.md` In-Flight: `{spec} · {blocked|parked} · stopped at task N/{total}`.
This is what makes re-engagement cheap — without it, planning must re-read the whole spec to
reconstruct the problem.

**A blocked spec stays in `docs/changes/` marked `blocked`** — do NOT move it to `drafts/`.
That relocation (patch-in-place vs full re-draft) is planning's judgment, not coding's.

### Edit Mode

Triggered by: direct instruction without a spec (small fix, quick change)

- Single sequential execution — no parallel workers

**Karpathy check for Edit Mode (runs before any file is touched):**
- State your interpretation of the edit request explicitly. If ambiguous, ask once.
- State the minimum change: "The smallest edit that achieves this is: ___"
- Confirm: every file you intend to touch is directly required by the edit.
- State what "done" looks like: "This edit is done when: [observable outcome]"
- After completing: verify the done-criteria before reporting finished.

- One clarifying question allowed before proceeding on ambiguous tasks
- Explicit confirmation required for critical files: *.env, migration files, auth middleware, CI/CD configs
- No spec required — work from the direct instruction
- Handoff still written at end

## Post-build steps (AFK and Edit both)

Execute in this order:

1. Spawn in parallel (neither depends on the other):
   - apex-docs-product-agent — inputs: files_changed, spec_path, today's date
   - apex-reviewer (skip if token_profile is "lean") — inputs: spec_path, files_changed
   Wait for both to complete. Collect docs_summary and reviewer_findings.

2. Spawn apex-docs-technical-agent:
   Inputs: spec_path, coder_summary, reviewer_findings, docs_summary, today's date
   Wait for completion.

3. Report to user:
   "Build complete. Handoff at docs/handoff/{date}.md.
   Reviewer: {clean | N findings — see handoff}.
   Decisions made: {count} — review in next planning session."

## Pause workflow

When pause signal detected during coding (including rate limit / quota cap):
1. Complete current task — never stop mid-task
2. Update ## Progress checkboxes in spec
3. Run git status
4. Update docs/status.md In-Flight table with exact stopped position
5. Report: "Paused after task {n}/{total}. Uncommitted: {files}. Say 'resume build' to continue."

Rate limit hit: treat as a pause signal. The In-Flight table is the checkpoint — quota reset + "resume build" resumes automatically.

## Permissions pre-authorisation (AFK build)

Before executing any task:

1. Parse ## Permissions from the spec into an authorised actions list:
   - file_writes: set of full file paths that may be written
   - commands: set of exact commands that may be run
   - git_ops: set of git operations permitted
   - env_vars: set of environment variables that may be read
   - network: set of permitted network operations

2. For each action during execution — check against authorised list:
   - Listed → execute normally
   - NOT listed → log to blocked_actions table, skip, continue with next task
   - Hard block (push to main, DROP TABLE, etc.) → stop immediately, report to user

3. Log all actions at L4+:
   Append to docs/audit/YYYY-MM-DD.log:
   [timestamp] FILE WRITE — {path} (auto-approved L{n})
   [timestamp] COMMAND — {command} (auto-approved L{n})
   [timestamp] BLOCKED — {action} (not in spec permissions)

## Audit log — session bookends

At session start, append to docs/audit/YYYY-MM-DD.log:
[timestamp] SESSION START — Level: L{n} | Profile: {profile} | Spec: {spec-name}

At session end, append:
[timestamp] SESSION END — {n} files written, {n} commands run, {n} blocked actions

## Hard blocks — never do regardless of autonomy level

These actions are permanently forbidden. Do not attempt them:
- git push to main or master
- git merge
- DROP TABLE or any destructive schema command
- git branch -d or git branch -D
- Reading, logging, or storing production secrets
- Modifying any file in docs/audit/
- Any action that disables or bypasses governance rules

## Autonomy level reference

L0: Read only — no writes, no commands
L1: Write files with per-file confirmation — no commands
L2 (default): Write non-critical files freely; critical files need confirmation
L3: Full pipeline + run the stack's Verification Recipe (typecheck/lint/test/build) — no git commits
L4: Includes git commit (message requires approval first)
L5: Includes git push to non-main branches + draft PR creation

Critical files always requiring confirmation regardless of level:
*.env, *.env.*, migration files, auth middleware, CI/CD configs, secrets files

## Decisions log format

Maintain this table during AFK build — append after each autonomous decision:

| Task | Decision | Reason | Review needed? |
|------|----------|--------|----------------|
| Task {n} | {what was decided} | {why — be specific} | No / Yes ⚠️ |

Include this table in the handoff under ## Decisions Made.
