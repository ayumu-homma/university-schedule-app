-- Phase 5 completion: persist sanitized per-message failures, make cursor
-- advancement replayable after a lost response, and support owner-bound
-- targeted retries without mutating the incremental replay receipt.
begin;

alter table public.email_candidates
  alter column validated_payload drop not null;

alter table public.email_candidates
  drop constraint email_candidates_payload_bounded,
  add constraint email_candidates_payload_bounded check (
    (
      review_state = 'failed'
      and validated_payload is null
    )
    or (
      review_state <> 'failed'
      and validated_payload is not null
      and jsonb_typeof(validated_payload) = 'object'
      and pg_column_size(validated_payload) <= 65536
    )
  ),
  add constraint email_candidates_failure_error_consistent check (
    (review_state = 'failed') = (error_category is not null)
  );

alter table public.email_sources
  add constraint email_sources_failure_error_consistent check (
    (processing_state = 'failed') = (error_category is not null)
  );

create function private.email_import_suppression_hashes(
  p_suppressions jsonb
)
returns text[]
language sql
immutable
strict
set search_path = pg_catalog
as $$
  select coalesce(
    array_agg(
      suppression.value ->> 'providerMessageIdHash'
      order by suppression.ordinality
    ),
    array[]::text[]
  )
  from jsonb_array_elements(p_suppressions)
    with ordinality suppression(value, ordinality);
$$;

create table private.email_import_sync_receipts (
  connection_id uuid not null,
  owner_user_id uuid not null,
  expected_cursor text,
  expected_cursor_key text generated always as (
    encode(
      extensions.digest(
        case
          when expected_cursor is null then 'N'
          else 'V' || expected_cursor
        end,
        'sha256'
      ),
      'hex'
    )
  ) stored,
  next_cursor text,
  items jsonb not null,
  item_message_id_hashes text[] not null,
  suppressions jsonb not null,
  suppression_message_id_hashes text[] generated always as (
    private.email_import_suppression_hashes(suppressions)
  ) stored,
  has_more boolean not null,
  created_at timestamptz not null,
  updated_at timestamptz not null,
  primary key (connection_id, expected_cursor_key),
  constraint email_import_sync_receipts_connection_owner_fk
    foreign key (connection_id, owner_user_id)
    references public.email_connections(id, owner_user_id)
    on delete cascade,
  constraint email_import_sync_receipts_expected_cursor_bounded check (
    expected_cursor is null
    or (
      char_length(expected_cursor) between 1 and 4096
      and expected_cursor = btrim(expected_cursor)
    )
  ),
  constraint email_import_sync_receipts_next_cursor_bounded check (
    next_cursor is null
    or (
      char_length(next_cursor) between 1 and 4096
      and next_cursor = btrim(next_cursor)
    )
  ),
  constraint email_import_sync_receipts_items_bounded check (
    jsonb_typeof(items) = 'array'
    and jsonb_array_length(items) <= 100
    and pg_column_size(items) <= 2097152
  ),
  constraint email_import_sync_receipts_suppressions_bounded check (
    jsonb_typeof(suppressions) = 'array'
    and jsonb_array_length(suppressions) <= 100
    and jsonb_array_length(items) + jsonb_array_length(suppressions) <= 100
    and pg_column_size(suppressions) <= 131072
  ),
  constraint email_import_sync_receipts_identity_partition check (
    cardinality(item_message_id_hashes) = jsonb_array_length(items)
    and cardinality(suppression_message_id_hashes) =
      jsonb_array_length(suppressions)
    and array_position(item_message_id_hashes, null) is null
    and array_position(suppression_message_id_hashes, null) is null
    and (
      cardinality(item_message_id_hashes) = 0
      or array_to_string(item_message_id_hashes, ',') ~
        '^[0-9a-f]{64}(,[0-9a-f]{64})*$'
    )
    and (
      cardinality(suppression_message_id_hashes) = 0
      or array_to_string(suppression_message_id_hashes, ',') ~
        '^[0-9a-f]{64}(,[0-9a-f]{64})*$'
    )
    and not (item_message_id_hashes && suppression_message_id_hashes)
  ),
  constraint email_import_sync_receipts_cursor_progress check (
    next_cursor is not null
    and next_cursor is distinct from expected_cursor
  )
);

create index email_import_sync_receipts_connection_updated_idx
on private.email_import_sync_receipts (connection_id, updated_at desc);
create index email_import_sync_receipts_updated_idx
on private.email_import_sync_receipts (updated_at);

create table private.email_import_retry_receipts (
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  idempotency_key text not null,
  connection_id uuid not null,
  provider_message_id text,
  provider_message_id_hash text not null,
  expected_content_hash text not null,
  retry_outcome text not null,
  item jsonb,
  suppression jsonb,
  created_at timestamptz not null,
  primary key (owner_user_id, idempotency_key),
  constraint email_import_retry_receipts_connection_owner_fk
    foreign key (connection_id, owner_user_id)
    references public.email_connections(id, owner_user_id)
    on delete cascade,
  constraint email_import_retry_receipts_key_valid check (
    idempotency_key ~ '^[0-9a-f]{64}$'
  ),
  constraint email_import_retry_receipts_message_bounded check (
    provider_message_id is null
    or (
      char_length(provider_message_id) between 1 and 1024
      and provider_message_id = btrim(provider_message_id)
      and provider_message_id !~ '[[:space:][:cntrl:]]'
    )
  ),
  constraint email_import_retry_receipts_hash_valid check (
    provider_message_id_hash ~ '^[0-9a-f]{64}$'
    and expected_content_hash ~ '^[0-9a-f]{64}$'
  ),
  constraint email_import_retry_receipts_item_bounded check (
    item is null
    or (
      jsonb_typeof(item) = 'object'
      and pg_column_size(item) <= 131072
    )
  ),
  constraint email_import_retry_receipts_suppression_bounded check (
    suppression is null
    or (
      jsonb_typeof(suppression) = 'object'
      and pg_column_size(suppression) <= 4096
    )
  ),
  constraint email_import_retry_receipts_item_contract check (
    (
      retry_outcome = 'suppressed'
      and provider_message_id is null
      and item is null
      and jsonb_typeof(suppression) = 'object'
      and coalesce(
        suppression ?& array['providerMessageIdHash', 'reason']
        and jsonb_typeof(suppression -> 'providerMessageIdHash') = 'string'
        and suppression ->> 'providerMessageIdHash' ~ '^[0-9a-f]{64}$'
        and suppression ->> 'reason' in ('dismissed', 'deduplicated'),
        false
      )
    )
    or (
      retry_outcome = 'persisted'
      and provider_message_id is not null
      and item is not null
      and suppression is null
      and coalesce(
        item ?& array[
          'providerMessageId', 'providerThreadId', 'receivedAt',
          'sanitizedContentHash', 'evidenceExcerpts', 'candidate',
          'errorCategory'
        ]
        and jsonb_typeof(item -> 'providerMessageId') = 'string'
        and jsonb_typeof(item -> 'providerThreadId') = 'string'
        and jsonb_typeof(item -> 'receivedAt') = 'string'
        and jsonb_typeof(item -> 'sanitizedContentHash') = 'string'
        and jsonb_typeof(item -> 'evidenceExcerpts') = 'array'
        and (
          (
            jsonb_typeof(item -> 'candidate') = 'null'
            and jsonb_typeof(item -> 'errorCategory') = 'string'
          )
          or (
            jsonb_typeof(item -> 'candidate') = 'object'
            and jsonb_typeof(item -> 'errorCategory') = 'null'
          )
        ),
        false
      )
    )
  )
);

