begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(7);

insert into auth.users(id) values
 ('a1430000-0000-4000-8000-000000000001'),
 ('a1430000-0000-4000-8000-000000000002'),
 ('a1430000-0000-4000-8000-000000000003'),
 ('a1430000-0000-4000-8000-000000000004')
on conflict(id) do nothing;
insert into public.profiles(user_id,display_name) values
 ('a1430000-0000-4000-8000-000000000001','P143 viewer one private profile'),
 ('a1430000-0000-4000-8000-000000000002','P143 blocked private profile'),
 ('a1430000-0000-4000-8000-000000000003','P143 unrelated public group label'),
 ('a1430000-0000-4000-8000-000000000004','P143 viewer two private profile')
on conflict(user_id) do update set display_name=excluded.display_name;
insert into public.groups(id,owner_user_id,name,type) values
 ('b1430000-0000-4000-8000-000000000001',
  'a1430000-0000-4000-8000-000000000001','P143 block display fixture','other'),
 ('b1430000-0000-4000-8000-000000000002',
  'a1430000-0000-4000-8000-000000000004','P143 outsider fixture','other');
insert into public.group_members(group_id,user_id,role) values
 ('b1430000-0000-4000-8000-000000000001','a1430000-0000-4000-8000-000000000001','owner'),
 ('b1430000-0000-4000-8000-000000000001','a1430000-0000-4000-8000-000000000002','member'),
 ('b1430000-0000-4000-8000-000000000001','a1430000-0000-4000-8000-000000000003','member'),
 ('b1430000-0000-4000-8000-000000000002','a1430000-0000-4000-8000-000000000004','owner');
insert into public.blocks(blocker_user_id,blocked_user_id) values
 ('a1430000-0000-4000-8000-000000000001','a1430000-0000-4000-8000-000000000002');

select extensions.ok(
  (select prosecdef and proconfig @> array['search_path=""']
   from pg_catalog.pg_proc
   where oid='public.list_group_members(uuid)'::regprocedure),
  'member listing remains definer-scoped with an empty search path');
select extensions.ok(
  has_function_privilege('authenticated','public.list_group_members(uuid)','EXECUTE')
  and not has_function_privilege('anon','public.list_group_members(uuid)','EXECUTE'),
  'only authenticated callers retain execution');

set local request.jwt.claims='{"sub":"a1430000-0000-4000-8000-000000000001","role":"authenticated"}';
set local request.jwt.claim.sub='a1430000-0000-4000-8000-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is(
  (select display_name from public.list_group_members('b1430000-0000-4000-8000-000000000001')
   where user_id='a1430000-0000-4000-8000-000000000002'),
  'ブロック中のメンバー',
  'blocker receives a generic label for the blocked peer');
select extensions.is(
  (select display_name from public.list_group_members('b1430000-0000-4000-8000-000000000001')
   where user_id='a1430000-0000-4000-8000-000000000001'),
  'P143 viewer one private profile',
  'viewer still receives their own profile name');
select extensions.is(
  (select display_name from public.list_group_members('b1430000-0000-4000-8000-000000000001')
   where user_id='a1430000-0000-4000-8000-000000000003'),
  'P143 unrelated public group label',
  'unrelated member label remains available');
select extensions.is(
  (select count(*) from public.list_group_members('b1430000-0000-4000-8000-000000000001')),
  3::bigint,
  'block masking does not remove group membership rows');

reset role;
set local request.jwt.claims='{"sub":"a1430000-0000-4000-8000-000000000004","role":"authenticated"}';
set local request.jwt.claim.sub='a1430000-0000-4000-8000-000000000004';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.throws_ok(
  $q$select * from public.list_group_members('b1430000-0000-4000-8000-000000000001')$q$,
  '42501','group access denied','nonmember cannot inspect the redacted group listing');

reset role;
select * from extensions.finish();
rollback;
