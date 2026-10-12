begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(78);

-- Two deterministic tenants. Auth bootstrap owns profile creation; all other
-- fixture construction runs as postgres so only the assertions exercise ACLs.
insert into auth.users (id)
values
  ('61111111-1111-4111-8111-111111111111'),
  ('62222222-2222-4222-8222-222222222222');

insert into public.universities (
  id, config_key, name, normalized_name, status
)
values (
  '26b72fcd-6e61-5d0f-9c77-350762f2562f',
  'sync-test-university-b',
  'Sync Test University B',
  'synctestuniversityb',
  'active'
);

update public.profiles
set university_id = case user_id
  when '61111111-1111-4111-8111-111111111111'::uuid
    then '26a72fcd-6e61-5d0f-9c77-350762f2562f'::uuid
  else '26b72fcd-6e61-5d0f-9c77-350762f2562f'::uuid
end
where user_id in (
  '61111111-1111-4111-8111-111111111111',
  '62222222-2222-4222-8222-222222222222'
);

insert into public.terms (
  id, university_id, name, academic_year, start_date, end_date, term_type,
  created_by, is_template, owner_user_id, status
)
values
  (
    'a1000000-0000-4000-8000-000000000001',
    '26a72fcd-6e61-5d0f-9c77-350762f2562f',
    'Sync term A', 2026, '2026-04-01', '2026-09-30', 'semester',
    '61111111-1111-4111-8111-111111111111', false,
    '61111111-1111-4111-8111-111111111111', 'active'
  ),
  (
    'a2000000-0000-4000-8000-000000000002',
    '26b72fcd-6e61-5d0f-9c77-350762f2562f',
    'Sync term B', 2026, '2026-04-01', '2026-09-30', 'semester',
    '62222222-2222-4222-8222-222222222222', false,
    '62222222-2222-4222-8222-222222222222', 'active'
  );

insert into public.course_templates (
  id, university_id, academic_year, title, normalized_title, status
)
values
  (
    '91000000-0000-4000-8000-000000000001',
    '26a72fcd-6e61-5d0f-9c77-350762f2562f',
    2026, 'Template A', 'templatea', 'active'
  ),
  (
    '92000000-0000-4000-8000-000000000002',
    '26b72fcd-6e61-5d0f-9c77-350762f2562f',
    2026, 'Template B', 'templateb', 'active'
  );

insert into public.groups (
  id, owner_user_id, name, default_visibility
)
values (
  '71000000-0000-4000-8000-000000000001',
  '61111111-1111-4111-8111-111111111111',
  'Tenant A group',
  'PRIVATE'
);

insert into public.calendars (
  id, owner_user_id, group_id, name, default_visibility
)
values
  (
    'b1000000-0000-4000-8000-000000000001',
    '61111111-1111-4111-8111-111111111111',
    null, 'Personal A', 'PRIVATE'
  ),
  (
    'b1000000-0000-4000-8000-000000000009',
    '61111111-1111-4111-8111-111111111111',
    '71000000-0000-4000-8000-000000000001',
    'Group A', 'PRIVATE'
  ),
  (
    'b2000000-0000-4000-8000-000000000002',
    '62222222-2222-4222-8222-222222222222',
    null, 'Personal B', 'PRIVATE'
  );

-- Represents a row which already exists when a fresh device starts at cursor
-- zero. Server-originated writes must use the same change trigger as the RPC.
insert into public.user_courses (
  id, owner_user_id, term_id, title, normalized_title, day_of_week,
  period_no, visibility_level
)
values (
  'c1000000-0000-4000-8000-000000000010',
  '61111111-1111-4111-8111-111111111111',
  'a1000000-0000-4000-8000-000000000001',
  'Preexisting course', 'preexistingcourse', 5, 5, 'PRIVATE'
);

-- Public/anonymous callers receive neither RPC execution nor raw sync data.
select extensions.ok(
  not pg_catalog.has_function_privilege(
    'anon',
    'public.apply_schedule_mutation(text,text,uuid,text,bigint,jsonb)',
    'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'anon', 'public.get_schedule_delta(bigint,integer)', 'EXECUTE'
  ),
  'anonymous role cannot execute either schedule-sync RPC'
);

select extensions.ok(
  pg_catalog.has_function_privilege(
    'authenticated',
    'public.apply_schedule_mutation(text,text,uuid,text,bigint,jsonb)',
    'EXECUTE'
  )
  and pg_catalog.has_function_privilege(
    'authenticated', 'public.get_schedule_delta(bigint,integer)', 'EXECUTE'
  ),
  'authenticated role can execute the two schedule-sync RPCs'
);

select extensions.ok(
  not pg_catalog.has_table_privilege(
    'authenticated', 'private.schedule_mutation_receipts', 'SELECT'
  )
  and not pg_catalog.has_table_privilege(
    'authenticated', 'private.schedule_cursor_heads', 'SELECT'
  )
  and not pg_catalog.has_table_privilege(
    'authenticated', 'private.schedule_change_log', 'SELECT'
  ),
  'receipt ledger, per-owner cursor heads, and change log are private'
);

select extensions.ok(
  not pg_catalog.has_table_privilege('authenticated', 'public.user_courses', 'INSERT')
  and not pg_catalog.has_table_privilege('authenticated', 'public.assignments', 'INSERT')
  and not pg_catalog.has_table_privilege('authenticated', 'public.assignment_user_states', 'INSERT')
  and not pg_catalog.has_table_privilege('authenticated', 'public.exams', 'INSERT')
  and not pg_catalog.has_table_privilege('authenticated', 'public.events', 'INSERT'),
  'authenticated clients have no direct insert path for synced entities'
);

