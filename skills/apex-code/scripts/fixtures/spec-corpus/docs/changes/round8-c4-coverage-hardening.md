---
spec: round8-c4-coverage-hardening
status: draft
autonomy_level: L2
risk: high
coder_effort: medium
---

# Spec: c2 review-debt closure — pin-first binding coverage, adopt exit-77 coverage, lockstep comments

**Identity:** Close the three ADVISORY findings the round8-c2 review left open, all in the harness under edit: (1) add a critical-file suite case that arms a REAL tree pin so the production pin-file read path (`codex-dispatch.ps1` `if ($treePinArmed)`, ≈1458-1463) is finally executed; (2) add an adopt live-replay case that drives the adopt-specific exit-77 rung (≈928-931), which no test hits today; (3) add short lockstep comments at BOTH halves of each of the two known duplications (dispatcher scope-check-throw handling; scope-check attribution loop) so a future editor keeps them coupled — behavior byte-identical, comments only.
→ why: see docs/changes/done/round8-c2-dispatch-binding.md (shipped D6 items 1 + 5). The wave reviewer flagged that every binding case passes `-NoTreePin`/`-TreePinScript` (the TOCTOU-free pin-file read has zero coverage), that the adopt exit-77 rung is independent code never exercised, and that two deliberate duplications carry no coupling note.

## Intent
- **Intent:** Convert three advisory review findings into executed coverage and a maintenance guard, without changing any production behavior. The two new tests exercise real code paths that currently have zero coverage; the comments prevent a future editor from silently un-coupling two fail-closed duplications.
- **Invariants:** The critical-file suite grows from 17 assertions to 19 (one pin-first binding case, one adopt exit-77 case) and stays green. No production `.ps1` logic changes: the only edits to `codex-dispatch.ps1` and `codex-scope-check.ps1` are inline comments (byte-identical behavior). All sibling suites stay green: family-gate 34, dispatch 14, scope-check unchanged. Every new assertion reads per-record ledger fields or exact exit codes; where output text is inspected it uses the suite's existing per-record newline-join (`Invoke-DispatchCase` builds `Output` at ≈278), never `Out-String` substring matching.
- **Non-goals:** No new dispatcher behavior, no new exit code, no new fake-codex knob. No change to any existing case (the deliberate case-3→case-8 `LASTEXITCODE` adjacency at ≈374-382 is untouched — both new cases append AFTER case 17). No change to `codex-dispatch.ps1` or `codex-scope-check.ps1` control flow. No SKILL.md / frontmatter change (so no `SKILL-HISTORY.md` row).

