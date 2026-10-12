-- PostgREST switches to the JWT-selected API role before invoking the
-- db_pre_request hook. Keep this function server-internal by leaving `private`
-- outside exposed PostgREST schemas, while allowing every configured API role
-- to execute the hook in its transaction.
begin;

grant usage on schema private to anon,authenticated,service_role;
grant execute on function private.safety_pre_request() to anon,authenticated,service_role;
notify pgrst,'reload config';

commit;
