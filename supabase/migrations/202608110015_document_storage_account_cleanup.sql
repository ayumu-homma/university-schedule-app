-- Preserve document Storage deletion work when a source row is hard-deleted,
-- including the ON DELETE CASCADE path used by Auth account deletion.
begin;

create table private.document_storage_delete_queue (
  source_id uuid not null,
  storage_path text primary key,
  queued_at timestamptz not null default clock_timestamp()
);

alter table private.document_storage_delete_queue enable row level security;

revoke all on table private.document_storage_delete_queue
from public, anon, authenticated, service_role;

create index document_storage_delete_queue_claim_idx
on private.document_storage_delete_queue(queued_at, source_id, storage_path);

create index document_storage_delete_queue_source_idx
on private.document_storage_delete_queue(source_id);

comment on table private.document_storage_delete_queue is
  'Durable private Storage paths captured before document source hard deletion. Contains no raw document bytes and is accessible only through the trusted cleanup RPC.';

create function private.queue_document_storage_delete()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, private
as $$
begin
  insert into private.document_storage_delete_queue (
    source_id,
    storage_path,
    queued_at
  ) values (
    old.id,
    old.storage_path,
    clock_timestamp()
  )
  on conflict (storage_path) do update
  set queued_at = least(
        private.document_storage_delete_queue.queued_at,
        excluded.queued_at
      );

  return old;
end;
$$;

revoke all on function private.queue_document_storage_delete()
from public, anon, authenticated, service_role;

create trigger document_sources_queue_storage_delete
before delete on public.document_sources
for each row execute function private.queue_document_storage_delete();

