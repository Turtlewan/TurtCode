---
skill: apex-frontend
backend: claude
version: 1.1.0
last_updated: 2026-05-28
sources:
  - Next.js Docs — nextjs.org/docs
  - Web Vitals — web.dev/vitals
  - Vercel Agent Skills — github.com/vercel-labs/agent-skills
  - Web Quality Skills (addyosmani) — github.com/addyosmani/web-quality-skills
  - shadcn/ui — github.com/shadcn-ui/ui
  - Radix Primitives — github.com/radix-ui/primitives
  - Tailwind CSS — github.com/tailwindlabs/tailwindcss
staleness_threshold: 14d
---

# Frontend Specialist — Planning Mode

## When to activate
Any spec involving: React components, Next.js pages or layouts, CSS/Tailwind,
browser APIs, client-side state, bundle optimisation, rendering strategy.

## Questions to ask before designing

- Is this a server component or client component? What's the data-fetching strategy?
- Does this need client-side state, or can it be server-rendered?
- Is this a shared component or a one-off page layout?
- What are the loading and error states?
- Are there responsive design requirements?

## Rendering strategy trade-offs

Server Component (default in Next.js App Router):
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
- [ ] No data fetching in client components — fetch in server components or API routes
- [ ] Loading states defined (Suspense boundary or loading.tsx)
- [ ] Error states defined (error.tsx or ErrorBoundary)
- [ ] TypeScript props typed — no implicit any
- [ ] Images use next/image with width/height or fill
- [ ] Links use next/link
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
