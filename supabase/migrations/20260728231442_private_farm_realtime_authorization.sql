-- Realtime is only a low-latency hint. The operation cursor remains the
-- authority. Clients may receive one private revision notification for farms
-- where they are active members, but no client policy permits Broadcast send.

drop policy if exists farm_realtime_receive_member on realtime.messages;

create policy farm_realtime_receive_member
on realtime.messages
for select
to authenticated
using (
  realtime.messages.extension = 'broadcast'
  and realtime.messages.event = 'revision_available'
  and realtime.messages.private
  and esheep_private.is_active_farm_member(
    esheep_private.realtime_farm_id((select realtime.topic()))
  )
);
