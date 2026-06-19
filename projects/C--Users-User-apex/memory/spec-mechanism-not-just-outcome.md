---
name: spec-mechanism-not-just-outcome
description: "Spec tasks must state the producing mechanism, not just the outcome — a \"reuse X\" task can't achieve a behaviour X structurally lacks (P6-maths dead-heroes failure)"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 0fc1a8d3-f6f0-4d26-924c-2c0a9f8bca83
---

A spec acceptance criterion describing a *behaviour* must be backed by a task whose *mechanism* actually produces it. P6-maths C2/C4/C5 specs stated the outcome ("kit art + cue") but the task said "re-skin: reuse the existing `exchange` primitive" — and the router skips `mode: 'exchange'`, so the reused path could never emit `situation`. The rich components (DiscColumns/BlockTowers/CuboidBuilder) got built and left orphaned. (Distinct from the A2–A6 tail still being text — that was a deliberate proof-slice gate, not a divergence.)

**Why:** DeepSeek executes specs literally and can't infer a missing wiring step. APEX's readiness-gate coverage audit was *presence-only* (criterion → some task exists), so it passed a structurally-incapable task — the criterion mapped to a task, but the task's mechanism couldn't produce the criterion.

**How to apply:** When authoring a spec, for every *behavioural* acceptance criterion verify the mapped task's mechanism can produce it — especially "reuse/extend existing X" tasks: confirm X already exhibits the behaviour (check the codebase), else add an explicit wiring/producing step (e.g. "emit `situation` + route through the registry"). Never let an outcome-stated task omit the producing step. Now enforced by apex-plan's readiness-gate **Sufficiency audit** + the inline "tasks state the mechanism, not just the outcome" rule (v1.22.0). Related: [[parked-discussion-handover]] (literal-executor spec discipline), [[removal-over-prohibition]].
