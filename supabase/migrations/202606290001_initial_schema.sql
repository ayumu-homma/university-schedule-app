-- University schedule app MVP schema.
-- Safe for Supabase local reset. Do not expose service_role keys to clients.

create extension if not exists pgcrypto;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_trgm') then
    execute 'create extension if not exists pg_trgm';
  end if;
  if exists (select 1 from pg_available_extensions where name = 'fuzzystrmatch') then
    execute 'create extension if not exists fuzzystrmatch';
  end if;
end $$;

do $$
begin
  create type visibility_level as enum ('PRIVATE', 'BUSY_ONLY', 'TITLE_ONLY', 'FULL');
exception when duplicate_object then null;
end $$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  if to_jsonb(new) ? 'version' then
    new.version = coalesce(old.version, 0) + 1;
  end if;
  return new;
end;
$$;

create or replace function public.normalize_course_text(input text)
returns text
language sql
immutable
as $$
  select lower(
    regexp_replace(
      translate(
        coalesce(input, ''),
        '　ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ１２３４５６７８９０ⅠⅡⅢⅣⅤ',
        ' ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz123456789012345'
      ),
      '[[:space:]（）()\[\]【】「」『』:：,，.．・_/\\-]+',
      '',
      'g'
    )
  );
$$;

create table public.universities (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  normalized_name text not null unique,
  aliases text[] not null default '{}',
  prefecture text,
  domain_hints text[] not null default '{}',
  status text not null default 'active' check (status in ('active','hidden','merged')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  username text unique,
  avatar_url text,
  user_type text not null default 'undergraduate' check (user_type in ('undergraduate','graduate','other')),
  university_id uuid references public.universities(id),
  grade int,
  university_verified boolean not null default false,
  searchable_by_username boolean not null default false,
  default_visibility visibility_level not null default 'PRIVATE',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.university_requests (
  id uuid primary key default gen_random_uuid(),
  requested_by uuid not null references auth.users(id),
  name text not null,
  normalized_name text not null,
  prefecture text,
  official_url text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','merged')),
  resolved_by uuid references auth.users(id),
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.terms (
  id uuid primary key default gen_random_uuid(),
  university_id uuid references public.universities(id),
  name text not null,
  academic_year int not null,
  start_date date not null,
  end_date date not null,
  term_type text not null check (term_type in ('semester','quarter','custom','intensive','year_round')),
  created_by uuid references auth.users(id),
  is_template boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.period_settings (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid references auth.users(id),
  university_id uuid references public.universities(id),
  day_of_week int not null check (day_of_week between 1 and 7),
  period_no int not null check (period_no between 1 and 9),
  start_time time not null,
  end_time time not null,
  is_template boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(owner_user_id, university_id, day_of_week, period_no)
);

create table public.course_templates (
  id uuid primary key default gen_random_uuid(),
  university_id uuid not null references public.universities(id),
  academic_year int not null,
  term_id uuid references public.terms(id),
  title text not null,
  normalized_title text not null,
  instructor_name text,
  normalized_instructor_name text,
  day_of_week int check (day_of_week between 1 and 7),
  period_no int check (period_no between 1 and 9),
  room text,
  normalized_room text,
  credit_count numeric,
  syllabus_url text,
  external_course_code text,
  created_by uuid references auth.users(id),
  visibility text not null default 'UNIVERSITY' check (visibility in ('UNIVERSITY')),
  status text not null default 'active' check (status in ('active','hidden','merged','deleted')),
  canonical_template_id uuid references public.course_templates(id),
  copy_count_total int not null default 0,
  copy_count_term int not null default 0,
  report_count int not null default 0,
  trust_score numeric not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1
);

create table public.course_template_copy_events (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.course_templates(id),
  copied_by uuid not null references auth.users(id),
  user_course_id uuid,
  created_at timestamptz not null default now()
);

create table public.course_template_duplicate_candidates (
  id uuid primary key default gen_random_uuid(),
  university_id uuid not null references public.universities(id),
  template_a_id uuid not null references public.course_templates(id),
  template_b_id uuid not null references public.course_templates(id),
  score numeric not null,
  status text not null default 'pending' check (status in ('pending','confirmed','rejected','merged')),
  created_at timestamptz not null default now(),
  unique(template_a_id, template_b_id)
);

create table public.course_template_edit_proposals (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.course_templates(id),
  proposed_by uuid not null references auth.users(id),
  proposed_payload jsonb not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.course_template_reports (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.course_templates(id),
  reported_by uuid not null references auth.users(id),
  reason text not null,
  status text not null default 'pending' check (status in ('pending','reviewed','dismissed','actioned')),
  created_at timestamptz not null default now()
);

create table public.user_courses (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id),
  term_id uuid references public.terms(id),
  source_template_id uuid references public.course_templates(id),
  title text not null,
  normalized_title text not null,
  instructor_name text,
  normalized_instructor_name text,
  day_of_week int check (day_of_week between 1 and 7),
  period_no int check (period_no between 1 and 9),
  room text,
  normalized_room text,
  credit_count numeric,
  syllabus_url text,
  color text,
  visibility_level visibility_level not null default 'PRIVATE',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1
);

create table public.assignments (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id),
  course_id uuid references public.user_courses(id),
  title text not null,
  description text,
  submission_url text,
  due_at timestamptz not null,
  visibility_level visibility_level not null default 'PRIVATE',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1
);

create table public.assignment_user_states (
  assignment_id uuid not null references public.assignments(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  status text not null default 'notStarted' check (status in ('notStarted','inProgress','submitted','overdue')),
  submitted_at timestamptz,
  note text,
  updated_at timestamptz not null default now(),
  primary key (assignment_id, user_id)
);

create table public.exams (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id),
  course_id uuid references public.user_courses(id),
  title text not null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  room text,
  scope text,
  visibility_level visibility_level not null default 'PRIVATE',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1
);

create table public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester_user_id uuid not null references auth.users(id),
  addressee_user_id uuid not null references auth.users(id),
  status text not null default 'pending' check (status in ('pending','accepted','rejected','blocked')),
  visibility_level visibility_level,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(requester_user_id, addressee_user_id),
  check (requester_user_id <> addressee_user_id)
);

create table public.groups (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id),
  name text not null,
  type text not null default 'other' check (type in ('friends','course','club','seminar','lab','part_time_job','other')),
  default_visibility visibility_level not null default 'TITLE_ONLY',
  event_create_policy text not null default 'member' check (event_create_policy in ('member','admin','owner')),
  invite_revoked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1
);

create table public.group_members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  role text not null default 'member' check (role in ('owner','admin','member')),
  visibility_level visibility_level,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

create table public.group_invitations (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id),
  token_hash text not null unique,
  created_by uuid not null references auth.users(id),
  expires_at timestamptz,
  max_uses int,
  used_count int not null default 0,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.calendars (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id),
  group_id uuid references public.groups(id),
  name text not null,
  default_visibility visibility_level not null default 'PRIVATE',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1
);

