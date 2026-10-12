# Google Play Internal Testing handoff

Status: preparation only. No Play Console app, upload key, signed artifact,
tester list, or release has been created by this repository work.

## Repository release contract

| Item | Current repository value | Gate |
| --- | --- | --- |
| Production application ID | `jp.universityschedule.app` | Confirm ownership before the first Play artifact upload; treat it as immutable afterward |
| Staging application ID | `jp.universityschedule.app.staging` | Never upload this isolated debug/staging package as the production Play app |
| Production flavor / deep-link scheme | `production` / `unischedule` | The Dart configuration, native flavor, and manifest scheme must agree |
| App version | `0.1.0+1` (`versionName` 0.1.0, `versionCode` 1) | Increment the build number for every uploaded artifact |
| Minimum Android SDK | Flutter-configured value, currently 24 in the verified debug artifact | Recheck the release AAB |
| Target/compile SDK | Flutter-configured values, currently 36 in the verified debug artifact | Recheck current Play policy immediately before upload |
| Backup | Disabled for cloud backup and device-to-device transfer | Keep the manifest and both XML exclusion files covered by `test_android_release_contract.sh` |
| R8/resource shrinker | Explicitly disabled for the first internal-test build | Enable only in a separate reviewed change with signed-release smoke evidence and retained mapping files |

The release build never falls back to the Android debug certificate. It reads
the ignored `apps/mobile/android/key.properties` only when that file exists:

- no file: a local unsigned release artifact may be built for structural checks;
- missing/blank property: Gradle fails during configuration;
- nonexistent `storeFile`: Gradle fails during configuration;
- all four properties and an existing file: the release signing configuration
  is attached.

