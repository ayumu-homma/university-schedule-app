// Placeholder Edge Function for server-side event notification fan-out.
// Wire this to Supabase secrets and FCM/APNs credentials in a trusted environment.

type NotificationPayload = {
  eventId: string;
  actorUserId: string;
  reason: 'group_event_created' | 'event_comment_created' | 'participant_updated';
};

Deno.serve(async (request) => {
  const payload = (await request.json()) as NotificationPayload;

  return Response.json({
    accepted: true,
    eventId: payload.eventId,
    reason: payload.reason,
    note: 'Push fan-out is intentionally not implemented in the MVP skeleton.',
  });
});
