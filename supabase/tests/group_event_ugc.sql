begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(64);

select extensions.ok(to_regprocedure('public.list_group_event_comments(uuid)') is not null,'comment list RPC exists');
select extensions.ok(to_regprocedure('public.create_group_event_comment(uuid,text,uuid)') is not null,'comment create RPC exists');
select extensions.ok(to_regprocedure('public.update_group_event_comment(uuid,text,bigint,uuid)') is not null,'comment update RPC exists');
select extensions.ok(to_regprocedure('public.delete_group_event_comment(uuid,bigint,uuid)') is not null,'comment delete RPC exists');
select extensions.ok(to_regprocedure('public.moderate_delete_group_event_comment(uuid,uuid)') is not null,'moderation delete RPC exists');
select extensions.ok(to_regprocedure('public.list_group_event_reactions(uuid)') is not null,'reaction list RPC exists');
select extensions.ok(to_regprocedure('public.set_group_event_reaction(uuid,text,uuid)') is not null,'reaction set RPC exists');
select extensions.ok(to_regprocedure('public.remove_group_event_reaction(uuid,text,uuid)') is not null,'reaction remove RPC exists');
select extensions.ok(to_regprocedure('public.create_group_content_report(text,uuid,text,uuid)') is not null,'report RPC exists');
select extensions.ok(to_regprocedure('public.validate_group_event_ugc(uuid,text)') is not null,'combined read validation RPC exists');
select extensions.ok(not has_table_privilege('authenticated','public.event_comments','SELECT'),'raw comments denied');
select extensions.ok(not has_table_privilege('authenticated','public.event_reactions','SELECT'),'raw reactions denied');
select extensions.ok(not has_table_privilege('authenticated','public.reports','INSERT'),'raw reports denied');
select extensions.ok(not has_function_privilege('anon','public.create_group_event_comment(uuid,text,uuid)','EXECUTE'),'anonymous comment denied');
select extensions.ok(not has_function_privilege('public','public.create_group_content_report(text,uuid,text,uuid)','EXECUTE'),'PUBLIC report denied');
select extensions.ok(not has_function_privilege('anon','public.get_group_event_ugc(uuid)','EXECUTE'),'anonymous combined read denied');
select extensions.ok(not has_function_privilege('anon','public.validate_group_event_ugc(uuid,text)','EXECUTE'),'anonymous combined validation denied');
select extensions.ok(has_function_privilege('authenticated','public.validate_group_event_ugc(uuid,text)','EXECUTE'),'authenticated combined validation granted');
select extensions.ok(not has_function_privilege('authenticated','private.phase13_raw_event_group(uuid)','EXECUTE'),'private event helper denied');
select extensions.ok((select prosecdef from pg_proc where oid='public.create_group_event_comment(uuid,text,uuid)'::regprocedure),'comment create is security definer');
select extensions.ok((select prosecdef from pg_proc where oid='public.create_group_content_report(text,uuid,text,uuid)'::regprocedure),'report create is security definer');

insert into auth.users(id) values
 ('b1011111-1111-4111-8111-111111111111'),
 ('b2022222-2222-4222-8222-222222222222'),
 ('b3033333-3333-4333-8333-333333333333'),
 ('b4044444-4444-4444-8444-444444444444') on conflict(id) do nothing;
insert into public.groups(id,owner_user_id,name,type,event_create_policy) values
 ('b5055555-5555-4555-8555-555555555555','b1011111-1111-4111-8111-111111111111','UGC Group','other','member');
insert into public.group_members(group_id,user_id,role) values
 ('b5055555-5555-4555-8555-555555555555','b1011111-1111-4111-8111-111111111111','owner'),
 ('b5055555-5555-4555-8555-555555555555','b2022222-2222-4222-8222-222222222222','member'),
 ('b5055555-5555-4555-8555-555555555555','b3033333-3333-4333-8333-333333333333','admin');
insert into public.calendars(id,owner_user_id,group_id,name) values
 ('b6066666-6666-4666-8666-666666666666','b1011111-1111-4111-8111-111111111111','b5055555-5555-4555-8555-555555555555','UGC Group');
