BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT extensions.plan(9);
SELECT gen_random_uuid() AS actor \gset
SELECT gen_random_uuid() AS enabled_invitee \gset
SELECT gen_random_uuid() AS disabled_invitee \gset
SELECT gen_random_uuid() AS group_id \gset
SELECT gen_random_uuid() AS outsider \gset

INSERT INTO auth.users(id) VALUES (:'actor'),(:'enabled_invitee'),(:'disabled_invitee'),(:'outsider');
INSERT INTO public.profiles(user_id,display_name) VALUES
 (:'actor','Synthetic inviter'),
 (:'enabled_invitee','Synthetic enabled invitee'),
 (:'disabled_invitee','Synthetic notification-disabled invitee'),
 (:'outsider','Synthetic unrelated user')
ON CONFLICT (user_id) DO NOTHING;
INSERT INTO public.groups(id,owner_user_id,name,type,event_create_policy) VALUES
 (:'group_id',:'actor','Synthetic invitation group','other','member');
INSERT INTO public.group_members(group_id,user_id,role) VALUES (:'group_id',:'actor','owner');
INSERT INTO public.friendships(requester_user_id,addressee_user_id,status) VALUES
 (:'actor',:'enabled_invitee','accepted'),
 (:'actor',:'disabled_invitee','accepted');
INSERT INTO public.notification_settings(user_id,group_updates_enabled) VALUES
 (:'enabled_invitee',true),(:'disabled_invitee',false);

SELECT set_config('request.jwt.claim.sub', :'actor', true) AS claim_sub \gset
SET LOCAL request.jwt.claim.role='authenticated';
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE invitation_enabled ON COMMIT DROP AS
SELECT * FROM public.create_targeted_group_invitation(
 :'group_id',:'enabled_invitee',clock_timestamp()+interval '1 day');
CREATE TEMP TABLE invitation_disabled ON COMMIT DROP AS
SELECT * FROM public.create_targeted_group_invitation(
 :'group_id',:'disabled_invitee',clock_timestamp()+interval '1 day');
RESET ROLE;

SELECT extensions.is((SELECT status FROM invitation_enabled),'pending',
 'notification-enabled friend receives a pending targeted invitation');
SELECT extensions.is((SELECT count(*) FROM public.group_members
 WHERE group_id=:'group_id' AND user_id=:'enabled_invitee'),0::bigint,
 'creating an invitation does not auto-join the friend');
SELECT extensions.is((SELECT count(*) FROM private.notification_inbox i
 JOIN private.notification_outbox o ON o.inbox_id=i.id
 WHERE i.invitation_id=(SELECT invitation_id FROM invitation_enabled)
   AND i.recipient_user_id=:'enabled_invitee'),1::bigint,
 'enabled invitation and durable notification outbox are atomic');
SELECT extensions.is((SELECT status FROM invitation_disabled),'pending',
 'notification-disabled friend still receives a pending invitation');
SELECT extensions.is((SELECT count(*) FROM private.notification_inbox i
 JOIN private.notification_outbox o ON o.inbox_id=i.id
 WHERE i.invitation_id=(SELECT invitation_id FROM invitation_disabled)
   AND i.recipient_user_id=:'disabled_invitee'),0::bigint,
 'disabled group notifications suppress invitation push enqueue');

SELECT set_config('request.jwt.claim.sub', :'disabled_invitee', true) AS claim_sub \gset
SET LOCAL request.jwt.claim.role='authenticated';
SET LOCAL ROLE authenticated;
SELECT extensions.is((SELECT count(*) FROM public.list_my_targeted_group_invitations()),1::bigint,
 'notification-disabled invitee still sees the product invitation inbox row');
SELECT extensions.is((SELECT status FROM public.respond_targeted_group_invitation(
 (SELECT invitation_id FROM invitation_disabled),true)),'accepted',
 'invitee can explicitly accept while push notifications are disabled');
RESET ROLE;
SELECT extensions.is((SELECT count(*) FROM public.group_members
 WHERE group_id=:'group_id' AND user_id=:'disabled_invitee'),1::bigint,
 'membership is created only after invitation acceptance');
SELECT set_config('request.jwt.claim.sub', :'outsider', true) AS claim_sub \gset
SET LOCAL request.jwt.claim.role='authenticated';
SET LOCAL ROLE authenticated;
SELECT extensions.is((SELECT count(*) FROM public.list_my_targeted_group_invitations()),0::bigint,
 'unrelated user cannot list another user invitation');
RESET ROLE;
SELECT * FROM extensions.finish();
ROLLBACK;
