#!/usr/bin/env bash

set -euo pipefail

readonly ANDROID_E2E_REQUIRED_NDK='/usr/local/lib/android/sdk/ndk/28.2.13676358'
readonly ANDROID_E2E_SYSTEM_IMAGE='/usr/local/lib/android/sdk/system-images/android-35/google_apis/x86_64'
readonly ANDROID_E2E_OBSERVED_USERDATA_MIB='7372.80'
readonly ANDROID_E2E_PRE_ACTION_MIN_FREE_KIB=12582912
readonly ANDROID_E2E_PRE_LAUNCH_MIN_FREE_KIB=8388608

readonly -a ANDROID_E2E_CLEANUP_ENTRIES=(
  '/usr/share/dotnet|.NET SDKs are not used by the Android E2E job.'
  '/opt/ghc|The legacy Haskell toolchain path is not used by the Android E2E job.'
  '/usr/share/swift|The Swift toolchain is not used by the Android E2E job.'
  '/opt/hostedtoolcache/CodeQL|The preinstalled CodeQL bundle is not used by the Android E2E job.'
  '/usr/local/lib/android/sdk/ndk/27.3.13750724|The project pins Android NDK 28.2.13676358, not NDK 27.3.'
  '/usr/local/lib/android/sdk/ndk/29.0.14206865|The project pins Android NDK 28.2.13676358, not NDK 29.0.'
)

fail() {
  echo "Android E2E runner disk guard failed: $1" >&2
  return 1
}

run_privileged() {
  sudo "$@"
}

print_root_disk() {
  local stage="$1"
  echo "Android E2E runner disk (${stage}):"
  df -h /
  df -B1 /
}

measure_path() {
  local label="$1"
  local path="$2"
  if [[ -e "$path" || -L "$path" ]]; then
    printf '%s: ' "$label"
    du -sh -- "$path"
  else
    printf '%s: NOT PRESENT (%s)\n' "$label" "$path"
  fi
}

measure_privileged_path() {
  local label="$1"
  local path="$2"
  if [[ -e "$path" || -L "$path" ]]; then
    printf '%s: ' "$label"
    run_privileged du -shx -- "$path"
  else
    printf '%s: NOT PRESENT (%s)\n' "$label" "$path"
  fi
}

validate_cleanup_target() {
  case "$1" in
    /usr/share/dotnet | \
      /opt/ghc | \
      /usr/share/swift | \
      /opt/hostedtoolcache/CodeQL | \
      /usr/local/lib/android/sdk/ndk/27.3.13750724 | \
      /usr/local/lib/android/sdk/ndk/29.0.14206865)
      ;;
    *)
      fail "refusing non-allowlisted cleanup target: $1"
      ;;
  esac
}

remove_existing_path() {
  local target="$1"
  local reason="$2"
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    printf 'Cleanup target not present; skipping %s. Reason: %s\n' \
      "$target" "$reason"
    return 0
  fi

  printf 'Removing %s. Reason: %s\n' "$target" "$reason"
  run_privileged du -shx -- "$target"
  run_privileged rm -rf --one-file-system -- "$target"
  [[ ! -e "$target" && ! -L "$target" ]] || \
    fail "cleanup target still exists: $target"
}

