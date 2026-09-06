-- Additive checkpoint metadata. Existing snapshots and command protocol stay intact.
create table esheep_cloud.business_checkpoints (
  checkpoint_id uuid primary key,
  farm_id uuid not null references esheep_cloud.farm_state(farm_id),
  farm_generation integer not null check (farm_generation >= 0),
  boundary_event_sequence bigint not null check (boundary_event_sequence >= 0),
  format_version integer not null check (format_version = 1),
  manifest jsonb not null,
  manifest_sha256 text not null check (manifest_sha256 ~ '^[0-9a-f]{64}$'),
  reconciliation_sha256 text not null check (reconciliation_sha256 ~ '^[0-9a-f]{64}$'),
  status text not null default 'candidate' check (status in ('candidate','verified','retired')),
  pinned boolean not null default false,
  created_at timestamptz not null default now(),
  verified_at timestamptz,
  unique (farm_id, farm_generation, checkpoint_id)
);
alter table esheep_cloud.business_checkpoints enable row level security;
revoke all on esheep_cloud.business_checkpoints from public, anon, authenticated;
grant select, insert, update on esheep_cloud.business_checkpoints to service_role;
create index business_checkpoints_latest on esheep_cloud.business_checkpoints
  (farm_id,farm_generation,boundary_event_sequence desc) where status='verified';

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('esheep-cloud-checkpoints','esheep-cloud-checkpoints',false,8388608,
        array['application/gzip','application/json'])
on conflict (id) do nothing;

-- This function is called with the caller JWT, before the edge service signs
-- any object URL. Revoked/foreign members cannot read manifests or audit rows.
create function public.esheep_cloud_checkpoint_manifest_v1(p_farm_id uuid,p_farm_generation integer,p_checkpoint_id uuid default null)
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
  select c.manifest into v_manifest from esheep_cloud.business_checkpoints c
    where c.farm_id=p_farm_id and c.farm_generation=p_farm_generation and c.status='verified'
      and (p_checkpoint_id is null or c.checkpoint_id=p_checkpoint_id)
    order by c.boundary_event_sequence desc,c.created_at desc limit 1;
  return jsonb_build_object('manifest',v_manifest);
end $$;
revoke all on function public.esheep_cloud_checkpoint_manifest_v1(uuid,integer,uuid) from public,anon;
grant execute on function public.esheep_cloud_checkpoint_manifest_v1(uuid,integer,uuid) to authenticated;

