-- Phase 3: authenticated idempotent schedule mutation + ordered delta pull.
-- The mobile client never receives table-write privileges from this migration.

alter table public.assignments
  add column if not exists priority text;

alter table public.exams
  add column if not exists memo text,
  add column if not exists exam_type text;

alter table public.assignment_user_states
  add column if not exists deleted_at timestamptz,
  add column if not exists version bigint not null default 1;

update public.events
set visibility_level = 'PRIVATE'
where visibility_level is null;

alter table public.events
  alter column visibility_level set default 'PRIVATE',
  alter column visibility_level set not null;

drop trigger if exists assignment_user_states_updated_at
  on public.assignment_user_states;
create trigger assignment_user_states_updated_at
before update on public.assignment_user_states
for each row execute function public.set_updated_at();

create table private.schedule_mutation_receipts (
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  idempotency_key text not null,
  request_hash text not null,
  response jsonb not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '90 days'),
  primary key (owner_user_id, idempotency_key),
  check (char_length(idempotency_key) between 1 and 200),
  check (jsonb_typeof(response) = 'object')
);

create index schedule_mutation_receipts_expiry_idx
  on private.schedule_mutation_receipts(expires_at);

create table private.schedule_cursor_heads (
  owner_user_id uuid primary key references auth.users(id) on delete cascade,
  last_cursor bigint not null default 0 check (last_cursor >= 0)
);

create table private.schedule_change_log (
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  change_cursor bigint not null check (change_cursor >= 1),
  entity_type text not null check (
    entity_type in (
      'user_course',
      'assignment',
      'assignment_user_state',
      'exam',
      'event'
    )
  ),
  entity_id uuid not null,
  operation text not null check (operation in ('upsert', 'delete')),
  server_version bigint not null check (server_version >= 1),
  deleted_at timestamptz,
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  changed_at timestamptz not null default now(),
  primary key (owner_user_id, change_cursor)
);

create index schedule_change_log_entity_idx
  on private.schedule_change_log(
    owner_user_id,
    entity_type,
    entity_id,
    change_cursor desc
  );

alter table private.schedule_mutation_receipts enable row level security;
alter table private.schedule_cursor_heads enable row level security;
alter table private.schedule_change_log enable row level security;

revoke all on private.schedule_mutation_receipts from public, anon, authenticated;
revoke all on private.schedule_cursor_heads from public, anon, authenticated;
revoke all on private.schedule_change_log from public, anon, authenticated;

create or replace function private.next_schedule_cursor(target_owner uuid)
returns bigint
language sql
security definer
set search_path = pg_catalog, private
as $$
  insert into private.schedule_cursor_heads (owner_user_id, last_cursor)
  values (target_owner, 1)
  on conflict (owner_user_id) do update
    set last_cursor = private.schedule_cursor_heads.last_cursor + 1
  returning last_cursor
$$;

revoke execute on function private.next_schedule_cursor(uuid)
  from public, anon, authenticated;

