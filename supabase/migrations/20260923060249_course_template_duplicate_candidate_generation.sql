-- COURSE-03: create review-only duplicate candidates from the v0.4 Level 1–3
-- keys. Scores are ordinal confidence tiers for the existing admin queue:
-- Level 1 = 0.99, Level 2 = 0.90, Level 3 = 0.80. No fuzzy Level 4 matching.
begin;

create or replace function private.course_template_duplicate_score(
  p_template_a_id uuid,
  p_template_b_id uuid
)
returns numeric
language sql
stable
set search_path = ''
as $$
  select case
    when a.university_id = b.university_id
      and a.academic_year = b.academic_year
      and a.term_id is not distinct from b.term_id
      and a.normalized_title = b.normalized_title
      and a.normalized_instructor_name is not distinct from b.normalized_instructor_name
      and a.day_of_week is not distinct from b.day_of_week
      and a.period_no is not distinct from b.period_no
      then 0.99::numeric
    when a.university_id = b.university_id
      and a.academic_year = b.academic_year
      and a.term_id is not distinct from b.term_id
      and a.normalized_title = b.normalized_title
      and a.day_of_week is not distinct from b.day_of_week
      and a.period_no is not distinct from b.period_no
      then 0.90::numeric
    when a.university_id = b.university_id
      and a.normalized_title = b.normalized_title
      and nullif(btrim(a.normalized_instructor_name), '') is not null
      and a.normalized_instructor_name = b.normalized_instructor_name
      then 0.80::numeric
    else null::numeric
  end
  from public.course_templates a
  join public.course_templates b on b.id = p_template_b_id
  where a.id = p_template_a_id
    and a.id < b.id
    and a.status = 'active'
    and a.deleted_at is null
    and a.canonical_template_id is null
    and b.status = 'active'
    and b.deleted_at is null
    and b.canonical_template_id is null
    and nullif(btrim(a.normalized_title), '') is not null
    and a.normalized_title = b.normalized_title;
$$;

create or replace function private.refresh_course_template_duplicate_candidates()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_other record;
  v_candidate record;
  v_a uuid;
  v_b uuid;
  v_score numeric;
  v_existing_id uuid;
  v_existing_status text;
begin
  -- A selected merge is preserved for the existing merge RPC to mark as
  -- status=merged. Other pending pairs involving the merged source are stale.
  if new.status = 'merged' then
    for v_candidate in
      select d.id, d.template_a_id, d.template_b_id
      from public.course_template_duplicate_candidates d
      where d.status = 'pending'
        and (d.template_a_id = new.id or d.template_b_id = new.id)
        and case
          when d.template_a_id = new.id then d.template_b_id
          else d.template_a_id
        end is distinct from new.canonical_template_id
      order by least(d.template_a_id, d.template_b_id),
               greatest(d.template_a_id, d.template_b_id), d.id
    loop
      v_a := least(v_candidate.template_a_id, v_candidate.template_b_id);
      v_b := greatest(v_candidate.template_a_id, v_candidate.template_b_id);
      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended('course-template-duplicate:' || v_a::text || ':' || v_b::text, 9017)
      );
      delete from public.course_template_duplicate_candidates d
      where d.id = v_candidate.id and d.status = 'pending';
    end loop;
    return new;
  end if;

  -- Hidden/deleted/non-root rows cannot remain actionable review candidates.
  if new.status <> 'active' or new.deleted_at is not null
     or new.canonical_template_id is not null then
    for v_candidate in
      select d.id, d.template_a_id, d.template_b_id
      from public.course_template_duplicate_candidates d
      where d.status = 'pending'
        and (d.template_a_id = new.id or d.template_b_id = new.id)
      order by least(d.template_a_id, d.template_b_id),
               greatest(d.template_a_id, d.template_b_id), d.id
    loop
      v_a := least(v_candidate.template_a_id, v_candidate.template_b_id);
      v_b := greatest(v_candidate.template_a_id, v_candidate.template_b_id);
      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended('course-template-duplicate:' || v_a::text || ':' || v_b::text, 9017)
      );
      delete from public.course_template_duplicate_candidates d
      where d.id = v_candidate.id and d.status = 'pending';
    end loop;
    return new;
  end if;

  -- Re-score existing pending pairs and remove only pending rows that no
  -- longer qualify. Human-reviewed history is deliberately left untouched.
  for v_candidate in
    select d.id, d.template_a_id, d.template_b_id
    from public.course_template_duplicate_candidates d
    where d.status = 'pending'
      and (d.template_a_id = new.id or d.template_b_id = new.id)
    order by least(d.template_a_id, d.template_b_id),
             greatest(d.template_a_id, d.template_b_id), d.id
  loop
    v_a := least(v_candidate.template_a_id, v_candidate.template_b_id);
    v_b := greatest(v_candidate.template_a_id, v_candidate.template_b_id);
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('course-template-duplicate:' || v_a::text || ':' || v_b::text, 9017)
    );

    select private.course_template_duplicate_score(v_a, v_b)
    into v_score;

    if v_score is null then
      delete from public.course_template_duplicate_candidates d
      where d.id = v_candidate.id and d.status = 'pending';
    else
      update public.course_template_duplicate_candidates d
      set score = v_score, version = d.version + 1
      where d.id = v_candidate.id and d.status = 'pending'
        and d.score is distinct from v_score;
    end if;
  end loop;

  -- The normalized-title index bounds candidate lookup. The pair lock plus
  -- the existing ordered unique key prevents duplicate inserts during races;
  -- either orientation of an existing/reviewed pair blocks resurrection.
  for v_other in
    select t.id
    from public.course_templates t
    where t.id <> new.id
      and t.university_id = new.university_id
      and t.status = 'active'
      and t.deleted_at is null
      and t.canonical_template_id is null
      and t.normalized_title = new.normalized_title
    order by t.id
  loop
    v_a := least(new.id, v_other.id);
    v_b := greatest(new.id, v_other.id);
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('course-template-duplicate:' || v_a::text || ':' || v_b::text, 9017)
    );

    select private.course_template_duplicate_score(v_a, v_b)
    into v_score;
    if v_score is null then
      continue;
    end if;

    v_existing_id := null;
    v_existing_status := null;
    select d.id, d.status
    into v_existing_id, v_existing_status
    from public.course_template_duplicate_candidates d
    where (d.template_a_id = v_a and d.template_b_id = v_b)
       or (d.template_a_id = v_b and d.template_b_id = v_a)
    order by d.created_at, d.id
    limit 1
    for update;

    if v_existing_id is null then
      insert into public.course_template_duplicate_candidates(
        university_id, template_a_id, template_b_id, score
      )
      select new.university_id, v_a, v_b, v_score
      where not exists (
        select 1
        from public.course_template_duplicate_candidates d
        where (d.template_a_id = v_a and d.template_b_id = v_b)
           or (d.template_a_id = v_b and d.template_b_id = v_a)
      )
      on conflict (template_a_id, template_b_id) do nothing;
    elsif v_existing_status = 'pending' then
      update public.course_template_duplicate_candidates d
      set score = v_score, version = d.version + 1
      where d.id = v_existing_id and d.status = 'pending'
        and d.score is distinct from v_score;
    end if;
  end loop;

  return new;
