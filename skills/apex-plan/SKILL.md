---
skill: apex-plan
backend: claude
version: 1.34.0
last_updated: 2026-07-13
sources:
  - APEX Design Specification 2026-05-24
  - GSD (Get Shit Done) — github.com/gsd-build/get-shit-done
  - docs/technical/adr/ADR-010-multi-pass-review.md
  - docs/technical/adr/ADR-031-codex-context-propagation.md
  - docs/technical/adr/ADR-032-gpt56-role-split.md
  - docs/technical/adr/ADR-011-instinct-loop-no-engine.md
  - docs/technical/adr/ADR-013-app-flow-artifact.md
  - docs/technical/adr/ADR-014-living-capability-overview.md
  - docs/technical/adr/ADR-017-design-brief-artifact.md
  - donor-analysis (Spec-Kit clarify/analyze, Superpowers self-review, BMAD scale-adaptive) — docs/research/donor-analysis/
staleness_threshold: 30d
description: >
  Use when planning — turning requirements into executable docs/changes specs, designing an
  approach, or shaping a build. Triggers (routed by apex-orchestrate): plan / design / architect /
  spec / "let's build" / "what if". Owns the planning-mode toggle, upfront intent elicitation, the
  research/council widen-options gate, dispatched domain review, the readiness gate, ADRs, and the
  confirmation digest. Not the build itself (apex-code) or standalone research (apex-deep-dive).
---

# APEX Planning Workflow

You are in planning mode (Claude). Your job: turn requirements into complete,
question-free specs the coder can execute without asking anything.

## Session start — read context first

