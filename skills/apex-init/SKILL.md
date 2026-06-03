---
skill: apex-init
backend: claude
version: 1.4.0
last_updated: 2026-06-03
sources:
  - APEX Design Specification 2026-05-24
  - GSD (Get Shit Done) — github.com/gsd-build/get-shit-done
  - docs/technical/adr/ADR-005-stack-best-practice-skills.md
  - docs/technical/adr/ADR-013-app-flow-artifact.md
  - docs/technical/adr/ADR-014-living-capability-overview.md
staleness_threshold: 30d
description: >
  Use when bootstrapping a brand-new APEX project — triggered automatically by
  apex-orchestrate when no docs/status.md exists in the project directory.
  Scaffolds the docs/ tree, seeds PROJECT.md / REQUIREMENTS.md / ROADMAP.md /
  status.md and the System Overview stub, then hands back. Not for projects that
  already have a status.md (that's normal orchestration).
---

# APEX Init — New Project Bootstrap

Triggered automatically by apex-orchestrate when no docs/status.md is found.
Sets up the project structure for APEX. Ask three questions, then scaffold.

## Persistent artifacts — why they matter

Each planning and coding session starts fresh. Without persistent artifacts,
context is lost between sessions. These four files survive every session boundary
and are loaded by every new agent before it acts:

- **PROJECT.md** — vision statement (what and who)
- **REQUIREMENTS.md** — scope boundaries (in-scope / out-of-scope)
- **ROADMAP.md** — phase breakdown (filled once planning begins)
- **docs/status.md** — live state (decisions, in-flight work, pending specs)

## Step 1: Ask three questions (one at a time)

Question 1:
"This looks like a new project. What are you building? (1-2 sentences)"

Wait for answer. Then:

Question 2:
"Who is it for? (users, internal team, just you, etc.)"

Wait for answer. Then:

Question 3:
"I recommend: Next.js 15 + TypeScript + Tailwind + PostgreSQL + Prisma.
Does that work, or do you have a different stack in mind?"

Wait for answer.

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

Also seed the **System Overview stub** at `docs/technical/architecture/overview.md`
if it doesn't already exist (template below). Leave it as the stub — it carries the
`<!-- apex:overview:stub -->` marker so planning mode's coverage check flags it as
"exists but not yet written." Planning fills it in (in Claude) once the architecture
takes shape; do not write the real overview during bootstrap.

**Data-model stub — only for data-bearing projects (ADR-008).** If the confirmed stack
(Question 3) includes a persistence layer (a database / ORM / local store), also seed the
**conceptual data-model stub** at `docs/technical/architecture/data-model.md` (template below). It
carries the `<!-- apex:data-model:stub -->` marker for the coverage check. If the project is
**stateless** (static site, pure CLI with no stored data), skip this file and add a line "No
persistent data model" under REQUIREMENTS.md → Out of scope. Leave it as a stub — planning fills the
entities/relationships in early; do not model data during bootstrap.

**App-flow stub — only for UI-bearing projects (ADR-013).** If the confirmed stack (Question 3)
includes a frontend / screen surface (web UI, mobile, desktop app), also seed the **app-flow stub**
at `docs/technical/architecture/app-flow.md` (template below). It carries the
`<!-- apex:app-flow:stub -->` marker for the coverage check. If the project is **headless** (API-only,
pure CLI, library), skip this file and add a line "No UI flow" under REQUIREMENTS.md → Out of scope.
Leave it as a stub — planning maps screens/journeys early; do not design flows during bootstrap.

## Step 3: Write docs/status.md

Use the template from ~/.claude/skills/apex-orchestrate/templates/status-template.md.

Fill in:
- Project name: from answer to Question 1 (first 3-4 words)
- Description: full answer to Question 1
- Stack: confirmed stack from Question 3
- specialists_default: [] (empty to start — user adds as needed)
- stack_skills: [] (empty to start — apex-stack's coverage gate records bound stack skills later)

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
    product/        ← user guides, API docs, changelog
  PROJECT.md        ← vision — loaded by every new agent
  REQUIREMENTS.md   ← scope boundaries — loaded by every new agent
  ROADMAP.md        ← phase direction — fill this during planning
  CHANGELOG.md
  README.md

Running at L2 | Profile: balanced | Mode: planning

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
> **STATUS: STUB.** Not yet written. Planning mode (Claude) fills this in once the
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
types/indexes); that is designed per-feature in specs via `apex-data` and reconciled against this.

```markdown
# {project-name} — Data Model (conceptual)

<!-- apex:data-model:stub -->
> **STATUS: STUB.** The conceptual domain model — the entities this system holds and how they
> relate. Planning fills this in early, before per-phase schema. Conceptual only: entities,
> relationships, invariants. **Not** physical schema — tables/columns/types/indexes/migrations are
> designed per-feature in specs via apex-data, and must reconcile with this model.

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
