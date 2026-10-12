begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(85);

select extensions.has_table(
  'private', 'email_import_sync_receipts',
  'incremental lost-response receipts stay in the private schema'
);
select extensions.has_table(
  'private', 'email_import_retry_receipts',
  'targeted retry idempotency receipts stay in the private schema'
);
select extensions.ok(
  (
    select bool_and(c.relrowsecurity)
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where (n.nspname, c.relname) in (
      ('private', 'email_import_sync_receipts'),
      ('private', 'email_import_retry_receipts'),
      ('private', 'email_import_source_replacement_guards')
    )
  ),
  'both private receipt tables have RLS enabled'
);
select extensions.ok(
  not exists (
    select 1
    from (values ('anon'), ('authenticated'), ('service_role')) api_role(role_name)
    cross join (values
      ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'),
      ('REFERENCES'), ('TRIGGER')
    ) privilege(privilege_name)
    cross join (values
      ('private.email_import_sync_receipts'),
      ('private.email_import_retry_receipts'),
      ('private.email_import_source_replacement_guards')
    ) receipt_table(table_name)
    where pg_catalog.has_table_privilege(
      api_role.role_name, receipt_table.table_name, privilege.privilege_name
    )
  ),
  'receipt tables deny every direct table privilege to every API role'
);
select extensions.is(
  (
    select count(*)
    from pg_catalog.pg_policies
    where schemaname = 'private'
      and tablename in (
        'email_import_sync_receipts', 'email_import_retry_receipts',
        'email_import_source_replacement_guards'
      )
  ),
  0::bigint,
  'private receipt tables expose no RLS policies'
);
select extensions.is(
  (
    select array_agg(attribute.attname order by key_position.ordinality)
    from pg_catalog.pg_constraint constraint_row
    cross join lateral unnest(constraint_row.conkey)
      with ordinality key_position(attnum, ordinality)
    join pg_catalog.pg_attribute attribute
      on attribute.attrelid = constraint_row.conrelid
      and attribute.attnum = key_position.attnum
    where constraint_row.conrelid =
      'private.email_import_sync_receipts'::pg_catalog.regclass
      and constraint_row.contype = 'p'
  ),
  array['connection_id', 'expected_cursor_key']::name[],
  'sync receipts use a null-safe per-connection cursor key'
);
select extensions.is(
  (
    select count(*)
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'email_import_get_sync_replay',
        'email_import_get_owner_timezone',
        'email_import_get_retry_replay',
        'email_import_assert_retry_candidate',
        'email_import_persist_retry_candidate'
      )
      and pg_catalog.has_function_privilege('service_role', p.oid, 'EXECUTE')
      and not pg_catalog.has_function_privilege('authenticated', p.oid, 'EXECUTE')
      and not pg_catalog.has_function_privilege('anon', p.oid, 'EXECUTE')
  ),
  5::bigint,
  'only service_role can invoke all five failure/replay RPCs'
);
select extensions.ok(
  not pg_catalog.has_function_privilege(
    'anon',
    'private.email_import_persist_sync_page_v2(uuid,uuid,text,text,jsonb,jsonb,boolean,timestamptz,uuid,boolean)',
    'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated',
    'private.email_import_persist_sync_page_v2(uuid,uuid,text,text,jsonb,jsonb,boolean,timestamptz,uuid,boolean)',
    'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'service_role',
    'private.email_import_persist_sync_page_v2(uuid,uuid,text,text,jsonb,jsonb,boolean,timestamptz,uuid,boolean)',
    'EXECUTE'
  ),
  'no API role can bypass the public wrapper through the private v2 core'
);

insert into auth.users (id)
values ('d5111111-1111-4111-8111-111111111111');

insert into public.universities (
  id, name, normalized_name, timezone, status
) values (
  'd4111111-1111-4111-8111-111111111111',
  'Replay University', 'replayuniversity', 'Asia/Tokyo', 'active'
);

insert into public.profiles (user_id, display_name, university_id)
values (
  'd5111111-1111-4111-8111-111111111111',
  'Replay User',
  'd4111111-1111-4111-8111-111111111111'
)
on conflict (user_id) do update
set university_id = excluded.university_id;

insert into public.email_connections (
  id, owner_user_id, provider, provider_account_hash, authorized_scopes,
  connection_state, connected_at
) values (
  'd6111111-1111-4111-8111-111111111111',
  'd5111111-1111-4111-8111-111111111111',
  'gmail', repeat('9', 64),
  array['https://www.googleapis.com/auth/gmail.readonly'],
  'connected', now()
);

insert into public.email_connections (
  id, owner_user_id, provider, provider_account_hash, authorized_scopes,
  connection_state, connected_at
) values (
  'd6222222-2222-4222-8222-222222222222',
  'd5111111-1111-4111-8111-111111111111',
  'gmail', repeat('8', 64),
  array['https://www.googleapis.com/auth/gmail.readonly'],
  'connected', now()
);

set local role service_role;
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      null,
      'cursor-failure-1',
      jsonb_build_array(
        jsonb_build_object(
          'provider_message_id', 'message-retry',
          'provider_thread_id', 'thread-retry',
          'received_at', '2031-02-01T00:00:00Z',
          'sanitized_content_hash', repeat('a', 64),
          'evidence_metadata', '[]'::jsonb,
          'processing_state', 'failed',
          'error_category', 'timeout'
        ),
        jsonb_build_object(
          'provider_message_id', 'message-unsafe',
          'provider_thread_id', 'thread-unsafe',
          'received_at', '2031-02-01T00:01:00Z',
          'sanitized_content_hash', repeat('b', 64),
          'evidence_metadata', '[]'::jsonb,
          'processing_state', 'failed',
          'error_category', 'unsafe_content'
        )
      ),
      jsonb_build_array(
        jsonb_build_object(
          'provider_message_id', 'message-retry',
          'validated_payload', null,
          'error_category', 'timeout'
        ),
        jsonb_build_object(
          'provider_message_id', 'message-unsafe',
          'validated_payload', null,
          'error_category', 'unsafe_content'
        )
      ),
      false,
      now(),
      'd7111111-1111-4111-8111-111111111111'
    )
  $sql$,
  'one page atomically persists sanitized failed sources and advances its cursor'
);
reset role;

