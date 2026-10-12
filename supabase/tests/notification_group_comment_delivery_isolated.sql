BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT extensions.plan(14);
SELECT gen_random_uuid() AS actor \gset
SELECT gen_random_uuid() AS eligible \gset
SELECT gen_random_uuid() AS inbound_blocker \gset
SELECT gen_random_uuid() AS outbound_blocker \gset
SELECT gen_random_uuid() AS delivery_target \gset
SELECT gen_random_uuid() AS group_id \gset
SELECT gen_random_uuid() AS event_operation \gset
SELECT gen_random_uuid() AS comment_operation \gset
SELECT gen_random_uuid() AS installation_id \gset
SELECT gen_random_uuid() AS eligible_installation_id \gset
SELECT gen_random_uuid() AS stale_lease_id \gset

INSERT INTO auth.users(id) VALUES
 (:'actor'),
 (:'eligible'),
 (:'inbound_blocker'),
 (:'outbound_blocker'),
 (:'delivery_target');
INSERT INTO public.profiles(user_id,display_name) VALUES
 (:'actor','Synthetic comment author'),
 (:'eligible','Synthetic eligible member'),
 (:'inbound_blocker','Synthetic inbound blocker'),
 (:'outbound_blocker','Synthetic outbound blocker'),
 (:'delivery_target','Synthetic delivery target')
ON CONFLICT (user_id) DO UPDATE SET display_name=EXCLUDED.display_name;
INSERT INTO public.groups(id,owner_user_id,name,type,event_create_policy) VALUES
 (:'group_id',:'actor','Synthetic notification group','other','member');
INSERT INTO public.group_members(group_id,user_id,role) VALUES
 (:'group_id',:'actor','owner'),
 (:'group_id',:'eligible','member'),
 (:'group_id',:'inbound_blocker','member'),
 (:'group_id',:'outbound_blocker','member'),
 (:'group_id',:'delivery_target','member');
INSERT INTO public.blocks(blocker_user_id,blocked_user_id) VALUES
 (:'inbound_blocker',:'actor'),
 (:'actor',:'outbound_blocker');

SELECT set_config('request.jwt.claim.sub', :'actor', true);
SET LOCAL request.jwt.claim.role='authenticated';
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE event_fixture ON COMMIT DROP AS
SELECT event_id FROM public.create_group_event(
 :'group_id','Synthetic comment notification event',
 '2026-09-28 10:00+09','2026-09-28 11:00+09','Room','Synthetic details',
 :'event_operation');
CREATE TEMP TABLE comment_fixture ON COMMIT DROP AS
SELECT comment_id FROM public.create_group_event_comment(
 (SELECT event_id FROM event_fixture),'Synthetic comment body',
 :'comment_operation');
SELECT extensions.ok((SELECT comment_id IS NOT NULL FROM comment_fixture),
 'authenticated group member creates a comment through the production RPC');

RESET ROLE;
SELECT extensions.is((SELECT count(*) FROM private.notification_inbox
 WHERE notification_type='group_comment' AND recipient_user_id=:'eligible'),1::bigint,
 'eligible group member receives one group-comment inbox row');
SELECT extensions.is((SELECT count(*) FROM private.notification_inbox
 WHERE notification_type='group_comment' AND recipient_user_id=:'inbound_blocker'),0::bigint,
 'recipient who blocked the comment author is suppressed at enqueue');
SELECT extensions.is((SELECT count(*) FROM private.notification_inbox
 WHERE notification_type='group_comment' AND recipient_user_id=:'outbound_blocker'),0::bigint,
 'recipient blocked by the comment author is suppressed at enqueue');
SELECT extensions.is((SELECT count(*) FROM private.notification_inbox
 WHERE notification_type='group_comment' AND recipient_user_id=:'delivery_target'),1::bigint,
 'delivery-target recipient is eligible when the comment is enqueued');
SELECT extensions.is((SELECT count(*) FROM private.notification_outbox o
 JOIN private.notification_inbox i ON i.id=o.inbox_id
 WHERE i.notification_type='group_comment'),2::bigint,
 'each eligible comment inbox row has one durable outbox row');

SELECT set_config('request.jwt.claim.sub', :'actor', true);
SET LOCAL request.jwt.claim.role='authenticated';
SET LOCAL ROLE authenticated;
SELECT extensions.is((SELECT comment_id FROM comment_fixture),
 (SELECT comment_id FROM public.create_group_event_comment(
  (SELECT event_id FROM event_fixture),'Synthetic comment body',
  :'comment_operation')),
 'idempotent comment RPC replay returns the same comment');
