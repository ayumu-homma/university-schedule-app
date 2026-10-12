begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(37);

select extensions.ok(to_regprocedure('public.get_my_safety_state()') is not null,'self safety state RPC exists');
select extensions.ok(to_regprocedure('public.list_my_safety_notices(integer)') is not null,'self notices RPC exists');
select extensions.ok(to_regprocedure('public.admin_set_safety_state(text,uuid,boolean,bigint,text,uuid)') is not null,'versioned suspend/restore RPC exists');
select extensions.ok((select prosecdef from pg_proc where oid='public.admin_set_safety_state(text,uuid,boolean,bigint,text,uuid)'::regprocedure),'suspend/restore runs as definer');
select extensions.ok(not has_table_privilege('authenticated','private.user_safety_state','SELECT'),'users cannot read safety state table');
select extensions.ok(not has_table_privilege('authenticated','private.user_safety_notices','SELECT'),'users cannot read notice table');
select extensions.ok(not has_function_privilege('service_role','public.get_my_safety_state()','EXECUTE')
  and not has_function_privilege('service_role','public.list_my_safety_notices(integer)','EXECUTE')
  and not has_function_privilege('service_role','public.acknowledge_safety_notice(uuid)','EXECUTE'),
  'trusted service role has no self-service safety RPC grants');
select extensions.ok(not has_function_privilege('service_role','public.admin_resolve_report(uuid,text,text,uuid)','EXECUTE')
  and not has_function_privilege('service_role','public.admin_set_safety_state(text,uuid,boolean,bigint,text,uuid)','EXECUTE')
  and not has_function_privilege('service_role','public.admin_list_suspended_targets(text,integer,integer)','EXECUTE'),
  'trusted service role has no user-facing admin mutation or list grants');
select extensions.ok(has_function_privilege('authenticator','private.safety_pre_request()','EXECUTE'),'PostgREST authenticator can run the safety gate');
select extensions.ok(exists(select 1 from pg_db_role_setting s join pg_roles r on r.oid=s.setrole
  join pg_database d on d.oid=s.setdatabase where r.rolname='authenticator'
    and d.datname=current_database() and s.setconfig @> array['pgrst.db_pre_request=private.safety_pre_request']),
  'safety gate is configured for this database Data API only');
select extensions.ok(exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='safety_actor_gate' and permissive='RESTRICTIVE'),'storage has the suspended-actor restrictive policy');
select extensions.ok(exists(select 1 from pg_policies where schemaname='public' and tablename='profiles' and policyname='safety_actor_gate' and permissive='RESTRICTIVE'),'direct table reads have the suspended-actor restrictive policy');

insert into auth.users(id) values
 ('f6011111-1111-4111-8111-111111111111'),
 ('f6022222-2222-4222-8222-222222222222'),
 ('f6033333-3333-4333-8333-333333333333') on conflict(id) do nothing;
insert into public.profiles(user_id,display_name) values
 ('f6011111-1111-4111-8111-111111111111','Safety admin'),
 ('f6022222-2222-4222-8222-222222222222','Safety target'),
 ('f6033333-3333-4333-8333-333333333333','Safety group owner') on conflict(user_id) do update set display_name=excluded.display_name;
insert into private.global_admins(user_id) values('f6011111-1111-4111-8111-111111111111')
 on conflict(user_id) do update set revoked_at=null;
insert into public.groups(id,owner_user_id,name,type,event_create_policy) values
 ('f6044444-4444-4444-8444-444444444444','f6033333-3333-4333-8333-333333333333','Safety synthetic','other','member')
 on conflict(id) do nothing;
insert into public.group_members(group_id,user_id,role) values
 ('f6044444-4444-4444-8444-444444444444','f6033333-3333-4333-8333-333333333333','owner') on conflict do nothing;
insert into public.reports(id,reporter_user_id,target_type,target_id,reason) values
 ('f6055555-5555-4555-8555-555555555555','f6033333-3333-4333-8333-333333333333','user','f6022222-2222-4222-8222-222222222222','synthetic warning'),
 ('f6066666-6666-4666-8666-666666666666','f6033333-3333-4333-8333-333333333333','group','f6044444-4444-4444-8444-444444444444','synthetic group report');