select extensions.ok(
  (
    select count(*) = 2
      and bool_and(processing_state = 'failed')
      and bool_and(error_category is not null)
      and bool_and(evidence_metadata = '[]'::jsonb)
    from public.email_sources
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
  ),
  'failed sources retain only safe identifiers, hashes, timestamps, and categories'
);
select extensions.ok(
  (
    select count(*) = 2
      and bool_and(review_state = 'failed')
      and bool_and(validated_payload is null)
      and bool_and(error_category is not null)
      and bool_and(semantic_fingerprint ~ '^[0-9a-f]{64}$')
    from public.email_candidates
    where owner_user_id = 'd5111111-1111-4111-8111-111111111111'
  ),
  'each failed source has one payload-free failed candidate'
);
select extensions.is(
  (
    select sync_cursor from public.email_connections
    where id = 'd6111111-1111-4111-8111-111111111111'
  ),
  'cursor-failure-1',
  'failed messages do not wedge cursor advancement'
);

create temporary table email_import_invalid_fixture (
  source jsonb not null,
  candidate jsonb not null
) on commit drop;
insert into email_import_invalid_fixture values (
  jsonb_build_object(
    'provider_message_id', 'message-invalid',
    'provider_thread_id', 'thread-invalid',
    'received_at', '2031-02-01T00:02:00Z',
    'sanitized_content_hash', repeat('7', 64),
    'evidence_metadata', '[]'::jsonb,
    'processing_state', 'failed',
    'error_category', 'timeout'
  ),
  jsonb_build_object(
    'provider_message_id', 'message-invalid',
    'validated_payload', null,
    'error_category', 'timeout'
  )
);

create temporary table email_import_valid_payload (
  payload jsonb not null
) on commit drop;
insert into email_import_valid_payload values ('{
  "schema_version":"1.0",
  "candidate_type":"assignment",
  "title":"Validation fixture",
  "course_hint":{"name":null,"code":null},
  "due":{"at":"2031-02-05T12:00:00Z","all_day":false,"timezone":"America/New_York","raw_text":"February 5"},
  "start_at":null,"end_at":null,"location":null,
  "submission_url":null,"summary":null,
  "suggested_reminders_minutes":[],
  "confidence":{"overall":0.9,"title":0.9,"course":0.5,"date_time":0.9},
  "evidence":[],"warnings":[],
  "requires_user_confirmation":true
}'::jsonb);
grant select on email_import_invalid_fixture, email_import_valid_payload
to service_role;

