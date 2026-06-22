# Model-routing build planning — full rubric

Loaded on demand when a project's `coder_models` menu is multi-model. SKILL.md carries the trigger,
the single-vs-multi branch, and the `## Wave plan` emit format; this file carries the per-task
selection rubric (ADR-024).

## Legacy `coder_tier_policy` mapping (when `coder_models` is absent)
flash→`[flash]` · pro→`[pro]` · split→`[flash, pro]`.

## Per-task selection (two steps, considering only models in the menu)

**Step 1 — eligibility filter (hard gates):** image input needed (mockup/screenshot/Figma) → drop
`flash`+`pro` (DeepSeek is text-only); only `codex` (gpt-5.5, sighted) is image-eligible. Intersect with the menu.

**Step 2 — cheapest eligible model that clears the complexity bar.** Cost order: `flash < pro < codex`.
Score the task's complexity (rubric below); pick the cheapest eligible model whose ceiling meets it.

**Complexity rubric (judgment, not a formula — read from the task's Files to Change):** logic novelty ·
blast radius / coupling · risk domain (security/auth/concurrency/crypto/transactions) · horizon (one
edit ↔ long agentic) · size · (brownfield) health of the touched files.

**Model ceilings:** `flash` = routine / short-horizon · `pro` = hard-kernel **text** (novel logic,
security/concurrency, big multi-file) · `codex` = **all image/visual** work **and** the **hard-text
ceiling above `pro`**. **`pro` is the proactive *text* ceiling** — for text, route proactively no higher
than `pro`; `codex` is reached for text **only** via build-time escalation on a `pro` verify-fail
(apex-code § Model escalation). Route to `codex` **proactively** for **image** tasks (it is the only
sighted coder in the menu). The retired `sonnet`/`opus` coder tiers fold into `codex`.

> Codex runs as a `codex exec` subprocess from the build session (its own OpenAI pool, no backend swap,
> no session restart) — so a `▸codex` task adds none of the cross-backend cost `opus`/`sonnet` once did.

## Family-aware review routing (when `cross_model_review: true` — ADR-026)
The independent reviewer family is **derived from each task's builder — reviewer family ≠ builder family**:
- DeepSeek-built task (`▸flash`/`▸pro`) → **Codex** reviews (`codex exec`).
- Codex-built task (`▸codex`) → **Opus** (Claude) reviews.
This preserves evaluator-independence (apex-governance § Evaluator independence) — no task is reviewed
by its own family. apex-code derives the reviewer from the `▸` tag at review time.

## Wave plan emit format
Append `▸<model>` to each task and order so same-backend DeepSeek tasks are contiguous (one DeepSeek
batch); `▸codex` tasks apex-code runs via `codex exec` (sequential subprocess, no session):
`Wave 1: [task 1 ▸flash, task 2 ▸flash] | Wave 2: [task 3 ▸pro] | Wave 3: [task 4 ▸codex]`

## Splitting a feature across models
Split only when the boundary is a contract you can freeze + conformance-test (the stronger model commits
the interface, the cheaper builds against it; tests travel — ADR-019); diffuse / un-freezable → keep the
feature on one model.
