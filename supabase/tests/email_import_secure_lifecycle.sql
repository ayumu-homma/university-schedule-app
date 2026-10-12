begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(101);

-- 01
select extensions.has_table(
  'private',
  'email_oauth_sessions',
  'OAuth PKCE state is stored only in the private schema'
);
select extensions.has_table(
  'private',
  'email_oauth_completion_receipts',
  'OAuth completion correlation is stored only in the private schema'
);
-- 02
select extensions.has_table(
  'public',
  'email_import_audit_events',
  'safe email lifecycle audit state is owner-readable'
);
-- 03
select extensions.has_column(
  'private',
  'email_connection_credentials',
  'credential_version',
  'sealed credentials support compare-and-swap rotation'
);
-- 04
select extensions.ok(
  (
    select bool_and(c.relrowsecurity)
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where (n.nspname, c.relname) in (
      ('private', 'email_oauth_sessions'),
      ('private', 'email_oauth_completion_receipts'),
      ('public', 'email_import_audit_events')
    )
  ),
  'RLS is enabled for OAuth sessions and safe audit rows'
);
-- 05
select extensions.is_empty(
  $sql$
    select c.relname, a.attname
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_class c on c.oid = a.attrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('public', 'graphql_public')
      and c.relname like 'email%'
      and a.attnum > 0
      and not a.attisdropped
      and a.attname ~* '(^|_)(token|credential|credentials|raw_body|body_html|body_text|message_body|body|email_address|sender)($|_)'
  $sql$,
  'no exposed email column can store tokens, credentials, addresses, senders, or bodies'
);
-- 06
select extensions.ok(
  not pg_catalog.has_table_privilege('anon', 'private.email_oauth_sessions', 'SELECT')
  and not pg_catalog.has_table_privilege('authenticated', 'private.email_oauth_sessions', 'SELECT')
  and not pg_catalog.has_table_privilege('service_role', 'private.email_oauth_sessions', 'SELECT')
  and not pg_catalog.has_table_privilege('anon', 'private.email_connection_credentials', 'SELECT')
  and not pg_catalog.has_table_privilege('authenticated', 'private.email_connection_credentials', 'SELECT')
  and not pg_catalog.has_table_privilege('service_role', 'private.email_connection_credentials', 'SELECT')
  and not pg_catalog.has_table_privilege('anon', 'private.email_oauth_completion_receipts', 'SELECT')
  and not pg_catalog.has_table_privilege('authenticated', 'private.email_oauth_completion_receipts', 'SELECT')
  and not pg_catalog.has_table_privilege('service_role', 'private.email_oauth_completion_receipts', 'SELECT'),
  'OAuth sessions, completion receipts, and credentials have no direct table read grant'
);
-- 07
select extensions.ok(
  pg_catalog.has_table_privilege('authenticated', 'public.email_import_audit_events', 'SELECT')
  and not pg_catalog.has_table_privilege('authenticated', 'public.email_import_audit_events', 'INSERT')
  and not pg_catalog.has_table_privilege('authenticated', 'public.email_import_audit_events', 'UPDATE')
  and not pg_catalog.has_table_privilege('authenticated', 'public.email_import_audit_events', 'DELETE'),
  'authenticated users can read but never write safe audit rows directly'
);
-- 08
select extensions.is(
  (
    select count(*)
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'email_import_begin_oauth',
        'email_import_take_oauth',
        'email_import_complete_oauth',
        'email_import_check_authorization',
        'email_import_get_credentials',
        'email_import_rotate_credentials',
        'email_import_persist_sync_page',
        'email_import_finalize_disconnect',
        'email_import_delete_account_data',
        'email_import_record_failure',
        'email_import_reconcile_confirmation',
        'email_import_reconcile_dismissal',
        'email_import_reconcile_update'
      )
      and pg_catalog.has_function_privilege('service_role', p.oid, 'EXECUTE')
  ),
  13::bigint,
  'service_role can execute all thirteen narrow lifecycle and reconciliation RPCs'
);
-- 09
select extensions.is(
  (
    select count(*)
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname like 'email_import_%'
      and pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ),
  0::bigint,
  'authenticated clients cannot invoke trusted email mutation RPCs'
);

insert into auth.users (id)
values
  ('b5111111-1111-4111-8111-111111111111'),
  ('b5222222-2222-4222-8222-222222222222');

create temporary table email_secure_payloads (
  fixture_key text primary key,
  payload jsonb not null
) on commit drop;

insert into email_secure_payloads (fixture_key, payload)
values
  (
    'base',
    '{
      "schema_version":"1.0",
      "candidate_type":"assignment",
      "title":"レポート提出",
      "course_hint":{"name":"情報科学","code":"CS101"},
      "due":{"at":"2031-02-01T01:00:00Z","all_day":false,"timezone":"Asia/Tokyo","raw_text":"2月1日10時"},
      "start_at":null,
      "end_at":null,
      "location":null,
      "submission_url":"https://lms.invalid/tasks/1",
      "summary":"提出案内",
      "suggested_reminders_minutes":[1440,180],
      "confidence":{"overall":0.9,"title":0.9,"course":0.8,"date_time":0.8},
      "evidence":[],
      "warnings":[],
      "requires_user_confirmation":true
    }'::jsonb
  ),
  (
    'changed',
    '{
      "schema_version":"1.0",
      "candidate_type":"assignment",
      "title":"レポート提出",
      "course_hint":{"name":"情報科学","code":"CS101"},
      "due":{"at":"2031-02-03T01:00:00Z","all_day":false,"timezone":"Asia/Tokyo","raw_text":"2月3日10時"},
      "start_at":null,
      "end_at":null,
      "location":null,
      "submission_url":"https://lms.invalid/tasks/1",
      "summary":"期限変更",
      "suggested_reminders_minutes":[1440,180],
      "confidence":{"overall":0.9,"title":0.9,"course":0.8,"date_time":0.9},
      "evidence":[],
      "warnings":[],
      "requires_user_confirmation":true
    }'::jsonb
  ),
  (
    'metadata_changed',
    '{
      "schema_version":"1.0",
      "candidate_type":"assignment",
      "title":"レポート提出",
      "course_hint":{"name":"情報科学","code":"CS101"},
      "due":{"at":"2031-02-01T01:00:00Z","all_day":false,"timezone":"Asia/Tokyo","raw_text":"2月1日10時"},
      "start_at":null,
      "end_at":null,
      "location":"第2講義室",
      "submission_url":"https://lms.invalid/tasks/1",
      "summary":"教室と通知を変更",
      "suggested_reminders_minutes":[60],
      "confidence":{"overall":0.9,"title":0.9,"course":0.8,"date_time":0.8},
      "evidence":[],
      "warnings":[],
      "requires_user_confirmation":true
    }'::jsonb
  ),
  (
    'accepted_changed',
    '{
      "schema_version":"1.0",
      "candidate_type":"assignment",
      "title":"レポート提出",
      "course_hint":{"name":"情報科学","code":"CS101"},
      "due":{"at":"2031-02-05T01:00:00Z","all_day":false,"timezone":"Asia/Tokyo","raw_text":"2月5日10時"},
      "start_at":null,
      "end_at":null,
      "location":null,
      "submission_url":"https://lms.invalid/tasks/1",
      "summary":"再変更",
      "suggested_reminders_minutes":[120],
      "confidence":{"overall":0.9,"title":0.9,"course":0.8,"date_time":0.9},
      "evidence":[],
      "warnings":[],
      "requires_user_confirmation":true
    }'::jsonb
  ),
  (
    'rejected_changed',
    '{
      "schema_version":"1.0",
      "candidate_type":"assignment",
      "title":"レポート提出（再通知）",
      "course_hint":{"name":"情報科学","code":"CS101"},
      "due":{"at":"2031-02-05T01:00:00Z","all_day":false,"timezone":"Asia/Tokyo","raw_text":"2月5日10時"},
      "start_at":null,
      "end_at":null,
      "location":null,
      "submission_url":"https://lms.invalid/tasks/1",
      "summary":"却下する変更",
      "suggested_reminders_minutes":[30],
      "confidence":{"overall":0.9,"title":0.9,"course":0.8,"date_time":0.9},
      "evidence":[],
      "warnings":[],
      "requires_user_confirmation":true
    }'::jsonb
  );

