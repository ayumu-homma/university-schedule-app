[CmdletBinding()]
param(
    [ValidateSet("staging")]
    [string]$Environment = "staging",

    [Parameter(Mandatory)]
    [string]$ProjectRef,

    [ValidateRange(1, 500)]
    [int]$Limit = 100,

    [switch]$Execute,

    [string]$Confirmation = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$manifestPath = (Resolve-Path -LiteralPath (
        Join-Path $workspace "supabase/deployment/environments.json"
    )).Path
$maximumResponseBytes = 1MB
$bucketName = "schedule-documents"
$executeConfirmation = "DELETE_STAGING_DOCUMENTS"

function Assert-Condition {
    param(
        [Parameter(Mandatory)] [bool]$Condition,
        [Parameter(Mandatory)] [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-GitCapture {
    param([Parameter(Mandatory)] [string[]]$Arguments)

    $output = @(& git -C $workspace @Arguments 2>&1 | ForEach-Object {
            $_.ToString()
        })
    if ($LASTEXITCODE -ne 0) {
        throw "The cleanup runner could not verify repository identity."
    }
    return ($output -join "`n").Trim()
}

function Get-ServiceRoleKeyKind {
    param([Parameter(Mandatory)] [string]$Value)

    if ($Value -cmatch '^sb_secret_[A-Za-z0-9_-]+$') {
        return "opaque-secret"
    }
    $segments = $Value.Split('.')
    if ($segments.Count -ne 3) {
        return $null
    }
    try {
        $payload = $segments[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }
        $decoded = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($payload)
        ) | ConvertFrom-Json
        if ($decoded.role -ceq 'service_role') {
            return "legacy-service-role-jwt"
        }
        return $null
    }
    catch {
        return $null
    }
}

function Convert-ToRows {
    param([Parameter()] $Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [System.Array]) {
        return @($Value)
    }
    return @($Value)
}

function Get-CountField {
    param(
        [Parameter(Mandatory)] $Row,
        [Parameter(Mandatory)] [string]$Name
    )

    $property = $Row.PSObject.Properties[$Name]
    Assert-Condition ($null -ne $property) "Cleanup preview response was invalid."
    $parsed = 0L
    Assert-Condition `
        ([long]::TryParse([string]$property.Value, [ref]$parsed) -and $parsed -ge 0) `
        "Cleanup preview response was invalid."
    return $parsed
}

function Invoke-CleanupApi {
    param(
        [Parameter(Mandatory)] [System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory)] [string]$RelativePath,
        [Parameter(Mandatory)] [hashtable]$Body,
        [Parameter()] [ValidateSet("POST", "DELETE")] [string]$Method = "POST"
    )

    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::new($Method),
        $RelativePath
    )
    try {
        $json = $Body | ConvertTo-Json -Compress -Depth 8
        $request.Content = [System.Net.Http.StringContent]::new(
            $json,
            [System.Text.Encoding]::UTF8,
            "application/json"
        )
        $response = $Client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            if ($bytes.Length -gt $maximumResponseBytes) {
                throw "Cleanup API response exceeded the safe size limit."
            }
            if (-not $response.IsSuccessStatusCode) {
                $statusCode = [int]$response.StatusCode
                throw "Cleanup API returned HTTP $statusCode. Response content was suppressed."
            }
            if ($bytes.Length -eq 0) {
                return $null
            }
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            try {
                return $text | ConvertFrom-Json
            }
            catch {
                throw "Cleanup API returned malformed JSON. Response content was suppressed."
            }
        }
        finally {
            $response.Dispose()
        }
    }
    finally {
        $request.Dispose()
    }
}

