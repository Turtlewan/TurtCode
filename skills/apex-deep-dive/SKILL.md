---
skill: apex-deep-dive
backend: claude
version: 1.4.0
last_updated: 2026-06-03
sources:
  - APEX Design Specification 2026-05-24
  - Firecrawl — github.com/firecrawl/firecrawl
  - Repomix — github.com/yamadashy/repomix
  - Context7 (Upstash) — github.com/upstash/context7
  - Planning with Files — github.com/OthmanAdi/planning-with-files
staleness_threshold: 30d
description: >
  Use when you're genuinely uncertain which approach to take and need researched analysis
  before deciding — 2-3 options compared with trade-offs, risks, and a project-specific
  recommendation (analysis only, no code or spec). Triggers: "/apex-deep-dive <domain>",
  "research X deeply", "explore options for Y", "should we do A or B?". Not when the approach
  is already known (→ apex-plan) or for the implementation itself.
---

# APEX Deep Dive

Specialist research mode. Goes deeper than a standard planning session.
Reads your project thoroughly, researches 2-3 approaches, returns structured analysis.
Output is analysis only — no code, no spec produced.

## Invocation

/apex-deep-dive security
/apex-deep-dive architecture "should we split auth into a microservice?"
/apex-deep-dive performance "API response times degrading under load"
/apex-deep-dive {domain} "{specific question or context}"
/apex-deep-dive council "{a genuine go/no-go decision}"   → runs Council mode (below)

## Deep dive workflow

### Step 1: Frame the domain

Identify the domain from the invocation and state what you already know about it, so the research
targets the gap rather than re-deriving the basics.

There is **no domain-specialist skill to load** — domain knowledge is model-native (ADR-036). What a
deep dive adds is not recall but *this project's* constraints: read the code, the stack, and the
decisions already made, then research only what those make genuinely uncertain.

### Step 2: Read project context

Before researching, understand the specific project:
1. Read docs/status.md — current project state, stack
2. Read latest docs/handoff/*.md — recent context and flags
3. Read docs/technical/architecture/ if it exists
4. Read the specific files most relevant to the question (if known)
5. Read any existing ADRs related to the topic

The output must be specific to this project — not generic advice.

### Step 2b: Persist findings as you go

Deep dives generate a lot of research. Save to disk, not context:
- Create `docs/findings/{topic}-deep-dive.md`
- Write findings after every 2-3 research operations
- This file survives context resets — don't re-research what's already written

### Step 2c: Research tools available

Use the right tool for the type of research:

**Context7** (`mcp__context7` or `ctx7`): up-to-date library documentation
- Use for: "what does the current Prisma API look like?", "current Next.js 15 patterns"
- Prevents hallucinated APIs — fetches live docs, not training data

**Firecrawl** (`mcp__firecrawl` or Firecrawl MCP): scrape any web page or crawl entire domains
- Use for: research papers, blog posts, documentation sites, competitor analysis
- Batch scrape multiple URLs; returns clean markdown

**Repomix**: pack the entire codebase for cross-cutting analysis
- Use for: "how does auth flow through this codebase?", finding all call sites of a pattern
- `repomix --include "src/**/*.ts"` then analyse the packed output

### Step 3: Research approaches

For the specific question or domain area:
- Identify 2-3 meaningfully different approaches
- For each: research current best practice, real-world trade-offs, known failure modes
- Consider: what does this project's stack and scale make viable?

### Step 4: Produce structured analysis

Return this exact structure:

```markdown
# Deep Dive: {Domain} — {Topic}

## Context Read
{What I read about your project and what's relevant to this question}

## Approaches Considered

### Option A — {name}
**What:** {description}
**Pros:** {list}
**Cons:** {list}
**Risks:** {what could go wrong post-implementation}
**Effort:** {low / medium / high}

### Option B — {name}
(same structure)

### Option C — {name}
(same structure)

## Recommendation
**Choose: Option {X}**

{Specific reasoning for this project — not generic. Reference the context you read.}

## Trade-offs You're Accepting
{What you give up with the recommended option. Be honest.}

## Implementation Implications
{What this means for the next spec. Files to change, patterns to adopt, constraints to add to Specialist Context.}

## Risks to Monitor
{What to watch for post-implementation. How to know if it's going wrong.}

## Opposing View
{The strongest case against the recommendation. If someone disagreed, this is what they'd say.}
```

### Step 5: Offer next step

After delivering the analysis:
"This analysis feeds into your next spec. Want me to start planning the implementation?"

If yes: transition to apex-plan with the deep-dive findings as specialist context.

## Council mode — anti-anchoring four-voice (ADR-010)

Use for a genuine **go/no-go** decision where the proposal already on the table risks anchoring
the analysis (the model rationalises the answer it first reached). Invoked explicitly
(`/apex-deep-dive council "{question}"`), or accepted when `apex-plan` offers it at a judgment fork.
Council *replaces* the lone "Opposing View" with three independent dissents.

**The four voices:**
1. **Architect — you, in-context.** State the proposal and the reasoning for it. This is the
   anchored voice; everything else exists to counter its bias.
2. **Three fresh-context voices.** Dispatch three `general-purpose` subagents **in parallel**, each
   given **only the decision question** — no proposal, no your reasoning, no conversation history.
   That deprivation is the mechanism: a voice that never saw the proposed answer cannot anchor to it.
   (No dedicated agent files — the stance lives in the prompt, per ADR-007 leanness.)

**Voices are advisory and stake-free** — they never decide and nothing rides on their position; the
Architect folds their dissent. That independence (evaluator disjoint from evaluated, no stake, blind
to each other) is the *evaluator-independence invariant* in `apex-governance` — preserve it for any
future vote- or score-based variant, or evaluators game the rule instead of the task (the Odysseus
council-collusion failure; `docs/research/odysseus-analysis.md`).

**Voice dispatch template** (one per voice, `subagent_type: general-purpose`):
```
You are the {Skeptic | Pragmatist | Critic}. Decision question: "{question}".
You have ONLY this question — no proposed answer, no prior discussion. Do not assume any
answer is preferred; reason from the question alone.
{stance line:
  Skeptic    → "Argue the strongest case that this FAILS. What breaks, and why?"
  Pragmatist → "What is the simplest thing that actually works? Is the obvious approach over-built?"
  Critic     → "What is being assumed? What is missing from the framing — the question not being asked?"}
Return exactly:
  POSITION: go | no-go | depends-on{...}
  REASONING: 2-4 bullets, your strongest points only
  BIGGEST RISK: one line
```

**Synthesis (Architect).** Reconcile the four voices into the Recommendation. **Surface explicitly
where the three independent voices diverged from the proposal** — convergent dissent is a stop
signal; a lone dissent the others reject is usually noise. In the output structure, put the
strongest independent dissent under "## Opposing View" (it supersedes the single-voice version).

## Available domains

Any domain — security, frontend, architecture, devops, performance, data, auth, and so on. There is
no registry and no domain skill to load (ADR-036); the model brings the expertise, and the deep dive
supplies what it cannot know: *this project's* code, constraints, and prior decisions.

For topics that span multiple domains (e.g., "how should we handle auth for our API?"):
Load the primary domain (security) and note where other domains are relevant.
Do not load all domains simultaneously — pick the primary one.

## Depth vs. planning difference

Standard planning: discussing a known approach, writing a spec
Deep dive: genuinely uncertain about the approach, need research before deciding

If the approach is already known: skip deep dive, go to apex-plan directly.
