---
skill: apex-plan
version: 2.4.1
last_updated: 2026-08-02
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
   patch the spec in place, or pull it back to `docs/drafts/`. Delete the record once drained.
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
5. Repo-root **`AGENTS.md`** still stubbed while â‰¥1 spec sits in `docs/changes/` â€” **Codex builds
   read AGENTS.md, not these skills** (ADR-031/037).

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

**FIRST, before you dispatch the author (Deep Details only): the pre-draft Sol architecture pass** â€”
a cold `gpt-5.6-sol` read of the PLAN BRIEF (problem statement, proposed structure, file map), not
of a spec. ADR-032 Â§1b; recipe in `references/sol-plan-check.md` Â§ Pre-draft architecture pass.
Advisory by default; for `risk: high` it is an **approval gate** â€” an unresolved BLOCK means you
print the **apex-governance Â§ Approval gate** banner and get the explicit `Approve? [y / n / edit]`
answer BEFORE any spec-author dispatch. Adjudicate its findings into the plan before drafting. It
never replaces the post-readiness cold read below, and that read never sees its output.

Template: `~/.claude/skills/apex-orchestrate/templates/spec-template.md`.
**You do not draft it yourself (ADR-045).** Resolve the open decisions, then dispatch a `model: opus`
spec-author worker with the plan, the template path, and the target path
`docs/drafts/{short-name}.md` â€” never straight to `docs/changes/`. The author drafts; you review its
draft against the rules below and the readiness gate. The rest of this section is the contract you
hand the author and grade against.

**Split rule:** >3 files or >2 logical phases â†’ split. When you split (or write alongside other
pending specs), make the specs **file-disjoint**, with any real dependency as a `## Prerequisites`
edge â€” so a session drains the whole set as parallel waves (ADR-029).

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
   (ADR-031).
2. **Tasks state the *mechanism*, not just the outcome.** A "reuse/extend X" task cannot achieve a
   behaviour X structurally lacks. Name the concrete producing step â€” the wiring that *emits* the
   behaviour. This is the highest-yield spec defect and it hides behind plausible prose.
3. **One concern layer per task** (API / DB / UI / test). Never manufacture thin tasks to raise
   worker count â€” spawn overhead exceeds the saving.

**`## Wave plan`** (specs with â‰¥3 tasks): derive a **PROPOSED** wave plan from the *stated*
dependencies â€” `Wave 1: [1, 2] | Wave 2: [3]`. The **dependencies are binding**; the **grouping is advisory**.
Final task selection and sequencing are **orchestrator-owned** — the dispatched `apex-build-orchestrator` on an attended build, the host as executor on an unattended one (ADR-046 D1). Do the analysis here so the
executor has a defensible starting point, not so it is spared judgement. Independence you can't
establish â†’ sequential.

**Frontmatter levers:** `coder_effort: {low|medium|high|xhigh|max|ultra}` (default `medium`; `high`
for risk:high/auth/security/data) Â· `coder_model: {codex|sonnet}` pins a whole spec Â·
`cross_model_review: true` for auth/security/data-migration â€” deliberate, never a default.
Full rubric â†’ `references/model-routing.md`.

## Dispatched spec review

Before the readiness gate, dispatch a **fresh-context** adversarial review. You cannot stress-test
your own reasoning; that is the point. **Evaluator-independence, not a rulebook** â€” there is no
domain skill to review against (ADR-036), and the value never came from one: the Sol plan-check
proving run returned three real BLOCKs (the launcher pinned the model, ExecutionPolicy, a routing
gap) and not one came from a domain rule.

Dispatch `apex-spec-reviewer` (Agent tool). Pass `spec` (draft path or text) and optionally a
`lens` â€” "security", "migration safety", "does this mechanism actually produce the behaviour".
It reads the spec plus the files the spec names, sandboxed from planning docs, and returns
BLOCK / FLAG / note, each cited to **evidence** (file:line, quoted clause, failing scenario).

