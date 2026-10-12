$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$assertionCount = 0

function Assert-Contract {
    param(
        [Parameter(Mandatory)] [bool]$Condition,
        [Parameter(Mandatory)] [string]$Message
    )

    if (-not $Condition) {
        throw "Supabase deployment guard contract failed: $Message"
    }
    $script:assertionCount += 1
}

function Assert-PowerShellSyntax {
    param([Parameter(Mandatory)] [string]$Path)

    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors
    )
    Assert-Contract (@($errors).Count -eq 0) `
        "PowerShell syntax errors were found in $Path."
}

$manifestPath = Join-Path $workspace "supabase/deployment/environments.json"
$workflowPath = Join-Path $workspace ".github/workflows/supabase-deploy.yml"
$predeployPath = Join-Path $workspace "scripts/verify_supabase_predeploy.ps1"
$migrationPlanPath = Join-Path $workspace `
    "scripts/verify_supabase_migration_plan.ps1"
$previewProvenancePath = Join-Path $workspace `
    "scripts/verify_supabase_preview_provenance.ps1"
$migrationPolicyPath = Join-Path $workspace `
    "supabase/deployment/migration-policy.json"
$cleanupPath = Join-Path $workspace "scripts/run_document_cleanup_staging.ps1"
$cleanupMigrationPath = Join-Path $workspace `
    "supabase/migrations/202608220016_document_cleanup_operations.sql"
$documentImportIndexPath = Join-Path $workspace `
    "supabase/functions/document-import/index.ts"
$documentImportProductionPath = Join-Path $workspace `
    "supabase/functions/document-import/production.ts"

foreach ($path in @(
    $manifestPath,
    $workflowPath,
    $predeployPath,
    $migrationPlanPath,
    $previewProvenancePath,
    $migrationPolicyPath,
    $cleanupPath,
    $cleanupMigrationPath,
    $documentImportIndexPath,
    $documentImportProductionPath
)) {
    Assert-Contract (Test-Path -LiteralPath $path -PathType Leaf) `
        "Required readiness artifact is missing: $path"
}

Assert-PowerShellSyntax $predeployPath
Assert-PowerShellSyntax $migrationPlanPath
Assert-PowerShellSyntax $previewProvenancePath
Assert-PowerShellSyntax $cleanupPath
Assert-PowerShellSyntax $PSCommandPath
& $migrationPlanPath -ClassifierSelfTest
Assert-Contract $true `
    "Automatic-migration classifier self-test did not complete."

$provenanceTempRoot = Join-Path ([IO.Path]::GetTempPath()) `
    "supabase-preview-provenance-$([guid]::NewGuid().ToString('N'))"
