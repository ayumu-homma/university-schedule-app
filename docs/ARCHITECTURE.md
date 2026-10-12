# Architecture

## Principles

- Drift/SQLite is the local read model for the mobile app.
- Supabase/PostgreSQL is the server source of truth for shared data.
- Supabase Realtime may accelerate refreshes but is not the primary sync mechanism.
- Course templates are shared only within a university; copied courses become independent user-course snapshots.
- Event visibility is projected server-side through RPC/view logic. Sensitive fields are not sent to unauthorized clients.
- Recurring events are stored as a master rule plus exceptions, not as permanently expanded rows.
- OAuth token exchange, provider email fetch, sanitization, and model-backed extraction stay behind a trusted server boundary. Flutter receives validated private candidates, never provider refresh tokens or raw mail by default.

## Mobile Layers

```text
presentation -> application -> domain -> data
```

- `presentation`: Flutter screens and widgets.
- `application`: Riverpod controllers, use cases, and view state.
- `domain`: shared immutable models and policies from `packages/shared_domain`.
- `data`: Drift DAOs, Supabase RPC/table clients, and sync queue.

## Local mutation lifecycle

Course, Assignment, Exam, and personal Event writes update the active row or tombstone and enqueue one mutation in the same Drift transaction. Updates and deletes are scoped by owner plus expected local version; a stale editor receives a conflict instead of overwriting a newer local row. Riverpod consumes a reactive multi-table Drift snapshot, so direct repository, queue, and future pull-sync writes update the UI without manual reloads.

The durable outbox claims one due mutation atomically, marks it `processing`, recovers abandoned five-minute leases after restart, retries failures with bounded exponential backoff, and isolates version conflicts from automatic retry. Terminal writes require the current processing attempt number, so a stale recovered worker cannot overwrite a newer result. Client mutation ID is also the default idempotency key. Successful acknowledgement clears payload/error data, retains non-sensitive metadata for 30 days, then deletes it during startup maintenance.

## Backend Shape

```text
auth.users
  -> profiles
universities -> course_templates -> user_courses
profiles -> calendars -> events -> event_exceptions
profiles -> assignments -> assignment_user_states
profiles -> friendships
groups -> group_members -> events/comments/reactions/participants
```

RLS protects original tables. RPC functions provide privacy-safe projections for visible events, free-time windows, and course template search/copy.

Caller identity for projection RPCs is derived from `auth.uid()`. Compatibility parameters such as `viewer_id` must match that identity and cannot be used to impersonate another user. Ordinary group members consume redacted projections; only the owner, event creator, or group administrator can read raw event rows needed for editing.

## Email Import Boundary

```text
Flutter candidate UI
  -> authenticated Edge Function contract
     -> Gmail provider adapter / future provider adapters
     -> sanitization and size limits
     -> EmailTaskExtractor
     -> strict JSON-schema validation
  -> private candidate cache
  -> explicit user confirmation
  -> local entity + projection + notification request + outbox transaction
```

Production email import is disabled by default. Fake Gmail and a deterministic rule-based extractor provide secret-free CI/E2E coverage.

## Widget Bridge

Flutter generates a compact JSON `WidgetSnapshot`. Native widgets read only the snapshot and deep-link back into the app. The snapshot supports privacy modes so lock-screen or shared-device surfaces can avoid exposing class details.

## Current local acceptance and account boundaries

As of 2026-09-29, the local MVP is accepted within [the recorded layers](TESTING.md). Hosted services, real delivery, device/OEM and signed release are separate gates. Local storage regions and activation generations fence reads, async completions and native commands across account replacement. Friend/group projections are capped and redacted in PostgreSQL; block state is checked in both directions. Group-default visibility is wired through the production owner/admin editor and authenticated RPC; ordinary members have read-only access.

The document-import UI, confirmation and storage paths are implemented. The demo explicitly uses synthetic extraction; real AI service behavior remains unverified. Admin moderation and account-deletion Web paths have scoped local synthetic acceptance, while public URLs/OTP and deployment are pending. [Setup](SETUP.md) keeps demo builds separate from actual backend configuration.
