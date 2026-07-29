---
skill: apex-handoff
version: 1.6.1
last_updated: 2026-07-29
sources:
  - APEX Design Specification 2026-05-24
  - Planning with Files (OthmanAdi) — github.com/OthmanAdi/planning-with-files
  - gstack (garrytan) — github.com/garrytan/gstack
staleness_threshold: 30d
description: >
  Use when writing or consuming handoff — docs/handoff/YYYY-MM-DD.md, or the
  planning↔coding spec boundary. Triggers: "write the handoff", "what did the last build
  learn", one-home-per-fact routing. Canonical home; not spec format (apex-plan).
---

# APEX Handoff Protocol

Defines the handoff format across a session boundary (ADR-038: one session plans and builds, so
the handoff spans *days*, not modes — it is what the next session reads to pick up).
The only way to move from planning to coding is a spec file.
The only way to move from coding to planning is a handoff file.

## What the handoff is

**A thin, read-once inbox: "what the build learned that git can't reconstruct."**
It is *narrative only* — not a state record. One home per fact:

| Fact | Its home — NOT the handoff |
|------|----------------------------|
| What files changed, SHAs | `git log` / `git diff` |
| Build/test status, known issues | status.md (live state) |
| Which specs finished | status.md + `docs/changes/done/` |
| In-progress position (partial/blocked/parked) | status.md **In-Flight** pointer |

The handoff never carries any of the above. If a fact has a home above, it does not
go in the handoff — duplicating it is the root cause of handoff bloat and drift.

## Writing a handoff (coding → planning)

Called by apex-code at the end of every session.

1. Copy template from ~/.claude/skills/apex-orchestrate/templates/handoff-from-coding.md
2. Save to docs/handoff/{YYYY-MM-DD}.md (today's date)
3. Fill only the four narrative sections; write "none" explicitly where empty:
   - **Decisions Made** — autonomous decisions + rationale; mark "review needed" if planning should revisit.
     Tag any *build-time architectural decision* with `[arch]` (a choice that shaped structure —
     a data model, a boundary, a protocol, a dependency). Coding only **tags** it; planning writes
     the ADR during the drain. Do not author the ADR mid-build — the rationale is
     judgment-heavy and is planning's job.
   - **Specialist Flags** — the non-obvious gotcha a specialist surfaced that git diff won't show
     - **AFK-only — end-gate findings:** for an unattended Build Mode run, docs-technical-agent
       records one row per P2 or note finding from the standing end-of-run adversarial pass
       (Opus — ADR-034):

       | Severity | Issue | File | Why |
       |----------|-------|------|-----|

       P1 findings are fixed before the handoff is written and never appear here. If no P2/note
       findings remain, write `End-gate: clean` instead of an empty table. Omit this element from
       Edit Mode handoffs; Edit Mode has no run-wide end-gate.
   - **Blocked Actions** — permissions/architecture calls coding couldn't make; what planning must resolve
   - **What's Next (discoveries)** — only what the build *learned* (surprises, follow-ups) — NOT a
     restatement of remaining tasks (those live in the spec + In-Flight)
4. Update status.md In-Flight (see In-Flight State below). The handoff stays thin precisely
   because In-Flight carries the in-progress position.

## Reading a handoff (planning ← coding) — triage is a drain, not a glance

Called by apex-plan at session start. Read the latest handoff **once**.

**Inbox-zero before closing the session.** Surfacing an item is not landing it — an item
read and not filed is lost. Every handoff item must terminate in **exactly one** of:

1. **Pending Spec** — write/queue a spec (Blocked Actions, "review needed" decisions often land here)
2. **Open Question** — add to status.md Open Questions (unresolved decision)
3. **Folded** — incorporated into existing state (e.g. a gotcha codified into a spec/skill/ADR)
4. **Discarded** — explicitly judged not actionable

**Required routing — `[arch]`-tagged decisions terminate as a written ADR (not optional).**
Every build-time architectural decision tagged `[arch]` in *Decisions Made* must terminate as a
written `docs/technical/adr/ADR-NNN-*.md` **this session** — planning authors it (coding only
tagged it). "Folded" is not sufficient for an `[arch]` item: a one-line mention in a spec or
status.md does not satisfy this — the ADR file must exist. If the decision also changed the
architecture, update `docs/technical/architecture/overview.md` too (de-stub if needed). This
is the drain-side half of the ADR-001 contract; `apex-plan`'s readiness gate is the other half.

A drained handoff stays git-tracked in `docs/handoff/` but is never auto-read again — only
the latest is read, only until drained. Accumulation is storage, not context. No standing
`decisions.md` log (it re-creates the bloat).

## In-Flight State (status.md) — the durable in-progress channel

The In-Flight row is a terse position pointer, not a narrative:
`{spec} · {state} · stopped at task {n}/{total}`. State enum (exactly three):

| State | Meaning |
|-------|---------|
| `partial` | Clean pause mid-spec — coding resumes off the In-Flight pointer; spec stays in `docs/changes/` |
| `blocked` | Needs planning intervention — spec stays in `docs/changes/` marked `blocked` until planning picks it up |
| `parked` | Paused at a gray-zone fork awaiting user routing |

Happy path barely touches In-Flight (clear it); every unhappy path *lives* in it.

## Spec status values

| Status | Meaning |
|--------|---------|
| ✅ complete | All tasks done, all criteria met |
| 🔄 partial | Some tasks done — spec stays in docs/changes/ for resume |
| ❌ blocked | Could not complete — needs planning intervention |

## Commit status values (status.md In-Flight `Uncommitted` column)

The handoff carries no file table — git is the changelog. Uncommitted risk lives in the
status.md In-Flight row:

| Status | Meaning |
|--------|---------|
| ✅ {sha} | Committed — safe |
| 🟡 uncommitted | Changed but not committed — at risk if session crashes |

## Persistent research files (for complex builds)

For large or research-heavy builds, spawn two persistent files alongside the spec:

```
docs/findings/{spec-name}.md   ← research results (save every 2 tool calls)
docs/progress/{spec-name}.md   ← session log + test results (also capture-at-halt records —
                                  drained by apex-plan at session start)
```

Purpose: filesystem as memory — these survive context resets and `/clear`.
Rules:
- Write to findings.md after every 2 search/browse operations
- Log all errors in progress.md (with what was tried) to avoid repeating failures
- Never repeat a failed approach — mutate the strategy and log the mutation

## Session recovery

If context is lost mid-build (crash, `/clear`, rate limit):
1. Read docs/status.md In-Flight table for stopped position
2. Read docs/progress/{spec-name}.md for session log
3. Read docs/findings/{spec-name}.md for accumulated research
4. Resume from the logged checkpoint — no need to re-research

WIP commits: when pausing mid-build, commit with message `wip: {spec-name} — task {n}/{total}` so the checkpoint is in git even if docs/ is lost.

## Spec lifecycle

docs/drafts/{name}.md      ← planning writing/discussing (status: draft)
        ↓ readiness gate passes
docs/changes/{name}.md     ← ready for build (status: ready)
        ↓ "start build" → coding executes
docs/changes/done/{name}.md ← completed (status: done)

A spec in docs/drafts/ is never executed.
A spec in docs/changes/ is always complete and question-free.
