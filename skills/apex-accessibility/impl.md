---
skill: apex-accessibility
version: 1.0.0
last_updated: 2026-05-24
sources:
  - WCAG 2.1 — w3.org/TR/WCAG21
  - ARIA APG — w3.org/WAI/ARIA/apg
staleness_threshold: 90d
---

# Accessibility Implementation Rules

## NEVER do

- Use div or span as interactive elements — use button, a, input
- Rely on colour alone to convey meaning (also use text, icon, pattern)
- Use placeholder as a label replacement
- Add tabIndex > 0 (breaks natural tab order)
- Use aria-label on elements that already have visible text
- Open links in new tab without warning (add " (opens in new tab)" to label)

## ALWAYS do

- Use semantic HTML: nav, main, section, article, h1-h6, button, a, form, label
- Associate form labels with inputs: <label htmlFor="email"> + <input id="email">
- Add aria-describedby for error messages linked to form fields
- Add aria-live="polite" to dynamic content regions
- Add role="dialog" + aria-labelledby + focus trap to modals
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

## Verification checklist

- [ ] Tab through all interactive elements — all reachable, order logical
- [ ] Check: no div or span with onClick without role="button"
- [ ] Check: all images have alt attribute
- [ ] Check: all form inputs have associated label elements
- [ ] Run: npx axe-playwright or browser axe extension — 0 critical violations
