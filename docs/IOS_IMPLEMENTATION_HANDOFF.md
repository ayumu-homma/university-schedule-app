# iOS implementation handoff

Status: contract preparation only. `apps/mobile/ios` currently contains only
the contract-only WidgetKit Swift source; it does not contain a Runner Xcode
project, scheme, Info.plist, entitlements, Podfile, or extension target. Windows
can validate Dart JSON and source invariants, but it cannot create credible
Xcode build/signing/runtime evidence. No Apple Developer capability,
certificate, profile, APNs key, App Group, TestFlight app, or App Store record
has been created.

## Readiness classification

| Area | Classification | Evidence / remaining work |
| --- | --- | --- |
| Flutter shared product code | IMPLEMENTED | Dart/Riverpod/Drift/routing code is platform-neutral and covered by existing tests |
| Widget JSON schema v1 | IMPLEMENTED | Strict Dart encoder/decoder plus `packages/shared_domain/test/fixtures/widget_snapshot_v1.json` |
| WidgetKit decoder source | PARTIAL | Swift source now mirrors schema v1 and rejects unknown/unsafe payloads; it is not in a compiled extension target |
| iOS Runner/Xcode project | REQUIRES_MACOS | `Runner.xcodeproj`, Runner Info.plist/entitlements, Podfile, schemes, and build configurations are absent |
| Bundle IDs/signing | REQUIRES_APPLE_ACCOUNT | Intended app ID is `jp.universityschedule.app`; availability and final ownership are unverified |
| App Group bridge | PARTIAL / REQUIRES_APPLE_ACCOUNT | Key/storage contract exists; `group.jp.example.universityschedule` is a placeholder and no Flutter writer/entitlements exist |
| Custom deep links | PARTIAL | Dart normalizer/routes exist; iOS URL types and native runtime tests are absent |
| Universal links | MISSING / REQUIRES_PUBLIC_HTTPS | Associated Domains entitlement and AASA file are absent |
| APNs notifications | MISSING / REQUIRES_APPLE_ACCOUNT | No APNs capability, token registration, actions, or iOS runtime implementation |
| Secure auth storage | PARTIAL / REQUIRES_MACOS | Common bootstrap injects a `flutter_secure_storage`-backed Supabase session/PKCE store, migrates legacy values only after read-back, and requests non-synchronizing `unlocked_this_device`; pinned `flutter_secure_storage` 10.3.1 also requires `keychain-access-groups` in both Runner entitlement files, which do not yet exist, so effective access group/runtime/upgrade behavior remains unverified |
| TestFlight/App Store | REQUIRES_APPLE_ACCOUNT | External human-owned archive, upload, metadata, review, and rollout |

## macOS/Xcode preparation

Use a clean, isolated change on a supported macOS host with Flutter 3.47.1,
current project-compatible Xcode, CocoaPods, and the iOS SDK. Record:

```bash
sw_vers
xcodebuild -version
xcrun simctl list runtimes
flutter --version
flutter doctor -v
pod --version
```

Generate the missing iOS platform scaffold from `apps/mobile` only after
reviewing how Flutter will derive identifiers:

```bash
flutter create --platforms=ios --org jp.universityschedule .
```

