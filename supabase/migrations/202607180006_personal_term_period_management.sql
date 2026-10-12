-- Phase 4: post-onboarding personal term and period management.
--
-- Personal terms and period settings are private snapshots.  Catalog rows are
-- read-only input to these RPCs; clients never receive a direct write grant to
-- the underlying tables.  Every mutation is bound to auth.uid(), the caller's
-- current university, and the profile's campus/user-type eligibility.

begin;

create or replace function private.normalize_personal_periods(
  p_periods jsonb
)
returns jsonb
language plpgsql
set search_path = pg_catalog, public, private
as $$
declare
  normalized jsonb;
begin
  if jsonb_typeof(p_periods) <> 'array'
     or jsonb_array_length(p_periods) not between 1 and 63 then
    raise exception 'period list must contain between 1 and 63 rows'
      using errcode = '22023';
  end if;

  begin
    select jsonb_agg(
      jsonb_build_object(
        'day_of_week', row_value.day_of_week,
        'period_no', row_value.period_no,
        'start_time', row_value.start_time::text,
        'end_time', row_value.end_time::text
      )
      order by row_value.day_of_week, row_value.period_no
    )
    into normalized
    from jsonb_to_recordset(p_periods) as row_value(
      day_of_week integer,
      period_no integer,
      start_time time,
      end_time time
    );
  exception
    when data_exception then
      raise exception 'invalid period row' using errcode = '22023';
  end;

  if normalized is null or exists (
    select 1
    from jsonb_to_recordset(normalized) as row_value(
      day_of_week integer,
      period_no integer,
      start_time time,
      end_time time
    )
    where row_value.day_of_week not between 1 and 7
       or row_value.period_no not between 1 and 9
       or row_value.start_time is null
       or row_value.end_time is null
       or row_value.end_time <= row_value.start_time
  ) then
    raise exception 'invalid period row' using errcode = '22023';
  end if;

  if (
    select count(*)
    from jsonb_to_recordset(normalized) as row_value(
      day_of_week integer,
      period_no integer,
      start_time time,
      end_time time
    )
  ) <> (
    select count(distinct (row_value.day_of_week, row_value.period_no))
    from jsonb_to_recordset(normalized) as row_value(
      day_of_week integer,
      period_no integer,
      start_time time,
      end_time time
    )
  ) then
    raise exception 'duplicate period slot' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(normalized) as first_row(
      day_of_week integer,
      period_no integer,
      start_time time,
      end_time time
    )
    join jsonb_to_recordset(normalized) as second_row(
      day_of_week integer,
      period_no integer,
      start_time time,
      end_time time
    )
      on first_row.day_of_week = second_row.day_of_week
     and first_row.period_no < second_row.period_no
     and first_row.start_time < second_row.end_time
     and second_row.start_time < first_row.end_time
  ) then
    raise exception 'period times overlap' using errcode = '22023';
  end if;

  return normalized;
end;
$$;

create or replace function private.resolve_personal_period_configuration(
  p_university_id uuid,
  p_campus_id uuid,
  p_user_type text,
  p_academic_year integer,
  p_period_template_set_id uuid,
  p_custom_periods jsonb
)
returns table (
  source_template_set_id uuid,
  normalized_periods jsonb
)
language plpgsql
set search_path = pg_catalog, public, private
as $$
declare
  resolved_periods jsonb;
begin
  if (p_period_template_set_id is null) = (p_custom_periods is null) then
    raise exception 'choose a period template set or custom periods, not both'
      using errcode = '22023';
  end if;

  if p_period_template_set_id is not null then
    if not exists (
      select 1
      from public.period_template_sets template_set
      where template_set.id = p_period_template_set_id
        and template_set.university_id = p_university_id
        and template_set.status = 'active'
        and template_set.deleted_at is null
        and (
          template_set.academic_year is null
          or template_set.academic_year = p_academic_year
        )
        and (
          template_set.user_type is null
          or template_set.user_type = p_user_type
        )
        and (
          template_set.campus_id is null
          or template_set.campus_id = p_campus_id
        )
    ) then
      raise exception 'period template set is not available'
        using errcode = '22023';
    end if;

    select jsonb_agg(
      jsonb_build_object(
        'day_of_week', template.day_of_week,
        'period_no', template.period_no,
        'start_time', template.start_time::text,
        'end_time', template.end_time::text
      )
      order by template.day_of_week, template.period_no
    )
    into resolved_periods
    from public.period_templates template
    where template.template_set_id = p_period_template_set_id
      and template.university_id = p_university_id
      and template.deleted_at is null;

    if resolved_periods is null then
      raise exception 'period template set has no active periods'
        using errcode = '22023';
    end if;

    source_template_set_id := p_period_template_set_id;
    normalized_periods := private.normalize_personal_periods(resolved_periods);
  else
    source_template_set_id := null;
    normalized_periods := private.normalize_personal_periods(p_custom_periods);
  end if;

  return next;
end;
$$;

