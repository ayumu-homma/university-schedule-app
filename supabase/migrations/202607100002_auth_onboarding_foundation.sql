-- Phase 2: authenticated onboarding, university catalog, and verification boundary.
-- This migration is append-only and intentionally keeps provider credentials,
-- raw email addresses, and verification codes outside PostgreSQL.

begin;

-- ---------------------------------------------------------------------------
-- Versioned university catalog
-- ---------------------------------------------------------------------------

alter table public.universities
  add column if not exists config_key text,
  add column if not exists name_en text,
  add column if not exists official_web_domain text,
  add column if not exists timezone text not null default 'Asia/Tokyo',
  add column if not exists deleted_at timestamptz,
  add column if not exists version bigint not null default 1;

create unique index if not exists universities_config_key_idx
  on public.universities(config_key)
  where config_key is not null;

alter table public.universities
  add constraint universities_timezone_not_blank
    check (btrim(timezone) <> ''),
  add constraint universities_official_domain_shape
    check (
      official_web_domain is null
      or (
        official_web_domain = lower(official_web_domain)
        and official_web_domain !~ '[@[:space:]]'
        and official_web_domain like '%.%'
      )
    );

create table public.campuses (
  id uuid primary key default gen_random_uuid(),
  university_id uuid not null references public.universities(id),
  config_key text not null unique,
  name text not null,
  normalized_name text not null,
  is_main boolean not null default false,
  status text not null default 'active' check (status in ('active', 'hidden')),
  effective_from date,
  effective_to date,
  source_url text,
  source_checked_at date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1,
  unique (id, university_id),
  check (btrim(name) <> ''),
  check (effective_to is null or effective_from is null or effective_to >= effective_from)
);

create table public.faculties (
  id uuid primary key default gen_random_uuid(),
  university_id uuid not null references public.universities(id),
  config_key text not null unique,
  name text not null,
  normalized_name text not null,
  status text not null default 'active' check (status in ('active', 'hidden')),
  effective_from date,
  effective_to date,
  source_url text,
  source_checked_at date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1,
  unique (id, university_id),
  check (btrim(name) <> ''),
  check (effective_to is null or effective_from is null or effective_to >= effective_from)
);

create table public.departments (
  id uuid primary key default gen_random_uuid(),
  university_id uuid not null references public.universities(id),
  faculty_id uuid not null,
  config_key text not null unique,
  name text not null,
  normalized_name text not null,
  status text not null default 'active' check (status in ('active', 'hidden')),
  effective_from date,
  effective_to date,
  source_url text,
  source_checked_at date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1,
  unique (id, faculty_id, university_id),
  foreign key (faculty_id, university_id)
    references public.faculties(id, university_id),
  check (btrim(name) <> ''),
  check (effective_to is null or effective_from is null or effective_to >= effective_from)
);

create table public.university_domains (
  id uuid primary key default gen_random_uuid(),
  university_id uuid not null references public.universities(id),
  config_key text not null unique,
  domain text not null,
  kind text not null check (kind in ('official_web', 'student_email')),
  verification_enabled boolean not null default false,
  match_subdomains boolean not null default false,
  cohort_start_academic_year int,
  cohort_end_academic_year int,
  effective_from date,
  effective_to date,
  status text not null default 'active' check (status in ('active', 'hidden')),
  source_url text,
  source_checked_at date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1,
  unique (id, university_id),
  unique (university_id, domain, cohort_start_academic_year, cohort_end_academic_year),
  check (
    domain = lower(domain)
    and domain !~ '[@[:space:]]'
    and domain like '%.%'
  ),
  check (
    cohort_end_academic_year is null
    or cohort_start_academic_year is null
    or cohort_end_academic_year >= cohort_start_academic_year
  ),
  check (effective_to is null or effective_from is null or effective_to >= effective_from),
  check (not verification_enabled or kind = 'student_email')
);

create index campuses_university_active_idx
  on public.campuses(university_id, name)
  where status = 'active' and deleted_at is null;
create index faculties_university_active_idx
  on public.faculties(university_id, name)
  where status = 'active' and deleted_at is null;
create index departments_faculty_active_idx
  on public.departments(faculty_id, name)
  where status = 'active' and deleted_at is null;
create index university_domains_university_active_idx
  on public.university_domains(university_id, kind, domain)
  where status = 'active' and deleted_at is null;

-- ---------------------------------------------------------------------------
-- Personal term snapshots and period-template separation
-- ---------------------------------------------------------------------------

alter table public.terms
  add column if not exists config_key text,
  add column if not exists owner_user_id uuid references auth.users(id) on delete cascade,
  add column if not exists source_template_id uuid references public.terms(id),
  add column if not exists instruction_start_date date,
  add column if not exists instruction_end_date date,
  add column if not exists status text not null default 'active',
  add column if not exists deleted_at timestamptz,
  add column if not exists version bigint not null default 1;

update public.terms
set owner_user_id = created_by
where not is_template
  and owner_user_id is null
  and created_by is not null;

update public.terms t
set university_id = p.university_id
from public.profiles p
where not t.is_template
  and t.university_id is null
  and t.owner_user_id = p.user_id
  and p.university_id is not null;

do $$
begin
  if exists (
    select 1
    from public.terms
    where university_id is null
       or (is_template and owner_user_id is not null)
       or (not is_template and owner_user_id is null)
  ) then
    raise exception 'cannot migrate malformed legacy term ownership';
  end if;
end;
$$;


alter table public.terms
  alter column university_id set not null,
  add constraint terms_status_check check (status in ('active', 'hidden')),
  add constraint terms_date_order_check check (end_date >= start_date),
  add constraint terms_instruction_date_shape_check check (
    (instruction_start_date is null and instruction_end_date is null)
    or (
      instruction_start_date is not null
      and instruction_end_date is not null
      and instruction_end_date >= instruction_start_date
    )
  ),
  add constraint terms_academic_year_check check (academic_year between 1900 and 2200),
  add constraint terms_template_owner_shape_check check (
    (is_template and owner_user_id is null)
    or (not is_template and owner_user_id is not null)
  ),
  add constraint terms_id_owner_university_key unique (id, owner_user_id, university_id),
  add constraint terms_id_university_key unique (id, university_id);

create unique index if not exists terms_config_key_idx
  on public.terms(config_key)
  where config_key is not null;

