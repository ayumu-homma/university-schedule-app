-- Phase 11: RPC-only group events and self RSVP.  Append-only; do not edit
-- the original events schema or earlier migrations.
begin;

create or replace function private.group_event_group(p_event_id uuid)
returns uuid language sql stable security definer
set search_path = pg_catalog, public, private as $$
  select e.group_id from public.events e
  join public.groups g on g.id=e.group_id and g.deleted_at is null
  where e.id=p_event_id and e.kind='group' and e.deleted_at is null;
$$;

create or replace function public.list_group_events(p_group_id uuid)
returns table(event_id uuid,group_id uuid,title text,start_at timestamptz,end_at timestamptz,
  location text,description text,created_by uuid,version bigint,cancelled boolean)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
begin
  if not private.group_member(p_group_id,auth.uid()) then
    raise exception 'group access denied' using errcode='42501';
  end if;
  return query select e.id,e.group_id,e.title,e.start_at,e.end_at,e.location,e.description,
    e.created_by,e.version,(e.deleted_at is not null)
    from public.events e where e.group_id=p_group_id and e.kind='group' and e.deleted_at is null
    order by e.start_at,e.id;
end; $$;

create or replace function public.get_group_event(p_event_id uuid)
returns table(event_id uuid,group_id uuid,title text,start_at timestamptz,end_at timestamptz,
  location text,description text,created_by uuid,version bigint,cancelled boolean)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
begin
  if not exists(select 1 from public.events e where e.id=p_event_id and e.kind='group'
    and e.deleted_at is null and private.group_member(e.group_id,auth.uid())) then
    raise exception 'event access denied' using errcode='42501';
  end if;
  return query select e.id,e.group_id,e.title,e.start_at,e.end_at,e.location,e.description,
    e.created_by,e.version,false from public.events e where e.id=p_event_id and e.kind='group'
    and e.deleted_at is null;
end; $$;

create or replace function public.list_group_event_rsvps(p_event_id uuid)
returns table(user_id uuid,status text,updated_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
declare g uuid;
begin
  g:=private.group_event_group(p_event_id);
  if g is null or not private.group_member(g,auth.uid()) then
    raise exception 'event access denied' using errcode='42501';
  end if;
  return query select m.user_id,coalesce(p.status,'unanswered'),p.updated_at from public.group_members m
    left join public.event_participants p on p.event_id=p_event_id and p.user_id=m.user_id
    where m.group_id=g order by m.user_id;
end; $$;

create or replace function public.create_group_event(
  p_group_id uuid,p_title text,p_start_at timestamptz,p_end_at timestamptz,
  p_location text,p_description text,p_operation_id uuid)
returns table(event_id uuid,group_id uuid,title text,start_at timestamptz,end_at timestamptz,
  location text,description text,created_by uuid,version bigint,cancelled boolean)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); h text; r jsonb; eid uuid; cid uuid; g record; e record;
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
    raise exception 'event creation denied' using errcode='42501'; end if;
  if r is not null then
    if not exists(select 1 from public.events x where x.id=(r->>'event_id')::uuid
      and x.group_id=p_group_id and x.kind='group' and x.deleted_at is null) then
      raise exception 'event replay is no longer active' using errcode='42501';
    end if;
    return query select (r->>'event_id')::uuid,(r->>'group_id')::uuid,r->>'title',(r->>'start_at')::timestamptz,(r->>'end_at')::timestamptz,nullif(r->>'location',''),nullif(r->>'description',''),(r->>'created_by')::uuid,(r->>'version')::bigint,false; return;
  end if;
  select c.id into cid from public.calendars c where c.group_id=p_group_id and c.deleted_at is null order by c.created_at limit 1 for update;
  if cid is null then insert into public.calendars(owner_user_id,group_id,name) values(a,p_group_id,g.name) returning id into cid; end if;
  insert into public.events(owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,location,description,timezone,created_by)
    values(a,cid,p_group_id,trim(p_title),'group',p_start_at,p_end_at,nullif(trim(p_location),''),nullif(trim(p_description),''),'Asia/Tokyo',a) returning * into e;
  r:=jsonb_build_object('event_id',e.id,'group_id',e.group_id,'title',e.title,'start_at',e.start_at,'end_at',e.end_at,'location',coalesce(e.location,''),'description',coalesce(e.description,''),'created_by',e.created_by,'version',e.version);
  perform private.group_record(a,p_operation_id,'create_group_event',h,r);
  return query select e.id,e.group_id,e.title,e.start_at,e.end_at,e.location,e.description,e.created_by,e.version,false;
