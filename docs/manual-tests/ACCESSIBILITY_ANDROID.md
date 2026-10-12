# Android accessibility acceptance

Automated Flutter tests reduce regressions, but they do not prove TalkBack,
Android accessibility-service focus, OEM notification announcements, or physical
orientation behavior. Those remain `MANUAL REQUIRED` until a person performs the
run on the approved debug/staging device with synthetic data.

## Automated baseline

The focused repository checks cover semantic names for important controls,
live-region errors/loading, compact 2x text, dark theme, landscape layout, and
minimum Material control sizing where deterministic widget tests can observe it:

```powershell
Push-Location apps/mobile
flutter test test/notification_settings_screen_test.dart
flutter test test/document_import_chat_screen_test.dart
flutter test test/assignment_list_screen_test.dart
Pop-Location
```

These checks are necessary but do not change any manual row to PASS. Native alarm
surfaces, Android widgets, real font rendering, switch-access/keyboard behavior,
and OEM TalkBack behavior still require a physical observation.

## Safety and setup

1. Complete the external-mutation checkpoint in
   [ANDROID_PHYSICAL_ACCEPTANCE.md](ANDROID_PHYSICAL_ACCEPTANCE.md).
2. Use only a human-approved debug or staging build and a disposable synthetic
   account. Record the exact 40-character source SHA.
3. Enable TalkBack through the device's normal Accessibility settings. Do not use
   adb or an automated script to enable, disable, or reconfigure an accessibility
   service.
4. Record manufacturer/model, Android/API level, display size, font scale, theme,
   orientation, and the SHA-256 build-fingerprint hash. Never record a raw serial,
   Android ID, account identity, notification body, or personal schedule.
5. Copy [templates/TALKBACK_EVIDENCE.md](templates/TALKBACK_EVIDENCE.md) to the
   approved external evidence location. Do not commit the completed device record.

## Required configurations

Run the screen matrix in the following configurations. If a device cannot provide
one, record `BLOCKED` with the reason; do not infer PASS from a widget test.

| Configuration | Required observation |
|---|---|
| Default portrait | TalkBack traversal, role, name, state, actions, focus after navigation |
| 200% font / largest practical display text | No clipped essential text, unreachable action, or unscrollable dialog |
| Landscape | Content and primary actions remain reachable; focus order follows reading order |
| Dark theme | Text/status contrast and disabled/focused state remain distinguishable without color alone |
| Alarm while unlocked and locked | Generic privacy text, predictable action order, Stop/Snooze/Today labels |

Do not take screenshots on the lock screen unless the evidence plan explicitly
allows them and the screen contains synthetic generic content only.

## Screen matrix

For each row, swipe forward and backward through every actionable element, invoke
the primary path, then return through the normal navigation path.

| Screen/surface | Required TalkBack and layout checks |
|---|---|
| Today | Page heading announced once; schedule sections and empty/loading states are meaningful; cards do not repeat decorative icons |
| Timetable day/week | Day, period, time, course, room, empty cell, edit/open actions are understandable without visual position alone |
| Assignments | Filter names/states are announced; each edit action includes the assignment title; status changes and failures are announced |
| Exams | Exam name is present in open/edit actions; nested controls do not create confusing duplicate actions |
| Calendar | View selector exposes selected state; month/week/day content remains navigable at 200% and landscape |
| Morning-alarm settings | Heading, loading/error states, switches, selected weekdays, time, capability label/value, and permission explanations are announced |
| Native ringing activity | Title and privacy message precede Stop, Snooze, Today; all actions are reachable in both orientations and with large text |
| Alarm notification/lock screen | Generic content only; Stop, Snooze, Today have distinct names and predictable order |
| Document import/review | Upload purpose/type/limit, candidate include state, item-specific edit action, validation live-region, retry, and confirm count are announced |
| Settings/account | Environment identity, policy/support links, destructive account action, confirmation, loading, success/failure have explicit names and state |
| Android home-screen widget | Day/period/course/room and destination are understandable; empty cells are not noisy; tap targets are practical on supported widget sizes |

## Human verdict rules

- `PASS`: a person observed the expected behavior in the named configuration and
  attached a privacy-safe reference.
- `FAIL`: the person reproduced a defect; include concise steps and expected versus
  observed behavior, without raw logs or personal data.
- `BLOCKED`: the required configuration or device state could not be reached.
- `MANUAL REQUIRED`: not yet observed. This is the default and is never promoted
  by widget, emulator, or inventory scripts.

After the run, restore TalkBack, font/display scale, theme, orientation lock, and
all alarm/device settings to their recorded original values.
