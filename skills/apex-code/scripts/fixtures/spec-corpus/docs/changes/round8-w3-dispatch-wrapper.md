---
spec: round8-w3-dispatch-wrapper
status: draft
autonomy_level: L2
coder_model: codex
coder_effort: xhigh
cross_model_review: true
max_parallel_codex: 1
---

# Spec: Round-8 Wave 3 — dispatch wrapper fail-open / bypass / correctness fixes

**Identity:** Closes 10 fail-open, bypass, and correctness defects in the Codex dispatch wrapper `codex-dispatch.ps1`, repairs its always-green test harness `dispatch-test.ps1`, and realigns two existing fixtures that the coupling changes invalidate. Three further defects (original items 3 and 8, plus a family-gate hole surfaced by cross-family review) need design, not a mechanical patch, and are recorded under Deferred. Windows PowerShell 5.1, no build step.

## Intent
- **Intent:** Every gate the wrapper claims to enforce (empty-scope refusal, critical-file classifier, baseline/spec pre-flight, scope check, tree pin, family-aware review, completion-status verdict) must actually fire on the paths that currently skip or misreport it. A careless coder — the standing threat model, NOT a hostile one — must not reach a workspace-write launch, a `done` success row, or an accepted cross-family review through a typo, a decoupled flag, a malformed ledger row, or a warn-and-continue write failure.
- **Invariants:** (1) fail CLOSED on every uncertainty — an unrecognized phase/status/verdict, a malformed reservation row, or a failed ledger write refuses rather than proceeds; (2) each of the 10 fixes is INDEPENDENT and must not regress the other nine, any already-correct path, or the exit-code contract; (3) the exit-code contract is preserved verbatim — no code is renumbered and new refusals REUSE existing codes (74 caller-contract, 72 pre-flight, 71 live-scan, 69 tree-pin void, 67 fail-closed-blocked); (4) `dispatch-test.ps1` returns non-zero when any check fails and holds a RED-before-GREEN case for each fix. Items 11 and 12 (reason + ledger annotation on `-AllowSharedWorktree` / `-NoTreePin`) extend ADR-041 (wrapper hardening) — no new ADR.
- **Non-goals:** Do NOT touch the documented threat-model escape hatches left deliberately unfixed: `-CriticalFilesScript`, `-CodexExecutable` / `-CodexExecutableArgumentPrefix`, base64/dot-source test overrides. Those are attended, host-only test seams, not careless-coder surfaces. No behavioural change to the async pipe pump, the deadlock fix, the encoding gate, or the state-dir isolation logic. Do NOT attempt the three Deferred items — they are out of scope for this wave.

## Assumptions
- Live callers dispatch only two phases, `build` and `review`; end-gates travel as `-Schema endgate`, NOT as a phase (the reviewer ledger fields at 880-881 key on `$Schema -eq 'endgate'`). The `-Phase` validation must accept exactly `build` and `review` and reject everything else → impact: Stop (a too-narrow phase set breaks live dispatch; grep apex-code / apex-build-wave / apex-orchestrate for `-Phase` to confirm no third phase is passed).
- The completion schema's `status` enum is exactly three tokens — `done`, `done_with_concerns`, `blocked` (there is NO `failed` token; the earlier draft's assumption was wrong). The review/end-gate schema carries `verdict`, not `status`. Read `codex-completion-schema.json` and `codex-review-schema.json` to confirm the exact tokens the allowlist keys on → impact: Caution.
- The ledger is append-only JSONL keyed by `run_id`; `Update-LedgerRow` rewrites atomically under the named mutex; `Test-LedgerRowLive` (328-341) expires an unverifiable row only after a 12-hour corpse ceiling → impact: Caution (the malformed-row fix reuses that same ceiling).

Simplicity check: considered splitting the 10 wrapper fixes across parallel workers — rejected: all 10 land in ONE file (`codex-dispatch.ps1`), so parallel workers would clobber each other. One coder, one file, one wave; the test files follow in a second wave.

## Deferred (need design)
These three defects are real and stay open. Each needs a design decision, not a mechanical edit, so none is attempted in this spec. Revisit next planning pass.