## Assumptions
- The critical-file suite has exactly 17 `Assert-Case` assertions today (cases 1,2,11,3,8,4,5,6,7,9,10,12,13,14,15,16,17); the fixture loop is `foreach ($number in 1..17)` (≈320) and creates all repos before any dispatch (≈317-329) → impact: the two new cases append after case 17 and the loop bumps to `1..19`; adding fixtures 18/19 keeps the pre-create discipline → Stop
- Every existing review-binding case (12b ≈447-451, 13b ≈469-473, 14b ≈489-493, 15b ≈508-512) passes BOTH `NoTreePin = $true` AND a `TreePinScript` stub, so `$treePinArmed` is always false and the code lands in the `elseif ($NoTreePin)` fallback (≈1464-1471) — the production `if ($treePinArmed)` pin-file read (≈1458-1463) has zero coverage → impact: the pin-first case must pass NEITHER `-NoTreePin` NOR `-TreePinScript` so the real `tree-pin.ps1` arms a pin (≈1421-1439) and line 2 of the `treepin-v2` file is read as `$live` (≈1459-1461) → Stop
- The seed build records a REAL `end_tree_digest` from the production `tree-pin.ps1 -Digest` path (no `-TreePinScript`), and the review fake writes into a separate sink (`reviewSink`, ≈331) so the reviewed tree does not move between build-close and review-pin; therefore the pin's line-2 digest equals the recorded `end_tree_digest`, the compare at ≈1484 matches, and `reviewed_tree_digest` is recorded at ≈1492 → impact: exit 0; assert `reviewRow.reviewed_tree_digest -ceq buildRow.end_tree_digest`; the reservation hashtable creates `tree_pin_override` on EVERY row unconditionally (≈1247, `([bool]$TreePinScript -and [bool]$ReviewedRunId)`), so with no `-TreePinScript` its value is `$false` (not absent) — unlike 12b-15b where it is `$true` → Stop
- The pre-reservation lookup (≈1263-1288) sets `$script:reviewedEndTreeDigest` from the referenced build row; the seed build produces a genuine terminal-success `phase=build` row matched by ≈1271-1272, so no ledger surgery is needed for the match case → impact: seed with `SkipBaselineCheck` (mirrors 12a-15a at ≈439-441); no `Set-LedgerRowProperty` call → Stop
- `apex-critical-files.ps1` classifies `package-lock.json` as CRITICAL category `deps` → exit 10 (basename table ≈52, `.lock`/deps rule ≈165-169, `CRITICAL` emit + `exit 10` at ≈204/213-214) — NOT a hard block → impact: an adopt live-replay whose recorded `critical_files_confirmed=false` and whose post-snapshot in-scope write is `src/package-lock.json` yields `critical_violation=true` (helper `-Confirmed $false` on exit 10), not exit 11 → Stop
- The adopt exit-77 rung is `if ($adoptCriticalViolation -eq $true) { … exit 77 }` (≈928-931), reached only after scope (`exit 65` ≈923) and encoding (`exit 73` ≈924-927); the terminal adopt `Update-LedgerRow` (≈900-912) records `status="adopted-$adoptFinal"` and `critical_violation` BEFORE the exit → impact: the new case asserts `exit 77`, `row.status -eq 'adopted-done'`, `row.critical_violation -eq $true`; it is a near-clone of case 16 (≈523-548) with the fabricated row's `critical_files_confirmed` flipped to `$false` → Stop
- Case 16's live-replay fabricated row forces the live `-Check` branch by setting `scope_armed=$true` with `scope_exit`/`ended` ABSENT (≈533-540 vs the recorded-verdict row 17 which sets `scope_exit`/`ended`, ≈553-560); the in-scope critical write `src\package-lock.json` under `-Authorized @('src')` keeps scope exit 0 so classification (not scope) drives the exit → impact: the new fixture mirrors the case-16 snapshot (≈527-528) + post-snapshot write (≈529) + fabricated row shape (≈533-540), changing only `critical_files_confirmed` → Stop
- The main-path scope-check-throw handling is the `catch` at ≈1889-1893 (`$scopeCheckThrew=$true`); `$scopeCheckThrew` feeds `$criticalViolation` ONLY on the build+workspace-write post-hoc path (`-or $scopeCheckThrew` at ≈1946, inside the `if ($scopeCheckArmed)` branch at ≈1941), and other completion paths null `$criticalViolation` at ≈1958-1960 — so the fail-closed equivalence holds specifically on the build post-hoc path (throw → exit 77 unless outranked), NOT universally. The adopt live-replay throw handling is the `catch` at ≈824-830 (`$adoptScopeExit=1` → scope violation → exit 65) → impact: the Task-3 comment pair scopes the coupling to the build post-hoc path and notes both fail closed on a scope-check throw; the exit codes differ (77 vs 65) — the pinned equivalence is the fail-closed intent on that path, not a shared exit code → Caution
- In `codex-scope-check.ps1` the `-WrittenPathsFile` attribution loop is duplicated: a collecting branch (≈651-703, `if ($collectWritten)`) and a non-collecting branch (≈704-738, `else`), whose GONE/untouched/isDirty classification (≈671-702 vs ≈709-736) is line-for-line identical except for the `[void]$writtenSet.Add($n)` calls → impact: the Task-3 comment pair notes the classification logic must stay identical between the two branches → Caution

