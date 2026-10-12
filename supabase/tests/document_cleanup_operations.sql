begin;

create extension if not exists pgtap with schema extensions;
select extensions.plan(29);

select extensions.has_table(
  'private',
  'document_cleanup_runs',
  'cleanup execution has a private count-only audit table'
);
select extensions.ok(
  (
    select table_definition.relrowsecurity
    from pg_catalog.pg_class table_definition
    join pg_catalog.pg_namespace namespace_definition
      on namespace_definition.oid = table_definition.relnamespace
    where namespace_definition.nspname = 'private'
      and table_definition.relname = 'document_cleanup_runs'
  ),
  'cleanup audit table has defense-in-depth RLS enabled'
);
select extensions.is(
  (
    select count(*)
    from pg_catalog.pg_policy policy
    join pg_catalog.pg_class table_definition
      on table_definition.oid = policy.polrelid
    join pg_catalog.pg_namespace namespace_definition
      on namespace_definition.oid = table_definition.relnamespace
    where namespace_definition.nspname = 'private'
      and table_definition.relname = 'document_cleanup_runs'
  ),
  0::bigint,
  'cleanup audit table exposes no client row policy'
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
      and table_definition.relname = 'document_cleanup_runs'
      and attribute_definition.attnum > 0
      and not attribute_definition.attisdropped
      and attribute_definition.attname ~*
        '(^|_)(path|owner|user|source|file|raw|body|bytes|token|key)($|_)'
  $sql$,
  'cleanup audit schema contains no path, owner, source, content, token, or key field'
);
select extensions.ok(
  (
    select bool_and(
      not pg_catalog.has_table_privilege(
        role_name,
        'private.document_cleanup_runs',
        privilege_name
      )
    )
    from unnest(array['anon', 'authenticated', 'service_role']) role_name
    cross join unnest(array['SELECT', 'INSERT', 'UPDATE', 'DELETE']) privilege_name
  ),
  'no API role has direct cleanup audit table privileges'
);
select extensions.ok(
  not pg_catalog.has_function_privilege(
    'anon',
    'public.preview_expired_document_sources(integer)',
    'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated',
    'public.preview_expired_document_sources(integer)',
    'EXECUTE'
  )
  and pg_catalog.has_function_privilege(
    'service_role',
    'public.preview_expired_document_sources(integer)',
    'EXECUTE'
  ),
  'cleanup preview is executable only by the service role'
);
select extensions.ok(
  not pg_catalog.has_function_privilege(
    'anon',
    'public.begin_document_cleanup_run(uuid, text, integer, bigint)',
    'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated',
    'public.begin_document_cleanup_run(uuid, text, integer, bigint)',
    'EXECUTE'
  )
  and pg_catalog.has_function_privilege(
    'service_role',
    'public.begin_document_cleanup_run(uuid, text, integer, bigint)',
    'EXECUTE'
  ),
  'cleanup audit begin RPC is executable only by the service role'
);
select extensions.ok(
  not pg_catalog.has_function_privilege(
    'anon',
    'public.finish_document_cleanup_run(uuid, text, integer, integer, integer)',
    'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated',
    'public.finish_document_cleanup_run(uuid, text, integer, integer, integer)',
    'EXECUTE'
  )
  and pg_catalog.has_function_privilege(
    'service_role',
    'public.finish_document_cleanup_run(uuid, text, integer, integer, integer)',
    'EXECUTE'
  ),
  'cleanup audit finish RPC is executable only by the service role'
);
select extensions.ok(
  not pg_catalog.has_function_privilege(
    'anon',
    'public.get_document_cleanup_run(uuid)',
    'EXECUTE'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated',
    'public.get_document_cleanup_run(uuid)',
    'EXECUTE'
  )
  and pg_catalog.has_function_privilege(
    'service_role',
    'public.get_document_cleanup_run(uuid)',
    'EXECUTE'
  ),
  'cleanup audit lookup RPC is executable only by the service role'
);
select extensions.is(
  (
    select function_definition.provolatile
    from pg_catalog.pg_proc function_definition
    join pg_catalog.pg_namespace namespace_definition
      on namespace_definition.oid = function_definition.pronamespace
    where namespace_definition.nspname = 'public'
      and function_definition.proname = 'preview_expired_document_sources'
  ),
  's'::"char",
  'cleanup preview is declared stable and cannot claim work'
);