insert into public.events(id,owner_user_id,calendar_id,group_id,title,kind,start_at,end_at,timezone,created_by) values
 ('b7077777-7777-4777-8777-777777777777','b1011111-1111-4111-8111-111111111111','b6066666-6666-4666-8666-666666666666','b5055555-5555-4555-8555-555555555555','UGC Event','group','2026-09-24 10:00+09','2026-09-24 11:00+09','Asia/Tokyo','b1011111-1111-4111-8111-111111111111');

set local request.jwt.claim.sub='b1011111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
create temp table phase13_generation on commit drop as
  select generation from public.get_group_event_ugc('b7077777-7777-4777-8777-777777777777');
select extensions.is((select valid from public.validate_group_event_ugc('b7077777-7777-4777-8777-777777777777',(select generation from phase13_generation))),true,'current content generation validates');
select extensions.is((select author_user_id from public.create_group_event_comment('b7077777-7777-4777-8777-777777777777','初回コメント','b8088888-8888-4888-8888-888888888888')),'b1011111-1111-4111-8111-111111111111'::uuid,'author is bound to auth.uid');
select extensions.is((select count(*) from public.create_group_event_comment('b7077777-7777-4777-8777-777777777777','初回コメント','b8088888-8888-4888-8888-888888888888')),1::bigint,'comment create exact replay is idempotent');
select extensions.throws_ok($q$select * from public.create_group_event_comment('b7077777-7777-4777-8777-777777777777','別本文','b8088888-8888-4888-8888-888888888888')$q$,'40001','operation replay mismatch','comment create replay mismatch rejected');
select extensions.is((select count(*) from public.list_group_event_comments('b7077777-7777-4777-8777-777777777777')),1::bigint,'author lists active comment');
create temp table phase13_comment_id on commit drop as
  select comment_id from public.list_group_event_comments('b7077777-7777-4777-8777-777777777777') limit 1;
select extensions.is((select version from public.update_group_event_comment((select comment_id from phase13_comment_id),'編集済み',1,'b8288888-8888-4888-8888-888888888888')),2::bigint,'author updates expected version');
select extensions.is((select version from public.update_group_event_comment((select comment_id from phase13_comment_id),'編集済み',1,'b8288888-8888-4888-8888-888888888888')),2::bigint,'update exact replay keeps version unchanged');
select extensions.throws_ok($q$select * from public.update_group_event_comment((select comment_id from phase13_comment_id),'別編集',1,'b8288888-8888-4888-8888-888888888888')$q$,'40001','operation replay mismatch','update replay mismatch rejected');
select extensions.is((select count(*) from public.create_group_event_comment('b7077777-7777-4777-8777-777777777777',repeat('x',2000),'b8388888-8888-4888-8888-888888888888')),1::bigint,'comment accepts 2000 characters');
select extensions.throws_ok($q$select * from public.create_group_event_comment('b7077777-7777-4777-8777-777777777777',repeat('x',2001),'b8488888-8888-4888-8888-888888888888')$q$,'22023','invalid comment','comment rejects 2001 characters');

