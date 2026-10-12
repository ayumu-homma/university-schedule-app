begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(143);

select extensions.has_table(
  'public', 'document_sources', 'document sources table exists'
);
select extensions.has_table(
  'public', 'document_candidates', 'document candidates table exists'
);
select extensions.has_table(
  'public', 'document_confirmations', 'document confirmations table exists'
);
select extensions.ok(
  exists (
    select 1 from storage.buckets
    where id = 'schedule-documents' and name = 'schedule-documents'
  ),
  'the schedule document bucket exists'
);
select extensions.ok(
  (select not public from storage.buckets where id = 'schedule-documents'),
  'the schedule document bucket is private'
);
select extensions.is(
  (select file_size_limit from storage.buckets where id = 'schedule-documents'),
  10485760::bigint,
  'the private bucket enforces the ten MiB limit'
);
select extensions.ok(
  (
    select allowed_mime_types @> array[
      'application/pdf', 'image/png', 'image/jpeg', 'text/plain'
    ]
    from storage.buckets where id = 'schedule-documents'
  ),
  'the bucket accepts only the documented baseline MIME families'
);

select extensions.ok(
  (
    select bool_and(c.relrowsecurity)
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in (
        'document_sources', 'document_candidates', 'document_confirmations'
      )
  ),
  'RLS is enabled on every exposed document table'
);
select extensions.is(
  (
    select count(*)
    from pg_catalog.pg_policy p
    join pg_catalog.pg_class c on c.oid = p.polrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in (
        'document_sources', 'document_candidates', 'document_confirmations'
      )
      and p.polcmd = 'r'
  ),
  3::bigint,
  'each document metadata table has one owner read policy'
);
select extensions.is(
  (
    select count(*)
    from pg_catalog.pg_policy p
    join pg_catalog.pg_class c on c.oid = p.polrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in (
        'document_sources', 'document_candidates', 'document_confirmations'
      )
      and p.polcmd <> 'r'
      and p.polpermissive
  ),
  0::bigint,
  'clients have no permissive document metadata write policy'
);
select extensions.ok(
  (
    select bool_and(
      pg_catalog.has_table_privilege(
        'authenticated', format('public.%I', table_name), 'SELECT'
      )
      and not pg_catalog.has_table_privilege(
        'authenticated', format('public.%I', table_name), 'INSERT'
      )
      and not pg_catalog.has_table_privilege(
        'authenticated', format('public.%I', table_name), 'UPDATE'
      )
      and not pg_catalog.has_table_privilege(
        'authenticated', format('public.%I', table_name), 'DELETE'
      )
    )
    from unnest(array[
      'document_sources', 'document_candidates', 'document_confirmations'
    ]) table_name
  ),
  'authenticated clients can read RLS rows but cannot write tables directly'
);
select extensions.ok(
  exists (
    select 1
    from pg_catalog.pg_index index_definition
    join pg_catalog.pg_class index_relation
      on index_relation.oid = index_definition.indexrelid
    join pg_catalog.pg_class table_relation
      on table_relation.oid = index_definition.indrelid
    join pg_catalog.pg_namespace namespace
      on namespace.oid = table_relation.relnamespace
    where namespace.nspname = 'public'
      and table_relation.relname = 'document_candidates'
      and index_relation.relname = 'document_candidates_source_fingerprint_idx'
      and not index_definition.indisunique
  ),
  'same-source duplicate mentions retain separate evidence and provenance rows'
);
select extensions.ok(
  (
    with function_definition as (
      select pg_catalog.pg_get_functiondef(
        'public.create_document_source(uuid,text,bigint,text)'::regprocedure
      ) definition
    )
    select position(':document-source-owner' in definition) > 0
      and position(':document-source-owner' in definition)
        < position('select count(*) into v_recent_count' in lower(definition))
    from function_definition
  ),
  'the owner-wide reservation lock is acquired before the hourly rate count'
);
select extensions.ok(
  (
    select bool_and(
      not pg_catalog.has_table_privilege(
        'anon', format('public.%I', table_name), privilege_name
      )
    )
    from unnest(array[
      'document_sources', 'document_candidates', 'document_confirmations'
    ]) table_name
    cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) privilege_name
  ),
  'anonymous clients receive no document table privilege'
);
select extensions.ok(
  (
    select bool_and(
      pg_catalog.has_table_privilege(
        'service_role', format('public.%I', table_name), privilege_name
      )
    )
    from unnest(array[
      'document_sources', 'document_candidates', 'document_confirmations'
    ]) table_name
    cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) privilege_name
  ),
  'the trusted Edge role can manage bounded derived document rows'
);
select extensions.is(
  (
    select count(*)
    from pg_catalog.pg_policy p
    join pg_catalog.pg_class c on c.oid = p.polrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'storage'
      and c.relname = 'objects'
      and p.polname like 'document_objects_owner_%'
  ),
  3::bigint,
  'Storage has exact owner insert/read/delete policies'
);
select extensions.ok(
  not pg_catalog.has_function_privilege(
    'anon', 'public.create_document_source(uuid,text,bigint,text)', 'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'anon', 'public.confirm_document_candidate(uuid,bigint,uuid,text,jsonb,uuid)', 'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'anon', 'public.delete_document_source(uuid)', 'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'anon', 'public.begin_document_processing(uuid)', 'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'anon', 'public.fail_document_processing(uuid,bigint,text,integer)', 'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'anon', 'public.replace_document_candidates(uuid,text,bigint,jsonb)', 'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'anon', 'public.claim_expired_document_sources(integer)', 'EXECUTE'
  ),
  'anonymous callers cannot execute document lifecycle RPCs'
);
select extensions.ok(
  pg_catalog.has_function_privilege(
    'authenticated', 'public.create_document_source(uuid,text,bigint,text)', 'EXECUTE'
  )
  and pg_catalog.has_function_privilege(
    'authenticated', 'public.update_document_candidate(uuid,bigint,jsonb,text)', 'EXECUTE'
  )
  and pg_catalog.has_function_privilege(
    'authenticated', 'public.confirm_document_candidate(uuid,bigint,uuid,text,jsonb,uuid)', 'EXECUTE'
  )
  and pg_catalog.has_function_privilege(
    'authenticated', 'public.begin_document_processing(uuid)', 'EXECUTE'
  )
  and pg_catalog.has_function_privilege(
    'authenticated', 'public.fail_document_processing(uuid,bigint,text,integer)', 'EXECUTE'
  )
  and pg_catalog.has_function_privilege(
    'authenticated', 'public.replace_document_candidates(uuid,text,bigint,jsonb)', 'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated', 'public.claim_expired_document_sources(integer)', 'EXECUTE'
  ),
  'authenticated callers receive only the bounded lifecycle RPCs'
);
select extensions.ok(
  pg_catalog.has_function_privilege(
    'service_role', 'public.claim_expired_document_sources(integer)', 'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'service_role', 'public.begin_document_processing(uuid)', 'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'service_role', 'public.fail_document_processing(uuid,bigint,text,integer)', 'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'service_role', 'public.replace_document_candidates(uuid,text,bigint,jsonb)', 'EXECUTE'
  ),
  'only the service worker receives the cleanup RPC; user-context processing stays isolated'
);
select extensions.is_empty(
  $sql$
    select a.attname
    from pg_catalog.pg_attribute a
    join pg_catalog.pg_class c on c.oid = a.attrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname like 'document_%'
      and a.attnum > 0
      and not a.attisdropped
      and a.attname ~* '(^|_)(raw|bytes|body|file_name|api_key|token)($|_)'
  $sql$,
  'exposed document tables contain no raw bytes, filename, token, or API key'
);

insert into auth.users (id)
values
  ('d0111111-1111-4111-8111-111111111111'),
  ('d0222222-2222-4222-8222-222222222222');

