[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("staging", "production")]
    [string]$Environment,

    [Parameter(Mandatory)]
    [string]$ProjectRef,

    [Parameter(Mandatory)]
    [string]$ExpectedSha,

    [Parameter(Mandatory)]
    [string]$ExpectedBranch,

    [string]$ProductionConfirmation = "",

    [switch]$StaticOnly,

    [switch]$LocalOnly,

    [switch]$RemoteOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$selectedPhases = @(
    @($StaticOnly, $LocalOnly, $RemoteOnly) |
        Where-Object { $_.IsPresent }
).Count
if ($selectedPhases -ne 1) {
    throw "Select exactly one verification phase: -StaticOnly, -LocalOnly, or -RemoteOnly."
}

$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$manifestPath = (Resolve-Path -LiteralPath (
        Join-Path $workspace "supabase/deployment/environments.json"
    )).Path

function Assert-Condition {
    param(
        [Parameter(Mandatory)] [bool]$Condition,
        [Parameter(Mandatory)] [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-CheckedNative {
    param(
        [Parameter(Mandatory)] [string]$FilePath,
        [Parameter()] [string[]]$ArgumentList = @(),
        [Parameter()] [switch]$Capture
    )

    if ($Capture) {
        $captured = @(& $FilePath @ArgumentList 2>&1)
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "Command failed with exit code ${exitCode}: $FilePath"
        }
        return ($captured | Out-String)
    }

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($ArgumentList -join ' ')"
    }
}

function Assert-CleanWorktree {
    $status = Invoke-CheckedNative "git" @(
        "status", "--porcelain=v1", "--untracked-files=all"
    ) -Capture
    Assert-Condition ([string]::IsNullOrWhiteSpace($status)) `
        "The deployment worktree must be clean."
}

function Assert-DeploymentWorkflowSafety {
    $workflowPath = Join-Path $workspace ".github/workflows/supabase-deploy.yml"
    Assert-Condition (Test-Path -LiteralPath $workflowPath -PathType Leaf) `
        "The guarded Supabase deployment workflow is missing."
    $workflow = Get-Content -Raw -LiteralPath $workflowPath
    $forbiddenPatterns = @(
        '(?im)\bsupabase\s+db\s+reset\s+--linked\b',
        '(?im)\bsupabase\s+migration\s+repair\b',
        '(?im)\bsupabase\s+db\s+push\b[^\r\n]*--include-seed\b',
        '(?im)\bsupabase\s+functions\s+deploy\b[^\r\n]*--prune\b',
        '(?im)\bsupabase\s+functions\s+deploy\b[^\r\n]*--no-verify-jwt\b',
        '(?im)\bTRUNCATE\b',
        '(?im)\bDROP\s+(DATABASE|SCHEMA|TABLE)\b'
    )
    foreach ($pattern in $forbiddenPatterns) {
        Assert-Condition (-not [regex]::IsMatch($workflow, $pattern)) `
            "The deployment workflow contains a forbidden destructive operation."
    }
}

function Assert-MigrationOrdering {
    $migrationDirectory = Join-Path $workspace "supabase/migrations"
    $files = @(Get-ChildItem -LiteralPath $migrationDirectory -File -Filter "*.sql")
    Assert-Condition ($files.Count -gt 0) "No Supabase migrations were found."

    $versions = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::Ordinal
    )
    $previousName = ""
    $highRiskPatterns = @(
        '(?im)^\s*DROP\s+(DATABASE|SCHEMA|TABLE|TYPE)\b',
        '(?im)^\s*TRUNCATE\b',
        '(?im)^\s*ALTER\s+TABLE\b[^;]*\bDROP\s+COLUMN\b'
    )
    foreach ($file in ($files | Sort-Object -Property Name)) {
        $match = [regex]::Match(
            $file.Name,
            '^(?<version>[0-9]{12,14})_[a-z0-9_]+\.sql$'
        )
        Assert-Condition $match.Success `
            "Invalid migration filename: $($file.Name)"
        Assert-Condition ($versions.Add($match.Groups['version'].Value)) `
            "Duplicate migration version: $($match.Groups['version'].Value)"
        if ($previousName.Length -gt 0) {
            Assert-Condition `
                ([StringComparer]::Ordinal.Compare($previousName, $file.Name) -lt 0) `
                "Migration filenames are not strictly ordered."
        }
        $previousName = $file.Name

        $migrationSql = Get-Content -Raw -LiteralPath $file.FullName
        foreach ($pattern in $highRiskPatterns) {
            Assert-Condition (-not [regex]::IsMatch($migrationSql, $pattern)) `
                "High-risk destructive DDL requires a separate reviewed deployment path: $($file.Name)"
        }
    }
}

