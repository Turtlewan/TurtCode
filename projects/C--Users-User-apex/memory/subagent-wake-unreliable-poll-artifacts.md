---
name: subagent-wake-unreliable-poll-artifacts
description: A subagent is NOT reliably re-woken when its own background commands finish — orchestrator subagents must poll for artifact files (or the host watches and nudges); observed twice in the 2026-07-16 build
metadata: 
  node_type: memory
  type: project
  originSessionId: 58b80d38-03b1-4bf3-a098-8c7a9f621f62
---

2026-07-16, Sonnet-orchestrated build: the orchestrator subagent dispatched Codex runs as
background commands and ended its turn to "wait for the completion notification" — which never
arrived, twice. The pipeline silently stalled both times with the work actually done on disk; the
host only noticed via the user asking "is it still working?".

**Why:** background-completion wake-ups reliably reach the MAIN session, but not a subagent that
has already ended its turn. A subagent waiting passively is a stall.

**How to apply:** orchestrator subagents must POLL in their own foreground (sleep loop on the
expected artifact file, e.g. the wrapper's `*.final` report in `$env:TEMP`) instead of ending their
turn to wait. Host-side backstop: arm a background watcher on the artifact file and nudge the
subagent via SendMessage when it lands ([[model-routing-four-roles]] makes this the host's job).

**Recurred 2026-07-18 (Wave B1, b3):** the orchestrator brief said "dispatch FOREGROUND (never
background)" TWICE and Sonnet still backgrounded task 1 and ended its turn. Prose in the brief does
not stick — put the constraint INSIDE the procedure step as the literal command shape ("one blocking
call; if your tool call times out, re-enter the poll loop"), and have the host expect one nudge per
build as normal cost, not an anomaly.
