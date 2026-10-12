#!/usr/bin/env bash

# A Windows-installed Flutter SDK has CRLF shell launchers when entered from
# WSL. Prefer the available Git Bash host for this Windows-emulator runner,
# keeping the test process, Flutter, adb, and Supabase on one side of the
# Windows boundary. If Git Bash is unavailable, the normal shell fallbacks
# below still report a concrete prerequisite failure.
if [[ -n "${WSL_INTEROP:-}" && "${ANDROID_E2E_GIT_BASH_REEXEC:-}" != '1' ]]; then
  git_bash='/mnt/c/Program Files/Git/bin/bash.exe'
  if [[ -f "$git_bash" ]] && command -v wslpath >/dev/null 2>&1; then
    script_path="$(wslpath -w "${BASH_SOURCE[0]}")"
    export ANDROID_E2E_GIT_BASH_REEXEC=1
    exec "$git_bash" "$script_path" "$@"
  fi
fi

set -euo pipefail

usage() {
  echo "Usage: bash scripts/run_android_personal_management_e2e.sh --device-id <emulator-id> [--reset]" >&2
}

device_id=''
reset_local=false
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --device-id)
      [[ "$#" -ge 2 ]] || {
        usage
        exit 2
      }
      device_id="$2"
      shift 2
      ;;
    --reset)
      reset_local=true
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$device_id" || "$device_id" != emulator-* ]]; then
  echo "An explicit Android emulator device ID is required." >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
# shellcheck source=scripts/android_e2e_install_guard.sh
source "$repo_root/scripts/android_e2e_install_guard.sh"
# shellcheck source=scripts/android_e2e_marker_guard.sh
source "$repo_root/scripts/android_e2e_marker_guard.sh"

test_app_package='jp.universityschedule.app.staging'
android_e2e_debug_apk_path="$repo_root/apps/mobile/build/app/outputs/flutter-apk/app-staging-debug.apk"
expected_test_app_uid=''
expected_test_app_first_install_time=''

resolve_supabase_cli() {
  local candidate=''
  if [[ -n "${SUPABASE_CLI:-}" ]]; then
    candidate="$SUPABASE_CLI"
  elif command -v supabase >/dev/null 2>&1; then
    candidate="$(command -v supabase)"
  elif command -v supabase.exe >/dev/null 2>&1; then
    candidate="$(command -v supabase.exe)"
  elif command -v where.exe >/dev/null 2>&1; then
    candidate="$(where.exe supabase 2>/dev/null | head -n 1 | tr -d '\r' || true)"
    if [[ -n "$candidate" ]] && command -v wslpath >/dev/null 2>&1; then
      candidate="$(wslpath -u "$candidate")"
    elif [[ -n "$candidate" ]] && command -v cygpath >/dev/null 2>&1; then
      candidate="$(cygpath -u "$candidate")"
    fi
  fi

  if [[ -z "$candidate" || (! -x "$candidate" && ! -f "$candidate") ]]; then
    echo "supabase is required (set SUPABASE_CLI when running from WSL)." >&2
    return 1
  fi
  printf '%s' "$candidate"
}

supabase_cli="$(resolve_supabase_cli)"

for command_name in flutter curl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required." >&2
    exit 1
  fi
done

devices_json="$(flutter devices --machine)"
if ! grep -Fq "\"id\": \"$device_id\"" <<<"$devices_json"; then
  echo "The requested Android emulator is not connected." >&2
  exit 1
fi
unset devices_json

if ! "$supabase_cli" status >/dev/null 2>&1; then
  echo "A running local Supabase stack is required." >&2
  exit 1
fi

if [[ "$reset_local" == true ]]; then
  # Local-only reset: this runner never accepts linked or remote DB options.
  "$supabase_cli" db reset --local >/dev/null
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
done < <("$supabase_cli" status -o env 2>/dev/null)

if [[ -z "$publishable_key" ]]; then
  publishable_key="$legacy_anon_key"
fi
unset legacy_anon_key

case "$api_url" in
  http://127.0.0.1:* | http://localhost:*) ;;
  *)
    echo "The runner accepts only a loopback local Supabase API." >&2
    exit 1
    ;;
esac
if [[ -z "$publishable_key" ]]; then
  echo "The local public Supabase client key is unavailable." >&2
  exit 1
fi

if ! curl --fail --silent --show-error --max-time 3 \
  "$api_url/auth/v1/health" >/dev/null; then
  echo "The local Supabase Auth route is unavailable." >&2
  exit 1
fi
if ! curl --fail --silent --show-error --max-time 3 \
  "http://127.0.0.1:54324/api/v1/info" >/dev/null; then
  echo "The local Mailpit route is unavailable." >&2
  exit 1
fi

emulator_loopback_host='127.0.0.1'
emulator_api_url="${api_url/localhost/$emulator_loopback_host}"
emulator_mailpit_port='54324'
emulator_mailpit_url="http://$emulator_loopback_host:$emulator_mailpit_port"
emulator_supabase_port="${api_url##*:}"
if ! [[ "$emulator_supabase_port" =~ ^[0-9]{1,5}$ ]]; then
  echo "The local Supabase API must expose a numeric loopback port." >&2
  exit 1
fi

adb_command=''
for candidate in \
  "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
  "${ANDROID_HOME:-}/platform-tools/adb"; do
  if [[ "$candidate" != '/platform-tools/adb' && -x "$candidate" ]]; then
    adb_command="$candidate"
    break
  fi
