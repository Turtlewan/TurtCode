---
skill: apex-code
version: 2.22.0
last_updated: 2026-10-06
sources:
  - docs/technical/adr/ADR-027-codex-primary-opus-fallback-deepseek-archived.md
  - docs/technical/adr/ADR-028-parallel-codex-dispatch.md
  - docs/technical/adr/ADR-029-cross-spec-parallel-build.md
  - docs/technical/adr/ADR-030-codex-reasoning-effort-dial.md
  - docs/technical/adr/ADR-031-codex-context-propagation.md
  - docs/technical/adr/ADR-032-gpt56-role-split.md
  - docs/technical/adr/ADR-036-remove-knowledge-layer.md
  - docs/technical/adr/ADR-037-three-context-files.md
  - docs/technical/adr/ADR-038-single-session.md
  - docs/technical/adr/ADR-045-four-role-split.md
  - docs/technical/adr/ADR-046-doctrine-audit-resolutions.md
  - docs/technical/adr/ADR-048-role-redesign.md
staleness_threshold: 30d
description: >
  APEX build workflow — executes docs/changes/ specs: attended Engine builds, HOST
  manual/AFK dispatch, verify vs AGENTS.md, forks, HOST close-out. Codex `gpt-5.6-sol`
  is the coder; owner-approved Sonnet 5 fallback. Loads when building a spec.
---

# APEX Build Workflow

**This skill carries the machinery, not the judgment.** How to execute a spec carefully — verify
assumptions before coding, don't build on red, keep scope surgical, verify per task, never weaken a
test to go green, don't silently redesign — is **model-native** and was cut in v2.0.0 after four RED
probes reproduced all of it cold (ADR-036). What remains is what a bare agent cannot know: APEX's
artifacts, the exact invocations, and the traps that only surface on a second pass.

## Session start

1. `git log --oneline -10` — what landed recently.
2. Read `docs/status.md` — In-Flight rows + `autonomy_level`.
3. Read the repo's **`AGENTS.md`** — its `## Verify commands` are the recipe, and its conventions
   and hard rules bind this build (ADR-037). Codex reads the same file natively, so host and coder
   run the same contract by construction.
4. List `docs/changes/*.md`. Report: "Ready specs: {list}. In-progress: {spec or none}."

No ready specs → "No specs in `docs/changes/`. Want me to plan one?" (same session — apex-plan).

**Context discipline:** read the spec and the files it lists. Not `docs/handoff/`, not other specs,
not ambient project docs.

## Pre-flight

- **`## Assumptions`** — verify each against the codebase *now*. Wrong + impact `Stop` → halt, log,
  report. Wrong + `Caution`/`Low` → log the deviation, proceed.
- **`## Files to Change`** is a **scope lock** for the whole build. A file not listed is a blocked
  action: log it, don't touch it, surface it in the handoff. Re-check before touching any file. A fork that needs to build "in the real place" (§ Forks) does **not** widen the lock by prose — prose cannot change the wrapper's `-Authorized` list, so a write there still trips exit 65. **The HOST amends the spec's `## Files to Change` and re-dispatches the task with the updated `-Authorized` list**, recording why in the decisions table and the handoff. The lock is never widened in-flight; it is re-issued.
- **Load `~/.claude/skills/apex-coding-principles/impl.md`** now — before any dispatch or write, not at verify time.
- **Invariant freshness (ADR-033 A3):** if the spec predates an ADR shift, check its `## Intent`
  invariants still hold. A contradiction is a wrong `Stop` assumption — halt and flag.
- **`coder_effort`** frontmatter `{low|medium|high|xhigh|max|ultra}`, default `medium`.
- AFK build → capture `run_base_sha = git rev-parse HEAD` now (for the end-gate).

## Engine path (default, attended)

Eligible attended builds use the Engine: one repo, an execution manifest, file-disjoint tasks, and Codex. No manifest, shared-file tasks, multi-repo, `coder_model: sonnet`, or owner-directed escalation/fixes use the attended HOST manual path (`references/parallel-codex.md`). AFK/unattended uses HOST mechanics below.

```powershell
& "$env:USERPROFILE\.claude\skills\apex-code\scripts\apex-engine.ps1" -SpecPath <absolute> -Repo <absolute> -Attended -MaxParallel 2
```

Use `-MaxParallel 1` for `risk: high`. Read the run's `engine-state.json` **status and diagnosis** whenever it exists. With no state, use console `Engine refused: <message>` as the diagnosis; fix the inputs/spec or take the attended HOST manual path.

- **Exit 0:** Engine build/hand-off complete; HOST close-out pending. Run § Post-build Critic/Scribe/family gate/docs close-out against the integrated tip, using fresh worktrees where those steps require them. Obtain the owner-approved commit so main HEAD equals the integration tip and working files match it; only then run proof-gated `apex-engine.ps1 -Teardown <runId>`.
- **Exit 1:** refused/parked/failed/partial/quota-paused, distinguished by state when present (`paused` plus quota diagnosis means quota-paused). Diagnose, adjust the spec or seek owner disposition; apply § Forks as HOST actions. No automatic Sonnet swap: quota fallback requires owner approval and uses the attended HOST manual path.
- **Exit 2:** `awaiting-review`, only for `risk: high` specs. Run Opus Critic for the integrated wave, binding its record to that wave's review tree digest, then invoke `apex-engine.ps1 -Resume <runId> -ReviewVerdict clean|reject -ReviewDigest <64 lowercase hex> -ReviewRecord <existing absolute path outside every Git worktree>`. An `awaiting-review` run resumes only with all three review flags together; bare `-Resume` is refused; the record must be a normalized absolute path to a strict UTF-8 file. Rejection parks; HOST fixes manually or starts an amended-spec run.

