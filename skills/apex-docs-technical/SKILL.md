---
skill: apex-docs-technical
backend: claude
version: 1.1.0
last_updated: 2026-05-31
sources:
  - APEX Design Specification 2026-05-24
  - ADR-001 (per-project documentation contract)
staleness_threshold: 30d
description: >
  Use when planning a project's technical documentation — ADRs, the System Overview,
  runbooks, architecture or setup docs. Triggers: an architectural decision was just made,
  a new operational procedure, a setup/onboarding gap, or "what does this system do / why
  did we do X". Not for user-facing docs (that's apex-docs-product).
---

# Technical Documentation Specialist — Planning Mode (Claude only)

## When to activate
Any architectural decision, new runbook requirement, setup documentation need,
or developer-facing documentation gap identified during planning.

## Documentation types and when to write them

System Overview — the project's single "what + why" doc, readable top-to-bottom (~10 min):
- When: created at init as a stub; updated whenever an ADR is added or a component changes
- Where: docs/technical/architecture/overview.md  (exactly one per project)
- Owner: planning (Claude) — never delegate to coding; the narrative/rationale is judgment-heavy
- Format (Divio "Explanation"):
  1. What it does — purpose, one paragraph
  2. How it's structured — components + data flow, narrative
  3. Shaping decisions — bulleted, each linking to its ADR (docs/technical/adr/ADR-NNN)
  4. Pointers — where ADRs, runbooks, setup live
- Rule: the Overview is the story; ADRs are the footnotes. Keep it current via the ADR/component
  trigger above — not a rewrite every build. (The per-component architecture doc below is the
  deeper dive, reserved for larger systems.)

ADR (Architecture Decision Record):
- When: any non-obvious architectural decision with meaningful alternatives
- Where: docs/technical/adr/ADR-NNN-short-title.md
- Format: Context → Decision → Consequences
- Rule: write immediately when decision is made, not deferred

Runbook:
- When: any new operational procedure (deployment, rollback, incident response)
- Where: docs/technical/runbooks/procedure-name.md
- Format: When to use → Steps (numbered) → Verify → Rollback

Architecture doc:
- When: new system component or significant design change
- Where: docs/technical/architecture/component-name.md
- Format: Overview → Components → Data flow → Interfaces

Developer setup doc:
- When: new tool, dependency, or environment requirement added
- Where: docs/technical/setup/topic.md
- Format: Prerequisites → Steps → Verify → Troubleshooting

## ADR format

```markdown
# ADR-{NNN}: {title}
**Date:** YYYY-MM-DD
**Status:** Accepted | Superseded by ADR-NNN

## Context
{Why this decision was needed — the forces at play, constraints, background}

## Decision
{What was decided, stated as a single clear sentence. Then explanation.}

## Consequences
**Good:** {positive outcomes}
**Bad:** {trade-offs accepted}
**Neutral:** {things that change but aren't inherently good or bad}
```

## Review checklist

- [ ] System Overview exists and reflects the latest ADRs/components (seeded at init; updated when an ADR lands)
- [ ] ADR written for every non-obvious architectural choice this session
- [ ] Runbook exists for every new operational procedure
- [ ] Setup docs updated for any new environment requirement
- [ ] All docs reference specific file paths and commands — no vague instructions
