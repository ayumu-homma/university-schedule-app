begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(41);

-- The fixture is intentionally trusted setup. Assertions below run through
-- ordinary authenticated/anonymous roles and RPC grants.
insert into auth.users (id) values
  ('81111111-1111-4111-8111-111111111111'),
  ('82222222-2222-4222-8222-222222222222'),
  ('83333333-3333-4333-8333-333333333333')
on conflict (id) do nothing;
update public.profiles set display_name = case user_id
  when '81111111-1111-4111-8111-111111111111' then 'Alice'
  when '82222222-2222-4222-8222-222222222222' then 'Bob'
  else 'Carol' end,
  university_id = '26a72fcd-6e61-5d0f-9c77-350762f2562f'
where user_id in (
  '81111111-1111-4111-8111-111111111111',
  '82222222-2222-4222-8222-222222222222',
  '83333333-3333-4333-8333-333333333333'
);

insert into public.terms (id, university_id, name, academic_year, start_date, end_date, term_type, created_by, owner_user_id)
values ('8a111111-1111-4111-8111-111111111111', '26a72fcd-6e61-5d0f-9c77-350762f2562f', 'A Autumn', 2030, '2030-10-01', '2031-03-31', 'semester', '81111111-1111-4111-8111-111111111111', '81111111-1111-4111-8111-111111111111')
on conflict (id) do nothing;
insert into public.period_settings (owner_user_id, university_id, term_id, day_of_week, period_no, start_time, end_time)
values ('81111111-1111-4111-8111-111111111111', '26a72fcd-6e61-5d0f-9c77-350762f2562f', '8a111111-1111-4111-8111-111111111111', 1, 1, '09:00', '10:30')
on conflict do nothing;
insert into public.user_courses (id, owner_user_id, term_id, title, normalized_title, day_of_week, period_no, visibility_level)
values ('8b111111-1111-4111-8111-111111111111', '81111111-1111-4111-8111-111111111111', '8a111111-1111-4111-8111-111111111111', 'Public course source', 'publiccoursesource', 1, 1, 'FULL')
on conflict (id) do nothing;
insert into public.user_courses (id, owner_user_id, term_id, title, normalized_title, day_of_week, period_no, visibility_level)
values ('8e111111-1111-4111-8111-111111111111', '81111111-1111-4111-8111-111111111111', '8a111111-1111-4111-8111-111111111111', 'Private course source', 'privatecoursesource', 1, 1, 'PRIVATE')
on conflict (id) do nothing;
insert into public.calendars (id, owner_user_id, name, default_visibility)
values ('8c111111-1111-4111-8111-111111111111', '81111111-1111-4111-8111-111111111111', 'A calendar', 'FULL')
on conflict (id) do nothing;
insert into public.events (id, owner_user_id, calendar_id, title, kind, start_at, end_at, visibility_level, created_by)
values ('8d111111-1111-4111-8111-111111111111', '81111111-1111-4111-8111-111111111111', '8c111111-1111-4111-8111-111111111111', 'Public event source', 'normal', '2030-10-01T00:00:00Z', '2030-10-01T01:00:00Z', 'FULL', '81111111-1111-4111-8111-111111111111')
on conflict (id) do nothing;
insert into public.exams (id, owner_user_id, course_id, title, start_at, end_at, room, scope, visibility_level)
values
  ('8f111111-1111-4111-8111-111111111111', '81111111-1111-4111-8111-111111111111', '8b111111-1111-4111-8111-111111111111', 'Exam one', '2030-10-02T00:00:00Z', '2030-10-02T01:00:00Z', 'Room one', 'private scope', 'FULL'),
  ('8f222222-2222-4222-8222-222222222222', '81111111-1111-4111-8111-111111111111', '8b111111-1111-4111-8111-111111111111', 'Exam two', '2030-10-03T00:00:00Z', '2030-10-03T01:00:00Z', 'Room two', 'private scope', 'FULL')
on conflict (id) do nothing;
insert into public.assignments (id, owner_user_id, course_id, title, description, submission_url, due_at, visibility_level)
values
  ('9a111111-1111-4111-8111-111111111111', '81111111-1111-4111-8111-111111111111', '8b111111-1111-4111-8111-111111111111', 'Assignment one', 'private memo', 'https://private.invalid/one', '2030-10-04T00:00:00Z', 'FULL'),
  ('9a222222-2222-4222-8222-222222222222', '81111111-1111-4111-8111-111111111111', '8b111111-1111-4111-8111-111111111111', 'Assignment two', 'private memo', 'https://private.invalid/two', '2030-10-05T00:00:00Z', 'FULL')