An unchanged spec in a parked/paused run resumes with `apex-engine.ps1 -Resume <runId>` (pending review still requires the three review flags). An amended spec starts a **new run**, only after the parked run's partial work is inspected and discarded via `apex-engine.ps1 -Teardown <runId> -Discard` when permitted; never amend a live run's immutable plan. Discard teardown is for non-complete runs and refuses live children/non-terminal ledger rows; successful complete teardown requires hand-off and commit proof, without `-Discard`.

## Wave analysis — HOST manual/AFK path

**Who does this:** the Engine owns eligible attended grouping, sequencing, integration, verification and completion routing. The **HOST** performs these mechanics for AFK/unattended and Engine-refused manual builds; **HOST close-out applies on every path** (§ Post-build). Raw results are bounded exit codes, `.final` fields, verify tails and porcelain output, never whole logs. Read producer events unchanged (§ Events); surface missing/malformed events rather than reconstructing or patching them.

**Deterministic structural checks — HOST-performed** before any manual/AFK wave launches and at each adjudication: **(a) Cap arithmetic** — wave slots must not exceed `max_parallel_codex` (default 2; risk:high sequential), `ultra` counts double, and total tasks across all waves must not exceed **64**. **(b) Per-repo authorized-path disjointness** — no path may EQUAL, be an ANCESTOR of, or be a DESCENDANT of another task's path within a wave; equal relative paths in different repos do not collide. **(c) `authorized` ⊆ `## Files to Change`** — reduce both to the same repo-relative form first. **(d) Executability minimums** — no empty authorized set (wrapper exit 74), repos, waves or wave. **(e) Repo and verify-contract integrity** — each task's repo must equal a declared repo; each repo's verify contract must be an existing absolute path. **(f) Terminal adjudication arithmetic** — at most one complete per turn and no duplicate task IDs; no completion while any task lacks a terminal verdict, is PARKED, lacks successful integration, or lacks a valid hex integration tree digest (including null/unverifiable). Request verify for an unpinned tree, then park if still unpinned. A violation requires HOST re-plan or park; retain build state across manual/AFK turns.

Two tasks may run in parallel iff `writes(A) ∩ writes(B) = ∅` **and** neither writes what the other
reads **and** they share no exclusive resource.

**Two traps — both cost a silent clobber, and neither shows up as a git conflict:**

1. **File-disjointness is necessary, not sufficient** (ADR-029). Dependency-independence and
   file-disjointness are different tests; a spec can pass one while failing the other. Run both.
2. **The collision is usually in files the spec didn't enumerate** — the shared substrate: a package
   `__init__.py`, a declarative `Base`, a barrel re-export, a route registry, a migration head. Two
   workers each create it, last write wins, and verification may still pass with one model silently
   missing from the metadata.

**Unsure whether B depends on A → sequential.** The costs are asymmetric: wrongly-sequential costs
wall-clock (visible, recoverable); wrongly-parallel costs a silent clobber that propagates.

Log the plan before executing: `Wave 1: [task N, task M] | Wave 2: [task P]`.

**Dispatch:** `wave_dispatch: workflow` (spec frontmatter, else status.md, else `inline`) + 2+
independent tasks → dispatch the wave via `apex-build-wave.js` rather than inline Agent calls, so
worker transcripts stay out of this window (ADR-015). Mechanics → `references/workflow-dispatch.md`.
Same-tree parallel workers collide on lockfiles, ports, caches and the git index — use
`isolation: "worktree"` (inline) / `isolate: true` (workflow). Cap: `max_parallel_codex` (default 2 — A2, session-79b).

## Codex dispatch — the coder

**Layer A -- classify authorized files before every build dispatch:**

```powershell
powershell.exe -NoProfile -File "$env:USERPROFILE\.claude\skills\apex-code\scripts\apex-critical-files.ps1" -Test -Root <repo-root> -Paths path1 path2 path3
```

Use the task's `-Authorized` paths, space-separated after `-Paths`. Never use `-Paths a,b,c`: under `-File` that arrives as one literal string, classifies nothing, and silently exits 0.

- Exit **0**: no critical path; dispatch normally.
- Exit **11**: permanent hard block (for example, `docs/audit/`) -- **REFUSE the task entirely**; it must never be built, even with confirmation.
- Exit **10**: critical path. If **ATTENDED**, run the existing governance approval gate; only the
  user's real "yes" permits dispatch with `-CriticalFilesConfirmed -CriticalFilesConfirmedNote
  "attended <who> <when>"`. If AFK, `dontAsk`, or otherwise autonomous with no human present, **PARK** and surface the task instead of dispatching it.

**Host-state authoring:** the six matchers are `docs/status.md`, root `AGENTS.md`, root `CLAUDE.md`,
`docs/changes/`, `docs/handoff/`, and any path whose basename is `codex-run-ledger.jsonl`.
Authorizing any of them -- including bare directory grants `docs/changes` or `docs/handoff` -- requires attended `-CriticalFilesConfirmed`; an unattended/AFK dispatch that tries to authorize one refuses with exit **76** by design: **PARK** the task. **Sole exception (D6, ADR-046):** the docs agents' three host's-pen artifacts — the handoff doc, `docs/status.md`, and spec archival into `docs/changes/done/` — are written by the docs agents during an AFK close-out and reviewed by the host before session close. That exception covers those three artifacts and nothing else; every other host-state authorization still parks. **Interim mechanics:** under AFK the harness may silently deny a docs-agent's off-list write (`dontAsk` inheritance); until the permissions follow-up ships (queued retro set), the **HOST performs the three artifacts' writes itself** — they are host bookkeeping (state-keeping) under the session licence clause, so no gate is crossed. The docs agents are the host's pen whenever the harness permits; the host is always a valid writer of its own three artifacts. Remaining gap: a broader directory grant (for example, all of `docs`) still slips literal-token classification until D6 post-hoc write classification (Wave B2); see ADR-044 D3 consequence (a).

A spec's `## Permissions` text does **not** satisfy Layer A; only a live attended human confirmation
does. Layer B's exit 76 mechanical backstop proves the confirmation switch was passed, but not who supplied it. Layer A owns that provenance check, so unattended work must park.

