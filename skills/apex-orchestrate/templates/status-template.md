# Project: {name}
_{description}_

stack: {stack}
token_profile: balanced
autonomy_level: L2
specialists_default: []   # domains always active for routing regardless of keywords
stack_skills: []          # bound stack skills (apex-<framework>); coding reads their ## Verification Recipe (ADR-005/006)
coder_models: [codex]     # allowed coding models, subset of {codex, opus} (ADR-027). codex = OpenAI Codex (gpt-5.5), the PRIMARY coder, dispatched per task via `codex exec` subprocess (covers text + image); opus = the MANUAL fallback coder (Claude coding mode, APEX_MODE=coding) when Codex quota is exhausted. Default [codex]. DeepSeek flash/pro are ARCHIVED (ADR-027, recovery-only); a legacy coder_tier_policy maps to [codex].
max_parallel_codex: 3     # project default cap on concurrent `codex exec` subprocesses per wave (ADR-028); machine-protection rate dial, not a quota cap. Auto-sized min(4, floor(cores/2)−1); 1 = sequential.

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
