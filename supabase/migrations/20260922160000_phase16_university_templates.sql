-- Phase 16: university request decisions and authenticated course-template
-- contribution/moderation.  Append-only; applied migrations remain immutable.
begin;

-- The existing rows remain the source of truth.  These columns add lifecycle
-- evidence and a private snapshot for explicit copied-template updates.
alter table public.university_requests
  add column if not exists operation_id uuid,
  add column if not exists decision_reason text,
  add column if not exists merged_into_university_id uuid references public.universities(id),
  add column if not exists approved_university_id uuid references public.universities(id);
create unique index if not exists university_requests_operation_idx
  on public.university_requests(requested_by, operation_id)
  where operation_id is not null;

alter table public.course_templates
  add column if not exists published_from_course_id uuid references public.user_courses(id),
  add column if not exists source_template_version bigint,
  add column if not exists moderation_hidden_at timestamptz,
  add column if not exists moderation_hidden_by uuid references auth.users(id),
  add column if not exists moderation_reason text,
  add column if not exists merged_at timestamptz,
  add column if not exists merged_by uuid references auth.users(id);

alter table public.course_template_edit_proposals
  add column if not exists expected_template_version bigint,
  add column if not exists version bigint not null default 1,
  add column if not exists decision_reason text,
  add column if not exists operation_id uuid,
  add column if not exists updated_at timestamptz not null default now();
alter table public.course_template_reports
  add column if not exists reviewed_by uuid references auth.users(id),
  add column if not exists reviewed_at timestamptz,
  add column if not exists decision_reason text,
  add column if not exists operation_id uuid,
  add column if not exists version bigint not null default 1,
  add column if not exists updated_at timestamptz not null default now();
alter table public.course_template_duplicate_candidates
  add column if not exists reviewed_by uuid references auth.users(id),
  add column if not exists reviewed_at timestamptz,
  add column if not exists decision_reason text,
  add column if not exists merged_template_id uuid references public.course_templates(id),
  add column if not exists operation_id uuid,
  add column if not exists version bigint not null default 1;

alter table public.user_courses
  add column if not exists source_template_version bigint,
  add column if not exists source_template_snapshot jsonb,
  add column if not exists template_update_state text not null default 'none';
do $$ begin
  alter table public.user_courses add constraint user_courses_template_update_state_check
    check (template_update_state in ('none','available','applied','ignored'));
exception when duplicate_object then null; end $$;

create table if not exists private.phase16_student_operation_receipts(
  actor_user_id uuid not null references auth.users(id) on delete cascade,
  operation_id uuid not null,
  operation_name text not null,
  request_hash text not null,
  response jsonb not null,
  created_at timestamptz not null default now(),
  primary key(actor_user_id, operation_id)
);
revoke all on private.phase16_student_operation_receipts from public,anon,authenticated,service_role;

create or replace function private.phase16_student_lock(a uuid,o uuid,n text,h text)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare r jsonb; old_hash text; old_name text;
begin
  if a is null or o is null then raise exception 'operation id is required' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('phase16-op:'||a::text||':'||o::text,9016));
  select response,request_hash,operation_name into r,old_hash,old_name
    from private.phase16_student_operation_receipts
    where actor_user_id=a and operation_id=o for update;
  if r is not null and (old_hash<>h or old_name<>n) then
    raise exception 'operation replay mismatch' using errcode='PT409';
  end if;
  return r;
end; $$;

create or replace function private.phase16_student_record(a uuid,o uuid,n text,h text,r jsonb)
returns void language sql security definer
set search_path=pg_catalog,public,private as $$
  insert into private.phase16_student_operation_receipts(actor_user_id,operation_id,operation_name,request_hash,response)
  values(a,o,n,h,r) on conflict(actor_user_id,operation_id) do nothing;
$$;

-- Operation-ID aware request submission.  The original three-argument RPC is
-- retained for old clients; this overload is used by the Phase 16 UI.
create or replace function public.submit_university_request(
  p_name text,p_prefecture text,p_official_url text,p_operation_id uuid
)
returns uuid language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); clean_name text:=btrim(coalesce(p_name,'')); clean_pref text:=nullif(btrim(p_prefecture),''); clean_url text:=nullif(btrim(p_official_url),''); n text; h text; r jsonb; request_id uuid;
begin
  if a is null then raise exception 'authentication required' using errcode='42501'; end if;
  if char_length(clean_name) not between 2 and 120 then raise exception 'invalid university name' using errcode='22023'; end if;
  if clean_pref is not null and char_length(clean_pref)>50 then raise exception 'invalid prefecture' using errcode='22023'; end if;
  if clean_url is not null and (char_length(clean_url)>2048 or clean_url !~ '^https://') then raise exception 'official_url must be an HTTPS URL' using errcode='22023'; end if;
  n:=public.normalize_course_text(clean_name);
  h:=encode(extensions.digest(jsonb_build_object('name',clean_name,'prefecture',clean_pref,'official_url',clean_url)::text,'sha256'),'hex');
  r:=private.phase16_student_lock(a,p_operation_id,'submit_university_request',h);
  if r is not null then return (r->>'request_id')::uuid; end if;
  select id into request_id from public.university_requests where requested_by=a and operation_id=p_operation_id;
  if request_id is null then
    insert into public.university_requests(requested_by,name,normalized_name,prefecture,official_url,operation_id)
    values(a,clean_name,n,clean_pref,clean_url,p_operation_id) returning id into request_id;
  end if;
  r:=jsonb_build_object('request_id',request_id);
  perform private.phase16_student_record(a,p_operation_id,'submit_university_request',h,r);
  return request_id;