reset role; set local request.jwt.claim.sub='b2022222-2222-4222-8222-222222222222'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.throws_ok($q$select * from public.update_group_event_comment((select comment_id from phase13_comment_id),'他人書換',2,'b8488888-8888-4888-8888-888888888888')$q$,'42501',NULL,'viewer cannot rewrite author');
select extensions.is((select reaction from public.set_group_event_reaction('b7077777-7777-4777-8777-777777777777','ok','b8588888-8888-4888-8888-888888888888')),'ok','viewer adds fixed reaction');
select extensions.is((select count(*) from public.set_group_event_reaction('b7077777-7777-4777-8777-777777777777','ok','b8588888-8888-4888-8888-888888888888')),1::bigint,'reaction exact replay is idempotent');
select extensions.throws_ok($q$select * from public.set_group_event_reaction('b7077777-7777-4777-8777-777777777777','thanks','b8588888-8888-4888-8888-888888888888')$q$,'40001','operation replay mismatch','reaction replay mismatch rejected');
select extensions.is((select reaction_count from public.list_group_event_reactions('b7077777-7777-4777-8777-777777777777') where reaction='ok'),1::bigint,'reaction count visible');
select extensions.is((select count(*) from public.remove_group_event_reaction('b7077777-7777-4777-8777-777777777777','ok','b8688888-8888-4888-8888-888888888888')),1::bigint,'viewer removes own reaction');
reset role; set local request.jwt.claim.sub='b1011111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select reaction from public.set_group_event_reaction('b7077777-7777-4777-8777-777777777777','thanks','b8788888-8888-4888-8888-888888888887')),'thanks','author adds reaction');
reset role; set local request.jwt.claim.sub='b2022222-2222-4222-8222-222222222222'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select reaction_count from public.list_group_event_reactions('b7077777-7777-4777-8777-777777777777') where reaction='thanks'),1::bigint,'other user reaction remains immutable');
select extensions.throws_ok($q$select * from public.set_group_event_reaction('b7077777-7777-4777-8777-777777777777','nope','b8788888-8888-4888-8888-888888888888')$q$,'22023','invalid reaction','unknown preset rejected');
select extensions.is((select status from public.create_group_content_report('event','b7077777-7777-4777-8777-777777777777','内容確認','b8888888-8888-4888-8888-888888888888')),'pending','event report reaches pending sink');
select extensions.is((select report_id from public.create_group_content_report('event','b7077777-7777-4777-8777-777777777777','内容確認','b8888888-8888-4888-8888-888888888888')),(select report_id from public.create_group_content_report('event','b7077777-7777-4777-8777-777777777777','内容確認','b8888888-8888-4888-8888-888888888888')),'report exact replay returns same receipt');
select extensions.throws_ok($q$select * from public.create_group_content_report('event','b7077777-7777-4777-8777-777777777777','別理由','b8888888-8888-4888-8888-888888888888')$q$,'40001','operation replay mismatch','report replay mismatch rejected');
select extensions.is((select status from public.create_group_content_report('comment',(select comment_id from phase13_comment_id),'コメント確認','b8988888-8888-4888-8888-888888888888')),'pending','comment report reaches pending sink');

reset role; insert into public.blocks(blocker_user_id,blocked_user_id)
values('b1011111-1111-4111-8111-111111111111','b2022222-2222-4222-8222-222222222222') on conflict do nothing;
set local request.jwt.claim.sub='b2022222-2222-4222-8222-222222222222'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select count(*) from public.list_group_event_comments('b7077777-7777-4777-8777-777777777777')),2::bigint,'block does not hide shared event content');

reset role; set local request.jwt.claim.sub='b1011111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select count(*) from public.create_group_event_comment('b7077777-7777-4777-8777-777777777777','削除競合対象','b8a88888-8888-4888-8888-888888888888')),1::bigint,'author creates deletion target');
create temp table phase13_delete_comment_id on commit drop as
  select comment_id from public.list_group_event_comments('b7077777-7777-4777-8777-777777777777') where body='削除競合対象' limit 1;

reset role; set local request.jwt.claim.sub='b2022222-2222-4222-8222-222222222222'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.throws_ok($q$select public.moderate_delete_group_event_comment((select comment_id from phase13_delete_comment_id),'b8b88888-8888-4888-8888-888888888888')$q$,'42501','moderation denied','member cannot moderate delete');

reset role; set local request.jwt.claim.sub='b1011111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.lives_ok($q$select public.delete_group_event_comment((select comment_id from phase13_delete_comment_id),1,'b8c88888-8888-4888-8888-888888888888')$q$,'author soft deletes own comment');
select extensions.throws_ok($q$select public.delete_group_event_comment((select comment_id from phase13_delete_comment_id),1,'b8c88888-8888-4888-8888-888888888888')$q$,'42501',NULL,'deleted target is not revived by exact replay');
select extensions.is((select count(*) from public.create_group_event_comment('b7077777-7777-4777-8777-777777777777','競合削除対象','b8d88888-8888-4888-8888-888888888888')),1::bigint,'author creates conflict target');
create temp table phase13_conflict_comment_id on commit drop as
  select comment_id from public.list_group_event_comments('b7077777-7777-4777-8777-777777777777') where body='競合削除対象' limit 1;
