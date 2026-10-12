begin;
create extension if not exists pgtap with schema extensions;
select extensions.plan(36);

insert into auth.users(id) values
  ('a1111111-1111-4111-8111-111111111111'),
  ('a2222222-2222-4222-8222-222222222222'),
  ('a3333333-3333-4333-8333-333333333333'),
  ('a4444444-4444-4444-8444-444444444444'),
  ('a5555555-5555-4555-8555-555555555555')
on conflict (id) do nothing;

update public.profiles set display_name = case user_id
  when 'a1111111-1111-4111-8111-111111111111' then 'Caller'
  when 'a2222222-2222-4222-8222-222222222222' then 'Visible Target'
  when 'a3333333-3333-4333-8333-333333333333' then 'Hidden Target'
  when 'a4444444-4444-4444-8444-444444444444' then 'Deleted Target'
  else 'Reverse Block Target' end,
  username = null,
  searchable_by_username = false,
  deleted_at = null
where user_id between 'a1111111-1111-4111-8111-111111111111'::uuid
                   and 'a5555555-5555-4555-8555-555555555555'::uuid;

update public.profiles set username='visible_user', searchable_by_username=true
where user_id='a2222222-2222-4222-8222-222222222222';
update public.profiles set username='hidden_user'
where user_id='a3333333-3333-4333-8333-333333333333';
update public.profiles set username='deleted_user', searchable_by_username=true,
  deleted_at=now()
where user_id='a4444444-4444-4444-8444-444444444444';
update public.profiles set username='reverse_block', searchable_by_username=true
where user_id='a5555555-5555-4555-8555-555555555555';

do $$
declare existing public.friendships%rowtype;
begin
  insert into public.friendships(requester_user_id, addressee_user_id, status)
  values ('a1111111-1111-4111-8111-111111111111',
          'a3333333-3333-4333-8333-333333333333', 'accepted')
  returning * into existing;
  insert into public.friend_visibility_rules
    (friendship_id, relationship_incarnation, owner_user_id, friend_user_id,
     target_kind, mode, visibility_level)
  values
    (existing.id, existing.incarnation, existing.requester_user_id,
     existing.addressee_user_id, 'default', 'explicit', 'PRIVATE'),
    (existing.id, existing.incarnation, existing.addressee_user_id,
     existing.requester_user_id, 'default', 'explicit', 'PRIVATE');
end;
$$;

