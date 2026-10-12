begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(51);

select extensions.ok(to_regprocedure('public.register_notification_device(uuid,bigint,text,text,text,text)') is not null,'device registration RPC exists');
select extensions.ok(to_regprocedure('public.revoke_notification_device(uuid,bigint,bigint)') is not null,'device revocation RPC exists');
select extensions.ok(to_regprocedure('public.list_server_notification_inbox(timestamp with time zone,integer,uuid)') is not null,'server inbox RPC exists');
select extensions.ok(to_regprocedure('public.create_targeted_group_invitation(uuid,uuid,timestamp with time zone)') is not null,'targeted invitation RPC exists');
select extensions.ok(not has_function_privilege('anon','public.register_notification_device(uuid,bigint,text,text,text,text)','execute'),'anonymous cannot register a delivery token');
select extensions.ok(has_function_privilege('authenticated','public.register_notification_device(uuid,bigint,text,text,text,text)','execute'),'authenticated user can register their own token');
select extensions.ok(not has_table_privilege('authenticated','private.notification_installation_bindings','select'),'mobile role cannot read deliverable tokens');
select extensions.ok(not has_table_privilege('service_role','private.notification_installation_bindings','select'),'dispatcher role reads tokens only through leased RPC');
select extensions.ok(not has_table_privilege('authenticated','public.device_tokens','select'),'mobile role cannot dump nondeliverable token index');
select extensions.ok(not has_function_privilege('authenticated','public.claim_notification_outbox(integer,integer)','execute'),'mobile role cannot dispatch push');
select extensions.ok(has_function_privilege('service_role','public.claim_notification_outbox(integer,integer)','execute'),'trusted dispatcher can claim outbox');
select extensions.ok(not has_function_privilege('anon','public.respond_targeted_group_invitation(uuid,boolean)','execute'),'anonymous cannot accept targeted invitation');

insert into auth.users(id) values
 ('da101111-1111-4111-8111-111111111111'),('da202222-2222-4222-8222-222222222222'),
 ('da303333-3333-4333-8333-333333333333'),('da404444-4444-4444-8444-444444444444'),
 ('da505555-5555-4555-8555-555555555555') on conflict(id) do nothing;
insert into public.profiles(user_id,display_name) values
 ('da101111-1111-4111-8111-111111111111','通知 actor'),
 ('da202222-2222-4222-8222-222222222222','受信 user'),
 ('da303333-3333-4333-8333-333333333333','ブロック user'),
 ('da404444-4444-4444-8444-444444444444','削除 user'),
 ('da505555-5555-4555-8555-555555555555','招待先') on conflict(user_id) do nothing;
insert into public.groups(id,owner_user_id,name,type,event_create_policy) values
 ('da606666-6666-4666-8666-666666666666','da101111-1111-4111-8111-111111111111','Private Group','other','member');
insert into public.group_members(group_id,user_id,role) values
 ('da606666-6666-4666-8666-666666666666','da101111-1111-4111-8111-111111111111','owner'),
 ('da606666-6666-4666-8666-666666666666','da202222-2222-4222-8222-222222222222','member'),
 ('da606666-6666-4666-8666-666666666666','da303333-3333-4333-8333-333333333333','member'),
 ('da606666-6666-4666-8666-666666666666','da404444-4444-4444-8444-444444444444','member');
insert into public.notification_settings(user_id,group_updates_enabled) values
 ('da303333-3333-4333-8333-333333333333',true),
 ('da202222-2222-4222-8222-222222222222',true)
 on conflict(user_id) do update set group_updates_enabled=true;
insert into public.blocks(blocker_user_id,blocked_user_id)
 values('da101111-1111-4111-8111-111111111111','da303333-3333-4333-8333-333333333333') on conflict do nothing;
insert into public.friendships(requester_user_id,addressee_user_id,status)
 values('da101111-1111-4111-8111-111111111111','da505555-5555-4555-8555-555555555555','accepted') on conflict do nothing;
delete from public.group_members where group_id='da606666-6666-4666-8666-666666666666' and user_id='da404444-4444-4444-8444-444444444444';

set local request.jwt.claim.sub='da202222-2222-4222-8222-222222222222';
set local request.jwt.claim.role='authenticated'; set local role authenticated;
create temporary table token_gen_one on commit drop as
select * from public.register_notification_device(
 'da808888-8888-4888-8888-888888888888',1,'android','private-test-token-generation-0001');
