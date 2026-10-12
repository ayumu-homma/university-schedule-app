-- SAFETY-01 slice A: warnings, enforced suspensions, and durable audit.
-- Account deletion is implemented as a separate resumable slice.
begin;

create table if not exists private.user_safety_state (
  user_id uuid primary key,
  status text not null default 'active' check(status in ('active','suspended','deletion_pending')),
  version bigint not null default 1 check(version>0),
  reason text,
  changed_by uuid,
  changed_at timestamptz not null default clock_timestamp()
);
revoke all on private.user_safety_state from public,anon,authenticated,service_role;
grant select,insert,update on private.user_safety_state to postgres,supabase_admin;

create table if not exists private.user_safety_notices (
  id uuid primary key default gen_random_uuid(),
  recipient_user_id uuid not null,
  report_id uuid,
  reason text not null check(length(trim(reason)) between 1 and 1000),
  created_by uuid not null,
  created_at timestamptz not null default clock_timestamp(),
  acknowledged_at timestamptz
);
create index if not exists user_safety_notices_recipient_idx
  on private.user_safety_notices(recipient_user_id,created_at desc,id desc);
revoke all on private.user_safety_notices from public,anon,authenticated,service_role;
grant select,insert,update on private.user_safety_notices to postgres,supabase_admin;

alter table public.groups
  add column if not exists suspended_at timestamptz,
  add column if not exists suspended_by uuid,
  add column if not exists suspension_reason text,
  add column if not exists suspension_version bigint not null default 0;

