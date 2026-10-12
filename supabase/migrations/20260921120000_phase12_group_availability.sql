-- Phase 12: group-scoped availability projection.  This is intentionally a
-- separate RPC: it does not fabricate friendships or call friend endpoints.
begin;

create or replace function private.restrict_group_visibility(
  p_source public.visibility_level,
  p_cap public.visibility_level)
returns public.visibility_level
language sql immutable parallel safe
set search_path = pg_catalog, public
as $$
  select case
    when coalesce(p_source, 'PRIVATE'::public.visibility_level) = 'PRIVATE'
      or coalesce(p_cap, 'PRIVATE'::public.visibility_level) = 'PRIVATE'
      then 'PRIVATE'::public.visibility_level
    when p_source = 'BUSY_ONLY' or p_cap = 'BUSY_ONLY'
      then 'BUSY_ONLY'::public.visibility_level
    when p_source = 'TITLE_ONLY' or p_cap = 'TITLE_ONLY'
      then 'TITLE_ONLY'::public.visibility_level
    else 'FULL'::public.visibility_level
  end;
$$;
revoke all on function private.restrict_group_visibility(public.visibility_level,public.visibility_level)
  from public,anon,authenticated;

-- The query
-- identity and membership generation are required even when there are no
-- busy rows, so an empty response can never be mistaken for a valid stale
-- result.
drop function if exists public.find_group_availability(uuid,uuid[],timestamptz,timestamptz,integer);
create or replace function public.find_group_availability(
  p_group_id uuid,p_member_ids uuid[],p_range_start timestamptz,p_range_end timestamptz,
  p_minimum_duration_minutes integer)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); q uuid:=gen_random_uuid(); gen text; rows jsonb;
