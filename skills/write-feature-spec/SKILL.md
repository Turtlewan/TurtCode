name: write-feature-spec
description: Use when creating a new feature or module specification for the orion-v2 project. Generates a functional spec, technical module spec, and docs/changes entry from a structured interview.
---

# write-feature-spec

Creates three spec files for a new orion-v2 module from a batched interview:
- `docs/specs/functional/<module>.md`
- `docs/specs/technical/modules/<module>.md`
- `docs/changes/<module>-initial-spec.md`

## Process

1. Read existing docs for context
2. Ask functional questions (2 rounds: plain-text batch + AskUserQuestion)
3. Ask UI/UX questions (2x AskUserQuestion calls)
4. Dispatch Spec Writer subagent to write all 3 files and commit

---

## Step 1: Read Existing Docs

Read each file if it exists (skip silently if not found). Extract and summarise — do not paste raw content into memory:

1. `docs/status.md` — current project state, what's been built
2. Latest file in `docs/handoff/` (sort by filename, take the last) — recent session context
3. `docs/specs/functional/README.md` — extract the Module Index table (module names only)
4. `docs/specs/technical/README.md` — note tech stack and design principles

Build a short PROJECT_CONTEXT summary (5-10 bullet points) covering:
- What the project is
- What modules already exist
- Current build state
- Any relevant constraints from recent sessions

---

## Step 2: Functional Questions (2 rounds)

### Round 2a — Plain-text batch (send as one message)

Ask all of these in a single message. Number them. User replies covering all:

```
I need a few details to write the module spec. Please answer each:

1. Module name (what should this feature be called?)
2. What problem does it solve for the user? (1-3 sentences)
3. Core features — what can the user do with this module?
4. Primary data entities (e.g. "Transaction", "RecurringPayment")
5. Key user flows — list the main step-by-step workflows
6. Which existing modules does it interact with, and how?
7. Hard rules or constraints the implementation must respect
8. Known edge cases to handle (optional — leave blank if none)
```

Wait for the user's reply. Record all answers.

### Round 2b — Module status (AskUserQuestion)

Ask one structured question:

```
AskUserQuestion([
  {
    question: "Is this a new module or extending/replacing an existing one?",
    header: "Module type",
    multiSelect: false,
    options: [
      { label: "New module", description: "Creates a brand-new module with its own routes, models, and frontend page. (Recommended)" },
      { label: "Extending existing", description: "Adds to an existing module — new fields, routes, or UI sections." },
      { label: "Replacing existing", description: "Replaces the current implementation of an existing module." }
    ]
  }
])
```

---

## Step 3: UI/UX Questions (2 AskUserQuestion calls)

### Round 3a — Surface and interaction

```
AskUserQuestion([
  {
    question: "What type of UI surface does this feature live on?",
    header: "UI surface",
    multiSelect: false,
    options: [
      { label: "Full page", description: "Its own route and page in the app. (Recommended)" },
      { label: "Modal / overlay", description: "Opened from another page — no dedicated route." },
      { label: "Sidebar panel", description: "A slide-in panel alongside existing content." },
      { label: "Dashboard widget", description: "A card or widget on the Dashboard home page." }
    ]
  },
  {
    question: "What is the primary interaction pattern?",
    header: "Interaction",
    multiSelect: false,
    options: [
      { label: "List view", description: "Scrollable list of items with actions per row. (Recommended)" },
      { label: "Kanban board", description: "Columns of cards, sorted by status or urgency." },
      { label: "Form", description: "Primary surface is a form for data entry." },
      { label: "Data table", description: "Tabular data with sorting, filtering, and pagination." }
    ]
  },
  {
    question: "How does the user navigate to this feature?",
    header: "Navigation",
    multiSelect: false,
    options: [
      { label: "Top nav item", description: "Its own item in the global top navigation bar. (Recommended)" },
      { label: "Sub-navigation", description: "Nested under an existing top nav item." },
      { label: "Linked from another page", description: "Accessed via a link or button on another page — no nav entry." },
      { label: "Modal trigger", description: "Opened by a button, not navigated to directly." }
    ]
  },
  {
    question: "Which empty/loading/error states are needed?",
    header: "States",
    multiSelect: false,
    options: [
      { label: "All three", description: "Empty state, loading skeleton, and error retry. (Recommended)" },
      { label: "Loading + error only", description: "No empty state needed (content always exists)." },
      { label: "Minimal", description: "Error state only — loading and empty are not needed." }
    ]
  }
])
```

### Round 3b — Viewport and components

```
AskUserQuestion([
  {
    question: "Which viewports must this feature support?",
    header: "Viewports",
    multiSelect: false,
    options: [
      { label: "Desktop + tablet", description: "Optimised for desktop, responsive down to iPad. (Recommended)" },
      { label: "Desktop only", description: "No tablet layout required." },
      { label: "All sizes", description: "Desktop, tablet, and mobile." }
    ]
  },
  {
    question: "Which existing shared components should this feature reuse?",
    header: "Components",
    multiSelect: true,
    options: [
      { label: "PageHeader", description: "Title + subtitle + action button slot (top of every page)." },
      { label: "GlassCard", description: "Glass-morphism card surface for content blocks." },
      { label: "GlassPanel", description: "Larger glass container — used for column panels." },
      { label: "Modal", description: "Popup overlay with close button — for create/edit forms." }
    ]
  },
  {
    question: "Are there any special visual behaviours?",
    header: "Visual FX",
    multiSelect: false,
    options: [
      { label: "None", description: "Standard interactions only — no custom animations or effects. (Recommended)" },
      { label: "Animations", description: "Entry/exit animations on cards, panels, or transitions." },
      { label: "Inline editing", description: "Fields editable directly on the list/card without opening a popup." },
      { label: "Quick actions", description: "Action buttons directly on cards (e.g. Paid, Dismiss)." }
    ]
  },
  {
    question: "Anything else about the UI that the spec should capture?",
    header: "Other UI notes",
    multiSelect: false,
    options: [
      { label: "Nothing else", description: "The above covers it. (Recommended)" },
      { label: "I have notes", description: "Select Other and type them." }
    ]
  }
])
```

---

## Step 4: Dispatch Spec Writer Subagent

1. Read `./spec-writer-prompt.md` (from this skill's directory: `~/.claude/skills/write-feature-spec/spec-writer-prompt.md`).
2. Replace every `{{PLACEHOLDER}}` with the gathered values:
   - `{{PROJECT_CONTEXT}}` — the bullet-point summary from Step 1
   - `{{MODULE_NAME}}` — user's answer to Q1
   - `{{MODULE_SLUG}}` — kebab-case version of the module name (e.g. "Voice Commands" → "voice-commands")
   - `{{MODULE_STATUS}}` — answer from Round 2b
   - `{{PROBLEM}}` through `{{VISUAL_BEHAVIOURS}}` — all functional and UI/UX answers
3. Dispatch the filled-in prompt as a general-purpose subagent.
4. After the subagent reports completion, confirm:
   - All 3 files exist
   - A commit was made
   - Report the file paths to the user

---

## Notes

- If `docs/specs/functional/README.md` does not exist, skip the module-list extraction and use free text for Q6.
- If the user's answer to any question is blank or "none", omit that section from the spec rather than writing placeholder text.
- The Spec Writer subagent works from the orion-v2 project root. Ensure the subagent prompt includes the correct project path (`C:\Users\User\Projects\orion-v2`).

---

After writing the file, verify it exists with Get-Item and report:
- Status: DONE | DONE_WITH_CONCERNS | BLOCKED
- File path and size
- Any issues (note: no git in ~/.claude so skip any commit steps)