create table public.events (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id),
  calendar_id uuid not null references public.calendars(id),
  group_id uuid references public.groups(id),
  title text not null,
  kind text not null check (kind in ('normal','routine','course','assignment_deadline','exam','group')),
  start_at timestamptz not null,
  end_at timestamptz not null,
  is_all_day boolean not null default false,
  location text,
  description text,
  rrule text,
  timezone text not null default 'Asia/Tokyo',
  visibility_level visibility_level,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1,
  check (end_at > start_at)
);

create table public.event_exceptions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  recurrence_id timestamptz not null,
  mode text not null check (mode in ('cancelled','modified')),
  override_start_at timestamptz,
  override_end_at timestamptz,
  override_title text,
  override_location text,
  override_description text,
  override_visibility visibility_level,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(event_id, recurrence_id)
);

create table public.event_participants (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  status text not null default 'unanswered' check (status in ('attending','declined','tentative','unanswered')),
  updated_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

create table public.event_comments (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  author_user_id uuid not null references auth.users(id),
  body text not null check (char_length(body) <= 2000),
  report_count int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.event_reactions (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  reaction text not null check (reaction in ('ok','thanks','question','maybe','cannot')),
  updated_at timestamptz not null default now(),
  primary key (event_id, user_id, reaction)
);

create table public.notification_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  assignments_enabled boolean not null default true,
  exams_enabled boolean not null default true,
  events_enabled boolean not null default true,
  group_updates_enabled boolean not null default true,
  minutes_before_class int not null default 10,
  minutes_before_assignment int not null default 1440,
  updated_at timestamptz not null default now()
);

create table public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null check (platform in ('ios','android')),
  token_hash text not null,
  token_preview text,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique(user_id, token_hash)
);

