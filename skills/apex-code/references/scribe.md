# Scribe: attended HOST close-out

Run once per repository after the build Critic cadence is clean or its owner
resolution is recorded, before the family gate and technical-docs handoff.
This is HOST mechanics under ADR-046 D1; builders never stage or commit. Require
the `wrapper-model-luna` prerequisite, the absolute promoted spec, the build's
pinned PRE-BUILD BASE SHA, and the exact staged build paths and operations.
Stop on a missing prerequisite; do not substitute integration HEAD for the base.

Anchors (73d6dff unless noted):

- [SKILL.md](../SKILL.md):367-378,389-446 (close-out), 97-110,396-398
  (critical-file policy and ledger schema).
- [codex-dispatch.ps1](../scripts/codex-dispatch.ps1):9-19,30-36,69-70
  (dispatch parameters; Luna admission is the prerequisite).
- [apex-critical-files.ps1](../scripts/apex-critical-files.ps1):103,204
  (per-path `HARDBLOCK` and `CRITICAL` output).
- [parallel-codex.md](parallel-codex.md):51-132 (operation-aware integration
  and D8 teardown); shortened references below mean this same file.
- [tree-pin.ps1](../scripts/tree-pin.ps1):20-49 (pin, digest, verify).
- [hooks/apex-ledger-append.ps1](C:/Users/User/.claude/hooks/apex-ledger-append.ps1):13-23
  (live HOST helper, absent at 73d6dff; base64 append interface).

Commands below are templates: replace angle-bracket placeholders with validated,
quoted literal values. Use the installed scripts under
`$env:USERPROFILE/.claude/skills/apex-code/scripts` for each repo. In PowerShell,
pass `A` as a string array to `-Authorized`; never pass comma-joined CLI paths.
Retain per-repo base, operation map, selected model, dispatch identity, and skips.

## 1. Derive authorization after step 2

Prepare the repo's spec file list now; finish this step only after step 2 creates
`SCRIBE_BASE`. Derive the actual changed set with:

```text
git diff --name-status <pre-build-base> SCRIBE_BASE
```

Parse statuses and path identities safely (use `-z` for machine parsing). Drop
every `D` entry and every `R` source; retain rename destinations as candidates.
Intersect with this repo's spec `## Files to Change`. Convert absolute HOST paths
to repo-relative paths after canonicalizing the repo boundary; drop paths outside
the repo. Reject traversal, directories, symlinks/reparse points, submodules,
unsafe ancestors, and ambiguous path identities as in parallel-codex.md:51-122.

Keep source paths other than CHANGELOG.md, README.md, ADR, status, handoff, and
docs-changes paths. Exclude ADR documents, status documents, handoff documents,
and `docs/changes/` paths; do not read or authorize host bookkeeping. There is
no extra exemption for changed source tests or configuration: apply the same
source-edit rule and critical classifier to them.

Add `{CHANGELOG.md, README.md}` as candidates only when each is explicitly listed
in the spec's `## Files to Change` for this repo, even if unchanged by the build.
Record `create` if absent in `SCRIBE_BASE`, else `modify`. Record source candidates
as `modify` because they exist in `SCRIBE_BASE`, including build-created files
and rename destinations. Never authorize source creation or deletion by Scribe.
Report needed but unlisted docs as skips in `docs_skipped_unlisted`; do not widen
the spec, generate an unlisted doc, or grant a directory.

Run this for **each candidate**, with one repo-relative path per invocation:

```text
skills/apex-code/scripts/apex-critical-files.ps1 -Test -Paths <path> -Root <repo>
```

Drop every path named on a `CRITICAL` or `HARDBLOCK` line, recording the reason.
Exit 10/11 classifies named paths; do not discard the whole candidate set because
of that exit code. Stop on an unexpected classifier failure. The survivors are
`A`: record each path's create/modify op for integration and pass only these
repo-relative paths to `-Authorized`. Preserve existing D6 exemptions unchanged;
they do not enlarge Scribe scope. Record empty `A` as `skipped` without dispatch.

## 2. Materialize the operation-aware Scribe base

From the pinned PRE-BUILD BASE SHA create the branch and linked worktree:

```text
git -C <repo> worktree add <repo>-wt/<spec>-scribe -b codex/<spec>-scribe <pre-build-base>
```

Before copying, require index == working tree for **every staged build path**
in the integration tree. From that tree, run:

```text
git diff --quiet -- <path>
```

Require exit 0 per path. For deletions additionally require the path absent from
both index (`git ls-files --stage -- <path>` has no entry) and working tree,
including dangling links. Stop and report any mismatch and exact paths to the
owner; copying unstaged bytes would document a different build.

