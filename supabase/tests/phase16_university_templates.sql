-- Phase 16 contract tests.  These are schema/RPC checks and do not mutate the
-- retained A/B fixtures; full Auth-JWT acceptance uses dedicated synthetic
-- accounts in the local runbook.
begin;
select plan(63);

select extensions.ok(to_regprocedure('public.submit_university_request(text,text,text,uuid)') is not null,'operation-aware university request RPC exists');
select extensions.ok(to_regprocedure('public.admin_list_university_requests(integer,integer)') is not null,'admin university request list exists');
select extensions.ok(to_regprocedure('public.admin_resolve_university_request(uuid,text,uuid,text,uuid)') is not null,'admin university decision exists');
select extensions.ok(to_regprocedure('public.admin_list_universities(integer,integer)') is not null,'admin university catalog list exists');
select extensions.ok(to_regprocedure('public.admin_update_university(uuid,text,text[],text,text,bigint,text,uuid)') is not null,'admin university master update exists');
select extensions.ok(to_regprocedure('public.publish_course_template(uuid,uuid)') is not null,'student publication RPC exists');
select extensions.ok(to_regprocedure('public.submit_course_template_edit_proposal(uuid,jsonb,bigint,uuid)') is not null,'student proposal RPC exists');
select extensions.ok(to_regprocedure('public.report_course_template(uuid,text,uuid)') is not null,'student template report RPC exists');
select extensions.ok(to_regprocedure('public.get_course_template_update(uuid)') is not null,'template update comparison exists');
select extensions.ok(to_regprocedure('public.review_course_template_update(uuid,text,bigint,bigint,uuid)') is not null,'receipt-backed explicit template update review exists');
select extensions.ok(to_regprocedure('public.admin_resolve_course_template_proposal(uuid,text,text,uuid)') is not null,'admin proposal decision exists');
select extensions.ok(to_regprocedure('public.admin_resolve_course_template_report(uuid,text,text,uuid)') is not null,'admin template report decision exists');
select extensions.ok(to_regprocedure('public.admin_merge_course_templates(uuid,uuid,bigint,bigint,text,uuid)') is not null,'admin template merge exists');
select extensions.ok(to_regprocedure('public.admin_list_course_template_duplicates(integer,integer)') is not null,'admin duplicate list exists');

select extensions.ok((select relrowsecurity from pg_class where oid='public.university_requests'::regclass),'university request RLS remains enabled');
select extensions.ok((select relrowsecurity from pg_class where oid='public.course_templates'::regclass),'course template RLS remains enabled');
select extensions.ok(not has_table_privilege('authenticated','private.phase16_student_operation_receipts','SELECT'),'student receipts remain private');
select extensions.ok(not has_table_privilege('authenticated','public.course_template_edit_proposals','SELECT'),'raw proposal table is not directly readable');
select extensions.ok(not has_table_privilege('authenticated','public.course_template_reports','SELECT'),'raw template reports are not directly readable');
select extensions.ok(has_function_privilege('authenticated','public.publish_course_template(uuid,uuid)','EXECUTE'),'students can call publication RPC');
select extensions.ok(
  has_function_privilege('authenticated','public.submit_university_request(text,text,text,uuid)','EXECUTE')
  and not has_function_privilege('public','public.submit_university_request(text,text,text,uuid)','EXECUTE')
  and not has_function_privilege('anon','public.submit_university_request(text,text,text,uuid)','EXECUTE')
  and has_function_privilege('authenticated','public.review_course_template_update(uuid,text,bigint,bigint,uuid)','EXECUTE')
  and not has_function_privilege('public','public.review_course_template_update(uuid,text,bigint,bigint,uuid)','EXECUTE')
  and not has_function_privilege('anon','public.review_course_template_update(uuid,text,bigint,bigint,uuid)','EXECUTE'),
  'student operation overloads are authenticated-only'
);
select extensions.ok(has_function_privilege('authenticated','public.review_course_template_update(uuid,text,bigint,bigint,uuid)','EXECUTE') and not has_function_privilege('authenticated','public.review_course_template_update(uuid,text,bigint)','EXECUTE'),'students can call only the receipt-backed update review');
select extensions.ok(not has_function_privilege('anon','public.admin_resolve_university_request(uuid,text,uuid,text,uuid)','EXECUTE'),'anon cannot decide university requests');
select extensions.ok(not has_function_privilege('anon','public.admin_merge_course_templates(uuid,uuid,bigint,bigint,text,uuid)','EXECUTE'),'anon cannot merge templates');
select extensions.ok((select pg_get_constraintdef(oid) like '%template_update_state%' from pg_constraint where conname='user_courses_template_update_state_check'),'copy update state is constrained');

