#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gradle="$repo_root/apps/mobile/android/app/build.gradle.kts"
manifest="$repo_root/apps/mobile/android/app/src/main/AndroidManifest.xml"
config="$repo_root/apps/mobile/lib/core/config/app_config.dart"
alarm="$repo_root/apps/mobile/android/app/src/main/kotlin/jp/universityschedule/alarm/MorningAlarmContract.kt"
widget="$repo_root/apps/mobile/android/app/src/main/kotlin/jp/universityschedule/widget/WeeklyTimetableWidget.kt"
runner="$repo_root/scripts/run_android_personal_management_e2e.sh"
integration_test="$repo_root/apps/mobile/integration_test/personal_management_e2e_test.dart"
physical="$repo_root/scripts/run_android_physical_acceptance.ps1"
capture="$repo_root/scripts/capture_portfolio_screenshots.ps1"
record="$repo_root/scripts/record_portfolio_demo.ps1"
supabase_config="$repo_root/supabase/config.toml"

fail() {
  echo "Android environment isolation contract failed: $1" >&2
  exit 1
}

require_literal() {
  local file="$1"
  local literal="$2"
  grep -Fq -- "$literal" "$file" || fail "$file is missing: $literal"
}

for file in \
  "$gradle" "$manifest" "$config" "$alarm" "$widget" "$runner" \
  "$integration_test" "$physical" "$capture" "$record"; do
  [[ -s "$file" ]] || fail "required file is missing or empty: $file"
done

[[ -s "$supabase_config" ]] ||
  fail "required file is missing or empty: $supabase_config"

require_literal "$gradle" 'applicationId = "jp.universityschedule.app"'
require_literal "$gradle" 'create("staging")'
require_literal "$gradle" 'applicationIdSuffix = ".staging"'
require_literal "$gradle" 'create("production")'
require_literal "$gradle" 'manifestPlaceholders["appLabel"] = "Uni Schedule (Staging)"'
require_literal "$gradle" 'manifestPlaceholders["authScheme"] = "unischedule-staging"'
require_literal "$gradle" 'manifestPlaceholders["authScheme"] = "unischedule"'
require_literal "$gradle" 'buildConfigField("String", "DEEP_LINK_SCHEME"'
require_literal "$manifest" 'android:label="${appLabel}"'
require_literal "$manifest" 'android:scheme="${authScheme}"'
require_literal "$config" "AppEnvironment.staging => const {'unischedule-staging'}"
require_literal "$config" "AppEnvironment.production => const {'unischedule'}"
require_literal "$config" 'nativeAppFlavor: services.appFlavor ??'
require_literal "$config" 'Android flavor must be $expectedFlavor'
require_literal "$alarm" 'BuildConfig.DEEP_LINK_SCHEME'
require_literal "$widget" 'environmentDeepLink(uri)'
require_literal "$widget" 'BuildConfig.DEEP_LINK_SCHEME'
require_literal "$runner" "test_app_package='jp.universityschedule.app.staging'"
require_literal "$runner" '--flavor staging'
require_literal "$runner" '--dart-define=APP_DEEP_LINK_SCHEME=unischedule-staging'
require_literal "$integration_test" \
  "String.fromEnvironment('APP_DEEP_LINK_SCHEME')"
require_literal "$integration_test" \
  "if (deepLinkScheme != 'unischedule-staging')"
require_literal "$integration_test" \
  'deepLinkScheme: environment.deepLinkScheme'
require_literal "$integration_test" \
  'SecureAuthStorageBundle.forSupabaseUrl('
require_literal "$integration_test" \
  'localStorage: secureAuthStorage.sessionStorage'
require_literal "$integration_test" \
  'pkceAsyncStorage: secureAuthStorage.pkceStorage'
require_literal "$integration_test" \
  'secureAuthLocalStorageProvider.overrideWithValue(sessionStorage)'
require_literal "$physical" '[string]$PackageName = "jp.universityschedule.app.staging"'
for portfolio_script in "$capture" "$record"; do
  require_literal "$portfolio_script" '[string]$PackageName = "jp.universityschedule.app.staging"'
  require_literal "$portfolio_script" '[string]$DeepLinkScheme = "unischedule-staging"'
  require_literal "$portfolio_script" 'restricted to the isolated staging Android app'
done

redirect_allowlist="$({
  awk '
    /^[[:space:]]*additional_redirect_urls[[:space:]]*=/ { capturing=1 }
    capturing { print }
    capturing && /]/ { exit }
  ' "$supabase_config"
})"
[[ "$redirect_allowlist" == *'"unischedule-staging://auth-callback/"'* ]] ||
  fail 'local Supabase Auth must allow the exact staging callback URI'
[[ "$redirect_allowlist" == *'"unischedule://auth-callback/"'* ]] ||
  fail 'local Supabase Auth must retain the canonical production callback URI'

if grep -Fq -- 'applicationIdSuffix' "$gradle" &&
  grep -Fq -- 'create("production")' "$gradle"; then
  production_block="$(sed -n '/create("production")/,/^        }/p' "$gradle")"
  [[ "$production_block" != *'applicationIdSuffix'* ]] ||
    fail 'the production flavor must retain jp.universityschedule.app'
fi

echo 'Android staging/production app-data isolation contract passed.'