end; $$;

-- Canonical resolution is bounded and rejects cycles defensively.
create or replace function private.phase16_canonical_template(p_template_id uuid)
returns uuid language plpgsql stable security definer
set search_path=pg_catalog,public,private as $$
declare current_id uuid:=p_template_id; next_id uuid; hops int:=0;
begin
  if current_id is null then return null; end if;
  loop
    select canonical_template_id into next_id from public.course_templates where id=current_id;
    exit when next_id is null;
    hops:=hops+1; if hops>20 or next_id=current_id then return null; end if;
    current_id:=next_id;
  end loop;
  return current_id;
end; $$;

-- Student publication is deliberately separate from personal course storage.
create or replace function public.publish_course_template(p_user_course_id uuid,p_operation_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); h text; r jsonb; c record; p record; t uuid; row jsonb;
begin
  select uc.* into c from public.user_courses uc where uc.id=p_user_course_id and uc.owner_user_id=a and uc.deleted_at is null for update;
  if not found then raise exception 'owned course is required' using errcode='42501'; end if;
  select prof.* into p from public.profiles prof where prof.user_id=a and prof.deleted_at is null;
  if not found or p.university_id is null then raise exception 'university membership is required' using errcode='42501'; end if;
  if not exists(select 1 from public.terms x where x.id=c.term_id and x.university_id=p.university_id and x.deleted_at is null) then raise exception 'course term is not available' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('course_id',p_user_course_id,'title',c.title,'instructor_name',c.instructor_name,'day_of_week',c.day_of_week,'period_no',c.period_no,'room',c.room,'credit_count',c.credit_count,'syllabus_url',c.syllabus_url)::text,'sha256'),'hex');
  r:=private.phase16_student_lock(a,p_operation_id,'publish_course_template',h);
  if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  select id into t from public.course_templates where published_from_course_id=c.id and status<>'deleted' order by created_at limit 1;
  if t is null then
    insert into public.course_templates(university_id,academic_year,term_id,title,normalized_title,instructor_name,normalized_instructor_name,day_of_week,period_no,room,normalized_room,credit_count,syllabus_url,created_by,published_from_course_id,source_template_version)
    select x.university_id,x.academic_year,x.id,c.title,public.normalize_course_text(c.title),c.instructor_name,public.normalize_course_text(c.instructor_name),c.day_of_week,c.period_no,c.room,public.normalize_course_text(c.room),c.credit_count,c.syllabus_url,a,c.id,c.version
    from public.terms x where x.id=c.term_id returning id into t;
  end if;
  row:=jsonb_build_object('template_id',t,'personal_course_id',c.id,'published',true,'personal_saved',true);
  perform private.phase16_student_record(a,p_operation_id,'publish_course_template',h,row);
  return row;
end; $$;

-- Allow-list is kept in SQL, never trusted from a client-generated arbitrary
-- JSON object.  Only the public catalog fields are accepted.
create or replace function public.submit_course_template_edit_proposal(p_template_id uuid,p_proposed_payload jsonb,p_expected_version bigint,p_operation_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); h text; r jsonb; c record; p record; payload jsonb; proposal_id uuid;
begin
  payload:=coalesce(p_proposed_payload,'{}'::jsonb) - array['id','university_id','created_by','created_at','updated_at','version','status','canonical_template_id','copy_count_total','copy_count_term','report_count','trust_score','personal_memo','meeting_url','assignments','notifications','visibility'];
  if jsonb_typeof(payload)<>'object' or payload='{}'::jsonb then raise exception 'public template fields are required' using errcode='22023'; end if;
  select ct.* into c from public.course_templates ct join public.profiles p0 on p0.university_id=ct.university_id and p0.user_id=a where ct.id=private.phase16_canonical_template(p_template_id) and ct.status='active' and ct.deleted_at is null for update;
  if not found then raise exception 'course template is unavailable' using errcode='42501'; end if;
  if p_expected_version is null or c.version<>p_expected_version then raise exception 'course template version conflict' using errcode='PT409'; end if;
  h:=encode(extensions.digest(jsonb_build_object('template_id',p_template_id,'payload',payload,'expected_version',p_expected_version)::text,'sha256'),'hex');
  r:=private.phase16_student_lock(a,p_operation_id,'submit_course_template_edit_proposal',h);
  if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  insert into public.course_template_edit_proposals(template_id,proposed_by,proposed_payload,expected_template_version,operation_id)
  values(c.id,a,payload,c.version,p_operation_id) returning id into proposal_id;
  r:=jsonb_build_object('proposal_id',proposal_id,'template_id',c.id,'status','pending','expected_version',c.version);
  perform private.phase16_student_record(a,p_operation_id,'submit_course_template_edit_proposal',h,r); return r;
