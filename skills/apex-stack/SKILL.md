---
skill: apex-stack
backend: claude
version: 1.2.0
last_updated: 2026-06-10
sources:
  - State of JS 2024 — stateofjs.com
  - Next.js Docs — nextjs.org/docs
  - Prisma Docs — prisma.io/docs
  - Drizzle Docs — orm.drizzle.team
  - Hono Docs — hono.dev
  - Auth.js Docs — authjs.dev
  - docs/technical/adr/ADR-005-stack-best-practice-skills.md
  - docs/technical/adr/ADR-006-buildability-layer-verification-inversion.md
staleness_threshold: 30d
description: >
  Use when choosing a tech stack for a new project, or for any "X or Y?" technology
  decision — "what stack should I use", "starting a new project", "which
  framework / database / ORM / language". Runs before apex-init. Selects merit-based
  across ecosystems (NOT JS-by-default), weighing AI-buildability and verifiability
  heavily, then writes the chosen stack's verify commands into the repo's AGENTS.md.
  Not for picking a feature library inside an already-chosen stack.
---

# apex-stack — Tech Stack Selection

Selection is **requirements-driven and merit-based across ecosystems** — never "the JS preset for
this profile." APEX builds with heavy AI assistance for developers who often don't know the stack,
so **AI-buildability and verifiability are first-class selection criteria** (see *How to choose*),
not afterthoughts. After the stack is chosen, write its **verify commands into `AGENTS.md`** — the
one thing about a stack the model cannot derive is how *this repo* proves itself green.

## Research findings

> **JS-ecosystem sample only** — this table is the family this skill historically over-indexed on;
> it is **not** the candidate set and **not** a default. For the ecosystem actually chosen —
> especially non-JS (Python, Go, Ruby, JVM, .NET, Rust) — verify current versions/maturity via
> **`apex-research`** at selection time. Do not recommend versions from this table for another stack.

| Technology | Finding | Tag |
|------------|---------|-----|
| Next.js 15 | GA since Oct 2024. Latest patch 15.5.x. Next.js 16 LTS also available (Oct 2025). Both are viable. | [VERIFIED] |
| Prisma | Latest stable v7.7.0 (Apr 2026). Prisma 8 Next in preview targeting mid-2026. Recommend Prisma 7 for production. | [VERIFIED] |
| Drizzle ORM | Latest stable 0.45.2. v1.0.0 in RC phase. Both streams production-ready. | [VERIFIED] |
| Auth.js v5 | See § Note on Auth.js v5 below. | [VERIFIED] |
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
3. **Team language familiarity — and how much will AI write the code?** (TypeScript / Python / Go / other; and "AI writes most of it" vs "experienced team in language X"). **If AI-reliant, buildability + verifiability outweigh team familiarity** — see *How to choose*.
4. **Timeline?** (prototype/MVP vs production-grade)
5. **Hard constraints?** (compliance: HIPAA/SOC2, existing infra, budget cap)
6. **Key features needed?** (real-time, file uploads, AI/LLM, payments, search — tick list)
7. **Expected scale in year 1?** (hundreds / thousands / millions of users)

## How to choose — merit-based, requirements-driven

Score the realistic candidates against these criteria, **in this priority order**, for THIS
project's answers. Do not start from a default and justify it backwards.

1. **Hard constraints (gate).** Compliance, existing infra, deployment target, mandated language —
   these eliminate candidates outright. Apply first.
2. **AI-buildability (heavy).** How reliably can an AI write correct code in this stack with little
   human steering? Favours: large/clean training corpus, stable conventions ("one obvious way"),
   first-class types, strong official docs, a mature framework that owns the boilerplate. A stack
   the AI builds well beats a marginally better-fitting stack the AI fumbles.
3. **Verifiability (heavy).** How tight is the write → check → fix loop? **Mostly a _language_
   property** (ADR-006): statically-typed languages (TS, Go, Rust, Kotlin, typed Python) give the
   AI a real self-correction signal; dynamic ones are weaker unless bought back with a strict
   type-checker (`mypy --strict`, `ruff`) + tests. Weight this heavily **because the developer often
   can't catch what the AI gets wrong — the toolchain must.**
4. **Requirements fit.** Does the ecosystem have first-class libraries for the must-have features?
   (ML/data → Python; CPU-bound/systems → Go/Rust; rich web UI → TS/React; rapid CRUD → Rails/
   Django/Laravel.)
5. **Team familiarity.** Real, but **subordinate to 2–3 when AI writes most of the code** — an
   AI-reliant dev gains little from a language they know but the AI builds poorly.
6. **Lock-in & maturity.** Run the finalists through the lock-in table; prefer mature, actively
   maintained, swappable choices.

Output the top candidate **plus the runner-up you ruled out and why** — selection is a comparison,
not a lookup. Record it in ADR-001 (template in impl.md).

## Candidate menu (cross-ecosystem starting points)

Merit-ranked candidates per profile — **candidates to score, not defaults to accept.** Pick the JS
option only if it wins on the criteria above; it sits alongside the others, never ahead of them.

