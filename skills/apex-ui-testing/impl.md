---
skill: apex-ui-testing
backend: deepseek
version: 1.3.0
last_updated: 2026-06-12
sources:
  - Playwright Docs — playwright.dev
  - Storybook (Vitest addon) — storybook.js.org/docs/writing-tests
  - Chromatic — chromatic.com/docs
  - axe-core (official Playwright) — github.com/dequelabs/axe-core-npm
  - docs/technical/adr/ADR-017-design-brief-artifact.md
  - docs/research/design-capability/ (WS-1/WS-4 — text-proxy visual checks)
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
- Pull a screenshot into context to "check" a UI (`browser_take_screenshot`) — the DeepSeek backend has no image support, so it is a wasted turn; observe via `browser_snapshot` (text a11y tree) instead
- Reflexively render/screenshot a UI just because it changed — only the visual-by-nature cases below justify pixels

## ALWAYS do

- Write a Storybook story before (or alongside) the component
- Run axe-core on every new component via `@storybook/addon-a11y`
- Use Playwright locators over CSS selectors (prefer `getByRole`, `getByLabel`)
- Approve Chromatic baseline before merging a PR with visual changes
- Test the critical user flow for every new page
- Observe a running UI agentically via `browser_snapshot` (accessibility tree), never `browser_take_screenshot`
- For a human to *see* the UI, surface the running dev-server URL (e.g. `http://localhost:3000`) for them to open — do not render it into context
- Keep visual-by-nature judgment headless or deferred: layout/CSS regression → Chromatic (automated); design fidelity → flag to planning-mode (Claude), the only backend that can see pixels
- Verify visual decisions **numerically** against the design brief — `toHaveCSS` token assertions + forbidden-pattern gates (below) — never eyeball them; the coder can't see
- Prefer the Playwright **CLI** (`npx playwright test`) over the Playwright **MCP** for routine coding-mode verification — the MCP's snapshots cost ~4× the tokens; reserve the MCP for planning-mode review

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

## Design-brief compliance checks (text-proxy — for the image-less coder)

The coder can't see the UI, so verify visual decisions **numerically** against
`docs/technical/architecture/design-brief.md` (ADR-017). Deterministic — no vision needed.

### Token compliance (computed style)

```typescript
import { test, expect } from '@playwright/test'

test('primary button uses brief tokens', async ({ page }) => {
  await page.goto('/')
  const btn = page.getByRole('button', { name: 'Create project' })
  await expect(btn).toHaveCSS('background-color', 'rgb(46, 125, 50)') // brief accent
  await expect(btn).toHaveCSS('border-radius', '10px')                // brief radius.md
})
```

### Forbidden-pattern gate (binary — from the brief's don'ts)

```typescript
test('no forbidden fonts or gradient backgrounds', async ({ page }) => {
  await page.goto('/')
  const fonts = await page.$$eval('*', els =>
    [...new Set(els.map(e => getComputedStyle(e).fontFamily))])
  expect(fonts.join(' ')).not.toMatch(/Inter|Roboto/)            // brief forbids these
  const grads = await page.$$eval('*', els =>
    els.map(e => getComputedStyle(e).backgroundImage).filter(b => b.includes('gradient')))
  expect(grads).toHaveLength(0)                                   // brief: no gradient bg
})
```

Generate one token-compliance test per primary component and one forbidden-pattern gate per project,
seeded from the brief's `## Forbidden patterns` list. These catch the slop defaults the coder reaches
for; design *fidelity* (does it look good?) still needs the planning-mode visual review gate
(apex-ui-ux-design § Visual review gate).

## Verification checklist

- [ ] Run stories as tests: `npx vitest --project=storybook` (Vite + `@storybook/addon-vitest`).
      Webpack/RsPack projects: `npx test-storybook` (legacy `@storybook/test-runner`).
- [ ] Run: `npx playwright test` — all E2E tests pass
- [ ] Run: `npx chromatic --project-token=$CHROMATIC_PROJECT_TOKEN` — baseline approved
- [ ] Check: `@storybook/addon-a11y` shows 0 violations for new components
- [ ] Check: no `.waitForTimeout()` calls in test files
- [ ] (UI-bearing) Token-compliance test present for each primary component; values match `design-brief.md`
- [ ] (UI-bearing) Forbidden-pattern gate present, seeded from the brief's `## Forbidden patterns`

## Flag for planning-mode review

- Visual regression baseline unclear — first run always needs human approval in Chromatic
- E2E tests failing due to auth — flag to apex-backend for session fixture setup
- axe-core reports contrast violations — flag to apex-accessibility
- Visual judgment needed (design fidelity, a layout/CSS regression Chromatic can't adjudicate) — flag to planning-mode (Claude); DeepSeek cannot see pixels
