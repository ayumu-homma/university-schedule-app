# Store release checklist

This is an evidence checklist, not a statement that either store release is
ready. Use `PASS` only with an artifact or observation from the exact candidate
SHA. Use `MANUAL REQUIRED`, `REQUIRES_STORE_ACCOUNT`, `REQUIRES_MACOS`, or
`REQUIRES_PHYSICAL_DEVICE` when the named external dependency remains.

Production deployment, real-device operation, API/provider key entry, signing,
and store publication are intentionally the final checkpoints.

## Common release gate

- [ ] Exact candidate SHA and clean build input recorded.
- [ ] Six-job CI for that exact SHA is green; no skipped product assertions.
- [ ] Version and user-visible release notes approved.
- [ ] Staging project identity is pinned and differs from production.
- [ ] Supabase deployment preview and apply are separate manual dispatches;
      apply uses the exact SHA-256 plan digest emitted by the accepted preview.
- [ ] No remote deploy, live-provider smoke, cleanup execution/scheduling, or
      secret registration is marked `PASS` without its external run evidence.
- [ ] Demo mode is off; disabled live-provider features are described honestly.
- [ ] Privacy policy, terms, support, and account-deletion HTTPS URLs are public,
      stable, and owned by the release operator.
- [ ] In-app account deletion initiates the real trusted workflow, requires
      appropriate reauthentication/confirmation, and reports outcome without
      exposing sensitive data.
- [x] Existing-group block behavior covers both block directions with privacy-
      safe member/comment labels, preserved roles and authorized controls, and
      a verified server/DB authorization contract. User-authored text is not
      assumed to redact names embedded in its body.
      P73/P78/P79 fake-backed Flutter evidence and P77 isolated DB/RLS/Auth acceptance
      (49/49 migrations, pgTAP 13/13) support this local criterion; connected
      Flutter/device acceptance is tracked separately. P79 specifically verifies
      event/comment dialogs and picker routes hide prior-account content and do
      not persist stale edits after identity changes. P80 additionally binds
      group create/edit drafts and their submissions to the opening account. P81 also hides friend names in the group invite picker after account changes.
- [ ] Deletion rehearsal covers Storage cleanup before Auth deletion and
      documented retention exceptions.
- [ ] Privacy/data inventory has product, security, and legal owner sign-off.
- [ ] No service-role/provider secret, OAuth client secret, signing material,
      raw document, token, or personal schedule is present in source/artifacts.
- [ ] Accessibility automated gates pass; screen-reader and physical-device
      observations remain explicitly manual.
- [ ] Store copy and screenshots match the exact enabled feature set and have a
      privacy review.
- [ ] Support, incident, rollback, and vulnerability-contact owners are named.

## Google Play internal testing

- [ ] Package is exactly `jp.universityschedule.app`; first-upload ownership and
      immutability are acknowledged.
- [ ] The release is built with `--flavor production`,
      `APP_ENV=production`, and scheme `unischedule`; the isolated staging
      package `jp.universityschedule.app.staging` / scheme
      `unischedule-staging` is not uploaded.
- [ ] The reviewed command is
      `.\tool\build_android_production_release.ps1 -ConfigFile .env.production.json -Build`
      and its output is
      `build/app/outputs/bundle/productionRelease/app-production-release.aab`.
- [ ] `versionCode` is greater than every prior Console artifact.
- [ ] Current target API and Play policy requirements are rechecked on upload
      day; repository values alone are not sufficient evidence.
- [ ] External upload keystore is backed up and access-controlled; the repository
      contains neither the key nor its passwords.
- [ ] Partial signing configuration and missing keystore fail closed; there is
      no debug-key fallback.
- [ ] Signed AAB signature, SHA-256, package, versions, SDK levels, contents, and
      installability from a Play-generated APK set are verified.
- [ ] `apksigner verify --print-certs` records the Play-installed APK-set
      certificate digest. The review distinguishes the declared source SHA,
      AAB hash/upload signer, and installed APK hashes/Play app signer; none is
      inferred from another.
