-- Locate the sealed V1 journal and its independent V2 roster witness.
create function public.esheep_cloud_legacy_roster_source_v1(
  p_farm_id uuid, p_farm_generation integer, p_day date, p_opening boolean
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  zone text;
  cutoff timestamptz;
  source jsonb;
begin
  if not esheep_private.is_active_farm_member(p_farm_id,array['owner','administrator','worker']) then
    raise exception using errcode='42501', message='roster_read_denied';
  end if;
  select p.time_zone_identifier into strict zone
    from esheep_cloud.farm_state s join esheep_cloud.farm_profiles p using(farm_id,farm_generation)
    where s.farm_id=p_farm_id and s.farm_generation=p_farm_generation and s.v2_ready and s.status in ('active','read_only');
  cutoff := ((p_day + case when p_opening then 0 else 1 end)::timestamp at time zone zone);
  select jsonb_build_object('farm',m.farm_id,'sourceGeneration',m.source_generation,'finalRevision',m.v1_final_event_boundary,
    'zone',zone,'cutoff',cutoff,'checkpoint',c.checkpoint_id,'digest',c.archive_digest,'bytes',c.archive_byte_count,'path',c.storage_path,
    'anchor',jsonb_build_object('checkpointID',w.checkpoint_id,'head',w.boundary_event_sequence,
       'atMillis',floor(extract(epoch from w.created_at)*1000)::bigint))
  into source from esheep_cloud.migration_reconciliations m
    join public.farm_checkpoints c on c.farm_id=m.farm_id and c.authority_generation=m.source_generation
    join lateral (select b.checkpoint_id,b.boundary_event_sequence,b.created_at from esheep_cloud.business_checkpoints b
       where b.farm_id=m.farm_id and b.farm_generation=p_farm_generation and b.status='verified' and b.created_at>=m.cut_over_at
       order by b.created_at limit 1) w on true
    where m.farm_id=p_farm_id and m.status='cut_over' and m.target_generation<=p_farm_generation
      and m.cut_over_at>=cutoff and c.verified_at<cutoff and c.checkpoint_format='compact_v1'
      and c.through_revision=0 and m.v1_final_event_boundary is not null
    order by m.cut_over_at,c.verified_at desc limit 1;
  return source;
end $$;
revoke all on function public.esheep_cloud_legacy_roster_source_v1(uuid,integer,date,boolean) from public,anon;
grant execute on function public.esheep_cloud_legacy_roster_source_v1(uuid,integer,date,boolean) to authenticated;