select extensions.is((select version from public.update_group_event_comment((select comment_id from phase13_conflict_comment_id),'競合更新',1,'b8e88888-8888-4888-8888-888888888888')),2::bigint,'author updates delete conflict target');
select extensions.throws_ok($q$select public.delete_group_event_comment((select comment_id from phase13_conflict_comment_id),1,'b8f88888-8888-4888-8888-888888888888')$q$,'40001','comment version conflict','self delete stale version rejected');
select extensions.is((select count(*) from public.create_group_event_comment('b7077777-7777-4777-8777-777777777777','Owner管理削除対象','b9099999-9999-4999-8999-999999999998')),1::bigint,'owner creates moderation target');
create temp table phase13_owner_moderation_id on commit drop as
  select comment_id from public.list_group_event_comments('b7077777-7777-4777-8777-777777777777') where body='Owner管理削除対象' limit 1;
select extensions.lives_ok($q$select public.moderate_delete_group_event_comment((select comment_id from phase13_owner_moderation_id),'b9099999-9999-4999-8999-999999999999')$q$,'owner can moderate delete');
select extensions.throws_ok($q$select public.moderate_delete_group_event_comment((select comment_id from phase13_owner_moderation_id),'b9099999-9999-4999-8999-999999999999')$q$,'42501',NULL,'moderation replay does not revive deleted comment');

reset role; set local request.jwt.claim.sub='b3033333-3333-4333-8333-333333333333'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.lives_ok($q$select public.moderate_delete_group_event_comment((select comment_id from phase13_comment_id),'b8988888-8888-4888-8888-888888888888')$q$,'admin can moderate delete');
select extensions.is((select count(*) from public.list_group_event_comments('b7077777-7777-4777-8777-777777777777') where comment_id=(select comment_id from phase13_comment_id)),0::bigint,'moderated comment is hidden');
select extensions.throws_ok($q$select * from public.create_group_content_report('comment',(select comment_id from phase13_comment_id),'削除済み','b8a88888-8888-4888-8888-888888888888')$q$,'42501','report target unavailable','deleted comment cannot be reported');

reset role; set local request.jwt.claim.sub='b4044444-4444-4444-8444-444444444444'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.throws_ok($q$select * from public.list_group_event_comments('b7077777-7777-4777-8777-777777777777')$q$,'42501','event access denied','outsider is denied');
select extensions.throws_ok($q$select * from public.create_group_content_report('event','b7077777-7777-4777-8777-777777777777','外部通報','b9099999-9999-4999-8999-999999999999')$q$,'42501','report target unavailable','report requires accessible event');

reset role; delete from public.group_members where group_id='b5055555-5555-4555-8555-555555555555' and user_id='b2022222-2222-4222-8222-222222222222';
set local request.jwt.claim.sub='b1011111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select valid from public.validate_group_event_ugc('b7077777-7777-4777-8777-777777777777',(select generation from phase13_generation))),false,'removed membership invalidates old generation');
set local request.jwt.claim.sub='b2022222-2222-4222-8222-222222222222'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.throws_ok($q$select * from public.list_group_event_reactions('b7077777-7777-4777-8777-777777777777')$q$,'42501','event access denied','ex-member cannot read UGC');

reset role;
insert into public.group_members(group_id,user_id,role,joined_at)
values('b5055555-5555-4555-8555-555555555555','b2022222-2222-4222-8222-222222222222','member',now()+interval '1 minute');
set local request.jwt.claim.sub='b1011111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select valid from public.validate_group_event_ugc('b7077777-7777-4777-8777-777777777777',(select generation from phase13_generation))),false,'same-role rejoin joined_at invalidates old generation');
reset role;
select extensions.is((select count(*) from public.reports where target_id='b7077777-7777-4777-8777-777777777777' and status='pending'),1::bigint,'report row is durable pending record');
select * from extensions.finish();
rollback;
