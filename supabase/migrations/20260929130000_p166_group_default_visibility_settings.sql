begin;

create or replace function public.get_group_default_visibility(p_group_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  visibility text;
begin
  if actor is null or not private.group_member(p_group_id, actor) then
    raise exception 'group access denied' using errcode = '42501';
  end if;

  select g.default_visibility::text
    into visibility
    from public.groups g
    where g.id = p_group_id and g.deleted_at is null;

  if not found then
    raise exception 'group access denied' using errcode = '42501';
  end if;
  return visibility;
end;
$$;

create or replace function public.set_group_default_visibility(
  p_group_id uuid,
  p_default_visibility text,
  p_operation_id uuid
)
returns table(group_id uuid, default_visibility text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor uuid := auth.uid();
  request_hash text;
  receipt jsonb;
  stored_visibility text;
begin
  if actor is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_default_visibility is null or p_default_visibility not in
     ('PRIVATE', 'BUSY_ONLY', 'TITLE_ONLY', 'FULL') then
    raise exception 'invalid group visibility' using errcode = '22023';
  end if;
  if not private.group_admin(p_group_id, actor) then
    raise exception 'admin required' using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('group:' || p_group_id::text, 9010)
  );

  select g.default_visibility::text
    into stored_visibility
    from public.groups g
    where g.id = p_group_id and g.deleted_at is null
    for update;
  if not found then
    raise exception 'admin required' using errcode = '42501';
  end if;

  request_hash := pg_catalog.encode(
    extensions.digest(
      pg_catalog.jsonb_build_object(
        'group_id', p_group_id,
        'default_visibility', p_default_visibility
      )::text,
      'sha256'
    ),
    'hex'
  );
  receipt := private.group_lock(
    actor, p_operation_id, 'set_group_default_visibility', request_hash
  );

  if receipt is null then
    update public.groups g
      set default_visibility = p_default_visibility::public.visibility_level
      where g.id = p_group_id and g.deleted_at is null
      returning g.default_visibility::text into stored_visibility;

    receipt := pg_catalog.jsonb_build_object(
      'group_id', p_group_id,
      'default_visibility', stored_visibility
    );
    perform private.group_record(
      actor, p_operation_id, 'set_group_default_visibility', request_hash,
      receipt
    );
  end if;

  return query select p_group_id, stored_visibility;
end;
$$;

revoke all on function public.get_group_default_visibility(uuid)
  from public, anon, service_role;
grant execute on function public.get_group_default_visibility(uuid)
  to authenticated;
revoke all on function public.set_group_default_visibility(uuid, text, uuid)
  from public, anon, service_role;
grant execute on function public.set_group_default_visibility(uuid, text, uuid)
  to authenticated;

notify pgrst, 'reload schema';

commit;
