# Email Import MVP Addendum

Status: normative addendum to v0.4

Version: 1.0

Date: 2026-07-10

Feature flag: `EMAIL_IMPORT_ENABLED=false` by default

## 1. Scope and compatibility

This document adds Gmail-first email import to `docs/university_schedule_app_spec_v0.4.md` without rewriting or weakening that specification. It imports candidate assignments, exams, and personal events from email only after explicit user review.

Included:

- Gmail connection behind a provider-independent connector.
- Incremental metadata/message fetch through a trusted server boundary.
- Sanitization, structured extraction, strict validation, candidate review/edit/dismiss, deduplication/update proposals, explicit confirmation, disconnect/delete, and offline confirmation.
- Fake Gmail and deterministic rule-based extraction for secret-free CI and E2E.

Excluded:

- Direct LMS integration, attachment analysis, sending/replying, deleting email, changing read state, automatic URL/image fetching, and automatic creation or sharing of schedule entities.
- Outlook implementation in this MVP. The provider abstraction must allow it later without changing domain/UI contracts.

## 2. Requirements

### EMAIL-01 — Gmail connection

- Provide an `EmailConnector` interface independent of Google types.
- Gmail uses the minimum read-only scope required for the approved message query.
- OAuth authorization code exchange, refresh, revocation, and token storage occur only in a trusted server boundary such as Supabase Edge Functions.
- Flutter never receives client secrets, refresh tokens, AI keys, service-role keys, or raw provider credentials.
- Connection states are `disconnected`, `connecting`, `connected`, `reauth_required`, `rate_limited`, `failed`, and `disconnecting`.
- Real Gmail is enabled only when the server configuration exists and the feature flag is explicitly enabled. Fake connector selection is test-only and never the production default.

### EMAIL-02 — Incremental fetch and candidate generation

- Fetch incrementally with an opaque provider cursor/history token and a bounded lookback for the first sync.
- Handle rate limits, timeouts, revoked OAuth, and expired cursors as explicit recoverable/non-recoverable states.
- Store no raw body by default. Persist only provider/thread identifiers, timestamps, content hash, short evidence excerpts, normalized extraction, status, and source linkage.
- Do not fetch remote images or follow URLs found in email.
- Remove HTML, active content, tracking elements, quoted history, and signatures; normalize whitespace; enforce byte/character limits before extraction.
- Treat every body/subject/sender string as untrusted input.

### EMAIL-03 — Structured extraction

- Provide an `EmailTaskExtractor` interface independent of the AI/model provider.
- The extractor returns JSON only and never invokes tools, executes code, follows links, or obeys instructions found in the email.
- Secret-free tests use deterministic fake/rule-based extraction and Japanese fixtures.
- Unknown or ambiguous values remain `null`; they are not guessed.
- Relative dates use the source `received_at` and the user's configured IANA timezone. Ambiguous year/time/course values add warnings and require review.
- Validate schema version, enums, maximum lengths, HTTPS URLs, RFC3339 timestamps, IANA timezones, confidence range, evidence limits, and reminder values before persistence.

Normative JSON contract:

```json
{
  "schema_version": "1.0",
  "candidate_type": "assignment|exam|event|announcement|unknown",
  "title": "string|null",
  "course_hint": {
    "name": "string|null",
    "code": "string|null"
  },
  "due": {
    "at": "RFC3339|null",
    "all_day": false,
    "timezone": "IANA|null",
    "raw_text": "string|null"
  },
  "start_at": "RFC3339|null",
  "end_at": "RFC3339|null",
  "location": "string|null",
  "submission_url": "https URL|null",
  "summary": "string|null",
  "suggested_reminders_minutes": [1440, 180],
  "confidence": {
    "overall": 0.0,
    "title": 0.0,
    "course": 0.0,
    "date_time": 0.0
  },
  "evidence": [
    {
      "field": "due.at",
      "text": "short source excerpt"
    }
  ],
  "warnings": ["ambiguous_date"],
  "requires_user_confirmation": true
}
```

`requires_user_confirmation` must always be `true` for this MVP. JSON outside this contract is rejected; prose surrounding JSON is not accepted.

### EMAIL-04 — Review, edit, and dismiss

- Show a private candidate inbox with `needs_review`, `ready_for_review`, `update_available`, `confirmed`, `dismissed`, and `failed` states.
- Before confirmation, no Assignment, Exam, Event, calendar projection, or notification is created.
- The review form exposes evidence and warnings, lets the user correct type/title/course/date/time/location/URL/reminders, and never preselects public/shared visibility.
- Dismissal retains only the minimum provider/hash/fingerprint data required to prevent repeated presentation.

### EMAIL-05 — Explicit confirmation

