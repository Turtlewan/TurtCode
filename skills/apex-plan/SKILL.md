---
skill: apex-plan
version: 2.8.1
last_updated: 2026-10-10
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
  Use when planning â€” turning requirements into docs/changes specs. Triggers: plan /
  design / architect / spec / "let's build". Owns spec authoring, research gate, readiness
  gate, ADRs. Not build (apex-code).
---

# APEX Planning

Turn requirements into specs a coder can execute **without asking anything**.

**This skill carries the machinery, not the judgment.** How to write a good spec â€” name exact files,
make criteria runnable, strip the *why*, ask before drafting, don't over-scope â€” is **model-native**
and was cut in v2.0.0 after a RED probe reproduced all of it cold, including the no-why litmus
verbatim (ADR-036). What remains is what a bare agent cannot know: APEX's artifacts, its gates, and
the traps that only surface on a second pass.

## Session start

1. Read `docs/status.md` â€” In-Flight, Pending Specs, Open Questions.
2. Read `docs/drafts/` â€” unfinished specs (`*.review.log` sidecars are review-round records, not drafts).
3. Check `docs/progress/*.md` â€” capture-at-halt records from blocked builds. Each must be **drained**:
   pull the spec back to `docs/drafts/` and apply the fixes through an `-AuthorSpec` revise
   dispatch (see Writing the spec). Delete the record once drained.
4. Read the latest `docs/handoff/*.md` â€” see Â§ Drain the handoff.
5. Run the doc-coverage check (below).
6. Acknowledge: "{n} pending spec(s): {list}. Flags from last build: {or none}. Doc coverage:
   {result}. What are we working on?"

### Doc-coverage check â€” informational, never blocks

One line, or "clean":
1. `docs/technical/architecture/overview.md` missing, or still carries `<!-- apex:overview:stub -->`.
2. Decisions in the handoff or status.md with no matching `docs/technical/adr/ADR-NNN-*.md`.
3. overview.md older than the newest ADR, **or not updated since the last spec archived to
   `docs/changes/done/`** (ADR-014).
4. Scope-gated stubs still stubbed while a spec in their scope is in play: `data-model.md`
   (ADR-008) Â· `app-flow.md` (ADR-013) Â· `design-brief.md` (ADR-017).
5. Repo-root **`AGENTS.md`** still stubbed while â‰¥1 spec sits in `docs/changes/`, or its exact
   `## Verify commands` heading lacks the adjacent populated fence â€” **Codex builds read AGENTS.md,
   not these skills** (ADR-031/037).

### Drain the handoff â€” inbox-zero, this session

The handoff is read **once**. Surfacing an item is not landing it. Every item terminates in exactly
one of: **Pending Spec** Â· **Open Question** (status.md) Â· **Folded** (written into a spec / skill /
ADR / `feedback` memory *now*) Â· **Discarded** (explicitly judged not actionable).

An item read and not filed is gone. Land each disposition this session.

**The learning loop (ADR-011):** a build lesson or a user correction folds into a `feedback` memory
at the drain. Don't wait for recurrence â€” when the user flags a deliverable they loved, post-mortem
it *while it's still in context*. A recurring lesson earns promotion via `apex-skill-author`
(human-gated, Iron Law).

## Mode

Ask, and recommend the lightest that fits â€” don't default to heavy for a one-file change:

| Mode | For | Ceremony |
|------|-----|----------|
| **Deep Details** | multi-file / architectural | full template Â· dispatched review Â· readiness gate Â· ADRs |
| **Light** | a contained change | intent Â· key decisions Â· acceptance criteria Â· no gate |
| **Bug Fix** | a bug | bug Â· root cause Â· fix approach Â· files. No gate, no ADR, no status.md update |

## Before drafting â€” resolve, don't discover

The coder executes silently against **frozen** criteria, in a fresh context, and cannot ask you
anything. So **every build-changing decision must be resolved before the spec freezes** â€” this is
the only place that can happen.

- **Resolve yourself:** codebase facts (read the files), clear technical defaults, anything derivable.
- **Ask the user:** product intent, preference between technically-valid options, edge-case priority,
  "what does good look like." Judgment, not facts. Batch the asks; don't drip them.
- **Leave to the coder:** bounded micro-ambiguity (which existing pattern to follow, a local name).

Drafting first and validating after is the failure mode â€” it produces guessed field lists and
punted decisions dressed up as "open questions."

