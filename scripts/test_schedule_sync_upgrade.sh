#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

for command_name in supabase docker awk; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required for the schedule-sync upgrade test." >&2
    exit 1
  fi
done

project_id="$(awk -F '"' '/^project_id[[:space:]]*=/{print $2; exit}' supabase/config.toml)"
if [[ -z "$project_id" ]]; then
  echo "The local Supabase project id is unavailable." >&2
  exit 1
fi

# Stop at the last pre-sync migration so these rows genuinely exist before the
# change-log triggers and backfill in 202607100003 are installed.
if ! supabase db reset --local --version 202607100002 --no-seed \
  >/dev/null 2>&1; then
  echo "The pre-sync local database reset failed." >&2
  exit 1
fi

db_container="$(
  docker ps \
    --filter "label=com.supabase.cli.project=$project_id" \
    --filter 'name=supabase_db_' \
    --format '{{.Names}}' | head -n 1 || true
)"
if [[ -z "$db_container" ]]; then
  echo "The project-scoped local Supabase database is unavailable." >&2
  exit 1
fi

docker exec -i "$db_container" \
  psql --no-psqlrc --set ON_ERROR_STOP=1 --quiet -U postgres -d postgres \
  >/dev/null <<'SQL'
insert into public.universities (
  id, config_key, name, normalized_name, status
)
values (
  '26a72fcd-6e61-5d0f-9c77-350762f2562f',
  'schedule-sync-upgrade-university',
  'Schedule Sync Upgrade University',
  'schedulesyncupgradeuniversity',
  'active'
)
on conflict (id) do nothing;

insert into auth.users (id)
values ('63333333-3333-4333-8333-333333333333');

update public.profiles
set university_id = '26a72fcd-6e61-5d0f-9c77-350762f2562f'
where user_id = '63333333-3333-4333-8333-333333333333';

insert into public.terms (
  id, university_id, name, academic_year, start_date, end_date, term_type,
  created_by, is_template, owner_user_id, status
)
values (
  'a3000000-0000-4000-8000-000000000003',
  '26a72fcd-6e61-5d0f-9c77-350762f2562f',
  'Pre-sync owned term', 2026, '2026-04-01', '2026-09-30', 'semester',
  '63333333-3333-4333-8333-333333333333', false,
  '63333333-3333-4333-8333-333333333333', 'active'
);

insert into public.calendars (id, owner_user_id, name, default_visibility)
values (
  'b3000000-0000-4000-8000-000000000003',
  '63333333-3333-4333-8333-333333333333',
  'Pre-sync calendar', 'PRIVATE'
);

insert into public.user_courses (
  id, owner_user_id, term_id, title, normalized_title, visibility_level
)
values (
  'c3000000-0000-4000-8000-000000000003',
  '63333333-3333-4333-8333-333333333333',
  'a3000000-0000-4000-8000-000000000003',
  'Pre-sync course', 'presynccourse', 'PRIVATE'
);

insert into public.assignments (
  id, owner_user_id, course_id, title, due_at, visibility_level
)
values (
  'd3000000-0000-4000-8000-000000000003',
  '63333333-3333-4333-8333-333333333333',
  'c3000000-0000-4000-8000-000000000003',
  'Pre-sync assignment', '2026-07-20T03:00:00Z', 'PRIVATE'
);

insert into public.assignment_user_states (
  assignment_id, user_id, status, submitted_at
)
values (
  'd3000000-0000-4000-8000-000000000003',
  '63333333-3333-4333-8333-333333333333',
  'submitted', '2026-07-19T03:00:00Z'
);

insert into public.exams (
  id, owner_user_id, course_id, title, start_at, end_at, visibility_level
)
values (
  'e3000000-0000-4000-8000-000000000003',
  '63333333-3333-4333-8333-333333333333',
  'c3000000-0000-4000-8000-000000000003',
  'Pre-sync exam', '2026-07-25T01:00:00Z', '2026-07-25T02:00:00Z',
  'PRIVATE'
);

insert into public.events (
  id, owner_user_id, calendar_id, title, kind, start_at, end_at, created_by
)
values (
  'f3000000-0000-4000-8000-000000000003',
  '63333333-3333-4333-8333-333333333333',
  'b3000000-0000-4000-8000-000000000003',
  'Pre-sync event', 'normal', '2026-07-15T05:00:00Z',
  '2026-07-15T06:00:00Z',
  '63333333-3333-4333-8333-333333333333'
);

