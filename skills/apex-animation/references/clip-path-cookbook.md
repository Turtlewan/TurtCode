# clip-path animation cookbook

Load when a task needs a masked reveal, progress-fill, or comparison effect. `clip-path` is
GPU-composited and adds no DOM. All recipes animate `clip-path` (transform/opacity-class — cheap).
Source: Emil Kowalski design-engineering (animations.dev).

## The inset primitive

`clip-path: inset(top right bottom left)` — each value eats into the element from that side.

```css
.hidden  { clip-path: inset(0 100% 0 0); }   /* fully hidden from the right */
.visible { clip-path: inset(0 0 0 0); }       /* fully shown */
```

## Reveal left-to-right

```css
.overlay { clip-path: inset(0 100% 0 0); transition: clip-path 200ms ease-out; }
.trigger:hover .overlay { clip-path: inset(0 0 0 0); }
```

## Animated tabs with seamless colour transition

Duplicate the tab list; style the copy as "active" (different bg + text colour); clip the copy so
only the active tab shows; animate the clip on change. Beats timing per-tab colour transitions.

## Hold-to-delete (asymmetric timing)

```css
.fill { clip-path: inset(0 100% 0 0); }
.btn:active .fill { clip-path: inset(0 0 0 0); transition: clip-path 2s linear; }   /* deliberate */
.fill { transition: clip-path 200ms ease-out; }                                     /* snappy release */
```

Pair with `transform: scale(0.97)` on `:active` for press feedback. Slow where the user decides,
fast where the system responds.

## Image reveal on scroll

Start `clip-path: inset(0 0 100% 0)` (hidden from bottom) → animate to `inset(0 0 0 0)` on enter.
Use `IntersectionObserver` or Motion `useInView({ once: true, margin: "-100px" })`. Respect
`prefers-reduced-motion` — drop the movement, keep opacity.

## Comparison slider

Overlay two images; clip the top one `clip-path: inset(0 50% 0 0)`; adjust the right inset from drag
position. No extra DOM, fully hardware-accelerated.
