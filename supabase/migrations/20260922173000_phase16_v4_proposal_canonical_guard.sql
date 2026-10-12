-- Phase 16 v4: an approval must target the exact canonical identity that was
-- proposed. Rejection remains available for stale/merged proposals.
begin;

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
    if private.phase16_canonical_template(p.template_id) is distinct from p.template_id then raise exception 'proposal target was merged; submit a new proposal against the canonical template' using errcode='PT409'; end if;
    select * into t from public.course_templates where id=p.template_id for update;
    if not found or t.status<>'active' or t.deleted_at is not null then raise exception 'template unavailable' using errcode='42501'; end if;
    if p.expected_template_version is distinct from t.version then raise exception 'template version conflict' using errcode='PT409'; end if;
    current:=jsonb_build_object('title',t.title,'instructor_name',t.instructor_name,'day_of_week',t.day_of_week,'period_no',t.period_no,'room',t.room);
    payload:=private.phase16_validate_template_payload(p.proposed_payload,current);
    update public.course_templates set title=case when payload ? 'title' then btrim(payload->>'title') else title end,normalized_title=case when payload ? 'title' then public.normalize_course_text(payload->>'title') else normalized_title end,instructor_name=case when payload ? 'instructor_name' then nullif(btrim(payload->>'instructor_name'),'') else instructor_name end,normalized_instructor_name=case when payload ? 'instructor_name' then public.normalize_course_text(payload->>'instructor_name') else normalized_instructor_name end,day_of_week=case when payload ? 'day_of_week' then (payload->>'day_of_week')::int else day_of_week end,period_no=case when payload ? 'period_no' then (payload->>'period_no')::int else period_no end,room=case when payload ? 'room' then nullif(btrim(payload->>'room'),'') else room end,normalized_room=case when payload ? 'room' then public.normalize_course_text(payload->>'room') else normalized_room end,updated_at=now() where id=t.id returning version into next_template_version;
  else next_template_version:=null; end if;
  update public.course_template_edit_proposals set status=case when p_action='approve' then 'approved' else 'rejected' end,reviewed_by=a,reviewed_at=now(),decision_reason=trim(p_reason),version=version+1,updated_at=now() where id=p.id;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata) values(a,'course_template_proposal_'||p_action,'course_template',target_id,jsonb_build_object('proposal_id',p.id,'reason',trim(p_reason),'template_version',next_template_version)) returning id into aid;
  r:=jsonb_build_object('proposal_id',p.id,'template_id',target_id,'status',case when p_action='approve' then 'approved' else 'rejected' end,'template_version',next_template_version,'audit_id',aid); perform private.admin_record(a,p_operation_id,'admin_resolve_course_template_proposal',h,r); return r;
end; $$;

revoke all on function public.admin_resolve_course_template_proposal(uuid,text,text,uuid) from public,anon;
grant execute on function public.admin_resolve_course_template_proposal(uuid,text,text,uuid) to authenticated;

commit;