insert into public.events (
  id, owner_user_id, calendar_id, title, kind, start_at, end_at, created_by,
  visibility_level, deleted_at, version
)
values (
  'f3000000-0000-4000-8000-000000000004',
  '63333333-3333-4333-8333-333333333333',
  'b3000000-0000-4000-8000-000000000003',
  'Pre-sync deleted event', 'normal', '2026-07-16T05:00:00Z',
  '2026-07-16T06:00:00Z',
  '63333333-3333-4333-8333-333333333333',
  'PRIVATE', '2026-07-17T00:00:00Z', 7
);
SQL

if ! supabase migration up --local >/dev/null 2>&1; then
  echo "Applying the schedule-sync migration to the upgrade fixture failed." >&2
  exit 1
fi

docker exec -i "$db_container" \
  psql --no-psqlrc --set ON_ERROR_STOP=1 --quiet -U postgres -d postgres \
  >/dev/null <<'SQL'
do $$
begin
  if (
    select count(*)
    from private.schedule_change_log
    where owner_user_id = '63333333-3333-4333-8333-333333333333'
  ) <> 6 then
    raise exception 'schedule-sync backfill did not capture all fixture rows';
  end if;
  if exists (
    select 1
    from private.schedule_change_log
    where owner_user_id = '63333333-3333-4333-8333-333333333333'
      and (
        operation is distinct from case
          when payload ->> 'deletedAt' is null then 'upsert'
          else 'delete'
        end
        or server_version < 1
        or server_version::text is distinct from payload ->> 'version'
        or payload is null
        or coalesce(payload ->> 'ownerUserId', payload ->> 'userId')
          <> '63333333-3333-4333-8333-333333333333'
      )
  ) then
    raise exception 'schedule-sync backfill produced a malformed canonical row';
  end if;
  if not exists (
    select 1
    from private.schedule_change_log
    where owner_user_id = '63333333-3333-4333-8333-333333333333'
      and entity_type = 'event'
      and entity_id = 'f3000000-0000-4000-8000-000000000004'
      and operation = 'delete'
      and server_version = 7
      and deleted_at is not null
      and payload ->> 'deletedAt' is not null
      and (payload ->> 'version')::bigint = 7
  ) then
    raise exception 'pre-sync tombstone was not preserved by the backfill';
  end if;
  if (
    select last_cursor
    from private.schedule_cursor_heads
    where owner_user_id = '63333333-3333-4333-8333-333333333333'
  ) <> 6 then
    raise exception 'schedule-sync backfill did not initialize the owner cursor';
  end if;
  if (
    select visibility_level
    from public.events
    where id = 'f3000000-0000-4000-8000-000000000003'
  ) <> 'PRIVATE' then
    raise exception 'pre-sync event visibility was not repaired';
  end if;
end;
$$;

begin;
set local request.jwt.claims =
  '{"sub":"63333333-3333-4333-8333-333333333333","role":"authenticated"}';
set local request.jwt.claim.sub = '63333333-3333-4333-8333-333333333333';
set local request.jwt.claim.role = 'authenticated';
set local role authenticated;

with page as (
  select public.get_schedule_delta(0, 500) value
)
select (
  jsonb_array_length(value -> 'changes') = 6
  and (value ->> 'next_cursor')::bigint = 6
  and not (value ->> 'has_more')::boolean
  and (
    select count(distinct change ->> 'entityType')
    from jsonb_array_elements(value -> 'changes') change
  ) = 5
  and exists (
    select 1
    from jsonb_array_elements(value -> 'changes') change
    where change ->> 'entityId' = 'f3000000-0000-4000-8000-000000000004'
      and change ->> 'operation' = 'delete'
      and (change ->> 'serverVersion')::bigint = 7
      and change ->> 'deletedAt' is not null
      and change #>> '{payload,deletedAt}' is not null
  )
) as upgrade_rpc_ok
from page
\gset

\if :upgrade_rpc_ok
\else
  \echo 'The authenticated cursor-zero upgrade pull was incomplete.'
  \quit 1
\endif
rollback;
SQL

echo "Schedule-sync pre-migration backfill: PASS"
