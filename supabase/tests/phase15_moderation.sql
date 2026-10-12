begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(33);

select extensions.ok(to_regprocedure('public.admin_list_pending_reports(integer,integer)') is not null,'global admin pending RPC exists');
select extensions.ok(to_regprocedure('public.admin_get_report(uuid)') is not null,'global admin detail RPC exists');
select extensions.ok(to_regprocedure('public.admin_resolve_report(uuid,text,text,uuid)') is not null,'global admin resolve RPC exists');
select extensions.ok(to_regprocedure('public.admin_list_audit_logs(integer,integer)') is not null,'global admin audit RPC exists');
select extensions.ok(not has_table_privilege('authenticated','public.audit_logs','SELECT'),'raw audit reads denied');
select extensions.ok(not has_table_privilege('authenticated','public.reports','SELECT'),'raw report reads denied');
select extensions.ok(not has_table_privilege('authenticated','private.global_admins','SELECT'),'admin registry hidden');
select extensions.ok(not has_function_privilege('anon','public.admin_list_pending_reports(integer,integer)','EXECUTE'),'anonymous admin list denied');
select extensions.ok((select prosecdef from pg_proc where oid='public.admin_resolve_report(uuid,text,text,uuid)'::regprocedure),'resolve is security definer');
select extensions.ok((select prosecdef from pg_proc where oid='public.admin_list_pending_reports(integer,integer)'::regprocedure),'list is security definer');
select extensions.ok(exists(select 1 from information_schema.columns where table_schema='public' and table_name='events' and column_name='moderation_hidden_at'),'event moderation state exists');
select extensions.ok(exists(select 1 from information_schema.columns where table_schema='public' and table_name='event_comments' and column_name='moderation_hidden_at'),'comment moderation state exists');

insert into auth.users(id) values
 ('f1511111-1111-4111-8111-111111111111'),
 ('f1522222-2222-4222-8222-222222222222'),
 ('f1533333-3333-4333-8333-333333333333'),
 ('f1544444-4444-4444-8444-444444444444') on conflict(id) do nothing;
insert into private.global_admins(user_id) values
 ('f1511111-1111-4111-8111-111111111111'),
 ('f1522222-2222-4222-8222-222222222222') on conflict(user_id) do update set revoked_at=null;
insert into public.groups(id,owner_user_id,name,type,event_create_policy) values
 ('f1555555-5555-4555-8555-555555555555','f1533333-3333-4333-8333-333333333333','Phase 15 synthetic','other','member');
insert into public.group_members(group_id,user_id,role) values
 ('f1555555-5555-4555-8555-555555555555','f1533333-3333-4333-8333-333333333333','owner'),
 ('f1555555-5555-4555-8555-555555555555','f1544444-4444-4444-8444-444444444444','member');
insert into public.calendars(id,owner_user_id,group_id,name) values
 ('f1566666-6666-4666-8666-666666666666','f1533333-3333-4333-8333-333333333333','f1555555-5555-4555-8555-555555555555','Phase 15 synthetic');
insert into public.events(id,owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,timezone,created_by) values
 ('f1577777-7777-4777-8777-777777777777','f1533333-3333-4333-8333-333333333333','f1566666-6666-4666-8666-666666666666','f1555555-5555-4555-8555-555555555555','Phase 15 hidden event','group','2026-09-25 10:00+09','2026-09-25 11:00+09','Asia/Tokyo','f1533333-3333-4333-8333-333333333333');

set local request.jwt.claim.sub='f1544444-4444-4444-8444-444444444444'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.throws_ok($q$select * from public.admin_list_pending_reports(50,0)$q$,'42501',NULL,'normal member cannot list reports');
create temp table p15_event_report as select report_id from public.create_group_content_report('event','f1577777-7777-4777-8777-777777777777','unsafe','f1588888-8888-4888-8888-888888888888');
select extensions.ok((select report_id from p15_event_report) is not null,'member creates dedicated report');
select extensions.is((select count(*) from p15_event_report),1::bigint,'dedicated report receipt exists');
set local request.jwt.claim.sub='f1533333-3333-4333-8333-333333333333'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.throws_ok($q$select * from public.admin_resolve_report((select report_id from p15_event_report),'hide','owner attempt','f1599999-9999-4999-8999-999999999999')$q$,'42501',NULL,'group owner cannot resolve as global admin');

