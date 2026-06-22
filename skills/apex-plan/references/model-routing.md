# Model-routing build planning — full rubric

Loaded on demand when a project's `coder_models` menu is multi-model. SKILL.md carries the trigger,
the single-vs-multi branch, and the `## Wave plan` emit format; this file carries the per-task
selection rubric (ADR-024).

## Legacy `coder_tier_policy` mapping (when `coder_models` is absent)
flash→`[flash]` · pro→`[pro]` · split→`[flash, pro]`.

## Per-task selection (two steps, considering only models in the menu)

**Step 1 — eligibility filter (hard gates):** image input needed (mockup/screenshot/Figma) → drop
`flash`+`pro` (DeepSeek is text-only); output > ~64K expected → drop `sonnet`. Intersect with the menu.

**Step 2 — cheapest eligible model that clears the complexity bar.** Cost order: `flash < pro < sonnet
< opus`. Score the task's complexity (rubric below); pick the cheapest eligible model whose ceiling meets it.

**Complexity rubric (judgment, not a formula — read from the task's Files to Change):** logic novelty ·
blast radius / coupling · risk domain (security/auth/concurrency/crypto/transactions) · horizon (one
edit ↔ long agentic) · size · (brownfield) health of the touched files.

**Model ceilings:** `flash` = routine / short-horizon · `pro` = hard-kernel **text** (novel logic,
security/concurrency, big multi-file) · `sonnet` = **image** tasks of moderate complexity · `opus` =
**image** tasks that are complex / large-output / long-horizon. **`pro` is the proactive *text* ceiling**
— never proactively route a text task to `opus` (Pro is near-Opus at ~1/29 the cash and pool-neutral);
`opus` is reached for text **only** via build-time escalation on a Pro verify-fail (apex-code). For
**text**, `sonnet` is never chosen — `pro` dominates it on every axis.

## Wave plan emit format
Append `▸<model>` to each task and order so same-backend tasks are contiguous (DeepSeek batch, then
Claude batch) → ≤1 backend crossing/build:
`Wave 1: [task 1 ▸flash, task 2 ▸flash] | Wave 2: [task 3 ▸pro] | Wave 3: [task 4 ▸sonnet]`

## Splitting a feature across models
Split only when the boundary is a contract you can freeze + conformance-test (the stronger model commits
the interface, the cheaper builds against it; tests travel — ADR-019); diffuse / un-freezable → keep the
feature on one model.
