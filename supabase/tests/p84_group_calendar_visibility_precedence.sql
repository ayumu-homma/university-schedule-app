begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(7);

insert into auth.users(id) values
  ('8b950000-8400-4900-9500-000000000001'),
  ('8b950000-8400-4900-9500-000000000002');
insert into public.profiles(user_id,display_name,default_visibility) values
  ('8b950000-8400-4900-9500-000000000001','P95 calendar owner','PRIVATE'),
  ('8b950000-8400-4900-9500-000000000002','P95 calendar member','PRIVATE')
on conflict(user_id) do update set display_name=excluded.display_name,
  default_visibility=excluded.default_visibility;
insert into public.groups(id,owner_user_id,name,type,default_visibility,event_create_policy)
values
  ('8c950000-8400-4900-9500-000000000001',
    '8b950000-8400-4900-9500-000000000001','P95 calendar precedence','other','FULL','member'),
  ('8c950000-8400-4900-9500-000000000002',
    '8b950000-8400-4900-9500-000000000001','P95 calendar fallback','other','BUSY_ONLY','member');
insert into public.group_members(group_id,user_id,role) values
  ('8c950000-8400-4900-9500-000000000001','8b950000-8400-4900-9500-000000000001','owner'),
  ('8c950000-8400-4900-9500-000000000001','8b950000-8400-4900-9500-000000000002','member'),
  ('8c950000-8400-4900-9500-000000000002','8b950000-8400-4900-9500-000000000001','owner'),
  ('8c950000-8400-4900-9500-000000000002','8b950000-8400-4900-9500-000000000002','member');
insert into public.calendars(owner_user_id,group_id,name,default_visibility)
values ('8b950000-8400-4900-9500-000000000001',
  '8c950000-8400-4900-9500-000000000001','P95 title-only calendar','TITLE_ONLY');

set local request.jwt.claim.sub='8b950000-8400-4900-9500-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select event_id as calendar_precedence_event
from public.create_group_event(
  '8c950000-8400-4900-9500-000000000001','P95 visible title canary',
  '2031-03-01 01:00+00','2031-03-01 02:00+00',
  'P95 hidden location canary','P95 hidden description canary',
  '8f950000-8400-4900-9500-000000000001')
\gset
select event_id as calendar_fallback_event
from public.create_group_event(
  '8c950000-8400-4900-9500-000000000002','P95 fallback title canary',
  '2031-03-01 03:00+00','2031-03-01 04:00+00',
  'P95 fallback location canary','P95 fallback description canary',
  '8f950000-8400-4900-9500-000000000002')
\gset
reset role;

select extensions.is((select visibility_level::text from public.events
  where id=:'calendar_precedence_event'::uuid), 'TITLE_ONLY',
  'calendar default outranks group default when no event-specific level is supplied');
select extensions.is((select visibility_level::text from public.events
  where id=:'calendar_fallback_event'::uuid), 'BUSY_ONLY',
  'event in a new group calendar inherits the group default');
select extensions.is((select c.default_visibility::text from public.calendars c
  join public.events e on e.calendar_id=c.id
  where e.id=:'calendar_fallback_event'::uuid), 'BUSY_ONLY',
  'new group calendar is initialized from the group default');

set local request.jwt.claim.sub='8b950000-8400-4900-9500-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
create temporary table p95_calendar_projection on commit drop as
select * from public.get_visible_events('8b950000-8400-4900-9500-000000000002',
  '2031-03-01 00:00+00','2031-03-02 00:00+00');
select extensions.ok(exists(select 1 from p95_calendar_projection
  where event_id=:'calendar_precedence_event'::uuid
    and visibility_level='TITLE_ONLY' and title='P95 visible title canary'
    and start_at='2031-03-01 01:00+00' and end_at='2031-03-01 02:00+00'),
  'group member receives the calendar-scoped TITLE_ONLY projection');
select extensions.ok(not exists(select 1 from p95_calendar_projection
  where event_id=:'calendar_precedence_event'::uuid
    and (location='P95 hidden location canary'
      or description='P95 hidden description canary')),
  'calendar TITLE_ONLY projection omits private fields');
select extensions.is((select count(*)::integer from p95_calendar_projection
  where location='P95 hidden location canary'
    or description='P95 hidden description canary'), 0,
  'private calendar canaries are absent from the member projection');
select extensions.ok(exists(select 1 from p95_calendar_projection
  where event_id=:'calendar_fallback_event'::uuid
    and visibility_level='BUSY_ONLY' and title='予定あり'
    and start_at='2031-03-01 03:00+00' and end_at='2031-03-01 04:00+00'
    and location is null and description is null),
  'group fallback remains BUSY_ONLY and hides event details');

reset role;
select * from extensions.finish();
rollback;
