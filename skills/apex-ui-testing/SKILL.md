---
skill: apex-ui-testing
version: 1.0.0
last_updated: 2026-05-24
sources:
  - Playwright MCP — github.com/microsoft/playwright-mcp
  - Storybook — github.com/storybookjs/storybook
  - Chromatic CLI — chromatic.com/docs/cli/
  - axe-core — github.com/dequelabs/axe-core
  - dequelabs axe-core-npm — github.com/dequelabs/axe-core-npm
staleness_threshold: 14d
---

# UI Testing Specialist — Planning Mode

## When to activate
Any spec touching UI components, pages, or user-facing interactions. Particularly: new components, redesigns, accessibility requirements, visual regression concerns.

## Testing layers for UI

| Layer | Tool | What it catches |
|-------|------|----------------|
| Component isolation | Storybook stories | Visual states, prop variants, edge cases |
| Visual regression | Chromatic | Pixel-level unintended changes across builds |
| Accessibility | axe-core (via Storybook a11y addon) | WCAG violations in components |
| E2E browser | Playwright MCP | Critical user flows, real browser behaviour |
| Accessibility E2E | axe-core + Playwright | WCAG violations in assembled pages |

## Playwright MCP (browser automation)

AI agents use Playwright MCP via accessibility snapshots — not pixel-based, so token-efficient.

Available to agents:
- Navigate URLs, click, type, select, fill forms
- Inspect accessibility tree (DOM structure for agents)
- Monitor network requests with headers/body
- Take screenshots for visual reference
- Record traces for debugging

Key advantage: agents can write and run browser tests without vision models.

## Storybook workflow

Every component requires stories covering:
1. Default state
2. All significant variants (size, colour, disabled)
3. Loading state (if async)
4. Error state (if applicable)
5. Empty state (if lists/tables)

```bash
yarn storybook          # develop
yarn storybook:test     # run test-runner (headless)
```

## Chromatic visual regression

Run in CI on every PR:
```bash
npx chromatic --project-token=$CHROMATIC_PROJECT_TOKEN
```

Exit codes: 0 = no changes, 1 = changes detected (requires review), 2 = build error.
Use `--dry-run` locally to check what would be captured.

For Playwright/Cypress: Chromatic captures a DOM archive while your tests run — no separate snapshot step.

## Accessibility testing (axe-core)

```javascript
// In Storybook: @storybook/addon-a11y runs automatically per story
// In Playwright:
import { checkA11y } from 'axe-playwright';
await checkA11y(page, '#main', { detailedReport: true });
```

axe-core finds ~57% of WCAG 2.2 issues automatically. Remaining 43% require manual testing.
Run on every new component + every page assembly.

## Review checklist

- [ ] Storybook stories written for all new components
- [ ] axe-core accessibility addon enabled in Storybook
- [ ] Chromatic configured in CI (project token in secrets)
- [ ] Playwright E2E covers the critical user flow introduced by this spec
- [ ] Accessibility tested at both component (Storybook) and page (Playwright) level
- [ ] Visual baseline approved in Chromatic before merging