select extensions.is((select binding_generation from token_gen_one),1::bigint,'first device generation is accepted');
select extensions.is((select accepted from public.register_notification_device(
 'da808888-8888-4888-8888-888888888888',1,'android','private-test-token-stale-generation')),false,
 'stale registration generation is ignored');
create temporary table token_gen_two on commit drop as
select * from public.register_notification_device(
 'da808888-8888-4888-8888-888888888888',2,'android','private-test-token-generation-0002');
select extensions.is((select binding_generation from token_gen_two),2::bigint,'new device generation rotates binding');
select extensions.is(public.revoke_notification_device(
 'da808888-8888-4888-8888-888888888888',1,1),false,'stale revoke cannot disable newer token');
select extensions.is(public.revoke_notification_device(
 'da808888-8888-4888-8888-888888888888',2,2),true,'current device generation can be revoked');
reset role;
select extensions.is((select enabled from private.notification_installation_bindings
 where installation_id='da808888-8888-4888-8888-888888888888'),false,'revocation disables private token binding');

set local request.jwt.claim.sub='da101111-1111-4111-8111-111111111111';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
create temporary table event_fixture on commit drop as
select event_id from public.create_group_event(
 'da606666-6666-4666-8666-666666666666','Sensitive title','2026-09-24 10:00+09','2026-09-24 11:00+09',
 'Secret room','Sensitive details','da707777-7777-4777-8777-777777777777');
select extensions.is((select event_id from event_fixture),
 (select event_id from public.create_group_event(
 'da606666-6666-4666-8666-666666666666','Sensitive title','2026-09-24 10:00+09','2026-09-24 11:00+09',
 'Secret room','Sensitive details','da707777-7777-4777-8777-777777777777')),'mutation response replay does not create another event notification');
reset role;
select extensions.is((select count(*) from private.notification_inbox where group_id='da606666-6666-4666-8666-666666666666' and notification_type='group_event_created'),1::bigint,'event mutation and one recipient inbox/outbox commit atomically');
select extensions.is((select count(*) from private.notification_inbox where group_id='da606666-6666-4666-8666-666666666666' and recipient_user_id='da101111-1111-4111-8111-111111111111'),0::bigint,'actor is excluded from event notification');
select extensions.is((select count(*) from private.notification_inbox where group_id='da606666-6666-4666-8666-666666666666' and recipient_user_id in ('da303333-3333-4333-8333-333333333333','da404444-4444-4444-8444-444444444444')),0::bigint,'blocked and removed members receive no event notification');

set local request.jwt.claim.sub='da101111-1111-4111-8111-111111111111'; set local role authenticated;
select public.update_group_event((select event_id from event_fixture),'Changed title','2026-09-24 10:00+09','2026-09-24 11:00+09','Room','Details',1,'da717777-7777-4777-8777-777777777777');
select public.set_group_event_reaction((select event_id from event_fixture),'ok','da727777-7777-4777-8777-777777777777');
set local request.jwt.claim.sub='da202222-2222-4222-8222-222222222222';
select extensions.is((select count(*) from public.list_server_notification_inbox(null,50)),2::bigint,'recipient inbox exposes event create and change without reaction noise');
select extensions.is((select count(*) from public.list_server_notification_inbox(
 (select created_at from public.list_server_notification_inbox(null,50) order by created_at desc,inbox_id desc limit 1),
 1,
 (select inbox_id from public.list_server_notification_inbox(null,50) order by created_at desc,inbox_id desc limit 1)
)),1::bigint,'composite cursor returns the next older inbox row');
select extensions.throws_ok($$select * from public.list_server_notification_inbox(clock_timestamp(),10,null)$$,
 '22023','incomplete notification cursor','inbox rejects a partial composite cursor');
reset role;
insert into public.blocks(blocker_user_id,blocked_user_id)
 values('da101111-1111-4111-8111-111111111111','da202222-2222-4222-8222-222222222222');
set local request.jwt.claim.sub='da202222-2222-4222-8222-222222222222'; set local role authenticated;
select extensions.is((select count(*) from public.list_server_notification_inbox(null,50)),0::bigint,
 'blocking an event actor immediately hides that actor notification');
reset role;
delete from public.blocks where blocker_user_id='da101111-1111-4111-8111-111111111111'
 and blocked_user_id='da202222-2222-4222-8222-222222222222';
update public.notification_settings set group_updates_enabled=false
 where user_id='da202222-2222-4222-8222-222222222222';
set local request.jwt.claim.sub='da202222-2222-4222-8222-222222222222'; set local role authenticated;
select extensions.is((select count(*) from public.list_server_notification_inbox(null,50)),0::bigint,
 'turning group updates off hides existing group notification rows');
