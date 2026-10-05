# Parallel Codex dispatch — full procedure (ADR-028)

Load when a dependency (sub-)wave has **2+ independent `▸codex` tasks** and `max_parallel_codex > 1`.
The host runs them as **concurrent background `codex exec` subprocesses** (Bash `run_in_background`) — **as mechanics only**: launching and monitoring the subprocesses strictly from the build orchestrator's wave plan and returning status/exit codes to it. Task selection, sequencing, routing, verification, retries, and close-out stay orchestrator-owned (ADR-045 as amended 2026-07-29; ADR-046 D1).
Codex subprocesses are OS processes, not subagents, so the host can fan them out and collect them. The
Workflow / `apex-build-wave.js` path is NOT used here (its `agent()` spawns Claude-Code subagents, which
can't drive the external Codex CLI).

## Cap (machine protection, not a quota device)
`max_parallel_codex = max(1, min(4, floor(physical_cores / 2) − 1))` → **3** on this host, capped to the **default 2** below (A2, session-79b: two full waves ran sequentially with zero wall-clock pressure; the formula value stays documented for reference). Detect cores
(`nproc` / PowerShell `(Get-CimInstance Win32_Processor).NumberOfCores`); if detection is unavailable,
default **2** (A2). Override per spec with `max_parallel_codex` frontmatter (`1` = sequential = pre-ADR-028
behaviour). The default is **2** (A2; ADR-028 as amended); a spec's `max_parallel_codex` frontmatter is the only override. A (sub-)wave wider than the cap splits into sequential
sub-waves of ≤cap (mirrors `worker_cap`). Each `codex exec` runs the full local toolchain, so keep the
cap well below the Workflow's `min(16, cores−2)`.

The wrapper enforces capacity per resolved state root, not by host-side counting. Before pre-flight it
holds the shared ledger mutex while it marks dead unresolved rows `orphaned`, totals live `leasing`,
`running`, `stalled`, and `adopting` build rows, checks both `-MachineCeiling` (state-root-wide) and the
spec's `max_parallel_codex`, and appends the new `row_kind:"lease"`. Normal build leases weigh 1 and
`ultra` leases weigh 2; review/read-only leases weigh 0. Wrappers using different state roots are not
in one capacity pool. A successful launch converts its lease to `row_kind:"dispatch"`; a pre-flight
refusal closes the lease with an append-only `row_kind:"lease_close"` event.

**Exit 79 is a queue signal, not model failure.** The refused task stays queued and is retried only
after an occupying lease/dispatch reaches terminal state; do not fall back, lower/bypass the cap, or
launch outside the wrapper. Because capacity refusal occurs before lease acquisition, it leaves no
lease, dispatch row, or dispatch log. The sole possible artifact is a `row_kind:"obligation"` event
when `-OwnedWorktree` teardown could not discharge its creator-owned cleanup.

## Isolation = git-worktree-per-task
For each parallel task: `git worktree add <path> -b codex/<spec>-<task-id>` from HEAD.

```powershell
# -Authorized paths are WORKTREE-RELATIVE, never absolute
& "$env:USERPROFILE\.claude\skills\apex-code\scripts\codex-dispatch.ps1" `
  -Spec <spec> -Task <task-id> -Phase build -Worktree <worktree> -BaseSha <sha> `
  -SpecSourcePath <abs path to the spec> `
  -Prompt "<the dispatch pack>" `
  -Authorized @('src/a.py','tests/test_a.py') `
  -Effort <coder_effort>
```

**Never hand-roll a raw pipe into `codex exec`** — `hooks/codex-dispatch-guard.js` hard-blocks a raw `codex exec` in Bash and PowerShell, and the raw path has no ledger, no watchdog, no `-Adopt`, and does not read the verdict. The wrapper owns the `--json`/`-o`/log split; the log path it prints is what the user tails. Full observability contract → `references/codex-observability.md`.

Launch every task in the sub-wave with `run_in_background`; wait for all subprocesses to exit before
integrating. The `--json`/`-o`/log split is the standard observability recipe — give the user every
task's log path so they can `tail -f` each one in parallel (the host reads only each `.final`). Full
recipe + teardown → `references/codex-observability.md`.

## Integrate (NOT `git merge` — hard block)
**Primary procedure: Engine integration.** After each task's own verify passes, the Engine uses
`Copy-EngineTaskFiles` in `scripts/engine-git.ps1` to copy the task worktree's bytes, then
`Stage-EngineWave` to stage the declared paths. `Restore-EngineWave` restores the wave base on
rollback, including removing paths absent at base and verifying restored index/filtered working
hashes. These helpers are operation-aware (`create`, `modify`, `delete`) and path-safe: they refuse
escaping paths, directories, reparse points, and unsafe commit entries. Copy verifies source and
destination **raw SHA-256** equality. A create must be absent at base; modify/delete must exist at
base; a delete must be absent in the task worktree before the Engine removes the integration file.
Any failed check aborts integration. The Engine consumes uncommitted task files; no task-branch
commit is needed for byte copy.

**Current limitation:** Engine integration parks repos whose `## Build outputs` verify creates
ignored directories until **`engine-build-output-residue`** ships. Use the attended manual fallback
below for those repos; declaring the outputs does not yet exempt them from the Engine residue scan.

**Manual fallback is attended HOST Bash only**, executed as mechanics under the orchestrator's
wave plan (ADR-046 D1), never by a coder or an unattended build. Integrate tasks serially with this
one procedure; use the pinned wave base, exact task paths and declared operations:

1. After task verification, the HOST stages only that task's named authorized paths **inside its
   worktree**, using `git add -- <paths>` (or `git add -f -- <paths>` for explicitly named ignored
   files, never a directory/glob or `-A`), and commits to `codex/<spec>-<task-id>` with message
   `build(<spec>): task <task-id>`. Builders still never commit. Verify that the branch records the
   task result and its authorized paths are clean; a diff from an uncommitted branch tip is a no-op.
2. Validate repo-relative literal file paths in both trees and the base/task commits: no traversal,
   directory, symlink/reparse point, submodule or unsafe ancestor. Require disjoint task path sets;
   quote every path, use `--`, and set `GIT_LITERAL_PATHSPECS=1` for the Bash commands below.
   Precheck **each main path**: for modify/delete, `git hash-object --path "$p" "$p"` must equal
   the blob at `"$base:$p"`; for create, the path must be absent at base, in the main worktree and
   in the index. Require the main index's existing entry to equal the base blob for modify/delete.
   Abort on any mismatch rather than overwriting host changes.
3. From the integration tree, set `base` to the pinned wave base, `branch` to
   `codex/<spec>-<task-id>`, and Bash array `non_delete_paths` to exactly this task's create/modify
   paths. Record the filtered hash of each task file with
   `git -C "$task_worktree" hash-object --path "$p" "$p"`; it must equal the task branch blob.
   **Immediately before each task apply, including any deletion via `git rm`,** capture the
   staged set as BEFORE. With Bash `set -e` and `set -o pipefail`, run:

   ```bash
   set -e
   set -o pipefail
   export GIT_LITERAL_PATHSPECS=1
   BEFORE=$(git diff --cached --name-only --no-renames "$base")
   if ((${#non_delete_paths[@]})); then
     git diff --binary "$base" "$branch" -- "${non_delete_paths[@]}" | git apply --check --index
     git diff --binary "$base" "$branch" -- "${non_delete_paths[@]}" | git apply --index
   fi
   ```

   Both pipes must exit 0; abort on either failure. The array must exclude declared deletions.
   Before **each** `git rm -- "$p"` for `Operation: delete`, assert that the base contains a
   regular blob at that path and that the path is absent in **both the task branch and task
   worktree** (including dangling links). If it remains present there, **abort before `git rm`**;
   a declaration alone is insufficient (the same absence check as `Copy-EngineTaskFiles` and
   ADR-046 D7/D8). Then use `git rm -- "$p"` to integrate that declared deletion.
4. **Immediately after that task**, including all its deletions, capture AFTER:

   ```bash
   AFTER=$(git diff --cached --name-only --no-renames "$base")
   ```

   Treat BEFORE and AFTER as exact path sets: assert **AFTER minus BEFORE equals exactly that
   task's full path set** (create, modify and delete), and **BEFORE minus AFTER is empty** (no
   removals from the prior staged set). Abort on extra, missing or removed paths; do not defer
   these assertions to the end of the wave. For line-based capture, refuse newline-containing
   paths and decode Git-quoted names before comparing identities.