create or replace function private.safety_actor_active(p_user uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,private,auth as $$
  select p_user is not null
    and exists(select 1 from auth.users u where u.id=p_user
      and (u.banned_until is null or u.banned_until<=clock_timestamp()))
    and not exists(select 1 from public.profiles p where p.user_id=p_user and p.deleted_at is not null)
    and not exists(select 1 from private.user_safety_state s
      where s.user_id=p_user and s.status<>'active');
$$;
revoke all on function private.safety_actor_active(uuid) from public,anon,authenticated,service_role;
grant execute on function private.safety_actor_active(uuid) to authenticated;
grant execute on function private.safety_actor_active(uuid) to postgres,supabase_admin;

create or replace function private.safety_group_active(p_group uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select exists(select 1 from public.groups g where g.id=p_group and g.deleted_at is null
    and g.suspended_at is null);
$$;
revoke all on function private.safety_group_active(uuid) from public,anon,authenticated,service_role;
grant execute on function private.safety_group_active(uuid) to postgres,supabase_admin;

-- Every authenticated Data API transaction shares this actor barrier. A
-- moderation transition takes the exclusive form, so in-flight requests drain
-- before suspension becomes visible and later requests recheck state.
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
                      '/rpc/acknowledge_safety_notice','/rpc/request_account_deletion') then
    return;
  end if;
  raise exception 'account access restricted' using errcode='42501';
end;
$$;
revoke all on function private.safety_pre_request() from public,anon,authenticated,service_role;
grant usage on schema private to authenticator;
grant execute on function private.safety_pre_request() to authenticator;
do $$ begin
  execute format('alter role authenticator in database %I set pgrst.db_pre_request = %L',
    current_database(),'private.safety_pre_request');
end $$;
notify pgrst,'reload config';

create or replace function private.safety_require_admin()
returns uuid language plpgsql security definer
set search_path=pg_catalog,public,private,auth as $$
declare actor uuid:=auth.uid();
begin
  if actor is null or not private.is_global_admin(actor) or not private.safety_actor_active(actor) then
    raise exception 'global admin required' using errcode='42501';
  end if;
  return actor;
end;
$$;
revoke all on function private.safety_require_admin() from public,anon,authenticated,service_role;
grant execute on function private.safety_require_admin() to postgres,supabase_admin;

create or replace function public.get_my_safety_state()
returns table(status text,version bigint,reason text,changed_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public,private,auth as $$
declare actor uuid:=auth.uid();
begin
  if actor is null then raise exception 'not authenticated' using errcode='42501'; end if;
  return query select coalesce(s.status,'active'),coalesce(s.version,0),
    case when s.status='suspended' then s.reason else null end,
    coalesce(s.changed_at,actor_row.created_at)
  from auth.users actor_row left join private.user_safety_state s on s.user_id=actor
  where actor_row.id=actor;
end;
$$;

create or replace function public.list_my_safety_notices(p_limit integer default 50)
returns table(notice_id uuid,report_id uuid,reason text,created_at timestamptz,acknowledged_at timestamptz)
language plpgsql security definer set search_path=pg_catalog,public,private,auth as $$
declare actor uuid:=auth.uid();
begin
  if actor is null or p_limit is null or p_limit<1 or p_limit>50 then
    raise exception 'invalid notice request' using errcode='42501';
  end if;
  return query select n.id,n.report_id,n.reason,n.created_at,n.acknowledged_at
    from private.user_safety_notices n where n.recipient_user_id=actor
    order by n.created_at desc,n.id desc limit p_limit;
end;
$$;

create or replace function public.acknowledge_safety_notice(p_notice_id uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,private,auth as $$
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode='42501'; end if;
  update private.user_safety_notices set acknowledged_at=coalesce(acknowledged_at,clock_timestamp())
    where id=p_notice_id and recipient_user_id=auth.uid();
  return found;
end;
$$;
revoke all on function public.get_my_safety_state() from public,anon,service_role;
revoke all on function public.list_my_safety_notices(integer) from public,anon,service_role;
revoke all on function public.acknowledge_safety_notice(uuid) from public,anon,service_role;
grant execute on function public.get_my_safety_state() to authenticated;
grant execute on function public.list_my_safety_notices(integer) to authenticated;
grant execute on function public.acknowledge_safety_notice(uuid) to authenticated;

-- Serialize group-scoped requests against moderation transitions and refuse
-- group reads/writes for suspended members as well as suspended groups.
create or replace function private.group_member(g uuid,u uuid)
returns boolean language plpgsql volatile security definer
set search_path=pg_catalog,public,private as $$
begin
  if g is null or u is null then return false; end if;
  perform pg_advisory_xact_lock_shared(hashtextextended('safety-group:'||g::text,9010));
  return private.safety_actor_active(u) and private.safety_group_active(g)
    and exists(select 1 from public.group_members m where m.group_id=g and m.user_id=u);
end;
$$;
create or replace function private.group_admin(g uuid,u uuid)
returns boolean language plpgsql volatile security definer
set search_path=pg_catalog,public,private as $$
begin
  if g is null or u is null then return false; end if;
  perform pg_advisory_xact_lock_shared(hashtextextended('safety-group:'||g::text,9010));
  return private.safety_actor_active(u) and private.safety_group_active(g)
    and exists(select 1 from public.group_members m where m.group_id=g and m.user_id=u
      and m.role in('owner','admin'));
end;
$$;
revoke all on function private.group_member(uuid,uuid) from public,anon;
revoke all on function private.group_admin(uuid,uuid) from public,anon;
grant execute on function private.group_member(uuid,uuid) to authenticated;
grant execute on function private.group_admin(uuid,uuid) to authenticated;

create or replace function private.safety_group_member_write_guard()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,private as $$
begin
  perform pg_advisory_xact_lock_shared(hashtextextended('safety-group:'||new.group_id::text,9010));
  if not private.safety_group_active(new.group_id) or not private.safety_actor_active(new.user_id) then
    raise exception 'group membership unavailable' using errcode='42501';
  end if;
  return new;
end;
$$;
revoke all on function private.safety_group_member_write_guard() from public,anon,authenticated,service_role;
drop trigger if exists safety_group_member_write_guard on public.group_members;
create trigger safety_group_member_write_guard before insert or update of group_id,user_id,role
  on public.group_members for each row execute function private.safety_group_member_write_guard();

create or replace function private.is_group_member(target_group_id uuid,target_user_id uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select private.group_member(target_group_id,target_user_id);
$$;
create or replace function private.is_group_admin(target_group_id uuid,target_user_id uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select private.group_admin(target_group_id,target_user_id);
$$;
create or replace function private.can_access_event(target_event_id uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select auth.uid() is not null and private.safety_actor_active(auth.uid()) and exists(
    select 1 from public.events e where e.id=target_event_id and e.deleted_at is null
      and e.moderation_hidden_at is null
      and (e.owner_user_id=auth.uid() or (e.group_id is not null
        and private.group_member(e.group_id,auth.uid())
        and private.safety_actor_active(e.owner_user_id)
        and not private.is_blocked(e.owner_user_id))));
$$;
create or replace function private.can_edit_event(target_event_id uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select auth.uid() is not null
    and private.safety_actor_active(auth.uid())
    and exists (
      select 1 from public.events e
      where e.id=target_event_id and e.deleted_at is null and e.moderation_hidden_at is null
        and (
          e.owner_user_id=auth.uid()
          or (
            e.group_id is not null
            and private.safety_actor_active(e.owner_user_id)
            and not private.is_blocked(e.owner_user_id)
            and (
              (e.created_by=auth.uid() and private.group_member(e.group_id,auth.uid()))
              or private.group_admin(e.group_id,auth.uid())
            )
          )
        )
    );
$$;
revoke all on function private.is_group_member(uuid,uuid),private.is_group_admin(uuid,uuid),
  private.can_access_event(uuid),private.can_edit_event(uuid) from public,anon;
grant execute on function private.is_group_member(uuid,uuid),private.is_group_admin(uuid,uuid),
  private.can_access_event(uuid),private.can_edit_event(uuid) to authenticated;

create or replace function public.preview_group_invite(p_token text)
returns table(invite_id uuid,group_id uuid,group_name text,expires_at timestamptz,status text)
language plpgsql volatile security definer set search_path=pg_catalog,public,private as $$
declare invite public.group_invitations%rowtype; group_name_value text;
begin
  if p_token is null or p_token !~ '^[0-9a-fA-F]{64}$' then return; end if;
  select * into invite from public.group_invitations i
    where i.token_hash=encode(extensions.digest(lower(p_token),'sha256'),'hex');
  if not found then return; end if;
  perform pg_advisory_xact_lock_shared(hashtextextended('safety-group:'||invite.group_id::text,9010));
  if not private.safety_group_active(invite.group_id) then return; end if;
  select g.name into group_name_value from public.groups g where g.id=invite.group_id;
  return query select invite.id,invite.group_id,group_name_value,invite.expires_at,
    case when invite.revoked_at is not null then 'revoked'
      when invite.expires_at<=clock_timestamp() then 'expired'
      when invite.used_count>=coalesce(invite.max_uses,1) then 'exhausted' else 'active' end;
end;
$$;
revoke all on function public.preview_group_invite(text) from public,anon;
grant execute on function public.preview_group_invite(text) to authenticated;

create or replace function private.friend_is_group_member(p_viewer uuid,p_group uuid)
returns boolean language plpgsql volatile security definer
set search_path=pg_catalog,public,private as $$
begin
  return private.group_member(p_group,p_viewer);
end;
$$;
create or replace function private.notification_recipient_allowed(
  p_group_id uuid,p_recipient uuid,p_actor uuid
) returns boolean language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select private.safety_group_active(p_group_id) and private.safety_actor_active(p_recipient)
    and private.safety_actor_active(p_actor)
    and p_recipient is distinct from p_actor
    and exists(select 1 from public.group_members m where m.group_id=p_group_id and m.user_id=p_recipient)
    and coalesce((select n.group_updates_enabled from public.notification_settings n where n.user_id=p_recipient),true)
    and not exists(select 1 from public.blocks b where
      (b.blocker_user_id=p_recipient and b.blocked_user_id=p_actor) or
      (b.blocker_user_id=p_actor and b.blocked_user_id=p_recipient));
$$;
create or replace function private.notification_inbox_allowed(
  p_type text,p_group_id uuid,p_event_id uuid,p_invitation_id uuid,p_recipient uuid,p_actor uuid
) returns boolean language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select private.safety_actor_active(p_recipient) and private.safety_actor_active(p_actor)
    and private.safety_group_active(p_group_id)
    and private.notification_account_eligible(p_recipient)
    and (p_type='group_invitation' or coalesce((select n.group_updates_enabled
      from public.notification_settings n where n.user_id=p_recipient),true))
    and not exists(select 1 from public.blocks b where
      (b.blocker_user_id=p_recipient and b.blocked_user_id=p_actor) or
      (b.blocker_user_id=p_actor and b.blocked_user_id=p_recipient))
    and case when p_type='group_invitation' then exists(
      select 1 from public.group_targeted_invitations ti where ti.id=p_invitation_id
        and ti.group_id=p_group_id and ti.invitee_user_id=p_recipient
        and ti.inviter_user_id is not distinct from p_actor and ti.status='pending'
        and ti.expires_at>clock_timestamp())
    else private.notification_recipient_allowed(p_group_id,p_recipient,p_actor)
      and (p_event_id is null or exists(select 1 from public.events e where e.id=p_event_id
        and e.group_id=p_group_id and e.kind='group' and e.deleted_at is null
        and e.moderation_hidden_at is null)) end;
$$;

-- Preserve the verified Phase 15 implementations, then wrap their projections
-- with owner/suspension predicates.
do $$
declare d text;
begin
  if to_regprocedure('private.phase15_build_friend_snapshot_base(uuid,uuid,uuid,timestamptz,timestamptz,boolean)') is null then
    select pg_get_functiondef('private.build_friend_snapshot(uuid,uuid,uuid,timestamptz,timestamptz,boolean)'::regprocedure) into d;
    d:=replace(d,'private.build_friend_snapshot(', 'private.phase15_build_friend_snapshot_base(');
    execute d;
  end if;
  if to_regprocedure('private.phase15_resolve_visible_events_for_base(uuid,timestamptz,timestamptz)') is null then
    select pg_get_functiondef('private.resolve_visible_events_for(uuid,timestamptz,timestamptz)'::regprocedure) into d;
    d:=replace(d,'private.resolve_visible_events_for(', 'private.phase15_resolve_visible_events_for_base(');
    execute d;
  end if;
end $$;

create or replace function private.build_friend_snapshot(
  p_viewer uuid,p_owner uuid,p_term uuid,p_range_start timestamptz,p_range_end timestamptz,p_allowed boolean
) returns jsonb language plpgsql volatile security definer
set search_path=pg_catalog,public,private as $$
begin
  if p_owner is not null then
    perform pg_advisory_xact_lock_shared(hashtextextended('safety-user:'||p_owner::text,9010));
  end if;
  if not p_allowed or not private.safety_actor_active(p_viewer) or not private.safety_actor_active(p_owner) then
    return jsonb_build_object('allowed',false,'revision',0,'owner_schedule_cursor',0,
      'rows',jsonb_build_object('items','[]'::jsonb));
  end if;
  return private.phase15_build_friend_snapshot_base(p_viewer,p_owner,p_term,p_range_start,p_range_end,p_allowed);
end;
$$;

create or replace function private.resolve_visible_events_for(
  p_viewer uuid,p_range_start timestamptz,p_range_end timestamptz
) returns table(event_id uuid,owner_user_id uuid,start_at timestamptz,end_at timestamptz,
  visibility_level public.visibility_level,title text,location text,description text,kind text,group_id uuid)
language sql stable security definer set search_path=pg_catalog,public,private as $$
  select b.* from private.phase15_resolve_visible_events_for_base(p_viewer,p_range_start,p_range_end) b
  where private.safety_actor_active(p_viewer) and private.safety_actor_active(b.owner_user_id)
    and (b.group_id is null or private.safety_group_active(b.group_id));
$$;

revoke all on function private.build_friend_snapshot(uuid,uuid,uuid,timestamptz,timestamptz,boolean),
  private.resolve_visible_events_for(uuid,timestamptz,timestamptz),
  private.phase15_build_friend_snapshot_base(uuid,uuid,uuid,timestamptz,timestamptz,boolean),
  private.phase15_resolve_visible_events_for_base(uuid,timestamptz,timestamptz)
  from public,anon,authenticated,service_role;
grant execute on function private.phase15_build_friend_snapshot_base(uuid,uuid,uuid,timestamptz,timestamptz,boolean),
  private.phase15_resolve_visible_events_for_base(uuid,timestamptz,timestamptz)
  to postgres,supabase_admin;

create or replace function public.list_my_groups()
returns table(group_id uuid,name text,owner_user_id uuid,type text,description text,event_create_policy text,role text)
language plpgsql volatile security definer set search_path=pg_catalog,public,private as $$
begin
  return query select g.id,g.name,g.owner_user_id,g.type,g.description,g.event_create_policy,m.role
    from public.groups g join public.group_members m on m.group_id=g.id and m.user_id=auth.uid()
    where g.deleted_at is null and private.group_member(g.id,auth.uid()) order by g.updated_at desc;
end;
$$;
revoke all on function public.list_my_groups() from public,anon;
grant execute on function public.list_my_groups() to authenticated;

do $$
declare d text;
begin
  if to_regprocedure('private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)') is null then
    select pg_get_functiondef('public.find_group_availability(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure) into d;
    d:=replace(d,'public.find_group_availability(', 'private.phase12_find_group_availability_base(');
    execute d;
  end if;
end $$;
revoke all on function private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)
  from public,anon,authenticated,service_role;
grant execute on function private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)
  to postgres,supabase_admin;
create or replace function public.find_group_availability(
  p_group_id uuid,p_member_ids uuid[],p_range_start timestamptz,p_range_end timestamptz,
  p_minimum_duration_minutes integer)
returns jsonb language plpgsql volatile security definer
set search_path=pg_catalog,public,private as $$
declare actor uuid:=auth.uid(); member_id uuid;
begin
  if actor is null or p_member_ids is null or not(actor=any(p_member_ids))
     or not private.group_member(p_group_id,actor) then
    raise exception 'membership or authorization changed; retry' using errcode='42501';
  end if;
  foreach member_id in array p_member_ids loop
    if not private.group_member(p_group_id,member_id) then
      raise exception 'membership or authorization changed; retry' using errcode='42501';
    end if;
  end loop;
  return private.phase12_find_group_availability_base(
    p_group_id,p_member_ids,p_range_start,p_range_end,p_minimum_duration_minutes);
end;
$$;
revoke all on function public.find_group_availability(uuid,uuid[],timestamptz,timestamptz,integer)
  from public,anon;
grant execute on function public.find_group_availability(uuid,uuid[],timestamptz,timestamptz,integer)
  to authenticated;

create or replace function public.validate_group_availability(
  p_group_id uuid,p_member_ids uuid[],p_generation text)
returns jsonb language plpgsql volatile security definer
set search_path=pg_catalog,public,private as $$
declare actor uuid:=auth.uid(); current_generation text; member_id uuid;
begin
  if actor is null or p_member_ids is null or not(actor=any(p_member_ids)) then
    raise exception 'availability validation denied' using errcode='42501';
  end if;
  if not private.group_member(p_group_id,actor) then
    return jsonb_build_object('valid',false,'generation',null);
  end if;
  foreach member_id in array p_member_ids loop
    if not private.group_member(p_group_id,member_id) or private.is_blocked(member_id) then
      return jsonb_build_object('valid',false,'generation',null);
    end if;
  end loop;
  select md5(g.version::text||':'||coalesce(string_agg(m.user_id::text||':'||m.role||':'||m.joined_at::text,',' order by m.user_id),''))
    into current_generation from public.groups g join public.group_members m
      on m.group_id=g.id and m.user_id=any(p_member_ids) where g.id=p_group_id group by g.version;
  return jsonb_build_object('valid',current_generation=p_generation,'generation',current_generation);
end;
$$;
revoke all on function public.validate_group_availability(uuid,uuid[],text) from public,anon;
grant execute on function public.validate_group_availability(uuid,uuid[],text) to authenticated;

create or replace function public.admin_get_report(p_report_id uuid)
returns table(report_id uuid,target_type text,target_id uuid,reason text,status text,created_at timestamptz,
  reporter_user_id uuid,reporter_display_name text,target_state text,decision_reason text,
  resolved_by uuid,resolved_at timestamptz,target_context jsonb)
language plpgsql stable security definer set search_path=pg_catalog,public,private,auth as $$
begin
  perform private.safety_require_admin();
  return query select r.id,r.target_type,r.target_id,r.reason,r.status,r.created_at,r.reporter_user_id,
    coalesce(reporter.display_name,'利用者'),r.target_state,r.decision_reason,r.resolved_by,r.resolved_at,
    case when r.target_type='event' then (
      select jsonb_build_object('event_id',e.id,'owner_user_id',e.owner_user_id,'created_by',e.created_by,
        'group_id',e.group_id,'group_name',g.name,'title',left(e.title,200),
        'description',left(coalesce(e.description,''),1000),'start_at',e.start_at,'end_at',e.end_at,
        'deleted_at',e.deleted_at,'moderation_hidden_at',e.moderation_hidden_at)
      from public.events e left join public.groups g on g.id=e.group_id where e.id=r.target_id)
    when r.target_type='comment' then (
      select jsonb_build_object('comment_id',c.id,'event_id',c.event_id,'author_user_id',c.author_user_id,
        'group_id',e.group_id,'group_name',g.name,'body',left(c.body,2000),
        'deleted_at',c.deleted_at,'moderation_hidden_at',c.moderation_hidden_at)
      from public.event_comments c join public.events e on e.id=c.event_id
        left join public.groups g on g.id=e.group_id where c.id=r.target_id)
    when r.target_type='group' then (
      select jsonb_build_object('group_id',g.id,'name',g.name,'owner_user_id',g.owner_user_id,
        'deleted_at',g.deleted_at,'suspended_at',g.suspended_at)
      from public.groups g where g.id=r.target_id)
    when r.target_type='user' then (
      select jsonb_build_object('user_id',u.id,'display_name',coalesce(p.display_name,'利用者'))
      from auth.users u left join public.profiles p on p.user_id=u.id where u.id=r.target_id)
    else jsonb_build_object('target_type',r.target_type,'target_id',r.target_id) end
  from public.reports r left join public.profiles reporter on reporter.user_id=r.reporter_user_id
  where r.id=p_report_id;
end;
$$;
revoke all on function public.admin_get_report(uuid) from public,anon,service_role;
grant execute on function public.admin_get_report(uuid) to authenticated;

create or replace function public.admin_resolve_report(p_report_id uuid,p_action text,p_reason text,p_operation_id uuid)
returns table(report_id uuid,status text,action text,target_state text,audit_id uuid,previous_target_state text)
language plpgsql security definer set search_path=pg_catalog,public,private,auth as $$
declare a uuid:=private.safety_require_admin(); h text; r jsonb; q public.reports%rowtype;
  e public.events%rowtype; c public.event_comments%rowtype; target_user uuid; target_group uuid;
  state text; aid uuid; old_version bigint; previous_state text;
begin
  if p_action not in('dismiss','hide','warn_user','suspend_user','suspend_group')
     or length(trim(coalesce(p_reason,'')))<1 or length(p_reason)>1000 then
    raise exception 'invalid moderation decision' using errcode='22023';
  end if;
  h:=encode(extensions.digest(jsonb_build_object('report_id',p_report_id,'action',p_action,
    'reason',trim(p_reason))::text,'sha256'),'hex');
  r:=private.admin_lock(a,p_operation_id,'admin_resolve_report',h);
  if r is not null then return query select (r->>'report_id')::uuid,r->>'status',r->>'action',
    r->>'target_state',(r->>'audit_id')::uuid,r->>'previous_target_state'; return; end if;
  select * into q from public.reports x where x.id=p_report_id for update;
  if not found or q.status<>'pending' then raise exception 'report unavailable' using errcode='40001'; end if;
  previous_state:=q.target_state;
  if q.target_type='event' then
    select * into e from public.events x where x.id=q.target_id for update;
    if not found then raise exception 'report target unavailable' using errcode='42501'; end if;
    target_user:=e.owner_user_id; target_group:=e.group_id;
  elsif q.target_type='comment' then
    select * into c from public.event_comments x where x.id=q.target_id for update;
    if not found then raise exception 'report target unavailable' using errcode='42501'; end if;
    target_user:=c.author_user_id;
    select ev.group_id into target_group from public.events ev where ev.id=c.event_id;
  elsif q.target_type='user' then target_user:=q.target_id;
  elsif q.target_type='group' then target_group:=q.target_id;
  else raise exception 'unsupported report target' using errcode='22023'; end if;

  if p_action in('warn_user','suspend_user') then
    if target_user is null or target_user=a or not exists(select 1 from auth.users u where u.id=target_user) then
      raise exception 'invalid user moderation target' using errcode='42501';
    end if;
    perform pg_advisory_xact_lock(hashtextextended('safety-user:'||target_user::text,9010));
    if p_action='suspend_user' then
      perform pg_advisory_xact_lock(hashtextextended('safety-admin-set',9010));
    end if;
    if private.is_global_admin(target_user) and
       (select count(*) from private.global_admins ga join auth.users u on u.id=ga.user_id
        where ga.revoked_at is null and private.safety_actor_active(ga.user_id))<=1 then
      raise exception 'cannot suspend the last active global admin' using errcode='42501';
    end if;
    if p_action='warn_user' then
      insert into private.user_safety_notices(recipient_user_id,report_id,reason,created_by)
      values(target_user,q.id,trim(p_reason),a);
      state:='warning_created';
    else
      insert into private.user_safety_state(user_id,status,version,reason,changed_by)
      values(target_user,'suspended',1,trim(p_reason),a)
      on conflict(user_id) do update set status='suspended',version=private.user_safety_state.version+1,
        reason=excluded.reason,changed_by=excluded.changed_by,changed_at=clock_timestamp()
      returning version into old_version;
      update private.notification_installation_bindings set enabled=false,updated_at=clock_timestamp()
        where user_id=target_user and enabled;
      update public.device_tokens set revoked_at=clock_timestamp()
        where user_id=target_user and revoked_at is null;
      update public.group_targeted_invitations gti set status='revoked',responded_at=clock_timestamp()
        where gti.status='pending' and (gti.invitee_user_id=target_user or gti.inviter_user_id=target_user);
      update public.group_invitations set revoked_at=clock_timestamp()
        where created_by=target_user and revoked_at is null;
      state:='user_suspended_v'||old_version;
    end if;
  elsif p_action='suspend_group' then
    if target_group is null then raise exception 'invalid group moderation target' using errcode='42501'; end if;
    perform pg_advisory_xact_lock(hashtextextended('group:'||target_group::text,9010));
    perform pg_advisory_xact_lock(hashtextextended('safety-group:'||target_group::text,9010));
    update public.groups set suspended_at=clock_timestamp(),suspended_by=a,
      suspension_reason=trim(p_reason),suspension_version=suspension_version+1,updated_at=clock_timestamp()
      where id=target_group and deleted_at is null returning suspension_version into old_version;
    if not found then raise exception 'group moderation target unavailable' using errcode='42501'; end if;
    update public.group_invitations set revoked_at=clock_timestamp()
      where group_id=target_group and revoked_at is null;
    update public.group_targeted_invitations gti set status='revoked',responded_at=clock_timestamp()
      where gti.group_id=target_group and gti.status='pending';
    state:='group_suspended_v'||old_version;
  elsif p_action='hide' then
    if q.target_type='event' then
      if e.deleted_at is not null then state:='already_deleted';
      elsif e.moderation_hidden_at is null then
        update public.events set moderation_hidden_at=clock_timestamp(),moderation_hidden_by=a,
          updated_at=clock_timestamp(),version=version+1 where id=q.target_id;
        state:='hidden'; else state:='already_hidden'; end if;
    elsif q.target_type='comment' then
      if c.deleted_at is not null then state:='already_deleted';
      elsif c.moderation_hidden_at is null then
        update public.event_comments set moderation_hidden_at=clock_timestamp(),moderation_hidden_by=a,
          updated_at=clock_timestamp(),version=version+1 where id=q.target_id;
        state:='hidden'; else state:='already_hidden'; end if;
    else raise exception 'unsupported hide target' using errcode='22023'; end if;
  else state:='unchanged'; end if;

  update public.reports set status=case when p_action='dismiss' then 'dismissed' else 'actioned' end,
    resolved_by=a,resolved_at=clock_timestamp(),decision_reason=trim(p_reason),target_state=state where id=q.id;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata)
    values(a,'moderation_'||p_action,q.target_type,q.target_id,
      jsonb_build_object('report_id',q.id,'reason',trim(p_reason),'previous_status',q.status,
        'target_state',state,'target_user_id',target_user,'target_group_id',target_group)) returning id into aid;
  r:=jsonb_build_object('report_id',q.id,'status',case when p_action='dismiss' then 'dismissed' else 'actioned' end,
    'action',p_action,'target_state',state,'audit_id',aid,'previous_target_state',previous_state);
  perform private.admin_record(a,p_operation_id,'admin_resolve_report',h,r);
  return query select q.id,r->>'status',p_action,state,aid,previous_state;
end;
$$;
revoke all on function public.admin_resolve_report(uuid,text,text,uuid) from public,anon,service_role;
grant execute on function public.admin_resolve_report(uuid,text,text,uuid) to authenticated;

create or replace function public.admin_list_suspended_targets(
  p_target_type text,p_limit integer default 50,p_offset integer default 0
) returns table(target_type text,target_id uuid,display_name text,reason text,version bigint,changed_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public,private,auth as $$
declare a uuid:=private.safety_require_admin();
begin
  if p_target_type not in('user','group') or p_limit is null or p_limit<1 or p_limit>50
     or p_offset is null or p_offset<0 then
    raise exception 'invalid suspension page' using errcode='22023';
  end if;
  if p_target_type='user' then
    return query select 'user'::text,s.user_id,coalesce(p.display_name,'利用者'),s.reason,s.version,s.changed_at
      from private.user_safety_state s join auth.users u on u.id=s.user_id
      left join public.profiles p on p.user_id=s.user_id
      where s.status='suspended' order by s.changed_at desc,s.user_id limit p_limit offset p_offset;
  else
    return query select 'group'::text,g.id,g.name,g.suspension_reason,g.suspension_version,g.suspended_at
      from public.groups g where g.suspended_at is not null
      order by g.suspended_at desc,g.id limit p_limit offset p_offset;
  end if;
end;
$$;
revoke all on function public.admin_list_suspended_targets(text,integer,integer) from public,anon,service_role;
grant execute on function public.admin_list_suspended_targets(text,integer,integer) to authenticated;

create or replace function public.admin_set_safety_state(
  p_target_type text,p_target_id uuid,p_restore boolean,p_expected_version bigint,
  p_reason text,p_operation_id uuid
) returns table(target_type text,target_id uuid,status text,version bigint,audit_id uuid)
language plpgsql security definer set search_path=pg_catalog,public,private,auth as $$
declare a uuid:=private.safety_require_admin(); h text; prior jsonb; current_version bigint;
  next_version bigint; new_status text; aid uuid;
begin
  if p_target_type not in('user','group') or p_target_id is null or p_expected_version is null
     or p_expected_version<0 or length(trim(coalesce(p_reason,'')))<1 or length(p_reason)>1000 then
    raise exception 'invalid safety transition' using errcode='22023';
  end if;
  h:=encode(extensions.digest(jsonb_build_object('type',p_target_type,'id',p_target_id,
    'restore',p_restore,'version',p_expected_version,'reason',trim(p_reason))::text,'sha256'),'hex');
  prior:=private.admin_lock(a,p_operation_id,'admin_set_safety_state',h);
  if prior is not null then return query select prior->>'target_type',(prior->>'target_id')::uuid,
    prior->>'status',(prior->>'version')::bigint,(prior->>'audit_id')::uuid; return; end if;
  if p_target_type='user' then
    if p_target_id=a then raise exception 'cannot change own account safety state' using errcode='42501'; end if;
    perform pg_advisory_xact_lock(hashtextextended('safety-user:'||p_target_id::text,9010));
    if not p_restore then
      perform pg_advisory_xact_lock(hashtextextended('safety-admin-set',9010));
    end if;
    select coalesce(s.version,0),coalesce(s.status,'active') into current_version,new_status
      from auth.users u left join private.user_safety_state s on s.user_id=u.id
      where u.id=p_target_id for update of u;
    if not found then raise exception 'user unavailable' using errcode='42501'; end if;
    if current_version<>p_expected_version or (p_restore and new_status<>'suspended')
       or (not p_restore and new_status<>'active') then
      raise exception 'safety state changed' using errcode='40001';
    end if;
    if private.is_global_admin(p_target_id) and not p_restore and
       (select count(*) from private.global_admins ga where ga.revoked_at is null
        and private.safety_actor_active(ga.user_id))<=1 then
      raise exception 'cannot suspend the last active global admin' using errcode='42501';
    end if;
    new_status:=case when p_restore then 'active' else 'suspended' end;
    next_version:=current_version+1;
    insert into private.user_safety_state(user_id,status,version,reason,changed_by,changed_at)
      values(p_target_id,new_status,next_version,case when p_restore then null else trim(p_reason) end,a,clock_timestamp())
      on conflict(user_id) do update set status=excluded.status,version=excluded.version,
        reason=excluded.reason,changed_by=excluded.changed_by,changed_at=excluded.changed_at;
    if not p_restore then
      update public.group_targeted_invitations gti set status='revoked',responded_at=clock_timestamp()
        where gti.status='pending' and (gti.invitee_user_id=p_target_id or gti.inviter_user_id=p_target_id);
      update public.group_invitations set revoked_at=clock_timestamp()
        where created_by=p_target_id and revoked_at is null;
      update private.notification_installation_bindings set enabled=false,updated_at=clock_timestamp()
        where user_id=p_target_id and enabled;
      update public.device_tokens set revoked_at=clock_timestamp()
        where user_id=p_target_id and revoked_at is null;
    end if;
  else
    perform pg_advisory_xact_lock(hashtextextended('group:'||p_target_id::text,9010));
    perform pg_advisory_xact_lock(hashtextextended('safety-group:'||p_target_id::text,9010));
    select g.suspension_version,case when g.suspended_at is null then 'active' else 'suspended' end
      into current_version,new_status from public.groups g where g.id=p_target_id for update;
    if not found or current_version<>p_expected_version or
       (p_restore and new_status<>'suspended') or (not p_restore and new_status<>'active') then
      raise exception 'safety state changed' using errcode='40001';
    end if;
    new_status:=case when p_restore then 'active' else 'suspended' end;
    next_version:=current_version+1;
    update public.groups set suspended_at=case when p_restore then null else clock_timestamp() end,
      suspended_by=case when p_restore then null else a end,
      suspension_reason=case when p_restore then null else trim(p_reason) end,
      suspension_version=next_version,updated_at=clock_timestamp() where id=p_target_id;
    if not p_restore then
      update public.group_invitations set revoked_at=clock_timestamp()
        where group_id=p_target_id and revoked_at is null;
      update public.group_targeted_invitations gti set status='revoked',responded_at=clock_timestamp()
        where gti.group_id=p_target_id and gti.status='pending';
    end if;
  end if;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata)
    values(a,case when p_restore then 'safety_restore' else 'safety_suspend' end,p_target_type,p_target_id,
      jsonb_build_object('reason',trim(p_reason),'version',next_version,'status',new_status)) returning id into aid;
  prior:=jsonb_build_object('target_type',p_target_type,'target_id',p_target_id,
    'status',new_status,'version',next_version,'audit_id',aid);
  perform private.admin_record(a,p_operation_id,'admin_set_safety_state',h,prior);
  return query select p_target_type,p_target_id,new_status,next_version,aid;
end;
$$;
revoke all on function public.admin_set_safety_state(text,uuid,boolean,bigint,text,uuid) from public,anon,service_role;
grant execute on function public.admin_set_safety_state(text,uuid,boolean,bigint,text,uuid) to authenticated;

-- Block active peers from viewing a suspended owner's shared timetable and
-- enforce user status for direct table/realtime reads. Existing permissive
-- policies remain authoritative for row ownership; this restrictive policy
-- only removes suspended/deleting actors.
do $$
declare r record;
begin
  for r in select n.nspname,c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r' and c.relrowsecurity
  loop
    execute format('drop policy if exists safety_actor_gate on %I.%I',r.nspname,r.relname);
    execute format('create policy safety_actor_gate on %I.%I as restrictive for all to authenticated using (private.safety_actor_active(auth.uid())) with check (private.safety_actor_active(auth.uid()))',r.nspname,r.relname);
  end loop;
end $$;
drop policy if exists safety_actor_gate on storage.objects;
create policy safety_actor_gate on storage.objects as restrictive for all to authenticated
  using(private.safety_actor_active(auth.uid())) with check(private.safety_actor_active(auth.uid()));

commit;
