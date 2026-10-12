begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(4);

-- An owner-issued per-friend event rule is more specific than that
-- relationship's default rule. This complements (and does not repeat) the
-- accepted PRIVATE/BUSY_ONLY event-rule cases.
insert into auth.users(id) values
 ('8c997200-9900-4700-9900-000000000001'),
 ('8c997200-9900-4700-9900-000000000002');
insert into public.profiles(user_id,display_name,default_visibility) values
 ('8c997200-9900-4700-9900-000000000001','P101 event owner','PRIVATE'),
 ('8c997200-9900-4700-9900-000000000002','P101 event friend','PRIVATE')
on conflict(user_id) do update set display_name=excluded.display_name;
insert into public.friendships(id,requester_user_id,addressee_user_id,status,incarnation)
values ('8a997200-9900-4700-9900-000000000001',
 '8c997200-9900-4700-9900-000000000001',
 '8c997200-9900-4700-9900-000000000002','accepted',
 '8a997200-9900-4700-9900-000000000002');
insert into public.friend_visibility_rules(
 friendship_id,relationship_incarnation,owner_user_id,friend_user_id,
 target_kind,target_id,target_value,mode,visibility_level
) values (
 '8a997200-9900-4700-9900-000000000001',
 '8a997200-9900-4700-9900-000000000002',
 '8c997200-9900-4700-9900-000000000001',
 '8c997200-9900-4700-9900-000000000002',
 'default',null,null,'explicit','BUSY_ONLY');
insert into public.calendars(id,owner_user_id,name,default_visibility)
values ('8d997200-9900-4700-9900-000000000001',
 '8c997200-9900-4700-9900-000000000001','P101 event calendar','PRIVATE');
insert into public.events(id,owner_user_id,calendar_id,title,kind,start_at,end_at,
 location,description,visibility_level,created_by) values
 ('8e997200-9900-4700-9900-000000000001',
  '8c997200-9900-4700-9900-000000000001',
  '8d997200-9900-4700-9900-000000000001',
  'P101 event title canary','normal','2031-06-01 01:00+00','2031-06-01 02:00+00',
  'P101 event location canary','P101 event description canary','FULL',
  '8c997200-9900-4700-9900-000000000001');

set local request.jwt.claim.sub='8c997200-9900-4700-9900-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.ok(exists(select 1 from public.get_visible_events(
 '8c997200-9900-4700-9900-000000000002',
 '2031-06-01 00:00+00','2031-06-02 00:00+00')
 where event_id='8e997200-9900-4700-9900-000000000001'
  and visibility_level='BUSY_ONLY' and title='予定あり'
  and location is null and description is null),
 'relationship default BUSY_ONLY is the pre-override baseline');

reset role;
set local request.jwt.claim.sub='8c997200-9900-4700-9900-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.ok((public.set_friend_visibility(
 '8a997200-9900-4700-9900-000000000001',
 '8a997200-9900-4700-9900-000000000002',
 '8c997200-9900-4700-9900-000000000002','event',
 '8e997200-9900-4700-9900-000000000001','FULL',null,
 '8f997200-9900-4700-9900-000000000001',null
 )->>'revision') is not null,
 'owner writes the more-specific FULL rule for this friend and event');

reset role;
set local request.jwt.claim.sub='8c997200-9900-4700-9900-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.ok(exists(select 1 from public.get_visible_events(
 '8c997200-9900-4700-9900-000000000002',
 '2031-06-01 00:00+00','2031-06-02 00:00+00')
 where event_id='8e997200-9900-4700-9900-000000000001'
  and visibility_level='FULL'
  and title='P101 event title canary'
  and location='P101 event location canary'
  and description='P101 event description canary'),
 'specific event FULL replaces only the broader BUSY_ONLY rule');
select extensions.is((select count(*)::integer from public.get_visible_events(
 '8c997200-9900-4700-9900-000000000002',
 '2031-06-01 00:00+00','2031-06-02 00:00+00')
 where event_id='8e997200-9900-4700-9900-000000000001'),
 1,'only the single synthetic event is returned');
reset role;
select * from extensions.finish();
rollback;
