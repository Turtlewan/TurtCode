---
name: sonnet-orchestrator-early-return
description: "Sonnet build-orchestrator subagents return early (\"I'll wait for the notification\") instead of supervising background codex exec; SendMessage nudge to foreground-poll fixes it — or avoid by dispatching codex exec as a foreground Bash call"
metadata: 
  node_type: memory
  type: project
  originSessionId: c3092c51-f27d-4fc7-aecc-baaaf9f1c3e1
---

Sonnet-model orchestrator subagents driving `codex exec` builds (role split per [[model-role-registry-doctrine]]) repeatedly stop early: they launch codex via a background Bash task, say "I'll wait for the completion notification", and exit — but their exit is the host's only signal, so the build dangles unsupervised. Happened 3× in one session (2026-07-06, W2-1/W2-2 builds), **even when the dispatch prompt pre-emptively demanded foreground supervision**.

**Why:** sonnet treats "background task + wait" as a natural stopping point; instruction alone does not reliably prevent it.

**How to apply:**
- Recovery that works every time: `SendMessage` nudge telling the orchestrator to resume and poll with BLOCKING sleep-and-check (30–60s foreground waits) until scoped verification is green. Both nudged runs then completed cleanly to full structured summaries.
- Better prevention: instruct orchestrators to run `codex exec` as a **foreground** Bash call with a long timeout (up to 600000ms, re-invoke in chunks if longer) instead of `run_in_background` + polling.
- Budget for 1 nudge per orchestrator when planning AFK builds; the builds themselves were unaffected (zero Codex recovery rounds).

**2026-07-09 refinement (5 more occurrences in one session):** foreground-dispatch prevention has a
hole — when the codex run outlives the orchestrator's own Bash command timeout, the orchestrator
falls back to backgrounding + waiting, reintroducing the failure. Two robust host-side moves:
(1) the SendMessage nudge still recovers every time (5/5); (2) when a nudged orchestrator goes quiet
again, **bypass it** — check the worktree directly (`git -C <wt> status/log`); if codex committed or
left a clean changed tree, host-verify + integrate yourself and let the stale agent rot. A
`Wait-Process`-on-the-codex-PID background watcher is a clean host-side completion signal that
doesn't depend on the orchestrator at all.

**2026-07-12 confirmation (3 more, ADR-055 workshop run):** the pattern held against every
escalation — explicit "NEVER end your turn / a Monitor will NOT resume you" brief language did not
prevent it (3/3 early-returned; one hallucinated a Monitor, one created a real one and still
returned). Treat the nudge as a STANDARD PIPELINE STEP, not an exception: dispatch orchestrator →
expect one early return → SendMessage nudge → completion (3/3 recovered). Faster alternative proven
same night: when the host sees the codex log's final summary block itself, **skip the orchestrator's
report entirely** — host-verify + commit directly; if doing so, SendMessage the orchestrator that
the host took over, else its late report misreads the committed tree as a phantom parallel session
(happened with the pinning build).

(migrated from Artemis memory 2026-07-19)
