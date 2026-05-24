---
skill: apex-refresh
version: 1.1.0
last_updated: 2026-05-24
sources:
  - APEX Design Specification 2026-05-24
  - Context7 (Upstash) — github.com/upstash/context7
  - Snyk Agent Scan — github.com/snyk/agent-scan
  - Vercel Skills CLI — github.com/vercel-labs/skills
staleness_threshold: 30d
---

# APEX Knowledge Refresh

Manual-only. Suggested cadence: every 2 weeks.
Never overwrites a skill without showing a diff and getting approval.
Full research pass — not limited to original sources.

## Invocation

/apex-refresh apex-security              # refresh one skill
/apex-refresh --audit                    # show staleness of all skills (informational only)
/apex-refresh --all                      # refresh all stale skills, one at a time

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
3. Append to skill changelog (create if not exists):
   `~/.claude/skills/{skill-name}/CHANGELOG.md`
   ```
   ## {version} — {YYYY-MM-DD}
   - Updated: {what changed}
   - Added: {new content}
   - Sources: {new sources added}
   ```

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

## Batch refresh (/apex-refresh --all)

Refreshes all skills with 🔴 or ⚠️ status, one at a time.
Presents each refresh individually — you approve or skip each skill before moving on.
Does not batch approvals — every skill gets its own review.

## Skill metadata header format

Every skill should have this at the top:

```yaml
---
skill: apex-{name}
version: 1.0.0
last_updated: YYYY-MM-DD
sources:
  - {Source Name} — {URL or reference}
staleness_threshold: 14d
---
```

If a skill is missing this header, add it during the refresh.