end; $$;

create or replace function public.update_group_event(
  p_event_id uuid,p_title text,p_start_at timestamptz,p_end_at timestamptz,p_location text,
  p_description text,p_expected_version bigint,p_operation_id uuid)
returns table(event_id uuid,group_id uuid,title text,start_at timestamptz,end_at timestamptz,
  location text,description text,created_by uuid,version bigint,cancelled boolean)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); h text; r jsonb; e record; g uuid;
begin
  select x.group_id into g from public.events x where x.id=p_event_id and x.kind='group';
  if g is null then raise exception 'event unavailable' using errcode='42501'; end if;
  if p_expected_version is null or length(trim(coalesce(p_title,'')))<1 or length(p_title)>200
     or length(coalesce(p_location,''))>300 or length(coalesce(p_description,''))>5000
     or p_start_at is null or p_end_at is null or p_end_at<=p_start_at then
    raise exception 'invalid event' using errcode='22023'; end if;
  h:=encode(extensions.digest(jsonb_build_object('event_id',p_event_id,'title',trim(p_title),'start_at',p_start_at,'end_at',p_end_at,'location',coalesce(trim(p_location),''),'description',coalesce(trim(p_description),''),'expected_version',p_expected_version)::text,'sha256'),'hex');
  r:=private.group_lock(a,p_operation_id,'update_group_event',h);
  perform pg_advisory_xact_lock(hashtextextended('group:'||g::text,9010));
  select x.* into e from public.events x where x.id=p_event_id and x.deleted_at is null for update;
  if not found or not private.group_member(g,a) or not (e.created_by=a or private.group_admin(g,a)) then raise exception 'event edit denied' using errcode='42501'; end if;
  if r is not null then
    if e.version<>(r->>'version')::bigint then
      raise exception 'event replay is stale' using errcode='40001';
    end if;
    return query select (r->>'event_id')::uuid,(r->>'group_id')::uuid,r->>'title',(r->>'start_at')::timestamptz,(r->>'end_at')::timestamptz,nullif(r->>'location',''),nullif(r->>'description',''),(r->>'created_by')::uuid,(r->>'version')::bigint,false; return;
  end if;
  if e.version<>p_expected_version then raise exception 'event version conflict' using errcode='40001'; end if;
  update public.events x set title=trim(p_title),start_at=p_start_at,end_at=p_end_at,location=nullif(trim(p_location),''),description=nullif(trim(p_description),''),version=x.version+1,updated_at=now() where x.id=p_event_id returning * into e;
  r:=jsonb_build_object('event_id',e.id,'group_id',e.group_id,'title',e.title,'start_at',e.start_at,'end_at',e.end_at,'location',coalesce(e.location,''),'description',coalesce(e.description,''),'created_by',e.created_by,'version',e.version);
  perform private.group_record(a,p_operation_id,'update_group_event',h,r);
  return query select e.id,e.group_id,e.title,e.start_at,e.end_at,e.location,e.description,e.created_by,e.version,false;
end; $$;

