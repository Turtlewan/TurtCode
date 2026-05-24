# APEX — Agentic Production Engineering eXperience
## Design Specification

**Date:** 2026-05-24
**Status:** Approved — pending implementation plan
**Author:** Planning session (Claude + user)

---

## 1. Overview

APEX is a clean-slate AI-assisted software development ecosystem designed for building large production-grade applications. It is the default app-building system — active in every project, every session, without manual invocation.

**Core split:**
- Claude (Anthropic) handles all planning, architecture, review, orchestration, and reasoning
- DeepSeek handles all coding execution, file editing, testing, and verification

**Primary pain points solved:**
1. Handoff friction between planning and coding modes — every transition is a typed artifact
2. No specialist depth — 13 dual-format domain specialists, each with real domain expertise
3. No governance or guardrails — explicit autonomy levels, approval gates, audit trail
4. Context flooding — skills and agents loaded on demand only

**Design for:** Solo developer, OSS-extensible later.

---

## 2. Core Axioms

| Axiom | Implication |
|-------|-------------|
| Claude = Reasoning | Planning, architecture, review, orchestration, risk, approval |
| DeepSeek = Execution | Coding, file editing, testing, commands, verification |
| Skill = Unit of capability | One skill = one purpose, loaded on demand |
| Agent = Autonomous worker | Spawned with scoped tools and isolated context |
| Pipeline = Structured workflow | Defined sequences, typed handoffs, no ad-hoc chaining |
| Governance = First-class | Autonomy level is always explicit, never implicit |
| Questions belong in planning | Coding execution is silent — no questions during AFK build |
| The only transition artifacts are specs and handoffs | No ad-hoc planning-to-coding or coding-to-planning transitions |

---

## 3. System Architecture — Three Layers

```
┌─────────────────────────────────────────────────────┐
│  Layer 3 — Governance                                │
│  Autonomy levels, approval gates, audit trail,       │
│  permissions manifest, hard blocks                   │
├─────────────────────────────────────────────────────┤
│  Layer 2 — Domain Specialists                        │
│  13 domains, dual-format (Claude + DeepSeek),        │
│  specialist agents, cross-domain flag system         │
├─────────────────────────────────────────────────────┤
│  Layer 1 — Foundation                                │
│  Orchestrator (router only), apex-plan, apex-code,   │
│  handoff protocol, pause/resume, docs strategy       │
└─────────────────────────────────────────────────────┘
```

The orchestrator is a **pure router** — zero domain knowledge. It reads the request, determines which skills/agents to load, and structures the handoff. All domain knowledge lives in Layer 2.

---

## 4. Folder Structure

### Global (`~/.claude/`)

```
~/.claude/
  skills/
    apex-orchestrate/        # Main entry — routing only
    apex-plan/               # Planning workflow (Claude)
    apex-code/               # Coding workflow (DeepSeek)
    apex-handoff/            # Handoff protocol (bidirectional)
    apex-review/             # Code + architecture review (Claude)
    apex-debug/              # Bug investigation
    apex-refresh/            # Knowledge refresh
    apex-deep-dive/          # Specialist research mode

    apex-security/
      SKILL.md               # Claude: threat modelling, review, risk
      impl.md                # DeepSeek: secure coding patterns
      refs/                  # OWASP, NIST, etc.
    apex-frontend/
    apex-backend/
    apex-architecture/
    apex-devops/
    apex-testing/
    apex-performance/
    apex-observability/
    apex-accessibility/
    apex-ai-systems/
    apex-data/
    apex-docs-technical/
    apex-docs-product/

    apex-governance/
      SKILL.md
      levels/
        L0.md
        L1.md
        L2.md
        L3.md
        L4.md
        L5.md
      audit-log.md

  agents/
    apex-orchestrator.md
    apex-coder.md
    apex-reviewer.md
    apex-security-agent.md
    apex-frontend-agent.md
    apex-backend-agent.md
    apex-architecture-agent.md
    apex-devops-agent.md
    apex-testing-agent.md
    apex-performance-agent.md
    apex-observability-agent.md
    apex-accessibility-agent.md
    apex-ai-systems-agent.md
    apex-data-agent.md
    apex-docs-technical-agent.md
    apex-docs-product-agent.md

  registry/
    skills.md                # Canonical skill registry
    agents.md                # Canonical agent registry
    domains.md               # Domain → skill + agent mapping
    token-config.md          # Global default token profile
```

### Per-Project

