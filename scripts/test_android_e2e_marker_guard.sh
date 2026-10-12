#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/android_e2e_marker_guard.sh
source "$repo_root/scripts/android_e2e_marker_guard.sh"
runner="$repo_root/scripts/run_android_personal_management_e2e.sh"
integration_test="$repo_root/apps/mobile/integration_test/personal_management_e2e_test.dart"

fail_test() {
  echo "android_e2e_marker_guard test failed: $1" >&2
  exit 1
}

assert_observed() {
  local run_id="$1"
  local phase="$2"
  local marker="$3"
  local snapshot="$4"
  android_e2e_marker_observed_in_snapshot \
    "$run_id" "$phase" "$marker" "$snapshot" || \
    fail_test "expected the exact marker to be observed"
}

assert_not_observed() {
  local run_id="$1"
  local phase="$2"
  local marker="$3"
  local snapshot="$4"
  if android_e2e_marker_observed_in_snapshot \
    "$run_id" "$phase" "$marker" "$snapshot"; then
    fail_test "unexpected marker match"
  fi
}

fake_adb() {
  if [[ "$#" -ne 8 ||
        "$1" != '-s' ||
        "$2" != 'emulator-5554' ||
        "$3" != 'shell' ||
        "$4" != 'run-as' ||
        "$5" != 'jp.universityschedule.app.staging' ||
        "$6" != 'ls' ||
        "$7" != '-1' ||
        "$8" != 'files' ]]; then
    return 64
  fi
  if [[ -n "${FAKE_FILES_SNAPSHOT:-}" ]]; then
    printf '%s\n' "$FAKE_FILES_SNAPSHOT"
  fi
}

run_id='20260811T040000-r123-r456'
phase='restart'
marker='ANDROID_E2E_ROUTINE_RESTART_QUEUE_VERIFIED'
expected="$(android_e2e_marker_file_name "$run_id" "$phase" "$marker")"

FAKE_FILES_SNAPSHOT="$expected"
snapshot="$(android_e2e_runner_markers_snapshot fake_adb emulator-5554)"
[[ "$snapshot" == "$expected" ]] || \
  fail_test "the runner did not read the Android files directory"
assert_observed "$run_id" "$phase" "$marker" "$snapshot"

# A marker that exists only in disposable code_cache is deliberately ignored.
FAKE_FILES_SNAPSHOT=''
snapshot="$(android_e2e_runner_markers_snapshot fake_adb emulator-5554)"
[[ -z "$snapshot" ]] || fail_test "a code_cache-only marker leaked into files"
assert_not_observed "$run_id" "$phase" "$marker" "$snapshot"

FAKE_FILES_SNAPSHOT="$expected"
snapshot="$(android_e2e_runner_markers_snapshot fake_adb emulator-5554)"
assert_not_observed '20260811T040001-r123-r456' "$phase" "$marker" "$snapshot"
assert_not_observed "$run_id" 'routine-offline' "$marker" "$snapshot"
assert_not_observed "$run_id" "$phase" \
  'ANDROID_E2E_OFFLINE_READY' "$snapshot"

if android_e2e_marker_file_name 'unsafe/id' "$phase" "$marker" >/dev/null; then
  fail_test "an unsafe run ID was accepted"
fi
if android_e2e_marker_file_name "$run_id" 'unknown' "$marker" >/dev/null; then
  fail_test "an unknown phase was accepted"
fi
if android_e2e_marker_file_name "$run_id" "$phase" \
  'ANDROID_E2E_UNSAFE-CHARS' >/dev/null; then
  fail_test "an unsafe marker was accepted"
fi

marker_wait_contract="$(
  sed -n '/^wait_for_network_marker() {/,/^}/p' "$runner"
)"
grep -Fq 'local deadline=$((SECONDS + 120))' <<<"$marker_wait_contract" ||
  fail_test "the fixed 120-second marker deadline changed"
grep -Fq 'sleep 1' <<<"$marker_wait_contract" ||
  fail_test "the marker wait does not use the bounded one-second poll"
if grep -Fq 'sleep 0.1' <<<"$marker_wait_contract"; then
  fail_test "the marker wait still performs high-frequency adb polling"
fi

connection_marker='ANDROID_E2E_EMAIL_CONNECTION_VERIFIED'
grep -Fq "const _emailConnectionVerifiedMarker =" "$integration_test" ||
  fail_test "the integration test does not declare the connection marker"
grep -Fq "'$connection_marker';" "$integration_test" ||
  fail_test "the integration test connection marker value changed"
grep -Fq "email_connection_verified_marker='$connection_marker'" "$runner" ||
  fail_test "the runner does not declare the connection marker"
email_online_runner_contract="$(
  sed -n '/^run_email_online_phase() {/,/^}/p' "$runner"
)"
grep -Fq '"$email_connection_verified_marker" \' \
  <<<"$email_online_runner_contract" ||
  fail_test "the runner does not require connection progress"

connection_signal_contract="$(
  sed -n '/bool emailConnectionProviderReady()/,/final inboxRefreshAction =/p' \
    "$integration_test"
)"
grep -Fq 'await _waitForCondition(' <<<"$connection_signal_contract" ||
  fail_test "the integration test does not wait for hydrated connection state"
grep -Fq 'emailConnectionProviderReady,' <<<"$connection_signal_contract" ||
  fail_test "the integration test does not wait on its provider predicate"
grep -Fq 'await _signalRunnerMarker(' <<<"$connection_signal_contract" ||
  fail_test "the integration test does not signal connection progress"
grep -Fq '_emailConnectionVerifiedMarker,' <<<"$connection_signal_contract" ||
  fail_test "the integration test signals the wrong connection marker"

connect_contract="$(
  sed -n '/final connectAction =/,/await _tap(tester, connectAction);/p' \
    "$integration_test"
)"
grep -Fq 'onPressed != null' <<<"$connect_contract" ||
  fail_test "the Gmail connect action is tapped before it is enabled"

refresh_contract="$(
  sed -n '/final inboxRefreshAction =/,/await _tap(tester, inboxRefreshAction);/p' \
    "$integration_test"
)"
grep -Fq 'emailConnectionProviderReady()' <<<"$refresh_contract" ||
  fail_test "the inbox refresh does not require hydrated connection state"
grep -Fq 'onPressed != null' <<<"$refresh_contract" ||
  fail_test "the inbox refresh is tapped before it is enabled"

retry_contract="$(
  sed -n "/final retryMalformedCandidate =/,/await _tap(/p" \
    "$integration_test"
)"
grep -Fq 'onPressed !=' <<<"$retry_contract" ||
  fail_test "the targeted retry is tapped before it is enabled"

echo 'android_e2e_marker_guard tests passed'
