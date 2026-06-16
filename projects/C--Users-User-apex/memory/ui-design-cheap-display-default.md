---
name: ui-design-cheap-display-default
description: "Adopted default for the UI design phase — cheap-display logic-free mockup with Claude as primary UI hand, then DeepSeek wires it"
metadata: 
  node_type: memory
  type: project
  originSessionId: f83aa40b-7d45-4d88-822e-f66a1914861a
---

The agreed default for the UI **design/prototype phase** (affirmed session 45, 2026-06-16) is
**"cheap display"**: iterate a **logic-free mockup** (mock data, no backend/nav) rendered cheaply,
with **Claude as the primary UI hand** at this stage — because a tiny logic-free surface is cheap
even at Claude's ≈29× per-token cost.

Loop: brief → cheap mockup iteration (Claude edits, user views live, Claude takes a Playwright
screenshot to see pixels) → lock into `design-brief.md` → **DeepSeek wires the locked design into the
real app** (logic returns → cheap mode ends) → visual gate → escalation if needed.

Render path by target: web / Electron / Tauri → Chrome + Playwright (trivial); Flutter / Android
Compose / Avalonia → Tier-A headless render (`flutter test --update-goldens`, Paparazzi, Avalonia
headless); **SwiftUI is Mac-gated** (web-mockup proxy for layout/feel only).

**Why:** keeps UI design fast + token-light, and routes the work to the image-capable model exactly
where it's cheap; the image-blind coder still carries the wired build.
**How to apply:** when the user wants to design/iterate UI, default to this loop; never pull app
logic into the visual loop.

Full method: `apex-ui-ux-design` 1.13.0 (§ Live preview + cheap-mode) + ADR-020 +
`docs/research/cheap-mode-native/`. Pairs with [[ui-preview-terminal-plus-browser]] and
[[design-style-on-demand]].
