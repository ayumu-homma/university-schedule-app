-- Phase 15: global-admin moderation, immutable audit, and hidden UGC.
-- Append-only.  Do not edit or replay this file against the Phase 6 data store
-- from an application role; the owner/fixture registration path is DB-admin only.
begin;

create table if not exists private.global_admins(
  user_id uuid primary key references auth.users(id) on delete cascade,
  granted_at timestamptz not null default now(),
  granted_by uuid references auth.users(id),
  revoked_at timestamptz
);
revoke all on private.global_admins from public,anon,authenticated;

create table if not exists private.admin_operation_receipts(
  actor_user_id uuid not null references auth.users(id) on delete cascade,
  operation_id uuid not null,
  operation_name text not null,
  request_hash text not null,
  response jsonb not null,
  created_at timestamptz not null default now(),
  primary key(actor_user_id,operation_id)
);
revoke all on private.admin_operation_receipts from public,anon,authenticated;

alter table public.events
  add column if not exists moderation_hidden_at timestamptz,
  add column if not exists moderation_hidden_by uuid references auth.users(id);
alter table public.event_comments
  add column if not exists moderation_hidden_at timestamptz,
  add column if not exists moderation_hidden_by uuid references auth.users(id);
alter table public.reports
  add column if not exists resolved_by uuid references auth.users(id),
  add column if not exists resolved_at timestamptz,
  add column if not exists decision_reason text,
  add column if not exists target_state text;

create index if not exists reports_pending_created_idx
  on public.reports(created_at,id) where status='pending';
create index if not exists audit_logs_created_idx on public.audit_logs(created_at,id);

create or replace function private.is_global_admin(p_user_id uuid default auth.uid())
returns boolean language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select p_user_id is not null and exists(
    select 1 from private.global_admins a
    where a.user_id=p_user_id and a.revoked_at is null
  );
$$;

create or replace function private.require_global_admin()
returns uuid language plpgsql stable security definer
set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid();
begin
  if a is null or not private.is_global_admin(a) then
    raise exception 'global admin required' using errcode='42501';
  end if;
  return a;
end; $$;

create or replace function private.admin_lock(a uuid,o uuid,n text,h text)
returns jsonb language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare r jsonb; old_hash text; old_name text;
begin
  if a is null or o is null then raise exception 'operation id is required' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('admin-op:'||a::text||':'||o::text,9010));
  select response,request_hash,operation_name into r,old_hash,old_name
    from private.admin_operation_receipts
    where actor_user_id=a and operation_id=o for update;
  if r is not null and (old_hash<>h or old_name<>n) then
    raise exception 'operation replay mismatch' using errcode='40001';
  end if;
  return r;
end; $$;

create or replace function private.admin_record(a uuid,o uuid,n text,h text,r jsonb)
returns void language sql security definer
set search_path=pg_catalog,public,private as $$
  insert into private.admin_operation_receipts(actor_user_id,operation_id,operation_name,request_hash,response)
  values(a,o,n,h,r) on conflict(actor_user_id,operation_id) do nothing;
$$;

create or replace function private.phase15_raw_event_group(p_event_id uuid)
returns uuid language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select e.group_id from public.events e
  where e.id=p_event_id and e.kind='group' and e.deleted_at is null
    and e.moderation_hidden_at is null;
$$;

create or replace function private.phase15_raw_comment_group(p_comment_id uuid)
returns uuid language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select e.group_id from public.event_comments c
  join public.events e on e.id=c.event_id and e.kind='group'
    and e.deleted_at is null and e.moderation_hidden_at is null
  where c.id=p_comment_id and c.deleted_at is null and c.moderation_hidden_at is null;
$$;

create or replace function private.phase13_raw_event_group(p_event_id uuid)
returns uuid language sql stable security definer
set search_path=pg_catalog,public,private as $$ select private.phase15_raw_event_group(p_event_id); $$;
create or replace function private.phase13_raw_comment_group(p_comment_id uuid)
returns uuid language sql stable security definer
set search_path=pg_catalog,public,private as $$ select private.phase15_raw_comment_group(p_comment_id); $$;
create or replace function private.phase13_active_event_group(p_event_id uuid)
returns uuid language sql stable security definer
set search_path=pg_catalog,public,private as $$ select private.phase15_raw_event_group(p_event_id); $$;
create or replace function private.phase13_event_generation(p_event_id uuid)
returns text language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select md5(e.version::text||':'||g.version::text||':'||coalesce(
    (select string_agg(m.user_id::text||':'||m.role||':'||coalesce(extract(epoch from m.joined_at)::text,''),',' order by m.user_id)
       from public.group_members m where m.group_id=e.group_id),''))
  from public.events e join public.groups g on g.id=e.group_id and g.deleted_at is null
  where e.id=p_event_id and e.kind='group' and e.deleted_at is null and e.moderation_hidden_at is null;
$$;

-- Re-declare normal group projections/mutators so moderation state is not
-- bypassed by a stale receipt, old client, or a lower-level RPC.
create or replace function public.list_group_events(p_group_id uuid)
returns table(event_id uuid,group_id uuid,title text,start_at timestamptz,end_at timestamptz,location text,description text,created_by uuid,version bigint,cancelled boolean)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
begin
  if not private.group_member(p_group_id,auth.uid()) then raise exception 'group access denied' using errcode='42501'; end if;
  return query select e.id,e.group_id,e.title,e.start_at,e.end_at,e.location,e.description,e.created_by,e.version,false
    from public.events e where e.group_id=p_group_id and e.kind='group' and e.deleted_at is null and e.moderation_hidden_at is null
    order by e.start_at,e.id;
