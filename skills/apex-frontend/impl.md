---
skill: apex-frontend
version: 1.0.0
last_updated: 2026-05-24
sources:
  - Next.js Docs — nextjs.org/docs
  - Web Vitals — web.dev/vitals
staleness_threshold: 14d
---

# Frontend Implementation Rules

## NEVER do

- Add 'use client' to a component that doesn't need browser APIs or hooks
- Fetch data inside a useEffect — use server components or React Query
- Use any type in TypeScript — always type props explicitly
- Use inline styles — Tailwind classes only
- Use <img> — always next/image
- Use <a href> for internal links — always next/link
- Mutate state directly — always use setter functions
- Import a whole library for one function (e.g., import _ from 'lodash')

## ALWAYS do

- Type all component props with an interface or type alias
- Define loading state (Suspense or skeleton)
- Define error state (error.tsx or try/catch with UI feedback)
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

- [ ] Run: `npm run build` — 0 TypeScript errors
- [ ] Run: `npm run lint` — 0 ESLint errors
- [ ] Check: no 'use client' on components that only render static HTML
- [ ] Check: all images use next/image
- [ ] Check: all internal links use next/link
