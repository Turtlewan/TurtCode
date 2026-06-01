# apex-realtime — Socket.io + SSE (TypeScript) worked examples

**Load condition:** read this file only when the bound stack is **Node + TypeScript using Socket.io
(WebSocket) / Express SSE**. On Python/FastAPI use SSE via `sse-starlette` (server→client token
streams) or native `WebSocket` (bidirectional) / `python-socketio`; on Swift use
`URLSessionWebSocketTask` or an `EventSource`/SSE client — following the transport matrix and
invariants in `impl.md` § Stack assumptions. These are *one stack's* illustration.

## Socket.io server setup with auth middleware + Redis adapter

```typescript
import { Server } from 'socket.io'
import { createAdapter } from '@socket.io/redis-adapter'
import { createClient } from 'redis'

const pubClient = createClient({ url: process.env.REDIS_URL })
const subClient = pubClient.duplicate()
await Promise.all([pubClient.connect(), subClient.connect()])

const io = new Server(httpServer, {
  cors: { origin: process.env.CLIENT_URL, credentials: true },
})

io.adapter(createAdapter(pubClient, subClient)) // only needed for multi-instance fan-out

// Auth middleware — runs before connection accepted
io.use(async (socket, next) => {
  const token = socket.handshake.auth.token
  const session = await verifyToken(token) // your auth verification
  if (!session) return next(new Error('Unauthorized'))
  socket.data.userId = session.userId
  next()
})

io.on('connection', (socket) => {
  const { userId } = socket.data
  socket.join(`user:${userId}`) // always join user room on connect
})
```

## External event → broadcast (webhook handler)

```typescript
// In your webhook/feed handler — publish to Redis, not directly to io (multi-instance safe)
async function onFinanceUpdate(userId: string, data: PriceUpdate) {
  await pubClient.publish(
    `user:${userId}:finance`,
    JSON.stringify({ event: 'finance:update', data })
  )
}

// Single-process / single-instance: emit directly
io.to(`user:${userId}`).emit('finance:update', data)
```

## SSE for AI token streaming (Express)

```typescript
app.get('/api/ai/stream', requireAuth, async (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream')
  res.setHeader('Cache-Control', 'no-cache')
  res.setHeader('Connection', 'keep-alive')

  const stream = await aiClient.stream(req.query.prompt as string)

  for await (const chunk of stream) {
    res.write(`data: ${JSON.stringify({ token: chunk })}\n\n`)
  }

  res.write('data: [DONE]\n\n')
  res.end()
})
```

> **Python/FastAPI equivalent:** `sse-starlette`'s `EventSourceResponse` over an async generator
> yielding `{"data": json.dumps({"token": chunk})}` — the recommended 2026 default for server→client
> LLM token streams (HTTP-based, auto-reconnect, proxy-friendly, no sticky sessions).

## Client-side Socket.io connection

```typescript
import { io } from 'socket.io-client'

const socket = io(process.env.NEXT_PUBLIC_API_URL, {
  auth: { token: getAuthToken() },
  reconnectionDelay: 1000,
  reconnectionDelayMax: 5000,
})

socket.on('finance:update', (data) => updatePrices(data))
socket.on('home:sensor', (data) => updateSensorState(data))
socket.on('connect_error', (err) => console.error('Socket auth failed:', err.message))
```

> **Swift client:** `URLSessionWebSocketTask` for bidirectional; for SSE, an `EventSource` client or
> a `URLSession` bytes stream parsing `data:` lines.
