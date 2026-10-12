-- Add a read-only cleanup preview and count-only audit trail around the
-- existing bounded Storage cleanup claim. Object deletion still happens only
-- through the Supabase Storage API.
begin;

create table private.document_cleanup_runs (
  run_id uuid primary key,
  mode text not null check (mode in ('dry_run', 'manual_execute')),
  requested_limit integer not null check (requested_limit between 1 and 500),
  eligible_count bigint not null check (eligible_count >= 0),
  claimed_count integer not null default 0 check (claimed_count >= 0),
  deleted_count integer not null default 0 check (deleted_count >= 0),
  failed_count integer not null default 0 check (failed_count >= 0),
  status text not null default 'started'
    check (status in ('started', 'succeeded', 'partial', 'failed')),
  started_at timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  check (claimed_count <= requested_limit),
  check (deleted_count + failed_count <= claimed_count),
  check (
    (status = 'started' and finished_at is null)
    or (status <> 'started' and finished_at is not null)
  )
);

alter table private.document_cleanup_runs enable row level security;

revoke all on table private.document_cleanup_runs
from public, anon, authenticated, service_role;

comment on table private.document_cleanup_runs is
  'Count-only audit records for document Storage cleanup. Never stores owner IDs, Storage paths, source names, bytes, tokens, or provider content.';

