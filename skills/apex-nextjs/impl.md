---
skill: apex-nextjs
backend: coding
version: 1.0.0
last_updated: 2026-05-31
sources:
  - Context7 /vercel/next.js (App Router docs, fetched 2026-05-31)
  - Next.js Data Security Guide — nextjs.org/docs/app/guides/data-security
staleness_threshold: 14d
description: >
  Coding-mode patterns for Next.js 15 App Router — Server/Client rules, Server Action security,
  caching, route conventions, and the Verification Recipe. Loaded when stack_skills includes apex-nextjs.
---

# apex-nextjs — Implementation patterns

Next.js 15 App Router, TypeScript, React 19. Pre-resolved defaults — apply directly. Package
manager: detect from lockfile (`pnpm-lock.yaml`/`package-lock.json`/`yarn.lock`/`bun.lockb`);
default `npm`. Commands below show `npm`; swap the runner to match.

## NEVER do

- Put `'use client'` on a `page.tsx`/`layout.tsx` to fix a hook error — move the hook to a leaf and mark *that* `'use client'`.
- Read `cookies()`/`headers()`/`params`/`searchParams` without `await` (async in 15).
- Mutate data in a `'use server'` action without checking session AND authorization first — actions are public endpoints.
- Pass `formData`/action args to the DB without Zod (`safeParse`) validation.
- Query the DB directly in a component or `route.ts` — go through `lib/dal/*` (`import 'server-only'`).
- Reference a non-`NEXT_PUBLIC_` env var in a `'use client'` file; never `NEXT_PUBLIC_` a secret.
- Assume `fetch` is cached — set the cache option explicitly.
- Use `next/router` (Pages Router) — use `next/navigation`.

## ALWAYS do

- Default to Server Components; add `'use client'` only on the smallest interactive leaf.
- `await` `cookies()`/`headers()`/`params`/`searchParams`.
- In every Server Action: `const session = await auth()` → authz (ownership/role) → Zod validate → mutate via DAL → `revalidatePath`/`revalidateTag`.
- Put DB access + auth/authz in `lib/dal/*.ts` files beginning `import 'server-only'`.
- Set explicit cache intent per `fetch` (`cache: 'no-store'` | `next: { revalidate: N }` | `next: { tags: [...] }`).
- Wrap slow/dynamic data in `<Suspense>`; add `loading.tsx`; `error.tsx` is a Client Component.

## Route file conventions (`app/`)

| File | Role |
|------|------|
| `page.tsx` | Route UI (makes segment routable) |
| `layout.tsx` | Shared wrapper, persists across navigation |
| `loading.tsx` | Suspense fallback |
| `error.tsx` | Error boundary — **must be `'use client'`** |
| `route.ts` | API endpoint (`GET`/`POST`/…); not in the same folder as `page.tsx` |
| `[id]/`, `[...slug]/` | Dynamic / catch-all — `params` is async |
| `(group)/` | Route group — no URL effect |

## Pattern — Server Component fetching data (default)

```tsx
// app/posts/page.tsx — Server Component (no directive)
export default async function PostsPage() {
  const res = await fetch('https://api.example.com/posts', {
    next: { tags: ['posts'], revalidate: 60 }, // explicit cache intent
  })
  if (!res.ok) throw new Error('Failed to load posts')
  const posts: { id: string; title: string }[] = await res.json()
  return <ul>{posts.map((p) => <li key={p.id}>{p.title}</li>)}</ul>
}
```

## Pattern — server-only Data Access Layer (the auth boundary)

```ts
// lib/dal/posts.ts
import 'server-only'
import { auth } from '@/lib/auth'
import { db } from '@/lib/db'

export async function deletePost(postId: string) {
  const session = await auth()
  if (!session?.user) throw new Error('Unauthorized')          // authn
  const post = await db.post.findUnique({ where: { id: postId } })
  if (post?.authorId !== session.user.id) throw new Error('Forbidden') // authz / IDOR guard
  await db.post.delete({ where: { id: postId } })
}
```

## Pattern — secure Server Action (thin; delegates to DAL)

```tsx
// app/posts/actions.ts
'use server'
import { z } from 'zod'
import { revalidatePath } from 'next/cache'
import { deletePost } from '@/lib/dal/posts'

const DeleteSchema = z.object({ id: z.string().min(1) })

export async function deletePostAction(_prev: unknown, formData: FormData) {
  const parsed = DeleteSchema.safeParse({ id: formData.get('id') }) // validate
  if (!parsed.success) return { error: 'Invalid input' }
  await deletePost(parsed.data.id)   // authn + authz live in the DAL
  revalidatePath('/posts')           // revalidate
  return { ok: true }
}
```

## Pattern — pushing interactivity to a client leaf

```tsx
// app/posts/page.tsx stays a Server Component; only the button is client
import { LikeButton } from './like-button'   // 'use client' lives in that file
export default async function Page() {
  const post = await getPost()
  return <article><h1>{post.title}</h1><LikeButton postId={post.id} /></article>
}
```

## Verification Recipe

**Layered: language ⊂ framework.**

**Language layer (TypeScript) — run first; carries the buildability weight:**

```bash
npx tsc --noEmit        # 0 type errors; tsconfig MUST have "strict": true
```

**Framework layer (Next.js):**

```bash
npm run lint            # next lint (ESLint + next/core-web-vitals); fallback: npx next lint
npm run build           # next build — full type-check + route/RSC build; fallback: npx next build
```

**Test layer (if the project has tests):** the recipe's test command (e.g. `npm test` / `vitest`).

**The loop (per task):** run language → fix first error → re-run; then `lint`; then `build`
(authoritative — re-checks types + Server/Client boundaries across all routes). One hypothesis
per failure (apex-debug discipline); don't shotgun.

## Common build errors → fix

| Error fragment | Cause | Fix |
|----------------|-------|-----|
| `…component that needs useState/useEffect…` | hook in a Server Component | add `'use client'` to that leaf (not the page) |
| `cookies()/headers() should be awaited` | sync use of async API (15) | `await cookies()` |
| `params`/`searchParams` is a Promise | sync access (15) | `const { id } = await params` |
| `Dynamic server usage: couldn't be rendered statically` | dynamic API in a static route | intended → it's dynamic; else remove the call / set cache |
| `Module not found: Can't resolve 'fs'/'net'` in client | server module in a client file | move it to a Server Component / server module |
