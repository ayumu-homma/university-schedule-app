begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(52);

select extensions.ok(to_regprocedure('public.get_my_account_deletion_preflight()') is not null,'account deletion preflight exists');
select extensions.ok(to_regprocedure('public.request_account_deletion(uuid,jsonb)') is not null,'durable account deletion request exists');
select extensions.ok(to_regprocedure('public.get_my_account_deletion_status()') is not null,'self deletion status exists');
select extensions.ok(not has_function_privilege('anon','public.request_account_deletion(uuid,jsonb)','EXECUTE'),'anonymous cannot request account deletion');
select extensions.ok(not has_function_privilege('service_role','public.request_account_deletion(uuid,jsonb)','EXECUTE'),'service role cannot initiate self-service deletion');
select extensions.ok(has_function_privilege('service_role','public.prepare_account_deletion_database(uuid)','EXECUTE'),'private worker can prepare relational cleanup');
select extensions.ok(not has_function_privilege('authenticated','public.prepare_account_deletion_database(uuid)','EXECUTE'),'client cannot run privileged database cleanup');
select extensions.ok(has_function_privilege('service_role','public.mark_account_deletion_objects_removed(uuid)','EXECUTE'),'worker can advance after Storage confirmation');
select extensions.ok(has_function_privilege('service_role','public.finish_account_deletion(uuid)','EXECUTE'),'worker can finish after Auth confirmation');
select extensions.ok(not has_table_privilege('authenticated','private.account_deletion_operations','SELECT'),'client cannot inspect operation or Storage manifest table');
select extensions.ok(not has_table_privilege('service_role','private.account_deletion_operations','SELECT'),'worker reads operations only through fixed RPCs');
select extensions.ok(to_regprocedure('public.get_account_deletion_worker_context(uuid)') is not null,
  'worker has a scoped operation lookup');
select extensions.ok(has_function_privilege('service_role','public.get_account_deletion_worker_context(uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.get_account_deletion_worker_context(uuid)','EXECUTE'),
  'only the service worker can look up operation ownership');
select extensions.ok(to_regprocedure('public.get_my_account_deletion_context()') is not null,
  'owner recovery context exists for account-scoped local cleanup');
select extensions.ok(has_function_privilege('authenticated','public.get_my_account_deletion_context()','EXECUTE')
  and not has_function_privilege('anon','public.get_my_account_deletion_context()','EXECUTE')
  and not has_function_privilege('service_role','public.get_my_account_deletion_context()','EXECUTE'),
  'deletion choices are visible only to their authenticated owner');
select extensions.ok(has_function_privilege('authenticator','private.safety_pre_request()','EXECUTE')
  and has_schema_privilege('anon','private','USAGE')
  and has_schema_privilege('authenticated','private','USAGE')
  and has_schema_privilege('service_role','private','USAGE')
  and has_function_privilege('anon','private.safety_pre_request()','EXECUTE')
  and has_function_privilege('authenticated','private.safety_pre_request()','EXECUTE')
  and has_function_privilege('service_role','private.safety_pre_request()','EXECUTE'),
  'PostgREST API roles can execute the unexposed pre-request safety hook');
select extensions.ok(position('sessions' in pg_get_functiondef(to_regprocedure('public.prepare_account_deletion_database(uuid)'))) > 0
  and position('refresh_tokens' in pg_get_functiondef(to_regprocedure('public.prepare_account_deletion_database(uuid)'))) > 0,
  'Auth sessions remain retryable until Auth Admin deletion');
select extensions.ok(exists(select 1 from pg_constraint where conrelid='public.event_comments'::regclass
  and conname='event_comments_author_user_id_fkey' and confdeltype='n'),'shared comment attribution uses ON DELETE SET NULL');

insert into auth.users(id) values
 ('f7011111-1111-4111-8111-111111111111'),
 ('f7022222-2222-4222-8222-222222222222'),
 ('f7033333-3333-4333-8333-333333333333') on conflict(id) do nothing;
insert into public.profiles(user_id,display_name) values
 ('f7011111-1111-4111-8111-111111111111','Delete owner'),
 ('f7022222-2222-4222-8222-222222222222','Transfer successor'),
 ('f7033333-3333-4333-8333-333333333333','Disband member')
 on conflict(user_id) do update set display_name=excluded.display_name;
insert into public.groups(id,owner_user_id,name,type,event_create_policy) values
 ('f7111111-1111-4111-8111-111111111111','f7011111-1111-4111-8111-111111111111','Transfer group','other','member'),
 ('f7122222-2222-4222-8222-222222222222','f7011111-1111-4111-8111-111111111111','Disband group','other','member');