on conflict (id) do nothing;

set local request.jwt.claims = '{"sub":"81111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '81111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.ok(
  pg_catalog.has_function_privilege('authenticated', 'public.create_friend_invite(text,uuid,timestamptz)', 'EXECUTE'),
  'authenticated can create invites'
);
select extensions.ok(
  not pg_catalog.has_table_privilege('authenticated', 'public.friendships', 'SELECT'),
  'authenticated cannot read raw friendships'
);

select extensions.is(
  public.create_friend_invite(
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    '91111111-1111-4111-8111-111111111111'
  ) ->> 'token',
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  'invite returns the caller supplied secret for retry without server plaintext storage'
);

reset role;
set local request.jwt.claims = '{"sub":"81111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '81111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.is(
  public.preview_friend_invite('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') ->> 'state',
  'active',
  'authenticated preview returns only invite metadata'
);

reset role;
set local request.jwt.claims = '{"sub":"82222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '82222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.is(
  public.request_friend_from_invite(
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    '92222222-2222-4222-8222-222222222222'
  ) ->> 'status',
  'pending',
  'recipient request remains pending until issuer approval'
);

select extensions.is(
  (select count(*) from public.list_friendships() as x(value) where value->>'viewer_role' = 'requester'),
  1::bigint,
  'requester receives role-aware relationship listing'
);

reset role;
set local request.jwt.claims = '{"sub":"81111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '81111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.is(
  (select value from public.list_friendships() as x(value) limit 1) ->> 'viewer_role',
  'addressee',
  'issuer receives incoming request role'
);

select extensions.is(
  public.accept_friend_request(
    (select (value->>'friendship_id')::uuid from public.list_friendships() as x(value) limit 1),
    (select (value->>'incarnation')::uuid from public.list_friendships() as x(value) limit 1),
    null,
    '93111111-1111-4111-8111-111111111111'
  ) ->> 'status',
  'accepted',
  'issuer approval creates accepted relationship'
);

reset role;
select extensions.is(
  (select count(*) from public.friend_visibility_rules where target_kind = 'default' and visibility_level = 'PRIVATE'
    and owner_user_id in ('81111111-1111-4111-8111-111111111111', '82222222-2222-4222-8222-222222222222')),
  2::bigint,
  'acceptance seeds explicit PRIVATE defaults in both directions'
);
select extensions.ok(
  exists (
    select 1 from realtime.messages
    where topic = 'schedule-sync:81111111-1111-4111-8111-111111111111'
      and event = 'friend-invalidate' and private
  ),
  'friend mutation emits empty owner-topic invalidation'
);

reset role;
set local request.jwt.claims = '{"sub":"82222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '82222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local request.jwt.claims = '{"sub":"82222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '82222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.is(
  jsonb_array_length(public.get_friend_schedule(
    '81111111-1111-4111-8111-111111111111', null,
    '2030-01-01T00:00:00Z', '2030-01-02T00:00:00Z'
  )->'rows'->'items'),
  0,
  'fresh relationship exposes no events'
);

select extensions.is(
  jsonb_array_length(public.get_friend_schedule(
    '81111111-1111-4111-8111-111111111111', '8a111111-1111-4111-8111-111111111111',
    '2030-10-01T00:00:00Z', '2030-10-08T00:00:00Z'
  )->'rows'->'items'),
  0,
  'directional PRIVATE default hides an existing FULL course source'
);

reset role;
set local request.jwt.claims = '{"sub":"81111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '81111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.ok(
  (public.set_friend_visibility(
    (select (value->>'friendship_id')::uuid from public.list_friendships() as x(value) limit 1),
    (select (value->>'incarnation')::uuid from public.list_friendships() as x(value) limit 1),
    '82222222-2222-4222-8222-222222222222', 'course',
    '8e111111-1111-4111-8111-111111111111', 'FULL', null,
    '94111111-1111-4111-8111-111111111113'
  )->>'revision') is not null,
  'individual course rule can be written for a private source'
);
reset role;
set local request.jwt.claims = '{"sub":"82222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '82222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.is(
  (select count(*) from jsonb_array_elements(public.get_friend_schedule(
    '81111111-1111-4111-8111-111111111111', '8a111111-1111-4111-8111-111111111111',
    '2030-10-01T00:00:00Z', '2030-10-08T00:00:00Z'
  )->'rows'->'items') as item
   where item->>'item_id' = encode(extensions.digest(
     '8e111111-1111-4111-8111-111111111111:2030-10-07', 'sha256'), 'hex')),
  0::bigint,
  'individual FULL cannot publish an explicit PRIVATE course source'
);

