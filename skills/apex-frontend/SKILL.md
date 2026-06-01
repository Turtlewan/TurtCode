---
skill: apex-frontend
backend: claude
version: 1.2.0
last_updated: 2026-06-01
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

## Questions to ask before designing

- Is this a server component or client component? What's the data-fetching strategy?
- Does this need client-side state, or can it be server-rendered?
- Is this a shared component or a one-off page layout?
- What are the loading and error states?
- Are there responsive design requirements?

## Rendering strategy trade-offs

> Generic RSC/client trade-offs below. **Next.js-specific** rendering, caching, `next/*`,
> Server Actions, and App Router file conventions live in **apex-nextjs** (Next 16: Turbopack
> default for dev + build, React Compiler on by default) — defer there, don't duplicate.

Server Component (default in React Server Components / Next.js App Router):
- Renders on server, no JS bundle cost, good for static/data-heavy UI
- Cannot use hooks, browser APIs, or event handlers

Client Component ('use client'):
- Needed for interactivity, hooks, browser APIs
- Adds to JS bundle — keep them as leaf nodes, not wrappers

SSG vs SSR vs ISR:
- SSG: static export, fastest, no real-time data
- SSR: server-rendered per request, always fresh, higher TTFB
- ISR: revalidate on interval, balance of both

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

**shadcn/ui**: copy-paste component library (not installed as a package) built on Radix + Tailwind.
Use as a starting point — copy the component, then customise it. Don't fight the design system.

**Radix Primitives**: accessibility-first headless components (Dialog, Select, Tooltip, etc.).
Prefer Radix over custom implementations for any interactive element — it handles ARIA, keyboard nav, and focus management correctly by default.

**Tailwind v4**: significant changes from v3 — check version before applying patterns.
v4 uses CSS-first config (`@theme`), drops `tailwind.config.js` for most use cases.
Utility classes stay the same; build tooling and config format changed.

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

Web Vitals targets: LCP ≤ 2.5s, INP ≤ 200ms (replaces FID), CLS ≤ 0.1
Next.js App Router docs — nextjs.org/docs
Vercel Agent Skills — github.com/vercel-labs/agent-skills
