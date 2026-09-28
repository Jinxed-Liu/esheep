-- Read-only, project-scoped input for a protected Xcode Cloud worker.
-- Authenticated clients cannot read this administrative source endpoint.
create function public.esheep_cloud_checkpoint_worker_source_v1(
  p_action text, p_farm_id uuid default null, p_generation integer default null,
  p_after bigint default null, p_through bigint default null, p_checkpoint_id uuid default null
) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  if p_action='list' then
    select coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) into result from (
      select s.farm_id,s.farm_generation,s.event_head,c.boundary_event_sequence,c.verified_at
      from esheep_cloud.farm_state s
      left join lateral (select boundary_event_sequence,verified_at from esheep_cloud.business_checkpoints c
        where c.farm_id=s.farm_id and c.farm_generation=s.farm_generation and c.status='verified'
        order by boundary_event_sequence desc limit 1) c on true
      where s.v2_ready and not s.write_frozen and s.status in ('active','read_only') order by s.farm_id
    ) q;
  elsif p_action='seal' then
select jsonb_build_object(
      'state',jsonb_build_object('farm_generation',s.farm_generation,'event_head',s.event_head,
        'status',s.status,'v2_ready',s.v2_ready,'write_frozen',s.write_frozen),
      'parent',(select jsonb_build_object('manifest',c.manifest,'manifestSHA256',c.manifest_sha256,
        'reconciliationSHA256',c.reconciliation_sha256,'verifiedAt',c.verified_at) from esheep_cloud.business_checkpoints c
        where c.farm_id=s.farm_id and c.farm_generation=s.farm_generation and c.status='verified'
        order by c.boundary_event_sequence desc limit 1),
      'profile',esheep_cloud.farm_profile_json_v2(p),
      'streams',coalesce((select jsonb_agg(jsonb_build_object('record_kind','stream',
        'stream_type',t.stream_type,'stream_id',t.stream_id,'stream_version',t.stream_version,
        'field_versions',t.field_versions,'content_digest',t.content_digest,'last_event_sequence',t.last_event_sequence)
        order by t.stream_type,t.stream_id) from esheep_cloud.streams t
        where t.farm_id=s.farm_id and t.farm_generation=s.farm_generation),'[]'::jsonb),
      'assets',coalesce((select jsonb_agg(to_jsonb(t)-'farm_id'-'farm_generation'||jsonb_build_object('record_kind','asset')
        order by t.asset_id) from esheep_cloud.assets t
        where t.farm_id=s.farm_id and t.farm_generation=s.farm_generation),'[]'::jsonb)) into result
      from esheep_cloud.farm_state s join esheep_cloud.farm_profiles p
        on p.farm_id=s.farm_id and p.farm_generation=s.farm_generation where s.farm_id=p_farm_id;
    if result is null or not (result->'state'->>'v2_ready')::boolean
      or (result->'state'->>'write_frozen')::boolean then
      raise exception 'checkpoint_source_unavailable';
    end if;
  elsif p_action='events' then
    if p_after is null or p_through is null or p_after<0 or p_through<p_after
      or not exists(select 1 from esheep_cloud.farm_state s where s.farm_id=p_farm_id
        and s.farm_generation=p_generation and s.event_head>=p_through and s.v2_ready) then
      raise exception 'checkpoint_source_boundary_changed';
    end if;
    select coalesce(jsonb_agg(q.body order by (q.body->>'event_sequence')::bigint),'[]'::jsonb) into result from (
select jsonb_build_object(
          'record_kind','event','event_sequence',event_sequence,'event_id',event_id,
          'command_id',command_id,'source_command_digest',source_command_digest,
          'stream_type',stream_type,'stream_id',stream_id,'event_kind',event_kind,
          'event_body_canonical',esheep_cloud.canonical_json_text(event_body),
          'event_body_digest',event_body_digest,'affected_fields',affected_fields,
          'before_digest',before_digest,'after_digest',after_digest,
          'actor_account_id',actor_account_id,'source_device_id',source_device_id,
          'source_device_sequence',source_device_sequence,
          'occurred_at_millis',round(extract(epoch from occurred_at)*1000)::bigint,
          'received_at_millis',round(extract(epoch from received_at)*1000)::bigint,
          'event_digest',event_digest) body
          from esheep_cloud.events where farm_id=p_farm_id and farm_generation=p_generation
          and event_sequence>p_after and event_sequence<=p_through order by event_sequence limit 500) q;
  elsif p_action='state' then
    select jsonb_build_object('farm_generation',farm_generation,'event_head',event_head)
      into result from esheep_cloud.farm_state where farm_id=p_farm_id;
  elsif p_action='parent' then
    select jsonb_build_object('manifest_sha256',manifest_sha256,'status',status)
      into result from esheep_cloud.business_checkpoints where checkpoint_id=p_checkpoint_id;
  else
    raise exception 'checkpoint_source_unknown_action';
  end if;
  return result;
end $$;
revoke all on function public.esheep_cloud_checkpoint_worker_source_v1(text,uuid,integer,bigint,bigint,uuid) from public,anon,authenticated;
grant execute on function public.esheep_cloud_checkpoint_worker_source_v1(text,uuid,integer,bigint,bigint,uuid) to service_role;
