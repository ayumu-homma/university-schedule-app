begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(16);

-- Three synthetic principals: one template author and one member at the same
-- university, plus a caller from an unrelated university.
insert into auth.users (id)
values
  ('71111111-1111-4111-8111-111111111111'),
  ('72222222-2222-4222-8222-222222222222'),
  ('73333333-3333-4333-8333-333333333333');

insert into public.universities (
  id, config_key, name, normalized_name, status
)
values
  (
    '7a000000-0000-4000-8000-000000000001',
    'test:course-template:university-a',
    'Course Template Test University A',
    'coursetemplatetestuniversitya',
    'active'
  ),
  (
    '7b000000-0000-4000-8000-000000000002',
    'test:course-template:university-b',
    'Course Template Test University B',
    'coursetemplatetestuniversityb',
    'active'
  );

update public.profiles
set university_id = case user_id
  when '71111111-1111-4111-8111-111111111111'::uuid
    then '7a000000-0000-4000-8000-000000000001'::uuid
  when '72222222-2222-4222-8222-222222222222'::uuid
    then '7a000000-0000-4000-8000-000000000001'::uuid
  else '7b000000-0000-4000-8000-000000000002'::uuid
end
where user_id in (
  '71111111-1111-4111-8111-111111111111',
  '72222222-2222-4222-8222-222222222222',
  '73333333-3333-4333-8333-333333333333'
);

-- Catalog terms are copied into caller-owned term snapshots during onboarding.
-- The search RPC must use that source-template relationship rather than expose
-- a template only when a caller somehow knows another user's term UUID.
insert into public.terms (
  id, university_id, name, academic_year, start_date, end_date, term_type,
  created_by, is_template, owner_user_id, source_template_id, status
)
values
  (
    '7a100000-0000-4000-8000-000000000001',
    '7a000000-0000-4000-8000-000000000001',
    'University A 2026 spring catalog', 2026,
    '2026-04-01', '2026-09-30', 'semester',
    '71111111-1111-4111-8111-111111111111', true, null, null, 'active'
  ),
  (
    '7a200000-0000-4000-8000-000000000002',
    '7a000000-0000-4000-8000-000000000001',
    'Member A 2026 spring', 2026,
    '2026-04-01', '2026-09-30', 'semester',
    '72222222-2222-4222-8222-222222222222', false,
    '72222222-2222-4222-8222-222222222222',
    '7a100000-0000-4000-8000-000000000001', 'active'
  ),
  (
    '7a300000-0000-4000-8000-000000000003',
    '7a000000-0000-4000-8000-000000000001',
    'Author A 2026 spring', 2026,
    '2026-04-01', '2026-09-30', 'semester',
    '71111111-1111-4111-8111-111111111111', false,
    '71111111-1111-4111-8111-111111111111',
    '7a100000-0000-4000-8000-000000000001', 'active'
  ),
  (
    '7b100000-0000-4000-8000-000000000004',
    '7b000000-0000-4000-8000-000000000002',
    'University B 2026 spring catalog', 2026,
    '2026-04-01', '2026-09-30', 'semester',
    '73333333-3333-4333-8333-333333333333', true, null, null, 'active'
  ),
  (
    '7b200000-0000-4000-8000-000000000005',
    '7b000000-0000-4000-8000-000000000002',
    'Member B 2026 spring', 2026,
    '2026-04-01', '2026-09-30', 'semester',
    '73333333-3333-4333-8333-333333333333', false,
    '73333333-3333-4333-8333-333333333333',
    '7b100000-0000-4000-8000-000000000004', 'active'
  );