insert into email_secure_payloads (fixture_key, payload)
values
  (
    'exam_timezone_base',
    '{
      "schema_version":"1.0",
      "candidate_type":"exam",
      "title":"Timezone exam",
      "course_hint":{"name":null,"code":null},
      "due":{"at":null,"all_day":false,"timezone":"Asia/Tokyo","raw_text":null},
      "start_at":"2031-03-08T06:30:00Z",
      "end_at":"2031-03-08T07:30:00Z",
      "location":"Exam room",
      "submission_url":null,
      "summary":"Timezone parity fixture",
      "suggested_reminders_minutes":[60],
      "confidence":{"overall":0.9,"title":0.9,"course":0.8,"date_time":0.9},
      "evidence":[],
      "warnings":[],
      "requires_user_confirmation":true
    }'::jsonb
  ),
  (
    'event_timezone_base',
    '{
      "schema_version":"1.0",
      "candidate_type":"event",
      "title":"Timezone event",
      "course_hint":{"name":null,"code":null},
      "due":{"at":null,"all_day":false,"timezone":"Asia/Tokyo","raw_text":null},
      "start_at":"2031-03-08T08:30:00Z",
      "end_at":"2031-03-08T09:30:00Z",
      "location":"Event room",
      "submission_url":null,
      "summary":"Timezone parity fixture",
      "suggested_reminders_minutes":[30],
      "confidence":{"overall":0.9,"title":0.9,"course":0.8,"date_time":0.9},
      "evidence":[],
      "warnings":[],
      "requires_user_confirmation":true
    }'::jsonb
  );

insert into email_secure_payloads (fixture_key, payload)
select fixture_key || '_changed',
  jsonb_set(payload, '{due,timezone}', '"America/New_York"'::jsonb)
from email_secure_payloads
where fixture_key in ('exam_timezone_base', 'event_timezone_base');

select extensions.is(
  private.email_import_candidate_diff(
    (select payload from email_secure_payloads where fixture_key = 'exam_timezone_base'),
    (select payload from email_secure_payloads where fixture_key = 'exam_timezone_base_changed')
  ),
  '{"due_timezone":{"before":"Asia/Tokyo","after":"America/New_York"}}'::jsonb,
  'Exam timezone-only changes remain an explicit field diff'
);

select extensions.ok(
  private.email_import_update_fingerprint(
    (select payload from email_secure_payloads where fixture_key = 'exam_timezone_base')
  ) <> private.email_import_update_fingerprint(
    (select payload from email_secure_payloads where fixture_key = 'exam_timezone_base_changed')
  ),
  'Exam update fingerprints include the review and notification timezone'
);

select extensions.is(
  private.email_import_candidate_diff(
    (select payload from email_secure_payloads where fixture_key = 'event_timezone_base'),
    (select payload from email_secure_payloads where fixture_key = 'event_timezone_base_changed')
  ),
  '{"due_timezone":{"before":"Asia/Tokyo","after":"America/New_York"}}'::jsonb,
  'Event timezone-only changes remain an explicit field diff'
);

select extensions.ok(
  private.email_import_update_fingerprint(
    (select payload from email_secure_payloads where fixture_key = 'event_timezone_base')
  ) <> private.email_import_update_fingerprint(
    (select payload from email_secure_payloads where fixture_key = 'event_timezone_base_changed')
  ),
  'Event update fingerprints include the review and notification timezone'
);

grant select on email_secure_payloads to service_role;

set local role service_role;

-- 10
select extensions.lives_ok(
  $sql$
    select public.email_import_begin_oauth(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      repeat('a', 64),
      decode(repeat('ab', 32), 'hex'),
      1,
      now() + interval '5 minutes',
      'b7111111-1111-4111-8111-111111111111'
    )
  $sql$,
  'trusted OAuth begin stores only encrypted, expiring state'
);
reset role;

-- 11
select extensions.ok(
  (
    select owner_user_id = 'b5111111-1111-4111-8111-111111111111'
      and provider = 'gmail'
      and connection_state = 'connecting'
      and authorized_scopes = array['https://www.googleapis.com/auth/gmail.readonly']::text[]
    from public.email_connections
    where id = 'b6111111-1111-4111-8111-111111111111'
  ),
  'OAuth begin creates owner-bound connecting metadata with the minimum scope'
);
-- 12
select extensions.ok(
  (
    select state_hash = repeat('a', 64)
      and octet_length(encrypted_pkce_verifier) = 32
      and expires_at > created_at
    from private.email_oauth_sessions
    where connection_id = 'b6111111-1111-4111-8111-111111111111'
  ),
  'only a state hash and encrypted PKCE verifier are retained'
);

set local role service_role;
create temporary table taken_oauth as
select public.email_import_take_oauth(repeat('a', 64), now()) result;
reset role;

-- 13
select extensions.ok(
  (
    select result ->> 'owner_user_id' = 'b5111111-1111-4111-8111-111111111111'
      and result ->> 'connection_id' = 'b6111111-1111-4111-8111-111111111111'
      and result ->> 'encrypted_pkce_verifier_base64' = encode(decode(repeat('ab', 32), 'hex'), 'base64')
    from taken_oauth
  ),
  'OAuth take returns the encrypted verifier only to the trusted caller'
);
-- 14
select extensions.is(
  (select count(*) from private.email_oauth_sessions),
  0::bigint,
  'OAuth state is deleted atomically on first consumption'
);

set local role service_role;
-- 15
select extensions.is(
  public.email_import_take_oauth(repeat('a', 64), now()),
  null::jsonb,
  'a consumed OAuth state cannot be replayed'
);
-- 16
select extensions.lives_ok(
  $sql$
    select public.email_import_complete_oauth(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      repeat('c', 64),
      array['https://www.googleapis.com/auth/gmail.readonly']::text[],
      decode(repeat('cd', 64), 'hex'),
      1,
      now() + interval '1 hour',
      null,
      now(),
      'b7111111-1111-4111-8111-111111111111'
    )
  $sql$,
  'OAuth completion stores only encrypted token material and safe metadata'
);
reset role;

set local role service_role;
select extensions.is(
  public.email_import_check_authorization(
    'b5111111-1111-4111-8111-111111111111',
    'b6111111-1111-4111-8111-111111111111',
    'b7111111-1111-4111-8111-111111111111'
  ) ->> 'effective_connection_id',
  'b6111111-1111-4111-8111-111111111111',
  'OAuth completion resolves only through its exact owner/request/correlation receipt'
);
select extensions.is(
  public.email_import_check_authorization(
    'b5111111-1111-4111-8111-111111111111',
    'b6111111-1111-4111-8111-111111111111',
    'b7111111-1111-4111-8111-111111111112'
  ),
  null::jsonb,
  'an unrelated callback correlation cannot resolve an OAuth attempt'
);
select extensions.is(
  public.email_import_check_authorization(
    'b5222222-2222-4222-8222-222222222222',
    'b6111111-1111-4111-8111-111111111111',
    'b7111111-1111-4111-8111-111111111111'
  ),
  null::jsonb,
  'another owner cannot resolve an OAuth attempt receipt'
);
reset role;

