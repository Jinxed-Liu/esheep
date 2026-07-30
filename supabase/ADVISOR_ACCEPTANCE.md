# Development advisor review

Reviewed: 2026-07-28

## Security Advisor

The `authenticated_security_definer_function_executable` warnings for the
public RPC surface are intentional and reviewed. Each callable function:

- fixes `search_path` to the empty string;
- rejects a missing `auth.uid()`;
- authorizes the current user through `profiles`, `farm_members`, ownership,
  role, generation, revision, and/or server-owned `entitlements`;
- has `PUBLIC` and `anon` execution revoked;
- accepts no caller-supplied entitlement decision;
- keeps direct table and Storage access behind RLS.

These functions require definer rights because the application is not granted
direct mutation access to the operation log, projections, authority state, or
entitlements. Converting them to invoker functions would require widening
direct table write privileges and would weaken the single transactional write
boundary.

The 16 externally reported functions were reviewed individually:

| RPC | Server-side authorization and concurrency evidence |
| --- | --- |
| `register_device` | Requires `auth.uid()` and writes only the caller's device row. |
| `claim_legacy_account` | Requires `auth.uid()` and a server-created, unexpired, one-time ticket; not exposed in this Development UI. |
| `request_account_deletion` | Requires `auth.uid()` and records only the caller's request; the UI is disabled until the deletion worker exists. |
| `register_farm_authority` | Requires `auth.uid()`, owner eligibility and Supabase entitlement before creating owner membership. |
| `activate_farm_authority` | Requires the owner, entitlement, expected generation, revision and baseline digest. |
| `deactivate_farm_authority` | Requires the owner and expected active generation. |
| `apply_farm_operation` | Requires an active member, role-permitted entity type, entitlement where the owner pays, matching generation/revision and an idempotent operation ID. |
| `register_farm_asset` | Requires an active member, matching generation, SHA-256 path and immutable asset metadata. |
| `begin_farm_authority_transition` | Requires owner membership, entitlement, source provider, target generation, baseline revision and a farm transaction lock. |
| `register_farm_checkpoint` | Requires the transition owner, migration ID, generation, revision, digest and private Storage path. |
| `verify_and_activate_farm_authority` | Requires the transition owner and exact migration/checkpoint/generation/digest; the internal one-shot helper is not executable by clients. |
| `apply_farm_operations_batch` | Requires the same member, role, generation, revision, operation-ID and farm-lock checks for every batch item. |
| `stage_farm_operations_batch` | Requires the transition owner, migration ID, target generation, ordered client sequence and operation-ID idempotency. |
| `create_farm_invite` | Requires owner or administrator membership, an allowed role, a 64-character SHA-256 digest and expiry within 24 hours. |
| `redeem_farm_invite` | Requires `auth.uid()`, atomically consumes one unexpired digest and creates only the selected farm membership. |
| `revoke_farm_member` | Requires owner or administrator membership, forbids owner removal and revokes only the selected active member. |

The live catalog check also confirmed that every callable RPC pins
`search_path=""`, grants `EXECUTE` only to `authenticated`, and denies `anon`.
The pgTAP suite separately proves direct-table rejection, cross-farm denial,
one-time invite consumption, Storage isolation and post-revocation loss of
access.

The hosted project's legacy `supabase_admin` default ACL cannot be altered by
the customer migration role (`permission denied to change default
privileges`). The enabled DDL event trigger is therefore the reviewed
compensating control: it strips hosted auto-grants from every supported new
public table, sequence, function and procedure before clients can use the
object. pgTAP creates each object type and proves `authenticated` receives no
effective access.

The legacy-account and account-deletion RPCs are present for the wider 3.1
schema but remain outside this Development vertical slice.

## Performance Advisor

The missing foreign-key index on
`esheep_private.legacy_account_claim_tickets.consumed_by` is fixed by
`20260728132135_make_authority_commit_idempotent.sql`.

Unused-index notices on a newly created empty Development database are
expected. The indexes cover membership authorization, cursor pulls, foreign
keys, checkpoints, and invite lifecycle queries and must not be removed before
the two-user load and revocation tests have populated representative data.
