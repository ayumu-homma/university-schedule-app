# Supabase deployment and document-cleanup operations

## Current boundary

This repository contains a guarded deployment path, but it does not contain
staging or production credentials. The project-ref placeholders in
`supabase/deployment/environments.json` intentionally make the selected remote
target fail closed until that project has been created and reviewed. Staging
may be activated while production remains the placeholder; production stays a
later, separate release checkpoint.

No project link, remote migration, Edge Function deployment, secret update, or
cleanup schedule is performed by the repository's normal CI workflow. The
deployment workflow is manual-only. Both environments depend on GitHub
Environment approval; production additionally requires an exact confirmation
value.

Repository status is `LOCALLY PREPARED / REMOTE NOT RUN`: the manifest still
contains fail-closed project-ref placeholders, no protected credentials are
present here, and neither a preview nor an apply run is claimed by this
document.

Supabase recommends separate staging and production projects and a
version-controlled migration pipeline. See [Managing Environments][env-docs],
[CLI workflows][cli-docs], and the [deployment maturity model][maturity-docs].

[env-docs]: https://supabase.com/docs/guides/deployment/managing-environments
[cli-docs]: https://supabase.com/docs/guides/local-development/cli-workflows
[maturity-docs]: https://supabase.com/docs/guides/deployment/maturity-model

## Environment activation checkpoint

The following steps are external operations. Stop for human approval before
performing them.

1. Create and review the hosted `staging` Supabase project first. Create the
   distinct `production` project only at the later production checkpoint.
2. Review each selected project's ref. Project refs are identifiers, not API
   keys, and may replace only that environment's placeholder in the deployment
   manifest through a reviewed code change. The other environment may remain a
   placeholder; if both are active, their refs must differ.
3. Create GitHub Environments named exactly `staging` and `production`.
4. In each GitHub Environment, configure the non-secret variable
   `SUPABASE_PROJECT_REF` and the encrypted secrets
   `SUPABASE_ACCESS_TOKEN` and `SUPABASE_DB_PASSWORD`.
5. In both GitHub Environments, configure at least one required reviewer,
   prevent self-review, and enable a deployment branch policy. Restrict
   production to `master`; staging may allow only the branches listed in the
   manifest. Do not add either environment's credentials before all three
   protections are active.
6. Register the custom Edge secret names listed in the manifest. Secret values
   must be supplied through an approved secret manager or the Supabase secret
   UI/CLI; never place them in a command argument, repository file, artifact,
   job summary, or mobile build.
   `APP_ENV`, `APP_SUPABASE_PROJECT_REF`, `DOCUMENT_IMPORT_FAKE_ENABLED`, and
   `DOCUMENT_IMPORT_PROVIDER` are still inventoried, but the protected deploy
   workflow overwrites them with the selected environment, the manifest-bound
   project ref, `false`, and `openai_responses` immediately before deploying
   functions. Do not hand-maintain different values for those four names.
7. Confirm OAuth redirect URLs, email-delivery endpoints, provider data
   controls, budgets, and model support in staging before enabling live
   provider flags.
8. Inspect each project's Data API exposure setting and effective grants. New
   hosted projects may not expose newly created tables automatically; API
   grants and RLS are separate controls. Do not infer remote accessibility from
   local RLS tests alone. See [Securing your API][data-api-docs].

GitHub documents that environment secrets are unavailable until configured
protection rules pass. Required reviewers, self-review prevention, and branch
rules remain external repository settings; the guard reads their metadata and
fails before the secret-bearing job when either selected environment lacks any
of them. It never creates or modifies an Environment. See
[Deployments and environments][github-environment-docs].

`SUPABASE_URL`, publishable/anon keys, and service-role/secret keys are managed
by Supabase. Custom secret names must not use the reserved `SUPABASE_` prefix.
See [Edge Function secrets][secret-docs].

[secret-docs]: https://supabase.com/docs/guides/functions/secrets
[github-environment-docs]: https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments
[data-api-docs]: https://supabase.com/docs/guides/api/securing-your-api

## Pre-deploy verifier

The guarded verifier is `scripts/verify_supabase_predeploy.ps1`. It checks:

- selected environment, exact project-ref allowlist, branch, and full Git SHA;
- a clean worktree and the linked ref in `supabase/.temp/project-ref`;
- the exact Supabase CLI version from the manifest;
- migration filename order and uniqueness;
- high-risk `DROP DATABASE/SCHEMA/TABLE/TYPE`, `TRUNCATE`, and
  `ALTER TABLE ... DROP COLUMN` migration statements;
- `verify_jwt = true` for every deployed Edge Function;
- local-only database reset, database lint, pgTAP, and schedule-sync tests;
- Edge format, lint, type-check, and tests;
- remote migration inventory;
- presence of required Edge secret names without reading or printing values;
- absence of destructive deployment commands in the manual workflow.

