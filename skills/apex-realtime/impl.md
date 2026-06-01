---
skill: apex-realtime
backend: deepseek
version: 1.1.0
last_updated: 2026-06-01
sources:
  - Socket.io Docs — socket.io/docs
  - sse-starlette — github.com/sysid/sse-starlette
  - FastAPI WebSockets — fastapi.tiangolo.com/advanced/websockets
  - MDN SSE — developer.mozilla.org/en-US/docs/Web/API/Server-sent_events
  - SP5 de-coupling + 2026 refresh (stack-neutral core; Socket.io/TS illustration)
staleness_threshold: 30d
description: >
  Coding-mode rules for real-time push — stack-neutral invariants (auth before connection, derive
  identity from the verified token not the client, scope emits to a room never broadcast-all, named
  events, clean stream close + client reconnect/catch-up, pub/sub backplane only for multi-instance).
  Loaded when a task adds live updates / streaming. Transport is stack-specific — Socket.io (TS) /
  SSE via sse-starlette + native WebSocket (Python) / URLSessionWebSocketTask (Swift); see § Stack
  assumptions. SSE is the 2026 default for server→client LLM token streams.
---

# apex-realtime — real-time push implementation rules

Capability skill — **stack-neutral**. The invariants govern any push transport; the concrete
transport + library come from the bound stack (see § Stack assumptions). The bound stack skill's
Verification Recipe is the verifier.

## Stack assumptions

Rules below are stack-neutral; the worked examples assume **Socket.io + Express SSE (TypeScript)**
(`references/socketio-typescript.md`). Pick the transport by direction, then swap the library:

- **Server→client streaming (LLM tokens, feeds, notifications):** **SSE** is the 2026 default — HTTP-based, auto-reconnect, proxy/CDN-friendly, no sticky sessions. **Node:** Express `text/event-stream`. **Python/FastAPI:** `sse-starlette` `EventSourceResponse`. **Swift:** `EventSource`/`URLSession` byte stream.
- **Bidirectional / interactive:** **WebSocket**. **Node:** Socket.io. **Python/FastAPI:** native `WebSocket` or `python-socketio` (ASGI). **Swift:** `URLSessionWebSocketTask`.
- **Multi-instance fan-out:** a pub/sub backplane (Socket.io Redis adapter / Redis pub/sub / Postgres LISTEN-NOTIFY). **Single-user local hub (Artemis): usually unnecessary** — one process, emit directly; add a backplane only when you actually run multiple instances.
- **Auth:** Socket.io handshake middleware → FastAPI WebSocket `Depends`/token check, or an auth header / query token validated before the SSE stream starts.

## NEVER do

- Accept `userId` or room/channel names from the client payload — derive identity from the verified token only.
- Broadcast to all clients (`io.emit()` / equivalent) when the message is for one user/room — scope it.
- Run a multi-instance deployment without a pub/sub backplane (messages reach only the local instance's clients).
- Leave an SSE / streaming response open after the stream ends (connection + memory leak).
- Store unverified client-supplied data as trusted connection state.

## ALWAYS do

- Verify auth **before** the connection/stream is accepted (handshake middleware, or token check before the first SSE byte).
- Associate the connection with `user:{userId}` (room/subscription) immediately after auth.
- Use named events (`finance:update`, `home:sensor`, `ai:token`) — never a generic `message`.
- Close the stream cleanly when it completes (`res.end()` / generator return / `await websocket.close()`).
- For external events (webhooks/feeds) in a multi-instance setup, publish to the backplane — don't call the socket server directly.
- Rely on (or implement) client auto-reconnect; on reconnect, send any missed events (catch-up) where ordering matters.

## Acceptance checks (stack-neutral)

- Connect/stream without a valid token → rejected before any data flows.
- Connect with a valid token → associated with the correct `user:{userId}` scope.
- Server emits to a user/room → only that user's client(s) receive it (not all clients).
- Open two clients for the same user → both receive the broadcast; close one → the other keeps receiving.
- SSE/stream endpoint streams tokens then closes cleanly on completion.
- Kill and restart the server → the client reconnects automatically.

## Worked examples (load on demand)

> The concrete **Socket.io + Express SSE (TypeScript)** implementation (server+auth middleware,
> Redis adapter, webhook→pub/sub, SSE token streaming, client connection) is in
> **`references/socketio-typescript.md`** — load it **only when the bound stack is Node + TypeScript**.
> On Python use `sse-starlette` / native WebSocket / python-socketio; on Swift use
> `URLSessionWebSocketTask` / an SSE client — per the transport matrix in § Stack assumptions.