create table public.widget_snapshots (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  payload jsonb not null,
  generated_at timestamptz not null default now()
);

create table public.blocks (
  blocker_user_id uuid not null references auth.users(id),
  blocked_user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (blocker_user_id, blocked_user_id)
);

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_user_id uuid not null references auth.users(id),
  target_type text not null check (target_type in ('user','group','event','comment','course_template')),
  target_id uuid not null,
  reason text not null,
  status text not null default 'pending' check (status in ('pending','reviewed','dismissed','actioned')),
  created_at timestamptz not null default now()
);

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references auth.users(id),
  action text not null,
  target_type text not null,
  target_id uuid,
  metadata jsonb not null default '{}',
  created_at timestamptz not null default now()
);

create index profiles_university_idx on public.profiles(university_id) where deleted_at is null;
create index course_templates_search_idx on public.course_templates(university_id, academic_year, term_id, day_of_week, period_no) where deleted_at is null;
create index course_templates_normalized_idx on public.course_templates(university_id, normalized_title, normalized_instructor_name);
create index user_courses_owner_term_idx on public.user_courses(owner_user_id, term_id, day_of_week, period_no) where deleted_at is null;
create index assignments_owner_due_idx on public.assignments(owner_user_id, due_at) where deleted_at is null;
create index exams_owner_start_idx on public.exams(owner_user_id, start_at) where deleted_at is null;
create index events_owner_range_idx on public.events(owner_user_id, start_at, end_at) where deleted_at is null;
create index events_calendar_range_idx on public.events(calendar_id, start_at, end_at) where deleted_at is null;
create index events_group_range_idx on public.events(group_id, start_at, end_at) where group_id is not null and deleted_at is null;
create index group_members_user_idx on public.group_members(user_id);
create index event_comments_event_idx on public.event_comments(event_id) where deleted_at is null;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_trgm') then
    execute 'create index if not exists course_templates_title_trgm_idx on public.course_templates using gin (normalized_title gin_trgm_ops)';
  end if;
end $$;

create trigger universities_updated_at before update on public.universities for each row execute function public.set_updated_at();
create trigger profiles_updated_at before update on public.profiles for each row execute function public.set_updated_at();
create trigger terms_updated_at before update on public.terms for each row execute function public.set_updated_at();
create trigger period_settings_updated_at before update on public.period_settings for each row execute function public.set_updated_at();
create trigger course_templates_updated_at before update on public.course_templates for each row execute function public.set_updated_at();
create trigger user_courses_updated_at before update on public.user_courses for each row execute function public.set_updated_at();
create trigger assignments_updated_at before update on public.assignments for each row execute function public.set_updated_at();
create trigger exams_updated_at before update on public.exams for each row execute function public.set_updated_at();
create trigger friendships_updated_at before update on public.friendships for each row execute function public.set_updated_at();
create trigger groups_updated_at before update on public.groups for each row execute function public.set_updated_at();
create trigger calendars_updated_at before update on public.calendars for each row execute function public.set_updated_at();
create trigger events_updated_at before update on public.events for each row execute function public.set_updated_at();
create trigger event_exceptions_updated_at before update on public.event_exceptions for each row execute function public.set_updated_at();
create trigger event_comments_updated_at before update on public.event_comments for each row execute function public.set_updated_at();

