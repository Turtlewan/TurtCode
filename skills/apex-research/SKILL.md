---
skill: apex-research
backend: claude
version: 1.4.1
last_updated: 2026-06-22
sources:
  - Context7 MCP — context7.com
  - APEX memory — background-agents-no-interactive-approval
staleness_threshold: 30d
description: >
  Use when researching before a decision — comparing tools/options, verifying current best
  practice, or studying external repos/systems to absorb. Triggers: "research X", "compare A vs
  B", "is this still current", "study repo Y", absorption/compare-and-absorb passes. Spawns
  source-grounded parallel agents and synthesises with confidence + token-cost tags. Not the
  decision/spec itself (apex-plan) or an uncertain-approach deep dive (apex-deep-dive).
---

# Deep Research Specialist — Planning Mode

Single-file, planning-only skill. Research is judgment work — it lives in planning
mode (Claude can spawn agents and weigh sources). There is no `impl.md`.

## When to activate

Any time you need to research a topic deeply before planning or building:
- "Research X before I decide"
- "What's the best approach for Y in 2025/2026?"
- "Find me the current best practices for Z"
- "Compare options A vs B vs C"
- "Look up how [library/API/service] works"
- Any fast-moving ecosystem where training data is likely stale

## Questions to ask before researching

A capable model already produces structured, confident-looking output on its own —
so the failure mode is not *bad writing*, it's **researching the wrong thing well**.
Resolve scope before spawning anything:

1. **Scope & target** — the exact thing to research? (e.g. "Claude Code skills"
   vs "agent skills in general"). Narrow or broad? When unclear, ask — don't assume.
2. **Decision at stake** — what will this research decide? Drives depth, and whether
   the output is an ADR (permanent decision) or just findings.
3. **Freshness** — is this an area where training knowledge is likely stale? Sets the
   re-research threshold and how hard to push for primary sources.
4. **Output destination** — feeding one spec (inline), reusable (`docs/research/`), or
   a permanent decision (ADR)? See *Where research output goes* below.

If any of these are unclear, stop and ask. A full research-agent run on the wrong
scope is the most expensive mistake here.

## The three-phase model contract — hard rule

Research runs in three phases with a **fixed model per phase**. The expensive reasoning model
never performs mechanical retrieval — that is the token-optimisation that makes this *hard*, not
a default.

| Phase | Model | Does | Never does |
|-------|-------|------|------------|
| **1 · Plan** | Opus/Fable — the planning context itself (no dispatch) | Decompose the question into retrieval tasks: what to fetch, which source tier, how to split across agents, what each must return; **pre-authorise the source domains** the agents will fetch (§ Web access under dispatch) | Mechanical retrieval (fetch/extract) |
| **2 · Retrieve** | **Sonnet** dispatched agents (drop to **Haiku** for wide, shallow, low-stakes fan-out) | Fetch + extract + cite from the source tiers below; tag each finding's tier | Form the cross-source comparison or final recommendation |
| **3 · Synthesise** | Opus/Fable — back in the planning context | All reasoning: dedup across agents, confidence-weight, compare, recommend | — |

**Why hard, not a default:** if the planning model fetches inline, the bulky raw content (full
pages/docs) lands in the *expensive* context. Dispatched retrieval keeps the bulk in the *cheap*
context and returns only a distilled, cited pointer (the ADR-015 return contract). This holds even
for a **single lookup** — there is no "just fetch it myself" escape hatch.

**Phase 2 return contract (every retrieval agent):** write any bulky raw capture to disk; return a
compact, **cite-or-drop** result — each finding tagged with its source tier (below) + URL. Agents
return cited findings (and at most a *per-source* preliminary tag); the cross-source dedup, weighing,
and final recommendation are **Phase 3 only**. If a needed source is on an un-authorised domain, return
`NEEDS-DOMAIN: <host>` rather than an empty result (§ Web access under dispatch) — never silent-drop it.

Set the model explicitly on dispatch: `Agent(model: "sonnet", …)` / `Agent(model: "haiku", …)`.
Phases 1 and 3 need no override — they *are* the planning context.

### Web access under dispatch — the non-interactive wall

Phase-2 agents run **non-interactively** (background dispatch), so a `WebFetch` to a domain **not in
`permissions.allow` auto-denies** — there is no prompt for a background agent to answer
([[background-agents-no-interactive-approval]]). `WebSearch` is allow-listed and works dispatched;
`WebFetch` is gated **per-domain**. Open research hits *novel* domains, so the retrieve phase silently
loses sources unless you clear the gate **first**.

Resolve it **without breaking the model contract — the planning model authorises, it never fetches:**

1. **Phase 1 pre-authorises (control, not retrieval).** When the plan names its source domains (a docs
   site, a repo host, arxiv, a comparison target), add each to `permissions.allow` as
   `WebFetch(domain:<host>)` *before* dispatch. Editing the allow-list is a permission action, **not**
   mechanical retrieval — it stays with the planning context and does **not** violate the contract.