end; $$;

create or replace function public.report_course_template(p_template_id uuid,p_reason text,p_operation_id uuid)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); h text; r jsonb; c record; report_id uuid;
begin
  select ct.* into c from public.course_templates ct join public.profiles p on p.university_id=ct.university_id and p.user_id=a where ct.id=private.phase16_canonical_template(p_template_id) and ct.status='active' and ct.deleted_at is null;
  if not found then raise exception 'course template is unavailable' using errcode='42501'; end if;
  if length(trim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'report reason is invalid' using errcode='22023'; end if;
  h:=encode(extensions.digest(jsonb_build_object('template_id',p_template_id,'reason',trim(p_reason))::text,'sha256'),'hex');
  r:=private.phase16_student_lock(a,p_operation_id,'report_course_template',h); if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  select id into report_id from public.course_template_reports where template_id=c.id and reported_by=a and status='pending' order by created_at limit 1;
  if report_id is null then insert into public.course_template_reports(template_id,reported_by,reason,operation_id) values(c.id,a,trim(p_reason),p_operation_id) returning id into report_id; end if;
  update public.course_templates set report_count=report_count+1 where id=c.id;
  r:=jsonb_build_object('report_id',report_id,'template_id',c.id,'status','pending'); perform private.phase16_student_record(a,p_operation_id,'report_course_template',h,r); return r;
end; $$;

create or replace function public.get_course_template_for_user(p_template_id uuid)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); t record;
begin
  select ct.* into t from public.course_templates ct join public.profiles p on p.user_id=a and p.university_id=ct.university_id where ct.id=private.phase16_canonical_template(p_template_id) and ct.status='active' and ct.deleted_at is null;
  if not found then raise exception 'course template is unavailable' using errcode='42501'; end if;
  return jsonb_build_object('id',t.id,'university_id',t.university_id,'academic_year',t.academic_year,'term_id',t.term_id,'title',t.title,'instructor_name',t.instructor_name,'day_of_week',t.day_of_week,'period_no',t.period_no,'room',t.room,'credit_count',t.credit_count,'syllabus_url',t.syllabus_url,'external_course_code',t.external_course_code,'version',t.version);
end; $$;

-- Replace the old search projection with canonical, active targets while
-- retaining the exact public redacted signature.
drop function if exists public.search_course_templates(text,uuid,integer,uuid,integer,integer,integer,text);
create function public.search_course_templates(query_text text,target_university_id uuid,target_academic_year integer,target_term_id uuid default null,target_day_of_week integer default null,target_period_no integer default null,limit_count integer default 20,target_instructor_name text default null)
returns table(id uuid,university_id uuid,academic_year integer,term_id uuid,title text,normalized_title text,instructor_name text,normalized_instructor_name text,day_of_week integer,period_no integer,room text,normalized_room text,credit_count numeric,syllabus_url text,external_course_code text,copy_count_total integer,copy_count_term integer,trust_score numeric,duplicate_key text,rank_score numeric)
language sql security definer set search_path=pg_catalog,public stable as $$
with caller as (select p.university_id,requested_term.id requested_term_id,requested_term.source_template_id requested_term_template_id from public.profiles p left join public.terms requested_term on target_term_id is not null and requested_term.id=target_term_id and requested_term.owner_user_id=p.user_id and requested_term.university_id=p.university_id and not requested_term.is_template and requested_term.status='active' and requested_term.deleted_at is null where p.user_id=auth.uid() and p.deleted_at is null and (target_term_id is null or requested_term.id is not null)), canonical as (select distinct on (root.id) root.* from public.course_templates source join public.course_templates root on root.id=private.phase16_canonical_template(source.id) where source.university_id=target_university_id and source.academic_year=target_academic_year), normalized as (select public.normalize_course_text(query_text) query_key,public.normalize_course_text(target_instructor_name) instructor_key), bounded as (select least(greatest(coalesce(limit_count,20),1),50) row_limit), ranked as (
  select ct.id,ct.university_id,ct.academic_year,ct.term_id,ct.title,ct.normalized_title,ct.instructor_name,ct.normalized_instructor_name,ct.day_of_week,ct.period_no,ct.room,ct.normalized_room,ct.credit_count,ct.syllabus_url,ct.external_course_code,ct.copy_count_total,ct.copy_count_term,ct.trust_score,concat_ws(':',ct.normalized_title,ct.normalized_instructor_name,ct.day_of_week,ct.period_no) as duplicate_key,((case when n.query_key='' then 0 when ct.normalized_title=n.query_key then 1000 when ct.normalized_title like '%'||n.query_key||'%' then 750 when coalesce(ct.normalized_instructor_name,'') like '%'||n.query_key||'%' then 500 else 0 end)+case when n.instructor_key='' then 0 when ct.normalized_instructor_name=n.instructor_key then 300 else 150 end+ln(1+greatest(ct.copy_count_term,0))*5+ln(1+greatest(ct.copy_count_total,0))*2+ct.trust_score-ct.report_count*5+case when target_day_of_week is not null and ct.day_of_week=target_day_of_week then 50 else 0 end+case when target_period_no is not null and ct.period_no=target_period_no then 50 else 0 end)::numeric as rank_score
  from canonical ct cross join caller c cross join normalized n where ct.university_id=c.university_id and ct.status='active' and ct.deleted_at is null and (target_term_id is null or ct.term_id is null or ct.term_id=c.requested_term_id or ct.term_id=c.requested_term_template_id) and (target_day_of_week is null or ct.day_of_week=target_day_of_week) and (target_period_no is null or ct.period_no=target_period_no) and (n.query_key='' or ct.normalized_title like '%'||n.query_key||'%' or coalesce(ct.normalized_instructor_name,'') like '%'||n.query_key||'%') and (n.instructor_key='' or coalesce(ct.normalized_instructor_name,'') like '%'||n.instructor_key||'%')
)
select ranked.id,ranked.university_id,ranked.academic_year,ranked.term_id,ranked.title,ranked.normalized_title,ranked.instructor_name,ranked.normalized_instructor_name,ranked.day_of_week,ranked.period_no,ranked.room,ranked.normalized_room,ranked.credit_count,ranked.syllabus_url,ranked.external_course_code,ranked.copy_count_total,ranked.copy_count_term,ranked.trust_score,ranked.duplicate_key,ranked.rank_score
from ranked order by ranked.rank_score desc,ranked.copy_count_term desc,ranked.copy_count_total desc,ranked.id limit (select row_limit from bounded);
$$;