create or replace function public.cancel_group_event(p_event_id uuid,p_expected_version bigint,p_operation_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); g uuid; e record; h text; r jsonb;
begin
  if p_expected_version is null then raise exception 'invalid event version' using errcode='22023'; end if;
  h:=encode(extensions.digest(jsonb_build_object('event_id',p_event_id,'expected_version',p_expected_version)::text,'sha256'),'hex');
  r:=private.group_lock(a,p_operation_id,'cancel_group_event',h);
  -- A successful cancellation has no authority-bearing response to revive.
  -- Return exact response-loss retries before looking for the now-deleted row.
  if r is not null then return; end if;
  select x.group_id into g from public.events x where x.id=p_event_id and x.kind='group';
  if g is null then raise exception 'event unavailable' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('group:'||g::text,9010));
  select x.* into e from public.events x where x.id=p_event_id and x.deleted_at is null for update;
  if not found or not private.group_member(g,a) or not (e.created_by=a or private.group_admin(g,a)) then raise exception 'event cancel denied' using errcode='42501'; end if;
  if e.version<>p_expected_version then raise exception 'event version conflict' using errcode='40001'; end if;
  update public.events set deleted_at=now(),updated_at=now(),version=version+1 where id=p_event_id;
  perform private.group_record(a,p_operation_id,'cancel_group_event',h,jsonb_build_object('event_id',p_event_id,'version',e.version+1));
end; $$;

create or replace function public.set_group_event_rsvp(p_event_id uuid,p_status text,p_operation_id uuid)
returns table(event_id uuid,user_id uuid,status text,updated_at timestamptz)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); g uuid; h text; r jsonb; p record;
begin
  select x.group_id into g from public.events x where x.id=p_event_id and x.kind='group';
  if g is null then raise exception 'event access denied' using errcode='42501'; end if;
  if p_status not in('attending','declined','tentative','unanswered') then raise exception 'invalid RSVP' using errcode='22023'; end if;
  h:=encode(extensions.digest(jsonb_build_object('event_id',p_event_id,'status',p_status)::text,'sha256'),'hex');
  r:=private.group_lock(a,p_operation_id,'set_group_event_rsvp',h);
  perform pg_advisory_xact_lock(hashtextextended('group:'||g::text,9010));
  if not exists(select 1 from public.events e where e.id=p_event_id and e.kind='group' and e.deleted_at is null)
     or not private.group_member(g,a) then raise exception 'event access denied' using errcode='42501'; end if;
  if r is not null then
    if not exists(select 1 from public.event_participants x
      where x.event_id=p_event_id and x.user_id=a and x.status=r->>'status'
        and x.updated_at=(r->>'updated_at')::timestamptz) then
      raise exception 'RSVP replay is stale' using errcode='40001';
    end if;
    return query select (r->>'event_id')::uuid,(r->>'user_id')::uuid,r->>'status',(r->>'updated_at')::timestamptz; return;
  end if;
  insert into public.event_participants(event_id,user_id,status,updated_at)
    values(p_event_id,a,p_status,now())
    on conflict on constraint event_participants_pkey
    do update set status=excluded.status,updated_at=excluded.updated_at
    returning * into p;
  perform private.group_record(a,p_operation_id,'set_group_event_rsvp',h,jsonb_build_object('event_id',p.event_id,'user_id',p.user_id,'status',p.status,'updated_at',p.updated_at));
  return query select p.event_id,p.user_id,p.status,p.updated_at;
end; $$;

-- Group events are deliberately outside the personal schedule delta and raw
-- table surface.  Existing personal-event policies remain available only for
-- rows whose group_id is null.
create or replace function private.record_schedule_change()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,private,realtime as $$
declare bound_owner uuid; bound_entity_type text:=tg_argv[0]; bound_entity_id uuid;
  bound_version bigint; bound_deleted_at timestamptz; bound_payload jsonb; bound_cursor bigint;
