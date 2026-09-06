-- Retention applies only to new business checkpoint objects, never the ledger,
-- business history, photos, or the old snapshot bucket.
alter table esheep_cloud.business_checkpoints add column retired_at timestamptz;
alter table esheep_cloud.business_checkpoints add column purged_at timestamptz;
alter table esheep_cloud.business_checkpoints drop constraint business_checkpoints_status_check;
alter table esheep_cloud.business_checkpoints add constraint business_checkpoints_status_check
  check (status in ('candidate','verified','retired','purging','purged'));
alter table esheep_cloud.business_checkpoints add constraint checkpoint_pin_before_purge
  check (not pinned or status not in ('purging','purged'));

create function public.esheep_cloud_checkpoint_retention_v1(p_farm_id uuid,p_farm_generation integer,p_apply boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_ids uuid[];
begin
  -- The latest two verified versions and every pinned version survive.
  select coalesce(array_agg(checkpoint_id),'{}'::uuid[]) into v_ids from (
    select checkpoint_id,pinned,row_number() over (
      order by boundary_event_sequence desc,created_at desc,checkpoint_id desc) rank
    from esheep_cloud.business_checkpoints
    where farm_id=p_farm_id and farm_generation=p_farm_generation and status='verified'
  ) ranked where rank>2 and not pinned;
  if p_apply then
    update esheep_cloud.business_checkpoints set status='retired',retired_at=now()
      where checkpoint_id=any(v_ids) and status='verified' and not pinned;
  end if;
  return jsonb_build_object('eligible_to_retire',v_ids,'applied',p_apply,
    'eligible_to_purge',coalesce((select jsonb_agg(checkpoint_id order by retired_at,checkpoint_id)
      from esheep_cloud.business_checkpoints where farm_id=p_farm_id
      and farm_generation=p_farm_generation and not pinned
      and (status='purging' or (status='retired' and retired_at<now()-interval '10 minutes'))),'[]'::jsonb));
end $$;

-- Claim is atomic with pin checks. Once deletion has been claimed, pinning is
-- rejected explicitly instead of promising to preserve an already deleted file.
create function public.esheep_cloud_claim_checkpoint_purge_v1(p_farm_id uuid,p_farm_generation integer,p_checkpoint_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_manifest jsonb; v_hash text;
begin
  update esheep_cloud.business_checkpoints set status='purging'
    where farm_id=p_farm_id and farm_generation=p_farm_generation
      and checkpoint_id=p_checkpoint_id and not pinned
      and (status='purging' or (status='retired' and retired_at<now()-interval '10 minutes'))
    returning manifest,manifest_sha256 into v_manifest,v_hash;
  return jsonb_build_object('manifest',v_manifest,'manifest_sha256',v_hash);
end $$;

create function public.esheep_cloud_finish_checkpoint_purge_v1(p_checkpoint_id uuid,p_manifest_sha256 text)
returns boolean language plpgsql security definer set search_path='' as $$
begin
  update esheep_cloud.business_checkpoints set status='purged',purged_at=now()
    where checkpoint_id=p_checkpoint_id and manifest_sha256=p_manifest_sha256
      and status='purging' and not pinned;
  if found then return true; end if;
  return exists(select 1 from esheep_cloud.business_checkpoints
    where checkpoint_id=p_checkpoint_id and manifest_sha256=p_manifest_sha256 and status='purged');
end $$;

revoke all on function public.esheep_cloud_checkpoint_retention_v1(uuid,integer,boolean) from public,anon,authenticated;
revoke all on function public.esheep_cloud_claim_checkpoint_purge_v1(uuid,integer,uuid) from public,anon,authenticated;
revoke all on function public.esheep_cloud_finish_checkpoint_purge_v1(uuid,text) from public,anon,authenticated;
grant execute on function public.esheep_cloud_checkpoint_retention_v1(uuid,integer,boolean) to service_role;
grant execute on function public.esheep_cloud_claim_checkpoint_purge_v1(uuid,integer,uuid) to service_role;
grant execute on function public.esheep_cloud_finish_checkpoint_purge_v1(uuid,text) to service_role;

-- A removed version cannot report a successful reactivation merely because
-- its immutable metadata row still exists as an audit record.
create or replace function public.esheep_cloud_publish_checkpoint_v1(p_manifest jsonb,p_manifest_sha256 text,p_reconciliation_sha256 text)
returns uuid language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from esheep_cloud.checkpoint_rollout_controls c
      where c.farm_id=(p_manifest->>'farmID')::uuid
        and c.farm_generation=(p_manifest->>'farmGeneration')::integer
        and not c.publication_enabled) then
    raise exception using errcode='55000',message='checkpoint_publication_paused';
  end if;
  if exists(select 1 from esheep_cloud.business_checkpoints c
      where c.checkpoint_id=(p_manifest->>'checkpointID')::uuid
        and c.status in ('retired','purging','purged')) then
    raise exception using errcode='55000',message='checkpoint_retired';
  end if;
  return public.esheep_cloud_publish_checkpoint_content_v1(p_manifest,p_manifest_sha256,p_reconciliation_sha256);
end $$;
revoke all on function public.esheep_cloud_publish_checkpoint_v1(jsonb,text,text) from public,anon,authenticated;
grant execute on function public.esheep_cloud_publish_checkpoint_v1(jsonb,text,text) to service_role;