```
<project>/
  docs/
    changes/                 # Ready specs (coding consumes)
      done/                  # Completed specs archived here
    drafts/                  # Planning in-progress specs
    handoff/                 # Session summaries (YYYY-MM-DD.md)
    status.md                # Live project state
    audit/                   # YYYY-MM-DD.log (L4+ sessions)

    technical/               # Internal / developer docs
      adr/                   # Architecture Decision Records
      architecture/          # System diagrams, design docs
      runbooks/              # Operational procedures
      setup/                 # Developer environment setup

    product/                 # External / user-facing docs
      api/                   # OpenAPI / API reference
      guides/                # User guides and tutorials
      components/            # Component documentation
      releases/              # Release notes

  CHANGELOG.md               # Updated by apex-docs-product-agent
  README.md                  # Updated by apex-docs-product-agent
```

---

## 5. Foundation Layer

### 5.1 Orchestrator (`apex-orchestrate`)

Pure router. No domain knowledge. Three responsibilities only:

1. **Orient** — read `docs/status.md`, detect mode, detect pause/resume signals
2. **Route** — decide what needs to happen and which skills/agents to load
3. **Hand off** — write or validate the structured artifact the other mode picks up

**Session start flow:**

```
Session starts
  → check for docs/status.md
      not found → run apex-init (new project bootstrap)
      found     → read it
  → check in-flight table
      in-flight work found → surface it: "You were mid-[task]. Continue or set aside?"
  → detect mode (planning or coding)
  → planning mode
      read docs/drafts/ for unfinished specs
      read docs/changes/ for ready specs (context only)
      read latest docs/handoff/ for coding session summary
      surface active token profile and autonomy level
  → coding mode
      read docs/changes/ for ready specs
      read latest docs/handoff/ for prior context
      surface active token profile and autonomy level
```

**Routing table:**

| Signal type | Route to |
|-------------|----------|
| Pause signal | Pause workflow for current mode |
| Resume signal | Resume from status.md in-flight |
| plan / design / architect / spec / review | `apex-plan` |
| build / implement / code / fix / write | `apex-code` |
| debug / investigate / root cause / broken | `apex-debug` |
| review / audit / check | `apex-review` |
| deep dive / research deeply | `apex-deep-dive` |
| refresh / update / stale | `apex-refresh` |
| Domain keyword | Load matching specialist + route |
| Ambiguous | Ask one clarifying question before routing |

Domain keywords trigger specialist loading **alongside** the primary route — not replacing it. Multiple specialists can be active simultaneously but do not share context and cannot activate each other.

---

### 5.2 Pause / Resume Protocol

**Pause signals:** "stopping for now", "pausing", "I'll continue later", "taking a break", "pause here", "stopping"

**Resume signals:** "resuming", "picking up", "continue where we left off", "back", "let's continue", "where were we"

**On pause — planning mode:**
1. Save in-progress draft to `docs/drafts/<spec-name>.md`
2. Write `## Where I stopped` section: decisions reached, next open question, open items
3. Update `docs/status.md` in-flight table
4. Confirm: "Draft saved to `docs/drafts/<name>.md`. Next time say 'resuming' and I'll pick up from: [next open item]."

**On pause — coding mode:**
1. Complete the current task (never stops mid-task)
2. Update `## Progress` checkboxes in the spec
3. Run `git status` — note uncommitted changes explicitly
4. Update `docs/status.md` in-flight table
5. Confirm: "Paused after task N/M. Uncommitted changes in [files]. Say 'resume build' to continue."

**On resume:**
- Reads `docs/status.md` in-flight table
- Surfaces in-flight work before anything else
- Works from artifacts, not conversation memory

**A pause is never silent.** The system always confirms what it saved, where, and what to expect when returning.

---

### 5.3 Spec Format (Planning → Coding handoff)

Every spec written by planning mode follows this exact format. This is the contract DeepSeek reads.

```markdown
---
spec: {short-name}
status: ready
token_profile: balanced        # lean | balanced | thorough | custom
autonomy_level: L3             # overrides session default for this spec
---

# Spec: {title}

## Scope
One paragraph. What this changes and why.

## Prerequisites
- Specs that must be complete first
- Environment setup required

## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| src/auth/middleware.ts | modify | Add token refresh logic |
| src/auth/refresh.ts | create | New endpoint handler |

## Tasks
- [ ] Task 1: {description} — acceptance: {criterion}
- [ ] Task 2: {description} — acceptance: {criterion}
- [ ] Task 3: {description} — acceptance: {criterion}

## Permissions

The following actions will run autonomously during build.
Approving this spec approves all of them.

### File Operations
| Action | Paths |
|--------|-------|
| Create | src/auth/refresh.ts |
| Modify | src/auth/middleware.ts |
| Delete | (none) |

### Commands
| Command | Purpose |
|---------|---------|
| `npm install jsonwebtoken` | Add dependency |
| `npm run lint` | Verify code style |
| `npm test -- --testPathPattern=auth` | Run auth tests |
| `npm run build` | Verify build passes |

### Git Operations
| Operation | Scope |
|-----------|-------|
| `git add` | src/auth/* |
| `git commit` | "feat: add token refresh endpoint" |

### Environment Access
| Variable | Purpose |
|----------|---------|
| `JWT_SECRET` | Token signing |

### Network
| Action | Purpose |
|--------|---------|
| `npm install` | Package installation |

## Specialist Context
### Security
{Threat model findings, constraints from apex-security review}

### Performance
{Performance constraints or budgets, if applicable}

### Accessibility
{A11y requirements, if frontend change}

## Documentation
| Doc type | File | Action |
|----------|------|--------|
| Inline | src/auth/refresh.ts | JSDoc all exports |
| API | docs/product/api/auth.md | Add refresh endpoint |
| Changelog | CHANGELOG.md | Add entry under Unreleased |
| ADR | docs/technical/adr/ADR-003-token-refresh.md | Write |

## Acceptance Criteria
- [ ] {criterion 1}
- [ ] {criterion 2}

## Risks / Open Questions
(Must be empty for spec to pass readiness gate)

## Progress
_(Coding mode writes here)_
```

