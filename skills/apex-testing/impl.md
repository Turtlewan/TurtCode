---
skill: apex-testing
backend: deepseek
version: 1.1.0
last_updated: 2026-05-31
sources:
  - Vitest Docs — vitest.dev
  - Playwright Docs — playwright.dev
  - docs/technical/adr/ADR-006-buildability-layer-verification-inversion.md
staleness_threshold: 14d
---

# Testing Implementation Rules

> **Test commands and framework patterns come from the bound stack skill's `## Verification
> Recipe` (via `stack_skills`), not from this file.** The Vitest/Playwright examples below are
> **JS-ecosystem illustrations**; for another stack follow that stack skill's test framework
> (e.g. `pytest`, `go test`). apex-code runs the recipe — this file is the test-authoring discipline.

## NEVER do

- Test implementation details — test behaviour and outputs only
- Mock everything — only mock what crosses a real boundary (network, filesystem, time)
- Write a test that always passes (no assertion, or assert true === true)
- Name tests "it works" or "test 1" — describe exact behaviour
- Test private functions directly — test through the public interface
- Copy-paste test code — extract shared setup to beforeEach or helpers

## ALWAYS do

- Name tests as: "it {does something} when {condition}"
- Arrange → Act → Assert structure, one assertion per test where possible
- Test the happy path, one invalid input case, and one edge case per function
- Write the test before the implementation (or immediately after the task, not at the end)
- Prefer real implementations over mocks within the same service boundary

## Vitest unit test pattern

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
