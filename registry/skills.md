# APEX Skill Registry

The 14 skills. **There is no domain-specialist layer** — it was removed 2026-07-14 (ADR-036).
Domain knowledge is model-native; APEX carries only what a frontier model cannot derive: this
project's workflow, its state, and its gates.

## Spine — the session loop

| Skill | Mode | Purpose |
|-------|------|---------|
| apex-orchestrate | Both | Session start, mode detection, routing, pause/resume |
| apex-plan | Planning | Spec creation, readiness gate, ADRs |
| apex-code | Coding | Build execution — wave dispatch, verify loop |
| apex-handoff | Both | The coding↔planning handoff contract |
| apex-init | Planning | New-project bootstrap |
| apex-governance | Both | Autonomy levels, approval gates, hard blocks |

## Process

| Skill | Mode | Purpose |
|-------|------|---------|
| apex-debug | Both | Bug investigation — reproduce-first, root cause |
| apex-research | Planning | Source-grounded parallel research |
| apex-deep-dive | Planning | Uncertain-approach option analysis |
| apex-stack | Planning | Tech-stack selection for a new project |

## Meta — APEX maintaining itself

| Skill | Mode | Purpose |
|-------|------|---------|
| apex-skill-author | Planning | Authoring/editing skills — the Iron Law |
| apex-refresh | Planning | Skill currency refresh + quality stocktake |
| apex-context-budget | Planning | Context/token overhead audit |
| apex-coding-principles | Coding | Baseline code-quality rules (impl.md, auto-loaded by apex-code) |

## Routing

Skills are matched by Claude Code natively, from each skill's `description` frontmatter — **there is
no keyword table**. `apex-orchestrate` routes the session by signal (plan / build / debug / …); the
harness selects the rest.