done
if [[ -z "$adb_command" && -f apps/mobile/android/local.properties ]]; then
  local_sdk_dir="$(
    awk -F= '$1 == "sdk.dir" {print substr($0, index($0, "=") + 1); exit}' \
      apps/mobile/android/local.properties
  )"
  local_sdk_dir="${local_sdk_dir//\\\\/\\}"
  if command -v cygpath >/dev/null 2>&1; then
    local_sdk_dir="$(cygpath -u "$local_sdk_dir")"
  elif command -v wslpath >/dev/null 2>&1; then
    local_sdk_dir="$(wslpath -u "$local_sdk_dir")"
  fi
  for local_adb in \
    "$local_sdk_dir/platform-tools/adb" \
    "$local_sdk_dir/platform-tools/adb.exe"; do
    if [[ -x "$local_adb" ]]; then
      adb_command="$local_adb"
      break
    fi
  done
fi
if [[ -z "$adb_command" ]] && command -v adb >/dev/null 2>&1; then
  adb_command="$(command -v adb)"
fi
if [[ -z "$adb_command" ]]; then
  echo "adb is required to prepare and verify the explicit Android emulator." >&2
  exit 1
fi

# Fail before the runner clears or updates any app data. Flutter automatically
# uninstalls an existing Android app when `adb install -r` fails, so low disk
# space would otherwise erase the auth and Drift state this flow verifies.
android_e2e_require_install_headroom \
  "$adb_command" "$device_id" "$android_e2e_debug_apk_path"

emulator_local_routes_configured=false
network_disabled=false
emulator_state_captured=false
original_emulator_timezone=''
original_auto_time_zone=''
original_auto_timezone_detection=''
original_window_animation_scale=''
original_transition_animation_scale=''
original_animator_duration_scale=''
original_airplane_mode=''
original_wifi_on=''

configure_emulator_local_service_routes() {
  if ! "$adb_command" -s "$device_id" reverse \
    "tcp:$emulator_supabase_port" "tcp:$emulator_supabase_port" \
    >/dev/null 2>&1; then
    echo "Unable to route local Supabase to the selected Android emulator." >&2
    return 1
  fi
  if ! "$adb_command" -s "$device_id" reverse \
    "tcp:$emulator_mailpit_port" "tcp:$emulator_mailpit_port" \
    >/dev/null 2>&1; then
    "$adb_command" -s "$device_id" reverse --remove \
      "tcp:$emulator_supabase_port" >/dev/null 2>&1 || true
    echo "Unable to route local Mailpit to the selected Android emulator." >&2
    return 1
  fi
  emulator_local_routes_configured=true
}

remove_emulator_local_service_routes() {
  local remaining_routes
  "$adb_command" -s "$device_id" reverse --remove \
    "tcp:$emulator_supabase_port" >/dev/null 2>&1 || true
  "$adb_command" -s "$device_id" reverse --remove \
    "tcp:$emulator_mailpit_port" >/dev/null 2>&1 || true
  if ! remaining_routes="$(
    "$adb_command" -s "$device_id" reverse --list 2>/dev/null |
      tr -d '\r'
  )"; then
    echo "Unable to inspect local routes on the selected Android emulator." >&2
    return 1
  fi
  if grep -Eq \
    "(^|[[:space:]])tcp:(${emulator_supabase_port}|${emulator_mailpit_port})([[:space:]]|$)" \
    <<<"$remaining_routes"; then
    echo "Unable to remove local routes from the selected Android emulator." >&2
    return 1
  fi
  emulator_local_routes_configured=false
}

set_emulator_airplane_mode() {
  local action="$1"
  if ! "$adb_command" -s "$device_id" shell cmd connectivity airplane-mode \
    "$action" >/dev/null 2>&1; then
    echo "Unable to set airplane mode on the selected Android emulator." >&2
    return 1
  fi
}

set_emulator_wifi() {
  local action="$1"
  if ! "$adb_command" -s "$device_id" shell svc wifi "$action" \
    >/dev/null 2>&1; then
    echo "Unable to set Wi-Fi on the selected Android emulator." >&2
    return 1
  fi
}

ensure_emulator_wifi_enabled() {
  local wifi_on
  if ! wifi_on="$(read_emulator_global_setting wifi_on)"; then
    echo "Unable to inspect Wi-Fi on the selected Android emulator." >&2
    return 1
  fi
  case "$wifi_on" in
    1) return ;;
    0) set_emulator_wifi enable ;;
    *)
      echo "The selected emulator reported an unsupported Wi-Fi state." >&2
      return 1
      ;;
  esac
}

emulator_local_supabase_tcp_reachable() {
  "$adb_command" -s "$device_id" shell nc -z -w 1 \
    "$emulator_loopback_host" "$emulator_supabase_port" >/dev/null 2>&1
}

emulator_local_mailpit_tcp_reachable() {
  "$adb_command" -s "$device_id" shell nc -z -w 1 \
    "$emulator_loopback_host" "$emulator_mailpit_port" >/dev/null 2>&1
}

wait_for_emulator_local_services_tcp() {
  local deadline=$((SECONDS + 10))
  while true; do
    if emulator_local_supabase_tcp_reachable &&
      emulator_local_mailpit_tcp_reachable; then
      return
    fi
    if (( SECONDS >= deadline )); then
      break
    fi
    sleep 0.1
  done
  echo "The selected emulator cannot reach the local acceptance services." >&2
  return 1
}

disable_emulator_network() {
  if [[ "$network_disabled" == true ]]; then
    return
  fi
  # ADB reverse makes host-loopback routing deterministic across local and CI
  # emulators. Remove the owned routes before the deliberate outage so the app
  # still has to exercise its real offline queue and reconnect behavior.
  remove_emulator_local_service_routes
  # Mark the temporary offline state first so the EXIT trap restores the
  # selected emulator if either transition fails partway through.
  network_disabled=true
  if ! set_emulator_airplane_mode enable; then
    return 1
  fi
  # Some emulator images retain the 10.0.2.2 host route in airplane mode.
  # Disable Wi-Fi as well so the app's local Supabase client actually sees
  # the runner-controlled offline interval.
  set_emulator_wifi disable
}

