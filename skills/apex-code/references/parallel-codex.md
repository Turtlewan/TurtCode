# Parallel Codex dispatch — full procedure (ADR-028)

Load when a dependency (sub-)wave has **2+ independent `▸codex` tasks** and `max_parallel_codex > 1`.
**Engine is primary for eligible attended specs.** From the build repo in PowerShell, run `& "$env:USERPROFILE\.claude\skills\apex-code\scripts\apex-engine.ps1" -SpecPath <absolute> -Repo <absolute> -Attended -MaxParallel 2` (`1` for `risk: high`). The Engine selects and sequences manifest tasks, dispatches isolated workers, adjudicates integrated verification, retries, integrates, and hands off; HOST owns escalation decisions and close-out.
The attended HOST manual procedure below covers five static eligibility exclusions: **no execution manifest, undeclared shared-file tasks, multi-repo specs, `coder_model: sonnet`, and owner-directed escalation/fixes**. Engine eligibility requires file-disjoint tasks or declared chains. HOST selects and sequences those tasks, runs the structural checks in SKILL.md, dispatches workers, and adjudicates verification and recovery. Undeclared shared-file tasks run in separate waves from the preceding integrated tip; never waive a wave's disjointness checks.
**Every other Engine refusal is diagnosis-driven**, including validator failure, malformed manifest, repo mismatch, dirty paths, and missing verify contract. Read `engine-state.json` status **and diagnosis** when present; otherwise use the console `Engine refused: <message>` as the diagnosis. Fix the inputs/spec or choose attended HOST manual recovery from that diagnosis; refusal alone does not authorize bypassing safety checks. Exit 0 means build/hand-off complete with HOST close-out pending; 1 needs diagnosis and HOST/owner disposition; 2 means `awaiting-review` and follows SKILL.md's bound Critic review/resume procedure. Inspect partial work before manual recovery; unchanged specs resume, amended specs start a new run after permitted discard teardown.
Codex subprocesses are OS processes, not subagents, so the host can fan them out and collect them. The
Workflow / `apex-build-wave.js` path is NOT used here (its `agent()` spawns Claude-Code subagents, which
can't drive the external Codex CLI).

## Cap (machine protection, not a quota device)
`max_parallel_codex = max(1, min(4, floor(physical_cores / 2) − 1))` → **3** on this host, capped to the **default 2** below (A2, session-79b: two full waves ran sequentially with zero wall-clock pressure; the formula value stays documented for reference). Detect cores
(PowerShell `(Get-CimInstance Win32_Processor).NumberOfCores`); if detection is unavailable,
default **2** (A2). Override per spec with `max_parallel_codex` frontmatter (`1` = sequential = pre-ADR-028
behaviour). The default is **2** (A2; ADR-028 as amended); frontmatter sets the spec ceiling, and Engine `-MaxParallel` may lower it. A (sub-)wave wider than the cap splits into sequential
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
On the manual path, for each parallel task: `git worktree add <path> -b codex/<spec>-<task-id>` from the pinned wave base. Engine creates its own worktrees.

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

On the manual path, HOST launches the sub-wave's wrappers as background PowerShell processes; wait for all subprocesses to exit before
integrating. The `--json`/`-o`/log split is the standard observability recipe — give the user every
task's log path so they can use `Get-Content -LiteralPath <log> -Wait` in parallel (the host reads only each `.final`). Full
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

Engine honors committed `## Build outputs` declarations in HEAD's `AGENTS.md`, using the same
declaration grammar as scope-check/tree-pin, for ignored, untracked verify residue (`!!`). Only
paths at or below a declared entry are exempt; unignored (`??`), tracked, and undeclared paths
remain checked. Declaration lookup failure disables only the declared-output exemption. Copy
and stage remain limited to manifest files, including explicitly authorized ignored files.

**Manual recovery is attended HOST PowerShell only**, under the HOST's wave plan,
never by a coder or an unattended build. HOST dispatches Sonnet workers through `workflow-dispatch.md`
when pinned or owner-approved. Integrate tasks serially with this one procedure; for multi-repo
specs, use each repo's own pinned wave base, exact task paths and declared operations:

1. After task verification, the HOST stages only that task's named authorized paths **inside its
   worktree**, using `git add -- <paths>` (or `git add -f -- <paths>` for explicitly named ignored
   files, never a directory/glob or `-A`), and commits to `codex/<spec>-<task-id>` with message
   `build(<spec>): task <task-id>`. Builders still never commit. Verify that the branch records the
   task result and its authorized paths are clean; a diff from an uncommitted branch tip is a no-op.
2. Validate repo-relative literal file paths in both trees and the base/task commits: no traversal,
   directory, symlink/reparse point, submodule or unsafe ancestor. Require disjoint task path sets;
   quote every path, use `--`, and set `$env:GIT_LITERAL_PATHSPECS = '1'` in PowerShell.
   Precheck **each main path**: for modify/delete, `git hash-object --path "$p" "$p"` must equal
   the blob at `"${base}:$p"`; for create, the path must be absent at base, in the main worktree and
   in the index. Require the main index's existing entry to equal the base blob for modify/delete.
   Abort on any mismatch rather than overwriting host changes.
3. From the integration tree, set `$base` to the pinned wave base, `$branch` to
   `codex/<spec>-<task-id>`, and PowerShell array `$nonDeletePaths` to exactly this task's create/modify
   paths. Record the filtered hash of each task file with
   `git -C "$task_worktree" hash-object --path "$p" "$p"`; it must equal the task branch blob.
   **Immediately before each task apply, including any deletion via `git rm`,** capture the
   staged set as BEFORE. Use a temporary `$patch` outside every worktree; native Git writes it
   directly so PowerShell does not re-encode a binary patch. Run:

   ```powershell
   $env:GIT_LITERAL_PATHSPECS = '1'
   $before = @(git diff --cached --name-only --no-renames "$base")
   if ($LASTEXITCODE -ne 0) { throw 'Cannot capture BEFORE' }
   if ($nonDeletePaths.Count -gt 0) {
     git diff --binary "--output=$patch" "$base" "$branch" -- @nonDeletePaths
     if ($LASTEXITCODE -ne 0) { throw 'Cannot create task patch' }
     git apply --check --index -- "$patch"
     if ($LASTEXITCODE -ne 0) { throw 'Task apply check failed' }
     git apply --index -- "$patch"
     if ($LASTEXITCODE -ne 0) { throw 'Task apply failed' }
   }
   ```

   Every command must exit 0; abort on any failure. The array must exclude declared deletions.
   Before **each** `git rm -- "$p"` for `Operation: delete`, assert that the base contains a
   regular blob at that path and that the path is absent in **both the task branch and task
   worktree** (including dangling links). If it remains present there, **abort before `git rm`**;
   a declaration alone is insufficient (the same absence check as `Copy-EngineTaskFiles` and
   ADR-046 D7/D8). Then use `git rm -- "$p"` to integrate that declared deletion.
4. **Immediately after that task**, including all its deletions, capture AFTER:

   ```powershell
   $after = @(git diff --cached --name-only --no-renames "$base")
   if ($LASTEXITCODE -ne 0) { throw 'Cannot capture AFTER' }
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

Run the recipe (AGENTS.md → `## Verify commands`) **on the integrated tree** — Engine's integration
worktree, or the main tree on the manual path. This
integrated-wave pass is authoritative. It does not replace each coder's isolated per-task pass.
Engine owns integrated pass/fail adjudication on its path; HOST executes and adjudicates the recipe
on the manual path. An apply conflict or overlapping paths means the wave was mis-grouped
→ fork. Rollback restore outside the Engine routes through the owner's `!` handback; do not use
path checkout or an agent-issued worktree `git restore` to bypass the destructive-command guard.
After integration, HOST runs Critic, Scribe, family gate, and docs close-out against the integrated
tip per SKILL.md Post-build; Scribe uses a **fresh worktree from that tip**, not a task worktree.
For Engine success, complete close-out and the owner-approved commit so main HEAD and working
files match the integration tip before proof-gated `-Teardown <runId>`.

## Teardown
Engine teardown removes its own run's worktrees and branches. The host may remove worktrees when the owner says "remove", after proving no unique staged, working, untracked, or non-disposable ignored content is lost. Branch deletion and elevated cleanup run through `apex-cleanup.ps1 -Apply` in the owner's administrator shell. ADR-046 D8 as amended is the canonical proof and execution contract; the wrapper's existing teardown behavior and branch obligations are unchanged. See `~/apex/docs/technical/adr/ADR-046-doctrine-audit-resolutions.md`. **And this is doctrine-level authorization, not a mechanical bypass:** `hooks/lib/destructive-detect.js` intercepts `git branch -d/-D`, denying it or requiring confirmation per its own rules. The queued retro P5(c) mechanical allowance is **teardown only**; its integration allowance is retired. If removal fails on Windows sandbox-SID-owned cache dirs, follow the **Windows sandbox** bullet under SKILL.md § Codex dispatch before retrying.

## Failure / fallback
Engine failures route by durable status/diagnosis, or the console `Engine refused:` message when no
state exists. Its automatic effort retries stop at xhigh; HOST decides whether escalation needs an
amended-spec Engine run or attended manual recovery. Terminal verify failure or Critic reject needs
HOST-directed fixes, not an automatic model swap. Quota-out parks for **owner decision**: stop launching
further Codex; only owner-approved Sonnet fallback uses fresh `model: sonnet` workers on the attended
HOST manual path, sequentially. A whole-spec `coder_model: sonnet` pin takes that manual path directly.
Opus retains high-risk Critic review. A task that won't converge after honest recovery → fork (capture-at-halt).

---

# Cross-spec parallel build (ADR-029)

Load when the trigger is **"build specs"** (a batch build over `docs/changes/*.md`), not a single-spec
build. This widens the pool above from "independent tasks within one spec's wave" to "independent tasks
across multiple ready specs." Everything above (worktree-per-task, Engine byte copy / attended PowerShell
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
the Engine byte-copy / attended PowerShell `git apply --index` procedure above, never `git merge` (hard
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
