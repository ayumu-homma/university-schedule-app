begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(4);

-- §29 requires an event-specific PRIVATE value to outrank broader visibility.
-- This covers group-scoped events in the shared schedule projection, distinct
-- from the accepted personal-event PRIVATE and group FULL/TITLE_ONLY cases.
insert into auth.users(id) values
  ('8b138000-1380-4380-8380-000000000001'),
  ('8b138000-1380-4380-8380-000000000002')
on conflict(id) do nothing;

insert into public.profiles(user_id,display_name,default_visibility) values
  ('8b138000-1380-4380-8380-000000000001','P138 group event owner','PRIVATE'),
  ('8b138000-1380-4380-8380-000000000002','P138 group event member','PRIVATE')
on conflict(user_id) do update set
  display_name=excluded.display_name,
  default_visibility=excluded.default_visibility;

insert into public.groups(id,owner_user_id,name,type,default_visibility,event_create_policy)
values ('8c138000-1380-4380-8380-000000000001',
  '8b138000-1380-4380-8380-000000000001','P138 private event precedence','other','FULL','member');

insert into public.group_members(group_id,user_id,role,visibility_level) values
  ('8c138000-1380-4380-8380-000000000001','8b138000-1380-4380-8380-000000000001','owner',null),
  ('8c138000-1380-4380-8380-000000000001','8b138000-1380-4380-8380-000000000002','member',null);

insert into public.calendars(id,owner_user_id,group_id,name,default_visibility) values
  ('8d138000-1380-4380-8380-000000000001',
   '8b138000-1380-4380-8380-000000000001',
   '8c138000-1380-4380-8380-000000000001','P138 group calendar','FULL');

insert into public.events(
  id,owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,
  location,description,visibility_level,created_by
) values
  ('8e138000-1380-4380-8380-000000000001',
   '8b138000-1380-4380-8380-000000000001',
   '8d138000-1380-4380-8380-000000000001',
   '8c138000-1380-4380-8380-000000000001',
   'P138 FULL group control','group','2032-08-01 01:00+00','2032-08-01 02:00+00',
   'P138 control location','P138 control description','FULL',
   '8b138000-1380-4380-8380-000000000001'),
  ('8e138000-1380-4380-8380-000000000002',
   '8b138000-1380-4380-8380-000000000001',
   '8d138000-1380-4380-8380-000000000001',
   '8c138000-1380-4380-8380-000000000001',
   'P138 PRIVATE group title canary','group','2032-08-01 03:00+00','2032-08-01 04:00+00',
   'P138 PRIVATE location canary','P138 PRIVATE description canary','PRIVATE',
   '8b138000-1380-4380-8380-000000000001');

set local request.jwt.claim.role='authenticated';
set local request.jwt.claim.sub='8b138000-1380-4380-8380-000000000002';
set local role authenticated;

select extensions.ok(exists(
  select 1 from public.get_visible_events(
    '8b138000-1380-4380-8380-000000000002',
    '2032-08-01 00:00+00','2032-08-02 00:00+00')
  where event_id='8e138000-1380-4380-8380-000000000001'
    and visibility_level='FULL'
    and title='P138 FULL group control'
    and location='P138 control location'
    and description='P138 control description'
), 'group member receives the FULL positive control');

select extensions.is((
  select count(*) from public.get_visible_events(
    '8b138000-1380-4380-8380-000000000002',
    '2032-08-01 00:00+00','2032-08-02 00:00+00')
  where event_id='8e138000-1380-4380-8380-000000000002'
),0::bigint,'event-specific PRIVATE overrides group and calendar FULL');

select extensions.ok(
  position('P138 PRIVATE group title canary' in public.get_visible_events(
    '8b138000-1380-4380-8380-000000000002',
    '2032-08-01 00:00+00','2032-08-02 00:00+00')::text)=0,
  'private group event title canary is absent from the projection');

select extensions.ok(not exists(
  select 1 from public.get_visible_events(
    '8b138000-1380-4380-8380-000000000002',
    '2032-08-01 00:00+00','2032-08-02 00:00+00')
  where event_id='8e138000-1380-4380-8380-000000000002'
    and (location='P138 PRIVATE location canary'
      or description='P138 PRIVATE description canary')
), 'private group event location and description canaries are absent');

reset role;
select * from extensions.finish();
rollback;
