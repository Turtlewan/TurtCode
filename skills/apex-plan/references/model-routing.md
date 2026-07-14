# Model-routing build planning — full rubric

Loaded on demand when a project's `coder_models` menu has >1 entry. Under ADR-027 the menu is
`{codex, opus}` and routing **collapses**: Codex is the default coder for every task; Opus is reached
only as the **manual fallback** when Codex quota is exhausted. There is no per-task cost/complexity
routing — both coders are frontier-class and Opus is not a proactive choice.

## Legacy `coder_tier_policy` / DeepSeek tiers — ARCHIVED (ADR-027)
The old DeepSeek Flash/Pro tiers and the `flash < pro < codex` cost-routing are archived (recoverable,
not in the active menu). If an old project still carries `coder_tier_policy`, treat it as `[codex]`.

## Host-direct build — when the planning host builds the queue itself (ADR-035)

The host may build a spec queue **itself** (own `Write`/`Edit`, in sequence) instead of dispatching
`codex exec`. Legal, but **narrow: it must win on a structural argument, never on convenience — when
both paths are viable, the tie goes to dispatch.** Requires ALL of:

- **Not dispatchable as one `codex exec`.** `codex exec -C <root>` takes a **single root**, so a task
  spanning `~/.claude` **and** `~/apex` cannot be one dispatch. This is the strongest — often the only
  honest — reason to build host-direct.
- **No verification recipe for a coder to iterate against** (APEX is markdown; "verify" is a grep + line
  count). Dispatch's value is the coder self-verifying to green *without host tokens*; with nothing to
  iterate on you pay the overhead and still verify yourself.
- **Judgment-dense, not mechanical.** Formulaic edits ("apply convention X across N files") are exactly
  what the plentiful pool is for — dispatch them even inside APEX.
- **Under the ceiling: ~2–3 specs / ~10–20 *substantial* writes.** Count substantial writes, not files —
  a 24-file run of one-line pin swaps is well inside it. **Re-check at the halfway point**; over the
  ceiling → commit what's done and fork the remainder to Codex.

Fail any one → **dispatch**.

**Two gotchas the reasoning won't supply:**
- The planning write-guard **exempts APEX + `~/.claude` only**. Every other repo prompts per non-`.md`
  edit — so host-direct outside those two is a prompt-per-edit slog regardless of how the reasoning
  above scores. Run the build in coding mode (`apex-build`) instead.
- **The B1 scope hole is live** (`apex:docs/findings/artemis-13-7-issues.md`): a dispatched Codex can
  write outside its authorized file list with nothing stopping it. Until the post-dispatch diff check
  lands, dispatch carries a risk host-direct does not. Expected to expire.

**Distrust the preference.** The host feels dispatch's costs (handoff, supervision, integration) and is
blind to host-direct's (pool depletion, context decay — never experienced). Host-direct also spends the
*scarce* pool to save the *plentiful* one, and collapses author and reviewer into one context. Any
host-direct argument that reduces to "it's smoother" is that bias, and is rejected. Degradation is
**silent** — "it feels fine" and "it worked last time" are not evidence.

## Per-task selection — collapses to a default + manual fallback
- **Default: `codex`** for every task — text and image alike (gpt-5.6-sol is sighted, so the old image gate
  is moot). No cost-tier decision; do not route proactively to Opus.
- **Fallback: `opus`**, reached only when Codex quota runs out mid-build (operator-confirmed) — apex-code's
  Opus `APEX_MODE=coding` host builds the task inline. This is a build-time event, not a planning-time
  per-task route. See apex-code § Model fallback on verify-fail or quota-out.
- A whole-spec `coder_model: opus` frontmatter can pin a spec to Opus up front (e.g. when you already
  know Codex quota is gone) — bypasses Codex entirely.

## Reasoning-effort dial — the one real per-task lever (ADR-030)
Model choice collapsed, but Codex's **reasoning-effort dial** is a genuine per-spec cost/quality lever on
the *same* `gpt-5.6-sol`. Set it with spec frontmatter `coder_effort: {low|medium|high|xhigh|max|ultra}`
(apex-code passes `-c model_reasoning_effort=<v>` to every `codex exec`). Default `medium` — leave it
absent unless the spec is clearly off-default.
- `low` — trivial mechanical specs (rename, config, boilerplate, docstrings): cheaper + faster.
- `medium` — default; most specs.
- `high` — `risk: high`, auth / security / data / concurrency, or algorithmically hard specs.
- `xhigh` — explicit opt-in for the hardest async / eval-like work only.
- `max` — reserve for the single hardest tasks a spec can carry: state migrations, IAM/auth-critical
  work, gnarly concurrency. Sits above `xhigh`; also the second-highest rung of apex-code's verify-fail
  recovery ladder.
- `ultra` — above `max`, and the **final** rung of that ladder before the Opus fallback (ADR-034; there is
  no higher Codex model to escalate to now that `gpt-5.6-sol` is the coder). Spawns in-model subagents, so
  it counts **double** against `max_parallel_codex` (ADR-028) — or keep `ultra` tasks sequential/foreground
  instead of folding them into a parallel wave. Gated on a pending head-to-head eval against `max` that
  hasn't run yet — **do not select it at spec-authoring time**; let the ladder reach it, or treat a
  deliberate opt-in as a logged escalation.

Cheap to dial up: under config-A the build runs on Codex's **separate pool**, so `high` on a hard spec
barely touches the scarce Opus pool. Don't blanket-`high` everything — it burns Codex quota faster (→
earlier Opus fallback). Effort is per-spec; apex-code additionally bumps it one notch on a Codex
verify-fail retry, up through the final `ultra` rung (ADR-034), before any Opus fallback (build-time, not a planning choice). The `gpt-5.4-mini` cheap
model is **deferred** (ADR-030) — do not route tasks to a second model; the dial is the cost lever.

## Family-aware review routing (when `cross_model_review: true`)
Reviewer family ≠ builder family:
- Codex-built task (the default) → **Claude** reviews — Sonnet routine, `model: opus` for the high-risk dual-pass set (ADR-032).
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
