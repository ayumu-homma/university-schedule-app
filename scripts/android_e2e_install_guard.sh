#!/usr/bin/env bash

# Pure helpers for protecting persisted Android E2E state from Flutter's
# install fallback. Flutter retries a failed `adb install -r` by uninstalling
# the existing package, which would erase the auth session and Drift database
# that the multi-process acceptance flow is intentionally verifying.

android_e2e_read_data_available_bytes() {
  local adb_command="$1"
  local device_id="$2"
  local available_kib

  available_kib="$(
    MSYS_NO_PATHCONV=1 \
      "$adb_command" -s "$device_id" shell df -Pk /data 2>/dev/null |
      tr -d '\r' |
      awk 'NR > 1 && $4 ~ /^[0-9]+$/ { print $4; exit }'
  )" || true
  if ! [[ "$available_kib" =~ ^[0-9]+$ ]]; then
    echo "Unable to read the selected emulator's available /data bytes." >&2
    return 1
  fi
  printf '%s' "$((available_kib * 1024))"
}

android_e2e_read_low_storage_bytes() {
  local adb_command="$1"
  local device_id="$2"
  local low_bytes

  low_bytes="$(
    "$adb_command" -s "$device_id" shell dumpsys devicestoragemonitor \
      2>/dev/null |
      tr -d '\r' |
      sed -nE 's/.*[[:space:]]lowBytes=([0-9]+).*/\1/p' |
      head -n 1
  )" || true
  if ! [[ "$low_bytes" =~ ^[0-9]+$ ]]; then
    echo "Unable to read the selected emulator's low-storage threshold." >&2
    return 1
  fi
  printf '%s' "$low_bytes"
}

android_e2e_read_apk_bytes() {
  local apk_path="$1"
  local apk_bytes=0

  if [[ -f "$apk_path" ]]; then
    apk_bytes="$(wc -c <"$apk_path" | tr -d '[:space:]')"
  fi
  if ! [[ "$apk_bytes" =~ ^[0-9]+$ ]]; then
    echo "Unable to read the Android E2E APK size." >&2
    return 1
  fi
  printf '%s' "$apk_bytes"
}

android_e2e_require_install_headroom() {
  local adb_command="$1"
  local device_id="$2"
  local apk_path="$3"
  local available_bytes
  local low_bytes
  local apk_bytes
  local required_bytes
  local available_mib
  local required_mib
  local apk_mib
  local low_mib
  local -r minimum_free_bytes=1073741824
  local -r staging_margin_bytes=268435456

  available_bytes="$(
    android_e2e_read_data_available_bytes "$adb_command" "$device_id"
  )" || return 1
  low_bytes="$(
    android_e2e_read_low_storage_bytes "$adb_command" "$device_id"
  )" || return 1
  apk_bytes="$(android_e2e_read_apk_bytes "$apk_path")" || return 1

  required_bytes=$((low_bytes + apk_bytes + staging_margin_bytes))
  if ((required_bytes < minimum_free_bytes)); then
    required_bytes=$minimum_free_bytes
  fi
  if ((available_bytes >= required_bytes)); then
    return 0
  fi

  available_mib=$((available_bytes / 1048576))
  required_mib=$((required_bytes / 1048576))
  apk_mib=$((apk_bytes / 1048576))
  low_mib=$((low_bytes / 1048576))
  echo \
    "Android E2E install headroom check failed: ${available_mib} MiB available; ${required_mib} MiB required (${low_mib} MiB low-storage threshold, ${apk_mib} MiB APK, 256 MiB staging margin)." \
    >&2
  echo \
    "Free emulator /data space or select another AVD before Flutter can uninstall the persisted test app." \
    >&2
  return 1
}

android_e2e_read_install_uid() {
  local adb_command="$1"
  local device_id="$2"
  local package_id="$3"
  local install_uid

  install_uid="$(
    "$adb_command" -s "$device_id" shell run-as "$package_id" id -u \
      2>/dev/null |
      tr -d '\r[:space:]'
  )" || true
  if ! [[ "$install_uid" =~ ^[0-9]+$ ]]; then
    echo "Unable to read the persisted Android E2E package UID." >&2
    return 1
  fi
  printf '%s' "$install_uid"
}

android_e2e_read_first_install_time() {
  local adb_command="$1"
  local device_id="$2"
  local package_id="$3"
  local first_install_time

  first_install_time="$(
    "$adb_command" -s "$device_id" shell dumpsys package "$package_id" \
      2>/dev/null |
      tr -d '\r' |
      sed -nE 's/^[[:space:]]*firstInstallTime=(.+)$/\1/p' |
      head -n 1
  )" || true
  if [[ -z "$first_install_time" ]]; then
    echo "Unable to read the persisted Android E2E first-install time." >&2
    return 1
  fi
  printf '%s' "$first_install_time"
}

android_e2e_verify_install_identity() {
  local adb_command="$1"
  local device_id="$2"
  local package_id="$3"
  local expected_uid="$4"
  local expected_first_install_time="$5"
  local observed_uid
  local observed_first_install_time

  if [[ -z "$expected_uid" || -z "$expected_first_install_time" ]]; then
    echo "The Android E2E install identity was not captured after bootstrap." >&2
    return 1
  fi
  observed_uid="$(
    android_e2e_read_install_uid "$adb_command" "$device_id" "$package_id"
  )" || return 1
  observed_first_install_time="$(
    android_e2e_read_first_install_time \
      "$adb_command" "$device_id" "$package_id"
  )" || return 1

  if [[ "$observed_uid" != "$expected_uid" ||
    "$observed_first_install_time" != "$expected_first_install_time" ]]; then
    echo \
      "Android E2E install identity changed; Flutter may have uninstalled the app after an APK update failure." \
      >&2
    return 1
  fi
}
