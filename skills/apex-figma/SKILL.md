---
skill: apex-figma
backend: planning
version: 1.2.0
last_updated: 2026-07-10
sources:
  - Figma MCP Server — developers.figma.com/docs/figma-mcp-server
  - Figma MCP (remote vs desktop) — help.figma.com/hc/en-us/articles/35281385065751
  - Figma Context MCP (GLips/Framelink) — github.com/GLips/Figma-Context-MCP
  - Code Connect — developers.figma.com/docs/code-connect
  - ADR-027 (sighted coder — Codex gpt-5.6-terra native vision, Opus fallback)
staleness_threshold: 30d
description: >
  Use when a spec references a Figma file, design-to-code work is needed, or design tokens
  must be extracted from a source file. Triggers: user pastes a Figma URL, "turn this design
  into a component", Dev Mode, Code Connect, design-system handoff, "extract the tokens".
  Not for pure UI work with no Figma source (→ apex-design-system / apex-frontend), or
  prompt-to-app prototyping (that's Figma Make — see § Figma Make).
---

# Figma Specialist — Planning Mode

## Stack assumptions

Default codegen target is **React + Tailwind + shadcn/Radix + Lucide** (the APEX web default).
Figma is the *source*, not the target — the same design context generates code for any stack.
Swap the target per project:

| Target | Token sink | Layout primitive | Component base |
|--------|-----------|------------------|----------------|
| **React + Tailwind** (default) | `@theme` CSS vars | flex/grid utilities | shadcn/Radix |
| **SwiftUI** | `Color`/`Spacing` asset catalog or constants | `HStack`/`VStack`/`Grid` | native + apex-swift |
| **Flutter** | `ThemeData` / design-token Dart consts | `Row`/`Column`/`Flex` | Material/Cupertino widgets |
| **Angular / Vue + SCSS** | SCSS vars / CSS custom props | flexbox/grid | project component lib |

Framework-specific code lives in `references/` — see the load conditions below.

## When to activate
Spec references a Figma design, design-to-code work is needed, or design tokens need to be
extracted from a source file.

## MCP tools available

**Figma MCP (official)** — `developers.figma.com/docs/figma-mcp-server`
Install (Claude Code): `claude mcp add --transport http figma https://mcp.figma.com/mcp`
- Returns **design context** — component metadata, variables (tokens), auto layout data,
  Code Connect references, and screenshots. It is *framework-aware context*, not a fixed
  React/Tailwind output — the LLM generates code in the project's stack.
- **Remote server** (default): all seats; broadest features incl. write-to-canvas (beta).
  **Starter/View/Collab seats are capped at ~6 MCP calls/month** — effectively unusable for
  real design-to-code; needs a **Dev or Full seat on a paid plan**.
- **Desktop server**: Dev/Full seat, paid only; selection-in-app context; no write-to-canvas.

**Figma Context MCP (Framelink/GLips)** — `github.com/GLips/Figma-Context-MCP`
- Read-only: trims the Figma API response to low-noise layout/styling metadata from a file URL.
- Good when you only need design-to-code and want lower token cost than the official server.
- **Security: pin to ≥ v0.6.3** — earlier versions carry CVE-2025-53967 (critical RCE).
  Prefer the official MCP unless token/noise reduction is the explicit priority.

## Design-to-code workflow

1. User pastes a Figma file/frame URL
2. Fetch design context via MCP (prefer official MCP for token access)
3. Read existing project components via Code Connect references — reuse before creating new
4. Translate Figma output into project conventions (per § Stack assumptions — token sink,
   layout primitive, component base)
5. Validate implementation against original design (screenshot comparison — the coder does this
   itself during the build, see impl.md § Visual comparison; final sign-off stays a host/planning
   review gate)

**Key principle**: use existing project components first. Figma output is the spec — not
literal code.

## Design token extraction

The official Figma MCP exposes design variables (colours, spacing, typography). Always
reference tokens in generated code — never hardcoded hex/px. For non-MCP (file-level)
pipelines the 2026 norm is: Figma Variables → Tokens Studio (or REST API) → W3C Design
Tokens JSON → Style Dictionary → platform outputs.

> Worked token-mapping examples (React/Tailwind `@theme`, auto-layout → utilities):
> read `references/react-tailwind-tokens.md` when the target is React/Tailwind.

**Variables REST API gating** — programmatic local-variable read/write/bulk requires a
**Full seat in an Enterprise org**. Non-Enterprise teams cannot sync tokens via REST; the
MCP token read is the practical workaround. Surface this as an escalation flag before
proposing a programmatic token-sync pipeline (see FLAG below).

## Figma Make

Figma Make (GA early 2026) is prompt-to-prototype / prompt-to-app — it generates interactive
React apps from prompts or frames. Its output is **not production-ready** (not accessible,
semantic, or clean). If a user says "turn this Figma into an app", clarify: do they want a
Make prototype (throwaway), or a proper design-to-code pipeline (this skill)? Don't route
production work through Make output.

## Escalation rules

FLAG:
- Figma uses design tokens but project has no token system — flag to set up the target's
  token sink (Tailwind `@theme`, SwiftUI asset catalog, etc.)
- Figma layout uses auto layout but code uses absolute positioning — flag as misalignment
- Component in Figma has no equivalent in design system — flag to apex-design-system
- Token-sync pipeline requested but team is not Enterprise + Full seat — flag the REST API
  gating; the programmatic pipeline will silently fail
