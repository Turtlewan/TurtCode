---
name: claude-agent-sdk-billing-split
description: June 15 2026 Anthropic billing split — interactive Claude Code (incl. subagents) stays on subscription pool; headless/programmatic runs hit a separate capped credit pool
metadata: 
  node_type: memory
  type: reference
  originSessionId: c91d2e13-674e-48a7-815d-f7cf2b28fbb4
---

Anthropic split programmatic Claude usage off the flat-rate subscription pool effective **2026-06-15**.

**Two pools:**
- **Interactive (subscription, unchanged):** Claude Code in the terminal/IDE, Claude.ai chat, Cowork — anywhere a human watches each turn.
- **Agent SDK credit (new, capped):** `claude -p` headless, the Agent SDK in your own apps, Claude Code GitHub Actions, third-party apps authing through the SDK. Sized $20 Pro / $100 Max 5x / $200 Max 20x, at standard API rates, monthly reset, **no rollover**, hard-stops when exhausted unless overflow billing is enabled.

**Implication for APEX:**
- Normal **interactive planning** sessions — including all subagent dispatch (apex-spec-reviewer fan-out, council voices, apex-research parallel agents, donor-absorption passes) — ride the subscription pool. Dispatch freely; the split doesn't touch it. The DeepSeek coding side is off Anthropic billing entirely.
- The credit pool only bites if APEX is run **unattended**: `claude -p`, a scheduled/cron remote agent, a GitHub Action, or an autonomous `/loop`. Those are capped at $20–$200/mo and dispatch-heavy passes burn it fast at API rates.
- **Rule of thumb:** never run APEX headless on the Anthropic backend without budgeting the credit pool. Relevant when the parked autonomous/Mac-gated trials come off the list.

**Caveat:** Anthropic's docs never explicitly name "subagents spawned inside an interactive session." Interactive-pool is a strong inference from the interactive-vs-`claude -p` boundary, not a documented guarantee — confirm via usage observation or support if relying on it for a heavy parallel pass.
