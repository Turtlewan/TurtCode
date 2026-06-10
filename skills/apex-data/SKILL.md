---
skill: apex-data
backend: claude
version: 1.4.0
last_updated: 2026-06-10
sources:
  - Prisma Migrations — prisma.io/docs/guides/database/developing-with-prisma-migrate
  - Alembic — alembic.sqlalchemy.org
staleness_threshold: 30d
description: >
  Use when designing database schema or migrations — new tables/columns/indexes, breaking schema
  changes, zero-downtime migration strategy, backfills, integrity constraints, query-pattern
  indexing. The safety rules are stack-neutral (expand/contract, nullable-then-backfill, FK
  indexing); the migration tool is per-stack — Prisma (TS) / Alembic (Python) / SwiftData or GRDB
  (Apple), see § Stack assumptions. Not the coding-mode enforcement rules (that's impl.md).
---

# Data Specialist — Planning Mode

## Stack assumptions

The migration-safety rules here are **stack-neutral** — they govern relational schema evolution
regardless of tool. The concrete ORM / migration tool is per-stack: **Prisma** (TypeScript) /
**SQLAlchemy + Alembic** or **SQLModel** (Python) / **SwiftData** or **GRDB** (Apple). Where a rule
names Prisma below, read it as the illustration; the rule itself is tool-agnostic.

## When to activate
Database schema changes, migrations, ORM model changes (Prisma / SQLAlchemy / SwiftData / …), data
pipelines, query optimisation, data integrity constraints.

## Questions to ask before designing

- Does this introduce or change an **entity**? Reconcile the schema against the conceptual model at
  `docs/technical/architecture/data-model.md` (the single anchor for the whole entity set); add any
  new entity/relationship to it so per-phase schema stays coherent (ADR-008). Physical schema here,
  conceptual model there — they must agree.
- Is this a breaking schema change? What is the migration strategy?
- Are there existing rows to backfill? How many?
- What indexes are needed for the expected query patterns?
- What are the data integrity requirements? (uniqueness, foreign keys, nullability)
- Can this migration run without downtime?

## Migration safety rules

Zero-downtime migration order for adding a required column:
1. Add column as nullable (migration 1, deploy)
2. Backfill existing rows (script)
3. Add NOT NULL constraint after backfill (migration 2, deploy)

Never rename a column in one migration — add new, backfill, remove old.

## Review checklist

- [ ] Migration is reversible (or rollback strategy documented)
- [ ] Indexes added for all foreign keys and frequently-queried columns
- [ ] NOT NULL columns have default values or migration handles backfill
- [ ] Unique constraints defined for business-unique fields
- [ ] Large table migrations reviewed for lock impact
- [ ] Schema reconciles with the conceptual model (`data-model.md`); any new entity added to it

External data gathering (scraping, repo packing, live docs) is out of scope here — see apex-research.