reset role;
set local request.jwt.claims = '{"sub":"81111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '81111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.ok(
  (public.set_friend_visibility(
    (select (value->>'friendship_id')::uuid from public.list_friendships() as x(value) limit 1),
    (select (value->>'incarnation')::uuid from public.list_friendships() as x(value) limit 1),
    '82222222-2222-4222-8222-222222222222', 'event_kind', null, 'FULL', null,
    '94111111-1111-4111-8111-111111111114', 'course'
  )->>'revision') is not null,
  'course kind rule is accepted'
);
reset role;
set local request.jwt.claims = '{"sub":"82222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '82222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.ok(
  jsonb_array_length(public.get_friend_schedule(
    '81111111-1111-4111-8111-111111111111', '8a111111-1111-4111-8111-111111111111',
    '2030-10-01T00:00:00Z', '2030-10-08T00:00:00Z'
  )->'rows'->'items') > 0,
  'course kind rule overrides the PRIVATE default for non-private source'
);
reset role;
set local request.jwt.claims = '{"sub":"81111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '81111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.ok(
  (public.inherit_friend_visibility(
    (select (value->>'friendship_id')::uuid from public.list_friendships() as x(value) limit 1),
    (select (value->>'incarnation')::uuid from public.list_friendships() as x(value) limit 1),
    '82222222-2222-4222-8222-222222222222', 'event_kind', null, null,
    '94111111-1111-4111-8111-111111111115', 'course'
  )->>'revision') is not null,
  'course kind inheritance is accepted'
);
reset role;
set local request.jwt.claims = '{"sub":"82222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '82222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.is(
  jsonb_array_length(public.get_friend_schedule(
    '81111111-1111-4111-8111-111111111111', '8a111111-1111-4111-8111-111111111111',
    '2030-10-01T00:00:00Z', '2030-10-08T00:00:00Z'
  )->'rows'->'items'),
  0,
  'inherited course kind skips to PRIVATE default'
);
reset role;
set local request.jwt.claims = '{"sub":"81111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '81111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.throws_ok(
  $sql$ select public.set_friend_visibility(
    (select (value->>'friendship_id')::uuid from public.list_friendships() as x(value) limit 1),
    (select (value->>'incarnation')::uuid from public.list_friendships() as x(value) limit 1),
    '82222222-2222-4222-8222-222222222222', 'event_kind', null, 'FULL', null,
    '94111111-1111-4111-8111-111111111116', 'unsupported'
  ) $sql$,
  '22023',
  'event kind is invalid'
);

select extensions.ok(
  (public.set_friend_visibility(
    (select (value->>'friendship_id')::uuid from public.list_friendships() as x(value) limit 1),
    (select (value->>'incarnation')::uuid from public.list_friendships() as x(value) limit 1),
    '82222222-2222-4222-8222-222222222222', 'exam',
    '8f111111-1111-4111-8111-111111111111', 'FULL', null,
    '94111111-1111-4111-8111-111111111117'
  )->>'revision') is not null,
  'individual exam rule is accepted'
);
reset role;
set local request.jwt.claims = '{"sub":"82222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '82222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.is(
  (select count(*) from jsonb_array_elements(public.get_friend_schedule(
    '81111111-1111-4111-8111-111111111111', '8a111111-1111-4111-8111-111111111111',
    '2030-10-01T00:00:00Z', '2030-10-08T00:00:00Z'
  )->'rows'->'items') as item where item->>'title' = 'Exam one'),
  1::bigint,
  'exam target rule publishes only the selected exam'
);
select extensions.is(
  (select count(*) from jsonb_array_elements(public.get_friend_schedule(
    '81111111-1111-4111-8111-111111111111', '8a111111-1111-4111-8111-111111111111',
    '2030-10-01T00:00:00Z', '2030-10-08T00:00:00Z'
  )->'rows'->'items') as item where item->>'title' = 'Exam two'),
  0::bigint,
  'exam target rule does not publish another exam'
);
reset role;
set local request.jwt.claims = '{"sub":"81111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '81111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.ok(
  (public.set_friend_visibility(
    (select (value->>'friendship_id')::uuid from public.list_friendships() as x(value) limit 1),
    (select (value->>'incarnation')::uuid from public.list_friendships() as x(value) limit 1),
    '82222222-2222-4222-8222-222222222222', 'assignment',
    '9a111111-1111-4111-8111-111111111111', 'FULL', null,
    '94111111-1111-4111-8111-111111111118'
  )->>'revision') is not null,
  'individual assignment rule is accepted'
);
reset role;
set local request.jwt.claims = '{"sub":"82222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '82222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.is(
  (select count(*) from jsonb_array_elements(public.get_friend_schedule(
    '81111111-1111-4111-8111-111111111111', '8a111111-1111-4111-8111-111111111111',
    '2030-10-01T00:00:00Z', '2030-10-08T00:00:00Z'
  )->'rows'->'items') as item where item->>'title' = 'Assignment one'),
  1::bigint,
  'assignment target rule publishes only the selected assignment'
);
select extensions.is(
  (select count(*) from jsonb_array_elements(public.get_friend_schedule(
    '81111111-1111-4111-8111-111111111111', '8a111111-1111-4111-8111-111111111111',
    '2030-10-01T00:00:00Z', '2030-10-08T00:00:00Z'
  )->'rows'->'items') as item where item->>'title' = 'Assignment two'),
  0::bigint,
  'assignment target rule does not publish another assignment'
);