RESET ROLE;
SELECT extensions.is((SELECT count(*) FROM private.notification_inbox
 WHERE notification_type='group_comment'),2::bigint,
 'comment RPC replay does not enqueue a duplicate notification');

WITH inserted_tokens AS (
 INSERT INTO public.device_tokens(user_id,platform,token_hash,token_preview)
 VALUES
  (:'eligible','android',
   encode(extensions.digest('synthetic-eligible-token-0001','sha256'),'hex'),'0001'),
  (:'delivery_target','android',
   encode(extensions.digest('synthetic-delivery-token-0002','sha256'),'hex'),'0002')
 RETURNING id,user_id
)
INSERT INTO private.notification_installation_bindings(
 installation_id,user_id,client_generation,binding_generation,public_token_id,platform,token
)
SELECT CASE WHEN user_id=:'eligible' THEN :'eligible_installation_id'::uuid ELSE :'installation_id'::uuid END,
 user_id,1,1,id,'android',
 CASE WHEN user_id=:'eligible' THEN 'synthetic-eligible-token-0001'
      ELSE 'synthetic-delivery-token-0002' END
FROM inserted_tokens;
INSERT INTO public.blocks(blocker_user_id,blocked_user_id)
VALUES (:'delivery_target',:'actor');
SET LOCAL request.jwt.claim.role='service_role';
SET LOCAL ROLE service_role;
CREATE TEMP TABLE delivery_claim ON COMMIT DROP AS
SELECT * FROM public.claim_notification_outbox(10,60);
SELECT extensions.ok((SELECT count(*)>0 FROM delivery_claim
 WHERE notification_type='group_comment' AND recipient_user_id=:'eligible'),
 'eligible group-comment delivery is leased by the current dispatcher claim');
SELECT extensions.is((SELECT count(*) FROM delivery_claim
 WHERE recipient_user_id=:'delivery_target'),0::bigint,
 'delivery-time block prevents claiming queued notifications for that recipient');
RESET ROLE;
SELECT extensions.is((SELECT count(*) FROM private.notification_delivery_attempts d
 JOIN private.notification_outbox o ON o.id=d.outbox_id
 JOIN private.notification_inbox i ON i.id=o.inbox_id
 WHERE i.notification_type='group_comment'
   AND o.recipient_user_id=:'delivery_target'),0::bigint,
 'ineligible queued comment never creates a deliverable attempt');
SET LOCAL request.jwt.claim.role='service_role';
SET LOCAL ROLE service_role;
SELECT extensions.is(public.finish_notification_delivery(
 (SELECT outbox_id FROM delivery_claim ORDER BY delivery_id LIMIT 1),
 (SELECT delivery_id FROM delivery_claim ORDER BY delivery_id LIMIT 1),
 :'stale_lease_id',
 (SELECT installation_id FROM delivery_claim ORDER BY delivery_id LIMIT 1),
 (SELECT binding_generation FROM delivery_claim ORDER BY delivery_id LIMIT 1),
 'sent'),false,'stale lease cannot finish a claimed delivery');
SELECT extensions.is(public.finish_notification_delivery(
 (SELECT outbox_id FROM delivery_claim ORDER BY delivery_id LIMIT 1),
 (SELECT delivery_id FROM delivery_claim ORDER BY delivery_id LIMIT 1),
 (SELECT lease_id FROM delivery_claim ORDER BY delivery_id LIMIT 1),
 (SELECT installation_id FROM delivery_claim ORDER BY delivery_id LIMIT 1),
 (SELECT binding_generation FROM delivery_claim ORDER BY delivery_id LIMIT 1)+1,
 'sent'),false,'stale binding generation cannot finish a claimed delivery');
SELECT extensions.is(public.finish_notification_delivery(
 (SELECT outbox_id FROM delivery_claim ORDER BY delivery_id LIMIT 1),
 (SELECT delivery_id FROM delivery_claim ORDER BY delivery_id LIMIT 1),
 (SELECT lease_id FROM delivery_claim ORDER BY delivery_id LIMIT 1),
 (SELECT installation_id FROM delivery_claim ORDER BY delivery_id LIMIT 1),
 (SELECT binding_generation FROM delivery_claim ORDER BY delivery_id LIMIT 1),
 'sent','synthetic-provider-message-id'),true,
 'matching lease installation and binding generation can finish the delivery');
RESET ROLE;
SELECT * FROM extensions.finish();
ROLLBACK;
