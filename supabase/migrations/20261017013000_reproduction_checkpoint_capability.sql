-- Capability 2 adds nullable reproductive-cycle and round associations.
-- Keep the outer rollout/retention publication guards and all grants intact.
-- Only the protected wrapper may invoke this content validator.
create or replace function public.esheep_cloud_publish_checkpoint_content_v1(p_manifest jsonb,p_manifest_sha256 text,p_reconciliation_sha256 text)
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
    or p_manifest->>'formatVersion' <> '1' or p_manifest->>'minimumClientCapability' not in ('1','2') or jsonb_typeof(p_manifest->'minimumClientCapability') <> 'number'
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
revoke all on function public.esheep_cloud_publish_checkpoint_content_v1(jsonb,text,text)
  from public,anon,authenticated,service_role;
