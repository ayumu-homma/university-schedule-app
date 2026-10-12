-- Phase 16 review corrections.  Append-only: this migration repairs the
-- already authored Phase 16 RPCs without changing any applied migration.
begin;

-- Private helpers are implementation details, including for service_role.
revoke all on function private.phase16_student_lock(uuid,uuid,text,text)
  from public, anon, authenticated, service_role;
revoke all on function private.phase16_student_record(uuid,uuid,text,text,jsonb)
  from public, anon, authenticated, service_role;
revoke all on function private.phase16_canonical_template(uuid)
  from public, anon, authenticated, service_role;

-- Authenticated clients use the redacted search/detail projections only.
revoke select on table public.course_templates from public, anon, authenticated;

create or replace function public.submit_university_request(
  p_name text,p_prefecture text,p_official_url text,p_operation_id uuid
)
returns uuid language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare
  a uuid:=auth.uid(); h text; r jsonb; request_id uuid;
  clean_name text; clean_pref text; clean_url text; n text;
begin
  if a is null then raise exception 'authentication required' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object(
    'name',p_name,'prefecture',p_prefecture,'official_url',p_official_url
  )::text,'sha256'),'hex');
  r:=private.phase16_student_lock(a,p_operation_id,'submit_university_request',h);
  if r is not null then return (r->>'request_id')::uuid; end if;

  clean_name:=btrim(coalesce(p_name,''));
  clean_pref:=nullif(btrim(p_prefecture),'');
  clean_url:=nullif(btrim(p_official_url),'');
  if char_length(clean_name) not between 2 and 120 then
    raise exception 'invalid university name' using errcode='22023';
  end if;
  if clean_pref is not null and char_length(clean_pref)>50 then
    raise exception 'invalid prefecture' using errcode='22023';
  end if;
  if clean_url is not null and (char_length(clean_url)>2048 or clean_url !~ '^https://') then
    raise exception 'official_url must be an HTTPS URL' using errcode='22023';
  end if;
  n:=public.normalize_course_text(clean_name);
  select id into request_id from public.university_requests
    where requested_by=a and operation_id=p_operation_id;
  if request_id is null then
    insert into public.university_requests(requested_by,name,normalized_name,prefecture,official_url,operation_id)
    values(a,clean_name,n,clean_pref,clean_url,p_operation_id)
    returning id into request_id;
  end if;
  r:=jsonb_build_object('request_id',request_id);
  perform private.phase16_student_record(a,p_operation_id,'submit_university_request',h,r);
  return request_id;
end; $$;

create or replace function public.publish_course_template(p_user_course_id uuid,p_operation_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); h text; r jsonb; c record; p record; t uuid; row jsonb;
begin
  if a is null then raise exception 'authentication required' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('course_id',p_user_course_id)::text,'sha256'),'hex');
  r:=private.phase16_student_lock(a,p_operation_id,'publish_course_template',h);
  if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  select uc.* into c from public.user_courses uc
    where uc.id=p_user_course_id and uc.owner_user_id=a and uc.deleted_at is null for update;
  if not found then raise exception 'owned course is required' using errcode='42501'; end if;
  select prof.* into p from public.profiles prof where prof.user_id=a and prof.deleted_at is null;
  if not found or p.university_id is null then raise exception 'university membership is required' using errcode='42501'; end if;
  if not exists(select 1 from public.terms x where x.id=c.term_id and x.university_id=p.university_id and x.deleted_at is null) then
    raise exception 'course term is not available' using errcode='42501';
  end if;
  select id into t from public.course_templates where published_from_course_id=c.id and status<>'deleted' order by created_at limit 1;
  if t is null then
    insert into public.course_templates(university_id,academic_year,term_id,title,normalized_title,instructor_name,normalized_instructor_name,day_of_week,period_no,room,normalized_room,credit_count,syllabus_url,created_by,published_from_course_id,source_template_version)
    select x.university_id,x.academic_year,x.id,c.title,public.normalize_course_text(c.title),c.instructor_name,public.normalize_course_text(c.instructor_name),c.day_of_week,c.period_no,c.room,public.normalize_course_text(c.room),c.credit_count,c.syllabus_url,a,c.id,c.version
    from public.terms x where x.id=c.term_id returning id into t;
  end if;
  row:=jsonb_build_object('template_id',t,'personal_course_id',c.id,'published',true,'personal_saved',true,'status','published');
  perform private.phase16_student_record(a,p_operation_id,'publish_course_template',h,row);
  return row;
