---
skill: apex-init
backend: claude
version: 1.2.0
last_updated: 2026-05-31
sources:
  - APEX Design Specification 2026-05-24
  - GSD (Get Shit Done) — github.com/gsd-build/get-shit-done
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

## Step 3: Write docs/status.md

Use the template from ~/.claude/skills/apex-orchestrate/templates/status-template.md.

Fill in:
- Project name: from answer to Question 1 (first 3-4 words)
- Description: full answer to Question 1
- Stack: confirmed stack from Question 3
- specialists_default: [] (empty to start — user adds as needed)

## Step 4: Confirm to user

"Project initialised. Here's what was created:

  docs/
    changes/        ← specs go here (ready for build)
    drafts/         ← specs-in-progress
    handoff/        ← session summaries
    technical/      ← ADRs, runbooks, architecture docs
      architecture/overview.md  ← System Overview (stub — planning fills it in)
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

## How it's structured
_The major pieces and how they fit — the shape of the system, not an API dump._

## Shaping decisions
_The handful of decisions that define the architecture. Each links to its ADR._

| Decision | Why (→ ADR) |
|----------|-------------|
| _e.g. Postgres over Mongo_ | [ADR-001](../adr/ADR-001-*.md) |
```