end; $$;

create or replace function public.get_group_event(p_event_id uuid)
returns table(event_id uuid,group_id uuid,title text,start_at timestamptz,end_at timestamptz,location text,description text,created_by uuid,version bigint,cancelled boolean)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
begin
  if private.phase15_raw_event_group(p_event_id) is null or not private.group_member((select e.group_id from public.events e where e.id=p_event_id),auth.uid()) then
    raise exception 'event access denied' using errcode='42501';
  end if;
  return query select e.id,e.group_id,e.title,e.start_at,e.end_at,e.location,e.description,e.created_by,e.version,false
    from public.events e where e.id=p_event_id and e.kind='group' and e.deleted_at is null and e.moderation_hidden_at is null;
end; $$;

create or replace function public.list_group_event_rsvps(p_event_id uuid)
returns table(user_id uuid,status text,updated_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
declare g uuid:=private.phase15_raw_event_group(p_event_id);
begin
  if g is null or not private.group_member(g,auth.uid()) then raise exception 'event access denied' using errcode='42501'; end if;
  return query select m.user_id,coalesce(p.status,'unanswered'),p.updated_at from public.group_members m
    left join public.event_participants p on p.event_id=p_event_id and p.user_id=m.user_id where m.group_id=g order by m.user_id;
end; $$;

create or replace function public.get_group_event_ugc(p_event_id uuid)
returns table(event_id uuid,group_id uuid,generation text,rsvps jsonb,comments jsonb,reactions jsonb)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
declare g uuid; gen text;
begin
  g:=private.phase15_raw_event_group(p_event_id);
  if g is null or not private.group_member(g,auth.uid()) then raise exception 'event access denied' using errcode='42501'; end if;
  gen:=private.phase13_event_generation(p_event_id);
  return query select p.id,p.group_id,gen,
    coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'status',coalesce(r.status,'unanswered'),'updated_at',r.updated_at) order by m.user_id) from public.group_members m left join public.event_participants r on r.event_id=p_event_id and r.user_id=m.user_id where m.group_id=g),'[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object('comment_id',c.id,'event_id',c.event_id,'author_user_id',c.author_user_id,'body',c.body,'created_at',c.created_at,'updated_at',c.updated_at,'version',c.version) order by c.created_at,c.id) from public.event_comments c where c.event_id=p_event_id and c.deleted_at is null and c.moderation_hidden_at is null),'[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object('reaction',z.reaction,'reaction_count',z.reaction_count,'reacted_by_me',z.reacted_by_me) order by z.reaction) from (select r.reaction,count(*)::bigint reaction_count,bool_or(r.user_id=auth.uid()) reacted_by_me from public.event_reactions r where r.event_id=p_event_id group by r.reaction) z),'[]'::jsonb)
    from public.events p where p.id=p_event_id and p.moderation_hidden_at is null;
end; $$;

create or replace function public.list_group_event_comments(p_event_id uuid)
returns table(comment_id uuid,event_id uuid,author_user_id uuid,body text,created_at timestamptz,updated_at timestamptz,version bigint)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
declare g uuid:=private.phase15_raw_event_group(p_event_id);
begin
  if g is null or not private.group_member(g,auth.uid()) then raise exception 'event access denied' using errcode='42501'; end if;
  return query select c.id,c.event_id,c.author_user_id,c.body,c.created_at,c.updated_at,c.version from public.event_comments c
    where c.event_id=p_event_id and c.deleted_at is null and c.moderation_hidden_at is null order by c.created_at,c.id;
end; $$;

