# 開発環境とデモ起動

公開用環境確認日：2026-10-12。リポジトリ直下からのPowerShellを想定します。Flutter **3.44.4** / Dart **3.12.2**、Python 3、**実行用JDK 21**、Android SDKがローカル検証の基準です。管理画面CIはNode.js 22、今回のWindowsローカル検証はNode.js 24.15.0です。

## JDKとコンパイル対象

| 設定 | このプロジェクトの値 | 確認元 |
|---|---|---|
| CI・Gradleを実行するJDK | **21** | [CIのJava選択](../.github/workflows/ci.yml)。ローカルもTemurin 21.0.11とJava 21のGradle daemonで確認 |
| AndroidのJava/Kotlinコンパイル対象 | **17** | [Android appのcompileOptions / compilerOptions](../apps/mobile/android/app/build.gradle.kts) |

実行用JDKとコンパイル対象は別の設定です。READMEの環境案内もJDK 21に統一しています。API 36を対象にするRobolectricを含め、CIはJava 21を明示して使用します。Gradle wrapperは9.1.0、Android Gradle Pluginは9.0.1です。SDK構成はGradleで宣言しています。

## ネットワークサービス不要のlocal/demo

```powershell
Set-Location apps/mobile
flutter pub get --enforce-lockfile
dart run build_runner build --delete-conflicting-outputs
flutter analyze
python ../../scripts/run_flutter_local_tests.py --list
flutter build apk --flavor staging --debug `
  --dart-define=APP_ENV=local `
  --dart-define=APP_DEMO_MODE=true `
  --dart-define=APP_DEEP_LINK_SCHEME=unischedule-staging
```

依存物の取得にはネットワークを使います。デモの実行に実アカウント、Supabase、AI provider、`.env`は不要です。生成Dartコードは`build_runner`で作ります。Gradle wrapperと必要なassetsはリポジトリに含めています。lockfileに整合しない取得は停止します。

出力は`apps/mobile/build/app/outputs/flutter-apk/app-staging-debug.apk`です。`stagingDebug`はflavor/build typeで、この例の環境は`APP_ENV=local`です。公開staging接続を意味しません。

自分で用意・接続・許可したAndroid端末またはエミュレーターで起動する場合のみ、`<device-id>`を実際の対象に置き換えます。

```powershell
flutter run -d <device-id> --flavor staging `
  --dart-define=APP_ENV=local `
  --dart-define=APP_DEMO_MODE=true `
  --dart-define=APP_DEEP_LINK_SCHEME=unischedule-staging
```

起動後は`demo@example.test`などの合成メールで「メールで続ける」を選びます。local/demoはfake Authを使用し、メールを送信しません。データ削除や再インストールは通常手順に含みません。デモの資料抽出はdeterministic fakeで、実AI呼び出しではありません。

## 実バックエンドとの接続

管理者が用意した**使い捨ての開発用**Supabase環境と許可されたAuth principalが必要です。保持DBへのmigration適用や`db reset`を通常の起動手順として実行しないでください。バックアップ・適用承認は[配備準備](operations/SUPABASE_DEPLOYMENT_READINESS.md)で別途扱います。

- モバイルには`SUPABASE_URL`とpublishable/anon client keyのみを渡します。
- service_role/secret key、SMTP、OAuth secret、AI keyはモバイルや公開テンプレートへ置きません。
- Android Emulatorから許可済みのホスト側ローカルAPIへ接続する場合は`10.0.2.2`を使います。HTTPの例外はlocal/test限定です。
- staging/productionでは環境に一致するproject ref、HTTPS URL、ポリシー・削除・サポートURLが必要です。未決定のホストやplaceholderを本番値にしません。
- 本番入力は未設定です。不足時のfail-closed検査を回避しないでください。

変数とflavor対応は[モバイル設定](../apps/mobile/README.md)、空値テンプレートは[.env.example](../.env.example)を参照してください。公開ホスト名・実project ref・認証情報をこの手順は提供しません。

## 管理画面

リポジトリ直下から実行します。

```powershell
Set-Location apps/admin
npm ci
npm run lint
npm run build
node scripts/run-local-tests.mjs
npm run dev -- --hostname 127.0.0.1
```

`http://127.0.0.1:3000`はローカル開発用です。Auth接続、管理者権限、公開ポリシー・削除メール導線には別の環境設定が必要です。設定が不足した公開機能は停止します。

テストは[TESTING](TESTING.md)へ。通常ビルドに`work/`、個人用絶対パス、未追跡の`.env`は使いません。iOSにはmacOS/Xcodeと別のデバイス・署名環境が必要です。[iOS引継ぎ](IOS_IMPLEMENTATION_HANDOFF.md)