create index terms_owner_active_idx
  on public.terms(owner_user_id, academic_year, start_date)
  where not is_template and deleted_at is null;

-- Retain the known pre-Phase-2 demo records for migration history, but remove
-- them from every active catalog surface. They must never be reidentified as
-- KIT or exposed as real source-backed data.
update public.universities
set status = 'hidden'
where id = '00000000-0000-0000-0000-000000000101'
  and normalized_name = public.normalize_course_text('東京サンプル大学');
update public.terms
set status = 'hidden'
where id = '00000000-0000-0000-0000-000000000201';
update public.course_templates
set status = 'hidden'
where id in (
  '00000000-0000-0000-0000-000000000401',
  '00000000-0000-0000-0000-000000000402'
);

create table public.period_template_sets (
  id uuid primary key default gen_random_uuid(),
  university_id uuid not null references public.universities(id),
  campus_id uuid,
  config_key text not null unique,
  name text not null,
  academic_year int,
  user_type text check (user_type in ('undergraduate', 'graduate', 'other')),
  effective_from date,
  effective_to date,
  is_default boolean not null default false,
  status text not null default 'active' check (status in ('active', 'hidden')),
  source_url text,
  source_checked_at date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1,
  unique (id, university_id),
  foreign key (campus_id, university_id)
    references public.campuses(id, university_id),
  check (btrim(name) <> ''),
  check (academic_year is null or academic_year between 1900 and 2200),
  check (effective_to is null or effective_from is null or effective_to >= effective_from)
);

create table public.period_templates (
  id uuid primary key default gen_random_uuid(),
  template_set_id uuid not null,
  university_id uuid not null,
  day_of_week int not null check (day_of_week between 1 and 7),
  period_no int not null check (period_no between 1 and 9),
  start_time time not null,
  end_time time not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1,
  foreign key (template_set_id, university_id)
    references public.period_template_sets(id, university_id) on delete cascade,
  unique (template_set_id, day_of_week, period_no),
  check (end_time > start_time)
);

create index period_template_sets_catalog_idx
  on public.period_template_sets(university_id, academic_year, is_default)
  where status = 'active' and deleted_at is null;
create index period_templates_set_idx
  on public.period_templates(template_set_id, day_of_week, period_no)
  where deleted_at is null;

-- Preserve any pre-Phase-2 template rows as hidden legacy catalog data. The
-- source-backed seed creates the active pilot template after migrations run.
insert into public.period_template_sets (
  university_id,
  config_key,
  name,
  is_default,
  status
)
select distinct
  ps.university_id,
  'legacy-import:' || ps.university_id::text,
  'Legacy imported period template',
  false,
  'hidden'
from public.period_settings ps
where ps.is_template
  and ps.university_id is not null
on conflict (config_key) do nothing;

insert into public.period_templates (
  id,
  template_set_id,
  university_id,
  day_of_week,
  period_no,
  start_time,
  end_time,
  created_at,
  updated_at
)
select
  ps.id,
  pts.id,
  ps.university_id,
  ps.day_of_week,
  ps.period_no,
  ps.start_time,
  ps.end_time,
  ps.created_at,
  ps.updated_at
from public.period_settings ps
join public.period_template_sets pts
  on pts.config_key = 'legacy-import:' || ps.university_id::text
where ps.is_template
on conflict (id) do nothing;

delete from public.period_settings where is_template;

alter table public.period_settings
  add column if not exists term_id uuid,
  add column if not exists source_template_set_id uuid,
  add column if not exists deleted_at timestamptz,
  add column if not exists version bigint not null default 1;

do $$
begin
  if exists (
    select 1
    from public.period_settings
    where owner_user_id is null
       or university_id is null
       or term_id is null
  ) then
    raise exception 'cannot infer term ownership for legacy personal period settings';
  end if;
end;
$$;

alter table public.period_settings
  alter column owner_user_id set not null,
  alter column university_id set not null,
  alter column term_id set not null,
  alter column is_template set default false,
  drop constraint if exists period_settings_owner_user_id_university_id_day_of_week_per_key,
  add constraint period_settings_personal_only_check check (not is_template),
  add constraint period_settings_time_order_check check (end_time > start_time),
  add constraint period_settings_term_owner_university_fkey
    foreign key (term_id, owner_user_id, university_id)
    references public.terms(id, owner_user_id, university_id),
  add constraint period_settings_source_set_university_fkey
    foreign key (source_template_set_id, university_id)
    references public.period_template_sets(id, university_id),
  add constraint period_settings_owner_term_slot_key
    unique (owner_user_id, term_id, day_of_week, period_no);

create index period_settings_owner_term_active_idx
  on public.period_settings(owner_user_id, term_id, day_of_week, period_no)
  where deleted_at is null;

-- ---------------------------------------------------------------------------
-- Profile onboarding state and hierarchy integrity
-- ---------------------------------------------------------------------------

alter table public.calendars
  add constraint calendars_id_owner_key unique (id, owner_user_id);

alter table public.profiles
  add column if not exists campus_id uuid,
  add column if not exists faculty_id uuid,
  add column if not exists department_id uuid,
  add column if not exists active_term_id uuid,
  add column if not exists primary_calendar_id uuid,
  add column if not exists entry_academic_year int,
  add column if not exists onboarding_status text not null default 'not_started',
  add column if not exists onboarding_step text not null default 'profile',
  add column if not exists onboarding_completed_at timestamptz,
  add column if not exists version bigint not null default 1;