select extensions.ok(
  pg_catalog.has_table_privilege(
    'authenticated', 'public.calendars', 'SELECT'
  )
  and not pg_catalog.has_table_privilege(
    'authenticated', 'public.calendars', 'INSERT'
  )
  and not pg_catalog.has_table_privilege(
    'authenticated', 'public.calendars', 'UPDATE'
  )
  and not pg_catalog.has_table_privilege(
    'authenticated', 'public.calendars', 'DELETE'
  ),
  'authenticated clients can hydrate an RLS-scoped calendar but not mutate it'
);

-- Tenant A creates every supported entity through the authenticated RPC.
set local request.jwt.claims = '{"sub":"61111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '61111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.results_eq(
  $sql$
    select id
    from public.calendars
    order by id
  $sql$,
  $sql$
    values
      ('b1000000-0000-4000-8000-000000000001'::uuid),
      ('b1000000-0000-4000-8000-000000000009'::uuid)
  $sql$,
  'calendar hydration returns only tenant A owned rows'
);

select extensions.ok(
  public.copy_course_template(
    '91000000-0000-4000-8000-000000000001',
    'a1000000-0000-4000-8000-000000000001'
  ) = public.copy_course_template(
    '91000000-0000-4000-8000-000000000001',
    'a1000000-0000-4000-8000-000000000001'
  ),
  'template copy is naturally idempotent for caller/template/term'
);

select extensions.throws_ok(
  $sql$
    select public.copy_course_template(
      '91000000-0000-4000-8000-000000000001',
      'a2000000-0000-4000-8000-000000000002'
    )
  $sql$,
  '42501',
  'owned active target term is required',
  'template copy rejects another tenant target term'
);

select extensions.throws_ok(
  $sql$
    select public.apply_schedule_mutation(
      'sync-a-cross-university-template', 'user_course',
      'c1000000-0000-4000-8000-000000000099', 'create', null,
      jsonb_build_object(
        'id', 'c1000000-0000-4000-8000-000000000099',
        'ownerUserId', auth.uid(),
        'termId', 'a1000000-0000-4000-8000-000000000001',
        'sourceTemplateId', '92000000-0000-4000-8000-000000000002',
        'title', 'Cross university template'
      )
    )
  $sql$,
  '42501',
  'course template is not available for this university',
  'schedule mutation rejects a cross-university source template'
);

select extensions.throws_ok(
  $sql$
    select public.apply_schedule_mutation(
      'sync-a-group-calendar-event', 'event',
      'f1000000-0000-4000-8000-000000000099', 'create', null,
      jsonb_build_object(
        'id', 'f1000000-0000-4000-8000-000000000099',
        'ownerUserId', auth.uid(),
        'calendarId', 'b1000000-0000-4000-8000-000000000009',
        'title', 'Invalid personal group-calendar event',
        'startAt', '2026-07-15T07:00:00Z',
        'endAt', '2026-07-15T08:00:00Z'
      )
    )
  $sql$,
  '42501',
  'owned active calendar is required',
  'personal sync rejects an owned group calendar'
);

select extensions.throws_ok(
  $sql$
    select public.apply_schedule_mutation(
      'sync-a-invalid-exam-range', 'exam',
      'e1000000-0000-4000-8000-000000000099', 'create', null,
      jsonb_build_object(
        'id', 'e1000000-0000-4000-8000-000000000099',
        'ownerUserId', auth.uid(),
        'title', 'Invalid exam range',
        'startAt', '2026-07-25T02:00:00Z',
        'endAt', '2026-07-25T01:00:00Z'
      )
    )
  $sql$,
  '23514',
  'new row for relation "exams" violates check constraint "exams_end_at_after_start_check"',
  'schedule mutation rejects an exam whose end is not after its start'
);

select extensions.is(
  public.apply_schedule_mutation(
    'sync-a-course-create', 'user_course',
    'c1000000-0000-4000-8000-000000000001', 'create', null,
    jsonb_build_object(
      'id', 'c1000000-0000-4000-8000-000000000001',
      'ownerUserId', auth.uid(),
      'termId', 'a1000000-0000-4000-8000-000000000001',
      'sourceTemplateId', '91000000-0000-4000-8000-000000000001',
      'title', 'Distributed Systems',
      'instructorName', 'Professor A',
      'dayOfWeek', 1,
      'periodNo', 2,
      'room', 'A101'
    )
  ) ->> 'outcome',
  'applied',
  'user course create is applied'
);

select extensions.is(
  public.apply_schedule_mutation(
    'sync-a-assignment-create', 'assignment',
    'd1000000-0000-4000-8000-000000000001', 'create', null,
    jsonb_build_object(
      'id', 'd1000000-0000-4000-8000-000000000001',
      'ownerUserId', auth.uid(),
      'courseId', 'c1000000-0000-4000-8000-000000000001',
      'title', 'Sync report',
      'dueAt', '2026-07-20T03:00:00Z',
      'memo', 'first draft',
      'priority', 'high'
    )
  ) ->> 'outcome',
  'applied',
  'assignment create is applied'
);

select extensions.is(
  public.apply_schedule_mutation(
    'sync-a-state-submit', 'assignment_user_state',
    'd1000000-0000-4000-8000-000000000001', 'submit', null,
    jsonb_build_object(
      'assignmentId', 'd1000000-0000-4000-8000-000000000001',
      'userId', auth.uid(),
      'status', 'submitted',
      'submittedAt', '2026-07-18T01:00:00Z',
      'note', 'uploaded'
    )
  ) ->> 'outcome',
  'applied',
  'assignment state submit is applied'
);

-- A personal progress state is created independently from submit. This keeps
-- submitted_at null until the student explicitly records a submission.
select extensions.is(
  public.apply_schedule_mutation(
    'sync-a-progress-assignment-create', 'assignment',
    'd1000000-0000-4000-8000-000000000002', 'create', null,
    jsonb_build_object(
      'id', 'd1000000-0000-4000-8000-000000000002',
      'ownerUserId', auth.uid(),
      'courseId', 'c1000000-0000-4000-8000-000000000001',
      'title', 'Progress lifecycle report',
      'dueAt', '2026-07-21T03:00:00Z'
    )
  ) ->> 'outcome',
  'applied',
  'progress-lifecycle assignment create is applied'
);