- **Deferred A — spec-resolution fail-closed (was Fix 3).** Refusing a build whose spec does not resolve under the build worktree looked like an edge-case hardening, but the two-tree layout (specs authored in `~/apex`, the build worktree under `~/.claude`) makes "spec not under the worktree" the NORMAL APEX self-build path, not an anomaly. Failing it closed breaks the standard build model. A correct fix needs a first-class `-SpecSourcePath` parameter and rewiring of every dispatch caller to pass it, and plan-time `apex-spec-validate` already covers the careless-unresolvable case. Design the parameter and caller wiring first.
- **Deferred B — bind a review to the build it reviewed (was Fix 8).** `worktree_key` + `base_sha` cannot identify a build ATTEMPT: two uncommitted builds in the same worktree share both values, so a review of attempt A would still validate against attempt B — the exact hole the bind was meant to close. A correct bind needs a durable per-attempt build identity (a tree/diff digest recorded at launch) that does not exist to bind to yet. Design the identity first, then the bind.
- **Deferred C — family gate accepts a bound-but-VOID review (surfaced by cross-family review).** When a CLEAN review's tree moved, the wrapper records `status:done, tree_moved:true` and then exits 69 (VOID). But `apex-family-gate.ps1` (164-203) accepts a terminal `done` review row and never inspects `tree_moved`, so a void review still satisfies the cross-family gate. The fix lives in a different file (`apex-family-gate.ps1`), so it is out of this wrapper-scoped wave. Important — carry it to the next wave.

## Prerequisites
- Specs that must be complete first: none.
- Environment setup required: none (pure PowerShell; the validator and the test files already exist beside the target).

## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| C:\Users\User\.claude\skills\apex-code\scripts\codex-dispatch.ps1 | modify | the 10 wrapper fixes |
| C:\Users\User\.claude\skills\apex-code\scripts\dispatch-test.ps1 | modify | fix always-0 exit + add isolated APEX_STATE_DIR + one RED-before-GREEN case per fix |
| C:\Users\User\.claude\skills\apex-code\scripts\review-findings-test.ps1 | modify | realign case #10 for the Fix 2 phase/schema coupling |
| C:\Users\User\.claude\skills\apex-code\scripts\careless-coder-test.ps1 | modify | realign case #9 for the Fix 12 reason requirement |

## Tasks

