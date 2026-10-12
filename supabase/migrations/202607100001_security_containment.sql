-- Phase-0 containment for caller identity, event projection, and raw-data RLS.
-- This migration intentionally preserves the existing public RPC signatures.

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.is_group_member(target_group_id uuid)
returns boolean
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select auth.uid() is not null
    and exists (
      select 1
      from public.groups g
      left join public.group_members gm
        on gm.group_id = g.id
       and gm.user_id = auth.uid()
      where g.id = target_group_id
        and g.deleted_at is null
        and (g.owner_user_id = auth.uid() or gm.user_id is not null)
    );
$$;

create or replace function private.is_group_admin(target_group_id uuid)
returns boolean
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select auth.uid() is not null
    and exists (
      select 1
      from public.groups g
      left join public.group_members gm
        on gm.group_id = g.id
       and gm.user_id = auth.uid()
      where g.id = target_group_id
        and g.deleted_at is null
        and (
          g.owner_user_id = auth.uid()
          or gm.role in ('owner', 'admin')
        )
    );
$$;

create or replace function private.are_friends(other_user_id uuid)
returns boolean
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select auth.uid() is not null
    and exists (
      select 1
      from public.friendships f
      where f.status = 'accepted'
        and (
          (f.requester_user_id = auth.uid() and f.addressee_user_id = other_user_id)
          or
          (f.addressee_user_id = auth.uid() and f.requester_user_id = other_user_id)
        )
    );
$$;

create or replace function private.is_blocked(other_user_id uuid)
returns boolean
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select auth.uid() is not null
    and exists (
      select 1
      from public.blocks b
      where (b.blocker_user_id = auth.uid() and b.blocked_user_id = other_user_id)
         or (b.blocker_user_id = other_user_id and b.blocked_user_id = auth.uid())
    );
$$;

create or replace function private.can_access_event(target_event_id uuid)
returns boolean
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select auth.uid() is not null
    and exists (
      select 1
      from public.events e
      where e.id = target_event_id
        and e.deleted_at is null
        and (
          e.owner_user_id = auth.uid()
          or (
            e.group_id is not null
            and not private.is_blocked(e.owner_user_id)
            and private.is_group_member(e.group_id)
          )
        )
    );
$$;

create or replace function private.can_edit_event(target_event_id uuid)
returns boolean
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select auth.uid() is not null
    and exists (
      select 1
      from public.events e
      where e.id = target_event_id
        and e.deleted_at is null
        and (
          e.owner_user_id = auth.uid()
          or (
            e.group_id is not null
            and not private.is_blocked(e.owner_user_id)
            and (
              (e.created_by = auth.uid() and private.is_group_member(e.group_id))
              or private.is_group_admin(e.group_id)
            )
          )
        )
    );
$$;

create or replace function private.can_create_event(
  target_owner_user_id uuid,
  target_created_by uuid,
  target_calendar_id uuid,
  target_group_id uuid
)
returns boolean
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select auth.uid() is not null
    and target_owner_user_id = auth.uid()
    and (target_created_by is null or target_created_by = auth.uid())
    and exists (
      select 1
      from public.calendars c
      left join public.groups g on g.id = target_group_id
      where c.id = target_calendar_id
        and c.deleted_at is null
        and (
          (
            target_group_id is null
            and c.group_id is null
            and c.owner_user_id = auth.uid()
          )
          or
          (
            target_group_id is not null
            and c.group_id = target_group_id
            and g.deleted_at is null
            and case g.event_create_policy
              when 'member' then private.is_group_member(target_group_id)
              when 'admin' then private.is_group_admin(target_group_id)
              when 'owner' then g.owner_user_id = auth.uid()
              else false
            end
          )
        )
    );
$$;

