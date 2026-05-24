---
skill: apex-handoff
version: 1.1.0
last_updated: 2026-05-24
sources:
  - APEX Design Specification 2026-05-24
  - Planning with Files (OthmanAdi) — github.com/OthmanAdi/planning-with-files
  - gstack (garrytan) — github.com/garrytan/gstack
staleness_threshold: 30d
---

# APEX Handoff Protocol

Defines the bidirectional handoff format between planning and coding modes.
The only way to move from planning to coding is a spec file.
The only way to move from coding to planning is a handoff file.

## Writing a handoff (coding → planning)

Called by apex-code at the end of every session.

1. Copy template from ~/.claude/skills/apex-orchestrate/templates/handoff-from-coding.md
2. Save to docs/handoff/{YYYY-MM-DD}.md (today's date)
3. Fill every section — no empty sections, no "N/A", write "none" explicitly

Sections that must always be filled:
- What Was Built: 1-3 sentences, what a user would notice
- Specs Completed: every spec touched this session with final status
- Files Changed: every file modified, with short-sha if committed
- Current State: actual build/test status — run the commands, don't guess
- What's Next: at least one concrete suggestion for planning mode

Sections filled only if applicable:
- Documentation Status: fill if any docs work was done
- Specialist Flags: fill if any specialist detected an issue
- Decisions Made: fill if any autonomous decisions were made
- Blocked Actions: fill if any unlisted permissions were encountered

## Reading a handoff (planning ← coding)

Called by apex-plan at session start.

Parse and surface:
1. What's Next → present as suggested starting point for this session
2. Decisions Made with "Yes ⚠️" → these need planning review before next build
3. Specialist Flags with high severity → address in next spec
4. Blocked Actions → add these to permissions section of next relevant spec
5. Current State failing build/tests → this is the first priority

## Spec status values

| Status | Meaning |
|--------|---------|
| ✅ complete | All tasks done, all criteria met |
| 🔄 partial | Some tasks done — spec stays in docs/changes/ for resume |
| ❌ blocked | Could not complete — needs planning intervention |

## File change status values

| Status | Meaning |
|--------|---------|
| ✅ {sha} | Committed — safe |
| 🟡 uncommitted | Changed but not committed — at risk if session crashes |

## Persistent research files (for complex builds)

For large or research-heavy builds, spawn three persistent files alongside the spec:

```
docs/findings/{spec-name}.md   ← research results (save every 2 tool calls)
docs/progress/{spec-name}.md   ← session log + test results
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
