begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(4);

-- A friendship must not grant access to an event scoped to a group the viewer
-- has not joined. Keep all fixtures synthetic and roll the transaction back.
insert into auth.users(id) values
 ('8b843000-8400-4200-8400-000000000001'),
 ('8b843000-8400-4200-8400-000000000002'),
 ('8b843000-8400-4200-8400-000000000003');
insert into public.profiles(user_id,display_name,default_visibility) values
 ('8b843000-8400-4200-8400-000000000001','P84 group owner','PRIVATE'),
 ('8b843000-8400-4200-8400-000000000002','P84 group member','PRIVATE'),
 ('8b843000-8400-4200-8400-000000000003','P84 owner friend outside group','PRIVATE')
on conflict(user_id) do update set display_name=excluded.display_name,
 default_visibility=excluded.default_visibility;
insert into public.friendships(requester_user_id,addressee_user_id,status)
values ('8b843000-8400-4200-8400-000000000001',
        '8b843000-8400-4200-8400-000000000003','accepted');
insert into public.groups(id,owner_user_id,name,type,default_visibility,event_create_policy)
values ('8c843000-8400-4200-8400-000000000001',
 '8b843000-8400-4200-8400-000000000001','P84 friend scope','other','FULL','member');
insert into public.group_members(group_id,user_id,role,visibility_level) values
 ('8c843000-8400-4200-8400-000000000001','8b843000-8400-4200-8400-000000000001','owner',null),
 ('8c843000-8400-4200-8400-000000000001','8b843000-8400-4200-8400-000000000002','member',null);
insert into public.calendars(id,owner_user_id,group_id,name,default_visibility)
values ('8d843000-8400-4200-8400-000000000001',
 '8b843000-8400-4200-8400-000000000001','8c843000-8400-4200-8400-000000000001',
 'P84 group calendar','FULL');
set local session_replication_role='replica';
insert into public.events(id,owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,
 location,description,visibility_level,created_by) values
 ('8e843000-8400-4200-8400-000000000001','8b843000-8400-4200-8400-000000000001',
  '8d843000-8400-4200-8400-000000000001','8c843000-8400-4200-8400-000000000001',
  'Member-only group event','group','2030-10-03 01:00+00','2030-10-03 02:00+00',
  'Synthetic room','Synthetic notes','FULL','8b843000-8400-4200-8400-000000000001');
set local session_replication_role='origin';

set local request.jwt.claim.sub='8b843000-8400-4200-8400-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is((select count(*)::integer from public.get_visible_events(
 '8b843000-8400-4200-8400-000000000002','2030-10-03 00:00+00','2030-10-04 00:00+00')
 where event_id='8e843000-8400-4200-8400-000000000001'),1,
 'group member is a positive control for visible group events');
select extensions.is((select count(*)::integer from public.list_group_events(
 '8c843000-8400-4200-8400-000000000001')),1,
 'group member is a positive control for the group event list');

set local request.jwt.claim.sub='8b843000-8400-4200-8400-000000000003';
select extensions.is((select count(*)::integer from public.get_visible_events(
 '8b843000-8400-4200-8400-000000000003','2030-10-03 00:00+00','2030-10-04 00:00+00')
 where event_id='8e843000-8400-4200-8400-000000000001'),0,
 'friendship with the owner does not expose a group event to a nonmember');
select extensions.throws_ok($q$select count(*) from public.list_group_events(
 '8c843000-8400-4200-8400-000000000001')$q$,
 '42501','group access denied',
 'friendship with the owner does not authorize group event listing');
reset role;
select * from extensions.finish();
rollback;
