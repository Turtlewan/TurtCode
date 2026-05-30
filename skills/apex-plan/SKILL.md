---
skill: apex-plan
backend: claude
version: 1.5.0
last_updated: 2026-05-30
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
1. Read docs/status.md — pending specs, open questions, project state, parked items
2. Read docs/drafts/ — any in-progress specs
3. Read the latest docs/handoff/*.md — the *thin* handoff: decisions, specialist flags,
   blocked actions, discoveries. (What changed lives in git, not the handoff — run
   `git log` / `git diff` only if you need the file-level history. Build/test status and
   in-progress position are in status.md.)
4. Acknowledge: "I see {n} pending spec(s): {list}. Open flags from last build: {or none}. What are we working on today?"

### Drain the handoff — inbox-zero before the session closes

The handoff is a read-once inbox. Surfacing an item is **not** landing it — an item read
and not filed is lost. **Every handoff item must terminate in exactly one of:**
1. **Pending Spec** — queue/write a spec (blocked actions and "review needed ⚠️" decisions often land here)
2. **Open Question** — add to status.md Open Questions (an unresolved decision, e.g. an architecture call to make later)
3. **Folded** — incorporated into existing state *now* (e.g. a gotcha written into a spec/skill/ADR)
4. **Discarded** — explicitly judged not actionable

Land each item's disposition **this session** — do not defer it to "later." The latest
handoff is read once and never auto-read again, so an undrained item is gone.

## Planning mode toggle

Before any planning work, ask the user which mode to use:

> "Pick a planning mode:
> - **Deep Details** (heavy) — full spec template, readiness gate, ADRs, specialist loading
> - **Light** (medium) — intent doc only, key decisions, acceptance criteria, no gate
> - **Bug Fix** (lightest) — bug description, root cause, fix approach, files to touch"

Wait for their choice. This determines everything below.

## Planning conversation

### Elicit intent before drafting — front-load the build-changing decisions

DeepSeek executes literally and cannot fill gaps, so **all judgment must be resolved before
the spec freezes** — and planning is the only place that can happen. Pull the decisions you
need *before* drafting; do not draft-then-validate.

- **Resolve yourself — don't ask:** codebase facts (read the files), clear technical defaults
  (defaults-not-menus), anything derivable from patterns or research. Asking these wastes the
  user's attention.
- **Ask the user — before drafting:** product intent, preferences among technically-valid
  options (taste/business), edge-case priorities, "what does good look like." Judgment, not facts.
- **Bound the ask:** surface only decisions that (a) planning cannot resolve itself **and**
  (b) change what gets built. Fails either test → don't ask it.
- **Batch and target** (AskUserQuestion-style) — a focused set of the genuine forks, not a
  drip of one-question-at-a-time, and not an exhaustive questionnaire.

Why front-load: this is the primary mechanism for reliable AFK builds — every decision
resolved here is a mid-build fork that never happens. A planning-time question is cheap
(you're here, nothing in flight); a build-time fork stalls the build, forces a context
switch, and may need a re-spec. Asymmetric cost → heavier planning is the cheaper path.
(The "coding asks at a fork" rule is the safety net; this is the primary mechanism.)

### Think Before Speccing

Before writing any spec section, state your interpretation of the request explicitly.
If multiple interpretations are valid, present them — do not silently pick one.

> "I'm reading this as X. An alternative interpretation is Y. I'm going with X because Z.
> Does that match your intent?"

If something is genuinely unclear, stop. Name what's confusing. Do not fill in the gap
with an assumption that isn't written down somewhere — write it in `## Assumptions` instead.
Present trade-offs and alternatives before deciding.
Write ADRs immediately for every architectural decision made (see ADR workflow below) — **Deep Details only**.
Load specialist skills when domain keywords appear (orchestrator handles this) — **Deep Details only**.

## Writing the spec — by mode

### Deep Details mode

Use the template at ~/.claude/skills/apex-orchestrate/templates/spec-template.md.

Write to docs/drafts/{short-name}.md first — not docs/changes/.

Split rule: if the spec touches more than 3 files or has more than 2 logical phases, split it into separate specs before proceeding.

As you build the spec, enforce these rules inline:
- Every file must have a full absolute path
- Every task must be a single unambiguous action that **names its exact files** — never
  "update the auth flow" (forces the worker to explore = context cost + judgment, DeepSeek's
  weakest areas)
- Every acceptance criterion must be concrete and testable
- Permissions section must cover every action the build will take
- Specialist context section captures any specialist findings
- Risks/Open Questions must be empty before spec is ready

**A spec is an execution script, not a design doc — rich on the *what*, stripped of the *why*:**
- **Scope = a one-line identity** (what this builds, for routing/review/recall), optionally
  + a single ADR/discussion link. Not a rationale paragraph.
- **No *why* inline.** Litmus when tempted: does it change what gets built? **No** → cut it
  (home = ADR / planning discussion). **Yes** → don't add the why, make the *what* explicit.
- **Cross-cutting conventions live in the skill's `impl.md`, never copied into the spec** —
  the spec is the task-specific delta; the skill is the shared baseline.

**Karpathy rules while writing:**
- Every `## Assumptions` item must say what happens if it's wrong (`Stop | Caution | Low`)
- Every `## Acceptance Criteria` item must use step→verify format — no vague criteria
- Every `## Tasks` item must have a "done when:" clause — observable, not "it works"
- Every file in `## Files to Change` must be strictly necessary — no speculative additions

Then run the Readiness Gate (below). Only move to docs/changes/ when it passes.

### Light mode

Write an intent doc directly to docs/changes/{short-name}.md (skip drafts/). Structure:

```markdown
## Intent
{2-3 sentences: what to build and why}

## Key decisions
- {why this way — non-obvious trade-offs Claude resolved}

## Gotchas / edge cases
{things DeepSeek might miss, subtle interactions, ordering constraints}

## Files to touch
- {full path} — {what changes broadly}
```

**What planning provides:** intent clarity, trade-off reasoning, and edge-case awareness that Claude is uniquely good at but would be lost once the session ends.

**What coding mode backfills:** task breakdown, implementation order, acceptance criteria, test strategy.

No readiness gate. No ADRs. No specialist context. **Light mode quality check (no gate, but run this before confirming):**
- Assumptions block written? Every non-obvious assumption stated.
- Is there a simpler intent that achieves the same goal? If so, write that.
- Every file listed in "Files to touch" is strictly necessary?
- Acceptance criteria (if any) use observable outcomes, not vague descriptions.

If any answer is "no": revise before confirming with user.

Verify decisions are clear, then confirm with the user before moving on.

### Bug Fix mode

Call `apex-debug` — the debug specialist handles the investigation. It reads the bug description, investigates root cause, and produces the fix doc.

Template the specialist produces (it goes directly to docs/changes/{short-name}.md):

```markdown
## Bug
{one paragraph — what actually happens vs what should happen}

## Root cause
{cause identified during investigation}

## Fix approach
{1-3 sentences}

## Files to touch
- {full path} — {why}
```

**Flow:**
1. User describes the bug
2. Route to `apex-debug` via Skill tool
3. Debug specialist investigates, produces the fix doc
4. Confirm with user: "Bug fix doc at docs/changes/{name}.md — ready for build?"

No readiness gate. No ADRs. No status.md update. No planning conversation — investigation is the planning.

## Readiness gate — Deep Details only

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
  [ ] Risks/Open Questions section removed from spec (not emptied — deleted)
  [ ] No ambiguity in any acceptance criterion

Karpathy Quality Gate
  [ ] Assumptions: every non-obvious assumption is written in ## Assumptions with impact level
  [ ] Complexity challenge: "Is there a simpler spec that achieves the same goal?"
      — answered explicitly in the Simplicity check line of ## Assumptions
  [ ] Acceptance criteria: every item uses step→verify format — no item says "it works" or "it passes"
  [ ] Tasks: every item has a "done when:" clause
  [ ] Surgical scope: every file in ## Files to Change maps to at least one task
      — no file is listed "just in case" or "while we're in there"
  [ ] No task contains work beyond what was explicitly requested

Documentation
  [ ] Inline doc requirements specified (if any code is exported)
  [ ] Product doc updates specified (if any user-facing change)
```

If any item fails: surface what is unresolved, revise in-place, re-run gate from top. Repeat until clean.

## Moving spec to ready — by mode

### Deep Details
1. Move: docs/drafts/{name}.md → docs/changes/{name}.md
2. Update spec status: `status: draft` → `status: ready`
3. Update docs/status.md PLANNING block:
   - Add spec to Pending Specs table with one-line summary
   - Update _Last updated by planning mode:_ to today
4. Confirm: "✅ Spec ready at docs/changes/{name}.md. Say 'start build' when ready."

### Light
1. Confirm with user: "Intent doc at docs/changes/{name}.md — ready for build?"
2. If yes: update docs/status.md PLANNING block (add to Pending table). No gate.
3. If no: revise.

### Bug Fix
1. Confirm with user: "Bug fix doc at docs/changes/{name}.md — ready for build?"
2. If yes: no status.md update. Coding mode will fix it immediately.
3. If no: revise.

## ADR workflow — Deep Details only

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

**Light / Bug Fix modes:** note decisions inline in the spec doc. Skip formal ADRs.

## Updating docs/status.md — by mode

### Deep Details / Light
At the end of every planning session:
1. Read current docs/status.md
2. Rewrite content between <!-- PLANNING:START --> and <!-- PLANNING:END -->:
   - Pending table: scan docs/changes/*.md (not done/). One row per spec, alphabetical
   - Open questions: carry over unresolved, add new, remove resolved
3. Update _Last updated by planning mode:_ line to today's date
4. Write file back

### Bug Fix
No status.md update. Bug fix docs are ephemeral — consumed and archived in one coding session.

## Specialist loading rules — Deep Details only

Specialists are loaded by the orchestrator based on keyword detection.
When a specialist is active:
- Their SKILL.md findings inform the spec's Specialist Context section
- BLOCK flags halt spec creation — must be resolved before continuing
- FLAG flags are noted in Specialist Context — user decides whether to accept

You never activate other specialists directly.
If a specialist flags that another domain is relevant, tell the orchestrator.

**Light / Bug Fix modes:** skip specialist loading entirely.
