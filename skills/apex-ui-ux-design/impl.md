---
skill: apex-ui-ux-design
backend: coding
version: 1.4.0
last_updated: 2026-06-10
sources:
  - Apple HIG + Liquid Glass (WWDC25) — developer.apple.com/design/human-interface-guidelines
  - Vercel Design Guidelines — vercel.com/design
  - WCAG 2.2 — w3.org/TR/WCAG22
  - design-taste-frontend (taste-skill) — github.com/Leonxlnx/taste-skill
staleness_threshold: 30d
description: >
  Coding-mode enforcement for UI/UX quality — interactive states, empty/loading/error
  states, inline validation, pointer/focus affordance, reduced-motion. Web (React/Tailwind)
  is the default; native (SwiftUI) swaps via § Stack assumptions. Loads when building any
  user-facing screen or component.
---

# UI/UX Design Implementation Rules

## Stack assumptions

Code below is **web (React + Tailwind)**. On **SwiftUI** the *intent* holds but the
mechanism changes: use standard controls (`Button`, `List`, `Form`) — they give press/focus
states free; **SF Symbols** not Lucide/Heroicons; **Liquid Glass** (`glassEffect`) for
chrome on iOS/macOS 26+; **Dynamic Type** not `rem`; `ContentUnavailableView` for empty
states; `@Environment(\.accessibilityReduceMotion)` for reduced motion. No `cursor-pointer`,
no `:hover`, no px breakpoints on native.

## NEVER do

- Use emoji as icons — use SVG (web: Lucide / Heroicons) or SF Symbols (native)
- Validate forms only on submit — validate inline and in real-time
- Hardcode widths that break with translated or longer text
- Leave empty states as blank screens — always provide a message and CTA
- Leave error states unhandled — always show a user-facing message
- (web) Omit `cursor-pointer` from clickable non-button elements (div, li, card)
- (web) Use `h-screen` for full-height/hero sections — use `min-h-[100dvh]` (iOS Safari toolbar collapse → layout jump)
- Ship template placeholder content — "John Doe", egg avatars, round fake numbers (`99.99%`/`50%`), "Acme"/"Nexus" names, filler verbs ("Elevate"/"Seamless"/"Unleash"); use organic names, believable data, concrete verbs
- (redesign) Silently change URLs/slugs, nav labels, or form field `name` attributes — preserve unless the change is explicitly requested, and flag any change

## ALWAYS do

- Define hover (where a pointer exists), focus, active/press, and disabled states for every interactive component
- Define loading state (skeleton or spinner) for all async content
- Define empty state with a helpful message and a CTA
- (web) Add `cursor-pointer` + `transition-colors duration-150` to interactive elements
- (web) Use `focus-visible:ring-2` (not `focus:ring`) to avoid mouse-click focus rings
- (web) Reflect filter/search state in URL params for shareable links
- (web) Test layout at 375px, 768px, 1024px, 1440px
- (web) `tabular-nums` on any updating/aligned numbers — counters, timers, prices, table figures
- (web) `text-wrap: balance` on headings/short titles; `text-wrap: pretty` on captions/short body (not long prose, code, or `pre`)
- (web) Nested rounded surfaces use **concentric radius**: `outer = inner + padding`

Contrast / touch targets / reduced motion: owned by apex-accessibility — defer.

## Interactive element pattern  (web — React + Tailwind)

```tsx
// Clickable card with cursor, hover, focus, transition
// SwiftUI: use Button { } .buttonStyle(...) — press/focus states are free
<div
  role="button"
  tabIndex={0}
  onClick={handleClick}
  onKeyDown={(e) => e.key === 'Enter' && handleClick()}
  className="cursor-pointer rounded-lg border p-4 transition-colors duration-150 hover:bg-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
>
  {children}
</div>
```

## Inline form validation pattern  (web)

```tsx
const [email, setEmail] = useState('')
const [error, setError] = useState('')

function validate(value: string) {
  if (!value) return 'Email is required'
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) return 'Enter a valid email'
  return ''
}

<input
  value={email}
  onChange={(e) => { setEmail(e.target.value); setError(validate(e.target.value)) }}
  aria-invalid={!!error}
  aria-describedby={error ? 'email-error' : undefined}
/>
{error && <p id="email-error" role="alert" className="text-sm text-red-600">{error}</p>}
```

## Empty and error state pattern  (web)

```tsx
// Empty state  (SwiftUI: ContentUnavailableView)
{items.length === 0 && (
  <div className="flex flex-col items-center gap-3 py-16 text-center">
    <InboxIcon className="h-10 w-10 text-muted-foreground" />
    <p className="text-sm text-muted-foreground">No items yet</p>
    <Button onClick={onAdd}>Add your first item</Button>
  </div>
)}

// Error state
{error && (
  <div role="alert" className="rounded border border-red-200 bg-red-50 p-4 text-sm text-red-700">
    {error.message}
  </div>
)}
```

## Micro-polish details  (web — the small things that compound into "polished")

These are the corrections a bare agent omits. Apply during build, not as a later pass.

- **Concentric radius** — nested rounded surfaces: `outer = inner + padding`. If padding is
  large, treat the layers as separate surfaces instead of forcing the formula (optical
  coherence, not formula worship).
- **Optical alignment** — geometric centring ≠ visual centring. Asymmetric glyphs (play ▶,
  arrows, stars, some icons) need a small offset. Fix the SVG/viewBox when possible; else nudge
  with a 1px margin/padding.
- **Tabular numbers** — `font-variant-numeric: tabular-nums` (Tailwind `tabular-nums`) on
  counters, timers, prices, and table figures so digits don't jitter as they update.
- **Text wrapping** — `text-wrap: balance` on headings/short titles; `text-wrap: pretty` on
  captions/short-to-medium body. Use **neither** on long prose, code, or `pre`.
- **Font smoothing** — on macOS targets, set at the root if the project doesn't already:
  `html { -webkit-font-smoothing: antialiased; -moz-osx-font-smoothing: grayscale; }`
- **Image edges** — give images a subtle inset outline so edges don't blur into the surface:
  `img { outline: 1px solid rgb(0 0 0 / 0.1); outline-offset: -1px; }` (lighten in dark mode).

```css
/* polish primitives — drop into the base layer */
.tabnums { font-variant-numeric: tabular-nums; }
h1, h2, h3 { text-wrap: balance; }
p.caption, li { text-wrap: pretty; }
```

> SwiftUI: tabular figures via `.monospacedDigit()`; optical alignment via `Image` baseline
> offset / `alignmentGuide`; no font-smoothing or image-outline equivalents needed.

## Verification checklist

- [ ] Check: no emoji icons — SVG / SF Symbols only
- [ ] (web) Check: updating numbers use `tabular-nums`; headings use `text-wrap: balance`
- [ ] (web) Check: nested rounded surfaces follow concentric radius
- [ ] Check: all interactive elements have visible focus state (keyboard/switch test)
- [ ] Check: empty state and error state defined for all dynamic content
- [ ] (web) Check: clickable elements have `cursor-pointer`; test at 375px — no horizontal scroll
- [ ] (web) Check: no `h-screen` on full-height sections — `min-h-[100dvh]` used
- [ ] Check: no template placeholder content (names/avatars/round numbers/filler verbs)

## Flag for planning-mode review

- Product category ambiguous — ask user before choosing information density and visual tone
- Dark mode / design tokens not defined — flag to apex-design-system
- Animation used for decoration only — flag to apex-animation for necessity check
