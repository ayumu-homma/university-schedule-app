-- Allow owners to change inheritance for their own personal calendars.
-- Direct authenticated table updates remain revoked, and group calendars use
-- their separate group visibility controls.
create or replace function public.set_personal_calendar_default_visibility(
  p_calendar_id uuid,
  p_visibility public.visibility_level
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  caller_id uuid := auth.uid();
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  update public.calendars as c
  set default_visibility = p_visibility
  where c.id = p_calendar_id
    and c.owner_user_id = caller_id
    and c.group_id is null;

  if not found then
    raise exception 'calendar is unavailable' using errcode = '42501';
  end if;
end;
$$;

revoke all on function public.set_personal_calendar_default_visibility(
  uuid, public.visibility_level
) from public, anon;
grant execute on function public.set_personal_calendar_default_visibility(
  uuid, public.visibility_level
) to authenticated;
