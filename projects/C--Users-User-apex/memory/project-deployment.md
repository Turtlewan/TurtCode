---
name: project-deployment
description: "DeepSeek cloud-API coding backend ALREADY works on Windows (env-var swap). Mac is needed only for macOS tooling (Xcode/Swift/Bitrig). Mac Mini = dev+prod target; AWS = future scale."
metadata: 
  node_type: memory
  type: project
  originSessionId: 9c0e3910-746f-4375-a64f-5fc0800e815b
---

User's deployment setup: Mac Mini is both the development machine and the production server.
There is no separate dev/prod environment initially — the same machine runs both.

**Two-machine working model (corrected 2026-06-15 — supersedes the 2026-06-01 "planning-only" claim):**
The Windows machine is the *default* planning seat, but it is **NOT** code-incapable. A **DeepSeek
cloud-API coding backend already works on Windows**: `DEEPSEEK_API_KEY` is set (User scope) and
switching to coding mode is a pure env-var swap — `ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic`
+ `ANTHROPIC_AUTH_TOKEN` + `ANTHROPIC_MODEL=deepseek-v4-flash`, then restart `claude` (see
`apex/BACKEND-ROUTING.md` §Switching backends). The endpoint is Anthropic-compatible cloud, reachable
from anywhere; mode detection (`backend-session-start.ps1`) keys only on the `deepseek` substring — no
OS gate. So coding sessions, the write-guard lift, and `build/test/lint` run on Windows today.

**Two distinct gates — do not conflate them (this conflation was the bug):**
- **`coding-session`** — needs a DeepSeek coding session. **Runnable on Windows** via the env-var swap.
  (e.g. destructive-command-guard hook, pro-mode toggle's PowerShell path, context-window probe,
  cross-model-review.)
- **`mac-gated`** — needs genuine **macOS tooling** (`xcodebuild`/Swift/Xcode, Bitrig). These truly
  cannot run on Windows under any backend.

The Mac Mini remains the intended **dev+prod execution target** (below) and is required for the
macOS-tooling items — but "the Mac is being bought" must not be read as "Windows cannot build."

**Why:** Personal project (e.g. Artemis — a Jarvis-like assistant + RAG second brain; home automation; finance). Self-hosted first, AWS only if scaling is needed.

**How to apply:**
- "Local dev" patterns (docker-compose, MinIO, Redis) ARE the production setup, not throwaway dev config
- Frame storage/infra specs as "self-hosted production" not "local dev only"
- Dev/prod environment split (different endpoints, different credentials) only becomes relevant on AWS migration
- PM2 or Docker Compose for process management on Mac Mini is a valid production deployment
- apex-realtime: Redis adapter optional — single instance, no multi-server concern on day 1
- apex-jobs: Redis on Mac Mini via Docker is the production Redis instance
- apex-storage: MinIO on Mac Mini is production storage, not just a dev mock

**Remote access + autonomous coding (added 2026-06-16, research `docs/research/remote-autonomous/`):**
- **Off-laptop access is a NATIVE feature now, not a build.** Channels (Telegram/Discord/iMessage) +
  Remote Control (full two-way phone drive + push notifications) + Dispatch + Claude Code on Web. No
  VPS needed for *access*. Remote Control/Channels work on the current Windows box today (v2.1.80+) —
  phone access to interactive sessions needs no Mac Mini. The old "build a VPS access layer" framing is wrong.
- **Scheduled/headless autonomous *coding* bills to DeepSeek's pool, NOT the Anthropic credit pool** —
  so [[claude-agent-sdk-billing-split]] applies to headless *Claude/planning* runs, not to coding. Cost
  of unattended coding builds is a non-issue.
- **Cloud Routines CANNOT run APEX coding** (Claude-only on Anthropic infra, fresh-clone no local state,
  won't honour the DeepSeek `ANTHROPIC_BASE_URL` swap). The real autonomous-coding path = **headless-local**
  (`claude -p`/`--bg` + DeepSeek base URL + ready spec + `--permission-mode dontAsk` + allow-list +
  `--max-budget`) on the always-on Mac Mini, with HITL/alerts over Channels. Build is **host-gated** (Mac
  Mini), not infra-gated; defer until the host is live, then one small spec wires recipe + safety envelope.

Related: [[parked-discussion-handover]] · [[claude-agent-sdk-billing-split]]
