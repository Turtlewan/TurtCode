---
spec: {short-name}
status: draft
token_profile: balanced
autonomy_level: L2
---

# Spec: {title}

<!-- Split rule: if this spec touches >3 files OR has >2 logical phases, split it into separate specs. -->

## Assumptions
<!-- Planning mode fills this. Coding mode verifies each item before executing. -->
<!-- Format: assumption → impact if wrong (Stop | Caution | Low) -->
- {Assumption 1} → impact: {Stop | Caution | Low}
- {Assumption 2} → impact: {Stop | Caution | Low}

<!-- Simplicity check (planning fills this): -->
<!-- "Is there a simpler spec? ___. Why this version: ___." -->
Simplicity check: {considered simpler approach? yes/no — if yes, why this version instead}

## Prerequisites
- Specs that must be complete first (or "none")
- Environment setup required (or "none")

## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| {full/path/to/file.ts} | create \| modify \| delete | {what changes} |

## Tasks
- [ ] Task 1: {description} — done when: {observable outcome}
- [ ] Task 2: {description} — done when: {observable outcome}
- [ ] Task 3: {description} — done when: {observable outcome}

## Permissions

The following actions will run autonomously during build.
Approving this spec approves all of them.

### File Operations
| Action | Paths |
|--------|-------|
| Create | {full/path/to/new-file.ts} |
| Modify | {full/path/to/existing.ts} |
| Delete | (none) |

### Commands
| Command | Purpose |
|---------|---------|
| `{exact command}` | {what it does} |

### Git Operations
| Operation | Scope |
|-----------|-------|
| `git add` | {path pattern} |
| `git commit` | "{conventional commit message}" |

### Environment Access
| Variable | Purpose |
|----------|---------|
| `{VAR_NAME}` | {what it's used for} |

### Network
| Action | Purpose |
|--------|---------|
| `npm install` | Package installation |

## Specialist Context
### Security
(none — or findings from apex-security review)

### Performance
(none — or constraints/budgets)

### Accessibility
(none — or a11y requirements if frontend change)

## Documentation
| Doc type | File | Action |
|----------|------|--------|
| Inline | {path} | JSDoc/TSDoc all exports |
| API | docs/product/api/{name}.md | {add/update} section |
| Changelog | CHANGELOG.md | Add entry under Unreleased |
| ADR | docs/technical/adr/ADR-{NNN}-{title}.md | Write (if architectural decision) |

## Acceptance Criteria
<!-- Use step→verify format. "Done" must be observable, not vague. -->
- [ ] {Step 1} → verify: {what to check — specific, observable}
- [ ] {Step 2} → verify: {what to check — specific, observable}
- [ ] {Step 3} → verify: {what to check — specific, observable}

## Progress
_(Coding mode writes here — do not edit manually)_
