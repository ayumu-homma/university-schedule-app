#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$repo_root/scripts/run_android_personal_management_e2e.sh"
dart_test="$repo_root/apps/mobile/integration_test/personal_management_e2e_test.dart"

fail() {
  echo 'Android auth-restore marker contract failed.' >&2
  exit 1
}

# Load only the real diagnostic function, without starting the E2E runner or
# touching an emulator, credentials, Docker, or Supabase.
sanitizer="$(sed -n '/^report_sanitized_e2e_failure() {/,/^}/p' "$runner")"
[[ -n "$sanitizer" ]] || fail
eval "$sanitizer"

auth_contract="$(sed -n '/^Future<String> _runPersonalManagementAuthenticationRestorePhase(/,/^Future<String> _runPersonalManagementCourseRestorePhase(/p' "$dart_test")"
grep -Fq "'ANDROID_E2E_PM_AUTH_\$stage'" <<<"$auth_contract" || fail
grep -Fq "print(marker);" "$dart_test" || fail

outer_stages=(SESSION_READY REACHABILITY_READY PROFILE_READY APP_STARTED
  STATE_READY ONBOARDING_READY HOME_READY ONLINE_READY CHANNELS_CLEARED
  SYNC_COMPLETE RESTORE_COMPLETE)
actual_stages="$(sed -n "s/.*await progress('\([A-Z_]*\)').*/\1/p" <<<"$auth_contract")"
expected_stages="$(printf '%s\n' "${outer_stages[@]}")"
[[ "$actual_stages" == "$expected_stages" ]] || fail
# Completion is after cleanup, so a dispose hang cannot look like success.
grep -Fq 'await runningApp?.dispose(tester, onStage: progress);' <<<"$auth_contract" || fail

inner_stages=(SQLITE_READY NATIVE_SCOPE_READY DOCUMENTS_READY STORAGE_READY
  DATABASE_OPEN_READY DATABASE_PROBE_READY CONTAINER_READY APP_PUMPED
  FIRST_FRAME_READY DISPOSE_SETTLED DISPOSE_UNMOUNTED
  DISPOSE_FINAL_FRAME_READY CONTAINER_DISPOSED DATABASE_CLOSED
  DISPOSE_COMPLETION_FRAME_READY)
for stage in "${inner_stages[@]}"; do
  grep -Fq "if (onStage != null) await onStage('$stage');" "$dart_test" || fail
done

output_file="$(mktemp)"
trap 'rm -f "$output_file"' EXIT
for stage in "${outer_stages[@]}" "${inner_stages[@]}"; do
  printf 'ANDROID_E2E_PM_AUTH_%s\n' "$stage" >>"$output_file"
done
# These are synthetic sentinels. The test never prints their values.
printf '%s\n' 'TimeoutException at an auth-restore boundary' \
  'password=synthetic-private-sentinel' \
  'Authorization: Bearer synthetic-bearer-sentinel' \
  'url https://synthetic.invalid/path?key=synthetic-url-sentinel' \
  'ANDROID_E2E_PM_AUTH_HOME_READY token=synthetic-token-sentinel' \
  >>"$output_file"
summary="$(report_sanitized_e2e_failure "$output_file" 2>&1)"
if grep -Eq 'synthetic-(private|bearer|url|token)-sentinel' <<<"$summary"; then
  fail
fi
markers="$(sed -n '/^Observed safe Android E2E markers before failure:$/,$p' <<<"$summary" | tail -n +2)"
expected_markers="$(printf 'ANDROID_E2E_PM_AUTH_%s\n' "${outer_stages[@]}" "${inner_stages[@]}")"
[[ "$markers" == "$expected_markers" ]] || fail
if grep -Ev '^ANDROID_E2E_[A-Z_]+$' <<<"$markers" >/dev/null; then
  fail
fi
echo 'Android auth-restore marker and sanitizer contracts passed.'