create or replace function public.is_group_member(target_group_id uuid, target_user_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.group_members gm
    join public.groups g on g.id = gm.group_id
    where gm.group_id = target_group_id
      and gm.user_id = target_user_id
      and g.deleted_at is null
  );
$$;

create or replace function public.is_group_admin(target_group_id uuid, target_user_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.group_members
    where group_id = target_group_id
      and user_id = target_user_id
      and role in ('owner','admin')
  );
$$;

create or replace function public.are_friends(user_a uuid, user_b uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.friendships
    where status = 'accepted'
      and (
        (requester_user_id = user_a and addressee_user_id = user_b)
        or (requester_user_id = user_b and addressee_user_id = user_a)
      )
  );
$$;

create or replace function public.is_blocked(user_a uuid, user_b uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from public.blocks
    where (blocker_user_id = user_a and blocked_user_id = user_b)
       or (blocker_user_id = user_b and blocked_user_id = user_a)
  );
$$;

create or replace function public.can_access_event(target_event_id uuid, target_user_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.events e
    where e.id = target_event_id
      and e.deleted_at is null
      and (
        e.owner_user_id = target_user_id
        or (e.group_id is not null and public.is_group_member(e.group_id, target_user_id))
      )
  );
$$;

create or replace function public.search_course_templates(
  query_text text,
  target_university_id uuid,
  target_academic_year int,
  target_term_id uuid default null,
  target_day_of_week int default null,
  target_period_no int default null,
  limit_count int default 20
)
returns table (
  id uuid,
  title text,
  instructor_name text,
  day_of_week int,
  period_no int,
  room text,
  copy_count_total int,
  copy_count_term int,
  duplicate_key text,
  rank_score numeric
)
language sql
security definer
set search_path = public
stable
as $$
  with caller as (
    select university_id from public.profiles where user_id = auth.uid()
  ),
  normalized as (
    select public.normalize_course_text(query_text) as q
  )
  select
    ct.id,
    ct.title,
    ct.instructor_name,
    ct.day_of_week,
    ct.period_no,
    ct.room,
    ct.copy_count_total,
    ct.copy_count_term,
    concat_ws(':', ct.normalized_title, ct.normalized_instructor_name, ct.day_of_week, ct.period_no) as duplicate_key,
    (
      case when n.q = '' then 0
           when ct.normalized_title like '%' || n.q || '%' then 1000
           else 0
      end
      + ct.copy_count_term * 10
      + ct.copy_count_total
      + ct.trust_score
      + case when target_day_of_week is not null and ct.day_of_week = target_day_of_week then 50 else 0 end
      + case when target_period_no is not null and ct.period_no = target_period_no then 50 else 0 end
    )::numeric as rank_score
  from public.course_templates ct
  cross join normalized n
  where ct.university_id = target_university_id
    and ct.university_id = (select university_id from caller)
    and ct.academic_year = target_academic_year
    and (target_term_id is null or ct.term_id = target_term_id)
    and (target_day_of_week is null or ct.day_of_week = target_day_of_week)
    and (target_period_no is null or ct.period_no = target_period_no)
    and ct.status = 'active'
    and ct.deleted_at is null
    and (n.q = '' or ct.normalized_title like '%' || n.q || '%' or ct.normalized_instructor_name like '%' || n.q || '%')
  order by rank_score desc, ct.copy_count_total desc
  limit limit_count;
$$;

