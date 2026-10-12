# Portfolio v0.5 Addendum

Status: Active

Date: 2026-08-10 JST

This addendum extends `docs/university_schedule_app_spec_v0.4.md` for the Android
portfolio release. It does not replace or rewrite v0.4. When an older document
conflicts with this addendum, the active Portfolio v0.5 goal and this addendum
take precedence.

## Cross-cutting constraints

- Flutter/Riverpod/go_router/Drift remain the mobile architecture.
- Drift reactive queries remain the rendering source; Supabase is never a UI-blocking read dependency.
- PostgreSQL/RLS remains the authorization boundary. Client-side masking is not authorization.
- Schedule and imported documents are sensitive and private by default.
- Realtime accelerates invalidation only; durable delta/outbox reconciliation remains authoritative.
- No Assignment, Exam, Event, reminder, projection, or sync mutation may be created from AI output before explicit user confirmation.
- Exact alarms and full-screen intents require explicit capability checks and a documented notification fallback. The app never changes global device volume.
- Synthetic fixtures and data are required for tests, screenshots, and video.

## Requirement catalogue

### UX-01 — Design system

Define semantic light/dark colors, typography, 8 dp spacing, radii, elevations,
icon/touch/component sizes, motion durations, responsive breakpoints, and
course/assignment/exam/event/deadline status semantics. Apply the system through
ThemeData and shared components rather than screen-local styling.

Acceptance evidence: theme/component tests in light and dark mode, source audit
showing the shared tokens in production screens, and portfolio screenshots.

### UX-02 — Touch, text, and accessibility

Interactive targets are normally at least 48 x 48 logical pixels; body/supporting
text is normally at least 16/14 sp and labels at least 12 sp. Critical state is
communicated with text/icon/shape as well as color. Production routes provide
appropriate Semantics, labels, tooltips, keyboard-safe actions, SafeArea handling,
and usable layouts at 360 x 640, 412 x 915, tablet widths, text scale 1.0/1.3,
and a representative 2.0 case.

Acceptance evidence: widget/accessibility matrix with long Japanese strings and
empty/loading/error/offline states; no weakened assertions.

### UX-03 — Primary-screen and form improvement

Home becomes action-oriented; timetable provides usable week/day modes without
nested fixed-width scrolling, shows each period's start/end time, renders neutral
blank empty cells, and exposes tap-visible edit/delete actions. Assignment/exam
views group Today/This week/Later/Overdue/Submitted and support undoable submit.
Forms clearly mark required/optional input, keep validation beside fields, prevent
double submit, keep primary actions visible above the keyboard, and confirm
destructive/unsaved exits. Quick Add prioritizes document discovery without
duplicating screen-specific actions.

Acceptance evidence: focused widget tests and Android screenshots for timetable,
tasks, forms, compact width, dark mode, and large text.

### TODAY-01 — Daily aggregation

The production `/today` screen aggregates, in Asia/Tokyo, today's courses,
current/next course, due-today unsubmitted assignments, overdue unsubmitted
assignments, today's exams, personal events, routines, and calendar occurrences.
Home and alarm navigation consume the same aggregation service/state.

Acceptance evidence: domain/query/controller tests and widget navigation tests
cover every item class and assignment submit/Undo behavior.

### TODAY-02 — Offline, date boundary, and navigation

Today renders entirely from Drift-cached state and updates across the local day
boundary. It supports `unischedule://today` and
`unischedule://today?source=morning-alarm` through the existing normalizer/guard,
including signed-out/onboarding and cold-start handling.

Acceptance evidence: fake-clock tests for 23:59/00:00, UTC to Asia/Tokyo, all-day,
course start/end, overdue/submitted filtering, recurrence exceptions, offline
restart, and deep-link guards.

### ALARM-01 — Morning-alarm settings

Notification settings provide an initially disabled, persisted morning check with
time, weekdays, sound, vibration, snooze interval, open-Today preference,
lock-screen privacy, capability/permission status, next occurrence, and a
debug/test-only near-time test hook. Permission requests follow an in-app value
explanation.

Acceptance evidence: persistence, next-occurrence, weekday, permission-denied,
timezone, and restart tests plus the Android settings screenshot.

### ALARM-02 — Stop, snooze, and Today

The selected alarm fires while the app process is absent, provides idempotent
Stop/Snooze/Check Today actions, reschedules the next occurrence, and opens the
single existing `/today` destination on stop/check in warm and cold starts.

Acceptance evidence: Kotlin/Dart contract tests, deep-link tests, emulator
fire/snooze/refire/stop/Today flow, and fatal-log scan.

### ALARM-03 — Restart, clock changes, and fallbacks

Boot, package replacement, date/time/timezone change, and exact-alarm permission
changes recompute schedules from persisted settings. Exact and full-screen
capability are checked at runtime. When unavailable or denied, a high-priority
notification/inexact alarm path remains usable and the UI explains the limitation.
No system volume mutation or policy-bypassing background Activity launch is used.