-- Existing writer bodies retain their operation receipts, but target lookup
-- now uses the moderation-aware helpers.  This prevents edit/delete/reaction/
-- RSVP/report replays from reviving or touching hidden content.
create or replace function public.update_group_event(p_event_id uuid,p_title text,p_start_at timestamptz,p_end_at timestamptz,p_location text,p_description text,p_expected_version bigint,p_operation_id uuid)
returns table(event_id uuid,group_id uuid,title text,start_at timestamptz,end_at timestamptz,location text,description text,created_by uuid,version bigint,cancelled boolean)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); g uuid:=private.phase15_raw_event_group(p_event_id); h text; r jsonb; e record;
begin
  if g is null then raise exception 'event unavailable' using errcode='42501'; end if;
  if p_expected_version is null or length(trim(coalesce(p_title,'')))<1 or length(p_title)>200 or length(coalesce(p_location,''))>300 or length(coalesce(p_description,''))>5000 or p_start_at is null or p_end_at is null or p_end_at<=p_start_at then raise exception 'invalid event' using errcode='22023'; end if;
  h:=encode(extensions.digest(jsonb_build_object('event_id',p_event_id,'title',trim(p_title),'start_at',p_start_at,'end_at',p_end_at,'location',coalesce(trim(p_location),''),'description',coalesce(trim(p_description),''),'expected_version',p_expected_version)::text,'sha256'),'hex');
  r:=private.group_lock(a,p_operation_id,'update_group_event',h); perform pg_advisory_xact_lock(hashtextextended('group:'||g::text,9010));
  select x.* into e from public.events x where x.id=p_event_id and x.deleted_at is null and x.moderation_hidden_at is null for update;
  if not found or not private.group_member(g,a) or not (e.created_by=a or private.group_admin(g,a)) then raise exception 'event edit denied' using errcode='42501'; end if;
  if r is not null then if e.version<>(r->>'version')::bigint then raise exception 'event replay is stale' using errcode='40001'; end if; return query select (r->>'event_id')::uuid,(r->>'group_id')::uuid,r->>'title',(r->>'start_at')::timestamptz,(r->>'end_at')::timestamptz,nullif(r->>'location',''),nullif(r->>'description',''),(r->>'created_by')::uuid,(r->>'version')::bigint,false; return; end if;
  if e.version<>p_expected_version then raise exception 'event version conflict' using errcode='40001'; end if;
  update public.events x set title=trim(p_title),start_at=p_start_at,end_at=p_end_at,location=nullif(trim(p_location),''),description=nullif(trim(p_description),''),version=x.version+1,updated_at=now() where x.id=p_event_id returning * into e;
  r:=jsonb_build_object('event_id',e.id,'group_id',e.group_id,'title',e.title,'start_at',e.start_at,'end_at',e.end_at,'location',coalesce(e.location,''),'description',coalesce(e.description,''),'created_by',e.created_by,'version',e.version); perform private.group_record(a,p_operation_id,'update_group_event',h,r);
  return query select e.id,e.group_id,e.title,e.start_at,e.end_at,e.location,e.description,e.created_by,e.version,false;
end; $$;

create or replace function public.set_group_event_rsvp(p_event_id uuid,p_status text,p_operation_id uuid)
returns table(event_id uuid,user_id uuid,status text,updated_at timestamptz)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); g uuid:=private.phase15_raw_event_group(p_event_id); h text; r jsonb; p record;
begin
  if g is null or p_status not in('attending','declined','tentative','unanswered') or not private.group_member(g,a) then raise exception 'event access denied' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('event_id',p_event_id,'status',p_status)::text,'sha256'),'hex'); r:=private.group_lock(a,p_operation_id,'set_group_event_rsvp',h); perform pg_advisory_xact_lock(hashtextextended('group:'||g::text,9010));
  if r is not null then return query select (r->>'event_id')::uuid,(r->>'user_id')::uuid,r->>'status',(r->>'updated_at')::timestamptz; return; end if;
  insert into public.event_participants(event_id,user_id,status,updated_at) values(p_event_id,a,p_status,now()) on conflict(event_id,user_id) do update set status=excluded.status,updated_at=excluded.updated_at returning * into p;
  perform private.group_record(a,p_operation_id,'set_group_event_rsvp',h,jsonb_build_object('event_id',p.event_id,'user_id',p.user_id,'status',p.status,'updated_at',p.updated_at)); return query select p.event_id,p.user_id,p.status,p.updated_at;
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
  if length(trim(coalesce(p_title,'')))<1 or length(p_title)>200 or length(coalesce(p_location,''))>300 or length(coalesce(p_description,''))>5000 or p_start_at is null or p_end_at is null or p_end_at<=p_start_at then raise exception 'invalid event' using errcode='22023'; end if;
  h:=encode(extensions.digest(jsonb_build_object('group_id',p_group_id,'title',trim(p_title),'start_at',p_start_at,'end_at',p_end_at,'location',coalesce(trim(p_location),''),'description',coalesce(trim(p_description),''))::text,'sha256'),'hex');
  r:=private.group_lock(a,p_operation_id,'create_group_event',h); perform pg_advisory_xact_lock(hashtextextended('group:'||p_group_id::text,9010));
  select x.* into g from public.groups x join public.group_members m on m.group_id=x.id and m.user_id=a where x.id=p_group_id and x.deleted_at is null for update;
  if not found or not (case g.event_create_policy when 'member' then true when 'admin' then g.owner_user_id=a or exists(select 1 from public.group_members m where m.group_id=p_group_id and m.user_id=a and m.role='admin') when 'owner' then g.owner_user_id=a else false end) then raise exception 'event creation denied' using errcode='42501'; end if;
  if r is not null then
    if not exists(select 1 from public.events x where x.id=(r->>'event_id')::uuid and x.group_id=p_group_id and x.kind='group' and x.deleted_at is null and x.moderation_hidden_at is null) then raise exception 'event replay is no longer active' using errcode='42501'; end if;
    return query select (r->>'event_id')::uuid,(r->>'group_id')::uuid,r->>'title',(r->>'start_at')::timestamptz,(r->>'end_at')::timestamptz,nullif(r->>'location',''),nullif(r->>'description',''),(r->>'created_by')::uuid,(r->>'version')::bigint,false; return;
  end if;
  select c.id into cid from public.calendars c where c.group_id=p_group_id and c.deleted_at is null order by c.created_at limit 1 for update;
  if cid is null then insert into public.calendars(owner_user_id,group_id,name) values(a,p_group_id,g.name) returning id into cid; end if;
  insert into public.events(owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,location,description,timezone,created_by) values(a,cid,p_group_id,trim(p_title),'group',p_start_at,p_end_at,nullif(trim(p_location),''),nullif(trim(p_description),''),'Asia/Tokyo',a) returning * into e;
  r:=jsonb_build_object('event_id',e.id,'group_id',e.group_id,'title',e.title,'start_at',e.start_at,'end_at',e.end_at,'location',coalesce(e.location,''),'description',coalesce(e.description,''),'created_by',e.created_by,'version',e.version);
  perform private.group_record(a,p_operation_id,'create_group_event',h,r); return query select e.id,e.group_id,e.title,e.start_at,e.end_at,e.location,e.description,e.created_by,e.version,false;
