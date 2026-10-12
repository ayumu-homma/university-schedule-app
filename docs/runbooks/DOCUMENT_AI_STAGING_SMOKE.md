# Document AI staging live smoke

This runbook exercises the real Document AI provider boundary with a synthetic
text document containing exactly two assignments and one exam. It creates only
review candidates, verifies `requires_user_confirmation=true`, never calls a
candidate-confirmation RPC, and queues the synthetic source for cleanup.

Status: `REQUIRES_STAGING_CREDENTIAL / NOT RUN`. Local mocked contract tests do
not establish a live provider, hosted Edge deployment, or cleanup result.

## Safety boundary

- Staging only. The script rejects every other environment and requires
  `-ConfirmStaging`.
- The target host is bound to the staging project ref in
  `supabase/deployment/environments.json`; a caller cannot substitute a
  production ref.
- Use a dedicated staging test account. Do not use a personal account or real
  university material.
- The publishable key and short-lived user access token are read only from
  process environment variables. Do not place either value on the command line,
  in a tracked file, or in captured output.
- The script suppresses provider/API response bodies on failure and prints only
  schema/count/cleanup evidence.
- Running this script is a remote staging mutation and therefore requires the
  external-mutation checkpoint. The repository contract test does not make any
  network request.

## Prerequisites requiring a human

1. Complete the staging `preview` workflow and review its exact migration-plan
   digest, then use a separate approved `apply` dispatch for that same digest
   and exact SHA as described in
   `docs/operations/SUPABASE_DEPLOYMENT_READINESS.md`.
2. Review and set the staging Edge runtime contract before the approved deploy:
   `DOCUMENT_IMPORT_ENABLED=true`, `DOCUMENT_IMPORT_MODEL_ENABLED=true`,
   `DOCUMENT_IMPORT_FAKE_ENABLED=false`, and
   `DOCUMENT_IMPORT_PROVIDER=openai_responses`. The deploy workflow binds the
   last two values and the exact staging environment/project ref again.
3. Review bounded runtime values: `DOCUMENT_IMPORT_TIMEOUT_MS` (1,000–60,000;
   repository default 25,000), `DOCUMENT_IMPORT_PROVIDER_MAX_ATTEMPTS` (1–2;
   default 2), and `DOCUMENT_IMPORT_RETRY_BASE_MS` (0–2,000; default 250).
   A human supplies the approved `DOCUMENT_IMPORT_MODEL_ID` and
   `OPENAI_API_KEY` only through the staging secret manager; never mobile or a
   tracked file. Keep Supabase-provided reserved names outside the custom list.
4. Sign in as the dedicated synthetic staging account and obtain a short-lived
   access token through an approved local process.
5. Set the following only in the current terminal process:
   `STAGING_SUPABASE_PUBLISHABLE_KEY` and
   `STAGING_DOCUMENT_IMPORT_ACCESS_TOKEN`.

Do not paste secret values into tickets, PR text, terminal transcripts, or this
runbook.

## Command after checkpoint approval

```powershell
try {
  pwsh ./scripts/run_document_ai_staging_smoke.ps1 `
    -Environment staging `
    -SupabaseUrl https://STAGING_PROJECT_REF.supabase.co `
    -ConfirmStaging
}
finally {
  Remove-Item Env:STAGING_DOCUMENT_IMPORT_ACCESS_TOKEN -ErrorAction SilentlyContinue
  Remove-Item Env:STAGING_SUPABASE_PUBLISHABLE_KEY -ErrorAction SilentlyContinue
}
```

Always clear the short-lived access token from the current process after the
run, including when the smoke or cleanup fails. Revoke the staging session if
the token may have been copied or captured outside the approved process.

Only an actually executed successful staging run may produce a `PASS` evidence
record. Before reporting the schema/count summary, the script verifies an
order-independent semantic fingerprint of the synthetic assignment due times
and exam time/location entirely in memory. It also verifies that the
confirmation RPC was not called and that cleanup was queued for the same source
and storage path. Candidate text, dates, locations, raw model output,
credentials, user IDs, source IDs, and storage paths are intentionally absent
from output.

## Cleanup and failure handling

The script calls the authenticated `delete_document_source` RPC in `finally`.
That RPC tombstones unconfirmed candidates and queues private Storage deletion;
the bounded cleanup worker removes the object later. A cleanup failure makes the
smoke fail. Record the run time and exact Git SHA, then use the cleanup preview
runbook before any manual worker invocation. Never run `db reset`, `DROP`,
`TRUNCATE`, or direct bucket-wide deletion against staging.