---

### 5.4 Handoff Format (Coding → Planning)

Every session summary written by coding mode.

```markdown
# Handoff: {YYYY-MM-DD}
_Mode: coding | Autonomy level: L{n} | Token profile: {profile}_

## What Was Built
1-3 sentence summary.

## Specs Completed
| Spec | Status |
|------|--------|
| auth-refresh | ✅ complete |
| search-api | 🔄 partial — stopped at task 3/5 |

## Files Changed
| File | What changed | Committed |
|------|-------------|-----------|
| src/auth/middleware.ts | Added token refresh | ✅ abc1234 |
| src/auth/refresh.ts | Created endpoint | 🟡 uncommitted |

## Documentation Status
| Doc | Action taken | Status |
|-----|-------------|--------|
| src/auth/refresh.ts | Inline JSDoc added | ✅ |
| docs/product/api/auth.md | Refresh endpoint documented | ✅ |
| CHANGELOG.md | Entry added under Unreleased | ✅ |

## Current State
- Builds: ✅ / ❌
- Tests: ✅ passing / ❌ {n} failing
- Known issues: {list or "none"}

## Specialist Flags
| Domain | Flag | Severity |
|--------|------|----------|
| Security | JWT secret hardcoded in test fixture | low |

## Decisions Made
| Task | Decision | Reason | Review needed? |
|------|----------|--------|----------------|
| Task 3 | Used existing UserService | Spec said "user lookup" — existing service covered it | No |
| Task 5 | Skipped email — SMTP config missing | Could not complete without config | Yes ⚠️ |

## What's Next
Suggested follow-up for planning mode.
```

---

## 6. Documentation Strategy

Documentation is handled by two separate specialist domains with different ownership and timing.

### 6.1 Technical Documentation (`apex-docs-technical`)

**Owned by:** Claude (planning mode)
**Timing:** Written *during* planning, alongside decisions
**Audience:** Engineers, future maintainers

| Doc type | When | Location |
|----------|------|----------|
| ADRs | When architectural decision is made | `docs/technical/adr/` |
| Architecture diagrams | During system design | `docs/technical/architecture/` |
| Runbooks | When operational procedures are defined | `docs/technical/runbooks/` |
| Developer setup | When environment/tooling changes | `docs/technical/setup/` |
| Inline code docs | During coding | Alongside source files |

**Principle:** ADRs are written when decisions are made, not deferred. If a decision was reached in planning, an ADR is produced before the spec is written.

### 6.2 Product Documentation (`apex-docs-product`)

**Owned by:** `apex-docs-product-agent` (post-coding, pre-review)
**Timing:** Runs after coding is complete, as a separate pipeline stage
**Audience:** End users, API consumers, external developers

| Doc type | When | Location |
|----------|------|----------|
| User guides / tutorials | After feature complete | `docs/product/guides/` |
| API reference (OpenAPI) | After API changes | `docs/product/api/` |
| README | After any user-facing change | `README.md` |
| Changelog | After every coding session | `CHANGELOG.md` |
| Release notes | At release time | `docs/product/releases/` |

The product docs agent reads the handoff summary and changed files — not the spec — to understand the user-facing change. It writes from the user's perspective, not the implementation's.

---

## 7. Dual-Format Specialist System (Layer 2)

### 7.1 The Dual-Format Principle

Every specialist domain ships two files with non-overlapping responsibilities:

| File | Model | Job |
|------|-------|-----|
| `SKILL.md` | Claude | Architecture, trade-offs, review, risk, recommendations |
| `impl.md` | DeepSeek | Implementation patterns, explicit constraints, checklists, verification steps |
| `refs/` | Both | Shared reference material — standards, patterns, examples |

**Claude (`SKILL.md`) always includes:**
- When to involve this specialist
- Key questions to ask before designing
- Trade-off frameworks
- Review checklist
- Common architectural mistakes
- Risk escalation rules (BLOCK vs. FLAG)
- Which standards apply and why