Simplicity check: considered folding both new cases into one task, and folding the two scope-check-check duplications into a single shared helper. Rejected the merge of tasks — the two cases append to the same file and are kept as separate tasks only to keep each self-contained (its own fixture + suite run); rejected the de-duplication refactor — this spec closes review DEBT with coverage + comments; extracting the attribution loop into a helper is a behavior-touching refactor out of scope for a comments-only guard, and the c2 review asked for coupling notes, not a rewrite.

## Prerequisites
- Specs complete first: **round8-c2-dispatch-binding** (SHIPPED) — it introduced the pin-first read path, the adopt exit-77 rung, and the two duplications this spec covers. Already merged to the live tree.
- Environment setup required: none. Isolated worktree copy of the `.claude` tree (the harness under edit is the harness doing the dispatching — build in an isolated worktree, ADR-044 isolation contract X1–X4).

## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| skills/apex-code/scripts/dispatch-criticalfile-test.ps1 | modify | Bump fixture loop to `1..19`; add case 18 (pin-first real-pin binding, exit 0) and case 19 (adopt live-replay exit 77); 17→19 assertions. |
| skills/apex-code/scripts/codex-dispatch.ps1 | modify | Comments ONLY: lockstep note at the main-path scope-check-throw `catch` (≈1889-1893) and the adopt live-replay throw `catch` (≈824-830). Byte-identical behavior. |
| skills/apex-code/scripts/codex-scope-check.ps1 | modify | Comments ONLY: lockstep note at the collecting (≈651-703) and non-collecting (≈704-738) attribution branches. Byte-identical behavior. |