select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      response ->> 'entity_type',
      response ->> 'operation',
      response #>> '{change,operation}',
      response #>> '{change,payload,status}',
      response #>> '{change,payload,submittedAt}' is null,
      (response ->> 'server_version')::bigint,
      response ->> 'deleted_at' is null
    from (
      select public.apply_schedule_mutation(
        'sync-a-progress-state-create', 'assignment_user_state',
        'd1000000-0000-4000-8000-000000000002', 'create', null,
        jsonb_build_object(
          'assignmentId', 'd1000000-0000-4000-8000-000000000002',
          'userId', auth.uid(),
          'status', 'inProgress',
          'submittedAt', null
        )
      ) response
    ) created
  $sql$,
  $sql$ values (
    'applied'::text,
    'assignment_user_state'::text,
    'create'::text,
    'upsert'::text,
    'inProgress'::text,
    true::boolean,
    1::bigint,
    true::boolean
  ) $sql$,
  'in-progress state create has a canonical create acknowledgement'
);

reset role;

select extensions.results_eq(
  $sql$
    select status, submitted_at is null, version, deleted_at is null
    from public.assignment_user_states
    where assignment_id = 'd1000000-0000-4000-8000-000000000002'
      and user_id = '61111111-1111-4111-8111-111111111111'
  $sql$,
  $sql$ values ('inProgress'::text, true::boolean, 1::bigint, true::boolean) $sql$,
  'in-progress state is persisted without a submission timestamp'
);

set local role authenticated;

select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      response ->> 'operation',
      (response ->> 'replayed')::boolean,
      (response ->> 'server_version')::bigint
    from (
      select public.apply_schedule_mutation(
        'sync-a-progress-state-create', 'assignment_user_state',
        'd1000000-0000-4000-8000-000000000002', 'create', null,
        jsonb_build_object(
          'assignmentId', 'd1000000-0000-4000-8000-000000000002',
          'userId', auth.uid(),
          'status', 'inProgress',
          'submittedAt', null
        )
      ) response
    ) replayed
  $sql$,
  $sql$ values ('applied'::text, 'create'::text, true::boolean, 1::bigint) $sql$,
  'in-progress create is exactly replayable'
);

select extensions.is(
  public.apply_schedule_mutation(
    'sync-a-progress-state-not-started', 'assignment_user_state',
    'd1000000-0000-4000-8000-000000000002', 'update', 1,
    jsonb_build_object(
      'assignmentId', 'd1000000-0000-4000-8000-000000000002',
      'userId', auth.uid(),
      'status', 'notStarted',
      'submittedAt', null
    )
  ) ->> 'outcome',
  'applied',
  'in-progress state can return to not-started'
);

select extensions.is(
  public.apply_schedule_mutation(
    'sync-a-progress-state-submit', 'assignment_user_state',
    'd1000000-0000-4000-8000-000000000002', 'submit', 2,
    jsonb_build_object(
      'assignmentId', 'd1000000-0000-4000-8000-000000000002',
      'userId', auth.uid(),
      'status', 'submitted',
      'submittedAt', '2026-07-19T01:00:00Z'
    )
  ) ->> 'outcome',
  'applied',
  'not-started state can be submitted'
);

select extensions.is(
  public.apply_schedule_mutation(
    'sync-a-progress-state-reopen', 'assignment_user_state',
    'd1000000-0000-4000-8000-000000000002', 'update', 3,
    jsonb_build_object(
      'assignmentId', 'd1000000-0000-4000-8000-000000000002',
      'userId', auth.uid(),
      'status', 'inProgress',
      'submittedAt', null
    )
  ) ->> 'outcome',
  'applied',
  'submitted state can reopen as in-progress'
);

select extensions.is(
  public.apply_schedule_mutation(
    'sync-a-progress-state-delete', 'assignment_user_state',
    'd1000000-0000-4000-8000-000000000002', 'delete', 4,
    jsonb_build_object(
      'assignmentId', 'd1000000-0000-4000-8000-000000000002',
      'userId', auth.uid()
    )
  ) ->> 'outcome',
  'applied',
  'progress state delete creates a tombstone'
);

select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      response ->> 'operation',
      response #>> '{change,operation}',
      (response ->> 'server_version')::bigint,
      response ->> 'deleted_at' is null
    from (
      select public.apply_schedule_mutation(
        'sync-a-progress-state-resurrect', 'assignment_user_state',
        'd1000000-0000-4000-8000-000000000002', 'update', 5,
        jsonb_build_object(
          'assignmentId', 'd1000000-0000-4000-8000-000000000002',
          'userId', auth.uid(),
          'status', 'inProgress',
          'submittedAt', null
        )
      ) response
    ) resurrected
  $sql$,
  $sql$ values (
    'applied'::text,
    'update'::text,
    'upsert'::text,
    6::bigint,
    true::boolean
  ) $sql$,
  'versioned non-submitted update resurrects a state tombstone'
);

reset role;

select extensions.results_eq(
  $sql$
    select status, submitted_at is null, version, deleted_at is null
    from public.assignment_user_states
    where assignment_id = 'd1000000-0000-4000-8000-000000000002'
      and user_id = '61111111-1111-4111-8111-111111111111'
  $sql$,
  $sql$ values ('inProgress'::text, true::boolean, 6::bigint, true::boolean) $sql$,
  'resurrected state clears submitted timestamp and retains canonical version'
);

set local role authenticated;

select extensions.throws_ok(
  $sql$
    select public.apply_schedule_mutation(
      'sync-a-progress-state-invalid-create', 'assignment_user_state',
      'd1000000-0000-4000-8000-000000000002', 'create', null,
      jsonb_build_object(
        'assignmentId', 'd1000000-0000-4000-8000-000000000002',
        'userId', auth.uid(),
        'status', 'submitted'
      )
    )
  $sql$,
  '22023',
  'assignment state create requires an in-progress status',
  'state create rejects a submitted status'
);

