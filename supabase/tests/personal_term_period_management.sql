begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(25);

-- Auth bootstrap creates the profiles.  Setup runs as the migration role; all
-- mutation and containment assertions below run as authenticated principals.
insert into auth.users (id)
values
  ('81111111-1111-4111-8111-111111111111'),
  ('82222222-2222-4222-8222-222222222222'),
  ('83333333-3333-4333-8333-333333333333');

insert into public.universities (
  id, config_key, name, normalized_name, status
)
values
  (
    '8a000000-0000-4000-8000-000000000001',
    'test:personal-term-period:university-a',
    'Personal Term Period Test University A',
    'personaltermperiodtestuniversitya',
    'active'
  ),
  (
    '8b000000-0000-4000-8000-000000000002',
    'test:personal-term-period:university-b',
    'Personal Term Period Test University B',
    'personaltermperiodtestuniversityb',
    'active'
  );

update public.profiles
set university_id = case user_id
      when '81111111-1111-4111-8111-111111111111'::uuid
        then '8a000000-0000-4000-8000-000000000001'::uuid
      when '82222222-2222-4222-8222-222222222222'::uuid
        then '8a000000-0000-4000-8000-000000000001'::uuid
      else '8b000000-0000-4000-8000-000000000002'::uuid
    end,
    user_type = 'undergraduate',
    onboarding_status = 'complete',
    onboarding_step = 'complete',
    onboarding_completed_at = now()
where user_id in (
  '81111111-1111-4111-8111-111111111111',
  '82222222-2222-4222-8222-222222222222',
  '83333333-3333-4333-8333-333333333333'
);

insert into public.terms (
  id, university_id, name, academic_year, start_date, end_date, term_type,
  created_by, is_template, owner_user_id, source_template_id, status
)
values
  (
    '8a100000-0000-4000-8000-000000000001',
    '8a000000-0000-4000-8000-000000000001',
    'University A spring 2026', 2026, '2026-04-01', '2026-09-30', 'semester',
    '81111111-1111-4111-8111-111111111111', true, null, null, 'active'
  ),
  (
    '8a100000-0000-4000-8000-000000000003',
    '8a000000-0000-4000-8000-000000000001',
    'University A intensive 2026', 2026, '2026-08-01', '2026-08-14', 'intensive',
    '81111111-1111-4111-8111-111111111111', true, null, null, 'active'
  ),
  (
    '8b100000-0000-4000-8000-000000000002',
    '8b000000-0000-4000-8000-000000000002',
    'University B spring 2026', 2026, '2026-04-01', '2026-09-30', 'semester',
    '83333333-3333-4333-8333-333333333333', true, null, null, 'active'
  );

insert into public.period_template_sets (
  id, university_id, config_key, name, academic_year, user_type, status
)
values
  (
    '8a200000-0000-4000-8000-000000000001',
    '8a000000-0000-4000-8000-000000000001',
    'test:personal-term-period:set-a',
    'University A standard timetable', 2026, 'undergraduate', 'active'
  ),
  (
    '8b200000-0000-4000-8000-000000000002',
    '8b000000-0000-4000-8000-000000000002',
    'test:personal-term-period:set-b',
    'University B standard timetable', 2026, 'undergraduate', 'active'
  );

insert into public.period_templates (
  template_set_id, university_id, day_of_week, period_no, start_time, end_time
)
values
  (
    '8a200000-0000-4000-8000-000000000001',
    '8a000000-0000-4000-8000-000000000001', 1, 1, '09:00', '10:20'
  ),
  (
    '8a200000-0000-4000-8000-000000000001',
    '8a000000-0000-4000-8000-000000000001', 1, 2, '10:30', '11:50'
  ),
  (
    '8b200000-0000-4000-8000-000000000002',
    '8b000000-0000-4000-8000-000000000002', 1, 1, '08:45', '10:05'
  );

select extensions.ok(
  pg_catalog.has_function_privilege(
    'authenticated',
    'public.create_personal_term(uuid,text,integer,date,date,text,uuid,jsonb,boolean)',
    'EXECUTE'
  )
  and pg_catalog.has_function_privilege(
    'authenticated', 'public.activate_personal_term(uuid)', 'EXECUTE'
  )
  and pg_catalog.has_function_privilege(
    'authenticated',
    'public.replace_personal_period_settings(uuid,uuid,jsonb)', 'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'anon',
    'public.create_personal_term(uuid,text,integer,date,date,text,uuid,jsonb,boolean)',
    'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'anon', 'public.activate_personal_term(uuid)', 'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'anon',
    'public.replace_personal_period_settings(uuid,uuid,jsonb)', 'EXECUTE'
  ),
  'term and period mutation RPCs are authenticated-only'
);

