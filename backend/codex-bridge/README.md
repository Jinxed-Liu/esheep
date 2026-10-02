# eSheep Codex bridge

This is a local, authenticated adapter for the **official Codex app-server**, not a renamed MiMo harness. It is disabled for normal users until all release gates pass. It has no third-party dependencies and requires Node 22+ and an installed, compatible official `codex` binary.

Verified locally on 2026-10-01: 19 Node protocol/security tests, Swift 6 typecheck of the Foundation protocol/client, and a real `codex-cli 0.159.0-alpha.3` `initialize` + `config/read` smoke test. The smoke test supplies a fixture token, uses a clean HOME, performs no login and makes no inference request. This is not evidence of subscription entitlement, iOS acceptance or a deployed connection.

## Production gates

The server and native `InsightCodexConnectionGate` require **partnerApproved**, **callbackApproved**, **privacyApproved**, and **runtimeIsolationVerified**. They default to false. These flags record completed external review; changing flags alone does not establish approval.

Commercial/cloud eSheep must obtain the official Sign in with ChatGPT trial/access qualification and an approved callback contract. The published OSS loopback OAuth example does not establish that an iOS callback is supported. The bridge does not attempt old Codex OAuth, reuse first-party credentials, automatically register a client, launch a browser, or apply for partner access.

A registration must come from an approved OAuth flow which validates issuer, signature, audience, nonce, account/workspace identity, state and PKCE. Save the issued client ID and granted `offline_access`, `resource.invoke`, `chatgpt.tokens.use.direct` scopes. Identity scopes alone do not authorize plan inference. The adapter cannot establish these facts from an untrusted JSON file; only the approved authorization owner may install protected registrations.

The app-server process must run inside a reviewed per-account isolated runtime with **no farm database or business storage mounted**. The adapter disables shell, unified execution, code mode, browser/computer tools, plugins, apps, child agents and image generation; declines every shell/file approval request; and exposes only an allowlist of native read/calculation/proposed-draft tools. These settings are additional controls, not proof of OS-level isolation. That proof and a reviewed TLS/authentication gateway are required before an iPhone can use a remote host.

## Local configuration

Set `ESHEEP_CODEX_BRIDGE_CONFIG` to an absolute, privately owned `0600` JSON file outside source control. The runtime directory must be owned by the executing user and `0700`. The CLI binds only `127.0.0.1` or `::1`, never `0.0.0.0`. Do not expose the loopback server through an unauthenticated proxy. A single exclusive runtime lock prevents competing hosts from racing rotating tokens; a stale lock needs operator reconciliation.

Configuration shape (placeholders are not credentials):

```json
{
  "host": "127.0.0.1",
  "port": 8789,
  "dataDirectory": "/private/esheep-codex-runtime",
  "codexBinary": "/usr/local/bin/codex",
  "gates": {
    "partnerApproved": false,
    "callbackApproved": false,
    "privacyApproved": false,
    "runtimeIsolationVerified": false
  },
  "registrations": { "REGISTRATION_ID": "/private/validated-registration.json" },
  "grants": [{
    "id": "BRIDGE_GRANT_ID",
    "tokenSHA256": "SHA256_OF_A_RANDOM_BRIDGE_BEARER",
    "accountID": "ESHEEP_ACCOUNT_UUID",
    "farmIDs": ["AUTHORIZED_FARM_UUID"],
    "registrationID": "REGISTRATION_ID"
  }]
}
```

Registration shape: `registrationID`, `identityValidated`, `clientID` (the issued ID, never `dynamic_agent_client`), `accessToken`, `refreshToken`, `expiresAt` (epoch milliseconds), `scopes`. No actual token examples are committed. Protected file reads reject symlinks, permissive modes and foreign ownership. Raw provider error bodies, child stderr, prompts and tokens are not logged or returned as errors.

The bridge credential is an independently generated high-entropy bearer bound to one eSheep account and authorized farm IDs; it is **not** the ChatGPT token. Production grants must come from the real account/membership authority and be revoked when membership, account, device or consent changes. The sample local grant store is not an identity service or a replacement farm permission system. iOS stores only the bridge credential in `SecureAccountStore`, keyed by account and host.

## Protocol

All endpoints require `Authorization: Bearer <bridge credential>`. They reject browser origins, set `Cache-Control: no-store`, and have no arbitrary JSON-RPC passthrough. IDs are scope-bound; another account or farm cannot open, poll, resume, stop or delete the thread.

