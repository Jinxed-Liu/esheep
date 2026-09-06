-- Functional rollback never rewrites the event ledger or an accepted command.
create table esheep_cloud.checkpoint_rollout_controls (
  farm_id uuid not null references esheep_cloud.farm_state(farm_id),
  farm_generation integer not null check (farm_generation >= 0),
  new_receives_enabled boolean not null default true,
  publication_enabled boolean not null default true,
  reason text not null default '',
  primary key (farm_id, farm_generation)
);
alter table esheep_cloud.checkpoint_rollout_controls enable row level security;
revoke all on esheep_cloud.checkpoint_rollout_controls from public, anon, authenticated;
grant select, insert, update on esheep_cloud.checkpoint_rollout_controls to service_role;

create or replace function public.esheep_cloud_checkpoint_manifest_v1(p_farm_id uuid,p_farm_generation integer,p_checkpoint_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_manifest jsonb;
begin
  if not esheep_private.is_active_farm_member(p_farm_id,array['owner','administrator','worker']) then
    raise exception using errcode='42501',message='checkpoint_read_denied';
  end if;
  if not exists(select 1 from esheep_cloud.farm_state s where s.farm_id=p_farm_id
      and s.farm_generation=p_farm_generation and s.v2_ready
      and s.status in ('active','read_only')) then
    raise exception using errcode='55000',message='checkpoint_farm_unavailable';
  end if;
  -- Only new receives switch to legacy. A saved checkpoint ID must either
  -- renew that exact verified version or fail; it never silently starts over.
  if p_checkpoint_id is null and exists (
      select 1 from esheep_cloud.checkpoint_rollout_controls c
      where c.farm_id=p_farm_id and c.farm_generation=p_farm_generation
        and not c.new_receives_enabled) then
    return jsonb_build_object('manifest',null,'legacy_reason','new_checkpoint_receives_paused');
  end if;
  select c.manifest into v_manifest from esheep_cloud.business_checkpoints c
    where c.farm_id=p_farm_id and c.farm_generation=p_farm_generation and c.status='verified'
      and (p_checkpoint_id is null or c.checkpoint_id=p_checkpoint_id)
    order by c.boundary_event_sequence desc,c.created_at desc limit 1;
  return jsonb_build_object('manifest',v_manifest);
end $$;

revoke all on function public.esheep_cloud_checkpoint_manifest_v1(uuid,integer,uuid) from public,anon;
grant execute on function public.esheep_cloud_checkpoint_manifest_v1(uuid,integer,uuid) to authenticated;

alter function public.esheep_cloud_publish_checkpoint_v1(jsonb,text,text)
  rename to esheep_cloud_publish_checkpoint_content_v1;
revoke all on function public.esheep_cloud_publish_checkpoint_content_v1(jsonb,text,text)
  from public,anon,authenticated,service_role;

create function public.esheep_cloud_publish_checkpoint_v1(p_manifest jsonb,p_manifest_sha256 text,p_reconciliation_sha256 text)
returns uuid language plpgsql security definer set search_path='' as $$
begin
  if exists(select 1 from esheep_cloud.checkpoint_rollout_controls c
      where c.farm_id=(p_manifest->>'farmID')::uuid
        and c.farm_generation=(p_manifest->>'farmGeneration')::integer
        and not c.publication_enabled) then
    raise exception using errcode='55000',message='checkpoint_publication_paused';
  end if;
  return public.esheep_cloud_publish_checkpoint_content_v1(
    p_manifest,p_manifest_sha256,p_reconciliation_sha256);
end $$;
revoke all on function public.esheep_cloud_publish_checkpoint_v1(jsonb,text,text) from public,anon,authenticated;
grant execute on function public.esheep_cloud_publish_checkpoint_v1(jsonb,text,text) to service_role;
