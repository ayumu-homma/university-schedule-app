-- Phase 5F/G keeps provider credentials and OAuth transients outside exposed
-- schemas, exposes only safe owner-readable state, and funnels every trusted
-- mutation through narrowly granted service-role RPCs.
begin;

alter table private.email_connection_credentials
  add column credential_version bigint not null default 1;

alter table private.email_connection_credentials
  add constraint email_connection_credentials_version_valid
  check (credential_version > 0);

create or replace function private.email_import_provider_identifier_hash(
  p_kind text,
  p_provider text,
  p_provider_account_hash text,
  p_raw_identifier text
)
returns text
language sql
immutable
strict
set search_path = pg_catalog, extensions
as $$
  select encode(
    extensions.digest(
      convert_to('university-schedule-email-import-v1', 'UTF8')
        || decode('00', 'hex') || convert_to(p_kind, 'UTF8')
        || decode('00', 'hex') || convert_to(p_provider, 'UTF8')
        || decode('00', 'hex') || convert_to(p_provider_account_hash, 'UTF8')
        || decode('00', 'hex') || convert_to(p_raw_identifier, 'UTF8'),
      'sha256'
    ),
    'hex'
  );
$$;

alter table public.email_sources
  add column provider_message_id_hash text,
  add column provider_thread_id_hash text;

update public.email_sources s
set provider_message_id_hash = private.email_import_provider_identifier_hash(
      'message', c.provider, c.provider_account_hash, s.provider_message_id
    ),
    provider_thread_id_hash = case
      when s.provider_thread_id is null then null
      else private.email_import_provider_identifier_hash(
        'thread', c.provider, c.provider_account_hash, s.provider_thread_id
      )
    end
from public.email_connections c
where c.id = s.connection_id and c.owner_user_id = s.owner_user_id;

alter table public.email_sources
  alter column provider_message_id_hash set not null,
  add constraint email_sources_message_hash_format
    check (provider_message_id_hash ~ '^[0-9a-f]{64}$'),
  add constraint email_sources_thread_hash_format
    check (
      provider_thread_id_hash is null
      or provider_thread_id_hash ~ '^[0-9a-f]{64}$'
    ),
  add constraint email_sources_connection_message_hash_key
    unique (connection_id, provider_message_id_hash);

create index email_sources_thread_hash_idx
  on public.email_sources(connection_id, provider_thread_id_hash, received_at desc)
  where provider_thread_id_hash is not null;

create or replace function private.email_import_fill_source_hashes()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_provider text;
  v_account_hash text;
begin
  select provider, provider_account_hash into v_provider, v_account_hash
  from public.email_connections
  where id = new.connection_id;

  -- A missing connection still receives constraint-valid placeholders so the
  -- owner-bound connection FK remains the authoritative rejection. Valid
  -- rows always overwrite caller input with account-domain-separated hashes.
  if v_provider is null or v_account_hash is null then
    new.provider_message_id_hash := repeat('0', 64);
    new.provider_thread_id_hash := case
      when new.provider_thread_id is null then null else repeat('0', 64)
    end;
    return new;
  end if;

  new.provider_message_id_hash := private.email_import_provider_identifier_hash(
    'message', v_provider, v_account_hash, new.provider_message_id
  );
  new.provider_thread_id_hash := case
    when new.provider_thread_id is null then null
    else private.email_import_provider_identifier_hash(
      'thread', v_provider, v_account_hash, new.provider_thread_id
    )
  end;
  return new;
end;
$$;

create trigger email_sources_fill_identifier_hashes
before insert or update of
  connection_id,
  owner_user_id,
  provider_message_id,
  provider_thread_id,
  provider_message_id_hash,
  provider_thread_id_hash
on public.email_sources
for each row execute function private.email_import_fill_source_hashes();

alter table public.email_candidates
  add column confirmation_idempotency_key text;

update public.email_candidates
set confirmation_idempotency_key = 'legacy-server-confirmation-' || id::text
where review_state in ('confirmed', 'update_available');

alter table public.email_candidates
  add constraint email_candidates_confirmation_key_bounded
    check (
      confirmation_idempotency_key is null
      or (
        char_length(confirmation_idempotency_key) between 1 and 200
        and confirmation_idempotency_key = btrim(confirmation_idempotency_key)
      )
    ),
  add constraint email_candidates_confirmation_key_consistent
    check (
      (review_state in ('confirmed', 'update_available'))
      = (confirmation_idempotency_key is not null)
    );

create unique index email_candidates_owner_confirmation_key
  on public.email_candidates(owner_user_id, confirmation_idempotency_key)
  where confirmation_idempotency_key is not null;

alter table public.email_candidate_updates
  add column proposed_payload jsonb,
  add column base_entity_version bigint,
  add column resolution_idempotency_key text;

update public.email_candidate_updates
set resolution_idempotency_key = 'legacy-server-resolution-' || id::text
where resolution_state in ('accepted', 'rejected');

alter table public.email_candidate_updates
  add constraint email_candidate_updates_payload_bounded
    check (
      proposed_payload is null
      or (
        jsonb_typeof(proposed_payload) = 'object'
        and pg_column_size(proposed_payload) <= 65536
      )
    ),
  add constraint email_candidate_updates_base_version_valid
    check (base_entity_version is null or base_entity_version > 0),
  add constraint email_candidate_updates_resolution_key_bounded
    check (
      resolution_idempotency_key is null
      or (
        char_length(resolution_idempotency_key) between 1 and 200
        and resolution_idempotency_key = btrim(resolution_idempotency_key)
      )
    ),
  add constraint email_candidate_updates_resolution_key_consistent
    check (
      (resolution_state in ('accepted', 'rejected'))
      = (resolution_idempotency_key is not null)
    );

create unique index email_candidate_updates_owner_resolution_key
  on public.email_candidate_updates(owner_user_id, resolution_idempotency_key)
  where resolution_idempotency_key is not null;
create unique index email_candidate_updates_one_pending_per_candidate
  on public.email_candidate_updates(candidate_id)
  where resolution_state = 'pending';