end; $$;

create or replace function private.phase16_validate_template_payload(p_payload jsonb,p_current jsonb)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare k text; v jsonb; allowed constant text[]:=array['title','instructor_name','day_of_week','period_no','room','credit_count','syllabus_url','external_course_code'];
begin
  if jsonb_typeof(p_payload)<>'object' or p_payload='{}'::jsonb then raise exception 'public template fields are required' using errcode='22023'; end if;
  for k in select key from jsonb_each(p_payload) loop
    if not (k=any(allowed)) then raise exception 'proposal field is not allowed' using errcode='22023'; end if;
    v:=p_payload->k;
    if k in ('title','instructor_name','room','external_course_code') and jsonb_typeof(v)<>'string' then raise exception 'proposal text field has invalid type' using errcode='22023'; end if;
    if k in ('day_of_week','period_no') and jsonb_typeof(v)<>'number' then raise exception 'proposal slot has invalid type' using errcode='22023'; end if;
    if k='credit_count' and jsonb_typeof(v)<>'number' then raise exception 'proposal credit count has invalid type' using errcode='22023'; end if;
    if k='syllabus_url' and v<>'null'::jsonb and jsonb_typeof(v)<>'string' then raise exception 'proposal URL has invalid type' using errcode='22023'; end if;
  end loop;
  if p_payload ? 'title' and char_length(btrim(p_payload->>'title')) not between 1 and 200 then raise exception 'proposal title length is invalid' using errcode='22023'; end if;
  if p_payload ? 'instructor_name' and char_length(p_payload->>'instructor_name')>200 then raise exception 'proposal instructor length is invalid' using errcode='22023'; end if;
  if p_payload ? 'room' and char_length(p_payload->>'room')>100 then raise exception 'proposal room length is invalid' using errcode='22023'; end if;
  if p_payload ? 'external_course_code' and char_length(p_payload->>'external_course_code')>100 then raise exception 'proposal course code length is invalid' using errcode='22023'; end if;
  if p_payload ? 'syllabus_url' and p_payload->>'syllabus_url' is not null and (char_length(p_payload->>'syllabus_url')>2048 or p_payload->>'syllabus_url' !~ '^https://') then raise exception 'proposal syllabus URL is invalid' using errcode='22023'; end if;
  if p_payload ? 'day_of_week' and ((p_payload->>'day_of_week')::int not between 1 and 7 or (p_payload->>'day_of_week')::numeric<>(p_payload->>'day_of_week')::int) then raise exception 'proposal day is invalid' using errcode='22023'; end if;
  if p_payload ? 'period_no' and ((p_payload->>'period_no')::int not between 1 and 9 or (p_payload->>'period_no')::numeric<>(p_payload->>'period_no')::int) then raise exception 'proposal period is invalid' using errcode='22023'; end if;
  if p_payload ? 'credit_count' and ((p_payload->>'credit_count')::numeric not between 0 and 20) then raise exception 'proposal credit count is invalid' using errcode='22023'; end if;
  if not exists(select 1 from jsonb_each(p_payload) e where p_current->e.key is distinct from e.value) then raise exception 'proposal must change a public field' using errcode='22023'; end if;
  return p_payload;
end; $$;
revoke all on function private.phase16_validate_template_payload(jsonb,jsonb) from public,anon,authenticated,service_role;

