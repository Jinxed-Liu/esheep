-- Conflict choices enter through a separate verified command path. Apply the
-- same pen lifecycle permission at the accepted-event boundary as pen.setActive.
create function esheep_cloud.guard_pen_attention_lifecycle()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if new.stream_type='pen' and new.event_kind='attention_resolved' and new.before_digest<>new.after_digest then
  if not exists(select 1 from esheep_cloud.pen_management_catalog p
   where p.farm_id=new.farm_id and p.farm_generation=new.farm_generation and p.pen_id=new.stream_id and not p.is_deleted) then
   raise exception using errcode='23503',message='羊舍不存在或已删除，不能再修改。';
  end if;
  if new.event_body->>'field'='isActive' and not exists(select 1 from public.farm_members m
   where m.farm_id=new.farm_id and m.app_account_id=new.actor_account_id and m.status='active' and m.role in ('owner','administrator')) then
   raise exception using errcode='42501',message='羊舍启用状态仅限牧场主或管理员处理。';
  end if;
 end if;
 return new;
end
$$;
revoke all on function esheep_cloud.guard_pen_attention_lifecycle() from public,anon,authenticated;
create trigger pen_attention_lifecycle_before_event before insert on esheep_cloud.events
 for each row execute function esheep_cloud.guard_pen_attention_lifecycle();