| Endpoint | Behavior |
| --- | --- |
| `GET /v1/models` | Same OAuth registration calls official `GET https://api.openai.com/v1/models`, keeping `visibility=list`, `display_name`, `slug` |
| `POST /v1/sessions` | `{scope:{accountID,farmID,conversationID},modelSlug,tools,instructions}`; starts/resumes the saved scoped official thread |
| `POST /v1/sessions/{sessionID}/turn` | `{requestID,text,effort?}`; stable request UUID prevents a retry from submitting twice |
| `GET /v1/sessions/{sessionID}/events?after=N` | Scoped sequence events; polling renews a 30-second foreground lease |
| `POST /v1/sessions/{sessionID}/tool-result` | `{callID,text,success}`; only a pending allowlisted native request, persisted deduplicated result |
| `POST /v1/sessions/{sessionID}/interrupt` | Interrupts the turn, closes the process and pauses further tool rounds |
| `POST /v1/sessions/{sessionID}/close` | Releases foreground connection without deleting protocol history |
| `POST /v1/conversations/remove` | `{scope}`; closes process, deletes scoped host history and records deletion tombstone |

Tool definitions use `{name,description,inputSchema}`. They are generated from existing `InsightToolRegistry.definitions(for:)`, not arbitrary model definitions. Server requests become `toolCall` events. iOS `InsightCodexFarmToolBridge.execute` rechecks the exact account/farm/conversation and currently allowed tools, then calls the existing native query/calculation/draft registry. Returned action drafts must be persisted and rendered through existing confirmation cards. **Neither bridge calls `execute(draft:)` or approves a card.** Extended-data authorization remains a separate per-call native consent gate. Stable tool receipts are replayed; a repeated call ID with altered arguments is rejected.

Events distinguish actual text deltas, official reasoning summary deltas, native tool requests, blocked runtime tools, failed/paused and terminal turn status. Only `turnCompleted` with `status=completed` establishes a successful inference. Failed/interrupted turns do not establish access. UI final-answer review and goal completion remain the App coordinator's responsibility; a model terminal event is not proof that a write reached cloud authority.

The session opens at event cursor zero. Keep a conversation's draft, request UUID, thread binding and operation-card receipt in the App checkpoint. Re-entry subscribes instead of resubmitting. Returning to the list must keep the foreground coordinator polling; background/scope change/disconnect closes the lease. A process that ignores SIGTERM is killed after two seconds. Expired event history pauses recovery instead of inventing a final message. Persisted uncertain/nonterminal turns block new requests until official thread history establishes terminal status or an operator reconciles the ambiguous start; they are never automatically replayed.

## SIWC contract and renewal

app-server uses a custom Responses provider pointing to `https://api.openai.com/v1`, child environment `ACCESS_TOKEN`, `requires_openai_auth=false`, `supports_websockets=false`. Its HTTP inference requests must use `store:false`, `stream:true` and explicit input history; forbidden ordinary API fields such as `max_output_tokens`, `temperature` and `previous_response_id` are not supplied. app-server owns official thread history and legal reasoning items; UI reasoning sidecars are not used as context.

The account model endpoint is the catalog authority. app-server `model/list` supplies actual advertised reasoning efforts where available and is **not an entitlement check**. A completed real inference verifies access for that request only. No synthetic usage balance or unlimited subscription claim is made.

Refreshes for one registration are serialized. The adapter POSTs the issued `client_id`, rotating refresh token and `resource=https://api.openai.com/v1`, omitting scope, to the official token endpoint; it persists replacements before use. Between turns it restarts app-server with the new access token, reinitializes and resumes the same thread. It does not restart an active tool turn by replaying business operations. Revocation/sign-out UI, OIDC discovery/ID validation, remote revoke retries, production grant issuance, and privacy retention administration belong to the approved authentication owner and remain external integration work.

The initial transport accepts **text only**. This makes unsupported audio/video, transcription/Files-upload APIs, hosted MCP/connectors and Responses `tool_search` impossible to submit through the bridge. Voice must first be transcribed locally and corrected by the user; documents must first be parsed into the user's selected text. Capability-tested images/files may be added later without widening arbitrary filesystem access. The native owner must reject unsupported attachments before sending; it must not silently strip them or switch provider.

## Checks

```sh
npm run check
npm test
npm run smoke:codex
```

The real smoke test only initializes the official binary and verifies effective provider/tool configuration. Run it before adopting another app-server version: generated protocol schema can advertise values which the effective config rejects (this verified version rejects `untrusted`, so the adapter uses `on-request` and declines runtime requests). Real SIWC inference, tool isolation, remote TLS, consent/revocation, iOS callbacks, quota limits and device flows still need approved external acceptance.

Official references: [SIWC integration](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt), [eligibility](https://developers.openai.com/siwc), [Codex app-server](https://learn.chatgpt.com/docs/app-server).
