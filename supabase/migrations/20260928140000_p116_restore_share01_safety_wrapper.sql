-- P116 restores the Phase 15 safety wrapper while updating only its private base projection.
begin;
create or replace function private.phase15_resolve_visible_events_for_base(
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
      and e.moderation_hidden_at is null
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
        when c.group_id is not null then
          case
            when c.event_visibility is not null then c.event_visibility
            else coalesce(
              c.calendar_visibility,
              c.member_visibility,
              c.group_default_visibility,
              c.owner_default_visibility,
              'PRIVATE'::public.visibility_level
            )
          end
        when c.friendship_id is not null then
          case
            -- Explicit event/calendar privacy remains a ceiling, while the
            -- relationship rule can only reduce that exposure.
            when c.event_visibility is not null then private.restrict_friend_visibility(
              c.event_visibility,
              coalesce(c.friend_rule_visibility, 'PRIVATE'::public.visibility_level)
            )
            when c.calendar_visibility is not null then private.restrict_friend_visibility(
              c.calendar_visibility,
              coalesce(c.friend_rule_visibility, 'PRIVATE'::public.visibility_level)
            )
            -- With both higher-priority overrides absent, the explicit friend
            -- default replaces the owner's profile default as §29 specifies.
            else coalesce(
              c.friend_rule_visibility,
              'PRIVATE'::public.visibility_level
            )
          end
        else coalesce(
          c.event_visibility,
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

create or replace function private.resolve_visible_events_for(
  p_viewer uuid,p_range_start timestamptz,p_range_end timestamptz
) returns table(event_id uuid,owner_user_id uuid,start_at timestamptz,end_at timestamptz,
  visibility_level public.visibility_level,title text,location text,description text,kind text,group_id uuid)
language sql stable security definer set search_path=pg_catalog,public,private as $$
  select b.* from private.phase15_resolve_visible_events_for_base(p_viewer,p_range_start,p_range_end) b
  join public.events e on e.id=b.event_id and e.moderation_hidden_at is null
  where private.safety_actor_active(p_viewer)
    and private.safety_actor_active(b.owner_user_id)
    and (b.group_id is null or private.safety_group_active(b.group_id));
$$;

revoke all on function private.resolve_visible_events_for(uuid,timestamptz,timestamptz),
  private.phase15_resolve_visible_events_for_base(uuid,timestamptz,timestamptz)
  from public,anon,authenticated,service_role;
grant execute on function private.phase15_resolve_visible_events_for_base(uuid,timestamptz,timestamptz)
  to postgres,supabase_admin;

commit;
