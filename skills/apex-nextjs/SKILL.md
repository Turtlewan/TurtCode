---
skill: apex-nextjs
backend: claude
version: 1.0.0
last_updated: 2026-05-31
sources:
  - Context7 /vercel/next.js (App Router docs, fetched 2026-05-31)
  - Next.js Data Security Guide — nextjs.org/docs/app/guides/data-security
  - Next.js v15 upgrade guide — nextjs.org/docs/app/guides/upgrading/version-15
staleness_threshold: 14d
description: >
  Use when building or designing a Next.js App Router app (Next 15+, React 19) — Server/Client
  component boundaries, rendering & caching strategy, Server Actions, data fetching, App Router
  file conventions. Not for generic React (apex-frontend), auth mechanics (apex-auth), or whether
  to pick Next at all (apex-stack).
---

# apex-nextjs — Next.js App Router (planning)

Stack skill (ADR-005) for Next.js **15+ App Router**, TypeScript, React 19. The meat is in
`impl.md`; this file is the planning "what to weigh."

## Boundary — what this skill is NOT

- **Generic React / component design → `apex-frontend`.** This skill is Next-specific depth only.
- **Auth mechanics (providers, sessions, JWT) → `apex-auth`.** Here: only *where* the auth check
  goes in a Next app (in the action / DAL).
- **DB / ORM / schema → `apex-data`.** Here: only the `server-only` data-access boundary.
- **Whether to choose Next at all → `apex-stack`.** This skill assumes Next is already chosen.

## Research findings (Next.js 15 — verified via context7 2026-05-31)

| Fact | Implication |
|------|-------------|
| `fetch` is **not cached by default**; POST / auth-header fetches auto-no-cache after dynamic | Set cache intent explicitly on every fetch (`cache` / `next.revalidate` / `next.tags`) |
| `cookies()`, `headers()`, `params`, `searchParams` are **async** (must `await`) | `const { id } = await params`; reading them forces dynamic rendering |
| Server Actions are **public POST endpoints** | Auth + authorization + input validation **inside** the action — UI checks are insufficient |
| `server-only` Data Access Layer is the official mutation pattern | Centralise auth/authz/DB in `lib/dal/*` starting with `import 'server-only'` |
| `revalidatePath` / `revalidateTag` invalidate cached data from actions | Call after every mutation so the UI reflects it |
| `use cache` directive exists for explicit caching of components/functions | Opt-in; don't assume implicit caching |

## What to weigh (planning)

1. **Rendering strategy per route:** static / ISR (`next.revalidate`) / on-demand (`tags` +
   `revalidateTag`) / dynamic. Reading a request API (`cookies`/`headers`/`searchParams`) makes
   a route dynamic — intend it or wrap the dynamic part in `<Suspense>`.
2. **Server-by-default; push `'use client'` to leaves.** A page/layout stays a Server Component;
   only the smallest interactive leaf is a client component.
3. **Data freshness per source** drives the cache option — don't pick one global default.
4. **Security boundary is the action/DAL, never middleware or layout** (those are not auth gates).

## Hard blocks (planning)

- Never sign off a Next plan that puts the auth gate in middleware or a layout instead of the
  action / DAL.
- Never plan `fetch` usage that relies on implicit caching — cache intent is explicit in 15.
- Never duplicate generic React guidance here — that's `apex-frontend`.

## Review checklist

- [ ] Rendering strategy chosen per route (static/ISR/on-demand/dynamic), dynamic intended
- [ ] Server/Client split planned — `'use client'` only on interactive leaves
- [ ] Every Server Action has auth + authz + validation planned (public-endpoint assumption)
- [ ] `server-only` DAL planned as the mutation/data boundary
- [ ] Cache intent + revalidation planned per data source
- [ ] Boundaries respected (auth→apex-auth, data→apex-data, generic React→apex-frontend)