select extensions.ok(
  not has_function_privilege('public','private.phase16_student_lock(uuid,uuid,text,text)','EXECUTE')
  and not has_function_privilege('anon','private.phase16_student_lock(uuid,uuid,text,text)','EXECUTE')
  and not has_function_privilege('authenticated','private.phase16_student_lock(uuid,uuid,text,text)','EXECUTE')
  and not has_function_privilege('service_role','private.phase16_student_lock(uuid,uuid,text,text)','EXECUTE'),
  'student receipt lock is private to definer RPCs'
);
select extensions.ok(
  not has_function_privilege('public','private.phase16_student_record(uuid,uuid,text,text,jsonb)','EXECUTE')
  and not has_function_privilege('anon','private.phase16_student_record(uuid,uuid,text,text,jsonb)','EXECUTE')
  and not has_function_privilege('authenticated','private.phase16_student_record(uuid,uuid,text,text,jsonb)','EXECUTE')
  and not has_function_privilege('service_role','private.phase16_student_record(uuid,uuid,text,text,jsonb)','EXECUTE'),
  'student receipt writer is private to definer RPCs'
);
select extensions.ok(
  not has_function_privilege('public','private.phase16_canonical_template(uuid)','EXECUTE')
  and not has_function_privilege('anon','private.phase16_canonical_template(uuid)','EXECUTE')
  and not has_function_privilege('authenticated','private.phase16_canonical_template(uuid)','EXECUTE')
  and not has_function_privilege('service_role','private.phase16_canonical_template(uuid)','EXECUTE'),
  'canonical resolver is private to definer RPCs'
);
select extensions.ok(not has_table_privilege('authenticated','public.course_templates','SELECT'),'raw course template rows are not directly readable');
select extensions.ok(pg_get_functiondef('public.admin_list_university_requests(integer,integer)'::regprocedure) like '%status=''pending''%','admin university queue is pending-only');
select extensions.ok(pg_get_functiondef('public.admin_list_course_template_duplicates(integer,integer)'::regprocedure) like '%template_a_version%','duplicate comparison returns current template versions');
select extensions.throws_ok(
  $sql$ select private.phase16_validate_template_payload('{"unknown":1}'::jsonb,'{}'::jsonb) $sql$,
  '22023',null,'proposal validator rejects arbitrary keys'
);

-- Synthetic end-to-end fixtures.  They are transaction-local and deliberately
-- use IDs outside the retained A/B fixture set.
reset role;
insert into auth.users(id) values
  ('f1600000-0000-4000-8000-000000000001'),
  ('f1600000-0000-4000-8000-000000000002'),
  ('f1600000-0000-4000-8000-000000000003'),
  ('f1600000-0000-4000-8000-000000000004')
on conflict(id) do nothing;
insert into public.universities(id,config_key,name,normalized_name,status)
values
  ('f1610000-0000-4000-8000-000000000001','phase16:test:a','Phase 16 Test A','phase16testa','active'),
  ('f1610000-0000-4000-8000-000000000002','phase16:test:b','Phase 16 Test B','phase16testb','active')
on conflict(id) do nothing;
insert into public.profiles(user_id,display_name,university_id)
values
  ('f1600000-0000-4000-8000-000000000001','Phase 16 Student A','f1610000-0000-4000-8000-000000000001'),
  ('f1600000-0000-4000-8000-000000000002','Phase 16 Student B','f1610000-0000-4000-8000-000000000002'),
  ('f1600000-0000-4000-8000-000000000003','Phase 16 Admin','f1610000-0000-4000-8000-000000000001'),
  ('f1600000-0000-4000-8000-000000000004','Phase 16 Student A2','f1610000-0000-4000-8000-000000000001')