alter table public.profiles
  add constraint profiles_campus_university_fkey
    foreign key (campus_id, university_id)
    references public.campuses(id, university_id),
  add constraint profiles_faculty_university_fkey
    foreign key (faculty_id, university_id)
    references public.faculties(id, university_id),
  add constraint profiles_department_hierarchy_fkey
    foreign key (department_id, faculty_id, university_id)
    references public.departments(id, faculty_id, university_id),
  add constraint profiles_active_term_owner_fkey
    foreign key (active_term_id, user_id, university_id)
    references public.terms(id, owner_user_id, university_id),
  add constraint profiles_primary_calendar_owner_fkey
    foreign key (primary_calendar_id, user_id)
    references public.calendars(id, owner_user_id),
  add constraint profiles_entry_academic_year_check
    check (entry_academic_year is null or entry_academic_year between 1900 and 2200),
  add constraint profiles_onboarding_status_check
    check (onboarding_status in ('not_started', 'in_progress', 'complete')),
  add constraint profiles_onboarding_step_check
    check (onboarding_step in ('profile', 'university', 'term', 'periods', 'first_course', 'notifications', 'complete')),
  add constraint profiles_hierarchy_shape_check
    check (
      (campus_id is null or university_id is not null)
      and (faculty_id is null or university_id is not null)
      and (department_id is null or (faculty_id is not null and university_id is not null))
      and (active_term_id is null or university_id is not null)
    ),
  add constraint profiles_verification_university_check
    check (not university_verified or university_id is not null),
  add constraint profiles_onboarding_completion_shape_check
    check (
      (onboarding_status = 'complete' and onboarding_step = 'complete' and onboarding_completed_at is not null)
      or (onboarding_status <> 'complete' and onboarding_step <> 'complete' and onboarding_completed_at is null)
    );

alter table public.university_requests
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists version bigint not null default 1;

alter table public.university_requests
  add constraint university_requests_resolution_shape_check check (
    (status = 'pending' and resolved_by is null and resolved_at is null)
    or (status <> 'pending' and resolved_by is not null and resolved_at is not null)
  );

-- ---------------------------------------------------------------------------
-- Public verification status; secret-derived material remains private.
-- ---------------------------------------------------------------------------

create table public.university_email_verifications (
  user_id uuid not null references auth.users(id) on delete cascade,
  university_id uuid not null references public.universities(id),
  domain_rule_id uuid not null,
  request_id uuid not null unique,
  status text not null default 'pending'
    check (status in ('pending', 'verified', 'revoked', 'expired', 'failed')),
  requested_at timestamptz not null default now(),
  verified_at timestamptz,
  revoked_at timestamptz,
  updated_at timestamptz not null default now(),
  version bigint not null default 1,
  primary key (user_id, university_id),
  foreign key (domain_rule_id, university_id)
    references public.university_domains(id, university_id),
  check (
    (status = 'verified' and verified_at is not null and revoked_at is null)
    or (status = 'revoked' and revoked_at is not null)
    or (status in ('pending', 'expired', 'failed') and verified_at is null)
  )
);

create table private.university_email_verification_challenges (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  university_id uuid not null references public.universities(id),
  email_hmac text not null,
  challenge_hmac text not null,
  expires_at timestamptz not null,
  attempt_count int not null default 0,
  max_attempts int not null default 5,
  last_attempt_at timestamptz,
  consumed_at timestamptz,
  invalidated_at timestamptz,
  invalidation_reason text,
  created_at timestamptz not null default now(),
  check (email_hmac ~ '^[0-9a-f]{64}$'),
  check (challenge_hmac ~ '^[0-9a-f]{64}$'),
  check (expires_at > created_at),
  check (max_attempts between 1 and 10),
  check (attempt_count between 0 and max_attempts),
  check (consumed_at is null or invalidated_at is null)
);

create unique index university_email_challenge_active_idx
  on private.university_email_verification_challenges(request_id)
  where consumed_at is null and invalidated_at is null;

create table private.onboarding_idempotency (
  user_id uuid not null references auth.users(id) on delete cascade,
  idempotency_key uuid not null,
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  term_id uuid not null references public.terms(id),
  calendar_id uuid not null references public.calendars(id),
  completed_at timestamptz not null default now(),
  primary key (user_id, idempotency_key)
);

alter table public.campuses enable row level security;
alter table public.faculties enable row level security;
alter table public.departments enable row level security;
alter table public.university_domains enable row level security;
alter table public.period_template_sets enable row level security;
alter table public.period_templates enable row level security;
alter table public.university_email_verifications enable row level security;
alter table private.university_email_verification_challenges enable row level security;
alter table private.onboarding_idempotency enable row level security;

create trigger campuses_updated_at
before update on public.campuses
for each row execute function public.set_updated_at();
create trigger faculties_updated_at
before update on public.faculties
for each row execute function public.set_updated_at();
create trigger departments_updated_at
before update on public.departments
for each row execute function public.set_updated_at();
create trigger university_domains_updated_at
before update on public.university_domains
for each row execute function public.set_updated_at();
create trigger period_template_sets_updated_at
before update on public.period_template_sets
for each row execute function public.set_updated_at();
create trigger period_templates_updated_at
before update on public.period_templates
for each row execute function public.set_updated_at();
create trigger university_email_verifications_updated_at
before update on public.university_email_verifications
for each row execute function public.set_updated_at();
create trigger university_requests_updated_at
before update on public.university_requests
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Auth profile bootstrap and server-managed profile fields
-- ---------------------------------------------------------------------------

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  candidate_name text;
begin
  candidate_name := nullif(btrim(coalesce(
    new.raw_user_meta_data ->> 'display_name',
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'name',
    ''
  )), '');

  insert into public.profiles (user_id, display_name)
  values (new.id, left(coalesce(candidate_name, 'ユーザー'), 80))
  on conflict (user_id) do nothing;

  return new;
end;
$$;

revoke execute on function private.handle_new_user() from public, anon, authenticated, service_role;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function private.handle_new_user();

-- Backfill legacy Auth users without deriving a display name from an email
-- local-part, which may itself be a student identifier.
insert into public.profiles (user_id, display_name)
select u.id, 'ユーザー'
from auth.users u
left join public.profiles p on p.user_id = u.id
where p.user_id is null
on conflict (user_id) do nothing;

create or replace function public.guard_profile_server_managed_fields()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if current_user in ('anon', 'authenticated') then
    if tg_op = 'INSERT' then
      if new.university_verified then
        raise exception 'university_verified is server-managed' using errcode = '42501';
      end if;
      raise exception 'profiles are created by the auth bootstrap' using errcode = '42501';
    end if;

    if new.university_verified is distinct from old.university_verified then
      raise exception 'university_verified is server-managed' using errcode = '42501';
    end if;

    if new.user_id is distinct from old.user_id
       or new.user_type is distinct from old.user_type
       or new.university_id is distinct from old.university_id
       or new.campus_id is distinct from old.campus_id
       or new.faculty_id is distinct from old.faculty_id
       or new.department_id is distinct from old.department_id
       or new.grade is distinct from old.grade
       or new.entry_academic_year is distinct from old.entry_academic_year
       or new.active_term_id is distinct from old.active_term_id
       or new.primary_calendar_id is distinct from old.primary_calendar_id
       or new.onboarding_status is distinct from old.onboarding_status
       or new.onboarding_step is distinct from old.onboarding_step
       or new.onboarding_completed_at is distinct from old.onboarding_completed_at
       or new.created_at is distinct from old.created_at
       or new.deleted_at is distinct from old.deleted_at
       or new.version is distinct from old.version then
      raise exception 'profile onboarding fields are server-managed' using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_guard_university_verified on public.profiles;
