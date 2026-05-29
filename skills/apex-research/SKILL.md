---
skill: apex-research
backend: claude
version: 1.1.0
last_updated: 2026-05-29
sources:
  - Context7 MCP — context7.com
staleness_threshold: 7d
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

For multiple independent topics (e.g. comparing 3 tools), spawn one agent per topic:
```
Agent 1: Research Tool A — setup, performance, community, known issues
Agent 2: Research Tool B — same focus areas
Agent 3: Research Tool C — same focus areas
→ synthesise into one comparison table, score, recommend
```
Use `run_in_background: true` per agent, then synthesise together. Never spawn
overlapping agents — redundant research wastes runs.

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

- Never present `[ASSUMED]` training knowledge as verified fact.
- Never ship research without a clear recommendation — a list of options is not a result.
- Never skip the primary source when one exists (Tier 1 before Tier 2/3).
- Never spawn parallel research agents for substantially overlapping topics.
- Never leave substantive research as an orphaned chat message — route it per the hand-off table.
- Never omit the re-research date on a substantive research doc.

## Review checklist

- [ ] Scope resolved before researching (the 4 pre-flight questions)
- [ ] At least one Tier 1 (official docs / primary) source used
- [ ] Every claim tagged `[VERIFIED]` / `[COMMUNITY]` / `[ASSUMED]`
- [ ] Confidence derived from source tier, not asserted
- [ ] Clear recommendation made (not just a list)
- [ ] Code examples where the topic is implementable
- [ ] Assumptions and gaps documented
- [ ] Output routed to its destination (inline / `docs/research/` / ADR)
- [ ] Re-research date set from the staleness table