begin
  if bound_entity_type='event' and new.group_id is not null then return new; end if;
  if bound_entity_type='assignment_user_state' then bound_owner:=new.user_id; bound_entity_id:=new.assignment_id;
  elsif bound_entity_type='event_exception' then bound_owner:=new.owner_user_id; bound_entity_id:=new.id;
  else bound_owner:=new.owner_user_id; bound_entity_id:=new.id; end if;
  bound_version:=new.version; bound_deleted_at:=new.deleted_at;
  bound_payload:=case when bound_entity_type='event_exception' then private.schedule_event_exception_payload(bound_owner,bound_entity_id)
    else private.schedule_entity_payload(bound_owner,bound_entity_type,bound_entity_id) end;
  if bound_payload is null then raise exception 'schedule entity payload is unavailable' using errcode='42501'; end if;
  insert into private.schedule_change_log(owner_user_id,change_cursor,entity_type,entity_id,operation,server_version,deleted_at,payload)
    values(bound_owner,private.next_schedule_cursor(bound_owner),bound_entity_type,bound_entity_id,
      case when bound_deleted_at is null then 'upsert' else 'delete' end,bound_version,bound_deleted_at,bound_payload)
    returning change_cursor into bound_cursor;
  perform realtime.send(jsonb_build_object('cursor',bound_cursor),'invalidate','schedule-sync:'||bound_owner::text,true);
  return new;
end; $$;
drop trigger if exists events_schedule_change on public.events;
drop trigger if exists events_schedule_change_insert on public.events;
drop trigger if exists events_schedule_change_update on public.events;
create trigger events_schedule_change_insert after insert on public.events for each row
  when (new.group_id is null) execute function private.record_schedule_change('event');
create trigger events_schedule_change_update after update on public.events for each row
  when (new.group_id is null and old.group_id is null)
  execute function private.record_schedule_change('event');

drop policy if exists events_owner_original_read on public.events;
create policy events_owner_original_read on public.events for select to authenticated
  using (owner_user_id=auth.uid() and group_id is null);
drop policy if exists events_group_editor_read on public.events;
drop policy if exists events_scoped_insert on public.events;
drop policy if exists events_scoped_update on public.events;
drop policy if exists events_scoped_delete on public.events;
create policy events_personal_scoped_insert on public.events for insert to authenticated
  with check (group_id is null and private.can_create_event(owner_user_id,created_by,calendar_id,null));
create policy events_personal_scoped_update on public.events for update to authenticated
  using (group_id is null and private.can_edit_event(id))
  with check (group_id is null and private.can_write_event_values(owner_user_id,created_by,calendar_id,null));
create policy events_personal_scoped_delete on public.events for delete to authenticated
  using (group_id is null and private.can_edit_event(id));
drop policy if exists event_participants_visible_members on public.event_participants;
drop policy if exists event_participants_self_write on public.event_participants;
create policy event_participants_personal_read on public.event_participants for select to authenticated
  using (user_id=auth.uid() and exists(select 1 from public.events e where e.id=event_id and e.group_id is null));
create policy event_participants_personal_write on public.event_participants for all to authenticated
  using (user_id=auth.uid() and exists(select 1 from public.events e where e.id=event_id and e.group_id is null))
  with check (user_id=auth.uid() and exists(select 1 from public.events e where e.id=event_id and e.group_id is null));

revoke all on function private.group_event_group(uuid) from public,anon,authenticated;
revoke all on function public.list_group_events(uuid),public.get_group_event(uuid),public.list_group_event_rsvps(uuid),public.create_group_event(uuid,text,timestamptz,timestamptz,text,text,uuid),public.update_group_event(uuid,text,timestamptz,timestamptz,text,text,bigint,uuid),public.cancel_group_event(uuid,bigint,uuid),public.set_group_event_rsvp(uuid,text,uuid) from public,anon;
grant execute on function public.list_group_events(uuid),public.get_group_event(uuid),public.list_group_event_rsvps(uuid),public.create_group_event(uuid,text,timestamptz,timestamptz,text,text,uuid),public.update_group_event(uuid,text,timestamptz,timestamptz,text,text,bigint,uuid),public.cancel_group_event(uuid,bigint,uuid),public.set_group_event_rsvp(uuid,text,uuid) to authenticated;
commit;
