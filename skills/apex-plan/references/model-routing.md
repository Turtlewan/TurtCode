# Model-routing build planning — full rubric

Loaded on demand when a project's `coder_models` menu has >1 entry. Under ADR-027 the menu is
`{codex, opus}` and routing **collapses**: Codex is the default coder for every task; Opus is reached
only as the **manual fallback** when Codex quota is exhausted. There is no per-task cost/complexity
routing — both coders are frontier-class and Opus is not a proactive choice.

## Legacy `coder_tier_policy` / DeepSeek tiers — ARCHIVED (ADR-027)
The old DeepSeek Flash/Pro tiers and the `flash < pro < codex` cost-routing are archived (recoverable,
not in the active menu). If an old project still carries `coder_tier_policy`, treat it as `[codex]`.

## Per-task selection — collapses to a default + manual fallback
- **Default: `codex`** for every task — text and image alike (gpt-5.5 is sighted, so the old image gate
  is moot). No cost-tier decision; do not route proactively to Opus.
- **Fallback: `opus`**, reached only when Codex quota runs out mid-build (operator-confirmed) — apex-code's
  Opus `APEX_MODE=coding` host builds the task inline. This is a build-time event, not a planning-time
  per-task route. See apex-code § Model fallback on verify-fail or quota-out.
- A whole-spec `coder_model: opus` frontmatter can pin a spec to Opus up front (e.g. when you already
  know Codex quota is gone) — bypasses Codex entirely.

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