The separate exact-plan builder is
`scripts/verify_supabase_migration_plan.ps1`. It requires the reviewed remote
baseline, rejects remote-only history, permits only migrations explicitly
listed as `additive-reviewed`, checks each migration's SHA-256, and produces a
canonical compact JSON plan bound to environment, project ref, deploy SHA,
baseline version, and pending migration hashes. Its classifier is a defense-in-
depth guard, not a complete SQL authorization proof. A human must still review
the exact migration diff, especially grants/revokes, RLS enable/disable and
policy semantics, ownership, constraints, column/type changes, and privileged
functions before adding a hash to the allowlist.

`-StaticOnly` performs repository/configuration checks and makes no remote
call. It is useful after real project refs have been reviewed and committed:

```powershell
pwsh ./scripts/verify_supabase_predeploy.ps1 `
  -Environment staging `
  -ProjectRef '<reviewed-staging-project-ref>' `
  -ExpectedSha '<full-current-sha>' `
  -ExpectedBranch 'feature/portfolio-v0.6-production-readiness' `
  -StaticOnly
```

The secret-bearing deploy job deliberately does not use `-StaticOnly`.

Run the non-network contract tests independently:

```powershell
pwsh ./scripts/test_supabase_deployment_guard.ps1
```

## Manual deployment workflow

`.github/workflows/supabase-deploy.yml` accepts only `workflow_dispatch`.
The requested SHA must be a full lowercase SHA and must equal the selected
workflow ref HEAD. Fork, PR, push, and scheduled events cannot enter the
secret-bearing deploy job.

GitHub only dispatches a manual workflow after that workflow file exists on
the repository's default branch. A Draft PR containing this file is reviewable
but is not itself authority to merge it or deploy. Default-branch integration
is a separate human approval checkpoint. See [Triggering a workflow][github-trigger-docs].

[github-trigger-docs]: https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow

Every dispatch performs these operations in order:

1. checks out the exact SHA without persisted Git credentials;
2. pins Deno and Supabase CLI versions;
3. verifies GitHub Environment protection metadata before protected secrets are
   available;
4. runs static and isolated local verification in a separate job that receives
   no deployment credentials;
5. starts a fresh protected job, re-runs the static target/SHA guard, and links
   only the manifest-approved project ref;
6. reads remote migration and secret-name inventory without printing values;
7. builds the exact allowlisted migration plan and, for preview only, prints
   its SHA-256;
8. confirms the same target with `supabase db push --dry-run --linked`.

For `operation=preview`, the workflow then stops. It does not push a migration,
set an Edge secret, or deploy a function. Preserve the successful run URL, exact
deploy SHA, environment, masked target ref, and emitted 64-character migration
plan digest for human review. The workflow also uploads an immutable, run-bound
plan artifact retained for 14 days; preserve the numeric preview run ID shown
in the summary.

`operation=apply` must be a new, separately approved dispatch on the same exact
SHA and target. Supply both `preview_run_id` and the reviewed
`migration_plan_sha256`. Before the protected remote job starts, the workflow
uses the Actions API to require that ID to be a completed, successful manual
preview from this workflow, repository, branch, environment, and exact SHA. It
downloads only that run's immutable plan artifact and verifies its target and
digest. A failed apply run, a digest copied from one, or a digest without a
matching successful preview artifact is not approval. Apply then recomputes the
remote inventory, canonical plan, digest, and CLI dry-run without displaying
the new digest or plan, and proceeds only when it still matches the approved
artifact and `apply_confirmation` is exactly `APPLY_STAGING` or
`APPLY_PRODUCTION`. A mismatch means the plan or remote baseline changed; stop
and run a new preview. Only after that equality check does apply:

1. push the reviewed migrations without seed/reset;
2. bind the Edge runtime to the approved environment/ref, force Document AI
   fake mode off, and select the reviewed provider without displaying values;
3. deploy only the explicit Edge Function allowlist;
4. check the Auth health endpoint, migration inventory, and deployed function
   inventory;
5. write a non-secret summary.

Production additionally requires all of the following:

- selected ref `refs/heads/master`;
- input `production_confirmation` exactly equal to `DEPLOY_PRODUCTION` for
  both preview and apply;
- for apply, the successful preview run ID, accepted artifact digest, and
  `APPLY_PRODUCTION`;
- approval through the protected `production` GitHub Environment.

Staging apply similarly requires the successful preview run ID, accepted
artifact digest, and `APPLY_STAGING`. A preview never accepts a run ID, digest,
or either apply confirmation.

Do not dispatch either environment until the environment-activation checkpoint
has been reviewed. Do not use `db reset --linked`, migration repair,
`--include-seed`, function `--prune`, or `--no-verify-jwt` in this workflow.

## Post-deploy checks and incident response

An apply run verifies control-plane inventory and Auth health. A preview run
does not claim post-deploy health because it performs no deployment. Staging
live-provider smoke tests remain a separate credentialed acceptance step and
must use synthetic inputs only.

If a migration fails, stop deployment and preserve the exact SHA and workflow
run. Database rollback is a reviewed forward-fix migration; never reset a
remote database and never edit an already-applied migration. Before a
production schema change, confirm the backup/PITR posture and recovery owner.

If an Edge Function regresses, disable its feature flag through the approved
secret-management process or redeploy the last known-good exact SHA after the
same environment approval. Do not silently weaken JWT verification or switch a
production provider to a fake.

Logs and audit events may contain only correlation/deployment IDs, action,
allowlisted status/category, duration, model identifier, and bounded numeric
counts. Never log request bodies, email/document text, Storage paths, user IDs,
provider response bodies, OAuth codes/tokens, API keys, or database passwords.

## Document cleanup: dry-run

`scripts/run_document_cleanup_staging.ps1` is intentionally staging-only. It
derives the HTTPS host from the reviewed manifest ref and reads
`SUPABASE_SERVICE_ROLE_KEY` from the current process environment. It never
accepts the key as an argument or prints it.

The default mode calls the read-only preview RPC and writes a count-only audit
record. No source/candidate lifecycle row is claimed and no Storage object is
deleted. The audit row itself is the only write.

After an approved staging secret has been injected into the process by a
secret manager, run:

```powershell
pwsh ./scripts/run_document_cleanup_staging.ps1 `
  -ProjectRef '<reviewed-staging-project-ref>' `
  -Limit 100
