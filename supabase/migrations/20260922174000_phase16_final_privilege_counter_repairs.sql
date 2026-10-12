-- Phase 16 final convergence: close the remaining public overload/table
-- privileges and preserve historical catalog counters when a new copy event
-- is recorded.
begin;

revoke all on function public.submit_university_request(text,text,text,uuid) from public,anon,service_role;
grant execute on function public.submit_university_request(text,text,text,uuid) to authenticated;
revoke all on function public.review_course_template_update(uuid,text,bigint,bigint,uuid) from public,anon,service_role;
grant execute on function public.review_course_template_update(uuid,text,bigint,bigint,uuid) to authenticated;
revoke all on table public.course_template_edit_proposals,public.course_template_reports from public,anon,authenticated;

create or replace function public.copy_course_template(template_id uuid,target_term_id uuid)
returns uuid language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); source_template public.course_templates%rowtype; canonical_id uuid; new_course_id uuid; same_catalog_term boolean;
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
  select exists(select 1 from public.terms personal_term where personal_term.id=target_term_id and personal_term.source_template_id=source_template.term_id) into same_catalog_term;
  update public.course_templates
  set copy_count_total=coalesce(copy_count_total,0)+1,
      copy_count_term=coalesce(copy_count_term,0)+case when same_catalog_term then 1 else 0 end
  where id=source_template.id;
  return new_course_id;
end; $$;

revoke all on function public.copy_course_template(uuid,uuid) from public,anon;
grant execute on function public.copy_course_template(uuid,uuid) to authenticated;

commit;
