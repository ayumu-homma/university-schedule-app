begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(12);

-- Synthetic group-only viewer with no friendship to the event owner.
insert into auth.users(id) values
  ('8b841200-8400-4200-8400-000000000001'),
  ('8b841200-8400-4200-8400-000000000002'),
  ('8b841200-8400-4200-8400-000000000003');
insert into public.profiles(user_id,display_name,default_visibility) values
  ('8b841200-8400-4200-8400-000000000001','P84 scope owner','PRIVATE'),
  ('8b841200-8400-4200-8400-000000000002','P84 scope member','PRIVATE'),
  ('8b841200-8400-4200-8400-000000000003','P84 scope outsider','PRIVATE')
on conflict(user_id) do update set
  display_name=excluded.display_name,
  default_visibility=excluded.default_visibility;
insert into public.groups(id,owner_user_id,name,type,default_visibility,event_create_policy)
values ('8c841200-8400-4200-8400-000000000001',
        '8b841200-8400-4200-8400-000000000001',
        'P84 synthetic scope','other','TITLE_ONLY','member');
insert into public.group_members(group_id,user_id,role,visibility_level) values
  ('8c841200-8400-4200-8400-000000000001','8b841200-8400-4200-8400-000000000001','owner',null),
  ('8c841200-8400-4200-8400-000000000001','8b841200-8400-4200-8400-000000000002','member',null);
insert into public.calendars(id,owner_user_id,group_id,name,default_visibility)
values ('8d841200-8400-4200-8400-000000000001',
        '8b841200-8400-4200-8400-000000000001',
        '8c841200-8400-4200-8400-000000000001','P84 scope calendar','PRIVATE');

set local session_replication_role='replica';
insert into public.events(id,owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,
                         location,description,visibility_level,created_by) values
  ('8e841200-8400-4200-8400-000000000001','8b841200-8400-4200-8400-000000000001',
   '8d841200-8400-4200-8400-000000000001','8c841200-8400-4200-8400-000000000001',
   'Group title canary','group','2030-10-01 01:00+00','2030-10-01 02:00+00',
   'Title-only room canary','Title-only notes canary','TITLE_ONLY','8b841200-8400-4200-8400-000000000001'),
  ('8e841200-8400-4200-8400-000000000002','8b841200-8400-4200-8400-000000000001',
   '8d841200-8400-4200-8400-000000000001','8c841200-8400-4200-8400-000000000001',
   'Private group canary','group','2030-10-01 03:00+00','2030-10-01 04:00+00',
   'Private room canary','Private notes canary','PRIVATE','8b841200-8400-4200-8400-000000000001'),
  ('8e841200-8400-4200-8400-000000000003','8b841200-8400-4200-8400-000000000001',
   '8d841200-8400-4200-8400-000000000001','8c841200-8400-4200-8400-000000000001',
   'Busy group canary','group','2030-10-01 05:00+00','2030-10-01 06:00+00',
   'Busy room canary','Busy notes canary','BUSY_ONLY','8b841200-8400-4200-8400-000000000001'),
  ('8e841200-8400-4200-8400-000000000004','8b841200-8400-4200-8400-000000000001',
   '8d841200-8400-4200-8400-000000000001','8c841200-8400-4200-8400-000000000001',
   'Full group event','group','2030-10-01 07:00+00','2030-10-01 08:00+00',
   'Full room','Full notes','FULL','8b841200-8400-4200-8400-000000000001');
set local session_replication_role='origin';

set local request.jwt.claim.sub='8b841200-8400-4200-8400-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is((select count(*)::integer from public.get_visible_events(
  '8b841200-8400-4200-8400-000000000002','2030-10-01 00:00+00','2030-10-02 00:00+00')),
  3,'group member without friendship sees only non-private group events');
select extensions.is((select visibility_level::text from public.get_visible_events(
  '8b841200-8400-4200-8400-000000000002','2030-10-01 00:00+00','2030-10-02 00:00+00')
  where event_id='8e841200-8400-4200-8400-000000000001'),'TITLE_ONLY',
  'event-level TITLE_ONLY visibility is preserved in group scope');
