---
name: worktree-integration-git-technique
description: "Parallel-worktree builds - current apex-code practice (per references/parallel-codex.md) integrates disjoint per-task files via path-scoped `git checkout <branch> -- <files>`; commit per-spec with path-scoped `git commit -- <paths>`"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f62fce28-2788-4603-a5ea-762f7999c602
  modified: 2026-07-29T09:16:27.412Z
---

**Reconciled 2026-07-29 against `apex-code/references/parallel-codex.md`:** current practice
integrates each parallel task's disjoint files with path-scoped `git checkout <branch> -- <that
task's files>` (never a bare `git merge` — hard block), because each wave's tasks are required to
write disjoint files by construction; a conflict there means the wave was mis-grouped and forks. The
2026-07-09 trap below (checkout not deleting branch-removed files / overwriting main-drifted files)
applies to the narrower case of integrating a branch whose file set isn't verified disjoint from
main's post-fork changes — for that case, `BASE=$(git merge-base HEAD <branch>); git diff $BASE
<branch> | git apply -3 --index` (carries deletions, 3-way-merges) remains a useful historical
fallback, not the standard path.

Two integration traps hit twice each in the 2026-07-09 14-spec batch build ([[codex-sandbox-flake-client-builds]] era, ADR-028/029 worktree flow):

1. `git checkout <branch> -- <dir>` does NOT delete files removed on the branch, and it overwrites files that advanced on main after the branch forked (reverted an already-committed sibling spec once) — a real risk only when the branch's files are NOT verified disjoint from concurrent main changes. When they are disjoint (the standard per-task/per-spec case), plain path-scoped checkout is correct and is what apex-code uses today. When disjointness isn't verified, fall back to `BASE=$(git merge-base HEAD <branch>); git diff $BASE <branch> | git apply -3 --index`.
2. Bare `git commit -m` commits EVERYTHING staged — in a multi-spec integration flow this bundles specs (happened twice; needed soft-reset splits). Use `git commit -m "..." -- <explicit paths>` for per-spec commits.

**Why:** worktree integration is overwrite-based; per-spec commit discipline dies silently without path scoping.
**How to apply:** any parallel-Codex (ADR-028/029) integrate→verify→commit loop.

3. (2026-07-09 mandate run) **`git mv` + commit promotes the INDEX blob, not the working tree.** An agent had edited a tracked draft in place; `git mv docs/drafts/x.md docs/changes/` + commit shipped the PRE-edit content while the working tree silently kept the edit — and a build worktree branched from the stale commit (mid-build course-correction needed). Detection signal: the file shows ` M` immediately after its own promote commit. Rule: after mv+commit of any agent-edited file, verify with `git show HEAD:<path>` (or `git add` the file explicitly before committing).

(migrated from Artemis memory 2026-07-19)