insert into public.group_members(group_id,user_id,role) values
 ('f7111111-1111-4111-8111-111111111111','f7011111-1111-4111-8111-111111111111','owner'),
 ('f7111111-1111-4111-8111-111111111111','f7022222-2222-4222-8222-222222222222','member'),
 ('f7122222-2222-4222-8222-222222222222','f7011111-1111-4111-8111-111111111111','owner'),
 ('f7122222-2222-4222-8222-222222222222','f7022222-2222-4222-8222-222222222222','member'),
 ('f7122222-2222-4222-8222-222222222222','f7033333-3333-4333-8333-333333333333','member');
insert into public.calendars(id,owner_user_id,group_id,name) values
 ('f7211111-1111-4111-8111-111111111111','f7011111-1111-4111-8111-111111111111','f7111111-1111-4111-8111-111111111111','Shared transfer calendar'),
 ('f7222222-2222-4222-8222-222222222222','f7011111-1111-4111-8111-111111111111','f7122222-2222-4222-8222-222222222222','Shared disband calendar'),
 ('f7233333-3333-4333-8333-333333333333','f7011111-1111-4111-8111-111111111111',null,'Personal calendar');
insert into public.events(id,owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,timezone,created_by) values
 ('f7311111-1111-4111-8111-111111111111','f7011111-1111-4111-8111-111111111111','f7211111-1111-4111-8111-111111111111','f7111111-1111-4111-8111-111111111111','Preserved shared event','group','2026-09-25 10:00+09','2026-09-25 11:00+09','Asia/Tokyo','f7011111-1111-4111-8111-111111111111'),
 ('f7322222-2222-4222-8222-222222222222','f7011111-1111-4111-8111-111111111111','f7222222-2222-4222-8222-222222222222','f7122222-2222-4222-8222-222222222222','Explicitly disbanded event','group','2026-09-25 12:00+09','2026-09-25 13:00+09','Asia/Tokyo','f7011111-1111-4111-8111-111111111111'),
 ('f7333333-3333-4333-8333-333333333333','f7011111-1111-4111-8111-111111111111','f7233333-3333-4333-8333-333333333333',null,'Private personal event','normal','2026-09-25 14:00+09','2026-09-25 15:00+09','Asia/Tokyo','f7011111-1111-4111-8111-111111111111');
insert into public.event_comments(id,event_id,author_user_id,body) values
 ('f7411111-1111-4111-8111-111111111111','f7311111-1111-4111-8111-111111111111','f7011111-1111-4111-8111-111111111111','Shared comment before deletion'),
 ('f7422222-2222-4222-8222-222222222222','f7333333-3333-4333-8333-333333333333','f7011111-1111-4111-8111-111111111111','Personal comment');

set local request.jwt.claim.sub='f7011111-1111-4111-8111-111111111111';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.is(jsonb_array_length(public.get_my_account_deletion_preflight()->'groups'),2,'preflight lists every owned group');
select extensions.is((select count(*) from jsonb_array_elements(public.get_my_account_deletion_preflight()->'groups') g
  where g->>'member_count'='2' and jsonb_array_length(g->'successors')=1),1::bigint,'preflight lists eligible successor and member count');
select extensions.is((select phase from public.request_account_deletion('f7511111-1111-4111-8111-111111111111',
  '[{"group_id":"f7111111-1111-4111-8111-111111111111","action":"transfer","successor_id":"f7022222-2222-4222-8222-222222222222"},{"group_id":"f7122222-2222-4222-8222-222222222222","action":"disband"}]'::jsonb)),'requested','request confirms transfer and disband choices');
select extensions.is((select group_actions->0->>'action' from public.get_my_account_deletion_context()),
  'transfer','restricted owner can recover confirmed local cleanup choices');
select extensions.is((select status from public.get_my_safety_state()),'deletion_pending','request revokes active actor access immediately');
select extensions.is((select phase from public.request_account_deletion('f7511111-1111-4111-8111-111111111111',
  '[{"group_id":"f7111111-1111-4111-8111-111111111111","action":"transfer","successor_id":"f7022222-2222-4222-8222-222222222222"},{"group_id":"f7122222-2222-4222-8222-222222222222","action":"disband"}]'::jsonb)),'requested','same operation replay is idempotent');
set local role service_role;
select extensions.is((select user_id from public.get_account_deletion_worker_context('f7511111-1111-4111-8111-111111111111')),
  'f7011111-1111-4111-8111-111111111111'::uuid,'worker can verify the operation owner');
