# Permissions pre-authorisation + audit log — full procedure

Read at the start of an AFK build, before executing any task.

## Parse `## Permissions` into an authorised actions list
- `file_writes`: set of full file paths that may be written
- `commands`: set of exact commands that may be run
- `git_ops`: set of git operations permitted
- `env_vars`: set of environment variables that may be read
- `network`: set of permitted network operations

## `dontAsk` build-mode policy
`dontAsk` enforces permissions at the harness level (no classifier), so the spec's `## Permissions`
must be mirrored into `permissions.allow` (`.claude/settings.local.json` or
`~/.claude/settings.json`) **before** the build. **Two limits, both ratified (ADR-046):** the spec
pre-authorises **NON-critical** actions only — a critical path is never mirrored in, and an unattended
run **parks** it rather than allow-listing it (D3). And the allow-list edit itself is a **permission
action**: it happens **attended, on user approval, before dispatch** (the ADR-023 flow, carved out of
the self-widening block by D4). A background or AFK run **never edits permissions**. Mirror this list:
- Each `file_writes` path → `Write(<path>)`/`Edit(<path>)`; each `commands` entry →
  `Bash(<exact command>)`; plus the repo's `AGENTS.md` `## Verify commands` commands.
  **Off-list = silently denied (no prompt)** — the allowlist must be complete for the verify loop.
  `permissions.deny` is the destructive floor (overrides allow in every mode).
- **`wave_dispatch: workflow`** also needs `Workflow(*)`, `Agent(*)`, `Task(*)`, `Skill(*)` allow-listed
  (gated by `permissions.allow`, not the classifier — omit them and dispatch silently blocks, no worker
  spawns). Dispatched workers **inherit the parent's `dontAsk`** (local denials, no classifier).
- **Protected paths** (`.claude/`, `.git/`, …) are denied outright and `permissions.allow` cannot
  override them — a spec that must write one (a skill `impl.md`, `~/.claude/workflows/*`) can't run under
  `dontAsk`; do those via a one-off approval (or a session where the path is allow-listed). For an ordinary project build this is a
  feature (the build can't mutate `.claude/`/`.git/`).

## Per-action check during execution
- Listed → execute normally
- NOT listed → log to blocked_actions table, skip, continue with next task
- Hard block (push to main, DROP TABLE, etc.) → stop immediately, report to user

## Audit log (L4+) — and session bookends
At L4+ every action is recorded to `docs/audit/YYYY-MM-DD.log` in the shape below. **Doctrine ahead of
enforcement (D5, ADR-046):** append-only is the sanctioned mode and editing or deleting an existing
entry is permanently forbidden — but the live classifier `apex-critical-files.ps1` refuses **every**
`docs/audit/` path on a path match alone (exit 11), with no append-vs-edit distinction. **So the agent
does not write this file.** Until a content-aware classifier change ships, these appends route through the **host**.
```
[timestamp] FILE WRITE — {path} (auto-approved L{n})
[timestamp] COMMAND — {command} (auto-approved L{n})
[timestamp] BLOCKED — {action} (not in spec permissions)
```
Session bookends (every session):
```
[timestamp] SESSION START — Level: L{n} | Spec: {spec-name}
[timestamp] SESSION END — {n} files written, {n} commands run, {n} blocked actions
```