create index email_import_retry_receipts_connection_created_idx
on private.email_import_retry_receipts (connection_id, created_at desc);
create index email_import_retry_receipts_created_idx
on private.email_import_retry_receipts (created_at);

-- One-row transaction guards distinguish an internal failed-to-success
-- replacement from an actual source deletion. No API role can create a guard.
create table private.email_import_source_replacement_guards (
  connection_id uuid not null,
  owner_user_id uuid not null,
  provider_message_id text not null,
  transaction_id bigint not null,
  primary key (connection_id, provider_message_id),
  constraint email_import_source_replacement_guards_connection_owner_fk
    foreign key (connection_id, owner_user_id)
    references public.email_connections(id, owner_user_id)
    on delete cascade,
  constraint email_import_source_replacement_guards_message_bounded check (
    char_length(provider_message_id) between 1 and 1024
    and provider_message_id = btrim(provider_message_id)
    and provider_message_id !~ '[[:space:][:cntrl:]]'
  )
);

alter table private.email_import_sync_receipts enable row level security;
alter table private.email_import_retry_receipts enable row level security;
alter table private.email_import_source_replacement_guards enable row level security;

revoke all on table private.email_import_sync_receipts
from public, anon, authenticated, service_role;
revoke all on table private.email_import_retry_receipts
from public, anon, authenticated, service_role;
revoke all on table private.email_import_source_replacement_guards
from public, anon, authenticated, service_role;

-- Preserve the already-audited success/dedupe/update implementation as a
-- private implementation detail. The replacement RPC below is the sole
-- service-role entry point.
alter function public.email_import_persist_sync_page(
  uuid, uuid, text, text, jsonb, jsonb, boolean, timestamptz, uuid
) rename to email_import_persist_sync_page_success_v1;

revoke all on function public.email_import_persist_sync_page_success_v1(
  uuid, uuid, text, text, jsonb, jsonb, boolean, timestamptz, uuid
) from public, anon, authenticated, service_role;