read_emulator_global_setting() {
  local key="$1"
  "$adb_command" -s "$device_id" shell settings get global "$key" |
    tr -d '\r'
}

read_emulator_timezone() {
  "$adb_command" -s "$device_id" shell getprop persist.sys.timezone |
    tr -d '\r'
}

read_emulator_auto_timezone_detection() {
  "$adb_command" -s "$device_id" shell cmd time_zone_detector \
    is_auto_detection_enabled | tr -d '\r'
}

restore_emulator_auto_timezone_detection() {
  case "$original_auto_timezone_detection" in
    true | false) ;;
    *)
      echo "The selected emulator has no captured automatic-timezone state to restore." >&2
      return 1
      ;;
  esac
  if ! "$adb_command" -s "$device_id" shell cmd time_zone_detector \
    set_auto_detection_enabled "$original_auto_timezone_detection" \
    >/dev/null 2>&1; then
    echo "Unable to restore automatic timezone detection on the selected Android emulator." >&2
    return 1
  fi
  if ! restore_emulator_global_setting \
    auto_time_zone "$original_auto_time_zone"; then
    return 1
  fi
}

wait_for_emulator_timezone() {
  local expected_timezone="$1"
  local deadline=$((SECONDS + 10))
  local observed_timezone=''
  while ((SECONDS < deadline)); do
    observed_timezone="$(read_emulator_timezone || true)"
    if [[ "$observed_timezone" == "$expected_timezone" ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "The selected emulator did not retain the $expected_timezone timezone (observed: ${observed_timezone:-unset})." >&2
  return 1
}

capture_emulator_state() {
  if ! original_emulator_timezone="$(read_emulator_timezone)" ||
    [[ -z "$original_emulator_timezone" ]]; then
    echo "Unable to capture the selected emulator timezone." >&2
    return 1
  fi
  if ! original_auto_time_zone="$(
    read_emulator_global_setting auto_time_zone
  )"; then
    echo "Unable to capture the selected emulator automatic-timezone state." >&2
    return 1
  fi
  case "$original_auto_time_zone" in
    0 | 1 | null) ;;
    *)
      echo "The selected emulator reported an unsupported automatic-timezone state." >&2
      return 1
      ;;
  esac
  if ! original_auto_timezone_detection="$(
    read_emulator_auto_timezone_detection
  )"; then
    echo "Unable to capture automatic timezone detection on the selected Android emulator." >&2
    return 1
  fi
  case "$original_auto_timezone_detection" in
    true | false) ;;
    *)
      echo "The selected emulator reported an unsupported automatic-timezone detector state." >&2
      return 1
      ;;
  esac
  if ! original_window_animation_scale="$(
    read_emulator_global_setting window_animation_scale
  )" || [[ -z "$original_window_animation_scale" ]]; then
    echo "Unable to capture the selected emulator window animation scale." >&2
    return 1
  fi
  if ! original_transition_animation_scale="$(
    read_emulator_global_setting transition_animation_scale
  )" || [[ -z "$original_transition_animation_scale" ]]; then
    echo "Unable to capture the selected emulator transition animation scale." >&2
    return 1
  fi
  if ! original_animator_duration_scale="$(
    read_emulator_global_setting animator_duration_scale
  )" || [[ -z "$original_animator_duration_scale" ]]; then
    echo "Unable to capture the selected emulator animator duration scale." >&2
    return 1
  fi
  if ! original_airplane_mode="$(
    read_emulator_global_setting airplane_mode_on
  )"; then
    echo "Unable to capture the selected emulator airplane-mode state." >&2
    return 1
  fi
  case "$original_airplane_mode" in
    0 | 1) ;;
    *)
      echo "The selected emulator reported an unsupported airplane-mode state." >&2
      return 1
      ;;
  esac
  if ! original_wifi_on="$(read_emulator_global_setting wifi_on)"; then
    echo "Unable to capture the selected emulator Wi-Fi state." >&2
    return 1
  fi
  case "$original_wifi_on" in
    0 | 1) ;;
    *)
      echo "The selected emulator reported an unsupported Wi-Fi state." >&2
      return 1
      ;;
  esac
  emulator_state_captured=true
}

restore_emulator_global_setting() {
  local key="$1"
  local value="$2"
  if [[ "$value" == 'null' ]]; then
    if ! "$adb_command" -s "$device_id" shell settings delete global "$key" \
      >/dev/null 2>&1; then
      echo "Unable to restore the $key setting on the selected Android emulator." >&2
      return 1
    fi
    return 0
  fi
  if ! "$adb_command" -s "$device_id" shell settings put global \
    "$key" "$value" >/dev/null 2>&1; then
    echo "Unable to restore the $key setting on the selected Android emulator." >&2
    return 1
  fi
}

restore_emulator_network() {
  if [[ "$network_disabled" != true ]]; then
    return
  fi
  # Match the known-good bootstrap ordering. Android applies the airplane-mode
  # and Wi-Fi commands asynchronously, so enabling Wi-Fi while airplane mode
  # is still active can let the Flutter phase observe a stale offline route.
  if ! set_emulator_airplane_mode disable; then
    return 1
  fi
  if ! ensure_emulator_wifi_enabled; then
    return 1
  fi
  if ! configure_emulator_local_service_routes; then
    return 1
  fi
  if ! wait_for_emulator_local_services_tcp; then
    return 1
  fi
  network_disabled=false
}

restore_emulator_wifi_state() {
  case "$original_wifi_on" in
    1) set_emulator_wifi enable ;;
    0) set_emulator_wifi disable ;;
    *)
      echo "The selected emulator reported an unsupported Wi-Fi state." >&2
      return 1
      ;;
  esac
}

