# System map format and host protocol

The system map is a host-maintained component index for the target code repository.
It records boundaries and evidence so planning can find the relevant code quickly.
Git history and live code are authoritative: git still wins over every map claim.
Map reads are read-only; freshness checking never rewrites the map or repository.

## Location and section grammar

Start with `docs/system-map.md`. Its map marker is:

```markdown
<!-- apex:system-map -->
```

Each component starts with `## <component>` followed immediately on the next line
by this exact header grammar, with fields in this order:

```text
<!-- apex:map-section covers: <p> [<p>...] contracts: [<p>...] seams: [<p>...] verified: <40-hex> -->
```

Angle brackets and square brackets above describe placeholders and optional
repeated tokens; they are not literal map values. `covers` must contain at least
one path. `contracts` and `seams` may be empty. `verified` is the full 40-hex Git
commit SHA whose covered code the host surveyed, not a date or abbreviated SHA.
Every `##` heading in a component map introduces a component section; use bold
labels or lower-level headings for the section's body.

Paths are repository-relative forward-slash tokens without spaces. Absolute
paths, traversal, malformed fields, and invalid UTF-8 are errors. Use Git
`:(glob)` pathspec semantics for cover globs and contract/seam lookups:

- A literal path matches that exact path or its descendants as a directory prefix.
- `*` matches within one path segment.
- Leading `**/` matches zero or more leading directories.
- Trailing `/**` matches everything inside a directory.
- `/**/` matches zero or more directories between segments.

Choose covers for the component's implementation and relevant tests/configuration;
do not expand covers into an inventory of today's files. Include contracts and
seams explicitly, even when they are also covered implementation paths.

Each component body records:

- **Role:** what the component owns and its boundary.
- **Contracts:** public APIs, formats, schemas, entry points, and invariants others
  rely on, with their declaring `file:line` pointers.
- **Seams:** integration boundaries, adapters, hooks, dispatch/routing points, and
  configuration interfaces, with `file:line` pointers.
- **Dependents:** named components or consumers and what each relies on.
- **Evidence:** implementation and test `file:line` pointers supporting the claims.

Pointers use repo-relative paths and actual surveyed line numbers. They help a
reader locate evidence; the header's path tokens drive machine checks. Recheck
pointers against live code when using a section.

Illustrative section only; replace the SHA and pointers with verified evidence:

```markdown
# System map
<!-- apex:system-map -->

## API
<!-- apex:map-section covers: src/api/** tests/api/** contracts: src/api/schema.json seams: src/api/router.ts verified: 0123456789abcdef0123456789abcdef01234567 -->

**Role:** Owns request validation and endpoint routing.
**Contracts:** Request schema (`src/api/schema.json:1`).
**Seams:** Router registration (`src/api/router.ts:24`).
**Dependents:** Web client consumes the request schema; server registers routes.
**Evidence:** Validation (`src/api/validate.ts:18`); route tests (`tests/api/routes.test.ts:12`).
```

## Freshness and targeted re-survey

The HOST runs the checker from the skills installation against an absolute path
to the target code repository, which may differ from the skills repository:

```powershell
$targetRepo = 'C:/absolute/path/to/code-repo'
$mapChecker = Join-Path $env:USERPROFILE '.claude/skills/apex-plan/scripts/apex-map-check.ps1'
& $mapChecker -Repo $targetRepo -Stale
$mapExit = $LASTEXITCODE
```

The checker reads `docs/system-map.md` when present; otherwise it reads
`docs/system-map/index.md`. For each verified ancestor of HEAD, it compares only
the declared covers using
`git diff --name-status -z --find-renames --ignore-submodules=none <sha>..HEAD -- :(glob)<cover>...`.
Changed, deleted, or renamed covered paths make that section stale. Covers are
passed to Git without expanding them into a current file inventory.

A missing verified SHA is stale; this is the sole tolerated header defect in
`-Stale` mode. An unknown SHA is stale, as is a valid SHA that is not an ancestor
of HEAD. Other malformed headers are errors. A marker-only stub is no map; any
map with zero component sections is also no map, with `no map sections` output.

| Exit | Meaning | HOST action |
|------|---------|-------------|
| 0 | All sections fresh, or a valid lookup | Continue using the result. |
| 1 | One or more stale sections | Re-survey only the named stale sections. |
| 2 | Usage, parse, UTF-8, or Git transport failure | Stop relying on the result; resolve the failure and rerun. |
| 3 | No map sections | Follow the no-map rule; a stub supplies no component evidence. |

For stale sections, inspect their current code, contracts, seams, dependents, and
tests; correct claims and pointers, then stamp the fully surveyed HEAD SHA and
rerun `-Stale`. Leave fresh sections alone. A successful history comparison does
not certify unstaged or staged edits: inspect live changes before trusting the
claims. Git/live code wins when either contradicts the map.

The map Scribe dispatch rewrites affected sections without stamping verified:. A rewritten section whose covers include a changed path reports stale at the next apex-map-check.ps1 -Stale run after the commit that integrates the change lands, because the checker compares the verified SHA to HEAD and ignores staged or working-tree edits; the HOST re-surveys and stamps it under the existing freshness protocol. A Touches-only section whose covers are unchanged keeps its stamp. When map_update is skipped or rejected, the handoff names the affected sections for targeted re-survey; -Stale catches only covers-changed sections. The HOST repairs covers listed in map_cover_repair during the next re-survey. Drained (AFK) specs get no map update.

