-- Phase 16 final publication repair: catalog templates must use the shared
-- catalog term identity, not the publisher's personal term row.
begin;

create or replace function public.publish_course_template(p_user_course_id uuid,p_operation_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); h text; r jsonb; c record; p record; source_term record; source_term_id uuid; has_catalog_source boolean; t uuid; row jsonb;
begin
  if a is null then raise exception 'authentication required' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('course_id',p_user_course_id)::text,'sha256'),'hex');
  r:=private.phase16_student_lock(a,p_operation_id,'publish_course_template',h);
  if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  select uc.* into c from public.user_courses uc where uc.id=p_user_course_id and uc.owner_user_id=a and uc.deleted_at is null for update;
  if not found then raise exception 'owned course is required' using errcode='42501'; end if;
  select prof.* into p from public.profiles prof where prof.user_id=a and prof.deleted_at is null;
  if not found or p.university_id is null then raise exception 'university membership is required' using errcode='42501'; end if;
  select x.* into source_term from public.terms x where x.id=c.term_id and x.university_id=p.university_id and x.owner_user_id=a and not x.is_template and x.status='active' and x.deleted_at is null;
  if not found then raise exception 'course term is not available' using errcode='42501'; end if;
  has_catalog_source:=source_term.source_template_id is not null;
  source_term_id:=coalesce(source_term.source_template_id,source_term.id);
  select x.* into source_term from public.terms x where x.id=source_term_id and x.university_id=p.university_id and x.is_template=has_catalog_source and x.status='active' and x.deleted_at is null;
  if not found then raise exception 'catalog source term is not available' using errcode='42501'; end if;
  select id into t from public.course_templates where published_from_course_id=c.id and status<>'deleted' order by created_at limit 1;
  if t is null then
    insert into public.course_templates(university_id,academic_year,term_id,title,normalized_title,instructor_name,normalized_instructor_name,day_of_week,period_no,room,normalized_room,credit_count,syllabus_url,created_by,published_from_course_id,source_template_version)
    select x.university_id,x.academic_year,x.id,c.title,public.normalize_course_text(c.title),c.instructor_name,public.normalize_course_text(c.instructor_name),c.day_of_week,c.period_no,c.room,public.normalize_course_text(c.room),c.credit_count,c.syllabus_url,a,c.id,c.version
    from public.terms x where x.id=source_term_id returning id into t;
  else
    update public.course_templates set term_id=source_term_id,updated_at=now() where id=t and term_id is distinct from source_term_id;
  end if;
  row:=jsonb_build_object('template_id',t,'personal_course_id',c.id,'published',true,'personal_saved',true,'status','published');
  perform private.phase16_student_record(a,p_operation_id,'publish_course_template',h,row);
  return row;
end; $$;

revoke all on function public.publish_course_template(uuid,uuid) from public,anon;
grant execute on function public.publish_course_template(uuid,uuid) to authenticated;

-- Repair only published catalog rows whose originating personal term has a
-- valid shared source. Personal user_courses remain untouched.
update public.course_templates ct
set term_id=personal_term.source_template_id,updated_at=now()
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

commit;
