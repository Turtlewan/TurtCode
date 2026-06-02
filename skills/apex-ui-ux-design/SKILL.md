---
skill: apex-ui-ux-design
backend: claude
version: 1.2.0
last_updated: 2026-06-02
sources:
  - Apple HIG + Liquid Glass (WWDC25) — developer.apple.com/design/human-interface-guidelines
  - Vercel Web Design Guidelines — github.com/vercel-labs/agent-skills
  - UI UX Pro Max (nextlevelbuilder) — github.com/nextlevelbuilder/ui-ux-pro-max-skill
  - Web Quality Skills (addyosmani) — github.com/addyosmani/web-quality-skills
  - UX/UI 2026 trend surveys — uxpin / envato / uxdesign.cc
staleness_threshold: 30d
description: >
  Use when designing screens, flows, or visual identity — new screens, redesigns,
  onboarding, forms, dashboards, empty/loading/error states, interaction & motion
  intent, information density, dark mode. Triggers: "design this screen", "UX for X",
  "what should this look like", "is this UI good", a UI spec review before coding.
  Principles are surface-neutral; web (Tailwind/CSS) is the default, native
  (SwiftUI / Liquid Glass) swaps via § Stack assumptions. Not the design-token/component
  system itself (apex-design-system), animation mechanics (apex-animation), or pure
  accessibility audit (apex-accessibility).
---

# UI/UX Design Specialist — Planning Mode

## When to activate
Any spec involving new screens, redesigns, user flows, onboarding, forms, dashboards, or
visual identity — on any surface (web, iOS/macOS, Android).

## Stack assumptions

| Concern | Web (default) | SwiftUI / Apple native |
|---------|---------------|------------------------|
| Layout | CSS/Tailwind, px breakpoints (375/768/1024/1440) | size classes + `@Environment` adaptivity; no px breakpoints |
| Pointer affordance | `cursor-pointer`, `:hover` | **no cursor**; `:hover` only on iPad pointer/`.hoverEffect`; design for touch |
| Icons | SVG (Lucide / Heroicons) | **SF Symbols** (`Image(systemName:)`) |
| Material / chrome | flat surfaces, shadows, `backdrop-blur` | **Liquid Glass** (`glassEffect`, floating toolbars) — iOS/macOS 26+ |
| Focus ring | `focus-visible:ring-2` | system focus engine (tvOS/keyboard) — don't hand-roll |
| Text scaling | `rem` + zoom | **Dynamic Type** |
| Deep-link state | URL params | `NavigationPath` / app routing |

The web rules below (cursor, ring classes, px breakpoints, URL state) are **web-only** — on
native, the *intent* (clear affordance, visible focus, adaptive layout, shareable state)
holds but the mechanism changes. Prefer the platform's native components over re-creating them.

## What's current (2026) — design to these, not to 2022 defaults

- **Calm UI / clarity over novelty.** Reduce cognitive load; the "visual theatrics" era is
  over. A bold interaction means nothing if the user can't complete the task.
- **AI-native / conversational UX is a primary paradigm**, not a novelty chatbot — natural
  language now drives real workflows. For assistant-style products, design the conversation
  as a first-class surface (streaming responses, visible tool/agent actions, transparent AI
  state — show what the system is doing and why).
- **Motion is structure, not decoration** — it should explain *what just happened / is
  happening / will happen next*. Decorative-only motion is a flag (→ apex-animation).
- **Tokens are governance, not docs** — visual decisions resolve to design tokens enforced
  across surfaces (→ apex-design-system), including AI-generated UI.
- **Accessibility is inclusive design, beyond WCAG checkboxes** — neurodivergence, literacy,
  situational impairments. Pair with apex-accessibility (WCAG 2.2 AA is the floor, not ceiling).

## Questions to ask before designing

- What product category is this? (SaaS, fintech, healthcare, e-commerce, creative tool, assistant…)
- What surface(s)? (web, iOS/macOS, Android, multi-surface)
- Who is the primary user? (B2B professional, consumer, developer, internal team)
- What is the emotional tone? (trustworthy, energetic, minimal, bold)
- What existing design system / component library / platform conventions apply?
- Are there brand colours, typography, or motion constraints?

## Industry-specific design reasoning

Match the product category to the right design language before generating UI:

| Category | Default style | Avoid |
|----------|--------------|-------|
| SaaS / B2B | Clean, data-dense, professional | Decorative animations, low-density layouts |
| Developer tools | Minimal, high information density, dark mode | Rounded bubble UI, marketing aesthetics |
| Consumer / lifestyle | Warm, inviting, generous whitespace | Cold enterprise grids |
| Fintech / banking | Trust signals, conservative, clear hierarchy | Playful animations, low contrast |
| Healthcare | Calm, accessible, high contrast | Busy layouts, small text |
| AI / assistant | Conversational, transparent AI state, minimal chrome | Feature overload, hidden agent actions |

## Pre-delivery quality checklist

Before any UI spec is marked ready:
- [ ] No emoji as icons — SVG (web: Lucide/Heroicons) or SF Symbols (native)
- [ ] Clear pointer affordance on clickable elements (web: `cursor-pointer`; native: standard controls)
- [ ] Hover/press transitions 150–300ms (web `:hover`; native press states — hover only where a pointer exists)
- [ ] Text contrast ≥ 4.5:1 (light), ≥ 3:1 (dark / large text & UI)
- [ ] Visible focus states for keyboard/switch navigation
- [ ] `prefers-reduced-motion` (web) / Reduce Motion (native) respected — no mandatory animations
- [ ] Adaptive across the target surfaces (web: 375/768/1024/1440; native: size classes)
- [ ] Loading states defined for all async UI
- [ ] Empty states defined (no blank screens) — message + CTA
- [ ] Error states defined (inline, not just toasts)

## Generic-AI ("slop") detection — reject these before shipping a UI spec

LLM-generated UI converges on a recognisable generic look. Treat any of these as a FLAG to
redesign with product-specific intent (see § Industry-specific design reasoning):

- Gratuitous gradients on everything; the purple→blue default palette
- Glassmorphism / blur cards used decoratively with no depth purpose
- Generic centred hero: oversized heading + vague copy over a stock/atmospheric gradient
- Uniform `grid-cols-3` / `grid-cols-4` card walls where the content isn't actually uniform
- Filler CTA copy ("Get Started", "Learn more") instead of action-specific labels
- Default font stack with no personality (plain `font-sans` / Inter everywhere)
- Cards nested inside cards; rounded corners on things that shouldn't be rounded
- The UI describing its own features in prose when the controls already speak for themselves

The fix is always the same: pick an explicit direction (purpose / audience / tone / one
memorable detail / constraints) and design to the product domain, not the template.

## Scored visual audit (review mode — "is this UI good?")

When asked to review/audit an existing UI, score each dimension **0–10** and give a specific
fix at `file:line` (not vague praise). Lead with the lowest scores.

| # | Dimension | Looks for |
|---|-----------|-----------|
| 1 | Colour consistency | palette tokens used, not random hex |
| 2 | Typography hierarchy | clear h1>h2>h3>body>caption |
| 3 | Spacing rhythm | consistent 4/8/16 scale, not arbitrary |
| 4 | Component consistency | similar elements look similar |
| 5 | Responsive behaviour | fluid, not broken at breakpoints |
| 6 | Dark mode | complete, not half-done |
| 7 | Motion | purposeful, not gratuitous (→ apex-animation) |
| 8 | Accessibility | contrast, focus, touch targets (→ apex-accessibility) |
| 9 | Information density | matched to product category, not cluttered/sparse |
| 10 | Polish | hover/focus/active, loading, empty, micro-details (concentric radius, tabular-nums, optical alignment) |

Report shape: per-dimension score + one concrete fix each; then the 3 highest-impact fixes.

## Interaction design rules

- **Animation**: 150–300ms micro-interactions, 300–500ms transitions; motion communicates state change
- **Touch targets**: ≥ 44×44pt (iOS) / 48dp (Android) / 24×24px min (web, WCAG 2.2 §2.5.8)
- **Form validation**: inline, real-time — not on submit only
- **State persistence**: web → reflect filter/search in URL (shareable); native → app navigation state
- **Dark mode**: required if the product offers it — test both
- **Internationalisation**: avoid hardcoded widths that break with longer/translated text

## Escalation rules

BLOCK (halt spec):
- Colour contrast below 4.5:1 for body text
- No keyboard/switch navigation defined for interactive elements
- Animations with no reduced-motion fallback

FLAG (note in spec):
- Layout untested at smallest target (web 375px / native compact size class)
- Missing empty or error state definition
- Icon-only buttons without accessible label
- Decorative-only motion → apex-animation for necessity check
- Undefined dark-mode / design tokens → apex-design-system