set local role service_role;
select extensions.throws_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-1', 'cursor-invalid',
      jsonb_build_array(jsonb_set(
        (select source from email_import_invalid_fixture),
        '{processing_state}', 'null'::jsonb
      )),
      jsonb_build_array((select candidate from email_import_invalid_fixture)),
      false, now(), 'd7111111-1111-4111-8111-111111111121'
    )
  $sql$,
  '22023', 'Invalid email source metadata.',
  'JSON null processing_state is rejected before cursor advancement'
);
select extensions.throws_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-1', 'cursor-invalid',
      jsonb_build_array(jsonb_set(
        (select source from email_import_invalid_fixture),
        '{processing_state}', '7'::jsonb
      )),
      jsonb_build_array((select candidate from email_import_invalid_fixture)),
      false, now(), 'd7111111-1111-4111-8111-111111111122'
    )
  $sql$,
  '22023', 'Invalid email source metadata.',
  'non-string processing_state is rejected before cursor advancement'
);
select extensions.throws_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-1', 'cursor-invalid',
      jsonb_build_array(jsonb_set(
        (select source from email_import_invalid_fixture),
        '{error_category}', 'null'::jsonb
      )),
      jsonb_build_array(jsonb_set(
        (select candidate from email_import_invalid_fixture),
        '{error_category}', 'null'::jsonb
      )),
      false, now(), 'd7111111-1111-4111-8111-111111111123'
    )
  $sql$,
  '22023', 'Invalid email source metadata.',
  'JSON null error_category is rejected for a failed source'
);
select extensions.throws_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-1', 'cursor-invalid',
      jsonb_build_array(jsonb_set(
        (select source from email_import_invalid_fixture),
        '{error_category}', '7'::jsonb
      )),
      jsonb_build_array(jsonb_set(
        (select candidate from email_import_invalid_fixture),
        '{error_category}', '7'::jsonb
      )),
      false, now(), 'd7111111-1111-4111-8111-111111111124'
    )
  $sql$,
  '22023', 'Invalid email source metadata.',
  'non-string error_category is rejected for a failed source'
);
select extensions.throws_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-1', 'cursor-invalid',
      jsonb_build_array(jsonb_set(
        (select source from email_import_invalid_fixture),
        '{received_at}', '"2031-02-01 00:02:00+00"'::jsonb
      )),
      jsonb_build_array((select candidate from email_import_invalid_fixture)),
      false, now(), 'd7111111-1111-4111-8111-111111111130'
    )
  $sql$,
  '22023', 'Invalid email source metadata.',
  'PostgreSQL-castable but non-RFC3339 received_at is rejected'
);
select extensions.throws_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-1', 'cursor-invalid',
      jsonb_build_array(jsonb_set(
        jsonb_set(
          jsonb_set(
            (select source from email_import_invalid_fixture),
            '{processing_state}', '"processed"'::jsonb
          ),
          '{error_category}', 'null'::jsonb
        ),
        '{evidence_metadata}', jsonb_build_array(' padded evidence ')
      )),
      jsonb_build_array(jsonb_set(
        jsonb_set(
          (select candidate from email_import_invalid_fixture),
          '{validated_payload}', (select payload from email_import_valid_payload)
        ),
        '{error_category}', 'null'::jsonb
      )),
      false, now(), 'd7111111-1111-4111-8111-111111111131'
    )
  $sql$,
  '22023', 'Invalid email source metadata.',
  'non-canonical evidence with surrounding whitespace is rejected'
);
select extensions.throws_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-1', 'cursor-invalid',
      jsonb_build_array(jsonb_set(
        jsonb_set(
          jsonb_set(
            (select source from email_import_invalid_fixture),
            '{processing_state}', '"processed"'::jsonb
          ),
          '{error_category}', 'null'::jsonb
        ),
        '{evidence_metadata}', jsonb_build_array('unsafe' || chr(1) || 'control')
      )),
      jsonb_build_array(jsonb_set(
        jsonb_set(
          (select candidate from email_import_invalid_fixture),
          '{validated_payload}', (select payload from email_import_valid_payload)
        ),
        '{error_category}', 'null'::jsonb
      )),
      false, now(), 'd7111111-1111-4111-8111-111111111132'
    )
  $sql$,
  '22023', 'Invalid email source metadata.',
  'evidence containing forbidden control characters is rejected'
);
select extensions.throws_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-1', 'cursor-invalid',
      jsonb_build_array(
        (select source from email_import_invalid_fixture),
        jsonb_set(
          jsonb_set(
            jsonb_set(
              (select source from email_import_invalid_fixture),
              '{provider_message_id}', '"message-invalid-2"'::jsonb
            ),
            '{provider_thread_id}', '"thread-invalid-2"'::jsonb
          ),
          '{sanitized_content_hash}', to_jsonb(repeat('6', 64))
        )
      ),
      jsonb_build_array(
        (select candidate from email_import_invalid_fixture),
        jsonb_set(
          (select candidate from email_import_invalid_fixture),
          '{provider_message_id}', '"orphan-candidate"'::jsonb
        )
      ),
      false, now(), 'd7111111-1111-4111-8111-111111111125'
    )
  $sql$,
  '22023', 'Invalid email candidate metadata.',
  'equal array lengths cannot hide a missing candidate and orphan candidate'
);
select extensions.throws_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-1', 'cursor-invalid',
      jsonb_build_array(
        (select source from email_import_invalid_fixture),
        jsonb_set(
          jsonb_set(
            jsonb_set(
              (select source from email_import_invalid_fixture),
              '{provider_message_id}', '"message-invalid-2"'::jsonb
            ),
            '{provider_thread_id}', '"thread-invalid-2"'::jsonb
          ),
          '{sanitized_content_hash}', to_jsonb(repeat('6', 64))
        )
      ),
      jsonb_build_array(
        (select candidate from email_import_invalid_fixture),
        (select candidate from email_import_invalid_fixture)
      ),
      false, now(), 'd7111111-1111-4111-8111-111111111126'
    )
  $sql$,
  '22023', 'Invalid email sync page.',
  'duplicate candidate identities violate the strict one-to-one page contract'
);
select extensions.throws_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-1', 'cursor-invalid',
      jsonb_build_array((select source from email_import_invalid_fixture)),
      jsonb_build_array(jsonb_set(
        (select candidate from email_import_invalid_fixture),
        '{validated_payload}', '{}'::jsonb
      )),
      false, now(), 'd7111111-1111-4111-8111-111111111127'
    )
  $sql$,
  '22023', 'Invalid email candidate metadata.',
  'failed source requires candidate null in the response XOR contract'
);
select extensions.throws_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-1', 'cursor-invalid',
      jsonb_build_array(jsonb_set(
        jsonb_set(
          (select source from email_import_invalid_fixture),
          '{processing_state}', '"processed"'::jsonb
        ),
        '{error_category}', 'null'::jsonb
      )),
      jsonb_build_array(jsonb_set(
        (select candidate from email_import_invalid_fixture),
        '{error_category}', 'null'::jsonb
      )),
      false, now(), 'd7111111-1111-4111-8111-111111111128'
    )
  $sql$,
  '22023', 'Invalid email candidate metadata.',
  'processed source requires a nonnull candidate in the response XOR contract'
);
select extensions.throws_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-1', null,
      jsonb_build_array((select source from email_import_invalid_fixture)),
      jsonb_build_array((select candidate from email_import_invalid_fixture)),
      false, now(), 'd7111111-1111-4111-8111-111111111133'
    )
  $sql$,
  '22023', 'Invalid email sync page.',
  'a nonempty page cannot reset a nonnull cursor to null'
);
select extensions.throws_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-1', 'cursor-failure-1',
      '[]'::jsonb, '[]'::jsonb, false, now(),
      'd7111111-1111-4111-8111-111111111134'
    )
  $sql$,
  '22023', 'Invalid email sync page.',
  'an empty page must advance the opaque cursor so its response key is replayable'
);
reset role;

select extensions.is(
  (
    select sync_cursor from public.email_connections
    where id = 'd6111111-1111-4111-8111-111111111111'
  ),
  'cursor-failure-1',
  'all malformed and non-bijective pages leave the cursor unchanged'
);

set local role service_role;
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-1', 'cursor-failure-2',
      '[]'::jsonb, '[]'::jsonb, false, now(),
      'd7111111-1111-4111-8111-111111111129'
    )
  $sql$,
  'a later empty page advances without overwriting the prior cursor receipt'
);
reset role;

select extensions.ok(
  (
    select count(*) = 2
      and count(*) filter (where expected_cursor is null) = 1
      and count(*) filter (where expected_cursor = 'cursor-failure-1') = 1
    from private.email_import_sync_receipts
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
  ),
  'null-sentinel and nonnull cursor receipts coexist for one connection'
);

create temporary table email_import_sync_receipt_snapshot on commit drop as
select jsonb_agg(to_jsonb(receipt) order by expected_cursor_key) as receipts
from private.email_import_sync_receipts receipt
where connection_id = 'd6111111-1111-4111-8111-111111111111';

set local role service_role;
select extensions.is(
  jsonb_array_length(public.email_import_get_sync_replay(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111',
    null
  ) -> 'items'),
  2,
  'retrying the pre-commit null cursor replays the exact committed safe page'
);
select extensions.is(
  jsonb_array_length(public.email_import_get_sync_replay(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111',
    'cursor-failure-1'
  ) -> 'items'),
  0,
  'the next retained cursor receipt independently replays its empty page'
);
select extensions.is(
  public.email_import_get_sync_replay(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111',
    'wrong-cursor'
  ),
  null::jsonb,
  'an unrelated stale cursor cannot read a receipt'
);
select extensions.is(
  public.email_import_get_owner_timezone(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111'
  ),
  'Asia/Tokyo',
  'trusted timezone lookup returns the owner university IANA timezone'
);
reset role;

update public.universities
set timezone = 'Mars/Olympus_Mons'
where id = 'd4111111-1111-4111-8111-111111111111';
set local role service_role;
select extensions.is(
  public.email_import_get_owner_timezone(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111'
  ),
  'Mars/Olympus_Mons',
  'an invalid configured timezone is returned for Edge validation, never silently replaced'
);
reset role;
update public.universities
set timezone = 'Asia/Tokyo'
where id = 'd4111111-1111-4111-8111-111111111111';

