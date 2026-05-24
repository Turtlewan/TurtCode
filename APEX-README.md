# APEX — Agentic Production Engineering eXperience

Your default app-building system for Claude Code. APEX is active in every project,
every session, automatically — no manual invocation required.

## What APEX does

- **Planning mode (Claude):** Designs features, writes complete specs, runs readiness gates, writes ADRs
- **Coding mode (DeepSeek):** Executes specs autonomously, never asks questions during AFK builds
- **Specialists:** 20 domain experts loaded on demand (security, frontend, UI/UX, animation, Figma, and more)
- **Governance:** Autonomy levels L0–L5, permission pre-authorisation, audit trails
- **Supporting tools:** Bug investigation, knowledge refresh, deep-dive research

## Prerequisites

- Claude Code installed
- `~/.claude/` directory exists
- DeepSeek backend configured (for coding mode)

## Installation

Clone or copy the APEX skills directory into `~/.claude/skills/`:

```bash
# If installing from a git repo
git clone https://github.com/your-org/apex ~/.claude/apex-install
cp -r ~/.claude/apex-install/skills/apex-* ~/.claude/skills/
cp -r ~/.claude/apex-install/agents/apex-* ~/.claude/agents/
cp -r ~/.claude/apex-install/registry/* ~/.claude/registry/
```

Then add the APEX session start block to your `~/.claude/CLAUDE.md`:

```markdown
## APEX — Default App Building System

### Session Start (all projects)

1. Check for `docs/status.md` in the current project directory
   - Not found → invoke `apex-init` to bootstrap the project
   - Found → read it: extract token_profile, autonomy_level, In-Flight table

2. Surface in-flight work
   - If In-Flight table has rows: "You were in the middle of [what]. Continue or set aside?"

3. Detect mode from ANTHROPIC_BASE_URL
   - Unset or api.anthropic.com → planning mode → route to `apex-plan`
   - Contains "deepseek" → coding mode → route to `apex-code`

4. State active context
   - Always output: "Running at L{n} | Profile: {profile} | Mode: {planning/coding}"
```

## Starting a new project

Open any directory in Claude Code. APEX detects no `docs/status.md` and bootstraps automatically:

```
APEX: This looks like a new project. What are you building?
You: A SaaS tool for managing freelance invoices
APEX: Who is it for?
You: Solo freelancers
APEX: I recommend: Next.js 15 + TypeScript + Tailwind + PostgreSQL + Prisma. Works for you?
You: Yes
APEX: Project initialised. What do you want to build first?
```

Bootstrap creates four persistent artifact files that every agent reads before acting:
- **PROJECT.md** — vision statement
- **REQUIREMENTS.md** — scope boundaries (in-scope / out-of-scope)
- **ROADMAP.md** — phase direction
- **docs/status.md** — live state (decisions, in-flight work, pending specs)

## The build loop

```
Planning session → discuss → spec → readiness gate → docs/changes/
   ↓
"start build" → AFK execution → handoff → docs/handoff/
   ↓
Planning session → review handoff → next spec
```

## Autonomy levels

| Level | What it allows | Use for |
|-------|---------------|---------|
| L0 | Read only | Audits, unfamiliar codebases |
| L1 | Write with per-file confirmation | High-stakes changes |
| L2 | Write freely (default) | Day-to-day development |
| L3 | Full pipeline, no git | Feature work |
| L4 | Includes git commit | Solo projects |
| L5 | Includes push to non-main | Personal tools |

Set level: "run this at L3" or in `docs/status.md`: `autonomy_level: L3`

## Token profiles

| Profile | Workers | Review | Specialists | Use for |
|---------|---------|--------|-------------|---------|
| lean | 1 | No | 0 | Quick edits |
| balanced (default) | 3 | Yes | 2 max | Daily work |
| thorough | Max | Yes | All | Security-sensitive |

Set profile: "switch to thorough" or in spec metadata: `token_profile: thorough`

## Pause and resume

Say "pause" or "stopping for now" — APEX saves your progress and confirms what it saved.
Say "resume" or "resuming" — APEX reads the checkpoint and continues.

Rate limit / quota cap: treated as a pause signal automatically. Say "resume build" when quota resets.

## What's next / auto-detect

Say "what's next" or "next step" — APEX reads your project state and tells you:
- If mid-build: surfaces the in-progress spec and position
- If specs ready: names the next spec to build
- If nothing queued: suggests starting planning

## Slash commands

| Command | What it does |
|---------|-------------|
| `/apex-debug "description"` | Start bug investigation (6-stage scientific method) |
| `/apex-debug --forensic "symptom"` | Production incident investigation |
| `/apex-refresh apex-security` | Refresh a skill with full research pass |
| `/apex-refresh --audit` | Show staleness of all skills |
| `/apex-deep-dive security` | Deep research on a domain |
| `/apex-deep-dive architecture "question"` | Specific architectural question |

## Domain specialists (20 domains)

Activated automatically when relevant keywords appear in your message.

### Core development
| Domain | Activates on |
|--------|-------------|
| `apex-security` | auth, crypto, secrets, SQL, injection, XSS, CORS |
| `apex-backend` | API, endpoint, database, cache, queue, REST, GraphQL |
| `apex-frontend` | React, Next.js, component, CSS, Tailwind, bundle |
| `apex-architecture` | system design, scalability, microservices, ADR |
| `apex-devops` | Docker, CI/CD, deploy, Terraform, GitHub Actions |
| `apex-testing` | TDD, test, Playwright, regression, coverage |
| `apex-performance` | latency, N+1, bundle size, Core Web Vitals, lighthouse |
| `apex-observability` | logging, tracing, metrics, Sentry, Grafana, OpenTelemetry |
| `apex-accessibility` | a11y, WCAG, ARIA, keyboard nav, screen reader |
| `apex-ai-systems` | LLM, RAG, vector, prompt, embedding, agent |
| `apex-data` | migration, schema, ETL, Prisma, PostgreSQL, Firecrawl |

### UI & design
| Domain | Activates on |
|--------|-------------|
| `apex-ui-ux-design` | UX, user flow, wireframe, visual hierarchy, onboarding |
| `apex-design-system` | component library, shadcn, Radix, Storybook, Tremor, tokens |
| `apex-animation` | animation, motion, GSAP, scroll effect, transition, gesture |
| `apex-figma` | Figma, design file, design-to-code, design token |
| `apex-ui-testing` | visual regression, Chromatic, Storybook testing, snapshot |

### Documentation
| Domain | Activates on |
|--------|-------------|
| `apex-docs-technical` | ADR, runbook, architecture doc, decision record |
| `apex-docs-product` | changelog, README, user guide, API reference, tutorial |

## Skill refresh

APEX skills can go stale. Refresh them when recommended:

```
/apex-refresh --audit         # see what needs refreshing
/apex-refresh apex-security   # full research pass using live docs + Snyk + Firecrawl
```

Suggested cadence: every 2 weeks for security and AI systems, every 60 days for stable domains.

## Directory structure created per project

```
docs/
  changes/        ← specs (planning writes, coding executes)
    done/         ← completed specs
  drafts/         ← in-progress specs
  handoff/        ← session summaries
  status.md       ← live project state
  technical/      ← ADRs, runbooks, architecture docs
  product/        ← user guides, API docs, changelog
  audit/          ← autonomy audit logs (L4+)
PROJECT.md        ← vision — loaded by every new agent
REQUIREMENTS.md   ← scope boundaries — loaded by every new agent
ROADMAP.md        ← phase direction — fill this during planning
CHANGELOG.md
README.md
```
