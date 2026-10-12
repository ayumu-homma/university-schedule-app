# Roadmap

- v1.1のToday・時間割・課題とテストのUIを、学生への利用検証で評価・改善。
- Spatial Weekの任意2.5D source experimentは実装・合成Androidエミュレーター受入済み。既定の2Dを維持し、利用者の理解・操作に役立つかを検証してから採否を決める。
- 物理Android/OEMとiOS、通知配送・共有・同期の実環境検証。
- 本番Auth・公開ポリシー・署名・運用・ストア配信は別の受入として整備。

v1.0.0は保全したGitHubソース公開版の基準で、v1.1.0は[公開済み](https://github.com/ayumu-homma/university-schedule-app/releases/tag/v1.1.0)。Spatial Weekはsource branch `codex/v1.2-spatial-week`へ保存し、package version `1.1.0+2`を維持しています。これは正式なv1.2 releaseではありません。エミュレーターの描画時間・PSS診断を記録していますが、一貫した性能・操作上の優位性は確認できていません。iOS・物理端末と実ユーザーの比較は未測定です。詳細は[実験記録](docs/SPATIAL_WEEK_EXPERIMENT.md)と[検証結果](docs/TESTING.md#spatial-week-25d-source-experiment)を参照してください。
