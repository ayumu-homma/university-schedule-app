-- Catalog-only checks after the fresh GitHub-hosted migration chain.
-- Never call the deletion worker or read application/user records here.
begin read only;

do $$
declare
  hook oid := 'private.safety_pre_request()'::regprocedure;
  worker oid := 'public.prepare_account_deletion_database(uuid)'::regprocedure;
  api_role text;
  target_table text;
  operation text;
begin
  if current_user <> 'postgres' then
    raise exception 'Unexpected CI inspection principal';
  end if;
  if (select pg_get_userbyid(nspowner) <> 'postgres'
      from pg_namespace where nspname = 'private') then
    raise exception 'Unexpected private schema owner';
  end if;
  if exists (select 1 from pg_proc where oid in (hook, worker)
             and (pg_get_userbyid(proowner) <> 'postgres' or not prosecdef)) then
    raise exception 'Unexpected privileged function owner or security mode';
  end if;
  if not exists (select 1 from pg_proc where oid = hook
      and 'search_path=pg_catalog, public, private, auth' = any(proconfig))
     or not exists (select 1 from pg_proc where oid = worker
      and 'search_path=pg_catalog, public, private, auth, storage' = any(proconfig)) then
    raise exception 'Unexpected privileged function search path';
  end if;
  if exists (select 1 from pg_proc p,
      lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
      where p.oid in (hook, worker) and a.grantee = 0
        and a.privilege_type = 'EXECUTE') then
    raise exception 'PUBLIC must not execute privileged functions';
  end if;
  foreach api_role in array array['anon', 'authenticated', 'service_role'] loop
    if not has_schema_privilege(api_role, 'private', 'USAGE')
       or has_schema_privilege(api_role, 'private', 'CREATE')
       or not has_function_privilege(api_role, hook, 'EXECUTE') then
      raise exception 'Unexpected API hook privileges';
    end if;
    if has_function_privilege(api_role, worker, 'EXECUTE')
       is distinct from (api_role = 'service_role') then
      raise exception 'Deletion worker must remain service-only';
    end if;
  end loop;
  if not has_function_privilege('authenticator', hook, 'EXECUTE') then
    raise exception 'Authenticator must retain hook execution';
  end if;
  foreach api_role in array array['anon', 'authenticated'] loop
    foreach target_table in array array[
      'private.account_deletion_operations', 'private.user_safety_state'
    ] loop
      foreach operation in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE'] loop
        if has_table_privilege(api_role, target_table, operation) then
          raise exception 'Client role must not access private safety tables directly';
        end if;
      end loop;
    end loop;
  end loop;
end;
$$;

select current_user as inspection_role,
  p.oid::regprocedure as checked_function,
  pg_get_userbyid(p.proowner) as function_owner
from pg_proc p
where p.oid in ('private.safety_pre_request()'::regprocedure,
  'public.prepare_account_deletion_database(uuid)'::regprocedure)
order by p.oid::regprocedure::text;
select 'migration ownership and execution privileges: PASS' as result;
rollback;