insert into auth.users (id)
values ('ee111111-1111-4111-8111-111111111111');

set local request.jwt.claims =
  '{"sub":"ee111111-1111-4111-8111-111111111111","role":"authenticated"}';
set local request.jwt.claim.sub = 'ee111111-1111-4111-8111-111111111111';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

select public.create_document_source(
  'ee200000-0000-4000-8000-000000000002',
  'application/pdf',
  1024,
  repeat('e', 64)
);
insert into storage.objects (bucket_id, name, owner_id)
values (
  'schedule-documents',
  'ee111111-1111-4111-8111-111111111111/ee200000-0000-4000-8000-000000000002/source.pdf',
  'ee111111-1111-4111-8111-111111111111'
);

reset role;
update public.document_sources
set created_at = statement_timestamp() - interval '40 days',
    retention_expires_at = statement_timestamp() - interval '1 second'
where id = 'ee200000-0000-4000-8000-000000000002';

insert into private.document_storage_delete_queue (
  source_id,
  storage_path,
  queued_at
) values (
  'ef300000-0000-4000-8000-000000000003',
  'ef333333-3333-4333-8333-333333333333/ef300000-0000-4000-8000-000000000003/source.txt',
  statement_timestamp() - interval '2 seconds'
);
insert into storage.objects (bucket_id, name, owner_id)
values (
  'schedule-documents',
  'ef333333-3333-4333-8333-333333333333/ef300000-0000-4000-8000-000000000003/source.txt',
  'ef333333-3333-4333-8333-333333333333'
);

set local request.jwt.claims = '{"role":"service_role"}';
set local request.jwt.claim.role = 'service_role';
set local role service_role;

select extensions.results_eq(
  $sql$
    select
      queued_object_count,
      expired_source_count,
      eligible_count,
      preview_count
    from public.preview_expired_document_sources(1)
  $sql$,
  $sql$ values (1::bigint, 1::bigint, 2::bigint, 1::integer) $sql$,
  'preview reports queue, retention, total, and bounded counts without paths'
);
reset role;
select extensions.is(
  (
    select processing_state
    from public.document_sources
    where id = 'ee200000-0000-4000-8000-000000000002'
  ),
  'pending_upload'::text,
  'preview does not transition an expired source'
);
select extensions.is(
  (
    select count(*)
    from private.document_storage_delete_queue
    where source_id = 'ef300000-0000-4000-8000-000000000003'
  ),
  1::bigint,
  'preview does not retire or claim a durable queue row'
);
set local role service_role;
select extensions.throws_ok(
  $sql$ select * from public.preview_expired_document_sources(0) $sql$,
  '22023',
  'invalid_cleanup_limit',
  'preview rejects an unbounded or zero cleanup limit'
);

