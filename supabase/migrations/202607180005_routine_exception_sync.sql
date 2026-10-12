-- Phase 4 ROUTINE-01: versioned, owner-scoped routine exceptions.
--
-- Event exceptions predate schedule sync. They used to be mutable through a
-- general event-access policy and had no owner/version/tombstone information,
-- which made a private routine impossible to converge safely across devices.
-- This migration makes an exception a first-class, private schedule entity
-- while deliberately leaving group-event exceptions out of personal sync.

begin;

alter table public.event_exceptions
  add column if not exists owner_user_id uuid references auth.users(id),
  add column if not exists deleted_at timestamptz,
  add column if not exists version bigint not null default 1;

update public.event_exceptions x
set owner_user_id = e.owner_user_id
from public.events e
where e.id = x.event_id
  and x.owner_user_id is null;

do $$
begin
  if exists (
    select 1
    from public.event_exceptions
    where owner_user_id is null
  ) then
    raise exception 'cannot infer event exception ownership';
  end if;
end;
$$;

alter table public.event_exceptions
  alter column owner_user_id set not null,
  drop constraint if exists event_exceptions_event_id_recurrence_id_key,
  add constraint event_exceptions_override_time_order_check check (
    override_start_at is null
    or override_end_at is null
    or override_end_at > override_start_at
  );

create unique index if not exists event_exceptions_active_recurrence_idx
  on public.event_exceptions(event_id, recurrence_id)
  where deleted_at is null;

create index if not exists event_exceptions_owner_active_idx
  on public.event_exceptions(owner_user_id, event_id, recurrence_id)
  where deleted_at is null;

-- Security-definer writers must never be able to attach a personal exception
-- to a group event or an event owned by somebody else. The trigger also keeps
-- legacy/direct callers from forging the denormalized owner column.
create or replace function private.enforce_personal_event_exception_scope()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  event_owner uuid;
begin
  select e.owner_user_id into event_owner
  from public.events e
  where e.id = new.event_id
    and e.group_id is null
    and e.deleted_at is null;
  if event_owner is null then
    raise exception 'owned personal event is required' using errcode = '42501';
  end if;
  if new.owner_user_id is null then
    new.owner_user_id := event_owner;
  elsif new.owner_user_id is distinct from event_owner then
    raise exception 'event exception owner mismatch' using errcode = '42501';
  end if;
  if new.created_by is null then
    new.created_by := event_owner;
  elsif new.created_by is distinct from event_owner then
    raise exception 'event exception creator mismatch' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists event_exceptions_scope_guard on public.event_exceptions;
create trigger event_exceptions_scope_guard
before insert or update on public.event_exceptions
for each row execute function private.enforce_personal_event_exception_scope();

revoke execute on function private.enforce_personal_event_exception_scope()
  from public, anon, authenticated;

-- Private routines are synced only via the authenticated mutation/delta
-- surface. Retain no direct table-write path for browser or mobile clients.
drop policy if exists event_exceptions_event_writer on public.event_exceptions;
drop policy if exists event_exceptions_owner_read on public.event_exceptions;
create policy event_exceptions_owner_read on public.event_exceptions
  for select to authenticated
  using (owner_user_id = auth.uid());

revoke all on public.event_exceptions from public, anon, authenticated;

alter table private.schedule_change_log
  drop constraint if exists schedule_change_log_entity_type_check,
  add constraint schedule_change_log_entity_type_check check (
    entity_type in (
      'user_course',
      'assignment',
      'assignment_user_state',
      'exam',
      'event',
      'event_exception'
    )
  );

create or replace function private.schedule_event_exception_payload(
  target_owner uuid,
  target_entity_id uuid
)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select jsonb_build_object(
    'id', x.id,
    'ownerUserId', x.owner_user_id,
    'eventId', x.event_id,
    'recurrenceId', x.recurrence_id,
    'mode', x.mode,
    'overrideStartAt', x.override_start_at,
    'overrideEndAt', x.override_end_at,
    'overrideTitle', x.override_title,
    'overrideLocation', x.override_location,
    'overrideDescription', x.override_description,
    'overrideVisibility', x.override_visibility,
    'updatedAt', x.updated_at,
    'deletedAt', x.deleted_at,
    'version', x.version
  )
  from public.event_exceptions x
  join public.events e on e.id = x.event_id
  where x.id = target_entity_id
    and x.owner_user_id = target_owner
    and e.owner_user_id = target_owner
    and e.group_id is null
