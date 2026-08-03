# Development advisor review

Reviewed: 2026-08-02

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

The 27 externally reported security-definer functions were reviewed individually:

| RPC | Server-side authorization and concurrency evidence |
| --- | --- |
| `register_device` | Requires `auth.uid()` and writes only the caller's device row. |
| `register_owned_icloud_farm` | Requires `auth.uid()`, the caller's matching app account, an active caller-owned device, the canonical CloudKit zone and no conflicting provider; stores control-plane metadata only. |
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
| `revoke_farm_member` | Requires owner or administrator membership, forbids owner removal, revokes only the selected member and invalidates that member's active iCloud capabilities. |
| `abort_farm_authority_transition` | Requires the transition owner and exact migration ID, and rejects an authority that has already been committed. |
| `begin_compact_farm_authority_transition` | Requires the owner, entitlement, next generation, archive digest and a farm transaction lock. |
| `complete_farm_authority_transition` | Requires the owner, committed migration ID, active Supabase authority and expected generation; repeated completion is idempotent. |
| `get_compact_authority_transition_status` | Requires the transition owner and exact migration ID, and returns only that migration's resumable progress. |
| `get_farm_authority_transition_status` | Requires the transition owner and exact migration ID, and exposes no cross-farm transition state. |
| `get_farm_storage_metrics` | Requires active membership and returns aggregate storage counters rather than business payloads. |
| `register_compact_farm_checkpoint` | Requires the transition owner, migration ID, generation, private Storage path, archive digest and declared projection/history/asset counts. |
| `stage_farm_baseline_batch` | Requires the transition owner, migration ID and target generation; enforces the 25-item limit and immutable operation-ID semantics. |
| `stage_farm_projection_batch` | Requires the transition owner, migration ID and target generation; validates projection identity, revision and digest before staging. |
| `verify_and_activate_compact_farm_authority` | Requires the transition owner and exact migration/checkpoint/generation/archive digest, then verifies all declared counts before the one authority commit. |

The live catalog check also confirmed that every callable RPC pins
`search_path=""`, grants `EXECUTE` only to `authenticated`, and denies `anon`.
The pgTAP suite separately proves direct-table rejection, cross-farm denial,
one-time invite consumption, Storage isolation and post-revocation loss of
access.

`list_my_active_farm_access` is intentionally not in the warning table: it is
`SECURITY INVOKER`, pins `search_path=""`, reads through `farm_members` RLS,
returns only rows for the current `auth.uid()`, and grants execution only to
`authenticated`. It is the client access snapshot used before login recovery,
foreground synchronization and Realtime reconnects.

The hosted project's legacy `supabase_admin` default ACL cannot be altered by
the customer migration role (`permission denied to change default
privileges`). The enabled DDL event trigger is therefore the reviewed
compensating control: it strips hosted auto-grants from every supported new
public table, sequence, function and procedure before clients can use the
object. pgTAP creates each object type and proves `authenticated` receives no
effective access.

The legacy-account and account-deletion RPCs are present for the wider 3.1
schema but remain outside this Development vertical slice.

`icloud_capability_certificates` has RLS enabled and grants no client table
access. The authenticated Edge Function validates the caller through the
invoker/RLS client before its service-role client signs, rotates or reads the
certificate trust set. The P-256 private key exists only as a hosted project
secret; the iOS app contains public verification keys only.

The Advisor `rls_enabled_no_policy` INFO for that table is intentional: adding
a client policy would widen access to server-only certificate material. Direct
client privileges are revoked and pgTAP proves `authenticated` cannot query or
mutate the table.

## Performance Advisor

The missing foreign-key index on
`esheep_private.legacy_account_claim_tickets.consumed_by` is fixed by
`20260728132135_make_authority_commit_idempotent.sql`.

Unused-index notices on a newly created empty Development database are
expected. The indexes cover membership authorization, cursor pulls, foreign
keys, checkpoints, and invite lifecycle queries and must not be removed before
the two-user load and revocation tests have populated representative data.
