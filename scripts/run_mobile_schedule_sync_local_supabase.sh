#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: bash scripts/run_mobile_schedule_sync_local_supabase.sh [--reset]" >&2
}

reset_local=false
if [[ "${1:-}" == "--reset" ]]; then
  reset_local=true
  shift
fi
if [[ "$#" -ne 0 ]]; then
  usage
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v supabase >/dev/null 2>&1; then
  echo "Supabase CLI is required." >&2
  exit 1
fi
if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter is required." >&2
  exit 1
fi
if ! supabase status >/dev/null 2>&1; then
  echo "A running local Supabase stack is required." >&2
  exit 1
fi

if [[ "$reset_local" == true ]]; then
  # This command is deliberately local-only; no --linked or remote database
  # option is accepted by this runner.
  supabase db reset >/dev/null
fi

unquote() {
  local value="$1"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value#\"}"
    value="${value%\"}"
  fi
  printf '%s' "$value"
}

api_url=''
publishable_key=''
legacy_anon_key=''
while IFS= read -r line; do
  case "$line" in
    API_URL=*) api_url="$(unquote "${line#*=}")" ;;
    PUBLISHABLE_KEY=*) publishable_key="$(unquote "${line#*=}")" ;;
    ANON_KEY=*) legacy_anon_key="$(unquote "${line#*=}")" ;;
    *) ;;
  esac
done < <(supabase status -o env 2>/dev/null)

if [[ -z "$publishable_key" ]]; then
  publishable_key="$legacy_anon_key"
fi
unset legacy_anon_key

if [[ -z "$api_url" || -z "$publishable_key" ]]; then
  echo "The local API URL or public client key is unavailable." >&2
  exit 1
fi

project_id="$(awk -F '"' '/^project_id[[:space:]]*=/{print $2; exit}' supabase/config.toml)"
restart_local_kong() {
  if ! command -v docker >/dev/null 2>&1 || [[ -z "$project_id" ]]; then
    return 1
  fi
  local kong_container
  kong_container="$(
    docker ps \
      --filter "label=com.supabase.cli.project=$project_id" \
      --filter 'name=supabase_kong_' \
      --format '{{.Names}}' | head -n 1
  )"
  [[ -n "$kong_container" ]] || return 1
  docker restart "$kong_container" >/dev/null
}

auth_is_healthy() {
  curl --fail --silent --show-error \
    --max-time 2 "$api_url/auth/v1/health" >/dev/null 2>&1
}

# `supabase db reset` can recreate Auth with a new container address while the
# local Kong proxy still holds its prior upstream. Restart only this project's
# proxy after a requested reset, then require the public Auth route to respond.
if [[ "$reset_local" == true ]]; then
  restart_local_kong || true
fi
for _ in {1..20}; do
  if auth_is_healthy; then
    break
  fi
  sleep 0.5
done
if ! auth_is_healthy; then
  restart_local_kong || true
  for _ in {1..20}; do
    if auth_is_healthy; then
      break
    fi
    sleep 0.5
  done
fi
if ! auth_is_healthy; then
  echo "The local Supabase Auth route is unavailable." >&2
  exit 1
fi

cd apps/mobile
UNIVERSITY_SCHEDULE_LOCAL_SYNC_TEST=1 \
LOCAL_SUPABASE_URL="$api_url" \
LOCAL_SUPABASE_PUBLISHABLE_KEY="$publishable_key" \
flutter test tool_tests/schedule_sync_local_supabase_test.dart \
  --reporter expanded

unset publishable_key
