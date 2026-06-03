---
skill: apex-plan
backend: claude
version: 1.14.0
last_updated: 2026-06-03
sources:
  - APEX Design Specification 2026-05-24
  - GSD (Get Shit Done) — github.com/gsd-build/get-shit-done
  - docs/technical/adr/ADR-010-multi-pass-review.md
  - docs/technical/adr/ADR-011-instinct-loop-no-engine.md
  - docs/technical/adr/ADR-013-app-flow-artifact.md
  - docs/technical/adr/ADR-014-living-capability-overview.md
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
question-free specs that DeepSeek can execute without asking anything.

## Session start — read context first

Before responding to the user's request:
1. Read docs/status.md — pending specs, open questions, project state, parked items
2. Read docs/drafts/ — any in-progress specs
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
4. **Conceptual data model still a stub** (data-bearing projects only) — does
   `docs/technical/architecture/data-model.md` exist and still carry the `<!-- apex:data-model:stub -->`
   marker while a spec touches data/schema? → flag "data model is still a stub." Skip for stateless
   projects (no such file by design — ADR-008).
5. **App-flow still a stub** (UI-bearing projects only) — does
   `docs/technical/architecture/app-flow.md` exist and still carry the `<!-- apex:app-flow:stub -->`
   marker while a UI/screen spec is in play? → flag "app-flow is still a stub." Skip for headless
   projects (no such file by design — ADR-013).

Example: "Doc coverage: overview is still a stub; 1 decision not yet ADR'd."

### Drain the handoff — inbox-zero before the session closes

The handoff is a read-once inbox. Surfacing an item is **not** landing it — an item read
and not filed is lost. **Every handoff item must terminate in exactly one of:**
1. **Pending Spec** — queue/write a spec (blocked actions and "review needed ⚠️" decisions often land here)
2. **Open Question** — add to status.md Open Questions (an unresolved decision, e.g. an architecture call to make later)
3. **Folded** — incorporated into existing state *now* (e.g. a gotcha written into a spec/skill/ADR,
   or a recurring build lesson / user correction written to a `feedback` **memory** so it re-surfaces)
4. **Discarded** — explicitly judged not actionable

Land each item's disposition **this session** — do not defer it to "later." The latest
handoff is read once and never auto-read again, so an undrained item is gone.