create function public.esheep_cloud_command_audit_v1(p_farm_id uuid,p_command_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not esheep_private.is_active_farm_member(p_farm_id,array['owner','administrator','worker']) then
    raise exception using errcode='42501',message='command_audit_denied';
  end if;
  if coalesce(cardinality(p_command_ids),0) not between 1 and 25 then
    raise exception using errcode='22023',message='command_audit_batch_limit';
  end if;
  return jsonb_build_object('commands',coalesce((select jsonb_agg(jsonb_build_object(
    'command_id',c.command_id,'command_kind',c.command_kind,'status',c.status,
    'occurred_at',c.occurred_at,'server_received_at',c.server_received_at,
    'account_id',c.account_id,'device_id',c.device_id,'content_digest',c.content_digest,
    'result',c.result,'unsigned_command_base64',encode(c.unsigned_command,'base64'))
    order by c.server_received_at,c.command_id)
    from esheep_cloud.commands c where c.farm_id=p_farm_id and c.command_id=any(p_command_ids)),'[]'::jsonb));
end $$;
revoke all on function public.esheep_cloud_command_audit_v1(uuid,uuid[]) from public,anon;
grant execute on function public.esheep_cloud_command_audit_v1(uuid,uuid[]) to authenticated;

-- Publication is one short transaction, after immutable objects and the
-- independent reconciliation report exist. Only the protected worker may call.
create function public.esheep_cloud_publish_checkpoint_v1(p_manifest jsonb,p_manifest_sha256 text,p_reconciliation_sha256 text)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  v_id uuid := (p_manifest->>'checkpointID')::uuid;
  v_farm uuid := (p_manifest->>'farmID')::uuid;
  v_generation integer := (p_manifest->>'farmGeneration')::integer;
  v_head bigint := (p_manifest->>'boundaryEventSequence')::bigint;
  v_chunk jsonb;
  v_index integer := 0;
  v_anchor text;
begin
  if p_manifest is null or not (p_manifest ?& array['checkpointID','farmID','farmGeneration','boundaryEventSequence','boundaryEventDigest','formatVersion','minimumClientCapability','chunks','modelCounts','businessDigest','receiptChainDigest'])
    or p_manifest_sha256 is null or p_reconciliation_sha256 is null
    or p_manifest->>'formatVersion' <> '1' or p_manifest->>'minimumClientCapability' <> '1'
    or jsonb_typeof(p_manifest->'chunks') <> 'array'
    or jsonb_array_length(p_manifest->'chunks') not between 1 and 10000
    or p_manifest_sha256 !~ '^[0-9a-f]{64}$' or p_reconciliation_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception using errcode='22023',message='checkpoint_invalid_manifest';
  end if;
  if not exists(select 1 from esheep_cloud.farm_state s where s.farm_id=v_farm
      and s.farm_generation=v_generation and s.event_head>=v_head and s.v2_ready) then
    raise exception using errcode='55000',message='checkpoint_boundary_unavailable';
  end if;
  select e.event_digest into v_anchor from esheep_cloud.events e
    where e.farm_id=v_farm and e.farm_generation=v_generation and e.event_sequence=v_head;
  if v_head>0 and (v_anchor is null or v_anchor<>p_manifest->>'boundaryEventDigest') then
    raise exception using errcode='22023',message='checkpoint_boundary_digest_mismatch';
  end if;
  for v_chunk in select value from jsonb_array_elements(p_manifest->'chunks') loop
    if not (v_chunk ?& array['index','objectKey','compressedBytes','uncompressedBytes','compressedSHA256','contentSHA256','recordCount'])
      or (v_chunk->>'index')::integer<>v_index
      or v_chunk->>'objectKey'<>v_farm::text||'/'||v_id::text||'/'||lpad(v_index::text,5,'0')||'.json.gz'
      or (v_chunk->>'compressedBytes')::bigint not between 1 and 8388608
      or (v_chunk->>'uncompressedBytes')::bigint not between 1 and 8388608
      or v_chunk->>'compressedSHA256' !~ '^[0-9a-f]{64}$'
      or v_chunk->>'contentSHA256' !~ '^[0-9a-f]{64}$'
      or not exists(select 1 from storage.objects o where o.bucket_id='esheep-cloud-checkpoints'
        and o.name=v_chunk->>'objectKey' and (o.metadata->>'size')::bigint=(v_chunk->>'compressedBytes')::bigint) then
      raise exception using errcode='22023',message='checkpoint_object_verification_missing';
    end if;
    v_index:=v_index+1;
  end loop;
  if exists(select 1 from esheep_cloud.business_checkpoints c where c.checkpoint_id=v_id) then
    if not exists(select 1 from esheep_cloud.business_checkpoints c where c.checkpoint_id=v_id
      and c.manifest=p_manifest and c.manifest_sha256=p_manifest_sha256
      and c.reconciliation_sha256=p_reconciliation_sha256 and c.status='verified') then
      raise exception using errcode='23505',message='checkpoint_id_is_immutable';
    end if;
    return v_id;
  end if;
  insert into esheep_cloud.business_checkpoints(checkpoint_id,farm_id,farm_generation,boundary_event_sequence,
    format_version,manifest,manifest_sha256,reconciliation_sha256,status,verified_at)
  values(v_id,v_farm,v_generation,v_head,1,p_manifest,p_manifest_sha256,p_reconciliation_sha256,'verified',now());
  return v_id;
end $$;
revoke all on function public.esheep_cloud_publish_checkpoint_v1(jsonb,text,text) from public,anon,authenticated;
grant execute on function public.esheep_cloud_publish_checkpoint_v1(jsonb,text,text) to service_role;

-- The edge verifier selects exactly these public-key identity columns with its
-- server role before executing the security-definer write RPC. No client grant.
grant select(device_id,user_id,public_key_jwk,status) on public.devices to service_role;
