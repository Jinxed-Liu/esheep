-- The projection trigger is installed on every event. Events such as
-- attention_resolved are not command events and may not carry command_kind.
-- Treat a missing key as a non-match instead of trying to parse a delete body.
create or replace function esheep_cloud.project_sheep_label_delete_event()
returns trigger language plpgsql security invoker set search_path='' as $$
declare
 v_d jsonb;
 v_id uuid;
 v_label esheep_cloud.sheep_label_catalog%rowtype;
 v_expected integer;
begin
 if new.event_body->>'command_kind' is distinct from 'care.sheepLabel.delete' then return new; end if;
 v_d:=new.event_body#>array['command_payload','body','sheepLabels','_0','deleteLabel','_0'];
 if jsonb_typeof(v_d) is distinct from 'object' then raise exception '标签删除命令内容无效。'; end if;
 v_id:=(v_d->>'id')::uuid;
 v_expected:=(v_d->>'expectedRevision')::integer;
 if new.stream_type<>'sheepLabel' or new.stream_id<>v_id then raise exception '标签删除对象不匹配。'; end if;
 select * into v_label from esheep_cloud.sheep_label_catalog
  where farm_id=new.farm_id and farm_generation=new.farm_generation and label_id=v_id;
 if not found then raise exception '标签不存在，可能已经被其他成员删除。'; end if;
 if v_label.revision is distinct from v_expected then raise exception '标签已由其他成员修改，请刷新后重试。'; end if;
 delete from esheep_cloud.sheep_label_catalog
  where farm_id=new.farm_id and farm_generation=new.farm_generation and label_id=v_id;
 update esheep_cloud.sheep_label_assignments a
  set label_ids=array_remove(a.label_ids,v_id),
      primary_label_id=esheep_cloud.sheep_label_primary(
       a.farm_id,a.farm_generation,array_remove(a.label_ids,v_id),a.primary_label_id),
      revision=a.revision+1
  where a.farm_id=new.farm_id and a.farm_generation=new.farm_generation and v_id=any(a.label_ids);
 return new;
end
$$;
revoke all on function esheep_cloud.project_sheep_label_delete_event() from public,anon,authenticated;