select extensions.throws_ok(
  $sql$
    select public.apply_schedule_mutation(
      'sync-a-progress-state-invalid-update', 'assignment_user_state',
      'd1000000-0000-4000-8000-000000000002', 'update', 6,
      jsonb_build_object(
        'assignmentId', 'd1000000-0000-4000-8000-000000000002',
        'userId', auth.uid(),
        'status', 'inProgress',
        'submittedAt', '2026-07-19T02:00:00Z'
      )
    )
  $sql$,
  '22023',
  'non-submitted assignment state cannot have a submitted timestamp',
  'non-submitted update rejects a submission timestamp'
);

select extensions.is(
  public.apply_schedule_mutation(
    'sync-a-exam-create', 'exam',
    'e1000000-0000-4000-8000-000000000001', 'create', null,
    jsonb_build_object(
      'id', 'e1000000-0000-4000-8000-000000000001',
      'ownerUserId', auth.uid(),
      'courseId', 'c1000000-0000-4000-8000-000000000001',
      'title', 'Midterm',
      'startAt', '2026-07-25T01:00:00Z',
      'endAt', '2026-07-25T02:00:00Z',
      'room', 'B203',
      'scope', 'Units 1-5',
      'memo', 'bring pencil',
      'examType', 'written'
    )
  ) ->> 'outcome',
  'applied',
  'exam create is applied'
);

select extensions.is(
  public.apply_schedule_mutation(
    'sync-a-event-create', 'event',
    'f1000000-0000-4000-8000-000000000001', 'create', null,
    jsonb_build_object(
      'id', 'f1000000-0000-4000-8000-000000000001',
      'ownerUserId', auth.uid(),
      'calendarId', 'b1000000-0000-4000-8000-000000000001',
      'title', 'Study session',
      'kind', 'normal',
      'startAt', '2026-07-15T05:00:00Z',
      'endAt', '2026-07-15T06:00:00Z',
      'location', 'Library'
    )
  ) ->> 'outcome',
  'applied',
  'personal event create is applied'
);

reset role;

select extensions.ok(
  (
    select count(*)
    from public.course_template_copy_events
    where template_id = '91000000-0000-4000-8000-000000000001'
      and copied_by = '61111111-1111-4111-8111-111111111111'
  ) = 1
  and (
    select copy_count_total
    from public.course_templates
    where id = '91000000-0000-4000-8000-000000000001'
  ) = 1,
  'idempotent template-copy replay records and counts exactly one copy'
);

select extensions.results_eq(
  $sql$
    select owner_user_id, version, visibility_level::text
    from public.user_courses
    where id = 'c1000000-0000-4000-8000-000000000001'
  $sql$,
  $sql$
    values (
      '61111111-1111-4111-8111-111111111111'::uuid,
      1::bigint,
      'PRIVATE'::text
    )
  $sql$,
  'course owner is auth-bound and visibility defaults PRIVATE'
);

select extensions.results_eq(
  $sql$
    select priority, version, visibility_level::text
    from public.assignments
    where id = 'd1000000-0000-4000-8000-000000000001'
  $sql$,
  $sql$ values ('high'::text, 1::bigint, 'PRIVATE'::text) $sql$,
  'assignment priority parity is persisted with private version one'
);

select extensions.results_eq(
  $sql$
    select status, version, deleted_at is null
    from public.assignment_user_states
    where assignment_id = 'd1000000-0000-4000-8000-000000000001'
      and user_id = '61111111-1111-4111-8111-111111111111'
  $sql$,
  $sql$ values ('submitted'::text, 1::bigint, true) $sql$,
  'assignment state has version and tombstone parity'
);

select extensions.results_eq(
  $sql$
    select memo, exam_type, visibility_level::text
    from public.exams
    where id = 'e1000000-0000-4000-8000-000000000001'
  $sql$,
  $sql$ values ('bring pencil'::text, 'written'::text, 'PRIVATE'::text) $sql$,
  'exam memo and exam-type parity is persisted privately'
);

select extensions.results_eq(
  $sql$
    select owner_user_id, created_by, group_id is null, visibility_level::text
    from public.events
    where id = 'f1000000-0000-4000-8000-000000000001'
  $sql$,
  $sql$
    values (
      '61111111-1111-4111-8111-111111111111'::uuid,
      '61111111-1111-4111-8111-111111111111'::uuid,
      true,
      'PRIVATE'::text
    )
  $sql$,
  'event owner/creator are server-bound and default visibility is PRIVATE'
);

-- Exact retry replays the stored canonical response without a second write.
set local role authenticated;

select extensions.ok(
  (
    public.apply_schedule_mutation(
      'sync-a-course-create', 'user_course',
      'c1000000-0000-4000-8000-000000000001', 'create', null,
      jsonb_build_object(
        'id', 'c1000000-0000-4000-8000-000000000001',
        'ownerUserId', auth.uid(),
        'termId', 'a1000000-0000-4000-8000-000000000001',
        'sourceTemplateId', '91000000-0000-4000-8000-000000000001',
        'title', 'Distributed Systems',
        'instructorName', 'Professor A',
        'dayOfWeek', 1,
        'periodNo', 2,
        'room', 'A101'
      )
    ) ->> 'replayed'
  )::boolean
  and (
    public.apply_schedule_mutation(
      'sync-a-course-create', 'user_course',
      'c1000000-0000-4000-8000-000000000001', 'create', null,
      jsonb_build_object(
        'id', 'c1000000-0000-4000-8000-000000000001',
        'ownerUserId', auth.uid(),
        'termId', 'a1000000-0000-4000-8000-000000000001',
        'sourceTemplateId', '91000000-0000-4000-8000-000000000001',
        'title', 'Distributed Systems',
        'instructorName', 'Professor A',
        'dayOfWeek', 1,
        'periodNo', 2,
        'room', 'A101'
      )
    ) ->> 'outcome'
  ) = 'applied',
  'identical idempotency retry replays the original applied result'
);