- Only an explicit **Add** action creates a schedule entity.
- Initial visibility is always `PRIVATE`; there is no automatic template/friend/group sharing.
- Confirmation creates the Assignment/Exam/Event, calendar projection, notification schedule request, source link, and outbox mutation atomically in one local transaction.
- Server application uses an idempotency key so retries cannot create duplicates.

### EMAIL-06 — Deduplication and update proposals

- Enforce unique `(connection_id, provider_message_id)`.
- Use client/server idempotency keys, a sanitized content hash, and a semantic fingerprint of type + normalized title + course + due/start + URL.
- A dismissed candidate retains a minimal hash/fingerprint to suppress re-presentation.
- A later message in the same thread proposing a deadline/content change becomes `update_available` with a field-level diff. It never silently overwrites a confirmed entity.

### EMAIL-07 — Disconnect and derived-data deletion

- Disconnect revokes the provider grant when possible, destroys server-side token material, disables future sync, and deletes provider-derived sources/candidates according to the user's confirmation.
- User-confirmed schedule entities remain user-owned unless the user explicitly elects to delete them. Source linkage is removed or marked disconnected.
- Provide a separate account/data deletion path and audit the trusted-server operation without recording tokens or message bodies.

### EMAIL-08 — Offline review and outbox synchronization

- Previously cached candidates can be reviewed, edited, dismissed, or confirmed offline.
- Confirmation uses the same atomic local transaction as online confirmation and adds one durable outbox mutation.
- Restart preserves pending/failed/conflict state. Reconnect retries safely and creates the server entity exactly once.
- Fetching new mail and connecting/disconnecting require network access; UI explains this without discarding local edits.

## 3. Provider-independent contracts

Conceptual interfaces (final Dart naming may follow repository conventions):

```dart
abstract interface class EmailConnector {
  EmailProvider get provider;
  Future<EmailConnectionState> connect();
  Future<EmailFetchPage> fetchDelta({String? cursor});
  Future<void> disconnect({required bool deleteDerivedData});
}

abstract interface class EmailTaskExtractor {
  Future<EmailCandidatePayload> extract(SanitizedEmailInput input);
}
```

The mobile production connector calls only authenticated Edge Function endpoints. Provider SDK objects/tokens do not cross into domain or local-DB APIs.

## 4. Data and RLS requirements

Server tables (names may be adapted in a migration while preserving semantics):

- `email_connections`: owner, provider, provider account hash/label, scopes, cursor, states/errors/timestamps; no token columns exposed to clients.
- `email_sources`: owner/connection, provider message/thread IDs, received time, sanitized content hash, short evidence metadata, processing state.
- `email_candidates`: owner/source, schema version, validated structured payload, review state, fingerprint, linked entity type/id, error category.
- `email_candidate_updates`: candidate/thread diff proposals and resolution state.
- Trusted token storage is outside exposed client tables, encrypted/managed by the server platform.

All email rows are private to `auth.uid()`. User A cannot select, insert for, update, or delete user B's connection/source/candidate/update rows. Admin access uses a separately tested trusted role and never returns token material. Raw email bodies and OAuth tokens are not written to these tables or logs.

## 5. Failure and security behavior

- Prompt injection, executable/active HTML, malformed encoding, oversized content, invalid URLs, invalid JSON, unknown schema versions, and unsafe redirects become sanitized `failed` states with non-sensitive reason codes.
- Errors shown or persisted are allow-listed categories; provider responses, tokens, and message content are never copied into `last_error`.
- Network retry uses bounded exponential backoff with jitter and respects provider retry hints.
- Logs contain request/correlation IDs and state transitions only; no bodies, evidence text, full provider identifiers, tokens, or personal addresses.

## 6. Acceptance tests

1. Synchronizing the same fixture repeatedly yields one source, one candidate, and at most one confirmed task.
2. Japanese assignment, exam, and event fixtures produce schema-valid candidates.
3. No schedule entity exists before confirmation.
4. Ambiguous deadline/course data remains unset or warned; it is not guessed into a confirmed entity.
5. A user-edited candidate creates the correct PRIVATE entity.
6. A cached candidate confirms offline, survives restart, and syncs once after reconnect.
7. A same-thread deadline change produces an update proposal and does not overwrite the confirmed task.
8. Prompt injection, malicious HTML, oversized bodies, invalid JSON and unsafe URLs are rejected without tool calls or external fetches.
9. User A cannot read or mutate user B's connection, source, candidate, or update rows.
10. Rate limit, timeout, cursor expiry, and OAuth revocation produce tested state transitions.
11. Disconnect/revocation and derived-data deletion behave as specified while preserving user-owned entities by default.
12. Secret-free CI and E2E pass with the fake connector and deterministic extractor while production defaults remain disabled.