update public.universities
set deleted_at = now()
where id = 'd4111111-1111-4111-8111-111111111111';
set local role service_role;
select extensions.throws_ok(
  $sql$
    select public.email_import_get_owner_timezone(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111'
    )
  $sql$,
  '55000', 'Configured university timezone is unavailable.',
  'a soft-deleted configured university fails closed instead of falling back'
);
reset role;
update public.universities
set deleted_at = null
where id = 'd4111111-1111-4111-8111-111111111111';

update public.profiles
set university_id = null
where user_id = 'd5111111-1111-4111-8111-111111111111';
set local role service_role;
select extensions.is(
  public.email_import_get_owner_timezone(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111'
  ),
  null::text,
  'timezone fallback is allowed only when the owner has no configured university'
);
reset role;
update public.profiles
set university_id = 'd4111111-1111-4111-8111-111111111111'
where user_id = 'd5111111-1111-4111-8111-111111111111';

select extensions.throws_matching(
  $sql$
    update public.email_candidates
    set validated_payload = '{}'::jsonb
    where source_id = (
      select id from public.email_sources
      where provider_message_id = 'message-unsafe'
    )
  $sql$,
  '.*email_candidates_payload_bounded.*',
  'failed candidates cannot retain even an empty payload object'
);
select extensions.throws_matching(
  $sql$
    update public.email_candidates
    set review_state = 'needs_review'
    where source_id = (
      select id from public.email_sources
      where provider_message_id = 'message-unsafe'
    )
  $sql$,
  '.*email_candidates_.*consistent.*|.*email_candidates_payload_bounded.*',
  'every nonfailed candidate requires a payload and no failure category'
);
select extensions.throws_matching(
  $sql$
    update public.email_sources
    set processing_state = 'processed'
    where provider_message_id = 'message-unsafe'
  $sql$,
  '.*email_sources_failure_error_consistent.*',
  'source failure state and error category cannot diverge'
);

set local role service_role;
select extensions.throws_ok(
  $sql$
    select public.email_import_assert_retry_candidate(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'message-unsafe', repeat('b', 64)
    )
  $sql$,
  '42501',
  'Email retry source mismatch.',
  'unsafe-content failures cannot be used as a Gmail refetch proxy'
);
select extensions.lives_ok(
  $sql$
    select public.email_import_assert_retry_candidate(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'message-retry', repeat('a', 64)
    )
  $sql$,
  'a matching transient failed source is target-retryable'
);
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_retry_candidate(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-retry',
        'provider_thread_id', 'thread-retry',
        'received_at', '2031-02-01T00:00:00Z',
        'sanitized_content_hash', repeat('c', 64),
        'evidence_metadata', '[]'::jsonb,
        'processing_state', 'failed',
        'error_category', 'timeout'
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-retry',
        'validated_payload', null,
        'error_category', 'timeout'
      )),
      repeat('a', 64), repeat('d', 64), now(),
      'd7111111-1111-4111-8111-111111111112'
    )
  $sql$,
  'a changed failed result is persisted without advancing the page cursor'
);
reset role;

select extensions.ok(
  (
    select sanitized_content_hash = repeat('c', 64)
      and processing_state = 'failed'
      and error_category = 'timeout'
    from public.email_sources
    where provider_message_id = 'message-retry'
  ),
  'targeted retry replaces failed metadata in place'
);
select extensions.is(
  (
    select jsonb_agg(to_jsonb(receipt) order by expected_cursor_key)
    from private.email_import_sync_receipts receipt
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
  ),
  (select receipts from email_import_sync_receipt_snapshot),
  'targeted retry preserves every incremental receipt byte-for-byte'
);
set local role service_role;
select extensions.is(
  public.email_import_get_retry_replay(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111',
    'message-retry', repeat('a', 64), repeat('d', 64)
  ) #>> '{item,errorCategory}',
  'timeout',
  'a lost targeted-retry response replays the exact safe failed item'
);
select extensions.throws_ok(
  $sql$
    select public.email_import_get_retry_replay(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'different-message', repeat('a', 64), repeat('d', 64)
    )
  $sql$,
  '23505',
  'Email retry idempotency key was reused.',
  'a retry idempotency key cannot be reused for another request'
);

reset role;
update public.email_connections
set connection_state = 'rate_limited',
    last_error_category = 'rate_limited'
where id = 'd6111111-1111-4111-8111-111111111111';
set local role service_role;
select extensions.ok(
  public.email_import_get_sync_replay(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111', null
  ) is not null
  and public.email_import_get_retry_replay(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111',
    'message-retry', repeat('a', 64), repeat('d', 64)
  ) ->> 'retry_outcome' = 'persisted',
  'exact committed receipts remain replayable across a later transient state'
);
reset role;
update public.email_connections
set connection_state = 'connected',
    last_error_category = null
where id = 'd6111111-1111-4111-8111-111111111111';
set local role service_role;

select extensions.lives_ok(
  $sql$
    select public.email_import_persist_retry_candidate(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-retry',
        'provider_thread_id', 'thread-retry',
        'received_at', '2031-02-01T00:00:00Z',
        'sanitized_content_hash', repeat('f', 64),
        'evidence_metadata', jsonb_build_array('期限 2月5日'),
        'processing_state', 'processed',
        'error_category', null
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-retry',
        'validated_payload', '{
          "schema_version":"1.0",
          "candidate_type":"assignment",
          "title":"再試行課題",
          "course_hint":{"name":null,"code":null},
          "due":{"at":"2031-02-05T12:00:00Z","all_day":false,"timezone":"America/New_York","raw_text":"2月5日"},
          "start_at":null,"end_at":null,"location":null,
          "submission_url":null,"summary":null,
          "suggested_reminders_minutes":[],
          "confidence":{"overall":0.9,"title":0.9,"course":0.5,"date_time":0.9},
          "evidence":[],"warnings":[],
          "requires_user_confirmation":true
        }'::jsonb,
        'error_category', null
      )),
      repeat('c', 64), repeat('e', 64), now(),
      'd7111111-1111-4111-8111-111111111113'
    )
  $sql$,
  'a successful targeted retry replaces the failed source/candidate'
);
reset role;

