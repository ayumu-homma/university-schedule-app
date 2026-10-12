# API

## Supabase RPCs

### `search_course_templates`

Searches course templates within the caller's university only.

Inputs:
- `query_text text`
- `target_university_id uuid`
- `target_academic_year int`
- `target_term_id uuid default null`
- `target_day_of_week int default null`
- `target_period_no int default null`
- `limit_count int default 20`

Returns ranked templates with copy counts and duplicate metadata. Template author identity is not returned.

### `copy_course_template`

Creates an independent `user_courses` snapshot from a same-university course template and increments copy counters.

Inputs:
- `template_id uuid`
- `target_term_id uuid`

Returns:
- `user_course_id uuid`

### `get_visible_events`

Returns events in a date range with sensitive fields redacted according to resolved visibility.

Inputs:
- `viewer_id uuid` (compatibility parameter; it must equal `auth.uid()` and cannot select another viewer)
- `range_start timestamptz`
- `range_end timestamptz`

Visibility:
- `PRIVATE`: no row returned.
- `BUSY_ONLY`: time and busy marker only.
- `TITLE_ONLY`: title and time.
- `FULL`: full safe event details.

Only owner, accepted/unblocked friend, or active group-member candidates enter resolution. Unauthenticated calls and caller/viewer mismatches are rejected. The requested range is bounded.

### `find_free_windows`

Foundation RPC for free-time search over a list of users or group members. It uses the same visibility projection semantics and never treats `PRIVATE` events as busy for viewers.

`viewer_id` is also identity-bound to `auth.uid()`. Member count and time range inputs are bounded before expansion.

## Email import contracts

Production mobile code calls authenticated Edge Function endpoints rather than Gmail or a model provider directly. The versioned payload and EMAIL-01..08 semantics are normative in `docs/spec/EMAIL_MVP_ADDENDUM.md`. The server accepts no automatic task-creation instruction from email content; validated candidates require explicit confirmation and start `PRIVATE`.

## Local outbox contract

The mobile schema-v4 mutation envelope contains client mutation/idempotency key, entity type/id, operation, payload, optional base/server versions, lifecycle state, attempt/lease/retry timestamps, acknowledgement time, and a bounded sanitized error. Lifecycle states are `pending`, `processing`, `failed`, `conflict`, and `synced`.

Create operations have no base version. Update/delete operations carry the version read before the optimistic local write. Delete payloads contain only entity ID, owner ID, deletion/update timestamp, and new version. The Phase 3 server mutation endpoint must enforce the idempotency key and version contract; it must not trust owner identity from the payload instead of the authenticated session.

## Deep Links

```text
unischedule://course/:id
unischedule://assignment/:id
unischedule://exam/:id
unischedule://event/:id
unischedule://group/:id
unischedule://invite/group/:token
unischedule://invite/friend/:token
```
