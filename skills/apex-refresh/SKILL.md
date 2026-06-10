---
skill: apex-refresh
backend: claude
version: 1.3.0
last_updated: 2026-06-10
sources:
  - APEX Design Specification 2026-05-24
  - Context7 (Upstash) — github.com/upstash/context7
  - Snyk Agent Scan — github.com/snyk/agent-scan
  - Vercel Skills CLI — github.com/vercel-labs/skills
  - ECC skill-stocktake + rules-distill (absorption Phase 5)
staleness_threshold: 30d
description: >
  Use when maintaining the skill SET itself — refreshing a skill's content against current best
  practice, or auditing skill quality/staleness across all skills. Triggers: "refresh apex-X",
  "is this skill stale", "/apex-refresh", "audit the skills", "skill stocktake", "are my skills
  still good". Three jobs: currency refresh of one/all skills (research-driven, diff + approval),
  staleness audit by date (--audit), and quality stocktake of the set + rule-promotion candidates
  (--stocktake, folds in rules-distill). Not authoring a new skill (apex-skill-author) or a token/
  context audit (apex-context-budget).
---

# APEX Knowledge Refresh

Manual-only. Suggested cadence: every 2 weeks.
Never overwrites a skill without showing a diff and getting approval.
Full research pass — not limited to original sources.

## Invocation

/apex-refresh apex-security              # refresh one skill
/apex-refresh --audit                    # show staleness of all skills (informational only)
/apex-refresh --all                      # refresh all stale skills, one at a time
/apex-refresh --stocktake                # quality audit of the skill SET (Quick Scan; folds in rules-distill)
/apex-refresh --stocktake full           # quality audit of every skill

## Single skill refresh workflow

### Step 1: Read current skill

Read the target skill file in full. Extract:
- What does this skill currently teach? (summarise in 3-5 bullets)
- What sources were originally cited?
- When was it last updated? (from metadata header)
- What domain does it cover?

### Step 2: Full research pass

Research the current state of the domain. Do NOT limit to original sources.
Ask: "If I were writing this skill today from scratch, what would I include?"

Research directions:
- Current best practices for this domain (as of today)
- What has changed since {last_updated} in this domain?
- Current recommended standards, tools, and patterns
- Known anti-patterns or vulnerabilities discovered recently
- Community consensus from respected sources
- Any deprecations or replacements for tools previously recommended

Research tools:
- **Context7** (`mcp__context7__query-docs`): live library docs — use for any framework/library claims. Prevents recommending deprecated APIs.
- **Snyk Agent Scan**: for security or devops skills, run `snyk agent-scan` to check if recommended tools have known vulnerabilities
- **WebFetch + Firecrawl**: for official standard bodies (OWASP, WCAG, NIST), fetch the live source directly

### Step 3: Synthesise findings

Produce a structured comparison:

```
STILL VALID (keep as-is):
- {point} — confirmed current by {source}

OUTDATED (needs update):
- CURRENT: "{what the skill currently says}"
  UPDATED: "{what it should say}" — reason: {why it changed}

MISSING (add to skill):
- {important content not covered} — from {source}

NEW SOURCES:
- {source name}: {URL} — why it's better/more current than what was cited
```

### Step 4: Show full proposed rewrite

Present the complete updated skill content — not just the changed sections.
The executor should be able to copy-paste the full rewrite if approved.

### Step 5: Require approval

Present clearly:
```
Summary of changes:
- {N} sections updated (outdated → current)
- {N} new sections added (missing content)
- {N} sources replaced or added

Apply full update? [y / n / partial]

partial → user specifies which sections to accept
```

Do NOT write anything until approved.

### Step 6: On approval

1. Update the skill file with approved content
2. Update metadata header:
   - version: bump minor (1.0.0 → 1.1.0) for partial, major (1.0.0 → 2.0.0) for full rewrite
   - last_updated: today's date
   - sources: updated list with new citations
3. Record the change in `~/apex/SKILL-HISTORY.md` — prepend one row (newest first):
   `Date | Skill | Files | Version | Event | What Changed | Sources`.
   SKILL-HISTORY.md is the single source of truth for "what changed when" — do NOT create
   per-skill CHANGELOG.md files. Sync `~/apex/SKILLS.md` / `registry/domains.md` if the
   description or routing changed (the triple-write — see apex-skill-author).

## Audit mode (/apex-refresh --audit)

Read all skill files in ~/.claude/skills/apex-*/SKILL.md.
For each, read metadata header and calculate days since last_updated.

Display:
```
Skill staleness audit (informational — nothing is blocked)
──────────────────────────────────────────────────────────
✅ apex-frontend     updated 5d ago    (threshold: 14d)
🟡 apex-backend      updated 18d ago   (threshold: 14d) → consider refreshing
🔴 apex-security     updated 45d ago   (threshold: 14d) → recommended to refresh
⚠️ apex-data         no metadata header

Run /apex-refresh <skill> when ready.
```