select extensions.throws_ok(
  $sql$
    select public.apply_schedule_mutation(
      'sync-a-course-create', 'user_course',
      'c1000000-0000-4000-8000-000000000001', 'create', null,
      jsonb_build_object(
        'id', 'c1000000-0000-4000-8000-000000000001',
        'ownerUserId', auth.uid(),
        'termId', 'a1000000-0000-4000-8000-000000000001',
        'title', 'Changed request',
        'dayOfWeek', 1,
        'periodNo', 2
      )
    )
  $sql$,
  '23505',
  'idempotency key was already used for another request',
  'changed request cannot reuse an idempotency key'
);

select extensions.throws_ok(
  $sql$
    select public.apply_schedule_mutation(
      'sync-a-owner-spoof', 'assignment',
      'd1000000-0000-4000-8000-000000000099', 'create', null,
      jsonb_build_object(
        'id', 'd1000000-0000-4000-8000-000000000099',
        'ownerUserId', '62222222-2222-4222-8222-222222222222',
        'title', 'Spoofed',
        'dueAt', '2026-07-30T00:00:00Z'
      )
    )
  $sql$,
  '42501',
  'payload owner mismatch',
  'payload owner spoof is rejected before mutation'
);

select extensions.throws_ok(
  $sql$
    select public.apply_schedule_mutation(
      'sync-a-state-spoof', 'assignment_user_state',
      'd1000000-0000-4000-8000-000000000001', 'submit', null,
      jsonb_build_object(
        'assignmentId', 'd1000000-0000-4000-8000-000000000001',
        'userId', '62222222-2222-4222-8222-222222222222',
        'status', 'submitted'
      )
    )
  $sql$,
  '42501',
  'payload user mismatch',
  'assignment-state user spoof is rejected'
);

-- Tenant B gets an independent entity/key namespace.
reset role;
set local request.jwt.claims = '{"sub":"62222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '62222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.results_eq(
  $sql$
    select id
    from public.calendars
    order by id
  $sql$,
  $sql$
    values ('b2000000-0000-4000-8000-000000000002'::uuid)
  $sql$,
  'calendar hydration returns only tenant B owned rows'
);

select extensions.is(
  public.apply_schedule_mutation(
    'sync-b-course-create', 'user_course',
    'c2000000-0000-4000-8000-000000000002', 'create', null,
    jsonb_build_object(
      'id', 'c2000000-0000-4000-8000-000000000002',
      'ownerUserId', auth.uid(),
      'termId', 'a2000000-0000-4000-8000-000000000002',
      'title', 'Tenant B course',
      'dayOfWeek', 2,
      'periodNo', 3
    )
  ) ->> 'outcome',
  'applied',
  'second tenant can create its own course'
);

reset role;

select extensions.is(
  (
    select min(change_cursor)
    from private.schedule_change_log
    where owner_user_id = '62222222-2222-4222-8222-222222222222'
  ),
  1::bigint,
  'each tenant receives an independent cursor namespace starting at one'
);

select extensions.ok(
  not exists (
    select 1
    from private.schedule_cursor_heads h
    where h.last_cursor is distinct from (
      select max(l.change_cursor)
      from private.schedule_change_log l
      where l.owner_user_id = h.owner_user_id
    )
  ),
  'per-owner cursor heads match the latest immutable change row'
);

set local request.jwt.claims = '{"sub":"61111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '61111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.throws_ok(
  $sql$
    select public.apply_schedule_mutation(
      'sync-a-cross-tenant', 'user_course',
      'c2000000-0000-4000-8000-000000000002', 'update', 1,
      jsonb_build_object(
        'id', 'c2000000-0000-4000-8000-000000000002',
        'ownerUserId', auth.uid(),
        'termId', 'a1000000-0000-4000-8000-000000000001',
        'title', 'Cross tenant write',
        'dayOfWeek', 2,
        'periodNo', 3
      )
    )
  $sql$,
  '42501',
  'schedule entity is unavailable',
  'cross-tenant entity update fails closed'
);

-- Optimistic update increments server version; stale retry returns a durable
-- conflict containing the canonical latest change instead of overwriting it.
select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      (response ->> 'server_version')::bigint,
      response #>> '{change,payload,title}',
      response #>> '{change,payload,priority}'
    from (
      select public.apply_schedule_mutation(
        'sync-a-assignment-update', 'assignment',
        'd1000000-0000-4000-8000-000000000001', 'update', 1,
        jsonb_build_object(
          'id', 'd1000000-0000-4000-8000-000000000001',
          'ownerUserId', auth.uid(),
          'courseId', 'c1000000-0000-4000-8000-000000000001',
          'title', 'Sync report revised',
          'dueAt', '2026-07-21T03:00:00Z',
          'memo', 'second draft',
          'priority', 'normal'
        )
      ) as response
    ) applied
  $sql$,
  $sql$ values ('applied'::text, 2::bigint, 'Sync report revised'::text, 'normal'::text) $sql$,
  'matching base version applies canonical assignment update at version two'
);

select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      (response ->> 'server_version')::bigint,
      response #>> '{change,payload,title}',
      response #>> '{change,payload,priority}'
    from (
      select public.apply_schedule_mutation(
        'sync-a-assignment-stale', 'assignment',
        'd1000000-0000-4000-8000-000000000001', 'update', 1,
        jsonb_build_object(
          'id', 'd1000000-0000-4000-8000-000000000001',
          'ownerUserId', auth.uid(),
          'courseId', 'c1000000-0000-4000-8000-000000000001',
          'title', 'Stale local title',
          'dueAt', '2026-07-22T03:00:00Z',
          'priority', 'low'
        )
      ) as response
    ) conflicted
  $sql$,
  $sql$ values ('conflict'::text, 2::bigint, 'Sync report revised'::text, 'normal'::text) $sql$,
  'stale base version returns the canonical current server change'
);

