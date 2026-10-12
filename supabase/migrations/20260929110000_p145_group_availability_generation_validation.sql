-- Keep availability validation on the same generation contract as the query.
-- The previous validator omitted group-event moderation state, so a valid
-- query could be rejected immediately after find_group_availability.
begin;

create or replace function public.validate_group_availability(
  p_group_id uuid,
  p_member_ids uuid[],
  p_generation text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = pg_catalog, public, private
as $$
declare
  actor uuid := auth.uid();
  member_id uuid;
  current_generation text;
begin
  if actor is null or p_member_ids is null or not (actor = any(p_member_ids)) then
    raise exception 'availability validation denied' using errcode = '42501';
  end if;

  if not private.group_member(p_group_id, actor) then
    return jsonb_build_object('valid', false, 'generation', null);
  end if;

  foreach member_id in array p_member_ids loop
    if not private.group_member(p_group_id, member_id)
       or private.is_blocked(member_id) then
      return jsonb_build_object('valid', false, 'generation', null);
    end if;
  end loop;

  current_generation := private.phase15_group_availability_generation(
    p_group_id,
    p_member_ids
  );
  return jsonb_build_object(
    'valid', current_generation = p_generation,
    'generation', current_generation
  );
end;
$$;

revoke all on function public.validate_group_availability(uuid, uuid[], text)
  from public, anon;
grant execute on function public.validate_group_availability(uuid, uuid[], text)
  to authenticated;

commit;