- [ ] **Task 1: apply the 10 fixes to `codex-dispatch.ps1`** — files: C:\Users\User\.claude\skills\apex-code\scripts\codex-dispatch.ps1 — done when: all 10 mechanisms below are in place, the exit-code contract is unchanged, and no previously-correct path regresses. Each fix is independent; fail closed on uncertainty. State each fix's producing mechanism, not just its outcome.

  - **Fix 1 — `-Phase` accepts any string** (param line 14 `[string]$Phase`). A typo like `-Phase buid` slips past every `$Phase -eq 'build'` / `'review'` branch (empty-scope refusal, critical-file + baseline/spec pre-flight, review→read-only forcing) and launches workspace-write ungated. MECHANISM: do NOT use `[ValidateSet]` — in PowerShell 5.1 a ValidateSet failure exits 1 BEFORE the body runs, colliding with the wrapper's existing exit-1 "child failure" meaning, so a typo would masquerade as a build failure. Instead validate `-Phase` IN-BODY, early, mirroring the pre-reservation refusals at 68-75: accept only `build` and `review`; any other value refuses with exit 74 (caller-contract), which is distinguishable from a child failure. `endgate` is a `-Schema` value, NOT a phase (880-881 key on `$Schema -eq 'endgate'`) — do not add it to the phase set.

  - **Fix 2 — phase / schema / sandbox decoupled, BOTH directions** (anchors: review→read-only forcing 652-659; reviewer ledger fields 879-881; verdict guard 1277). Today the coupling is one-directional and leaves two holes. MECHANISM, made bidirectional and enforced before reservation: (a) a `review` phase (or `-Schema review` / `-Schema endgate`) MUST use the review/endgate schema AND a read-only sandbox AND record a real verdict — so `-Phase review` paired with the default `completion` schema refuses (exit 74) rather than stamping `reviewer_family` + `reviewed_run_id` on a status-only `done` row the family gate would read as a review that never happened; and reuse the runtime verdict guard at 1277 so a review/end-gate report carrying no verdict resolves to `blocked` (exit 67), never a bare `done`. (b) INVERSELY, a `build` phase MUST run the build pre-flight gates AND be writable — refuse (exit 74) a `build` phase paired with a read-only sandbox OR with a non-`completion` schema, because `-Phase build -Sandbox read-only -Schema completion` (or `-Phase build -Schema review`) otherwise skips the empty-scope/build pre-flight yet records `phase:build, builder_family:<x>, status:done`, a FAKE BUILD row the family gate accepts. Both directions refuse the mismatch before any reservation is written.

  - **Fix 4 — completion statuses not allowlisted, scoped + case-sensitive + correct enum** (anchors: main path ~1218 and final mapping 1315-1316; adoption 446 and 497; coupling 1292-1297). An exit-0 child writing `{}` or `{"status":"garbage"}` leaves `$reportStatus` empty/unrecognized, no coupling fires, `$status` stays `done`, and the run records success; adoption likewise passes any nonempty `status` through to exit 0. MECHANISM: (i) apply the status allowlist ONLY to COMPLETION-schema reports — review schemas carry no `status`, so applying it there would block every legitimate CLEAN review; (ii) compare CASE-SENSITIVELY (`-ceq` or a case-sensitive set — `-in` / `-contains` are case-insensitive, so `DONE` would slip an unintended token through); (iii) the allowlist is the exact three-token enum `done`, `done_with_concerns`, `blocked` (NOT `failed`); (iv) any status outside the allowlist, including empty on a present-but-garbage report from an exit-0 child, resolves to `blocked` (fail closed, exit 67) on BOTH the main path and `Invoke-Adopt`.

  - **Fix 5 — malformed ledger row skipped in the live-worker scan, TTL-bounded + non-overridable** (anchors: `Get-LiveDispatches` line 355 `catch { continue }`; 12-hour corpse ceiling in `Test-LedgerRowLive` 328-341; reservation refusal path 901-928; per-row formatter 915-927; the live-scan gate `-not $AllowSharedWorktree`). A partially-written or corrupt row makes the scan see no live reservation, so a second dispatch launches into a tree that may already hold a live coder. A line that fails to parse cannot be proven terminal or proven to belong to another worktree, so it MUST fail closed. MECHANISM, with two required guards: (a) TTL-bound the blast radius with the SAME 12-hour ceiling `Test-LedgerRowLive` uses — best-effort recover a timestamp from the raw line (the `started` instant, extracted by regex from the unparsed text); a malformed line whose recovered age exceeds 12 hours is ignored as a corpse, so one stale corrupt line cannot wedge every future dispatch on the machine forever; a line that is fresh, or whose timestamp cannot be recovered, fails closed. (b) the malformed-line refusal is a SEPARATE, NON-OVERRIDABLE check — do NOT surface it as an item in `$liveHere`, because `$liveHere` is gated by `-not $AllowSharedWorktree`, so `-AllowSharedWorktree -AllowSharedWorktreeReason x` would bypass it; parse uncertainty is not an intentionally-shared reservation. Refuse with a distinct exit-71 message naming the bad line ("a ledger line could not be parsed: <raw, truncated>"), NOT the per-row spec/task/pid formatter at 915-927 (which would print blanks for an unparsed row).

  - **Fix 6 — adoption does not replace dead PIDs, and races a second adopter** (anchors: selection-lock release ~404; the liveness refusal ~421; PID replacement at 505). Invoke-Adopt releases the selection lock at ~404, parses the report, THEN claims the row at 505 — so a dispatcher in that window sees the dead PIDs and launches, and a second adopter can select an already-`adopting` row because the liveness refusal at ~421 excludes that status. MECHANISM: (a) replace `launcher_pid` + `launcher_start` and `pid` + `pid_start` with the ADOPTER's `$PID` and `Get-ProcessStamp $PID` UNDER the selection lock (~404), before the lock is released, so the reservation reads live for the whole adoption; (b) make the liveness refusal at ~421 INCLUDE `adopting` status so a second adopter cannot grab a row already being adopted.

  - **Fix 7 — adoption ledger-update errors only warn, BOTH write sites** (anchors: the `adopting` update at 508; the terminal `adopted-*` close at 591-597). Both currently use `try {...} catch { Write-Host WARNING }`, so a failed write leaves clean gates + a `done` report exiting 0 while the row stays nonterminal or undurable. MECHANISM: fail CLOSED at BOTH sites — replace warn-and-continue with a throw (non-zero exit, harness-failure semantics) at the `adopting` reservation (~505-508) AND the terminal `adopted-*` close (~591-597). Adoption must never report success on a run it could not durably close.

  - **Fix 9 — `-SkipScopeCheck` records `scope_armed:false` but still arms** (anchors: 872 vs 939-950; `-Adopt` gate at 522/528). `scope_armed` is computed as `($Authorized.Count -gt 0 -and -not $SkipScopeCheck)`, but the snapshot and `$scopeCheckArmed` arm whenever `$Authorized.Count -gt 0` regardless of `-SkipScopeCheck`, so with `-SkipScopeCheck` the check really is armed while the ledger says `false`, and `-Adopt` (gated on `$match.scope_armed`) skips available scope evidence. MECHANISM: set `scope_armed` to the actual arming condition `$Authorized.Count -gt 0` (matching `$scopeCheckArmed`) so `-Adopt` replays the evidence. `-SkipScopeCheck` only silences the no-Authorized note at 955 — do not change that.

  - **Fix 10 — log filename omits run id and is truncated before the reservation check** (anchors: 824 filename, 826 truncation; reservation 901-928; `$finalPath` 845, `$gateKey` 831). The log path `codex-$safeSpec-$safeTask-$worktreeTag.log` carries no run id and line 826 truncates it BEFORE the exit-71 reservation refusal, so a second same-spec/task/worktree dispatch erases the active run's log, refreshes its mtime (resetting the live run's no-output watchdog), then gets refused anyway. MECHANISM: generate `$runId` before the log path and add `$($runId.Substring(0,8))` to the filename (parallel to 845/831) so no dispatch can truncate another's log; the ledger's `log_path` then carries the unique name. Deferring truncation until after the reservation passes is an acceptable alternative, but the run-id filename is preferred — it also disambiguates observability.

  - **Fix 11 — `-AllowSharedWorktree` silently disables the live-worker refusal** (anchors: param line 31; used at 903 `-and -not $AllowSharedWorktree`). One flag lets two builds with overlapping authorized files write one tree, last-writer-wins, against mandated isolation. MECHANISM (keep the escape hatch, make it deliberate + traced): add `-AllowSharedWorktreeReason [string]`; refuse (exit 74) if `-AllowSharedWorktree` is passed without a non-empty reason (mirror the `-ScopeUnlocked` / `-ScopeUnlockedReason` refusal at 72-75); when used, annotate the ledger row (`shared_worktree = $true`, `shared_worktree_reason = <reason>`) and print a loud warning. Extends ADR-041.

  - **Fix 12 — `-NoTreePin` silently disables the read-only gate pin** (anchors: param line 34; used at 973/977). A review can return CLEAN after the tree moved, unverified, with no reason or trace. MECHANISM: same shape as Fix 11 — add `-NoTreePinReason [string]`; refuse (exit 74) if `-NoTreePin` is passed without a non-empty reason; annotate the ledger row (`tree_pin_disabled = $true`, `tree_pin_disabled_reason = <reason>`) and warn loudly. Extends ADR-041.