revoke all on function public.search_course_templates(text,uuid,integer,uuid,integer,integer,integer,text) from public,anon;
grant execute on function public.search_course_templates(text,uuid,integer,uuid,integer,integer,integer,text) to authenticated;

-- The copy writer now stores a source snapshot and resolves merged canonical
-- targets.  Personal rows are never updated by later template changes.
create or replace function public.copy_course_template(template_id uuid,target_term_id uuid)
returns uuid language plpgsql security definer set search_path=pg_catalog,public as $$
declare a uuid:=auth.uid(); source_template public.course_templates%rowtype; canonical_id uuid; new_course_id uuid;
begin
  if a is null then raise exception 'authentication required' using errcode='42501'; end if;
  canonical_id:=private.phase16_canonical_template(template_id);
  select ct.* into source_template from public.course_templates ct join public.profiles p on p.user_id=a and p.university_id=ct.university_id where ct.id=canonical_id and ct.status='active' and ct.deleted_at is null;
  if not found then raise exception 'course template is not available for this university' using errcode='42501'; end if;
  if not exists(select 1 from public.terms t where t.id=target_term_id and t.owner_user_id=a and t.university_id=source_template.university_id and not t.is_template and t.status='active' and t.deleted_at is null) then raise exception 'owned active target term is required' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('copy-course:'||a::text||':'||source_template.id::text||':'||target_term_id::text,0));
  select id into new_course_id from public.user_courses where owner_user_id=a and term_id=target_term_id and source_template_id=source_template.id and deleted_at is null order by created_at,id limit 1;
  if found then return new_course_id; end if;
  insert into public.user_courses(owner_user_id,term_id,source_template_id,title,normalized_title,instructor_name,normalized_instructor_name,day_of_week,period_no,room,normalized_room,credit_count,syllabus_url,visibility_level,source_template_version,source_template_snapshot,template_update_state)
  values(a,target_term_id,source_template.id,source_template.title,source_template.normalized_title,source_template.instructor_name,source_template.normalized_instructor_name,source_template.day_of_week,source_template.period_no,source_template.room,source_template.normalized_room,source_template.credit_count,source_template.syllabus_url,'PRIVATE',source_template.version,jsonb_build_object('title',source_template.title,'instructor_name',source_template.instructor_name,'day_of_week',source_template.day_of_week,'period_no',source_template.period_no,'room',source_template.room,'credit_count',source_template.credit_count,'syllabus_url',source_template.syllabus_url,'external_course_code',source_template.external_course_code),'none') returning id into new_course_id;
  insert into public.course_template_copy_events(template_id,copied_by,user_course_id) values(source_template.id,a,new_course_id);
  update public.course_templates set copy_count_total=(select count(*) from public.course_template_copy_events where template_id=source_template.id),copy_count_term=(select count(*) from public.course_template_copy_events e join public.user_courses c on c.id=e.user_course_id where e.template_id=source_template.id and c.term_id=target_term_id) where id=source_template.id;
  return new_course_id;
end; $$;
revoke all on function public.copy_course_template(uuid,uuid) from public,anon;
grant execute on function public.copy_course_template(uuid,uuid) to authenticated;

