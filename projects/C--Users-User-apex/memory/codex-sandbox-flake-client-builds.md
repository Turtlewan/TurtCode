---
name: codex-sandbox-flake-client-builds
description: "Transient Windows 0xc0000142 can kill `codex exec` mid-verify on heavy client builds; proven fallback = host takes over verification and completes missing tests natively"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 3f7452ea-4c1d-4b5e-9bca-26f2ab523e58
  modified: 2026-07-29T09:16:06.964Z
---

On heavy CLIENT (Tauri/npm/cargo) builds, `codex exec` can die with a transient
Windows `0xc0000142` (fs-helper launch failure) — observed twice consecutively on
AL-6b (2026-07-05, session 14). It is NOT a code fault: the source edits land;
only Codex's own in-sandbox verify step is interrupted, which can leave spec'd
tests unwritten.

**Why:** a killed Codex run looks like a build failure, but re-dispatching wastes
a cycle and may hit the same flake; the diff on disk is usually complete except
for the verify-phase artifacts (tests it never got to write).

**How to apply:** on a `0xc0000142` Codex death mid-client-build, don't blindly
re-dispatch. Check the diff first — if the source edits landed, the host takes
over: run the verify natively (`npm`/`cargo` bypass Codex's sandbox), fix small
slips, and hand-write any spec'd tests Codex never wrote, following the test
file's existing conventions. Related: [[host-verify-full-mypy]].

**Second flavor (2026-07-09, ra6b):** the sandbox can also deny ALL writes under
nested worktree paths (ACL denial on `evals/*`, `tests/*`; root-level writes fine)
— worker exits cleanly with ZERO changes. Unlike 0xc0000142 there is no diff to
salvage: one re-dispatch in a FRESH worktree recovered completely. Also: sandbox-SID
residue (`.venv`/`.codex-scratch`) can defeat `git worktree remove` AND `rm -rf`;
after the codex-cleanup trick, `git worktree prune` clears the registry and leftover
dirs are inert disk residue (elevated delete is the owner's call).

**Third flavor (2026-07-17, ask-navigate-client):** the sandbox DETERMINISTICALLY
blocks vitest (esbuild parent-dir access loading vite.config.ts) — every client
task ships untested test code, and full-App-mount tests then fail natively one
missing gateway-mock export per fix round (5 rounds that day; 3 ended as host
test-file fix-forwards). Also: `vi.restoreAllMocks()` in afterEach guts factory-
level `mockResolvedValue` primings — prime inside the mount helper. How to apply:
client specs must MANDATE reusing the file's proven mock setup / a shared
complete-mock helper, and plan host-native vitest per task, not per wave.

(migrated from Artemis memory 2026-07-19)