end; $$;

create or replace function public.admin_list_pending_reports(p_limit int default 50,p_offset int default 0)
returns table(report_id uuid,target_type text,target_id uuid,reason text,status text,created_at timestamptz,reporter_user_id uuid,reporter_display_name text,target_state text)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
begin
  perform private.require_global_admin();
  if p_limit is null or p_limit<1 or p_limit>100 or p_offset is null or p_offset<0 then raise exception 'invalid pagination' using errcode='22023'; end if;
  return query select r.id,r.target_type,r.target_id,r.reason,r.status,r.created_at,r.reporter_user_id,coalesce(p.display_name,'利用者'),r.target_state
    from public.reports r left join public.profiles p on p.user_id=r.reporter_user_id
    where r.status='pending' order by r.created_at,r.id limit p_limit offset p_offset;
end; $$;

create or replace function public.admin_get_report(p_report_id uuid)
returns table(report_id uuid,target_type text,target_id uuid,reason text,status text,created_at timestamptz,reporter_user_id uuid,reporter_display_name text,target_state text,decision_reason text,resolved_by uuid,resolved_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
begin
  perform private.require_global_admin();
  return query select r.id,r.target_type,r.target_id,r.reason,r.status,r.created_at,r.reporter_user_id,coalesce(p.display_name,'利用者'),r.target_state,r.decision_reason,r.resolved_by,r.resolved_at
    from public.reports r left join public.profiles p on p.user_id=r.reporter_user_id where r.id=p_report_id;
end; $$;

create or replace function public.admin_resolve_report(p_report_id uuid,p_action text,p_reason text,p_operation_id uuid)
returns table(report_id uuid,status text,action text,target_state text,audit_id uuid)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=private.require_global_admin(); h text; r jsonb; q record; e record; c record; state text; aid uuid; target_group uuid;
begin
  if p_action not in('dismiss','hide') or length(trim(coalesce(p_reason,'')))<1 or length(p_reason)>1000 then raise exception 'invalid moderation decision' using errcode='22023'; end if;
  h:=encode(extensions.digest(jsonb_build_object('report_id',p_report_id,'action',p_action,'reason',trim(p_reason))::text,'sha256'),'hex');
  r:=private.admin_lock(a,p_operation_id,'admin_resolve_report',h);
  if r is not null then return query select (r->>'report_id')::uuid,r->>'status',r->>'action',r->>'target_state',(r->>'audit_id')::uuid; return; end if;
  select x.* into q from public.reports x where x.id=p_report_id for update;
  if not found then raise exception 'report unavailable' using errcode='42501'; end if;
  if q.status<>'pending' then raise exception 'report already resolved' using errcode='40001'; end if;
  state:=case when p_action='dismiss' then 'unchanged' else 'hidden' end;
  if p_action='hide' then
    if q.target_type='event' then
      select x.* into e from public.events x where x.id=q.target_id and x.kind='group' for update;
      if not found then raise exception 'report target unavailable' using errcode='42501'; end if;
      if e.deleted_at is not null then state:='already_deleted'; elsif e.moderation_hidden_at is null then update public.events set moderation_hidden_at=now(),moderation_hidden_by=a,updated_at=now(),version=version+1 where id=q.target_id; end if;
    elsif q.target_type='comment' then
      select x.* into c from public.event_comments x where x.id=q.target_id for update;
      if not found then raise exception 'report target unavailable' using errcode='42501'; end if;
      if c.deleted_at is not null then state:='already_deleted'; elsif c.moderation_hidden_at is null then update public.event_comments set moderation_hidden_at=now(),moderation_hidden_by=a,updated_at=now(),version=version+1 where id=q.target_id; end if;
    else raise exception 'unsupported report target' using errcode='22023'; end if;
  end if;
  update public.reports set status=case when p_action='dismiss' then 'dismissed' else 'actioned' end,resolved_by=a,resolved_at=now(),decision_reason=trim(p_reason),target_state=state where id=p_report_id;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata) values(a,'moderation_'||p_action,q.target_type,q.target_id,jsonb_build_object('report_id',q.id,'reason',trim(p_reason),'previous_status',q.status,'new_status',case when p_action='dismiss' then 'dismissed' else 'actioned' end,'target_state',state)) returning id into aid;
  r:=jsonb_build_object('report_id',p_report_id,'status',case when p_action='dismiss' then 'dismissed' else 'actioned' end,'action',p_action,'target_state',state,'audit_id',aid);
  perform private.admin_record(a,p_operation_id,'admin_resolve_report',h,r);
  return query select p_report_id,r->>'status',p_action,state,aid;
end; $$;

