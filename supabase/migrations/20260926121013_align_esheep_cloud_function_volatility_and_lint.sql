-- These helpers call PostgreSQL routines whose volatility is STABLE. Keep
-- their declarations aligned with those dependencies so the planner never
-- folds session-dependent values as constants.
alter function esheep_cloud.canonical_json_text(jsonb) stable;
alter function esheep_cloud.json_digest(jsonb) stable;
alter function esheep_cloud.farm_profile_json_v2(esheep_cloud.farm_profiles) stable;
alter function esheep_cloud.value_digest(jsonb) stable;
alter function esheep_cloud.safe_value_digest_v2(jsonb) stable;
alter function esheep_cloud.safe_jsonb_from_utf8_v2(bytea) stable;
alter function esheep_cloud.normalize_contract_json_v2(jsonb) stable;
alter function esheep_cloud.validate_sheep_label_payload(text,jsonb,jsonb,jsonb) stable;
alter function esheep_cloud.validate_command_semantics_v2(text,jsonb,text,jsonb,jsonb,jsonb) stable;

-- The main semantic validator already rejects a missing merge mode. Preserve
-- that invariant at the dispatcher boundary as well and keep its established
-- four-argument interface available to callers and release inventory checks.
do $migration$
declare
  v_definition text;
  v_marker text := '  v_handler := case p_kind';
  v_guard text := '  if p_merge_mode is null then
    raise exception using errcode = ''22023'', message = ''esheep_cloud_command_semantics_invalid'';
  end if;

';
begin
  v_definition := pg_get_functiondef(
    'esheep_cloud.dispatch_command_v2(text,jsonb,text,jsonb)'::regprocedure
  );
  if position(v_marker in v_definition) = 0
     or position(v_marker in replace(v_definition, v_marker, '')) <> 0 then
    raise exception 'command dispatcher changed before merge-mode guard';
  end if;
  execute replace(v_definition, v_marker, v_guard || v_marker);
end
$migration$;

-- This SELECT was used only for FOUND and its FOR UPDATE lock. PERFORM keeps
-- both behaviors while avoiding an unused row variable.
do $migration$
declare
  v_definition text;
  v_declaration text := E'  v_transition public.authority_transitions%rowtype;\n';
  v_select_marker text := '  select transition.* into v_transition';
begin
  v_definition := pg_get_functiondef(
    'public.stage_farm_projection_batch(uuid,uuid,integer,jsonb)'::regprocedure
  );
  if position(v_declaration in v_definition) = 0
     or position(v_declaration in replace(v_definition, v_declaration, '')) <> 0
     or position(v_select_marker in v_definition) = 0
     or position(v_select_marker in replace(v_definition, v_select_marker, '')) <> 0 then
    raise exception 'projection staging function changed before lint cleanup';
  end if;
  v_definition := replace(v_definition, v_declaration, '');
  v_definition := replace(v_definition, v_select_marker, '  perform 1');
  execute v_definition;
end
$migration$;