drop trigger if exists profiles_guard_server_managed_fields on public.profiles;
create trigger profiles_guard_server_managed_fields
before insert or update on public.profiles
for each row execute function public.guard_profile_server_managed_fields();

-- Any legacy boolean without a supporting verification record is untrusted.
update public.profiles p
set university_verified = false
where p.university_verified
  and not exists (
    select 1
    from public.university_email_verifications v
    where v.user_id = p.user_id
      and v.university_id = p.university_id
      and v.status = 'verified'
  );

-- ---------------------------------------------------------------------------
-- Auth-bound application RPCs
-- ---------------------------------------------------------------------------

create or replace function public.submit_university_request(
  p_name text,
  p_prefecture text default null,
  p_official_url text default null
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  caller_id uuid := auth.uid();
  clean_name text := btrim(coalesce(p_name, ''));
  clean_prefecture text := nullif(btrim(p_prefecture), '');
  clean_url text := nullif(btrim(p_official_url), '');
  normalized text;
  request_id uuid;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if char_length(clean_name) not between 2 and 120 then
    raise exception 'invalid university name' using errcode = '22023';
  end if;
  if clean_prefecture is not null and char_length(clean_prefecture) > 50 then
    raise exception 'invalid prefecture' using errcode = '22023';
  end if;
  if clean_url is not null
     and (char_length(clean_url) > 2048 or clean_url !~ '^https://') then
    raise exception 'official_url must be an HTTPS URL' using errcode = '22023';
  end if;

  normalized := public.normalize_course_text(clean_name);
  if normalized = '' then
    raise exception 'invalid university name' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.university_requests r
    where r.requested_by = caller_id
      and r.status = 'pending'
      and r.normalized_name = normalized
  ) then
    select r.id into request_id
    from public.university_requests r
    where r.requested_by = caller_id
      and r.status = 'pending'
      and r.normalized_name = normalized
    order by r.created_at
    limit 1;
    return request_id;
  end if;

  if (
    select count(*)
    from public.university_requests r
    where r.requested_by = caller_id
      and r.status = 'pending'
  ) >= 3 then
    raise exception 'too many pending university requests' using errcode = '22023';
  end if;

  insert into public.university_requests (
    requested_by,
    name,
    normalized_name,
    prefecture,
    official_url
  )
  values (caller_id, clean_name, normalized, clean_prefecture, clean_url)
  returning id into request_id;

  return request_id;
end;
$$;

create or replace function public.change_university(p_university_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  caller_id uuid := auth.uid();
  current_university_id uuid;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.universities u
    where u.id = p_university_id
      and u.status = 'active'
      and u.deleted_at is null
  ) then
    raise exception 'university is not active' using errcode = '22023';
  end if;

  select p.university_id into current_university_id
  from public.profiles p
  where p.user_id = caller_id
  for update;

  if not found then
    raise exception 'profile not found' using errcode = 'P0002';
  end if;

  if current_university_id is not distinct from p_university_id then
    return;
  end if;

  update private.university_email_verification_challenges c
  set invalidated_at = coalesce(c.invalidated_at, now()),
      invalidation_reason = coalesce(c.invalidation_reason, 'university_changed')
  where c.user_id = caller_id
    and c.consumed_at is null
    and c.invalidated_at is null;

  update public.university_email_verifications v
  set status = 'revoked',
      revoked_at = now()
  where v.user_id = caller_id
    and v.status <> 'revoked';

  update public.profiles
  set university_id = p_university_id,
      campus_id = null,
      faculty_id = null,
      department_id = null,
      grade = null,
      entry_academic_year = null,
      active_term_id = null,
      university_verified = false,
      onboarding_status = 'in_progress',
      onboarding_step = 'university',
      onboarding_completed_at = null
  where user_id = caller_id;
end;
$$;

