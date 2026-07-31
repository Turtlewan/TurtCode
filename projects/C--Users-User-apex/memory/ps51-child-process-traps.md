---
name: ps51-child-process-traps
description: "PS 5.1: Start-Process -UseNewEnvironment kills a powershell child (8009001d) BEFORE any code runs; inline `python -c \"<code>\"` arrives quote-stripped (NameError); `-File` argv is strings-only so an [int[]] param silently kills the script at binding; BOM-less UTF-8 .ps1 files read as ANSI (patterns mojibake). Self-scrub in-child + temp-file/EncodedCommand/BOM instead."
metadata: 
  node_type: memory
  type: project
  originSessionId: 6b72db6c-a50a-4343-b937-4c069e62811d
  modified: 2026-07-30T09:09:22.313Z
---

Two PowerShell 5.1 child-process traps, both found live 2026-07-17 in the installer smoke
(the first masked the second for the fix's whole life):

1. **`Start-Process -UseNewEnvironment` is fatal to a powershell.exe child** — the regenerated
   profile environment breaks crypto-provider load: `Loading managed Windows PowerShell failed,
   error 8009001d`, exit −65536, before the script runs at all. Any "clean env" need → scrub
   inside the child (`$env:PATH = <bootstrap>`, null the poison vars), never via that flag.
2. **Native-arg quoting strips embedded double quotes**: `& exe -c "code with \"quotes\""` style
   pass-through (e.g. `python -c $code`) arrives unquoted → NameError/exit 1. Route code via a
   temp file or `-EncodedCommand`. Same family as [[wsl-argv-quoting-two-layer]].

**Why:** both produce failures that look like the CHECK failing, not the harness — the installer
smoke "failed" on a healthy system for both reasons, serially.

**How to apply:** writing any PS 5.1 code that spawns children (launcher, installer, dispatch
wrappers) → self-scrub + temp-file/base64 channels; treat a child that "fails all checks
instantly" as harness-suspect first. Fixed in `221421e` ([[one-click-current-app-launcher]]).

Two more, found live 2026-07-30 (doctrine-sweep build):
3. **`powershell -File script.ps1 -Tasks 4,5,6` never runs the script** when the param is typed
   `[int[]]` — `-File` argv is strings-only, binding fails silently pre-execution (no log, no
   error surface if output is redirected). Take a `[string]` and split in-body.
4. **A BOM-less UTF-8 `.ps1` is read as ANSI by PS 5.1** — non-ASCII literals (em-dashes in
   Select-String patterns) mojibake and silently never match; checks false-FAIL against healthy
   files. Write generated scripts with a BOM (`UTF8Encoding($true)`).
Also proven that session: harness "killed" background tasks take the whole process tree (a 26-min
codex review died at session resume) — long dispatches survive via detached `Start-Process` +
exit-marker files + Monitor; the codex child itself keeps writing `-o <final>` even if the
wrapper's outer powershell dies.

(migrated from Artemis memory 2026-07-19)
