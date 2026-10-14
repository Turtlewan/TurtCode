# System map
<!-- apex:system-map -->

`~/.claude` is the APEX runtime: 14 `apex-*` skills, four agents, Claude Code hooks, one workflow
script and the harness settings. Documentation, ADRs and the skill index live in the separate
`~/apex` tree (`AGENTS.md:5`). The repo ignores `*` and tracks files by name (`.gitignore:1`), so
only `git ls-files` paths are mapped. Executable code is Windows PowerShell 5.1 (the build
machinery under `skills/apex-code/scripts/` and `skills/apex-plan/scripts/`) plus Node hooks; the
rest is Markdown instructions that agents load. Surveyed at `0e3b863` plus the
`planning-gate-check` (`aaa4950`) and `critic-plan-inputs` (`30f0186`) builds. Live uncommitted
edits to `settings.json` were not surveyed. **Out of scope, not mapped:** the vendored and legacy trees `plugins/` (marketplaces),
`get-shit-done/`, `style-library/`, `skills-archived/` and `projects/` (memory); the non-APEX skills
`skills/brandkit/`, `skills/design-motion-principles/`, `skills/imagegen-frontend-mobile/` and
`skills/imagegen-frontend-web/`; and the pre-ADR-036 legacy docs `APEX-README.md` and
`APEX-CONTRIBUTING.md`, which still describe planning and coding modes and the domain skills.

## Repository contract and verify fence
<!-- apex:map-section covers: AGENTS.md package.json .gitignore contracts: AGENTS.md seams: AGENTS.md verified: 0e3b863ccc8623ef2919423131144988ebdf2d54 -->

**Role:** The coder's contract for this repo: the two-tree layout, the no-commit rule, and the
fenced verify and preflight recipes that the wrapper, Engine and HOST all execute.
**Contracts:**
- Two-tree layout (skills here, docs/ADRs in `~/apex`); coders never commit or push (`AGENTS.md:5`, `AGENTS.md:7`).
- `## Verify commands`: one unlabeled (cmd.exe) fence with 22 lines (node syntax checks, the Python
  guard test, and PowerShell suites, with `apex-drain-test.ps1` split into four `-Case` runs)
  (`AGENTS.md:9`, `AGENTS.md:11`-`AGENTS.md:34`).
- `## Preflight commands` is the cheap pre-dispatch subset: two `node --check` lines (`AGENTS.md:36`-`AGENTS.md:41`).
- `package.json` sets `{"type":"commonjs"}` so hooks can `require` each other (`package.json:1`).
- Ignore-all, then re-include only `.gitignore` (`.gitignore:1`-`.gitignore:2`); new files need `git add -f`.
**Seams:** Parsed by `apex-baseline-check.ps1` (grammar `skills/apex-code/scripts/apex-baseline-check.ps1:13`-`:19`)
for wrapper pre-flight and the pre-commit hook, and by the Engine's `Get-EngineVerifyFence`
(`skills/apex-code/scripts/engine-plan.ps1:328`, `skills/apex-code/scripts/engine-plan.ps1:873`).
Capped at 32768 bytes by the context cap guard (`hooks/context-cap-guard.js:33`).
**Dependents:** Codex coders (read AGENTS.md natively); the Engine's integrated verify; the drain; the HOST.
**Evidence:** The fence omits these suites: `dispatch-test.ps1`, `dispatch-scopelock-test.ps1`,
`dispatch-criticalfile-test.ps1`, `dispatch-deadlock-test.ps1`, `dispatch-encoding-utf8-test.ps1`,
`careless-coder-test.ps1`, `verdict-test.ps1`, `review-findings-test.ps1`, `family-gate-test.ps1`,
`critical-files-test.ps1`, `encoding-check-test.ps1`, `sibling-guard-test.ps1`,
`wave-scope-test.ps1`, `snapshot-scale-test.ps1`, `git-stderr-test.ps1`,
`hooks/codex-dispatch-guard.test.js` and `hooks/context-cap-guard.test.js`. Those suites run only when
someone invokes them directly.

## Session bootstrap and harness settings
<!-- apex:map-section covers: CLAUDE.md settings.json hooks/apex-session-context.md hooks/backend-session-start.ps1 contracts: hooks/apex-session-context.md CLAUDE.md settings.json seams: settings.json hooks/backend-session-start.ps1 verified: 30f018629943f96e659399c987e1172c18a334ed -->

**Role:** Loads the APEX session contract into every Claude Code session and registers every hook,
the status line, permissions and the default model.
**Contracts:**
- Session contract: the first action is `apex-orchestrate`, and the reply opens with the `[APEX] Using APEX system` banner
  (`hooks/apex-session-context.md:1`-`:13`). It also defines the single-session model (ADR-038)
  (`hooks/apex-session-context.md:15`), the four-role routing table (`hooks/apex-session-context.md:26`-`:34`),
  the three files with their caps (`hooks/apex-session-context.md:47`-`:58`), and specs as
  execution scripts (`hooks/apex-session-context.md:60`).
- `CLAUDE.md` holds cross-project preferences only: Cursor co-editing, the APEX pointer, and git rules with the
  PR-merge approval rule (`CLAUDE.md:8`, `CLAUDE.md:23`, `CLAUDE.md:33`-`CLAUDE.md:47`).
- Settings: allow-list including the ledger-append hook (`settings.json:3`, `settings.json:30`-`:31`),
  `defaultMode: acceptEdits` (`settings.json:48`), and model (`settings.json:54`).
**Seams:** SessionStart runs `backend-session-start.ps1`, plus an external
`claude-cockpit/hooks/mode-stamp.js` that lives outside this repo (`settings.json:56`-`:73`).
PreToolUse registers the destructive guard, the Codex guard and the cap guard
(`settings.json:74`-`:105`). PostToolUse registers the context monitor and the injection scanner
(`settings.json:106`-`:127`). The status line is at `settings.json:130`. The start script reads the
context file and appends the newest `docs/handoff/*.md` of the current directory as `additionalContext`
(`hooks/backend-session-start.ps1:12`-`:25`, `hooks/backend-session-start.ps1:29`-`:36`).
**Dependents:** Every session and subagent (CLAUDE.md); apex-orchestrate (routing trigger); all hooks below.
**Evidence:** The live tree has uncommitted settings edits (`defaultMode: auto`, `model: opus`, an
`autoMode.allow` rule for ledger appends); HEAD is cited.

