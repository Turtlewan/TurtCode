---
skill: apex-data
backend: coding
version: 1.2.0
last_updated: 2026-06-10
sources:
  - Prisma Migrations — prisma.io/docs/guides/database/developing-with-prisma-migrate
  - Alembic — alembic.sqlalchemy.org
  - SP5 de-coupling (stack-neutral core; Prisma/TS illustration)
staleness_threshold: 30d
description: >
  Coding-mode rules for database schema & migrations — stack-neutral invariants (no NOT NULL
  without default/backfill, no rename-in-one-migration, index every foreign key, immutable
  committed migrations, explicit cascade). Loaded when a task adds/changes a table, column, index,
  or migration. The migration tool is stack-specific — Prisma (TS) / Alembic (Python) / SwiftData
  or GRDB (Apple); see § Stack assumptions. The Prisma snippet is one illustration.
---

# apex-data — schema & migration implementation rules

Capability skill — **stack-neutral**. The invariants are universal to relational schema evolution;
the concrete migration tool comes from the bound stack (see § Stack assumptions). The bound stack
skill's Verification Recipe is the verifier.

## Stack assumptions

Rules below are stack-neutral; the schema snippet assumes **Prisma + TypeScript**. On the bound
stack, swap the schema-definition + migration tool:

- **ORM / migrations:** Prisma (`schema.prisma` + `prisma migrate`) → **Python:** SQLAlchemy + Alembic, or SQLModel (+ Alembic). **Apple:** SwiftData (`@Model`, lightweight migration) or GRDB (`DatabaseMigrator`).
- **Index declaration:** Prisma `@@index([...])` → Alembic `op.create_index` / SQLAlchemy `Index(...)`; SwiftData `#Index`; GRDB `create(index:)`.
- **Cascade:** Prisma `onDelete`/`onUpdate` → SQLAlchemy `ondelete=`/`onupdate=` on `ForeignKey`; GRDB `.cascade` in the FK definition.
- **Apply command:** `prisma migrate dev` → `alembic upgrade head` / SwiftData auto-migration / GRDB `migrator.migrate(db)`.

## NEVER do

- Add a NOT NULL column without a default or a backfill migration.
- Rename a column in a single migration (breaks running app instances — use expand/contract: add new → backfill → switch reads/writes → drop old).
- Delete a column before all code references are removed.
- Skip the index on a foreign-key column.
- Hand-write raw DDL when the migration tool can express it portably (loses cross-DB safety + the tool's rollback tracking).

## ALWAYS do

- Test migrations before deploying: on greenfield projects, against a seeded fixture of representative size; against a masked production copy where one exists.
- Add composite indexes for queries that filter on multiple columns together.
- Set cascade behaviour explicitly on foreign keys (`onDelete` / `onUpdate` or the stack equivalent).
- Keep committed migration files immutable — never edit a past migration; add a new one.
- Index any column used in a `WHERE` / filter / sort clause.

## Schema patterns (Prisma + TypeScript illustration)

> One stack's form of the rules above. On Python use SQLAlchemy/SQLModel models + Alembic; on Apple
> use SwiftData `@Model` or GRDB — the *rules* (FK index, explicit cascade, date index) are identical.

```prisma
model User {
  id        String   @id @default(cuid())
  email     String   @unique
  name      String
  createdAt DateTime @default(now())
  orders    Order[]

  @@index([createdAt]) // index for sorting/filtering by date
}

model Order {
  id        String   @id @default(cuid())
  userId    String
  user      User     @relation(fields: [userId], references: [id], onDelete: Cascade)
  status    OrderStatus @default(PENDING)
  createdAt DateTime @default(now())

  @@index([userId])     // index on foreign key
  @@index([status])     // index for filtering by status
}
```

## Acceptance checks (stack-neutral)

- The migration applies cleanly via the stack's apply command (`prisma migrate dev` / `alembic upgrade head` / SwiftData / GRDB).
- The schema validates (`prisma validate` / model import succeeds / `alembic check`).
- Every foreign key has an index.
- The migration is reversible, or its rollback is documented.