create or replace function private.can_write_event_values(
  target_owner_user_id uuid,
  target_created_by uuid,
  target_calendar_id uuid,
  target_group_id uuid
)
returns boolean
language sql
security definer
set search_path = pg_catalog, public, private
stable
as $$
  select auth.uid() is not null
    and exists (
      select 1
      from public.calendars c
      left join public.groups g on g.id = target_group_id
      where c.id = target_calendar_id
        and c.deleted_at is null
        and (
          (
            target_group_id is null
            and c.group_id is null
            and c.owner_user_id = auth.uid()
            and target_owner_user_id = auth.uid()
          )
          or
          (
            target_group_id is not null
            and c.group_id = target_group_id
            and g.deleted_at is null
            and (
              (
                (target_owner_user_id = auth.uid() or target_created_by = auth.uid())
                and private.is_group_member(target_group_id)
              )
              or private.is_group_admin(target_group_id)
            )
          )
        )
    );
$$;

-- Repoint RLS policies away from public, caller-parameterized helpers.
drop policy if exists groups_member_read on public.groups;
create policy groups_member_read on public.groups
  for select to authenticated
  using (private.is_group_member(id));

drop policy if exists groups_admin_update on public.groups;
create policy groups_admin_update on public.groups
  for update to authenticated
  using (private.is_group_admin(id))
  with check (private.is_group_admin(id));

drop policy if exists group_members_member_read on public.group_members;
create policy group_members_member_read on public.group_members
  for select to authenticated
  using (private.is_group_member(group_id));

drop policy if exists group_members_admin_write on public.group_members;
create policy group_members_admin_write on public.group_members
  for all to authenticated
  using (private.is_group_admin(group_id))
  with check (private.is_group_admin(group_id));

drop policy if exists group_invitations_member_read on public.group_invitations;
create policy group_invitations_member_read on public.group_invitations
  for select to authenticated
  using (private.is_group_member(group_id));

drop policy if exists group_invitations_admin_write on public.group_invitations;
create policy group_invitations_admin_write on public.group_invitations
  for all to authenticated
  using (private.is_group_admin(group_id))
  with check (private.is_group_admin(group_id));

drop policy if exists calendars_owner_or_group on public.calendars;
create policy calendars_owner_or_group on public.calendars
  for select to authenticated
  using (
    owner_user_id = auth.uid()
    or (group_id is not null and private.is_group_member(group_id))
  );

drop policy if exists events_owner_or_group_write on public.events;

create policy events_group_editor_read on public.events
  for select to authenticated
  using (private.can_edit_event(id));

create policy events_scoped_insert on public.events
  for insert to authenticated
  with check (
    private.can_create_event(owner_user_id, created_by, calendar_id, group_id)
  );

create policy events_scoped_update on public.events
  for update to authenticated
  using (private.can_edit_event(id))
  with check (
    private.can_write_event_values(owner_user_id, created_by, calendar_id, group_id)
  );

create policy events_scoped_delete on public.events
  for delete to authenticated
  using (private.can_edit_event(id));

drop policy if exists event_exceptions_event_writer on public.event_exceptions;
create policy event_exceptions_event_writer on public.event_exceptions
  for all to authenticated
  using (private.can_edit_event(event_id))
  with check (private.can_edit_event(event_id));

drop policy if exists event_participants_visible_members on public.event_participants;
create policy event_participants_visible_members on public.event_participants
  for select to authenticated
  using (user_id = auth.uid() or private.can_access_event(event_id));

drop policy if exists event_comments_group_read on public.event_comments;
create policy event_comments_group_read on public.event_comments
  for select to authenticated
  using (deleted_at is null and private.can_access_event(event_id));

drop policy if exists event_comments_author_or_group_insert on public.event_comments;
create policy event_comments_author_or_group_insert on public.event_comments
  for insert to authenticated
  with check (
    author_user_id = auth.uid()
    and private.can_access_event(event_id)
  );

drop policy if exists event_reactions_group_read on public.event_reactions;
create policy event_reactions_group_read on public.event_reactions
  for select to authenticated
  using (private.can_access_event(event_id));

-- A searchable profile must be exposed later through a narrow, block-aware RPC.
drop policy if exists profiles_read_self_or_searchable on public.profiles;
create policy profiles_read_self on public.profiles
  for select to authenticated
  using (user_id = auth.uid());

