---
skill: apex-backend
backend: claude
version: 1.1.0
last_updated: 2026-05-28
sources:
  - Fastify Docs — fastify.dev
  - Prisma Docs — prisma.io/docs
  - HTTP Semantics RFC 9110
  - Agent Skills (addyosmani) — github.com/addyosmani/agent-skills
staleness_threshold: 14d
---

# Backend Specialist — Planning Mode

## When to activate
Any spec involving: API endpoints, database queries, caching, background jobs,
service integrations, data models, server-side business logic.

## Questions to ask before designing

- Is this a read-heavy or write-heavy operation?
- What is the expected request volume? Does it need caching?
- Is this synchronous or should it be async/queued?
- What are the failure modes? What happens when downstream services fail?
- Does this need a transaction? What is the rollback strategy?

## API design principles

REST conventions:
- GET for reads, POST for creates, PUT/PATCH for updates, DELETE for deletes
- Return appropriate HTTP status codes (201 for create, 204 for delete, etc.)
- Consistent error response format across all endpoints
- Version the API if it's consumed by external clients

Pagination:
- Cursor-based for large datasets or real-time data
- Offset-based for simple admin UIs with predictable dataset sizes

## Review checklist

- [ ] Input validated with Zod before any processing
- [ ] Error responses use consistent format: { error: string, code?: string }
- [ ] Database queries use Prisma — no raw SQL unless proven necessary
- [ ] N+1 queries prevented — use include/select appropriately
- [ ] Transactions used for multi-step writes
- [ ] Idempotency considered for POST endpoints that create resources
- [ ] Timeouts set for all external service calls

## Source-driven development

Before implementing any API pattern, verify against current official docs via Context7:
- Fastify plugin patterns change between majors — check current version
- Prisma query API evolves — don't rely on training data for syntax

Use `mcp__context7__query-docs` with the library ID and your specific question.

## Doubt-driven review (for auth and data endpoints)

For high-stakes endpoints (auth, payments, user data), apply before marking complete:
1. **CLAIM**: state what security assumptions this endpoint makes
2. **EXTRACT**: find every other endpoint that shares those assumptions
3. **DOUBT**: challenge each: "could an attacker violate this assumption?"
4. **RECONCILE**: fix before shipping, or explicitly accept and document the risk

## Standards

HTTP semantics: RFC 9110
Fastify docs: fastify.dev
Prisma docs: prisma.io/docs
