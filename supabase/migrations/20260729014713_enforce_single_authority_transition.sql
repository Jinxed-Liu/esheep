-- A farm can have only one pre-commit authority transition. This closes the
-- race between foreground recovery and an explicit retry using a new
-- migration ID.
create unique index authority_transitions_one_precommit_per_farm_idx
  on public.authority_transitions (farm_id)
  where committed_at is null
    and state in ('preparing', 'uploading_baseline', 'verifying', 'failed');
