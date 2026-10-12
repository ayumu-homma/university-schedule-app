-- FRIEND-01 bounded username discovery. Usernames are opt-in, private by
-- default, and canonical ASCII identifiers. Lookup never exposes a directory.

do $$
begin
  if exists (
    select 1 from public.profiles p
    where p.username is not null
      and p.username !~ '^[a-z0-9_]{3,32}$'
  ) then
    raise exception 'existing profile usernames are not canonical ASCII identifiers';
  end if;
  if exists (select 1 from public.profiles p where p.searchable_by_username) then
    -- Existing values cannot be promoted into public discovery implicitly.
    raise exception 'existing username discovery opt-ins require explicit review';
  end if;
end;
$$;

alter table public.profiles
  add constraint profiles_username_canonical_check
    check (username is null or username ~ '^[a-z0-9_]{3,32}$'),
  add constraint profiles_username_opt_in_requires_username_check
    check (not searchable_by_username or username is not null);

-- Fail safely if legacy rows contain case-only collisions; do not rewrite them.
create unique index profiles_username_casefold_uidx
  on public.profiles ((lower(username) collate "C"))
  where username is not null;

create or replace function private.guard_profile_username_discovery()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  if new.username is not null
     and (new.username !~ '^[a-z0-9_]{3,32}$'
          or new.username <> lower(new.username)) then
    raise exception 'username must be normalized lowercase ASCII'
      using errcode = '22023';
  end if;
  if new.searchable_by_username and new.username is null then
    raise exception 'username discovery requires a username'
      using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_guard_username_discovery on public.profiles;
create trigger profiles_guard_username_discovery
before insert or update of username, searchable_by_username
on public.profiles
for each row execute function private.guard_profile_username_discovery();

revoke execute on function private.guard_profile_username_discovery() from public, anon, authenticated, service_role;

create or replace function public.set_my_friend_username(
  p_username text,
  p_searchable boolean
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
volatile
as $$
declare
  actor uuid := auth.uid();
  clean_username text := lower(btrim(coalesce(p_username, '')));
  profile public.profiles%rowtype;
begin
  if actor is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_searchable is null then
    raise exception 'discovery choice is required' using errcode = '22023';
  end if;
  if clean_username = '' then clean_username := null; end if;
  if clean_username is not null
     and clean_username !~ '^[a-z0-9_]{3,32}$' then
    raise exception 'username must be 3 to 32 ASCII letters, digits, or underscores'
      using errcode = '22023';
  end if;
  if p_searchable and clean_username is null then
    raise exception 'username discovery requires a username' using errcode = '22023';
  end if;

  update public.profiles p
  set username = clean_username,
      searchable_by_username = p_searchable
  where p.user_id = actor and p.deleted_at is null
  returning p.* into profile;
  if not found then
    raise exception 'profile is unavailable' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'username', profile.username,
    'searchable_by_username', profile.searchable_by_username
  );
end;
$$;

create or replace function public.get_my_friend_username()
returns jsonb
language sql
security invoker
set search_path = ''
stable
as $$
  select jsonb_build_object(
    'username', p.username,
    'searchable_by_username', p.searchable_by_username
  )
  from public.profiles p
  where p.user_id = auth.uid() and p.deleted_at is null;
$$;

create or replace function public.find_friend_by_username(p_username text)
returns table(user_id uuid, username text, display_name text)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  actor uuid := auth.uid();
  clean_username text := lower(btrim(coalesce(p_username, '')));
begin
  if actor is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if clean_username !~ '^[a-z0-9_]{3,32}$' then return; end if;

  return query
  select p.user_id, p.username, p.display_name
  from public.profiles p
  where p.username = clean_username
    and p.searchable_by_username
    and p.deleted_at is null
    and p.user_id <> actor
    and not private.friend_is_blocked(actor, p.user_id)
  limit 1;
end;
$$;

