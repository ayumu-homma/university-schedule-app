# ADR 0002: Keep email credentials and extraction behind a server trust boundary

- Status: Accepted
- Date: 2026-07-10

## Context

The email MVP needs Gmail OAuth, incremental fetch, sanitization, and optional model-backed extraction. Email content is untrusted and can contain prompt injection, active HTML, tracking URLs, secrets, and sensitive personal data. A Flutter client cannot safely hold OAuth client secrets, refresh tokens, service-role credentials, or AI API keys.

## Decision

- Flutter uses provider-independent domain contracts and authenticated Edge Function endpoints only.
- OAuth exchange/refresh/revocation, token storage, provider fetch, sanitization limits, and any model invocation run in the trusted server boundary.
- Raw bodies are processed ephemerally and are not persisted by default.
- AI output is an untrusted JSON proposal validated against the versioned contract; it can never directly create or update a schedule entity.
- The user must review and explicitly confirm every candidate, whose initial visibility is `PRIVATE`.
- Production email import is disabled by default. Secret-free CI uses fake Gmail and deterministic rule-based extraction.

## Consequences

- A later Outlook connector can implement the same connector contract without changing confirmation UI or local entity creation.
- Live OAuth/Gmail/model smoke tests may remain `EXTERNAL_BLOCKED` without blocking the fake/contract/DB/RLS/UI/E2E implementation.
- Server code and migrations must guarantee tenant isolation and must not log body, token, or personal-address data.