select extensions.lives_ok(
  $sql$
    select private.email_import_write_audit(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'b7111111-1111-4111-8111-111111111111',
      'oauth_callback',
      'succeeded',
      'connected',
      null,
      now()
    )
  $sql$,
  'an exact duplicate OAuth callback audit is idempotent'
);
select extensions.is(
  (
    select count(*)
    from private.email_oauth_completion_receipts
    where owner_user_id = 'b5111111-1111-4111-8111-111111111111'
      and requested_connection_id = 'b6111111-1111-4111-8111-111111111111'
      and correlation_id = 'b7111111-1111-4111-8111-111111111111'
  ),
  1::bigint,
  'an exact callback replay cannot duplicate its authorization receipt'
);
select extensions.throws_ok(
  $sql$
    select private.email_import_write_audit(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'b7111111-1111-4111-8111-111111111111',
      'oauth_callback',
      'failed',
      'failed',
      'provider_unavailable',
      now()
    )
  $sql$,
  '23505',
  'OAuth callback correlation conflict.',
  'conflicting callback reuse of a completed correlation fails closed'
);

insert into auth.users (id)
values ('b5444444-4444-4444-8444-444444444444');

select extensions.lives_ok(
  $sql$
    do $body$
    begin
      perform private.email_import_write_audit(
        'b5444444-4444-4444-8444-444444444444',
        'b6444444-4444-4444-8444-444444444441',
        'b7444444-4444-4444-8444-444444444441',
        'connect',
        'started',
        'connecting',
        null,
        now()
      );
      perform private.email_import_write_audit(
        'b5444444-4444-4444-8444-444444444444',
        'b6444444-4444-4444-8444-444444444441',
        'b7444444-4444-4444-8444-444444444441',
        'oauth_callback',
        'failed',
        'failed',
        'provider_unavailable',
        now()
      );
    end
    $body$;
  $sql$,
  'a safe failed callback audit survives a missing connection row'
);
select extensions.ok(
  (
    select effective_connection_id is null
      and callback_outcome = 'failed'
      and connection_state = 'failed'
      and error_category = 'provider_unavailable'
    from private.email_oauth_completion_receipts
    where owner_user_id = 'b5444444-4444-4444-8444-444444444444'
      and requested_connection_id = 'b6444444-4444-4444-8444-444444444441'
      and correlation_id = 'b7444444-4444-4444-8444-444444444441'
  ) and (
    select public.email_import_check_authorization(
      'b5444444-4444-4444-8444-444444444444',
      'b6444444-4444-4444-8444-444444444441',
      'b7444444-4444-4444-8444-444444444441'
    ) ->> 'connection_state' = 'failed'
  ),
  'missing-row failures remain correlation-bound and safely resolvable'
);

delete from auth.users
where id = 'b5444444-4444-4444-8444-444444444444';

insert into auth.users (id)
values ('b5333333-3333-4333-8333-333333333333');

set local role service_role;
select extensions.lives_ok(
  $sql$
    do $body$
    begin
      perform public.email_import_begin_oauth(
        'b5333333-3333-4333-8333-333333333333',
        'b6333333-3333-4333-8333-333333333331',
        repeat('1', 64),
        decode(repeat('11', 32), 'hex'),
        1,
        now() + interval '5 minutes',
        'b7333333-3333-4333-8333-333333333331'
      );
      perform public.email_import_take_oauth(repeat('1', 64), now());
      perform public.email_import_complete_oauth(
        'b5333333-3333-4333-8333-333333333333',
        'b6333333-3333-4333-8333-333333333331',
        repeat('e', 64),
        array['https://www.googleapis.com/auth/gmail.readonly']::text[],
        decode(repeat('12', 32), 'hex'),
        1,
        now() + interval '1 hour',
        null,
        now(),
        'b7333333-3333-4333-8333-333333333331'
      );

      perform public.email_import_begin_oauth(
        'b5333333-3333-4333-8333-333333333333',
        'b6333333-3333-4333-8333-333333333332',
        repeat('2', 64),
        decode(repeat('21', 32), 'hex'),
        1,
        now() + interval '5 minutes',
        'b7333333-3333-4333-8333-333333333332'
      );
      perform public.email_import_take_oauth(repeat('2', 64), now());
      perform public.email_import_complete_oauth(
        'b5333333-3333-4333-8333-333333333333',
        'b6333333-3333-4333-8333-333333333332',
        repeat('e', 64),
        array['https://www.googleapis.com/auth/gmail.readonly']::text[],
        decode(repeat('22', 32), 'hex'),
        1,
        now() + interval '1 hour',
        null,
        now(),
        'b7333333-3333-4333-8333-333333333332'
      );

      perform public.email_import_begin_oauth(
        'b5333333-3333-4333-8333-333333333333',
        'b6333333-3333-4333-8333-333333333333',
        repeat('3', 64),
        decode(repeat('31', 32), 'hex'),
        1,
        now() + interval '5 minutes',
        'b7333333-3333-4333-8333-333333333333'
      );
      perform public.email_import_take_oauth(repeat('3', 64), now());
      perform public.email_import_complete_oauth(
        'b5333333-3333-4333-8333-333333333333',
        'b6333333-3333-4333-8333-333333333333',
        repeat('f', 64),
        array['https://www.googleapis.com/auth/gmail.readonly']::text[],
        decode(repeat('32', 32), 'hex'),
        1,
        now() + interval '1 hour',
        null,
        now(),
        'b7333333-3333-4333-8333-333333333333'
      );
    end
    $body$;
  $sql$,
  'duplicate and unrelated Gmail account completions produce private correlation receipts'
);
select extensions.ok(
  not exists (
    select 1 from public.email_connections
    where id = 'b6333333-3333-4333-8333-333333333332'
  )
  and exists (
    select 1 from public.email_connections
    where id = 'b6333333-3333-4333-8333-333333333331'
  )
  and exists (
    select 1 from public.email_connections
    where id = 'b6333333-3333-4333-8333-333333333333'
  )
  and public.email_import_check_authorization(
    'b5333333-3333-4333-8333-333333333333',
    'b6333333-3333-4333-8333-333333333332',
    'b7333333-3333-4333-8333-333333333332'
  ) ->> 'effective_connection_id' =
    'b6333333-3333-4333-8333-333333333331',
  'duplicate completion resolves its effective connection instead of a newer unrelated account row'
);
reset role;

delete from public.email_connections
where owner_user_id = 'b5333333-3333-4333-8333-333333333333';
delete from public.email_import_audit_events
where owner_user_id = 'b5333333-3333-4333-8333-333333333333';
delete from auth.users
where id = 'b5333333-3333-4333-8333-333333333333';

-- OAuth callback failure regression: consumed state must not strand metadata.
set local role service_role;
select extensions.lives_ok(
  $sql$
    with started as (
      select public.email_import_begin_oauth(
        'b5111111-1111-4111-8111-111111111111',
        'b6111111-1111-4111-8111-111111111113',
        repeat('f', 64),
        decode(repeat('45', 32), 'hex'),
        1,
        now() + interval '5 minutes',
        'b7111111-1111-4111-8111-111111111130'
      )
    ), consumed as (
      select public.email_import_take_oauth(repeat('f', 64), now())
      from started
    )
    select public.email_import_record_failure(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111113',
      'oauth_callback',
      'failed',
      'provider_unavailable',
      null,
      now(),
      'b7111111-1111-4111-8111-111111111130'
    )
    from consumed
  $sql$,
  'a consumed OAuth attempt records an owner-bound callback failure'
);
reset role;

