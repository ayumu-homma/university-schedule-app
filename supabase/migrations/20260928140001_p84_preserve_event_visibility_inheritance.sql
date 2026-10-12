-- P120: preserve an explicit NULL event visibility override as inheritance.
-- Missing fields preserve legacy defaults on create and stored values on update.
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
    if p_operation not in ('create', 'submit', 'update', 'delete') then
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
    if p_operation = 'create' then
      if bound_payload ->> 'status' is distinct from 'inProgress' then
        raise exception 'assignment state create requires an in-progress status'
          using errcode = '22023';
      end if;
      if nullif(bound_payload ->> 'submittedAt', '') is not null then
        raise exception 'initial assignment state cannot have a submitted timestamp'
          using errcode = '22023';
      end if;
    elsif p_operation = 'update' then
      if coalesce(bound_payload ->> 'status', '')
           not in ('notStarted', 'inProgress') then
        raise exception 'assignment state update requires a non-submitted status'
          using errcode = '22023';
      end if;
      if nullif(bound_payload ->> 'submittedAt', '') is not null then
        raise exception 'non-submitted assignment state cannot have a submitted timestamp'
          using errcode = '22023';
      end if;
    elsif p_operation = 'submit'
          and bound_payload ? 'status'
          and bound_payload ->> 'status' is distinct from 'submitted' then
      raise exception 'assignment state submit requires a submitted status'
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

    if p_operation = 'create' then
      insert into public.assignment_user_states (
        assignment_id, user_id, status, submitted_at, note
      ) values (
        p_entity_id,
        bound_owner,
        'inProgress',
        null,
        nullif(bound_payload ->> 'note', '')
      ) on conflict (assignment_id, user_id) do nothing;
      get diagnostics affected = row_count;
    elsif p_operation = 'submit' and p_base_version is null then
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
    elsif p_operation = 'submit' then
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
        and version = p_base_version;
      get diagnostics affected = row_count;
    elsif p_operation = 'update' then
      update public.assignment_user_states
      set status = bound_payload ->> 'status',
          submitted_at = null,
          note = case
            when bound_payload ? 'note' then bound_payload ->> 'note'
            else note
          end,
          deleted_at = null
      where assignment_id = p_entity_id
        and user_id = bound_owner
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
        case
          when bound_payload ? 'visibilityLevel' then
            case
              when jsonb_typeof(bound_payload -> 'visibilityLevel') = 'null'
                then null::public.visibility_level
              when bound_payload ->> 'visibilityLevel' = ''
                then 'PRIVATE'::public.visibility_level
              else (bound_payload ->> 'visibilityLevel')::public.visibility_level
            end
          else 'PRIVATE'::public.visibility_level
        end,
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
          visibility_level = case
            when bound_payload ? 'visibilityLevel' then
              case
                when jsonb_typeof(bound_payload -> 'visibilityLevel') = 'null'
                  then null::public.visibility_level
                when bound_payload ->> 'visibilityLevel' = ''
                  then 'PRIVATE'::public.visibility_level
                else (bound_payload ->> 'visibilityLevel')::public.visibility_level
              end
            else visibility_level
          end
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

revoke execute on function public.apply_schedule_mutation(
  text, text, uuid, text, bigint, jsonb
) from public, anon;
grant execute on function public.apply_schedule_mutation(
  text, text, uuid, text, bigint, jsonb
) to authenticated;
