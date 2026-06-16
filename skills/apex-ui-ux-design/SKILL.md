---
skill: apex-ui-ux-design
backend: claude
version: 1.21.0
last_updated: 2026-06-16
sources:
  - Apple HIG + Liquid Glass (WWDC25) — developer.apple.com/design/human-interface-guidelines
  - docs/technical/adr/ADR-013-app-flow-artifact.md
  - docs/technical/adr/ADR-017-design-brief-artifact.md
  - docs/research/design-capability/ (WS-1…4, 2026-06-12)
  - docs/research/swiftui-design-tooling/ (Bitrig + native lanes, 2026-06-12)
  - docs/research/ai-slop-watch/ (design-slop tells, 2026-06-16)
  - docs/research/cross-platform-design-tooling.md (non-web/native lanes, 2026-06-16)
  - docs/technical/adr/ADR-020-capability-routed-ui-escalation.md
  - docs/research/cheap-mode-native/ (cheap-mode preview per target surface, 2026-06-16)
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
  records the **chosen feel → aesthetic direction** (§ Aesthetic direction).
- **Forbidden patterns** — the project-specific don'ts ("no purple-on-white gradients, no nested
  cards, no Inter"). Highest-evidence lever for steering a literal coder — don'ts pull more weight
  than do's.

**Stays OUT** (un-persisted judgment, per ADR-013): per-screen layouts and component visuals — they
live as planning judgment, verified by the § Visual review gate, never frozen in a doc that rots.
Screens/journeys are app-flow.md's job; do not duplicate them here.

- **Scope-gate** — headless / API-only / CLI projects have no design brief.
- apex-plan's readiness gate checks a UI spec references brief tokens; apex-code loads the brief as
  build context. Template: `~/.claude/skills/apex-ui-ux-design/references/design-brief-template.md`.

## Aesthetic direction (ask first: research the look, or design from keywords)

Set the project's aesthetic **once**, when the design brief is first filled (early in planning) — not
per screen; per-screen work reads the existing brief.

**Open every UI workflow by asking — don't assume a path.** Before choosing a direction, ask outright:

> "Want me to **research UI suggestions** for this (reference apps + current patterns for this surface),
> or would you rather give me **a few keywords / references** to design from directly?"

- **Yes, research** → run **Path A**, then **report the findings back** (references + recommended
  direction) and confirm before locking them into the brief — never silently proceed to design.
- **Keywords / a reference instead** → skip the research dispatch; seed the brief's feel + art-direction
  straight from those keywords (+ **Path B** if one shelf aesthetic clearly fits). Treat the keywords as
  the art-direction seed, not throwaway.

Either way the output is identical: concrete brief entries (tokens + art-direction + forbidden patterns),
never vibes. The two paths below are *how* you fill the brief once the user has picked.

**Path A — research-first (when the user opts into research, or no shelf style obviously fits).**
Dispatch a focused design-direction scan via **apex-research**, scoped to *this* product:
- reference / competitor apps in the same category — what do the best ones actually do?
- established interaction patterns for this surface type;
- what domain users expect ("what good looks like") — **not** generic 20xx trend surveys.

Bounded return (ADR-015): references (with links) + a recommended direction. **Distil it into the
brief as concrete entries** — specific token values, the 2–4-sentence art-direction, forbidden
patterns, and a short `References` list. **Guardrail:** if the output is vibes/trends rather than
concrete tokens + don'ts + references, it is **not done** — push to specifics. Research *informs* the
brief; it never replaces it (constraints beat taste prose).

**Optional — concept mockups to align on direction.** Before locking the brief you may generate a few
concept mockups to discuss the *feel* (`imagegen-frontend-web` / `-mobile`, or `brandkit` for identity
boards). Opt-in, never reflexive ([[no-reflexive-ui-render-prompt]]) — reach for it only when seeing a
direction beats describing it. Mockups are saved as PNGs the user **opens** (Cursor / VS Code / desktop /
web preview them natively — they do **not** render inline inside a terminal Claude Code session, whose
TUI overwrites inline-image sequences). Treat them as discussion artifacts: ping-pong to converge on a
direction together, then seed the agreed feel + art-direction into the brief. The mockup is a reference,
never a spec the coder traces.

