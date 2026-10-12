-- Phase 16 admin/version and duplicate-projection repairs.
begin;

drop function if exists public.admin_list_course_template_duplicates(int,int);
create function public.admin_list_course_template_duplicates(p_limit int default 50,p_offset int default 0)
returns table(candidate_id uuid,university_id uuid,template_a_id uuid,template_b_id uuid,score numeric,status text,version bigint,created_at timestamptz,template_a_title text,template_b_title text,template_a_version bigint,template_b_version bigint)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
begin
  perform private.require_global_admin();
  return query
    select d.id,d.university_id,d.template_a_id,d.template_b_id,d.score,d.status,d.version,d.created_at,a.title,b.title,a.version,b.version
    from public.course_template_duplicate_candidates d
    left join public.course_templates a on a.id=d.template_a_id
    left join public.course_templates b on b.id=d.template_b_id
    where d.status='pending'
    order by d.score desc,d.created_at,d.id
    limit least(greatest(p_limit,1),100) offset greatest(p_offset,0);
end; $$;
revoke all on function public.admin_list_course_template_duplicates(int,int) from public,anon;
grant execute on function public.admin_list_course_template_duplicates(int,int) to authenticated;

create or replace function public.admin_resolve_course_template_proposal(p_proposal_id uuid,p_action text,p_reason text,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=private.require_global_admin(); h text; r jsonb; p record; t record; payload jsonb; current jsonb; aid uuid; next_template_version bigint;
begin
  h:=encode(extensions.digest(jsonb_build_object('proposal_id',p_proposal_id,'action',p_action,'reason',p_reason)::text,'sha256'),'hex'); r:=private.admin_lock(a,p_operation_id,'admin_resolve_course_template_proposal',h); if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  if p_action not in('approve','reject') or length(trim(coalesce(p_reason,'')))<1 then raise exception 'invalid proposal decision' using errcode='22023'; end if;
  select x.* into p from public.course_template_edit_proposals x where x.id=p_proposal_id for update; if not found then raise exception 'proposal unavailable' using errcode='42501'; end if;
  if p.status<>'pending' or p.version<1 then raise exception 'proposal already resolved' using errcode='PT409'; end if;
  select * into t from public.course_templates where id=private.phase16_canonical_template(p.template_id) for update; if not found or t.status<>'active' then raise exception 'template unavailable' using errcode='42501'; end if;
  current:=jsonb_build_object('title',t.title,'instructor_name',t.instructor_name,'day_of_week',t.day_of_week,'period_no',t.period_no,'room',t.room,'credit_count',t.credit_count,'syllabus_url',t.syllabus_url,'external_course_code',t.external_course_code);
  payload:=private.phase16_validate_template_payload(p.proposed_payload,current);
  if p_action='approve' then
    if p.expected_template_version is distinct from t.version then raise exception 'template version conflict' using errcode='PT409'; end if;
    update public.course_templates set title=case when payload ? 'title' then btrim(payload->>'title') else title end,normalized_title=case when payload ? 'title' then public.normalize_course_text(payload->>'title') else normalized_title end,instructor_name=case when payload ? 'instructor_name' then nullif(btrim(payload->>'instructor_name'),'') else instructor_name end,normalized_instructor_name=case when payload ? 'instructor_name' then public.normalize_course_text(payload->>'instructor_name') else normalized_instructor_name end,day_of_week=case when payload ? 'day_of_week' then (payload->>'day_of_week')::int else day_of_week end,period_no=case when payload ? 'period_no' then (payload->>'period_no')::int else period_no end,room=case when payload ? 'room' then nullif(btrim(payload->>'room'),'') else room end,normalized_room=case when payload ? 'room' then public.normalize_course_text(payload->>'room') else normalized_room end,credit_count=case when payload ? 'credit_count' then (payload->>'credit_count')::numeric else credit_count end,syllabus_url=case when payload ? 'syllabus_url' then nullif(btrim(payload->>'syllabus_url'),'') else syllabus_url end,external_course_code=case when payload ? 'external_course_code' then nullif(btrim(payload->>'external_course_code'),'') else external_course_code end,updated_at=now() where id=t.id returning version into next_template_version;
  else next_template_version:=t.version; end if;
  update public.course_template_edit_proposals set status=case when p_action='approve' then 'approved' else 'rejected' end,reviewed_by=a,reviewed_at=now(),decision_reason=trim(p_reason),version=version+1,updated_at=now() where id=p.id;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata) values(a,'course_template_proposal_'||p_action,'course_template',t.id,jsonb_build_object('proposal_id',p.id,'reason',trim(p_reason),'template_version',next_template_version)) returning id into aid;
  r:=jsonb_build_object('proposal_id',p.id,'template_id',t.id,'status',case when p_action='approve' then 'approved' else 'rejected' end,'template_version',next_template_version,'audit_id',aid); perform private.admin_record(a,p_operation_id,'admin_resolve_course_template_proposal',h,r); return r;
end; $$;