create or replace function public.admin_list_audit_logs(p_limit int default 50,p_offset int default 0)
returns table(audit_id uuid,actor_user_id uuid,action text,target_type text,target_id uuid,metadata jsonb,created_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
begin
  perform private.require_global_admin();
  if p_limit is null or p_limit<1 or p_limit>100 or p_offset is null or p_offset<0 then raise exception 'invalid pagination' using errcode='22023'; end if;
  return query select l.id,l.actor_user_id,l.action,l.target_type,l.target_id,l.metadata,l.created_at from public.audit_logs l order by l.created_at desc,l.id desc limit p_limit offset p_offset;
end; $$;

alter table public.audit_logs enable row level security;
revoke all on public.audit_logs,public.reports,private.global_admins,private.admin_operation_receipts from public,anon,authenticated;
revoke all on function private.is_global_admin(uuid),private.require_global_admin(),private.admin_lock(uuid,uuid,text,text),private.admin_record(uuid,uuid,text,text,jsonb),private.phase15_raw_event_group(uuid),private.phase15_raw_comment_group(uuid) from public,anon,authenticated;
revoke all on function public.admin_list_pending_reports(int,int),public.admin_get_report(uuid),public.admin_resolve_report(uuid,text,text,uuid),public.admin_list_audit_logs(int,int) from public,anon;
grant execute on function public.admin_list_pending_reports(int,int),public.admin_get_report(uuid),public.admin_resolve_report(uuid,text,text,uuid),public.admin_list_audit_logs(int,int) to authenticated;

-- Direct authenticated UPDATE/DELETE of audit evidence remains impossible;
-- only the SECURITY DEFINER resolution function inserts rows.
revoke update,delete,truncate on public.audit_logs from public,anon,authenticated;
commit;

-- Phase 15 follow-up repairs from the security review.  Append-only.
begin;

-- Keep the established friend resolver contract while moving its original
-- body under a private base name and adding the moderation predicate.  This
-- avoids duplicating the privacy-resolution algorithm and keeps all callers'
-- signatures unchanged.
do $$
declare d text;
begin
  select pg_get_functiondef('private.resolve_visible_events_for(uuid,timestamptz,timestamptz)'::regprocedure) into d;
  if position('phase15_resolve_visible_events_for_base' in d)=0 then
    d:=replace(d,'private.resolve_visible_events_for(', 'private.phase15_resolve_visible_events_for_base(');
    d:=replace(d,'where e.deleted_at is null','where e.deleted_at is null and e.moderation_hidden_at is null');
    execute d;
  end if;
end $$;

create or replace function private.resolve_visible_events_for(
  p_viewer uuid,p_range_start timestamptz,p_range_end timestamptz)
returns table(event_id uuid,owner_user_id uuid,start_at timestamptz,end_at timestamptz,
  visibility_level public.visibility_level,title text,location text,description text,kind text,group_id uuid)
language sql security definer stable
set search_path=pg_catalog,public,private as $$
  select b.* from private.phase15_resolve_visible_events_for_base(p_viewer,p_range_start,p_range_end) b
  join public.events e on e.id=b.event_id and e.moderation_hidden_at is null;
$$;
revoke all on function private.phase15_resolve_visible_events_for_base(uuid,timestamptz,timestamptz) from public,anon,authenticated;

-- Group availability generation includes event moderation/version state, so a
-- fetch made before hide cannot validate after hide.
create or replace function private.phase15_group_availability_generation(p_group_id uuid,p_member_ids uuid[])
returns text language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select md5(g.version::text||':'||coalesce(string_agg(m.user_id::text||':'||m.role||':'||m.joined_at::text,',' order by m.user_id),'')||':'||coalesce((select string_agg(e.id::text||':'||e.version::text||':'||coalesce(extract(epoch from e.moderation_hidden_at)::text,''),',' order by e.id) from public.events e where e.group_id=g.id and e.kind='group' and e.deleted_at is null),''))
  from public.groups g join public.group_members m on m.group_id=g.id and m.user_id=any(p_member_ids)
  where g.id=p_group_id and g.deleted_at is null group by g.id,g.version;
$$;
revoke all on function private.phase15_group_availability_generation(uuid,uuid[]) from public,anon,authenticated;

create or replace function public.find_group_availability(
  p_group_id uuid,p_member_ids uuid[],p_range_start timestamptz,p_range_end timestamptz,
  p_minimum_duration_minutes integer)
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); q uuid:=gen_random_uuid(); gen text; rows jsonb;
begin
  if a is null then raise exception 'not authenticated' using errcode='42501'; end if;
  if p_member_ids is null or cardinality(p_member_ids)<1 or cardinality(p_member_ids)>20 or p_range_end is null or p_range_start is null or p_range_end<=p_range_start or p_range_end-p_range_start>interval '14 days' or p_minimum_duration_minutes is null or p_minimum_duration_minutes<1 or p_minimum_duration_minutes>1440 or not (a=any(p_member_ids)) then raise exception 'invalid availability request' using errcode='22023'; end if;
  if cardinality(p_member_ids)<>cardinality(array(select distinct x from unnest(p_member_ids) x)) then raise exception 'duplicate member selection' using errcode='42501'; end if;
  if not exists(select 1 from public.groups g where g.id=p_group_id and g.deleted_at is null) or exists(select 1 from unnest(p_member_ids) selected(id) where not exists(select 1 from public.group_members m where m.group_id=p_group_id and m.user_id=selected.id)) or exists(select 1 from unnest(p_member_ids) selected(id) where private.is_blocked(selected.id)) then raise exception 'membership or authorization changed; retry' using errcode='42501'; end if;
  gen:=private.phase15_group_availability_generation(p_group_id,p_member_ids);
  with selected as (select unnest(p_member_ids) id), group_context as (select default_visibility from public.groups where id=p_group_id and deleted_at is null), busy as (
    select s.id member_id,e.start_at,e.end_at,case when s.id=a then 'BUSY_ONLY' else effective.effective_visibility::text end visibility_level
    from selected s join public.events e on e.owner_user_id=s.id and e.group_id is null cross join group_context grp join public.profiles p on p.user_id=s.id and p.deleted_at is null left join public.calendars c on c.id=e.calendar_id and c.deleted_at is null left join public.group_members gm on gm.group_id=p_group_id and gm.user_id=s.id cross join lateral (select private.restrict_group_visibility(coalesce(e.visibility_level,c.default_visibility,p.default_visibility,'PRIVATE'::public.visibility_level),coalesce(gm.visibility_level,grp.default_visibility,'PRIVATE'::public.visibility_level)) effective_visibility) effective
    where e.deleted_at is null and e.start_at<p_range_end and e.end_at>p_range_start and (s.id=a or (effective.effective_visibility<>'PRIVATE' and not private.is_blocked(s.id)))
    union all
    select s.id,e.start_at,e.end_at,'BUSY_ONLY' from selected s cross join group_context grp join public.events e on e.group_id=p_group_id and e.kind='group' and e.deleted_at is null and e.moderation_hidden_at is null left join public.event_participants ep on ep.event_id=e.id and ep.user_id=s.id where e.start_at<p_range_end and e.end_at>p_range_start and coalesce(ep.status,'unanswered')<>'declined'
    union all
    select s.id,(d::date+ps.start_time)::timestamp at time zone 'Asia/Tokyo',(d::date+ps.end_time)::timestamp at time zone 'Asia/Tokyo',case when s.id=a then 'BUSY_ONLY' else effective.effective_visibility::text end from selected s cross join group_context grp join public.user_courses uc on uc.owner_user_id=s.id and uc.deleted_at is null join public.terms t on t.id=uc.term_id and t.deleted_at is null join public.profiles p on p.user_id=s.id and p.deleted_at is null left join public.group_members gm on gm.group_id=p_group_id and gm.user_id=s.id join public.period_settings ps on ps.owner_user_id=s.id and ps.term_id=uc.term_id and ps.day_of_week=uc.day_of_week and ps.period_no=uc.period_no cross join lateral (select private.restrict_group_visibility(coalesce(uc.visibility_level,p.default_visibility,'PRIVATE'::public.visibility_level),coalesce(gm.visibility_level,grp.default_visibility,'PRIVATE'::public.visibility_level)) effective_visibility) effective cross join lateral generate_series(greatest(t.start_date,(p_range_start at time zone 'Asia/Tokyo')::date),least(t.end_date,((p_range_end-interval '1 microsecond') at time zone 'Asia/Tokyo')::date),interval '1 day') d where extract(isodow from d)::int=uc.day_of_week and (s.id=a or (effective.effective_visibility<>'PRIVATE' and not private.is_blocked(s.id))) and ((d::date+ps.start_time)::timestamp at time zone 'Asia/Tokyo')<p_range_end and ((d::date+ps.end_time)::timestamp at time zone 'Asia/Tokyo')>p_range_start
    union all
    select s.id,ex.start_at,ex.end_at,case when s.id=a then 'BUSY_ONLY' else effective.effective_visibility::text end from selected s cross join group_context grp join public.exams ex on ex.owner_user_id=s.id and ex.deleted_at is null join public.profiles p on p.user_id=s.id and p.deleted_at is null left join public.group_members gm on gm.group_id=p_group_id and gm.user_id=s.id cross join lateral (select private.restrict_group_visibility(coalesce(ex.visibility_level,p.default_visibility,'PRIVATE'::public.visibility_level),coalesce(gm.visibility_level,grp.default_visibility,'PRIVATE'::public.visibility_level)) effective_visibility) effective where ex.start_at<p_range_end and ex.end_at>p_range_start and (s.id=a or (effective.effective_visibility<>'PRIVATE' and not private.is_blocked(s.id)))
  ) select coalesce(jsonb_agg(jsonb_build_object('start_at',start_at,'end_at',end_at,'visibility_level',visibility_level) order by start_at),'[]'::jsonb) into rows from busy;
  return jsonb_build_object('query_id',q,'generation',gen,'member_ids',to_jsonb(p_member_ids),'rows',rows);
