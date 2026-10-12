-- NOTIF-01: durable server inbox/outbox, generation-bound private FCM token
-- storage, and explicit targeted group invitations. Existing local reminder
-- delivery remains a separate client concern.
begin;

create table private.notification_inbox (
  id uuid primary key default gen_random_uuid(),
  recipient_user_id uuid not null references auth.users(id) on delete cascade,
  actor_user_id uuid references auth.users(id) on delete set null,
  notification_type text not null check (notification_type in (
    'group_invitation','group_event_created','group_event_updated','group_comment'
  )),
  group_id uuid not null references public.groups(id) on delete cascade,
  event_id uuid references public.events(id) on delete cascade,
  invitation_id uuid,
  created_at timestamptz not null default clock_timestamp(),
  read_at timestamptz,
  unique (recipient_user_id, notification_type, group_id, event_id, invitation_id, actor_user_id, created_at)
);
revoke all on private.notification_inbox from public, anon, authenticated, service_role;

create table private.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  inbox_id uuid not null unique references private.notification_inbox(id) on delete cascade,
  recipient_user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','leased','sent','permanent_failure')),
  attempts integer not null default 0 check (attempts >= 0),
  available_at timestamptz not null default clock_timestamp(),
  lease_id uuid,
  lease_expires_at timestamptz,
  provider_message_id text,
  last_error text,
  created_at timestamptz not null default clock_timestamp()
);
create index notification_outbox_pending_idx
  on private.notification_outbox(available_at, created_at)
  where status in ('pending','leased');
revoke all on private.notification_outbox from public, anon, authenticated, service_role;

create table private.notification_delivery_attempts (
  id uuid primary key default gen_random_uuid(),
  outbox_id uuid not null references private.notification_outbox(id) on delete cascade,
  installation_id uuid not null,
  binding_generation bigint not null,
  status text not null default 'pending' check (status in ('pending','leased','sent','permanent_failure')),
  attempts integer not null default 0 check (attempts >= 0),
  available_at timestamptz not null default clock_timestamp(),
  lease_id uuid,
  lease_expires_at timestamptz,
  provider_message_id text,
  last_error text,
  unique(outbox_id,installation_id,binding_generation)
);
create index notification_delivery_pending_idx
  on private.notification_delivery_attempts(available_at,id)
  where status in ('pending','leased');
revoke all on private.notification_delivery_attempts from public,anon,authenticated,service_role;

-- Raw provider tokens are only ever stored in the private binding table. The
-- existing public table remains a nondeliverable hash/preview projection.
create table private.notification_installation_bindings (
  installation_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  client_generation bigint not null check (client_generation > 0),
  binding_generation bigint not null default 1,
  public_token_id uuid not null references public.device_tokens(id) on delete cascade,
  platform text not null check (platform in ('ios','android')),
  token text not null,
  app_version text,
  device_id text,
  enabled boolean not null default true,
  updated_at timestamptz not null default clock_timestamp(),
  unique (platform, token)
);
revoke all on private.notification_installation_bindings from public, anon, authenticated, service_role;

alter table public.device_tokens enable row level security;
revoke all on public.device_tokens from public, anon, authenticated;

create table public.group_targeted_invitations (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  inviter_user_id uuid not null references auth.users(id) on delete cascade,
  invitee_user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined','revoked','expired')),
  expires_at timestamptz not null,
  created_at timestamptz not null default clock_timestamp(),
  responded_at timestamptz,
  check (inviter_user_id<>invitee_user_id)
);
alter table public.group_targeted_invitations enable row level security;
revoke all on public.group_targeted_invitations from public, anon, authenticated;
create index group_targeted_invitations_recipient_idx
  on public.group_targeted_invitations(invitee_user_id, created_at desc)
  where status = 'pending';
create unique index group_targeted_invitation_one_pending
  on public.group_targeted_invitations(group_id,invitee_user_id) where status='pending';