select extensions.is(
  public.apply_schedule_mutation(
    'sync-a-assignment-stale', 'assignment',
    'd1000000-0000-4000-8000-000000000001', 'update', 1,
    jsonb_build_object(
      'id', 'd1000000-0000-4000-8000-000000000001',
      'ownerUserId', auth.uid(),
      'courseId', 'c1000000-0000-4000-8000-000000000001',
      'title', 'Stale local title',
      'dueAt', '2026-07-22T03:00:00Z',
      'priority', 'low'
    )
  ) ->> 'replayed',
  'true',
  'conflict response itself is idempotently replayable'
);

select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      response #>> '{change,operation}',
      (response ->> 'server_version')::bigint,
      (response ->> 'deleted_at') is not null
    from (
      select public.apply_schedule_mutation(
        'sync-a-event-delete', 'event',
        'f1000000-0000-4000-8000-000000000001', 'delete', 1,
        jsonb_build_object(
          'id', 'f1000000-0000-4000-8000-000000000001',
          'ownerUserId', auth.uid()
        )
      ) as response
    ) deleted
  $sql$,
  $sql$ values ('applied'::text, 'delete'::text, 2::bigint, true) $sql$,
  'delete creates a versioned canonical tombstone'
);

reset role;

select extensions.ok(
  exists (
    select 1 from public.events
    where id = 'f1000000-0000-4000-8000-000000000001'
      and owner_user_id = '61111111-1111-4111-8111-111111111111'
      and version = 2
      and deleted_at is not null
  ),
  'soft-deleted event row remains available for delta reconciliation'
);

select extensions.ok(
  not exists (
    select 1
    from private.schedule_mutation_receipts r
    where r.response ->> 'server_version'
        is distinct from r.response #>> '{change,serverVersion}'
       or r.response ->> 'change_cursor'
        is distinct from r.response #>> '{change,changeCursor}'
       or r.response ->> 'entity_type'
        is distinct from r.response #>> '{change,entityType}'
       or r.response ->> 'entity_id'
        is distinct from r.response #>> '{change,entityId}'
       or r.response ->> 'deleted_at'
        is distinct from r.response #>> '{change,deletedAt}'
  ),
  'every stored acknowledgement is one internally consistent change snapshot'
);

select extensions.is(
  (
    select count(*) from private.schedule_mutation_receipts
    where owner_user_id = '61111111-1111-4111-8111-111111111111'
      and idempotency_key = 'sync-a-course-create'
  ),
  1::bigint,
  'identical delivery retains exactly one receipt'
);

select extensions.ok(
  exists (
    select 1 from private.schedule_mutation_receipts
    where owner_user_id = '61111111-1111-4111-8111-111111111111'
      and idempotency_key = 'sync-a-assignment-stale'
      and request_hash ~ '^[0-9a-f]{64}$'
      and response ->> 'outcome' = 'conflict'
      and response #>> '{change,payload,title}' = 'Sync report revised'
      and expires_at >= created_at + interval '89 days'
  ),
  'bounded receipt stores canonical hash/result but no request payload column'
);

select extensions.ok(
  not exists (
    select 1
    from information_schema.columns
    where table_schema = 'private'
      and table_name = 'schedule_mutation_receipts'
      and column_name in ('payload', 'request_payload')
  ),
  'receipt ledger never persists the submitted request payload'
);

-- Delta is owner-filtered, ordered, cursor-paginated, and includes both
-- initial server rows and delete tombstones.
set local role authenticated;

select extensions.ok(
  exists (
    select 1
    from jsonb_array_elements(
      public.get_schedule_delta(0, 200) -> 'changes'
    ) change
    where change ->> 'entityId' = 'c1000000-0000-4000-8000-000000000010'
      and change ->> 'entityType' = 'user_course'
  ),
  'cursor-zero initial pull contains a preexisting server row'
);

select extensions.ok(
  not exists (
    select 1
    from jsonb_array_elements(
      public.get_schedule_delta(0, 200) -> 'changes'
    ) change
    where change #>> '{payload,ownerUserId}'
      <> '61111111-1111-4111-8111-111111111111'
  ),
  'delta contains only the authenticated owner payloads'
);

select extensions.ok(
  not exists (
    select 1
    from (
      select
        (change ->> 'changeCursor')::bigint as cursor_value,
        lag((change ->> 'changeCursor')::bigint)
          over (order by ordinal) as prior_cursor
      from jsonb_array_elements(
        public.get_schedule_delta(0, 200) -> 'changes'
      ) with ordinality item(change, ordinal)
    ) ordered_changes
    where cursor_value <= prior_cursor
  ),
  'delta changes are strictly ordered by monotonic cursor'
);