Staleness states:
- ✅ Fresh: updated within threshold (default 14d, configurable per skill)
- 🟡 Aging: 1x–2x threshold
- 🔴 Stale: beyond 2x threshold
- ⚠️ Unknown: no metadata header

Nothing is blocked by staleness. This is informational only.

## Stocktake mode (/apex-refresh --stocktake)

A quality audit of the skill **set** — distinct from `--audit`, which only checks staleness by
date. It scores each skill against the APEX authoring contract **and** cross-reads for principles
that should be promoted to `apex-coding-principles` (rules-distill, folded in — ECC absorption
Phase 5). **Report-only — it never edits a skill.** Automates the *finding* step of a manual SP5
sweep; fixing stays on the existing paths (Phase 4 below).

### Modes
- **Quick Scan** (default): evaluate only skills changed since the last stocktake.
- **Full** (`--stocktake full`): evaluate every `apex-*` skill.

### Phase 1 — Inventory
- `Glob ~/.claude/skills/apex-*/{SKILL,impl}.md`; read each frontmatter.
- **Quick Scan change-detection (git, no verdict cache):** read the marker
  `~/.claude/skills/apex-refresh/.stocktake-state` (a stored commit SHA), then
  `git -C ~/.claude diff --name-only <SHA>..HEAD -- skills/apex-*` for the changed set.
  Marker absent → report "no prior stocktake — run `--stocktake full`" and stop.
- State which skills will be evaluated (and which paths were scanned).

### Phase 2 — Evaluate (dispatched, chunked)
Dispatch `general-purpose` subagents, **~15–20 skills per chunk** (keeps each context lean). Give
each chunk the skill files + the checklist below + the full `apex-coding-principles` text. Each
returns, per skill, one quality verdict **and** any rule-promotion candidates.

**Quality checklist (per skill):**
- [ ] Frontmatter complete: `skill, backend, version, last_updated, sources, staleness_threshold, description`
- [ ] `description` is **trigger-style** ("Use when…", real phrases, near-miss exclusions) — NOT a workflow summary
- [ ] SKILL.md ≤ 500 lines / 5k tokens
- [ ] SKILL-vs-impl split appropriate; if `impl.md` exists it follows the **two-tier core/references** convention (core, by section identity = frontmatter + `## Stack assumptions` [capability only] + NEVER/ALWAYS + `## Verification Recipe` [stack only] + a compact errors table; bulky content in `references/*.md` with a load condition)
- [ ] **Triple-write in sync:** a `registry/domains.md` row, a `SKILLS.md` entry, and a `SKILL-HISTORY.md` row all exist
- [ ] Content is gotchas / defaults / procedures — not what the model already knows
- [ ] Stack skill (`apex-<framework>`): `impl.md` carries a runnable `## Verification Recipe`
- [ ] Holistic: actionability · scope-fit · uniqueness (not replaceable by CLAUDE.md / another skill) · currency

**Verdict (per skill):** `Keep | Improve | Update | Retire | Merge into [X]`.
The `reason` **must be self-contained and decision-enabling** — restate the evidence; never just
"unchanged" or "too long". For **Retire/Merge**, name what covers the same need instead; for
**Improve**, name the section and the change.

**Rule-promotion cross-read (folded-in rules-distill):** while reading, flag any principle meeting
**ALL** of — appears in **2+ skills** · is an actionable do/don't · has a clear violation risk · is
**NOT** already in `apex-coding-principles`. Verdict each: `Append | Revise | New Section | New File
| Already Covered | Too Specific`. Target = `apex-coding-principles` (or a shared `impl.md` core).
**What, not how** — code/commands stay in the skill; the promoted rule links back with `See skill: X`.

### Phase 3 — Report (two tables, informational — nothing is blocked)
- **Table A — per-skill quality:** `| Skill | Verdict | Reason |`
- **Table B — promotion candidates:** `| Principle | # skills (evidence) | Verdict | Target |`

### Phase 4 — Route (no auto-fix; apply only on user go-ahead)
Each finding goes to its existing fix path:
- **Update** (stale tech) → `/apex-refresh <skill>`
- **Improve / frontmatter / length / triple-write gap** → an `apex-skill-author` edit
- **Retire / Merge** → present full justification (defect found · what covers it · impact), require **explicit** user confirmation
- **Promotion candidate** → an `apex-skill-author` edit to `apex-coding-principles`

Then write the new HEAD SHA + UTC timestamp (`date -u +%Y-%m-%dT%H:%M:%SZ`) to `.stocktake-state`.

## Batch refresh (/apex-refresh --all)

Refreshes all skills with 🔴 or ⚠️ status, one at a time.
Presents each refresh individually — you approve or skip each skill before moving on.
Does not batch approvals — every skill gets its own review.

## Skill metadata header format

Every skill should have this at the top:

```yaml
---
skill: apex-{name}
backend: claude
version: 1.0.0
last_updated: YYYY-MM-DD
sources:
  - {Source Name} — {URL or reference}
staleness_threshold: 14d
---
```

If a skill is missing this header, add it during the refresh.
