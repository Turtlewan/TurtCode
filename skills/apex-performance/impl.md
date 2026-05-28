---
skill: apex-performance
backend: deepseek
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Web Vitals — web.dev/vitals
  - Prisma Performance — prisma.io/docs/guides/performance-and-optimization
staleness_threshold: 14d
---

# Performance Implementation Rules

## NEVER do

- Query the database inside a loop — batch with include or findMany with where
- Load all records from a table — always paginate or limit
- Block the event loop with synchronous CPU-heavy operations
- Import entire libraries when a subset is needed
- Fetch the same data multiple times in one request lifecycle

## ALWAYS do

- Use Prisma include for related data (never N queries for N records)
- Add database index for any column used in WHERE, ORDER BY, or JOIN
- Set a page size limit on all list queries (maximum 100 per page default)
- Use cursor-based pagination for large or growing datasets
- Cache expensive, infrequently-changing data (Redis, in-memory, HTTP cache headers)

## N+1 prevention

```typescript
// BAD — N+1 query
const orders = await prisma.order.findMany()
for (const order of orders) {
  const user = await prisma.user.findUnique({ where: { id: order.userId } }) // N queries
}

// CORRECT — single query with include
const orders = await prisma.order.findMany({
  include: { user: { select: { id: true, name: true } } }
})
```

## Verification checklist

- [ ] Check Prisma queries in changed files — no queries inside loops
- [ ] Run: EXPLAIN on any new SQL query involving joins or filtering
- [ ] Check: all new list endpoints have take parameter with maximum
- [ ] Run: npm run build — check bundle size output, no unexpected increases
