-- Keep a trustworthy submission-time before-value snapshot for Phase 16
-- proposal review. Existing proposals remain NULL because their prior state
-- cannot be reconstructed safely.
begin;

alter table public.course_template_edit_proposals
  add column if not exists before_payload jsonb;

create or replace function public.submit_course_template_edit_proposal(
  p_template_id uuid,
  p_proposed_payload jsonb,
  p_expected_version bigint,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,private
as $$
declare
  a uuid:=auth.uid();
  h text;
  r jsonb;
  c record;
  payload jsonb;
  before_snapshot jsonb;
  proposal_id uuid;
  current jsonb;
begin
  if a is null then
    raise exception 'authentication required' using errcode='42501';
  end if;

  h:=encode(extensions.digest(jsonb_build_object(
    'template_id',p_template_id,
    'payload',p_proposed_payload,
    'expected_version',p_expected_version
  )::text,'sha256'),'hex');
  r:=private.phase16_student_lock(a,p_operation_id,'submit_course_template_edit_proposal',h);
  if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;

  select ct.* into c
  from public.course_templates ct
  join public.profiles p0 on p0.university_id=ct.university_id and p0.user_id=a
  where ct.id=private.phase16_canonical_template(p_template_id)
    and ct.status='active' and ct.deleted_at is null
  for update;
  if not found then
    raise exception 'course template is unavailable' using errcode='42501';
  end if;
  if p_expected_version is null or c.version<>p_expected_version then
    raise exception 'course template version conflict' using errcode='PT409';
  end if;

  current:=jsonb_build_object(
    'title',c.title,
    'instructor_name',c.instructor_name,
    'day_of_week',c.day_of_week,
    'period_no',c.period_no,
    'room',c.room,
    'credit_count',c.credit_count,
    'syllabus_url',c.syllabus_url,
    'external_course_code',c.external_course_code
  );
  payload:=private.phase16_validate_template_payload(p_proposed_payload,current);

  select coalesce(jsonb_object_agg(k.key,current->k.key),'{}'::jsonb)
    into before_snapshot
  from jsonb_object_keys(payload) as k(key);

  insert into public.course_template_edit_proposals(
    template_id,proposed_by,proposed_payload,before_payload,
    expected_template_version,operation_id
  ) values(c.id,a,payload,before_snapshot,c.version,p_operation_id)
  returning id into proposal_id;

  r:=jsonb_build_object(
    'proposal_id',proposal_id,
    'template_id',c.id,
    'status','pending',
    'expected_version',c.version
  );
  perform private.phase16_student_record(a,p_operation_id,'submit_course_template_edit_proposal',h,r);
  return r;
end;
$$;

revoke all on function public.submit_course_template_edit_proposal(uuid,jsonb,bigint,uuid)
  from public,anon,service_role;
grant execute on function public.submit_course_template_edit_proposal(uuid,jsonb,bigint,uuid)
  to authenticated;

create or replace function public.admin_get_course_template_proposal_change(p_proposal_id uuid)
returns table(
  proposal_id uuid,
  before_payload jsonb,
  proposed_payload jsonb,
  expected_template_version bigint,
  current_template_version bigint,
  current_payload jsonb,
  snapshot_available boolean
)
language plpgsql
stable
security definer
set search_path=pg_catalog,public,private
as $$
declare
  p record;
  t record;
begin
  perform private.require_global_admin();
  if p_proposal_id is null then
    raise exception 'proposal id is required' using errcode='22023';
  end if;

  select x.id,x.template_id,x.before_payload,x.proposed_payload,x.expected_template_version
    into p
  from public.course_template_edit_proposals x
  where x.id=p_proposal_id and x.status='pending';
  if not found then
    raise exception 'proposal unavailable' using errcode='42501';
  end if;

  select ct.version,
    jsonb_build_object(
      'title',ct.title,
      'instructor_name',ct.instructor_name,
      'day_of_week',ct.day_of_week,
      'period_no',ct.period_no,
      'room',ct.room,
      'credit_count',ct.credit_count,
      'syllabus_url',ct.syllabus_url,
      'external_course_code',ct.external_course_code
    ) as current_payload
    into t
  from public.course_templates ct
  where ct.id=private.phase16_canonical_template(p.template_id);
  if not found then
    raise exception 'template unavailable' using errcode='42501';
  end if;

  return query select
    p.id,
    p.before_payload,
    p.proposed_payload,
    p.expected_template_version,
    t.version,
    t.current_payload,
    p.before_payload is not null;
end;
$$;

revoke all on function public.admin_get_course_template_proposal_change(uuid)
  from public,anon,service_role;
grant execute on function public.admin_get_course_template_proposal_change(uuid)
  to authenticated;

commit;
