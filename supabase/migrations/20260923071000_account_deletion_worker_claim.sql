-- Give the Edge worker a narrow lookup path without exposing the durable
-- operation table or its Storage manifest to clients.
begin;

create or replace function public.get_account_deletion_worker_context(p_operation_id uuid)
returns table(user_id uuid,phase text)
language sql stable security definer
set search_path=pg_catalog,private as $$
  select o.user_id,o.phase
  from private.account_deletion_operations o
  where o.operation_id=p_operation_id
$$;
revoke all on function public.get_account_deletion_worker_context(uuid)
  from public,anon,authenticated;
grant execute on function public.get_account_deletion_worker_context(uuid) to service_role;

commit;