verify_emulator_restored_state() {
  local deadline=$((SECONDS + 10))
  local observed_timezone=''
  local observed_auto_time_zone=''
  local observed_auto_timezone_detection=''
  local observed_window_animation_scale=''
  local observed_transition_animation_scale=''
  local observed_animator_duration_scale=''
  local observed_airplane_mode=''
  local observed_wifi_on=''
  while ((SECONDS < deadline)); do
    observed_timezone="$(read_emulator_timezone || true)"
    observed_auto_time_zone="$(
      read_emulator_global_setting auto_time_zone || true
    )"
    observed_auto_timezone_detection="$(
      read_emulator_auto_timezone_detection || true
    )"
    observed_window_animation_scale="$(
      read_emulator_global_setting window_animation_scale || true
    )"
    observed_transition_animation_scale="$(
      read_emulator_global_setting transition_animation_scale || true
    )"
    observed_animator_duration_scale="$(
      read_emulator_global_setting animator_duration_scale || true
    )"
    observed_airplane_mode="$(
      read_emulator_global_setting airplane_mode_on || true
    )"
    observed_wifi_on="$(read_emulator_global_setting wifi_on || true)"
    if [[ "$observed_timezone" == "$original_emulator_timezone" &&
      "$observed_auto_time_zone" == "$original_auto_time_zone" &&
      "$observed_auto_timezone_detection" == \
        "$original_auto_timezone_detection" &&
      "$observed_window_animation_scale" == \
        "$original_window_animation_scale" &&
      "$observed_transition_animation_scale" == \
        "$original_transition_animation_scale" &&
      "$observed_animator_duration_scale" == \
        "$original_animator_duration_scale" &&
      "$observed_airplane_mode" == "$original_airplane_mode" &&
      "$observed_wifi_on" == "$original_wifi_on" ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "The selected Android emulator state does not match its captured pre-test state after restoration." >&2
  return 1
}

restore_explicit_emulator_state() {
  local exit_status=$?
  local cleanup_failed=false
  if declare -F retire_local_template_fixture >/dev/null 2>&1; then
    if ! retire_local_template_fixture; then
      cleanup_failed=true
    fi
  fi
  if [[ "$emulator_state_captured" == true ]]; then
    # Keep the current failure paths online before restoring the caller's
    # original airplane-mode setting below.
    if ! restore_emulator_network; then
      cleanup_failed=true
    fi
    if ! restore_emulator_wifi_state; then
      cleanup_failed=true
    fi
    if ! "$adb_command" -s "$device_id" shell cmd alarm set-timezone \
      "$original_emulator_timezone" >/dev/null 2>&1; then
      echo "Unable to restore the timezone on the selected Android emulator." >&2
      cleanup_failed=true
    fi
    if ! restore_emulator_auto_timezone_detection; then
      cleanup_failed=true
    fi
    if ! restore_emulator_global_setting \
      window_animation_scale "$original_window_animation_scale"; then
      cleanup_failed=true
    fi
    if ! restore_emulator_global_setting \
      transition_animation_scale "$original_transition_animation_scale"; then
      cleanup_failed=true
    fi
    if ! restore_emulator_global_setting \
      animator_duration_scale "$original_animator_duration_scale"; then
      cleanup_failed=true
    fi
    if [[ "$original_airplane_mode" == 1 ]]; then
      if ! set_emulator_airplane_mode enable; then
        cleanup_failed=true
      fi
    else
      if ! set_emulator_airplane_mode disable; then
        cleanup_failed=true
      fi
    fi
  fi
  if [[ "$emulator_local_routes_configured" == true ]]; then
    if ! remove_emulator_local_service_routes; then
      cleanup_failed=true
    fi
  fi
  if [[ "$emulator_state_captured" == true ]] &&
    ! verify_emulator_restored_state; then
    cleanup_failed=true
  fi
  if ((exit_status == 0)) && [[ "$cleanup_failed" == true ]]; then
    exit_status=1
  fi
  # Returning from an EXIT trap does not replace Bash's pending exit status.
  # Disable the trap before exiting explicitly so a restoration mismatch turns
  # an otherwise successful acceptance run into a failure without recursion.
  trap - EXIT
  exit "$exit_status"
}

capture_emulator_state
trap restore_explicit_emulator_state EXIT

# Flutter installs the debug app during bootstrap, so its absence here is
# expected. If it is already installed, a failed clear must stop the run.
test_app_path=''
if test_app_path="$(
  "$adb_command" -s "$device_id" shell pm path "$test_app_package" 2>&1
)" && [[ "$test_app_path" == package:* ]]; then
  if ! "$adb_command" -s "$device_id" shell pm clear \
    "$test_app_package" >/dev/null 2>&1; then
    echo "Unable to clear the selected Android test app." >&2
    exit 1
  fi
elif [[ -n "$test_app_path" &&
  "$test_app_path" != *'Unknown package'* &&
  "$test_app_path" != *'not found'* ]]; then
  echo "Unable to inspect the selected Android test app installation." >&2
  exit 1
fi
unset test_app_path
if ! "$adb_command" -s "$device_id" shell cmd time_zone_detector \
  set_auto_detection_enabled false >/dev/null; then
  echo "Unable to disable automatic timezone selection on the emulator." >&2
  exit 1
fi
emulator_auto_timezone_detection="$(
  read_emulator_auto_timezone_detection || true
)"
if [[ "$emulator_auto_timezone_detection" != false ]]; then
  echo "The selected emulator did not disable automatic timezone selection." >&2
  exit 1
fi
if ! "$adb_command" -s "$device_id" shell cmd alarm set-timezone \
  Asia/Tokyo >/dev/null 2>&1; then
  echo "Unable to set the selected emulator timezone to Asia/Tokyo." >&2
  exit 1
fi
if ! wait_for_emulator_timezone Asia/Tokyo; then
  exit 1
fi
"$adb_command" -s "$device_id" shell settings put global \
  window_animation_scale 0 >/dev/null