$$;

revoke execute on function private.schedule_event_exception_payload(uuid, uuid)
  from public, anon, authenticated;

-- Preserve the established change log behavior for the original five entity
-- kinds and add the exception identity/payload shape without exposing it.
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
  elsif bound_entity_type = 'event_exception' then
    bound_owner := new.owner_user_id;
    bound_entity_id := new.id;
  else
    bound_owner := new.owner_user_id;
    bound_entity_id := new.id;
  end if;
  bound_version := new.version;
  bound_deleted_at := new.deleted_at;
  bound_payload := case
    when bound_entity_type = 'event_exception'
      then private.schedule_event_exception_payload(bound_owner, bound_entity_id)
    else private.schedule_entity_payload(
      bound_owner,
      bound_entity_type,
      bound_entity_id
    )
  end;
  if bound_payload is null then
    raise exception 'schedule entity payload is unavailable' using errcode = '42501';
  end if;

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

drop trigger if exists event_exceptions_schedule_change on public.event_exceptions;
create trigger event_exceptions_schedule_change
after insert or update on public.event_exceptions
for each row execute function private.record_schedule_change('event_exception');

insert into private.schedule_change_log (
  owner_user_id, change_cursor, entity_type, entity_id, operation,
  server_version, deleted_at, payload
)
select
  x.owner_user_id,
  private.next_schedule_cursor(x.owner_user_id),
  'event_exception',
  x.id,
  case when x.deleted_at is null then 'upsert' else 'delete' end,
  x.version,
  x.deleted_at,
  private.schedule_event_exception_payload(x.owner_user_id, x.id)
from public.event_exceptions x
join public.events e on e.id = x.event_id
where e.owner_user_id = x.owner_user_id
  and e.group_id is null
  and not exists (
    select 1
    from private.schedule_change_log l
    where l.owner_user_id = x.owner_user_id
      and l.entity_type = 'event_exception'
      and l.entity_id = x.id
  );