**Path B — pull one library style (fast path when a shelf aesthetic clearly fits the feel).**
Fixed-aesthetic "style/taste" skills are **not** auto-loaded (they collide and tax compliance —
[[design-style-on-demand]]); they live shelved in `~/.claude/style-library/`.
1. Read `~/.claude/style-library/INDEX.md`; match the brief's feel to **at most one** style.
2. Propose it; on user confirmation install that one into `~/.claude/skills/` (INDEX gives the
   command). **Never install more than one** — that re-creates the collision the shelf prevents.
   Shelve it again when the project is done.

Combine if useful (research to confirm a style fits, or research → bespoke brief with no style).
Reserve Path A's dispatch for surfaces where the aesthetic matters — skip it for trivial/internal
screens. If none of this fits, the brief's tokens + art-direction + forbidden-patterns stand alone.
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

_Last AI-slop refresh: 2026-06-16 · cadence: 7d._ When elapsed, a planning session runs a design-only
(no colour) slop-pattern research pass → dated file in `docs/research/ai-slop-watch/` → proposes deduped
additions → on approval lands via apex-skill-author; log each run in `docs/research/ai-slop-watch/log.md`.

LLM-generated UI converges on a recognisable generic look. Treat any of these as a FLAG to redesign with
product-specific intent (see § Industry-specific design reasoning). These are **FLAGs, not BLOCKs** — an
explicit, intentional choice in a prompt or in `design-brief.md` overrides them (the list catches
*unconsidered defaults*, not deliberate decisions). Genuine accessibility/correctness BLOCKs
(§ Escalation) are never overridable by aesthetic preference:

- Gratuitous gradients on everything; the purple→blue default palette
- Glassmorphism / blur cards used decoratively with no depth purpose
- Generic centred hero: oversized heading + vague copy over a stock/atmospheric gradient
- Uniform `grid-cols-3` / `grid-cols-4` card walls where the content isn't actually uniform
- Filler CTA copy ("Get Started", "Learn more") instead of action-specific labels
- Default font stack with no personality (plain `font-sans` / Inter everywhere)
- Cards nested inside cards; `rounded-2xl` (or maximum rounding) applied uniformly — corner radii should follow the design system's scale, not be maximised everywhere
- Oversized equal padding everywhere — destroys visual hierarchy and wastes screen space; use the spacing scale with intent
- Shadow-heavy design — layered `box-shadow` stacks compete with content and slow rendering on low-end devices; shadows are depth signals, not decoration
- The UI describing its own features in prose when the controls already speak for themselves
- Coloured left-border accent stripe on cards (as reliable an AI tell as em-dashes are in text)
- All-caps eyebrow/kicker label stacked above every section heading
- Bento grid reached for reflexively as a "look modern" default rather than to serve the content
- Hand-coded SVG mascot/scene illustrations that read as amateur doodles, not deliberate whimsy
- Emoji used as interface or feature icons (use a real icon system instead)
- Default stroke icon set (Lucide/Heroicons) used verbatim as the *entire* icon language, no personality
- Fake dashboard mockups + floating icon "pills" as hero decoration `[trending-2026]`
- Over-smooth glossy 3D-blob / stock-like "AI hero" imagery `[trending-2026]`
- Reflexively uniform, evenly-spaced symmetric sections as the default — vary rhythm, weight, and hierarchy with intent rather than stacking identical centred blocks `[trending-2026]`
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

1. Capture the rendered UI at the target sizes:
   - **Web** → Playwright screenshots (375/768/1024/1440).
   - **Native SwiftUI** → **Xcode Preview captures** (compact/regular) — the native analogue of the
     web screenshot; Mac-gated. (Xcode 26.3+ can capture Previews for an agent to iterate on.)
2. Score them with the § Scored visual audit against the design brief — tokens honoured? forbidden
   patterns absent? art-direction met?
3. Turn findings into a focused fix-spec for the coder. Typically 2–3 cycles; stop when the audit
   clears its band threshold (avg ≥ 7, no dimension < 4).

Dispatch the review as a **fresh reviewer** — don't self-review the build you just reasoned about.
Environment: the app must be reachable from planning mode (local web; Mac-hosted app over LAN /
Tailscale). Image-less coding mode runs the deterministic text-proxy checks instead
(→ apex-ui-testing); this gate is the vision half.

