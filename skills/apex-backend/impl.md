---
skill: apex-backend
version: 1.0.0
last_updated: 2026-05-24
sources:
  - Fastify Docs — fastify.dev
  - Prisma Docs — prisma.io/docs
  - HTTP Semantics RFC 9110
staleness_threshold: 14d
---

# Backend Implementation Rules

## NEVER do

- Return a 200 status for an error response
- Put business logic in route handlers — use service functions
- Use raw SQL unless Prisma genuinely cannot express the query
- Call external APIs without a timeout
- Return full database model objects — select only needed fields
- Catch errors silently — always log or rethrow

## ALWAYS do

- Validate all request input with Zod at the route handler boundary
- Return consistent error format: `{ error: 'Human-readable message' }`
- Use Prisma transactions for any operation touching multiple tables
- Set explicit select on Prisma queries — never return full model
- Add request timeout to all external service calls (default 5000ms)
- Log errors with context (endpoint, userId if available, timestamp)

## Error response format

```typescript
// All error responses use this shape
return res.status(400).json({ error: 'Validation failed', code: 'INVALID_INPUT' })
return res.status(404).json({ error: 'Resource not found' })
return res.status(500).json({ error: 'Internal server error' }) // never expose internals
```

## Prisma query pattern

```typescript
// CORRECT — select only needed fields
const user = await prisma.user.findUnique({
  where: { id: userId },
  select: { id: true, name: true, email: true }
})

// CORRECT — transaction for multi-step writes
await prisma.$transaction(async (tx) => {
  await tx.order.create({ data: orderData })
  await tx.inventory.update({ where: { id: itemId }, data: { stock: { decrement: 1 } } })
})
```

## Verification checklist

- [ ] Run: npm run build — 0 TypeScript errors
- [ ] Test: POST with invalid body returns 400 with error message
- [ ] Test: GET non-existent resource returns 404
- [ ] Check: no Prisma query returns entire model (always has select)
- [ ] Check: all external calls have timeout configured
