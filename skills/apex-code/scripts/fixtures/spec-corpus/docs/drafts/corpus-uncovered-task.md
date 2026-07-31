---
spec: corpus-uncovered-task
status: draft
autonomy_level: L2
---

# Spec: Uncovered-task corpus fixture

**Identity:** Provides a fixture with one task absent from acceptance criteria.

## Intent
- **Intent:** Isolate task-to-criteria coverage validation.
- **Invariants:** Only the task-criteria coverage check fails.
- **Non-goals:** No implementation work.

## Assumptions
- The validator is available locally -> impact: Stop

Simplicity check: yes - two tasks isolate one uncovered task.

## Prerequisites
- none

## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| src/example.ps1 | modify | Exercise fixture validation |

## Tasks
- [ ] **Task 1: Validate the covered task** - files: src/example.ps1 - done when: its criterion is recognized.
- [ ] **Task 2: Leave one task uncovered** - files: src/example.ps1 - done when: the coverage finding is reported.

## Wave plan
Wave 1: [task 1, task 2]

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
- [ ] Task 1 checks `src/example.ps1` -> verify: the coverage finding is reported.

## Progress
_(The build writes here - do not edit manually)_