## Prompt-to-design lanes (opt-in — user-invoked)

A fuller alternative to the text-first brief flow, for when the user wants to **design the UI
visually before building**. **Opt-in only** — never auto-run, never auto-offered
([[no-reflexive-ui-render-prompt]]). Invoke explicitly: "design this in Stitch/Bitrig", "use the
design lane", "/stitch", "/bitrig".

**Pick the lane by target stack:**

| Target stack | Lane |
|---|---|
| Web (+ Tauri / Electron shells) | Google Stitch |
| Apple-native SwiftUI (Mac/iPad/iPhone) | Bitrig |
| Flutter (Dart) | FlutterFlow AI (+ DreamFlow for first drafts) |
| .NET/C# all-platform native (Win/Mac/iOS/Android/Linux) | Uno Platform Studio — Hot Design Agent (Figma-MCP incoming) |
| Windows-first native (WinUI 3) | WinCLI / Windows Dev Skills — agent codegen (from Claude Code) |
| KMP · Compose Multiplatform · .NET MAUI | no dedicated tool → text-first brief + generic agent codegen |

Two principles: design the **spine once** (tokens + flow + states — it spans every surface), and the
**framework choice is apex-stack / apex-mobile's call — the lane follows it**, never the reverse.
Capture per-platform divergences in the brief (nav · window chrome · input mode · density). Caveat:
"native everywhere" in 2026 means Uno/Flutter render their *own* cross-platform controls from one
codebase, not separate per-OS toolkits. Detail: `docs/research/cross-platform-design-tooling.md`.

The two mature lanes in detail:
- **Web → Google Stitch** (free; prompt → React + agent-readable `DESIGN.md`). Browser tool on the
  user's Google account (free tier ~350 + 200 gens/mo).
- **Native SwiftUI → Bitrig** (free tier / ~$20·mo; prompt → **real SwiftUI source** + Xcode project;
  `iSwift.dev` is the browser alternative). Output is already native, so **no web→SwiftUI translation
  tax** — its advantage over using a web tool for a native app. Mac-only to run; new (Mar 2026), no
  API/MCP — validate output quality. Detail: `docs/research/swiftui-design-tooling/`.

**Division of labour (fixed, both lanes):** these are browser/Mac tools planning mode **cannot
drive**. *Planning authors + refines the prompt and translates the result into the brief/spec; the
user runs the tool and iterates visually.*

The loop:
1. **Screen brief** — 3–5 lines: what the screen does, its states, the feel + the don'ts (from
   `design-brief.md`).
2. **Author the prompt** — encode the brief into one generation prompt: token values, the project
   forbidden-pattern list as explicit "do NOT" lines, layout intent, every state. Hand it to the user;
   do not attempt to run the tool.
3. **User generates + iterates** — refines conversationally in the tool, or pastes the result back so
   planning revises the prompt. Ping-pong until it's right.
4. **Lock + fold into the brief** — the **design facts** (tokens + structure — Stitch's `DESIGN.md`,
   Bitrig's source) fold into `design-brief.md`, which stays the single source of truth the coder
   reads. Tool output never wires straight to the coder.
5. **Feed the build:**
   - The token/`DESIGN.md` layer is the **universal, stack-agnostic spine** — always folds into the brief.
   - **Code reuse is stack-matched:** Stitch's React feeds a React project directly (other web stacks
     adapt); Bitrig's SwiftUI feeds a SwiftUI build directly. Cross-stack (e.g. a web design for a
     native app), the rendered output is a **reference to interpret, not trace** — the image-less coder
     gets the brief + spec text, never the image.
6. **Gate** — the post-build visual review (below) scores the build against the **locked design**, not
   just prose — a far sharper target.

The brief's art-direction + APEX anti-slop rules outrank any tool's house aesthetic
([[design-style-on-demand]]); pair `stitch-design-taste` only if Stitch's look is wanted.

## Live preview + Claude visual escalation (during build) — ADR-020

