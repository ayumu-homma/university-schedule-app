#!/usr/bin/env bash

# Shared, assertion-preserving marker helpers for the Android E2E app/runner
# handshake. Marker files live in Android's persistent app files directory:
# cache and code_cache are disposable during package updates between phases.

android_e2e_marker_file_name() {
  if [[ "$#" -ne 3 ]]; then
    return 2
  fi
  local run_id="$1"
  local phase="$2"
  local marker="$3"

  if [[ ! "$run_id" =~ ^[A-Za-z0-9-]{8,96}$ ]]; then
    return 2
  fi
  case "$phase" in
    bootstrap | bootstrap-exams | personal-management | email-online | \
      email-restart | routine-offline | restart | convergence) ;;
    *) return 2 ;;
  esac
  if [[ ! "$marker" =~ ^ANDROID_E2E_[A-Z_]+$ ]]; then
    return 2
  fi

  printf 'android-e2e-%s-%s-%s' "$run_id" "$phase" "$marker"
}

android_e2e_runner_markers_snapshot() {
  if [[ "$#" -ne 2 ]]; then
    return 2
  fi
  local adb_command="$1"
  local device_id="$2"

  "$adb_command" -s "$device_id" shell run-as jp.universityschedule.app.staging \
    ls -1 files 2>/dev/null | tr -d '\r' || true
}

android_e2e_marker_observed_in_snapshot() {
  if [[ "$#" -ne 4 ]]; then
    return 2
  fi
  local run_id="$1"
  local phase="$2"
  local marker="$3"
  local snapshot="$4"
  local marker_file

  marker_file="$(android_e2e_marker_file_name "$run_id" "$phase" "$marker")" || \
    return 2
  grep -Fqx -- "$marker_file" <<<"$snapshot"
}
