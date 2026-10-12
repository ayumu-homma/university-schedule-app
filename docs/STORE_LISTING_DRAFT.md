# Store listing draft and asset inventory

Status: editorial draft only. No metadata or asset has been uploaded to Google
Play or App Store Connect. Copy must be reconciled with the exact enabled build,
policy URLs, legal review, and current store field limits before use.

## Draft copy (Japanese)

**App name**

Uni Schedule

**Short description**

時間割・課題・試験・予定を、オフラインでもひとつに整理

**Full description candidate**

Uni Schedule は、大学生活の予定を時間割中心に整理するためのアプリです。

月〜金の時間割、授業ごとの教室、課題と提出状況、試験、個人予定をひとつの流れで確認できます。Today 画面では、今日の授業と期限の近い課題にすぐアクセスできます。

主な機能:

- 週の時間割と授業・教室の管理
- 課題、試験、個人予定の整理
- オフラインでの確認と、接続回復後の同期
- 曜日や時刻を選べる朝のリマインダー
- プライバシー表示を選べる時間割ウィジェット
- 資料から抽出した候補を、保存前に確認・編集・除外するレビュー画面
- ライト／ダークテーマと読みやすさに配慮した表示

資料やメールからの取り込みは、候補を自動で予定にせず、ユーザーが内容を確認して確定する設計です。共有機能、外部プロバイダー連携、iOS ウィジェット、プッシュ配信は、対象ビルドで実際に有効化・検証された場合だけ掲載します。

**Internal-test release notes candidate**

初回の内部テスト版です。時間割、課題、試験、Today、朝のリマインダー、Android 時間割ウィジェット、資料候補の確認フローを評価できます。外部連携は段階的に検証します。

## Claims excluded until separately verified

Do not claim live Gmail/AI import, real-time friend/group collaboration, push
delivery, iOS WidgetKit, universal links, account deletion completion, public
production availability, or a specific accessibility conformance level until
the exact store binary and backend provide runtime evidence.

## Existing phone screenshot inventory

All eight repository captures are 1080 x 2424 PNGs, below 2 MiB, generated from
synthetic demo data, and previously privacy-reviewed for the portfolio. Recheck
them against the exact store candidate; portfolio acceptance does not
automatically make them store-approved.

| Order | Repository asset | Candidate caption | Review note |
| --- | --- | --- | --- |
| 1 | `docs/assets/screenshots/01-today.png` | 今日の授業と課題をひと目で確認 | Verify date/content remains synthetic |
| 2 | `docs/assets/screenshots/02-timetable-week.png` | 月〜金の時間割を週表示で整理 | Verify room/course names and active term |
| 3 | `docs/assets/screenshots/03-assignments.png` | 課題を期限と提出状況で管理 | Verify no unsupported cloud claim |
| 4 | `docs/assets/screenshots/04-morning-alarm-settings.png` | 曜日・時刻・通知方法を選べる朝の設定 | Android-only behavior must be labelled by locale/store as needed |
| 5 | `docs/assets/screenshots/05-morning-alarm-ringing.png` | ロック画面でも内容を見せすぎない通知 | Confirm exact/full-screen policy eligibility before selection |
| 6 | `docs/assets/screenshots/06-document-upload.png` | 資料を選んで予定候補を作成 | Do not imply an enabled live provider unless verified |
| 7 | `docs/assets/screenshots/07-document-candidates.png` | 保存前に候補を確認・編集・除外 | Preserve review-before-persistence claim |
| 8 | `docs/assets/screenshots/08-dark-timetable.png` | ダークテーマでも見やすい時間割 | Recheck contrast on release build/device |

Suggested Android phone sequence: 1, 2, 3, 4, 6, 7, 8. Include screenshot 5
only after permission-policy review. For iOS, recapture on a supported iPhone
simulator/device; do not reuse Android system chrome or claim the Android alarm
surface as iOS behavior.

## Missing store assets and metadata

| Item | Status | Completion evidence |
| --- | --- | --- |
| Google Play 512 x 512 icon | MISSING | Approved source export; do not upscale the 192 x 192 launcher asset |
| Google Play feature graphic | MISSING | Approved current-size graphic with license/privacy review |
| App Store 1024 x 1024 icon | REQUIRES_IOS_ASSET_CATALOG | Xcode asset validation and archive evidence |
| Tablet screenshots | NOT PLANNED / RECHECK | Decide device support and current store requirement before submission |
| Localized copy/assets | PARTIAL | Japanese draft only; locale owner and final field limits required |
| Privacy policy URL | REQUIRES_PUBLIC_HTTPS | Public, final, versioned policy reviewed against the deployed app |
| Terms URL | REQUIRES_PUBLIC_HTTPS | Public final terms and effective date |
| Account deletion URL | REQUIRES_PUBLIC_HTTPS | Public request/instructions matching the in-app deletion workflow |
| Support URL/email | REQUIRES_SUPPORT_OWNER | Monitored contact, response process, and incident escalation |
| Category/content rating/audience | REQUIRES_STORE_ACCOUNT | Human answers in each console based on the exact product |
| Data safety/App privacy | REQUIRES_LEGAL_REVIEW | Signed-off inventory mapped to exact binary/backend/processors |
| Copyright/trademark | REQUIRES_OWNER_REVIEW | Ownership/license evidence for name, icon, copy, fonts, and captures |

Use `docs/PRIVACY_AND_DATA_HANDLING_CHECKLIST.md` for the data review and
`docs/STORE_RELEASE_CHECKLIST.md` for the release gate.