set local request.jwt.claims = '{"sub":"a1111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = 'a1111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.ok(
  not (select searchable_by_username from public.profiles where user_id=auth.uid()),
  'username discovery defaults to off'
);
select extensions.is(
  public.set_my_friend_username('Caller_Name', false)->>'username',
  'caller_name',
  'owner RPC stores a normalized lowercase username'
);
select extensions.ok(
  not (public.get_my_friend_username()->>'searchable_by_username')::boolean,
  'owner profile RPC reports the private default'
);
select extensions.throws_ok(
  $sql$ update public.profiles set username='Bad Name' where user_id=auth.uid() $sql$,
  '22023', 'username must be normalized lowercase ASCII',
  'direct profile writes cannot bypass canonical username validation'
);
select extensions.throws_ok(
  $sql$ update public.profiles set searchable_by_username=true, username=null where user_id=auth.uid() $sql$,
  '22023', 'username discovery requires a username',
  'direct profile writes cannot opt in without a username'
);
select extensions.is(
  (select count(*) from public.profiles where user_id='a2222222-2222-4222-8222-222222222222'),
  0::bigint,
  'profile row policy remains self-only'
);
select extensions.is(
  (public.set_my_friend_username('Caller_Name', true)->>'searchable_by_username')::boolean,
  true,
  'owner can opt in with a username'
);
select extensions.is(
  (select count(*) from public.find_friend_by_username('VISIBLE_USER')),
  1::bigint,
  'case-insensitive exact lookup returns a single visible match'
);
select extensions.is(
  (select count(*) from jsonb_object_keys(
    (select to_jsonb(f) from public.find_friend_by_username('visible_user') f)
  )),
  3::bigint,
  'lookup returns only user id, username, and display name'
);
select extensions.is(
  (select user_id from public.find_friend_by_username('visible_user')),
  'a2222222-2222-4222-8222-222222222222'::uuid,
  'lookup returns the expected opted-in profile'
);
select extensions.is(
  (select count(*) from public.find_friend_by_username('caller_name')),
  0::bigint,
  'lookup excludes the caller'
);
select extensions.is(
  (select count(*) from public.find_friend_by_username('hidden_user')),
  0::bigint,
  'lookup hides profiles that did not opt in'
);
select extensions.is(
  (select count(*) from public.find_friend_by_username('deleted_user')),
  0::bigint,
  'lookup hides deleted profiles'
);
select extensions.is(
  (select count(*) from public.find_friend_by_username('visible')),
  0::bigint,
  'lookup does not return prefixes'
);
select extensions.is(
  (select count(*) from public.find_friend_by_username('visible%')),
  0::bigint,
  'lookup treats wildcard characters as invalid input'
);
select extensions.is(
  (select count(*) from public.find_friend_by_username('not valid')),
  0::bigint,
  'lookup rejects non-ASCII identifier syntax uniformly'
);
select extensions.ok(
  pg_catalog.has_function_privilege('authenticated','public.find_friend_by_username(text)','EXECUTE')
  and not pg_catalog.has_function_privilege('anon','public.find_friend_by_username(text)','EXECUTE')
  and not pg_catalog.has_function_privilege('service_role','public.find_friend_by_username(text)','EXECUTE')
  and not pg_catalog.has_function_privilege('service_role','public.find_friend_by_username(text)','EXECUTE'),
  'only authenticated users can execute discovery lookup'
);
select extensions.ok(
  not exists (
    select 1 from pg_catalog.pg_proc p
    cross join lateral pg_catalog.aclexplode(
      coalesce(p.proacl, pg_catalog.acldefault('f', p.proowner))
    ) acl
    where p.oid='public.request_friend_by_username(uuid,text,uuid)'::regprocedure
      and acl.grantee=0 and acl.privilege_type='EXECUTE'
  )
  and not pg_catalog.has_function_privilege('anon','public.request_friend_by_username(uuid,text,uuid)','EXECUTE'),
  'request mutation is not executable by public or anon'
);
select extensions.is(
  (public.request_friend_by_username(
    'a2222222-2222-4222-8222-222222222222','visible_user',
    'b1111111-1111-4111-8111-111111111111')->>'status'),
  'pending',
  'confirmed username request waits for approval'
);
select extensions.is(
  (select value->>'requester_user_id' from public.list_friendships() as x(value)
    where value->>'other_user_id'='a2222222-2222-4222-8222-222222222222'),
  'a1111111-1111-4111-8111-111111111111',
  'new request keeps the caller as requester'
);
select extensions.is(
  (select count(*) from public.list_friendships() as x(value)
    where value->>'other_user_id'='a2222222-2222-4222-8222-222222222222'
      and value->>'status'='accepted'),
  0::bigint,
  'username request does not auto-accept'
);
select extensions.is(
  (public.request_friend_by_username(
    'a2222222-2222-4222-8222-222222222222','visible_user',
    'b2222222-2222-4222-8222-222222222222')->>'status'),
  'pending',
  'duplicate request preserves the original pending relationship'
);
select extensions.is(
  (public.request_friend_by_username(
    'a2222222-2222-4222-8222-222222222222','visible_user',
    'b1111111-1111-4111-8111-111111111111')->>'status'),
  'pending',
  'same operation replay returns the current eligible pending relationship'
);
select extensions.throws_ok(
  $sql$ select public.set_my_friend_username('VISIBLE_USER', true) $sql$,
  '23505',
  null,
  'duplicate username settings are rejected case-insensitively'
);
select extensions.throws_ok(
  $sql$ select public.request_friend_by_username(
    'a2222222-2222-4222-8222-222222222222','renamed_user',
    'b3333333-3333-4333-8333-333333333333') $sql$,
  'PT409', 'friend username changed after confirmation',
  'confirmation is bound to the username the caller saw'
);
select extensions.throws_ok(
  $sql$ select public.request_friend_by_username(
    'a3333333-3333-4333-8333-333333333333','hidden_user',
    'b4444444-4444-4444-8444-444444444444') $sql$,
  '42501', 'friend username target is unavailable',
  'ineligible targets have the same unavailable response'
);