create or replace function public.request_friend_by_username(
  p_target_user_id uuid,
  p_shown_username text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
volatile
as $$
declare
  actor uuid := auth.uid();
  clean_username text := lower(btrim(coalesce(p_shown_username, '')));
  request_hash text;
  prior jsonb;
  actor_profile public.profiles%rowtype;
  target_profile public.profiles%rowtype;
  friendship public.friendships%rowtype;
  response jsonb;
begin
  if actor is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if p_operation_id is null or p_target_user_id is null
     or p_target_user_id = actor
     or clean_username !~ '^[a-z0-9_]{3,32}$'
     or p_shown_username is distinct from clean_username then
    raise exception 'friend username target is unavailable' using errcode = '42501';
  end if;

  request_hash := encode(extensions.digest(
    p_target_user_id::text || ':' || clean_username, 'sha256'), 'hex');
  prior := private.friend_replay_lookup(
    actor, p_operation_id, 'request_friend_by_username', request_hash);

  perform private.lock_friend_pair(actor, p_target_user_id);

  -- Lock profiles in stable order so opt-out/rename and request confirmation
  -- serialize, while the pair lock serializes this request against blocking.
  perform p.user_id
  from public.profiles p
  where p.user_id in (actor, p_target_user_id)
  order by p.user_id
  for update;
  select p.* into actor_profile from public.profiles p where p.user_id = actor;
  select p.* into target_profile from public.profiles p where p.user_id = p_target_user_id;

  if actor_profile.user_id is null or actor_profile.deleted_at is not null
     or target_profile.user_id is null or target_profile.deleted_at is not null
     or not target_profile.searchable_by_username
     or private.friend_is_blocked(actor, p_target_user_id) then
    raise exception 'friend username target is unavailable' using errcode = '42501';
  end if;
  if target_profile.username is distinct from clean_username then
    raise exception 'friend username changed after confirmation' using errcode = 'PT409';
  end if;

  select f.* into friendship
  from public.friendships f
  where least(f.requester_user_id, f.addressee_user_id) = least(actor, p_target_user_id)
    and greatest(f.requester_user_id, f.addressee_user_id) = greatest(actor, p_target_user_id)
  for update;

  if prior is not null then
    if not found
       or friendship.id is distinct from (prior->>'friendship_id')::uuid
       or friendship.incarnation is distinct from (prior->>'incarnation')::uuid
       or friendship.status not in ('pending', 'accepted') then
      raise exception 'friend request receipt is stale' using errcode = 'PT409';
    end if;
    return jsonb_build_object(
      'friendship_id', friendship.id,
      'status', friendship.status,
      'requester_user_id', friendship.requester_user_id,
      'addressee_user_id', friendship.addressee_user_id,
      'incarnation', friendship.incarnation,
      'revision', friendship.revision
    );
  end if;

  if found and friendship.status in ('pending', 'accepted') then
    -- Preserve either direction of pending request and accepted relationships.
    null;
  elsif found and friendship.status in ('rejected', 'blocked') then
    update public.friendships f
    set requester_user_id = actor,
        addressee_user_id = p_target_user_id,
        status = 'pending',
        incarnation = gen_random_uuid(),
        revision = f.revision + 1,
        updated_at = now()
    where f.id = friendship.id
    returning f.* into friendship;
  else
    insert into public.friendships(requester_user_id, addressee_user_id, status)
    values (actor, p_target_user_id, 'pending')
    returning * into friendship;
  end if;

  response := jsonb_build_object(
    'friendship_id', friendship.id,
    'status', friendship.status,
    'requester_user_id', friendship.requester_user_id,
    'addressee_user_id', friendship.addressee_user_id,
    'incarnation', friendship.incarnation,
    'revision', friendship.revision
  );
  perform private.bump_friend_schedule_revision(actor);
  perform private.bump_friend_schedule_revision(p_target_user_id);
  perform private.friend_replay_record(
    actor, p_operation_id, 'request_friend_by_username', request_hash, response);
  return response;
end;
$$;

revoke execute on function public.set_my_friend_username(text, boolean) from public, anon, service_role;
revoke execute on function public.get_my_friend_username() from public, anon, service_role;
revoke execute on function public.find_friend_by_username(text) from public, anon, service_role;
revoke execute on function public.request_friend_by_username(uuid, text, uuid) from public, anon, service_role;
grant execute on function public.set_my_friend_username(text, boolean) to authenticated;
grant execute on function public.get_my_friend_username() to authenticated;
grant execute on function public.find_friend_by_username(text) to authenticated;
grant execute on function public.request_friend_by_username(uuid, text, uuid) to authenticated;