insert into public.course_templates (
  id, university_id, academic_year, term_id, title, normalized_title,
  instructor_name, normalized_instructor_name, day_of_week, period_no, room,
  normalized_room, credit_count, syllabus_url, external_course_code,
  created_by, copy_count_total, copy_count_term, report_count, trust_score,
  status
)
values
  (
    '7c100000-0000-4000-8000-000000000001',
    '7a000000-0000-4000-8000-000000000001', 2026,
    '7a100000-0000-4000-8000-000000000001',
    'Distributed Systems', public.normalize_course_text('Distributed Systems'),
    'Ada Lovelace', public.normalize_course_text('Ada Lovelace'),
    1, 2, 'A-201', public.normalize_course_text('A-201'), 2,
    'https://example.test/syllabus/distributed-systems', 'DST-101',
    '71111111-1111-4111-8111-111111111111', 14, 9, 0, 3, 'active'
  ),
  (
    '7c200000-0000-4000-8000-000000000002',
    '7a000000-0000-4000-8000-000000000001', 2026,
    '7a100000-0000-4000-8000-000000000001',
    'Data Structures', public.normalize_course_text('Data Structures'),
    'Ada Lovelace', public.normalize_course_text('Ada Lovelace'),
    2, 3, 'B-301', public.normalize_course_text('B-301'), 2,
    'https://example.test/syllabus/data-structures-a', 'DSA-201',
    '71111111-1111-4111-8111-111111111111', 80, 20, 0, 1, 'active'
  ),
  (
    '7c300000-0000-4000-8000-000000000003',
    '7a000000-0000-4000-8000-000000000001', 2026,
    '7a100000-0000-4000-8000-000000000001',
    'Data Structures', public.normalize_course_text('Data Structures'),
    'Ada Lovelace', public.normalize_course_text('Ada Lovelace'),
    2, 3, 'B-302', public.normalize_course_text('B-302'), 2,
    'https://example.test/syllabus/data-structures-b', 'DSB-202',
    '71111111-1111-4111-8111-111111111111', 5, 1, 0, 1, 'active'
  ),
  (
    '7c400000-0000-4000-8000-000000000004',
    '7a000000-0000-4000-8000-000000000001', 2026,
    '7a100000-0000-4000-8000-000000000001',
    'Compilers', public.normalize_course_text('Compilers'),
    'Grace Hopper', public.normalize_course_text('Grace Hopper'),
    4, 4, 'C-401', public.normalize_course_text('C-401'), 2,
    'https://example.test/syllabus/compilers', 'CMP-301',
    '71111111-1111-4111-8111-111111111111', 1, 0, 0, 0, 'active'
  ),
  (
    '7d100000-0000-4000-8000-000000000005',
    '7b000000-0000-4000-8000-000000000002', 2026,
    '7b100000-0000-4000-8000-000000000004',
    'Data Structures', public.normalize_course_text('Data Structures'),
    'Ada Lovelace', public.normalize_course_text('Ada Lovelace'),
    2, 3, 'Z-999', public.normalize_course_text('Z-999'), 2,
    'https://example.test/syllabus/unrelated', 'OTHER-999',
    '73333333-3333-4333-8333-333333333333', 999, 999, 0, 99, 'active'
  );

select extensions.ok(
  pg_catalog.has_function_privilege(
    'authenticated',
    'public.search_course_templates(text,uuid,integer,uuid,integer,integer,integer,text)',
    'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'anon',
    'public.search_course_templates(text,uuid,integer,uuid,integer,integer,integer,text)',
    'EXECUTE'
  ),
  'the complete course-template search RPC is authenticated-only'
);

select extensions.ok(
  pg_catalog.to_regprocedure(
    'public.search_course_templates(text,uuid,integer,uuid,integer,integer,integer,text)'
  ) is not null
  and pg_catalog.to_regprocedure(
    'public.search_course_templates(text,uuid,integer,uuid,integer,integer,integer)'
  ) is null,
  'the search RPC has one trailing-default instructor filter signature'
);

set local request.jwt.claims = '{"sub":"72222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '72222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is(
  (
    select count(*)
    from public.search_course_templates(
      'Distributed Systems',
      '7a000000-0000-4000-8000-000000000001',
      2026,
      '7a200000-0000-4000-8000-000000000002',
      1,
      2,
      50
    )
  ),
  1::bigint,
  'the legacy seven-argument call remains compatible through the trailing default'
);

