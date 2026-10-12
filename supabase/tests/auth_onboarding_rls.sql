begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(61);

-- Deterministic principals. Auth bootstrap creates profiles automatically.
insert into auth.users (id)
values
  ('51111111-1111-4111-8111-111111111111'),
  ('52222222-2222-4222-8222-222222222222'),
  ('53333333-3333-4333-8333-333333333333'),
  ('54444444-4444-4444-8444-444444444444');

insert into public.universities (
  id, config_key, name, normalized_name, status
)
values (
  '90000000-0000-4000-8000-000000000001',
  'test:university:other',
  'Portability Test University',
  'portabilitytestuniversity',
  'active'
);

insert into public.faculties (
  id, university_id, config_key, name, normalized_name, status
)
values (
  '90000000-0000-4000-8000-000000000002',
  '90000000-0000-4000-8000-000000000001',
  'test:faculty:other',
  'Other Faculty',
  'otherfaculty',
  'active'
);

update public.profiles
set university_id = '26a72fcd-6e61-5d0f-9c77-350762f2562f'
where user_id in (
  '51111111-1111-4111-8111-111111111111',
  '52222222-2222-4222-8222-222222222222'
);
update public.profiles
set university_id = '90000000-0000-4000-8000-000000000001'
where user_id = '53333333-3333-4333-8333-333333333333';
delete from public.profiles
where user_id = '54444444-4444-4444-8444-444444444444';

select extensions.is(
  (select count(*) from public.profiles where user_id = '51111111-1111-4111-8111-111111111111'),
  1::bigint,
  'auth.users bootstrap creates exactly one profile'
);

set local request.jwt.claims = '{"sub":"54444444-4444-4444-8444-444444444444","role":"authenticated"}';
set local request.jwt.claim.sub = '54444444-4444-4444-8444-444444444444';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.throws_ok(
  $sql$
    select * from public.complete_onboarding(
      p_idempotency_key => 'a0000000-0000-4000-8000-000000000001',
      p_user_type => 'undergraduate',
      p_university_id => '26a72fcd-6e61-5d0f-9c77-350762f2562f',
      p_entry_academic_year => 2026,
      p_term_template_id => '657f0bb3-7c10-510d-a8d2-133f0114a2f9',
      p_period_template_set_id => '253ef732-d142-5abc-bb3a-17a12ff3820b'
    )
  $sql$,
  'P0002',
  'profile not found',
  'authenticated caller without a profile fails closed'
);

reset role;

select extensions.ok(
  not pg_catalog.has_table_privilege('anon', 'public.universities', 'SELECT'),
  'anon cannot read university catalog'
);
select extensions.ok(
  not pg_catalog.has_table_privilege('anon', 'public.university_domains', 'SELECT')
  and not pg_catalog.has_table_privilege('anon', 'public.university_email_verifications', 'SELECT'),
  'anon cannot read domain rules or verification status rows'
);
select extensions.ok(
  not pg_catalog.has_function_privilege(
    'anon',
    'public.complete_onboarding(uuid,text,uuid,uuid,uuid,uuid,integer,uuid,text,integer,date,date,text,uuid,jsonb)',
    'EXECUTE'
  ),
  'anon cannot execute onboarding completion'
);

-- KIT user A.
set local request.jwt.claims = '{"sub":"51111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '51111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is(
  (select count(*) from public.universities where id = '26a72fcd-6e61-5d0f-9c77-350762f2562f'),
  1::bigint,
  'authenticated onboarding user can read active KIT catalog'
);
select extensions.is(
  (select count(*) from public.campuses where university_id = '26a72fcd-6e61-5d0f-9c77-350762f2562f'),
  4::bigint,
  'KIT seed exposes four active campus choices'
);
select extensions.is(
  (select count(*) from public.period_templates where template_set_id = '253ef732-d142-5abc-bb3a-17a12ff3820b'),
  25::bigint,
  'KIT main period template contains 25 weekday slots'
);
select extensions.ok(
  not pg_catalog.has_table_privilege('authenticated', 'public.university_requests', 'INSERT'),
  'authenticated cannot directly insert a forged university request'
);
select extensions.lives_ok(
  $sql$ select public.submit_university_request('New Test University', '石川県', 'https://example.invalid') $sql$,
  'incomplete onboarding user can submit a bounded university request'
);
select extensions.is(
  (select count(*) from public.university_requests where requested_by = auth.uid() and status = 'pending'),
  1::bigint,
  'university request RPC binds the pending request to an incomplete auth.uid'
);
select extensions.ok(
  (
    select onboarding_status = 'not_started'
      and onboarding_step = 'profile'
      and onboarding_completed_at is null
      and active_term_id is null
      and primary_calendar_id is null
    from public.profiles
    where user_id = auth.uid()
  ),
  'university request leaves the onboarding profile and active schedule incomplete'
);

