# eSheep+ Harness on Cloudflare Containers

The API runs in separate service-binding-only Workers named
`esheepplus-harness-staging` and `esheepplus-harness`. MiMo remains the model
provider and each user supplies their own API key for each turn. No shared model
credential is baked into either image.

## Deployment contract

- Use `web/wrangler.harness.jsonc` for staging and
  `web/wrangler.harness.production.jsonc` for production. Workers Paid is required.
- Build context is `web/`; the Dockerfile allowlist excludes local environments,
  credentials, farm exports, build output, and developer configuration.
- Supply `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` as Worker secrets/environment
  values before enabling the frontend binding. Never supply a service-role key.
- The separate `/api/weather/farm` route runs in this Worker without starting a
  container. Set `WEATHERKIT_TEAM_ID`, `WEATHERKIT_SERVICE_ID`, `WEATHERKIT_KEY_ID`,
  and `WEATHERKIT_PRIVATE_KEY` as Worker secrets. Deploy the member-scoped weather
  location RPC first. The WeatherKit private key must never enter frontend or
  Docker build inputs.
- Verify the Linux Codex binary, read-only sandbox, query execution, streamed
  responses, cancellation, and session expiry in the deployed container before
  adding `CODEX_HARNESS` as a staging service binding.
- Keep `HARNESS_RUNTIME_VERIFIED=false` until the runtime check passes. The
  operator-only runtime-check endpoint requires `HARNESS_DIAGNOSTICS_TOKEN`, uses
  fixed synthetic inputs, and never reads user sessions. Delete that token after
  validation and set `HARNESS_RUNTIME_VERIFIED=true` to enable user turns.
- Production has its own `esheepplus-harness` Worker and container application.

The production Worker uses `wrangler.harness.production.jsonc` and a pinned
Cloudflare Registry image. Its 2026-09-29 image layers the current `server/` and
`src/lib/` source over the existing 2026-09-08 `esheepplus-harness` image, whose
installed `@openai/codex-sdk` and `@supabase/supabase-js` versions match the
current pinned direct dependencies. The production image digest is recorded in
the Wrangler config; update it after building and pushing a new production image.

## Isolation and resource limits

The router verifies Supabase authentication and farm membership before starting a
container. Routing hashes the verified user ID, farm ID, and session ID. Each
session gets its own VM; user-provided routing headers are overwritten. The Node
API also verifies membership before invoking Codex. Codex keeps its existing
read-only sandbox, no command network access, and no approvals.

Initial capacity is two `basic` instances. Idle instances sleep after ten minutes;
active response streams renew activity and each model turn has a ten-minute
deadline. These controls reduce usage but are not a Cloudflare billing hard cap.

The initial container filesystem is ephemeral. A warm container can resume its
Codex thread. A stopped/replaced container returns `SESSION_EXPIRED`; the frontend
clears its stale session identifier and asks the user to start a new conversation.
Durable conversation storage is not implemented in this deployment. Do not claim
that sessions survive container replacement, or that local tests establish hosted
Codex sandbox compatibility.

## Verification

Run `npm test` in `web/`, build the Linux/amd64 Docker image, and run the Worker
dry run with `--config wrangler.harness.jsonc --containers-rollout=none`.
Authentication failure, farm mismatch, body limits, per-user VM isolation, forged
creation headers, and missing resumed sessions are covered by automated tests.

On 2026-09-08, Workers Paid activation and the staging deployment were verified.
The Cloudflare x64 container passed fixture reads, read-only write rejection,
blocked command networking, and the actual Codex SDK with a local synthetic
Responses server. A real MiMo answer still requires the user's personal key in
the browser; this synthetic check does not prove vendor key validity or billing.
