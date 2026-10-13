# 2026-10-13 Supabase Disk IO investigation

Project: `rnqrvthbunrzqtprquqx` (`eSheepNext-Development`), PostgreSQL 17.
This incident involved both the Free database quota and excessive physical IO.
They had separate causes and were checked separately.

## Data and capacity

Read-only inspection confirmed the original 星露谷牧场 in generation 3:

- 50,516 events, minimum sequence 1, maximum 50,516, matching `event_head`.
- 39,428 accepted commands.
- 44,406 streams, including 3,271 sheep and 4,538 weight streams. These are
  historical record counts, not a current livestock count.

The 外测审核副本, created on 2026-10-11 China time, has a separate generation-1
ledger with the same event, command and stream counts. This second full copy
explains the material growth from the earlier single-farm database. Both farms,
historical generations, approvals, events, commands and snapshots were retained.

The live database measured 536,472,723 bytes at 03:04 UTC. The dashboard reported
552/500 MB to the owner. Measurement times and units differ; both indicate that
the previous 500 MB Free quota was exceeded. The owner upgraded the organization
to Pro, and the organization API subsequently returned `plan=pro`.

## Persistent IO source and immediate repair

The service initially refused or timed out on database connections, including
schema/table metadata queries. An empty dashboard under those errors was not
evidence that tables had been removed. One supported project restart was
accepted at 02:57:23 UTC; the database started at 03:01:33 UTC and database,
Auth, REST and Storage health checks recovered.

After startup, the exporter still waited on `IO/BuffileRead` while reading
`pg_stat_statements`. Inspection found:

- 3,095 statistics entries with 123,550,051 bytes of representative SQL text.
- 201 unusually large one-off procedural `DO` statements accounting for
  121,849,640 bytes (98.6% of that text).
- The monitor's query using `left(query, 10000)` still accessed the underlying
  full query-text store. A captured execution took 12,771.564 ms. The prior
  24-hour logs recorded 112 timeouts for the two statistics-monitor query IDs.

PostgreSQL keeps this query text in an external disk file. Retaining large
literal payloads inside utility statements made periodic monitoring expensive
on the small Nano instance and contributed to memory/swap pressure. The payloads
came from historical bulk operations; the evidence does not assign every large
statement to the recent review-farm copy.

Before repair, numeric performance counters and oversized-statement metadata
were saved privately. At 03:13:12 UTC, `extensions.pg_stat_statements_reset()`
cleared performance counters and representative SQL text. It did not delete
application data, historical events, commands or snapshots. The next check
found 6 entries / 1,295 bytes. The same monitoring query subsequently executed
in 1.510 ms, with no temporary read/write blocks. Metrics returned HTTP 200.
The before/after timing was measured at different times and loads.

The API's read-only diagnostic connection sets a read-only session default;
that setting must not be confused with project-wide quota enforcement.
The project-wide read-only endpoint returned `enabled=false`.

## Verified backup and Pro compute

The final paged logical backup completed at 04:49:58 UTC. It contains all 80
non-system base tables, 313,581 rows and 302 gzip JSON pages totaling
142,063,246 compressed bytes, plus full schema SQL and sequence positions.
Every page was decompressed, parsed and checked against both compressed and
uncompressed SHA-256 values. There were no PostgreSQL large objects outside
those tables. Storage file bytes are outside this database backup.

The export is not a single transaction snapshot across all tables. During the
export, Auth added one refresh-token row (1,866 to 1,867); that table was exported
again and its previous export retained. Final table counts matched the source.
Farm ledger counts, generations, event heads and projection digests remained
unchanged from the initial export through final verification. Restoration has
not been rehearsed. The interrupted native dump is retained separately and is
not represented as a verified complete backup.