end; $$;

create or replace function public.validate_group_availability(p_group_id uuid,p_member_ids uuid[],p_generation text)
returns jsonb language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); current_generation text;
begin
  if a is null or p_member_ids is null or not (a=any(p_member_ids)) then raise exception 'availability validation denied' using errcode='42501'; end if;
  if not exists(select 1 from public.groups g where g.id=p_group_id and g.deleted_at is null) or exists(select 1 from unnest(p_member_ids) x where not exists(select 1 from public.group_members m where m.group_id=p_group_id and m.user_id=x)) or exists(select 1 from unnest(p_member_ids) x where private.is_blocked(x)) then return jsonb_build_object('valid',false,'generation',null); end if;
  current_generation:=private.phase15_group_availability_generation(p_group_id,p_member_ids);
  return jsonb_build_object('valid',current_generation=p_generation,'generation',current_generation);
end; $$;

-- Include comment moderation/version in UGC cache generations.
create or replace function private.phase13_event_generation(p_event_id uuid)
returns text language sql stable security definer set search_path=pg_catalog,public,private as $$
  select md5(e.version::text||':'||g.version::text||':'||coalesce((select string_agg(m.user_id::text||':'||m.role||':'||coalesce(extract(epoch from m.joined_at)::text,''),',' order by m.user_id) from public.group_members m where m.group_id=e.group_id),'')||':'||coalesce((select string_agg(c.id::text||':'||c.version::text||':'||coalesce(extract(epoch from c.moderation_hidden_at)::text,''),',' order by c.id) from public.event_comments c where c.event_id=e.id and c.deleted_at is null),''))
  from public.events e join public.groups g on g.id=e.group_id and g.deleted_at is null
  where e.id=p_event_id and e.kind='group' and e.deleted_at is null and e.moderation_hidden_at is null;
