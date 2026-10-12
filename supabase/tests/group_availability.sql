begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(36);
select extensions.ok(to_regprocedure('public.find_group_availability(uuid,uuid[],timestamptz,timestamptz,integer)') is not null and to_regprocedure('private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)') is not null,'group availability RPC and safety wrapper base exist');
select extensions.ok(has_function_privilege('anon','public.find_group_availability(uuid,uuid[],timestamptz,timestamptz,integer)','execute') is false,'anonymous cannot query group availability');
select extensions.ok(has_function_privilege('public','public.find_group_availability(uuid,uuid[],timestamptz,timestamptz,integer)','execute') is false,'PUBLIC cannot query group availability');
select extensions.ok(has_function_privilege('authenticated','public.find_group_availability(uuid,uuid[],timestamptz,timestamptz,integer)','execute'),'authenticated can call group availability');
select extensions.ok((select prosecdef from pg_proc where oid='public.find_group_availability(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure),'availability derives actor in security definer RPC');
select extensions.ok(pg_get_functiondef('private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure) like '%PRIVATE%','self PRIVATE projection is represented');
select extensions.ok(pg_get_functiondef('private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure) like '%declined%','declined group events are excluded');
select extensions.ok(pg_get_functiondef('private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure) like '%membership or authorization changed%','membership loss fails closed');
select extensions.ok(pg_get_functiondef('private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure) like '%generate_series%','timetable courses are projected');
select extensions.ok(pg_get_functiondef('private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure) like '%p.default_visibility%','profile defaults are applied');
select extensions.ok(pg_get_functiondef('private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure) like '%p_range_end%','busy intervals use bounded half-open range');
select extensions.ok(pg_get_functiondef('private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure) like '%query_id%','responses carry a query identity');
select extensions.ok(pg_get_functiondef('private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure) like '%generation%','responses carry a membership generation');
select extensions.ok(pg_get_functiondef('private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure) not like '%jsonb_build_object(''member_id''%','busy output has no member attribution');
select extensions.ok(pg_get_functiondef('public.validate_group_availability(uuid,uuid[],text)'::regprocedure) like '%private.is_blocked%','validation rechecks block authorization');
select extensions.ok(pg_get_functiondef('private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure) like '%gm.visibility_level%','group member visibility is applied');
select extensions.ok(pg_get_functiondef('private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure) like '%grp.default_visibility%','group default visibility is applied');
select extensions.ok(pg_get_functiondef('private.phase12_find_group_availability_base(uuid,uuid[],timestamptz,timestamptz,integer)'::regprocedure) not like '%friend_%','group projection does not call friend RPCs');
select extensions.ok(to_regprocedure('private.restrict_group_visibility(public.visibility_level,public.visibility_level)') is not null,'group visibility cap helper exists');
select extensions.ok(not has_function_privilege('authenticated','private.restrict_group_visibility(public.visibility_level,public.visibility_level)','execute'),'group visibility cap helper is not callable by clients');

-- Functional/JWT coverage. The selected third member is intentionally not a
-- friend; this exercises the group-only authorization path.
insert into auth.users(id) values
 ('9a111111-1111-4111-8111-111111111111'),
 ('9a222222-2222-4222-8222-222222222222'),
 ('9a333333-3333-4333-8333-333333333333'),
 ('9a444444-4444-4444-8444-444444444444') on conflict(id) do nothing;
insert into public.profiles(user_id,display_name,default_visibility)
values
 ('9a111111-1111-4111-8111-111111111111','Availability owner','PRIVATE'),
 ('9a222222-2222-4222-8222-222222222222','Availability member','PRIVATE'),
 ('9a333333-3333-4333-8333-333333333333','Availability nonfriend','PRIVATE'),
 ('9a444444-4444-4444-8444-444444444444','Availability outsider','PRIVATE')
on conflict(user_id) do update set display_name=excluded.display_name;
insert into public.groups(id,owner_user_id,name,type,default_visibility,event_create_policy)
values ('9b111111-1111-4111-8111-111111111111','9a111111-1111-4111-8111-111111111111','Availability group','other','BUSY_ONLY','member');
insert into public.group_members(group_id,user_id,role,visibility_level) values
 ('9b111111-1111-4111-8111-111111111111','9a111111-1111-4111-8111-111111111111','owner','FULL'),
 ('9b111111-1111-4111-8111-111111111111','9a222222-2222-4222-8222-222222222222','member','BUSY_ONLY'),
 ('9b111111-1111-4111-8111-111111111111','9a333333-3333-4333-8333-333333333333','member','BUSY_ONLY');
insert into public.calendars(id,owner_user_id,group_id,name,default_visibility) values
 ('9c111111-1111-4111-8111-111111111111','9a111111-1111-4111-8111-111111111111',null,'Owner calendar','PRIVATE'),
 ('9c222222-2222-4222-8222-222222222222','9a222222-2222-4222-8222-222222222222',null,'Member calendar','PRIVATE'),
 ('9c333333-3333-4333-8333-333333333333','9a333333-3333-4333-8333-333333333333',null,'Nonfriend calendar','PRIVATE'),
 ('9c444444-4444-4444-8444-444444444444','9a111111-1111-4111-8111-111111111111','9b111111-1111-4111-8111-111111111111','Group calendar','BUSY_ONLY');
set local session_replication_role='replica';
insert into public.events(id,owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,visibility_level,created_by) values
 ('9d111111-1111-4111-8111-111111111111','9a111111-1111-4111-8111-111111111111','9c111111-1111-4111-8111-111111111111',null,'Self private','normal','2026-09-21 01:00+00','2026-09-21 02:00+00','PRIVATE','9a111111-1111-4111-8111-111111111111'),
 ('9d333333-3333-4333-8333-333333333333','9a222222-2222-4222-8222-222222222222','9c222222-2222-4222-8222-222222222222',null,'Member busy','normal','2026-09-21 05:00+00','2026-09-21 06:00+00','BUSY_ONLY','9a222222-2222-4222-8222-222222222222'),
 ('9d444444-4444-4444-8444-444444444444','9a111111-1111-4111-8111-111111111111','9c444444-4444-4444-8444-444444444444','9b111111-1111-4111-8111-111111111111','Declined group event','group','2026-09-21 11:00+00','2026-09-21 12:00+00','BUSY_ONLY','9a111111-1111-4111-8111-111111111111'),
 ('9d555555-5555-4555-8555-555555555555','9a111111-1111-4111-8111-111111111111','9c444444-4444-4444-8444-444444444444','9b111111-1111-4111-8111-111111111111','Attending group event','group','2026-09-21 12:00+00','2026-09-21 13:00+00','BUSY_ONLY','9a111111-1111-4111-8111-111111111111');
insert into public.event_participants(event_id,user_id,status) values
 ('9d444444-4444-4444-8444-444444444444','9a111111-1111-4111-8111-111111111111','declined'),
 ('9d444444-4444-4444-8444-444444444444','9a222222-2222-4222-8222-222222222222','declined'),
 ('9d444444-4444-4444-8444-444444444444','9a333333-3333-4333-8333-333333333333','declined'),
 ('9d555555-5555-4555-8555-555555555555','9a111111-1111-4111-8111-111111111111','attending'),
 ('9d555555-5555-4555-8555-555555555555','9a222222-2222-4222-8222-222222222222','attending'),
 ('9d555555-5555-4555-8555-555555555555','9a333333-3333-4333-8333-333333333333','declined');
insert into public.universities(id,name,normalized_name) values
 ('9e222222-2222-4222-8222-222222222222','Availability University','availability university');
insert into public.terms(id,university_id,owner_user_id,name,academic_year,start_date,end_date,term_type,created_by)
values ('9e111111-1111-4111-8111-111111111111','9e222222-2222-4222-8222-222222222222','9a333333-3333-4333-8333-333333333333','Availability term',2026,'2026-09-01','2026-09-30','semester','9a333333-3333-4333-8333-333333333333');
insert into public.period_settings(id,owner_user_id,university_id,term_id,day_of_week,period_no,start_time,end_time)
values ('9f111111-1111-4111-8111-111111111111','9a333333-3333-4333-8333-333333333333','9e222222-2222-4222-8222-222222222222','9e111111-1111-4111-8111-111111111111',1,1,'16:00','17:00');
insert into public.user_courses(id,owner_user_id,term_id,title,normalized_title,day_of_week,period_no,visibility_level)
values ('9f222222-2222-4222-8222-222222222222','9a333333-3333-4333-8333-333333333333','9e111111-1111-4111-8111-111111111111','Nonfriend course','nonfriend course',1,1,'BUSY_ONLY');
insert into public.exams(id,owner_user_id,title,start_at,end_at,visibility_level)
values ('9f333333-3333-4333-8333-333333333333','9a333333-3333-4333-8333-333333333333','Nonfriend exam','2026-09-21 09:00+00','2026-09-21 10:00+00','BUSY_ONLY');
set local session_replication_role='origin';

set local request.jwt.claim.sub='9a111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
create temp table phase12_baseline on commit drop as
select public.find_group_availability(
  '9b111111-1111-4111-8111-111111111111',
  array['9a111111-1111-4111-8111-111111111111'::uuid,'9a222222-2222-4222-8222-222222222222'::uuid,'9a333333-3333-4333-8333-333333333333'::uuid],
  '2026-09-21 00:00+00','2026-09-21 18:00+00',30) response;
reset role;
insert into public.events(id,owner_user_id,calendar_id,title,kind,start_at,end_at,visibility_level,created_by)
values ('9d222222-2222-4222-8222-222222222222','9a222222-2222-4222-8222-222222222222','9c222222-2222-4222-8222-222222222222','Other private','normal','2026-09-21 03:00+00','2026-09-21 04:00+00','PRIVATE','9a222222-2222-4222-8222-222222222222');
set local role authenticated;
select extensions.ok((select response->'query_id' from phase12_baseline) is not null,'functional response has query identity');
select extensions.ok(exists(select 1 from jsonb_array_elements((select response->'rows' from phase12_baseline)) r where (r->>'start_at')::timestamptz='2026-09-21 01:00+00'::timestamptz),'self PRIVATE contributes busy timing');
select extensions.ok((select response->'rows' from phase12_baseline)=(select public.find_group_availability('9b111111-1111-4111-8111-111111111111',array['9a111111-1111-4111-8111-111111111111'::uuid,'9a222222-2222-4222-8222-222222222222'::uuid,'9a333333-3333-4333-8333-333333333333'::uuid],'2026-09-21 00:00+00','2026-09-21 18:00+00',30)->'rows'),'other member PRIVATE is invariant and not leaked');
select extensions.ok(exists(select 1 from jsonb_array_elements((select response->'rows' from phase12_baseline)) r where (r->>'start_at')::timestamptz='2026-09-21 05:00+00'::timestamptz and r->>'visibility_level'='BUSY_ONLY'),'BUSY_ONLY member timing contributes without details');
reset role;
update public.group_members set visibility_level='PRIVATE' where group_id='9b111111-1111-4111-8111-111111111111' and user_id='9a222222-2222-4222-8222-222222222222';
set local role authenticated;
create temp table phase12_private_cap on commit drop as
select public.find_group_availability('9b111111-1111-4111-8111-111111111111',array['9a111111-1111-4111-8111-111111111111'::uuid,'9a222222-2222-4222-8222-222222222222'::uuid],'2026-09-21 00:00+00','2026-09-21 18:00+00',30) response;
select extensions.ok(not exists(select 1 from jsonb_array_elements((select response->'rows' from phase12_private_cap)) r where (r->>'start_at')::timestamptz='2026-09-21 05:00+00'::timestamptz),'PRIVATE group cap suppresses another member interval');
reset role;
update public.group_members set visibility_level='BUSY_ONLY' where group_id='9b111111-1111-4111-8111-111111111111' and user_id='9a222222-2222-4222-8222-222222222222';
set local role authenticated;
create temp table phase12_busy_cap on commit drop as
select public.find_group_availability('9b111111-1111-4111-8111-111111111111',array['9a111111-1111-4111-8111-111111111111'::uuid,'9a222222-2222-4222-8222-222222222222'::uuid],'2026-09-21 00:00+00','2026-09-21 18:00+00',30) response;
select extensions.ok(exists(select 1 from jsonb_array_elements((select response->'rows' from phase12_busy_cap)) r where (r->>'start_at')::timestamptz='2026-09-21 05:00+00'::timestamptz and r->>'visibility_level'='BUSY_ONLY'),'BUSY_ONLY group cap preserves timing only');
select extensions.ok(exists(select 1 from jsonb_array_elements((select response->'rows' from phase12_baseline)) r where (r->>'start_at')::timestamptz='2026-09-21 07:00+00'::timestamptz),'nonfriend timetable course contributes through group membership');
select extensions.ok(exists(select 1 from jsonb_array_elements((select response->'rows' from phase12_baseline)) r where (r->>'start_at')::timestamptz='2026-09-21 09:00+00'::timestamptz),'timed exam contributes to busy projection');
select extensions.ok(not exists(select 1 from jsonb_array_elements((select response->'rows' from phase12_baseline)) r where (r->>'start_at')::timestamptz='2026-09-21 11:00+00'::timestamptz),'all-declined group event does not block');
select extensions.ok(exists(select 1 from jsonb_array_elements((select response->'rows' from phase12_baseline)) r where (r->>'start_at')::timestamptz='2026-09-21 12:00+00'::timestamptz),'attending group event blocks conservatively');
select extensions.throws_ok($q$select public.find_group_availability('9b111111-1111-4111-8111-111111111111',array['9a111111-1111-4111-8111-111111111111'::uuid,'9a444444-4444-4444-8444-444444444444'::uuid],'2026-09-21 00:00+00','2026-09-21 18:00+00',30)$q$,'42501','membership or authorization changed; retry','foreign member is denied');
reset role;
set local request.jwt.claim.sub='9a444444-4444-4444-8444-444444444444';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.throws_ok($q$select public.find_group_availability('9b111111-1111-4111-8111-111111111111',array['9a111111-1111-4111-8111-111111111111'::uuid],'2026-09-21 00:00+00','2026-09-21 18:00+00',30)$q$,'42501','membership or authorization changed; retry','nonmember cannot read group availability');
select extensions.throws_ok($q$select public.find_group_availability('9b111111-1111-4111-8111-111111111111',array['9a444444-4444-4444-8444-444444444444'::uuid],'2026-09-21 00:00+00','2026-09-21 18:00+00',30)$q$,'42501','membership or authorization changed; retry','nonmember actor fails group membership gate when selected');
reset role;
set local request.jwt.claim.sub='9a111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role='authenticated';
set local role authenticated;
select extensions.throws_ok($q$select public.find_group_availability('9b111111-1111-4111-8111-111111111111',array['9a111111-1111-4111-8111-111111111111'::uuid,'9a111111-1111-4111-8111-111111111111'::uuid],'2026-09-21 00:00+00','2026-09-21 18:00+00',30)$q$,'42501','duplicate member selection','duplicate member selection is denied');
select extensions.is(jsonb_array_length((public.find_group_availability('9b111111-1111-4111-8111-111111111111',array['9a111111-1111-4111-8111-111111111111'::uuid,'9a222222-2222-4222-8222-222222222222'::uuid],'2026-09-21 02:00+00','2026-09-21 03:00+00',30)->'rows')),0,'half-open boundary excludes an event ending at range start');
create temp table phase12_generation on commit drop as
select public.find_group_availability('9b111111-1111-4111-8111-111111111111',array['9a111111-1111-4111-8111-111111111111'::uuid,'9a222222-2222-4222-8222-222222222222'::uuid,'9a333333-3333-4333-8333-333333333333'::uuid],'2026-09-21 00:00+00','2026-09-21 18:00+00',30) response;
reset role;
delete from public.group_members where group_id='9b111111-1111-4111-8111-111111111111' and user_id='9a333333-3333-4333-8333-333333333333';
set local role authenticated;
select extensions.is((public.validate_group_availability('9b111111-1111-4111-8111-111111111111',array['9a111111-1111-4111-8111-111111111111'::uuid,'9a222222-2222-4222-8222-222222222222'::uuid,'9a333333-3333-4333-8333-333333333333'::uuid],(select response->>'generation' from phase12_generation))->>'valid'),'false','membership loss invalidates captured generation');
reset role;
select * from extensions.finish();
rollback;
