---
name: ui-preview-terminal-plus-browser
description: "For live UI preview while building, user uses terminal + external Chrome (Win-snap), NOT Cursor in-editor Simple Browser / panel splits"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f83aa40b-7d45-4d88-822e-f66a1914861a
---

For watching UI changes live while building, the user works in a **terminal + a separate Chrome
window** (Windows snap: `Win+←` / `Win+→`), not Cursor's in-editor Simple Browser pane or editor splits.

**Why:** Cursor editor-layout config proved fiddly and unreliable in practice — panel-position
commands ("Move Panel Right") didn't surface, the Claude Code "Open in New Tab" command opens the
*extension chat* (not the user's terminal session), and moving the terminal into the editor area was
more friction than it was worth. Cursor is a VS Code fork, so switching editors gains nothing here.

**How to apply:** when the user wants to "see UI changes," default to *run the dev server → open the
localhost URL in Chrome → snap windows side by side*. Don't propose moving Cursor panels or editor
splits unless they explicitly ask. For *my* eyes on the render, take a Playwright-MCP screenshot.
Relates to [[no-reflexive-ui-render-prompt]] and the apex-ui-ux-design live-preview loop (ADR-020).