create or replace function public.create_document_source(
  p_source_id uuid,
  p_media_type text,
  p_byte_size bigint,
  p_content_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_owner uuid := auth.uid();
  v_extension text;
  v_insert_source_id uuid;
  v_source public.document_sources%rowtype;
  v_recent_count bigint;
begin
  if v_owner is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_source_id is null
     or p_media_type is null
     or p_media_type not in ('application/pdf', 'image/png', 'image/jpeg', 'text/plain')
     or p_byte_size is null
     or p_byte_size not between 1 and 10485760
     or p_content_hash is null
     or p_content_hash !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'invalid_document_source';
  end if;

  -- Every reservation for one owner is serialized before the owner-wide
  -- hourly count. A content-keyed lock alone lets concurrent unique hashes
  -- each observe the same pre-insert count and bypass the quota.
  perform pg_advisory_xact_lock(
    hashtextextended(v_owner::text || ':document-source-owner', 0)
  );
  select * into v_source
  from public.document_sources
  where owner_user_id = v_owner
    and content_hash = p_content_hash
    and deleted_at is null
  for update;
  if found then
    if v_source.retention_expires_at > clock_timestamp() then
      return jsonb_build_object(
        'source_id', v_source.id,
        'storage_path', v_source.storage_path,
        'processing_state', v_source.processing_state,
        'replayed', true
      );
    end if;

    update public.document_sources source
    set processing_state = 'deleted',
        error_category = null,
        retry_after_at = null,
        deleted_at = clock_timestamp(),
        updated_at = clock_timestamp(),
        version = source.version + 1
    where source.id = v_source.id;
    update public.document_candidates candidate
    set review_state = case
          when candidate.review_state = 'confirmed' then candidate.review_state
          else 'excluded'
        end,
        is_selected = false,
        deleted_at = coalesce(candidate.deleted_at, clock_timestamp()),
        updated_at = clock_timestamp(),
        version = candidate.version + 1
    where candidate.source_id = v_source.id
      and candidate.deleted_at is null;
  end if;

  select count(*) into v_recent_count
  from public.document_sources
  where owner_user_id = v_owner
    and created_at >= clock_timestamp() - interval '1 hour';
  if v_recent_count >= 20 then
    raise exception using errcode = 'P0001', message = 'document_rate_limited';
  end if;

  v_extension := case p_media_type
    when 'application/pdf' then 'pdf'
    when 'image/png' then 'png'
    when 'image/jpeg' then 'jpg'
    when 'text/plain' then 'txt'
  end;

  -- The caller UUID is a retry correlation value, not permanent authority.
  -- Preserve it for the usual first reservation, but never reactivate or
  -- overwrite a tombstone (including one owned by another account). A queued
  -- UUID is also reserved until its old Storage path is fully drained: reusing
  -- it with the same media type would let a new live source adopt old bytes.
  v_insert_source_id := p_source_id;
  while exists (
    select 1 from public.document_sources where id = v_insert_source_id
  ) or exists (
    select 1
    from private.document_storage_delete_queue queued
    where queued.source_id = v_insert_source_id
  ) loop
    v_insert_source_id := gen_random_uuid();
  end loop;

  insert into public.document_sources (
    id,
    owner_user_id,
    storage_path,
    media_type,
    byte_size,
    content_hash
  ) values (
    v_insert_source_id,
    v_owner,
    v_owner::text || '/' || v_insert_source_id::text || '/source.' || v_extension,
    p_media_type,
    p_byte_size,
    p_content_hash
  )
  returning * into v_source;

  return jsonb_build_object(
    'source_id', v_source.id,
    'storage_path', v_source.storage_path,
    'processing_state', v_source.processing_state,
    'replayed', false
  );
end;
$$;

revoke execute on function public.create_document_source(uuid, text, bigint, text)
from public, anon, service_role;
grant execute on function public.create_document_source(uuid, text, bigint, text)
to authenticated;

create or replace function public.claim_expired_document_sources(
  p_limit integer default 100
)
returns table (source_id uuid, storage_path text)
language plpgsql
security definer
set search_path = pg_catalog, public, private, storage
as $$
declare
  v_queued private.document_storage_delete_queue%rowtype;
  v_source public.document_sources%rowtype;
  v_claimed integer := 0;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_limit is null or p_limit not between 1 and 500 then
    raise exception using errcode = '22023', message = 'invalid_cleanup_limit';
  end if;

  -- A prior Storage API deletion removes storage.objects metadata as part of
  -- the same operation. Retire only queue entries whose object is already gone.
  with stale_queue as (
    select queued.storage_path
    from private.document_storage_delete_queue queued
    where not exists (
      select 1
      from storage.objects object
      where object.bucket_id = 'schedule-documents'
        and object.name = queued.storage_path
    )
    order by queued.queued_at, queued.source_id, queued.storage_path
    for update of queued skip locked
    limit p_limit
  )
  delete from private.document_storage_delete_queue queued
  using stale_queue stale
  where queued.storage_path = stale.storage_path;

  -- Hard-deleted source rows no longer exist in public.document_sources, so
  -- drain their durable paths first. Storage deletion remains idempotent and a
  -- path stays claimable until the Storage API removes its object metadata.
  for v_queued in
    select queued.*
    from private.document_storage_delete_queue queued
    where exists (
      select 1
      from storage.objects object
      where object.bucket_id = 'schedule-documents'
        and object.name = queued.storage_path
    )
    order by queued.queued_at, queued.source_id, queued.storage_path
    for update of queued skip locked
    limit p_limit
  loop
    source_id := v_queued.source_id;
    storage_path := v_queued.storage_path;
    v_claimed := v_claimed + 1;
    return next;
  end loop;

  if v_claimed >= p_limit then
    return;
  end if;

  for v_source in
    select source.*
    from public.document_sources source
    where source.retention_expires_at <= clock_timestamp()
      and (
        source.deleted_at is null
        or exists (
          select 1
          from storage.objects object
          where object.bucket_id = 'schedule-documents'
            and object.name = source.storage_path
        )
      )
    order by source.retention_expires_at, source.id
    for update of source skip locked
    limit (p_limit - v_claimed)
  loop
    update public.document_sources source
    set processing_state = 'deleted',
        error_category = null,
        retry_after_at = null,
        deleted_at = coalesce(source.deleted_at, clock_timestamp()),
        updated_at = clock_timestamp(),
        version = source.version + 1
    where source.id = v_source.id
      and source.deleted_at is null;

    update public.document_candidates candidate
    set review_state = case
          when candidate.review_state = 'confirmed' then candidate.review_state
          else 'excluded'
        end,
        is_selected = false,
        deleted_at = coalesce(candidate.deleted_at, clock_timestamp()),
        updated_at = clock_timestamp(),
        version = candidate.version + 1
    where candidate.source_id = v_source.id
      and candidate.deleted_at is null;

    source_id := v_source.id;
    storage_path := v_source.storage_path;
    return next;
  end loop;
end;
$$;

revoke execute on function public.claim_expired_document_sources(integer)
from public, anon, authenticated;
grant execute on function public.claim_expired_document_sources(integer)
to service_role;

comment on function public.claim_expired_document_sources(integer) is
  'Service-only bounded cleanup claim. Returns at most p_limit total paths across hard-delete queue entries and expired source rows; paths remain retryable until Storage API deletion succeeds.';

commit;
