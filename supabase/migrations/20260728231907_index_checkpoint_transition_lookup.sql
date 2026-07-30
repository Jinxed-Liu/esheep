create index if not exists farm_checkpoints_migration_id_idx
  on public.farm_checkpoints (migration_id)
  where migration_id is not null;