create or replace function public.preview_expired_document_sources(
  p_limit integer default 100
)
returns table (
  queued_object_count bigint,
  expired_source_count bigint,
  eligible_count bigint,
  preview_count integer
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public, private, storage
as $$
declare
  v_queued_count bigint;
  v_expired_count bigint;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_limit is null or p_limit not between 1 and 500 then
    raise exception using errcode = '22023', message = 'invalid_cleanup_limit';
  end if;

  select count(*)
  into v_queued_count
  from private.document_storage_delete_queue queued
  where exists (
    select 1
    from storage.objects object
    where object.bucket_id = 'schedule-documents'
      and object.name = queued.storage_path
  );

  select count(*)
  into v_expired_count
  from public.document_sources source
  where source.retention_expires_at <= statement_timestamp()
    and (
      source.deleted_at is null
      or exists (
        select 1
        from storage.objects object
        where object.bucket_id = 'schedule-documents'
          and object.name = source.storage_path
      )
    );

  return query
  select
    v_queued_count,
    v_expired_count,
    v_queued_count + v_expired_count,
    least(v_queued_count + v_expired_count, p_limit::bigint)::integer;
end;
$$;

create or replace function public.begin_document_cleanup_run(
  p_run_id uuid,
  p_mode text,
  p_requested_limit integer,
  p_eligible_count bigint
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, private
as $$
declare
  v_existing private.document_cleanup_runs%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_run_id is null
     or p_mode not in ('dry_run', 'manual_execute')
     or p_requested_limit is null
     or p_requested_limit not between 1 and 500
     or p_eligible_count is null
     or p_eligible_count < 0 then
    raise exception using errcode = '22023', message = 'invalid_cleanup_run';
  end if;

  insert into private.document_cleanup_runs (
    run_id,
    mode,
    requested_limit,
    eligible_count
  ) values (
    p_run_id,
    p_mode,
    p_requested_limit,
    p_eligible_count
  )
  on conflict (run_id) do nothing;

  select run.*
  into strict v_existing
  from private.document_cleanup_runs run
  where run.run_id = p_run_id;

  if v_existing.mode <> p_mode
     or v_existing.requested_limit <> p_requested_limit
     or v_existing.eligible_count <> p_eligible_count then
    raise exception using errcode = '22023', message = 'cleanup_run_conflict';
  end if;

  return p_run_id;
end;
$$;

create or replace function public.finish_document_cleanup_run(
  p_run_id uuid,
  p_status text,
  p_claimed_count integer,
  p_deleted_count integer,
  p_failed_count integer
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, private
as $$
declare
  v_run private.document_cleanup_runs%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;

  select run.*
  into v_run
  from private.document_cleanup_runs run
  where run.run_id = p_run_id
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'cleanup_run_not_found';
  end if;

  if p_status not in ('succeeded', 'partial', 'failed')
     or p_claimed_count is null
     or p_deleted_count is null
     or p_failed_count is null
     or p_claimed_count < 0
     or p_claimed_count > v_run.requested_limit
     or p_deleted_count < 0
     or p_failed_count < 0
     or p_deleted_count + p_failed_count <> p_claimed_count
     or (
       v_run.mode = 'dry_run'
       and (
         p_status <> 'succeeded'
         or p_claimed_count <> 0
         or p_deleted_count <> 0
         or p_failed_count <> 0
       )
     ) then
    raise exception using errcode = '22023', message = 'invalid_cleanup_run_result';
  end if;

  if v_run.status <> 'started' then
    if v_run.status = p_status
       and v_run.claimed_count = p_claimed_count
       and v_run.deleted_count = p_deleted_count
       and v_run.failed_count = p_failed_count then
      return p_run_id;
    end if;
    raise exception using errcode = '22023', message = 'cleanup_run_already_finished';
  end if;

  update private.document_cleanup_runs run
  set status = p_status,
      claimed_count = p_claimed_count,
      deleted_count = p_deleted_count,
      failed_count = p_failed_count,
      finished_at = clock_timestamp()
  where run.run_id = p_run_id;

  return p_run_id;
end;
$$;

create or replace function public.get_document_cleanup_run(
  p_run_id uuid
)
returns table (
  run_id uuid,
  mode text,
  requested_limit integer,
  eligible_count bigint,
  claimed_count integer,
  deleted_count integer,
  failed_count integer,
  status text,
  started_at timestamptz,
  finished_at timestamptz
)
language plpgsql
stable
security definer
set search_path = pg_catalog, private
as $$
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_run_id is null then
    raise exception using errcode = '22023', message = 'invalid_cleanup_run';
  end if;

  return query
  select
    run.run_id,
    run.mode,
    run.requested_limit,
    run.eligible_count,
    run.claimed_count,
    run.deleted_count,
    run.failed_count,
    run.status,
    run.started_at,
    run.finished_at
  from private.document_cleanup_runs run
  where run.run_id = p_run_id;

  if not found then
    raise exception using errcode = 'P0002', message = 'cleanup_run_not_found';
  end if;
end;
$$;

revoke execute on function public.preview_expired_document_sources(integer)
from public, anon, authenticated;
grant execute on function public.preview_expired_document_sources(integer)
to service_role;

revoke execute on function public.begin_document_cleanup_run(uuid, text, integer, bigint)
from public, anon, authenticated;
grant execute on function public.begin_document_cleanup_run(uuid, text, integer, bigint)
to service_role;

revoke execute on function public.finish_document_cleanup_run(uuid, text, integer, integer, integer)
from public, anon, authenticated;
grant execute on function public.finish_document_cleanup_run(uuid, text, integer, integer, integer)
to service_role;

revoke execute on function public.get_document_cleanup_run(uuid)
from public, anon, authenticated;
grant execute on function public.get_document_cleanup_run(uuid)
to service_role;

comment on function public.preview_expired_document_sources(integer) is
  'Service-only read-only preview of bounded cleanup eligibility. Returns counts only and does not claim rows or reveal Storage paths.';
comment on function public.begin_document_cleanup_run(uuid, text, integer, bigint) is
  'Starts or idempotently returns the same count-only cleanup audit record for a trusted worker.';
comment on function public.finish_document_cleanup_run(uuid, text, integer, integer, integer) is
  'Idempotently finishes a trusted cleanup audit record without storing paths, owners, content, or credentials.';
comment on function public.get_document_cleanup_run(uuid) is
  'Returns one trusted count-only cleanup audit record by run ID without exposing paths, owners, content, or credentials.';

commit;
