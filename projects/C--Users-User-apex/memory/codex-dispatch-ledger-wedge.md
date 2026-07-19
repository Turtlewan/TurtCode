---
name: codex-dispatch-ledger-wedge
description: "codex-dispatch.ps1 wedges pre-launch (no pid, empty log) when the run-ledger holds a stale live row; the REAL ledger is under %LOCALAPPDATA%\\apex, not .claude"
metadata: 
  node_type: memory
  type: project
  originSessionId: 87f80b66-3b53-448b-99e7-5906719ce0d5
---

`scripts/codex-dispatch.ps1` can hang **before launching Codex at all** — no PID in the ledger, an
empty log file, zero output from the wrapper, and your own call eventually dies at the harness
timeout. It is NOT Codex failing (`codex --version` works fine); it is the wrapper's
shared-worktree guard blocking on a **stale `running`/`adopting` row** in the run ledger.

**The trap that cost an hour on 2026-07-15:** the live ledger is at
`%LOCALAPPDATA%\apex\progress\codex-run-ledger.jsonl` (`$apexStateRoot = $env:LOCALAPPDATA\apex`).
There is a **legacy copy at `~/.claude/docs/progress/codex-run-ledger.jsonl` that nothing reads** —
editing that one changes nothing and looks like the fix failed. Confirm the path by tracing the
script (`Set-PSDebug -Trace 1` inside a `Start-Job`), don't assume.

**It self-amplifies.** Each blocked dispatch reserves its own ledger row *before* launching, then
hangs and gets killed — leaving another orphan (`pid: None`) behind. Retrying feeds the jam. One
stale row from a prior session became six.

**Recovery:** `-Adopt` will NOT close a row whose coder left no `.final` ("a missing verdict is not
a passing one") — it deliberately leaves it for a human. So verify liveness yourself
(`Get-Process -Id <pid>`), then rewrite the dead rows' `status` to something outside
`running`/`adopting`. Back the ledger up first.

Diagnosis order that works: `codex --version` (rules out the CLI) → look for the log under
`%LOCALAPPDATA%\apex\progress\codex-logs\` (NOT `<repo>/docs/progress/` — the log was moved out of
the judged tree deliberately) → dump live rows for the worktree → check each PID.

**Second flavor (2026-07-17): killing the wrapper kills the codex child.** Run the wrapper as a
harness BACKGROUND task, never under a foreground shell timeout — when the timeout killed the
wrapper mid-run, the codex process died with it (log stops mid-item, no `.final` written) and the
ledger row stuck at `running`, which then feeds the stale-row jam above. It *looked* alive for an
hour (stale row + old log). Liveness check: `Get-Process -Id <ledger pid>` + log LastWriteTime,
not the row.

Related: [[codex-exec-stdin-wedge]], [[codex-dispatch-needs-a-quiet-tree]],
[[codex-dispatch-baseline-must-be-green]].

(migrated from Artemis memory 2026-07-19)
