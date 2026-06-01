---
skill: apex-performance
backend: deepseek
version: 1.1.0
last_updated: 2026-06-01
sources:
  - Web Vitals — web.dev/vitals
  - Prisma Performance — prisma.io/docs/guides/performance-and-optimization
  - SP5 de-coupling (stack-neutral core; Prisma/TS illustration)
staleness_threshold: 14d
description: >
  Coding-mode performance rules — stack-neutral invariants (no query-in-a-loop / N+1, always
  paginate, index filtered/sorted/joined columns, don't block the event loop with sync CPU work,
  cache expensive infrequently-changing data, import only what's needed). Loaded on perf-sensitive
  work. The ORM eager-load + bundle tooling is stack-specific (Prisma `include` / SQLAlchemy
  `selectinload`); see § Stack assumptions.
---

# apex-performance — performance implementation rules

Capability skill — **stack-neutral**. The invariants apply on any stack; the concrete eager-load API
and profiling tools come from the bound stack (see § Stack assumptions). The bound stack skill's
Verification Recipe is the verifier.

## Stack assumptions

Rules below are stack-neutral; the snippet assumes **Prisma + TypeScript**. On the bound stack, swap:

- **Eager-load related data:** Prisma `include` → **Python:** SQLAlchemy `selectinload` / `joinedload`; **Swift/SwiftData:** fetch with relationships / batch. Goal: one query, not N.
- **Don't block the loop:** Node event loop → **Python:** never run sync CPU-heavy work in an async handler (offload to a thread/process pool); **Swift:** never block the main actor — move heavy work off-main.
- **Pagination:** Prisma `take`/cursor → the stack's LIMIT + keyset/cursor pagination.
- **Bundle/size check:** `npm run build` size → the stack's build/size tool (irrelevant for a pure API).

## NEVER do

- Query the database inside a loop — batch with an eager-load (`include` / `selectinload`) or one `WHERE ... IN`.
- Load all rows from a table — always paginate or limit.
- Block the event/request loop (or main actor) with synchronous CPU-heavy operations.
- Import an entire library when a subset is needed.
- Fetch the same data multiple times in one request lifecycle.

## ALWAYS do

- Eager-load related data in one query — never N queries for N records.
- Add a database index for any column used in `WHERE`, `ORDER BY`, or `JOIN`.
- Set a page-size limit on all list queries (default max 100 per page).
- Use cursor/keyset pagination for large or growing datasets.
- Cache expensive, infrequently-changing data (Redis / in-memory / HTTP cache headers).

## N+1 prevention (Prisma + TypeScript illustration)

> Same rule on any stack: one eager-loaded query, not a loop of lookups. Python: SQLAlchemy
> `selectinload`; the BAD/CORRECT contrast is identical.

```typescript
// BAD — N+1 query
const orders = await prisma.order.findMany()
for (const order of orders) {
  const user = await prisma.user.findUnique({ where: { id: order.userId } }) // N queries
}

// CORRECT — single query with include
const orders = await prisma.order.findMany({
  include: { user: { select: { id: true, name: true } } },
})
```

## Acceptance checks (stack-neutral)

- No database query runs inside a loop in the changed files.
- `EXPLAIN` on any new join/filter query uses an index (no full scan on a large table).
- Every new list endpoint has a page-size limit.
- For a frontend build, the bundle size shows no unexpected increase.
