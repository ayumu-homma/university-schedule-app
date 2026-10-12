begin;

-- Personal schedules use a fixed civil timezone. Keep group events outside
-- this contract because their timezone policy is owned by group scheduling.
-- This replaces the existing recurrence guard rather than adding a second
-- trigger, so recurrence validation and timezone validation remain atomic.
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

  if new.timezone is distinct from 'Asia/Tokyo' then
    raise exception 'personal events must use Asia/Tokyo' using errcode = '22023';
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

revoke execute on function private.enforce_personal_event_recurrence_rule()
  from public, anon, authenticated;

commit;
