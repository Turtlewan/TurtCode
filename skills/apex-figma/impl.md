---
skill: apex-figma
version: 1.0.0
last_updated: 2026-05-24
sources:
  - Figma MCP Server — github.com/figma/mcp-server-guide
  - Figma Context MCP (Framelink) — github.com/GLips/Figma-Context-MCP
staleness_threshold: 30d
---

# Figma Implementation Rules

## NEVER do

- Hardcode Figma token values as hex/px in components — map to Tailwind `@theme` tokens
- Create a new component that already exists in the design system — reuse first
- Treat Figma MCP output as literal code — it is a spec; translate to project conventions
- Use absolute positioning when Figma auto layout maps to Flexbox/Grid
- Pull design tokens on every build — extract once, define in `@theme`, reference from there

## ALWAYS do

- Fetch design context via MCP before writing any component from a Figma spec
- Check project components (`Glob components/**`) before creating a new one
- Map Figma color/spacing variables to the project's `@theme` token names
- Use existing Tailwind utility classes — never inline styles
- Validate implementation by comparing MCP screenshot to rendered output

## Design-to-code workflow

```
1. Receive Figma URL from spec
2. Call Figma MCP to fetch design context and design variables
3. Glob existing components — find closest match
4. If match found: extend existing component (new variant or prop)
5. If no match: create new component from shadcn/Radix base
6. Map Figma tokens → project @theme token names
7. Validate: compare MCP screenshot to rendered browser output
```

## Token mapping pattern

```tsx
// Figma token: color/brand/primary → oklch(55% 0.22 260)
// Define in globals.css @theme:
// --color-brand: oklch(55% 0.22 260);

// In component — reference the token name, not the raw value:
<button className="bg-brand text-brand-foreground hover:bg-brand/90">
  {label}
</button>
```

## Auto layout → Flexbox mapping

| Figma auto layout | Tailwind class |
|-------------------|----------------|
| Direction: Horizontal | `flex flex-row` |
| Direction: Vertical | `flex flex-col` |
| Gap: 16 | `gap-4` |
| Padding: 12 16 | `py-3 px-4` |
| Align: Center | `items-center` |
| Justify: Space between | `justify-between` |

## Verification checklist

- [ ] All design tokens mapped to `@theme` — no hardcoded hex/px in components
- [ ] No duplicate components — checked existing project before creating
- [ ] Auto layout translated to Flexbox/Grid — no absolute positioning
- [ ] MCP screenshot compared to rendered output — no major deviations
- [ ] Component re-uses existing shadcn/Radix base where applicable

## Flag for Claude review

- Figma uses a token not defined in the project `@theme` — define it before implementing
- Figma layout cannot be reproduced with Flexbox/Grid — flag for CSS Grid subgrid discussion
- Design uses a custom illustration or icon not in Lucide — flag for asset sourcing
