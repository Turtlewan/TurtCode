---
name: project-deployment
description: "DeepSeek env-var-swap coding backend is ARCHIVED (ADR-027, recovery-only) — Mac is needed only for macOS tooling (Xcode/Swift/Bitrig). Mac Mini = dev+prod target; AWS = future scale."
metadata: 
  node_type: memory
  type: project
  originSessionId: 9c0e3910-746f-4375-a64f-5fc0800e815b
  modified: 2026-07-29T09:15:14.344Z
---

User's deployment setup: Mac Mini is both the development machine and the production server.
There is no separate dev/prod environment initially — the same machine runs both.

**DeepSeek backend status (corrected 2026-07-29):** the env-var-swap DeepSeek coding backend
described in earlier sessions is **archived** (ADR-027, recovery-only) — it is not the live coding
path. The live coder is Codex `gpt-5.6-sol` (fallback Sonnet 5, A1); see [[sol-deliberation-feed-evidence]]
and the model-routing table in `~/.claude/CLAUDE.md`.

**Two distinct gates — do not conflate them (this conflation was the bug):**
- **`coding-session`** — the Windows machine is code-capable for the current (Codex) coding path, not
  just planning. (e.g. destructive-command-guard hook, pro-mode toggle's PowerShell path, context-window
  probe, cross-model-review.)
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
- **Scheduled/headless autonomous *coding* bills to Codex's own subscription/quota, NOT the Anthropic
  credit pool** — so [[claude-agent-sdk-billing-split]] applies to headless *Claude/planning* runs, not
  to coding. Cost of unattended coding builds is a non-issue.
- **Cloud Routines CANNOT run APEX coding** (Claude-only on Anthropic infra, fresh-clone no local state,
  can't drive the external Codex CLI subprocess). The real autonomous-coding path = **headless-local**
  (`claude -p`/`--bg` + ready spec + `--permission-mode dontAsk` + allow-list + `--max-budget`) on the
  always-on Mac Mini, with HITL/alerts over Channels. Build is **host-gated** (Mac Mini), not
  infra-gated; defer until the host is live, then one small spec wires recipe + safety envelope.

Related: [[claude-agent-sdk-billing-split]]
