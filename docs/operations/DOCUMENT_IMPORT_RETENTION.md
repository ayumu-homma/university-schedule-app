# Document import retention and cleanup runbook

## Policy

- Raw source objects and review candidates expire 30 days after upload.
- An explicit user deletion closes database and Storage visibility immediately,
  advances retention expiry, and queues the exact object for the trusted cleanup
  worker. The mobile client cannot and does not delete a soft-deleted object.
- Confirmed assignments and exams are user-owned schedule records. Deleting or
  expiring their source document does not delete those records.
- Processing is claimed atomically, is limited to five attempts, and records
  only a bounded error category plus an optional retry-after timestamp.

## Production cleanup worker

The repository defines the service-role-only
`claim_expired_document_sources(limit)` boundary. A production scheduler must:

1. Run in a trusted server environment; never place the service-role credential
   in Flutter, a public workflow artifact, logs, or this repository.
2. Call the RPC in bounded batches (1–500). The RPC makes expired rows and
   candidates private before it returns their Storage paths. The limit applies
   once across both expired rows and durable hard-delete queue entries.
3. Delete each returned object from the private `schedule-documents` bucket via
   the Supabase Storage API. Do not delete directly from `storage.objects`.
4. Retry the same bounded job. A path stays claimable while its expired object
   still exists, so an interrupted Storage deletion is recoverable.
5. Emit counts and opaque source IDs only. Never log filenames, object bytes,
   extracted text, candidate payloads, user IDs, or provider response bodies.

Scheduling and credentials are intentionally external deployment settings; no
production cron or secrets are created by this repository task.

## Account deletion order

Supabase Auth can reject user deletion while that user still owns Storage
objects. The trusted account-deletion workflow must therefore hard-delete the
owner's document import metadata in foreign-key-safe order (confirmations,
candidates, then sources), drain the queued source paths through
`claim_expired_document_sources(limit)`, delete every returned object through
the Storage API, and only then retry Auth user deletion. This pre-Auth import
cleanup does not delete confirmed schedule entities; their normal deletion
policy applies when Auth account deletion completes. A `BEFORE DELETE`
trigger durably captures each source path before an account cascade or trusted
hard delete can erase its relational metadata. Do not use direct SQL deletion
from `storage.objects`; it removes metadata without deleting the stored bytes.

## Verification

The pgTAP suite verifies the service-role boundary, expiry visibility, cleanup
claim/reclaim behavior, account-cascade queue durability, the combined batch
limit, and retention of confirmed schedule entities. Run:

```powershell
supabase db reset --local
supabase test db --local
```

For an end-to-end production rehearsal, use a disposable private project,
upload synthetic data only, invoke the trusted cleanup worker, and verify both
Storage deletion and retained confirmed schedule records.