select extensions.ok(
  (
    select s.processing_state = 'processed'
      and s.error_category is null
      and c.review_state in ('ready_for_review', 'needs_review')
      and c.validated_payload is not null
      and c.error_category is null
    from public.email_sources s
    join public.email_candidates c on c.source_id = s.id
    where s.provider_message_id = 'message-retry'
  ) and not exists (
    select 1 from private.email_import_source_replacement_guards
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
  ),
  'successful retry atomically upgrades the failed pair to a review candidate'
);
select extensions.is(
  (
    select jsonb_agg(to_jsonb(receipt) order by expected_cursor_key)
    from private.email_import_sync_receipts receipt
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
  ),
  (select receipts from email_import_sync_receipt_snapshot),
  'successful retry also preserves every incremental receipt byte-for-byte'
);
select extensions.ok(
  (
    select item -> 'candidate' is not null
      and item -> 'candidate' <> 'null'::jsonb
      and item -> 'errorCategory' = 'null'::jsonb
    from private.email_import_retry_receipts
    where owner_user_id = 'd5111111-1111-4111-8111-111111111111'
      and idempotency_key = repeat('e', 64)
  ),
  'successful retry receipt contains the exact safe candidate response'
);

set local role service_role;
select extensions.is(
  public.email_import_get_retry_replay(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111',
    'message-retry', repeat('a', 64), repeat('d', 64)
  ) #>> '{item,errorCategory}',
  'timeout',
  'the earlier exact retry key still replays after a later successful retry'
);
reset role;

insert into private.email_import_retry_receipts (
  owner_user_id, idempotency_key, connection_id, provider_message_id,
  provider_message_id_hash, expected_content_hash, retry_outcome, item,
  suppression, created_at
)
select
  'd5111111-1111-4111-8111-111111111111', repeat('4', 64),
  'd6111111-1111-4111-8111-111111111111', 'message-unsafe',
  provider_message_id_hash, repeat('b', 64), 'persisted',
  jsonb_build_object(
    'providerMessageId', 'message-unsafe',
    'providerThreadId', 'thread-unsafe',
    'receivedAt', '2031-02-01T00:01:00Z',
    'sanitizedContentHash', repeat('b', 64),
    'evidenceExcerpts', '[]'::jsonb,
    'candidate', null,
    'errorCategory', 'timeout'
  ),
  null, now()
from public.email_sources
where provider_message_id = 'message-unsafe';

set local role service_role;
select extensions.lives_ok(
  format(
    $sql$
      select public.email_import_reconcile_dismissal(
        'd5111111-1111-4111-8111-111111111111',
        'd6111111-1111-4111-8111-111111111111',
        'gmail', repeat('9', 64), %L, %L, repeat('b', 64),
        'dismiss-failed-unsafe', now(),
        'd7111111-1111-4111-8111-111111111114'
      )
    $sql$,
    (select provider_message_id_hash from public.email_sources where provider_message_id = 'message-unsafe'),
    (select provider_thread_id_hash from public.email_sources where provider_message_id = 'message-unsafe')
  ),
  'a payload-free failed candidate can still be dismissed by complete safe identity'
);
reset role;

select extensions.ok(
  not exists (
    select 1 from public.email_sources where provider_message_id = 'message-unsafe'
  ) and exists (
    select 1 from private.email_import_dismissal_tombstones
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
      and sanitized_content_hash = repeat('b', 64)
  ),
  'dismissal deletes raw source/candidate rows and leaves only the minimal tombstone'
);
select extensions.ok(
  2 = (
    select count(*) from private.email_import_sync_receipts
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
  ) and 1 = (
    select jsonb_array_length(items)
    from private.email_import_sync_receipts
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
      and expected_cursor is null
  ) and 'message-retry' = (
    select items -> 0 ->> 'providerMessageId'
    from private.email_import_sync_receipts
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
      and expected_cursor is null
  ) and 0 = (
    select jsonb_array_length(items)
    from private.email_import_sync_receipts
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
      and expected_cursor = 'cursor-failure-1'
  ) and 2 = (
    select count(*) from private.email_import_retry_receipts
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
      and provider_message_id = 'message-retry'
  ) and not exists (
    select 1 from private.email_import_retry_receipts
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
      and provider_message_id = 'message-unsafe'
  ) and exists (
    select 1 from private.email_import_retry_receipts
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
      and provider_message_id_hash = private.email_import_provider_identifier_hash(
        'message', 'gmail', repeat('9', 64), 'message-unsafe'
      )
      and provider_message_id is null
      and retry_outcome = 'suppressed'
      and suppression ->> 'providerMessageIdHash' = provider_message_id_hash
  ),
  'dismissal redacts only its message while retaining pages and unrelated retry keys'
);
select extensions.throws_matching(
  $sql$
    update private.email_import_sync_receipts
    set item_message_id_hashes = suppression_message_id_hashes
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
      and expected_cursor is null
  $sql$,
  '.*email_import_sync_receipts_identity_partition.*',
  'receipt storage rejects overlap between committed item and suppression hashes'
);

set local role service_role;
select extensions.ok(
  public.email_import_get_retry_replay(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111',
    'message-unsafe', repeat('b', 64), repeat('4', 64)
  ) ->> 'retry_outcome' = 'suppressed'
  and public.email_import_get_retry_replay(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111',
    'message-unsafe', repeat('b', 64), repeat('4', 64)
  ) #>> '{suppression,providerMessageIdHash}' ~ '^[0-9a-f]{64}$',
  'dismissed exact retry key replays a hash-only suppression without raw identity'
);
select extensions.is(
  public.email_import_get_retry_replay(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111',
    'message-retry', repeat('a', 64), repeat('d', 64)
  ) #>> '{item,errorCategory}',
  'timeout',
  'the older exact retry key survives an unrelated dismissal'
);
reset role;