insert into public.user_courses (
  id, owner_user_id, title, normalized_title
) values
  (
    'd3000000-0000-4000-8000-000000000001',
    'd0111111-1111-4111-8111-111111111111',
    '合成データ演習 A',
    '合成データ演習a'
  ),
  (
    'd3000000-0000-4000-8000-000000000002',
    'd0111111-1111-4111-8111-111111111111',
    '合成データ演習 B',
    '合成データ演習b'
  );

create temporary table document_reimport_results (
  lifecycle text primary key,
  source_id uuid not null,
  storage_path text not null
) on commit drop;
grant select, insert on document_reimport_results to authenticated;

create function pg_temp.document_candidate(
  candidate_key text,
  candidate_type text,
  candidate_title text,
  due_at text default null,
  start_at text default null,
  end_at text default null
)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'candidate_id', candidate_key,
    'type', candidate_type,
    'title', candidate_title,
    'course_hint', jsonb_build_object('name', '合成データ演習', 'code', null),
    'due_at', due_at,
    'all_day', false,
    'start_at', start_at,
    'end_at', end_at,
    'location', null,
    'submission_url', null,
    'notes', 'CI用の合成候補',
    'confidence', jsonb_build_object(
      'overall', 0.91, 'course', 0.84, 'date_time', 0.88
    ),
    'evidence', jsonb_build_array(jsonb_build_object(
      'page_number', 2,
      'section', '課題と試験',
      'excerpt', 'これは実在資料を含まない合成根拠です。'
    )),
    'warnings', '[]'::jsonb,
    'requires_user_confirmation', true
  )
$$;

create function pg_temp.document_batch(
  source_id uuid,
  content_hash text,
  candidates jsonb
)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'schema_version', '1.0',
    'source_id', source_id::text,
    'content_hash', content_hash,
    'timezone', 'Asia/Tokyo',
    'candidates', candidates
  )
$$;

set local request.jwt.claims = '{"sub":"d0111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = 'd0111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.lives_ok(
  $sql$
    select public.create_document_source(
      'd1000000-0000-4000-8000-000000000001',
      'application/pdf',
      4096,
      repeat('a', 64)
    )
  $sql$,
  'owner A can reserve one private document source'
);
select extensions.results_eq(
  $sql$
    select storage_path, processing_state
    from public.document_sources
    where id = 'd1000000-0000-4000-8000-000000000001'
  $sql$,
  $sql$
    values (
      'd0111111-1111-4111-8111-111111111111/d1000000-0000-4000-8000-000000000001/source.pdf'::text,
      'pending_upload'::text
    )
  $sql$,
  'the server returns an owner-scoped deterministic Storage path'
);
select extensions.is(
  (
    public.create_document_source(
      'd1000000-0000-4000-8000-000000000099',
      'application/pdf',
      4096,
      repeat('a', 64)
    ) ->> 'replayed'
  )::boolean,
  true,
  'the same content hash replays the existing source instead of duplicating it'
);
select extensions.throws_ok(
  $sql$
    select public.create_document_source(
      'd1000000-0000-4000-8000-000000000098',
      'application/pdf',
      10485761,
      repeat('b', 64)
    )
  $sql$,
  '22023',
  'invalid_document_source',
  'oversized source metadata fails closed before upload'
);

select extensions.throws_ok(
  $sql$
    select public.mark_document_source_uploaded(
      'd1000000-0000-4000-8000-000000000001'
    )
  $sql$,
  'P0002',
  'document_object_not_found',
  'upload completion cannot be marked before the private object exists'
);
select extensions.lives_ok(
  $sql$
    insert into storage.objects (bucket_id, name)
    values (
      'schedule-documents',
      'd0111111-1111-4111-8111-111111111111/d1000000-0000-4000-8000-000000000001/source.pdf'
    )
  $sql$,
  'owner A can insert its exact reserved Storage object'
);
select extensions.is(
  (
    select count(*) from storage.objects
    where bucket_id = 'schedule-documents'
      and name = 'd0111111-1111-4111-8111-111111111111/d1000000-0000-4000-8000-000000000001/source.pdf'
  ),
  1::bigint,
  'owner A can read its unexpired private Storage object'
);
select extensions.is(
  (
    public.mark_document_source_uploaded(
      'd1000000-0000-4000-8000-000000000001'
    ) ->> 'processing_state'
  ),
  'uploaded'::text,
  'mark uploaded verifies Storage existence and advances only the pending source'
);
select extensions.is(
  (
    public.mark_document_source_uploaded(
      'd1000000-0000-4000-8000-000000000001'
    ) ->> 'replayed'
  )::boolean,
  true,
  'mark uploaded replay does not rotate the optimistic version token'
);
select extensions.throws_ok(
  $sql$
    select public.replace_document_candidates(
      'd1000000-0000-4000-8000-000000000001',
      repeat('a', 64),
      (select version from public.document_sources
       where id = 'd1000000-0000-4000-8000-000000000001'),
      pg_temp.document_batch(
        'd1000000-0000-4000-8000-000000000001',
        repeat('a', 64),
        '[]'::jsonb
      )
    )
  $sql$,
  '22023',
  'document_processing_not_claimed',
  'candidate persistence cannot run before an atomic processing claim'
);
select extensions.is(
  (
    public.begin_document_processing(
      'd1000000-0000-4000-8000-000000000001'
    ) ->> 'processing_state'
  ),
  'processing'::text,
  'begin processing atomically claims an uploaded source'
);
select extensions.results_eq(
  $sql$
    select processing_attempt_count, version
    from public.document_sources
    where id = 'd1000000-0000-4000-8000-000000000001'
  $sql$,
  $sql$ values (1, 3::bigint) $sql$,
  'the claim increments the bounded attempt count and version token'
);
select extensions.throws_ok(
  $sql$
    select public.begin_document_processing(
      'd1000000-0000-4000-8000-000000000001'
    )
  $sql$,
  'P0001',
  'document_processing_in_progress',
  'a live claim prevents duplicate provider work'
);
select extensions.throws_ok(
  $sql$
    select public.replace_document_candidates(
      'd1000000-0000-4000-8000-000000000001',
      repeat('a', 64),
      2,
      pg_temp.document_batch(
        'd1000000-0000-4000-8000-000000000001', repeat('a', 64), '[]'::jsonb
      )
    )
  $sql$,
  '40001',
  'document_processing_version_conflict',
  'a stale worker cannot complete a newer processing claim'
);