create or replace function private.notification_account_eligible(p_user_id uuid)
returns boolean language sql stable security definer
set search_path=pg_catalog,public,auth,private as $$
  select exists (
    select 1 from public.profiles p join auth.users u on u.id=p.user_id
    where p.user_id=p_user_id and p.deleted_at is null
      and (u.banned_until is null or u.banned_until <= clock_timestamp())
  );
$$;
revoke all on function private.notification_account_eligible(uuid) from public,anon,authenticated,service_role;

create or replace function private.notification_recipient_allowed(
  p_group_id uuid, p_recipient uuid, p_actor uuid
) returns boolean language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select p_recipient is distinct from p_actor
    and exists (select 1 from public.groups g where g.id=p_group_id and g.deleted_at is null)
    and exists (select 1 from public.group_members m where m.group_id=p_group_id
      and m.user_id=p_recipient)
    and private.notification_account_eligible(p_recipient)
    and coalesce((select n.group_updates_enabled from public.notification_settings n
      where n.user_id=p_recipient),true)
    and not exists (select 1 from public.blocks b where
      (b.blocker_user_id=p_recipient and b.blocked_user_id=p_actor) or
      (b.blocker_user_id=p_actor and b.blocked_user_id=p_recipient));
$$;
revoke all on function private.notification_recipient_allowed(uuid,uuid,uuid) from public,anon,authenticated,service_role;

create or replace function private.notification_inbox_allowed(
  p_type text,p_group_id uuid,p_event_id uuid,p_invitation_id uuid,
  p_recipient uuid,p_actor uuid
) returns boolean language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select private.notification_account_eligible(p_recipient)
    and (p_type='group_invitation' or coalesce((select n.group_updates_enabled
      from public.notification_settings n where n.user_id=p_recipient),true))
    and not exists(select 1 from public.blocks b where
      (b.blocker_user_id=p_recipient and b.blocked_user_id=p_actor) or
      (b.blocker_user_id=p_actor and b.blocked_user_id=p_recipient))
    and case when p_type='group_invitation' then
      exists(select 1 from public.groups g where g.id=p_group_id and g.deleted_at is null)
      and exists(select 1 from public.group_targeted_invitations ti
        where ti.id=p_invitation_id and ti.group_id=p_group_id
          and ti.invitee_user_id=p_recipient and ti.inviter_user_id is not distinct from p_actor
          and ti.status='pending' and ti.expires_at>clock_timestamp())
    else
      private.notification_recipient_allowed(p_group_id,p_recipient,p_actor)
      and (p_event_id is null or exists(select 1 from public.events e
        where e.id=p_event_id and e.group_id=p_group_id and e.kind='group' and e.deleted_at is null))
    end;
$$;
revoke all on function private.notification_inbox_allowed(text,uuid,uuid,uuid,uuid,uuid)
  from public,anon,authenticated,service_role;

-- Explicit invitations remain available in the product inbox when push is
-- disabled, but the dispatcher must honor the recipient's current setting.
create or replace function private.notification_delivery_allowed(
  p_type text,p_group_id uuid,p_event_id uuid,p_invitation_id uuid,
  p_recipient uuid,p_actor uuid
) returns boolean language sql stable security definer
set search_path=pg_catalog,public,private as $$
  select private.notification_inbox_allowed(
      p_type,p_group_id,p_event_id,p_invitation_id,p_recipient,p_actor)
    and coalesce((select n.group_updates_enabled from public.notification_settings n
      where n.user_id=p_recipient),true);
$$;
revoke all on function private.notification_delivery_allowed(text,uuid,uuid,uuid,uuid,uuid)
  from public,anon,authenticated,service_role;

