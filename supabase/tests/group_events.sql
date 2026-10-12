begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(46);

select extensions.ok(to_regprocedure('public.list_group_events(uuid)') is not null,'list group events RPC exists');
select extensions.ok(to_regprocedure('public.get_group_event(uuid)') is not null,'get group event RPC exists');
select extensions.ok(to_regprocedure('public.list_group_event_rsvps(uuid)') is not null,'list RSVP RPC exists');
select extensions.ok(to_regprocedure('public.create_group_event(uuid,text,timestamptz,timestamptz,text,text,uuid)') is not null,'create event RPC exists');
select extensions.ok(to_regprocedure('public.update_group_event(uuid,text,timestamptz,timestamptz,text,text,bigint,uuid)') is not null,'update event RPC exists');
select extensions.ok(to_regprocedure('public.cancel_group_event(uuid,bigint,uuid)') is not null,'cancel event RPC exists');
select extensions.ok(to_regprocedure('public.set_group_event_rsvp(uuid,text,uuid)') is not null,'RSVP RPC exists');
select extensions.ok(not has_function_privilege('anon','public.create_group_event(uuid,text,timestamptz,timestamptz,text,text,uuid)','execute'),'anonymous cannot create events');
select extensions.ok(not has_function_privilege('public','public.create_group_event(uuid,text,timestamptz,timestamptz,text,text,uuid)','execute'),'PUBLIC cannot create events');
select extensions.ok(has_function_privilege('authenticated','public.create_group_event(uuid,text,timestamptz,timestamptz,text,text,uuid)','execute'),'authenticated can call create event RPC');
select extensions.ok(not has_function_privilege('anon','public.set_group_event_rsvp(uuid,text,uuid)','execute'),'anonymous cannot RSVP');
select extensions.ok(has_function_privilege('authenticated','public.set_group_event_rsvp(uuid,text,uuid)','execute'),'authenticated can RSVP');
select extensions.ok((select prosecdef from pg_proc where oid='public.create_group_event(uuid,text,timestamptz,timestamptz,text,text,uuid)'::regprocedure),'create event is security definer');
select extensions.ok((select prosecdef from pg_proc where oid='public.set_group_event_rsvp(uuid,text,uuid)'::regprocedure),'RSVP is security definer');
select extensions.ok((select pg_get_triggerdef(oid) like '%new.group_id IS NULL%' from pg_trigger where tgname='events_schedule_change_insert'),'group insert is outside personal schedule trigger');
select extensions.ok((select pg_get_triggerdef(oid) like '%new.group_id IS NULL%' from pg_trigger where tgname='events_schedule_change_update'),'group update is outside personal schedule trigger');
select extensions.ok((select pg_get_expr(polqual,polrelid) like '%group_id IS NULL%' from pg_policy where polname='events_owner_original_read'),'raw owner event read is personal-only');
select extensions.ok((select pg_get_expr(polqual,polrelid) like '%group_id IS NULL%' from pg_policy where polname='event_participants_personal_read'),'raw participant read is personal-only');
select extensions.ok((select pg_get_expr(polwithcheck,polrelid) like '%group_id IS NULL%' from pg_policy where polname='event_participants_personal_write'),'raw participant write is personal-only');

insert into auth.users(id) values
 ('a1011111-1111-4111-8111-111111111111'),('a2022222-2222-4222-8222-222222222222'),
 ('a3033333-3333-4333-8333-333333333333'),('a4044444-4444-4444-8444-444444444444') on conflict(id) do nothing;
insert into public.groups(id,owner_user_id,name,type,event_create_policy) values
 ('c1011111-1111-4111-8111-111111111111','a1011111-1111-4111-8111-111111111111','Members','other','member'),
 ('c2022222-2222-4222-8222-222222222222','a1011111-1111-4111-8111-111111111111','Admins','other','admin'),
 ('c3033333-3333-4333-8333-333333333333','a1011111-1111-4111-8111-111111111111','Owners','other','owner');
insert into public.group_members(group_id,user_id,role)
select g.id,u.id,case when u.id='a1011111-1111-4111-8111-111111111111' then 'owner' when u.id='a3033333-3333-4333-8333-333333333333' then 'admin' else 'member' end
from public.groups g cross join auth.users u
where g.id in('c1011111-1111-4111-8111-111111111111','c2022222-2222-4222-8222-222222222222','c3033333-3333-4333-8333-333333333333')
and u.id in('a1011111-1111-4111-8111-111111111111','a2022222-2222-4222-8222-222222222222','a3033333-3333-4333-8333-333333333333');
insert into public.calendars(id,owner_user_id,group_id,name) values
 ('ca101111-1111-4111-8111-111111111111','a1011111-1111-4111-8111-111111111111','c1011111-1111-4111-8111-111111111111','Members'),
 ('ca202222-2222-4222-8222-222222222222','a1011111-1111-4111-8111-111111111111','c2022222-2222-4222-8222-222222222222','Admins'),
 ('ca303333-3333-4333-8333-333333333333','a1011111-1111-4111-8111-111111111111','c3033333-3333-4333-8333-333333333333','Owners');
