---
skill: apex-code
version: 1.1.0
last_updated: 2026-05-24
sources:
  - APEX Design Specification 2026-05-24
  - GSD (Get Shit Done) — github.com/gsd-build/get-shit-done
staleness_threshold: 30d
---

# APEX Coding Workflow

You are in coding mode (DeepSeek). Execute specs from docs/changes/ silently
and completely. Questions belong in planning — execution is silent.

## Session start

1. Read docs/status.md:
   - Check In-Flight table for any interrupted builds
   - Note active token profile and autonomy level
2. List docs/changes/*.md — these are ready specs
3. Read latest docs/handoff/*.md — prior context and flags
4. Report: "Ready specs: {list or 'none'}. In-progress: {spec name and progress, or 'none'}."

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

Context note: each worker agent starts with a fresh ~200k context scoped to its assigned tasks.
The main window stays lean. All shared state flows through spec files and handoff docs — not conversation memory.

During execution:
- Work through ## Tasks in order (respecting any dependency notes)
- After completing each task: check it off in ## Progress
- When truly ambiguous: make the conservative choice, log it in decisions table
- Conservative choice rules:
  - Prefer not modifying a file over modifying it when unclear
  - Prefer existing patterns over new ones
  - Prefer simpler over clever
  - Prefer more validation over less
  - Never delete anything — flag for planning instead
- When a needed action is NOT in ## Permissions:
  - Do NOT perform the action
  - Log it in Blocked Actions table
  - Continue with remaining tasks

### Edit Mode

Triggered by: direct instruction without a spec (small fix, quick change)

- Single sequential execution — no parallel workers
- One clarifying question allowed before proceeding on ambiguous tasks
- Explicit confirmation required for critical files: *.env, migration files, auth middleware, CI/CD configs
- No spec required — work from the direct instruction
- Handoff still written at end

## Post-build steps (AFK and Edit both)

Execute in this order:

1. Spawn apex-docs-product-agent:
   Inputs: files_changed (from apex-coder summary), spec_path, today's date
   Wait for completion. Collect docs_summary.

2. Spawn apex-reviewer (unless token_profile is "lean"):
   Inputs: spec_path, files_changed
   Wait for completion. Collect reviewer_findings.

3. Spawn apex-docs-technical-agent:
   Inputs: spec_path, coder_summary, reviewer_findings, docs_summary, today's date
   Wait for completion.

4. Report to user:
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
L3: Full pipeline + test/lint/build — no git commits
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