create table private.email_import_dismissal_tombstones (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  connection_id uuid not null,
  provider text not null,
  provider_account_hash text not null,
  provider_message_id_hash text not null,
  provider_thread_id_hash text not null,
  sanitized_content_hash text not null,
  semantic_fingerprint text not null,
  dismissal_idempotency_key text not null,
  dismissed_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint email_import_dismissals_connection_owner_fk
    foreign key (connection_id, owner_user_id)
    references public.email_connections(id, owner_user_id)
    on delete cascade,
  constraint email_import_dismissals_provider_allowed check (provider = 'gmail'),
  constraint email_import_dismissals_hashes_valid check (
    provider_account_hash ~ '^[0-9a-f]{64}$'
    and provider_message_id_hash ~ '^[0-9a-f]{64}$'
    and provider_thread_id_hash ~ '^[0-9a-f]{64}$'
    and sanitized_content_hash ~ '^[0-9a-f]{64}$'
    and semantic_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  constraint email_import_dismissals_key_bounded check (
    char_length(dismissal_idempotency_key) between 1 and 200
    and dismissal_idempotency_key = btrim(dismissal_idempotency_key)
  ),
  constraint email_import_dismissals_message_key unique (
    owner_user_id, provider, provider_account_hash, provider_message_id_hash
  ),
  constraint email_import_dismissals_idempotency_key unique (
    owner_user_id, dismissal_idempotency_key
  )
);

create index email_import_dismissals_thread_content_idx
  on private.email_import_dismissal_tombstones(
    owner_user_id,
    provider,
    provider_account_hash,
    provider_thread_id_hash,
    sanitized_content_hash
  );
create index email_import_dismissals_thread_fingerprint_idx
  on private.email_import_dismissal_tombstones(
    owner_user_id,
    provider,
    provider_account_hash,
    provider_thread_id_hash,
    semantic_fingerprint
  );

create table private.email_import_reconciliation_receipts (
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  idempotency_key text not null,
  action text not null,
  request_hash text not null,
  response jsonb not null,
  created_at timestamptz not null default now(),
  primary key (owner_user_id, idempotency_key),
  constraint email_import_reconciliation_key_bounded check (
    char_length(idempotency_key) between 1 and 200
    and idempotency_key = btrim(idempotency_key)
  ),
  constraint email_import_reconciliation_action_allowed check (
    action in ('confirmation', 'dismissal', 'update')
  ),
  constraint email_import_reconciliation_request_hash_format
    check (request_hash ~ '^[0-9a-f]{64}$'),
  constraint email_import_reconciliation_response_object
    check (jsonb_typeof(response) = 'object')
);

alter table private.email_import_dismissal_tombstones enable row level security;
alter table private.email_import_reconciliation_receipts enable row level security;

revoke all on table private.email_import_dismissal_tombstones,
  private.email_import_reconciliation_receipts
from public, anon, authenticated, service_role;

comment on table private.email_import_dismissal_tombstones is
  'Minimal account-scoped hashes retained after an explicit dismissal; no raw provider identifiers or message content.';
comment on table private.email_import_reconciliation_receipts is
  'Trusted idempotency ledger for owner-bound email review reconciliation.';

create table private.email_oauth_sessions (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  connection_id uuid not null,
  state_hash text not null,
  encrypted_pkce_verifier bytea not null,
  encryption_key_version integer not null,
  expires_at timestamptz not null,
  correlation_id uuid not null,
  created_at timestamptz not null default now(),
  constraint email_oauth_sessions_connection_owner_fk
    foreign key (connection_id, owner_user_id)
    references public.email_connections(id, owner_user_id)
    on delete cascade,
  constraint email_oauth_sessions_state_hash_format
    check (state_hash ~ '^[0-9a-f]{64}$'),
  constraint email_oauth_sessions_ciphertext_bounded
    check (octet_length(encrypted_pkce_verifier) between 1 and 8192),
  constraint email_oauth_sessions_key_version_valid
    check (encryption_key_version > 0),
  constraint email_oauth_sessions_expiry_valid
    check (expires_at > created_at),
  constraint email_oauth_sessions_state_key unique (state_hash),
  constraint email_oauth_sessions_connection_key unique (connection_id)
);

create table public.email_import_audit_events (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  connection_id uuid,
  correlation_id uuid not null,
  operation text not null,
  outcome text not null,
  connection_state text,
  error_category text,
  occurred_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint email_import_audit_operation_allowed
    check (
      operation in (
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
    ),
  constraint email_import_audit_outcome_allowed
    check (outcome in ('started', 'succeeded', 'failed', 'already_revoked')),
  constraint email_import_audit_state_allowed
    check (
      connection_state is null
      or connection_state in (
        'disconnected',
        'connecting',
        'connected',
        'reauth_required',
        'rate_limited',
        'failed',
        'disconnecting'
      )
    ),
  constraint email_import_audit_error_allowed
    check (
      error_category is null
      or error_category in (
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
      )
    )
);

create index email_import_audit_owner_occurred_idx
  on public.email_import_audit_events(owner_user_id, occurred_at desc);

alter table private.email_oauth_sessions enable row level security;
alter table public.email_import_audit_events enable row level security;

create policy email_import_audit_owner_read
on public.email_import_audit_events for select to authenticated
using (owner_user_id = auth.uid());

revoke all on table private.email_oauth_sessions
from public, anon, authenticated, service_role;

revoke all on table public.email_import_audit_events
from public, anon, authenticated, service_role;

grant select on table public.email_import_audit_events to authenticated;

comment on table private.email_oauth_sessions is
  'Single-use encrypted Gmail OAuth PKCE state. Raw state and verifier are never stored.';
comment on table public.email_import_audit_events is
  'Owner-readable correlation and state transitions only; no tokens, addresses, provider identifiers, or message content.';

create or replace function private.email_import_write_audit(
  p_owner_user_id uuid,
  p_connection_id uuid,
  p_correlation_id uuid,
  p_operation text,
  p_outcome text,
  p_connection_state text,
  p_error_category text,
  p_occurred_at timestamptz
)
returns void
language sql
security definer
set search_path = pg_catalog, public, private
as $$
  insert into public.email_import_audit_events (
    owner_user_id,
    connection_id,
    correlation_id,
    operation,
    outcome,
    connection_state,
    error_category,
    occurred_at
  ) values (
    p_owner_user_id,
    p_connection_id,
    p_correlation_id,
    p_operation,
    p_outcome,
    p_connection_state,
    p_error_category,
    p_occurred_at
  );
$$;

create or replace function private.email_import_semantic_fingerprint(
  p_payload jsonb
)
returns text
language sql
immutable
strict
set search_path = pg_catalog, extensions
as $$
  select encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'candidate_type', p_payload -> 'candidate_type',
          'title', lower(regexp_replace(trim(coalesce(p_payload ->> 'title', '')), '\s+', ' ', 'g')),
          'course', lower(regexp_replace(trim(coalesce(
            p_payload #>> '{course_hint,code}',
            p_payload #>> '{course_hint,name}',
            ''
          )), '\s+', ' ', 'g')),
          'due_at', p_payload #> '{due,at}',
          'start_at', p_payload -> 'start_at',
          'submission_url', p_payload -> 'submission_url'
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
$$;

create or replace function private.email_import_candidate_diff(
  p_before jsonb,
  p_after jsonb
)
returns jsonb
language plpgsql
immutable
strict
set search_path = pg_catalog
as $$
declare
  v_field text;
  v_diff jsonb := '{}'::jsonb;
  v_before_fields jsonb;
  v_after_fields jsonb;
begin
  if p_before ->> 'candidate_type' is distinct from p_after ->> 'candidate_type' then
    return jsonb_build_object(
      'candidate_type',
      jsonb_build_object(
        'before', p_before -> 'candidate_type',
        'after', p_after -> 'candidate_type'
      )
    );
  end if;

  v_before_fields := case p_before ->> 'candidate_type'
    when 'assignment' then jsonb_build_object(
      'title', p_before -> 'title',
      'due_at', p_before #> '{due,at}',
      'due_all_day', p_before #> '{due,all_day}',
      'due_timezone', p_before #> '{due,timezone}',
      'submission_url', p_before -> 'submission_url',
      'summary', p_before -> 'summary',
      'suggested_reminders_minutes', p_before -> 'suggested_reminders_minutes'
    )
    when 'exam' then jsonb_build_object(
      'title', p_before -> 'title',
      'start_at', p_before -> 'start_at',
      'end_at', p_before -> 'end_at',
      'due_timezone', p_before #> '{due,timezone}',
      'location', p_before -> 'location',
      'summary', p_before -> 'summary',
      'suggested_reminders_minutes', p_before -> 'suggested_reminders_minutes'
    )
    when 'event' then jsonb_build_object(
      'title', p_before -> 'title',
      'start_at', p_before -> 'start_at',
      'end_at', p_before -> 'end_at',
      'due_timezone', p_before #> '{due,timezone}',
      'location', p_before -> 'location',
      'summary', p_before -> 'summary',
      'suggested_reminders_minutes', p_before -> 'suggested_reminders_minutes'
    )
    else '{}'::jsonb
  end;
  v_after_fields := case p_after ->> 'candidate_type'
    when 'assignment' then jsonb_build_object(
      'title', p_after -> 'title',
      'due_at', p_after #> '{due,at}',
      'due_all_day', p_after #> '{due,all_day}',
      'due_timezone', p_after #> '{due,timezone}',
      'submission_url', p_after -> 'submission_url',
      'summary', p_after -> 'summary',
      'suggested_reminders_minutes', p_after -> 'suggested_reminders_minutes'
    )
    when 'exam' then jsonb_build_object(
      'title', p_after -> 'title',
      'start_at', p_after -> 'start_at',
      'end_at', p_after -> 'end_at',
      'due_timezone', p_after #> '{due,timezone}',
      'location', p_after -> 'location',
      'summary', p_after -> 'summary',
      'suggested_reminders_minutes', p_after -> 'suggested_reminders_minutes'
    )
    when 'event' then jsonb_build_object(
      'title', p_after -> 'title',
      'start_at', p_after -> 'start_at',
      'end_at', p_after -> 'end_at',
      'due_timezone', p_after #> '{due,timezone}',
      'location', p_after -> 'location',
      'summary', p_after -> 'summary',
      'suggested_reminders_minutes', p_after -> 'suggested_reminders_minutes'
    )
    else '{}'::jsonb
  end;

  for v_field in select jsonb_object_keys(v_before_fields) loop
    if (v_before_fields -> v_field) is distinct from (v_after_fields -> v_field) then
      v_diff := v_diff || jsonb_build_object(
        v_field,
        jsonb_build_object(
          'before', v_before_fields -> v_field,
          'after', v_after_fields -> v_field
        )
      );
    end if;
  end loop;
  return v_diff;
end;
$$;

create or replace function private.email_import_update_fingerprint(
  p_payload jsonb
)
returns text
language sql
immutable
strict
set search_path = pg_catalog, extensions
as $$
  select encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'candidate_type', p_payload -> 'candidate_type',
          'course', coalesce(
            nullif(p_payload #> '{course_hint,code}', 'null'::jsonb),
            p_payload #> '{course_hint,name}'
          ),
          'fields', case p_payload ->> 'candidate_type'
            when 'assignment' then jsonb_build_object(
              'title', p_payload -> 'title',
              'due_at', p_payload #> '{due,at}',
              'due_all_day', p_payload #> '{due,all_day}',
              'due_timezone', p_payload #> '{due,timezone}',
              'submission_url', p_payload -> 'submission_url',
              'summary', p_payload -> 'summary',
              'suggested_reminders_minutes', p_payload -> 'suggested_reminders_minutes'
            )
            when 'exam' then jsonb_build_object(
              'title', p_payload -> 'title',
              'start_at', p_payload -> 'start_at',
              'end_at', p_payload -> 'end_at',
              'due_timezone', p_payload #> '{due,timezone}',
              'location', p_payload -> 'location',
              'summary', p_payload -> 'summary',
              'suggested_reminders_minutes', p_payload -> 'suggested_reminders_minutes'
            )
            when 'event' then jsonb_build_object(
              'title', p_payload -> 'title',
              'start_at', p_payload -> 'start_at',
              'end_at', p_payload -> 'end_at',
              'due_timezone', p_payload #> '{due,timezone}',
              'location', p_payload -> 'location',
              'summary', p_payload -> 'summary',
              'suggested_reminders_minutes', p_payload -> 'suggested_reminders_minutes'
            )
            else '{}'::jsonb
          end
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
$$;

create or replace function private.email_import_minimize_dismissed_candidate()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
begin
  if new.review_state <> 'dismissed' or old.review_state = 'dismissed' then
    return new;
  end if;
  if old.review_state in ('confirmed', 'update_available') then
    raise exception using errcode = '55000', message = 'A confirmed email candidate cannot be dismissed.';
  end if;

  new.semantic_fingerprint := coalesce(
    new.semantic_fingerprint,
    private.email_import_semantic_fingerprint(old.validated_payload)
  );
  new.validated_payload := '{}'::jsonb;
  new.error_category := null;
  new.linked_entity_type := null;
  new.linked_entity_id := null;
  new.confirmed_at := null;

  update public.email_sources
  set evidence_metadata = '[]'::jsonb,
      processing_state = 'ignored',
      error_category = null,
      updated_at = new.updated_at
  where id = new.source_id and owner_user_id = new.owner_user_id;

  return new;
end;
$$;

drop trigger if exists email_candidates_minimize_dismissed
on public.email_candidates;
create trigger email_candidates_minimize_dismissed
before update of review_state on public.email_candidates
for each row execute function private.email_import_minimize_dismissed_candidate();

revoke all on function private.email_import_write_audit(
  uuid, uuid, uuid, text, text, text, text, timestamptz
) from public, anon, authenticated, service_role;
revoke all on function private.email_import_semantic_fingerprint(jsonb)
from public, anon, authenticated, service_role;
revoke all on function private.email_import_candidate_diff(jsonb, jsonb)
from public, anon, authenticated, service_role;
revoke all on function private.email_import_update_fingerprint(jsonb)
from public, anon, authenticated, service_role;
revoke all on function private.email_import_minimize_dismissed_candidate()
from public, anon, authenticated, service_role;

create or replace function public.email_import_begin_oauth(
  p_owner_user_id uuid,
  p_connection_id uuid,
  p_state_hash text,
  p_encrypted_pkce_verifier bytea,
  p_encryption_key_version integer,
  p_expires_at timestamptz,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private, extensions
as $$
declare
  v_now timestamptz := clock_timestamp();
  v_pending_hash text;
begin
  if p_owner_user_id is null
    or p_connection_id is null
    or p_correlation_id is null
    or p_state_hash is null
    or p_state_hash !~ '^[0-9a-f]{64}$'
    or p_encrypted_pkce_verifier is null
    or octet_length(p_encrypted_pkce_verifier) not between 1 and 8192
    or p_encryption_key_version <= 0
    or p_expires_at <= v_now
    or p_expires_at > v_now + interval '15 minutes'
  then
    raise exception using errcode = '22023', message = 'Invalid email OAuth request.';
  end if;

  if not exists (select 1 from auth.users where id = p_owner_user_id) then
    raise exception using errcode = '22023', message = 'Invalid email OAuth owner.';
  end if;

  v_pending_hash := encode(
    extensions.digest(
      convert_to(
        'pending' || chr(31) || p_owner_user_id::text || chr(31) || p_connection_id::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  insert into public.email_connections (
    id,
    owner_user_id,
    provider,
    provider_account_hash,
    authorized_scopes,
    sync_cursor,
    connection_state,
    last_error_category,
    retry_after_at,
    connected_at,
    disconnected_at,
    created_at,
    updated_at
  ) values (
    p_connection_id,
    p_owner_user_id,
    'gmail',
    v_pending_hash,
    array['https://www.googleapis.com/auth/gmail.readonly']::text[],
    null,
    'connecting',
    null,
    null,
    null,
    null,
    v_now,
    v_now
  )
  on conflict (id) do update
  set connection_state = 'connecting',
      last_error_category = null,
      retry_after_at = null,
      disconnected_at = null,
      updated_at = v_now
  where email_connections.owner_user_id = excluded.owner_user_id
    and email_connections.provider = 'gmail';

  if not exists (
    select 1
    from public.email_connections
    where id = p_connection_id
      and owner_user_id = p_owner_user_id
      and provider = 'gmail'
  ) then
    raise exception using errcode = '42501', message = 'Email connection owner mismatch.';
  end if;

  delete from private.email_oauth_sessions
  where connection_id = p_connection_id
    or expires_at <= v_now;

  insert into private.email_oauth_sessions (
    owner_user_id,
    connection_id,
    state_hash,
    encrypted_pkce_verifier,
    encryption_key_version,
    expires_at,
    correlation_id,
    created_at
  ) values (
    p_owner_user_id,
    p_connection_id,
    p_state_hash,
    p_encrypted_pkce_verifier,
    p_encryption_key_version,
    p_expires_at,
    p_correlation_id,
    v_now
  );

  perform private.email_import_write_audit(
    p_owner_user_id,
    p_connection_id,
    p_correlation_id,
    'connect',
    'started',
    'connecting',
    null,
    v_now
  );

  return jsonb_build_object(
    'connection_id', p_connection_id,
    'expires_at', p_expires_at
  );
end;
$$;

create or replace function public.email_import_take_oauth(
  p_state_hash text,
  p_consumed_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_session private.email_oauth_sessions%rowtype;
begin
  if p_state_hash !~ '^[0-9a-f]{64}$' or p_consumed_at is null then
    return null;
  end if;

  delete from private.email_oauth_sessions
  where id = (
    select id
    from private.email_oauth_sessions
    where state_hash = p_state_hash
      and expires_at > p_consumed_at
    for update skip locked
    limit 1
  )
  returning * into v_session;

  if v_session.id is null then
    return null;
  end if;

  return jsonb_build_object(
    'owner_user_id', v_session.owner_user_id,
    'connection_id', v_session.connection_id,
    'encrypted_pkce_verifier_base64', encode(v_session.encrypted_pkce_verifier, 'base64'),
    'encryption_key_version', v_session.encryption_key_version,
    'expires_at', v_session.expires_at,
    'correlation_id', v_session.correlation_id
  );
end;
$$;

create or replace function public.email_import_complete_oauth(
  p_owner_user_id uuid,
  p_connection_id uuid,
  p_provider_account_hash text,
  p_authorized_scopes text[],
  p_encrypted_oauth_bundle bytea,
  p_encryption_key_version integer,
  p_expires_at timestamptz,
  p_initial_sync_cursor text,
  p_connected_at timestamptz,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_effective_connection_id uuid;
  v_existing_connection_id uuid;
begin
  if p_owner_user_id is null
    or p_connection_id is null
    or p_correlation_id is null
    or p_provider_account_hash is null
    or p_provider_account_hash !~ '^[0-9a-f]{64}$'
    or p_authorized_scopes is distinct from array['https://www.googleapis.com/auth/gmail.readonly']::text[]
    or p_encrypted_oauth_bundle is null
    or octet_length(p_encrypted_oauth_bundle) not between 1 and 65536
    or p_encryption_key_version <= 0
    or p_expires_at is null
    or p_connected_at is null
    or (p_initial_sync_cursor is not null and (
      char_length(p_initial_sync_cursor) not between 1 and 4096
      or p_initial_sync_cursor <> btrim(p_initial_sync_cursor)
    ))
  then
    raise exception using errcode = '22023', message = 'Invalid email OAuth completion.';
  end if;

  if not exists (
    select 1
    from public.email_connections
    where id = p_connection_id
      and owner_user_id = p_owner_user_id
      and provider = 'gmail'
      and connection_state = 'connecting'
  ) then
    raise exception using errcode = '42501', message = 'Email connection owner mismatch.';
  end if;

  select id into v_existing_connection_id
  from public.email_connections
  where owner_user_id = p_owner_user_id
    and provider = 'gmail'
    and provider_account_hash = p_provider_account_hash
    and id <> p_connection_id
  for update;

  v_effective_connection_id := coalesce(v_existing_connection_id, p_connection_id);

  if v_existing_connection_id is not null then
    delete from public.email_connections
    where id = p_connection_id
      and owner_user_id = p_owner_user_id;
  end if;

  update public.email_connections
  set provider_account_hash = p_provider_account_hash,
      authorized_scopes = p_authorized_scopes,
      sync_cursor = p_initial_sync_cursor,
      connection_state = 'connected',
      last_error_category = null,
      retry_after_at = null,
      connected_at = p_connected_at,
      last_synced_at = null,
      disconnected_at = null,
      updated_at = p_connected_at
  where id = v_effective_connection_id
    and owner_user_id = p_owner_user_id;

  insert into private.email_connection_credentials (
    connection_id,
    owner_user_id,
    encrypted_oauth_bundle,
    encryption_key_version,
    credential_version,
    expires_at,
    created_at,
    updated_at
  ) values (
    v_effective_connection_id,
    p_owner_user_id,
    p_encrypted_oauth_bundle,
    p_encryption_key_version,
    1,
    p_expires_at,
    p_connected_at,
    p_connected_at
  )
  on conflict (connection_id) do update
  set encrypted_oauth_bundle = excluded.encrypted_oauth_bundle,
      encryption_key_version = excluded.encryption_key_version,
      credential_version = private.email_connection_credentials.credential_version + 1,
      expires_at = excluded.expires_at,
      updated_at = excluded.updated_at
  where private.email_connection_credentials.owner_user_id = p_owner_user_id;

  perform private.email_import_write_audit(
    p_owner_user_id,
    v_effective_connection_id,
    p_correlation_id,
    'oauth_callback',
    'succeeded',
    'connected',
    null,
    p_connected_at
  );

  return (
    select jsonb_build_object(
      'connection_id', c.id,
      'connection_state', c.connection_state,
      'sync_cursor', c.sync_cursor,
      'connected_at', c.connected_at,
      'credential_version', k.credential_version
    )
    from public.email_connections c
    join private.email_connection_credentials k
      on k.connection_id = c.id and k.owner_user_id = c.owner_user_id
    where c.id = v_effective_connection_id
      and c.owner_user_id = p_owner_user_id
  );
end;
$$;

create or replace function public.email_import_get_credentials(
  p_owner_user_id uuid,
  p_connection_id uuid
)
returns jsonb
language sql
security definer
stable
set search_path = pg_catalog, public, private
as $$
  select jsonb_build_object(
    'connection_id', c.id,
    'provider', c.provider,
    'provider_account_hash', c.provider_account_hash,
    'connection_state', c.connection_state,
    'sync_cursor', c.sync_cursor,
    'connected_at', c.connected_at,
    'encrypted_oauth_bundle_base64', encode(k.encrypted_oauth_bundle, 'base64'),
    'encryption_key_version', k.encryption_key_version,
    'credential_version', k.credential_version,
    'expires_at', k.expires_at
  )
  from public.email_connections c
  join private.email_connection_credentials k
    on k.connection_id = c.id and k.owner_user_id = c.owner_user_id
  where c.id = p_connection_id
    and c.owner_user_id = p_owner_user_id
    and c.provider = 'gmail';
$$;

create or replace function public.email_import_rotate_credentials(
  p_owner_user_id uuid,
  p_connection_id uuid,
  p_expected_credential_version bigint,
  p_encrypted_oauth_bundle bytea,
  p_encryption_key_version integer,
  p_expires_at timestamptz,
  p_rotated_at timestamptz,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_version bigint;
begin
  if p_owner_user_id is null
    or p_connection_id is null
    or p_expected_credential_version <= 0
    or p_encrypted_oauth_bundle is null
    or octet_length(p_encrypted_oauth_bundle) not between 1 and 65536
    or p_encryption_key_version <= 0
    or p_expires_at is null
    or p_rotated_at is null
    or p_correlation_id is null
  then
    raise exception using errcode = '22023', message = 'Invalid credential rotation.';
  end if;

  update private.email_connection_credentials
  set encrypted_oauth_bundle = p_encrypted_oauth_bundle,
      encryption_key_version = p_encryption_key_version,
      credential_version = credential_version + 1,
      expires_at = p_expires_at,
      updated_at = p_rotated_at
  where connection_id = p_connection_id
    and owner_user_id = p_owner_user_id
    and credential_version = p_expected_credential_version
  returning credential_version into v_version;

  if v_version is null then
    raise exception using errcode = '40001', message = 'Credential state changed.';
  end if;

  update public.email_connections
  set connection_state = 'connected',
      last_error_category = null,
      retry_after_at = null,
      updated_at = p_rotated_at
  where id = p_connection_id
    and owner_user_id = p_owner_user_id;

  perform private.email_import_write_audit(
    p_owner_user_id,
    p_connection_id,
    p_correlation_id,
    'refresh',
    'succeeded',
    'connected',
    null,
    p_rotated_at
  );

  return jsonb_build_object(
    'connection_id', p_connection_id,
    'credential_version', v_version,
    'expires_at', p_expires_at
  );
end;
$$;

create or replace function public.email_import_persist_sync_page(
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
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_connection public.email_connections%rowtype;
  v_source jsonb;
  v_candidate_entry jsonb;
  v_payload jsonb;
  v_source_id uuid;
  v_existing_source_id uuid;
  v_existing_hash text;
  v_provider_message_id text;
  v_provider_thread_id text;
  v_received_at timestamptz;
  v_content_hash text;
  v_message_hash text;
  v_thread_hash text;
  v_evidence jsonb;
  v_fingerprint text;
  v_update_fingerprint text;
  v_candidate_type text;
  v_candidate_state text;
  v_base_candidate_id uuid;
  v_base_payload jsonb;
  v_base_entity_type text;
  v_base_entity_id uuid;
  v_base_entity_version bigint;
  v_field_diff jsonb;
  v_item_count integer;
begin
  if p_owner_user_id is null
    or p_connection_id is null
    or p_has_more is null
    or p_synced_at is null
    or p_correlation_id is null
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
  then
    raise exception using errcode = '22023', message = 'Invalid email sync page.';
  end if;

  if (
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
      or (select count(*) from jsonb_object_keys(v_source)) <> 5
      or not (v_source ?& array[
        'provider_message_id',
        'provider_thread_id',
        'received_at',
        'sanitized_content_hash',
        'evidence_metadata'
      ])
    then
      raise exception using errcode = '22023', message = 'Invalid email source metadata.';
    end if;

    v_provider_message_id := v_source ->> 'provider_message_id';
    v_provider_thread_id := v_source ->> 'provider_thread_id';
    v_content_hash := v_source ->> 'sanitized_content_hash';
    v_evidence := v_source -> 'evidence_metadata';

    if v_provider_message_id is null
      or char_length(v_provider_message_id) not between 1 and 1024
      or v_provider_message_id <> btrim(v_provider_message_id)
      or v_provider_message_id ~ '[[:space:][:cntrl:]]'
      or v_provider_thread_id is null
      or char_length(v_provider_thread_id) not between 1 and 1024
      or v_provider_thread_id <> btrim(v_provider_thread_id)
      or v_provider_thread_id ~ '[[:space:][:cntrl:]]'
      or v_content_hash is null
      or v_content_hash !~ '^[0-9a-f]{64}$'
      or jsonb_typeof(v_evidence) <> 'array'
      or jsonb_array_length(v_evidence) > 8
      or pg_column_size(v_evidence) > 8192
      or exists (
        select 1
        from jsonb_array_elements(v_evidence) evidence
        where jsonb_typeof(evidence) <> 'string'
          or char_length(evidence #>> '{}') not between 1 and 512
      )
    then
      raise exception using errcode = '22023', message = 'Invalid email source metadata.';
    end if;

    begin
      v_received_at := (v_source ->> 'received_at')::timestamptz;
    exception when others then
      raise exception using errcode = '22023', message = 'Invalid email source metadata.';
    end;

    select value into v_candidate_entry
    from jsonb_array_elements(p_candidates)
    where value ->> 'provider_message_id' = v_provider_message_id;

    if v_candidate_entry is null
      or jsonb_typeof(v_candidate_entry) <> 'object'
      or (select count(*) from jsonb_object_keys(v_candidate_entry)) <> 2
      or not (v_candidate_entry ?& array['provider_message_id', 'validated_payload'])
    then
      raise exception using errcode = '22023', message = 'Invalid email candidate metadata.';
    end if;

    v_payload := v_candidate_entry -> 'validated_payload';
    v_candidate_type := v_payload ->> 'candidate_type';
    if v_payload is null
      or jsonb_typeof(v_payload) <> 'object'
      or pg_column_size(v_payload) > 65536
      or v_payload ->> 'schema_version' <> '1.0'
      or v_candidate_type not in ('assignment', 'exam', 'event', 'announcement', 'unknown')
      or v_payload -> 'requires_user_confirmation' <> 'true'::jsonb
    then
      raise exception using errcode = '22023', message = 'Invalid email candidate metadata.';
    end if;

    v_fingerprint := private.email_import_semantic_fingerprint(v_payload);
    v_message_hash := private.email_import_provider_identifier_hash(
      'message', v_connection.provider, v_connection.provider_account_hash,
      v_provider_message_id
    );
    v_thread_hash := private.email_import_provider_identifier_hash(
      'thread', v_connection.provider, v_connection.provider_account_hash,
      v_provider_thread_id
    );

    -- A reconciliation tombstone is deliberately checked before any source
    -- row is inserted so a dismissed repeat cannot restore raw identifiers or
    -- review payloads on the server.
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
            and (
              d.sanitized_content_hash = v_content_hash
              or d.semantic_fingerprint = v_fingerprint
            )
          )
        )
    ) then
      continue;
    end if;

    select id, sanitized_content_hash
      into v_existing_source_id, v_existing_hash
    from public.email_sources
    where connection_id = p_connection_id
      and provider_message_id = v_provider_message_id;

    if v_existing_source_id is not null then
      if v_existing_hash <> v_content_hash then
        raise exception using errcode = '22023', message = 'Email source identity changed.';
      end if;
      continue;
    end if;

    insert into public.email_sources (
      owner_user_id,
      connection_id,
      provider_message_id,
      provider_thread_id,
      provider_message_id_hash,
      provider_thread_id_hash,
      received_at,
      sanitized_content_hash,
      evidence_metadata,
      processing_state,
      created_at,
      updated_at
    ) values (
      p_owner_user_id,
      p_connection_id,
      v_provider_message_id,
      v_provider_thread_id,
      v_message_hash,
      v_thread_hash,
      v_received_at,
      v_content_hash,
      v_evidence,
      'processed',
      p_synced_at,
      p_synced_at
    ) returning id into v_source_id;

    -- A dismissed candidate suppresses only exact/same-thread repeats. A
    -- similar message from another thread remains independently reviewable.
    if exists (
      select 1
      from public.email_candidates c
      join public.email_sources s
        on s.id = c.source_id and s.owner_user_id = c.owner_user_id
      where c.owner_user_id = p_owner_user_id
        and s.connection_id = p_connection_id
        and s.provider_thread_id = v_provider_thread_id
        and c.review_state = 'dismissed'
        and (
          s.sanitized_content_hash = v_content_hash
          or c.semantic_fingerprint = v_fingerprint
        )
    ) then
      update public.email_sources
      set processing_state = 'ignored', updated_at = p_synced_at
      where id = v_source_id and owner_user_id = p_owner_user_id;
      continue;
    end if;

    v_base_candidate_id := null;
    select c.id, c.validated_payload, c.linked_entity_type, c.linked_entity_id
      into v_base_candidate_id, v_base_payload, v_base_entity_type, v_base_entity_id
    from public.email_candidates c
    join public.email_sources s
      on s.id = c.source_id and s.owner_user_id = c.owner_user_id
    where c.owner_user_id = p_owner_user_id
      and s.connection_id = p_connection_id
      and s.provider_thread_id = v_provider_thread_id
      and c.candidate_type = v_candidate_type
      and c.review_state in ('confirmed', 'update_available')
      and c.confirmed_at is not null
    order by c.confirmed_at desc, c.created_at desc
    limit 1;

    if v_base_candidate_id is not null then
      v_base_entity_version := case v_base_entity_type
        when 'assignment' then (
          select version from public.assignments
          where id = v_base_entity_id
            and owner_user_id = p_owner_user_id
            and visibility_level = 'PRIVATE'
            and deleted_at is null
        )
        when 'exam' then (
          select version from public.exams
          where id = v_base_entity_id
            and owner_user_id = p_owner_user_id
            and visibility_level = 'PRIVATE'
            and deleted_at is null
        )
        when 'event' then (
          select version from public.events
          where id = v_base_entity_id
            and owner_user_id = p_owner_user_id
            and visibility_level = 'PRIVATE'
            and deleted_at is null
        )
      end;
      if v_base_entity_version is null then
        raise exception using errcode = '55000', message = 'Linked schedule entity is unavailable.';
      end if;

      v_field_diff := private.email_import_candidate_diff(v_base_payload, v_payload);
      if v_field_diff = '{}'::jsonb then
        -- A newer message can revert a pending proposal back to the already
        -- confirmed payload. Resolve the stale proposal and restore the
        -- confirmed review state; never leave an obsolete update actionable.
        update public.email_candidate_updates
        set resolution_state = 'superseded',
            resolved_at = p_synced_at,
            updated_at = p_synced_at
        where candidate_id = v_base_candidate_id
          and owner_user_id = p_owner_user_id
          and resolution_state = 'pending';

        update public.email_candidates
        set review_state = 'confirmed', updated_at = p_synced_at
        where id = v_base_candidate_id
          and owner_user_id = p_owner_user_id
          and review_state = 'update_available';

        update public.email_sources
        set processing_state = 'ignored', updated_at = p_synced_at
        where id = v_source_id and owner_user_id = p_owner_user_id;
        continue;
      end if;

      v_update_fingerprint := private.email_import_update_fingerprint(v_payload);
      if exists (
        select 1
        from public.email_candidate_updates
        where candidate_id = v_base_candidate_id
          and owner_user_id = p_owner_user_id
          and proposal_fingerprint = v_update_fingerprint
      ) then
        update public.email_sources
        set evidence_metadata = '[]'::jsonb,
            processing_state = 'ignored',
            updated_at = p_synced_at
        where id = v_source_id and owner_user_id = p_owner_user_id;
        continue;
      end if;

      update public.email_candidate_updates
      set resolution_state = 'superseded',
          resolved_at = p_synced_at,
          updated_at = p_synced_at
      where candidate_id = v_base_candidate_id
        and owner_user_id = p_owner_user_id
        and resolution_state = 'pending';

      insert into public.email_candidate_updates (
        owner_user_id,
        candidate_id,
        source_id,
        proposal_fingerprint,
        field_diff,
        proposed_payload,
        base_entity_version,
        resolution_state,
        created_at,
        updated_at
      ) values (
        p_owner_user_id,
        v_base_candidate_id,
        v_source_id,
        v_update_fingerprint,
        v_field_diff,
        v_payload,
        v_base_entity_version,
        'pending',
        p_synced_at,
        p_synced_at
      )
      on conflict (candidate_id, source_id) do nothing;

      update public.email_candidates
      set review_state = 'update_available', updated_at = p_synced_at
      where id = v_base_candidate_id
        and owner_user_id = p_owner_user_id
        and review_state in ('confirmed', 'update_available');
      continue;
    end if;

    v_candidate_state := case
      when coalesce(nullif(btrim(v_payload ->> 'title'), ''), '') <> ''
        and jsonb_typeof(v_payload -> 'warnings') = 'array'
        and jsonb_array_length(v_payload -> 'warnings') = 0
        and case v_candidate_type
          when 'assignment' then v_payload #> '{due,at}' <> 'null'::jsonb
          when 'exam' then v_payload -> 'start_at' <> 'null'::jsonb
            and v_payload -> 'end_at' <> 'null'::jsonb
          when 'event' then v_payload -> 'start_at' <> 'null'::jsonb
            and v_payload -> 'end_at' <> 'null'::jsonb
          else false
        end
      then 'ready_for_review'
      else 'needs_review'
    end;

    insert into public.email_candidates (
      owner_user_id,
      source_id,
      schema_version,
      candidate_type,
      validated_payload,
      review_state,
      semantic_fingerprint,
      requires_user_confirmation,
      created_at,
      updated_at
    ) values (
      p_owner_user_id,
      v_source_id,
      '1.0',
      v_candidate_type,
      v_payload,
      v_candidate_state,
      v_fingerprint,
      true,
      p_synced_at,
      p_synced_at
    );
  end loop;

  update public.email_connections
  set sync_cursor = p_next_cursor,
      connection_state = 'connected',
      last_error_category = null,
      retry_after_at = null,
      last_synced_at = p_synced_at,
      updated_at = p_synced_at
  where id = p_connection_id
    and owner_user_id = p_owner_user_id;

  perform private.email_import_write_audit(
    p_owner_user_id,
    p_connection_id,
    p_correlation_id,
    'fetch',
    'succeeded',
    'connected',
    null,
    p_synced_at
  );

  return (
    select jsonb_build_object(
      'connection_id', id,
      'connection_state', connection_state,
      'sync_cursor', sync_cursor,
      'connected_at', connected_at,
      'last_synced_at', last_synced_at
    )
    from public.email_connections
    where id = p_connection_id and owner_user_id = p_owner_user_id
  );
end;
$$;

create or replace function private.email_import_schedule_entity_matches(
  p_owner_user_id uuid,
  p_entity_type text,
  p_entity_id uuid,
  p_payload jsonb,
  p_expected_version bigint
)
returns boolean
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_title text;
  v_due_at timestamptz;
  v_start_at timestamptz;
  v_end_at timestamptz;
begin
  if p_owner_user_id is null
    or p_entity_id is null
    or p_expected_version is null
    or p_expected_version < 1
    or p_entity_type not in ('assignment', 'exam', 'event')
    or p_payload is null
    or jsonb_typeof(p_payload) <> 'object'
    or pg_column_size(p_payload) > 65536
    or p_payload ->> 'schema_version' <> '1.0'
    or p_payload ->> 'candidate_type' <> p_entity_type
    or p_payload -> 'requires_user_confirmation' <> 'true'::jsonb
  then
    return false;
  end if;

  v_title := nullif(btrim(p_payload ->> 'title'), '');
  if v_title is null then return false; end if;

  if p_entity_type = 'assignment' then
    v_due_at := (p_payload #>> '{due,at}')::timestamptz;
    return exists (
      select 1
      from public.assignments a
      where a.id = p_entity_id
        and a.owner_user_id = p_owner_user_id
        and a.deleted_at is null
        and a.visibility_level = 'PRIVATE'
        and a.version = p_expected_version
        and a.title = v_title
        and a.due_at = v_due_at
        and a.description is not distinct from (p_payload ->> 'summary')
        and a.submission_url is not distinct from (p_payload ->> 'submission_url')
    );
  end if;

  v_start_at := (p_payload ->> 'start_at')::timestamptz;
  v_end_at := (p_payload ->> 'end_at')::timestamptz;
  if v_end_at <= v_start_at then return false; end if;

  if p_entity_type = 'exam' then
    return exists (
      select 1
      from public.exams e
      where e.id = p_entity_id
        and e.owner_user_id = p_owner_user_id
        and e.deleted_at is null
        and e.visibility_level = 'PRIVATE'
        and e.version = p_expected_version
        and e.title = v_title
        and e.start_at = v_start_at
        and e.end_at = v_end_at
        and e.room is not distinct from (p_payload ->> 'location')
        and e.memo is not distinct from (p_payload ->> 'summary')
    );
  end if;

  return exists (
    select 1
    from public.events e
    where e.id = p_entity_id
      and e.owner_user_id = p_owner_user_id
      and e.deleted_at is null
      and e.visibility_level = 'PRIVATE'
      and e.group_id is null
      and e.kind = 'normal'
      and e.timezone = 'Asia/Tokyo'
      and e.version = p_expected_version
      and e.title = v_title
      and e.start_at = v_start_at
      and e.end_at = v_end_at
      and e.location is not distinct from (p_payload ->> 'location')
      and e.description is not distinct from (p_payload ->> 'summary')
  );
exception when others then
  return false;
end;
$$;

create or replace function public.email_import_reconcile_confirmation(
  p_owner_user_id uuid,
  p_connection_id uuid,
  p_provider text,
  p_provider_account_hash text,
  p_provider_message_id_hash text,
  p_provider_thread_id_hash text,
  p_sanitized_content_hash text,
  p_reviewed_payload jsonb,
  p_entity_type text,
  p_entity_id uuid,
  p_idempotency_key text,
  p_reconciled_at timestamptz,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private, extensions
as $$
declare
  v_connection public.email_connections%rowtype;
  v_source public.email_sources%rowtype;
  v_candidate public.email_candidates%rowtype;
  v_schedule_receipt jsonb;
  v_schedule_version bigint;
  v_request_hash text;
  v_stored_hash text;
  v_stored_response jsonb;
  v_response jsonb;
begin
  if p_owner_user_id is null
    or p_connection_id is null
    or p_provider is null
    or p_provider <> 'gmail'
    or p_provider_account_hash is null
    or p_provider_account_hash !~ '^[0-9a-f]{64}$'
    or p_provider_message_id_hash is null
    or p_provider_message_id_hash !~ '^[0-9a-f]{64}$'
    or p_provider_thread_id_hash is null
    or p_provider_thread_id_hash !~ '^[0-9a-f]{64}$'
    or p_sanitized_content_hash is null
    or p_sanitized_content_hash !~ '^[0-9a-f]{64}$'
    or p_entity_type is null
    or p_entity_type not in ('assignment', 'exam', 'event')
    or p_entity_id is null
    or p_idempotency_key is null
    or char_length(p_idempotency_key) not between 1 and 200
    or p_idempotency_key <> btrim(p_idempotency_key)
    or p_reviewed_payload is null
    or jsonb_typeof(p_reviewed_payload) <> 'object'
    or pg_column_size(p_reviewed_payload) > 65536
    or p_reviewed_payload ->> 'schema_version' <> '1.0'
    or p_reviewed_payload ->> 'candidate_type' <> p_entity_type
    or p_reviewed_payload -> 'requires_user_confirmation' <> 'true'::jsonb
    or p_reconciled_at is null
    or not isfinite(p_reconciled_at)
    or p_correlation_id is null
  then
    raise exception using errcode = '22023', message = 'Invalid email confirmation reconciliation.';
  end if;

  v_request_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'connection_id', p_connection_id,
    'provider', p_provider,
    'provider_account_hash', p_provider_account_hash,
    'provider_message_id_hash', p_provider_message_id_hash,
    'provider_thread_id_hash', p_provider_thread_id_hash,
    'sanitized_content_hash', p_sanitized_content_hash,
    'reviewed_payload', p_reviewed_payload,
    'entity_type', p_entity_type,
    'entity_id', p_entity_id
  )::text, 'UTF8'), 'sha256'), 'hex');

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_owner_user_id::text || ':email-reconcile:' || p_idempotency_key, 0
  ));
  select request_hash, response into v_stored_hash, v_stored_response
  from private.email_import_reconciliation_receipts
  where owner_user_id = p_owner_user_id and idempotency_key = p_idempotency_key;
  if found then
    if v_stored_hash <> v_request_hash then
      raise exception using errcode = '23505', message = 'Email reconciliation idempotency key was reused.';
    end if;
    return jsonb_set(v_stored_response, '{replayed}', 'true'::jsonb, true);
  end if;

  select * into v_connection
  from public.email_connections
  where id = p_connection_id
    and owner_user_id = p_owner_user_id
    and provider = p_provider
    and provider_account_hash = p_provider_account_hash
  for update;
  if v_connection.id is null then
    raise exception using errcode = '42501', message = 'Email connection owner mismatch.';
  end if;

  select * into v_source
  from public.email_sources
  where owner_user_id = p_owner_user_id
    and connection_id = p_connection_id
    and provider_message_id_hash = p_provider_message_id_hash
    and provider_thread_id_hash = p_provider_thread_id_hash
    and sanitized_content_hash = p_sanitized_content_hash
  for update;
  if v_source.id is not null then
    select * into v_candidate
    from public.email_candidates
    where owner_user_id = p_owner_user_id and source_id = v_source.id
    for update;
  end if;
  if v_source.id is null or v_candidate.id is null then
    raise exception using errcode = '42501', message = 'Email review source mismatch.';
  end if;
  if v_candidate.review_state not in ('needs_review', 'ready_for_review')
    or v_candidate.candidate_type <> p_entity_type
  then
    raise exception using errcode = '55000', message = 'Email candidate is not confirmable.';
  end if;

  select response into v_schedule_receipt
  from private.schedule_mutation_receipts
  where owner_user_id = p_owner_user_id
    and idempotency_key = p_idempotency_key;
  if v_schedule_receipt is null
    or v_schedule_receipt ->> 'outcome' <> 'applied'
    or v_schedule_receipt ->> 'operation' <> 'create'
    or v_schedule_receipt ->> 'entity_type' <> p_entity_type
    or v_schedule_receipt ->> 'entity_id' <> p_entity_id::text
  then
    raise exception using errcode = '55000', message = 'Confirmed schedule mutation is unavailable.';
  end if;
  begin
    v_schedule_version := (v_schedule_receipt ->> 'server_version')::bigint;
  exception when others then
    raise exception using errcode = '55000', message = 'Confirmed schedule mutation is unavailable.';
  end;
  if not private.email_import_schedule_entity_matches(
    p_owner_user_id, p_entity_type, p_entity_id, p_reviewed_payload,
    v_schedule_version
  ) then
    raise exception using errcode = '55000', message = 'Confirmed schedule entity does not match the reviewed payload.';
  end if;

  update public.email_candidates
  set candidate_type = p_entity_type,
      validated_payload = p_reviewed_payload,
      review_state = 'confirmed',
      semantic_fingerprint = private.email_import_semantic_fingerprint(p_reviewed_payload),
      linked_entity_type = p_entity_type,
      linked_entity_id = p_entity_id,
      confirmation_idempotency_key = p_idempotency_key,
      error_category = null,
      confirmed_at = p_reconciled_at,
      dismissed_at = null,
      updated_at = p_reconciled_at
  where id = v_candidate.id and owner_user_id = p_owner_user_id;

  update public.email_sources
  set processing_state = 'processed', error_category = null, updated_at = p_reconciled_at
  where id = v_source.id and owner_user_id = p_owner_user_id;

  perform private.email_import_write_audit(
    p_owner_user_id, p_connection_id, p_correlation_id,
    'confirm', 'succeeded', null, null, p_reconciled_at
  );
  v_response := jsonb_build_object(
    'connection_id', p_connection_id,
    'connection_state', v_connection.connection_state,
    'action', 'confirmation',
    'outcome', 'confirmed',
    'entity_type', p_entity_type,
    'entity_id', p_entity_id,
    'replayed', false
  );
  insert into private.email_import_reconciliation_receipts(
    owner_user_id, idempotency_key, action, request_hash, response, created_at
  ) values (
    p_owner_user_id, p_idempotency_key, 'confirmation', v_request_hash,
    v_response, p_reconciled_at
  );
  return v_response;
end;
$$;

create or replace function public.email_import_reconcile_dismissal(
  p_owner_user_id uuid,
  p_connection_id uuid,
  p_provider text,
  p_provider_account_hash text,
  p_provider_message_id_hash text,
  p_provider_thread_id_hash text,
  p_sanitized_content_hash text,
  p_idempotency_key text,
  p_reconciled_at timestamptz,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private, extensions
as $$
declare
  v_connection public.email_connections%rowtype;
  v_source public.email_sources%rowtype;
  v_candidate public.email_candidates%rowtype;
  v_request_hash text;
  v_stored_hash text;
  v_stored_response jsonb;
  v_response jsonb;
begin
  if p_owner_user_id is null
    or p_connection_id is null
    or p_provider is null
    or p_provider <> 'gmail'
    or p_provider_account_hash is null
    or p_provider_account_hash !~ '^[0-9a-f]{64}$'
    or p_provider_message_id_hash is null
    or p_provider_message_id_hash !~ '^[0-9a-f]{64}$'
    or p_provider_thread_id_hash is null
    or p_provider_thread_id_hash !~ '^[0-9a-f]{64}$'
    or p_sanitized_content_hash is null
    or p_sanitized_content_hash !~ '^[0-9a-f]{64}$'
    or p_idempotency_key is null
    or char_length(p_idempotency_key) not between 1 and 200
    or p_idempotency_key <> btrim(p_idempotency_key)
    or p_reconciled_at is null
    or not isfinite(p_reconciled_at)
    or p_correlation_id is null
  then
    raise exception using errcode = '22023', message = 'Invalid email dismissal reconciliation.';
  end if;

  v_request_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'connection_id', p_connection_id,
    'provider', p_provider,
    'provider_account_hash', p_provider_account_hash,
    'provider_message_id_hash', p_provider_message_id_hash,
    'provider_thread_id_hash', p_provider_thread_id_hash,
    'sanitized_content_hash', p_sanitized_content_hash
  )::text, 'UTF8'), 'sha256'), 'hex');

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_owner_user_id::text || ':email-reconcile:' || p_idempotency_key, 0
  ));
  select request_hash, response into v_stored_hash, v_stored_response
  from private.email_import_reconciliation_receipts
  where owner_user_id = p_owner_user_id and idempotency_key = p_idempotency_key;
  if found then
    if v_stored_hash <> v_request_hash then
      raise exception using errcode = '23505', message = 'Email reconciliation idempotency key was reused.';
    end if;
    return jsonb_set(v_stored_response, '{replayed}', 'true'::jsonb, true);
  end if;

  select * into v_connection
  from public.email_connections
  where id = p_connection_id
    and owner_user_id = p_owner_user_id
    and provider = p_provider
    and provider_account_hash = p_provider_account_hash
  for update;
  if v_connection.id is null then
    raise exception using errcode = '42501', message = 'Email connection owner mismatch.';
  end if;

  select * into v_source
  from public.email_sources
  where owner_user_id = p_owner_user_id
    and connection_id = p_connection_id
    and provider_message_id_hash = p_provider_message_id_hash
    and provider_thread_id_hash = p_provider_thread_id_hash
    and sanitized_content_hash = p_sanitized_content_hash
  for update;
  if v_source.id is not null then
    select * into v_candidate
    from public.email_candidates
    where owner_user_id = p_owner_user_id and source_id = v_source.id
    for update;
  end if;
  if v_source.id is null or v_candidate.id is null then
    raise exception using errcode = '42501', message = 'Email review source mismatch.';
  end if;
  if v_candidate.review_state in ('confirmed', 'update_available') then
    raise exception using errcode = '55000', message = 'A confirmed email candidate cannot be dismissed.';
  end if;

  insert into private.email_import_dismissal_tombstones(
    owner_user_id,
    connection_id,
    provider,
    provider_account_hash,
    provider_message_id_hash,
    provider_thread_id_hash,
    sanitized_content_hash,
    semantic_fingerprint,
    dismissal_idempotency_key,
    dismissed_at,
    created_at
  ) values (
    p_owner_user_id,
    p_connection_id,
    p_provider,
    p_provider_account_hash,
    p_provider_message_id_hash,
    p_provider_thread_id_hash,
    p_sanitized_content_hash,
    coalesce(v_candidate.semantic_fingerprint,
      private.email_import_semantic_fingerprint(v_candidate.validated_payload)),
    p_idempotency_key,
    p_reconciled_at,
    p_reconciled_at
  );

  -- Cascading from the source removes the candidate/proposal and every raw
  -- provider identifier while the minimal private tombstone remains.
  delete from public.email_sources
  where id = v_source.id and owner_user_id = p_owner_user_id;

  perform private.email_import_write_audit(
    p_owner_user_id, p_connection_id, p_correlation_id,
    'dismiss', 'succeeded', null, null, p_reconciled_at
  );
  v_response := jsonb_build_object(
    'connection_id', p_connection_id,
    'connection_state', v_connection.connection_state,
    'action', 'dismissal',
    'outcome', 'dismissed',
    'replayed', false
  );
  insert into private.email_import_reconciliation_receipts(
    owner_user_id, idempotency_key, action, request_hash, response, created_at
  ) values (
    p_owner_user_id, p_idempotency_key, 'dismissal', v_request_hash,
    v_response, p_reconciled_at
  );
  return v_response;
end;
$$;

create or replace function public.email_import_reconcile_update(
  p_owner_user_id uuid,
  p_connection_id uuid,
  p_provider text,
  p_provider_account_hash text,
  p_provider_message_id_hash text,
  p_provider_thread_id_hash text,
  p_sanitized_content_hash text,
  p_resolution text,
  p_entity_type text,
  p_entity_id uuid,
  p_idempotency_key text,
  p_reconciled_at timestamptz,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private, extensions
as $$
declare
  v_connection public.email_connections%rowtype;
  v_source public.email_sources%rowtype;
  v_candidate public.email_candidates%rowtype;
  v_update public.email_candidate_updates%rowtype;
  v_schedule_receipt jsonb;
  v_schedule_version bigint;
  v_request_hash text;
  v_stored_hash text;
  v_stored_response jsonb;
  v_response jsonb;
begin
  if p_owner_user_id is null
    or p_connection_id is null
    or p_provider is null
    or p_provider <> 'gmail'
    or p_provider_account_hash is null
    or p_provider_account_hash !~ '^[0-9a-f]{64}$'
    or p_provider_message_id_hash is null
    or p_provider_message_id_hash !~ '^[0-9a-f]{64}$'
    or p_provider_thread_id_hash is null
    or p_provider_thread_id_hash !~ '^[0-9a-f]{64}$'
    or p_sanitized_content_hash is null
    or p_sanitized_content_hash !~ '^[0-9a-f]{64}$'
    or p_resolution is null
    or p_resolution not in ('accepted', 'rejected')
    or p_entity_type is null
    or p_entity_type not in ('assignment', 'exam', 'event')
    or p_entity_id is null
    or p_idempotency_key is null
    or char_length(p_idempotency_key) not between 1 and 200
    or p_idempotency_key <> btrim(p_idempotency_key)
    or p_reconciled_at is null
    or not isfinite(p_reconciled_at)
    or p_correlation_id is null
  then
    raise exception using errcode = '22023', message = 'Invalid email update reconciliation.';
  end if;

  v_request_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'connection_id', p_connection_id,
    'provider', p_provider,
    'provider_account_hash', p_provider_account_hash,
    'provider_message_id_hash', p_provider_message_id_hash,
    'provider_thread_id_hash', p_provider_thread_id_hash,
    'sanitized_content_hash', p_sanitized_content_hash,
    'resolution', p_resolution,
    'entity_type', p_entity_type,
    'entity_id', p_entity_id
  )::text, 'UTF8'), 'sha256'), 'hex');

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    p_owner_user_id::text || ':email-reconcile:' || p_idempotency_key, 0
  ));
  select request_hash, response into v_stored_hash, v_stored_response
  from private.email_import_reconciliation_receipts
  where owner_user_id = p_owner_user_id and idempotency_key = p_idempotency_key;
  if found then
    if v_stored_hash <> v_request_hash then
      raise exception using errcode = '23505', message = 'Email reconciliation idempotency key was reused.';
    end if;
    return jsonb_set(v_stored_response, '{replayed}', 'true'::jsonb, true);
  end if;

  select * into v_connection
  from public.email_connections
  where id = p_connection_id
    and owner_user_id = p_owner_user_id
    and provider = p_provider
    and provider_account_hash = p_provider_account_hash
  for update;
  if v_connection.id is null then
    raise exception using errcode = '42501', message = 'Email connection owner mismatch.';
  end if;

  select * into v_source
  from public.email_sources
  where owner_user_id = p_owner_user_id
    and connection_id = p_connection_id
    and provider_message_id_hash = p_provider_message_id_hash
    and provider_thread_id_hash = p_provider_thread_id_hash
    and sanitized_content_hash = p_sanitized_content_hash
  for update;
  if v_source.id is not null then
    select * into v_update
    from public.email_candidate_updates
    where owner_user_id = p_owner_user_id and source_id = v_source.id
    for update;
  end if;
  if v_update.id is not null then
    select * into v_candidate
    from public.email_candidates
    where owner_user_id = p_owner_user_id and id = v_update.candidate_id
    for update;
  end if;
  if v_update.id is null then
    raise exception using errcode = '42501', message = 'Email update source mismatch.';
  end if;
  if v_update.resolution_state <> 'pending'
    or v_update.proposed_payload is null
    or v_update.base_entity_version is null
    or v_candidate.review_state <> 'update_available'
    or v_candidate.linked_entity_type <> p_entity_type
    or v_candidate.linked_entity_id <> p_entity_id
    or v_update.proposed_payload ->> 'candidate_type' <> p_entity_type
  then
    raise exception using errcode = '55000', message = 'Email update proposal is not resolvable.';
  end if;

  if p_resolution = 'accepted' then
    select response into v_schedule_receipt
    from private.schedule_mutation_receipts
    where owner_user_id = p_owner_user_id
      and idempotency_key = p_idempotency_key;
    if v_schedule_receipt is null
      or v_schedule_receipt ->> 'outcome' <> 'applied'
      or v_schedule_receipt ->> 'operation' <> 'update'
      or v_schedule_receipt ->> 'entity_type' <> p_entity_type
      or v_schedule_receipt ->> 'entity_id' <> p_entity_id::text
    then
      raise exception using errcode = '55000', message = 'Accepted schedule mutation is unavailable.';
    end if;
    begin
      v_schedule_version := (v_schedule_receipt ->> 'server_version')::bigint;
    exception when others then
      raise exception using errcode = '55000', message = 'Accepted schedule mutation is unavailable.';
    end;
    if v_schedule_version <> v_update.base_entity_version + 1
      or not private.email_import_schedule_entity_matches(
        p_owner_user_id, p_entity_type, p_entity_id,
        v_update.proposed_payload, v_schedule_version
      )
    then
      raise exception using errcode = '55000', message = 'Accepted schedule entity does not match the proposal.';
    end if;

    update public.email_candidates
    set validated_payload = v_update.proposed_payload,
        semantic_fingerprint = private.email_import_semantic_fingerprint(
          v_update.proposed_payload
        ),
        review_state = 'confirmed',
        updated_at = p_reconciled_at
    where id = v_candidate.id and owner_user_id = p_owner_user_id;
    update public.email_sources
    set processing_state = 'processed', error_category = null, updated_at = p_reconciled_at
    where id = v_source.id and owner_user_id = p_owner_user_id;
  else
    update public.email_candidates
    set review_state = 'confirmed', updated_at = p_reconciled_at
    where id = v_candidate.id and owner_user_id = p_owner_user_id;
    update public.email_sources
    set evidence_metadata = '[]'::jsonb,
        processing_state = 'ignored',
        error_category = null,
        updated_at = p_reconciled_at
    where id = v_source.id and owner_user_id = p_owner_user_id;
  end if;

  update public.email_candidate_updates
  set resolution_state = p_resolution,
      resolution_idempotency_key = p_idempotency_key,
      error_category = null,
      resolved_at = p_reconciled_at,
      updated_at = p_reconciled_at
  where id = v_update.id and owner_user_id = p_owner_user_id;

  perform private.email_import_write_audit(
    p_owner_user_id, p_connection_id, p_correlation_id,
    'resolve_update', 'succeeded', null, null, p_reconciled_at
  );
  v_response := jsonb_build_object(
    'connection_id', p_connection_id,
    'connection_state', v_connection.connection_state,
    'action', 'update',
    'outcome', p_resolution,
    'entity_type', p_entity_type,
    'entity_id', p_entity_id,
    'replayed', false
  );
  insert into private.email_import_reconciliation_receipts(
    owner_user_id, idempotency_key, action, request_hash, response, created_at
  ) values (
    p_owner_user_id, p_idempotency_key, 'update', v_request_hash,
    v_response, p_reconciled_at
  );
  return v_response;
