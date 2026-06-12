---
skill: apex-animation
backend: deepseek
version: 1.4.0
last_updated: 2026-06-12
sources:
  - Motion — motion.dev
  - GSAP (100% free since Apr 2025) — gsap.com/docs
  - SwiftUI Animations — developer.apple.com/documentation/swiftui/animations
  - Emil Kowalski design-engineering — animations.dev
staleness_threshold: 30d
description: >
  Coding-mode enforcement for animation — reduced-motion fallback, animate transform/opacity
  only, spring physics, AnimatePresence. Web (Motion/GSAP/CSS) default; native (SwiftUI
  built-in) swaps via § Stack assumptions. Loads when building motion/transitions.
---

# Animation Implementation Rules

## Stack assumptions

Code below is **web** (Motion / GSAP / CSS). On **SwiftUI** use built-in animation
(`withAnimation`, `.animation(_:value:)`, `.spring`/`.bouncy`/`.smooth`, `matchedGeometryEffect`,
`PhaseAnimator`) — never a JS lib; gate motion on `@Environment(\.accessibilityReduceMotion)`.
The reduced-motion + cheap-property + spring rules below are universal.

## NEVER do

- Add animation without a reduced-motion fallback (web `prefers-reduced-motion` / native Reduce Motion)
- Use `transition-duration: 0s` to disable animations — use `0.01ms` to avoid reflow (web)
- Animate `top`/`left`/`width`/`height` — animate `transform` and `opacity` only (web)
- Use GSAP for simple show/hide transitions achievable with CSS or Motion
- Create looping animations with no pause mechanism
- Use hardcoded pixel values in spring animations — use unitless stiffness/damping
- Set a Motion `initial` that differs from server-rendered output — causes a hydration mismatch (web SSR). Match `initial` to what the server renders, or gate the animation behind a mounted flag
- Read `window`/`navigator` at module top level — guard with `typeof window !== "undefined"` (web SSR)
- Use `ease-in` for UI transitions — it delays the start; use `ease-out` or a strong custom curve (`cubic-bezier(0.23, 1, 0.32, 1)`)
- Animate an element in from `scale(0)` — nothing appears from nothing; start at `scale(0.95)` + `opacity: 0`
- Use `@keyframes` for rapidly-retriggered UI (toasts, toggles) — keyframes restart from 0 on interrupt; use CSS transitions / springs, which retarget mid-flight
- (web) Animate via Motion's `x`/`y`/`scale` shorthand under load — they run on the main thread (rAF) and drop frames; use the full transform string: `animate={{ transform: "translateX(100px)" }}`

## ALWAYS do

- Wrap all Motion `animate` values with `useReducedMotion()` (web) / check Reduce Motion (native)
- Use spring physics for component animations, not duration-based easing (web `type:"spring"` / SwiftUI spring presets)
- Use `AnimatePresence` for all mount/unmount animations (web)
- Use `layout` prop (web) / `matchedGeometryEffect` (SwiftUI) for size/position change animations
- Use `layoutId` (web) for shared-element transitions — same element moving across route/layout contexts
- Stagger list/children entrances at **0.05–0.10s** per item (below feels mechanical, above feels sluggish)
- Use `mode="wait"` on `AnimatePresence` for page/route transitions so exit finishes before enter starts
- Apply `will-change-transform` (Tailwind) for GPU-composited animations (web)
- Use `viewport={{ once: true }}` on scroll-reveals — repeating on scroll-out distracts, not informs
- (web) Scale popovers/menus from their trigger: `transform-origin: var(--radix-popover-content-transform-origin)` (Base UI: `var(--transform-origin)`) — **modals are exempt, keep them centered**
- Make exit faster than enter — slow where the user decides, snappy where the system responds
- (web) Prefer `@starting-style` for enter animations over a JS mounted-flag; fall back to the `data-mounted` pattern only where browser support is missing

## Motion enter/exit pattern

```tsx
import { motion, AnimatePresence, useReducedMotion } from "motion/react"

function Modal({ open, children }: { open: boolean; children: React.ReactNode }) {
  const reduced = useReducedMotion()
  return (
    <AnimatePresence>
      {open && (
        <motion.div
          initial={{ opacity: 0, scale: reduced ? 1 : 0.95 }}
          animate={{ opacity: 1, scale: 1 }}
          exit={{ opacity: 0, scale: reduced ? 1 : 0.95 }}
          transition={{ type: "spring", stiffness: 300, damping: 30 }}
        >
          {children}
        </motion.div>
      )}
    </AnimatePresence>
  )
}
```

## CSS prefers-reduced-motion global rule

```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    transition-duration: 0.01ms !important;
  }
}
```

## GSAP scroll-linked pattern

```typescript
import gsap from "gsap"
import { ScrollTrigger } from "gsap/ScrollTrigger"
gsap.registerPlugin(ScrollTrigger)

if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
  gsap.from(".hero-text", {
    opacity: 0,
    y: 40,
    duration: 0.6,
    scrollTrigger: { trigger: ".hero", start: "top 80%" },
  })
}
```

## Modern CSS motion primitives

Prefer these over JS where supported — they run off the main thread and need no library.

### Enter animation with @starting-style (no mounted-flag JS)

```css
.toast {
  opacity: 1;
  transform: translateY(0);
  transition: opacity 400ms ease, transform 400ms ease;
  @starting-style { opacity: 0; transform: translateY(100%); }
}
```

Replaces the `useEffect(() => setMounted(true), [])` + `data-mounted` pattern. Fall back to the
mounted-flag only where browser support is missing.

### WAAPI for programmatic animation (JS control, CSS performance)

```js
element.animate(
  [{ clipPath: "inset(0 0 100% 0)" }, { clipPath: "inset(0 0 0 0)" }],
  { duration: 1000, fill: "forwards", easing: "cubic-bezier(0.77,0,0.175,1)" }
)
```

Hardware-accelerated and interruptible without a motion library. Use for dynamic, one-off
programmatic animation; keep declarative CSS transitions for predetermined UI.

> `clip-path` reveal / animated-tabs / hold-to-delete / comparison-slider recipes: read
> `references/clip-path-cookbook.md` when the task needs a masked reveal or progress-fill effect.

## Verification checklist

- [ ] Toggle OS reduced motion — animations must stop or minimise (all surfaces)
- [ ] Check: all animated properties are `transform` or `opacity` (no layout properties) (web)
- [ ] Check: no looping animations without a pause control
- [ ] (web) Check: no `ease-in` on UI transitions; no entrance from `scale(0)`
- [ ] (web) Check: popovers/menus scale from trigger origin (modals stay centered)
- [ ] Check: `AnimatePresence` wraps every conditionally-rendered animated element (web)
- [ ] (web) Run Lighthouse — no CLS caused by animated layout shifts

## Flag for planning-mode review

- Complex SVG morphing needed — GSAP MorphSVG vs Motion; flag the choice
- Page transition between routes — confirm Next.js View Transitions API compatibility
- Marketing scroll story needs scroll-sync precision — GSAP ScrollTrigger vs Motion scroll APIs
