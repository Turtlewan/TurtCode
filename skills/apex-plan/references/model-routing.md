# Model-routing build planning — full rubric

**Pin every Claude-side dispatch.** The session model is Fable 5 (expensive) — an `Agent`/`Task`
dispatch that omits `model:` silently inherits it, not the cheap default, so always pass `model:`
explicitly. Never route mechanical work through a `fork`-type subagent — forks always inherit the
session model regardless of any pin.

Loaded on demand when a build could take more than one coder — i.e. before setting a spec's
`coder_model` frontmatter, or at a quota-out fallback decision. Under ADR-027 as amended (A1,
session-79b; ADR-045) the menu is `{codex, sonnet}` and routing **collapses**: Codex is the default
coder for every task; **Sonnet 5** is reached only through the three fallback triggers
(quota-out/unavailable · whole-spec `coder_model: sonnet` pin · terminal verify-failure routing by
the executor). There is no per-task cost/complexity routing, and the fallback is not a proactive
choice. Opus keeps the spec-author, build-orchestrator, and high-risk-reviewer roles — it is not a
coder.

## Legacy `coder_tier_policy` / DeepSeek tiers — ARCHIVED (ADR-027)
The old DeepSeek Flash/Pro tiers and the `flash < pro < codex` cost-routing are archived (recoverable,
not in the active menu). If an old project still carries `coder_tier_policy`, treat it as `[codex]`.

## Host-direct build — SUPERSEDED by ADR-045 (kept as background)

> **ADR-045 (2026-07-16 split) retires host-direct build.** The host reasons/plans/challenges only;
> it makes no mechanical edits and writes no code — all build work dispatches to a coder or worker.
> The reasoning below is why (context decay, scarce-pool depletion, the self-serving bias); it no
> longer describes a path the host may take.

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
- Outside APEX / `~/.claude`, edits to non-allow-listed paths prompt for permission (there is no
  write-guard any more — ADR-038 — but the ordinary permission system still gates writes outside the
  `permissions.allow` set). Arm AFK autonomy (`acceptEdits` + `permissions.allow`) so an unattended
  run doesn't stall on prompts, or dispatch.
- The B1 scope hole is **closed**: the post-dispatch scope check (`codex-scope-check`, exit-65;
  ADR-041/044) now blocks a dispatched Codex from writing outside its authorized file list. Dispatch
  no longer carries the extra risk this note once flagged.

**Distrust the preference.** The host feels dispatch's costs (handoff, supervision, integration) and is
blind to host-direct's (pool depletion, context decay — never experienced). Host-direct also spends the
*scarce* pool to save the *plentiful* one, and collapses author and reviewer into one context. Any
host-direct argument that reduces to "it's smoother" is that bias, and is rejected. Degradation is
**silent** — "it feels fine" and "it worked last time" are not evidence.

## Per-task selection — collapses to a default + manual fallback

The Claude fallback (Sonnet 5) fires on exactly three triggers: (1) Codex quota-out or unavailability; (2) a whole-spec `coder_model: sonnet` pin; (3) terminal verify-failure routing by the executor (the orchestrator, or the host as interim executor). Nothing else reaches it.

- **Default: `codex`** for every task — text and image alike (gpt-5.6-sol is sighted, so the old image gate
  is moot). No cost-tier decision; do not route proactively to the Claude fallback.
- **Fallback: `sonnet` (Sonnet 5 — A1, session-79b)** — apex-code builds the task inline as a fresh
  `model: sonnet` worker in this session. This is a build-time event, not a planning-time per-task
  route. See apex-code § Model fallback on verify-fail or quota-out.
- A whole-spec `coder_model: sonnet` frontmatter can pin a spec to the Claude fallback up front
  (e.g. when you already know Codex quota is gone) — bypasses Codex entirely. The enum is exactly
  `{codex|sonnet}`; there is no `opus` value.

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
- `ultra` — above `max`, and the **final** rung of that ladder before the Claude fallback (Sonnet 5) (ADR-034; there is
  no higher Codex model to escalate to now that `gpt-5.6-sol` is the coder). Spawns in-model subagents, so
  it counts **double** against `max_parallel_codex` (ADR-028) — or keep `ultra` tasks sequential/foreground
  instead of folding them into a parallel wave. Gated on a pending head-to-head eval against `max` that
  hasn't run yet — **do not select it at spec-authoring time**; let the ladder reach it, or treat a
  deliberate opt-in as a logged escalation.

Cheap to dial up: under config-A the build runs on Codex's **separate pool**, so `high` on a hard spec
barely touches the scarce Anthropic Max pool. Don't blanket-`high` everything — it burns Codex quota faster (→
earlier Claude fallback). Effort is per-spec; apex-code additionally bumps it one notch on a Codex
verify-fail retry, up through the final `ultra` rung (ADR-034), before any Claude fallback (build-time, not a planning choice). The `gpt-5.4-mini` cheap
model is **deferred** (ADR-030) — do not route tasks to a second model; the dial is the cost lever.

## Family-aware review routing (when `cross_model_review: true`)
Reviewer family ≠ builder family:
- Codex-built task (the default) → **Claude** reviews — Sonnet routine, `model: opus` for the high-risk dual-pass set (ADR-032).
- Claude-fallback-built task (Sonnet 5) → **Codex** reviews (`codex exec`) — but the fallback most
  commonly fires on quota-out (one of the three triggers), so this usually degrades to single-model
  + human flag (apex-governance § Cross-model review).

Preserves evaluator-independence — no task reviewed by its own family. apex-code derives the reviewer
from the builder at review time.

## Wave plan emit format
With a single proactive coder, emit the normal **untagged** `## Wave plan` (every task → Codex). Do not
tag `▸sonnet` proactively — the Claude fallback is a session-level manual switch, not a per-task tag.

## Splitting a feature across models
Largely moot with one proactive coder. If a Codex build must hand a frozen-contract slice to the
Claude fallback coder (or vice-versa), split only when the boundary is a contract you can freeze + conformance-test
(tests travel); diffuse / un-freezable → keep the feature on one coder.

## Coder-model tripwire (2026-07-29)
Sol stays the sole coder. Re-open the Terra question only on measured Codex quota pressure — a quota-out
fallback firing, or weekly Codex limits being hit. Then run the parked A3 bakeoff (~10 routine specs,
Terra vs Sol, verified-completions-per-dollar); if Terra wins routine work it returns as a cheap worker
tier (A4), never as the default (ADR-034).
