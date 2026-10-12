# ADR 0001: Retain bounded sync audit history

- Status: Accepted
- Date: 2026-07-10

## Context

The existing local worker marks successful `sync_queue` rows as `synced` and keeps them. The v0.4 specification's pseudocode deletes successful mutations. The goal requires an explicit decision because both indefinite retention and immediate deletion have tradeoffs.

Email confirmation and offline retries also need idempotency evidence after acknowledgement, but payloads can contain sensitive schedule metadata and must not remain indefinitely.

## Decision

Keep an acknowledged mutation record for a bounded audit window instead of immediately deleting every row.

- Persist immutable client mutation/idempotency key, entity type/id, operation, acknowledgement time, attempt count, and non-sensitive result metadata.
- Clear the mutation payload and detailed error text after successful acknowledgement.
- Retain acknowledged metadata for 30 days by default, then delete it during local maintenance.
- Keep pending, failed, and conflict rows until resolved or explicitly discarded by the owning user flow.
- Never record OAuth tokens, raw email, API responses containing personal data, or server secrets in the queue/error fields.
- Server idempotency records may use a longer bounded retention appropriate to retry guarantees, documented in the sync API migration.

## Consequences

- Duplicate/restart investigations remain possible without retaining sensitive payloads.
- Phase 1 implements the local decision in Drift schema v4: acknowledgement clears payload/error data, safe metadata is retained for 30 days, and cleanup/restart tests enforce the boundary.
- Immediate row deletion remains acceptable for migrations from older installations after extracting the safe audit metadata.

Server-side idempotency retention remains a Phase 3 contract and must be documented with the mutation RPC migration.
