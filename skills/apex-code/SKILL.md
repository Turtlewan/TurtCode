---
skill: apex-code
backend: claude
version: 2.0.0
last_updated: 2026-07-14
sources:
  - docs/technical/adr/ADR-027-codex-primary-opus-fallback-deepseek-archived.md
  - docs/technical/adr/ADR-028-parallel-codex-dispatch.md
  - docs/technical/adr/ADR-029-cross-spec-parallel-build.md
  - docs/technical/adr/ADR-030-codex-reasoning-effort-dial.md
  - docs/technical/adr/ADR-031-codex-context-propagation.md
  - docs/technical/adr/ADR-032-gpt56-role-split.md
  - docs/technical/adr/ADR-036-remove-knowledge-layer.md
  - docs/technical/adr/ADR-037-three-context-files.md
  - docs/technical/adr/ADR-038-single-session.md
staleness_threshold: 30d
description: >
  APEX build workflow — executes docs/changes/ specs: pre-flight, wave-parallel Codex
  dispatch, the verify loop against the repo's AGENTS.md, forks, and post-build review.
  Codex `gpt-5.6-sol` is the coder; Opus is the fallback. Loads when building a spec.
---

# APEX Build Workflow

**This skill carries the machinery, not the judgment.** How to execute a spec carefully — verify
assumptions before coding, don't build on red, keep scope surgical, verify per task, never weaken a
test to go green, don't silently redesign — is **model-native** and was cut in v2.0.0 after four RED
probes reproduced all of it cold (ADR-036). What remains is what a bare agent cannot know: APEX's
artifacts, the exact invocations, and the traps that only surface on a second pass.

## Session start

1. `git log --oneline -10` — what landed recently.
2. Read `docs/status.md` — In-Flight rows + `autonomy_level`.
3. Read the repo's **`AGENTS.md`** — its `## Verify commands` are the recipe, and its conventions
   and hard rules bind this build (ADR-037). Codex reads the same file natively, so host and coder
   run the same contract by construction.
4. List `docs/changes/*.md`. Report: "Ready specs: {list}. In-progress: {spec or none}."

No ready specs → "No specs in `docs/changes/`. Want me to plan one?" (same session — apex-plan).

**Context discipline:** read the spec and the files it lists. Not `docs/handoff/`, not other specs,
not ambient project docs.

## Pre-flight

- **`## Assumptions`** — verify each against the codebase *now*. Wrong + impact `Stop` → halt, log,
  report. Wrong + `Caution`/`Low` → log the deviation, proceed.
- **`## Files to Change`** is a **scope lock** for the whole build. A file not listed is a blocked
  action: log it, don't touch it, surface it in the handoff. Re-check before touching any file.
- **Invariant freshness (ADR-033 A3):** if the spec predates an ADR shift, check its `## Intent`
  invariants still hold. A contradiction is a wrong `Stop` assumption — halt and flag.
- **`coder_effort`** frontmatter `{low|medium|high|xhigh|max|ultra}`, default `medium`.
- AFK build → capture `run_base_sha = git rev-parse HEAD` now (for the end-gate).

## Wave analysis

Two tasks may run in parallel iff `writes(A) ∩ writes(B) = ∅` **and** neither writes what the other
reads **and** they share no exclusive resource.

**Two traps — both cost a silent clobber, and neither shows up as a git conflict:**

1. **File-disjointness is necessary, not sufficient** (ADR-029). Dependency-independence and
   file-disjointness are different tests; a spec can pass one while failing the other. Run both.
2. **The collision is usually in files the spec didn't enumerate** — the shared substrate: a package
   `__init__.py`, a declarative `Base`, a barrel re-export, a route registry, a migration head. Two
   workers each create it, last write wins, and verification may still pass with one model silently
   missing from the metadata.

**Unsure whether B depends on A → sequential.** The costs are asymmetric: wrongly-sequential costs
wall-clock (visible, recoverable); wrongly-parallel costs a silent clobber that propagates.

Log the plan before executing: `Wave 1: [task N, task M] | Wave 2: [task P]`.

**Dispatch:** `wave_dispatch: workflow` (spec frontmatter, else status.md, else `inline`) + 2+
independent tasks → dispatch the wave via `apex-build-wave.js` rather than inline Agent calls, so
worker transcripts stay out of this window (ADR-015). Mechanics → `references/workflow-dispatch.md`.
Same-tree parallel workers collide on lockfiles, ports, caches and the git index — use
`isolation: "worktree"` (inline) / `isolate: true` (workflow). Cap: `max_parallel_codex` (default 3).

## Codex dispatch — the coder

Every task tagged `▸codex` (the default). Assemble the **dispatch pack** — Goal → Context →
Constraints → Done-when — per `references/dispatch-pack.md`, then **run it backgrounded**:

```
printf '%s' "<the dispatch pack>" | codex exec -p apex-coder --sandbox workspace-write -m gpt-5.6-sol \
  -c model_reasoning_effort="<coder_effort>" -C <repo-root> --json \
  --output-schema ~/.claude/skills/apex-code/references/codex-completion-schema.json \
  -o <scratch>/codex-<task>.final --color never > docs/progress/codex-<task>.log 2>&1
```

- **Pipe the prompt via stdin** — a bare argument hangs.
- Omit `-c model_reasoning_effort` at `medium`.
- `--json` streams to a tailable log. **Post a one-line progress pulse to chat per check-in** — a
  backgrounded Codex is otherwise invisible until it exits. Recipe → `references/codex-observability.md`.