select extensions.throws_ok(
  $sql$
    select * from public.complete_onboarding(
      p_idempotency_key => 'a0000000-0000-4000-8000-000000000002',
      p_user_type => 'undergraduate',
      p_university_id => '26a72fcd-6e61-5d0f-9c77-350762f2562f',
      p_faculty_id => '90000000-0000-4000-8000-000000000002',
      p_entry_academic_year => 2026,
      p_term_template_id => '657f0bb3-7c10-510d-a8d2-133f0114a2f9',
      p_period_template_set_id => '253ef732-d142-5abc-bb3a-17a12ff3820b'
    )
  $sql$,
  '22023',
  'faculty does not belong to university',
  'cross-university hierarchy is rejected'
);

select extensions.throws_ok(
  $sql$
    select * from public.complete_onboarding(
      p_idempotency_key => 'a0000000-0000-4000-8000-000000000003',
      p_user_type => 'undergraduate',
      p_university_id => '26a72fcd-6e61-5d0f-9c77-350762f2562f',
      p_entry_academic_year => 2026,
      p_term_template_id => '657f0bb3-7c10-510d-a8d2-133f0114a2f9',
      p_custom_term_name => 'Ambiguous',
      p_period_template_set_id => '253ef732-d142-5abc-bb3a-17a12ff3820b'
    )
  $sql$,
  '22023',
  'choose a term template or a custom term, not both',
  'term template and custom term are mutually exclusive'
);

select extensions.throws_ok(
  $sql$
    select * from public.complete_onboarding(
      p_idempotency_key => 'a0000000-0000-4000-8000-000000000005',
      p_user_type => 'undergraduate',
      p_university_id => '26a72fcd-6e61-5d0f-9c77-350762f2562f',
      p_campus_id => '72264f8f-a659-524a-94ea-506634a5bdd7',
      p_entry_academic_year => 2026,
      p_term_template_id => '657f0bb3-7c10-510d-a8d2-133f0114a2f9',
      p_period_template_set_id => '253ef732-d142-5abc-bb3a-17a12ff3820b'
    )
  $sql$,
  '22023',
  'period template set is not available',
  'Ogigaoka main period template cannot be selected for Toranomon'
);

select extensions.throws_ok(
  $sql$
    select * from public.complete_onboarding(
      p_idempotency_key => 'a0000000-0000-4000-8000-000000000004',
      p_user_type => 'undergraduate',
      p_university_id => '26a72fcd-6e61-5d0f-9c77-350762f2562f',
      p_entry_academic_year => 2026,
      p_custom_term_name => 'Custom',
      p_custom_academic_year => 2026,
      p_custom_start_date => '2026-04-01',
      p_custom_end_date => '2026-09-30',
      p_custom_term_type => 'custom',
      p_custom_periods => '[
        {"day_of_week":1,"period_no":1,"start_time":"09:00","end_time":"10:30"},
        {"day_of_week":1,"period_no":2,"start_time":"10:00","end_time":"11:30"}
      ]'::jsonb
    )
  $sql$,
  '22023',
  'period times overlap',
  'overlapping custom period rows are rejected'
);
select extensions.is(
  (select count(*) from public.terms where owner_user_id = auth.uid()),
  0::bigint,
  'failed onboarding leaves no personal term'
);

select extensions.lives_ok(
  $sql$
    select * from public.complete_onboarding(
      p_idempotency_key => 'a0000000-0000-4000-8000-000000000010',
      p_user_type => 'undergraduate',
      p_university_id => '26a72fcd-6e61-5d0f-9c77-350762f2562f',
      p_campus_id => '5400e7bb-e9bf-5cbc-aaf8-5cfdade1ee74',
      p_faculty_id => '5a34c1ab-9478-51b5-bbe1-cb1a709c90ba',
      p_department_id => '34b179bc-9629-595f-90f7-32173a4e8698',
      p_entry_academic_year => 2026,
      p_term_template_id => '657f0bb3-7c10-510d-a8d2-133f0114a2f9',
      p_period_template_set_id => '253ef732-d142-5abc-bb3a-17a12ff3820b'
    )
  $sql$,
  'valid KIT onboarding completes atomically'
);

