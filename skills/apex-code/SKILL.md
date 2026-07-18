---
skill: apex-code
backend: claude
version: 2.10.0
last_updated: 2026-07-18
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
staleness_threshold: 30d
description: >
  APEX build workflow — executes docs/changes/ specs: pre-flight, wave-parallel Codex
  dispatch, the verify loop against the repo's AGENTS.md, forks, and post-build review.
  Codex `gpt-5.6-sol` is the coder; Opus is the fallback. Loads when building a spec.
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
  action: log it, don't touch it, surface it in the handoff. Re-check before touching any file.
- **Invariant freshness (ADR-033 A3):** if the spec predates an ADR shift, check its `## Intent`
  invariants still hold. A contradiction is a wrong `Stop` assumption — halt and flag.
- **`coder_effort`** frontmatter `{low|medium|high|xhigh|max|ultra}`, default `medium`.
- AFK build → capture `run_base_sha = git rev-parse HEAD` now (for the end-gate).

## Wave analysis

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
`isolation: "worktree"` (inline) / `isolate: true` (workflow). Cap: `max_parallel_codex` (default 3).

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
Authorizing any of them -- including bare directory grants `docs/changes` or `docs/handoff` -- requires attended `-CriticalFilesConfirmed`; an unattended/AFK dispatch that tries to authorize one refuses with exit **76** by design: **PARK** the task. Remaining gap: a broader directory grant (for example, all of `docs`) still slips literal-token classification until D6 post-hoc write classification (Wave B2); see ADR-044 D3 consequence (a).

A spec's `## Permissions` text does **not** satisfy Layer A; only a live attended human confirmation
does. Layer B's exit 76 mechanical backstop proves the confirmation switch was passed, but not who supplied it. Layer A owns that provenance check, so unattended work must park.

Every task tagged `▸codex` (the default). Assemble the **dispatch pack** — Goal → Context →
Constraints → Done-when — per `references/dispatch-pack.md`, then **always dispatch through the
wrapper**:

```powershell
scripts/codex-dispatch.ps1 `
  -Spec <spec> -Task <task> -Phase build -Worktree <repo-root> -BaseSha <sha> `
  -SpecSourcePath <abs path> `                    # host always passes the spec's real home on cross-tree builds
  -Prompt "<the dispatch pack>" `
  -Authorized @('src/a.py','tests/test_a.py') `   # the spec's ## Files to change, VERBATIM
  -Effort <coder_effort>                          # default medium
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
   coder).
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
| 73 | **double-encoded text (mojibake)** | Codex-on-Windows corrupted non-ASCII it wrote (em-dash → `â€"`). **Do not commit — the suite is green and wrong.** The coder writes the same bad bytes into the *expected* string, so the assertion compares corrupt to corrupt and passes. Fix the bytes, re-verify. |
| 74 | refused: scope lock | A workspace-write build dispatch had an empty -Authorized scope list and no -ScopeUnlocked escape, OR a contradictory/incomplete flag combination. Refused BEFORE reservation, so NO ledger row and NO dispatch log exist for the refused run. Pass the spec's Files-to-change list as -Authorized, or -ScopeUnlocked -ScopeUnlockedReason to bypass (recorded in the row). |
| 75 | still running | Your *call* died; the coder did **not**. Wait for `.final`. |
| 76 | refused: critical-file gate | The dispatch's -Authorized named a permanent hard block (docs/audit -- NOT confirmable) or a critical file (migration/auth/CI/lockfile/hook/settings/secret/...) with no -CriticalFilesConfirmed switch, OR a -ScopeUnlocked build passed no confirmation, OR the apex-critical-files.ps1 classifier was missing. Refused BEFORE reservation, so NO ledger row and NO dispatch log exist. Confirm attended via Layer A, or park; a hard block cannot be built at all; spec text cannot self-approve. |
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
and writes them to `<final>.concerns.md`. Paste that into the reviewer's prompt **verbatim**. The
coder's own account of what it could not finish is the highest-value input the review will get —
and on `cap-deps-1b` it evaporated into a status word, leaving the reviewer to re-derive the coder's
doubts from scratch. It guessed. It happened to guess right.