**Before dispatching, the host runs `git hash-object <draft>`, writes the value into the round's
sidecar row, and passes it as the FIRST line of the reviewer prompt: `SPEC-DIGEST: <sha>`.** At
adjudication the host re-runs `git hash-object <draft>`; if it no longer matches the recorded row,
the verdict is VOID and its findings are discarded unread (Â§ Convergence control).

- **Always**, with 2â€“3 **different lenses** in parallel: security, auth, data/migrations, anything
  hard to reverse. Diverse lenses catch what redundancy can't.
- **One reviewer** for an ordinary multi-file spec. **Skip** a trivial single-file spec.

Every BLOCK resolved in the spec; every FLAG resolved or explicitly accepted with reasoning.

### Convergence control â€” 3 rounds, per SPEC LIFETIME

Every reviewed spec gets a **review-round record**: a sidecar `docs/drafts/<short-name>.review.log`
(deliberately not `.md` â€” spec tooling must never pick it up), created by the HOST at round 1, never
by the author or the reviewer, deleted when the spec promotes to `docs/changes/`. One row per round:

| Round | Dispatched (UTC) | Reviewer | Spec digest | Verdict | Disposition |

**One ROUND = one review PASS**, however many lenses that pass dispatches in parallel: a 3-lens
apex-spec-reviewer fan-out is ONE row, and the `Reviewer` cell carries the comma-joined lens list
(`security, migration safety, mechanism`). The Sol plan-check is its own pass and gets its own row.

**Row lifecycle â€” TWO PHASES. This is the single definition; every rule below refers to it.**
1. **At DISPATCH** the host APPENDS the row with `Round`, `Dispatched (UTC)`, `Reviewer` (the lens
   list), and `Spec digest` filled, and `Verdict` / `Disposition` both set to `pending`.
2. **At ADJUDICATION**, and only after ALL lenses of that pass have returned, the host COMPLETES the
   same row: `Verdict` = worst-of, `Disposition` = the outcome.

**Cap semantics, in the same breath:** a `pending` row COUNTS toward the <3 precondition â€” so a
second dispatch launched while the first is still out cannot slip past the cap â€” and a COMPLETED row
with `Disposition = VOID` does not count (a completed VOID row does NOT consume the cap). Everything
else counts. "Non-VOID rows" below means exactly this: every row except a completed VOID one.

**Multi-lens aggregation** (phase 2 of the lifecycle): adjudication waits for ALL lenses of the pass,
then writes `Verdict` = WORST-OF its lenses (BLOCK > FLAG > CLEAN). If ANY lens returns against a
digest that no longer matches, the WHOLE row completes as VOID â€” no partial adjudication, no
cherry-picking a clean lens â€” and, being a completed VOID row, it does not count.

- **Cap: 3 rounds per spec LIFETIME â€” apex-spec-reviewer FAMILY only.** The counter is the sidecar's
  count of non-VOID reviewer-family rows as defined by the lifecycle above (`pending` counts, a
  completed VOID does not); it lives outside the draft, so a re-draft does not reset it. Reviewer-family rounds 4+ are not dispatched. The Sol plan-check appends its
  own digest-bound row and is EXEMPT from this count (it is mandatory at the gate and must stay
  available after the cap); its own cycling is bounded by the announced pass-or-park rule.
- **Host precondition â€” read before you dispatch.** Before ANY reviewer-family dispatch, the host
  READS `docs/drafts/<short-name>.review.log` and counts its non-VOID reviewer-family rows per the
  lifecycle definition (`pending` rows included). **At â‰¥3 the dispatch is REFUSED** â€” no reviewer is
  launched â€” and the spec routes to the post-cap path below. A missing sidecar means round 1: append
  the phase-1 row, then dispatch.
- **The post-cap path is not a dead end.** Fresh draft against the closed fix-list â†’ readiness gate
  â†’ Sol cold read (still mandatory, still dispatched) â†’ promotion. An exhausted reviewer-family cap
  never blocks that path; it only stops further apex-spec-reviewer passes.