### Widen the options â€” the research gate

Before locking an approach, check you have more than one. If the decision is **contested,
high-stakes, and hard to reverse** â†’ `apex-deep-dive` (2â€“3 options, trade-offs) or its **Council
mode** (three blind fresh-context voices â€” anti-anchoring, ADR-010). For "what's current / which
tool" â†’ `apex-research`. For a routine call with an obvious default â†’ neither; just decide.

UI-bearing work â†’ `references/design-workflow.md` (persisted app-flow + design-brief artifacts, the
ask-first aesthetic gate, the cheap-mockup loop, the visual review gate).

## Writing the spec

**FIRST, before you dispatch the author (Deep Details, Medium/High only): the pre-draft Sol
architecture pass** â€” a cold `gpt-6.1-sol` read of the PLAN BRIEF (problem statement, proposed
structure, file map), not of a spec. ADR-032 Â§1b; recipe in `references/sol-plan-check.md` Â§
Pre-draft architecture pass. Low and doc-only specs skip this pass. It is advisory for Medium; for
High it is an **approval gate** â€” an unresolved BLOCK means you print the **apex-governance Â§
Approval gate** banner and get the explicit `Approve? [y / n / edit]` answer BEFORE any spec-author
dispatch. Adjudicate its findings into the plan before drafting. It never replaces the
post-readiness cold read below, and that read never sees its output.

Template: `~/.claude/skills/apex-orchestrate/templates/spec-template.md`. Derive its execution manifest,
Files to Change, and Tasks list from the same decisions: one entry per coder task, with explicit file operation and dependency IDs; exclude HOST/OWNER tasks from the manifest.
**You do not draft it yourself (ADR-045, ADR-048).** Resolve the open decisions, then dispatch the
spec author: gpt-6-sol through the wrapper's author mode. The host assembles a prompt pack (`$pack`)
containing the adjudicated plan brief, the exact template path, the target `docs/drafts/<short-name>.md`
(never straight to `docs/changes/`), and the three rules below (no why inline except Intent, mechanism
in each task, one concern per task). For an absent draft, create:

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

**Split rule:** >3 files or >2 logical phases â†’ split, except doc-only specs. When you split (or
write alongside other pending specs), make the specs **file-disjoint**, with any real dependency
as a `## Prerequisites` edge â€” so a session drains the whole set as parallel waves (ADR-029).

### Spec one WAVE ahead â€” never the whole roadmap (the default)

Design the whole thing. **Then spec and build one dependency wave at a time:**

> spec wave 1 â†’ **build wave 1** â†’ spec wave 2 *against the real, shipped wave-1 code* â†’ build wave 2

**Inside a wave**, specs are dependency-independent by construction, so spec them all up front and
dispatch them in parallel â€” you keep the full batching win. **Across waves, never.** A spec that
consumes another spec's *output shape* is being written against an interface that **does not exist
yet**, and you will not find out until the build.

This is not theoretical. Artemis's 35-spec one-shot (2026-07-14) shipped, but **four of its six
host-caught defects were spec-ahead damage**, and every one of them landed in a *chained* family
(mcp aâ†’bâ†’c, map3â†’map4, ref, pr) while the independent specs came through clean. The deepest â€”
`dto.ts`/`gateway.ts` appearing in **no** spec's file list across mcp6a/6b/6c â€” would have broken
every invoke-confirm call at the IPC layer. The same run also found "10 of 47 unbuilt specs were
already shipped, just unarchived": **specs written far ahead of the build decay, because the codebase
moves under them.**

The cost used to be a session restart. It isn't any more (ADR-038 â€” one session plans and builds), so
the main argument for spec-everything-first is gone.

**Spec further ahead only when** the specs are genuinely file-disjoint *and* depend on no interface
that doesn't exist yet. That is the same test as `Batch-joinable` in the readiness gate â€” if a spec
fails that, it is also too far ahead to write.

**Three rules a bare model does not reliably apply:**

1. **No *why* inline.** Litmus: does it change what gets built? **No** â†’ cut it (home = an ADR).
   **Yes** â†’ don't add the why, make the *what* explicit. One exception: the template's `## Intent`
   block (intent / invariants / non-goals, â‰¤10 lines) â€” it travels to the coder in the dispatch pack
   (ADR-031). Under the definition in Intent, declare `risk: low|medium|high`; absent = medium. A
   doc-only spec is Low unless it explicitly declares `risk: high`, which always wins. Doc-only
   means every Files-to-Change path is documentation prose under `docs/`, an ADR, README, or
   CHANGELOG, and none is a skill (`SKILL.md`, `references/**`, `templates/**`), agent, hook,
   settings, script, or other config/instruction file.