create function private.email_import_persist_sync_page_v2(
  p_owner_user_id uuid,
  p_connection_id uuid,
  p_expected_cursor text,
  p_next_cursor text,
  p_sources jsonb,
  p_candidates jsonb,
  p_has_more boolean,
  p_synced_at timestamptz,
  p_correlation_id uuid,
  p_write_sync_receipt boolean
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_connection public.email_connections%rowtype;
  v_source jsonb;
  v_candidate_entry jsonb;
  v_payload jsonb;
  v_provider_message_id text;
  v_provider_thread_id text;
  v_received_at timestamptz;
  v_content_hash text;
  v_error_category text;
  v_evidence jsonb;
  v_message_hash text;
  v_thread_hash text;
  v_source_id uuid;
  v_success_sources jsonb;
  v_success_candidates jsonb;
  v_receipt_items jsonb;
  v_suppressions jsonb;
  v_suppression jsonb;
  v_item_message_id_hashes text[];
  v_suppression_message_id_hashes text[];
  v_result jsonb;
  v_item_count integer;
begin
  if p_owner_user_id is null
    or p_connection_id is null
    or p_has_more is null
    or p_synced_at is null
    or not isfinite(p_synced_at)
    or p_correlation_id is null
    or p_write_sync_receipt is null
    or p_sources is null
    or p_candidates is null
    or jsonb_typeof(p_sources) <> 'array'
    or jsonb_typeof(p_candidates) <> 'array'
  then
    raise exception using errcode = '22023', message = 'Invalid email sync page.';
  end if;

  v_item_count := jsonb_array_length(p_sources);
  if v_item_count > 100
    or v_item_count <> jsonb_array_length(p_candidates)
    or pg_column_size(p_sources) > 1048576
    or pg_column_size(p_candidates) > 2097152
    or (p_expected_cursor is not null and (
      char_length(p_expected_cursor) not between 1 and 4096
      or p_expected_cursor <> btrim(p_expected_cursor)
    ))
    or (p_next_cursor is not null and (
      char_length(p_next_cursor) not between 1 and 4096
      or p_next_cursor <> btrim(p_next_cursor)
    ))
    or (p_has_more and (
      p_next_cursor is null
      or p_next_cursor is not distinct from p_expected_cursor
    ))
    or (
      p_write_sync_receipt
      and (
        p_next_cursor is null
        or p_next_cursor is not distinct from p_expected_cursor
      )
    )
    or (
      select count(distinct item ->> 'provider_message_id')
      from jsonb_array_elements(p_sources) item
    ) <> v_item_count
    or (
      select count(distinct item ->> 'provider_message_id')
      from jsonb_array_elements(p_candidates) item
    ) <> v_item_count
  then
    raise exception using errcode = '22023', message = 'Invalid email sync page.';
  end if;

  select * into v_connection
  from public.email_connections
  where id = p_connection_id
    and owner_user_id = p_owner_user_id
    and provider = 'gmail'
  for update;
  if v_connection.id is null then
    raise exception using errcode = '42501', message = 'Email connection owner mismatch.';
  end if;
  if v_connection.connection_state not in ('connected', 'rate_limited', 'failed') then
    raise exception using errcode = '55000', message = 'Email connection is not fetchable.';
  end if;
  if v_connection.sync_cursor is distinct from p_expected_cursor then
    raise exception using errcode = '40001', message = 'Email cursor changed.';
  end if;

  for v_source in select value from jsonb_array_elements(p_sources) loop
    if jsonb_typeof(v_source) <> 'object'
      or (select count(*) from jsonb_object_keys(v_source)) <> 7
      or not (v_source ?& array[
        'provider_message_id',
        'provider_thread_id',
        'received_at',
        'sanitized_content_hash',
        'evidence_metadata',
        'processing_state',
        'error_category'
      ])
    then
      raise exception using errcode = '22023', message = 'Invalid email source metadata.';
    end if;

    v_provider_message_id := v_source ->> 'provider_message_id';
    v_provider_thread_id := v_source ->> 'provider_thread_id';
    v_content_hash := v_source ->> 'sanitized_content_hash';
    v_evidence := v_source -> 'evidence_metadata';
    v_error_category := v_source ->> 'error_category';
    if jsonb_typeof(v_source -> 'provider_message_id') <> 'string'
      or jsonb_typeof(v_source -> 'provider_thread_id') <> 'string'
      or jsonb_typeof(v_source -> 'received_at') <> 'string'
      or jsonb_typeof(v_source -> 'sanitized_content_hash') <> 'string'
      or jsonb_typeof(v_source -> 'processing_state') <> 'string'
      or jsonb_typeof(v_source -> 'error_category') is null
      or jsonb_typeof(v_source -> 'error_category') not in ('string', 'null')
      or v_provider_message_id is null
      or char_length(v_provider_message_id) not between 1 and 1024
      or v_provider_message_id <> btrim(v_provider_message_id)
      or v_provider_message_id ~ '[[:space:][:cntrl:]]'
      or v_provider_thread_id is null
      or char_length(v_provider_thread_id) not between 1 and 1024
      or v_provider_thread_id <> btrim(v_provider_thread_id)
      or v_provider_thread_id ~ '[[:space:][:cntrl:]]'
      or v_content_hash is null
      or v_content_hash !~ '^[0-9a-f]{64}$'
      or (v_source ->> 'received_at') !~
        '^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]{1,9})?(Z|[+-](0[0-9]|1[0-3]):[0-5][0-9]|[+-]14:00)$'
      or jsonb_typeof(v_evidence) <> 'array'
      or jsonb_array_length(v_evidence) > 8
      or pg_column_size(v_evidence) > 8192
      or exists (
        select 1 from jsonb_array_elements(v_evidence) evidence
        where jsonb_typeof(evidence) <> 'string'
          or char_length(evidence #>> '{}') not between 1 and 512
          or evidence #>> '{}' <> btrim(evidence #>> '{}')
          or evidence #>> '{}' ~ '^[[:space:]]|[[:space:]]$'
          or exists (
            select 1
            from regexp_split_to_table(evidence #>> '{}', '') character(value)
            where ascii(character.value) between 1 and 8
              or ascii(character.value) in (11, 12, 127)
              or ascii(character.value) between 14 and 31
          )
      )
      or v_source ->> 'processing_state' not in ('processed', 'failed')
      or (
        (v_source ->> 'processing_state') = 'failed'
        and (
          jsonb_typeof(v_source -> 'error_category') <> 'string'
          or v_error_category is null
          or v_error_category not in (
            'authorization_revoked', 'cursor_expired', 'rate_limited',
            'timeout', 'network_unavailable', 'provider_unavailable',
            'configuration_missing', 'malformed_content',
            'oversized_content', 'unsafe_content', 'invalid_extraction',
            'unsupported_schema', 'unsafe_url', 'validation_failed',
            'internal_error'
          )
          or jsonb_array_length(v_evidence) <> 0
        )
      )
      or (
        (v_source ->> 'processing_state') = 'processed'
        and jsonb_typeof(v_source -> 'error_category') <> 'null'
      )
    then
      raise exception using errcode = '22023', message = 'Invalid email source metadata.';
    end if;
    begin
      v_received_at := (v_source ->> 'received_at')::timestamptz;
      if not isfinite(v_received_at) then raise exception 'invalid'; end if;
    exception when others then
      raise exception using errcode = '22023', message = 'Invalid email source metadata.';
    end;

    select value into v_candidate_entry
    from jsonb_array_elements(p_candidates)
    where value ->> 'provider_message_id' = v_provider_message_id;
    if v_candidate_entry is null
      or jsonb_typeof(v_candidate_entry) <> 'object'
      or (select count(*) from jsonb_object_keys(v_candidate_entry)) <> 3
      or not (v_candidate_entry ?& array[
        'provider_message_id', 'validated_payload', 'error_category'
      ])
      or jsonb_typeof(v_candidate_entry -> 'provider_message_id') <> 'string'
      or jsonb_typeof(v_candidate_entry -> 'error_category') is null
      or jsonb_typeof(v_candidate_entry -> 'error_category')
        not in ('string', 'null')
      or v_candidate_entry ->> 'error_category' is distinct from v_error_category
      or jsonb_typeof(v_candidate_entry -> 'error_category') is distinct from
        jsonb_typeof(v_source -> 'error_category')
    then
      raise exception using errcode = '22023', message = 'Invalid email candidate metadata.';
    end if;

    v_payload := v_candidate_entry -> 'validated_payload';
    if (v_source ->> 'processing_state') = 'failed' then
      if v_payload is distinct from 'null'::jsonb then
        raise exception using errcode = '22023', message = 'Invalid email candidate metadata.';
      end if;
    elsif v_payload is null
      or v_payload = 'null'::jsonb
      or jsonb_typeof(v_payload) <> 'object'
      or pg_column_size(v_payload) > 65536
      or jsonb_typeof(v_payload -> 'schema_version') <> 'string'
      or v_payload ->> 'schema_version' <> '1.0'
      or jsonb_typeof(v_payload -> 'candidate_type') <> 'string'
      or v_payload ->> 'candidate_type' not in (
        'assignment', 'exam', 'event', 'announcement', 'unknown'
      )
      or v_payload -> 'requires_user_confirmation' <> 'true'::jsonb
    then
      raise exception using errcode = '22023', message = 'Invalid email candidate metadata.';
    end if;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object(
      'provider_message_id', source.value ->> 'provider_message_id',
      'provider_thread_id', source.value ->> 'provider_thread_id',
      'received_at', source.value ->> 'received_at',
      'sanitized_content_hash', source.value ->> 'sanitized_content_hash',
      'evidence_metadata', source.value -> 'evidence_metadata'
    ) order by source.ordinality), '[]'::jsonb)
  into v_success_sources
  from jsonb_array_elements(p_sources) with ordinality source(value, ordinality)
  where source.value ->> 'processing_state' = 'processed';

  select coalesce(jsonb_agg(jsonb_build_object(
      'provider_message_id', candidate.value ->> 'provider_message_id',
      'validated_payload', candidate.value -> 'validated_payload'
    ) order by candidate.ordinality), '[]'::jsonb)
  into v_success_candidates
  from jsonb_array_elements(p_candidates) with ordinality candidate(value, ordinality)
  join jsonb_array_elements(p_sources) source
    on source ->> 'provider_message_id' = candidate.value ->> 'provider_message_id'
  where source ->> 'processing_state' = 'processed';

  -- A successful result replaces the minimal failed source/candidate.
  -- Deleting only failed rows preserves the immutable identity guard for every
  -- already-successful source. This is an in-place state transition, not a
  -- user deletion, so a private transaction guard tells the delete trigger to
  -- preserve prior replay receipts for this state transition.
  insert into private.email_import_source_replacement_guards (
    connection_id, owner_user_id, provider_message_id, transaction_id
  )
  select existing.connection_id, existing.owner_user_id,
    existing.provider_message_id, txid_current()
  from public.email_sources existing
  join jsonb_array_elements(v_success_sources) incoming
    on existing.provider_message_id = incoming ->> 'provider_message_id'
  where existing.owner_user_id = p_owner_user_id
    and existing.connection_id = p_connection_id
    and existing.processing_state = 'failed'
  on conflict (connection_id, provider_message_id) do update
  set owner_user_id = excluded.owner_user_id,
      transaction_id = excluded.transaction_id;

  delete from public.email_sources existing
  using jsonb_array_elements(v_success_sources) incoming
  where existing.owner_user_id = p_owner_user_id
    and existing.connection_id = p_connection_id
    and existing.provider_message_id = incoming ->> 'provider_message_id'
    and existing.processing_state = 'failed';

  delete from private.email_import_source_replacement_guards guard
  where guard.connection_id = p_connection_id
    and guard.owner_user_id = p_owner_user_id
    and guard.transaction_id = txid_current();

  v_result := public.email_import_persist_sync_page_success_v1(
    p_owner_user_id,
    p_connection_id,
    p_expected_cursor,
    p_next_cursor,
    v_success_sources,
    v_success_candidates,
    p_has_more,
    p_synced_at,
    p_correlation_id
  );

  for v_source in
    select value from jsonb_array_elements(p_sources)
    where value ->> 'processing_state' = 'failed'
  loop
    v_provider_message_id := v_source ->> 'provider_message_id';
    v_provider_thread_id := v_source ->> 'provider_thread_id';
    v_content_hash := v_source ->> 'sanitized_content_hash';
    v_error_category := v_source ->> 'error_category';
    v_received_at := (v_source ->> 'received_at')::timestamptz;
    v_message_hash := private.email_import_provider_identifier_hash(
      'message', v_connection.provider, v_connection.provider_account_hash,
      v_provider_message_id
    );
    v_thread_hash := private.email_import_provider_identifier_hash(
      'thread', v_connection.provider, v_connection.provider_account_hash,
      v_provider_thread_id
    );

    if exists (
      select 1
      from private.email_import_dismissal_tombstones d
      where d.owner_user_id = p_owner_user_id
        and d.connection_id = p_connection_id
        and d.provider = v_connection.provider
        and d.provider_account_hash = v_connection.provider_account_hash
        and (
          d.provider_message_id_hash = v_message_hash
          or (
            d.provider_thread_id_hash = v_thread_hash
            and d.sanitized_content_hash = v_content_hash
          )
        )
    ) then
      delete from public.email_sources existing
      where existing.owner_user_id = p_owner_user_id
        and existing.connection_id = p_connection_id
        and existing.provider_message_id = v_provider_message_id
        and existing.processing_state = 'failed';
      continue;
    end if;

    insert into public.email_sources (
      owner_user_id, connection_id, provider_message_id, provider_thread_id,
      provider_message_id_hash, provider_thread_id_hash, received_at,
      sanitized_content_hash, evidence_metadata, processing_state,
      error_category, created_at, updated_at
    ) values (
      p_owner_user_id, p_connection_id, v_provider_message_id,
      v_provider_thread_id, v_message_hash, v_thread_hash, v_received_at,
      v_content_hash, '[]'::jsonb, 'failed', v_error_category,
      p_synced_at, p_synced_at
    )
    on conflict (connection_id, provider_message_id) do update
    set provider_thread_id = excluded.provider_thread_id,
        received_at = excluded.received_at,
        sanitized_content_hash = excluded.sanitized_content_hash,
        evidence_metadata = '[]'::jsonb,
        processing_state = 'failed',
        error_category = excluded.error_category,
        updated_at = excluded.updated_at
    where email_sources.owner_user_id = p_owner_user_id
      and email_sources.processing_state = 'failed'
    returning id into v_source_id;

    if v_source_id is null then
      continue;
    end if;
    insert into public.email_candidates (
      owner_user_id, source_id, schema_version, candidate_type,
      validated_payload, review_state, semantic_fingerprint,
      error_category, requires_user_confirmation, created_at, updated_at
    ) values (
      p_owner_user_id, v_source_id, '1.0', 'unknown', null, 'failed',
      v_content_hash, v_error_category, true, p_synced_at, p_synced_at
    )
    on conflict (source_id) do update
    set validated_payload = null,
        review_state = 'failed',
        semantic_fingerprint = excluded.semantic_fingerprint,
        error_category = excluded.error_category,
        updated_at = excluded.updated_at
    where email_candidates.owner_user_id = p_owner_user_id
      and email_candidates.review_state = 'failed';
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object(
      'providerMessageId', source.value ->> 'provider_message_id',
      'providerThreadId', source.value ->> 'provider_thread_id',
      'receivedAt', source.value ->> 'received_at',
      'sanitizedContentHash', source.value ->> 'sanitized_content_hash',
      'evidenceExcerpts', source.value -> 'evidence_metadata',
      'candidate', candidate.value -> 'validated_payload',
      'errorCategory', candidate.value -> 'error_category'
    ) order by source.ordinality), '[]'::jsonb)
  into v_receipt_items
  from jsonb_array_elements(p_sources) with ordinality source(value, ordinality)
  join jsonb_array_elements(p_candidates) candidate
    on candidate ->> 'provider_message_id' = source.value ->> 'provider_message_id'
  where exists (
    select 1
    from public.email_sources persisted_source
    where persisted_source.owner_user_id = p_owner_user_id
      and persisted_source.connection_id = p_connection_id
      and persisted_source.provider_message_id =
        source.value ->> 'provider_message_id'
      and persisted_source.sanitized_content_hash =
        source.value ->> 'sanitized_content_hash'
      and persisted_source.processing_state =
        source.value ->> 'processing_state'
      and persisted_source.error_category is not distinct from
        (source.value ->> 'error_category')
  )
  and not exists (
    select 1
    from private.email_import_dismissal_tombstones d
    where d.owner_user_id = p_owner_user_id
      and d.connection_id = p_connection_id
      and d.provider = v_connection.provider
      and d.provider_account_hash = v_connection.provider_account_hash
      and (
        d.provider_message_id_hash = private.email_import_provider_identifier_hash(
            'message', v_connection.provider,
            v_connection.provider_account_hash,
            source.value ->> 'provider_message_id'
          )
        or (
          d.provider_thread_id_hash = private.email_import_provider_identifier_hash(
              'thread', v_connection.provider,
              v_connection.provider_account_hash,
              source.value ->> 'provider_thread_id'
            )
          and (
            d.sanitized_content_hash = source.value ->> 'sanitized_content_hash'
            or (
              candidate -> 'validated_payload' is distinct from 'null'::jsonb
              and d.semantic_fingerprint = private.email_import_semantic_fingerprint(
                candidate -> 'validated_payload'
              )
            )
          )
        )
      )
  );

  select coalesce(jsonb_agg(jsonb_build_object(
      'providerMessageIdHash', private.email_import_provider_identifier_hash(
        'message', v_connection.provider, v_connection.provider_account_hash,
        source.value ->> 'provider_message_id'
      ),
      'reason', case when exists (
        select 1
        from private.email_import_dismissal_tombstones d
        where d.owner_user_id = p_owner_user_id
          and d.connection_id = p_connection_id
          and d.provider = v_connection.provider
          and d.provider_account_hash = v_connection.provider_account_hash
          and (
            d.provider_message_id_hash = private.email_import_provider_identifier_hash(
                'message', v_connection.provider,
                v_connection.provider_account_hash,
                source.value ->> 'provider_message_id'
              )
            or (
              d.provider_thread_id_hash = private.email_import_provider_identifier_hash(
                  'thread', v_connection.provider,
                  v_connection.provider_account_hash,
                  source.value ->> 'provider_thread_id'
                )
              and (
                d.sanitized_content_hash =
                  source.value ->> 'sanitized_content_hash'
                or (
                  candidate -> 'validated_payload' is distinct from 'null'::jsonb
                  and d.semantic_fingerprint =
                    private.email_import_semantic_fingerprint(
                      candidate -> 'validated_payload'
                    )
                )
              )
            )
          )
      ) then 'dismissed' else 'deduplicated' end
    ) order by source.ordinality), '[]'::jsonb)
  into v_suppressions
  from jsonb_array_elements(p_sources) with ordinality source(value, ordinality)
  join jsonb_array_elements(p_candidates) candidate
    on candidate ->> 'provider_message_id' =
      source.value ->> 'provider_message_id'
  where not exists (
    select 1
    from jsonb_array_elements(v_receipt_items) committed_item
    where committed_item ->> 'providerMessageId' =
      source.value ->> 'provider_message_id'
  );

  select coalesce(array_agg(
      private.email_import_provider_identifier_hash(
        'message', v_connection.provider, v_connection.provider_account_hash,
        committed_item.value ->> 'providerMessageId'
      ) order by committed_item.ordinality
    ), array[]::text[])
  into v_item_message_id_hashes
  from jsonb_array_elements(v_receipt_items)
    with ordinality committed_item(value, ordinality);
  v_suppression_message_id_hashes :=
    private.email_import_suppression_hashes(v_suppressions);

  if jsonb_array_length(v_receipt_items) + jsonb_array_length(v_suppressions)
      <> v_item_count
    or v_item_message_id_hashes && v_suppression_message_id_hashes
  then
    raise exception using errcode = '55000', message = 'Invalid committed sync page.';
  end if;

  -- If a newer committed page suppresses a previously returned identity,
  -- replace that old item with the same exact acknowledgement on every replay.
  for v_suppression in
    select value from jsonb_array_elements(v_suppressions)
  loop
    update private.email_import_sync_receipts receipt
    set items = (
        select coalesce(
          jsonb_agg(page_item.value order by page_item.ordinality),
          '[]'::jsonb
        )
        from jsonb_array_elements(receipt.items)
          with ordinality page_item(value, ordinality)
        where private.email_import_provider_identifier_hash(
          'message', v_connection.provider, v_connection.provider_account_hash,
          page_item.value ->> 'providerMessageId'
        ) <> v_suppression ->> 'providerMessageIdHash'
      ),
      item_message_id_hashes = array_remove(
        receipt.item_message_id_hashes,
        v_suppression ->> 'providerMessageIdHash'
      ),
      suppressions = receipt.suppressions || jsonb_build_array(v_suppression),
      updated_at = clock_timestamp()
    where receipt.connection_id = p_connection_id
      and receipt.owner_user_id = p_owner_user_id
      and exists (
        select 1 from jsonb_array_elements(receipt.items) page_item
        where private.email_import_provider_identifier_hash(
          'message', v_connection.provider, v_connection.provider_account_hash,
          page_item ->> 'providerMessageId'
        ) = v_suppression ->> 'providerMessageIdHash'
      );
  end loop;

  -- The targeted-retry wrapper calls this private core with receipt writes
  -- disabled. Normal sync calls retain an exact replay per input cursor.
  if p_write_sync_receipt then
    insert into private.email_import_sync_receipts (
      connection_id, owner_user_id, expected_cursor, next_cursor, items,
      item_message_id_hashes, suppressions, has_more, created_at, updated_at
    ) values (
      p_connection_id, p_owner_user_id, p_expected_cursor, p_next_cursor,
      v_receipt_items, v_item_message_id_hashes, v_suppressions, p_has_more,
      clock_timestamp(), clock_timestamp()
    )
    on conflict (connection_id, expected_cursor_key) do update
    set owner_user_id = excluded.owner_user_id,
        next_cursor = excluded.next_cursor,
        items = excluded.items,
        item_message_id_hashes = excluded.item_message_id_hashes,
        suppressions = excluded.suppressions,
        has_more = excluded.has_more,
        updated_at = excluded.updated_at
    where email_import_sync_receipts.expected_cursor is not distinct from
      excluded.expected_cursor;
    if not found then
      raise exception using errcode = '55000', message = 'Email cursor receipt collision.';
    end if;

    -- Receipts are recovery state, not permanent mailbox history. Replay
    -- expires after 24 hours; each write opportunistically purges expired rows
    -- globally and retains at most 32 cursor pages per connection.
    delete from private.email_import_sync_receipts receipt
    where receipt.updated_at < clock_timestamp() - interval '24 hours';

    with ranked_receipts as (
      select expected_cursor_key,
        row_number() over (
          order by updated_at desc, expected_cursor_key desc
        ) as receipt_rank
      from private.email_import_sync_receipts
      where connection_id = p_connection_id
    )
    delete from private.email_import_sync_receipts receipt
    using ranked_receipts ranked
    where receipt.connection_id = p_connection_id
      and receipt.expected_cursor_key = ranked.expected_cursor_key
      and ranked.receipt_rank > 32;
  end if;

  return jsonb_build_object(
    'connection', v_result,
    'page', jsonb_build_object(
      'items', v_receipt_items,
      'suppressions', v_suppressions,
      'next_cursor', p_next_cursor,
      'has_more', p_has_more,
      'connected_at', v_result -> 'connected_at'
    )
  );
