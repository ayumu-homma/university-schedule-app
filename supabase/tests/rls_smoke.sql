begin;

create extension if not exists pgtap with schema extensions;

select extensions.plan(26);

-- Deterministic auth and schedule fixtures. Setup runs as postgres so that the
-- assertions, rather than fixture construction, exercise RLS.
insert into auth.users (id)
values
  ('11111111-1111-4111-8111-111111111111'),
  ('22222222-2222-4222-8222-222222222222'),
  ('33333333-3333-4333-8333-333333333333'),
  ('44444444-4444-4444-8444-444444444444');

-- Phase 2 bootstraps profiles from auth.users. Enrich those generated rows as
-- the trusted fixture role rather than attempting a second insert.
update public.profiles p
set display_name = fixture.display_name,
    username = fixture.username,
    university_id = '26a72fcd-6e61-5d0f-9c77-350762f2562f',
    searchable_by_username = fixture.searchable_by_username
from (
  values
    ('11111111-1111-4111-8111-111111111111'::uuid, 'Owner'::text, 'owner_visible_search'::text, true),
    ('22222222-2222-4222-8222-222222222222'::uuid, 'Unrelated'::text, 'unrelated_user'::text, false),
    ('33333333-3333-4333-8333-333333333333'::uuid, 'Plain member'::text, 'plain_member'::text, false)
) as fixture(user_id, display_name, username, searchable_by_username)
where p.user_id = fixture.user_id;

insert into public.groups (
  id,
  owner_user_id,
  name,
  default_visibility,
  event_create_policy
)
values (
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
  '11111111-1111-4111-8111-111111111111',
  'Containment group',
  'TITLE_ONLY',
  'member'
);

insert into public.group_members (group_id, user_id, role)
values
  (
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
    '11111111-1111-4111-8111-111111111111',
    'owner'
  ),
  (
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
    '33333333-3333-4333-8333-333333333333',
    'member'
  );

insert into public.calendars (
  id,
  owner_user_id,
  group_id,
  name,
  default_visibility
)
values (
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1',
  '11111111-1111-4111-8111-111111111111',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
  'Containment calendar',
  'PRIVATE'
);

insert into public.events (
  id,
  owner_user_id,
  calendar_id,
  group_id,
  title,
  kind,
  start_at,
  end_at,
  location,
  description,
  visibility_level,
  created_by
)
values
  (
    'dddddddd-dddd-4ddd-8ddd-ddddddddddd1',
    '11111111-1111-4111-8111-111111111111',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
    'Private secret',
    'normal',
    '2030-01-10T01:00:00Z',
    '2030-01-10T02:00:00Z',
    'Private room',
    'Private description',
    'PRIVATE',
    '11111111-1111-4111-8111-111111111111'
  ),
  (
    'dddddddd-dddd-4ddd-8ddd-ddddddddddd2',
    '11111111-1111-4111-8111-111111111111',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
    'Busy secret',
    'normal',
    '2030-01-11T01:00:00Z',
    '2030-01-11T02:00:00Z',
    'Busy room',
    'Busy description',
    'BUSY_ONLY',
    '11111111-1111-4111-8111-111111111111'
  ),
  (
    'dddddddd-dddd-4ddd-8ddd-ddddddddddd3',
    '11111111-1111-4111-8111-111111111111',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
    'Title projection',
    'normal',
    '2030-01-12T01:00:00Z',
    '2030-01-12T02:00:00Z',
    'Title room',
    'Title description',
    'TITLE_ONLY',
    '11111111-1111-4111-8111-111111111111'
  ),
  (
    'dddddddd-dddd-4ddd-8ddd-ddddddddddd4',
    '11111111-1111-4111-8111-111111111111',
    'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',
    'Full projection',
    'normal',
    '2030-01-13T01:00:00Z',
    '2030-01-13T02:00:00Z',
    'Full room',
    'Full description',
    'FULL',
    '11111111-1111-4111-8111-111111111111'
  );

-- Unrelated authenticated caller.
set local request.jwt.claims = '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '22222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is(
  auth.uid(),
  '22222222-2222-4222-8222-222222222222'::uuid,
  'JWT harness sets auth.uid() for RLS tests'
);

select extensions.throws_ok(
  $sql$
    select count(*)
    from public.get_visible_events(
      '11111111-1111-4111-8111-111111111111',
      '2030-01-01T00:00:00Z',
      '2030-02-01T00:00:00Z'
    )
  $sql$,
  '42501',
  'viewer_id must match auth.uid()',
  'legacy viewer_id cannot impersonate another user'
);