set local role service_role;
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-2', 'cursor-failure-3',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-unsafe-repeat',
        'provider_thread_id', 'thread-unsafe',
        'received_at', '2031-02-02T00:00:00Z',
        'sanitized_content_hash', repeat('b', 64),
        'evidence_metadata', '[]'::jsonb,
        'processing_state', 'failed',
        'error_category', 'unsafe_content'
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-unsafe-repeat',
        'validated_payload', null,
        'error_category', 'unsafe_content'
      )),
      false, now(),
      'd7111111-1111-4111-8111-111111111115'
    )
  $sql$,
  'a dismissed same-thread/content failed repeat advances safely'
);
reset role;
select extensions.ok(
  not exists (
    select 1 from public.email_sources
    where provider_message_id = 'message-unsafe-repeat'
  ) and (
    select items = '[]'::jsonb
      and suppressions #>> '{0,providerMessageIdHash}' =
        private.email_import_provider_identifier_hash(
          'message', 'gmail', repeat('9', 64), 'message-unsafe-repeat'
        )
      and suppressions #>> '{0,providerMessageIdHash}' ~ '^[0-9a-f]{64}$'
      and (
        select count(*) from jsonb_object_keys(suppressions -> 0)
      ) = 2
      and suppressions #>> '{0,reason}' = 'dismissed'
    from private.email_import_sync_receipts
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
      and expected_cursor = 'cursor-failure-2'
  ),
  'dismissed failed repeats restore neither raw identifiers nor receipt payloads'
);

set local role service_role;
select extensions.is(
  public.email_import_get_sync_replay(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111',
    'cursor-failure-2'
  ) #>> '{suppressions,0,reason}',
  'dismissed',
  'lost normal-sync response replays the same dismissed suppression ack'
);
select extensions.is(
  public.email_import_persist_sync_page(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111',
    'cursor-failure-3', 'cursor-deduplicated',
    jsonb_build_array(jsonb_build_object(
      'provider_message_id', 'message-retry',
      'provider_thread_id', 'thread-retry',
      'received_at', '2031-02-02T00:30:00Z',
      'sanitized_content_hash', repeat('0', 64),
      'evidence_metadata', '[]'::jsonb,
      'processing_state', 'failed',
      'error_category', 'timeout'
    )),
    jsonb_build_array(jsonb_build_object(
      'provider_message_id', 'message-retry',
      'validated_payload', null,
      'error_category', 'timeout'
    )),
    false, now(), 'd7111111-1111-4111-8111-111111111139'
  ) #>> '{page,suppressions,0,reason}',
  'deduplicated',
  'normal sync returns an exact deduplicated ack for an immutable successful identity'
);
select extensions.is(
  public.email_import_get_sync_replay(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111',
    'cursor-failure-3'
  ) #>> '{suppressions,0,reason}',
  'deduplicated',
  'deduplicated normal-sync ack is atomically replayable'
);
reset role;

set local role service_role;
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-deduplicated', 'cursor-semantic-4',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-semantic-retry',
        'provider_thread_id', 'thread-retry',
        'received_at', '2031-02-02T01:00:00Z',
        'sanitized_content_hash', repeat('6', 64),
        'evidence_metadata', '[]'::jsonb,
        'processing_state', 'failed',
        'error_category', 'timeout'
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-semantic-retry',
        'validated_payload', null,
        'error_category', 'timeout'
      )),
      false, now(),
      'd7111111-1111-4111-8111-111111111140'
    )
  $sql$,
  'a transient failed B is persisted before its same-thread A is dismissed'
);
reset role;

create temporary table email_import_semantic_payload on commit drop as
select c.validated_payload as payload
from public.email_sources s
join public.email_candidates c on c.source_id = s.id
where s.provider_message_id = 'message-retry';
grant select on email_import_semantic_payload to service_role;

set local role service_role;
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_retry_candidate(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-semantic-retry',
        'provider_thread_id', 'thread-retry',
        'received_at', '2031-02-02T01:00:00Z',
        'sanitized_content_hash', repeat('6', 64),
        'evidence_metadata', '[]'::jsonb,
        'processing_state', 'failed',
        'error_category', 'timeout'
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-semantic-retry',
        'validated_payload', null,
        'error_category', 'timeout'
      )),
      repeat('6', 64), repeat('2', 64), now(),
      'd7111111-1111-4111-8111-111111111143'
    )
  $sql$,
  'failed B has an older exact retry receipt before semantic suppression'
);
select extensions.lives_ok(
  format(
    $sql$
      select public.email_import_reconcile_dismissal(
        'd5111111-1111-4111-8111-111111111111',
        'd6111111-1111-4111-8111-111111111111',
        'gmail', repeat('9', 64), %L, %L, repeat('f', 64),
        'dismiss-semantic-a', now(),
        'd7111111-1111-4111-8111-111111111141'
      )
    $sql$,
    (select provider_message_id_hash from public.email_sources
      where provider_message_id = 'message-retry'),
    (select provider_thread_id_hash from public.email_sources
      where provider_message_id = 'message-retry')
  ),
  'successful A dismissal creates a semantic tombstone while failed B remains retryable'
);
select extensions.is(
  public.email_import_persist_retry_candidate(
    'd5111111-1111-4111-8111-111111111111',
    'd6111111-1111-4111-8111-111111111111',
    jsonb_build_array(jsonb_build_object(
      'provider_message_id', 'message-semantic-retry',
      'provider_thread_id', 'thread-retry',
      'received_at', '2031-02-02T01:00:00Z',
      'sanitized_content_hash', repeat('7', 64),
      'evidence_metadata', jsonb_build_array('semantic retry'),
      'processing_state', 'processed',
      'error_category', null
    )),
    jsonb_build_array(jsonb_build_object(
      'provider_message_id', 'message-semantic-retry',
      'validated_payload', (select payload from email_import_semantic_payload),
      'error_category', null
    )),
    repeat('6', 64), repeat('3', 64), now(),
    'd7111111-1111-4111-8111-111111111142'
  ) ->> 'retry_outcome',
  'suppressed',
  'retry result is suppressed when successful B matches A semantic tombstone'
);
reset role;

