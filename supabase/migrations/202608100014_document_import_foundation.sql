-- Portfolio v0.5 document import foundation.
-- Raw class documents remain in a private Storage bucket. Public tables hold
-- bounded metadata and validated candidate JSON only; schedule entities are
-- created exclusively after an explicit, idempotent confirmation RPC.
begin;

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'schedule-documents',
  'schedule-documents',
  false,
  10485760,
  array['application/pdf', 'image/png', 'image/jpeg', 'text/plain']
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create table public.document_sources (
  id uuid primary key,
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  storage_path text not null,
  media_type text not null,
  byte_size bigint not null,
  content_hash text not null,
  processing_state text not null default 'pending_upload',
  error_category text,
  processing_attempt_count integer not null default 0,
  retry_after_at timestamptz,
  retention_expires_at timestamptz not null default (now() + interval '30 days'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1,
  constraint document_sources_id_owner_key unique (id, owner_user_id),
  constraint document_sources_storage_path_key unique (storage_path),
  constraint document_sources_storage_path_format check (
    storage_path = owner_user_id::text || '/' || id::text || '/source.' ||
      case media_type
        when 'application/pdf' then 'pdf'
        when 'image/png' then 'png'
        when 'image/jpeg' then 'jpg'
        when 'text/plain' then 'txt'
      end
  ),
  constraint document_sources_media_type_allowed check (
    media_type in ('application/pdf', 'image/png', 'image/jpeg', 'text/plain')
  ),
  constraint document_sources_byte_size_bounded check (
    byte_size between 1 and 10485760
  ),
  constraint document_sources_content_hash_format check (
    content_hash ~ '^[0-9a-f]{64}$'
  ),
  constraint document_sources_processing_state_allowed check (
    processing_state in (
      'pending_upload', 'uploaded', 'processing', 'processed', 'failed', 'deleted'
    )
  ),
  constraint document_sources_error_category_allowed check (
    error_category is null or error_category in (
      'configuration_missing', 'unsupported_type', 'oversized_file',
      'oversized_document', 'corrupt_document', 'encrypted_document',
      'spoofed_media_type', 'unsafe_content', 'invalid_extraction',
      'rate_limited', 'timeout', 'network_unavailable',
      'provider_unavailable', 'cancelled', 'internal_error'
    )
  ),
  constraint document_sources_attempts_bounded check (
    processing_attempt_count between 0 and 5
  ),
  constraint document_sources_version_valid check (version >= 1),
  constraint document_sources_failure_state_consistent check (
    (processing_state = 'failed') = (error_category is not null)
    and (retry_after_at is null or processing_state = 'failed')
  ),
  constraint document_sources_retention_valid check (
    retention_expires_at > created_at
  ),
  constraint document_sources_deleted_state_consistent check (
    (processing_state = 'deleted') = (deleted_at is not null)
  )
);

create table public.document_candidates (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  source_id uuid not null,
  candidate_key text not null,
  schema_version text not null default '1.0',
  candidate_type text not null,
  validated_payload jsonb not null,
  semantic_fingerprint text not null,
  review_state text not null default 'needs_review',
  is_selected boolean not null default true,
  requires_user_confirmation boolean not null default true,
  linked_entity_type text,
  linked_entity_id uuid,
  error_category text,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  version bigint not null default 1,
  constraint document_candidates_source_owner_fk
    foreign key (source_id, owner_user_id)
    references public.document_sources(id, owner_user_id),
  constraint document_candidates_id_owner_key unique (id, owner_user_id),
  constraint document_candidates_source_candidate_key unique (source_id, candidate_key),
  constraint document_candidates_candidate_key_format check (
    candidate_key ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
  ),
  constraint document_candidates_schema_allowed check (schema_version = '1.0'),
  constraint document_candidates_type_allowed check (
    candidate_type in ('assignment', 'exam')
  ),
  constraint document_candidates_payload_bounded check (
    jsonb_typeof(validated_payload) = 'object'
    and pg_column_size(validated_payload) <= 65536
  ),
  constraint document_candidates_fingerprint_format check (
    semantic_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  constraint document_candidates_review_state_allowed check (
    review_state in ('needs_review', 'excluded', 'confirmed', 'failed')
  ),
  constraint document_candidates_error_category_allowed check (
    error_category is null or error_category in (
      'configuration_missing', 'unsupported_type', 'oversized_file',
      'oversized_document', 'corrupt_document', 'encrypted_document',
      'spoofed_media_type', 'unsafe_content', 'invalid_extraction',
      'rate_limited', 'timeout', 'network_unavailable',
      'provider_unavailable', 'cancelled', 'internal_error'
    )
  ),
  constraint document_candidates_confirmation_required check (
    requires_user_confirmation
  ),
  constraint document_candidates_link_type_allowed check (
    linked_entity_type is null or linked_entity_type in ('assignment', 'exam')
  ),
  constraint document_candidates_link_pair_consistent check (
    (linked_entity_type is null) = (linked_entity_id is null)
  ),
  constraint document_candidates_link_matches_type check (
    linked_entity_type is null or linked_entity_type = candidate_type
  ),
  constraint document_candidates_confirmation_consistent check (
    (review_state = 'confirmed') = (confirmed_at is not null)
    and (review_state = 'confirmed') = (linked_entity_id is not null)
  ),
  constraint document_candidates_deleted_consistent check (
    deleted_at is null or review_state in ('excluded', 'confirmed')
  ),
  constraint document_candidates_version_valid check (version >= 1)
);

create table public.document_confirmations (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  source_id uuid not null,
  candidate_id uuid not null,
  idempotency_key text not null,
  request_hash text not null,
  semantic_fingerprint text not null,
  entity_type text not null,
  entity_id uuid not null,
  response jsonb not null,
  deduplicated boolean not null default false,
  confirmed_at timestamptz not null default now(),
  constraint document_confirmations_candidate_owner_fk
    foreign key (candidate_id, owner_user_id)
    references public.document_candidates(id, owner_user_id),
  constraint document_confirmations_source_owner_fk
    foreign key (source_id, owner_user_id)
    references public.document_sources(id, owner_user_id),
  constraint document_confirmations_owner_key unique (owner_user_id, idempotency_key),
  constraint document_confirmations_candidate_key unique (candidate_id),
  constraint document_confirmations_idempotency_bounded check (
    char_length(idempotency_key) between 1 and 200
  ),
  constraint document_confirmations_hash_format check (
    request_hash ~ '^[0-9a-f]{64}$'
    and semantic_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  constraint document_confirmations_entity_type_allowed check (
    entity_type in ('assignment', 'exam')
  ),
  constraint document_confirmations_response_bounded check (
    jsonb_typeof(response) = 'object'
    and pg_column_size(response) <= 8192
  )
);

create index document_sources_owner_state_idx
  on public.document_sources(owner_user_id, processing_state, updated_at desc)
  where deleted_at is null;
create unique index document_sources_owner_content_active_key
  on public.document_sources(owner_user_id, content_hash)
  where deleted_at is null;
create index document_sources_retention_idx
  on public.document_sources(retention_expires_at)
  where deleted_at is null;
create index document_candidates_owner_review_idx
  on public.document_candidates(owner_user_id, review_state, updated_at desc)
  where deleted_at is null;
create index document_candidates_owner_fingerprint_idx
  on public.document_candidates(owner_user_id, semantic_fingerprint);
create index document_candidates_source_fingerprint_idx
  on public.document_candidates(source_id, semantic_fingerprint);
create index document_confirmations_owner_fingerprint_idx
  on public.document_confirmations(owner_user_id, semantic_fingerprint);

alter table public.document_sources enable row level security;
alter table public.document_candidates enable row level security;
alter table public.document_confirmations enable row level security;

create policy document_sources_owner_read
on public.document_sources for select to authenticated
using (
  owner_user_id = (select auth.uid())
  and deleted_at is null
  and retention_expires_at > clock_timestamp()
);

create policy document_candidates_owner_read
on public.document_candidates for select to authenticated
using (
  owner_user_id = (select auth.uid())
  and deleted_at is null
  and exists (
    select 1
    from public.document_sources source
    where source.id = source_id
      and source.owner_user_id = (select auth.uid())
      and source.deleted_at is null
      and source.retention_expires_at > clock_timestamp()
  )
);

create policy document_confirmations_owner_read
on public.document_confirmations for select to authenticated
using (owner_user_id = (select auth.uid()));

-- Storage object names are server-generated by create_document_source. The
-- object API is restricted to that exact owner/source path and private bucket.
create policy document_objects_owner_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'schedule-documents'
  and exists (
    select 1
    from public.document_sources source
    where source.owner_user_id = (select auth.uid())
      and source.storage_path = name
      and source.deleted_at is null
      and source.retention_expires_at > clock_timestamp()
  )
);

create policy document_objects_owner_read
on storage.objects for select to authenticated
using (
  bucket_id = 'schedule-documents'
  and exists (
    select 1
    from public.document_sources source
    where source.owner_user_id = (select auth.uid())
      and source.storage_path = name
      and source.deleted_at is null
      and source.retention_expires_at > clock_timestamp()
  )
);

create policy document_objects_owner_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'schedule-documents'
  and exists (
    select 1
    from public.document_sources source
    where source.owner_user_id = (select auth.uid())
      and source.storage_path = name
  )
);

revoke all on table public.document_sources,
  public.document_candidates,
  public.document_confirmations
from public, anon, authenticated, service_role;

grant select on table public.document_sources,
  public.document_candidates,
  public.document_confirmations
to authenticated;

grant select, insert, update, delete on table public.document_sources,
  public.document_candidates,
  public.document_confirmations
to service_role;

create or replace function private.document_payload_fingerprint(payload jsonb)
returns text
language sql
immutable
security definer
set search_path = pg_catalog, extensions
as $$
  select encode(
    extensions.digest(
      convert_to(
        (payload - 'candidate_id' - 'confidence' - 'evidence' - 'warnings')::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  )
$$;

revoke execute on function private.document_payload_fingerprint(jsonb)
from public, anon, authenticated, service_role;

create or replace function private.document_text_is_safe(
  value text,
  maximum_characters integer
)
returns boolean
language sql
immutable
security invoker
set search_path = pg_catalog
as $$
  select value is not null
    and maximum_characters between 1 and 4096
    and char_length(value) between 1 and maximum_characters
    and value = btrim(value)
    and value !~ '^[[:space:]]'
    and value !~ '[[:space:]]$'
    and replace(value, chr(10), '') !~ '[[:cntrl:]]'
    and value !~* (
      '<[[:space:]]*/?[[:space:]]*'
      || '(script|iframe|object|embed|style|svg|html)([[:space:]>])'
      || '|on(load|error|click|mouseover)[[:space:]]*='
      || '|javascript[[:space:]]*:'
    )
$$;

revoke execute on function private.document_text_is_safe(text, integer)
from public, anon, authenticated, service_role;

create or replace function private.document_nullable_text_is_safe(
  payload jsonb,
  field_name text,
  maximum_characters integer
)
returns boolean
language sql
immutable
security invoker
set search_path = pg_catalog, private
as $$
  select case jsonb_typeof(payload -> field_name)
    when 'null' then true
    when 'string' then private.document_text_is_safe(
      payload ->> field_name,
      maximum_characters
    )
    else false
  end
$$;

revoke execute on function private.document_nullable_text_is_safe(
  jsonb, text, integer
) from public, anon, authenticated, service_role;

create or replace function private.document_timestamp_is_valid(value jsonb)
returns boolean
language plpgsql
immutable
security invoker
set search_path = pg_catalog
as $$
declare
  raw_value text;
begin
  if jsonb_typeof(value) = 'null' then
    return true;
  end if;
  if jsonb_typeof(value) <> 'string' then
    return false;
  end if;
  raw_value := value #>> '{}';
  if char_length(raw_value) > 64
     or raw_value !~ (
       '^[0-9]{4}-(0[1-9]|1[0-2])-([0-2][0-9]|3[01])'
       || 'T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]'
       || '(\.[0-9]{1,9})?'
       || '(Z|[+-]((0[0-9]|1[0-3]):[0-5][0-9]|14:00))$'
     ) then
    return false;
  end if;
  perform raw_value::timestamptz;
  return true;
exception when others then
  return false;
end;
$$;

revoke execute on function private.document_timestamp_is_valid(jsonb)
from public, anon, authenticated, service_role;

create or replace function private.document_https_url_is_safe(value text)
returns boolean
language plpgsql
immutable
security invoker
set search_path = pg_catalog, private
as $$
declare
  authority text;
  host text;
  port_text text;
  first_octet integer;
  second_octet integer;
begin
  if not private.document_text_is_safe(value, 2048)
     or value !~ '^https://[^/?#[:space:]]+([/?#]|$)' then
    return false;
  end if;
  authority := substring(value from '^https://([^/?#]+)');
  if authority is null or authority ~ '[@\\]' then
    return false;
  end if;
  port_text := substring(authority from ':([0-9]+)$');
  if port_text is not null
     and (char_length(port_text) > 5 or port_text::integer > 65535) then
    return false;
  end if;
  host := lower(regexp_replace(authority, ':[0-9]{1,5}$', ''));
  if host = ''
     or host ~ ':'
     or host = 'localhost'
     or host like '%.localhost'
     or host like '%.local'
     or host ~ '^([0-9]+|0[xX][0-9a-fA-F]+)(\.([0-9]+|0[xX][0-9a-fA-F]+))*$' then
    return false;
  end if;
  if host ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' then
    first_octet := split_part(host, '.', 1)::integer;
    second_octet := split_part(host, '.', 2)::integer;
    if first_octet > 255
       or second_octet > 255
       or split_part(host, '.', 3)::integer > 255
       or split_part(host, '.', 4)::integer > 255
       or first_octet in (0, 10, 127)
       or (first_octet = 169 and second_octet = 254)
       or (first_octet = 172 and second_octet between 16 and 31)
       or (first_octet = 192 and second_octet = 168) then
      return false;
    end if;
  end if;
  return true;
exception when others then
  return false;
end;
$$;

revoke execute on function private.document_https_url_is_safe(text)
from public, anon, authenticated, service_role;

create or replace function private.assert_document_candidate_payload(
  payload jsonb,
  expected_candidate_key text default null
)
returns void
language plpgsql
stable
security definer
set search_path = pg_catalog
as $$
declare
  candidate_type text;
  candidate_key text;
  course_hint jsonb;
  confidence jsonb;
  evidence_item jsonb;
  warning_item jsonb;
  warning_value text;
  seen_warnings text[] := array[]::text[];
  missing_date boolean;
  due_at timestamptz;
  start_at timestamptz;
  end_at timestamptz;
begin
  if jsonb_typeof(payload) <> 'object' or pg_column_size(payload) > 65536 then
    raise exception using errcode = '22023', message = 'invalid_candidate_payload';
  end if;
  if (select count(*) from jsonb_object_keys(payload)) <> 15
     or not payload ?& array[
       'candidate_id', 'type', 'title', 'course_hint', 'due_at', 'all_day',
       'start_at', 'end_at', 'location', 'submission_url', 'notes',
       'confidence', 'evidence', 'warnings', 'requires_user_confirmation'
     ] then
    raise exception using errcode = '22023', message = 'invalid_candidate_payload';
  end if;

  candidate_key := payload ->> 'candidate_id';
  candidate_type := payload ->> 'type';
  if candidate_key is null
     or candidate_key !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$'
     or (expected_candidate_key is not null and candidate_key <> expected_candidate_key)
     or candidate_type not in ('assignment', 'exam')
     or jsonb_typeof(payload -> 'title') <> 'string'
     or not private.document_text_is_safe(payload ->> 'title', 200)
     or payload -> 'requires_user_confirmation' <> 'true'::jsonb
     or jsonb_typeof(payload -> 'all_day') <> 'boolean'
     or not private.document_timestamp_is_valid(payload -> 'due_at')
     or not private.document_timestamp_is_valid(payload -> 'start_at')
     or not private.document_timestamp_is_valid(payload -> 'end_at')
     or not private.document_nullable_text_is_safe(payload, 'location', 200)
     or not private.document_nullable_text_is_safe(payload, 'notes', 1000)
     or (
       jsonb_typeof(payload -> 'submission_url') <> 'null'
       and (
         jsonb_typeof(payload -> 'submission_url') <> 'string'
         or not private.document_https_url_is_safe(payload ->> 'submission_url')
       )
     ) then
    raise exception using errcode = '22023', message = 'invalid_candidate_payload';
  end if;

  course_hint := payload -> 'course_hint';
  if jsonb_typeof(course_hint) <> 'object' then
    raise exception using errcode = '22023', message = 'invalid_candidate_course';
  end if;
  if (select count(*) from jsonb_object_keys(course_hint)) <> 2
     or not course_hint ?& array['name', 'code']
     or not private.document_nullable_text_is_safe(course_hint, 'name', 160)
     or not private.document_nullable_text_is_safe(course_hint, 'code', 64) then
    raise exception using errcode = '22023', message = 'invalid_candidate_course';
  end if;

  confidence := payload -> 'confidence';
  if jsonb_typeof(confidence) <> 'object' then
    raise exception using errcode = '22023', message = 'invalid_candidate_confidence';
  end if;
  if (select count(*) from jsonb_object_keys(confidence)) <> 3
     or not confidence ?& array['overall', 'course', 'date_time']
     or jsonb_typeof(confidence -> 'overall') <> 'number'
     or jsonb_typeof(confidence -> 'course') <> 'number'
     or jsonb_typeof(confidence -> 'date_time') <> 'number' then
    raise exception using errcode = '22023', message = 'invalid_candidate_confidence';
  end if;
  if (confidence ->> 'overall')::numeric not between 0 and 1
     or (confidence ->> 'course')::numeric not between 0 and 1
     or (confidence ->> 'date_time')::numeric not between 0 and 1 then
    raise exception using errcode = '22023', message = 'invalid_candidate_confidence';
  end if;

  if jsonb_typeof(payload -> 'evidence') <> 'array'
     or jsonb_array_length(payload -> 'evidence') not between 1 and 8
     or pg_column_size(payload -> 'evidence') > 8192 then
    raise exception using errcode = '22023', message = 'invalid_candidate_evidence';
  end if;
  for evidence_item in
    select value from jsonb_array_elements(payload -> 'evidence')
  loop
    if jsonb_typeof(evidence_item) <> 'object' then
      raise exception using errcode = '22023', message = 'invalid_candidate_evidence';
    end if;
    if (select count(*) from jsonb_object_keys(evidence_item)) <> 3
       or not evidence_item ?& array['page_number', 'section', 'excerpt']
       or not private.document_nullable_text_is_safe(evidence_item, 'section', 120)
       or jsonb_typeof(evidence_item -> 'excerpt') <> 'string'
       or not private.document_text_is_safe(evidence_item ->> 'excerpt', 500)
       or jsonb_typeof(evidence_item -> 'page_number') not in ('null', 'number') then
      raise exception using errcode = '22023', message = 'invalid_candidate_evidence';
    end if;
    if jsonb_typeof(evidence_item -> 'page_number') = 'number' then
      if (evidence_item ->> 'page_number')::numeric <> trunc(
           (evidence_item ->> 'page_number')::numeric
         )
         or (evidence_item ->> 'page_number')::numeric not between 1 and 500 then
        raise exception using errcode = '22023', message = 'invalid_candidate_evidence';
      end if;
    end if;
  end loop;

  if jsonb_typeof(payload -> 'warnings') <> 'array'
     or jsonb_array_length(payload -> 'warnings') > 7 then
    raise exception using errcode = '22023', message = 'invalid_candidate_warnings';
  end if;
  for warning_item in
    select value from jsonb_array_elements(payload -> 'warnings')
  loop
    if jsonb_typeof(warning_item) <> 'string' then
      raise exception using errcode = '22023', message = 'invalid_candidate_warnings';
    end if;
    warning_value := warning_item #>> '{}';
    if warning_value not in (
         'missing_year', 'missing_date', 'missing_time', 'ambiguous_course',
         'duplicate_mention', 'relative_date', 'low_confidence'
       )
       or warning_value = any(seen_warnings) then
      raise exception using errcode = '22023', message = 'invalid_candidate_warnings';
    end if;
    seen_warnings := array_append(seen_warnings, warning_value);
  end loop;

  missing_date := seen_warnings && array['missing_date', 'missing_year'];
  due_at := case when jsonb_typeof(payload -> 'due_at') = 'string'
    then (payload ->> 'due_at')::timestamptz else null end;
  start_at := case when jsonb_typeof(payload -> 'start_at') = 'string'
    then (payload ->> 'start_at')::timestamptz else null end;
  end_at := case when jsonb_typeof(payload -> 'end_at') = 'string'
    then (payload ->> 'end_at')::timestamptz else null end;

  if (payload ->> 'all_day')::boolean and due_at is null then
    raise exception using errcode = '22023', message = 'invalid_candidate_dates';
  end if;
  if end_at is not null and (start_at is null or end_at <= start_at) then
    raise exception using errcode = '22023', message = 'invalid_candidate_dates';
  end if;
  if candidate_type = 'assignment'
     and (start_at is not null or end_at is not null or (due_at is null and not missing_date)) then
    raise exception using errcode = '22023', message = 'invalid_assignment_candidate';
  end if;
  if candidate_type = 'exam'
     and (due_at is not null or (payload ->> 'all_day')::boolean
       or (start_at is null and not missing_date)) then
    raise exception using errcode = '22023', message = 'invalid_exam_candidate';
  end if;
end;
$$;

revoke execute on function private.assert_document_candidate_payload(jsonb, text)
from public, anon, authenticated, service_role;

create or replace function public.create_document_source(
  p_source_id uuid,
  p_media_type text,
  p_byte_size bigint,
  p_content_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
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
  -- overwrite a tombstone (including one owned by another account). A lost
  -- response still replays through the active owner/content-hash row above.
  v_insert_source_id := p_source_id;
  while exists (
    select 1 from public.document_sources where id = v_insert_source_id
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

create or replace function public.mark_document_source_uploaded(p_source_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, storage
as $$
declare
  v_owner uuid := auth.uid();
  v_source public.document_sources%rowtype;
begin
  if v_owner is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  select * into v_source
  from public.document_sources
  where id = p_source_id and owner_user_id = v_owner
  for update;
  if not found
     or v_source.deleted_at is not null
     or v_source.retention_expires_at <= clock_timestamp() then
    raise exception using errcode = 'P0002', message = 'document_source_not_found';
  end if;
  if v_source.processing_state <> 'pending_upload' then
    return jsonb_build_object(
      'source_id', v_source.id,
      'processing_state', v_source.processing_state,
      'version', v_source.version,
      'replayed', true
    );
  end if;
  if not exists (
    select 1 from storage.objects object
    where object.bucket_id = 'schedule-documents'
      and object.name = v_source.storage_path
  ) then
    raise exception using errcode = 'P0002', message = 'document_object_not_found';
  end if;
  update public.document_sources
  set processing_state = case
        when processing_state = 'pending_upload' then 'uploaded'
        else processing_state
      end,
      updated_at = clock_timestamp(),
      version = version + 1
  where id = p_source_id
  returning * into v_source;
  return jsonb_build_object(
    'source_id', v_source.id,
    'processing_state', v_source.processing_state,
    'version', v_source.version,
    'replayed', false
  );
end;
$$;

revoke execute on function public.mark_document_source_uploaded(uuid)
from public, anon, service_role;
grant execute on function public.mark_document_source_uploaded(uuid)
to authenticated;

create or replace function public.begin_document_processing(p_source_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_owner uuid := auth.uid();
  v_source public.document_sources%rowtype;
begin
  if v_owner is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  select * into v_source
  from public.document_sources
  where id = p_source_id and owner_user_id = v_owner
  for update;
  if not found
     or v_source.deleted_at is not null
     or v_source.retention_expires_at <= clock_timestamp() then
    raise exception using errcode = 'P0002', message = 'document_source_not_found';
  end if;
  if v_source.processing_state = 'pending_upload' then
    raise exception using errcode = '22023', message = 'document_upload_incomplete';
  end if;
  if v_source.processing_state = 'processed' then
    return jsonb_build_object(
      'source_id', v_source.id,
      'processing_state', v_source.processing_state,
      'attempt_count', v_source.processing_attempt_count,
      'version', v_source.version,
      'replayed', true
    );
  end if;
  if v_source.processing_state = 'processing'
     and v_source.updated_at > clock_timestamp() - interval '2 minutes' then
    raise exception using errcode = 'P0001', message = 'document_processing_in_progress';
  end if;
  if v_source.retry_after_at is not null
     and v_source.retry_after_at > clock_timestamp() then
    raise exception using errcode = 'P0001', message = 'document_retry_delayed';
  end if;
  if v_source.processing_attempt_count >= 5 then
    raise exception using errcode = 'P0001', message = 'document_attempt_limit';
  end if;

  update public.document_sources
  set processing_state = 'processing',
      error_category = null,
      retry_after_at = null,
      processing_attempt_count = processing_attempt_count + 1,
      updated_at = clock_timestamp(),
      version = version + 1
  where id = p_source_id
  returning * into v_source;

  return jsonb_build_object(
    'source_id', v_source.id,
    'processing_state', v_source.processing_state,
    'attempt_count', v_source.processing_attempt_count,
    'version', v_source.version,
    'replayed', false
  );
end;
$$;

revoke execute on function public.begin_document_processing(uuid)
from public, anon, service_role;
grant execute on function public.begin_document_processing(uuid)
to authenticated;

create or replace function public.fail_document_processing(
  p_source_id uuid,
  p_expected_version bigint,
  p_error_category text,
  p_retry_after_seconds integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_owner uuid := auth.uid();
  v_source public.document_sources%rowtype;
  v_retryable boolean;
begin
  if v_owner is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_expected_version is null
     or p_expected_version < 1
     or p_error_category is null
     or p_error_category not in (
       'configuration_missing', 'unsupported_type', 'oversized_file',
       'oversized_document', 'corrupt_document', 'encrypted_document',
       'spoofed_media_type', 'unsafe_content', 'invalid_extraction',
       'rate_limited', 'timeout', 'network_unavailable',
       'provider_unavailable', 'cancelled', 'internal_error'
     )
     or (p_retry_after_seconds is not null
       and p_retry_after_seconds not between 0 and 86400) then
    raise exception using errcode = '22023', message = 'invalid_document_failure';
  end if;
  v_retryable := p_error_category in (
    'rate_limited', 'timeout', 'network_unavailable',
    'provider_unavailable', 'cancelled', 'internal_error'
  );
  if not v_retryable and coalesce(p_retry_after_seconds, 0) <> 0 then
    raise exception using errcode = '22023', message = 'invalid_document_retry';
  end if;

  select * into v_source
  from public.document_sources
  where id = p_source_id and owner_user_id = v_owner
  for update;
  if not found or v_source.deleted_at is not null then
    raise exception using errcode = 'P0002', message = 'document_source_not_found';
  end if;
  if v_source.processing_state <> 'processing'
     or v_source.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'document_processing_version_conflict';
  end if;

  update public.document_sources
  set processing_state = 'failed',
      error_category = p_error_category,
      retry_after_at = case
        when v_retryable and coalesce(p_retry_after_seconds, 0) > 0
          then clock_timestamp() + make_interval(secs => p_retry_after_seconds)
        else null
      end,
      updated_at = clock_timestamp(),
      version = version + 1
  where id = p_source_id
  returning * into v_source;

  return jsonb_build_object(
    'source_id', v_source.id,
    'processing_state', v_source.processing_state,
    'error_category', v_source.error_category,
    'retry_after_at', v_source.retry_after_at,
    'attempt_count', v_source.processing_attempt_count,
    'version', v_source.version
  );
end;
$$;

revoke execute on function public.fail_document_processing(
  uuid, bigint, text, integer
) from public, anon, service_role;
grant execute on function public.fail_document_processing(
  uuid, bigint, text, integer
) to authenticated;

create or replace function public.replace_document_candidates(
  p_source_id uuid,
  p_content_hash text,
  p_expected_version bigint,
  p_batch jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_source public.document_sources%rowtype;
  v_candidate jsonb;
  v_candidate_count integer;
  v_owner uuid := auth.uid();
begin
  select * into v_source
  from public.document_sources
  where id = p_source_id
  for update;
  if not found
     or v_source.deleted_at is not null
     or v_source.retention_expires_at <= clock_timestamp() then
    raise exception using errcode = 'P0002', message = 'document_source_not_found';
  end if;
  if v_owner is null or v_owner <> v_source.owner_user_id then
    raise exception using errcode = '42501', message = 'document_source_forbidden';
  end if;
  if p_content_hash is distinct from v_source.content_hash
     or p_batch is null
     or jsonb_typeof(p_batch) <> 'object'
     or pg_column_size(p_batch) > 262144 then
    raise exception using errcode = '22023', message = 'invalid_candidate_batch';
  end if;
  if (select count(*) from jsonb_object_keys(p_batch)) <> 5
     or not p_batch ?& array[
       'schema_version', 'source_id', 'content_hash', 'timezone', 'candidates'
     ]
     or p_batch ->> 'schema_version' is distinct from '1.0'
     or p_batch ->> 'source_id' is distinct from p_source_id::text
     or p_batch ->> 'content_hash' is distinct from p_content_hash
     or p_batch ->> 'timezone' is distinct from 'Asia/Tokyo'
     or jsonb_typeof(p_batch -> 'candidates') <> 'array' then
    raise exception using errcode = '22023', message = 'invalid_candidate_batch';
  end if;

  if v_source.processing_state = 'processed' then
    return jsonb_build_object(
      'source_id', p_source_id,
      'processing_state', v_source.processing_state,
      'candidate_count', (
        select count(*) from public.document_candidates
        where source_id = p_source_id and deleted_at is null
      ),
      'version', v_source.version,
      'replayed', true
    );
  end if;
  if v_source.processing_state <> 'processing' then
    raise exception using errcode = '22023', message = 'document_processing_not_claimed';
  end if;
  if p_expected_version is null or p_expected_version <> v_source.version then
    raise exception using errcode = '40001', message = 'document_processing_version_conflict';
  end if;

  v_candidate_count := jsonb_array_length(p_batch -> 'candidates');
  if v_candidate_count > 20 then
    raise exception using errcode = '22023', message = 'too_many_candidates';
  end if;

  delete from public.document_candidates
  where source_id = p_source_id and review_state <> 'confirmed';

  for v_candidate in
    select value from jsonb_array_elements(p_batch -> 'candidates')
  loop
    perform private.assert_document_candidate_payload(v_candidate);
    insert into public.document_candidates (
      owner_user_id,
      source_id,
      candidate_key,
      candidate_type,
      validated_payload,
      semantic_fingerprint
    ) values (
      v_source.owner_user_id,
      p_source_id,
      v_candidate ->> 'candidate_id',
      v_candidate ->> 'type',
      v_candidate,
      private.document_payload_fingerprint(v_candidate)
    );
  end loop;

  select count(*) into v_candidate_count
  from public.document_candidates
  where source_id = p_source_id and deleted_at is null;

  update public.document_sources
  set processing_state = 'processed',
      error_category = null,
      retry_after_at = null,
      updated_at = clock_timestamp(),
      version = version + 1
  where id = p_source_id
  returning * into v_source;

  return jsonb_build_object(
    'source_id', p_source_id,
    'processing_state', v_source.processing_state,
    'candidate_count', v_candidate_count,
    'version', v_source.version,
    'replayed', false
  );
end;
$$;

revoke execute on function public.replace_document_candidates(uuid, text, bigint, jsonb)
from public, anon, service_role;
grant execute on function public.replace_document_candidates(uuid, text, bigint, jsonb)
to authenticated;

create or replace function public.update_document_candidate(
  p_candidate_id uuid,
  p_expected_version bigint,
  p_payload jsonb default null,
  p_action text default 'edit'
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_owner uuid := auth.uid();
  v_candidate public.document_candidates%rowtype;
  v_next_state text;
  v_selected boolean;
  v_payload jsonb;
  v_payload_fingerprint text;
begin
  if v_owner is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_expected_version is null or p_expected_version < 1 then
    raise exception using errcode = '22023', message = 'invalid_document_review_version';
  end if;
  select * into v_candidate
  from public.document_candidates
  where id = p_candidate_id and owner_user_id = v_owner
  for update;
  if not found or v_candidate.deleted_at is not null then
    raise exception using errcode = 'P0002', message = 'document_candidate_not_found';
  end if;
  if v_candidate.review_state = 'confirmed' then
    raise exception using errcode = '22023', message = 'document_candidate_already_confirmed';
  end if;

  v_payload := coalesce(p_payload, v_candidate.validated_payload);
  if p_payload is not null then
    perform private.assert_document_candidate_payload(
      p_payload,
      v_candidate.candidate_key
    );
  end if;
  v_next_state := v_candidate.review_state;
  v_selected := v_candidate.is_selected;
  case p_action
    when 'edit' then
      perform private.assert_document_candidate_payload(v_payload, v_candidate.candidate_key);
      v_next_state := 'needs_review';
    when 'select' then
      v_selected := true;
      v_next_state := 'needs_review';
    when 'deselect' then
      v_selected := false;
      v_next_state := 'needs_review';
    when 'exclude' then
      v_selected := false;
      v_next_state := 'excluded';
    when 'restore' then
      v_selected := true;
      v_next_state := 'needs_review';
    else
      raise exception using errcode = '22023', message = 'invalid_document_review_action';
  end case;
  v_payload_fingerprint := private.document_payload_fingerprint(v_payload);

  if v_candidate.version <> p_expected_version then
    -- Heal a response-loss retry only when exactly one version was committed
    -- and the requested action's complete persisted postcondition is already
    -- present. A genuinely stale/different mutation remains a conflict.
    if p_expected_version = v_candidate.version - 1
       and v_candidate.validated_payload = v_payload
       and v_candidate.candidate_type = v_payload ->> 'type'
       and v_candidate.semantic_fingerprint = v_payload_fingerprint
       and v_candidate.review_state = v_next_state
       and v_candidate.is_selected = v_selected then
      return jsonb_build_object(
        'candidate_id', v_candidate.id,
        'review_state', v_candidate.review_state,
        'is_selected', v_candidate.is_selected,
        'version', v_candidate.version,
        'replayed', true
      );
    end if;
    raise exception using errcode = '40001', message = 'document_candidate_version_conflict';
  end if;

  update public.document_candidates
  set validated_payload = v_payload,
      candidate_type = v_payload ->> 'type',
      semantic_fingerprint = v_payload_fingerprint,
      review_state = v_next_state,
      is_selected = v_selected,
      updated_at = clock_timestamp(),
      version = version + 1
  where id = p_candidate_id
  returning * into v_candidate;

  return jsonb_build_object(
    'candidate_id', v_candidate.id,
    'review_state', v_candidate.review_state,
    'is_selected', v_candidate.is_selected,
    'version', v_candidate.version,
    'replayed', false
  );
end;
$$;

revoke execute on function public.update_document_candidate(uuid, bigint, jsonb, text)
from public, anon, service_role;
grant execute on function public.update_document_candidate(uuid, bigint, jsonb, text)
to authenticated;

create or replace function public.confirm_document_candidate(
  p_candidate_id uuid,
  p_expected_version bigint,
  p_entity_id uuid,
  p_idempotency_key text,
  p_confirmed_payload jsonb,
  p_course_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_owner uuid := auth.uid();
  v_candidate public.document_candidates%rowtype;
  v_existing public.document_confirmations%rowtype;
  v_request_hash text;
  v_candidate_fingerprint text;
  v_semantic_fingerprint text;
  v_entity_type text;
  v_response jsonb;
  v_due_at timestamptz;
  v_start_at timestamptz;
  v_end_at timestamptz;
begin
  if v_owner is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  if p_expected_version is null
     or p_expected_version < 1
     or p_entity_id is null
     or p_idempotency_key is null
     or char_length(p_idempotency_key) not between 1 and 200 then
    raise exception using errcode = '22023', message = 'invalid_confirmation_request';
  end if;
  perform private.assert_document_candidate_payload(p_confirmed_payload);

  v_request_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'candidate_id', p_candidate_id,
    'entity_id', p_entity_id,
    'course_id', p_course_id,
    'payload', p_confirmed_payload
  )::text, 'UTF8'), 'sha256'), 'hex');

  select * into v_existing
  from public.document_confirmations
  where owner_user_id = v_owner and idempotency_key = p_idempotency_key;
  if found then
    if v_existing.request_hash <> v_request_hash then
      raise exception using errcode = '22023', message = 'idempotency_key_reused';
    end if;
    return v_existing.response || jsonb_build_object('replayed', true);
  end if;

  select * into v_candidate
  from public.document_candidates
  where id = p_candidate_id and owner_user_id = v_owner
  for update;
  if not found or v_candidate.deleted_at is not null then
    raise exception using errcode = 'P0002', message = 'document_candidate_not_found';
  end if;
  if v_candidate.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'document_candidate_version_conflict';
  end if;
  if v_candidate.review_state <> 'needs_review' or not v_candidate.is_selected then
    raise exception using errcode = '22023', message = 'document_candidate_not_confirmable';
  end if;
  if p_confirmed_payload ->> 'candidate_id' <> v_candidate.candidate_key then
    raise exception using errcode = '22023', message = 'document_candidate_identity_mismatch';
  end if;

  v_entity_type := p_confirmed_payload ->> 'type';
  v_candidate_fingerprint := private.document_payload_fingerprint(
    p_confirmed_payload
  );
  if p_course_id is not null and not exists (
    select 1 from public.user_courses
    where id = p_course_id and owner_user_id = v_owner and deleted_at is null
  ) then
    raise exception using errcode = '42501', message = 'document_course_forbidden';
  end if;

  if v_entity_type = 'assignment' then
    begin
      v_due_at := (p_confirmed_payload ->> 'due_at')::timestamptz;
    exception when others then
      raise exception using errcode = '22023', message = 'assignment_due_at_required';
    end;
    if v_due_at is null then
      raise exception using errcode = '22023', message = 'assignment_due_at_required';
    end if;
  elsif v_entity_type = 'exam' then
    begin
      v_start_at := (p_confirmed_payload ->> 'start_at')::timestamptz;
      v_end_at := (p_confirmed_payload ->> 'end_at')::timestamptz;
    exception when others then
      raise exception using errcode = '22023', message = 'exam_time_range_required';
    end;
    if v_start_at is null or v_end_at is null or v_end_at <= v_start_at then
      raise exception using errcode = '22023', message = 'exam_time_range_required';
    end if;
  else
    raise exception using errcode = '22023', message = 'unsupported_candidate_type';
  end if;

  -- Course linkage is part of the canonical schedule entity. Two identical
  -- payloads confirmed against different courses must not silently reuse an
  -- entity whose persisted course differs from the user's explicit choice.
  v_semantic_fingerprint := encode(extensions.digest(convert_to(
    jsonb_build_object(
      'candidate_fingerprint', v_candidate_fingerprint,
      'course_id', p_course_id
    )::text,
    'UTF8'
  ), 'sha256'), 'hex');
  perform pg_advisory_xact_lock(
    hashtextextended(v_owner::text || ':' || v_semantic_fingerprint, 0)
  );

  -- A confirmation receipt is provenance, not proof that its schedule entity
  -- is still canonical. Reuse only a live entity whose current persisted state
  -- exactly matches the reviewed payload and explicit course choice. This keeps
  -- remote dedupe aligned with the mobile canonical-entity verifier after user
  -- edits or soft deletion.
  select confirmation.* into v_existing
  from public.document_confirmations confirmation
  left join public.assignments canonical_assignment
    on confirmation.entity_type = 'assignment'
   and canonical_assignment.id = confirmation.entity_id
   and canonical_assignment.owner_user_id = v_owner
   and canonical_assignment.deleted_at is null
   and canonical_assignment.course_id is not distinct from p_course_id
   and canonical_assignment.title is not distinct from
       (p_confirmed_payload ->> 'title')
   and canonical_assignment.description is not distinct from
       nullif(p_confirmed_payload ->> 'notes', '')
   and canonical_assignment.submission_url is not distinct from
       nullif(p_confirmed_payload ->> 'submission_url', '')
   and canonical_assignment.due_at is not distinct from v_due_at
   and canonical_assignment.visibility_level = 'PRIVATE'
  left join public.exams canonical_exam
    on confirmation.entity_type = 'exam'
   and canonical_exam.id = confirmation.entity_id
   and canonical_exam.owner_user_id = v_owner
   and canonical_exam.deleted_at is null
   and canonical_exam.course_id is not distinct from p_course_id
   and canonical_exam.title is not distinct from
       (p_confirmed_payload ->> 'title')
   and canonical_exam.start_at is not distinct from v_start_at
   and canonical_exam.end_at is not distinct from v_end_at
   and canonical_exam.room is not distinct from
       nullif(p_confirmed_payload ->> 'location', '')
   and canonical_exam.memo is not distinct from
       nullif(p_confirmed_payload ->> 'notes', '')
   and canonical_exam.visibility_level = 'PRIVATE'
  where confirmation.owner_user_id = v_owner
    and confirmation.semantic_fingerprint = v_semantic_fingerprint
    and confirmation.entity_type = v_entity_type
    and (
      (v_entity_type = 'assignment' and canonical_assignment.id is not null)
      or (v_entity_type = 'exam' and canonical_exam.id is not null)
    )
  order by confirmation.confirmed_at, confirmation.id
  limit 1;

  if found then
    v_response := jsonb_build_object(
      'candidate_id', p_candidate_id,
      'entity_type', v_existing.entity_type,
      'entity_id', v_existing.entity_id,
      'deduplicated', true,
      'replayed', true
    );
  else
    if v_entity_type = 'assignment' then
      insert into public.assignments (
        id, owner_user_id, course_id, title, description, submission_url,
        due_at, visibility_level
      ) values (
        p_entity_id,
        v_owner,
        p_course_id,
        p_confirmed_payload ->> 'title',
        nullif(p_confirmed_payload ->> 'notes', ''),
        nullif(p_confirmed_payload ->> 'submission_url', ''),
        v_due_at,
        'PRIVATE'
      );
    elsif v_entity_type = 'exam' then
      insert into public.exams (
        id, owner_user_id, course_id, title, start_at, end_at, room, memo,
        visibility_level
      ) values (
        p_entity_id,
        v_owner,
        p_course_id,
        p_confirmed_payload ->> 'title',
        v_start_at,
        v_end_at,
        nullif(p_confirmed_payload ->> 'location', ''),
        nullif(p_confirmed_payload ->> 'notes', ''),
        'PRIVATE'
      );
    end if;

    v_response := jsonb_build_object(
      'candidate_id', p_candidate_id,
      'entity_type', v_entity_type,
      'entity_id', p_entity_id,
      'deduplicated', false,
      'replayed', false
    );
  end if;

  insert into public.document_confirmations (
    owner_user_id,
    source_id,
    candidate_id,
    idempotency_key,
    request_hash,
    semantic_fingerprint,
    entity_type,
    entity_id,
    response,
    deduplicated
  ) values (
    v_owner,
    v_candidate.source_id,
    v_candidate.id,
    p_idempotency_key,
    v_request_hash,
    v_semantic_fingerprint,
    v_response ->> 'entity_type',
    (v_response ->> 'entity_id')::uuid,
    v_response,
    (v_response ->> 'deduplicated')::boolean
  );

  update public.document_candidates
  set validated_payload = p_confirmed_payload,
      candidate_type = v_response ->> 'entity_type',
      semantic_fingerprint = v_candidate_fingerprint,
      review_state = 'confirmed',
      linked_entity_type = v_response ->> 'entity_type',
      linked_entity_id = (v_response ->> 'entity_id')::uuid,
      confirmed_at = clock_timestamp(),
      updated_at = clock_timestamp(),
      version = version + 1
  where id = p_candidate_id;

  return v_response;
end;
$$;

revoke execute on function public.confirm_document_candidate(
  uuid, bigint, uuid, text, jsonb, uuid
) from public, anon, service_role;
grant execute on function public.confirm_document_candidate(
  uuid, bigint, uuid, text, jsonb, uuid
) to authenticated;

create or replace function public.delete_document_source(p_source_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_owner uuid := auth.uid();
  v_path text;
begin
  if v_owner is null then
    raise exception using errcode = '42501', message = 'authentication_required';
  end if;
  select storage_path into v_path
  from public.document_sources
  where id = p_source_id and owner_user_id = v_owner
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'document_source_not_found';
  end if;

  update public.document_sources
  set processing_state = 'deleted',
      error_category = null,
      retry_after_at = null,
      retention_expires_at = greatest(
        created_at + interval '1 microsecond',
        least(retention_expires_at, clock_timestamp())
      ),
      deleted_at = coalesce(deleted_at, clock_timestamp()),
      updated_at = clock_timestamp(),
      version = version + 1
  where id = p_source_id and deleted_at is null;

  update public.document_candidates
  set review_state = case when review_state = 'confirmed' then review_state else 'excluded' end,
      is_selected = false,
      deleted_at = coalesce(deleted_at, clock_timestamp()),
      updated_at = clock_timestamp(),
      version = version + 1
  where source_id = p_source_id and deleted_at is null;

  return jsonb_build_object(
    'source_id', p_source_id,
    'storage_path', v_path,
    'schedule_entities_retained', true,
    'storage_deletion_queued', true
  );
end;
$$;

revoke execute on function public.delete_document_source(uuid)
from public, anon, service_role;
grant execute on function public.delete_document_source(uuid)
to authenticated;

create or replace function public.claim_expired_document_sources(
  p_limit integer default 100
)
returns table (source_id uuid, storage_path text)
language plpgsql
security definer
set search_path = pg_catalog, public, storage
as $$
declare
  v_source public.document_sources%rowtype;
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception using errcode = '42501', message = 'service_role_required';
  end if;
  if p_limit is null or p_limit not between 1 and 500 then
    raise exception using errcode = '22023', message = 'invalid_cleanup_limit';
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
    limit p_limit
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

create trigger document_sources_updated_at
before update on public.document_sources
for each row execute function public.set_updated_at();

create trigger document_candidates_updated_at
before update on public.document_candidates
for each row execute function public.set_updated_at();

comment on table public.document_sources is
  'Owner-private document metadata. Raw bytes remain in private Storage and expire after 30 days by policy.';
comment on table public.document_candidates is
  'Strict validated proposals only; no schedule side effect exists before explicit confirmation.';
comment on table public.document_confirmations is
  'Idempotent confirmation receipts. Source deletion never cascades into created schedule entities.';
comment on function public.begin_document_processing(uuid) is
  'Atomically claims one owner source for extraction, increments attempts, enforces retry delay and returns the version token required by success/failure RPCs.';
comment on function public.fail_document_processing(uuid, bigint, text, integer) is
  'Records one version-checked extraction failure with a bounded category and optional retry delay.';
comment on function public.replace_document_candidates(uuid, text, bigint, jsonb) is
  'Version-checked success transition for one exact, bounded candidate batch; processed replay is side-effect free.';
comment on function public.confirm_document_candidate(uuid, bigint, uuid, text, jsonb, uuid) is
  'Atomically creates one private assignment or exam after explicit confirmation and deduplicates semantic replay.';
comment on function public.claim_expired_document_sources(integer) is
  'Service-worker claim: closes private DB visibility first and returns Storage paths. The worker must delete each object through the Storage API; rows remain claimable while an expired object still exists so deletion can be retried.';

commit;