The checker also provides mutually exclusive lookup modes:

```powershell
& $mapChecker -Repo $targetRepo -Touches @('src/api/router.ts')
& $mapChecker -Repo $targetRepo -Owner 'src/api/router.ts'
```

`-Touches` prints sections whose contracts or seams match a predicted path; it
does not match covers. `-Owner` matches covers only. Optional `-Json` emits the
same results as ASCII-escaped JSON; human machine-readable output is escaped too.
Both lookup modes require valid headers, including the verified SHA.

The checker and size guard are read-only in their target repositories and fail
closed on parse errors, invalid UTF-8, Git launch/exit errors, and timeouts. Each
Git child has a 120-second timeout, closed redirected stdin, concurrent output
drains, disabled optional locks/lazy fetch/network protocols, and repository
selection isolated from inherited Git repository/pathspec environment overrides.
An error is never evidence of freshness or of a small change.

## Four-part Trivial test

All four criteria must hold before treating a change as Trivial:

1. One predicted file and at most 10 changed lines (added plus deleted).
2. `-Touches` finds no contract or seam for the predicted path.
3. No behavior change; skills/config/code are counted as behavior, including
   instructions or configuration that change what the system does.
4. No High-tier path under the normal risk/model-routing policy.

For a repo without a map (including a marker-only stub), skip the map read and
criterion 2, the `-Touches` contract/seam check. Criteria 1, 3, and 4 still apply;
absence of a map does not prove that a change is Trivial.

Trivial still uses a one-task Light spec on the normal wrapper path. It is exempt
only from the map read; normal scope, verification, review, and HOST close-out
remain in force. This reference documents the protocol; it does not change the
planning gate or wrapper routing.

At HOST close-out, after staging the proposed commit, run Task 2's staged size
guard with the spec's predicted paths:

```powershell
$sizeGuard = Join-Path $env:USERPROFILE '.claude/skills/apex-plan/scripts/apex-size-guard.ps1'
& $sizeGuard -Repo $targetRepo -Paths @('README.md') -MaxFiles 1 -MaxLines 10
$sizeExit = $LASTEXITCODE
```

Use the actual predicted path rather than the example. The guard measures the
whole staged index against HEAD, counting each changed file once and summing
added plus deleted lines. Every staged path must be predicted, including both
sides of a rename. A binary row is OVER. Unstaged/untracked residue is reported
as warning counts and is excluded from the staged measurement.

`WITHIN` (exit 0) confirms only the measured size and prediction. `OVER` (exit 1)
triggers a map read and normal review before commit; the no-map read exception
still applies where no map exists. Resolve the overrun through normal planning
and review, then rerun the guard on the final staged commit. Exit 2 is a blocking
error, including no HEAD or no staged changes. The HOST owns staging and commits;
the coder leaves its work dirty.

## Split index

At about 400 lines, split the map into `docs/system-map/<component>.md` plus
`docs/system-map/index.md`. Each component file retains the section grammar and
evidence above. The split index has the marker and one `- <file>.md` entry per
line, naming files relative to `docs/system-map/`:

```markdown
# System map index
<!-- apex:system-map -->

- api.md
- worker.md
```

Keep component descriptions and headers in the referenced files. Missing split
files are parse errors. During migration retire the root `docs/system-map.md`;
otherwise root-map precedence hides the split index. Update the AGENTS pointer
to `docs/system-map/index.md` after splitting.

## Opus host-written first map

Bootstrap creates only a marker stub. The Opus HOST owns the host-written first
map for the target code repo; this task does not write a real map or require one
before an ordinary no-map build.

1. Select the target code repository explicitly and record `git -C <repo>
   rev-parse HEAD`. Inspect its working-tree changes so the survey distinguishes
   the committed snapshot from live edits.
2. Sweep entry points, packages, runtime flow, public contracts, configuration,
   integration seams, tests, and consumers. Read code and follow references;
   directory names and existing prose alone do not establish component roles.
3. Draft component boundaries and cover globs. Cross-check each contract and seam
   against its implementation and dependents. Record actual `file:line` evidence
   and the full SHA of the committed code surveyed. Incorporate live changes only
   once their committed baseline can be verified; do not stamp unsurveyed code.
4. Write the map with the marker and exact headers, or the split index and
   component files when needed. Read it back against live code and test evidence;
   run `-Stale`, representative `-Owner` lookups, and `-Touches` lookups at known
   boundaries. Resolve parse/Git failures and stale sections before declaring the
   first map verified. If HEAD advances, recheck and re-survey affected sections.
5. Put one AGENTS pointer after the Verify commands closing fence, or after the
   entire verify marker stub block when the stack is TBD. Keep it outside the
   commands and stub, and preserve the System Overview stub as a separate artifact.
6. The HOST stages the verified map for normal review. For the ignored
   `~/.claude` map, use `git -C "$targetRepo" add -f -- docs/system-map.md`;
   for a split map, explicitly force-add `docs/system-map/index.md` and each
   referenced `docs/system-map/<component>.md`. These are HOST instructions,
   not permission for the coder to stage or commit.