After the backup passed, the supported compute-addon API accepted Nano to
Micro at 04:50:36 UTC. The API reports `ci_micro`, 1 GB RAM, approximately
$10/month of compute, covered by the Pro plan's $10 compute credit for the
organization's sole active project. Live available total memory increased from
452,898,816 to 974,299,136 bytes. Database, Auth, REST and Storage health checks
passed. The database restarted at 04:51:18 UTC. The physical gp3 disk remains
2 GB; Pro includes an 8 GB disk allowance, so this incident did not require an
additional disk allocation.

At 04:52:24 UTC, both farms still had 50,516 contiguous events, 39,428 accepted
commands and 44,406 streams each. Their generations and projection digests
matched the backup, both were active and ready, and neither was write-frozen.
The database remained 536,472,723 bytes. Project-wide read-only mode was off.
The monitoring query ran in 19.260 ms after the resize and full backup, with no
temporary read/write blocks. This later sample had more statistics entries
than the initial 1.510 ms sample taken immediately after clearing the cache.

Post-resize host-counter samples also fell as startup settled. Over 95 seconds,
reads averaged about 0.90 MB/s, writes 0.19 MB/s and CPU IO wait 0.84%. In the
following 166-second interval, reads averaged 0.177 MB/s, writes 0.137 MB/s and
CPU IO wait 0.143%. Available memory was 404,422,656 bytes. Swap usage increased
from about 41 to 51 MB in that later interval; this observation does not claim
that all paging stopped. IO rates use request-start timestamps and are
approximate short-window observations, not a full-day budget measurement.
The live Safari project overview separately showed PRO, MICRO and Healthy.

## Preventing recurrence in batch generators

The baseline and extended repair publishers and the original migration
generator previously interpolated the signed JSON batch directly into a `DO`
body. New output stages it using an ordinary `INSERT` into a temporary table.
The small procedural body reads that table in ordinal order and calls the same
`esheep_cloud.process_command_v2` pipeline. The JSON literal can then be
normalized by ordinary statement tracking rather than retained inside a
different large procedural statement for each batch.

The caller's transaction, signed envelopes, command ordering, rejection rules,
baseline guards, integrity checks and publication sealing remain in place.
Python input is bounded to 250 commands per temporary table; migration batches
retain their existing 100-command boundary. Temporary staging data is dropped
within the transaction or at commit. No existing sealed publication was
regenerated or replayed against production.

## Verification and remaining acceptance

- Four Python staging regression tests and two JavaScript generator tests passed:
  signed envelopes/order round-trip unchanged, large payloads stay outside the
  procedural body, command routing and transaction ownership remain explicit.
- Eight existing baseline operation-translation tests passed. JavaScript syntax
  validation and `git diff --check` passed.
- `./tools/verify_local.sh static` passed its earlier scans, localization,
  checkpoint/history-consumer, provider-boundary and Privacy Manifest syntax checks, then stopped
  because `Config/StagingEnvironment.local.xcconfig` is absent. The complete
  static gate is therefore not recorded as passed.
- The local database reset gate and exact publication rehearsal were not run.
  Docker was not running. New business publications still require their existing
  prepare/rehearse/seal gates; this investigation did not execute one.
- Database presence and event continuity were checked live. They are not a
  fresh cryptographic audit of every historical record or an iOS/Web acceptance
  test. No state-changing integrity-audit function was used for diagnosis.

Private evidence, the pre-edit source copy and backup work are under
`/Volumes/移动硬盘/eSheepNext-Dev/supabase-disk-io-20261013-105033/`.
The verified backup manifest is `logical_database_backup/backup_manifest.json`.
Backup format, scope and restoration limitations are in `BACKUP_README.md`.

## References

- [Supabase high Disk IO consumption](https://supabase.com/docs/guides/troubleshooting/exhaust-disk-io)
- [Supabase compute and disk](https://supabase.com/docs/guides/platform/compute-and-disk)
- [Supabase compute credits and billing](https://supabase.com/docs/guides/platform/manage-your-usage/compute)
- [Supabase included disk allowance](https://supabase.com/docs/guides/platform/manage-your-usage/disk-size)
- [PostgreSQL 17 pg_stat_statements](https://www.postgresql.org/docs/17/pgstatstatements.html)