create or replace function public.complete_onboarding(
  p_idempotency_key uuid,
  p_user_type text,
  p_university_id uuid,
  p_campus_id uuid default null,
  p_faculty_id uuid default null,
  p_department_id uuid default null,
  p_entry_academic_year int default null,
  p_term_template_id uuid default null,
  p_custom_term_name text default null,
  p_custom_academic_year int default null,
  p_custom_start_date date default null,
  p_custom_end_date date default null,
  p_custom_term_type text default null,
  p_period_template_set_id uuid default null,
  p_custom_periods jsonb default null
)
returns table (term_id uuid, calendar_id uuid)
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  caller_id uuid := auth.uid();
  locked_profile public.profiles%rowtype;
  source_term public.terms%rowtype;
  existing_request private.onboarding_idempotency%rowtype;
  has_existing_request boolean := false;
  canonical_custom_periods jsonb;
  normalized_periods jsonb;
  request_payload jsonb;
  request_hash_value text;
  selected_academic_year int;
  new_term_id uuid;
  selected_calendar_id uuid;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_idempotency_key is null then
    raise exception 'idempotency key is required' using errcode = '22023';
  end if;

  select p.* into locked_profile
  from public.profiles p
  where p.user_id = caller_id
  for update;
  if not found then
    raise exception 'profile not found' using errcode = 'P0002';
  end if;

  -- Fingerprint only canonical caller-supplied selectors and custom rows.
  -- Resolved catalog rows are mutable configuration and must not change the
  -- identity of a request that has already committed successfully.
  if jsonb_typeof(p_custom_periods) = 'array' then
    select coalesce(
      jsonb_agg(item.value order by item.value::text),
      '[]'::jsonb
    ) into canonical_custom_periods
    from jsonb_array_elements(p_custom_periods) as item(value);
  else
    canonical_custom_periods := p_custom_periods;
  end if;

  request_payload := jsonb_build_object(
    'user_type', p_user_type,
    'university_id', p_university_id,
    'campus_id', p_campus_id,
    'faculty_id', p_faculty_id,
    'department_id', p_department_id,
    'entry_academic_year', p_entry_academic_year,
    'term_template_id', p_term_template_id,
    'custom_term_name', nullif(btrim(p_custom_term_name), ''),
    'custom_academic_year', p_custom_academic_year,
    'custom_start_date', p_custom_start_date,
    'custom_end_date', p_custom_end_date,
    'custom_term_type', p_custom_term_type,
    'period_template_set_id', p_period_template_set_id,
    'custom_periods', canonical_custom_periods
  );
  request_hash_value := encode(
    extensions.digest(convert_to(request_payload::text, 'UTF8'), 'sha256'),
    'hex'
  );

  select i.* into existing_request
  from private.onboarding_idempotency i
  where i.user_id = caller_id
    and i.idempotency_key = p_idempotency_key;
  has_existing_request := found;

  if has_existing_request then
    if existing_request.request_hash <> request_hash_value then
      raise exception 'idempotency key was reused with a different payload' using errcode = '23505';
    end if;
    if locked_profile.university_id is not null
       and locked_profile.university_id is distinct from p_university_id then
      raise exception 'change_university must be called first' using errcode = '22023';
    end if;
    return query select existing_request.term_id, existing_request.calendar_id;
    return;
  end if;

  -- A completed profile may only replay the request that completed it. Reject
  -- a new key before request/catalog validation so it cannot start setup twice.
  if not has_existing_request
     and locked_profile.onboarding_status = 'complete' then
    raise exception 'onboarding is already complete' using errcode = '22023';
  end if;

  if p_user_type not in ('undergraduate', 'graduate', 'other') then
    raise exception 'invalid user type' using errcode = '22023';
  end if;
  if p_entry_academic_year is not null
     and p_entry_academic_year not between 1900 and 2200 then
    raise exception 'invalid entry academic year' using errcode = '22023';
  end if;

  if locked_profile.university_id is not null
     and locked_profile.university_id is distinct from p_university_id then
    raise exception 'change_university must be called first' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.universities u
    where u.id = p_university_id
      and u.status = 'active'
      and u.deleted_at is null
  ) then
    raise exception 'university is not active' using errcode = '22023';
  end if;

  if p_campus_id is not null and not exists (
    select 1 from public.campuses c
    where c.id = p_campus_id
      and c.university_id = p_university_id
      and c.status = 'active'
      and c.deleted_at is null
  ) then
    raise exception 'campus does not belong to university' using errcode = '22023';
  end if;
  if p_faculty_id is not null and not exists (
    select 1 from public.faculties f
    where f.id = p_faculty_id
      and f.university_id = p_university_id
      and f.status = 'active'
      and f.deleted_at is null
  ) then
    raise exception 'faculty does not belong to university' using errcode = '22023';
  end if;
  if p_department_id is not null and (
    p_faculty_id is null or not exists (
      select 1 from public.departments d
      where d.id = p_department_id
        and d.faculty_id = p_faculty_id
        and d.university_id = p_university_id
        and d.status = 'active'
        and d.deleted_at is null
    )
  ) then
    raise exception 'department does not belong to faculty' using errcode = '22023';
  end if;

  if p_term_template_id is not null then
    if p_custom_term_name is not null
       or p_custom_academic_year is not null
       or p_custom_start_date is not null
       or p_custom_end_date is not null
       or p_custom_term_type is not null then
      raise exception 'choose a term template or a custom term, not both' using errcode = '22023';
    end if;

    select t.* into source_term
    from public.terms t
    where t.id = p_term_template_id
      and t.university_id = p_university_id
      and t.is_template
      and t.status = 'active'
      and t.deleted_at is null;
    if not found then
      raise exception 'term template is not available' using errcode = '22023';
    end if;
    selected_academic_year := source_term.academic_year;
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
       or p_custom_term_type not in ('semester', 'quarter', 'custom', 'intensive', 'year_round')
       or char_length(btrim(p_custom_term_name)) > 100 then
      raise exception 'invalid custom term' using errcode = '22023';
    end if;
    selected_academic_year := p_custom_academic_year;
  end if;

  if (p_period_template_set_id is null) = (p_custom_periods is null) then
    raise exception 'choose a period template set or custom periods, not both' using errcode = '22023';
  end if;

  if p_period_template_set_id is not null then
    if not exists (
      select 1
      from public.period_template_sets s
      where s.id = p_period_template_set_id
        and s.university_id = p_university_id
        and s.status = 'active'
        and s.deleted_at is null
        and (s.academic_year is null or s.academic_year = selected_academic_year)
        and (s.user_type is null or s.user_type = p_user_type)
        and (s.campus_id is null or s.campus_id = p_campus_id)
    ) then
      raise exception 'period template set is not available' using errcode = '22023';
    end if;

    select jsonb_agg(
      jsonb_build_object(
        'day_of_week', pt.day_of_week,
        'period_no', pt.period_no,
        'start_time', pt.start_time::text,
        'end_time', pt.end_time::text
      ) order by pt.day_of_week, pt.period_no
    ) into normalized_periods
    from public.period_templates pt
    where pt.template_set_id = p_period_template_set_id
      and pt.deleted_at is null;
  else
    if jsonb_typeof(p_custom_periods) <> 'array' then
      raise exception 'custom periods must be an array' using errcode = '22023';
    end if;

    select jsonb_agg(
      jsonb_build_object(
        'day_of_week', x.day_of_week,
        'period_no', x.period_no,
        'start_time', x.start_time::text,
        'end_time', x.end_time::text
      ) order by x.day_of_week, x.period_no
    ) into normalized_periods
    from jsonb_to_recordset(p_custom_periods) as x(
      day_of_week int,
      period_no int,
      start_time time,
      end_time time
    );
  end if;

  if normalized_periods is null
     or jsonb_array_length(normalized_periods) not between 1 and 63 then
    raise exception 'period list must contain between 1 and 63 rows' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(normalized_periods) as x(
      day_of_week int,
      period_no int,
      start_time time,
      end_time time
    )
    where x.day_of_week not between 1 and 7
       or x.period_no not between 1 and 9
       or x.start_time is null
       or x.end_time is null
       or x.end_time <= x.start_time
  ) then
    raise exception 'invalid period row' using errcode = '22023';
  end if;

  if (
    select count(*)
    from jsonb_to_recordset(normalized_periods) as x(
      day_of_week int,
      period_no int,
      start_time time,
      end_time time
    )
  ) <> (
    select count(distinct (x.day_of_week, x.period_no))
    from jsonb_to_recordset(normalized_periods) as x(
      day_of_week int,
      period_no int,
      start_time time,
      end_time time
    )
  ) then
    raise exception 'duplicate period slot' using errcode = '22023';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(normalized_periods) as a(
      day_of_week int,
      period_no int,
      start_time time,
      end_time time
    )
    join jsonb_to_recordset(normalized_periods) as b(
      day_of_week int,
      period_no int,
      start_time time,
      end_time time
    )
      on a.day_of_week = b.day_of_week
     and a.period_no < b.period_no
     and a.start_time < b.end_time
     and b.start_time < a.end_time
  ) then
    raise exception 'period times overlap' using errcode = '22023';
  end if;

  if p_term_template_id is not null then
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
      is_template
    ) values (
      p_university_id,
      source_term.name,
      source_term.academic_year,
      source_term.start_date,
      source_term.end_date,
      source_term.instruction_start_date,
      source_term.instruction_end_date,
      source_term.term_type,
      caller_id,
      caller_id,
      source_term.id,
      false
    ) returning id into new_term_id;
  else
    insert into public.terms (
      university_id,
      name,
      academic_year,
      start_date,
      end_date,
      term_type,
      created_by,
      owner_user_id,
      is_template
    ) values (
      p_university_id,
      btrim(p_custom_term_name),
      p_custom_academic_year,
      p_custom_start_date,
      p_custom_end_date,
      p_custom_term_type,
      caller_id,
      caller_id,
      false
    ) returning id into new_term_id;
  end if;

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
    p_university_id,
    new_term_id,
    p_period_template_set_id,
    x.day_of_week,
    x.period_no,
    x.start_time,
    x.end_time,
    false
  from jsonb_to_recordset(normalized_periods) as x(
    day_of_week int,
    period_no int,
    start_time time,
    end_time time
  );

  selected_calendar_id := locked_profile.primary_calendar_id;
  if selected_calendar_id is null or not exists (
    select 1 from public.calendars c
    where c.id = selected_calendar_id
      and c.owner_user_id = caller_id
      and c.group_id is null
      and c.deleted_at is null
  ) then
    select c.id into selected_calendar_id
    from public.calendars c
    where c.owner_user_id = caller_id
      and c.group_id is null
      and c.deleted_at is null
    order by c.created_at, c.id
    limit 1;

    if selected_calendar_id is null then
      insert into public.calendars (
        owner_user_id,
        name,
        default_visibility
      ) values (caller_id, 'マイカレンダー', 'PRIVATE')
      returning id into selected_calendar_id;
    end if;
  end if;

  insert into public.notification_settings (user_id)
  values (caller_id)
  on conflict (user_id) do nothing;

  update public.profiles p
  set user_type = p_user_type,
      university_id = p_university_id,
      campus_id = p_campus_id,
      faculty_id = p_faculty_id,
      department_id = p_department_id,
      entry_academic_year = p_entry_academic_year,
      active_term_id = new_term_id,
      primary_calendar_id = selected_calendar_id,
      university_verified = exists (
        select 1
        from public.university_email_verifications v
        where v.user_id = caller_id
          and v.university_id = p_university_id
          and v.status = 'verified'
      ),
      onboarding_status = 'complete',
      onboarding_step = 'complete',
      onboarding_completed_at = now()
  where p.user_id = caller_id;

  insert into private.onboarding_idempotency (
    user_id,
    idempotency_key,
    request_hash,
    term_id,
    calendar_id
  ) values (
    caller_id,
    p_idempotency_key,
    request_hash_value,
    new_term_id,
    selected_calendar_id
  );

  return query select new_term_id, selected_calendar_id;
