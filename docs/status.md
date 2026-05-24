# APEX — Project Status

_Last updated by planning mode: 2026-05-24 (session 2)_

<!-- CODING:START -->
## Coding context

**Project:** APEX skill system (`~/.claude/`)
**Stack:** Markdown skill files, PowerShell hooks, Claude Code plugin system
**Build status:** All skills valid — no build step required

### Completed

| Spec | Status |
|------|--------|
| Phase 1 — Foundation | ✅ done |
| Phase 2 — Build pipeline | ✅ done |
| Phase 3 — Specialist domains (13) | ✅ done |
| Phase 4 — Governance L0–L5 | ✅ done |
| Phase 5 — Debug / Refresh / Deep-dive | ✅ done |
| Phase 6 — OSS prep (README, CONTRIBUTING) | ✅ done |
| GSD augmentation (4 core skills) | ✅ done |
| Source augmentation (17 existing skills) | ✅ done |
| New skills (6) | ✅ done |
<!-- CODING:END -->

<!-- PLANNING:START -->
## Planning context

### Pending specs

None — no specs in `docs/changes/`.

### What was done this session (2026-05-24)

**GSD-sourced updates (4 skills):**
- `apex-orchestrate` — context rot principle, auto-detect next step, rate limit recovery
- `apex-plan` — iterative readiness gate (loop until clean), package legitimacy check
- `apex-init` — PROJECT.md / REQUIREMENTS.md / ROADMAP.md persistent artifacts
- `apex-code` — package legitimacy pre-flight, fresh context note, rate limit pause

**Source-augmented existing skills (17):**
- `apex-debug` — Sentry MCP integration, doubt-driven review
- `apex-security` — Trail of Bits patterns, Snyk, Claude Code security review, AI threats
- `apex-observability` — Sentry/Grafana/OTel MCP tools, LLM observability
- `apex-frontend` — waterfall elimination, Radix/shadcn, Tailwind v4, INP replaces FID
- `apex-performance` — full Core Web Vitals thresholds, performance budgets
- `apex-governance` — two-stage review, scope guardrails, Claude Code Action
- `apex-handoff` — findings/progress persistence, session recovery, WIP commits
- `apex-deep-dive` — Context7 / Firecrawl / Repomix as research tools
- `apex-data` — Firecrawl/Repomix/Context7 for external data gathering
- `apex-devops` — Terraform/HashiCorp, Claude Code Action, Vercel deploy
- `apex-backend` — source-driven dev, doubt-driven review for auth
- `apex-accessibility` — WCAG 2.2 (upgraded from 2.1), axe-core, Radix
- `apex-refresh` — Context7 / Snyk / Firecrawl as research tools

**New skills created (6):**
- `apex-testing` — TDD, test pyramid, Playwright MCP, axe-core
- `apex-ui-ux-design` — industry design reasoning, 67 UI styles, pre-delivery checklist
- `apex-design-system` — shadcn/ui, Radix, Tailwind v4, Storybook, component library map
- `apex-animation` — Motion vs GSAP selection, prefers-reduced-motion rules, timing guide
- `apex-figma` — official Figma MCP + Framelink, design-to-code workflow
- `apex-ui-testing` — Playwright, Storybook, Chromatic, axe-core E2E

**Registry:** `domains.md` updated to 20 domains (was 13).
**README:** `APEX-README.md` updated to reflect all 20 domains.

### Open questions

- No outstanding open questions.

### What was done this session (2026-05-24 session 2)

**impl.md written for all 5 UI/design skills:**
- `apex-ui-testing/impl.md` — Storybook, Playwright, axe-core patterns
- `apex-design-system/impl.md` — shadcn/ui, Tailwind v4 @theme, Radix patterns
- `apex-animation/impl.md` — Motion enter/exit, GSAP scroll, reduced-motion rules
- `apex-ui-ux-design/impl.md` — interactive states, form validation, empty/error patterns
- `apex-figma/impl.md` — design-to-code workflow, token mapping, auto layout → Flexbox

**Agent files written for all 5 UI/design skills:**
- `agents/apex-ui-testing-agent.md`
- `agents/apex-design-system-agent.md`
- `agents/apex-animation-agent.md`
- `agents/apex-ui-ux-design-agent.md` (Claude-only planning gate)
- `agents/apex-figma-agent.md`

**Registry updated:**
- `registry/domains.md` — all 5 UI/design rows now have impl.md + agent paths; duplicate testing row removed
- `registry/agents.md` — 5 new agents added to Phase 3 table

**CONTRIBUTING.md updated:** UI/design section now shows all 5 domains as ✅ complete

### What's next

- Run `/apex-refresh --audit` to check staleness of updated skills after ~14 days
- Consider source-augmenting the 5 new impl.md files once real projects use them (gather evidence first)
- `apex-architecture` is the only core domain still missing impl.md
<!-- PLANNING:END -->