select extensions.throws_ok(
  $sql$
    select public.replace_document_candidates(
      'd1000000-0000-4000-8000-000000000001',
      repeat('a', 64),
      3,
      pg_temp.document_batch(
        'd1000000-0000-4000-8000-000000000001', repeat('a', 64), '[]'::jsonb
      ) || jsonb_build_object('unexpected', true)
    )
  $sql$,
  '22023',
  'invalid_candidate_batch',
  'the persistence boundary rejects extra batch keys'
);
select extensions.throws_ok(
  $sql$
    select public.replace_document_candidates(
      'd1000000-0000-4000-8000-000000000001', repeat('a', 64), 3,
      jsonb_set(
        pg_temp.document_batch(
          'd1000000-0000-4000-8000-000000000001', repeat('a', 64), '[]'::jsonb
        ),
        '{timezone}',
        '"UTC"'::jsonb
      )
    )
  $sql$,
  '22023',
  'invalid_candidate_batch',
  'the wire contract requires the documented Asia/Tokyo timezone'
);
select extensions.throws_ok(
  $sql$
    select public.replace_document_candidates(
      'd1000000-0000-4000-8000-000000000001', repeat('a', 64), 3,
      pg_temp.document_batch(
        'd1000000-0000-4000-8000-000000000001', repeat('a', 64),
        jsonb_build_array(
          pg_temp.document_candidate(
            'invalid-extra', 'assignment', 'strict fields',
            '2026-08-20T23:59:00+09:00'
          ) || jsonb_build_object('unexpected', true)
        )
      )
    )
  $sql$,
  '22023',
  'invalid_candidate_payload',
  'candidate payloads reject extra keys at the SQL trust boundary'
);
select extensions.throws_ok(
  $sql$
    select public.replace_document_candidates(
      'd1000000-0000-4000-8000-000000000001', repeat('a', 64), 3,
      pg_temp.document_batch(
        'd1000000-0000-4000-8000-000000000001', repeat('a', 64),
        jsonb_build_array(jsonb_set(
          pg_temp.document_candidate(
            'invalid-type', 'assignment', 'strict type',
            '2026-08-20T23:59:00+09:00'
          ),
          '{confidence,overall}',
          '"0.9"'::jsonb
        ))
      )
    )
  $sql$,
  '22023',
  'invalid_candidate_confidence',
  'confidence values must retain numeric JSON types'
);
select extensions.throws_ok(
  $sql$
    select public.replace_document_candidates(
      'd1000000-0000-4000-8000-000000000001', repeat('a', 64), 3,
      pg_temp.document_batch(
        'd1000000-0000-4000-8000-000000000001', repeat('a', 64),
        jsonb_build_array(jsonb_set(
          pg_temp.document_candidate(
            'invalid-length', 'assignment', 'bounded title',
            '2026-08-20T23:59:00+09:00'
          ),
          '{title}',
          to_jsonb(repeat('x', 201))
        ))
      )
    )
  $sql$,
  '22023',
  'invalid_candidate_payload',
  'candidate strings are rejected beyond the documented character limit'
);
select extensions.throws_ok(
  $sql$
    select public.replace_document_candidates(
      'd1000000-0000-4000-8000-000000000001', repeat('a', 64), 3,
      pg_temp.document_batch(
        'd1000000-0000-4000-8000-000000000001', repeat('a', 64),
        jsonb_build_array(jsonb_set(
          pg_temp.document_candidate(
            'invalid-url', 'assignment', 'unsafe URL',
            '2026-08-20T23:59:00+09:00'
          ),
          '{submission_url}',
          '"javascript:alert(1)"'::jsonb
        ))
      )
    )
  $sql$,
  '22023',
  'invalid_candidate_payload',
  'javascript submission URLs fail closed at persistence'
);
select extensions.throws_ok(
  $sql$
    select public.replace_document_candidates(
      'd1000000-0000-4000-8000-000000000001', repeat('a', 64), 3,
      pg_temp.document_batch(
        'd1000000-0000-4000-8000-000000000001', repeat('a', 64),
        jsonb_build_array(pg_temp.document_candidate(
          'invalid-date', 'assignment', 'invalid calendar date',
          '2026-02-30T23:59:00+09:00'
        ))
      )
    )
  $sql$,
  '22023',
  'invalid_candidate_payload',
  'invalid RFC3339 calendar dates cannot reach confirmed entities'
);
select extensions.throws_ok(
  $sql$
    select public.replace_document_candidates(
      'd1000000-0000-4000-8000-000000000001', repeat('a', 64), 3,
      pg_temp.document_batch(
        'd1000000-0000-4000-8000-000000000001', repeat('a', 64),
        jsonb_build_array(jsonb_set(
          pg_temp.document_candidate(
            'invalid-warning', 'assignment', 'warning enum',
            '2026-08-20T23:59:00+09:00'
          ),
          '{warnings}',
          '["invented_warning"]'::jsonb
        ))
      )
    )
  $sql$,
  '22023',
  'invalid_candidate_warnings',
  'warnings are restricted to the exact shared enum'
);
select extensions.throws_ok(
  $sql$
    select public.replace_document_candidates(
      'd1000000-0000-4000-8000-000000000001', repeat('a', 64), 3,
      pg_temp.document_batch(
        'd1000000-0000-4000-8000-000000000001', repeat('a', 64),
        jsonb_build_array(jsonb_set(
          pg_temp.document_candidate(
            'invalid-evidence', 'assignment', 'evidence type',
            '2026-08-20T23:59:00+09:00'
          ),
          '{evidence,0,page_number}',
          '"two"'::jsonb
        ))
      )
    )
  $sql$,
  '22023',
  'invalid_candidate_evidence',
  'evidence page numbers reject malformed JSON types'
);
select extensions.throws_ok(
  $sql$
    select public.replace_document_candidates(
      'd1000000-0000-4000-8000-000000000001', repeat('a', 64), 3,
      pg_temp.document_batch(
        'd1000000-0000-4000-8000-000000000001', repeat('a', 64),
        jsonb_build_array(jsonb_set(
          pg_temp.document_candidate(
            'invalid-confirmation', 'assignment', 'confirmation flag',
            '2026-08-20T23:59:00+09:00'
          ),
          '{requires_user_confirmation}',
          'false'::jsonb
        ))
      )
    )
  $sql$,
  '22023',
  'invalid_candidate_payload',
  'every persisted proposal must still require explicit confirmation'
);

select extensions.lives_ok(
  $sql$
    select public.replace_document_candidates(
      'd1000000-0000-4000-8000-000000000001',
      repeat('a', 64),
      3,
      jsonb_build_object(
        'schema_version', '1.0',
        'source_id', 'd1000000-0000-4000-8000-000000000001',
        'content_hash', repeat('a', 64),
        'timezone', 'Asia/Tokyo',
        'candidates', jsonb_build_array(
          pg_temp.document_candidate(
            'assignment-a', 'assignment', '暗号方式比較レポート',
            '2026-08-20T23:59:00+09:00'
          ),
          pg_temp.document_candidate(
            'assignment-b', 'assignment', '認証方式の小課題',
            '2026-08-24T17:00:00+09:00'
          ),
          pg_temp.document_candidate(
            'exam-a', 'exam', '達成度確認', null,
            '2026-08-27T10:35:00+09:00',
            '2026-08-27T12:05:00+09:00'
          ),
          pg_temp.document_candidate(
            'assignment-a-repeat', 'assignment', '暗号方式比較レポート',
            '2026-08-20T23:59:00+09:00'
          )
        )
      )
    )
  $sql$,
  'one strict batch can persist multiple assignments and an exam'
);
select extensions.is(
  (
    select count(*) from public.document_candidates
    where source_id = 'd1000000-0000-4000-8000-000000000001'
  ),
  4::bigint,
  'a repeated semantic candidate retains independent evidence in the source batch'
);
select extensions.is(
  (
    select processing_state from public.document_sources
    where id = 'd1000000-0000-4000-8000-000000000001'
  ),
  'processed'::text,
  'successful extraction moves the source to processed'
);
select extensions.results_eq(
  $sql$
    select
      (result ->> 'replayed')::boolean,
      (result ->> 'attempt_count')::integer
    from (
      select public.begin_document_processing(
        'd1000000-0000-4000-8000-000000000001'
      ) result
    ) replay
  $sql$,
  $sql$ values (true, 1) $sql$,
  'processed begin short-circuits before another provider attempt'
);
select extensions.is(
  (
    public.replace_document_candidates(
      'd1000000-0000-4000-8000-000000000001',
      repeat('a', 64),
      4,
      jsonb_build_object(
        'schema_version', '1.0',
        'source_id', 'd1000000-0000-4000-8000-000000000001',
        'content_hash', repeat('a', 64),
        'timezone', 'Asia/Tokyo',
        'candidates', '[]'::jsonb
      )
    ) ->> 'replayed'
  )::boolean,
  true,
  'reprocessing an already processed source is an idempotent replay'
);
select extensions.is(
  (select count(*) from public.document_sources),
  1::bigint,
  'owner A can read its source'
);
select extensions.is(
  (select count(*) from public.document_candidates),
  4::bigint,
  'owner A can read its candidate batch'
);