on conflict(user_id) do update set university_id=excluded.university_id;
insert into private.global_admins(user_id) values ('f1600000-0000-4000-8000-000000000003') on conflict(user_id) do update set revoked_at=null;
insert into public.terms(id,university_id,name,academic_year,start_date,end_date,term_type,created_by,is_template,owner_user_id,source_template_id,status)
values
  ('f1620000-0000-4000-8000-000000000001','f1610000-0000-4000-8000-000000000001','Phase 16 catalog',2026,'2026-04-01','2026-09-30','semester','f1600000-0000-4000-8000-000000000001',true,null,null,'active'),
  ('f1620000-0000-4000-8000-000000000002','f1610000-0000-4000-8000-000000000001','Phase 16 student term',2026,'2026-04-01','2026-09-30','semester','f1600000-0000-4000-8000-000000000001',false,'f1600000-0000-4000-8000-000000000001','f1620000-0000-4000-8000-000000000001','active'),
  ('f1620000-0000-4000-8000-000000000003','f1610000-0000-4000-8000-000000000002','Phase 16 other term',2026,'2026-04-01','2026-09-30','semester','f1600000-0000-4000-8000-000000000002',false,'f1600000-0000-4000-8000-000000000002',null,'active'),
  ('f1620000-0000-4000-8000-000000000004','f1610000-0000-4000-8000-000000000001','Phase 16 student term B',2026,'2026-04-01','2026-09-30','semester','f1600000-0000-4000-8000-000000000004',false,'f1600000-0000-4000-8000-000000000004','f1620000-0000-4000-8000-000000000001','active');
insert into public.course_templates(id,university_id,academic_year,term_id,title,normalized_title,instructor_name,normalized_instructor_name,day_of_week,period_no,room,normalized_room,credit_count,syllabus_url,created_by,status)
values
  ('f1630000-0000-4000-8000-000000000001','f1610000-0000-4000-8000-000000000001',2026,'f1620000-0000-4000-8000-000000000001','Phase 16 Source','phase 16 source','Teacher A','teacher a',1,1,'A-1','a-1',2,'https://example.test/p16','f1600000-0000-4000-8000-000000000001','active'),
  ('f1630000-0000-4000-8000-000000000002','f1610000-0000-4000-8000-000000000001',2026,'f1620000-0000-4000-8000-000000000001','Phase 16 Merge Source','phase 16 merge source','Teacher A','teacher a',2,2,'A-2','a-2',2,'https://example.test/p16b','f1600000-0000-4000-8000-000000000001','active'),
  ('f1630000-0000-4000-8000-000000000003','f1610000-0000-4000-8000-000000000001',2026,'f1620000-0000-4000-8000-000000000001','Phase 16 Merge Target','phase 16 merge target','Teacher A','teacher a',2,2,'A-3','a-3',2,'https://example.test/p16c','f1600000-0000-4000-8000-000000000001','active');
insert into public.user_courses(id,owner_user_id,term_id,title,normalized_title,instructor_name,normalized_instructor_name,day_of_week,period_no,room,visibility_level)
values ('f1640000-0000-4000-8000-000000000001','f1600000-0000-4000-8000-000000000001','f1620000-0000-4000-8000-000000000002','Private published source','private published source','Teacher A','teacher a',3,3,'A-4','PRIVATE');

