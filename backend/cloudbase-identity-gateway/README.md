# eSheepNext CloudBase identity gateway

Mainland-facing CloudBase function for eSheepNext authentication and collaboration identity. It uses CloudBase Auth for email verification, registration, password sign-in and token introspection, and CloudBase Document Database for accounts, devices, opaque farm directories, memberships, one-time invites, capability certificates and deletion audit records.

It never stores farm names, sheep, pens, feed, health, breeding, photos, statistics or other farm business records. Those remain in the app's CloudKit zones.

Required runtime environment variables:

- `CLOUDBASE_ENV_ID`
- `CLOUDBASE_AUTH_BASE_URL`
- `CLOUDBASE_IDENTITY_COLLECTION` (defaults to `esheep_identity`)
- `CLOUDBASE_CUSTOM_LOGIN_KEY_ID`
- `CLOUDBASE_CUSTOM_LOGIN_PRIVATE_KEY`
- `APPLE_CLIENT_ID`
- `APPLE_TEAM_ID`
- `APPLE_KEY_ID`
- `APPLE_PRIVATE_KEY`
- `APPLE_TOKEN_ENCRYPTION_KEY` (base64-encoded 32-byte key)
- `RATE_LIMIT_HASH_SALT`
- `CAPABILITY_SIGNING_PRIVATE_KEY`
- `CAPABILITY_SIGNING_KEY_ID`
- `CAPABILITY_TTL_SECONDS` (defaults to seven days)

Never commit private keys, encryption keys or salts. The matching capability public key belongs in the iOS environment xcconfig. Development, Staging and Production must use separate CloudBase environments, keys, collections and public URLs.

`POST /v1/auth/apple` verifies the Apple identity token and nonce, exchanges the authorization code, stores the encrypted Apple refresh token, creates a CloudBase custom-login ticket and returns the same `WorkerSessionResponse` shape used by email/password login. There is no release-mode local Apple fallback.

Before deployment run:

```bash
npm install
npm run check
npm test
npm run security:audit
```

Deployment is blocked if the production dependency audit reports a high or critical vulnerability. The legacy `backend/identity-worker` Cloudflare/D1 service is not part of the 3.0 production runtime.
