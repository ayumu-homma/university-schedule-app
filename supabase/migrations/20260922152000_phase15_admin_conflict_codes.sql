-- Return deterministic HTTP 409 responses for moderation replay/conflict
-- decisions. SQLSTATE 40001 can be retried by API/database middleware and is
-- inappropriate for an intentional business conflict.
begin;

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
    raise exception 'operation replay mismatch' using errcode='PT409';
  end if;
  return r;
end; $$;

create or replace function public.admin_resolve_report(p_report_id uuid,p_action text,p_reason text,p_operation_id uuid)
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
  if q.status<>'pending' then raise exception 'report already resolved' using errcode='PT409'; end if;
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

revoke all on function private.admin_lock(uuid,uuid,text,text) from public,anon,authenticated,service_role;
revoke all on function public.admin_resolve_report(uuid,text,text,uuid) from public,anon,service_role;
grant execute on function public.admin_resolve_report(uuid,text,text,uuid) to authenticated;

commit;
