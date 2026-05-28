---
skill: apex-docs-product
backend: claude
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Keep a Changelog — keepachangelog.com
  - Divio Documentation System — documentation.divio.com
  - Google Developer Documentation Style Guide — developers.google.com/style
staleness_threshold: 60d
---

# Product Documentation Specialist — Planning Mode

## When to activate

Planning what documentation to write before building it. Includes:
- "What docs do I need for this feature?"
- "How should I structure the README?"
- "What belongs in the changelog vs internal notes?"
- "How do I document this API for external users?"
- Designing a documentation site structure
- Deciding which doc type fits a piece of content

## The four doc types (Divio system)

Every piece of documentation is one of four types. Match the type before writing:

| Type | Answers | Tone | Example |
|------|---------|------|---------|
| **Tutorial** | "How do I get started?" | Step by step, hand-holding | Getting started guide |
| **How-to** | "How do I achieve X?" | Goal-oriented, assumes knowledge | "How to export data as CSV" |
| **Reference** | "What does X do?" | Precise, dry, complete | API reference, CLI flags |
| **Explanation** | "Why does it work this way?" | Conceptual, discusses trade-offs | Architecture overview |

Never mix types in a single document — split them.

## Questions to ask before designing docs

- Who is the reader? (end user / developer / ops / internal team)
- What is their starting knowledge level?
- What are they trying to accomplish?
- Where will this doc live? (README, docs site, inline, Notion)
- What triggers an update to this doc? (feature change, API change, release)

## README design — what goes where

A README is a tutorial + quick reference. Structure:

```markdown
# Project Name
One-sentence description — what it does, not how.

## Quick start
Fewest possible steps to get something running.
Code block with copy-paste commands.

## Features
Bullet list — what users can do. Link to how-to guides for each.

## Configuration
Key env vars / config options as a table: name | default | description.

## Contributing
Link to CONTRIBUTING.md (don't repeat it here).

## License
One line.
```

**Do not add** to README: architecture diagrams, internal dev notes, deployment steps
(those go in `docs/technical/`), full API reference (link to it).

## Changelog design

Use Keep a Changelog format. Rules for what belongs:

**Include (user-facing changes):**
- New features users can use
- Changed behaviour users will notice
- Bugs that affected users — describe what broke and what works now
- Deprecations users need to act on
- Removals that break existing usage

**Exclude (internal changes):**
- Refactors with no behaviour change
- Test additions
- CI/CD config changes
- Dependency upgrades (unless they surface a behaviour change)
- Internal tooling

**Section order:** Added → Changed → Deprecated → Removed → Fixed → Security

## API reference design

For every endpoint / function / CLI command, document:
1. What it does (one sentence)
2. Parameters / arguments — name, type, required/optional, description
3. Return value / response shape
4. Error cases — what errors it can throw, when
5. A working code example

## Documentation review checklist

- [ ] Doc type identified (tutorial / how-to / reference / explanation) — not mixed
- [ ] Audience defined — no jargon the reader won't know
- [ ] README updated if any user-facing behaviour changed
- [ ] Changelog entry written in [Unreleased] (if feature or fix)
- [ ] API reference updated for changed endpoints/functions
- [ ] No placeholder text ([TODO], TBD, coming soon) in publishable docs
- [ ] Code examples tested — they run as written
- [ ] Links checked — no dead references

## Hard blocks

- Do not document internal implementation details in user-facing docs
- Do not use "we" in docs — use "you" (user) and imperative mood
- Do not combine multiple doc types in one file — split first, then write
