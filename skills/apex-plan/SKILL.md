---
skill: apex-plan
version: 2.9.3
last_updated: 2026-10-15
sources:
  - docs/technical/adr/ADR-010-multi-pass-review.md
  - docs/technical/adr/ADR-011-instinct-loop-no-engine.md
  - docs/technical/adr/ADR-013-app-flow-artifact.md
  - docs/technical/adr/ADR-014-living-capability-overview.md
  - docs/technical/adr/ADR-017-design-brief-artifact.md
  - docs/technical/adr/ADR-029-cross-spec-parallel-build.md
  - docs/technical/adr/ADR-031-codex-context-propagation.md
  - docs/technical/adr/ADR-032-gpt56-role-split.md
  - docs/technical/adr/ADR-036-remove-knowledge-layer.md
  - docs/technical/adr/ADR-037-three-context-files.md
  - docs/technical/adr/ADR-048-role-redesign.md
staleness_threshold: 30d
description: >
  Use when planning — turning requirements into docs/changes specs. Triggers: plan /
  design / architect / spec / "let's build". Owns spec authoring, research gate, readiness
  gate, ADRs. Not build (apex-code).
---

# APEX Planning

Turn requirements into specs a coder can execute **without asking anything**.

**This skill carries the machinery, not the judgment.** How to write a good spec — name exact files,
make criteria runnable, strip the *why*, ask before drafting, don't over-scope — is **model-native**
and was cut in v2.0.0 after a RED probe reproduced all of it cold, including the no-why litmus
verbatim (ADR-036). What remains is what a bare agent cannot know: APEX's artifacts, its gates, and
the traps that only surface on a second pass.

## Session start

1. Read `docs/status.md` — In-Flight, Pending Specs, Open Questions.
2. Read `docs/drafts/` — unfinished specs (`*.review.log` sidecars are review-round records, not drafts).
3. Check `docs/progress/*.md` — capture-at-halt records from blocked builds. Each must be **drained**:
   pull the spec back to `docs/drafts/` and apply the fixes through an `-AuthorSpec` revise
   dispatch (see Writing the spec). Delete the record once drained.
   The wave-resume procedure runs only after every `docs/progress/*.md` capture-at-halt record is drained. An In-Flight slice row is surfaced for disposition only. Then surface an ordinary In-Flight row for a plan slice (partial, blocked or parked) for disposition before that plan's C4 pointer. A C4 pointer never authorizes a fresh build while its plan is stopped. While a plan is stopped, the resume procedure skips both its spec and build branches for that plan; only the revisions permitted while stopped run. The resume procedure never specs or builds a spec named in a `change held` row. For wave N, finish unfinished drafts in `docs/drafts/` first. Then spec against shipped code every wave-N slice with no draft in `docs/drafts/` and no spec in `docs/changes/` or `docs/changes/done/`. Then build wave-N specs in `docs/changes/`. Only after every wave-N slice spec archives to `docs/changes/done/`, advance the pointer and spec wave N+1 against shipped code.
   Read the plan-stopped and change-held In-Flight rows before the pointer and enforce their guards across all affected slices and specs. Read each C4 pointer `plan · docs/plans/<plan>.md · next wave <N>` by that order. Use the slices table's wave column and C5 `plan: docs/plans/<plan>.md · slice: <slice-id>` in each slice spec's `## Intent`; after plan archival that path resolves under `docs/plans/done/`. The HOST maintains one pointer per active plan.
4. Read the latest `docs/handoff/*.md` — see § Drain the handoff.
5. Run the doc-coverage check (below).
6. Acknowledge: "{n} pending spec(s): {list}. Flags from last build: {or none}. Doc coverage:
   {result}. What are we working on?"

### Doc-coverage check — informational, never blocks

One line, or "clean":
1. `docs/technical/architecture/overview.md` missing, or still carries `<!-- apex:overview:stub -->`.
2. Decisions in the handoff or status.md with no matching `docs/technical/adr/ADR-NNN-*.md`.
3. overview.md older than the newest ADR, **or not updated since the last spec archived to
   `docs/changes/done/`** (ADR-014).
4. Scope-gated stubs still stubbed while a spec in their scope is in play: `data-model.md`
   (ADR-008) · `app-flow.md` (ADR-013) · `design-brief.md` (ADR-017).
5. Repo-root **`AGENTS.md`** still stubbed while ≥1 spec sits in `docs/changes/`, or its exact
   `## Verify commands` heading lacks the adjacent populated fence — **Codex builds read AGENTS.md,
   not these skills** (ADR-031/037).
6. A target repo map is missing or has stale sections.

### Drain the handoff — inbox-zero, this session