set local request.jwt.claim.sub='f6011111-1111-4111-8111-111111111111';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is((select status from public.admin_resolve_report('f6055555-5555-4555-8555-555555555555','warn_user','warning for test','f6077777-7777-4777-8777-777777777777')),'actioned','admin warning resolves a report');
select extensions.is((select target_context->>'display_name' from public.admin_get_report('f6055555-5555-4555-8555-555555555555')),'Safety target','admin review resolves user target identity server-side');
select extensions.is((select target_context->>'name' from public.admin_get_report('f6066666-6666-4666-8666-666666666666')),'Safety synthetic','admin review shows group identity before confirmation');
select extensions.is((select count(*) from public.admin_list_audit_logs(50,0) where action='moderation_warn_user' and target_id='f6022222-2222-4222-8222-222222222222'),1::bigint,'warning is durably audited');
set local request.jwt.claim.sub='f6022222-2222-4222-8222-222222222222';
select extensions.is((select count(*) from public.list_my_safety_notices(50)),1::bigint,'only the recipient sees their warning notice');
select extensions.is((select status from public.get_my_safety_state()),'active','warning does not suspend the account');
select extensions.ok(public.acknowledge_safety_notice((select notice_id from public.list_my_safety_notices(50) limit 1)),'recipient can acknowledge their notice');

set local request.jwt.claim.sub='f6011111-1111-4111-8111-111111111111';
select extensions.is((select status from public.admin_set_safety_state('user','f6022222-2222-4222-8222-222222222222',false,0,'suspension for test','f6088888-8888-4888-8888-888888888888')),'suspended','admin suspends active user with version check');
select extensions.is((select display_name from public.admin_list_suspended_targets('user',50,0) where target_id='f6022222-2222-4222-8222-222222222222'),'Safety target','admin can identify a suspended account for restoration');
set local request.jwt.claim.sub='f6022222-2222-4222-8222-222222222222';
select extensions.is((select status from public.get_my_safety_state()),'suspended','suspended user can read their own restriction state');
set local request.path='/rest/v1/profiles';
reset role;
select extensions.throws_ok($q$select private.safety_pre_request()$q$,'42501',NULL,'suspended actor is rejected at the Data API request gate');
set local role authenticated;
set local request.path='/rpc/list_my_safety_notices';
reset role;
select extensions.lives_ok($q$select private.safety_pre_request()$q$,'suspended actor may reach notice recovery RPC');
set local role authenticated;
select extensions.is((select count(*) from public.profiles),0::bigint,'restrictive RLS hides direct rows from suspended actor');

set local request.jwt.claim.sub='f6011111-1111-4111-8111-111111111111';
select extensions.is((select version from public.admin_set_safety_state('user','f6022222-2222-4222-8222-222222222222',true,1,'restore for test','f6099999-9999-4999-8999-999999999999')),'2'::bigint,'admin restores user with compare-and-swap version');
set local request.jwt.claim.sub='f6022222-2222-4222-8222-222222222222';
select extensions.is((select status from public.get_my_safety_state()),'active','restored user returns to active state');
set local request.jwt.claim.sub='f6011111-1111-4111-8111-111111111111';
select extensions.is((select status from public.admin_set_safety_state('group','f6044444-4444-4444-8444-444444444444',false,0,'group suspension for test','f60a1111-1111-4111-8111-111111111111')),'suspended','admin suspends a group with version check');
select extensions.is((select display_name from public.admin_list_suspended_targets('group',50,0) where target_id='f6044444-4444-4444-8444-444444444444'),'Safety synthetic','admin can identify a suspended group for restoration');
reset role;
select extensions.ok(not private.safety_group_active('f6044444-4444-4444-8444-444444444444'),'suspended group is not active');
set local role authenticated;
select extensions.is((select version from public.admin_set_safety_state('group','f6044444-4444-4444-8444-444444444444',true,1,'group restore for test','f60b1111-1111-4111-8111-111111111111')),'2'::bigint,'admin restores group with compare-and-swap version');
reset role;
select extensions.ok(private.safety_group_active('f6044444-4444-4444-8444-444444444444'),'restored group is active');
set local role authenticated;
select extensions.throws_ok($q$select * from public.admin_set_safety_state('group','f6044444-4444-4444-8444-444444444444',false,0,'stale replay','f60c1111-1111-4111-8111-111111111111')$q$,'40001','safety state changed','stale version cannot overwrite newer moderation state');
select extensions.is((select count(*) from public.admin_list_audit_logs(50,0) where action in ('safety_suspend','safety_restore')),4::bigint,'every suspend and restore has an audit row');

reset role;
select extensions.ok(not has_function_privilege('anon','public.admin_set_safety_state(text,uuid,boolean,bigint,text,uuid)','EXECUTE'),'anonymous cannot suspend or restore accounts');
select extensions.ok(not has_function_privilege('anon','public.admin_list_suspended_targets(text,integer,integer)','EXECUTE'),'anonymous cannot enumerate suspended accounts or groups');
select extensions.ok(has_function_privilege('authenticated','public.admin_list_suspended_targets(text,integer,integer)','EXECUTE'),'authenticated role can call the global-admin gated restoration list');
select * from extensions.finish();
rollback;
