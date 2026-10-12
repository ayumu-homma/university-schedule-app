begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(2);

-- §29 row: owner BUSY_ONLY + friend FULL => FULL.
-- Event and calendar overrides must be NULL to exercise default inheritance.
insert into auth.users(id) values
 ('8b990000-9900-4900-9900-000000000001'),
 ('8b990000-9900-4900-9900-000000000002');
insert into public.profiles(user_id,display_name,default_visibility) values
 ('8b990000-9900-4900-9900-000000000001','P99 BUSY owner','BUSY_ONLY'),
 ('8b990000-9900-4900-9900-000000000002','P99 FULL friend','PRIVATE')
on conflict(user_id) do update set display_name=excluded.display_name, default_visibility=excluded.default_visibility;
insert into public.friendships(id,requester_user_id,addressee_user_id,status,incarnation)
values ('8a990000-9900-4900-9900-000000000001',
 '8b990000-9900-4900-9900-000000000001',
 '8b990000-9900-4900-9900-000000000002','accepted',
 '8a990000-9900-4900-9900-000000000002');
insert into public.friend_visibility_rules(
 friendship_id,relationship_incarnation,owner_user_id,friend_user_id,
 target_kind,target_id,target_value,mode,visibility_level
) values (
 '8a990000-9900-4900-9900-000000000001',
 '8a990000-9900-4900-9900-000000000002',
 '8b990000-9900-4900-9900-000000000001',
 '8b990000-9900-4900-9900-000000000002',
 'default',null,null,'explicit','FULL');
insert into public.calendars(id,owner_user_id,name,default_visibility)
values ('8d990000-9900-4900-9900-000000000001',
 '8b990000-9900-4900-9900-000000000001','P99 BUSY owner calendar',null);
insert into public.events(id,owner_user_id,calendar_id,title,kind,start_at,end_at,
 location,description,visibility_level,created_by) values
 ('8e990000-9900-4900-9900-000000000001',
  '8b990000-9900-4900-9900-000000000001',
  '8d990000-9900-4900-9900-000000000001',
  'P99 owner BUSY title','normal','2031-06-01 01:00+00','2031-06-01 02:00+00',
  'P99 owner BUSY location','P99 owner BUSY description',null,
  '8b990000-9900-4900-9900-000000000001');

set local request.jwt.claim.sub='8b990000-9900-4900-9900-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is((select visibility_level::text from public.get_visible_events(
 '8b990000-9900-4900-9900-000000000002',
 '2031-06-01 00:00+00','2031-06-02 00:00+00')
 where event_id='8e990000-9900-4900-9900-000000000001'), 'FULL',
 'friend FULL overrides owner BUSY_ONLY for the §29 default grant row');
select extensions.ok(exists(select 1 from public.get_visible_events(
 '8b990000-9900-4900-9900-000000000002',
 '2031-06-01 00:00+00','2031-06-02 00:00+00')
 where event_id='8e990000-9900-4900-9900-000000000001'
  and title='P99 owner BUSY title' and location='P99 owner BUSY location'
  and description='P99 owner BUSY description'),
 'FULL grant exposes the expected details for the §29 row');
reset role;
select * from extensions.finish();
rollback;