create or replace function public.submit_course_template_edit_proposal(p_template_id uuid,p_proposed_payload jsonb,p_expected_version bigint,p_operation_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); h text; r jsonb; c record; payload jsonb; proposal_id uuid; current jsonb;
begin
  if a is null then raise exception 'authentication required' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('template_id',p_template_id,'payload',p_proposed_payload,'expected_version',p_expected_version)::text,'sha256'),'hex');
  r:=private.phase16_student_lock(a,p_operation_id,'submit_course_template_edit_proposal',h);
  if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  select ct.* into c from public.course_templates ct join public.profiles p0 on p0.university_id=ct.university_id and p0.user_id=a
    where ct.id=private.phase16_canonical_template(p_template_id) and ct.status='active' and ct.deleted_at is null for update;
  if not found then raise exception 'course template is unavailable' using errcode='42501'; end if;
  if p_expected_version is null or c.version<>p_expected_version then raise exception 'course template version conflict' using errcode='PT409'; end if;
  current:=jsonb_build_object('title',c.title,'instructor_name',c.instructor_name,'day_of_week',c.day_of_week,'period_no',c.period_no,'room',c.room,'credit_count',c.credit_count,'syllabus_url',c.syllabus_url,'external_course_code',c.external_course_code);
  payload:=private.phase16_validate_template_payload(p_proposed_payload,current);
  insert into public.course_template_edit_proposals(template_id,proposed_by,proposed_payload,expected_template_version,operation_id)
  values(c.id,a,payload,c.version,p_operation_id) returning id into proposal_id;
  r:=jsonb_build_object('proposal_id',proposal_id,'template_id',c.id,'status','pending','expected_version',c.version);
  perform private.phase16_student_record(a,p_operation_id,'submit_course_template_edit_proposal',h,r); return r;
end; $$;

create or replace function public.report_course_template(p_template_id uuid,p_reason text,p_operation_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); h text; r jsonb; c record; report_id uuid; inserted boolean:=false;
begin
  if a is null then raise exception 'authentication required' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('template_id',p_template_id,'reason',p_reason)::text,'sha256'),'hex');
  r:=private.phase16_student_lock(a,p_operation_id,'report_course_template',h);
  if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  if length(trim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'report reason is invalid' using errcode='22023'; end if;
  select ct.* into c from public.course_templates ct join public.profiles p on p.university_id=ct.university_id and p.user_id=a
    where ct.id=private.phase16_canonical_template(p_template_id) and ct.status='active' and ct.deleted_at is null;
  if not found then raise exception 'course template is unavailable' using errcode='42501'; end if;
  select id into report_id from public.course_template_reports where template_id=c.id and reported_by=a and status='pending' order by created_at limit 1;
  if report_id is null then
    insert into public.course_template_reports(template_id,reported_by,reason,operation_id) values(c.id,a,trim(p_reason),p_operation_id) returning id into report_id;
    inserted:=true;
    update public.course_templates set report_count=report_count+1 where id=c.id;
  end if;
  r:=jsonb_build_object('report_id',report_id,'template_id',c.id,'status','pending','new_report',inserted);
  perform private.phase16_student_record(a,p_operation_id,'report_course_template',h,r); return r;
end; $$;

create or replace function public.copy_course_template(template_id uuid,target_term_id uuid)
returns uuid language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); source_template public.course_templates%rowtype; canonical_id uuid; new_course_id uuid;
begin
  if a is null then raise exception 'authentication required' using errcode='42501'; end if;
  canonical_id:=private.phase16_canonical_template(template_id);
  select ct.* into source_template from public.course_templates ct join public.profiles p on p.user_id=a and p.university_id=ct.university_id where ct.id=canonical_id and ct.status='active' and ct.deleted_at is null;
  if not found then raise exception 'course template is not available for this university' using errcode='42501'; end if;
  if not exists(select 1 from public.terms t where t.id=target_term_id and t.owner_user_id=a and t.university_id=source_template.university_id and not t.is_template and t.status='active' and t.deleted_at is null) then raise exception 'owned active target term is required' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('copy-course:'||a::text||':'||source_template.id::text||':'||target_term_id::text,0));
  select uc.id into new_course_id from public.user_courses uc where uc.owner_user_id=a and uc.term_id=target_term_id and uc.deleted_at is null and private.phase16_canonical_template(uc.source_template_id)=canonical_id order by uc.created_at,uc.id limit 1;
  if found then return new_course_id; end if;
  insert into public.user_courses(owner_user_id,term_id,source_template_id,title,normalized_title,instructor_name,normalized_instructor_name,day_of_week,period_no,room,normalized_room,credit_count,syllabus_url,visibility_level,source_template_version,source_template_snapshot,template_update_state)
  values(a,target_term_id,source_template.id,source_template.title,source_template.normalized_title,source_template.instructor_name,source_template.normalized_instructor_name,source_template.day_of_week,source_template.period_no,source_template.room,source_template.normalized_room,source_template.credit_count,source_template.syllabus_url,'PRIVATE',source_template.version,jsonb_build_object('canonical_template_id',source_template.id,'title',source_template.title,'instructor_name',source_template.instructor_name,'day_of_week',source_template.day_of_week,'period_no',source_template.period_no,'room',source_template.room,'credit_count',source_template.credit_count,'syllabus_url',source_template.syllabus_url,'external_course_code',source_template.external_course_code),'none') returning id into new_course_id;
  insert into public.course_template_copy_events(template_id,copied_by,user_course_id) values(source_template.id,a,new_course_id);
  update public.course_templates set copy_count_total=(select count(distinct e.user_course_id) from public.course_template_copy_events e join public.course_templates lineage on private.phase16_canonical_template(e.template_id)=source_template.id where e.user_course_id is not null),copy_count_term=(select count(distinct e.user_course_id) from public.course_template_copy_events e join public.user_courses uc on uc.id=e.user_course_id join public.course_templates lineage on private.phase16_canonical_template(e.template_id)=source_template.id where e.user_course_id is not null and uc.term_id=source_template.term_id) where id=source_template.id;
  return new_course_id;