| Profile | Strong candidates (score these) | Default DB |
|---------|---------------------------------|------------|
| SaaS fullstack (rich UI) | Next.js/TS · Remix/TS · Rails · Django · Laravel | PostgreSQL |
| API-only service | FastAPI/Python · Go (Gin/std) · Hono/TS · Spring Boot/Kotlin | PostgreSQL |
| Data / ML-heavy backend | FastAPI or Django/Python (polars, pandas, ML libs) | PostgreSQL (+pgvector) |
| Real-time | Elixir/Phoenix · Go (+WS) · Next.js + Supabase | PostgreSQL |
| Mobile + API | Expo/TS · native (Swift/Kotlin) + (FastAPI / Go / Hono) | PostgreSQL |
| Content / blog | Astro · Hugo/Go · Eleventy · Next.js | SQLite / PostgreSQL |
| Edge / global | Hono/TS (Workers) · Go · Next.js | SQLite / Turso / D1 |
| CPU-bound / systems | Go · Rust (Axum) | PostgreSQL |
| Enterprise / B2B | Spring Boot/JVM · .NET/C# · Next.js + Nest | PostgreSQL |

**Default to PostgreSQL** for relational data in every ecosystem. Per-component lock-in below.

**Note on Auth.js v5:** As of May 2026, Auth.js v5 has not shipped a stable GA release — it remains in perpetual beta. The original maintainer departed in Jan 2025 and the project is now maintained by the Better Auth team. Auth.js v5 is still functional with a large provider ecosystem, but for new projects requiring stability, evaluate Better Auth as an alternative (see apex-auth for detailed comparison). When a JS/TS stack reaches for Auth.js v5 for its provider breadth, flag this beta caveat to the user.

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

## Land the recipe (run after the stack is chosen — before handing to apex-init)

1. **APEX ships no stack skills.** There is no global `apex-python` / `apex-nextjs` to bind — the
   domain layer was removed (ADR-036). A frontier coder knows the stack; what it cannot know is how
   *this repo* verifies itself.
2. **The Verification Recipe's single home is the repo's `AGENTS.md`** (ADR-037). Write the exact
   commands (install, lint, typecheck, test, build) there under `## Verify commands`. This is a
   **per-project fact**, not model knowledge — that is why it is written down at all.
   **It must be AGENTS.md, not status.md:** Codex reads AGENTS.md natively on every `codex exec` and
   **never sees status.md**. A recipe in status.md is invisible to the coder that runs it.
   `apex-code` reads AGENTS.md before dispatching; absent a recipe, it falls back to the spec's
   `## Commands to run`.
3. **Write only what the model cannot derive.** Real command names, real flags, and any gotcha that
   would otherwise waste a run (e.g. "plain `uv sync` — there is NO `agentic` group; `--group
   agentic` errors"). Do **not** restate framework best practice — an AGENTS.md padded with what the
   model already knows measurably *lowers* task success (ADR-037).
4. **Never author a stack skill.** That layer is gone (ADR-036) and re-creating it one stack at a
   time is the failure mode to guard against. A stack gap is not a skill gap.

## Hard blocks

- Never default to a JS/TS stack by reflex — select on merit across ecosystems, weighing AI-buildability and verifiability (see *How to choose*). The JS option must *win*, not be assumed.
- Never finish stack selection without writing the verify commands into the repo's `AGENTS.md` (or leaving the `<!-- apex:agents:verify -->` stub if the stack is genuinely TBD).
- Never output a recommendation without naming the runner-up and why it lost.
- Never recommend MongoDB for apps with relational data — PostgreSQL handles documents via JSONB
- Never recommend a hosted auth provider (Clerk, Supabase Auth) without noting its pricing at 10k+ MAU
- Never recommend tRPC for projects that are not TypeScript end-to-end (including separate mobile repos)
- Never output a stack recommendation without the lock-in table
- Never recommend NestJS for edge/Cloudflare profiles — NestJS uses reflect-metadata decorators and does not run in edge runtimes

## Review checklist

- [ ] Candidates scored on merit (AI-buildability + verifiability weighted heavily); top pick + ruled-out runner-up documented
- [ ] All components documented across the chosen ecosystem (language, framework, database, data/ORM layer, auth, deploy)
- [ ] Lock-in table reviewed — high lock-in items confirmed intentionally, not by default
- [ ] Hosted services priced at expected scale (MAU × price per seat)
- [ ] ADR written to docs/technical/adr/ADR-001-stack.md
- [ ] Verify commands written into `AGENTS.md` `## Verify commands` — install, lint, typecheck, test, build
- [ ] AGENTS.md carries no content the model could derive (that content lowers task success)

## Gotchas / edge cases

- **Package name drift**: Package names change (e.g. `next-auth` → `@auth/core` + `next-auth` v5 — status: see § Note on Auth.js v5). The impl.md warns the coder to verify current npm names.
- **Supabase dual role**: Supabase appears in both the real-time preset (as a realtime provider) and as a hosted auth option. These are separate choices — you can use Supabase realtime without Supabase Auth.
- **tRPC scope restriction**: tRPC only works if both client and server are TypeScript in the same repo. If the mobile preset (Expo) is in a separate repo from the API, tRPC doesn't apply.
- **Deployment ≠ hosting**: Vercel provides features beyond hosting (edge middleware, image optimization). Factor this into lock-in analysis when self-hosting is a future option.
- **NestJS at edge**: Uses reflect-metadata decorators — does not run in Cloudflare Workers or Vercel edge runtime. Only for AWS/Azure/Railway.
- **staleness**: 30-day threshold is intentional — JS ecosystem presets can drift within a month. If `last_updated` is >30 days ago, flag potential staleness.