create or replace function public.get_course_template_update(p_user_course_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); c record; t record; current jsonb; old jsonb; changed jsonb;
begin
  select * into c from public.user_courses where id=p_user_course_id and owner_user_id=a and deleted_at is null;
  if not found or c.source_template_id is null then return jsonb_build_object('available',false,'reason','not_template_copy'); end if;
  select * into t from public.course_templates where id=private.phase16_canonical_template(c.source_template_id) and status='active' and deleted_at is null;
  if not found or c.source_template_snapshot is null or t.version<=coalesce(c.source_template_version,0) then return jsonb_build_object('available',false,'state',coalesce(c.template_update_state,'none')); end if;
  old:=c.source_template_snapshot; current:=jsonb_build_object('title',t.title,'instructor_name',t.instructor_name,'day_of_week',t.day_of_week,'period_no',t.period_no,'room',t.room,'credit_count',t.credit_count,'syllabus_url',t.syllabus_url,'external_course_code',t.external_course_code);
  select coalesce(jsonb_object_agg(k,value),'{}'::jsonb) into changed from jsonb_each(current) e(k,value) where old->k is distinct from value;
  update public.user_courses set template_update_state='available' where id=c.id and template_update_state='none';
  return jsonb_build_object('available',true,'state','available','course_id',c.id,'source_template_id',t.id,'source_version',coalesce(c.source_template_version,0),'template_version',t.version,'before',old,'after',current,'changed',coalesce(changed,'{}'::jsonb));
end; $$;

create or replace function public.review_course_template_update(p_user_course_id uuid,p_action text,p_expected_template_version bigint default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); c record; t record; snapshot jsonb; next_state text;
begin
  if p_action not in('apply','ignore') then raise exception 'invalid template update action' using errcode='22023'; end if;
  select * into c from public.user_courses where id=p_user_course_id and owner_user_id=a and deleted_at is null for update;
  if not found or c.source_template_id is null then raise exception 'owned template copy is required' using errcode='42501'; end if;
  select * into t from public.course_templates where id=private.phase16_canonical_template(c.source_template_id) and status='active' and deleted_at is null for update;
  if not found then raise exception 'course template is unavailable' using errcode='42501'; end if;
  if p_expected_template_version is not null and t.version<>p_expected_template_version then raise exception 'course template version conflict' using errcode='PT409'; end if;
  if p_action='ignore' then update public.user_courses set source_template_version=t.version,source_template_snapshot=jsonb_build_object('title',t.title,'instructor_name',t.instructor_name,'day_of_week',t.day_of_week,'period_no',t.period_no,'room',t.room,'credit_count',t.credit_count,'syllabus_url',t.syllabus_url,'external_course_code',t.external_course_code),template_update_state='ignored' where id=c.id; return jsonb_build_object('course_id',c.id,'action','ignore','template_version',t.version); end if;
  update public.user_courses set title=t.title,normalized_title=t.normalized_title,instructor_name=t.instructor_name,normalized_instructor_name=t.normalized_instructor_name,day_of_week=t.day_of_week,period_no=t.period_no,room=t.room,normalized_room=t.normalized_room,credit_count=t.credit_count,syllabus_url=t.syllabus_url,source_template_version=t.version,source_template_snapshot=jsonb_build_object('title',t.title,'instructor_name',t.instructor_name,'day_of_week',t.day_of_week,'period_no',t.period_no,'room',t.room,'credit_count',t.credit_count,'syllabus_url',t.syllabus_url,'external_course_code',t.external_course_code),template_update_state='applied' where id=c.id;
  return jsonb_build_object('course_id',c.id,'action','apply','template_version',t.version);
end; $$;

-- Protected administration: every decision is caller-bound, version-checked,
-- atomic, receipt-backed, and audit-recorded.
create or replace function public.admin_list_university_requests(p_limit int default 50,p_offset int default 0)
returns table(request_id uuid,name text,prefecture text,official_url text,status text,created_at timestamptz,version bigint,decision_reason text,merged_into_university_id uuid,approved_university_id uuid)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$ begin perform private.require_global_admin(); return query select r.id,r.name,r.prefecture,r.official_url,r.status,r.created_at,r.version,r.decision_reason,r.merged_into_university_id,r.approved_university_id from public.university_requests r order by r.created_at,r.id limit least(greatest(p_limit,1),100) offset greatest(p_offset,0); end; $$;

create or replace function public.admin_resolve_university_request(p_request_id uuid,p_action text,p_target_university_id uuid,p_reason text,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=private.require_global_admin(); h text; r jsonb; q record; target uuid; created boolean:=false; next_status text;
begin
  if p_action not in('approve','reject','merge') or length(trim(coalesce(p_reason,'')))<1 or length(p_reason)>1000 then raise exception 'invalid university decision' using errcode='22023'; end if;
  h:=encode(extensions.digest(jsonb_build_object('request_id',p_request_id,'action',p_action,'target',p_target_university_id,'reason',trim(p_reason))::text,'sha256'),'hex'); r:=private.admin_lock(a,p_operation_id,'admin_resolve_university_request',h); if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  select * into q from public.university_requests where id=p_request_id for update; if not found then raise exception 'university request unavailable' using errcode='42501'; end if;
  if q.status<>'pending' then raise exception 'university request already resolved' using errcode='PT409'; end if;
  if p_action='merge' then select id into target from public.universities where id=p_target_university_id and status='active' and deleted_at is null; if target is null then raise exception 'active target university required' using errcode='22023'; end if; next_status:='merged';
  elsif p_action='approve' then select id into target from public.universities where normalized_name=q.normalized_name and status='active' and deleted_at is null limit 1; if target is null then insert into public.universities(name,normalized_name,prefecture) values(q.name,q.normalized_name,q.prefecture) returning id into target; created:=true; end if; next_status:='approved';
  else next_status:='rejected'; end if;
  update public.university_requests set status=next_status,resolved_by=a,resolved_at=now(),decision_reason=trim(p_reason),merged_into_university_id=case when p_action='merge' then target else null end,approved_university_id=case when p_action='approve' then target else null end,version=version+1,updated_at=now() where id=q.id;
  r:=jsonb_build_object('request_id',q.id,'status',next_status,'university_id',target,'created',created,'decision_reason',trim(p_reason)); insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata) values(a,'university_'||p_action,'university_request',q.id,r); perform private.admin_record(a,p_operation_id,'admin_resolve_university_request',h,r); return r;