"$adb_command" -s "$device_id" shell settings put global \
  transition_animation_scale 0 >/dev/null
"$adb_command" -s "$device_id" shell settings put global \
  animator_duration_scale 0 >/dev/null

force_stop_test_app() {
  if ! "$adb_command" -s "$device_id" shell am force-stop \
    "$test_app_package" >/dev/null 2>&1; then
    echo "Unable to force-stop the selected Android test app." >&2
    return 1
  fi
}

# Bootstrap must begin online. The runner will restore this setting again if
# the marker-controlled offline interval exits unexpectedly.
set_emulator_airplane_mode disable
ensure_emulator_wifi_enabled
configure_emulator_local_service_routes
wait_for_emulator_local_services_tcp

cd apps/mobile
e2e_now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
# Letter-prefix the random groups so this opaque identifier cannot resemble a
# numeric date fragment inside the deterministic email-extraction fixtures.
e2e_run_id="$(date -u +'%Y%m%dT%H%M%S')-r${RANDOM}-r${RANDOM}"
e2e_fixture_external_code="android-e2e-catalog-${e2e_run_id}"
e2e_fixture_duplicate_external_code="android-e2e-catalog-duplicate-${e2e_run_id}"
e2e_fixture_title="Android E2E Catalog-${e2e_run_id}"
e2e_fixture_duplicate_title="Android E2E Catalog (${e2e_run_id})"
e2e_fixture_instructor='E2E Instructor'
e2e_fixture_created=false

prepare_local_template_fixture() {
  # This is a local database fixture, not a client credential or service-role
  # request. The production app still reaches it only through the authenticated
  # search/copy RPCs exercised below.
  if ! "$supabase_cli" db query --local "
    do \$\$
    begin
      if not exists (
        select 1 from public.universities
        where config_key = 'university:jp:kit' and status = 'active'
      ) then
        raise exception 'the active KIT local fixture university is required';
      end if;
      insert into public.course_templates (
        university_id, academic_year, title, normalized_title,
        instructor_name, normalized_instructor_name, day_of_week, period_no,
        room, normalized_room, credit_count, external_course_code, status,
        copy_count_total, copy_count_term
      )
      select
        id,
        2026,
        '${e2e_fixture_title}',
        public.normalize_course_text('${e2e_fixture_title}'),
        '${e2e_fixture_instructor}',
        public.normalize_course_text('${e2e_fixture_instructor}'),
        1,
        1,
        'E2E-201',
        public.normalize_course_text('E2E-201'),
        2,
        '${e2e_fixture_external_code}',
        'active',
        14,
        9
      from public.universities
      where config_key = 'university:jp:kit'
        and status = 'active';

      insert into public.course_templates (
        university_id, academic_year, title, normalized_title,
        instructor_name, normalized_instructor_name, day_of_week, period_no,
        room, normalized_room, credit_count, external_course_code, status,
        copy_count_total, copy_count_term
      )
      select
        id,
        2026,
        '${e2e_fixture_duplicate_title}',
        public.normalize_course_text('${e2e_fixture_duplicate_title}'),
        '${e2e_fixture_instructor}',
        public.normalize_course_text('${e2e_fixture_instructor}'),
        1,
        1,
        'E2E-202',
        public.normalize_course_text('E2E-202'),
        2,
        '${e2e_fixture_duplicate_external_code}',
        'active',
        5,
        1
      from public.universities
      where config_key = 'university:jp:kit'
        and status = 'active';
    end
    \$\$;
  " >/dev/null; then
    echo "Unable to prepare the local Android E2E course-template fixture." >&2
    return 1
  fi
  e2e_fixture_created=true
}

retire_local_template_fixture() {
  if [[ "$e2e_fixture_created" != true ]]; then
    return
  fi
  "$supabase_cli" db query --local "
    update public.course_templates
    set status = 'hidden', deleted_at = now()
    where external_course_code in (
      '${e2e_fixture_external_code}',
      '${e2e_fixture_duplicate_external_code}'
    )
      and status = 'active';
  " >/dev/null 2>&1 || true
  e2e_fixture_created=false
}

prepare_local_template_fixture
flutter pub get

run_flutter_phase() {
  local phase="$1"
  local flutter_status=0
  local identity_status=0
  # The bootstrap, bootstrap-exams, personal-management, email-online,
  # email-restart, routine-offline, restart, and convergence phases are
  # separate Flutter test invocations.
  # Keep the target app installed so force-stop exercises its persisted auth
  # session and Drift database instead of turning a later phase into a fresh
  # installation.
  android_e2e_require_install_headroom \
    "$adb_command" "$device_id" "$android_e2e_debug_apk_path" || return 1
  if [[ "$phase" != bootstrap ]]; then
    android_e2e_verify_install_identity \
      "$adb_command" "$device_id" "$test_app_package" \
      "$expected_test_app_uid" "$expected_test_app_first_install_time" || \
      return 1
  fi

  flutter test integration_test/personal_management_e2e_test.dart \
    --device-id "$device_id" \
    --flavor staging \
    --no-uninstall \
    --no-pub \
    --no-track-widget-creation \
    --reporter expanded \
    --dart-define=ANDROID_PERSONAL_E2E=true \
    --dart-define=APP_ENV=test \
    --dart-define=APP_DEEP_LINK_SCHEME=unischedule-staging \
    --dart-define=EMAIL_IMPORT_ENABLED=false \
    --dart-define=ANDROID_E2E_PHASE="$phase" \
    --dart-define=ANDROID_E2E_RUN_ID="$e2e_run_id" \
    --dart-define=ANDROID_E2E_NOW="$e2e_now" \
    --dart-define=SUPABASE_URL="$emulator_api_url" \
    --dart-define=SUPABASE_PUBLISHABLE_KEY="$publishable_key" \
    --dart-define=LOCAL_MAILPIT_URL="$emulator_mailpit_url" || \
    flutter_status=$?

  # Always inspect the package after Flutter returns, including failures. This
  # turns its destructive uninstall fallback into an explicit boundary error.
  if [[ "$phase" != bootstrap ]] && ! android_e2e_verify_install_identity \
    "$adb_command" "$device_id" "$test_app_package" \
    "$expected_test_app_uid" "$expected_test_app_first_install_time"; then
    identity_status=1
  fi
  if ((flutter_status != 0)); then
    return "$flutter_status"
  fi
  return "$identity_status"
}

