begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(38);

insert into auth.users (id)
values
  ('81111111-1111-4111-8111-111111111111'),
  ('82222222-2222-4222-8222-222222222222');

insert into public.universities (
  id, config_key, name, normalized_name, status
)
values (
  '8a000000-0000-4000-8000-000000000001',
  'test:routine-exception:university',
  'Routine Exception Test University',
  'routineexceptiontestuniversity',
  'active'
);

update public.profiles
set university_id = '8a000000-0000-4000-8000-000000000001'
where user_id in (
  '81111111-1111-4111-8111-111111111111',
  '82222222-2222-4222-8222-222222222222'
);

insert into public.groups (id, owner_user_id, name)
values (
  '8a000000-0000-4000-8000-000000000002',
  '81111111-1111-4111-8111-111111111111',
  'Timezone policy test group'
);

insert into public.calendars (id, owner_user_id, name, default_visibility)
values
  (
    '8b100000-0000-4000-8000-000000000001',
    '81111111-1111-4111-8111-111111111111',
    'Routine owner calendar',
    'PRIVATE'
  ),
  (
    '8b200000-0000-4000-8000-000000000002',
    '82222222-2222-4222-8222-222222222222',
    'Other member calendar',
    'PRIVATE'
  );

insert into public.calendars (
  id, owner_user_id, group_id, name, default_visibility
)
values (
  '8b100000-0000-4000-8000-000000000003',
  '81111111-1111-4111-8111-111111111111',
  '8a000000-0000-4000-8000-000000000002',
  'Timezone policy group calendar',
  'PRIVATE'
);

insert into public.events (
  id, owner_user_id, calendar_id, title, kind, start_at, end_at, rrule,
  timezone, visibility_level, created_by
)
values
  (
    '8c100000-0000-4000-8000-000000000001',
    '81111111-1111-4111-8111-111111111111',
    '8b100000-0000-4000-8000-000000000001',
    'Weekly routine',
    'routine',
    '2026-07-06T00:00:00Z',
    '2026-07-06T01:00:00Z',
    'FREQ=WEEKLY;COUNT=4',
    'Asia/Tokyo',
    'PRIVATE',
    '81111111-1111-4111-8111-111111111111'
  ),
  (
    '8c100000-0000-4000-8000-000000000003',
    '81111111-1111-4111-8111-111111111111',
    '8b100000-0000-4000-8000-000000000001',
    'Normal event',
    'normal',
    '2026-07-06T02:00:00Z',
    '2026-07-06T03:00:00Z',
    null,
    'Asia/Tokyo',
    'PRIVATE',
    '81111111-1111-4111-8111-111111111111'
  ),
  (
    '8c200000-0000-4000-8000-000000000002',
    '82222222-2222-4222-8222-222222222222',
    '8b200000-0000-4000-8000-000000000002',
    'Other member routine',
    'routine',
    '2026-07-06T00:00:00Z',
    '2026-07-06T01:00:00Z',
    'FREQ=WEEKLY;COUNT=4',
    'Asia/Tokyo',
    'PRIVATE',
    '82222222-2222-4222-8222-222222222222'
  ),
  (
    '8c100000-0000-4000-8000-000000000004',
    '81111111-1111-4111-8111-111111111111',
    '8b100000-0000-4000-8000-000000000001',
    'Biweekly routine',
    'routine',
    '2026-07-06T00:00:00Z',
    '2026-07-06T01:00:00Z',
    'FREQ=WEEKLY;INTERVAL=2;COUNT=4',
    'Asia/Tokyo',
    'PRIVATE',
    '81111111-1111-4111-8111-111111111111'
  ),
  (
    '8c100000-0000-4000-8000-000000000005',
    '81111111-1111-4111-8111-111111111111',
    '8b100000-0000-4000-8000-000000000001',
    'Daily routine with local UNTIL',
    'routine',
    '2026-07-06T00:00:00Z',
    '2026-07-06T01:00:00Z',
    'FREQ=DAILY;UNTIL=2026-07-08T09:00:00',
    'Asia/Tokyo',
    'PRIVATE',
    '81111111-1111-4111-8111-111111111111'
  ),
  (
    '8c100000-0000-4000-8000-000000000006',
    '81111111-1111-4111-8111-111111111111',
    '8b100000-0000-4000-8000-000000000001',
    'Multi-day weekly routine',
    'routine',
    '2026-07-06T00:00:00Z',
    '2026-07-06T01:00:00Z',
    'FREQ=WEEKLY;BYDAY=1,3,5;COUNT=4',
    'Asia/Tokyo',
    'PRIVATE',
    '81111111-1111-4111-8111-111111111111'
  ),
  (
    '8c100000-0000-4000-8000-000000000010',
    '81111111-1111-4111-8111-111111111111',
    '8b100000-0000-4000-8000-000000000001',
    'Month-end routine',
    'routine',
    '2026-01-31T00:00:00Z',
    '2026-01-31T01:00:00Z',
    'FREQ=MONTHLY;MONTHDAY=31;COUNT=2',
    'Asia/Tokyo',
    'PRIVATE',
    '81111111-1111-4111-8111-111111111111'
  ),
  (
    '8c100000-0000-4000-8000-000000000011',
    '81111111-1111-4111-8111-111111111111',
    '8b100000-0000-4000-8000-000000000001',
    'Fifth Monday routine',
    'routine',
    '2026-02-02T00:00:00Z',
    '2026-02-02T01:00:00Z',
    'FREQ=NTHWEEKDAY;NTH=5;WEEKDAY=1;COUNT=2',
    'Asia/Tokyo',
    'PRIVATE',
    '81111111-1111-4111-8111-111111111111'
  ),
  (
    '8c100000-0000-4000-8000-000000000012',
    '81111111-1111-4111-8111-111111111111',
    '8b100000-0000-4000-8000-000000000001',
    'Weekday-only routine',
    'routine',
    '2026-07-03T00:00:00Z',
    '2026-07-03T01:00:00Z',
    'FREQ=WEEKDAYS;COUNT=2',
    'Asia/Tokyo',
    'PRIVATE',
    '81111111-1111-4111-8111-111111111111'
  );

