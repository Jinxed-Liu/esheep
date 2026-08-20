-- The four-argument TMR-aware overload replaced the legacy registration path,
-- but its EXECUTE privilege was never granted to authenticated API callers.
-- Keep both supported signatures private from anon/public while allowing a
-- signed-in client to register its own device under the functions' RLS checks.
revoke all on function public.register_device(uuid, jsonb, text, integer)
  from public, anon, authenticated;
grant execute on function public.register_device(uuid, jsonb, text, integer)
  to authenticated;

revoke all on function public.register_device(uuid, jsonb, text)
  from public, anon, authenticated;
grant execute on function public.register_device(uuid, jsonb, text)
  to authenticated;