end;
$$;

create or replace function public.request_university_email_verification(
  p_university_id uuid,
  p_domain_rule_id uuid
)
returns table (request_id uuid, status text)
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  caller_id uuid := auth.uid();
  caller_profile public.profiles%rowtype;
  new_request_id uuid := gen_random_uuid();
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select p.* into caller_profile
  from public.profiles p
  where p.user_id = caller_id
  for update;
  if not found then
    raise exception 'profile not found' using errcode = 'P0002';
  end if;
  if caller_profile.university_id is distinct from p_university_id then
    raise exception 'verification university must match profile' using errcode = '22023';
  end if;
  if caller_profile.entry_academic_year is null then
    raise exception 'entry academic year is required' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.university_domains d
    join public.universities u on u.id = d.university_id
    where d.id = p_domain_rule_id
      and d.university_id = p_university_id
      and d.kind = 'student_email'
      and d.verification_enabled
      and not d.match_subdomains
      and d.status = 'active'
      and d.deleted_at is null
      and u.status = 'active'
      and u.deleted_at is null
      and (d.cohort_start_academic_year is null or caller_profile.entry_academic_year >= d.cohort_start_academic_year)
      and (d.cohort_end_academic_year is null or caller_profile.entry_academic_year <= d.cohort_end_academic_year)
      and (d.effective_from is null or current_date >= d.effective_from)
      and (d.effective_to is null or current_date <= d.effective_to)
  ) then
    raise exception 'email domain rule is not eligible' using errcode = '22023';
  end if;

  update private.university_email_verification_challenges c
  set invalidated_at = coalesce(c.invalidated_at, now()),
      invalidation_reason = coalesce(c.invalidation_reason, 'superseded')
  where c.user_id = caller_id
    and c.university_id = p_university_id
    and c.consumed_at is null
    and c.invalidated_at is null;

  insert into public.university_email_verifications (
    user_id, university_id, domain_rule_id, request_id, status,
    requested_at, verified_at, revoked_at
  ) values (
    caller_id, p_university_id, p_domain_rule_id, new_request_id,
    'pending', now(), null, null
  )
  on conflict (user_id, university_id) do update
  set domain_rule_id = excluded.domain_rule_id,
      request_id = excluded.request_id,
      status = 'pending',
      requested_at = excluded.requested_at,
      verified_at = null,
      revoked_at = null;

  update public.profiles
  set university_verified = false
  where user_id = caller_id;

  return query select new_request_id, 'pending'::text;