function Assert-FunctionJwtConfiguration {
    param([Parameter(Mandatory)] [string[]]$FunctionNames)

    $configPath = Join-Path $workspace "supabase/config.toml"
    $configuration = Get-Content -Raw -LiteralPath $configPath
    foreach ($functionName in $FunctionNames) {
        $sourcePath = Join-Path $workspace "supabase/functions/$functionName/index.ts"
        Assert-Condition (Test-Path -LiteralPath $sourcePath -PathType Leaf) `
            "Required Edge Function source is missing: $functionName"

        $escaped = [regex]::Escape($functionName)
        $section = [regex]::Match(
            $configuration,
            "(?ms)^\[functions\.$escaped\]\s*(?<body>.*?)(?=^\[|\z)"
        )
        Assert-Condition $section.Success `
            "Missing config.toml section for Edge Function: $functionName"
        Assert-Condition `
            ([regex]::IsMatch($section.Groups['body'].Value, '(?m)^verify_jwt\s*=\s*true\s*$')) `
            "verify_jwt must remain enabled for Edge Function: $functionName"
    }
}

Write-Host "==> Supabase deployment manifest"
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
Assert-Condition ($manifest.schemaVersion -eq 1) `
    "Unsupported deployment manifest schema version."
Assert-Condition ($manifest.supabaseCliVersion -match '^\d+\.\d+\.\d+$') `
    "The manifest must pin an exact Supabase CLI version."

$target = $manifest.environments.$Environment
Assert-Condition ($null -ne $target) `
    "The selected environment is absent from the deployment manifest."
Assert-Condition ($target.githubEnvironment -eq $Environment) `
    "GitHub Environment and selected environment do not match."
Assert-Condition ($target.allowDemoOrFake -eq $false) `
    "Demo or fake providers are forbidden for deployed environments."
Assert-Condition ($ProjectRef -cmatch '^[a-z0-9]{20}$') `
    "ProjectRef must be an exact 20-character Supabase project ref."
Assert-Condition ($target.projectRef -cmatch '^[a-z0-9]{20}$') `
    "The selected environment is not activated: replace its project-ref placeholder in the deployment manifest."
Assert-Condition ($ProjectRef -ceq $target.projectRef) `
    "ProjectRef does not match the selected environment allowlist."

$otherEnvironment = if ($Environment -eq "staging") { "production" } else { "staging" }
$otherTarget = $manifest.environments.$otherEnvironment
if ($otherTarget.projectRef -cmatch '^[a-z0-9]{20}$') {
    Assert-Condition ($ProjectRef -cne $otherTarget.projectRef) `
        "Staging and production must use different Supabase projects."
}

Assert-Condition ($ExpectedSha -cmatch '^[0-9a-f]{40}$') `
    "ExpectedSha must be a full lowercase Git SHA."
Assert-Condition (@($target.allowedBranches) -ccontains $ExpectedBranch) `
    "Branch '$ExpectedBranch' is not allowed for $Environment deployment."
if ($Environment -eq "production") {
    Assert-Condition ($target.requiresProductionConfirmation -eq $true) `
        "The production manifest must require explicit confirmation."
    Assert-Condition ($ProductionConfirmation -ceq "DEPLOY_PRODUCTION") `
        "Production confirmation must exactly equal DEPLOY_PRODUCTION."
    Assert-Condition ($ExpectedBranch -ceq "master") `
        "Production deployment is restricted to master."
}

Assert-Condition (@($manifest.requiredFunctions).Count -gt 0) `
    "The deployment function allowlist must not be empty."
Assert-Condition (@($manifest.requiredSecretNames).Count -gt 0) `
    "The required secret-name inventory must not be empty."
Assert-Condition `
    ((@($manifest.requiredSecretNames) | Sort-Object -Unique).Count -eq @($manifest.requiredSecretNames).Count) `
    "The required secret-name inventory contains duplicates."

Assert-MigrationOrdering
Assert-FunctionJwtConfiguration @($manifest.requiredFunctions)
Assert-DeploymentWorkflowSafety

Write-Host "==> Supabase CLI and repository identity"
$supabaseVersion = (Invoke-CheckedNative "supabase" @("--version") -Capture).Trim()
Assert-Condition ($supabaseVersion -ceq $manifest.supabaseCliVersion) `
    "Supabase CLI version mismatch. Expected $($manifest.supabaseCliVersion), received $supabaseVersion."

$actualSha = (Invoke-CheckedNative "git" @("rev-parse", "HEAD") -Capture).Trim()
Assert-Condition ($actualSha -ceq $ExpectedSha) `
    "Current Git SHA does not match the approved deployment SHA."