Every task tagged `▸codex` (the default). Assemble the **dispatch pack** — Goal → Context →
Constraints → Done-when — per `references/dispatch-pack.md`, then **always dispatch through the
wrapper**:

```powershell
# -SpecSourcePath: the spec's real home, required on cross-tree builds
# -Authorized: the task's Files-to-Change paths, WORKTREE-RELATIVE (never absolute)
# -Effort: omit at medium
& "$env:USERPROFILE\.claude\skills\apex-code\scripts\codex-dispatch.ps1" `
  -Spec <spec> -Task <task> -Phase build -Worktree <repo-root> -BaseSha <sha> `
  -SpecSourcePath <abs path> `
  -Prompt "<the dispatch pack>" `
  -Authorized @('src/a.py','tests/test_a.py') `
  -Effort <coder_effort>
```

**Never hand-roll `printf … | codex exec …`.** You now *can't* — a `PreToolUse` hook
(`hooks/codex-dispatch-guard.js`) hard-blocks a raw `codex exec` in Bash or PowerShell. This
sentence existed in prose for weeks and **three consecutive real builds bypassed it anyway**, with
the ledger sitting frozen while they ran. That is the Iron Law's own rule landing on APEX itself:
mechanism beats instruction, *including when you are the one writing the instruction*.

Four things are load-bearing, and each has already broken a real build when done by hand:

1. **stdin.** Codex needs the prompt *on* stdin, but backgrounding a process wants stdin *closed* —
   so a reflexive `< /dev/null` clobbers the pipe and Codex reports *"No prompt provided via
   stdin"* (live failure, 2026-07-14). Passing the prompt as a bare argument hangs instead. The
   wrapper writes to the child's stdin and closes it, with **no shell redirect anywhere in the
   path**, so neither failure is reachable.
2. **Scope.** `-Authorized` arms the host-side scope check (`scripts/codex-scope-check.ps1`, called
   by the wrapper — never run it by hand): snapshot before launch, compare after exit, and **report**
   anything unauthorized. **It reverts nothing.** Omit `-Authorized` and the scope lock is prose only
   — *proven not to work*: Codex has been given that rule, in those words, and written outside it
   anyway. **Exit 65 = out-of-scope writes, still sitting in the tree. Exit 66 = the `-Authorized`
   list itself is wrong** (the task wrote several files and none is on it — fix the spec, not the
   coder). See AGENTS.md's optional **`## Build outputs`** for committed declarations of ignored,
   untracked verify outputs; undeclared or tracked paths remain checked. Engine integration still
   parks on ignored output directories until `engine-build-output-residue` ships — use the attended
   HOST manual integration procedure in `references/parallel-codex.md` for those repos.
3. **Durability** — run ledger, no-output watchdog, `-Adopt` recovery after a host crash.
4. **The verdict.** The wrapper reads the coder's own `.final` report and **fails on `blocked`**.
   Hand-rolled, you get an exit code — and the exit code lies: Codex exits **0** while its report
   says `blocked`. On `cap-deps-1b` (2026-07-14) that unread `blocked` — *"the sandbox can no longer
   launch helpers, so implementation cannot be inspected, corrected, or verified"* — was committed,
   and the next spec was built on top of it.

**The wrapper's exit codes are the contract. Route on them, not on the log and not on a hunch:**

