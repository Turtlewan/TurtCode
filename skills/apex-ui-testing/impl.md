---
skill: apex-ui-testing
backend: deepseek
version: 1.1.0
last_updated: 2026-06-01
sources:
  - Playwright Docs — playwright.dev
  - Storybook (Vitest addon) — storybook.js.org/docs/writing-tests
  - Chromatic — chromatic.com/docs
  - axe-core (official Playwright) — github.com/dequelabs/axe-core-npm
staleness_threshold: 14d
description: >
  Use when implementing UI tests — Storybook stories, Playwright E2E, @axe-core/playwright
  accessibility checks, and Chromatic visual regression. Not: test strategy/layer decisions
  (→ apex-testing SKILL.md) or a11y criteria selection (→ apex-accessibility).
---

# UI Testing Implementation Rules

## Stack assumptions

Web browser UI (React/Vue/Svelte). All tools below are browser-bound. React Native/Flutter →
apex-mobile; backend/API tests → apex-testing.

## NEVER do

- Write E2E tests for logic that belongs in unit tests
- Skip accessibility testing on new components
- Hardcode URLs — use relative paths or environment variables
- Use `.waitForTimeout()` — use web-first assertions (`expect(locator)`) or `waitForSelector`
- Write visual regression tests without approving a baseline first
- Import Playwright test utilities outside of test files
- Use `axe-playwright` / `checkA11y` (legacy community pkg) — use `@axe-core/playwright` `AxeBuilder`
- Start a new project on Cypress — Playwright is the default; keep Cypress only if already in use

## ALWAYS do

- Write a Storybook story before (or alongside) the component
- Run axe-core on every new component via `@storybook/addon-a11y`
- Use Playwright locators over CSS selectors (prefer `getByRole`, `getByLabel`)
- Approve Chromatic baseline before merging a PR with visual changes
- Test the critical user flow for every new page

## Storybook story pattern

```typescript
import type { Meta, StoryObj } from '@storybook/react'
import { Button } from './Button'

const meta: Meta<typeof Button> = {
  component: Button,
  tags: ['autodocs'],
}
export default meta

type Story = StoryObj<typeof Button>

export const Default: Story = { args: { label: 'Click me' } }
export const Disabled: Story = { args: { label: 'Disabled', disabled: true } }
```

## Playwright E2E pattern

```typescript
import { test, expect } from '@playwright/test'

test('user can submit the contact form', async ({ page }) => {
  await page.goto('/contact')
  await page.getByLabel('Name').fill('Alice')
  await page.getByLabel('Email').fill('alice@example.com')
  await page.getByRole('button', { name: 'Send' }).click()
  await expect(page.getByText('Message sent')).toBeVisible()
})
```

## axe-core accessibility check (Playwright)

```typescript
import { AxeBuilder } from '@axe-core/playwright'
import { test, expect } from '@playwright/test'

test('contact page has no a11y violations', async ({ page }) => {
  await page.goto('/contact')
  const results = await new AxeBuilder({ page }).analyze()
  expect(results.violations).toEqual([])
})
```

## Verification checklist

- [ ] Run stories as tests: `npx vitest --project=storybook` (Vite + `@storybook/addon-vitest`).
      Webpack/RsPack projects: `npx test-storybook` (legacy `@storybook/test-runner`).
- [ ] Run: `npx playwright test` — all E2E tests pass
- [ ] Run: `npx chromatic --project-token=$CHROMATIC_PROJECT_TOKEN` — baseline approved
- [ ] Check: `@storybook/addon-a11y` shows 0 violations for new components
- [ ] Check: no `.waitForTimeout()` calls in test files

## Flag for planning-mode review

- Visual regression baseline unclear — first run always needs human approval in Chromatic
- E2E tests failing due to auth — flag to apex-backend for session fixture setup
- axe-core reports contrast violations — flag to apex-accessibility