- `-o` captures the schema-constrained final message: `{status, changed_files, commands_run,
  deviations, unresolved, blocker}`. Route `status` per `references/dispatch-pack.md` § Completion
  routing. **`blocked` = spec defect → Forks, never a model fallback.**
- **Blast radius:** the Codex subprocess does **not** ride Claude Code's `permissions.deny` floor.
  `workspace-write` is its only guardrail — keep it repo-confined, never `danger-full-access`.
- **Windows sandbox:** install dependencies **as the normal user** in this session (`npm install` /
  `uv sync`) *before* dispatch. Never let the subprocess create `node_modules`/`.venv` — the sandbox
  SID owns them and your verify (running as you) then hits a locked tree.
- **Scope check after every task** (open — see status.md): `git diff --name-only` vs the authorized
  set. Extra paths = scope violation → revert **only the offending paths**, never the file wholesale.

**Parallel Codex** (2+ independent `▸codex` tasks) → `references/parallel-codex.md`.

**Fallback:** `codex --version` fails, or quota is exhausted mid-run → the task falls back to
**Opus**, a fresh `model: opus` worker in this session. Logged, never silent. No backend swap, no
relaunch (ADR-038). Whole-spec pin: `coder_model: {codex|opus}`.

## Verify

The recipe is the repo's **`AGENTS.md` → `## Verify commands`** (ADR-037). Absent one, fall back to
the spec's `## Commands to run`; absent that, run the obvious per-ecosystem checks, log the gap, and
**write a recipe into AGENTS.md so the next build has one**.

Load `~/.claude/skills/apex-coding-principles/impl.md` before writing code.

Run the recipe **per task**, not once at the end. **The host runs it — never the coder subprocess
judging its own output** (evaluator independence).

**On failure, escalate in order**, logging each rung: bump `coder_effort` one notch → … → `max` →
`ultra` → **Opus** (fresh worker). `ultra` is the only place it fires automatically, and it is
un-evaled — first rung to cut if the eval disappoints (see status.md).

## Forks — when the spec is wrong

- **Assumption wrong / file not where the spec says** → build in the real place and **flag loudly**:
  "spec said X, built at Y — review needed ⚠️". Never create a decoy file to make the spec
  technically true; never silently rewrite the spec.
- **Acceptance criterion cannot be met as written** → a planning defect. Stop that spec, leave it in
  `docs/changes/`, mark the In-Flight row `blocked`, move on. **Never edit the criterion** — a spec
  you graded yourself on proves nothing.
- **GRAY (a real judgment call the spec doesn't cover)** → **surface it to the user**. Never quietly
  escalate to a stronger model to decide it for you.

## Post-build

1. **In parallel:**
   - `apex-reviewer` — spec_path, files_changed. **Always runs.** It is the evaluator-independence
     gate; skipping it to save tokens trades away the one thing that sees what the coder cannot.
   - `apex-docs-product-agent` — files_changed, spec_path, date.
2. **Cross-family review** (`cross_model_review: true`; auto for auth/security/data/`risk: high`).
   Derive the reviewer from the builder (ADR-032/034): **Codex built → Claude reviews** (`model:
   opus` for the high-risk set); **Opus built → Codex reviews** (`references/codex-review.md`).
   Give it the spec + diff only — **never the other reviewer's findings**. A finding both raise →
   resolve before "complete"; only one → decisions table, human adjudication ⚠️. Codex unavailable →
   record it; never skip silently.
3. **AFK only:** the standing end-of-run **Opus** adversarial pass over `run_base_sha..HEAD` —
   read-only, advisory (`references/afk-endgate.md`). Opus, not Sol: Sol is the coder, and the one
   review that runs with nobody watching must not be self-review. Lenses →
   `references/silent-regression-lenses.md`.
4. `apex-docs-technical-agent` — writes the handoff, archives the spec to `docs/changes/done/`, and
   folds the shipped capability into `overview.md` as one line (merge-on-archive, ADR-014).
5. Report: handoff path · reviewer verdict · decisions count.

## Autonomy, permissions, hard blocks

`apex-governance` is canonical — L0–L5, Build/AFK vs Edit, critical-file confirmation, and the
hard-block list (push to main · merge a PR · drop a table). Summary only here; on conflict it wins.

- **AFK** = "run the list, don't ask." Launch the build path in **`dontAsk`**, not `auto` — `auto`
  routes protected-path writes through the safety classifier even when allow-listed. The allowlist
  must be complete: off-list is a silent deny, not a prompt (ADR-023). Details →
  `references/permissions.md`.
- **Critical files always need confirmation regardless of level** — `.env`, migrations, auth
  middleware, CI configs, secrets. Unattended, an auth-semantics change is a **stop**, not a build.
- **Commit yes, push no**, unless the level says otherwise.
- A new dependency is a **supply-chain action**: verify the exact package name (typosquat) and that
  it is maintained. Unattended and uncertain → don't install; block the spec.

## Pause

Complete the current task — never stop mid-task. Tick `## Progress`. Update the In-Flight row:
`{spec} · {partial|blocked} · stopped at task {n}/{total}`. Capture-at-halt →
`docs/progress/{spec-name}.md` for planning to drain.

## Decisions log

Every autonomous decision: `| what | why | reversibility | review needed? |`.

Surface anything the diff doesn't show. A decision contained in the diff is disclosed *by* the diff
(naming, structure, which helper to reuse). One that constrains future work, touches a trust
boundary, or reaches the outside world is not — that goes in the handoff, flagged.