select extensions.results_eq(
  $sql$
    select public.begin_document_cleanup_run(
      'f0111111-1111-4111-8111-111111111111',
      'dry_run',
      1,
      2
    )
  $sql$,
  $sql$ values ('f0111111-1111-4111-8111-111111111111'::uuid) $sql$,
  'dry-run audit starts with a caller-generated correlation ID'
);
reset role;
select extensions.results_eq(
  $sql$
    select mode, requested_limit, eligible_count, status, finished_at is null
    from private.document_cleanup_runs
    where run_id = 'f0111111-1111-4111-8111-111111111111'
  $sql$,
  $sql$ values ('dry_run'::text, 1, 2::bigint, 'started'::text, true) $sql$,
  'dry-run audit stores only bounded counts and lifecycle state'
);
set local role service_role;
select extensions.results_eq(
  $sql$
    select public.begin_document_cleanup_run(
      'f0111111-1111-4111-8111-111111111111',
      'dry_run',
      1,
      2
    )
  $sql$,
  $sql$ values ('f0111111-1111-4111-8111-111111111111'::uuid) $sql$,
  'repeating the same audit begin request is idempotent'
);
select extensions.throws_ok(
  $sql$
    select public.begin_document_cleanup_run(
      'f0111111-1111-4111-8111-111111111111',
      'dry_run',
      2,
      2
    )
  $sql$,
  '22023',
  'cleanup_run_conflict',
  'reusing a run ID with different inputs fails closed'
);
select extensions.results_eq(
  $sql$
    select public.finish_document_cleanup_run(
      'f0111111-1111-4111-8111-111111111111',
      'succeeded',
      0,
      0,
      0
    )
  $sql$,
  $sql$ values ('f0111111-1111-4111-8111-111111111111'::uuid) $sql$,
  'dry-run audit finishes without claiming or deleting data'
);
reset role;
select extensions.results_eq(
  $sql$
    select status, claimed_count, deleted_count, failed_count,
      finished_at is not null
    from private.document_cleanup_runs
    where run_id = 'f0111111-1111-4111-8111-111111111111'
  $sql$,
  $sql$ values ('succeeded'::text, 0, 0, 0, true) $sql$,
  'finished dry-run audit remains count-only'
);
set local role service_role;
select extensions.results_eq(
  $sql$
    select public.finish_document_cleanup_run(
      'f0111111-1111-4111-8111-111111111111',
      'succeeded',
      0,
      0,
      0
    )
  $sql$,
  $sql$ values ('f0111111-1111-4111-8111-111111111111'::uuid) $sql$,
  'repeating the same audit finish request is idempotent'
);
select extensions.results_eq(
  $sql$
    select mode, requested_limit, eligible_count,
      claimed_count, deleted_count, failed_count, status,
      started_at is not null, finished_at is not null
    from public.get_document_cleanup_run(
      'f0111111-1111-4111-8111-111111111111'
    )
  $sql$,
  $sql$
    values ('dry_run'::text, 1, 2::bigint, 0, 0, 0, 'succeeded'::text, true, true)
  $sql$,
  'service audit lookup exposes the completed count-only dry-run record'
);
select extensions.throws_ok(
  $sql$
    select public.finish_document_cleanup_run(
      'f0111111-1111-4111-8111-111111111111',
      'failed',
      0,
      0,
      0
    )
  $sql$,
  '22023',
  'invalid_cleanup_run_result',
  'a dry-run cannot be rewritten as a failed destructive execution'
);

select public.begin_document_cleanup_run(
  'f0222222-2222-4222-8222-222222222222',
  'manual_execute',
  1,
  2
);
select extensions.throws_ok(
  $sql$
    select public.finish_document_cleanup_run(
      'f0222222-2222-4222-8222-222222222222',
      'succeeded',
      2,
      2,
      0
    )
  $sql$,
  '22023',
  'invalid_cleanup_run_result',
  'audit completion cannot exceed the requested cleanup limit'
);
select extensions.results_eq(
  $sql$
    select public.finish_document_cleanup_run(
      'f0222222-2222-4222-8222-222222222222',
      'partial',
      1,
      0,
      1
    )
  $sql$,
  $sql$ values ('f0222222-2222-4222-8222-222222222222'::uuid) $sql$,
  'manual execution can record a bounded partial Storage API result'
);
reset role;
select extensions.results_eq(
  $sql$
    select mode, requested_limit, eligible_count,
      claimed_count, deleted_count, failed_count, status
    from private.document_cleanup_runs
    where run_id = 'f0222222-2222-4222-8222-222222222222'
  $sql$,
  $sql$
    values ('manual_execute'::text, 1, 2::bigint, 1, 0, 1, 'partial'::text)
  $sql$,
  'manual audit exposes only aggregate execution counts'
);
set local role service_role;
select extensions.throws_ok(
  $sql$
    select public.finish_document_cleanup_run(
      'f0333333-3333-4333-8333-333333333333',
      'failed',
      0,
      0,
      0
    )
  $sql$,
  'P0002',
  'cleanup_run_not_found',
  'finishing an unknown cleanup run fails closed'
);
select extensions.throws_ok(
  $sql$
    select * from public.get_document_cleanup_run(
      'f0333333-3333-4333-8333-333333333333'
    )
  $sql$,
  'P0002',
  'cleanup_run_not_found',
  'looking up an unknown cleanup run fails closed'
);
reset role;
select extensions.is(
  (
    select count(*)
    from private.document_cleanup_runs
  ),
  2::bigint,
  'idempotent audit RPCs never duplicate run records'
);

select * from extensions.finish();
rollback;