end;
$$;

create or replace function public.issue_university_email_verification_challenge(
  p_request_id uuid,
  p_user_id uuid,
  p_email_hmac text,
  p_challenge_hmac text,
  p_expires_at timestamptz
)
returns table (challenge_id uuid, expires_at timestamptz)
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  verification_row public.university_email_verifications%rowtype;
  new_challenge_id uuid;
begin
  if p_email_hmac !~ '^[0-9a-f]{64}$' or p_challenge_hmac !~ '^[0-9a-f]{64}$' then
    raise exception 'verification HMAC values must be lowercase SHA-256 hex' using errcode = '22023';
  end if;
  if p_expires_at <= now() + interval '1 minute'
     or p_expires_at > now() + interval '30 minutes' then
    raise exception 'invalid challenge expiry' using errcode = '22023';
  end if;

  select v.* into verification_row
  from public.university_email_verifications v
  where v.request_id = p_request_id
    and v.user_id = p_user_id
    and v.status = 'pending'
  for update;
  if not found then
    raise exception 'verification request is not pending' using errcode = '22023';
  end if;

  update private.university_email_verification_challenges c
  set invalidated_at = coalesce(c.invalidated_at, now()),
      invalidation_reason = coalesce(c.invalidation_reason, 'superseded')
  where c.request_id = p_request_id
    and c.consumed_at is null
    and c.invalidated_at is null;

  insert into private.university_email_verification_challenges (
    request_id, user_id, university_id, email_hmac, challenge_hmac, expires_at
  ) values (
    p_request_id, p_user_id, verification_row.university_id,
    p_email_hmac, p_challenge_hmac, p_expires_at
  ) returning id into new_challenge_id;

  return query select new_challenge_id, p_expires_at;
end;
$$;

create or replace function public.complete_university_email_verification(
  p_request_id uuid,
  p_user_id uuid,
  p_challenge_hmac text
)
returns table (result text, attempts_remaining int, verified_at timestamptz)
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  verification_row public.university_email_verifications%rowtype;
  challenge_row private.university_email_verification_challenges%rowtype;
  now_value timestamptz := now();
  remaining int;
begin
  if p_challenge_hmac !~ '^[0-9a-f]{64}$' then
    return query select 'invalid_request'::text, 0, null::timestamptz;
    return;
  end if;

  select v.* into verification_row
  from public.university_email_verifications v
  where v.request_id = p_request_id
    and v.user_id = p_user_id
    and v.status = 'pending'
  for update;
  if not found then
    return query select 'invalid_request'::text, 0, null::timestamptz;
    return;
  end if;

  select c.* into challenge_row
  from private.university_email_verification_challenges c
  where c.request_id = p_request_id
    and c.user_id = p_user_id
    and c.consumed_at is null
    and c.invalidated_at is null
  order by c.created_at desc
  limit 1
  for update;
  if not found then
    return query select 'invalid_request'::text, 0, null::timestamptz;
    return;
  end if;

  if not exists (
    select 1
    from public.profiles p
    join public.university_domains d
      on d.id = verification_row.domain_rule_id
     and d.university_id = verification_row.university_id
    where p.user_id = p_user_id
      and p.university_id = verification_row.university_id
      and p.entry_academic_year is not null
      and d.status = 'active'
      and d.verification_enabled
      and d.deleted_at is null
      and (d.cohort_start_academic_year is null or p.entry_academic_year >= d.cohort_start_academic_year)
      and (d.cohort_end_academic_year is null or p.entry_academic_year <= d.cohort_end_academic_year)
  ) then
    update private.university_email_verification_challenges
    set invalidated_at = now_value, invalidation_reason = 'university_changed'
    where id = challenge_row.id;
    update public.university_email_verifications
    set status = 'revoked', revoked_at = now_value
    where request_id = p_request_id;
    update public.profiles set university_verified = false where user_id = p_user_id;
    return query select 'invalid_request'::text, 0, null::timestamptz;
    return;
  end if;

  if challenge_row.expires_at <= now_value then
    update private.university_email_verification_challenges
    set invalidated_at = now_value, invalidation_reason = 'expired'
    where id = challenge_row.id;
    update public.university_email_verifications set status = 'expired'
    where request_id = p_request_id;
    return query select 'expired'::text, 0, null::timestamptz;
    return;
  end if;

  if challenge_row.attempt_count >= challenge_row.max_attempts then
    return query select 'locked'::text, 0, null::timestamptz;
    return;
  end if;

  remaining := challenge_row.max_attempts - challenge_row.attempt_count - 1;
  if challenge_row.challenge_hmac <> p_challenge_hmac then
    update private.university_email_verification_challenges
    set attempt_count = attempt_count + 1,
        last_attempt_at = now_value,
        invalidated_at = case when remaining = 0 then now_value else invalidated_at end,
        invalidation_reason = case when remaining = 0 then 'attempts_exhausted' else invalidation_reason end
    where id = challenge_row.id;
    if remaining = 0 then
      update public.university_email_verifications set status = 'failed'
      where request_id = p_request_id;
      return query select 'locked'::text, 0, null::timestamptz;
    else
      return query select 'invalid_code'::text, remaining, null::timestamptz;
    end if;
    return;
  end if;

  update private.university_email_verification_challenges
  set attempt_count = attempt_count + 1,
      last_attempt_at = now_value,
      consumed_at = now_value
  where id = challenge_row.id;
  update public.university_email_verifications
  set status = 'verified', verified_at = now_value, revoked_at = null
  where request_id = p_request_id;
  update public.profiles
  set university_verified = true
  where user_id = p_user_id
    and university_id = verification_row.university_id;

  return query select 'verified'::text, remaining, now_value;
end;
$$;

