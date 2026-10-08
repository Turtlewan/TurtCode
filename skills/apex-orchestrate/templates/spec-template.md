---
spec: {short-name}
status: draft
autonomy_level: L2
# risk: medium               # optional — enum {low|medium|high}. Absent = medium, except a doc-only spec is Low unless it explicitly declares risk: high, which always wins.
# cross_model_review: true   # optional — high-stakes builds (auth / security / data). Runs an
#                              independent 2nd review by a DIFFERENT model family than the builder
#                              (family-aware: Codex-built → Claude reviews; Claude-fallback-built (Sonnet 5) → Codex reviews).
#                              Cross-family (ADR-032/034): the Claude side is `apex-critic` code mode
#                              subagent; the Codex side is headless `codex exec`. Findings are
#                              advisory, but a Codex BLOCK verdict routes exit 67 — a hard stop.
# coder_model: codex         # optional — pin this WHOLE spec to one coder. Enum {codex|sonnet}, full
#                              stop. Absent → codex (the default); sonnet pins the whole spec to the
#                              Claude fallback coder (Sonnet 5 — A1, session-79b; ADR-045).
# coder_effort: medium       # optional — Codex reasoning effort {low|medium|high|xhigh|max|ultra}.
#                              Absent → medium (default). low = trivial/mechanical; high = risk:high /
#                              auth / security / data / hard; xhigh = hardest async/eval work only;
#                              max = hardest single tasks (state migrations, IAM/auth-critical, gnarly
#                              concurrency); ultra = RARE per-task escalation above max — spawns
#                              in-model subagents, counts DOUBLE against max_parallel_codex, not for
#                              routine use pending head-to-head eval vs max (ADR-030).
# max_parallel_codex: 2      # optional — cap on concurrent `codex exec` subprocesses per wave
#                              (ADR-028). 1 = sequential. Absent → **2** (A2, session-79b; ADR-028 as
#                              amended). Formula min(4, floor(cores/2)−1) documented for reference only.
#                              Machine-protection, not a quota cap.
# declared_runtime_paths:    # optional — repo-relative paths this build depends on at RUNTIME that
#   - path/to/runtime/asset  #   git may not track; the dispatch pre-flight checks DECLARED paths only
#                            #   (a check cannot discover an undeclared invisible dependency).
---

