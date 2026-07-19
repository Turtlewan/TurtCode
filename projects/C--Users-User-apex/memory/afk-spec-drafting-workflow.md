---
name: afk-spec-drafting-workflow
description: Artemis planning cadence — present time = decisions/briefs only; spec drafting + reviews run AFK via background agents
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 0d9d37f0-a264-465b-a03a-130f3b24b49a
---

Agreed 2026-06-08. The user wants terminal/present time spent on the interactive planning
conversation only; all spec **drafting** and other long-running work (dispatched reviews, research,
deep-dives) happen **while they are away from the computer**.

The cadence (overrides apex-plan's "main session drafts inline"):
1. **Present — elicitation sprint:** resolve every judgment fork (one question at a time, per
   [[questions-one-at-a-time]]), identify seams, and write a compact **Spec Brief** to
   `docs/briefs/<spec>.md` — intent + resolved decisions + seams/symbols + scope/file set +
   acceptance shape + which review domains to dispatch. NOT the full spec.
2. **Away — delegate ALL drafting:** spawn **one background agent per brief** (`run_in_background`)
   that drafts the full Deep Details spec → dispatches its own security/auth review → applies
   findings → runs the readiness gate → marks `ready`, or parks with `[NEEDS CLARIFICATION]` if the
   brief left a gap. The user chose **delegate-all** (every spec AFK, regardless of risk), accepting
   that a cold agent is lower-assurance, with brief-quality + dispatched-review + gate + the user's
   return-time digest-check as the guardrails.
3. **Return — confirmation digests:** present digests (files / acceptance / decisions), resolve any
   parked forks live.

**Standing authorization:** spawning the AFK drafting + review agents for this workflow is
pre-approved — do NOT stop to ask per-spawn (it would stall the away-phase). Scoped to this drafting
workflow, not blanket agent-spawning. Extends [[sp0-parallel-agents-authorized]] beyond SP0.

**Why:** the user's keyboard time is the scarce, high-bandwidth resource; drafting is slow boilerplate
once decisions are made. Splitting decision (present) from drafting (away) maximises the judgment-dense
interaction and moves the wait offline.

**How to apply:** in a present session, run elicitation sprints that output briefs, then on the
"I'm heading off / draft them" signal, fan out background drafters and let the user leave. Constraint
to state: in-session background agents only survive while the terminal stays open — shutdown-survival
needs a scheduled cloud routine (repo-access caveat). The brief is load-bearing: front-load every
decision into it so the agent never has to guess.

**File-write constraint (observed 2026-06-09):** in PLANNING mode, background sub-agents CANNOT persist
files — the PreToolUse hook's non-interactive write is denied (even for `.md`/`docs/`). The working
pattern: brief the agent to **return the full drafted artifact in its result**, and the **main planning
agent writes it to disk** (the main agent's `.md` writes succeed). So AFK agents = draft + self-review +
park-seams + RETURN content; orchestrator = persist + reconcile parks. Budget for the larger return.

(migrated from Artemis memory 2026-07-19)
