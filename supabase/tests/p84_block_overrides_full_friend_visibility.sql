begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(7);

-- A block outranks accepted friendship and FULL event/friend visibility.
-- All rows are synthetic and the transaction is rolled back.
insert into auth.users(id) values
 ('8b845200-8400-4200-8400-000000000001'),
 ('8b845200-8400-4200-8400-000000000002');
insert into public.profiles(user_id,display_name,default_visibility) values
 ('8b845200-8400-4200-8400-000000000001','P84 block precedence owner','PRIVATE'),
 ('8b845200-8400-4200-8400-000000000002','P84 block precedence friend','PRIVATE')
on conflict(user_id) do update set
 display_name=excluded.display_name,
 default_visibility=excluded.default_visibility;
insert into public.friendships(id,requester_user_id,addressee_user_id,status,incarnation)
values ('8a845200-8400-4200-8400-000000000001',
 '8b845200-8400-4200-8400-000000000001',
 '8b845200-8400-4200-8400-000000000002','accepted',
 '8a845200-8400-4200-8400-000000000002');
insert into public.friend_visibility_rules(
 friendship_id,relationship_incarnation,owner_user_id,friend_user_id,
 target_kind,target_id,target_value,mode,visibility_level
) values (
 '8a845200-8400-4200-8400-000000000001',
 '8a845200-8400-4200-8400-000000000002',
 '8b845200-8400-4200-8400-000000000001',
 '8b845200-8400-4200-8400-000000000002',
 'default',null,null,'explicit','FULL'
);
insert into public.calendars(id,owner_user_id,name,default_visibility)
values ('8d845200-8400-4200-8400-000000000001',
 '8b845200-8400-4200-8400-000000000001','P84 blocked FULL calendar','PRIVATE');
insert into public.events(id,owner_user_id,calendar_id,title,kind,start_at,end_at,
 location,description,visibility_level,created_by) values
 ('8e845200-8400-4200-8400-000000000001',
  '8b845200-8400-4200-8400-000000000001',
  '8d845200-8400-4200-8400-000000000001',
  'P84 blocked FULL event canary','normal','2030-10-08 01:00+00','2030-10-08 02:00+00',
  'P84 blocked location canary','P84 blocked description canary','FULL',
  '8b845200-8400-4200-8400-000000000001');

set local request.jwt.claim.sub='8b845200-8400-4200-8400-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is((public.preview_friend_schedule(
 '8b845200-8400-4200-8400-000000000002',null,
 '2030-10-08 00:00+00','2030-10-09 00:00+00')->>'allowed'),'true',
 'accepted friendship and FULL rule allow the positive control before blocking');
select extensions.is(jsonb_array_length(public.preview_friend_schedule(
 '8b845200-8400-4200-8400-000000000002',null,
 '2030-10-08 00:00+00','2030-10-09 00:00+00')->'rows'->'items'),1,
 'the FULL event is present in the pre-block friend preview');
reset role;
set local request.jwt.claim.sub='8b845200-8400-4200-8400-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is((select count(*)::integer from public.get_visible_events(
 '8b845200-8400-4200-8400-000000000002',
 '2030-10-08 00:00+00','2030-10-09 00:00+00')
 where event_id='8e845200-8400-4200-8400-000000000001'),1,
 'the FULL event is visible through the direct event projection before blocking');

reset role;
set local request.jwt.claim.sub='8b845200-8400-4200-8400-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is((public.block_user(
 '8b845200-8400-4200-8400-000000000002',
 '8f845200-8400-4200-8400-000000000001')->>'blocked'),'true',
 'the schedule owner blocks the accepted friend');

select extensions.is((public.preview_friend_schedule(
 '8b845200-8400-4200-8400-000000000002',null,
 '2030-10-08 00:00+00','2030-10-09 00:00+00')->>'allowed'),'false',
 'block takes precedence over accepted friendship and FULL rule');
select extensions.is(jsonb_array_length(public.preview_friend_schedule(
 '8b845200-8400-4200-8400-000000000002',null,
 '2030-10-08 00:00+00','2030-10-09 00:00+00')->'rows'->'items'),0,
 'blocked friend preview contains no event or identifying canary');
reset role;
set local request.jwt.claim.sub='8b845200-8400-4200-8400-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is((select count(*)::integer from public.get_visible_events(
 '8b845200-8400-4200-8400-000000000002',
 '2030-10-08 00:00+00','2030-10-09 00:00+00')
 where event_id='8e845200-8400-4200-8400-000000000001'),0,
 'block removes the FULL event from the direct event projection');

reset role;
select * from extensions.finish();
rollback;
