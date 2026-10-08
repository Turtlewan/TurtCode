# APEX specification validation contract

Contract version: **1.2.0**

This reference describes the mechanical contract enforced by `apex-spec-validate.ps1`. It is not a substitute for the planning workflow's judgment checks.

## Consumers and authority

The contract has two consumers:

1. The `apex-plan` draft-to-changes promotion gate is authoritative. A validation finding blocks promotion.
2. The `codex-dispatch.ps1` pre-flight check is a backstop immediately before dispatch.

The rationale and consumer split are recorded in [ADR-040](~/apex/docs/technical/adr/ADR-040-preflight-gate-and-spec-validator.md).

## Fixed checks and findings

The validator runs these six checks in this fixed order. Findings use the labels shown exactly:

```text
1. FAIL FILES-COMPLETENESS
2. FAIL NO-UNRESOLVED-MARKERS
3. FAIL TASK-CRITERIA-COVERAGE
4. FAIL STRUCTURE
5. FAIL EXEC-MANIFEST
6. FAIL ACCEPTANCE-CHECK
```

Fenced code-block content is excluded from the original four checks. `EXEC-MANIFEST` instead reads the single fence in the optional `## Execution manifest` section. Prose, tables, and inline-code spans outside fences remain visible to the applicable checks. A fence may use backticks or tildes, but its closer must use the same character, be at least as long as the opener, and have no trailing content other than spaces. An unterminated code fence is itself a `STRUCTURE` failure.

## Files completeness

A token counts as a path only when it has a directory component and its basename ends in a 1-5 character alphanumeric extension. The following runtime and transient extensions are exempt: `.exe`, `.dll`, `.bat`, `.cmd`, `.com`, `.log`, `.jsonl`, `.lock`, and `.tmp`.

Matching is case-insensitive and normalizes `\` and `/` separators. Suffix matching occurs only on component boundaries. A bare basename never matches a path that has directory components.

The check compares paths mentioned in Acceptance Criteria and Permissions, plus the text after `files:` in task list items, with entries in Files to Change. Paths found in those checked locations must match an entry in Files to Change.

## Unresolved markers

The token set below is reproduced verbatim from the validator's check-2 regular expression. It is deliberately fenced because fenced content is the one region ignored by the checks; putting this enumeration in ordinary prose would make this contract document violate the contract it documents.

```regex
(?<![A-Za-z0-9_])(?:TBD|TODO|FIXME)(?![A-Za-z0-9_])|(?<!\?)\?\?\?(?!\?)|<placeholder>
```

Matching is case-insensitive. The three marker words use alphanumeric-and-underscore word-boundary guards, and the bare triple question mark uses guards that reject a longer run of question marks. The angle-bracketed placeholder token is matched literally.

## Task and criterion coverage

A declaration is recognized only when a list item starts with the bolded **Task N** form; an optional checkbox may precede the bold text and a single letter may follow the task number. Coverage is bidirectional: a declared task with no criterion fails, and a criterion naming an undeclared task also fails. Task identity matching is case-insensitive.

## Structure

The following eleven level-two headings are required exactly and in this spelling:

```text
## Intent
## Assumptions
## Prerequisites
## Files to Change
## Tasks
## Wave plan
## Permissions
## Specialist Context
## Documentation
## Acceptance Criteria
## Progress
```

Four sections also have mechanical non-empty rules:

1. `Files to Change` must contain a pipe-table data row, after the first pipe row, with a recognized path or bare filename; a header, separator, bare pipe, or `N/A` row alone does not qualify.
2. `Tasks` must contain at least one recognized bolded task list item.
3. `Acceptance Criteria` must contain at least one bulleted or numbered list item.
4. `Permissions` must contain at least one non-whitespace line.

Required headings and qualifying content inside a fence do not count.

## Execution manifest

`## Execution manifest` is optional. If the unfenced heading is absent, `EXEC-MANIFEST` does not run and the spec's validation result is unchanged from the four-check contract. A `json apex-manifest` fence elsewhere does not opt a spec in or count for this section.

