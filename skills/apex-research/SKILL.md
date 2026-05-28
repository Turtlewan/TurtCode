---
skill: apex-research
backend: claude
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Context7 MCP — mcp.context7.com
  - Exa Search — exa.ai
  - Firecrawl — firecrawl.dev
staleness_threshold: 7d
---

# Deep Research Specialist — Planning Mode

## When to activate
Any time you need to research a topic deeply before planning or building. This includes:
- "Research X before I decide"
- "What's the best approach for Y in 2025/2026?"
- "Find me the current best practices for Z"
- "Compare options A vs B vs C"
- "Look up how [library/API/service] works"
- Any topic where training data may be stale (fast-moving ecosystems)

## Research strategy — tiered by source quality

### Tier 1: Official documentation (highest confidence)
Use Context7 MCP for libraries, frameworks, SDKs, CLIs:
```
mcp__plugin_context7_context7__resolve-library-id: { libraryName: "react" }
mcp__plugin_context7_context7__query-docs: { context7CompatibleLibraryID: "/facebook/react", topic: "hooks" }
```
Use for: API syntax, configuration, version migration, library-specific patterns.

### Tier 2: Web search (current state, trends, comparisons)
Use WebSearch for: recent developments, community consensus, tool comparisons, news:
```
WebSearch: "best practices [topic] 2025 site:reddit.com OR site:dev.to OR site:news.ycombinator.com"
WebSearch: "[library] vs [library] 2025 comparison"
```

### Tier 3: Primary sources (official docs, GitHub repos, papers)
Use WebFetch for: official docs not in Context7, GitHub READMEs, specification documents:
```
WebFetch: "https://docs.official-site.com/getting-started"
WebFetch: "https://github.com/org/repo/blob/main/README.md"
```

## Research output format

Always produce a structured research document with:

```markdown
# Research: [Topic]
**Date:** YYYY-MM-DD
**Confidence:** HIGH (verified from official docs) | MEDIUM (community sources) | LOW (assumed)

## Summary
2-3 sentence answer to the core question.

## Key findings
- Finding 1 [SOURCE: url or tool]
- Finding 2 [SOURCE: url or tool]

## Options comparison (if applicable)
| Option | Pros | Cons | Best for |
|--------|------|------|---------|

## Recommended approach
[Clear recommendation with rationale]

## Code examples / patterns
[Concrete, copy-paste ready examples]

## Assumptions / gaps
[What couldn't be verified; what needs validation]

## Sources
- [Source name] — [url or Context7 library ID]
```

## Spawning parallel research agents

When researching multiple independent topics (e.g., comparing 3 tools), spawn parallel agents:
```
Agent 1: Research Tool A
Agent 2: Research Tool B
Agent 3: Research Tool C
→ Synthesise results
```

Use `run_in_background: true` for each agent, then synthesise all results at once.

## Topic-specific research patterns

**Technology comparison:**
1. WebSearch: "[tech A] vs [tech B] [year]"
2. Context7: official docs for each
3. WebSearch: "[tech A] reddit" for community experience
4. Check GitHub stars/activity for popularity signal

**Library/framework deep dive:**
1. Context7: resolve library ID → query for specific topic
2. WebFetch: official changelog or migration guide
3. WebSearch: "[library] common pitfalls 2025"
4. WebFetch: GitHub issues for known bugs

**Architecture/pattern research:**
1. WebSearch: "[pattern] best practices [domain]"
2. WebFetch: Martin Fowler, AWS/GCP/Azure architecture blog, engineering blogs (Stripe, Cloudflare, etc.)
3. Context7: if pattern is implemented in a specific framework

**Market/tool landscape:**
1. WebSearch: "best [category] tools 2025"
2. Cross-reference: star counts, release dates, community size
3. WebSearch: "[tool] alternatives"

## Confidence tagging — mandatory

Every claim in research output must be tagged:
- `[VERIFIED]` — confirmed from official docs or primary source
- `[ASSUMED]` — based on training knowledge, not verified this session
- `[COMMUNITY]` — from community sources (Reddit, StackOverflow, blog posts)

Never present assumed knowledge as verified fact.

## When to stop researching

Research is complete when:
- Core question is answered with a clear recommendation
- At least one primary source verified
- Trade-offs are documented
- Code examples are available

Stop before: reading every article, exploring tangential topics, or achieving 100% certainty (that's not the goal — good-enough to act is).

## Review checklist

- [ ] Research question clearly stated at the top
- [ ] At least one Tier 1 (official docs) source used
- [ ] Confidence levels tagged on all claims
- [ ] Clear recommendation made (not just a list of options)
- [ ] Code examples provided where relevant
- [ ] Assumptions and gaps documented
- [ ] Staleness noted — when should this be re-researched?

## Standards

Context7: context7.com (library documentation search)
Exa: exa.ai (semantic search, better than Google for technical content)
Firecrawl: firecrawl.dev (full page content extraction)
