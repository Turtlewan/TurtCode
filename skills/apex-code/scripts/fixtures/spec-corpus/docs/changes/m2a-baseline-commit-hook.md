---
spec: m2a-baseline-commit-hook
status: draft
autonomy_level: L2
coder_model: opus          # REQUIRED, not preference: the tests run `git commit`/`git stash` in throwaway
                           # temp repos, which the standing dispatch scope-lock forbids. In-session Opus
                           # is not subject to that lock (it is appended only to Codex dispatch packs).
cross_model_review: true   # Opus builds -> Codex reviews (ADR-032/034). Harness change.
coder_effort: high         # gate mechanism; fail-closed + git-hook correctness is load-bearing.
---

# Spec: M2a — baseline-green pre-commit hook

**Identity:** A git pre-commit hook that runs a repo's own full verify quad against the STAGED snapshot
and blocks the commit on red — the higher-value half of the baseline-green gate (M2).
→ why: see docs/technical/adr/ADR-039-baseline-green-gate.md and docs/research/reconciliation-pass.md § M2.

## Intent
- **Intent:** Stop a red baseline from being committed (the failure that escapes: a file-scoped "green"
  over a whole-project-red tree gets committed, then makes the *next* dispatch refuse to build). Enforce
  it with a git hook a forgetful host cannot skip, not a paragraph in AGENTS.md.
- **Invariants:**
  - A commit in a repo carrying the hook is blocked when the repo's full `AGENTS.md → ## Verify commands`
    quad is red **against the staged snapshot** (what will be committed). Unstaged/untracked changes are
    stashed for the check and restored after; the working tree ends unchanged.
  - If a file is both staged and further edited (index ≠ working), the hook **refuses up front**
    (fail closed) — that overlap is the one case a restoring `stash pop` could conflict on and strand
    work. Stage fully, or `--no-verify`.
  - The installer targets the hook git *actually runs* (linked-worktree- and `core.hooksPath`-safe) and
    never destroys a pre-existing hook.
  - Fail closed: a present-but-unparseable recipe blocks; a genuinely absent recipe is a *logged* skip.
- **Non-goals (deferred to M2b):** the pre-dispatch wrapper pre-flight + exit 72, the `-Preflight`/
  `-DetectOnly` modes, and any edit to `codex-dispatch.ps1`. Sol's BLOCKs 1-4 are all pre-flight; M2b
  will design them in (before-reservation placement so no phantom ledger row, tree-pin around the
  pre-flight, `&&`-aware test-line splitting, no circular DetectOnly). Also: auto-installing the hook
  into every consumer repo (installing into Artemis is a separate, explicit host step).

## Assumptions
- The recipe is the fenced block under a heading matching `^##\s*Verify commands\b` in the repo's root
  `AGENTS.md`; each non-empty, non-`#` line is one runnable command (may contain `&&`). Verified against
  `~/artemis/AGENTS.md:27-33`. → impact if wrong: Stop
- The build runs as in-session Opus, so the tests' `git commit`/`git stash`/`git init` in throwaway temp
  repos are permitted (the dispatch scope-lock does not apply). → impact: Stop
- `powershell.exe` and git's bundled `sh` are on PATH on the host (Windows). → impact: Caution
- `git rev-parse --git-path hooks` yields the correct hooks dir for both normal and linked worktrees and
  honours `core.hooksPath`. → impact: Stop
Simplicity check: considered inlining the parser into the sh hook — rejected: a PowerShell helper is
independently testable and reused by M2b. Build note: an intermediate working-tree check was tried and
**rejected by cross-family review (Claude + Codex, both BLOCK)** as unsound — it fails OPEN (staged-red
+ working-green commits the red index) and fails RED (unrelated dirt blocks a clean commit). Final
design verifies the **staged snapshot** via `git stash --keep-index`, guarded by an up-front refusal
when a file is both staged and further edited (the one same-file overlap where `stash pop` conflicts).

## Prerequisites
- none.

## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| `~/.claude/skills/apex-code/scripts/apex-baseline-check.ps1` | create | Parse `<worktree>/AGENTS.md → ## Verify commands` (heading regex `^##\s*Verify commands\b`), run every recipe line with **cwd = `-Worktree`** (`cmd /c "cd /d ""<wt>"" && <line>"`), first non-zero → print the failing line, **exit 1**; all pass → **exit 0**; heading present but no fenced block → **exit 3**; no heading / no AGENTS.md → print "no verify recipe — skipping" and **exit 0**. (Only the `-Full` behaviour is built here; `-Preflight`/`-DetectOnly` are M2b.) |
| `~/.claude/skills/apex-code/templates/pre-commit-baseline` | create | POSIX-sh hook. If there is anything unstaged/untracked, `git stash push --keep-index --include-untracked` (record whether it actually stashed); `trap` restores with `git stash pop` on EXIT (success, fail, or interrupt) — and only if it stashed. Runs `apex-baseline-check.ps1 -Full -Worktree <root>`; exits its code (non-zero blocks). Bypass = the standard `git commit --no-verify` (documented). |
| `~/.claude/skills/apex-code/scripts/install-baseline-hook.ps1` | create | Resolve the hooks dir via `git -C <repo> rev-parse --git-path hooks` (linked-worktree + `core.hooksPath` safe), create it if absent, write the template to `pre-commit`, mark executable. A differing existing hook is copied to `pre-commit.bak` and only overwritten with `-Force`. |
| `~/.claude/skills/apex-code/scripts/baseline-check-test.ps1` | create | Test suite that **accumulates failures and exits non-zero on any FAIL** (the existing dispatch-test `Check` only prints — Sol FLAG). Fully isolated: throwaway temp repos + isolated `APEX_STATE_DIR`; never renames the live helper. |
| `~/.claude/skills/apex-code/SKILL.md` | modify | Document the pre-commit hook + installer in § Verify / § Post-build (what it enforces, the `--no-verify` bypass, the install step). No exit-code-table change (that is M2b's exit 72). |

## Tasks
- [ ] Task 1: Build `apex-baseline-check.ps1` per its Files-to-Change note — heading regex, fenced-block
  capture, per-line run with cwd = `-Worktree`, exit 0/1/3, absent-recipe skip+0.
  — files: `~/.claude/skills/apex-code/scripts/apex-baseline-check.ps1`
  — done when: returns 0/1/3 and the skip-notice+0 against seeded temp repos, and provably runs the recipe
  in `-Worktree` not the caller's CWD.
- [ ] Task 2: Write `pre-commit-baseline` (sh) — stash-keep-index of unstaged+untracked with trap-based
  restore (no-op when nothing to stash; pops only what it pushed), run `-Full`, exit its code.
  — files: `~/.claude/skills/apex-code/templates/pre-commit-baseline`
  — done when: a red **staged** diff is blocked even with an unrelated green fix left unstaged; a green
  staged commit succeeds; the working tree (incl. untracked) is identical afterwards.
- [ ] Task 3: Write `install-baseline-hook.ps1` — resolve hooks dir via `git rev-parse --git-path hooks`,
  install + mark executable, back up a differing existing hook to `pre-commit.bak`, overwrite only `-Force`.
  — files: `~/.claude/skills/apex-code/scripts/install-baseline-hook.ps1`
  — done when: installs into a normal repo AND a linked worktree (`git worktree add`) targeting the right
  hooks dir; a pre-existing hook is preserved to `.bak`.
- [ ] Task 4: `baseline-check-test.ps1` — accumulate-and-exit-nonzero runner covering: green→0; red
  lint/type→1; failing test→1; no recipe→0+notice; unparseable→3; cwd-is-Worktree; hook red-staged blocked
  / green-staged ok / partial-staging judges the index / working tree restored; installer linked-worktree
  target + existing-hook backup. Each red/refuse case is first run against the not-yet-built logic and
  observed to fail (captured), matching the deadlock-fix red-before-green discipline.
  — files: `~/.claude/skills/apex-code/scripts/baseline-check-test.ps1`
  — done when: all cases pass and the suite exits non-zero if any assertion fails.
- [ ] Task 5: Document in SKILL.md § Verify / § Post-build — what the hook enforces, `--no-verify`, install.
  — files: `~/.claude/skills/apex-code/SKILL.md`
  — done when: the hook + installer are described where the verify/post-build guidance lives.

## Wave plan
Wave 1: [Task 1] | Wave 2: [Task 2, Task 3] | Wave 3: [Task 4, Task 5]
<!-- Task 1 is the helper both Task 2 (hook) and Task 3 (installer path) exercise. Single-coder (Opus),
     so waves are sequencing. Tests (Task 4) are AUTHORED alongside and each red case is run against the
     pre-change (absent) logic first for red-before-green evidence, then re-run at Wave 3. -->

## Permissions
The following actions will run autonomously during build. Approving this spec approves all of them.

### File Operations
| Action | Paths |
|--------|-------|
| Create | `~/.claude/skills/apex-code/scripts/apex-baseline-check.ps1`, `~/.claude/skills/apex-code/scripts/install-baseline-hook.ps1`, `~/.claude/skills/apex-code/scripts/baseline-check-test.ps1`, `~/.claude/skills/apex-code/templates/pre-commit-baseline` |
| Modify | `~/.claude/skills/apex-code/SKILL.md` |
| Delete | (none) |

### Commands
| Command | Purpose |
|---------|---------|
| `powershell -File baseline-check-test.ps1` | Run the new suite (exits non-zero on any failure) |
| `git init` / `git add` / `git commit` / `git stash` / `git worktree add` **in throwaway temp repos** | Test the hook + installer (NOT the target repo; in-session Opus, not a scope-locked dispatch) |
| `apex-baseline-check.ps1 -Full -Worktree ~/artemis` | Prove against the real Artemis recipe (read-only run; no hook installed into Artemis) |

### Git Operations
| Operation | Scope |
|-----------|-------|
| `git add -f` | the four new script/template files (`~/.claude` blanket-ignores `*`) |
| `git add` | `SKILL.md` |
| `git commit` (~/.claude) | "feat(apex-code): baseline-green pre-commit hook — block a commit on a red verify baseline" |
| `git add` + `git commit` (~/apex, SEPARATE) | ADR-039 (already written) + a `SKILL-HISTORY.md` row |

### Environment Access
| Variable | Purpose |
|----------|---------|
| `APEX_STATE_DIR` | test isolation (already used by the harness) |

### Network
| Action | Purpose |
|--------|---------|
| `uv sync` (inside the verify recipe, when proving against Artemis / in tests using that recipe) | may fetch dependencies on a cold cache |

## Specialist Context
### Security
The hook and helper execute the repo's **AGENTS.md-declared verify commands on the host with the
committer's privileges, outside any sandbox** (Sol FLAG). This is the *same* trust already placed in
those commands — the host runs the verify recipe today (apex-code § Verify); the hook only makes it
non-skippable. The residual expansion: a commit that also modifies `AGENTS.md`'s verify lines changes
what the hook then runs. Documented as a known trust boundary; not mitigated in M2a (AGENTS.md is
trusted, planning-authored repo content). `git commit --no-verify` remains the deliberate escape.

### Performance
The hook runs the FULL quad (incl. the ~600-test pytest) once per commit — seconds-to-~1min on Artemis.
Acceptable at the commit boundary; the fast per-dispatch subset is M2b's concern.

### Accessibility
(none — no UI.)

## Documentation
| Doc type | File | Action |
|----------|------|--------|
| Inline | the new scripts / hook | header comment: mechanism + fail-closed + trust-boundary note |
| ADR | docs/technical/adr/ADR-039-baseline-green-gate.md | **already written** — update its "Consequences" to note M2 shipped in two parts (M2a hook now, M2b pre-flight later) |
| SKILL-HISTORY | ~/apex/SKILL-HISTORY.md | add a row (apex-code baseline commit hook) — committed in the SEPARATE ~/apex commit |

## Acceptance Criteria
- [ ] Green baseline → `apex-baseline-check.ps1 -Full` exits 0; whole-project mypy/lint or a failing test → exit 1 naming the line → verify: seeded temp repos.
- [ ] No recipe → exit 0 + skip notice; heading-but-no-block → exit 3 → verify: two temp repos.
- [ ] Recipe runs in `-Worktree`, not the caller's CWD → verify: a recipe asserting its own directory passes only in the target repo.
- [ ] Hook blocks a red **staged** commit even with an unrelated green fix left unstaged; a green staged commit succeeds → verify: install + partial-staging commit test.
- [ ] Working tree (including untracked files) is byte-identical after a blocked commit → verify: hash the tree before/after.
- [ ] Installer targets the correct hooks dir in a **linked worktree** and backs a differing hook up to `pre-commit.bak` → verify: `git worktree add` + pre-existing-hook tests.
- [ ] Real-world proof → `apex-baseline-check.ps1 -Full -Worktree ~/artemis` runs Artemis's actual recipe and its exit code matches Artemis's real current state (0 iff that baseline is green) → verify: run it, compare to a hand-run of the same quad. (Artemis has tracked mods at review time; the oracle is "matches the same quad run by hand," not a clean checkout.)
- [ ] Suite integrity → `baseline-check-test.ps1` exits **non-zero** if any assertion fails (not print-only) → verify: inject a deliberately failing assertion, confirm non-zero exit.
- [ ] Docs → SKILL.md § Verify / § Post-build describe the hook, the `--no-verify` bypass, and the installer → verify: grep SKILL.md.
- [ ] Regression → the full existing dispatch suite (dispatch-test, verdict, review-findings, sibling-guard, careless-coder, wave-scope, encoding, scope, **git-stderr**, deadlock) stays green → verify: run them, all exit 0.

## Progress
_(Coding mode writes here — do not edit manually)_