$$;

commit;



-- Phase 15 review repairs: target context, precise state transitions, and
-- safe handling of already-deleted targets.  Append-only.
begin;

drop function if exists public.admin_get_report(uuid);
create function public.admin_get_report(p_report_id uuid)
returns table(report_id uuid,target_type text,target_id uuid,reason text,status text,created_at timestamptz,reporter_user_id uuid,reporter_display_name text,target_state text,decision_reason text,resolved_by uuid,resolved_at timestamptz,target_context jsonb)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
begin
  perform private.require_global_admin();
  return query select r.id,r.target_type,r.target_id,r.reason,r.status,r.created_at,r.reporter_user_id,coalesce(p.display_name,'利用者'),r.target_state,r.decision_reason,r.resolved_by,r.resolved_at,
    case when r.target_type='event' then (select jsonb_build_object('event_id',e.id,'group_id',e.group_id,'title',left(e.title,200),'description',left(coalesce(e.description,''),1000),'start_at',e.start_at,'end_at',e.end_at,'deleted_at',e.deleted_at,'moderation_hidden_at',e.moderation_hidden_at) from public.events e where e.id=r.target_id)
         when r.target_type='comment' then (select jsonb_build_object('comment_id',c.id,'event_id',c.event_id,'author_user_id',c.author_user_id,'body',left(c.body,2000),'deleted_at',c.deleted_at,'moderation_hidden_at',c.moderation_hidden_at) from public.event_comments c where c.id=r.target_id)
         else jsonb_build_object('target_type',r.target_type,'target_id',r.target_id) end
    from public.reports r left join public.profiles p on p.user_id=r.reporter_user_id where r.id=p_report_id;
end; $$;

drop function if exists public.admin_resolve_report(uuid,text,text,uuid);
create function public.admin_resolve_report(p_report_id uuid,p_action text,p_reason text,p_operation_id uuid)
returns table(report_id uuid,status text,action text,target_state text,audit_id uuid,previous_target_state text)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=private.require_global_admin(); h text; r jsonb; q record; e record; c record; state text; previous_state text; aid uuid;
begin
  if p_action not in('dismiss','hide') or length(trim(coalesce(p_reason,'')))<1 or length(p_reason)>1000 then raise exception 'invalid moderation decision' using errcode='22023'; end if;
  h:=encode(extensions.digest(jsonb_build_object('report_id',p_report_id,'action',p_action,'reason',trim(p_reason))::text,'sha256'),'hex');
  r:=private.admin_lock(a,p_operation_id,'admin_resolve_report',h);
  if r is not null then return query select (r->>'report_id')::uuid,r->>'status',r->>'action',r->>'target_state',(r->>'audit_id')::uuid,r->>'previous_target_state'; return; end if;
  select x.* into q from public.reports x where x.id=p_report_id for update;
  if not found then raise exception 'report unavailable' using errcode='42501'; end if;
  if q.status<>'pending' then raise exception 'report already resolved' using errcode='40001'; end if;
  if p_action='dismiss' then previous_state:='unchanged'; state:='unchanged';
  elsif q.target_type='event' then
    select x.* into e from public.events x where x.id=q.target_id and x.kind='group' for update;
    if not found then previous_state:='missing'; state:='target_missing';
    elsif e.deleted_at is not null then previous_state:='deleted'; state:='already_deleted';
    elsif e.moderation_hidden_at is not null then previous_state:='hidden'; state:='already_hidden';
    else previous_state:='visible'; state:='transitioned_hidden'; update public.events set moderation_hidden_at=now(),moderation_hidden_by=a,updated_at=now(),version=version+1 where id=q.target_id; end if;
  elsif q.target_type='comment' then
    select x.* into c from public.event_comments x where x.id=q.target_id for update;
    if not found then previous_state:='missing'; state:='target_missing';
    elsif c.deleted_at is not null then previous_state:='deleted'; state:='already_deleted';
    elsif c.moderation_hidden_at is not null then previous_state:='hidden'; state:='already_hidden';
    else previous_state:='visible'; state:='transitioned_hidden'; update public.event_comments set moderation_hidden_at=now(),moderation_hidden_by=a,updated_at=now(),version=version+1 where id=q.target_id; end if;
  else raise exception 'unsupported report target' using errcode='22023'; end if;
  update public.reports set status=case when p_action='dismiss' then 'dismissed' else 'actioned' end,resolved_by=a,resolved_at=now(),decision_reason=trim(p_reason),target_state=state where id=p_report_id;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata) values(a,'moderation_'||p_action,q.target_type,q.target_id,jsonb_build_object('report_id',q.id,'reason',trim(p_reason),'previous_status',q.status,'new_status',case when p_action='dismiss' then 'dismissed' else 'actioned' end,'previous_target_state',previous_state,'new_target_state',state)) returning id into aid;
  r:=jsonb_build_object('report_id',p_report_id,'status',case when p_action='dismiss' then 'dismissed' else 'actioned' end,'action',p_action,'target_state',state,'previous_target_state',previous_state,'audit_id',aid);
  perform private.admin_record(a,p_operation_id,'admin_resolve_report',h,r);
  return query select p_report_id,r->>'status',p_action,state,aid,previous_state;
