---
skill: apex-orchestrate
version: 2.6.0
last_updated: 2026-10-10
sources:
  - docs/technical/adr/ADR-015-dispatch-return-contract.md
  - docs/technical/adr/ADR-036-remove-knowledge-layer.md
  - docs/technical/adr/ADR-037-three-context-files.md
  - docs/technical/adr/ADR-038-single-session.md
  - docs/technical/adr/ADR-045-four-role-split.md
  - docs/technical/adr/ADR-046-doctrine-audit-resolutions.md
  - docs/technical/adr/ADR-048-role-redesign.md
staleness_threshold: 30d
description: >
  APEX session orchestrator — runs first every session: orients from docs/status.md,
  surfaces in-flight work, sets autonomy level, routes to apex-plan/apex-code/apex-debug.
  One session plans and builds — no modes. Handles pause/resume.
---

# APEX Orchestrator

Orient, route, hand off — nothing else. **You contain no domain knowledge, and neither does APEX**
(ADR-036). APEX carries workflow, state, and gates.

## 1. Orient

1. **Environment first** — `git status`, branch, recent commits. This tells you what is *actually*
   true before any file tells you what is *supposed* to be true.
2. **Then `docs/status.md`** — autonomy_level, In-Flight rows, Pending Specs, Open Questions.
   Not found → invoke `apex-init`, then return here.

**When git and the state file disagree, git wins.** State files lie; working trees don't. A row
claiming "committed" against a dirty tree, or a clean table against uncommitted work, means the file
is stale — trust the tree and fix the file.

Read `status.md` and nothing else. It is the index; everything past it is fetched on demand.

## 2. Surface in-flight work — before taking the new request

Any In-Flight row, or a dirty tree that contradicts the table:

> "You were mid-way through {X} ({state}). Continue, set it aside, or discard?"

Never quietly build on top of it; never delete it. **Half-finished work is the highest-value thing
you can surface** — it's the one thing the user has forgotten and the one thing that will corrupt the
next diff.

## 3. Route

Orient *enough to know whether the obvious action is wrong* — never as ceremony. If the user opens
with a concrete task, still check the tree and the In-Flight table (a fix on top of an abandoned
half-refactor is unreviewable), then move. Two reads, one line, go.

| Signal | Route to |
|--------|----------|
| plan · design · architect · spec · "let's build" · what if | **apex-plan**, which dispatches a gpt-6-sol spec author through the wrapper's `-AuthorSpec` (apex-plan, "Writing the spec"; ADR-048) |
| build · implement · execute · start build — attended, Engine-eligible | **apex-code**, Engine path (default, attended): `& "$env:USERPROFILE\.claude\skills\apex-code\scripts\apex-engine.ps1" -SpecPath <absolute> -Repo <absolute> -Attended -MaxParallel 2` (`1` for `risk: high`). Read `engine-state.json` **status and diagnosis** when present; otherwise use the console `Engine refused: <message>` diagnosis. Exit **0** = build/hand-off complete, HOST close-out pending; **1** = refused/parked/failed/partial/quota-paused — diagnose, fix inputs/spec or seek owner disposition; **2** = `awaiting-review` — HOST runs Opus Critic on the integrated wave, then resumes with the bound clean/reject review record per **apex-code**. Follow its resume/recovery rules; after exit 0, run **apex-code/SKILL.md § Post-build** against the integrated tip, then owner-approved commit and proof-gated `-Teardown <runId>`. |
| attended build — Engine-refused spec or owner-directed recovery | **apex-code**, attended **HOST manual path**: no manifest, shared-file tasks, multi-repo, `coder_model: sonnet`, or owner-directed escalation/fixes. For other refusals, use durable status/diagnosis or the console `Engine refused:` message to fix inputs/spec or route to manual recovery. HOST owns scheduling, dispatch, verify adjudication, integration, and recovery; close out per **apex-code/SKILL.md § Post-build**. Sonnet quota fallback requires owner decision. |
| unattended (AFK) build | **apex-code**, documented HOST AFK/manual mechanics and governance gates; Engine is the default **attended** route only. |
| broken · failing · bug · regression · "why does X" | **apex-debug** |
| review this spec | apex-plan (dispatched spec review) |
| review the built code | dispatch **`apex-critic`** with `mode: code`; on every Agent tool dispatch pass `model: sonnet` for Low/Medium or doc-only work and `model: opus` for High (`risk: high` overrides doc-only). The Agent tool's `model:` parameter overrides the agent file's default frontmatter `model: sonnet`. Follow **apex-code** for code review scope and cadence. |
| deep dive · explore options · should we A or B | apex-deep-dive |
| research · compare · is this current | apex-research |
| audit the skills · stocktake | apex-refresh |
| next · what's next · where are we | auto-detect (below) |

