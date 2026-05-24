# Contributing to APEX

## Current domain inventory

### Core development (11 domains)

| Domain | SKILL.md | impl.md | Agent |
|--------|----------|---------|-------|
| apex-security | ✅ | ✅ | ✅ |
| apex-backend | ✅ | ✅ | ✅ |
| apex-frontend | ✅ | ✅ | ✅ |
| apex-architecture | ✅ | — | ✅ |
| apex-devops | ✅ | ✅ | ✅ |
| apex-testing | ✅ | ✅ | ✅ |
| apex-performance | ✅ | ✅ | ✅ |
| apex-observability | ✅ | ✅ | ✅ |
| apex-accessibility | ✅ | ✅ | ✅ |
| apex-ai-systems | ✅ | ✅ | ✅ |
| apex-data | ✅ | ✅ | ✅ |

### UI & design (5 domains)

| Domain | SKILL.md | impl.md | Agent |
|--------|----------|---------|-------|
| apex-ui-ux-design | ✅ | ✅ | ✅ |
| apex-design-system | ✅ | ✅ | ✅ |
| apex-animation | ✅ | ✅ | ✅ |
| apex-figma | ✅ | ✅ | ✅ |
| apex-ui-testing | ✅ | ✅ | ✅ |

### Documentation (2 domains)

| Domain | SKILL.md | impl.md | Agent |
|--------|----------|---------|-------|
| apex-docs-technical | ✅ | — | ✅ |
| apex-docs-product | — | ✅ | ✅ |

---

## Adding a new specialist domain

A new domain requires three files:

```
~/.claude/skills/apex-{domain}/
  SKILL.md          # Claude version (planning) — optional if DeepSeek-only
  impl.md           # DeepSeek version (coding) — optional if Claude-only
~/.claude/agents/
  apex-{domain}-agent.md
```

### 1. Write `SKILL.md` (Claude version)

Required sections:
- `## When to activate` — exact conditions (keywords, file paths)
- `## Questions to ask before designing` — domain-specific discovery questions
- `## Trade-off frameworks` — key decisions in this domain with honest pros/cons
- `## Review checklist` — what to check in planning and code review
- `## Escalation rules` — what is a BLOCK vs a FLAG
- `## Standards` — authoritative sources (URLs, not just names)

Metadata header (required):
```yaml
---
skill: apex-{domain}
version: 1.0.0
last_updated: YYYY-MM-DD
sources:
  - {Source Name} — {URL}
staleness_threshold: {Nd}
---
```

**Source quality rule:** Sources must be real, authoritative, and verified before being listed.
Do not list a source because it sounds credible — fetch it and confirm the content matches
what the skill teaches. Use Context7 (`mcp__context7__query-docs`) for library docs,
and WebFetch for standards bodies (OWASP, WCAG, NIST).

### 2. Write `impl.md` (DeepSeek version)

Required sections:
- `## NEVER do` — explicit forbidden patterns (no ambiguity)
- `## ALWAYS do` — required patterns
- At least one `## {Pattern name}` section with actual code examples
- `## Verification checklist` — how to confirm implementation is correct
- `## Flag for Claude review` — what decisions are beyond this skill's authority

### 3. Write the agent file

```markdown
---
name: apex-{domain}-agent
description: {One sentence: what it does and when}
tools: Read, Glob, Grep[, Edit, Write, Bash if DeepSeek mode needs them]
model: sonnet
---

## Purpose
## Activation conditions
## Claude behaviour (planning)     ← omit if DeepSeek-only
## DeepSeek behaviour (coding)     ← omit if Claude-only
```

**Model routing guidance:**
- `opus` — deep reasoning tasks (architecture decisions, security audits, complex logic)
- `sonnet` — standard coding and review tasks (default for most domains)
- `haiku` — lightweight operations (doc lookups, dependency checks, quick searches)

### 4. Register the domain

Add a row to `~/.claude/registry/domains.md`:
```
| {domain} | apex-{domain}/SKILL.md | apex-{domain}/impl.md | apex-{domain}-agent | {keyword1}, {keyword2}, ... |
```

Update `~/.claude/registry/skills.md` and `~/.claude/registry/agents.md`.

### 5. Safety checklist (required for all new domains)

Before submitting a new domain:
- [ ] SKILL.md has escalation rules (BLOCK vs FLAG) with clear criteria
- [ ] impl.md has a NEVER do section with at least 5 explicit rules
- [ ] impl.md has a verification checklist
- [ ] Agent has explicit activation conditions — not "activate for everything"
- [ ] Agent cannot activate other agents (no cross-agent calls)
- [ ] No domain knowledge embedded in the orchestrator
- [ ] All sources verified — fetched and confirmed, not assumed

---

## Completing a partial domain

The 6 UI/design skills currently have SKILL.md only. To complete one:

1. Write `impl.md` following the template above
2. Write `apex-{domain}-agent.md` in `~/.claude/agents/`
3. Update `registry/domains.md` row: replace `—` with the correct paths
4. Update `registry/agents.md` with the new agent

Priority order (suggested): apex-ui-testing → apex-design-system → apex-animation → apex-ui-ux-design → apex-figma

---

## Modifying an existing skill

- Bump the version in the metadata header
- Update `last_updated` to today's date
- Update `sources` if you used new references — verify new sources before listing
- Append to the skill's `CHANGELOG.md`
- Do not remove content without a clear reason — note removals in the changelog

**To augment a skill with an external source:**
1. Fetch the source (URL, GitHub repo, or spec document)
2. Identify what's genuinely new — don't duplicate what's already covered
3. Add the new content to the relevant section
4. Add the source to the metadata `sources:` list
5. Bump the minor version (1.0.0 → 1.1.0)

---

## Cross-domain coordination rule

Specialists cannot activate other specialists.
A specialist may flag that another domain is relevant.
The orchestrator decides whether to load it.
This rule is not optional — it prevents context flooding and uncontrolled chaining.
