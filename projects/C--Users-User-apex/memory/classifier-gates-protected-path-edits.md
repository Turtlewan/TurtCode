---
name: classifier-gates-protected-path-edits
description: Auto-mode classifier gates .claude/ protected-path writes in planning; can false-positive on permission-meta content; dontAsk denies protected paths outright
metadata: 
  node_type: memory
  type: reference
  originSessionId: c15fb9f9-11c6-4b2e-afab-9a8d18e800ee
---

The Claude Code **auto-mode safety classifier** is a separate gate from APEX's PreToolUse write-guard hook. `.claude/`, `.git/`, `.vscode/`, dotfiles etc. are **protected paths**: in `auto` mode their writes route to the classifier *even when allow-listed*; in `acceptEdits` they **prompt**; in `dontAsk` they are **denied outright** (`permissions.allow` cannot override). Source: CC `/permission-modes` protected-paths table.

**Planning mode (Anthropic backend):** the classifier runs on Anthropic (reliable — not the DeepSeek SPOF). APEX edits `.claude/` skills constantly here and they pass silently. But an edit whose **content describes disabling/skipping the classifier** (e.g. `dontAsk`, "never calls the classifier", "cycle off auto") can be **denied as a false-positive** — a safety model double-checking content about weakening safety gating. Observed 2026-06-20 applying `classifier-spof-dontask-mode.md`: the classifier blocked the `apex-code` edit; user approval cleared it. **This is expected, not a bug — approve and continue. Do NOT route around a classifier denial with sed/heredoc.**

`auto` is the least-friction mode for planning-mode skill authoring (silent pass for benign edits; the alternatives are worse — `acceptEdits` prompts every `.claude/` write, `dontAsk` denies them). So no system fix is warranted for the false-positive.

Consequence for the coding path: a DeepSeek build run in `dontAsk` ([[apex-sole-coding-workflow]] / apex-code 1.17.x classifier-SPOF policy) **cannot write protected paths** — so any spec that edits a skill's `impl.md` or `~/.claude/workflows/*` must be applied in planning mode, not inside the `dontAsk` build. Relates to [[verify-env-claims-live]] (check harness behaviour live, don't assume).