end; $$;

create or replace function public.get_course_template_update(p_user_course_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); c record; t record; current jsonb; old jsonb; changed jsonb; old_canonical uuid; canonical_changed boolean;
begin
  select * into c from public.user_courses where id=p_user_course_id and owner_user_id=a and deleted_at is null;
  if not found or c.source_template_id is null then return jsonb_build_object('available',false,'reason','not_template_copy'); end if;
  select * into t from public.course_templates where id=private.phase16_canonical_template(c.source_template_id) and status='active' and deleted_at is null;
  if not found or c.source_template_snapshot is null then return jsonb_build_object('available',false,'state',coalesce(c.template_update_state,'none')); end if;
  old:=c.source_template_snapshot; old_canonical:=coalesce(nullif(old->>'canonical_template_id','')::uuid,c.source_template_id); canonical_changed:=old_canonical is distinct from t.id;
  current:=jsonb_build_object('canonical_template_id',t.id,'title',t.title,'instructor_name',t.instructor_name,'day_of_week',t.day_of_week,'period_no',t.period_no,'room',t.room,'credit_count',t.credit_count,'syllabus_url',t.syllabus_url,'external_course_code',t.external_course_code);
  select coalesce(jsonb_object_agg(k,value),'{}'::jsonb) into changed from jsonb_each(current) e(k,value) where old->k is distinct from value or k='canonical_template_id' and canonical_changed;
  if not canonical_changed and changed='{}'::jsonb then return jsonb_build_object('available',false,'state',coalesce(c.template_update_state,'none')); end if;
  return jsonb_build_object('available',true,'state','available','course_id',c.id,'course_version',c.version,'source_template_id',t.id,'source_version',coalesce(c.source_template_version,0),'template_version',t.version,'before',old,'after',current,'changed',changed);
end; $$;