end; $$;

revoke all on function public.admin_get_report(uuid),public.admin_resolve_report(uuid,text,text,uuid) from public,anon;
grant execute on function public.admin_get_report(uuid),public.admin_resolve_report(uuid,text,text,uuid) to authenticated;
commit;

-- Phase 15 final repairs: keep trigger row shapes and conflict targets explicit.
-- This is intentionally appended to the not-yet-applied Phase 15 migration;
-- older migrations remain immutable.
begin;

create or replace function private.record_schedule_change()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public,private,realtime as $$
declare
  bound_owner uuid;
  bound_entity_type text:=tg_argv[0];
  bound_entity_id uuid;
  bound_version bigint;
  bound_deleted_at timestamptz;
  bound_payload jsonb;
  bound_cursor bigint;
begin
  -- Only event rows have group_id.  Keep this access inside the event branch
  -- so triggers for assignments, exceptions, and other schedule entities do
  -- not evaluate a column that is absent from their NEW record.
  if bound_entity_type='event' then
    if new.group_id is not null then
      return new;
    end if;
    bound_owner:=new.owner_user_id;
    bound_entity_id:=new.id;
  elsif bound_entity_type='assignment_user_state' then
    bound_owner:=new.user_id;
    bound_entity_id:=new.assignment_id;
  elsif bound_entity_type='event_exception' then
    bound_owner:=new.owner_user_id;
    bound_entity_id:=new.id;
  else
    bound_owner:=new.owner_user_id;
    bound_entity_id:=new.id;
  end if;
  bound_version:=new.version;
  bound_deleted_at:=new.deleted_at;
  bound_payload:=case
    when bound_entity_type='event_exception' then private.schedule_event_exception_payload(bound_owner,bound_entity_id)
    else private.schedule_entity_payload(bound_owner,bound_entity_type,bound_entity_id)
  end;
  if bound_payload is null then
    raise exception 'schedule entity payload is unavailable' using errcode='42501';
  end if;
  insert into private.schedule_change_log(owner_user_id,change_cursor,entity_type,entity_id,operation,server_version,deleted_at,payload)
    values(bound_owner,private.next_schedule_cursor(bound_owner),bound_entity_type,bound_entity_id,
      case when bound_deleted_at is null then 'upsert' else 'delete' end,bound_version,bound_deleted_at,bound_payload)
    returning change_cursor into bound_cursor;
  perform realtime.send(jsonb_build_object('cursor',bound_cursor),'invalidate','schedule-sync:'||bound_owner::text,true);
  return new;
end; $$;

revoke all on function private.record_schedule_change() from public,anon,authenticated;

create or replace function public.set_group_event_rsvp(p_event_id uuid,p_status text,p_operation_id uuid)
returns table(event_id uuid,user_id uuid,status text,updated_at timestamptz)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare
  a uuid:=auth.uid();
  g uuid:=private.phase15_raw_event_group(p_event_id);
  h text;
  r jsonb;
  p record;
begin
  if g is null or p_status not in('attending','declined','tentative','unanswered') or not private.group_member(g,a) then
    raise exception 'event access denied' using errcode='42501';
  end if;
  h:=encode(extensions.digest(jsonb_build_object('event_id',p_event_id,'status',p_status)::text,'sha256'),'hex');
  r:=private.group_lock(a,p_operation_id,'set_group_event_rsvp',h);
  perform pg_advisory_xact_lock(hashtextextended('group:'||g::text,9010));
  if r is not null then
    return query select (r->>'event_id')::uuid,(r->>'user_id')::uuid,r->>'status',(r->>'updated_at')::timestamptz;
    return;
  end if;
  insert into public.event_participants(event_id,user_id,status,updated_at)
    values(p_event_id,a,p_status,now())
    on conflict on constraint event_participants_pkey
    do update set status=excluded.status,updated_at=excluded.updated_at
    returning * into p;
  perform private.group_record(a,p_operation_id,'set_group_event_rsvp',h,
    jsonb_build_object('event_id',p.event_id,'user_id',p.user_id,'status',p.status,'updated_at',p.updated_at));
  return query select p.event_id,p.user_id,p.status,p.updated_at;
end; $$;

revoke all on function public.set_group_event_rsvp(uuid,text,uuid) from public,anon;
grant execute on function public.set_group_event_rsvp(uuid,text,uuid) to authenticated;
commit;
