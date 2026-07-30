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
**First commit the worktree to its task branch.** Coder output is uncommitted; `git checkout <branch> -- <files>` reads the branch TIP, so an uncommitted worktree integrates as a no-op. After the task's own verify passes, the integrator stages **path-scoped** with `git add -- <this task's authorized paths, worktree-relative>` (run **inside that worktree**; explicitly listed paths DO stage newly created files, so no `-A` is needed — and `-A` would absorb out-of-scope residue, defeating the D8 porcelain check). **If the worktree's gitignore excludes those paths** — as `~/.claude`'s blanket `*` does — use `git add -f -- <paths>`; force-add **only the name-listed authorized files**, never a directory or a glob. Then commit to `codex/<spec>-<task-id>` with message `build(<spec>): task <task-id>`. Only then integrate path-scoped into the main tree. **Deletions cannot be integrated this way (D7):** `git checkout <branch> -- <path>` cannot remove a file that is absent at the branch tip, so for every file the spec marks `Operation: delete` the integrator stages the removal on the integration branch directly with `git rm <path>` instead. The integrator here is the **host, acting as mechanics** under the wave plan (ADR-046 D1): executing the staging, the commit, and the path-scoped checkout exactly as directed is *within* host mechanics; deciding which tasks integrate, in what order, or whether a result passes is not. Builders still never commit — this commit is the host's, not the coder's.

Tasks in a wave write disjoint files, so bring each task's changes into the main tree with
`git checkout codex/<spec>-<task-id> -- <that task's files>`. Then run the recipe (AGENTS.md → `## Verify commands`) **on the integrated main tree** — this integrated-wave pass is the authoritative one. It does not replace the per-task pass each coder ran inside its own worktree; both cadences apply (per task in isolation during build, once integrated at integration). Ownership is split (ADR-046 D1). The host EXECUTES the recipe as mechanics from the orchestrator's wave plan and returns the raw results; the ORCHESTRATOR owns the pass/fail adjudication and the routing that follows. A merge
conflict means the wave was mis-grouped (non-disjoint files) → fork.

## Teardown
Teardown is permitted **only** under the D8 carve-out (ADR-046) — you created this worktree/branch, integration is complete, and **both** checks below pass. Teardown is permitted only after the verification defined in **ADR-046 § D8** (`~/apex/docs/technical/adr/ADR-046-doctrine-audit-resolutions.md`): `git worktree remove <path>` requires a clean worktree, and `git branch -D codex/<spec>-<task-id>` additionally requires an empty path-scoped branch diff, so branch deletion follows the approved per-spec integration commit. Ancestry checks are not valid evidence. **ADR-046 § D8 is the single canonical home of that algorithm — read it there; it is deliberately not restated here.** Any non-empty result, or any other branch, is a hard block. **And this is doctrine-level authorization, not a mechanical bypass:** `hooks/lib/destructive-detect.js` intercepts `git branch -d/-D` — and the path-scoped `git checkout … -- …` integration form — denying it or requiring confirmation per its own rules. The scoped mechanical allowance is the queued retro P5(c) hook change, out of scope here; until it ships, a permitted teardown executes via the user's `!` one-liner handback. If removal fails on Windows sandbox-SID-owned cache dirs, follow the **Windows sandbox** bullet under SKILL.md § Codex dispatch before retrying.

## Failure / fallback (ADR-027 unchanged)
A subprocess that exits non-zero / rate-limited → that task falls back to Sonnet 5 (fresh `model: sonnet` worker — ADR-032 as amended by A1, session-79b; quota-out skips the remaining effort rungs — the Codex pool is dead). A
quota-out on **any** concurrent subprocess means the pool is dead → stop launching further Codex and fall
back the remaining sub-wave tasks to Sonnet 5 (sequential — A1/ADR-045; Opus keeps the spec-author, build-orchestrator, and high-risk-reviewer roles). A task that won't converge after honest recovery → fork (capture-at-halt).

---

# Cross-spec parallel build (ADR-029)

Load when the trigger is **"build specs"** (a batch build over `docs/changes/*.md`), not a single-spec
build. This widens the pool above from "independent tasks within one spec's wave" to "independent tasks
across multiple ready specs." Everything above (worktree-per-task, `git checkout` integrate, teardown,
fallback) is reused.

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