reset role;
set local request.jwt.claims = '{"sub":"81111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '81111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.ok(
  (public.set_friend_visibility(
    (select (value->>'friendship_id')::uuid from public.list_friendships() as x(value) limit 1),
    (select (value->>'incarnation')::uuid from public.list_friendships() as x(value) limit 1),
    '82222222-2222-4222-8222-222222222222', 'default', null, 'FULL', null,
    '94111111-1111-4111-8111-11111111111b'
  )->>'revision') is not null,
  'default FULL rule is accepted before assignment-kind override'
);
select extensions.ok(
  (public.set_friend_visibility(
    (select (value->>'friendship_id')::uuid from public.list_friendships() as x(value) limit 1),
    (select (value->>'incarnation')::uuid from public.list_friendships() as x(value) limit 1),
    '82222222-2222-4222-8222-222222222222', 'event_kind', null, 'PRIVATE', null,
    '94111111-1111-4111-8111-11111111111c', 'assignment_deadline'
  )->>'revision') is not null,
  'assignment-deadline kind PRIVATE rule is accepted'
);

reset role;
set local request.jwt.claims = '{"sub":"82222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '82222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.is(
  (select count(*) from jsonb_array_elements(public.get_friend_schedule(
    '81111111-1111-4111-8111-111111111111', '8a111111-1111-4111-8111-111111111111',
    '2030-10-01T00:00:00Z', '2030-10-08T00:00:00Z'
  )->'rows'->'items') as item where item->>'title' = 'Assignment one'),
  1::bigint,
  'individual assignment FULL rule takes precedence over assignment-kind PRIVATE'
);
select extensions.is(
  (select count(*) from jsonb_array_elements(public.get_friend_schedule(
    '81111111-1111-4111-8111-111111111111', '8a111111-1111-4111-8111-111111111111',
    '2030-10-01T00:00:00Z', '2030-10-08T00:00:00Z'
  )->'rows'->'items') as item where item->>'title' = 'Assignment two'),
  0::bigint,
  'assignment-kind PRIVATE overrides FULL default for other deadlines'
);
select extensions.ok(
  (with definition as (
    select pg_get_functiondef(
      'private.build_friend_snapshot(uuid,uuid,uuid,timestamptz,timestamptz,boolean)'::regprocedure
    ) as body
  ) select position('perform pg_advisory_xact_lock_shared' in body) > 0
      and position('private.safety_actor_active(p_viewer)' in body) > 0
      and position('private.safety_actor_active(p_owner)' in body) > 0
      and position('private.phase15_build_friend_snapshot_base(' in body) > 0
    from definition),
  'friend schedule safety wrapper retains its owner lock and active-actor checks'
);

reset role;
set local request.jwt.claims = '{"sub":"81111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '81111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.ok(
  (public.set_friend_visibility(
    (select (value->>'friendship_id')::uuid from public.list_friendships() as x(value) limit 1),
    (select (value->>'incarnation')::uuid from public.list_friendships() as x(value) limit 1),
    '82222222-2222-4222-8222-222222222222', 'event', '8d111111-1111-4111-8111-111111111111', 'FULL', null,
    '94111111-1111-4111-8111-111111111112'
  )->>'revision') is not null,
  'issuer can explicitly share one event'
);

