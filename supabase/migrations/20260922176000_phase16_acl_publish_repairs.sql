-- Phase 16 append-only convergence after the publication/catalog-term repair.
-- Do not edit or replay the retained Phase 6 stack with this file.
begin;

-- Phase 15's security contract is RPC-only for browser/mobile entry points.
-- Function creation grants EXECUTE to PUBLIC, so every replacement must
-- explicitly remove service_role as well as the public API roles.
revoke all on function public.submit_university_request(text,text,text,uuid)
  from public,anon,service_role;
grant execute on function public.submit_university_request(text,text,text,uuid)
  to authenticated;
revoke all on function public.submit_university_request(text,text,text)
  from public,anon,authenticated,service_role;
grant execute on function public.submit_university_request(text,text,text)
  to authenticated;
revoke all on function public.publish_course_template(uuid,uuid)
  from public,anon,service_role;
grant execute on function public.publish_course_template(uuid,uuid)
  to authenticated;
revoke all on function public.submit_course_template_edit_proposal(uuid,jsonb,bigint,uuid)
  from public,anon,service_role;
grant execute on function public.submit_course_template_edit_proposal(uuid,jsonb,bigint,uuid)
  to authenticated;
revoke all on function public.report_course_template(uuid,text,uuid)
  from public,anon,service_role;
grant execute on function public.report_course_template(uuid,text,uuid)
  to authenticated;
revoke all on function public.get_course_template_for_user(uuid)
  from public,anon,service_role;
grant execute on function public.get_course_template_for_user(uuid)
  to authenticated;
revoke all on function public.get_course_template_update(uuid)
  from public,anon,service_role;
grant execute on function public.get_course_template_update(uuid)
  to authenticated;
revoke all on function public.review_course_template_update(uuid,text,bigint)
  from public,anon,authenticated,service_role;
revoke all on function public.review_course_template_update(uuid,text,bigint,bigint,uuid)
  from public,anon,service_role;
grant execute on function public.review_course_template_update(uuid,text,bigint,bigint,uuid)
  to authenticated;
revoke all on function public.search_course_templates(text,uuid,integer,uuid,integer,integer,integer,text)
  from public,anon,service_role;
grant execute on function public.search_course_templates(text,uuid,integer,uuid,integer,integer,integer,text)
  to authenticated;
revoke all on function public.copy_course_template(uuid,uuid)
  from public,anon,service_role;
grant execute on function public.copy_course_template(uuid,uuid)
  to authenticated;

revoke all on function public.admin_list_university_requests(integer,integer),
  public.admin_resolve_university_request(uuid,text,uuid,text,uuid),
  public.admin_list_universities(integer,integer),
  public.admin_update_university(uuid,text,text[],text,text,bigint,text,uuid),
  public.admin_list_course_template_proposals(integer,integer),
  public.admin_list_course_template_reports(integer,integer),
  public.admin_list_course_template_duplicates(integer,integer),
  public.admin_resolve_course_template_proposal(uuid,text,text,uuid),
  public.admin_resolve_course_template_report(uuid,text,text,uuid),
  public.admin_merge_course_templates(uuid,uuid,bigint,bigint,text,uuid)
  from public,anon,service_role;
grant execute on function public.admin_list_university_requests(integer,integer),
  public.admin_resolve_university_request(uuid,text,uuid,text,uuid),
  public.admin_list_universities(integer,integer),
  public.admin_update_university(uuid,text,text[],text,text,bigint,text,uuid),
  public.admin_list_course_template_proposals(integer,integer),
  public.admin_list_course_template_reports(integer,integer),
  public.admin_list_course_template_duplicates(integer,integer),
  public.admin_resolve_course_template_proposal(uuid,text,text,uuid),
  public.admin_resolve_course_template_report(uuid,text,text,uuid),
  public.admin_merge_course_templates(uuid,uuid,bigint,bigint,text,uuid)
  to authenticated;

-- These tables are projections/receipts owned by SECURITY DEFINER RPCs.  The
-- source migrations intentionally preserve service_role's backend access to
-- Phase15 raw tables, but no API role may read or write Phase16 moderation
-- tables directly.  user_courses is the deliberate exception: authenticated
-- SELECT is needed by the established schedule read path, while all direct
-- mutations remain RPC-only.
revoke all on table public.course_templates,
  public.course_template_edit_proposals,
  public.course_template_reports,
  public.course_template_duplicate_candidates,
  public.course_template_copy_events
  from public,anon,authenticated;
grant select on table public.course_template_copy_events to service_role;
grant select on table public.user_courses to authenticated;
revoke insert,update,delete,truncate on table public.user_courses from authenticated;
revoke all on table public.user_courses from anon;

-- Re-assert the Phase15 table boundary in case the retained database has the
-- pre-convergence ACL.  These roles match the original Phase15 migration.
revoke all on table public.audit_logs,public.reports,private.global_admins,
  private.admin_operation_receipts from public,anon,authenticated;