Treat generated changes as untrusted until reviewed. Preserve the existing
Flutter/Dart source, set the Runner bundle ID explicitly to the final approved
ID, and do not accept example identifiers. Add unit/UI test targets before
claiming runtime support. Flutter's current build prerequisites and archive
flow are documented at [Build and release an iOS app](https://docs.flutter.dev/deployment/ios).

There is no repository-defined iOS staging scheme today. When the host is
created, add explicit `staging` and `production` schemes/configurations, give
staging a distinct bundle ID and `unischedule-staging` URL scheme, and bind the
production scheme to the approved production bundle ID and `unischedule`.
Until those files exist and build on macOS, Android flavor commands are not
evidence of equivalent iOS separation.

## Identifiers and capabilities

The Apple account owner must choose and record, without committing credentials:

- Runner bundle ID: intended `jp.universityschedule.app`, subject to ownership;
- Widget extension ID: recommended `<runner-id>.WeeklyTimetableWidget`;
- one non-example App Group shared by Runner and extension;
- Associated Domains entry `applinks:<approved-web-host>` for Runner;
- Push Notifications and `aps-environment` for Runner;
- Background Modes `remote-notification` only if the implemented APNs design
  actually needs silent background delivery.

Provisioning profiles must include exactly those entitlements. Inspect the
archive's effective entitlements before TestFlight. Do not copy a Team ID,
profile UUID, certificate, `.p8`, or App Group value into general documentation.

## WidgetKit bridge contract

The only shared value is UTF-8 JSON under
`weekly_timetable_snapshot`. Schema v1 is:

| Object | Exact fields |
| --- | --- |
| Root | `schemaVersion`, `mode`, `generatedAt`, `weekStart`, `timezone`, `privacyMode`, `days`, `periods`, `items` |
| Day | `dayOfWeek`, `label` |
| Period | `periodNo`, `start`, `end` |
| Item | `courseId`, `dayOfWeek`, `periodNo`, `title`, optional-by-mode `room`, `colorKey`, `deepLink` |

Constants are schemaVersion 1, mode `timetable_week`, timezone `Asia/Tokyo`,
Monday–Friday and periods 1–5. Privacy modes are `title`, `titleAndRoom`, and
`busyOnly`; busy-only titles must be `予定あり`. Deep links must exactly match
`unischedule://course/<safe-course-id>`. Payloads are bounded to 64 KiB in the
Swift decoder.

Add `WeeklyTimetableWidget.swift` to the extension target and make the canonical
fixture available to an XCTest target. The Flutter/native bridge must:

1. validate/generate through the Dart schema-v1 type;
2. atomically write only the JSON string to the final App Group UserDefaults;
3. call `WidgetCenter.shared.reloadTimelines(ofKind:)` after a successful write;
4. retain the last valid snapshot when a new payload is rejected;
5. clear the snapshot on sign-out/account deletion and render a safe empty state;
6. never give the extension direct Supabase, SQLite, token, or raw document
   access.

Use the official Flutter App Extension guidance for target integration, App
Groups, memory, and deployment-version constraints:
[Adding iOS app extensions](https://docs.flutter.dev/platform-integration/ios/app-extensions).

## Deep-link contract

Register the custom `unischedule` URL scheme in Runner Info.plist for existing
auth, Today, timetable, and course routes. Continue routing through the Dart
normalizer; do not navigate from arbitrary URL text or bypass authorization.

For HTTPS links, add the Runner Associated Domains entitlement and serve a valid
`apple-app-site-association` file from the approved host with the exact Team ID
and bundle ID. Allow only intended paths, avoid redirects, and test cold start,
warm start, signed-out deferral, sign-in callback correlation, malformed links,
and cross-account course identifiers. Apple setup reference:
[Supporting associated domains](https://developer.apple.com/documentation/Xcode/supporting-associated-domains).

## Notifications and morning alarm

iOS must not imitate Android exact-alarm/full-screen behavior. Implement an iOS
provider using `UNUserNotificationCenter`, request authorization in context,
schedule within platform limits, register only reviewed categories/actions,
route taps through the same deep-link allowlist, and handle denial/revocation.
APNs delivery additionally needs capability registration, token rotation,
trusted-server association, privacy-safe payloads, foreground/background tests,
and deletion/sign-out cleanup. A placeholder/in-memory provider is never
production evidence.

## Secure storage and account lifecycle

The common Flutter bootstrap now injects `SecureAuthStorageBundle` into both
Supabase session and PKCE persistence. It uses `flutter_secure_storage`, a
project-isolated key namespace, non-synchronizing iOS Keychain storage with
`unlocked_this_device`, and verified write-before-delete migration from the
legacy SharedPreferences locations. Windows unit tests cover migration,
read-back failure, removal, size limits, and project isolation; they are not
Keychain runtime evidence.

`IOSOptions` in Dart expresses requested plugin behavior; it does not create or
prove a signed entitlement, provisioning-profile match, effective Keychain
access group, or successful device read/write. For the pinned
`flutter_secure_storage` 10.3.1 integration, both
`Runner/DebugProfile.entitlements` and `Runner/Release.entitlements` must contain
the `keychain-access-groups` key even when its value is an empty array. Treat
those two files and their target/build-configuration attachment as mandatory,
not optional Keychain Sharing setup. Add a named Keychain access group only
when an intentional sharing design and provisioning capability have been
separately approved; never reuse the widget App Group identifier for auth.

On macOS, inspect the final archive with
`codesign -d --entitlements :- <signed-app-path>` and compare the effective
entitlements with the reviewed profile/capability set.

Verify the selected accessibility behavior on simulator and physical iPhone.
Do not place access/refresh tokens in UserDefaults or the App Group. Verify
first install, relaunch, upgrade from a legacy session, sign-out, device lock,
token refresh, restore, and account deletion. The App Group contains only the
bounded widget snapshot. These items remain `REQUIRES_MACOS` /
`REQUIRES_PHYSICAL_DEVICE`; no current local test changes them to `PASS`.

Account deletion remains a shared backend/product contract: initiate in-app,
confirm scope, reauthenticate when required, expose the public HTTPS alternative,
remove Storage objects before Auth deletion, clear local DB/session/widget/
notification state, and report a bounded result. See
`docs/PRIVACY_AND_DATA_HANDLING_CHECKLIST.md`.

## Build and acceptance

Before signing, require:

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter test
flutter build ios --simulator --debug
flutter build ios --release --no-codesign
xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner \
  -destination 'platform=iOS Simulator,name=<approved simulator>'
```

Then, in a separately approved Apple/signing checkpoint, archive and validate
the exact SHA. On both simulator and named physical devices test fresh install,
upgrade with retained local data, offline restart, sign-in/out/deletion, custom
and universal links, notification denial/actions, timezone/date change, WidgetKit
empty/privacy/course states, dynamic type, VoiceOver, reduced motion, and crash
logs. Record observations without tokens or personal data. Only those results
can change `REQUIRES_MACOS` / `REQUIRES_PHYSICAL_DEVICE` to `PASS`.
