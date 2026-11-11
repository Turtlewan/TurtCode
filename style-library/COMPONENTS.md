# Component shelf — the owner's approved UI libraries

Owner preference, edited freely (plain file, not a skill). Read on demand when a product with an
interface reaches the design step. The rules for picking from it live in
`~/.claude/skills/apex-plan/references/design-workflow.md` § Component sources.

"Lands as" was written from memory on 2026-11-11 unless marked checked. Confirm against the
library's current docs at the moment a product picks it.

## Look-setting libraries — options, one per product

These compete in the anchor-screen comparison.

| Library | Character | Mechanism underneath | Lands as |
|---|---|---|---|
| [shadcn/ui](https://ui.shadcn.com) | Neutral, restyles fully to the brief | Radix or Base UI (use Base UI) | Source copied in |
| [Coss UI](https://www.coss.com) | Component set built on Base UI | Base UI | Source copied in |
| [Align UI](https://www.alignui.com) | Tailwind design system with Figma source | confirm at pick time | Source copied in |
| [daisyUI](https://daisyui.com) | Tailwind class plugin, works outside React | none (styling only) | Package → wrapper folder |
| [HeroUI](https://www.heroui.com) | Full React library, keeps some house character | its own | Package → wrapper folder |
| [Ant Design](https://ant.design) | Dense enterprise library, strong house character | its own | Package → wrapper folder |

## Mechanism — follows the look-setting library

| Library | Use when |
|---|---|
| [Base UI](https://base-ui.com) | The choice is free: shadcn/ui, or parts built from scratch |
| [Radix UI](https://www.radix-ui.com) | The chosen library or an existing project already sits on it |

## Single-job defaults — used whichever look wins

| Job | Default | Alternate |
|---|---|---|
| Toasts | [Sonner](https://sonner.emilkowal.ski) | |
| Drawer / bottom sheet | [Vaul](https://vaul.emilkowal.ski) | |
| Command menu | [cmdk](https://github.com/pacocoursey/cmdk) | |
| Animated numbers | [NumberFlow](https://number-flow.barvian.me) | |
| Charts | [recharts](https://recharts.org) | [Liveline](https://github.com/benjitaylor/liveline) when data streams live |
| Drag and drop | [dnd kit](https://dndkit.com) | |
| Long lists / large tables | [Virtuoso](https://virtuoso.dev) | |
| Animation | [motion](https://motion.dev) | plain CSS for a simple hover or fade |
| One-time-code input | [input-otp](https://input-otp.rodz.dev) | |
| Theme switching | [next-themes](https://github.com/pacocoursey/next-themes) | |

Rows from Charts down come from `pick-ui-library` (github.com/emilkowalski/skills), which is
deliberately not installed as a skill.

## Borrow-a-piece sources — single components, restyled to the brief

Never set the look; never compete in the comparison.

| Library | What to borrow | Lands as |
|---|---|---|
| [Magic UI](https://magicui.design) | Animated marketing components | Source copied in |
| [Aceternity UI](https://ui.aceternity.com) | Effect-heavy animated components | Source copied in |
| [21st.dev](https://21st.dev) | Community component registry | Source copied in |
| [assistant-ui](https://www.assistant-ui.com) | AI chat interface | Package primitives + copied-in styled parts |
| [Beautiful UI](https://www.beautifului.dev) | AI-agent interface pieces: thinking traces, approval cards, chat panel, diff tables (MIT; checked 2026-11-11) | "Copy-paste ready"; install method not stated |
| [Rare UI](https://rare-ui.com) | Unclassified — classify on first use | ? |
