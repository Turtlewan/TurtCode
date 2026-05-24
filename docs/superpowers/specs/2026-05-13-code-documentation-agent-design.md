# Code Documentation Agent — Design Spec

**Date:** 2026-05-13
**Status:** Approved — pending implementation

---

## Overview

A new `code-documenter` agent that slots into the existing 5-agent coding pipeline. It runs after `code-reviewer` and before `doc-writer`, automatically writing inline docs and module-level READMEs for all code produced in a pipeline run. Supports Swift (DocC) and TypeScript/JavaScript (JSDoc). Skippable via `--no-docs`.

---

## 1. Pipeline Position

```
code-writer → code-workers (parallel) → code-reviewer → code-documenter → doc-writer
```

The agent is the 6th step in the pipeline. It receives the list of changed files from `code-writer` and the reviewer flags from `code-reviewer`. It produces inline-documented source files and README updates, then passes a doc summary to `doc-writer`.

---

## 2. Agent File

**Location:** `~/.claude/agents/code-documenter.md`

### Tool restrictions

| Agent | Tools |
|---|---|
| `code-documenter` | Read, Glob, Grep, Edit, Write |

### Inputs

- List of files changed by `code-writer`
- Reviewer flags from `code-reviewer`

### Behaviour

1. For each changed file, detect language by extension:
   - `.swift` → DocC format
   - `.ts`, `.tsx`, `.js`, `.jsx` → JSDoc format
   - All other extensions → skip
2. Read the file, identify all public/exported functions, classes, types, and methods.
3. Write inline docs for any undocumented symbols — never overwrite existing doc comments.
4. Write or update the `README.md` in the same directory.
5. Return: list of files documented, list of READMEs written/updated.

**Deferred question rule:** proceed with best judgment, log uncertainty, never stop to ask.

---

## 3. Inline Doc Format Rules

### Swift (DocC)

```swift
/// One-line summary.
///
/// Longer description if needed.
///
/// - Parameters:
///   - name: What this parameter is.
/// - Returns: What this returns.
/// - Throws: What errors this can throw.
func fetchUser(id: String) throws -> User { ... }
```

### TypeScript / JavaScript (JSDoc)

```ts
/**
 * One-line summary.
 *
 * @param id - What this parameter is.
 * @returns What this returns.
 * @throws {ErrorType} When this throws.
 */
function fetchUser(id: string): Promise<User> { ... }
```

### Rules

- Document all `public`/exported symbols. Skip `private`/internal ones.
- Never overwrite an existing doc comment — only fill gaps.
- Keep docs concise: one summary line + params/returns/throws only.
- For React components (`.tsx`/`.jsx`): document the props interface, not the component function itself.

---

## 4. README Structure

Each changed directory gets a `README.md` written or updated.

```markdown
# <module name>

One-paragraph summary of what this module does and why it exists.

## Public API

| Symbol | Type | Description |
|--------|------|-------------|
| `fetchUser` | `func` | Fetches a user by ID from the API |
| `UserStore` | `class` | Observable store for user state |

## Usage

\`\`\`swift
// Minimal working example
let user = try await fetchUser(id: "abc123")
\`\`\`

## Dependencies

- `NetworkClient` — used for HTTP requests
- `UserModel` — data model this module operates on
```

### Rules

- If `README.md` already exists: update only the **Public API** table and **Usage** example. Leave all other sections untouched.
- If no `README.md` exists: write the full structure above.
- One README per directory, not per file.
- Skip directories with only private/internal files — not worth documenting.

---

## 5. Pipeline Integration Changes

### `coding-pipeline` orchestrator

Add one new step between code-reviewer and doc-writer:

**Before (5-agent pipeline):**
```
6. Spawn doc-writer with spec + task summary + reviewer flags + resolved questions.
```

**After (6-agent pipeline):**
```
6. Spawn code-documenter with spec + list of changed files + reviewer flags.
7. Spawn doc-writer with spec + task summary + reviewer flags + doc summary + resolved questions.
```

### `doc-writer` handoff doc

Add a new section to the handoff doc template:

- **Docs written** — which source files received inline docs, which directories received a README.

### New flag

| Flag | Behaviour |
|---|---|
| `--no-docs` | Skip the `code-documenter` step entirely |

### Full command examples

```bash
coding-pipeline docs/changes/auth.md
coding-pipeline docs/changes/auth.md --no-docs
coding-pipeline docs/changes/auth.md --auto
coding-pipeline docs/changes/auth.md --auto --no-docs
coding-pipeline docs/changes/auth.md --dry-run
coding-pipeline docs/changes/auth.md --workers 4
```

---

## 6. Updated Tool Restrictions Table

| Agent | Tools |
|---|---|
| `coding-pipeline` | Read, Glob, Agent |
| `code-writer` | Read, Glob, Grep, Agent |
| `code-worker` | Read, Glob, Grep, Edit, Write, Bash |
| `code-reviewer` | Read, Glob, Grep |
| `code-documenter` | Read, Glob, Grep, Edit, Write |
| `doc-writer` | Read, Write |

---

## 7. Risks / Open Questions

- **Existing doc comments:** The agent must reliably detect whether a symbol already has a doc comment before writing. A false negative (thinking there's no doc when there is) could overwrite handwritten docs. The agent should check for `///` (Swift) or `/**` (JS/TS) immediately above the symbol declaration.
- **Large files:** Files with many exported symbols could produce very long doc passes. The agent should process one symbol at a time using Edit, not rewrite the whole file.
- **README merge conflicts:** If a README has custom sections between Public API and Usage, the agent must preserve them. Update only the specific tables/sections, not the whole file.
- **Language detection edge cases:** `.js` files may contain TypeScript-style code (common in some setups). The agent should use JSDoc regardless — DocC is Swift-only.
