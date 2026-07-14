# Design workflow (UI-bearing projects)

Loaded on demand when planning a UI-bearing project. **Process only** — the design *knowledge*
(what good UI looks like, stack conventions, slop patterns, interaction timings) is model-native and
deliberately not written down here. What follows is the APEX-specific machinery a model cannot
derive: the persisted artifacts, the ask-first gate, the two design lanes, and the review gates.

Scope-gate: headless / API-only / pure-CLI projects skip this file entirely.

---

## The two persisted artifacts

Design decisions must be an **explicit, persisted, in-repo contract** the coder honours by name —
durable, inspectable build input, not ephemeral planning-side judgment.

### app-flow.md (ADR-013)

`docs/technical/architecture/app-flow.md` — seeded by apex-init, one per project.

- **Capture early**, before per-screen feature specs: **screens/routes** (name · purpose · how
  reached), **primary user journeys** (key end-to-end paths), and **screen states + transitions**
  (empty / loading / error / loaded). Flow-level only.
- **Flow only, not visual design.** Layout, spacing, colour, component styling and taste stay
  un-persisted judgment. Do not turn this into a visual spec — that boundary keeps it stable.
- **Keep it current** — a new screen or journey updates it; a UI feature spec names which
  screen(s)/journey it implements (the readiness gate checks this for UI specs).

### design-brief.md (ADR-017)

`docs/technical/architecture/design-brief.md` — seeded by apex-init, one per project.
Template: `~/.claude/skills/apex-plan/references/design-brief-template.md`.

Persist only the **stable, single-homed** visual decisions:
- **Tokens** — exact values: colour, type family + scale, spacing scale, radii, shadow. The coder
  references these by name, never inventing per-component values.
- **Art direction** — 2–4 sentences: mood, references, and *what it must NOT feel like*. Records
  the chosen feel (§ Aesthetic direction).
- **Forbidden patterns** — the project-specific don'ts ("no purple-on-white gradients, no nested
  cards, no Inter"). Highest-evidence lever for steering a literal coder — don'ts pull more weight
  than do's.

**Stays out:** per-screen layouts and component visuals — planning judgment, verified by the visual
gate, never frozen in a doc that rots. Screens/journeys are app-flow.md's job; don't duplicate.

apex-plan's readiness gate checks a UI spec references brief tokens; apex-code loads the brief as
build context. Keep the brief **prose-rich, not a bare token table** — tokens alone drift by
~screen 5–8.

---

## Aesthetic direction — ask first, don't assume

Set the aesthetic **once**, when the brief is first filled. Per-screen work reads the existing brief.

**Open every UI workflow by asking:**

> "Want me to **research UI suggestions** for this (reference apps + current patterns for this
> surface), or would you rather give me **a few keywords / references** to design from directly?"

- **Research** → Path A, then **report findings back** (references + recommended direction) and
  confirm before locking them into the brief — never silently proceed to design.
- **Keywords / a reference** → skip the research dispatch; seed the brief's feel + art-direction
  straight from those keywords (+ Path B if one shelf aesthetic clearly fits).

Either way the output is identical: concrete brief entries (tokens + art-direction + forbidden
patterns), never vibes.