select extensions.ok(
  pg_catalog.has_function_privilege(
    'authenticated',
    'public.apply_event_exception_mutation(text,uuid,text,bigint,jsonb)',
    'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'anon',
    'public.apply_event_exception_mutation(text,uuid,text,bigint,jsonb)',
    'EXECUTE'
  ),
  'event-exception mutation RPC is authenticated-only'
);

select extensions.ok(
  not pg_catalog.has_table_privilege(
    'authenticated', 'public.event_exceptions', 'INSERT'
  )
  and not pg_catalog.has_table_privilege(
    'authenticated', 'public.event_exceptions', 'UPDATE'
  )
  and not pg_catalog.has_table_privilege(
    'authenticated', 'public.event_exceptions', 'DELETE'
  ),
  'clients have no direct event-exception write path'
);

select extensions.lives_ok(
  $sql$
    insert into public.events (
      id, owner_user_id, calendar_id, group_id, title, kind, start_at,
      end_at, timezone, visibility_level, created_by
    ) values (
      '8c100000-0000-4000-8000-000000000013',
      '81111111-1111-4111-8111-111111111111',
      '8b100000-0000-4000-8000-000000000003',
      '8a000000-0000-4000-8000-000000000002',
      'UTC group event',
      'group',
      '2026-07-06T00:00:00Z',
      '2026-07-06T01:00:00Z',
      'UTC',
      'PRIVATE',
      '81111111-1111-4111-8111-111111111111'
    )
  $sql$,
  'group events remain unrestricted by the personal Asia/Tokyo contract'
);

