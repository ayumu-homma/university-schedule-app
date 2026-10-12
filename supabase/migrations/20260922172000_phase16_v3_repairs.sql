-- Phase 16 review correction v3. Append-only repairs for canonical lineage,
-- proposal decisions, and the reduced mobile-supported public field set.
begin;

-- Mobile's UserCourse model intentionally does not expose credit/syllabus or
-- external-code fields. Keep those fields out of proposal/update snapshots so
-- apply/reconcile has one consistent allowlist instead of silently dropping
-- fields during local reconciliation.
create or replace function private.phase16_validate_template_payload(p_payload jsonb,p_current jsonb)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare k text; v jsonb; allowed constant text[]:=array['title','instructor_name','day_of_week','period_no','room'];
begin
  if jsonb_typeof(p_payload)<>'object' or p_payload='{}'::jsonb then raise exception 'public template fields are required' using errcode='22023'; end if;
  for k in select key from jsonb_each(p_payload) loop
    if not (k=any(allowed)) then raise exception 'proposal field is not allowed' using errcode='22023'; end if;
    v:=p_payload->k;
    if k in ('title','instructor_name','room') and jsonb_typeof(v)<>'string' then raise exception 'proposal text field has invalid type' using errcode='22023'; end if;
    if k in ('day_of_week','period_no') and jsonb_typeof(v)<>'number' then raise exception 'proposal slot has invalid type' using errcode='22023'; end if;
  end loop;
  if p_payload ? 'title' and char_length(btrim(p_payload->>'title')) not between 1 and 200 then raise exception 'proposal title length is invalid' using errcode='22023'; end if;
  if p_payload ? 'instructor_name' and char_length(p_payload->>'instructor_name')>200 then raise exception 'proposal instructor length is invalid' using errcode='22023'; end if;
  if p_payload ? 'room' and char_length(p_payload->>'room')>100 then raise exception 'proposal room length is invalid' using errcode='22023'; end if;
  if p_payload ? 'day_of_week' and ((p_payload->>'day_of_week')::int not between 1 and 7 or (p_payload->>'day_of_week')::numeric<>(p_payload->>'day_of_week')::int) then raise exception 'proposal day is invalid' using errcode='22023'; end if;
  if p_payload ? 'period_no' and ((p_payload->>'period_no')::int not between 1 and 9 or (p_payload->>'period_no')::numeric<>(p_payload->>'period_no')::int) then raise exception 'proposal period is invalid' using errcode='22023'; end if;
  if not exists(select 1 from jsonb_each(p_payload) e where p_current->e.key is distinct from e.value) then raise exception 'proposal must change a public field' using errcode='22023'; end if;
  return p_payload;
end; $$;
revoke all on function private.phase16_validate_template_payload(jsonb,jsonb) from public,anon,authenticated,service_role;

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
  values(a,target_term_id,source_template.id,source_template.title,source_template.normalized_title,source_template.instructor_name,source_template.normalized_instructor_name,source_template.day_of_week,source_template.period_no,source_template.room,source_template.normalized_room,source_template.credit_count,source_template.syllabus_url,'PRIVATE',source_template.version,jsonb_build_object('canonical_template_id',source_template.id,'title',source_template.title,'instructor_name',source_template.instructor_name,'day_of_week',source_template.day_of_week,'period_no',source_template.period_no,'room',source_template.room),'none') returning id into new_course_id;
  insert into public.course_template_copy_events(template_id,copied_by,user_course_id) values(source_template.id,a,new_course_id);
  update public.course_templates set copy_count_total=(select count(distinct e.user_course_id) from public.course_template_copy_events e where e.user_course_id is not null and private.phase16_canonical_template(e.template_id)=source_template.id),copy_count_term=(select count(distinct e.user_course_id) from public.course_template_copy_events e join public.user_courses uc on uc.id=e.user_course_id join public.terms personal_term on personal_term.id=uc.term_id where e.user_course_id is not null and private.phase16_canonical_template(e.template_id)=source_template.id and personal_term.source_template_id=source_template.term_id) where id=source_template.id;
  return new_course_id;
