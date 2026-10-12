begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(35);

select extensions.has_table(
  'public',
  'email_connections',
  'email connections are stored in the exposed owner-readable schema'
);
select extensions.has_table(
  'public',
  'email_sources',
  'email sources are stored in the exposed owner-readable schema'
);
select extensions.has_table(
  'public',
  'email_candidates',
  'email candidates are stored in the exposed owner-readable schema'
);
select extensions.has_table(
  'public',
  'email_candidate_updates',
  'email candidate updates are stored in the exposed owner-readable schema'
);
select extensions.has_table(
  'private',
  'email_connection_credentials',
  'sealed OAuth material is stored outside exposed schemas'
);

select extensions.ok(
  (
    select bool_and(c.relrowsecurity)
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in (
        'email_connections',
        'email_sources',
        'email_candidates',
        'email_candidate_updates'
      )
  ),
  'RLS is enabled on every exposed email table'
);

select extensions.is(
  (
    select count(*)
    from pg_catalog.pg_policy p
    join pg_catalog.pg_class c on c.oid = p.polrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in (
        'email_connections',
        'email_sources',
        'email_candidates',
        'email_candidate_updates'
      )
      and p.polcmd = 'r'
  ),
  4::bigint,
  'each exposed email table has one authenticated read policy'
);

select extensions.is(
  (
    select count(*)
    from pg_catalog.pg_policy p
    join pg_catalog.pg_class c on c.oid = p.polrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in (
        'email_connections',
        'email_sources',
        'email_candidates',
        'email_candidate_updates'
      )
      and p.polcmd <> 'r'
      and p.polpermissive
  ),
  0::bigint,
  'no permissive client write policy exists on exposed email tables'
);

select extensions.ok(
  (
    select bool_and(
      pg_catalog.has_table_privilege(
        'authenticated',
        format('public.%I', table_name),
        'SELECT'
      )
      and not pg_catalog.has_table_privilege(
        'authenticated',
        format('public.%I', table_name),
        'INSERT'
      )
      and not pg_catalog.has_table_privilege(
        'authenticated',
        format('public.%I', table_name),
        'UPDATE'
      )
      and not pg_catalog.has_table_privilege(
        'authenticated',
        format('public.%I', table_name),
        'DELETE'
      )
    )
    from unnest(array[
      'email_connections',
      'email_sources',
      'email_candidates',
      'email_candidate_updates'
    ]) table_name
  ),
  'authenticated clients receive SELECT and no direct DML privileges'
);

select extensions.ok(
  (
    select bool_and(
      not pg_catalog.has_table_privilege(
        'anon',
        format('public.%I', table_name),
        privilege_name
      )
    )
    from unnest(array[
      'email_connections',
      'email_sources',
      'email_candidates',
      'email_candidate_updates'
    ]) table_name
    cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) privilege_name
  ),
  'anonymous clients receive no email-table privileges'
);

select extensions.ok(
  (
    select bool_and(
      pg_catalog.has_table_privilege(
        'service_role',
        format('public.%I', table_name),
        privilege_name
      )
    )
    from unnest(array[
      'email_connections',
      'email_sources',
      'email_candidates',
      'email_candidate_updates'
    ]) table_name
    cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) privilege_name
  ),
  'the trusted Edge role can manage only non-secret derived email rows'
);

select extensions.ok(
  not pg_catalog.has_table_privilege(
    'anon',
    'private.email_connection_credentials',
    'SELECT'
  )
  and not pg_catalog.has_table_privilege(
    'authenticated',
    'private.email_connection_credentials',
    'SELECT'
  )
  and not pg_catalog.has_table_privilege(
    'service_role',
    'private.email_connection_credentials',
    'SELECT'
  ),
  'client and application server roles cannot inspect sealed credential rows'
);

select extensions.is_empty(
  $sql$
    select n.nspname, c.relname, a.attname
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_class c on c.oid = a.attrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('public', 'graphql_public')
      and c.relname like 'email%'
      and a.attnum > 0
      and not a.attisdropped
      and a.attname ~* '(^|_)(token|credential|credentials|raw_body|body_html|body_text|message_body|body)($|_)'
  $sql$,
  'exposed email columns contain no token, credential, raw-body or HTML-body field'
);