The middle of the UI loop, between the design lane (before) and the visual gate (after). The
coding model (DeepSeek) is **image-blind** — it writes UI code against the brief text and never sees
the render. So the live window is the **human's** eyes, and Claude is the **escalation** scalpel when
prose to a blind coder won't converge.

The full loop:
1. **Design** → `design-brief.md` (optionally via the Bitrig/Stitch lane above).
2. **Build** — DeepSeek codes the UI blind against the brief.
3. **Live preview (human watches, during build)** — keep a render window open:
   - **Web (Windows / Cursor):** run the dev server, then open Cursor's **Simple Browser** pane
     (Command Palette → "Simple Browser: Show" → the localhost URL) docked beside the terminal — hot
     reload shows each change live. Any browser works too; the in-editor pane just keeps it one window.
   - **SwiftUI:** Xcode Previews on a **Mac** — there is **no Windows live-preview path**. On Windows
     the only SwiftUI visual route is the Bitrig design lane (generate-and-iterate, not live-as-you-code).
   Divergences feed back to the coder as prose, or trigger escalation (next).
4. **Visual gate** — score the build against the locked design (rubric below).
5. **Claude visual escalation (bounded)** — Claude (planning) makes a **direct UI code edit** only
   when *all* hold: a **visual divergence** exists; the fix is **inherently visual** (pixel / spacing /
   optical) **or** prose feedback has failed to converge (≥2 rounds); and Claude can **see the render**
   (web: a Playwright-MCP screenshot or a pasted image; SwiftUI: Mac-gated). Bounds: **view-layer only**
   (markup / styles / view files — never logic, data, auth, or any critical-file path); **smallest
   surgical change**, then hand back to DeepSeek for volume (Claude output ≈29× the cost); **approval-
   gated + logged** (the edit hits the planning write-guard `ask`, the user approves, and the touched
   files are recorded in the handoff / status In-Flight). Authority rule + when it is *not* allowed:
   **apex-governance § Capability-routed UI escalation**. This is capability, not authority — it
   changes no gate, critical-file confirmation, or hard block.

### Cheap-mode preview by target surface

"Cheap mode" = render the component **logic-free** (mock data, no backend/navigation) to a **PNG the
image model can read** — a small, fast, token-light loop. On a logic-free surface the cost is low
enough that **Claude can be the primary UI hand at the design/prototype stage**, not just the
escalation scalpel (the ≈29× is per-token; a tiny mockup is cheap in absolute terms). Once it's wired
into the real app, logic + bigger files return → DeepSeek carries the bulk again.

**Design archetypes, not pages — the design→build handoff.** The unit of design is the *pattern*, not
the page: design each archetype **once**, then coding mode (DeepSeek) builds every page that recombines
locked archetypes. "How much to design" is pattern-count, not page-count — a 30-screen app often needs
only ~5–7 designed things.
- **Claude designs (cheap mode):** the brief (tokens + art-direction + forbidden, once) · one **anchor
  screen** at high finish · each distinct **archetype** (index/list · detail · form · dashboard · modal
  + empty/loading/error states) · recurring **component patterns**. That's the lock point.
- **DeepSeek builds (coding mode):** every remaining page that's a *variation on a locked archetype* —
  apply brief tokens, reuse locked components, follow the established layout. Image-blind-safe **because
  it traces a locked design, not judges pixels**.
- **Boundary test, per page:** a *new* visual pattern or a hard taste call → design in cheap mode first
  (the seeing model is needed); a recombination of locked patterns → coding mode builds it directly.
  Don't re-design instances.
- **Handoff = three artifacts:** `design-brief.md` + `app-flow.md` + the locked mockups/components.
  Build-time safety net = § Escalation rules above (ADR-020 bounded view-layer fix on visual divergence).
  Claude designs patterns + is the escalation scalpel — it does **not** hand-design the long tail.

**Step 0 — establish the feel before mockup #1 (soft-default; skippable).** A cold mockup defaults to
generic AI-slop, so before rendering the *first* one, do the lightweight half of § Aesthetic direction:
seed the brief's feel + art-direction, and if a shelf aesthetic clearly fits, pull **one** style-library
pack (Path B — `~/.claude/style-library/INDEX.md`; never more than one). Mockup #1 is then on-brand, not
generic. Runs **by default but is skippable** — if the user wants pixels fast ("skip taste"), render a
generic baseline now and fold the feel in on a later pass. Set the brief **once** (§ Aesthetic direction);
don't re-run step 0 per mockup — every later iteration reads the existing brief.

