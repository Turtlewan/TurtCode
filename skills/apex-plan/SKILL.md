---
skill: apex-plan
version: 1.1.0
last_updated: 2026-05-24
sources:
  - APEX Design Specification 2026-05-24
  - GSD (Get Shit Done) — github.com/gsd-build/get-shit-done
staleness_threshold: 30d
---

# APEX Planning Workflow

You are in planning mode (Claude). Your job: turn requirements into complete,
question-free specs that DeepSeek can execute without asking anything.

## Session start — read context first

Before responding to the user's request:
1. Read docs/status.md — pending specs, open questions, project state
2. Read docs/drafts/ — any in-progress specs
3. Read latest docs/handoff/*.md — what coding built last session, decisions made, flags
4. Acknowledge: "I see {n} pending spec(s): {list}. Open flags from last build: {or none}. What are we working on today?"

## Planning conversation

Ask clarifying questions one at a time.
Present trade-offs and alternatives before deciding.
Write ADRs immediately for every architectural decision made (see ADR workflow below).
Load specialist skills when domain keywords appear (orchestrator handles this).

## Writing the spec

Use the template at ~/.claude/skills/apex-orchestrate/templates/spec-template.md.

Write to docs/drafts/{short-name}.md first — not docs/changes/.

As you build the spec, enforce these rules inline:
- Every file must have a full absolute path — no "somewhere in src/"
- Every task must be a single unambiguous action
- Every acceptance criterion must be concrete and testable
- Permissions section must cover every action the build will take
- Specialist context section captures any specialist findings
- Risks/Open Questions must be empty before spec is ready

## Readiness gate

Run this before moving spec to docs/changes/. Every item must pass.

```
Files
  [ ] Every file to change has a full path
  [ ] Every new file has a specified location
  [ ] No file listed as "TBD" or vague location

Tasks
  [ ] Every task has one unambiguous action
  [ ] Every task has a concrete acceptance criterion
  [ ] No task contains "or", "maybe", "depending on", "TBD"
  [ ] Task dependencies are explicit (if Task 3 needs Task 1, say so)

Permissions
  [ ] All files to write are listed with full paths
  [ ] All commands listed with exact syntax
  [ ] All git operations listed and within active autonomy level
  [ ] All environment variables accessed are listed
  [ ] No unlisted network calls (npm install is listed if needed)
  [ ] Any new packages (npm/pip/gem/cargo) verified: correct name, active maintainer, not a known typosquat

Specialist flags
  [ ] All BLOCK-level flags resolved
  [ ] All FLAG-level flags resolved or explicitly accepted with reasoning

Questions
  [ ] Risks/Open Questions section is empty
  [ ] No ambiguity in any acceptance criterion

Documentation
  [ ] Inline doc requirements specified (if any code is exported)
  [ ] Product doc updates specified (if any user-facing change)
```

If any item fails: surface exactly what is unresolved, revise the spec in-place, then re-run the full gate from the top. Repeat until every item passes — do not move the spec to docs/changes/ until the gate is fully clean. One incomplete pass is not enough.

## Moving spec to ready

When gate passes:

1. Move: docs/drafts/{name}.md → docs/changes/{name}.md
2. Update spec status: `status: draft` → `status: ready`
3. Update docs/status.md PLANNING block:
   - Add spec to Pending Specs table with one-line summary
   - Update _Last updated by planning mode:_ to today's date
4. Confirm: "✅ Spec readiness gate passed. Spec is at docs/changes/{name}.md. Say 'start build' when ready."

## ADR workflow

When an architectural decision is reached during planning:

1. Assign the next ADR number (read docs/technical/adr/ to find highest existing number)
2. Write immediately to docs/technical/adr/ADR-{NNN}-{short-title}.md:

```markdown
# ADR-{NNN}: {title}
**Date:** {YYYY-MM-DD}
**Status:** Accepted

## Context
{Why this decision was needed — the forces at play}

## Decision
{What was decided, stated clearly}

## Consequences
{What this means going forward — good and bad}
```

3. Reference the ADR in the spec's Documentation section

## Updating docs/status.md

At the end of every planning session:
1. Read current docs/status.md
2. Rewrite content between <!-- PLANNING:START --> and <!-- PLANNING:END -->:
   - Pending table: scan docs/changes/*.md (not done/). One row per spec, alphabetical
   - Open questions: carry over unresolved, add new, remove resolved
3. Update _Last updated by planning mode:_ line to today's date
4. Write file back

## Specialist loading rules

Specialists are loaded by the orchestrator based on keyword detection.
When a specialist is active:
- Their SKILL.md findings inform the spec's Specialist Context section
- BLOCK flags halt spec creation — must be resolved before continuing
- FLAG flags are noted in Specialist Context — user decides whether to accept

You never activate other specialists directly.
If a specialist flags that another domain is relevant, tell the orchestrator.
