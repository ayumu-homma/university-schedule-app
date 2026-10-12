# Android physical-device acceptance

This gate is intentionally deferred until a person has approved physical-device
operation. It is not part of an unattended local or hosted-runner verification
run. Use synthetic university data with the isolated Android `staging` flavor
only. Its package is `jp.universityschedule.app.staging`, label is
`Uni Schedule (Staging)`, and custom scheme is `unischedule-staging`.
Production, personal accounts, real schedules, API-key entry, store publishing,
and remote deployment are outside this procedure.

## Automated preflight (no device mutation)

Run the mock contract without a device:

```powershell
pwsh ./scripts/test_android_physical_acceptance_contract.ps1
```

Before any device operation, prepare the ignored staging configuration through
the separately approved credential process. From `apps/mobile`, the exact
staging-flavor build is:

```powershell
flutter pub get
flutter build apk --debug --flavor staging `
  --dart-define-from-file=.env.staging.json
```

The expected artifact is
`build/app/outputs/flutter-apk/app-staging-debug.apk`. The input must bind
`APP_ENV=staging`, `APP_DEMO_MODE=false`,
`APP_DEEP_LINK_SCHEME=unischedule-staging`, the reviewed staging project
URL/ref, a public staging client key, and approved public HTTPS URLs. Do not run
this credentialed build merely to satisfy the repository-only contract test.

Before installation, record the artifact identity without exposing its
configuration:

```powershell
Get-FileHash -Algorithm SHA256 `
  build/app/outputs/flutter-apk/app-staging-debug.apk
apksigner verify --print-certs `
  build/app/outputs/flutter-apk/app-staging-debug.apk
```

After the external-mutation checkpoint has been approved, connect exactly one
physical Android device, authorize USB debugging, install that reviewed
artifact by the separately approved process, and run:

```powershell
pwsh ./scripts/run_android_physical_acceptance.ps1 `
  -TargetEnvironment debug `
  -BuildSha <40-hex-source-sha> `
  -OutputDirectory <approved-evidence-directory>
```

`-TargetEnvironment` accepts only `debug` or `staging`; both values still target
the isolated `jp.universityschedule.app.staging` package. `debug` additionally
requires Android to report the installed staging-flavor package as debuggable.
The preflight rejects any `-PackageName` override to the production package,
zero devices, multiple devices, unauthorized/offline devices, emulators, and a
missing staging package.

The preflight performs read-only inventory only. It does not install or launch the
app, clear app data, change time or timezone, change permissions or app-ops,
change battery optimization, enable accessibility services, reboot, force-stop,
capture logcat, or read notification contents. It reads only:

- `adb devices -l` and `get-state`;
- non-unique build properties needed to reject emulators and describe the test
  matrix;
- automatic-timezone status;
- package path and bounded package metadata;
- a temporary local pull of the installed `base.apk`, used only for SHA-256 and
  `apksigner verify --print-certs`, then deleted;
- battery-optimization exemption and three relevant app-op observations.

The JSON evidence stores a SHA-256 hash of the adb serial and a SHA-256 hash of
the Android build fingerprint. It never stores the raw serial, raw fingerprint,
or raw adb output. Manufacturer/model identify a device class, not a device
instance. Do not add IMEI, Android ID, account names, Wi-Fi details, screenshots
containing notifications, raw logs, or real schedule content to the evidence.

`declaredBuildSha` is caller-supplied provenance and the harness deliberately
records `sourceShaVerified=false`; a source SHA cannot prove which APK is
installed. The independent installed-artifact evidence is
`app.baseApkSha256` plus
`app.signingCertificateSha256Digests`, derived from the pulled `base.apk` with
`apksigner`. For a direct single-APK install, the human reviewer must compare
those fields with the pre-install APK hash/certificate above. For Play-generated
split APKs, retain hashes and certificate digests for the whole installed set
and do not compare an APK hash to the AAB hash.