select extensions.results_eq(
  $sql$
    select onboarding_status, onboarding_step, active_term_id is not null, primary_calendar_id is not null
    from public.profiles where user_id = auth.uid()
  $sql$,
  $sql$ values ('complete'::text, 'complete'::text, true, true) $sql$,
  'profile stores completed onboarding, active term, and primary calendar'
);
select extensions.is(
  (select count(*) from public.terms where owner_user_id = auth.uid() and not is_template),
  1::bigint,
  'onboarding creates one personal term snapshot'
);
select extensions.is(
  (select count(*) from public.period_settings where owner_user_id = auth.uid()),
  25::bigint,
  'onboarding snapshots all 25 personal period rows'
);
select extensions.is(
  (select source_template_id from public.terms where owner_user_id = auth.uid() and not is_template),
  '657f0bb3-7c10-510d-a8d2-133f0114a2f9'::uuid,
  'personal term records its source template'
);

select extensions.lives_ok(
  $sql$
    select * from public.complete_onboarding(
      p_idempotency_key => 'a0000000-0000-4000-8000-000000000010',
      p_user_type => 'undergraduate',
      p_university_id => '26a72fcd-6e61-5d0f-9c77-350762f2562f',
      p_campus_id => '5400e7bb-e9bf-5cbc-aaf8-5cfdade1ee74',
      p_faculty_id => '5a34c1ab-9478-51b5-bbe1-cb1a709c90ba',
      p_department_id => '34b179bc-9629-595f-90f7-32173a4e8698',
      p_entry_academic_year => 2026,
      p_term_template_id => '657f0bb3-7c10-510d-a8d2-133f0114a2f9',
      p_period_template_set_id => '253ef732-d142-5abc-bb3a-17a12ff3820b'
    )
  $sql$,
  'same onboarding key and payload is idempotent'
);
select extensions.is(
  (select count(*) from public.terms where owner_user_id = auth.uid() and not is_template),
  1::bigint,
  'idempotent retry does not duplicate the personal term'
);

reset role;
update public.period_templates
set end_time = '10:19'
where template_set_id = '253ef732-d142-5abc-bb3a-17a12ff3820b'
  and day_of_week = 1
  and period_no = 1;
set local role authenticated;

select extensions.results_eq(
  $sql$
    select * from public.complete_onboarding(
      p_idempotency_key => 'a0000000-0000-4000-8000-000000000010',
      p_user_type => 'undergraduate',
      p_university_id => '26a72fcd-6e61-5d0f-9c77-350762f2562f',
      p_campus_id => '5400e7bb-e9bf-5cbc-aaf8-5cfdade1ee74',
      p_faculty_id => '5a34c1ab-9478-51b5-bbe1-cb1a709c90ba',
      p_department_id => '34b179bc-9629-595f-90f7-32173a4e8698',
      p_entry_academic_year => 2026,
      p_term_template_id => '657f0bb3-7c10-510d-a8d2-133f0114a2f9',
      p_period_template_set_id => '253ef732-d142-5abc-bb3a-17a12ff3820b'
    )
  $sql$,
  $sql$
    select active_term_id, primary_calendar_id
    from public.profiles
    where user_id = auth.uid()
  $sql$,
  'same-key replay is independent of later period catalog edits'
);

reset role;
update public.terms
set status = 'hidden'
where id = '657f0bb3-7c10-510d-a8d2-133f0114a2f9';
update public.period_template_sets
set status = 'hidden'
where id = '253ef732-d142-5abc-bb3a-17a12ff3820b';
set local role authenticated;

select extensions.results_eq(
  $sql$
    select * from public.complete_onboarding(
      p_idempotency_key => 'a0000000-0000-4000-8000-000000000010',
      p_user_type => 'undergraduate',
      p_university_id => '26a72fcd-6e61-5d0f-9c77-350762f2562f',
      p_campus_id => '5400e7bb-e9bf-5cbc-aaf8-5cfdade1ee74',
      p_faculty_id => '5a34c1ab-9478-51b5-bbe1-cb1a709c90ba',
      p_department_id => '34b179bc-9629-595f-90f7-32173a4e8698',
      p_entry_academic_year => 2026,
      p_term_template_id => '657f0bb3-7c10-510d-a8d2-133f0114a2f9',
      p_period_template_set_id => '253ef732-d142-5abc-bb3a-17a12ff3820b'
    )
  $sql$,
  $sql$
    select active_term_id, primary_calendar_id
    from public.profiles
    where user_id = auth.uid()
  $sql$,
  'same-key replay returns the committed result after source catalogs are hidden'
);