-- Five-argument form is the durable/idempotent apply entry point. The legacy
-- three-argument form is removed from client EXECUTE privileges below.
create or replace function public.review_course_template_update(p_user_course_id uuid,p_action text,p_expected_template_version bigint,p_expected_course_version bigint,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); h text; r jsonb; c record; t record; snapshot jsonb; next_state text; updated_version bigint; canonical_id uuid;
begin
  if a is null then raise exception 'authentication required' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('course_id',p_user_course_id,'action',p_action,'expected_template_version',p_expected_template_version,'expected_course_version',p_expected_course_version)::text,'sha256'),'hex');
  r:=private.phase16_student_lock(a,p_operation_id,'review_course_template_update',h);
  if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  if p_action not in('apply','ignore') then raise exception 'invalid template update action' using errcode='22023'; end if;
  select * into c from public.user_courses where id=p_user_course_id and owner_user_id=a and deleted_at is null for update;
  if not found or c.source_template_id is null then raise exception 'owned template copy is required' using errcode='42501'; end if;
  if p_expected_course_version is null or c.version<>p_expected_course_version then raise exception 'personal course version conflict' using errcode='PT409'; end if;
  canonical_id:=private.phase16_canonical_template(c.source_template_id);
  select * into t from public.course_templates where id=canonical_id and status='active' and deleted_at is null for update;
  if not found then raise exception 'course template is unavailable' using errcode='42501'; end if;
  if p_expected_template_version is null or t.version<>p_expected_template_version then raise exception 'course template version conflict' using errcode='PT409'; end if;
  snapshot:=jsonb_build_object('canonical_template_id',t.id,'title',t.title,'instructor_name',t.instructor_name,'day_of_week',t.day_of_week,'period_no',t.period_no,'room',t.room,'credit_count',t.credit_count,'syllabus_url',t.syllabus_url,'external_course_code',t.external_course_code);
  if p_action='ignore' then
    update public.user_courses set source_template_id=t.id,source_template_version=t.version,source_template_snapshot=snapshot,template_update_state='ignored' where id=c.id returning version into updated_version;
  else
    update public.user_courses set source_template_id=t.id,title=t.title,normalized_title=t.normalized_title,instructor_name=t.instructor_name,normalized_instructor_name=t.normalized_instructor_name,day_of_week=t.day_of_week,period_no=t.period_no,room=t.room,normalized_room=t.normalized_room,source_template_version=t.version,source_template_snapshot=snapshot,template_update_state='applied' where id=c.id returning version into updated_version;
  end if;
  r:=jsonb_build_object('course_id',c.id,'action',p_action,'template_version',t.version,'course_version',updated_version,'id',c.id,'ownerUserId',a,'termId',c.term_id,'sourceTemplateId',t.id,'title',case when p_action='apply' then t.title else c.title end,'normalizedTitle',case when p_action='apply' then t.normalized_title else c.normalized_title end,'instructorName',case when p_action='apply' then t.instructor_name else c.instructor_name end,'normalizedInstructorName',case when p_action='apply' then t.normalized_instructor_name else c.normalized_instructor_name end,'dayOfWeek',case when p_action='apply' then t.day_of_week else c.day_of_week end,'periodNo',case when p_action='apply' then t.period_no else c.period_no end,'room',case when p_action='apply' then t.room else c.room end,'color',c.color,'visibilityLevel',c.visibility_level,'updatedAt',now(),'deletedAt',null,'version',updated_version);
  perform private.phase16_student_record(a,p_operation_id,'review_course_template_update',h,r); return r;
end; $$;

create or replace function public.admin_list_university_requests(p_limit int default 50,p_offset int default 0)
returns table(request_id uuid,name text,prefecture text,official_url text,status text,created_at timestamptz,version bigint,decision_reason text,merged_into_university_id uuid,approved_university_id uuid)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$ begin perform private.require_global_admin(); return query select r.id,r.name,r.prefecture,r.official_url,r.status,r.created_at,r.version,r.decision_reason,r.merged_into_university_id,r.approved_university_id from public.university_requests r where r.status='pending' order by r.created_at,r.id limit least(greatest(p_limit,1),100) offset greatest(p_offset,0); end; $$;