require_hosted_linux_runner() {
  [[ "${GITHUB_ACTIONS:-}" == 'true' ]] || \
    fail 'cleanup is restricted to GitHub Actions.'
  [[ "${RUNNER_OS:-}" == 'Linux' ]] || \
    fail 'cleanup is restricted to a Linux runner.'
  [[ "${RUNNER_TOOL_CACHE:-}" == '/opt/hostedtoolcache' ]] || \
    fail 'unexpected GitHub hosted-runner tool cache root.'
  [[ "${GITHUB_WORKSPACE:-}" == /home/runner/work/* ]] || \
    fail 'unexpected GitHub hosted-runner workspace root.'
  [[ -d "$GITHUB_WORKSPACE" ]] || fail 'GitHub workspace is missing.'
}

require_preserved_android_toolchain() {
  [[ -d /usr/local/lib/android/sdk ]] || fail 'Android SDK is missing.'
  [[ -d "$ANDROID_E2E_REQUIRED_NDK" ]] || \
    fail 'required Android NDK 28.2.13676358 is missing.'
  [[ -n "${JAVA_HOME:-}" && -d "$JAVA_HOME" ]] || \
    fail 'the configured Java toolchain is missing.'
}

measure_cleanup_targets() {
  local entry target reason
  for entry in "${ANDROID_E2E_CLEANUP_ENTRIES[@]}"; do
    target="${entry%%|*}"
    reason="${entry#*|}"
    measure_privileged_path "Cleanup candidate (${reason})" "$target"
  done
  measure_privileged_path 'Preserved Android SDK' '/usr/local/lib/android/sdk'
  measure_privileged_path 'Preserved Android NDK 28.2.13676358' \
    "$ANDROID_E2E_REQUIRED_NDK"
}

measure_warm_state() {
  local -a warm_paths=(
    "$GRADLE_USER_HOME"
    'apps/mobile/.dart_tool/flutter_build'
    'apps/mobile/android/.gradle'
    'apps/mobile/build'
    'apps/mobile/lib/local_db/app_database.g.dart'
    'android-e2e-warm-manifest.txt'
  )
  local -a existing_paths=()
  local path

  for path in "${warm_paths[@]}"; do
    measure_path 'Warm-state path' "$path"
    if [[ -e "$path" || -L "$path" ]]; then
      existing_paths+=("$path")
    fi
  done

  ((${#existing_paths[@]} > 0)) || fail 'no restored warm-state paths exist.'
  echo 'Warm-state restored footprint:'
  du -sch -- "${existing_paths[@]}" | tail -n 1
}

available_root_kib() {
  local available
  available="$(df -Pk / | awk 'NR == 2 {print $4}')"
  if [[ ! "$available" =~ ^[0-9]+$ ]]; then
    fail 'could not parse root free space.'
    return 1
  fi
  printf '%s\n' "$available"
}

print_capacity() {
  local available_kib="$1"
  local required_kib="$2"
  local stage="$3"
  if [[ ! "$available_kib" =~ ^[0-9]+$ ]]; then
    fail "invalid available KiB: $available_kib"
    return 1
  fi
  if [[ ! "$required_kib" =~ ^[0-9]+$ ]]; then
    fail "invalid required KiB: $required_kib"
    return 1
  fi

  awk -v available="$available_kib" -v required="$required_kib" \
    -v userdata="$ANDROID_E2E_OBSERVED_USERDATA_MIB" -v stage="$stage" \
    'BEGIN {
      printf("Android E2E capacity (%s): %.2f MiB available; %.2f MiB required by this gate.\n", stage, available / 1024, required / 1024)
      printf("Pinned Pixel 7 Pro emulator userdata host requirement observed in run 32474835396: %s MiB.\n", userdata)
    }'
}

check_free_kib() {
  local available_kib="$1"
  local required_kib="$2"
  local stage="$3"
  print_capacity "$available_kib" "$required_kib" "$stage" || return 1

  if ((available_kib < required_kib)); then
    echo "::error::Android E2E runner capacity is below the ${stage} threshold." >&2
    return 1
  fi
}

reclaim_runner_disk() {
  local entry target reason
  require_hosted_linux_runner
  require_preserved_android_toolchain
  print_root_disk 'before cleanup'
  measure_cleanup_targets

  for entry in "${ANDROID_E2E_CLEANUP_ENTRIES[@]}"; do
    target="${entry%%|*}"
    reason="${entry#*|}"
    validate_cleanup_target "$target"
    remove_existing_path "$target" "$reason"
  done

  require_preserved_android_toolchain
  print_root_disk 'after cleanup'
  measure_cleanup_targets
}

measure_restored_state() {
  print_root_disk 'after exact-head warm-state restore'
  measure_path 'Android SDK' "$ANDROID_SDK_ROOT"
  measure_path 'Required Android NDK 28.2.13676358' "$ANDROID_E2E_REQUIRED_NDK"
  measure_path 'Flutter tool build cache' "$FLUTTER_ROOT/bin/cache"
  measure_warm_state
  measure_path 'API 35 Google APIs x86_64 system image (installed by emulator action)' \
    "$ANDROID_E2E_SYSTEM_IMAGE"
}

check_pre_action_capacity() {
  local available_kib
  print_root_disk 'after Supabase and before emulator action'
  measure_privileged_path 'Docker data after local Supabase start' '/var/lib/docker'
  docker system df
  measure_path 'Gradle cache' "$GRADLE_USER_HOME"
  measure_path 'Flutter tool build cache' "$FLUTTER_ROOT/bin/cache"
  measure_warm_state
  echo 'The 12 GiB gate reserves the observed 7.2 GiB userdata requirement,'
  echo 'the pinned emulator/system-image installation, and runtime/install headroom.'
  available_kib="$(available_root_kib)"
  check_free_kib \
    "$available_kib" \
    "$ANDROID_E2E_PRE_ACTION_MIN_FREE_KIB" \
    'pre-action'
}

measure_pre_launch_state() {
  local avd_root="${ANDROID_AVD_HOME:-$HOME/.android/avd}"
  local avd_directory="$avd_root/test.avd"
  local avd_config="$avd_directory/config.ini"
  local available_kib partition_size

  print_root_disk 'after system image and AVD creation, before launch'
  measure_path 'API 35 Google APIs x86_64 system image' "$ANDROID_E2E_SYSTEM_IMAGE"
  measure_path 'Android AVD' "$avd_directory"
  measure_path 'Gradle cache' "$GRADLE_USER_HOME"
  measure_path 'Flutter tool build cache' "$FLUTTER_ROOT/bin/cache"
  measure_warm_state

  partition_size='profile default (disk-size input intentionally unset)'
  if [[ -f "$avd_config" ]]; then
    partition_size="$(awk -F= '$1 == "disk.dataPartition.size" {print $2}' \
      "$avd_config" | tail -n 1)"
    [[ -n "$partition_size" ]] || \
      partition_size='profile default (disk-size input intentionally unset)'
  fi
  printf 'AVD disk.dataPartition.size: %s\n' "$partition_size"

  available_kib="$(available_root_kib)"
  print_capacity \
    "$available_kib" \
    "$ANDROID_E2E_PRE_LAUNCH_MIN_FREE_KIB" \
    'pre-launch'
  if ((available_kib < ANDROID_E2E_PRE_LAUNCH_MIN_FREE_KIB)); then
    echo '::warning::Pre-launch space is below the 8 GiB diagnostic floor; the independent pre-action gate already passed before SDK installation.' >&2
  fi
}

main() {
  case "${1:-}" in
    reclaim)
      reclaim_runner_disk
      ;;
    measure-warm-state)
      measure_restored_state
      ;;
    preflight)
      check_pre_action_capacity
      ;;
    prelaunch)
      measure_pre_launch_state
      ;;
    *)
      fail 'usage: android_e2e_runner_disk_guard.sh {reclaim|measure-warm-state|preflight|prelaunch}'
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