`-Authorized` is an **array**: `@('a.py','b.py')`. Passed as one comma-joined string it matches
nothing, and then *every authorized file reads as a violation*. The wrapper splits on commas
defensively, but pass it properly.

- Omit `-Effort` at `medium`.
- The run streams to a tailable log **outside the target repo**, beside the ledger:
  `<ledgerDirectory>\codex-logs\codex-<spec>-<task>-<worktreeTag>-<runId8>.log` (i.e.
  `%LOCALAPPDATA%\apex\progress\codex-logs\...`, or `%APEX_STATE_DIR%\progress\codex-logs\...`).
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
- **Blast radius:** the Codex subprocess does **not** ride Claude Code's `permissions.deny` floor.
  `workspace-write` is its only guardrail — keep it repo-confined, never `danger-full-access`.
- **Windows sandbox:** install dependencies **as the normal user** in this session (`npm install` /
  `uv sync`) *before* dispatch. Never let the subprocess create `node_modules`/`.venv` — the sandbox
  SID owns them and your verify (running as you) then hits a locked tree. Codex's per-task scratch
  dirs (`.scratch-*`) must be gitignored, or the scope check flags them on every run.


**Parallel Codex** (2+ independent `▸codex` tasks) → `references/parallel-codex.md`.

**Fallback:** `codex --version` fails, or quota is exhausted mid-run → the task falls back to
**Opus**, a fresh `model: opus` worker in this session. Logged, never silent. No backend swap, no
relaunch (ADR-038). Whole-spec pin: `coder_model: {codex|opus}`.

## Verify

The recipe is the repo's **`AGENTS.md` → `## Verify commands`** (ADR-037). Absent one, fall back to
the spec's `## Commands to run`; absent that, run the obvious per-ecosystem checks, log the gap, and
**write a recipe into AGENTS.md so the next build has one**.

Load `~/.claude/skills/apex-coding-principles/impl.md` before writing code.

Run the recipe **per task**, not once at the end. **The host runs it — never the coder subprocess
judging its own output** (evaluator independence).

**On failure, escalate in order**, logging each rung: bump `coder_effort` one notch → … → `max` →
`ultra` → **Opus** (fresh worker). `ultra` is the only place it fires automatically, and it is
un-evaled — first rung to cut if the eval disappoints (see status.md).

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

- **Assumption wrong / file not where the spec says** → build in the real place and **flag loudly**:
  "spec said X, built at Y — review needed ⚠️". Never create a decoy file to make the spec
  technically true; never silently rewrite the spec.
- **Acceptance criterion cannot be met as written** → a planning defect. Stop that spec, leave it in
  `docs/changes/`, mark the In-Flight row `blocked`, move on. **Never edit the criterion** — a spec
  you graded yourself on proves nothing.