create or replace function private.schedule_entity_payload(
  target_owner uuid,
  target_entity_type text,
  target_entity_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
stable
as $$
declare
  result jsonb;
begin
  result := case target_entity_type
    when 'user_course' then (
      select jsonb_build_object(
        'id', c.id,
        'ownerUserId', c.owner_user_id,
        'termId', c.term_id,
        'sourceTemplateId', c.source_template_id,
        'title', c.title,
        'normalizedTitle', c.normalized_title,
        'instructorName', c.instructor_name,
        'normalizedInstructorName', c.normalized_instructor_name,
        'dayOfWeek', c.day_of_week,
        'periodNo', c.period_no,
        'room', c.room,
        'color', c.color,
        'visibilityLevel', c.visibility_level,
        'updatedAt', c.updated_at,
        'deletedAt', c.deleted_at,
        'version', c.version
      )
      from public.user_courses c
      where c.id = target_entity_id
        and c.owner_user_id = target_owner
    )
    when 'assignment' then (
      select jsonb_build_object(
        'id', a.id,
        'ownerUserId', a.owner_user_id,
        'courseId', a.course_id,
        'title', a.title,
        'description', a.description,
        'memo', a.description,
        'submissionUrl', a.submission_url,
        'priority', a.priority,
        'dueAt', a.due_at,
        'visibilityLevel', a.visibility_level,
        'updatedAt', a.updated_at,
        'deletedAt', a.deleted_at,
        'version', a.version
      )
      from public.assignments a
      where a.id = target_entity_id
        and a.owner_user_id = target_owner
    )
    when 'assignment_user_state' then (
      select jsonb_build_object(
        'assignmentId', s.assignment_id,
        'userId', s.user_id,
        'status', s.status,
        'submittedAt', s.submitted_at,
        'note', s.note,
        'updatedAt', s.updated_at,
        'deletedAt', s.deleted_at,
        'version', s.version
      )
      from public.assignment_user_states s
      where s.assignment_id = target_entity_id
        and s.user_id = target_owner
    )
    when 'exam' then (
      select jsonb_build_object(
        'id', e.id,
        'ownerUserId', e.owner_user_id,
        'courseId', e.course_id,
        'title', e.title,
        'startAt', e.start_at,
        'endAt', e.end_at,
        'room', e.room,
        'scope', e.scope,
        'memo', e.memo,
        'examType', e.exam_type,
        'visibilityLevel', e.visibility_level,
        'updatedAt', e.updated_at,
        'deletedAt', e.deleted_at,
        'version', e.version
      )
      from public.exams e
      where e.id = target_entity_id
        and e.owner_user_id = target_owner
    )
    when 'event' then (
      select jsonb_build_object(
        'id', e.id,
        'ownerUserId', e.owner_user_id,
        'calendarId', e.calendar_id,
        'groupId', e.group_id,
        'title', e.title,
        'kind', e.kind,
        'startAt', e.start_at,
        'endAt', e.end_at,
        'isAllDay', e.is_all_day,
        'location', e.location,
        'description', e.description,
        'rrule', e.rrule,
        'timezone', e.timezone,
        'visibilityLevel', e.visibility_level,
        'updatedAt', e.updated_at,
        'deletedAt', e.deleted_at,
        'version', e.version
      )
      from public.events e
      where e.id = target_entity_id
        and e.owner_user_id = target_owner
    )
    else null
  end;

  return result;
end;
$$;

create or replace function private.schedule_change_payload(
  target_owner uuid,
  target_entity_type text,
  target_entity_id uuid,
  target_cursor bigint
)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select jsonb_build_object(
    'changeCursor', l.change_cursor,
    'entityType', l.entity_type,
    'entityId', l.entity_id,
    'operation', l.operation,
    'serverVersion', l.server_version,
    'deletedAt', l.deleted_at,
    'payload', l.payload
  )
  from private.schedule_change_log l
  where l.owner_user_id = target_owner
    and l.entity_type = target_entity_type
    and l.entity_id = target_entity_id
    and l.change_cursor = target_cursor
$$;

create or replace function private.record_schedule_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private, realtime
as $$
declare
  bound_owner uuid;
  bound_entity_type text := tg_argv[0];
  bound_entity_id uuid;
  bound_version bigint;
  bound_deleted_at timestamptz;
  bound_payload jsonb;
  bound_cursor bigint;
begin
  if bound_entity_type = 'assignment_user_state' then
    bound_owner := new.user_id;
    bound_entity_id := new.assignment_id;
  else
    bound_owner := new.owner_user_id;
    bound_entity_id := new.id;
  end if;
  bound_version := new.version;
  bound_deleted_at := new.deleted_at;
  bound_payload := private.schedule_entity_payload(
    bound_owner,
    bound_entity_type,
    bound_entity_id
  );

  insert into private.schedule_change_log (
    owner_user_id,
    change_cursor,
    entity_type,
    entity_id,
    operation,
    server_version,
    deleted_at,
    payload
  ) values (
    bound_owner,
    private.next_schedule_cursor(bound_owner),
    bound_entity_type,
    bound_entity_id,
    case when bound_deleted_at is null then 'upsert' else 'delete' end,
    bound_version,
    bound_deleted_at,
    bound_payload
  )
  returning change_cursor into bound_cursor;

  perform realtime.send(
    jsonb_build_object('cursor', bound_cursor),
    'invalidate',
    'schedule-sync:' || bound_owner::text,
    true
  );

  return new;
end;
$$;

drop trigger if exists user_courses_schedule_change on public.user_courses;
create trigger user_courses_schedule_change
after insert or update on public.user_courses
for each row execute function private.record_schedule_change('user_course');

drop trigger if exists assignments_schedule_change on public.assignments;
create trigger assignments_schedule_change
after insert or update on public.assignments
for each row execute function private.record_schedule_change('assignment');

drop trigger if exists assignment_states_schedule_change
  on public.assignment_user_states;
create trigger assignment_states_schedule_change
after insert or update on public.assignment_user_states
for each row execute function private.record_schedule_change(
  'assignment_user_state'
);

drop trigger if exists exams_schedule_change on public.exams;
create trigger exams_schedule_change
after insert or update on public.exams
for each row execute function private.record_schedule_change('exam');

drop trigger if exists events_schedule_change on public.events;
create trigger events_schedule_change
after insert or update on public.events
for each row execute function private.record_schedule_change('event');

-- Existing rows must be visible to a fresh device pulling from cursor zero.
insert into private.schedule_change_log (
  owner_user_id, change_cursor, entity_type, entity_id, operation,
  server_version, deleted_at, payload
)
select owner_user_id, private.next_schedule_cursor(owner_user_id),
  'user_course', id,
  case when deleted_at is null then 'upsert' else 'delete' end,
  version, deleted_at,
  private.schedule_entity_payload(owner_user_id, 'user_course', id)
from public.user_courses;

insert into private.schedule_change_log (
  owner_user_id, change_cursor, entity_type, entity_id, operation,
  server_version, deleted_at, payload
)
select owner_user_id, private.next_schedule_cursor(owner_user_id),
  'assignment', id,
  case when deleted_at is null then 'upsert' else 'delete' end,
  version, deleted_at,
  private.schedule_entity_payload(owner_user_id, 'assignment', id)
from public.assignments;

insert into private.schedule_change_log (
  owner_user_id, change_cursor, entity_type, entity_id, operation,
  server_version, deleted_at, payload
)
select user_id, private.next_schedule_cursor(user_id),
  'assignment_user_state', assignment_id,
  case when deleted_at is null then 'upsert' else 'delete' end,
  version, deleted_at,
  private.schedule_entity_payload(
    user_id,
    'assignment_user_state',
    assignment_id
  )
from public.assignment_user_states;

insert into private.schedule_change_log (
  owner_user_id, change_cursor, entity_type, entity_id, operation,
  server_version, deleted_at, payload
)
select owner_user_id, private.next_schedule_cursor(owner_user_id),
  'exam', id,
  case when deleted_at is null then 'upsert' else 'delete' end,
  version, deleted_at,
  private.schedule_entity_payload(owner_user_id, 'exam', id)
from public.exams;

insert into private.schedule_change_log (
  owner_user_id, change_cursor, entity_type, entity_id, operation,
  server_version, deleted_at, payload
)
select owner_user_id, private.next_schedule_cursor(owner_user_id),
  'event', id,
  case when deleted_at is null then 'upsert' else 'delete' end,
  version, deleted_at,
  private.schedule_entity_payload(owner_user_id, 'event', id)
from public.events;

-- This pre-existing SECURITY DEFINER writer must enforce the same ownership
-- boundary as the sync RPC. In particular, a caller may never attach a copied
-- course to another user's term by guessing its UUID.
create or replace function public.copy_course_template(
  template_id uuid,
  target_term_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  caller_id uuid := auth.uid();
  source_template public.course_templates%rowtype;
  caller_university_id uuid;
  new_course_id uuid;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  select p.university_id into caller_university_id
  from public.profiles p
  where p.user_id = caller_id
    and p.deleted_at is null;

  select * into source_template
  from public.course_templates ct
  where ct.id = template_id
    and ct.university_id = caller_university_id
    and ct.status = 'active'
    and ct.deleted_at is null;

  if not found then
    raise exception 'course template is not available for this university'
      using errcode = '42501';
  end if;

  if target_term_id is null or not exists (
    select 1
    from public.terms t
    where t.id = target_term_id
      and t.owner_user_id = caller_id
      and t.university_id = caller_university_id
      and not t.is_template
      and t.status = 'active'
      and t.deleted_at is null
  ) then
    raise exception 'owned active target term is required'
      using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'copy-course:' || caller_id::text || ':' || template_id::text || ':' ||
        target_term_id::text,
      0
    )
  );
  select c.id into new_course_id
  from public.user_courses c
  where c.owner_user_id = caller_id
    and c.term_id = target_term_id
    and c.source_template_id = source_template.id
    and c.deleted_at is null
  order by c.created_at, c.id
  limit 1;
  if found then
    return new_course_id;
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
  ) values (
    caller_id,
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
  ) returning id into new_course_id;

  update public.course_templates
  set copy_count_total = copy_count_total + 1,
      copy_count_term = copy_count_term + 1
  where id = source_template.id;

  insert into public.course_template_copy_events (
    template_id,
    copied_by,
    user_course_id
  ) values (
    source_template.id,
    caller_id,
    new_course_id
  );

  return new_course_id;
