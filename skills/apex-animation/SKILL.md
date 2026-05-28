---
skill: apex-animation
backend: claude
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Motion (motiondivision) — github.com/motiondivision/motion
  - GSAP — github.com/greensock/gsap
  - MagicUI — github.com/magicuidesign/magicui
  - Vercel React View Transitions — github.com/vercel-labs/agent-skills
staleness_threshold: 30d
---

# Animation Specialist — Planning Mode

## When to activate
Any spec involving transitions, motion, scroll effects, entrance/exit animations, gestures, or page transitions.

## Library selection

| Use case | Library | Why |
|----------|---------|-----|
| React component animations | Motion (`motion/react`) | Spring physics, gestures, layout, AnimatePresence |
| Complex SVG / path animations | GSAP | MorphSVG, MotionPath, ScrollTrigger precision |
| Marketing / scroll storytelling | GSAP ScrollTrigger | Industry standard for scroll-linked effects |
| Scroll-linked in React | Motion scroll APIs | Native integration, no extra dep |
| Page transitions (Next.js) | React View Transitions API | Native browser API, zero JS overhead |
| Copy-paste animated components | MagicUI | Pre-built, production-ready, MIT licensed |

## Motion (Framer Motion) patterns

```javascript
import { motion, AnimatePresence } from "motion/react"

// Entrance/exit
<AnimatePresence>
  {show && <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} />}
</AnimatePresence>

// Spring physics (preferred over duration-based)
<motion.div animate={{ x: 100 }} transition={{ type: "spring", stiffness: 300, damping: 30 }} />

// Layout animations
<motion.div layout />  // auto-animates size/position changes
```

## GSAP patterns

```javascript
import gsap from "gsap"
import { ScrollTrigger } from "gsap/ScrollTrigger"

// Timeline sequence
const tl = gsap.timeline()
tl.to(".hero", { opacity: 1, y: 0, duration: 0.6 })
  .to(".subtitle", { opacity: 1, y: 0, duration: 0.4 }, "-=0.2")

// Scroll-linked
gsap.to(".panel", {
  xPercent: -100 * (panels.length - 1),
  scrollTrigger: { trigger: ".container", pin: true, scrub: 1 }
})
```

GSAP is free including all plugins for personal and commercial use.

## Accessibility rules (non-negotiable)

- **Always** wrap animations in `prefers-reduced-motion` check
- Motion must add meaning — not decoration for its own sake
- No looping animations that cannot be paused

```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation-duration: 0.01ms !important; transition-duration: 0.01ms !important; }
}
```

In Motion: `useReducedMotion()` hook returns `true` when user prefers reduced motion — use it.

## Timing guidelines

| Interaction | Duration | Easing |
|-------------|----------|--------|
| Micro (hover, focus) | 150–200ms | ease-out |
| Component (modal, drawer) | 250–350ms | spring or ease-in-out |
| Page transition | 300–500ms | ease-in-out |
| Scroll storytelling | scrub-based | linear (ScrollTrigger) |

## Escalation rules

BLOCK:
- Animation with no `prefers-reduced-motion` fallback
- Looping animation with no pause mechanism

FLAG:
- GSAP used for simple CSS-achievable transitions (overkill)
- Motion used for SVG morphing (GSAP MorphSVG is better)