**DeepSeek (`impl.md`) always includes:**
- Explicit do/don't rules — no ambiguity
- Step-by-step implementation patterns
- Code-level constraints (exact patterns, required validations)
- Verification checklist
- What to flag for Claude review
- Forbidden patterns

### 7.2 Domain Registry

| Domain | Skill | Activation keywords |
|--------|-------|---------------------|
| Security | `apex-security` | auth, crypto, secret, password, token, permissions, SQL, injection, XSS, CORS, API key |
| Frontend | `apex-frontend` | React, Next, Vue, component, UI, CSS, browser, client-side, bundle |
| Backend | `apex-backend` | API, server, endpoint, database, cache, queue, service, handler |
| Architecture | `apex-architecture` | system design, scalability, microservices, monolith, event-driven, domain model, ADR |
| DevOps | `apex-devops` | Docker, CI/CD, deploy, pipeline, Kubernetes, infra, environment, container |
| Testing | `apex-testing` | test, spec, e2e, integration, unit, coverage, mock, fixture, assertion |
| Performance | `apex-performance` | slow, latency, throughput, N+1, memory, bundle size, cache, profiling |
| Observability | `apex-observability` | logging, tracing, metrics, alert, monitor, Prometheus, OpenTelemetry |
| Accessibility | `apex-accessibility` | a11y, WCAG, ARIA, screen reader, keyboard nav, colour contrast |
| AI Systems | `apex-ai-systems` | LLM, embedding, RAG, vector, prompt, eval, model, agent, inference |
| Data | `apex-data` | migration, schema, pipeline, ETL, warehouse, query optimisation |
| Technical Docs | `apex-docs-technical` | ADR, runbook, architecture doc, decision, setup guide |
| Product Docs | `apex-docs-product` | changelog, README, user guide, API reference, release notes |

### 7.3 Activation Mechanism

Three triggers for specialist loading:

1. **Keyword detection** — orchestrator scans user request against activation keyword list
2. **Spec content scan** — file paths and task descriptions scanned when spec is opened (`src/auth/` → security; `src/components/` → frontend + accessibility)
3. **Explicit request** — user names a domain directly ("with a focus on performance")

**Cross-domain coordination rule:** Specialists cannot activate each other. A specialist may flag that another domain should be consulted. The orchestrator reads that flag and decides whether to act. All coordination routes through the orchestrator only.

### 7.4 Skill Metadata

Every skill file carries a metadata header:

```yaml
---
skill: apex-security
version: 1.0.0
last_updated: 2026-05-24
sources:
  - OWASP Top 10 (2021)
  - NIST SP 800-63B
confidence: high
staleness_threshold: 14d
claude_compatibility: high
deepseek_compatibility: high
context_efficiency: medium
safety_quality: critical
---
```

---

## 8. Governance Layer (Layer 3)

### 8.1 Two Primary Operating Modes

#### Build Mode — AFK Execution

Full discussion and spec creation with all questions answered in planning. Once "start build" is said, coding runs completely silently. No questions, no gates, no approvals during execution. You come back to a handoff.

**During AFK execution, coding mode:**
- Never stops to ask a question
- Makes the conservative choice when ambiguous, logs every decision
- Completes all tasks declared in the spec
- Blocks and logs any action not declared in the permissions section
- Writes the full handoff on completion

**Conservative choice rules:**
- Prefer not modifying a file over modifying it if the task is unclear
- Prefer existing patterns over inventing new ones
- Prefer simpler over clever
- Prefer more validation over less
- Never delete — flag for planning review instead

#### Edit Mode — Interactive

For bug fixes, quick tweaks, config changes, small refactors. User is present. Coding mode can ask questions. Confirmation gates active for critical files. No spec required for small changes.

---

### 8.2 Spec Readiness Gate

Runs automatically when user says "ready to build" or "start build". Spec does not move from `docs/drafts/` to `docs/changes/` until every item passes.

```
Files
  [ ] Every file to be changed has a full path
  [ ] Every new file has a specified location
  [ ] No file listed as "TBD" or "somewhere in src/"

Tasks
  [ ] Every task has a single unambiguous action
  [ ] Every task has a concrete acceptance criterion
  [ ] No task contains "or", "maybe", "depending on", "TBD"
  [ ] Task dependencies are explicit

Permissions
  [ ] All files to be written are listed with full paths
  [ ] All commands listed with exact syntax
  [ ] All git operations listed and within active autonomy level
  [ ] All environment variables accessed are listed
  [ ] No unlisted network calls

Specialist flags
  [ ] All BLOCK-level flags resolved
  [ ] All FLAG-level flags resolved or explicitly accepted

Questions
  [ ] Zero open questions in the spec
  [ ] "Risks / Open Questions" section is empty
  [ ] No ambiguity in acceptance criteria

Documentation
  [ ] Inline doc requirements specified
  [ ] Product doc updates specified (if user-facing change)
```

