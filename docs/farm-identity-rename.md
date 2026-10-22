# Farm identity rename

Farm name is authenticated control-plane metadata, alongside membership. It is not a sheep fact or a location name. A rename retains the farm UUID, owner, generation, all business records, event chain, snapshots and checkpoint bytes.

## Write boundary

`esheep_cloud_rename_farm_v2` is the only client rename command. It requires the authenticated active owner, current generation, active writable V2 state, a valid 1–80 character name, the observed name revision and a request UUID. The transaction locks authority/state/profile, checks the expected revision, changes only the profile name/revision/update time, and inserts the old name, new name, actor and immutable result in the private RLS-protected `farm_name_commands` ledger. Retrying the same request returns the same receipt; reusing its UUID with different content is rejected. A stale revision cannot overwrite a newer edit. Offline edits are not represented as cloud successes.

## Read and compatibility boundary

Existing membership discovery, status and event-page responses now include optional `farm_identity` metadata. Old clients ignore this field and continue replaying the unchanged event protocol. They need an app update to display subsequent renames; no reinstall or business-data restore is required.

Updated iOS clients apply identity even on an empty event page, and at discovery and initial receive completion. They validate farm UUID/generation and persist the display name and a separate local revision watermark together. Delayed lower revisions are ignored. A business snapshot cannot overwrite a name once live metadata has been applied. Widget/Spotlight refresh uses the existing farm update/system-snapshot mechanism. The owner can rename under Settings → Farm name.

App schema V16 adds only a local-only `ESheepCloudFarmIdentityState`. V15 and earlier model lists keep their original shapes; V15 → V16 is an explicit lightweight migration. The identity watermark is never transferred in checkpoints. Web reads apply final authenticated status identity after verifying cached checkpoint/event data.

## Validation

Schema V20 freezes the shipped V19 identity shape and adds local-only verification markers. Clients predating Latin-name support can have the correct name revision with an unknown nil Latin name. The first authenticated same-revision response may enrich only that migrated unknown value, never a known nil, another non-nil value or a different Chinese name. New writes and cleared names remain strict at the same revision.

V19 could roll an entire incremental page back and enter integrity hold on this upgrade mismatch. Recovery is limited to its exact legacy enrichment signature at an already verified cursor, after the page and history rebuild succeed atomically. Any integrity failure encountered by the fixed client permanently disables this compatibility recovery for that identity. Neither the migration nor recovery creates business commands, replaces the device database, removes pending photo files/intents, or stamps pending work as safely saved.

Identity-only refreshes from membership discovery or name settings defer this specific enrichment while the legacy hold is recoverable. The event page must commit the name enrichment and recovery together; an earlier identity refresh must not consume the migration marker or clear a hold on its own.

Database tests cover permissions, RLS, request replay, revision conflicts, wrong generation, invalid names, frozen farms, unchanged review-copy name and business cursor, and empty-page/status propagation. Native tests cover metadata application, delayed responses, foreign scope rejection, old-response decoding, snapshot protection and V15 upgrade preservation. The live one-off rename and its before/after evidence are stored separately under `backups/farm-rename-20261013/`.

## Public RPC grants

The existing `esheep_guard_public_data_api_exposure` event trigger also revokes client privileges on `CREATE OR REPLACE FUNCTION`. Explicit authenticated EXECUTE grants must follow all modified public read-function definitions. The follow-up `restore_farm_identity_read_permissions` migration restores discovery, status and event-page reads without permitting anonymous execution. Regression tests check both ACLs and actual calls under `SET LOCAL ROLE authenticated`; changing JWT claims while still executing as postgres is not a client permission test.
