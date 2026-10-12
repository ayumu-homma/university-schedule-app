# MVP requirements and source map

Status: 2026-09-29 local scope accepted; GitHub source release is the v1.0.0 scope; store and hosted-service acceptance remain pending. [Evidence and limits](TESTING.md) distinguish DB/API, Flutter, JVM and device results. This is not a new execution of accepted cases.

| Requirement group | Source | Local acceptance scope | External gate |
|---|---|---|---|
| Auth / onboarding / university | [mobile features](../apps/mobile/lib/features/) | Config validation, Auth state, university/term/period setup | Hosted Auth, OAuth/OTP |
| Course / timetable / assignment / exam / event / recurrence | [features](../apps/mobile/lib/features/), [domain](../packages/shared_domain/lib/) | CRUD, projections, recurrence, Today and local tests | Device UX |
| Offline persistence / sync | [local DB](../apps/mobile/lib/local_db/), [sync](../apps/mobile/lib/core/sync/) | Owner regions, outbox/retry/conflicts, account switch | Hosted networking/operational acceptance |
| SHARE-01 / friend / group / availability | [features](../apps/mobile/lib/features/), [migrations](../supabase/migrations/) | Six specified visibility rows; layered synthetic DB/API/Flutter evidence | Hosted and device |
| Comments / reactions / block / report | [groups](../apps/mobile/lib/features/groups/), [SQL tests](../supabase/tests/) | Bidirectional authorization, safe projections, scoped connected screens | Real-user moderation |
| Notifications / alarm / widget | [notification](../apps/mobile/lib/features/notification/), [Android](../apps/mobile/android/app/src/), [iOS](../apps/mobile/ios/) | Dart/native contracts and JVM tests | Actual delivery, physical Android/OEM, APNs/iOS |
| Document import | [document import](../apps/mobile/lib/features/document_import/), [Edge](../supabase/functions/document-import/) | Input validation, synthetic extraction, review and persistence | Live AI/provider, hosted Storage/Edge |
| Admin / deletion / policies | [admin](../apps/admin/), [Edge](../supabase/functions/) | Scoped local synthetic moderation/deletion E2E; public config fail-closed | HTTPS host, content, SMTP and deployment |

The current migration source has 60 files ending at `20260929131715_portfolio_moderation_contract_restoration.sql`. The forward repair restores the existing moderation result, conflict, and previous-state audit contract. Authorized migration validation uses fresh disposable GitHub-hosted CI databases only; retained and remote databases are not migration targets. Check the public repository's exact-commit CI result separately from historical local acceptance. Runtime credentials, historical fixtures, DB files and raw operational records are kept out of the current source tree. The v1.0.0 tag and its CI identify the public source and test inputs.