- **Same-path constraint.** A post-cap fresh draft MUST target the identical
  `docs/drafts/<short-name>.md`. Renaming a spec while it is under review is PROHIBITED, because the
  sidecar is keyed by the name and a rename silently resets the counter. If a rename is truly
  required, it is a manual carry-over step: MOVE the sidecar alongside the spec, keeping its rows â€”
  never recreate it, never start a new one.
- **At the cap**, stop reviewing and hand a FRESH drafter a **CLOSED fix-list**: the exact
  unresolved findings as of round 3, frozen. No new lenses, no additions after handoff. The next
  draft is graded against that list and the readiness gate only.
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
any fails, fix in place and re-run from the top.

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
                    for the evidence, not the claim. LLM-judged, like the line above.
[ ] Review rounds â€” the spec's review-round sidecar shows FEWER THAN 3 non-VOID reviewer-family
                    rows (`pending` rows count; completed Disposition=VOID rows do not â€” Â§ Row
                    lifecycle) before any further apex-spec-reviewer dispatch. At 3
                    that dispatch is refused and the spec routes to the closed-fix-list fresh-draft
                    path (Â§ Dispatched spec review â†’ Convergence control), which also owns the
                    same-path/no-rename constraint. The mandatory Sol plan-check is EXEMPT from this
                    count and still runs on the post-cap path.
[ ] Batch-joinableâ€” ## Files to Change disjoint from sibling pending specs; or each shared file
                    (types / barrel re-export / schema / route registry) owned by ONE spec, the
                    others declaring it in ## Prerequisites (ADR-029).
[ ] Wave plan     â€” present for â‰¥3 tasks; waves derived only from STATED dependencies.
[ ] Permissions   â€” every file, command, git op, and env var the build touches is listed.
                    New packages verified: exact name (typosquat), actively maintained.
[ ] Review        â€” all BLOCK findings resolved; all FLAGs resolved or accepted with reasoning.
[ ] Questions     â€” Risks/Open Questions section DELETED, not emptied. No [NEEDS CLARIFICATION].
[ ] ADR coverage  â€” every architectural decision this session has a written ADR file. "Noted
                    inline" fails.
[ ] Overview      â€” if architecture changed, overview.md updated + de-stubbed; decisions link to ADRs.
[ ] App-flow      â€” every UI spec names the app-flow screen(s)/journey it implements (ADR-013).
[ ] AGENTS.md     â€” populated per references/agents-md-population.md at first spec-ready, and
                    whenever a spec changes layout, conventions, or the verify commands (ADR-031/037).
```

**Then the Sol plan-check** (ADR-032): a cold `gpt-5.6-sol` read, read-only, schema'd, effort xhigh â€”
`references/sol-plan-check.md`. Advisory by default, **blocking for `risk: high`**. Sol never edits
the spec. Skip only trivial specs. For high-risk work you may *offer* (never auto-run) the â‰¤2-round
cross-model deliberation in that reference.

Only move to `docs/changes/` when the gate and the plan-check are both resolved.

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

- **Deep Details / Light:** move the spec `docs/drafts/` â†’ `docs/changes/`, delete the spec's
  `<short-name>.review.log` sidecar (host's pen â€” the round record dies with the promotion), then rewrite the
  `<!-- PLANNING -->` block of `docs/status.md` â€” Pending Specs (scan `docs/changes/`, not `done/`)
  and Open Questions (carry unresolved, add new, **delete resolved**). Update `_Last updated:_`.
- **status.md is LIVE STATE â€” rewritten, never appended. â‰¤100 lines** (ADR-037). A finished row is
  **deleted**, not marked done; git is the record. Never let a session narrative land here.
- **Bug Fix:** no status.md update â€” ephemeral.
- ADR + status procedures (formats, numbering) â†’ `references/adr-and-status-procedures.md`.