2. **Discovery-first for unknown domains.** Where sources aren't known upfront, dispatch a `WebSearch`
   sweep first (allow-listed → works dispatched); the agent returns candidate **URLs**, the planning
   context authorises their domains, then re-dispatches the **fetch** to the cheap tier.
3. **Agents flag, never fail silently.** A Phase-2 agent that needs an un-authorised domain returns
   `NEEDS-DOMAIN: <host>` in its result (an extension of cite-or-drop) instead of returning empty — so
   the planning context can authorise it and re-dispatch, rather than the source just vanishing.

## Research strategy — tiered by source quality

Confidence is **derived from the tier**, not asserted. Tier 1 → `[VERIFIED]`;
Tier 2 / community → `[COMMUNITY]`; unverified training knowledge → `[ASSUMED]`.

### Tier 1: Official documentation (highest confidence)
Context7 MCP for libraries, frameworks, SDKs, CLIs:
```
mcp__plugin_context7_context7__resolve-library-id: { libraryName: "react" }
mcp__plugin_context7_context7__query-docs: { context7CompatibleLibraryID: "/facebook/react", topic: "hooks" }
```
Use for: API syntax, configuration, version migration, library-specific patterns.

### Tier 2: Web search (current state, trends, comparisons)
WebSearch for recent developments, community consensus, tool comparisons:
```
WebSearch: "best practices [topic] 2026 site:reddit.com OR site:dev.to OR news.ycombinator.com"
WebSearch: "[library] vs [library] 2026 comparison"
```

### Tier 3: Primary sources (official sites, GitHub, specs, papers)
WebFetch for official docs not in Context7, GitHub READMEs, specifications:
```
WebFetch: "https://docs.official-site.com/getting-started"
WebFetch: "https://github.com/org/repo/blob/main/README.md"
```

## Confidence tagging — mandatory, per claim

Every claim carries a tag. Doc-level confidence is not enough — a fluent model writes
unverified assumptions as confident prose, so each individual finding gets:
- `[VERIFIED]` — confirmed from a Tier 1 / primary source
- `[COMMUNITY]` — from Reddit, StackOverflow, blogs, practitioner reports
- `[ASSUMED]` — training knowledge, not verified this session

Never present `[ASSUMED]` as fact.

## Research output format

One canonical template (whether inline or a file):

```markdown
# Research: [Topic]
**Date:** YYYY-MM-DD
**Confidence:** HIGH (primary sources) | MEDIUM (community) | LOW (assumed)
**Re-research after:** [date — per the staleness table below]

## Summary
2-3 sentences: what you found and what you recommend.

## Key findings
- [Finding] [VERIFIED — source: url]
- [Finding] [COMMUNITY — source: thread]
- [Finding] [ASSUMED — not verified this session]

## Options comparison (if applicable)
| Option | Pros | Cons | Best for |
|--------|------|------|----------|

## Recommended approach
**Use [X]** because [rationale]. Concretely: [implementation guidance].

## Code examples / patterns
[Copy-paste ready snippets]

## Assumptions / gaps
[What couldn't be verified; what needs hands-on validation]

## Sources
- [Name] — [url or Context7 library ID]
```

## Where research output goes — hand-off to planning

The model will dump findings into chat unless told otherwise. Route the output:

| Output | When | Path |
|--------|------|------|
| **Inline into the spec** | Research serves one specific spec being written | the spec in `docs/changes/` |
| **`docs/research/<topic>.md`** | Substantive and reusable beyond one spec | `docs/research/` |
| **ADR** | Research settles a permanent architecture decision | `docs/technical/adr/ADR-NNN-short-title.md` |
| **Ephemeral** | Trivial lookup, no lasting value | chat only, no file |

Default: **inline** when serving a single spec; **promote to `docs/research/`** the moment
it's reusable. Never leave substantive research as an orphaned chat message.

### ADR output format
When research settles a permanent decision:

```markdown
# ADR-NNN: [Decision title]
**Date:** YYYY-MM-DD
**Status:** Accepted

## Context
[Problem and why a decision was needed]

## Options considered
| Option | Score | Reasoning |
|--------|-------|-----------|

## Decision
Use **[X]** because [rationale].

## Consequences
- Positive: [benefits]
- Negative: [tradeoffs accepted]
- Risks: [what could go wrong]

## Sources
- [source]
```

## Spawning parallel research agents

These are **Phase-2 retrieval agents** — dispatch with `model: "sonnet"` (or `"haiku"` for wide,
low-stakes fan-out). They return cited findings, not recommendations; you synthesise in Phase 3.

For multiple independent topics (e.g. comparing 3 tools), spawn one agent per topic:
```
Agent 1: Research Tool A — setup, performance, community, known issues
Agent 2: Research Tool B — same focus areas
Agent 3: Research Tool C — same focus areas
→ synthesise into one comparison table, score, recommend
```
Use `run_in_background: true` per agent, then synthesise together. Never spawn
overlapping agents — redundant research wastes runs.

