---
skill: apex-accessibility
backend: deepseek
version: 1.3.0
last_updated: 2026-06-10
sources:
  - WCAG 2.2 — w3.org/TR/WCAG22
  - ARIA APG — w3.org/WAI/ARIA/apg
  - axe-core — github.com/dequelabs/axe-core
staleness_threshold: 90d
description: >
  Coding-mode enforcement for accessibility — semantic HTML, ARIA, WCAG 2.2 AA hard
  rules (target size, dragging alternative, accessible auth), and the axe + manual
  screen-reader verification loop. Web is the default surface; native swaps via
  § Stack assumptions. Loads when building any user-facing component.
---

# Accessibility Implementation Rules

## Stack assumptions

Patterns below assume **web** (semantic HTML + ARIA). On **SwiftUI** use
`.accessibilityLabel/Hint/Value` + `.accessibilityAddTraits` + Dynamic Type; on **Android**
use `contentDescription` + roles. The WCAG 2.2 *criteria* are identical across surfaces —
only the API changes. Never hand-roll ARIA roles when a native a11y API exists.

## NEVER do

- Use div or span as interactive elements — use button, a, input
- Rely on colour alone to convey meaning (also use text, icon, pattern)
- Use placeholder as a label replacement
- Add tabIndex > 0 (breaks natural tab order)
- Use aria-label on elements that already have visible text
- Open links in new tab without warning (add " (opens in new tab)" to label)
- Block paste on password/OTP fields or gate login behind a cognitive puzzle (WCAG 2.2 §3.3.8)
- Ship a drag-only interaction with no tap/click alternative (WCAG 2.2 §2.5.7)

## ALWAYS do

- Use semantic HTML: nav, main, section, article, h1-h6, button, a, form, label
- Associate form labels with inputs: <label htmlFor="email"> + <input id="email">
- Add aria-describedby for error messages linked to form fields
- Add aria-live="polite" to dynamic content regions
- Add role="dialog" + aria-labelledby + focus trap to modals; return focus on close
- Make interactive targets ≥ 24×24 CSS px (native: 44pt iOS / 48dp Android) (WCAG 2.2 §2.5.8) — this skill owns touch-target minimums
- Give every icon-only button an accessible name: `aria-label` (web) / `.accessibilityLabel` (SwiftUI) / `contentDescription` (Android) — this skill owns the icon-button label rule
- Keep the focused element visible — not hidden behind sticky headers/footers (WCAG 2.2 §2.4.11)
- Test with Tab key — every interactive element must be reachable

## Accessible form field pattern

```tsx
<div>
  <label htmlFor="email" className="block text-sm font-medium">
    Email address
  </label>
  <input
    id="email"
    name="email"
    type="email"
    autoComplete="email"
    aria-describedby={error ? 'email-error' : undefined}
    aria-invalid={!!error}
    className="mt-1 block w-full rounded border"
  />
  {error && (
    <p id="email-error" role="alert" className="mt-1 text-sm text-red-600">
      {error}
    </p>
  )}
</div>
```

## Common errors → fix

| Symptom | Fix |
|---------|-----|
| axe: "element has insufficient color contrast" | raise to ≥4.5:1 (text) / ≥3:1 (large text & UI components) |
| axe: "form element has no label" | add `<label htmlFor>` + matching `id`; placeholder is not a label |
| axe: "interactive control is too small" | enlarge target to ≥24×24px (WCAG 2.2 §2.5.8) |
| Screen reader silent on dynamic update | wrap region in `aria-live="polite"` |
| Focus lost / not visible after action | manage focus explicitly; ensure indicator not obscured (§2.4.11) |
| Drag-only reorder unusable by keyboard | add up/down buttons or tap alternative (§2.5.7) |

## Verification

- [ ] Tab through all interactive elements — all reachable, order logical, focus visible
- [ ] Check: no div or span with onClick without role="button"
- [ ] Check: all images have alt attribute; all inputs have associated labels
- [ ] Check: interactive targets ≥ 24×24px; drag actions have a non-drag alternative
- [ ] Check: every icon-only button has an accessible name (`aria-label` / `.accessibilityLabel` / `contentDescription`)
- [ ] Run axe via a Playwright spec (`@axe-core/playwright` is a library, not a CLI). Create `a11y.spec.ts`:

  ```ts
  import { test, expect } from '@playwright/test';
  import AxeBuilder from '@axe-core/playwright';

  test('no critical a11y violations', async ({ page }) => {
    await page.goto('/');
    const results = await new AxeBuilder({ page }).analyze();
    expect(results.violations.filter(v => v.impact === 'critical')).toEqual([]);
  });
  ```

  Then run: `npx playwright test a11y.spec.ts` — must pass (0 critical violations)
- [ ] **Manual screen-reader pass** (VoiceOver / NVDA / TalkBack): needs a human at a real device/screen reader, which the DeepSeek coding backend **does not have**. **DeepSeek must SKIP this step and flag it for planning-mode (Claude) / human review** — do not guess or mark it done. Automation only catches ~30–40%.
