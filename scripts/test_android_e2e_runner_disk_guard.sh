#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$repo_root/scripts/android_e2e_runner_disk_guard.sh"
workflow="$repo_root/.github/workflows/ci.yml"
connected_workflow="$repo_root/.github/workflows/connected-e2e.yml"

# shellcheck source=scripts/android_e2e_runner_disk_guard.sh
source "$guard"

test_fail() {
  echo "Android E2E runner disk contract test failed: $1" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || test_fail "missing contract text: $needle"
}

assert_line_order() {
  local section="$1"
  shift
  local previous=0 needle line
  for needle in "$@"; do
    line="$(grep -nF -- "$needle" <<<"$section" | head -n 1 | cut -d: -f1)"
    [[ "$line" =~ ^[0-9]+$ ]] || test_fail "workflow entry not found: $needle"
    ((line > previous)) || test_fail "workflow entry is out of order: $needle"
    previous="$line"
  done
}

expected_cleanup_entries=(
  '/usr/share/dotnet|.NET SDKs are not used by the Android E2E job.'
  '/opt/ghc|The legacy Haskell toolchain path is not used by the Android E2E job.'
  '/usr/share/swift|The Swift toolchain is not used by the Android E2E job.'
  '/opt/hostedtoolcache/CodeQL|The preinstalled CodeQL bundle is not used by the Android E2E job.'
  '/usr/local/lib/android/sdk/ndk/27.3.13750724|The project pins Android NDK 28.2.13676358, not NDK 27.3.'
  '/usr/local/lib/android/sdk/ndk/29.0.14206865|The project pins Android NDK 28.2.13676358, not NDK 29.0.'
)

[[ "${ANDROID_E2E_CLEANUP_ENTRIES[*]}" == "${expected_cleanup_entries[*]}" ]] || \
  test_fail 'cleanup allowlist changed.'
[[ "$ANDROID_E2E_REQUIRED_NDK" == \
  '/usr/local/lib/android/sdk/ndk/28.2.13676358' ]] || \
  test_fail 'required NDK contract changed.'
[[ "$ANDROID_E2E_OBSERVED_USERDATA_MIB" == '7372.80' ]] || \
  test_fail 'observed emulator userdata requirement changed.'
[[ "$ANDROID_E2E_PRE_ACTION_MIN_FREE_KIB" == '12582912' ]] || \
  test_fail 'pre-action free-space threshold changed.'
[[ "$ANDROID_E2E_PRE_LAUNCH_MIN_FREE_KIB" == '8388608' ]] || \
  test_fail 'pre-launch free-space threshold changed.'

for entry in "${ANDROID_E2E_CLEANUP_ENTRIES[@]}"; do
  target="${entry%%|*}"
  validate_cleanup_target "$target"
  case "$ANDROID_E2E_REQUIRED_NDK" in
    "$target" | "$target"/*)
      test_fail "cleanup target contains the required NDK: $target"
      ;;
  esac
done

if validate_cleanup_target '/usr/local/lib/android/sdk' >/dev/null 2>&1; then
  test_fail 'Android SDK root was accepted as a cleanup target.'
fi
if validate_cleanup_target "$repo_root" >/dev/null 2>&1; then
  test_fail 'workspace was accepted as a cleanup target.'
fi

fixture_root="$(mktemp -d)"
trap 'if [[ -d "$fixture_root" ]]; then rm -rf -- "$fixture_root"; fi' EXIT
fixture_target="$fixture_root/unused-tool"
mkdir -p "$fixture_target"
printf 'fixture\n' >"$fixture_target/payload.txt"

run_privileged() {
  "$@"
}

removal_output="$(remove_existing_path "$fixture_target" 'fixture cleanup reason')"
[[ ! -e "$fixture_target" ]] || test_fail 'existing guarded target was not removed.'
assert_contains "$removal_output" "$fixture_target"
assert_contains "$removal_output" 'fixture cleanup reason'

missing_output="$(remove_existing_path "$fixture_target" 'fixture missing reason')"
assert_contains "$missing_output" 'not present; skipping'
assert_contains "$missing_output" "$fixture_target"

check_free_kib 12582912 12582912 'test-pass' >/dev/null
if check_free_kib 12582911 12582912 'test-fail' >/dev/null 2>&1; then
  test_fail 'insufficient host space did not fail closed.'
fi
if check_free_kib malformed 12582912 'test-malformed' >/dev/null 2>&1; then
  test_fail 'malformed host space did not fail closed.'
fi

prelaunch_function="$(sed -n \
  '/^measure_pre_launch_state()/,/^}/p' "$guard")"
assert_contains "$prelaunch_function" 'print_capacity'
assert_contains "$prelaunch_function" '::warning::Pre-launch space'
if grep -Fq 'check_free_kib' <<<"$prelaunch_function"; then
  test_fail 'the action prelaunch hook cannot provide the fail-fast gate.'
fi

android_section="$(sed -n \
  '/^  android-personal-e2e:/,$p' "$connected_workflow")"
assert_line_order "$android_section" \
  'Reclaim runner disk space for the Android emulator' \
  'uses: subosito/flutter-action@v2' \
  'Generate fresh sources' \
  'Start clean local Supabase acceptance stack' \
  'Check Android emulator host capacity' \
  'uses: reactivecircus/android-emulator-runner@v2'

for invariant in \
  'timeout-minutes: 50' \
  'api-level: 35' \
  'target: google_apis' \
  'arch: x86_64' \
  'profile: pixel_7_pro' \
  'emulator-build: 15004761' \
  '-no-window -gpu swiftshader -no-snapshot -noaudio' \
  '-no-boot-anim -camera-back none' \
  'pre-emulator-launch-script: >-' \
  'bash scripts/android_e2e_runner_disk_guard.sh prelaunch' \
  'bash scripts/run_android_personal_management_e2e.sh' \
  '--device-id emulator-5554'; do
  assert_contains "$android_section" "$invariant"
done

for forbidden in 'actions/cache' 'actions/upload-artifact' 'actions/download-artifact'; do
  if grep -Fq "$forbidden" <<<"$android_section"; then
    test_fail 'connected E2E must use fresh same-job state without remote storage.'
  fi
done
assert_contains "$android_section" 'dart run build_runner build --delete-conflicting-outputs'

if grep -Fq 'disk-size:' <<<"$android_section"; then
  test_fail 'emulator disk-size must remain unset for the cleanup-first fix.'
fi
grep -Fq 'bash scripts/test_android_e2e_runner_disk_guard.sh' "$workflow" || \
  test_fail 'focused disk contract test is not invoked by CI.'
grep -Fq 'scripts/test_android_e2e_runner_disk_guard.sh' \
  "$repo_root/scripts/verify_portfolio.ps1" || \
  test_fail 'focused disk contract test is not invoked by the local verifier.'

echo 'Android E2E runner disk contract tests passed.'
