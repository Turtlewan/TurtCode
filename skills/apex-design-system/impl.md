---
skill: apex-design-system
version: 1.0.0
last_updated: 2026-05-24
sources:
  - shadcn/ui — ui.shadcn.com
  - Radix Primitives — radix-ui.com/primitives
  - Tailwind CSS v4 — tailwindcss.com
  - Storybook — storybook.js.org
staleness_threshold: 14d
---

# Design System Implementation Rules

## NEVER do

- Build interactive components from scratch (dialog, dropdown, tooltip) — use Radix primitives
- Hardcode colour values (hex/RGB) in components — use design tokens via `@theme`
- Import all of shadcn — use `npx shadcn@latest add <component>` per component
- Use pixels for spacing — use Tailwind scale (4px base unit)
- Create a custom table component — use TanStack Table
- Override shadcn styles via external CSS — edit the copied source directly

## ALWAYS do

- Extend shadcn/ui components by editing the copied source — never patch via CSS overrides
- Define design tokens in CSS `@theme` (Tailwind v4), not in `tailwind.config.js`
- Add a Storybook story for every new component (default + all variants)
- Use `cn()` (clsx + tailwind-merge) for conditional class composition
- Keep component logic and styles co-located in one file

## Tailwind v4 design token pattern

```css
/* globals.css */
@import "tailwindcss";

@theme {
  --color-brand: oklch(55% 0.22 260);
  --color-brand-foreground: oklch(98% 0.01 260);
  --radius-card: 0.75rem;
  --font-sans: 'Inter', sans-serif;
}
```

## shadcn/ui component pattern

```bash
npx shadcn@latest add button dialog
```

```tsx
// components/ui/button.tsx (generated — edit this directly)
import { cn } from "@/lib/utils"

interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'default' | 'outline' | 'ghost'
  size?: 'sm' | 'md' | 'lg'
}

export function Button({ variant = 'default', size = 'md', className, ...props }: ButtonProps) {
  return (
    <button
      className={cn(
        "inline-flex items-center justify-center rounded-md font-medium transition-colors",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand",
        variant === 'default' && "bg-brand text-brand-foreground hover:bg-brand/90",
        variant === 'outline' && "border border-input bg-background hover:bg-accent",
        size === 'sm' && "h-8 px-3 text-xs",
        size === 'md' && "h-10 px-4 text-sm",
        size === 'lg' && "h-12 px-6 text-base",
        className
      )}
      {...props}
    />
  )
}
```

## Verification checklist

- [ ] Run: `npm run build` — 0 TypeScript errors
- [ ] Run: `yarn storybook` — all new component stories render
- [ ] Check: no hardcoded hex/RGB/px values in components
- [ ] Check: all interactive components use Radix primitive as base
- [ ] Check: `cn()` used for all conditional class merging

## Flag for Claude review

- Figma design uses tokens not yet defined in `@theme` — define before implementing
- New chart component needed — flag apex-data (Recharts vs Tremor decision)
- shadcn component needs structural change — discuss before modifying generated code