create or replace function private.enqueue_group_notification(
  p_type text, p_group_id uuid, p_event_id uuid, p_invitation_id uuid,
  p_actor uuid, p_only_recipient uuid default null
) returns void language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare recipient record; inbox_key uuid;
begin
  if p_type not in ('group_invitation','group_event_created','group_event_updated','group_comment') then
    raise exception 'invalid notification type' using errcode='22023';
  end if;
  for recipient in
    select m.user_id from public.group_members m
    where m.group_id=p_group_id
      and (p_only_recipient is null or m.user_id=p_only_recipient)
      and private.notification_recipient_allowed(p_group_id,m.user_id,p_actor)
    order by m.user_id
  loop
    insert into private.notification_inbox(
      recipient_user_id,actor_user_id,notification_type,group_id,event_id,invitation_id
    ) values (recipient.user_id,p_actor,p_type,p_group_id,p_event_id,p_invitation_id)
    returning id into inbox_key;
    insert into private.notification_outbox(inbox_id,recipient_user_id)
    values(inbox_key,recipient.user_id);
  end loop;
end;
$$;
revoke all on function private.enqueue_group_notification(text,uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;

create or replace function private.notification_group_event_outbox()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare actor uuid:=auth.uid();
begin
  if new.kind='group' and new.group_id is not null and new.deleted_at is null then
    if tg_op='INSERT' then
      perform private.enqueue_group_notification('group_event_created',new.group_id,new.id,null,actor);
    elsif old.deleted_at is null and (
      old.title is distinct from new.title or old.start_at is distinct from new.start_at or
      old.end_at is distinct from new.end_at or old.location is distinct from new.location or
      old.description is distinct from new.description
    ) then
      perform private.enqueue_group_notification('group_event_updated',new.group_id,new.id,null,actor);
    end if;
  end if;
  return new;
end;
$$;
revoke all on function private.notification_group_event_outbox() from public,anon,authenticated,service_role;
create trigger notification_group_event_inserted
after insert on public.events for each row execute function private.notification_group_event_outbox();
create trigger notification_group_event_changed
after update of title,start_at,end_at,location,description,deleted_at on public.events
for each row execute function private.notification_group_event_outbox();

create or replace function private.notification_group_comment_outbox()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public,private as $$
declare gid uuid;
begin
  if new.deleted_at is not null then return new; end if;
  select e.group_id into gid from public.events e join public.groups g on g.id=e.group_id
  where e.id=new.event_id and e.kind='group' and e.deleted_at is null and g.deleted_at is null;
  if gid is not null then
    perform private.enqueue_group_notification('group_comment',gid,new.event_id,null,new.author_user_id);
  end if;
  return new;
end;
$$;
revoke all on function private.notification_group_comment_outbox() from public,anon,authenticated,service_role;
create trigger notification_group_comment_created after insert on public.event_comments
for each row execute function private.notification_group_comment_outbox();

create or replace function public.register_notification_device(
  p_installation_id uuid, p_client_generation bigint, p_platform text,
  p_token text, p_app_version text default null, p_device_id text default null
) returns table(binding_generation bigint, accepted boolean)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare actor uuid:=auth.uid(); current private.notification_installation_bindings%rowtype;
  public_id uuid; token_hash text;
begin
  if actor is null then raise exception 'not authenticated' using errcode='42501'; end if;
  if p_installation_id is null or p_client_generation is null or p_client_generation<1 or
     p_platform not in ('ios','android') or length(coalesce(p_token,''))<20 or length(p_token)>8192 then
    raise exception 'invalid notification device' using errcode='22023';
  end if;
  token_hash:=encode(extensions.digest(p_token,'sha256'),'hex');
  perform pg_advisory_xact_lock(hashtextextended('notification-installation:'||p_installation_id::text,9121));
  select * into current from private.notification_installation_bindings b
    where b.installation_id=p_installation_id for update;
  if found and p_client_generation<=current.client_generation then
    return query select current.binding_generation,false; return;
  end if;
  if not private.notification_account_eligible(actor) then
    raise exception 'account unavailable' using errcode='42501';
  end if;
  if found then
    update public.device_tokens set revoked_at=clock_timestamp()
      where id=current.public_token_id and revoked_at is null;
  end if;
  insert into public.device_tokens(user_id,platform,token_hash,token_preview,created_at,last_seen_at,revoked_at)
    values(actor,p_platform,token_hash,right(p_token,4),clock_timestamp(),clock_timestamp(),null)
    on conflict on constraint device_tokens_user_id_token_hash_key do update set platform=excluded.platform,
      token_preview=excluded.token_preview,last_seen_at=clock_timestamp(),revoked_at=null
    returning id into public_id;
  insert into private.notification_installation_bindings(
    installation_id,user_id,client_generation,binding_generation,public_token_id,
    platform,token,app_version,device_id,enabled,updated_at
  ) values(p_installation_id,actor,p_client_generation,
    case when current.installation_id is null then 1 else current.binding_generation+1 end,
    public_id,p_platform,p_token,p_app_version,p_device_id,true,clock_timestamp())
  on conflict(installation_id) do update set user_id=excluded.user_id,
    client_generation=excluded.client_generation,binding_generation=excluded.binding_generation,
    public_token_id=excluded.public_token_id,platform=excluded.platform,token=excluded.token,
    app_version=excluded.app_version,device_id=excluded.device_id,enabled=true,updated_at=clock_timestamp()
  returning private.notification_installation_bindings.binding_generation into binding_generation;
  return query select binding_generation,true;
end;
$$;

create or replace function public.revoke_notification_device(
  p_installation_id uuid, p_client_generation bigint, p_binding_generation bigint
) returns boolean language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare actor uuid:=auth.uid(); current private.notification_installation_bindings%rowtype;
begin
  if actor is null then raise exception 'not authenticated' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('notification-installation:'||p_installation_id::text,9121));
  select * into current from private.notification_installation_bindings b
    where b.installation_id=p_installation_id for update;
  if not found or current.user_id<>actor or current.client_generation<>p_client_generation or
     current.binding_generation<>p_binding_generation then return false; end if;
  update private.notification_installation_bindings set enabled=false,
    client_generation=greatest(client_generation,p_client_generation),updated_at=clock_timestamp()
    where installation_id=p_installation_id;
  update public.device_tokens set revoked_at=clock_timestamp()
    where id=current.public_token_id and revoked_at is null;
  return true;
