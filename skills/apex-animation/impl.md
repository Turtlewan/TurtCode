---
skill: apex-animation
backend: deepseek
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Motion — motion.dev
  - GSAP — gsap.com/docs
staleness_threshold: 30d
---

# Animation Implementation Rules

## NEVER do

- Add animation without a `prefers-reduced-motion` fallback
- Use `transition-duration: 0s` to disable animations — use `0.01ms` to avoid reflow
- Animate `top`/`left`/`width`/`height` — animate `transform` and `opacity` only
- Use GSAP for simple show/hide transitions achievable with CSS or Motion
- Create looping animations with no pause mechanism
- Use hardcoded pixel values in spring animations — use unitless stiffness/damping

## ALWAYS do

- Wrap all Motion `animate` values with `useReducedMotion()` check
- Use spring physics (`type: "spring"`) for component animations, not duration-based easing
- Use `AnimatePresence` for all mount/unmount animations
- Use `layout` prop for size/position change animations
- Apply `will-change-transform` (Tailwind) for GPU-composited animations

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

## Verification checklist

- [ ] Toggle OS reduced motion — animations must stop or minimise
- [ ] Check: all animated properties are `transform` or `opacity` (no layout properties)
- [ ] Check: no looping animations without a pause control
- [ ] Check: `AnimatePresence` wraps every conditionally-rendered animated element
- [ ] Run: Lighthouse performance — no CLS caused by animated layout shifts

## Flag for planning-mode review

- Complex SVG morphing needed — GSAP MorphSVG vs Motion; flag the choice
- Page transition between routes — confirm Next.js View Transitions API compatibility
- Marketing scroll story needs scroll-sync precision — GSAP ScrollTrigger vs Motion scroll APIs