create or replace function public.guard_profile_university_verified()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if current_user in ('anon', 'authenticated') then
    if tg_op = 'INSERT' and new.university_verified then
      raise exception 'university_verified is server-managed' using errcode = '42501';
    end if;

    if tg_op = 'UPDATE'
       and new.university_verified is distinct from old.university_verified then
      raise exception 'university_verified is server-managed' using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_guard_university_verified on public.profiles;
create trigger profiles_guard_university_verified
before insert or update of university_verified on public.profiles
for each row execute function public.guard_profile_university_verified();

-- The initial schema defined RLS but no table ACLs. Grant only the operations
-- that this containment slice explicitly protects and tests.
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update, delete on public.events to authenticated;

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
  visibility_level visibility_level,
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
declare
  bound_viewer uuid := auth.uid();
begin
  if bound_viewer is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if viewer_id is distinct from bound_viewer then
    raise exception 'viewer_id must match auth.uid()' using errcode = '42501';
  end if;

  if range_end <= range_start or range_end - range_start > interval '366 days' then
    raise exception 'invalid event range' using errcode = '22023';
  end if;

  return query
  with candidate as (
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
      p.default_visibility as owner_default_visibility,
      g.default_visibility as group_default_visibility,
      gm.visibility_level as member_visibility,
      (
        select f.visibility_level
        from public.friendships f
        where f.status = 'accepted'
          and (
            (f.requester_user_id = bound_viewer and f.addressee_user_id = e.owner_user_id)
            or
            (f.addressee_user_id = bound_viewer and f.requester_user_id = e.owner_user_id)
          )
        order by f.updated_at desc, f.id
        limit 1
      ) as friend_visibility
    from public.events e
    join public.calendars c
      on c.id = e.calendar_id
     and c.deleted_at is null
    join public.profiles p
      on p.user_id = e.owner_user_id
     and p.deleted_at is null
    left join public.groups g
      on g.id = e.group_id
     and g.deleted_at is null
    left join public.group_members gm
      on gm.group_id = e.group_id
     and gm.user_id = bound_viewer
    where e.deleted_at is null
      and e.start_at < range_end
      and e.end_at > range_start
      and (
        e.owner_user_id = bound_viewer
        or (
          not private.is_blocked(e.owner_user_id)
          and (
            (
              e.group_id is not null
              and private.is_group_member(e.group_id)
            )
            or (
              e.group_id is null
              and private.are_friends(e.owner_user_id)
            )
          )
        )
      )
  ),
  resolved as (
    select
      c.*,
      case
        when c.owner_user_id = bound_viewer then 'FULL'::visibility_level
        when private.is_blocked(c.owner_user_id) then 'PRIVATE'::visibility_level
        when c.event_visibility is not null then c.event_visibility
        when c.group_id is not null
          then coalesce(
            c.member_visibility,
            c.group_default_visibility,
            c.owner_default_visibility,
            'PRIVATE'::visibility_level
          )
        else coalesce(
          c.friend_visibility,
          c.owner_default_visibility,
          'PRIVATE'::visibility_level
        )
      end as resolved_visibility
    from candidate c
  )
  select
    r.event_id,
    r.owner_user_id,
    r.start_at,
    r.end_at,
    r.resolved_visibility,
    case
      when r.resolved_visibility = 'BUSY_ONLY' then '予定あり'
      when r.resolved_visibility in ('TITLE_ONLY', 'FULL') then r.title
      else null
    end as title,
    case when r.resolved_visibility = 'FULL' then r.location else null end as location,
    case when r.resolved_visibility = 'FULL' then r.description else null end as description,
    case when r.resolved_visibility in ('TITLE_ONLY', 'FULL') then r.kind else null end as kind,
    case when r.resolved_visibility = 'FULL' then r.group_id else null end as group_id
  from resolved r
  where r.resolved_visibility <> 'PRIVATE';
end;
$$;