-- Keep the catalog mutation scoped to the replay assertions so the remaining
-- role-matrix checks still exercise the source-backed active KIT catalog.
reset role;
update public.period_templates
set end_time = '10:20'
where template_set_id = '253ef732-d142-5abc-bb3a-17a12ff3820b'
  and day_of_week = 1
  and period_no = 1;
update public.terms
set status = 'active'
where id = '657f0bb3-7c10-510d-a8d2-133f0114a2f9';
update public.period_template_sets
set status = 'active'
where id = '253ef732-d142-5abc-bb3a-17a12ff3820b';
set local role authenticated;

select extensions.throws_ok(
  $sql$
    select * from public.complete_onboarding(
      p_idempotency_key => 'a0000000-0000-4000-8000-000000000010',
      p_user_type => 'graduate',
      p_university_id => '26a72fcd-6e61-5d0f-9c77-350762f2562f',
      p_campus_id => '5400e7bb-e9bf-5cbc-aaf8-5cfdade1ee74',
      p_faculty_id => '5a34c1ab-9478-51b5-bbe1-cb1a709c90ba',
      p_department_id => '34b179bc-9629-595f-90f7-32173a4e8698',
      p_entry_academic_year => 2026,
      p_term_template_id => '657f0bb3-7c10-510d-a8d2-133f0114a2f9',
      p_period_template_set_id => '253ef732-d142-5abc-bb3a-17a12ff3820b'
    )
  $sql$,
  '23505',
  'idempotency key was reused with a different payload',
  'idempotency key reuse with a different payload is rejected'
);

select extensions.throws_ok(
  $sql$
    select * from public.complete_onboarding(
      p_idempotency_key => 'a0000000-0000-4000-8000-000000000011',
      p_user_type => 'undergraduate',
      p_university_id => '26a72fcd-6e61-5d0f-9c77-350762f2562f',
      p_entry_academic_year => 2026,
      p_term_template_id => '657f0bb3-7c10-510d-a8d2-133f0114a2f9',
      p_period_template_set_id => '253ef732-d142-5abc-bb3a-17a12ff3820b'
    )
  $sql$,
  '22023',
  'onboarding is already complete',
  'a new key cannot duplicate already completed onboarding'
);

select extensions.throws_ok(
  $sql$
    update public.profiles
    set university_id = '90000000-0000-4000-8000-000000000001'
    where user_id = auth.uid()
  $sql$,
  '42501',
  'profile onboarding fields are server-managed',
  'client cannot directly change profile university'
);
-- KIT user B completes a custom schedule and then attempts cross-user reads.
reset role;
set local request.jwt.claims = '{"sub":"52222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '52222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.lives_ok(
  $sql$
    select * from public.complete_onboarding(
      p_idempotency_key => 'b0000000-0000-4000-8000-000000000001',
      p_user_type => 'undergraduate',
      p_university_id => '26a72fcd-6e61-5d0f-9c77-350762f2562f',
      p_campus_id => '72264f8f-a659-524a-94ea-506634a5bdd7',
      p_entry_academic_year => 2025,
      p_custom_term_name => 'User B custom',
      p_custom_academic_year => 2026,
      p_custom_start_date => '2026-04-01',
      p_custom_end_date => '2026-09-30',
      p_custom_term_type => 'custom',
      p_custom_periods => '[{"day_of_week":1,"period_no":1,"start_time":"09:00","end_time":"10:00"}]'::jsonb
    )
  $sql$,
  'custom term and manual periods support a known campus without a template'
);
select extensions.is(
  (select count(*) from public.terms where owner_user_id = '51111111-1111-4111-8111-111111111111'),
  0::bigint,
  'same-university peer cannot read another personal term'
);
select extensions.is(
  (select count(*) from public.period_settings where owner_user_id = '51111111-1111-4111-8111-111111111111'),
  0::bigint,
  'same-university peer cannot read another personal period settings'
);
select extensions.is(
  (select count(*) from public.university_requests where requested_by = '51111111-1111-4111-8111-111111111111'),
  0::bigint,
  'peer cannot read another university request'
);
select extensions.throws_ok(
  $sql$
    select * from public.request_university_email_verification(
      '26a72fcd-6e61-5d0f-9c77-350762f2562f',
      '9ff6e383-a629-53e1-b24c-0deb14a278f7'
    )
  $sql$,
  '22023',
  'email domain rule is not eligible',
  'KIT 2026 email rule rejects a 2025 cohort'
);

