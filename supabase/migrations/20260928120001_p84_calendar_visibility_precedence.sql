begin;

-- The calendar level precedes the group fallback when a group event is
-- created without an explicit event-level visibility choice.
create or replace function public.create_group_event(
  p_group_id uuid,p_title text,p_start_at timestamptz,p_end_at timestamptz,
  p_location text,p_description text,p_operation_id uuid)
returns table(event_id uuid,group_id uuid,title text,start_at timestamptz,end_at timestamptz,
  location text,description text,created_by uuid,version bigint,cancelled boolean)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); h text; r jsonb; eid uuid; cid uuid; cv public.visibility_level;
  g record; e record;
begin
  if a is null then raise exception 'not authenticated' using errcode='42501'; end if;
  if length(trim(coalesce(p_title,'')))<1 or length(p_title)>200 or length(coalesce(p_location,''))>300
     or length(coalesce(p_description,''))>5000 or p_start_at is null or p_end_at is null
     or p_end_at<=p_start_at then raise exception 'invalid event' using errcode='22023'; end if;
  h:=encode(extensions.digest(jsonb_build_object('group_id',p_group_id,'title',trim(p_title),'start_at',p_start_at,'end_at',p_end_at,'location',coalesce(trim(p_location),''),'description',coalesce(trim(p_description),''))::text,'sha256'),'hex');
  r:=private.group_lock(a,p_operation_id,'create_group_event',h);
  perform pg_advisory_xact_lock(hashtextextended('group:'||p_group_id::text,9010));
  select x.* into g from public.groups x join public.group_members m on m.group_id=x.id
    and m.user_id=a where x.id=p_group_id and x.deleted_at is null for update;
  if not found or not (case g.event_create_policy when 'member' then true when 'admin' then g.owner_user_id=a or exists(select 1 from public.group_members m where m.group_id=p_group_id and m.user_id=a and m.role='admin') when 'owner' then g.owner_user_id=a else false end) then
    raise exception 'event creation denied' using errcode='42501';
  end if;
  if r is not null then
    if not exists(select 1 from public.events x where x.id=(r->>'event_id')::uuid
      and x.group_id=p_group_id and x.kind='group' and x.deleted_at is null) then
      raise exception 'event replay is no longer active' using errcode='42501';
    end if;
    return query select (r->>'event_id')::uuid,(r->>'group_id')::uuid,r->>'title',
      (r->>'start_at')::timestamptz,(r->>'end_at')::timestamptz,nullif(r->>'location',''),
      nullif(r->>'description',''),(r->>'created_by')::uuid,(r->>'version')::bigint,false;
    return;
  end if;
  select c.id,c.default_visibility into cid,cv from public.calendars c where c.group_id=p_group_id
    and c.deleted_at is null order by c.created_at limit 1 for update;
  if cid is null then
    insert into public.calendars(owner_user_id,group_id,name,default_visibility)
      values(a,p_group_id,g.name,g.default_visibility)
      returning id,default_visibility into cid,cv;
  end if;
  insert into public.events(owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,
    location,description,timezone,visibility_level,created_by)
  values(a,cid,p_group_id,trim(p_title),'group',p_start_at,p_end_at,nullif(trim(p_location),''),
    nullif(trim(p_description),''),'Asia/Tokyo',coalesce(cv,g.default_visibility),a)
  returning * into e;
  r:=jsonb_build_object('event_id',e.id,'group_id',e.group_id,'title',e.title,
    'start_at',e.start_at,'end_at',e.end_at,'location',coalesce(e.location,''),
    'description',coalesce(e.description,''),'created_by',e.created_by,'version',e.version);
  perform private.group_record(a,p_operation_id,'create_group_event',h,r);
  return query select e.id,e.group_id,e.title,e.start_at,e.end_at,e.location,e.description,
    e.created_by,e.version,false;
end;
$$;

commit;