create or replace function public.admin_resolve_course_template_report(p_report_id uuid,p_action text,p_reason text,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=private.require_global_admin(); h text; r jsonb; q record; t record; state text; aid uuid; next_template_version bigint;
begin
  h:=encode(extensions.digest(jsonb_build_object('report_id',p_report_id,'action',p_action,'reason',p_reason)::text,'sha256'),'hex'); r:=private.admin_lock(a,p_operation_id,'admin_resolve_course_template_report',h); if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  if p_action not in('dismiss','hide') or length(trim(coalesce(p_reason,'')))<1 then raise exception 'invalid template report decision' using errcode='22023'; end if;
  select * into q from public.course_template_reports where id=p_report_id for update; if not found or q.status<>'pending' or q.version<1 then raise exception 'template report unavailable or already resolved' using errcode='PT409'; end if;
  select * into t from public.course_templates where id=private.phase16_canonical_template(q.template_id) for update;
  if not found then state:='target_missing'; next_template_version:=null;
  elsif p_action='hide' and t.status='active' then update public.course_templates set status='hidden',moderation_hidden_at=now(),moderation_hidden_by=a,moderation_reason=trim(p_reason),updated_at=now() where id=t.id returning version into next_template_version; state:='hidden';
  elsif t.status='hidden' then state:='already_hidden'; next_template_version:=t.version;
  else state:='unchanged'; next_template_version:=t.version; end if;
  update public.course_template_reports set status=case when p_action='hide' then 'actioned' else 'dismissed' end,reviewed_by=a,reviewed_at=now(),decision_reason=trim(p_reason),version=version+1,updated_at=now() where id=q.id;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata) values(a,'course_template_report_'||p_action,'course_template',q.template_id,jsonb_build_object('report_id',q.id,'reason',trim(p_reason),'target_state',state,'template_version',next_template_version)) returning id into aid;
  r:=jsonb_build_object('report_id',q.id,'status',case when p_action='hide' then 'actioned' else 'dismissed' end,'target_state',state,'template_version',next_template_version,'audit_id',aid); perform private.admin_record(a,p_operation_id,'admin_resolve_course_template_report',h,r); return r;
end; $$;

create or replace function public.admin_merge_course_templates(p_source_template_id uuid,p_target_template_id uuid,p_expected_source_version bigint,p_expected_target_version bigint,p_reason text,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=private.require_global_admin(); h text; r jsonb; s record; t record; aid uuid; source_next bigint; target_next bigint;
begin
  h:=encode(extensions.digest(jsonb_build_object('source',p_source_template_id,'target',p_target_template_id,'source_version',p_expected_source_version,'target_version',p_expected_target_version,'reason',p_reason)::text,'sha256'),'hex'); r:=private.admin_lock(a,p_operation_id,'admin_merge_course_templates',h); if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  if p_source_template_id is null or p_target_template_id is null or p_source_template_id=p_target_template_id or length(trim(coalesce(p_reason,'')))<1 then raise exception 'self merge is not allowed' using errcode='PT409'; end if;
  perform pg_advisory_xact_lock(hashtextextended('template-merge:'||least(p_source_template_id,p_target_template_id)::text||':'||greatest(p_source_template_id,p_target_template_id)::text,9016));
  select * into s from public.course_templates where id=p_source_template_id for update; select * into t from public.course_templates where id=p_target_template_id for update;
  if not found or s.status<>'active' or s.deleted_at is not null or t.status<>'active' or t.deleted_at is not null or s.university_id<>t.university_id then raise exception 'active same-university merge targets are required' using errcode='42501'; end if;
  if private.phase16_canonical_template(s.id)<>s.id or private.phase16_canonical_template(t.id)<>t.id then raise exception 'template merge target is already merged' using errcode='PT409'; end if;
  if p_expected_source_version is null or p_expected_target_version is null or s.version<>p_expected_source_version or t.version<>p_expected_target_version then raise exception 'template merge version conflict' using errcode='PT409'; end if;
  update public.course_templates set status='merged',canonical_template_id=t.id,merged_at=now(),merged_by=a,updated_at=now() where id=s.id returning version into source_next;
  update public.course_template_duplicate_candidates set status='merged',merged_template_id=t.id,reviewed_by=a,reviewed_at=now(),decision_reason=trim(p_reason),version=version+1 where status='pending' and ((template_a_id=s.id and template_b_id=t.id) or (template_a_id=t.id and template_b_id=s.id));
  update public.course_templates set copy_count_total=(select count(distinct e.user_course_id) from public.course_template_copy_events e where e.user_course_id is not null and private.phase16_canonical_template(e.template_id)=t.id),copy_count_term=(select count(distinct e.user_course_id) from public.course_template_copy_events e join public.user_courses uc on uc.id=e.user_course_id where e.user_course_id is not null and private.phase16_canonical_template(e.template_id)=t.id and uc.term_id=t.term_id),updated_at=now() where id=t.id returning version into target_next;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata) values(a,'course_template_merge','course_template',s.id,jsonb_build_object('target_template_id',t.id,'reason',trim(p_reason),'source_version',source_next,'target_version',target_next)) returning id into aid;
  r:=jsonb_build_object('source_template_id',s.id,'target_template_id',t.id,'status','merged','source_version',source_next,'target_version',target_next,'audit_id',aid); perform private.admin_record(a,p_operation_id,'admin_merge_course_templates',h,r); return r;
end; $$;

revoke all on function public.admin_list_course_template_duplicates(int,int),public.admin_resolve_course_template_proposal(uuid,text,text,uuid),public.admin_resolve_course_template_report(uuid,text,text,uuid),public.admin_merge_course_templates(uuid,uuid,bigint,bigint,text,uuid) from public,anon;
grant execute on function public.admin_list_course_template_duplicates(int,int),public.admin_resolve_course_template_proposal(uuid,text,text,uuid),public.admin_resolve_course_template_report(uuid,text,text,uuid),public.admin_merge_course_templates(uuid,uuid,bigint,bigint,text,uuid) to authenticated;

commit;
