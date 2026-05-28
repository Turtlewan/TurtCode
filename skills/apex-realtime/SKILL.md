---
skill: apex-realtime
backend: claude
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Socket.io Docs — socket.io/docs
  - Socket.io Redis Adapter — github.com/socketio/socket.io-redis-adapter
  - MDN SSE — developer.mozilla.org/en-US/docs/Web/API/Server-sent_events
staleness_threshold: 30d
---

## Research findings

| Technology | Finding | Tag |
|------------|---------|-----|
| Socket.io v4 | Current stable v4.8.x (Dec 2025). API stable (io.on, socket.join, io.to().emit). No breaking changes. CVE-2026-33151 patched in socket.io-parser@4.2.6. | [VERIFIED] |
| Redis adapter | Current package: @socket.io/redis-adapter@8.3.0. Old `socket.io-redis` deprecated. Works with ioredis v5+. Requires manual client creation (pub + sub). | [VERIFIED] |
| Socket.io auth | Middleware pattern with `socket.handshake.auth.token` is current best practice. No query params for tokens. | [VERIFIED] |
| SSE in Node.js/Next.js | Works in Express/Fastify natively. In Next.js App Router: use ReadableStream + TextEncoder in Route Handlers with `runtime = 'nodejs'`. Requires `X-Accel-Buffering: no` for nginx reverse proxy. | [VERIFIED] |
| Socket.io + Next.js App Router | No native support in Route Handlers. Requires a custom server (`server.ts`) or a separate API process. | [VERIFIED] |
| Socket.io vs ws in Node.js 22 | Node.js 22+ has native WebSocket client (not server). The `ws` library remains best for server-side. Socket.io still wins for rooms, reconnection, and fallback transport. | [VERIFIED] |

## When to activate

- "real-time" / "live updates" / "push to client"
- "WebSocket" / "Socket.io" / "SSE" / "Server-Sent Events"
- "live dashboard" / "live feed" / "streaming data"
- "presence" / "online status" / "who is connected"
- "AI streaming" / "stream LLM response"
- "push notification to UI" / "instant update"
- "Home Assistant live" / "Telegram live" / "finance ticker"

## 5 questions to ask before designing

1. **Direction of data flow?** — server→client only / bidirectional
2. **Single user on multiple devices, or multiple distinct users?**
3. **How many concurrent connections expected?** — affects Redis adapter decision
4. **Any pure streaming use case?** — AI token streaming → SSE may be simpler
5. **Running multiple server instances?** — yes → Redis adapter required

## Protocol decision table

| Use case | Protocol | Why |
|----------|----------|-----|
| Live dashboard, notifications, presence | Socket.io | Rooms, reconnection, multi-instance via Redis adapter |
| AI token streaming (one-way) | SSE | Simpler, HTTP-native, no persistent connection overhead |
| Raw bidirectional, full control | `ws` library | Lighter than Socket.io, manual room management |
| Managed, no infra | Ably / Pusher | Hosted, pay-per-message, no Redis needed |

**Primary recommendation: Socket.io + Redis adapter.** Covers all project use cases (finance, Home Assistant, Telegram, AI brain) through named events and user-scoped rooms. Redis adapter ensures multi-instance correctness when scaling to AWS.

## Room / channel architecture

Use user-scoped rooms so all of a user's devices receive the same updates:

```
room: `user:{userId}`           — all events for this user
room: `user:{userId}:finance`   — finance updates only
room: `user:{userId}:home`      — Home Assistant sensor events
room: `user:{userId}:telegram`  — Telegram incoming messages
room: `user:{userId}:ai`        — AI brain streaming events
```

On connect: server joins socket to `user:{userId}` (and sub-rooms if client subscribes). External webhook/feed handler publishes to Redis → Redis adapter → all sockets in room receive it.

## Authentication of socket connections

- Socket.io middleware runs before connection is accepted
- Verify JWT or session cookie in handshake `auth` or `headers`
- Reject unauthenticated connections with `next(new Error('Unauthorized'))`
- Store `userId` on `socket.data` after verification — use it for room join

## External event → broadcast flow

```
External source (Home Assistant webhook, finance API poll, Telegram webhook)
  → HTTP endpoint on server receives event
  → Server publishes to Redis pub/sub channel
  → Redis adapter broadcasts to all Socket.io instances
  → All sockets in `user:{userId}:home` room receive the event
```

## SSE pattern (for AI streaming)

- Use SSE when the client only needs to receive (AI token stream, progress updates)
- SSE is a standard HTTP response with `Content-Type: text/event-stream`
- Simpler than Socket.io for this specific case — no persistent connection library needed
- Each AI request opens one SSE connection, closes when stream ends

## Reconnection and resilience

- Socket.io handles reconnection automatically (exponential backoff by default)
- On reconnect, client must re-subscribe to rooms (server re-joins on `connection` event)
- Missed events during disconnect: use a "catch-up" REST endpoint for critical data (finance: fetch last N prices; home: fetch current sensor states)
- Do not replay all missed events via socket — use HTTP for state, socket for deltas

## Hard blocks

- Never trust `userId` from the client — always derive from verified session/JWT on server
- Never broadcast to all connected clients globally — always scope to user room
- Never skip the Redis adapter when running multiple server instances
- Never store sensitive data in `socket.data` that persists across reconnections without re-verification
- Never use polling as a substitute for WebSockets/SSE in production

## Review checklist

- [ ] Socket connections authenticated before `connection` event fires
- [ ] `userId` derived from server-side session/JWT, never from client payload
- [ ] All emits scoped to `user:{userId}` room, not global broadcast
- [ ] Redis adapter configured when `NODE_ENV=production` or multiple instances
- [ ] Client reconnection tested: disconnect → reconnect → events resume
- [ ] SSE connections closed by server when stream ends (no dangling connections)
- [ ] External webhook handlers publish to Redis channel, not directly to socket

## Gotchas / edge cases

- **Socket.io + Next.js App Router**: Next.js App Router does not support Socket.io natively in Route Handlers. A custom server (`server.ts`) or a separate API process is required.
- **Redis adapter package rename**: The old package `socket.io-redis` is deprecated. Current package is `@socket.io/redis-adapter`. Many tutorials still show the old package.
- **Missed events on reconnect**: Socket.io reconnects automatically but does not replay missed events. Recommend a REST catch-up endpoint for critical state (current sensor values, last N prices).
- **SSE and reverse proxies**: SSE requires the reverse proxy (nginx, AWS ALB) to disable response buffering (`X-Accel-Buffering: no` for nginx). Without this, tokens appear in batches not as a stream.
- **userId in socket.data persists across reconnects**: When a client reconnects, the `connection` event fires again and middleware re-runs. Do not cache `socket.data.userId` between reconnects without re-verifying — always re-derive from the token.
- **Global io.emit is a security risk**: Broadcasting to all clients leaks one user's finance/home data to another user.