2. **Tasks state the *mechanism*, not just the outcome.** A "reuse/extend X" task cannot achieve a
   behaviour X structurally lacks. Name the concrete producing step â€” the wiring that *emits* the
   behaviour. This is the highest-yield spec defect and it hides behind plausible prose.
3. **One concern layer per task** (API / DB / UI / test). Never manufacture thin tasks to raise
   worker count â€” spawn overhead exceeds the saving.

For doc-only work, write acceptance criteria as presence/absence, version/date, cap, pointer, and
verify-fence checks. Exact-line manifests and whole-tree hashes are reserved for High specs.

**`## Wave plan`** (specs with â‰¥3 tasks): derive a **PROPOSED** wave plan from the *stated*
dependencies â€” `Wave 1: [1, 2] | Wave 2: [3]`. The **dependencies are binding**; the **grouping is advisory**.
Prefer Engine-compatible, manifest-backed, file-disjoint single-repo specs where they fit; this
shape is not required. The **Engine** determines task selection and sequencing for eligible
attended specs from manifest `depends_on`; **HOST** schedules the manual path for refused specs
and executes unattended builds. Do the analysis here so HOST has a defensible starting point.
Independence you can't establish means sequential.

**Frontmatter levers:** `coder_effort: {low|medium|high|xhigh|max|ultra}` (default `medium`; `high`
for risk:high/auth/security/data) Â· `coder_model: {codex|sonnet}` pins a whole spec Â·
`cross_model_review: true` for auth/security/data-migration â€” deliberate, never a default.
Full rubric â†’ `references/model-routing.md`.

## Dispatched spec review

Before the readiness gate, dispatch `apex-critic` through the Agent tool with `mode: spec`. On
**every dispatch**, pass Agent tool `model: sonnet` for Low, Medium, and doc-only specs, and
`model: opus` for High. The Agent tool's `model:` parameter takes precedence over the agent file's
default frontmatter `model: sonnet`.

Every Critic prompt contains the author prompt pack's adjudicated plan brief and the current full
draft under review, so intent fidelity is reviewable. Before dispatching, the host runs
`git hash-object <draft>`, writes the value into the round's sidecar row, and passes it as the
**FIRST line** of the prompt: `SPEC-DIGEST: <sha>`. Round 1 is a full fresh review. After an author
revise dispatch, rounds 2â€“3 are fix checks: also pass the immediately prior
`docs/drafts/<short-name>.round-<N-1>.findings.json` plus the current full draft; the Critic checks
the prior findings and reports any regressions or new blocking evidence under its shared contract.

The host saves each round's returned JSON verbatim as
`docs/drafts/<short-name>.round-<N>.findings.json` beside the sidecar. At adjudication it re-runs
`git hash-object <draft>`; a mismatch makes the verdict VOID and the findings are discarded unread.
For a non-clean round 1 or 2, adjudicate the findings, send the accepted fixes through an author
revise dispatch, wait for completion, then run the next fix check. A clean round proceeds to the
readiness gate.

### Convergence control â€” 3 rounds per SPEC LIFETIME, plus one owner-approved cycle

Every reviewed spec gets a **review-round record**: a sidecar `docs/drafts/<short-name>.review.log`
(deliberately not `.md` â€” spec tooling must never pick it up), created by the HOST at whichever comes first (the pre-draft arch-check row or the first author dispatch), never
by the author or the reviewer, deleted when the spec promotes to `docs/changes/`. One row per author dispatch or review round:

| Round | Dispatched (UTC) | Reviewer | Spec digest | Verdict | Disposition |

**One ROUND = one `apex-critic` spec-mode dispatch.** Its `Reviewer` cell is
`apex-critic:spec:<sonnet|opus>`. The Sol plan-check is its own pass and gets its own row.

**Round-column tokens:** `arch-N` = pre-draft architecture pass; `N` (an integer) = reviewer-family
round; `sol-N` = Sol cold read; `delib-N` = Sol deliberation; `author` = author dispatch; `owner` =
an owner decision. Author rows never count toward the reviewer-family round cap or the Sol round
count.

