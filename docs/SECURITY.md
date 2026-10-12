# Security

## Non-Negotiables

- Never commit real `.env`, OAuth secrets, API keys, certificates, signing keys, provisioning profiles, private keys, or Supabase service role keys.
- Mobile code may use only the Supabase anon key.
- RLS must be enabled on exposed tables.
- Private event details must be redacted server-side through RPC/view projection.
- Schedule, university, friend, group, course, and job information are sensitive personal information.
- Raw email bodies and OAuth tokens are not application logs or client-visible table data.

## Visibility Rules

Final visibility resolution order:

1. Block state
2. Event-level override
3. Calendar-level override
4. Group-level rule
5. Friend-level rule
6. User default

`PRIVATE` events are hidden from the viewer and treated as free time. `BUSY_ONLY` returns a busy block only. `TITLE_ONLY` returns title and time only. `FULL` returns details.

Projection RPCs bind the requested viewer to `auth.uid()`, filter candidates by relationship before resolving visibility, and give blocks priority. A group membership alone never grants direct access to raw event details. Base profile reads are self-only until a narrow, block-aware search projection is implemented. `university_verified` is server-managed and client forgery is rejected.

## UGC

UGC surfaces include course templates, event comments, reactions, group names, and event titles. The MVP includes report/block placeholders, admin review tables, and moderation/audit foundations.

## Native / Platform Secrets

Push notification credentials, Apple Developer assets, Google service files, and signing material must be injected through secure CI/project configuration and excluded from Git.

## Local outbox data minimization

- Mutation payloads exist only while pending, retrying, or awaiting conflict resolution; successful acknowledgement replaces the payload with `{}` and clears detailed errors.
- Acknowledged rows retain only safe idempotency/audit metadata for 30 days before cleanup.
- Stored errors redact email addresses, credential-like assignments, Bearer values, URLs, and long token-like values, then enforce a 240-character limit.
- OAuth tokens, raw email, provider responses, secrets, and server credentials are forbidden in payload/error fields.
- Local updates/deletes require owner scope and an expected version; this protects devices that retain data for more than one account, but server authorization still depends on authenticated RLS.

## Email Import

- Gmail OAuth exchange/refresh/revocation, message fetch, sanitization, and AI calls run only in the trusted server boundary.
- Flutter never receives refresh tokens, OAuth client secrets, AI keys, service-role credentials, or raw provider credentials.
- Email is untrusted input: no tool execution, code execution, URL following, remote image loading, or obedience to body instructions.
- Persist only minimal provider identifiers/hashes, timestamps, bounded evidence, validated extraction, and review state; raw bodies are ephemeral by default.
- Every candidate requires explicit user review and confirmation, and the initial visibility is `PRIVATE`.
- Error/log fields use allow-listed reason codes and never contain bodies, tokens, personal addresses, or provider response dumps.
