---
skill: apex-code
backend: claude
version: 1.27.0
last_updated: 2026-06-27
sources:
  - APEX Design Specification 2026-05-24
  - GSD (Get Shit Done) — github.com/gsd-build/get-shit-done
  - docs/technical/adr/ADR-006-buildability-layer-verification-inversion.md
  - docs/technical/adr/ADR-010-multi-pass-review.md
  - docs/technical/adr/ADR-014-living-capability-overview.md
  - docs/technical/adr/ADR-017-design-brief-artifact.md
  - docs/technical/adr/ADR-018-apex-sole-coding-workflow.md
  - docs/technical/adr/ADR-025-claude-coding-mode.md
  - docs/technical/adr/ADR-030-codex-reasoning-effort-dial.md
  - docs/technical/adr/ADR-027-codex-primary-opus-fallback-deepseek-archived.md
  - docs/technical/adr/ADR-028-parallel-codex-dispatch.md
  - donor-analysis (Superpowers 4-status worker contract) — docs/research/donor-analysis/
  - Agent Skills (addyosmani) — github.com/addyosmani/agent-skills
staleness_threshold: 30d
description: >
  APEX coding-mode workflow (Codex-primary / Opus fallback) — executes docs/changes/ specs: session start,
  AFK build vs edit mode, Karpathy pre-flight, wave-parallel dispatch, fork routing,
  and the stack-agnostic recipe-driven verify loop (reads the stack_skills Verification
  Recipe, runs it per task, recovers on failure). Loads when building/executing a spec.
---

# APEX Coding Workflow

You are in coding mode (Codex-primary via the Claude coding host; Opus fallback — ADR-027). Execute
specs from docs/changes/ silently and completely. Questions belong in planning — execution is silent.

**APEX is the sole coding workflow.** In coding mode follow this skill and the impl.md cores
it loads — that is the only execution loop. Any other dev-system or coding-process skill
(test-driven-development, executing-plans, gsd-*, controlled-yolo, full-output-enforcement, etc.)
is out of scope here; do not invoke it. (See ADR-018.)

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
4. Set permission mode: run the build path (interactive AFK, headless `-p`, workflow waves)
   in **`dontAsk`**, NOT `auto` — see § Permissions 1a for the allowlist and rationale. Launch
   headless/workflow builds with `--permission-mode dontAsk`; for an interactive session, cycle off `auto`.