select extensions.ok(
  exists (
    select 1
    from jsonb_array_elements(
      public.get_schedule_delta(0, 200) -> 'changes'
    ) change
    where change ->> 'entityId' = 'f1000000-0000-4000-8000-000000000001'
      and change ->> 'operation' = 'delete'
      and change ->> 'deletedAt' is not null
      and change #>> '{payload,deletedAt}' is not null
      and (change #>> '{payload,version}')::bigint = 2
  ),
  'delta exposes the event tombstone and canonical deleted payload'
);

select extensions.results_eq(
  $sql$
    select
      jsonb_array_length(page -> 'changes'),
      (page ->> 'has_more')::boolean
    from (select public.get_schedule_delta(0, 2) page) first_page
  $sql$,
  $sql$ values (2, true) $sql$,
  'bounded first page returns exactly the limit and advertises more rows'
);

select extensions.ok(
  (
    with first_page as (
      select public.get_schedule_delta(0, 2) page
    ), second_page as (
      select public.get_schedule_delta(
        (page ->> 'next_cursor')::bigint,
        2
      ) page,
      (page ->> 'next_cursor')::bigint prior_cursor
      from first_page
    )
    select min((change ->> 'changeCursor')::bigint) > prior_cursor
    from second_page,
      lateral jsonb_array_elements(page -> 'changes') change
    group by prior_cursor
  ),
  'next page begins strictly after the prior next_cursor'
);

select extensions.results_eq(
  $sql$
    with watermark as (
      select (public.get_schedule_delta(0, 200) ->> 'next_cursor')::bigint cursor_value
    )
    select
      jsonb_array_length(page -> 'changes'),
      (page ->> 'next_cursor')::bigint = cursor_value,
      (page ->> 'has_more')::boolean
    from watermark,
      lateral public.get_schedule_delta(cursor_value, 200) page
  $sql$,
  $sql$ values (0, true, false) $sql$,
  'empty delta retains the supplied cursor and has_more is false'
);

select extensions.ok(
  not exists (
    select 1
    from jsonb_array_elements(
      public.get_schedule_delta(0, 200) -> 'changes'
    ) change
    where change ->> 'entityId' = 'c2000000-0000-4000-8000-000000000002'
  ),
  'tenant A delta cannot observe tenant B entity IDs'
);

-- Realtime carries invalidation-only cursor hints. Authorization is exact-topic
-- owner binding; guessing another user's private topic yields no messages.
reset role;

select extensions.ok(
  exists (
    select 1 from realtime.messages
    where topic = 'schedule-sync:61111111-1111-4111-8111-111111111111'
      and event = 'invalidate'
      and extension = 'broadcast'
      and private
  )
  and not exists (
    select 1 from realtime.messages
    where topic like 'schedule-sync:%'
      and not (
        (
          event = 'invalidate'
          and private
          and extension = 'broadcast'
          and (payload ? 'cursor')
          and not (payload ?| array[
            'entityType', 'entityId', 'ownerUserId', 'title', 'payload'
          ])
        )
        or (
          event = 'friend-invalidate'
          and private
          and extension = 'broadcast'
          and not (payload ?| array[
            'entityType', 'entityId', 'ownerUserId', 'title', 'payload', 'cursor'
          ])
        )
      )
  ),
  'Realtime broadcasts contain only invalidation cursor metadata'
);

select extensions.ok(
  exists (
    select 1 from pg_catalog.pg_policy p
    where p.polrelid = 'realtime.messages'::regclass
      and p.polname = 'schedule_sync_broadcast_receive'
      and p.polcmd = 'r'
      and pg_get_expr(p.polqual, p.polrelid) like '%realtime.topic()%'
      and pg_get_expr(p.polqual, p.polrelid) like '%auth.uid()%'
  ),
  'Realtime SELECT policy binds private topic to auth.uid()'
);

set local role authenticated;
select set_config(
  'realtime.topic',
  'schedule-sync:61111111-1111-4111-8111-111111111111',
  true
);

select extensions.ok(
  (select count(*) from realtime.messages) > 0,
  'authenticated owner can receive its private invalidation topic'
);

select set_config(
  'realtime.topic',
  'schedule-sync:62222222-2222-4222-8222-222222222222',
  true
);

select extensions.is(
  (select count(*) from realtime.messages),
  0::bigint,
  'authenticated owner cannot receive another tenant private topic'
);

-- Events retain UPDATE/DELETE table ACLs only for legacy negative RLS probes;
-- with no matching policies, even an owned row is not effectively writable.
select set_config(
  'realtime.topic',
  'schedule-sync:61111111-1111-4111-8111-111111111111',
  true
);

select extensions.results_eq(
  $sql$
    with changed as (
      update public.events
      set title = 'Direct bypass'
      where id = 'f1000000-0000-4000-8000-000000000001'
      returning id
    )
    select count(*) from changed
  $sql$,
  $sql$ values (0::bigint) $sql$,
  'event UPDATE privilege has no effective row path outside the RPC'
);

reset role;

select extensions.is_empty(
  $sql$
    select p.oid::regprocedure
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private')
      and p.prosecdef
      and not exists (
        select 1
        from unnest(coalesce(p.proconfig, '{}'::text[])) setting
        where setting like 'search_path=%'
      )
  $sql$,
  'all schedule security-definer functions pin search_path'
);

select extensions.is(
  (
    select count(*)
    from private.schedule_change_log
    where owner_user_id = '61111111-1111-4111-8111-111111111111'
      and entity_type = 'user_course'
      and entity_id = 'c1000000-0000-4000-8000-000000000001'
      and operation = 'upsert'
  ),
  1::bigint,
  'idempotent replay does not append a duplicate change-log row'
);

select extensions.is(
  (
    select count(*)
    from private.schedule_change_log
    where owner_user_id = '61111111-1111-4111-8111-111111111111'
      and entity_type = 'assignment'
      and entity_id = 'd1000000-0000-4000-8000-000000000001'
  ),
  2::bigint,
  'stale conflict appends no change beyond create and successful update'
);

select extensions.ok(
  not exists (
    select 1
    from private.schedule_change_log
    where owner_user_id = '61111111-1111-4111-8111-111111111111'
      and payload ->> 'ownerUserId'
        = '62222222-2222-4222-8222-222222222222'
  ),
  'private change log never records a cross-tenant payload'
);

set local role authenticated;

select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      response #>> '{change,operation}',
      (response ->> 'server_version')::bigint,
      response ->> 'server_version' = response #>> '{change,serverVersion}',
      response ->> 'deleted_at' is not null
    from (
      select public.apply_schedule_mutation(
        'sync-a-exam-delete', 'exam',
        'e1000000-0000-4000-8000-000000000001', 'delete', 1,
        jsonb_build_object(
          'id', 'e1000000-0000-4000-8000-000000000001',
          'ownerUserId', auth.uid()
        )
      ) response
    ) deleted
  $sql$,
  $sql$ values ('applied'::text, 'delete'::text, 2::bigint, true, true) $sql$,
  'exam delete returns a consistent versioned canonical tombstone'
);

