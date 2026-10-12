# Changelog

## 1.0.0 — Portfolio / Source Release

大学生向け時間割・課題・試験・予定管理アプリの、ソースとローカルデモを公開する版です。公開履歴はv1.0から管理します。

- Flutter / Riverpod / go_router、Drift / SQLiteによるローカル保存とoutbox同期。
- 授業テンプレコピー、課題の提出状態、試験、カレンダー、繰り返しと例外。
- Supabase Auth、PostgreSQLのRLS/RPCによる公開範囲、友だち・グループ、通報・ブロック。
- Android通知・朝アラーム・ウィジェット橋渡し、iOS WidgetKit連携コード、Next.js管理画面。
- 資料候補の確認・編集・登録。ローカルデモの抽出はfake adapter。
- クリーンなソース、lockfile、生成手順、標準Public runnerのCI。検証用APKは配布しません。

本番サービス、ストア配信、production署名、実AI/通知provider、物理Android/OEM、iOS実機の受入は含みません。[検証と制限](docs/TESTING.md)を参照してください。
