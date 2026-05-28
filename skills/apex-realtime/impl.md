---
skill: apex-realtime
backend: deepseek
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Socket.io Docs — socket.io/docs
  - Socket.io Redis Adapter — github.com/socketio/socket.io-redis-adapter
  - MDN SSE — developer.mozilla.org/en-US/docs/Web/API/Server-sent_events
staleness_threshold: 30d
---

## NEVER do

- Accept `userId` or room names from the client payload — derive from verified token only
- Emit to `io.emit()` (all clients) instead of `io.to(room).emit()` (scoped room)
- Skip the Redis adapter in multi-instance deployments
- Leave SSE connections open after the stream ends (memory leak)
- Store unverified client data in `socket.data`

## ALWAYS do

- Verify auth in Socket.io middleware before connection is accepted
- Join socket to `user:{userId}` room immediately after connection
- Use named events (`finance:update`, `home:sensor`, `ai:token`) not a generic `message`
- Close SSE response with `res.end()` when stream completes
- Publish to Redis pub/sub from external event handlers — never call `io` directly from webhooks

## Code example — Socket.io server setup with auth middleware

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

io.adapter(createAdapter(pubClient, subClient))

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

## Code example — external event → broadcast (webhook handler)

```typescript
// In your webhook/feed handler — publish to Redis, not directly to io
async function onFinanceUpdate(userId: string, data: PriceUpdate) {
  await pubClient.publish(
    `user:${userId}:finance`,
    JSON.stringify({ event: 'finance:update', data })
  )
}

// Socket.io Redis adapter picks this up and delivers to all sockets in the room
// You can also emit directly if in the same process:
io.to(`user:${userId}`).emit('finance:update', data)
```

## Code example — SSE for AI token streaming

```typescript
// Express route handler
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

## Code example — client-side Socket.io connection

```typescript
import { io } from 'socket.io-client'

const socket = io(process.env.NEXT_PUBLIC_API_URL, {
  auth: { token: getAuthToken() },
  reconnectionDelay: 1000,
  reconnectionDelayMax: 5000,
})

socket.on('finance:update', (data) => updatePrices(data))
socket.on('home:sensor', (data) => updateSensorState(data))
socket.on('telegram:message', (data) => showNotification(data))
socket.on('connect_error', (err) => console.error('Socket auth failed:', err.message))
```

## Verification checklist

- [ ] `npm run build` — 0 TypeScript errors
- [ ] Connect without auth token → connection rejected with error
- [ ] Connect with valid token → socket joins `user:{userId}` room
- [ ] Emit event from server to room → client receives it
- [ ] Open two browser tabs → both receive the same broadcast
- [ ] Disconnect one tab → other continues receiving events
- [ ] SSE endpoint: open in browser → tokens stream, connection closes on completion
- [ ] Kill and restart server → client reconnects automatically
