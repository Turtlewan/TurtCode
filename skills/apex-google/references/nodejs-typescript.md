# apex-google — googleapis + TypeScript worked examples

**Load condition:** read this file only when the bound stack is **Node + TypeScript using the
`googleapis` + `google-auth-library` clients**. On Python use `google-api-python-client` +
`google-auth` + `google-auth-oauthlib` (the same OAuth flow, ID-token verification, and
Gmail/Calendar/Drive resources have direct equivalents); follow the invariants + swaps in
`impl.md` § Stack assumptions. These are *one stack's* illustration.

## OAuth2 client setup (Node.js)

```typescript
import { google } from 'googleapis';

const oauth2Client = new google.auth.OAuth2(
  process.env.GOOGLE_CLIENT_ID,
  process.env.GOOGLE_CLIENT_SECRET,
  process.env.GOOGLE_REDIRECT_URI  // e.g. http://localhost:3000/auth/google/callback
);

const authUrl = oauth2Client.generateAuthUrl({
  access_type: 'offline',        // get refresh token
  prompt: 'consent',             // force consent to obtain refresh_token
  scope: ['openid', 'email', 'profile', 'https://www.googleapis.com/auth/calendar.readonly'],
});

const { tokens } = await oauth2Client.getToken(code);
oauth2Client.setCredentials(tokens);
// tokens.refresh_token — store encrypted in DB; tokens.access_token — ~1h
```

## Token refresh + revocation handling

```typescript
oauth2Client.setCredentials({ refresh_token: storedRefreshToken });
// googleapis auto-refreshes when access_token is expired if refresh_token is set
try {
  const { data } = await gmail.users.labels.list({ userId: 'me' });
  return data;
} catch (err) {
  if (err.code === 401 || err.message?.includes('invalid_grant')) {
    await revokeUserGoogleAuth(userId); // token revoked — clear + re-auth
    throw new Error('GOOGLE_AUTH_REQUIRED');
  }
  throw err;
}
```

## Gmail API — common operations

```typescript
const gmail = google.gmail({ version: 'v1', auth: oauth2Client });

const res = await gmail.users.messages.list({ userId: 'me', q: 'is:unread', maxResults: 10 });
const msg = await gmail.users.messages.get({ userId: 'me', id: messageId, format: 'full' });
await gmail.users.messages.send({
  userId: 'me',
  requestBody: {
    raw: Buffer.from(`To: recipient@example.com\r\nSubject: Hello\r\n\r\nBody text`).toString('base64url'),
  },
});
```

## Calendar API — common operations

```typescript
const calendar = google.calendar({ version: 'v3', auth: oauth2Client });

const events = await calendar.events.list({
  calendarId: 'primary', timeMin: new Date().toISOString(),
  maxResults: 10, singleEvents: true, orderBy: 'startTime',
});
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

const files = await drive.files.list({ pageSize: 10, fields: 'files(id, name, mimeType, modifiedTime)' });
const res = await drive.files.get({ fileId, alt: 'media' }, { responseType: 'stream' });
```

## Service account setup

```typescript
import { google } from 'googleapis';

// JSON key file (store path in env, never commit the file)
const auth = new google.auth.GoogleAuth({
  keyFile: process.env.GOOGLE_SERVICE_ACCOUNT_KEY_PATH,
  scopes: ['https://www.googleapis.com/auth/calendar'],
});

// Domain-wide delegation: impersonate a specific user
const authDWD = new google.auth.GoogleAuth({
  keyFile: process.env.GOOGLE_SERVICE_ACCOUNT_KEY_PATH,
  scopes: ['https://www.googleapis.com/auth/calendar'],
  clientOptions: { subject: 'user@yourdomain.com' },
});
```

## Sign in with Google — server-side ID-token verification

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

> **Python equivalent:** `google.oauth2.id_token.verify_oauth2_token(credential, google.auth.transport.requests.Request(), CLIENT_ID)` returns the same claims dict (`sub`, `email`, `email_verified`, …).

## Environment variables

```env
GOOGLE_CLIENT_ID=...apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=GOCSPX-...
GOOGLE_REDIRECT_URI=http://localhost:3000/auth/google/callback
GOOGLE_SERVICE_ACCOUNT_KEY_PATH=/run/secrets/google-sa-key.json
```

## Verification checklist (googleapis stack)

- [ ] OAuth2 client ID and secret in env vars — not hardcoded
- [ ] Refresh token encrypted before DB insert
- [ ] `invalid_grant` handler in place — clears token, redirects to auth
- [ ] Sign in with Google: `verifyIdToken` called server-side before any user creation
- [ ] `sub` (not `email`) stored as `googleId` foreign key
- [ ] Service account key file excluded from git and stored in a secrets manager
- [ ] Scopes are minimal — confirmed against actual API usage
