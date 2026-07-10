---
skill: apex-figma
backend: coding
version: 1.2.0
last_updated: 2026-07-10
sources:
  - Figma MCP Server — developers.figma.com/docs/figma-mcp-server
  - Figma Context MCP (Framelink) — github.com/GLips/Figma-Context-MCP
  - ADR-027 (sighted coder — Codex gpt-5.6-terra native vision, Opus fallback)
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

## Visual comparison — sighted coder, host-fetched assets

The coder (Codex `gpt-5.6-terra`, native vision; Opus fallback — ADR-027) inspects and compares
screenshots directly. Caveat: a headless `codex exec` subprocess carries no MCP tools of its own —
the **host** calls the Figma MCP, exports the reference frame/assets to files, and passes those file
paths in the dispatch for the coder to compare against. Design **sign-off** still lands with the
host/planning review gate (apex-ui-ux-design § Visual review gate) — evaluator-independence, not a
vision workaround.

## NEVER do

- Hardcode Figma token values as hex/px in components — map to the target's token sink
- Create a new component that already exists in the design system — reuse first
- Treat Figma MCP output as literal code — it is a spec; translate to project conventions
- Use absolute positioning when Figma auto layout maps to Flexbox/Grid (or HStack/VStack)
- Pull design tokens on every build — extract once, define in the token sink, reference from there
- Claim a visual match without actually comparing the rendered output against the reference image supplied in the dispatch

## ALWAYS do

- Fetch design context via MCP before writing any component from a Figma spec
- Check project components (`Glob components/**`) before creating a new one
- Map Figma color/spacing variables to the project's token names
- Use existing utility classes / design-system primitives — never inline styles
- At the validate step, **compare the rendered output against the Figma reference screenshot/exported frame** provided in the dispatch; fix drift in the build (see § Visual comparison)

## Design-to-code workflow

```
1. Receive Figma URL from spec
2. Call Figma MCP to fetch design context and design variables
3. Glob existing components — find closest match
4. If match found: extend existing component (new variant or prop)
5. If no match: create new component from the target's base (shadcn/Radix on web)
6. Map Figma tokens → project token names
7. Validate: tokens mapped, components reused, layout not absolute — AND compare the rendered
   output against the Figma reference screenshot/exported frame supplied in the dispatch; fix
   any drift in the build. Design sign-off still routes to the host/planning review gate (below).
```

> Token-mapping + auto-layout→utility examples (React/Tailwind): read
> `references/react-tailwind-tokens.md` when the target is React/Tailwind.

## Verification checklist

- [ ] All design tokens mapped to the token sink — no hardcoded hex/px in components
- [ ] No duplicate components — checked existing project before creating
- [ ] Auto layout translated to Flexbox/Grid (or native stack) — no absolute positioning
- [ ] Rendered output compared against the Figma reference screenshot/exported frame — drift fixed in the build
- [ ] Component re-uses existing design-system base where applicable

## Flag for planning-mode review

- Design **sign-off** (does fidelity meet the bar — a subjective taste call) — host/planning review gate, not a routine coder check
- Figma uses a token not defined in the project token sink — define it before implementing
- Figma layout cannot be reproduced with Flexbox/Grid — flag for CSS Grid subgrid discussion
- Design uses a custom illustration or icon not in the project icon set — flag for asset sourcing
- Token-sync requested but team lacks Enterprise + Full seat — REST API will fail (see SKILL.md)