reset role;
set local request.jwt.claims = '{"sub":"82222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '82222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.is(
  (select count(*) from jsonb_array_elements(public.get_friend_schedule(
    '81111111-1111-4111-8111-111111111111', '8a111111-1111-4111-8111-111111111111',
    '2030-10-01T00:00:00Z', '2030-10-08T00:00:00Z'
  )->'rows'->'items') as item where item->>'title' = 'Public event source'),
  1::bigint,
  'individual FULL rule shares only the selected event'
);

reset role;
set local request.jwt.claims = '{"sub":"81111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '81111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.ok(
  (public.set_friend_visibility(
    (select (value->>'friendship_id')::uuid from public.list_friendships() as x(value) limit 1),
    (select (value->>'incarnation')::uuid from public.list_friendships() as x(value) limit 1),
    '82222222-2222-4222-8222-222222222222', 'course',
    '8b111111-1111-4111-8111-111111111111', 'BUSY_ONLY',
    (select (value->>'revision')::bigint from public.list_friendships() as x(value) limit 1),
    '94111111-1111-4111-8111-111111111119'
  )->>'revision') is not null,
  'course BUSY rule is accepted'
);
select extensions.ok(
  (public.set_friend_visibility(
    (select (value->>'friendship_id')::uuid from public.list_friendships() as x(value) limit 1),
    (select (value->>'incarnation')::uuid from public.list_friendships() as x(value) limit 1),
    '82222222-2222-4222-8222-222222222222', 'event',
    '8d111111-1111-4111-8111-111111111111', 'BUSY_ONLY',
    (select (value->>'revision')::bigint from public.list_friendships() as x(value) limit 1),
    '94111111-1111-4111-8111-111111111120'
  )->>'revision') is not null,
  'event BUSY rule is accepted'
);
reset role;
set local request.jwt.claims = '{"sub":"82222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '82222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;
select extensions.ok(
  (with items as (
    select value as item
    from jsonb_array_elements(public.get_friend_schedule(
      '81111111-1111-4111-8111-111111111111', '8a111111-1111-4111-8111-111111111111',
      '2030-10-01T00:00:00Z', '2030-10-08T00:00:00Z'
    )->'rows'->'items') value
    where value->>'title' = '予定あり'
  ), shapes as (
    select array_agg(key order by key) as shape from items
    cross join lateral jsonb_object_keys(items.item) key
    group by items.item
  ) select count(*) >= 2 and count(distinct shape) = 1 from shapes),
  'BUSY course and event items use one opaque generic key shape'
);

select extensions.throws_ok(
  $sql$ select public.set_friend_visibility(
    (select (value->>'friendship_id')::uuid from public.list_friendships() as x(value) limit 1),
    (select (value->>'incarnation')::uuid from public.list_friendships() as x(value) limit 1),
    '82222222-2222-4222-8222-222222222222', 'default', null, 'FULL', null,
    '94111111-1111-4111-8111-111111111111'
  ) $sql$,
  'PT409',
  'stale or unauthorized visibility change'
);

select extensions.is(
  public.block_user('81111111-1111-4111-8111-111111111111', '95111111-1111-4111-8111-111111111111') ->> 'blocked',
  'true',
  'block mutation succeeds through RPC'
);
select extensions.is(
  (select count(*) from public.get_visible_events(
    '82222222-2222-4222-8222-222222222222', '2030-10-01T00:00:00Z', '2030-10-02T00:00:00Z'
  )),
  0::bigint,
  'legacy event RPC remains blocked after relationship block'
);

select extensions.is(
  public.unblock_user('81111111-1111-4111-8111-111111111111', '96111111-1111-4111-8111-111111111111') ->> 'blocked',
  'false',
  'unblock does not revive sharing'
);
reset role;
select extensions.is(
  (select status from public.friendships where requester_user_id = '82222222-2222-4222-8222-222222222222'
    and addressee_user_id = '81111111-1111-4111-8111-111111111111'),
  'blocked',
  'unblock leaves blocked relationship terminal'
);

select extensions.ok(
  not pg_catalog.has_function_privilege('anon', 'public.get_friend_schedule(uuid,uuid,timestamptz,timestamptz)', 'EXECUTE'),
  'anonymous callers cannot fetch schedules'
);

select * from extensions.finish();
rollback;
