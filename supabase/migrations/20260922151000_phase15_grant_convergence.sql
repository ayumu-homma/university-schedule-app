-- Make the Phase 15 RPC execute surface deterministic across local Supabase
-- bootstrap versions. The admin UI uses authenticated JWTs; service_role has
-- no reason to invoke these browser/mobile RPCs directly.
begin;

revoke execute on function public.admin_list_pending_reports(integer,integer) from service_role;
revoke execute on function public.admin_get_report(uuid) from service_role;
revoke execute on function public.admin_resolve_report(uuid,text,text,uuid) from service_role;
revoke execute on function public.admin_list_audit_logs(integer,integer) from service_role;
revoke execute on function public.list_group_events(uuid) from service_role;
revoke execute on function public.get_group_event(uuid) from service_role;
revoke execute on function public.list_group_event_rsvps(uuid) from service_role;
revoke execute on function public.get_group_event_ugc(uuid) from service_role;
revoke execute on function public.validate_group_event_ugc(uuid,text) from service_role;
revoke execute on function public.list_group_event_comments(uuid) from service_role;
revoke execute on function public.set_group_event_rsvp(uuid,text,uuid) from service_role;
revoke execute on function public.create_group_event(uuid,text,timestamptz,timestamptz,text,text,uuid) from service_role;
revoke execute on function public.update_group_event(uuid,text,timestamptz,timestamptz,text,text,bigint,uuid) from service_role;
revoke execute on function public.find_group_availability(uuid,uuid[],timestamptz,timestamptz,integer) from service_role;
revoke execute on function public.validate_group_availability(uuid,uuid[],text) from service_role;

commit;