Copy exactly those staged build bytes onto the worktree from the pre-build base
using the same operation-aware byte-copy or indexed `git apply` procedure in
references/parallel-codex.md:51-122. Validate declared `create`, `modify`, `delete`
against the base: create absent, modify/delete present as regular blobs. For
byte-copy, verify source/destination raw SHA-256 equality; remove only declared
deletions whose integration index and working-tree absence was proved. For
indexed apply, use the integration index's binary diff from pre-build base,
`git diff --cached --binary <pre-build-base> -- <staged-build-paths>`, with
`git apply --check --index` then `git apply --index` in the fresh worktree.
Preserve modes and filters; run the reference's path, filtered-hash, index and
staged-set checks. Never use raw `git show` redirection as a byte-copy substitute.

The HOST stages only these exact paths in the Scribe worktree (use `git add -f`
only for explicitly named ignored files) and commits there:

```text
git -C <scribe-worktree> add -- <staged-build-paths>
git -C <scribe-worktree> commit -m "build(<spec>): scribe base"
git -C <scribe-worktree> rev-parse HEAD
```

Record that SHA as `SCRIBE_BASE`; verify it captures exactly the staged build
result and the worktree is clean. This transient `codex/*` task-branch commit is
ADR-046 D1 build mechanics. Never commit on the integration branch. Complete
step 1 against this SHA before continuing.

## 3. Dispatch Luna with a fact-bounded pack

Invoke per repo, replacing `SCRIBE_BASE` with its recorded SHA:

```text
codex-dispatch.ps1 -Spec <s> -SpecSourcePath <absolute-spec> -Task scribe -Phase build -Model gpt-6-luna -Effort low -Attended -Worktree <scribe-worktree> -BaseSha SCRIBE_BASE -Authorized <A> -Prompt <pack>
```

Use the wrapper, never raw `codex exec`. Capture wrapper exit, `.final`, log path,
and selected dispatch identity. The pack must contain the pre-build-base ->
`SCRIBE_BASE` diff limited to `A` source files (`git diff <pre-build-base>
SCRIBE_BASE -- <A-source-paths>`), verbatim `## Intent`, the operation map, and
the current CHANGELOG/README only when each is in `A` (mark absent files).
Include step 4 verbatim as the source-edit contract. Allow only diff/Intent-
supported facts, the existing CHANGELOG style, user-facing README content, and
source documentation comments. Do not invent behavior, promises, or features.

## 4. Enforce the source-edit contract

Allow C#/Java/TS/JS `///` and `/** */`, JS/TS `//`, Python first-statement
module/class/def docstrings and `#`, and PowerShell comment-based help and `#`.
Allow whitespace edits only within comments. Python docstrings (the
first-statement string literal of a module/class/def) are the sole exception:
they may be added or edited although they are string tokens. Reject every other
string or code token change, including whitespace outside comments; do not
change declarations, imports, control flow, identifiers, literals, configuration
values, or test assertions. Use language-aware token/AST inspection when needed
to distinguish actual comments/docstrings from strings containing comment syntax.

Reject any add/remove/edit of directive or pragma comments, including
`eslint-disable`, `@ts-ignore`, `#pragma`, `# type:`, `# noqa`, `#requires`,
`#region`, shebang, and encoding declarations. This prohibition applies even
inside otherwise allowed comment forms. Unsupported source comment forms get
no edits; authorization alone never permits code edits. CHANGELOG/README are
prose exceptions subject to the supported-fact rule, not source-edit exceptions.

## 5. Select at most one model-availability retry

On a failed dispatch, inspect `.final` and log. Quota/429/usage-limit,
"model at capacity", or a launch error naming the model/quota/capacity permits one
non-destructive retry regardless of wrapper exit code: the wrapper maps child
and launch failures to exit 1. **Except exit 79**, which stays queue/park; never
use model fallback to bypass capacity leases.

Retain the failed worktree. Create a NEW branch/worktree from the same
`SCRIBE_BASE`, with no failed-result bytes copied:

```text
git -C <repo> worktree add <repo>-wt/<spec>-scribe-sol -b codex/<spec>-scribe-sol SCRIBE_BASE
codex-dispatch.ps1 -Spec <s> -SpecSourcePath <absolute-spec> -Task scribe -Phase build -Model gpt-6-sol -Effort low -Attended -Worktree <repo>-wt/<spec>-scribe-sol -BaseSha SCRIBE_BASE -Authorized <A> -Prompt <pack>
```