end; $$;

create or replace function public.admin_list_universities(p_limit int default 100,p_offset int default 0)
returns table(university_id uuid,name text,normalized_name text,aliases text[],prefecture text,status text,version bigint,created_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$ begin perform private.require_global_admin(); return query select u.id,u.name,u.normalized_name,u.aliases,u.prefecture,u.status,u.version,u.created_at from public.universities u where u.deleted_at is null order by u.name,u.id limit least(greatest(p_limit,1),200) offset greatest(p_offset,0); end; $$;

create or replace function public.admin_update_university(p_university_id uuid,p_name text,p_aliases text[],p_prefecture text,p_status text,p_expected_version bigint,p_reason text,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=private.require_global_admin(); h text; r jsonb; u record; clean_name text:=btrim(coalesce(p_name,'')); clean_aliases text[]:=coalesce(p_aliases,'{}');
begin
  if char_length(clean_name) not between 2 and 160 or p_status not in('active','hidden','merged') or length(trim(coalesce(p_reason,'')))<1 then raise exception 'invalid university master update' using errcode='22023'; end if;
  h:=encode(extensions.digest(jsonb_build_object('university_id',p_university_id,'name',clean_name,'aliases',clean_aliases,'prefecture',p_prefecture,'status',p_status,'expected_version',p_expected_version,'reason',trim(p_reason))::text,'sha256'),'hex'); r:=private.admin_lock(a,p_operation_id,'admin_update_university',h); if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  select * into u from public.universities where id=p_university_id and deleted_at is null for update; if not found then raise exception 'university unavailable' using errcode='42501'; end if;
  if p_expected_version is null or u.version<>p_expected_version then raise exception 'university version conflict' using errcode='PT409'; end if;
  update public.universities set name=clean_name,normalized_name=public.normalize_course_text(clean_name),aliases=clean_aliases,prefecture=nullif(btrim(p_prefecture),''),status=p_status,updated_at=now() where id=u.id;
  r:=jsonb_build_object('university_id',u.id,'status',p_status,'version',u.version+1); insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata) values(a,'university_master_update','university',u.id,jsonb_build_object('reason',trim(p_reason),'previous_version',u.version,'new_version',u.version+1)); perform private.admin_record(a,p_operation_id,'admin_update_university',h,r); return r;
end; $$;

create or replace function public.admin_list_course_template_proposals(p_limit int default 50,p_offset int default 0)
returns table(proposal_id uuid,template_id uuid,proposed_by uuid,proposed_payload jsonb,status text,expected_template_version bigint,version bigint,created_at timestamptz,decision_reason text)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$ begin perform private.require_global_admin(); return query select p.id,p.template_id,p.proposed_by,p.proposed_payload,p.status,p.expected_template_version,p.version,p.created_at,p.decision_reason from public.course_template_edit_proposals p where p.status='pending' order by p.created_at,p.id limit least(greatest(p_limit,1),100) offset greatest(p_offset,0); end; $$;

create or replace function public.admin_list_course_template_reports(p_limit int default 50,p_offset int default 0)
returns table(report_id uuid,template_id uuid,reason text,status text,reported_by uuid,created_at timestamptz,version bigint,decision_reason text)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$ begin perform private.require_global_admin(); return query select r.id,r.template_id,r.reason,r.status,r.reported_by,r.created_at,r.version,r.decision_reason from public.course_template_reports r where r.status='pending' order by r.created_at,r.id limit least(greatest(p_limit,1),100) offset greatest(p_offset,0); end; $$;

create or replace function public.admin_list_course_template_duplicates(p_limit int default 50,p_offset int default 0)
returns table(candidate_id uuid,university_id uuid,template_a_id uuid,template_b_id uuid,score numeric,status text,version bigint,created_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$ begin perform private.require_global_admin(); return query select d.id,d.university_id,d.template_a_id,d.template_b_id,d.score,d.status,d.version,d.created_at from public.course_template_duplicate_candidates d where d.status='pending' order by d.score desc,d.created_at,d.id limit least(greatest(p_limit,1),100) offset greatest(p_offset,0); end; $$;

create or replace function public.admin_resolve_course_template_proposal(p_proposal_id uuid,p_action text,p_reason text,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=private.require_global_admin(); h text; r jsonb; p record; t record; payload jsonb; aid uuid;
begin
  if p_action not in('approve','reject') or length(trim(coalesce(p_reason,'')))<1 then raise exception 'invalid proposal decision' using errcode='22023'; end if;
  select x.* into p from public.course_template_edit_proposals x where x.id=p_proposal_id for update; if not found then raise exception 'proposal unavailable' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('proposal_id',p_proposal_id,'action',p_action,'reason',trim(p_reason))::text,'sha256'),'hex'); r:=private.admin_lock(a,p_operation_id,'admin_resolve_course_template_proposal',h); if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  if p.status<>'pending' then raise exception 'proposal already resolved' using errcode='PT409'; end if;
  select * into t from public.course_templates where id=p.template_id for update; if not found or t.status<>'active' then raise exception 'template unavailable' using errcode='42501'; end if;
  if p_action='approve' then if p.expected_template_version is distinct from t.version then raise exception 'template version conflict' using errcode='PT409'; end if; payload:=p.proposed_payload; update public.course_templates set title=coalesce(nullif(btrim(payload->>'title'),''),title),normalized_title=case when payload ? 'title' then public.normalize_course_text(payload->>'title') else normalized_title end,instructor_name=case when payload ? 'instructor_name' then nullif(btrim(payload->>'instructor_name'),'') else instructor_name end,normalized_instructor_name=case when payload ? 'instructor_name' then public.normalize_course_text(payload->>'instructor_name') else normalized_instructor_name end,day_of_week=case when payload ? 'day_of_week' then (payload->>'day_of_week')::int else day_of_week end,period_no=case when payload ? 'period_no' then (payload->>'period_no')::int else period_no end,room=case when payload ? 'room' then nullif(btrim(payload->>'room'),'') else room end,normalized_room=case when payload ? 'room' then public.normalize_course_text(payload->>'room') else normalized_room end,credit_count=case when payload ? 'credit_count' then (payload->>'credit_count')::numeric else credit_count end,syllabus_url=case when payload ? 'syllabus_url' then nullif(btrim(payload->>'syllabus_url'),'') else syllabus_url end,external_course_code=case when payload ? 'external_course_code' then nullif(btrim(payload->>'external_course_code'),'') else external_course_code end,updated_at=now() where id=t.id; end if;
  update public.course_template_edit_proposals set status=case when p_action='approve' then 'approved' else 'rejected' end,reviewed_by=a,reviewed_at=now(),decision_reason=trim(p_reason),version=version+1,updated_at=now() where id=p.id;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata) values(a,'course_template_proposal_'||p_action,'course_template',t.id,jsonb_build_object('proposal_id',p.id,'reason',trim(p_reason),'template_version',t.version)) returning id into aid;
  r:=jsonb_build_object('proposal_id',p.id,'template_id',t.id,'status',case when p_action='approve' then 'approved' else 'rejected' end,'audit_id',aid); perform private.admin_record(a,p_operation_id,'admin_resolve_course_template_proposal',h,r); return r;