reset role;
update public.notification_settings set group_updates_enabled=true
 where user_id='da202222-2222-4222-8222-222222222222';
select extensions.is((select count(*) from private.notification_outbox where inbox_id in (
  select id from private.notification_inbox where notification_type='group_event_created')),
  (select count(*) from private.notification_inbox where notification_type='group_event_created'),
  'event inbox mutation has matching durable outbox receipt');

with inserted_token as (
  insert into public.device_tokens(user_id,platform,token_hash,token_preview)
  values ('da202222-2222-4222-8222-222222222222','android',
    encode(extensions.digest('private-test-token-012345678901','sha256'),'hex'),'8901')
  returning id
)
insert into private.notification_installation_bindings(
  installation_id,user_id,client_generation,binding_generation,public_token_id,platform,token
)
select 'da818888-8888-4888-8888-888888888888','da202222-2222-4222-8222-222222222222',1,1,
  inserted_token.id,'android','private-test-token-012345678901'
from inserted_token;
select extensions.is((select count(*) from private.notification_delivery_attempts),0::bigint,'delivery attempts are created only by trusted dispatcher claims');
set local request.jwt.claim.role='service_role'; set local role service_role;
create temporary table delivery_claim on commit drop as
select * from public.claim_notification_outbox(10,60);
select extensions.ok((select count(*)>0 from delivery_claim),'dispatcher leases pending deliveries');
select extensions.is((select token from delivery_claim limit 1),
 'private-test-token-012345678901','dispatcher receives only the active generation token through a lease');
select extensions.is(public.finish_notification_delivery(
 (select outbox_id from delivery_claim limit 1),(select delivery_id from delivery_claim limit 1),
 'da909999-9999-4999-8999-999999999999',(select installation_id from delivery_claim limit 1),
 (select binding_generation from delivery_claim limit 1),'sent'),false,'stale lease cannot complete delivery');
select extensions.is(public.finish_notification_delivery(
 (select outbox_id from delivery_claim limit 1),(select delivery_id from delivery_claim limit 1),
 (select lease_id from delivery_claim limit 1),(select installation_id from delivery_claim limit 1),
 (select binding_generation from delivery_claim limit 1),'sent','synthetic-provider-id'),true,
 'current lease records provider completion');
reset role;
update private.notification_delivery_attempts set status='pending',available_at=clock_timestamp(),
  lease_id=null,lease_expires_at=null where status='leased';
update private.notification_installation_bindings set client_generation=2,
  binding_generation=2,token='private-test-token-rotated-0002',updated_at=clock_timestamp()
  where installation_id='da818888-8888-4888-8888-888888888888';
set local request.jwt.claim.role='service_role'; set local role service_role;
create temporary table delivery_claim_generation_two on commit drop as
select * from public.claim_notification_outbox(10,60);
select extensions.ok((select count(*)>0 from delivery_claim_generation_two
  where binding_generation=2),'dispatcher claims only the current token generation');
reset role;
select extensions.ok((select count(*)>0 from private.notification_delivery_attempts
  where installation_id='da818888-8888-4888-8888-888888888888'
    and binding_generation=1 and status='permanent_failure'),
  'obsolete token-generation attempts become terminal');
update private.notification_delivery_attempts set status='pending',available_at=clock_timestamp(),
  lease_id=null,lease_expires_at=null where status='leased';
update public.notification_settings set group_updates_enabled=false
  where user_id='da202222-2222-4222-8222-222222222222';
set local request.jwt.claim.role='service_role'; set local role service_role;
create temporary table delivery_claim_preferences_off on commit drop as
select * from public.claim_notification_outbox(10,60);
select extensions.is((select count(*) from delivery_claim_preferences_off),0::bigint,
 'dispatcher stops delivery after group notifications are disabled');
reset role;
select extensions.ok((select count(*)=0 from private.notification_delivery_attempts
  where status in ('pending','leased')),'ineligible delivery attempts do not occupy the queue');
update public.notification_settings set group_updates_enabled=true
  where user_id='da202222-2222-4222-8222-222222222222';

set local request.jwt.claim.sub='da202222-2222-4222-8222-222222222222'; set local role authenticated;
select extensions.is((select count(*) from public.list_server_notification_inbox(null,50)),2::bigint,'recipient sees only current active membership inbox rows');
reset role;
set local request.jwt.claim.sub='da404444-4444-4444-8444-444444444444'; set local role authenticated;
select extensions.is((select count(*) from public.list_server_notification_inbox(null,50)),0::bigint,'removed member inbox is immediately hidden');
reset role;