-- The mobile app intentionally supports a small, finite recurrence grammar
-- instead of arbitrary RFC 5545. Keep its validation in one private parser so
-- personal event writes and exception occurrence checks cannot drift apart.
-- Offset-less UNTIL values are emitted by the app as wall-clock values, so
-- they are interpreted in the event's declared timezone.
create or replace function private.parse_personal_routine_rule(
  p_start_at timestamptz,
  p_timezone text,
  p_rrule text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
stable
strict
as $$
declare
  raw_rule text := btrim(p_rrule);
  component text;
  equals_at integer;
  component_key text;
  component_value text;
  rule_values jsonb := '{}'::jsonb;
  frequency text;
  interval_value bigint := 1;
  count_value bigint;
  until_value timestamptz;
  until_text text;
  by_weekdays integer[] := '{}'::integer[];
  weekday_text text;
  weekday_value bigint;
  month_day_value bigint;
  nth_value bigint;
  weekday_selector_value bigint;
  local_start timestamp without time zone;
begin
  if raw_rule = ''
     or octet_length(raw_rule) > 1024
     or nullif(btrim(p_timezone), '') is null then
    return null;
  end if;

  begin
    -- This also rejects an invalid timezone before any timestamp parsing.
    local_start := p_start_at at time zone p_timezone;
  exception when others then
    return null;
  end;
  if local_start is null then
    return null;
  end if;

  for component in
    select regexp_split_to_table(raw_rule, ';')
  loop
    equals_at := position('=' in component);
    if equals_at <= 1
       or position('=' in substring(component from equals_at + 1)) > 0 then
      return null;
    end if;
    component_key := upper(btrim(left(component, equals_at - 1)));
    component_value := btrim(substring(component from equals_at + 1));
    if component_key not in (
         'FREQ', 'INTERVAL', 'BYDAY', 'COUNT', 'UNTIL', 'MONTHDAY',
         'NTH', 'WEEKDAY'
       )
       or component_value = ''
       or rule_values ? component_key then
      return null;
    end if;
    rule_values := rule_values || jsonb_build_object(
      component_key,
      component_value
    );
  end loop;

  frequency := rule_values ->> 'FREQ';
  if frequency not in (
       'DAILY', 'WEEKLY', 'MONTHLY', 'NTHWEEKDAY', 'WEEKDAYS'
     ) then
    return null;
  end if;
  if (rule_values ? 'COUNT') = (rule_values ? 'UNTIL') then
    return null;
  end if;

  if rule_values ? 'INTERVAL' then
    component_value := rule_values ->> 'INTERVAL';
    if component_value !~ '^[1-9][0-9]{0,9}$' then
      return null;
    end if;
    interval_value := component_value::bigint;
    if interval_value > 2147483647 then
      return null;
    end if;
  end if;

  if rule_values ? 'COUNT' then
    component_value := rule_values ->> 'COUNT';
    if component_value !~ '^[1-9][0-9]{0,9}$' then
      return null;
    end if;
    count_value := component_value::bigint;
    if count_value > 2147483647 then
      return null;
    end if;
  end if;

  if rule_values ? 'BYDAY' then
    component_value := rule_values ->> 'BYDAY';
    if component_value !~ '^[1-7](,[1-7])*$' then
      return null;
    end if;
    foreach weekday_text in array string_to_array(component_value, ',') loop
      weekday_value := weekday_text::bigint;
      if weekday_value = any(by_weekdays) then
        return null;
      end if;
      by_weekdays := array_append(by_weekdays, weekday_value::integer);
    end loop;
    select array_agg(day order by day)
      into by_weekdays
    from unnest(by_weekdays) as days(day);
  end if;

  if rule_values ? 'MONTHDAY' then
    component_value := rule_values ->> 'MONTHDAY';
    if component_value !~ '^[1-9][0-9]{0,9}$' then
      return null;
    end if;
    month_day_value := component_value::bigint;
    if month_day_value > 31 then
      return null;
    end if;
  end if;

  if rule_values ? 'NTH' then
    component_value := rule_values ->> 'NTH';
    if component_value !~ '^[1-9][0-9]{0,9}$' then
      return null;
    end if;
    nth_value := component_value::bigint;
    if nth_value > 5 then
      return null;
    end if;
  end if;

  if rule_values ? 'WEEKDAY' then
    component_value := rule_values ->> 'WEEKDAY';
    if component_value !~ '^[1-9][0-9]{0,9}$' then
      return null;
    end if;
    weekday_selector_value := component_value::bigint;
    if weekday_selector_value > 7 then
      return null;
    end if;
  end if;

  if frequency <> 'WEEKLY' and rule_values ? 'BYDAY' then
    return null;
  end if;
  if frequency <> 'MONTHLY' and rule_values ? 'MONTHDAY' then
    return null;
  end if;
  if frequency <> 'NTHWEEKDAY'
     and ((rule_values ? 'NTH') or (rule_values ? 'WEEKDAY')) then
    return null;
  end if;
  if frequency = 'NTHWEEKDAY'
     and (nth_value is null or weekday_selector_value is null) then
    return null;
  end if;

  if rule_values ? 'UNTIL' then
    until_text := rule_values ->> 'UNTIL';
    if octet_length(until_text) > 128 then
      return null;
    end if;
    begin
      if until_text ~* '[t ][^ ]*(z|[+-][0-9]{2}:?[0-9]{2})$' then
        until_value := until_text::timestamptz;
      else
        until_value := (until_text::timestamp) at time zone p_timezone;
      end if;
    exception when others then
      return null;
    end;
    if until_value < p_start_at then
      return null;
    end if;
  end if;

  return jsonb_build_object(
    'frequency', frequency,
    'interval', interval_value,
    'byWeekdays', to_jsonb(by_weekdays),
    'count', count_value,
    'until', until_value,
    'monthDay', month_day_value,
    'nth', nth_value,
    'weekday', weekday_selector_value
  );
end;
$$;

revoke execute on function private.parse_personal_routine_rule(
  timestamptz, text, text
) from public, anon, authenticated;

create or replace function private.enforce_personal_event_recurrence_rule()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
begin
  -- Group event recurrence is outside the personal schedule protocol. Do not
  -- reinterpret or rewrite it here.
  if new.group_id is not null then
    return new;
  end if;

  if new.kind = 'routine' then
    if private.parse_personal_routine_rule(
         new.start_at,
         new.timezone,
         new.rrule
       ) is null then
      raise exception 'routine requires a supported finite recurrence rule'
        using errcode = '22023';
    end if;
  elsif nullif(btrim(new.rrule), '') is not null then
    raise exception 'only routines may define a recurrence rule'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists events_personal_recurrence_rule_guard on public.events;
create trigger events_personal_recurrence_rule_guard
before insert or update of kind, start_at, timezone, rrule, group_id
on public.events
for each row execute function private.enforce_personal_event_recurrence_rule();

revoke execute on function private.enforce_personal_event_recurrence_rule()
  from public, anon, authenticated;

create or replace function private.personal_routine_has_occurrence(
  p_start_at timestamptz,
  p_timezone text,
  p_rrule text,
  p_recurrence_id timestamptz
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public, private
stable
strict
as $$
declare
  parsed_rule jsonb;
  frequency text;
  interval_value bigint;
  count_value bigint;
  until_value timestamptz;
  by_weekdays integer[];
  month_day_value integer;
  nth_value integer;
  weekday_selector_value integer;
  local_start timestamp without time zone;
  local_recurrence timestamp without time zone;
  expected_time time without time zone;
  start_date date;
  recurrence_date date;
  start_weekday integer;
  recurrence_weekday integer;
  start_week date;
  recurrence_week date;
  start_month date;
  recurrence_month date;
  target_month date;
  expected_date date;
  first_expected_date date;
  last_date date;
  month_offset bigint;
  week_offset bigint;
  cycle_index bigint;
  occurrence_ordinal bigint;
  skipped_in_first_week bigint;
  weekday_position integer;
  weekday_delta integer;
  full_weeks bigint;
  remaining_days integer;
  day_offset bigint;
  matched_cycle_index bigint;
begin
  parsed_rule := private.parse_personal_routine_rule(
    p_start_at,
    p_timezone,
    p_rrule
  );
  if parsed_rule is null or p_recurrence_id < p_start_at then
    return false;
  end if;

  begin
    local_start := p_start_at at time zone p_timezone;
    local_recurrence := p_recurrence_id at time zone p_timezone;
  exception when others then
    return false;
  end;
  if local_recurrence < local_start then
    return false;
  end if;

  frequency := parsed_rule ->> 'frequency';
  interval_value := (parsed_rule ->> 'interval')::bigint;
  count_value := (parsed_rule ->> 'count')::bigint;
  until_value := (parsed_rule ->> 'until')::timestamptz;
  month_day_value := (parsed_rule ->> 'monthDay')::integer;
  nth_value := (parsed_rule ->> 'nth')::integer;
  weekday_selector_value := (parsed_rule ->> 'weekday')::integer;
  select coalesce(array_agg(day::integer order by day::integer), '{}')
    into by_weekdays
  from jsonb_array_elements_text(parsed_rule -> 'byWeekdays') as days(day);

  expected_time := case
    when frequency = 'NTHWEEKDAY' then date_trunc('second', local_start)::time
    else local_start::time
  end;
  if local_recurrence::time <> expected_time then
    return false;
  end if;
  if until_value is not null and p_recurrence_id > until_value then
    return false;
  end if;

  start_date := local_start::date;
  recurrence_date := local_recurrence::date;
  start_weekday := extract(isodow from start_date)::integer;
  recurrence_weekday := extract(isodow from recurrence_date)::integer;

  case frequency
    when 'DAILY' then
      day_offset := recurrence_date - start_date;
      if day_offset < 0 or day_offset % interval_value <> 0 then
        return false;
      end if;
      occurrence_ordinal := day_offset / interval_value + 1;

    when 'WEEKLY' then
      if cardinality(by_weekdays) = 0 then
        by_weekdays := array[start_weekday];
      end if;
      if not (recurrence_weekday = any(by_weekdays)) then
        return false;
      end if;
      start_week := start_date - (start_weekday - 1);
      recurrence_week := recurrence_date - (recurrence_weekday - 1);
      week_offset := (recurrence_week - start_week) / 7;
      if week_offset < 0 or week_offset % interval_value <> 0 then
        return false;
      end if;
      cycle_index := week_offset / interval_value;
      select count(*) into skipped_in_first_week
      from unnest(by_weekdays) as weekdays(day)
      where day < start_weekday;
      weekday_position := array_position(by_weekdays, recurrence_weekday);
      occurrence_ordinal := cycle_index * cardinality(by_weekdays)
        - skipped_in_first_week + weekday_position;

    when 'MONTHLY' then
      month_offset := (
        (extract(year from recurrence_date)::bigint -
          extract(year from start_date)::bigint) * 12
        + extract(month from recurrence_date)::bigint -
          extract(month from start_date)::bigint
      );
      if month_offset < 0 or month_offset % interval_value <> 0 then
        return false;
      end if;
      recurrence_month := date_trunc('month', recurrence_date)::date;
      last_date := (recurrence_month + interval '1 month - 1 day')::date;
      expected_date := make_date(
        extract(year from recurrence_month)::integer,
        extract(month from recurrence_month)::integer,
        least(
          coalesce(month_day_value, extract(day from start_date)::integer),
          extract(day from last_date)::integer
        )
      );
      if recurrence_date <> expected_date then
        return false;
      end if;
      start_month := date_trunc('month', start_date)::date;
      last_date := (start_month + interval '1 month - 1 day')::date;
      first_expected_date := make_date(
        extract(year from start_month)::integer,
        extract(month from start_month)::integer,
        least(
          coalesce(month_day_value, extract(day from start_date)::integer),
          extract(day from last_date)::integer
        )
      );
      occurrence_ordinal := month_offset / interval_value + 1
        - case when first_expected_date < start_date then 1 else 0 end;

    when 'NTHWEEKDAY' then
      start_month := date_trunc('month', start_date)::date;
      recurrence_month := date_trunc('month', recurrence_date)::date;
      matched_cycle_index := null;
      for target_month in
        select recurrence_month
        union all
        select (recurrence_month - interval '1 month')::date
      loop
        month_offset := (
          (extract(year from target_month)::bigint -
            extract(year from start_month)::bigint) * 12
          + extract(month from target_month)::bigint -
            extract(month from start_month)::bigint
        );
        if month_offset >= 0 and month_offset % interval_value = 0 then
          weekday_delta := mod(
            weekday_selector_value -
              extract(isodow from target_month)::integer + 7,
            7
          );
          expected_date := target_month + weekday_delta + 7 * (nth_value - 1);
          if expected_date = recurrence_date then
            matched_cycle_index := month_offset / interval_value;
            exit;
          end if;
        end if;
      end loop;
      if matched_cycle_index is null then
        return false;
      end if;
      weekday_delta := mod(
        weekday_selector_value - extract(isodow from start_month)::integer + 7,
        7
      );
      first_expected_date := start_month + weekday_delta + 7 * (nth_value - 1);
      occurrence_ordinal := matched_cycle_index + 1
        - case when first_expected_date < start_date then 1 else 0 end;

    when 'WEEKDAYS' then
      if recurrence_weekday > 5 then
        return false;
      end if;
      day_offset := recurrence_date - start_date;
      if day_offset < 0 then
        return false;
      end if;
      full_weeks := day_offset / 7;
      remaining_days := (day_offset % 7)::integer;
      occurrence_ordinal := full_weeks * 5;
      for loop_offset in 0..remaining_days loop
        if extract(isodow from start_date + loop_offset)::integer <= 5 then
          occurrence_ordinal := occurrence_ordinal + 1;
        end if;
      end loop;

    else
      return false;
  end case;

  return occurrence_ordinal >= 1
    and (count_value is null or occurrence_ordinal <= count_value);
end;
$$;

revoke execute on function private.personal_routine_has_occurrence(
  timestamptz, text, text, timestamptz
) from public, anon, authenticated;

-- Kept separate from the original multipurpose RPC so the established Phase 3
-- protocol remains byte-for-byte compatible. The mobile gateway routes only
-- event_exception mutations here; both APIs return the same ack envelope and
-- share one durable idempotency ledger and delta stream.
create or replace function public.apply_event_exception_mutation(
  p_idempotency_key text,
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
  referenced_event public.events%rowtype;
  referenced_event_id uuid;
  recurrence_at timestamptz;
  override_start timestamptz;
  override_end timestamptz;
  exception_mode text;
  override_visibility_value public.visibility_level;
  has_override boolean;
  occurrence_claimed_by_other boolean := false;
  duplicate_create_conflict boolean := false;
begin
  if bound_owner is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_idempotency_key is null
     or char_length(btrim(p_idempotency_key)) not between 1 and 200
     or p_idempotency_key <> btrim(p_idempotency_key) then
    raise exception 'invalid idempotency key' using errcode = '22023';
  end if;
  if p_entity_id is null then
    raise exception 'event exception id is required' using errcode = '22023';
  end if;
  if jsonb_typeof(bound_payload) <> 'object' then
    raise exception 'schedule mutation payload must be an object'
      using errcode = '22023';
  end if;
  if pg_catalog.pg_column_size(bound_payload) > 65536 then
    raise exception 'schedule mutation payload is too large'
      using errcode = '22023';
  end if;
  if p_operation not in ('create', 'update', 'delete') then
    raise exception 'unsupported event exception operation' using errcode = '22023';
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
  if bound_payload ? 'ownerUserId'
     and nullif(bound_payload ->> 'ownerUserId', '')::uuid
       is distinct from bound_owner then
    raise exception 'payload owner mismatch' using errcode = '42501';
  end if;
  if bound_payload ? 'id'
     and nullif(bound_payload ->> 'id', '')::uuid
       is distinct from p_entity_id then
    raise exception 'payload entity mismatch' using errcode = '22023';
  end if;

  bound_payload := bound_payload - 'ownerUserId' - 'owner_user_id';
  bound_hash := encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'entityType', 'event_exception',
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

  if p_operation <> 'delete' then
    referenced_event_id := nullif(bound_payload ->> 'eventId', '')::uuid;
    recurrence_at := nullif(bound_payload ->> 'recurrenceId', '')::timestamptz;
    exception_mode := nullif(bound_payload ->> 'mode', '');
    if referenced_event_id is null or recurrence_at is null then
      raise exception 'event and recurrence identifiers are required'
        using errcode = '22023';
    end if;
    if exception_mode not in ('cancelled', 'modified') then
      raise exception 'invalid event exception mode' using errcode = '22023';
    end if;
    select e.* into referenced_event
    from public.events e
    where e.id = referenced_event_id
      and e.owner_user_id = bound_owner
      and e.group_id is null
      and e.deleted_at is null;
    if not found then
      raise exception 'owned personal event is required' using errcode = '42501';
    end if;
    if referenced_event.kind <> 'routine'
       or nullif(btrim(referenced_event.rrule), '') is null then
      raise exception 'exceptions require an active routine' using errcode = '22023';
    end if;
    if not private.personal_routine_has_occurrence(
         referenced_event.start_at,
         referenced_event.timezone,
         referenced_event.rrule,
         recurrence_at
       ) then
      raise exception 'recurrence identifier is not a routine occurrence'
        using errcode = '22023';
    end if;

    override_start := nullif(
      bound_payload ->> 'overrideStartAt', ''
    )::timestamptz;
    override_end := nullif(
      bound_payload ->> 'overrideEndAt', ''
    )::timestamptz;
    override_visibility_value := nullif(
      bound_payload ->> 'overrideVisibility', ''
    )::public.visibility_level;
    has_override := override_start is not null
      or override_end is not null
      or nullif(btrim(bound_payload ->> 'overrideTitle'), '') is not null
      or nullif(btrim(bound_payload ->> 'overrideLocation'), '') is not null
      or nullif(btrim(bound_payload ->> 'overrideDescription'), '') is not null
      or override_visibility_value is not null;
    if exception_mode = 'cancelled' and has_override then
      raise exception 'cancelled occurrence cannot carry overrides'
        using errcode = '22023';
    end if;
    if exception_mode = 'modified' and not has_override then
      raise exception 'modified occurrence requires an override'
        using errcode = '22023';
    end if;
    if exception_mode = 'modified' and coalesce(
      override_end,
      coalesce(override_start, recurrence_at) +
        (referenced_event.end_at - referenced_event.start_at)
    ) <= coalesce(override_start, recurrence_at) then
      raise exception 'event exception time range is invalid'
        using errcode = '22023';
    end if;

    -- Different offline clients use different idempotency keys, so serialize
    -- the occurrence identity as well as each request key. This makes the
    -- partial active-recurrence index a backstop rather than a raw unique
    -- violation surface.
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        bound_owner::text || ':' || referenced_event_id::text || ':' ||
          to_char(
            recurrence_at at time zone 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS.US'
          ),
        0
      )
    );
    select exists (
      select 1
      from public.event_exceptions x
      where x.event_id = referenced_event_id
        and x.recurrence_id = recurrence_at
        and x.deleted_at is null
        and x.id <> p_entity_id
    ) into occurrence_claimed_by_other;
  end if;

  if p_operation = 'create' then
    if occurrence_claimed_by_other then
      -- Persist the losing client entity as a tombstone. The ACK can therefore
      -- keep the requested entity identity and the normal sync resolver can
      -- apply a server-wins delete without retrying a unique violation.
      insert into public.event_exceptions (
        id, owner_user_id, event_id, recurrence_id, mode, created_by,
        deleted_at
      ) values (
        p_entity_id,
        bound_owner,
        referenced_event_id,
        recurrence_at,
        exception_mode,
        bound_owner,
        now()
      ) on conflict (id) do nothing;
      get diagnostics affected = row_count;
      duplicate_create_conflict := true;
    else
      insert into public.event_exceptions (
        id, owner_user_id, event_id, recurrence_id, mode,
        override_start_at, override_end_at, override_title, override_location,
        override_description, override_visibility, created_by
      ) values (
        p_entity_id,
        bound_owner,
        referenced_event_id,
        recurrence_at,
        exception_mode,
        case when exception_mode = 'modified' then override_start else null end,
        case when exception_mode = 'modified' then override_end else null end,
        case when exception_mode = 'modified'
          then nullif(btrim(bound_payload ->> 'overrideTitle'), '') else null end,
        case when exception_mode = 'modified'
          then nullif(btrim(bound_payload ->> 'overrideLocation'), '') else null end,
        case when exception_mode = 'modified'
          then nullif(btrim(bound_payload ->> 'overrideDescription'), '') else null end,
        case when exception_mode = 'modified'
          then override_visibility_value else null end,
        bound_owner
      ) on conflict (id) do nothing;
      get diagnostics affected = row_count;
    end if;
  elsif p_operation = 'update' then
    update public.event_exceptions
    set event_id = referenced_event_id,
        recurrence_id = recurrence_at,
        mode = exception_mode,
        override_start_at = case
          when exception_mode = 'modified' then override_start else null end,
        override_end_at = case
          when exception_mode = 'modified' then override_end else null end,
        override_title = case when exception_mode = 'modified'
          then nullif(btrim(bound_payload ->> 'overrideTitle'), '') else null end,
        override_location = case when exception_mode = 'modified'
          then nullif(btrim(bound_payload ->> 'overrideLocation'), '') else null end,
        override_description = case when exception_mode = 'modified'
          then nullif(btrim(bound_payload ->> 'overrideDescription'), '') else null end,
        override_visibility = case
          when exception_mode = 'modified'
            then override_visibility_value else null end,
        deleted_at = null
    where id = p_entity_id
      and owner_user_id = bound_owner
      and deleted_at is null
      and version = p_base_version
      and not occurrence_claimed_by_other;
    get diagnostics affected = row_count;
  else
    update public.event_exceptions
    set deleted_at = now()
    where id = p_entity_id
      and owner_user_id = bound_owner
      and deleted_at is null
      and version = p_base_version;
    get diagnostics affected = row_count;
  end if;

  outcome := case
    when duplicate_create_conflict then 'conflict'
    when affected = 1 then 'applied'
    else 'conflict'
  end;
  select
    l.change_cursor,
    l.server_version,
    l.deleted_at,
    private.schedule_change_payload(
      bound_owner,
      'event_exception',
      p_entity_id,
      l.change_cursor
    )
    into current_cursor, current_version, current_deleted_at, current_change
  from private.schedule_change_log l
  where l.owner_user_id = bound_owner
    and l.entity_type = 'event_exception'
    and l.entity_id = p_entity_id
  order by l.change_cursor desc
  limit 1;
  if not found then
    raise exception 'event exception is unavailable' using errcode = '42501';
  end if;
  result := jsonb_build_object(
    'outcome', outcome,
    'entity_type', 'event_exception',
    'entity_id', p_entity_id,
    'operation', p_operation,
    'server_version', current_version,
    'change_cursor', current_cursor,
    'deleted_at', current_deleted_at,
    'replayed', false,
    'change', current_change
  );
  insert into private.schedule_mutation_receipts (
    owner_user_id, idempotency_key, request_hash, response
  ) values (
    bound_owner, p_idempotency_key, bound_hash, result
  );
  return result;
end;
$$;

revoke execute on function private.record_schedule_change()
  from public, anon, authenticated;
revoke execute on function public.apply_event_exception_mutation(
  text, uuid, text, bigint, jsonb
) from public, anon;
grant execute on function public.apply_event_exception_mutation(
  text, uuid, text, bigint, jsonb
) to authenticated;

commit;