report_sanitized_e2e_failure() {
  local output_file="$1"
  local summary
  local summary_head
  local summary_tail
  local markers
  summary_head="$(
    grep -Ei -A 12 'error|exception|fail|timeout|timed out|expected|actual|stateerror|overflowed|renderflex|rendering library|relevant error-causing widget|uninstalling old version|install identity|install headroom|══' \
      "$output_file" 2>/dev/null | head -n 40 || true
  )"
  summary_tail="$(
    grep -Ei -A 12 'error|exception|fail|timeout|timed out|expected|actual|stateerror|overflowed|renderflex|rendering library|relevant error-causing widget|uninstalling old version|install identity|install headroom|══' \
      "$output_file" 2>/dev/null | tail -n 80 || true
  )"
  if [[ "$summary_head" == "$summary_tail" ]]; then
    summary="$summary_head"
  elif [[ -n "$summary_head" && -n "$summary_tail" ]]; then
    summary="${summary_head}
... sanitized middle diagnostics omitted ...
${summary_tail}"
  else
    summary="${summary_head}${summary_tail}"
  fi
  if [[ -n "$summary" ]]; then
    summary="$(printf '%s\n' "$summary" | sed -E \
      -e 's#https?://[^[:space:]]+#<redacted-url>#gI' \
      -e 's#Bearer[[:space:]]+[^[:space:],;]+#Bearer <redacted>#gI' \
      -e 's#(token(_hash)?|access_token|refresh_token|password|api[_-]?key|authorization)[=:[:space:]]+[^[:space:],;]+#\1=<redacted>#gI'
    )"
    echo 'Sanitized Android E2E failure summary:' >&2
    printf '%s\n' "$summary" >&2
  fi
  markers="$(grep -E '^ANDROID_E2E_[A-Z_]+$' "$output_file" 2>/dev/null | tail -n 30 || true)"
  if [[ -n "$markers" ]]; then
    echo 'Observed safe Android E2E markers before failure:' >&2
    printf '%s\n' "$markers" >&2
  fi
}

runner_markers_snapshot() {
  android_e2e_runner_markers_snapshot "$adb_command" "$device_id"
}

runner_marker_observed_in_snapshot() {
  local phase="$1"
  local marker="$2"
  local snapshot="$3"
  android_e2e_marker_observed_in_snapshot \
    "$e2e_run_id" "$phase" "$marker" "$snapshot"
}

wait_for_network_marker() {
  local phase="$1"
  local marker="$2"
  local output_file="$3"
  local test_pid="$4"
  shift 4
  local deadline=$((SECONDS + 120))
  local progress_marker
  local observed_progress_markers=''
  local marker_snapshot
  while kill -0 "$test_pid" >/dev/null 2>&1; do
    marker_snapshot="$(runner_markers_snapshot)"
    if runner_marker_observed_in_snapshot \
      "$phase" "$marker" "$marker_snapshot"; then
      echo "Observed Android E2E phase marker: $marker"
      return 0
    fi
    for progress_marker in "$@"; do
      if runner_marker_observed_in_snapshot \
        "$phase" "$progress_marker" "$marker_snapshot" &&
        [[ "|$observed_progress_markers|" != *"|$progress_marker|"* ]]; then
        observed_progress_markers+="|$progress_marker"
        deadline=$((SECONDS + 120))
        echo "Observed Android E2E progress marker: $progress_marker"
      fi
    done
    if (( SECONDS >= deadline )); then
      # A marker can be persisted after the snapshot above but before this
      # deadline check. Re-read the durable marker set at the boundary so a
      # verified terminal/progress checkpoint is never reported as a timeout.
      marker_snapshot="$(runner_markers_snapshot)"
      if runner_marker_observed_in_snapshot \
        "$phase" "$marker" "$marker_snapshot"; then
        echo "Observed Android E2E phase marker: $marker"
        return 0
      fi
      for progress_marker in "$@"; do
        if runner_marker_observed_in_snapshot \
          "$phase" "$progress_marker" "$marker_snapshot" &&
          [[ "|$observed_progress_markers|" != *"|$progress_marker|"* ]]; then
          observed_progress_markers+="|$progress_marker"
          deadline=$((SECONDS + 120))
          echo "Observed Android E2E progress marker: $progress_marker"
        fi
      done
    fi
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for a required Android E2E network marker." >&2
      return 1
    fi
    # A durable marker cannot require sub-second observation. Avoid issuing up
    # to 1,200 run-as/ls processes while Flutter builds, installs, and renders
    # on a shared hosted runner.
    sleep 1
  done
  # The terminal marker can be persisted during the final polling sleep just
  # before a successful test process exits. Require that exact marker once
  # more before treating process exit as an early phase failure.
  marker_snapshot="$(runner_markers_snapshot)"
  if runner_marker_observed_in_snapshot \
    "$phase" "$marker" "$marker_snapshot"; then
    echo "Observed Android E2E phase marker: $marker"
    return 0
  fi
  report_sanitized_e2e_failure "$output_file"
  echo "Android E2E phase ended before a required network marker." >&2
  return 1
}

