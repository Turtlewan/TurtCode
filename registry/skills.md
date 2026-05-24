# APEX Skill Registry

## Core Skills (Phase 1)

| Skill | File | Mode | Purpose |
|-------|------|------|---------|
| apex-orchestrate | skills/apex-orchestrate/SKILL.md | Both | Session start, routing, pause/resume |
| apex-init | skills/apex-init/SKILL.md | Planning | New project bootstrap |
| apex-plan | skills/apex-plan/SKILL.md | Planning (Claude) | Spec creation, readiness gate |
| apex-code | skills/apex-code/SKILL.md | Coding (DeepSeek) | AFK build, edit mode |
| apex-handoff | skills/apex-handoff/SKILL.md | Both | Bidirectional handoff protocol |

## Pipeline Skills (Phase 2)

| Skill | File | Mode | Purpose |
|-------|------|------|---------|
| apex-review | skills/apex-review/SKILL.md | Coding | Post-build code review |

## Domain Specialist Skills (Phase 3)

| Skill | SKILL.md (Claude) | impl.md (DeepSeek) |
|-------|------------------|-------------------|
| apex-security | skills/apex-security/SKILL.md | skills/apex-security/impl.md |
| apex-frontend | skills/apex-frontend/SKILL.md | skills/apex-frontend/impl.md |
| apex-backend | skills/apex-backend/SKILL.md | skills/apex-backend/impl.md |
| apex-architecture | skills/apex-architecture/SKILL.md | — (Claude only) |
| apex-devops | skills/apex-devops/SKILL.md | skills/apex-devops/impl.md |
| apex-testing | — (DeepSeek only) | skills/apex-testing/impl.md |
| apex-performance | skills/apex-performance/SKILL.md | skills/apex-performance/impl.md |
| apex-observability | skills/apex-observability/SKILL.md | skills/apex-observability/impl.md |
| apex-accessibility | skills/apex-accessibility/SKILL.md | skills/apex-accessibility/impl.md |
| apex-ai-systems | skills/apex-ai-systems/SKILL.md | skills/apex-ai-systems/impl.md |
| apex-data | skills/apex-data/SKILL.md | skills/apex-data/impl.md |
| apex-docs-technical | skills/apex-docs-technical/SKILL.md | — (Claude only) |
| apex-docs-product | — (DeepSeek only) | skills/apex-docs-product/impl.md |

## Supporting Skills (Phase 5)

| Skill | File | Mode | Purpose |
|-------|------|------|---------|
| apex-debug | skills/apex-debug/SKILL.md | Both | Bug investigation, root cause analysis |
| apex-refresh | skills/apex-refresh/SKILL.md | Planning | Full skill knowledge refresh |
| apex-deep-dive | skills/apex-deep-dive/SKILL.md | Planning | Specialist deep research mode |