## Tasks
- [ ] **Task 1** — Add the pin-first real-pin binding case to `skills/apex-code/scripts/dispatch-criticalfile-test.ps1`. Bump the fixture loop (≈320) to `foreach ($number in 1..18)` (fixture 18 needs no `ExtraFiles`; it follows the 12-15 seed-then-review pattern, both of which pass `SkipBaselineCheck` and need no `docs/changes` spec doc). After the case-17 block (≈571) append a new case: (a) seed a REAL build via `Invoke-DispatchCase -CaseName '18a seed real build for pin-first bind' -Spec 'critfile-review-pinfirst-bind' -Fixture $fixtures[18] -ExtraParameters @{ SkipBaselineCheck = $true } -FakeEnvironment @{ FAKE_CODEX_INSCOPE_ONLY = '1' }`, mirroring 13a (≈464-466); capture `$buildRow = @($build.Rows | Where-Object { $_.phase -eq 'build' }) | Select-Object -First 1`. Do NOT rewrite the ledger digest — the recorded `end_tree_digest` is the real one to match. (b) Dispatch the review with a REAL pin — pass NEITHER `NoTreePin` NOR `TreePinScript` — using `-FakeRepo $reviewSink.Path -FakePath $cleanReviewFake` (so the review's report is CLEAN and its writes land in the sink, leaving `$fixtures[18]` unmoved so `tree-pin -Verify` at ≈1929 passes): `Invoke-DispatchCase -CaseName '18b review binds via real pin file' -Spec 'critfile-review-pinfirst-bind' -Fixture $fixtures[18] -FakeRepo $reviewSink.Path -FakePath $cleanReviewFake -Authorized @() -ExtraParameters @{ Phase = 'review'; Schema = 'review'; ReviewedRunId = [string]$buildRow.run_id } -FakeEnvironment @{ FAKE_CODEX_VERDICT = 'CLEAN' }`. (c) Assert: `$build.ExitCode -eq 0` AND `$result.ExitCode -eq 0` AND `$result.Rows.Count -eq 2` AND the review row's `reviewed_tree_digest -ceq [string]$buildRow.end_tree_digest` AND the review row's `tree_pin_override -eq $false` (the property is created on every reserved row at ≈1247; with no `-TreePinScript` its value is `$false`, not absent). Use `Assert-Case` with a `-Detail` string built from per-record fields only (no `Out-String`). files: skills/apex-code/scripts/dispatch-criticalfile-test.ps1 — done when: the suite runs 18 assertions and exits 0; the real-pin review reaches exit 0 through the `if ($treePinArmed)` pin-file read (≈1458-1463) — proven by `reviewed_tree_digest` equalling the seeded build's `end_tree_digest` with `tree_pin_override -eq $false`.
- [ ] **Task 2** — Add the adopt live-replay exit-77 case to `skills/apex-code/scripts/dispatch-criticalfile-test.ps1`. Bump the fixture loop from `1..18` to `1..19`. After the Task-1 case append a new case modeled EXACTLY on case 16 (≈523-548), changing only the recorded confirmation: (a) `$spec = 'critfile-adopt-critical-unconfirmed'`; `$scopeTask = 'fabricated-adopt-77-replay'`; take a real scope snapshot over `$fixtures[19]` `-Authorized @('src')` into the gate state dir (mirror ≈525-528), throwing on non-zero. (b) Make the post-snapshot in-scope critical write: via `Add-Content`, create a file named `package-lock.json` inside the fixture's `src` subdirectory (build the path with `Join-Path` from `$fixtures[19].Path`, then `src`, then the lockfile name — no literal combined path in code is required), content `'adopted critical write'` (in-scope under `src`, classified `deps`/CRITICAL, exit 10). (c) Write a `done` report JSON listing that same fixture-relative lockfile path (`src` + `package-lock.json`) as changed (mirror ≈530-531) and a fabricated dead `build`-phase ledger row via `Add-FabricatedLedgerRow` identical to case 16's (≈533-540) EXCEPT `critical_files_confirmed = $false` (and drop the `critical_files_confirmed_note`), with `scope_armed = $true`, `scope_task = $scopeTask`, `authorized = @('src')`, and `scope_exit`/`ended` ABSENT so the live `-Check` replay branch (≈811-840) runs. (d) `Invoke-DispatchCase -CaseName '19 adopt live replay unconfirmed critical' -Spec $spec -Fixture $fixtures[19] -ExtraParameters @{ Adopt = $true; CriticalFilesScript = $criticalFiles }`. (e) Assert `$result.ExitCode -eq 77` AND `$row.status -eq 'adopted-done'` AND `$row.critical_violation -eq $true` (the terminal update at ≈900-912 records both before the exit-77 rung at ≈928-931). files: skills/apex-code/scripts/dispatch-criticalfile-test.ps1 — done when: the suite runs 19 assertions and exits 0; the adopt live-replay over an unconfirmed post-snapshot critical write drives exit 77 with `critical_violation:true` and `status=adopted-done` recorded. (Build after Task 1 — same file, sequential.)
- [ ] **Task 3** — Add lockstep coupling comments at both halves of each of the two known duplications. Comments ONLY — no token of executable code changes; the dispatch suite and the scope-check suite must stay byte-behavior-identical. (a) In `skills/apex-code/scripts/codex-dispatch.ps1`: at the main-path scope-check-throw `catch` (≈1889-1893) add a short comment noting it is the lockstep sibling of the adopt live-replay throw `catch` (≈824-830) — both fail closed on a scope-check throw. Scope the note precisely: on the main path a throw fails closed ONLY on the build+workspace-write post-hoc path, where `$scopeCheckThrew` feeds `critical_violation` via `-or $scopeCheckThrew` at ≈1946 (inside `if ($scopeCheckArmed)` ≈1941) → exit 77 unless outranked; the adopt sibling sets `$adoptScopeExit=1` → exit 65. Do NOT describe the two as universally equivalent catches (other completion paths null `$criticalViolation` at ≈1958-1960) — the coupling being pinned is the fail-closed intent on the build post-hoc path, not a shared exit code. Add the mirror comment at the adopt `catch` (≈824-830) pointing back. (b) In `skills/apex-code/scripts/codex-scope-check.ps1`: at the collecting branch (`if ($collectWritten)`, ≈651) and the non-collecting branch (`else`, ≈704) of the attribution loop, add a short comment at each noting the two branches differ ONLY in the `writtenSet` accumulation and that the GONE/untouched/isDirty classification (≈671-702 vs ≈709-736) must stay line-for-line identical between them. files: skills/apex-code/scripts/codex-dispatch.ps1, skills/apex-code/scripts/codex-scope-check.ps1 — done when: each of the four sites carries a one-to-three-line lockstep comment naming its sibling by role; no behavior change (the dispatch suite, the criticalfile suite, the family-gate suite, and the scope-check suite all still exit 0). (Runs LAST and alone — its edit to codex-dispatch.ps1 must not race Task 2's suite run, which executes that file; verified against the completed 19-assertion suite.)

## Wave plan
Wave 1: [Task 1] | Wave 2: [Task 2] | Wave 3: [Task 3]
<!-- Strictly sequential. Tasks 1 and 2 both append to dispatch-criticalfile-test.ps1 and Task 2 builds on Task 1's fixture-loop bump. Task 3 must run LAST and alone: it edits codex-dispatch.ps1, which Task 2's suite run EXECUTES (via a dispatch) — running them together would race a live edit against a suite invocation. Ordering Task 3 last also means its comment-only edit is verified against the finished 19-assertion suite. -->

## Permissions

The following actions will run autonomously during build.
Approving this spec approves all of them.

### File Operations
| Action | Paths |
|--------|-------|
| Create | (none) |
| Modify | skills/apex-code/scripts/dispatch-criticalfile-test.ps1, skills/apex-code/scripts/codex-dispatch.ps1, skills/apex-code/scripts/codex-scope-check.ps1 |
| Delete | (none) |

### Commands
| Command | Purpose |
|---------|---------|
| `powershell.exe -NoProfile -File .\skills\apex-code\scripts\dispatch-criticalfile-test.ps1` | Critical-file + review-launch suite incl. the two new cases (X2). |

All non-regression suites (dispatch, family-gate, scope-check) are run via the fenced Verify commands block below — approving this spec approves that block.

### Verify commands
Run from the worktree root (X2) — the `.claude` repo verify contract (worktree AGENTS.md `## Verify commands`), plus the target/regression suites:

```
node --check hooks/destructive-command-guard.js
node --check hooks/lib/destructive-detect.js
python hooks/destructive-guard-test.py
powershell.exe -NoProfile -File skills/apex-code/scripts/baseline-check-test.ps1
powershell.exe -NoProfile -File skills/apex-code/scripts/spec-validate-test.ps1
powershell.exe -NoProfile -File skills/apex-code/scripts/dispatch-preflight-test.ps1
powershell.exe -NoProfile -File skills/apex-code/scripts/dispatch-criticalfile-test.ps1
powershell.exe -NoProfile -File skills/apex-code/scripts/dispatch-test.ps1
powershell.exe -NoProfile -File skills/apex-code/scripts/family-gate-test.ps1
powershell.exe -NoProfile -File skills/apex-code/scripts/scope-check-test.ps1
```

### Git Operations
| Operation | Scope |
|-----------|-------|
| (none) | The builder performs no git operations; the host integrates the worktree diff and commits (X3). |

_Host integration-commit message: `test(dispatch): pin-first binding + adopt exit-77 coverage; lockstep comments (c2 review debt)`._

### Environment Access
| Variable | Purpose |
|----------|---------|
| `APEX_STATE_DIR` | Test isolation — scratch state/ledger root used by the suite (set/restored by the suite itself). |
| `FAKE_CODEX_*` | Fake-codex fixture control (`FAKE_CODEX_INSCOPE_ONLY`, `FAKE_CODEX_VERDICT`, `FAKE_CODEX_REPO`) — set/restored by the suite. |
| `GIT_CONFIG_GLOBAL` | Scratch git excludes/config for the fixture repos — set/restored by the suite. |

### Network
| Action | Purpose |
|--------|---------|
| (none) | No package installation. |

## Specialist Context
### Security
Both new cases harden the trust boundary c2 built. Case 18 is the FIRST test to execute the TOCTOU-free binding: a real `-Pin` arms the tree at review start and the compared digest is read from that same `treepin-v2` fingerprint (≈1459-1461), so no writer can move the tree between compare and pin — the property c2's security section claims but no prior test exercised. Case 19 proves the adopt path fails closed on an unconfirmed post-hoc critical write exactly as the main path does (exit 77), using the ROW's recorded `critical_files_confirmed` (never the adopt invocation's own switch). The Task-3 comments defend against the specific regression this file has shipped repeatedly — "two copies of one rule, the weaker fails open" — by naming each duplication's sibling so a future editor cannot un-couple them silently. No production behavior changes, so no new attack surface.

### Performance
(none) — two additional fixture repos and two dispatches; the suite already creates 17.

### Accessibility
(none)

## Documentation
| Doc type | File | Action |
|----------|------|--------|
| Inline | skills/apex-code/scripts/codex-dispatch.ps1 | Lockstep comment pair at the two scope-check-throw `catch` sites. |
| Inline | skills/apex-code/scripts/codex-scope-check.ps1 | Lockstep comment pair at the two attribution-loop branches. |
| ADR | (none) | No design change; c2/ADR-044 already carry the shipped behavior. |

## Acceptance Criteria
- [ ] **Task 1** → verify: `powershell.exe -NoProfile -File .\skills\apex-code\scripts\dispatch-criticalfile-test.ps1` runs the pin-first case — a real-pin review (no `-NoTreePin`, no `-TreePinScript`) over a seeded real build reaches exit 0, records `reviewed_tree_digest` equal (`-ceq`) to the build's `end_tree_digest`, and carries `tree_pin_override:false` — proving the `if ($treePinArmed)` pin-file read path (≈1458-1463) executed; the suite exits 0 at 18 assertions.
- [ ] **Task 2** → verify: the same suite runs the adopt live-replay case — a fabricated dead `build`-phase row with `critical_files_confirmed=false` plus a post-snapshot in-scope critical write (a `package-lock.json` under the fixture's `src` subdirectory) drives exit 77 with `critical_violation:true` and `status=adopted-done` recorded on the row; the suite exits 0 at 19 assertions.
- [ ] **Task 3** → verify: `codex-dispatch.ps1` carries a lockstep comment at both the main-path scope-check-throw `catch` (≈1889-1893) and the adopt live-replay throw `catch` (≈824-830); `codex-scope-check.ps1` carries one at both attribution branches (≈651, ≈704); no executable byte changed — `dispatch-test.ps1` (14), the criticalfile suite (19), and `family-gate-test.ps1` (34) all exit 0.

## Host verification
Host integrates the worktree diff into the live `.claude` tree with NO gates open (X3), then re-runs on the live tree: `dispatch-criticalfile-test.ps1` (now 19 green), `dispatch-test.ps1` (14 green), `family-gate-test.ps1` (34 green), and (non-regression) `scope-check-test.ps1`, `tree-pin-test.ps1`, and `dispatch-preflight-test.ps1` — all exit 0. Host verification is the authoritative acceptance gate; the builder's green is necessary, not sufficient. No `harness-known-limits.md` change is required (this spec adds coverage + comments, not behavior); no `SKILL-HISTORY.md` row (no skill frontmatter change).

## Progress
_(Coding mode writes here — do not edit manually)_
