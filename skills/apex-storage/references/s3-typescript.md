# apex-storage — S3-SDK + TypeScript worked examples

**Load condition:** read this file only when the bound stack uses the **AWS S3 SDK
(`@aws-sdk/client-s3`) + TypeScript** — i.e. an object-store backend (MinIO / S3 / R2). On a
Python object-store app, use the `boto3` / `aioboto3` equivalents; for a **local-filesystem**
backend (e.g. the single-user Mac hub) there is no SDK and no presigning — follow the local-fs
swaps in `impl.md` § Stack assumptions (authenticated streaming route + path-containment check).
These are *one stack's illustration* of the stack-neutral rules in `impl.md`.

## S3 client setup (works for MinIO, S3, and R2)

```typescript
import { S3Client } from '@aws-sdk/client-s3'

export const s3 = new S3Client({
  region: process.env.STORAGE_REGION ?? 'us-east-1',
  endpoint: process.env.STORAGE_ENDPOINT,         // MinIO or R2 endpoint
  forcePathStyle: process.env.STORAGE_FORCE_PATH_STYLE === 'true', // true for MinIO
  requestChecksumCalculation: 'WHEN_REQUIRED',     // required for R2
  responseChecksumValidation: 'WHEN_REQUIRED',     // required for R2
  credentials: {
    accessKeyId: process.env.STORAGE_ACCESS_KEY!,
    secretAccessKey: process.env.STORAGE_SECRET_KEY!,
  },
})
```

The checksum flags are harmless for MinIO and S3 (they just add a no-op when not needed) and required for R2. This config works identically across all three providers — migration = change environment variables, not code.

## Server-side upload (files < 10 MB) with MIME validation

```typescript
import { PutObjectCommand } from '@aws-sdk/client-s3'
import { fileTypeFromBuffer } from 'file-type'
import { randomUUID } from 'node:crypto'

const BLOCKED_MIMES = new Set([
  'application/x-dosexec',       // .exe
  'application/x-msdownload',    // .dll, .exe
  'application/x-sh',            // .sh
  'application/x-bat',           // .bat
  'application/x-msdos-program',
  'text/x-php',
  'application/x-java-jnilib',
])

async function uploadFile(buffer: Buffer, originalName: string, userId: string) {
  // 1. Validate MIME from bytes, not filename or Content-Type header
  const detected = await fileTypeFromBuffer(buffer)
  if (!detected) throw new Error('Unable to detect file type from content')

  if (BLOCKED_MIMES.has(detected.mime)) {
    throw new Error(`File type '${detected.mime}' is not allowed`)
  }

  // 2. Generate storage key — never use original filename
  const ext = detected.ext
  const date = new Date().toISOString().slice(0, 10) // YYYY-MM-DD
  const key = `${userId}/${date}/${randomUUID()}.${ext}`

  // 3. Upload to storage first
  await s3.send(new PutObjectCommand({
    Bucket: process.env.STORAGE_BUCKET!,
    Key: key,
    Body: buffer,
    ContentType: detected.mime,
  }))

  // 4. Then record metadata in DB (if this fails, async cleanup handles orphan)
  //    (DB insert goes here — adapt to your ORM)

  return { key, mimeType: detected.mime, sizeBytes: buffer.length }
}
```

## Presigned GET URL for private files

```typescript
import { GetObjectCommand } from '@aws-sdk/client-s3'
import { getSignedUrl } from '@aws-sdk/s3-request-presigner'

async function getPrivateDownloadUrl(key: string): Promise<string> {
  return getSignedUrl(
    s3,
    new GetObjectCommand({
      Bucket: process.env.STORAGE_BUCKET!,
      Key: key,
    }),
    { expiresIn: 900 } // 15 minutes
  )
}
```

## Presigned PUT URL for direct client upload (files 10 MB – 5 GB)

```typescript
import { PutObjectCommand } from '@aws-sdk/client-s3'
import { getSignedUrl } from '@aws-sdk/s3-request-presigner'
import { randomUUID } from 'node:crypto'

async function createUploadUrl(
  contentType: string,
  fileSizeBytes: number,
  userId: string
): Promise<{ url: string; key: string }> {
  const MAX_SIZE = 5 * 1024 ** 3 // 5 GB
  if (fileSizeBytes > MAX_SIZE) {
    throw new Error('File too large — use multipart upload')
  }

  // ext is for the storage key only — MIME must be validated from bytes post-upload
  const ext = contentType.split('/')[1] ?? 'bin'
  const date = new Date().toISOString().slice(0, 10)
  const key = `${userId}/${date}/${randomUUID()}.${ext}`

  const url = await getSignedUrl(
    s3,
    new PutObjectCommand({
      Bucket: process.env.STORAGE_BUCKET!,
      Key: key,
      ContentType: contentType,
    }),
    { expiresIn: 300 } // 5 minutes — enough for upload, limits exposure
  )

  return { url, key }
}
```

After a presigned PUT completes, the client cannot be trusted to have sent the declared
`ContentType` — trigger server-side MIME validation from the stored object's bytes before
marking the file record active in the DB.

