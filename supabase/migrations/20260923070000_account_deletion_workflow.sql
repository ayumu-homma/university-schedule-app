-- SAFETY-01 slice B: resumable account/data deletion. The Auth identity is
-- deleted only by the Edge worker after relational and Storage cleanup pass.
begin;

alter table private.user_safety_state
  drop constraint if exists user_safety_state_status_check;
alter table private.user_safety_state
  add constraint user_safety_state_status_check
  check(status in ('active','suspended','deletion_pending','deleted'));

-- Shared comments and templates retain a neutral/anonymized record while the
-- Auth identity is removed. Do not cascade shared content with the author.
alter table public.event_comments alter column author_user_id drop not null;
alter table public.event_comments drop constraint if exists event_comments_author_user_id_fkey;
alter table public.event_comments add constraint event_comments_author_user_id_fkey
  foreign key(author_user_id) references auth.users(id) on delete set null;
alter table public.course_templates drop constraint if exists course_templates_created_by_fkey;
alter table public.course_templates add constraint course_templates_created_by_fkey
  foreign key(created_by) references auth.users(id) on delete set null;
alter table public.course_templates drop constraint if exists course_templates_merged_by_fkey;
alter table public.course_templates add constraint course_templates_merged_by_fkey
  foreign key(merged_by) references auth.users(id) on delete set null;
alter table public.course_templates drop constraint if exists course_templates_moderation_hidden_by_fkey;
alter table public.course_templates add constraint course_templates_moderation_hidden_by_fkey
  foreign key(moderation_hidden_by) references auth.users(id) on delete set null;

create table if not exists private.account_deletion_operations (
  operation_id uuid primary key,
  user_id uuid not null,
  phase text not null default 'requested'
    check(phase in ('requested','object_cleanup','auth_delete','complete')),
  group_actions jsonb not null default '[]'::jsonb
    check(jsonb_typeof(group_actions)='array'),
  object_manifest jsonb not null default '[]'::jsonb
    check(jsonb_typeof(object_manifest)='array'),
  last_error_code text,
  attempts integer not null default 0 check(attempts>=0),
  requested_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz
);
create index if not exists account_deletion_operations_user_idx
  on private.account_deletion_operations(user_id,requested_at desc);
revoke all on private.account_deletion_operations from public,anon,authenticated,service_role;
grant select,insert,update,delete on private.account_deletion_operations to postgres,supabase_admin;

create or replace function public.get_my_account_deletion_preflight()
returns jsonb language plpgsql stable security definer
set search_path=pg_catalog,public,private,auth as $$
declare actor uuid:=auth.uid(); result jsonb;
begin
  if actor is null or not exists(select 1 from auth.users u where u.id=actor) then
    raise exception 'account unavailable' using errcode='42501';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'group_id',g.id,'name',g.name,'member_count',m.member_count,
      'suspended',g.suspended_at is not null,
      'successors',coalesce((select jsonb_agg(jsonb_build_object(
          'user_id',gm.user_id,'display_name',coalesce(p.display_name,'利用者'))
        order by gm.joined_at,gm.user_id)
        from public.group_members gm left join public.profiles p on p.user_id=gm.user_id
        where gm.group_id=g.id and gm.user_id<>actor and private.safety_actor_active(gm.user_id)),
        '[]'::jsonb)
    ) order by g.created_at,g.id),'[]'::jsonb)
    into result
    from public.groups g
    cross join lateral (select count(*)::integer member_count from public.group_members gm
      where gm.group_id=g.id) m
    where g.owner_user_id=actor and g.deleted_at is null;
  return jsonb_build_object('groups',result);
end;
$$;
revoke all on function public.get_my_account_deletion_preflight() from public,anon,service_role;
grant execute on function public.get_my_account_deletion_preflight() to authenticated;

create or replace function public.request_account_deletion(
  p_operation_id uuid,p_group_actions jsonb
) returns table(operation_id uuid,phase text,requested_at timestamptz)
language plpgsql volatile security definer
set search_path=pg_catalog,public,private,auth as $$
declare actor uuid:=auth.uid(); current_state text; existing private.account_deletion_operations%rowtype;
  g record; action_row jsonb; action_name text; successor uuid; action_count integer; admin_count integer;
