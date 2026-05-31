---
skill: apex-testing
backend: claude
version: 1.1.0
last_updated: 2026-05-31
sources:
  - Superpowers (obra) — github.com/obra/superpowers
  - Agent Skills (addyosmani) — github.com/addyosmani/agent-skills
  - Playwright MCP — github.com/microsoft/playwright-mcp
  - axe-core — github.com/dequelabs/axe-core
  - docs/technical/adr/ADR-006-buildability-layer-verification-inversion.md
staleness_threshold: 14d
description: >
  Use when planning tests for any spec that adds behaviour, fixes a bug, or changes
  functionality — TDD strategy, the test pyramid, DAMP naming, regression tests, E2E via
  Playwright MCP, and accessibility (axe-core). Concrete test commands come from the bound
  stack skill's Verification Recipe, not from here. Not the runner — that's apex-code.
---

# Testing Specialist — Planning Mode

## When to activate
Any spec that adds behaviour, fixes a bug, or changes existing functionality.
TDD is the default — not optional.

Concrete test/coverage **commands** come from the chosen stack's `## Verification Recipe`
(apex-code runs them, ADR-006); this skill is the framework-agnostic test *strategy*.

## RED-GREEN-REFACTOR (mandatory)

1. **RED**: write a failing test that describes the expected behaviour
2. **GREEN**: write the minimum code to make the test pass
3. **REFACTOR**: clean up without breaking the test

Never write implementation before a failing test exists.
Never write a test after the fact to hit coverage numbers.

## Test pyramid (defaults)

| Layer | Target share | What it tests |
|-------|-------------|---------------|
| Unit | 80% | Pure functions, business logic, isolated components |
| Integration | 15% | API endpoints, DB queries, service interactions |
| E2E | 5% | Critical user flows only (login, checkout, key journeys) |

## DAMP over DRY

Tests should be readable without jumping to helpers.
Prefer duplicating setup over abstracting it into a shared helper that obscures intent.
Name tests: `it("does X when Y")` — describes the scenario, not the function.

## Playwright MCP (E2E and browser testing)

Playwright MCP provides AI agents direct browser access via accessibility snapshots (not screenshots — token-efficient and deterministic).

Agent can:
- Navigate URLs, click, type, select, drag, handle dialogs
- Inspect DOM via accessibility tree
- Monitor network requests (headers + body)
- Access console messages
- Record traces and take screenshots for debugging

Use for: E2E tests on critical flows, visual regression baseline capture, accessibility snapshot testing.

Integration:
```bash
npx @playwright/mcp@latest  # start MCP server
```

## Regression tests (from apex-debug)

Every bug fix requires a regression test:
- Must FAIL before the fix and PASS after
- Name: `it("does not {reproduce the bug scenario}")`
- Placed next to the unit being fixed

## Accessibility testing

Run axe-core in integration tests for any component with UI:
```javascript
import axe from 'axe-core';
// in test:
const results = await axe.run();
if (results.violations.length) throw new Error('a11y violations found');
```

axe-core finds ~57% of WCAG issues automatically. Covers WCAG 2.0, 2.1, 2.2 at A/AA/AAA.

## Review checklist

- [ ] Failing test written before implementation (RED phase documented)
- [ ] Tests named descriptively (behaviour, not function name)
- [ ] No test verifies implementation details — only observable behaviour
- [ ] Integration tests hit real dependencies (not mocked DB unless justified)
- [ ] E2E tests cover the happy path only; edge cases handled at unit level
- [ ] Regression test added for every bug fixed
- [ ] axe-core run on any new UI component
