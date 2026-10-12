[CmdletBinding(DefaultParameterSetName = "Verify")]
param(
    [Parameter(Mandatory, ParameterSetName = "Verify")]
    [ValidateSet("staging", "production")]
    [string]$Environment,

    [Parameter(Mandatory, ParameterSetName = "Verify")]
    [ValidatePattern('^[a-z0-9]{20}$')]
    [string]$ProjectRef,

    [Parameter(Mandatory, ParameterSetName = "Verify")]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$DeploySha,

    [Parameter(Mandatory, ParameterSetName = "Verify")]
    [string]$MigrationInventoryPath,

    [Parameter(Mandatory, ParameterSetName = "Verify")]
    [string]$PlanOutputPath,

    [Parameter(Mandatory, ParameterSetName = "SelfTest")]
    [switch]$ClassifierSelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$migrationDirectory = Join-Path $workspace "supabase/migrations"
$policyPath = Join-Path $workspace "supabase/deployment/migration-policy.json"

function Assert-Condition {
    param(
        [Parameter(Mandatory)] [bool]$Condition,
        [Parameter(Mandatory)] [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Remove-SqlNonExecutableText {
    param([Parameter(Mandatory)] [string]$Sql)

    $result = [regex]::Replace($Sql, '(?s)/\*.*?\*/', ' ')
    $result = [regex]::Replace($result, '(?m)--[^\r\n]*$', ' ')
    $result = [regex]::Replace(
        $result,
        "(?s)'(?:''|[^'])*'",
        "''"
    )
    $result = [regex]::Replace(
        $result,
        '(?s)\$(?<tag>[A-Za-z_][A-Za-z0-9_]*)\$.*?\$\k<tag>\$',
        ' '
    )
    return [regex]::Replace($result, '(?s)\$\$.*?\$\$', ' ')
}

function Test-AutomaticMigrationSafe {
    param([Parameter(Mandatory)] [string]$Sql)

    $withoutComments = [regex]::Replace($Sql, '(?s)/\*.*?\*/', ' ')
    $withoutComments = [regex]::Replace(
        $withoutComments,
        '(?m)--[^\r\n]*$',
        ' '
    )
    if ([regex]::IsMatch($withoutComments, '(?im)^\s*do\s+\$')) {
        return $false
    }

    $executable = Remove-SqlNonExecutableText -Sql $Sql
    $forbidden = @(
        '(?im)^\s*(delete\s+from|update\s+|insert\s+into|merge\s+into)\b',
        '(?im)^\s*(truncate|call|execute)\b',
        '(?im)^\s*select\b',
        '(?im)^\s*drop\s+(database|schema|table|view|materialized\s+view|function|procedure|trigger|policy|index|type|extension)\b',
        '(?im)^\s*alter\s+(table|view|materialized\s+view|function|procedure|type)\b[^;]*\b(drop|rename)\b',
        '(?im)^\s*alter\s+table\b[^;]*\b(disable\s+row\s+level\s+security|no\s+force\s+row\s+level\s+security)\b',
        '(?im)^\s*alter\s+table\b[^;]*\balter\s+(column\s+)?[^;]*(\btype\b|\bset\s+not\s+null\b)',
        '(?im)^\s*grant\b[^;]*\bto\b[^;]*\b(anon|authenticated|public)\b',
        '(?im)^\s*create\s+or\s+replace\s+(view|materialized\s+view)\b'
    )
    return -not ($forbidden | Where-Object {
            [regex]::IsMatch($executable, $_)
        } | Select-Object -First 1)
}

if ($ClassifierSelfTest) {
    $unsafeStatements = @(
        'delete from public.events;',
        'update public.profiles set display_name = null;',
        'drop view public.visible_events;',
        'drop function public.lookup();',
        'drop policy owner_read on public.events;',
        'drop index public.events_owner_idx;',
        'alter table public.events drop constraint events_owner_fkey;',
        'alter table public.events rename column title to old_title;',
        'alter table public.events disable row level security;',
        'alter table public.events no force row level security;',
        'alter table public.events alter column owner_id type text;',
        'alter table public.events alter column owner_id set not null;',
        'grant select on table public.events to authenticated;',
        "grant execute on function public.lookup()`n  to public;",
        'do $$ begin delete from public.events; end $$;'
    )
    foreach ($statement in $unsafeStatements) {
        Assert-Condition (-not (Test-AutomaticMigrationSafe -Sql $statement)) `
            "Classifier accepted a destructive SQL fixture."
    }
    $safeFixture = @'
begin;
create table private.audit_counts (id uuid primary key);
create or replace function private.runtime_cleanup()
returns void language plpgsql as $$
begin
  delete from private.runtime_queue where false;
end;
$$;
alter table private.audit_counts enable row level security;
commit;
'@
    Assert-Condition (Test-AutomaticMigrationSafe -Sql $safeFixture) `
        "Classifier rejected an additive migration fixture."
    Write-Host "Supabase automatic-migration classifier self-test PASS."
    return
}

Assert-Condition (Test-Path -LiteralPath $policyPath -PathType Leaf) `
    "Migration policy is missing."
Assert-Condition (Test-Path -LiteralPath $MigrationInventoryPath -PathType Leaf) `
    "Migration inventory is missing."

$policy = Get-Content -Raw -LiteralPath $policyPath | ConvertFrom-Json
Assert-Condition ($policy.schemaVersion -eq 1) `
    "Unsupported migration policy schema version."
Assert-Condition ($policy.baselineRemoteVersion -cmatch '^\d{12,14}$') `
    "Migration policy baseline is invalid."

$allowedRows = @($policy.automaticMigrations)
Assert-Condition ($allowedRows.Count -gt 0) `
    "Automatic migration allowlist must not be empty."
$allowedByVersion = @{}
foreach ($row in $allowedRows) {
    $version = [string]$row.version
    $fileName = [string]$row.file
    $expectedHash = [string]$row.sha256
    Assert-Condition ($version -cmatch '^\d{12,14}$') `
        "Allowlisted migration version is invalid."
    Assert-Condition ($fileName -ceq "$version`_$($fileName.Substring($version.Length + 1))") `
        "Allowlisted migration filename does not match its version."
    Assert-Condition ($fileName -cmatch '^\d{12,14}_[a-z0-9_]+\.sql$') `
        "Allowlisted migration filename is invalid."
    Assert-Condition ($expectedHash -cmatch '^[0-9a-f]{64}$') `
        "Allowlisted migration hash is invalid."
    Assert-Condition ([string]$row.classification -ceq 'additive-reviewed') `
        "Automatic migrations require the additive-reviewed classification."
    Assert-Condition (-not $allowedByVersion.ContainsKey($version)) `
        "Automatic migration allowlist contains a duplicate version."

    $sourcePath = Join-Path $migrationDirectory $fileName
    Assert-Condition (Test-Path -LiteralPath $sourcePath -PathType Leaf) `
        "Allowlisted migration source is missing."
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash.ToLowerInvariant()
    Assert-Condition ($actualHash -ceq $expectedHash) `
        "Allowlisted migration hash does not match the reviewed source."
    $sql = Get-Content -Raw -LiteralPath $sourcePath
    Assert-Condition (Test-AutomaticMigrationSafe -Sql $sql) `
        "Allowlisted migration contains a destructive or data-mutating statement."
    $allowedByVersion[$version] = [ordered]@{
        version = $version
        file = $fileName
        sha256 = $actualHash
        classification = 'additive-reviewed'
    }
}

$inventoryLines = @(Get-Content -LiteralPath $MigrationInventoryPath)
$inventoryRows = @()
foreach ($line in $inventoryLines) {
    $match = [regex]::Match(
        $line,
        '^\s*(?<local>\d{12,14})?\s*\|\s*(?<remote>\d{12,14})?\s*\|'
    )
    if ($match.Success) {
        $inventoryRows += [ordered]@{
            local = $match.Groups['local'].Value
            remote = $match.Groups['remote'].Value
        }
    }
}
Assert-Condition ($inventoryRows.Count -gt 0) `
    "Unable to parse the linked migration inventory."
Assert-Condition (@($inventoryRows | Where-Object {
            $_.remote -ceq [string]$policy.baselineRemoteVersion
        }).Count -eq 1) `
    "The regular deploy path requires the reviewed remote baseline."
Assert-Condition (@($inventoryRows | Where-Object {
            [string]::IsNullOrEmpty($_.local) -and
            -not [string]::IsNullOrEmpty($_.remote)
        }).Count -eq 0) `
    "Remote-only migration history requires manual reconciliation."

$pendingVersions = @(
    $inventoryRows |
        Where-Object {
            -not [string]::IsNullOrEmpty($_.local) -and
            [string]::IsNullOrEmpty($_.remote)
        } |
        ForEach-Object { $_.local } |
        Sort-Object -Unique
)
$pendingRows = @()
foreach ($version in $pendingVersions) {
    Assert-Condition ($allowedByVersion.ContainsKey($version)) `
        "Pending migration $version is not approved for automatic deployment."
    $pendingRows += $allowedByVersion[$version]
}

$plan = [ordered]@{
    schemaVersion = 1
    environment = $Environment
    projectRef = $ProjectRef
    deploySha = $DeploySha
    baselineRemoteVersion = [string]$policy.baselineRemoteVersion
    pendingMigrations = @($pendingRows)
}
$planJson = $plan | ConvertTo-Json -Depth 8 -Compress
$outputParent = Split-Path -Parent ([IO.Path]::GetFullPath($PlanOutputPath))
Assert-Condition (Test-Path -LiteralPath $outputParent -PathType Container) `
    "Migration plan output directory does not exist."
[IO.File]::WriteAllText(
    [IO.Path]::GetFullPath($PlanOutputPath),
    $planJson,
    [Text.UTF8Encoding]::new($false)
)

Write-Host "Supabase migration plan PASS."
Write-Host "PendingMigrationCount=$($pendingRows.Count)"
foreach ($row in $pendingRows) {
    Write-Host "PendingMigration=$($row.version):$($row.sha256)"
}
