---
skill: apex-refresh
version: 2.0.2
last_updated: 2026-07-29
sources:
  - docs/technical/adr/ADR-036-remove-knowledge-layer.md
staleness_threshold: 30d
description: >
  Use when maintaining the skill SET — refreshing against current fact, auditing staleness,
  or stocktake. Triggers: "refresh apex-X", "is this skill stale", "skill stocktake". Not
  authoring (apex-skill-author) or context audit (apex-context-budget).
---

# Refreshing the skill set

## The thing this skill exists to remember

**A truth-audit is structurally blind to redundancy.** Every claim in a skill can verify clean and
the file still be worthless — because the model knew it all along. Redundancy is the *larger* source
of bloat, and it is invisible to the check most people run. APEX carried 17,700 lines for months
while passing every currency check.

**A stale skill is worse than no skill.** With no skill, the model falls back on its prior — which is
decent, and *improves with every model release*. A stale skill overrides that improving prior,
authoritatively and silently, every run, and the agent will never flag it.

That splits the set cleanly:
- **Local facts** (this repo's build command, this project's convention) — no prior to fall back on;
  staleness breaks the build immediately, so it is self-correcting and cheap to hold. **Keep these.**
- **General best-practice content** — decays worst, justifies itself least, competes with a prior
  that is getting better. **This is what to cut.**

**Deletion has no advocate.** Every incident adds a rule; nothing removes one. The set grows by
default. That is not a discipline failure, it is a structural one — so counteract it structurally:
**assume delete, and require a passing probe to keep.**

## Three different problems, three different fixes

| | Detector | Fix |
|---|---|---|
| **Stale** — a dated external fact drifted | extract falsifiable claims (versions, flags, paths, model ids), check against a primary source | refresh the fact; stamp source + date |
| **Wrong** — the instruction fails *here* | apply it and watch it break; grep for cross-skill contradictions | correct it — or remove the *source* of the conflict rather than patching over it |
| **Redundant** — true, current, and the model does it anyway | **RED probe: run a real task with the skill withheld.** No behaviour delta → the skill buys nothing | **delete** |

Only the third finds bloat, and only a probe finds the third.

## Refreshing one skill

1. **Read it.** Note `last_updated`, `sources`, `staleness_threshold`.
2. **Extract every falsifiable claim** — versions, flags, commands, paths, model ids. Everything else
   is behaviour, and behaviour is what the RED probe tests, not the source check.
3. **Verify each claim** against a primary source (changelog, `--help`, real error output) — never
   against the model's recall. That is the same distribution that produced the stale line.
4. **RED-probe the behavioural half** (apex-skill-author § The Iron Law) — sandboxed, no `docs/`.
5. **Show the full proposed rewrite as a diff. Require explicit approval.** Never silently rewrite.
6. On approval: bump `version` + `last_updated`, stamp `sources`, and land the **double-write**
   (`SKILLS.md` + `SKILL-HISTORY.md`).

**If the refresh changes no behaviour, the refresh was a no-op — and that is a DELETE signal, not a
success.**

## Audit (`--audit`)

Cheap, no reading, highest kill-rate first — don't spend research budget refreshing a skill you are
about to delete:

1. **Dates** — `last_updated` vs `staleness_threshold`. 🔴 over · 🟡 approaching · ✅ fresh · ⚠️ no
   metadata header.
2. **Reachability** — is the skill in `SKILLS.md`? Does its `description` actually route? An orphan
   or a never-fired skill dies here without being read closely.
3. **Cross-skill conflict** — grep the set for rules that contradict each other. Two skills
   disagreeing is a bug regardless of which is right.

## Stocktake (`--stocktake`)

The real audit. For each skill, one question: **would an agent WITHOUT this skill produce materially
worse output on a task the user actually performs?**

Dispatch RED probes in parallel, each pinned `model: sonnet` (sandboxed — no planning docs). Then,
per skill:

- **No behaviour delta** → delete.
- **Delta, but it's a local/project fact** → keep; it is exactly what a skill is for.
- **Delta, but it's general best practice** → suspect. Re-probe with a harder task before keeping.
- **Trigger never fires** → delete.
- **Really one rule that belongs inside another skill** → merge.

**Deletion is reversible — it's in git. On a tie, delete.** The asymmetry runs the opposite way to
intuition: the cost of a wrongly-deleted skill is one re-write; the cost of a wrongly-kept one is
paid every session, forever, and it degrades adherence to the rules that *do* matter.

**Budget:** adding a skill requires cutting one, unless the set is demonstrably under-weight.
Without a fixed budget the ratchet has no pawl.

## Automate the detector, gate the edit

Staleness is *silent* — nothing fails loudly — so a cheap scheduled sweep (dates, extracted claims,
reachability) earns its keep. But scheduled *editing* manufactures churn. Real fixes fire on events:
a build failed in a way a skill should have prevented; a dependency or model bumped; a new skill
overlaps an old one.
