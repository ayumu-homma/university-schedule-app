begin;

-- Keep the authoritative exam range invariant in the database. The mobile
-- client validates this too, but offline payloads are ultimately accepted by
-- the schedule mutation RPC and must not be able to create an invalid row.
alter table public.exams
  add constraint exams_end_at_after_start_check check (end_at > start_at);

-- `apply_schedule_mutation` is the personal-schedule protocol. Its events
-- table is shared with derived and future group scheduling, so enforce the
-- personal kind boundary alongside the existing timezone and recurrence guard
-- rather than narrowing the table-wide enum/check constraint.
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

  if new.kind not in ('normal', 'routine') then
    raise exception 'personal events must be normal or routine'
      using errcode = '22023';
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
