begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(9);

insert into auth.users(id) values
  ('8b660000-8400-4900-8600-000000000001'),
  ('8b660000-8400-4900-8600-000000000002'),
  ('8b660000-8400-4900-8600-000000000003');
insert into public.profiles(user_id, display_name, default_visibility) values
  ('8b660000-8400-4900-8600-000000000001', 'P166 owner', 'PRIVATE'),
  ('8b660000-8400-4900-8600-000000000002', 'P166 member', 'PRIVATE'),
  ('8b660000-8400-4900-8600-000000000003', 'P166 outsider', 'PRIVATE')
on conflict(user_id) do update set display_name=excluded.display_name;
insert into public.groups(id, owner_user_id, name, type, default_visibility)
values ('8c660000-8400-4900-8600-000000000001',
  '8b660000-8400-4900-8600-000000000001', 'P166 visibility fixture', 'other', 'TITLE_ONLY');
insert into public.group_members(group_id, user_id, role) values
  ('8c660000-8400-4900-8600-000000000001','8b660000-8400-4900-8600-000000000001','owner'),
  ('8c660000-8400-4900-8600-000000000001','8b660000-8400-4900-8600-000000000002','member');

set local request.jwt.claim.sub='8b660000-8400-4900-8600-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is(public.get_group_default_visibility(
  '8c660000-8400-4900-8600-000000000001'), 'TITLE_ONLY',
  'owner can read group default visibility');
reset role;

set local request.jwt.claim.sub='8b660000-8400-4900-8600-000000000002';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is(public.get_group_default_visibility(
  '8c660000-8400-4900-8600-000000000001'), 'TITLE_ONLY',
  'member can read group default visibility');
select extensions.throws_ok(
  $$select * from public.set_group_default_visibility(
    '8c660000-8400-4900-8600-000000000001','FULL',
    '8f660000-8400-4900-8600-000000000001')$$,
  '42501', 'admin required', 'ordinary member cannot change group default visibility');
reset role;

set local request.jwt.claim.sub='8b660000-8400-4900-8600-000000000003';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.throws_ok(
  $$select public.get_group_default_visibility(
    '8c660000-8400-4900-8600-000000000001')$$,
  '42501', 'group access denied', 'non-member cannot read group default visibility');
reset role;

set local request.jwt.claim.sub='8b660000-8400-4900-8600-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select default_visibility as p166_saved_visibility
from public.set_group_default_visibility(
  '8c660000-8400-4900-8600-000000000001','BUSY_ONLY',
  '8f660000-8400-4900-8600-000000000002') \gset
select extensions.is(:'p166_saved_visibility'::text, 'BUSY_ONLY'::text,
  'owner receives the committed visibility');
reset role;
select extensions.is((select g.default_visibility::text from public.groups g
  where g.id='8c660000-8400-4900-8600-000000000001'), 'BUSY_ONLY',
  'setting is persisted on the existing group row');

set local request.jwt.claim.sub='8b660000-8400-4900-8600-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.throws_ok(
  $$select * from public.set_group_default_visibility(
    '8c660000-8400-4900-8600-000000000001','INVALID',
    '8f660000-8400-4900-8600-000000000003')$$,
  '22023', 'invalid group visibility', 'unknown visibility levels are rejected');
reset role;

select extensions.ok(not pg_catalog.has_function_privilege(
  'anon', 'public.set_group_default_visibility(uuid,text,uuid)', 'EXECUTE'),
  'anonymous role cannot execute the setting RPC');
select extensions.ok(not pg_catalog.has_function_privilege(
  'service_role', 'public.set_group_default_visibility(uuid,text,uuid)', 'EXECUTE'),
  'service role does not need client setting RPC access');
select * from extensions.finish();
rollback;