function Complete-AuditRun {
    param(
        [Parameter(Mandatory)] [System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory)] [guid]$RunId,
        [Parameter(Mandatory)]
        [ValidateSet("succeeded", "partial", "failed")]
        [string]$Status,
        [Parameter(Mandatory)] [int]$Claimed,
        [Parameter(Mandatory)] [int]$Deleted,
        [Parameter(Mandatory)] [int]$Failed
    )

    $null = Invoke-CleanupApi `
        -Client $Client `
        -RelativePath "rest/v1/rpc/finish_document_cleanup_run" `
        -Body @{
            p_run_id = $RunId.ToString()
            p_status = $Status
            p_claimed_count = $Claimed
            p_deleted_count = $Deleted
            p_failed_count = $Failed
        }
}

function Confirm-AuditRun {
    param(
        [Parameter(Mandatory)] [System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory)] [guid]$RunId,
        [Parameter(Mandatory)] [string]$ExpectedStatus,
        [Parameter(Mandatory)] [int]$ExpectedClaimed,
        [Parameter(Mandatory)] [int]$ExpectedDeleted,
        [Parameter(Mandatory)] [int]$ExpectedFailed
    )

    $value = Invoke-CleanupApi `
        -Client $Client `
        -RelativePath "rest/v1/rpc/get_document_cleanup_run" `
        -Body @{ p_run_id = $RunId.ToString() }
    $rows = @(Convert-ToRows $value)
    Assert-Condition ($rows.Count -eq 1) `
        "Cleanup audit confirmation returned an invalid row count."
    $row = $rows[0]
    Assert-Condition ([string]$row.status -ceq $ExpectedStatus) `
        "Cleanup audit confirmation returned an unexpected status."
    Assert-Condition `
        ((Get-CountField $row "claimed_count") -eq $ExpectedClaimed -and
         (Get-CountField $row "deleted_count") -eq $ExpectedDeleted -and
         (Get-CountField $row "failed_count") -eq $ExpectedFailed) `
        "Cleanup audit confirmation returned unexpected counts."
}

$repositoryStatus = Invoke-GitCapture @(
    "status", "--porcelain=v1", "--untracked-files=all"
)
Assert-Condition ([string]::IsNullOrWhiteSpace($repositoryStatus)) `
    "Document cleanup requires a clean worktree."
$currentSha = Invoke-GitCapture @("rev-parse", "HEAD")
Assert-Condition ($currentSha -cmatch '^[0-9a-f]{40}$') `
    "Document cleanup requires an exact Git SHA."
$currentBranch = Invoke-GitCapture @("branch", "--show-current")

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
Assert-Condition ($manifest.schemaVersion -eq 1) `
    "Unsupported deployment manifest schema version."
$target = $manifest.environments.staging
Assert-Condition ($null -ne $target) "The staging manifest is missing."
Assert-Condition ($target.githubEnvironment -ceq "staging") `
    "The staging GitHub Environment mapping is invalid."
Assert-Condition ($target.allowDemoOrFake -eq $false) `
    "Cleanup cannot run against a demo or fake environment."
Assert-Condition (@($target.allowedBranches) -ccontains $currentBranch) `
    "The current branch is not allowlisted for staging cleanup."
Assert-Condition ($ProjectRef -cmatch '^[a-z0-9]{20}$') `
    "ProjectRef must be an exact 20-character Supabase project ref."
Assert-Condition ($target.projectRef -cmatch '^[a-z0-9]{20}$') `
    "Staging cleanup is not activated: configure the reviewed staging project ref in the deployment manifest."
