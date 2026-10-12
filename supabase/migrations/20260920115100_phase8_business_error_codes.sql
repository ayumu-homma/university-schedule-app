-- Business conflicts are terminal HTTP 409 responses, not serialization
-- failures. PostgREST v14.13 retries SQLSTATE 40001; deliberately raising it
-- for a stale/unauthorized intent can keep a denied request running forever.
-- Preserve the applied Phase8 definitions, ACLs, search_path and data.
do $migration$
declare
  target record;
  definition text;
  changed integer := 0;
begin
  for target in
    select p.oid, n.nspname || '.' || p.proname as name
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname || '.' || p.proname = any(array[
      'private.friend_replay_lookup',
      'public.accept_friend_request', 'public.reject_friend_request',
      'public.cancel_friend_request', 'public.unfriend',
      'public.set_friend_visibility', 'public.inherit_friend_visibility',
      'public.list_friend_visibility_rules'
    ])
  loop
    definition := pg_get_functiondef(target.oid);
    if position('errcode = ''40001''' in definition) = 0 then
      raise exception 'Unexpected Phase8 function definition: %', target.name;
    end if;
    execute replace(definition, 'errcode = ''40001''', 'errcode = ''PT409''');
    changed := changed + 1;
  end loop;
  if changed <> 8 then
    raise exception 'Expected eight Phase8 conflict functions, found %', changed;
  end if;
end;
$migration$;

notify pgrst, 'reload schema';
