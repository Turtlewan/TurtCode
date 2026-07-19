---
skill: apex-plan
version: 2.1.0
last_updated: 2026-07-16
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
  Use when planning — turning requirements into executable docs/changes specs, designing an
  approach, or shaping a build. Triggers: plan / design / architect / spec / "let's build" /
  "what if". Owns spec authoring, the research gate, dispatched review, the readiness gate,
  ADRs, and the confirmation digest. Not the build (apex-code) or standalone research
  (apex-deep-dive).
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
2. Read `docs/drafts/` — unfinished specs.
3. Check `docs/progress/*.md` — capture-at-halt records from blocked builds. Each must be **drained**:
   patch the spec in place, or pull it back to `docs/drafts/`. Delete the record once drained.
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
5. Repo-root **`AGENTS.md`** still stubbed while ≥1 spec sits in `docs/changes/` — **Codex builds
   read AGENTS.md, not these skills** (ADR-031/037).

### Drain the handoff — inbox-zero, this session

The handoff is read **once**. Surfacing an item is not landing it. Every item terminates in exactly
one of: **Pending Spec** · **Open Question** (status.md) · **Folded** (written into a spec / skill /
ADR / `feedback` memory *now*) · **Discarded** (explicitly judged not actionable).

An item read and not filed is gone. Land each disposition this session.

**The learning loop (ADR-011):** a build lesson or a user correction folds into a `feedback` memory
at the drain. Don't wait for recurrence — when the user flags a deliverable they loved, post-mortem
it *while it's still in context*. A recurring lesson earns promotion via `apex-skill-author`
(human-gated, Iron Law).

## Mode

Ask, and recommend the lightest that fits — don't default to heavy for a one-file change:

| Mode | For | Ceremony |
|------|-----|----------|
| **Deep Details** | multi-file / architectural | full template · dispatched review · readiness gate · ADRs |
| **Light** | a contained change | intent · key decisions · acceptance criteria · no gate |
| **Bug Fix** | a bug | bug · root cause · fix approach · files. No gate, no ADR, no status.md update |

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

Template: `~/.claude/skills/apex-orchestrate/templates/spec-template.md`.
Write to **`docs/drafts/{short-name}.md`** first — never straight to `docs/changes/`.

**Split rule:** >3 files or >2 logical phases → split. When you split (or write alongside other
pending specs), make the specs **file-disjoint**, with any real dependency as a `## Prerequisites`
edge — so a session drains the whole set as parallel waves (ADR-029).

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
   (ADR-031).
2. **Tasks state the *mechanism*, not just the outcome.** A "reuse/extend X" task cannot achieve a
   behaviour X structurally lacks. Name the concrete producing step — the wiring that *emits* the
   behaviour. This is the highest-yield spec defect and it hides behind plausible prose.
3. **One concern layer per task** (API / DB / UI / test). Never manufacture thin tasks to raise
   worker count — spawn overhead exceeds the saving.

**`## Wave plan`** (specs with ≥3 tasks): group tasks into waves from the *stated* dependencies —
`Wave 1: [1, 2] | Wave 2: [3]`. You are the stronger reasoner; do the analysis here so the build
executes it verbatim with zero inference. Independence you can't establish → sequential.

**Frontmatter levers:** `coder_effort: {low|medium|high|xhigh|max|ultra}` (default `medium`; `high`
for risk:high/auth/security/data) · `coder_model: {codex|opus}` pins a whole spec ·
`cross_model_review: true` for auth/security/data-migration — deliberate, never a default.
Full rubric → `references/model-routing.md`.

## Dispatched spec review

Before the readiness gate, dispatch a **fresh-context** adversarial review. You cannot stress-test
your own reasoning; that is the point. **Evaluator-independence, not a rulebook** — there is no
domain skill to review against (ADR-036), and the value never came from one: the Sol plan-check
proving run returned three real BLOCKs (the launcher pinned the model, ExecutionPolicy, a routing
gap) and not one came from a domain rule.

Dispatch `apex-spec-reviewer` (Agent tool). Pass `spec` (draft path or text) and optionally a
`lens` — "security", "migration safety", "does this mechanism actually produce the behaviour".
It reads the spec plus the files the spec names, sandboxed from planning docs, and returns
BLOCK / FLAG / note, each cited to **evidence** (file:line, quoted clause, failing scenario).

