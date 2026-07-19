---
name: worktree-integration-git-technique
description: "Parallel-worktree builds - integrate via `git diff base..branch | git apply -3 --index`, never checkout-a-directory; commit per-spec with path-scoped `git commit -- <paths>`"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f62fce28-2788-4603-a5ea-762f7999c602
---

Two integration traps hit twice each in the 2026-07-09 14-spec batch build ([[codex-sandbox-flake-client-builds]] era, ADR-028/029 worktree flow):

1. `git checkout <branch> -- <dir>` does NOT delete files removed on the branch, and it overwrites files that advanced on main after the branch forked (reverted an already-committed sibling spec once). Use `BASE=$(git merge-base HEAD <branch>); git diff $BASE <branch> | git apply -3 --index` — carries deletions, 3-way-merges shared files, works from any base.
2. Bare `git commit -m` commits EVERYTHING staged — in a multi-spec integration flow this bundles specs (happened twice; needed soft-reset splits). Use `git commit -m "..." -- <explicit paths>` for per-spec commits.

**Why:** worktree integration is overwrite-based; per-spec commit discipline dies silently without path scoping.
**How to apply:** any parallel-Codex (ADR-028/029) integrate→verify→commit loop.

3. (2026-07-09 mandate run) **`git mv` + commit promotes the INDEX blob, not the working tree.** An agent had edited a tracked draft in place; `git mv docs/drafts/x.md docs/changes/` + commit shipped the PRE-edit content while the working tree silently kept the edit — and a build worktree branched from the stale commit (mid-build course-correction needed). Detection signal: the file shows ` M` immediately after its own promote commit. Rule: after mv+commit of any agent-edited file, verify with `git show HEAD:<path>` (or `git add` the file explicitly before committing).

(migrated from Artemis memory 2026-07-19)
