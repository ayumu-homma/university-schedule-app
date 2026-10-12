begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(11);

insert into auth.users (id) values
  ('61220000-0000-4000-8000-000000000122'),
  ('61220000-0000-4000-8000-000000000123');

insert into public.groups (id, owner_user_id, name, type)
values (
  '26220000-0000-4000-8000-000000000122',
  '61220000-0000-4000-8000-000000000122',
  'P122 group calendar owner',
  'other'
);

insert into public.calendars (
  id, owner_user_id, group_id, name, default_visibility
)
values
  (
    'b1220000-0000-4000-8000-000000000122',
    '61220000-0000-4000-8000-000000000122',
    null,
    'P122 personal calendar',
    'PRIVATE'
  ),
  (
    'b1220000-0000-4000-8000-000000000123',
    '61220000-0000-4000-8000-000000000122',
    '26220000-0000-4000-8000-000000000122',
    'P122 group calendar',
    'TITLE_ONLY'
  );

select extensions.ok(
  not pg_catalog.has_function_privilege(
    'anon',
    'public.set_personal_calendar_default_visibility(uuid,public.visibility_level)',
    'EXECUTE'
  ),
  'anonymous execution remains denied'
);
select extensions.ok(
  pg_catalog.has_function_privilege(
    'authenticated',
    'public.set_personal_calendar_default_visibility(uuid,public.visibility_level)',
    'EXECUTE'
  ),
  'authenticated execution is granted'
);

set local request.jwt.claims =
  '{"sub":"61220000-0000-4000-8000-000000000122","role":"authenticated"}';
set local request.jwt.claim.sub = '61220000-0000-4000-8000-000000000122';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.lives_ok(
  $$select public.set_personal_calendar_default_visibility(
    'b1220000-0000-4000-8000-000000000122', null
  )$$,
  'owner can select inherited visibility for a personal calendar'
);
reset role;
select extensions.ok(
  (select default_visibility is null from public.calendars
   where id = 'b1220000-0000-4000-8000-000000000122'),
  'explicit null is stored on the personal calendar'
);

set local role authenticated;
select extensions.lives_ok(
  $$select public.set_personal_calendar_default_visibility(
    'b1220000-0000-4000-8000-000000000122', 'BUSY_ONLY'
  )$$,
  'owner can select a concrete visibility value'
);
reset role;
select extensions.is(
  (select default_visibility::text from public.calendars
   where id = 'b1220000-0000-4000-8000-000000000122'),
  'BUSY_ONLY',
  'concrete calendar visibility persists'
);

set local request.jwt.claims =
  '{"sub":"61220000-0000-4000-8000-000000000123","role":"authenticated"}';
set local request.jwt.claim.sub = '61220000-0000-4000-8000-000000000123';
set local role authenticated;
select extensions.throws_ok(
  $$select public.set_personal_calendar_default_visibility(
    'b1220000-0000-4000-8000-000000000122', 'FULL'
  )$$,
  '42501',
  null,
  'another authenticated user cannot update the owner calendar'
);
reset role;
select extensions.is(
  (select default_visibility::text from public.calendars
   where id = 'b1220000-0000-4000-8000-000000000122'),
  'BUSY_ONLY',
  'denied outsider update has no side effect'
);

set local request.jwt.claims =
  '{"sub":"61220000-0000-4000-8000-000000000122","role":"authenticated"}';
set local request.jwt.claim.sub = '61220000-0000-4000-8000-000000000122';
set local role authenticated;
select extensions.throws_ok(
  $$select public.set_personal_calendar_default_visibility(
    'b1220000-0000-4000-8000-000000000123', null
  )$$,
  '42501',
  null,
  'personal-calendar RPC rejects group calendars'
);
reset role;
select extensions.is(
  (select default_visibility::text from public.calendars
   where id = 'b1220000-0000-4000-8000-000000000123'),
  'TITLE_ONLY',
  'rejected group calendar update has no side effect'
);

set local request.jwt.claims =
  '{"sub":"61220000-0000-4000-8000-000000000122","role":"anon"}';
set local request.jwt.claim.sub = '61220000-0000-4000-8000-000000000122';
set local request.jwt.claim.role = 'anon';
set local role anon;
select extensions.throws_ok(
  $$select public.set_personal_calendar_default_visibility(
    'b1220000-0000-4000-8000-000000000122', null
  )$$,
  '42501',
  null,
  'anonymous request cannot execute the function'
);
reset role;

select * from extensions.finish();
rollback;