create or replace function public.create_personal_term(
  p_term_template_id uuid,
  p_custom_term_name text,
  p_custom_academic_year integer,
  p_custom_start_date date,
  p_custom_end_date date,
  p_custom_term_type text,
  p_period_template_set_id uuid,
  p_custom_periods jsonb,
  p_make_active boolean
)
returns table (
  term_id uuid,
  active_term_id uuid
)
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  caller_id uuid := auth.uid();
  locked_profile public.profiles%rowtype;
  source_term public.terms%rowtype;
  selected_academic_year integer;
  selected_name text;
  selected_start_date date;
  selected_end_date date;
  selected_term_type text;
  selected_instruction_start_date date;
  selected_instruction_end_date date;
  selected_source_template_id uuid;
  resolved_periods jsonb;
  resolved_template_set_id uuid;
  created_term_id uuid;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_make_active is null then
    raise exception 'make active selection is required' using errcode = '22023';
  end if;

  select profile.* into locked_profile
  from public.profiles profile
  where profile.user_id = caller_id
    and profile.deleted_at is null
  for update;
  if not found
     or locked_profile.university_id is null
     or locked_profile.onboarding_status <> 'complete' then
    raise exception 'completed university profile is required'
      using errcode = '42501';
  end if;

  if locked_profile.active_term_id is not null and not exists (
    select 1
    from public.terms active_term
    where active_term.id = locked_profile.active_term_id
      and active_term.owner_user_id = caller_id
      and active_term.university_id = locked_profile.university_id
      and not active_term.is_template
      and active_term.status = 'active'
      and active_term.deleted_at is null
  ) then
    raise exception 'profile active term is unavailable' using errcode = '42501';
  end if;
  if not p_make_active and locked_profile.active_term_id is null then
    raise exception 'the first personal term must be active' using errcode = '22023';
  end if;

  if p_term_template_id is not null then
    if p_custom_term_name is not null
       or p_custom_academic_year is not null
       or p_custom_start_date is not null
       or p_custom_end_date is not null
       or p_custom_term_type is not null then
      raise exception 'choose a term template or a custom term, not both'
        using errcode = '22023';
    end if;

    select template.* into source_term
    from public.terms template
    where template.id = p_term_template_id
      and template.university_id = locked_profile.university_id
      and template.is_template
      and template.status = 'active'
      and template.deleted_at is null;
    if not found then
      raise exception 'term template is not available' using errcode = '22023';
    end if;

    selected_name := source_term.name;
    selected_academic_year := source_term.academic_year;
    selected_start_date := source_term.start_date;
    selected_end_date := source_term.end_date;
    selected_instruction_start_date := source_term.instruction_start_date;
    selected_instruction_end_date := source_term.instruction_end_date;
    selected_term_type := source_term.term_type;
    selected_source_template_id := source_term.id;
  else
    if nullif(btrim(p_custom_term_name), '') is null
       or p_custom_academic_year is null
       or p_custom_start_date is null
       or p_custom_end_date is null
       or p_custom_term_type is null then
      raise exception 'custom term fields are incomplete' using errcode = '22023';
    end if;
    if p_custom_academic_year not between 1900 and 2200
       or p_custom_end_date < p_custom_start_date
       or p_custom_term_type not in (
         'semester', 'quarter', 'custom', 'intensive', 'year_round'
       )
       or char_length(btrim(p_custom_term_name)) > 100 then
      raise exception 'invalid custom term' using errcode = '22023';
    end if;

    selected_name := btrim(p_custom_term_name);
    selected_academic_year := p_custom_academic_year;
    selected_start_date := p_custom_start_date;
    selected_end_date := p_custom_end_date;
    selected_instruction_start_date := null;
    selected_instruction_end_date := null;
    selected_term_type := p_custom_term_type;
    selected_source_template_id := null;
  end if;

  select configuration.source_template_set_id, configuration.normalized_periods
  into resolved_template_set_id, resolved_periods
  from private.resolve_personal_period_configuration(
    locked_profile.university_id,
    locked_profile.campus_id,
    locked_profile.user_type,
    selected_academic_year,
    p_period_template_set_id,
    p_custom_periods
  ) configuration;

  insert into public.terms (
    university_id,
    name,
    academic_year,
    start_date,
    end_date,
    instruction_start_date,
    instruction_end_date,
    term_type,
    created_by,
    owner_user_id,
    source_template_id,
    is_template,
    status
  ) values (
    locked_profile.university_id,
    selected_name,
    selected_academic_year,
    selected_start_date,
    selected_end_date,
    selected_instruction_start_date,
    selected_instruction_end_date,
    selected_term_type,
    caller_id,
    caller_id,
    selected_source_template_id,
    false,
    'active'
  ) returning id into created_term_id;

  insert into public.period_settings (
    owner_user_id,
    university_id,
    term_id,
    source_template_set_id,
    day_of_week,
    period_no,
    start_time,
    end_time,
    is_template
  )
  select
    caller_id,
    locked_profile.university_id,
    created_term_id,
    resolved_template_set_id,
    row_value.day_of_week,
    row_value.period_no,
    row_value.start_time,
    row_value.end_time,
    false
  from jsonb_to_recordset(resolved_periods) as row_value(
    day_of_week integer,
    period_no integer,
    start_time time,
    end_time time
  );

  if p_make_active then
    update public.profiles
    set active_term_id = created_term_id
    where user_id = caller_id;
    active_term_id := created_term_id;
  else
    active_term_id := locked_profile.active_term_id;
  end if;
  term_id := created_term_id;
  return next;