end;
$$;
revoke all on function public.register_notification_device(uuid,bigint,text,text,text,text) from public,anon;
revoke all on function public.revoke_notification_device(uuid,bigint,bigint) from public,anon;
grant execute on function public.register_notification_device(uuid,bigint,text,text,text,text) to authenticated;
grant execute on function public.revoke_notification_device(uuid,bigint,bigint) to authenticated;

drop function if exists public.list_server_notification_inbox(timestamptz,integer);
create or replace function public.list_server_notification_inbox(
  p_before timestamptz default null,p_limit integer default 30,p_before_id uuid default null
)
returns table(inbox_id uuid,notification_type text,group_id uuid,event_id uuid,
  invitation_id uuid,created_at timestamptz,read_at timestamptz)
language plpgsql stable security definer set search_path=pg_catalog,public,private as $$
declare actor uuid:=auth.uid();
begin
  if actor is null then raise exception 'not authenticated' using errcode='42501'; end if;
  if p_limit is null or p_limit<1 or p_limit>50 then raise exception 'invalid page size' using errcode='22023'; end if;
  if (p_before is null) <> (p_before_id is null) then
    raise exception 'incomplete notification cursor' using errcode='22023';
  end if;
  return query select i.id,i.notification_type,i.group_id,i.event_id,i.invitation_id,i.created_at,i.read_at
    from private.notification_inbox i
    where i.recipient_user_id=actor
      and (p_before is null or (i.created_at,i.id)<(p_before,p_before_id))
      and private.notification_inbox_allowed(
        i.notification_type,i.group_id,i.event_id,i.invitation_id,actor,i.actor_user_id)
    order by i.created_at desc,i.id desc limit p_limit;
end;
$$;

