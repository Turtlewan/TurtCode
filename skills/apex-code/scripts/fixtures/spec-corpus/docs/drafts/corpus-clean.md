---
spec: corpus-clean
status: draft
autonomy_level: L2
---

# Spec: Clean corpus fixture

**Identity:** Provides a minimal valid specification fixture.

## Intent
- **Intent:** Exercise the validator's passing path.
- **Invariants:** Validation succeeds without findings.
- **Non-goals:** No implementation work.

## Assumptions
- The validator is available locally -> impact: Stop

Simplicity check: yes - one task and one file are sufficient.

## Prerequisites
- none

## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| src/example.ps1 | modify | Exercise fixture validation |

## Tasks
- [ ] **Task 1: Validate the clean fixture** - files: src/example.ps1 - done when: the fixture passes.

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
- [ ] Task 1 passes for `src/example.ps1` -> verify: validator exits zero.

## Progress
_(The build writes here - do not edit manually)_
