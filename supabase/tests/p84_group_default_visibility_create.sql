begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(4);

insert into auth.users(id) values
  ('8b920000-8400-4900-9200-000000000001'),
  ('8b920000-8400-4900-9200-000000000002');
insert into public.profiles(user_id,display_name,default_visibility) values
  ('8b920000-8400-4900-9200-000000000001','P92 group-default owner','PRIVATE'),
  ('8b920000-8400-4900-9200-000000000002','P92 group-default member','PRIVATE')
on conflict(user_id) do update set display_name=excluded.display_name,
  default_visibility=excluded.default_visibility;
insert into public.groups(id,owner_user_id,name,type,default_visibility,event_create_policy)
values ('8c920000-8400-4900-9200-000000000001',
  '8b920000-8400-4900-9200-000000000001','P92 group-default fixture',
  'other','TITLE_ONLY','member');
insert into public.group_members(group_id,user_id,role) values
  ('8c920000-8400-4900-9200-000000000001','8b920000-8400-4900-9200-000000000001','owner'),
  ('8c920000-8400-4900-9200-000000000001','8b920000-8400-4900-9200-000000000002','member');

set local request.jwt.claim.sub='8b920000-8400-4900-9200-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select event_id as created_group_event_id
from public.create_group_event(
  '8c920000-8400-4900-9200-000000000001',
  'P92 title canary',
  '2031-01-08 01:00+00','2031-01-08 02:00+00',
  'P92 location canary','P92 description canary',
  '8f920000-8400-4900-9200-000000000001')
\gset
reset role;

select extensions.is((select visibility_level::text from public.events
  where id=:'created_group_event_id'::uuid), 'TITLE_ONLY',
  'new group event inherits the group default visibility');

set local request.jwt.claim.sub='8b920000-8400-4900-9200-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is((select count(*)::integer from public.get_visible_events(
  '8b920000-8400-4900-9200-000000000002',
  '2031-01-08 00:00+00','2031-01-09 00:00+00')
  where event_id=:'created_group_event_id'::uuid),1,
  'group member receives the default-visible event projection');
select extensions.ok((select visibility_level='TITLE_ONLY'
  and title='P92 title canary' and location is null and description is null
  and group_id is null from public.get_visible_events(
    '8b920000-8400-4900-9200-000000000002',
    '2031-01-08 00:00+00','2031-01-09 00:00+00')
  where event_id=:'created_group_event_id'::uuid),
  'TITLE_ONLY retains title and time but omits private fields and group identity');
select extensions.ok(not exists(select 1 from public.get_visible_events(
  '8b920000-8400-4900-9200-000000000002',
  '2031-01-08 00:00+00','2031-01-09 00:00+00')
  where event_id=:'created_group_event_id'::uuid
    and (location='P92 location canary' or description='P92 description canary')),
  'location and description canaries are not projected');

reset role;
select * from extensions.finish();
rollback;