# Spec: {title}
<!-- Governing contract: ~/.claude/skills/apex-code/references/spec-contract.md (the validator's contract doc owns the version; never restate a number here). -->

**Identity:** {one line — what this builds, for routing/review/recall. NOT rationale.}
<!-- Optional, on its own line: → why: see docs/technical/adr/ADR-NNN-*.md (a pointer, never the content). -->

<!-- A spec is an EXECUTION SCRIPT, not a design doc: rich on the *what* (exact files,
     copy-paste-ready detail, per-task verify), stripped of the *why*. The coder executes against
     frozen acceptance criteria; build-changing judgment is resolved in planning, not the build. Spec-authoring rules:
     - No why inline. Litmus when tempted: does it change what gets built? No → cut it
       (home = ADR / planning discussion). Yes → don't add the why, make the *what* explicit.
     - List files per task — every task names its exact files (see ## Tasks). Never "update the auth flow."
     - Cross-cutting conventions live in the relevant skill's impl.md, never copied into the spec. -->

<!-- Split rule: if this spec touches >3 files OR has >2 logical phases, split it into separate specs,
     unless it is doc-only as defined in Intent. Explicit `risk: high` overrides this exemption. -->

## Intent
<!-- Optional for single-task specs, recommended otherwise. ≤10 lines, what-bearing — the ONE
     sanctioned home for load-bearing intent; it travels to the coder in the dispatch pack
     (ADR-031) so mismatches resolve against stated invariants instead of guesses.
     Never an ADR essay — rationale lives in the ADR.
     Doc-only means every Files-to-Change path is documentation prose under `docs/`, an ADR,
     README, or CHANGELOG, and none is a skill (`SKILL.md`, `references/**`, `templates/**`), agent,
     hook, settings, script, or other config/instruction file. Explicit `risk: high` always overrides
     doc-only. -->
- **Intent:** {1-2 lines — the outcome this spec exists to produce}
- **Invariants:** {properties that must hold when done — behavioural/structural, testable where possible}
- **Non-goals:** {adjacent work this spec deliberately does NOT do}

## Assumptions
<!-- The plan fills this. The build verifies each item before executing. -->
<!-- Format: assumption → impact if wrong (Stop | Caution | Low) -->
- {Assumption 1} → impact: {Stop | Caution | Low}
- {Assumption 2} → impact: {Stop | Caution | Low}

<!-- Simplicity check (planning fills this): -->
<!-- "Is there a simpler spec? ___. Why this version: ___." -->
Simplicity check: {considered simpler approach? yes/no — if yes, why this version instead}

## Prerequisites
<!-- Build-load-bearing for cross-spec parallelism (ADR-029): at a batch "build specs", two specs
     run concurrently only when BOTH dependency-independent (this list, transitive) AND file-disjoint
     (their ## Files to Change don't intersect). List every prerequisite spec precisely — a missing
     edge, or a shared file unlisted here/below (e.g. two specs both editing one types.py or
     re-exporting into one package __init__.py), costs a needless serialization or a clobbering build.
     Design FOR this: give each shared file ONE owning spec and list that spec here, rather than
     co-editing it from two specs. -->
- Specs that must be complete first (or "none")
- Environment setup required (or "none")

## Files to Change
| File | Operation | Notes |
|------|-----------|-------|
| {path/to/a.ts} | modify | {what changes} |
| {path/to/b.ts} | create | {what changes} |
| {path/to/c.ts} | modify | {what changes} |
| {path/to/d.ts} | delete | {what changes} |

## Execution manifest
<!-- Include one entry per coder task. HOST/OWNER tasks stay outside the manifest.
     ## Wave plan remains human-readable, while manifest depends_on dependencies are authoritative to the Engine. -->
```json apex-manifest
{
  "version": 1,
  "repos": { "app": "{absolute/forward-slash/repo/root}" },
  "tasks": [
    { "id": "1", "repo": "app", "files": [{ "path": "{path/to/a.ts}", "op": "modify" }, { "path": "{path/to/b.ts}", "op": "create" }], "depends_on": [] },
    { "id": "2", "repo": "app", "files": [{ "path": "{path/to/c.ts}", "op": "modify" }], "depends_on": [] },
    { "id": "3", "repo": "app", "files": [{ "path": "{path/to/d.ts}", "op": "delete" }], "depends_on": ["1", "2"] }
  ]
}
```

## Tasks
<!-- Every task names its exact files — never "update the auth flow" (forces the worker to explore = context cost + scope creep; the file list is also the wave grouping + scope lock). -->
- [ ] **Task 1** — {description} — files: {path/to/a.ts, path/to/b.ts} — done when: {observable outcome}
- [ ] **Task 2** — {description} — files: {path/to/c.ts} — done when: {observable outcome}
- [ ] **Task 3** — {description} — files: {path/to/d.ts} — done when: {observable outcome}

## Wave plan
<!-- Required for specs with ≥3 tasks. Planning derives this from stated dependencies. The emitted
     plan is a PROPOSAL: grouping is advisory; manifest depends_on is authoritative to the Engine
     for eligible specs. HOST schedules the attended manual path for refused specs. Parallel tasks
     must be file-disjoint; risk:high runs sequentially on both paths.
     Under ADR-027 as amended (A1/ADR-045) the coder is Codex by default for every task (Sonnet 5 is the
     fallback, reached only via the three fallback triggers and handled at build time by apex-code) — emit
     the normal untagged wave plan; don't tag ▸sonnet
     proactively. Full rubric in apex-plan § Model-routing build planning. -->
Wave 1: [task 1, task 2] | Wave 2: [task 3]

## Permissions

The following NON-CRITICAL actions will run autonomously during build. Approving this spec approves all of them.
Critical paths — .env · migrations · auth/authz/crypto · CI config · dependency manifests and lockfiles · infra-as-code · secrets/keys/certs · host-state (`status.md`, root AGENTS.md, root CLAUDE.md, docs/changes/, docs/handoff/, the run ledger) · the permission settings and the hooks — are NEVER pre-authorised by this section. They need a live attended confirmation at build time, and an AFK run parks them (D3, ADR-046; apex-governance is canonical). (Sole exception: the docs agents' three host's-pen artifacts — the handoff, `status.md`, and spec archival — under D6.)
docs/audit/ is different and stricter: TIER-1, refused outright on a path match. No confirmation authorises a write there — not attended, not by any switch, not by this section. (D5's append-only exception is doctrine pending a content-aware classifier change; it is not a live permission.)

### File Operations
| Action | Paths |
|--------|-------|
| Create | {full/path/to/new-file.ts} |
| Modify | {full/path/to/existing.ts} |
| Delete | (none) |

### Commands
| Command | Purpose |
|---------|---------|
| `{exact command}` | {what it does} |

### Git Operations
| Operation | Scope |
|-----------|-------|
| `git add` | {path pattern} |
| `git commit` | "{conventional commit message}" |

### Environment Access
| Variable | Purpose |
|----------|---------|
| `{VAR_NAME}` | {what it's used for} |

### Network
| Action | Purpose |
|--------|---------|
| `npm install` | Package installation |

## Specialist Context
### Security
(none — or findings from the dispatched spec review)

### Performance
(none — or constraints/budgets)

### Accessibility
(none — or a11y requirements if frontend change)

## Documentation
| Doc type | File | Action |
|----------|------|--------|
| Inline | {path} | JSDoc/TSDoc all exports |
| API | docs/product/api/{name}.md | {add/update} section |
| Changelog | CHANGELOG.md | Add entry under Unreleased |
| ADR | docs/technical/adr/ADR-{NNN}-{title}.md | Write (if architectural decision) |

## Acceptance Criteria
<!-- Executable checks opt in only with the exact, case-sensitive info string `powershell apex-accept`
     under this Acceptance Criteria section. Checks run with integration-root cwd.
     Binding uses the immediately preceding criterion line: a leading label matching
     `^- \[[ xX]\] Task (\d+[a-z]?) -` binds to that execution-manifest task ID;
     an unlabelled criterion binds to spec level. Compound task labels and unknown task IDs,
     including HOST tasks absent from the manifest, are refused. Untagged criteria remain HOST checks.
     Tagged checks are trusted author-written, Critic-reviewed, owner-promoted spec content,
     run unsandboxed with the same trust as the AGENTS.md verify fence. The grammar guards accidents
     rather than confines execution. Tree/index movement or residue parks the run without restoration.
     Refuse whole path tokens beginning a drive-letter path (X:\ or X:/), UNC (\\), or /,
     including single- or double-quoted argument values. Quoted -match/-notmatch regex operands
     are patterns, not paths. Refuse cd, Set-Location, and Push-Location case-insensitively as
     whole command names in command position, including after operators and invocation with &;
     incidental words in arguments/strings are allowed. See the governing contract for the grammar.
     Throw on failure: PowerShell checks must throw when assertions fail. Native commands require
     explicit $LASTEXITCODE tests, e.g. `if ($LASTEXITCODE -ne 0) { throw 'native check failed' }`.
     A check's exit ends its child process, not the Engine process. -->
<!-- Use step→verify format. "Done" must be observable, not vague.
     For doc-only specs, use presence/absence greps, version/date checks, caps, pointers, and the
     exact commands in the repo AGENTS.md `## Verify commands` fence. Reserve exact-line manifests
     and whole-tree content hashes for High risk. -->
- [ ] {Step 1} → verify: {what to check — specific, observable}
- [ ] {Step 2} → verify: {what to check — specific, observable}
- [ ] {Step 3} → verify: {what to check — specific, observable}
<!-- Scope check — use THIS form, never `git diff --stat`: a newly-created file is UNTRACKED, so it
     never appears in a diff at all (and `git add` is not available — the coder may not touch the git
     index), which makes "`git diff --stat` lists exactly N files" unsatisfiable for any spec that
     creates one. `-uall` is required, or a new directory collapses to `dir/` and the file path never
     shows. The output cannot separate your writes from the repo's normal dirty state, so assert the
     LISTED paths — never a total file count. -->
- [ ] Scope — nothing written outside `## Files to Change` → verify: `git status --porcelain -uall`
      lists every path in `## Files to Change` (`??` = created, ` M` = modified), and every other
      path it shows was already dirty before this build (name them in the report).
<!-- Reachability (readiness-gate item): SPEC-LEVEL, or one line per exposed boundary — never per
     task. Name the wiring, not the mechanism. Typed client/server boundary → ROUND-TRIP test.
     deny-unknown-fields is a per-repo choice, never mandated by this slot. -->
- [ ] Reachability — {boundary/entry point} is reached end-to-end from {real caller} → verify:
      {the wiring test/command — for a typed boundary, the ROUND-TRIP test asserting field equality}

## Progress
_(The build writes here — do not edit manually)_
