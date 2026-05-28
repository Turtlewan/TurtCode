---
skill: apex-stack
backend: claude
version: 1.0.1
last_updated: 2026-05-28
sources:
  - State of JS 2024 — stateofjs.com
  - Next.js Docs — nextjs.org/docs
  - Prisma Docs — prisma.io/docs
  - Drizzle Docs — orm.drizzle.team
  - Hono Docs — hono.dev
  - Auth.js Docs — authjs.dev
staleness_threshold: 30d
---

# apex-stack — Tech Stack Selection

## Research findings

| Technology | Finding | Tag |
|------------|---------|-----|
| Next.js 15 | GA since Oct 2024. Latest patch 15.5.x. Next.js 16 LTS also available (Oct 2025). Both are viable. | [VERIFIED] |
| Prisma | Latest stable v7.7.0 (Apr 2026). Prisma 8 Next in preview targeting mid-2026. Recommend Prisma 7 for production. | [VERIFIED] |
| Drizzle ORM | Latest stable 0.45.2. v1.0.0 in RC phase. Both streams production-ready. | [VERIFIED] |
| Auth.js v5 | Never had a stable GA release. Perpetual beta since Oct 2023. Original maintainer departed Jan 2025; now maintained by Better Auth team under same org. Still usable but note the beta status. | [VERIFIED] |
| Hono | Latest stable v4.12.x (May 2026). Actively maintained with frequent releases. | [VERIFIED] |

## When to activate

- "what stack should I use"
- "starting a new project" / "new app"
- "which framework / database / ORM should I choose"
- "should I use X or Y" for any technology category
- invoked automatically before apex-init on a new project

## 7 questions to ask (in this order)

1. **What type of app?** (SaaS / API-only / real-time / content / mobile-first / data-heavy / enterprise)
2. **Deployment target?** (Vercel / Railway / Fly.io / AWS / Azure / GCP / Cloudflare / bare metal)
3. **Team language familiarity?** (TypeScript / Python / Go / other)
4. **Timeline?** (prototype/MVP vs production-grade)
5. **Hard constraints?** (compliance: HIPAA/SOC2, existing infra, budget cap)
6. **Key features needed?** (real-time, file uploads, AI/LLM, payments, search — tick list)
7. **Expected scale in year 1?** (hundreds / thousands / millions of users)

## Preset decision table

| Profile | Framework | Database | ORM | Auth | Deploy |
|---------|-----------|----------|-----|------|--------|
| SaaS fullstack | Next.js 15 App Router | PostgreSQL | Prisma | Auth.js v5 or Clerk | Vercel + Railway/Neon |
| API-only service | Hono or Fastify | PostgreSQL | Drizzle | JWT (custom) | Railway or Fly.io |
| Real-time app | Next.js 15 + Supabase realtime | PostgreSQL (via Supabase) | Prisma | Supabase Auth | Vercel + Supabase |
| Mobile + API | Expo (React Native) + Hono | PostgreSQL | Drizzle | JWT (custom) | Railway or Fly.io |
| Content / blog | Astro or Next.js | PostgreSQL or SQLite | Prisma or Drizzle | Simple JWT or none | Vercel |
| Edge / global | Remix or Next.js | SQLite / Turso / D1 | Drizzle | Lucia | Cloudflare Pages |
| AI-first app | Next.js 15 + AI SDK | PostgreSQL + pgvector | Prisma | Auth.js v5 | Vercel + Neon |
| Enterprise / B2B | Next.js 15 + Hono or NestJS | PostgreSQL | Prisma | Auth.js v5 + SAML | AWS or Azure |

**Note on Auth.js v5:** As of May 2026, Auth.js v5 has not shipped a stable GA release — it remains in perpetual beta. The original maintainer departed in Jan 2025 and the project is now maintained by the Better Auth team. Auth.js v5 is still functional with a large provider ecosystem, but for new projects requiring stability, evaluate Better Auth as an alternative (see apex-auth for detailed comparison). For the presets above, Auth.js v5 is listed as a default because of its provider breadth; flag this caveat to the user when recommending it.

## Lock-in table (required alongside every recommendation)

| Component | Lock-in | Swap cost | Note |
|-----------|---------|-----------|------|
| Framework (Next.js, Remix…) | 🔴 High | Near-rewrite | Most consequential choice |
| Database engine | 🔴 High | Full data migration | Default to PostgreSQL |
| Hosted auth (Clerk, Supabase Auth) | 🟡 Medium | Data export + re-integration | Check pricing at scale before committing |
| Auth library (Auth.js, Lucia) | 🟡 Medium | Refactor session logic | Lower exit cost than hosted |
| ORM (Prisma vs Drizzle) | 🟡 Medium | Schema compat work | Both TypeScript-first; Drizzle is lighter |
| API style (REST vs tRPC) | 🟡 Medium | Frontend contract refactor | tRPC only viable in full-TS monorepo |
| Deployment platform | 🟢 Low | Dockerfile + env vars | Avoid platform-specific edge features |
| Payment provider | 🟡 Medium | Customer migration | Stripe is default |
| Email provider | 🟢 Low | Swap API calls | 1-2 hour swap |

**Deployment platform caveat:** Vercel is listed as low-lock-in but is also a feature provider (edge middleware, image optimization). Self-hosting or moving to Railway later requires replacing these features. Factor this into the ADR analysis.

## Hard blocks

- Never recommend MongoDB for apps with relational data — PostgreSQL handles documents via JSONB
- Never recommend a hosted auth provider (Clerk, Supabase Auth) without noting its pricing at 10k+ MAU
- Never recommend tRPC for projects that are not TypeScript end-to-end (including separate mobile repos)
- Never output a stack recommendation without the lock-in table
- Never recommend NestJS for edge/Cloudflare profiles — NestJS uses reflect-metadata decorators and does not run in edge runtimes

## Review checklist

- [ ] Stack preset selected and all 5 components documented (framework, database, ORM, auth, deploy)
- [ ] Lock-in table reviewed — high lock-in items confirmed intentionally, not by default
- [ ] Hosted services priced at expected scale (MAU × price per seat)
- [ ] ADR written to docs/technical/adr/ADR-001-stack.md
- [ ] Any gaps in apex-* coverage flagged (e.g. "apex-payments not yet a skill")

## Gotchas / edge cases

- **Package name drift**: Package names change (e.g. `next-auth` → `@auth/core` + `next-auth` v5 beta). The impl.md warns DeepSeek to verify current npm names.
- **Supabase dual role**: Supabase appears in both the real-time preset (as a realtime provider) and as a hosted auth option. These are separate choices — you can use Supabase realtime without Supabase Auth.
- **tRPC scope restriction**: tRPC only works if both client and server are TypeScript in the same repo. If the mobile preset (Expo) is in a separate repo from the API, tRPC doesn't apply.
- **Deployment ≠ hosting**: Vercel provides features beyond hosting (edge middleware, image optimization). Factor this into lock-in analysis when self-hosting is a future option.
- **NestJS at edge**: Uses reflect-metadata decorators — does not run in Cloudflare Workers or Vercel edge runtime. Only for AWS/Azure/Railway.
- **staleness**: 30-day threshold is intentional — JS ecosystem presets can drift within a month. If `last_updated` is >30 days ago, flag potential staleness.