reset role;
select extensions.is(
  (
    select count(*) from public.assignments
    where owner_user_id = 'd0111111-1111-4111-8111-111111111111'
  ),
  0::bigint,
  'candidate extraction does not create an assignment before confirmation'
);
select extensions.is(
  (
    select count(*) from public.exams
    where owner_user_id = 'd0111111-1111-4111-8111-111111111111'
  ),
  0::bigint,
  'candidate extraction does not create an exam before confirmation'
);
select set_config(
  'test.document_assignment_id',
  (
    select id::text from public.document_candidates
    where candidate_key = 'assignment-a'
  ),
  true
);
set local request.jwt.claims = '{"sub":"d0222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = 'd0222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is(
  (select count(*) from public.document_sources),
  0::bigint,
  'owner B cannot read owner A source metadata'
);
select extensions.is(
  (select count(*) from public.document_candidates),
  0::bigint,
  'owner B cannot read owner A candidate payloads'
);
select extensions.is(
  (
    select count(*) from storage.objects
    where bucket_id = 'schedule-documents'
      and name = 'd0111111-1111-4111-8111-111111111111/d1000000-0000-4000-8000-000000000001/source.pdf'
  ),
  0::bigint,
  'owner B cannot read owner A private Storage object'
);
-- The Storage API sets this transaction-local guard before metadata deletion.
-- Keeping it explicit lets pgTAP exercise RLS without bypassing Storage's
-- orphan-protection trigger.
set local storage.allow_delete_query = 'true';
select extensions.is_empty(
  $sql$
    delete from storage.objects
    where bucket_id = 'schedule-documents'
      and name = 'd0111111-1111-4111-8111-111111111111/d1000000-0000-4000-8000-000000000001/source.pdf'
    returning name
  $sql$,
  'owner B cannot delete owner A private Storage object'
);
select extensions.throws_ok(
  $sql$
    insert into storage.objects (bucket_id, name)
    values (
      'schedule-documents',
      'd0111111-1111-4111-8111-111111111111/d1999999-9999-4999-8999-999999999999/source.pdf'
    )
  $sql$,
  '42501',
  'new row violates row-level security policy for table "objects"',
  'owner B cannot insert an unreserved object below owner A prefix'
);
select extensions.throws_ok(
  format(
    'select public.update_document_candidate(%L::uuid, 1, null, %L)',
    current_setting('test.document_assignment_id'),
    'exclude'
  ),
  'P0002',
  'document_candidate_not_found',
  'owner B cannot mutate owner A candidate through the RPC'
);
select extensions.lives_ok(
  $sql$
    select public.create_document_source(
      'd1000000-0000-4000-8000-00000000000b',
      'text/plain',
      128,
      repeat('b', 64)
    )
  $sql$,
  'owner B can reserve an independent private source'
);
select extensions.lives_ok(
  $sql$
    insert into storage.objects (bucket_id, name)
    values (
      'schedule-documents',
      'd0222222-2222-4222-8222-222222222222/d1000000-0000-4000-8000-00000000000b/source.txt'
    )
  $sql$,
  'owner B can insert only its own exact reserved object'
);
select extensions.is(
  (
    select count(*) from storage.objects
    where bucket_id = 'schedule-documents'
  ),
  1::bigint,
  'owner B sees its own Storage object and no owner A objects'
);
select extensions.results_eq(
  $sql$
    delete from storage.objects
    where bucket_id = 'schedule-documents'
      and name = 'd0222222-2222-4222-8222-222222222222/d1000000-0000-4000-8000-00000000000b/source.txt'
    returning name
  $sql$,
  $sql$
    values (
      'd0222222-2222-4222-8222-222222222222/d1000000-0000-4000-8000-00000000000b/source.txt'::text
    )
  $sql$,
  'owner B can delete its own active Storage object through the policy'
);

reset role;
set local request.jwt.claims = '{"sub":"d0111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = 'd0111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is(
  (
    select count(*) from storage.objects
    where bucket_id = 'schedule-documents'
      and name = 'd0222222-2222-4222-8222-222222222222/d1000000-0000-4000-8000-00000000000b/source.txt'
  ),
  0::bigint,
  'owner A cannot read owner B private Storage object'
);

select extensions.is(
  (
    public.update_document_candidate(
      (select id from public.document_candidates where candidate_key = 'assignment-b'),
      1,
      null,
      'exclude'
    ) ->> 'review_state'
  ),
  'excluded'::text,
  'an owner can explicitly exclude one proposal'
);
select extensions.is(
  (
    public.update_document_candidate(
      (select id from public.document_candidates where candidate_key = 'assignment-b'),
      1,
      null,
      'exclude'
    ) ->> 'replayed'
  )::boolean,
  true,
  'an exact exclusion retry heals a lost response without another mutation'
);
select extensions.is(
  (
    public.update_document_candidate(
      (select id from public.document_candidates where candidate_key = 'assignment-b'),
      2,
      null,
      'restore'
    ) ->> 'review_state'
  ),
  'needs_review'::text,
  'an excluded proposal can be explicitly restored'
);
select extensions.is(
  (
    public.update_document_candidate(
      (select id from public.document_candidates where candidate_key = 'assignment-a'),
      1,
      pg_temp.document_candidate(
        'assignment-a', 'assignment', '暗号方式比較レポート（編集済み）',
        '2026-08-20T23:59:00+09:00'
      ),
      'edit'
    ) ->> 'version'
  )::bigint,
  2::bigint,
  'an owner can edit a candidate with optimistic version checking'
);
select extensions.is(
  (
    public.update_document_candidate(
      (select id from public.document_candidates where candidate_key = 'assignment-a'),
      1,
      pg_temp.document_candidate(
        'assignment-a', 'assignment', '暗号方式比較レポート（編集済み）',
        '2026-08-20T23:59:00+09:00'
      ),
      'edit'
    ) ->> 'replayed'
  )::boolean,
  true,
  'a lost edit response replays the exact committed postcondition without another version bump'
);
select extensions.is(
  (
    select version from public.document_candidates
    where candidate_key = 'assignment-a'
  ),
  2::bigint,
  'an exact review replay preserves the committed candidate version'
);
select extensions.throws_ok(
  $sql$
    select public.update_document_candidate(
      (select id from public.document_candidates where candidate_key = 'assignment-a'),
      1,
      null,
      'exclude'
    )
  $sql$,
  '40001',
  'document_candidate_version_conflict',
  'stale candidate edits are rejected'
);
select extensions.throws_ok(
  $sql$
    select public.update_document_candidate(
      (select id from public.document_candidates where candidate_key = 'assignment-a'),
      null::bigint,
      null,
      'exclude'
    )
  $sql$,
  '22023',
  'invalid_document_review_version',
  'a null candidate version cannot bypass optimistic review concurrency'
);

select extensions.throws_ok(
  $sql$
    select public.confirm_document_candidate(
      (select id from public.document_candidates where candidate_key = 'assignment-a'),
      null::bigint,
      'd2000000-0000-4000-8000-000000000001',
      'document-confirm-assignment-null-version',
      pg_temp.document_candidate(
        'assignment-a', 'assignment', '暗号方式比較レポート（編集済み）',
        '2026-08-20T23:59:00+09:00'
      ),
      null
    )
  $sql$,
  '22023',
  'invalid_confirmation_request',
  'a null confirmation version cannot bypass optimistic concurrency'
);