Use the same flags and pack, `-BaseSha SCRIBE_BASE -Authorized <A> -Model
gpt-6-sol -Effort low`. Select the retry's wrapper ledger row for the gate key
and selected worktree/model. No second fallback. A launch failure without
model-availability evidence (missing executable, permission denied, sandbox
error) has no retry and goes to the owner. Exit 79 stays queue/park; every other
nonzero without that evidence has no retry and goes to the owner. Retain all
diagnostic worktrees; no reset, cleanup, or overwrite of a failed attempt.

## 6. Bind Critic, verification, and family gate to the selected build

After exit 0, read the latest wrapper ledger row with `spec=<s>, task=scribe`
for the selected dispatch, matching its worktree and launch identity. Take
`run_id`, `worktree_key`, and `end_tree_digest` verbatim; never reconstruct the
key from a local path or select the failed Luna row after a successful retry.
Resolve the ledger at `%APEX_STATE_DIR%/progress/codex-run-ledger.jsonl`, else
`%LOCALAPPDATA%/apex/progress/codex-run-ledger.jsonl`, else
`%TEMP%/apex/progress/codex-run-ledger.jsonl`.

Run in this order on the selected Scribe worktree:

```text
tree-pin.ps1 -Pin -Worktree <scribe-worktree> -Label <spec>-scribe
tree-pin.ps1 -Digest -Worktree <scribe-worktree>
```

Record the digest and require equality with ledger `end_tree_digest`. A missing,
unverifiable, or unequal digest stops close-out; report tree movement to owner.
Dispatch `apex-critic` through the Agent tool with `model: sonnet`, `mode: code`,
over the full Scribe diff versus `SCRIBE_BASE`. Supply `A`, operations, pack,
and step 4. Use the same comment-only rule, including its sole Python
first-statement docstring exception and prohibition on every other string or
code token change, as the source-edit pass criterion; check fact support for
docs and that changed paths are a subset of `A`. BLOCK on any violation.

On return, verify the original pin before acting on the verdict:

```text
tree-pin.ps1 -Verify -Worktree <scribe-worktree> -Label <spec>-scribe
```

Require exit 0 and set `reviewed_tree_digest` to that pinned digest. THEN run
the repo `AGENTS.md` `## Verify commands` fence in the selected Scribe worktree,
in order, requiring all commands to pass. Immediately verify the same pin again:

```text
tree-pin.ps1 -Verify -Worktree <scribe-worktree> -Label <spec>-scribe
```

If verification moved the tree, do not integrate or silently re-run; report to
the owner. Do not re-pin to bless a different tree. Only after clean Critic,
successful verification, and both successful pin checks append this review row
through `hooks/apex-ledger-append.ps1` (the live helper linked above):

```powershell
$row = [ordered]@{
  run_id = "insession-$([guid]::NewGuid())"
  in_session = $true
  spec = $s
  task = 'scribe'
  worktree_key = $selectedRow.worktree_key
  phase = 'review'
  builder_family = 'openai'
  reviewer_family = 'anthropic'
  builder_model = $selectedModel
  attended = $true
  reviewed_run_id = $selectedRow.run_id
  reviewed_tree_digest = $pinnedDigest
  status = 'done'
  started = [DateTime]::UtcNow.ToString('o')
}
$json = $row | ConvertTo-Json -Compress
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE/.claude/hooks/apex-ledger-append.ps1" -LineBase64 $b64
```

Require append exit 0. `builder_model` is the selected `gpt-6-luna` or
`gpt-6-sol`; `reviewed_run_id` is Scribe `run_id`; `worktree_key` is exactly
the selected wrapper row's value, and `reviewed_tree_digest` is the pinned digest.
The helper serializes with the wrapper's `ApexCodexRunLedger` mutex; never append
with bare `Add-Content`. Then run and require exit 0:

```text
apex-family-gate.ps1 -Spec <s> -Task scribe -WorktreeKey <ledger worktree_key>
```

## 7. Commit the reviewed result, then integrate only its delta

After all gates pass, immediately before the HOST stages exactly the files Scribe
changed (a subset of `A`) and commits the selected Scribe worktree result on
`codex/<spec>-scribe` or selected retry branch `codex/<spec>-scribe-sol`, require
the original pin verification below to exit 0. The fingerprint includes HEAD,
so this check must precede the commit. On non-zero verify, stop, integrate
nothing, and report to the owner.

```text
tree-pin.ps1 -Verify -Worktree <scribe-worktree> -Label <spec>-scribe
git -C <scribe-worktree> add -- <scribe-changed-paths>
git -C <scribe-worktree> commit -m "build(<spec>): scribe"
git -C <scribe-worktree> rev-parse HEAD
```

