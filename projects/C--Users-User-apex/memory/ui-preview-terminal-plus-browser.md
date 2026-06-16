---
name: ui-preview-terminal-plus-browser
description: "For live UI preview of the RUNNING APP while building (dev server / localhost), user uses terminal + external Chrome (Win-snap), NOT Cursor in-editor Simple Browser. NOTE (2026-06-16): does NOT cover static cheap-mockups — those now render in Cursor's in-editor pane, see [[cheap-mockup-interactive-loop]]."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f83aa40b-7d45-4d88-822e-f66a1914861a
---

For watching the **running app** change live while building (dev server / localhost), the user works in a
**terminal + a separate Chrome window** (Windows snap: `Win+←` / `Win+→`), not Cursor's in-editor Simple
Browser pane or editor splits.

**Scope narrowed (2026-06-16):** this is the *running-app* preview case only. For **static cheap-mockups**
(a logic-free `.html`), the user now previews in **Cursor's in-editor render** — see
[[cheap-mockup-interactive-loop]]. A served localhost app in Cursor's Simple Browser was the fiddly part
(below); a static file rendering in a Cursor pane is not, and that path the user has confirmed works.

**Why:** Cursor editor-layout config proved fiddly and unreliable in practice — panel-position
commands ("Move Panel Right") didn't surface, the Claude Code "Open in New Tab" command opens the
*extension chat* (not the user's terminal session), and moving the terminal into the editor area was
more friction than it was worth. Cursor is a VS Code fork, so switching editors gains nothing here.

**How to apply:** when the user wants to "see UI changes," default to *run the dev server → open the
localhost URL in Chrome → snap windows side by side*. Don't propose moving Cursor panels or editor
splits unless they explicitly ask. For *my* eyes on the render, take a Playwright-MCP screenshot.
Relates to [[no-reflexive-ui-render-prompt]] and the apex-ui-ux-design live-preview loop (ADR-020).
