begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(39);

select extensions.has_table(
  'private',
  'document_storage_delete_queue',
  'hard-deleted document Storage paths have a durable private queue'
);
select extensions.ok(
  (
    select c.relrowsecurity
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'private'
      and c.relname = 'document_storage_delete_queue'
  ),
  'the private cleanup queue has defense-in-depth RLS enabled'
);
select extensions.is(
  (
    select count(*)
    from pg_catalog.pg_policy p
    join pg_catalog.pg_class c on c.oid = p.polrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'private'
      and c.relname = 'document_storage_delete_queue'
  ),
  0::bigint,
  'the private cleanup queue exposes no row policy to clients'
);
select extensions.ok(
  exists (
    select 1
    from pg_catalog.pg_trigger trigger_definition
    join pg_catalog.pg_class table_definition
      on table_definition.oid = trigger_definition.tgrelid
    join pg_catalog.pg_namespace namespace_definition
      on namespace_definition.oid = table_definition.relnamespace
    where namespace_definition.nspname = 'public'
      and table_definition.relname = 'document_sources'
      and trigger_definition.tgname = 'document_sources_queue_storage_delete'
      and not trigger_definition.tgisinternal
      and (trigger_definition.tgtype & 2) = 2
      and (trigger_definition.tgtype & 8) = 8
  ),
  'document source hard deletion queues Storage work before the row disappears'
);
select extensions.ok(
  exists (
    select 1
    from pg_catalog.pg_proc function_definition
    join pg_catalog.pg_namespace namespace_definition
      on namespace_definition.oid = function_definition.pronamespace
    where namespace_definition.nspname = 'private'
      and function_definition.proname = 'queue_document_storage_delete'
      and function_definition.prosecdef
  ),
  'the Auth cascade trigger uses a private security-definer function'
);
select extensions.ok(
  (
    select bool_and(
      not pg_catalog.has_table_privilege(
        role_name,
        'private.document_storage_delete_queue',
        privilege_name
      )
    )
    from unnest(array['anon', 'authenticated', 'service_role']) role_name
    cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) privilege_name
  ),
  'anon, authenticated, and service roles have no direct queue privileges'
);
select extensions.is_empty(
  $sql$
    select attribute_definition.attname
    from pg_catalog.pg_attribute attribute_definition
    join pg_catalog.pg_class table_definition
      on table_definition.oid = attribute_definition.attrelid
    join pg_catalog.pg_namespace namespace_definition
      on namespace_definition.oid = table_definition.relnamespace
    where namespace_definition.nspname = 'private'
      and table_definition.relname = 'document_storage_delete_queue'
      and attribute_definition.attnum > 0
      and not attribute_definition.attisdropped
      and attribute_definition.attname ~* '(^|_)(raw|bytes|body|file_name|api_key|token)($|_)'
  $sql$,
  'the durable queue contains no document bytes, filename, token, or API key'
);
select extensions.ok(
  not pg_catalog.has_function_privilege(
    'anon', 'public.claim_expired_document_sources(integer)', 'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated',
    'public.claim_expired_document_sources(integer)',
    'EXECUTE'
  )
  and pg_catalog.has_function_privilege(
    'service_role',
    'public.claim_expired_document_sources(integer)',
    'EXECUTE'
  ),
  'only the trusted service role can claim queued or expired paths'
);

insert into auth.users (id)
values
  ('da111111-1111-4111-8111-111111111111'),
  ('db222222-2222-4222-8222-222222222222'),
  ('dc333333-3333-4333-8333-333333333333');

set local request.jwt.claims =
  '{"sub":"da111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = 'da111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.lives_ok(
  $sql$
    select public.create_document_source(
      'da100000-0000-4000-8000-000000000001',
      'application/pdf',
      1024,
      repeat('a', 64)
    )
  $sql$,
  'account owner reserves a private source before upload'
);
select extensions.lives_ok(
  $sql$
    insert into storage.objects (bucket_id, name, owner_id)
    values (
      'schedule-documents',
      'da111111-1111-4111-8111-111111111111/da100000-0000-4000-8000-000000000001/source.pdf',
      'da111111-1111-4111-8111-111111111111'
    )
  $sql$,
  'account owner uploads an owner-attributed private Storage object'
);

