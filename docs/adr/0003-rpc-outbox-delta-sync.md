# ADR 0003: Use an RPC outbox/delta protocol for schedule sync

- Status: Accepted
- Date: 2026-07-10

## Context

The mobile client already commits optimistic schedule changes and an owner-scoped
outbox row in one Drift transaction. Direct table upserts cannot safely complete
the remaining protocol: they do not provide durable idempotency receipts, exact
base-version conflict handling, ordered pull cursors, or a canonical tombstone
representation. Realtime delivery is also not reliable enough to be the source
of truth.

## Decision

Authenticated clients write supported personal schedule entities only through
`apply_schedule_mutation`. The RPC derives the owner from `auth.uid()`, validates
the entity and operation, and commits the mutation, an idempotency receipt, and a
per-owner monotonic change record atomically. Create and the first Assignment
state submit have no base version; update/delete and a later submit require the
exact current base version. Acknowledgements are assembled from one immutable
change-log row, so version, payload, tombstone, and cursor cannot cross
concurrent snapshots. Reusing a key with the same canonical request replays its
receipt; reusing it for a different request is rejected.

Clients push in durable outbox order and stop after a transient failure so later
mutations cannot overtake an earlier one. An acknowledgement is applied to the
local entity and outbox in one Drift transaction. A conflict remains durable and
retains the bounded canonical server snapshot needed for an explicit resolution.

`get_schedule_delta` is the source of truth for initial and incremental pull.
The server returns canonical rows and tombstones behind an owner-scoped monotonic
cursor. Drift applies a validated page and advances its cursor atomically. A page
that intersects an unresolved local mutation is not applied and its cursor is not
advanced.

Startup, foreground resume, connectivity restoration, manual requests, and
Realtime invalidations all request the same coalescing single-flight sync. A
private Realtime broadcast contains only an invalidation cursor; clients always
pull the authoritative delta and never treat a broadcast payload as schedule
data.

## Consequences

- A lost response is safe: restart resends the same key and receives the stored
  result without duplicating the server row.
- A fresh device can hydrate from cursor zero, including rows that existed when
  this protocol was introduced.
- Soft deletes remain pullable as tombstones.
- Conflict resolution is explicit; remote data is not allowed to silently
  overwrite an unsent optimistic change.
- Receipt retention is 90 days, exceeding the 30-day redacted acknowledged-local
  outbox retention. Receipts, per-owner cursor heads, and change records are
  private server data and are not directly client writable.
