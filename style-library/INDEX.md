# Style Library — on-demand aesthetic skills

These are **fixed-aesthetic "style/taste" skills**, deliberately kept OUT of `~/.claude/skills/`
so none of them auto-loads. Always-on taste skills collide (mandated-vs-banned glassmorphism,
Lucide, nested cards, infinite motion) and constraint-stacking taxes compliance (~30 pts,
arXiv:2605.06445). Decoupled per ADR-017 / [[design-style-on-demand]].

The owner's approved component libraries are a separate shelf: `COMPONENTS.md` in this folder.

## How this is used (Mechanism A)

1. A project's **design brief** (`apex-ui-ux-design` owns `design-brief.md`) settles the *feel*
   first — mood, references, what it must NOT feel like.
2. If that feel matches a library style below, **install exactly one** into the active skills dir
   for that project's work:
   ```powershell
   Move-Item "C:\Users\User\.claude\style-library\<name>" "C:\Users\User\.claude\skills\<name>"
   ```
   (or copy if you want to keep the shelf copy). Shelve it again when the project is done.
3. **Never install more than one** style at a time — that re-creates the collision this shelf exists
   to prevent. If none fits, the design brief's tokens + art-direction + forbidden-patterns stand
   on their own; no style skill is required.

`apex-ui-ux-design` (§ Aesthetic direction, Path B) drives this — it reads this index, proposes the
matching style for the brief's feel, and asks before installing. Path A (research-first) is the
default when no shelf style obviously fits.

## Available styles (feel → pull this)

| Style skill | The feel it encodes | Pull when the brief wants… |
|-------------|---------------------|----------------------------|
| `minimalist-ui` | Editorial / minimal — warm monochrome, typographic contrast, flat bento grids, muted pastels; no gradients/heavy shadows | calm, content-first, "magazine" restraint |
| `industrial-brutalist-ui` | Brutalist — raw, high-contrast, structural, visible grid/borders | bold, technical, anti-polished, opinionated |
| `high-end-visual-design` | Premium / luxe — nested "bezel" depth, refined type, rich surfaces | a high-end, expensive-feeling product surface |
| `design-taste-frontend` | Motion-rich, glassmorphic, animated micro-interactions | a lively, animated marketing/landing feel |
| `gpt-taste` | General "make it not generic" taste pass | a quick taste lift with no specific aesthetic |
| `stitch-design-taste` | Google Stitch's house aesthetic | pairing with the Stitch ideation lane (see apex-ui-ux-design § Stitch lane) |

> These styles **conflict with each other by design** (e.g. minimalist forbids what brutalist
> mandates). That is exactly why only one loads at a time. They also predate the APEX cluster's
> anti-slop rules — when a style rule conflicts with `apex-ui-ux-design`'s slop detection, the APEX
> rule wins.

## Archived (not styles — superseded by the APEX cluster)
`~/.claude/skills-archived/` holds `frontend-design`, `image-to-code`, `redesign-existing-projects`
(overlap apex-ui-ux-design / apex-frontend) and `emil-design-eng` (its `@starting-style` / WAAPI /
clip-path techniques were absorbed into `apex-animation` v1.4.0). Recoverable; not on the load path.
