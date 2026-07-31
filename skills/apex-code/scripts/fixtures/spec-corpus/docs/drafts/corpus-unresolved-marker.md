---
spec: corpus-unresolved-marker
status: draft
autonomy_level: L2
---

# Spec: Unresolved-marker corpus fixture

**Identity:** Provides a fixture containing one unresolved marker.

## Intent
- **Intent:** Isolate unresolved-marker validation.
- **Invariants:** Only the unresolved-marker check fails.
- **Non-goals:** No implementation work.

## Assumptions
- The validator is available locally -> impact: Stop

Simplicity check: yes - one marker is sufficient.

## Prerequisites
- none

## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| src/example.ps1 | modify | Exercise fixture validation |

## Tasks
- [ ] **Task 1: Validate the marker fixture** - files: src/example.ps1 - done when: the marker finding is reported.

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
- [ ] Task 1 checks `src/example.ps1` -> verify: TBD is reported as unresolved.

## Progress
_(The build writes here - do not edit manually)_