| Exit | Meaning | What you do |
|------|---------|-------------|
| 0 | done | Verify, review, commit. |
| 65 | scope violation | **Spec defect** — the task needed a file its spec didn't list. **Nothing was reverted; the changes are still in the tree.** Read them, then surface to planning; don't just re-run. |
| 66 | bad `-Authorized` list | The task wrote several files and *none* is on the list — the **list** is wrong, not the coder. |
| 67 | **blocked** | **HARD STOP.** Do not commit. Do not build a dependent spec on top. Clear every `unresolved` item with a host re-verify first. Outranks every other code. |
| 68 | done_with_concerns | The coder finished but flagged doubts. Read them; carry them into the review. |
| 69 | **tree moved under a gate or at the launch boundary** | The verdict is **VOID** — it describes a tree that no longer exists. This also fires when the tree moves between the pre-flight pin and the launch boundary. By then the reservation **HAS occurred**, so the ledger row **EXISTS** and is updated `failed` / `tree-moved` (unlike exit 72, which refuses before reservation and creates no row). Find the writer, let it finish, re-run the gate. |
| 71 | shared worktree refused | A coder is already live here. `git worktree add` one per concurrent task, or go serial. |
| 72 | refused: red baseline | The pre-dispatch pre-flight found a red/unparseable/recipe-less baseline or refused spec validation. NOTHING was launched and NO ledger row exists. Fix the baseline/spec; for cross-tree builds pass `-SpecSourcePath <abs path>`, or use `-SkipBaselineCheck` for a bootstrap. |
| 73 | **double-encoded text (mojibake)** | Codex-on-Windows corrupted non-ASCII it wrote (em-dash → `—`). **Do not commit — the suite is green and wrong.** The coder writes the same bad bytes into the *expected* string, so the assertion compares corrupt to corrupt and passes. Fix the bytes, re-verify. |
| 74 | refused: scope lock | A workspace-write build dispatch had an empty -Authorized scope list and no -ScopeUnlocked escape, OR a contradictory/incomplete flag combination. `-ReviewedRunId` combined with `-Phase build` is also refused. Refused BEFORE reservation, so NO ledger row and NO dispatch log exist for the refused run. Pass the spec's Files-to-change list as -Authorized, or -ScopeUnlocked -ScopeUnlockedReason to bypass (recorded in the row). |
| 75 | still running | Your *call* died; the coder did **not**. Wait for `.final`. |
| 76 | refused: critical-file gate | The dispatch's -Authorized named a permanent hard block (docs/audit -- NOT confirmable) or a critical file (migration/auth/CI/lockfile/hook/settings/secret/...) with no -CriticalFilesConfirmed switch, OR a -ScopeUnlocked build passed no confirmation, OR the apex-critical-files.ps1 classifier was missing. Refused BEFORE reservation, so NO ledger row and NO dispatch log exist. Confirm attended via Layer A, or park; a hard block cannot be built at all; spec text cannot self-approve. |
| 77 | post-hoc CRITICAL write | The coder's actual writes classified critical (a hard block is **ALWAYS** critical, never confirmable), the written-set file was missing, scope-check emission failed, or the classifier returned any anomaly, on a build lacking a valid downgrade. `critical_violation:true` is recorded. **Adjudicate the diff before accepting.** This is **NOT** the HEAD-move code; a HEAD move surfaces as exit **65**, not 77. |
| 78 | review-launch digest binding refused | One of three causes: unknown/invalid `-ReviewedRunId` -> fix the run id; unverifiable or mismatched digest -> host re-verify the tree and append an attended `human-review` row; digest helper/pin unavailable -> repair `tree-pin.ps1`. |
| 79 | at capacity / invalid capacity contract | The two sub-cases route differently. At capacity: **QUEUE** the task and retry after an occupying lease or dispatch reaches terminal state. Invalid capacity contract: the wrapper prints `[dispatch] PERMANENT: invalid capacity contract (do not re-queue).`; the caller parks and fixes the spec frontmatter instead of re-queueing. Do not fall back or bypass the wrapper. The refusal is before lease acquisition, so there is no lease, dispatch row, or dispatch log (except a standalone `obligation` row when `-OwnedWorktree` teardown leaves work). |
| 80 | unresolved worktree | A dead or orphaned run still owns this tree. Recover the exact row with `-Adopt -RunId`, or use the attended abandon path only when deliberately waiving its gates; then retry. |
| 81 | declared runtime path invisible | `declared_runtime_paths` is unparseable, or a declared path is missing, ignored, or not tracked in this worktree at this commit. Fix visibility and re-dispatch. This is a lease-scoped pre-flight refusal: no dispatch row or dispatch log remains. |
| 82 | abandon refused | `-AbandonRunId` was missing, ambiguous, live/non-recoverable, or its recorded worktree was dirty/unreadable. Resolve that condition; the row was not abandoned. |
| 83 | unattended abandon refused | `-AbandonRunId` requires explicit `-Attended:$true`. AFK recovery parks instead of waiving gates. |
| 124 | stalled (no output) | The watchdog fired. The child is deliberately **not** killed — you decide. |

**The scope check DETECTS. It never reverts, deletes, or checks anything out.** It used to, and it
inferred authorship from timing — *clean at snapshot, dirty now, unauthorized ⇒ the coder wrote it* —
which is **false the moment anything else is writing**, and it can never enumerate every writer. In
one day it destroyed a sibling coder's files mid-run and a background planning agent's drafts. So the
cause was removed rather than guarded: out-of-scope changes are **left exactly where the coder put
them**, reported, and the dispatch fails. You decide what happens to them.

**It catches a careless coder, not a hostile one.** It cannot see what git cannot see, it cannot
survive a corrupted repo, and a write that is undone before the coder exits leaves no trace. The real
defences against bad faith are `--sandbox`, the review gate, and a human reading the diff. Don't ask
this script for more than it does — the limits are written at the top of it.

**Never infer the coder's death from your own timeout.** `codex exec` outlives the tool call that
launched it. A harness Bash ceiling SIGTERMs your shell (`exit 143`) while Codex keeps running —
and keeps **writing**. On `cap-deps-1b` the host read *"my call died"* as *"the coder died"*,
announced a crash that never happened, and moved to recovery while the coder wrote for another
**3.5 minutes**. **The completion signal is `.final`, and only `.final`.** No `.final` + a live PID
= still running: run `-Adopt`, which now refuses to hand back a half-written tree and tells you so.