- **GRAY (a real judgment call the spec doesn't cover)** → **surface it to the user**. Never quietly
  escalate to a stronger model to decide it for you.

## Post-build

**Pin the tree before you open a gate.** A gate reads the tree at time T and acts on a verdict at
T+n. Nothing pins T — so if the tree moves in between, the verdict describes a tree that no longer
exists.

**Wrapper-dispatched read-only gates pin themselves** (`-Phase review` or `-Sandbox read-only`):
the dispatcher pins before launch, verifies on return, and **exits 69 with the verdict VOID** if the
tree moved. You don't have to remember. For a gate the wrapper doesn't run — a Claude-side
`apex-reviewer`, a manual verify, the commit itself — pin it yourself:

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

1. **In parallel:**
   - `apex-reviewer` — spec_path, files_changed, **and `<final>.concerns.md` verbatim** if the coder
     raised any. **Always runs.** It is the evaluator-independence gate; skipping it to save tokens
     trades away the one thing that sees what the coder cannot.
   - `apex-docs-product-agent` — files_changed, spec_path, date.
2. **Cross-family review** (`cross_model_review: true`; auto for auth/security/data/`risk: high`).
   Use the other model family when both are available: **Codex built -> Claude reviews** (`model:
   opus` for the high-risk set); **Opus built -> Codex reviews** (`references/codex-review.md`).
   Give it the spec + diff only -- **never the other reviewer's findings**. A finding both raise ->
   resolve before "complete"; only one -> decisions table, human adjudication. If Codex is still
   unavailable after Opus fallback builds, a diff-bound attended human review substitutes for the
   unavailable cross-family review (ADR-042); a same-family Claude review remains advisory.
   `apex-family-gate.ps1` enforces this substitution at completion, not prose alone. The wrapper
   hardwires `gpt-5.6-sol` and has no `-CoderModel` parameter, so every wrapper-dispatched build or
   review is family `openai`; ledger family fields describe what it launched, not a caller's claim.
3. **AFK only:** the standing end-of-run **Opus** adversarial pass over `run_base_sha..HEAD` —
   read-only, advisory (`references/afk-endgate.md`). Opus, not Sol: Sol is the coder, and the one
   review that runs with nobody watching must not be self-review. Lenses →
   `references/silent-regression-lenses.md`.
4. **Annotate in-session work.** At completion of every in-session worker (Opus fallback build or
   in-session Claude reviewer), append one compact JSON row with a terminal status to the wrapper's
   ledger. Human review uses the same row shape. Resolve the ledger as
   `%APEX_STATE_DIR%\progress\codex-run-ledger.jsonl`, falling back to
   `%LOCALAPPDATA%\apex\progress\codex-run-ledger.jsonl`, then
   `%TEMP%\apex\progress\codex-run-ledger.jsonl`, matching the wrapper.

   ```json
   {"run_id":"insession-<guid>","in_session":true,"spec":"<spec>","task":"<task>","worktree_key":"<git-root>","phase":"build"|"review"|"human-review","builder_family":"<fam>","reviewer_family":"<fam>","builder_model":"<model>","attended":<bool>,"reviewed_run_id":"<the-build-run_id-this-review-covers>","status":"done","started":"<utc-o>"}
   ```

   - In-session **BUILD** (Opus fallback): `phase:"build"`, fresh `run_id`, and
     `builder_family:"anthropic"`. That `run_id` is the build identity later reviews cite in
     `reviewed_run_id`.
   - In-session **REVIEW** (Claude): `phase:"review"`, `reviewer_family:"anthropic"` for Sonnet or
     Opus, and `reviewed_run_id` equal to the reviewed build's wrapper or in-session `run_id`.
   - Human review: `phase:"human-review"`, `attended:true`, and `reviewed_run_id` equal to the
     selected build's `run_id`.

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
5. **Completion gate -- run it; do not eyeball the ledger:**

   ```powershell
   powershell.exe -NoProfile -File "$env:USERPROFILE\.claude\skills\apex-code\scripts\apex-family-gate.ps1" -Spec <s> -Task <t> -WorktreeKey <k>
   ```

   Run before marking a task or spec complete. There is no base-SHA argument: the gate selects the
   build and its identity from the ledger, so a caller cannot point it at the wrong diff. Exit 0 --
   mark complete. Non-zero (12 = same-family refusal; 13 = unverifiable) -- **REFUSE completion**
   until a cross-family review or build-bound attended human review exists. AFK -- park instead of
   blocking forever. A same-family automated review is advisory only and cannot satisfy this gate.
6. `apex-docs-technical-agent` -- writes the handoff, archives the spec to `docs/changes/done/`, and
   folds the shipped capability into `overview.md` as one line (merge-on-archive, ADR-014).
7. Report: handoff path; reviewer verdict; decisions count.

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
