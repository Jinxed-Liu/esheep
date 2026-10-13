# Farm identity rename

Farm name is authenticated control-plane metadata, alongside membership. It is not a sheep fact or a location name. A rename retains the farm UUID, owner, generation, all business records, event chain, snapshots and checkpoint bytes.

## Write boundary

`esheep_cloud_rename_farm_v2` is the only client rename command. It requires the authenticated active owner, current generation, active writable V2 state, a valid 1–80 character name, the observed name revision and a request UUID. The transaction locks authority/state/profile, checks the expected revision, changes only the profile name/revision/update time, and inserts the old name, new name, actor and immutable result in the private RLS-protected `farm_name_commands` ledger. Retrying the same request returns the same receipt; reusing its UUID with different content is rejected. A stale revision cannot overwrite a newer edit. Offline edits are not represented as cloud successes.

## Read and compatibility boundary

Existing membership discovery, status and event-page responses now include optional `farm_identity` metadata. Old clients ignore this field and continue replaying the unchanged event protocol. They need an app update to display subsequent renames; no reinstall or business-data restore is required.

Updated iOS clients apply identity even on an empty event page, and at discovery and initial receive completion. They validate farm UUID/generation and persist the display name and a separate local revision watermark together. Delayed lower revisions are ignored. A business snapshot cannot overwrite a name once live metadata has been applied. Widget/Spotlight refresh uses the existing farm update/system-snapshot mechanism. The owner can rename under Settings → Farm name.

App schema V16 adds only a local-only `ESheepCloudFarmIdentityState`. V15 and earlier model lists keep their original shapes; V15 → V16 is an explicit lightweight migration. The identity watermark is never transferred in checkpoints. Web reads apply final authenticated status identity after verifying cached checkpoint/event data.

## Validation

Database tests cover permissions, RLS, request replay, revision conflicts, wrong generation, invalid names, frozen farms, unchanged review-copy name and business cursor, and empty-page/status propagation. Native tests cover metadata application, delayed responses, foreign scope rejection, old-response decoding, snapshot protection and V15 upgrade preservation. The live one-off rename and its before/after evidence are stored separately under `backups/farm-rename-20261013/`.

## Public RPC grants

The existing `esheep_guard_public_data_api_exposure` event trigger also revokes client privileges on `CREATE OR REPLACE FUNCTION`. Explicit authenticated EXECUTE grants must follow all modified public read-function definitions. The follow-up `restore_farm_identity_read_permissions` migration restores discovery, status and event-page reads without permitting anonymous execution. Regression tests check both ACLs and actual calls under `SET LOCAL ROLE authenticated`; changing JWT claims while still executing as postgres is not a client permission test.