create or replace function public.mark_server_notification_read(p_inbox_id uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare actor uuid:=auth.uid(); n private.notification_inbox%rowtype;
begin
  if actor is null then raise exception 'not authenticated' using errcode='42501'; end if;
  select * into n from private.notification_inbox i where i.id=p_inbox_id
    and i.recipient_user_id=actor for update;
  if not found or not private.notification_inbox_allowed(
    n.notification_type,n.group_id,n.event_id,n.invitation_id,actor,n.actor_user_id) then return false; end if;
  update private.notification_inbox set read_at=coalesce(read_at,clock_timestamp()) where id=n.id;
  return true;
end;
$$;
revoke all on function public.list_server_notification_inbox(timestamptz,integer,uuid) from public,anon;
revoke all on function public.mark_server_notification_read(uuid) from public,anon;
grant execute on function public.list_server_notification_inbox(timestamptz,integer,uuid) to authenticated;
grant execute on function public.mark_server_notification_read(uuid) to authenticated;

create or replace function public.create_targeted_group_invitation(
  p_group_id uuid,p_invitee_user_id uuid,p_expires_at timestamptz
) returns table(invitation_id uuid,group_id uuid,invitee_user_id uuid,status text,expires_at timestamptz)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare actor uuid:=auth.uid(); invitation public.group_targeted_invitations%rowtype;
  inbox_key uuid;
begin
  if actor is null then raise exception 'not authenticated' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('group:'||p_group_id::text,9010));
  if not private.group_admin(p_group_id,actor) or p_invitee_user_id is null or p_invitee_user_id=actor
     or p_expires_at<=clock_timestamp() or p_expires_at>clock_timestamp()+interval '7 days'
     or not exists(select 1 from public.friendships f where f.status='accepted' and
       ((f.requester_user_id=actor and f.addressee_user_id=p_invitee_user_id) or
        (f.addressee_user_id=actor and f.requester_user_id=p_invitee_user_id)))
     or exists(select 1 from public.blocks b where
       (b.blocker_user_id=actor and b.blocked_user_id=p_invitee_user_id) or
       (b.blocker_user_id=p_invitee_user_id and b.blocked_user_id=actor))
     or exists(select 1 from public.group_members m where m.group_id=p_group_id and m.user_id=p_invitee_user_id)
     or not private.notification_account_eligible(p_invitee_user_id)
     or not exists(select 1 from public.groups g where g.id=p_group_id and g.deleted_at is null) then
    raise exception 'invitation unavailable' using errcode='42501';
  end if;
  update public.group_targeted_invitations ti set status='expired',responded_at=clock_timestamp()
    where ti.group_id=p_group_id and ti.invitee_user_id=p_invitee_user_id
      and ti.status='pending' and ti.expires_at<=clock_timestamp();
  select * into invitation from public.group_targeted_invitations ti
    where ti.group_id=p_group_id and ti.invitee_user_id=p_invitee_user_id and ti.status='pending'
    order by ti.created_at desc limit 1 for update;
  if found then raise exception 'invitation already pending' using errcode='PT409'; end if;
  insert into public.group_targeted_invitations(group_id,inviter_user_id,invitee_user_id,expires_at)
    values(p_group_id,actor,p_invitee_user_id,p_expires_at) returning * into invitation;
  if coalesce((select n.group_updates_enabled from public.notification_settings n where n.user_id=p_invitee_user_id),true)
     and not exists(select 1 from public.blocks b where
       (b.blocker_user_id=actor and b.blocked_user_id=p_invitee_user_id) or
       (b.blocker_user_id=p_invitee_user_id and b.blocked_user_id=actor)) then
    insert into private.notification_inbox(recipient_user_id,actor_user_id,notification_type,group_id,invitation_id)
      values(p_invitee_user_id,actor,'group_invitation',p_group_id,invitation.id) returning id into inbox_key;
    insert into private.notification_outbox(inbox_id,recipient_user_id)
      values(inbox_key,p_invitee_user_id);
  end if;
  return query select invitation.id,invitation.group_id,invitation.invitee_user_id,invitation.status,invitation.expires_at;
end;
$$;

create or replace function public.list_my_targeted_group_invitations()
returns table(invitation_id uuid,group_id uuid,group_name text,inviter_user_id uuid,
  inviter_display_name text,created_at timestamptz,expires_at timestamptz,status text)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare actor uuid:=auth.uid();
