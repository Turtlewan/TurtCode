---
skill: apex-tauri
backend: coding
version: 1.0.0
last_updated: 2026-06-24
staleness_threshold: 30d
---

# apex-tauri — Implementation patterns (Tauri 2.x + React/TS/Vite + Rust)

Coding-mode enforcement for a Tauri 2 desktop client. Core = NEVER/ALWAYS + Verification Recipe +
Common-errors. Bulky walk-throughs (the native-keystore plugin, the full v1→v2 table) → `references/`.

## NEVER do
- NEVER emit Tauri-1 shapes: `"tauri": {}` config key, `build.distDir`/`build.devPath`, `tauri.allowlist`, JS `@tauri-apps/api/tauri`, Rust `Window`/`WindowBuilder`/`get_window()`. (v2 forms in § Common errors.)
- NEVER build a glass effect with `backdrop-filter` on a **transparent** window — broken on WebView2 (#12437) AND WKWebView (#13801). Use the in-content mitigation (§ ALWAYS).
- NEVER pass secrets (keys, tokens, DEKs) as IPC args or hold them in webview JS — the webview is untrusted. Keep them in the Rust core; return only derived outputs (signatures, ciphertexts).
- NEVER set `"csp": null` or use `dangerousDisableAssetCspModification` / `dangerousRemoteUrlIpcAccess`.
- NEVER ship a capability scoped to `"windows": ["*"]`, an unscoped `fs:default`/`assetProtocol`, or leave a stray dev file in `src-tauri/capabilities/` (every file there compiles in → prod over-grant).
- NEVER animate anything but `transform`/`opacity`/`filter`/`clip-path`; NEVER use SMIL (no HW accel) or `mix-blend-mode`+`backdrop-filter` on one element (WebKit #176830).
- NEVER `app.manage(Arc::new(x))` — Tauri already wraps managed state in `Arc`; double-wrapping breaks `State<'_, T>` extraction (runtime panic, not a compile error).
- NEVER enable the `devtools` Cargo feature in a release build.
- NEVER run the Rust recipe from project root — `cargo` commands run inside `src-tauri/`.

## ALWAYS do
- ALWAYS use v2 config: `app` key, `build.frontendDist`/`build.devUrl` (URLs only), top-level `productName`/`version`/`identifier`, `src-tauri/capabilities/*.json`. JS `invoke` from `@tauri-apps/api/core`. Rust `WebviewWindow`/`get_webview_window()`. Logic in `lib.rs` + thin `main.rs` calling `<crate>_lib::run()`.
- ALWAYS pick the IPC primitive by direction: `invoke` (request-response, ~90%) · `emit`/`listen` (backend→frontend push) · `Channel` (ordered streaming — the SSE-token-stream primitive).
- ALWAYS scope capabilities to named windows + minimum `core:`/`<plugin>:` permissions; `deny` wins over `allow` in scopes; autogenerate plugin command permissions from a `build.rs` `COMMANDS` const.
- ALWAYS set a strict CSP for a no-remote-content client: `default-src 'self'`; `connect-src` includes **both** `ipc:` and `http://ipc.localhost`; `object-src`/`frame-src 'none'`. Keep Tauri's nonce injection on.
- ALWAYS render the in-app glass safely: **non-transparent window** + bundled photo background as a DOM element + glass panel gets `background: rgba(...)` so `backdrop-filter` samples in-content, not the OS desktop. (OS-blur alt only if you want desktop sampling: `window-vibrancy`.)
- ALWAYS make IPC error types serializable (`thiserror` + `impl Serialize`); `anyhow::Error` is not serializable across the boundary. Async commands return `Result<T, E>`.
- ALWAYS commit both lockfiles (`Cargo.lock` + `package-lock.json`); pin `@tauri-apps/api` minor == `tauri` crate minor.
- ALWAYS build on Windows with the **MSVC** toolchain: `rustup default stable-msvc` + the Visual Studio **C++ Build Tools** ("Desktop development with C++" → MSVC linker + Windows SDK). The GNU toolchain (`stable-gnu`) is **not** Tauri-supported and fails to compile `windows-sys`/`parking_lot_core` (`dlltool.exe not found`) unless MinGW binutils are also installed. Verify with `npm run tauri info` before the first build.

## Pattern — IPC command + managed state (inline; the canonical shape)
```rust
// lib.rs
#[tauri::command]
async fn ping(state: tauri::State<'_, std::sync::Mutex<AppState>>, msg: String) -> Result<String, String> {
    let mut s = state.lock().map_err(|e| e.to_string())?;
    s.count += 1;
    Ok(format!("{msg} #{}", s.count))
}
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(std::sync::Mutex::new(AppState::default()))   // NOT Arc::new — Tauri wraps it
        .invoke_handler(tauri::generate_handler![ping])        // one invoke_handler call; last wins
        .run(tauri::generate_context!()).expect("run");
}
```
Frontend: `import { invoke } from "@tauri-apps/api/core"; await invoke("ping", { msg })`. Grant the command in a capability (`"identifier": "default", "windows": ["main"], "permissions": ["core:default", ...]`).

> Native hardware-keystore plugin (P-256 on Win CNG/TPM + mac SE, signature normalization): read `references/native-keystore-ffi.md` when the task implements device-key sealing / biometric signing.
> Full v1→v2 migration mapping (config, Rust API, JS imports, env vars): read `references/v1-to-v2.md` when porting Tauri-1 code or unsure of a v2 form.

## Verification Recipe
Layered language ⊂ framework. Run language gates first (fast), then the integration compile.

**Frontend (project root)** — _empirically converges on a fresh scaffold (run 2026-06-24, exit 0):_
```bash
npx tsc --noEmit                 # typecheck
npm run build                    # = tsc && vite build → dist/
# add-ons IF the project wired them (NOT in the base scaffold — install + add scripts first):
npx eslint . --max-warnings 0
npx vitest run
```

**Rust (inside `src-tauri/`):** _(needs the MSVC toolchain — see § ALWAYS / § Common errors)_
```bash
cargo fmt --check                # converges on scaffold (run 2026-06-24, exit 0)
cargo clippy -- -D warnings      # lint (warnings = errors)
cargo check                      # fast compile gate (no link)
cargo test                       # pure-Rust + Tauri mock-runtime (needs tauri features=["test"]); no WebView launched
```

**Tauri integration:**
```bash
npm run tauri info               # env doctor — run first when debugging
npm run tauri build -- --no-bundle   # release compile, no installer — the CI gate
npm run tauri build              # full bundle (slow; needs WebView2 on Win) — release only
```
Prefer `npm run tauri` (pre-compiled, version-locked) over `cargo tauri`. `tsc --noEmit` carries the
frontend buildability weight; `cargo check`/`clippy -D warnings` carry the Rust side.

## Common errors → fix
| Symptom | Cause | Fix |
|---|---|---|
| `unknown field "tauri"` in config | v1 schema | rename root key `tauri` → `app` |
| `unknown field "distDir"/"devPath"` | v1 build fields | `frontendDist` / `devUrl` (devUrl = URL only) |
| Blank white window | wrong `frontendDist` or dev server down | point `frontendDist` at Vite `../dist`; `devUrl` = `http://localhost:5173` |
| `command X not allowed` at runtime | no capability grant | add the permission to `capabilities/default.json` + pin `windows` |
| core perm silently ignored | missing prefix | use `core:` prefix (e.g. `core:path:default`) |
| `window.__TAURI__` undefined | `withGlobalTauri` off / wrong place | set `app.withGlobalTauri: true` (moved from `build` in v2) |
| `invoke is not a function` | v1 import path | `import { invoke } from "@tauri-apps/api/core"` |
| Rust: `Window`/`get_window` not found | v1 types | `WebviewWindow` / `get_webview_window()` |
| `State` extraction panics at runtime | managed type ≠ `State<'_,T>`, or double-`Arc` | `manage(Mutex::new(..))` (no `Arc`); types must match exactly |
| IPC returns `{}` / serialize error | error type not serializable | `thiserror` + `impl Serialize`; not `anyhow::Error` |
| Glass blur invisible / black | `backdrop-filter` on transparent window | in-content mitigation (non-transparent window + DOM photo bg + `background: rgba()`) |
| `cargo test` fails at project root | crate root is `src-tauri/` | run inside `src-tauri/` |
| WebView2 not found (Win build) | missing runtime | install WebView2 (bundled for end-users by the Tauri installer) |
| `dlltool.exe not found` compiling `windows-sys`/`parking_lot_core` | GNU Rust toolchain active | `rustup default stable-msvc` + install VS C++ Build Tools (MSVC is the Tauri-supported Windows toolchain) |
| MSVC link error / `link.exe` is Git's not MSVC's | MSVC toolchain set but C++ Build Tools absent | install VS Build Tools "Desktop development with C++" (MSVC linker + Windows SDK) |
| Linux dev fails | missing `webkit2gtk` dev libs | install the distro's `webkit2gtk-4.1` + `librsvg` dev packages |
