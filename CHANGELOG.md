# Changelog

## Unreleased — 3D_EXPERIMENTAL

- Optional interactive geometric 2.5D personal-week view, using existing course, personal-event, exam and deadline models without viewer mutations; `APP_ENABLE_SPATIAL_WEEK=false` keeps it off by default.
- Same-data 2D comparison, orbit/zoom/reset, read-only selection, complete equivalent list and list-only fallback. No new package or engine dependency. Focused tests and synthetic API 36 emulator interactions passed.
- Source branch `codex/v1.2-spatial-week` retains the experiment. The package remains `1.1.0+2`; this is not a formal v1.2 release. Emulator frame/PSS diagnostics are recorded with limits; consistent performance and human benefit are unestablished. iOS/physical-device behavior remains unmeasured. Details are in [the experiment record](docs/SPATIAL_WEEK_EXPERIMENT.md) and [testing evidence](docs/TESTING.md#spatial-week-25d-source-experiment).

## 1.1.0 — Academic UI / Source Release

- Todayで現在・次の授業、時刻と教室、締切・テストへの操作を先に確認できる構成へ整理。空の項目を繰り返し表示せず、必要な追加操作を案内します。
- 日・週の時間割に、授業名・教室・時限・関連課題を完全に読める選択シートを追加。既存の詳細・編集・削除、空きコマへの登録は維持します。
- 課題とテストを明示的に切り替え、既存の期限・授業フィルタ、提出状態の記録、更新中・失敗表示・Undoを維持します。
- ニュートラルな明暗テーマ、幅を制限したタブレット表示とナビゲーション、48dp操作、文字拡大、OSの動きを減らす設定への対応。
- 公式資料のUX比較、編集可能な独自ワイヤーフレームとデザインシステム、追加の画面回帰テスト。
- アカウント・学期の切替で時間割の古い選択を解除し、提出完了の遅延通知を元の画面・文脈に限定。未設定・曜日別の時刻と、読み上げ操作の重複も修正。

v1.0.0のタグとReleaseは保全します。ソース公開とローカルデモの版であり、本番・ストア受入や未検証の性能向上を主張しません。[新しい検証結果と制限](docs/TESTING.md)を確認してください。

## 1.0.0 — Portfolio / Source Release

大学生向け時間割・課題・試験・予定管理アプリの、ソースとローカルデモを公開する版です。公開履歴はv1.0から管理します。

- Flutter / Riverpod / go_router、Drift / SQLiteによるローカル保存とoutbox同期。
- 授業テンプレコピー、課題の提出状態、試験、カレンダー、繰り返しと例外。
- Supabase Auth、PostgreSQLのRLS/RPCによる公開範囲、友だち・グループ、通報・ブロック。
- Android通知・朝アラーム・ウィジェット橋渡し、iOS WidgetKit連携コード、Next.js管理画面。
- 資料候補の確認・編集・登録。ローカルデモの抽出はfake adapter。
- クリーンなソース、lockfile、生成手順、標準Public runnerのCI。検証用APKは配布しません。

本番サービス、ストア配信、production署名、実AI/通知provider、物理Android/OEM、iOS実機の受入は含みません。[検証と制限](docs/TESTING.md)を参照してください。
