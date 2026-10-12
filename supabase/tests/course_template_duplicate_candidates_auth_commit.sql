-- Exercise the deferred generator at transaction commit with an authenticated
-- RPC caller. Cleanup targets only these dedicated fixtures in an isolated DB.
insert into auth.users(id) values
  ('e1800000-0000-4000-8000-000000000001') on conflict (id) do nothing;
insert into private.global_admins(user_id)
values ('e1800000-0000-4000-8000-000000000001')
on conflict (user_id) do update set revoked_at = null;
insert into public.universities(id,config_key,name,normalized_name,status)
values ('e1810000-0000-4000-8000-000000000001','auth-commit-duplicate-test',
  'Auth Commit Duplicate Test','authcommitduplicatetest','active');
insert into public.course_templates(
  id,university_id,academic_year,title,normalized_title,instructor_name,
  normalized_instructor_name,day_of_week,period_no,created_by,status
) values
 ('e1820000-0000-4000-8000-000000000001','e1810000-0000-4000-8000-000000000001',2026,
  'Commit Auth Duplicate',public.normalize_course_text('Commit Auth Duplicate'),'Prof Commit',
  public.normalize_course_text('Prof Commit'),1,1,'e1800000-0000-4000-8000-000000000001','active'),
 ('e1820000-0000-4000-8000-000000000002','e1810000-0000-4000-8000-000000000001',2026,
  'Commit Auth Duplicate',public.normalize_course_text('Commit Auth Duplicate'),'Prof Commit',
  public.normalize_course_text('Prof Commit'),1,1,'e1800000-0000-4000-8000-000000000001','active');
do $$ begin
  if not exists(select 1 from public.course_template_duplicate_candidates
    where template_a_id='e1820000-0000-4000-8000-000000000001'
      and template_b_id='e1820000-0000-4000-8000-000000000002'
      and status='pending') then
    raise exception 'insert did not create the expected synthetic pending candidate';
  end if;
end $$;

begin;
set local request.jwt.claim.sub='e1800000-0000-4000-8000-000000000001';
set local request.jwt.claim.role='authenticated';
set local request.jwt.claims='{"sub":"e1800000-0000-4000-8000-000000000001","role":"authenticated"}';
set local role authenticated;
select public.admin_merge_course_templates(
  'e1820000-0000-4000-8000-000000000001',
  'e1820000-0000-4000-8000-000000000002',
  1,1,'synthetic deferred-trigger permission check',
  gen_random_uuid()
);
commit;

do $$ begin
  if not exists(select 1 from public.course_template_duplicate_candidates
    where template_a_id='e1820000-0000-4000-8000-000000000001'
      and template_b_id='e1820000-0000-4000-8000-000000000002'
      and status='merged') then
    raise exception 'authenticated RPC commit did not preserve merged duplicate history';
  end if;
end $$;

delete from public.course_template_duplicate_candidates
where template_a_id in ('e1820000-0000-4000-8000-000000000001','e1820000-0000-4000-8000-000000000002')
   or template_b_id in ('e1820000-0000-4000-8000-000000000001','e1820000-0000-4000-8000-000000000002');
delete from public.course_templates
where id in ('e1820000-0000-4000-8000-000000000001','e1820000-0000-4000-8000-000000000002');
delete from public.universities where id='e1810000-0000-4000-8000-000000000001';
-- Keep the synthetic actor because its audit row is durable; revoke only the
-- test-only global-admin grant rather than erasing audit history.
update private.global_admins set revoked_at=clock_timestamp()
where user_id='e1800000-0000-4000-8000-000000000001';
