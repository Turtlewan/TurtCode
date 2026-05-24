---
skill: apex-ui-testing
version: 1.0.0
last_updated: 2026-05-24
sources:
  - Playwright Docs — playwright.dev
  - Storybook — storybook.js.org
  - Chromatic — chromatic.com/docs
  - axe-core — github.com/dequelabs/axe-core
staleness_threshold: 14d
---

# UI Testing Implementation Rules

## NEVER do

- Write E2E tests for logic that belongs in unit tests
- Skip accessibility testing on new components
- Hardcode URLs — use relative paths or environment variables
- Use `.waitForTimeout()` — use `waitForSelector` or `expect` locators
- Write visual regression tests without approving a baseline first
- Import Playwright test utilities outside of test files

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
import { checkA11y } from 'axe-playwright'

test('contact page has no a11y violations', async ({ page }) => {
  await page.goto('/contact')
  await checkA11y(page, '#main', { detailedReport: true })
})
```

## Verification checklist

- [ ] Run: `yarn storybook:test` — all stories render without errors
- [ ] Run: `npx playwright test` — all E2E tests pass
- [ ] Run: `npx chromatic --project-token=$CHROMATIC_PROJECT_TOKEN` — baseline approved
- [ ] Check: `@storybook/addon-a11y` shows 0 violations for new components
- [ ] Check: no `.waitForTimeout()` calls in test files

## Flag for Claude review

- Visual regression baseline unclear — first run always needs human approval in Chromatic
- E2E tests failing due to auth — flag to apex-backend for session fixture setup
- axe-core reports contrast violations — flag to apex-accessibility
