-- Phase 8 friend sharing. Append-only; existing schedule and identity tables
-- remain intact. All client access is through the RPCs below.

create schema if not exists private;

alter table public.friendships
  add column if not exists incarnation uuid not null default gen_random_uuid(),
  add column if not exists revision bigint not null default 1;

create unique index if not exists friendships_canonical_pair_uidx
  on public.friendships (
    least(requester_user_id, addressee_user_id),
    greatest(requester_user_id, addressee_user_id)
  );

create table if not exists public.friend_invites (
  id uuid primary key default gen_random_uuid(),
  issuer_user_id uuid not null references auth.users(id) on delete cascade,
  secret_hash text not null,
  operation_id uuid not null,
  expires_at timestamptz not null,
  claimed_by uuid references auth.users(id),
  claimed_at timestamptz,
  revoked_at timestamptz,
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  unique (issuer_user_id, operation_id),
  unique (secret_hash),
  check (expires_at <= created_at + interval '7 days'),
  check (claimed_at is null or claimed_by is not null)
);

create index if not exists friend_invites_issuer_created_idx
  on public.friend_invites (issuer_user_id, created_at desc);

create table if not exists public.friend_visibility_rules (
  id uuid primary key default gen_random_uuid(),
  friendship_id uuid not null references public.friendships(id) on delete cascade,
  relationship_incarnation uuid not null,
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  friend_user_id uuid not null references auth.users(id) on delete cascade,
  target_kind text not null check (target_kind in (
    'default', 'calendar', 'course', 'event', 'exam', 'assignment', 'event_kind'
  )),
  target_id uuid,
  target_value text,
  mode text not null check (mode in ('explicit', 'inherit')),
  visibility_level public.visibility_level,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (owner_user_id <> friend_user_id),
  check ((mode = 'inherit' and visibility_level is null)
      or (mode = 'explicit' and visibility_level is not null)),
  check (target_kind in ('default', 'event_kind') or target_value is null),
  check (target_kind = 'event_kind' or target_value is null),
  check (target_kind in ('default', 'event_kind') or target_id is not null)
);

