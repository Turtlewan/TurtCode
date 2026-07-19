---
name: ps51-child-process-traps
description: "PS 5.1: Start-Process -UseNewEnvironment kills a powershell child (8009001d) BEFORE any code runs; inline `python -c \"<code>\"` arrives quote-stripped (NameError). Self-scrub in-child + temp-file/EncodedCommand instead."
metadata: 
  node_type: memory
  type: project
  originSessionId: 6b72db6c-a50a-4343-b937-4c069e62811d
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

(migrated from Artemis memory 2026-07-19)
