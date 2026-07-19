---
name: dispatch-survives-only-native-background
description: A BACKGROUNDED codex-dispatch survives the turn only via host harness-native run_in_background (Start-Job + subagent-background both reaped); but a subagent FOREGROUND-BLOCKING dispatch survives (completes in-turn) — so Sonnet CAN own a build via foreground code-workers (round-8 W1)
metadata: 
  node_type: memory
  type: project
  originSessionId: 04486d28-1528-4572-bab2-2f8a50197759
---

Dispatching a `codex exec` build subprocess is long (30–90 min). What keeps it alive across the
launcher's turn boundary:

- **Host, harness-native `run_in_background`** (Bash/PowerShell tool `run_in_background: true`) —
  SURVIVES. Every step-2 host dispatch completed this way.
- **Subagent-owned background dispatch** — DIES when the subagent ends its turn. Killed the first
  Wave-1 attempts twice; the fix was to make the HOST run every dispatch and the subagent only
  plan/route.
- **`Start-Job` + separate poll loop** — DIES: the job handle does not persist across separate tool
  invocations, and the child is reaped when its parent PowerShell exits.

Also: a subagent's `run_in_background` from *within* the workflow runtime is fine, but a subagent
that `Start-Job`s then ends its turn loses it.

- **Subagent-owned FOREGROUND-BLOCKING dispatch** — SURVIVES. The reaping above is specifically about
  dispatches that *outlive the turn* (backgrounded / Start-Job). A blocking `codex-dispatch.ps1` Bash
  call inside a code-worker completes *within* the worker's turn, so there is nothing to reap. Proven
  2026-07-17 round-8 W1: a **Sonnet** orchestrator spawned 6 code-workers, each blocking-foreground on
  one Codex dispatch (two sub-waves of 3, isolated git worktrees), and the whole build completed clean.
  So **Sonnet CAN own build execution** this way — the "host owns execution" rule below is only forced
  when a dispatch must be BACKGROUNDED (long build, don't-block-the-turn). Cost of foreground: the ~10-min
  Bash timeout caps a single task; fine for small fixes, not for a 30–90-min build.

**How to apply:** for a build that must background (long, or you want the turn free), the HOST owns the
`run_in_background: true` launch and arms its OWN watcher (background poll on the `*.final` report, with
child-PID death-detection) — the completion wake is unreliable. For a build whose per-task dispatches fit
under the foreground Bash timeout, a **Sonnet orchestrator with foreground-blocking code-workers** owns
execution end-to-end and returns one completion — no host watcher needed. Gotcha (round-8 W1): building in
temp worktrees + integrating by file-copy leaves NO ledger row keyed to the real tree, so the executable
`apex-family-gate` can't vouch (exits 13) even though cross-family review happened — host becomes
reviewer-of-record. [[subagent-wake-unreliable-poll-artifacts]] is the wake half; this is the survival half.
