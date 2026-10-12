# University Schedule Mobile

Flutter Android/iOS client for the university schedule application. Android is the first internal-test target.

```powershell
flutter pub get
dart run build_runner build
flutter analyze --fatal-infos --fatal-warnings
python ../../scripts/run_flutter_local_tests.py --coverage
flutter build apk --debug --flavor staging `
  --dart-define=APP_ENV=local `
  --dart-define=APP_DEMO_MODE=true `
  --dart-define=APP_DEEP_LINK_SCHEME=unischedule-staging
```

Runtime configuration is supplied with `--dart-define`. Production and staging runs must set an explicit environment and Supabase client values and must not enable demo mode. Secrets, service-role keys, OAuth tokens, and signing material never belong in this directory.

Demo mode is opt-in and is accepted only for local/test builds:

```powershell
flutter run --flavor staging `
  --dart-define=APP_ENV=local `
  --dart-define=APP_DEMO_MODE=true `
  --dart-define=APP_DEEP_LINK_SCHEME=unischedule-staging
```

Android always uses an explicit native flavor. Local, test, and staging runs
use `staging`; production uses `production`. The mappings are:

| Android flavor | Package | Label | Custom scheme |
| --- | --- | --- | --- |
| `staging` | `jp.universityschedule.app.staging` | `Uni Schedule (Staging)` | `unischedule-staging` |
| `production` | `jp.universityschedule.app` | `Uni Schedule` | `unischedule` |

The app fails closed when the native flavor, `APP_ENV`, and
`APP_DEEP_LINK_SCHEME` disagree. A flavorless Android command is not a supported
deployed build.

For a local Supabase stack from the Android emulator, use the emulator host
alias rather than `127.0.0.1`:

```powershell
flutter run --flavor staging `
  --dart-define=APP_ENV=local `
  --dart-define=APP_DEMO_MODE=false `
  --dart-define=APP_DEEP_LINK_SCHEME=unischedule-staging `
  --dart-define=SUPABASE_URL=http://10.0.2.2:54321 `
  --dart-define=SUPABASE_PUBLISHABLE_KEY=replace-with-local-client-key `
  --dart-define=APP_WEB_BASE_URL=http://10.0.2.2:3000
```

`SUPABASE_ANON_KEY` remains a compatibility input for the local CLI's legacy
client key. Prefer `SUPABASE_PUBLISHABLE_KEY`. The bootstrap rejects modern
secret keys and legacy JWTs carrying the `service_role` claim.

## Staging and production configuration

Each deployed configuration requires the selected environment's project ref;
the unselected ref may be empty. If both refs are supplied, they must be
distinct. `SUPABASE_URL` must be the exact selected
`https://<project-ref>.supabase.co` origin without a custom port, and the client
key must be an `sb_publishable_` key or a legacy JWT whose role is exactly
`anon`. Policy/deletion/support URLs must be explicit public HTTPS URLs; the
app does not invent routes from the web base URL.

- `APP_ENV` (`staging` or `production`)
- `APP_DEMO_MODE=false`
- `APP_DEEP_LINK_SCHEME` (`unischedule-staging` or `unischedule` as mapped
  above)
- `STAGING_SUPABASE_PROJECT_REF` when `APP_ENV=staging`
- `PRODUCTION_SUPABASE_PROJECT_REF` when `APP_ENV=production`
- `SUPABASE_URL`
- `SUPABASE_PUBLISHABLE_KEY` (preferred) or `SUPABASE_ANON_KEY`
- `APP_WEB_BASE_URL`
- `APP_PRIVACY_POLICY_URL`
- `APP_TERMS_URL`
- `APP_ACCOUNT_DELETION_URL`
- `APP_SUPPORT_URL`
- reviewed feature flags such as `EMAIL_IMPORT_ENABLED` and
  `DOCUMENT_IMPORT_ENABLED`
- `EMAIL_IMPORT_GMAIL_CLIENT_ID` when Email import is enabled; this is a public
  mobile OAuth client identifier, never the OAuth client secret

Keep the approved values in an ignored, access-controlled file such as
`.env.staging.json`, then use Flutter's file input so values are not copied into
the shell command or history:

```json
{
  "APP_ENV": "staging",
  "APP_DEMO_MODE": "false",
  "APP_DEEP_LINK_SCHEME": "unischedule-staging",
  "STAGING_SUPABASE_PROJECT_REF": "REVIEWED_20_CHARACTER_REF",
  "PRODUCTION_SUPABASE_PROJECT_REF": "",
  "SUPABASE_URL": "https://REVIEWED_STAGING_REF.supabase.co",
  "SUPABASE_PUBLISHABLE_KEY": "INJECT_FROM_APPROVED_BUILD_ENVIRONMENT",
  "APP_WEB_BASE_URL": "https://REVIEWED_WEB_HOST",
  "APP_PRIVACY_POLICY_URL": "https://REVIEWED_POLICY_URL",
  "APP_TERMS_URL": "https://REVIEWED_TERMS_URL",
  "APP_ACCOUNT_DELETION_URL": "https://REVIEWED_DELETION_URL",
  "APP_SUPPORT_URL": "https://REVIEWED_SUPPORT_URL",
  "EMAIL_IMPORT_ENABLED": "false",
  "DOCUMENT_IMPORT_ENABLED": "false"
}
```

```powershell
flutter run --flavor staging `
  --dart-define-from-file=.env.staging.json
flutter build apk --debug --flavor staging `
  --dart-define-from-file=.env.staging.json
```

The staging debug APK is
`build/app/outputs/flutter-apk/app-staging-debug.apk`. Physical-device use,
staging client-key entry, and live-provider testing remain separate approved
external checkpoints; building or running the mock contract does not prove
them.

The example names are deliberately invalid placeholders. Do not commit the
resolved file, provider keys, service-role/secret keys, OAuth tokens, or signing
material. A production release additionally requires `APP_ENV=production`,
`APP_DEEP_LINK_SCHEME=unischedule`, release mode, the `production` flavor, and
the production URL/ref binding; demo mode remains rejected. After external
signing and configuration approval, the exact Android command is:

```powershell
.\tool\build_android_production_release.ps1 `
  -ConfigFile .env.production.json -Build
```

The release wrapper validates the selected production configuration and
requires the ignored `android/key.properties` before starting Flutter. It does
not print configuration or signing values. Omit `-Build` to run the preflight
without launching Flutter.

The expected production AAB is
`build/app/outputs/bundle/productionRelease/app-production-release.aab`.
No signed production build or store upload is claimed by this README.