set local request.jwt.claims = '{"sub":"81111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '81111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.throws_ok(
  $sql$
    select public.apply_schedule_mutation(
      'routine-rule-invalid-through-event-rpc',
      'event',
      '8c100000-0000-4000-8000-000000000007',
      'create',
      null,
      jsonb_build_object(
        'id', '8c100000-0000-4000-8000-000000000007',
        'ownerUserId', auth.uid(),
        'calendarId', '8b100000-0000-4000-8000-000000000001',
        'title', 'Malformed routine',
        'kind', 'routine',
        'startAt', '2026-07-06T00:00:00Z',
        'endAt', '2026-07-06T01:00:00Z',
        'rrule', 'FREQ=UNKNOWN;COUNT=1',
        'timezone', 'Asia/Tokyo'
      )
    )
  $sql$,
  '22023',
  'routine requires a supported finite recurrence rule',
  'personal event RPC rejects a malformed routine rule before it can persist'
);

select extensions.throws_ok(
  $sql$
    select public.apply_schedule_mutation(
      'normal-event-rule-through-event-rpc',
      'event',
      '8c100000-0000-4000-8000-000000000008',
      'create',
      null,
      jsonb_build_object(
        'id', '8c100000-0000-4000-8000-000000000008',
        'ownerUserId', auth.uid(),
        'calendarId', '8b100000-0000-4000-8000-000000000001',
        'title', 'Normal event with recurrence',
        'kind', 'normal',
        'startAt', '2026-07-06T00:00:00Z',
        'endAt', '2026-07-06T01:00:00Z',
        'rrule', 'FREQ=DAILY;COUNT=1',
        'timezone', 'Asia/Tokyo'
      )
    )
  $sql$,
  '22023',
  'only routines may define a recurrence rule',
  'personal event RPC rejects recurrence metadata for a non-routine'
);

select extensions.throws_ok(
  $sql$
    select public.apply_schedule_mutation(
      'personal-event-utc-timezone-rejected',
      'event',
      '8c100000-0000-4000-8000-000000000014',
      'create',
      null,
      jsonb_build_object(
        'id', '8c100000-0000-4000-8000-000000000014',
        'ownerUserId', auth.uid(),
        'calendarId', '8b100000-0000-4000-8000-000000000001',
        'title', 'UTC personal event',
        'kind', 'normal',
        'startAt', '2026-07-06T00:00:00Z',
        'endAt', '2026-07-06T01:00:00Z',
        'timezone', 'UTC'
      )
    )
  $sql$,
  '22023',
  'personal events must use Asia/Tokyo',
  'personal event RPC rejects a non-JST timezone'
);

select extensions.throws_ok(
  $sql$
    select public.apply_schedule_mutation(
      'personal-event-derived-kind-rejected',
      'event',
      '8c100000-0000-4000-8000-000000000016',
      'create',
      null,
      jsonb_build_object(
        'id', '8c100000-0000-4000-8000-000000000016',
        'ownerUserId', auth.uid(),
        'calendarId', '8b100000-0000-4000-8000-000000000001',
        'title', 'Derived event cannot use personal sync',
        'kind', 'exam',
        'startAt', '2026-07-06T00:00:00Z',
        'endAt', '2026-07-06T01:00:00Z',
        'timezone', 'Asia/Tokyo'
      )
    )
  $sql$,
  '22023',
  'personal events must be normal or routine',
  'personal event RPC rejects derived schedule kinds'
);

select extensions.throws_ok(
  $sql$
    select public.apply_schedule_mutation(
      'personal-event-derived-kind-update-rejected',
      'event',
      '8c100000-0000-4000-8000-000000000003',
      'update',
      1,
      jsonb_build_object(
        'id', '8c100000-0000-4000-8000-000000000003',
        'ownerUserId', auth.uid(),
        'calendarId', '8b100000-0000-4000-8000-000000000001',
        'title', 'Normal event cannot become derived',
        'kind', 'exam',
        'startAt', '2026-07-06T02:00:00Z',
        'endAt', '2026-07-06T03:00:00Z',
        'timezone', 'Asia/Tokyo'
      )
    )
  $sql$,
  '22023',
  'personal events must be normal or routine',
  'personal event RPC rejects changing a personal event to a derived kind'
);