end; $$;
revoke all on function public.copy_course_template(uuid,uuid) from public,anon;
grant execute on function public.copy_course_template(uuid,uuid) to authenticated;

create or replace function public.get_course_template_update(p_user_course_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); c record; t record; current jsonb; old jsonb; changed jsonb; old_canonical uuid;
begin
  select * into c from public.user_courses where id=p_user_course_id and owner_user_id=a and deleted_at is null;
  if not found or c.source_template_id is null then return jsonb_build_object('available',false,'reason','not_template_copy'); end if;
  select * into t from public.course_templates where id=private.phase16_canonical_template(c.source_template_id) and status='active' and deleted_at is null;
  if not found or c.source_template_snapshot is null then return jsonb_build_object('available',false,'state',coalesce(c.template_update_state,'none')); end if;
  old:=c.source_template_snapshot; old_canonical:=coalesce(nullif(old->>'canonical_template_id','')::uuid,c.source_template_id);
  current:=jsonb_build_object('canonical_template_id',t.id,'title',t.title,'instructor_name',t.instructor_name,'day_of_week',t.day_of_week,'period_no',t.period_no,'room',t.room);
  select coalesce(jsonb_object_agg(k,value),'{}'::jsonb) into changed from jsonb_each(current) e(k,value) where old->k is distinct from value;
  if old_canonical is not distinct from t.id and changed='{}'::jsonb then return jsonb_build_object('available',false,'state',coalesce(c.template_update_state,'none')); end if;
  return jsonb_build_object('available',true,'state','available','course_id',c.id,'course_version',c.version,'source_template_id',t.id,'source_version',coalesce(c.source_template_version,0),'template_version',t.version,'before',old,'after',current,'changed',changed);
end; $$;

create or replace function public.review_course_template_update(p_user_course_id uuid,p_action text,p_expected_template_version bigint,p_expected_course_version bigint,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); h text; r jsonb; c record; t record; snapshot jsonb; updated_version bigint; canonical_id uuid;
begin
  if a is null then raise exception 'authentication required' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('course_id',p_user_course_id,'action',p_action,'expected_template_version',p_expected_template_version,'expected_course_version',p_expected_course_version)::text,'sha256'),'hex');
  r:=private.phase16_student_lock(a,p_operation_id,'review_course_template_update',h); if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  if p_action not in('apply','ignore') then raise exception 'invalid template update action' using errcode='22023'; end if;
  select * into c from public.user_courses where id=p_user_course_id and owner_user_id=a and deleted_at is null for update;
  if not found or c.source_template_id is null then raise exception 'owned template copy is required' using errcode='42501'; end if;
  if p_expected_course_version is null or c.version<>p_expected_course_version then raise exception 'personal course version conflict' using errcode='PT409'; end if;
  canonical_id:=private.phase16_canonical_template(c.source_template_id);
  select * into t from public.course_templates where id=canonical_id and status='active' and deleted_at is null for update;
  if not found then raise exception 'course template is unavailable' using errcode='42501'; end if;
  if p_expected_template_version is null or t.version<>p_expected_template_version then raise exception 'course template version conflict' using errcode='PT409'; end if;
  snapshot:=jsonb_build_object('canonical_template_id',t.id,'title',t.title,'instructor_name',t.instructor_name,'day_of_week',t.day_of_week,'period_no',t.period_no,'room',t.room);
  if p_action='ignore' then
    update public.user_courses set source_template_id=t.id,source_template_version=t.version,source_template_snapshot=snapshot,template_update_state='ignored' where id=c.id returning version into updated_version;
  else
    update public.user_courses set source_template_id=t.id,title=t.title,normalized_title=t.normalized_title,instructor_name=t.instructor_name,normalized_instructor_name=t.normalized_instructor_name,day_of_week=t.day_of_week,period_no=t.period_no,room=t.room,normalized_room=t.normalized_room,source_template_version=t.version,source_template_snapshot=snapshot,template_update_state='applied' where id=c.id returning version into updated_version;
  end if;
  r:=jsonb_build_object('course_id',c.id,'action',p_action,'template_version',t.version,'course_version',updated_version,'id',c.id,'ownerUserId',a,'termId',c.term_id,'sourceTemplateId',t.id,'title',case when p_action='apply' then t.title else c.title end,'normalizedTitle',case when p_action='apply' then t.normalized_title else c.normalized_title end,'instructorName',case when p_action='apply' then t.instructor_name else c.instructor_name end,'normalizedInstructorName',case when p_action='apply' then t.normalized_instructor_name else c.normalized_instructor_name end,'dayOfWeek',case when p_action='apply' then t.day_of_week else c.day_of_week end,'periodNo',case when p_action='apply' then t.period_no else c.period_no end,'room',case when p_action='apply' then t.room else c.room end,'color',c.color,'visibilityLevel',c.visibility_level,'updatedAt',now(),'deletedAt',null,'version',updated_version);
  perform private.phase16_student_record(a,p_operation_id,'review_course_template_update',h,r); return r;