begin
  if actor is null or p_operation_id is null or jsonb_typeof(p_group_actions)<>'array'
     or jsonb_array_length(p_group_actions)>100 then
    raise exception 'invalid account deletion request' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('safety-user:'||actor::text,9010));
  select coalesce(s.status,'active') into current_state
    from auth.users u left join private.user_safety_state s on s.user_id=u.id
    where u.id=actor for update of u;
  if not found then raise exception 'account unavailable' using errcode='42501'; end if;

  select * into existing from private.account_deletion_operations o
    where o.operation_id=p_operation_id for update;
  if found then
    if existing.user_id<>actor or existing.group_actions<>p_group_actions then
      raise exception 'account deletion operation mismatch' using errcode='PT409';
    end if;
    return query select existing.operation_id,existing.phase,existing.requested_at;
    return;
  end if;
  if current_state='deletion_pending' then
    raise exception 'account deletion already pending' using errcode='PT409';
  elsif current_state not in ('active','suspended') then
    raise exception 'account unavailable' using errcode='42501';
  end if;
  if exists(select 1 from private.global_admins ga where ga.user_id=actor and ga.revoked_at is null) then
    perform pg_advisory_xact_lock(hashtextextended('safety-admin-set',9010));
    select count(*) into admin_count from private.global_admins ga
      where ga.revoked_at is null and private.safety_actor_active(ga.user_id);
    if admin_count<=1 then
      raise exception 'cannot delete the last active global admin' using errcode='42501';
    end if;
  end if;

  select count(*) into action_count from jsonb_array_elements(p_group_actions) a;
  for g in select x.id,x.name,count(gm.user_id)::integer member_count
    from public.groups x left join public.group_members gm on gm.group_id=x.id
    where x.owner_user_id=actor and x.deleted_at is null group by x.id,x.name loop
    select a into action_row from jsonb_array_elements(p_group_actions) a
      where a->>'group_id'=g.id::text;
    if action_row is null or (select count(*) from jsonb_array_elements(p_group_actions) a
        where a->>'group_id'=g.id::text)<>1 then
      raise exception 'every owned group needs one explicit action' using errcode='22023';
    end if;
    action_name:=action_row->>'action';
    successor:=nullif(action_row->>'successor_id','')::uuid;
    if g.member_count<=1 then
      if action_name<>'delete' or successor is not null then
        raise exception 'sole-member group must be confirmed for deletion' using errcode='22023';
      end if;
    elsif action_name='transfer' then
      if successor is null or successor=actor or not exists(
        select 1 from public.group_members gm where gm.group_id=g.id and gm.user_id=successor)
        or not private.safety_actor_active(successor) then
        raise exception 'group transfer target must be an active current member' using errcode='22023';
      end if;
    elsif action_name='disband' then
      if successor is not null then raise exception 'disband cannot have a successor' using errcode='22023'; end if;
    else
      raise exception 'shared group needs an explicit transfer or disband' using errcode='22023';
    end if;
  end loop;
  if action_count<>(select count(*) from public.groups x
      where x.owner_user_id=actor and x.deleted_at is null) then
    raise exception 'group action list does not match current ownership' using errcode='22023';
  end if;
  if exists(select 1 from jsonb_array_elements(p_group_actions) a
      where coalesce(a->>'group_id','') !~* '^[0-9a-f-]{36}$'
         or not exists(select 1 from public.groups x where x.id=(a->>'group_id')::uuid
           and x.owner_user_id=actor and x.deleted_at is null)) then
    raise exception 'group action references an unowned group' using errcode='22023';
  end if;

  insert into private.account_deletion_operations(operation_id,user_id,group_actions)
    values(p_operation_id,actor,p_group_actions);
  insert into private.user_safety_state(user_id,status,version,reason,changed_by,changed_at)
    values(actor,'deletion_pending',1,'self-service account deletion',actor,clock_timestamp())
    on conflict(user_id) do update set status='deletion_pending',
      version=private.user_safety_state.version+1,reason='self-service account deletion',
      changed_by=actor,changed_at=clock_timestamp();
  update private.notification_installation_bindings set enabled=false,updated_at=clock_timestamp()
    where user_id=actor and enabled;
  update public.device_tokens set revoked_at=clock_timestamp() where user_id=actor and revoked_at is null;
  update public.group_targeted_invitations gti set status='revoked',responded_at=clock_timestamp()
    where gti.status='pending' and (gti.invitee_user_id=actor or gti.inviter_user_id=actor);
  update public.group_invitations gi set revoked_at=clock_timestamp()
    where gi.created_by=actor and gi.revoked_at is null;
  update public.friend_invites fi set revoked_at=clock_timestamp()
    where fi.issuer_user_id=actor and fi.revoked_at is null;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata)
    values(actor,'account_deletion_requested','user',actor,
      jsonb_build_object('operation_id',p_operation_id));
  return query select p_operation_id,'requested'::text,clock_timestamp();