select extensions.is(
  (
    select count(*)
    from public.get_visible_events(
      '22222222-2222-4222-8222-222222222222',
      '2030-01-01T00:00:00Z',
      '2030-02-01T00:00:00Z'
    )
    where event_id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd4'
  ),
  0::bigint,
  'unrelated caller cannot see an explicitly FULL event'
);

select extensions.is(
  (
    select count(*)
    from public.profiles
    where user_id = '11111111-1111-4111-8111-111111111111'
  ),
  0::bigint,
  'searchable profile base row is not readable by another user'
);

select extensions.is(
  (
    select count(*)
    from public.profiles
    where user_id = auth.uid()
  ),
  1::bigint,
  'profile owner can still read their own base row'
);

select extensions.throws_ok(
  $sql$
    select count(*)
    from public.find_free_windows(
      '11111111-1111-4111-8111-111111111111',
      array['11111111-1111-4111-8111-111111111111'::uuid],
      '2030-01-01T00:00:00Z',
      '2030-02-01T00:00:00Z',
      30
    )
  $sql$,
  '42501',
  'viewer_id must match auth.uid()',
  'find_free_windows cannot impersonate another viewer'
);

-- Ordinary group member: projection is allowed, raw row access and writes are not.
reset role;
set local request.jwt.claims = '{"sub":"33333333-3333-4333-8333-333333333333","role":"authenticated"}';
set local request.jwt.claim.sub = '33333333-3333-4333-8333-333333333333';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is(
  (
    select count(*)
    from public.events
    where id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd4'
  ),
  0::bigint,
  'plain group member cannot SELECT a raw event row'
);

select extensions.is_empty(
  $sql$
    update public.events
    set title = 'tampered'
    where id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd4'
    returning id
  $sql$,
  'plain group member cannot UPDATE a raw event row'
);

select extensions.is_empty(
  $sql$
    delete from public.events
    where id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd4'
    returning id
  $sql$,
  'plain group member cannot DELETE a raw event row'
);

select extensions.is(
  (
    select count(*)
    from public.get_visible_events(
      '33333333-3333-4333-8333-333333333333',
      '2030-01-01T00:00:00Z',
      '2030-02-01T00:00:00Z'
    )
  ),
  3::bigint,
  'group member receives only the three non-private projections'
);

select extensions.is_empty(
  $sql$
    select event_id
    from public.get_visible_events(
      '33333333-3333-4333-8333-333333333333',
      '2030-01-01T00:00:00Z',
      '2030-02-01T00:00:00Z'
    )
    where event_id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd1'
  $sql$,
  'PRIVATE event is absent from the projection'
);

select extensions.results_eq(
  $sql$
    select title, kind, location, description
    from public.get_visible_events(
      '33333333-3333-4333-8333-333333333333',
      '2030-01-01T00:00:00Z',
      '2030-02-01T00:00:00Z'
    )
    where event_id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd2'
  $sql$,
  $sql$ values ('予定あり'::text, null::text, null::text, null::text) $sql$,
  'BUSY_ONLY returns only the busy marker and time'
);

select extensions.results_eq(
  $sql$
    select title, kind, location, description
    from public.get_visible_events(
      '33333333-3333-4333-8333-333333333333',
      '2030-01-01T00:00:00Z',
      '2030-02-01T00:00:00Z'
    )
    where event_id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd3'
  $sql$,
  $sql$ values ('Title projection'::text, 'normal'::text, null::text, null::text) $sql$,
  'TITLE_ONLY returns title and kind but no details'
);

select extensions.results_eq(
  $sql$
    select title, kind, location, description
    from public.get_visible_events(
      '33333333-3333-4333-8333-333333333333',
      '2030-01-01T00:00:00Z',
      '2030-02-01T00:00:00Z'
    )
    where event_id = 'dddddddd-dddd-4ddd-8ddd-ddddddddddd4'
  $sql$,
  $sql$ values ('Full projection'::text, 'normal'::text, 'Full room'::text, 'Full description'::text) $sql$,
  'FULL returns the safe full-detail projection'
);

-- Group events are RPC-only; even the event owner cannot read the raw row.
reset role;
set local request.jwt.claims = '{"sub":"11111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = '11111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is(
  (
    select count(*)
    from public.events
    where calendar_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1'
  ),
  0::bigint,
  'group event owner has no raw read access'
);

-- A block suppresses even an otherwise valid group projection.
reset role;
insert into public.blocks (blocker_user_id, blocked_user_id)
values (
  '11111111-1111-4111-8111-111111111111',
  '33333333-3333-4333-8333-333333333333'
);

