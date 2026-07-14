# Prompt-to-design lanes — full procedure

Loaded on demand when the user invokes a design lane ("design this in Stitch/Bitrig", "/stitch",
"/bitrig"). SKILL.md carries the opt-in trigger, the pick-by-stack table, and the two principles
(design the spine once; framework choice is apex-stack's call). This file carries the two
mature lanes in detail and the loop.

## The two mature lanes in detail
- **Web → Google Stitch** (free; prompt/image/voice → **HTML/CSS + Tailwind**, export to **Figma**
  (named layers + Auto Layout) or via **MCP / Antigravity**; React/Vue/SwiftUI code export roadmapped,
  not shipped as of 2026-06). Browser tool on the user's Google account (free tier 550 gens/mo —
  350 Flash + 200 Pro).
- **Native SwiftUI → Bitrig** (free tier / ~$20·mo; prompt → **real SwiftUI source** + Xcode project;
  `iSwift.dev` is the browser alternative). Output is already native, so **no web→SwiftUI translation
  tax** — its advantage over a web tool for a native app. Mac-only to run; new (Mar 2026), no API/MCP —
  validate output quality. Detail: `docs/research/swiftui-design-tooling/`.

## Division of labour (fixed, both lanes)
These are browser/Mac tools planning mode **cannot drive**. *Planning authors + refines the prompt and
translates the result into the brief/spec; the user runs the tool and iterates visually.*

## The loop
1. **Screen brief** — 3–5 lines: what the screen does, its states, the feel + the don'ts (from `design-brief.md`).
2. **Author the prompt** — encode the brief into one generation prompt: token values, the project
   forbidden-pattern list as explicit "do NOT" lines, layout intent, every state. Hand it to the user;
   do not attempt to run the tool.
3. **User generates + iterates** — refines conversationally in the tool, or pastes the result back so
   planning revises the prompt. Ping-pong until it's right.
4. **Lock + fold into the brief** — the **design facts** (tokens + structure — Stitch's HTML/CSS + Figma
   export, Bitrig's source) fold into `design-brief.md`, the single source of truth the coder reads.
   Tool output never wires straight to the coder.
5. **Feed the build:**
   - The token + structure layer is the **universal, stack-agnostic spine** — always folds into the brief.
   - **Code reuse is stack-matched:** Stitch's HTML/CSS + Figma export feeds a web build (translate the
     markup — React export roadmapped, not shipped); Bitrig's SwiftUI feeds a SwiftUI build directly.
     Cross-stack (e.g. a web design for a native app), the rendered output is a **reference to interpret,
     not trace** — the image-less coder gets the brief + spec text, never the image.
6. **Gate** — the post-build visual review scores the build against the **locked design**, not just prose.