select extensions.ok(
  (
    select connection_state = 'failed'
      and last_error_category = 'provider_unavailable'
    from public.email_connections
    where id = 'b6111111-1111-4111-8111-111111111113'
  ) and exists (
    select 1
    from public.email_import_audit_events
    where connection_id = 'b6111111-1111-4111-8111-111111111113'
      and operation = 'oauth_callback'
      and outcome = 'failed'
  ) and (
    select public.email_import_check_authorization(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111113',
      'b7111111-1111-4111-8111-111111111130'
    ) ->> 'connection_state' = 'failed'
  ),
  'OAuth callback failure leaves no connection stuck in connecting state'
);

-- 17
select extensions.ok(
  (
    select connection_state = 'connected'
      and provider_account_hash = repeat('c', 64)
      and connected_at is not null
    from public.email_connections
    where id = 'b6111111-1111-4111-8111-111111111111'
  ),
  'OAuth completion exposes only connected state and an account hash'
);
-- 18
select extensions.ok(
  (
    select octet_length(encrypted_oauth_bundle) = 64
      and encryption_key_version = 1
      and credential_version = 1
    from private.email_connection_credentials
    where connection_id = 'b6111111-1111-4111-8111-111111111111'
  ),
  'sealed credentials start at compare-and-swap version one'
);

set local role service_role;
-- 19
select extensions.is(
  public.email_import_get_credentials(
    'b5222222-2222-4222-8222-222222222222',
    'b6111111-1111-4111-8111-111111111111'
  ),
  null::jsonb,
  'credential reads fail closed on an owner mismatch'
);
-- 20
select extensions.ok(
  (
    public.email_import_get_credentials(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111'
    ) ->> 'encrypted_oauth_bundle_base64'
  ) = encode(decode(repeat('cd', 64), 'hex'), 'base64'),
  'trusted credential reads return ciphertext as base64, never a raw token'
);
-- 21
select extensions.lives_ok(
  $sql$
    select public.email_import_rotate_credentials(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      1,
      decode(repeat('ef', 64), 'hex'),
      2,
      now() + interval '2 hours',
      now(),
      'b7111111-1111-4111-8111-111111111112'
    )
  $sql$,
  'credential refresh rotates ciphertext with a version CAS'
);
reset role;

-- 22
select extensions.is(
  (
    select credential_version
    from private.email_connection_credentials
    where connection_id = 'b6111111-1111-4111-8111-111111111111'
  ),
  2::bigint,
  'credential rotation increments the durable version'
);

set local role service_role;
-- 23
select extensions.throws_ok(
  $sql$
    select public.email_import_rotate_credentials(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      1,
      decode(repeat('01', 64), 'hex'),
      2,
      now() + interval '2 hours',
      now(),
      'b7111111-1111-4111-8111-111111111113'
    )
  $sql$,
  '40001',
  'Credential state changed.',
  'a stale credential refresh cannot overwrite newer ciphertext'
);

-- 24
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      null,
      'cursor-1',
      jsonb_build_array(
        jsonb_build_object(
          'provider_message_id', 'message-base',
          'provider_thread_id', 'thread-base',
          'received_at', '2031-01-01T00:00:00Z',
          'sanitized_content_hash', repeat('1', 64),
          'evidence_metadata', jsonb_build_array('締切 2月1日'),
          'processing_state', 'processed',
          'error_category', null
        ),
        jsonb_build_object(
          'provider_message_id', 'message-dismiss',
          'provider_thread_id', 'thread-dismiss',
          'received_at', '2031-01-01T00:01:00Z',
          'sanitized_content_hash', repeat('2', 64),
          'evidence_metadata', jsonb_build_array('提出案内'),
          'processing_state', 'processed',
          'error_category', null
        )
      ),
      jsonb_build_array(
        jsonb_build_object(
          'provider_message_id', 'message-base',
          'validated_payload', (select payload from email_secure_payloads where fixture_key = 'base'),
          'error_category', null
        ),
        jsonb_build_object(
          'provider_message_id', 'message-dismiss',
          'validated_payload', (select payload from email_secure_payloads where fixture_key = 'base'),
          'error_category', null
        )
      ),
      false,
      now(),
      'b7111111-1111-4111-8111-111111111114'
    )
  $sql$,
  'a validated safe page persists atomically with its cursor'
);
reset role;

-- 25
select extensions.ok(
  (select count(*) = 2 from public.email_sources where owner_user_id = 'b5111111-1111-4111-8111-111111111111')
  and (select count(*) = 2 from public.email_candidates where owner_user_id = 'b5111111-1111-4111-8111-111111111111'),
  'the first page creates one source and one candidate per message'
);

set local role service_role;
-- 26
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'cursor-1',
      'cursor-2',
      jsonb_build_array(
        jsonb_build_object(
          'provider_message_id', 'message-base',
          'provider_thread_id', 'thread-base',
          'received_at', '2031-01-01T00:00:00Z',
          'sanitized_content_hash', repeat('1', 64),
          'evidence_metadata', jsonb_build_array('締切 2月1日'),
          'processing_state', 'processed',
          'error_category', null
        )
      ),
      jsonb_build_array(
        jsonb_build_object(
          'provider_message_id', 'message-base',
          'validated_payload', (select payload from email_secure_payloads where fixture_key = 'base'),
          'error_category', null
        )
      ),
      false,
      now(),
      'b7111111-1111-4111-8111-111111111115'
    )
  $sql$,
  'repeating the same fixture advances the cursor without duplicating data'
);
reset role;

-- 27
select extensions.ok(
  (select count(*) = 2 from public.email_sources where owner_user_id = 'b5111111-1111-4111-8111-111111111111')
  and (select count(*) = 2 from public.email_candidates where owner_user_id = 'b5111111-1111-4111-8111-111111111111'),
  'repeated fixture synchronization remains one source and one candidate'
);

update public.email_candidates c
set review_state = 'dismissed',
    dismissed_at = now(),
    updated_at = now()
from public.email_sources s
where c.source_id = s.id
  and s.provider_message_id = 'message-dismiss';

-- 28
select extensions.ok(
  (
    select c.validated_payload = '{}'::jsonb
      and c.semantic_fingerprint ~ '^[0-9a-f]{64}$'
      and s.evidence_metadata = '[]'::jsonb
      and s.processing_state = 'ignored'
    from public.email_candidates c
    join public.email_sources s on s.id = c.source_id
    where s.provider_message_id = 'message-dismiss'
  ),
  'dismissal keeps only provider/hash/fingerprint suppression data'
);

set local role service_role;
-- 29
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'cursor-2',
      'cursor-3',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-dismiss-repeat',
        'provider_thread_id', 'thread-dismiss',
        'received_at', '2031-01-02T00:00:00Z',
        'sanitized_content_hash', repeat('8', 64),
        'evidence_metadata', jsonb_build_array('提出案内'),
        'processing_state', 'processed',
        'error_category', null
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-dismiss-repeat',
        'validated_payload', (select payload from email_secure_payloads where fixture_key = 'base'),
        'error_category', null
      )),
      false,
      now(),
      'b7111111-1111-4111-8111-111111111116'
    )
  $sql$,
  'a same-thread dismissed fixture is safely suppressed'
);
reset role;

-- 30
select extensions.ok(
  (
    select count(*) = 1
    from public.email_candidates c
    join public.email_sources s on s.id = c.source_id
    where s.provider_thread_id = 'thread-dismiss'
  ) and (
    select processing_state = 'ignored'
    from public.email_sources
    where provider_message_id = 'message-dismiss-repeat'
  ),
  'dismissed repeat creates no new candidate and marks its source ignored'
);