-- An authenticated principal from another university can inspect portable
-- onboarding catalog data, but never another user's personal snapshots.
reset role;
set local request.jwt.claims = '{"sub":"53333333-3333-4333-8333-333333333333","role":"authenticated"}';
set local request.jwt.claim.sub = '53333333-3333-4333-8333-333333333333';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.is(
  (select count(*) from public.terms where owner_user_id = '51111111-1111-4111-8111-111111111111'),
  0::bigint,
  'other-university principal cannot read a KIT user personal term'
);
select extensions.is(
  (select count(*) from public.terms where is_template and university_id = '26a72fcd-6e61-5d0f-9c77-350762f2562f'),
  2::bigint,
  'portable active term catalog remains selectable before university change'
);

-- KIT user A requests verification; only trusted roles can issue/complete it.
reset role;
set local request.jwt.claims = '{"sub":"51111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '51111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.lives_ok(
  $sql$
    select * from public.request_university_email_verification(
      '26a72fcd-6e61-5d0f-9c77-350762f2562f',
      '9ff6e383-a629-53e1-b24c-0deb14a278f7'
    )
  $sql$,
  'eligible user creates only an opaque verification request'
);
select extensions.is(
  (select status from public.university_email_verifications where user_id = auth.uid()),
  'pending'::text,
  'request status is visible to its owner'
);
select extensions.ok(
  not pg_catalog.has_function_privilege(
    'authenticated',
    'public.issue_university_email_verification_challenge(uuid,uuid,text,text,timestamptz)',
    'EXECUTE'
  ),
  'authenticated cannot issue a verification challenge'
);
select extensions.ok(
  not pg_catalog.has_table_privilege(
    'authenticated',
    'private.university_email_verification_challenges',
    'SELECT'
  ),
  'authenticated cannot read private challenge material'
);
select extensions.ok(
  pg_catalog.has_table_privilege('authenticated', 'public.university_email_verifications', 'SELECT')
  and not pg_catalog.has_table_privilege('authenticated', 'public.university_email_verifications', 'INSERT')
  and not pg_catalog.has_table_privilege('authenticated', 'public.university_email_verifications', 'UPDATE')
  and not pg_catalog.has_table_privilege('authenticated', 'public.university_email_verifications', 'DELETE'),
  'authenticated receives owner-filtered verification status read only'
);

reset role;
select extensions.lives_ok(
  $sql$
    select * from public.issue_university_email_verification_challenge(
      (select request_id from public.university_email_verifications where user_id = '51111111-1111-4111-8111-111111111111'),
      '51111111-1111-4111-8111-111111111111',
      repeat('a', 64),
      repeat('b', 64),
      now() + interval '10 minutes'
    )
  $sql$,
  'trusted boundary stores only HMAC challenge material'
);
select extensions.is(
  (select count(*) from private.university_email_verification_challenges where user_id = '51111111-1111-4111-8111-111111111111'),
  1::bigint,
  'one active private challenge is stored'
);
select extensions.is(
  (
    select result
    from public.complete_university_email_verification(
      (select request_id from public.university_email_verifications where user_id = '51111111-1111-4111-8111-111111111111'),
      '51111111-1111-4111-8111-111111111111',
      repeat('c', 64)
    )
  ),
  'invalid_code'::text,
  'wrong verification code HMAC returns a bounded failure state'
);
select extensions.is(
  (select attempt_count from private.university_email_verification_challenges where user_id = '51111111-1111-4111-8111-111111111111'),
  1,
  'wrong verification attempt is durably counted'
);
select extensions.is(
  (
    select result
    from public.complete_university_email_verification(
      (select request_id from public.university_email_verifications where user_id = '51111111-1111-4111-8111-111111111111'),
      '51111111-1111-4111-8111-111111111111',
      repeat('b', 64)
    )
  ),
  'verified'::text,
  'matching trusted HMAC verifies the university email'
);
select extensions.is(
  (select university_verified from public.profiles where user_id = '51111111-1111-4111-8111-111111111111'),
  true,
  'successful verification updates the server-managed profile badge'
);
select extensions.is(
  (
    select result
    from public.complete_university_email_verification(
      (select request_id from public.university_email_verifications where user_id = '51111111-1111-4111-8111-111111111111'),
      '51111111-1111-4111-8111-111111111111',
      repeat('b', 64)
    )
  ),
  'invalid_request'::text,
  'consumed verification challenge cannot be replayed'
);

