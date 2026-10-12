begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(41);

insert into auth.users (id) values
  ('a1011111-1111-4111-8111-111111111111'),
  ('a2022222-2222-4222-8222-222222222222'),
  ('a3033333-3333-4333-8333-333333333333')
on conflict (id) do nothing;
update public.profiles set display_name = case user_id
  when 'a1011111-1111-4111-8111-111111111111' then 'Owner'
  when 'a2022222-2222-4222-8222-222222222222' then 'Member'
  else 'Third' end
where user_id in ('a1011111-1111-4111-8111-111111111111','a2022222-2222-4222-8222-222222222222','a3033333-3333-4333-8333-333333333333');

select extensions.ok(not pg_catalog.has_table_privilege('authenticated','public.groups','SELECT'),'raw groups denied');
select extensions.ok(not pg_catalog.has_table_privilege('authenticated','public.group_members','SELECT'),'raw members denied');
select extensions.ok(not pg_catalog.has_table_privilege('authenticated','public.group_invitations','SELECT'),'raw invites denied');
select extensions.ok(not pg_catalog.has_function_privilege('anon','public.create_group(text,text,text,text,uuid)','EXECUTE'),'anonymous create denied');
select extensions.ok(not pg_catalog.has_function_privilege('authenticated','private.group_lock(uuid,uuid,text,text)','EXECUTE'),'private receipt helper denied');
select extensions.ok(exists(select 1 from pg_indexes where indexname='group_one_owner_idx'),'owner uniqueness index exists');
select extensions.ok(exists(select 1 from pg_trigger where tgname='group_owner_invariant'),'deferred owner invariant exists');

set local request.jwt.claims='{"sub":"a1011111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub='a1011111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select count(*) from public.create_group('TAP Group','course','desc','member','b1011111-1111-4111-8111-111111111111')),1::bigint,'create succeeds');
select extensions.is((select group_id from public.create_group('TAP Group','course','desc','member','b1011111-1111-4111-8111-111111111111')),(select group_id from public.list_my_groups() limit 1),'create replay returns same group');
select extensions.throws_ok($q$select * from public.create_group('Different','course',null,'member','b1011111-1111-4111-8111-111111111111')$q$,'40001','operation replay mismatch','changed create replay rejected');
select extensions.is((select count(*) from public.list_my_groups()),1::bigint,'create replay made one group');
select extensions.is((select role from public.get_group((select group_id from public.list_my_groups() limit 1))),'owner','creator is owner');
select extensions.is((select name from public.update_group((select group_id from public.list_my_groups() limit 1),'Updated Group','seminar','updated','admin','b1111111-1111-4111-8111-111111111111')),'Updated Group','owner updates group');
select extensions.is((select name from public.update_group((select group_id from public.list_my_groups() limit 1),'Updated Group','seminar','updated','admin','b1111111-1111-4111-8111-111111111111')),'Updated Group','update replay returns original response');
select extensions.throws_ok($q$select public.delete_group((select group_id from public.list_my_groups() limit 1),'b1111111-1111-4111-8111-111111111111')$q$,'40001','operation replay mismatch','operation id cannot cross operation names');
select extensions.is((select token from public.create_group_invite((select group_id from public.list_my_groups() limit 1),'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',now()+interval '1 day',2,'b2022222-2222-4222-8222-222222222222')),'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','invite returns caller secret');
select extensions.is((select status from public.preview_group_invite('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')),'active','invite preview is active');

reset role;
select extensions.is((select count(*) from private.group_operation_receipts where response::text like '%aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa%'),0::bigint,'receipt stores no plaintext invite secret');
set local request.jwt.claims='{"sub":"a3033333-3333-4333-8333-333333333333","role":"authenticated"}'; set local request.jwt.claim.sub='a3033333-3333-4333-8333-333333333333'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.throws_ok($q$select * from public.get_group((select group_id from public.preview_group_invite('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')))$q$,'42501','group access denied','nonmember detail denied');

reset role;
set local request.jwt.claims='{"sub":"a2022222-2222-4222-8222-222222222222","role":"authenticated"}'; set local request.jwt.claim.sub='a2022222-2222-4222-8222-222222222222'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select role from public.join_group_invite('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','b3033333-3333-4333-8333-333333333333')),'member','member explicitly joins');
select extensions.is((select count(*) from public.join_group_invite('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','b3033333-3333-4333-8333-333333333333')),1::bigint,'exact join replay returns response');
select extensions.is((select role from public.get_group((select group_id from public.list_my_groups() limit 1))),'member','member detail allowed');
select extensions.throws_ok($q$select * from public.list_group_invites((select group_id from public.list_my_groups() limit 1))$q$,'42501','admin required','member invite list denied');

reset role;
set local request.jwt.claims='{"sub":"a1011111-1111-4111-8111-111111111111","role":"authenticated"}'; set local request.jwt.claim.sub='a1011111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select used_count from public.list_group_invites((select group_id from public.list_my_groups() limit 1)) limit 1),1,'join increments usage once');

