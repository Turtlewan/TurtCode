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
printf '%s' "<task prompt>" | codex exec -p apex-coder --sandbox workspace-write -m gpt-5.6-sol -C <worktree> \
  --json -o <scratch>/codex-<task>.final --color never > docs/progress/codex-<task>.log 2>&1
```

Launch every task in the sub-wave with `run_in_background`; wait for all subprocesses to exit before
integrating. The `--json`/`-o`/log split is the standard observability recipe — give the user every
task's log path so they can `tail -f` each one in parallel (the host reads only each `.final`). Full
recipe + teardown → `references/codex-observability.md`.

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
A subprocess that exits non-zero / rate-limited → that task falls back to Opus (fresh `model: opus` worker — ADR-032; quota-out skips the remaining effort rungs — the Codex pool is dead). A
quota-out on **any** concurrent subprocess means the pool is dead → stop launching further Codex and fall
back the remaining sub-wave tasks to Opus (sequential). A task that won't converge after honest recovery
→ fork (capture-at-halt).

---

# Cross-spec parallel build (ADR-029)

Load when the trigger is **"build specs"** (a batch build over `docs/changes/*.md`), not a single-spec
build. This widens the pool above from "independent tasks within one spec's wave" to "independent tasks
across multiple ready specs." Everything above (worktree-per-task, `git checkout` integrate, teardown,
fallback) is reused.

## One shared cap — the load-bearing safety rule
Cross-spec parallelism draws from the **same** `max_parallel_codex` pool as within-spec parallelism — it
is NOT multiplied per spec. Three ready Codex tasks from three different specs fill the same 3 slots that
three tasks from one spec would. Without this, N specs × their tasks exhaust the host.

## Wave grouping = TWO constraints (both already declared in every spec)
Build a *spec DAG* at the start of the batch, then group specs into waves. Two specs may share a wave
only if BOTH hold:
1. **Dependency-independent** — neither is in the other's transitive `## Prerequisites` closure.
2. **File-disjoint** — their `## Files to Change` path sets do not intersect.

**Dependency-independence is NOT file-disjointness.** Two specs with no prerequisite edge can still
modify the same file — real cases: two "carrier" specs both adding fields to `ports/types.py`, or any
two specs in the same package both re-exporting into its `__init__.py`. Integration is
`git checkout <branch> -- <file>` (overwrite, never `git merge` — hard block), so two concurrent specs
writing one file **silently clobber**. So **file overlap is an implicit serialization edge**: put the
overlapping specs in different waves (the later one rebased after the earlier integrates). Do not invent
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