set local request.jwt.claims = '{"sub":"51111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '51111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.lives_ok(
  $sql$ select public.change_university('90000000-0000-4000-8000-000000000001') $sql$,
  'university change runs through the auth-bound RPC'
);
select extensions.results_eq(
  $sql$
    select university_verified, active_term_id is null, onboarding_status
    from public.profiles where user_id = auth.uid()
  $sql$,
  $sql$ values (false, true, 'in_progress'::text) $sql$,
  'university change revokes verification and active term atomically'
);

reset role;
select extensions.is(
  (select status from public.university_email_verifications where user_id = '51111111-1111-4111-8111-111111111111'),
  'revoked'::text,
  'university change revokes the prior verification status'
);
select extensions.results_eq(
  $sql$
    select cohort_start_academic_year, cohort_end_academic_year, match_subdomains
    from public.university_domains
    where id = '9ff6e383-a629-53e1-b24c-0deb14a278f7'
  $sql$,
  $sql$ values (2026, 2026, false) $sql$,
  'KIT student domain rule is exact and limited to the sourced 2026 cohort'
);
select extensions.is(
  (select count(*) from public.terms where is_template and instruction_start_date is not null),
  0::bigint,
  'uncertain KIT teaching windows are not seeded as instruction dates'
);
select extensions.is(
  (select count(*) from public.course_templates where status = 'active' and deleted_at is null),
  0::bigint,
  'no fictitious course template remains active'
);

select extensions.is_empty(
  $sql$
    select p.oid::regprocedure
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    cross join lateral pg_catalog.aclexplode(
      coalesce(p.proacl, pg_catalog.acldefault('f'::"char", p.proowner))
    ) acl
    where n.nspname in ('public', 'private')
      and p.prosecdef
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  $sql$,
  'PUBLIC has no EXECUTE on application SECURITY DEFINER functions'
);
select extensions.is_empty(
  $sql$
    select p.oid::regprocedure
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private')
      and p.prosecdef
      and pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
      -- PostgREST runs this internal hook after switching to the API role.
      -- It remains in the unexposed private schema; no other exception applies.
      and p.oid <> 'private.safety_pre_request()'::regprocedure
  $sql$,
  'anon has no EXECUTE on application SECURITY DEFINER functions except the internal pre-request hook'
);
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
  'every application SECURITY DEFINER function pins search_path'
);
select extensions.ok(
  pg_catalog.has_function_privilege('service_role', 'public.issue_university_email_verification_challenge(uuid,uuid,text,text,timestamptz)', 'EXECUTE')
  and pg_catalog.has_function_privilege('service_role', 'public.complete_university_email_verification(uuid,uuid,text)', 'EXECUTE')
  and pg_catalog.has_function_privilege('service_role', 'public.invalidate_university_email_verification(uuid,uuid,text)', 'EXECUTE')
  and not pg_catalog.has_function_privilege('authenticated', 'public.complete_university_email_verification(uuid,uuid,text)', 'EXECUTE'),
  'trusted verification RPCs are service-role-only'
);
select extensions.ok(
  pg_catalog.has_function_privilege('authenticated', 'public.submit_university_request(text,text,text)', 'EXECUTE')
  and pg_catalog.has_function_privilege('authenticated', 'public.change_university(uuid)', 'EXECUTE')
  and pg_catalog.has_function_privilege('authenticated', 'public.complete_onboarding(uuid,text,uuid,uuid,uuid,uuid,integer,uuid,text,integer,date,date,text,uuid,jsonb)', 'EXECUTE')
  and pg_catalog.has_function_privilege('authenticated', 'public.request_university_email_verification(uuid,uuid)', 'EXECUTE'),
  'authenticated can execute only the intended onboarding entry points'
);
select extensions.ok(
  not pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'INSERT')
  and pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'SELECT')
  and pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'UPDATE'),
  'profile ACL relies on auth bootstrap and guarded owner updates'
);
select extensions.ok(
  pg_catalog.has_column_privilege('service_role', 'public.university_email_verifications', 'request_id', 'SELECT')
  and pg_catalog.has_column_privilege('service_role', 'public.university_email_verifications', 'user_id', 'SELECT')
  and pg_catalog.has_column_privilege('service_role', 'public.university_domains', 'domain', 'SELECT')
  and not pg_catalog.has_table_privilege('service_role', 'private.university_email_verification_challenges', 'SELECT'),
  'verification worker receives only allow-listed public lookup columns'
);

select * from extensions.finish();
rollback;
