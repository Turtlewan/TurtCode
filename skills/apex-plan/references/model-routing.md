# Model-routing build planning — full rubric

Loaded on demand when a project's `coder_models` menu has >1 entry. Under ADR-027 the menu is
`{codex, opus}` and routing **collapses**: Codex is the default coder for every task; Opus is reached
only as the **manual fallback** when Codex quota is exhausted. There is no per-task cost/complexity
routing — both coders are frontier-class and Opus is not a proactive choice.

## Legacy `coder_tier_policy` / DeepSeek tiers — ARCHIVED (ADR-027)
The old DeepSeek Flash/Pro tiers and the `flash < pro < codex` cost-routing are archived (recoverable,
not in the active menu). If an old project still carries `coder_tier_policy`, treat it as `[codex]`.

## Per-task selection — collapses to a default + manual fallback
- **Default: `codex`** for every task — text and image alike (gpt-5.6-terra is sighted, so the old image gate
  is moot). No cost-tier decision; do not route proactively to Opus.
- **Fallback: `opus`**, reached only when Codex quota runs out mid-build (operator-confirmed) — apex-code's
  Opus `APEX_MODE=coding` host builds the task inline. This is a build-time event, not a planning-time
  per-task route. See apex-code § Model fallback on verify-fail or quota-out.
- A whole-spec `coder_model: opus` frontmatter can pin a spec to Opus up front (e.g. when you already
  know Codex quota is gone) — bypasses Codex entirely.

## Reasoning-effort dial — the one real per-task lever (ADR-030)
Model choice collapsed, but Codex's **reasoning-effort dial** is a genuine per-spec cost/quality lever on
the *same* `gpt-5.6-terra`. Set it with spec frontmatter `coder_effort: {low|medium|high|xhigh}` (apex-code
passes `-c model_reasoning_effort=<v>` to every `codex exec`). Default `medium` — leave it absent unless
the spec is clearly off-default.
- `low` — trivial mechanical specs (rename, config, boilerplate, docstrings): cheaper + faster.
- `medium` — default; most specs.
- `high` — `risk: high`, auth / security / data / concurrency, or algorithmically hard specs.
- `xhigh` — explicit opt-in for the hardest async / eval-like work only.

Cheap to dial up: under config-A the build runs on Codex's **separate pool**, so `high` on a hard spec
barely touches the scarce Opus pool. Don't blanket-`high` everything — it burns Codex quota faster (→
earlier Opus fallback). Effort is per-spec; apex-code additionally bumps it one notch on a Codex
verify-fail retry before any model fallback (build-time, not a planning choice). The `gpt-5.4-mini` cheap
model is **deferred** (ADR-030) — do not route tasks to a second model; the dial is the cost lever.

## Family-aware review routing (when `cross_model_review: true`)
Reviewer family ≠ builder family:
- Codex-built task (the default) → **Opus** (Claude) reviews.
- Opus-built task (the fallback) → **Codex** reviews (`codex exec`) — but Opus builds only because Codex
  quota is out, so this usually degrades to single-model + human flag (apex-governance § Cross-model review).

Preserves evaluator-independence — no task reviewed by its own family. apex-code derives the reviewer
from the builder at review time.

## Wave plan emit format
With a single proactive coder, emit the normal **untagged** `## Wave plan` (every task → Codex). Do not
tag `▸opus` proactively — the Opus fallback is a session-level manual switch, not a per-task tag.

## Splitting a feature across models
Largely moot with one proactive coder. If a Codex build must hand a frozen-contract slice to Opus (or
vice-versa during fallback), split only when the boundary is a contract you can freeze + conformance-test
(tests travel); diffuse / un-freezable → keep the feature on one coder.