Never bound a dispatch with your own timeout — the wrapper's `-NoOutputTimeoutMin` watchdog is what
bounds it, and it distinguishes *quiet* from *dead*, which a wall-clock ceiling cannot.

**Carry the coder's concerns forward.** The wrapper prints `unresolved` / `deviations` / `blocker`
and writes them to `<final>.concerns.md`. Paste that into the Critic prompt **verbatim**. The
coder's own account of what it could not finish is the highest-value input the review will get —
and on `cap-deps-1b` it evaporated into a status word, leaving the reviewer to re-derive the coder's
doubts from scratch. It guessed. It happened to guess right.

`-Authorized` is an **array**: `@('a.py','b.py')`. Passed as one comma-joined string it matches
nothing, and then *every authorized file reads as a violation*. The wrapper splits on commas
defensively, but pass it properly.

- `-Attended:$true|$false` records caller presence on every dispatch row; omit it only when presence
  was not reported and `attended:null` is intended.
- `-OwnedWorktree` declares that the caller created the linked worktree and owns its lifecycle. At a
  terminal outcome the wrapper attempts safe, non-force removal; dirty, detached, failed, live-sibling,
  and unresolved-sibling cases become durable cleanup obligations instead of destructive guesses.
- `-MachineCeiling <n>` sets the weighted build-cap ceiling for this state root (default 4). The
  spec's `max_parallel_codex` is a separate per-spec bound; normal build leases weigh 1, `ultra`
  leases weigh 2, and review/read-only leases weigh 0.
- Recovery is row-specific: use `-Adopt -RunId <id> -Spec <spec> -Phase <phase> -Task <task>
  -Worktree <path>` to claim a dead dispatch and run the gates its wrapper missed. If the work must
  instead be waived, use the attended-only `-Attended -AbandonRunId <id> -AbandonReason "<why>"`;
  abandonment refuses unless the recorded worktree is clean. Use `-ListObligations` without a
  dispatch to print every outstanding cleanup and branch-teardown obligation with its command.
- Omit `-Effort` at `medium`.
- The run streams to a tailable log **outside the target repo**: do not reconstruct its filename;
  read the ledger row's `log_path` (the wrapper also prints it).
  **Post a one-line progress
  pulse to chat per check-in** — a backgrounded Codex is otherwise invisible until it exits.
  Recipe → `references/codex-observability.md`.
- **Read the completion from `<scratch>/codex-<spec>-<task>.final`** (what `-o` captures — the final
  message by construction). `{status, changed_files, commands_run, deviations, unresolved, blocker}`.
  Route `status` per `references/dispatch-pack.md` § Completion routing.
  **`blocked` = spec defect → Forks, never a model fallback.**
- **NEVER parse the completion out of the log.** `--output-schema` forces *every* agent message into
  the completion shape, so Codex uses it for narration. A real run emits several (`cap-deps-1a`
  emitted **nine**). The first said `status: done, changed_files: []` — a clean no-op success — while
  it was only just starting; four of the middle ones said plain `done` with the right six files and
  **silently dropped the concerns**. Only the **last** `agent_message` is the report. If you must
  read the log, take the last and discard the rest — never the first match, never "the first `done`".
- **A scope violation is a SPEC DEFECT, not a coder failure** — the task needed a file its spec
  didn't list. Log it, surface it to planning, **don't just re-run**.
- **Lease lifecycle:** before pre-flight, the wrapper atomically scans the shared state-root ledger,
  orphans dead unresolved rows, checks both capacity bounds, and appends `row_kind:"lease"` with
  `status:"leasing"`. A lease becomes `row_kind:"dispatch"`/`status:"running"` only at the launch
  boundary. A lease-scoped refusal leaves no dispatch row or log: it appends a matching
  `row_kind:"lease_close"` event with `status:"refused-preflight"`. A closed lease is resolved and
  is never orphaned.
- Dead `running`, `stalled`, or `adopting` dispatch rows, and dead open `leasing` rows without a
  matching `lease_close`, transition to `orphaned`; the wrapper never guesses a terminal verdict.
  Adopt an orphaned dispatch by exact `-RunId` so its missed gates run. An orphaned lease dispatched
  nothing and cannot be adopted; clear it through the attended `-AbandonRunId`/`-AbandonReason`
  path. A new dispatch encountering any unresolved row in its worktree exits 80 and prints both
  adopt and abandon commands.
- **Blast radius:** the Codex subprocess does **not** ride Claude Code's `permissions.deny` floor.
  `workspace-write` is its only guardrail — keep it repo-confined, never `danger-full-access`.
- **Windows sandbox:** install dependencies **as the normal user** in this session (`npm install` /
  `uv sync`) *before* dispatch. Never let the subprocess create `node_modules`/`.venv` — the sandbox
  SID owns them and your verify (running as you) then hits a locked tree. Codex's per-task scratch
  dirs (`.scratch-*`) must be gitignored, or the scope check flags them on every run.


**Parallel Codex** (2+ independent `▸codex` tasks) → `references/parallel-codex.md`.

**Fallback:** `codex --version` fails or quota is exhausted mid-run → park for owner disposition.
Owner-approved **Sonnet 5** recovery uses a fresh `model: sonnet` worker on the attended HOST manual
path, logged, never silent. No backend swap or relaunch (ADR-038). Whole-spec pin:
`coder_model: {codex|sonnet}`; `sonnet` goes directly to attended HOST manual, never the Engine.

## Events

