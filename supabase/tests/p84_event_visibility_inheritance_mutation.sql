begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(11);

insert into auth.users (id)
values ('61200000-0000-4000-8000-000000000120');

insert into public.universities (
  id, config_key, name, normalized_name, status
)
values (
  '26200000-0000-4000-8000-000000000120',
  'p120-visibility-inheritance',
  'P120 synthetic university',
  'p120syntheticuniversity',
  'active'
);

update public.profiles
set university_id = '26200000-0000-4000-8000-000000000120'
where user_id = '61200000-0000-4000-8000-000000000120';

insert into public.calendars (
  id, owner_user_id, group_id, name, default_visibility
)
values (
  'b1200000-0000-4000-8000-000000000120',
  '61200000-0000-4000-8000-000000000120',
  null,
  'P120 synthetic calendar',
  'PRIVATE'
);

select extensions.ok(
  not pg_catalog.has_function_privilege(
    'anon',
    'public.apply_schedule_mutation(text,text,uuid,text,bigint,jsonb)',
    'EXECUTE'
  ),
  'anonymous execution remains denied'
);
select extensions.ok(
  pg_catalog.has_function_privilege(
    'authenticated',
    'public.apply_schedule_mutation(text,text,uuid,text,bigint,jsonb)',
    'EXECUTE'
  ),
  'authenticated execution remains granted'
);

set local request.jwt.claims =
  '{"sub":"61200000-0000-4000-8000-000000000120","role":"authenticated"}';
set local request.jwt.claim.sub = '61200000-0000-4000-8000-000000000120';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is(
  public.apply_schedule_mutation(
    'p120-event-create-null',
    'event',
    'f1200000-0000-4000-8000-000000000120',
    'create',
    null,
    jsonb_build_object(
      'id', 'f1200000-0000-4000-8000-000000000120',
      'ownerUserId', auth.uid(),
      'calendarId', 'b1200000-0000-4000-8000-000000000120',
      'title', 'P120 explicit null event',
      'kind', 'normal',
      'startAt', '2026-09-28T05:00:00Z',
      'endAt', '2026-09-28T06:00:00Z',
      'visibilityLevel', null
    )
  ) ->> 'outcome',
  'applied',
  'create accepts an explicit null inheritance override'
);

select extensions.is(
  public.apply_schedule_mutation(
    'p120-event-create-legacy-default',
    'event',
    'f1200000-0000-4000-8000-000000000121',
    'create',
    null,
    jsonb_build_object(
      'id', 'f1200000-0000-4000-8000-000000000121',
      'ownerUserId', auth.uid(),
      'calendarId', 'b1200000-0000-4000-8000-000000000120',
      'title', 'P120 omitted visibility event',
      'kind', 'normal',
      'startAt', '2026-09-28T07:00:00Z',
      'endAt', '2026-09-28T08:00:00Z'
    )
  ) ->> 'outcome',
  'applied',
  'create without a visibility key remains backward compatible'
);

reset role;
select extensions.ok(
  (select visibility_level is null from public.events
   where id = 'f1200000-0000-4000-8000-000000000120')
  and
  (select visibility_level = 'PRIVATE'::public.visibility_level
   from public.events where id = 'f1200000-0000-4000-8000-000000000121'),
  'explicit null persists while omitted create keeps PRIVATE'
);

set local role authenticated;
select extensions.is(
  public.apply_schedule_mutation(
    'p120-event-set-full',
    'event',
    'f1200000-0000-4000-8000-000000000120',
    'update',
    1,
    jsonb_build_object(
      'id', 'f1200000-0000-4000-8000-000000000120',
      'ownerUserId', auth.uid(),
      'calendarId', 'b1200000-0000-4000-8000-000000000120',
      'title', 'P120 explicit null event',
      'kind', 'normal',
      'startAt', '2026-09-28T05:00:00Z',
      'endAt', '2026-09-28T06:00:00Z',
      'visibilityLevel', 'FULL'
    )
  ) ->> 'outcome',
  'applied',
  'explicit enum update applies'
);

select extensions.is(
  public.apply_schedule_mutation(
    'p120-event-update-no-visibility-key',
    'event',
    'f1200000-0000-4000-8000-000000000120',
    'update',
    2,
    jsonb_build_object(
      'id', 'f1200000-0000-4000-8000-000000000120',
      'ownerUserId', auth.uid(),
      'calendarId', 'b1200000-0000-4000-8000-000000000120',
      'title', 'P120 explicit null event',
      'kind', 'normal',
      'startAt', '2026-09-28T05:00:00Z',
      'endAt', '2026-09-28T06:00:00Z'
    )
  ) ->> 'outcome',
  'applied',
  'update without a visibility key preserves the stored value'
);

reset role;
select extensions.is(
  (select visibility_level::text from public.events
   where id = 'f1200000-0000-4000-8000-000000000120'),
  'FULL',
  'omitted update leaves the explicit FULL value intact'
);

set local role authenticated;
select extensions.is(
  public.apply_schedule_mutation(
    'p120-event-clear-visibility',
    'event',
    'f1200000-0000-4000-8000-000000000120',
    'update',
    3,
    jsonb_build_object(
      'id', 'f1200000-0000-4000-8000-000000000120',
      'ownerUserId', auth.uid(),
      'calendarId', 'b1200000-0000-4000-8000-000000000120',
      'title', 'P120 explicit null event',
      'kind', 'normal',
      'startAt', '2026-09-28T05:00:00Z',
      'endAt', '2026-09-28T06:00:00Z',
      'visibilityLevel', null
    )
  ) ->> 'outcome',
  'applied',
  'explicit null clears the stored override'
);

select extensions.throws_ok(
  $sql$
    select public.apply_schedule_mutation(
      'p120-event-invalid-visibility',
      'event',
      'f1200000-0000-4000-8000-000000000120',
      'update',
      4,
      jsonb_build_object(
        'id', 'f1200000-0000-4000-8000-000000000120',
        'ownerUserId', auth.uid(),
        'calendarId', 'b1200000-0000-4000-8000-000000000120',
        'title', 'P120 explicit null event',
        'kind', 'normal',
        'startAt', '2026-09-28T05:00:00Z',
        'endAt', '2026-09-28T06:00:00Z',
        'visibilityLevel', 'NOT_A_LEVEL'
      )
    )
  $sql$,
  '22P02',
  null,
  'unknown nonempty visibility text is rejected'
);

reset role;
select extensions.ok(
  (select visibility_level is null from public.events
   where id = 'f1200000-0000-4000-8000-000000000120'),
  'rejected enum value leaves the prior null override unchanged'
);

select * from extensions.finish();
rollback;