end;
$$;

create function public.email_import_persist_sync_page(
  p_owner_user_id uuid,
  p_connection_id uuid,
  p_expected_cursor text,
  p_next_cursor text,
  p_sources jsonb,
  p_candidates jsonb,
  p_has_more boolean,
  p_synced_at timestamptz,
  p_correlation_id uuid
)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public, private
as $$
  select private.email_import_persist_sync_page_v2(
    p_owner_user_id, p_connection_id, p_expected_cursor, p_next_cursor,
    p_sources, p_candidates, p_has_more, p_synced_at, p_correlation_id,
    true
  );
$$;

create function public.email_import_get_sync_replay(
  p_owner_user_id uuid,
  p_connection_id uuid,
  p_expected_cursor text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_connection public.email_connections%rowtype;
  v_receipt private.email_import_sync_receipts%rowtype;
begin
  if p_owner_user_id is null
    or p_connection_id is null
    or (p_expected_cursor is not null and (
      char_length(p_expected_cursor) not between 1 and 4096
      or p_expected_cursor <> btrim(p_expected_cursor)
    ))
  then
    raise exception using errcode = '22023', message = 'Invalid email replay lookup.';
  end if;
  select * into v_connection
  from public.email_connections
  where id = p_connection_id
    and owner_user_id = p_owner_user_id
    and provider = 'gmail'
    and connection_state in ('connected', 'rate_limited', 'failed');
  if v_connection.id is null then
    raise exception using errcode = '42501', message = 'Email connection owner mismatch.';
  end if;
  select * into v_receipt
  from private.email_import_sync_receipts
  where connection_id = p_connection_id
    and owner_user_id = p_owner_user_id
    and expected_cursor_key = encode(
      extensions.digest(
        case
          when p_expected_cursor is null then 'N'
          else 'V' || p_expected_cursor
        end,
        'sha256'
      ),
      'hex'
    )
    and expected_cursor is not distinct from p_expected_cursor
    and updated_at >= statement_timestamp() - interval '24 hours';
  if v_receipt.connection_id is null then return null; end if;
  return jsonb_build_object(
    'items', v_receipt.items,
    'suppressions', v_receipt.suppressions,
    'next_cursor', v_receipt.next_cursor,
    'has_more', v_receipt.has_more,
    'connected_at', v_connection.connected_at
  );
end;
$$;

create function public.email_import_get_owner_timezone(
  p_owner_user_id uuid,
  p_connection_id uuid
)
returns text
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_timezone text;
  v_university_id uuid;
begin
  if not exists (
    select 1 from public.email_connections
    where id = p_connection_id
      and owner_user_id = p_owner_user_id
      and provider = 'gmail'
  ) then
    raise exception using errcode = '42501', message = 'Email connection owner mismatch.';
  end if;
  select p.university_id into v_university_id
  from public.profiles p
  where p.user_id = p_owner_user_id
    and p.deleted_at is null;
  if v_university_id is null then return null; end if;
  select u.timezone into v_timezone
  from public.universities u
  where u.id = v_university_id
    and u.deleted_at is null;
  if not found then
    raise exception using errcode = '55000',
      message = 'Configured university timezone is unavailable.';
  end if;
  return v_timezone;
end;
$$;

create function public.email_import_get_retry_replay(
  p_owner_user_id uuid,
  p_connection_id uuid,
  p_provider_message_id text,
  p_expected_content_hash text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_connection public.email_connections%rowtype;
  v_receipt private.email_import_retry_receipts%rowtype;
begin
  if p_owner_user_id is null
    or p_connection_id is null
    or p_provider_message_id is null
    or char_length(p_provider_message_id) not between 1 and 1024
    or p_provider_message_id <> btrim(p_provider_message_id)
    or p_provider_message_id ~ '[[:space:][:cntrl:]]'
    or p_expected_content_hash is null
    or p_expected_content_hash !~ '^[0-9a-f]{64}$'
    or p_idempotency_key is null
    or p_idempotency_key !~ '^[0-9a-f]{64}$'
  then
    raise exception using errcode = '22023', message = 'Invalid email retry replay lookup.';
  end if;
  select * into v_connection
  from public.email_connections
  where id = p_connection_id
    and owner_user_id = p_owner_user_id
    and provider = 'gmail'
    and connection_state in ('connected', 'rate_limited', 'failed');
  if v_connection.id is null then
    raise exception using errcode = '42501', message = 'Email connection owner mismatch.';
  end if;
  select * into v_receipt
  from private.email_import_retry_receipts
  where owner_user_id = p_owner_user_id
    and idempotency_key = p_idempotency_key
    and created_at >= statement_timestamp() - interval '24 hours';
  if v_receipt.idempotency_key is null then return null; end if;
  if v_receipt.connection_id <> p_connection_id
    or v_receipt.provider_message_id_hash <>
      private.email_import_provider_identifier_hash(
        'message', v_connection.provider, v_connection.provider_account_hash,
        p_provider_message_id
      )
    or v_receipt.expected_content_hash <> p_expected_content_hash
  then
    raise exception using errcode = '23505', message = 'Email retry idempotency key was reused.';
  end if;
  return jsonb_build_object(
    'retry_outcome', v_receipt.retry_outcome,
    'item', v_receipt.item,
    'suppression', v_receipt.suppression,
    'connected_at', v_connection.connected_at
  );
end;
$$;

create function public.email_import_assert_retry_candidate(
  p_owner_user_id uuid,
  p_connection_id uuid,
  p_provider_message_id text,
  p_expected_content_hash text
)
returns boolean
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if p_owner_user_id is null
    or p_connection_id is null
    or p_provider_message_id is null
    or char_length(p_provider_message_id) not between 1 and 1024
    or p_provider_message_id <> btrim(p_provider_message_id)
    or p_provider_message_id ~ '[[:space:][:cntrl:]]'
    or p_expected_content_hash is null
    or p_expected_content_hash !~ '^[0-9a-f]{64}$'
  then
    raise exception using errcode = '22023', message = 'Invalid email retry candidate.';
  end if;
  if not exists (
    select 1
    from public.email_sources s
    join public.email_candidates c
      on c.source_id = s.id and c.owner_user_id = s.owner_user_id
    join public.email_connections ec
      on ec.id = s.connection_id and ec.owner_user_id = s.owner_user_id
    where s.owner_user_id = p_owner_user_id
      and s.connection_id = p_connection_id
      and s.provider_message_id = p_provider_message_id
      and s.sanitized_content_hash = p_expected_content_hash
      and s.processing_state = 'failed'
      and c.review_state = 'failed'
      and c.error_category = s.error_category
      and s.error_category in (
        'rate_limited', 'timeout', 'network_unavailable',
        'provider_unavailable', 'internal_error'
      )
      and ec.provider = 'gmail'
      and ec.connection_state = 'connected'
  ) then
    raise exception using errcode = '42501', message = 'Email retry source mismatch.';
  end if;
  return true;
end;
$$;

create function public.email_import_persist_retry_candidate(
  p_owner_user_id uuid,
  p_connection_id uuid,
  p_sources jsonb,
  p_candidates jsonb,
  p_expected_content_hash text,
  p_idempotency_key text,
  p_retried_at timestamptz,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_connection public.email_connections%rowtype;
  v_retry_receipt private.email_import_retry_receipts%rowtype;
  v_provider_message_id text;
  v_provider_message_id_hash text;
  v_item jsonb;
  v_suppression jsonb;
  v_retry_outcome text;
  v_core_result jsonb;
  v_page_items jsonb;
  v_page_suppressions jsonb;
  v_result jsonb;
begin
  if p_sources is null
    or p_candidates is null
    or jsonb_typeof(p_sources) <> 'array'
    or jsonb_typeof(p_candidates) <> 'array'
    or jsonb_array_length(p_sources) <> 1
    or jsonb_array_length(p_candidates) <> 1
    or p_expected_content_hash is null
    or p_expected_content_hash !~ '^[0-9a-f]{64}$'
    or p_idempotency_key is null
    or p_idempotency_key !~ '^[0-9a-f]{64}$'
    or p_retried_at is null
    or not isfinite(p_retried_at)
    or p_correlation_id is null
  then
    raise exception using errcode = '22023', message = 'Invalid email retry candidate.';
  end if;
  v_provider_message_id := p_sources -> 0 ->> 'provider_message_id';
  if v_provider_message_id is null
    or v_provider_message_id is distinct from
      (p_candidates -> 0 ->> 'provider_message_id')
  then
    raise exception using errcode = '22023', message = 'Invalid email retry candidate.';
  end if;

  select * into v_connection
  from public.email_connections
  where id = p_connection_id
    and owner_user_id = p_owner_user_id
    and provider = 'gmail'
  for update;
  if v_connection.id is null then
    raise exception using errcode = '42501', message = 'Email connection owner mismatch.';
  end if;
  if v_connection.connection_state <> 'connected' then
    raise exception using errcode = '55000', message = 'Email connection is not retryable.';
  end if;
  v_provider_message_id_hash := private.email_import_provider_identifier_hash(
    'message', v_connection.provider, v_connection.provider_account_hash,
    v_provider_message_id
  );

  -- Bound idempotency storage without dropping a still-live key merely because
  -- a later retry for the same message succeeds.
  delete from private.email_import_retry_receipts
  where created_at < clock_timestamp() - interval '24 hours';

  select * into v_retry_receipt
  from private.email_import_retry_receipts
  where owner_user_id = p_owner_user_id
    and idempotency_key = p_idempotency_key
  for update;
  if v_retry_receipt.idempotency_key is not null then
    if v_retry_receipt.connection_id <> p_connection_id
      or v_retry_receipt.provider_message_id_hash <>
        v_provider_message_id_hash
      or v_retry_receipt.expected_content_hash <> p_expected_content_hash
    then
      raise exception using errcode = '23505', message = 'Email retry idempotency key was reused.';
    end if;
    return jsonb_build_object(
      'connection', jsonb_build_object(
        'connection_id', v_connection.id,
        'connection_state', v_connection.connection_state,
        'sync_cursor', v_connection.sync_cursor,
        'connected_at', v_connection.connected_at,
        'last_synced_at', v_connection.last_synced_at
      ),
      'retry_outcome', v_retry_receipt.retry_outcome,
      'item', v_retry_receipt.item,
      'suppression', v_retry_receipt.suppression
    );
  end if;
  perform 1
  from public.email_sources s
  join public.email_candidates c
    on c.source_id = s.id and c.owner_user_id = s.owner_user_id
  where s.owner_user_id = p_owner_user_id
    and s.connection_id = p_connection_id
    and s.provider_message_id = v_provider_message_id
    and s.sanitized_content_hash = p_expected_content_hash
    and s.processing_state = 'failed'
    and c.review_state = 'failed'
    and c.error_category = s.error_category
    and s.error_category in (
      'rate_limited', 'timeout', 'network_unavailable',
      'provider_unavailable', 'internal_error'
    )
  for update of s, c;
  if not found then
    raise exception using errcode = '42501', message = 'Email retry source mismatch.';
  end if;

  -- Reuse the private strict persistence core without adding, overwriting,
  -- pruning, or deleting any incremental sync receipt.
  v_core_result := private.email_import_persist_sync_page_v2(
    p_owner_user_id,
    p_connection_id,
    v_connection.sync_cursor,
    v_connection.sync_cursor,
    p_sources,
    p_candidates,
    false,
    p_retried_at,
    p_correlation_id,
    false
  );
  v_result := v_core_result -> 'connection';
  v_page_items := v_core_result #> '{page,items}';
  v_page_suppressions := v_core_result #> '{page,suppressions}';
  if jsonb_typeof(v_page_items) <> 'array'
    or jsonb_typeof(v_page_suppressions) <> 'array'
  then
    raise exception using errcode = '55000', message = 'Invalid committed retry page.';
  end if;
  if jsonb_array_length(v_page_items) = 0
    and jsonb_array_length(v_page_suppressions) = 1
    and v_page_suppressions -> 0 ->> 'providerMessageIdHash' =
      v_provider_message_id_hash
  then
    v_retry_outcome := 'suppressed';
    v_item := null;
    v_suppression := v_page_suppressions -> 0;
  elsif jsonb_array_length(v_page_items) = 1
    and jsonb_array_length(v_page_suppressions) = 0
    and v_page_items -> 0 ->> 'providerMessageId' = v_provider_message_id
  then
    v_retry_outcome := 'persisted';
    v_item := v_page_items -> 0;
    v_suppression := null;
  else
    raise exception using errcode = '55000', message = 'Invalid committed retry page.';
  end if;

  if v_retry_outcome = 'suppressed' then
    update private.email_import_retry_receipts receipt
    set retry_outcome = 'suppressed',
        provider_message_id = null,
        item = null,
        suppression = v_suppression
    where receipt.owner_user_id = p_owner_user_id
      and receipt.connection_id = p_connection_id
      and receipt.provider_message_id_hash = v_provider_message_id_hash;
  end if;

  insert into private.email_import_retry_receipts (
    owner_user_id, idempotency_key, connection_id, provider_message_id,
    provider_message_id_hash, expected_content_hash, retry_outcome, item,
    suppression, created_at
  ) values (
    p_owner_user_id, p_idempotency_key, p_connection_id,
    case when v_retry_outcome = 'persisted'
      then v_provider_message_id else null end,
    v_provider_message_id_hash,
    p_expected_content_hash, v_retry_outcome, v_item, v_suppression,
    clock_timestamp()
  );

  with ranked_receipts as (
    select idempotency_key,
      row_number() over (
        order by created_at desc, idempotency_key desc
      ) as receipt_rank
    from private.email_import_retry_receipts
    where owner_user_id = p_owner_user_id
      and connection_id = p_connection_id
  )
  delete from private.email_import_retry_receipts receipt
  using ranked_receipts ranked
  where receipt.owner_user_id = p_owner_user_id
    and receipt.idempotency_key = ranked.idempotency_key
    and ranked.receipt_rank > 64;
  return jsonb_build_object(
    'connection', v_result,
    'retry_outcome', v_retry_outcome,
    'item', v_item,
    'suppression', v_suppression
  );
end;
$$;

create function private.email_import_clear_sync_receipt_on_dismissal()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, private
as $$
declare
  v_provider_message_id text;
begin
  for v_provider_message_id in
    select distinct page_item.value ->> 'providerMessageId'
    from private.email_import_sync_receipts receipt
    cross join lateral jsonb_array_elements(receipt.items) page_item(value)
    where receipt.connection_id = new.connection_id
      and receipt.owner_user_id = new.owner_user_id
      and coalesce(
        private.email_import_provider_identifier_hash(
          'message', new.provider, new.provider_account_hash,
          page_item.value ->> 'providerMessageId'
        ) = new.provider_message_id_hash
        or (
          private.email_import_provider_identifier_hash(
            'thread', new.provider, new.provider_account_hash,
            page_item.value ->> 'providerThreadId'
          ) = new.provider_thread_id_hash
          and (
            page_item.value ->> 'sanitizedContentHash' =
              new.sanitized_content_hash
            or (
              jsonb_typeof(page_item.value -> 'candidate') = 'object'
              and private.email_import_semantic_fingerprint(
                page_item.value -> 'candidate'
              ) = new.semantic_fingerprint
            )
          )
        ),
        false
      )
  loop
    update private.email_import_sync_receipts receipt
    set items = (
        select coalesce(
          jsonb_agg(page_item.value order by page_item.ordinality),
          '[]'::jsonb
        )
        from jsonb_array_elements(receipt.items)
          with ordinality page_item(value, ordinality)
        where page_item.value ->> 'providerMessageId' <>
          v_provider_message_id
      ),
      item_message_id_hashes = array_remove(
        receipt.item_message_id_hashes,
        private.email_import_provider_identifier_hash(
          'message', new.provider, new.provider_account_hash,
          v_provider_message_id
        )
      ),
      suppressions = receipt.suppressions || jsonb_build_array(
        jsonb_build_object(
          'providerMessageIdHash', private.email_import_provider_identifier_hash(
            'message', new.provider, new.provider_account_hash,
            v_provider_message_id
          ),
          'reason', 'dismissed'
        )
      ),
      updated_at = clock_timestamp()
    where receipt.connection_id = new.connection_id
      and receipt.owner_user_id = new.owner_user_id
      and exists (
        select 1 from jsonb_array_elements(receipt.items) page_item
        where page_item ->> 'providerMessageId' = v_provider_message_id
      );
  end loop;
  update private.email_import_retry_receipts receipt
  set retry_outcome = 'suppressed',
      provider_message_id = null,
      item = null,
      suppression = jsonb_build_object(
        'providerMessageIdHash', receipt.provider_message_id_hash,
        'reason', 'dismissed'
      )
  where receipt.connection_id = new.connection_id
    and receipt.owner_user_id = new.owner_user_id
    and (
      receipt.provider_message_id_hash = new.provider_message_id_hash
      or (
        receipt.item is not null
        and private.email_import_provider_identifier_hash(
          'thread', new.provider, new.provider_account_hash,
          receipt.item ->> 'providerThreadId'
        ) = new.provider_thread_id_hash
        and (
          receipt.item ->> 'sanitizedContentHash' =
            new.sanitized_content_hash
          or (
            jsonb_typeof(receipt.item -> 'candidate') = 'object'
            and private.email_import_semantic_fingerprint(
              receipt.item -> 'candidate'
            ) = new.semantic_fingerprint
          )
        )
      )
    );
  return new;
end;
$$;

create trigger email_import_dismissals_clear_sync_receipt
after insert on private.email_import_dismissal_tombstones
for each row execute function private.email_import_clear_sync_receipt_on_dismissal();

create function private.email_import_clear_retry_receipt_on_source_delete()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, private
as $$
declare
  v_reason text;
begin
  delete from private.email_import_source_replacement_guards guard
  where guard.connection_id = old.connection_id
    and guard.owner_user_id = old.owner_user_id
    and guard.provider_message_id = old.provider_message_id
    and guard.transaction_id = txid_current();
  if found then
    return old;
  end if;
  select case when exists (
    select 1
    from private.email_import_dismissal_tombstones tombstone
    where tombstone.connection_id = old.connection_id
      and tombstone.owner_user_id = old.owner_user_id
      and (
        tombstone.provider_message_id_hash = old.provider_message_id_hash
        or (
          tombstone.provider_thread_id_hash = old.provider_thread_id_hash
          and tombstone.sanitized_content_hash = old.sanitized_content_hash
        )
      )
  ) then 'dismissed' else 'deduplicated' end
  into v_reason;
  update private.email_import_sync_receipts receipt
  set items = (
    select coalesce(
      jsonb_agg(page_item.value order by page_item.ordinality),
      '[]'::jsonb
    )
    from jsonb_array_elements(receipt.items)
      with ordinality page_item(value, ordinality)
    where page_item.value ->> 'providerMessageId' <> old.provider_message_id
  ),
  item_message_id_hashes = array_remove(
    receipt.item_message_id_hashes,
    old.provider_message_id_hash
  ),
  suppressions = receipt.suppressions || jsonb_build_array(
    jsonb_build_object(
      'providerMessageIdHash', old.provider_message_id_hash,
      'reason', v_reason
    )
  ),
  updated_at = clock_timestamp()
  where receipt.connection_id = old.connection_id
    and receipt.owner_user_id = old.owner_user_id
    and exists (
      select 1 from jsonb_array_elements(receipt.items) page_item
      where page_item ->> 'providerMessageId' = old.provider_message_id
    );
  update private.email_import_retry_receipts receipt
  set retry_outcome = 'suppressed',
      provider_message_id = null,
      item = null,
      suppression = jsonb_build_object(
        'providerMessageIdHash', old.provider_message_id_hash,
        'reason', v_reason
      )
  where receipt.connection_id = old.connection_id
    and receipt.owner_user_id = old.owner_user_id
    and receipt.provider_message_id_hash = old.provider_message_id_hash;
  return old;
end;
$$;

create trigger email_sources_clear_retry_receipt
after delete on public.email_sources
for each row execute function private.email_import_clear_retry_receipt_on_source_delete();

create function private.email_import_clear_receipts_on_disconnect()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, private
as $$
begin
  delete from private.email_import_sync_receipts
  where connection_id = new.id
    and owner_user_id = new.owner_user_id;
  delete from private.email_import_retry_receipts
  where connection_id = new.id
    and owner_user_id = new.owner_user_id;
  delete from private.email_import_source_replacement_guards
  where connection_id = new.id
    and owner_user_id = new.owner_user_id;
  return new;
end;
$$;

create trigger email_connections_clear_import_receipts_on_disconnect
after update of connection_state on public.email_connections
for each row
when (
  new.connection_state = 'disconnected'
  and old.connection_state is distinct from new.connection_state
)
execute function private.email_import_clear_receipts_on_disconnect();

revoke all on function public.email_import_persist_sync_page(
  uuid, uuid, text, text, jsonb, jsonb, boolean, timestamptz, uuid
) from public, anon, authenticated;
revoke all on function private.email_import_persist_sync_page_v2(
  uuid, uuid, text, text, jsonb, jsonb, boolean, timestamptz, uuid, boolean
) from public, anon, authenticated, service_role;
revoke all on function public.email_import_get_sync_replay(uuid, uuid, text)
from public, anon, authenticated;
revoke all on function public.email_import_get_owner_timezone(uuid, uuid)
from public, anon, authenticated;
revoke all on function public.email_import_get_retry_replay(uuid, uuid, text, text, text)
from public, anon, authenticated;
revoke all on function public.email_import_assert_retry_candidate(uuid, uuid, text, text)
from public, anon, authenticated;
revoke all on function public.email_import_persist_retry_candidate(
  uuid, uuid, jsonb, jsonb, text, text, timestamptz, uuid
) from public, anon, authenticated;
revoke all on function private.email_import_clear_sync_receipt_on_dismissal()
from public, anon, authenticated, service_role;
revoke all on function private.email_import_suppression_hashes(jsonb)
from public, anon, authenticated, service_role;
revoke all on function private.email_import_clear_retry_receipt_on_source_delete()
from public, anon, authenticated, service_role;
revoke all on function private.email_import_clear_receipts_on_disconnect()
from public, anon, authenticated, service_role;

grant execute on function public.email_import_persist_sync_page(
  uuid, uuid, text, text, jsonb, jsonb, boolean, timestamptz, uuid
) to service_role;
grant execute on function public.email_import_get_sync_replay(uuid, uuid, text)
to service_role;
grant execute on function public.email_import_get_owner_timezone(uuid, uuid)
to service_role;
grant execute on function public.email_import_get_retry_replay(uuid, uuid, text, text, text)
to service_role;
grant execute on function public.email_import_assert_retry_candidate(uuid, uuid, text, text)
to service_role;
grant execute on function public.email_import_persist_retry_candidate(
  uuid, uuid, jsonb, jsonb, text, text, timestamptz, uuid
) to service_role;

comment on function public.email_import_persist_sync_page(
  uuid, uuid, text, text, jsonb, jsonb, boolean, timestamptz, uuid
) is
  'Trusted owner-bound v2 sync persistence. Atomically stores safe successes, sanitized failures, cursor CAS, and bounded cursor-keyed private replay receipts.';
comment on function public.email_import_get_sync_replay(uuid, uuid, text) is
  'Trusted exact cursor-page replay lookup for a lost response; safe page data only.';
comment on function public.email_import_persist_retry_candidate(
  uuid, uuid, jsonb, jsonb, text, text, timestamptz, uuid
) is
  'Trusted failed-source retry persistence without changing the incremental cursor receipt.';

commit;
