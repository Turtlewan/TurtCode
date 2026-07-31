---
spec: round8-b1-specsource
status: draft
autonomy_level: L2
risk: high
coder_effort: high
---

# Spec: `-SpecSourcePath` — cross-tree spec validation refuses instead of silently skipping

**Identity:** Add a `-SpecSourcePath` param to `codex-dispatch.ps1` so a cross-tree build validates its out-of-worktree spec, and refuse (exit 72) when neither an in-worktree spec nor `-SpecSourcePath` is present — closing the silent-skip fail-open.
→ why: see docs/technical/adr/ADR-044-round8-deferred-designs.md (D5).

## Intent
- **Intent:** A build + workspace-write dispatch whose spec lives in another tree must validate that spec or refuse; it must never silently proceed unvalidated.
- **Invariants:** In-worktree spec present → today's validation path is unchanged and wins (the external file is never consulted). Neither in-worktree spec nor `-SpecSourcePath` → exit 72 (no launch, no ledger row). A provided `-SpecSourcePath` that is relative, drive-relative, nonexistent, basename ≠ `-Spec`, or validation-failing → exit 72. `-SkipBaselineCheck` still bypasses the entire pre-flight. Reviews and non-workspace-write dispatches never reach this block. Spec-level: the whole test-suite corpus stays green — every build-dispatching fixture is armed with an in-worktree green spec so the new refusal does not flip it to 72.
- **Non-goals:** No change to `apex-spec-validate.ps1`, to the in-worktree resolution/validation (≈907-921), or to any exit code other than reusing 72. Fixture arming uses a seeded in-worktree spec, NOT `-SkipBaselineCheck` — pre-flight-exercising fixtures keep their coverage. Cross-tree spec FRESHNESS is out of scope: the external spec file is validated at dispatch time but not pinned or hashed; the spec-source tree is outside the gate contract, and host-side mutation of the spec mid-dispatch is outside the careless-not-hostile threat model. Accepted, stated.

## Assumptions
- `apex-spec-validate.ps1` honours a single mandatory `-SpecPath` and returns exit 0 = valid, exit 1 = findings/missing/unreadable → impact: Stop
- The whole spec-validation block is reached only under `$Phase -eq 'build' -and $Sandbox -eq 'workspace-write'` (≈819) and is skipped by `-SkipBaselineCheck` (≈865-868), so the new refusal inherits that scoping → impact: Stop
- Exit 72 is the established "pre-flight gate refused before reservation" code (≈876/890/898/915) → impact: Caution

Simplicity check: considered leaving the silent skip and logging a warning — rejected per ADR-044 D5 (a warning on a fail-open path is the pattern this ADR set removes). This version refuses.

## Prerequisites
- Specs complete first: **round8-b3-suite-isolation** — b1 arms build-dispatching fixtures in two suites b3 restructures (`review-findings-test.ps1`, `careless-coder-test.ps1`); build strictly AFTER b3 so this spec edits the post-isolation suite bodies. `verdict-test.ps1` is entirely b3's (b3 both isolates it AND repairs its pre-existing 4×74 empty-scope debt with `-SkipBaselineCheck`, so its dispatches never reach spec validation — b1 does not touch it). Build order: b3 → b1 → b2.
- Environment setup required: none. Built in an isolated worktree copy of `~/.claude` (isolation contract X1–X4, ADR-044 Wave plan).

## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| skills/apex-code/scripts/codex-dispatch.ps1 | modify | Declare `[string]$SpecSourcePath`; bind basename to `-Spec`; rewrite the cross-tree `else` (≈923-925) into validate-or-refuse. |
| skills/apex-code/scripts/dispatch-preflight-test.ps1 | modify | Add cross-tree pre-flight cases; arm the GREEN-baseline and moved-tree fixtures with a seeded in-worktree spec. |
| skills/apex-code/SKILL.md | modify | Add `-SpecSourcePath` to the build-dispatch example (≈109-115), the exit-72 routing-table row (≈155), and the exit-72 description (≈255-257); bump frontmatter `version` 2.8.1 → 2.9.0 + `last_updated`; NET-NEUTRAL-OR-NEGATIVE line delta (tighten prose to offset). |
| hooks/codex-dispatch-guard.js | modify | The recommended build command at ≈448-450 gains `-SpecSourcePath <abs>`. |
| skills/apex-code/references/codex-observability.md | modify | The Params row at ≈103 gains `[-SpecSourcePath <abs>]`. |
| skills/apex-code/scripts/dispatch-test.ps1 | modify | Arm the build dispatch (`-Spec cap-test`) with a seeded in-worktree spec. |
| skills/apex-code/scripts/review-findings-test.ps1 | modify | Arm the build dispatches in cases #5 (`-Spec f5`) and #11 (`-Spec a-b`, `-Spec a`) with seeded in-worktree specs. |
| skills/apex-code/scripts/careless-coder-test.ps1 | modify | Arm the clean-build case #1 (`-Spec clean`) with a seeded spec; narrow its harness-wrote-nothing assertion to `docs/progress/`. |
| skills/apex-code/scripts/dispatch-criticalfile-test.ps1 | modify | Arm the two proceed-past-gate build dispatches — case 3 (`-Spec critfile-critical-confirmed`) and case 9 (`-Spec critfile-noncritical-build`) — with seeded in-worktree specs. Also edited by b2 (adds one end-to-end case); b2 builds strictly after b1. |
| skills/apex-code/scripts/dispatch-scopelock-test.ps1 | modify | Arm the deliberately-unlocked green-baseline build (`New-UniqueSpec -CaseName 'unlocked'`, ≈245-259) with a seeded in-worktree spec. PARITY acceptance (2 pre-existing failures stay). |

## Tasks
- [ ] **Task 1 (dispatcher):** In `skills/apex-code/scripts/codex-dispatch.ps1`, declare `[string]$SpecSourcePath` in the `param(...)` block near the other string params (landmark ≈10 `[string]$Spec,` … ≈23 `[string[]]$Authorized = @()`). Then rewrite ONLY the cross-tree `else` branch at ≈923-925 (landmark: `validator skipped (cross-tree build)`). New behavior:
  - (a) If `$SpecSourcePath` is provided: first require it to be a FULLY-QUALIFIED path — matching drive-absolute `^[A-Za-z]:[\\/]` OR UNC `^\\\\` (do NOT use `[System.IO.Path]::IsPathRooted`, which returns true for a drive-RELATIVE `C:foo` on PowerShell 5.1). A value failing both patterns (relative, or drive-relative like `C:relative\path`) → Red `[dispatch] REFUSED (exit 72)` message stating the documented contract is a drive-absolute or UNC path, then `exit 72`. Then it must resolve to an existing leaf file (`Test-Path -LiteralPath $SpecSourcePath -PathType Leaf`); if not → print a Red `[dispatch] REFUSED (exit 72)` message naming the missing path, then `exit 72`. **Identity binding:** then require `[System.IO.Path]::GetFileNameWithoutExtension($SpecSourcePath)` to equal `$Spec` under `OrdinalIgnoreCase`; on mismatch → Red `[dispatch] REFUSED (exit 72)` message naming BOTH the `-Spec` value and the source basename, then `exit 72`. ONLY after all three checks pass, run `$specFindings = @(& $preflightSpecValidateScript -SpecPath $SpecSourcePath)`, capture `$LASTEXITCODE`, echo findings, and mirror the in-worktree shape: exit 1 → Red REFUSED message with `$findingText` join + `exit 72` (same shape as ≈913-918); any other non-zero → `throw` (same shape as ≈919-921). Exit 0 → fall through (pre-flight continues).
  - (b) If `$SpecSourcePath` is NOT provided → print a Red `[dispatch] REFUSED (exit 72)` message stating: no in-worktree spec at `docs/changes/$Spec.md`; pass `-SpecSourcePath <absolute path>` for a cross-tree build, or `-SkipBaselineCheck` for a deliberate bootstrap; then `exit 72`.
  - The in-worktree branch (≈909-921, `if (Test-Path -LiteralPath $specFile -PathType Leaf)`) is UNCHANGED and takes precedence when the in-worktree spec exists.
  - files: skills/apex-code/scripts/codex-dispatch.ps1 — done when: the `else` no longer prints "validator skipped"; a workspace-write build with no in-worktree spec and no `-SpecSourcePath` exits 72; with a drive-absolute/UNC, existing, basename-matching, valid `-SpecSourcePath` it proceeds; with a relative, DRIVE-RELATIVE, nonexistent, basename-mismatched, or validation-failing `-SpecSourcePath` it exits 72.
