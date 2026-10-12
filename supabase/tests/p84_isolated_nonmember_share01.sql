begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(9);

-- Synthetic fixture: one owner, one regular member, and one nonmember.
insert into auth.users(id) values
  ('8b840000-8400-4400-8400-000000000001'),
  ('8b840000-8400-4400-8400-000000000002'),
  ('8b840000-8400-4400-8400-000000000003');
insert into public.profiles(user_id,display_name,default_visibility) values
  ('8b840000-8400-4400-8400-000000000001','P84 owner','PRIVATE'),
  ('8b840000-8400-4400-8400-000000000002','P84 member','PRIVATE'),
  ('8b840000-8400-4400-8400-000000000003','P84 outsider','PRIVATE')
on conflict(user_id) do update set display_name=excluded.display_name;
insert into public.groups(id,owner_user_id,name,type,default_visibility,event_create_policy)
values ('8c840000-8400-4400-8400-000000000001',
        '8b840000-8400-4400-8400-000000000001',
        'P84 synthetic group','other','BUSY_ONLY','member');
insert into public.group_members(group_id,user_id,role,visibility_level) values
  ('8c840000-8400-4400-8400-000000000001','8b840000-8400-4400-8400-000000000001','owner','FULL'),
  ('8c840000-8400-4400-8400-000000000001','8b840000-8400-4400-8400-000000000002','member','BUSY_ONLY');

set local request.jwt.claim.sub='8b840000-8400-4400-8400-000000000003';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.throws_ok(
  $q$select public.find_group_availability(
    '8c840000-8400-4400-8400-000000000001',
    array['8b840000-8400-4400-8400-000000000002'::uuid],
    '2026-09-21 00:00+00','2026-09-21 18:00+00',30)$q$,
  '42501','membership or authorization changed; retry',
  'a nonmember cannot query a group member availability');
select extensions.throws_ok(
  $q$select public.find_group_availability(
    '8c840000-8400-4400-8400-000000000001',
    array['8b840000-8400-4400-8400-000000000003'::uuid],
    '2026-09-21 00:00+00','2026-09-21 18:00+00',30)$q$,
  '42501','membership or authorization changed; retry',
  'a nonmember selected as a requested user is denied');
reset role;

select extensions.ok(
  not has_function_privilege('anon',
    'public.get_visible_events(uuid,timestamptz,timestamptz)','EXECUTE'),
  'anon cannot execute the legacy visible-events RPC');
select extensions.ok(
  has_function_privilege('authenticated',
    'public.get_visible_events(uuid,timestamptz,timestamptz)','EXECUTE'),
  'authenticated retains the intended visible-events RPC grant');
select extensions.ok(not exists (
  select 1
  from pg_proc p
  cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
  where p.oid='public.get_visible_events(uuid,timestamptz,timestamptz)'::regprocedure
    and a.grantee=0 and a.privilege_type='EXECUTE'),
  'PUBLIC has no direct visible-events RPC grant');

select extensions.ok(
  not has_function_privilege('anon',
    'private.phase15_build_friend_snapshot_base(uuid,uuid,uuid,timestamptz,timestamptz,boolean)','EXECUTE'),
  'anon cannot execute the private friend projection base');
select extensions.ok(
  not has_function_privilege('authenticated',
    'private.phase15_build_friend_snapshot_base(uuid,uuid,uuid,timestamptz,timestamptz,boolean)','EXECUTE'),
  'authenticated cannot execute the private friend projection base');
select extensions.ok(
  not has_function_privilege('service_role',
    'private.phase15_build_friend_snapshot_base(uuid,uuid,uuid,timestamptz,timestamptz,boolean)','EXECUTE'),
  'service_role cannot execute the private friend projection base');
select extensions.ok(not exists (
  select 1
  from pg_proc p
  cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
  where p.oid='private.phase15_build_friend_snapshot_base(uuid,uuid,uuid,timestamptz,timestamptz,boolean)'::regprocedure
    and a.grantee=0 and a.privilege_type='EXECUTE'),
  'PUBLIC has no direct private-helper grant');

select * from extensions.finish();
rollback;
