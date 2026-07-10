# AGENTS.md population — planning fills what Codex reads (ADR-031)

Fired by the readiness-gate Documentation item: at **first spec-ready** for a project — and again
whenever a spec changes repo layout, conventions, or the stack binding — populate the root
`AGENTS.md` stub sections. apex-init seeds the file (ADR-026); planning owns its content from
here. Codex builds read AGENTS.md, not the APEX skills — an empty `§ Conventions` is a
propagation gap.

## Per-section instructions

- **`§ Verify commands`** (replace the `<!-- apex:agents:verify -->` stub): the union of every
  bound `stack_skills` entry's `## Verification Recipe`, verbatim runnable commands **including
  the install/setup step** (`uv sync`, `npm ci`, …). If the stack is still TBD, leave the marker.
- **`§ Project layout`** (replace its `<!-- apex:agents:stub -->`): the module map — each
  top-level package/dir + one line on what it owns — and the architecture shape in one line
  (e.g. "ports & adapters; domain logic never imports adapters"). Only fill once code exists.
- **`§ Conventions`** (replace its `<!-- apex:agents:stub -->`): ONLY what tooling does not
  mechanically enforce —
  - repo-specific conventions (naming schemes, module boundaries, error-contract shape)
  - resolved policy values (chosen lib + pinned major version, config values — state the
    decision, never "adapt to the bound stack")
  - version-bound hazards for the bound stack (API removals, v1→v2 breaking defaults)
  - security invariants (auth-source, tenant scoping, secret handling)
  Never generic hygiene (validation, HTTP codes, naming-in-general, DRY, no-silent-errors —
  native to the coder; injecting it degrades output via instruction competition).

## Form rules (apply to every line you write)

- **Repo-relative paths only** — absolute paths break in per-task worktrees (ADR-028).
- **Positively phrased + internally consistent** — GPT-5 burns reasoning reconciling
  contradictions and deviates from negative constraints; before adding a line, check it against
  the existing AGENTS.md text and rewrite conflicts instead of stacking them.
- **Root file ≤ ~200 lines** — beyond that there are real cost/perf penalties (AGENTS.md size
  is a quota lever). Overflow goes to **nested per-directory AGENTS.md files** (nearest wins),
  never a fatter root.
- **Keep it stable** — the file is prompt-prefix cacheable; edit when facts change, never
  cosmetically.
- **One home per fact vs CLAUDE.md:** conventions both agents need live HERE; the project
  CLAUDE.md may carry a thin cross-reference ("build conventions: see AGENTS.md") — never a
  copy, never a symlink (different audiences).