reset role;
set local request.jwt.claims = '{"sub":"a3333333-3333-4333-8333-333333333333","role":"authenticated"}';
set local request.jwt.claim.sub = 'a3333333-3333-4333-8333-333333333333';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select public.set_my_friend_username('hidden_user', true);

reset role;
set local request.jwt.claims = '{"sub":"a1111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = 'a1111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.is(
  (public.request_friend_by_username(
    'a3333333-3333-4333-8333-333333333333','hidden_user',
    'b9999999-9999-4999-8999-999999999999')->>'status'),
  'accepted',
  'request to an existing accepted relationship stays accepted'
);
select extensions.is(
  (public.request_friend_by_username(
    'a3333333-3333-4333-8333-333333333333','hidden_user',
    'baaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')->>'friendship_id'),
  (select value->>'friendship_id' from public.list_friendships() as x(value)
    where value->>'other_user_id'='a3333333-3333-4333-8333-333333333333'),
  'accepted relationship identity is unchanged by username request'
);

reset role;
set local request.jwt.claims = '{"sub":"a2222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = 'a2222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.is(
  (public.request_friend_by_username(
    'a1111111-1111-4111-8111-111111111111','caller_name',
    'b7777777-7777-4777-8777-777777777777')->>'status'),
  'pending',
  'opposite-direction request leaves an existing pending relationship pending'
);
select extensions.is(
  (select value->>'requester_user_id' from public.list_friendships() as x(value)
    where value->>'other_user_id'='a1111111-1111-4111-8111-111111111111'),
  'a1111111-1111-4111-8111-111111111111',
  'opposite request never reverses the original requester'
);
select public.set_my_friend_username('visible_user', false);

reset role;
set local request.jwt.claims = '{"sub":"a1111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = 'a1111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.throws_ok(
  $sql$ select public.request_friend_by_username(
    'a2222222-2222-4222-8222-222222222222','visible_user',
    'b1111111-1111-4111-8111-111111111111') $sql$,
  '42501', 'friend username target is unavailable',
  'receipt replay cannot bypass a target opt-out'
);

reset role;
set local request.jwt.claims = '{"sub":"a2222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = 'a2222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select public.set_my_friend_username('visible_user', true);
select public.reject_friend_request(
  (select (value->>'friendship_id')::uuid from public.list_friendships() as x(value)
    where value->>'other_user_id'='a1111111-1111-4111-8111-111111111111'),
  (select (value->>'incarnation')::uuid from public.list_friendships() as x(value)
    where value->>'other_user_id'='a1111111-1111-4111-8111-111111111111'),
  (select (value->>'revision')::bigint from public.list_friendships() as x(value)
    where value->>'other_user_id'='a1111111-1111-4111-8111-111111111111'),
  'b8888888-8888-4888-8888-888888888888'
);

reset role;
set local request.jwt.claims = '{"sub":"a1111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = 'a1111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.throws_ok(
  $sql$ select public.request_friend_by_username(
    'a2222222-2222-4222-8222-222222222222','visible_user',
    'b1111111-1111-4111-8111-111111111111') $sql$,
  'PT409', 'friend request receipt is stale',
  'receipt replay cannot restore a rejected incarnation'
);

select extensions.ok(
  (public.set_my_friend_username(null, false)->>'username') is null,
  'owner can clear a username after opting out'
);
select public.set_my_friend_username('caller_name', true);

select extensions.is(
  public.block_user('a5555555-5555-4555-8555-555555555555',
    'b5555555-5555-4555-8555-555555555555')->>'blocked',
  'true',
  'caller can block a discovery target'
);
select extensions.is(
  (select count(*) from public.find_friend_by_username('reverse_block')),
  0::bigint,
  'lookup hides the other-direction block'
);

reset role;
set local request.jwt.claims = '{"sub":"a2222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = 'a2222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select public.block_user(
  'a1111111-1111-4111-8111-111111111111',
  'b6666666-6666-4666-8666-666666666666'
);
select extensions.ok(
  (select count(*) from public.find_friend_by_username('caller_name')) = 0,
  'lookup also hides blocks created by the target'
);
select extensions.finish();
rollback;