create or replace function public.invalidate_university_email_verification(
  p_request_id uuid,
  p_user_id uuid,
  p_reason text
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  affected boolean;
begin
  if p_reason not in ('cancelled', 'delivery_failed', 'superseded', 'university_changed') then
    raise exception 'invalid invalidation reason' using errcode = '22023';
  end if;

  update private.university_email_verification_challenges c
  set invalidated_at = coalesce(c.invalidated_at, now()),
      invalidation_reason = coalesce(c.invalidation_reason, p_reason)
  where c.request_id = p_request_id
    and c.user_id = p_user_id
    and c.consumed_at is null
    and c.invalidated_at is null;

  update public.university_email_verifications v
  set status = case when p_reason = 'delivery_failed' then 'failed' else 'revoked' end,
      revoked_at = case when p_reason = 'delivery_failed' then null else now() end
  where v.request_id = p_request_id
    and v.user_id = p_user_id
    and v.status <> 'verified';
  affected := found;

  if affected then
    update public.profiles p
    set university_verified = false
    where p.user_id = p_user_id
      and p.university_id = (
        select v.university_id
        from public.university_email_verifications v
        where v.request_id = p_request_id
      );
  end if;
  return affected;
end;
$$;

-- ---------------------------------------------------------------------------
-- RLS and explicit Data API grants
-- ---------------------------------------------------------------------------

drop policy if exists universities_read_active on public.universities;
create policy universities_read_active on public.universities
  for select to authenticated
  using (status = 'active' and deleted_at is null);
create policy campuses_read_active on public.campuses
  for select to authenticated using (status = 'active' and deleted_at is null);
create policy faculties_read_active on public.faculties
  for select to authenticated using (status = 'active' and deleted_at is null);
create policy departments_read_active on public.departments
  for select to authenticated using (status = 'active' and deleted_at is null);
create policy university_domains_read_active on public.university_domains
  for select to authenticated using (status = 'active' and deleted_at is null);

drop policy if exists profiles_insert_self on public.profiles;
drop policy if exists profiles_read_self on public.profiles;
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_read_self on public.profiles
  for select to authenticated using (user_id = (select auth.uid()));
create policy profiles_update_self on public.profiles
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists university_requests_insert_self on public.university_requests;
drop policy if exists university_requests_read_self on public.university_requests;
create policy university_requests_read_self on public.university_requests
  for select to authenticated using (requested_by = (select auth.uid()));

drop policy if exists terms_read_same_university on public.terms;
create policy terms_read_catalog_or_owner on public.terms
  for select to authenticated
  using (
    (is_template and status = 'active' and deleted_at is null)
    or (not is_template and owner_user_id = (select auth.uid()))
  );

drop policy if exists period_settings_read_owner_or_university on public.period_settings;
drop policy if exists period_settings_write_owner on public.period_settings;
create policy period_settings_read_owner on public.period_settings
  for select to authenticated using (owner_user_id = (select auth.uid()));

create policy period_template_sets_read_active on public.period_template_sets
  for select to authenticated using (status = 'active' and deleted_at is null);
create policy period_templates_read_active on public.period_templates
  for select to authenticated
  using (
    deleted_at is null
    and exists (
      select 1 from public.period_template_sets s
      where s.id = period_templates.template_set_id
        and s.status = 'active'
        and s.deleted_at is null
    )
  );
create policy university_email_verifications_read_self
  on public.university_email_verifications
  for select to authenticated using (user_id = (select auth.uid()));

revoke all on table public.universities from anon, authenticated;
revoke all on table public.campuses from anon, authenticated;
revoke all on table public.faculties from anon, authenticated;
revoke all on table public.departments from anon, authenticated;
revoke all on table public.university_domains from anon, authenticated;
revoke all on table public.profiles from anon, authenticated;
revoke all on table public.university_requests from anon, authenticated;
revoke all on table public.terms from anon, authenticated;
revoke all on table public.period_template_sets from anon, authenticated;
revoke all on table public.period_templates from anon, authenticated;
revoke all on table public.period_settings from anon, authenticated;
revoke all on table public.university_email_verifications from anon, authenticated;
revoke all on table private.university_email_verification_challenges
  from public, anon, authenticated, service_role;
revoke all on table private.onboarding_idempotency
  from public, anon, authenticated, service_role;

grant select on table public.universities, public.campuses,
  public.faculties, public.departments, public.university_domains,
  public.university_requests, public.terms, public.period_template_sets,
  public.period_templates, public.period_settings,
  public.university_email_verifications to authenticated;
grant select, update on table public.profiles to authenticated;

-- The verification Edge Function resolves only an opaque request and its
-- allow-listed domain rule before calling the trusted RPCs. It cannot read
-- profiles, challenge rows, or any email-derived material through Table API.
grant select (request_id, user_id, domain_rule_id, status)
  on table public.university_email_verifications to service_role;
grant select (id, domain, kind, match_subdomains, verification_enabled)
  on table public.university_domains to service_role;

revoke execute on function public.submit_university_request(text, text, text)
  from public, anon;
revoke execute on function public.change_university(uuid)
  from public, anon;
revoke execute on function public.complete_onboarding(uuid, text, uuid, uuid, uuid, uuid, integer, uuid, text, integer, date, date, text, uuid, jsonb)
  from public, anon;
revoke execute on function public.request_university_email_verification(uuid, uuid)
  from public, anon;
grant execute on function public.submit_university_request(text, text, text)
  to authenticated;
grant execute on function public.change_university(uuid)
  to authenticated;
grant execute on function public.complete_onboarding(uuid, text, uuid, uuid, uuid, uuid, integer, uuid, text, integer, date, date, text, uuid, jsonb)
  to authenticated;
grant execute on function public.request_university_email_verification(uuid, uuid)
  to authenticated;

revoke execute on function public.issue_university_email_verification_challenge(uuid, uuid, text, text, timestamptz)
  from public, anon, authenticated;
revoke execute on function public.complete_university_email_verification(uuid, uuid, text)
  from public, anon, authenticated;
revoke execute on function public.invalidate_university_email_verification(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.issue_university_email_verification_challenge(uuid, uuid, text, text, timestamptz)
  to service_role;
grant execute on function public.complete_university_email_verification(uuid, uuid, text)
  to service_role;
grant execute on function public.invalidate_university_email_verification(uuid, uuid, text)
  to service_role;

revoke execute on function private.handle_new_user()
  from public, anon, authenticated, service_role;
revoke execute on function public.guard_profile_server_managed_fields()
  from public, anon, authenticated, service_role;
revoke execute on function public.guard_profile_university_verified()
  from public, anon, authenticated, service_role;

commit;