When gate passes:
```
✅ Spec readiness gate passed — 0 open items.
Spec moved to docs/changes/auth-refresh.md
Status: 📋 ready

Say "start build" to run coding mode, or continue planning other specs.
```

---

### 8.3 Autonomy Levels

Default: **L2**. Set in `docs/status.md` or inline ("run this at L3").

| Level | Name | Allowed | Forbidden | Gate |
|-------|------|---------|-----------|------|
| L0 | Read Only | Read, explore, plan, draft | Write any file, run any command | Every action manual |
| L1 | Supervised Write | L0 + write files | Running commands, batch writes, schema changes | Confirm each file |
| L2 | Controlled Auto-Write *(default)* | L1 + write non-critical files | Schema, auth, config changes without confirmation | Auto for regular; explicit for critical |
| L3 | Pipeline Auto-Run | L2 + full coding pipeline + test/lint/build | git commit, schema changes, deletions | Confirm before commit, schema, deletions |
| L4 | Agentic Loop | L3 + git commit (message approved first) | git push, merge, PR, drop data | Commit message approval; destructive = hard block |
| L5 | High Autonomy | L4 + git push to non-main + create draft PRs | Merge to main, delete branches, modify prod infra | PR description approval; push to main = hard block |

**Critical files** (always require explicit confirmation regardless of level): `*.env`, migration files, auth middleware, CI/CD configs, secrets.

### 8.4 Hard Blocks — Never Overridable

```
- Push to main / master directly
- Merge a PR
- Drop a database table or schema
- Delete a git branch
- Access or log production secrets
- Modify audit log files
- Disable or bypass the governance layer itself
```

### 8.5 Approval Gate Format

```
⚠️  Approval required [L{n} gate]

Action:    git commit
Scope:     src/auth/middleware.ts, src/auth/refresh.ts
Message:   "feat: add token refresh endpoint"

Risks:     Auth flow modified — regression risk
Rollback:  git reset HEAD~1 (before push)

Approve? [y / n / edit message]
```

No silent escalation. No retrying a denied action.

### 8.6 Audit Trail

Every session at L4+ writes to `docs/audit/YYYY-MM-DD.log`:

```
[2026-05-24 14:32:11] SESSION START — Level: L4 | Profile: balanced
[2026-05-24 14:32:15] SPECIALIST LOADED — apex-security (trigger: keyword "auth")
[2026-05-24 14:35:02] FILE WRITE — src/auth/refresh.ts (auto-approved L4)
[2026-05-24 14:35:44] GATE TRIGGERED — git commit (approval required)
[2026-05-24 14:35:51] GATE APPROVED — commit abc1234 "feat: add token refresh"
[2026-05-24 14:36:00] SESSION END — 2 files written, 1 commit, 0 blocks
```

---

## 9. Specialist Subagent Registry

### 9.1 Agent Definition Format

```markdown
---
name: apex-{domain}-agent
mode: both | claude | deepseek
tools: [Read, Glob, Grep, Edit, Write, Bash]
spawned_by: orchestrator
---

## Purpose
## Activation Conditions
## Inputs
## Claude Behaviour (planning mode)
## DeepSeek Behaviour (coding mode)
## Output Format
## Escalation Rules
## Handoff Format
```

### 9.2 Agent Registry

| Agent | Mode | Job |
|-------|------|-----|
| `apex-security-agent` | Both | Threat modelling (Claude) / secure implementation (DeepSeek) |
| `apex-frontend-agent` | Both | UI architecture (Claude) / component implementation (DeepSeek) |
| `apex-backend-agent` | Both | API design (Claude) / endpoint implementation (DeepSeek) |
| `apex-architecture-agent` | Claude only | System design, ADRs, trade-off analysis |
| `apex-devops-agent` | Both | Pipeline design (Claude) / config implementation (DeepSeek) |
| `apex-testing-agent` | DeepSeek only | Write and run tests — only when spec includes testing tasks |
| `apex-performance-agent` | Both | Profiling analysis (Claude) / optimisation (DeepSeek) |
| `apex-observability-agent` | Both | Instrumentation design (Claude) / logging implementation (DeepSeek) |
| `apex-accessibility-agent` | Both | A11y review (Claude) / ARIA implementation (DeepSeek) |
| `apex-ai-systems-agent` | Both | LLM/RAG design (Claude) / integration implementation (DeepSeek) |
| `apex-data-agent` | Both | Schema design (Claude) / migration implementation (DeepSeek) |
| `apex-docs-technical-agent` | Claude only | ADRs, runbooks, architecture docs, handoff writer |
| `apex-docs-product-agent` | DeepSeek only | Inline docs, API reference, changelog, README — always runs post-build |

