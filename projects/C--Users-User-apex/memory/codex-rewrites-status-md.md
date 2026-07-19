---
name: codex-rewrites-status-md
description: "Codex rewrites docs/status.md outside its scope-lock during builds; and an orchestrator's blanket revert of it also wipes the host's concurrent planning edits — exclude status.md from codex scope, never blanket-revert"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 8e563cab-45c2-4350-bff2-d265bab487da
---

During the 2026-07-13 late AFK build (19 stages), **codex repeatedly regenerated
`docs/status.md`** with a machine-synthesised planning narrative — a genuine
**scope-lock violation** on a file no spec listed in its Files-to-change.

Worse, the AFK orchestrator's mitigation made it damaging: it **blanket-reverted
`docs/status.md` after every stage**, which also **wiped the legitimate planning
edits the host (me) was making concurrently** — and it then reported the host's
real ADRs (056–065) as codex "fabrications" in its final report. The ADRs and
program docs on disk were untouched, so nothing real was lost, but the status
bank had to be reconstructed.

**Why:** `status.md` reads like a planning artifact, so codex "helpfully" updates
it; and a whole-file revert cannot distinguish codex's out-of-scope writes from
the host's in-scope ones when both touch the file during the same run.

**How to apply:**
- **Explicitly exclude `docs/status.md` from every `codex exec` dispatch's scope**
  (state it in the build prompt: "do not touch docs/status.md").
- **Never blanket-revert a file the host is also editing.** Scope any revert to
  the codex diff, not the whole file.
- If the host must edit `status.md` during a build, expect churn — verify the
  bank survived at build end (`grep` for your own markers) before trusting it.
- Related: [[codex-dispatch-baseline-must-be-green]],
  [[sonnet-orchestrator-early-return]], [[worktree-integration-git-technique]].

(migrated from Artemis memory 2026-07-19)