select extensions.ok(
  not exists (
    select 1 from public.email_sources
    where provider_message_id = 'message-semantic-retry'
  ) and exists (
    select 1 from private.email_import_retry_receipts
    where provider_message_id_hash =
        private.email_import_provider_identifier_hash(
          'message', 'gmail', repeat('9', 64), 'message-semantic-retry'
        )
      and retry_outcome = 'suppressed'
      and provider_message_id is null
      and item is null
      and suppression ->> 'providerMessageIdHash' =
        provider_message_id_hash
      and suppression ->> 'reason' = 'dismissed'
  ) and 2 = (
    select count(*) from private.email_import_retry_receipts
    where provider_message_id_hash =
        private.email_import_provider_identifier_hash(
          'message', 'gmail', repeat('9', 64), 'message-semantic-retry'
        )
      and retry_outcome = 'suppressed'
      and provider_message_id is null
      and item is null
      and suppression ->> 'reason' = 'dismissed'
  ) and not exists (
    select 1
    from private.email_import_sync_receipts receipt
    cross join lateral jsonb_array_elements(receipt.items) item
    where receipt.connection_id = 'd6111111-1111-4111-8111-111111111111'
      and item ->> 'providerMessageId' = 'message-semantic-retry'
  ) and exists (
    select 1
    from private.email_import_sync_receipts receipt
    cross join lateral jsonb_array_elements(receipt.suppressions) suppression
    where receipt.connection_id = 'd6111111-1111-4111-8111-111111111111'
      and suppression ->> 'providerMessageIdHash' =
        private.email_import_provider_identifier_hash(
          'message', 'gmail', repeat('9', 64), 'message-semantic-retry'
        )
      and suppression ->> 'reason' = 'dismissed'
  ) and not exists (
    select 1 from private.email_import_sync_receipts receipt
    where receipt.connection_id = 'd6111111-1111-4111-8111-111111111111'
      and (
        receipt.items::text like '%message-semantic-retry%'
        or receipt.suppressions::text like '%message-semantic-retry%'
      )
  ) and not exists (
    select 1 from private.email_import_retry_receipts receipt
    where receipt.connection_id = 'd6111111-1111-4111-8111-111111111111'
      and (
        receipt.provider_message_id = 'message-semantic-retry'
        or coalesce(receipt.item::text, '') like '%message-semantic-retry%'
        or coalesce(receipt.suppression::text, '') like '%message-semantic-retry%'
      )
  ),
  'suppression removes raw B from every receipt and retains only exact hash acks'
);

set local role service_role;
select extensions.ok(
  (
    public.email_import_get_retry_replay(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'message-semantic-retry', repeat('6', 64), repeat('3', 64)
    ) ->> 'retry_outcome'
  ) = 'suppressed'
  and (
    public.email_import_get_retry_replay(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'message-semantic-retry', repeat('6', 64), repeat('3', 64)
    ) #>> '{suppression,reason}'
  ) = 'dismissed',
  'a lost suppressed retry response replays the same exact suppression ack'
);
select extensions.ok(
  (
    public.email_import_get_retry_replay(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'message-semantic-retry', repeat('6', 64), repeat('2', 64)
    ) ->> 'retry_outcome'
  ) = 'suppressed'
  and (
    public.email_import_get_retry_replay(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'message-semantic-retry', repeat('6', 64), repeat('2', 64)
    ) #>> '{suppression,reason}'
  ) = 'dismissed',
  'the older exact retry key is rewritten to the same suppression ack'
);
reset role;

set local role service_role;
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-semantic-4', 'cursor-failure-4',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-delete-derived',
        'provider_thread_id', 'thread-delete-derived',
        'received_at', '2031-02-03T00:00:00Z',
        'sanitized_content_hash', repeat('8', 64),
        'evidence_metadata', '[]'::jsonb,
        'processing_state', 'failed',
        'error_category', 'timeout'
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'message-delete-derived',
        'validated_payload', null,
        'error_category', 'timeout'
      )),
      false, now(),
      'd7111111-1111-4111-8111-111111111116'
    )
  $sql$,
  'a final derived-data fixture creates a private page receipt'
);
select extensions.lives_ok(
  $sql$
    select public.email_import_finalize_disconnect(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      true, false, false, now(),
      'd7111111-1111-4111-8111-111111111117'
    )
  $sql$,
  'disconnect with derived deletion remains supported'
);
reset role;

select extensions.ok(
  not exists (
    select 1 from public.email_sources
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
  ) and not exists (
    select 1 from private.email_import_sync_receipts
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
  ) and not exists (
    select 1 from private.email_import_retry_receipts
    where connection_id = 'd6111111-1111-4111-8111-111111111111'
  ),
  'derived deletion removes sources, candidates, and every independent receipt'
);
select extensions.is(
  (
    select connection_state from public.email_connections
    where id = 'd6111111-1111-4111-8111-111111111111'
  ),
  'disconnected',
  'derived deletion leaves the retained connection explicitly disconnected'
);
set local role service_role;
select extensions.throws_ok(
  $sql$
    select public.email_import_get_sync_replay(
      'd5111111-1111-4111-8111-111111111111',
      'd6111111-1111-4111-8111-111111111111',
      'cursor-failure-2'
    )
  $sql$,
  '42501',
  'Email connection owner mismatch.',
  'a disconnected connection cannot replay stale sync data'
);
reset role;

set local role service_role;
select extensions.lives_ok(
  $sql$
    do $body$
    begin
      perform public.email_import_persist_sync_page(
        'd5111111-1111-4111-8111-111111111111',
        'd6222222-2222-4222-8222-222222222222',
        null, repeat('x', 4096), '[]'::jsonb, '[]'::jsonb, false,
        now(), 'd7222222-2222-4222-8222-222222222201'
      );
      perform public.email_import_persist_sync_page(
        'd5111111-1111-4111-8111-111111111111',
        'd6222222-2222-4222-8222-222222222222',
        repeat('x', 4096), 'sync-cap-0',
        '[]'::jsonb, '[]'::jsonb, false,
        now(), 'd7222222-2222-4222-8222-222222222202'
      );
    end
    $body$
  $sql$,
  'fixed-width receipt keys accept and persist a 4096-character cursor'
);
select extensions.is(
  public.email_import_get_sync_replay(
    'd5111111-1111-4111-8111-111111111111',
    'd6222222-2222-4222-8222-222222222222',
    repeat('x', 4096)
  ) ->> 'next_cursor',
  'sync-cap-0',
  'a maximum-length cursor has an exact collision-checked replay'
);
select extensions.lives_ok(
  $sql$
    do $body$
    declare
      page_number integer;
      expected_cursor text := 'sync-cap-0';
      next_cursor text;
    begin
      for page_number in 1..35 loop
        next_cursor := 'sync-cap-' || page_number::text;
        perform public.email_import_persist_sync_page(
          'd5111111-1111-4111-8111-111111111111',
          'd6222222-2222-4222-8222-222222222222',
          expected_cursor, next_cursor, '[]'::jsonb, '[]'::jsonb, false,
          now(), md5('sync-cap-' || page_number::text)::uuid
        );
        expected_cursor := next_cursor;
      end loop;
    end
    $body$
  $sql$,
  'many committed cursor pages stay within the bounded replay window'
);
reset role;

