---
skill: apex-figma
backend: deepseek
version: 1.1.0
last_updated: 2026-06-01
sources:
  - Figma MCP Server — developers.figma.com/docs/figma-mcp-server
  - Figma Context MCP (Framelink) — github.com/GLips/Figma-Context-MCP
staleness_threshold: 30d
description: >
  Use when implementing components from a Figma spec in coding mode. Triggers: Figma URL in
  spec, design-token extraction task, MCP design-context fetch. Not for design decisions or
  token architecture (those are planning mode).
---

# Figma Implementation Rules

## Stack assumptions

Patterns below assume the **React + Tailwind + shadcn/Radix** target (APEX web default). For a
SwiftUI / Flutter / Angular target, swap the token sink, layout primitive, and component base
per § Stack assumptions in `SKILL.md`; the NEVER/ALWAYS rules hold for every target (map tokens,
reuse components, layout-not-absolute, extract-once).

## DeepSeek image caveat — read first

The Figma MCP returns **screenshots**; visual comparison needs image support, which the DeepSeek
coding backend **does not have**. So at any "compare screenshot to rendered output" step below:
**DeepSeek must SKIP the visual comparison and flag it for planning-mode (Claude) review** — do
not guess whether it matches. Verify everything else (tokens, components, layout) normally.

## NEVER do

- Hardcode Figma token values as hex/px in components — map to the target's token sink
- Create a new component that already exists in the design system — reuse first
- Treat Figma MCP output as literal code — it is a spec; translate to project conventions
- Use absolute positioning when Figma auto layout maps to Flexbox/Grid (or HStack/VStack)
- Pull design tokens on every build — extract once, define in the token sink, reference from there
- Claim a visual match you can't see — DeepSeek has no image support; flag the comparison instead

## ALWAYS do

- Fetch design context via MCP before writing any component from a Figma spec
- Check project components (`Glob components/**`) before creating a new one
- Map Figma color/spacing variables to the project's token names
- Use existing utility classes / design-system primitives — never inline styles
- At the validate step, **flag the screenshot comparison for planning-mode review** (see caveat)

## Design-to-code workflow

```
1. Receive Figma URL from spec
2. Call Figma MCP to fetch design context and design variables
3. Glob existing components — find closest match
4. If match found: extend existing component (new variant or prop)
5. If no match: create new component from the target's base (shadcn/Radix on web)
6. Map Figma tokens → project token names
7. Validate non-visual: tokens mapped, components reused, layout not absolute.
   → SKIP visual screenshot comparison (no image support) and FLAG it for planning review.
```

> Token-mapping + auto-layout→utility examples (React/Tailwind): read
> `references/react-tailwind-tokens.md` when the target is React/Tailwind.

## Verification checklist

- [ ] All design tokens mapped to the token sink — no hardcoded hex/px in components
- [ ] No duplicate components — checked existing project before creating
- [ ] Auto layout translated to Flexbox/Grid (or native stack) — no absolute positioning
- [ ] Visual screenshot comparison **flagged for planning review** (DeepSeek can't see images)
- [ ] Component re-uses existing design-system base where applicable

## Flag for planning-mode review

- The MCP screenshot-vs-rendered visual comparison (always — no image support on this backend)
- Figma uses a token not defined in the project token sink — define it before implementing
- Figma layout cannot be reproduced with Flexbox/Grid — flag for CSS Grid subgrid discussion
- Design uses a custom illustration or icon not in the project icon set — flag for asset sourcing
- Token-sync requested but team lacks Enterprise + Full seat — REST API will fail (see SKILL.md)
