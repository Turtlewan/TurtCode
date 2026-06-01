---
skill: apex-frontend
backend: deepseek
version: 1.1.0
last_updated: 2026-06-01
sources:
  - React 19 — react.dev/blog/2024/12/05/react-19
  - React Compiler — react.dev/learn/react-compiler
  - Next.js 16 — nextjs.org/blog/next-16
  - Web Vitals — web.dev/vitals
staleness_threshold: 14d
description: >
  Coding-mode enforcement for React web frontend — server/client boundaries, React 19
  Actions, no reflexive memoization (React Compiler), TS-typed props, Tailwind. Web-stack;
  native UI is apex-swift. Loads when building React components.
---

# Frontend Implementation Rules

## Stack assumptions

**Web-stack** — React 19+ + DOM + Tailwind. Verification commands come from the bound stack's
`## Verification Recipe` (apex-nextjs / apex-vite etc.), not hardcoded here. `next/*` rules
below apply only when the bound stack is Next.js. Native UI → apex-swift (not this skill).

## NEVER do

- Add 'use client' to a component that doesn't need browser APIs or hooks
- Fetch data inside a useEffect — use server components, the `use()` hook, or React Query
- Add reflexive `useMemo` / `useCallback` / `React.memo` — the React Compiler memoizes; add only on a profiled hot path
- Use `forwardRef` for new components — in React 19 `ref` is a normal prop
- Hand-roll form submit/pending state — use `<form action>` + `useActionState` / `useFormStatus`
- Use any type in TypeScript — always type props explicitly
- Use inline styles — Tailwind classes only
- Mutate state directly — always use setter functions
- Import a whole library for one function (e.g., import _ from 'lodash')
- (Next.js) Use `<img>` / `<a href>` for internal links — use `next/image` / `next/link`

## ALWAYS do

- Type all component props with an interface or type alias
- Use Actions for mutations: `useActionState` for result+pending, `useOptimistic` for instant feedback
- Define loading state (Suspense or skeleton)
- Define error state (ErrorBoundary / `error.tsx` / try-catch with UI feedback)
- Use semantic HTML elements (nav, main, section, article, button)
- Add aria-label to icon-only buttons
- Use Tailwind's responsive prefixes mobile-first (base → sm: → md: → lg:)
- Co-locate component styles and logic — one file per component

## Component structure

```typescript
interface ButtonProps {
  label: string
  onClick: () => void
  disabled?: boolean
  variant?: 'primary' | 'secondary'
}

export function Button({ label, onClick, disabled = false, variant = 'primary' }: ButtonProps) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      aria-label={label}
      className={`px-4 py-2 rounded ${variant === 'primary' ? 'bg-blue-600 text-white' : 'bg-gray-200 text-gray-800'} disabled:opacity-50`}
    >
      {label}
    </button>
  )
}
```

## Verification checklist

- [ ] Run the bound stack's Verification Recipe (e.g. `tsc --noEmit` + lint + build) — 0 errors
- [ ] Check: no 'use client' on components that only render static HTML
- [ ] Check: no reflexive useMemo/useCallback/memo added (let React Compiler handle it)
- [ ] (Next.js) Check: all images use next/image; all internal links use next/link
