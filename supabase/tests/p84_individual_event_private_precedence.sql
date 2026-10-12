begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(4);

-- Synthetic owner/friend pair; individual PRIVATE must cap all broader FULL grants.
insert into auth.users(id) values
 ('8c845300-8400-4300-8400-000000000001'),
 ('8c845300-8400-4300-8400-000000000002');
insert into public.profiles(user_id,display_name,default_visibility) values
 ('8c845300-8400-4300-8400-000000000001','P84 private event owner','FULL'),
 ('8c845300-8400-4300-8400-000000000002','P84 private event friend','PRIVATE')
on conflict(user_id) do update set
 display_name=excluded.display_name,
 default_visibility=excluded.default_visibility;
insert into public.friendships(id,requester_user_id,addressee_user_id,status,incarnation)
values ('8a845300-8400-4300-8400-000000000001',
 '8c845300-8400-4300-8400-000000000001',
 '8c845300-8400-4300-8400-000000000002','accepted',
 '8a845300-8400-4300-8400-000000000002');
insert into public.friend_visibility_rules(
 friendship_id,relationship_incarnation,owner_user_id,friend_user_id,
 target_kind,target_id,target_value,mode,visibility_level
) values (
 '8a845300-8400-4300-8400-000000000001',
 '8a845300-8400-4300-8400-000000000002',
 '8c845300-8400-4300-8400-000000000001',
 '8c845300-8400-4300-8400-000000000002',
 'default',null,null,'explicit','FULL'
);
insert into public.calendars(id,owner_user_id,name,default_visibility)
values ('8d845300-8400-4300-8400-000000000001',
 '8c845300-8400-4300-8400-000000000001','P84 private event calendar','FULL');
insert into public.events(id,owner_user_id,calendar_id,title,kind,start_at,end_at,
 location,description,visibility_level,created_by) values
 ('8e845300-8400-4300-8400-000000000001',
  '8c845300-8400-4300-8400-000000000001',
  '8d845300-8400-4300-8400-000000000001',
  'P84 PRIVATE event title canary','normal','2030-11-08 01:00+00','2030-11-08 02:00+00',
  'P84 PRIVATE location canary','P84 PRIVATE description canary','FULL',
  '8c845300-8400-4300-8400-000000000001');

set local request.jwt.claim.sub='8c845300-8400-4300-8400-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is(
 (select count(*)::integer from jsonb_array_elements(public.get_friend_schedule(
  '8c845300-8400-4300-8400-000000000001',null,
  '2030-11-08 00:00+00','2030-11-09 00:00+00')->'rows'->'items') item
  where item->>'title'='P84 PRIVATE event title canary'),
 1,'broader FULL defaults expose the event before an item-specific restriction');

reset role;
set local request.jwt.claim.sub='8c845300-8400-4300-8400-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.ok(
 (public.set_friend_visibility(
  '8a845300-8400-4300-8400-000000000001',
  '8a845300-8400-4300-8400-000000000002',
  '8c845300-8400-4300-8400-000000000002','event',
  '8e845300-8400-4300-8400-000000000001','PRIVATE',null,
  '8f845300-8400-4300-8400-000000000001',null
 )->>'revision') is not null,
 'owner sets explicit PRIVATE for the specific event');

reset role;
set local request.jwt.claim.sub='8c845300-8400-4300-8400-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is(
 jsonb_array_length(public.get_friend_schedule(
  '8c845300-8400-4300-8400-000000000001',null,
  '2030-11-08 00:00+00','2030-11-09 00:00+00')->'rows'->'items'),
 0,'event-specific PRIVATE overrides owner, calendar, and friend FULL values');
select extensions.ok(
 position('P84 PRIVATE event title canary' in public.get_friend_schedule(
  '8c845300-8400-4300-8400-000000000001',null,
  '2030-11-08 00:00+00','2030-11-09 00:00+00')::text)=0
 and position('P84 PRIVATE location canary' in public.get_friend_schedule(
  '8c845300-8400-4300-8400-000000000001',null,
  '2030-11-08 00:00+00','2030-11-09 00:00+00')::text)=0
 and position('P84 PRIVATE description canary' in public.get_friend_schedule(
  '8c845300-8400-4300-8400-000000000001',null,
  '2030-11-08 00:00+00','2030-11-09 00:00+00')::text)=0,
 'restricted response contains no event title, location, or description canary');

reset role;
select * from extensions.finish();
rollback;
