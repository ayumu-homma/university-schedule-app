begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(2);

insert into auth.users(id) values
  ('8b843000-8400-4300-8400-000000000001'),
  ('8b843000-8400-4300-8400-000000000002');
insert into public.profiles(user_id,display_name,default_visibility) values
  ('8b843000-8400-4300-8400-000000000001','P84 create owner','PRIVATE'),
  ('8b843000-8400-4300-8400-000000000002','P84 create outsider','PRIVATE')
on conflict(user_id) do update set
  display_name=excluded.display_name,
  default_visibility=excluded.default_visibility;
insert into public.groups(id,owner_user_id,name,type,default_visibility,event_create_policy)
values ('8c843000-8400-4300-8400-000000000001',
        '8b843000-8400-4300-8400-000000000001',
        'P84 nonmember create scope','other','TITLE_ONLY','member');
insert into public.group_members(group_id,user_id,role)
values ('8c843000-8400-4300-8400-000000000001',
        '8b843000-8400-4300-8400-000000000001','owner');

set local request.jwt.claim.sub='8b843000-8400-4300-8400-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.throws_ok(
  $q$select * from public.create_group_event(
    '8c843000-8400-4300-8400-000000000001','P84 unauthorized group event',
    '2031-03-01 01:00+00','2031-03-01 02:00+00',null,null,
    '8f843000-8400-4300-8400-000000000001')$q$,
  '42501','event creation denied',
  'authenticated nonmember cannot create a group event');
reset role;
select extensions.is((select count(*)::integer from public.events
  where group_id='8c843000-8400-4300-8400-000000000001'),0,
  'denied nonmember request persists no event');

select * from extensions.finish();
rollback;
