begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(4);

-- The owner's event-target TITLE_ONLY rule must outrank the relationship
-- default FULL rule while retaining only title and time.
insert into auth.users(id) values
 ('8c997300-9900-4700-9900-000000000001'),
 ('8c997300-9900-4700-9900-000000000002');
insert into public.profiles(user_id,display_name,default_visibility) values
 ('8c997300-9900-4700-9900-000000000001','P102 event owner','PRIVATE'),
 ('8c997300-9900-4700-9900-000000000002','P102 event friend','PRIVATE')
on conflict(user_id) do update set display_name=excluded.display_name;
insert into public.friendships(id,requester_user_id,addressee_user_id,status,incarnation)
values ('8a997300-9900-4700-9900-000000000001',
 '8c997300-9900-4700-9900-000000000001',
 '8c997300-9900-4700-9900-000000000002','accepted',
 '8a997300-9900-4700-9900-000000000002');
insert into public.friend_visibility_rules(
 friendship_id,relationship_incarnation,owner_user_id,friend_user_id,
 target_kind,target_id,target_value,mode,visibility_level
) values (
 '8a997300-9900-4700-9900-000000000001',
 '8a997300-9900-4700-9900-000000000002',
 '8c997300-9900-4700-9900-000000000001',
 '8c997300-9900-4700-9900-000000000002',
 'default',null,null,'explicit','FULL');
insert into public.calendars(id,owner_user_id,name,default_visibility)
values ('8d997300-9900-4700-9900-000000000001',
 '8c997300-9900-4700-9900-000000000001','P102 event calendar','FULL');
insert into public.events(id,owner_user_id,calendar_id,title,kind,start_at,end_at,
 location,description,visibility_level,created_by) values
 ('8e997300-9900-4700-9900-000000000001',
  '8c997300-9900-4700-9900-000000000001',
  '8d997300-9900-4700-9900-000000000001',
  'P102 title-only title canary','normal','2031-06-02 01:00+00','2031-06-02 02:00+00',
  'P102 private location canary','P102 private description canary','FULL',
  '8c997300-9900-4700-9900-000000000001');

set local request.jwt.claim.sub='8c997300-9900-4700-9900-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.ok(exists(select 1 from public.get_visible_events(
 '8c997300-9900-4700-9900-000000000002',
 '2031-06-02 00:00+00','2031-06-03 00:00+00')
 where event_id='8e997300-9900-4700-9900-000000000001'
  and visibility_level='FULL' and title='P102 title-only title canary'
  and location='P102 private location canary'
  and description='P102 private description canary'),
 'relationship FULL is the positive baseline');

reset role;
set local request.jwt.claim.sub='8c997300-9900-4700-9900-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.ok((public.set_friend_visibility(
 '8a997300-9900-4700-9900-000000000001',
 '8a997300-9900-4700-9900-000000000002',
 '8c997300-9900-4700-9900-000000000002','event',
 '8e997300-9900-4700-9900-000000000001','TITLE_ONLY',null,
 '8f997300-9900-4700-9900-000000000001',null
 )->>'revision') is not null,
 'owner writes the more-specific TITLE_ONLY rule for this friend and event');

reset role;
set local request.jwt.claim.sub='8c997300-9900-4700-9900-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.ok(exists(select 1 from public.get_visible_events(
 '8c997300-9900-4700-9900-000000000002',
 '2031-06-02 00:00+00','2031-06-03 00:00+00')
 where event_id='8e997300-9900-4700-9900-000000000001'
  and visibility_level='TITLE_ONLY'
  and title='P102 title-only title canary'
  and location is null and description is null and group_id is null),
 'event-specific TITLE_ONLY retains the title but removes private fields');
select extensions.ok(
 position('P102 private location canary' in coalesce((select jsonb_agg(to_jsonb(projection))::text
  from public.get_visible_events('8c997300-9900-4700-9900-000000000002',
   '2031-06-02 00:00+00','2031-06-03 00:00+00') projection),''))=0
 and position('P102 private description canary' in coalesce((select jsonb_agg(to_jsonb(projection))::text
  from public.get_visible_events('8c997300-9900-4700-9900-000000000002',
   '2031-06-02 00:00+00','2031-06-03 00:00+00') projection),''))=0,
 'response serialization contains neither private canary');
reset role;
select * from extensions.finish();
rollback;
