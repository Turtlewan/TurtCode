---
skill: apex-ui-testing
backend: claude
version: 1.1.0
last_updated: 2026-06-01
sources:
  - Playwright MCP — github.com/microsoft/playwright-mcp
  - Storybook (Vitest addon) — storybook.js.org/docs/writing-tests
  - Chromatic CLI — chromatic.com/docs/cli/
  - axe-core (official Playwright) — github.com/dequelabs/axe-core-npm
staleness_threshold: 14d
description: >
  Use when planning UI component or page tests for browser-based apps. Triggers: new
  components, redesigns, "add tests for this UI", accessibility requirements, visual-regression
  concerns, critical E2E user flows. Not: backend/API tests or test strategy/pyramid
  (→ apex-testing), native mobile UI (→ apex-mobile), or a11y criteria selection
  (→ apex-accessibility).
---

# UI Testing Specialist — Planning Mode

## Stack assumptions

Web browser UI only — every tool here (Playwright, Storybook, Chromatic, axe-core) is
browser-bound. For **React Native / Flutter** defer to apex-mobile; for **backend / API**
tests and overall test-pyramid strategy defer to apex-testing; for **a11y criteria** decisions
(which WCAG rules apply) defer to apex-accessibility. This skill owns the *web UI* test layer.

## When to activate
Any spec touching UI components, pages, or user-facing interactions. Particularly: new
components, redesigns, accessibility requirements, visual regression concerns.

## Testing layers for UI

| Layer | Tool | What it catches |
|-------|------|----------------|
| Component isolation | Storybook stories | Visual states, prop variants, edge cases |
| Component-as-test | Storybook **Vitest addon** (Vite) / test-runner (Webpack) | Stories render + interactions, run as Vitest browser tests |
| Visual regression | Chromatic | Pixel-level unintended changes across builds |
| Accessibility | axe-core (Storybook a11y addon) | WCAG violations in components |
| E2E browser | Playwright (+ Playwright MCP for agents) | Critical user flows, real browser behaviour |
| Accessibility E2E | `@axe-core/playwright` | WCAG violations in assembled pages |

**Tool stance (2026):** Playwright is the default for new projects (E2E and, where component-level
isolation outside Storybook is wanted, the still-experimental `@playwright/experimental-ct-*`).
**Don't start new projects on Cypress** — only keep it if the project already uses it.

## Playwright MCP (browser automation)

Use the **official** `@playwright/mcp` (Microsoft). AI agents drive it via accessibility
snapshots — not pixel-based, so token-efficient. Agents can navigate/click/type/fill, inspect
the accessibility tree, monitor network, screenshot, and record traces — writing and running
browser tests without a vision model. Playwright 1.59+ adds `browser.bind()`, letting the MCP
and CLI share one browser session (useful for agent-driven workflows).

## Storybook workflow

Every component requires stories covering: (1) default, (2) all significant variants
(size/colour/disabled), (3) loading (if async), (4) error (if applicable), (5) empty (if
lists/tables).

Run stories as tests via the **Vitest addon** (`@storybook/addon-vitest`) on Vite-based setups —
it executes stories as Vitest browser-mode tests (Playwright Chromium) without Storybook running.
The legacy `@storybook/test-runner` is superseded but remains the path for **Webpack/RsPack**
projects. (Exact run commands live in impl.md.)

## Chromatic visual regression

Run in CI on every PR. Exit codes: 0 = no changes, 1 = changes detected (needs review),
2 = build error; `--dry-run` previews what would be captured. With Playwright, Chromatic
captures a DOM archive during the test run — no separate snapshot step. First run always needs
a human-approved baseline. (Command in impl.md.)

## Accessibility testing (axe-core)

Use Deque's official `@axe-core/playwright` (`AxeBuilder`) for page-level checks and the
Storybook a11y addon for component-level. axe-core auto-detects **~57% of WCAG issues overall**
(2.0/2.1/2.2); coverage of the **new WCAG 2.2 success criteria specifically is much narrower**
(target-size is about the only new 2.2 rule it adds) — Focus Appearance, Dragging Movements,
Accessible Authentication, etc. need manual testing. Run on every new component + page assembly.

## Review checklist

- [ ] Storybook stories written for all new components (default + variants + async/empty/error)
- [ ] axe-core a11y addon enabled in Storybook; `@axe-core/playwright` on page assemblies
- [ ] Chromatic configured in CI (project token in secrets); baseline approved before merge
- [ ] Playwright E2E covers the critical user flow introduced by this spec
- [ ] Accessibility tested at both component (Storybook) and page (Playwright) level
- [ ] WCAG 2.2-specific criteria manually verified (axe won't catch most) — see apex-accessibility