set local request.jwt.claim.sub='da101111-1111-4111-8111-111111111111'; set local role authenticated;
create temporary table created_invitation on commit drop as
select invitation_id,status from public.create_targeted_group_invitation(
 'da606666-6666-4666-8666-666666666666','da505555-5555-4555-8555-555555555555',clock_timestamp()+interval '1 day');
select extensions.is((select status from created_invitation),
 'pending','friend receives explicit targeted invitation rather than bearer link');
reset role;
select extensions.is((select count(*) from public.group_members where group_id='da606666-6666-4666-8666-666666666666' and user_id='da505555-5555-4555-8555-555555555555'),0::bigint,'invitation creation does not auto-join the friend');
select extensions.is((select count(*) from private.notification_inbox where recipient_user_id='da505555-5555-4555-8555-555555555555' and notification_type='group_invitation'),1::bigint,'targeted invite and notification are atomic');
set local request.jwt.claim.sub='da505555-5555-4555-8555-555555555555'; set local role authenticated;
select extensions.is((select count(*) from public.list_my_targeted_group_invitations()),1::bigint,'only invitee can list pending targeted invitation');
reset role;
with inserted_token as (
  insert into public.device_tokens(user_id,platform,token_hash,token_preview)
  values ('da505555-5555-4555-8555-555555555555','android',
    encode(extensions.digest('private-invite-test-token-012345','sha256'),'hex'),'2345')
  returning id
)
insert into private.notification_installation_bindings(
  installation_id,user_id,client_generation,binding_generation,public_token_id,platform,token
)
select 'da828888-8888-4888-8888-888888888888','da505555-5555-4555-8555-555555555555',1,1,
  inserted_token.id,'android','private-invite-test-token-012345'
from inserted_token;
insert into public.notification_settings(user_id,group_updates_enabled)
values ('da505555-5555-4555-8555-555555555555',false)
on conflict(user_id) do update set group_updates_enabled=false;
set local request.jwt.claim.role='service_role'; set local role service_role;
create temporary table invite_delivery_preferences_off on commit drop as
select * from public.claim_notification_outbox(10,60);
select extensions.is((select count(*) from invite_delivery_preferences_off),0::bigint,
 'dispatcher does not send targeted invitations after recipient disables notifications');
reset role;
set local request.jwt.claim.sub='da505555-5555-4555-8555-555555555555'; set local role authenticated;
select extensions.is((select count(*) from public.list_server_notification_inbox(null,50)
 where notification_type='group_invitation'),1::bigint,
 'targeted invitation remains available in the product inbox when push is disabled');
reset role;
update public.notification_settings set group_updates_enabled=true
 where user_id='da505555-5555-4555-8555-555555555555';
insert into public.blocks(blocker_user_id,blocked_user_id)
 values('da505555-5555-4555-8555-555555555555','da101111-1111-4111-8111-111111111111');
set local request.jwt.claim.sub='da505555-5555-4555-8555-555555555555'; set local role authenticated;
select extensions.is((select count(*) from public.list_my_targeted_group_invitations()),0::bigint,
 'blocking an inviter hides and disables their pending targeted invitation');
select extensions.throws_ok($$select * from public.respond_targeted_group_invitation(
 (select invitation_id from created_invitation),true)$$,
 '42501','invitation unavailable','a blocked invitee cannot accept the targeted invitation');
reset role;
delete from public.blocks where blocker_user_id='da505555-5555-4555-8555-555555555555'
 and blocked_user_id='da101111-1111-4111-8111-111111111111';
set local request.jwt.claim.sub='da505555-5555-4555-8555-555555555555'; set local role authenticated;
select extensions.is((select invitation_id from created_invitation),
 (select invitation_id from public.list_my_targeted_group_invitations()),
 'creation returns the invitation identifier rather than the inbox identifier');
create temp table invite_fixture on commit drop as select invitation_id from public.list_my_targeted_group_invitations();
select extensions.is((select status from public.respond_targeted_group_invitation((select invitation_id from invite_fixture),true)),'accepted','recipient explicitly accepts invitation');
select extensions.is((select status from public.respond_targeted_group_invitation((select invitation_id from invite_fixture),true)),'accepted','accept replay returns the prior result');
reset role;
select extensions.is((select count(*) from public.group_members where group_id='da606666-6666-4666-8666-666666666666' and user_id='da505555-5555-4555-8555-555555555555'),1::bigint,'membership begins only after acceptance');
select * from extensions.finish();
rollback;