- [ ] **Task 2 (preflight tests + arm pre-flight fixtures):** In `skills/apex-code/scripts/dispatch-preflight-test.ps1`, add cross-tree cases following the suite's existing fresh-temp-root + `APEX_STATE_DIR`-sibling isolation pattern (landmark ≈15-20 `$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) …` / `$stateRoot`). New cases: (1) cross-tree build (spec ABSENT under the worktree) with no `-SpecSourcePath` → exit 72; (2) same, with an ABSOLUTE `-SpecSourcePath` pointing at a valid spec file whose basename equals `-Spec` → **proceeds to end-to-end success: exit 0** (use the same fake-codex success shape the GREEN-baseline case uses at ≈318-324, i.e. a green AGENTS.md recipe + `FAKE_CODEX_INSCOPE_ONLY=1`); assert `ExitCode -eq 0`; (3) `-SpecSourcePath` pointing at a nonexistent path → exit 72; (4) `-SpecSourcePath` pointing at a spec whose basename MATCHES `-Spec` (so it reaches validation, not the mismatch branch) but whose CONTENT fails validation → exit 72, AND assert a `FAIL ` validator line appears in the output; (5) `-SpecSourcePath` pointing at a VALID spec whose basename ≠ `-Spec` → exit 72; (6) a RELATIVE `-SpecSourcePath` (basename would match) → exit 72; (7) precedence: BOTH an in-worktree spec (seeded, valid) AND a `-SpecSourcePath` with a matching basename but INVALID content → dispatch PROCEEDS (exit 0), proving the in-worktree branch wins and the external file is never consulted; (8) a DRIVE-RELATIVE `-SpecSourcePath` of the form `C:relative\path\<name>.md` (basename would match) → exit 72 (pins the drive-absolute/UNC contract from Task 1); (9) a `-SpecSourcePath` whose basename is a CASE-VARIANT of `-Spec` (e.g. `-Spec cap-test` with `...\CAP-TEST.md`) → PROCEEDS (exit 0), pinning the `OrdinalIgnoreCase` basename compare. **Refusal-case rigor:** every exit-72 case above additionally asserts NO ledger row was created (scratch ledger absent, or row count unchanged) AND no per-run codex log file appears under the scratch state dir's `codex-logs` directory — refusal is pre-reservation, so neither artifact exists (the fake-codex's own stdout goes only to the external log and is non-probative, so do NOT assert on a stdout launch marker). **Existing coverage (do NOT duplicate):** the `-SkipBaselineCheck`-without-spec bypass is already covered at ≈339-347 — verify that case still passes unchanged rather than adding a new one. **Arm the pre-flight fixtures:** the GREEN-baseline case (≈318-324) and the moved-tree case (≈308-316) build against fixture repos with NO seeded spec, so the new refusal would flip them (GREEN 0→72, moved-tree 69→72). For BOTH, seed the fixture's in-worktree spec via the existing `New-FixtureRepo -ExtraFiles @{ "docs\changes\$spec.md" = <green spec body> }` mechanism (the same `-ExtraFiles` path the validator-fail case at ≈300-301 already uses), where `$spec` is the `New-UniqueSpec` name each case already passes as `-Spec`; the seeded body is the minimal validator-green spec below (its filename tracks `$spec`). Do NOT use `-SkipBaselineCheck` — these fixtures must still exercise the pre-flight. files: skills/apex-code/scripts/dispatch-preflight-test.ps1 — done when: suite exits 0; the nine new cross-tree cases assert their stated outcomes (each refusal case also asserting no ledger row + no per-run codex log file under the scratch `codex-logs` dir); the existing ≈339-347 SkipBaselineCheck case still passes unchanged; GREEN-baseline still exits 0 and moved-tree still exits 69.
- [ ] **Task 3 (doc + skill-edit contract):** Update the documented dispatch contract across four sites:
  - `skills/apex-code/SKILL.md` (a) the build-dispatch example at ≈109-115 (landmark: `scripts/codex-dispatch.ps1 \`` … `-Effort <coder_effort>`) gains a `-SpecSourcePath <abs path>` line with a one-line trailing comment that the host always passes the spec's real home on cross-tree builds; (b) the exit-72 routing-table row at ≈155 (landmark: `refused: red baseline` … `or -SkipBaselineCheck for a bootstrap`) also names `-SpecSourcePath` as the cross-tree remedy; (c) the exit-72 description at ≈255-257 (landmark: `Exit **72** means the pre-flight refused … or failed in-tree spec validation`) is updated so it no longer implies ONLY baseline/in-tree validation — a cross-tree build with neither an in-worktree spec nor `-SpecSourcePath` is also refused at 72. **Skill-edit contract:** bump the frontmatter `version` 2.8.1 → 2.9.0 and set `last_updated` to the build date; the whole-file edit must be NET-NEUTRAL-OR-NEGATIVE in line count — offset the added lines by tightening prose elsewhere in the same file — and stay ≤ the 500-line cap.
  - `hooks/codex-dispatch-guard.js` — the recommended build command at ≈448-450 (landmark: `Use: ~/.claude/skills/apex-code/scripts/codex-dispatch.ps1 … -Authorized … -Prompt <pack>`) gains `-SpecSourcePath <abs>` so the guard's own guidance matches the contract.
  - `skills/apex-code/references/codex-observability.md` — the Params row at ≈103 (landmark: `**Params:** \`-Spec -Task -Worktree -BaseSha -Phase -Prompt …`) gains `[-SpecSourcePath <abs>]`.
  - (Verify each landmark before editing; if a cite has drifted, find the real site.)
  - files: skills/apex-code/SKILL.md, hooks/codex-dispatch-guard.js, skills/apex-code/references/codex-observability.md — done when: the SKILL.md example + exit-72 row + exit-72 description all mention `-SpecSourcePath`, its frontmatter reads `version: 2.9.0` with an updated `last_updated`, and the file's net line delta is ≤ 0 and ≤ 500 total; the guard hook's recommended command shows `-SpecSourcePath` and `node --check hooks/codex-dispatch-guard.js` passes; the observability Params row shows `-SpecSourcePath`.
- [ ] **Task 4 (arm the remaining build-dispatching fixtures):** Seed a minimal validator-green in-worktree spec at `docs/changes/<spec>.md` inside each build-dispatching fixture repo BEFORE its dispatch (the seed is written pre-snapshot, so the scope check treats it as baseline, never a coder write). `<spec>` MUST equal the `-Spec` argument that dispatch passes. Seed the green body below (an inline here-string). Do NOT use `-SkipBaselineCheck`. Per file:
  - `skills/apex-code/scripts/dispatch-test.ps1` — before the dispatch at ≈55-60 (landmark: `-Spec 'cap-test'`), seed `docs/changes/cap-test.md` in `$repo`.
  - `skills/apex-code/scripts/review-findings-test.ps1` — case #5 (≈150-160, `-Spec 'f5'`) seed `docs/changes/f5.md` in that `$repo`; case #11 (≈166-176) issues TWO build dispatches over one repo (`-Spec 'a-b'` then `-Spec 'a'`) — seed BOTH `docs/changes/a-b.md` and `docs/changes/a.md` in that `$repo`. (Cases #10 and other review-phase dispatches are build-gated-out and need no seed.)
  - `skills/apex-code/scripts/careless-coder-test.ps1` — the build case #1 dispatch is at ≈120 (`-Spec 'clean'`); seed `docs/changes/clean.md` in `$repo`. Seeding creates `docs/`, which collides with the assertion at ≈125 `-not (Test-Path (Join-Path $repo 'docs'))`; NARROW that assertion to `-not (Test-Path (Join-Path $repo 'docs\progress'))` (the comment's real concern is the harness's own `docs/progress/` output, not the seeded spec) — assertion intent preserved. (The suite's OTHER dispatch at ≈100 is `-Phase 'review'` → build-gated-out of spec validation, needs no seed.)
  - `skills/apex-code/scripts/dispatch-criticalfile-test.ps1` — only the two dispatches that PROCEED past the Layer-B gate reach spec validation: case 3 (≈222-234, `-Spec 'critfile-critical-confirmed'`, seed in `$fixtures[3].Path`) and case 9 (≈274-282, `-Spec 'critfile-noncritical-build'`, seed in `$fixtures[9].Path`). Seed `docs/changes/<spec>.md` in each fixture repo before its dispatch (extend the suite's `New-FixtureRepo` or write the file post-creation). The exit-76 cases (2,4,5,6,7,8) refuse at the classifier gate BEFORE spec validation, and the review case (10) is build-gated-out — leave all of them unarmed.
  - `skills/apex-code/scripts/dispatch-scopelock-test.ps1` — **PARITY acceptance, not green.** Only the "deliberately unlocked build" case (≈245-259, `New-UniqueSpec -CaseName 'unlocked'`, build phase, `-ScopeUnlocked` clears the ≈805 refusal and reaches the fake coder) proceeds to spec validation; seed its in-worktree spec matching the `New-UniqueSpec` name via the suite's `New-FixtureRepo` (`-ExtraFiles` if present, else write post-creation). This suite has TWO PRE-EXISTING failures unrelated to this spec — `no-scope refusal precedence` and `unlocked loud note` (the known findings-doc test-debt row) — of its 18 assertions; they are a SEPARATE cleanup spec, out of scope here. Do not fix or mask them. The exit-74 refusals and the review-exempt case (≈261-270) refuse-before / are build-gated-out — leave them unarmed.
  - files: skills/apex-code/scripts/dispatch-test.ps1, skills/apex-code/scripts/review-findings-test.ps1, skills/apex-code/scripts/careless-coder-test.ps1, skills/apex-code/scripts/dispatch-criticalfile-test.ps1, skills/apex-code/scripts/dispatch-scopelock-test.ps1 — done when: `dispatch-test`, `review-findings-test`, `careless-coder-test`, and `dispatch-criticalfile-test` each exit 0, every armed build dispatch reaching its pre-amendment outcome (65/67/0/report-collision/confirmed-proceed as before); and `dispatch-scopelock-test`'s failure set is BYTE-IDENTICAL to its recorded pre-edit baseline — exactly the same 2 pre-existing failures (`no-scope refusal precedence`, `unlocked loud note`) out of 18 assertions, ZERO new failures (the `unlocked` case no longer contributes a 72).

**Minimal validator-green spec body** (seed content for Tasks 2 and 4; `<name>` is set to the matching `-Spec`; passes `apex-spec-validate` — 11 headings, one bolded `**Task 1**` with a `files:` marker, matching acceptance line, non-empty Files-to-Change and Permissions):

```text
---
spec: <name>
status: draft
autonomy_level: L2
---
# Spec: fixture placeholder
## Intent
- Intent: fixture spec to satisfy pre-flight validation.
## Assumptions
- none -> impact: Low
## Prerequisites
- none
## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| src/a.py | modify | placeholder |
## Tasks
- [ ] **Task 1:** placeholder change — files: src/a.py — done when: file present.
## Wave plan
Wave 1: [Task 1]
## Permissions
Approving this spec approves the file operation above.
## Specialist Context
### Security
(none)
## Documentation
(none)
## Acceptance Criteria
- [ ] **Task 1** → verify: the placeholder change is present.
## Progress
_(coding writes here)_
```

## Wave plan
Wave 1: [Task 1] | Wave 2: [Task 2, Task 3, Task 4]
<!-- Task 1 (dispatcher) ships the refusal first. Wave 2: Task 2 (dispatch-preflight-test.ps1), Task 3 (SKILL.md + hooks/codex-dispatch-guard.js + references/codex-observability.md), and Task 4 (dispatch-test.ps1 + review-findings-test.ps1 + careless-coder-test.ps1 + dispatch-criticalfile-test.ps1 + dispatch-scopelock-test.ps1) touch disjoint files and all depend only on Task 1's behavior, so they run in parallel. The spec-level invariant is "target suite corpus green (scopelock at parity) at spec end" — all of Tasks 2 and 4 must complete within this spec. -->

## Permissions

The following actions will run autonomously during build.
Approving this spec approves all of them.

### File Operations
| Action | Paths |
|--------|-------|
| Create | (none) |
| Modify | skills/apex-code/scripts/codex-dispatch.ps1, skills/apex-code/scripts/dispatch-preflight-test.ps1, skills/apex-code/SKILL.md, hooks/codex-dispatch-guard.js, skills/apex-code/references/codex-observability.md, skills/apex-code/scripts/dispatch-test.ps1, skills/apex-code/scripts/review-findings-test.ps1, skills/apex-code/scripts/careless-coder-test.ps1, skills/apex-code/scripts/dispatch-criticalfile-test.ps1, skills/apex-code/scripts/dispatch-scopelock-test.ps1 |
| Delete | (none) |

### Commands
| Command | Purpose |
|---------|---------|
| `powershell -NoProfile -File .\skills\apex-code\scripts\dispatch-preflight-test.ps1` | Pre-flight suite (X2). |
| `powershell -NoProfile -File .\skills\apex-code\scripts\dispatch-test.ps1` | Dispatch suite (X2). |
| `powershell -NoProfile -File .\skills\apex-code\scripts\review-findings-test.ps1` | Review-findings suite (X2). |
| `powershell -NoProfile -File .\skills\apex-code\scripts\careless-coder-test.ps1` | Careless-coder suite (X2). |
| `powershell -NoProfile -File .\skills\apex-code\scripts\dispatch-criticalfile-test.ps1` | Critical-file suite (X2). |
| `powershell -NoProfile -File .\skills\apex-code\scripts\dispatch-scopelock-test.ps1` | Scope-lock suite (X2, PARITY). |
| `node --check hooks/codex-dispatch-guard.js` | Guard-hook syntax check after the doc edit. |

### Verify commands
Run from the build worktree root — the repo verify contract (worktree AGENTS.md `## Verify commands`), plus the six target suites above:

```
node --check hooks/destructive-command-guard.js
node --check hooks/lib/destructive-detect.js
python hooks/destructive-guard-test.py
powershell.exe -NoProfile -File .\skills\apex-code\scripts\baseline-check-test.ps1
powershell.exe -NoProfile -File .\skills\apex-code\scripts\spec-validate-test.ps1
powershell.exe -NoProfile -File .\skills\apex-code\scripts\dispatch-preflight-test.ps1
```

### Git Operations
| Operation | Scope |
|-----------|-------|
| (none) | The builder performs no git operations; the host integrates the worktree diff and commits (X3). |

_Host integration-commit message: `feat(dispatch): -SpecSourcePath refuses cross-tree builds without validated spec; arm fixtures (ADR-044 D5)`._

### Environment Access
| Variable | Purpose |
|----------|---------|
| `APEX_STATE_DIR` | Test isolation — scratch state root (set by the suite). |

### Network
| Action | Purpose |
|--------|---------|
| (none) | No package installation. |

## Specialist Context
### Security
(none)

### Performance
(none)

### Accessibility
(none)

## Documentation
| Doc type | File | Action |
|----------|------|--------|
| Inline | skills/apex-code/scripts/codex-dispatch.ps1 | Comment the refusal branches (why 72, cross-tree meaning). |
| ADR | docs/technical/adr/ADR-044-round8-deferred-designs.md | Already carries D5 — no new ADR. |

## Acceptance Criteria
- [ ] **Task 1** → verify: from the worktree root, `Select-String 'validator skipped' skills/apex-code/scripts/codex-dispatch.ps1` returns nothing; `Select-String 'SpecSourcePath' skills/apex-code/scripts/codex-dispatch.ps1` shows the param declaration and both branch uses; `Select-String 'GetFileNameWithoutExtension' skills/apex-code/scripts/codex-dispatch.ps1` shows the basename-binding check.
- [ ] **Task 2** → verify: `powershell -NoProfile -File .\skills\apex-code\scripts\dispatch-preflight-test.ps1` exits 0; the nine new cross-tree cases (no-param refuse, drive-absolute-valid-matching proceed to exit 0, missing-path refuse, matching-basename-invalid-content refuse with a `FAIL ` line, basename-mismatch refuse, relative refuse, in-worktree-wins precedence proceed, drive-relative refuse, case-variant-basename proceed) each assert their stated outcome and each refusal case also asserts no ledger row + no per-run codex log file under the scratch `codex-logs` dir; the existing ≈339-347 SkipBaselineCheck case still passes; the armed GREEN-baseline case still exits 0 and the moved-tree case still exits 69.
- [ ] **Task 3** → verify: the build-dispatch example, the exit-72 routing-table row, AND the exit-72 description (≈255-257) in `skills/apex-code/SKILL.md` all contain `-SpecSourcePath`; its frontmatter reads `version: 2.9.0` with an updated `last_updated`; the file's net line delta is ≤ 0 and total ≤ 500; `hooks/codex-dispatch-guard.js`'s recommended command shows `-SpecSourcePath` and `node --check hooks/codex-dispatch-guard.js` passes; `skills/apex-code/references/codex-observability.md` Params row shows `-SpecSourcePath`.
- [ ] **Task 4** → verify: each of `dispatch-test.ps1`, `review-findings-test.ps1`, `careless-coder-test.ps1`, `dispatch-criticalfile-test.ps1` exits 0 against the patched dispatcher; careless-coder case #1 still asserts exit 0 and now checks `docs/progress/` (not `docs/`); dispatch-criticalfile cases 3 and 9 still reach their pre-amendment proceed outcomes; `dispatch-scopelock-test.ps1` at PARITY — its failure set is byte-identical to the pre-edit baseline (exactly the 2 pre-existing failures out of 18 assertions, zero new).
- [ ] **Suite corpus** → verify: green required — `dispatch-preflight-test.ps1`, `dispatch-test.ps1`, `review-findings-test.ps1`, `careless-coder-test.ps1`, `dispatch-criticalfile-test.ps1` all exit 0 from the worktree root; parity required — `dispatch-scopelock-test.ps1` shows only its 2 pre-existing failures. (`verdict-test.ps1` is b3's, not this spec's.)

## Host verification
Host integrates the worktree diff into live `~/.claude` with NO gates open (isolation contract X3), then from the live tree re-runs the touched suites — GREEN: `dispatch-preflight-test.ps1`, `dispatch-test.ps1`, `review-findings-test.ps1`, `careless-coder-test.ps1`, `dispatch-criticalfile-test.ps1` (each isolates via scratch `APEX_STATE_DIR` per b3, already merged) all exit 0; PARITY: `dispatch-scopelock-test.ps1` shows exactly its 2 recorded pre-existing failures and no new ones. `node --check hooks/codex-dispatch-guard.js` passes. At wave close the host also adds the host-owned `SKILL-HISTORY.md` row (in the ~/apex repo, Wave-A D3 pattern) recording the apex-code SKILL.md bump to version 2.9.0. Host verification is the authoritative acceptance gate; the builder's worktree-green is necessary, not sufficient.

## Progress
_(Coding mode writes here — do not edit manually)_