select extensions.is((select title from public.get_visible_events(
  '8b841200-8400-4200-8400-000000000002','2030-10-01 00:00+00','2030-10-02 00:00+00')
  where event_id='8e841200-8400-4200-8400-000000000001'),'Group title canary',
  'TITLE_ONLY group projection includes the title');
select extensions.ok((select start_at='2030-10-01 01:00+00'::timestamptz
  and end_at='2030-10-01 02:00+00'::timestamptz
  from public.get_visible_events('8b841200-8400-4200-8400-000000000002',
    '2030-10-01 00:00+00','2030-10-02 00:00+00')
  where event_id='8e841200-8400-4200-8400-000000000001'),
  'TITLE_ONLY group projection retains only the interval among schedule details');
select extensions.ok((select location is null and description is null
  from public.get_visible_events('8b841200-8400-4200-8400-000000000002',
    '2030-10-01 00:00+00','2030-10-02 00:00+00')
  where event_id='8e841200-8400-4200-8400-000000000001'),
  'TITLE_ONLY group projection omits location and description');
select extensions.ok((select kind='group' and group_id is null
  from public.get_visible_events('8b841200-8400-4200-8400-000000000002',
    '2030-10-01 00:00+00','2030-10-02 00:00+00')
  where event_id='8e841200-8400-4200-8400-000000000001'),
  'TITLE_ONLY exposes kind but does not expose the group identifier');
select extensions.ok((select visibility_level='BUSY_ONLY' and title='予定あり'
  from public.get_visible_events('8b841200-8400-4200-8400-000000000002',
    '2030-10-01 00:00+00','2030-10-02 00:00+00')
  where event_id='8e841200-8400-4200-8400-000000000003'),
  'event BUSY_ONLY overrides the group default and uses an opaque title');
select extensions.ok((select location is null and description is null and kind is null and group_id is null
  from public.get_visible_events('8b841200-8400-4200-8400-000000000002',
    '2030-10-01 00:00+00','2030-10-02 00:00+00')
  where event_id='8e841200-8400-4200-8400-000000000003'),
  'BUSY_ONLY group projection omits all identifying event fields');
select extensions.ok((select visibility_level='FULL' and title='Full group event'
  and location='Full room' and description='Full notes' and kind='group'
  and group_id='8c841200-8400-4200-8400-000000000001'::uuid
  from public.get_visible_events('8b841200-8400-4200-8400-000000000002',
    '2030-10-01 00:00+00','2030-10-02 00:00+00')
  where event_id='8e841200-8400-4200-8400-000000000004'),
  'event FULL exposes the documented group event details');
select extensions.is((select count(*)::integer from public.get_visible_events(
  '8b841200-8400-4200-8400-000000000002','2030-10-01 00:00+00','2030-10-02 00:00+00')
  where event_id='8e841200-8400-4200-8400-000000000002'
     or title='Private group canary' or location='Private room canary'
     or description='Private notes canary'),0,
  'PRIVATE event and its canaries are absent from group scope');

set local request.jwt.claim.sub='8b841200-8400-4200-8400-000000000003';
select extensions.is((select count(*)::integer from public.get_visible_events(
  '8b841200-8400-4200-8400-000000000003','2030-10-01 00:00+00','2030-10-02 00:00+00')),
  0,'a nonmember cannot see the group-scoped event set');
set local request.jwt.claim.sub='8b841200-8400-4200-8400-000000000002';
select extensions.throws_ok($q$select count(*) from public.get_visible_events(
  '8b841200-8400-4200-8400-000000000003','2030-10-01 00:00+00','2030-10-02 00:00+00')$q$,
  '42501','viewer_id must match auth.uid()','authenticated viewer cannot substitute another viewer id');
reset role;

select * from extensions.finish();
rollback;