### 9.3 AFK Build Pipeline

```
"start build" → coding pipeline reads spec
      │
      ├─ apex-coder (code-writer)
      │     → builds task dependency graph
      │     → spawns code-workers in parallel waves
      │
      ├─ Parallel wave 1
      │     ├─ code-worker (task 1)
      │     ├─ code-worker (task 2)
      │     └─ apex-security-agent (if declared in spec specialist context)
      │
      ├─ Parallel wave 2 (after wave 1 complete)
      │     ├─ code-worker (task 3)
      │     └─ apex-testing-agent (only if spec includes testing tasks)
      │
      ├─ Post-build
      │     ├─ apex-reviewer (reads all changed files, flags issues)
      │     ├─ apex-accessibility-agent (if frontend changes in spec)
      │     └─ apex-docs-product-agent (always runs)
      │
      └─ apex-docs-technical-agent writes handoff doc
```

Specialist agents only spawn if their domain is declared in the spec's `## Specialist Context` section.

---

## 10. Supporting Systems

### 10.1 Knowledge Refresh (`apex-refresh`)

**Manual-only. Suggested cadence: every 2 weeks.**
No automatic triggers. Staleness audit is informational only — nothing is blocked by staleness.

**Workflow:**
```
/apex-refresh <skill>

1. Read current skill — what does it currently teach?
2. Full research pass (not limited to original sources)
   → current best practices for the domain
   → what has changed since last update
   → current standards, tools, anti-patterns
   → new vulnerability disclosures or deprecations
3. Synthesise findings — what does the field recommend today?
4. Diff against current skill:
   STILL VALID:   content that holds up
   OUTDATED:      content now wrong or deprecated
   MISSING:       important content the skill doesn't cover
   NEW SOURCES:   better or more current references found
5. Show full proposed rewrite
6. Require approval: "Apply full update? [y / n / partial]"
7. On approval: write updated skill, bump version, update sources,
   log change to skill changelog
```

**`/apex-refresh --audit`** — informational scan:
```
Skill staleness audit (informational — nothing is blocked)
──────────────────────────────────────────────────────────
✅ apex-frontend     updated 5d ago
🟡 apex-backend      updated 18d ago   → consider refreshing
🔴 apex-security     updated 45d ago   → recommended to refresh
⚠️ apex-data         no metadata
```

### 10.2 Deep-Dive Mode (`apex-deep-dive`)

For when a standard planning session isn't enough. Loads a specialist agent, researches the domain for your specific project, returns structured analysis.

**Invocation:**
```
/apex-deep-dive security
/apex-deep-dive architecture "should we split auth into a microservice?"
/apex-deep-dive performance "API response times degrading under load"
```

**Output structure — always:**
```markdown
# Deep Dive: [Domain] — [Topic]

## Context Read
## Approaches Considered (2-3 options with pros/cons/risks)
## Recommendation (with reasoning specific to this project)
## Trade-offs You're Accepting
## Implementation Implications
## Risks to Monitor
## Opposing View (strongest case against the recommendation)
```

Output is analysis only — no code written, no spec produced. Findings feed into planning → spec.

### 10.3 Bug Investigation (`apex-debug`)

**Rule: reproduce before fixing. Assumption-based debugging is forbidden.**

**Six-stage workflow:**
```
Stage 1 — Reproduce
  Define exact reproduction steps
  Confirm bug is reproducible before proceeding
  If not reproducible: stop, document, escalate

Stage 2 — Isolate
  Narrow to: frontend / backend / database / infrastructure
  Read git log since last known-good state
  Identify candidates — do not fix yet

Stage 3 — Root Cause
  One hypothesis at a time
  Instrument to confirm (logs, tests, debugger)
  Confirm root cause before proposing fix

Stage 4 — Fix
  Surgical fix only — minimum files touched
  No refactoring, no cleanup, no "while I'm here"
  Fix must be verifiable against reproduction steps

Stage 5 — Verify
  Run reproduction steps — bug gone
  Run full test suite — no regressions introduced

Stage 6 — Prevent
  Write regression test that would have caught this
  Note in handoff: what failed, why, what prevents recurrence
```

**`--forensic` flag** — adds Stage 0 for production incidents without clear reproduction:
```
Stage 0 — Evidence Gathering
  Read: recent git commits, deploy logs, error logs
  Timeline: when did symptoms start?
  Correlate: what changed around that time?
  Form initial hypothesis before attempting reproduction
```

**Unbreakable rules:**
- Never fix before reproducing
- Never modify more than the minimum
- Always write a regression test
- Always document root cause

---

## 11. Token Configuration

### 11.1 Profiles