run_bootstrap_phase() {
  local output_file
  local test_pid
  output_file="$(mktemp)"
  run_flutter_phase bootstrap >"$output_file" 2>&1 &
  test_pid=$!

  if ! wait "$test_pid"; then
    report_sanitized_e2e_failure "$output_file"
    echo "Android E2E online bootstrap phase failed; no authentication data was emitted." >&2
    restore_emulator_network
    rm -f "$output_file"
    return 1
  fi
  expected_test_app_uid="$(
    android_e2e_read_install_uid \
      "$adb_command" "$device_id" "$test_app_package"
  )" || {
    report_sanitized_e2e_failure "$output_file"
    echo "Android E2E bootstrap did not leave a readable package UID." >&2
    rm -f "$output_file"
    return 1
  }
  expected_test_app_first_install_time="$(
    android_e2e_read_first_install_time \
      "$adb_command" "$device_id" "$test_app_package"
  )" || {
    report_sanitized_e2e_failure "$output_file"
    echo "Android E2E bootstrap did not leave a readable install identity." >&2
    rm -f "$output_file"
    return 1
  }
  rm -f "$output_file"
}

run_bootstrap_exams_phase() {
  local output_file
  local test_pid
  output_file="$(mktemp)"
  run_flutter_phase bootstrap-exams >"$output_file" 2>&1 &
  test_pid=$!

  if ! wait "$test_pid"; then
    report_sanitized_e2e_failure "$output_file"
    echo "Android E2E bootstrap-exams phase failed; no authentication data was emitted." >&2
    restore_emulator_network
    rm -f "$output_file"
    return 1
  fi
  rm -f "$output_file"
}

run_personal_management_phase() {
  local output_file
  local test_pid
  output_file="$(mktemp)"
  run_flutter_phase personal-management >"$output_file" 2>&1 &
  test_pid=$!

  if ! wait "$test_pid"; then
    report_sanitized_e2e_failure "$output_file"
    echo "Android E2E personal-management phase failed; no authentication data was emitted." >&2
    restore_emulator_network
    rm -f "$output_file"
    return 1
  fi
  rm -f "$output_file"
}

run_email_online_phase() {
  local output_file
  local test_pid
  output_file="$(mktemp)"
  run_flutter_phase email-online >"$output_file" 2>&1 &
  test_pid=$!

  if ! wait_for_network_marker \
    email-online "$email_offline_ready_marker" "$output_file" "$test_pid" \
    "$email_connection_verified_marker" \
    "$email_inbox_verified_marker" \
    "$email_review_verified_marker" \
    "$email_online_confirmation_verified_marker"; then
    restore_emulator_network || true
    wait "$test_pid" || true
    report_sanitized_e2e_failure "$output_file"
    rm -f "$output_file"
    return 1
  fi
  if ! disable_emulator_network; then
    restore_emulator_network || true
    wait "$test_pid" || true
    rm -f "$output_file"
    return 1
  fi
  if ! wait_for_network_marker \
    email-online "$email_offline_queued_marker" "$output_file" "$test_pid"; then
    restore_emulator_network || true
    wait "$test_pid" || true
    report_sanitized_e2e_failure "$output_file"
    rm -f "$output_file"
    return 1
  fi
  if ! wait "$test_pid"; then
    report_sanitized_e2e_failure "$output_file"
    echo "Android E2E email online/offline phase failed." >&2
    restore_emulator_network || true
    rm -f "$output_file"
    return 1
  fi
  # Keep the target app and emulator offline until the next invocation has
  # proved the email candidate, entity, and mutation survived force-stop.
  rm -f "$output_file"
}

run_email_restart_phase() {
  local output_file
  local test_pid
  output_file="$(mktemp)"
  run_flutter_phase email-restart >"$output_file" 2>&1 &
  test_pid=$!

  if ! wait_for_network_marker \
    email-restart "$email_restart_verified_marker" "$output_file" "$test_pid"; then
    restore_emulator_network || true
    wait "$test_pid" || true
    report_sanitized_e2e_failure "$output_file"
    rm -f "$output_file"
    return 1
  fi
  if ! restore_emulator_network; then
    restore_emulator_network || true
    wait "$test_pid" || true
    rm -f "$output_file"
    return 1
  fi
  if ! wait_for_network_marker \
    email-restart "$email_cleanup_verified_marker" "$output_file" "$test_pid" \
    "$email_converged_marker" \
    "$email_update_verified_marker" \
    "$email_account_isolated_marker"; then
    restore_emulator_network || true
    wait "$test_pid" || true
    report_sanitized_e2e_failure "$output_file"
    rm -f "$output_file"
    return 1
  fi
  if ! wait "$test_pid"; then
    report_sanitized_e2e_failure "$output_file"
    echo "Android E2E email restart/convergence phase failed." >&2
    restore_emulator_network || true
    rm -f "$output_file"
    return 1
  fi
  rm -f "$output_file"
}

run_routine_offline_phase() {
  local output_file
  local test_pid
  output_file="$(mktemp)"
  run_flutter_phase routine-offline >"$output_file" 2>&1 &
  test_pid=$!

  if ! wait_for_network_marker \
    routine-offline "$routine_offline_ready_marker" "$output_file" "$test_pid"; then
    restore_emulator_network
    wait "$test_pid" || true
    report_sanitized_e2e_failure "$output_file"
    rm -f "$output_file"
    return 1
  fi
  # Keep the selected emulator offline until the routine parent/child queue
  # has survived the subsequent explicit Android process restart.
  if ! disable_emulator_network; then
    restore_emulator_network
    wait "$test_pid" || true
    rm -f "$output_file"
    return 1
  fi
  if ! wait_for_network_marker \
    routine-offline "$routine_offline_queued_marker" "$output_file" "$test_pid" \
    "$routine_offline_first_queued_marker"; then
    restore_emulator_network
    wait "$test_pid" || true
    report_sanitized_e2e_failure "$output_file"
    rm -f "$output_file"
    return 1
  fi
  if ! wait "$test_pid"; then
    report_sanitized_e2e_failure "$output_file"
    echo "Android E2E offline routine phase failed; no authentication data was emitted." >&2
    restore_emulator_network
    rm -f "$output_file"
    return 1
  fi
  rm -f "$output_file"
}

