begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(13);

-- Synthetic actors and groups only. This contract is source for a future
-- isolated PostgreSQL run; it is not executed as part of P74.
insert into auth.users (id) values
  ('a7410000-0000-4000-8000-000000000001'),
  ('a7410000-0000-4000-8000-000000000002'),
  ('a7410000-0000-4000-8000-000000000003'),
  ('a7410000-0000-4000-8000-000000000004'),
  ('a7410000-0000-4000-8000-000000000005')
on conflict (id) do nothing;

insert into public.groups (id, owner_user_id, name, type) values
  ('b7410000-0000-4000-8000-000000000001',
   'a7410000-0000-4000-8000-000000000001', 'P61 projection fixture', 'other'),
  ('b7410000-0000-4000-8000-000000000002',
   'a7410000-0000-4000-8000-000000000005', 'P61 isolated group fixture', 'other');

insert into public.group_members (group_id, user_id, role) values
  ('b7410000-0000-4000-8000-000000000001','a7410000-0000-4000-8000-000000000001','owner'),
  ('b7410000-0000-4000-8000-000000000001','a7410000-0000-4000-8000-000000000002','member'),
  ('b7410000-0000-4000-8000-000000000001','a7410000-0000-4000-8000-000000000003','member'),
  ('b7410000-0000-4000-8000-000000000001','a7410000-0000-4000-8000-000000000004','member'),
  ('b7410000-0000-4000-8000-000000000002','a7410000-0000-4000-8000-000000000005','owner');

insert into public.blocks (blocker_user_id, blocked_user_id) values
  ('a7410000-0000-4000-8000-000000000002','a7410000-0000-4000-8000-000000000001'), -- incoming
  ('a7410000-0000-4000-8000-000000000001','a7410000-0000-4000-8000-000000000003'), -- outgoing
  ('a7410000-0000-4000-8000-000000000004','a7410000-0000-4000-8000-000000000005'); -- third party, outside this group

select extensions.ok(
  pg_catalog.has_function_privilege('authenticated', 'public.list_group_member_blocked_users(uuid)', 'EXECUTE'),
  'authenticated can call the scoped projection');
select extensions.ok(
  not pg_catalog.has_function_privilege('anon', 'public.list_group_member_blocked_users(uuid)', 'EXECUTE'),
  'anonymous role cannot call the projection');
select extensions.ok(
  not pg_catalog.has_function_privilege('service_role', 'public.list_group_member_blocked_users(uuid)', 'EXECUTE'),
  'service role is not granted projection execution');
select extensions.ok(
  (select prosecdef and proconfig @> array['search_path=""']
   from pg_catalog.pg_proc
   where oid='public.list_group_member_blocked_users(uuid)'::regprocedure),
  'projection is definer-scoped with an empty search path');
select extensions.is(
  (select pronargs from pg_catalog.pg_proc
   where oid='public.list_group_member_blocked_users(uuid)'::regprocedure),
  1::smallint,
  'projection accepts only a group id and derives the viewer from auth.uid');

set local request.jwt.claims='{"sub":"a7410000-0000-4000-8000-000000000001","role":"authenticated"}';
set local request.jwt.claim.sub='a7410000-0000-4000-8000-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is(
  (select coalesce(jsonb_agg(user_id order by user_id), '[]'::jsonb)
   from public.list_group_member_blocked_users('b7410000-0000-4000-8000-000000000001')),
  jsonb_build_array('a7410000-0000-4000-8000-000000000002'::uuid,
                    'a7410000-0000-4000-8000-000000000003'::uuid),
  'returns only in-group peers with either-direction blocks, without direction');

reset role;
set local request.jwt.claims='{"sub":"a7410000-0000-4000-8000-000000000005","role":"authenticated"}';
set local request.jwt.claim.sub='a7410000-0000-4000-8000-000000000005';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.throws_ok(
  $q$select * from public.list_group_member_blocked_users('b7410000-0000-4000-8000-000000000001')$q$,
  '42501', 'group access denied', 'non-member cannot inspect another group projection');

reset role;
set local request.jwt.claims='{"sub":"a7410000-0000-4000-8000-000000000001","role":"authenticated"}';
set local request.jwt.claim.sub='a7410000-0000-4000-8000-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.throws_ok(
  $q$select * from public.list_group_member_blocked_users('b7410000-0000-4000-8000-000000000002')$q$,
  '42501', 'group access denied', 'member cannot use this projection across groups');

reset role;
set local request.jwt.claims='{"role":"anon"}';
set local request.jwt.claim.role='anon';
set local role anon;
select extensions.throws_ok(
  $q$select * from public.list_group_member_blocked_users('b7410000-0000-4000-8000-000000000001')$q$,
  '42501', null, 'anonymous execution is denied');

reset role;
insert into private.user_safety_state (user_id, status)
values ('a7410000-0000-4000-8000-000000000001', 'suspended')
on conflict (user_id) do update set status='suspended';
set local request.jwt.claims='{"sub":"a7410000-0000-4000-8000-000000000001","role":"authenticated"}';
set local request.jwt.claim.sub='a7410000-0000-4000-8000-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.throws_ok(
  $q$select * from public.list_group_member_blocked_users('b7410000-0000-4000-8000-000000000001')$q$,
  '42501', 'group access denied', 'suspended actor is rejected');

reset role;
update private.user_safety_state set status='active'
where user_id='a7410000-0000-4000-8000-000000000001';
update public.groups set suspended_at=clock_timestamp()
where id='b7410000-0000-4000-8000-000000000001';
set local role authenticated;
select extensions.throws_ok(
  $q$select * from public.list_group_member_blocked_users('b7410000-0000-4000-8000-000000000001')$q$,
  '42501', 'group access denied', 'suspended group is rejected');

reset role;
update public.groups set suspended_at=null
where id='b7410000-0000-4000-8000-000000000001';
delete from public.blocks
where blocker_user_id='a7410000-0000-4000-8000-000000000001'
  and blocked_user_id='a7410000-0000-4000-8000-000000000003';
set local role authenticated;
select extensions.is(
  (select coalesce(jsonb_agg(user_id order by user_id), '[]'::jsonb)
   from public.list_group_member_blocked_users('b7410000-0000-4000-8000-000000000001')),
  jsonb_build_array('a7410000-0000-4000-8000-000000000002'::uuid),
  'unblocking removes only that peer from the projection');

reset role;
delete from public.blocks
where blocker_user_id='a7410000-0000-4000-8000-000000000002'
  and blocked_user_id='a7410000-0000-4000-8000-000000000001';
set local role authenticated;
select extensions.is(
  (select count(*) from public.list_group_member_blocked_users('b7410000-0000-4000-8000-000000000001')),
  0::bigint,
  'empty projection means there are no blocked peers in this group');

reset role;
select * from extensions.finish();
rollback;
