-- Apply assignment_deadline event-kind visibility without replacing the
-- Phase 15 safety wrapper around the redacted friend schedule projection.
begin;

do $migration$
declare
  v_definition text;
  v_old text := $old$
        and r.mode = 'explicit' and ((r.target_kind = 'assignment' and r.target_id = a.id)
          or r.target_kind = 'default')
$old$;
  v_new text := $new$
        and r.mode = 'explicit' and ((r.target_kind = 'assignment' and r.target_id = a.id)
          or (r.target_kind = 'event_kind' and r.target_value = 'assignment_deadline')
          or r.target_kind = 'default')
$new$;
  v_occurrences integer;
begin
  select pg_get_functiondef(
    'private.phase15_build_friend_snapshot_base(uuid,uuid,uuid,timestamptz,timestamptz,boolean)'::regprocedure
  ) into v_definition;

  v_occurrences := (
    length(v_definition) - length(replace(v_definition, v_old, ''))
  ) / length(v_old);
  if v_occurrences <> 1 then
    raise exception 'expected one assignment visibility rule in phase15 base, found %', v_occurrences;
  end if;

  execute replace(v_definition, v_old, v_new);
end;
$migration$;

revoke all on function private.phase15_build_friend_snapshot_base(uuid,uuid,uuid,timestamptz,timestamptz,boolean)
  from public, anon, authenticated, service_role;
grant execute on function private.phase15_build_friend_snapshot_base(uuid,uuid,uuid,timestamptz,timestamptz,boolean)
  to postgres, supabase_admin;

commit;