select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      response ->> 'entity_type',
      (response ->> 'server_version')::bigint,
      response #>> '{change,payload,overrideTitle}'
    from (
      select public.apply_event_exception_mutation(
        'routine-exception-create',
        '8d100000-0000-4000-8000-000000000001',
        'create',
        null,
        jsonb_build_object(
          'id', '8d100000-0000-4000-8000-000000000001',
          'ownerUserId', auth.uid(),
          'eventId', '8c100000-0000-4000-8000-000000000001',
          'recurrenceId', '2026-07-13T00:00:00Z',
          'mode', 'modified',
          'overrideStartAt', '2026-07-13T03:00:00Z',
          'overrideEndAt', '2026-07-13T04:00:00Z',
          'overrideTitle', 'Moved routine'
        )
      ) response
    ) created
  $sql$,
  $sql$ values ('applied'::text, 'event_exception'::text, 1::bigint, 'Moved routine'::text) $sql$,
  'a private routine exception is created with a canonical versioned acknowledgement'
);

reset role;
select extensions.results_eq(
  $sql$
    select owner_user_id, event_id, mode, override_title, version, deleted_at is null
    from public.event_exceptions
    where id = '8d100000-0000-4000-8000-000000000001'
  $sql$,
  $sql$
    values (
      '81111111-1111-4111-8111-111111111111'::uuid,
      '8c100000-0000-4000-8000-000000000001'::uuid,
      'modified'::text,
      'Moved routine'::text,
      1::bigint,
      true
    )
  $sql$,
  'the server persists an owner-scoped exception snapshot'
);

set local role authenticated;
select extensions.ok(
  exists (
    select 1
    from jsonb_array_elements(public.get_schedule_delta(0, 500) -> 'changes') change
    where change ->> 'entityType' = 'event_exception'
      and change ->> 'entityId' = '8d100000-0000-4000-8000-000000000001'
      and change #>> '{payload,ownerUserId}' = auth.uid()::text
      and change #>> '{payload,overrideTitle}' = 'Moved routine'
      and change #>> '{payload,version}' = '1'
  ),
  'delta exposes only the canonical owner-scoped exception payload'
);

select extensions.ok(
  (public.apply_event_exception_mutation(
    'routine-exception-create',
    '8d100000-0000-4000-8000-000000000001',
    'create',
    null,
    jsonb_build_object(
      'id', '8d100000-0000-4000-8000-000000000001',
      'ownerUserId', auth.uid(),
      'eventId', '8c100000-0000-4000-8000-000000000001',
      'recurrenceId', '2026-07-13T00:00:00Z',
      'mode', 'modified',
      'overrideStartAt', '2026-07-13T03:00:00Z',
      'overrideEndAt', '2026-07-13T04:00:00Z',
      'overrideTitle', 'Moved routine'
    )
  ) ->> 'replayed')::boolean,
  'a replay returns the stored acknowledgement'
);

reset role;
select extensions.is(
  (
    select count(*)
    from private.schedule_change_log
    where owner_user_id = '81111111-1111-4111-8111-111111111111'
      and entity_type = 'event_exception'
      and entity_id = '8d100000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'an idempotent replay does not append another exception delta'
);

set local role authenticated;
select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      (response ->> 'server_version')::bigint,
      response #>> '{change,payload,overrideTitle}'
    from (
      select public.apply_event_exception_mutation(
        'routine-exception-update',
        '8d100000-0000-4000-8000-000000000001',
        'update',
        1,
        jsonb_build_object(
          'id', '8d100000-0000-4000-8000-000000000001',
          'ownerUserId', auth.uid(),
          'eventId', '8c100000-0000-4000-8000-000000000001',
          'recurrenceId', '2026-07-13T00:00:00Z',
          'mode', 'modified',
          'overrideStartAt', '2026-07-13T05:00:00Z',
          'overrideEndAt', '2026-07-13T06:00:00Z',
          'overrideTitle', 'Updated routine'
        )
      ) response
    ) updated
  $sql$,
  $sql$ values ('applied'::text, 2::bigint, 'Updated routine'::text) $sql$,
  'a matching version updates the exception and produces version two'
);

