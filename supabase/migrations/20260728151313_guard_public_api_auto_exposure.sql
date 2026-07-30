-- The hosted Dashboard toggle for "Automatically expose new tables" can fail
-- before changing supabase_admin's legacy default ACL. Keep the effective
-- security invariant inside Postgres as well: after any supported public DDL,
-- remove implicit client privileges while leaving explicit migration GRANTs
-- as the only way to expose an object.

create or replace function esheep_private.guard_public_data_api_exposure()
returns event_trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_command record;
begin
  for v_command in
    select *
    from pg_event_trigger_ddl_commands()
    where schema_name = 'public'
  loop
    if v_command.object_type in ('table', 'partitioned table') then
      execute format(
        'revoke all privileges on table %s from public, anon, authenticated',
        v_command.object_identity
      );
    elsif v_command.object_type = 'sequence' then
      execute format(
        'revoke all privileges on sequence %s from public, anon, authenticated',
        v_command.object_identity
      );
    elsif v_command.object_type = 'function' then
      execute format(
        'revoke all privileges on function %s from public, anon, authenticated',
        v_command.object_identity
      );
    elsif v_command.object_type = 'procedure' then
      execute format(
        'revoke all privileges on procedure %s from public, anon, authenticated',
        v_command.object_identity
      );
    end if;
  end loop;
end;
$$;

revoke all on function esheep_private.guard_public_data_api_exposure()
  from public, anon, authenticated;

drop event trigger if exists esheep_guard_public_data_api_exposure;
create event trigger esheep_guard_public_data_api_exposure
on ddl_command_end
when tag in (
  'CREATE TABLE',
  'CREATE TABLE AS',
  'CREATE SEQUENCE',
  'CREATE FUNCTION',
  'CREATE PROCEDURE'
)
execute function esheep_private.guard_public_data_api_exposure();
