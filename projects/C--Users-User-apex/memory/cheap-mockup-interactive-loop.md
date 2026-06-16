---
name: cheap-mockup-interactive-loop
description: "User's preferred cheap-mockup / UI design-prototype loop is INTERACTIVE co-review (not Claude-solo headless). Single mockup previews in Cursor's in-editor render (same window as the live code diff); external Chrome only for multi-variant side-by-side. User comments → Claude edits view-layer → user re-views → repeat to approval."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 9a478326-5d45-4f79-9491-313736f0f4c9
---

When in **cheap-mockup / UI design-prototype mode**, the user's preferred loop is **interactive
co-review**, not a fully-autonomous Claude-solo pass:

1. Claude writes a self-contained `mockup.html` (logic-free; inline styles; CDN Tailwind/fonts if needed)
   to `docs/research/mockups/<name>.html`.
2. **Single mockup → the user previews it in Cursor's in-editor render** (the default). They keep the
   `.html` open, so Claude's edit lands as a **live diff** AND the rendered pane updates in the **same
   window** — one surface for code + pixels ([[cursor-coedit-flow]]). No external browser needed.
3. User types comments → Claude edits the mockup (**view-layer only**) → user re-views the Cursor render →
   repeat **until the user approves**.

**Browser is the fallback, not the default (changed 2026-06-16).** If the user *prefers* a browser for a
single mockup, the same `.html` opens in their OWN Chrome tab (`file://…` or served) that stays open the
whole loop — but Cursor's in-editor render is the default surface now. Either way the tab is **NEVER a
Playwright-controlled one**: Playwright is Claude's *separate* headless screenshot instance; never
`browser_close` the user's view, never route their tab through Playwright. Optional `live-server`/`vite`
for browser auto-reload.

**Options/variants → one window, many tabs.** When the user asks for *options*, write each variant to its
own `docs/research/mockups/<name>.html` and open them **all at once as tabs in the user's own Chrome
window** in a single launch (Windows: `Start-Process chrome -ArgumentList 'file://…A','file://…B',…`) so
they persist for **side-by-side comparison**. Never open option tabs via Playwright — they close on
context end (the user's reported failure). Iterate per option: comment → edit that file → refresh that tab.

**Why:** the user wants eyes-on + comment control over each iteration, not an autonomous one-shot. This is
the default whenever the user is present for a UI mockup.

**How to apply:** keep the `.html` open in Cursor so the render + diff update together; iterate on
comments; view-layer edits only; stop when the user says it's right. Reach for Chrome only for
multi-variant side-by-side. Encoded in `apex-ui-ux-design` v1.20.0 (§ Cheap-mode preview — interactive
co-review loop).

Related: [[ui-design-cheap-display-default]] · [[ui-preview-terminal-plus-browser]] · [[cursor-coedit-flow]]