run_restart_phase() {
  local output_file
  local test_pid
  output_file="$(mktemp)"
  run_flutter_phase restart >"$output_file" 2>&1 &
  test_pid=$!

  if ! wait_for_network_marker \
    restart "$routine_restart_queue_verified_marker" "$output_file" "$test_pid"; then
    restore_emulator_network || true
    wait "$test_pid" || true
    report_sanitized_e2e_failure "$output_file"
    rm -f "$output_file"
    return 1
  fi
  if ! restore_emulator_network; then
    restore_emulator_network || true
    wait "$test_pid" || true
    rm -f "$output_file"
    return 1
  fi
  if ! wait_for_network_marker \
    restart "$offline_ready_marker" "$output_file" "$test_pid"; then
    restore_emulator_network || true
    wait "$test_pid" || true
    report_sanitized_e2e_failure "$output_file"
    rm -f "$output_file"
    return 1
  fi
  if ! disable_emulator_network; then
    restore_emulator_network || true
    wait "$test_pid" || true
    rm -f "$output_file"
    return 1
  fi

  # Each progress marker follows an assertion inside the Flutter test. Check
  # the causally final marker first on every poll so network restoration is not
  # delayed while the runner serially acknowledges already-completed steps.
  # Newly observed progress still resets the unchanged liveness deadline once.
  if ! wait_for_network_marker \
    restart "$offline_queued_marker" "$output_file" "$test_pid" \
    "$offline_network_disabled_marker" \
    "$offline_event_updated_marker" \
    "$offline_queue_durable_marker" \
    "$offline_settings_rendered_marker"; then
    restore_emulator_network || true
    wait "$test_pid" || true
    report_sanitized_e2e_failure "$output_file"
    rm -f "$output_file"
    return 1
  fi
  if ! wait "$test_pid"; then
    force_stop_test_app || true
    restore_emulator_network || true
    report_sanitized_e2e_failure "$output_file"
    echo "Android E2E restart phase failed; no authentication data was emitted." >&2
    rm -f "$output_file"
    return 1
  fi
  # Keep the old runtime offline until both the Flutter invocation and target
  # app are dead. Otherwise connectivity recovery can push the queued update
  # before the next phase captures its asserted remote baseline.
  if ! force_stop_test_app; then
    restore_emulator_network || true
    rm -f "$output_file"
    return 1
  fi
  if ! restore_emulator_network; then
    restore_emulator_network || true
    rm -f "$output_file"
    return 1
  fi
  rm -f "$output_file"
}

run_convergence_phase() {
  local output_file
  local test_pid
  output_file="$(mktemp)"
  run_flutter_phase convergence >"$output_file" 2>&1 &
  test_pid=$!

  if ! wait "$test_pid"; then
    report_sanitized_e2e_failure "$output_file"
    echo "Android E2E convergence phase failed; no authentication data was emitted." >&2
    restore_emulator_network || true
    rm -f "$output_file"
    return 1
  fi
  rm -f "$output_file"
}

offline_ready_marker='ANDROID_E2E_OFFLINE_READY'
offline_network_disabled_marker='ANDROID_E2E_OFFLINE_NETWORK_DISABLED'
offline_event_updated_marker='ANDROID_E2E_OFFLINE_EVENT_UPDATED'
offline_queue_durable_marker='ANDROID_E2E_OFFLINE_QUEUE_DURABLE'
offline_settings_rendered_marker='ANDROID_E2E_OFFLINE_SETTINGS_RENDERED'
offline_queued_marker='ANDROID_E2E_OFFLINE_MUTATION_QUEUED'
routine_offline_ready_marker='ANDROID_E2E_ROUTINE_OFFLINE_READY'
routine_offline_first_queued_marker='ANDROID_E2E_ROUTINE_OFFLINE_FIRST_MUTATION_QUEUED'
routine_offline_queued_marker='ANDROID_E2E_ROUTINE_OFFLINE_MUTATION_QUEUED'
routine_restart_queue_verified_marker='ANDROID_E2E_ROUTINE_RESTART_QUEUE_VERIFIED'
email_offline_ready_marker='ANDROID_E2E_EMAIL_OFFLINE_READY'
email_offline_queued_marker='ANDROID_E2E_EMAIL_OFFLINE_QUEUED'
email_connection_verified_marker='ANDROID_E2E_EMAIL_CONNECTION_VERIFIED'
email_inbox_verified_marker='ANDROID_E2E_EMAIL_INBOX_VERIFIED'
email_review_verified_marker='ANDROID_E2E_EMAIL_REVIEW_VERIFIED'
email_online_confirmation_verified_marker='ANDROID_E2E_EMAIL_ONLINE_CONFIRMATION_VERIFIED'
email_restart_verified_marker='ANDROID_E2E_EMAIL_RESTART_VERIFIED'
email_converged_marker='ANDROID_E2E_EMAIL_CONVERGED'
email_update_verified_marker='ANDROID_E2E_EMAIL_UPDATE_VERIFIED'
email_account_isolated_marker='ANDROID_E2E_EMAIL_ACCOUNT_ISOLATED'
email_cleanup_verified_marker='ANDROID_E2E_EMAIL_CLEANUP_VERIFIED'

run_bootstrap_phase
force_stop_test_app
run_bootstrap_exams_phase
force_stop_test_app
run_personal_management_phase
force_stop_test_app
run_email_online_phase
force_stop_test_app
run_email_restart_phase
force_stop_test_app
run_routine_offline_phase
force_stop_test_app
run_restart_phase
run_convergence_phase

unset publishable_key