end; $$;

-- Rejection is allowed to resolve a stale/hidden proposal. Only approval needs
-- a live canonical target and a matching template version.
create or replace function public.admin_resolve_course_template_proposal(p_proposal_id uuid,p_action text,p_reason text,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=private.require_global_admin(); h text; r jsonb; p record; t record; payload jsonb; current jsonb; aid uuid; next_template_version bigint; target_id uuid;
begin
  h:=encode(extensions.digest(jsonb_build_object('proposal_id',p_proposal_id,'action',p_action,'reason',p_reason)::text,'sha256'),'hex'); r:=private.admin_lock(a,p_operation_id,'admin_resolve_course_template_proposal',h); if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  if p_action not in('approve','reject') or length(trim(coalesce(p_reason,'')))<1 then raise exception 'invalid proposal decision' using errcode='22023'; end if;
  select x.* into p from public.course_template_edit_proposals x where x.id=p_proposal_id for update; if not found then raise exception 'proposal unavailable' using errcode='42501'; end if;
  if p.status<>'pending' or p.version<1 then raise exception 'proposal already resolved' using errcode='PT409'; end if;
  target_id:=p.template_id;
  if p_action='approve' then
    select * into t from public.course_templates where id=private.phase16_canonical_template(p.template_id) for update;
    if not found or t.status<>'active' or t.deleted_at is not null then raise exception 'template unavailable' using errcode='42501'; end if;
    target_id:=t.id;
    if p.expected_template_version is distinct from t.version then raise exception 'template version conflict' using errcode='PT409'; end if;
    current:=jsonb_build_object('title',t.title,'instructor_name',t.instructor_name,'day_of_week',t.day_of_week,'period_no',t.period_no,'room',t.room);
    payload:=private.phase16_validate_template_payload(p.proposed_payload,current);
    update public.course_templates set title=case when payload ? 'title' then btrim(payload->>'title') else title end,normalized_title=case when payload ? 'title' then public.normalize_course_text(payload->>'title') else normalized_title end,instructor_name=case when payload ? 'instructor_name' then nullif(btrim(payload->>'instructor_name'),'') else instructor_name end,normalized_instructor_name=case when payload ? 'instructor_name' then public.normalize_course_text(payload->>'instructor_name') else normalized_instructor_name end,day_of_week=case when payload ? 'day_of_week' then (payload->>'day_of_week')::int else day_of_week end,period_no=case when payload ? 'period_no' then (payload->>'period_no')::int else period_no end,room=case when payload ? 'room' then nullif(btrim(payload->>'room'),'') else room end,normalized_room=case when payload ? 'room' then public.normalize_course_text(payload->>'room') else normalized_room end,updated_at=now() where id=t.id returning version into next_template_version;
  end if;
  if p_action='reject' then next_template_version:=null; end if;
  update public.course_template_edit_proposals set status=case when p_action='approve' then 'approved' else 'rejected' end,reviewed_by=a,reviewed_at=now(),decision_reason=trim(p_reason),version=version+1,updated_at=now() where id=p.id;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata) values(a,'course_template_proposal_'||p_action,'course_template',target_id,jsonb_build_object('proposal_id',p.id,'reason',trim(p_reason),'template_version',next_template_version)) returning id into aid;
  r:=jsonb_build_object('proposal_id',p.id,'template_id',target_id,'status',case when p_action='approve' then 'approved' else 'rejected' end,'template_version',next_template_version,'audit_id',aid); perform private.admin_record(a,p_operation_id,'admin_resolve_course_template_proposal',h,r); return r;