5. Postcheck each non-delete main file: `git hash-object --path "$p" "$p"` must equal the recorded
   task file's filtered hash; verify the index blob matches too. These are **filtered** hashes,
   including with `core.autocrlf=true`, not raw-byte comparisons. Deleted paths must remain absent
   in the main worktree and index. Abort on any mismatch. Raw `git show <sha>:<p> > <p>` is **not
   equivalent**: it bypasses working-tree conversion and indexed-apply checks.

Run the recipe (AGENTS.md → `## Verify commands`) **on the integrated main tree** — this
integrated-wave pass is authoritative. It does not replace each coder's isolated per-task pass.
The HOST executes the recipe as mechanics and returns raw results; the ORCHESTRATOR owns pass/fail
adjudication and routing. An apply conflict or overlapping paths means the wave was mis-grouped
→ fork. Rollback restore outside the Engine routes through the owner's `!` handback; do not use
path checkout or an agent-issued worktree `git restore` to bypass the destructive-command guard.

## Teardown
Teardown is permitted **only** under the D8 carve-out (ADR-046) — you created this worktree/branch, integration is complete, and **both** checks below pass. Teardown is permitted only after the verification defined in **ADR-046 § D8** (`~/apex/docs/technical/adr/ADR-046-doctrine-audit-resolutions.md`): `git worktree remove <path>` requires a clean worktree, and `git branch -D codex/<spec>-<task-id>` additionally requires an empty path-scoped branch diff, so branch deletion follows the approved per-spec integration commit. Ancestry checks are not valid evidence. **ADR-046 § D8 is the single canonical home of that algorithm — read it there; it is deliberately not restated here.** Any non-empty result, or any other branch, is a hard block. **And this is doctrine-level authorization, not a mechanical bypass:** `hooks/lib/destructive-detect.js` intercepts `git branch -d/-D`, denying it or requiring confirmation per its own rules. The queued retro P5(c) mechanical allowance is **teardown only**; its integration allowance is retired. Until it ships, a permitted teardown executes via the owner's `!` one-liner handback. If removal fails on Windows sandbox-SID-owned cache dirs, follow the **Windows sandbox** bullet under SKILL.md § Codex dispatch before retrying.

