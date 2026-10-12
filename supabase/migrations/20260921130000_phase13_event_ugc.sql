-- Phase 13: RPC-only event comments, reactions, reports, and a consistent
-- event-content read envelope. Append-only; raw tables remain inaccessible.
begin;

alter table public.event_comments
  add column if not exists version bigint not null default 1;
create index if not exists event_comments_event_created_idx
  on public.event_comments(event_id, created_at, id) where deleted_at is null;

drop policy if exists event_comments_group_read on public.event_comments;
drop policy if exists event_comments_author_or_group_insert on public.event_comments;
drop policy if exists event_comments_author_update on public.event_comments;
drop policy if exists event_reactions_group_read on public.event_reactions;
drop policy if exists event_reactions_self_write on public.event_reactions;
drop policy if exists reports_insert_self on public.reports;
drop policy if exists reports_read_self on public.reports;
revoke all on public.event_comments, public.event_reactions, public.reports
  from public, anon, authenticated;

create or replace function private.phase13_raw_event_group(p_event_id uuid)
returns uuid language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select e.group_id from public.events e
   where e.id=p_event_id and e.kind='group';
$$;

create or replace function private.phase13_raw_comment_group(p_comment_id uuid)
returns uuid language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select private.phase13_raw_event_group(c.event_id)
    from public.event_comments c where c.id=p_comment_id;
$$;

create or replace function private.phase13_active_event_group(p_event_id uuid)
returns uuid language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select e.group_id from public.events e
    join public.groups g on g.id=e.group_id and g.deleted_at is null
   where e.id=p_event_id and e.kind='group' and e.deleted_at is null;
$$;

create or replace function private.phase13_event_generation(p_event_id uuid)
returns text language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select md5(e.version::text||':'||g.version::text||':'||coalesce(
    (select string_agg(m.user_id::text||':'||m.role||':'||coalesce(extract(epoch from m.joined_at)::text,''),',' order by m.user_id)
       from public.group_members m where m.group_id=e.group_id),''))
    from public.events e join public.groups g on g.id=e.group_id and g.deleted_at is null
   where e.id=p_event_id and e.kind='group' and e.deleted_at is null;
$$;

create or replace function public.get_group_event_ugc(p_event_id uuid)
returns table(event_id uuid,group_id uuid,generation text,rsvps jsonb,comments jsonb,reactions jsonb)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
declare g uuid; gen text;
begin
  select e.group_id into g from public.events e
    join public.groups x on x.id=e.group_id and x.deleted_at is null
   where e.id=p_event_id and e.kind='group' and e.deleted_at is null;
  if g is null or not private.group_member(g,auth.uid()) then raise exception 'event access denied' using errcode='42501'; end if;
  gen:=private.phase13_event_generation(p_event_id);
  return query select p.id,p.group_id,gen,
    coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'status',coalesce(r.status,'unanswered'),'updated_at',r.updated_at) order by m.user_id) from public.group_members m left join public.event_participants r on r.event_id=p_event_id and r.user_id=m.user_id where m.group_id=g),'[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object('comment_id',c.id,'event_id',c.event_id,'author_user_id',c.author_user_id,'body',c.body,'created_at',c.created_at,'updated_at',c.updated_at,'version',c.version) order by c.created_at,c.id) from public.event_comments c where c.event_id=p_event_id and c.deleted_at is null),'[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object('reaction',z.reaction,'reaction_count',z.reaction_count,'reacted_by_me',z.reacted_by_me) order by z.reaction) from (select r.reaction,count(*)::bigint reaction_count,bool_or(r.user_id=auth.uid()) reacted_by_me from public.event_reactions r where r.event_id=p_event_id group by r.reaction) z),'[]'::jsonb)
    from public.events p where p.id=p_event_id;
end; $$;

create or replace function public.validate_group_event_ugc(p_event_id uuid,p_generation text)
returns table(valid boolean,generation text)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
declare g uuid; current_generation text;
begin
  g:=private.phase13_active_event_group(p_event_id);
  if g is null or not private.group_member(g,auth.uid()) then
    raise exception 'event access denied' using errcode='42501';
  end if;
  current_generation:=private.phase13_event_generation(p_event_id);
  return query select current_generation=p_generation,current_generation;
end; $$;

create or replace function public.list_group_event_comments(p_event_id uuid)
returns table(comment_id uuid,event_id uuid,author_user_id uuid,body text,created_at timestamptz,updated_at timestamptz,version bigint)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
declare g uuid;
begin
  g:=private.phase13_active_event_group(p_event_id); if g is null or not private.group_member(g,auth.uid()) then raise exception 'event access denied' using errcode='42501'; end if;
  return query select c.id,c.event_id,c.author_user_id,c.body,c.created_at,c.updated_at,c.version from public.event_comments c where c.event_id=p_event_id and c.deleted_at is null order by c.created_at,c.id;
