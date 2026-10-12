begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(6);

insert into auth.users(id) values
  ('8b930000-8400-4900-9300-000000000001'),
  ('8b930000-8400-4900-9300-000000000002');
insert into public.profiles(user_id,display_name,default_visibility) values
  ('8b930000-8400-4900-9300-000000000001','P93 matrix owner','PRIVATE'),
  ('8b930000-8400-4900-9300-000000000002','P93 matrix member','PRIVATE')
on conflict(user_id) do update set display_name=excluded.display_name,
  default_visibility=excluded.default_visibility;
insert into public.groups(id,owner_user_id,name,type,default_visibility,event_create_policy) values
  ('8c930000-8400-4900-9300-000000000001','8b930000-8400-4900-9300-000000000001','P93 TITLE_ONLY','other','TITLE_ONLY','member'),
  ('8c930000-8400-4900-9300-000000000002','8b930000-8400-4900-9300-000000000001','P93 BUSY_ONLY','other','BUSY_ONLY','member'),
  ('8c930000-8400-4900-9300-000000000003','8b930000-8400-4900-9300-000000000001','P93 PRIVATE','other','PRIVATE','member'),
  ('8c930000-8400-4900-9300-000000000004','8b930000-8400-4900-9300-000000000001','P93 FULL','other','FULL','member');
insert into public.group_members(group_id,user_id,role)
select g.id,u.user_id,case when u.user_id='8b930000-8400-4900-9300-000000000001' then 'owner' else 'member' end
from public.groups g cross join (values
  ('8b930000-8400-4900-9300-000000000001'::uuid),
  ('8b930000-8400-4900-9300-000000000002'::uuid)
) as u(user_id)
where g.id between '8c930000-8400-4900-9300-000000000001'::uuid
  and '8c930000-8400-4900-9300-000000000004'::uuid;

set local request.jwt.claim.sub='8b930000-8400-4900-9300-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select event_id as title_only_event from public.create_group_event(
  '8c930000-8400-4900-9300-000000000001','P93 title canary',
  '2031-02-01 01:00+00','2031-02-01 02:00+00','P93 title location canary','P93 title description canary',
  '8f930000-8400-4900-9300-000000000001') \gset
select event_id as busy_event from public.create_group_event(
  '8c930000-8400-4900-9300-000000000002','P93 busy title canary',
  '2031-02-01 03:00+00','2031-02-01 04:00+00','P93 busy location canary','P93 busy description canary',
  '8f930000-8400-4900-9300-000000000002') \gset
select event_id as private_event from public.create_group_event(
  '8c930000-8400-4900-9300-000000000003','P93 private title canary',
  '2031-02-01 05:00+00','2031-02-01 06:00+00','P93 private location canary','P93 private description canary',
  '8f930000-8400-4900-9300-000000000003') \gset
select event_id as full_event from public.create_group_event(
  '8c930000-8400-4900-9300-000000000004','P93 full title',
  '2031-02-01 07:00+00','2031-02-01 08:00+00','P93 full location','P93 full description',
  '8f930000-8400-4900-9300-000000000004') \gset
reset role;

select extensions.is((select count(*)::integer from public.events e
  join public.groups g on g.id=e.group_id
  where e.id=any(array[:'title_only_event'::uuid,:'busy_event'::uuid,
    :'private_event'::uuid,:'full_event'::uuid])
    and e.visibility_level=g.default_visibility),4,
  'new group events persist their configured default visibility');

set local request.jwt.claim.sub='8b930000-8400-4900-9300-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
create temporary table p93_projection on commit drop as
select * from public.get_visible_events('8b930000-8400-4900-9300-000000000002',
  '2031-02-01 00:00+00','2031-02-02 00:00+00');
select extensions.is((select count(*)::integer from p93_projection),3,
  'PRIVATE group default is omitted while the three other projections remain');
select extensions.ok((select visibility_level='TITLE_ONLY' and title='P93 title canary'
  and start_at='2031-02-01 01:00+00' and end_at='2031-02-01 02:00+00'
  and location is null and description is null and group_id is null
  from p93_projection where event_id=:'title_only_event'::uuid),
  'TITLE_ONLY keeps title and interval but removes location, description and group identity');
select extensions.ok((select visibility_level='BUSY_ONLY' and title='予定あり'
  and start_at='2031-02-01 03:00+00' and end_at='2031-02-01 04:00+00'
  and location is null and description is null and kind is null and group_id is null
  from p93_projection where event_id=:'busy_event'::uuid),
  'BUSY_ONLY keeps only the interval with an opaque title');
select extensions.ok(not exists(select 1 from p93_projection
  where event_id=:'private_event'::uuid or title like 'P93 private %'
    or location like 'P93 private %' or description like 'P93 private %'),
  'PRIVATE group default and all its canaries are absent');
select extensions.ok((select visibility_level='FULL' and title='P93 full title'
  and start_at='2031-02-01 07:00+00' and end_at='2031-02-01 08:00+00'
  and location='P93 full location' and description='P93 full description'
  and group_id='8c930000-8400-4900-9300-000000000004'::uuid
  from p93_projection where event_id=:'full_event'::uuid),
  'FULL group default retains the intended details and group identity');

reset role;
select * from extensions.finish();
rollback;
