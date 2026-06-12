---
skill: apex-ui-ux-design
backend: claude
version: 1.6.0
last_updated: 2026-06-12
sources:
  - Apple HIG + Liquid Glass (WWDC25) — developer.apple.com/design/human-interface-guidelines
  - docs/technical/adr/ADR-013-app-flow-artifact.md
  - docs/technical/adr/ADR-017-design-brief-artifact.md
  - docs/research/design-capability/ (WS-1…4, 2026-06-12)
  - Vercel Web Design Guidelines — github.com/vercel-labs/agent-skills
  - UI UX Pro Max (nextlevelbuilder) — github.com/nextlevelbuilder/ui-ux-pro-max-skill
  - Web Quality Skills (addyosmani) — github.com/addyosmani/web-quality-skills
  - UX/UI 2026 trend surveys — uxpin / envato / uxdesign.cc
  - design-taste-frontend (taste-skill) — github.com/Leonxlnx/taste-skill
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

## App-flow artifact (persisted — ADR-013)

For any UI-bearing project the screen-map and user journeys are a **persisted artifact**, not
session-only judgment: `docs/technical/architecture/app-flow.md` (seeded by apex-init, owned here).
This skill owns the *technique*; apex-docs-technical owns the doc's place in the doc system.

- **Capture early** — before per-screen feature specs, map: **screens/routes** (name · purpose · how
  reached), **primary user journeys** (key end-to-end paths), and **screen states + transitions**
  (empty / loading / error / loaded). Keep it flow-level.
- **Flow only, not visual design.** Layout, spacing, colour, component styling, and taste stay
  un-persisted planning judgment (+ Figma). Do not turn app-flow.md into a visual spec — that boundary
  is what keeps it Low-cost and stable.
