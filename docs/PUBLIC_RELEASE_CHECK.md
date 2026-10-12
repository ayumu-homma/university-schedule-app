# 公開前確認の要約

公開履歴は保全したv1.0.0から継続します。v1.1以降のsource-only版でも、変更したソース・画像・文書と対応するcommit/CIを確認します。過去の開発履歴や内部ログは転載しません。

- 変更したソース、lockfile、Gradle wrapper、必要なassets、migration、テストと公開文書を検査。
- `.env`実値、鍵・署名、DB、内部会話、プロンプト、実行ログ、個人用絶対パス、履修画像に基づく時間割を除外。
- Gitleaksと内容確認、PNG内容・metadata、相対リンク、CI設定、第三者表示を組み合わせて確認。
- 新しいcommitは既に公開されている著者表示とGitHub ID由来のnoreplyを使用。過去の日付・開発履歴を作らず、既存タグを移動しません。
- Git LFS、submodule、symlinkを持ち込みません。生成Dartは公開ソースから再生成します。
- CIは標準Public runner。検証workflowでcache/artifactを保存せず、APK/AABを転送しません。配備workflowの全jobを無効化。
- 未修正の開発用依存監査FAILとその影響範囲は[TESTING](TESTING.md)で明示。
- 未認証HTTPでREADME・主要文書・全掲載画像を読み戻し、公開commitのbytesと一致することを確認。認証helperを使わないfresh cloneで依存取得・コード生成も確認。
- 公開commitとtagの対応、CI、通常Releaseは[Releases](https://github.com/ayumu-homma/university-schedule-app/releases)を正本とします。[v1.0.0 Release](https://github.com/ayumu-homma/university-schedule-app/releases/tag/v1.0.0)は不変の基準です。APK/AABは添付しません。

本人コードへのOSSライセンスは未付与です。[第三者の権利](../THIRD_PARTY_NOTICES.md)を維持します。スキャン成功は安全の完全な保証ではありません。
