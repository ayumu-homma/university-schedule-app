-- Focused COURSE-03 duplicate-candidate lifecycle contract.
-- Transaction-local synthetic rows; no retained templates or copies are changed.
begin;
select plan(23);

create temporary table duplicate_test_user_course_count as
select count(*) as row_count from public.user_courses;

insert into auth.users(id) values
  ('e1700000-0000-4000-8000-000000000001')
on conflict (id) do nothing;

insert into public.universities(id,config_key,name,normalized_name,status)
values
  ('e1710000-0000-4000-8000-000000000001','course-duplicate-test-a','Course Duplicate Test A','courseduplicatetesta','active'),
  ('e1710000-0000-4000-8000-000000000002','course-duplicate-test-b','Course Duplicate Test B','courseduplicatetestb','active');

insert into private.global_admins(user_id)
values ('e1700000-0000-4000-8000-000000000001')
on conflict (user_id) do update set revoked_at = null;

insert into public.course_templates(
  id,university_id,academic_year,title,normalized_title,
  instructor_name,normalized_instructor_name,day_of_week,period_no,
  created_by,status,canonical_template_id,deleted_at
)
values
  ('e1730000-0000-4000-8000-000000000001','e1710000-0000-4000-8000-000000000001',2026,'Linear Algebra',public.normalize_course_text('Linear Algebra'),'Prof A',public.normalize_course_text('Prof A'),1,1,'e1700000-0000-4000-8000-000000000001','active',null,null),
  ('e1730000-0000-4000-8000-000000000002','e1710000-0000-4000-8000-000000000001',2026,'Linear Algebra',public.normalize_course_text('Linear Algebra'),'Prof A',public.normalize_course_text('Prof A'),1,1,'e1700000-0000-4000-8000-000000000001','active',null,null),
  ('e1730000-0000-4000-8000-000000000003','e1710000-0000-4000-8000-000000000001',2026,'Linear Algebra',public.normalize_course_text('Linear Algebra'),'Prof B',public.normalize_course_text('Prof B'),1,1,'e1700000-0000-4000-8000-000000000001','active',null,null),
  ('e1730000-0000-4000-8000-000000000004','e1710000-0000-4000-8000-000000000001',2027,'Linear Algebra',public.normalize_course_text('Linear Algebra'),'Prof A',public.normalize_course_text('Prof A'),2,2,'e1700000-0000-4000-8000-000000000001','active',null,null),
  ('e1730000-0000-4000-8000-000000000005','e1710000-0000-4000-8000-000000000002',2026,'Linear Algebra',public.normalize_course_text('Linear Algebra'),'Prof A',public.normalize_course_text('Prof A'),1,1,'e1700000-0000-4000-8000-000000000001','active',null,null),
  ('e1730000-0000-4000-8000-000000000006','e1710000-0000-4000-8000-000000000001',2026,'Linear Algebra II',public.normalize_course_text('Linear Algebra II'),'Prof A',public.normalize_course_text('Prof A'),2,2,'e1700000-0000-4000-8000-000000000001','active',null,null),
  ('e1730000-0000-4000-8000-000000000007','e1710000-0000-4000-8000-000000000001',2026,'Linear Algebra',public.normalize_course_text('Linear Algebra'),'Prof A',public.normalize_course_text('Prof A'),1,1,'e1700000-0000-4000-8000-000000000001','hidden',null,null),
  ('e1730000-0000-4000-8000-000000000008','e1710000-0000-4000-8000-000000000001',2026,'Linear Algebra',public.normalize_course_text('Linear Algebra'),'Prof A',public.normalize_course_text('Prof A'),1,1,'e1700000-0000-4000-8000-000000000001','merged','e1730000-0000-4000-8000-000000000001',null),
  ('e1730000-0000-4000-8000-000000000009','e1710000-0000-4000-8000-000000000001',2026,'Linear Algebra',public.normalize_course_text('Linear Algebra'),'Prof A',public.normalize_course_text('Prof A'),1,1,'e1700000-0000-4000-8000-000000000001','active',null,now()),
  ('e1730000-0000-4000-8000-000000000010','e1710000-0000-4000-8000-000000000001',2026,'Database Systems',public.normalize_course_text('Database Systems'),'Prof Z',public.normalize_course_text('Prof Z'),3,3,'e1700000-0000-4000-8000-000000000001','active',null,null),
  ('e1730000-0000-4000-8000-000000000011','e1710000-0000-4000-8000-000000000001',2026,'Database Systems',public.normalize_course_text('Database Systems'),'Prof Z',public.normalize_course_text('Prof Z'),3,3,'e1700000-0000-4000-8000-000000000001','active',null,null),
  ('e1730000-0000-4000-8000-000000000012','e1710000-0000-4000-8000-000000000001',2026,'Database Systems',public.normalize_course_text('Database Systems'),'Prof Q',public.normalize_course_text('Prof Q'),3,3,'e1700000-0000-4000-8000-000000000001','active',null,null);

