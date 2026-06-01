# APEX Agent Registry

## Phase 1 Agents
(none — orchestration handled by skills)

## Phase 2 Agents (coding pipeline)

| Agent | File | Mode | Spawned by | Job |
|-------|------|------|-----------|-----|
| apex-coder | agents/apex-coder.md | DeepSeek | apex-code | Dependency analysis + parallel planning |
| code-worker | agents/code-worker.md | DeepSeek | apex-coder | Executes one isolated task |
| apex-reviewer | agents/apex-reviewer.md | DeepSeek | apex-code | Post-build advisory review |
| apex-docs-technical-agent | agents/apex-docs-technical-agent.md | Claude | apex-code | Writes handoff, ADRs |
| apex-docs-product-agent | agents/apex-docs-product-agent.md | DeepSeek | apex-code | Inline docs, changelog, README |

## Phase 3 Agents (domain review + tooling)

Planning-side **domain review** is one generic agent dispatched per domain (ADR-007), not a
per-domain roster:

| Agent | File | Mode | Activation |
|-------|------|------|-----------|
| apex-spec-reviewer | agents/apex-spec-reviewer.md | Claude | Dispatched by apex-plan to review a draft spec against one `apex-<domain>/SKILL.md`; auto-fired for the heavy set (security/auth/data/testing/a11y), judgment-fired otherwise |

Agents retained for domain-specific **tooling** (not review stubs):

| Agent | File | Mode | Activation |
|-------|------|------|-----------|
| apex-security-agent | agents/apex-security-agent.md | Both | security, auth, crypto keywords (Bash security verification) |
| apex-figma-agent | agents/apex-figma-agent.md | DeepSeek only | When spec includes a Figma URL (MCP / image steps) |

The post-build doc agents are listed in Phase 2 (`apex-docs-technical-agent`, `apex-docs-product-agent`).

_Retired 2026-06-01 (ADR-007): the 14 per-domain review/enforce stubs — accessibility, ai-systems,
animation, architecture, backend, data, design-system, devops, frontend, observability, performance,
testing, ui-testing, ui-ux-design. They were never dispatched; planning-side review is now the generic
`apex-spec-reviewer`, coding-side enforcement is `apex-coder` wave-workers loading `impl.md` inline._
