# 検証範囲と再現手順

2026-10-12の公開用クリーンコピーを対象にした検証です。公開の対象はv1.0.0タグとそのCIで特定します。各テストの生ログ、入力hash、時刻、終了コードは非公開で保全し、ここには安全な要約を掲載します。

## 今回の必須と結果

実行前に必須と別途検証を分類しました。依存取得・生成、静的解析・format、通常Flutter unit/widget、共通domain、Android local/demo buildと可能なJVM/起動、管理画面lint/test/build、Edge、使い捨て環境のSQL/権限、安全監査を必須としています。

- PASS：Flutter 3.44.4 / Dart 3.12.2、lockfile準拠の依存取得、Drift生成、format、fatal infos/warningsを有効にした全体analyze。
- PASS：通常Flutter unit/widgetは135ファイル、811成功・3スキップ。保持DBのschema18 fixtureを必要とする2ケースと、過去の保存領域snapshotを必要とする1ケースは、fixture非配布のため既存の条件どおりskip。24件の接続fixtureファイルは別スイートとしてソースを維持。
- PASS：shared_domainは91成功、format/analyze、lockfile準拠の依存取得。
- PASS：管理画面のnpm ci、lint、Next.js build、既存6ファイルの14テスト（13 unit + 1合成HTTP）。HTTPは専用loopbackサーバーに架空の公開文面を渡して検証し、プロセスを終了します。WindowsローカルはNode24.15.0、CIはNode22。
- PASS：Deno2.9.7によるEdge format/lint/checkと168テスト。実サービス接続の成功ではありません。
- PASS：配備ガード・migration計画・資料AI smoke入口・物理Android入口の契約テスト。実配備・実AI・実機の成功ではありません。
- PASS：Android local/demo APK（1.0.0+1）を生成。JVM/Robolectric68件成功・failure/error/skip0。新規専用API36 AVDにインストールし、合成Auth、Home/Today、時間割の日/週表示、課題、提出済みを記録する導線、再起動後の表示を確認。物理端末や接続E2Eとは別です。
- ENV_BLOCKED（ローカル）：Docker engineが停止しているためSQL入口を実行していません。GitHub-hosted専用入口にローカル環境変数を偽装せず、新規Public CI DBでmigration・SQL・権限を検証します。
- PENDING：公開候補の無料CIと未認証読み戻し。

## 管理画面の依存監査

修正版のあるNext.js15.5.27、sharp0.35.5、source-map-js1.2.2へ限定して更新し、lockfileを固定しました。lint・既存テスト・buildを再検証しています。

`npm audit --audit-level=high`は**FAIL**です。残る5件のHigh表示は[GHSA-vfj7-8cjw-p6xm](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm)に起因する開発用の依存経路（eslint-config-next → @next/eslint-plugin-next → fast-glob → micromatch → braces3.0.3）です。2026-10-12時点で修正版がありません。npmが提案する強制ダウングレードは採用していません。

補助検証の`npm audit --omit=dev --audit-level=high`は**PASS、0 vulnerabilities**。production依存グラフとNextのserver output traceにはbraces/micromatch/fast-globがありません。pluginの唯一のfast-glob呼び出しは`settings.next.rootDir`を扱いますが、リポジトリの固定ESLint設定にはその設定がなく、既定のcwdを使います。アプリのAPI/フォーム入力はlintへ渡しません。

この未修正依存を含む設定を未審査PRから自動実行しないよう、公開CIの入口はmainへのpushと手動dispatchです。すべての通常検証を保持し、full auditは独立したFAILのジョブで報告します。全CI greenやfull audit合格を主張しません。次の依存変更、upstream修正版、lint rootDir変更、外部PR自動実行の再導入時に再評価します。本番Webホストとしての受入は対象外です。

## 再現コマンド

リポジトリ直下からPowerShellで実行します。Python3、Flutter/Dart、JDK21、Android SDK、Nodeを用意してください。

```powershell
Set-Location packages/shared_domain
dart pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
dart analyze
dart test
Set-Location ../../apps/mobile
flutter pub get --enforce-lockfile
dart run build_runner build --delete-conflicting-outputs
dart format --output=none --set-exit-if-changed lib test tool_tests integration_test
flutter analyze --fatal-infos --fatal-warnings
python ../../scripts/run_flutter_local_tests.py --list
python ../../scripts/run_flutter_local_tests.py --coverage
flutter build apk --flavor staging --debug `
  --dart-define=APP_ENV=local `
  --dart-define=APP_DEMO_MODE=true `
  --dart-define=APP_DEEP_LINK_SCHEME=unischedule-staging
Set-Location android
./gradlew.bat :app:testStagingDebugUnitTest --no-daemon
Set-Location ../../admin
npm ci
npm run lint
npm run build
node scripts/run-local-tests.mjs
npm audit --omit=dev --audit-level=high
npm audit --audit-level=high
```

最後のfull auditは上記の既知dev依存により非ゼロで終了します。成功したと読み替えないでください。通常のまとめ入口`./scripts/verify_portfolio.ps1`も同じ失敗を返します。`-SkipAndroid`を明示した場合、AndroidはNOT_RUNと表示し受入を主張しません。

EdgeはDeno2.9.7を使用します。

```powershell
deno fmt --check supabase/functions/university-email-verification supabase/functions/email-import supabase/functions/document-import supabase/functions/notification-dispatcher
deno lint supabase/functions/email-import supabase/functions/document-import
deno check supabase/functions/university-email-verification/index.ts supabase/functions/email-import/index.ts supabase/functions/document-import/index.ts supabase/functions/notification-dispatcher/index.ts
deno test --allow-env supabase/functions/university-email-verification supabase/functions/email-import supabase/functions/document-import supabase/functions/notification-dispatcher
```

SQLの`scripts/run_supabase_sql_ci.sh`は新規GitHub-hosted DB専用です。migration適用、privileges-only検査、upgrade、lint、pgTAP、実COMMIT assertionをCIで実行します。保持DBへのreset/migrationは通常手順に含めません。接続Android E2Eは[手動workflow](../.github/workflows/connected-e2e.yml)に残し、自動・通常受入とは区別します。

通常runnerはSQLite待機を検証するため`--enable-vmservice`を使います。合成一時DBをPython別プロセスでロックし、待機と解放後の完了を確認します。Linuxの待機2ケースだけCPU profilerを一時停止して復元する既存の処理を維持します。端末OSの配送や既存DB受入ではありません。

## 過去の証拠と別途検証

2026-09-29開発版：Flutter802成功・1スキップ、共通domain91成功、Android JVM68成功。2026-09-30：時間割UIの限定8テスト、APK起動・撮影。これらは当時の入力と環境の記録で、今回の必須テスト成功には代用していません。

NOT_RUN / 未受入：Android接続E2E、物理Android/OEM、iOS/macOS、ホスト型Supabase/Auth/SMTP/OAuth、実AI、実FCM/APNs、production署名、本番運用・ストア受入。資料デモはfake adapterです。秘密スキャンやコマンド成功だけで安全性・全製品完成を断定しません。
