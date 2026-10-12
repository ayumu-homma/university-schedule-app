begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(33);
select extensions.ok(pg_get_functiondef('public.admin_get_report(uuid)'::regprocedure) like '%target_context%','admin detail has bounded target context');
select extensions.ok(pg_get_functiondef('public.admin_resolve_report(uuid,text,text,uuid)'::regprocedure) like '%already_hidden%','resolution distinguishes already hidden');
select extensions.ok(pg_get_functiondef('public.admin_resolve_report(uuid,text,text,uuid)'::regprocedure) like '%previous_target_state%','audit carries previous target state');
select extensions.ok(
  pg_get_functiondef('public.find_group_availability(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure) like '%private.phase12_find_group_availability_base(%'
  and pg_get_functiondef('private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure) like '%moderation_hidden_at%',
  'availability wrapper delegates to the base that excludes hidden group events');
select extensions.ok(pg_get_functiondef('private.phase15_group_availability_generation(uuid,uuid[])'::regprocedure) like '%moderation_hidden_at%','availability generation includes moderation state');
select extensions.ok(pg_get_functiondef('private.phase15_resolve_visible_events_for_base(uuid,timestamptz,timestamptz)'::regprocedure) like '%moderation_hidden_at%','friend base projection excludes hidden events');
select extensions.ok(pg_get_functiondef('private.phase13_event_generation(uuid)'::regprocedure) like '%event_comments%','UGC generation includes comments');

insert into auth.users(id) values
 ('f2511111-1111-4111-8111-111111111111'),('f2522222-2222-4222-8222-222222222222'),
 ('f2533333-3333-4333-8333-333333333333'),('f2544444-4444-4444-8444-444444444444') on conflict(id) do nothing;
insert into private.global_admins(user_id) values ('f2511111-1111-4111-8111-111111111111'),('f2522222-2222-4222-8222-222222222222') on conflict(user_id) do update set revoked_at=null;
insert into public.groups(id,owner_user_id,name,type,event_create_policy) values ('f2555555-5555-4555-8555-555555555555','f2533333-3333-4333-8333-333333333333','Phase15 followup','other','member');
insert into public.group_members(group_id,user_id,role) values ('f2555555-5555-4555-8555-555555555555','f2533333-3333-4333-8333-333333333333','owner'),('f2555555-5555-4555-8555-555555555555','f2544444-4444-4444-8444-444444444444','member');
insert into public.calendars(id,owner_user_id,group_id,name) values ('f2566666-6666-4666-8666-666666666666','f2533333-3333-4333-8333-333333333333','f2555555-5555-4555-8555-555555555555','Phase15 followup');
insert into public.events(id,owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,timezone,created_by) values ('f2577777-7777-4777-8777-777777777777','f2533333-3333-4333-8333-333333333333','f2566666-6666-4666-8666-666666666666','f2555555-5555-4555-8555-555555555555','comment target','group','2026-09-28 10:00+09','2026-09-28 11:00+09','Asia/Tokyo','f2533333-3333-4333-8333-333333333333');

set local request.jwt.claim.sub='f2544444-4444-4444-8444-444444444444'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.throws_ok($q$select * from public.admin_list_pending_reports(50,0)$q$,'42501',NULL,'member cannot use global admin list');
select extensions.is((select count(*) from public.create_group_event_comment('f2577777-7777-4777-8777-777777777777','reviewable comment','f2588888-8888-4888-8888-888888888888')),1::bigint,'dedicated comment created');
create temp table p15_comment as select comment_id from public.list_group_event_comments('f2577777-7777-4777-8777-777777777777') limit 1;
create temp table p15_before as select generation from public.get_group_event_ugc('f2577777-7777-4777-8777-777777777777');
create temp table p15_comment_report as select report_id from public.create_group_content_report('comment',(select comment_id from p15_comment),'moderation review','f2599999-9999-4999-8999-999999999999');
select extensions.is((select report_id from p15_comment_report) is not null,true,'comment report created');
set local request.jwt.claim.sub='f2533333-3333-4333-8333-333333333333'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.throws_ok($q$select * from public.admin_resolve_report((select report_id from p15_comment_report),'hide','owner attempt','f25a1111-1111-4111-8111-111111111111')$q$,'42501',NULL,'group owner is not global admin');
set local request.jwt.claim.sub='f2511111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select target_state from public.admin_resolve_report((select report_id from p15_comment_report),'hide','hide comment','f25b1111-1111-4111-8111-111111111111')),'transitioned_hidden','comment hide reports transition');
select extensions.is((select previous_target_state from public.admin_resolve_report((select report_id from p15_comment_report),'hide','hide comment','f25b1111-1111-4111-8111-111111111111')),'visible','exact replay retains the actual pre-hide comment state');
select extensions.is((select metadata->>'previous_target_state' from public.admin_list_audit_logs(100,0) where target_id=(select comment_id from p15_comment) and action='moderation_hide' limit 1),'visible','audit records actual pre-hide comment state');
select extensions.ok(((select target_context->>'moderation_hidden_at' from public.admin_get_report((select report_id from p15_comment_report))) is not null),'comment has separate moderation state');
set local request.jwt.claim.sub='f2544444-4444-4444-8444-444444444444'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select valid from public.validate_group_event_ugc('f2577777-7777-4777-8777-777777777777',(select generation from p15_before))),false,'cached UGC generation invalidates after comment hide');
select extensions.is((select count(*) from public.list_group_event_comments('f2577777-7777-4777-8777-777777777777')),0::bigint,'hidden comment leaves normal projection');
select extensions.throws_ok($q$select * from public.update_group_event_comment((select comment_id from p15_comment),'revive',1,'f25c1111-1111-4111-8111-111111111111')$q$,'42501',NULL,'hidden comment cannot be restored');
set local request.jwt.claim.sub='f2511111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select target_state from public.admin_resolve_report((select report_id from p15_comment_report),'hide','hide comment','f25b1111-1111-4111-8111-111111111111')),'transitioned_hidden','exact resolution replay returns original result');
select extensions.is((select count(*) from public.admin_list_audit_logs(100,0) where target_id=(select comment_id from p15_comment) and action='moderation_hide'),1::bigint,'exact replay creates no duplicate audit');
set local request.jwt.claim.sub='f2522222-2222-4222-8222-222222222222'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.throws_ok($q$select * from public.admin_resolve_report((select report_id from p15_comment_report),'dismiss','competing admin','f25d1111-1111-4111-8111-111111111111')$q$,'PT409','report already resolved','second admin cannot overwrite decision');

reset role;
insert into public.events(id,owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,timezone,created_by) values ('f25e7777-7777-4777-8777-777777777777','f2533333-3333-4333-8333-333333333333','f2566666-6666-4666-8666-666666666666','f2555555-5555-4555-8555-555555555555','availability target','group','2026-09-29 10:00+09','2026-09-29 11:00+09','Asia/Tokyo','f2533333-3333-4333-8333-333333333333');
set local request.jwt.claim.sub='f2544444-4444-4444-8444-444444444444'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
create temp table p15_availability_before as select public.find_group_availability('f2555555-5555-4555-8555-555555555555',array['f2544444-4444-4444-8444-444444444444'::uuid],'2026-09-29 09:00+09','2026-09-29 12:00+09',30)->>'generation' generation;
select extensions.ok((select jsonb_array_length(response->'rows')>0 from (select public.find_group_availability('f2555555-5555-4555-8555-555555555555',array['f2544444-4444-4444-8444-444444444444'::uuid],'2026-09-29 09:00+09','2026-09-29 12:00+09',30) response) x),'availability has baseline response');
create temp table p15_event_report as select report_id from public.create_group_content_report('event','f25e7777-7777-4777-8777-777777777777','availability review','f25f1111-1111-4111-8111-111111111111');
select extensions.is((select report_id from p15_event_report) is not null,true,'event report created');
set local request.jwt.claim.sub='f2511111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select target_state from public.admin_resolve_report((select report_id from p15_event_report),'hide','hide availability event','f2601111-1111-4111-8111-111111111111')),'transitioned_hidden','event hide reports transition');
set local request.jwt.claim.sub='f2544444-4444-4444-8444-444444444444'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((public.validate_group_availability('f2555555-5555-4555-8555-555555555555',array['f2544444-4444-4444-8444-444444444444'::uuid],(select generation from p15_availability_before))->>'valid'),'false','availability cache invalidates after event hide');
select extensions.is((select count(*) from public.get_visible_events('f2544444-4444-4444-8444-444444444444','2026-09-28 00:00+09','2026-09-30 00:00+09') where event_id='f25e7777-7777-4777-8777-777777777777'),0::bigint,'shared event projection excludes hidden event');

reset role;
insert into public.event_comments(id,event_id,author_user_id,body,moderation_hidden_at) values ('f2611111-1111-4111-8111-111111111111','f2577777-7777-4777-8777-777777777777','f2544444-4444-4444-8444-444444444444','already hidden',now());
create temp table p15_hidden_report as select 'f2651111-1111-4111-8111-111111111111'::uuid id;
insert into public.reports(id,reporter_user_id,target_type,target_id,reason) select id,'f2544444-4444-4444-8444-444444444444','comment','f2611111-1111-4111-8111-111111111111','pre-hidden' from p15_hidden_report;
set local request.jwt.claim.sub='f2511111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select target_state from public.admin_resolve_report('f2651111-1111-4111-8111-111111111111','hide','confirm hidden','f2622222-2222-4222-8222-222222222222')),'already_hidden','already hidden is distinguished');
select extensions.is((select previous_target_state from public.admin_resolve_report('f2651111-1111-4111-8111-111111111111','hide','confirm hidden','f2622222-2222-4222-8222-222222222222')),'hidden','pre-hidden target state is retained in the idempotent receipt');
select extensions.is((select metadata->>'previous_target_state' from public.admin_list_audit_logs(100,0) where target_id='f2611111-1111-4111-8111-111111111111' limit 1),'hidden','audit captures previous hidden state');
reset role;
insert into public.event_comments(id,event_id,author_user_id,body,deleted_at) values ('f2633333-3333-4333-8333-333333333333','f2577777-7777-4777-8777-777777777777','f2544444-4444-4444-8444-444444444444','already deleted',now());
create temp table p15_deleted_report as select 'f2666666-6666-4666-8666-666666666666'::uuid id;
insert into public.reports(id,reporter_user_id,target_type,target_id,reason) select id,'f2544444-4444-4444-8444-444444444444','comment','f2633333-3333-4333-8333-333333333333','pre-deleted' from p15_deleted_report;
set local request.jwt.claim.sub='f2511111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select target_state from public.admin_resolve_report('f2666666-6666-4666-8666-666666666666','hide','confirm deleted','f2644444-4444-4444-8444-444444444444')),'already_deleted','already deleted is distinguished');
select extensions.ok(((select target_context->>'moderation_hidden_at' from public.admin_get_report('f2666666-6666-4666-8666-666666666666')) is null),'already deleted is not falsely hidden');
reset role;
select extensions.ok(not has_function_privilege('authenticated','private.admin_record(uuid,uuid,text,text,jsonb)','EXECUTE'),'receipt writer remains private');
select extensions.ok(not has_table_privilege('authenticated','public.audit_logs','SELECT'),'audit rows remain inaccessible to normal users');
select * from extensions.finish();
rollback;