end;
$$;

create or replace function public.activate_personal_term(
  p_term_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  caller_id uuid := auth.uid();
  locked_profile public.profiles%rowtype;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_term_id is null then
    raise exception 'personal term is required' using errcode = '22023';
  end if;

  select profile.* into locked_profile
  from public.profiles profile
  where profile.user_id = caller_id
    and profile.deleted_at is null
  for update;
  if not found
     or locked_profile.university_id is null
     or locked_profile.onboarding_status <> 'complete' then
    raise exception 'completed university profile is required'
      using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.terms personal_term
    where personal_term.id = p_term_id
      and personal_term.owner_user_id = caller_id
      and personal_term.university_id = locked_profile.university_id
      and not personal_term.is_template
      and personal_term.status = 'active'
      and personal_term.deleted_at is null
  ) then
    raise exception 'personal term is not available' using errcode = '42501';
  end if;

  update public.profiles
  set active_term_id = p_term_id
  where user_id = caller_id;
  return p_term_id;
end;
$$;

create or replace function public.replace_personal_period_settings(
  p_term_id uuid,
  p_period_template_set_id uuid,
  p_custom_periods jsonb
)
returns integer
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  caller_id uuid := auth.uid();
  locked_profile public.profiles%rowtype;
  personal_term public.terms%rowtype;
  resolved_periods jsonb;
  resolved_template_set_id uuid;
  inserted_count integer;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_term_id is null then
    raise exception 'personal term is required' using errcode = '22023';
  end if;

  select profile.* into locked_profile
  from public.profiles profile
  where profile.user_id = caller_id
    and profile.deleted_at is null
  for update;
  if not found
     or locked_profile.university_id is null
     or locked_profile.onboarding_status <> 'complete' then
    raise exception 'completed university profile is required'
      using errcode = '42501';
  end if;

  select term_row.* into personal_term
  from public.terms term_row
  where term_row.id = p_term_id
    and term_row.owner_user_id = caller_id
    and term_row.university_id = locked_profile.university_id
    and not term_row.is_template
    and term_row.status = 'active'
    and term_row.deleted_at is null
  for update;
  if not found then
    raise exception 'personal term is not available' using errcode = '42501';
  end if;

  select configuration.source_template_set_id, configuration.normalized_periods
  into resolved_template_set_id, resolved_periods
  from private.resolve_personal_period_configuration(
    locked_profile.university_id,
    locked_profile.campus_id,
    locked_profile.user_type,
    personal_term.academic_year,
    p_period_template_set_id,
    p_custom_periods
  ) configuration;

  delete from public.period_settings setting_row
  where setting_row.owner_user_id = caller_id
    and setting_row.university_id = locked_profile.university_id
    and setting_row.term_id = personal_term.id;

  insert into public.period_settings (
    owner_user_id,
    university_id,
    term_id,
    source_template_set_id,
    day_of_week,
    period_no,
    start_time,
    end_time,
    is_template
  )
  select
    caller_id,
    locked_profile.university_id,
    personal_term.id,
    resolved_template_set_id,
    row_value.day_of_week,
    row_value.period_no,
    row_value.start_time,
    row_value.end_time,
    false
  from jsonb_to_recordset(resolved_periods) as row_value(
    day_of_week integer,
    period_no integer,
    start_time time,
    end_time time
  );
  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;

-- No client gets a raw write path to personal schedule configuration.  The
-- RLS read policies from the onboarding foundation continue to expose only a
-- caller's own snapshots, while these entry points make all writes atomic.
revoke all on table public.terms from anon, authenticated;
revoke all on table public.period_settings from anon, authenticated;
grant select on table public.terms, public.period_settings to authenticated;

revoke execute on function private.normalize_personal_periods(jsonb)
  from public, anon, authenticated, service_role;
revoke execute on function private.resolve_personal_period_configuration(
  uuid, uuid, text, integer, uuid, jsonb
) from public, anon, authenticated, service_role;
revoke execute on function public.create_personal_term(
  uuid, text, integer, date, date, text, uuid, jsonb, boolean
) from public, anon;
revoke execute on function public.activate_personal_term(uuid)
  from public, anon;
revoke execute on function public.replace_personal_period_settings(
  uuid, uuid, jsonb
) from public, anon;
grant execute on function public.create_personal_term(
  uuid, text, integer, date, date, text, uuid, jsonb, boolean
) to authenticated;
grant execute on function public.activate_personal_term(uuid)
  to authenticated;
grant execute on function public.replace_personal_period_settings(
  uuid, uuid, jsonb
) to authenticated;

commit;