select extensions.results_eq(
  $sql$
    select
      id, university_id, academic_year, term_id, title, normalized_title,
      instructor_name, normalized_instructor_name, day_of_week, period_no,
      room, normalized_room, credit_count, syllabus_url, external_course_code,
      copy_count_total, copy_count_term, trust_score
    from public.search_course_templates(
      query_text => 'Distributed Systems',
      target_university_id => '7a000000-0000-4000-8000-000000000001',
      target_academic_year => 2026,
      target_term_id => '7a200000-0000-4000-8000-000000000002',
      target_day_of_week => 1,
      target_period_no => 2,
      limit_count => 50,
      target_instructor_name => 'Ada'
    )
  $sql$,
  $sql$
    values (
      '7c100000-0000-4000-8000-000000000001'::uuid,
      '7a000000-0000-4000-8000-000000000001'::uuid,
      2026,
      '7a100000-0000-4000-8000-000000000001'::uuid,
      'Distributed Systems'::text,
      'distributedsystems'::text,
      'Ada Lovelace'::text,
      'adalovelace'::text,
      1,
      2,
      'A-201'::text,
      'a201'::text,
      2::numeric,
      'https://example.test/syllabus/distributed-systems'::text,
      'DST-101'::text,
      14,
      9,
      3::numeric
    )
  $sql$,
  'a same-university member receives the complete safe catalog shape via its owned term snapshot'
);

select extensions.ok(
  (
    select
      not (to_jsonb(result_row) ? 'created_by')
      and not (to_jsonb(result_row) ? 'author_name')
      and not (to_jsonb(result_row) ? 'report_count')
      and to_jsonb(result_row) ? 'duplicate_key'
      and to_jsonb(result_row) ? 'rank_score'
      and result_row.duplicate_key is not null
      and result_row.rank_score is not null
    from public.search_course_templates(
      query_text => 'Distributed Systems',
      target_university_id => '7a000000-0000-4000-8000-000000000001',
      target_academic_year => 2026,
      target_term_id => '7a200000-0000-4000-8000-000000000002',
      limit_count => 50,
      target_instructor_name => 'Ada'
    ) result_row
    where result_row.id = '7c100000-0000-4000-8000-000000000001'
  ),
  'search results expose ranking metadata but exclude template-author and moderation fields'
);

select extensions.results_eq(
  $sql$
    select id, title, instructor_name
    from public.search_course_templates(
      query_text => '',
      target_university_id => '7a000000-0000-4000-8000-000000000001',
      target_academic_year => 2026,
      target_term_id => '7a200000-0000-4000-8000-000000000002',
      limit_count => 50,
      target_instructor_name => 'Grace Hopper'
    )
  $sql$,
  $sql$
    values (
      '7c400000-0000-4000-8000-000000000004'::uuid,
      'Compilers'::text,
      'Grace Hopper'::text
    )
  $sql$,
  'the normalized instructor filter narrows same-university template results'
);

select extensions.results_eq(
  $sql$
    select id
    from public.search_course_templates(
      query_text => 'Data Structures',
      target_university_id => '7a000000-0000-4000-8000-000000000001',
      target_academic_year => 2026,
      target_term_id => '7a200000-0000-4000-8000-000000000002',
      limit_count => 50,
      target_instructor_name => 'Ada'
    )
  $sql$,
  $sql$
    values
      ('7c200000-0000-4000-8000-000000000002'::uuid),
      ('7c300000-0000-4000-8000-000000000003'::uuid)
  $sql$,
  'equally relevant templates are ranked by copy counts before the stable identifier'
);

select extensions.ok(
  (
    select count(distinct duplicate_key) = 1
    from public.search_course_templates(
      query_text => 'Data Structures',
      target_university_id => '7a000000-0000-4000-8000-000000000001',
      target_academic_year => 2026,
      target_term_id => '7a200000-0000-4000-8000-000000000002',
      limit_count => 50,
      target_instructor_name => 'Ada'
    )
  ),
  'duplicate candidates retain a normalized title-instructor-slot key'
);

