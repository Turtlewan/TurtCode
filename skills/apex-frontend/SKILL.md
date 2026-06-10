---
skill: apex-frontend
backend: claude
version: 1.3.0
last_updated: 2026-06-10
sources:
  - React 19 — react.dev/blog/2024/12/05/react-19
  - React Compiler — react.dev/learn/react-compiler
  - Next.js 16 — nextjs.org/blog/next-16
  - Web Vitals — web.dev/vitals
  - Vercel Agent Skills — github.com/vercel-labs/agent-skills
  - shadcn/ui — github.com/shadcn-ui/ui · Radix Primitives — github.com/radix-ui/primitives
  - Tailwind CSS v4 — github.com/tailwindlabs/tailwindcss
staleness_threshold: 14d
description: >
  Use when building web frontend with React — components, hooks, client state,
  rendering strategy, CSS/Tailwind, bundle/perf, composition. Triggers: "React
  component", "client vs server component", "this UI is slow / re-rendering",
  "Tailwind", "frontend perf". WEB-STACK skill (React + DOM). For native UI use
  apex-swift (SwiftUI); for Next.js-specific routing/caching/Server Actions defer to
  apex-nextjs; for design/UX judgment apex-ui-ux-design; pure a11y apex-accessibility.
---

# Frontend Specialist — Planning Mode

## When to activate
Any spec involving: React components, CSS/Tailwind, browser APIs, client-side state,
bundle optimisation, client rendering strategy.

## Stack assumptions

**Web-stack skill** — assumes **React (19+) + DOM + Tailwind**. This is the generic React
layer:
- **Native UI** (iOS/macOS) → not this skill; use **apex-swift** / SwiftUI.
- **Next.js specifics** (App Router file conventions, caching, Server Actions, `next/*`) →
  **apex-nextjs** owns the depth; this skill stays framework-generic and won't duplicate it.
- **Cross-surface design/UX judgment** → apex-ui-ux-design. **Pure a11y audit** → apex-accessibility.

## React 19 + React Compiler — current baseline (don't write 2023 React)

- **React Compiler 1.0 is stable** (and on-by-default in Next.js 16). **Stop hand-memoizing** —
  drop reflexive `useMemo` / `useCallback` / `React.memo`; the compiler auto-memoizes. Add them
  back only when a profiler shows a real hot path the compiler missed.
- **Actions** for mutations/forms: `<form action={fn}>` + **`useActionState`** (pending + result)
  + **`useFormStatus`**; **`useOptimistic`** for instant feedback with auto-revert on error.
- **`use()`** to read a promise/context conditionally (with Suspense) — not a substitute for
  server-component data fetching.
- **`ref` is a regular prop** — `forwardRef` is no longer needed for new components.
- Native document-metadata (`<title>`/`<meta>`) and stylesheet hoisting are built in.

## Rendering strategy

Server components by default; `'use client'` only on interactive leaves. All rendering/caching
strategy depth (static/ISR/dynamic, `next/*`, Server Actions, App Router conventions) lives in
**apex-nextjs** (Next.js 15+ (16 current)) — defer there, don't duplicate.

## Review checklist

- [ ] Server components used by default; 'use client' only where needed
- [ ] No data fetching in client components — fetch in server components or React Query
- [ ] No reflexive useMemo/useCallback/memo — let React Compiler memoize (add back only on a profiled hot path)
- [ ] Forms/mutations use Actions (`useActionState`/`useOptimistic`), not hand-rolled submit state
- [ ] Loading states defined (Suspense boundary or `loading.tsx` in Next)
- [ ] Error states defined (`error.tsx` or ErrorBoundary)
- [ ] TypeScript props typed — no implicit any
- [ ] (Next.js) Images use `next/image`; internal links use `next/link`
- [ ] No inline styles — Tailwind classes only
- [ ] Mobile-first responsive classes (sm:, md:, lg: breakpoints)

## Component foundation

Component primitives (shadcn/ui, Radix) and Tailwind v4 setup are owned by **apex-design-system** — defer.

## Eliminating waterfalls (Vercel)

Waterfalls = sequential data fetches that could be parallel. Critical priority.

- **Server components**: `Promise.all()` parallel data fetches before render
- **Client components**: use SWR/React Query with `parallel` queries, not sequential `await`
- **Route prefetching**: `<Link prefetch>` for predictable navigation
- **Streaming**: use `<Suspense>` boundaries to show partial UI while data loads

## Composition patterns

Avoid boolean prop explosion (`isLarge`, `isDisabled`, `isLoading`, `isPrimary`...).
Use compound components and state lifting instead:
- `<Tabs>` + `<Tabs.List>` + `<Tabs.Panel>` over `<Tabs variant="underline" size="md" />`
- Internal composition: accept `children` + `slots`, not 10 props

## Web quality targets (Lighthouse)

| Metric | Target |
|--------|--------|
| Performance score | ≥ 90 |
| Accessibility score | 100 |
| Best Practices | ≥ 95 |
| SEO | ≥ 95 |
| LCP | ≤ 2.5s |
| INP | ≤ 200ms |
| CLS | ≤ 0.1 |

## Standards

Next.js App Router docs — nextjs.org/docs
Vercel Agent Skills — github.com/vercel-labs/agent-skills