select extensions.is_empty(
  $sql$
    select a.attname
    from pg_catalog.pg_attribute a
    where a.attrelid = 'private.email_connection_credentials'::regclass
      and a.attnum > 0
      and not a.attisdropped
      and a.attname ~* '(^|_)(raw_body|body_html|body_text|message_body|body)($|_)'
  $sql$,
  'private OAuth storage also has no message-body field'
);

-- Deterministic principals. Profile bootstrap is incidental to this isolated
-- server test; all email fixture writes below run as a trusted database owner.
insert into auth.users (id)
values
  ('a5111111-1111-4111-8111-111111111111'),
  ('a5222222-2222-4222-8222-222222222222'),
  ('a5333333-3333-4333-8333-333333333333'),
  ('a5444444-4444-4444-8444-444444444444');

update auth.users
set raw_app_meta_data = '{"app_role":"admin"}'::jsonb
where id = 'a5444444-4444-4444-8444-444444444444';

select extensions.lives_ok(
  $sql$
    insert into public.email_connections (
      owner_user_id,
      provider_account_hash,
      connection_state,
      last_error_category
    )
    select
      'a5333333-3333-4333-8333-333333333333'::uuid,
      repeat(state_fixture.hash_character, 64),
      state_fixture.connection_state,
      null::text
    from (
      values
        ('1'::text, 'disconnected'::text),
        ('2', 'connecting'),
        ('3', 'connected'),
        ('4', 'reauth_required'),
        ('5', 'rate_limited'),
        ('6', 'failed'),
        ('7', 'disconnecting')
    ) state_fixture(hash_character, connection_state)
    union all
    select
      'a5333333-3333-4333-8333-333333333333'::uuid,
      md5(error_category) || md5(error_category),
      'failed'::text,
      error_category
    from unnest(array[
      'authorization_revoked',
      'cursor_expired',
      'rate_limited',
      'timeout',
      'network_unavailable',
      'provider_unavailable',
      'configuration_missing',
      'malformed_content',
      'oversized_content',
      'unsafe_content',
      'invalid_extraction',
      'unsupported_schema',
      'unsafe_url',
      'validation_failed',
      'internal_error'
    ]) error_category
  $sql$,
  'the normative connection states and safe wire error categories are accepted'
);

delete from public.email_connections
where owner_user_id = 'a5333333-3333-4333-8333-333333333333';

select extensions.throws_ok(
  $sql$
    insert into public.email_connections (
      owner_user_id,
      provider_account_hash,
      connection_state
    ) values (
      'a5333333-3333-4333-8333-333333333333',
      repeat('8', 64),
      'compromised'
    )
  $sql$,
  '23514',
  'new row for relation "email_connections" violates check constraint "email_connections_state_allowed"',
  'unknown connection states are rejected'
);

select extensions.throws_ok(
  $sql$
    insert into public.email_connections (
      owner_user_id,
      provider_account_hash,
      connection_state,
      last_error_category
    ) values (
      'a5333333-3333-4333-8333-333333333333',
      repeat('9', 64),
      'failed',
      'provider_payload'
    )
  $sql$,
  '23514',
  'new row for relation "email_connections" violates check constraint "email_connections_error_category_allowed"',
  'connection errors accept only non-sensitive allow-listed categories'
);

insert into public.email_connections (
  id,
  owner_user_id,
  provider_account_hash,
  authorized_scopes,
  connection_state,
  connected_at
)
values
  (
    'e5111111-1111-4111-8111-111111111111',
    'a5111111-1111-4111-8111-111111111111',
    repeat('a', 64),
    array['gmail.readonly'],
    'connected',
    now()
  ),
  (
    'e5222222-2222-4222-8222-222222222222',
    'a5222222-2222-4222-8222-222222222222',
    repeat('b', 64),
    array['gmail.readonly'],
    'connected',
    now()
  );

