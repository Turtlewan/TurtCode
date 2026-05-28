---
skill: apex-research
backend: deepseek
mode: coding
version: 1.0.0
last_updated: 2026-05-28
---

# Deep Research — Execution Patterns

Research is a planning-mode skill, but these patterns apply when research results
need to be materialised into files, reports, or decision docs during a coding session.

## NEVER / ALWAYS

NEVER:
- Present assumed knowledge as verified fact — tag everything `[VERIFIED]`, `[ASSUMED]`, or `[COMMUNITY]`
- Continue researching past the point of actionability — stop when you have a clear recommendation
- Spawn redundant research agents for topics that overlap substantially
- Write research output without a clear recommendation — a list of options without guidance is not useful
- Fetch full pages when a targeted search would suffice

ALWAYS:
- Start with official docs (Context7 / official site) before community sources
- Include at least one primary source for every key claim
- State the research date — information staleness matters
- Link sources by URL or Context7 library ID
- End every research document with a concrete "Recommended approach" section

## Materialising research output

When research results in a file (comparison doc, tech memo, decision record):

```markdown
# Research: [Topic]
**Date:** 2026-05-27
**Confidence:** HIGH | MEDIUM | LOW
**Re-research after:** [date — e.g., 90 days for fast-moving ecosystems]

## Summary
[2-3 sentences: what you found and what you recommend]

## Key findings
- [Finding] [VERIFIED — source: url]
- [Finding] [COMMUNITY — source: reddit thread]
- [Finding] [ASSUMED — not verified this session]

## Options comparison
| Option | Pros | Cons | Best for |
|--------|------|------|----------|

## Recommended approach
**Use [X]** because [rationale]. Specifically: [concrete implementation guidance].

## Code examples
[Copy-paste ready snippets]

## Assumptions / gaps
- [What couldn't be verified]
- [What needs hands-on validation]

## Sources
- [Name] — [url or Context7 ID]
```

## Context7 usage patterns

```
# Resolve a library to its Context7 ID
mcp__plugin_context7_context7__resolve-library-id: { libraryName: "prisma" }
→ returns: "/prisma/prisma"

# Query docs for a specific topic
mcp__plugin_context7_context7__query-docs: {
  context7CompatibleLibraryID: "/prisma/prisma",
  topic: "transactions",
  tokens: 5000
}

# Common library IDs (resolve first if uncertain)
/vercel/next.js          — Next.js
/prisma/prisma           — Prisma ORM
/facebook/react          — React
/tanstack/query          — TanStack Query (React Query)
/tailwindlabs/tailwindcss — Tailwind CSS
/shadcn-ui/ui            — shadcn/ui
/trpc/trpc               — tRPC
/drizzle-team/drizzle-orm — Drizzle ORM
```

## Web search patterns

```
# Technology comparison
"[tech A] vs [tech B] 2026"
"[tech A] vs [tech B] reddit"
"[tech A] alternatives 2026"

# Best practices
"[topic] best practices 2026 site:dev.to OR site:blog.cloudflare.com OR site:engineering.atspotify.com"

# Community experience
"[library] pitfalls site:reddit.com"
"[library] issues site:github.com"
"[library] real world experience"

# Popularity signal
"[library] npm downloads"
"[library] github stars trend"
"[topic] state of JS 2024" (annual survey)
```

## Parallel research agent pattern

When comparing 3+ independent options, spawn parallel research agents:

```
Agent 1 prompt: "Research [Option A] for [use case]. Focus on: setup complexity, 
  performance, community size, known issues. Use Context7 for official docs, 
  WebSearch for community experience. Output structured research doc."

Agent 2 prompt: "Research [Option B] for [use case]. Same focus areas as Agent 1."

Agent 3 prompt: "Research [Option C] for [use case]. Same focus areas as Agent 1."
```

Then synthesise: merge findings into options comparison table, apply scoring, recommend.

## Decision record output format (ADR)

When research results in a permanent architecture decision:

```markdown
# ADR-NNN: [Decision title]

**Date:** 2026-05-27
**Status:** Accepted

## Context
[What problem we were solving and why a decision was needed]

## Options considered
| Option | Score | Reasoning |
|--------|-------|-----------|
| [A]    | 7/10  | [why]     |
| [B]    | 9/10  | [why]     |
| [C]    | 5/10  | [why]     |

## Decision
Use **[B]** because [rationale].

## Consequences
- Positive: [benefits]
- Negative: [tradeoffs to accept]
- Risks: [what could go wrong]

## Sources
- [source]
```

Save ADRs to: `docs/technical/adr/ADR-NNN-short-title.md`

## Staleness tracking

Different domains have different staleness thresholds:

| Domain | Re-research threshold |
|--------|-----------------------|
| AI/LLM tooling | 14 days |
| Frontend frameworks (Next.js, Astro) | 30 days |
| Cloud services (AWS/Azure/GCP pricing) | 60 days |
| Database/ORM patterns | 90 days |
| Security advisories | 7 days |
| General architecture patterns | 1 year |

Always include `**Re-research after:**` in research docs.

## Verification checklist

- [ ] At least one Tier 1 source (official docs via Context7 or direct URL) cited
- [ ] All claims tagged: `[VERIFIED]`, `[ASSUMED]`, or `[COMMUNITY]`
- [ ] Research date included in document
- [ ] Re-research date set based on domain staleness
- [ ] Concrete recommendation made (not just a list of options)
- [ ] Code examples included where the topic is implementable
- [ ] Assumptions and gaps section documents what couldn't be verified
- [ ] ADR written and saved to `docs/technical/adr/` if a permanent decision was made
