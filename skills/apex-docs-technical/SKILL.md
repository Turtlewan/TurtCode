---
skill: apex-docs-technical
version: 1.0.0
last_updated: 2026-05-24
sources:
  - APEX Design Specification 2026-05-24
staleness_threshold: 30d
---

# Technical Documentation Specialist — Planning Mode (Claude only)

## When to activate
Any architectural decision, new runbook requirement, setup documentation need,
or developer-facing documentation gap identified during planning.

## Documentation types and when to write them

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

- [ ] ADR written for every non-obvious architectural choice this session
- [ ] Runbook exists for every new operational procedure
- [ ] Setup docs updated for any new environment requirement
- [ ] All docs reference specific file paths and commands — no vague instructions