The handoff is read **once**. Surfacing an item is not landing it. Every item terminates in exactly
one of: **Pending Spec** · **Open Question** (status.md) · **Folded** (written into a spec / skill /
ADR / `feedback` memory *now*) · **Discarded** (explicitly judged not actionable).

An item read and not filed is gone. Land each disposition this session.

**The learning loop (ADR-011):** a build lesson or a user correction folds into a `feedback` memory
at the drain. Don't wait for recurrence — when the user flags a deliverable they loved, post-mortem
it *while it's still in context*. A recurring lesson earns promotion via `apex-skill-author`
(human-gated, Iron Law).

## Intake

The HOST proposes `Size: Trivial | Normal | Big; Risk: Low | Medium | High; target code repos: ...` in one line with evidence; the owner confirms labels only for Big or High, separately from plan approval. For Trivial, apply `references/system-map.md` § Four-part Trivial test before assigning the label; failure of any criterion means at least Normal. Bug is an entry route: `apex-debug` confirms root cause and passes its statement to Intake, which sizes the fix; a contract-changing fix is Big. Labels only rise.

Selected repos are the target code repos, not the current directory or spec-owning repo. Normal selects per change; Big selects per plan, and each `### Slice <slice-id>` section has required `**Target code repos:**` and `**Cross-slice contracts produced or consumed:**` fields listing that slice's own selected repos and every cross-slice contract it produces or consumes. Before planning or author dispatch, for Normal, Big and non-Trivial bug fixes, run `apex-map-check.ps1 -Stale` for each selected repo with a map and read touched sections. Follow `references/system-map.md` § Freshness and targeted re-survey for exits, targeted re-survey and live-edit inspection; a no-map repo skips the read. After the slice-spec manifest exists, compare its build repos with that slice's selection (Normal: the change's selection). For Normal work, update the change's selection and read an added repo's map. A Big slice whose manifest names a repo outside its `**Target code repos:**` field stops its plan under the stop rule. Bring the mismatch to the OWNER before promotion. Update the slice's target-repo field through plan re-approval, then repeat the map step for each added repo before that slice builds. Repeat the map step before each just-in-time wave.

Route Trivial to one-task Light on the normal wrapper path and `apex-size-guard.ps1` at HOST close-out; `OVER` triggers a map read and normal review before commit per `references/system-map.md` § Four-part Trivial test. Route Normal to one Light or Deep Details slice. If the existing split rule would require more than one spec for a change, the change is Big. The existing doc-only exception to the split rule remains in force. Route Big through C1 `## Planning gate check` and then one wave of slice specs at a time under C1 `## Plan artifact` in `references/sol-plan-check.md`. Apply the existing tier classification first: doc-only is Low unless it declares `risk: high`; explicit High wins. Every Medium or High Big-plan slice uses Deep Details, its readiness gate and its own post-readiness cold read by tier. A Low slice may use Light without a cold read. Keep Normal mode choice and Sol-skip rules.

A completed plan archived under `docs/plans/done/` is never reopened; a change to it is new work that enters Intake as a new plan. A label rising to Big, or a contract change to an approved Big plan, stops that plan: the HOST starts no build dispatch, Engine run or unattended drain for any of its slices, brings every running or completed-but-uncommitted Engine run or drain touching the plan to the OWNER for disposition, and resumes the plan only after the owner re-approves it through § Planning gate check. While a plan is stopped, the only author dispatches permitted for its slices are revisions of slice specs authorized before the stop, including capture-at-halt drain revisions; authoring a new or changed slice waits for re-approval under § Planning gate check. A change that affects a slice already archived to `docs/changes/done/` in an active plan is new work: at re-approval the plan gains a new slice for it in the current C4 pointer wave N or a later wave; archived slice specs are never moved back. When a plan stops, the HOST adds an In-Flight row to `docs/status.md`: `plan stopped · docs/plans/<plan>.md · <trigger>`, and deletes it only after re-approval. Owner disposition also covers an unattended drain whose branch holds committed specs awaiting attended close-out: close-out of the stopped plan's slices waits for that disposition.

The archived-slice rule applies only to changes made while a plan is stopped; any other change to a shipped slice is ordinary new work that enters Intake. An unbuilt spec has no committed build output on any branch; a spec with committed drain or Engine output awaits its owner disposition and is never listed for deletion until that disposition completes. A parked, paused or awaiting-review Engine run, a stopped drain, or an in-flight HOST manual-path dispatch touching a stopped plan or a spec held under the Normal-to-Big rule goes to the OWNER for disposition and is not resumed while the plan is stopped or the spec is held. At re-approval of a stopped plan, before deleting the stop row, the HOST lists every unbuilt slice spec the re-approved plan affects in `docs/drafts/` or `docs/changes/`. When a Normal change's label rises to Big, the HOST lists every unbuilt spec of that change in `docs/drafts/` or `docs/changes/`. When a Normal change's label rises to Big, the HOST adds an In-Flight row to `docs/status.md`: `change held · <spec names> · normal-to-big`, and deletes it only when the owner's disposition of every held spec completes. From the moment a Normal change's label rises to Big, the HOST starts no build dispatch, Engine run or unattended drain for any spec of that change, and brings every running Engine run or drain on such a spec to the OWNER; the specs stay held until the owner decides their deletion. If the owner declines the deletion, the specs stay held until the owner decides otherwise. For either disposition, the HOST expands the affected-spec list to include every unbuilt spec whose `## Prerequisites` names a listed spec and that is either in the same plan as that listed spec or outside any plan, repeating until no such spec remains. A prerequisite consumer that belongs to another plan is not deleted; that other plan stops under the stop rule instead, with trigger `prereq:<deleted-spec>`. With owner approval, the HOST deletes each listed spec together with its review sidecar and findings. When the re-approval and Normal-to-Big deletion rule deletes a spec, the HOST deletes that spec's `docs/progress/<name>.md` capture-at-halt record in the same owner-approved disposition. Every unbuilt spec whose `## Prerequisites` names a deleted spec and that is either in the same plan as that deleted spec or outside any plan is also affected: it is deleted and re-authored under the same owner-approved rule. Each affected slice is then re-authored as a fresh spec under a spec name no spec or draft has used, with its own new review record. The HOST renames the slices-table entries before the re-approval gate dispatch. The new Big plan created by a Normal-to-Big rise authors its slices fresh under unused names; an existing plan re-authors only its affected unbuilt slices. Built specs in `docs/changes/done/` are never deleted. No unbuilt spec moves from `docs/changes/` back to `docs/drafts/` through re-approval or Normal-to-Big disposition. The re-approval and Normal-to-Big deletion rule's no-move-back rule applies only to the re-approval and Normal-to-Big deletions; the capture-at-halt route and the revisions permitted while a plan is stopped are unchanged. The new slice goes in the current C4 pointer wave N or a later wave. `<trigger>` is `big-raise`, `contract:<name>`, `contract:target-code-repos/<slice-id>` or `prereq:<deleted-spec>`; each further trigger while the plan is stopped adds its own stop row, and the plan resumes only when re-approval deletes all of them. A Normal change whose label rises to Big has no plan to stop; it enters § Planning gate check as a new Big plan. Re-approval grants a fresh two-read budget under § Planning gate check; its reads continue the plan's existing `gate-N` numbering.

Use the existing C1 `gate-N` review rows and approval path for re-approval.

## Mode

Ask, and recommend the lightest that fits — don't default to heavy for a one-file change:

| Mode | For | Ceremony |
|------|-----|----------|
| **Deep Details** | multi-file / architectural | full template · dispatched review · readiness gate · ADRs |
| **Light** | a contained change | intent · key decisions · acceptance criteria · no gate |

## Before drafting — resolve, don't discover

The coder executes silently against **frozen** criteria, in a fresh context, and cannot ask you
anything. So **every build-changing decision must be resolved before the spec freezes** — this is
the only place that can happen.

- **Resolve yourself:** codebase facts (read the files), clear technical defaults, anything derivable.
- **Ask the user:** product intent, preference between technically-valid options, edge-case priority,
  "what does good look like." Judgment, not facts. Batch the asks; don't drip them.
- **Leave to the coder:** bounded micro-ambiguity (which existing pattern to follow, a local name).

Drafting first and validating after is the failure mode — it produces guessed field lists and
punted decisions dressed up as "open questions."

### Widen the options — the research gate

Before locking an approach, check you have more than one. If the decision is **contested,
high-stakes, and hard to reverse** → `apex-deep-dive` (2–3 options, trade-offs) or its **Council
mode** (three blind fresh-context voices — anti-anchoring, ADR-010). For "what's current / which
tool" → `apex-research`. For a routine call with an obvious default → neither; just decide.

UI-bearing work → `references/design-workflow.md` (persisted app-flow + design-brief artifacts, the
ask-first aesthetic gate, the cheap-mockup loop, the visual review gate).

## Writing the spec

Big uses C1 § Planning gate check instead of the pre-draft pass. Non-Big Medium/High Deep Details retains the pre-draft pass and its independent post-readiness cold read. Low and doc-only skip under the existing tier rule. The Big gate output never enters the cold read. Pre-draft pass recipe: `references/sol-plan-check.md` § Pre-draft architecture pass; for High an unresolved BLOCK is an approval gate — print the **apex-governance § Approval gate** banner and get the explicit `Approve? [y / n / edit]` answer before any spec-author dispatch.

Template: `~/.claude/skills/apex-orchestrate/templates/spec-template.md`. Derive its execution manifest,
Files to Change, and Tasks list from the same decisions: one entry per coder task, with explicit file operation and dependency IDs; exclude HOST/OWNER tasks from the manifest.
**You do not draft it yourself (ADR-045, ADR-048).** Resolve the open decisions, then dispatch the
spec author: gpt-6-sol through the wrapper's author mode. The host assembles a prompt pack (`$pack`)
containing the adjudicated plan brief, the exact template path, the target `docs/drafts/<short-name>.md`
(never straight to `docs/changes/`), and the three rules below (no why inline except Intent, mechanism
in each task, one concern per task).

Normal and Trivial author dispatches keep the full adjudicated plan brief, the exact template path, the target draft and the three rules. For a Big slice, the author pack carries the C6 clean slice brief (slice intent, cross-slice contracts, cited map sections) in place of the full adjudicated plan brief, along with the existing template, target draft and three rules.

For an absent draft, create:

```powershell
& "$env:USERPROFILE\.claude\skills\apex-code\scripts\codex-dispatch.ps1" -AuthorSpec -Model gpt-6-sol -Task author -Spec <short-name> -Authorized "docs/drafts/<short-name>.md" -Worktree <repo> -BaseSha <HEAD> -Effort high -Prompt $pack
```

A zero exit means the wrapper left exactly that one regular draft file. The author drafts; you
review its draft against the rules below and the readiness gate. The rest of this section is the
contract you hand the author and grade against.

**Every later write to an existing draft is a new author dispatch** -- reviewer fixes, readiness
fixes, cold-read amendments, and owner-directed fixes alike. Each is a
fresh, stateless gpt-6-sol `-AuthorSpec` call with the same arguments plus
`-ExpectedDigest (git -C <repo> hash-object "docs/drafts/<short-name>.md")` and a prompt containing
the requested changes. The host never edits the draft itself. Author dispatches into one repo run
sequentially; do not pass `-AllowSharedWorktree`, which author mode refuses.

**Author exits** (diagnose against the exit-code table in `apex-code`'s `Codex dispatch` section):
- **0** -> review the draft.
- **75 with STILL RUNNING in the output** -> wait for the coder's `.final`, then run the wrapper's
  printed `-Adopt -RunId <id>` command without `-AuthorSpec`, so the skipped scope, tree-pin,
  encoding, and verdict gates run. Adoption exit 0 -> review; every other adoption result -> the
  OWNER. Never act on the call's timeout.
- **Any other non-zero exit**, including `[adopt] REFUSED (exit 75)` -> read the wrapper's printed
  diagnosis and the `.final`/concerns, then bring them to the OWNER with a recommendation. The host
  never edits the draft, never deletes or reverts files, and never re-dispatches without the
  owner's decision.
- **Quota-out** (a usage-limit/429/quota message in the `.final` or log, or Codex failing to
  launch) -> the OWNER. Only the owner may approve a `model: sonnet` Agent (non-wrapper) author
  fallback; record the chosen model and never fall back silently. Before and after that Agent
  dispatch, record `git hash-object` for every file under `docs/drafts` and the full
  `git status --porcelain --ignored -uall -- docs/drafts` list; accept only when the target draft
  is the sole new or changed content and no other path appears. For a revise, also check that the
  pre-dispatch draft hash matches the expected digest.
- **74 because the target repo's `docs/drafts` has no tracked file** -> the OWNER; do not seed a
  file automatically.

**Write freeze.** While an author run is in flight, the host makes NO writes to the target repo --
including sidecar row completion, status.md, and plan files -- until the coder's `.final` exists or
the wrapper confirms no coder launched, not merely until the wrapper call returns. Concurrent host
writes are attributed to the author and cause a false exit 65.

**Author rows in the sidecar.** The HOST creates `docs/drafts/<short-name>.review.log` at whichever
comes first: the pre-draft arch-check row or the first author dispatch. Rows are only APPENDED,
never overwritten or recreated; phase-2 completion fills the pending cells of the existing row. Each
author dispatch gets a two-phase row. At dispatch: Round = `author`, Dispatched (UTC), Reviewer =
`author:<model>:<create|revise>`, Spec digest = the `-ExpectedDigest` for a revise or `- (create)`,
Verdict and Disposition = `pending`. After a wrapper run, complete the same row (subject to the
write freeze) with Verdict = the wrapper exit and Disposition = `launched` only if the ledger has a
dispatch row AND a child process started; exits 72/74/76/79/80/71 before launch and exit 69 at the
launch boundary are `not-launched`, even when exit 69 left a ledger row. An owner-approved Sonnet
Agent dispatch uses Reviewer = `author:sonnet:<create|revise>`, Verdict = `agent`, and Disposition
= `launched` only after its child process starts. Review rows follow.

**Split rule:** >3 files or >2 logical phases → split, except doc-only specs. When you split (or
write alongside other pending specs), make the specs **file-disjoint**, with any real dependency
as a `## Prerequisites` edge — so a session drains the whole set as parallel waves (ADR-029).

### Spec one WAVE ahead — never the whole roadmap (the default)

Design the whole thing. **Then spec and build one dependency wave at a time:**

> spec wave 1 → **build wave 1** → spec wave 2 *against the real, shipped wave-1 code* → build wave 2

**Inside a wave**, specs are dependency-independent by construction, so spec them all up front and
dispatch them in parallel — you keep the full batching win. **Across waves, never.** A spec that
consumes another spec's *output shape* is being written against an interface that **does not exist
yet**, and you will not find out until the build.

This is not theoretical. Artemis's 35-spec one-shot (2026-07-14) shipped, but **four of its six
host-caught defects were spec-ahead damage**, and every one of them landed in a *chained* family
(mcp a→b→c, map3→map4, ref, pr) while the independent specs came through clean. The deepest —
`dto.ts`/`gateway.ts` appearing in **no** spec's file list across mcp6a/6b/6c — would have broken
every invoke-confirm call at the IPC layer. The same run also found "10 of 47 unbuilt specs were
already shipped, just unarchived": **specs written far ahead of the build decay, because the codebase
moves under them.**

The cost used to be a session restart. It isn't any more (ADR-038 — one session plans and builds), so
the main argument for spec-everything-first is gone.

**Spec further ahead only when** the specs are genuinely file-disjoint *and* depend on no interface
that doesn't exist yet. That is the same test as `Batch-joinable` in the readiness gate — if a spec
fails that, it is also too far ahead to write.

**Three rules a bare model does not reliably apply:**

1. **No *why* inline.** Litmus: does it change what gets built? **No** → cut it (home = an ADR).
   **Yes** → don't add the why, make the *what* explicit. One exception: the template's `## Intent`
   block (intent / invariants / non-goals, ≤10 lines) — it travels to the coder in the dispatch pack
   (ADR-031). Under the definition in Intent, declare `risk: low|medium|high`; absent = medium. A
   doc-only spec is Low unless it explicitly declares `risk: high`, which always wins. Doc-only
   means every Files-to-Change path is documentation prose under `docs/`, an ADR, README, or
   CHANGELOG, and none is a skill (`SKILL.md`, `references/**`, `templates/**`), agent, hook,
   settings, script, or other config/instruction file.
2. **Tasks state the *mechanism*, not just the outcome.** A "reuse/extend X" task cannot achieve a
   behaviour X structurally lacks. Name the concrete producing step — the wiring that *emits* the
   behaviour. This is the highest-yield spec defect and it hides behind plausible prose.
3. **One concern layer per task** (API / DB / UI / test). Never manufacture thin tasks to raise
   worker count — spawn overhead exceeds the saving.

For doc-only work, write acceptance criteria as presence/absence, version/date, cap, pointer, and
verify-fence checks. Exact-line manifests and whole-tree hashes are reserved for High specs.

**`## Wave plan`** (specs with ≥3 tasks): derive a **PROPOSED** wave plan from the *stated*
dependencies — `Wave 1: [1, 2] | Wave 2: [3]`. The **dependencies are binding**; the **grouping is advisory**.
Prefer Engine-compatible, manifest-backed, file-disjoint single-repo specs where they fit; this
shape is not required. The **Engine** determines task selection and sequencing for eligible
attended specs from manifest `depends_on`; **HOST** schedules the manual path for refused specs
and executes unattended builds. Do the analysis here so HOST has a defensible starting point.
Independence you can't establish means sequential.

**Frontmatter levers:** `coder_effort: {low|medium|high|xhigh|max|ultra}` (default `medium`; `high`
for risk:high/auth/security/data) · `coder_model: {codex|sonnet}` pins a whole spec ·
`cross_model_review: true` for auth/security/data-migration — deliberate, never a default.
Full rubric → `references/model-routing.md`.

## Dispatched spec review

Before the readiness gate, dispatch `apex-critic` through the Agent tool with `mode: spec`. On
**every dispatch**, pass Agent tool `model: sonnet` for Low, Medium, and doc-only specs, and
`model: opus` for High. The Agent tool's `model:` parameter takes precedence over the agent file's
default frontmatter `model: sonnet`.

Normal and Trivial spec-mode Critic dispatches keep the full adjudicated plan brief and current full draft under review. Every spec-mode Critic dispatch of a Big slice receives the same C6 clean slice brief plus C2 plan-slice inputs: the plan path as reference only, the slice's section text, the plan's cross-slice contracts section text, and the map sections the slice cites, pasted in the prompt. The Big-slice Critic also receives the current full draft under review. Gate findings, `gate-N` rows, adjudication history and the rest of the plan narrative are excluded.

Before dispatching, the host runs
`git hash-object <draft>`, writes the value into the round's sidecar row, and passes it as the
**FIRST line** of the prompt: `SPEC-DIGEST: <sha>`. Round 1 is a full fresh review. After an author
revise dispatch, rounds 2–3 are fix checks: also pass the immediately prior
`docs/drafts/<short-name>.round-<N-1>.findings.json` plus the current full draft; the Critic checks
the prior findings and reports any regressions or new blocking evidence under its shared contract.

The host saves each round's returned JSON verbatim as
`docs/drafts/<short-name>.round-<N>.findings.json` beside the sidecar. At adjudication it re-runs
`git hash-object <draft>`; a mismatch makes the verdict VOID and the findings are discarded unread.
For a non-clean round 1 or 2, adjudicate the findings, send the accepted fixes through an author
revise dispatch, wait for completion, then run the next fix check. A clean round proceeds to the
readiness gate.

### Convergence control — 3 rounds per SPEC LIFETIME, plus one owner-approved cycle

Every reviewed spec gets a **review-round record**: a sidecar `docs/drafts/<short-name>.review.log`
(deliberately not `.md` — spec tooling must never pick it up), created by the HOST at whichever comes first (the pre-draft arch-check row or the first author dispatch), never
by the author or the reviewer, deleted when the spec promotes to `docs/changes/`. One row per author dispatch or review round:

| Round | Dispatched (UTC) | Reviewer | Spec digest | Verdict | Disposition |

**One ROUND = one `apex-critic` spec-mode dispatch.** Its `Reviewer` cell is
`apex-critic:spec:<sonnet|opus>`. The Sol plan-check is its own pass and gets its own row.

**Round-column tokens:** `arch-N` = pre-draft architecture pass; `N` (an integer) = reviewer-family
round; `sol-N` = Sol cold read; `delib-N` = Sol deliberation; `author` = author dispatch; `owner` =
an owner decision. Author rows never count toward the reviewer-family round cap or the Sol round
count.

**Row lifecycle — TWO PHASES. This is the single definition; every rule below refers to it.**
1. **At DISPATCH** the host APPENDS the row with `Round`, `Dispatched (UTC)`, `Reviewer`, and
   `Spec digest` filled, and `Verdict` / `Disposition` both set to `pending`.
2. **At ADJUDICATION**, after the Critic returns, the host COMPLETES the same row: `Verdict` = the
   returned JSON `status`, `Disposition` = the outcome.

**Cap semantics, in the same breath:** a `pending` row COUNTS toward the <3 precondition — so a
second dispatch launched while the first is still out cannot slip past the cap — and a COMPLETED row
with `Disposition = VOID` does not count (a completed VOID row does NOT consume the cap). Everything
else counts. "Non-VOID rows" below means exactly this: every row except a completed VOID one.

- **Reviewer family and cap.** Reviewer-family rows are exactly the integer-numbered Critic
  spec-mode rows. At every tier, the cap is three non-VOID rows per spec lifetime unless the OWNER
  records approval for exactly one further fix-and-review cycle. The counter lives outside the
  draft, so a re-draft does not reset it. Exception: an owner-approved deletion under the re-approval and Normal-to-Big deletion rule ends that spec's lifetime. For a spec still in `docs/drafts/`, the HOST first appends an `owner` row recording the deletion to its sidecar and the spec's row to `C:/Users/User/apex/docs/research/spec-author-trial.md`, dated the deletion day, then deletes the spec, sidecar and findings. A promoted spec in `docs/changes/` already has its trial row and no sidecar, so the HOST deletes it with no new rows. The re-authored spec under its new name starts a new lifetime. Sol, author, and owner rows are not reviewer-family rows.
- **Host precondition — read before you dispatch.** Before any Critic spec-mode dispatch, read the
  sidecar and count non-VOID reviewer-family rows (`pending` counts; completed VOID does not). With
  three, refuse dispatch unless an `owner` row explicitly approves the one extra cycle; that
  approval permits only one further non-VOID Critic row. Zero means round 1: append its phase-1 row,
  then dispatch.
- **Round-3 escalation.** If round 3 `status` is not `clean`, send the Critic analysis to the OWNER
  and stop reviewer dispatch. The OWNER chooses: (a) accept the open findings and promote the spec,
  (b) approve exactly one further fix-and-review cycle, or (c) park or kill the spec. Append an
  `owner` row recording the choice before proceeding. Choice (b) runs one author revise followed
  by round 4, using round 3's findings file and the current full draft under the same model, digest,
  lifecycle, VOID, and write-barrier rules. If the extra review is not `clean`, return to the OWNER
  for only (a) accept and promote or (c) park or kill, and record that choice in another `owner` row
  before proceeding.
- **Same-path constraint.** Every review-driven revise targets the identical
  `docs/drafts/<short-name>.md`. Renaming a spec under review is prohibited because the sidecar is
  keyed by name. If a rename is truly required, manually move the sidecar and all round findings
  files alongside the spec, keeping their rows and numbering; never recreate or reset them.
- **Write barrier — an explicit gate precondition.** A round is dispatched only AFTER the
  completion notification for the last edit to the draft has arrived. Never dispatch while an
  author or editor worker on that draft is in flight; a mid-edit read is the known VOID-round cause.
- **Digest binding** (the two lifecycle phases, again): in phase 1 the host runs
  `git hash-object <draft>` and writes the value into the row's `Spec digest` cell as it appends the
  row, then passes the SAME value as the first line of the review prompt: `SPEC-DIGEST: <sha>`. In
  phase 2 the host re-runs `git hash-object <draft>` and compares it to that cell. **Mismatch → the
  verdict is VOID**: the findings are discarded unread, the row COMPLETES with Disposition
  `VOID (digest moved)`, and — as a completed VOID row — it does not count against the cap; the write
  barrier, not the cap, is what stops cycling. Never adjudicate a verdict whose digest did not match.
- **Recorded residual.** The digest binds the file the HOST hashed at dispatch, not the exact bytes
  the reviewer read; a path-based reviewer could in principle read a file edited in between. The
  write barrier plus hash-at-dispatch / re-hash-at-adjudication closes the practical race. Byte-proof
  would need reviewer-side hashing, which a read-only Agent-tool reviewer cannot return — accepted.

## Readiness gate — Deep Details only

The model already checks for vague paths, "maybe"/"TBD", missing done-when clauses, and unrequested
scope (RED-confirmed). **These are the items it does not reliably check.** Every one must pass; if
any fails, send the fixes through an author revise dispatch, then re-run the full gate from the top.

As the deterministic backstop to the prose Files-to-Change / Coverage / structure checkboxes (which retain judgment depth), on draft->changes promotion run `powershell.exe -NoProfile -File "$env:USERPROFILE\.claude\skills\apex-code\scripts\apex-spec-validate.ps1" -SpecPath <draft>`; a `FAIL` (exit 1) **BLOCKS** promotion.

```
[ ] Coverage      — every acceptance criterion maps to ≥1 task, every task to ≥1 criterion.
                    No orphan tasks. No uncovered criteria.
[ ] Sufficiency   — for every BEHAVIOURAL criterion, the mapped task's stated mechanism can
                    actually PRODUCE that behaviour. "Reuse/extend X" covers it only if X already
                    exhibits it (verify against the codebase) or the task adds the wiring step.
                    An outcome-stated task with no producing step is UNCOVERED — fail it.
[ ] Reachability  — every exposed boundary this spec adds or changes carries a SPEC-LEVEL
                    reachability criterion (one per boundary is fine) naming the wiring that makes
                    it reachable from a real caller. NEVER per task — entry wiring spans tasks, and
                    a shared integration file per task manufactures the file overlap that kills
                    wave parallelism. Typed client/server boundary → the criterion's mechanism is a
                    ROUND-TRIP test (encode → transport → decode → assert field equality), which is
                    what catches a silent DTO drop. deny-unknown-fields is a per-repo choice; this
                    gate never mandates it. Like Coverage and Sufficiency, this line is LLM-JUDGED
                    at gate time — apex-spec-validate.ps1 does not and cannot enforce it.
[ ] Map citations — the spec cites every map section it touches when a map exists.
[ ] Review rounds — the spec's review-round sidecar shows FEWER THAN 3 non-VOID reviewer-family
                    rows (`pending` rows count; completed Disposition=VOID rows do not — § Row
                    lifecycle) before any further Critic spec-mode dispatch, unless an `owner` row
                    approves exactly one further fix-and-review cycle. Round-3 non-clean and any
                    non-clean extra review follow the OWNER choices in Convergence control.
[ ] Batch-joinable— ## Files to Change disjoint from sibling pending specs; or each shared file
                    (types / barrel re-export / schema / route registry) owned by ONE spec, the
                    others declaring it in ## Prerequisites (ADR-029).
[ ] Wave plan     — present for ≥3 tasks; waves derived only from STATED dependencies.
[ ] Permissions   — every file, command, git op, and env var the build touches is listed.
                    New packages verified: exact name (typosquat), actively maintained.
[ ] Review        — Critic status is clean, or an `owner` row accepts the open findings.
[ ] Questions     — Risks/Open Questions section DELETED, not emptied. No [NEEDS CLARIFICATION].
[ ] ADR coverage  — every architectural decision this session has a written ADR file. "Noted
                    inline" fails.
[ ] Overview      — if architecture changed, overview.md updated + de-stubbed; decisions link to ADRs.
[ ] App-flow      — every UI spec names the app-flow screen(s)/journey it implements (ADR-013).
[ ] AGENTS.md     — marker and entire stub replaced and exact heading + adjacent fence retained per
                    references/agents-md-population.md at first spec-ready, and
                    whenever a spec changes layout, conventions, or the verify commands (ADR-031/037).
```

**Then the Sol plan-check, for Medium/High only** (ADR-032): a cold `gpt-6.1-sol` read, read-only,
schema'd, effort xhigh — `references/sol-plan-check.md`. Apply each slice's own tier: doc-only is Low unless it declares `risk: high`; explicit High wins. Every Medium or High Big-plan slice receives this independent post-readiness cold read. Low slices and doc-only specs without explicit High skip this pass.
It is advisory for Medium and **blocking for High**: an unresolved High BLOCK still gates
promotion. Sol never edits the spec. For High work you may *offer* (never auto-run) the ≤2-round
cross-model deliberation in that reference.

Only move to `docs/changes/` when the gate and every required pass are resolved.

## Confirmation digest

Never tell the user to "go read the file." Surface a digest in chat of **only the high-drift fields**
— the places the written spec could have drifted from the discussion:

- **Files** — every path + operation (create / modify / delete)
- **Acceptance criteria** — each as a one-line observable outcome
- **Decisions baked in** — especially any reversed mid-discussion or folded in late. This is where
  transcription drift hides.

Omit the why, the task breakdown, boilerplate. They are auditing *fidelity*, not re-reading the spec.
Close with: "Anything here not match what we discussed? Otherwise say 'start build.'"

Deep Details → digest + offer the file. Light → digest only.

## Closing the session

- **Deep Details / Light:** in order: (1) append one row to
  `C:\users\user\apex\docs\research\spec-author-trial.md` from the spec's sidecar (next bullet);
  (2) move the spec `docs/drafts/` -> `docs/changes/`; (3) delete the spec's `<short-name>.review.log`
  sidecar and every `<short-name>.round-<N>.findings.json` (the round record dies with promotion);
  (4) rewrite the
  `<!-- PLANNING -->` block of `docs/status.md` — Pending Specs (scan `docs/changes/`, not `done/`)
  and Open Questions (carry unresolved, add new, **delete resolved**). Update `_Last updated:_`.
- **Trial log row** (ADR-048), appended before the sidecar is deleted. Columns exactly:
  `date | repo | spec | author models | reviewer-family rounds | Sol rounds | intent drift | notes`.
  Use the promotion date and repo path. Author models come only from sidecar `author` rows with
  Disposition = `launched` and Reviewer = `author:<model>:<create|revise>`: list launched create rows
  in order, counting repeated models, then revise rows in order with counts, for example
  `gpt-6-sol create x2; revise gpt-6-sol x1`. Reviewer-family rounds = non-VOID integer `N` rows (one
  row per Critic spec-mode dispatch). Sol rounds = non-VOID `sol-N` and `delib-N` rows; `arch-N` rows are
  excluded. A legacy spec promoted with no sidecar logs author models = `unknown (no sidecar)` and
  zero round counts. Intent drift = `y` only when the owner flags a mismatch at the confirmation
  digest, otherwise `n`. A re-promotion of the same repo/spec appends a new row with `re-promote` in
  notes; never overwrite an earlier row. If the log does not exist yet, create it with the header
  `| date | repo | spec | author models | reviewer-family rounds | Sol rounds | intent drift | notes |`
  and its separator, and verify that header with `Select-String -SimpleMatch` before the first append.
- **status.md is LIVE STATE — rewritten, never appended. ≤100 lines** (ADR-037). A finished row is
  **deleted**, not marked done; git is the record. Never let a session narrative land here.
- ADR + status procedures (formats, numbering) → `references/adr-and-status-procedures.md`.