5. Pre-authorise all listed operations for this session
6. Package legitimacy check: for any new packages introduced by this spec,
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

   **b. Simplicity flag (Simplicity First — flag, don't act)**
   The spec is authored by the stronger planning model — do NOT second-guess its approach.
   For each task in ## Tasks, before implementing:
   - If you see a significantly simpler implementation that would meet the same acceptance
     criteria: implement the task **as specified**, and log the alternative in the decisions
     table: "Task N: simpler alternative exists — [one line]. Review needed ⚠️."
   - Exception (apply + log, no flag): purely mechanical reductions — a branch the spec itself
     makes unreachable, a literal the spec lists twice. Nothing that changes the approach.

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

   **If the spec ships a `## Wave plan` section, use it verbatim — skip the pairwise analysis
   entirely.** Otherwise, for every pair of tasks (A, B) in ## Tasks, check all three:
   - **File conflict**: both tasks write to the same file path → B depends on A
   - **Output dependency**: B's inputs are produced by A, as stated in the spec → B depends on A
   - **Shared state**: both tasks modify the same schema, migration, or shared config file → B depends on A

   Never infer an unstated dependency relationship: if you are uncertain whether B depends on A,
   treat it as dependent (run sequentially). Independence must be evident from the spec's stated
   files and inputs — not guessed.

   Group tasks with no dependencies on each other into the same wave.

   Log the wave plan before execution begins:
   `"Wave 1: [task N, task M] | Wave 2: [task P] | ..."`

   Dispatch rule:
   - **Workflow dispatch (opt-in):** if `wave_dispatch: workflow` is set (spec frontmatter, else
     status.md, else default `inline`) AND the wave has **2+ independent tasks**, dispatch the wave
     via the Workflow runtime instead of spawning code-worker agents inline — see § Workflow dispatch
     path below. The runtime isolates worker transcripts so they never enter this context. Otherwise
     use the inline rules below.
   - **Fan-out cap (default 3–4):** dispatch at most 4 parallel workers per wave. If a wave has
     more independent tasks than the cap, split it into sub-waves of ≤4 and run the sub-waves
     sequentially (wait for each sub-wave before the next). The spec frontmatter `worker_cap`
     overrides the default (`worker_cap: null` = unlimited; a number = that cap). This bounds the
     launch overhead each parallel dispatch writes into the main context.
   - **Build-artifact isolation (worktree):** when a wave's parallel workers each run an
     artifact-producing recipe (build / serve / lockfile-mutating — `dist`/`.next`, dev-server
     ports, lockfiles), same-tree concurrency collides even though their *source* files are
     disjoint. Dispatch those workers in an isolated managed git worktree: inline path → pass
     `isolation: "worktree"` to each code-worker Agent; workflow path → set `"isolate": true` in
     the args. **Default it ON for headless/AFK builds** (isolate from the user's working tree).
     Do NOT blanket-apply — per-worker checkout has overhead, and most waves (no concurrent build,
     or pure source edits) are safe same-tree.
   - Wave with **2+ independent tasks** → spawn one code-worker agent per task up to the cap; dispatch the sub-wave in parallel; wait for all to complete before the next (sub-)wave
   - Wave with **1 task** → execute that task directly (no agent spawn)
   - All tasks sequential (every wave has exactly 1 task) → execute directly in order; no agents needed
   - **Multi-spec dispatch:** if the main session dispatches whole-spec `apex-coder` orchestrators in parallel, the same cap applies to those — at most 4 concurrent, remaining specs in the next batch.

   #### Workflow dispatch path (opt-in)

   When `wave_dispatch: workflow` is set, run each **2+-task (sub-)wave** through the Workflow tool
   (`apex-build-wave.js`) instead of inline Agent dispatch — per-worker transcripts stay in the runtime
   (ADR-015 isolation), the main context gets only a bounded status array. Single-task waves execute
   directly. **Full procedure (args object, per-wave steps, fallback) → read
   `references/workflow-dispatch.md`.** Route returned statuses through the Worker return contract below.

   **Worker return contract** — each dispatched code-worker returns one status, not prose
   (Superpowers): `DONE` (complete, verified) · `DONE_WITH_CONCERNS` (complete, flag noted) ·
   `BLOCKED` (could not complete — reason) · `NEEDS_CONTEXT` (missing a fact/file to proceed). Route
   `DONE_WITH_CONCERNS` to the decisions table; `BLOCKED` / `NEEDS_CONTEXT` through Forks.

   #### Model-routing dispatch (ADR-027) — coders {codex (default), opus (fallback)}

   **Codex is the default coder for every task** (untagged plan → all Codex). Opus is reached only as the
   manual fallback when Codex quota is exhausted (below). Dispatch per this map:

   | `▸` tag | Builder / agent | Model string | Dispatch channel |
   |---------|-----------------|--------------|------------------|
   | `codex` (default) | OpenAI Codex (external CLI) | `gpt-5.6-terra` | **`codex exec -p apex-coder` subprocess — NOT a subagent**, sequential |
   | `opus` (fallback) | the Opus `APEX_MODE=coding` host, inline | `opus` | built inline in the host session (no subagent, no subprocess) |

   - **Host = an Opus `APEX_MODE=coding` session (mechanic A).** It dispatches Codex per task and, on quota-out, builds the task itself inline as Opus. DeepSeek (`flash`/`pro`) is archived — ADR-027.
   - **`codex` dispatch (ADR-026) — runs in THIS session, not the workflow.** `agent()` spawns Claude-Code subagents, so it cannot dispatch the external Codex CLI. apex-code executes each `▸codex` task itself, **sequentially**, via Bash. Codex runs under the **`apex-coder` profile** (`~/.codex/apex-coder.config.toml`: `approval_policy=never` + `workspace-write` network-on; canonical tracked source `apex:docs/technical/setup/codex-apex-coder-profile.toml` — copy it to `~/.codex/` on a new host) so it behaves like a first-class in-session worker — writes, verifies, fixes, iterates; **never halts to escalate** (in non-interactive `exec`, any policy but `never` turns the first sandbox/command failure into a dead-stop). **Pipe the prompt via stdin — never pass it as a positional arg** (a bare-arg `codex exec` hangs in a non-interactive shell waiting on stdin; proven 2026-06-22 pilot):
     `printf '%s' "<task text + Files for this task + acceptance criterion + the autonomy clause below>" | codex exec -p apex-coder --sandbox workspace-write -m gpt-5.6-terra -c model_reasoning_effort="<coder_effort>" -C <repo-root> --json -o <scratch>/codex-<task>.final --color never > docs/progress/codex-<task>.log 2>&1` — **run it backgrounded** (`run_in_background`). `-c model_reasoning_effort` = the spec's `coder_effort` frontmatter (`{low|medium|high|xhigh|max|ultra}`, default `medium` — omit the flag at medium; ADR-030. `max`/`ultra` are rare escalation rungs above `xhigh` — semantics in `references/codex-observability.md` § Effort ladder). `--json` streams Codex's events to a tailable log; **while it runs the host posts a one-line progress pulse to chat per check-in** (tail-in/one-line-out — a backgrounded Codex otherwise shows nothing in chat until it exits). `-o` captures the final message the host reads on completion. Recipe + effort dial + pulse mechanism + teardown → `references/codex-observability.md`.
     **Autonomy clause** (append to every coder prompt — config kills halt-to-escalate, this kills report-and-stop-by-disposition): *"Follow AGENTS.md. Surgical scope — touch only the listed files. Work autonomously to completion: run the verify recipe, and if a test fails / lint errors / you hit a problem, fix it and re-run — do not stop to ask. Only end when the acceptance criterion passes, or you are genuinely blocked (missing credential, ambiguous spec) — then state exactly what blocked you."*
     Codex returns its own diff; apex-code then runs the spec's Verification Recipe on it like any task. **Blast radius:** the Codex subprocess does NOT ride Claude Code's `permissions.deny` floor — `workspace-write` is its only guardrail, so keep it repo-confined (never `danger-full-access`). Codex tasks default to **sequential**; for a wave with 2+ independent `▸codex` tasks the host fans them out concurrently — see § Parallel Codex dispatch (ADR-028) below.
   - **Windows sandbox artifact ownership (`▸codex`).** The Windows restricted-token sandbox tags files written by Codex's *shell commands* with the sandbox SID — the interactive user can't delete them without elevation. Codex's *source-file edits* are unaffected (normal-user-owned). Two rules keep this from biting: (1) the `apex-coder` profile suppresses the common in-tree caches (`PYTHONDONTWRITEBYTECODE`, `PYTEST_ADDOPTS=-p no:cacheprovider`); (2) **install dependencies as the normal user in the apex-code session** (`npm install` / `uv sync` etc. before or as part of the verify step) — never let the Codex subprocess create `node_modules`/`.venv`, or the verify (run as your user) hits a locked tree. To clear any locked residue **without elevation**, run a cleanup `codex exec -p apex-coder --sandbox workspace-write -C <repo> "delete <dir>"` — Codex runs under the same sandbox SID that owns the files, so it can remove them (proven 2026-06-22); an elevated `Remove-Item -Recurse -Force` is the fallback (normal-user `takeown` reclaims source files but not deep-locked cache dirs).
   - **No backend swap.** Codex runs as a subprocess (its own auth); the Opus fallback builds inline in the same `APEX_MODE=coding` host. No `ANTHROPIC_BASE_URL` change, no restart.
   - **Fallback (codex → opus):** if `codex --version` fails, or Codex quota is exhausted mid-run (non-zero exit / rate-limit error from `codex exec`), the task **falls back to Opus** — the host builds it inline + logs it (never silent). Whole-spec `coder_model: <m>` frontmatter (`{codex|opus}`) pins every task (no routing).

   #### Parallel Codex dispatch (ADR-028)

   Codex tasks default to **sequential**, but when a dependency (sub-)wave has **2+ independent
   `▸codex` tasks** and `max_parallel_codex > 1`, the host fans them out as **concurrent background
   `codex exec` subprocesses** (Bash `run_in_background`) — Codex subprocesses are OS processes, not
   subagents, so the host collects them; the Workflow path can't drive the external CLI. Cap =
   `max_parallel_codex` (spec frontmatter, else status.md, else auto-sized
   `min(4, floor(cores/2)−1)`, fallback **3**) — machine-protection, not a quota cap; a wave wider than
   the cap splits into sequential sub-waves of ≤cap. Each task runs in its own git worktree, integrates
   via `git checkout <branch> -- <files>` (NOT `git merge`), then the integrated tree is re-verified;
   quota-out on any subprocess → remaining sub-wave falls back to Opus.

   **Cross-spec parallel (ADR-029).** At **"build specs"** (batch over `docs/changes/`) the same one cap
   widens the pool across *independent ready specs*: a pair shares a wave only if BOTH dependency-
   independent (transitive `## Prerequisites`) AND file-disjoint (`## Files to Change` don't intersect) —
   overlap serializes (checkout overwrites, no merge). High-risk specs (`risk: high`/auth/security/data)
   stay sequential+foreground for close host supervision (the live log is written either way); integrate→verify→commit per-spec, in dep order. **Full procedure → `references/parallel-codex.md`.**

**Task granularity** is fixed at spec authoring time by apex-plan — do not re-decompose
tasks during Wave Analysis. If a task appears too coarse to verify atomically after
completion, treat it as a GRAY fork and route back to planning.

Context note: each worker agent starts with a fresh ~200k context scoped to its assigned tasks.
The main window stays lean. All shared state flows through spec files and git history — not handoff docs or conversation memory.

During execution:
- Execute waves in the order produced by Wave Analysis
- Within each wave: apply the dispatch rule (parallel agents or direct execution)
- After each wave completes: run the wave domain review (see § Wave domain review) before starting the next wave
- **Wave-boundary compaction:** after a wave's domain review completes and before the next wave, if main-context usage is high (≳70%), run a deliberate `/compact`. Durable state survives — spec ## Progress checkboxes, git, and docs/progress/{spec}.md — so the next wave reloads what it needs. Compact at this boundary, never mid-wave.
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

**UI specs — load the design brief (build input, not ambient docs):**
If the spec touches user-facing UI, also read `docs/technical/architecture/design-brief.md` (tokens +
art-direction + forbidden patterns, ADR-017). Honour its tokens **by name** and obey its
forbidden-pattern list while writing — never substitute training-default colours / fonts / layouts
for the brief's values. If the spec is UI-bearing but the brief is still a stub, flag it (don't invent
a visual direction).

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

**Model fallback on verify-fail or quota-out (ADR-027; one fallback per task, ADR-015):**
The default coder is Codex. Fall back to Opus when a Codex task won't converge after honest recovery, **or**
Codex quota is exhausted (non-zero exit / rate-limit from `codex exec`):
- **Effort bump first (ADR-030):** on a Codex *verify-fail* (not a quota-out), re-dispatch the same task at one notch higher `model_reasoning_effort` (`medium→high→xhigh→max`) before any model fallback — more thinking on the same Codex pool is the cheaper retry. Exhausted the dial (already `max`) or quota-out → fall back:
- **codex → opus (manual fallback):** capture-at-halt, recommend the switch; on operator confirmation the
  Opus `APEX_MODE=coding` host builds the task **inline itself** (no subprocess, no session swap — the
  write-guard is already relaxed under `APEX_MODE=coding`) and re-runs the recipe. Opus draws the shared Max
  pool, so gate it (apex-governance § soft pool guard). Under parallel dispatch (ADR-028) a quota-out on
  any concurrent subprocess fails the whole Codex pool → fall back the remaining sub-wave tasks to Opus
  (sequential).
- One fallback is the retry; if Opus still fails, fork (capture-at-halt).

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

The matched domains (auth/security/data) are the critical subset, reviewed by independent
`apex-wave-reviewer` instances — **two** (dual-pass) where a missed violation is shipped-code
defect-grade, **one** otherwise, per the **pass-count rule** below. For each domain resolving to
dual-pass dispatch two reviewers in parallel (one for single-pass), each with identical inputs:
- `changed_files`: list of file paths written in this wave
- `domain_impl_path`: `~/.claude/skills/apex-{domain}/impl.md`
- `acceptance_criteria`: the "done when:" clauses for this wave's tasks

The two passes run in isolated contexts — do not share state between them.

**Pass-count rule (per matched domain):** **auth/security** → dual-pass. **data** → single-pass if it
matched only on additive-DDL (`schema`/`/schema/`), dual-pass if a migration signal matched (`/migrations/`/`migration`/`seed`).
Spec `risk: high` → dual-pass for all matched domains (use for a destructive `schema.py` change, e.g. a table/column drop); `risk: low` → single-pass for all.

Wait for all dispatched reviewers to complete before proceeding.

**Step 2b — union the dual pass (per matched domain):** combine the domain's two verdicts into one,
taking the worst:
- **BLOCK** if *either* pass returns BLOCK
- else **FLAG** if *either* pass returns FLAG
- else **CLEAN** (only when *both* passes are CLEAN)

Union the two findings lists; dedupe findings that point at the same file+rule. Use this single
unioned verdict in Step 3. (Single-pass → the one verdict is used as-is.)

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
  Surface it in this format — state the conflict, don't bury it in prose:
  > `CONFUSION: spec says {X}; the codebase has {Y}.`
  > `Options: A) {…}  B) {…}  C) {…} — which?`

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

   **Cross-model review — only if the spec frontmatter has `cross_model_review: true`**
   (apex-governance § Cross-model review). After apex-reviewer returns, run an independent review by a
   **different model family than the builder** (family-aware, ADR-026):
   - **Per task, derive the reviewer from the builder:** Codex-built (the default) → **Opus** reviews;
     Opus-built (the fallback) → **Codex** reviews. (Default whole-build path: Codex built → Opus reviews
     the diff.)
   - **Codex review** runs via Bash, read-only, schema'd — full invocation + schema + prompt in
     `references/codex-review.md`. **Pipe the prompt via stdin** (bare-arg hangs):
     `printf '%s' "<review prompt + acceptance criteria + git diff>" | codex exec -c approval_policy="never" --sandbox read-only --output-schema ~/.claude/skills/apex-code/references/codex-review-schema.json -o <out.json> -m gpt-5.6-terra`, then read `<out.json>` (the schema-constrained final message: `{findings[], verdict}`). (`approval_policy=never` so a sandboxed command never stalls the review; read-only keeps zero blast radius — no profile needed here.)
     Give it the spec + changed files only — **never** apex-reviewer's findings (evaluator independence).
   - **Opus review** (for Codex-built tasks — the common path) → dispatch one `apex-reviewer` on the Claude family, same independence rule.
   - Combine: a finding **both** raise → high-confidence, resolve before "complete"; **only one** → decisions
     table "cross-model divergence — human adjudication ⚠️." Codex findings are **advisory** (never auto-block, no auto-fix).
   - **Codex unavailable** (`codex --version` fails **or quota exhausted** — the usual case when Opus is the
     fallback builder, since Codex can't review on a dead pool) → do NOT skip silently: record
     "cross_model_review requested but codex unavailable — single-model review only ⚠️" and continue.

2. Spawn apex-docs-technical-agent:
   Inputs: spec_path, coder_summary, reviewer_findings, docs_summary, today's date
   It writes the handoff and archives the spec to docs/changes/done/. **On archive it also folds the
   spec's shipped capability into docs/technical/architecture/overview.md → Capabilities (current
   truth) as one terse line — added / modified / removed (merge-on-archive, ADR-014).** A one-liner,
   never a scenario dump.
   Wait for completion.

3. Report to user:
   "Build complete. Handoff at docs/handoff/{date}.md.
   Reviewer: {clean | N findings — see handoff}.
   Decisions made: {count} — review in next planning session."
   - **High-risk specs** (`risk: high`, or auth / security / data domains, or pre-PR): append a
     recommendation — "Before you merge, consider running `/code-review ultra` (cloud multi-agent
     review)." APEX **cannot self-launch it** (billed, user-triggered) — recommend only. It
     complements, never replaces, the free in-pipeline reviewers above (apex-governance § Ultra review gate).

## Pause workflow

When pause signal detected during coding (including rate limit / quota cap):
1. Complete current task — never stop mid-task
2. Update ## Progress checkboxes in spec
3. Run git status
4. Update docs/status.md In-Flight table with exact stopped position
5. Report: "Paused after task {n}/{total}. Uncommitted: {files}. Say 'resume build' to continue."

Rate limit hit: treat as a pause signal. The In-Flight table is the checkpoint — quota reset + "resume build" resumes automatically.

## Permissions pre-authorisation (AFK build)

Before executing any task, parse the spec's `## Permissions` into an authorised actions list
(`file_writes` / `commands` / `git_ops` / `env_vars` / `network`). Then enforce per action:
- Listed → execute normally
- NOT listed → log to the blocked_actions table, skip, continue with the next task
- Hard block (push to main, DROP TABLE, etc.) → stop immediately, report to user

**Full procedure — read `references/permissions.md` before an AFK build:** the `dontAsk` allowlist
policy (mirror `## Permissions` into `permissions.allow`; off-list = silently denied; `wave_dispatch:
workflow` also needs `Workflow/Agent/Task/Skill(*)`; protected paths can't be overridden) and the L4+
audit-log + session-bookend formats.

## Hard blocks — never do regardless of autonomy level

(Summary — **apex-governance owns the canonical list**; on any conflict, governance wins.)
These actions are permanently forbidden. Do not attempt them:
- git push to main or master
- git merge
- DROP TABLE or any destructive schema command
- git branch -d or git branch -D
- Reading, logging, or storing production secrets
- Modifying any file in docs/audit/
- Any action that disables or bypasses governance rules

## Autonomy level reference

(Summary for in-build checks — **apex-governance owns the canonical definitions**; on any
conflict, governance wins. Note: the per-spec commit prompt in global CLAUDE.md applies at
every level — committing with the user's explicit approval is never blocked by L2/L3.)

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
