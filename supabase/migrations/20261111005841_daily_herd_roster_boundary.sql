-- Identify the immutable version of the member's herd book at the requested local day.
create or replace function public.esheep_cloud_daily_roster_boundary_v1(
  p_farm_id uuid, p_farm_generation integer, p_day date default null, p_opening boolean default false
) returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  zone text;
  live_head bigint;
  roster_day date;
  today date;
  cutoff timestamptz;
  target bigint;
  checkpoint uuid;
begin
  if not esheep_private.is_active_farm_member(p_farm_id,array['owner','administrator','worker']) then
    raise exception using errcode='42501', message='roster_read_denied';
  end if;
  select p.time_zone_identifier,s.event_head into strict zone,live_head
    from esheep_cloud.farm_state s join esheep_cloud.farm_profiles p using (farm_id,farm_generation)
    where s.farm_id=p_farm_id and s.farm_generation=p_farm_generation and s.v2_ready
      and s.status in ('active','read_only');
  today := (statement_timestamp() at time zone zone)::date;
  roster_day := coalesce(p_day,today);
  if roster_day > today then return jsonb_build_object('unavailable','future','day',roster_day); end if;
  if roster_day=today and not p_opening then
    return jsonb_build_object('day',roster_day,'current',true,'zone',zone);
  end if;
  cutoff := ((roster_day + case when p_opening then 0 else 1 end)::timestamp at time zone zone);
  -- Only the continuous prefix received before this instant belonged to that day's book.
  select coalesce(min(e.event_sequence)-1,live_head) into target from esheep_cloud.events e
    where e.farm_id=p_farm_id and e.farm_generation=p_farm_generation and e.received_at>=cutoff;
  select c.checkpoint_id into checkpoint from esheep_cloud.business_checkpoints c
    where c.farm_id=p_farm_id and c.farm_generation=p_farm_generation and c.status='verified'
      and c.boundary_event_sequence<=target and c.created_at<cutoff
    order by c.boundary_event_sequence desc,c.created_at desc limit 1;
  if checkpoint is null then return jsonb_build_object('unavailable','no_roster','day',roster_day); end if;
  return jsonb_build_object('day',roster_day,'zone',zone,'checkpointID',checkpoint,'head',target,
    'atMillis',floor(extract(epoch from cutoff)*1000)::bigint-1);
end $$;
revoke all on function public.esheep_cloud_daily_roster_boundary_v1(uuid,integer,date,boolean) from public,anon;
grant execute on function public.esheep_cloud_daily_roster_boundary_v1(uuid,integer,date,boolean) to authenticated;
