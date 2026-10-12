-- Forward-only repair authorized for fresh disposable CI validation.
-- Restore Phase15 hide/audit/conflict contract while preserving safety actions and authorization.
begin;

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
  if not found then raise exception 'report unavailable' using errcode='42501'; end if;
  if q.status<>'pending' then raise exception 'report already resolved' using errcode='PT409'; end if;
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
      previous_state:=case when e.deleted_at is not null then 'deleted'
        when e.moderation_hidden_at is not null then 'hidden' else 'visible' end;
    elsif q.target_type='comment' then
      previous_state:=case when c.deleted_at is not null then 'deleted'
        when c.moderation_hidden_at is not null then 'hidden' else 'visible' end;
    end if;
    if q.target_type='event' then
      if e.deleted_at is not null then state:='already_deleted';
      elsif e.moderation_hidden_at is null then
        update public.events set moderation_hidden_at=clock_timestamp(),moderation_hidden_by=a,
          updated_at=clock_timestamp(),version=version+1 where id=q.target_id;
        state:='transitioned_hidden'; else state:='already_hidden'; end if;
    elsif q.target_type='comment' then
      if c.deleted_at is not null then state:='already_deleted';
      elsif c.moderation_hidden_at is null then
        update public.event_comments set moderation_hidden_at=clock_timestamp(),moderation_hidden_by=a,
          updated_at=clock_timestamp(),version=version+1 where id=q.target_id;
        state:='transitioned_hidden'; else state:='already_hidden'; end if;
    else raise exception 'unsupported hide target' using errcode='22023'; end if;
  else state:='unchanged'; end if;

  update public.reports set status=case when p_action='dismiss' then 'dismissed' else 'actioned' end,
    resolved_by=a,resolved_at=clock_timestamp(),decision_reason=trim(p_reason),target_state=state where id=q.id;
  insert into public.audit_logs(actor_user_id,action,target_type,target_id,metadata)
    values(a,'moderation_'||p_action,q.target_type,q.target_id,
      jsonb_build_object('report_id',q.id,'reason',trim(p_reason),'previous_status',q.status,
        'target_state',state,'target_user_id',target_user,'target_group_id',target_group,
        'previous_target_state',previous_state,'new_target_state',state,
        'new_status',case when p_action='dismiss' then 'dismissed' else 'actioned' end)) returning id into aid;
  r:=jsonb_build_object('report_id',q.id,'status',case when p_action='dismiss' then 'dismissed' else 'actioned' end,
    'action',p_action,'target_state',state,'audit_id',aid,'previous_target_state',previous_state);
  perform private.admin_record(a,p_operation_id,'admin_resolve_report',h,r);
  return query select q.id,r->>'status',p_action,state,aid,previous_state;
end;
$$;
revoke all on function public.admin_resolve_report(uuid,text,text,uuid) from public,anon,service_role;
grant execute on function public.admin_resolve_report(uuid,text,text,uuid) to authenticated;

notify pgrst, 'reload schema';
commit;