The required property names are `storeFile`, `storePassword`, `keyAlias`, and
`keyPassword`. `apps/mobile/android/key.properties.example` documents the
shape without credentials. Keep the upload keystore outside the repository,
limit access, back it up through an approved secret-management process, and do
not print property values. Android's official guidance distinguishes the
private upload key from the Play-managed app-signing key and rejects debug
certificates for store publishing: [Sign your app](https://developer.android.com/studio/publish/app-signing).

## Pre-upload build checkpoint

This checkpoint is intentionally last because it needs external configuration.
From `apps/mobile`, after the production configuration, policy URLs, and
complete external signing file have been approved, use the production flavor.
The ignored input file must contain `APP_ENV=production`,
`APP_DEMO_MODE=false`, `APP_DEEP_LINK_SCHEME=unischedule`, the production
Supabase URL/ref binding, a public client key, and the four approved public
HTTPS URLs:

```powershell
flutter clean
flutter pub get
.\tool\build_android_production_release.ps1 `
  -ConfigFile .env.production.json -Build
jarsigner -verify -strict -verbose `
  build/app/outputs/bundle/productionRelease/app-production-release.aab
```

The PowerShell wrapper validates production Dart defines and requires
`android/key.properties` to exist before starting Flutter. Gradle then checks
the signing properties and referenced keystore. Configuration and signing
values are not printed. Omit `-Build` to run the preflight without building.

The expected output is
`build/app/outputs/bundle/productionRelease/app-production-release.aab`.
Building without `--flavor production` is not a release candidate. The
repository has not created, signed, or uploaded this AAB; these commands remain
an external release checkpoint.

Do not paste secrets into the command line, shell history, Gradle files, CI
logs, or `--dart-define` values visible in process listings. Supply the
reviewed public mobile configuration through the approved build environment.
The signing reviewer records only the artifact SHA-256, package/version,
certificate SHA-256 fingerprint, tool versions, and pass/fail result.

Before upload, also inspect the AAB with Android Studio's Bundle Analyzer or a
pinned `bundletool` version and verify:

1. package `jp.universityschedule.app`, expected versionCode/versionName, min
   and target SDK;
2. no `.env`, `key.properties`, keystore, provider key, service-role key, raw
   document, or test fixture containing personal data;
3. notification/alarm receivers and widget metadata are present;
4. the signed release installs through a Play-generated test APK set and opens
   the production entry point without demo mode;
5. a mapping artifact is not expected while R8 remains disabled.

`jarsigner` verifies the upload-signed AAB. It does not prove the identity of
the APK installed by Play, which is signed with the Play-managed app-signing
key. On a test device, obtain the installed APK set through the approved Play
or `bundletool` path and run `apksigner verify --print-certs` on every APK.
Record the installed package/version and certificate SHA-256 digest separately
from the AAB SHA-256 and upload-certificate digest.

## Permissions and policy declarations

The manifest requests notifications, exact-alarm scheduling, full-screen
intent, vibration, boot completion, and internet access. These are functional
alarm requirements, not permission to skip Play review. At the manual Play
checkpoint:

- complete every applicable Permissions Declaration Form truthfully;
- confirm the app's alarm/reminder use case is eligible for exact alarm and
  full-screen intent under the then-current policy;
- verify denial and fallback behavior on the internal-test build;
- keep screenshots and descriptions aligned with the actual release behavior.

Use the current official policy rather than copying this document into the
console: [Permissions and APIs that access sensitive information](https://support.google.com/googleplay/android-developer/answer/16558241?hl=en).

## Links

The production flavor registers the custom `unischedule` scheme; staging uses
the isolated `unischedule-staging` scheme. Neither declares an HTTPS
`autoVerify` App Link, and the repository does not provide `assetlinks.json`.
That is acceptable only when store copy does not claim verified web-to-app
routing. Privacy, terms, support, and deletion URLs must remain normal public
HTTPS browser destinations. If verified Android App Links become a release
requirement, add the narrow host/path allowlist and hosted Digital Asset Links
file in a separate reviewed change, then test valid, malformed, signed-out, and
cross-account links against the release signer.

## Account, policy, and support blockers

Do not upload until all of the following work against the selected staging
backend and public HTTPS host:

- privacy policy, terms, and support URLs resolve without authentication;
- account deletion can be initiated in-app with clear scope and confirmation;
- the public account-deletion URL explains how to request deletion outside the
  app and what data is deleted or retained;
- the trusted deletion worker removes owned Storage objects before Auth user
  deletion and records only privacy-safe evidence;
- Data safety answers match the reviewed production configuration.

Google currently requires an in-app deletion path and a web resource for apps
that let users create accounts. Recheck the official page before submission:
[App account deletion requirements](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en).

## Internal-track manual procedure

1. A human owner creates or selects the Play Console app for the exact package.
2. Enroll in Play App Signing and register the separately protected upload
   certificate.
3. Complete App content, Data safety, target audience, ads, content rating,
   privacy policy, account deletion, and permission declarations.
4. Create an Internal testing release, upload the reviewed signed AAB, and
   inspect all Console warnings. Do not promote the release.
5. Add only approved tester accounts or a managed group. Internal testing is
   intended for a small controlled cohort; consult the current limit and
   availability rules in [Play Console internal testing guidance](https://support.google.com/googleplay/android-developer/answer/9845334?hl=en).
6. Install through the Play opt-in URL on named test devices, verify package,
   version, the Play app-signing certificate with `apksigner`, login/deletion,
   notification/alarm fallback, retained upgrade, widget, deep links, and
   offline restart. A declared source SHA is provenance metadata; it is not
   proof of the installed binary. Bind the review record to the AAB hash and
   the installed APK-set hashes/certificate digests.
7. Record tester/device/OS, artifact hash, observations, crash/ANR status, and
   rollback owner. Never record account tokens or personal schedule content.

Rollback means halting or deactivating the internal release in Play Console and
returning testers to the last accepted version where Play permits it. Database
or Edge Function rollback is a separate, explicitly approved operation.

Store copy and assets remain drafts in `docs/STORE_LISTING_DRAFT.md`; the full
human gate is `docs/STORE_RELEASE_CHECKLIST.md`.