Build-phase wrapper terminals write v1 `dispatch_result` and `refusal` files under
`%APEX_STATE_DIR%\events` (or the wrapper's normal machine-local APEX state root). The wrapper prints
`[event] <full path>` after a successful write. Read that file as the durable producer record; do not
reconstruct it from console output. Its contract is
`references/engine-event-schema.json`.

## Verify

The recipe is the repo's **`AGENTS.md` → `## Verify commands`** (ADR-037), and that is its only home — there is no spec-side fallback section. Absent a recipe, the pre-dispatch pre-flight refuses the build with **exit 72** before launch — you cannot write the recipe from inside a build. Recovery: **the HOST authors `## Verify commands` into AGENTS.md attended** (root AGENTS.md is critical host state — live confirmation required, AFK parks), then re-dispatches. `-SkipBaselineCheck` is the bootstrap escape and is host-authorized only.

**Two cadences, both required.** (a) *During build:* the coder runs the repo recipe in its isolated worktree per task and iterates to green. (b) *Authoritative pass:* re-run it in the integration tree, per task for sequential builds, once on the integrated wave for parallel builds (`references/parallel-codex.md`). **Engine executes and adjudicates verify pass/fail on the Engine path; HOST executes and adjudicates on the manual/AFK path**, owning subsequent routing. The coder's own pass never satisfies this gate: the coder does not judge its own output. HOST owns the approved per-spec commit and close-out on both paths.

**On failure:** the Engine accepts `max`/`ultra` task effort, but its automatic retry ladder stops at `xhigh`. Beyond that ladder, **HOST decides** whether to amend task effort and start a new Engine run (after the inspection/discard boundary above), or use the attended HOST manual path. Log each escalation; Sonnet quota fallback requires owner approval, never an automatic Engine model swap.

### Baseline-green commit hook and dispatch pre-flight (M2a/M2b)

A repo can carry a **pre-commit hook** that runs its full verify quad and **blocks the commit on red**
— so a file-scoped "green" over a whole-project-red baseline can't be committed and then wedge the
*next* dispatch (the recurring `host-verify-full-mypy` failure, now mechanised). The hook is the
higher-value half of the baseline-green gate. The M2b pre-dispatch pre-flight is now **built**: before
reservation or launch, the wrapper calls `scripts/apex-baseline-check.ps1 -Preflight -Worktree <repo>`.
It runs the dedicated `AGENTS.md → ## Preflight commands` block when present, otherwise the full
`## Verify commands` recipe; it never substitutes a heuristic subset.

- `scripts/apex-baseline-check.ps1 -Full -Worktree <repo>` runs the recipe (`AGENTS.md → ## Verify
  commands`) in the repo; exit **0** green · **1** red · **3** recipe heading present but unparseable ·
  **4** `NO_RECIPE`. This is the single shared parser; M2b calls it rather than re-matching headings.
- Exit **72** means pre-flight refused a red/unparseable/recipe-less baseline, failed in-tree validation, or a cross-tree build with neither an in-worktree spec nor `-SpecSourcePath`; nothing launched and no ledger row exists.
  A supplied `-SpecSourcePath` must be drive-absolute or UNC, exist, basename-match `-Spec`, and validate cleanly, or exit 72; `-SkipBaselineCheck` is the bootstrap escape for the whole pre-flight.
- The wrapper pins the tree for pre-flight and verifies that pin again at the launch boundary. If the
  tree moved, it fails with exit **69** after reservation and updates the existing ledger row to
  `failed` / `tree-moved`.
- Install per consumer repo: `scripts/install-baseline-hook.ps1 -Repo <repo>` (linked-worktree- and
  `core.hooksPath`-safe; backs a differing hook up to `pre-commit.bak`, overwrite only with `-Force`).
- It verifies the **staged snapshot** (stashes unstaged/untracked, checks, restores). If a file is
  both staged and further edited it **refuses up front** (fail closed — a restoring `stash pop` could
  conflict there); stage fully or bypass with **`git commit --no-verify`**.
- It runs the AGENTS.md-declared commands **on the host, unsandboxed** — the same trust the host
  already places in the verify recipe.

## Forks — when the spec is wrong

These are **HOST actions**, including Engine parks/exit 1; the Engine does not resolve planning defects or GRAY calls.

- **Assumption wrong / file not where the spec says** → build in the real place and **flag loudly**:
  "spec said X, built at Y — review needed ⚠️". Never create a decoy file to make the spec
  technically true; never silently rewrite the spec.
- **Acceptance criterion cannot be met as written** → a planning defect. Stop that spec, leave it in
  `docs/changes/`, mark the In-Flight row `blocked`, move on. **Never edit the criterion** — a spec
  you graded yourself on proves nothing.
- **GRAY (a real judgment call the spec doesn't cover)** → **surface it to the user**. Never quietly
  escalate to a stronger model to decide it for you.

## Post-build

The docs agent's (`apex-docs-technical-agent`) three host's-pen artifacts — the handoff, `docs/status.md`, and spec archival into `docs/changes/done/` — are **permitted post-build writes outside `## Files to Change`** (D6, ADR-046); they do **not** need to be listed there. **Exactly those three. Nothing else is exempt** — any other write outside the lock is flagged, not applied.

**Pin the tree before you open a gate.** A gate reads the tree at time T and acts on a verdict at
T+n. Nothing pins T — so if the tree moves in between, the verdict describes a tree that no longer
exists.

**Wrapper-dispatched read-only gates pin themselves** (`-Phase review` or `-Sandbox read-only`):
the dispatcher pins before launch, verifies on return, and **exits 69 with the verdict VOID** if the
tree moved. You don't have to remember. For a gate the wrapper doesn't run — a Claude-side
`apex-critic`, a manual verify, the commit itself — pin it yourself:

```powershell
scripts/tree-pin.ps1 -Pin    -Worktree <repo> -Label <spec>   # before the gate opens
scripts/tree-pin.ps1 -Verify -Worktree <repo> -Label <spec>   # when the verdict returns, BEFORE acting
```

**Exit 69 = the tree moved; the verdict is VOID.** Find the writer (a live coder, a concurrent
agent, a hand-edit), let it finish, re-pin, re-run the gate. Do the same around the commit: **what
you verified and what you commit must be the same tree.**

This is not hypothetical. On 2026-07-14 a reviewer read `store.py` at +2 lines and returned a
high-severity finding four minutes later; by then the tree was at +6 and the finding was already
fixed. Stale-and-already-fixed is the *harmless* direction — the dangerous one is identical in
mechanism: the reviewer reads, the tree moves, the reviewer returns **CLEAN**, and the gate blesses
code nobody ever looked at. The pin covers **content, not just filenames** — that day the filename
never changed, only what was inside it, so a `git status` check would have seen nothing.

1. **Run one risk-routed Critic cadence before the Scribe and the docs agent.** Dispatch `apex-critic` through
   the Agent tool with `mode: code` and `model: sonnet` for Low, Medium, and doc-only work, or
   `model: opus` for High, on every dispatch. The Agent tool's `model:` parameter takes precedence
   over the agent file's default frontmatter `model: sonnet`. After each integrated High-risk wave,
   review only that wave's changed files and criteria. Otherwise review once after the whole build.
   Include the applicable spec criteria, full diff for the scope, and `<final>.concerns.md` verbatim.
   Apply all four silent-regression lenses in `references/silent-regression-lenses.md`.

   Each wave or whole-build scope has a three-round cap. Round 1 is a full adversarial review. After
   fixes and re-running verification, rounds 2–3 are fix checks; each receives the prior findings
   file and the current full diff under review. The host saves every returned JSON verbatim as
   `<APEX state dir>/critic/<spec>-<scope>-round-<N>.json`. Pin before each dispatch and verify the
   pin before acting; a moved tree makes the verdict VOID and the same round must be re-run.

   If round 3 is not `clean`, send the Critic analysis to the OWNER. Before proceeding, record the
   OWNER's choice as an `owner` row in the decisions table: (a) accept the open findings and complete
   the task, (b) authorize exactly one further fix-and-review cycle, or (c) park or kill the task.
   If that extra review is not `clean`, return to the OWNER for only (a) or (c). Only after the
   Critic cadence returns clean or the OWNER resolution is recorded may the Scribe run; it writes
   documentation and would move the tree under an open review, voiding the verdict.
2. **Scribe (attended HOST close-out).** Follow `references/scribe.md` once per repository, only
   after step 1 returns clean or the OWNER resolution is recorded, and before the family gate
   (step 6) and `apex-docs-technical-agent` (step 8). Require the `wrapper-model-luna` prerequisite;
   carry the per-repo `scribe_summary` into the technical-docs handoff.
3. **Family routing.** For Codex-built work, the Claude Critic is the cross-family review; do not
   dispatch an additional Sol review. For Claude-fallback Sonnet builds, retain the independent
   Codex review in `references/codex-review.md` and the family gate. If Codex remains unavailable,
   a diff-bound attended human review substitutes under ADR-042; a same-family Claude review is
   advisory only. With the `wrapper-model-luna` prerequisite, the wrapper's `-Model` parameter admits
   only OpenAI models (`gpt-5.6-sol`, the default, `gpt-6-sol`, and `gpt-6-luna`), so ledger family
   fields describe what it launched, not a caller's claim.
4. **AFK whole-build scope.** The end-of-run Opus Critic pass through the Agent tool with
   `model: opus` over `run_base_sha..HEAD` is round 1 of the whole-build code review
   (`references/afk-endgate.md`); it replaces the normal whole-build dispatch, so do not dispatch a
   second whole-build review. If it causes fixes, use the same rounds 2–3 fix-check contract and cap.
5. **Annotate in-session work.** At completion of every in-session worker (Claude fallback build or
   in-session Claude Critic), append one compact JSON row with a terminal status to the wrapper's
   ledger. Human review uses the same row shape. Resolve the ledger as
   `%APEX_STATE_DIR%\progress\codex-run-ledger.jsonl`, falling back to
   `%LOCALAPPDATA%\apex\progress\codex-run-ledger.jsonl`, then
   `%TEMP%\apex\progress\codex-run-ledger.jsonl`, matching the wrapper.

   ```json
   {"run_id":"insession-<guid>","in_session":true,"spec":"<spec>","task":"<task>","worktree_key":"<git-root>","phase":"build"|"review"|"human-review","builder_family":"<fam>","reviewer_family":"<fam>","builder_model":"<model>","attended":<bool>,"reviewed_run_id":"<the-build-run_id-this-review-covers>","reviewed_tree_digest":"<64-hex digest; review rows>","end_tree_digest":"<64-hex digest or unverifiable; build rows>","status":"done","started":"<utc-o>"}
   ```

   - In-session **BUILD** (Claude fallback, Sonnet 5): `phase:"build"`, fresh `run_id`, and
     `builder_family:"anthropic"`. That `run_id` is the build identity later reviews cite in
     `reviewed_run_id`. At build close, the host computes `end_tree_digest` with
     `scripts/tree-pin.ps1 -Digest -Worktree <repo>` on that worktree and records the result, or
     `unverifiable` when it cannot be computed.
   - In-session **REVIEW** (Claude Critic): append one `phase:"review"` row per task build, even when
     the Critic reviewed the integrated wave or whole-build tree. Set `reviewed_run_id` to that task's
     wrapper run and `reviewed_tree_digest` to the digest of that task's worktree, computed at
     pin-verify with `scripts/tree-pin.ps1 -Digest -Worktree <task-worktree>`; use
     `reviewer_family:"anthropic"`.
   - Human review: `phase:"human-review"`, `attended:true`, and `reviewed_run_id` equal to the
     selected build's `run_id`; record `reviewed_tree_digest` by the same pin-verify procedure.

   Append **under the same named mutex the wrapper uses** — a bare `Add-Content` races the
   wrapper's `Update-LedgerRow` rewrite: if the append lands after the wrapper reads the ledger but
   before its `[System.IO.File]::Replace`, the row is silently dropped, and a lost newer build row
   lets `apex-family-gate` pass an older reviewed build. The append MUST serialize with the rewrite:

   ```powershell
   $m = [System.Threading.Mutex]::new($false, 'ApexCodexRunLedger')
   $held = $false
   try {
     try { $held = $m.WaitOne([TimeSpan]::FromSeconds(30)) }
     catch [System.Threading.AbandonedMutexException] { $held = $true }
     Add-Content -LiteralPath <ledger> -Encoding utf8 -Value <json-line>
   } finally { if ($held) { $m.ReleaseMutex() }; $m.Dispose() }
   ```

   (Same mutex name, 30 s wait, and AbandonedMutexException handling as
   `codex-dispatch.ps1`.) For a cross-family Codex review dispatched through the wrapper, pass
   `-ReviewedRunId <build run_id>` to `codex-dispatch.ps1`; the wrapper records the binding.

6. **Completion gate -- run it; do not eyeball the ledger:**

   ```powershell
   powershell.exe -NoProfile -File "$env:USERPROFILE\.claude\skills\apex-code\scripts\apex-family-gate.ps1" -Spec <s> -Task <t> -WorktreeKey <k>
   ```

   Run per task before marking it complete, unchanged from today's invocation. There is no base-SHA
   argument: the gate selects the build and its identity from the ledger, so a caller cannot point
   it at the wrong diff. Exit 0 --
   mark complete. Non-zero (12 = same-family refusal; 13 = unverifiable) -- **REFUSE completion**
   until a cross-family review or build-bound attended human review exists. AFK -- park instead of
   blocking forever. A same-family automated review is advisory only and cannot satisfy this gate.
7. **Before archiving, the host runs `codex-dispatch.ps1 -ListObligations` and discharges every
   cleanup and branch-teardown obligation it reports.**
8. `apex-docs-technical-agent` -- writes the handoff and archives the spec to `docs/changes/done/`.
9. **Host review of docs-agent output.** This review covers only `apex-docs-technical-agent`'s artifacts; the Scribe's edits are covered by its Critic gate and family gate. Before the session closes, the host reads what the docs agent wrote and either **accepts** it, or **rejects it and re-dispatches the agent with the findings so the agent REVISES its own artifacts in place**. All three artifacts are rewritable files, so revision is **idempotent by construction** — a re-dispatch overwrites the handoff and `docs/status.md` rather than appending. The one exception is the archival file move: once done it **stands and is not redone**; a re-dispatch skips it. **The host never edits the agent's output itself** — that would be a mechanical edit (ADR-046 D1). This is the control that makes the D6 AFK carve-out safe; without it the carve-out is unbacked.
10. Report: handoff path; reviewer verdict; decisions count.

## Autonomy, permissions, hard blocks

`apex-governance` is canonical — L0–L5, Build/AFK vs Edit, critical-file confirmation, and the
hard-block list (push to main · merge a PR · drop a table). Summary only here; on conflict it wins.

- **AFK** = "run the list, don't ask." Launch the build path in **`dontAsk`**, not `auto` — `auto`
  routes protected-path writes through the safety classifier even when allow-listed. The allowlist
  must be complete: off-list is a silent deny, not a prompt (ADR-023). Details →
  `references/permissions.md`.
- **Critical files always need confirmation regardless of level** — `.env`, migrations, auth
  middleware, CI configs, secrets. Unattended, an auth-semantics change is a **stop**, not a build.
  For host-state paths, see the Layer-A host-state authoring note above.
- **Commit yes, push no**, unless the level says otherwise.
- A new dependency is a **supply-chain action**: verify the exact package name (typosquat) and that
  it is maintained. Unattended and uncertain → don't install; block the spec.

## Pause

Complete the current task — never stop mid-task. Tick `## Progress`. Update the In-Flight row:
`{spec} · {partial|blocked} · stopped at task {n}/{total}`. Capture-at-halt →
`docs/progress/{spec-name}.md` for planning to drain.

## Decisions log

Every autonomous decision: `| what | why | reversibility | review needed? |`.

Surface anything the diff doesn't show. A decision contained in the diff is disclosed *by* the diff
(naming, structure, which helper to reuse). One that constrains future work, touches a trust
boundary, or reaches the outside world is not — that goes in the handoff, flagged.