select extensions.throws_ok(
  $sql$
    insert into public.email_sources (
      owner_user_id,
      connection_id,
      provider_message_id,
      received_at,
      sanitized_content_hash
    ) values (
      'a5111111-1111-4111-8111-111111111111',
      'e5222222-2222-4222-8222-222222222222',
      'cross-owner-message',
      '2031-01-01T00:00:00Z',
      repeat('c', 64)
    )
  $sql$,
  '23503',
  'insert or update on table "email_sources" violates foreign key constraint "email_sources_connection_owner_fk"',
  'trusted writes cannot cross-link a source to another owner connection'
);

insert into public.email_sources (
  id,
  owner_user_id,
  connection_id,
  provider_message_id,
  provider_thread_id,
  received_at,
  sanitized_content_hash,
  processing_state
)
values
  (
    'e6111111-1111-4111-8111-111111111111',
    'a5111111-1111-4111-8111-111111111111',
    'e5111111-1111-4111-8111-111111111111',
    'provider-message-a',
    'provider-thread-a',
    '2031-01-10T01:00:00Z',
    repeat('d', 64),
    'processed'
  ),
  (
    'e6222222-2222-4222-8222-222222222222',
    'a5222222-2222-4222-8222-222222222222',
    'e5222222-2222-4222-8222-222222222222',
    'provider-message-b',
    'provider-thread-b',
    '2031-01-11T01:00:00Z',
    repeat('e', 64),
    'processed'
  );

select extensions.throws_ok(
  $sql$
    insert into public.email_sources (
      owner_user_id,
      connection_id,
      provider_message_id,
      received_at,
      sanitized_content_hash,
      processing_state,
      error_category
    ) values (
      'a5111111-1111-4111-8111-111111111111',
      'e5111111-1111-4111-8111-111111111111',
      'invalid-error-source',
      '2031-01-12T01:00:00Z',
      repeat('f', 64),
      'failed',
      'raw_provider_response'
    )
  $sql$,
  '23514',
  'new row for relation "email_sources" violates check constraint "email_sources_error_category_allowed"',
  'source errors accept only non-sensitive allow-listed categories'
);

select extensions.throws_ok(
  $sql$
    insert into public.email_sources (
      owner_user_id,
      connection_id,
      provider_message_id,
      received_at,
      sanitized_content_hash
    ) values (
      'a5111111-1111-4111-8111-111111111111',
      'e5111111-1111-4111-8111-111111111111',
      'provider-message-a',
      '2031-01-12T02:00:00Z',
      repeat('1', 64)
    )
  $sql$,
  '23505',
  'duplicate key value violates unique constraint "email_sources_connection_message_key"',
  'a provider message cannot be inserted twice for one connection'
);

select extensions.lives_ok(
  $sql$
    insert into public.email_sources (
      id,
      owner_user_id,
      connection_id,
      provider_message_id,
      received_at,
      sanitized_content_hash
    ) values (
      'e6333333-3333-4333-8333-333333333333',
      'a5222222-2222-4222-8222-222222222222',
      'e5222222-2222-4222-8222-222222222222',
      'provider-message-a',
      '2031-01-12T03:00:00Z',
      repeat('2', 64)
    )
  $sql$,
  'the provider message identifier uniqueness is scoped to its connection'
);

delete from public.email_sources
where id = 'e6333333-3333-4333-8333-333333333333';

insert into public.assignments (
  id,
  owner_user_id,
  title,
  due_at,
  visibility_level
)
values (
  'e7111111-1111-4111-8111-111111111111',
  'a5111111-1111-4111-8111-111111111111',
  'Confirmed private assignment',
  '2031-02-01T01:00:00Z',
  'PRIVATE'
);

select extensions.throws_ok(
  $sql$
    insert into public.email_candidates (
      owner_user_id,
      source_id,
      candidate_type,
      validated_payload,
      review_state,
      error_category
    ) values (
      'a5222222-2222-4222-8222-222222222222',
      'e6222222-2222-4222-8222-222222222222',
      'unknown',
      '{"schema_version":"1.0"}'::jsonb,
      'failed',
      'model_stack_trace'
    )
  $sql$,
  '23514',
  'new row for relation "email_candidates" violates check constraint "email_candidates_error_category_allowed"',
  'candidate errors accept only non-sensitive allow-listed categories'
);

