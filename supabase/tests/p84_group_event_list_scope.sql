begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(7);

insert into auth.users(id) values
 ('8b842000-8400-4200-8400-000000000001'),
 ('8b842000-8400-4200-8400-000000000002'),
 ('8b842000-8400-4200-8400-000000000003')
on conflict(id) do nothing;
insert into public.profiles(user_id,display_name,default_visibility) values
 ('8b842000-8400-4200-8400-000000000001','P84 list owner','PRIVATE'),
 ('8b842000-8400-4200-8400-000000000002','P84 list member','PRIVATE'),
 ('8b842000-8400-4200-8400-000000000003','P84 list outsider','PRIVATE')
on conflict(user_id) do update set display_name=excluded.display_name,
 default_visibility=excluded.default_visibility;
insert into public.groups(id,owner_user_id,name,type,default_visibility,event_create_policy)
values ('8c842000-8400-4200-8400-000000000001',
 '8b842000-8400-4200-8400-000000000001','P84 list scope','other','FULL','member');
insert into public.group_members(group_id,user_id,role,visibility_level) values
 ('8c842000-8400-4200-8400-000000000001','8b842000-8400-4200-8400-000000000001','owner',null),
 ('8c842000-8400-4200-8400-000000000001','8b842000-8400-4200-8400-000000000002','member',null);
insert into public.calendars(id,owner_user_id,group_id,name,default_visibility)
values ('8d842000-8400-4200-8400-000000000001','8b842000-8400-4200-8400-000000000001',
 '8c842000-8400-4200-8400-000000000001','P84 list calendar','PRIVATE');
set local session_replication_role='replica';
insert into public.events(id,owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,
 location,description,visibility_level,created_by,moderation_hidden_at) values
 ('8e842000-8400-4200-8400-000000000001','8b842000-8400-4200-8400-000000000001',
 '8d842000-8400-4200-8400-000000000001','8c842000-8400-4200-8400-000000000001',
 'Member-visible group event','group','2030-10-02 01:00+00','2030-10-02 02:00+00',
 'P84 member room','P84 member notes','FULL','8b842000-8400-4200-8400-000000000001',null),
 ('8e842000-8400-4200-8400-000000000002','8b842000-8400-4200-8400-000000000001',
 '8d842000-8400-4200-8400-000000000001','8c842000-8400-4200-8400-000000000001',
 'Moderation-hidden canary','group','2030-10-02 03:00+00','2030-10-02 04:00+00',
 'P84 hidden room','P84 hidden notes','FULL','8b842000-8400-4200-8400-000000000001','2030-01-01 00:00+00');
set local session_replication_role='origin';

select extensions.ok(not has_function_privilege('anon','public.list_group_events(uuid)','execute'),
 'anon cannot execute group event list');
select extensions.ok(not has_function_privilege('public','public.list_group_events(uuid)','execute'),
 'PUBLIC cannot execute group event list');
select extensions.ok(has_function_privilege('authenticated','public.list_group_events(uuid)','execute'),
 'authenticated role can execute group event list');
set local request.jwt.claim.sub='8b842000-8400-4200-8400-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is((select count(*)::integer from public.list_group_events(
 '8c842000-8400-4200-8400-000000000001')),1,
 'active group member sees only the current visible event');
select extensions.ok((select title='Member-visible group event' and location='P84 member room'
 and description='P84 member notes' from public.list_group_events(
 '8c842000-8400-4200-8400-000000000001')),
 'member list returns the group event details');
select extensions.is((select count(*)::integer from public.list_group_events(
 '8c842000-8400-4200-8400-000000000001') where title='Moderation-hidden canary'
 or location='P84 hidden room' or description='P84 hidden notes'),0,
 'moderation-hidden event and canaries are excluded from list');
set local request.jwt.claim.sub='8b842000-8400-4200-8400-000000000003';
select extensions.throws_ok($q$select count(*) from public.list_group_events(
 '8c842000-8400-4200-8400-000000000001')$q$,
 '42501','group access denied','nonmember cannot list group events');
reset role;
select * from extensions.finish();
rollback;