select extensions.lives_ok(
  $sql$
    select public.confirm_document_candidate(
      (select id from public.document_candidates where candidate_key = 'assignment-a'),
      2,
      'd2000000-0000-4000-8000-000000000001',
      'document-confirm-assignment-a',
      pg_temp.document_candidate(
        'assignment-a', 'assignment', '暗号方式比較レポート（編集済み）',
        '2026-08-20T23:59:00+09:00'
      ),
      null
    )
  $sql$,
  'explicit confirmation atomically creates the selected assignment'
);
reset role;
select extensions.results_eq(
  $sql$
    select title, visibility_level::text
    from public.assignments
    where id = 'd2000000-0000-4000-8000-000000000001'
  $sql$,
  $sql$
    values ('暗号方式比較レポート（編集済み）'::text, 'PRIVATE'::text)
  $sql$,
  'the confirmed entity is private and contains the reviewed title'
);
set local role authenticated;
select extensions.is(
  (
    select count(*) from public.document_confirmations
    where candidate_id = (
      select id from public.document_candidates where candidate_key = 'assignment-a'
    )
  ),
  1::bigint,
  'confirmation writes one durable idempotency receipt'
);
select extensions.is(
  (
    public.confirm_document_candidate(
      (select id from public.document_candidates where candidate_key = 'assignment-a'),
      2,
      'd2000000-0000-4000-8000-000000000001',
      'document-confirm-assignment-a',
      pg_temp.document_candidate(
        'assignment-a', 'assignment', '暗号方式比較レポート（編集済み）',
        '2026-08-20T23:59:00+09:00'
      ),
      null
    ) ->> 'replayed'
  )::boolean,
  true,
  'the same confirmation idempotency key returns the prior response'
);
reset role;
select extensions.is(
  (
    select count(*) from public.assignments
    where id = 'd2000000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'confirmation replay never duplicates the assignment'
);
set local role authenticated;
select extensions.throws_ok(
  $sql$
    select public.confirm_document_candidate(
      (select id from public.document_candidates where candidate_key = 'assignment-b'),
      3,
      'd2000000-0000-4000-8000-000000000002',
      'document-confirm-assignment-a',
      pg_temp.document_candidate(
        'assignment-b', 'assignment', '認証方式の小課題',
        '2026-08-24T17:00:00+09:00'
      ),
      null
    )
  $sql$,
  '22023',
  'idempotency_key_reused',
  'one idempotency key cannot be reused with a different request'
);

select extensions.results_eq(
  $sql$
    select
      (result ->> 'entity_id')::uuid,
      (result ->> 'deduplicated')::boolean,
      (result ->> 'replayed')::boolean
    from (
      select public.confirm_document_candidate(
        (select id from public.document_candidates where candidate_key = 'exam-a'),
        1,
        'd2000000-0000-4000-8000-0000000000e1',
        'document-confirm-exam-a',
        pg_temp.document_candidate(
          'exam-a', 'exam', '達成度確認', null,
          '2026-08-27T10:35:00+09:00',
          '2026-08-27T12:05:00+09:00'
        ),
        null
      ) result
    ) confirmed
  $sql$,
  $sql$
    values (
      'd2000000-0000-4000-8000-0000000000e1'::uuid,
      false,
      false
    )
  $sql$,
  'explicit confirmation creates the canonical exam before dedupe checks'
);
reset role;
select extensions.results_eq(
  $sql$
    select title, start_at, end_at, room, memo, course_id,
      visibility_level::text, deleted_at
    from public.exams
    where id = 'd2000000-0000-4000-8000-0000000000e1'
  $sql$,
  $sql$
    values (
      '達成度確認'::text,
      '2026-08-27T10:35:00+09:00'::timestamptz,
      '2026-08-27T12:05:00+09:00'::timestamptz,
      null::text,
      'CI用の合成候補'::text,
      null::uuid,
      'PRIVATE'::text,
      null::timestamptz
    )
  $sql$,
  'the canonical exam exactly reflects the reviewed nullable payload fields'
);
set local role authenticated;

select extensions.lives_ok(
  $sql$
    select public.create_document_source(
      'd1000000-0000-4000-8000-000000000002',
      'text/plain',
      1024,
      repeat('c', 64)
    )
  $sql$,
  'owner A can reserve a second synthetic source'
);
select extensions.lives_ok(
  $sql$
    insert into storage.objects (bucket_id, name)
    values (
      'schedule-documents',
      'd0111111-1111-4111-8111-111111111111/d1000000-0000-4000-8000-000000000002/source.txt'
    )
  $sql$,
  'owner A uploads the second source to its reserved Storage path'
);
select extensions.lives_ok(
  $sql$
    select public.mark_document_source_uploaded(
      'd1000000-0000-4000-8000-000000000002'
    )
  $sql$,
  'the second source can be verified as uploaded'
);
select extensions.lives_ok(
  $sql$
    select public.begin_document_processing(
      'd1000000-0000-4000-8000-000000000002'
    )
  $sql$,
  'the second source receives an independent processing claim'
);
select extensions.lives_ok(
  $sql$
    select public.replace_document_candidates(
      'd1000000-0000-4000-8000-000000000002',
      repeat('c', 64),
      3,
      jsonb_build_object(
        'schema_version', '1.0',
        'source_id', 'd1000000-0000-4000-8000-000000000002',
        'content_hash', repeat('c', 64),
        'timezone', 'Asia/Tokyo',
        'candidates', jsonb_build_array(
          pg_temp.document_candidate(
            'assignment-a-copy', 'assignment', '暗号方式比較レポート（編集済み）',
            '2026-08-20T23:59:00+09:00'
          ),
          pg_temp.document_candidate(
            'assignment-a-copy-2', 'assignment', '暗号方式比較レポート（編集済み）',
            '2026-08-20T23:59:00+09:00'
          ),
          pg_temp.document_candidate(
            'assignment-a-course-a', 'assignment', '暗号方式比較レポート（編集済み）',
            '2026-08-20T23:59:00+09:00'
          ),
          pg_temp.document_candidate(
            'assignment-a-course-b', 'assignment', '暗号方式比較レポート（編集済み）',
            '2026-08-20T23:59:00+09:00'
          ),
          pg_temp.document_candidate(
            'assignment-a-after-edit', 'assignment', '暗号方式比較レポート（編集済み）',
            '2026-08-20T23:59:00+09:00'
          ),
          pg_temp.document_candidate(
            'assignment-a-after-delete', 'assignment', '暗号方式比較レポート（編集済み）',
            '2026-08-20T23:59:00+09:00'
          ),
          pg_temp.document_candidate(
            'exam-a-copy', 'exam', '達成度確認', null,
            '2026-08-27T10:35:00+09:00',
            '2026-08-27T12:05:00+09:00'
          ),
          pg_temp.document_candidate(
            'exam-a-after-delete', 'exam', '達成度確認', null,
            '2026-08-27T10:35:00+09:00',
            '2026-08-27T12:05:00+09:00'
          )
        )
      )
    )
  $sql$,
  'same-source duplicate mentions are all persisted with their own provenance'
);
select extensions.results_eq(
  $sql$
    select count(*), count(distinct semantic_fingerprint)
    from public.document_candidates
    where source_id = 'd1000000-0000-4000-8000-000000000002'
  $sql$,
  $sql$ values (8::bigint, 2::bigint) $sql$,
  'assignment and exam reimport fixtures retain provenance and type-specific fingerprints'
);
select extensions.is(
  (
    public.confirm_document_candidate(
      (select id from public.document_candidates where candidate_key = 'assignment-a-copy'),
      1,
      'd2000000-0000-4000-8000-000000000099',
      'document-confirm-assignment-copy',
      pg_temp.document_candidate(
        'assignment-a-copy', 'assignment', '暗号方式比較レポート（編集済み）',
        '2026-08-20T23:59:00+09:00'
      ),
      null
    ) ->> 'deduplicated'
  )::boolean,
  true,
  'a cross-document semantic duplicate links to the existing entity'
);
select extensions.is(
  (
    public.confirm_document_candidate(
      (select id from public.document_candidates where candidate_key = 'assignment-a-copy-2'),
      1,
      'd2000000-0000-4000-8000-000000000098',
      'document-confirm-assignment-copy-2',
      pg_temp.document_candidate(
        'assignment-a-copy-2', 'assignment', '暗号方式比較レポート（編集済み）',
        '2026-08-20T23:59:00+09:00'
      ),
      null
    ) ->> 'deduplicated'
  )::boolean,
  true,
  'same payload and same null course dedupe to one canonical entity'
);
reset role;
select extensions.is(
  (
    select count(*) from public.assignments
    where owner_user_id = 'd0111111-1111-4111-8111-111111111111'
      and title = '暗号方式比較レポート（編集済み）'
  ),
  1::bigint,
  'cross-document confirmation does not duplicate the schedule entity'
);
set local role authenticated;
select extensions.is(
  (
    select count(*)
    from public.document_candidates
    where candidate_key in ('assignment-a-copy', 'assignment-a-copy-2')
      and linked_entity_id = 'd2000000-0000-4000-8000-000000000001'
  ),
  2::bigint,
  'both duplicate candidates retain provenance links to the canonical entity'
);
select extensions.is(
  (
    public.confirm_document_candidate(
      (select id from public.document_candidates where candidate_key = 'assignment-a-course-a'),
      1,
      'd2000000-0000-4000-8000-0000000000a1',
      'document-confirm-assignment-course-a',
      pg_temp.document_candidate(
        'assignment-a-course-a', 'assignment', '暗号方式比較レポート（編集済み）',
        '2026-08-20T23:59:00+09:00'
      ),
      'd3000000-0000-4000-8000-000000000001'
    ) ->> 'deduplicated'
  )::boolean,
  false,
  'the same payload confirmed for course A creates a course-specific entity'
);
select extensions.is(
  (
    public.confirm_document_candidate(
      (select id from public.document_candidates where candidate_key = 'assignment-a-course-b'),
      1,
      'd2000000-0000-4000-8000-0000000000a2',
      'document-confirm-assignment-course-b',
      pg_temp.document_candidate(
        'assignment-a-course-b', 'assignment', '暗号方式比較レポート（編集済み）',
        '2026-08-20T23:59:00+09:00'
      ),
      'd3000000-0000-4000-8000-000000000002'
    ) ->> 'deduplicated'
  )::boolean,
  false,
  'the same payload confirmed for course B does not reuse course A'
);
reset role;
select extensions.results_eq(
  $sql$
    select course_id, count(*)
    from public.assignments
    where owner_user_id = 'd0111111-1111-4111-8111-111111111111'
      and title = '暗号方式比較レポート（編集済み）'
    group by course_id
    order by course_id nulls first
  $sql$,
  $sql$
    values
      (null::uuid, 1::bigint),
      ('d3000000-0000-4000-8000-000000000001'::uuid, 1::bigint),
      ('d3000000-0000-4000-8000-000000000002'::uuid, 1::bigint)
  $sql$,
  'confirmation dedupe includes the explicit course while retaining same-course provenance'
);
set local role authenticated;

select extensions.results_eq(
  $sql$
    select
      (result ->> 'entity_id')::uuid,
      (result ->> 'deduplicated')::boolean,
      (result ->> 'replayed')::boolean
    from (
      select public.confirm_document_candidate(
        (select id from public.document_candidates where candidate_key = 'exam-a-copy'),
        1,
        'd2000000-0000-4000-8000-0000000000ef',
        'document-confirm-exam-a-copy',
        pg_temp.document_candidate(
          'exam-a-copy', 'exam', '達成度確認', null,
          '2026-08-27T10:35:00+09:00',
          '2026-08-27T12:05:00+09:00'
        ),
        null
      ) result
    ) confirmed
  $sql$,
  $sql$
    values (
      'd2000000-0000-4000-8000-0000000000e1'::uuid,
      true,
      true
    )
  $sql$,
  'an exact exam with NULL course and room reuses the live canonical entity'
);

reset role;
update public.assignments
set description = 'ユーザーが追記した内容',
    visibility_level = 'FULL'
where id = 'd2000000-0000-4000-8000-000000000001';
set local role authenticated;

select extensions.results_eq(
  $sql$
    select
      (result ->> 'entity_id')::uuid,
      (result ->> 'deduplicated')::boolean,
      (result ->> 'replayed')::boolean
    from (
      select public.confirm_document_candidate(
        (select id from public.document_candidates
         where candidate_key = 'assignment-a-after-edit'),
        1,
        'd2000000-0000-4000-8000-000000000097',
        'document-confirm-assignment-after-edit',
        pg_temp.document_candidate(
          'assignment-a-after-edit', 'assignment', '暗号方式比較レポート（編集済み）',
          '2026-08-20T23:59:00+09:00'
        ),
        null
      ) result
    ) confirmed
  $sql$,
  $sql$
    values (
      'd2000000-0000-4000-8000-000000000097'::uuid,
      false,
      false
    )
  $sql$,
  'an edited canonical assignment is not reused for an exact payload reimport'
);

reset role;
select extensions.results_eq(
  $sql$
    select id, description, visibility_level::text, deleted_at is not null
    from public.assignments
    where id in (
      'd2000000-0000-4000-8000-000000000001',
      'd2000000-0000-4000-8000-000000000097'
    )
    order by id
  $sql$,
  $sql$
    values
      (
        'd2000000-0000-4000-8000-000000000001'::uuid,
        'ユーザーが追記した内容'::text,
        'FULL'::text,
        false
      ),
      (
        'd2000000-0000-4000-8000-000000000097'::uuid,
        'CI用の合成候補'::text,
        'PRIVATE'::text,
        false
      )
  $sql$,
  'the edited assignment is preserved while p_entity_id becomes a fresh canonical row'
);
set local role authenticated;
select extensions.results_eq(
  $sql$
    select candidate_key, linked_entity_id
    from public.document_candidates
    where candidate_key in (
      'assignment-a',
      'assignment-a-copy',
      'assignment-a-copy-2',
      'assignment-a-after-edit'
    )
    order by candidate_key
  $sql$,
  $sql$
    values
      (
        'assignment-a'::text,
        'd2000000-0000-4000-8000-000000000001'::uuid
      ),
      (
        'assignment-a-after-edit'::text,
        'd2000000-0000-4000-8000-000000000097'::uuid
      ),
      (
        'assignment-a-copy'::text,
        'd2000000-0000-4000-8000-000000000001'::uuid
      ),
      (
        'assignment-a-copy-2'::text,
        'd2000000-0000-4000-8000-000000000001'::uuid
      )
  $sql$,
  'edited-canonical reimport preserves every prior and new confirmation provenance link'
);
select extensions.results_eq(
  $sql$
    select
      (result ->> 'entity_id')::uuid,
      (result ->> 'deduplicated')::boolean,
      (result ->> 'replayed')::boolean
    from (
      select public.confirm_document_candidate(
        (select id from public.document_candidates
         where candidate_key = 'assignment-a-after-edit'),
        1,
        'd2000000-0000-4000-8000-000000000097',
        'document-confirm-assignment-after-edit',
        pg_temp.document_candidate(
          'assignment-a-after-edit', 'assignment', '暗号方式比較レポート（編集済み）',
          '2026-08-20T23:59:00+09:00'
        ),
        null
      ) result
    ) replayed
  $sql$,
  $sql$
    values (
      'd2000000-0000-4000-8000-000000000097'::uuid,
      false,
      true
    )
  $sql$,
  'edited-canonical reimport remains exactly idempotent after the fresh receipt commits'
);
select extensions.throws_ok(
  $sql$
    select public.confirm_document_candidate(
      (select id from public.document_candidates
       where candidate_key = 'assignment-a-after-edit'),
      1,
      'd2000000-0000-4000-8000-000000000095',
      'document-confirm-assignment-after-edit',
      pg_temp.document_candidate(
        'assignment-a-after-edit', 'assignment', '暗号方式比較レポート（編集済み）',
        '2026-08-20T23:59:00+09:00'
      ),
      null
    )
  $sql$,
  '22023',
  'idempotency_key_reused',
  'the fresh receipt still rejects a conflicting p_entity_id for the same key'
);

reset role;
update public.assignments
set deleted_at = clock_timestamp()
where id = 'd2000000-0000-4000-8000-000000000097';
set local role authenticated;
select extensions.results_eq(
  $sql$
    select
      (result ->> 'entity_id')::uuid,
      (result ->> 'deduplicated')::boolean
    from (
      select public.confirm_document_candidate(
        (select id from public.document_candidates
         where candidate_key = 'assignment-a-after-delete'),
        1,
        'd2000000-0000-4000-8000-000000000096',
        'document-confirm-assignment-after-delete',
        pg_temp.document_candidate(
          'assignment-a-after-delete', 'assignment', '暗号方式比較レポート（編集済み）',
          '2026-08-20T23:59:00+09:00'
        ),
        null
      ) result
    ) confirmed
  $sql$,
  $sql$
    values ('d2000000-0000-4000-8000-000000000096'::uuid, false)
  $sql$,
  'a soft-deleted assignment receipt is skipped and p_entity_id is created'
);
reset role;
select extensions.results_eq(
  $sql$
    select id, deleted_at is not null
    from public.assignments
    where id in (
      'd2000000-0000-4000-8000-000000000096',
      'd2000000-0000-4000-8000-000000000097'
    )
    order by id
  $sql$,
  $sql$
    values
      ('d2000000-0000-4000-8000-000000000096'::uuid, false),
      ('d2000000-0000-4000-8000-000000000097'::uuid, true)
  $sql$,
  'soft-deleted assignment provenance remains while the replacement is live'
);

update public.exams
set deleted_at = clock_timestamp()
where id = 'd2000000-0000-4000-8000-0000000000e1';
set local role authenticated;
select extensions.results_eq(
  $sql$
    select
      (result ->> 'entity_id')::uuid,
      (result ->> 'deduplicated')::boolean
    from (
      select public.confirm_document_candidate(
        (select id from public.document_candidates
         where candidate_key = 'exam-a-after-delete'),
        1,
        'd2000000-0000-4000-8000-0000000000e2',
        'document-confirm-exam-after-delete',
        pg_temp.document_candidate(
          'exam-a-after-delete', 'exam', '達成度確認', null,
          '2026-08-27T10:35:00+09:00',
          '2026-08-27T12:05:00+09:00'
        ),
        null
      ) result
    ) confirmed
  $sql$,
  $sql$
    values ('d2000000-0000-4000-8000-0000000000e2'::uuid, false)
  $sql$,
  'a soft-deleted exam receipt is skipped and p_entity_id is created'
);
reset role;
select extensions.results_eq(
  $sql$
    select exam.id, exam.deleted_at is not null, count(candidate.id)
    from public.exams exam
    join public.document_candidates candidate
      on candidate.linked_entity_type = 'exam'
     and candidate.linked_entity_id = exam.id
    where exam.id in (
      'd2000000-0000-4000-8000-0000000000e1',
      'd2000000-0000-4000-8000-0000000000e2'
    )
    group by exam.id, exam.deleted_at
    order by exam.id
  $sql$,
  $sql$
    values
      ('d2000000-0000-4000-8000-0000000000e1'::uuid, true, 2::bigint),
      ('d2000000-0000-4000-8000-0000000000e2'::uuid, false, 1::bigint)
  $sql$,
  'exam soft-delete reimport retains confirmed provenance for both entities'
);
set local role authenticated;

select extensions.lives_ok(
  $sql$
    select public.create_document_source(
      'd1000000-0000-4000-8000-000000000003',
      'text/plain',
      256,
      repeat('d', 64)
    )
  $sql$,
  'owner A can reserve a source for retry and retention lifecycle checks'
);
select extensions.lives_ok(
  $sql$
    insert into storage.objects (bucket_id, name)
    values (
      'schedule-documents',
      'd0111111-1111-4111-8111-111111111111/d1000000-0000-4000-8000-000000000003/source.txt'
    )
  $sql$,
  'the retry fixture has a private Storage object'
);
select extensions.lives_ok(
  $sql$
    select public.mark_document_source_uploaded(
      'd1000000-0000-4000-8000-000000000003'
    )
  $sql$,
  'the retry fixture advances to uploaded'
);
select extensions.lives_ok(
  $sql$
    select public.begin_document_processing(
      'd1000000-0000-4000-8000-000000000003'
    )
  $sql$,
  'the retry fixture receives its first processing claim'
);
select extensions.throws_ok(
  $sql$
    select public.fail_document_processing(
      'd1000000-0000-4000-8000-000000000003', null::bigint, 'timeout', 60
    )
  $sql$,
  '22023',
  'invalid_document_failure',
  'a null processing version cannot bypass the claimed attempt token'
);
select extensions.throws_ok(
  $sql$
    select public.fail_document_processing(
      'd1000000-0000-4000-8000-000000000003', 3, null, 60
    )
  $sql$,
  '22023',
  'invalid_document_failure',
  'a failure transition requires an exact bounded error category'
);
select extensions.is(
  (
    public.fail_document_processing(
      'd1000000-0000-4000-8000-000000000003', 3, 'timeout', 60
    ) ->> 'processing_state'
  ),
  'failed'::text,
  'a version-matched retryable failure is recorded atomically'
);
select extensions.results_eq(
  $sql$
    select processing_attempt_count, error_category,
      retry_after_at > clock_timestamp(), version
    from public.document_sources
    where id = 'd1000000-0000-4000-8000-000000000003'
  $sql$,
  $sql$ values (1, 'timeout'::text, true, 4::bigint) $sql$,
  'failure state retains the attempt count and bounded retry timestamp'
);
select extensions.throws_ok(
  $sql$
    select public.begin_document_processing(
      'd1000000-0000-4000-8000-000000000003'
    )
  $sql$,
  'P0001',
  'document_retry_delayed',
  'retry-after prevents immediate duplicate provider work'
);

reset role;
update public.document_sources
set retry_after_at = clock_timestamp() - interval '1 second'
where id = 'd1000000-0000-4000-8000-000000000003';
set local request.jwt.claims = '{"sub":"d0111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = 'd0111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.results_eq(
  $sql$
    select
      (result ->> 'attempt_count')::integer,
      (result ->> 'version')::bigint
    from (
      select public.begin_document_processing(
        'd1000000-0000-4000-8000-000000000003'
      ) result
    ) claimed
  $sql$,
  $sql$ values (2, 6::bigint) $sql$,
  'an eligible retry clears failure metadata and increments the attempt token'
);
select extensions.is(
  (
    public.fail_document_processing(
      'd1000000-0000-4000-8000-000000000003', 6, 'unsafe_content', null
    ) ->> 'error_category'
  ),
  'unsafe_content'::text,
  'a non-retryable failure is recorded without a retry delay'
);
select extensions.results_eq(
  $sql$
    select processing_state, processing_attempt_count,
      error_category, retry_after_at is null
    from public.document_sources
    where id = 'd1000000-0000-4000-8000-000000000003'
  $sql$,
  $sql$ values ('failed'::text, 2, 'unsafe_content'::text, true) $sql$,
  'non-retryable state remains internally consistent'
);

reset role;
update public.document_sources
set created_at = clock_timestamp() - interval '40 days',
    retention_expires_at = clock_timestamp() - interval '1 second'
where id = 'd1000000-0000-4000-8000-000000000003';
set local request.jwt.claims = '{"sub":"d0111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = 'd0111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is(
  (
    select count(*) from public.document_sources
    where id = 'd1000000-0000-4000-8000-000000000003'
  ),
  0::bigint,
  'an expired source is no longer visible through the owner RLS projection'
);
select extensions.lives_ok(
  $sql$
    insert into document_reimport_results (lifecycle, source_id, storage_path)
    select
      'expired',
      (result ->> 'source_id')::uuid,
      result ->> 'storage_path'
    from (
      select public.create_document_source(
        'd1000000-0000-4000-8000-000000000003',
        'text/plain',
        256,
        repeat('d', 64)
      ) result
    ) created
  $sql$,
  'the same bytes can be reserved again after retention expiry'
);
select extensions.isnt(
  (
    select source_id from document_reimport_results
    where lifecycle = 'expired'
  ),
  'd1000000-0000-4000-8000-000000000003'::uuid,
  'expiry reimport rotates the tombstoned caller UUID instead of reusing provenance'
);
select extensions.is(
  (
    select count(*) from public.document_sources
    where id = (
      select source_id from document_reimport_results where lifecycle = 'expired'
    )
      and content_hash = repeat('d', 64)
      and processing_state = 'pending_upload'
  ),
  1::bigint,
  'the owner sees exactly one fresh active source for the reimported bytes'
);
select extensions.lives_ok(
  $sql$
    insert into storage.objects (bucket_id, name)
    select 'schedule-documents', storage_path
    from document_reimport_results
    where lifecycle = 'expired'
  $sql$,
  'the rotated retention reimport accepts its newly reserved private object'
);
select extensions.lives_ok(
  $sql$
    select public.mark_document_source_uploaded(
      (select source_id from document_reimport_results where lifecycle = 'expired')
    )
  $sql$,
  'the rotated retention source advances to uploaded'
);
select extensions.lives_ok(
  $sql$
    select public.begin_document_processing(
      (select source_id from document_reimport_results where lifecycle = 'expired')
    )
  $sql$,
  'the rotated retention source receives an independent processing claim'
);
select extensions.lives_ok(
  $sql$
    select public.replace_document_candidates(
      (select source_id from document_reimport_results where lifecycle = 'expired'),
      repeat('d', 64),
      3,
      pg_temp.document_batch(
        (select source_id from document_reimport_results where lifecycle = 'expired'),
        repeat('d', 64),
        jsonb_build_array(pg_temp.document_candidate(
          'retention-reimport-assignment',
          'assignment',
          '保存期間後の再取込課題',
          '2026-09-01T12:00:00+09:00'
        ))
      )
    )
  $sql$,
  'a retention reimport creates a fresh independently reviewable candidate'
);
select extensions.is(
  (
    select count(*) from public.document_candidates
    where source_id = (
      select source_id from document_reimport_results where lifecycle = 'expired'
    )
  ),
  1::bigint,
  'the fresh retention candidate is visible without exposing the tombstoned row'
);

select extensions.is(
  (
    select count(*) from storage.objects
    where bucket_id = 'schedule-documents'
      and name = 'd0111111-1111-4111-8111-111111111111/d1000000-0000-4000-8000-000000000003/source.txt'
  ),
  0::bigint,
  'private Storage reads close exactly at retention expiry'
);

reset role;
set local request.jwt.claims = '{"role":"service_role"}';
set local request.jwt.claim.role = 'service_role';
set local role service_role;

select extensions.results_eq(
  $sql$
    select source_id, storage_path
    from public.claim_expired_document_sources(10)
  $sql$,
  $sql$
    values (
      'd1000000-0000-4000-8000-000000000003'::uuid,
      'd0111111-1111-4111-8111-111111111111/d1000000-0000-4000-8000-000000000003/source.txt'::text
    )
  $sql$,
  'the service worker claims the expired DB row and receives its Storage path'
);
select extensions.results_eq(
  $sql$
    select processing_state, error_category, retry_after_at, deleted_at is not null
    from public.document_sources
    where id = 'd1000000-0000-4000-8000-000000000003'
  $sql$,
  $sql$ values ('deleted'::text, null::text, null::timestamptz, true) $sql$,
  'retention claim clears extraction errors before closing DB visibility'
);
select extensions.results_eq(
  $sql$
    select source_id, storage_path
    from public.claim_expired_document_sources(10)
  $sql$,
  $sql$
    values (
      'd1000000-0000-4000-8000-000000000003'::uuid,
      'd0111111-1111-4111-8111-111111111111/d1000000-0000-4000-8000-000000000003/source.txt'::text
    )
  $sql$,
  'an expired object remains claimable until the Storage worker deletes it'
);
select extensions.lives_ok(
  $sql$
    delete from storage.objects
    where bucket_id = 'schedule-documents'
      and name = 'd0111111-1111-4111-8111-111111111111/d1000000-0000-4000-8000-000000000003/source.txt'
  $sql$,
  'the test simulates successful idempotent Storage API worker deletion'
);
select extensions.is_empty(
  $sql$
    select source_id, storage_path
    from public.claim_expired_document_sources(10)
  $sql$,
  'a cleaned Storage path leaves the retention retry queue'
);

reset role;
set local request.jwt.claims = '{"sub":"d0111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = 'd0111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.is(
  (
    public.delete_document_source(
      'd1000000-0000-4000-8000-000000000001'
    ) ->> 'schedule_entities_retained'
  )::boolean,
  true,
  'source deletion explicitly reports that confirmed entities are retained'
);
reset role;
select extensions.is(
  (
    select count(*) from public.assignments
    where id = 'd2000000-0000-4000-8000-000000000001'
  ),
  1::bigint,
  'deleting source metadata never cascades into the user-created assignment'
);
set local role authenticated;
select extensions.is(
  (
    select count(*) from public.document_sources
    where id = 'd1000000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'source deletion closes owner metadata reads through RLS'
);
select extensions.is(
  (
    select count(*) from public.document_candidates
    where source_id = 'd1000000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'source deletion closes owner reads of every derived candidate payload'
);
select extensions.ok(
  exists (
    select 1 from public.document_confirmations
    where source_id = 'd1000000-0000-4000-8000-000000000001'
  ),
  'confirmed receipts remain owner-readable after source and candidate deletion'
);
select extensions.is(
  (
    select count(*) from storage.objects
    where bucket_id = 'schedule-documents'
      and name = 'd0111111-1111-4111-8111-111111111111/d1000000-0000-4000-8000-000000000001/source.pdf'
  ),
  0::bigint,
  'soft deletion immediately closes owner reads while cleanup is queued'
);
reset role;
select extensions.results_eq(
  $sql$
    select processing_state, deleted_at is not null,
      retention_expires_at <= clock_timestamp()
    from public.document_sources
    where id = 'd1000000-0000-4000-8000-000000000001'
  $sql$,
  $sql$ values ('deleted'::text, true, true) $sql$,
  'trusted inspection retains the tombstone and immediate cleanup deadline'
);
select extensions.ok(
  (
    select bool_and(retention_expires_at > created_at)
    from public.document_sources
  ),
  'every source records a bounded retention expiry'
);
select extensions.is(
  (
    select count(*) from public.document_candidates
    where source_id = 'd1000000-0000-4000-8000-000000000001'
      and deleted_at is not null
  ),
  4::bigint,
  'source deletion marks every cached proposal deleted without erasing receipts'
);
set local role authenticated;
select extensions.lives_ok(
  $sql$
    insert into document_reimport_results (lifecycle, source_id, storage_path)
    select
      'explicit-delete',
      (result ->> 'source_id')::uuid,
      result ->> 'storage_path'
    from (
      select public.create_document_source(
        'd1000000-0000-4000-8000-000000000001',
        'application/pdf',
        4096,
        repeat('a', 64)
      ) result
    ) created
  $sql$,
  'the same bytes can be reserved again after explicit source deletion'
);
select extensions.isnt(
  (
    select source_id from document_reimport_results
    where lifecycle = 'explicit-delete'
  ),
  'd1000000-0000-4000-8000-000000000001'::uuid,
  'explicit deletion rotates the tombstoned source UUID'
);
select extensions.is(
  (
    select count(*) from public.document_sources
    where id = (
      select source_id from document_reimport_results
      where lifecycle = 'explicit-delete'
    )
      and content_hash = repeat('a', 64)
      and processing_state = 'pending_upload'
  ),
  1::bigint,
  'the owner sees the fresh post-deletion source while the old provenance stays hidden'
);

select * from extensions.finish();
rollback;
