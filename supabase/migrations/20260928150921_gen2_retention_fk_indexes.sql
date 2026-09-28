-- Keep command foreign-key checks indexed while retiring an old cloud generation.
-- These indexes also make future command cleanup proportional to the commands
-- being removed rather than the full event and watermark tables.
create index if not exists esheep_cloud_events_command_id_fk_idx
  on esheep_cloud.events (command_id);

create index if not exists esheep_cloud_field_device_watermarks_command_id_fk_idx
  on esheep_cloud.field_device_watermarks (command_id);