`INVENTORY_READY` means only that the device and installed artifact passed the
read-only inventory. It does not establish source-SHA binding or a product
acceptance result. Every manual item remains `MANUAL REQUIRED`; the script never
converts absence of a device observation into PASS. Record human observations
and the artifact comparison in a separate review record and retain the generated
JSON unchanged.

## External-mutation checkpoint

Before touching a physical device, record and obtain human approval for:

1. exact device class, Android/API level, declared source SHA, staging package,
   pre-install APK SHA-256/certificate, and debug/staging evidence label;
2. the exact install, launch, permission/settings, reboot, and cleanup actions;
3. possible device-state, notification, availability, privacy, and cost impact;
4. verification plus rollback/restore steps;
5. confirmation that only synthetic data and a disposable test account are used.

The person running the test owns all device actions below. The repository script
does not perform them.

## Manual matrix

Record the observed time and a privacy-safe evidence reference for every row.
Leave an unobserved row as `MANUAL REQUIRED`; use `BLOCKED` rather than inferring
success. Do not use Android force-stop as proof that an alarm survives ordinary
process death: force-stop intentionally places the package in a stopped state.

| ID | Human observation | Acceptance |
|---|---|---|
| environment-marker | Open the app and confirm the intended debug/staging identity and synthetic account | No production identity, endpoint, or personal content is present |
| cold-launch | Cold-launch through the normal launcher | App reaches its normal authenticated or sign-in state without crash |
| today-display | Open Today with known synthetic fixtures | Expected classes, assignments, and exams are readable and private details do not appear on the lock screen |
| alarm-settings-save | Enable the morning alarm, select time/weekdays/options, leave and return | The chosen state and truthful capability labels persist |
| alarm-fire | Background or swipe away the task normally and wait for the configured time | One alarm is presented; app process presence is not required |
| lock-screen | Observe the alarm while locked | Generic text only; no schedule, class, account, or friend detail leaks |
| stop | Use Stop once | Ringing and the active notification stop without a duplicate |
| snooze | Trigger again and use Snooze once | One snoozed occurrence is presented at the selected interval |
| today-navigation | Use Today from the alarm surface | The standard Today destination opens through the normal deep link |
| exact-alarm-fallback | Deny exact-alarm access through system UI, then save/observe | UI reports approximate timing and the notification fallback remains usable |
| full-screen-fallback | Deny full-screen access through system UI | A high-priority notification still exposes Stop, Snooze, and Today |
| notification-permission | Deny then grant notification permission through system UI | Value explanation precedes the request; denial remains truthful and recoverable |
| timezone-recalculation | Change timezone through system UI according to the approved plan | Next occurrence is recomputed for the documented Japan-time contract |
| date-recalculation | Change date/time through system UI according to the approved plan | Stale work is replaced by one recomputed occurrence |
| package-update-reschedule | Install the approved newer build while retaining app data | Settings survive and exactly one next occurrence is restored |
| reboot-reschedule | Reboot through normal device UI | Settings survive and exactly one next occurrence is restored after boot |
| battery-optimization-enabled | Test with normal optimization | Record OEM delivery behavior without claiming a universal guarantee |
| battery-optimization-exempt | If explicitly approved, exempt the app through system UI and repeat | Record the difference; restore the original setting afterward |
| talkback | Complete the linked TalkBack run | Every required screen has a human verdict and evidence reference |

Use [ACCESSIBILITY_ANDROID.md](ACCESSIBILITY_ANDROID.md) for TalkBack and layout
acceptance. Android/OEM exactness, DND, sound-channel behavior, reboot delivery,
full-screen policy, and physical notification presentation remain human evidence;
unit/widget/emulator success cannot replace them.

## Closeout

- Restore timezone, automatic-time, permissions, full-screen/exact-alarm access,
  battery optimization, DND, accessibility services, and notification settings
  to their recorded original values.
- Remove only the synthetic test account/data using normal app or system UI under
  the approved cleanup plan. Do not use repository cleanup scripts on the device.
- Keep the app uninstalled only if that was part of the approved rollback.
- Store the unchanged JSON inventory and human review record in the approved
  release-evidence location. Do not commit device evidence to the repository.