end;
$$;

revoke all on function private.course_template_duplicate_score(uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function private.refresh_course_template_duplicate_candidates()
  from public, anon, authenticated, service_role;

create index if not exists course_template_duplicate_pending_a_idx
  on public.course_template_duplicate_candidates(template_a_id)
  where status = 'pending';
create index if not exists course_template_duplicate_pending_b_idx
  on public.course_template_duplicate_candidates(template_b_id)
  where status = 'pending';

create trigger course_template_duplicate_candidates_after_insert
after insert on public.course_templates
for each row
execute function private.refresh_course_template_duplicate_candidates();

create trigger course_template_duplicate_candidates_after_update
after update of university_id, academic_year, term_id, normalized_title,
  normalized_instructor_name, day_of_week, period_no, status, deleted_at,
  canonical_template_id
on public.course_templates
for each row
when (
  old.university_id is distinct from new.university_id
  or old.academic_year is distinct from new.academic_year
  or old.term_id is distinct from new.term_id
  or old.normalized_title is distinct from new.normalized_title
  or old.normalized_instructor_name is distinct from new.normalized_instructor_name
  or old.day_of_week is distinct from new.day_of_week
  or old.period_no is distinct from new.period_no
  or old.status is distinct from new.status
  or old.deleted_at is distinct from new.deleted_at
  or old.canonical_template_id is distinct from new.canonical_template_id
)
execute function private.refresh_course_template_duplicate_candidates();

-- One-time additive generation. Existing rows in either orientation—including
-- reviewed/rejected/merged decisions—are left byte-for-byte unchanged.
insert into public.course_template_duplicate_candidates(
  university_id, template_a_id, template_b_id, score
)
select a.university_id, a.id, b.id,
       private.course_template_duplicate_score(a.id, b.id)
from public.course_templates a
join public.course_templates b
  on b.university_id = a.university_id
 and a.id < b.id
 and b.status = 'active'
 and b.deleted_at is null
 and b.canonical_template_id is null
 and b.normalized_title = a.normalized_title
where a.status = 'active'
  and a.deleted_at is null
  and a.canonical_template_id is null
  and nullif(btrim(a.normalized_title), '') is not null
  and private.course_template_duplicate_score(a.id, b.id) is not null
  and not exists (
    select 1
    from public.course_template_duplicate_candidates d
    where (d.template_a_id = a.id and d.template_b_id = b.id)
       or (d.template_a_id = b.id and d.template_b_id = a.id)
  )
on conflict (template_a_id, template_b_id) do nothing;

commit;
