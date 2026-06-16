---
name: background-work-overlap
description: "When a long background task is running (research or build), keep the foreground conversation productive — carry on questioning the user on specs instead of going idle"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: eac6c01b-73ac-4d7c-84d0-e9998e5d93a0
---

When dispatching a long-running background task (`run_in_background` research agent, or a build), do NOT go silent and wait. Keep the foreground conversation productive — continue questioning the user on the spec, drafting the next spec, or resolving open items. When the background task notifies completion, fold its results into the live conversation.

**Why:** Pipelining. Overlapping a long task with continued interactive planning means the user is never idle waiting — it speeds up their work with Claude.

**How to apply:**
- Background research that *feeds* the open questions of the spec being worked on, then keep eliciting the rest of that spec in the foreground.
- Or background the build of a *different, already-ready* spec while questioning/drafting the next one.
- Sequencing constraint: the spec actively being questioned can't itself be backgrounded yet (it's unresolved) — background only research that informs it, or an already-ready different spec.
- Planning mode (Windows) = research-in-background fits today; build-in-background mostly applies in coding sessions (DeepSeek/Mac).
- Reinforces [[user-autonomy-preference]] — keep the human productive; don't stall on long waits.
