begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(12);

select gen_random_uuid() as actor \gset
select gen_random_uuid() as recipient \gset
select gen_random_uuid() as group_id \gset
select gen_random_uuid() as event_operation \gset
select gen_random_uuid() as installation_id \gset
select gen_random_uuid() as second_installation_id \gset

insert into auth.users(id) values (:'actor'), (:'recipient');
insert into public.profiles(user_id,display_name) values
 (:'actor','Synthetic dispatcher actor'),
 (:'recipient','Synthetic dispatcher recipient')
on conflict(user_id) do update set display_name=excluded.display_name;
insert into public.groups(id,owner_user_id,name,type,event_create_policy)
values (:'group_id',:'actor','Synthetic dispatcher group','other','member');
insert into public.group_members(group_id,user_id,role) values
 (:'group_id',:'actor','owner'), (:'group_id',:'recipient','member');
insert into public.notification_settings(user_id,group_updates_enabled)
values (:'recipient',true)
on conflict(user_id) do update set group_updates_enabled=true;

set local request.jwt.claim.sub=:'actor';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
create temporary table event_fixture on commit drop as
select event_id from public.create_group_event(
 :'group_id','Synthetic retry event',clock_timestamp()+interval '1 hour',
 clock_timestamp()+interval '2 hours','Room','Synthetic details',:'event_operation');

set local request.jwt.claim.sub=:'recipient';
create temporary table registration_fixture on commit drop as
select * from public.register_notification_device(
 :'installation_id',1,'android','synthetic-invalid-token-p84');
create temporary table second_registration_fixture on commit drop as
select * from public.register_notification_device(
 :'second_installation_id',1,'android','synthetic-retry-token-p84');
reset role;

select extensions.is((select count(*) from private.notification_inbox
 where recipient_user_id=:'recipient' and notification_type='group_event_created'),1::bigint,
 'synthetic group event creates one recipient inbox row');
select extensions.is((select count(*) from private.notification_outbox o
 join private.notification_inbox i on i.id=o.inbox_id
 where i.recipient_user_id=:'recipient' and i.notification_type='group_event_created'
   and o.status='pending'),1::bigint,
 'synthetic group event creates one pending durable outbox row');

set local request.jwt.claim.role='service_role';
set local role service_role;
create temporary table claim_one on commit drop as
select * from public.claim_notification_outbox(1,60);
reset role;
select extensions.is((select count(*) from claim_one
 where recipient_user_id=:'recipient'),1::bigint,
 'dispatcher leases the active synthetic installation');
select extensions.ok((select d.status='leased' and d.attempts=1
 from private.notification_delivery_attempts d
 join claim_one c on c.delivery_id=d.id),
 'first claim creates one leased delivery attempt');

set local request.jwt.claim.role='service_role';
set local role service_role;
create temporary table retry_finish on commit drop as
select public.finish_notification_delivery(
 (select outbox_id from claim_one),(select delivery_id from claim_one),
 (select lease_id from claim_one),(select installation_id from claim_one),
 (select binding_generation from claim_one),'retry',null,30,'synthetic_retry') as accepted;
reset role;
select extensions.is((select accepted from retry_finish),true,
 'current retry result is accepted for the matching lease and generation');
select extensions.ok((select d.status='pending' and d.attempts=1
 and d.available_at>transaction_timestamp()+interval '5 seconds'
 and o.status='leased' and o.attempts=1
 from private.notification_delivery_attempts d
 join claim_one c on c.delivery_id=d.id
 join private.notification_outbox o on o.id=d.outbox_id),
 'retry returns the delivery to pending with bounded delay and keeps the outbox leased');

set local request.jwt.claim.role='service_role';
set local role service_role;
create temporary table claim_two on commit drop as
select * from public.claim_notification_outbox(1,60);
reset role;
select extensions.is((select count(*) from claim_two),1::bigint,
 'dispatcher claims another eligible installation while retry delay is pending');
select extensions.ok((select c.delivery_id<>old.delivery_id and d.attempts=1
 from claim_two c join claim_one old on old.outbox_id=c.outbox_id
 join private.notification_delivery_attempts d on d.id=c.delivery_id),
 'second eligible installation has an independent first attempt');

set local request.jwt.claim.role='service_role';
set local role service_role;
create temporary table invalid_finish on commit drop as
select public.finish_notification_delivery(
 (select outbox_id from claim_two),(select delivery_id from claim_two),
 (select lease_id from claim_two),(select installation_id from claim_two),
 (select binding_generation from claim_two),'invalid_token',null,null,'fcm_unregistered') as accepted;
reset role;
select extensions.is((select accepted from invalid_finish),true,
 'invalid-token result is accepted only for the current claim');
select extensions.ok((select d.status='permanent_failure' and d.last_error='fcm_unregistered'
 from private.notification_delivery_attempts d
 join claim_two c on c.delivery_id=d.id
 join private.notification_outbox o on o.id=d.outbox_id),
 'unregistered token makes its delivery attempt terminal');
select extensions.ok((select o.status='leased' and exists(
 select 1 from private.notification_delivery_attempts sibling
 where sibling.outbox_id=o.id and sibling.status='pending')
 from private.notification_outbox o join claim_two c on c.outbox_id=o.id),
 'outbox remains leased while the separate installation retry is pending');
select extensions.ok((select not b.enabled and t.revoked_at is not null
 from private.notification_installation_bindings b
 join public.device_tokens t on t.id=b.public_token_id
 where b.installation_id=(select installation_id from claim_two)),
 'invalid token disables the private binding and revokes its public token row');

select * from extensions.finish();
rollback;
