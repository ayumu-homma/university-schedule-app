-- Phase 5A stores only bounded, provider-derived review data in the exposed
-- schema. OAuth material remains sealed in the non-exposed private schema and
-- every client mutation is reserved for a trusted Edge/RPC boundary.
begin;

create table public.email_connections (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null default 'gmail',
  provider_account_hash text not null,
  authorized_scopes text[] not null default '{}',
  sync_cursor text,
  connection_state text not null default 'disconnected',
  last_error_category text,
  retry_after_at timestamptz,
  connected_at timestamptz,
  last_synced_at timestamptz,
  disconnected_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint email_connections_provider_allowed
    check (provider in ('gmail')),
  constraint email_connections_account_hash_format
    check (provider_account_hash ~ '^[0-9a-f]{64}$'),
  constraint email_connections_scopes_bounded
    check (
      cardinality(authorized_scopes) <= 16
      and pg_column_size(authorized_scopes) <= 4096
    ),
  constraint email_connections_cursor_bounded
    check (sync_cursor is null or char_length(sync_cursor) between 1 and 4096),
  constraint email_connections_state_allowed
    check (
      connection_state in (
        'disconnected',
        'connecting',
        'connected',
        'reauth_required',
        'rate_limited',
        'failed',
        'disconnecting'
      )
    ),
  constraint email_connections_error_category_allowed
    check (
      last_error_category is null
      or last_error_category in (
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
    ),
  constraint email_connections_owner_provider_account_key
    unique (owner_user_id, provider, provider_account_hash),
  constraint email_connections_id_owner_key unique (id, owner_user_id)
);

create table public.email_sources (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  connection_id uuid not null,
  provider_message_id text not null,
  provider_thread_id text,
  received_at timestamptz not null,
  sanitized_content_hash text not null,
  evidence_metadata jsonb not null default '[]'::jsonb,
  processing_state text not null default 'pending',
  error_category text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint email_sources_connection_owner_fk
    foreign key (connection_id, owner_user_id)
    references public.email_connections(id, owner_user_id)
    on delete cascade,
  constraint email_sources_message_id_bounded
    check (char_length(provider_message_id) between 1 and 1024),
  constraint email_sources_thread_id_bounded
    check (
      provider_thread_id is null
      or char_length(provider_thread_id) between 1 and 1024
    ),
  constraint email_sources_content_hash_format
    check (sanitized_content_hash ~ '^[0-9a-f]{64}$'),
  constraint email_sources_evidence_bounded
    check (
      jsonb_typeof(evidence_metadata) = 'array'
      and pg_column_size(evidence_metadata) <= 8192
    ),
  constraint email_sources_processing_state_allowed
    check (
      processing_state in ('pending', 'processing', 'processed', 'ignored', 'failed')
    ),
  constraint email_sources_error_category_allowed
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
    ),
  constraint email_sources_connection_message_key
    unique (connection_id, provider_message_id),
  constraint email_sources_id_owner_key unique (id, owner_user_id)
);

create table public.email_candidates (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  source_id uuid not null,
  schema_version text not null default '1.0',
  candidate_type text not null,
  validated_payload jsonb not null,
  review_state text not null default 'needs_review',
  semantic_fingerprint text,
  linked_entity_type text,
  linked_entity_id uuid,
  error_category text,
  requires_user_confirmation boolean not null default true,
  confirmed_at timestamptz,
  dismissed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint email_candidates_source_owner_fk
    foreign key (source_id, owner_user_id)
    references public.email_sources(id, owner_user_id)
    on delete cascade,
  constraint email_candidates_schema_version_allowed
    check (schema_version = '1.0'),
  constraint email_candidates_type_allowed
    check (candidate_type in ('assignment', 'exam', 'event', 'announcement', 'unknown')),
  constraint email_candidates_payload_bounded
    check (
      jsonb_typeof(validated_payload) = 'object'
      and pg_column_size(validated_payload) <= 65536
    ),
  constraint email_candidates_review_state_allowed
    check (
      review_state in (
        'needs_review',
        'ready_for_review',
        'update_available',
        'confirmed',
        'dismissed',
        'failed'
      )
    ),
  constraint email_candidates_fingerprint_format
    check (
      semantic_fingerprint is null
      or semantic_fingerprint ~ '^[0-9a-f]{64}$'
    ),
  constraint email_candidates_link_type_allowed
    check (
      linked_entity_type is null
      or linked_entity_type in ('assignment', 'exam', 'event')
    ),
  constraint email_candidates_link_pair_consistent
    check ((linked_entity_type is null) = (linked_entity_id is null)),
  constraint email_candidates_link_matches_type
    check (
      linked_entity_type is null
      or linked_entity_type = candidate_type
    ),
  constraint email_candidates_confirmed_link_required
    check (
      (review_state in ('confirmed', 'update_available'))
      = (linked_entity_id is not null)
    ),
  constraint email_candidates_confirmation_time_consistent
    check (
      (review_state in ('confirmed', 'update_available'))
      = (confirmed_at is not null)
    ),
  constraint email_candidates_dismissal_time_consistent
    check ((review_state = 'dismissed') = (dismissed_at is not null)),
  constraint email_candidates_error_category_allowed
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
    ),
  constraint email_candidates_confirmation_always_required
    check (requires_user_confirmation),
  constraint email_candidates_source_key unique (source_id),
  constraint email_candidates_id_owner_key unique (id, owner_user_id)
);

