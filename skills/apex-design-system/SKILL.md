---
skill: apex-design-system
backend: claude
version: 1.2.0
last_updated: 2026-06-12
sources:
  - shadcn/ui (CLI v4, MCP, registries) — ui.shadcn.com/docs
  - Radix UI (unified package) — radix-ui.com
  - Base UI — base-ui.com
  - Tailwind CSS v4 — tailwindcss.com
  - Storybook — storybook.js.org
  - floating-ui — floating-ui.com
  - Emil Kowalski (vaul, sonner) — github.com/emilkowalski
  - TanStack Table — tanstack.com/table
staleness_threshold: 14d
description: >
  Use when building or extending a component library / design system — UI primitives,
  design tokens, theming, component variants, Storybook stories, registries. Triggers:
  "design system", "component library", "design tokens", "shadcn", "theme this",
  "add a primitive". WEB-STACK skill (React + Tailwind + shadcn/Radix or Base UI). The
  token discipline generalises but the component machinery is web; native design systems →
  apex-swift. Not screen-level UX (apex-ui-ux-design) or animation (apex-animation).
---

# Design System Specialist — Planning Mode

## When to activate
Building or extending a component library, adding a new UI primitive, establishing design tokens, or integrating a third-party component system.

## Stack assumptions

**Web-stack skill** — assumes **React + Tailwind v4 + shadcn/ui** on **Radix or Base UI**
primitives. The *token discipline* (semantic tokens, single source of truth, no hardcoded
values, all states defined) is universal — on **SwiftUI** it maps to Asset Catalog colour
sets + semantic/system colours + Dynamic Type + a shared `Theme` — but the component
machinery here (shadcn CLI, Radix, Storybook, `cn()`) is web-only. Native design system → apex-swift.

## What's current (2026)

- **Unified `radix-ui` package** (Feb 2026) — new-york style imports from a single `radix-ui`
  dep, **not** individual `@radix-ui/react-*` packages. Don't add the old per-component packages.
- **shadcn CLI v4** (Mar 2026) — `shadcn init` scaffolds full templates (Next.js, Vite, Astro,
  React Router, TanStack Start, Laravel). `npx shadcn@latest add <component>` still the per-component flow.
- **shadcn MCP server + shadcn/skills** — agents browse/search/install from registries; prefer
  it for discovering components. Registries can compose multiple `registry.json` files.
- **Base UI** (from the MUI team) is now a supported headless primitive set alongside Radix —
  pick one per project; both give ARIA/keyboard/focus correctly.
- **Tailwind v4**: container queries are built-in; `@theme` + `@theme inline`; oklch tokens.

## Component stack (recommended defaults)

| Need | Recommended | Why |
|------|-------------|-----|
| Headless primitives | Radix UI (unified `radix-ui`) or Base UI | Accessibility built in (ARIA, keyboard, focus) |
| Styled components | shadcn/ui (CLI v4 / MCP) | Copy-paste, fully customisable, Radix/Base foundation |
| Styling | Tailwind CSS v4 | Utility-first, token system via `@theme`, container queries |
| Floating UI (dropdowns, tooltips, popovers) | floating-ui | Correct positioning, collision detection |
| Drawers / sheets | vaul (Emil Kowalski) | Native feel, smooth gesture support |
| Toast / notifications | sonner (Emil Kowalski) | Clean, accessible, stacks correctly |
| Data tables | TanStack Table | Headless, powerful, works with any UI |
| Charts / dashboards | Recharts (general) or Tremor (admin) | Recharts: composable; Tremor: batteries-included |
| Icons | Lucide | Consistent, tree-shakeable, actively maintained |

## shadcn/ui usage pattern

shadcn/ui is **not a runtime package** — it's copy-paste source code (now also installable via
the shadcn MCP server / registries).
- Run `npx shadcn@latest add button` (or use the MCP server) to copy the component into your project
- Customise the copy — it's yours
- Never fight the component — modify it at source

## Tailwind v4 key changes (from v3)

- Config is now CSS-first: `@theme { --color-primary: oklch(...); }` in CSS file
- `tailwind.config.js` is optional for most projects
- Container queries are built-in (no plugin); `@theme inline` for referencing existing vars
- New `oklch()` colour space for design tokens
- Check version before applying v3 patterns

## Token naming convention

Name tokens by **semantic role, not raw value** — one source of truth the image-less coder
references by name (this is what `design-brief.md` tokens map onto). Three tiers:

1. **Primitive** (raw scale, no meaning): `--color-green-600`, `--space-4`, `--radius-10`. Not used
   directly in components.
2. **Semantic** (role-mapped — components use these): `--color-bg`, `--color-surface`, `--color-fg`,
   `--color-muted`, `--color-accent`, `--color-danger`, `--text-body`, `--radius-card`. Map to primitives.
3. **Component** (only for a genuine local override): `--button-bg: var(--color-accent)`.

Rules:
- Components reference **semantic** tokens only — never a primitive or a raw hex/px. A theme change is
  then one edit, and dark mode is a semantic remap, not a component rewrite.
- One name per role across surfaces — the brief's `accent` is `--color-accent` everywhere.
- Match the bound stack's mechanism: Tailwind v4 `@theme` vars (web), `Color` + asset catalog
  (SwiftUI — see apex-swift). The naming discipline is identical; only the syntax swaps.

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
