---
spec: corpus-unlisted-file
status: draft
autonomy_level: L2
---

# Spec: Unlisted-file corpus fixture

**Identity:** Provides a fixture that references one unlisted file.

## Intent
- **Intent:** Isolate file-list completeness validation.
- **Invariants:** Only the file-completeness check fails.
- **Non-goals:** No implementation work.

## Assumptions
- The validator is available locally -> impact: Stop

Simplicity check: yes - one unlisted reference is sufficient.

## Prerequisites
- none

## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| src/example.ps1 | modify | Exercise fixture validation |

## Tasks
- [ ] **Task 1: Validate the file-list fixture** - files: src/example.ps1 - done when: the file-list finding is reported.

## Wave plan
Wave 1: [task 1]

## Permissions
Read and validate `src/example.ps1`.

## Specialist Context
### Security
(none)

### Performance
(none)

### Accessibility
(none)

## Documentation
| Doc type | File | Action |
|----------|------|--------|
| None | N/A | No documentation changes |

## Acceptance Criteria
- [ ] Task 1 checks `src/unlisted.ps1` -> verify: the unlisted-file finding is reported.

## Progress
_(The build writes here - do not edit manually)_
