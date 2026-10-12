begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(2);

insert into auth.users(id) values
  ('8b960000-8400-4900-9600-000000000001'),
  ('8b960000-8400-4900-9600-000000000002');
insert into public.profiles(user_id,display_name,default_visibility) values
  ('8b960000-8400-4900-9600-000000000001','P96 calendar owner','PRIVATE'),
  ('8b960000-8400-4900-9600-000000000002','P96 calendar member','PRIVATE')
on conflict(user_id) do update set display_name=excluded.display_name,
  default_visibility=excluded.default_visibility;
insert into public.groups(id,owner_user_id,name,type,default_visibility,event_create_policy)
values ('8c960000-8400-4900-9600-000000000001',
  '8b960000-8400-4900-9600-000000000001','P96 calendar FULL precedence','other','TITLE_ONLY','member');
insert into public.group_members(group_id,user_id,role) values
  ('8c960000-8400-4900-9600-000000000001','8b960000-8400-4900-9600-000000000001','owner'),
  ('8c960000-8400-4900-9600-000000000001','8b960000-8400-4900-9600-000000000002','member');
insert into public.calendars(owner_user_id,group_id,name,default_visibility)
values ('8b960000-8400-4900-9600-000000000001',
  '8c960000-8400-4900-9600-000000000001','P96 FULL calendar','FULL');

set local request.jwt.claim.sub='8b960000-8400-4900-9600-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select event_id as calendar_full_event
from public.create_group_event(
  '8c960000-8400-4900-9600-000000000001','P96 full title canary',
  '2031-04-01 01:00+00','2031-04-01 02:00+00',
  'P96 full location canary','P96 full description canary',
  '8f960000-8400-4900-9600-000000000001')
\gset
reset role;

select extensions.is((select visibility_level::text from public.events
  where id=:'calendar_full_event'::uuid), 'FULL',
  'calendar FULL outranks group TITLE_ONLY when no item-level choice is supplied');

set local request.jwt.claim.sub='8b960000-8400-4900-9600-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.ok(exists(select 1 from public.get_visible_events(
  '8b960000-8400-4900-9600-000000000002',
  '2031-04-01 00:00+00','2031-04-02 00:00+00')
  where event_id=:'calendar_full_event'::uuid and visibility_level='FULL'
    and title='P96 full title canary' and start_at='2031-04-01 01:00+00'
    and end_at='2031-04-01 02:00+00' and location='P96 full location canary'
    and description='P96 full description canary'
    and group_id='8c960000-8400-4900-9600-000000000001'::uuid),
  'group member receives the FULL calendar projection over group TITLE_ONLY');

reset role;
select * from extensions.finish();
rollback;
