---
skill: apex-animation
backend: claude
version: 1.3.0
last_updated: 2026-06-10
sources:
  - Motion — motion.dev
  - GSAP (now 100% free) — gsap.com
  - SwiftUI Animations — developer.apple.com/documentation/swiftui/animations
  - MagicUI — github.com/magicuidesign/magicui
  - Vercel React View Transitions — github.com/vercel-labs/agent-skills
  - Emil Kowalski design-engineering — animations.dev
staleness_threshold: 30d
description: >
  Use when adding motion — transitions, entrance/exit, scroll effects, gestures, page
  transitions, micro-interactions. Triggers: "animate this", "add a transition", "scroll
  animation", "page transition", "make it feel smooth". Motion principles (reduced-motion,
  meaningful motion, spring physics, animate transform/opacity) are surface-neutral; web
  (Motion / GSAP) is the default, native (SwiftUI) swaps via § Stack assumptions. Not the
  design-token system (apex-design-system) or screen-level UX (apex-ui-ux-design).
---

# Animation Specialist — Planning Mode

## When to activate
Any spec involving transitions, motion, scroll effects, entrance/exit animations, gestures, or page transitions — on any surface.

## Stack assumptions

| Concern | Web (default) | SwiftUI / native |
|---------|---------------|------------------|
| Library | Motion (`motion/react`) / GSAP / CSS | built-in — no dependency |
| Trigger | `animate` props / GSAP timelines | `withAnimation {}` / `.animation(_:value:)` |
| Spring | `type: "spring"` (stiffness/damping) | `.spring`, `.bouncy`, `.smooth`, `.snappy` presets (iOS 17+) |
| Shared element | Motion `layout` / View Transitions | `matchedGeometryEffect` |
| Sequence / scroll | GSAP timeline / ScrollTrigger | `PhaseAnimator` / `KeyframeAnimator` (iOS 17+); `ScrollView` `.scrollTransition` |
| Reduced motion | `prefers-reduced-motion` / `useReducedMotion()` | `@Environment(\.accessibilityReduceMotion)` |

The libraries below are **web**. The *principles* (animate cheap properties, springs over
fixed durations, respect reduced-motion, motion must mean something) are universal — on
native, SwiftUI provides them built-in; never reach for a JS animation lib on an Apple surface.

## Library selection  (web)

| Use case | Library | Why |
|----------|---------|-----|
| React component animations | Motion (`motion/react`) | Spring physics, gestures, layout, AnimatePresence |
| Complex SVG / path animations | GSAP | MorphSVG, MotionPath, ScrollTrigger precision |
| Marketing / scroll storytelling | GSAP ScrollTrigger | Industry standard for scroll-linked effects |
| Scroll-linked in React | Motion scroll APIs | Native integration, no extra dep |
| Page transitions (Next.js) | React View Transitions API | Native browser API, zero JS overhead |
| Copy-paste animated components | MagicUI | Pre-built, production-ready, MIT licensed |

## GSAP licensing

**GSAP is 100% free** (since 30 Apr 2025, after the Webflow acquisition) — including all
formerly-paid Club plugins (SplitText, MorphSVG, DrawSVG, etc.) for personal and commercial
use. SplitText was rewritten ~50% smaller. No licence gate to consider any more.

## Accessibility rules (non-negotiable)

- **Always** wrap animations in `prefers-reduced-motion` check
- Motion must add meaning — not decoration for its own sake
- No looping animations that cannot be paused
- Reduced motion means *fewer and gentler*, not none — keep opacity/colour transitions that aid
  comprehension; remove movement, position, and scale. (The impl global kill-all is the safe
  floor; prefer per-component reduced variants where feasible.)

Ownership: apex-animation owns the reduced-motion *implementation* (the global CSS kill-switch
lives in impl.md); apex-accessibility owns the requirement.

In Motion: `useReducedMotion()` hook returns `true` when user prefers reduced motion — use it.
In SwiftUI: read `@Environment(\.accessibilityReduceMotion)` and drop/shorten the animation.

## Should it animate at all? (decide before "how")

Motion budget is a function of frequency — decide by how often the user sees it:

| Frequency | Decision |
|-----------|----------|
| 100+×/day (keyboard shortcuts, command palette) | No animation, ever |
| Tens×/day (hover, list nav) | Remove or drastically reduce |
| Occasional (modals, drawers, toasts) | Standard animation |
| Rare / first-time (onboarding, celebration) | Can add delight |

**Never animate keyboard-initiated actions** — they repeat hundreds of times/day; motion makes
them feel laggy (Raycast's command palette has no open/close animation by design).

## Timing guidelines

| Interaction | Duration | Easing |
|-------------|----------|--------|
| Micro (hover, focus) | 150–200ms | ease-out |
| Component (modal, drawer) | 250–350ms | spring or ease-in-out |
| Page transition | 300–500ms | ease-in-out |
| Scroll storytelling | scrub-based | linear (ScrollTrigger) |

**Never use `ease-in` for UI** — it delays the start, exactly where the eye is watching, so it
feels slower than `ease-out` at the same duration. Built-in curves are weak; prefer a strong
custom curve, e.g. `--ease-out: cubic-bezier(0.23, 1, 0.32, 1)`.

## Escalation rules

BLOCK:
- Animation with no `prefers-reduced-motion` fallback
- Looping animation with no pause mechanism

FLAG:
- GSAP used for simple CSS-achievable transitions (overkill)
- Motion used for SVG morphing (GSAP MorphSVG is better)
