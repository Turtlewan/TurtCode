---
skill: apex-context-budget
version: 1.1.1
last_updated: 2026-07-29
sources:
  - ECC context-budget — github.com/affaan-m/ECC
  - donor-analysis (Kiro steering inclusion modes, GSD context tripwire, Cline focus-chain) — docs/research/donor-analysis/
staleness_threshold: 60d
description: >
  Use to audit or reduce Claude Code context/token overhead — "how much context am I
  using", "is my skill set too heavy", or before adding skills/agents/MCP. Analysis
  only; apex-skill-author trims.
---

# Context Budget — measure APEX's context-rot doctrine

APEX prevents context rot by design (lean loads, subagent fresh-context, durable artifacts).
This skill makes that **measurable**: estimate token overhead across everything that loads
into a session, classify it by how often it's actually needed, and return ranked savings.
Analysis only — it never edits a component (trimming is `apex-skill-author`'s job).

## When to run it

- Before adding a batch of skills / agents / MCP servers — "do I have headroom?"
- A periodic leanness review (the finalisation goal: keep APEX lean as it grows).
- Output quality degrades or a session feels heavy and you want the numbers, not a guess.

## The one thing a bare audit gets wrong: what *actually* loads

Token cost is **per loading-tier**, not per file-on-disk. Counting every `SKILL.md` +
`impl.md` byte as "overhead" over-counts the realized cost by 3–5×. Anchor every estimate to
**this table** — it is the core of the audit:

| Component | Loads when | What you pay |
|---|---|---|
| **CLAUDE.md chain** (global `~/.claude/CLAUDE.md` + project `CLAUDE.md`) | every turn, every session | full body — **always-on** |
| **Skill name + `description`** (the system-reminder list) | every session | one line per skill, **always-on** — the body is *not* loaded |
| **Skill `SKILL.md` body** | only when that skill is invoked (matched natively by its `description` — there is no keyword table) | full body, **on-invocation** |
| **`impl.md` body** | `apex-code` loads `apex-coding-principles/impl.md` at pre-flight. The repo's verify commands come from its `AGENTS.md`, not a skill (ADR-036/037). | per build run |
| **`references/*.md` tail** | only when a task matches the inline load-condition at the split point | conditional — usually **zero** |
| **Agent `description` frontmatter** | whenever the Agent tool is available (any session that can spawn) | one description per agent, folded into the Agent-tool schema — **always-on**. Bodies load only in the agent's *own* fresh context, never the main window. |
| **MCP tool schema** | always-on **unless deferred** by the harness | see § Heuristics — deferral changes the math |
| **Subagent (dispatched) work** | in the subagent's own ~200k context | **not** charged to the main window — this is the point of dispatch |

Two consequences a flat byte-count misses:
- A big `impl.md` is cheap if its bulk is in `references/*.md` and a long appendix; only the
  **core** is the recurring cost. Estimate the core, note the tail separately.
- **Agent `description`s and skill `description`s are an always-on tax** even for components
  never invoked. Bloated descriptions (>30 words) are pure overhead on every session.

## Heuristics — fix them so audits are repeatable

- **Prose:** `tokens ≈ words × 1.3`. **Code / dense markdown / tables:** `tokens ≈ chars / 4`
  (≈ `bytes / 4` for ASCII). State which you used.
- **MCP tool schema:** budget **~500 tokens per tool** (name + description + JSON input schema)
  when loaded. **But this harness defers most MCP tools** — a deferred tool costs only its
  *name* (~20–40 tok) until `ToolSearch` fetches the schema on demand. So realized MCP cost =
  `enumerated deferred names (cheap) + non-deferred/fetched schemas (~500 each)`. Always check
  the deferred-tools list before multiplying tool count × 500 — that's the #1 over-estimate.
- **Built-in tool schemas** (Read/Edit/Bash/Grep…) are a fixed harness cost (~3–4k); note it,
  don't try to optimize it.
- Measure bytes from disk (don't eyeball); compute, don't assert.

## The audit — four phases

### Phase 1 — Inventory
Walk the APEX surface and record bytes → tokens per the heuristics, tagged by loading-tier:
- **Skills** `~/.claude/skills/apex-*/SKILL.md` (+ `impl.md` **core** if it has one). Flag SKILL.md > 500 lines (the cap), impl.md core that's bloated.
- **Agents** `~/.claude/agents/apex-*.md` — count the **description** (always-on) separately from the body (latent). Flag description > 30 words; body > 200 lines.
- **CLAUDE.md chain** — global + project. Flag combined > 300 lines (always-on, every turn — highest-value line to cut).
- **MCP** — list servers + tool counts; separate deferred (name-only) from live (~500/tool).

### Phase 2 — Classify (do not skip — this is the deliverable a bare audit omits)
Sort **every** inventoried item into one bucket with an action:

| Bucket | Criteria (APEX-specific) | Action |
|---|---|---|
| **Always** | CLAUDE.md chain; skill/agent description lists; the orchestrator + active-mode skill; non-deferred MCP schemas | Keep — but trim fat (verbose descriptions, duplicated prose) |
| **Sometimes** | A specialist SKILL.md matched by this project's domains; an `impl.md` core for a bound stack skill | Fine on-demand; trim only if a recurring per-run cost |
| **Rarely** | Skills no project domain matches; `references/*.md` tails; agents never dispatched here | Leave latent (no always-on cost) or flag for lazy-load |

### Phase 3 — Detect issues
- **Always-on bloat:** CLAUDE.md prose duplicated in `apex-orchestrate`/`apex-code`; descriptions > 30 words; the same loop documented in three places.
- **MCP over-subscription:** live (non-deferred) tools unrelated to the workflow; servers wrapping a CLI that's free via Bash.
- **Latent context-bombs:** a single agent/skill body so large that one accidental invocation drops a 10k-token block — call it out even though it's latent.
- **Cap violations:** any `SKILL.md` > 500 lines.
- **Unconditional always-on docs/rules:** a rule or doc loaded every session that applies to only *some* tasks — a candidate for conditional/glob-gated loading (see § Two levers) rather than the always-on chain.

### Phase 4 — Report (template below)

## Scope discipline — audit APEX, don't prescribe deleting other systems

The APEX surface is `apex-*` skills/agents, the CLAUDE.md chain, and MCP
*relevance to the workflow*. **Co-installed third-party systems ARE in scope.** This rule used to
read "not APEX's to prune" — and that is exactly how 33 `gsd-*` agents survived, costing **14.5 KB of
always-on description weight, four times APEX's own**, while the skill built to find bloat was
forbidden from naming them as removable (deleted 2026-07-14). An always-on cost is an always-on cost
regardless of who installed it. Measure it, name it, and **recommend deletion** — the user decides,
but the recommendation is yours to make. Their bodies are latent (don't load unless invoked); only
their description lines tax every session.

## Report template

```
Context Budget Report — APEX
════════════════════════════════════════════

Estimation: prose words×1.3 / code chars÷4 / MCP ~500 tok per LIVE tool (deferred = name-only)

ALWAYS-ON FLOOR (every turn)            ~XX,XXX tok
┌──────────────────────────┬────────┬───────────┐
│ Component                │ Count  │ Tokens    │
├──────────────────────────┼────────┼───────────┤
│ CLAUDE.md chain          │ 2      │ ~X,XXX    │
│ Skill descriptions       │ N      │ ~X,XXX    │
│ Agent descriptions       │ N      │ ~X,XXX    │
│ MCP schemas (live)       │ N      │ ~X,XXX    │  ← deferred: M names, ~XXX tok
│ Built-in tools (fixed)   │ —      │ ~3–4k     │
└──────────────────────────┴────────┴───────────┘

LATENT LIBRARY (paid per invocation, not per turn)
  Skills ~XXX,XXX · impl cores ~XX,XXX · agent bodies ~XXX,XXX · refs ~XX,XXX

ISSUES (N), ranked by ALWAYS-ON impact:
  …

TOP 3 SAVINGS:
  1. [action] → save ~X,XXX tok always-on   [effort]
  2. [action] → save ~X,XXX tok             [effort]
  3. [action] → save ~X,XXX tok             [effort]

Headroom: always-on floor ≈ XX% of a 200k window.  Adding {planned components} → +~X,XXX tok.
```

Rank savings by **always-on** impact first (every-turn cost), latent second. Always force a
top-3 — the audit's value is the prioritized cut, not the spreadsheet.

## Two levers beyond trimming

Deleting content is not the only way to cut the always-on floor:

- **Conditional / glob-gated loading.** Not everything in the always-on chain must be always-on. Give
  a rule or doc a load condition — *always* / *file-match glob* / *manual* — so it loads only when a
  task touches its domain, moving cost from every-turn to on-demand **without deleting content**. Flag
  always-on items that apply to only *some* tasks as conditional-loading candidates. (Kiro steering
  inclusion modes; mirrors APEX's own impl.md core/references split.)
- **Live-context tripwire.** This audit is static (the per-turn floor). At *runtime*, when live
  context passes **~70%** of the window, recommend a deliberate `/compact` at the next phase boundary
  rather than waiting for mid-task auto-compaction — and keep the In-Flight task list re-injected so
  position survives. (GSD `health --context`; Cline focus-chain; pairs with apex-orchestrate
  § Strategic compaction.)

## Rules

- **NEVER** edit a component — this skill measures and recommends; trimming is `apex-skill-author`.
- **NEVER** multiply MCP tool-count × 500 without first subtracting the deferred (name-only) tools.
- **NEVER** count a whole `impl.md` as always-on cost — only its core sections load per run, and only for *bound* stack skills.
- **Co-installed non-APEX systems:** measure their always-on weight and recommend removal where
  warranted — the user decides (§ Scope discipline).
- **ALWAYS** separate the always-on floor from the latent library — they are different decisions.
- **ALWAYS** end with a forced top-3 ranked by always-on saving.