insert into public.email_candidates (
  id,
  owner_user_id,
  source_id,
  candidate_type,
  validated_payload,
  review_state,
  semantic_fingerprint,
  linked_entity_type,
  linked_entity_id,
  confirmation_idempotency_key,
  confirmed_at
)
values
  (
    'e8111111-1111-4111-8111-111111111111',
    'a5111111-1111-4111-8111-111111111111',
    'e6111111-1111-4111-8111-111111111111',
    'assignment',
    '{"schema_version":"1.0","requires_user_confirmation":true}'::jsonb,
    'confirmed',
    repeat('3', 64),
    'assignment',
    'e7111111-1111-4111-8111-111111111111',
    'foundation-confirmation-key',
    '2031-01-10T02:00:00Z'
  ),
  (
    'e8222222-2222-4222-8222-222222222222',
    'a5222222-2222-4222-8222-222222222222',
    'e6222222-2222-4222-8222-222222222222',
    'event',
    '{"schema_version":"1.0","requires_user_confirmation":true}'::jsonb,
    'needs_review',
    repeat('4', 64),
    null,
    null,
    null,
    null
  );

insert into public.email_candidate_updates (
  id,
  owner_user_id,
  candidate_id,
  source_id,
  proposal_fingerprint,
  field_diff
)
values
  (
    'e9111111-1111-4111-8111-111111111111',
    'a5111111-1111-4111-8111-111111111111',
    'e8111111-1111-4111-8111-111111111111',
    'e6111111-1111-4111-8111-111111111111',
    repeat('5', 64),
    '{"due.at":{"before":null,"after":"2031-02-01T01:00:00Z"}}'::jsonb
  ),
  (
    'e9222222-2222-4222-8222-222222222222',
    'a5222222-2222-4222-8222-222222222222',
    'e8222222-2222-4222-8222-222222222222',
    'e6222222-2222-4222-8222-222222222222',
    repeat('6', 64),
    '{"title":{"before":null,"after":"Review"}}'::jsonb
  );

insert into private.email_connection_credentials (
  connection_id,
  owner_user_id,
  encrypted_oauth_bundle,
  encryption_key_version,
  expires_at
)
values
  (
    'e5111111-1111-4111-8111-111111111111',
    'a5111111-1111-4111-8111-111111111111',
    decode(repeat('ab', 32), 'hex'),
    1,
    '2031-01-10T03:00:00Z'
  ),
  (
    'e5222222-2222-4222-8222-222222222222',
    'a5222222-2222-4222-8222-222222222222',
    decode(repeat('cd', 32), 'hex'),
    1,
    '2031-01-11T03:00:00Z'
  );

-- User A owns one complete derived chain and can read only that chain.
set local request.jwt.claims = '{"sub":"a5111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = 'a5111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is(
  (
    select count(*)
    from (
      select id from public.email_connections
      union all select id from public.email_sources
      union all select id from public.email_candidates
      union all select id from public.email_candidate_updates
    ) own_rows
  ),
  4::bigint,
  'User A can read exactly their own connection, source, candidate and update'
);

select extensions.is(
  (
    select count(*)
    from (
      select id from public.email_connections
      where owner_user_id = 'a5222222-2222-4222-8222-222222222222'
      union all
      select id from public.email_sources
      where owner_user_id = 'a5222222-2222-4222-8222-222222222222'
      union all
      select id from public.email_candidates
      where owner_user_id = 'a5222222-2222-4222-8222-222222222222'
      union all
      select id from public.email_candidate_updates
      where owner_user_id = 'a5222222-2222-4222-8222-222222222222'
    ) foreign_rows
  ),
  0::bigint,
  'User A cannot read any User B email row'
);

select extensions.throws_ok(
  $sql$
    insert into public.email_connections (
      owner_user_id,
      provider_account_hash
    ) values (
      'a5222222-2222-4222-8222-222222222222',
      repeat('7', 64)
    )
  $sql$,
  '42501',
  'permission denied for table email_connections',
  'User A cannot insert email data for User B'
);