**Path A — research-first.** Dispatch a focused design-direction scan via **apex-research**, scoped
to *this* product: reference/competitor apps in the category; established interaction patterns for
the surface; what domain users expect. Seed the scan with curated galleries —
[Awwwards](https://www.awwwards.com), [layers.to](https://layers.to),
[21st.dev](https://21st.dev) — mine for direction, never trace. Not generic trend surveys.

Bounded return (ADR-015): references (with links) + a recommended direction, distilled into the
brief as concrete entries. **Guardrail:** if the output is vibes/trends rather than concrete tokens
+ don'ts + references, it is **not done** — push to specifics. Research *informs* the brief; it never
replaces it.

**Path B — pull one library style.** Fixed-aesthetic style skills are **not** auto-loaded (they
collide and tax compliance — [[design-style-on-demand]]); they live shelved in
`~/.claude/style-library/`.
1. Read `~/.claude/style-library/INDEX.md`; match the brief's feel to **at most one** style.
2. Propose it; on confirmation install that one. **Never more than one** — that re-creates the
   collision the shelf prevents. Shelve it again when the project is done.

A library style's rule never outranks the brief's art-direction + forbidden patterns.

**Optional — concept mockups to align on direction.** Before locking the brief you may generate a
few concept mockups to discuss the *feel* (`imagegen-frontend-web` / `-mobile`, `brandkit` for
identity boards). Opt-in, never reflexive ([[no-reflexive-ui-render-prompt]]). Discussion artifacts —
ping-pong to converge, then seed the agreed feel into the brief. A mockup is a reference, never a
spec the coder traces.

---

## Design archetypes, not pages — the design→build handoff

The unit of design is the *pattern*, not the page: design each archetype **once**, then the coder
builds every page that recombines locked archetypes. "How much to design" is pattern-count, not
page-count — a 30-screen app often needs only ~5–7 designed things.

- **Claude designs (cheap mode):** the brief (once) · one **anchor screen** at high finish · each
  distinct **archetype** (index/list · detail · form · dashboard · modal + empty/loading/error
  states) · recurring **component patterns**. That's the lock point.
- **The coder builds:** every remaining page that's a *variation on a locked archetype* — apply
  brief tokens, reuse locked components, follow the established layout. Safe **because it traces a
  locked design rather than re-judging it**.
- **Boundary test, per page:** a *new* visual pattern or a hard taste call → design it in cheap mode
  first; a recombination of locked patterns → the coder builds it directly. Don't re-design instances.
- **Handoff = three artifacts:** `design-brief.md` + `app-flow.md` + the locked mockups/components.

**Consistency rides on three gates that only work together** (a coder can't reliably self-verify
cross-screen consistency; its top drift mode is *component multiplication* — a 2nd, slightly-different
card):
1. **Context** — `design-brief.md` fed in, prose-rich.
2. **Commit lint** — token-compliance + forbidden-pattern checks.
3. **Visual verify** — the visual review gate below.

**Promote early (rule of one), not on the 3rd use.** Human design waits ~3 uses before extracting a
shared component; an AI build inverts it — drafting a reusable piece is cheap, drift is the costly
failure → the moment a piece *could* recur, lock it as the one definition. The locked contract must
be **in-repo + inspectable** (local components / Storybook the coder can read) — never an imported
lib it can't see; agents treat imported deps as "aspirational" and re-invent instead.

---

## Cheap-mode preview (the design loop)

"Cheap mode" = render the component **logic-free** (mock data, no backend/navigation) to a PNG the
image model can read — small, fast, token-light. On a logic-free surface the cost is low enough that
**Claude can be the primary UI hand at the design/prototype stage**. Once it's wired into the real
app, logic + bigger files return → coding mode carries the bulk again.

**Step 0 — establish the feel before mockup #1** (soft-default, skippable). A cold mockup defaults to
generic AI-slop, so before rendering the *first* one, do the lightweight half of § Aesthetic
direction. Mockup #1 is then on-brand. If the user wants pixels fast ("skip taste"), render a generic
baseline now and fold the feel in later. Set the brief **once** — don't re-run step 0 per mockup.

**Two loops — pick by whether the user wants to be in it:**
- **Interactive co-review (the user's eyes — default when present):** write the mockup to
  **`docs/research/mockups/<name>.html`** (that dir auto-passes the write-guard); the user views it
  in **Cursor's in-editor render** — Claude's edit lands as a live diff *and* the pane updates, one
  window ([[cursor-coedit-flow]]). Loop: user comments → Claude edits (view-layer) → re-view →
  repeat to approval.
- **Solo self-drive (Claude's eyes):** write logic-free HTML/CSS → render + screenshot via
  **Playwright MCP** (`browser_navigate` → `browser_take_screenshot`) → **Read** the PNG → critique
  vs brief → iterate. **Never say "I can't render / you view it"** — Claude sees by **Read**-ing the
  screenshot (conflating the no-inline-images terminal with no vision is the known miss).

Variants side-by-side (Chrome multi-tab), the browser alternative, and headless-render tiers →
`cheap-mockup-workflow.md`. **Apple SwiftUI is the lone hard gate** — no Windows render path;
prototype the look as a web mockup, lock the brief, then use the target's native render.

---

## Live preview during build

The coder (Codex `gpt-5.6-sol`; Opus on fallback) has **native vision and sees the render** — so a
visual divergence is fixed in the build like any other task. The live window is the **human's**
eyes-on loop, not a capability workaround.

- **Web (Windows / Cursor):** run the dev server, then open Cursor's **Simple Browser** pane
  (Command Palette → "Simple Browser: Show" → the localhost URL) docked beside the terminal — hot
  reload shows each change live. Any browser works; the in-editor pane just keeps it one window.
- **SwiftUI:** Xcode Previews on a **Mac** — there is **no Windows live-preview path**. On Windows
  the only SwiftUI visual route is the Bitrig design lane (generate-and-iterate).

---

## Visual review gate (post-build)

A generator rates its own UI as fine when it isn't, so visual defects are caught by a **separate**
reviewer (evaluator-independence). After a UI build completes, in planning mode:

1. **Capture** the rendered UI at target sizes — Web → Playwright screenshots (375/768/1024/1440);
   Native SwiftUI → Xcode Preview captures (compact/regular), Mac-gated.
2. **Score** against the design brief: tokens honoured? forbidden patterns absent? art-direction met?
3. **Turn findings into a focused fix-spec** for the coder. Typically 2–3 cycles.

Dispatch as a **fresh reviewer** — never self-review the build you just reasoned about. The app must
be reachable from planning mode (local web; Mac-hosted app over LAN / Tailscale).

---

## Prompt-to-design lanes (opt-in — user-invoked)

A fuller alternative to the text-first brief flow, for when the user wants to **design the UI
visually before building**. **Opt-in only** — never auto-run, never auto-offered
([[no-reflexive-ui-render-prompt]]). Invoke explicitly: "design this in Stitch/Bitrig", "/stitch",
"/bitrig".

| Target stack | Lane |
|---|---|
| Web (+ Tauri / Electron shells) | Google Stitch |
| Apple-native SwiftUI | Bitrig |
| Flutter (Dart) | FlutterFlow AI (+ DreamFlow for first drafts) |
| .NET/C# all-platform native | Uno Platform Studio — Hot Design Agent |
| Windows-first native (WinUI 3) | WinCLI / Windows Dev Skills |
| KMP · Compose Multiplatform · .NET MAUI | no dedicated tool → text-first brief |

Two principles: design the **spine once** (tokens + flow + states — it spans every surface), and the
**framework choice is apex-stack's call — the lane follows it**, never the reverse. Capture
per-platform divergences in the brief (nav · window chrome · input mode · density).

The two mature lanes (Web → Stitch · Native SwiftUI → Bitrig), the fixed division of labour
(planning authors the prompt; the user runs the tool and iterates), and the 6-step
brief→prompt→generate→lock→build→gate loop → `design-lane-workflow.md`.