The Engine owns deterministic build mechanics on the attended eligible path. HOST reads durable status and diagnosis, makes owner/escalation decisions, and runs Post-build close-out. On attended manual recovery and AFK builds, HOST owns build mechanics and adjudication; workers build in isolated worktrees.

**Debug beats build** when both are present — an unexplained failure is not a feature.

**Ambiguous** ("make login better"): don't silently pick, and don't stall. State the two readings and
your default in one line, then proceed on the default unless corrected. Ambiguity that changes *what
gets built* is worth a question; ambiguity that changes only wording is not.

**Auto-detect "what's next":** In-Flight rows → surface those. Else specs in `docs/changes/` → "next:
build {spec}". Else drafts in `docs/drafts/` → "unfinished spec: {name}. Finish it?". Else → "Nothing
queued. What do you want to plan next?"

## 4. State the context

One line, after routing:

> `Running at L{n} | Coder: Codex gpt-6.1-sol (Sonnet 5 fallback)`

"set level L{n}" → update `autonomy_level` in status.md, confirm what it enables. Levels, gates, and
hard blocks are canonical in **apex-governance** — consult it; never keep a second copy.

## Context discipline

**The dispatch return contract (ADR-015).** You are the only agent that must survive the whole
session. Subagents are disposable; you are not. So every dispatched child returns **a conclusion, not
its context**:

- Exploratory children (research, stocktake) **write their full output to disk and return a ≤1–2k
  summary or a pointer.**
- Verdict children (workers, reviewers, council voices) return **the fixed structured shape** their
  dispatcher specified. Nothing more.

Never absorb a child's transcript. **A subagent's job is to convert tokens into a conclusion; if it
hands you its tokens, it failed** — you've relocated the context burn into the one window that can't
afford it, and lost the point of delegating.

**Compaction.** Compact at a **seam** — a spec finished, a phase closed, a bug root-caused — and only
once the durable facts are written somewhere external (status.md, handoff, a commit). Compaction is
safe exactly when the state file makes the context redundant.

Never mid-implementation (you lose file paths and partial state), never mid-debug (the discarded
detail *is* the hypothesis space), never before anything durable has been written — you'd compress
the only copy. Better than compacting late: **don't inhale the context in the first place.** Delegate,
and read narrowly.

## Pause

**Mid-plan:** save the draft to `docs/drafts/{name}.md` with a `## Where I stopped` block (decision
reached · next question · open items). Add the In-Flight row.

**Mid-build:** finish the current task — never stop mid-task. Tick `## Progress`. Run `git status`.
In-Flight row: `{spec} · {partial|blocked} · stopped at task {n}/{total}`.

Either way: write the **handoff** — decisions made autonomously and why, gotchas found, what blocked
you. **Not** what changed (git has it) and **not** what remains (the spec has it). The handoff exists
to carry what git cannot reconstruct. Then confirm in one line what you wrote, so the user can correct
it while they still remember.

## Resume / quota recovery

Read the In-Flight row, surface the stopped position, continue. Hit a quota cap mid-run → finish the
current atomic task, run the pause workflow, stop. The In-Flight row is the checkpoint; no manual
state tracking.

## status.md is live state

**Rewritten, never appended. ≤100 lines** (ADR-037, hook-enforced). A finished row is **deleted**, not
marked done — git is the record. History belongs to `git log` (what changed), `docs/handoff/` (what
the build learned), `docs/technical/adr/` (why), and memory (durable facts). Never here.