### External-repo / absorption ("compare-and-absorb") passes

Studying real repos to decide what to adopt has two recurring failure modes — agents skipping
the source (confabulating stars/versions from web/training) and prompt-variance across
hand-written agents. Follow this recipe; use the per-agent prompt template in
**`references/external-repo-study-template.md`** (read it before dispatching such a pass):

1. **Scale to stakes.** Full parallel-clone ceremony only when results drive a real decision
   (an ADR or skill edit). A quick "what's in repo X?" is one agent, or inline.
2. **One agent per repo/facet, never overlapping. Fill the template — do NOT hand-roll
   divergent prompts.** Prompt variance is the root failure: a hedged "clone if helpful" in
   one prompt is the off-ramp a cheap model takes.
3. **Source-grounding is mandatory** (baked into the template): resolve URL first → `git clone`
   (required, not optional) → cite-or-drop → identity = URL + SHA + license-from-file.
4. **Model tier — per the three-phase contract:** gather agents are **Sonnet** (**Haiku** for wide
   low-stakes fan-out); synthesis is always the planning context (Opus/Fable). There is **no
   Opus-gather path** — a single-agent study still gathers on Sonnet and synthesises in main
   context. Re-dispatch (don't self-fix) any thin/uncited result, escalating Haiku → Sonnet.
5. **`run_in_background` per agent**; agents write full analysis to disk and return a compact
   summary (keeps the orchestrator window lean).
6. **Verify before trusting** — check every result has `CLONED: yes` + cited candidates +
   URL/SHA *before* synthesising; re-dispatch (hardened) any that skipped grounding.
7. **Report first, no edits.** Synthesise dedup-across-agents (convergent candidates = highest
   confidence) + a token-cost watchlist + ranked bundles; let the user bundle-select before any
   skill edit (per the absorption-pass-protocol convention).

## Topic-specific patterns

- **Tech comparison:** WebSearch "[A] vs [B] [year]" → Context7 official docs each →
  WebSearch "[A] reddit" for real experience → check GitHub activity for popularity.
- **Library deep dive:** Context7 resolve → query topic → WebFetch changelog/migration →
  WebSearch "[library] pitfalls [year]".
- **Architecture/pattern:** WebSearch best practices → WebFetch engineering blogs
  (Fowler, Stripe, Cloudflare, cloud vendor architecture centres) → Context7 if
  framework-specific.

## Staleness — two distinct clocks

- **Frontmatter `staleness_threshold`** = when to re-review *this skill document*.
- **Re-research threshold (below)** = when to re-run *the research output* you produced.

| Domain | Re-research threshold |
|--------|-----------------------|
| AI/LLM tooling | 14 days |
| Frontend frameworks | 30 days |
| Cloud services / pricing | 60 days |
| Database/ORM patterns | 90 days |
| Security advisories | 7 days |
| General architecture patterns | 1 year |

Always set `**Re-research after:**` on a substantive research doc.

## When to stop researching

Stop when: the core question is answered with a clear recommendation, at least one
primary source is verified, trade-offs are documented, and code examples exist.

Stop **before**: reading every article, chasing tangents, or 100% certainty.
Good-enough-to-act is the goal.

## Hard blocks

- Never let the planning/synthesis model (Opus/Fable) perform mechanical retrieval — Phase 2
  fetch+extract is always dispatched to the cheap tier (Sonnet/Haiku), even for a single lookup.
  (Pre-authorising a domain is a permission action, not retrieval — that *does* stay with planning.)
- Never rely on a dispatched Phase-2 agent approving a novel `WebFetch` domain — pre-authorise it in Phase 1 (§ Web access under dispatch), else it silently auto-denies.
- Never present `[ASSUMED]` training knowledge as verified fact.
- Never ship research without a clear recommendation — a list of options is not a result.
- Never skip the primary source when one exists (Tier 1 before Tier 2/3).
- Never spawn parallel research agents for substantially overlapping topics.
- Never leave substantive research as an orphaned chat message — route it per the hand-off table.
- Never omit the re-research date on a substantive research doc.

## Review checklist

- [ ] Scope resolved before researching (the 4 pre-flight questions)
- [ ] Three-phase contract held — retrieval dispatched to Sonnet/Haiku, synthesis in the planning context
- [ ] Source domains pre-authorised before dispatch (§ Web access under dispatch)
- [ ] At least one Tier 1 (official docs / primary) source used
- [ ] Every claim tagged `[VERIFIED]` / `[COMMUNITY]` / `[ASSUMED]`
- [ ] Confidence derived from source tier, not asserted
- [ ] Clear recommendation made (not just a list)
- [ ] Code examples where the topic is implementable
- [ ] Assumptions and gaps documented
- [ ] Output routed to its destination (inline / `docs/research/` / ADR)
- [ ] Re-research date set from the staleness table
