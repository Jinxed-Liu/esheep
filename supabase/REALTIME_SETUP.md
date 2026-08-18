# Realtime production setup

Realtime is a delivery hint only. Database projections, operation cursors,
compact checkpoints and digests remain the recovery and consistency authority.

Supabase locked the managed `realtime` schema against SQL migration changes in
2026. Do not add `CREATE POLICY`, `DROP POLICY`, `GRANT` or `REVOKE` statements
against `realtime.messages` to this repository's migrations.

For each Development, Staging and Production project, use the current Supabase
Dashboard/API workflow to configure private Broadcast authorization with these
invariants:

- channels are private;
- the topic format is exactly `farm:<farm-id>`;
- authenticated users may receive only the `revision_available` event for an
  active farm membership;
- clients have no Broadcast send permission;
- anonymous users have no send or receive permission;
- authorization resolves the farm ID from the topic and checks active
  membership server-side.

Record the project ref, configuration timestamp and operator in the release
evidence. Repeat these acceptance cases after every project initialization:

1. An owner, administrator and employee can subscribe to their own farm.
2. A non-member cannot subscribe using a known farm ID.
3. A revoked member loses access after token refresh/reconnect.
4. A valid member cannot send a forged `revision_available` Broadcast.
5. A valid notification only triggers a cursor pull; its payload is never
   accepted as authoritative state.

The exact Dashboard/API request must be copied from the current official
Supabase Realtime authorization documentation at execution time and saved with
the environment's evidence. Do not reuse a stale management API payload.
