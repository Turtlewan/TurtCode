---
skill: apex-google
backend: deepseek
version: 1.0.0
last_updated: 2026-05-28
sources:
  - googleapis npm — github.com/googleapis/google-api-nodejs-client
  - google-auth-library — github.com/googleapis/google-auth-library-nodejs
  - Google Identity GIS — developers.google.com/identity/gsi/web
staleness_threshold: 30d
---

# Google Account & Workspace Implementation Rules

## NEVER do

- Store refresh tokens in localStorage, sessionStorage, or non-HttpOnly cookies
- Use `email` as the primary user key in your database — always use `sub`
- Skip server-side JWT verification for Sign in with Google credentials
- Commit service account JSON key files to source control
- Request `drive`, `mail.google.com`, or other broad scopes without explicit need
- Use the old `platform.js` GSI library (deprecated) — use the new GIS library

## ALWAYS do

- Use `google-auth-library` for all token exchange and refresh on the server
- Encrypt refresh tokens before storing in the database
- Handle `invalid_grant` errors by re-initiating OAuth flow (token was revoked)
- Use `googleapis` npm client — do not hand-roll API calls
- Verify returned tokens include expected scopes before storing

## OAuth2 client setup (Node.js)

```typescript
import { google } from 'googleapis';

const oauth2Client = new google.auth.OAuth2(
  process.env.GOOGLE_CLIENT_ID,
  process.env.GOOGLE_CLIENT_SECRET,
  process.env.GOOGLE_REDIRECT_URI  // e.g. http://localhost:3000/auth/google/callback
);

// Generate auth URL
const authUrl = oauth2Client.generateAuthUrl({
  access_type: 'offline',        // get refresh token
  prompt: 'consent',             // force consent screen on every auth (to get refresh_token)
  scope: [
    'openid',
    'email',
    'profile',
    'https://www.googleapis.com/auth/calendar.readonly',
  ],
});

// Exchange code for tokens
const { tokens } = await oauth2Client.getToken(code);
oauth2Client.setCredentials(tokens);
// tokens.refresh_token — store this encrypted in DB
// tokens.access_token — use for immediate API calls (expires in ~1h)
```

## Token refresh pattern

```typescript
// On subsequent requests: load refresh token from DB, set credentials
oauth2Client.setCredentials({ refresh_token: storedRefreshToken });

// googleapis auto-refreshes when access_token is expired if refresh_token is set
// But handle revocation explicitly:
try {
  const { data } = await gmail.users.labels.list({ userId: 'me' });
  return data;
} catch (err) {
  if (err.code === 401 || err.message?.includes('invalid_grant')) {
    // Token revoked — clear from DB, redirect user to re-authenticate
    await revokeUserGoogleAuth(userId);
    throw new Error('GOOGLE_AUTH_REQUIRED');
  }
  throw err;
}
```

## Gmail API — common operations

```typescript
const gmail = google.gmail({ version: 'v1', auth: oauth2Client });

// List messages
const res = await gmail.users.messages.list({
  userId: 'me',
  q: 'is:unread',
  maxResults: 10,
});

// Get full message
const msg = await gmail.users.messages.get({
  userId: 'me',
  id: messageId,
  format: 'full',  // 'minimal' | 'full' | 'raw' | 'metadata'
});

// Send email
await gmail.users.messages.send({
  userId: 'me',
  requestBody: {
    raw: Buffer.from(
      `To: recipient@example.com\r\nSubject: Hello\r\n\r\nBody text`
    ).toString('base64url'),
  },
});
```

## Calendar API — common operations

```typescript
const calendar = google.calendar({ version: 'v3', auth: oauth2Client });

// List upcoming events
const events = await calendar.events.list({
  calendarId: 'primary',
  timeMin: new Date().toISOString(),
  maxResults: 10,
  singleEvents: true,
  orderBy: 'startTime',
});

// Create event
await calendar.events.insert({
  calendarId: 'primary',
  requestBody: {
    summary: 'Meeting',
    start: { dateTime: '2026-06-01T10:00:00+08:00' },
    end:   { dateTime: '2026-06-01T11:00:00+08:00' },
    attendees: [{ email: 'guest@example.com' }],
  },
});
```

## Drive API — common operations

```typescript
const drive = google.drive({ version: 'v3', auth: oauth2Client });

// List files
const files = await drive.files.list({
  pageSize: 10,
  fields: 'files(id, name, mimeType, modifiedTime)',
});

// Download file content
const res = await drive.files.get(
  { fileId, alt: 'media' },
  { responseType: 'stream' }
);
```

## Service account setup

```typescript
import { google } from 'googleapis';

// Using a JSON key file (store path in env, never commit the file)
const auth = new google.auth.GoogleAuth({
  keyFile: process.env.GOOGLE_SERVICE_ACCOUNT_KEY_PATH,
  scopes: ['https://www.googleapis.com/auth/calendar'],
});

// Domain-wide delegation: impersonate a specific user
const auth = new google.auth.GoogleAuth({
  keyFile: process.env.GOOGLE_SERVICE_ACCOUNT_KEY_PATH,
  scopes: ['https://www.googleapis.com/auth/calendar'],
  clientOptions: { subject: 'user@yourdomain.com' },
});
```

## Sign in with Google — server-side verification (Next.js/Node)

```typescript
import { OAuth2Client } from 'google-auth-library';

const client = new OAuth2Client(process.env.GOOGLE_CLIENT_ID);

export async function verifyGoogleCredential(credential: string) {
  const ticket = await client.verifyIdToken({
    idToken: credential,
    audience: process.env.GOOGLE_CLIENT_ID,
  });
  const payload = ticket.getPayload();
  if (!payload) throw new Error('Invalid credential');

  return {
    googleId: payload.sub,          // stable; use as foreign key
    email: payload.email!,
    emailVerified: payload.email_verified ?? false,
    name: payload.name,
    picture: payload.picture,
  };
}
```

## Environment variables

```env
GOOGLE_CLIENT_ID=...apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=GOCSPX-...
GOOGLE_REDIRECT_URI=http://localhost:3000/auth/google/callback
# Service account (if used) — path to key file, not the key itself
GOOGLE_SERVICE_ACCOUNT_KEY_PATH=/run/secrets/google-sa-key.json
```

## Verification checklist

- [ ] OAuth2 client ID and secret in env vars — not hardcoded
- [ ] Refresh token encrypted before DB insert
- [ ] `invalid_grant` handler in place — clears token, redirects to auth
- [ ] Sign in with Google: `verifyIdToken` called server-side before any user creation
- [ ] `sub` (not `email`) stored as `googleId` foreign key
- [ ] Service account key file excluded from git (`.gitignore`) and stored in secrets manager
- [ ] Scopes are minimal — confirmed against actual API usage