When the heading is present, the section must contain exactly one fenced block and its complete, case-sensitive info string must be `json apex-manifest`. The fence body must be valid JSON with this shape:

````text
```json apex-manifest
{
  "version": 1,
  "repos": {
    "repo-key": "C:/absolute/canonical/repo-root"
  },
  "tasks": [
    {
      "id": "1a",
      "repo": "repo-key",
      "files": [
        { "path": "canonical/repo-relative/file.ps1", "op": "modify" }
      ],
      "depends_on": [],
      "effort": "high"
    }
  ]
}
```
````

The root must be an object. `version` is required and must be the JSON integer `1`. `repos` is a required, nonempty object whose nonempty keys are case-sensitive and unique. Each repo value is an absolute, canonical, forward-slash path: a drive path such as `C:/repo` or a slash-rooted path, with no backslash, doubled slash, trailing slash (except a filesystem root), empty segment, `.` segment, or `..` segment.

`tasks` is a required JSON array. Every entry must be an object with these fields:

1. `id` is a string matching a recognized Tasks number with an optional single letter suffix (`^[0-9]+[A-Za-z]?$`). IDs are canonicalized to lowercase for matching. Manifest IDs must be unique ignoring case.
2. `repo` is a nonempty string that exactly names a key in `repos`.
3. `files` is a nonempty array of objects. Each object has a canonical repo-relative `path` and an `op` equal, with exact lowercase spelling, to `create`, `modify`, or `delete`. A canonical path uses forward slashes, has no leading slash or drive prefix, and has no backslash, doubled or trailing slash, empty segment, `.` segment, or `..` segment. Paths within one task must be unique ignoring case.
4. `depends_on` is an array of task-ID strings in the same canonical grammar. Dependencies within one task must be unique ignoring case.
5. `effort` is optional. When present it must be exactly one of `low`, `medium`, `high`, `xhigh`, `max`, or `ultra`. When absent it falls back to frontmatter `coder_effort`, or to `medium` if that key is absent. A frontmatter value used by this fallback must belong to the same set.

The validator classifies each recognized bold Tasks declaration from its title. It is host/owner-run only when that title contains the exact case-sensitive token `(HOST)` or the exact case-sensitive whole word `OWNER`. Thus `OWNER-run` and `(critical, OWNER-run)` qualify, while lowercase `owner`, `HOMEOWNER`, and `(HOSTILE)` do not. Every other recognized declaration is a coder task. Host/owner tasks stay out of the manifest. When a manifest is present, duplicate coder task IDs are rejected ignoring case rather than silently de-duplicated, and the canonical coder-ID set and manifest-ID set must be equal.

For every coder task, the nonempty set of paths after its last `files:` marker must equal that task's manifest `files` set after resolving relative paths through the task's repo root; comparison is by canonical, case-insensitive absolute identity. Every manifest file must appear in Files to Change with the same case-sensitive operation. Every Files-to-Change row must use a canonical absolute or repo-relative path and one of the same three exact lowercase operations, and its file must be owned either by a coder manifest task or exclusively outside the manifest by a host/owner task's `files:` list. An absolute Files-to-Change path is matched directly. A relative row is accepted only when its full repo-relative path identifies exactly one owned path across the declared repo roots; suffix-only matching is never used, and an orphaned or ambiguous row fails.

Each manifest task's repo key must resolve. Every dependency must resolve to a coder task ID, self-dependencies and longer cycles are rejected, and the resulting `depends_on` graph must be acyclic. `depends_on` is the machine dependency source; `## Wave plan` remains human-readable.

## Tagged acceptance checks

Only fences under the exact `## Acceptance Criteria` heading whose complete, case-sensitive info string is `powershell apex-accept` opt in. Surrounding fence whitespace is trimmed; both backtick and tilde fences use the normal fence rules. Untagged fences and fences in other sections are excluded from this check.