end;
$$;

create or replace function public.email_import_finalize_disconnect(
  p_owner_user_id uuid,
  p_connection_id uuid,
  p_delete_derived_data boolean,
  p_revocation_attempted boolean,
  p_revocation_succeeded boolean,
  p_disconnected_at timestamptz,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_outcome text;
  v_error text;
begin
  if p_owner_user_id is null
    or p_connection_id is null
    or p_delete_derived_data is null
    or p_revocation_attempted is null
    or p_revocation_succeeded is null
    or (p_revocation_succeeded and not p_revocation_attempted)
    or p_disconnected_at is null
    or p_correlation_id is null
  then
    raise exception using errcode = '22023', message = 'Invalid email disconnect request.';
  end if;

  perform 1
  from public.email_connections
  where id = p_connection_id
    and owner_user_id = p_owner_user_id
    and provider = 'gmail'
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'Email connection owner mismatch.';
  end if;

  delete from private.email_connection_credentials
  where connection_id = p_connection_id
    and owner_user_id = p_owner_user_id;
  delete from private.email_oauth_sessions
  where connection_id = p_connection_id
    and owner_user_id = p_owner_user_id;

  if p_delete_derived_data then
    delete from private.email_import_dismissal_tombstones
    where connection_id = p_connection_id
      and owner_user_id = p_owner_user_id;
    delete from private.email_import_reconciliation_receipts
    where owner_user_id = p_owner_user_id
      and response ->> 'connection_id' = p_connection_id::text;
    delete from public.email_sources
    where connection_id = p_connection_id
      and owner_user_id = p_owner_user_id;
  end if;

  update public.email_connections
  set sync_cursor = null,
      connection_state = 'disconnected',
      last_error_category = null,
      retry_after_at = null,
      connected_at = null,
      last_synced_at = null,
      disconnected_at = p_disconnected_at,
      updated_at = p_disconnected_at
  where id = p_connection_id
    and owner_user_id = p_owner_user_id;

  v_outcome := case
    when p_revocation_succeeded then 'succeeded'
    when not p_revocation_attempted then 'already_revoked'
    else 'failed'
  end;
  v_error := case when v_outcome = 'failed' then 'provider_unavailable' end;

  perform private.email_import_write_audit(
    p_owner_user_id,
    p_connection_id,
    p_correlation_id,
    'disconnect',
    v_outcome,
    'disconnected',
    v_error,
    p_disconnected_at
  );

  return jsonb_build_object(
    'connection_id', p_connection_id,
    'connection_state', 'disconnected',
    'connected_at', null
  );
end;
$$;

create or replace function public.email_import_delete_account_data(
  p_owner_user_id uuid,
  p_deleted_at timestamptz,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_connections integer;
  v_sources integer;
  v_candidates integer;
  v_updates integer;
begin
  if p_owner_user_id is null or p_deleted_at is null or p_correlation_id is null
    or not exists (select 1 from auth.users where id = p_owner_user_id)
  then
    raise exception using errcode = '22023', message = 'Invalid email data deletion request.';
  end if;

  select count(*) into v_connections
  from public.email_connections where owner_user_id = p_owner_user_id;
  select count(*) into v_sources
  from public.email_sources where owner_user_id = p_owner_user_id;
  select count(*) into v_candidates
  from public.email_candidates where owner_user_id = p_owner_user_id;
  select count(*) into v_updates
  from public.email_candidate_updates where owner_user_id = p_owner_user_id;

  delete from private.email_oauth_sessions where owner_user_id = p_owner_user_id;
  delete from private.email_connection_credentials where owner_user_id = p_owner_user_id;
  delete from private.email_import_reconciliation_receipts
  where owner_user_id = p_owner_user_id;
  delete from public.email_connections where owner_user_id = p_owner_user_id;

  perform private.email_import_write_audit(
    p_owner_user_id,
    null,
    p_correlation_id,
    'delete_account_data',
    'succeeded',
    'disconnected',
    null,
    p_deleted_at
  );

  return jsonb_build_object(
    'deleted_connections', v_connections,
    'deleted_sources', v_sources,
    'deleted_candidates', v_candidates,
    'deleted_updates', v_updates
  );
end;
$$;

create or replace function public.email_import_record_failure(
  p_owner_user_id uuid,
  p_connection_id uuid,
  p_operation text,
  p_connection_state text,
  p_error_category text,
  p_retry_after_at timestamptz,
  p_occurred_at timestamptz,
  p_correlation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
begin
  if p_owner_user_id is null
    or p_connection_id is null
    or p_operation not in ('connect', 'oauth_callback', 'refresh', 'fetch')
    or p_connection_state not in ('reauth_required', 'rate_limited', 'failed')
    or p_error_category is null
    or p_error_category not in (
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
    )
    or (p_connection_state = 'rate_limited') <> (p_retry_after_at is not null)
    or p_occurred_at is null
    or not isfinite(p_occurred_at)
    or (
      p_retry_after_at is not null
      and (
        not isfinite(p_retry_after_at)
        or p_retry_after_at < p_occurred_at
        or p_retry_after_at > p_occurred_at + interval '1 day'
      )
    )
    or p_correlation_id is null
    or not exists (select 1 from auth.users where id = p_owner_user_id)
  then
    raise exception using errcode = '22023', message = 'Invalid email failure state.';
  end if;

  update public.email_connections
  set connection_state = p_connection_state,
      last_error_category = p_error_category,
      retry_after_at = p_retry_after_at,
      updated_at = p_occurred_at
  where id = p_connection_id
    and owner_user_id = p_owner_user_id
    and provider = 'gmail';
  if not found then
    raise exception using errcode = '42501', message = 'Email connection owner mismatch.';
  end if;

  perform private.email_import_write_audit(
    p_owner_user_id,
    p_connection_id,
    p_correlation_id,
    p_operation,
    'failed',
    p_connection_state,
    p_error_category,
    p_occurred_at
  );

  return (
    select jsonb_build_object(
      'connection_id', id,
      'connection_state', connection_state,
      'last_error_category', last_error_category,
      'retry_after_at', retry_after_at,
      'connected_at', connected_at
    )
    from public.email_connections
    where id = p_connection_id and owner_user_id = p_owner_user_id
  );
end;
$$;

revoke all on function public.email_import_begin_oauth(
  uuid, uuid, text, bytea, integer, timestamptz, uuid
) from public, anon, authenticated;
revoke all on function public.email_import_take_oauth(text, timestamptz)
from public, anon, authenticated;
revoke all on function public.email_import_complete_oauth(
  uuid, uuid, text, text[], bytea, integer, timestamptz, text, timestamptz, uuid
) from public, anon, authenticated;
revoke all on function public.email_import_get_credentials(uuid, uuid)
from public, anon, authenticated;
revoke all on function public.email_import_rotate_credentials(
  uuid, uuid, bigint, bytea, integer, timestamptz, timestamptz, uuid
) from public, anon, authenticated;
revoke all on function public.email_import_persist_sync_page(
  uuid, uuid, text, text, jsonb, jsonb, boolean, timestamptz, uuid
) from public, anon, authenticated;
revoke all on function public.email_import_finalize_disconnect(
  uuid, uuid, boolean, boolean, boolean, timestamptz, uuid
) from public, anon, authenticated;
revoke all on function public.email_import_delete_account_data(uuid, timestamptz, uuid)
from public, anon, authenticated;
revoke all on function public.email_import_record_failure(
  uuid, uuid, text, text, text, timestamptz, timestamptz, uuid
) from public, anon, authenticated;
revoke all on function public.email_import_reconcile_confirmation(
  uuid, uuid, text, text, text, text, text, jsonb, text, uuid, text,
  timestamptz, uuid
) from public, anon, authenticated;
revoke all on function public.email_import_reconcile_dismissal(
  uuid, uuid, text, text, text, text, text, text, timestamptz, uuid
) from public, anon, authenticated;
revoke all on function public.email_import_reconcile_update(
  uuid, uuid, text, text, text, text, text, text, text, uuid, text,
  timestamptz, uuid
) from public, anon, authenticated;
revoke all on function private.email_import_provider_identifier_hash(
  text, text, text, text
) from public, anon, authenticated, service_role;
revoke all on function private.email_import_fill_source_hashes()
from public, anon, authenticated, service_role;
revoke all on function private.email_import_schedule_entity_matches(
  uuid, text, uuid, jsonb, bigint
) from public, anon, authenticated, service_role;

grant execute on function public.email_import_begin_oauth(
  uuid, uuid, text, bytea, integer, timestamptz, uuid
) to service_role;
grant execute on function public.email_import_take_oauth(text, timestamptz)
to service_role;
grant execute on function public.email_import_complete_oauth(
  uuid, uuid, text, text[], bytea, integer, timestamptz, text, timestamptz, uuid
) to service_role;
grant execute on function public.email_import_get_credentials(uuid, uuid)
to service_role;
grant execute on function public.email_import_rotate_credentials(
  uuid, uuid, bigint, bytea, integer, timestamptz, timestamptz, uuid
) to service_role;
grant execute on function public.email_import_persist_sync_page(
  uuid, uuid, text, text, jsonb, jsonb, boolean, timestamptz, uuid
) to service_role;
grant execute on function public.email_import_finalize_disconnect(
  uuid, uuid, boolean, boolean, boolean, timestamptz, uuid
) to service_role;
grant execute on function public.email_import_delete_account_data(uuid, timestamptz, uuid)
to service_role;
grant execute on function public.email_import_record_failure(
  uuid, uuid, text, text, text, timestamptz, timestamptz, uuid
) to service_role;
grant execute on function public.email_import_reconcile_confirmation(
  uuid, uuid, text, text, text, text, text, jsonb, text, uuid, text,
  timestamptz, uuid
) to service_role;
grant execute on function public.email_import_reconcile_dismissal(
  uuid, uuid, text, text, text, text, text, text, timestamptz, uuid
) to service_role;
grant execute on function public.email_import_reconcile_update(
  uuid, uuid, text, text, text, text, text, text, text, uuid, text,
  timestamptz, uuid
) to service_role;

comment on function public.email_import_get_credentials(uuid, uuid) is
  'Trusted Edge-only encrypted credential read. Never returns raw OAuth material.';
comment on function public.email_import_persist_sync_page(
  uuid, uuid, text, text, jsonb, jsonb, boolean, timestamptz, uuid
) is
  'Trusted owner-bound safe page persistence with cursor CAS, dedupe, dismissed suppression, and update proposals.';
comment on function public.email_import_finalize_disconnect(
  uuid, uuid, boolean, boolean, boolean, timestamptz, uuid
) is
  'Trusted revoke finalization that always destroys sealed credentials and preserves canonical schedules.';
comment on function public.email_import_reconcile_confirmation(
  uuid, uuid, text, text, text, text, text, jsonb, text, uuid, text,
  timestamptz, uuid
) is
  'Trusted idempotent confirmation reconciliation. Verifies the schedule mutation receipt and canonical PRIVATE entity; never creates a schedule row.';
comment on function public.email_import_reconcile_dismissal(
  uuid, uuid, text, text, text, text, text, text, timestamptz, uuid
) is
  'Trusted idempotent dismissal reconciliation using only account-domain-separated hashes and bounded content identity.';
comment on function public.email_import_reconcile_update(
  uuid, uuid, text, text, text, text, text, text, text, uuid, text,
  timestamptz, uuid
) is
  'Trusted explicit update resolution. Accepted proposals require a matching applied schedule update receipt and canonical PRIVATE entity.';

commit;