| Profile | Agents active | Relative DeepSeek cost | Use when |
|---------|--------------|----------------------|----------|
| `lean` | 1 worker, no reviewer, no specialists, minimal docs | 1x | Quick edits, exploratory, tight budget |
| `balanced` *(default)* | 3 workers, reviewer, relevant specialists, full docs | 2-3x | Day-to-day feature work |
| `thorough` | Max workers, reviewer, all relevant specialists, deep docs | 4-6x | Security-sensitive, critical features, pre-release |
| `custom` | User-defined knobs | Variable | When presets don't fit |

**Planning mode cost stays roughly constant regardless of profile.** Profiles only affect the coding pipeline (DeepSeek).

### 11.2 Custom Knobs

```yaml
token_profile: custom
token_config:
  workers: 2
  reviewer: true
  max_specialists: 1
  reviewer_depth: quick         # quick | deep
  testing_agent: false
  docs_product: true
  docs_inline: true
  model_workers: deepseek-chat
  model_reviewer: deepseek-chat
```

### 11.3 Configuration Levels

**Global default** — `~/.claude/registry/token-config.md`
```yaml
default_profile: balanced
```

**Per session** — inline signal or `docs/status.md`
```
"run this session lean"
"switch to thorough for this build"
```

**Per spec** — spec metadata block
```yaml
---
token_profile: thorough
---
```

Token config is locked once "start build" is called. No changes during AFK execution.

---

## 12. Recommended Stack

Chosen for strong AI coding compatibility: strong types, clear conventions, wide training coverage.

### Frontend
| Technology | Choice |
|------------|--------|
| Framework | Next.js 15 (App Router) |
| Language | TypeScript |
| Styling | Tailwind CSS |
| Components | shadcn/ui |
| Animation | Framer Motion |

### Backend
| Technology | Choice |
|------------|--------|
| Runtime | Node.js |
| Framework | Fastify |
| Database | PostgreSQL |
| ORM | Prisma |
| Cache | Redis |
| Validation | Zod |
| Auth | Auth.js |

### AI Systems (when building AI features)
| Technology | Choice |
|------------|--------|
| Language | Python |
| API layer | FastAPI |
| LLM SDK | Anthropic SDK + Vercel AI SDK |
| RAG | LlamaIndex |
| Vector DB | Qdrant |

### DevOps
| Technology | Choice |
|------------|--------|
| Containers | Docker |
| CI/CD | GitHub Actions |
| Deployment | Railway or Fly.io |
| IaC | Terraform (when infra warrants it) |

### Testing
| Technology | Choice |
|------------|--------|
| Unit | Vitest |
| E2E | Playwright |
| API | Supertest |

### Observability
| Technology | Choice |
|------------|--------|
| Instrumentation | OpenTelemetry |
| Error tracking | Sentry |
| Logs/metrics | Axiom or Grafana |

**Why TypeScript dominates:** The type system — Prisma schemas, Zod validators, TypeScript interfaces — acts as guardrails DeepSeek reasons against, significantly reducing implementation errors.

**Python is for AI systems only** — not a second backend language. One primary language per layer.

---

## 13. Project Bootstrap (`apex-init`)

Runs automatically on first session in any project (no `docs/status.md` found).

**Bootstrap conversation:**
```
1. What are you building? (1-2 sentences)
2. Who is it for?
3. Confirm or override recommended stack?
```

**Creates:**
```
docs/
  status.md          ← initialised with project context + defaults
  changes/
  drafts/
  handoff/
  technical/adr/
  product/guides/
  product/api/
CHANGELOG.md
README.md (minimal)
```

**Initialised `docs/status.md`:**
```markdown
# Project: {name}
{description}

stack: {confirmed stack}
token_profile: balanced
autonomy_level: L2
specialists_default: []   # domains always active for routing in this project, regardless of keywords

## In-Flight
(none)

<!-- PLANNING:START -->
## Pending Specs
(none yet)

## Open Questions
(none)
<!-- PLANNING:END -->
```

After bootstrap: "Project initialised. Ready to plan your first feature. What do you want to build first?"

---

## 14. CLAUDE.md Integration

The global `~/.claude/CLAUDE.md` is updated to run the APEX orchestrator automatically at the start of every session in every project.

**Addition to session start rules:**
```markdown
## Session Start (all projects)

1. Check for docs/status.md
   - Not found → run apex-init before anything else
   - Found → read it, surface in-flight work, detect mode

2. Detect active backend
   - Anthropic → planning mode (apex-plan)
   - DeepSeek → coding mode (apex-code, check docs/changes/ first)

3. Surface active context
   - In-flight work (from status.md in-flight table)
   - Active token profile
   - Active autonomy level

4. Route to appropriate APEX workflow
```

---

## 15. Implementation Roadmap

### Phase 1 — Foundation (Week 1)
Skeleton everything else sits on.

