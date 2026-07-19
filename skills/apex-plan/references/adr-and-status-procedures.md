# apex-plan — ADR & status.md procedures (on-demand)

Split out of `apex-plan/SKILL.md` to keep the core under the 500-line cap. Load this only when you
are actually performing one of these two end-of-step procedures.

---

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

---

## status.md update — by mode

### Deep Details / Light
At the end of every planning pass:
1. Read current docs/status.md
2. Rewrite content between <!-- PLANNING:START --> and <!-- PLANNING:END -->:
   - Pending table: scan docs/changes/*.md (not done/). One row per spec, alphabetical
   - Open questions: carry over unresolved, add new, remove resolved
3. Update _Last updated:_ line to today's date
4. Write file back

### Bug Fix
No status.md update. Bug fix docs are ephemeral — consumed and archived within the session.
