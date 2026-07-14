# APEX Agent Registry

Five agents. The per-domain agent roster was retired in two waves: the 14 review/enforce stubs in
2026-06-01 (ADR-007), and the last four tooling agents — `apex-security-agent`,
`apex-figma-agent`, `apex-docs-technical-agent`, `apex-docs-product-agent` — on 2026-07-14 with the
knowledge layer they enforced (ADR-036).

## Build pipeline

| Agent | Spawned by | Job |
|-------|-----------|-----|
| apex-coder | apex-code | Dependency analysis, wave grouping, parallel dispatch |
| code-worker | apex-coder | Executes one isolated task from a spec |
| apex-reviewer | apex-code | Post-build advisory review against the spec's acceptance criteria |

## Review gates

| Agent | Spawned by | Job |
|-------|-----------|-----|
| apex-spec-reviewer | apex-plan | Planning-side review of a draft spec — returns BLOCK / FLAG |
| apex-wave-reviewer | apex-code | Reviews a completed build wave — returns BLOCK / FLAG / CLEAN |

Both reviewers are **generic and parametrised**: what they review against is passed in, not baked
into a per-domain agent. With the domain skills gone, they review against the spec's own acceptance
criteria and `apex-coding-principles`. Cross-family routing holds (Codex builds → Claude reviews —
ADR-032).
