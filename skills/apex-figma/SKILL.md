---
skill: apex-figma
version: 1.0.0
last_updated: 2026-05-24
sources:
  - Figma MCP Server Guide — github.com/figma/mcp-server-guide
  - Figma Context MCP (GLips/Framelink) — github.com/GLips/Figma-Context-MCP
staleness_threshold: 30d
---

# Figma Specialist — Planning Mode

## When to activate
Spec references a Figma design, design-to-code work is needed, or design tokens need to be extracted from a source file.

## Two MCP tools available

**Figma MCP (official)** — figma.com/developers/mcp
- Read: design context, design tokens (variables), component definitions, Code Connect references, auto layout data, screenshots
- Write (remote server): create frames, components, variables, auto layout in Figma
- Returns structured React + Tailwind representation of selection

**Figma Context MCP (Framelink/GLips)** — github.com/GLips/Figma-Context-MCP
- Read-only: simplified layout and styling metadata from a Figma file URL
- Lower noise — trims Figma API response to what's actually useful for code generation
- Good choice if you only need design-to-code (no write operations needed)

## Design-to-code workflow

1. User pastes a Figma file/frame URL
2. Fetch design context via MCP (prefer official MCP for token access)
3. Read existing project components via Code Connect references — reuse before creating new
4. Translate Figma output into project conventions (Tailwind, shadcn, existing component names)
5. Validate implementation against original design (screenshot comparison if available)

**Key principle**: use existing project components first. Figma output is the spec — not literal code.

## Design token extraction

The official Figma MCP exposes design variables (colours, spacing, typography).
Always reference tokens in generated code — no hardcoded hex/px values:

```tsx
// From Figma token: color/brand/primary → mapped to Tailwind token
<div className="bg-brand-primary text-brand-on-primary" />
```

## Escalation rules

FLAG:
- Figma uses design tokens but project has no token system — flag to set up `@theme` in Tailwind
- Figma layout uses auto layout but code uses absolute positioning — flag as misalignment
- Component in Figma has no equivalent in design system — flag to apex-design-system
