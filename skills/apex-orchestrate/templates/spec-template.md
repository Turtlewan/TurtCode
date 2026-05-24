---
spec: {short-name}
status: draft
token_profile: balanced
autonomy_level: L2
---

# Spec: {title}

## Scope
One paragraph. What this changes and why.

## Prerequisites
- Specs that must be complete first (or "none")
- Environment setup required (or "none")

## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| {full/path/to/file.ts} | create \| modify \| delete | {what changes} |

## Tasks
- [ ] Task 1: {description} — acceptance: {concrete criterion}
- [ ] Task 2: {description} — acceptance: {concrete criterion}
- [ ] Task 3: {description} — acceptance: {concrete criterion}

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
- [ ] {criterion 1}
- [ ] {criterion 2}

## Risks / Open Questions
(Must be empty before spec passes readiness gate)

## Progress
_(Coding mode writes here — do not edit manually)_
