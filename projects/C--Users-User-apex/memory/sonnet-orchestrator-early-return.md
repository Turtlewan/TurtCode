---
name: sonnet-orchestrator-early-return
description: "Sonnet build-orchestrators reliably end their turn early after backgrounding a codex exec dispatch and re-wake remains unproven — keep the SendMessage nudge / host-bypass pipeline; but as of the 2026-07-30 harness the backgrounded process itself SURVIVES the turn end (kill behavior refuted by live probes, version-pinned)"
metadata: 
  node_type: memory
  type: project
  originSessionId: c3092c51-f27d-4fc7-aecc-baaaf9f1c3e1
  modified: 2026-07-31T15:14:39.070Z
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

**Merged (2026-07-29, folded from two now-deleted source memories on dispatch survival and subagent
wake reliability):** Sonnet build-orchestrators reliably end their turn
early after backgrounding a codex exec dispatch and are never re-woken on completion — only
host-native `run_in_background` (Bash/PowerShell tool, not a subagent's own `Start-Job`) or a
subagent's own FOREGROUND-BLOCKING call survives the turn boundary. A subagent-owned background
dispatch dies when the subagent ends its turn; a subagent that blocks in its own foreground on one
`codex exec` call (fits under the ~10-min Bash timeout) completes in-turn and needs no nudge — proven
2026-07-17 round-8 W1, a Sonnet orchestrator spawning 6 foreground-blocking code-workers across two
sub-waves, whole build clean. For a dispatch that must background (long build, turn must stay free),
recover via a SendMessage nudge telling the orchestrator to resume and POLL in its own foreground
(sleep-and-check on the expected artifact, e.g. the wrapper's `*.final` report) rather than passively
waiting — treat this nudge as a standard pipeline step, budgeted at ~1 per build, not an exception.
If a nudged orchestrator goes quiet again, bypass it entirely: check the worktree directly
(`git -C <wt> status/log`), host-verify + integrate, and SendMessage the orchestrator that the host
took over (else its late report misreads the committed tree as a phantom parallel session). A
`Wait-Process`-on-the-codex-PID background watcher is a clean host-side completion signal independent
of the orchestrator.

(migrated from Artemis memory 2026-07-19)

**2026-07-30 live reverification (issue-13 root-cause probes, `apex/docs/research/issue13-kill-ceiling-rootcause-2026-07-30.md`):** the *process-death* half of this memory no longer reproduces on the current harness — a subagent-backgrounded process now SURVIVES the subagent's turn end (ran 200/200 heartbeats over 17 min, through the old 8–10-min kill band), and a foreground tool-timeout now MIGRATES the call to background instead of killing the tree. Still true and still the operative guidance: orchestrators may end their turn early and their re-wake on background completion remains unproven — keep the SendMessage nudge / host-bypass pipeline. What changed is the blast radius: an early return no longer kills the dispatch *while the session stays active*; the codex child keeps running and the worktree/ledger can be host-verified directly. Resolved same evening: a 40-min host-backgrounded probe survived ~29 min of fully idle session and completed (idle-reap refuted); the two terminated probes (E4/E5a) coincided with the owner's active window and were classified manual stops. Net: on the 2026-07-30 harness, background dispatches survive turn end AND session idle; no kill ceiling exists. Behavior is harness-version-pinned — re-verify with a ≥12-min probe before relying on it in a shipped workflow.

**2026-07-31 partial counter-evidence (wrapper-hygiene repair session):** host-native `run_in_background` PowerShell dispatches were externally stopped 3 of 6 times (task status "killed"), at ~1.5-4 min in, and each stop killed the WHOLE tree — codex child pid dead, log frozen at the stop moment, no `.final` (owner confirmed the first two stops were not manual; cause unattributed). AND a foreground dispatch that hit the 10-min tool ceiling (exit 143) also had its whole tree killed — codex + launcher dead, log frozen, verified by process scan + 45 s log-growth wait — contradicting the 07-30 "timeout migrates to background" observation. Operative guidance now: any dispatch that can exceed 10 min is killable either way; before re-dispatching repairs onto UNCOMMITTED build state, copy the tree aside (`Copy-Item -Recurse` to scratchpad) since a mid-write kill leaves partial edits with no git checkpoint; recover each kill with `-Adopt` (closes the row `adopted-blocked`); if kills persist, detach via a scheduled task (`schtasks /sc once`) which runs outside the session's process tree.