begin
  if a is null then raise exception 'not authenticated' using errcode='42501'; end if;
  if p_member_ids is null or cardinality(p_member_ids)<1 or cardinality(p_member_ids)>20
     or p_range_end is null or p_range_start is null or p_range_end<=p_range_start
     or p_range_end-p_range_start>interval '14 days'
     or p_minimum_duration_minutes is null or p_minimum_duration_minutes<1
     or p_minimum_duration_minutes>1440 or not (a=any(p_member_ids)) then
    raise exception 'invalid availability request' using errcode='22023'; end if;
  if cardinality(p_member_ids)<>cardinality(array(select distinct x from unnest(p_member_ids) x)) then
    raise exception 'duplicate member selection' using errcode='42501'; end if;
  if not exists(select 1 from public.groups g where g.id=p_group_id and g.deleted_at is null)
     or exists(select 1 from unnest(p_member_ids) selected(id)
       where not exists(select 1 from public.group_members m where m.group_id=p_group_id and m.user_id=selected.id))
     or exists(select 1 from unnest(p_member_ids) selected(id) where private.is_blocked(selected.id)) then
    raise exception 'membership or authorization changed; retry' using errcode='42501'; end if;
  select md5(g.version::text||':'||coalesce(string_agg(m.user_id::text||':'||m.role||':'||m.joined_at::text,',' order by m.user_id),''))
    into gen from public.groups g join public.group_members m on m.group_id=g.id
    where g.id=p_group_id and g.deleted_at is null and m.user_id=any(p_member_ids) group by g.version;
  with selected as (select unnest(p_member_ids) id),
  group_context as (select default_visibility from public.groups where id=p_group_id and deleted_at is null),
  busy as (
    select s.id member_id,e.start_at,e.end_at,
      case when s.id=a then 'BUSY_ONLY'
           else effective.effective_visibility::text end visibility_level
    from selected s join public.events e on e.owner_user_id=s.id and e.group_id is null
    cross join group_context grp
    join public.profiles p on p.user_id=s.id and p.deleted_at is null
    left join public.calendars c on c.id=e.calendar_id and c.deleted_at is null
    left join public.group_members gm on gm.group_id=p_group_id and gm.user_id=s.id
    cross join lateral (select private.restrict_group_visibility(
      coalesce(e.visibility_level,c.default_visibility,p.default_visibility,'PRIVATE'::public.visibility_level),
      coalesce(gm.visibility_level,grp.default_visibility,'PRIVATE'::public.visibility_level)
    ) effective_visibility) effective
    where e.deleted_at is null and e.start_at<p_range_end and e.end_at>p_range_start
      and (s.id=a or (effective.effective_visibility<>'PRIVATE' and not private.is_blocked(s.id)))
    union all
    select s.id,e.start_at,e.end_at,'BUSY_ONLY'
    from selected s cross join group_context grp
      join public.events e on e.group_id=p_group_id and e.kind='group' and e.deleted_at is null
    left join public.event_participants ep on ep.event_id=e.id and ep.user_id=s.id
    where e.start_at<p_range_end and e.end_at>p_range_start and coalesce(ep.status,'unanswered')<>'declined'
    union all
    select s.id, (d::date + ps.start_time)::timestamp at time zone 'Asia/Tokyo',
      (d::date + ps.end_time)::timestamp at time zone 'Asia/Tokyo',
      case when s.id=a then 'BUSY_ONLY' else effective.effective_visibility::text end
    from selected s cross join group_context grp
      join public.user_courses uc on uc.owner_user_id=s.id and uc.deleted_at is null
    join public.terms t on t.id=uc.term_id and t.deleted_at is null
    join public.profiles p on p.user_id=s.id and p.deleted_at is null
    left join public.group_members gm on gm.group_id=p_group_id and gm.user_id=s.id
    join public.period_settings ps on ps.owner_user_id=s.id and ps.term_id=uc.term_id
      and ps.day_of_week=uc.day_of_week and ps.period_no=uc.period_no
    cross join lateral (select private.restrict_group_visibility(
      coalesce(uc.visibility_level,p.default_visibility,'PRIVATE'::public.visibility_level),
      coalesce(gm.visibility_level,grp.default_visibility,'PRIVATE'::public.visibility_level)
    ) effective_visibility) effective
    cross join lateral generate_series(greatest(t.start_date,(p_range_start at time zone 'Asia/Tokyo')::date),least(t.end_date,((p_range_end-interval '1 microsecond') at time zone 'Asia/Tokyo')::date),interval '1 day') d
    where extract(isodow from d)::int=uc.day_of_week
      and ((s.id=a) or (effective.effective_visibility<>'PRIVATE' and not private.is_blocked(s.id)))
      and ((d::date+ps.start_time)::timestamp at time zone 'Asia/Tokyo')<p_range_end
      and ((d::date+ps.end_time)::timestamp at time zone 'Asia/Tokyo')>p_range_start
    union all
    select s.id,ex.start_at,ex.end_at,
      case when s.id=a then 'BUSY_ONLY' else effective.effective_visibility::text end
    from selected s cross join group_context grp
      join public.exams ex on ex.owner_user_id=s.id and ex.deleted_at is null
    join public.profiles p on p.user_id=s.id and p.deleted_at is null
    left join public.group_members gm on gm.group_id=p_group_id and gm.user_id=s.id
    cross join lateral (select private.restrict_group_visibility(
      coalesce(ex.visibility_level,p.default_visibility,'PRIVATE'::public.visibility_level),
      coalesce(gm.visibility_level,grp.default_visibility,'PRIVATE'::public.visibility_level)
    ) effective_visibility) effective
    where ex.start_at<p_range_end and ex.end_at>p_range_start
      and ((s.id=a) or (effective.effective_visibility<>'PRIVATE' and not private.is_blocked(s.id)))
  )
  -- Busy intervals are intentionally aggregated without member attribution.
  select coalesce(jsonb_agg(jsonb_build_object('start_at',start_at,'end_at',end_at,'visibility_level',visibility_level) order by start_at),'[]'::jsonb) into rows from busy;
  return jsonb_build_object('query_id',q,'generation',gen,'member_ids',to_jsonb(p_member_ids),'rows',rows);
end; $$;

create or replace function public.validate_group_availability(
  p_group_id uuid,p_member_ids uuid[],p_generation text)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); current_generation text;
begin
  if a is null or p_member_ids is null or not (a=any(p_member_ids)) then
    raise exception 'availability validation denied' using errcode='42501'; end if;
  if not exists(select 1 from public.groups g where g.id=p_group_id and g.deleted_at is null)
     or exists(select 1 from unnest(p_member_ids) x where not exists(select 1 from public.group_members m where m.group_id=p_group_id and m.user_id=x)) then
    return jsonb_build_object('valid',false,'generation',null); end if;
  if exists(select 1 from unnest(p_member_ids) x where private.is_blocked(x)) then
    return jsonb_build_object('valid',false,'generation',null); end if;
  select md5(g.version::text||':'||coalesce(string_agg(m.user_id::text||':'||m.role||':'||m.joined_at::text,',' order by m.user_id),'')) into current_generation
    from public.groups g join public.group_members m on m.group_id=g.id and m.user_id=any(p_member_ids) where g.id=p_group_id group by g.version;
  return jsonb_build_object('valid',current_generation=p_generation,'generation',current_generation);
end; $$;
revoke all on function public.find_group_availability(uuid,uuid[],timestamptz,timestamptz,integer),public.validate_group_availability(uuid,uuid[],text) from public,anon;
grant execute on function public.find_group_availability(uuid,uuid[],timestamptz,timestamptz,integer),public.validate_group_availability(uuid,uuid[],text) to authenticated;
commit;