```

Output is restricted to run ID, masked project ref, requested limit, and
aggregate counts. Paths, owners, source IDs, API responses, and credentials are
suppressed.

## Document cleanup: bounded manual execution

Execution is a destructive staging operation and requires a separate human
approval. The exact confirmation is deliberately awkward:

```powershell
pwsh ./scripts/run_document_cleanup_staging.ps1 `
  -ProjectRef '<reviewed-staging-project-ref>' `
  -Limit 100 `
  -Execute `
  -Confirmation DELETE_STAGING_DOCUMENTS
```

The script:

1. previews counts without revealing paths;
2. opens a count-only audit run with a random run ID;
3. calls the existing service-only claim RPC with a limit from 1 through 500;
4. validates every returned source/path binding internally;
5. deletes the bounded path list through the Supabase Storage API, never SQL;
6. finalizes the audit with claimed/deleted/failed counts;
7. reads the same count-only audit row back by run ID;
8. performs a final count preview when possible.

The existing claim remains recoverable: a failed Storage deletion leaves its
object metadata present, so a later bounded run can claim the path again. A
successful Storage API deletion makes the path ineligible; a later claim
retires a now-stale durable queue entry. Audit begin/finish calls are
idempotent for the same run ID and inputs. Storage deletion is permanent and
not recoverable, so inspect the dry-run count and backup posture first. See
[Delete Objects][storage-delete-docs].

[storage-delete-docs]: https://supabase.com/docs/guides/storage/management/delete-objects

For a partial/failed run, retain the run ID, do not expose paths in an incident
ticket, run another dry-run, and reconcile only aggregate counts. If audit
finalization failed, the private record remains `started` for operator review.

## Scheduler boundary, activation, and disable

No cleanup schedule is active in this repository. This is deliberate: the
current trusted implementation is an operator script, and scheduling the claim
RPC by itself would transition database rows without deleting the underlying
Storage objects.

Before activation, implement and test an authenticated server-side cleanup
worker that uses the same preview, claim, Storage API, and count-only audit
sequence. In staging, prove bounded execution, retry behavior, safe logs, and
zero raw path/content output. Only then may an approved operator store a
dedicated scheduler credential in Supabase Vault and create a `pg_cron` +
`pg_net` schedule that invokes that worker. Supabase documents this pattern in
[Scheduling Edge Functions][schedule-docs]. Activation is a remote database
mutation and requires the external-mutation checkpoint.

Disable/rollback procedure after activation:

1. unschedule the named cron job before changing the worker;
2. confirm no invocation remains in flight;
3. disable the worker feature flag or scheduler credential;
4. use dry-run counts to assess remaining work;
5. redeploy a reviewed exact SHA or a forward-fix migration;
6. retain only count-level incident evidence.

Until that worker exists and staging evidence is green, continue with approved
manual bounded execution. Do not enable a production scheduler.

[schedule-docs]: https://supabase.com/docs/guides/functions/schedule-functions

## Exact external blockers

The following remain outside repository-only verification and must not be
reported as `PASS` here:

- `REQUIRES_STAGING_CREDENTIAL`: create the staging hosted project, replace only
  its manifest placeholder through review, configure a non-empty required
  reviewer set, self-review prevention, a branch policy, protected GitHub
  Environment variables/secrets, and complete a staging preview then separately
  approved run/artifact-bound apply; production remains deferred;
- `REQUIRES_STAGING_CREDENTIAL`: configure Document AI, Gmail OAuth/email
  import, and university-email-verification provider values, then run their
  synthetic staging acceptance checks;
- `REQUIRES_DESTRUCTIVE_STAGING_APPROVAL`: rehearse bounded cleanup against
  synthetic expired data and preserve count-only evidence;
- `REQUIRES_PRODUCTION_APPROVAL`: configure production protection/backup/PITR,
  run production preview, obtain separate approval for its run ID and exact
  artifact digest, and dispatch production apply from `master`;
- `NOT IMPLEMENTED / DO NOT ACTIVATE`: build and stage the authenticated cleanup
  worker before any scheduler credential or `pg_cron` activation.