create or replace function public.copy_course_template(template_id uuid, target_term_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  source_template public.course_templates%rowtype;
  caller_university_id uuid;
  new_course_id uuid;
begin
  select * into source_template
  from public.course_templates
  where id = template_id
    and status = 'active'
    and deleted_at is null;

  if not found then
    raise exception 'course template not found';
  end if;

  select university_id into caller_university_id
  from public.profiles
  where user_id = auth.uid();

  if caller_university_id is null or caller_university_id <> source_template.university_id then
    raise exception 'course template is not available for this university';
  end if;

  insert into public.user_courses (
    owner_user_id,
    term_id,
    source_template_id,
    title,
    normalized_title,
    instructor_name,
    normalized_instructor_name,
    day_of_week,
    period_no,
    room,
    normalized_room,
    credit_count,
    syllabus_url,
    visibility_level
  )
  values (
    auth.uid(),
    target_term_id,
    source_template.id,
    source_template.title,
    source_template.normalized_title,
    source_template.instructor_name,
    source_template.normalized_instructor_name,
    source_template.day_of_week,
    source_template.period_no,
    source_template.room,
    source_template.normalized_room,
    source_template.credit_count,
    source_template.syllabus_url,
    'PRIVATE'
  )
  returning id into new_course_id;

  update public.course_templates
  set copy_count_total = copy_count_total + 1,
      copy_count_term = copy_count_term + 1
  where id = source_template.id;

  insert into public.course_template_copy_events(template_id, copied_by, user_course_id)
  values (source_template.id, auth.uid(), new_course_id);

  return new_course_id;
end;
$$;

create or replace function public.get_visible_events(
  viewer_id uuid,
  range_start timestamptz,
  range_end timestamptz
)
returns table (
  event_id uuid,
  owner_user_id uuid,
  start_at timestamptz,
  end_at timestamptz,
  visibility_level visibility_level,
  title text,
  location text,
  description text,
  kind text,
  group_id uuid
)
language sql
security definer
set search_path = public
stable
as $$
  with resolved as (
    select
      e.*,
      case
        when e.owner_user_id = viewer_id then 'FULL'::visibility_level
        when public.is_blocked(viewer_id, e.owner_user_id) then 'PRIVATE'::visibility_level
        when e.visibility_level is not null then e.visibility_level
        when e.group_id is not null and public.is_group_member(e.group_id, viewer_id)
          then coalesce(gm.visibility_level, g.default_visibility)
        when public.are_friends(viewer_id, e.owner_user_id)
          then coalesce(f.visibility_level, p.default_visibility)
        else 'PRIVATE'::visibility_level
      end as resolved_visibility
    from public.events e
    join public.calendars c on c.id = e.calendar_id
    join public.profiles p on p.user_id = e.owner_user_id
    left join public.groups g on g.id = e.group_id
    left join public.group_members gm on gm.group_id = e.group_id and gm.user_id = viewer_id
    left join public.friendships f
      on f.status = 'accepted'
     and ((f.requester_user_id = viewer_id and f.addressee_user_id = e.owner_user_id)
       or (f.addressee_user_id = viewer_id and f.requester_user_id = e.owner_user_id))
    where e.deleted_at is null
      and e.start_at < range_end
      and e.end_at > range_start
  )
  select
    id,
    owner_user_id,
    start_at,
    end_at,
    resolved_visibility,
    case
      when resolved_visibility = 'BUSY_ONLY' then '予定あり'
      when resolved_visibility in ('TITLE_ONLY','FULL') then title
      else null
    end as title,
    case when resolved_visibility = 'FULL' then location else null end as location,
    case when resolved_visibility = 'FULL' then description else null end as description,
    case when resolved_visibility = 'FULL' then kind else null end as kind,
    case when resolved_visibility = 'FULL' then group_id else null end as group_id
  from resolved
  where resolved_visibility <> 'PRIVATE';
$$;

create or replace function public.find_free_windows(
  viewer_id uuid,
  member_ids uuid[],
  range_start timestamptz,
  range_end timestamptz,
  minimum_minutes int default 30
)
returns table (
  start_at timestamptz,
  end_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  with busy as (
    select greatest(ve.start_at, range_start) as start_at,
           least(ve.end_at, range_end) as end_at
    from unnest(member_ids) as m(member_id)
    join lateral public.get_visible_events(viewer_id, range_start, range_end) ve on ve.owner_user_id = m.member_id
    where ve.visibility_level <> 'PRIVATE'
  ),
  points as (
    select range_start as point
    union
    select range_end
    union
    select start_at from busy
    union
    select end_at from busy
  ),
  windows as (
    select point as start_at,
           lead(point) over (order by point) as end_at
    from points
  )
  select w.start_at, w.end_at
  from windows w
  where w.end_at is not null
    and extract(epoch from (w.end_at - w.start_at)) / 60 >= minimum_minutes
    and not exists (
      select 1 from busy b
      where b.start_at < w.end_at and b.end_at > w.start_at
    )
  order by w.start_at;
$$;

alter table public.universities enable row level security;
alter table public.profiles enable row level security;
alter table public.university_requests enable row level security;
alter table public.terms enable row level security;
alter table public.period_settings enable row level security;
alter table public.course_templates enable row level security;
alter table public.course_template_copy_events enable row level security;
alter table public.course_template_duplicate_candidates enable row level security;
alter table public.course_template_edit_proposals enable row level security;
alter table public.course_template_reports enable row level security;
alter table public.user_courses enable row level security;
alter table public.assignments enable row level security;
alter table public.assignment_user_states enable row level security;
alter table public.exams enable row level security;
alter table public.friendships enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.group_invitations enable row level security;
alter table public.calendars enable row level security;
alter table public.events enable row level security;
alter table public.event_exceptions enable row level security;
alter table public.event_participants enable row level security;
alter table public.event_comments enable row level security;
alter table public.event_reactions enable row level security;
alter table public.notification_settings enable row level security;
alter table public.device_tokens enable row level security;
alter table public.widget_snapshots enable row level security;
alter table public.blocks enable row level security;
alter table public.reports enable row level security;
alter table public.audit_logs enable row level security;

create policy universities_read_active on public.universities for select using (status = 'active');

create policy profiles_read_self_or_searchable on public.profiles
  for select using (user_id = auth.uid() or searchable_by_username = true);
create policy profiles_insert_self on public.profiles
  for insert with check (user_id = auth.uid());
create policy profiles_update_self on public.profiles
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy university_requests_insert_self on public.university_requests
  for insert with check (requested_by = auth.uid());
create policy university_requests_read_self on public.university_requests
  for select using (requested_by = auth.uid());

create policy terms_read_same_university on public.terms
  for select using (
    university_id is null
    or exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.university_id = terms.university_id)
  );

create policy period_settings_read_owner_or_university on public.period_settings
  for select using (
    owner_user_id = auth.uid()
    or exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.university_id = period_settings.university_id)
  );