create table public.email_candidate_updates (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  candidate_id uuid not null,
  source_id uuid not null,
  proposal_fingerprint text not null,
  field_diff jsonb not null,
  resolution_state text not null default 'pending',
  error_category text,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint email_candidate_updates_candidate_owner_fk
    foreign key (candidate_id, owner_user_id)
    references public.email_candidates(id, owner_user_id)
    on delete cascade,
  constraint email_candidate_updates_source_owner_fk
    foreign key (source_id, owner_user_id)
    references public.email_sources(id, owner_user_id)
    on delete cascade,
  constraint email_candidate_updates_fingerprint_format
    check (proposal_fingerprint ~ '^[0-9a-f]{64}$'),
  constraint email_candidate_updates_diff_bounded
    check (
      jsonb_typeof(field_diff) = 'object'
      and pg_column_size(field_diff) <= 32768
    ),
  constraint email_candidate_updates_resolution_state_allowed
    check (
      resolution_state in ('pending', 'accepted', 'rejected', 'superseded', 'failed')
    ),
  constraint email_candidate_updates_resolution_time_consistent
    check (
      (resolution_state in ('accepted', 'rejected', 'superseded'))
      = (resolved_at is not null)
    ),
  constraint email_candidate_updates_error_category_allowed
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
    ),
  constraint email_candidate_updates_candidate_source_key
    unique (candidate_id, source_id)
);

-- The sealed bundle is intentionally not in a Data API schema. A future
-- trusted SECURITY DEFINER boundary will own exchange, refresh and revocation;
-- neither a client nor a service-role Table API call can inspect this table.
create table private.email_connection_credentials (
  connection_id uuid primary key,
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  encrypted_oauth_bundle bytea not null,
  encryption_key_version integer not null,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint email_connection_credentials_connection_owner_fk
    foreign key (connection_id, owner_user_id)
    references public.email_connections(id, owner_user_id)
    on delete cascade,
  constraint email_connection_credentials_ciphertext_bounded
    check (octet_length(encrypted_oauth_bundle) between 1 and 65536),
  constraint email_connection_credentials_key_version_valid
    check (encryption_key_version > 0)
);

create index email_connections_owner_state_idx
  on public.email_connections(owner_user_id, connection_state);
create index email_sources_owner_received_idx
  on public.email_sources(owner_user_id, received_at desc);
create index email_sources_thread_idx
  on public.email_sources(connection_id, provider_thread_id, received_at desc)
  where provider_thread_id is not null;
create index email_candidates_owner_review_idx
  on public.email_candidates(owner_user_id, review_state, updated_at desc);
create index email_candidate_updates_owner_state_idx
  on public.email_candidate_updates(owner_user_id, resolution_state, updated_at desc);

alter table public.email_connections enable row level security;
alter table public.email_sources enable row level security;
alter table public.email_candidates enable row level security;
alter table public.email_candidate_updates enable row level security;
alter table private.email_connection_credentials enable row level security;

create policy email_connections_owner_read
on public.email_connections for select to authenticated
using (owner_user_id = auth.uid());

create policy email_sources_owner_read
on public.email_sources for select to authenticated
using (owner_user_id = auth.uid());

create policy email_candidates_owner_read
on public.email_candidates for select to authenticated
using (owner_user_id = auth.uid());

create policy email_candidate_updates_owner_read
on public.email_candidate_updates for select to authenticated
using (owner_user_id = auth.uid());

revoke all on table public.email_connections,
  public.email_sources,
  public.email_candidates,
  public.email_candidate_updates
from public, anon, authenticated, service_role;

grant select on table public.email_connections,
  public.email_sources,
  public.email_candidates,
  public.email_candidate_updates
to authenticated;

-- service_role identifies the authenticated trusted Edge boundary. It may
-- manage only the non-secret derived rows directly; credential access remains
-- behind narrowly granted server RPCs.
grant select, insert, update, delete on table public.email_connections,
  public.email_sources,
  public.email_candidates,
  public.email_candidate_updates
to service_role;

revoke all on table private.email_connection_credentials
from public, anon, authenticated, service_role;

comment on table public.email_connections is
  'Owner-readable email connection metadata. Contains no OAuth credentials.';
comment on table public.email_sources is
  'Bounded sanitized email source metadata. Raw message content is never persisted.';
comment on table public.email_candidates is
  'Validated private review proposals; schedule creation requires explicit confirmation.';
comment on table public.email_candidate_updates is
  'Field-level update proposals that never silently overwrite a linked schedule entity.';
comment on table private.email_connection_credentials is
  'Sealed OAuth material accessible only through trusted server-owned routines.';

commit;
