---
skill: apex-ui-ux-design
backend: deepseek
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Vercel Design Guidelines — vercel.com/design
  - WCAG 2.2 — w3.org/TR/WCAG22
staleness_threshold: 30d
---

# UI/UX Design Implementation Rules

## NEVER do

- Use emoji as icons — use SVG (Lucide / Heroicons)
- Omit `cursor-pointer` from clickable non-button elements (div, li, card)
- Set touch targets below 44×44px on mobile
- Validate forms only on submit — validate inline and in real-time
- Hardcode widths that break with translated or longer text
- Leave empty states as blank screens — always provide a message and CTA
- Leave error states unhandled — always show a user-facing message

## ALWAYS do

- Add `cursor-pointer` and `transition-colors duration-150` to all interactive elements
- Define hover, focus, active, and disabled states for every interactive component
- Use `focus-visible:ring-2` (not `focus:ring`) to avoid mouse-click focus rings
- Define loading state (skeleton or spinner) for all async content
- Define empty state with helpful message and a CTA
- Reflect filter/search state in URL params for shareable links
- Test layout at 375px, 768px, 1024px, 1440px

## Interactive element pattern

```tsx
// Clickable card with cursor, hover, focus, transition
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

## Inline form validation pattern

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

## Empty and error state pattern

```tsx
// Empty state
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

- [ ] Check: no emoji icons in UI — SVG icons only
- [ ] Check: all clickable elements have `cursor-pointer`
- [ ] Check: all interactive elements have visible focus ring (keyboard test)
- [ ] Check: contrast ratio ≥ 4.5:1 (use browser devtools or Polypane)
- [ ] Check: empty state and error state defined for all dynamic content
- [ ] Test at 375px — no horizontal scroll, no truncated text

## Flag for planning-mode review

- Product category ambiguous — ask user before choosing information density and visual tone
- Dark mode required but tokens not defined — flag to apex-design-system
- Animation used for decoration only — flag to apex-animation for necessity check
