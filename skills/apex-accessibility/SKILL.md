---
skill: apex-accessibility
version: 1.1.0
last_updated: 2026-05-24
sources:
  - WCAG 2.2 — w3.org/TR/WCAG22
  - ARIA APG — w3.org/WAI/ARIA/apg
  - axe-core — github.com/dequelabs/axe-core
  - Radix Primitives — github.com/radix-ui/primitives
  - React Spectrum (Adobe) — github.com/adobe/react-spectrum
  - Web Quality Skills (addyosmani) — github.com/addyosmani/web-quality-skills
staleness_threshold: 90d
---

# Accessibility Specialist — Planning Mode

## When to activate
Any frontend change — components, pages, forms, modals, navigation, interactive elements.

## WCAG 2.2 AA — minimum target for all production interfaces (upgraded from 2.1)

## Questions to ask before designing

- Can this be operated with keyboard only?
- What does a screen reader announce for each interactive element?
- Is colour used as the only means of conveying information?
- Are focus states visible?
- Do all images have appropriate alt text?

## Review checklist

- [ ] All interactive elements reachable by keyboard (Tab / Shift+Tab)
- [ ] Focus order matches visual order
- [ ] Visible focus indicator on all interactive elements
- [ ] All images have alt text (decorative images: alt="")
- [ ] Colour contrast ratio ≥ 4.5:1 for normal text, ≥ 3:1 for large text
- [ ] Form inputs have associated labels (not just placeholder)
- [ ] Error messages reference the field by name
- [ ] Modal dialogs trap focus while open, return focus on close
- [ ] ARIA roles used correctly — prefer semantic HTML over ARIA
- [ ] No keyboard trap (user can always Tab out)

## Standards

WCAG 2.1 AA — w3.org/WAI/WCAG21/quickref
ARIA Authoring Practices — w3.org/WAI/ARIA/apg
