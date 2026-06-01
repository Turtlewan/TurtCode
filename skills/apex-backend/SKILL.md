---
skill: apex-backend
backend: claude
version: 1.2.0
last_updated: 2026-06-01
sources:
  - Fastify Docs — fastify.dev
  - FastAPI Docs — fastapi.tiangolo.com
  - Prisma Docs — prisma.io/docs
  - HTTP Semantics RFC 9110
  - Agent Skills (addyosmani) — github.com/addyosmani/agent-skills
staleness_threshold: 14d
description: >
  Use when designing backend APIs or services — REST endpoints, status codes, pagination, input
  validation, transactions, error contracts, external-call resilience, server-side business logic.
  The design principles are stack-neutral (HTTP semantics, validate-at-boundary, services-not-handlers,
  transactions, timeouts); validation lib + ORM are per-stack — Zod+Prisma (TS) / pydantic+SQLAlchemy
  (Python), see § Stack assumptions. Not the coding-mode enforcement rules (that's impl.md).
---

# Backend Specialist — Planning Mode

## Stack assumptions

The API/service design principles here are **stack-neutral** (HTTP semantics, validate-at-the-edge,
logic-in-services, transactions, timeouts). The concrete validation library and ORM are per-stack:
**Zod + Prisma** (TypeScript / Fastify / Hono) / **pydantic + SQLAlchemy** (Python / FastAPI). Where
a rule names Zod or Prisma below, read it as the illustration — the rule is framework-agnostic.

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

- [ ] Input validated at the boundary (Zod / pydantic / the stack's validator) before any processing
- [ ] Error responses use consistent format: { error: string, code?: string }
- [ ] Database queries go through the ORM — no raw SQL unless proven necessary
- [ ] N+1 queries prevented — use include/select (or eager-load) appropriately
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