end; $$;

create or replace function public.create_group_event_comment(p_event_id uuid,p_body text,p_operation_id uuid)
returns table(comment_id uuid,event_id uuid,author_user_id uuid,body text,created_at timestamptz,updated_at timestamptz,version bigint)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); g uuid; h text; r jsonb; c record;
begin
  if a is null then raise exception 'not authenticated' using errcode='42501'; end if;
  if length(trim(coalesce(p_body,'')))<1 or length(p_body)>2000 then raise exception 'invalid comment' using errcode='22023'; end if;
  g:=private.phase13_raw_event_group(p_event_id); if g is null then raise exception 'event unavailable' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('event_id',p_event_id,'body',trim(p_body))::text,'sha256'),'hex');
  r:=private.group_lock(a,p_operation_id,'create_group_event_comment',h);
  perform pg_advisory_xact_lock(hashtextextended('group:'||g::text,9010));
  if not exists(select 1 from public.events e join public.groups x on x.id=e.group_id and x.deleted_at is null join public.group_members m on m.group_id=e.group_id and m.user_id=a where e.id=p_event_id and e.kind='group' and e.deleted_at is null) then raise exception 'event access denied' using errcode='42501'; end if;
  if r is not null then
    select x.* into c from public.event_comments x where x.id=(r->>'comment_id')::uuid and x.event_id=p_event_id and x.deleted_at is null for update;
    if not found or c.author_user_id<>a then raise exception 'comment replay is no longer active' using errcode='42501'; end if;
    return query select c.id,c.event_id,c.author_user_id,c.body,c.created_at,c.updated_at,c.version; return;
  end if;
  insert into public.event_comments(event_id,author_user_id,body) values(p_event_id,a,trim(p_body)) returning * into c;
  r:=jsonb_build_object('comment_id',c.id,'event_id',c.event_id,'author_user_id',c.author_user_id,'body',c.body,'created_at',c.created_at,'updated_at',c.updated_at,'version',c.version);
  perform private.group_record(a,p_operation_id,'create_group_event_comment',h,r);
  return query select c.id,c.event_id,c.author_user_id,c.body,c.created_at,c.updated_at,c.version;
end; $$;

create or replace function public.update_group_event_comment(p_comment_id uuid,p_body text,p_expected_version bigint,p_operation_id uuid)
returns table(comment_id uuid,event_id uuid,author_user_id uuid,body text,created_at timestamptz,updated_at timestamptz,version bigint)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); g uuid; h text; r jsonb; c record;
begin
  if a is null then raise exception 'not authenticated' using errcode='42501'; end if;
  if p_expected_version is null or length(trim(coalesce(p_body,'')))<1 or length(p_body)>2000 then raise exception 'invalid comment' using errcode='22023'; end if;
  g:=private.phase13_raw_comment_group(p_comment_id); if g is null then raise exception 'comment unavailable' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('comment_id',p_comment_id,'body',trim(p_body),'expected_version',p_expected_version)::text,'sha256'),'hex');
  r:=private.group_lock(a,p_operation_id,'update_group_event_comment',h);
  perform pg_advisory_xact_lock(hashtextextended('group:'||g::text,9010));
  select x.* into c from public.event_comments x join public.events e on e.id=x.event_id and e.kind='group' and e.deleted_at is null join public.groups q on q.id=e.group_id and q.deleted_at is null where x.id=p_comment_id and x.deleted_at is null for update;
  if not found or not private.group_member(g,a) or c.author_user_id<>a then raise exception 'comment edit denied' using errcode='42501'; end if;
  if r is not null then if c.version<>(r->>'version')::bigint then raise exception 'comment replay is stale' using errcode='40001'; end if; return query select c.id,c.event_id,c.author_user_id,c.body,c.created_at,c.updated_at,c.version; return; end if;
  if c.version<>p_expected_version then raise exception 'comment version conflict' using errcode='40001'; end if;
  update public.event_comments x set body=trim(p_body),version=x.version+1,updated_at=now() where x.id=p_comment_id returning * into c;
  r:=jsonb_build_object('comment_id',c.id,'event_id',c.event_id,'author_user_id',c.author_user_id,'body',c.body,'created_at',c.created_at,'updated_at',c.updated_at,'version',c.version);
  perform private.group_record(a,p_operation_id,'update_group_event_comment',h,r);
  return query select c.id,c.event_id,c.author_user_id,c.body,c.created_at,c.updated_at,c.version;
end; $$;

