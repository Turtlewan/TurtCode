---
skill: apex-accessibility
backend: claude
version: 1.2.0
last_updated: 2026-06-01
sources:
  - WCAG 2.2 — w3.org/TR/WCAG22
  - EN 301 549 / European Accessibility Act — ec.europa.eu (EAA enforcement 2025-06-28)
  - ARIA APG — w3.org/WAI/ARIA/apg
  - axe-core — github.com/dequelabs/axe-core
  - Apple HIG Accessibility — developer.apple.com/design/human-interface-guidelines/accessibility
  - Android Accessibility — developer.android.com/guide/topics/ui/accessibility
staleness_threshold: 90d
description: >
  Use when designing or reviewing any interface for accessibility — components,
  pages, forms, modals, navigation, focus, colour contrast, screen-reader support,
  keyboard operation, or touch-target sizing. Triggers: "is this accessible", "a11y",
  "WCAG", "screen reader", "keyboard nav", "EAA compliance", or any frontend change
  that ships to users. Stack-neutral on principles; web (ARIA/HTML) is the default
  surface, native (SwiftUI/Android) swaps via § Stack assumptions. Not the coding-mode
  enforcement rules (that's impl.md).
---

# Accessibility Specialist — Planning Mode

## When to activate
Any user-facing change — components, pages, forms, modals, navigation, interactive
elements — on any surface (web, iOS/macOS, Android).

## Target: WCAG 2.2 AA — minimum for all production interfaces

WCAG 2.2 (Oct 2023) is the current W3C Recommendation and a **superset of 2.1** — meeting
2.2 AA also satisfies 2.1 AA.

**Why 2.2 AA, not just 2.1:** the **European Accessibility Act** (EAA) has been enforceable
since **2025-06-28**, with enforcement intensifying through 2026. Its harmonised standard
**EN 301 549** currently references **WCAG 2.1 AA** as the legal floor and is being updated
to 2.2 — so targeting 2.2 AA is forward-compatible and covers both. The EAA also reaches
**beyond web**: support docs, cancellation/post-sale flows, and hardware — relevant to any
multi-surface product.

## Stack assumptions

| Layer | Web (default) | SwiftUI / iOS | Android |
|-------|---------------|---------------|---------|
| Semantics | semantic HTML + ARIA roles | `.accessibilityLabel/Hint/Value`, `.accessibilityAddTraits` | `contentDescription`, roles |
| Live regions | `aria-live` | `.accessibilityAddTraits(.updatesFrequently)` / announcements | `announceForAccessibility` |
| Text scaling | `rem` + browser zoom | **Dynamic Type** (`.font(.body)`, scale with `@ScaledMetric`) | `sp` units + font scale |
| Screen reader | VoiceOver / NVDA / JAWS | VoiceOver | TalkBack |
| Contrast/target | CSS | system + HIG (44pt min touch) | Material (48dp min touch) |

The ARIA/HTML patterns below assume **web**. On native, the *criteria* (label, focus order,
contrast, target size, no colour-only) are identical — only the API changes. Prefer the
platform's native a11y API over re-implementing roles.

## WCAG 2.2 — the new criteria bare agents miss (added since 2.1)

- **2.5.8 Target Size (Minimum)** — interactive targets ≥ **24×24 CSS px** (native: 44pt iOS / 48dp Android).
- **2.5.7 Dragging Movements** — any drag action needs a **single-pointer alternative** (tap/click).
- **2.4.11 Focus Not Obscured** — focused element must not be fully hidden by sticky headers/footers.
- **3.3.8 Accessible Authentication** — **no cognitive-function test** (no puzzles/transcription); **allow paste** into password/OTP fields; support password managers.
- **3.2.6 Consistent Help** — help mechanisms appear in the same relative order across pages.
- **3.3.7 Redundant Entry** — don't ask for the same info twice in one flow (auto-populate or let the user select).
- _(4.1.1 Parsing was **removed** in 2.2 — no longer assess it.)_

## Questions to ask before designing

- Can this be operated **keyboard-only** (web) / with switch control + VoiceOver (native)?
- What does the screen reader announce for each interactive element?
- Is colour the *only* means of conveying information?
- Are focus states visible, and never obscured by sticky UI?
- Do all images have appropriate alt text / labels (decorative → empty)?
- Are touch/click targets ≥ the minimum, with a non-drag alternative for any drag?
- Does login allow paste and avoid cognitive puzzles?

## Review checklist

- [ ] All interactive elements reachable by keyboard (Tab / Shift+Tab); no keyboard trap
- [ ] Focus order matches visual order; visible focus indicator, not obscured (2.4.11)
- [ ] All images have alt text (decorative: `alt=""`)
- [ ] Colour contrast ≥ 4.5:1 normal text, ≥ 3:1 large text & UI components
- [ ] Colour is never the sole information channel
- [ ] Form inputs have associated labels (not just placeholder); errors reference the field
- [ ] Modal dialogs trap focus while open, return focus on close
- [ ] Interactive targets ≥ 24×24px; drag actions have a single-pointer alternative (2.5.7/2.5.8)
- [ ] Auth flow allows paste, no cognitive test (3.3.8); no redundant re-entry (3.3.7)
- [ ] Prefer semantic HTML / native a11y API over hand-rolled ARIA roles

## Testing reality — automation catches ~30–40% only

Automated scanners (**axe-core**, Lighthouse, `@axe-core/playwright`) catch an estimated
**30–40%** of real WCAG violations. A **manual screen-reader pass** (VoiceOver on macOS/iOS,
NVDA on Windows, TalkBack on Android) before each release is **mandatory**, not optional —
ten minutes catches what no scanner will. Coding-mode commands live in impl.md.

## Standards

- WCAG 2.2 AA — w3.org/TR/WCAG22 (quickref: w3.org/WAI/WCAG22/quickref)
- ARIA Authoring Practices — w3.org/WAI/ARIA/apg
- EN 301 549 / EAA — the EU legal benchmark