**Row lifecycle â€” TWO PHASES. This is the single definition; every rule below refers to it.**
1. **At DISPATCH** the host APPENDS the row with `Round`, `Dispatched (UTC)`, `Reviewer`, and
   `Spec digest` filled, and `Verdict` / `Disposition` both set to `pending`.
2. **At ADJUDICATION**, after the Critic returns, the host COMPLETES the same row: `Verdict` = the
   returned JSON `status`, `Disposition` = the outcome.

**Cap semantics, in the same breath:** a `pending` row COUNTS toward the <3 precondition â€” so a
second dispatch launched while the first is still out cannot slip past the cap â€” and a COMPLETED row
with `Disposition = VOID` does not count (a completed VOID row does NOT consume the cap). Everything
else counts. "Non-VOID rows" below means exactly this: every row except a completed VOID one.

- **Reviewer family and cap.** Reviewer-family rows are exactly the integer-numbered Critic
  spec-mode rows. At every tier, the cap is three non-VOID rows per spec lifetime unless the OWNER
  records approval for exactly one further fix-and-review cycle. The counter lives outside the
  draft, so a re-draft does not reset it. Sol, author, and owner rows are not reviewer-family rows.
- **Host precondition â€” read before you dispatch.** Before any Critic spec-mode dispatch, read the
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
- **Write barrier â€” an explicit gate precondition.** A round is dispatched only AFTER the
  completion notification for the last edit to the draft has arrived. Never dispatch while an
  author or editor worker on that draft is in flight; a mid-edit read is the known VOID-round cause.
- **Digest binding** (the two lifecycle phases, again): in phase 1 the host runs
  `git hash-object <draft>` and writes the value into the row's `Spec digest` cell as it appends the
  row, then passes the SAME value as the first line of the review prompt: `SPEC-DIGEST: <sha>`. In
  phase 2 the host re-runs `git hash-object <draft>` and compares it to that cell. **Mismatch â†’ the
  verdict is VOID**: the findings are discarded unread, the row COMPLETES with Disposition
  `VOID (digest moved)`, and â€” as a completed VOID row â€” it does not count against the cap; the write
  barrier, not the cap, is what stops cycling. Never adjudicate a verdict whose digest did not match.
- **Recorded residual.** The digest binds the file the HOST hashed at dispatch, not the exact bytes
  the reviewer read; a path-based reviewer could in principle read a file edited in between. The
  write barrier plus hash-at-dispatch / re-hash-at-adjudication closes the practical race. Byte-proof
  would need reviewer-side hashing, which a read-only Agent-tool reviewer cannot return â€” accepted.

## Readiness gate â€” Deep Details only

The model already checks for vague paths, "maybe"/"TBD", missing done-when clauses, and unrequested
scope (RED-confirmed). **These are the items it does not reliably check.** Every one must pass; if
any fails, send the fixes through an author revise dispatch, then re-run the full gate from the top.

As the deterministic backstop to the prose Files-to-Change / Coverage / structure checkboxes (which retain judgment depth), on draft->changes promotion run `powershell.exe -NoProfile -File "$env:USERPROFILE\.claude\skills\apex-code\scripts\apex-spec-validate.ps1" -SpecPath <draft>`; a `FAIL` (exit 1) **BLOCKS** promotion.

