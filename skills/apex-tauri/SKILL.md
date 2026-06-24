---
skill: apex-tauri
backend: claude
version: 1.0.0
last_updated: 2026-06-24
sources:
  - docs/research/2026-06-24-tauri2-stack.md (Artemis project)
  - Context7 /websites/v2_tauri_app (fetched 2026-06-24)
  - MS Learn — NCrypt / KeyCredentialManager (fetched 2026-06-24)
staleness_threshold: 30d
description: >
  Use when building or designing a Tauri 2 desktop app — a Rust shell hosting a web
  (React/Vite/TS) webview: project scaffold, tauri.conf.json, IPC commands/events/channels,
  capabilities/permissions (ACL) + CSP, cross-platform WebKit-safe rendering (WebView2 vs
  WKWebView), and native crypto/OS FFI from Rust. Triggers: "Tauri", "Tauri 2", ".exe/.app
  desktop client", "webview app in Rust", "invoke command", "capabilities/permissions",
  "backdrop-filter broken in the webview". Not generic React (apex-frontend), not the
  brain/server side (apex-python), not whether to pick Tauri at all (apex-stack).
---

# apex-tauri — Tauri 2 desktop client (planning)

Stack skill (ADR-005) for **Tauri 2.x** apps: a Rust core (`src-tauri/`) hosting a web frontend
(React + TypeScript + Vite) shipped as a native binary (`.exe` → `.app`). The meat — NEVER/ALWAYS,
patterns, the Verification Recipe — is in `impl.md`; this file is the planning "what to weigh."

## Boundary — what this skill is NOT
- **Not the React/DOM half** — component design, hooks, client state → `apex-frontend`. This skill owns the **Tauri shell**: Rust core, IPC, config, capabilities, the webview/build target.
- **Not the server** — the brain/gateway it talks to is `apex-python`. The client is a thin HTTP/SSE consumer.
- **Not auth mechanics** — counter discipline, session model → `apex-auth`; this skill owns only the *native key-sealing FFI* the client prover needs.
- **Not the stack choice** — whether Tauri vs Electron/native → `apex-stack`.

## Research findings (verified 2026-06-24 — see docs/research/2026-06-24-tauri2-stack.md)
- **Tauri 2 ≠ Tauri 1.** Config schema restructured, v1 **allowlist** replaced by **capabilities/permissions (ACL)**, built-in APIs (`fs/dialog/http/shell/...`) moved to **separate plugins**, `main.rs`+`lib.rs` split for mobile. A model trained on v1 gets ~12 concrete things wrong — impl.md § Common errors lists them.
- **`backdrop-filter` on a *transparent* window is broken** on both WebView2 (#12437) and WKWebView (#13801). The in-content mitigation (non-transparent window + photo bg as a DOM element + `background: rgba()` on glass) preserves the look. This is the single biggest visual-client gotcha.
- **Native hardware-keystore FFI is buildable** (Win CNG/TPM via `windows-sys`; mac SE via `security-framework`/`objc2-security`), normalized with the `ecdsa` crate. Windows Hello `KeyCredentialManager` is **RSA-only** — use NCrypt + the Platform Crypto Provider for P-256.

## What to weigh (planning)
- **Plugin vs inline command.** A `#[tauri::command]` in the app is right for simple desktop-only work. Author a **plugin** when the feature needs its own ACL namespace, a mobile impl, or reuse (e.g. the hardware keystore → its own plugin + permissions).
- **IPC primitive by direction.** `invoke` for request-response (the default); `emit`/`listen` for backend→frontend push; **`Channel`** (v2) for ordered streaming (the right primitive for an SSE-style token stream from the brain).
- **Capabilities are default-deny + window-scoped.** Plan the minimum permission set per window up front; pin capabilities to named windows, never `"*"`. Every file in `capabilities/` compiles in — no stray dev files.
- **WebKit-safe is a build constraint, not a polish pass.** Anything visually rich (blur, transforms, SVG/Canvas animation) must be specced to render on **both** WebView2 and WKWebView. Decide the glass approach (in-content `backdrop-filter` vs `window-vibrancy`) at design time — they look different.
- **CSP is set in `tauri.conf.json`** (`app.security.csp`); for a no-remote-content client go strict (`default-src 'self'`, `connect-src ipc: http://ipc.localhost`). Never `null`.
- **Lint/test tooling is NOT in the scaffold.** The base template ships only `dev/build/preview/tauri` — eslint + vitest are project add-ons the spec must install/wire if the Verification Recipe is to include them.
- **Verifiability is bought at the language layer** — `tsc --noEmit` (frontend) + `cargo check`/`clippy -D warnings` (Rust) carry the buildability weight; treat them as gates, not suggestions.

## Hard blocks (planning)
- Never spec Tauri-1 config/API shapes (`tauri:{}` key, `distDir`/`devPath`, `allowlist`, `@tauri-apps/api/tauri`, `Window`/`get_window`) for a v2 build — see impl.md § Common errors.
- Never spec a transparent-window `backdrop-filter` glass effect — it's broken on both engines; use the in-content mitigation.
- Never pass secrets (keys/tokens) through IPC args or hold them in the webview — secrets stay in the Rust core; expose only derived outputs.
- Never leave the CSP `null` or disable the asset-CSP nonce injection.

## Review checklist
- [ ] v2 config/API shapes only (no v1 carryover) — checked against impl.md § Common errors
- [ ] Capabilities scoped to named windows, minimum permissions; no stray `capabilities/` files
- [ ] CSP strict + non-null; secrets confined to Rust core
- [ ] Visual specs declare a WebKit-safe approach (glass, animation) for both engines
- [ ] IPC primitive chosen by direction (invoke / emit / Channel)
- [ ] The bound Verification Recipe (impl.md) is what coding mode will run — lint/test add-ons named if used