- Folder structure (global + per-project template)
- `docs/status.md` template
- Spec format template + permissions manifest section
- Handoff format template (both directions)
- Pause/resume signal list + workflow
- `apex-orchestrate` — basic routing, session start flow, status.md reading
- `apex-init` — new project bootstrap
- CLAUDE.md update — always-on orchestrator

**Done when:** Session starts, orchestrator reads status.md, routes correctly, pause/resume works end-to-end, new project bootstraps automatically.

### Phase 2 — AFK Build Pipeline (Week 2)
Core build loop.

- `apex-plan` skill — planning workflow, spec creation
- Readiness gate validator — all checklist items enforced
- Permissions pre-authorisation — spec permissions → coding mode context
- Unlisted action blocker — blocks and logs anything not in permissions
- `apex-code` skill — AFK mode + edit mode
- Coding pipeline agents: `apex-coder`, `code-worker`, `apex-reviewer`
- `apex-docs-technical-agent` — handoff writer
- `apex-docs-product-agent` — inline docs, changelog, README

**Done when:** Write spec in planning, say "start build", go AFK, return to complete handoff with decisions logged. Unlisted actions blocked and logged.

### Phase 3 — Specialist Layer (Weeks 3–5)
Build one domain fully, then repeat.

| Week | Domains |
|------|---------|
| 3 | `apex-security`, `apex-backend`, `apex-frontend` |
| 4 | `apex-testing`, `apex-devops`, `apex-architecture` |
| 5 | `apex-performance`, `apex-observability`, `apex-accessibility`, `apex-ai-systems`, `apex-data` |

Per domain: `SKILL.md` (Claude) + `impl.md` (DeepSeek) + agent definition + registry entry.

**Done when:** All 13 domains have dual-format skills and registered agents.

### Phase 4 — Governance (Week 6)
Make AFK safe and auditable.

- Autonomy level enforcement per level (L0–L5)
- Hard block list — permanently enforced
- Approval gate format — all gates use standard format
- Audit trail writer — L4+ sessions write to `docs/audit/`
- Token profiles — lean/balanced/thorough/custom implemented
- Per-session and per-spec token config overrides

**Done when:** AFK build runs within exactly what was declared, unlisted actions blocked, audit trail written at L4+.

### Phase 5 — Supporting Systems (Week 7)
Knowledge refresh, deep-dive, bug investigation.

- `apex-refresh` skill — full research pass, diff, approval, version bump
- `apex-refresh --audit` — staleness scan, informational only
- Skill metadata headers on all 13 domain skills
- `apex-deep-dive` skill — structured analysis output format
- `apex-debug` skill — 6-stage workflow + forensic mode

**Done when:** Refresh any skill with full research pass; run deep-dive on any domain; investigate bugs with full reproduce-isolate-fix-verify-prevent flow.

### Phase 6 — OSS Prep (Week 8)
Clean, documented, installable by others.

- `registry/skills.md` — canonical skill registry with compatibility scores
- `registry/agents.md` — canonical agent registry
- `registry/domains.md` — domain → skill + agent mapping
- System README — install, configure, use APEX
- Contribution guide — how to add a new domain
- All skills have version + sources + staleness threshold metadata

**Done when:** Someone else could install and use APEX from the README.

---

## 16. Risk Register

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Readiness gate too strict — specs never pass | Medium | Start with lighter gate, tighten after first 3 builds |
| Specialist agents bloat context in AFK builds | Medium | `max_specialists` cap in token config; default 2 |
| DeepSeek diverges from spec silently | Low-medium | Reviewer agent catches post-build; decisions logged in handoff |
| Skill refresh finds conflicting sources | Medium | Refresh workflow requires source ranking, not just synthesis |
| AFK build blocked by unlisted permission | Medium | Planning mode must be thorough in permissions manifest |
| Parallel workers produce conflicting file edits | Low | Code-writer dependency graph prevents parallel tasks on shared files |
| OSS contributors add unsafe specialist domains | Low (solo phase) | Contribution guide requires safety checklist per domain |

---

## 17. Acceptance Criteria

The system is working when:

- [ ] Every new project bootstraps with `docs/` structure automatically
- [ ] Orchestrator reads `docs/status.md` at every session start and surfaces in-flight work
- [ ] A spec written in planning mode passes the readiness gate before coding mode can start
- [ ] AFK build runs from start to handoff with zero questions asked
- [ ] Unlisted permission actions are blocked and logged, not silently executed
- [ ] Pause mid-session produces a confirmed checkpoint; resume picks up from it
- [ ] All 13 specialist domains have dual-format skills loaded on demand
- [ ] Specialists flag cross-domain issues but cannot activate other specialists
- [ ] `/apex-refresh` runs a full research pass, shows diff, requires approval
- [ ] Bug investigation follows all 6 stages; regression test always written
- [ ] Token profile changes take effect per session or per spec
- [ ] Audit trail written for L4+ sessions
- [ ] Technical docs written during planning; product docs written post-build