insert into public.assignments (
  id,
  owner_user_id,
  title,
  due_at,
  visibility_level
) values (
  'b8111111-1111-4111-8111-111111111111',
  'b5111111-1111-4111-8111-111111111111',
  'Confirmed assignment',
  '2031-02-01T01:00:00Z',
  'PRIVATE'
);

-- 31
select extensions.lives_ok(
  $sql$
    update public.email_candidates c
    set review_state = 'confirmed',
        linked_entity_type = 'assignment',
        linked_entity_id = 'b8111111-1111-4111-8111-111111111111',
        confirmation_idempotency_key = 'legacy-test-confirmation',
        confirmed_at = now(),
        updated_at = now()
    from public.email_sources s
    where c.source_id = s.id
      and s.provider_message_id = 'message-base'
  $sql$,
  'the base candidate can represent an explicitly confirmed private assignment'
);

set local role service_role;
-- 32
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'cursor-3',
      'cursor-4',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-update',
        'provider_thread_id', 'thread-base',
        'received_at', '2031-01-03T00:00:00Z',
        'sanitized_content_hash', repeat('3', 64),
        'evidence_metadata', jsonb_build_array('期限変更'),
        'processing_state', 'processed',
        'error_category', null
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-update',
        'validated_payload', (select payload from email_secure_payloads where fixture_key = 'changed'),
        'error_category', null
      )),
      false,
      now(),
      'b7111111-1111-4111-8111-111111111117'
    )
  $sql$,
  'a changed message in the confirmed thread creates an update proposal'
);
reset role;

-- 33
select extensions.ok(
  (
    select review_state = 'update_available'
    from public.email_candidates
    where linked_entity_id = 'b8111111-1111-4111-8111-111111111111'
  ) and (
    select count(*) = 1
    from public.email_candidate_updates
    where owner_user_id = 'b5111111-1111-4111-8111-111111111111'
      and resolution_state = 'pending'
      and field_diff ? 'due_at'
  ),
  'update_available retains one bounded field-level due diff'
);
-- 34
select extensions.ok(
  (
    select due_at = '2031-02-01T01:00:00Z'::timestamptz
      and visibility_level = 'PRIVATE'
    from public.assignments
    where id = 'b8111111-1111-4111-8111-111111111111'
  ),
  'a proposal never silently overwrites the confirmed private entity'
);

set local role service_role;
-- 35
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'cursor-4',
      'cursor-5',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-update',
        'provider_thread_id', 'thread-base',
        'received_at', '2031-01-03T00:00:00Z',
        'sanitized_content_hash', repeat('3', 64),
        'evidence_metadata', jsonb_build_array('期限変更'),
        'processing_state', 'processed',
        'error_category', null
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-update',
        'validated_payload', (select payload from email_secure_payloads where fixture_key = 'changed'),
        'error_category', null
      )),
      false,
      now(),
      'b7111111-1111-4111-8111-111111111118'
    )
  $sql$,
  'replaying the changed source is idempotent'
);
reset role;

-- 36
select extensions.is(
  (
    select count(*)
    from public.email_candidate_updates
    where owner_user_id = 'b5111111-1111-4111-8111-111111111111'
  ),
  1::bigint,
  'the same changed message still has exactly one update proposal'
);

set local role service_role;
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'cursor-5',
      'cursor-6',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-update-metadata',
        'provider_thread_id', 'thread-base',
        'received_at', '2031-01-03T01:00:00Z',
        'sanitized_content_hash', repeat('4', 64),
        'evidence_metadata', jsonb_build_array('教室と通知を変更'),
        'processing_state', 'processed',
        'error_category', null
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-update-metadata',
        'validated_payload', (select payload from email_secure_payloads where fixture_key = 'metadata_changed'),
        'error_category', null
      )),
      false,
      now(),
      'b7111111-1111-4111-8111-111111111132'
    )
  $sql$,
  'a same-fingerprint change to other actionable fields creates a proposal'
);
reset role;

select extensions.ok(
  (
    select count(*) = 1
    from public.email_candidate_updates
    where owner_user_id = 'b5111111-1111-4111-8111-111111111111'
      and resolution_state = 'pending'
      and field_diff ? 'summary'
      and field_diff ? 'suggested_reminders_minutes'
  ) and (
    select count(*) = 1
    from public.email_candidate_updates
    where owner_user_id = 'b5111111-1111-4111-8111-111111111111'
      and resolution_state = 'superseded'
  ) and exists (
    select 1
    from public.email_candidate_updates u
    join public.email_candidates c on c.id = u.candidate_id
    where u.resolution_state = 'pending'
      and u.proposal_fingerprint <> c.semantic_fingerprint
  ),
  'coarse-semantic-equal changes keep a distinct full update identity and diff'
);

set local role service_role;
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'cursor-6',
      'cursor-7',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-update-reverted',
        'provider_thread_id', 'thread-base',
        'received_at', '2031-01-03T02:00:00Z',
        'sanitized_content_hash', repeat('5', 64),
        'evidence_metadata', jsonb_build_array('変更を取り消し'),
        'processing_state', 'processed',
        'error_category', null
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-update-reverted',
        'validated_payload', (select payload from email_secure_payloads where fixture_key = 'base'),
        'error_category', null
      )),
      false,
      now(),
      'b7111111-1111-4111-8111-111111111133'
    )
  $sql$,
  'a newer same-thread message can revert to the confirmed payload'
);
reset role;

select extensions.ok(
  (
    select review_state = 'confirmed'
    from public.email_candidates
    where linked_entity_id = 'b8111111-1111-4111-8111-111111111111'
  ) and not exists (
    select 1
    from public.email_candidate_updates
    where owner_user_id = 'b5111111-1111-4111-8111-111111111111'
      and resolution_state = 'pending'
  ),
  'reversion supersedes stale proposals and restores confirmed review state'
);

set local role service_role;
-- 37
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'cursor-7',
      'cursor-8',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-unrelated',
        'provider_thread_id', 'thread-unrelated',
        'received_at', '2031-01-04T00:00:00Z',
        'sanitized_content_hash', repeat('3', 64),
        'evidence_metadata', jsonb_build_array('期限変更'),
        'processing_state', 'processed',
        'error_category', null
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-unrelated',
        'validated_payload', (select payload from email_secure_payloads where fixture_key = 'changed'),
        'error_category', null
      )),
      false,
      now(),
      'b7111111-1111-4111-8111-111111111119'
    )
  $sql$,
  'an unrelated thread with similar semantics remains independently reviewable'
);
reset role;

-- 38
select extensions.is(
  (
    select count(*)
    from public.email_candidates c
    join public.email_sources s on s.id = c.source_id
    where s.provider_thread_id = 'thread-unrelated'
  ),
  1::bigint,
  'semantic similarity alone never collapses unrelated threads'
);

set local role service_role;
-- 39
select extensions.lives_ok(
  $sql$
    select public.email_import_record_failure(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'fetch',
      'rate_limited',
      'rate_limited',
      now() + interval '1 minute',
      now(),
      'b7111111-1111-4111-8111-111111111120'
    )
  $sql$,
  'trusted failure persistence stores only an allow-listed state and category'
);
reset role;

-- 40
select extensions.ok(
  (
    select connection_state = 'rate_limited'
      and last_error_category = 'rate_limited'
      and retry_after_at is not null
    from public.email_connections
    where id = 'b6111111-1111-4111-8111-111111111111'
  ),
  'rate-limit state remains explicit and bounded metadata only'
);