-- Keep these lifecycle assertions statement-local. A separate committed,
-- coordinated two-session test exercises the default deferred behavior.
set constraints all immediate;

select extensions.ok(
  to_regprocedure('private.course_template_duplicate_score(uuid,uuid)') is not null
  and to_regprocedure('private.refresh_course_template_duplicate_candidates()') is not null,
  'private score and trigger helpers exist'
);
select extensions.ok(
  exists(select 1 from pg_trigger where tgname='course_template_duplicate_candidates_after_insert' and not tgisinternal and tgdeferrable and tginitdeferred)
  and exists(select 1 from pg_trigger where tgname='course_template_duplicate_candidates_after_update' and not tgisinternal and tgdeferrable and tginitdeferred),
  'insert and relevant-update triggers are deferred until commit'
);
select extensions.ok(
  not has_function_privilege('authenticated','private.course_template_duplicate_score(uuid,uuid)','EXECUTE')
  and not has_function_privilege('authenticated','private.refresh_course_template_duplicate_candidates()','EXECUTE')
  and not has_function_privilege('anon','private.course_template_duplicate_score(uuid,uuid)','EXECUTE')
  and not has_function_privilege('anon','private.refresh_course_template_duplicate_candidates()','EXECUTE'),
  'client roles cannot call private generation helpers'
);
select extensions.is(
  (select score from public.course_template_duplicate_candidates where template_a_id='e1730000-0000-4000-8000-000000000001' and template_b_id='e1730000-0000-4000-8000-000000000002'),
  0.99::numeric,
  'Level 1 creates the highest review score'
);
select extensions.is(
  (select status from public.course_template_duplicate_candidates where template_a_id='e1730000-0000-4000-8000-000000000001' and template_b_id='e1730000-0000-4000-8000-000000000002'),
  'pending',
  'generation never merges a candidate automatically'
);
select extensions.ok(
  (select template_a_id < template_b_id from public.course_template_duplicate_candidates where template_a_id='e1730000-0000-4000-8000-000000000001' and template_b_id='e1730000-0000-4000-8000-000000000002'),
  'new candidate pairs use a stable ordered orientation'
);
select extensions.is(
  (select count(*) from public.course_template_duplicate_candidates where (template_a_id='e1730000-0000-4000-8000-000000000001' and template_b_id='e1730000-0000-4000-8000-000000000002') or (template_a_id='e1730000-0000-4000-8000-000000000002' and template_b_id='e1730000-0000-4000-8000-000000000001')),
  1::bigint,
  'reversed pair generation does not duplicate a candidate'
);
select extensions.is(
  (select score from public.course_template_duplicate_candidates where template_a_id='e1730000-0000-4000-8000-000000000001' and template_b_id='e1730000-0000-4000-8000-000000000003'),
  0.90::numeric,
  'Level 2 matches title and slot without requiring instructor equality'
);
select extensions.is(
  (select score from public.course_template_duplicate_candidates where template_a_id='e1730000-0000-4000-8000-000000000001' and template_b_id='e1730000-0000-4000-8000-000000000004'),
  0.80::numeric,
  'Level 3 matches university, normalized title, and instructor across terms/slots'
);
select extensions.is(
  (select count(*) from public.course_template_duplicate_candidates where template_a_id='e1730000-0000-4000-8000-000000000001' and template_b_id='e1730000-0000-4000-8000-000000000006'),
  0::bigint,
  'Level 4 fuzzy title candidates are not generated'
);
select extensions.is(
  (select count(*) from public.course_template_duplicate_candidates where template_a_id='e1730000-0000-4000-8000-000000000001' and template_b_id='e1730000-0000-4000-8000-000000000005'),
  0::bigint,
  'identical templates across universities do not become candidates'
);
select extensions.is(
  (select count(*) from public.course_template_duplicate_candidates d join public.course_templates t on t.id=d.template_b_id where d.template_a_id='e1730000-0000-4000-8000-000000000001' and t.id in ('e1730000-0000-4000-8000-000000000007','e1730000-0000-4000-8000-000000000008','e1730000-0000-4000-8000-000000000009')),
  0::bigint,
  'hidden, merged, and soft-deleted rows are excluded'
);

