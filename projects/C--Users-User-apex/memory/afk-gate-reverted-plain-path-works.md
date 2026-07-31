---
name: afk-gate-reverted-plain-path-works
description: "The `!afk` permission-flag gate was built then REVERTED — unattended builds already work via autonomy mode + acceptEdits + permissions.allow; don't rebuild a second permission system"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 243c0ad7-1738-4738-b48e-8bfe28f78d49
  modified: 2026-07-29T09:17:10.152Z
---

APEX's `!afk` gate (ADR-033 `afk-permission-mode`: `afk.on` flag, terminal arming, `afk-gate.js`
PreToolUse hook, `apex-afk` skill) was **removed on 2026-07-14**. Do not propose or rebuild it.

**Why:** it was a *fail-closed allowlist* — armed, it auto-approved ~24 read/copy/git commands and
non-critical writes and prompted for everything else. No build or test command was on it
(`pytest`/`npm`/`python`/`node`/`uv`/`cargo`), and none are in `permissions.allow` either, so **every
armed run stalled at its own Verification Recipe**. Its critical-path list also gated ordinary build
targets (auth code, migrations, package manifests, CI). Arming bought a halt, not a run.

The user's own words: *"I don't like how the changes we made to the system resulted in the very strict
asking for afk. The previous one where I told it to just run and go ahead when I was AFK and it built
the list, it was fine. Let's get back to that."*

**How to apply:**
- Unattended runs already work with **no flag**: AFK-as-autonomy-mode (apex-governance Build/AFK vs
  Edit — "run the list, don't ask") + `acceptEdits` + the APEX/`~/.claude` write-guard exemption +
  `permissions.allow`. That is what drained the full spec queue unattended in sessions 65, 68 and 69.
- If an unattended run needs a command the classifier won't clear, **add that one command to
  `permissions.allow`** — a targeted, inspectable, always-on grant. Never a second permission system.
- General lesson: when a security review hardens a mechanism whose *entire purpose* is "the owner
  armed this and left," check the hardening didn't invert the threat model. Here the round-2 BLOCK
  flipped Bash from denylist to allowlist — correct for a sandbox, fatal for an unattended run.
- Ceremony added on top of a working path is a regression even when each step is individually
  defensible. Ask "did the plain path actually fail?" before building the gate.

ADR-033's *safety half* (A1 Opus end-of-run pass · A2 silent-regression lenses · A3 invariant
freshness · A4 durable Codex dispatcher) is untouched and still in force — only the permission gate
was reverted.