begin
  if actor is null then raise exception 'not authenticated' using errcode='42501'; end if;
  update public.group_targeted_invitations ti set status='expired',responded_at=clock_timestamp()
    where ti.invitee_user_id=actor and ti.status='pending' and ti.expires_at<=clock_timestamp();
  return query select ti.id,ti.group_id,g.name,ti.inviter_user_id,p.display_name,
      ti.created_at,ti.expires_at,ti.status
    from public.group_targeted_invitations ti join public.groups g on g.id=ti.group_id and g.deleted_at is null
    join public.profiles p on p.user_id=ti.inviter_user_id and p.deleted_at is null
    where ti.invitee_user_id=actor and ti.status='pending' and ti.expires_at>clock_timestamp()
      and private.notification_account_eligible(actor)
      and not exists(select 1 from public.blocks b where
        (b.blocker_user_id=actor and b.blocked_user_id=ti.inviter_user_id) or
        (b.blocker_user_id=ti.inviter_user_id and b.blocked_user_id=actor))
    order by ti.created_at desc,ti.id desc limit 50;
end;
$$;

create or replace function public.respond_targeted_group_invitation(p_invitation_id uuid,p_accept boolean)
returns table(invitation_id uuid,group_id uuid,status text)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare actor uuid:=auth.uid(); invitation public.group_targeted_invitations%rowtype;
begin
  if actor is null then raise exception 'not authenticated' using errcode='42501'; end if;
  select * into invitation from public.group_targeted_invitations ti
    where ti.id=p_invitation_id and ti.invitee_user_id=actor;
  if not found then raise exception 'invitation unavailable' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('group:'||invitation.group_id::text,9010));
  select * into invitation from public.group_targeted_invitations ti
    where ti.id=p_invitation_id and ti.invitee_user_id=actor for update;
  if found and invitation.status=(case when p_accept then 'accepted' else 'declined' end) then
    return query select invitation.id,invitation.group_id,invitation.status; return;
  end if;
  if not found or invitation.status<>'pending' or invitation.expires_at<=clock_timestamp()
     or not exists(select 1 from public.groups g where g.id=invitation.group_id and g.deleted_at is null)
     or not private.notification_inbox_allowed('group_invitation',invitation.group_id,null,
       invitation.id,actor,invitation.inviter_user_id) then
    raise exception 'invitation unavailable' using errcode='42501';
  end if;
  if p_accept then
    if exists(select 1 from public.group_members m where m.group_id=invitation.group_id and m.user_id=actor) then
      raise exception 'membership already exists' using errcode='PT409';
    end if;
    insert into public.group_members(group_id,user_id,role) values(invitation.group_id,actor,'member');
  end if;
  update public.group_targeted_invitations set status=case when p_accept then 'accepted' else 'declined' end,
    responded_at=clock_timestamp() where id=invitation.id returning * into invitation;
  return query select invitation.id,invitation.group_id,invitation.status;
end;
$$;

