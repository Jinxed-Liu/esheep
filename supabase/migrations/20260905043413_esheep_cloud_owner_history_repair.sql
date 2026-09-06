-- Forward-only, owner-authorized historical projection repair. No old
-- command/event/snapshot or V1 business row is changed by this migration.
create table esheep_cloud.history_repair_approvals (
  command_id uuid primary key,
  farm_id uuid not null references public.farm_registry(farm_id),
  farm_generation integer not null check (farm_generation > 0),
  approved_by_user_id uuid not null references public.profiles(user_id),
  command_kind text not null check (command_kind in ('migration.restoreSheepBaseline','migration.restoreRemoval','migration.restoreBusinessBaseline')),
  content_digest text not null check (content_digest ~ '^[0-9a-f]{64}$'),
  source_manifest_digest text not null check (source_manifest_digest ~ '^[0-9a-f]{64}$'),
  expected_event_head bigint not null check (expected_event_head >= 0),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
alter table esheep_cloud.history_repair_approvals enable row level security;
revoke all on esheep_cloud.history_repair_approvals from public, anon, authenticated;
grant select, insert on esheep_cloud.history_repair_approvals to service_role;

insert into esheep_cloud.command_catalog (command_kind, merge_mode, allowed_roles, requires_online, current_schema_version)
values
 ('migration.restoreSheepBaseline','append_fact',array['owner'],true,1),
 ('migration.restoreBusinessBaseline','append_fact',array['owner'],true,1),
 ('migration.restoreRemoval','append_fact',array['owner'],true,1)
on conflict (command_kind) do update set merge_mode=excluded.merge_mode,
 allowed_roles=excluded.allowed_roles,requires_online=excluded.requires_online,
 current_schema_version=excluded.current_schema_version;

-- Preserve installed hardening. Each exact patch must match once; an
-- unexpected definition aborts the migration instead of replacing a function
-- with an older copy. No extra SECURITY DEFINER function is introduced.
do $migration$
declare d text; before_text text; after_text text; signature text;
begin
 foreach signature in array array[
   'esheep_cloud.expected_payload_case_v2(text)',
   'esheep_cloud.dispatch_command_v2(text,jsonb,text,jsonb)',
   'esheep_cloud.client_projection_route_v2(text)'
 ] loop
   select pg_get_functiondef(signature::regprocedure) into d;
   before_text := case when signature like '%expected_payload_case%'
     then 'when ''sheep.add'' then ''add'''
     else 'when ''sheep.add'' then ''sheep.add''' end;
   after_text := before_text || E'\n    ' || case when signature like '%expected_payload_case%'
     then 'when ''migration.restoreSheepBaseline'' then ''restoreSheepBaseline''
    when ''migration.restoreRemoval'' then ''restoreRemoval''
    when ''migration.restoreBusinessBaseline'' then ''restoreBusinessBaseline'''
     else 'when ''migration.restoreSheepBaseline'' then ''migration.restoreSheepBaseline''
    when ''migration.restoreRemoval'' then ''migration.restoreRemoval''
    when ''migration.restoreBusinessBaseline'' then ''migration.restoreBusinessBaseline''' end;
   if position(before_text in d)=0 or position(before_text in replace(d,before_text,''))<>0 then
     raise exception 'history repair route definition changed: %',signature;
   end if;
   execute replace(d,before_text,after_text);
 end loop;

 -- Current server retains the UUID/decimal normalization wrapper; extend
 -- only its delegated semantics function, not the wrapper itself.
 select pg_get_functiondef('esheep_cloud.validate_command_semantics_v2_legacy(text,jsonb,text,jsonb,jsonb,jsonb)'::regprocedure) into d;
 before_text := 'when p_kind = ''sheep.add'' then ''sheep''';
 after_text := before_text || E'\n    when p_kind in (''migration.restoreSheepBaseline'',''migration.restoreRemoval'',''migration.restoreBusinessBaseline'') then ''migrationRepair''';
 if position(before_text in d)=0 or position(before_text in replace(d,before_text,''))<>0 then
   raise exception 'history repair semantics definition changed';
 end if;
 execute replace(d,before_text,after_text);

 select pg_get_functiondef('esheep_cloud.process_command_v2(uuid,integer,uuid,jsonb)'::regprocedure) into d;
 before_text := '  -- sourceRequestID is also immutable within a farm.  A different command';
 after_text := $guard$
  -- Executed after the farm row lock and after ordinary signature/role/scope
  -- checks and BOTH duplicate branches, before any new ledger mutation.
  -- Concurrent retries waiting on the farm lock must also remain idempotent.
  -- The earlier duplicate branch
  -- still returns the original receipt after expiry/head advancement.
  if v_kind in ('migration.restoreSheepBaseline','migration.restoreRemoval','migration.restoreBusinessBaseline') then
    if v_role <> 'owner' or not exists (
      select 1 from esheep_cloud.history_repair_approvals approval
      where approval.command_id=v_command_id and approval.farm_id=p_farm_id
        and approval.farm_generation=p_farm_generation
        and approval.approved_by_user_id=p_user_id
        and approval.command_kind=v_kind and approval.content_digest=v_digest
        and approval.expected_event_head=v_farm_state.event_head
        and approval.expires_at>clock_timestamp()
    ) or jsonb_array_length(v_affected_streams)<>1 then
      raise exception using errcode='42501',message='esheep_cloud_history_repair_not_approved';
    end if;
  end if;
$guard$ || before_text;
 if position(before_text in d)=0 or position(before_text in replace(d,before_text,''))<>0 then
   raise exception 'history repair processor definition changed';
 end if;
 execute replace(d,before_text,after_text);
end;
$migration$;