select extensions.throws_ok(
  $sql$
    update public.email_connections
    set connection_state = 'disconnecting'
    where owner_user_id = 'a5222222-2222-4222-8222-222222222222'
  $sql$,
  '42501',
  'permission denied for table email_connections',
  'User A cannot update User B email data'
);

select extensions.throws_ok(
  $sql$
    delete from public.email_connections
    where owner_user_id = 'a5222222-2222-4222-8222-222222222222'
  $sql$,
  '42501',
  'permission denied for table email_connections',
  'User A cannot delete User B email data'
);

-- An unrelated authenticated user sees no derived rows at all.
reset role;
set local request.jwt.claims = '{"sub":"a5333333-3333-4333-8333-333333333333","role":"authenticated"}';
set local request.jwt.claim.sub = 'a5333333-3333-4333-8333-333333333333';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is(
  (
    select count(*)
    from (
      select id from public.email_connections
      union all select id from public.email_sources
      union all select id from public.email_candidates
      union all select id from public.email_candidate_updates
    ) unrelated_rows
  ),
  0::bigint,
  'an unrelated authenticated user sees zero email rows'
);

-- Application admin claims do not bypass owner RLS or reveal credentials.
reset role;
set local request.jwt.claims = '{"sub":"a5444444-4444-4444-8444-444444444444","role":"authenticated","app_metadata":{"app_role":"admin"}}';
set local request.jwt.claim.sub = 'a5444444-4444-4444-8444-444444444444';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is(
  (
    select count(*)
    from (
      select id from public.email_connections
      union all select id from public.email_sources
      union all select id from public.email_candidates
      union all select id from public.email_candidate_updates
    ) admin_rows
  ),
  0::bigint,
  'an application-admin claim still sees zero foreign email rows'
);

select extensions.throws_ok(
  $sql$ select count(*) from private.email_connection_credentials $sql$,
  '42501',
  'permission denied for table email_connection_credentials',
  'an application-admin claim cannot inspect private OAuth material'
);

-- User B independently sees only their own chain.
reset role;
set local request.jwt.claims = '{"sub":"a5222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = 'a5222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is(
  (
    select count(*)
    from (
      select id from public.email_connections
      union all select id from public.email_sources
      union all select id from public.email_candidates
      union all select id from public.email_candidate_updates
    ) own_rows
  ),
  4::bigint,
  'User B can read exactly their own connection, source, candidate and update'
);

-- A trusted disconnect removes only provider-derived data and sealed material.
reset role;
set local role service_role;

select extensions.lives_ok(
  $sql$
    delete from public.email_connections
    where id = 'e5111111-1111-4111-8111-111111111111'
  $sql$,
  'the trusted Edge role can delete a disconnected connection'
);

reset role;

select extensions.is(
  (
    select count(*)
    from (
      select id from public.email_connections
      where owner_user_id = 'a5111111-1111-4111-8111-111111111111'
      union all
      select id from public.email_sources
      where owner_user_id = 'a5111111-1111-4111-8111-111111111111'
      union all
      select id from public.email_candidates
      where owner_user_id = 'a5111111-1111-4111-8111-111111111111'
      union all
      select id from public.email_candidate_updates
      where owner_user_id = 'a5111111-1111-4111-8111-111111111111'
    ) derived_rows
  ),
  0::bigint,
  'disconnect deletion cascades through all User A provider-derived rows'
);

select extensions.is(
  (
    select count(*)
    from private.email_connection_credentials
    where owner_user_id = 'a5111111-1111-4111-8111-111111111111'
  ),
  0::bigint,
  'disconnect deletion also destroys User A sealed OAuth material'
);

select extensions.ok(
  (
    select owner_user_id = 'a5111111-1111-4111-8111-111111111111'
      and visibility_level = 'PRIVATE'
    from public.assignments
    where id = 'e7111111-1111-4111-8111-111111111111'
  ),
  'the confirmed PRIVATE user-owned Assignment survives derived email deletion'
);

select * from extensions.finish();
rollback;
