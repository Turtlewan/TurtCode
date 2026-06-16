---
name: cursor-coedit-flow
description: "User's primary coding flow — APEX in Cursor's integrated terminal, co-editing files live in the editor (watch APEX edit + hand-edit alongside)"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 7ec56d97-9da3-4052-888a-f0894f778b2c
---

User is moving their main coding flow to **co-editing inside Cursor**: APEX (Claude Code) runs
in Cursor's integrated terminal, and they watch/edit the same files in Cursor's editor panes.

**Why:** they want to see code change as APEX edits it and be able to hand-edit alongside it.

**How to apply:**
- The live "watch it edit" experience needs the file **already open** in Cursor — APEX's edit
  then lands in-place as a diff. A file that's *not* open only shows a transient diff-preview tab
  that closes on approve and leaves nothing behind. So: keep working files open.
- Suggest **auto-accept mode** (`Shift+Tab`) for smooth interactive co-editing; reserve
  prompt-per-edit for unattended AFK builds.
- This co-edit loop fits APEX **edit mode** (single-threaded main session). **AFK build mode**
  runs wave-parallel subagents whose edits do NOT stream into the IDE diff view → prefer edit
  mode when co-editing.
- The integration is **read-editor-state + push-diffs only**; it does NOT drive Cursor's
  tabs/windows. APEX cannot open a file for the user (no openFile tool exposed — only
  ide diagnostics + executeCode). Opening tabs stays the user's action.
- Bidirectional edit: save your hand-edits; APEX re-reads disk before editing and the harness
  blocks edits made against a stale view. Don't hold an unsaved buffer while APEX edits the same
  file (dirty buffer won't auto-reload → conflict).
- IDE diff/auto-open is a **harness** feature, so it behaves identically on the DeepSeek coding
  backend, not just planning.

**For UI work specifically** (ties [[ui-preview-terminal-plus-browser]] + [[ui-design-cheap-display-default]]):
- Run two loops side by side — **code diff in Cursor** + **rendered UI in external Chrome snapped
  beside it**. Co-edit deliberately does NOT merge them (Cursor shows source, Chrome shows pixels).
- The image-blind coder (DeepSeek) can't see the render, so under auto-accept **you are the eyes** —
  watch the diff land and the Chrome preview update together, catching visual divergence live (the
  real-time half of ADR-020 capability-routed UI escalation).
- **Hand-edit visual values directly** (spacing/colour/alignment nudges) — faster than describing a
  few-px change to an image-blind model and round-tripping. APEX re-reads from disk and continues.
- **Edit mode only** for visual UI work (diffs stream + someone's watching pixels); reserve AFK
  builds for non-visual UI plumbing (data wiring, handlers, state).
- Design stage (cheap-display mockups, Claude as primary UI hand, lock-before-wire) is upstream and
  unchanged — co-edit only affects the editing/wiring stage.

Distinct from [[ui-preview-terminal-plus-browser]]: that is rendered-UI *preview* → external
Chrome; this is code *co-editing* → Cursor's editor. Different concerns, both valid.
