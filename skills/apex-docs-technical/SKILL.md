---
skill: apex-docs-technical
backend: claude
version: 1.2.0
last_updated: 2026-06-03
sources:
  - APEX Design Specification 2026-05-24
  - ADR-001 (per-project documentation contract)
  - ADR-013 (app-flow artifact)
  - ADR-014 (living capability overview)
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

System Overview — the project's single "what + why" doc AND its **living capability index**
(ADR-014), readable top-to-bottom (~10 min):
- When: created at init as a stub; updated whenever an ADR is added, a component changes, **or a spec
  is archived to docs/changes/done/** (the merge-on-archive trigger below)
- Where: docs/technical/architecture/overview.md  (exactly one per project)
- Owner: planning (Claude) owns the narrative/rationale; the **merge-on-archive capability update** is
  a terse one-line append made at spec-archive time (coding mode / per-spec discipline)
- Format (Divio "Explanation"):
  1. What it does — purpose, one paragraph
  2. **Capabilities (current truth)** — the bulleted list of what the system does *today*, one terse
     line each (+ link to its ADR/spec). This is the living index — keep it a **terse index, not a
     scenario corpus** (token guardrail, ADR-014)
  3. How it's structured — components + data flow, narrative
  4. Shaping decisions — bulleted, each linking to its ADR (docs/technical/adr/ADR-NNN)
  5. Pointers — where ADRs, runbooks, setup live
- **Merge-on-archive (ADR-014):** when a spec moves to docs/changes/done/, fold its shipped capability
  into the Capabilities list as one line (added / modified / removed). This closes the loop so the
  archive is never write-only and the overview is always current-truth. If a project outgrows a
  one-page index, per-domain detail goes to docs/technical/architecture/capabilities/<domain>.md,
  loaded **on-demand only** — never auto-load the whole set.
- Rule: the Overview is the story; ADRs are the footnotes. Keep it current via the ADR/component/archive
  triggers above — not a rewrite every build. (The per-component architecture doc below is the
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

App-flow doc (UI-bearing projects only — ADR-013):
- When: a project has a UI / screen surface; captured early, before per-screen feature specs
- Where: docs/technical/architecture/app-flow.md  (exactly one per project)
- Owner: planning — the screen-map + journey-mapping technique is owned by apex-ui-ux-design
- Format: Screens/routes map → Primary user journeys → Screen states + transitions. **Flow only** —
  not visual design (layout/styling stay judgment + Figma)
- Rule: scope-gated — headless / API-only / pure-CLI projects skip it. Keep it flow-level; per-screen
  behaviour stays in the feature spec.

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
- [ ] System Overview's Capabilities list updated for every spec archived to docs/changes/done/ (merge-on-archive — ADR-014)
- [ ] App-flow doc exists and reflects current screens/journeys (UI-bearing projects only — ADR-013)
- [ ] ADR written for every non-obvious architectural choice this session
- [ ] Runbook exists for every new operational procedure
- [ ] Setup docs updated for any new environment requirement
- [ ] All docs reference specific file paths and commands — no vague instructions
