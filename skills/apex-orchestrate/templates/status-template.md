# Project: {name}
_{description}_

stack: {stack}
token_profile: balanced
autonomy_level: L2
specialists_default: []   # domains always active for routing regardless of keywords
stack_skills: []          # bound stack skills (apex-<framework>); coding reads their ## Verification Recipe (ADR-005/006)
coder_models: [flash]     # allowed coding models, subset of {flash, pro, codex} (ADR-024/026). Router picks per-task within this menu; 1 entry = no routing. flash/pro = DeepSeek backend; codex = OpenAI Codex (gpt-5.5), dispatched via `codex exec` subprocess, covering image/visual work + the hard-text ceiling (replaces the retired sonnet/opus coder tiers — Opus is now planner + reviewer-of-codex-tasks only). Default [flash] = backward-compatible (supersedes coder_tier_policy: flash|pro|split → [flash]|[pro]|[flash,pro])

_Last updated by planning mode:_ {YYYY-MM-DD}

<!-- CODING:START -->
## In-Flight
| What | Mode | State | File | Stopped at | Uncommitted |
|------|------|-------|------|------------|-------------|

_(empty — nothing in progress)_
<!-- CODING:END -->

<!-- PLANNING:START -->
## Pending Specs
| Spec | Summary |
|------|---------|

_(empty — no specs ready yet)_

## Open Questions
_(none)_
<!-- PLANNING:END -->
