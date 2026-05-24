---
skill: apex-data
version: 1.0.0
last_updated: 2026-05-24
sources:
  - Prisma Migrations — prisma.io/docs/guides/database/developing-with-prisma-migrate
staleness_threshold: 30d
---

# Data Implementation Rules

## NEVER do

- Add a NOT NULL column without a default or backfill migration
- Rename a column in a single migration (breaks running app instances)
- Delete a column without first removing all code references
- Skip adding an index on a foreign key column
- Use raw SQL in migrations when Prisma can express it

## ALWAYS do

- Test migrations on a copy of production data before deploying
- Add composite indexes for queries that filter on multiple columns
- Set cascade behaviour explicitly on foreign keys (onDelete, onUpdate)
- Keep migration files immutable once committed — never edit past migrations
- Add Prisma @@index for any field used in findMany where clause

## Prisma schema patterns

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

## Verification checklist

- [ ] Run: npx prisma migrate dev — migration applies without errors
- [ ] Run: npx prisma validate — schema is valid
- [ ] Check: every foreign key has @@index
- [ ] Check: migration is reversible or rollback documented
