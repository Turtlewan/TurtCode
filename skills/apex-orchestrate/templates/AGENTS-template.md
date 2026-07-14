# AGENTS.md — {project-name} (Codex build instructions)

Standing instructions for the **Codex CLI** (and any AGENTS.md-aware agent) when working in this
repo. Codex reads this before acting; the nearest-directory AGENTS.md wins. Keep the root file
≤ ~200 lines — overflow goes to nested per-directory AGENTS.md files, never a fatter root.

## What this repo is
{one line from PROJECT.md — what this builds + its top-level shape}

## How to build a spec (APEX convention — universal)
When asked to implement `docs/changes/<name>.md`:
1. **Read the whole spec first.** Implement `## Exact changes` precisely — signatures, file contents, edit locations.
2. **Surgical scope:** only create/modify files in the spec's `## Files to change`. `git diff --stat` must show only those.
3. **Run the spec's `## Commands to run`** and make every `## Acceptance criteria` item pass.
4. **Tests are the contract:** if a check fails, fix the *code* and re-run until green. NEVER weaken, skip, or delete a test to make it pass.
5. **Stop and ask** if a spec's acceptance criteria cannot be met as written — that is a planning question. Note it; do not improvise around the spec.

## Building a queue of specs
On **"build specs"** (or "build the queue" / "build docs/changes"): work through every spec in
`docs/changes/` (not `done/`):
1. **Dependency order** — honour each spec's `## Prerequisites`; if order is unclear, ask once then proceed.
2. **One spec fully at a time** — implement → run the verify recipe → green — before starting the next.
3. **STOP on the first failure** — if verify won't go green or a criterion can't be met, stop, leave the tree as-is, and report which spec + why. Never continue onto a red tree.
4. **After a spec passes, move it to `docs/changes/done/`** (a file move, not a commit).
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