Acceptance evidence: receiver/scheduler unit tests, manifest audit, permission
fallback tests, and `docs/manual-tests/MORNING_ALARM_ANDROID.md`.

### DOC-AI-01 — Private document upload

Authenticated users may choose PDF, PNG, JPEG, or plain text. Extension, MIME,
signature, file/page/text/candidate limits, encrypted/corrupt/spoofed input, cancel,
timeout, cleanup, and feature flags are handled conservatively. Upload uses a
private bucket and owner-scoped path/RLS; raw content is not logged.

Acceptance evidence: upload validation tests, Storage RLS user-A/B tests, synthetic
fixtures, and upload UI states.

### DOC-AI-02 — Multi-candidate extraction

A versioned strict batch schema returns zero or more Assignment/Exam candidates
(Event only if naturally supported), with stable candidate ID, course hint,
nullable dates/times, Asia/Tokyo, evidence page/section/excerpt, bounded confidence,
warnings, and mandatory confirmation. A document can yield at least two assignments
and one exam. Missing year/time/course is surfaced, never invented.

Acceptance evidence: deterministic fake extractor, strict-codec/Edge contract
tests, prompt-injection/HTML/oversize/corrupt/encrypted/spoofed fixtures, duplicate
republication, and schema-failure tests.

### DOC-AI-03 — Review, edit, select, and bulk confirm

The chat-style flow exposes upload/analysis/result states and batch review with
select all/none, individual select/edit/exclude, course/date/time/type changes,
evidence/warnings, double-submit prevention, bulk confirmation, exact success/fail
counts, and safe retry. The mandatory scenario finds three candidates, excludes
one, edits one, and confirms two without duplicates.

Acceptance evidence: controller/store/widget tests, restart/offline cache tests,
and Android end-to-end flow using a synthetic document.

### DOC-AI-04 — Security, RLS, dedupe, and deletion

Provider calls occur only in an authenticated Edge/server boundary via an
extractor interface. The production adapter is fail-closed without a server secret;
CI uses an explicitly composed deterministic fake. Strict validation, sanitization,
no URL/tool execution, rate/timeout/count limits, content hash, source and candidate
fingerprints, idempotent confirmation, owner generation/account isolation, retry,
retention, and source/candidate deletion are required. Confirmed user entities are
retained according to the documented deletion policy.

Acceptance evidence: append-only migration, grants/RLS/RPC pgTAP, A/B isolation,
replay/idempotency, partial-failure/retry, deletion/retention, Edge format/lint/
typecheck/tests, and client-secret scan.

### PORT-01 — Recruiter README

README leads with a short English summary and Japanese value proposition, then
documents real flows, implemented/external/unimplemented status, architecture and
trust-boundary diagrams, stack, security, tests/CI, verified local/demo/Supabase/
Android setup, environment variables, screenshots/video, roadmap, and portfolio
engineering decisions without overstating evidence.

Acceptance evidence: link checker, command verification, and implementation-status
cross-check against traceability.

### PORT-02 — Screenshots

Repository-owned, consistently framed, compressed PNGs show Today, timetable,
assignments, alarm settings, alarm notification/stop, document upload, batch review,
and dark/alternate width. They contain only coherent synthetic data, no debug
banner, real identity, real email, or real class document.

Acceptance evidence: capture script, file/dimension/size inventory, and visual
privacy review.

### PORT-03 — Demo video

A 60–90 second synthetic Android emulator demo covers Today, timetable, alarm,
document analysis/review/bulk confirmation, and resulting assignments. Target is
under 25 MB and always under 100 MB. If local tooling prevents generation, the
repository still contains an executable recording script, deterministic seed/reset
instructions, storyboard, screenshots, and an exact external blocker record.

Acceptance evidence: MP4 metadata/privacy review or the documented reproducible
fallback bundle.

### CI-01 — Local verification script

`scripts/verify_portfolio.ps1` performs environment checks and available shared,
Flutter/codegen/UI/accessibility/APK, local Supabase/migration/lint/pgTAP/public-
client, Edge, admin, workflow/script, secret, diff, and optional Android E2E gates.
It emits a clear summary and returns non-zero for product failures while separately
classifying genuine external-only checks.

Acceptance evidence: PowerShell syntax/run evidence and deliberate failure-path
test.

### CI-02 — GitHub Actions

PR CI retains or strengthens hygiene/secret, shared Dart, Flutter analysis/tests/
codegen, Android APK, Supabase reset/lint/pgTAP/public-client, Edge, admin, UI/
accessibility, artifact, and coverage gates. Required jobs do not use
`continue-on-error`; expensive Android E2E may be manual/scheduled if documented.

Acceptance evidence: actionlint/YAML validation, local-equivalent gates, and exact-
head run URL/status. Billing-blocked runs remain `REMOTE_CI_BLOCKED`, never green.

## Traceability rule

Implementation paths, focused tests, Android evidence, migration names, commit IDs,
and final states for these IDs are maintained in `docs/MVP_TRACEABILITY.md`,
`docs/PROJECT_STATE.md`, and `docs/TESTING.md` as work is completed.