create or replace function public.delete_group_event_comment(p_comment_id uuid,p_expected_version bigint,p_operation_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); g uuid; h text; r jsonb; c record;
begin
  if p_expected_version is null then raise exception 'invalid comment version' using errcode='22023'; end if;
  g:=private.phase13_raw_comment_group(p_comment_id); if g is null then raise exception 'comment unavailable' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('comment_id',p_comment_id,'expected_version',p_expected_version)::text,'sha256'),'hex');
  r:=private.group_lock(a,p_operation_id,'delete_group_event_comment',h);
  perform pg_advisory_xact_lock(hashtextextended('group:'||g::text,9010));
  select x.* into c from public.event_comments x join public.events e on e.id=x.event_id and e.kind='group' and e.deleted_at is null join public.groups q on q.id=e.group_id and q.deleted_at is null where x.id=p_comment_id and x.deleted_at is null for update;
  if not found or not private.group_member(g,a) or c.author_user_id<>a then raise exception 'comment delete denied' using errcode='42501'; end if;
  if r is not null then return; end if;
  if c.version<>p_expected_version then raise exception 'comment version conflict' using errcode='40001'; end if;
  update public.event_comments set deleted_at=now(),updated_at=now(),version=version+1 where id=p_comment_id;
  perform private.group_record(a,p_operation_id,'delete_group_event_comment',h,'{}');
end; $$;

create or replace function public.moderate_delete_group_event_comment(p_comment_id uuid,p_operation_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); g uuid; h text; r jsonb; c record;
begin
  g:=private.phase13_raw_comment_group(p_comment_id); if g is null then raise exception 'comment unavailable' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('comment_id',p_comment_id)::text,'sha256'),'hex');
  r:=private.group_lock(a,p_operation_id,'moderate_delete_group_event_comment',h);
  perform pg_advisory_xact_lock(hashtextextended('group:'||g::text,9010));
  select x.* into c from public.event_comments x join public.events e on e.id=x.event_id and e.kind='group' and e.deleted_at is null join public.groups q on q.id=e.group_id and q.deleted_at is null where x.id=p_comment_id and x.deleted_at is null for update;
  if not found or not private.group_member(g,a) or not private.group_admin(g,a) then raise exception 'moderation denied' using errcode='42501'; end if;
  if r is not null then return; end if;
  update public.event_comments set deleted_at=now(),updated_at=now(),version=version+1 where id=p_comment_id;
  perform private.group_record(a,p_operation_id,'moderate_delete_group_event_comment',h,'{}');
end; $$;

create or replace function public.list_group_event_reactions(p_event_id uuid)
returns table(reaction text,reaction_count bigint,reacted_by_me boolean)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
declare g uuid;
begin
  g:=private.phase13_active_event_group(p_event_id); if g is null or not private.group_member(g,auth.uid()) then raise exception 'event access denied' using errcode='42501'; end if;
  return query select r.reaction,count(*)::bigint,bool_or(r.user_id=auth.uid()) from public.event_reactions r where r.event_id=p_event_id group by r.reaction order by r.reaction;
end; $$;

create or replace function public.set_group_event_reaction(p_event_id uuid,p_reaction text,p_operation_id uuid)
returns table(event_id uuid,reaction text,reacted boolean)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); g uuid; h text; r jsonb;
begin
  if p_reaction not in('ok','thanks','question','maybe','cannot') then raise exception 'invalid reaction' using errcode='22023'; end if;
  g:=private.phase13_raw_event_group(p_event_id); if g is null then raise exception 'event unavailable' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('event_id',p_event_id,'reaction',p_reaction)::text,'sha256'),'hex');
  r:=private.group_lock(a,p_operation_id,'set_group_event_reaction',h);
  perform pg_advisory_xact_lock(hashtextextended('group:'||g::text,9010));
  if not exists(select 1 from public.events e join public.groups q on q.id=e.group_id and q.deleted_at is null join public.group_members m on m.group_id=e.group_id and m.user_id=a where e.id=p_event_id and e.kind='group' and e.deleted_at is null) then raise exception 'event access denied' using errcode='42501'; end if;
  if r is not null then return query select (r->>'event_id')::uuid,r->>'reaction',true; return; end if;
  insert into public.event_reactions(event_id,user_id,reaction) values(p_event_id,a,p_reaction) on conflict on constraint event_reactions_pkey do nothing;
  perform private.group_record(a,p_operation_id,'set_group_event_reaction',h,jsonb_build_object('event_id',p_event_id,'reaction',p_reaction,'reacted',true));
  return query select p_event_id,p_reaction,true;
end; $$;

