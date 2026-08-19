-- Realtime evaluates channel authorization with a synthetic messages row when
-- the client joins. At that point extension and topic are populated, while an
-- application event name is not a stable authorization input. Keep the
-- channel private in the client/project settings and authorize receipt solely
-- through active farm membership for the requested farm topic.

drop policy if exists farm_realtime_receive_member on realtime.messages;

create policy farm_realtime_receive_member
on realtime.messages
for select
to authenticated
using (
  realtime.messages.extension = 'broadcast'
  and esheep_private.is_active_farm_member(
    esheep_private.realtime_farm_id((select realtime.topic()))
  )
);

-- Intentionally do not add an INSERT policy: iOS clients may receive server
-- revision notifications but cannot publish Broadcast messages.