select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      (response ->> 'server_version')::bigint
    from (
      select public.apply_event_exception_mutation(
        'routine-exception-stale-update',
        '8d100000-0000-4000-8000-000000000001',
        'update',
        1,
        jsonb_build_object(
          'id', '8d100000-0000-4000-8000-000000000001',
          'ownerUserId', auth.uid(),
          'eventId', '8c100000-0000-4000-8000-000000000001',
          'recurrenceId', '2026-07-13T00:00:00Z',
          'mode', 'cancelled'
        )
      ) response
    ) stale
  $sql$,
  $sql$ values ('conflict'::text, 2::bigint) $sql$,
  'a stale version returns the canonical conflict state'
);

select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      (response ->> 'server_version')::bigint,
      response ->> 'deleted_at' is not null,
      response #>> '{change,operation}'
    from (
      select public.apply_event_exception_mutation(
        'routine-exception-delete',
        '8d100000-0000-4000-8000-000000000001',
        'delete',
        2,
        jsonb_build_object(
          'id', '8d100000-0000-4000-8000-000000000001',
          'ownerUserId', auth.uid()
        )
      ) response
    ) deleted
  $sql$,
  $sql$ values ('applied'::text, 3::bigint, true, 'delete'::text) $sql$,
  'delete preserves a versioned exception tombstone'
);

reset role;
select extensions.ok(
  exists (
    select 1
    from public.event_exceptions
    where id = '8d100000-0000-4000-8000-000000000001'
      and version = 3
      and deleted_at is not null
  ),
  'the exception tombstone persists for a fresh device delta'
);

set local role authenticated;
select extensions.is(
  public.apply_event_exception_mutation(
    'routine-exception-recreate',
    '8d100000-0000-4000-8000-000000000002',
    'create',
    null,
    jsonb_build_object(
      'id', '8d100000-0000-4000-8000-000000000002',
      'ownerUserId', auth.uid(),
      'eventId', '8c100000-0000-4000-8000-000000000001',
      'recurrenceId', '2026-07-13T00:00:00Z',
      'mode', 'cancelled'
    )
  ) ->> 'outcome',
  'applied'::text,
  'a deleted exception does not block a later replacement for the same occurrence'
);

select extensions.throws_ok(
  $sql$
    select public.apply_event_exception_mutation(
      'routine-exception-before-dtstart',
      '8d100000-0000-4000-8000-000000000011',
      'create',
      null,
      jsonb_build_object(
        'id', '8d100000-0000-4000-8000-000000000011',
        'ownerUserId', auth.uid(),
        'eventId', '8c100000-0000-4000-8000-000000000001',
        'recurrenceId', '2026-06-29T00:00:00Z',
        'mode', 'cancelled'
      )
    )
  $sql$,
  '22023',
  'recurrence identifier is not a routine occurrence',
  'an exception cannot target an instant before DTSTART'
);

select extensions.throws_ok(
  $sql$
    select public.apply_event_exception_mutation(
      'routine-exception-wrong-weekday',
      '8d100000-0000-4000-8000-000000000012',
      'create',
      null,
      jsonb_build_object(
        'id', '8d100000-0000-4000-8000-000000000012',
        'ownerUserId', auth.uid(),
        'eventId', '8c100000-0000-4000-8000-000000000001',
        'recurrenceId', '2026-07-14T00:00:00Z',
        'mode', 'cancelled'
      )
    )
  $sql$,
  '22023',
  'recurrence identifier is not a routine occurrence',
  'a weekly exception rejects a non-matching weekday'
);

select extensions.throws_ok(
  $sql$
    select public.apply_event_exception_mutation(
      'routine-exception-interval-mismatch',
      '8d100000-0000-4000-8000-000000000013',
      'create',
      null,
      jsonb_build_object(
        'id', '8d100000-0000-4000-8000-000000000013',
        'ownerUserId', auth.uid(),
        'eventId', '8c100000-0000-4000-8000-000000000004',
        'recurrenceId', '2026-07-13T00:00:00Z',
        'mode', 'cancelled'
      )
    )
  $sql$,
  '22023',
  'recurrence identifier is not a routine occurrence',
  'a biweekly exception rejects an in-between week'
);

