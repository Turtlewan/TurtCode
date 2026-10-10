---
skill: apex-init
version: 1.7.4
last_updated: 2026-10-10
sources:
  - APEX Design Specification 2026-05-24
  - GSD (Get Shit Done) — github.com/gsd-build/get-shit-done
  - docs/technical/adr/ADR-005-stack-best-practice-skills.md
  - docs/technical/adr/ADR-013-app-flow-artifact.md
  - docs/technical/adr/ADR-014-living-capability-overview.md
  - docs/technical/adr/ADR-017-design-brief-artifact.md
  - docs/technical/adr/ADR-026-codex-third-model-family.md
staleness_threshold: 30d
description: >
  Use when bootstrapping a brand-new APEX project — triggered automatically when no
  docs/status.md exists. Scaffolds docs/, seeds PROJECT.md/REQUIREMENTS.md/ROADMAP.md/status.md
  and the System Overview stub. Not for projects that already have status.md.
---

# APEX Init — New Project Bootstrap

Triggered automatically by apex-orchestrate when no docs/status.md is found.
Sets up the project structure for APEX. Ask the questions, run stack selection, then scaffold.

## Persistent artifacts — why they matter

Each session starts fresh. Without persistent artifacts,
context is lost between sessions. These four files survive every session boundary
and are read **on demand**, not preloaded — no agent loads all four before it acts (ADR-037):