set local request.jwt.claims = '{"sub":"33333333-3333-4333-8333-333333333333","role":"authenticated"}';
set local request.jwt.claim.sub = '33333333-3333-4333-8333-333333333333';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is(
  (
    select count(*)
    from public.get_visible_events(
      '33333333-3333-4333-8333-333333333333',
      '2030-01-01T00:00:00Z',
      '2030-02-01T00:00:00Z'
    )
  ),
  0::bigint,
  'block state takes precedence over group visibility'
);

-- Verification is server-managed on both update and insert paths.
reset role;
set local request.jwt.claims = '{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = '22222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.throws_ok(
  $sql$
    update public.profiles
    set university_verified = true
    where user_id = '22222222-2222-4222-8222-222222222222'
  $sql$,
  '42501',
  'university_verified is server-managed',
  'user cannot forge university verification by update'
);

select extensions.is(
  (
    select university_verified
    from public.profiles
    where user_id = auth.uid()
  ),
  false,
  'verification remains false after rejected update'
);

reset role;
set local request.jwt.claims = '{"sub":"44444444-4444-4444-8444-444444444444","role":"authenticated"}';
set local request.jwt.claim.sub = '44444444-4444-4444-8444-444444444444';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.ok(
  not pg_catalog.has_table_privilege('authenticated', 'public.profiles', 'INSERT'),
  'authenticated users cannot bypass auth bootstrap with a profile insert'
);

-- Function ACL and hardening assertions run as postgres against the catalogs.
reset role;

select extensions.is_empty(
  $sql$
    select p.oid::regprocedure
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    cross join lateral pg_catalog.aclexplode(
      coalesce(p.proacl, pg_catalog.acldefault('f'::"char", p.proowner))
    ) acl
    where n.nspname in ('public', 'private')
      and p.prosecdef
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  $sql$,
  'PUBLIC has no EXECUTE on application SECURITY DEFINER functions'
);

select extensions.is_empty(
  $sql$
    select p.oid::regprocedure
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private')
      and p.prosecdef
      and pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
      -- The unexposed pre-request hook must execute under the selected API role.
      and p.oid <> 'private.safety_pre_request()'::regprocedure
  $sql$,
  'anon has no effective EXECUTE on application SECURITY DEFINER functions except the internal pre-request hook'
);

select extensions.is(
  (
    select bool_and(
      pg_catalog.has_function_privilege(
        'authenticated',
        pg_catalog.to_regprocedure(signature),
        'EXECUTE'
      )
    )
    from (
      values
        ('public.search_course_templates(text,uuid,integer,uuid,integer,integer,integer,text)'),
        ('public.copy_course_template(uuid,uuid)'),
        ('public.get_visible_events(uuid,timestamptz,timestamptz)'),
        ('public.find_free_windows(uuid,uuid[],timestamptz,timestamptz,integer)')
    ) intended(signature)
  ),
  true,
  'authenticated can execute only the intended public client RPC set'
);

select extensions.is_empty(
  $sql$
    select h.signature, r.role_name
    from (
      values
        ('public.is_group_member(uuid,uuid)'),
        ('public.is_group_admin(uuid,uuid)'),
        ('public.are_friends(uuid,uuid)'),
        ('public.is_blocked(uuid,uuid)'),
        ('public.can_access_event(uuid,uuid)')
    ) h(signature)
    cross join (
      values ('anon'::name), ('authenticated'::name)
    ) r(role_name)
    where pg_catalog.has_function_privilege(
      r.role_name,
      pg_catalog.to_regprocedure(h.signature),
      'EXECUTE'
    )
  $sql$,
  'arbitrary-user public relationship helpers are not client executable'
);

select extensions.ok(
  pg_catalog.has_function_privilege(
    'authenticated',
    'public.get_visible_events(uuid,timestamptz,timestamptz)',
    'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'anon',
    'public.get_visible_events(uuid,timestamptz,timestamptz)',
    'EXECUTE'
  ),
  'visible-event RPC is authenticated-only'
);

select extensions.ok(
  pg_catalog.has_function_privilege(
    'authenticated',
    'public.find_free_windows(uuid,uuid[],timestamptz,timestamptz,integer)',
    'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'anon',
    'public.find_free_windows(uuid,uuid[],timestamptz,timestamptz,integer)',
    'EXECUTE'
  ),
  'free-window RPC is authenticated-only'
);

select extensions.is_empty(
  $sql$
    select p.oid::regprocedure
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private')
      and p.prosecdef
      and not exists (
        select 1
        from unnest(coalesce(p.proconfig, '{}'::text[])) setting
        where setting like 'search_path=%'
      )
  $sql$,
  'every application SECURITY DEFINER function pins search_path'
);

select * from extensions.finish();
rollback;
