-- Historical archive rows are real sheep-profile projection facts.  They are
-- intentionally represented as normal sheep.patchProfile field events so a
-- fresh device can rebuild the same `isHistoricalArchive` value from the
-- immutable V2 ledger.  Existing profile fields and existing event rows remain
-- unchanged.

create or replace function esheep_cloud.field_display_name(p_field text)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select case p_field
    when 'avatar' then '头像'
    when 'earTag' then '耳号'
    when 'breed' then '品种'
    when 'sex' then '性别'
    when 'birthAt' then '出生日期'
    when 'currentParity' then '当前胎次'
    when 'parityRecordedAt' then '胎次确认时间'
    when 'note' then '备注'
    when 'purpose' then '用途'
    when 'isBreedingRam' then '种公羊标记'
    when 'isHistoricalArchive' then '历史归档标记'
    when 'name' then '名称'
    when 'isActive' then '启用状态'
    when 'displayName' then '牧场地点'
    when 'latitude' then '纬度'
    when 'longitude' then '经度'
    when 'addressSnapshot' then '地址'
    when 'timeZoneIdentifier' then '时区'
    else p_field
  end;
$$;

-- The field-scope guard lives in the durable command processor.  Rebuild that
-- function from its installed definition so this additive migration changes
-- exactly one allow-list entry while retaining the server's current contract
-- and all later hardening already applied to the remote database.
do $$
declare
  v_definition text;
  v_before text := $needle$
             'earTag', 'breed', 'sex', 'birthAt', 'currentParity',
             'parityRecordedAt', 'note'
           ]$needle$;
  v_after text := $replacement$
             'earTag', 'breed', 'sex', 'birthAt', 'currentParity',
             'parityRecordedAt', 'note', 'isHistoricalArchive'
           ]$replacement$;
begin
  select pg_get_functiondef(
    'esheep_cloud.process_command_v2(uuid,integer,uuid,jsonb)'::regprocedure
  ) into v_definition;
  if position(v_before in v_definition) = 0
     or position(v_before in replace(v_definition, v_before, '')) <> 0 then
    raise exception using
      message = 'historical_archive_processor_allowlist_shape_changed';
  end if;
  execute replace(v_definition, v_before, v_after);
end;
$$;