end;
$$;
revoke all on function public.request_account_deletion(uuid,jsonb) from public,anon,service_role;
grant execute on function public.request_account_deletion(uuid,jsonb) to authenticated;

create or replace function public.get_my_account_deletion_status()
returns table(operation_id uuid,phase text,last_error_code text,attempts integer,
  requested_at timestamptz,updated_at timestamptz,completed_at timestamptz)
language sql stable security definer set search_path=pg_catalog,public,private,auth as $$
  select o.operation_id,o.phase,o.last_error_code,o.attempts,o.requested_at,o.updated_at,o.completed_at
  from private.account_deletion_operations o where o.user_id=auth.uid()
  order by o.requested_at desc limit 1;
$$;
revoke all on function public.get_my_account_deletion_status() from public,anon,service_role;
grant execute on function public.get_my_account_deletion_status() to authenticated;

-- This service-only worker step is transactionally idempotent. It returns a
-- private Storage manifest, cleans relational rows, then advances the durable
-- operation. The Edge worker must delete every object through Storage API
-- before calling mark_account_deletion_objects_removed and Auth Admin delete.
create or replace function public.prepare_account_deletion_database(p_operation_id uuid)
returns jsonb language plpgsql volatile security definer
set search_path=pg_catalog,public,private,auth,storage as $$
declare o private.account_deletion_operations%rowtype; action_row jsonb; v_group_id uuid;
  successor uuid; actor uuid; manifest jsonb; fk record;
