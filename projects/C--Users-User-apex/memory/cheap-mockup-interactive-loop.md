---
name: cheap-mockup-interactive-loop
description: "User's preferred cheap-mockup / UI design-prototype loop is INTERACTIVE co-review (not Claude-solo headless): a persistent user-owned Chrome tab that never closes, user comments → Claude edits view-layer → user refreshes → repeat to approval."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 9a478326-5d45-4f79-9491-313736f0f4c9
---

When in **cheap-mockup / UI design-prototype mode**, the user's preferred loop is **interactive
co-review**, not a fully-autonomous Claude-solo pass:

1. Claude writes a self-contained `mockup.html` (logic-free; inline styles; CDN Tailwind/fonts if needed).
2. The **user opens it once in their OWN Chrome tab** (`file://…` or a served URL). **This tab must NOT
   close** — it stays open across the entire loop.
3. User types comments → Claude edits the mockup (**view-layer only**) → user **refreshes (Ctrl+R)** and
   checks → repeat **until the user approves**.

**Hard mechanic — the persistent tab is the user's own browser, NEVER a Playwright-controlled one.**
Playwright is Claude's *separate* headless instance for its own screenshots; never `browser_close` the
user's view, and never route the user's persistent tab through Playwright. Claude may still self-screenshot
for its own check, but the user's tab is decoupled. Optional upgrade: `live-server`/`vite` for auto-reload
instead of manual refresh (the user said "I refresh", so manual is the default — auto is opt-in).

**Options/variants → one window, many tabs.** When the user asks for *options*, write each variant to its
own `docs/research/mockups/<name>.html` and open them **all at once as tabs in the user's own Chrome
window** in a single launch (Windows: `Start-Process chrome -ArgumentList 'file://…A','file://…B',…`) so
they persist for **side-by-side comparison**. Never open option tabs via Playwright — they close on
context end (the user's reported failure). Iterate per option: comment → edit that file → refresh that tab.

**Why:** the user wants eyes-on + comment control over each iteration, not an autonomous one-shot. This is
the default whenever the user is present for a UI mockup.

**How to apply:** keep the tab alive; iterate on comments; view-layer edits only; stop when the user says
it's right. Encoded in `apex-ui-ux-design` v1.15.0 (§ Cheap-mode preview — interactive co-review loop).

Related: [[ui-design-cheap-display-default]] · [[ui-preview-terminal-plus-browser]] · [[cursor-coedit-flow]]
