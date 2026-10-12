# AGENTS.md

## Project role

You are acting as a senior full-stack mobile engineer for a university student scheduling app.

Build a production-oriented MVP from the repository documents, not a throwaway prototype.

## Source of truth

Read these documents before editing code:

1. `docs/university_schedule_app_spec_v0.4.md`
2. `docs/development_implementation_research.md`
3. `docs/product_research.md` if present

When documents conflict, prefer:

1. `docs/university_schedule_app_spec_v0.4.md`
2. `docs/development_implementation_research.md`
3. `docs/product_research.md`

## Non-negotiable architecture

- Mobile: Flutter
- State management: Riverpod
- Routing: go_router
- Local DB: Drift + SQLite
- Backend: Supabase + PostgreSQL
- Auth: Supabase Auth
- Realtime: Supabase Realtime only as an accelerator, not the sole sync mechanism
- Push: FCM + APNs
- iOS widget: WidgetKit
- Android widget: Jetpack Glance / App Widgets
- Admin: Next.js or a minimal web admin shell

## Security rules

- Never put Supabase service_role keys in mobile code.
- Never commit real `.env`, API keys, certificates, signing keys, provisioning profiles, or OAuth secrets.
- Use `.env.example` with placeholder values.
- RLS must be enabled on exposed Supabase tables.
- Prefer RPC/view projection for redacted event visibility.
- Do not rely on client-side masking for private event details.
- Treat schedule, university, friend, group, class, and job information as sensitive personal information.

## Implementation priorities

Implement the MVP in vertical slices. Use `docs/TESTING.md` for current acceptance scope and `docs/MVP_TRACEABILITY.md` for source mappings. Keep test evidence tied to its actual layer:

1. Repo scaffold and tooling
2. Domain models
3. Drift local schema
4. Supabase migrations, RLS, and RPCs
5. Mock/offline-first mobile UI
6. Timetable and course template copy
7. Assignments, exams, calendar, recurrence
8. Visibility and free-time search
9. Friends and groups
10. Group events, comments, reactions
11. Widget bridge
12. Notifications and deep links
13. Tests, CI, documentation

## Quality gates

Run the relevant checks at each acceptance-batch boundary and after repairs that affect them. Reuse a passing result only when its relevant source, tests, fixtures, dependencies, configuration, tool version, environment, command, and result still match. Do not infer whole-feature or device acceptance from a successful command:

- `flutter analyze`
- `dart run build_runner build --delete-conflicting-outputs`
- `flutter test`
- Supabase migration validation when Supabase CLI is available
- Unit tests for recurrence, visibility projection, course normalization, duplicate detection, and assignment submission

If a tool is unavailable, document the skipped check and the exact command the user should run.

## Working style

- Keep changes reviewable and update `docs/PROJECT_STATE.md` with non-sensitive progress; commit only when separately authorized.
- Before a risky refactor, record a short non-sensitive plan.
- Prefer completing a working vertical slice over scattering incomplete files.
- Do not stop after scaffolding. Continue until the Definition of Done in the active prompt is met or a real blocker is reached.