set local request.jwt.claims='{"sub":"f1600000-0000-4000-8000-000000000001","role":"authenticated"}';
set local request.jwt.claim.sub='f1600000-0000-4000-8000-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is(
  public.submit_university_request('Replay University','Tokyo','https://example.test/replay','f1650000-0000-4000-8000-000000000001'::uuid),
  public.submit_university_request('Replay University','Tokyo','https://example.test/replay','f1650000-0000-4000-8000-000000000001'::uuid),
  'student university request replay returns one stable request'
);
select extensions.is(
  (public.publish_course_template('f1640000-0000-4000-8000-000000000001','f1650000-0000-4000-8000-000000000002'::uuid)->>'template_id'),
  (public.publish_course_template('f1640000-0000-4000-8000-000000000001','f1650000-0000-4000-8000-000000000002'::uuid)->>'template_id'),
  'student publication replay returns one stable template'
);
reset role;
select extensions.is(
  (select count(*) from public.course_templates where published_from_course_id='f1640000-0000-4000-8000-000000000001'),
  1::bigint,
  'publication replay does not create duplicate templates'
);
select extensions.is(
  (select term_id from public.course_templates where published_from_course_id='f1640000-0000-4000-8000-000000000001'),
  'f1620000-0000-4000-8000-000000000001'::uuid,
  'publication stores the shared catalog term identity'
);
select extensions.is(
  (select term_id from public.user_courses where id='f1640000-0000-4000-8000-000000000001'),
  'f1620000-0000-4000-8000-000000000002'::uuid,
  'publication leaves the personal course term unchanged'
);
set local request.jwt.claims='{"sub":"f1600000-0000-4000-8000-000000000004","role":"authenticated"}';
set local request.jwt.claim.sub='f1600000-0000-4000-8000-000000000004';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is(
  (select count(*) from public.search_course_templates('Private published source','f1610000-0000-4000-8000-000000000001',2026,'f1620000-0000-4000-8000-000000000004',null,null,20,null)),
  1::bigint,
  'another user term sourced from the catalog can search the published template'
);
select extensions.ok(
  public.copy_course_template(
    (select id from public.search_course_templates('Private published source','f1610000-0000-4000-8000-000000000001',2026,'f1620000-0000-4000-8000-000000000004',null,null,20,null) limit 1),
    'f1620000-0000-4000-8000-000000000004'
  ) is not null,
  'another same-university user can copy the published template'
);
reset role;
set local request.jwt.claims='{"sub":"f1600000-0000-4000-8000-000000000001","role":"authenticated"}';
set local request.jwt.claim.sub='f1600000-0000-4000-8000-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is(
  public.copy_course_template('f1630000-0000-4000-8000-000000000001','f1620000-0000-4000-8000-000000000002'),
  public.copy_course_template('f1630000-0000-4000-8000-000000000001','f1620000-0000-4000-8000-000000000002'),
  'copy replay is lineage-scoped and idempotent'
);
select extensions.throws_ok(
  $sql$ select public.copy_course_template('f1630000-0000-4000-8000-000000000001','f1620000-0000-4000-8000-000000000003') $sql$,
  '42501',null,'cross-university copy is denied'
);
select extensions.is(
  (public.report_course_template('f1630000-0000-4000-8000-000000000001','duplicate report','f1650000-0000-4000-8000-000000000003'::uuid)->>'report_id'),
  (public.report_course_template('f1630000-0000-4000-8000-000000000001','duplicate report','f1650000-0000-4000-8000-000000000004'::uuid)->>'report_id'),
  'distinct pending report retries deduplicate without counter inflation'
);
reset role;
select extensions.is(
  (select report_count from public.course_templates where id='f1630000-0000-4000-8000-000000000001'),
  1,
  'report count increments only for a new report'
);
set local role authenticated;
select extensions.is(
  (public.submit_course_template_edit_proposal('f1630000-0000-4000-8000-000000000001','{"title":"Phase 16 Source Revised"}'::jsonb,3,'f1650000-0000-4000-8000-000000000005'::uuid)->>'status'),
  'pending',
  'same-university proposal is accepted with an explicit allowlisted change'
);
reset role;
insert into public.course_template_duplicate_candidates(university_id,template_a_id,template_b_id,score)
values ('f1610000-0000-4000-8000-000000000001','f1630000-0000-4000-8000-000000000002','f1630000-0000-4000-8000-000000000003',0.99);
set local request.jwt.claims='{"sub":"f1600000-0000-4000-8000-000000000003","role":"authenticated"}';
set local request.jwt.claim.sub='f1600000-0000-4000-8000-000000000003';
set local request.jwt.claim.role='authenticated';
reset role;
select extensions.is(
  (public.admin_resolve_course_template_proposal((select id from public.course_template_edit_proposals where operation_id='f1650000-0000-4000-8000-000000000005'), 'approve','accepted','f1660000-0000-4000-8000-000000000002'::uuid)->>'status'),
  'approved',
  'global admin proposal approval is versioned and audited'
);
select extensions.is(
  (public.admin_merge_course_templates('f1630000-0000-4000-8000-000000000002','f1630000-0000-4000-8000-000000000003',1,1,'duplicate','f1660000-0000-4000-8000-000000000001'::uuid)->>'status'),
  'merged',
  'global admin merge executes the canonical transition'
);
select extensions.is(
  (public.admin_merge_course_templates('f1630000-0000-4000-8000-000000000002','f1630000-0000-4000-8000-000000000003',1,1,'duplicate','f1660000-0000-4000-8000-000000000001'::uuid)->>'status'),
  'merged',
  'exact admin merge replay returns the saved result'
);
select extensions.throws_ok(
  $sql$ select public.admin_merge_course_templates('f1630000-0000-4000-8000-000000000002','f1630000-0000-4000-8000-000000000003',1,1,'changed reason','f1660000-0000-4000-8000-000000000001'::uuid) $sql$,
  'PT409',null,'mismatched admin merge replay is rejected'
);
reset role;
select extensions.is(
  (select status from public.course_templates where id='f1630000-0000-4000-8000-000000000002'),
  'merged',
  'merge leaves source lineage marked merged'
);
select extensions.is(
  (select title from public.user_courses where source_template_id='f1630000-0000-4000-8000-000000000001'),
  'Phase 16 Source',
  'existing copied personal snapshot is preserved by moderation merge'
);