**The learning loop (no engine — this rail is it).** A build lesson reaches planning only through the
handoff; the drain is where it's caught. Most fold into a `feedback` memory. When the *same* lesson
recurs across multiple handoffs (the memory's recall is your tally — no separate ledger), it has earned
promotion: treat it as a candidate for `apex-refresh --stocktake` (cross-skill principle) or a direct
`apex-skill-author` edit. Promotion is always human-gated through those rails — the Iron Law's
failing-baseline test stays in force, so an instinct-sourced edit is held to the same bar as any other.
(Why no automatic capture/confidence engine: ADR-011 / `docs/findings/instinct-loop-deep-dive.md`.)

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

DeepSeek executes literally and cannot fill gaps, so **all judgment must be resolved before
the spec freezes** — and planning is the only place that can happen. Pull the decisions you
need *before* drafting; do not draft-then-validate.

- **Resolve yourself — don't ask:** codebase facts (read the files), clear technical defaults
  (defaults-not-menus), anything derivable from patterns or research. Asking these wastes the
  user's attention. **Brownfield:** if planning touches an existing codebase you haven't mapped, run a
  codebase-mapping pass first (reuse `gsd-map-codebase` if installed) — gate it to onboarding; it's a
  HIGH-token whole-repo scan, so do it once and persist to overview/data-model, not every session.
- **Ask the user — before drafting:** product intent, preferences among technically-valid
  options (taste/business), edge-case priorities, "what does good look like." Judgment, not facts.
- **Bound the ask:** surface only decisions that (a) planning cannot resolve itself **and**
  (b) change what gets built. Fails either test → don't ask it.
- **Batch and target** (AskUserQuestion-style) — a focused set of the genuine forks, not a
  drip of one-question-at-a-time, and not an exhaustive questionnaire.

Why front-load: this is the primary mechanism for reliable AFK builds — every decision
resolved here is a mid-build fork that never happens. A planning-time question is cheap
(you're here, nothing in flight); a build-time fork stalls the build, forces a context
switch, and may need a re-spec. Asymmetric cost → heavier planning is the cheaper path.
(The "coding asks at a fork" rule is the safety net; this is the primary mechanism.)

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
`docs/technical/architecture/app-flow.md` **early — before per-screen specs** — so screens stay coherent
against one navigation anchor (ADR-013; technique owned by apex-ui-ux-design) — **Deep Details only**.

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

Split rule: if the spec touches more than 3 files or has more than 2 logical phases, split it into separate specs before proceeding.

As you build the spec, enforce these rules inline:
- Every file must have a full absolute path
- Every task must be a single unambiguous action that **names its exact files** — never
  "update the auth flow" (forces the worker to explore = context cost + judgment, DeepSeek's
  weakest areas)
- Every acceptance criterion must be concrete and testable
- Permissions section must cover every action the build will take
- Specialist context section captures any specialist findings
- Risks/Open Questions must be empty before spec is ready
- **Task granularity:** size each task as one concern layer — API layer, DB layer, UI layer,
  test layer. One task should not span multiple layers; one layer should not be split into
  multiple thin tasks. Independent concern layers run in parallel waves in coding mode;
  artificially thin tasks (one import, one function, one file) cost more in agent-spawn
  overhead than they save in parallelism. Natural independence is the signal — do not
  manufacture it.

**A spec is an execution script, not a design doc — rich on the *what*, stripped of the *why*:**
- **Scope = a one-line identity** (what this builds, for routing/review/recall), optionally
  + a single ADR/discussion link. Not a rationale paragraph.
- **No *why* inline.** Litmus when tempted: does it change what gets built? **No** → cut it
  (home = ADR / planning discussion). **Yes** → don't add the why, make the *what* explicit.
- **Cross-cutting conventions live in the skill's `impl.md`, never copied into the spec** —
  the spec is the task-specific delta; the skill is the shared baseline.

**Karpathy rules while writing:**
- Every `## Assumptions` item must say what happens if it's wrong (`Stop | Caution | Low`)
- Every `## Acceptance Criteria` item must use step→verify format — no vague criteria
- Every `## Tasks` item must have a "done when:" clause — observable, not "it works"
- Every file in `## Files to Change` must be strictly necessary — no speculative additions

Then dispatch domain review (below), resolve its findings, and run the Readiness Gate (below).
Only move to docs/changes/ when the gate passes.

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
  accessibility**. A missed non-salient gap in these is expensive.
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
{things DeepSeek might miss, subtle interactions, ordering constraints}

## Files to touch
- {full path} — {what changes broadly}
```

**What planning provides:** intent clarity, trade-off reasoning, and edge-case awareness that Claude is uniquely good at but would be lost once the session ends.

**What coding mode backfills:** task breakdown, implementation order, acceptance criteria, test strategy.

No readiness gate. No ADRs. No specialist context. **Light mode quality check (no gate, but run this before confirming):**
- Assumptions block written? Every non-obvious assumption stated.
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
  [ ] Task granularity: each task is one concern layer — not one file and not multiple features; no artificially thin tasks manufactured to increase worker count
  [ ] Coverage audit: every acceptance criterion maps to ≥1 task, and every task traces to ≥1 criterion — no orphan tasks, no uncovered criteria (Spec-Kit /analyze)

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
```

If any item fails: surface what is unresolved, revise in-place, re-run gate from top. Repeat until clean.

## Confirmation digest — how the user signs off

At spec-confirm time, do **not** tell the user to "go read the file." They lived the
discussion; sending them to re-read a stripped-down restatement is the redundant step.
Instead surface a **digest** in chat — only the fields where the written spec could have
drifted from what you discussed — and let them verify *that*. Depth is mode-gated.

**Digest = the load-bearing, high-drift fields only:**
- **Files** — every path + operation (create / modify / delete)
- **Acceptance criteria** — each as a one-line observable outcome
- **Decisions baked in** — choices the spec now encodes, especially any reversed mid-discussion
  or folded in late (this is where transcription drift hides)

Omit the *why*, the full task breakdown, and boilerplate — the user is auditing fidelity,
not re-reading the spec. Close with:
> "Anything here not match what we discussed? Otherwise say 'start build.'"

**Mode dial — how much to show:**
| Mode | Confirmation |
|------|-------------|
| Deep Details | Digest **+** offer to open the full spec file |
| Light | Digest only |
| Bug Fix | One-line verbal confirm — no digest (single ephemeral fix) |

Why a digest, not the file: it catches the drift that bites an AFK build (wrong path, loose
criterion, a reversed decision) at a fraction of the reading, and keeps the user in chat —
no context switch from deciding to auditing.

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
2. If yes: no status.md update. Coding mode will fix it immediately.
3. If no: revise.

## ADR workflow — Deep Details only

When an architectural decision is reached during planning:

1. Assign the next ADR number (read docs/technical/adr/ to find highest existing number)
2. Write immediately to docs/technical/adr/ADR-{NNN}-{short-title}.md:

```markdown
# ADR-{NNN}: {title}
**Date:** {YYYY-MM-DD}
**Status:** Accepted

## Context
{Why this decision was needed — the forces at play}

## Decision
{What was decided, stated clearly}

## Consequences
{What this means going forward — good and bad}
```

3. Reference the ADR in the spec's Documentation section

**Light / Bug Fix modes:** note decisions inline in the spec doc. Skip formal ADRs.

## Updating docs/status.md — by mode

### Deep Details / Light
At the end of every planning session:
1. Read current docs/status.md
2. Rewrite content between <!-- PLANNING:START --> and <!-- PLANNING:END -->:
   - Pending table: scan docs/changes/*.md (not done/). One row per spec, alphabetical
   - Open questions: carry over unresolved, add new, remove resolved
3. Update _Last updated by planning mode:_ line to today's date
4. Write file back

### Bug Fix
No status.md update. Bug fix docs are ephemeral — consumed and archived in one coding session.

## Specialist knowledge — two roles (Deep Details only)

Domain knowledge reaches a spec two ways — keep them distinct (ADR-007):

- **Inline (drafting advice).** The orchestrator loads a matched domain's SKILL.md into this window
  (keyword detection + specialists_default) so you draft with its concerns in mind. Its guidance
  shapes the spec's Specialist Context section.
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