**Two cheap-mode loops — pick by whether the user wants to be in it:**
- **Solo self-drive (Claude's eyes, no user):** Claude runs both halves — write logic-free HTML/CSS →
  render + screenshot via **Playwright MCP** (`browser_navigate` → `browser_take_screenshot`) → **Read**
  the PNG → critique vs brief → iterate. For fast iteration when the user isn't watching. **Never say "I
  can't render / you view it"** — the terminal not showing images *inline* ≠ no vision; Claude sees by
  **Read**-ing the screenshot (conflating them is the known miss, two live sessions).
- **Interactive co-review (the user's eyes — default when the user is present for the mockup):** Claude
  writes a self-contained mockup to **`docs/research/mockups/<name>.html`** (inline styles; CDN
  Tailwind/fonts if needed — that dir auto-passes the planning write-guard, so mockup writes never
  prompt). **Default preview surface = Cursor's in-editor render:** the user keeps the `.html` open, so
  Claude's edit lands as a live diff *and* the rendered pane updates in the same window — one surface for
  code + pixels ([[cursor-coedit-flow]]), no external browser needed for a single mockup. Loop: user types
  comments → Claude edits the mockup (view-layer only) → user re-views the Cursor render → repeat until
  approved. (If the user prefers a browser instead, the same `.html` opens in their **own** Chrome tab —
  `file://…` or served — that **stays open the whole loop**; never a Playwright-controlled tab, which is
  Claude's *separate* headless screenshot instance and is **never `browser_close`d on the user's view**.
  Optional `live-server`/`vite` for auto-reload.)

**Multiple options → all tabs in ONE persistent Chrome window** (the one case external Chrome beats
Cursor's single-pane render — true side-by-side comparison). When the user asks for *options/variants*,
write each to its own `docs/research/mockups/<name>.html`, then open them **all at once as tabs in the
user's own Chrome window** in a single launch — Windows: `Start-Process chrome -ArgumentList
'file:///…A.html','file:///…B.html',…` (Chrome opens multiple URL args as tabs in one window; appends to
the existing window if Chrome is already running). They **persist** for side-by-side comparison. **Never
present option tabs via Playwright** — its browser closes on context end (the reported tab-closing
failure). Iterate per option: user comments on one → edit that file → user refreshes that tab.

The cheapness depends on getting a PNG **without booting a heavy emulator/window** — three tiers:
- **Tier A — headless host-render → PNG** (no emulator; cheapest, scriptable): **Flutter** goldens
  (`flutter test --update-goldens`), **Android Compose** (Paparazzi / Compose Preview Screenshot
  Testing / Roborazzi), **Avalonia** desktop (headless Skia `CaptureRenderedFrame()`). All Windows-runnable.
- **Tier B — browser preview + Playwright screenshot** (= the web loop): Web, **Electron/Tauri**
  (Chromium under the hood — mock in Chrome like a website), Expo/RN via Storybook-RN-Web.
- **Tier C — run on emulator/device/window + capture**: Android `adb exec-out screencap -p > x.png`;
  WinUI/WPF window via FlaUI / PowerShell; iOS simulator (Mac).

**Apple SwiftUI is the lone hard gate** — no Windows render path at all; fall back to a CI macOS
runner (render + upload PNG artifacts) or a web-mockup proxy for layout/feel. **Strategy:** prototype
the look as a web mockup (cheapest, framework-agnostic) → lock the brief → use the target's Tier-A
render for native fidelity where it exists. Full per-target table + commands + caveats:
`docs/research/cheap-mode-native/`.

## Escalation rules

BLOCK (halt spec):
- No keyboard/switch navigation defined for interactive elements

FLAG (note in spec):
- Layout untested at smallest target (web 375px / native compact size class)
- Missing empty or error state definition
- Decorative-only motion → apex-animation for necessity check
- Undefined dark-mode / design tokens → apex-design-system
- Redesign silently changes a URL/slug, nav label, or form field `name` — preserve it or call out the change (SEO / muscle-memory / integration breakage)