select extensions.throws_ok(
  $sql$
    select public.apply_event_exception_mutation(
      'routine-exception-after-count',
      '8d100000-0000-4000-8000-000000000014',
      'create',
      null,
      jsonb_build_object(
        'id', '8d100000-0000-4000-8000-000000000014',
        'ownerUserId', auth.uid(),
        'eventId', '8c100000-0000-4000-8000-000000000001',
        'recurrenceId', '2026-08-03T00:00:00Z',
        'mode', 'cancelled'
      )
    )
  $sql$,
  '22023',
  'recurrence identifier is not a routine occurrence',
  'a recurrence identifier after COUNT is rejected'
);

select extensions.throws_ok(
  $sql$
    select public.apply_event_exception_mutation(
      'routine-exception-after-until',
      '8d100000-0000-4000-8000-000000000015',
      'create',
      null,
      jsonb_build_object(
        'id', '8d100000-0000-4000-8000-000000000015',
        'ownerUserId', auth.uid(),
        'eventId', '8c100000-0000-4000-8000-000000000005',
        'recurrenceId', '2026-07-09T00:00:00Z',
        'mode', 'cancelled'
      )
    )
  $sql$,
  '22023',
  'recurrence identifier is not a routine occurrence',
  'an offset-less local UNTIL still bounds routine exceptions'
);

select extensions.is(
  public.apply_event_exception_mutation(
    'routine-exception-multi-byday-fourth',
    '8d100000-0000-4000-8000-000000000016',
    'create',
    null,
    jsonb_build_object(
      'id', '8d100000-0000-4000-8000-000000000016',
      'ownerUserId', auth.uid(),
      'eventId', '8c100000-0000-4000-8000-000000000006',
      'recurrenceId', '2026-07-13T00:00:00Z',
      'mode', 'cancelled'
    )
  ) ->> 'outcome',
  'applied'::text,
  'multi-BYDAY COUNT ordering accepts the exact fourth emitted occurrence'
);

select extensions.is(
  public.apply_event_exception_mutation(
    'routine-exception-month-end-clamp',
    '8d100000-0000-4000-8000-000000000017',
    'create',
    null,
    jsonb_build_object(
      'id', '8d100000-0000-4000-8000-000000000017',
      'ownerUserId', auth.uid(),
      'eventId', '8c100000-0000-4000-8000-000000000010',
      'recurrenceId', '2026-02-28T00:00:00Z',
      'mode', 'cancelled'
    )
  ) ->> 'outcome',
  'applied'::text,
  'monthly month-day recurrence accepts the app''s end-of-month clamp'
);

select extensions.is(
  public.apply_event_exception_mutation(
    'routine-exception-nth-spill',
    '8d100000-0000-4000-8000-000000000018',
    'create',
    null,
    jsonb_build_object(
      'id', '8d100000-0000-4000-8000-000000000018',
      'ownerUserId', auth.uid(),
      'eventId', '8c100000-0000-4000-8000-000000000011',
      'recurrenceId', '2026-03-02T00:00:00Z',
      'mode', 'cancelled'
    )
  ) ->> 'outcome',
  'applied'::text,
  'fifth-weekday recurrence accepts the app''s next-month spill'
);

select extensions.is(
  public.apply_event_exception_mutation(
    'routine-exception-weekday-count-valid',
    '8d100000-0000-4000-8000-000000000019',
    'create',
    null,
    jsonb_build_object(
      'id', '8d100000-0000-4000-8000-000000000019',
      'ownerUserId', auth.uid(),
      'eventId', '8c100000-0000-4000-8000-000000000012',
      'recurrenceId', '2026-07-06T00:00:00Z',
      'mode', 'cancelled'
    )
  ) ->> 'outcome',
  'applied'::text,
  'weekday-only COUNT advances over the weekend without emitting it'
);

