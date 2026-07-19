---
name: codex-scope-check-gitignore-false-positive
description: codex-dispatch scope check flags gitignored scratch → every build task false-exit-65s; verify with git status --porcelain instead
metadata: 
  node_type: memory
  type: feedback
  originSessionId: e06e970f-aaed-4828-9683-ea3bf1d7ae22
---

The `codex-dispatch.ps1` scope check counts **gitignored** files, so any build task that runs pytest (all of them) creates ignored scratch mid-run (`.codex-task*-tmp/`, `.artemis-verify-*/`, `.mypy_cache`, pytest temp) and the wrapper returns **exit 65 (scope violation)** even when the coder touched ONLY its authorized files. This is a FALSE POSITIVE, distinct from a real overreach.

**Why:** the scope check diffs the tree pre/post using a git command that includes ignored paths; `.gitignore` doesn't exclude them (confirmed: `.scratch-*/` and `.artemis-verify-*/` were already ignored yet still flagged). Separate from the shared-worktree build-guard defect the owner fixed 2026-07-15.

**How to apply:** on exit 65 during a Codex build, do NOT treat it as a spec defect reflexively — run `git status --porcelain` (gitignore-aware). If it shows ONLY the task's `-Authorized` files (no unexpected tracked/untracked-non-ignored source), it's the scratch false-positive → host-verify + commit normally. A REAL overreach would appear in porcelain. NOTE (2026-07-19): counting ignored paths is now BY DESIGN in `codex-scope-check.ps1` (`--ignored=traditional`, in-script rationale: an ignored file could hide a hook) — it will not be "fixed"; the durable remedies are gitignoring per-task scratch patterns AND porcelain adjudication. `rm -rf` is on the APEX destructive never-list (blocked) — gitignore scratch patterns rather than deleting. Related: [[codex-dispatch-ledger-wedge]].

(migrated from Artemis memory 2026-07-19)