- [ ] **Task 2: repair `dispatch-test.ps1` and add a RED-before-GREEN case per fix** — files: C:\Users\User\.claude\skills\apex-code\scripts\dispatch-test.ps1 — done when: the harness exits non-zero if any check fails, every new case runs under an isolated state dir, and each of the 10 fixes has a case that is RED against the unmodified wrapper and GREEN after Task 1.
  - FIRST: fix the always-0 exit. The `Check` helper (62-66) only prints; the script ends at `Pop-Location` with no `exit`, so it certifies whatever it runs. MECHANISM: add a module-scoped failure accumulator (`$script:failCount`), increment it inside `Check` on every FAIL, and end the script with `if ($script:failCount -gt 0) { exit 1 } else { exit 0 }` (PowerShell 5.1 — explicit if/else, no ternary). This is load-bearing: without it the suite cannot prove the fixes.
  - ISOLATION: every new or changed case MUST run under an isolated `APEX_STATE_DIR` (the pattern at dispatch-preflight-test.ps1:22-24,246-248), NOT the unisolated dispatch-test.ps1 pattern — especially the Fix 5 corrupt-line case, since an unisolated corrupt-ledger test could wedge the real machine-global ledger.
  - RED CAPTURE: because Task 1 (wrapper) lands before Task 2 (tests), the coder captures RED evidence by running each new case against the UNMODIFIED wrapper — `git stash` (or `git checkout`) the `codex-dispatch.ps1` fix, run the case to observe RED, then restore the fix and observe GREEN. State this ordering explicitly in the run notes; without it the order cannot show RED.
  - THEN add one focused case per fix (10), each asserting fail-closed / correct behaviour: `-Phase buid` refuses at exit 74, `-Phase build` / `-Phase review` still dispatch (Fix 1); `-Phase review` + default completion schema refuses at 74, a build phase with a read-only sandbox or a non-completion schema refuses at 74, and no review row closes as a bare `done` (Fix 2); an exit-0 child writing `{}` / `{"status":"garbage"}` yields `blocked` (exit 67) on both the main and adopt paths, and a CLEAN review is NOT blocked by the allowlist (Fix 4); a corrupt in-worktree ledger line makes a second same-worktree dispatch refuse at 71 naming the bad line, and the refusal is not bypassed by `-AllowSharedWorktree` + reason (Fix 5); an `adopting` row reads live to a concurrent scan and a second adopter is refused (Fix 6); a forced adoption ledger-write failure exits non-zero at BOTH the adopting and terminal-close sites (Fix 7); with `-Authorized` + `-SkipScopeCheck` the row records `scope_armed: true` (Fix 9); a second same-spec/task/worktree dispatch does not truncate the first run's log (Fix 10); `-AllowSharedWorktree` without a reason refuses at 74 and with one is annotated (Fix 11); `-NoTreePin` without a reason refuses at 74 and with one is annotated (Fix 12). For Fix 7's terminal-close (591-597), use a deterministic fault hook — make the first ledger write succeed and the terminal write fail by rendering the ledger path unwritable at the close moment (for example replacing the ledger file with a directory, or holding an exclusive handle, after the adopting update lands); if no clean hook is reachable, mark that specific site inspection-verified with a written rationale rather than assert it. Reuse the existing fake-codex seam (`dispatch-test-fakecodex.ps1`, `-CodexExecutable` / `-CodexExecutableArgumentPrefix`) and repo scaffold; keep each case isolated so one failure does not mask the rest.

