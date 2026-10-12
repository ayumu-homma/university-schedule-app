# ADR 0004: Android morning alarm boundary

- Status: Accepted for Portfolio v0.5
- Date: 2026-08-10
- Requirements: ALARM-01, ALARM-02, ALARM-03, TODAY-02

## Context

The morning check is a user-configured alarm, not a server push and not an
in-process timer. It must remain useful after normal process death, survive
restart and clock changes, keep accounts isolated on a shared device, and open
the single production Today destination. Android 12+ makes exact alarms a
revocable special access; Android 13+ makes notifications a runtime permission;
Android 14+ can separately deny full-screen intents. Treating any of these
capabilities as unconditional would silently drop the feature or crash it.

Android's alarm guidance says to check `canScheduleExactAlarms()` before an exact
API and to reschedule after the exact-alarm access broadcast. Android's urgent
notification guidance reserves full-screen intents for explicit calls and
alarms, and otherwise presents a heads-up notification. Those constraints are
part of the feature contract, not exceptional cases.

Primary references:

- [Schedule alarms](https://developer.android.com/develop/background-work/services/alarms)
- [Notification runtime permission](https://developer.android.com/develop/ui/views/notifications/notification-permission)
- [Urgent/full-screen notifications](https://developer.android.com/develop/ui/views/notifications/build-notification#urgent-message)
- [Android 14 full-screen intent limits](https://developer.android.com/about/versions/14/behavior-changes-14#secure-fsi-notifications)

## Decision

### Contract and ownership

- Flutter owns settings UX and a strict, versioned MethodChannel contract.
- Native Android owns durable settings, `AlarmManager`, notification channels,
  action receivers, restart reconciliation, and the lock-screen activity.
- The raw authenticated user ID crosses the in-process channel only. Android
  persists a SHA-256 owner namespace, never the raw ID. One owner is active at a
  time.
- Activating another owner or `null` first cancels every regular, snoozed, and
  debug alarm plus the visible alarm notification. Per-owner preferences remain
  namespaced for a later legitimate sign-in.
- The app boundary must watch `morningAlarmOwnershipRuntimeProvider`; this makes
  sign-out/account changes cancel native work even if the settings screen was
  not opened in the current process.

### Scheduling and fallbacks

- Settings default to OFF. Enabling requires at least one weekday and an
  explicit notification-permission explanation.
- Wall-clock recurrence is fixed to `Asia/Tokyo`, matching the rest of the
  schedule domain. Every alarm is calculated from persisted hour/weekdays; a
  chain of elapsed-delay alarms is not authoritative.
- With exact access, the scheduler uses `setAlarmClock`, appropriate for a
  visible alarm explicitly configured by the user.
- Without exact access, it uses `setAndAllowWhileIdle`. Delivery may be deferred,
  and the Flutter UI labels it as an approximate-time fallback.
- `BOOT_COMPLETED`, `DATE_CHANGED`, `TIME_SET`, `TIMEZONE_CHANGED`,
  `MY_PACKAGE_REPLACED`/`PACKAGE_REPLACED`, and exact-alarm permission changes
  cancel stale pending intents and recompute the next occurrence.

### Presentation and actions

- Four immutable notification channels cover sound/vibration combinations.
  Changing the setting selects a different channel. The app never reads or
  changes global device volume.
- Notifications contain no class, assignment, exam, or account details. Privacy
  mode additionally uses secret lock-screen visibility.
- When full-screen intent access is present, a generic native ringing Activity
  exposes 56 dp Stop, Snooze, and Today actions. When unavailable, the same
  actions remain on an ongoing high-priority alarm notification.
- Stop and Snooze are owner-validated and idempotent. Snooze uses one replaceable
  pending intent. A regular fire immediately schedules the next recurrence.
- Today and the optional stop-and-open behavior run only from a user-tapped
  `PendingIntent`; no broadcast receiver performs a policy-bypassing background
  Activity launch.
- Warm and cold starts use exactly
  `unischedule://today?source=morning-alarm`, which the normal deep-link
  allowlist maps to the existing `/today` route.

### Debug hook

The near-time test method is accepted only when Android marks the application
debuggable and constrains the delay to 5–60 seconds. It does not enable or alter
the persisted regular schedule.

## Consequences

- The feature works without Supabase, network access, FCM, or a running Flutter
  isolate.
- Exactness, notification visibility, DND behavior, channel sound, and
  full-screen presentation remain partly user/OEM controlled. The UI reports
  capabilities but never claims guaranteed delivery.
- A normal process-kill test is meaningful; Android force-stop puts the package
  into a stopped state and is intentionally not used as proof that alarms fire.
- Physical-device/OEM, DND, reboot, and store-policy checks remain explicit
  release gates in the manual test runbook.

## Rejected alternatives

- `Timer`/background Flutter isolate: cannot provide process-independent
  delivery and restart recovery.
- FCM as the alarm clock: adds network/server dependency and cannot guarantee a
  user-selected local wall-clock time.
- `USE_EXACT_ALARM`: broader auto-granted access and store-policy burden are not
  justified for an optional morning-check feature. Revocable
  `SCHEDULE_EXACT_ALARM` is used with a visible fallback.
- Starting `MainActivity` directly from a receiver: violates modern background
  launch expectations. Only explicit user PendingIntents open Today.
- Mutating `AudioManager` volume: surprising, privacy-hostile, and outside app
  ownership.