Assert-Condition ($ProjectRef -ceq $target.projectRef) `
    "ProjectRef does not match the staging allowlist."

if ($Execute) {
    Assert-Condition ($Confirmation -ceq $executeConfirmation) `
        "Execute mode requires the exact confirmation DELETE_STAGING_DOCUMENTS."
}
else {
    Assert-Condition ([string]::IsNullOrWhiteSpace($Confirmation)) `
        "Confirmation is accepted only together with -Execute."
}

$serviceRoleKey = [Environment]::GetEnvironmentVariable(
    "SUPABASE_SERVICE_ROLE_KEY",
    [EnvironmentVariableTarget]::Process
)
Assert-Condition (-not [string]::IsNullOrWhiteSpace($serviceRoleKey)) `
    "SUPABASE_SERVICE_ROLE_KEY is unavailable in the current process."
$serviceRoleKeyKind = Get-ServiceRoleKeyKind -Value $serviceRoleKey
Assert-Condition (
    $serviceRoleKey.Length -le 16384 -and
    $serviceRoleKey -notmatch '[\r\n]' -and
    $null -ne $serviceRoleKeyKind
) "SUPABASE_SERVICE_ROLE_KEY is not a recognized service-role key."

$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.BaseAddress = [Uri]::new("https://$ProjectRef.supabase.co/")
$client.Timeout = [TimeSpan]::FromSeconds(30)
$client.MaxResponseContentBufferSize = $maximumResponseBytes
$client.DefaultRequestHeaders.TryAddWithoutValidation("apikey", $serviceRoleKey) |
    Out-Null
if ($serviceRoleKeyKind -ceq "legacy-service-role-jwt") {
    $client.DefaultRequestHeaders.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new(
            "Bearer",
            $serviceRoleKey
        )
}
$client.DefaultRequestHeaders.Accept.Add(
    [System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new(
        "application/json"
    )
)

$runId = [guid]::NewGuid()
$auditStarted = $false
$auditFinished = $false
$claimedCount = 0
$deletedCount = 0

try {
    $previewValue = Invoke-CleanupApi `
        -Client $client `
        -RelativePath "rest/v1/rpc/preview_expired_document_sources" `
        -Body @{ p_limit = $Limit }
    $previewRows = @(Convert-ToRows $previewValue)
    Assert-Condition ($previewRows.Count -eq 1) `
        "Cleanup preview must return exactly one count row."
    $queuedCount = Get-CountField $previewRows[0] "queued_object_count"
    $expiredCount = Get-CountField $previewRows[0] "expired_source_count"
    $eligibleCount = Get-CountField $previewRows[0] "eligible_count"
    $previewCount = Get-CountField $previewRows[0] "preview_count"
    Assert-Condition ($previewCount -le $Limit -and $eligibleCount -ge $previewCount) `
        "Cleanup preview violated the configured bound."

    $mode = if ($Execute) { "manual_execute" } else { "dry_run" }
    $null = Invoke-CleanupApi `
        -Client $client `
        -RelativePath "rest/v1/rpc/begin_document_cleanup_run" `
        -Body @{
            p_run_id = $runId.ToString()
            p_mode = $mode
            p_requested_limit = $Limit
            p_eligible_count = $eligibleCount
        }
    $auditStarted = $true

    $maskedProjectRef = "$($ProjectRef.Substring(0, 6))...$($ProjectRef.Substring(16, 4))"
    Write-Host "Document cleanup preview"
    Write-Host "RunId=$runId"
    Write-Host "Environment=staging"
    Write-Host "GitSha=$currentSha"
    Write-Host "ProjectRef=$maskedProjectRef"
    Write-Host "RequestedLimit=$Limit"
    Write-Host "QueuedObjectCount=$queuedCount"
    Write-Host "ExpiredSourceCount=$expiredCount"
    Write-Host "EligibleCount=$eligibleCount"
    Write-Host "BoundedPreviewCount=$previewCount"

    if (-not $Execute) {
        Complete-AuditRun `
            -Client $client `
            -RunId $runId `
            -Status "succeeded" `
            -Claimed 0 `
            -Deleted 0 `
            -Failed 0
        Confirm-AuditRun `
            -Client $client `
            -RunId $runId `
            -ExpectedStatus "succeeded" `
            -ExpectedClaimed 0 `
            -ExpectedDeleted 0 `
            -ExpectedFailed 0
        $auditFinished = $true
        Write-Host "Mode=DRY_RUN"
        Write-Host "BusinessRowsMutated=0"
        Write-Host "StorageObjectsDeleted=0"
        exit 0
    }

    $claimValue = Invoke-CleanupApi `
        -Client $client `
        -RelativePath "rest/v1/rpc/claim_expired_document_sources" `
        -Body @{ p_limit = $Limit }
    $claimRows = @(Convert-ToRows $claimValue)
    $claimedCount = $claimRows.Count
    Assert-Condition ($claimedCount -le $Limit) `
        "Cleanup claim exceeded the requested limit."

    $paths = [System.Collections.Generic.List[string]]::new()
    $pathPattern = [regex]::new(
        '^(?<owner>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/' +
        '(?<source>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/' +
        'source\.(?:pdf|txt|png|jpe?g)$',
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    foreach ($row in $claimRows) {
        $sourceId = [string]$row.source_id
        $storagePath = [string]$row.storage_path
        $parsedSourceId = [guid]::Empty
        Assert-Condition ([guid]::TryParse($sourceId, [ref]$parsedSourceId)) `
            "Cleanup claim returned an invalid source identifier."
        Assert-Condition ($storagePath.Length -le 512) `
            "Cleanup claim returned an invalid Storage path."
        $pathMatch = $pathPattern.Match($storagePath)
        Assert-Condition $pathMatch.Success `
            "Cleanup claim returned an invalid Storage path."
        Assert-Condition `
            ($pathMatch.Groups['source'].Value -ceq $sourceId.ToLowerInvariant()) `
            "Cleanup claim returned a mismatched source/path binding."
        $paths.Add($storagePath)
    }

    if ($claimedCount -gt 0) {
        $deleteValue = Invoke-CleanupApi `
            -Client $client `
            -RelativePath "storage/v1/object/$bucketName" `
            -Body @{ prefixes = @($paths) } `
            -Method "DELETE"
        $deletedRows = @(Convert-ToRows $deleteValue)
        $deletedCount = $deletedRows.Count
    }

    $failedCount = $claimedCount - $deletedCount
    $status = if ($failedCount -eq 0) { "succeeded" } else { "partial" }
    Complete-AuditRun `
        -Client $client `
        -RunId $runId `
        -Status $status `
        -Claimed $claimedCount `
        -Deleted $deletedCount `
        -Failed $failedCount
    Confirm-AuditRun `
        -Client $client `
        -RunId $runId `
        -ExpectedStatus $status `
        -ExpectedClaimed $claimedCount `
        -ExpectedDeleted $deletedCount `
        -ExpectedFailed $failedCount
    $auditFinished = $true

    Write-Host "Mode=MANUAL_EXECUTE"
    Write-Host "ClaimedCount=$claimedCount"
    Write-Host "DeletedCount=$deletedCount"
    Write-Host "FailedCount=$failedCount"
    if ($failedCount -ne 0) {
        throw "Storage deletion was partial. Paths and response content were suppressed."
    }

    try {
        $postValue = Invoke-CleanupApi `
            -Client $client `
            -RelativePath "rest/v1/rpc/preview_expired_document_sources" `
            -Body @{ p_limit = $Limit }
        $postRows = @(Convert-ToRows $postValue)
        if ($postRows.Count -eq 1) {
            $remaining = Get-CountField $postRows[0] "eligible_count"
            Write-Host "RemainingEligibleCount=$remaining"
        }
    }
    catch {
        Write-Warning "Post-run count preview was unavailable; no response content was displayed."
    }
}
catch {
    if ($auditStarted -and -not $auditFinished) {
        $knownFailedCount = [Math]::Max(0, $claimedCount - $deletedCount)
        try {
            Complete-AuditRun `
                -Client $client `
                -RunId $runId `
                -Status "failed" `
                -Claimed $claimedCount `
                -Deleted $deletedCount `
                -Failed $knownFailedCount
        }
        catch {
            Write-Warning "Cleanup audit finalization failed; reconcile the count-only run by RunId=$runId."
        }
    }
    throw "Document cleanup did not complete. RunId=$runId. Secret values, paths, and response bodies were suppressed."
}
finally {
    $client.Dispose()
    $handler.Dispose()
    $serviceRoleKey = $null
}
