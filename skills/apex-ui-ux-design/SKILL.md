---
skill: apex-ui-ux-design
backend: claude
version: 1.0.0
last_updated: 2026-05-28
sources:
  - UI UX Pro Max (nextlevelbuilder) — github.com/nextlevelbuilder/ui-ux-pro-max-skill
  - Vercel Web Design Guidelines — github.com/vercel-labs/agent-skills
  - Web Quality Skills (addyosmani) — github.com/addyosmani/web-quality-skills
staleness_threshold: 30d
---

# UI/UX Design Specialist — Planning Mode

## When to activate
Any spec involving new screens, redesigns, user flows, onboarding, forms, dashboards, or visual identity decisions.

## Questions to ask before designing

- What product category is this? (SaaS, fintech, healthcare, e-commerce, creative tool...)
- Who is the primary user? (B2B professional, consumer, developer, internal team)
- What is the emotional tone? (trustworthy, energetic, minimal, bold)
- What existing design system or component library is in use?
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
| AI / chatbot | Conversational, minimal chrome | Feature overload |

## Pre-delivery quality checklist

Before any UI spec is marked ready:
- [ ] No emoji used as icons — use SVG (Heroicons / Lucide)
- [ ] `cursor-pointer` on all clickable elements
- [ ] Hover states with smooth transitions (150–300ms)
- [ ] Text contrast ≥ 4.5:1 (light mode), ≥ 3:1 (dark mode)
- [ ] Visible focus states for keyboard navigation
- [ ] `prefers-reduced-motion` respected — no mandatory animations
- [ ] Responsive at 375px, 768px, 1024px, 1440px breakpoints
- [ ] Loading states defined for all async UI
- [ ] Empty states defined (no blank screens)
- [ ] Error states defined (inline, not just toasts)

## Interaction design rules (Vercel guidelines)

- **Animation**: 150–300ms for micro-interactions, 300–500ms for page transitions
- **Touch targets**: minimum 44×44px on mobile
- **Form validation**: inline, real-time — not on submit only
- **URL state**: filter/search state reflected in URL (shareable)
- **Dark mode**: required if product has a dark option — test both
- **Internationalisation**: avoid hardcoded widths that break with longer text

## Escalation rules

BLOCK (halt spec):
- Colour contrast below 4.5:1 for body text
- No keyboard navigation defined for interactive elements
- Animations with no `prefers-reduced-motion` fallback

FLAG (note in spec):
- Layout untested at 375px (mobile)
- Missing empty or error state definition
- Icon-only buttons without aria-label
