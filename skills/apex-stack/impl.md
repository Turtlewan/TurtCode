---
skill: apex-stack
backend: deepseek
version: 1.1.0
last_updated: 2026-05-31
sources:
  - State of JS 2024 — stateofjs.com
  - Next.js Docs — nextjs.org/docs
  - Prisma Docs — prisma.io/docs
  - Drizzle Docs — orm.drizzle.team
  - Hono Docs — hono.dev
  - Auth.js Docs — authjs.dev
  - docs/technical/adr/ADR-005-stack-best-practice-skills.md
staleness_threshold: 30d
---

## NEVER do

- Install packages without verifying they are actively maintained (no release in >12 months = flag it)
- Use package names from this skill verbatim without checking the ecosystem's registry (npm / PyPI / crates.io / pkg.go.dev / Maven) — names change (e.g. `next-auth` → `@auth/core`)
- Hardcode any secret or API key in scaffold files — .env.example from day 0
- Skip writing the ADR — first commit must include docs/technical/adr/ADR-001-stack.md

## ALWAYS do

- Write ADR-001-stack.md before any application code
- Verify exact package name and latest major version on the ecosystem's package registry (npm / PyPI / crates.io / pkg.go.dev / Maven) before installing
- Create .env.example with all required variable keys (values empty, not real secrets)
- Add a "Stack" section to PROJECT.md (or create it) listing the chosen preset
- Run the chosen preset past the lock-in table before committing

## Code example — ADR-001 template

```markdown
# ADR-001: Technology Stack
**Date:** YYYY-MM-DD
**Status:** Accepted

## Context
[App type] requiring [key features]. Team: [language familiarity].
Deployment target: [platform]. Scale expectation: [year-1 estimate].

## Decision

| Layer | Choice | Rationale |
|-------|--------|-----------|
| Framework | Next.js 15 | [reason] |
| Database | PostgreSQL | [reason] |
| ORM | Prisma | [reason] |
| Auth | Auth.js v5 | [reason] |
| Deploy | Vercel + Railway | [reason] |

## Lock-in accepted
- [High lock-in choice]: accepted because [reason]

## Consequences
[trade-offs noted, options ruled out and why]
```

## Verification checklist

- [ ] ADR written to docs/technical/adr/ADR-001-stack.md
- [ ] All chosen packages confirmed on the ecosystem's registry (npm / PyPI / crates.io / pkg.go.dev / Maven): exists, active, correct current name
- [ ] .env.example created with all required keys (no real values)
- [ ] PROJECT.md has a "Stack" section
- [ ] No secrets hardcoded in any file
- [ ] Lock-in table reviewed with the user — high lock-in items are intentional choices