select extensions.ok(
  not pg_catalog.has_table_privilege('anon', 'public.terms', 'SELECT')
  and not pg_catalog.has_table_privilege('authenticated', 'public.terms', 'INSERT')
  and not pg_catalog.has_table_privilege('authenticated', 'public.terms', 'UPDATE')
  and not pg_catalog.has_table_privilege('authenticated', 'public.period_settings', 'INSERT')
  and not pg_catalog.has_table_privilege('authenticated', 'public.period_settings', 'UPDATE')
  and not pg_catalog.has_table_privilege('authenticated', 'public.period_settings', 'DELETE'),
  'raw personal-term and period writes remain unavailable to clients'
);

-- Same-university user A creates a source-backed personal term and makes it
-- active in the same transaction as the period snapshot.
set local request.jwt.claims = '{"sub":"81111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '81111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.lives_ok(
  $sql$
    select *
    from public.create_personal_term(
      '8a100000-0000-4000-8000-000000000001',
      null, null, null, null, null,
      '8a200000-0000-4000-8000-000000000001',
      null,
      true
    )
  $sql$,
  'a same-university caller can copy an active term and period template'
);

select extensions.results_eq(
  $sql$
    select university_id, source_template_id, academic_year, term_type
    from public.terms
    where owner_user_id = auth.uid()
      and name = 'University A spring 2026'
  $sql$,
  $sql$
    values (
      '8a000000-0000-4000-8000-000000000001'::uuid,
      '8a100000-0000-4000-8000-000000000001'::uuid,
      2026,
      'semester'::text
    )
  $sql$,
  'template copy records a private same-university source snapshot'
);

select extensions.results_eq(
  $sql$
    select
      count(*),
      min(source_template_set_id::text),
      max(source_template_set_id::text)
    from public.period_settings
    where owner_user_id = auth.uid()
      and term_id = (select active_term_id from public.profiles where user_id = auth.uid())
  $sql$,
  $sql$
    values (
      2::bigint,
      '8a200000-0000-4000-8000-000000000001'::text,
      '8a200000-0000-4000-8000-000000000001'::text
    )
  $sql$,
  'template periods are copied as a personal snapshot with source provenance'
);

select extensions.ok(
  exists (
    select 1
    from public.profiles profile
    join public.terms personal_term
      on personal_term.id = profile.active_term_id
     and personal_term.owner_user_id = profile.user_id
     and personal_term.university_id = profile.university_id
     and not personal_term.is_template
     and personal_term.status = 'active'
     and personal_term.deleted_at is null
    where profile.user_id = auth.uid()
  ),
  'profile active_term_id always points to the caller-owned active university term'
);

select extensions.lives_ok(
  $sql$
    select *
    from public.create_personal_term(
      null,
      'Personal summer quarter',
      2026,
      '2026-08-01',
      '2026-09-15',
      'quarter',
      null,
      '[
        {"day_of_week":1,"period_no":1,"start_time":"09:15","end_time":"10:15"},
        {"day_of_week":1,"period_no":2,"start_time":"10:30","end_time":"11:30"}
      ]'::jsonb,
      false
    )
  $sql$,
  'a caller can create a semester, quarter, or custom personal term with user periods'
);

select extensions.results_eq(
  $sql$
    select source_template_id, term_type, start_date, end_date
    from public.terms
    where owner_user_id = auth.uid()
      and name = 'Personal summer quarter'
  $sql$,
  $sql$
    values (null::uuid, 'quarter'::text, '2026-08-01'::date, '2026-09-15'::date)
  $sql$,
  'custom personal terms carry no catalog source and retain their supplied bounds'
);

select extensions.is(
  (
    select name
    from public.terms
    where id = (select active_term_id from public.profiles where user_id = auth.uid())
  ),
  'University A spring 2026'::text,
  'an inactive create does not disturb the existing active profile term'
);

select extensions.lives_ok(
  $sql$
    select public.activate_personal_term(
      (
        select id from public.terms
        where owner_user_id = auth.uid()
          and name = 'Personal summer quarter'
      )
    )
  $sql$,
  'a caller can switch the active term to another owned same-university term'
);

select extensions.is(
  (
    select name
    from public.terms
    where id = (select active_term_id from public.profiles where user_id = auth.uid())
  ),
  'Personal summer quarter'::text,
  'active switch updates the guarded profile pointer atomically'
);

select extensions.is(
  public.replace_personal_period_settings(
    (
      select id from public.terms
      where owner_user_id = auth.uid()
        and name = 'Personal summer quarter'
    ),
    null,
    '[
      {"day_of_week":2,"period_no":1,"start_time":"08:50","end_time":"10:10"},
      {"day_of_week":2,"period_no":2,"start_time":"10:20","end_time":"11:40"}
    ]'::jsonb
  ),
  2,
  'user period replacement writes the complete replacement snapshot'
);

select extensions.results_eq(
  $sql$
    select count(*), bool_and(source_template_set_id is null), min(start_time), max(end_time)
    from public.period_settings
    where owner_user_id = auth.uid()
      and term_id = (select active_term_id from public.profiles where user_id = auth.uid())
  $sql$,
  $sql$
    values (2::bigint, true, '08:50'::time, '11:40'::time)
  $sql$,
  'custom replacement clears template provenance and persists normalized periods'
);