- **Always**, with 2–3 **different lenses** in parallel: security, auth, data/migrations, anything
  hard to reverse. Diverse lenses catch what redundancy can't.
- **One reviewer** for an ordinary multi-file spec. **Skip** a trivial single-file spec.

Every BLOCK resolved in the spec; every FLAG resolved or explicitly accepted with reasoning.

## Readiness gate — Deep Details only

The model already checks for vague paths, "maybe"/"TBD", missing done-when clauses, and unrequested
scope (RED-confirmed). **These are the items it does not reliably check.** Every one must pass; if
any fails, fix in place and re-run from the top.

As the deterministic backstop to the prose Files-to-Change / Coverage / structure checkboxes (which retain judgment depth), on draft->changes promotion run `powershell.exe -NoProfile -File "$env:USERPROFILE\.claude\skills\apex-code\scripts\apex-spec-validate.ps1" -SpecPath <draft>`; a `FAIL` (exit 1) **BLOCKS** promotion.

```
[ ] Coverage      — every acceptance criterion maps to ≥1 task, every task to ≥1 criterion.
                    No orphan tasks. No uncovered criteria.
[ ] Sufficiency   — for every BEHAVIOURAL criterion, the mapped task's stated mechanism can
                    actually PRODUCE that behaviour. "Reuse/extend X" covers it only if X already
                    exhibits it (verify against the codebase) or the task adds the wiring step.
                    An outcome-stated task with no producing step is UNCOVERED — fail it.
[ ] Batch-joinable— ## Files to Change disjoint from sibling pending specs; or each shared file
                    (types / barrel re-export / schema / route registry) owned by ONE spec, the
                    others declaring it in ## Prerequisites (ADR-029).
[ ] Wave plan     — present for ≥3 tasks; waves derived only from STATED dependencies.
[ ] Permissions   — every file, command, git op, and env var the build touches is listed.
                    New packages verified: exact name (typosquat), actively maintained.
[ ] Review        — all BLOCK findings resolved; all FLAGs resolved or accepted with reasoning.
[ ] Questions     — Risks/Open Questions section DELETED, not emptied. No [NEEDS CLARIFICATION].
[ ] ADR coverage  — every architectural decision this session has a written ADR file. "Noted
                    inline" fails.
[ ] Overview      — if architecture changed, overview.md updated + de-stubbed; decisions link to ADRs.
[ ] App-flow      — every UI spec names the app-flow screen(s)/journey it implements (ADR-013).
[ ] AGENTS.md     — populated per references/agents-md-population.md at first spec-ready, and
                    whenever a spec changes layout, conventions, or the verify commands (ADR-031/037).
```

**Then the Sol plan-check** (ADR-032): a cold `gpt-5.6-sol` read, read-only, schema'd, effort max —
`references/sol-plan-check.md`. Advisory by default, **blocking for `risk: high`**. Sol never edits
the spec. Skip only trivial specs. For high-risk work you may *offer* (never auto-run) the ≤2-round
cross-model deliberation in that reference.

Only move to `docs/changes/` when the gate and the plan-check are both resolved.

## Confirmation digest

Never tell the user to "go read the file." Surface a digest in chat of **only the high-drift fields**
— the places the written spec could have drifted from the discussion:

- **Files** — every path + operation (create / modify / delete)
- **Acceptance criteria** — each as a one-line observable outcome
- **Decisions baked in** — especially any reversed mid-discussion or folded in late. This is where
  transcription drift hides.

Omit the why, the task breakdown, boilerplate. They are auditing *fidelity*, not re-reading the spec.
Close with: "Anything here not match what we discussed? Otherwise say 'start build.'"

Deep Details → digest + offer the file. Light → digest only. Bug Fix → one-line verbal confirm.

## Closing the session

- **Deep Details / Light:** move the spec `docs/drafts/` → `docs/changes/`, then rewrite the
  `<!-- PLANNING -->` block of `docs/status.md` — Pending Specs (scan `docs/changes/`, not `done/`)
  and Open Questions (carry unresolved, add new, **delete resolved**). Update `_Last updated:_`.
- **status.md is LIVE STATE — rewritten, never appended. ≤100 lines** (ADR-037). A finished row is
  **deleted**, not marked done; git is the record. Never let a session narrative land here.
- **Bug Fix:** no status.md update — ephemeral.
- ADR + status procedures (formats, numbering) → `references/adr-and-status-procedures.md`.