-- Reconciliation uses private idempotency/tombstone storage with no direct
-- access even for the service-role Table API.
select extensions.ok(
  (
    select bool_and(c.relrowsecurity)
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where (n.nspname, c.relname) in (
      ('private', 'email_import_dismissal_tombstones'),
      ('private', 'email_import_reconciliation_receipts')
    )
  ),
  'reconciliation tombstones and receipts have RLS enabled'
);
select extensions.ok(
  not pg_catalog.has_table_privilege(
    'service_role', 'private.email_import_dismissal_tombstones', 'SELECT'
  ) and not pg_catalog.has_table_privilege(
    'service_role', 'private.email_import_reconciliation_receipts', 'SELECT'
  ),
  'trusted reconciliation tables have no direct Table API read grant'
);

-- A local confirmation can be reflected in email review state only after the
-- schedule mutation receipt and exact canonical PRIVATE row both exist.
insert into public.assignments (
  id,
  owner_user_id,
  title,
  description,
  submission_url,
  due_at,
  visibility_level,
  version
) values (
  'b8111111-1111-4111-8111-111111111122',
  'b5111111-1111-4111-8111-111111111111',
  'レポート提出',
  '期限変更',
  'https://lms.invalid/tasks/1',
  '2031-02-03T01:00:00Z',
  'PRIVATE',
  1
);

set local role service_role;
select extensions.throws_ok(
  $sql$
    select public.email_import_reconcile_confirmation(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'gmail',
      repeat('c', 64),
      (select provider_message_id_hash from public.email_sources where provider_message_id = 'message-unrelated'),
      (select provider_thread_id_hash from public.email_sources where provider_message_id = 'message-unrelated'),
      repeat('3', 64),
      (select payload from email_secure_payloads where fixture_key = 'changed'),
      'assignment',
      'b8111111-1111-4111-8111-111111111122',
      'email-confirmation-reconcile',
      now(),
      'b7111111-1111-4111-8111-111111111140'
    )
  $sql$,
  '55000',
  'Confirmed schedule mutation is unavailable.',
  'confirmation fails closed before its schedule create receipt exists'
);
select extensions.throws_ok(
  $sql$
    select public.email_import_reconcile_confirmation(
      'b5222222-2222-4222-8222-222222222222',
      'b6111111-1111-4111-8111-111111111111',
      'gmail',
      repeat('c', 64),
      (select provider_message_id_hash from public.email_sources where provider_message_id = 'message-unrelated'),
      (select provider_thread_id_hash from public.email_sources where provider_message_id = 'message-unrelated'),
      repeat('3', 64),
      (select payload from email_secure_payloads where fixture_key = 'changed'),
      'assignment',
      'b8111111-1111-4111-8111-111111111122',
      'email-confirmation-cross-owner',
      now(),
      'b7111111-1111-4111-8111-111111111141'
    )
  $sql$,
  '42501',
  'Email connection owner mismatch.',
  'confirmation cannot cross the authenticated owner boundary'
);
reset role;

insert into private.schedule_mutation_receipts (
  owner_user_id,
  idempotency_key,
  request_hash,
  response
) values (
  'b5111111-1111-4111-8111-111111111111',
  'email-confirmation-reconcile',
  repeat('a', 64),
  jsonb_build_object(
    'outcome', 'applied',
    'entity_type', 'assignment',
    'entity_id', 'b8111111-1111-4111-8111-111111111122',
    'operation', 'create',
    'server_version', 1
  )
);

set local role service_role;
select extensions.lives_ok(
  $sql$
    select public.email_import_reconcile_confirmation(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'gmail',
      repeat('c', 64),
      (select provider_message_id_hash from public.email_sources where provider_message_id = 'message-unrelated'),
      (select provider_thread_id_hash from public.email_sources where provider_message_id = 'message-unrelated'),
      repeat('3', 64),
      (select payload from email_secure_payloads where fixture_key = 'changed'),
      'assignment',
      'b8111111-1111-4111-8111-111111111122',
      'email-confirmation-reconcile',
      now(),
      'b7111111-1111-4111-8111-111111111142'
    )
  $sql$,
  'an applied create is reconciled without creating a second schedule row'
);
reset role;

select extensions.ok(
  (
    select c.review_state = 'confirmed'
      and c.linked_entity_type = 'assignment'
      and c.linked_entity_id = 'b8111111-1111-4111-8111-111111111122'
      and c.confirmation_idempotency_key = 'email-confirmation-reconcile'
      and c.validated_payload = (select payload from email_secure_payloads where fixture_key = 'changed')
      and s.processing_state = 'processed'
    from public.email_candidates c
    join public.email_sources s on s.id = c.source_id
    where s.provider_message_id = 'message-unrelated'
  ) and (
    select count(*) = 1
    from public.assignments
    where id = 'b8111111-1111-4111-8111-111111111122'
  ),
  'confirmation links the exact reviewed payload and leaves one canonical entity'
);

set local role service_role;
select extensions.ok(
  (
    public.email_import_reconcile_confirmation(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'gmail',
      repeat('c', 64),
      (select provider_message_id_hash from public.email_sources where provider_message_id = 'message-unrelated'),
      (select provider_thread_id_hash from public.email_sources where provider_message_id = 'message-unrelated'),
      repeat('3', 64),
      (select payload from email_secure_payloads where fixture_key = 'changed'),
      'assignment',
      'b8111111-1111-4111-8111-111111111122',
      'email-confirmation-reconcile',
      now(),
      'b7111111-1111-4111-8111-111111111143'
    ) ->> 'replayed'
  )::boolean,
  'confirmation reconciliation replay is idempotent'
);
select extensions.throws_ok(
  $sql$
    select public.email_import_reconcile_confirmation(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'gmail',
      repeat('c', 64),
      repeat('9', 64),
      repeat('8', 64),
      repeat('7', 64),
      (select payload from email_secure_payloads where fixture_key = 'changed'),
      'assignment',
      'b8111111-1111-4111-8111-111111111122',
      'email-confirmation-reconcile',
      now(),
      'b7111111-1111-4111-8111-111111111144'
    )
  $sql$,
  '23505',
  'Email reconciliation idempotency key was reused.',
  'confirmation idempotency keys reject a mismatched request'
);
reset role;

-- Dismissal resolves the active row by account-scoped hashes and removes all
-- raw source identifiers while retaining a minimal suppression tombstone.
set local role service_role;
select extensions.lives_ok(
  $sql$
    select public.email_import_reconcile_dismissal(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'gmail',
      repeat('c', 64),
      (select provider_message_id_hash from public.email_sources where provider_message_id = 'message-dismiss'),
      (select provider_thread_id_hash from public.email_sources where provider_message_id = 'message-dismiss'),
      repeat('2', 64),
      'email-dismissal-reconcile',
      now(),
      'b7111111-1111-4111-8111-111111111145'
    )
  $sql$,
  'a locally pruned dismissal reconciles using hashes only'
);
reset role;

select extensions.ok(
  not exists (
    select 1 from public.email_sources where provider_message_id = 'message-dismiss'
  ) and exists (
    select 1
    from private.email_import_dismissal_tombstones
    where owner_user_id = 'b5111111-1111-4111-8111-111111111111'
      and dismissal_idempotency_key = 'email-dismissal-reconcile'
      and provider_message_id_hash ~ '^[0-9a-f]{64}$'
      and provider_thread_id_hash ~ '^[0-9a-f]{64}$'
  ),
  'dismissal deletes raw identifiers and retains only bounded hashes'
);