select extensions.ok(
  32 = (
    select count(*) from private.email_import_sync_receipts
    where connection_id = 'd6222222-2222-4222-8222-222222222222'
  ) and not exists (
    select 1 from private.email_import_sync_receipts
    where connection_id = 'd6222222-2222-4222-8222-222222222222'
      and expected_cursor = repeat('x', 4096)
  ) and exists (
    select 1 from private.email_import_sync_receipts
    where connection_id = 'd6222222-2222-4222-8222-222222222222'
      and expected_cursor = 'sync-cap-34'
  ),
  'sync retention keeps exactly the 32 most recent cursor pages'
);

update private.email_import_sync_receipts
set updated_at = now() - interval '25 hours'
where connection_id = 'd6222222-2222-4222-8222-222222222222'
  and expected_cursor = 'sync-cap-20';
set local role service_role;
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6222222-2222-4222-8222-222222222222',
      'sync-cap-35', 'sync-cap-36', '[]'::jsonb, '[]'::jsonb, false,
      now(), 'd7222222-2222-4222-8222-222222222203'
    )
  $sql$,
  'a later sync opportunistically prunes expired replay rows'
);
reset role;
select extensions.ok(
  32 = (
    select count(*) from private.email_import_sync_receipts
    where connection_id = 'd6222222-2222-4222-8222-222222222222'
  ) and not exists (
    select 1 from private.email_import_sync_receipts
    where connection_id = 'd6222222-2222-4222-8222-222222222222'
      and expected_cursor = 'sync-cap-20'
  ),
  'expired sync receipts are deleted while the per-connection cap remains exact'
);

set local role service_role;
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_sync_page(
      'd5111111-1111-4111-8111-111111111111',
      'd6222222-2222-4222-8222-222222222222',
      'sync-cap-36', 'sync-cap-37',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'bounded-retry-message',
        'provider_thread_id', 'bounded-retry-thread',
        'received_at', '2031-02-04T00:00:00Z',
        'sanitized_content_hash', repeat('5', 64),
        'evidence_metadata', '[]'::jsonb,
        'processing_state', 'failed',
        'error_category', 'timeout'
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'bounded-retry-message',
        'validated_payload', null,
        'error_category', 'timeout'
      )),
      false, now(), 'd7222222-2222-4222-8222-222222222204'
    )
  $sql$,
  'a transient failure fixture supports bounded retry receipt stress'
);
select extensions.lives_ok(
  $sql$
    do $body$
    declare retry_number integer;
    begin
      for retry_number in 1..65 loop
        perform public.email_import_persist_retry_candidate(
          'd5111111-1111-4111-8111-111111111111',
          'd6222222-2222-4222-8222-222222222222',
          jsonb_build_array(jsonb_build_object(
            'provider_message_id', 'bounded-retry-message',
            'provider_thread_id', 'bounded-retry-thread',
            'received_at', '2031-02-04T00:00:00Z',
            'sanitized_content_hash', repeat('5', 64),
            'evidence_metadata', '[]'::jsonb,
            'processing_state', 'failed',
            'error_category', 'timeout'
          )),
          jsonb_build_array(jsonb_build_object(
            'provider_message_id', 'bounded-retry-message',
            'validated_payload', null,
            'error_category', 'timeout'
          )),
          repeat('5', 64), lpad(to_hex(retry_number), 64, '0'), now(),
          md5('bounded-retry-' || retry_number::text)::uuid
        );
      end loop;
    end
    $body$
  $sql$,
  'many exact retry keys remain replayable up to the configured cap'
);
reset role;

select extensions.ok(
  64 = (
    select count(*) from private.email_import_retry_receipts
    where connection_id = 'd6222222-2222-4222-8222-222222222222'
  ) and not exists (
    select 1 from private.email_import_retry_receipts
    where owner_user_id = 'd5111111-1111-4111-8111-111111111111'
      and idempotency_key = lpad(to_hex(1), 64, '0')
  ) and exists (
    select 1 from private.email_import_retry_receipts
    where owner_user_id = 'd5111111-1111-4111-8111-111111111111'
      and idempotency_key = lpad(to_hex(65), 64, '0')
      and retry_outcome = 'persisted'
  ),
  'retry retention keeps the 64 newest exact keys without newer-key invalidation'
);

update private.email_import_retry_receipts
set created_at = now() - interval '25 hours'
where owner_user_id = 'd5111111-1111-4111-8111-111111111111'
  and idempotency_key = lpad(to_hex(2), 64, '0');
set local role service_role;
select extensions.lives_ok(
  $sql$
    select public.email_import_persist_retry_candidate(
      'd5111111-1111-4111-8111-111111111111',
      'd6222222-2222-4222-8222-222222222222',
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'bounded-retry-message',
        'provider_thread_id', 'bounded-retry-thread',
        'received_at', '2031-02-04T00:00:00Z',
        'sanitized_content_hash', repeat('5', 64),
        'evidence_metadata', '[]'::jsonb,
        'processing_state', 'failed',
        'error_category', 'timeout'
      )),
      jsonb_build_array(jsonb_build_object(
        'provider_message_id', 'bounded-retry-message',
        'validated_payload', null,
        'error_category', 'timeout'
      )),
      repeat('5', 64), lpad(to_hex(66), 64, '0'), now(),
      'd7222222-2222-4222-8222-222222222205'
    )
  $sql$,
  'a later retry opportunistically prunes expired idempotency rows'
);
reset role;
select extensions.ok(
  64 = (
    select count(*) from private.email_import_retry_receipts
    where connection_id = 'd6222222-2222-4222-8222-222222222222'
  ) and not exists (
    select 1 from private.email_import_retry_receipts
    where owner_user_id = 'd5111111-1111-4111-8111-111111111111'
      and idempotency_key = lpad(to_hex(2), 64, '0')
  ) and exists (
    select 1 from private.email_import_retry_receipts
    where owner_user_id = 'd5111111-1111-4111-8111-111111111111'
      and idempotency_key = lpad(to_hex(66), 64, '0')
  ),
  'expired retry receipts are deleted while the 64-key cap remains exact'
);

select * from extensions.finish();
rollback;
