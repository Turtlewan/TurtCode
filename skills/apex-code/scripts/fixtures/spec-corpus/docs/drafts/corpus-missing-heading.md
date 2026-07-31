---
spec: corpus-missing-heading
status: draft
autonomy_level: L2
---

# Spec: Missing-heading corpus fixture

**Identity:** Provides a fixture with one required heading omitted.

## Intent
- **Intent:** Isolate required-heading validation.
- **Invariants:** Only the structure check fails.
- **Non-goals:** No implementation work.

## Prerequisites
- none

## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| src/example.ps1 | modify | Exercise fixture validation |

## Tasks
- [ ] **Task 1: Validate the structure fixture** - files: src/example.ps1 - done when: the structure finding is reported.

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
- [ ] Task 1 checks `src/example.ps1` -> verify: the required-heading finding is reported.

## Progress
_(The build writes here - do not edit manually)_
