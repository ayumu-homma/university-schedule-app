-- Serialize duplicate discovery at the eligible university/title cohort level.
-- The deferred trigger reads final transaction state, including concurrent commits.
begin;

create or replace function private.refresh_course_template_duplicate_candidates()
returns trigger
language plpgsql
security definer
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
  v_current public.course_templates%rowtype;
  v_cohort_locks bigint[] := array[]::bigint[];
  v_lock bigint;
begin
  -- Deferred events may represent an intermediate state when a row is changed
  -- more than once in one transaction. Always reconcile the row's final state.
  select t.* into v_current
  from public.course_templates t
  where t.id = new.id;
  if not found then
    return new;
  end if;

  -- Serialize candidate discovery per university + normalized-title cohort.
  -- Old and final scopes are locked in hash order so title/university moves
  -- cannot deadlock with the same move in another transaction.
  if nullif(btrim(v_current.normalized_title), '') is not null then
    v_cohort_locks := array_append(v_cohort_locks, pg_catalog.hashtextextended(
      'course-template-duplicate-cohort:' || pg_catalog.jsonb_build_array(v_current.university_id::text, v_current.normalized_title)::text, 9018));
  end if;
  if tg_op = 'UPDATE' and nullif(btrim(old.normalized_title), '') is not null then
    v_cohort_locks := array_append(v_cohort_locks, pg_catalog.hashtextextended(
      'course-template-duplicate-cohort:' || pg_catalog.jsonb_build_array(old.university_id::text, old.normalized_title)::text, 9018));
  end if;
  for v_lock in
    select distinct k from pg_catalog.unnest(v_cohort_locks) as locks(k) order by k
  loop
    perform pg_catalog.pg_advisory_xact_lock(v_lock);
  end loop;
  -- A selected merge is preserved for the existing merge RPC to mark as
  -- status=merged. Other pending pairs involving the merged source are stale.
  if v_current.status = 'merged' then
    for v_candidate in
      select d.id, d.template_a_id, d.template_b_id
      from public.course_template_duplicate_candidates d
      where d.status = 'pending'
        and (d.template_a_id = v_current.id or d.template_b_id = v_current.id)
        and case
          when d.template_a_id = v_current.id then d.template_b_id
          else d.template_a_id
        end is distinct from v_current.canonical_template_id
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
  if v_current.status <> 'active' or v_current.deleted_at is not null
     or v_current.canonical_template_id is not null then
    for v_candidate in
      select d.id, d.template_a_id, d.template_b_id
      from public.course_template_duplicate_candidates d
      where d.status = 'pending'
        and (d.template_a_id = v_current.id or d.template_b_id = v_current.id)
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
      and (d.template_a_id = v_current.id or d.template_b_id = v_current.id)
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
    where t.id <> v_current.id
      and t.university_id = v_current.university_id
      and t.status = 'active'
      and t.deleted_at is null
      and t.canonical_template_id is null
      and t.normalized_title = v_current.normalized_title
    order by t.id
  loop
    v_a := least(v_current.id, v_other.id);
    v_b := greatest(v_current.id, v_other.id);
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
      select v_current.university_id, v_a, v_b, v_score
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

drop trigger if exists course_template_duplicate_candidates_after_insert on public.course_templates;
drop trigger if exists course_template_duplicate_candidates_after_update on public.course_templates;

create constraint trigger course_template_duplicate_candidates_after_insert
after insert on public.course_templates
deferrable initially deferred
for each row
execute function private.refresh_course_template_duplicate_candidates();

create constraint trigger course_template_duplicate_candidates_after_update
after update on public.course_templates
deferrable initially deferred
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

commit;
