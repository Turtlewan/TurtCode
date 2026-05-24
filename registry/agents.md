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

## Phase 3 Agents (domain specialists)

| Agent | File | Mode | Activation |
|-------|------|------|-----------|
| apex-security-agent | agents/apex-security-agent.md | Both | security, auth, crypto keywords |
| apex-frontend-agent | agents/apex-frontend-agent.md | Both | React, Next, component, UI keywords |
| apex-backend-agent | agents/apex-backend-agent.md | Both | API, server, endpoint, database keywords |
| apex-architecture-agent | agents/apex-architecture-agent.md | Claude only | system design, ADR, scalability keywords |
| apex-devops-agent | agents/apex-devops-agent.md | Both | Docker, CI/CD, deploy, pipeline keywords |
| apex-testing-agent | agents/apex-testing-agent.md | DeepSeek only | When spec includes testing tasks only |
| apex-performance-agent | agents/apex-performance-agent.md | Both | slow, latency, N+1, profiling keywords |
| apex-observability-agent | agents/apex-observability-agent.md | Both | logging, metrics, tracing keywords |
| apex-accessibility-agent | agents/apex-accessibility-agent.md | Both | a11y, WCAG, ARIA keywords |
| apex-ai-systems-agent | agents/apex-ai-systems-agent.md | Both | LLM, RAG, embedding, vector keywords |
| apex-data-agent | agents/apex-data-agent.md | Both | migration, schema, ETL keywords |
| apex-docs-technical-agent | (see Phase 2) | Claude only | Always in planning |
| apex-docs-product-agent | (see Phase 2) | DeepSeek only | Always post-build |
| apex-ui-testing-agent | agents/apex-ui-testing-agent.md | DeepSeek only | When spec includes Storybook, Playwright, or axe-core tasks |
| apex-design-system-agent | agents/apex-design-system-agent.md | DeepSeek only | When spec adds components, tokens, or Storybook stories |
| apex-animation-agent | agents/apex-animation-agent.md | DeepSeek only | When spec includes Motion, GSAP, or scroll animation tasks |
| apex-ui-ux-design-agent | agents/apex-ui-ux-design-agent.md | Claude only | Pre-build quality gate for UI specs |
| apex-figma-agent | agents/apex-figma-agent.md | DeepSeek only | When spec includes a Figma URL |