create or replace function public.remove_group_event_reaction(p_event_id uuid,p_reaction text,p_operation_id uuid)
returns table(event_id uuid,reaction text,reacted boolean)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); g uuid; h text; r jsonb;
begin
  if p_reaction not in('ok','thanks','question','maybe','cannot') then raise exception 'invalid reaction' using errcode='22023'; end if;
  g:=private.phase13_raw_event_group(p_event_id); if g is null then raise exception 'event unavailable' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('event_id',p_event_id,'reaction',p_reaction)::text,'sha256'),'hex');
  r:=private.group_lock(a,p_operation_id,'remove_group_event_reaction',h);
  perform pg_advisory_xact_lock(hashtextextended('group:'||g::text,9010));
  if not exists(select 1 from public.events e join public.groups q on q.id=e.group_id and q.deleted_at is null join public.group_members m on m.group_id=e.group_id and m.user_id=a where e.id=p_event_id and e.kind='group' and e.deleted_at is null) then raise exception 'event access denied' using errcode='42501'; end if;
  if r is not null then return query select (r->>'event_id')::uuid,r->>'reaction',false; return; end if;
  delete from public.event_reactions er where er.event_id=p_event_id and er.user_id=a and er.reaction=p_reaction;
  perform private.group_record(a,p_operation_id,'remove_group_event_reaction',h,jsonb_build_object('event_id',p_event_id,'reaction',p_reaction,'reacted',false));
  return query select p_event_id,p_reaction,false;
end; $$;

create or replace function public.create_group_content_report(p_target_type text,p_target_id uuid,p_reason text,p_operation_id uuid)
returns table(report_id uuid,target_type text,target_id uuid,status text)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare a uuid:=auth.uid(); g uuid; eid uuid; h text; r jsonb; i uuid;
begin
  if p_target_type not in('event','comment') or length(trim(coalesce(p_reason,'')))<1 or length(p_reason)>500 then raise exception 'invalid report' using errcode='22023'; end if;
  if p_target_type='event' then select e.id,e.group_id into eid,g from public.events e where e.id=p_target_id and e.kind='group'; else select c.event_id,e.group_id into eid,g from public.event_comments c join public.events e on e.id=c.event_id and e.kind='group' where c.id=p_target_id; end if;
  if g is null then raise exception 'report target unavailable' using errcode='42501'; end if;
  h:=encode(extensions.digest(jsonb_build_object('target_type',p_target_type,'target_id',p_target_id,'reason',trim(p_reason))::text,'sha256'),'hex');
  r:=private.group_lock(a,p_operation_id,'create_group_content_report',h);
  perform pg_advisory_xact_lock(hashtextextended('group:'||g::text,9010));
  if not exists(select 1 from public.events e join public.groups q on q.id=e.group_id and q.deleted_at is null join public.group_members m on m.group_id=e.group_id and m.user_id=a where e.id=eid and e.kind='group' and e.deleted_at is null) then raise exception 'report target unavailable' using errcode='42501'; end if;
  if p_target_type='comment' and not exists(select 1 from public.event_comments c where c.id=p_target_id and c.event_id=eid and c.deleted_at is null) then raise exception 'report target unavailable' using errcode='42501'; end if;
  if r is not null then return query select (r->>'report_id')::uuid,r->>'target_type',(r->>'target_id')::uuid,r->>'status'; return; end if;
  insert into public.reports(reporter_user_id,target_type,target_id,reason,status) values(a,p_target_type,p_target_id,trim(p_reason),'pending') returning id into i;
  r:=jsonb_build_object('report_id',i,'target_type',p_target_type,'target_id',p_target_id,'status','pending');
  perform private.group_record(a,p_operation_id,'create_group_content_report',h,r);
  return query select i,p_target_type,p_target_id,'pending';
end; $$;

revoke all on function private.phase13_raw_event_group(uuid),private.phase13_raw_comment_group(uuid),private.phase13_active_event_group(uuid),private.phase13_event_generation(uuid) from public,anon,authenticated;
revoke all on function public.get_group_event_ugc(uuid),public.validate_group_event_ugc(uuid,text),public.list_group_event_comments(uuid),public.create_group_event_comment(uuid,text,uuid),public.update_group_event_comment(uuid,text,bigint,uuid),public.delete_group_event_comment(uuid,bigint,uuid),public.moderate_delete_group_event_comment(uuid,uuid),public.list_group_event_reactions(uuid),public.set_group_event_reaction(uuid,text,uuid),public.remove_group_event_reaction(uuid,text,uuid),public.create_group_content_report(text,uuid,text,uuid) from public,anon;
grant execute on function public.get_group_event_ugc(uuid),public.validate_group_event_ugc(uuid,text),public.list_group_event_comments(uuid),public.create_group_event_comment(uuid,text,uuid),public.update_group_event_comment(uuid,text,bigint,uuid),public.delete_group_event_comment(uuid,bigint,uuid),public.moderate_delete_group_event_comment(uuid,uuid),public.list_group_event_reactions(uuid),public.set_group_event_reaction(uuid,text,uuid),public.remove_group_event_reaction(uuid,text,uuid),public.create_group_content_report(text,uuid,text,uuid) to authenticated;
commit;
