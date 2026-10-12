$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$verifier = Join-Path $PSScriptRoot "verify_supabase_migration_plan.ps1"
$assertions = 0

function Assert-Contract {
    param(
        [Parameter(Mandatory)] [bool]$Condition,
        [Parameter(Mandatory)] [string]$Message
    )
    if (-not $Condition) {
        throw "Supabase migration plan contract failed: $Message"
    }
    $script:assertions += 1
}

function Write-Inventory {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string[]]$Rows
    )
    $text = @(
        "   Local        | Remote       | Time (UTC)"
        "  --------------|--------------|--------------"
        $Rows
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
}

function Assert-VerifierFails {
    param(
        [Parameter(Mandatory)] [string]$InventoryPath,
        [Parameter(Mandatory)] [string]$PlanPath,
        [Parameter(Mandatory)] [string]$ExpectedMessage
    )
    try {
        & $verifier `
            -Environment staging `
            -ProjectRef abcdefghijklmnopqrst `
            -DeploySha ("a" * 40) `
            -MigrationInventoryPath $InventoryPath `
            -PlanOutputPath $PlanPath
    }
    catch {
        Assert-Contract `
            ($_.Exception.Message.Contains($ExpectedMessage, [StringComparison]::Ordinal)) `
            "Unexpected failure: $($_.Exception.Message)"
        return
    }
    throw "Expected migration verifier failure containing: $ExpectedMessage"
}

Assert-Contract (Test-Path -LiteralPath $verifier -PathType Leaf) `
    "Migration verifier is missing."

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) `
    "supabase-migration-plan-$([guid]::NewGuid().ToString('N'))"
[void][IO.Directory]::CreateDirectory($tempRoot)
try {
    $inventory = Join-Path $tempRoot "inventory.txt"
    $plan = Join-Path $tempRoot "plan.json"

    Write-Inventory -Path $inventory -Rows @(
        "   202608110015 | 202608110015 | 202608110015",
        "   202608220016 |                | 202608220016"
    )
    & $verifier `
        -Environment staging `
        -ProjectRef abcdefghijklmnopqrst `
        -DeploySha ("a" * 40) `
        -MigrationInventoryPath $inventory `
        -PlanOutputPath $plan
    $decoded = Get-Content -Raw -LiteralPath $plan | ConvertFrom-Json
    Assert-Contract ($decoded.schemaVersion -eq 1) "Plan schema is not exact."
    Assert-Contract ($decoded.environment -ceq "staging") "Plan target is not bound."
    Assert-Contract ($decoded.projectRef -ceq "abcdefghijklmnopqrst") `
        "Plan project ref is not bound."
    Assert-Contract ($decoded.deploySha -ceq ("a" * 40)) "Plan SHA is not bound."
    Assert-Contract (@($decoded.pendingMigrations).Count -eq 1) `
        "Expected one approved pending migration."
    Assert-Contract ($decoded.pendingMigrations[0].version -ceq "202608220016") `
        "Pending migration version changed."
    Assert-Contract ($decoded.pendingMigrations[0].sha256 -cmatch '^[0-9a-f]{64}$') `
        "Pending migration source hash is missing."

    Write-Inventory -Path $inventory -Rows @(
        "   202608110015 | 202608110015 | 202608110015",
        "   202608230017 |                | 202608230017"
    )
    Assert-VerifierFails `
        -InventoryPath $inventory `
        -PlanPath $plan `
        -ExpectedMessage "is not approved for automatic deployment"

    Write-Inventory -Path $inventory -Rows @(
        "   202608220016 |                | 202608220016"
    )
    Assert-VerifierFails `
        -InventoryPath $inventory `
        -PlanPath $plan `
        -ExpectedMessage "requires the reviewed remote baseline"

    Write-Inventory -Path $inventory -Rows @(
        "                  | 202608110015 | 202608110015"
    )
    Assert-VerifierFails `
        -InventoryPath $inventory `
        -PlanPath $plan `
        -ExpectedMessage "Remote-only migration history"

    & $verifier -ClassifierSelfTest
    Assert-Contract $true "Classifier self-test did not complete."
}
finally {
    if (Test-Path -LiteralPath $tempRoot -PathType Container) {
        [IO.Directory]::Delete($tempRoot, $true)
    }
}

Write-Host "Supabase migration plan contract tests: $assertions/$assertions PASS"
