---
name: design-style-on-demand
description: "Don't auto-load fixed-aesthetic style skills; establish the feel first, then select+install the matching style from a style-library shelf"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 64c46fc0-25aa-4be2-9d1e-a04047a6d0ad
---

Fixed-aesthetic "style/taste" skills must NOT be auto-loaded into every session. Co-installed
ones collided hard (mandated-vs-banned glassmorphism, Lucide, nested cards, infinite motion) and
constraint-stacking taxes compliance (~30 pts, arXiv:2605.06445) — so a pile of always-on taste
skills actively degrades design output, not just bloats context.

**The model the user chose (Mechanism A, 2026-06-12):** establish the *feel* first via the
per-project design brief's art-direction line, THEN select + install the one matching style from a
`~/.claude/style-library/` shelf (outside the skills auto-load path). `apex-ui-ux-design` owns the
feel→style selection, reading the library `INDEX.md`. New aesthetic skills go to the style library,
never to `~/.claude/skills/`.

**Why:** decouples "what look" (chosen per project) from "always loaded" (nothing aesthetic);
zero default context cost; impossible for styles to collide at generic-build time.

**How to apply:** never auto-load a fixed look; a new "style/taste" skill is a library entry, not an
installed skill; the design brief records the chosen feel + which library style to pull. See
[[absorption-pass-protocol]] (report-first) and the design-capability research in
`docs/research/design-capability/`.