create policy period_settings_write_owner on public.period_settings
  for all using (owner_user_id = auth.uid()) with check (owner_user_id = auth.uid());

create policy course_templates_read_same_university on public.course_templates
  for select using (
    deleted_at is null
    and status = 'active'
    and exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.university_id = course_templates.university_id)
  );
create policy course_templates_insert_same_university on public.course_templates
  for insert with check (
    created_by = auth.uid()
    and exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.university_id = course_templates.university_id)
  );

create policy course_template_copy_events_read_self on public.course_template_copy_events
  for select using (copied_by = auth.uid());

create policy course_template_edit_proposals_self on public.course_template_edit_proposals
  for all using (proposed_by = auth.uid()) with check (proposed_by = auth.uid());
create policy course_template_reports_self on public.course_template_reports
  for all using (reported_by = auth.uid()) with check (reported_by = auth.uid());

create policy owner_all_user_courses on public.user_courses
  for all using (owner_user_id = auth.uid()) with check (owner_user_id = auth.uid());
create policy owner_all_assignments on public.assignments
  for all using (owner_user_id = auth.uid()) with check (owner_user_id = auth.uid());
create policy assignment_state_self on public.assignment_user_states
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy owner_all_exams on public.exams
  for all using (owner_user_id = auth.uid()) with check (owner_user_id = auth.uid());