begin
  select * into o from private.account_deletion_operations where operation_id=p_operation_id for update;
  if not found then raise exception 'deletion operation unavailable' using errcode='42501'; end if;
  if o.phase in ('object_cleanup','auth_delete','complete') then
    return jsonb_build_object('operation_id',o.operation_id,'phase',o.phase,
      'user_id',o.user_id,'objects',o.object_manifest);
  end if;
  actor:=o.user_id;
  perform pg_advisory_xact_lock(hashtextextended('safety-user:'||actor::text,9010));
  if not exists(select 1 from private.user_safety_state s where s.user_id=actor
      and s.status='deletion_pending') then
    raise exception 'account is not pending deletion' using errcode='42501';
  end if;

  select coalesce(jsonb_agg(x.item order by x.bucket_id,x.name),'[]'::jsonb) into manifest
  from (
    select distinct so.bucket_id,so.name,
      jsonb_build_object('bucket_id',so.bucket_id,'name',so.name) item
    from storage.objects so
    where so.owner_id=actor::text
       or (so.bucket_id='schedule-documents' and so.name like actor::text||'/%')
    union
    select 'schedule-documents',ds.storage_path,
      jsonb_build_object('bucket_id','schedule-documents','name',ds.storage_path)
    from public.document_sources ds where ds.owner_user_id=actor
  ) x;

  -- Explicitly transfer or disband owned groups as the user confirmed.
  for action_row in select value from jsonb_array_elements(o.group_actions) loop
    v_group_id:=(action_row->>'group_id')::uuid;
    successor:=nullif(action_row->>'successor_id','')::uuid;
    perform pg_advisory_xact_lock(hashtextextended('group:'||v_group_id::text,9010));
    perform pg_advisory_xact_lock(hashtextextended('safety-group:'||v_group_id::text,9010));
    if action_row->>'action'='transfer' then
      if not exists(select 1 from public.groups g join public.group_members gm
          on gm.group_id=g.id and gm.user_id=successor
        where g.id=v_group_id and g.owner_user_id=actor and private.safety_actor_active(successor)) then
        raise exception 'group transfer target changed; retry required' using errcode='40001';
      end if;
      update public.groups set owner_user_id=successor,updated_at=clock_timestamp() where id=v_group_id;
      delete from public.group_members gm where gm.group_id=v_group_id and gm.user_id=actor;
      update public.group_members gm set role='owner' where gm.group_id=v_group_id and gm.user_id=successor;
      update public.events e set owner_user_id=successor where e.group_id=v_group_id and e.owner_user_id=actor;
      update public.calendars c set owner_user_id=successor where c.group_id=v_group_id and c.owner_user_id=actor;
      insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata)
        values(actor,'account_deletion_group_transfer','group',v_group_id,
          jsonb_build_object('operation_id',p_operation_id,'successor_user_id',successor));
    else
      delete from public.group_invitations gi where gi.group_id=v_group_id;
      delete from public.group_targeted_invitations gti where gti.group_id=v_group_id;
      delete from public.event_reactions r using public.events e
        where r.event_id=e.id and e.group_id=v_group_id;
      delete from public.event_participants ep using public.events e
        where ep.event_id=e.id and e.group_id=v_group_id;
      delete from public.event_comments c using public.events e
        where c.event_id=e.id and e.group_id=v_group_id;
      delete from public.events e where e.group_id=v_group_id;
      delete from public.calendars c where c.group_id=v_group_id;
      delete from public.group_members gm where gm.group_id=v_group_id;
      delete from public.groups g where g.id=v_group_id and g.owner_user_id=actor;
      insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata)
        values(actor,'account_deletion_group_disband','group',v_group_id,
          jsonb_build_object('operation_id',p_operation_id,'confirmed_by_owner',true));
    end if;
  end loop;

  -- Preserve other members' events/calendars in non-owned groups by handing
  -- their ownership to the current group owner; delete personal schedule data.
  update public.events e set owner_user_id=g.owner_user_id
    from public.groups g where e.owner_user_id=actor and e.group_id=g.id;
  delete from public.event_reactions r using public.events e
    where r.event_id=e.id and e.owner_user_id=actor and e.group_id is null;
  delete from public.event_participants ep using public.events e
    where ep.event_id=e.id and e.owner_user_id=actor and e.group_id is null;
  delete from public.event_comments c using public.events e
    where c.event_id=e.id and e.owner_user_id=actor and e.group_id is null;
  delete from public.events where owner_user_id=actor and group_id is null;
  update public.event_comments set body='[削除済みユーザー]',author_user_id=null
    where author_user_id=actor;
  update public.calendars c set owner_user_id=g.owner_user_id
    from public.groups g where c.owner_user_id=actor and c.group_id=g.id;
  delete from public.calendars where owner_user_id=actor and group_id is null;
  delete from public.assignments where owner_user_id=actor;
  delete from public.user_courses where owner_user_id=actor;
  delete from public.period_settings where owner_user_id=actor;
  delete from public.exams where owner_user_id=actor;
  delete from public.terms where owner_user_id=actor;
  delete from public.friendships where requester_user_id=actor or addressee_user_id=actor;
  delete from public.blocks where blocker_user_id=actor or blocked_user_id=actor;
  delete from public.reports where reporter_user_id=actor;
  delete from public.course_template_reports where reported_by=actor;
  delete from public.university_requests where requested_by=actor;
  delete from public.group_invitations where created_by=actor;
  delete from public.course_template_copy_events where copied_by=actor;
  delete from public.event_comments where author_user_id=actor;

  -- Null surviving attribution where nullable; delete only rows whose schema
  -- requires an Auth identity. This catalog-derived pass covers later user FKs.
  for fk in
    select n.nspname,c.relname,a.attname,a.attnotnull
    from pg_constraint f join pg_class c on c.oid=f.conrelid
      join pg_namespace n on n.oid=c.relnamespace
      join unnest(f.conkey) with ordinality k(attnum,ord) on true
      join pg_attribute a on a.attrelid=c.oid and a.attnum=k.attnum
    where f.contype='f' and f.confrelid='auth.users'::regclass
      and not (n.nspname='private' and c.relname in
        ('account_deletion_operations','user_safety_state','user_safety_notices'))
    order by n.nspname,c.relname,a.attname
  loop
    if fk.attnotnull then
      execute format('delete from %I.%I where %I=$1',fk.nspname,fk.relname,fk.attname) using actor;
    else
      execute format('update %I.%I set %I=null where %I=$1',fk.nspname,fk.relname,fk.attname,fk.attname) using actor;
    end if;
  end loop;
  delete from private.user_safety_notices where recipient_user_id=actor or created_by=actor;
  update private.user_safety_state set changed_by=null where changed_by=actor;
  update public.groups set suspended_by=null where suspended_by=actor;
  update private.account_deletion_operations set phase='object_cleanup',object_manifest=manifest,
    attempts=attempts+1,last_error_code=null,updated_at=clock_timestamp()
    where operation_id=p_operation_id;
  return jsonb_build_object('operation_id',p_operation_id,'phase','object_cleanup',
    'user_id',actor,'objects',manifest);
