---
skill: apex-design-system
version: 1.0.0
last_updated: 2026-05-24
sources:
  - shadcn/ui — github.com/shadcn-ui/ui
  - Radix Primitives — github.com/radix-ui/primitives
  - Tailwind CSS — github.com/tailwindlabs/tailwindcss
  - Storybook — github.com/storybookjs/storybook
  - floating-ui — github.com/floating-ui/floating-ui
  - Emil Kowalski (vaul, sonner) — github.com/emilkowalski
  - TanStack Table — github.com/TanStack/table
  - Recharts — github.com/recharts/recharts
  - Tremor — github.com/tremorlabs/tremor
staleness_threshold: 14d
---

# Design System Specialist — Planning Mode

## When to activate
Building or extending a component library, adding a new UI primitive, establishing design tokens, or integrating a third-party component system.

## Component stack (recommended defaults)

| Need | Recommended | Why |
|------|-------------|-----|
| Headless primitives | Radix UI | Accessibility built in (ARIA, keyboard, focus) |
| Styled components | shadcn/ui | Copy-paste, fully customisable, Radix foundation |
| Styling | Tailwind CSS v4 | Utility-first, design token system via `@theme` |
| Floating UI (dropdowns, tooltips, popovers) | floating-ui | Correct positioning, collision detection |
| Drawers / sheets | vaul (Emil Kowalski) | Native feel, smooth gesture support |
| Toast / notifications | sonner (Emil Kowalski) | Clean, accessible, stacks correctly |
| Data tables | TanStack Table | Headless, powerful, works with any UI |
| Charts / dashboards | Recharts (general) or Tremor (admin) | Recharts: composable; Tremor: batteries-included |
| Icons | Lucide | Consistent, tree-shakeable, actively maintained |

## shadcn/ui usage pattern

shadcn/ui is **not a package** — it's copy-paste source code.
- Run `npx shadcn@latest add button` to copy the component into your project
- Customise the copy — it's yours
- Never fight the component — modify it at source

## Tailwind v4 key changes (from v3)

- Config is now CSS-first: `@theme { --color-primary: oklch(...); }` in CSS file
- `tailwind.config.js` is optional for most projects
- `@apply` still works but prefer direct utility classes
- New `oklch()` colour space for design tokens
- Check version before applying v3 patterns

## Storybook integration

Every new component should have a Story:
- Demonstrates all visual states (default, hover, disabled, loading, error)
- Enables visual regression testing via Chromatic
- Acts as living documentation
- Accessibility addon (`@storybook/addon-a11y`) runs axe-core per story

```bash
yarn storybook  # dev
npx chromatic --project-token=<token>  # visual regression CI
```

## Questions to ask before designing

- Is there an existing design system to extend, or starting fresh?
- Which component libraries are already installed?
- Are design tokens defined (colours, spacing, typography)?
- Is Storybook already set up?
- What Tailwind version is in use?

## Review checklist

- [ ] New primitives built on Radix (not custom from scratch)
- [ ] Tailwind version confirmed before writing config patterns
- [ ] Every new component has a Storybook story
- [ ] Design tokens defined in CSS `@theme` (not hardcoded hex values)
- [ ] Floating elements (dropdowns, tooltips) use floating-ui for positioning
- [ ] Tables use TanStack Table — no custom table implementations