end;
$$;

create or replace function public.apply_schedule_mutation(
  p_idempotency_key text,
  p_entity_type text,
  p_entity_id uuid,
  p_operation text,
  p_base_version bigint default null,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private, extensions
as $$
declare
  bound_owner uuid := auth.uid();
  bound_entity_type text := case
    when p_entity_type = 'assignment_state' then 'assignment_user_state'
    else p_entity_type
  end;
  bound_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  bound_hash text;
  stored_hash text;
  stored_response jsonb;
  current_change jsonb;
  result jsonb;
  outcome text;
  affected integer := 0;
  current_version bigint;
  current_cursor bigint;
  current_deleted_at timestamptz;
  referenced_term uuid;
  referenced_course uuid;
  referenced_calendar uuid;
  referenced_template uuid;
begin
  if bound_owner is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_idempotency_key is null
     or char_length(btrim(p_idempotency_key)) not between 1 and 200
     or p_idempotency_key <> btrim(p_idempotency_key) then
    raise exception 'invalid idempotency key' using errcode = '22023';
  end if;
  if p_entity_id is null
     or bound_entity_type not in (
       'user_course',
       'assignment',
       'assignment_user_state',
       'exam',
       'event'
     ) then
    raise exception 'unsupported schedule entity' using errcode = '22023';
  end if;
  if jsonb_typeof(bound_payload) <> 'object' then
    raise exception 'schedule mutation payload must be an object'
      using errcode = '22023';
  end if;
  if pg_catalog.pg_column_size(bound_payload) > 65536 then
    raise exception 'schedule mutation payload is too large'
      using errcode = '22023';
  end if;
  if p_operation not in ('create', 'update', 'submit', 'delete') then
    raise exception 'unsupported schedule operation' using errcode = '22023';
  end if;
  if p_operation = 'create' and p_base_version is not null then
    raise exception 'create mutation cannot include a base version'
      using errcode = '22023';
  end if;
  if p_operation in ('update', 'delete')
     and coalesce(p_base_version, 0) < 1 then
    raise exception 'update and delete require a base version'
      using errcode = '22023';
  end if;
  if bound_entity_type = 'assignment_user_state' then
    if p_operation not in ('submit', 'update', 'delete') then
      raise exception 'unsupported assignment state operation'
        using errcode = '22023';
    end if;
    if p_operation = 'update' and coalesce(p_base_version, 0) < 1 then
      raise exception 'assignment state update requires a base version'
        using errcode = '22023';
    end if;
    if p_operation = 'submit'
       and p_base_version is not null
       and p_base_version < 1 then
      raise exception 'invalid assignment state base version'
        using errcode = '22023';
    end if;
  elsif p_operation = 'submit' then
    raise exception 'submit is only valid for assignment state'
      using errcode = '22023';
  end if;

  if bound_payload ? 'ownerUserId'
     and nullif(bound_payload ->> 'ownerUserId', '')::uuid
       is distinct from bound_owner then
    raise exception 'payload owner mismatch' using errcode = '42501';
  end if;
  if bound_payload ? 'owner_user_id'
     and nullif(bound_payload ->> 'owner_user_id', '')::uuid
       is distinct from bound_owner then
    raise exception 'payload owner mismatch' using errcode = '42501';
  end if;
  if bound_entity_type = 'assignment_user_state'
     and bound_payload ? 'userId'
     and nullif(bound_payload ->> 'userId', '')::uuid
       is distinct from bound_owner then
    raise exception 'payload user mismatch' using errcode = '42501';
  end if;
  if bound_entity_type = 'assignment_user_state' then
    if bound_payload ? 'assignmentId'
       and nullif(bound_payload ->> 'assignmentId', '')::uuid
         is distinct from p_entity_id then
      raise exception 'payload entity mismatch' using errcode = '22023';
    end if;
  elsif bound_payload ? 'id'
        and nullif(bound_payload ->> 'id', '')::uuid
          is distinct from p_entity_id then
    raise exception 'payload entity mismatch' using errcode = '22023';
  end if;

  -- Owner values are transport assertions only. They never participate in the
  -- server write and are normalized out of the durable request fingerprint.
  bound_payload := bound_payload
    - 'ownerUserId'
    - 'owner_user_id'
    - 'userId';
  bound_hash := encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'entityType', bound_entity_type,
          'entityId', p_entity_id,
          'operation', p_operation,
          'baseVersion', p_base_version,
          'payload', bound_payload
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      bound_owner::text || ':' || p_idempotency_key,
      0
    )
  );
  delete from private.schedule_mutation_receipts r
  where r.owner_user_id = bound_owner
    and r.expires_at <= now();
  select r.request_hash, r.response
    into stored_hash, stored_response
  from private.schedule_mutation_receipts r
  where r.owner_user_id = bound_owner
    and r.idempotency_key = p_idempotency_key;
  if found then
    if stored_hash <> bound_hash then
      raise exception 'idempotency key was already used for another request'
        using errcode = '23505';
    end if;
    return jsonb_set(stored_response, '{replayed}', 'true'::jsonb, true);
  end if;

  if bound_entity_type = 'user_course' then
    if p_operation <> 'delete' then
      if nullif(btrim(bound_payload ->> 'title'), '') is null then
        raise exception 'course title is required' using errcode = '22023';
      end if;
      referenced_term := nullif(bound_payload ->> 'termId', '')::uuid;
      if referenced_term is null or not exists (
        select 1
        from public.terms t
        join public.profiles p
          on p.user_id = bound_owner
         and p.university_id = t.university_id
         and p.deleted_at is null
        where t.id = referenced_term
          and t.owner_user_id = bound_owner
          and not t.is_template
          and t.status = 'active'
          and t.deleted_at is null
      ) then
        raise exception 'owned active term is required' using errcode = '42501';
      end if;
      referenced_template := nullif(
        bound_payload ->> 'sourceTemplateId',
        ''
      )::uuid;
      if referenced_template is not null and not exists (
        select 1
        from public.course_templates ct
        join public.profiles p
          on p.user_id = bound_owner
         and p.university_id = ct.university_id
         and p.deleted_at is null
        where ct.id = referenced_template
          and ct.status = 'active'
          and ct.deleted_at is null
      ) then
        raise exception 'course template is not available for this university'
          using errcode = '42501';
      end if;
    end if;

    if p_operation = 'create' then
      insert into public.user_courses (
        id, owner_user_id, term_id, source_template_id, title,
        normalized_title, instructor_name, normalized_instructor_name,
        day_of_week, period_no, room, color, visibility_level
      ) values (
        p_entity_id,
        bound_owner,
        referenced_term,
        referenced_template,
        btrim(bound_payload ->> 'title'),
        public.normalize_course_text(bound_payload ->> 'title'),
        nullif(bound_payload ->> 'instructorName', ''),
        public.normalize_course_text(bound_payload ->> 'instructorName'),
        nullif(bound_payload ->> 'dayOfWeek', '')::integer,
        nullif(bound_payload ->> 'periodNo', '')::integer,
        nullif(bound_payload ->> 'room', ''),
        nullif(bound_payload ->> 'color', ''),
        coalesce(
          nullif(bound_payload ->> 'visibilityLevel', '')::public.visibility_level,
          'PRIVATE'::public.visibility_level
        )
      ) on conflict (id) do nothing;
      get diagnostics affected = row_count;
    elsif p_operation = 'update' then
      update public.user_courses
      set term_id = referenced_term,
          source_template_id = referenced_template,
          title = btrim(bound_payload ->> 'title'),
          normalized_title = public.normalize_course_text(
            bound_payload ->> 'title'
          ),
          instructor_name = nullif(bound_payload ->> 'instructorName', ''),
          normalized_instructor_name = public.normalize_course_text(
            bound_payload ->> 'instructorName'
          ),
          day_of_week = nullif(bound_payload ->> 'dayOfWeek', '')::integer,
          period_no = nullif(bound_payload ->> 'periodNo', '')::integer,
          room = nullif(bound_payload ->> 'room', ''),
          color = nullif(bound_payload ->> 'color', ''),
          visibility_level = coalesce(
            nullif(bound_payload ->> 'visibilityLevel', '')::public.visibility_level,
            'PRIVATE'::public.visibility_level
          )
      where id = p_entity_id
        and owner_user_id = bound_owner
        and deleted_at is null
        and version = p_base_version;
      get diagnostics affected = row_count;
    else
      update public.user_courses
      set deleted_at = now()
      where id = p_entity_id
        and owner_user_id = bound_owner
        and deleted_at is null
        and version = p_base_version;
      get diagnostics affected = row_count;
    end if;

  elsif bound_entity_type = 'assignment' then
    if p_operation <> 'delete' then
      if nullif(btrim(bound_payload ->> 'title'), '') is null
         or nullif(bound_payload ->> 'dueAt', '') is null then
        raise exception 'assignment title and due time are required'
          using errcode = '22023';
      end if;
      referenced_course := nullif(bound_payload ->> 'courseId', '')::uuid;
      if referenced_course is not null and not exists (
        select 1 from public.user_courses c
        where c.id = referenced_course
          and c.owner_user_id = bound_owner
          and c.deleted_at is null
      ) then
        raise exception 'owned active course is required' using errcode = '42501';
      end if;
    end if;

    if p_operation = 'create' then
      insert into public.assignments (
        id, owner_user_id, course_id, title, description, submission_url,
        priority, due_at, visibility_level
      ) values (
        p_entity_id,
        bound_owner,
        referenced_course,
        btrim(bound_payload ->> 'title'),
        coalesce(bound_payload ->> 'memo', bound_payload ->> 'description'),
        nullif(bound_payload ->> 'submissionUrl', ''),
        nullif(bound_payload ->> 'priority', ''),
        (bound_payload ->> 'dueAt')::timestamptz,
        coalesce(
          nullif(bound_payload ->> 'visibilityLevel', '')::public.visibility_level,
          'PRIVATE'::public.visibility_level
        )
      ) on conflict (id) do nothing;
      get diagnostics affected = row_count;
    elsif p_operation = 'update' then
      update public.assignments
      set course_id = referenced_course,
          title = btrim(bound_payload ->> 'title'),
          description = coalesce(
            bound_payload ->> 'memo',
            bound_payload ->> 'description'
          ),
          submission_url = nullif(bound_payload ->> 'submissionUrl', ''),
          priority = nullif(bound_payload ->> 'priority', ''),
          due_at = (bound_payload ->> 'dueAt')::timestamptz,
          visibility_level = coalesce(
            nullif(bound_payload ->> 'visibilityLevel', '')::public.visibility_level,
            'PRIVATE'::public.visibility_level
          )
      where id = p_entity_id
        and owner_user_id = bound_owner
        and deleted_at is null
        and version = p_base_version;
      get diagnostics affected = row_count;
    else
      update public.assignments
      set deleted_at = now()
      where id = p_entity_id
        and owner_user_id = bound_owner
        and deleted_at is null
        and version = p_base_version;
      get diagnostics affected = row_count;
    end if;

  elsif bound_entity_type = 'assignment_user_state' then
    if not exists (
      select 1 from public.assignments a
      where a.id = p_entity_id
        and a.owner_user_id = bound_owner
        and (p_operation = 'delete' or a.deleted_at is null)
    ) then
      raise exception 'owned active assignment is required'
        using errcode = '42501';
    end if;

    if p_operation = 'submit' and p_base_version is null then
      insert into public.assignment_user_states (
        assignment_id, user_id, status, submitted_at, note
      ) values (
        p_entity_id,
        bound_owner,
        coalesce(nullif(bound_payload ->> 'status', ''), 'submitted'),
        coalesce(
          nullif(bound_payload ->> 'submittedAt', '')::timestamptz,
          now()
        ),
        nullif(bound_payload ->> 'note', '')
      ) on conflict (assignment_id, user_id) do nothing;
      get diagnostics affected = row_count;
    elsif p_operation in ('submit', 'update') then
      update public.assignment_user_states
      set status = coalesce(
            nullif(bound_payload ->> 'status', ''),
            status
          ),
          submitted_at = case
            when bound_payload ? 'submittedAt'
              then nullif(bound_payload ->> 'submittedAt', '')::timestamptz
            else submitted_at
          end,
          note = case
            when bound_payload ? 'note' then bound_payload ->> 'note'
            else note
          end,
          deleted_at = null
      where assignment_id = p_entity_id
        and user_id = bound_owner
        and (p_operation = 'submit' or deleted_at is null)
        and version = p_base_version;
      get diagnostics affected = row_count;
    else
      update public.assignment_user_states
      set deleted_at = now()
      where assignment_id = p_entity_id
        and user_id = bound_owner
        and deleted_at is null
        and version = p_base_version;
      get diagnostics affected = row_count;
    end if;

  elsif bound_entity_type = 'exam' then
    if p_operation <> 'delete' then
      if nullif(btrim(bound_payload ->> 'title'), '') is null
         or nullif(bound_payload ->> 'startAt', '') is null
         or nullif(bound_payload ->> 'endAt', '') is null then
        raise exception 'exam title and time range are required'
          using errcode = '22023';
      end if;
      referenced_course := nullif(bound_payload ->> 'courseId', '')::uuid;
      if referenced_course is not null and not exists (
        select 1 from public.user_courses c
        where c.id = referenced_course
          and c.owner_user_id = bound_owner
          and c.deleted_at is null
      ) then
        raise exception 'owned active course is required' using errcode = '42501';
      end if;
    end if;

    if p_operation = 'create' then
      insert into public.exams (
        id, owner_user_id, course_id, title, start_at, end_at, room, scope,
        memo, exam_type, visibility_level
      ) values (
        p_entity_id,
        bound_owner,
        referenced_course,
        btrim(bound_payload ->> 'title'),
        (bound_payload ->> 'startAt')::timestamptz,
        (bound_payload ->> 'endAt')::timestamptz,
        nullif(bound_payload ->> 'room', ''),
        nullif(bound_payload ->> 'scope', ''),
        nullif(bound_payload ->> 'memo', ''),
        nullif(bound_payload ->> 'examType', ''),
        coalesce(
          nullif(bound_payload ->> 'visibilityLevel', '')::public.visibility_level,
          'PRIVATE'::public.visibility_level
        )
      ) on conflict (id) do nothing;
      get diagnostics affected = row_count;
    elsif p_operation = 'update' then
      update public.exams
      set course_id = referenced_course,
          title = btrim(bound_payload ->> 'title'),
          start_at = (bound_payload ->> 'startAt')::timestamptz,
          end_at = (bound_payload ->> 'endAt')::timestamptz,
          room = nullif(bound_payload ->> 'room', ''),
          scope = nullif(bound_payload ->> 'scope', ''),
          memo = nullif(bound_payload ->> 'memo', ''),
          exam_type = nullif(bound_payload ->> 'examType', ''),
          visibility_level = coalesce(
            nullif(bound_payload ->> 'visibilityLevel', '')::public.visibility_level,
            'PRIVATE'::public.visibility_level
          )
      where id = p_entity_id
        and owner_user_id = bound_owner
        and deleted_at is null
        and version = p_base_version;
      get diagnostics affected = row_count;
    else
      update public.exams
      set deleted_at = now()
      where id = p_entity_id
        and owner_user_id = bound_owner
        and deleted_at is null
        and version = p_base_version;
      get diagnostics affected = row_count;
    end if;

  elsif bound_entity_type = 'event' then
    if p_operation <> 'delete' then
      if nullif(btrim(bound_payload ->> 'title'), '') is null
         or nullif(bound_payload ->> 'startAt', '') is null
         or nullif(bound_payload ->> 'endAt', '') is null then
        raise exception 'event title and time range are required'
          using errcode = '22023';
      end if;
      referenced_calendar := nullif(bound_payload ->> 'calendarId', '')::uuid;
      if referenced_calendar is null or not exists (
        select 1 from public.calendars c
        where c.id = referenced_calendar
          and c.owner_user_id = bound_owner
          and c.group_id is null
          and c.deleted_at is null
      ) then
        raise exception 'owned active calendar is required'
          using errcode = '42501';
      end if;
      if nullif(bound_payload ->> 'groupId', '') is not null then
        raise exception 'personal schedule sync cannot mutate a group event'
          using errcode = '42501';
      end if;
    end if;

    if p_operation = 'create' then
      insert into public.events (
        id, owner_user_id, calendar_id, group_id, title, kind, start_at,
        end_at, is_all_day, location, description, rrule, timezone,
        visibility_level, created_by
      ) values (
        p_entity_id,
        bound_owner,
        referenced_calendar,
        null,
        btrim(bound_payload ->> 'title'),
        coalesce(nullif(bound_payload ->> 'kind', ''), 'normal'),
        (bound_payload ->> 'startAt')::timestamptz,
        (bound_payload ->> 'endAt')::timestamptz,
        coalesce((bound_payload ->> 'isAllDay')::boolean, false),
        nullif(bound_payload ->> 'location', ''),
        nullif(bound_payload ->> 'description', ''),
        nullif(bound_payload ->> 'rrule', ''),
        coalesce(nullif(bound_payload ->> 'timezone', ''), 'Asia/Tokyo'),
        coalesce(
          nullif(bound_payload ->> 'visibilityLevel', '')::public.visibility_level,
          'PRIVATE'::public.visibility_level
        ),
        bound_owner
      ) on conflict (id) do nothing;
      get diagnostics affected = row_count;
    elsif p_operation = 'update' then
      update public.events
      set calendar_id = referenced_calendar,
          group_id = null,
          title = btrim(bound_payload ->> 'title'),
          kind = coalesce(nullif(bound_payload ->> 'kind', ''), kind),
          start_at = (bound_payload ->> 'startAt')::timestamptz,
          end_at = (bound_payload ->> 'endAt')::timestamptz,
          is_all_day = coalesce(
            (bound_payload ->> 'isAllDay')::boolean,
            false
          ),
          location = nullif(bound_payload ->> 'location', ''),
          description = nullif(bound_payload ->> 'description', ''),
          rrule = nullif(bound_payload ->> 'rrule', ''),
          timezone = coalesce(
            nullif(bound_payload ->> 'timezone', ''),
            'Asia/Tokyo'
          ),
          visibility_level = coalesce(
            nullif(bound_payload ->> 'visibilityLevel', '')::public.visibility_level,
            'PRIVATE'::public.visibility_level
          )
      where id = p_entity_id
        and owner_user_id = bound_owner
        and group_id is null
        and deleted_at is null
        and version = p_base_version;
      get diagnostics affected = row_count;
    else
      update public.events
      set deleted_at = now()
      where id = p_entity_id
        and owner_user_id = bound_owner
        and group_id is null
        and deleted_at is null
        and version = p_base_version;
      get diagnostics affected = row_count;
    end if;
  end if;

  outcome := case when affected = 1 then 'applied' else 'conflict' end;
  select
    l.change_cursor,
    l.server_version,
    l.deleted_at,
    private.schedule_change_payload(
      bound_owner,
      bound_entity_type,
      p_entity_id,
      l.change_cursor
    )
    into
      current_cursor,
      current_version,
      current_deleted_at,
      current_change
  from private.schedule_change_log l
  where l.owner_user_id = bound_owner
    and l.entity_type = bound_entity_type
    and l.entity_id = p_entity_id
  order by l.change_cursor desc
  limit 1;
  if not found then
    raise exception 'schedule entity is unavailable' using errcode = '42501';
  end if;
  result := jsonb_build_object(
    'outcome', outcome,
    'entity_type', bound_entity_type,
    'entity_id', p_entity_id,
    'operation', p_operation,
    'server_version', current_version,
    'change_cursor', current_cursor,
    'deleted_at', current_deleted_at,
    'replayed', false,
    'change', current_change
  );

  insert into private.schedule_mutation_receipts (
    owner_user_id,
    idempotency_key,
    request_hash,
    response
  ) values (
    bound_owner,
    p_idempotency_key,
    bound_hash,
    result
  );
  return result;
