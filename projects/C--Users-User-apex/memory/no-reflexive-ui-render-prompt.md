---
name: no-reflexive-ui-render-prompt
description: "Don't auto-offer a visual UI render/screenshot whenever UI is discussed or changed — only when seeing pixels is the actual deliverable"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 428482ec-aa10-47eb-9221-005723b52631
---

Do NOT reflexively prompt/offer a visual UI render (screenshot or generated HTML/image render) whenever the user is making UI changes OR just talking about UI. Default to the cheap path and stay silent about visual rendering unless the change is **visual by nature**: layout/spacing, styling/colour, a new component's look, responsive breakpoints, or Figma design-fidelity. For functional/structural/copy/logic/a11y UI work, never raise screenshots.

**Why:** A rendered image costs ~1,600+ tokens each and accumulates *inline* (re-sent every turn) — a 10-step screenshot flow ≈ 88K tokens, one pathological full-page screenshot measured at 232K — vs ~200–2,000 tokens for an accessibility snapshot (text) or ~tens for an ASCII mockup. Offering it on *every* UI touch meant constant expensive prompts the user rightly dismissed multiple times. The capability was never wrong; the unconditional trigger was. See [[be-token-efficient]].

**How to apply:** Snapshot-first / ASCII-mockup-first. In coding, drive + verify via the a11y snapshot (Playwright `browser_snapshot`); in planning, sketch layout choices as ASCII/preview mockups. Spend pixel tokens only as a *one-shot checkpoint* when the model must literally see the result (visual regression, CSS/layout break, canvas/charts, Figma fidelity) — one render at the checkpoint, never a per-step loop. Rule of thumb: "offer a visual render only when the thing being changed is something I'd have to literally see to judge."