create or replace function public.revoke_targeted_group_invitation(p_invitation_id uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,private as $$
declare actor uuid:=auth.uid(); invitation public.group_targeted_invitations%rowtype;
begin
  if actor is null then raise exception 'not authenticated' using errcode='42501'; end if;
  select * into invitation from public.group_targeted_invitations ti where ti.id=p_invitation_id;
  if not found then raise exception 'invitation unavailable' using errcode='42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended('group:'||invitation.group_id::text,9010));
  select * into invitation from public.group_targeted_invitations ti where ti.id=p_invitation_id for update;
  if not found or (invitation.inviter_user_id<>actor and not private.group_admin(invitation.group_id,actor)) then
    raise exception 'invitation unavailable' using errcode='42501';
  end if;
  if invitation.status<>'pending' then return false; end if;
  update public.group_targeted_invitations set status='revoked',responded_at=clock_timestamp() where id=invitation.id;
  return true;
end;
$$;
revoke all on function public.create_targeted_group_invitation(uuid,uuid,timestamptz) from public,anon;
revoke all on function public.list_my_targeted_group_invitations() from public,anon;
revoke all on function public.respond_targeted_group_invitation(uuid,boolean) from public,anon;
revoke all on function public.revoke_targeted_group_invitation(uuid) from public,anon;
grant execute on function public.create_targeted_group_invitation(uuid,uuid,timestamptz) to authenticated;
grant execute on function public.list_my_targeted_group_invitations() to authenticated;
grant execute on function public.respond_targeted_group_invitation(uuid,boolean) to authenticated;
grant execute on function public.revoke_targeted_group_invitation(uuid) to authenticated;

-- The Edge dispatcher can atomically claim a bounded batch. Its response
-- includes the private token only to the service role; payload content stays
-- generic and contains only the opaque inbox id.
create or replace function public.claim_notification_outbox(p_limit integer default 20,p_lease_seconds integer default 60)
returns table(outbox_id uuid,delivery_id uuid,lease_id uuid,inbox_id uuid,recipient_user_id uuid,
  installation_id uuid,binding_generation bigint,token text,notification_type text)
language plpgsql security definer set search_path=pg_catalog,public,private as $$
begin
  if auth.role() is distinct from 'service_role' or p_limit is null or p_limit<1 or p_limit>50
     or p_lease_seconds is null or p_lease_seconds<15 or p_lease_seconds>300 then
    raise exception 'dispatcher access denied' using errcode='42501';
  end if;
  insert into private.notification_delivery_attempts(outbox_id,installation_id,binding_generation)
  select o.id,b.installation_id,b.binding_generation
  from private.notification_outbox o join private.notification_inbox i on i.id=o.inbox_id
    join private.notification_installation_bindings b on b.user_id=o.recipient_user_id and b.enabled
  where o.status in ('pending','leased') and o.available_at<=clock_timestamp()
    and private.notification_delivery_allowed(
      i.notification_type,i.group_id,i.event_id,i.invitation_id,o.recipient_user_id,i.actor_user_id)
  on conflict on constraint notification_delivery_attempt_outbox_id_installation_id_bin_key do nothing;
  update private.notification_delivery_attempts d set status='permanent_failure',
    lease_id=null,lease_expires_at=null,last_error='recipient_or_binding_unavailable'
  from private.notification_outbox o join private.notification_inbox i on i.id=o.inbox_id
  where d.outbox_id=o.id and d.status in ('pending','leased')
    and (not exists(select 1 from private.notification_installation_bindings b
        where b.installation_id=d.installation_id and b.user_id=o.recipient_user_id
          and b.binding_generation=d.binding_generation and b.enabled)
      or not private.notification_delivery_allowed(
        i.notification_type,i.group_id,i.event_id,i.invitation_id,o.recipient_user_id,i.actor_user_id));
  update private.notification_outbox o set status=case
    when exists(select 1 from private.notification_delivery_attempts d
      where d.outbox_id=o.id and d.status in ('pending','leased')) then 'leased'
    when exists(select 1 from private.notification_delivery_attempts d
      where d.outbox_id=o.id and d.status='permanent_failure') then 'permanent_failure'
    else 'sent' end
  where exists(select 1 from private.notification_delivery_attempts d
    where d.outbox_id=o.id and d.status='permanent_failure');
  return query with claimed as (
    select d.id from private.notification_delivery_attempts d
    join private.notification_outbox o on o.id=d.outbox_id
    join private.notification_installation_bindings b on b.installation_id=d.installation_id
      and b.user_id=o.recipient_user_id and b.binding_generation=d.binding_generation and b.enabled
    join private.notification_inbox i on i.id=o.inbox_id
    where d.status in ('pending','leased') and d.available_at<=clock_timestamp()
      and (d.status='pending' or d.lease_expires_at<=clock_timestamp())
      and o.status in ('pending','leased')
      and private.notification_delivery_allowed(
        i.notification_type,i.group_id,i.event_id,i.invitation_id,o.recipient_user_id,i.actor_user_id)
    order by d.available_at,d.id limit p_limit for update of d,b skip locked
  ), leased as (
    update private.notification_delivery_attempts d set status='leased',attempts=d.attempts+1,
      lease_id=gen_random_uuid(),lease_expires_at=clock_timestamp()+make_interval(secs=>p_lease_seconds)
    from claimed c where d.id=c.id returning d.*
  )
  select l.outbox_id,l.id,l.lease_id,o.inbox_id,o.recipient_user_id,b.installation_id,
      b.binding_generation,b.token,i.notification_type
  from leased l join private.notification_outbox o on o.id=l.outbox_id
  join private.notification_inbox i on i.id=o.inbox_id
  join private.notification_installation_bindings b on b.installation_id=l.installation_id
    and b.binding_generation=l.binding_generation and b.enabled
  where private.notification_account_eligible(o.recipient_user_id);
end;
$$;

create or replace function public.finish_notification_delivery(
  p_outbox_id uuid,p_delivery_id uuid,p_lease_id uuid,p_installation_id uuid,p_binding_generation bigint,
  p_outcome text,p_provider_message_id text default null,p_retry_seconds integer default null,p_error text default null
) returns boolean language plpgsql security definer set search_path=pg_catalog,public,private as $$
begin
  if auth.role() is distinct from 'service_role' or p_outcome is null
     or p_outcome not in ('sent','retry','permanent','invalid_token') then
    raise exception 'dispatcher access denied' using errcode='42501';
  end if;
  update private.notification_delivery_attempts d set
    status=case when p_outcome='sent' then 'sent'
      when p_outcome='permanent' or p_outcome='invalid_token' or d.attempts>=12 then 'permanent_failure'
      else 'pending' end,
    provider_message_id=case when p_outcome='sent' then p_provider_message_id else provider_message_id end,
    available_at=case when p_outcome='retry' then clock_timestamp()+make_interval(secs=>greatest(5,least(coalesce(p_retry_seconds,60),3600))) else available_at end,
    lease_id=null,lease_expires_at=null,last_error=left(coalesce(p_error,''),300)
  where d.id=p_delivery_id and d.outbox_id=p_outbox_id and d.status='leased' and d.lease_id=p_lease_id
    and d.installation_id=p_installation_id and d.binding_generation=p_binding_generation;
  if not found then return false; end if;
  if p_outcome='invalid_token' then
    update private.notification_installation_bindings b set enabled=false,updated_at=clock_timestamp()
    where b.installation_id=p_installation_id and b.binding_generation=p_binding_generation;
    update public.device_tokens t set revoked_at=clock_timestamp()
      where t.id=(select b.public_token_id from private.notification_installation_bindings b
        where b.installation_id=p_installation_id and b.binding_generation=p_binding_generation)
        and t.revoked_at is null;
  end if;
  update private.notification_outbox o set
    status=case when exists(select 1 from private.notification_delivery_attempts d
      where d.outbox_id=o.id and d.status in ('pending','leased')) then 'leased'
      when exists(select 1 from private.notification_delivery_attempts d
        where d.outbox_id=o.id and d.status='permanent_failure') then 'permanent_failure'
      else 'sent' end,
    attempts=o.attempts+1,lease_id=null,lease_expires_at=null,
    available_at=case when exists(select 1 from private.notification_delivery_attempts d
      where d.outbox_id=o.id and d.status='pending') then
        (select min(d.available_at) from private.notification_delivery_attempts d where d.outbox_id=o.id and d.status='pending')
      else o.available_at end
  where o.id=p_outbox_id;
  return true;
end;
$$;
revoke all on function public.claim_notification_outbox(integer,integer) from public,anon,authenticated;
revoke all on function public.finish_notification_delivery(uuid,uuid,uuid,uuid,bigint,text,text,integer,text) from public,anon,authenticated;
grant execute on function public.claim_notification_outbox(integer,integer) to service_role;
grant execute on function public.finish_notification_delivery(uuid,uuid,uuid,uuid,bigint,text,text,integer,text) to service_role;

commit;