end;
$$;

create or replace function public.get_schedule_delta(
  p_after_cursor bigint default 0,
  p_limit integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
stable
as $$
declare
  bound_owner uuid := auth.uid();
  result_changes jsonb;
  result_next_cursor bigint;
  result_has_more boolean;
begin
  if bound_owner is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_after_cursor is null or p_after_cursor < 0 then
    raise exception 'cursor must be non-negative' using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 500 then
    raise exception 'limit must be between 1 and 500' using errcode = '22023';
  end if;

  with candidate as materialized (
    select l.change_cursor
    from private.schedule_change_log l
    where l.owner_user_id = bound_owner
      and l.change_cursor > p_after_cursor
    order by l.change_cursor
    limit p_limit + 1
  ), page as (
    select c.change_cursor
    from candidate c
    order by c.change_cursor
    limit p_limit
  )
  select
    coalesce(
      jsonb_agg(
        private.schedule_change_payload(
          bound_owner,
          l.entity_type,
          l.entity_id,
          l.change_cursor
        ) order by l.change_cursor
      ),
      '[]'::jsonb
    ),
    coalesce(max(l.change_cursor), p_after_cursor),
    (select count(*) > p_limit from candidate)
  into result_changes, result_next_cursor, result_has_more
  from page p
  join private.schedule_change_log l
    on l.change_cursor = p.change_cursor
   and l.owner_user_id = bound_owner;

  return jsonb_build_object(
    'changes', result_changes,
    'next_cursor', result_next_cursor,
    'has_more', coalesce(result_has_more, false)
  );
end;
$$;

revoke execute on function private.schedule_entity_payload(uuid, text, uuid)
  from public, anon, authenticated;
revoke execute on function private.schedule_change_payload(uuid, text, uuid, bigint)
  from public, anon, authenticated;
revoke execute on function private.record_schedule_change()
  from public, anon, authenticated;
revoke execute on function public.apply_schedule_mutation(
  text, text, uuid, text, bigint, jsonb
) from public, anon;
revoke execute on function public.get_schedule_delta(bigint, integer)
  from public, anon;
grant execute on function public.apply_schedule_mutation(
  text, text, uuid, text, bigint, jsonb
) to authenticated;
grant execute on function public.get_schedule_delta(bigint, integer)
  to authenticated;

revoke all on public.user_courses from anon;
revoke all on public.assignments from anon;
revoke all on public.assignment_user_states from anon;
revoke all on public.exams from anon;
revoke all on public.events from anon;
revoke all on public.calendars from anon;
revoke insert, update, delete on public.user_courses from authenticated;
revoke insert, update, delete on public.assignments from authenticated;
revoke insert, update, delete on public.assignment_user_states from authenticated;
revoke insert, update, delete on public.exams from authenticated;
revoke insert, update, delete on public.events from authenticated;
revoke insert, update, delete on public.calendars from authenticated;
grant select on public.calendars to authenticated;

-- Preserve the existing RLS negative-operation probes without retaining an
-- executable direct-write path. UPDATE/DELETE have table permission so a
-- denied row returns an empty result, while the absence of policies denies
-- every authenticated row. All legitimate event writes use the mutation RPC.
drop policy if exists events_scoped_update on public.events;
drop policy if exists events_scoped_delete on public.events;
grant update, delete on public.events to authenticated;

drop policy if exists schedule_sync_broadcast_receive on realtime.messages;
create policy schedule_sync_broadcast_receive
on realtime.messages
for select
to authenticated
using (
  extension = 'broadcast'
  and private
  and realtime.topic() = 'schedule-sync:' || auth.uid()::text
);