set local role service_role;
select extensions.ok(
  (
    public.email_import_reconcile_dismissal(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'gmail',
      repeat('c', 64),
      'b169fcafc513ff58c644d54ea32fa966e37014a6e8ac189e593a075d79211237',
      '1b4aa53086e38539b221996a977ab3a3b2e8694336c8e4b5d30818594afcca6b',
      repeat('2', 64),
      'email-dismissal-reconcile',
      now(),
      'b7111111-1111-4111-8111-111111111146'
    ) ->> 'replayed'
  )::boolean,
  'dismissal reconciliation replay survives local and server pruning'
);
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'cursor-8',
      'cursor-9',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-dismiss-after-reconcile',
        'provider_thread_id', 'thread-dismiss',
        'received_at', '2031-01-05T00:00:00Z',
        'sanitized_content_hash', repeat('8', 64),
        'evidence_metadata', jsonb_build_array('提出案内'),
        'processing_state', 'processed',
        'error_category', null
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-dismiss-after-reconcile',
        'validated_payload', (select payload from email_secure_payloads where fixture_key = 'base'),
        'error_category', null
      )),
      false,
      now(),
      'b7111111-1111-4111-8111-111111111147'
    )
  $sql$,
  'a private dismissal tombstone suppresses a later same-thread fixture'
);
reset role;

select extensions.is(
  (
    select count(*)
    from public.email_sources
    where provider_message_id = 'message-dismiss-after-reconcile'
  ),
  0::bigint,
  'suppression never restores a raw provider identifier'
);
select extensions.is(
  (
    select items from private.email_import_sync_receipts
    where connection_id = 'b6111111-1111-4111-8111-111111111111'
      and expected_cursor = 'cursor-8'
  ),
  '[]'::jsonb,
  'same-thread semantic-fingerprint suppression also omits the safe page receipt'
);

-- A full proposed payload and its base entity version are durable separately
-- from the coarse semantic fingerprint. Acceptance remains impossible until
-- the exact update mutation is applied server-side.
set local role service_role;
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'cursor-9',
      'cursor-10',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-update-accepted',
        'provider_thread_id', 'thread-base',
        'received_at', '2031-01-06T00:00:00Z',
        'sanitized_content_hash', repeat('6', 64),
        'evidence_metadata', jsonb_build_array('期限変更'),
        'processing_state', 'processed',
        'error_category', null
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-update-accepted',
        'validated_payload', (select payload from email_secure_payloads where fixture_key = 'accepted_changed'),
        'error_category', null
      )),
      false,
      now(),
      'b7111111-1111-4111-8111-111111111148'
    )
  $sql$,
  'a later same-thread deadline creates a fresh explicit update proposal'
);
reset role;

select extensions.ok(
  (
    select u.proposed_payload = (select payload from email_secure_payloads where fixture_key = 'accepted_changed')
      and u.base_entity_version = 1
      and u.field_diff ? 'due_at'
      and u.resolution_state = 'pending'
    from public.email_candidate_updates u
    join public.email_sources s on s.id = u.source_id
    where s.provider_message_id = 'message-update-accepted'
  ) and (
    select due_at = '2031-02-01T01:00:00Z'::timestamptz and version = 1
    from public.assignments
    where id = 'b8111111-1111-4111-8111-111111111111'
  ),
  'the full proposal is retained while the canonical assignment stays unchanged'
);

set local role service_role;
select extensions.throws_ok(
  $sql$
    select public.email_import_reconcile_update(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'gmail',
      repeat('c', 64),
      (select provider_message_id_hash from public.email_sources where provider_message_id = 'message-update-accepted'),
      (select provider_thread_id_hash from public.email_sources where provider_message_id = 'message-update-accepted'),
      repeat('6', 64),
      'accepted',
      'assignment',
      'b8111111-1111-4111-8111-111111111111',
      'email-update-accept-reconcile',
      now(),
      'b7111111-1111-4111-8111-111111111149'
    )
  $sql$,
  '55000',
  'Accepted schedule mutation is unavailable.',
  'acceptance cannot update server review state before schedule sync succeeds'
);
reset role;

update public.assignments
set title = 'レポート提出',
    description = '再変更',
    submission_url = 'https://lms.invalid/tasks/1',
    due_at = '2031-02-05T01:00:00Z',
    version = 2,
    updated_at = now()
where id = 'b8111111-1111-4111-8111-111111111111'
  and owner_user_id = 'b5111111-1111-4111-8111-111111111111';

insert into private.schedule_mutation_receipts (
  owner_user_id,
  idempotency_key,
  request_hash,
  response
) values (
  'b5111111-1111-4111-8111-111111111111',
  'email-update-accept-reconcile',
  repeat('b', 64),
  jsonb_build_object(
    'outcome', 'applied',
    'entity_type', 'assignment',
    'entity_id', 'b8111111-1111-4111-8111-111111111111',
    'operation', 'update',
    'server_version', 2
  )
);

set local role service_role;
select extensions.lives_ok(
  $sql$
    select public.email_import_reconcile_update(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'gmail',
      repeat('c', 64),
      (select provider_message_id_hash from public.email_sources where provider_message_id = 'message-update-accepted'),
      (select provider_thread_id_hash from public.email_sources where provider_message_id = 'message-update-accepted'),
      repeat('6', 64),
      'accepted',
      'assignment',
      'b8111111-1111-4111-8111-111111111111',
      'email-update-accept-reconcile',
      now(),
      'b7111111-1111-4111-8111-111111111150'
    )
  $sql$,
  'the applied canonical update is reconciled only after explicit acceptance'
);
reset role;

select extensions.ok(
  (
    select c.review_state = 'confirmed'
      and c.validated_payload = (select payload from email_secure_payloads where fixture_key = 'accepted_changed')
    from public.email_candidates c
    where c.linked_entity_id = 'b8111111-1111-4111-8111-111111111111'
  ) and (
    select u.resolution_state = 'accepted'
      and u.resolution_idempotency_key = 'email-update-accept-reconcile'
      and s.processing_state = 'processed'
    from public.email_candidate_updates u
    join public.email_sources s on s.id = u.source_id
    where s.provider_message_id = 'message-update-accepted'
  ),
  'accepted resolution advances candidate state and preserves explicit source processing state'
);

set local role service_role;
select extensions.ok(
  (
    public.email_import_reconcile_update(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'gmail',
      repeat('c', 64),
      (select provider_message_id_hash from public.email_sources where provider_message_id = 'message-update-accepted'),
      (select provider_thread_id_hash from public.email_sources where provider_message_id = 'message-update-accepted'),
      repeat('6', 64),
      'accepted',
      'assignment',
      'b8111111-1111-4111-8111-111111111111',
      'email-update-accept-reconcile',
      now(),
      'b7111111-1111-4111-8111-111111111151'
    ) ->> 'replayed'
  )::boolean,
  'accepted update reconciliation is idempotent'
);
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'cursor-10',
      'cursor-11',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-update-rejected',
        'provider_thread_id', 'thread-base',
        'received_at', '2031-01-07T00:00:00Z',
        'sanitized_content_hash', repeat('7', 64),
        'evidence_metadata', jsonb_build_array('通知変更'),
        'processing_state', 'processed',
        'error_category', null
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-update-rejected',
        'validated_payload', (select payload from email_secure_payloads where fixture_key = 'rejected_changed'),
        'error_category', null
      )),
      false,
      now(),
      'b7111111-1111-4111-8111-111111111152'
    )
  $sql$,
  'another changed source remains a separate pending proposal'
);
select extensions.lives_ok(
  $sql$
    select public.email_import_reconcile_update(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'gmail',
      repeat('c', 64),
      (select provider_message_id_hash from public.email_sources where provider_message_id = 'message-update-rejected'),
      (select provider_thread_id_hash from public.email_sources where provider_message_id = 'message-update-rejected'),
      repeat('7', 64),
      'rejected',
      'assignment',
      'b8111111-1111-4111-8111-111111111111',
      'email-update-reject-reconcile',
      now(),
      'b7111111-1111-4111-8111-111111111153'
    )
  $sql$,
  'rejection resolves the proposal without a schedule mutation'
);
reset role;

