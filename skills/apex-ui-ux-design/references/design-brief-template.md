# Design brief — `docs/technical/architecture/design-brief.md`

Per-project visual source of truth the **image-less coding model reads**. Scope = stable,
single-homed visual decisions only (ADR-017). Seeded by apex-init (scope-gated to UI-bearing
projects); owned by apex-ui-ux-design. NOT a per-screen visual spec — screens/journeys live in
`app-flow.md`; live per-screen visual judgment is verified by the visual review gate, not frozen here.

```markdown
---
# Tokens — exact values; the coder references these by NAME, never invents per-component values.
tokens:
  color:
    bg:       "#0B0B0F"
    surface:  "#16161D"
    fg:       "#ECECEF"
    muted:    "#9A9AA5"
    accent:   "#2E7D32"
    danger:   "#C0362C"
  type:
    family:   "Söhne, system-ui, sans-serif"   # NOT Inter/Roboto unless deliberate
    scale:    [12, 14, 16, 20, 28, 40]          # rem-based in code
    weight:   { body: 400, medium: 500, bold: 650 }
  space:      [4, 8, 12, 16, 24, 32, 48, 64]    # the only spacing values allowed
  radius:     { sm: 6, md: 10, lg: 16, full: 9999 }
  shadow:     { sm: "0 1px 2px rgb(0 0 0 / .25)", md: "0 4px 16px rgb(0 0 0 / .30)" }
---

## Art direction
<2–4 sentences: product category, mood, 1–2 references, and what it must NOT feel like.>
Example: "Calm, dense ops console for a technical operator. References: Linear, Vercel dashboard.
Confident and quiet — NOT a consumer marketing site, NOT playful, NOT gradient-heavy."

**Chosen feel → style library:** <none | minimalist-ui | industrial-brutalist-ui | high-end-visual-design | …>
(If a style is named, install exactly one from ~/.claude/style-library/ per its INDEX.)

## Forbidden patterns (project-specific don'ts — the highest-evidence lever)
- no purple-on-white gradients / no gradient backgrounds
- no glassmorphism used decoratively
- no cards nested inside cards
- no Inter / Roboto / Space Grotesk
- no `grid-cols-3` card walls for non-uniform content
- no filler CTA copy ("Get Started", "Learn more") — name the action
- <add the ones this project keeps drifting toward>
```

**Authoring notes**
- Tokens are invariants for the whole project — they rarely change, so persisting them is safe.
- The forbidden list is reverse-engineered from this project's recurring AI-slop drift; grow it as
  the visual review gate surfaces repeat offenders.
- Keep it short. If it's growing per-screen sections, that's app-flow.md / live judgment leaking in —
  stop (ADR-017 scope boundary).