- [ ] **Task 3: realign the two fixtures the coupling changes invalidate** — files: C:\Users\User\.claude\skills\apex-code\scripts\review-findings-test.ps1 C:\Users\User\.claude\skills\apex-code\scripts\careless-coder-test.ps1 — done when: both suites pass GREEN against the Task 1 wrapper without weakening what they test. In `review-findings-test.ps1` case #10 (line 177) the dispatch passes `-Phase review` with the DEFAULT completion schema and expects exit 69 (tree-pin VOID); under Fix 2 that pairing now refuses at 74 before the tree-pin gate is reached, so add `-Schema review` to that dispatch so it still exercises the read-only review path and keeps the exit-69 assertion. In `careless-coder-test.ps1` case #9 (line 92) the dispatch passes `-NoTreePin` with no reason and expects the unrecognized-verdict block at exit 67; under Fix 12 a reasonless `-NoTreePin` now refuses at 74, so add a non-empty `-NoTreePinReason` (e.g. a short test rationale) so the case still reaches and asserts the exit-67 verdict block. Do not alter the exit-69 / exit-67 assertions themselves — only the dispatch invocation.

## Wave plan
Wave 1: [Task 1] | Wave 2: [Task 2, Task 3]

## Permissions

The following actions will run autonomously during build.
Approving this spec approves all of them.

### File Operations
| Action | Paths |
|--------|-------|
| Create | (none) |
| Modify | C:\Users\User\.claude\skills\apex-code\scripts\codex-dispatch.ps1 · C:\Users\User\.claude\skills\apex-code\scripts\dispatch-test.ps1 · C:\Users\User\.claude\skills\apex-code\scripts\review-findings-test.ps1 · C:\Users\User\.claude\skills\apex-code\scripts\careless-coder-test.ps1 |
| Delete | (none) |

### Commands
| Command | Purpose |
|---------|---------|
| `powershell.exe -NoProfile -File dispatch-test.ps1` | Run the repaired harness from the scripts dir — non-zero RED before Task 1, exit 0 GREEN after |
| `powershell.exe -NoProfile -File review-findings-test.ps1` | Confirm the realigned case #10 stays GREEN under Fix 2 |
| `powershell.exe -NoProfile -File careless-coder-test.ps1` | Confirm the realigned case #9 stays GREEN under Fix 12 |
| `powershell.exe -NoProfile -File apex-spec-validate.ps1` | Validate this spec (exit 0) — exact invocation with the draft's full path below |

Validator invocation (full paths — the spec lives under `docs/drafts/`, not beside the script):

```
powershell.exe -NoProfile -File "C:\Users\User\.claude\skills\apex-code\scripts\apex-spec-validate.ps1" -SpecPath "C:\users\user\apex\docs\drafts\round8-w3-dispatch-wrapper.md"
```

### Git Operations
| Operation | Scope |
|-----------|-------|
| `git add` | (none — host stages and commits) |
| `git commit` | (none) |