$actualBranch = (Invoke-CheckedNative "git" @("branch", "--show-current") -Capture).Trim()
if ($actualBranch.Length -gt 0) {
    Assert-Condition ($actualBranch -ceq $ExpectedBranch) `
        "Current branch does not match the approved deployment branch."
}
Assert-CleanWorktree

if ($StaticOnly) {
    Write-Host "Supabase static pre-deploy verification PASS (no remote calls)."
    exit 0
}

if ($LocalOnly) {
    Assert-Condition ([string]::IsNullOrWhiteSpace($env:SUPABASE_ACCESS_TOKEN)) `
        "Local verification must not receive SUPABASE_ACCESS_TOKEN."
    Assert-Condition ([string]::IsNullOrWhiteSpace($env:SUPABASE_DB_PASSWORD)) `
        "Local verification must not receive SUPABASE_DB_PASSWORD."
    Write-Host "==> Local database and Edge Function quality gates"
    $null = Invoke-CheckedNative "supabase" @("status") -Capture
    Invoke-CheckedNative "supabase" @("db", "reset", "--local")
    Invoke-CheckedNative "supabase" @("db", "lint", "--local")
    Invoke-CheckedNative "supabase" @("test", "db", "--local")
    Invoke-CheckedNative "bash" @(
        (Join-Path $workspace "scripts/run_mobile_schedule_sync_local_supabase.sh")
    )
    Invoke-CheckedNative "deno" @(
        "fmt", "--check",
        "supabase/functions/university-email-verification",
        "supabase/functions/email-import",
        "supabase/functions/document-import"
    )
    Invoke-CheckedNative "deno" @(
        "lint",
        "supabase/functions/university-email-verification",
        "supabase/functions/email-import",
        "supabase/functions/document-import"
    )
    Invoke-CheckedNative "deno" @(
        "check",
        "supabase/functions/university-email-verification/index.ts",
        "supabase/functions/email-import/index.ts",
        "supabase/functions/document-import/index.ts"
    )
    Invoke-CheckedNative "deno" @(
        "test", "--allow-env",
        "supabase/functions/university-email-verification/index_test.ts"
    )
    Invoke-CheckedNative "deno" @("test", "supabase/functions/email-import")
    Invoke-CheckedNative "deno" @("test", "supabase/functions/document-import")
    Assert-CleanWorktree
    Write-Host "Supabase local pre-deploy verification PASS at $ExpectedSha."
    exit 0
}

Write-Host "==> Linked project identity"
$linkedRefPath = Join-Path $workspace "supabase/.temp/project-ref"
Assert-Condition (Test-Path -LiteralPath $linkedRefPath -PathType Leaf) `
    "No linked Supabase project is available for the approved job."
$linkedRef = (Get-Content -Raw -LiteralPath $linkedRefPath).Trim()
Assert-Condition ($linkedRef -ceq $ProjectRef) `
    "The linked Supabase project does not match the selected environment."

Write-Host "==> Remote migration inventory"
Invoke-CheckedNative "supabase" @("migration", "list", "--linked")

Write-Host "==> Required Edge secret names"
Assert-Condition (-not [string]::IsNullOrWhiteSpace($env:SUPABASE_ACCESS_TOKEN)) `
    "SUPABASE_ACCESS_TOKEN is unavailable to the approved deployment job."
$secretJson = Invoke-CheckedNative "supabase" @(
    "secrets", "list", "--project-ref", $ProjectRef, "--output", "json"
) -Capture
try {
    $secretRows = @($secretJson | ConvertFrom-Json)
}
catch {
    throw "Unable to parse the secret-name inventory returned by Supabase."
}
$presentNames = @(
    $secretRows |
        ForEach-Object { $_.name } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)
$missingNames = @(
    $manifest.requiredSecretNames |
        Where-Object { @($presentNames) -cnotcontains $_ }
)
foreach ($secretName in $manifest.requiredSecretNames) {
    $state = if (@($presentNames) -ccontains $secretName) {
        "PRESENT"
    }
    else {
        "MISSING"
    }
    Write-Host "$secretName=$state"
}
Assert-Condition ($missingNames.Count -eq 0) `
    "One or more required Edge secret names are missing. Values were not read or displayed."

Write-Host "Supabase pre-deploy verification PASS for $Environment at $ExpectedSha."