[void][IO.Directory]::CreateDirectory($provenanceTempRoot)
try {
    $metadataPath = Join-Path $provenanceTempRoot "workflow-run.json"
    $artifactDirectory = Join-Path $provenanceTempRoot "artifact"
    [void][IO.Directory]::CreateDirectory($artifactDirectory)
    $planPath = Join-Path $artifactDirectory "migration-plan.json"
    $fixtureSha = "a" * 40
    $fixtureProjectRef = "abcdefghijklmnopqrst"
    $fixtureRunId = "12345"
    $fixtureWorkflowId = "67890"
    $fixtureRepository = "example/university_schedule_app"
    $fixtureBranch = "feature/portfolio-v0.6-production-readiness"
    $metadata = [ordered]@{
        id = [long]$fixtureRunId
        workflow_id = [long]$fixtureWorkflowId
        path = ".github/workflows/supabase-deploy.yml@$fixtureBranch"
        event = "workflow_dispatch"
        status = "completed"
        conclusion = "success"
        head_sha = $fixtureSha
        head_branch = $fixtureBranch
        display_title = "Supabase staging preview @ $fixtureSha"
        run_attempt = 1
        repository = [ordered]@{ full_name = $fixtureRepository }
    }
    $plan = [ordered]@{
        schemaVersion = 1
        environment = "staging"
        projectRef = $fixtureProjectRef
        deploySha = $fixtureSha
        baselineRemoteVersion = "202608110015"
        pendingMigrations = @(
            [ordered]@{
                version = "202608220016"
                file = "202608220016_document_cleanup_operations.sql"
                sha256 = "b" * 64
                classification = "additive-reviewed"
            }
        )
    }
    [IO.File]::WriteAllText(
        $metadataPath,
        ($metadata | ConvertTo-Json -Depth 6 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        $planPath,
        ($plan | ConvertTo-Json -Depth 6 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    $fixturePlanDigest = (
        Get-FileHash -Algorithm SHA256 -LiteralPath $planPath
    ).Hash.ToLowerInvariant()
    $commonArguments = @{
        Environment = "staging"
        DeploySha = $fixtureSha
        DeployBranch = $fixtureBranch
        Repository = $fixtureRepository
        PreviewRunId = $fixtureRunId
        ExpectedWorkflowId = $fixtureWorkflowId
        WorkflowRunMetadataPath = $metadataPath
    }

    & $previewProvenancePath @commonArguments -MetadataOnly
    Assert-Contract $true "Successful preview metadata was rejected."
    & $previewProvenancePath @commonArguments `
        -ProjectRef $fixtureProjectRef `
        -PreviewPlanPath $planPath `
        -ExpectedPlanSha256 $fixturePlanDigest
    Assert-Contract $true "Successful preview artifact was rejected."

    $metadata.conclusion = "failure"
    $metadata.display_title = "Supabase staging apply @ $fixtureSha"
    [IO.File]::WriteAllText(
        $metadataPath,
        ($metadata | ConvertTo-Json -Depth 6 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    try {
        & $previewProvenancePath @commonArguments -MetadataOnly
        throw "A failed apply run was accepted as preview provenance."
    }
    catch {
        Assert-Contract (
            $_.Exception.Message.Contains(
                "Preview workflow run was not successful.",
                [StringComparison]::Ordinal
            )
        ) "Failed-apply laundering did not fail closed."
    }

    $metadata.conclusion = "success"
    $metadata.display_title = "Supabase staging preview @ $fixtureSha"
    [IO.File]::WriteAllText(
        $metadataPath,
        ($metadata | ConvertTo-Json -Depth 6 -Compress),
        [Text.UTF8Encoding]::new($false)
    )
    $digestOnlyArguments = $commonArguments.Clone()
    $digestOnlyArguments.PreviewRunId = "12346"
    try {
        & $previewProvenancePath @digestOnlyArguments -MetadataOnly
        throw "A digest without matching preview provenance was accepted."
    }
    catch {
        Assert-Contract (
            $_.Exception.Message.Contains(
                "Preview workflow run ID did not match.",
                [StringComparison]::Ordinal
            )
        ) "Digest-only apply did not fail closed."
    }

    try {
        & $previewProvenancePath @commonArguments `
            -ProjectRef $fixtureProjectRef `
            -PreviewPlanPath $planPath `
            -ExpectedPlanSha256 ("0" * 64)
        throw "A preview artifact with an unapproved digest was accepted."
    }
    catch {
        Assert-Contract (
            $_.Exception.Message.Contains(
                "Preview artifact digest did not match the approved digest.",
                [StringComparison]::Ordinal
            )
        ) "Preview artifact digest mismatch did not fail closed."
    }
}
finally {
    if (Test-Path -LiteralPath $provenanceTempRoot -PathType Container) {
        [IO.Directory]::Delete($provenanceTempRoot, $true)
    }
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
Assert-Contract ($manifest.schemaVersion -eq 1) `
    "Deployment manifest schema must be version 1."
Assert-Contract ($manifest.supabaseCliVersion -match '^\d+\.\d+\.\d+$') `
    "Supabase CLI must be pinned to an exact version."
$stagingRef = [string]$manifest.environments.staging.projectRef
$productionRef = [string]$manifest.environments.production.projectRef
Assert-Contract (
    $stagingRef -ceq "SET_STAGING_PROJECT_REF" -or
    $stagingRef -cmatch '^[a-z0-9]{20}$'
) "Staging project ref must be a fail-closed placeholder or an exact reviewed ref."
Assert-Contract (
    $productionRef -ceq "SET_PRODUCTION_PROJECT_REF" -or
    $productionRef -cmatch '^[a-z0-9]{20}$'
) "Production project ref must be a fail-closed placeholder or an exact reviewed ref."
if ($stagingRef -cmatch '^[a-z0-9]{20}$' -and
    $productionRef -cmatch '^[a-z0-9]{20}$') {
    Assert-Contract ($stagingRef -cne $productionRef) `
        "Staging and production project refs must be different."
}
Assert-Contract (
    $manifest.environments.staging.allowDemoOrFake -eq $false -and
    $manifest.environments.production.allowDemoOrFake -eq $false
) "Deployed environments must prohibit demo and fake modes."
Assert-Contract (
    $manifest.environments.production.requiresProductionConfirmation -eq $true
) "Production must require an explicit confirmation."
Assert-Contract (
    @($manifest.environments.production.allowedBranches).Count -eq 1 -and
    $manifest.environments.production.allowedBranches[0] -ceq "master"
) "Production must be restricted to master."
Assert-Contract (
    (@($manifest.requiredFunctions) -join ',') -ceq
        'university-email-verification,email-import,document-import'
) "The Edge Function deployment allowlist changed unexpectedly."
Assert-Contract (
    (@($manifest.requiredSecretNames) | Sort-Object -Unique).Count -eq
        @($manifest.requiredSecretNames).Count
) "Required Edge secret names must be unique."
Assert-Contract (
    @($manifest.requiredSecretNames | Where-Object { $_ -cmatch '^SUPABASE_' }).Count -eq 0
) "Supabase-provided reserved names must not be declared as custom secrets."

$documentImportSource = @(
    Get-Content -Raw -LiteralPath $documentImportIndexPath
    Get-Content -Raw -LiteralPath $documentImportProductionPath
) -join "`n"
$documentCustomEnvironmentNames = @(
    [regex]::Matches(
        $documentImportSource,
        '"(?<name>(?:APP_|DOCUMENT_IMPORT_|OPENAI_)[A-Z0-9_]+)"'
    ) | ForEach-Object { $_.Groups['name'].Value } | Sort-Object -Unique
)
foreach ($name in $documentCustomEnvironmentNames) {
    Assert-Contract ($manifest.requiredSecretNames -ccontains $name) `
        "Document import custom environment name is missing from the deployment manifest: $name"
}

$workflow = Get-Content -Raw -LiteralPath $workflowPath
$onStart = $workflow.IndexOf("on:`n", [StringComparison]::Ordinal)
$permissionsStart = $workflow.IndexOf("permissions:`n", [StringComparison]::Ordinal)
Assert-Contract ($onStart -ge 0 -and $permissionsStart -gt $onStart) `
    "Workflow trigger block is malformed."
$triggerBlock = $workflow.Substring($onStart, $permissionsStart - $onStart)
Assert-Contract ($triggerBlock -match '(?m)^\s+workflow_dispatch:\s*$') `
    "Deployment workflow must be manual-only."
Assert-Contract (
    $triggerBlock -notmatch '(?m)^\s+(pull_request|push|schedule):'
) "Deployment workflow must not run from PR, push, or schedule events."
Assert-Contract (
    $workflow -match "github\.event\.repository\.fork == false"
) "Fork-originated jobs must be rejected before secret-bearing work."
Assert-Contract (
    $workflow -match 'environment:\s*\r?\n\s+name: \$\{\{ inputs\.environment \}\}'
) "Deploy job must use the selected protected GitHub Environment."
Assert-Contract (
    $workflow -match "DEPLOY_SHA.*DISPATCH_SHA" -and
    $workflow -match 'deploy_sha must exactly match the selected workflow ref HEAD'
) "Workflow must bind deploy_sha to the dispatch ref HEAD."
Assert-Contract (
    $workflow -match "refs/heads/master" -and
    $workflow -match "DEPLOY_PRODUCTION"
) "Production branch and exact confirmation guards are required."
Assert-Contract (
    $workflow -match 'repos/\$\{REPOSITORY\}/environments/\$\{DEPLOY_ENVIRONMENT\}' -and
    $workflow -match 'required_reviewers' -and
    $workflow -match 'prevent_self_review == true' -and
    $workflow -match 'deployment_branch_policy' -and
    $workflow -match 'Every deployment Environment requires reviewers' -and
    $workflow -match 'Every deployment Environment requires a deployment branch policy'
) "Guard must verify protection metadata for every deployment Environment."
Assert-Contract (
    $workflow -notmatch '(?ms)if\s+\[\[\s+"\$DEPLOY_ENVIRONMENT"\s+==\s+''production''\s+\]\];\s+then\s+reviewer_rules='
) "Staging must not bypass reviewer, self-review, or branch-policy enforcement."
Assert-Contract (
    ([regex]::Matches($workflow, 'persist-credentials:\s*false')).Count -eq 3
) "Every checkout must disable persisted Git credentials."
Assert-Contract (
    ([regex]::Matches(
        $workflow,
        'uses:\s+(?:actions/checkout|denoland/setup-deno|supabase/setup-cli)@[0-9a-f]{40}(?:\s+#\s+v[0-9.]+)?'
    )).Count -eq 6
) "All checkout and tool-setup actions must use immutable commit SHAs."
$allActionUses = @(
    [regex]::Matches($workflow, '(?m)^\s*(?:-\s+)?uses:\s+[^\s]+') |
        ForEach-Object { $_.Value }
)
$pinnedActionUses = @(
    [regex]::Matches(
        $workflow,
        '(?m)^\s*(?:-\s+)?uses:\s+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}(?:\s+#\s+v[0-9.]+)?\s*$'
    )
)
Assert-Contract (
    $allActionUses.Count -eq 8 -and
    $pinnedActionUses.Count -eq $allActionUses.Count -and
    $workflow -match 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' -and
    $workflow -match 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
) "Every third-party Action, including preview artifact transfer, must use an immutable commit SHA."
Assert-Contract (
    $workflow -match '(?ms)^permissions:\s*\r?\n\s+actions:\s+read\s*\r?\n\s+contents:\s+read\s*$' -and
    $workflow -notmatch '(?m)^\s+(actions|deployments|id-token|packages|pull-requests):\s+write'
) "Workflow permissions must grant only the read scopes required by the guard."
Assert-Contract (
    $workflow -match [regex]::Escape("version: $($manifest.supabaseCliVersion)")
) "Workflow Supabase CLI pin must match the manifest."
$dryRunIndex = $workflow.IndexOf(
    "supabase db push --dry-run --linked",
    [StringComparison]::Ordinal
)
$applyIndex = $workflow.IndexOf(
    "supabase db push --linked",
    [StringComparison]::Ordinal
)
Assert-Contract ($dryRunIndex -ge 0 -and $applyIndex -gt $dryRunIndex) `
    "Migration dry-run must precede the reviewed migration apply step."
$runtimeBindingIndex = $workflow.IndexOf(
    "supabase secrets set",
    [StringComparison]::Ordinal
)
$functionDeployIndex = $workflow.IndexOf(
    "supabase functions deploy",
    [StringComparison]::Ordinal
)
Assert-Contract (
    $runtimeBindingIndex -gt $applyIndex -and
    $functionDeployIndex -gt $runtimeBindingIndex
) "Reviewed migrations must precede exact runtime binding and function deploy."
Assert-Contract (
    $workflow -match '"APP_ENV=\$DEPLOY_ENVIRONMENT"' -and
    $workflow -match '"APP_SUPABASE_PROJECT_REF=\$SUPABASE_PROJECT_REF"' -and
    $workflow -match "'DOCUMENT_IMPORT_FAKE_ENABLED=false'" -and
    $workflow -match "'DOCUMENT_IMPORT_PROVIDER=openai_responses'" -and
    $workflow -match '--project-ref "\$SUPABASE_PROJECT_REF" >/dev/null 2>&1'
) "Edge runtime environment/ref/provider bindings must be exact and output-suppressed."
$staticVerifierIndex = $workflow.IndexOf("-StaticOnly", [StringComparison]::Ordinal)
$localVerifierIndex = $workflow.IndexOf("-LocalOnly", [StringComparison]::Ordinal)
$linkIndex = $workflow.IndexOf("supabase link", [StringComparison]::Ordinal)
$remoteVerifierIndex = $workflow.IndexOf("-RemoteOnly", [StringComparison]::Ordinal)
Assert-Contract (
    $staticVerifierIndex -ge 0 -and
    $localVerifierIndex -gt $staticVerifierIndex -and
    $linkIndex -gt $localVerifierIndex -and
    $remoteVerifierIndex -gt $linkIndex -and
    $dryRunIndex -gt $remoteVerifierIndex
) "Static/local checks must precede link, then remote inventory and migration preview."
$localJob = [regex]::Match(
    $workflow,
    '(?ms)^  verify-local:\s*$(?<body>.*?)(?=^  deploy-remote:)'
)
$remoteJob = [regex]::Match(
    $workflow,
    '(?ms)^  deploy-remote:\s*$(?<body>.*)\z'
)
Assert-Contract (
    $localJob.Success -and
    $localJob.Groups['body'].Value -notmatch
        'environment:\s*\r?\n\s+name:|secrets\.|SUPABASE_ACCESS_TOKEN|SUPABASE_DB_PASSWORD'
) "Local verification must run in a separate job without protected credentials."
Assert-Contract (
    $remoteJob.Success -and
    $remoteJob.Groups['body'].Value -notmatch
        'denoland/setup-deno|supabase start|db reset --local|deno test|flutter test'
) "The protected remote job must not execute the local dependency/test stack."
Assert-Contract (
    $workflow -notmatch '(?ms)^  deploy-remote:.*?^    env:\s*\r?\n\s+SUPABASE_(?:ACCESS_TOKEN|DB_PASSWORD):'
) "Deployment credentials must not be job-wide."
$localWorkflowStep = [regex]::Match(
    $workflow,
    '(?ms)^      - name: Run local quality gates without deployment credentials\s*$(?<body>.*?)(?=^      - name:)'
)
Assert-Contract (
    $localWorkflowStep.Success -and
    $localWorkflowStep.Groups['body'].Value -notmatch
        'secrets\.|SUPABASE_ACCESS_TOKEN|SUPABASE_DB_PASSWORD'
) "Local database and Deno gates must not receive deployment credentials."
Assert-Contract (
    $workflow -match 'options:\s*\r?\n\s+- preview\s*\r?\n\s+- apply' -and
    $workflow -match 'preview_run_id:' -and
    $workflow -match 'migration_plan_sha256:' -and
    $workflow -match 'Apply requires a successful preview workflow run ID' -and
    $workflow -match 'APPLY_\$\{DEPLOY_ENVIRONMENT\^\^\}' -and
    $workflow -match "if: inputs.operation == 'apply'" -and
    $workflow -match 'Migration plan changed after preview'
) "Apply must be a separate dispatch bound to a successful preview run and exact plan digest."
Assert-Contract (
    $workflow -match 'verify_supabase_migration_plan\.ps1' -and
    $workflow -match 'supabase db push --dry-run --linked' -and
    $workflow -match 'Publish immutable preview plan artifact' -and
    $workflow -match 'read-only preview only; no migration, secret, or function mutation'
) "Preview must publish a non-mutating exact migration plan before apply."
Assert-Contract (
    $workflow -match 'actions/runs/\$\{PREVIEW_RUN_ID\}' -and
    $workflow -match 'verify_supabase_preview_provenance\.ps1' -and
    $workflow -match 'supabase-migration-plan-\$\{\{ inputs\.preview_run_id \}\}' -and
    $workflow -match 'run-id:\s*\$\{\{ inputs\.preview_run_id \}\}' -and
    $workflow -match 'ExpectedPlanSha256 \$env:MIGRATION_PLAN_SHA256'
) "Apply must verify Actions API provenance and the exact preview artifact binding."
Assert-Contract (
    $workflow -match "(?ms)- name: Publish immutable preview plan artifact\s*\r?\n\s*if: inputs\.operation == 'preview'.*?name: supabase-migration-plan-\$\{\{ github\.run_id \}\}" -and
    $workflow -notmatch '(?m)^\s*overwrite:\s*true\s*$'
) "Only preview may publish a run-bound immutable migration-plan artifact."
$buildPlanStep = [regex]::Match(
    $workflow,
    '(?ms)^      - name: Build exact additive migration plan\s*$(?<body>.*?)(?=^      - name:)'
)
Assert-Contract (
    $buildPlanStep.Success -and
    $buildPlanStep.Groups['body'].Value -match
        '(?ms)if \(\$env:DEPLOY_OPERATION -ceq ''preview''\).*?Write-Host "MigrationPlanSha256=\$digest".*?Write-Host \(Get-Content' -and
    ([regex]::Matches(
        $buildPlanStep.Groups['body'].Value,
        '(?m)^\s*Write-Host "MigrationPlanSha256=\$digest"\s*$'
    )).Count -eq 1
) "Apply must not disclose its newly computed digest or full plan before provenance validation."
$guardJob = [regex]::Match(
    $workflow,
    '(?ms)^  guard:\s*$(?<body>.*?)(?=^  verify-local:)'
)
Assert-Contract (
    $guardJob.Success -and
    $guardJob.Groups['body'].Value -match 'Verify successful preview run provenance' -and
    $guardJob.Groups['body'].Value -match 'Verify preview artifact target and digest binding'
) "Successful-preview provenance must fail closed before the protected remote job starts."

$forbiddenWorkflowPatterns = @(
    '(?im)\bsupabase\s+db\s+reset\s+--linked\b',
    '(?im)\bsupabase\s+migration\s+repair\b',
    '(?im)\bsupabase\s+db\s+push\b[^\r\n]*--include-seed\b',
    '(?im)\bsupabase\s+functions\s+deploy\b[\s\S]*?--prune\b',
    '(?im)\bsupabase\s+functions\s+deploy\b[\s\S]*?--no-verify-jwt\b',
    '(?im)\bTRUNCATE\b',
    '(?im)\bDROP\s+(DATABASE|SCHEMA|TABLE)\b'
)
foreach ($pattern in $forbiddenWorkflowPatterns) {
    Assert-Contract (-not [regex]::IsMatch($workflow, $pattern)) `
        "Workflow contains a forbidden destructive deployment operation."
}

$functionDeploy = [regex]::Match(
    $workflow,
    '(?ms)supabase functions deploy\s+(?<body>.*?)\s+--use-api'
)
Assert-Contract $functionDeploy.Success `
    "Explicit Edge Function deployment command is missing."
foreach ($functionName in $manifest.requiredFunctions) {
    Assert-Contract (
        $functionDeploy.Groups['body'].Value -match
            "(?m)^\s*$([regex]::Escape($functionName))\s*\\?\s*$"
    ) "Edge Function allowlist is missing $functionName."
}
Assert-Contract (
    $workflow -match 'supabase functions list' -and
    $workflow -match '/auth/v1/health'
) "Post-deploy Auth and Edge Function inventory checks are required."

$predeploy = Get-Content -Raw -LiteralPath $predeployPath
Assert-Contract (
    $predeploy -match 'supabase/.temp/project-ref' -and
    $predeploy -match 'ProjectRef does not match the selected environment allowlist'
) "Pre-deploy verifier must bind both manifest and linked project refs."
Assert-Contract (
    $predeploy -match 'secrets", "list"' -and
    $predeploy -match 'PRESENT' -and
    $predeploy -match 'MISSING'
) "Pre-deploy verifier must inspect and report secret names only."
Assert-Contract (
    $predeploy -match 'db", "reset", "--local"' -and
    $predeploy -notmatch 'db", "reset", "--linked"'
) "Pre-deploy reset must remain local-only."
Assert-Contract (
    $predeploy -match '\[switch\]\$LocalOnly' -and
    $predeploy -match '\[switch\]\$RemoteOnly' -and
    $predeploy -match 'Local verification must not receive SUPABASE_ACCESS_TOKEN' -and
    $predeploy -match 'Local verification must not receive SUPABASE_DB_PASSWORD'
) "Local and remote pre-deploy phases must be separated and secret-fail-closed."

$migrationPolicy = Get-Content -Raw -LiteralPath $migrationPolicyPath |
    ConvertFrom-Json
Assert-Contract (
    $migrationPolicy.schemaVersion -eq 1 -and
    $migrationPolicy.baselineRemoteVersion -cmatch '^\d{12,14}$' -and
    @($migrationPolicy.automaticMigrations).Count -gt 0
) "Automatic migration policy must declare a reviewed remote baseline and allowlist."
$migrationPlan = Get-Content -Raw -LiteralPath $migrationPlanPath
Assert-Contract (
    $migrationPlan -match 'Pending migration \$version is not approved' -and
    $migrationPlan -match 'requires the reviewed remote baseline' -and
    $migrationPlan -match 'additive-reviewed' -and
    $migrationPlan -match 'drop\\s\+\(database\|schema\|table\|view' -and
    $migrationPlan -match 'delete\\s\+from\|update\\s\+' -and
    $migrationPlan -match 'disable\\s\+row\\s\+level\\s\+security' -and
    $migrationPlan -match 'set\\s\+not\\s\+null' -and
    $migrationPlan -match 'anon\|authenticated\|public'
) "Regular deploy must reject unapproved, baseline-mismatched, or destructive migrations."
Assert-Contract (
    $predeploy -match 'DROP\\s\+\(DATABASE\|SCHEMA\|TABLE\|TYPE\)' -and
    $predeploy -match 'DROP\\s\+COLUMN'
) "Pre-deploy verifier must reject high-risk destructive migration DDL."

$cleanup = Get-Content -Raw -LiteralPath $cleanupPath
Assert-Contract ($cleanup -match 'ValidateSet\("staging"\)') `
    "Manual cleanup script must remain staging-only."
Assert-Contract (
    $cleanup -match 'DELETE_STAGING_DOCUMENTS' -and
    $cleanup -match '\[ValidateRange\(1, 500\)\]'
) "Manual cleanup requires an exact confirmation and bounded limit."
Assert-Contract (
    $cleanup -match 'storage/v1/object/\$bucketName' -and
    $cleanup -notmatch '(?im)delete\s+from\s+storage\.objects'
) "Manual cleanup must delete objects only through the Storage API."
Assert-Contract (
    $cleanup -notmatch '(?im)(Write-Host|Write-Output|Write-Warning).*serviceRoleKey'
) "Manual cleanup must never print the service-role key."
Assert-Contract (
    $cleanup -notmatch '(?m)^\s*\[string\]\$ManifestPath' -and
    $cleanup -match 'Document cleanup requires a clean worktree' -and
    $cleanup -match 'allowedBranches' -and
    $cleanup -match 'AllowAutoRedirect = \$false' -and
    $cleanup -match 'Get-ServiceRoleKeyKind'
) "Manual cleanup must bind the tracked manifest and fail closed on identity or redirects."
Assert-Contract (
    $cleanup -match 'return "opaque-secret"' -and
    $cleanup -match 'return "legacy-service-role-jwt"' -and
    $cleanup -match '(?ms)TryAddWithoutValidation\("apikey", \$serviceRoleKey\).*?if \(\$serviceRoleKeyKind -ceq "legacy-service-role-jwt"\).*?DefaultRequestHeaders\.Authorization' -and
    $cleanup -notmatch '(?ms)if \(\$serviceRoleKeyKind -ceq "opaque-secret"\).*?DefaultRequestHeaders\.Authorization'
) "Opaque secret keys must use apikey only; only legacy service-role JWTs may use Bearer."
Assert-Contract (
    $cleanup -match 'preview_expired_document_sources' -and
    $cleanup -match 'begin_document_cleanup_run' -and
    $cleanup -match 'finish_document_cleanup_run' -and
    $cleanup -match 'get_document_cleanup_run'
) "Manual cleanup must preview and write a count-only audit lifecycle."

$cleanupMigration = Get-Content -Raw -LiteralPath $cleanupMigrationPath
Assert-Contract (
    $cleanupMigration -match '(?ms)preview_expired_document_sources.*?stable' -and
    $cleanupMigration -match "role'.*?service_role"
) "Cleanup preview must be stable and service-role-only."
Assert-Contract (
    $cleanupMigration -match 'document_cleanup_runs' -and
    $cleanupMigration -match 'Never stores owner IDs, Storage paths' -and
    $cleanupMigration -match 'get_document_cleanup_run'
) "Cleanup migration must define the count-only audit contract."
Assert-Contract (
    $cleanupMigration -notmatch '(?im)delete\s+from\s+storage\.objects'
) "Cleanup migration must never delete Storage metadata through SQL."

Write-Host "Supabase deployment guard tests: $assertionCount/$assertionCount PASS"