select extensions.ok(
  (
    select u.resolution_state = 'rejected'
      and u.resolution_idempotency_key = 'email-update-reject-reconcile'
      and s.processing_state = 'ignored'
      and s.evidence_metadata = '[]'::jsonb
    from public.email_candidate_updates u
    join public.email_sources s on s.id = u.source_id
    where s.provider_message_id = 'message-update-rejected'
  ) and (
    select c.review_state = 'confirmed'
      and c.validated_payload = (select payload from email_secure_payloads where fixture_key = 'accepted_changed')
    from public.email_candidates c
    where c.linked_entity_id = 'b8111111-1111-4111-8111-111111111111'
  ) and (
    select due_at = '2031-02-05T01:00:00Z'::timestamptz and version = 2
    from public.assignments
    where id = 'b8111111-1111-4111-8111-111111111111'
  ),
  'rejection prunes proposal evidence and never alters the canonical schedule or candidate payload'
);

set local role service_role;
select extensions.ok(
  (
    public.email_import_reconcile_update(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      'gmail',
      repeat('c', 64),
      (select provider_message_id_hash from public.email_sources where provider_message_id = 'message-update-rejected'),
      (select provider_thread_id_hash from public.email_sources where provider_message_id = 'message-update-rejected'),
      repeat('7', 64),
      'rejected',
      'assignment',
      'b8111111-1111-4111-8111-111111111111',
      'email-update-reject-reconcile',
      now(),
      'b7111111-1111-4111-8111-111111111154'
    ) ->> 'replayed'
  )::boolean,
  'rejected update reconciliation is idempotent'
);
reset role;

select extensions.ok(
  (
    select count(*) = 4
    from public.email_import_audit_events
    where operation in ('confirm', 'dismiss', 'resolve_update')
      and outcome = 'succeeded'
      and connection_state is null
      and error_category is null
  ),
  'reconciliation audit rows contain only safe action outcomes and correlation state'
);

set local role service_role;
-- 41
select extensions.throws_ok(
  $sql$
    select public.email_import_finalize_disconnect(
      'b5222222-2222-4222-8222-222222222222',
      'b6111111-1111-4111-8111-111111111111',
      false,
      true,
      true,
      now(),
      'b7111111-1111-4111-8111-111111111121'
    )
  $sql$,
  '42501',
  'Email connection owner mismatch.',
  'disconnect cannot cross an owner boundary'
);
-- 42
select extensions.lives_ok(
  $sql$
    select public.email_import_finalize_disconnect(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      false,
      true,
      false,
      now(),
      'b7111111-1111-4111-8111-111111111122'
    )
  $sql$,
  'disconnect destroys local token material even when provider revocation fails'
);
reset role;

-- 43
select extensions.ok(
  (select count(*) = 0 from private.email_connection_credentials where owner_user_id = 'b5111111-1111-4111-8111-111111111111')
  and (
    select connection_state = 'disconnected' and sync_cursor is null
    from public.email_connections
    where id = 'b6111111-1111-4111-8111-111111111111'
  ),
  'disconnect always removes sealed credentials and disables future sync'
);
-- 44
select extensions.ok(
  (select count(*) > 0 from public.email_sources where owner_user_id = 'b5111111-1111-4111-8111-111111111111')
  and (select count(*) = 1 from public.assignments where id = 'b8111111-1111-4111-8111-111111111111'),
  'disconnect without derived deletion retains cached review data and canonical schedules'
);

set local role service_role;
-- 45
select extensions.lives_ok(
  $sql$
    select public.email_import_finalize_disconnect(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111111',
      true,
      false,
      false,
      now(),
      'b7111111-1111-4111-8111-111111111123'
    )
  $sql$,
  'a separate confirmed choice removes provider-derived data'
);
reset role;

-- 46
select extensions.ok(
  (select count(*) = 0 from public.email_sources where owner_user_id = 'b5111111-1111-4111-8111-111111111111')
  and (select count(*) = 0 from public.email_candidates where owner_user_id = 'b5111111-1111-4111-8111-111111111111')
  and (select count(*) = 0 from public.email_candidate_updates where owner_user_id = 'b5111111-1111-4111-8111-111111111111')
  and (select count(*) = 1 from public.assignments where id = 'b8111111-1111-4111-8111-111111111111'),
  'derived deletion cascades only through email data and retains the user-owned assignment'
);

set local role service_role;
-- 47
select extensions.lives_ok(
  $sql$
    select public.email_import_begin_oauth(
      'b5111111-1111-4111-8111-111111111111',
      'b6111111-1111-4111-8111-111111111112',
      repeat('d', 64),
      decode(repeat('23', 32), 'hex'),
      1,
      now() + interval '5 minutes',
      'b7111111-1111-4111-8111-111111111124'
    )
  $sql$,
  'a new OAuth attempt can exist before separate account-data deletion'
);
-- 48
select extensions.lives_ok(
  $sql$
    select public.email_import_delete_account_data(
      'b5111111-1111-4111-8111-111111111111',
      now(),
      'b7111111-1111-4111-8111-111111111125'
    )
  $sql$,
  'separate account-data deletion removes every Gmail connection boundary'
);
reset role;

-- 49
select extensions.ok(
  (select count(*) = 0 from public.email_connections where owner_user_id = 'b5111111-1111-4111-8111-111111111111')
  and (select count(*) = 0 from private.email_oauth_sessions where owner_user_id = 'b5111111-1111-4111-8111-111111111111')
  and (select count(*) = 0 from private.email_connection_credentials where owner_user_id = 'b5111111-1111-4111-8111-111111111111'),
  'account-data deletion destroys connections, OAuth sessions, and credentials'
);
-- 50
select extensions.is(
  (select count(*) from public.assignments where id = 'b8111111-1111-4111-8111-111111111111'),
  1::bigint,
  'separate email account deletion does not delete a confirmed schedule entity'
);
-- 51
select extensions.is_empty(
  $sql$
    select operation, outcome, connection_state, error_category
    from public.email_import_audit_events
    where operation not in (
      'connect',
      'oauth_callback',
      'refresh',
      'fetch',
      'confirm',
      'dismiss',
      'resolve_update',
      'disconnect',
      'delete_account_data'
    )
      or outcome not in ('started', 'succeeded', 'failed', 'already_revoked')
  $sql$,
  'audit records contain only allow-listed correlation and transition states'
);

set local request.jwt.claims = '{"sub":"b5111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = 'b5111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

-- 52
select extensions.ok(
  (select count(*) > 0 from public.email_import_audit_events)
  and (select count(*) = 0 from public.email_import_audit_events where owner_user_id <> 'b5111111-1111-4111-8111-111111111111'),
  'the owner can read only their safe lifecycle audit events'
);
-- 53
select extensions.throws_ok(
  $sql$
    select public.email_import_begin_oauth(
      'b5111111-1111-4111-8111-111111111111',
      gen_random_uuid(),
      repeat('e', 64),
      decode(repeat('34', 32), 'hex'),
      1,
      now() + interval '5 minutes',
      gen_random_uuid()
    )
  $sql$,
  '42501',
  null,
  'an authenticated client cannot execute the OAuth begin RPC'
);
-- 54
select extensions.throws_ok(
  $sql$ select count(*) from private.email_oauth_sessions $sql$,
  '42501',
  'permission denied for table email_oauth_sessions',
  'an authenticated client cannot inspect OAuth state'
);

reset role;
set local request.jwt.claims = '{"sub":"b5222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = 'b5222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

-- 55
select extensions.is(
  (select count(*) from public.email_import_audit_events),
  0::bigint,
  'another authenticated user sees no foreign email audit events'
);

reset role;
select * from extensions.finish();
rollback;
