---
skill: apex-architecture
backend: claude
version: 1.2.0
last_updated: 2026-06-01
sources:
  - Clean Architecture — Robert Martin
  - Twelve-Factor App — 12factor.net
staleness_threshold: 60d
description: >
  Use when making codebase-structure and system-shape decisions — monolith vs microservices,
  module/domain boundaries (DDD bounded contexts), data-model shape, dependency direction, or
  whether a decision needs an ADR. Triggers: "how should we structure this", "split into
  services?", "where do the boundaries go", "is this over-engineered". Not the distributed-
  systems / scale operational layer (→ apex-system-design), nor ADR file format & the doc
  system (→ apex-docs-technical).
---

# Architecture Specialist — Planning Mode (Claude only)

## When to activate
System design decisions, microservices vs monolith debate, data model design,
event-driven architecture, bounded contexts, scalability planning, ADR creation.

## Questions to ask before designing

- What are the natural domain boundaries in this system?
- What is the expected scale? When do we need to worry about it?
- What is the team's deployment and operational capability?
- What does the data model look like at steady state? Record the **conceptual** model (entities +
  relationships + invariants) in `docs/technical/architecture/data-model.md` — its single home, owned
  here; physical schema is designed per-phase via apex-data and reconciled against it (ADR-008).
- What are the consistency requirements? Is eventual consistency acceptable?

## Monolith vs microservices

Default recommendation: Start with a well-structured monolith.
Decompose into services only when: independent scaling is needed, team size demands it,
or deployment cadence of components diverges significantly.

Modular monolith pattern: domain-separated modules with clear interfaces, no cross-module
direct database access, extractable to services when needed.

## ADR process

Write an ADR for any decision that:
- Cannot be easily reversed
- Involves a trade-off between meaningful alternatives
- Other engineers would reasonably question in a code review

ADR format: Context (why decision needed) → Decision (what) → Consequences (what it means).

## Review checklist

- [ ] Domain boundaries are clear — no circular dependencies between domains
- [ ] Shared database access is controlled — no cross-domain direct table access
- [ ] External dependencies are behind interfaces (not imported directly throughout)
- [ ] ADR written for any non-obvious architectural choice
- [ ] Data model normalised appropriately for the access patterns

## Standards

Clean Architecture — Robert Martin
Domain-Driven Design — Eric Evans (bounded contexts)
Twelve-Factor App — 12factor.net