- [ ] R8/resource shrinking remains off for the first internal candidate, or a
      separate reviewed change supplies release-smoke and mapping evidence.
- [ ] Cloud backup and device-transfer exclusion is verified in the merged
      release manifest/resources.
- [ ] Custom-scheme links are described accurately; no verified HTTPS App Link
      is claimed while `autoVerify`/`assetlinks.json` remain absent.
- [ ] Notification, exact-alarm, and full-screen-intent declarations are complete
      and consistent with actual alarm behavior and policy eligibility.
- [ ] Data safety, content rating, target audience, ads status, and account
      deletion declarations are answered from the approved data inventory.
- [ ] Internal testers, feedback channel, device matrix, acceptance evidence, and
      rollback owner are recorded.
- [ ] No closed/open/production promotion is performed in this change window.

Detailed procedure: `docs/GOOGLE_PLAY_INTERNAL_TESTING.md`.

## Apple development and TestFlight

- [ ] `REQUIRES_MACOS`: generate and review a complete Flutter iOS Runner project;
      the current repository does not contain an Xcode host target.
- [ ] `REQUIRES_APPLE_ACCOUNT`: register the final bundle ID, extension ID, App
      Group, Associated Domains, and APNs capabilities.
- [ ] Runner and WidgetKit extension use the same reviewed App Group; no example
      identifier remains in an archive.
- [ ] Swift schema-v1 decoder is added to the extension target and tested with
      the canonical JSON fixture on macOS.
- [ ] Flutter writes the exact schema-v1 JSON atomically to shared UserDefaults
      and reloads WidgetKit timelines; privacy modes are verified while locked.
- [ ] Custom scheme and universal links route only allowlisted destinations;
      AASA is served over HTTPS and tested without redirects.
- [ ] APNs registration, authorization denial, foreground/background behavior,
      notification actions, and token rotation are tested.
- [ ] Auth/session secrets use an approved Keychain-backed store; no release
      session relies on plain preferences. The existing Dart
      `flutter_secure_storage` options and unit tests are not evidence that the
      final signed app has the intended effective Keychain entitlements or
      runtime/upgrade behavior.
- [ ] Effective archive entitlements and provisioning are inspected with
      `codesign`, and first install/relaunch/upgrade/sign-out/locked-device
      Keychain behavior is observed on a signed build.
- [ ] Runner `DebugProfile.entitlements` and `Release.entitlements` both contain
      the mandatory `keychain-access-groups` key (empty array unless a named
      group is separately approved); the widget App Group is never used for
      auth/session values.
- [ ] `flutter build ios --release --no-codesign`, signed archive, export, symbol,
      and privacy-manifest checks pass on the pinned macOS/Xcode toolchain.
- [ ] Apple account deletion requirements and App privacy answers are validated
      against the exact binary.
- [ ] `REQUIRES_PHYSICAL_DEVICE`: launch, upgrade, deep link, notification,
      widget, offline restart, dynamic type, VoiceOver, and deletion are observed.
- [ ] TestFlight remains internal until feedback and rollback criteria pass; no
      App Store submission or release is performed in this change window.

Detailed native handoff: `docs/IOS_IMPLEMENTATION_HANDOFF.md`. Apple states that
apps supporting account creation must let users initiate deletion in-app;
review the current official guidance at the release checkpoint:
[Offering account deletion in your app](https://developer.apple.com/support/offering-account-deletion-in-your-app/).

## Store asset and copy gate

- [ ] Draft copy has product/legal approval and contains no unsupported claims.
- [ ] Eight existing 1080 x 2424 phone captures are mapped to truthful captions.
- [ ] Every selected capture is synthetic, contains no account/email/token or
      personal schedule, matches the candidate theme, and is current.
- [ ] Required 512 x 512 Play icon and 1024 x 1024 App Store icon are produced
      from approved source art; launcher mipmaps are not upscaled as store art.
- [ ] Google Play feature graphic and any locale-specific assets are produced
      and reviewed against current Console requirements.
- [ ] Copyright/trademark/license ownership for copy and visual assets is
      recorded.

Draft and inventory: `docs/STORE_LISTING_DRAFT.md`.