select extensions.ok(
  public.copy_course_template(
    '7c100000-0000-4000-8000-000000000001',
    '7a200000-0000-4000-8000-000000000002'
  ) is not null,
  'a same-university member can copy a template into its owned active term'
);

reset role;

select extensions.ok(
  exists (
    select 1
    from public.user_courses c
    where c.owner_user_id = '72222222-2222-4222-8222-222222222222'
      and c.term_id = '7a200000-0000-4000-8000-000000000002'
      and c.source_template_id = '7c100000-0000-4000-8000-000000000001'
      and c.title = 'Distributed Systems'
      and c.instructor_name = 'Ada Lovelace'
      and c.room = 'A-201'
      and c.visibility_level = 'PRIVATE'
      and c.deleted_at is null
  ),
  'copy creates a private member-owned course snapshot with source metadata'
);

set local role authenticated;

select extensions.ok(
  public.copy_course_template(
    '7c100000-0000-4000-8000-000000000001',
    '7a200000-0000-4000-8000-000000000002'
  ) = public.copy_course_template(
    '7c100000-0000-4000-8000-000000000001',
    '7a200000-0000-4000-8000-000000000002'
  ),
  'copy replay is idempotent for the member, source template, and owned term'
);

reset role;

select extensions.ok(
  (
    select count(*)
    from public.course_template_copy_events
    where template_id = '7c100000-0000-4000-8000-000000000001'
      and copied_by = '72222222-2222-4222-8222-222222222222'
  ) = 1
  and (
    select copy_count_total
    from public.course_templates
    where id = '7c100000-0000-4000-8000-000000000001'
  ) = 15,
  'copy replay records one event and increments the source count exactly once'
);

update public.course_templates
set title = 'Distributed Systems (updated source)',
    instructor_name = 'Changed Instructor',
    room = 'Changed room'
where id = '7c100000-0000-4000-8000-000000000001';

select extensions.ok(
  exists (
    select 1
    from public.user_courses c
    where c.owner_user_id = '72222222-2222-4222-8222-222222222222'
      and c.term_id = '7a200000-0000-4000-8000-000000000002'
      and c.source_template_id = '7c100000-0000-4000-8000-000000000001'
      and c.title = 'Distributed Systems'
      and c.instructor_name = 'Ada Lovelace'
      and c.room = 'A-201'
  ),
  'later source-template edits do not mutate the copied personal course snapshot'
);

set local request.jwt.claims = '{"sub":"73333333-3333-4333-8333-333333333333","role":"authenticated"}';
set local request.jwt.claim.sub = '73333333-3333-4333-8333-333333333333';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is_empty(
  $sql$
    select *
    from public.search_course_templates(
      query_text => 'Data Structures',
      target_university_id => '7a000000-0000-4000-8000-000000000001',
      target_academic_year => 2026,
      target_term_id => '7b200000-0000-4000-8000-000000000005',
      limit_count => 50,
      target_instructor_name => 'Ada'
    )
  $sql$,
  'a different-university caller cannot search another university catalog'
);

select extensions.throws_ok(
  $sql$
    select public.copy_course_template(
      '7c100000-0000-4000-8000-000000000001',
      '7b200000-0000-4000-8000-000000000005'
    )
  $sql$,
  '42501',
  'course template is not available for this university',
  'a different-university caller cannot copy a foreign template'
);

set local request.jwt.claims = '{"sub":"72222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '72222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';

select extensions.is_empty(
  $sql$
    select *
    from public.search_course_templates(
      query_text => 'Distributed Systems',
      target_university_id => '7a000000-0000-4000-8000-000000000001',
      target_academic_year => 2026,
      target_term_id => '7a300000-0000-4000-8000-000000000003',
      limit_count => 50,
      target_instructor_name => 'Ada'
    )
  $sql$,
  'a caller cannot use another member term as a search scope'
);

select * from extensions.finish();
rollback;