end; $$;

create or replace function public.admin_merge_course_templates(p_source_template_id uuid,p_target_template_id uuid,p_expected_source_version bigint,p_expected_target_version bigint,p_reason text,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=private.require_global_admin(); h text; r jsonb; s record; t record; aid uuid; source_next bigint; target_next bigint;
begin
  h:=encode(extensions.digest(jsonb_build_object('source',p_source_template_id,'target',p_target_template_id,'source_version',p_expected_source_version,'target_version',p_expected_target_version,'reason',p_reason)::text,'sha256'),'hex'); r:=private.admin_lock(a,p_operation_id,'admin_merge_course_templates',h); if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  if p_source_template_id is null or p_target_template_id is null or p_source_template_id=p_target_template_id or length(trim(coalesce(p_reason,'')))<1 then raise exception 'self merge is not allowed' using errcode='PT409'; end if;
  perform pg_advisory_xact_lock(hashtextextended('template-merge:'||least(p_source_template_id,p_target_template_id)::text||':'||greatest(p_source_template_id,p_target_template_id)::text,9016));
  select * into s from public.course_templates where id=p_source_template_id for update;
  if not found then raise exception 'source merge template is unavailable' using errcode='42501'; end if;
  select * into t from public.course_templates where id=p_target_template_id for update;
  if not found then raise exception 'target merge template is unavailable' using errcode='42501'; end if;
  if s.status<>'active' or s.deleted_at is not null or t.status<>'active' or t.deleted_at is not null or s.university_id<>t.university_id then raise exception 'active same-university merge targets are required' using errcode='42501'; end if;
  if private.phase16_canonical_template(s.id)<>s.id or private.phase16_canonical_template(t.id)<>t.id then raise exception 'template merge target is already merged' using errcode='PT409'; end if;
  if p_expected_source_version is null or p_expected_target_version is null or s.version<>p_expected_source_version or t.version<>p_expected_target_version then raise exception 'template merge version conflict' using errcode='PT409'; end if;
  update public.course_templates set status='merged',canonical_template_id=t.id,merged_at=now(),merged_by=a,updated_at=now() where id=s.id returning version into source_next;
  update public.course_template_duplicate_candidates set status='merged',merged_template_id=t.id,reviewed_by=a,reviewed_at=now(),decision_reason=trim(p_reason),version=version+1 where status='pending' and ((template_a_id=s.id and template_b_id=t.id) or (template_a_id=t.id and template_b_id=s.id));
  update public.course_templates set copy_count_total=(select count(distinct e.user_course_id) from public.course_template_copy_events e where e.user_course_id is not null and private.phase16_canonical_template(e.template_id)=t.id),copy_count_term=(select count(distinct e.user_course_id) from public.course_template_copy_events e join public.user_courses uc on uc.id=e.user_course_id join public.terms personal_term on personal_term.id=uc.term_id where e.user_course_id is not null and private.phase16_canonical_template(e.template_id)=t.id and personal_term.source_template_id=t.term_id),updated_at=now() where id=t.id returning version into target_next;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata) values(a,'course_template_merge','course_template',s.id,jsonb_build_object('target_template_id',t.id,'reason',trim(p_reason),'source_version',source_next,'target_version',target_next)) returning id into aid;
  r:=jsonb_build_object('source_template_id',s.id,'target_template_id',t.id,'status','merged','source_version',source_next,'target_version',target_next,'audit_id',aid); perform private.admin_record(a,p_operation_id,'admin_merge_course_templates',h,r); return r;
end; $$;

revoke all on function public.admin_resolve_course_template_proposal(uuid,text,text,uuid),public.admin_merge_course_templates(uuid,uuid,bigint,bigint,text,uuid) from public,anon;
grant execute on function public.admin_resolve_course_template_proposal(uuid,text,text,uuid),public.admin_merge_course_templates(uuid,uuid,bigint,bigint,text,uuid) to authenticated;

commit;