create unique index if not exists friend_visibility_rules_key_uidx
  on public.friend_visibility_rules (
    friendship_id, relationship_incarnation, owner_user_id, friend_user_id,
    target_kind, coalesce(target_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(target_value, '')
  );

create index if not exists friend_visibility_rules_lookup_idx
  on public.friend_visibility_rules
    (friendship_id, relationship_incarnation, owner_user_id, friend_user_id);

create table if not exists public.friend_schedule_revisions (
  owner_user_id uuid primary key references auth.users(id) on delete cascade,
  revision bigint not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists private.friend_operation_receipts (
  actor_user_id uuid not null references auth.users(id) on delete cascade,
  operation_id uuid not null,
  operation_name text not null,
  request_hash text not null,
  response jsonb not null,
  created_at timestamptz not null default now(),
  primary key (actor_user_id, operation_id)
);

alter table public.friend_invites enable row level security;
alter table public.friend_visibility_rules enable row level security;
alter table public.friend_schedule_revisions enable row level security;

revoke all on public.friend_invites from public, anon, authenticated;
revoke all on public.friend_visibility_rules from public, anon, authenticated;
revoke all on public.friend_schedule_revisions from public, anon, authenticated;
revoke all on private.friend_operation_receipts from public, anon, authenticated;

create or replace function private.friend_replay_lookup(
  p_actor uuid, p_operation_id uuid, p_operation_name text, p_request_hash text
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, private
volatile
as $$
declare prior private.friend_operation_receipts%rowtype;
begin
  if p_operation_id is null then raise exception 'operation id is required' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('friend-op:' || p_actor::text || ':' || p_operation_id::text, 8108));
  select * into prior from private.friend_operation_receipts
  where actor_user_id = p_actor and operation_id = p_operation_id for update;
  if not found then return null; end if;
  if prior.operation_name <> p_operation_name or prior.request_hash <> p_request_hash then
    raise exception 'operation replay mismatch' using errcode = '40001';
  end if;
  return prior.response;
end;
$$;

create or replace function private.friend_replay_record(
  p_actor uuid, p_operation_id uuid, p_operation_name text,
  p_request_hash text, p_response jsonb
)
returns void
language sql security definer
set search_path = pg_catalog, public, private
volatile
as $$
  insert into private.friend_operation_receipts(actor_user_id, operation_id, operation_name, request_hash, response)
  values (p_actor, p_operation_id, p_operation_name, p_request_hash, p_response)
  on conflict (actor_user_id, operation_id) do nothing;
$$;

create or replace function private.bump_friend_schedule_revision(p_owner uuid)
returns bigint
language plpgsql
security definer
set search_path = pg_catalog, public, private
volatile
as $$
declare
  next_revision bigint;
  friend_id uuid;
begin
  if p_owner is null then return 0; end if;
  if not exists (select 1 from auth.users where id = p_owner) then return 0; end if;
  insert into public.friend_schedule_revisions(owner_user_id, revision)
  values (p_owner, 1)
  on conflict (owner_user_id) do update
    set revision = public.friend_schedule_revisions.revision + 1,
        updated_at = now()
  returning revision into next_revision;
  -- The owner may have a pending request, a removed friendship, or an open
  -- preview/detail screen.  Reuse the owner's existing private topic and send
  -- an empty friend-specific invalidation without exposing any peer identity.
  perform realtime.send('{}'::jsonb, 'friend-invalidate', 'schedule-sync:' || p_owner::text, true);
  for friend_id in
    select case when f.requester_user_id = p_owner then f.addressee_user_id else f.requester_user_id end
    from public.friendships f
    where f.status = 'accepted'
      and (f.requester_user_id = p_owner or f.addressee_user_id = p_owner)
  loop
    perform realtime.send('{}'::jsonb, 'friend-invalidate', 'schedule-sync:' || friend_id::text, true);
  end loop;
  return next_revision;
end;
$$;

create or replace function private.friend_source_revision_trigger()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private
volatile
as $$
declare
  source_owner uuid;
  target_group uuid;
begin
  if tg_table_name = 'profiles' then
    source_owner := case when tg_op = 'DELETE' then old.user_id else new.user_id end;
    perform private.bump_friend_schedule_revision(source_owner);
  elsif tg_table_name = 'period_settings' then
    source_owner := case when tg_op = 'DELETE' then old.owner_user_id else new.owner_user_id end;
    perform private.bump_friend_schedule_revision(source_owner);
  elsif tg_table_name = 'terms' then
    for source_owner in
      select distinct owner_user_id from public.user_courses
      where term_id = case when tg_op = 'DELETE' then old.id else new.id end
      union
      select case when tg_op = 'DELETE' then old.owner_user_id else new.owner_user_id end
    loop
      perform private.bump_friend_schedule_revision(source_owner);
    end loop;
  elsif tg_table_name = 'groups' then
    target_group := case when tg_op = 'DELETE' then old.id else new.id end;
    source_owner := case when tg_op = 'DELETE' then old.owner_user_id else new.owner_user_id end;
    perform private.bump_friend_schedule_revision(source_owner);
    for source_owner in
      select distinct e.owner_user_id from public.events e where e.group_id = target_group
    loop
      perform private.bump_friend_schedule_revision(source_owner);
    end loop;
  elsif tg_table_name = 'group_members' then
    target_group := case when tg_op = 'DELETE' then old.group_id else new.group_id end;
    select g.owner_user_id into source_owner from public.groups g where g.id = target_group;
    perform private.bump_friend_schedule_revision(source_owner);
    for source_owner in
      select distinct e.owner_user_id from public.events e where e.group_id = target_group
    loop
      perform private.bump_friend_schedule_revision(source_owner);
    end loop;
  elsif tg_table_name in ('user_courses', 'events', 'calendars', 'exams', 'assignments') then
    source_owner := case when tg_op = 'DELETE' then old.owner_user_id else new.owner_user_id end;
    perform private.bump_friend_schedule_revision(source_owner);
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists phase8_user_courses_revision on public.user_courses;
create trigger phase8_user_courses_revision after insert or update or delete
on public.user_courses for each row execute function private.friend_source_revision_trigger();
drop trigger if exists phase8_events_revision on public.events;
create trigger phase8_events_revision after insert or update or delete
on public.events for each row execute function private.friend_source_revision_trigger();
drop trigger if exists phase8_calendars_revision on public.calendars;
create trigger phase8_calendars_revision after insert or update or delete
on public.calendars for each row execute function private.friend_source_revision_trigger();
drop trigger if exists phase8_groups_revision on public.groups;
create trigger phase8_groups_revision after insert or update or delete
on public.groups for each row execute function private.friend_source_revision_trigger();
drop trigger if exists phase8_group_members_revision on public.group_members;
create trigger phase8_group_members_revision after insert or update or delete
on public.group_members for each row execute function private.friend_source_revision_trigger();
drop trigger if exists phase8_profiles_revision on public.profiles;
create trigger phase8_profiles_revision after update or delete
on public.profiles for each row execute function private.friend_source_revision_trigger();
drop trigger if exists phase8_terms_revision on public.terms;
create trigger phase8_terms_revision after insert or update or delete
on public.terms for each row execute function private.friend_source_revision_trigger();
drop trigger if exists phase8_period_settings_revision on public.period_settings;
create trigger phase8_period_settings_revision after insert or update or delete
on public.period_settings for each row execute function private.friend_source_revision_trigger();
drop trigger if exists phase8_exams_revision on public.exams;
create trigger phase8_exams_revision after insert or update or delete
on public.exams for each row execute function private.friend_source_revision_trigger();
drop trigger if exists phase8_assignments_revision on public.assignments;
create trigger phase8_assignments_revision after insert or update or delete
on public.assignments for each row execute function private.friend_source_revision_trigger();

create or replace function private.lock_friend_pair(p_left uuid, p_right uuid)
returns void
language sql
security definer
set search_path = pg_catalog, public, private
volatile
as $$
  select pg_advisory_xact_lock(
    hashtextextended(
      least(p_left::text, p_right::text) || ':' || greatest(p_left::text, p_right::text),
      8108
    )
  );
$$;

create or replace function private.friend_is_blocked(p_viewer uuid, p_owner uuid)
returns boolean
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select exists (
    select 1 from public.blocks b
    where (b.blocker_user_id = p_viewer and b.blocked_user_id = p_owner)
       or (b.blocker_user_id = p_owner and b.blocked_user_id = p_viewer)
  );
$$;

create or replace function private.friend_is_group_member(p_viewer uuid, p_group uuid)
returns boolean
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select exists (
    select 1 from public.groups g
    left join public.group_members gm on gm.group_id = g.id and gm.user_id = p_viewer
    where g.id = p_group and g.deleted_at is null
      and (g.owner_user_id = p_viewer or gm.user_id is not null)
  );
$$;

create or replace function private.friend_revision(p_owner uuid)
returns bigint
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select coalesce((select revision from public.friend_schedule_revisions where owner_user_id = p_owner), 0);
$$;

create or replace function private.restrict_friend_visibility(
  p_source public.visibility_level,
  p_cap public.visibility_level
)
returns public.visibility_level
language sql
immutable
as $$
  select case least(
    case p_source when 'PRIVATE' then 0 when 'BUSY_ONLY' then 1 when 'TITLE_ONLY' then 2 else 3 end,
    case p_cap when 'PRIVATE' then 0 when 'BUSY_ONLY' then 1 when 'TITLE_ONLY' then 2 else 3 end
  )
    when 0 then 'PRIVATE'::public.visibility_level
    when 1 then 'BUSY_ONLY'::public.visibility_level
    when 2 then 'TITLE_ONLY'::public.visibility_level
    else 'FULL'::public.visibility_level
  end;
$$;

create or replace function private.resolve_visible_events_for(
  p_viewer uuid,
  p_range_start timestamptz,
  p_range_end timestamptz
)
returns table (
  event_id uuid,
  owner_user_id uuid,
  start_at timestamptz,
  end_at timestamptz,
  visibility_level public.visibility_level,
  title text,
  location text,
  description text,
  kind text,
  group_id uuid
)
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  with candidate as materialized (
    select
      e.id as event_id,
      e.owner_user_id,
      e.start_at,
      e.end_at,
      e.title,
      e.location,
      e.description,
      e.kind,
      e.group_id,
      e.visibility_level as event_visibility,
      c.default_visibility as calendar_visibility,
      p.default_visibility as owner_default_visibility,
      g.default_visibility as group_default_visibility,
      gm.visibility_level as member_visibility,
      f.id as friendship_id,
      f.incarnation as friendship_incarnation,
      fr.visibility_level as friend_rule_visibility,
      fr.mode as friend_rule_mode,
      fr.target_kind as friend_rule_kind
    from public.events e
    join public.calendars c on c.id = e.calendar_id and c.deleted_at is null
    join public.profiles p on p.user_id = e.owner_user_id and p.deleted_at is null
    left join public.groups g on g.id = e.group_id and g.deleted_at is null
    left join public.group_members gm
      on gm.group_id = e.group_id and gm.user_id = p_viewer
    left join public.friendships f
      on f.status = 'accepted'
     and ((f.requester_user_id = p_viewer and f.addressee_user_id = e.owner_user_id)
       or (f.addressee_user_id = p_viewer and f.requester_user_id = e.owner_user_id))
    left join lateral (
      select r.visibility_level, r.mode, r.target_kind
      from public.friend_visibility_rules r
      where f.id is not null
        and r.friendship_id = f.id
        and r.relationship_incarnation = f.incarnation
        and r.owner_user_id = e.owner_user_id
        and r.friend_user_id = p_viewer
        and r.mode = 'explicit'
        and (
          (r.target_kind = 'event' and r.target_id = e.id)
          or (r.target_kind = 'calendar' and r.target_id = e.calendar_id)
          or (r.target_kind = 'event_kind' and r.target_value = e.kind)
          or (r.target_kind = 'default' and r.target_id is null)
        )
      order by case
        when r.target_kind = 'event' then 1
        when r.target_kind = 'calendar' then 2
        when r.target_kind = 'event_kind' then 3
        else 4
      end
      limit 1
    ) fr on true
    where e.deleted_at is null
      and e.start_at < p_range_end
      and e.end_at > p_range_start
      and (
        e.owner_user_id = p_viewer
        or (
          not private.friend_is_blocked(p_viewer, e.owner_user_id)
          and (
            (e.group_id is not null and private.friend_is_group_member(p_viewer, e.group_id))
            or (e.group_id is null and f.id is not null)
          )
        )
      )
  ), resolved as (
    select c.*,
      case
        when c.owner_user_id = p_viewer then 'FULL'::public.visibility_level
        when private.friend_is_blocked(p_viewer, c.owner_user_id) then 'PRIVATE'::public.visibility_level
        when c.event_visibility = 'PRIVATE'::public.visibility_level then 'PRIVATE'::public.visibility_level
        when c.group_id is null and c.friendship_id is not null
          then private.restrict_friend_visibility(
            coalesce(c.event_visibility, c.calendar_visibility, c.owner_default_visibility, 'PRIVATE'::public.visibility_level),
            coalesce(c.friend_rule_visibility, 'PRIVATE'::public.visibility_level)
          )
        when c.event_visibility is not null then c.event_visibility
        when c.group_id is not null then coalesce(
          c.member_visibility, c.group_default_visibility,
          c.owner_default_visibility, 'PRIVATE'::public.visibility_level
        )
        else coalesce(
          case
            when c.friend_rule_mode = 'explicit' then c.friend_rule_visibility
            when c.friend_rule_mode = 'inherit'
              and c.friend_rule_kind in ('event', 'event_kind')
              then c.calendar_visibility
            when c.friend_rule_mode = 'inherit' then c.owner_default_visibility
            else null
          end,
          c.calendar_visibility,
          c.owner_default_visibility,
          'PRIVATE'::public.visibility_level
        )
      end as resolved_visibility
    from candidate c
  )
  select
    r.event_id, r.owner_user_id, r.start_at, r.end_at,
    r.resolved_visibility,
    case
      when r.resolved_visibility = 'BUSY_ONLY' then '予定あり'
      when r.resolved_visibility in ('TITLE_ONLY', 'FULL') then r.title
      else null
    end,
    case when r.resolved_visibility = 'FULL' then r.location else null end,
    case when r.resolved_visibility = 'FULL' then r.description else null end,
    case when r.resolved_visibility in ('TITLE_ONLY', 'FULL') then r.kind else null end,
    case when r.resolved_visibility = 'FULL' then r.group_id else null end
  from resolved r
  where r.resolved_visibility <> 'PRIVATE';
$$;

create or replace function public.get_visible_events(
  viewer_id uuid,
  range_start timestamptz,
  range_end timestamptz
)
returns table (
  event_id uuid,
  owner_user_id uuid,
  start_at timestamptz,
  end_at timestamptz,
  visibility_level public.visibility_level,
  title text,
  location text,
  description text,
  kind text,
  group_id uuid
)
language plpgsql
security definer
set search_path = pg_catalog, public, private
stable
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;
  if viewer_id is distinct from auth.uid() then
    raise exception 'viewer_id must match auth.uid()' using errcode = '42501';
  end if;
  if range_end <= range_start or range_end - range_start > interval '366 days' then
    raise exception 'invalid event range' using errcode = '22023';
  end if;
  return query select * from private.resolve_visible_events_for(viewer_id, range_start, range_end);
end;
$$;

revoke execute on function private.resolve_visible_events_for(uuid, timestamptz, timestamptz)
  from public, anon, authenticated;
revoke execute on function public.get_visible_events(uuid, timestamptz, timestamptz)
  from public, anon;
grant execute on function public.get_visible_events(uuid, timestamptz, timestamptz)
  to authenticated;

create or replace function public.create_friend_invite(
  p_secret text,
  p_operation_id uuid,
  p_expires_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
volatile
as $$
declare
  actor uuid := auth.uid();
  v_secret_hash text;
  invite public.friend_invites%rowtype;
  response jsonb;
  prior jsonb;
  request_hash text;
  requested_expiry timestamptz := p_expires_at;
begin
  if actor is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_operation_id is null then raise exception 'operation id is required' using errcode = '22023'; end if;
  if p_secret is null or p_secret !~ '^[0-9a-fA-F]{64}$' then
    raise exception 'secret must be a 256-bit hexadecimal value' using errcode = '22023';
  end if;
  v_secret_hash := encode(extensions.digest(lower(p_secret), 'sha256'), 'hex');
  request_hash := encode(extensions.digest(jsonb_build_object(
    'secret', lower(p_secret), 'expires_at', requested_expiry
  )::text, 'sha256'), 'hex');
  prior := private.friend_replay_lookup(actor, p_operation_id, 'create_friend_invite', request_hash);
  if prior is not null then return prior || jsonb_build_object('token', lower(p_secret)); end if;

  if p_expires_at is null then p_expires_at := now() + interval '7 days'; end if;
  if p_expires_at <= now() or p_expires_at > now() + interval '7 days' then
    raise exception 'invite expiry must be within seven days' using errcode = '22023';
  end if;
  insert into public.friend_invites(issuer_user_id, secret_hash, operation_id, expires_at)
  values (actor, v_secret_hash, p_operation_id, p_expires_at)
  returning * into invite;

  response := jsonb_build_object(
    'invite_id', invite.id,
    'issuer_user_id', actor,
    'expires_at', invite.expires_at
  );
  perform private.friend_replay_record(actor, p_operation_id, 'create_friend_invite', request_hash, response);
  return response || jsonb_build_object('token', lower(p_secret));
end;
$$;

create or replace function public.preview_friend_invite(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
stable
as $$
declare
  invite public.friend_invites%rowtype;
  invite_state text;
  issuer_name text;
begin
  if p_token is null or p_token !~ '^[0-9a-fA-F]{64}$' then
    return jsonb_build_object('state', 'invalid');
  end if;
  select * into invite from public.friend_invites
  where secret_hash = encode(extensions.digest(lower(p_token), 'sha256'), 'hex');
  if not found then return jsonb_build_object('state', 'invalid'); end if;
  invite_state := case
    when invite.revoked_at is not null then 'revoked'
    when invite.accepted_at is not null then 'claimed'
    when invite.claimed_by is not null then 'claimed'
    when invite.expires_at <= now() then 'expired'
    else 'active' end;
  select display_name into issuer_name from public.profiles where user_id = invite.issuer_user_id;
  return jsonb_build_object(
    'state', invite_state, 'invite_id', invite.id,
    'issuer_user_id', invite.issuer_user_id,
    'issuer_display_name', issuer_name,
    'expires_at', invite.expires_at
  );
end;
$$;

create or replace function public.request_friend_from_invite(
  p_token text,
  p_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
volatile
as $$
declare
  actor uuid := auth.uid();
  invite public.friend_invites%rowtype;
  friendship public.friendships%rowtype;
  response jsonb;
  prior jsonb;
  v_secret_hash text;
  request_hash text;
begin
  if actor is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_operation_id is null or p_token is null or p_token !~ '^[0-9a-fA-F]{64}$' then
    raise exception 'valid token and operation id are required' using errcode = '22023';
  end if;
  request_hash := encode(extensions.digest(lower(p_token), 'sha256'), 'hex');
  prior := private.friend_replay_lookup(actor, p_operation_id, 'request_friend_from_invite', request_hash);
  if prior is not null then return prior; end if;
  v_secret_hash := encode(extensions.digest(lower(p_token), 'sha256'), 'hex');
  select i.* into invite from public.friend_invites i where i.secret_hash = v_secret_hash for update;
  if not found or invite.revoked_at is not null or invite.expires_at <= now() then
    raise exception 'invite is unavailable' using errcode = '42501';
  end if;
  if invite.issuer_user_id = actor then raise exception 'cannot invite yourself' using errcode = '22023'; end if;
  -- A claimed token is single-use.  The exact original operation is handled
  -- by the receipt lookup above; a new operation must never recreate a
  -- relationship after remove/block/reinvite.
  if invite.claimed_by is not null then
    raise exception 'invite is already claimed' using errcode = '42501';
  end if;

  perform private.lock_friend_pair(invite.issuer_user_id, actor);
  if private.friend_is_blocked(invite.issuer_user_id, actor) then
    raise exception 'blocked relationship' using errcode = '42501';
  end if;
  select * into friendship from public.friendships
  where least(requester_user_id, addressee_user_id) = least(invite.issuer_user_id, actor)
    and greatest(requester_user_id, addressee_user_id) = greatest(invite.issuer_user_id, actor)
  for update;

  if found and friendship.status = 'accepted' then
    response := jsonb_build_object('friendship_id', friendship.id, 'status', friendship.status,
      'issuer_user_id', invite.issuer_user_id, 'recipient_user_id', actor,
      'incarnation', friendship.incarnation, 'revision', friendship.revision);
  elsif found and friendship.status = 'pending'
        and friendship.requester_user_id = actor
        and friendship.addressee_user_id = invite.issuer_user_id then
    response := jsonb_build_object('friendship_id', friendship.id, 'status', friendship.status,
      'issuer_user_id', invite.issuer_user_id, 'recipient_user_id', actor,
      'incarnation', friendship.incarnation, 'revision', friendship.revision);
  elsif found then
    update public.friendships set requester_user_id = actor,
      addressee_user_id = invite.issuer_user_id, status = 'pending', incarnation = gen_random_uuid(),
      revision = friendship.revision + 1, updated_at = now()
    where id = friendship.id returning * into friendship;
    response := jsonb_build_object('friendship_id', friendship.id, 'status', friendship.status,
      'issuer_user_id', invite.issuer_user_id, 'recipient_user_id', actor,
      'incarnation', friendship.incarnation, 'revision', friendship.revision);
  else
    insert into public.friendships(requester_user_id, addressee_user_id, status)
    values (actor, invite.issuer_user_id, 'pending') returning * into friendship;
    response := jsonb_build_object('friendship_id', friendship.id, 'status', friendship.status,
      'issuer_user_id', invite.issuer_user_id, 'recipient_user_id', actor,
      'incarnation', friendship.incarnation, 'revision', friendship.revision);
  end if;
  update public.friend_invites set claimed_by = actor, claimed_at = coalesce(claimed_at, now())
  where id = invite.id;
  perform private.bump_friend_schedule_revision(invite.issuer_user_id);
  perform private.bump_friend_schedule_revision(actor);
  perform private.friend_replay_record(actor, p_operation_id, 'request_friend_from_invite', request_hash, response);
  return response;
end;
$$;

create or replace function public.list_friendships()
returns setof jsonb
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select jsonb_build_object(
    'friendship_id', f.id,
    'requester_user_id', f.requester_user_id,
    'addressee_user_id', f.addressee_user_id,
    'other_user_id', case when f.requester_user_id = auth.uid() then f.addressee_user_id else f.requester_user_id end,
    'other_display_name', p.display_name,
    'viewer_role', case when f.requester_user_id = auth.uid() then 'requester' else 'addressee' end,
    'status', f.status,
    'incarnation', f.incarnation,
    'revision', f.revision,
    'updated_at', f.updated_at
  )
  from public.friendships f
  join public.profiles p on p.user_id = case when f.requester_user_id = auth.uid() then f.addressee_user_id else f.requester_user_id end
  where auth.uid() is not null and (f.requester_user_id = auth.uid() or f.addressee_user_id = auth.uid())
  order by f.updated_at desc;
$$;

create or replace function public.list_friend_invites()
returns setof jsonb
language sql security definer
set search_path = pg_catalog, public, private stable
as $$
  select jsonb_build_object('invite_id', id, 'expires_at', expires_at,
    'claimed', claimed_by is not null, 'revoked', revoked_at is not null,
    'accepted', accepted_at is not null)
  from public.friend_invites
  where issuer_user_id = auth.uid()
  order by created_at desc;
$$;

create or replace function public.revoke_friend_invite(p_invite_id uuid, p_operation_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, private volatile
as $$
declare actor uuid := auth.uid(); changed_count integer; prior jsonb;
  request_hash text := encode(extensions.digest(coalesce(p_invite_id::text,''), 'sha256'), 'hex');
begin
  if actor is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_operation_id is null then raise exception 'operation id is required' using errcode = '22023'; end if;
  prior := private.friend_replay_lookup(actor, p_operation_id, 'revoke_friend_invite', request_hash);
  if prior is not null then return prior; end if;
  update public.friend_invites set revoked_at = now()
  where id = p_invite_id and issuer_user_id = actor and revoked_at is null;
  get diagnostics changed_count = row_count;
  if changed_count = 0 then raise exception 'invite is unavailable' using errcode = '42501'; end if;
  perform private.bump_friend_schedule_revision(actor);
  prior := jsonb_build_object('invite_id', p_invite_id, 'revoked', true);
  perform private.friend_replay_record(actor, p_operation_id, 'revoke_friend_invite', request_hash, prior);
  return prior;
end;
$$;

-- Remove the legacy direct relationship/block write surface. SECURITY DEFINER
-- RPCs above are the only client entry point; existing RLS remains enabled.
drop policy if exists friendships_party_read on public.friendships;
drop policy if exists friendships_request on public.friendships;
drop policy if exists friendships_party_update on public.friendships;
drop policy if exists blocks_self on public.blocks;
revoke all on public.friendships from public, anon, authenticated;
revoke all on public.blocks from public, anon, authenticated;

create or replace function public.accept_friend_request(
  p_friendship_id uuid, p_incarnation uuid, p_expected_revision bigint default null,
  p_operation_id uuid default null
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, private volatile
as $$
declare actor uuid := auth.uid(); f public.friendships%rowtype; response jsonb; prior jsonb; left_id uuid; right_id uuid;
  request_hash text := encode(extensions.digest(coalesce(p_friendship_id::text,'') || ':' || coalesce(p_incarnation::text,'') || ':' || coalesce(p_expected_revision::text,''), 'sha256'), 'hex');
begin
  if actor is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_operation_id is null then raise exception 'operation id is required' using errcode = '22023'; end if;
  prior := private.friend_replay_lookup(actor, p_operation_id, 'accept_friend_request', request_hash);
  if prior is not null then return prior; end if;
  select requester_user_id, addressee_user_id into left_id, right_id from public.friendships where id = p_friendship_id;
  if not found then raise exception 'stale or unauthorized friendship request' using errcode = '40001'; end if;
  perform private.lock_friend_pair(left_id, right_id);
  select * into f from public.friendships where id = p_friendship_id for update;
  if f.addressee_user_id <> actor or f.status <> 'pending'
     or f.incarnation is distinct from p_incarnation
     or (p_expected_revision is not null and f.revision <> p_expected_revision) then
    raise exception 'stale or unauthorized friendship request' using errcode = '40001';
  end if;
  update public.friendships set status = 'accepted', revision = revision + 1, updated_at = now()
  where id = f.id returning * into f;
  insert into public.friend_visibility_rules
    (friendship_id, relationship_incarnation, owner_user_id, friend_user_id, target_kind, mode, visibility_level)
  values
    (f.id, f.incarnation, f.requester_user_id, f.addressee_user_id, 'default', 'explicit', 'PRIVATE'),
    (f.id, f.incarnation, f.addressee_user_id, f.requester_user_id, 'default', 'explicit', 'PRIVATE')
  on conflict do nothing;
  update public.friend_invites set accepted_at = now()
  where issuer_user_id = actor and claimed_by = f.requester_user_id and accepted_at is null;
  perform private.bump_friend_schedule_revision(f.requester_user_id);
  perform private.bump_friend_schedule_revision(f.addressee_user_id);
  response := jsonb_build_object('friendship_id', f.id, 'status', f.status,
    'incarnation', f.incarnation, 'revision', f.revision);
  perform private.friend_replay_record(actor, p_operation_id, 'accept_friend_request', request_hash, response);
  return response;
end;
$$;

create or replace function public.reject_friend_request(
  p_friendship_id uuid, p_incarnation uuid, p_expected_revision bigint default null,
  p_operation_id uuid default null
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, private volatile
as $$
declare actor uuid := auth.uid(); f public.friendships%rowtype; prior jsonb; left_id uuid; right_id uuid;
  request_hash text := encode(extensions.digest(coalesce(p_friendship_id::text,'') || ':' || coalesce(p_incarnation::text,'') || ':' || coalesce(p_expected_revision::text,''), 'sha256'), 'hex');
begin
  if actor is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_operation_id is null then raise exception 'operation id is required' using errcode = '22023'; end if;
  prior := private.friend_replay_lookup(actor, p_operation_id, 'reject_friend_request', request_hash);
  if prior is not null then return prior; end if;
  select requester_user_id, addressee_user_id into left_id, right_id from public.friendships where id = p_friendship_id;
  if not found then raise exception 'stale or unauthorized friendship request' using errcode = '40001'; end if;
  perform private.lock_friend_pair(left_id, right_id);
  select * into f from public.friendships where id = p_friendship_id for update;
  if f.addressee_user_id <> actor or f.status <> 'pending'
     or f.incarnation is distinct from p_incarnation
     or (p_expected_revision is not null and f.revision <> p_expected_revision) then
    raise exception 'stale or unauthorized friendship request' using errcode = '40001';
  end if;
  delete from public.friend_visibility_rules where friendship_id = f.id;
  update public.friendships set status = 'rejected', incarnation = gen_random_uuid(), revision = revision + 1, updated_at = now()
  where id = f.id returning * into f;
  perform private.bump_friend_schedule_revision(f.requester_user_id);
  perform private.bump_friend_schedule_revision(f.addressee_user_id);
  prior := jsonb_build_object('friendship_id', f.id, 'status', f.status, 'incarnation', f.incarnation, 'revision', f.revision);
  perform private.friend_replay_record(actor, p_operation_id, 'reject_friend_request', request_hash, prior);
  return prior;
end;
$$;

create or replace function public.cancel_friend_request(
  p_friendship_id uuid, p_incarnation uuid, p_expected_revision bigint default null,
  p_operation_id uuid default null
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, private volatile
as $$
declare actor uuid := auth.uid(); f public.friendships%rowtype; prior jsonb; left_id uuid; right_id uuid;
  request_hash text := encode(extensions.digest(coalesce(p_friendship_id::text,'') || ':' || coalesce(p_incarnation::text,'') || ':' || coalesce(p_expected_revision::text,''), 'sha256'), 'hex');
begin
  if actor is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_operation_id is null then raise exception 'operation id is required' using errcode = '22023'; end if;
  prior := private.friend_replay_lookup(actor, p_operation_id, 'cancel_friend_request', request_hash);
  if prior is not null then return prior; end if;
  select requester_user_id, addressee_user_id into left_id, right_id from public.friendships where id = p_friendship_id;
  if not found then raise exception 'stale or unauthorized friendship request' using errcode = '40001'; end if;
  perform private.lock_friend_pair(left_id, right_id);
  select * into f from public.friendships where id = p_friendship_id for update;
  if f.requester_user_id <> actor or f.status <> 'pending'
     or f.incarnation is distinct from p_incarnation
     or (p_expected_revision is not null and f.revision <> p_expected_revision) then
    raise exception 'stale or unauthorized friendship request' using errcode = '40001';
  end if;
  delete from public.friend_visibility_rules where friendship_id = f.id;
  update public.friendships set status = 'rejected', incarnation = gen_random_uuid(), revision = revision + 1, updated_at = now()
  where id = f.id returning * into f;
  perform private.bump_friend_schedule_revision(f.requester_user_id);
  perform private.bump_friend_schedule_revision(f.addressee_user_id);
  prior := jsonb_build_object('friendship_id', f.id, 'status', f.status, 'incarnation', f.incarnation, 'revision', f.revision);
  perform private.friend_replay_record(actor, p_operation_id, 'cancel_friend_request', request_hash, prior);
  return prior;
end;
$$;

create or replace function public.unfriend(
  p_friendship_id uuid, p_incarnation uuid, p_expected_revision bigint default null,
  p_operation_id uuid default null
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, private volatile
as $$
declare actor uuid := auth.uid(); f public.friendships%rowtype; prior jsonb; left_id uuid; right_id uuid;
  request_hash text := encode(extensions.digest(coalesce(p_friendship_id::text,'') || ':' || coalesce(p_incarnation::text,'') || ':' || coalesce(p_expected_revision::text,''), 'sha256'), 'hex');
begin
  if actor is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_operation_id is null then raise exception 'operation id is required' using errcode = '22023'; end if;
  prior := private.friend_replay_lookup(actor, p_operation_id, 'unfriend', request_hash);
  if prior is not null then return prior; end if;
  select requester_user_id, addressee_user_id into left_id, right_id from public.friendships where id = p_friendship_id;
  if not found then raise exception 'stale or unauthorized friendship' using errcode = '40001'; end if;
  perform private.lock_friend_pair(left_id, right_id);
  select * into f from public.friendships where id = p_friendship_id for update;
  if (actor <> f.requester_user_id and actor <> f.addressee_user_id)
     or f.status <> 'accepted' or f.incarnation is distinct from p_incarnation
     or (p_expected_revision is not null and f.revision <> p_expected_revision) then
    raise exception 'stale or unauthorized friendship' using errcode = '40001';
  end if;
  delete from public.friend_visibility_rules where friendship_id = f.id;
  update public.friendships set status = 'rejected', incarnation = gen_random_uuid(), revision = revision + 1, updated_at = now()
  where id = f.id returning * into f;
  perform private.bump_friend_schedule_revision(f.requester_user_id);
  perform private.bump_friend_schedule_revision(f.addressee_user_id);
  prior := jsonb_build_object('friendship_id', f.id, 'status', f.status, 'incarnation', f.incarnation, 'revision', f.revision);
  perform private.friend_replay_record(actor, p_operation_id, 'unfriend', request_hash, prior);
  return prior;
end;
$$;

create or replace function public.block_user(p_user_id uuid, p_operation_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, private volatile
as $$
declare actor uuid := auth.uid(); f record; prior jsonb;
  request_hash text := encode(extensions.digest(coalesce(p_user_id::text,''), 'sha256'), 'hex');
begin
  if actor is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_operation_id is null then raise exception 'operation id is required' using errcode = '22023'; end if;
  prior := private.friend_replay_lookup(actor, p_operation_id, 'block_user', request_hash);
  if prior is not null then return prior; end if;
  if p_user_id is null or actor = p_user_id then raise exception 'invalid block target' using errcode = '22023'; end if;
  perform private.lock_friend_pair(actor, p_user_id);
  insert into public.blocks(blocker_user_id, blocked_user_id) values (actor, p_user_id) on conflict do nothing;
  for f in select * from public.friendships
    where least(requester_user_id, addressee_user_id) = least(actor, p_user_id)
      and greatest(requester_user_id, addressee_user_id) = greatest(actor, p_user_id)
    for update
  loop
    delete from public.friend_visibility_rules where friendship_id = f.id;
    update public.friendships set status = 'blocked', incarnation = gen_random_uuid(), revision = revision + 1, updated_at = now()
    where id = f.id;
  end loop;
  perform private.bump_friend_schedule_revision(actor);
  perform private.bump_friend_schedule_revision(p_user_id);
  prior := jsonb_build_object('user_id', p_user_id, 'blocked', true,
    'revision', private.friend_revision(actor));
  perform private.friend_replay_record(actor, p_operation_id, 'block_user', request_hash, prior);
  return prior;
end;
$$;

create or replace function public.unblock_user(p_user_id uuid, p_operation_id uuid default null)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, private volatile
as $$
declare actor uuid := auth.uid(); prior jsonb;
  request_hash text := encode(extensions.digest(coalesce(p_user_id::text,''), 'sha256'), 'hex');
begin
  if actor is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_operation_id is null then raise exception 'operation id is required' using errcode = '22023'; end if;
  prior := private.friend_replay_lookup(actor, p_operation_id, 'unblock_user', request_hash);
  if prior is not null then return prior; end if;
  perform private.lock_friend_pair(actor, p_user_id);
  delete from public.blocks where blocker_user_id = actor and blocked_user_id = p_user_id;
  perform private.bump_friend_schedule_revision(actor);
  perform private.bump_friend_schedule_revision(p_user_id);
  prior := jsonb_build_object('user_id', p_user_id, 'blocked', false, 'revision', private.friend_revision(actor));
  perform private.friend_replay_record(actor, p_operation_id, 'unblock_user', request_hash, prior);
  return prior;
end;
$$;

create or replace function public.list_blocked_users()
returns setof jsonb
language sql security definer
set search_path = pg_catalog, public, private stable
as $$
  select jsonb_build_object('user_id', p.user_id, 'display_name', p.display_name)
  from public.blocks b join public.profiles p on p.user_id = b.blocked_user_id
  where b.blocker_user_id = auth.uid();
$$;

create or replace function private.friend_target_owned(
  p_owner uuid, p_target_kind text, p_target_id uuid, p_target_value text
)
returns boolean
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select case p_target_kind
    when 'default' then p_target_id is null and p_target_value is null
    when 'event_kind' then p_target_id is null and p_target_value is not null and p_target_value in
      ('normal', 'routine', 'course', 'assignment_deadline', 'exam', 'group')
    when 'calendar' then exists (
      select 1 from public.calendars c
      where c.id = p_target_id and c.owner_user_id = p_owner and c.deleted_at is null
    )
    when 'course' then exists (
      select 1 from public.user_courses c
      where c.id = p_target_id and c.owner_user_id = p_owner and c.deleted_at is null
    )
    when 'event' then exists (
      select 1 from public.events e
      where e.id = p_target_id and e.owner_user_id = p_owner and e.deleted_at is null
    )
    when 'exam' then exists (
      select 1 from public.exams e
      where e.id = p_target_id and e.owner_user_id = p_owner and e.deleted_at is null
    )
    when 'assignment' then exists (
      select 1 from public.assignments a
      where a.id = p_target_id and a.owner_user_id = p_owner and a.deleted_at is null
    )
    else false
  end;
$$;

create or replace function public.set_friend_visibility(
  p_friendship_id uuid,
  p_incarnation uuid,
  p_friend_user_id uuid,
  p_target_kind text,
  p_target_id uuid,
  p_visibility_level public.visibility_level,
  p_expected_revision bigint default null,
  p_operation_id uuid default null,
  p_target_value text default null
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, private volatile
as $$
declare
  actor uuid := auth.uid(); f public.friendships%rowtype; r public.friend_visibility_rules%rowtype; prior jsonb;
  request_hash text := encode(extensions.digest(coalesce(p_friendship_id::text,'') || ':' || coalesce(p_incarnation::text,'') || ':' || coalesce(p_friend_user_id::text,'') || ':' || coalesce(p_target_kind,'') || ':' || coalesce(p_target_id::text,'') || ':' || coalesce(p_visibility_level::text,'') || ':' || coalesce(p_expected_revision::text,'') || ':' || coalesce(p_target_value,''), 'sha256'), 'hex');
begin
  if actor is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_operation_id is null then raise exception 'operation id is required' using errcode = '22023'; end if;
  prior := private.friend_replay_lookup(actor, p_operation_id, 'set_friend_visibility', request_hash);
  if prior is not null then return prior; end if;
  if p_target_kind not in ('default','calendar','course','event','exam','assignment','event_kind')
     or p_visibility_level is null then raise exception 'invalid visibility target' using errcode = '22023'; end if;
  if p_target_kind in ('default','event_kind') and p_target_id is not null then raise exception 'target id is invalid' using errcode = '22023'; end if;
  if p_target_kind = 'event_kind' and (p_target_value is null or p_target_value not in
      ('normal', 'routine', 'course', 'assignment_deadline', 'exam', 'group')
    ) then raise exception 'event kind is invalid' using errcode = '22023'; end if;
  if p_target_kind <> 'event_kind' and p_target_value is not null then raise exception 'target value is invalid' using errcode = '22023'; end if;
  if not private.friend_target_owned(actor, p_target_kind, p_target_id, p_target_value) then
    raise exception 'visibility target is unavailable' using errcode = '42501';
  end if;
  select * into f from public.friendships where id = p_friendship_id;
  if not found then raise exception 'friendship is unavailable' using errcode = '42501'; end if;
  perform private.lock_friend_pair(f.requester_user_id, f.addressee_user_id);
  select * into f from public.friendships where id = p_friendship_id for update;
  if f.status <> 'accepted' or f.incarnation is distinct from p_incarnation
     or (actor <> f.requester_user_id and actor <> f.addressee_user_id)
     or (actor = f.requester_user_id and p_friend_user_id <> f.addressee_user_id)
     or (actor = f.addressee_user_id and p_friend_user_id <> f.requester_user_id)
     or (p_expected_revision is not null and f.revision <> p_expected_revision)
     or private.friend_is_blocked(actor, p_friend_user_id) then
    raise exception 'stale or unauthorized visibility change' using errcode = '40001';
  end if;
  select * into r from public.friend_visibility_rules
  where friendship_id = f.id and relationship_incarnation = f.incarnation
    and owner_user_id = actor and friend_user_id = p_friend_user_id
    and target_kind = p_target_kind
    and coalesce(target_id, '00000000-0000-0000-0000-000000000000'::uuid) = coalesce(p_target_id, '00000000-0000-0000-0000-000000000000'::uuid)
    and coalesce(target_value, '') = coalesce(p_target_value, '')
  for update;
  if found then
    update public.friend_visibility_rules set mode = 'explicit', visibility_level = p_visibility_level, updated_at = now() where id = r.id;
  else
    insert into public.friend_visibility_rules
      (friendship_id, relationship_incarnation, owner_user_id, friend_user_id, target_kind, target_id, target_value, mode, visibility_level)
    values (f.id, f.incarnation, actor, p_friend_user_id, p_target_kind, p_target_id, p_target_value, 'explicit', p_visibility_level);
  end if;
  update public.friendships set revision = revision + 1, updated_at = now() where id = f.id returning * into f;
  perform private.bump_friend_schedule_revision(actor);
  perform private.bump_friend_schedule_revision(p_friend_user_id);
  prior := jsonb_build_object('friendship_id', f.id, 'incarnation', f.incarnation, 'revision', f.revision);
  perform private.friend_replay_record(actor, p_operation_id, 'set_friend_visibility', request_hash, prior);
  return prior;
end;
$$;

create or replace function public.inherit_friend_visibility(
  p_friendship_id uuid, p_incarnation uuid, p_friend_user_id uuid,
  p_target_kind text, p_target_id uuid,
  p_expected_revision bigint default null, p_operation_id uuid default null,
  p_target_value text default null
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, private volatile
as $$
declare actor uuid := auth.uid(); f public.friendships%rowtype; r public.friend_visibility_rules%rowtype; prior jsonb;
  request_hash text := encode(extensions.digest(coalesce(p_friendship_id::text,'') || ':' || coalesce(p_incarnation::text,'') || ':' || coalesce(p_friend_user_id::text,'') || ':' || coalesce(p_target_kind,'') || ':' || coalesce(p_target_id::text,'') || ':' || coalesce(p_expected_revision::text,'') || ':' || coalesce(p_target_value,''), 'sha256'), 'hex');
begin
  if actor is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_operation_id is null then raise exception 'operation id is required' using errcode = '22023'; end if;
  prior := private.friend_replay_lookup(actor, p_operation_id, 'inherit_friend_visibility', request_hash);
  if prior is not null then return prior; end if;
  select * into f from public.friendships where id = p_friendship_id;
  if not found then raise exception 'friendship is unavailable' using errcode = '42501'; end if;
  perform private.lock_friend_pair(f.requester_user_id, f.addressee_user_id);
  select * into f from public.friendships where id = p_friendship_id for update;
  if p_target_kind not in ('default','calendar','course','event','exam','assignment','event_kind')
     or (p_target_kind in ('default','event_kind') and p_target_id is not null)
     or (p_target_kind = 'event_kind' and (p_target_value is null or p_target_value not in
       ('normal', 'routine', 'course', 'assignment_deadline', 'exam', 'group')))
     or (p_target_kind <> 'event_kind' and p_target_value is not null)
     or not private.friend_target_owned(actor, p_target_kind, p_target_id, p_target_value)
     or f.status <> 'accepted' or f.incarnation is distinct from p_incarnation
     or (actor <> f.requester_user_id and actor <> f.addressee_user_id)
     or (actor = f.requester_user_id and p_friend_user_id <> f.addressee_user_id)
     or (actor = f.addressee_user_id and p_friend_user_id <> f.requester_user_id)
     or (p_expected_revision is not null and f.revision <> p_expected_revision) then
    raise exception 'stale or unauthorized visibility change' using errcode = '40001';
  end if;
  select * into r from public.friend_visibility_rules where friendship_id = f.id and relationship_incarnation = f.incarnation
    and owner_user_id = actor and friend_user_id = p_friend_user_id and target_kind = p_target_kind
    and coalesce(target_id, '00000000-0000-0000-0000-000000000000'::uuid) = coalesce(p_target_id, '00000000-0000-0000-0000-000000000000'::uuid)
    and coalesce(target_value, '') = coalesce(p_target_value, '') for update;
  if found then update public.friend_visibility_rules set mode = 'inherit', visibility_level = null, updated_at = now() where id = r.id;
  else insert into public.friend_visibility_rules
    (friendship_id, relationship_incarnation, owner_user_id, friend_user_id, target_kind, target_id, target_value, mode)
    values (f.id, f.incarnation, actor, p_friend_user_id, p_target_kind, p_target_id, p_target_value, 'inherit');
  end if;
  update public.friendships set revision = revision + 1, updated_at = now() where id = f.id returning * into f;
  perform private.bump_friend_schedule_revision(actor); perform private.bump_friend_schedule_revision(p_friend_user_id);
  prior := jsonb_build_object('friendship_id', f.id, 'incarnation', f.incarnation, 'revision', f.revision);
  perform private.friend_replay_record(actor, p_operation_id, 'inherit_friend_visibility', request_hash, prior);
  return prior;
end;
$$;

create or replace function public.list_friend_visibility_rules(
  p_friendship_id uuid, p_incarnation uuid, p_friend_user_id uuid
)
returns setof jsonb
language plpgsql security definer
set search_path = pg_catalog, public, private stable
as $$
declare actor uuid := auth.uid(); f public.friendships%rowtype;
begin
  if actor is null then raise exception 'authentication required' using errcode = '42501'; end if;
  select * into f from public.friendships where id = p_friendship_id;
  if not found or f.status <> 'accepted' or f.incarnation is distinct from p_incarnation
     or (actor <> f.requester_user_id and actor <> f.addressee_user_id)
     or (actor = f.requester_user_id and p_friend_user_id <> f.addressee_user_id)
     or (actor = f.addressee_user_id and p_friend_user_id <> f.requester_user_id)
     or private.friend_is_blocked(actor, p_friend_user_id) then
    raise exception 'stale or unauthorized visibility read' using errcode = '40001';
  end if;
  return query select jsonb_build_object(
    'friendship_id', r.friendship_id, 'incarnation', r.relationship_incarnation,
    'friend_user_id', r.friend_user_id, 'target_kind', r.target_kind,
    'target_id', r.target_id, 'target_value', r.target_value,
    'mode', r.mode, 'visibility_level', r.visibility_level,
    'revision', f.revision
  ) from public.friend_visibility_rules r
  where r.friendship_id = f.id and r.relationship_incarnation = f.incarnation
    and r.owner_user_id = actor and r.friend_user_id = p_friend_user_id
  order by r.target_kind, r.target_id nulls first, r.target_value nulls first;
end;
$$;

create or replace function private.build_friend_snapshot(
  p_viewer uuid, p_owner uuid, p_term uuid,
  p_range_start timestamptz, p_range_end timestamptz, p_allowed boolean
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, private
stable
as $$
declare
  course_rows jsonb := '[]'::jsonb;
  all_course_rows jsonb := '[]'::jsonb;
  event_rows jsonb := '[]'::jsonb;
  item_rows jsonb := '[]'::jsonb;
  owner_revision bigint;
  owner_cursor bigint;
begin
  if not p_allowed then
      return jsonb_build_object('allowed', false, 'revision', 0,
      'owner_schedule_cursor', 0, 'rows', jsonb_build_object('items', '[]'::jsonb));
  end if;
  owner_revision := private.friend_revision(p_owner);
  select coalesce(max(change_cursor), 0) into owner_cursor
  from private.schedule_change_log where owner_user_id = p_owner;

  select coalesce(jsonb_agg(jsonb_build_object(
      'course_id', x.occurrence_id, 'title', case when x.level in ('TITLE_ONLY','FULL') then x.title else case when x.level = 'BUSY_ONLY' then '予定あり' else null end end,
      'instructor_name', case when x.level = 'FULL' then x.instructor_name else null end,
      'day_of_week', x.day_of_week, 'period_no', x.period_no,
      'room', case when x.level = 'FULL' then x.room else null end,
      'start_at', x.start_at, 'end_at', x.end_at,
      'visibility_level', x.level
    ) order by x.day_of_week nulls last, x.period_no nulls last, x.id), '[]'::jsonb)
  into all_course_rows
  from (
    select uc.*, occ.occurrence_date, ps.start_time, ps.end_time,
      encode(extensions.digest(uc.id::text || ':' || occ.occurrence_date::text, 'sha256'), 'hex') as occurrence_id,
      case when ps.start_time is not null
        then (occ.occurrence_date + ps.start_time)::timestamp at time zone 'Asia/Tokyo'
        else null end as start_at,
      case when ps.end_time is not null
        then (occ.occurrence_date + ps.end_time)::timestamp at time zone 'Asia/Tokyo'
        else null end as end_at,
      case
      when uc.owner_user_id = p_viewer then 'FULL'::public.visibility_level
      when uc.visibility_level = 'PRIVATE'::public.visibility_level then 'PRIVATE'::public.visibility_level
      when rr.target_kind = 'course' and rr.mode = 'explicit'
        then private.restrict_friend_visibility(uc.visibility_level, rr.visibility_level)
      else private.restrict_friend_visibility(
        uc.visibility_level,
        coalesce(rr.visibility_level, 'PRIVATE'::public.visibility_level)
      )
    end as level
    from public.user_courses uc
    join public.profiles owner_profile on owner_profile.user_id = uc.owner_user_id
      and owner_profile.deleted_at is null
    left join public.terms t on t.id = uc.term_id and t.deleted_at is null
    cross join lateral (
      select gs::date as occurrence_date
      from generate_series(
        greatest(t.start_date, coalesce(t.instruction_start_date, t.start_date),
          (p_range_start at time zone 'Asia/Tokyo')::date)::timestamp,
        least(t.end_date, coalesce(t.instruction_end_date, t.end_date),
          ((p_range_end - interval '1 microsecond') at time zone 'Asia/Tokyo')::date)::timestamp,
        interval '1 day'
      ) gs
      where uc.day_of_week is not null
        and extract(isodow from gs)::int = uc.day_of_week
    ) occ
    left join lateral (
      select p.start_time, p.end_time from public.period_settings p
      where p.owner_user_id = p_owner and p.term_id = uc.term_id and p.university_id = t.university_id
        and p.deleted_at is null
        and p.day_of_week = uc.day_of_week and p.period_no = uc.period_no
      order by p.updated_at desc limit 1
    ) ps on true
    left join public.friendships f on f.status = 'accepted'
      and ((f.requester_user_id = p_viewer and f.addressee_user_id = p_owner)
       or (f.addressee_user_id = p_viewer and f.requester_user_id = p_owner))
    left join lateral (
      select r.mode, r.visibility_level, r.target_kind from public.friend_visibility_rules r
      where r.friendship_id = f.id and r.relationship_incarnation = f.incarnation
        and r.owner_user_id = p_owner and r.friend_user_id = p_viewer
        and r.mode = 'explicit'
        and ((r.target_kind = 'course' and r.target_id = uc.id)
          or (r.target_kind = 'event_kind' and r.target_value = 'course')
          or r.target_kind = 'default')
      order by case when r.target_kind = 'course' then 1
                    when r.target_kind = 'event_kind' then 2 else 3 end limit 1
    ) rr on true
    where uc.owner_user_id = p_owner and uc.deleted_at is null
      and (t.id is not null)
      and (p_term is null or uc.term_id = p_term)
      and (uc.owner_user_id = p_viewer or (f.id is not null and not private.friend_is_blocked(p_viewer, p_owner)))
  ) x where x.level <> 'PRIVATE'
    and x.start_at is not null and x.end_at is not null
    and x.start_at < p_range_end and x.end_at > p_range_start;

  select coalesce(jsonb_agg(value order by value->>'start_at', value->>'course_id'), '[]'::jsonb)
  into course_rows
  from jsonb_array_elements(all_course_rows) value
  where value->>'visibility_level' <> 'BUSY_ONLY';

  select coalesce(jsonb_agg(jsonb_build_object(
    'event_id', e.event_id, 'owner_user_id', e.owner_user_id,
    'start_at', e.start_at, 'end_at', e.end_at, 'title', e.title,
    'kind', e.kind, 'location', e.location, 'description', e.description,
    'visibility_level', e.visibility_level, 'group_id', e.group_id
  ) order by e.start_at, e.event_id), '[]'::jsonb)
  into event_rows
  from private.resolve_visible_events_for(p_viewer, p_range_start, p_range_end) e
  where e.owner_user_id = p_owner;

  select coalesce(jsonb_agg(jsonb_build_object(
    'item_id', value->'course_id', 'start_at', value->'start_at', 'end_at', value->'end_at',
    'title', value->'title',
    'kind', case when value->>'visibility_level' in ('TITLE_ONLY','FULL') then 'course' else null end,
    'location', value->'room',
    'description', null, 'instructor_name', value->'instructor_name',
    'visibility_level', value->'visibility_level'
  ) order by value->>'start_at', value->>'course_id'), '[]'::jsonb)
  into item_rows
  from jsonb_array_elements(all_course_rows) value;
  select item_rows || coalesce(jsonb_agg(jsonb_build_object(
    'item_id', to_jsonb(encode(extensions.digest(
      (e->>'event_id') || ':' || (e->>'start_at'), 'sha256'), 'hex')),
    'start_at', e->'start_at', 'end_at', e->'end_at',
    'title', e->'title', 'kind', e->'kind', 'location', e->'location',
    'description', e->'description', 'instructor_name', null,
    'visibility_level', e->'visibility_level'
  ) order by e->>'start_at', e->>'item_id'), '[]'::jsonb)
  into item_rows
  from jsonb_array_elements(event_rows) e;

  -- Exams and assignments are schedule sources too.  Only their redacted
  -- title/time projection crosses this boundary; memo/state/submission data
  -- is intentionally never selected.
  select item_rows || coalesce(jsonb_agg(jsonb_build_object(
    'item_id', q.item_id, 'start_at', q.start_at, 'end_at', q.end_at,
    'title', case when q.level in ('TITLE_ONLY','FULL') then q.title
                  when q.level = 'BUSY_ONLY' then '予定あり' else null end,
    'kind', case when q.level in ('TITLE_ONLY','FULL') then 'exam' else null end,
    'location', case when q.level = 'FULL' then q.room else null end,
    'description', null, 'instructor_name', null,
    'visibility_level', q.level
  ) order by q.start_at, q.item_id), '[]'::jsonb)
  into item_rows
  from (
    select encode(extensions.digest(ex.id::text || ':' || ex.start_at::text, 'sha256'), 'hex') as item_id,
      ex.start_at, ex.end_at, ex.title,
      case
        when ex.owner_user_id = p_viewer then 'FULL'::public.visibility_level
        when ex.visibility_level = 'PRIVATE'::public.visibility_level then 'PRIVATE'::public.visibility_level
        when rr.target_kind = 'exam' and rr.mode = 'explicit'
          then private.restrict_friend_visibility(ex.visibility_level, rr.visibility_level)
        else private.restrict_friend_visibility(ex.visibility_level,
          coalesce(rr.visibility_level, 'PRIVATE'::public.visibility_level))
      end as level,
      ex.room
    from public.exams ex
    join public.profiles op on op.user_id = ex.owner_user_id and op.deleted_at is null
    left join public.user_courses linked_course on linked_course.id = ex.course_id
      and linked_course.owner_user_id = ex.owner_user_id and linked_course.deleted_at is null
    left join public.terms selected_term on selected_term.id = p_term
      and selected_term.owner_user_id = p_owner and selected_term.deleted_at is null
    left join public.friendships f on f.status = 'accepted'
      and ((f.requester_user_id = p_viewer and f.addressee_user_id = p_owner)
       or (f.addressee_user_id = p_viewer and f.requester_user_id = p_owner))
    left join lateral (
      select r.mode, r.visibility_level, r.target_kind from public.friend_visibility_rules r
      where r.friendship_id = f.id and r.relationship_incarnation = f.incarnation
        and r.owner_user_id = p_owner and r.friend_user_id = p_viewer
        and r.mode = 'explicit' and ((r.target_kind = 'exam' and r.target_id = ex.id)
          or (r.target_kind = 'event_kind' and r.target_value = 'exam')
          or r.target_kind = 'default')
      order by case when r.target_kind = 'exam' then 1
                    when r.target_kind = 'event_kind' then 2 else 3 end limit 1
    ) rr on true
    where ex.owner_user_id = p_owner and ex.deleted_at is null
      and ex.start_at < p_range_end and ex.end_at > p_range_start
      and (p_term is null or linked_course.term_id = p_term or (
        linked_course.id is null and selected_term.id is not null
        and ex.start_at >= (greatest(selected_term.start_date,
          coalesce(selected_term.instruction_start_date, selected_term.start_date))::timestamp at time zone 'Asia/Tokyo')
        and ex.start_at < ((least(selected_term.end_date,
          coalesce(selected_term.instruction_end_date, selected_term.end_date)) + 1)::timestamp at time zone 'Asia/Tokyo')
      ))
      and (ex.owner_user_id = p_viewer or (f.id is not null and not private.friend_is_blocked(p_viewer, p_owner)))
  ) q where q.level <> 'PRIVATE';

  select item_rows || coalesce(jsonb_agg(jsonb_build_object(
    'item_id', q.item_id, 'start_at', q.start_at, 'end_at', q.end_at,
    'title', case when q.level in ('TITLE_ONLY','FULL') then q.title
                  when q.level = 'BUSY_ONLY' then '予定あり' else null end,
    'kind', case when q.level in ('TITLE_ONLY','FULL') then 'assignment_deadline' else null end,
    'location', null, 'description', null, 'instructor_name', null,
    'visibility_level', q.level
  ) order by q.start_at, q.item_id), '[]'::jsonb)
  into item_rows
  from (
    select encode(extensions.digest(a.id::text || ':' || a.due_at::text, 'sha256'), 'hex') as item_id,
      a.due_at as start_at, a.due_at as end_at, a.title,
      case
        when a.owner_user_id = p_viewer then 'FULL'::public.visibility_level
        when a.visibility_level = 'PRIVATE'::public.visibility_level then 'PRIVATE'::public.visibility_level
        when rr.target_kind = 'assignment' and rr.mode = 'explicit'
          then private.restrict_friend_visibility(a.visibility_level, rr.visibility_level)
        else private.restrict_friend_visibility(a.visibility_level,
          coalesce(rr.visibility_level, 'PRIVATE'::public.visibility_level))
      end as level
    from public.assignments a
    join public.profiles op on op.user_id = a.owner_user_id and op.deleted_at is null
    left join public.user_courses linked_course on linked_course.id = a.course_id
      and linked_course.owner_user_id = a.owner_user_id and linked_course.deleted_at is null
    left join public.terms selected_term on selected_term.id = p_term
      and selected_term.owner_user_id = p_owner and selected_term.deleted_at is null
    left join public.friendships f on f.status = 'accepted'
      and ((f.requester_user_id = p_viewer and f.addressee_user_id = p_owner)
       or (f.addressee_user_id = p_viewer and f.requester_user_id = p_owner))
    left join lateral (
      select r.mode, r.visibility_level, r.target_kind from public.friend_visibility_rules r
      where r.friendship_id = f.id and r.relationship_incarnation = f.incarnation
        and r.owner_user_id = p_owner and r.friend_user_id = p_viewer
        and r.mode = 'explicit' and ((r.target_kind = 'assignment' and r.target_id = a.id)
          or r.target_kind = 'default')
      order by case when r.target_kind = 'assignment' then 1
                    when r.target_kind = 'event_kind' then 2 else 3 end limit 1
    ) rr on true
    where a.owner_user_id = p_owner and a.deleted_at is null
      and a.due_at >= p_range_start and a.due_at < p_range_end
      and (p_term is null or linked_course.term_id = p_term or (
        linked_course.id is null and selected_term.id is not null
        and a.due_at >= (greatest(selected_term.start_date,
          coalesce(selected_term.instruction_start_date, selected_term.start_date))::timestamp at time zone 'Asia/Tokyo')
        and a.due_at < ((least(selected_term.end_date,
          coalesce(selected_term.instruction_end_date, selected_term.end_date)) + 1)::timestamp at time zone 'Asia/Tokyo')
      ))
      and (a.owner_user_id = p_viewer or (f.id is not null and not private.friend_is_blocked(p_viewer, p_owner)))
  ) q where q.level <> 'PRIVATE';

  select coalesce(jsonb_agg(value order by value->>'start_at', value->>'item_id'), '[]'::jsonb)
  into item_rows
  from jsonb_array_elements(item_rows) value;

  return jsonb_build_object('allowed', true, 'revision', owner_revision,
    'owner_schedule_cursor', owner_cursor,
    'rows', jsonb_build_object('items', item_rows));
end;
$$;

create or replace function public.get_friend_schedule(
  p_owner_user_id uuid, p_term_id uuid, p_range_start timestamptz, p_range_end timestamptz
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, private stable
as $$
declare actor uuid := auth.uid(); allowed boolean;
begin
  if actor is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_range_end <= p_range_start or p_range_end - p_range_start > interval '366 days' then
    raise exception 'invalid schedule range' using errcode = '22023';
  end if;
  allowed := actor = p_owner_user_id
    or (not private.friend_is_blocked(actor, p_owner_user_id) and exists (
      select 1 from public.friendships f where f.status = 'accepted'
        and ((f.requester_user_id = actor and f.addressee_user_id = p_owner_user_id)
          or (f.addressee_user_id = actor and f.requester_user_id = p_owner_user_id))
    ));
  return private.build_friend_snapshot(actor, p_owner_user_id, p_term_id, p_range_start, p_range_end, allowed);
end;
$$;

create or replace function public.preview_friend_schedule(
  p_friend_user_id uuid, p_term_id uuid, p_range_start timestamptz, p_range_end timestamptz
)
returns jsonb
language plpgsql security definer
set search_path = pg_catalog, public, private stable
as $$
declare owner_id uuid := auth.uid(); allowed boolean;
begin
  if owner_id is null then raise exception 'authentication required' using errcode = '42501'; end if;
  if p_range_end <= p_range_start or p_range_end - p_range_start > interval '366 days' then
    raise exception 'invalid schedule range' using errcode = '22023';
  end if;
  allowed := not private.friend_is_blocked(p_friend_user_id, owner_id) and exists (
    select 1 from public.friendships f where f.status = 'accepted'
      and ((f.requester_user_id = owner_id and f.addressee_user_id = p_friend_user_id)
        or (f.addressee_user_id = owner_id and f.requester_user_id = p_friend_user_id))
  );
  return private.build_friend_snapshot(p_friend_user_id, owner_id, p_term_id, p_range_start, p_range_end, allowed);
end;
$$;

create or replace function public.list_friend_terms(p_owner_user_id uuid)
returns setof jsonb
language plpgsql security definer
set search_path = pg_catalog, public, private stable
as $$
declare actor uuid := auth.uid(); allowed boolean;
begin
  if actor is null then raise exception 'authentication required' using errcode = '42501'; end if;
  allowed := actor = p_owner_user_id or (not private.friend_is_blocked(actor, p_owner_user_id) and exists (
    select 1 from public.friendships f where f.status = 'accepted'
      and ((f.requester_user_id = actor and f.addressee_user_id = p_owner_user_id)
        or (f.addressee_user_id = actor and f.requester_user_id = p_owner_user_id))
  ));
  if not allowed then return; end if;
  return query select jsonb_build_object('term_id', t.id, 'name', t.name,
    'academic_year', t.academic_year, 'start_date', t.start_date, 'end_date', t.end_date)
    from public.terms t
    where t.deleted_at is null
      and (t.owner_user_id = p_owner_user_id or t.created_by = p_owner_user_id or exists (
        select 1 from public.user_courses c
        where c.owner_user_id = p_owner_user_id and c.term_id = t.id and c.deleted_at is null
      ))
    order by t.start_date desc, t.id;
end;
$$;

revoke execute on function private.bump_friend_schedule_revision(uuid) from public, anon, authenticated;
revoke execute on function private.friend_replay_lookup(uuid, uuid, text, text) from public, anon, authenticated;
revoke execute on function private.friend_replay_record(uuid, uuid, text, text, jsonb) from public, anon, authenticated;
revoke execute on function private.friend_source_revision_trigger() from public, anon, authenticated;
revoke execute on function private.lock_friend_pair(uuid, uuid) from public, anon, authenticated;
revoke execute on function private.friend_is_blocked(uuid, uuid) from public, anon, authenticated;
revoke execute on function private.friend_is_group_member(uuid, uuid) from public, anon, authenticated;
revoke execute on function private.friend_revision(uuid) from public, anon, authenticated;
revoke execute on function private.restrict_friend_visibility(public.visibility_level, public.visibility_level) from public, anon, authenticated;
revoke execute on function private.friend_target_owned(uuid, text, uuid, text) from public, anon, authenticated;
revoke execute on function private.build_friend_snapshot(uuid, uuid, uuid, timestamptz, timestamptz, boolean) from public, anon, authenticated;
revoke execute on function private.resolve_visible_events_for(uuid, timestamptz, timestamptz) from public, anon, authenticated;

revoke execute on function public.create_friend_invite(text, uuid, timestamptz) from public, anon;
revoke execute on function public.preview_friend_invite(text) from public, anon;
revoke execute on function public.request_friend_from_invite(text, uuid) from public, anon;
revoke execute on function public.list_friendships() from public, anon;
revoke execute on function public.list_friend_invites() from public, anon;
revoke execute on function public.revoke_friend_invite(uuid, uuid) from public, anon;
revoke execute on function public.accept_friend_request(uuid, uuid, bigint, uuid) from public, anon;
revoke execute on function public.reject_friend_request(uuid, uuid, bigint, uuid) from public, anon;
revoke execute on function public.cancel_friend_request(uuid, uuid, bigint, uuid) from public, anon;
revoke execute on function public.unfriend(uuid, uuid, bigint, uuid) from public, anon;
revoke execute on function public.block_user(uuid, uuid) from public, anon;
revoke execute on function public.unblock_user(uuid, uuid) from public, anon;
revoke execute on function public.list_blocked_users() from public, anon;
revoke execute on function public.set_friend_visibility(uuid, uuid, uuid, text, uuid, public.visibility_level, bigint, uuid, text) from public, anon;
revoke execute on function public.inherit_friend_visibility(uuid, uuid, uuid, text, uuid, bigint, uuid, text) from public, anon;
revoke execute on function public.list_friend_visibility_rules(uuid, uuid, uuid) from public, anon;
revoke execute on function public.get_friend_schedule(uuid, uuid, timestamptz, timestamptz) from public, anon;
revoke execute on function public.preview_friend_schedule(uuid, uuid, timestamptz, timestamptz) from public, anon;
revoke execute on function public.list_friend_terms(uuid) from public, anon;

grant execute on function public.create_friend_invite(text, uuid, timestamptz) to authenticated;
grant execute on function public.preview_friend_invite(text) to authenticated;
grant execute on function public.request_friend_from_invite(text, uuid) to authenticated;
grant execute on function public.list_friendships() to authenticated;
grant execute on function public.list_friend_invites() to authenticated;
grant execute on function public.revoke_friend_invite(uuid, uuid) to authenticated;
grant execute on function public.accept_friend_request(uuid, uuid, bigint, uuid) to authenticated;
grant execute on function public.reject_friend_request(uuid, uuid, bigint, uuid) to authenticated;
grant execute on function public.cancel_friend_request(uuid, uuid, bigint, uuid) to authenticated;
grant execute on function public.unfriend(uuid, uuid, bigint, uuid) to authenticated;
grant execute on function public.block_user(uuid, uuid) to authenticated;
grant execute on function public.unblock_user(uuid, uuid) to authenticated;
grant execute on function public.list_blocked_users() to authenticated;
grant execute on function public.set_friend_visibility(uuid, uuid, uuid, text, uuid, public.visibility_level, bigint, uuid, text) to authenticated;
grant execute on function public.inherit_friend_visibility(uuid, uuid, uuid, text, uuid, bigint, uuid, text) to authenticated;
grant execute on function public.list_friend_visibility_rules(uuid, uuid, uuid) to authenticated;
grant execute on function public.get_friend_schedule(uuid, uuid, timestamptz, timestamptz) to authenticated;
grant execute on function public.preview_friend_schedule(uuid, uuid, timestamptz, timestamptz) to authenticated;
grant execute on function public.list_friend_terms(uuid) to authenticated;