- **Keep it current** — a new screen or journey updates app-flow.md; a UI feature spec should name
  which app-flow screen(s)/journey it implements (apex-plan's readiness gate checks this for UI specs).
- **Scope-gate** — headless / API-only / pure-CLI projects have no app-flow doc.

## Design-brief artifact (persisted — ADR-017)

For any UI-bearing project, a small per-project **design brief** is a persisted artifact the
*coding* model reads: `docs/technical/architecture/design-brief.md` (seeded by apex-init, owned
here). It exists because the coding backend is image-less and literal — anything it must honour
visually has to be explicit text in its context, not planning-side judgment it cannot see.

**Scope (ADR-017 — partially amends ADR-013's "visual stays un-persisted").** Persist only the
*stable, single-homed* visual decisions:
- **Tokens** — exact values: colour, type family + scale, spacing scale, radii, shadow. The coder
  references these by name, never inventing per-component values.
- **Art direction** — 2–4 sentences: mood, references, and *what it must NOT feel like*. This also
  records the **chosen feel → which style-library style to install** (§ Style selection).
- **Forbidden patterns** — the project-specific don'ts ("no purple-on-white gradients, no nested
  cards, no Inter"). Highest-evidence lever for steering a literal coder — don'ts pull more weight
  than do's.

**Stays OUT** (un-persisted judgment, per ADR-013): per-screen layouts and component visuals — they
live as planning judgment, verified by the § Visual review gate, never frozen in a doc that rots.
Screens/journeys are app-flow.md's job; do not duplicate them here.

- **Scope-gate** — headless / API-only / CLI projects have no design brief.
- apex-plan's readiness gate checks a UI spec references brief tokens; apex-code loads the brief as
  build context. Template: `~/.claude/skills/apex-ui-ux-design/references/design-brief-template.md`.

## Style selection (style library)

Fixed-aesthetic "style/taste" skills are **not** auto-loaded (they collide and tax compliance —
[[design-style-on-demand]]). They live shelved in `~/.claude/style-library/` (see its `INDEX.md`).
Establish the *feel* first via the design brief's art-direction, then:

1. Read `~/.claude/style-library/INDEX.md`; match the brief's feel to **at most one** style.
2. Propose it; on user confirmation install that one into `~/.claude/skills/` (INDEX gives the
   command). **Never install more than one** — that re-creates the collision the shelf prevents.
3. If none fits, the brief's tokens + art-direction + forbidden-patterns stand alone. Shelve the
   style again when the project is done.

When a library style's rule conflicts with this skill's slop detection, **the APEX rule wins.**

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
- Does the target platform have an *official* design system (GOV.UK, IBM Carbon, Microsoft
  Fluent, GitHub Primer, Shopify Polaris)? If so, install and use the official package — don't
  reinvent it.

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
- [ ] Visible focus states for keyboard/switch navigation
- [ ] Adaptive across the target surfaces (web: 375/768/1024/1440; native: size classes)
- [ ] Loading states defined for all async UI
- [ ] Empty states defined (no blank screens) — message + CTA
- [ ] Error states defined (inline, not just toasts)
- [ ] Full-height/hero sections use `min-h-[100dvh]`, never `h-screen` (iOS Safari toolbar collapse causes a layout jump)

Contrast / touch targets / reduced motion: owned by apex-accessibility — defer.

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
- Template placeholder content: "John Doe" names, generic egg/Lucide-user avatars, round fake
  numbers (`99.99%`, `50%`), "Acme"/"Nexus" brand names, filler verbs ("Elevate", "Seamless",
  "Unleash", "Next-Gen"). Use organic names, believable data (`47.2%`), concrete verbs.
- Em-dashes in UI copy as a writing tell — prefer commas/parentheses/restructured sentences.

The fix is always the same: pick an explicit direction (purpose / audience / tone / one
memorable detail / constraints) and design to the product domain, not the template.

## Microcopy — write these, not slop

The slop list says what *not* to write; the positive form the coder should produce:
- **Buttons name the action**, never "Submit"/"Get Started": "Create project", "Send invite", "Save changes".
- **Empty states = one next action**: what's missing + the CTA ("No invoices yet — create your first").
- **Errors = cause + recovery**, inline and specific: "Card declined — try another card", not "Something went wrong".
- **Believable content**: organic names, real-looking data (`47.2%`, not `99.99%`), concrete nouns — never "Acme" / "John Doe" / Lorem.
- **Voice matches the product category** (§ Industry-specific): fintech terse + precise; consumer warm; dev-tool plain.

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

**Score bands:** 0–3 broken (blocks ship) · 4–6 generic / inconsistent — the "slop" zone, redesign ·
7–8 solid and product-appropriate · 9–10 distinctive + polished. A UI **averaging < 7, or any single
dimension < 4, is a FLAG** to fix before ship. This is the threshold the § Visual review gate clears to.

## Interaction design rules

- **Animation**: 150–300ms micro-interactions, 300–500ms transitions; motion communicates state change
- **Form validation**: inline, real-time — not on submit only
- **State persistence**: web → reflect filter/search in URL (shareable); native → app navigation state
- **Dark mode**: required if the product offers it — test both
- **Internationalisation**: avoid hardcoded widths that break with longer/translated text

## Visual review gate (screenshot critique — post-build)

The coding backend can't see what it built, so visual defects are caught planning-side by a
*separate* reviewer (evaluator-independence — a generator rates its own UI as fine when it isn't).
After a UI build completes, in planning mode:

1. Run the app; take Playwright screenshots at the target breakpoints (web 375/768/1024/1440;
   native compact/regular).
2. Score them with the § Scored visual audit against the design brief — tokens honoured? forbidden
   patterns absent? art-direction met?
3. Turn findings into a focused fix-spec for the coder. Typically 2–3 cycles; stop when the audit
   clears its band threshold (avg ≥ 7, no dimension < 4).

Dispatch the review as a **fresh reviewer** — don't self-review the build you just reasoned about.
Environment: the app must be reachable from planning mode (local web; Mac-hosted app over LAN /
Tailscale). Image-less coding mode runs the deterministic text-proxy checks instead
(→ apex-ui-testing); this gate is the vision half.

## Stitch ideation lane (optional)

Google Stitch (free prompt-to-UI) is an optional *first-draft* ideation layer when starting from a
blank canvas. It exports an agent-readable `DESIGN.md` (tokens + structure as text). Use it to
explore a look fast, then **fold its tokens/direction into the design brief** — Stitch is the
ideation, the brief is the source of truth the coder reads. Don't wire Stitch output straight to the
coder; it goes through the brief. Pair with the `stitch-design-taste` library style to match Stitch's
house aesthetic. (Account is user-provisioned.)

## Escalation rules

BLOCK (halt spec):
- No keyboard/switch navigation defined for interactive elements

FLAG (note in spec):
- Layout untested at smallest target (web 375px / native compact size class)
- Missing empty or error state definition
- Decorative-only motion → apex-animation for necessity check
- Undefined dark-mode / design tokens → apex-design-system
- Redesign silently changes a URL/slug, nav label, or form field `name` — preserve it or call out the change (SEO / muscle-memory / integration breakage)
