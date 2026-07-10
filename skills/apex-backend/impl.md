---
skill: apex-backend
backend: coding
version: 1.1.0
last_updated: 2026-06-01
sources:
  - Fastify Docs — fastify.dev
  - FastAPI Docs — fastapi.tiangolo.com
  - HTTP Semantics RFC 9110
  - SP5 de-coupling (stack-neutral core; Fastify/Prisma/Zod illustration)
staleness_threshold: 14d
description: >
  Coding-mode rules for backend API / service design — stack-neutral invariants (correct status
  codes, validate input at the boundary, logic in services not handlers, consistent error shape,
  transactions for multi-table writes, select only needed fields, timeouts on external calls, never
  swallow errors). Loaded when a task adds/changes an API route or service. The validation lib + ORM
  are stack-specific — Zod+Prisma (TS) / pydantic+SQLAlchemy (Python); see § Stack assumptions.
---

# apex-backend — API & service implementation rules

Capability skill — **stack-neutral**. The invariants are HTTP/API-design fundamentals; the concrete
validation library and ORM come from the bound stack (see § Stack assumptions). The bound stack
skill's Verification Recipe is the verifier.

## Stack assumptions

Rules below are stack-neutral; the snippets assume **Fastify + Prisma + Zod (TypeScript)**. On the
bound stack, swap:

- **Input validation:** Zod at the handler boundary → **Python/FastAPI:** pydantic models (validation is automatic from the typed signature). Same rule: validate at the edge, reject before logic.
- **ORM / query:** Prisma `select` + `$transaction` → **Python:** SQLAlchemy/SQLModel — load only needed columns, wrap multi-table writes in a `session.begin()` transaction.
- **Error shape:** `res.status(n).json({error})` → FastAPI `HTTPException(status_code, detail)` / a typed error response model. Same rule: consistent shape, never leak internals on 5xx.
- **External-call timeout:** fetch/axios timeout → `httpx`/`requests` `timeout=` (Python). Always set one.

## NEVER do

- Return a 200 status for an error response — use the correct 4xx/5xx.
- Put business logic in route handlers — call a service function.
- Hand-write raw SQL unless the ORM genuinely cannot express the query.
- Call an external API without a timeout.
- Return full database model objects — select only the fields the response needs.
- Catch errors silently — always log or rethrow.

## ALWAYS do

- Validate all request input at the route-handler boundary (Zod / pydantic / the stack's validator).
- Return a consistent error shape (e.g. `{ error: 'Human-readable message' }`); never expose internals on 5xx.
- Wrap any operation touching multiple tables in a transaction.
- Select only the needed fields — never return the whole model.
- Set a request timeout on every external service call (default 5000 ms).
- Log errors with context (endpoint, userId if available, timestamp).

## Patterns (Fastify + Prisma + Zod illustration)

> One stack's form of the rules. On Python/FastAPI: pydantic models for input, `HTTPException` for
> errors, SQLAlchemy `select()` + `session.begin()` for the query/transaction — same invariants.

```typescript
// Error responses — consistent shape, no internals leaked
return res.status(400).json({ error: 'Validation failed', code: 'INVALID_INPUT' })
return res.status(404).json({ error: 'Resource not found' })
return res.status(500).json({ error: 'Internal server error' })

// Select only needed fields
const user = await prisma.user.findUnique({
  where: { id: userId },
  select: { id: true, name: true, email: true },
})

// Transaction for multi-step writes
await prisma.$transaction(async (tx) => {
  await tx.order.create({ data: orderData })
  await tx.inventory.update({ where: { id: itemId }, data: { stock: { decrement: 1 } } })
})
```

## Acceptance checks (stack-neutral)

- POST with an invalid body → 400 with an error message (not 200, not 500).
- GET a non-existent resource → 404.
- No query returns the entire model (an explicit field selection is always present).
- Every external call has a timeout configured.
- A 5xx response body contains no internal/stack-trace detail.