create or replace function public.admin_update_university(p_university_id uuid,p_name text,p_aliases text[],p_prefecture text,p_status text,p_expected_version bigint,p_reason text,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=private.require_global_admin(); h text; r jsonb; u record; clean_name text:=btrim(coalesce(p_name,'')); clean_aliases text[]:=coalesce(p_aliases,'{}'); next_version bigint;
begin
  if char_length(clean_name) not between 2 and 160 or p_status not in('active','hidden') or length(trim(coalesce(p_reason,'')))<1 then raise exception 'invalid university master update' using errcode='22023'; end if;
  h:=encode(extensions.digest(jsonb_build_object('university_id',p_university_id,'name',p_name,'aliases',p_aliases,'prefecture',p_prefecture,'status',p_status,'expected_version',p_expected_version,'reason',p_reason)::text,'sha256'),'hex'); r:=private.admin_lock(a,p_operation_id,'admin_update_university',h); if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  select * into u from public.universities where id=p_university_id and deleted_at is null for update; if not found then raise exception 'university unavailable' using errcode='42501'; end if;
  if p_expected_version is null or u.version<>p_expected_version then raise exception 'university version conflict' using errcode='PT409'; end if;
  begin
    update public.universities set name=clean_name,normalized_name=public.normalize_course_text(clean_name),aliases=clean_aliases,prefecture=nullif(btrim(p_prefecture),''),status=p_status,updated_at=now() where id=u.id returning version into next_version;
  exception when unique_violation then raise exception 'university normalized name conflict' using errcode='PT409'; end;
  r:=jsonb_build_object('university_id',u.id,'status',p_status,'version',next_version); insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata) values(a,'university_master_update','university',u.id,jsonb_build_object('reason',trim(p_reason),'previous_version',u.version,'new_version',next_version)); perform private.admin_record(a,p_operation_id,'admin_update_university',h,r); return r;
end; $$;

-- Normalize approval decisions under one advisory key, and never permit a
-- direct targetless merged master state (merge requests always store a target).
create or replace function public.admin_resolve_university_request(p_request_id uuid,p_action text,p_target_university_id uuid,p_reason text,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=private.require_global_admin(); h text; r jsonb; q record; target uuid; created boolean:=false; next_status text;
begin
  h:=encode(extensions.digest(jsonb_build_object('request_id',p_request_id,'action',p_action,'target',p_target_university_id,'reason',p_reason)::text,'sha256'),'hex'); r:=private.admin_lock(a,p_operation_id,'admin_resolve_university_request',h); if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  if p_action not in('approve','reject','merge') or length(trim(coalesce(p_reason,'')))<1 or length(p_reason)>1000 then raise exception 'invalid university decision' using errcode='22023'; end if;
  select * into q from public.university_requests where id=p_request_id for update; if not found then raise exception 'university request unavailable' using errcode='42501'; end if;
  if q.status<>'pending' then raise exception 'university request already resolved' using errcode='PT409'; end if;
  if p_action='merge' then select id into target from public.universities where id=p_target_university_id and status='active' and deleted_at is null; if target is null then raise exception 'active target university required' using errcode='22023'; end if; next_status:='merged';
  elsif p_action='approve' then
    perform pg_advisory_xact_lock(hashtextextended('university-normalized:'||q.normalized_name,9016));
    begin
      select id into target from public.universities where normalized_name=q.normalized_name and status='active' and deleted_at is null limit 1;
      if target is null then insert into public.universities(name,normalized_name,prefecture) values(q.name,q.normalized_name,q.prefecture) returning id into target; created:=true; end if;
    exception when unique_violation then raise exception 'university normalized name conflict' using errcode='PT409'; end;
    next_status:='approved';
  else next_status:='rejected'; end if;
  update public.university_requests set status=next_status,resolved_by=a,resolved_at=now(),decision_reason=trim(p_reason),merged_into_university_id=case when p_action='merge' then target else null end,approved_university_id=case when p_action='approve' then target else null end,version=version+1,updated_at=now() where id=q.id;
  r:=jsonb_build_object('request_id',q.id,'status',next_status,'university_id',target,'created',created,'decision_reason',trim(p_reason)); insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata) values(a,'university_'||p_action,'university_request',q.id,r); perform private.admin_record(a,p_operation_id,'admin_resolve_university_request',h,r); return r;
end; $$;

-- Explicitly remove the unversioned legacy update entry point from clients;
-- mobile uses the five-argument receipt-backed operation below.
revoke all on function public.review_course_template_update(uuid,text,bigint) from public,anon,authenticated;
revoke all on function private.phase16_validate_template_payload(jsonb,jsonb) from service_role;
grant execute on function public.review_course_template_update(uuid,text,bigint,bigint,uuid) to authenticated;

commit;