## MinIO docker-compose (local dev)

```yaml
services:
  minio:
    image: minio/minio
    ports:
      - '9000:9000'   # API — used by app/sdk
      - '9001:9001'   # Console UI — browser admin at http://localhost:9001
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    command: server /data --console-address ":9001"
    volumes:
      - minio_data:/data
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:9000/minio/health/live']
      interval: 10s
      timeout: 5s
      retries: 5

  # Optional: auto-create the app bucket on first start
  minio-init:
    image: minio/mc
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
      /usr/bin/mc alias set local http://minio:9000 minioadmin minioadmin;
      /usr/bin/mc mb local/my-app --ignore-existing;
      /usr/bin/mc anonymous set public local/my-app-public --ignore-existing;
      "
    restart: no

volumes:
  minio_data:
```

## Environment variables (.env.example)

```
# Storage provider: MinIO (local), S3 (AWS), or R2 (Cloudflare)

# For MinIO (local dev):
STORAGE_ENDPOINT=http://localhost:9000
STORAGE_FORCE_PATH_STYLE=true
STORAGE_REGION=us-east-1

# For AWS S3 (remove endpoint, set forcePathStyle to false):
# STORAGE_ENDPOINT=
# STORAGE_FORCE_PATH_STYLE=false
# STORAGE_REGION=us-east-1

# For Cloudflare R2:
# STORAGE_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com
# STORAGE_FORCE_PATH_STYLE=false
# STORAGE_REGION=auto

# Common to all providers:
STORAGE_ACCESS_KEY=minioadmin
STORAGE_SECRET_KEY=minioadmin
STORAGE_BUCKET=my-app
```

## Large file upload — MIME detection without buffering the whole file

For files > 10 MB, read only the first 4100 bytes for type detection, then stream to storage:

```typescript
import { fileTypeFromBuffer, minimumBytes } from 'file-type'
import { PassThrough } from 'node:stream'

async function detectTypeAndStream(
  stream: NodeJS.ReadableStream
): Promise<{ fileType: { ext: string; mime: string }; body: NodeJS.ReadableStream }> {
  // Read the minimum bytes needed for detection
  const chunk = await new Promise<Buffer>((resolve, reject) => {
    const bufs: Buffer[] = []
    stream.on('data', (d: Buffer) => {
      bufs.push(d)
      const total = bufs.reduce((a, b) => a + b.length, 0)
      if (total >= minimumBytes) {
        stream.pause()
        resolve(Buffer.concat(bufs))
      }
    })
    stream.on('error', reject)
    stream.on('end', () => resolve(Buffer.concat(bufs)))
  })

  const fileType = await fileTypeFromBuffer(chunk)
  if (!fileType) throw new Error('Unable to detect file type')

  // Reconstruct stream from the chunk + remaining data
  const pass = new PassThrough()
  pass.write(chunk)
  stream.resume()
  stream.pipe(pass)

  return { fileType, body: pass }
}
```

## Verification checklist (S3-SDK stack)

- [ ] MinIO console accessible at `http://localhost:9001`
- [ ] Upload a file (any type) — object appears in MinIO console under correct bucket and key
- [ ] Upload `.exe` file — rejected with 400 error
- [ ] Upload file with spoofed `Content-Type` header — MIME validated from bytes not header
- [ ] Fetch presigned URL for a private file — file downloads correctly
- [ ] Presigned URL returns 403 after expiry
- [ ] Swap `STORAGE_ENDPOINT` to point at real S3 or R2 — same code works unchanged
- [ ] Soft-delete a file (set `deletedAt`) — object still exists in storage
- [ ] Large file upload (>10 MB) correctly detects MIME from first bytes only
- [ ] Bucket is auto-created on `docker compose up` (check minio-init service)
- [ ] Presigned PUT: after client upload, server validates MIME from bytes before DB record is marked active

## Gotchas (S3-SDK specific)

- **`forcePathStyle: true` is required for MinIO**: without it the SDK builds virtual-hosted URLs (`bucket.localhost:9000`) which MinIO does not support. S3 and R2 use virtual-hosted style by default → flag is `false` for them.
- **`file-type` works on buffers, not streams directly**: for large files read only the first 4100 bytes for detection, then stream the rest.
- **R2 + SDK v3 checksum**: newer SDK v3 versions require `requestChecksumCalculation: "WHEN_REQUIRED"` and `responseChecksumValidation: "WHEN_REQUIRED"` in the client config for R2 compatibility.
- **R2 EU regions need a different endpoint**: `https://<ACCOUNT_ID>.eu.r2.cloudflare.com` instead of `*.r2.cloudflarestorage.com`.
- **MinIO presigned URL + non-standard port**: presigned URLs for MinIO on port 9000 can cause `SignatureDoesNotMatch`. Workaround: override the `Host` header to include the port, or proxy MinIO behind a reverse proxy on 80/443.
- **Multer is not abandoned** (v2.1.1, March 2025) but buffers files in memory by default. For Fastify use `@fastify/multipart`; for custom streaming pipelines use `busboy` directly.