## Command guards (destructive and raw Codex)
<!-- apex:map-section covers: hooks/destructive-command-guard.js hooks/codex-dispatch-guard.js hooks/lib/** hooks/destructive-guard-test.py hooks/codex-dispatch-guard.test.js contracts: hooks/lib/guard-disable.js hooks/lib/destructive-detect.js seams: hooks/destructive-command-guard.js hooks/codex-dispatch-guard.js verified: 0e3b863ccc8623ef2919423131144988ebdf2d54 -->

**Role:** PreToolUse hard-blocks for Bash and PowerShell commands. The destructive guard denies
never-list destructive commands, exfiltration and pipe-to-shell; the Codex guard denies any raw
`codex exec` that does not go through the wrapper.
**Contracts:**
- Hook protocol: read PreToolUse JSON from stdin, write a `permissionDecision: deny` object, always exit 0
  (`hooks/destructive-command-guard.js:5`-`:7`, `hooks/destructive-command-guard.js:73`-`:83`).
- Fail-closed: a stdin timeout (`APEX_GUARD_STDIN_TIMEOUT_MS`, default 3000), malformed input or a
  non-string command is denied (`hooks/destructive-command-guard.js:36`-`:60`, `hooks/destructive-command-guard.js:85`-`:97`).
- Reason-gated disable: only `off|0|false|disabled` with a non-empty `APEX_GUARD_DISABLE_REASON`,
  and it is honoured only when the audit line was written to `APEX_GUARD_AUDIT_LOG` or `hooks/guard-audit.log`
  (`hooks/lib/guard-disable.js:4`-`:9`, `hooks/lib/guard-disable.js:17`-`:45`).
- Detection API: `isDestructiveBash`, `isReadOnlyGitIntrospection`, `isExfiltrationBash`,
  `isRemoteCodeExec`, plus tokenizer helpers (`hooks/lib/destructive-detect.js:701`-`:711`). Git rules
  are at `hooks/lib/destructive-detect.js:401`.
**Seams:** Disable env vars are `APEX_DESTRUCT_GUARD` (`hooks/destructive-command-guard.js:106`) and
`APEX_CODEX_GUARD` (`hooks/codex-dispatch-guard.js:427`). The Codex guard reuses the detector's
tokenizer (`hooks/codex-dispatch-guard.js:35`-`:39`), and its raw-exec matcher is at
`hooks/codex-dispatch-guard.js:335`.
**Dependents:** Governance hard blocks (mechanical half); the dispatch wrapper relies on being the only
Codex path (`skills/apex-code/SKILL.md:146` in the reviewed build).
**Evidence:** The deny message lists only exit codes 0/65/67/68/75/124 (`hooks/codex-dispatch-guard.js:451`-`:452`).
The wrapper's full exit table is longer. Python suite harness: `hooks/destructive-guard-test.py:185`.

## Context cap guard and advisory hooks
<!-- apex:map-section covers: hooks/context-cap-guard.js hooks/context-cap-guard.test.js hooks/apex-context-monitor.js hooks/apex-statusline.js hooks/apex-read-injection-scanner.js contracts: hooks/context-cap-guard.js seams: hooks/apex-statusline.js hooks/apex-context-monitor.js verified: 0e3b863ccc8623ef2919423131144988ebdf2d54 -->

**Role:** The blocking write rule for the three capped context files, plus GSD-derived advisory
hooks: a context-usage status line, low-context warnings and a Read prompt-injection scanner.
**Contracts:**
- Caps: `status.md` at most 100 lines, `CLAUDE.md` at most 200 lines, `AGENTS.md` at most 32768 bytes
  (`hooks/context-cap-guard.js:28`-`:35`). Line counting uses `wc -l` semantics (`hooks/context-cap-guard.js:9`).
  An edit that does not grow the file is always allowed (`hooks/context-cap-guard.js:193`); denial is at
  `hooks/context-cap-guard.js:200`.
- Monitor thresholds: warning at 35% remaining, critical at 25%, a 5-call debounce, and metrics older
  than 60 seconds ignored (`hooks/apex-context-monitor.js:26`-`:29`).
- The scanner is advisory only and never blocks (`hooks/apex-read-injection-scanner.js:13`,
  patterns `hooks/apex-read-injection-scanner.js:23`-`:48`).
**Seams:** The status line writes `os.tmpdir()/claude-ctx-<session>.json` (`hooks/apex-statusline.js:328`,
`hooks/apex-statusline.js:340`). The monitor reads that file and injects `additionalContext`
(`hooks/apex-context-monitor.js:73`, `hooks/apex-context-monitor.js:183`).
**Dependents:** Session contract (three-file caps); the HOST (context warnings).
**Evidence:** The advisory hooks still carry `gsd-hook-version: 1.41.2` and read `.planning/` config
(`hooks/apex-statusline.js:2`, `hooks/apex-statusline.js:16`); they are GSD carry-overs renamed `apex-*`.

## Codex dispatch wrapper
<!-- apex:map-section covers: skills/apex-code/scripts/codex-dispatch.ps1 skills/apex-code/scripts/dispatch-*.ps1 skills/apex-code/scripts/careless-coder-test.ps1 skills/apex-code/scripts/verdict-test.ps1 skills/apex-code/scripts/review-findings-test.ps1 skills/apex-code/references/codex-*-schema.json skills/apex-code/references/afk-endgate-schema.json skills/apex-code/references/dispatch-pack.md skills/apex-code/references/codex-observability.md contracts: skills/apex-code/scripts/codex-dispatch.ps1 skills/apex-code/references/codex-completion-schema.json skills/apex-code/references/codex-review-schema.json skills/apex-code/references/afk-endgate-schema.json skills/apex-code/references/engine-event-schema.json seams: skills/apex-code/scripts/codex-dispatch.ps1 verified: 0e3b863ccc8623ef2919423131144988ebdf2d54 -->

**Role:** The only Codex launch path (ADR-033). It runs `codex exec`, wrapped in the pre-flight,
scope, tree-pin, critical-file, encoding and verdict gates. It also owns the durable run ledger, the
leases and capacity, the dispatch events, `-Adopt`/abandon recovery, creator-teardown obligations,
and `-AuthorSpec` draft authoring.
**Contracts:**
- Parameters: `-Model` accepts only OpenAI models, default `gpt-6.1-sol`. Effort ladder up to `ultra`.
  `-Schema completion|endgate|review`. `-Sandbox workspace-write|read-only`
  (`skills/apex-code/scripts/codex-dispatch.ps1:9`-`:86`).
- Exit codes 0/65-69/71-83/124 are the routing contract (`skills/apex-code/SKILL.md:176`-`:199` in the reviewed build).
  The post-exit precedence is 67 blocked, 69 tree moved, 66, 65, 77, 73, 68
  (`skills/apex-code/scripts/codex-dispatch.ps1:4402`-`:4450`).
- `-AuthorSpec`: requires `-Task author`, exactly one `-Authorized docs/drafts/<name>.md`, and an
  optional `-ExpectedDigest` for revise. Bad combinations are refused with exit 74
  (`skills/apex-code/scripts/codex-dispatch.ps1:93`-`:160`). The run must leave exactly one regular file
  (`skills/apex-code/scripts/codex-dispatch.ps1:4248`-`:4263`).
- State root: `APEX_STATE_DIR`, then `%LOCALAPPDATA%\apex`, then `%TEMP%\apex`. The ledger is
  `progress/codex-run-ledger.jsonl` and events are written to `events/`
  (`skills/apex-code/scripts/codex-dispatch.ps1:448`-`:450`, `:476`-`:477`). Named mutex `ApexCodexRunLedger`
  (`skills/apex-code/scripts/codex-dispatch.ps1:486`). Row kinds and lease lifecycle are documented at
  `skills/apex-code/references/codex-observability.md:116`-`:124`.
- Completion `.final` schema `{status, changed_files, commands_run, deviations, unresolved, blocker}`
  (`skills/apex-code/references/codex-completion-schema.json:1`). Events `dispatch_result`/`refusal`
  (`skills/apex-code/scripts/codex-dispatch.ps1:830`, `:996`, `:917`-`:951`) follow `skills/apex-code/references/engine-event-schema.json:1`.
**Seams:** Launch arguments `exec -p apex-coder --sandbox ... --output-schema ... -o <final>`, using a
Codex profile outside this repo (`skills/apex-code/scripts/codex-dispatch.ps1:3839`-`:3842`). Process
start and stdin close are at `:3923` and `:3974`; the no-output watchdog exits 124 without killing the
child (`skills/apex-code/scripts/codex-dispatch.ps1:4010`-`:4016`). Calls to its helpers:
critical-file gate `:3203`, baseline pre-flight, spec validation and tree pin `:3250`-`:3350`,
`declared_runtime_paths` exit 81 `:3354`, scope snapshot `:3699`, read-only tree pin `:3735`.
Capacity (`max_parallel_codex`, exit 79) is at `skills/apex-code/scripts/codex-dispatch.ps1:2942`-`:2969`.
**Dependents:** Engine (`engine-dispatch.ps1`), the HOST manual/AFK path, apex-plan author and Sol reads,
Scribe (Luna), the Codex guard hook, and the family gate (which reads its ledger rows).
**Evidence:** `Invoke-Adopt` `skills/apex-code/scripts/codex-dispatch.ps1:2046`; abandon `:1186`;
`-ListObligations` `:1856`. Dispatch pack template `skills/apex-code/references/dispatch-pack.md:8`, last
`agent_message` rule `skills/apex-code/references/dispatch-pack.md:71`. Suites (in fence): `dispatch-preflight-test`,
`dispatch-events-test`, `dispatch-author-test` (`AGENTS.md:17`, `AGENTS.md:18`, `AGENTS.md:21`).

## Dispatch gate helpers (scope, tree pin, critical files)
<!-- apex:map-section covers: skills/apex-code/scripts/codex-scope-check.ps1 skills/apex-code/scripts/tree-pin.ps1 skills/apex-code/scripts/apex-critical-files.ps1 skills/apex-code/scripts/scope-check-test.ps1 skills/apex-code/scripts/sibling-guard-test.ps1 skills/apex-code/scripts/wave-scope-test.ps1 skills/apex-code/scripts/snapshot-scale-test.ps1 skills/apex-code/scripts/git-stderr-test.ps1 skills/apex-code/scripts/encoding-check-test.ps1 skills/apex-code/scripts/tree-pin-test.ps1 skills/apex-code/scripts/critical-files-test.ps1 contracts: skills/apex-code/scripts/codex-scope-check.ps1 skills/apex-code/scripts/tree-pin.ps1 skills/apex-code/scripts/apex-critical-files.ps1 seams: skills/apex-code/scripts/apex-critical-files.ps1 verified: 0e3b863ccc8623ef2919423131144988ebdf2d54 -->

**Role:** The single-purpose gate scripts that the wrapper and the HOST call. Scope detection and the
mojibake scan never remediate anything. The tree pin voids a verdict when the tree moved. The
critical-file classifier is the Layer A and Layer B backstop.
**Contracts:**
- Scope check modes are `-Snapshot`, `-Check` and `-EncodingScan`. Exits: 0 in scope, 1 out-of-scope
  writes (left in place), 66 bad `-Authorized` list, 73 mojibake
  (`skills/apex-code/scripts/codex-scope-check.ps1:32`-`:41`). It detects only and never reverts
  (`skills/apex-code/scripts/codex-scope-check.ps1:11`-`:30`).
- Tree pin modes are `-Pin`, `-Verify` and `-Digest`, with `-PinAlso` for cross-tree gates. Exit 0
  means unchanged; exit 69 means moved, so the verdict is void
  (`skills/apex-code/scripts/tree-pin.ps1:16`-`:32`, `skills/apex-code/scripts/tree-pin.ps1:52`-`:62`).
  `-Digest` gives the 64-hex END and review digests that the ledger binds.
- Critical files: exit 11 for a permanent hard block (`docs/audit`), 10 for critical, 0 for neither
  (`skills/apex-code/scripts/apex-critical-files.ps1:102`, `skills/apex-code/scripts/apex-critical-files.ps1:209`-`:217`).
  The host-state matchers include `codex-run-ledger.jsonl` (`skills/apex-code/scripts/apex-critical-files.ps1:119`).
**Seams:** The classifier names apex-governance "Hard blocks"/"Critical files" as its source of truth
(`skills/apex-code/scripts/apex-critical-files.ps1:1`-`:4`; `skills/apex-governance/SKILL.md:73`, `:110`).
It splits comma-packed `-Paths` (`skills/apex-code/scripts/apex-critical-files.ps1:20`-`:21`).
**Dependents:** The dispatch wrapper (all three), Engine (`Test-RunnerCriticalGate`
`skills/apex-code/scripts/apex-engine.ps1:532`), the HOST for Claude-side gates (`skills/apex-code/SKILL.md:360`-`:362`
in the reviewed build), and Layer A classification (`skills/apex-code/SKILL.md:112`).
**Evidence:** `skills/apex-code/SKILL.md:115` (reviewed build) still warns that `-Paths a,b,c` silently
classifies nothing, but the script now splits commas, so that prose is stale. Only `tree-pin-test` and
`scope-check-test` are in the fence (`AGENTS.md:19`-`:20`).

## Baseline pre-flight and spec validator
<!-- apex:map-section covers: skills/apex-code/scripts/apex-baseline-check.ps1 skills/apex-code/scripts/baseline-check-test.ps1 skills/apex-code/scripts/install-baseline-hook.ps1 skills/apex-code/templates/** skills/apex-code/scripts/apex-spec-validate.ps1 skills/apex-code/scripts/spec-validate-test.ps1 skills/apex-code/scripts/spec-contract-sweep.ps1 skills/apex-code/scripts/fixtures/** skills/apex-code/references/spec-contract.md contracts: skills/apex-code/scripts/apex-baseline-check.ps1 skills/apex-code/scripts/apex-spec-validate.ps1 skills/apex-code/references/spec-contract.md seams: skills/apex-code/templates/pre-commit-baseline skills/apex-code/scripts/install-baseline-hook.ps1 verified: 0e3b863ccc8623ef2919423131144988ebdf2d54 -->

**Role:** Runs a repo's own AGENTS.md recipe as a green or red gate (dispatch pre-flight and the
baseline-green pre-commit hook). Also validates spec structure mechanically for planning promotion,
the wrapper pre-flight and Engine planning.
**Contracts:**
- Recipe grammar (exact heading, the first nonblank line opens the fence, one fence, info string
  selects the shell, one command per line) and exits 0 GREEN, 1 RED, 3 UNPARSEABLE, 4 NO_RECIPE
  (`skills/apex-code/scripts/apex-baseline-check.ps1:13`-`:30`). `-Preflight` prefers `## Preflight commands`
  (`skills/apex-code/scripts/apex-baseline-check.ps1:5`-`:7`).
- The validator runs six checks in fixed order (FILES-COMPLETENESS through ACCEPTANCE-CHECK); exit 0
  means valid, exit 1 means `FAIL <check>: <evidence>` findings
  (`skills/apex-code/scripts/apex-spec-validate.ps1:6`-`:16`).
- Spec contract: required headings (`skills/apex-code/references/spec-contract.md:53`-`:68`), the optional
  `## Execution manifest` (`skills/apex-code/references/spec-contract.md:80`-`:82`), and
  `powershell apex-accept` tagged checks (`skills/apex-code/references/spec-contract.md:124`-`:126`).
**Seams:** The pre-commit hook template calls the checker by absolute home path
(`skills/apex-code/templates/pre-commit-baseline:29`). It is installed per consumer repo by
`skills/apex-code/scripts/install-baseline-hook.ps1:30`. The corpus oracle is
`skills/apex-code/scripts/fixtures/spec-corpus/expected.tsv:1`.
**Dependents:** Wrapper pre-flight (exit 72); apex-plan readiness gate (`skills/apex-plan/SKILL.md:330`);
Engine planning (`skills/apex-code/scripts/engine-plan.ps1:647`); spec template headings.
**Evidence:** Suites `baseline-check-test` and `spec-validate-test` are in the fence (`AGENTS.md:15`-`:16`).

## Family gate and run ledger
<!-- apex:map-section covers: skills/apex-code/scripts/apex-family-gate.ps1 skills/apex-code/scripts/family-gate-test.ps1 contracts: skills/apex-code/scripts/apex-family-gate.ps1 seams: skills/apex-code/scripts/apex-family-gate.ps1 verified: 0e3b863ccc8623ef2919423131144988ebdf2d54 -->

**Role:** The completion gate. It refuses task completion unless the newest build attempt in the
ledger has a bound cross-family review or an attended human review. It reads ledger facts only, never
a caller-supplied SHA.
**Contracts:**
- Exits: 0 vouched, 12 same-family/no acceptable review, 13 cannot vouch
  (`skills/apex-code/scripts/apex-family-gate.ps1:6`-`:11`, `:266`, `:270`). Mandatory `-Spec -Task -WorktreeKey`
  (`skills/apex-code/scripts/apex-family-gate.ps1:25`-`:36`).
- The newest attempt governs (no fallback to an older reviewed build), and review digests must equal the build's
  `end_tree_digest` (`skills/apex-code/scripts/apex-family-gate.ps1:11`, `:185`). Review rows with
  `tree_moved` or `scopeViolation` do not vouch (`skills/apex-code/scripts/apex-family-gate.ps1:13`-`:16`).
- In-session row shape and mutex append protocol (`skills/apex-code/SKILL.md:411`-`:452` in the reviewed build).
**Seams:** The ledger path resolution mirrors the wrapper (`skills/apex-code/scripts/apex-family-gate.ps1:45`-`:57`).
In-session rows are appended through `hooks/apex-ledger-append.ps1`, which is **untracked** (named in
`settings.json:30`-`:31` and `skills/apex-code/scripts/codex-dispatch.ps1:2996`) and cannot be covered.
**Dependents:** apex-code Post-build step 6 (`skills/apex-code/SKILL.md:454`-`:465` in the reviewed build); Scribe step 6
(`skills/apex-code/references/scribe.md:179`); drain close-out step 2.
**Evidence:** `family-gate-test.ps1` exists but is not in the verify fence.

## Engine (attended build runner)
<!-- apex:map-section covers: skills/apex-code/scripts/apex-engine.ps1 skills/apex-code/scripts/engine-*.ps1 skills/apex-code/references/engine-*-schema.json skills/apex-code/references/accept-grammar-vectors.json contracts: skills/apex-code/scripts/apex-engine.ps1 skills/apex-code/references/engine-state-schema.json skills/apex-code/references/engine-event-schema.json skills/apex-code/references/accept-grammar-vectors.json seams: skills/apex-code/scripts/engine-dispatch.ps1 skills/apex-code/scripts/engine-plan.ps1 verified: 0e3b863ccc8623ef2919423131144988ebdf2d54 -->

**Role:** The default attended build route for eligible specs (one repo, an execution manifest,
file-disjoint tasks, Codex). It plans waves from the manifest, dispatches per task through the
wrapper, retries up an effort ladder, integrates on a `codex/*-integration` branch, verifies, runs
tagged acceptance checks and hands off. HOST close-out stays outside it.
**Contracts:**
- CLI: `-SpecPath -Repo -Attended -MaxParallel`; `-Resume <id>` with
  `-ReviewVerdict/-ReviewDigest/-ReviewRecord`; `-Teardown <id> [-Discard -Reason]`
  (`skills/apex-code/scripts/apex-engine.ps1:1`-`:22`).
- Exits: 0 complete with HOST checks printed, 1 refused/parked/failed, 2 awaiting-review on a high-risk wave
  (`skills/apex-code/scripts/apex-engine.ps1:1625`-`:1646`, `:1589`, `:2002`-`:2020`).
  Usage is documented at `skills/apex-code/SKILL.md:59`-`:73` in the reviewed build.
- Durable `engine-state.json` per run (`skills/apex-code/scripts/apex-engine.ps1:1652`;
  schema `skills/apex-code/references/engine-state-schema.json:1`). State and worktree roots must lie
  outside every Git worktree (`skills/apex-code/scripts/apex-engine.ps1:1995`-`:1997`).
- Refusals: a manifest with exactly one fence and one repo (`skills/apex-code/scripts/engine-plan.ps1:654`-`:672`),
  overlapping paths (`skills/apex-code/scripts/engine-plan.ps1:797`), risk consistency
  (`skills/apex-code/scripts/engine-plan.ps1:639`). Tagged `powershell apex-accept` fences
  (`skills/apex-code/scripts/engine-plan.ps1:447`).
**Seams:** It dot-sources `engine-plan.ps1`, `engine-git.ps1` and `engine-dispatch.ps1`
(`skills/apex-code/scripts/apex-engine.ps1:62`-`:64`). It calls the wrapper through
`Start-EngineDispatch` (`skills/apex-code/scripts/engine-dispatch.ps1:163`, `skills/apex-code/scripts/apex-engine.ps1:655`)
and validates its events against the schema (`skills/apex-code/scripts/engine-dispatch.ps1:4`-`:5`,
`skills/apex-code/scripts/engine-dispatch.ps1:721`). Git work happens in the integration and task worktrees
(`skills/apex-code/scripts/engine-git.ps1:223`, `:248`); wave commits are limited to the integration branch
(`skills/apex-code/scripts/engine-git.ps1:401`); the teardown proof is at `skills/apex-code/scripts/engine-git.ps1:614`.
**Dependents:** apex-orchestrate routing (`skills/apex-orchestrate/SKILL.md:57`); the drain runner (dot-sources the
same three files); the HOST (state, diagnosis and the `-Teardown` close-out).
**Evidence:** The review gate is at `skills/apex-code/scripts/apex-engine.ps1:1375` and acceptance checks at `:1017`.
Suites are `engine-plan-test`, `engine-git-test`, `engine-dispatch-test` and `engine-test` (`AGENTS.md:22`-`:24`, `AGENTS.md:33`).

## Unattended drain and close-out
<!-- apex:map-section covers: skills/apex-code/scripts/apex-drain*.ps1 skills/apex-code/references/drain-close-out.md contracts: skills/apex-code/scripts/apex-drain-plan.ps1 skills/apex-code/scripts/apex-drain.ps1 skills/apex-code/scripts/apex-drain-close.ps1 skills/apex-code/references/drain-close-out.md seams: skills/apex-code/scripts/apex-drain.ps1 verified: 0e3b863ccc8623ef2919423131144988ebdf2d54 -->

**Role:** ADR-049 unattended queue builds. A read-only plan sorts `docs/changes` into WILL BUILD and
NEEDS YOU. A durable serial runner drives the Engine per spec on local `codex/drain-<id>` branches.
A read-only close-out plan feeds the attended HOST close-out sequence.
**Contracts:**
- `apex-drain-plan.ps1 -Project <abs> [-Json]` is read-only; exits 0 or 1
  (`skills/apex-code/scripts/apex-drain-plan.ps1:1`-`:18`, `:217`-`:225`).
- `apex-drain.ps1 -Project | -Resume <id>`: `drain-state.json` under the state root's `drains/`, report
  `<project>/docs/drain/<id>.md`, branch `codex/drain-<id>`, quota budget of 300 minutes, and
  `stopped-integrity` must not be resumed (`skills/apex-code/scripts/apex-drain.ps1:8`, `:87`-`:93`, `:101`,
  `:482`, `:591`).
- `apex-drain-close.ps1 -Plan <id> [-Json]` reads only state and Git and never reads the Markdown report
  (`skills/apex-code/scripts/apex-drain-close.ps1:1`-`:3`). Git is called without hooks, optional locks or
  lazy fetch (`skills/apex-code/scripts/apex-drain-close.ps1:17`-`:18`).
- HOST sequence: per-spec checks, Critic and family gate, one Opus end-gate, docs agent per spec,
  batched owner approval of staged trees, `merge --ff-only` to the approved SHA, then teardown
  (`skills/apex-code/references/drain-close-out.md:5`-`:9`).
**Seams:** It dot-sources the Engine modules (`skills/apex-code/scripts/apex-drain.ps1:15`-`:17`) and
launches `apex-engine.ps1` (`skills/apex-code/scripts/apex-drain.ps1:418`). The trigger is documented at
`skills/apex-code/SKILL.md:75`-`:76` in the reviewed build.
**Dependents:** The owner's `!` trigger and the HOST close-out; the docs agent.
**Evidence:** Suites `apex-drain-plan-test`, `apex-drain-test -Case core|recovery|resume|safety` and
`apex-drain-close-test` are in the fence (`AGENTS.md:25`-`:30`).

## apex-code skill and build references
<!-- apex:map-section covers: skills/apex-code/SKILL.md skills/apex-code/references/parallel-codex.md skills/apex-code/references/afk-endgate.md skills/apex-code/references/scribe.md skills/apex-code/references/codex-review.md skills/apex-code/references/permissions.md skills/apex-code/references/workflow-dispatch.md skills/apex-code/references/silent-regression-lenses.md skills/apex-code/REVIEW-ENSEMBLE-DESIGN.md contracts: skills/apex-code/SKILL.md skills/apex-code/references/afk-endgate.md skills/apex-code/references/parallel-codex.md seams: skills/apex-code/SKILL.md verified: 30f018629943f96e659399c987e1172c18a334ed -->

**Role:** The build-workflow instructions for the HOST: pre-flight, Engine routing, HOST manual and
AFK wave mechanics, Layer A classification, wrapper invocation and exit routing, verify cadence,
forks, and the Post-build close-out (Critic, Scribe, family gate, docs). Line numbers below are from
the reviewed `critic-plan-inputs` build of `SKILL.md` and `afk-endgate.md`.
**Contracts:**
- `## Files to Change` is the scope lock and is re-issued, never widened in flight (`skills/apex-code/SKILL.md:51`-`:52`).
- HOST structural wave checks (a)-(f), with a cap of 64 tasks (`skills/apex-code/SKILL.md:82`).
- The wrapper exit table (`skills/apex-code/SKILL.md:176`-`:199`); Events (`skills/apex-code/SKILL.md:290`-`:296`);
  Verify is AGENTS.md only (`skills/apex-code/SKILL.md:300`).
- Post-build cadence: a risk-routed Critic with a three-round cap; plan-slice inputs are pasted when the
  `## Intent` has a C5 line (`skills/apex-code/SKILL.md:376`-`:395`, `:381`). Then Scribe
  (`skills/apex-code/SKILL.md:396`), the family gate (`skills/apex-code/SKILL.md:454`), obligations
  (`skills/apex-code/SKILL.md:466`) and the docs agent (`skills/apex-code/SKILL.md:468`).
- AFK end-gate: one Opus `apex-critic` `mode: code` pass over `run_base_sha..HEAD` as whole-build round 1,
  with C2 plan-slice inputs; output maps block to P1, flag to P2 and note to note
  (`skills/apex-code/references/afk-endgate.md:13`-`:31`, `skills/apex-code/references/afk-endgate.md:68`-`:81`).
- Parallel Codex: a cap, worktree per task, integration without `git merge`, and cross-spec rules
  (`skills/apex-code/references/parallel-codex.md:11`, `:33`, `:53`, `:160`).
**Seams:** Scribe dispatches Luna through the wrapper (`skills/apex-code/references/scribe.md:119`). Codex
review goes through the wrapper (`skills/apex-code/references/codex-review.md:19`). The `dontAsk` AFK policy is at
`skills/apex-code/references/permissions.md:12`. The workflow fan-out is at `skills/apex-code/SKILL.md:101`-`:105`
(`skills/apex-code/references/workflow-dispatch.md:1`). `impl.md` loads at pre-flight (`skills/apex-code/SKILL.md:53`).
**Dependents:** apex-orchestrate routing; governance L3 (`skills/apex-governance/levels/L3.md:5`); agents
(critic, docs, coder); the session contract's routing row.
**Evidence:** `REVIEW-ENSEMBLE-DESIGN.md` is a parked design note, not built
(`skills/apex-code/REVIEW-ENSEMBLE-DESIGN.md:3`). Silent-regression lenses are at
`skills/apex-code/references/silent-regression-lenses.md:13`.

## Map checker and size guard
<!-- apex:map-section covers: skills/apex-plan/scripts/** skills/apex-plan/references/system-map.md contracts: skills/apex-plan/references/system-map.md skills/apex-plan/scripts/apex-map-check.ps1 skills/apex-plan/scripts/apex-size-guard.ps1 seams: skills/apex-plan/scripts/apex-map-check.ps1 skills/apex-plan/scripts/apex-size-guard.ps1 verified: 0e3b863ccc8623ef2919423131144988ebdf2d54 -->

**Role:** The system-map format and HOST protocol, the read-only freshness and lookup checker, and the
staged Trivial size guard. Both scripts are read-only in their target repositories.
**Contracts:**
- Map marker and section header grammar (`skills/apex-plan/references/system-map.md:13`, `:20`), Git `:(glob)`
  rules (`skills/apex-plan/references/system-map.md:32`-`:38`), the body shape
  (`skills/apex-plan/references/system-map.md:44`-`:52`), and exits 0 fresh, 1 stale, 2 error, 3 no
  sections (`skills/apex-plan/references/system-map.md:98`-`:103`).
- Checker CLI `-Repo <abs> (-Stale | -Touches <p>... | -Owner <p>) [-Json]`
  (`skills/apex-plan/scripts/apex-map-check.ps1:2`-`:3`). It parses the header at
  `skills/apex-plan/scripts/apex-map-check.ps1:161`. Path tokens reject spaces, backslashes, `[ ]` and
  partial `**` (`skills/apex-plan/scripts/apex-map-check.ps1:131`-`:144`). `-Stale` diffs each cover with
  `:(glob)` against HEAD (`skills/apex-plan/scripts/apex-map-check.ps1:308`-`:313`). `-Touches` matches
  contracts and seams; `-Owner` matches covers (`skills/apex-plan/scripts/apex-map-check.ps1:318`).
- Four-part Trivial test and size guard WITHIN 0, OVER 1, error 2 (`skills/apex-plan/references/system-map.md:130`-`:169`;
  `skills/apex-plan/scripts/apex-size-guard.ps1:311`-`:320`). Split index at about 400 lines
  (`skills/apex-plan/references/system-map.md:171`).
**Seams:** Git children run with closed stdin, a 120-second timeout, and repository and pathspec
environment variables scrubbed (`skills/apex-plan/scripts/apex-map-check.ps1:57`-`:129`). The map is read from
`docs/system-map.md` or `docs/system-map/index.md` (`skills/apex-plan/scripts/apex-map-check.ps1:271`-`:290`).
**Dependents:** apex-init seeds the marker-only stub (`skills/apex-init/SKILL.md:92`-`:95`, `:246`-`:254`);
the HOST writes this map. apex-plan's `SKILL.md` never mentions the map, the checker or the size guard,
so the Trivial test and map reads are reachable only from this reference.
**Evidence:** Suites `apex-map-check-test` and `apex-size-guard-test` are in the fence (`AGENTS.md:31`-`:32`).

## apex-plan skill and planning references
<!-- apex:map-section covers: skills/apex-plan/SKILL.md skills/apex-plan/references/sol-plan-check.md skills/apex-plan/references/model-routing.md skills/apex-plan/references/agents-md-population.md skills/apex-plan/references/adr-and-status-procedures.md skills/apex-plan/references/design-*.md skills/apex-plan/references/cheap-mockup-workflow.md contracts: skills/apex-plan/SKILL.md skills/apex-plan/references/sol-plan-check.md seams: skills/apex-plan/SKILL.md skills/apex-plan/references/sol-plan-check.md verified: 30f018629943f96e659399c987e1172c18a334ed -->

**Role:** Turns requirements into `docs/changes` specs. It chooses the mode, runs the research gate,
dispatches the gpt-6-sol spec author, and runs Critic spec review, the readiness gate and the Sol
reads. The Big-change planning gate and the plan artifact (C1-C6) are in `sol-plan-check.md`.
**Contracts:**
- Modes are Deep Details, Light and Bug Fix (`skills/apex-plan/SKILL.md:72`-`:80`). The author dispatch is
  `codex-dispatch.ps1 -AuthorSpec -Model gpt-6-sol -Task author` (`skills/apex-plan/SKILL.md:119`-`:127`).
- Critic spec review: a `SPEC-DIGEST` first line, digest-voided verdicts, and round findings files
  (`skills/apex-plan/SKILL.md:239`-`:259`). The cap is 3 rounds per spec lifetime plus one owner-approved
  cycle (`skills/apex-plan/SKILL.md:261`). Promotion is blocked on an `apex-spec-validate` FAIL
  (`skills/apex-plan/SKILL.md:330`). The Sol cold read is required for Medium and High
  (`skills/apex-plan/SKILL.md:377`-`:383`).
- Cold read recipe (`skills/apex-plan/references/sol-plan-check.md:7`-`:30`). The planning gate check
  (`docs/plans/<plan>.md`, `gate-N` rows, digest VOID, approval banner) is at
  `skills/apex-plan/references/sol-plan-check.md:88`-`:147`. C2-C6 contracts (plan-slice inputs, finding
  classes, status pointer, Intent `plan:` line, clean slice brief) are at
  `skills/apex-plan/references/sol-plan-check.md:149`-`:173`.
**Seams:** Every Sol read goes through the wrapper with `-Phase review -Schema review -Effort xhigh`
(`skills/apex-plan/references/sol-plan-check.md:107`). The spec template is in apex-orchestrate
(`skills/apex-plan/SKILL.md:117`). AGENTS.md population is at
`skills/apex-plan/references/agents-md-population.md:11`.
**Dependents:** apex-critic consumes plan-slice inputs; apex-code consumes specs; the orchestrator routes here.
**Evidence:** `skills/apex-plan/references/sol-plan-check.md:198` cites `codex-dispatch.ps1:1793-1795`
and `:2052-2053` for the exit contract; those lines are now teardown and ledger code, so the pointer is
stale. `skills/apex-plan/SKILL.md` contains double-encoded UTF-8 (mojibake) on 70 lines, including
the frontmatter description (`skills/apex-plan/SKILL.md:19`).

## apex-orchestrate and governance
<!-- apex:map-section covers: skills/apex-orchestrate/** skills/apex-governance/** contracts: skills/apex-governance/SKILL.md skills/apex-orchestrate/templates/spec-template.md skills/apex-orchestrate/templates/AGENTS-template.md seams: skills/apex-orchestrate/SKILL.md verified: 0e3b863ccc8623ef2919423131144988ebdf2d54 -->

**Role:** The session router (orient from `docs/status.md`, surface in-flight work, route to
plan/code/debug), the project templates, and the canonical autonomy model (levels L0-L5, hard
blocks, critical files, approval gate, evaluator independence).
**Contracts:**
- The routing table, including Engine exit semantics (`skills/apex-orchestrate/SKILL.md:48`-`:62`, `:57`).
  Orient reads only status.md (`skills/apex-orchestrate/SKILL.md:25`-`:36`); status.md is live state
  (`skills/apex-orchestrate/SKILL.md:132`).
- Spec template frontmatter (`risk`, `coder_model`, `coder_effort`, `max_parallel_codex`,
  `declared_runtime_paths`) and sections
  (`skills/apex-orchestrate/templates/spec-template.md:5`-`:28`, `:48`-`:215`). The execution manifest is at
  `skills/apex-orchestrate/templates/spec-template.md:91`.
- The AGENTS template's Verify commands and Build outputs sections
  (`skills/apex-orchestrate/templates/AGENTS-template.md:28`, `:44`).
- Governance hard blocks (`skills/apex-governance/SKILL.md:73`-`:80`), critical files
  (`skills/apex-governance/SKILL.md:110`-`:118`), the approval gate banner (`skills/apex-governance/SKILL.md:149`),
  and evaluator independence (`skills/apex-governance/SKILL.md:173`). Levels are in
  `skills/apex-governance/levels/L0.md:1` through `skills/apex-governance/levels/L5.md:1`.
**Seams:** The session contract triggers the orchestrator (`hooks/apex-session-context.md:2`). The
orchestrator hands off to apex-init when status.md is missing (`skills/apex-orchestrate/SKILL.md:29`-`:30`).
**Dependents:** `apex-critical-files.ps1` (executable copy of the critical-file rules); apex-code; apex-plan
(approval banner); the destructive guard (hard blocks).
**Evidence:** The L3 pipeline definition is at `skills/apex-governance/levels/L3.md:5`.

## Agents and build-wave workflow
<!-- apex:map-section covers: agents/** workflows/** contracts: agents/apex-critic.md workflows/apex-build-wave.js seams: workflows/apex-build-wave.js agents/apex-coder.md verified: 30f018629943f96e659399c987e1172c18a334ed -->

**Role:** The Claude subagents: the advisory critic for spec and code modes, the Claude-fallback coder
with its code-worker children, and the docs agent that acts as the host's pen. Also the workflow script
that fans out one wave of code-workers.
**Contracts:**
- `apex-critic` (reviewed build): Read/Glob/Grep only, and the Agent `model:` parameter overrides its default
  `sonnet` (`agents/apex-critic.md:4`-`:5`, `:13`-`:15`). Required inputs per mode (`agents/apex-critic.md:17`-`:66`).
  The optional plan-slice inputs are never opened from the plan file (`agents/apex-critic.md:30`-`:38`). Rounds
  run 1 to 3 (`agents/apex-critic.md:68`-`:77`). Output is
  `{"status":"clean|flag|block","findings":[...]}` (`agents/apex-critic.md:106`-`:116`).
- `apex-coder`: Claude fallback only, with no Bash tool; it spawns code-workers per wave
  (`agents/apex-coder.md:3`-`:8`, `agents/apex-coder.md:49`-`:71`). `code-worker` returns
  `{task,status:"done|blocked",...}` (`agents/code-worker.md:54`-`:66`).
- `apex-docs-technical-agent` writes the handoff, archives the spec and updates status.md as the host's pen
  (`agents/apex-docs-technical-agent.md:10`, `:29`, `:42`, `:48`).
- Workflow args `{spec_path, token_profile, wave_label, tasks[], isolate}` and `STATUS_SCHEMA`
  (`workflows/apex-build-wave.js:9`-`:42`).
**Seams:** The workflow calls `agent(..., {agentType:'code-worker', schema, model?, isolation?})`
(`workflows/apex-build-wave.js:62`-`:68`). Critic dispatch rules are in apex-code Post-build and
apex-plan's spec review.
**Dependents:** apex-code (critic, docs agent, fallback coder); apex-plan (spec-mode critic); the AFK end-gate.
**Evidence:** The workflow schema's enum `DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT`
(`workflows/apex-build-wave.js:35`) differs from code-worker's own `done | blocked` return shape
(`agents/code-worker.md:60`).

## Remaining small skills
<!-- apex:map-section covers: skills/apex-coding-principles/** skills/apex-context-budget/** skills/apex-debug/** skills/apex-deep-dive/** skills/apex-handoff/** skills/apex-init/** skills/apex-refresh/** skills/apex-research/** skills/apex-skill-author/** skills/apex-stack/** contracts: skills/apex-init/SKILL.md skills/apex-handoff/SKILL.md skills/apex-coding-principles/impl.md seams: skills/apex-init/SKILL.md verified: 0e3b863ccc8623ef2919423131144988ebdf2d54 -->

**Role:** Single-file workflow skills with no executable code: bootstrap (init), handoff protocol,
coding principles (loaded by apex-code), debug, deep-dive, research, stack choice, context budget,
skill authoring, and skill-set refresh.
**Contracts:**
- apex-init scaffolds `docs/` and seeds the marker-only `docs/system-map.md` stub
  (`skills/apex-init/SKILL.md:92`-`:95`, `skills/apex-init/SKILL.md:246`-`:254`).
- The handoff file is `docs/handoff/{YYYY-MM-DD}.md` (`skills/apex-handoff/SKILL.md:43`).
- Coding principles are enforced through `impl.md` (`skills/apex-coding-principles/SKILL.md:22`; frontmatter
  `skills/apex-coding-principles/impl.md:1`), which apex-code loads at pre-flight.
- Skill authoring: the Iron Law, a 500-line body cap, and the double-write to `~/apex/SKILLS.md`/`SKILL-HISTORY.md`
  (`skills/apex-skill-author/SKILL.md:36`, `:95`, `:107`).
**Seams:** apex-orchestrate invokes apex-init when status.md is missing. apex-refresh keeps tracked
state in `skills/apex-refresh/.stocktake-state`.
**Dependents:** apex-orchestrate, apex-code (impl.md), apex-plan (research, deep-dive, stack routing), the
docs agent (handoff format).
**Evidence:** Versions are in each frontmatter, for example `skills/apex-init/SKILL.md:3` and `skills/apex-skill-author/SKILL.md:3`.