end; $$;

create or replace function public.admin_resolve_course_template_report(p_report_id uuid,p_action text,p_reason text,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=private.require_global_admin(); h text; r jsonb; q record; t record; state text; aid uuid;
begin
  if p_action not in('dismiss','hide') or length(trim(coalesce(p_reason,'')))<1 then raise exception 'invalid template report decision' using errcode='22023'; end if;
  h:=encode(extensions.digest(jsonb_build_object('report_id',p_report_id,'action',p_action,'reason',trim(p_reason))::text,'sha256'),'hex'); r:=private.admin_lock(a,p_operation_id,'admin_resolve_course_template_report',h); if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  select * into q from public.course_template_reports where id=p_report_id for update; if not found or q.status<>'pending' then raise exception 'template report unavailable or already resolved' using errcode='PT409'; end if;
  select * into t from public.course_templates where id=q.template_id for update; if not found then state:='target_missing'; else if p_action='hide' and t.status='active' then update public.course_templates set status='hidden',moderation_hidden_at=now(),moderation_hidden_by=a,moderation_reason=trim(p_reason),version=version+1 where id=t.id; state:='hidden'; elsif t.status='hidden' then state:='already_hidden'; else state:='unchanged'; end if; end if;
  update public.course_template_reports set status=case when p_action='hide' then 'actioned' else 'dismissed' end,reviewed_by=a,reviewed_at=now(),decision_reason=trim(p_reason),version=version+1,updated_at=now() where id=q.id;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata) values(a,'course_template_report_'||p_action,'course_template',q.template_id,jsonb_build_object('report_id',q.id,'reason',trim(p_reason),'target_state',state)) returning id into aid;
  r:=jsonb_build_object('report_id',q.id,'status',case when p_action='hide' then 'actioned' else 'dismissed' end,'target_state',state,'audit_id',aid); perform private.admin_record(a,p_operation_id,'admin_resolve_course_template_report',h,r); return r;
end; $$;

