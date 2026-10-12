[CmdletBinding(DefaultParameterSetName = "Plan")]
param(
    [Parameter(Mandatory)]
    [ValidateSet("staging", "production")]
    [string]$Environment,

    [Parameter(Mandatory, ParameterSetName = "Plan")]
    [ValidatePattern('^[a-z0-9]{20}$')]
    [string]$ProjectRef,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$DeploySha,

    [Parameter(Mandatory)]
    [ValidateScript({
        $_.Length -ge 1 -and $_.Length -le 255 -and
        $_ -notmatch '[\x00-\x1f\x7f]'
    })]
    [string]$DeployBranch,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository,

    [Parameter(Mandatory)]
    [ValidatePattern('^[1-9][0-9]{0,19}$')]
    [string]$PreviewRunId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[1-9][0-9]{0,19}$')]
    [string]$ExpectedWorkflowId,

    [Parameter(Mandatory)]
    [string]$WorkflowRunMetadataPath,

    [Parameter(Mandatory, ParameterSetName = "Metadata")]
    [switch]$MetadataOnly,

    [Parameter(Mandatory, ParameterSetName = "Plan")]
    [string]$PreviewPlanPath,

    [Parameter(Mandatory, ParameterSetName = "Plan")]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ExpectedPlanSha256
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Condition {
    param(
        [Parameter(Mandatory)] [bool]$Condition,
        [Parameter(Mandatory)] [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-BoundedRegularFile {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [long]$MaximumBytes,
        [Parameter(Mandatory)] [string]$Label
    )

    Assert-Condition (Test-Path -LiteralPath $Path -PathType Leaf) `
        "$Label is missing."
    $item = Get-Item -LiteralPath $Path -Force
    Assert-Condition (
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0
    ) "$Label must be a regular file."
    Assert-Condition ($item.Length -ge 1 -and $item.Length -le $MaximumBytes) `
        "$Label exceeded its fail-closed size boundary."
    return $item
}

$metadataFile = Get-BoundedRegularFile `
    -Path $WorkflowRunMetadataPath `
    -MaximumBytes (512 * 1024) `
    -Label "Preview workflow metadata"
try {
    $metadata = Get-Content -Raw -LiteralPath $metadataFile.FullName |
        ConvertFrom-Json
}
catch {
    throw "Preview workflow metadata was not valid JSON."
}

$expectedTitle = "Supabase $Environment preview @ $DeploySha"
Assert-Condition ([string]$metadata.id -ceq $PreviewRunId) `
    "Preview workflow run ID did not match."
Assert-Condition ([string]$metadata.workflow_id -ceq $ExpectedWorkflowId) `
    "Preview provenance came from a different workflow."
$allowedWorkflowPaths = @(
    '.github/workflows/supabase-deploy.yml',
    ".github/workflows/supabase-deploy.yml@$DeployBranch"
)
Assert-Condition ($allowedWorkflowPaths -ccontains [string]$metadata.path) `
    "Preview provenance used an unexpected workflow path."
Assert-Condition ([string]$metadata.event -ceq 'workflow_dispatch') `
    "Preview provenance was not manually dispatched."
Assert-Condition ([string]$metadata.status -ceq 'completed') `
    "Preview workflow run has not completed."
Assert-Condition ([string]$metadata.conclusion -ceq 'success') `
    "Preview workflow run was not successful."
Assert-Condition ([string]$metadata.head_sha -ceq $DeploySha) `
    "Preview workflow SHA did not match apply."
Assert-Condition ([string]$metadata.head_branch -ceq $DeployBranch) `
    "Preview workflow branch did not match apply."
Assert-Condition ([string]$metadata.display_title -ceq $expectedTitle) `
    "Preview workflow operation or environment did not match apply."
Assert-Condition (
    $null -ne $metadata.repository -and
    [string]$metadata.repository.full_name -ceq $Repository
) "Preview workflow repository did not match apply."
$runAttempt = 0L
Assert-Condition (
    [long]::TryParse([string]$metadata.run_attempt, [ref]$runAttempt) -and
    $runAttempt -ge 1 -and $runAttempt -le 1000
) "Preview workflow attempt was invalid."

if ($MetadataOnly) {
    Write-Host "Supabase successful-preview metadata provenance PASS."
    exit 0
}

$planFile = Get-BoundedRegularFile `
    -Path $PreviewPlanPath `
    -MaximumBytes (1024 * 1024) `
    -Label "Preview migration plan"
Assert-Condition ($planFile.Name -ceq 'migration-plan.json') `
    "Preview artifact filename was not exact."
$artifactEntries = @(
    Get-ChildItem -LiteralPath $planFile.DirectoryName -Force -Recurse
)
Assert-Condition (
    $artifactEntries.Count -eq 1 -and
    $artifactEntries[0].FullName -ceq $planFile.FullName
) "Preview artifact must contain only the canonical migration plan."

$actualPlanSha256 = (
    Get-FileHash -Algorithm SHA256 -LiteralPath $planFile.FullName
).Hash.ToLowerInvariant()
Assert-Condition ($actualPlanSha256 -ceq $ExpectedPlanSha256) `
    "Preview artifact digest did not match the approved digest."

try {
    $plan = Get-Content -Raw -LiteralPath $planFile.FullName | ConvertFrom-Json
}
catch {
    throw "Preview migration plan was not valid JSON."
}
$expectedPlanFields = @(
    'baselineRemoteVersion',
    'deploySha',
    'environment',
    'pendingMigrations',
    'projectRef',
    'schemaVersion'
) | Sort-Object
$actualPlanFields = @($plan.PSObject.Properties.Name | Sort-Object)
Assert-Condition (
    ($actualPlanFields -join ',') -ceq ($expectedPlanFields -join ',')
) "Preview migration plan fields were not exact."
Assert-Condition ($plan.schemaVersion -eq 1) `
    "Preview migration plan schema was not supported."
Assert-Condition ([string]$plan.environment -ceq $Environment) `
    "Preview migration plan environment did not match apply."
Assert-Condition ([string]$plan.projectRef -ceq $ProjectRef) `
    "Preview migration plan project ref did not match the reviewed manifest."
Assert-Condition ([string]$plan.deploySha -ceq $DeploySha) `
    "Preview migration plan SHA did not match apply."
Assert-Condition (
    [string]$plan.baselineRemoteVersion -cmatch '^\d{12,14}$'
) "Preview migration plan baseline was invalid."

$pendingMigrations = @($plan.pendingMigrations)
Assert-Condition ($pendingMigrations.Count -le 1000) `
    "Preview migration plan contained too many pending migrations."
$seenVersions = [System.Collections.Generic.HashSet[string]]::new(
    [StringComparer]::Ordinal
)
foreach ($row in $pendingMigrations) {
    $expectedRowFields = @('classification', 'file', 'sha256', 'version') |
        Sort-Object
    $actualRowFields = @($row.PSObject.Properties.Name | Sort-Object)
    Assert-Condition (
        ($actualRowFields -join ',') -ceq ($expectedRowFields -join ',')
    ) "Preview migration row fields were not exact."
    $version = [string]$row.version
    Assert-Condition ($version -cmatch '^\d{12,14}$') `
        "Preview migration version was invalid."
    Assert-Condition ($seenVersions.Add($version)) `
        "Preview migration plan contained a duplicate version."
    Assert-Condition (
        [string]$row.file -cmatch "^$version`_[a-z0-9_]+\.sql$"
    ) "Preview migration filename was invalid."
    Assert-Condition ([string]$row.sha256 -cmatch '^[0-9a-f]{64}$') `
        "Preview migration hash was invalid."
    Assert-Condition ([string]$row.classification -ceq 'additive-reviewed') `
        "Preview migration classification was not approved."
}

Write-Host "Supabase successful-preview artifact provenance PASS."