-- Publication must never silently reuse a hidden, merged, deleted, foreign,
-- or otherwise malformed linked row.  A malformed existing link is a
-- deterministic business conflict; a new publication is allowed only after
-- the personal term and shared catalog identity have been validated.
create or replace function public.publish_course_template(p_user_course_id uuid,p_operation_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare
  a uuid:=auth.uid();
  h text;
  r jsonb;
  c record;
  p record;
  personal_term record;
  catalog_term record;
  linked public.course_templates%rowtype;
  linked_count integer;
  source_term_id uuid;
  t uuid;
  row jsonb;
begin
  if a is null then
    raise exception 'authentication required' using errcode='42501';
  end if;

  h:=encode(extensions.digest(
    jsonb_build_object('course_id',p_user_course_id)::text,'sha256'
  ),'hex');
  r:=private.phase16_student_lock(a,p_operation_id,'publish_course_template',h);
  if r is not null then
    return jsonb_set(r,'{replayed}','true'::jsonb,true);
  end if;

  select uc.* into c
    from public.user_courses uc
   where uc.id=p_user_course_id
     and uc.owner_user_id=a
     and uc.deleted_at is null
   for update;
  if not found then
    raise exception 'owned course is required' using errcode='42501';
  end if;

  select prof.* into p
    from public.profiles prof
   where prof.user_id=a and prof.deleted_at is null;
  if not found or p.university_id is null then
    raise exception 'university membership is required' using errcode='42501';
  end if;

  select x.* into personal_term
    from public.terms x
   where x.id=c.term_id
     and x.university_id=p.university_id
     and x.owner_user_id=a
     and not x.is_template
     and x.status='active'
     and x.deleted_at is null;
  if not found then
    raise exception 'course term is not available' using errcode='42501';
  end if;

  source_term_id:=coalesce(personal_term.source_template_id,personal_term.id);
  select x.* into catalog_term
    from public.terms x
   where x.id=source_term_id
     and x.university_id=p.university_id
     and x.is_template=(personal_term.source_template_id is not null)
     and x.status='active'
     and x.deleted_at is null;
  if not found then
    raise exception 'catalog source term is not available' using errcode='42501';
  end if;

  select count(*) into linked_count
    from public.course_templates x
   where x.published_from_course_id=c.id;
  if linked_count>1 then
    raise exception 'multiple linked course templates' using errcode='PT409';
  elsif linked_count=1 then
    select x.* into linked
      from public.course_templates x
     where x.published_from_course_id=c.id;
    if linked.status<>'active'
       or linked.deleted_at is not null
       or linked.created_by is distinct from a
       or linked.university_id is distinct from p.university_id
       or linked.term_id is distinct from catalog_term.id
       or linked.canonical_template_id is not null then
      raise exception 'linked course template is no longer publishable'
        using errcode='PT409';
    end if;
    t:=linked.id;
  else
    insert into public.course_templates(
      university_id,academic_year,term_id,title,normalized_title,
      instructor_name,normalized_instructor_name,day_of_week,period_no,
      room,normalized_room,credit_count,syllabus_url,created_by,
      published_from_course_id,source_template_version
    )
    select catalog_term.university_id,catalog_term.academic_year,catalog_term.id,
      c.title,public.normalize_course_text(c.title),c.instructor_name,
      public.normalize_course_text(c.instructor_name),c.day_of_week,c.period_no,
      c.room,public.normalize_course_text(c.room),c.credit_count,c.syllabus_url,
      a,c.id,c.version
    returning id into t;
  end if;

  row:=jsonb_build_object(
    'template_id',t,
    'personal_course_id',c.id,
    'published',true,
    'personal_saved',true,
    'status','published'
  );
  perform private.phase16_student_record(a,p_operation_id,
    'publish_course_template',h,row);
  return row;
end; $$;

revoke all on function public.publish_course_template(uuid,uuid)
  from public,anon,service_role;
grant execute on function public.publish_course_template(uuid,uuid)
  to authenticated;

-- The 175000 repair corrected shared term identity but left historical term
-- counters stale.  Recompute from distinct copy events over the complete
-- canonical lineage.  No user_courses row is touched by this repair.
update public.course_templates ct
   set term_id=personal_term.source_template_id,
       updated_at=now()
  from public.user_courses personal_course
  join public.terms personal_term on personal_term.id=personal_course.term_id
  join public.terms catalog_term on catalog_term.id=personal_term.source_template_id
 where ct.published_from_course_id=personal_course.id
   and personal_term.source_template_id is not null
   and personal_term.is_template=false
   and personal_term.status='active'
   and personal_term.deleted_at is null
   and catalog_term.university_id=ct.university_id
   and catalog_term.is_template
   and catalog_term.status='active'
   and catalog_term.deleted_at is null
   and ct.term_id is distinct from personal_term.source_template_id;

create or replace function private.phase16_recompute_template_copy_counts()
returns void language plpgsql security definer
set search_path=pg_catalog,public,private as $$
begin
  with canonical_templates as (
    select ct.id,ct.term_id
      from public.course_templates ct
     where private.phase16_canonical_template(ct.id)=ct.id
  ), counts as (
    select c.id,
           count(distinct e.user_course_id)::integer as total_count,
           count(distinct e.user_course_id) filter (
             where target_term.id=c.term_id
                or target_term.source_template_id=c.term_id
           )::integer as term_count
      from canonical_templates c
      left join public.course_template_copy_events e
        on e.user_course_id is not null
       and private.phase16_canonical_template(e.template_id)=c.id
      left join public.user_courses copied_course on copied_course.id=e.user_course_id
      left join public.terms target_term on target_term.id=copied_course.term_id
     group by c.id,c.term_id
  )
  update public.course_templates ct
     set copy_count_total=counts.total_count,
         copy_count_term=counts.term_count,
         updated_at=now()
    from counts
   where ct.id=counts.id
     and (ct.copy_count_total is distinct from counts.total_count
          or ct.copy_count_term is distinct from counts.term_count);
end; $$;
revoke all on function private.phase16_recompute_template_copy_counts()
  from public,anon,authenticated,service_role;

select private.phase16_recompute_template_copy_counts();

commit;
