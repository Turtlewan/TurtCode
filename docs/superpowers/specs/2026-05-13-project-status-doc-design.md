# Project Status Document — Design Spec

**Date:** 2026-05-13
**Status:** Approved — pending implementation

---

## Overview

A single `docs/status.md` file that serves as the planning agent's session-start anchor. It replaces the current guidance to read the latest handoff doc + scan `docs/changes/` separately, consolidating everything the planner needs into one read: completed work, current state, pending specs, and open questions. Both coding mode (`doc-writer`) and planning mode (CLAUDE.md) maintain it from their respective perspectives.

---

## 1. File Structure

Location: `docs/status.md` in each project.

```markdown
# Project Status

_Last updated by coding mode: YYYY-MM-DD_
_Last updated by planning mode: YYYY-MM-DD_

<!-- CODING:START -->
## Completed

| Date | Feature | Spec |
|------|---------|------|
| 2026-05-13 | 6-agent coding pipeline | `docs/changes/done/coding-pipeline-agents.md` |

## Current state

- **Build:** passing / failing / unknown
- **Tests:** passing / failing / unknown
- **Known issues:** none
<!-- CODING:END -->

<!-- PLANNING:START -->
## Pending

| Priority | Spec | Summary |
|----------|------|---------|
| 1 | `docs/changes/auth.md` | Add OAuth2 login flow |

## Open questions

- [unresolved question or decision]
<!-- PLANNING:END -->
```

### Section ownership

| Block | Owner | Updated when |
|-------|-------|--------------|
| `CODING:START` → `CODING:END` | `doc-writer` agent | After each coding pipeline run |
| `PLANNING:START` → `PLANNING:END` | Planning mode (CLAUDE.md) | At end of each planning session |

Neither writer touches the other's block. Each overwrites its own block in full.

---

## 2. doc-writer Changes

Add a new step after archiving the spec (current step 2).

**New step 3:** Update `docs/status.md`:

1. Read `docs/status.md` if it exists. If it doesn't, create it with the full template (both blocks present, PLANNING block empty).
2. Rewrite everything between `<!-- CODING:START -->` and `<!-- CODING:END -->` (inclusive of the markers):
   - **Completed table:** append a new row for the spec just executed. Date = today. Feature = one-line summary from the spec. Spec = path under `docs/changes/done/`.
   - **Current state:** rewrite from the pipeline run results — build/test outcomes reported by code-worker(s), reviewer flags that were not addressed.
3. Update the `_Last updated by coding mode:_` timestamp at the top.
4. Write the file back.

### CODING block content rules

- Never remove existing rows from the Completed table — only append.
- Current state reflects the state at the END of this run. If build/test results are unknown (no commands were run), write "unknown".
- Unaddressed reviewer flags belong in Known issues.

---

## 3. CLAUDE.md Changes

### Planning mode — session start

Replace the current steps 1-2:

> 1. Read the latest `docs/handoff/*.md` to understand what was built last session.
> 2. Review any remaining specs in `docs/changes/` to understand what's still pending.

With:

> 1. Read `docs/status.md` to understand the current project state — completed work, current state, pending specs, and open questions. If `docs/status.md` does not exist, fall back to reading the latest `docs/handoff/*.md` and scanning `docs/changes/*.md` as before.

Step 3 (summarise understanding back to user) stays unchanged.

### Planning mode — session end

Add a new step after writing specs:

> Before closing the session, update `docs/status.md`:
>
> 1. Read the current file (create with full template if it doesn't exist).
> 2. Rewrite everything between `<!-- PLANNING:START -->` and `<!-- PLANNING:END -->`:
>    - **Pending table:** scan `docs/changes/*.md` (not `done/`). List each spec with a one-line summary in priority order (most urgent first).
>    - **Open questions:** carry over any unresolved questions from the previous PLANNING block, plus any new unresolved questions from this session. Remove questions that were resolved this session.
> 3. Update the `_Last updated by planning mode:_` timestamp at the top.
> 4. Write the file back.

---

## 4. Initial Creation

If `docs/status.md` does not exist:

- **doc-writer** creates it with both blocks present. PLANNING block contains empty Pending table and "None" under Open questions.
- **Planning mode** creates it with both blocks present. CODING block contains empty Completed table and "unknown" for all Current state fields.

Whichever writer runs first creates the file. The other writer fills in its own block on its next run.

---

## 5. Relationship to Existing Handoff Docs

`docs/handoff/YYYY-MM-DD.md` files are kept as-is. They remain the detailed per-session record.

`docs/status.md` is the summary layer on top:
- Planner reads `docs/status.md` first.
- If detail on a specific past session is needed, the planner reads the relevant `docs/handoff/YYYY-MM-DD.md` directly.
- `docs/status.md` does not replace handoff docs — it reduces how often the planner needs to dig into them.

---

## 6. Files to Change

| File | Change |
|------|--------|
| `~/.claude/agents/doc-writer.md` | Add step 3: update `docs/status.md` CODING block after archiving spec |
| `~/.claude/CLAUDE.md` | Replace planning session-start steps 1-2; add planning session-end status update step |

No new agent files. No new tools required.

---

## 7. Risks / Open Questions

- **Multiple coding runs on the same day:** `doc-writer` appends to the Completed table, so two runs on the same day produce two rows. This is correct — don't deduplicate by date.
- **PLANNING block on first coding run:** If no planning session has run yet, the PLANNING block will be empty (or absent). `doc-writer` must create it with empty content, not omit it — the markers must always be present for future writers to locate them.
- **Manually-edited status.md:** If the user edits the file by hand, the block markers must remain intact. Document this constraint in the file itself via a comment above the first marker.
