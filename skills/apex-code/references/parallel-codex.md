# Parallel Codex dispatch — full procedure (ADR-028)

Load when a dependency (sub-)wave has **2+ independent `▸codex` tasks** and `max_parallel_codex > 1`.
The host runs them as **concurrent background `codex exec` subprocesses** (Bash `run_in_background`) —
Codex subprocesses are OS processes, not subagents, so the host can fan them out and collect them. The
Workflow / `apex-build-wave.js` path is NOT used here (its `agent()` spawns Claude-Code subagents, which
can't drive the external Codex CLI).

## Cap (machine protection, not a quota device)
`max_parallel_codex = max(1, min(4, floor(physical_cores / 2) − 1))` → **3** on this host. Detect cores
(`nproc` / PowerShell `(Get-CimInstance Win32_Processor).NumberOfCores`); if detection is unavailable,
default **3**. Override per spec with `max_parallel_codex` frontmatter (`1` = sequential = pre-ADR-028
behaviour; status.md carries the project default). A (sub-)wave wider than the cap splits into sequential
sub-waves of ≤cap (mirrors `worker_cap`). Each `codex exec` runs the full local toolchain, so keep the
cap well below the Workflow's `min(16, cores−2)`.

## Isolation = git-worktree-per-task
For each parallel task: `git worktree add <path> -b codex/<task-id>` from HEAD, then pipe the same prompt
+ autonomy clause as the sequential path:

```
printf '%s' "<task prompt>" | codex exec -p apex-coder --sandbox workspace-write -m gpt-5.5 -C <worktree>
```

Launch every task in the sub-wave with `run_in_background`; wait for all subprocesses to exit before
integrating.

## Integrate (NOT `git merge` — hard block)
Tasks in a wave write disjoint files, so bring each task's changes into the main tree with
`git checkout codex/<task-id> -- <that task's files>`. Then run the spec's Verification Recipe **once on
the integrated main tree** as the authoritative gate (each Codex already self-verified inside its
worktree; the integrated re-verify catches project-wide issues like a whole-repo typecheck). A merge
conflict means the wave was mis-grouped (non-disjoint files) → fork.

## Teardown
`git worktree remove --force <path>`, then delete the branch. If removal fails on Windows
sandbox-SID-owned cache dirs, clear them with the codex-exec cleanup trick (SKILL.md § Windows sandbox
artifact ownership) before retrying.

## Failure / fallback (ADR-027 unchanged)
A subprocess that exits non-zero / rate-limited → that task falls back to Opus (host builds it inline). A
quota-out on **any** concurrent subprocess means the pool is dead → stop launching further Codex and fall
back the remaining sub-wave tasks to Opus (sequential). A task that won't converge after honest recovery
→ fork (capture-at-halt).
