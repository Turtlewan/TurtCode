---
skill: apex-context-budget
backend: claude
version: 1.0.0
last_updated: 2026-06-02
sources:
  - ECC context-budget — github.com/affaan-m/ECC
staleness_threshold: 60d
description: >
  Use when auditing or reducing this setup's Claude Code context/token overhead —
  "how much context am I using", "is my skill set too heavy", "do I have headroom to
  add more skills/agents/MCP servers", a leanness review, or before adding a batch of
  components. Planning-mode analysis only: inventories what *actually* loads (the
  CLAUDE.md chain, matched skills, impl.md cores, agent descriptions, MCP schemas),
  classifies each as Always/Sometimes/Rarely, and produces ranked token-savings with a
  forced top-3. Not a coding task; not general latency/perf tuning (that's apex-performance);
  not the act of trimming a skill (that's apex-skill-author).
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
| **Skill `SKILL.md` body** | only when that skill is invoked (planning loads the *matched* specialist via keyword + `specialists_default`) | full body, **on-invocation** |
| **`impl.md` body** | coding mode (`apex-code`) loads **only the core sections** of each *bound* `stack_skills` entry — frontmatter + `## Stack assumptions` + `## NEVER`/`## ALWAYS` + `## Verification Recipe` + the compact errors table (SP6 two-tier). The rest of `impl.md` does **not** load. | **core sections only**, per build run |
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
- **Registry** `~/.claude/registry/*.md` — on-demand (orchestrator reads it); usually small.
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

### Phase 4 — Report (template below)

## Scope discipline — audit APEX, don't prescribe deleting other systems

The APEX surface is `apex-*` skills/agents, the registry, the CLAUDE.md chain, and MCP
*relevance to the planning/coding workflow*. Co-installed third-party systems (e.g. `gsd-*`,
`superpowers`, design kits) share `~/.claude` but are **not APEX's to prune**. Report their
**always-on description weight** as a single informational line and flag it for the user to
decide — never recommend removing another system as if it were APEX overhead. Their bodies are
latent (don't load unless invoked); only their description lines tax every session.

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

## Rules

- **NEVER** edit a component — this skill measures and recommends; trimming is `apex-skill-author`.
- **NEVER** multiply MCP tool-count × 500 without first subtracting the deferred (name-only) tools.
- **NEVER** count a whole `impl.md` as always-on cost — only its core sections load per run, and only for *bound* stack skills.
- **NEVER** recommend deleting a co-installed non-APEX system; report it as informational.
- **ALWAYS** separate the always-on floor from the latent library — they are different decisions.
- **ALWAYS** end with a forced top-3 ranked by always-on saving.
