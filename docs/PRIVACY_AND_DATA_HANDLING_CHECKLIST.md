# Privacy and data-handling checklist

Status: engineering inventory for release review. This is not legal advice, a
published privacy policy, or a completed Google Play Data safety / Apple App
privacy declaration. The final answers must be derived from the exact deployed
configuration and approved by the responsible product/legal owner.

Current status is repository-only preparation. No hosted Supabase deployment,
live AI/Gmail/email-provider call, cleanup execution/schedule, production API
key entry, physical-device run, signed store binary, or store submission is
claimed by this checklist.

## Data inventory

| Data or capability | Purpose and current boundary | Release question |
| --- | --- | --- |
| Auth user ID and email | Supabase authentication and account-scoped access | Confirm providers, verification, retention, export, and deletion language |
| Profile, university, term, period settings | Personalize university schedule and timetable | Confirm fields, visibility defaults, and whether any value is public |
| Courses, assignments, exams, events, routines | Core personal schedule; Drift offline copy plus authenticated Supabase sync | Document retention, conflict history, export, and full deletion behavior |
| Friends, groups, calendars, comments, reactions | Sensitive relationship/UGC schema with RLS and server projection | Do not enable publicly until report/block/moderation/support controls are accepted |
| Visibility/free-time projections | Share only server-projected availability/detail allowed by policy | Verify no client-side masking is treated as access control |
| Document uploads, extracted text, candidates | Private review-before-confirm flow; raw source/candidates expire after 30 days. The live adapter sends sanitized text for TXT and bounded inline bytes for validated PDF/images; live use is not yet exercised | Confirm processor/model, region, provider retention/training controls, deletion worker, retry/error evidence, and user notice |
| Gmail import metadata/content | Optional server-mediated import; OAuth credentials stay behind the trusted boundary | Confirm scopes, consent screen, encrypted credential storage, disconnect/revoke/delete behavior |
| Device/push tokens | Notification delivery; database stores bounded token identifiers | Confirm FCM/APNs configuration, rotation, deletion, and provider disclosures |
| Local notification/alarm settings | On-device reminders and privacy-safe lock-screen behavior | Explain notification permission and exact/full-screen alarm use |
| Widget snapshot | Bounded title/room/busy projection in app-private/shared widget storage | Verify selected privacy mode and locked-device exposure on each OS |
| Diagnostics | No production analytics/crash SDK is asserted by this checklist | If enabled later, inventory fields, consent/opt-out, processors, retention, and deletion first |

## Required handling controls

- [ ] Production/staging URLs and project refs are explicit, separate, HTTPS, and
      fail closed; the mobile app contains only a publishable client key.
- [ ] The isolated Android staging flavor is
      `jp.universityschedule.app.staging` with scheme
      `unischedule-staging`; production is `jp.universityschedule.app` with
      scheme `unischedule`. Environment identity is verified from the exact
      binary/configuration rather than inferred from a filename.
- [ ] Supabase service-role, provider API keys, OAuth client secrets, signing
      keys, APNs keys, and refresh-token plaintext never enter Flutter code,
      source control, artifacts, screenshots, analytics, or logs.
- [ ] Exposed Supabase tables have RLS, sensitive sharing uses an RPC/view
      projection, and cross-user negative tests pass.
- [ ] Logs contain only allowlisted categories and opaque correlation IDs—no
      email address, auth/OAuth token, schedule title, room, document text,
      filename, provider body, or signed URL.
- [ ] Raw document sources and review candidates follow the 30-day policy in
      `docs/operations/DOCUMENT_IMPORT_RETENTION.md`; cleanup preview, bounded
      execution, retry, and object deletion are rehearsed on synthetic staging
      data before activation.
- [ ] Gmail disconnect revokes access where supported, destroys protected token
      material, stops sync, and clearly distinguishes provider-derived data from
      user-confirmed schedule records.
- [ ] Account deletion removes owned Storage objects before deleting the Auth
      user, covers cascaded/private data, states any lawful retention, and is
      available both in-app and through the configured public web resource.
- [ ] Export/access/correction/support request handling, identity verification,
      response owner, and incident escalation are documented outside source.
- [ ] Transport security, processor regions, encryption at rest, backups,
      subprocessors, and retention are verified against deployed vendor/account
      settings rather than assumed from local code.

## Device storage and backups

Android explicitly disables OS backup and excludes root files, files,
databases, shared preferences, and external app data from both cloud backup and
device-to-device transfer. Server-backed data must return only through an
authenticated sync. Verify the merged release manifest because OEM behavior and
future manifest changes can alter the effective policy.

iOS is not release-ready. The Dart bootstrap requests a
`flutter_secure_storage` Keychain-backed store for auth/session and PKCE values,
but the repository has no Runner Xcode project, signing entitlements, or
provisioning profile. The handoff must inspect the signed app's effective
Keychain entitlements/access group, prove first-install/relaunch/upgrade/lock/
sign-out behavior on device, choose file protection and backup exclusion for
caches/documents, and limit the App Group to the bounded widget snapshot. Dart
unit tests, the contract-only Swift source, and the example App Group identifier
are not Keychain or device runtime evidence.

## Permission and disclosure review

- [ ] Internet: required for Supabase and explicitly enabled live providers.
- [ ] Notifications: ask in context, explain value, and preserve useful behavior
      when denied.
- [ ] Exact alarm/full-screen intent: explain the alarm use case, expose capability
      state/fallback, and complete current Play declarations.
- [ ] Boot/time/date/timezone receivers: used only to reschedule enabled local
      alarms/widgets; verify no unexpected background collection.
- [ ] File selection: use the system picker and process only the file the user
      selected; verify type/size limits and deletion notice.
- [ ] Gmail OAuth: request the smallest accepted scopes and keep browser-based
      consent, state/PKCE, token rotation, and revocation inside the trusted flow.
- [ ] Push: document FCM/APNs identifiers and message metadata; never put private
      schedule detail in a lock-screen payload by default.

## Store-form evidence packet

For each declared data type record: collected/not collected, optional/required,
purpose, linked-to-user status, tracking status, transport, storage/processors,
retention, user deletion path, and exact code/config evidence. Resolve conflicts
between Android and iOS before answering a shared store questionnaire.

Final sign-off requires the exact binary/configuration, a public policy revision,
support and deletion URLs, a subprocessors list, a synthetic staging deletion
rehearsal, and human legal/product/security approval. An unchecked item remains
a release blocker; it must not be converted to `PASS` because a credential or
platform is unavailable.

## External evidence still required

- `REQUIRES_STAGING_CREDENTIAL`: separate hosted project identity, protected
  secrets, digest-bound deployment preview/apply evidence, and synthetic live
  Document AI/Gmail/university-email-verification checks.
- `REQUIRES_DESTRUCTIVE_STAGING_APPROVAL`: bounded source/Storage cleanup and
  account-deletion rehearsal with count-only evidence; no scheduler is active.
- `REQUIRES_PHYSICAL_DEVICE`: Android OEM alarm/notification/TalkBack and iOS
  Keychain/widget/notification behavior.
- `REQUIRES_PRODUCTION_APPROVAL`: production deploy, final processor/account
  settings, exact binary review, policy/legal sign-off, and store forms/upload.