update public.course_templates
set normalized_title = public.normalize_course_text('Different Subject')
where id='e1730000-0000-4000-8000-000000000001';
select extensions.is(
  (select count(*) from public.course_template_duplicate_candidates where template_a_id='e1730000-0000-4000-8000-000000000001' and template_b_id='e1730000-0000-4000-8000-000000000002' and status='pending'),
  0::bigint,
  'a template edit removes a stale pending pair'
);
update public.course_templates
set normalized_title = public.normalize_course_text('Linear Algebra')
where id='e1730000-0000-4000-8000-000000000001';
select extensions.is(
  (select count(*) from public.course_template_duplicate_candidates where template_a_id='e1730000-0000-4000-8000-000000000001' and template_b_id='e1730000-0000-4000-8000-000000000002' and status='pending'),
  1::bigint,
  'a newly matching pair is generated after an edit'
);

update public.course_template_duplicate_candidates
set status='rejected',reviewed_at=now(),reviewed_by='e1700000-0000-4000-8000-000000000001',decision_reason='synthetic review'
where template_a_id='e1730000-0000-4000-8000-000000000001'
  and template_b_id='e1730000-0000-4000-8000-000000000002';
update public.course_templates
set normalized_title = public.normalize_course_text('Different Subject')
where id='e1730000-0000-4000-8000-000000000001';
update public.course_templates
set normalized_title = public.normalize_course_text('Linear Algebra')
where id='e1730000-0000-4000-8000-000000000001';
select extensions.is(
  (select status from public.course_template_duplicate_candidates where template_a_id='e1730000-0000-4000-8000-000000000001' and template_b_id='e1730000-0000-4000-8000-000000000002'),
  'rejected',
  'reviewed candidates are retained and never resurrected as pending'
);

update public.course_templates set status='hidden'
where id='e1730000-0000-4000-8000-000000000003';
select extensions.is(
  (select count(*) from public.course_template_duplicate_candidates where (template_a_id='e1730000-0000-4000-8000-000000000001' and template_b_id='e1730000-0000-4000-8000-000000000003') and status='pending'),
  0::bigint,
  'hiding a template removes its stale pending candidates'
);
update public.course_templates set status='active'
where id='e1730000-0000-4000-8000-000000000003';
select extensions.is(
  (select status from public.course_template_duplicate_candidates where template_a_id='e1730000-0000-4000-8000-000000000001' and template_b_id='e1730000-0000-4000-8000-000000000003'),
  'pending',
  'reactivated, still-unreviewed matches can be generated again'
);

select extensions.ok(
  to_regprocedure('public.admin_list_course_template_duplicates(integer,integer)') is not null
  and pg_get_function_result('public.admin_list_course_template_duplicates(integer,integer)'::regprocedure) like '%candidate_id uuid%template_a_version bigint%template_b_version bigint%',
  'current admin listing signature and version columns remain compatible'
);
set local request.jwt.claims='{"sub":"e1700000-0000-4000-8000-000000000001","role":"authenticated"}';
set local request.jwt.claim.sub='e1700000-0000-4000-8000-000000000001';
select extensions.is(
  (select count(*) from public.admin_list_course_template_duplicates(100,0) where template_a_id='e1730000-0000-4000-8000-000000000001' and template_b_id='e1730000-0000-4000-8000-000000000003'),
  1::bigint,
  'current admin RPC lists a generated pending pair'
);

select extensions.is(
  (public.admin_merge_course_templates('e1730000-0000-4000-8000-000000000010','e1730000-0000-4000-8000-000000000011',1,1,'synthetic duplicate review','e1740000-0000-4000-8000-000000000001'::uuid)->>'status'),
  'merged',
  'explicit admin merge continues to use the existing RPC contract'
);
select extensions.is(
  (select status from public.course_template_duplicate_candidates where template_a_id='e1730000-0000-4000-8000-000000000010' and template_b_id='e1730000-0000-4000-8000-000000000011'),
  'merged',
  'the explicitly selected merge pair retains merged review history'
);
select extensions.is(
  (select count(*) from public.course_template_duplicate_candidates where template_a_id='e1730000-0000-4000-8000-000000000010' and template_b_id='e1730000-0000-4000-8000-000000000012' and status='pending'),
  0::bigint,
  'other stale pending pairs are invalidated when a template is merged'
);
select extensions.is(
  (select count(*) from public.user_courses),
  (select row_count from duplicate_test_user_course_count),
  'candidate generation leaves user copies unchanged'
);

select * from finish();
rollback;