insert into public.events(id,owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,timezone,created_by) values
 ('e1011111-1111-4111-8111-111111111111','a2022222-2222-4222-8222-222222222222','ca101111-1111-4111-8111-111111111111','c1011111-1111-4111-8111-111111111111','Member event','group','2026-09-22 14:00+00','2026-09-22 16:00+00','Asia/Tokyo','a2022222-2222-4222-8222-222222222222'),
 ('e2022222-2222-4222-8222-222222222222','a1011111-1111-4111-8111-111111111111','ca101111-1111-4111-8111-111111111111','c1011111-1111-4111-8111-111111111111','Owner event','group','2026-09-23 14:00+00','2026-09-23 16:00+00','Asia/Tokyo','a1011111-1111-4111-8111-111111111111'),
 ('e3033333-3333-4333-8333-333333333333','a1011111-1111-4111-8111-111111111111','ca303333-3333-4333-8333-333333333333','c3033333-3333-4333-8333-333333333333','Deleted group event','group','2026-09-25 14:00+00','2026-09-25 16:00+00','Asia/Tokyo','a1011111-1111-4111-8111-111111111111');

set local request.jwt.claim.sub='a2022222-2222-4222-8222-222222222222'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select count(*) from public.create_group_event('c1011111-1111-4111-8111-111111111111','Member create','2026-09-24 23:00+09','2026-09-25 01:00+09','Tokyo','overnight','d1011111-1111-4111-8111-111111111111')),1::bigint,'member policy permits member create and overnight range');
select extensions.throws_ok($q$select * from public.create_group_event('c2022222-2222-4222-8222-222222222222','Denied','2026-09-24 10:00+09','2026-09-24 11:00+09',null,null,'d2022222-2222-4222-8222-222222222222')$q$,'42501','event creation denied','admin policy denies member');
select extensions.throws_ok($q$select * from public.create_group_event('c3033333-3333-4333-8333-333333333333','Denied','2026-09-24 10:00+09','2026-09-24 11:00+09',null,null,'d3033333-3333-4333-8333-333333333333')$q$,'42501','event creation denied','owner policy denies member');
reset role; set local request.jwt.claim.sub='a3033333-3333-4333-8333-333333333333'; set local role authenticated;
select extensions.is((select count(*) from public.create_group_event('c2022222-2222-4222-8222-222222222222','Admin create','2026-09-24 10:00+09','2026-09-24 11:00+09',null,null,'d4044444-4444-4444-8444-444444444444')),1::bigint,'admin policy permits admin');
select extensions.throws_ok($q$select * from public.create_group_event('c3033333-3333-4333-8333-333333333333','Denied','2026-09-24 10:00+09','2026-09-24 11:00+09',null,null,'d5055555-5555-4555-8555-555555555555')$q$,'42501','event creation denied','owner policy denies admin');
reset role; set local request.jwt.claim.sub='a1011111-1111-4111-8111-111111111111'; set local role authenticated;
select extensions.is((select count(*) from public.create_group_event('c3033333-3333-4333-8333-333333333333','Owner create','2026-09-24 10:00+09','2026-09-24 11:00+09',null,null,'d6066666-6666-4666-8666-666666666666')),1::bigint,'owner policy permits owner');
select extensions.is((select event_id from public.create_group_event('c3033333-3333-4333-8333-333333333333','Owner create','2026-09-24 10:00+09','2026-09-24 11:00+09',null,null,'d6066666-6666-4666-8666-666666666666')),(select event_id from public.list_group_events('c3033333-3333-4333-8333-333333333333') where title='Owner create'),'create exact replay returns original event');
select extensions.throws_ok($q$select * from public.create_group_event('c3033333-3333-4333-8333-333333333333','Changed','2026-09-24 10:00+09','2026-09-24 11:00+09',null,null,'d6066666-6666-4666-8666-666666666666')$q$,'40001','operation replay mismatch','create replay mismatch rejected');
reset role; set local request.jwt.claim.sub='a2022222-2222-4222-8222-222222222222'; set local role authenticated;
select extensions.is((select version from public.update_group_event('e1011111-1111-4111-8111-111111111111','Member edited','2026-09-22 14:00+00','2026-09-22 17:00+00','Room','Body',1,'d7077777-7777-4777-8777-777777777777')),2::bigint,'member creator edits own event');
select extensions.throws_ok($q$select * from public.update_group_event('e1011111-1111-4111-8111-111111111111','Stale','2026-09-22 14:00+00','2026-09-22 17:00+00',null,null,1,'d8088888-8888-4888-8888-888888888888')$q$,'40001','event version conflict','stale expected version rejected');
reset role; set local request.jwt.claim.sub='a4044444-4444-4444-8444-444444444444'; set local role authenticated;
select extensions.throws_ok($q$select * from public.get_group_event('e1011111-1111-4111-8111-111111111111')$q$,'42501','event access denied','nonmember read denied');
select extensions.throws_ok($q$select * from public.set_group_event_rsvp('e1011111-1111-4111-8111-111111111111','attending','d9099999-9999-4999-8999-999999999999')$q$,'42501','event access denied','nonmember RSVP denied');
reset role; set local request.jwt.claim.sub='a2022222-2222-4222-8222-222222222222'; set local role authenticated;
select extensions.is((select user_id from public.set_group_event_rsvp('e1011111-1111-4111-8111-111111111111','attending','da111111-1111-4111-8111-111111111111')),'a2022222-2222-4222-8222-222222222222'::uuid,'RSVP writes authenticated user');
select extensions.is((select status from public.set_group_event_rsvp('e1011111-1111-4111-8111-111111111111','attending','da111111-1111-4111-8111-111111111111')),'attending','RSVP exact replay succeeds');
select extensions.throws_ok($q$select * from public.set_group_event_rsvp('e1011111-1111-4111-8111-111111111111','declined','da111111-1111-4111-8111-111111111111')$q$,'40001','operation replay mismatch','RSVP replay mismatch rejected');
reset role; set local request.jwt.claim.sub='a1011111-1111-4111-8111-111111111111'; set local role authenticated;
select extensions.is((select count(*) from public.list_group_event_rsvps('e1011111-1111-4111-8111-111111111111')),3::bigint,'RSVP projection includes all active members');
select extensions.is((select count(*) from public.list_group_event_rsvps('e1011111-1111-4111-8111-111111111111') where status='unanswered'),2::bigint,'missing responses project unanswered');
reset role; set local request.jwt.claim.sub='a2022222-2222-4222-8222-222222222222'; set local role authenticated;
select extensions.is((select count(*) from public.events where id='e1011111-1111-4111-8111-111111111111'),0::bigint,'raw group event hidden from creator');
reset role;
select extensions.is((select count(*) from private.schedule_change_log where entity_type='event' and entity_id in('e1011111-1111-4111-8111-111111111111','e2022222-2222-4222-8222-222222222222')),0::bigint,'group events never enter personal delta');
set local request.jwt.claim.sub='a3033333-3333-4333-8333-333333333333'; set local role authenticated;
select extensions.is((select version from public.update_group_event('e1011111-1111-4111-8111-111111111111','Admin edited','2026-09-22 14:00+00','2026-09-22 18:00+00',null,null,2,'db111111-1111-4111-8111-111111111111')),3::bigint,'admin edits another creator event');
reset role; set local request.jwt.claim.sub='a2022222-2222-4222-8222-222222222222'; set local role authenticated;
select extensions.throws_ok($q$select public.cancel_group_event('e2022222-2222-4222-8222-222222222222',1,'dc111111-1111-4111-8111-111111111111')$q$,'42501','event cancel denied','member cannot cancel owner event');
reset role; set local request.jwt.claim.sub='a1011111-1111-4111-8111-111111111111'; set local role authenticated;
select extensions.lives_ok($q$select public.cancel_group_event('e2022222-2222-4222-8222-222222222222',1,'dd111111-1111-4111-8111-111111111111')$q$,'owner cancels event');
select extensions.lives_ok($q$select public.cancel_group_event('e2022222-2222-4222-8222-222222222222',1,'dd111111-1111-4111-8111-111111111111')$q$,'cancel exact replay succeeds');
reset role; set local request.jwt.claim.sub='a2022222-2222-4222-8222-222222222222'; set local role authenticated;
select extensions.throws_ok($q$select * from public.set_group_event_rsvp('e2022222-2222-4222-8222-222222222222','attending','de111111-1111-4111-8111-111111111111')$q$,'42501','event access denied','cancelled event rejects RSVP');
reset role; delete from public.group_members where group_id='c1011111-1111-4111-8111-111111111111' and user_id='a2022222-2222-4222-8222-222222222222';
set local request.jwt.claim.sub='a2022222-2222-4222-8222-222222222222'; set local role authenticated;
select extensions.throws_ok($q$select * from public.update_group_event('e1011111-1111-4111-8111-111111111111','After removal','2026-09-22 14:00+00','2026-09-22 18:00+00',null,null,3,'df111111-1111-4111-8111-111111111111')$q$,'42501','event edit denied','removed creator cannot edit');
reset role; set local request.jwt.claim.sub='a1011111-1111-4111-8111-111111111111'; set local role authenticated;
select extensions.lives_ok($q$select public.delete_group('c3033333-3333-4333-8333-333333333333','da222222-2222-4222-8222-222222222222')$q$,'owner deletes synthetic group');
select extensions.throws_ok($q$select * from public.get_group_event('e3033333-3333-4333-8333-333333333333')$q$,'42501','event access denied','deleted group invalidates event detail');

reset role;
select * from extensions.finish();
rollback;