end;
$$;
revoke all on function public.prepare_account_deletion_database(uuid) from public,anon,authenticated;
grant execute on function public.prepare_account_deletion_database(uuid) to service_role;

create or replace function public.mark_account_deletion_objects_removed(p_operation_id uuid)
returns boolean language plpgsql volatile security definer
set search_path=pg_catalog,public,private,auth as $$
begin
  update private.account_deletion_operations set phase='auth_delete',last_error_code=null,
    attempts=attempts+1,updated_at=clock_timestamp()
    where operation_id=p_operation_id and phase='object_cleanup';
  if not found then
    return exists(select 1 from private.account_deletion_operations o
      where o.operation_id=p_operation_id and o.phase in ('auth_delete','complete'));
  end if;
  return true;
end;
$$;
revoke all on function public.mark_account_deletion_objects_removed(uuid) from public,anon,authenticated;
grant execute on function public.mark_account_deletion_objects_removed(uuid) to service_role;

create or replace function public.finish_account_deletion(p_operation_id uuid)
returns boolean language plpgsql volatile security definer
set search_path=pg_catalog,public,private,auth as $$
declare actor uuid;
begin
  select user_id into actor from private.account_deletion_operations
    where operation_id=p_operation_id and phase='auth_delete' for update;
  if not found then
    return exists(select 1 from private.account_deletion_operations o
      where o.operation_id=p_operation_id and o.phase='complete');
  end if;
  if exists(select 1 from auth.users where id=actor) then
    raise exception 'Auth Admin deletion is not confirmed' using errcode='40001';
  end if;
  update private.user_safety_state set status='deleted',version=version+1,reason=null,
    changed_by=null,changed_at=clock_timestamp() where user_id=actor;
  update private.account_deletion_operations set phase='complete',last_error_code=null,
    completed_at=clock_timestamp(),updated_at=clock_timestamp()
    where operation_id=p_operation_id and phase='auth_delete';
  return true;
end;
$$;
revoke all on function public.finish_account_deletion(uuid) from public,anon,authenticated;
grant execute on function public.finish_account_deletion(uuid) to service_role;

create or replace function public.record_account_deletion_failure(p_operation_id uuid,p_error_code text)
returns void language plpgsql volatile security definer
set search_path=pg_catalog,public,private as $$
begin
  if p_error_code is null or p_error_code !~ '^[a-z_]{1,48}$' then
    raise exception 'invalid deletion error code' using errcode='22023';
  end if;
  update private.account_deletion_operations set last_error_code=p_error_code,
    attempts=attempts+1,updated_at=clock_timestamp()
    where operation_id=p_operation_id and phase<>'complete';
end;
$$;
revoke all on function public.record_account_deletion_failure(uuid,text) from public,anon,authenticated;
grant execute on function public.record_account_deletion_failure(uuid,text) to service_role;

-- Keep all user-level Data API access restricted while deletion can be retried.
create or replace function private.safety_pre_request()
returns void language plpgsql security definer
set search_path=pg_catalog,public,private,auth as $$
declare actor uuid:=auth.uid(); actor_role text:=auth.role(); request_path text;
begin
  if actor_role<>'authenticated' then return; end if;
  if actor is null then raise exception 'account unavailable' using errcode='42501'; end if;
  perform pg_advisory_xact_lock_shared(hashtextextended('safety-user:'||actor::text,9010));
  if not exists(select 1 from auth.users u where u.id=actor) then
    raise exception 'account unavailable' using errcode='42501';
  end if;
  if private.safety_actor_active(actor) then return; end if;
  request_path:=coalesce(current_setting('request.path',true),'');
  if request_path in ('/rpc/get_my_safety_state','/rpc/list_my_safety_notices',
      '/rpc/acknowledge_safety_notice','/rpc/get_my_account_deletion_preflight',
      '/rpc/request_account_deletion','/rpc/get_my_account_deletion_status') then return; end if;
  raise exception 'account access restricted' using errcode='42501';
end;
$$;
revoke all on function private.safety_pre_request() from public,anon,authenticated,service_role;
grant execute on function private.safety_pre_request() to authenticator;
notify pgrst,'reload config';

commit;
