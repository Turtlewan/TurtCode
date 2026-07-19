---
name: review-ensemble-design-parked
description: Hybrid Codex+Claude multi-lens review-harness design parked for later deep-dive
metadata: 
  node_type: memory
  type: reference
  originSessionId: 44140540-3392-4b67-b96e-b7ab1adf50ea
---

A design for augmenting APEX's review process — a **hybrid Codex+Claude multi-lens ensemble** that approximates "ultra" review WITHOUT the (Team/Enterprise-only) cloud Code Review and mostly OFF the Max pool — is parked at `~/.claude/skills/apex-code/REVIEW-ENSEMBLE-DESIGN.md` (authored 2026-06-28).

Core idea: Tier-1 breadth = N parallel `codex exec --sandbox read-only --output-schema` reviewers, one per lens (security/concurrency/data-integrity/correctness/privacy) on the Codex pool; Tier-2 = a bounded Opus adjudication of the union (judge, not grunt); Tier-3 = the existing both-raise/one-raise triage. Hybrid beats either alone via model-family diversity, with Claude spent surgically to protect the Max pool.

The same file holds the **Artemis deep-review backlog** (two surveys, 2026-06-28): dominant theme = concurrency/race correctness in the always-on background + auth (P0: auth counter-monotonicity race, tier1_queue, memory bitemporal writes, staging state-machine). NONE of the built corpus has had an ultra-grade review yet.

Recall when: discussing review-process augmentation, "should we ultra-review X", or doing the deep concurrency audit. Relates to [[agency-proactivity-scope-locked]] (brain reactive-dispatch P2 ties to the deferred GATE).
(migrated from Artemis memory 2026-07-19)