The immediately preceding criterion line binds a block to a task only with the exact leading label `^- \[[ xX]\] Task (\d+[a-z]?) -`. Its ID must occur in the execution manifest (case-insensitive identity); HOST tasks outside the manifest cannot bind. A leading task label with a compound or malformed ID is refused. An unlabelled criterion binds to spec level; labels mentioned later in prose do not bind.

The safety grammar inspects PowerShell command tokens, including whole single- or double-quoted argument values with their outer quotes removed. It refuses tokens beginning a drive-letter path (`X:\` or `X:/`, any letter), a UNC path (`\\`), or `/`. Quote-delimited operands of `-match` or `-notmatch` (including explicit case variants) are regex patterns, not path tokens. It refuses `cd`, `Set-Location`, and `Push-Location` case-insensitively only as whole command names in command position, including statement/pipeline operators and invocation with `&`. Incidental command words in strings or arguments are accepted. Comments are not command tokens. Shared examples are the array of `{ "text": string, "expected": "accept"|"refuse" }` entries in `accept-grammar-vectors.json`.

`FAIL ACCEPTANCE-CHECK` reports each prohibited path token or location command, compound/malformed leading task label, or unknown manifest task ID, with the fence line number. This finding follows `EXEC-MANIFEST` and does not affect legacy untagged content.

Tagged checks are trusted author-written, Critic-reviewed, owner-promoted spec content. They run unsandboxed with integration-root cwd and the same trust as the `AGENTS.md` verify fence. The grammar guards accidents rather than confines execution. Tree/index movement or residue parks the run without restoration. Checks must throw on failed assertions, including explicit `$LASTEXITCODE` tests after native commands (for example, `if ($LASTEXITCODE -ne 0) { throw 'native check failed' }`). A check's `exit` ends its child process, not the Engine process.

## Changing the contract

The contract version is written in exactly two places:

1. `$SpecContractVersion` in `skills/apex-code/scripts/apex-spec-validate.ps1`, which is the source of truth.
2. The `Contract version` line at the top of this reference.

The spec template's contract pointer is deliberately version-less, so it never becomes a third version site that can drift. The sweep and this reference are the mechanisms that catch drift instead.

For every contract change, run this procedure in order from the repository root:

1. Bump `$SpecContractVersion` in the validator and update the version line in this reference to the same value.
2. Run the hermetic validator test and ordinary corpus test against the existing live `expected.tsv`:

   ```powershell
   powershell.exe -NoProfile -File skills/apex-code/scripts/spec-validate-test.ps1
   ```

3. Run the report-only sweep over the corpus and inspect every per-spec result:

   ```powershell
   powershell.exe -NoProfile -File skills/apex-code/scripts/spec-contract-sweep.ps1 -Root skills/apex-code/scripts/fixtures/spec-corpus
   ```

   The sweep only reports results; it does not write the TSV. If an expected outcome truly changed, update only the justified row or rows in `skills/apex-code/scripts/fixtures/spec-corpus/expected.tsv`, then diff the live TSV:

   ```powershell
   git diff -- skills/apex-code/scripts/fixtures/spec-corpus/expected.tsv
   ```

   Justify **every changed row individually** as an intended behaviour change, and record each justification in the changing spec or its commit message before committing the manifest. An unexplained changed row is a regression to fix, not a new expectation to accept. Wholesale regenerate-and-commit is forbidden precisely because it would launder a semantic break into a green suite.

4. Re-run the hermetic and corpus test after any justified row edits:

   ```powershell
   powershell.exe -NoProfile -File skills/apex-code/scripts/spec-validate-test.ps1
   ```

   For an additive, backward-compatible change such as a new optional section, if the hermetic test and ordinary corpus test both pass against the existing, unmodified `expected.tsv`, no regenerate/diff/justify step is needed for that change.

5. Run the report-only sweep once for each live repository's spec directories, then act on every report before shipping:

   ```powershell
   powershell.exe -NoProfile -File skills/apex-code/scripts/spec-contract-sweep.ps1 -Root C:\path\to\live-repo
   ```

   Repeat the command with each live repository root. The sweep must cover that repository's live spec directories and never modifies a spec.