reset role;
select extensions.throws_ok($q$select * from public.request_account_deletion('f7511111-1111-4111-8111-111111111111','[]'::jsonb)$q$,'PT409','account deletion operation mismatch','changed replay payload is rejected');
select extensions.is((select phase from public.get_my_account_deletion_status()),'requested','owner can read durable deletion status while restricted');
set local request.path='/rpc/get_my_account_deletion_preflight';
reset role;
select extensions.lives_ok($q$select private.safety_pre_request()$q$,'restricted owner can reach deletion preflight and recovery');
set local role authenticated;
set local request.path='/rpc/create_group';
select extensions.throws_ok($q$select private.safety_pre_request()$q$,'42501',NULL,'restricted owner cannot make unrelated RPC requests');
reset role;

set local role service_role;
create temp table deletion_prepared on commit drop as
select public.prepare_account_deletion_database('f7511111-1111-4111-8111-111111111111') result;
reset role;
select extensions.is((select result->>'phase' from deletion_prepared),'object_cleanup','database cleanup advances only to object cleanup');
select extensions.is((select owner_user_id from public.groups where id='f7111111-1111-4111-8111-111111111111'),'f7022222-2222-4222-8222-222222222222'::uuid,'confirmed successor receives shared group');
select extensions.is((select role from public.group_members where group_id='f7111111-1111-4111-8111-111111111111' and user_id='f7022222-2222-4222-8222-222222222222'),'owner','successor membership invariant is preserved');
select extensions.is((select count(*) from public.group_members where group_id='f7111111-1111-4111-8111-111111111111' and user_id='f7011111-1111-4111-8111-111111111111'),0::bigint,'deleting owner membership is removed');
select extensions.is((select owner_user_id from public.events where id='f7311111-1111-4111-8111-111111111111'),'f7022222-2222-4222-8222-222222222222'::uuid,'shared event ownership follows transferred group');
select extensions.is((select body from public.event_comments where id='f7411111-1111-4111-8111-111111111111'),'[削除済みユーザー]','shared user comment becomes a neutral tombstone');
select extensions.is((select author_user_id from public.event_comments where id='f7411111-1111-4111-8111-111111111111'),null::uuid,'shared comment no longer references deleted author');
select extensions.is((select count(*) from public.groups where id='f7122222-2222-4222-8222-222222222222'),0::bigint,'confirmed disband removes shared group');
select extensions.is((select count(*) from public.events where id='f7322222-2222-4222-8222-222222222222'),0::bigint,'confirmed disband removes that group event');
select extensions.is((select count(*) from public.events where id='f7333333-3333-4333-8333-333333333333'),0::bigint,'personal schedule event is removed');
select extensions.is((select count(*) from public.calendars where owner_user_id='f7011111-1111-4111-8111-111111111111'),0::bigint,'personal calendar rows are removed');
select extensions.ok(exists(select 1 from auth.users where id='f7011111-1111-4111-8111-111111111111'),'database phase never deletes Auth directly');
select extensions.ok(not private.safety_actor_active('f7011111-1111-4111-8111-111111111111'),'deletion-pending actor remains blocked');
select extensions.ok((select jsonb_typeof(result->'objects')='array' from deletion_prepared),'private worker receives an explicit Storage manifest');
set local role service_role;
select extensions.ok(public.mark_account_deletion_objects_removed('f7511111-1111-4111-8111-111111111111'),'worker can advance after confirming Storage removal');
reset role;
select extensions.is((select phase from private.account_deletion_operations where operation_id='f7511111-1111-4111-8111-111111111111'),'auth_delete','operation waits at Auth deletion gate');
set local role service_role;
select extensions.throws_ok($q$select public.finish_account_deletion('f7511111-1111-4111-8111-111111111111')$q$,'40001','Auth Admin deletion is not confirmed','complete phase requires missing Auth identity');
reset role;
select extensions.ok(not exists(select 1 from private.account_deletion_operations where operation_id='f7511111-1111-4111-8111-111111111111' and phase='complete'),'Auth failure cannot mark request complete');

-- This fixture user is created in this rollback-only isolated contract test.
delete from auth.users where id='f7011111-1111-4111-8111-111111111111';
select extensions.ok(not exists(select 1 from auth.users where id='f7011111-1111-4111-8111-111111111111'),'synthetic Auth identity can be removed after data cleanup');
set local role service_role;
select extensions.ok(public.finish_account_deletion('f7511111-1111-4111-8111-111111111111'),'worker records completion after confirmed Auth absence');
reset role;
select extensions.is((select phase from private.account_deletion_operations where operation_id='f7511111-1111-4111-8111-111111111111'),'complete','operation completes only at final phase');
select extensions.is((select status from private.user_safety_state where user_id='f7011111-1111-4111-8111-111111111111'),'deleted','non-FK tombstone retains terminal safety state');
select extensions.ok(not has_function_privilege('authenticated','public.prepare_account_deletion_database(uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.finish_account_deletion(uuid)','EXECUTE'),'client cannot skip Storage or Auth deletion gates');
reset role;
select * from extensions.finish();
rollback;
