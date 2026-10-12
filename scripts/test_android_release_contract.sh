#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gradle="$repo_root/apps/mobile/android/app/build.gradle.kts"
manifest="$repo_root/apps/mobile/android/app/src/main/AndroidManifest.xml"
backup_rules="$repo_root/apps/mobile/android/app/src/main/res/xml/backup_rules.xml"
extraction_rules="$repo_root/apps/mobile/android/app/src/main/res/xml/data_extraction_rules.xml"
template="$repo_root/apps/mobile/android/key.properties.example"
release_gate="$repo_root/apps/mobile/tool/validate_android_production_release.mjs"
release_launcher="$repo_root/apps/mobile/tool/build_android_production_release.ps1"
ignore_file="$repo_root/.gitignore"
play_guide="$repo_root/docs/GOOGLE_PLAY_INTERNAL_TESTING.md"

fail() {
  echo "Android release contract test failed: $1" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local literal="$2"
  grep -Fq -- "$literal" "$file" || fail "$file is missing: $literal"
}

reject_literal() {
  local file="$1"
  local literal="$2"
  if grep -Fq -- "$literal" "$file"; then
    fail "$file contains forbidden release behavior: $literal"
  fi
}

for file in \
  "$gradle" \
  "$manifest" \
  "$backup_rules" \
  "$extraction_rules" \
  "$template" \
  "$release_gate" \
  "$release_launcher" \
  "$play_guide"; do
  [[ -s "$file" ]] || fail "required contract file is missing or empty: $file"
done

require_literal "$gradle" 'val releaseSigningRequested = releaseSigningPropertiesFile.isFile'
require_literal "$gradle" 'missingReleaseSigningProperties.isEmpty()'
require_literal "$gradle" 'configuredStoreFile.isFile'
require_literal "$gradle" 'if (releaseSigningRequested) {'
require_literal "$gradle" 'create("release")'
require_literal "$gradle" 'signingConfig = signingConfigs.getByName("release")'
require_literal "$gradle" 'isMinifyEnabled = false'
require_literal "$gradle" 'isShrinkResources = false'
require_literal "$gradle" 'flavorDimensions += "environment"'
require_literal "$gradle" 'create("staging")'
require_literal "$gradle" 'applicationIdSuffix = ".staging"'
require_literal "$gradle" 'manifestPlaceholders["authScheme"] = "unischedule-staging"'
require_literal "$gradle" 'create("production")'
require_literal "$gradle" 'manifestPlaceholders["authScheme"] = "unischedule"'
reject_literal "$gradle" 'signingConfigs.getByName("debug")'
reject_literal "$gradle" 'signingConfigs.debug'

for property_name in storeFile storePassword keyAlias keyPassword; do
  require_literal "$gradle" "\"$property_name\""
  require_literal "$template" "$property_name="
done
require_literal "$ignore_file" '**/key.properties'

require_literal "$manifest" 'android:allowBackup="false"'
require_literal "$manifest" 'android:dataExtractionRules="@xml/data_extraction_rules"'
require_literal "$manifest" 'android:fullBackupContent="@xml/backup_rules"'
require_literal "$manifest" 'android:label="${appLabel}"'
require_literal "$manifest" 'android:scheme="${authScheme}"'

for domain in root file database sharedpref external; do
  require_literal "$backup_rules" "<exclude domain=\"$domain\" path=\".\" />"
  count="$(grep -Fc -- "<exclude domain=\"$domain\" path=\".\" />" "$extraction_rules")"
  [[ "$count" == 2 ]] || \
    fail "Android 12+ rules must exclude $domain from backup and transfer."
done
require_literal "$extraction_rules" '<cloud-backup>'
require_literal "$extraction_rules" '<device-transfer>'

require_literal "$play_guide" '.\tool\build_android_production_release.ps1'
require_literal "$play_guide" '-ConfigFile .env.production.json -Build'
require_literal "$play_guide" 'build/app/outputs/bundle/productionRelease/app-production-release.aab'
require_literal "$release_launcher" 'validate_android_production_release.mjs'
require_literal "$release_launcher" 'if (-not $Build)'
require_literal "$release_launcher" '--dart-define-from-file='
require_literal "$release_gate" 'android/key.properties'
require_literal "$release_gate" "APP_ENV_MUST_BE_PRODUCTION"
require_literal "$release_gate" "APP_DEEP_LINK_SCHEME"
require_literal "$release_gate" "SIGNING_CONFIG_MISSING"
reject_literal "$play_guide" 'flutter build appbundle --flavor production --release'

echo 'Android production flavor, release signing, and backup contract tests passed.'