select extensions.throws_ok(
  $sql$
    select public.apply_event_exception_mutation(
      'routine-exception-weekday-count-after-limit',
      '8d100000-0000-4000-8000-000000000020',
      'create',
      null,
      jsonb_build_object(
        'id', '8d100000-0000-4000-8000-000000000020',
        'ownerUserId', auth.uid(),
        'eventId', '8c100000-0000-4000-8000-000000000012',
        'recurrenceId', '2026-07-07T00:00:00Z',
        'mode', 'cancelled'
      )
    )
  $sql$,
  '22023',
  'recurrence identifier is not a routine occurrence',
  'weekday-only COUNT rejects the next weekday after its final emission'
);

select extensions.results_eq(
  $sql$
    with winner as (
      select public.apply_event_exception_mutation(
        'routine-exception-race-winner',
        '8d100000-0000-4000-8000-000000000021',
        'create',
        null,
        jsonb_build_object(
          'id', '8d100000-0000-4000-8000-000000000021',
          'ownerUserId', auth.uid(),
          'eventId', '8c100000-0000-4000-8000-000000000001',
          'recurrenceId', '2026-07-20T00:00:00Z',
          'mode', 'cancelled'
        )
      ) response
    ),
    loser as (
      select public.apply_event_exception_mutation(
        'routine-exception-race-loser',
        '8d100000-0000-4000-8000-000000000022',
        'create',
        null,
        jsonb_build_object(
          'id', '8d100000-0000-4000-8000-000000000022',
          'ownerUserId', auth.uid(),
          'eventId', '8c100000-0000-4000-8000-000000000001',
          'recurrenceId', '2026-07-20T00:00:00Z',
          'mode', 'cancelled'
        )
      ) response
      from winner
    )
    select
      response ->> 'outcome',
      response ->> 'entity_id',
      response #>> '{change,operation}',
      (response ->> 'deleted_at') is not null,
      (response #>> '{change,payload,deletedAt}') is not null
    from loser
  $sql$,
  $sql$
    values (
      'conflict'::text,
      '8d100000-0000-4000-8000-000000000022'::text,
      'delete'::text,
      true,
      true
    )
  $sql$,
  'two offline creates for one occurrence return a canonical loser tombstone'
);

-- Raw table reads are administrative test observations; restore the app role
-- immediately afterwards so mutation and delta assertions still use RLS.
reset role;
select extensions.is(
  (
    select count(*)
    from public.event_exceptions
    where event_id = '8c100000-0000-4000-8000-000000000001'
      and recurrence_id = '2026-07-20T00:00:00Z'::timestamptz
      and deleted_at is null
  ),
  1::bigint,
  'the race loser tombstone never creates a second active occurrence exception'
);

set local role authenticated;
select extensions.ok(
  (public.apply_event_exception_mutation(
    'routine-exception-race-loser',
    '8d100000-0000-4000-8000-000000000022',
    'create',
    null,
    jsonb_build_object(
      'id', '8d100000-0000-4000-8000-000000000022',
      'ownerUserId', auth.uid(),
      'eventId', '8c100000-0000-4000-8000-000000000001',
      'recurrenceId', '2026-07-20T00:00:00Z',
      'mode', 'cancelled'
    )
  ) ->> 'replayed')::boolean
  and (
    select count(*)
    from jsonb_array_elements(public.get_schedule_delta(0, 500) -> 'changes') change
    where change ->> 'entityType' = 'event_exception'
      and change ->> 'entityId' = '8d100000-0000-4000-8000-000000000022'
  ) = 1,
  'the terminal duplicate conflict replays without another loser tombstone delta'
);

select extensions.results_eq(
  $sql$
    with created as (
      select public.apply_event_exception_mutation(
        'routine-exception-update-collision-create',
        '8d100000-0000-4000-8000-000000000023',
        'create',
        null,
        jsonb_build_object(
          'id', '8d100000-0000-4000-8000-000000000023',
          'ownerUserId', auth.uid(),
          'eventId', '8c100000-0000-4000-8000-000000000001',
          'recurrenceId', '2026-07-27T00:00:00Z',
          'mode', 'cancelled'
        )
      ) response
    ),
    collided as (
      select public.apply_event_exception_mutation(
        'routine-exception-update-collision',
        '8d100000-0000-4000-8000-000000000023',
        'update',
        1,
        jsonb_build_object(
          'id', '8d100000-0000-4000-8000-000000000023',
          'ownerUserId', auth.uid(),
          'eventId', '8c100000-0000-4000-8000-000000000001',
          'recurrenceId', '2026-07-20T00:00:00Z',
          'mode', 'cancelled'
        )
      ) response
      from created
    )
    select
      (select response ->> 'outcome' from created),
      response ->> 'outcome',
      (response #>> '{change,payload,recurrenceId}')::timestamptz
    from collided
  $sql$,
  $sql$
    values (
      'applied'::text,
      'conflict'::text,
      '2026-07-27T00:00:00Z'::timestamptz
    )
  $sql$,
  'an update collision returns the caller entity''s own canonical current row'
);

select extensions.throws_ok(
  $sql$
    select public.apply_event_exception_mutation(
      'routine-exception-empty-modification',
      '8d100000-0000-4000-8000-000000000003',
      'create',
      null,
      jsonb_build_object(
        'id', '8d100000-0000-4000-8000-000000000003',
        'ownerUserId', auth.uid(),
        'eventId', '8c100000-0000-4000-8000-000000000001',
        'recurrenceId', '2026-07-20T00:00:00Z',
        'mode', 'modified'
      )
    )
  $sql$,
  '22023',
  'modified occurrence requires an override',
  'a modified exception needs a real override'
);

select extensions.throws_ok(
  $sql$
    select public.apply_event_exception_mutation(
      'routine-exception-normal-event',
      '8d100000-0000-4000-8000-000000000004',
      'create',
      null,
      jsonb_build_object(
        'id', '8d100000-0000-4000-8000-000000000004',
        'ownerUserId', auth.uid(),
        'eventId', '8c100000-0000-4000-8000-000000000003',
        'recurrenceId', '2026-07-13T02:00:00Z',
        'mode', 'cancelled'
      )
    )
  $sql$,
  '22023',
  'exceptions require an active routine',
  'a normal personal event cannot receive a routine exception'
);

select extensions.throws_ok(
  $sql$
    select public.apply_event_exception_mutation(
      'routine-exception-owner-mismatch',
      '8d100000-0000-4000-8000-000000000005',
      'create',
      null,
      jsonb_build_object(
        'id', '8d100000-0000-4000-8000-000000000005',
        'ownerUserId', '82222222-2222-4222-8222-222222222222',
        'eventId', '8c100000-0000-4000-8000-000000000001',
        'recurrenceId', '2026-07-20T00:00:00Z',
        'mode', 'cancelled'
      )
    )
  $sql$,
  '42501',
  'payload owner mismatch',
  'the transport owner assertion cannot be forged'
);

set local request.jwt.claims = '{"sub":"82222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '82222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
select extensions.throws_ok(
  $sql$
    select public.apply_event_exception_mutation(
      'routine-exception-foreign-event',
      '8d200000-0000-4000-8000-000000000006',
      'create',
      null,
      jsonb_build_object(
        'id', '8d200000-0000-4000-8000-000000000006',
        'ownerUserId', auth.uid(),
        'eventId', '8c100000-0000-4000-8000-000000000001',
        'recurrenceId', '2026-07-20T00:00:00Z',
        'mode', 'cancelled'
      )
    )
  $sql$,
  '42501',
  'owned personal event is required',
  'another user cannot attach an exception to a foreign routine'
);

select extensions.is_empty(
  $sql$
    select change
    from jsonb_array_elements(public.get_schedule_delta(0, 500) -> 'changes') change
    where change ->> 'entityType' = 'event_exception'
  $sql$,
  'another user cannot pull private routine exception deltas'
);

reset role;
select extensions.ok(
  not exists (
    select 1
    from private.schedule_change_log
    where owner_user_id = '82222222-2222-4222-8222-222222222222'
      and entity_type = 'event_exception'
  ),
  'failed foreign attempts never append a cross-tenant exception change'
);

select * from extensions.finish();
rollback;