create or replace function public.admin_merge_course_templates(p_source_template_id uuid,p_target_template_id uuid,p_expected_source_version bigint,p_expected_target_version bigint,p_reason text,p_operation_id uuid)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=private.require_global_admin(); h text; r jsonb; s record; t record; aid uuid;
begin
  if p_source_template_id is null or p_target_template_id is null or p_source_template_id=p_target_template_id then raise exception 'self merge is not allowed' using errcode='PT409'; end if;
  h:=encode(extensions.digest(jsonb_build_object('source',p_source_template_id,'target',p_target_template_id,'source_version',p_expected_source_version,'target_version',p_expected_target_version,'reason',trim(p_reason))::text,'sha256'),'hex'); r:=private.admin_lock(a,p_operation_id,'admin_merge_course_templates',h); if r is not null then return jsonb_set(r,'{replayed}','true'::jsonb,true); end if;
  perform pg_advisory_xact_lock(hashtextextended('template-merge:'||least(p_source_template_id,p_target_template_id)::text||':'||greatest(p_source_template_id,p_target_template_id)::text,9016));
  select * into s from public.course_templates where id=p_source_template_id for update;
  if not found then raise exception 'active same-university merge targets are required' using errcode='42501'; end if;
  select * into t from public.course_templates where id=p_target_template_id for update;
  if not found or s.status<>'active' or s.deleted_at is not null or t.status<>'active' or t.deleted_at is not null or s.university_id<>t.university_id then raise exception 'active same-university merge targets are required' using errcode='42501'; end if;
  if p_expected_source_version is null or p_expected_target_version is null or s.version<>p_expected_source_version or t.version<>p_expected_target_version then raise exception 'template merge version conflict' using errcode='PT409'; end if;
  if private.phase16_canonical_template(t.id)<>t.id or private.phase16_canonical_template(s.id)<>s.id then raise exception 'template merge target is already merged' using errcode='PT409'; end if;
  update public.course_templates set status='merged',canonical_template_id=t.id,merged_at=now(),merged_by=a,updated_at=now() where id=s.id;
  update public.course_template_duplicate_candidates set status='merged',merged_template_id=t.id,reviewed_by=a,reviewed_at=now(),decision_reason=trim(p_reason),version=version+1 where status='pending' and ((template_a_id=s.id and template_b_id=t.id) or (template_a_id=t.id and template_b_id=s.id));
  update public.course_templates set copy_count_total=(select count(distinct e.user_course_id) from public.course_template_copy_events e where e.template_id in (s.id,t.id) and e.user_course_id is not null),copy_count_term=(select count(distinct e.user_course_id) from public.course_template_copy_events e join public.user_courses uc on uc.id=e.user_course_id where e.template_id in (s.id,t.id) and e.user_course_id is not null and uc.term_id=t.term_id) where id=t.id;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata) values(a,'course_template_merge','course_template',s.id,jsonb_build_object('target_template_id',t.id,'reason',trim(p_reason),'source_version',s.version,'target_version',t.version)) returning id into aid;
  r:=jsonb_build_object('source_template_id',s.id,'target_template_id',t.id,'status','merged','audit_id',aid); perform private.admin_record(a,p_operation_id,'admin_merge_course_templates',h,r); return r;
end; $$;

revoke all on function public.publish_course_template(uuid,uuid),public.submit_course_template_edit_proposal(uuid,jsonb,bigint,uuid),public.report_course_template(uuid,text,uuid),public.get_course_template_for_user(uuid),public.get_course_template_update(uuid),public.review_course_template_update(uuid,text,bigint) from public,anon;
grant execute on function public.publish_course_template(uuid,uuid),public.submit_course_template_edit_proposal(uuid,jsonb,bigint,uuid),public.report_course_template(uuid,text,uuid),public.get_course_template_for_user(uuid),public.get_course_template_update(uuid),public.review_course_template_update(uuid,text,bigint) to authenticated;
revoke all on function public.admin_list_university_requests(int,int),public.admin_resolve_university_request(uuid,text,uuid,text,uuid),public.admin_list_universities(int,int),public.admin_update_university(uuid,text,text[],text,text,bigint,text,uuid),public.admin_list_course_template_proposals(int,int),public.admin_list_course_template_reports(int,int),public.admin_list_course_template_duplicates(int,int),public.admin_resolve_course_template_proposal(uuid,text,text,uuid),public.admin_resolve_course_template_report(uuid,text,text,uuid),public.admin_merge_course_templates(uuid,uuid,bigint,bigint,text,uuid) from public,anon;
grant execute on function public.admin_list_university_requests(int,int),public.admin_resolve_university_request(uuid,text,uuid,text,uuid),public.admin_list_universities(int,int),public.admin_update_university(uuid,text,text[],text,text,bigint,text,uuid),public.admin_list_course_template_proposals(int,int),public.admin_list_course_template_reports(int,int),public.admin_list_course_template_duplicates(int,int),public.admin_resolve_course_template_proposal(uuid,text,text,uuid),public.admin_resolve_course_template_report(uuid,text,text,uuid),public.admin_merge_course_templates(uuid,uuid,bigint,bigint,text,uuid) to authenticated;

commit;