### Environment Access
| Variable | Purpose |
|----------|---------|
| `LOCALAPPDATA` / `TEMP` / `APEX_STATE_DIR` | Locate the machine-local ledger, logs, and gate state; the new test cases set an isolated `APEX_STATE_DIR` so they never touch the real global ledger |

### Network
| Action | Purpose |
|--------|---------|
| (none) | No network access |

## Specialist Context
### Security
These are fail-open / bypass defects: every fix must fail CLOSED on uncertainty and open no new bypass. Threat model is a careless coder, not a hostile one — the `-CriticalFilesScript` / `-CodexExecutable` / base64 / dot-source test seams are deliberately left in place and out of scope. Fix 5 is deliberately non-overridable: an unparseable reservation row is not an intentionally-shared worktree, so `-AllowSharedWorktree` must not silence it.

### Performance
(none)

### Accessibility
(none — no frontend surface)

## Documentation
| Doc type | File | Action |
|----------|------|--------|
| Inline | C:\Users\User\.claude\skills\apex-code\scripts\codex-dispatch.ps1 | Keep the rationale comments accurate for each changed block; document the new `-AllowSharedWorktreeReason` / `-NoTreePinReason` params in the param-block comments |
| ADR | docs/technical/adr/ADR-041-*.md | No new ADR — items 11/12 extend ADR-041 (wrapper hardening); the extension is stated inline in Intent |

## Acceptance Criteria
- [ ] Task 1 lands the 10 wrapper fixes → verify: each mechanism below is present in `codex-dispatch.ps1`, the exit-code contract is unchanged, and no previously-correct path regresses.
- [ ] Task 2 repaired harness fails loudly → verify: `dispatch-test.ps1` exits non-zero on any FAIL (force one check false to confirm) and exits 0 only when all checks pass; every new case runs under an isolated `APEX_STATE_DIR`.
- [ ] Task 2 RED-before-GREEN holds → verify: each new case FAILS against the stashed/unmodified `codex-dispatch.ps1` and PASSES after Task 1's fixes land.
- [ ] Task 3 fixtures stay GREEN → verify: `review-findings-test.ps1` and `careless-coder-test.ps1` both pass against the Task 1 wrapper, with case #10 still asserting exit 69 and case #9 still asserting exit 67.
- [ ] Fix 1 → verify: `-Phase buid` is refused in-body at exit 74 (never param-binding exit 1); `-Phase build` / `-Phase review` still dispatch.
- [ ] Fix 2 → verify: `-Phase review` + default completion schema refuses at exit 74; a `build` phase with a read-only sandbox or a non-completion schema refuses at exit 74; no review row closes as a bare `done` without a verdict.
- [ ] Fix 4 → verify: an exit-0 child with `{}` or `{"status":"garbage"}` yields `blocked` (exit 67) on both the main and adopt paths; a legitimate CLEAN review is not blocked by the allowlist; comparison is case-sensitive.
- [ ] Fix 5 → verify: a corrupt active-worker ledger line makes a second same-worktree dispatch refuse (exit 71) naming the bad line; the refusal is not bypassed by `-AllowSharedWorktree` + reason; a corrupt line older than 12 hours is ignored.
- [ ] Fix 6 → verify: an `adopting` row reads live to `Get-LiveDispatches` because it carries the adopter's PID + stamp under the selection lock; a second adopter is refused.
- [ ] Fix 7 → verify: a forced adoption ledger-write failure exits non-zero at both the adopting and the terminal-close sites (no exit 0 on a nonterminal row).
- [ ] Fix 9 → verify: with `-Authorized` + `-SkipScopeCheck`, the ledger row records `scope_armed: true`.
- [ ] Fix 10 → verify: a second same-spec/task/worktree dispatch does not truncate the first run's log (distinct run-id filenames).
- [ ] Fix 11 → verify: `-AllowSharedWorktree` alone is refused (exit 74); with `-AllowSharedWorktreeReason` it proceeds and the row records the reason.
- [ ] Fix 12 → verify: `-NoTreePin` alone is refused (exit 74); with `-NoTreePinReason` it proceeds and the row records the reason.
- [ ] Exit-code contract intact → verify: no existing exit code (0/1/65/66/67/68/69/71/72/73/74/75/76/124) is renumbered; new refusals reuse existing codes.
- [ ] Spec validates → verify: `apex-spec-validate.ps1` on this spec exits 0.

## Progress
_(Coding mode writes here — do not edit manually)_