- **PROJECT.md** — vision statement (what and who) — read on demand during planning
- **REQUIREMENTS.md** — scope boundaries (in-scope / out-of-scope) — read on demand during planning
- **ROADMAP.md** — phase breakdown (filled once planning begins) — read on demand during planning
- **docs/status.md** — live state — read by the **host** at session start; **Codex never reads it** (the coder's contract is `AGENTS.md`, ADR-037)

## Step 1: Ask the bootstrap questions (one batch)

Ask all three together — do not drip them one at a time:

1. "What are you building? (1-2 sentences)"
2. "Who is it for? (users, internal team, just you, etc.)"
3. "Do you already have a stack in mind, or should we select one?"

**Never recommend a stack yourself, and never default to a JS/TS stack by reflex —
stack selection belongs to apex-stack.**

After the answers:
- User already has a firm stack → record it, and write its **verify commands into `AGENTS.md`**
  (`## Verify commands`) — that is the recipe's only home (ADR-037).
- User wants a recommendation (or is unsure) → **invoke `apex-stack`** before scaffolding;
  it selects merit-based across ecosystems, then writes the verify commands into AGENTS.md.
- User explicitly defers the decision → scaffold with stack "TBD"; leave the
  `<!-- apex:agents:verify -->` marker and its stub in place (until the stack is chosen), and add "Stack selection (apex-stack)" to
  ROADMAP.md phase 1 — it must run before the first build spec.

## Step 2: Create directory structure

Create the following in the current working directory (the project root):

```
docs/
  changes/
  drafts/
  handoff/
  technical/
    adr/
    architecture/
    runbooks/
    setup/
  product/
    api/
    guides/
    components/
    releases/
  audit/
```

Create these files in the project root if they don't already exist:
- CHANGELOG.md (with standard Keep a Changelog header)
- README.md (minimal — project name + 1-sentence description)
- PROJECT.md (vision statement — write from Question 1 + 2 answers)
- REQUIREMENTS.md (scope boundaries — stub with "In scope / Out of scope" sections)
- ROADMAP.md (phase direction — stub, to be filled during planning)
- AGENTS.md (Codex build instructions — seed from the AGENTS template; see "AGENTS.md" below)

Also seed the **System Overview stub** at `docs/technical/architecture/overview.md`
if it doesn't already exist (template below). Leave it as the stub — it carries the
`<!-- apex:overview:stub -->` marker so the doc-coverage check flags it as
"exists but not yet written." The host fills it in once the architecture
takes shape; do not write the real overview during bootstrap.

**Data-model stub — only for data-bearing projects (ADR-008).** If the confirmed stack
(Step 1 / apex-stack) includes a persistence layer (a database / ORM / local store), also seed the
**conceptual data-model stub** at `docs/technical/architecture/data-model.md` (template below). It
carries the `<!-- apex:data-model:stub -->` marker for the coverage check. If the project is
**stateless** (static site, pure CLI with no stored data), skip this file and add a line "No
persistent data model" under REQUIREMENTS.md → Out of scope. Leave it as a stub — planning fills the
entities/relationships in early; do not model data during bootstrap.

**App-flow stub — only for UI-bearing projects (ADR-013).** If the confirmed stack (Step 1 /
apex-stack) includes a frontend / screen surface (web UI, mobile, desktop app), also seed the **app-flow stub**
at `docs/technical/architecture/app-flow.md` (template below). It carries the
`<!-- apex:app-flow:stub -->` marker for the coverage check. If the project is **headless** (API-only,
pure CLI, library), skip this file and add a line "No UI flow" under REQUIREMENTS.md → Out of scope.
Leave it as a stub — planning maps screens/journeys early; do not design flows during bootstrap.

**Design-brief stub — only for UI-bearing projects (ADR-017).** Alongside app-flow.md, seed the
**design-brief stub** at `docs/technical/architecture/design-brief.md` (template below) for any
project with a screen surface. It carries the `<!-- apex:design-brief:stub -->` marker for the
coverage check. Same scope-gate as app-flow (skip for headless / CLI). Leave it a stub — planning
fills tokens + art-direction + forbidden-patterns once a visual direction is chosen, using the full
template at `~/.claude/skills/apex-plan/references/design-brief-template.md`; do not design
during bootstrap.

**AGENTS.md — Codex build instructions (ADR-026).** Seed `AGENTS.md` in the project root from
`~/.claude/skills/apex-orchestrate/templates/AGENTS-template.md`. The universal sections (the
build-a-spec workflow + hard rules) are verbatim. Fill **What this repo is** from PROJECT.md, and the
**Verify commands** from the chosen stack's real commands — install, lint, typecheck, test, build.
Replace the marker and entire stub with one fence directly under the exact heading `## Verify commands`
(blank lines only), and put notes after the closing fence. If the stack is TBD, leave the
`<!-- apex:agents:verify -->` marker and its stub in place (until the stack is chosen). **AGENTS.md is the recipe's only
home (ADR-037)** — Codex reads it natively and never sees status.md. Leave **Project layout** + **Conventions** as
`<!-- apex:agents:stub -->` blocks — planning fills them as code takes shape. AGENTS.md is the
Codex-facing projection of the project's build context (commands + hard-blocks + structure); it tracks
the stack recipe and hard-blocks, it is not hand-maintained in parallel with CLAUDE.md.

## Step 3: Write docs/status.md

Use the template from ~/.claude/skills/apex-orchestrate/templates/status-template.md.

Fill in:
- Project name: from answer to Question 1 (first 3-4 words)
- Description: full answer to Question 1
- Stack: the confirmed stack (from Step 1 / apex-stack), or "TBD" if deferred

## Step 4: Confirm to user

"Project initialised. Here's what was created:

  docs/
    changes/        ← specs go here (ready for build)
    drafts/         ← specs-in-progress
    handoff/        ← session summaries
    technical/      ← ADRs, runbooks, architecture docs
      architecture/overview.md  ← System Overview + living capability index (stub — planning fills it in)
      architecture/data-model.md ← conceptual data model (stub — data-bearing projects only)
      architecture/app-flow.md   ← app-flow: screens + journeys (stub — UI-bearing projects only)
      architecture/design-brief.md ← tokens + art-direction + don'ts the coder reads (stub — UI-bearing only)
    product/        ← user guides, API docs, changelog
  PROJECT.md        ← vision — read on demand during planning
  REQUIREMENTS.md   ← scope boundaries — read on demand during planning
  ROADMAP.md        ← phase direction — fill this during planning
  CHANGELOG.md
  README.md
  AGENTS.md         ← Codex build instructions (build-a-spec workflow + verify recipe + hard rules)

Running at L2 | Coder: Codex gpt-6.1-sol (Sonnet 5 fallback)

What do you want to build first?"

## Step 5: Hand back to apex-orchestrate

Return to normal orchestration after bootstrap. Do not do anything else.

## PROJECT.md initial content

```markdown
# {project-name}

## Vision
{one paragraph: what this is and why it exists}

## Users
{who it's for}

## Success looks like
{what "done" means for v1}
```

## REQUIREMENTS.md initial content

```markdown
# Requirements

## In scope
- {item}

## Out of scope
- {item}

## Open questions
- {question}
```

## ROADMAP.md initial content

```markdown
# Roadmap

Phases to be defined during planning.

| Phase | Goal | Status |
|-------|------|--------|
| 1 | {TBD} | Not started |
```

## CHANGELOG.md initial content

```markdown
# Changelog

All notable changes to this project will be documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]
```

## README.md initial content

```markdown
# {project-name}

{one-sentence description}
```

## docs/technical/architecture/overview.md initial content

Seed this verbatim (substitute `{project-name}`). The `<!-- apex:overview:stub -->`
marker stays until planning writes the real overview — it is what the doc-coverage
check greps for. Do not fill the sections during bootstrap.

```markdown
# {project-name} — System Overview

<!-- apex:overview:stub -->
> **STATUS: STUB.** Not yet written. The host fills this in once the
> architecture takes shape. Until then the doc-coverage check flags it as outstanding.

## What it does
_One or two paragraphs: what the system does, for whom, top-to-bottom readable._

## Capabilities (current truth)
_What the system does today — one terse line each (+ link to ADR/spec). Updated on every spec archive
to docs/changes/done/ (merge-on-archive, ADR-014). Keep it a terse index, not a scenario corpus._
-

## How it's structured
_The major pieces and how they fit — the shape of the system, not an API dump._

## Shaping decisions
_The handful of decisions that define the architecture. Each links to its ADR._

| Decision | Why (→ ADR) |
|----------|-------------|
| _e.g. Postgres over Mongo_ | [ADR-001](../adr/ADR-001-*.md) |
```

## docs/technical/architecture/data-model.md initial content

Seed this **only for data-bearing projects** (substitute `{project-name}`). The
`<!-- apex:data-model:stub -->` marker stays until planning writes the real model — it is what the
doc-coverage check greps for. Conceptual only — do **not** add physical schema (tables/columns/
types/indexes); that is designed per-feature in specs and reconciled against this.

```markdown
# {project-name} — Data Model (conceptual)

<!-- apex:data-model:stub -->
> **STATUS: STUB.** The conceptual domain model — the entities this system holds and how they
> relate. Planning fills this in early, before per-phase schema. Conceptual only: entities,
> relationships, invariants. **Not** physical schema — tables/columns/types/indexes/migrations are
> designed per-feature in specs, and must reconcile with this model.

## Entities
_Each: what it represents · key attributes (conceptual, not columns) · owning subsystem._

| Entity | Represents | Key attributes | Owner |
|--------|-----------|----------------|-------|

## Relationships
_How entities relate, with cardinality._

| From | → | To | Cardinality |
|------|---|----|-------------|

## Invariants
_Rules that must always hold across entities (e.g. "an Order always has ≥1 LineItem")._
-
```

## docs/technical/architecture/app-flow.md initial content

Seed this **only for UI-bearing projects** (substitute `{project-name}`). The
`<!-- apex:app-flow:stub -->` marker stays until planning maps the flows — it is what the
doc-coverage check greps for. Flow only — do **not** add visual design (layout/colour/component
styling); that stays planning judgment + Figma.

```markdown
# {project-name} — App-Flow (screens + journeys)

<!-- apex:app-flow:stub -->
> **STATUS: STUB.** The screen/route map and primary user journeys. Planning fills this in early,
> before per-screen feature specs. Flow only: screens, navigation, journeys, screen states +
> transitions. **Not** visual design — layout/styling stay judgment + Figma.

## Screens / routes
_Each: name · purpose · how it's reached._

| Screen / route | Purpose | Reached from |
|----------------|---------|--------------|

## Primary user journeys
_The key end-to-end paths a user takes through the screens._

1.

## Screen states & transitions
_Per screen: the states (empty / loading / error / loaded) and what transitions between them._
-
```

## docs/technical/architecture/design-brief.md initial content

Seed this **only for UI-bearing projects** (substitute `{project-name}`). The
`<!-- apex:design-brief:stub -->` marker stays until planning fills the brief — it is what the
doc-coverage check greps for. Tokens + art-direction + forbidden-patterns ONLY — per-screen visuals
stay judgment (app-flow.md owns screens). Full authoring template:
`~/.claude/skills/apex-plan/references/design-brief-template.md`.

```markdown
# {project-name} — Design Brief

<!-- apex:design-brief:stub -->
> **STATUS: STUB.** The visual source of truth the image-less coder reads (ADR-017): design tokens,
> art direction, and forbidden patterns. Planning fills this once a visual direction is chosen.
> Tokens + direction + don'ts ONLY — per-screen visuals stay judgment (app-flow.md owns screens).

## Tokens
_colour · type family + scale · spacing scale · radii · shadow — exact values, referenced by name._

## Art direction
_2–4 sentences: mood, references, what it must NOT feel like. + chosen feel → style-library style._

## Forbidden patterns
_project-specific don'ts (no gradient bg, no nested cards, no Inter, …)._
-
```
