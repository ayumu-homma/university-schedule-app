-- Phase 16 publication-link and historical counter regressions.
begin;
select plan(7);

insert into auth.users(id) values
  ('f1760000-0000-4000-8000-000000000001'),
  ('f1760000-0000-4000-8000-000000000002')
on conflict(id) do nothing;
insert into public.universities(id,config_key,name,normalized_name,status)
values
  ('f1761000-0000-4000-8000-000000000001','phase176:a','Phase 176 A','phase176a','active'),
  ('f1761000-0000-4000-8000-000000000002','phase176:b','Phase 176 B','phase176b','active')
on conflict(id) do nothing;
insert into public.profiles(user_id,display_name,university_id)
values
  ('f1760000-0000-4000-8000-000000000001','Phase 176 A','f1761000-0000-4000-8000-000000000001'),
  ('f1760000-0000-4000-8000-000000000002','Phase 176 B','f1761000-0000-4000-8000-000000000001')
on conflict(user_id) do update set university_id=excluded.university_id;
insert into public.terms(
  id,university_id,name,academic_year,start_date,end_date,term_type,
  created_by,is_template,owner_user_id,source_template_id,status
)
values
  ('f1762000-0000-4000-8000-000000000001','f1761000-0000-4000-8000-000000000001','Catalog A',2026,'2026-04-01','2026-09-30','semester',null,true,null,null,'active'),
  ('f1762000-0000-4000-8000-000000000002','f1761000-0000-4000-8000-000000000001','Personal A',2026,'2026-04-01','2026-09-30','semester','f1760000-0000-4000-8000-000000000001',false,'f1760000-0000-4000-8000-000000000001','f1762000-0000-4000-8000-000000000001','active'),
  ('f1762000-0000-4000-8000-000000000003','f1761000-0000-4000-8000-000000000002','Catalog B',2026,'2026-04-01','2026-09-30','semester',null,true,null,null,'active'),
  ('f1762000-0000-4000-8000-000000000004','f1761000-0000-4000-8000-000000000001','Personal B',2026,'2026-04-01','2026-09-30','semester','f1760000-0000-4000-8000-000000000002',false,'f1760000-0000-4000-8000-000000000002','f1762000-0000-4000-8000-000000000001','active')
on conflict(id) do nothing;
insert into public.user_courses(
  id,owner_user_id,term_id,title,normalized_title,instructor_name,
  normalized_instructor_name,day_of_week,period_no,room,visibility_level
)
values
  ('f1764000-0000-4000-8000-000000000001','f1760000-0000-4000-8000-000000000001','f1762000-0000-4000-8000-000000000002','Hidden link','hidden link','Teacher','teacher',1,1,'A-1','PRIVATE'),
  ('f1764000-0000-4000-8000-000000000002','f1760000-0000-4000-8000-000000000001','f1762000-0000-4000-8000-000000000002','Foreign link','foreign link','Teacher','teacher',2,2,'A-2','PRIVATE'),
  ('f1764000-0000-4000-8000-000000000003','f1760000-0000-4000-8000-000000000001','f1762000-0000-4000-8000-000000000002','Copied A','copied a','Teacher','teacher',3,3,'A-3','PRIVATE'),
  ('f1764000-0000-4000-8000-000000000004','f1760000-0000-4000-8000-000000000002','f1762000-0000-4000-8000-000000000004','Copied B','copied b','Teacher','teacher',4,4,'A-4','PRIVATE')
on conflict(id) do nothing;
create temporary table phase16_course_before as
select to_jsonb(uc) as row_value
  from public.user_courses uc
 where uc.id='f1764000-0000-4000-8000-000000000003';
insert into public.course_templates(
  id,university_id,academic_year,term_id,title,normalized_title,
  instructor_name,normalized_instructor_name,day_of_week,period_no,
  created_by,status,published_from_course_id
)
values
  ('f1763000-0000-4000-8000-000000000001','f1761000-0000-4000-8000-000000000001',2026,'f1762000-0000-4000-8000-000000000001','Hidden linked','hidden linked','Teacher','teacher',1,1,'f1760000-0000-4000-8000-000000000001','hidden','f1764000-0000-4000-8000-000000000001'),
  ('f1763000-0000-4000-8000-000000000002','f1761000-0000-4000-8000-000000000002',2026,'f1762000-0000-4000-8000-000000000003','Foreign linked','foreign linked','Teacher','teacher',2,2,'f1760000-0000-4000-8000-000000000001','active','f1764000-0000-4000-8000-000000000002'),
  ('f1763000-0000-4000-8000-000000000003','f1761000-0000-4000-8000-000000000001',2026,'f1762000-0000-4000-8000-000000000001','Counter source','counter source','Teacher','teacher',3,3,'f1760000-0000-4000-8000-000000000001','active',null)
on conflict(id) do nothing;
insert into public.course_template_copy_events(template_id,copied_by,user_course_id)
values
  ('f1763000-0000-4000-8000-000000000003','f1760000-0000-4000-8000-000000000001','f1764000-0000-4000-8000-000000000003'),
  ('f1763000-0000-4000-8000-000000000003','f1760000-0000-4000-8000-000000000001','f1764000-0000-4000-8000-000000000003'),
  ('f1763000-0000-4000-8000-000000000003','f1760000-0000-4000-8000-000000000002','f1764000-0000-4000-8000-000000000004');
update public.course_templates
   set copy_count_total=99,copy_count_term=99
 where id='f1763000-0000-4000-8000-000000000003';

set local request.jwt.claims='{"sub":"f1760000-0000-4000-8000-000000000001","role":"authenticated"}';
set local request.jwt.claim.sub='f1760000-0000-4000-8000-000000000001';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.throws_ok(
  $sql$ select public.publish_course_template('f1764000-0000-4000-8000-000000000001','f1765000-0000-4000-8000-000000000001'::uuid) $sql$,
  'PT409',null,'hidden linked publication is rejected as a business conflict'
);
select extensions.throws_ok(
  $sql$ select public.publish_course_template('f1764000-0000-4000-8000-000000000002','f1765000-0000-4000-8000-000000000002'::uuid) $sql$,
  'PT409',null,'cross-university linked publication is rejected as a business conflict'
);
reset role;
select extensions.lives_ok(
  $sql$ select private.phase16_recompute_template_copy_counts() $sql$,
  'historical counter repair is an internal no-result operation'
);
select extensions.is(
  (select copy_count_total from public.course_templates where id='f1763000-0000-4000-8000-000000000003'),
  2,
  'historical total count uses distinct copied personal courses'
);
select extensions.is(
  (select copy_count_term from public.course_templates where id='f1763000-0000-4000-8000-000000000003'),
  2,
  'historical term count joins personal source_template_id to catalog term'
);
select extensions.is(
  (select to_jsonb(uc) from public.user_courses uc where uc.id='f1764000-0000-4000-8000-000000000003'),
  (select row_value from phase16_course_before),
  'counter repair preserves copied user_course bytes'
);
select extensions.ok(
  not has_table_privilege('authenticated','public.course_template_copy_events','SELECT')
  and has_table_privilege('service_role','public.course_template_copy_events','SELECT'),
  'copy-event evidence is backend-readable but not client-readable'
);

select * from finish();
rollback;
