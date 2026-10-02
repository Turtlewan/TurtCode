# AGENTS.md — {project-name} (Codex build instructions)

Standing instructions for the **Codex CLI** (and any AGENTS.md-aware agent) when working in this
repo. Codex reads this before acting; the nearest-directory AGENTS.md wins. Keep the root file
≤ ~200 lines — overflow goes to nested per-directory AGENTS.md files, never a fatter root.

## What this repo is
{one line from PROJECT.md — what this builds + its top-level shape}

## How to build a spec (APEX convention — universal)
When asked to implement `docs/changes/<name>.md`:
1. **Read the whole spec first.** Implement each `## Tasks` item precisely — the task text names its exact files, mechanism, and done-when.
2. **Surgical scope:** only create/modify files in the spec's `## Files to Change`. Check with `git status --porcelain -uall` — **not** `git diff --stat`, which never lists a file you *created* (it is untracked) and cannot be made to, since you may not `git add`.
3. **Run this file's `## Verify commands`** (the recipe's single home, ADR-037) and make every `## Acceptance Criteria` item pass. You run it inside your own worktree and iterate to green. That is not the authoritative pass and not a verdict. The host EXECUTES the recipe as mechanics from the orchestrator's wave plan and returns the raw results; the ORCHESTRATOR owns the pass/fail adjudication and the routing that follows.
4. **Tests are the contract:** if a check fails, fix the *code* and re-run until green. NEVER weaken, skip, or delete a test to make it pass.
5. **Stop and ask** if a spec's acceptance criteria cannot be met as written — that is a planning question. Note it; do not improvise around the spec.

## Building a queue of specs
On **"build specs"** (or "build the queue" / "build docs/changes"): work through every spec in
`docs/changes/` (not `done/`):
1. **Dependency order** — honour each spec's `## Prerequisites`; if order is unclear, ask once then proceed.
2. **Scheduling is the orchestrator's call (ADR-029).** Specs that are both dependency-independent (`## Prerequisites`) and file-disjoint (`## Files to Change`) may build concurrently, up to `max_parallel_codex` (default 2). **Third condition (ADR-029 supervision gate):** a **high-risk** spec — `risk: high`, or auth / security / data — runs **supervised and sequential even when it is dependency-independent and file-disjoint**; it never joins the pool. **Channel is keyed on ATTENDANCE, not duration** (owner ruling, 2026-07-31): an attended long dispatch runs on the detached runner with the owner present, and an attended short one stays literal foreground — and a foreground call that outlives the harness tool ceiling is MIGRATED to background by the harness rather than killed (probe B). Both claims are observations **version-pinned to the harness build the 2026-08-01 probes ran on** (issue-13 § Caveats), never properties of the harness: re-probe before relying on either against a newer build. Anything else is one spec at a time. Either way: implement → run the verify recipe → green, and **integrate → verify → commit strictly sequentially, in dependency order**. **That commit is not yours** — the `## Hard rules` no-commit rule above still binds you absolutely. Integration and commits are executed host-side from the orchestrator's plan (ADR-046 D1); you build and verify in the tree you are given and leave it dirty.
3. **STOP on the first failure** — if verify won't go green or a criterion can't be met, stop, leave the tree as-is, and report which spec + why. Never continue onto a red tree.
4. **Never move or archive a spec.** Spec archival into `docs/changes/done/` is the `apex-docs-technical-agent`'s host's-pen write, or the host's directly (D6, ADR-046). Report that the spec passed; the close-out does the move.
5. **Never commit** (hard rule) — leave all built work dirty for owner review at the end.
6. **End with a summary** — specs passed, specs blocked, final verify status.

## Verify commands (run after each spec — green on all = done)
<!-- apex:agents:verify -->
{The exact runnable commands that verify this repo — install, lint, typecheck, test, build.

**This file is THE home of the Verification Recipe (ADR-037).** Codex reads AGENTS.md natively on
every `codex exec` and **never sees status.md**, so a recipe written anywhere else is invisible to
the coder that actually runs it.

Write only what the model cannot derive: the real command names, the real flags, and any gotcha that
would otherwise waste a run — e.g. "plain `uv sync`; there is NO `agentic` dependency group and
`uv sync --group agentic` errors". Do not restate what any competent coder already knows.

If the stack is TBD at init, leave this marker as the stub.}

## Hard rules (APEX hard-blocks — never violate)
- **Never `git commit`, never `git push`, never create or switch branches.** The host owns integration — worktrees, checkouts, and commits are owner-controlled; pushing to the default branch is a permanent hard block. Build + verify only, in the tree you are given; leave it dirty for owner review.
- **Building uses `--sandbox workspace-write`;** read-only/review tasks use `--sandbox read-only`.
- **Baseline before building:** run the **full** verify recipe once first — **including its install/setup step** (e.g. `uv sync`, `npm ci`); never run the check-only commands against an unprepared env, since a missing project install reads as a **false red**. If the baseline is genuinely **red**, stop and report — never build on a broken base. **Do NOT stop merely because the working tree has uncommitted changes** — that is the owner's normal state by design (this file forbids committing, so the tree is *expected* to be dirty). Note what is already modified, then proceed.

## Project layout
<!-- apex:agents:stub -->
> **STUB.** Planning fills this once code exists: the module map (top-level packages + what each owns)
> and the architecture shape (e.g. ports & adapters, layering). Until then Codex explores the tree.

## Conventions
<!-- apex:agents:stub -->
> **STUB.** Planning fills this: language/typing rules, framework patterns, and anything `ruff`/`mypy`/
> the linter does **not** mechanically enforce. Keep it to what the tooling can't catch.
