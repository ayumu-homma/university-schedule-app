-- Bind every OAuth callback to the exact requested connection and server
-- correlation. Duplicate Gmail-account completion may keep an older effective
-- connection row, so authenticated clients must never guess by recency.
begin;

create table private.email_oauth_completion_receipts (
  owner_user_id uuid not null references auth.users(id) on delete cascade,
  requested_connection_id uuid not null,
  correlation_id uuid not null,
  effective_connection_id uuid,
  callback_outcome text not null,
  connection_state text not null,
  error_category text,
  connected_at timestamptz,
  completed_at timestamptz not null,
  constraint email_oauth_completion_receipts_pk
    primary key (owner_user_id, requested_connection_id, correlation_id),
  constraint email_oauth_completion_receipts_owner_correlation_key
    unique (owner_user_id, correlation_id),
  constraint email_oauth_completion_receipts_effective_fk
    foreign key (effective_connection_id)
    references public.email_connections(id)
    on delete set null,
  constraint email_oauth_completion_receipts_shape check (
    (
      callback_outcome = 'succeeded'
      and connection_state = 'connected'
      and error_category is null
      and connected_at is not null
    )
    or (
      callback_outcome = 'failed'
      and connection_state = 'failed'
      and error_category is not null
      and connected_at is null
    )
  )
);

alter table private.email_oauth_completion_receipts enable row level security;

revoke all on table private.email_oauth_completion_receipts
from public, anon, authenticated, service_role;

comment on table private.email_oauth_completion_receipts is
  'Private owner/request/correlation binding for safe OAuth completion resolution; contains no provider account, address, or credential data.';

create or replace function private.email_import_capture_oauth_completion()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  v_requested_connections uuid[];
  v_requested_connection_id uuid;
  v_effective_connection_id uuid;
  v_connected_at timestamptz;
  v_persisted_correlation_id uuid;
begin
  if new.operation <> 'oauth_callback'
    or new.outcome not in ('succeeded', 'failed')
  then
    return new;
  end if;

  if new.connection_id is null then
    raise exception using errcode = '22023', message = 'Invalid OAuth callback audit.';
  end if;

  select array_agg(distinct event.connection_id)
  into v_requested_connections
  from public.email_import_audit_events event
  where event.owner_user_id = new.owner_user_id
    and event.correlation_id = new.correlation_id
    and event.operation = 'connect'
    and event.outcome = 'started'
    and event.connection_state = 'connecting'
    and event.connection_id is not null;
  if coalesce(cardinality(v_requested_connections), 0) <> 1 then
    raise exception using errcode = '22023', message = 'Missing OAuth attempt correlation.';
  end if;
  v_requested_connection_id := v_requested_connections[1];

  select connection.id, connection.connected_at
  into v_effective_connection_id, v_connected_at
  from public.email_connections connection
  where connection.id = new.connection_id
    and connection.owner_user_id = new.owner_user_id
    and connection.provider = 'gmail';

  if new.outcome = 'succeeded' then
    if new.connection_state <> 'connected'
      or new.error_category is not null
      or v_effective_connection_id is null
      or v_connected_at is null
    then
      raise exception using errcode = '22023', message = 'Invalid OAuth completion audit.';
    end if;
  elsif new.connection_state <> 'failed' or new.error_category is null then
    raise exception using errcode = '22023', message = 'Invalid OAuth failure audit.';
  end if;

  insert into private.email_oauth_completion_receipts (
    owner_user_id,
    requested_connection_id,
    correlation_id,
    effective_connection_id,
    callback_outcome,
    connection_state,
    error_category,
    connected_at,
    completed_at
  ) values (
    new.owner_user_id,
    v_requested_connection_id,
    new.correlation_id,
    v_effective_connection_id,
    new.outcome,
    new.connection_state,
    new.error_category,
    case when new.outcome = 'succeeded' then v_connected_at else null end,
    new.occurred_at
  )
  on conflict (owner_user_id, correlation_id) do update
  set completed_at = email_oauth_completion_receipts.completed_at
  where email_oauth_completion_receipts.requested_connection_id =
      excluded.requested_connection_id
    and email_oauth_completion_receipts.effective_connection_id is not distinct from
      excluded.effective_connection_id
    and email_oauth_completion_receipts.callback_outcome =
      excluded.callback_outcome
    and email_oauth_completion_receipts.connection_state =
      excluded.connection_state
    and email_oauth_completion_receipts.error_category is not distinct from
      excluded.error_category
    and email_oauth_completion_receipts.connected_at is not distinct from
      excluded.connected_at
  returning correlation_id into v_persisted_correlation_id;

  if v_persisted_correlation_id is null then
    raise exception using errcode = '23505', message = 'OAuth callback correlation conflict.';
  end if;

  return new;
end;
$$;

revoke all on function private.email_import_capture_oauth_completion()
from public, anon, authenticated, service_role;

create trigger email_import_capture_oauth_completion
after insert on public.email_import_audit_events
for each row execute function private.email_import_capture_oauth_completion();

create or replace function public.email_import_check_authorization(
  p_owner_user_id uuid,
  p_requested_connection_id uuid,
  p_correlation_id uuid
)
returns jsonb
language sql
security definer
stable
set search_path = pg_catalog, public, private
as $$
  select jsonb_build_object(
    'requested_connection_id', receipt.requested_connection_id,
    'effective_connection_id', coalesce(
      receipt.effective_connection_id,
      receipt.requested_connection_id
    ),
    'connection_state', coalesce(
      connection.connection_state,
      receipt.connection_state
    ),
    'last_error_category', coalesce(
      connection.last_error_category,
      receipt.error_category
    ),
    'retry_after_at', connection.retry_after_at,
    'connected_at', coalesce(connection.connected_at, receipt.connected_at)
  )
  from private.email_oauth_completion_receipts receipt
  left join public.email_connections connection
    on connection.id = receipt.effective_connection_id
    and connection.owner_user_id = receipt.owner_user_id
    and connection.provider = 'gmail'
  where receipt.owner_user_id = p_owner_user_id
    and receipt.requested_connection_id = p_requested_connection_id
    and receipt.correlation_id = p_correlation_id
    and (
      receipt.callback_outcome = 'failed'
      or connection.id is not null
    )
    and receipt.completed_at > clock_timestamp() - interval '30 days';
$$;

revoke all on function public.email_import_check_authorization(uuid, uuid, uuid)
from public, anon, authenticated;
grant execute on function public.email_import_check_authorization(uuid, uuid, uuid)
to service_role;

comment on function public.email_import_check_authorization(uuid, uuid, uuid) is
  'Trusted Edge-only correlation-bound OAuth completion lookup. Returns safe state and opaque connection UUIDs only.';

commit;
