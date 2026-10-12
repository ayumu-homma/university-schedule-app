-- Realtime v2.108.0 inserts authorization probes with topic and extension,
-- omitting private (whose database default is false). Authorize the exact
-- owner topic and row instead. Actual sends and subscriptions remain private.
alter policy schedule_sync_broadcast_receive
on realtime.messages
using (
  extension = 'broadcast'
  and topic = realtime.topic()
  and realtime.topic() = 'schedule-sync:' || auth.uid()::text
);