create or replace function public.find_free_windows(
  viewer_id uuid,
  member_ids uuid[],
  range_start timestamptz,
  range_end timestamptz,
  minimum_minutes int default 30
)
returns table (
  start_at timestamptz,
  end_at timestamptz
)
language plpgsql
security definer
set search_path = pg_catalog, public, private
stable
as $$
declare
  bound_viewer uuid := auth.uid();
begin
  if bound_viewer is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if viewer_id is distinct from bound_viewer then
    raise exception 'viewer_id must match auth.uid()' using errcode = '42501';
  end if;

  if minimum_minutes <= 0 then
    raise exception 'minimum_minutes must be positive' using errcode = '22023';
  end if;

  if coalesce(cardinality(member_ids), 0) > 100 then
    raise exception 'too many members' using errcode = '22023';
  end if;

  return query
  with busy as (
    select
      greatest(ve.start_at, range_start) as busy_start,
      least(ve.end_at, range_end) as busy_end
    from public.get_visible_events(bound_viewer, range_start, range_end) ve
    where ve.owner_user_id = any(member_ids)
  ),
  points as (
    select range_start as point
    union
    select range_end
    union
    select busy_start from busy
    union
    select busy_end from busy
  ),
  windows as (
    select
      p.point as window_start,
      lead(p.point) over (order by p.point) as window_end
    from points p
  )
  select w.window_start, w.window_end
  from windows w
  where w.window_end is not null
    and extract(epoch from (w.window_end - w.window_start)) / 60 >= minimum_minutes
    and not exists (
      select 1
      from busy b
      where b.busy_start < w.window_end
        and b.busy_end > w.window_start
    )
  order by w.window_start;
end;
$$;

-- Private helpers are usable by authenticated RLS evaluation but are not in an
-- exposed PostgREST schema. Public arbitrary-user helper RPCs are disabled.
revoke execute on function private.is_group_member(uuid) from public, anon;
revoke execute on function private.is_group_admin(uuid) from public, anon;
revoke execute on function private.are_friends(uuid) from public, anon;
revoke execute on function private.is_blocked(uuid) from public, anon;
revoke execute on function private.can_access_event(uuid) from public, anon;
revoke execute on function private.can_edit_event(uuid) from public, anon;
revoke execute on function private.can_create_event(uuid, uuid, uuid, uuid) from public, anon;
revoke execute on function private.can_write_event_values(uuid, uuid, uuid, uuid) from public, anon;

grant execute on function private.is_group_member(uuid) to authenticated;
grant execute on function private.is_group_admin(uuid) to authenticated;
grant execute on function private.are_friends(uuid) to authenticated;
grant execute on function private.is_blocked(uuid) to authenticated;
grant execute on function private.can_access_event(uuid) to authenticated;
grant execute on function private.can_edit_event(uuid) to authenticated;
grant execute on function private.can_create_event(uuid, uuid, uuid, uuid) to authenticated;
grant execute on function private.can_write_event_values(uuid, uuid, uuid, uuid) to authenticated;

revoke execute on function public.is_group_member(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.is_group_admin(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.are_friends(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.is_blocked(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.can_access_event(uuid, uuid) from public, anon, authenticated;

revoke execute on function public.search_course_templates(text, uuid, integer, uuid, integer, integer, integer) from public, anon;
revoke execute on function public.copy_course_template(uuid, uuid) from public, anon;
revoke execute on function public.get_visible_events(uuid, timestamptz, timestamptz) from public, anon;
revoke execute on function public.find_free_windows(uuid, uuid[], timestamptz, timestamptz, integer) from public, anon;

grant execute on function public.search_course_templates(text, uuid, integer, uuid, integer, integer, integer) to authenticated;
grant execute on function public.copy_course_template(uuid, uuid) to authenticated;
grant execute on function public.get_visible_events(uuid, timestamptz, timestamptz) to authenticated;
grant execute on function public.find_free_windows(uuid, uuid[], timestamptz, timestamptz, integer) to authenticated;
