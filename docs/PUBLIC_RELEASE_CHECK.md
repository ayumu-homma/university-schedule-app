# 公開前確認の要約

対象は新しい公開履歴とv1.0.0のsource-only版です。過去の開発履歴や内部ログは転載しません。

- 選別したソース、lockfile、Gradle wrapper、必要なassets、migration、テストと公開文書を抽出。
- `.env`実値、鍵・署名、DB、内部会話、プロンプト、実行ログ、個人用絶対パス、履修画像に基づく時間割を除外。
- Gitleaksと内容確認、PNG内容・metadata、相対リンク、CI設定、第三者表示を組み合わせて確認。
- 新しいcommitは既に公開されている著者表示とGitHub ID由来のnoreplyを使用。過去の日付・開発履歴を作りません。
- Git LFS、submodule、symlinkを持ち込みません。生成Dartは公開ソースから再生成します。
- CIは標準Public runner。検証workflowでcache/artifactを保存せず、APK/AABを転送しません。配備workflowの全jobを無効化。
- 未修正の開発用依存監査FAILとその影響範囲は[TESTING](TESTING.md)で明示。
- タグ、Release、匿名閲覧、fresh cloneの最終確認は公開後に追記します。

本人コードへのOSSライセンスは未付与です。[第三者の権利](../THIRD_PARTY_NOTICES.md)を維持します。スキャン成功は安全の完全な保証ではありません。
