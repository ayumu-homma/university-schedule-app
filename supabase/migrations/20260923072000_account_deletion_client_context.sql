-- Expose only the authenticated owner's non-secret recovery context so a
-- restarted client can finish account-scoped local cache cleanup safely.
begin;

create or replace function public.get_my_account_deletion_context()
returns table(operation_id uuid,phase text,group_actions jsonb)
language sql stable security definer
set search_path=pg_catalog,auth,private as $$
  select o.operation_id,o.phase,o.group_actions
  from private.account_deletion_operations o
  where o.user_id=auth.uid()
  order by o.requested_at desc
  limit 1
$$;
revoke all on function public.get_my_account_deletion_context() from public,anon,service_role;
grant execute on function public.get_my_account_deletion_context() to authenticated;

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
      '/rpc/request_account_deletion','/rpc/get_my_account_deletion_status',
      '/rpc/get_my_account_deletion_context') then return; end if;
  raise exception 'account access restricted' using errcode='42501';
end;
$$;
revoke all on function private.safety_pre_request() from public,anon,authenticated,service_role;
grant execute on function private.safety_pre_request() to authenticator;
notify pgrst,'reload config';

commit;