reset role;
insert into public.document_candidates (
  id,
  owner_user_id,
  source_id,
  candidate_key,
  candidate_type,
  validated_payload,
  semantic_fingerprint
) values (
  'da300000-0000-4000-8000-000000000003',
  'da111111-1111-4111-8111-111111111111',
  'da100000-0000-4000-8000-000000000001',
  'account-delete-candidate',
  'assignment',
  '{}'::jsonb,
  repeat('c', 64)
);

set local request.jwt.claims =
  '{"sub":"db222222-2222-4222-8222-222222222222","role":"authenticated"}';
set local request.jwt.claim.sub = 'db222222-2222-4222-8222-222222222222';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.lives_ok(
  $sql$
    select public.create_document_source(
      'db200000-0000-4000-8000-000000000002',
      'text/plain',
      256,
      repeat('b', 64)
    )
  $sql$,
  'a second owner reserves an independent retention source'
);
select extensions.lives_ok(
  $sql$
    insert into storage.objects (bucket_id, name, owner_id)
    values (
      'schedule-documents',
      'db222222-2222-4222-8222-222222222222/db200000-0000-4000-8000-000000000002/source.txt',
      'db222222-2222-4222-8222-222222222222'
    )
  $sql$,
  'the second owner uploads only the independently reserved path'
);

reset role;
update public.document_sources
set created_at = clock_timestamp() - interval '40 days',
    retention_expires_at = clock_timestamp() - interval '1 second'
where id = 'db200000-0000-4000-8000-000000000002';

