-- RETURNS TABLE output columns become PL/pgSQL variables. Several idempotent
-- INSERT ... ON CONFLICT clauses intentionally use the same PostgreSQL column
-- names, so explicitly prefer table columns in those function bodies.
do $migration$
declare
  v_function regprocedure;
  v_definition text;
begin
  foreach v_function in array array[
    'public.register_device(uuid,jsonb,text)'::regprocedure,
    'public.begin_farm_authority_transition(uuid,uuid,text,integer,bigint,text)'::regprocedure,
    'public.register_farm_checkpoint(uuid,uuid,uuid,integer,bigint,jsonb,text,text,bigint,bigint,bigint,bigint)'::regprocedure
  ]
  loop
    v_definition := pg_get_functiondef(v_function);
    if position('#variable_conflict use_column' in v_definition) = 0 then
      v_definition := replace(
        v_definition,
        E'AS $function$\n',
        E'AS $function$\n#variable_conflict use_column\n'
      );
      execute v_definition;
    end if;
  end loop;
end;
$migration$;
