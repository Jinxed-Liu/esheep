-- Integrity audits validate the latest event for every materialized stream.
-- Keep that lookup bounded by the stream key instead of repeatedly scanning
-- the farm-wide event-sequence index.
create index if not exists esheep_cloud_events_stream_integrity_idx
  on esheep_cloud.events (
    farm_id,
    farm_generation,
    stream_type,
    stream_id,
    event_sequence desc
  );
