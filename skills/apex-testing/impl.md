---
skill: apex-testing
backend: coding
version: 1.3.0
last_updated: 2026-06-10
sources:
  - Vitest Docs — vitest.dev
  - Playwright Docs — playwright.dev
  - docs/technical/adr/ADR-006-buildability-layer-verification-inversion.md
staleness_threshold: 14d
description: >
  Coding-mode test-authoring discipline — stack-neutral invariants (test behaviour not
  implementation, AAA structure, descriptive "it does X when Y" names, mock only real boundaries,
  test through the public interface). Loaded when a task adds/changes tests. Test commands +
  framework come from the bound stack skill's `## Verification Recipe`, NOT this file (Vitest/
  Playwright shown are JS illustrations — pytest / go test / XCTest on other stacks); see § Stack
  assumptions.
---

# Testing Implementation Rules

## Stack assumptions

The test-authoring discipline below is **stack-neutral**. The **test commands and framework come
from the bound stack skill's `## Verification Recipe`** (via `stack_skills`), *not* from this file —
apex-code runs that recipe. The **Vitest / Playwright** examples are **JS-ecosystem illustrations**;
on the bound stack swap the framework: **Python** pytest (+ Playwright-Python / httpx for E2E/API);
**Go** `go test`; **Swift/Apple** XCTest / Swift Testing + XCUITest. The *patterns* (AAA, behaviour
assertions, descriptive names) are identical across all of them.

## NEVER do

- Test implementation details — test behaviour and outputs only
- Mock everything — only mock what crosses a real boundary (network, filesystem, time)
- Write a test that always passes (no assertion, or assert true === true)
- Name tests "it works" or "test 1" — describe exact behaviour
- Test private functions directly — test through the public interface
- DRY-up test cases at the cost of readability — prefer duplicated, readable setup (DAMP); extract only mechanical boilerplate (server boot, db reset) into beforeEach

## ALWAYS do

- Name tests as: "it {does something} when {condition}"
- Arrange → Act → Assert structure, one assertion per test where possible
- Test the happy path, one invalid input case, and one edge case per function
- Write the test before the implementation (or immediately after the task, not at the end)
- Prefer real implementations over mocks within the same service boundary

## Vitest unit test pattern (JS illustration — see § Stack assumptions)

```typescript
import { describe, it, expect, beforeEach } from 'vitest'
import { createUser } from '../src/services/user'

describe('createUser', () => {
  it('returns created user when given valid data', async () => {
    const result = await createUser({ name: 'Alice', email: 'alice@test.com' })
    expect(result.id).toBeDefined()
    expect(result.name).toBe('Alice')
  })

  it('throws ValidationError when email is missing', async () => {
    await expect(createUser({ name: 'Alice', email: '' })).rejects.toThrow('ValidationError')
  })
})
```

## Playwright e2e pattern

```typescript
import { test, expect } from '@playwright/test'

test('user can log in with valid credentials', async ({ page }) => {
  await page.goto('/login')
  await page.fill('[name="email"]', 'test@example.com')
  await page.fill('[name="password"]', 'password123')
  await page.click('[type="submit"]')
  await expect(page).toHaveURL('/dashboard')
})
```

## Verification checklist

Commands come from the bound stack skill's `## Verification Recipe` (via `stack_skills`) — **not
assumed npm**. apex-code runs the recipe; this is the test-layer intent it must satisfy.

- [ ] Run the recipe's **test** command — all tests pass (e.g. `pytest`, `go test ./...`, `npm test`)
- [ ] Coverage ≥ 80% for changed files, via the recipe's coverage command if it declares one
- [ ] No skipped tests left in (`.skip` / `xit` / `@pytest.mark.skip` / `t.Skip`)
- [ ] Each new function/behaviour has at least one test
