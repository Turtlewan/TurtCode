---
skill: apex-ui-ux-design
backend: deepseek
version: 1.1.0
last_updated: 2026-06-01
sources:
  - Apple HIG + Liquid Glass (WWDC25) — developer.apple.com/design/human-interface-guidelines
  - Vercel Design Guidelines — vercel.com/design
  - WCAG 2.2 — w3.org/TR/WCAG22
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
- Use decorative-only motion with no reduced-motion fallback
- (web) Omit `cursor-pointer` from clickable non-button elements (div, li, card)
- (web/mobile) Set touch targets below 44×44pt (iOS) / 48dp (Android) / 24×24px (web)

## ALWAYS do

- Define hover (where a pointer exists), focus, active/press, and disabled states for every interactive component
- Define loading state (skeleton or spinner) for all async content
- Define empty state with a helpful message and a CTA
- Respect reduced-motion (web `prefers-reduced-motion` / native Reduce Motion)
- (web) Add `cursor-pointer` + `transition-colors duration-150` to interactive elements
- (web) Use `focus-visible:ring-2` (not `focus:ring`) to avoid mouse-click focus rings
- (web) Reflect filter/search state in URL params for shareable links
- (web) Test layout at 375px, 768px, 1024px, 1440px

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

## Verification checklist

- [ ] Check: no emoji icons — SVG / SF Symbols only
- [ ] Check: all interactive elements have visible focus state (keyboard/switch test)
- [ ] Check: contrast ratio ≥ 4.5:1 (devtools / Polypane / native colour check)
- [ ] Check: empty state and error state defined for all dynamic content
- [ ] (web) Check: clickable elements have `cursor-pointer`; test at 375px — no horizontal scroll
- [ ] Check: reduced-motion fallback present for any animation

## Flag for planning-mode review

- Product category ambiguous — ask user before choosing information density and visual tone
- Dark mode / design tokens not defined — flag to apex-design-system
- Animation used for decoration only — flag to apex-animation for necessity check