create policy friendships_party_read on public.friendships
  for select using (requester_user_id = auth.uid() or addressee_user_id = auth.uid());
create policy friendships_request on public.friendships
  for insert with check (requester_user_id = auth.uid());
create policy friendships_party_update on public.friendships
  for update using (requester_user_id = auth.uid() or addressee_user_id = auth.uid());

create policy groups_member_read on public.groups
  for select using (public.is_group_member(id, auth.uid()));
create policy groups_owner_insert on public.groups
  for insert with check (owner_user_id = auth.uid());
create policy groups_admin_update on public.groups
  for update using (public.is_group_admin(id, auth.uid()));

create policy group_members_member_read on public.group_members
  for select using (public.is_group_member(group_id, auth.uid()));
create policy group_members_admin_write on public.group_members
  for all using (
    public.is_group_admin(group_id, auth.uid())
    or exists (select 1 from public.groups g where g.id = group_members.group_id and g.owner_user_id = auth.uid())
  ) with check (
    public.is_group_admin(group_id, auth.uid())
    or exists (select 1 from public.groups g where g.id = group_members.group_id and g.owner_user_id = auth.uid())
  );

create policy group_invitations_member_read on public.group_invitations
  for select using (public.is_group_member(group_id, auth.uid()));
create policy group_invitations_admin_write on public.group_invitations
  for all using (public.is_group_admin(group_id, auth.uid())) with check (public.is_group_admin(group_id, auth.uid()));

create policy calendars_owner_or_group on public.calendars
  for select using (owner_user_id = auth.uid() or (group_id is not null and public.is_group_member(group_id, auth.uid())));
create policy calendars_owner_write on public.calendars
  for all using (owner_user_id = auth.uid()) with check (owner_user_id = auth.uid());

create policy events_owner_original_read on public.events
  for select using (owner_user_id = auth.uid());
create policy events_owner_or_group_write on public.events
  for all using (
    owner_user_id = auth.uid()
    or (group_id is not null and public.is_group_member(group_id, auth.uid()))
  ) with check (
    owner_user_id = auth.uid()
    or (group_id is not null and public.is_group_member(group_id, auth.uid()))
  );

create policy event_exceptions_event_writer on public.event_exceptions
  for all using (
    public.can_access_event(event_exceptions.event_id, auth.uid())
  ) with check (
    public.can_access_event(event_exceptions.event_id, auth.uid())
  );

create policy event_participants_visible_members on public.event_participants
  for select using (
    user_id = auth.uid()
    or public.can_access_event(event_participants.event_id, auth.uid())
  );
create policy event_participants_self_write on public.event_participants
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy event_comments_group_read on public.event_comments
  for select using (
    public.can_access_event(event_comments.event_id, auth.uid())
  );
create policy event_comments_author_or_group_insert on public.event_comments
  for insert with check (
    author_user_id = auth.uid()
    and public.can_access_event(event_comments.event_id, auth.uid())
  );
create policy event_comments_author_update on public.event_comments
  for update using (author_user_id = auth.uid()) with check (author_user_id = auth.uid());

create policy event_reactions_group_read on public.event_reactions
  for select using (
    public.can_access_event(event_reactions.event_id, auth.uid())
  );
create policy event_reactions_self_write on public.event_reactions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy notification_settings_self on public.notification_settings
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy device_tokens_self on public.device_tokens
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy widget_snapshots_self on public.widget_snapshots
  for all using (owner_user_id = auth.uid()) with check (owner_user_id = auth.uid());
create policy blocks_self on public.blocks
  for all using (blocker_user_id = auth.uid()) with check (blocker_user_id = auth.uid());
create policy reports_insert_self on public.reports
  for insert with check (reporter_user_id = auth.uid());
create policy reports_read_self on public.reports
  for select using (reporter_user_id = auth.uid());

-- No client policy for audit_logs. Admin/server-only access should use trusted environments.