-- Replay mismatch is deterministic even when the live request is otherwise
-- valid.
set local request.jwt.claims='{"sub":"f1600000-0000-4000-8000-000000000001","role":"authenticated"}';
set local request.jwt.claim.sub='f1600000-0000-4000-8000-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.throws_ok(
  $sql$ select public.submit_university_request('Different Name','Tokyo','https://example.test/replay','f1650000-0000-4000-8000-000000000001'::uuid) $sql$,
  'PT409',null,'student replay with different arguments is rejected'
);
-- Ignore must reconcile the canonical identity while preserving personal
-- fields; apply then changes only the allowlisted course fields.
select extensions.is(
  (public.review_course_template_update(
    (select id from public.user_courses where owner_user_id='f1600000-0000-4000-8000-000000000001' and source_template_id='f1630000-0000-4000-8000-000000000001'),
    'ignore',
    (public.get_course_template_update((select id from public.user_courses where owner_user_id='f1600000-0000-4000-8000-000000000001' and source_template_id='f1630000-0000-4000-8000-000000000001'))->>'template_version')::bigint,
    (public.get_course_template_update((select id from public.user_courses where owner_user_id='f1600000-0000-4000-8000-000000000001' and source_template_id='f1630000-0000-4000-8000-000000000001'))->>'course_version')::bigint,
    'f16a0000-0000-4000-8000-000000000001'::uuid
  )->>'action'),
  'ignore','explicit ignore is receipt-backed and succeeds'
);
reset role;
update public.user_courses set color='keep-me',source_template_version=1,source_template_snapshot=jsonb_build_object('canonical_template_id','f1630000-0000-4000-8000-000000000001','title','old','instructor_name','Teacher A','day_of_week',3,'period_no',3,'room','A-4') where owner_user_id='f1600000-0000-4000-8000-000000000001' and source_template_id='f1630000-0000-4000-8000-000000000001';
set local request.jwt.claims='{"sub":"f1600000-0000-4000-8000-000000000001","role":"authenticated"}';
set local request.jwt.claim.sub='f1600000-0000-4000-8000-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is(
  (public.review_course_template_update(
    (select id from public.user_courses where owner_user_id='f1600000-0000-4000-8000-000000000001' and source_template_id='f1630000-0000-4000-8000-000000000001'),
    'apply',
    (public.get_course_template_update((select id from public.user_courses where owner_user_id='f1600000-0000-4000-8000-000000000001' and source_template_id='f1630000-0000-4000-8000-000000000001'))->>'template_version')::bigint,
    (public.get_course_template_update((select id from public.user_courses where owner_user_id='f1600000-0000-4000-8000-000000000001' and source_template_id='f1630000-0000-4000-8000-000000000001'))->>'course_version')::bigint,
    'f16a0000-0000-4000-8000-000000000002'::uuid
  )->>'action'),
  'apply','explicit apply returns the reconciled allowlisted snapshot'
);
reset role;
select extensions.is(
  (select color from public.user_courses where owner_user_id='f1600000-0000-4000-8000-000000000001' and source_template_id='f1630000-0000-4000-8000-000000000001'),
  'keep-me','explicit apply preserves personal metadata'
);