```
[ ] Coverage      â€” every acceptance criterion maps to â‰¥1 task, every task to â‰¥1 criterion.
                    No orphan tasks. No uncovered criteria.
[ ] Sufficiency   â€” for every BEHAVIOURAL criterion, the mapped task's stated mechanism can
                    actually PRODUCE that behaviour. "Reuse/extend X" covers it only if X already
                    exhibits it (verify against the codebase) or the task adds the wiring step.
                    An outcome-stated task with no producing step is UNCOVERED â€” fail it.
[ ] Reachability  â€” every exposed boundary this spec adds or changes carries a SPEC-LEVEL
                    reachability criterion (one per boundary is fine) naming the wiring that makes
                    it reachable from a real caller. NEVER per task â€” entry wiring spans tasks, and
                    a shared integration file per task manufactures the file overlap that kills
                    wave parallelism. Typed client/server boundary â†’ the criterion's mechanism is a
                    ROUND-TRIP test (encode â†’ transport â†’ decode â†’ assert field equality), which is
                    what catches a silent DTO drop. deny-unknown-fields is a per-repo choice; this
                    gate never mandates it. Like Coverage and Sufficiency, this line is LLM-JUDGED
                    at gate time â€” apex-spec-validate.ps1 does not and cannot enforce it.
[ ] Files evidenceâ€” the author GREPPED the live tree before listing ## Files to Change: a
                    `Grep evidence:` line under the table records each pattern run and its hit
                    count, for consumers of every changed file and for every path listed. Prose
                    assurance ("checked the tree", "verified paths") FAILS this line â€” the check is
                    for the evidence, not the claim. LLM-judged, like the line above. Doc-only
                    criteria use presence/absence, version/date, cap, pointer, and verify-fence
                    checks; exact-line manifests and whole-tree hashes are High-only.
[ ] Review rounds â€” the spec's review-round sidecar shows FEWER THAN 3 non-VOID reviewer-family
                    rows (`pending` rows count; completed Disposition=VOID rows do not â€” Â§ Row
                    lifecycle) before any further Critic spec-mode dispatch, unless an `owner` row
                    approves exactly one further fix-and-review cycle. Round-3 non-clean and any
                    non-clean extra review follow the OWNER choices in Convergence control.
[ ] Batch-joinableâ€” ## Files to Change disjoint from sibling pending specs; or each shared file
                    (types / barrel re-export / schema / route registry) owned by ONE spec, the
                    others declaring it in ## Prerequisites (ADR-029).
[ ] Wave plan     â€” present for â‰¥3 tasks; waves derived only from STATED dependencies.
[ ] Permissions   â€” every file, command, git op, and env var the build touches is listed.
                    New packages verified: exact name (typosquat), actively maintained.
[ ] Review        â€” Critic status is clean, or an `owner` row accepts the open findings.
[ ] Questions     â€” Risks/Open Questions section DELETED, not emptied. No [NEEDS CLARIFICATION].
[ ] ADR coverage  â€” every architectural decision this session has a written ADR file. "Noted
                    inline" fails.
[ ] Overview      â€” if architecture changed, overview.md updated + de-stubbed; decisions link to ADRs.
[ ] App-flow      â€” every UI spec names the app-flow screen(s)/journey it implements (ADR-013).
[ ] AGENTS.md     â€” marker and entire stub replaced and exact heading + adjacent fence retained per
                    references/agents-md-population.md at first spec-ready, and
                    whenever a spec changes layout, conventions, or the verify commands (ADR-031/037).
```

**Then the Sol plan-check, for Medium/High only** (ADR-032): a cold `gpt-6.1-sol` read, read-only,
schema'd, effort xhigh â€” `references/sol-plan-check.md`. Low and doc-only specs skip this pass.
It is advisory for Medium and **blocking for High**: an unresolved High BLOCK still gates
promotion. Sol never edits the spec. For High work you may *offer* (never auto-run) the â‰¤2-round
cross-model deliberation in that reference.

Only move to `docs/changes/` when the gate and every required pass are resolved.

## Confirmation digest

Never tell the user to "go read the file." Surface a digest in chat of **only the high-drift fields**
â€” the places the written spec could have drifted from the discussion:

- **Files** â€” every path + operation (create / modify / delete)
- **Acceptance criteria** â€” each as a one-line observable outcome
- **Decisions baked in** â€” especially any reversed mid-discussion or folded in late. This is where
  transcription drift hides.

Omit the why, the task breakdown, boilerplate. They are auditing *fidelity*, not re-reading the spec.
Close with: "Anything here not match what we discussed? Otherwise say 'start build.'"

Deep Details â†’ digest + offer the file. Light â†’ digest only. Bug Fix â†’ one-line verbal confirm.

## Closing the session

- **Deep Details / Light:** in order: (1) append one row to
  `C:\users\user\apex\docs\research\spec-author-trial.md` from the spec's sidecar (next bullet);
  (2) move the spec `docs/drafts/` -> `docs/changes/`; (3) delete the spec's `<short-name>.review.log`
  sidecar and every `<short-name>.round-<N>.findings.json` (the round record dies with promotion);
  (4) rewrite the
  `<!-- PLANNING -->` block of `docs/status.md` â€” Pending Specs (scan `docs/changes/`, not `done/`)
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
- **status.md is LIVE STATE â€” rewritten, never appended. â‰¤100 lines** (ADR-037). A finished row is
  **deleted**, not marked done; git is the record. Never let a session narrative land here.
- **Bug Fix:** no status.md update â€” ephemeral.
- ADR + status procedures (formats, numbering) â†’ `references/adr-and-status-procedures.md`.
