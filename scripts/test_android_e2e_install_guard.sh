#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/android_e2e_install_guard.sh
source "$repo_root/scripts/android_e2e_install_guard.sh"

fake_available_kib=3927712
fake_low_bytes=311405772
fake_uid=10219
fake_first_install_time='2026-08-11 03:47:39'
fake_df_malformed=false
fake_low_missing=false
fake_package_missing=false

fake_adb() {
  local command_line="$*"
  case "$command_line" in
    *'shell df -Pk /data'*)
      if [[ "$fake_df_malformed" == true ]]; then
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/data bad bad bad bad /data\n'
      else
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/data 6082144 1 %s 34%% /data\n' \
          "$fake_available_kib"
      fi
      ;;
    *'shell dumpsys devicestoragemonitor'*)
      if [[ "$fake_low_missing" != true ]]; then
        printf 'Default: totalBytes=6082144 lowBytes=%s fullBytes=1048576\n' \
          "$fake_low_bytes"
      fi
      ;;
    *'shell run-as jp.universityschedule.app.staging id -u'*)
      [[ "$fake_package_missing" != true ]] || return 1
      printf '%s\r\n' "$fake_uid"
      ;;
    *'shell dumpsys package jp.universityschedule.app.staging'*)
      [[ "$fake_package_missing" != true ]] || return 1
      printf '  firstInstallTime=%s\r\n' "$fake_first_install_time"
      ;;
    *)
      echo "Unexpected fake adb invocation: $command_line" >&2
      return 1
      ;;
  esac
}

fail() {
  echo "Android E2E install guard test failed: $1" >&2
  exit 1
}

expect_success() {
  local label="$1"
  shift
  "$@" >/dev/null 2>&1 || fail "$label should succeed"
}

expect_failure() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$label should fail closed"
  fi
}

temporary_directory="$(mktemp -d)"
apk_path="$temporary_directory/app-debug.apk"
cleanup() {
  rm -f -- "$apk_path"
  rmdir -- "$temporary_directory"
}
trap cleanup EXIT
truncate -s 169837132 "$apk_path"

expect_success \
  '3.9 GiB free headroom' \
  android_e2e_require_install_headroom fake_adb emulator-test "$apk_path"

fake_available_kib=458404
expect_failure \
  '448 MiB free headroom' \
  android_e2e_require_install_headroom fake_adb emulator-test "$apk_path"

fake_available_kib=3927712
fake_df_malformed=true
expect_failure \
  'malformed df output' \
  android_e2e_require_install_headroom fake_adb emulator-test "$apk_path"
fake_df_malformed=false

fake_low_missing=true
expect_failure \
  'missing low-storage threshold' \
  android_e2e_require_install_headroom fake_adb emulator-test "$apk_path"
fake_low_missing=false

fake_available_kib=921600
expect_failure \
  'missing APK with less than the 1 GiB floor' \
  android_e2e_require_install_headroom \
  fake_adb emulator-test "$temporary_directory/missing.apk"

fake_available_kib=1258291
truncate -s 943718400 "$apk_path"
expect_failure \
  'large APK dynamic threshold' \
  android_e2e_require_install_headroom fake_adb emulator-test "$apk_path"

expect_success \
  'unchanged install identity' \
  android_e2e_verify_install_identity \
    fake_adb emulator-test jp.universityschedule.app.staging \
  '10219' '2026-08-11 03:47:39'

fake_uid=10220
expect_failure \
  'changed package UID' \
  android_e2e_verify_install_identity \
    fake_adb emulator-test jp.universityschedule.app.staging \
  '10219' '2026-08-11 03:47:39'
fake_uid=10219

fake_first_install_time='2026-08-11 03:58:10'
expect_failure \
  'changed first-install time' \
  android_e2e_verify_install_identity \
    fake_adb emulator-test jp.universityschedule.app.staging \
  '10219' '2026-08-11 03:47:39'
fake_first_install_time='2026-08-11 03:47:39'

fake_package_missing=true
expect_failure \
  'missing package identity' \
  android_e2e_verify_install_identity \
    fake_adb emulator-test jp.universityschedule.app.staging \
  '10219' '2026-08-11 03:47:39'

echo 'Android E2E install guard tests passed.'