select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      response #>> '{change,operation}',
      (response ->> 'server_version')::bigint,
      response ->> 'deleted_at' is not null
    from (
      select public.apply_schedule_mutation(
        'sync-a-state-delete-before-resubmit', 'assignment_user_state',
        'd1000000-0000-4000-8000-000000000001', 'delete', 1,
        jsonb_build_object(
          'assignmentId', 'd1000000-0000-4000-8000-000000000001',
          'userId', auth.uid()
        )
      ) response
    ) deleted
  $sql$,
  $sql$ values ('applied'::text, 'delete'::text, 2::bigint, true) $sql$,
  'assignment-state delete creates its first tombstone'
);

select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      response #>> '{change,operation}',
      (response ->> 'server_version')::bigint,
      response ->> 'deleted_at' is null
    from (
      select public.apply_schedule_mutation(
        'sync-a-state-resubmit', 'assignment_user_state',
        'd1000000-0000-4000-8000-000000000001', 'submit', 2,
        jsonb_build_object(
          'assignmentId', 'd1000000-0000-4000-8000-000000000001',
          'userId', auth.uid(),
          'status', 'submitted',
          'submittedAt', '2026-07-19T01:00:00Z'
        )
      ) response
    ) resubmitted
  $sql$,
  $sql$ values ('applied'::text, 'upsert'::text, 3::bigint, true) $sql$,
  'submit resurrects a matching assignment-state tombstone'
);

select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      response #>> '{change,operation}',
      (response ->> 'server_version')::bigint,
      response ->> 'server_version' = response #>> '{change,serverVersion}',
      response ->> 'deleted_at' is not null
    from (
      select public.apply_schedule_mutation(
        'sync-a-assignment-delete', 'assignment',
        'd1000000-0000-4000-8000-000000000001', 'delete', 2,
        jsonb_build_object(
          'id', 'd1000000-0000-4000-8000-000000000001',
          'ownerUserId', auth.uid()
        )
      ) response
    ) deleted
  $sql$,
  $sql$ values ('applied'::text, 'delete'::text, 3::bigint, true, true) $sql$,
  'assignment delete returns a consistent versioned canonical tombstone'
);

select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      response #>> '{change,operation}',
      (response ->> 'server_version')::bigint,
      response ->> 'server_version' = response #>> '{change,serverVersion}',
      response ->> 'deleted_at' is not null
    from (
      select public.apply_schedule_mutation(
        'sync-a-state-delete', 'assignment_user_state',
        'd1000000-0000-4000-8000-000000000001', 'delete', 3,
        jsonb_build_object(
          'assignmentId', 'd1000000-0000-4000-8000-000000000001',
          'userId', auth.uid()
        )
      ) response
    ) deleted
  $sql$,
  $sql$ values ('applied'::text, 'delete'::text, 4::bigint, true, true) $sql$,
  'assignment-state delete remains valid after its parent tombstone'
);

select extensions.results_eq(
  $sql$
    select
      response ->> 'outcome',
      response #>> '{change,operation}',
      (response ->> 'server_version')::bigint,
      response ->> 'server_version' = response #>> '{change,serverVersion}',
      response ->> 'deleted_at' is not null
    from (
      select public.apply_schedule_mutation(
        'sync-a-course-delete', 'user_course',
        'c1000000-0000-4000-8000-000000000001', 'delete', 1,
        jsonb_build_object(
          'id', 'c1000000-0000-4000-8000-000000000001',
          'ownerUserId', auth.uid()
        )
      ) response
    ) deleted
  $sql$,
  $sql$ values ('applied'::text, 'delete'::text, 2::bigint, true, true) $sql$,
  'user-course delete returns a consistent versioned canonical tombstone'
);

select extensions.ok(
  (
    with latest as (
      select distinct on (
        change ->> 'entityType',
        change ->> 'entityId'
      ) change
      from jsonb_array_elements(
        public.get_schedule_delta(0, 500) -> 'changes'
      ) change
      where change ->> 'entityType' in (
        'user_course', 'assignment', 'assignment_user_state', 'exam'
      )
        and change ->> 'entityId' in (
          'c1000000-0000-4000-8000-000000000001',
          'd1000000-0000-4000-8000-000000000001',
          'e1000000-0000-4000-8000-000000000001'
        )
      order by
        change ->> 'entityType',
        change ->> 'entityId',
        (change ->> 'changeCursor')::bigint desc
    )
    select count(*)
    from latest
    where change ->> 'operation' = 'delete'
      and change ->> 'deletedAt' is not null
      and change #>> '{payload,deletedAt}' is not null
  ) = 4,
  'delta latest rows are all four course/assignment/state/exam tombstones'
);

select extensions.ok(
  (public.apply_schedule_mutation(
    'sync-a-course-delete', 'user_course',
    'c1000000-0000-4000-8000-000000000001', 'delete', 1,
    jsonb_build_object(
      'id', 'c1000000-0000-4000-8000-000000000001',
      'ownerUserId', auth.uid()
    )
  ) ->> 'replayed')::boolean,
  'delete acknowledgement replays without a second tombstone'
);

reset role;

select extensions.is(
  (
    select count(*)
    from (
      select id from public.user_courses
      where id = 'c1000000-0000-4000-8000-000000000001'
        and version = 2 and deleted_at is not null
      union all
      select id from public.assignments
      where id = 'd1000000-0000-4000-8000-000000000001'
        and version = 3 and deleted_at is not null
      union all
      select assignment_id from public.assignment_user_states
      where assignment_id = 'd1000000-0000-4000-8000-000000000001'
        and user_id = '61111111-1111-4111-8111-111111111111'
        and version = 4 and deleted_at is not null
      union all
      select id from public.exams
      where id = 'e1000000-0000-4000-8000-000000000001'
        and version = 2 and deleted_at is not null
    ) persisted_tombstones
  ),
  4::bigint,
  'all four supported non-event deletes persist their canonical tombstones'
);

select * from extensions.finish();
rollback;