set local request.jwt.claim.sub='f1511111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select count(*) from public.admin_list_pending_reports(50,0) where report_id=(select report_id from p15_event_report)),1::bigint,'global admin sees dedicated pending report');
select extensions.is((select reporter_user_id from public.admin_get_report((select report_id from p15_event_report))),'f1544444-4444-4444-8444-444444444444'::uuid,'admin detail includes reporter identity');
select extensions.is((select status from public.admin_resolve_report((select report_id from p15_event_report),'hide','confirmed unsafe','f15a1111-1111-4111-8111-111111111111')),'actioned','admin hides event atomically');
select extensions.is((select count(*) from public.admin_list_pending_reports(50,0) where report_id=(select report_id from p15_event_report)),0::bigint,'resolved dedicated report leaves pending list');
select extensions.is((select count(*) from public.admin_list_audit_logs(50,0) where action='moderation_hide' and target_id='f1577777-7777-4777-8777-777777777777'),1::bigint,'hide writes audit evidence');
set local request.jwt.claim.sub='f1544444-4444-4444-8444-444444444444'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.throws_ok($q$select * from public.get_group_event('f1577777-7777-4777-8777-777777777777')$q$,'42501',NULL,'hidden event detail is denied');
select extensions.is((select count(*) from public.list_group_events('f1555555-5555-4555-8555-555555555555')),0::bigint,'hidden event is absent from list projection');
select extensions.throws_ok($q$select * from public.list_group_event_rsvps('f1577777-7777-4777-8777-777777777777')$q$,'42501',NULL,'hidden event RSVP is denied');
select extensions.throws_ok($q$select * from public.create_group_event_comment('f1577777-7777-4777-8777-777777777777','stale write','f15b1111-1111-4111-8111-111111111111')$q$,'42501',NULL,'hidden event cannot receive comment');

reset role; update private.global_admins set revoked_at=now() where user_id='f1511111-1111-4111-8111-111111111111';
set local request.jwt.claim.sub='f1511111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.throws_ok($q$select * from public.admin_list_audit_logs(50,0)$q$,'42501',NULL,'revoked admin stale JWT is denied');

reset role; update private.global_admins set revoked_at=null where user_id='f1511111-1111-4111-8111-111111111111';
insert into public.events(id,owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,timezone,created_by) values
 ('f15d7777-7777-4777-8777-777777777777','f1533333-3333-4333-8333-333333333333','f1566666-6666-4666-8666-666666666666','f1555555-5555-4555-8555-555555555555','Phase 15 conflict event','group','2026-09-26 10:00+09','2026-09-26 11:00+09','Asia/Tokyo','f1533333-3333-4333-8333-333333333333');
set local request.jwt.claim.sub='f1544444-4444-4444-8444-444444444444'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
create temp table p15_second_report as select report_id from public.create_group_content_report('event','f15d7777-7777-4777-8777-777777777777','conflict','f15e1111-1111-4111-8111-111111111111');
select extensions.ok((select report_id from p15_second_report) is not null,'second dedicated report created');
set local request.jwt.claim.sub='f1511111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select status from public.admin_resolve_report((select report_id from p15_second_report),'dismiss','no violation','f15f1111-1111-4111-8111-111111111111')),'dismissed','dismiss leaves target unchanged');
select extensions.throws_ok($q$select * from public.admin_resolve_report((select report_id from p15_second_report),'hide','late hide','f15f1111-1111-4111-8111-111111111111')$q$,'PT409','operation replay mismatch','resolution payload mismatch is rejected');
select extensions.is((select count(*) from public.admin_list_audit_logs(50,0) where action='moderation_dismiss'),1::bigint,'dismiss writes audit evidence');
select extensions.ok(not has_table_privilege('authenticated','public.audit_logs','UPDATE'),'normal user cannot update audit');
select extensions.ok(not has_table_privilege('authenticated','public.audit_logs','DELETE'),'normal user cannot delete audit');
reset role;
select extensions.ok(not has_function_privilege('authenticated','private.admin_record(uuid,uuid,text,text,jsonb)','EXECUTE'),'normal user cannot write receipts');

select * from extensions.finish();
rollback;
