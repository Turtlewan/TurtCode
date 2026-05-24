# Coding Mode Agent Pipeline — Design Spec

**Date:** 2026-05-13
**Status:** Approved — pending implementation

---

## Overview

A five-agent pipeline for coding mode (DeepSeek backend) that takes a technical change spec, implements it with maximum parallelism, reviews the output, and produces a handoff doc — all in a single invocation.

---

## 1. Architecture

Five agent files in `~/.claude/agents/`:

```
coding-pipeline.md   ← orchestrator (the one you invoke)
code-writer.md       ← dependency analyser + parallel planner
code-worker.md       ← executes one isolated task (spawned in parallel)
code-reviewer.md     ← reviews all changes, flags issues (non-blocking)
doc-writer.md        ← writes docs/handoff/YYYY-MM-DD.md
```

### Pipeline flow

```
User: coding-pipeline docs/changes/feature-x.md [options]
          ↓
coding-pipeline reads spec, checks docs/changes/ and docs/handoff/
          ↓
code-writer analyses spec → builds dependency graph → groups tasks
          ↓
  ┌─ code-worker (task A) ─┐
  ├─ code-worker (task B) ─┤  ← parallel group 1
  └─ code-worker (task C) ─┘
          ↓ (wait for group 1)
  ┌─ code-worker (task D) ─┐  ← sequential group 2 (depends on A/B/C)
          ↓
code-reviewer reads all changed files → flags issues
          ↓
[question batch presented to user if not --auto]
          ↓
doc-writer writes docs/handoff/YYYY-MM-DD.md
          ↓
spec moved to docs/changes/done/
```

### Tool restrictions

| Agent | Tools |
|---|---|
| `coding-pipeline` | Read, Glob, Agent |
| `code-writer` | Read, Glob, Grep, Agent |
| `code-worker` | Read, Glob, Grep, Edit, Write, Bash |
| `code-reviewer` | Read, Glob, Grep |
| `doc-writer` | Read, Write |

The orchestrator and planner cannot write code. Only `code-worker` touches files.

---

## 2. Agent Behaviours

### coding-pipeline (orchestrator)

**Inputs:** spec path (optional), options flags

**Behaviour:**
1. If no spec path given, list `docs/changes/*.md` and ask which to run.
2. Read the spec and the latest `docs/handoff/*.md` for prior context.
3. Spawn `code-writer` with the spec content and all flags.
4. If `--dry-run`: receive the dependency plan from code-writer, present it to the user, and stop. No further steps.
5. Receive code-writer's completed task summary.
6. Spawn `code-reviewer` with spec + list of changed files.
7. Collect all deferred questions from code-writer and code-reviewer.
8. If not `--auto`: present question batch to user. Wait for response or "proceed".
9. Spawn `doc-writer` with spec + task summary + reviewer flags + resolved questions.
10. Report completion.

**Never writes code or docs directly** — only delegates.

---

### code-writer (dependency analyser + planner)

**Inputs:** spec content

**Behaviour:**
1. Parse the spec — extract all tasks (files to create/modify, commands to run).
2. Analyse dependencies:
   - Tasks touching different files with no shared imports → **parallel**
   - Tasks where one's output is another's input → **sequential**
   - Tasks modifying shared config, types, or schema → **sequential**
3. Build an ordered execution plan: groups of parallel tasks, sequenced by dependency.
4. For `--dry-run`: output the plan and stop.
5. Execute each group:
   - Spawn one `code-worker` per task in the group (parallel).
   - Wait for all workers in the group to finish before starting the next group.
6. Collect results and deferred questions from all workers.
7. Return: list of files changed, one-line summary per change, deferred questions.

**Deferred question rule:** if uncertain about a task, proceed with best judgment, log the question with reasoning, and continue. Never stop to ask.

---

### code-worker (task executor)

**Inputs:** one isolated task from the spec (files to change, exact changes, acceptance criteria)

**Behaviour:**
1. Read all relevant existing files before making changes.
2. Implement exactly what the task describes — no extras.
3. Run any specified commands (build, lint, test) and report results.
4. Return: files changed, brief summary, any deferred questions.

**Deferred question rule:** same as code-writer — proceed, log, continue.

---

### code-reviewer (advisory reviewer)

**Inputs:** spec + list of files changed by code-writer

**Behaviour:**
1. Read each changed file.
2. Check against the spec's acceptance criteria.
3. Flag any of the following (non-blocking — never rewrites code):
   - Missed requirements
   - Bugs or logic errors
   - Risky patterns worth addressing
   - Anything that diverges from the spec
4. If nothing to flag: say "No issues found."
5. Return: flagged issues list (or clean bill of health).

---

### doc-writer

**Inputs:** spec + code-writer summary + reviewer flags + resolved questions

**Behaviour:**
1. Write `docs/handoff/YYYY-MM-DD.md` with:
   - **What was built** — summary of everything implemented.
   - **Files changed** — full list.
   - **Current state** — does it build? Tests pass? Known issues?
   - **Specs completed** — which spec was executed.
   - **Reviewer flags** — issues flagged (or "None").
   - **Decisions & open questions** — deferred decisions made + anything unresolved (always present in `--auto` mode).
   - **What's next** — suggested follow-up for planning mode.
2. Move the executed spec from `docs/changes/` to `docs/changes/done/`.

---

## 3. Command Interface

```
coding-pipeline [spec-path] [options]
```

### Options

| Flag | Behaviour |
|---|---|
| *(none)* | Full pipeline, batch questions/issues to user before writing docs |
| `--auto` | Full autonomy — no question batch, everything logged in handoff doc |
| `--workers <n>` | Cap on parallel code-worker agents (default: unlimited) |
| `--model <id>` | Override model for all worker agents |
| `--dry-run` | Show dependency plan and task groups, no execution |

### Examples

```bash
coding-pipeline docs/changes/auth.md
coding-pipeline docs/changes/api.md --auto
coding-pipeline docs/changes/refactor.md --dry-run
coding-pipeline docs/changes/feature.md --auto --workers 4
coding-pipeline docs/changes/feature.md --model deepseek-chat
```

### Question batch (default mode)

Before doc-writer runs, the orchestrator presents all deferred questions:

```
Pipeline complete. Before I write the handoff doc, here are the
decisions I made and questions I deferred:

[code-writer] Assumed X because spec was ambiguous on Y — confirm?
[code-reviewer] Flag: pattern Z looks risky, worth addressing?
[code-worker:task-A] Chose approach A over B for performance — ok?

Answer any you want to address, or say "proceed" to write the docs as-is.
```

In `--auto` mode this step is skipped entirely.

---

## 4. Folder Structure

Every project using this pipeline should have:

```
docs/
  changes/          ← planning mode writes specs here
    <name>.md
    done/           ← completed specs moved here by doc-writer
  handoff/          ← doc-writer writes session summaries here
    YYYY-MM-DD.md
```

---

## 5. Implementation Notes

- All five agents live in `~/.claude/agents/` (global, available in all projects).
- `permissionMode: bypassPermissions` is set on all agents when `--auto` is passed by the orchestrator at spawn time.
- The `model` frontmatter field in each agent should be set to `sonnet` (maps to whatever DeepSeek model is configured) unless `--model` overrides it.
- `code-worker` is the only agent with write access — this is the trust boundary.
- The pipeline is designed for DeepSeek (coding mode) only. Running it in planning mode will be blocked by the PreToolUse hook for any write operations.