Before responding to the user's request:
1. Read docs/status.md — pending specs, open questions, project state, parked items
2. Read docs/drafts/ — any in-progress specs
2b. Check docs/progress/*.md — capture-at-halt records for blocked/parked specs. For each:
    decide **patch-in-place** (resolve the captured decision, edit the spec in docs/changes/,
    clear the blocked mark) or **re-draft** (pull the spec back to docs/drafts/ and rework).
    This is planning's judgment — a blocked spec left undrained stalls forever. Delete the
    progress record once drained.
3. Read the latest docs/handoff/*.md — the *thin* handoff: decisions, specialist flags,
   blocked actions, discoveries. (What changed lives in git, not the handoff — run
   `git log` / `git diff` only if you need the file-level history. Build/test status and
   in-progress position are in status.md.)
4. Run the **doc-coverage check** (below) — fold its one-line result into the acknowledgement.
5. Acknowledge: "I see {n} pending spec(s): {list}. Open flags from last build: {or none}. Doc coverage: {result}. What are we working on today?"

### Doc-coverage check — informational, never blocks

Mirrors `apex-refresh --audit`: surface the per-project documentation gaps so they don't
silently rot. **It never halts anything** — enforcement lives in the readiness gate, not here.
Compute three signals and report them in one line (say "clean" if none fire):

1. **Overview missing / still a stub** — does `docs/technical/architecture/overview.md` exist?
   Does it still contain the `<!-- apex:overview:stub -->` marker? Stub = seeded but never
   written → flag "overview is still a stub."
2. **Decisions not yet ADR'd** — any architectural decision in the latest handoff's
   "Decisions Made" or in status.md that has no matching `docs/technical/adr/ADR-NNN-*.md` →
   flag "{n} decision(s) not yet ADR'd."
3. **Overview staleness** — overview.md older than the newest ADR, **or not updated since the last
   spec archived to docs/changes/done/** (a change shipped but the capability list wasn't merged —
   ADR-014) → flag "overview may be stale vs ADR-NNN / vs last archive."
4. **Architecture artifact still a stub** (scope-gated) — `data-model.md` (data-bearing, ADR-008) ·
   `app-flow.md` (UI-bearing, ADR-013) · `design-brief.md` (UI-bearing, ADR-017), all under
   `docs/technical/architecture/`: the file exists, still carries its `<!-- apex:…:stub -->` marker,
   and a spec in its scope is in play (data/schema spec · UI/screen spec) → flag "{artifact} is
   still a stub." Headless/stateless projects skip by design (no such file).
5. **AGENTS.md still stubbed** — the repo-root `AGENTS.md` carries an `<!-- apex:agents:stub -->` /
   `<!-- apex:agents:verify -->` marker while ≥1 spec sits in docs/changes/ → flag it (Codex builds read AGENTS.md, not the skills — ADR-031).

Example: "Doc coverage: overview is still a stub; 1 decision not yet ADR'd."

### Drain the handoff — inbox-zero before the session closes

The handoff is a read-once inbox. Surfacing an item is **not** landing it — an item read
and not filed is lost. **Every handoff item must terminate in exactly one of:**
1. **Pending Spec** — queue/write a spec (blocked actions and "review needed ⚠️" decisions often land here)
2. **Open Question** — add to status.md Open Questions (an unresolved decision, e.g. an architecture call to make later)
3. **Folded** — incorporated into existing state *now* (e.g. a gotcha written into a spec/skill/ADR,
   or a recurring build lesson / user correction written to a `feedback` **memory** so it re-surfaces)
4. **Discarded** — explicitly judged not actionable

Land each item's disposition **this session** — the handoff is never auto-read again; an undrained item is gone.

**The learning loop.** Build lessons fold into `feedback` memories at the drain. Don't wait for
recurrence when the user flags a deliverable they loved: post-mortem it *while it's still in context*
(what was reasoned about, what proved it worked) and fold the answer into a `feedback` memory. A
recurring lesson earns promotion — `apex-refresh --stocktake` or an `apex-skill-author` edit (human-gated, Iron Law — ADR-011).

## Planning mode toggle

Before any planning work, ask the user which mode to use:

> "Pick a planning mode:
> - **Deep Details** (heavy) — full spec template, readiness gate, ADRs, specialist loading
> - **Light** (medium) — intent doc only, key decisions, acceptance criteria, no gate
> - **Bug Fix** (lightest) — bug description, root cause, fix approach, files to touch"

Wait for their choice. This determines everything below. **Recommend the lightest mode that fits the
change size** — collapse ceremony for trivial L0/L1 work; don't default to Deep Details for a one-file
change (scale-adaptive routing). Reserve Deep Details for multi-file / architectural work.

## Planning conversation

### Elicit intent before drafting — front-load the build-changing decisions

The coder (Codex `gpt-5.6-sol`; Opus on fallback) executes the spec silently against frozen
acceptance criteria — questions belong in planning, which alone holds the conversation +
research context. So **all build-changing judgment must be resolved before the spec freezes**;
planning is the only place that can happen. Pull the decisions you need *before* drafting; do
not draft-then-validate. (Bounded micro-ambiguity — which existing pattern to follow, a local
name — can be left to the coder's conservative-choice protocol in apex-code; it is
*build-changing* judgment that must not reach the build.)

- **Resolve yourself — don't ask:** codebase facts (read the files), clear technical defaults
  (defaults-not-menus), anything derivable from patterns or research. Asking these wastes the
  user's attention. **Brownfield:** if planning touches an existing codebase you haven't mapped, map
  it first — dispatch `Explore` agents in parallel over the subsystems in play. Gate it to onboarding:
  it's a HIGH-token scan, so do it once and persist the result to overview/data-model, never per session.
- **Ask the user — before drafting:** product intent, preferences among technically-valid
  options (taste/business), edge-case priorities, "what does good look like." Judgment, not facts.
- **Bound the ask:** surface only decisions that (a) planning cannot resolve itself **and**
  (b) change what gets built. Fails either test → don't ask it.
- **Batch and target** (AskUserQuestion-style) — a focused set of the genuine forks, not a
  drip of one-question-at-a-time, and not an exhaustive questionnaire.

(Every decision resolved here is a mid-build fork that never happens — heavier planning is
the cheaper path; coding's fork-routing is only the safety net.)

### Think Before Speccing

Before writing any spec section, state your interpretation of the request explicitly.
If multiple interpretations are valid, present them — do not silently pick one.

> "I'm reading this as X. An alternative interpretation is Y. I'm going with X because Z.
> Does that match your intent?"

If something is genuinely unclear, stop. Name what's confusing. Do not fill in the gap
with an assumption that isn't written down somewhere — write it in `## Assumptions` instead, or drop a
greppable `[NEEDS CLARIFICATION: …]` marker at the exact spot; the readiness gate blocks while any
marker remains (Spec-Kit clarify discipline).
Present trade-offs and alternatives before deciding.
Write ADRs immediately for every architectural decision made (see ADR workflow below) — **Deep Details only**.
Load specialist skills when domain keywords appear (orchestrator handles this) — **Deep Details only**.
For **data-bearing projects**, capture the conceptual data model (entities + relationships) in
`docs/technical/architecture/data-model.md` **early — before per-phase schema specs** — so per-phase
schema stays coherent against one anchor (ADR-008) — **Deep Details only**.
For **UI-bearing projects**, likewise capture the app-flow (screens + journeys) in
`docs/technical/architecture/app-flow.md` **early — before per-screen specs**, and fill the
**design-brief** (tokens + art-direction + forbidden-patterns) in
`docs/technical/architecture/design-brief.md` once a visual direction is chosen — a UI spec should
reference its tokens. Both artifacts, the ask-first aesthetic gate, and the design loop →
`references/design-workflow.md` (ADR-013/017) — **Deep Details only**.

### Widen the options — research gate

At a **meaningful** solution-branch point — when ≥2 candidate approaches are in play *and* the
choice has real trade-offs, touches architecture, or rests on knowledge that may be stale — do
**not** jump straight to a recommendation from in-context knowledge. First surface the candidates
(one line each), then ask:

> "I have {N} candidate approaches: {one-liner each}. Want me to search online for more before we choose?"

- **Yes** → research, **picking depth by magnitude and stating which you're running first**:
  - *Most forks* → `apex-research` (light gather: additional/better options, tiered sources, confidence tags).
  - *Heavy / architectural fork* → `apex-deep-dive` (full 2-3 option comparison + project-specific recommendation).
  Then fold what comes back into the option set, re-present, and recommend/decide.
- **No** → proceed with the in-context options.

**Judgment fork (not facts) → offer council instead (ADR-010).** When the candidate approaches are
already well understood and the uncertainty is a *judgment* call — a load-bearing go/no-go with no
factual tiebreaker, where more searching won't help — offer the anti-anchoring council in place of
web research:

> "This is a judgment call, not a facts gap. Want me to run a council — three fresh-context voices
> (Skeptic / Pragmatist / Critic) that haven't seen my lean — before we decide?"

- **Yes** → run **Council mode** in `apex-deep-dive`, fold the independent dissent into the
  recommendation, then decide.
- **No** → proceed with your call.

Never *auto-run* council — offer only, and only at a genuine judgment fork (same tight-scope rule
below). Facts-uncertainty stays with `apex-research` / `apex-deep-dive` above.

**Scope it tightly — this is a deliberate mid-stream interrupt.** Fire it only on meaningful forks.
A clear default with no real trade-off follows *defaults-not-menus* (above) and never triggers the
gate — trivial picks must not nag. This is the one sanctioned exception to batch-the-questions:
widening the option set is worth the interrupt precisely when the decision is load-bearing.

## Writing the spec — by mode

### Deep Details mode

Use the template at ~/.claude/skills/apex-orchestrate/templates/spec-template.md.

Write to docs/drafts/{short-name}.md first — not docs/changes/.

Split rule: if the spec touches more than 3 files or has more than 2 logical phases, split it into separate specs before proceeding. When you split (or write a spec alongside other pending specs), make the resulting specs **file-disjoint** — any real dependency a `## Prerequisites` edge — so a session drains the set as parallel waves (ADR-029, *Batch-joinable* in the readiness gate).

As you build the spec, enforce these rules inline:
- Every file must have a full absolute path
- Every task must be a single unambiguous action that **names its exact files** — never
  "update the auth flow" (forces the worker to explore = context cost + scope creep; the file
  list is also the parallel-wave grouping and the scope lock)
- Every acceptance criterion must be concrete and testable
- **Tasks state the mechanism, not just the outcome.** When a task reuses or extends an existing
  component to achieve a *new* behaviour, name the concrete producing step (the wiring that emits/
  routes the behaviour) — never assume the executor infers it from the desired outcome.
- Permissions section must cover every action the build will take
- Specialist context section captures any specialist findings
- Risks/Open Questions must be empty before spec is ready
- **Task granularity:** one concern layer per task (API / DB / UI / test) — don't span layers or
  split one layer into thin tasks. Independent layers run as parallel waves; tasks made thin to
  raise worker count cost more in spawn overhead than they save — never manufacture independence.

**A spec is an execution script, not a design doc — rich on the *what*, stripped of the *why*:**
- **Scope = a one-line identity** (what this builds, for routing/review/recall), optionally
  + a single ADR/discussion link. Not a rationale paragraph.
- **No *why* inline.** Litmus when tempted: does it change what gets built? **No** → cut it
  (home = ADR / planning discussion). **Yes** → don't add the why, make the *what* explicit.
  One sanctioned exception: the template's `## Intent` block (intent / invariants / non-goals, ≤10
  lines) — load-bearing intent that travels to the coder in the dispatch pack (ADR-031); ADR-essay rationale still cut.
- **Cross-cutting conventions live in the skill's `impl.md`, never copied into the spec** —
  the spec is the task-specific delta; the skill is the shared baseline.

**Karpathy rules while writing:** apply the readiness gate's *Karpathy Quality Gate* items
(below) as you draft — don't write loose and rely on the gate to catch it.

**Wave plan — emit it for the executor (specs with ≥3 tasks):** after the task list, add a
`## Wave plan` section grouping tasks into waves from the stated dependencies
(`Wave 1: [task 1, task 2] | Wave 2: [task 3]`). You are the stronger reasoner — do the
dependency analysis here so coding mode executes the grouping verbatim with zero inference.
Tasks whose independence you can't establish go in sequential waves.

**Cross-model review — set the flag for high-stakes builds.** For an auth / security / data-migration
spec, set `cross_model_review: true` in the frontmatter — coding mode runs an independent second review
by the *other* model family before shipping (apex-governance § Cross-model review). Deliberate, never a default.

Then dispatch domain review (below), resolve its findings, and run the Readiness Gate (below).
After the gate passes, run the **Sol plan-check gate** (ADR-032): dispatch a cold `gpt-5.6-sol`
read of the spec (read-only, schema'd, effort max) per `references/sol-plan-check.md` — advisory
by default, **blocking for `risk: high`**; Sol never edits the spec; skip only trivial
single-domain specs. For high-risk specs you may *offer* (never auto-run) the ≤2-round
cross-model deliberation in the same reference. Only move to docs/changes/ when gate + plan-check are resolved.

### Dispatched domain review — Deep Details only

Before the readiness gate, dispatch a **fresh-context** domain review of the draft. Domain knowledge
loaded *inline* into this planning window both bloats it and lets self-review skip the non-salient
checklist items; a dispatched reviewer returns gate-ready, severity-tagged findings and keeps this
window lean (ADR-007).

**What to dispatch:** the generic `apex-spec-reviewer` agent (Agent tool,
`subagent_type: apex-spec-reviewer`), **one per reviewed domain, in parallel**. Pass each:
- `skill_path`: `~/.claude/skills/apex-<domain>/SKILL.md` for that domain
- `spec`: the draft path `docs/drafts/{name}.md` (or its text)

It reads only that one skill + the spec (sandboxed from planning docs) and returns findings
classified BLOCK / FLAG / note, each cited to a skill rule.

**Which domains — the trigger:**
- **Auto-fire** for any of the heavy set the spec touches: **security, auth, data, testing,
  accessibility**. A missed non-salient gap in these is expensive. Also auto-fire
  **ui-ux-design** when the spec ships or restyles user-facing UI (new or changed components,
  layout, design tokens, visual styling) — not trivial copy/attribute edits; visual and UX
  judgment is otherwise silently skipped (accessibility ≠ visual/layout review).
- **Judgment-fire** any other domain the spec touches when you think it's warranted.
- **Skip** a trivial single-domain spec — inline drafting already handles the salient single-domain
  case; don't pay the spawn.

**Resolve before the gate:** every BLOCK finding must be resolved in the spec; every FLAG resolved or
explicitly accepted with reasoning. These populate the gate's *Specialist flags* section. Only then
run the readiness gate. If a review flags that another domain is relevant, dispatch a reviewer for it
too before proceeding.

### Light mode

Write an intent doc directly to docs/changes/{short-name}.md (skip drafts/). Structure:

```markdown
## Intent
{2-3 sentences: what to build and why}

## Key decisions
- {why this way — non-obvious trade-offs Claude resolved}

## Gotchas / edge cases
{things the coder might miss, subtle interactions, ordering constraints}

## Tasks
1. {one action, exact files named} — done when: {observable check}

## Files to touch
- {full path} — {what changes broadly}
```

**Planning provides everything that needs judgment** — intent, trade-offs, edge cases, AND a
minimal ordered task list with a "done when:" per task. Light mode trims *ceremony* (gate,
ADRs, specialist review), never *decomposition* — coding mode executes tasks as written and
does not backfill task breakdown, acceptance criteria, or test strategy (planning's job —
apex-code's task granularity is fixed at spec time).

No readiness gate. No ADRs. No specialist context. **Light mode quality check (no gate, but run this before confirming):**
- Assumptions block written? Every non-obvious assumption stated.
- Every task names its exact files and has a "done when:" clause.
- Is there a simpler intent that achieves the same goal? If so, write that.
- Every file listed in "Files to touch" is strictly necessary?
- Acceptance criteria (if any) use observable outcomes, not vague descriptions.

If any answer is "no": revise before confirming with user.

Verify decisions are clear, then confirm with the user before moving on.

### Bug Fix mode

Call `apex-debug` — the debug specialist handles the investigation. It reads the bug description, investigates root cause, and produces the fix doc.

Template the specialist produces (it goes directly to docs/changes/{short-name}.md):

```markdown
## Bug
{one paragraph — what actually happens vs what should happen}

## Root cause
{cause identified during investigation}

## Fix approach
{1-3 sentences}

## Files to touch
- {full path} — {why}
```

**Flow:**
1. User describes the bug
2. Route to `apex-debug` via Skill tool
3. Debug specialist investigates, produces the fix doc
4. Confirm with user: "Bug fix doc at docs/changes/{name}.md — ready for build?"

No readiness gate. No ADRs. No status.md update. No planning conversation — investigation is the planning.

## Readiness gate — Deep Details only

Run this before moving spec to docs/changes/. Every item must pass.

```
Files
  [ ] Every file to change has a full path
  [ ] Every new file has a specified location
  [ ] No file listed as "TBD" or vague location

Tasks
  [ ] Every task has one unambiguous action
  [ ] Every task has a concrete acceptance criterion
  [ ] No task contains "or", "maybe", "depending on", "TBD"
  [ ] Task dependencies are explicit (if Task 3 needs Task 1, say so)
  [ ] Wave plan present for specs with ≥3 tasks — waves derived only from stated dependencies
  [ ] Batch-joinable: ## Files to Change disjoint from sibling pending specs', or each shared file (types / barrel re-export / schema / route registry) owned by one spec with others declaring it in ## Prerequisites (ADR-029)
  [ ] Task granularity: each task is one concern layer — not one file and not multiple features; no artificially thin tasks manufactured to increase worker count
  [ ] Coverage audit (presence): every acceptance criterion maps to ≥1 task, and every task traces to ≥1 criterion — no orphan tasks, no uncovered criteria (Spec-Kit /analyze)
  [ ] Sufficiency audit (mechanism): for every *behavioural* criterion, the mapped task's stated mechanism can actually produce that behaviour. A "reuse/extend existing X" task covers a behavioural criterion only if X already exhibits it (verify against the codebase) OR the task adds an explicit producing/wiring step. An outcome-stated task that omits the producing step — e.g. "re-skin to get the rich treatment" while reusing a primitive that structurally can't emit it — is UNCOVERED: fail until the wiring task exists.

Permissions
  [ ] All files to write are listed with full paths
  [ ] All commands listed with exact syntax
  [ ] All git operations listed and within active autonomy level
  [ ] All environment variables accessed are listed
  [ ] No unlisted network calls (npm install is listed if needed)
  [ ] Any new packages (npm/pip/gem/cargo) verified: correct name, active maintainer, not a known typosquat

Specialist flags
  [ ] All BLOCK-level flags resolved
  [ ] All FLAG-level flags resolved or explicitly accepted with reasoning

Questions
  [ ] Risks/Open Questions section removed from spec (not emptied — deleted)
  [ ] No ambiguity in any acceptance criterion
  [ ] No unresolved `[NEEDS CLARIFICATION: …]` markers remain anywhere in the spec

Self-review (Superpowers)
  [ ] No leftover placeholders — no TODO / TBD / "…" / bare brackets left in the spec
  [ ] Internal consistency — no section contradicts another (file paths, names, criteria all agree)

Karpathy Quality Gate
  [ ] Assumptions: every non-obvious assumption is written in ## Assumptions with impact level
  [ ] Complexity challenge: "Is there a simpler spec that achieves the same goal?"
      — answered explicitly in the Simplicity check line of ## Assumptions
  [ ] Acceptance criteria: every item uses step→verify format — no item says "it works" or "it passes"
  [ ] Tasks: every item has a "done when:" clause
  [ ] Surgical scope: every file in ## Files to Change maps to at least one task
      — no file is listed "just in case" or "while we're in there"
  [ ] No task contains work beyond what was explicitly requested

Documentation
  [ ] Inline doc requirements specified (if any code is exported)
  [ ] Product doc updates specified (if any user-facing change)
  [ ] ADR coverage: every architectural decision reached this session has a written
      docs/technical/adr/ADR-NNN-*.md — not merely "noted inline." Fails until the ADR file exists.
  [ ] Overview currency: if the architecture changed, docs/technical/architecture/overview.md
      is updated — and de-stubbed (the `<!-- apex:overview:stub -->` marker removed) if it was
      still a stub. Shaping decisions link to their ADRs.
  [ ] App-flow currency: every UI/screen spec names which app-flow screen(s)/journey it implements,
      and app-flow.md is de-stubbed if it was still a stub (UI-bearing projects — ADR-013)
  [ ] AGENTS.md currency: at first spec-ready — and whenever this spec changes repo layout,
      conventions, or the stack binding — the root AGENTS.md stub sections are populated per
      references/agents-md-population.md (ADR-031)
```

If any item fails: surface what is unresolved, revise in-place, re-run gate from top. Repeat until clean.

## Model-routing build planning — coders {codex (default), opus (fallback)}

`coder_models` from status.md (default `[codex]`; ADR-027): **Codex builds every task; Opus is the
manual fallback at quota-out** (a build-time event handled by apex-code, not a planning route). Emit the
normal **untagged `## Wave plan`**; `coder_model: opus` pins a whole spec; the one real per-spec lever is **reasoning effort** — `coder_effort: {low|medium|high|xhigh|max|ultra}` (default `medium`; `high` for risk:high/auth/security/data/hard, `low` for trivial, `max`/`ultra` rare rungs — references/model-routing.md; ADR-030).
Full rubric (effort dial, family-aware review, fallback mechanic, archived DeepSeek mapping) → `references/model-routing.md`.

## Confirmation digest — how the user signs off

At spec-confirm time, do **not** tell the user to "go read the file." Surface a **digest** in chat —
only the fields where the written spec could have drifted from the discussion — and let them verify *that*. Depth is mode-gated.

**Digest = the load-bearing, high-drift fields only:**
- **Files** — every path + operation (create / modify / delete)
- **Acceptance criteria** — each as a one-line observable outcome
- **Decisions baked in** — choices the spec now encodes, especially any reversed mid-discussion
  or folded in late (this is where transcription drift hides)

Omit the *why*, the full task breakdown, and boilerplate — the user is auditing fidelity
(the drift that bites an AFK build: wrong path, loose criterion, a reversed decision), not
re-reading the spec. Close with:
> "Anything here not match what we discussed? Otherwise say 'start build.'"

**Mode dial — how much to show:**
| Mode | Confirmation |
|------|-------------|
| Deep Details | Digest **+** offer to open the full spec file |
| Light | Digest only |
| Bug Fix | One-line verbal confirm — no digest (single ephemeral fix) |

## Moving spec to ready — by mode

### Deep Details
1. Move: docs/drafts/{name}.md → docs/changes/{name}.md
2. Update spec status: `status: draft` → `status: ready`
3. Update docs/status.md PLANNING block:
   - Add spec to Pending Specs table with one-line summary
   - Update _Last updated by planning mode:_ to today
4. Present the **Confirmation digest** (Deep Details depth — digest + offer the full file),
   then: "✅ Spec ready at docs/changes/{name}.md. Say 'start build' when ready."

### Light
1. Present the **Confirmation digest** (Light depth — digest only) for docs/changes/{name}.md.
2. If it matches: update docs/status.md PLANNING block (add to Pending table). No gate.
3. If not: revise.

### Bug Fix
1. One-line verbal confirm — no digest: "Bug fix doc at docs/changes/{name}.md — ready for build?"
2. If yes: no status.md update at planning time (ephemeral). If the build is later interrupted,
   apex-code's pause workflow still writes the In-Flight row — bug-fix builds are not invisible to resume.
3. If no: revise.

## ADR workflow — Deep Details only

When an architectural decision is reached during planning, write an ADR **immediately** (don't defer):
assign the next ADR number, write `docs/technical/adr/ADR-{NNN}-{short-title}.md`, and reference it in
the spec's Documentation section. **Light / Bug Fix:** note decisions inline; skip formal ADRs.

> Full procedure + ADR template: read `references/adr-and-status-procedures.md` § ADR workflow when
> writing an ADR.

## Updating docs/status.md — by mode

At the end of every Deep Details / Light planning session, rewrite the PLANNING block of
docs/status.md (Pending Specs from docs/changes/*.md + Open Questions) and bump the
_Last updated by planning mode:_ date. **Bug Fix:** no status.md update (ephemeral).

> Full rewrite mechanics (markers, table rules): read `references/adr-and-status-procedures.md`
> § status.md update when closing the session.

## Specialist knowledge — two roles (Deep Details only)

Domain knowledge reaches a spec two ways — keep them distinct (ADR-007):

- **Inline (drafting advice).** You apply domain expertise directly — there is no domain skill to
  load (ADR-036). It shapes the spec's Specialist Context section.
- **Dispatched (review).** The gate-bearing check is the dispatched `apex-spec-reviewer` pass
  (§ Dispatched domain review) — fresh context, severity-tagged, gate-ready. This is what produces
  the BLOCK/FLAG flags the readiness gate resolves. **Do not rely on inline self-review for that** —
  inline review skips non-salient checklist items and bloats this window.

Rules:
- BLOCK flags halt spec creation — must be resolved before continuing.
- FLAG flags are noted in Specialist Context — user decides whether to accept.
- You never run other specialists' impl-side enforcement directly; if a review flags another domain
  is relevant, dispatch a reviewer for it (§ Dispatched domain review).

**Light / Bug Fix modes:** skip specialist review entirely.