## Failure / fallback (ADR-027 unchanged)
A subprocess that exits non-zero / rate-limited → that task falls back to Sonnet 5 (fresh `model: sonnet` worker — ADR-032 as amended by A1, session-79b; quota-out skips the remaining effort rungs — the Codex pool is dead). A
quota-out on **any** concurrent subprocess means the pool is dead → stop launching further Codex and fall
back the remaining sub-wave tasks to Sonnet 5 (sequential — A1/ADR-045; Opus keeps the build-orchestrator and high-risk-reviewer roles; specs are authored by gpt-6-sol (ADR-048)). A task that won't converge after honest recovery → fork (capture-at-halt).

---

# Cross-spec parallel build (ADR-029)

Load when the trigger is **"build specs"** (a batch build over `docs/changes/*.md`), not a single-spec
build. This widens the pool above from "independent tasks within one spec's wave" to "independent tasks
across multiple ready specs." Everything above (worktree-per-task, Engine byte copy / attended Bash
indexed-apply integration, teardown, fallback) is reused.

## One shared cap — the load-bearing safety rule
Cross-spec parallelism draws from the **same** `max_parallel_codex` pool as within-spec parallelism — it
is NOT multiplied per spec. Three ready Codex tasks from three different specs fill the same slots (default 2) that
three tasks from one spec would. Without this, N specs × their tasks exhaust the host.

## Wave grouping = TWO constraints (both already declared in every spec)
Build a *spec DAG* at the start of the batch, then group specs into waves. Two specs may share a wave
only if BOTH hold:
1. **Dependency-independent** — neither is in the other's transitive `## Prerequisites` closure.
2. **File-disjoint** — their `## Files to Change` path sets do not intersect.

**Dependency-independence is NOT file-disjointness.** Two specs with no prerequisite edge can still
modify the same file — real cases: two "carrier" specs both adding fields to `ports/types.py`, or any
two specs in the same package both re-exporting into its `__init__.py`. Integration is
the Engine byte-copy / attended Bash `git apply --index` procedure above, never `git merge` (hard
block); concurrent writes to one file violate its base/path checks. So **file overlap is an implicit
serialization edge**: put overlapping specs in different waves (the later one rebased after the earlier integrates). Do not invent
a new spec tag — these two existing fields are sufficient.

**Conservative paths.** A spec whose `## Files to Change` lists a directory or a fuzzy path ("the ingest
path — confirm exact file from M8-b1") is treated as touching that whole subtree → serialize it against
anything else under that subtree.

## Supervision gate — parallel-safe is not parallel-eligible
Two specs passing both safety constraints still do **not** background if either is **high-risk**
(`risk: high`, or an auth / security / data domain — the same set apex-code already dual-pass-reviews).
Parallel dispatch runs several specs unattended at once; the high-risk set is exactly what earns close,
one-at-a-time **host supervision** (the ability to react, not just to read), so it runs **sequentially in
the foreground** instead (and does not fan its own tasks into the pool either). The live log
(`references/codex-observability.md`) is written for every spec regardless, so this gate is about
intervention, not visibility — background specs are no longer blind. **Opt-out default:** routine `risk: low`/unmarked
specs are pool-eligible; only the high-risk set is excluded. (This differs from the review gate, where
an *absent* `risk` defaults to cautious — there absence means "be careful"; here it means "routine.")

## Per-spec boundaries — parallelism is build-phase only
Each spec builds in its own worktree(s) from HEAD. As it completes, it integrates, runs **its own**
Verification Recipe, and commits under per-spec commit discipline — **sequentially, in dependency
order**. The parallel win is the overlapped *build* phase; integrate→verify→commit is serial. A merge
conflict at integration means the disjointness check was wrong (or a fuzzy path resolved to a shared
file) → fork that spec (capture-at-halt).

## Throughput reality (set expectations honestly)
The win concentrates **across modules/clusters** (specs in different package subtrees). It is throttled
**within a module** by the shared `__init__.py` + any shared contract/types file, and is **zero** for a
serial-by-design chain (e.g. a ledger A→B→C→D). The per-spec `mypy`/test verify is a sequential floor —
pipeline a spec's verify under the next spec's build where possible.

## Adoption gate
A project still driven by a standalone per-spec runbook (e.g. Artemis's `CODEX-BUILD-RUNBOOK.md`) cannot
consume a spec DAG — it must migrate onto apex-code (mechanic A) before cross-spec parallel applies.
