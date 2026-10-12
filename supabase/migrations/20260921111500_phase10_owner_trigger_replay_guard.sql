-- Follow-up for the deferred owner invariant and stale create replay found by
-- Android commit-time acceptance. Earlier migrations remain immutable.
begin;

create or replace function private.group_owner_invariant()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public,private
as $$
declare bound_group_id uuid;
begin
  bound_group_id:=case when tg_op='DELETE' then old.group_id else new.group_id end;
  if exists(select 1 from public.groups where id=bound_group_id and deleted_at is null)
     and (select count(*) from public.group_members where group_id=bound_group_id and role='owner')<>1 then
    raise exception 'group must have exactly one owner' using errcode='23514';
  end if;
  if exists(select 1 from public.groups where id=bound_group_id and deleted_at is null)
     and not exists(
       select 1 from public.group_members m join public.groups g on g.id=m.group_id
       where m.group_id=bound_group_id and m.user_id=g.owner_user_id and m.role='owner'
     ) then
    raise exception 'group owner membership mismatch' using errcode='23514';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end; $$;

create or replace function public.create_group(
  p_name text,p_type text default 'other',p_description text default null,
  p_event_create_policy text default 'member',p_operation_id uuid default null)
returns table(group_id uuid,name text,owner_user_id uuid,type text,description text,
  event_create_policy text,role text)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare actor uuid:=auth.uid(); created_id uuid; request_hash text; receipt jsonb;
begin
  if actor is null then raise exception 'not authenticated' using errcode='42501'; end if;
  if length(trim(coalesce(p_name,'')))<1 or length(p_name)>120
     or length(coalesce(p_description,''))>500
     or p_type not in('friends','course','club','seminar','lab','part_time_job','other')
     or p_event_create_policy not in('member','admin','owner') then
    raise exception 'invalid group' using errcode='22023';
  end if;
  request_hash:=encode(extensions.digest(jsonb_build_object(
    'name',trim(p_name),'type',p_type,'description',coalesce(trim(p_description),''),
    'event_create_policy',p_event_create_policy)::text,'sha256'),'hex');
  receipt:=private.group_lock(actor,p_operation_id,'create_group',request_hash);
  if receipt is not null then
    if not exists(
      select 1 from public.groups g join public.group_members m on m.group_id=g.id
      where g.id=(receipt->>'group_id')::uuid and g.deleted_at is null
        and g.owner_user_id=actor and m.user_id=actor and m.role='owner'
    ) then raise exception 'group replay is no longer active' using errcode='42501'; end if;
    return query select (receipt->>'group_id')::uuid,receipt->>'name',
      (receipt->>'owner_user_id')::uuid,receipt->>'type',receipt->>'description',
      receipt->>'event_create_policy',receipt->>'role';
    return;
  end if;
  insert into public.groups(owner_user_id,name,type,description,event_create_policy)
    values(actor,trim(p_name),p_type,nullif(trim(p_description),''),p_event_create_policy)
    returning id into created_id;
  insert into public.group_members(group_id,user_id,role) values(created_id,actor,'owner');
  receipt:=jsonb_build_object('group_id',created_id,'name',trim(p_name),
    'owner_user_id',actor,'type',p_type,'description',nullif(trim(p_description),''),
    'event_create_policy',p_event_create_policy,'role','owner');
  perform private.group_record(actor,p_operation_id,'create_group',request_hash,receipt);
  return query select created_id,trim(p_name),actor,p_type,nullif(trim(p_description),''),
    p_event_create_policy,'owner';
end; $$;

revoke all on function private.group_owner_invariant() from public,anon,authenticated;
revoke all on function public.create_group(text,text,text,text,uuid) from public,anon;
grant execute on function public.create_group(text,text,text,text,uuid) to authenticated;

commit;