Use `git add -f` only for explicitly named ignored files. Record the resulting
SHA as `<commit>`. After the commit, run both commands for every Scribe-changed
path `<p>` and require exit 0 and equal outputs:

```text
git -C <scribe-worktree> hash-object --path <p> <p>
git -C <scribe-worktree> rev-parse <commit>:<p>
```

On any mismatch or command failure, stop, integrate nothing, and report the
exact paths to the owner. Require authorized paths to be clean and committed
modes to match the reviewed modes. If Scribe changed nothing, record `skipped` and
do not create an empty commit.
Never commit the integration branch. Integrate only `SCRIBE_BASE` -> committed
Scribe result, never the pre-build-base -> result diff.

Use the attended HOST Bash indexed `git apply` pipe in
references/parallel-codex.md:51-122 for the exact changed paths. Precheck literal
paths, recorded create/modify ops, and index/working-tree filtered hashes against
`SCRIBE_BASE`: modify must equal its base blob; create must be absent from base,
index, and working tree. Record each result's filtered hash with
`git -C <scribe-worktree> hash-object --path <path> <path>` and require equality
to its committed blob. Reject mismatches before applying; protect owner edits.

In the integration tree, set Bash `base` to `SCRIBE_BASE`, `branch` to the
committed Scribe SHA, and array `paths` to the exact Scribe-changed subset of `A`.
There are no Scribe deletions. Run:

```bash
set -e
set -o pipefail
export GIT_LITERAL_PATHSPECS=1
BEFORE=$(git diff --cached --name-only --no-renames "$base")
git diff --binary "$base" "$branch" -- "${paths[@]}" | git apply --check --index
git diff --binary "$base" "$branch" -- "${paths[@]}" | git apply --index
AFTER=$(git diff --cached --name-only --no-renames "$base")
```

These instantiate the following templates; use the committed result here:

```text
git diff --binary SCRIBE_BASE <scribe-branch-commit-or-worktree-state> -- <paths> | git apply --check --index
git diff --binary SCRIBE_BASE <scribe-branch-commit-or-worktree-state> -- <paths> | git apply --index
```

Git apply is atomic: a failed check or apply leaves the integration tree
unchanged. Require both pipes exit 0. Compare BEFORE/AFTER as exact path sets:
AFTER minus BEFORE must equal the changed subset, BEFORE minus AFTER must be
empty. Comparing against `SCRIBE_BASE` makes the already-staged build the base.
Decode Git-quoted identities; refuse newline-containing paths. Postcheck each
working-tree filtered hash (`git hash-object --path <path> <path>`) and index
blob against the recorded committed result. On any postcheck mismatch after
apply, report exact paths to owner and take no further automatic action.

Run the integrated-main verify fence per parallel-codex.md:124-128; route any
failure to owner without automatic rollback. On BLOCK, verify, pin, or gate
failure integrate nothing, retain worktrees, record diagnosis in handoff, and
ask owner to redispatch docs-only with `A` limited to CHANGELOG/README listed
in `## Files to Change` or skip. Mark a rejected result `discarded`.

Teardown follows D8 and the owner `!` handback
(references/parallel-codex.md:132): require clean creator-owned worktrees and
the canonical D8 path-scoped branch-diff check after the approved integration
commit. Retain failed attempts for diagnosis; never infer teardown permission
from ancestry or bypass guards. Before archival the HOST runs:

```text
codex-dispatch.ps1 -ListObligations
```

Discharge reported cleanup/branch obligations through the permitted D8 route.

## 8. Deliver the technical-docs input

Deliver one per-repo result to `apex-docs-technical-agent`:

```text
scribe_summary = {status: integrated|skipped|discarded, model: used model including fallback, files_written: paths, docs_skipped_unlisted: paths, reason: text}
```

Use `integrated` only after successful integration and verification; list exact
repo-relative integrated paths in `files_written`. Use `skipped` for empty `A`,
no edits, or owner-approved skip; use `discarded` for rejected/failed results.
For skipped/discarded results set `files_written` to `[]`, retain diagnostics,
and explain queue/park or owner routing in `reason`. Record the used model,
including `gpt-6-sol` fallback and failed Luna attempt when applicable; use
`none` when no dispatch ran. Always carry `docs_skipped_unlisted` even if empty.
Send model/fallback/discard reasons for Decisions Made and unlisted-doc skips
for What's Next in the technical-docs handoff. Do not hide a discarded attempt
behind a successful retry; include its diagnosis in `reason`.
