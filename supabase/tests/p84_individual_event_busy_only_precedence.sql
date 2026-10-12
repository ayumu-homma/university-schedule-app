begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(5);

-- §29: event-specific BUSY_ONLY has priority over broader FULL permissions.
insert into auth.users(id) values
 ('8c846500-8400-4500-8400-000000000001'),
 ('8c846500-8400-4500-8400-000000000002');
insert into public.profiles(user_id,display_name,default_visibility) values
 ('8c846500-8400-4500-8400-000000000001','P84 BUSY event owner','FULL'),
 ('8c846500-8400-4500-8400-000000000002','P84 BUSY event friend','PRIVATE')
on conflict(user_id) do update set
 display_name=excluded.display_name,
 default_visibility=excluded.default_visibility;
insert into public.friendships(id,requester_user_id,addressee_user_id,status,incarnation)
values ('8a846500-8400-4500-8400-000000000001',
 '8c846500-8400-4500-8400-000000000001',
 '8c846500-8400-4500-8400-000000000002','accepted',
 '8a846500-8400-4500-8400-000000000002');
insert into public.friend_visibility_rules(
 friendship_id,relationship_incarnation,owner_user_id,friend_user_id,
 target_kind,target_id,target_value,mode,visibility_level
) values (
 '8a846500-8400-4500-8400-000000000001',
 '8a846500-8400-4500-8400-000000000002',
 '8c846500-8400-4500-8400-000000000001',
 '8c846500-8400-4500-8400-000000000002',
 'default',null,null,'explicit','FULL'
);
insert into public.calendars(id,owner_user_id,name,default_visibility)
values ('8d846500-8400-4500-8400-000000000001',
 '8c846500-8400-4500-8400-000000000001','P84 BUSY event calendar','FULL');
insert into public.events(id,owner_user_id,calendar_id,title,kind,start_at,end_at,
 location,description,visibility_level,created_by) values
 ('8e846500-8400-4500-8400-000000000001',
  '8c846500-8400-4500-8400-000000000001',
  '8d846500-8400-4500-8400-000000000001',
  'P84 BUSY event title canary','normal','2030-11-09 01:00+00','2030-11-09 02:00+00',
  'P84 BUSY event location canary','P84 BUSY event description canary','FULL',
  '8c846500-8400-4500-8400-000000000001');

set local request.jwt.claim.sub='8c846500-8400-4500-8400-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is(
 (select count(*)::integer from jsonb_array_elements(public.get_friend_schedule(
  '8c846500-8400-4500-8400-000000000001',null,
  '2030-11-09 00:00+00','2030-11-10 00:00+00')->'rows'->'items') item
  where item->>'title'='P84 BUSY event title canary'),
 1,'owner and friendship FULL controls reveal the positive event before restriction');

reset role;
set local request.jwt.claim.sub='8c846500-8400-4500-8400-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.ok(
 (public.set_friend_visibility(
  '8a846500-8400-4500-8400-000000000001',
  '8a846500-8400-4500-8400-000000000002',
  '8c846500-8400-4500-8400-000000000002','event',
  '8e846500-8400-4500-8400-000000000001','BUSY_ONLY',null,
  '8f846500-8400-4500-8400-000000000001',null
 )->>'revision') is not null,
 'owner sets event-specific BUSY_ONLY');

reset role;
set local request.jwt.claim.sub='8c846500-8400-4500-8400-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.ok(
 (select count(*)=1 and bool_and(item->>'visibility_level'='BUSY_ONLY'
   and item->>'title'='予定あり'
   and item->>'location' is null and item->>'description' is null)
  from jsonb_array_elements(public.get_friend_schedule(
   '8c846500-8400-4500-8400-000000000001',null,
   '2030-11-09 00:00+00','2030-11-10 00:00+00')->'rows'->'items') item),
 'friend schedule preserves the time-only BUSY_ONLY projection');
select extensions.is(
 (select count(*)::integer from public.get_visible_events(
  '8c846500-8400-4500-8400-000000000002',
  '2030-11-09 00:00+00','2030-11-10 00:00+00')
  where event_id='8e846500-8400-4500-8400-000000000001'
   and visibility_level='BUSY_ONLY' and title='予定あり'
   and location is null and description is null),
 1,'direct visibility projection applies the same BUSY_ONLY cap');
select extensions.ok(
 position('P84 BUSY event title canary' in public.get_friend_schedule(
  '8c846500-8400-4500-8400-000000000001',null,
  '2030-11-09 00:00+00','2030-11-10 00:00+00')::text)=0
 and position('P84 BUSY event location canary' in coalesce((
  select jsonb_agg(to_jsonb(projection))::text from public.get_visible_events(
   '8c846500-8400-4500-8400-000000000002',
   '2030-11-09 00:00+00','2030-11-10 00:00+00') projection),''))=0
 and position('P84 BUSY event description canary' in public.get_friend_schedule(
  '8c846500-8400-4500-8400-000000000001',null,
  '2030-11-09 00:00+00','2030-11-10 00:00+00')::text)=0,
 'restricted projections contain no event title, location, or description canaries');

reset role;
select * from extensions.finish();
rollback;