reset role;
set local request.jwt.claims='{"sub":"a3033333-3333-4333-8333-333333333333","role":"authenticated"}'; set local request.jwt.claim.sub='a3033333-3333-4333-8333-333333333333'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select role from public.join_group_invite('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','b3133333-3333-4333-8333-333333333333')),'member','second member joins');
select extensions.is((select status from public.preview_group_invite('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')),'exhausted','max uses enforced in preview');

reset role;
set local request.jwt.claims='{"sub":"a1011111-1111-4111-8111-111111111111","role":"authenticated"}'; set local request.jwt.claim.sub='a1011111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select public.change_group_member_role((select group_id from public.list_my_groups() limit 1),'a2022222-2222-4222-8222-222222222222','admin','b4044444-4444-4444-8444-444444444444');
select extensions.is((select role from public.list_group_members((select group_id from public.list_my_groups() limit 1)) where user_id='a2022222-2222-4222-8222-222222222222'),'admin','owner promotes admin');

reset role;
set local request.jwt.claims='{"sub":"a2022222-2222-4222-8222-222222222222","role":"authenticated"}'; set local request.jwt.claim.sub='a2022222-2222-4222-8222-222222222222'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.throws_ok($q$select public.transfer_group_ownership((select group_id from public.list_my_groups() limit 1),'a3033333-3333-4333-8333-333333333333','b5055555-5555-4555-8555-555555555555')$q$,'42501','ownership transfer denied','admin cannot transfer ownership');
select extensions.throws_ok($q$select public.remove_group_member((select group_id from public.list_my_groups() limit 1),'a1011111-1111-4111-8111-111111111111','b5155555-5555-4555-8555-555555555555')$q$,'42501','member removal denied','admin cannot remove owner');

reset role;
set local request.jwt.claims='{"sub":"a1011111-1111-4111-8111-111111111111","role":"authenticated"}'; set local request.jwt.claim.sub='a1011111-1111-4111-8111-111111111111'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select public.transfer_group_ownership((select group_id from public.list_my_groups() limit 1),'a2022222-2222-4222-8222-222222222222','b6066666-6666-4666-8666-666666666666');
select extensions.is((select count(*) from public.list_group_members((select group_id from public.list_my_groups() limit 1)) where role='owner'),1::bigint,'transfer leaves exactly one owner');
select extensions.throws_ok($q$select public.delete_group((select group_id from public.list_my_groups() limit 1),'b6166666-6666-4666-8666-666666666666')$q$,'42501','owner required','old owner cannot delete');

reset role;
set local request.jwt.claims='{"sub":"a2022222-2222-4222-8222-222222222222","role":"authenticated"}'; set local request.jwt.claim.sub='a2022222-2222-4222-8222-222222222222'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select public.remove_group_member((select group_id from public.list_my_groups() limit 1),'a3033333-3333-4333-8333-333333333333','b7077777-7777-4777-8777-777777777777');
select extensions.is((select count(*) from public.list_group_members((select group_id from public.list_my_groups() limit 1)) where user_id='a3033333-3333-4333-8333-333333333333'),0::bigint,'owner removes member');

reset role;
set local request.jwt.claims='{"sub":"a3033333-3333-4333-8333-333333333333","role":"authenticated"}'; set local request.jwt.claim.sub='a3033333-3333-4333-8333-333333333333'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.throws_ok($q$select * from public.get_group((select group_id from public.preview_group_invite('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')))$q$,'42501','group access denied','removed member detail denied');
select extensions.throws_ok($q$select * from public.join_group_invite('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa','b3133333-3333-4333-8333-333333333333')$q$,'42501','membership no longer active','old join replay cannot restore removed member');

reset role;
set local request.jwt.claims='{"sub":"a2022222-2222-4222-8222-222222222222","role":"authenticated"}'; set local request.jwt.claim.sub='a2022222-2222-4222-8222-222222222222'; set local request.jwt.claim.role='authenticated'; set local role authenticated;
select extensions.is((select token from public.create_group_invite((select group_id from public.list_my_groups() limit 1),'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',now()+interval '1 day',1,'b8088888-8888-4888-8888-888888888888')),'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','new owner creates invite');
select public.revoke_group_invite((select group_id from public.list_my_groups() limit 1),(select invite_id from public.list_group_invites((select group_id from public.list_my_groups() limit 1)) where used_count=0 limit 1),'b8188888-8888-4888-8888-888888888888');
select extensions.is((select status from public.preview_group_invite('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')),'revoked','revoked invite is unusable');
select public.delete_group((select group_id from public.list_my_groups() limit 1),'b9099999-9999-4999-8999-999999999999');
select extensions.is((select count(*) from public.preview_group_invite('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')),0::bigint,'deleted group invite preview disappears');
select extensions.is((select count(*) from public.list_my_groups()),0::bigint,'deleted group leaves active list');
select extensions.throws_ok($q$select * from public.join_group_invite('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','ba111111-1111-4111-8111-111111111111')$q$,'42501','group unavailable','deleted group cannot be joined');

reset role;
select extensions.is((select count(*) from public.groups where deleted_at is not null and name='Updated Group'),1::bigint,'delete is a single soft-deleted group');
select extensions.is((select count(*) from public.group_invitations i join public.groups g on g.id=i.group_id where g.name='Updated Group' and i.revoked_at is null),0::bigint,'delete revokes all invites');
select * from extensions.finish();
rollback;
