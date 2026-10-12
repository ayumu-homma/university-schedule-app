#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift="$repo_root/apps/mobile/ios/Runner/WeeklyTimetableWidget/WeeklyTimetableWidget.swift"
fixture="$repo_root/packages/shared_domain/test/fixtures/widget_snapshot_v1.json"
dart_test="$repo_root/packages/shared_domain/test/widget_snapshot_test.dart"

fail() {
  echo "iOS widget contract test failed: $1" >&2
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
    fail "$file still uses the obsolete widget shape: $literal"
  fi
}

[[ -s "$swift" ]] || fail 'WidgetKit contract source is missing.'
[[ -s "$fixture" ]] || fail 'Canonical schema-v1 fixture is missing.'

for field in \
  schemaVersion mode generatedAt weekStart timezone privacyMode \
  days periods items courseId dayOfWeek periodNo title room colorKey deepLink; do
  require_literal "$swift" "let $field:"
  require_literal "$fixture" "\"$field\""
done

for invariant in \
  'static func decodeStrict(from data: Data)' \
  'data.count <= 64 * 1024' \
  'JSONSerialization.jsonObject' \
  'requireExactKeys' \
  '"timetable_week"' \
  '"Asia/Tokyo"' \
  '"titleAndRoom"' \
  '"busyOnly"' \
  'unischedule://course/' \
  'TimetableSnapshot.decodeStrict(from: data)'; do
  require_literal "$swift" "$invariant"
done

reject_literal "$swift" 'let weekdays:'
reject_literal "$swift" 'let startPeriod:'
reject_literal "$swift" 'let endPeriod:'
reject_literal "$swift" 'let cells:'

require_literal "$dart_test" "File('test/fixtures/widget_snapshot_v1.json')"
require_literal "$dart_test" 'WidgetSnapshot.fromJson(fixture).toJson()'

echo 'iOS WidgetKit schema-v1 contract tests passed.'
