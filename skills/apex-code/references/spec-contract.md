# APEX specification validation contract

Contract version: **1.0.0**

This reference describes the mechanical contract enforced by `apex-spec-validate.ps1`. It is not a substitute for the planning workflow's judgment checks.

## Consumers and authority

The contract has two consumers:

1. The `apex-plan` draft-to-changes promotion gate is authoritative. A validation finding blocks promotion.
2. The `codex-dispatch.ps1` pre-flight check is a backstop immediately before dispatch.

The rationale and consumer split are recorded in [ADR-040](~/apex/docs/technical/adr/ADR-040-preflight-gate-and-spec-validator.md).

## Fixed checks and findings

The validator runs these four checks in this fixed order. Findings use the labels shown exactly:

```text
1. FAIL FILES-COMPLETENESS
2. FAIL NO-UNRESOLVED-MARKERS
3. FAIL TASK-CRITERIA-COVERAGE
4. FAIL STRUCTURE
```

Fenced code-block content is excluded from all four checks. Prose, tables, and inline-code spans outside fences remain visible to the applicable checks. A fence may use backticks or tildes, but its closer must use the same character, be at least as long as the opener, and have no trailing content other than spaces. An unterminated code fence is itself a `STRUCTURE` failure.

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

## Changing the contract

The contract version is written in exactly two places:

1. `$SpecContractVersion` in `skills/apex-code/scripts/apex-spec-validate.ps1`, which is the source of truth.
2. The `Contract version` line at the top of this reference.

The spec template's contract pointer is deliberately version-less, so it never becomes a third version site that can drift. The sweep and this reference are the mechanisms that catch drift instead.

For every contract change, run this procedure in order from the repository root:

1. Bump `$SpecContractVersion` in the validator and update the version line in this reference to the same value.
2. Regenerate the fixture manifest:

   ```powershell
   powershell.exe -NoProfile -File skills/apex-code/scripts/spec-validate-test.ps1 -RegenerateExpected
   ```

3. Diff the regenerated manifest against its previously committed version:

   ```powershell
   git diff -- skills/apex-code/tests/spec-validator/expected.tsv
   ```

   Justify **every changed row individually** as an intended behaviour change, and record each justification in the changing spec or its commit message before committing the manifest. An unexplained changed row is a regression to fix, not a new expectation to accept. Wholesale regenerate-and-commit is forbidden precisely because it would launder a semantic break into a green suite.

4. Run the corpus test:

   ```powershell
   powershell.exe -NoProfile -File skills/apex-code/scripts/spec-validate-test.ps1
   ```

5. Run the report-only sweep once for each live repository's spec directories, then act on every report before shipping:

   ```powershell
   powershell.exe -NoProfile -File skills/apex-code/scripts/spec-contract-sweep.ps1 -RepoPath C:\path\to\live-repo
   ```

   Repeat the command with each live repository root. The sweep must cover that repository's live spec directories and never modifies a spec.
