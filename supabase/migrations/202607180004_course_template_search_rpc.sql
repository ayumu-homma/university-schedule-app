-- Phase 4: authenticated course-template search with a complete, redacted
-- catalog response. The client receives course metadata only; template
-- authorship and moderation fields remain server-only.

begin;

-- PostgreSQL cannot append an input argument through CREATE OR REPLACE.
-- Recreate the RPC with a trailing default so existing seven-argument callers
-- continue to work while authenticated clients can supply an instructor filter.
drop function if exists public.search_course_templates(
  text,
  uuid,
  integer,
  uuid,
  integer,
  integer,
  integer
);

create function public.search_course_templates(
  query_text text,
  target_university_id uuid,
  target_academic_year integer,
  target_term_id uuid default null,
  target_day_of_week integer default null,
  target_period_no integer default null,
  limit_count integer default 20,
  target_instructor_name text default null
)
returns table (
  id uuid,
  university_id uuid,
  academic_year integer,
  term_id uuid,
  title text,
  normalized_title text,
  instructor_name text,
  normalized_instructor_name text,
  day_of_week integer,
  period_no integer,
  room text,
  normalized_room text,
  credit_count numeric,
  syllabus_url text,
  external_course_code text,
  copy_count_total integer,
  copy_count_term integer,
  trust_score numeric,
  duplicate_key text,
  rank_score numeric
)
language sql
security definer
set search_path = pg_catalog, public
stable
as $$
  with caller as (
    select
      p.university_id,
      requested_term.id as requested_term_id,
      requested_term.source_template_id as requested_term_template_id
    from public.profiles p
    left join public.terms requested_term
      on target_term_id is not null
      and requested_term.id = target_term_id
      and requested_term.owner_user_id = p.user_id
      and requested_term.university_id = p.university_id
      and not requested_term.is_template
      and requested_term.status = 'active'
      and requested_term.deleted_at is null
    where p.user_id = auth.uid()
      and p.deleted_at is null
      and (target_term_id is null or requested_term.id is not null)
  ),
  normalized as (
    select
      public.normalize_course_text(query_text) as query_key,
      public.normalize_course_text(target_instructor_name) as instructor_key
  ),
  bounded as (
    select least(greatest(coalesce(limit_count, 20), 1), 50) as row_limit
  )
  select
    ct.id,
    ct.university_id,
    ct.academic_year,
    ct.term_id,
    ct.title,
    ct.normalized_title,
    ct.instructor_name,
    ct.normalized_instructor_name,
    ct.day_of_week,
    ct.period_no,
    ct.room,
    ct.normalized_room,
    ct.credit_count,
    ct.syllabus_url,
    ct.external_course_code,
    ct.copy_count_total,
    ct.copy_count_term,
    ct.trust_score,
    concat_ws(
      ':',
      ct.normalized_title,
      ct.normalized_instructor_name,
      ct.day_of_week,
      ct.period_no
    ) as duplicate_key,
    (
      case
        when n.query_key = '' then 0
        when ct.normalized_title = n.query_key then 1000
        when ct.normalized_title like '%' || n.query_key || '%' then 750
        when coalesce(ct.normalized_instructor_name, '') like
          '%' || n.query_key || '%' then 500
        else 0
      end
      + case
        when n.instructor_key = '' then 0
        when ct.normalized_instructor_name = n.instructor_key then 300
        else 150
      end
      + ln(1 + greatest(ct.copy_count_term, 0)) * 5
      + ln(1 + greatest(ct.copy_count_total, 0)) * 2
      + ct.trust_score
      - ct.report_count * 5
      + case
        when target_day_of_week is not null
          and ct.day_of_week = target_day_of_week then 50
        else 0
      end
      + case
        when target_period_no is not null
          and ct.period_no = target_period_no then 50
        else 0
      end
    )::numeric as rank_score
  from public.course_templates ct
  cross join caller c
  cross join normalized n
  where ct.university_id = target_university_id
    and ct.university_id = c.university_id
    and ct.academic_year = target_academic_year
    and (
      target_term_id is null
      or ct.term_id is null
      or ct.term_id = c.requested_term_id
      or ct.term_id = c.requested_term_template_id
    )
    and (target_day_of_week is null or ct.day_of_week = target_day_of_week)
    and (target_period_no is null or ct.period_no = target_period_no)
    and ct.status = 'active'
    and ct.deleted_at is null
    and (
      n.query_key = ''
      or ct.normalized_title like '%' || n.query_key || '%'
      or coalesce(ct.normalized_instructor_name, '') like
        '%' || n.query_key || '%'
    )
    and (
      n.instructor_key = ''
      or coalesce(ct.normalized_instructor_name, '') like
        '%' || n.instructor_key || '%'
    )
  order by
    rank_score desc,
    ct.copy_count_term desc,
    ct.copy_count_total desc,
    ct.id
  limit (select row_limit from bounded);
$$;

revoke execute on function public.search_course_templates(
  text,
  uuid,
  integer,
  uuid,
  integer,
  integer,
  integer,
  text
) from public, anon;
grant execute on function public.search_course_templates(
  text,
  uuid,
  integer,
  uuid,
  integer,
  integer,
  integer,
  text
) to authenticated;

commit;
