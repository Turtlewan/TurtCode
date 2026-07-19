---
name: ab-revert-codex-worktree-trap
description: "To A/B a codex fix (prove the test goes red on old code), COPY the impl files first — never `git checkout HEAD --`, which destroys uncommitted worktree work irrecoverably"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b178d9e4-718b-4a93-8cec-df1dd0f19b75
---

Proving a fix is load-bearing by reverting the impl and re-running the new tests is standing
practice for every P1 (it is the only thing that separates a real gate from a lying one). But a
`codex exec` build leaves its changes **uncommitted in the worktree** — the build branch still
points at base. So `git checkout HEAD -- <impl>` (or `git checkout <build-branch> -- <impl>`)
does not "revert to the fix": it **destroys the fix with nothing to restore from**. Hit this on
2026-07-14; recovered only because the full diff was still in context.

**Why:** the fix exists solely in the working tree until the host integrates and commits it. Git
has no copy of it. Both `HEAD` and the build branch resolve to the pre-build base.

**How to apply:** before any A/B revert, `Copy-Item <impl> <scratchpad>/FIXED_<name>` for every
impl file, revert, run the test (expect RED), then restore by copying back — not by `git checkout`.
Verify the restore with `git diff --stat HEAD` against the stat you recorded before reverting.
Also: an A/B is only meaningful if the new test can still *collect* against the old code — a test
importing a new symbol (`_MAX_FRAME_BYTES`) dies at import and proves nothing; prove those
behaviourally with a standalone probe instead.

Related: [[worktree-integration-git-technique]], [[live-smoke-real-integrations]].

(migrated from Artemis memory 2026-07-19)