set local request.jwt.claims='{"sub":"f1600000-0000-4000-8000-000000000001","role":"authenticated"}';
set local request.jwt.claim.sub='f1600000-0000-4000-8000-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is(
  (public.submit_course_template_edit_proposal('f1630000-0000-4000-8000-000000000001','{"room":"A-99"}'::jsonb,(public.get_course_template_for_user('f1630000-0000-4000-8000-000000000001')->>'version')::bigint,'f16a0000-0000-4000-8000-000000000006'::uuid)->>'status'),
  'pending','proposal can be created before a later moderation state change'
);
reset role;
update public.course_templates set status='hidden' where id='f1630000-0000-4000-8000-000000000001';
set local request.jwt.claims='{"sub":"f1600000-0000-4000-8000-000000000003","role":"authenticated"}';
set local request.jwt.claim.sub='f1600000-0000-4000-8000-000000000003';
set local request.jwt.claim.role='authenticated';
select extensions.is(
  (public.admin_resolve_course_template_proposal((select id from public.course_template_edit_proposals where operation_id='f16a0000-0000-4000-8000-000000000006'),'reject','hidden target','f16a0000-0000-4000-8000-000000000007'::uuid)->>'status'),
  'rejected','proposal rejection succeeds after the target becomes hidden'
);
reset role;

set local request.jwt.claims='{"sub":"f1600000-0000-4000-8000-000000000003","role":"authenticated"}';
set local request.jwt.claim.sub='f1600000-0000-4000-8000-000000000003';
set local request.jwt.claim.role='authenticated';
reset role;
insert into public.course_template_edit_proposals(template_id,proposed_by,proposed_payload,expected_template_version,operation_id)
values ('f1630000-0000-4000-8000-000000000002','f1600000-0000-4000-8000-000000000001','{"title":"stale merged proposal"}'::jsonb,2,'f16a0000-0000-4000-8000-000000000008'::uuid);
select extensions.throws_ok(
  $sql$ select public.admin_resolve_course_template_proposal((select id from public.course_template_edit_proposals where operation_id='f16a0000-0000-4000-8000-000000000008'),'approve','stale merged target','f16a0000-0000-4000-8000-000000000009'::uuid) $sql$,
  'PT409',null,'approval of a merged proposal requires a new canonical proposal'
);
select extensions.is(
  (public.admin_resolve_course_template_proposal((select id from public.course_template_edit_proposals where operation_id='f16a0000-0000-4000-8000-000000000008'),'reject','stale merged target','f16a0000-0000-4000-8000-000000000010'::uuid)->>'status'),
  'rejected','merged proposal can still be explicitly rejected'
);
select extensions.throws_ok(
  $sql$ select public.admin_merge_course_templates('f16b0000-0000-4000-8000-000000000001','f1630000-0000-4000-8000-000000000003',1,1,'missing','f16a0000-0000-4000-8000-000000000003'::uuid) $sql$,
  '42501',null,'merge validates a missing source before mutation'
);
update public.course_templates set status='hidden' where id='f1630000-0000-4000-8000-000000000003';
select extensions.throws_ok(
  $sql$ select public.admin_merge_course_templates('f1630000-0000-4000-8000-000000000001','f1630000-0000-4000-8000-000000000003',1,2,'hidden','f16a0000-0000-4000-8000-000000000004'::uuid) $sql$,
  '42501',null,'merge rejects a hidden target'
);
insert into public.course_templates(id,university_id,academic_year,term_id,title,normalized_title,day_of_week,period_no,created_by,status)
values ('f1690000-0000-4000-8000-000000000001','f1610000-0000-4000-8000-000000000002',2026,'f1620000-0000-4000-8000-000000000003','Other University Template','other university template',1,1,'f1600000-0000-4000-8000-000000000002','active');
update public.course_templates set status='active' where id='f1630000-0000-4000-8000-000000000001';
select extensions.throws_ok(
  $sql$ select public.admin_merge_course_templates('f1630000-0000-4000-8000-000000000001','f1690000-0000-4000-8000-000000000001',1,1,'cross university','f16a0000-0000-4000-8000-000000000005'::uuid) $sql$,
  '42501',null,'merge rejects cross-university targets'
);
update public.course_templates set canonical_template_id=id where id='f1630000-0000-4000-8000-000000000001';
select extensions.is(
  private.phase16_canonical_template('f1630000-0000-4000-8000-000000000001'),
  null::uuid,
  'canonical resolver fails closed on a self-cycle'
);
update private.global_admins set revoked_at=now() where user_id='f1600000-0000-4000-8000-000000000003';
set local role authenticated;
select extensions.throws_ok(
  $sql$ select public.admin_list_university_requests(10,0) $sql$,
  '42501',null,'revoked admin cannot read the university request queue'
);
reset role;

select * from finish();
rollback;