select extensions.lives_ok(
  $sql$
    delete from auth.users
    where id = 'da111111-1111-4111-8111-111111111111'
  $sql$,
  'database Auth deletion can cascade document metadata without losing cleanup work'
);
select extensions.is(
  (
    select count(*)
    from auth.users
    where id = 'da111111-1111-4111-8111-111111111111'
  ),
  0::bigint,
  'the Auth account row is deleted'
);
select extensions.is(
  (
    select count(*)
    from public.document_sources
    where id = 'da100000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'the account cascade removes the source metadata row'
);
select extensions.is(
  (
    select count(*)
    from public.document_candidates
    where id = 'da300000-0000-4000-8000-000000000003'
  ),
  0::bigint,
  'the same account cascade removes derived candidate metadata'
);
select extensions.is(
  (
    select count(*)
    from storage.objects
    where bucket_id = 'schedule-documents'
      and name = 'da111111-1111-4111-8111-111111111111/da100000-0000-4000-8000-000000000001/source.pdf'
      and owner_id = 'da111111-1111-4111-8111-111111111111'
  ),
  1::bigint,
  'the Auth database cascade does not itself delete the underlying Storage object'
);

-- A client-supplied source UUID is only a retry correlation value. If its old
-- path is still queued, a new reservation with the same media type must rotate
-- to a fresh authoritative UUID/path instead of adopting the old object bytes.
set local request.jwt.claims =
  '{"sub":"dc333333-3333-4333-8333-333333333333","role":"authenticated"}';
set local request.jwt.claim.sub = 'dc333333-3333-4333-8333-333333333333';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.lives_ok(
  $sql$
    select public.create_document_source(
      'dc300000-0000-4000-8000-000000000003',
      'application/pdf',
      3072,
      repeat('d', 64)
    )
  $sql$,
  'a third live owner reserves the source UUID used by the queue-key regression'
);
select extensions.lives_ok(
  $sql$
    insert into storage.objects (bucket_id, name, owner_id)
    values (
      'schedule-documents',
      'dc333333-3333-4333-8333-333333333333/dc300000-0000-4000-8000-000000000003/source.pdf',
      'dc333333-3333-4333-8333-333333333333'
    )
  $sql$,
  'the third owner uploads the first independently deletable Storage object'
);

reset role;
select extensions.lives_ok(
  $sql$
    delete from public.document_sources
    where id = 'dc300000-0000-4000-8000-000000000003'
  $sql$,
  'hard-deleting the first third-owner source queues its PDF path'
);

set local request.jwt.claims =
  '{"sub":"dc333333-3333-4333-8333-333333333333","role":"authenticated"}';
set local request.jwt.claim.sub = 'dc333333-3333-4333-8333-333333333333';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select extensions.results_eq(
  $sql$
    select
      (created.response ->> 'source_id')::uuid <>
        'dc300000-0000-4000-8000-000000000003'::uuid,
      created.response ->> 'storage_path' <>
        'dc333333-3333-4333-8333-333333333333/dc300000-0000-4000-8000-000000000003/source.pdf',
      created.response ->> 'storage_path' =
        'dc333333-3333-4333-8333-333333333333/' ||
        (created.response ->> 'source_id') || '/source.pdf',
      created.response ->> 'processing_state',
      (created.response ->> 'replayed')::boolean
    from (
      select public.create_document_source(
        'dc300000-0000-4000-8000-000000000003',
        'application/pdf',
        2048,
        repeat('e', 64)
      ) as response
    ) created
  $sql$,
  $sql$ values (true, true, true, 'pending_upload'::text, false) $sql$,
  'a queued caller UUID rotates to a fresh authoritative UUID and PDF path'
);

select extensions.throws_ok(
  $sql$
    select public.mark_document_source_uploaded((
      select source.id
      from public.document_sources source
      where source.owner_user_id =
          'dc333333-3333-4333-8333-333333333333'::uuid
        and source.content_hash = repeat('e', 64)
        and source.deleted_at is null
    ))
  $sql$,
  'P0002',
  'document_object_not_found',
  'the rotated source cannot adopt bytes stored at the old queued path'
);

insert into storage.objects (bucket_id, name, owner_id)
select
  'schedule-documents',
  source.storage_path,
  source.owner_user_id
from public.document_sources source
where source.owner_user_id = 'dc333333-3333-4333-8333-333333333333'
  and source.content_hash = repeat('e', 64)
  and source.deleted_at is null;

reset role;
select extensions.lives_ok(
  $sql$
    delete from public.document_sources
    where owner_user_id = 'dc333333-3333-4333-8333-333333333333'
      and content_hash = repeat('e', 64)
  $sql$,
  'hard-deleting the rotated source queues its independent PDF path'
);
select extensions.results_eq(
  $sql$
    select
      count(*)::bigint,
      count(*) filter (
        where source_id = 'dc300000-0000-4000-8000-000000000003'
          and storage_path =
            'dc333333-3333-4333-8333-333333333333/dc300000-0000-4000-8000-000000000003/source.pdf'
      )::bigint,
      count(*) filter (
        where source_id <> 'dc300000-0000-4000-8000-000000000003'
          and storage_path =
            'dc333333-3333-4333-8333-333333333333/' ||
            source_id::text || '/source.pdf'
      )::bigint,
      count(distinct source_id)::bigint,
      count(distinct storage_path)::bigint
    from private.document_storage_delete_queue
    where storage_path like
      'dc333333-3333-4333-8333-333333333333/%'
  $sql$,
  $sql$ values (2::bigint, 1::bigint, 1::bigint, 2::bigint, 2::bigint) $sql$,
  'the old and rotated source paths remain independently queued'
);

insert into private.document_storage_delete_queue (
  source_id,
  storage_path,
  queued_at
) values
  (
    'dd400000-0000-4000-8000-000000000004',
    'dd444444-4444-4444-8444-444444444444/dd400000-0000-4000-8000-000000000004/source.pdf',
    clock_timestamp() - interval '2 seconds'
  ),
  (
    'de500000-0000-4000-8000-000000000005',
    'de555555-5555-4555-8555-555555555555/de500000-0000-4000-8000-000000000005/source.pdf',
    clock_timestamp() - interval '1 second'
  );

set local request.jwt.claims = '{"role":"service_role"}';
set local request.jwt.claim.role = 'service_role';
set local role service_role;

select extensions.results_eq(
  $sql$
    select source_id, storage_path
    from public.claim_expired_document_sources(1)
  $sql$,
  $sql$
    values (
      'da100000-0000-4000-8000-000000000001'::uuid,
      'da111111-1111-4111-8111-111111111111/da100000-0000-4000-8000-000000000001/source.pdf'::text
    )
  $sql$,
  'one total claim returns the hard-delete queue before other expired rows'
);
reset role;
select extensions.is(
  (
    select count(*)
    from private.document_storage_delete_queue
    where source_id in (
      'dd400000-0000-4000-8000-000000000004',
      'de500000-0000-4000-8000-000000000005'
    )
  ),
  1::bigint,
  'p_limit one retires at most one stale queue entry in the same bounded claim'
);
select extensions.is(
  (
    select processing_state
    from public.document_sources
    where id = 'db200000-0000-4000-8000-000000000002'
  ),
  'pending_upload'::text,
  'the same p_limit is not applied independently to the expired-row branch'
);

set local storage.allow_delete_query = 'true';
select extensions.lives_ok(
  $sql$
    delete from storage.objects
    where bucket_id = 'schedule-documents'
      and name = 'da111111-1111-4111-8111-111111111111/da100000-0000-4000-8000-000000000001/source.pdf'
  $sql$,
  'the test simulates successful Storage API deletion of the queued object'
);
set local role service_role;
select extensions.results_eq(
  $sql$
    select source_id, storage_path
    from public.claim_expired_document_sources(1)
  $sql$,
  $sql$
    values (
      'dc300000-0000-4000-8000-000000000003'::uuid,
      'dc333333-3333-4333-8333-333333333333/dc300000-0000-4000-8000-000000000003/source.pdf'::text
    )
  $sql$,
  'the original caller UUID path remains independently claimable'
);
reset role;
select extensions.is(
  (
    select count(*)
    from private.document_storage_delete_queue
    where source_id in (
      'dd400000-0000-4000-8000-000000000004',
      'de500000-0000-4000-8000-000000000005'
    )
  ),
  0::bigint,
  'the next p_limit one call retires the remaining stale queue entry'
);
select extensions.lives_ok(
  $sql$
    delete from storage.objects
    where bucket_id = 'schedule-documents'
      and name = 'dc333333-3333-4333-8333-333333333333/dc300000-0000-4000-8000-000000000003/source.pdf'
  $sql$,
  'the test simulates successful Storage API deletion of the reused UUID PDF object'
);
set local role service_role;
select extensions.results_eq(
  $sql$
    select source_id, storage_path
    from public.claim_expired_document_sources(1)
  $sql$,
  $sql$
    select
      split_part(object.name, '/', 2)::uuid,
      object.name
    from storage.objects object
    where object.bucket_id = 'schedule-documents'
      and object.owner_id = 'dc333333-3333-4333-8333-333333333333'
  $sql$,
  'the rotated authoritative UUID path remains independently claimable'
);
select extensions.lives_ok(
  $sql$
    delete from storage.objects
    where bucket_id = 'schedule-documents'
      and owner_id = 'dc333333-3333-4333-8333-333333333333'
  $sql$,
  'the test simulates successful Storage API deletion of the rotated PDF object'
);
select extensions.results_eq(
  $sql$
    select source_id, storage_path
    from public.claim_expired_document_sources(1)
  $sql$,
  $sql$
    values (
      'db200000-0000-4000-8000-000000000002'::uuid,
      'db222222-2222-4222-8222-222222222222/db200000-0000-4000-8000-000000000002/source.txt'::text
    )
  $sql$,
  'the next bounded claim retires the completed queue row and claims one expired source'
);
select extensions.results_eq(
  $sql$
    select source_id, storage_path
    from public.claim_expired_document_sources(1)
  $sql$,
  $sql$
    values (
      'db200000-0000-4000-8000-000000000002'::uuid,
      'db222222-2222-4222-8222-222222222222/db200000-0000-4000-8000-000000000002/source.txt'::text
    )
  $sql$,
  'one more bounded retry retires the final completed queue row while the expired source stays claimable'
);

reset role;
select extensions.is(
  (select count(*) from private.document_storage_delete_queue),
  0::bigint,
  'a Storage-deleted hard-delete path leaves the durable retry queue'
);
select extensions.results_eq(
  $sql$
    select processing_state, deleted_at is not null
    from public.document_sources
    where id = 'db200000-0000-4000-8000-000000000002'
  $sql$,
  $sql$ values ('deleted'::text, true) $sql$,
  'the expired source branch retains its existing lifecycle transition'
);

set local request.jwt.claims = '{"role":"service_role"}';
set local request.jwt.claim.role = 'service_role';
set local role service_role;
select extensions.lives_ok(
  $sql$
    delete from storage.objects
    where bucket_id = 'schedule-documents'
      and name = 'db222222-2222-4222-8222-222222222222/db200000-0000-4000-8000-000000000002/source.txt'
  $sql$,
  'the test simulates successful Storage API deletion of the expired object'
);
select extensions.is_empty(
  $sql$
    select source_id, storage_path
    from public.claim_expired_document_sources(1)
  $sql$,
  'completed queue and retention paths are no longer reclaimed'
);

select * from extensions.finish();
rollback;