select extensions.throws_ok(
  $sql$
    select public.replace_personal_period_settings(
      (select active_term_id from public.profiles where user_id = auth.uid()),
      null,
      '[
        {"day_of_week":2,"period_no":1,"start_time":"09:00","end_time":"10:30"},
        {"day_of_week":2,"period_no":2,"start_time":"10:00","end_time":"11:30"}
      ]'::jsonb
    )
  $sql$,
  '22023',
  'period times overlap',
  'overlapping replacement periods are rejected before any delete'
);

select extensions.is(
  (
    select count(*)
    from public.period_settings
    where owner_user_id = auth.uid()
      and term_id = (select active_term_id from public.profiles where user_id = auth.uid())
  ),
  2::bigint,
  'failed period validation leaves the prior personal snapshot intact'
);

select extensions.lives_ok(
  $sql$
    select *
    from public.create_personal_term(
      '8a100000-0000-4000-8000-000000000003',
      null, null, null, null, null,
      '8a200000-0000-4000-8000-000000000001',
      null,
      false
    )
  $sql$,
  'a caller can copy an intensive term template without a client decode mismatch'
);

select extensions.lives_ok(
  $sql$
    select *
    from public.create_personal_term(
      null,
      'Personal year-round term',
      2026,
      '2026-04-01',
      '2027-03-31',
      'year_round',
      null,
      '[{"day_of_week":1,"period_no":1,"start_time":"09:00","end_time":"10:20"}]'::jsonb,
      false
    )
  $sql$,
  'a caller can create a year-round personal term without a client decode mismatch'
);

select extensions.results_eq(
  $sql$
    select name, term_type
    from public.terms
    where owner_user_id = auth.uid()
      and name in ('University A intensive 2026', 'Personal year-round term')
    order by name
  $sql$,
  $sql$
    values
      ('Personal year-round term'::text, 'year_round'::text),
      ('University A intensive 2026'::text, 'intensive'::text)
  $sql$,
  'intensive and year-round personal terms persist their supported wire types'
);

reset role;
update public.terms
set status = 'hidden'
where id = '8a100000-0000-4000-8000-000000000001';
set local role authenticated;

select extensions.throws_ok(
  $sql$
    select *
    from public.create_personal_term(
      '8a100000-0000-4000-8000-000000000001',
      null, null, null, null, null,
      '8a200000-0000-4000-8000-000000000001',
      null,
      false
    )
  $sql$,
  '22023',
  'term template is not available',
  'hidden catalog terms cannot be copied into a new personal term'
);

-- User B belongs to the same university, but cannot read or mutate user A's
-- personal term or its period rows.
reset role;
select set_config(
  'test.personal_term_id',
  (
    select active_term_id::text
    from public.profiles
    where user_id = '81111111-1111-4111-8111-111111111111'
  ),
  true
);
set local request.jwt.claims = '{"sub":"82222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '82222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.throws_ok(
  $sql$
    select public.activate_personal_term(
      current_setting('test.personal_term_id')::uuid
    )
  $sql$,
  '42501',
  'personal term is not available',
  'a same-university peer cannot activate another user personal term'
);

select extensions.throws_ok(
  $sql$
    select public.replace_personal_period_settings(
      current_setting('test.personal_term_id')::uuid,
      null,
      '[{"day_of_week":1,"period_no":1,"start_time":"09:00","end_time":"10:00"}]'::jsonb
    )
  $sql$,
  '42501',
  'personal term is not available',
  'a same-university peer cannot replace another user period settings'
);

select extensions.is(
  (
    select count(*)
    from public.terms
    where owner_user_id = '81111111-1111-4111-8111-111111111111'
  ),
  0::bigint,
  'same-university peers cannot read another user personal term rows'
);

select extensions.is(
  (
    select count(*)
    from public.period_settings
    where owner_user_id = '81111111-1111-4111-8111-111111111111'
  ),
  0::bigint,
  'same-university peers cannot read another user personal period rows'
);

-- User C has a different university profile and cannot borrow University A's
-- catalog template or its period set through the security-definer boundary.
reset role;
set local request.jwt.claims = '{"sub":"83333333-3333-4333-8333-333333333333","role":"authenticated"}';
set local request.jwt.claim.sub = '83333333-3333-4333-8333-333333333333';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.throws_ok(
  $sql$
    select *
    from public.create_personal_term(
      '8a100000-0000-4000-8000-000000000001',
      null, null, null, null, null,
      '8a200000-0000-4000-8000-000000000001',
      null,
      true
    )
  $sql$,
  '22023',
  'term template is not available',
  'different-university callers cannot copy a foreign term template'
);

reset role;

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
  'PUBLIC retains no EXECUTE on security-definer term or period helpers'
);

select * from extensions.finish();
rollback;
