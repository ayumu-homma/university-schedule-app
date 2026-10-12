# Morning Alarm Android Manual Test

Use synthetic demo data and the isolated Android `staging` flavor debug APK
only. Its package is `jp.universityschedule.app.staging`, custom scheme is
`unischedule-staging`, and artifact is
`apps/mobile/build/app/outputs/flutter-apk/app-staging-debug.apk`. Record Android
version, device or emulator model, build SHA, notification/exact/full-screen
capability state, and the result of every row. Do not use `am force-stop`:
Android intentionally marks force-stopped packages as stopped. Use a normal
swipe-away or `am kill` after the app is backgrounded to exercise process
absence.

## Preconditions

1. From `apps/mobile`, build with
   `flutter build apk --debug --flavor staging --dart-define=APP_ENV=local --dart-define=APP_DEMO_MODE=true --dart-define=APP_DEEP_LINK_SCHEME=unischedule-staging`.
   Install the staging debug APK with retained state:
   `adb install -r build/app/outputs/flutter-apk/app-staging-debug.apk`.
2. Launch the app, sign in to the synthetic account, complete onboarding, and
   open Settings > Notifications.
3. Confirm Morning check is initially OFF and no next alarm appears in
   `adb shell dumpsys alarm | Select-String universityschedule`.
4. Grant notification access only after the in-app explanation.

## Core flow

| Step | Action | Expected |
|---|---|---|
| 1 | Set a weekday/time, sound, vibration, 10-minute snooze, open-Today, and privacy; enable | Values survive leaving/reopening the screen; next JST occurrence is shown |
| 2 | In debug, tap the 10-second test and background the app | One alarm appears; no schedule detail or identity is on the lock screen |
| 3 | Tap Snooze | Notification/ringing UI closes and one snooze alarm is registered |
| 4 | For a practical run, temporarily use the debug hook with a shortened test snooze build or wait ten minutes | Alarm appears again once; repeated Snooze taps do not create duplicates |
| 5 | Tap Stop | Alarm UI and notification close; the next regular selected-day alarm remains |
| 6 | Trigger another debug alarm, swipe the app away (or background then `adb shell am kill jp.universityschedule.app.staging`), and tap Today | Cold start opens the authenticated `/today` screen through `unischedule-staging://today?source=morning-alarm` |
| 7 | Repeat while the app is warm | The existing task navigates to the same `/today` destination, without duplicate routes |

## Permissions and fallbacks

1. Deny `POST_NOTIFICATIONS`, return to the app, and refresh the screen. The UI
   must say notification permission is needed and must not silently enable a
   new schedule.
2. On Android 12+, revoke Alarms & reminders. Reopen the app. The UI must show
   approximate timing and a regular/inexact alarm must remain in `dumpsys alarm`.
3. Grant Alarms & reminders from the app-provided settings action. On resume,
   the next schedule must be recomputed as an exact alarm.
4. On Android 14+, deny full-screen alarm access. The alarm must remain actionable
   as a high-priority notification. Grant it and verify the lock-screen ringing
   Activity on the next test.
5. Enable DND and document actual OEM behavior; the app must not change media,
   ring, notification, or alarm volume.

## Lifecycle and owner isolation

For each broadcast, note the next trigger before and after and confirm exactly
one recomputed regular alarm:

- reboot (`BOOT_COMPLETED`) on a physical or reboot-capable emulator;
- manual clock change (`TIME_SET`/`DATE_CHANGED`);
- device timezone change (`TIMEZONE_CHANGED`; wall time remains Asia/Tokyo);
- retained reinstall (`MY_PACKAGE_REPLACED`/`PACKAGE_REPLACED`);
- grant of exact-alarm special access.

Then enable an alarm as synthetic account A, sign out, and confirm all app alarms
and the active notification are canceled. Sign in as account B and confirm its
default is OFF. Switching back to A may restore A's namespaced preference, but
only the currently authenticated owner's alarm may be active.

## Evidence and fatal scan

Capture the settings, fallback, notification actions, snooze/refire, and Today
screens with synthetic data. After the run:

```powershell
adb logcat -d | Select-String -Pattern 'FATAL EXCEPTION|AndroidRuntime|Process: jp.universityschedule.app.staging'
adb shell dumpsys alarm | Select-String -Pattern 'universityschedule|MORNING_ALARM'
adb shell dumpsys notification --noredact | Select-String -Pattern 'morning_alarm'
```

Pass requires no app fatal, no account/class detail in notification evidence,
no duplicate PendingIntents, and an explicit result for OEM/DND/reboot behavior.
