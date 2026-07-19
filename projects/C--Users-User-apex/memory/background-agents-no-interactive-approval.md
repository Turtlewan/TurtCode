---
name: background-agents-no-interactive-approval
description: "Dispatched/background subagents run non-interactively — approval-gated tool calls (WebFetch on non-allowlisted domains, any off-list tool) auto-deny with no prompt; breaks apex-research's dispatched-retrieval model on novel web sources"
metadata: 
  node_type: memory
  type: project
  originSessionId: 74cce0c7-b8e8-4c58-94e7-af72d002caed
---

Background/dispatched subagents — `Agent`/`Task`, workflow workers, and apex-research's retrieval
agents — run **non-interactively**: no user is present to answer a permission prompt, so any tool
call that would require approval **auto-denies** for them (no prompt, the agent just "hits a wall").
Same root cause as the dontAsk SPOF findings ([[classifier-gates-protected-path-edits]],
[[dontask-probe-cleanup-paradox]]): anything a background agent needs must be in `permissions.allow`;
off-list = silent deny.

Verified live 2026-06-21 (planning/Anthropic): `WebSearch` is globally allow-listed (so snippet
search survives in a dispatched agent), but `WebFetch` is allow-listed **per-domain** (~30 fixed
domains in the project `.claude/settings.local.json`). A research agent fetching any **novel** domain
not on that list needs approval → auto-deny.

**Why:** apex-research (since v1.3.0) dispatches retrieval to background Sonnet/Haiku agents — exactly
the agents that cannot approve a novel `WebFetch` domain. Open-web research therefore silently loses
un-allowlisted sources; the dispatched retrieve phase is the affected mechanism, not planning/synthesis.

**How to apply:** for web research that hits unpredictable domains, either (a) do the deep `WebFetch`
in the **main interactive agent** (it can surface the approval) and have dispatched agents return
"needs domain X" rather than fetch it themselves; or (b) pre-authorise the expected domains in settings
before dispatching. `WebSearch` (snippets) works dispatched; deep `WebFetch` on novel domains does not.
Re-verify live before relying on this — allow-lists and permission modes change ([[verify-env-claims-live]]).
