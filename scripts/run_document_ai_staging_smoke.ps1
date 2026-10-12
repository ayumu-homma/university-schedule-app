[CmdletBinding()]
param(
    [ValidateSet('staging')]
    [string]$Environment = 'staging',

    [Parameter(Mandatory = $true)]
    [string]$SupabaseUrl,

    [switch]$ConfirmStaging
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-Condition {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Get-RequiredJsonString {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Assert-Condition ($Value -is [string]) $Message
    return [string]$Value
}

function Get-CanonicalJsonTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Value -is [datetime]) {
        return ([datetime]$Value).ToUniversalTime().ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    if ($Value -is [datetimeoffset]) {
        return ([datetimeoffset]$Value).UtcDateTime.ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    Assert-Condition ($Value -is [string]) $Message
    return [string]$Value
}

function Assert-ExactJsonBoolean {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Value,
        [Parameter(Mandatory = $true)]
        [bool]$Expected,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Assert-Condition (($Value -is [bool]) -and ($Value -eq $Expected)) $Message
}

function Test-ServerSideSupabaseKey {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value.StartsWith('sb_secret_', [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $segments = $Value.Split('.')
    if ($segments.Count -ne 3) {
        return $false
    }
    try {
        $payload = $segments[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) |
            ConvertFrom-Json
        $roleProperty = $decoded.PSObject.Properties['role']
        return $null -ne $roleProperty -and
            $roleProperty.Value -is [string] -and
            $roleProperty.Value -ceq 'service_role'
    }
    catch {
        return $false
    }
}

function Test-AllowedSupabaseClientKey {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value -cmatch '^sb_publishable_[A-Za-z0-9_-]+$') {
        return $true
    }
    $segments = $Value.Split('.')
    if ($segments.Count -ne 3) {
        return $false
    }
    try {
        $payload = $segments[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) |
            ConvertFrom-Json
        $roleProperty = $decoded.PSObject.Properties['role']
        return $null -ne $roleProperty -and
            $roleProperty.Value -is [string] -and
            $roleProperty.Value -ceq 'anon'
    }
    catch {
        return $false
    }
}

function Invoke-BoundedJsonRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][ValidateSet('Get', 'Post')][string]$Method,
        [Parameter(Mandatory = $true)][uri]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [object]$Body,
        [int]$MaximumResponseBytes = 1048576
    )

    $request = @{
        Uri = $Uri
        Method = $Method
        Headers = $Headers
        SkipHttpErrorCheck = $true
        TimeoutSec = 90
        MaximumRedirection = 0
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $request.ContentType = 'application/json; charset=utf-8'
        $request.Body = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
    }
    try {
        $response = Invoke-WebRequest @request
    }
    catch {
        throw "$Stage failed before receiving a safe HTTP status."
    }
    $statusCode = [int]$response.StatusCode
    if ($statusCode -lt 200 -or $statusCode -ge 300) {
        throw "$Stage failed with HTTP $statusCode. Response content was suppressed."
    }
    $content = [string]$response.Content
    if ([Text.Encoding]::UTF8.GetByteCount($content) -gt $MaximumResponseBytes) {
        throw "$Stage returned an oversized response."
    }
    try {
        return ConvertFrom-Json -InputObject $content -Depth 30
    }
    catch {
        throw "$Stage returned invalid JSON. Response content was suppressed."
    }
}

function Invoke-SyntheticUpload {
    param(
        [Parameter(Mandatory = $true)][uri]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    try {
        $response = Invoke-WebRequest `
            -Uri $Uri `
            -Method Post `
            -Headers $Headers `
            -ContentType 'text/plain; charset=utf-8' `
            -Body $Bytes `
            -SkipHttpErrorCheck `
            -MaximumRedirection 0 `
            -TimeoutSec 90
    }
    catch {
        throw 'synthetic-upload failed before receiving a safe HTTP status.'
    }
    $statusCode = [int]$response.StatusCode
    if ($statusCode -lt 200 -or $statusCode -ge 300) {
        throw "synthetic-upload failed with HTTP $statusCode. Response content was suppressed."
    }
}

Assert-Condition ($Environment -ceq 'staging') 'Document AI live smoke is staging-only.'
Assert-Condition $ConfirmStaging.IsPresent 'Live smoke requires -ConfirmStaging.'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$deploymentManifestPath = Join-Path $repositoryRoot 'supabase/deployment/environments.json'
Assert-Condition (Test-Path -LiteralPath $deploymentManifestPath -PathType Leaf) `
    'The Supabase deployment manifest is missing.'
try {
    $deploymentManifest = Get-Content -Raw -LiteralPath $deploymentManifestPath |
        ConvertFrom-Json
    $expectedProjectRef = [string]$deploymentManifest.environments.staging.projectRef
    $productionProjectRef = [string]$deploymentManifest.environments.production.projectRef
}
catch {
    throw 'The Supabase deployment manifest is invalid.'
}
Assert-Condition ($expectedProjectRef -cmatch '^[a-z0-9]{20}$') `
    'The staging project ref is not configured in the deployment manifest.'
Assert-Condition (
    $productionProjectRef -ceq 'SET_PRODUCTION_PROJECT_REF' -or
    $productionProjectRef -cmatch '^[a-z0-9]{20}$'
) 'The production project ref entry is malformed.'
if ($productionProjectRef -cmatch '^[a-z0-9]{20}$') {
    Assert-Condition ($expectedProjectRef -cne $productionProjectRef) `
        'Staging and production project refs must be distinct.'
}

try {
    $baseUri = [uri]$SupabaseUrl
}
catch {
    throw 'SupabaseUrl is invalid.'
}
Assert-Condition ($baseUri.Scheme -ceq 'https') 'Staging SupabaseUrl must use HTTPS.'
Assert-Condition $baseUri.IsDefaultPort 'Staging SupabaseUrl must not use a custom port.'
Assert-Condition ([string]::IsNullOrEmpty($baseUri.UserInfo)) 'SupabaseUrl must not contain credentials.'
Assert-Condition ([string]::IsNullOrEmpty($baseUri.Query)) 'SupabaseUrl must not contain a query.'
Assert-Condition ([string]::IsNullOrEmpty($baseUri.Fragment)) 'SupabaseUrl must not contain a fragment.'
Assert-Condition ($baseUri.AbsolutePath -ceq '/') 'SupabaseUrl must not contain a path.'
Assert-Condition ($baseUri.Host -ceq "$expectedProjectRef.supabase.co") `
    'SupabaseUrl does not match the manifest staging project ref.'

$publishableKey = [Environment]::GetEnvironmentVariable(
    'STAGING_SUPABASE_PUBLISHABLE_KEY'
)
$accessToken = [Environment]::GetEnvironmentVariable(
    'STAGING_DOCUMENT_IMPORT_ACCESS_TOKEN'
)
Assert-Condition (-not [string]::IsNullOrWhiteSpace($publishableKey)) `
    'STAGING_SUPABASE_PUBLISHABLE_KEY is required.'
Assert-Condition (-not [string]::IsNullOrWhiteSpace($accessToken)) `
    'STAGING_DOCUMENT_IMPORT_ACCESS_TOKEN is required.'
Assert-Condition ($publishableKey.Length -le 16384 -and $publishableKey -notmatch '[\r\n]') `
    'The staging publishable key is invalid.'
Assert-Condition (-not (Test-ServerSideSupabaseKey -Value $publishableKey)) `
    'A server-side Supabase key cannot be used by this caller smoke.'
Assert-Condition (Test-AllowedSupabaseClientKey -Value $publishableKey) `
    'The staging caller requires a publishable or legacy anon-role key.'
Assert-Condition ($accessToken.Length -le 16384 -and $accessToken -cmatch '^[A-Za-z0-9._~-]+$') `
    'The staging access token is invalid.'
Assert-Condition (-not (Test-ServerSideSupabaseKey -Value $accessToken)) `
    'A server-side Supabase key cannot be used as the staging user token.'

$base = $baseUri.AbsoluteUri.TrimEnd('/')
$headers = @{
    apikey = $publishableKey
    Authorization = "Bearer $accessToken"
    Accept = 'application/json'
}
$sourceId = $null
$storagePath = $null
$cleanupSourceId = $null
$cleanupStoragePath = $null
$cleanupQueued = $false
$result = $null
$primaryFailure = $null
$cleanupFailure = $null

try {
    $caller = Invoke-BoundedJsonRequest `
        -Stage 'caller-validation' `
        -Method Get `
        -Uri "$base/auth/v1/user" `
        -Headers $headers `
        -MaximumResponseBytes 65536
    $ownerId = Get-RequiredJsonString -Value $caller.id `
        -Message 'The staging caller identity must be a string.'
    Assert-Condition ($ownerId -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') `
        'The staging caller identity is invalid.'

    $correlation = [guid]::NewGuid().ToString('D').ToLowerInvariant()
    $requestedSourceId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
    $cleanupSourceId = $requestedSourceId
    $cleanupStoragePath = "$ownerId/$requestedSourceId/source.txt"
    $syntheticText = @(
        'Synthetic university schedule document for automated staging smoke only.'
        'Software Engineering assignment: submit design report by 2027-01-15 23:59 Asia/Tokyo.'
        'Statistics assignment: submit worksheet by 2027-01-20 17:00 Asia/Tokyo.'
        'Calculus final exam: 2027-01-25 10:00-11:30 Asia/Tokyo, Room A101.'
        "Synthetic smoke correlation: $correlation"
    ) -join "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($syntheticText)
    $hashBytes = [Security.Cryptography.SHA256]::HashData($bytes)
    $contentHash = [Convert]::ToHexString($hashBytes).ToLowerInvariant()

    $created = Invoke-BoundedJsonRequest `
        -Stage 'source-reservation' `
        -Method Post `
        -Uri "$base/rest/v1/rpc/create_document_source" `
        -Headers $headers `
        -Body @{
            p_source_id = $requestedSourceId
            p_media_type = 'text/plain'
            p_byte_size = $bytes.Length
            p_content_hash = $contentHash
        }
    $returnedSourceId = Get-RequiredJsonString -Value $created.source_id `
        -Message 'The reserved source identity must be a string.'
    Assert-Condition ($returnedSourceId -ceq $requestedSourceId) `
        'The reserved source identity does not match the requested identity.'
    Assert-Condition ($returnedSourceId -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') `
        'The reserved source identity is invalid.'
    $sourceId = $returnedSourceId
    $storagePath = Get-RequiredJsonString -Value $created.storage_path `
        -Message 'The reserved storage path must be a string.'
    Assert-ExactJsonBoolean -Value $created.replayed -Expected $false `
        -Message 'Synthetic source replayed must be the boolean false.'
    Assert-Condition ($storagePath -ceq $cleanupStoragePath) `
        'The server returned an unexpected private storage path.'

    $encodedStoragePath = (($storagePath -split '/') | ForEach-Object {
            [uri]::EscapeDataString($_)
        }) -join '/'
    $uploadHeaders = $headers.Clone()
    $uploadHeaders['x-upsert'] = 'false'
    Invoke-SyntheticUpload `
        -Uri "$base/storage/v1/object/schedule-documents/$encodedStoragePath" `
        -Headers $uploadHeaders `
        -Bytes $bytes

    $marked = Invoke-BoundedJsonRequest `
        -Stage 'upload-finalization' `
        -Method Post `
        -Uri "$base/rest/v1/rpc/mark_document_source_uploaded" `
        -Headers $headers `
        -Body @{ p_source_id = $sourceId }
    $markedProcessingState = Get-RequiredJsonString `
        -Value $marked.processing_state `
        -Message 'Synthetic upload state must be a string.'
    Assert-Condition ($markedProcessingState -ceq 'uploaded') `
        'Synthetic source did not enter uploaded state.'

    $batch = Invoke-BoundedJsonRequest `
        -Stage 'document-import-live-provider' `
        -Method Post `
        -Uri "$base/functions/v1/document-import" `
        -Headers $headers `
        -Body @{ source_id = $sourceId }
    $schemaVersion = Get-RequiredJsonString -Value $batch.schema_version `
        -Message 'Candidate schema version must be a string.'
    $batchSourceId = Get-RequiredJsonString -Value $batch.source_id `
        -Message 'Candidate source identity must be a string.'
    $batchContentHash = Get-RequiredJsonString -Value $batch.content_hash `
        -Message 'Candidate content hash must be a string.'
    $batchTimezone = Get-RequiredJsonString -Value $batch.timezone `
        -Message 'Candidate timezone must be a string.'
    Assert-Condition ($schemaVersion -ceq '1.0') 'Candidate schema version mismatch.'
    Assert-Condition ($batchSourceId -ceq $sourceId) 'Candidate source identity mismatch.'
    Assert-Condition ($batchContentHash -ceq $contentHash) 'Candidate content hash mismatch.'
    Assert-Condition ($batchTimezone -ceq 'Asia/Tokyo') 'Candidate timezone mismatch.'
    Assert-Condition ($batch.candidates -is [array]) `
        'Candidate collection must be a JSON array.'
    $candidates = @($batch.candidates)
    Assert-Condition ($candidates.Count -eq 3) 'Synthetic document must yield exactly three candidates.'
    foreach ($candidate in $candidates) {
        $candidateType = Get-RequiredJsonString -Value $candidate.type `
            -Message 'Every candidate type must be a string.'
        Assert-Condition (
            $candidateType -ceq 'assignment' -or $candidateType -ceq 'exam'
        ) 'Every candidate type must be assignment or exam.'
        Assert-ExactJsonBoolean `
            -Value $candidate.requires_user_confirmation `
            -Expected $true `
            -Message 'Every candidate confirmation flag must be the boolean true.'
    }
    Assert-Condition ((@($candidates | Where-Object type -ceq 'assignment')).Count -eq 2) `
        'Synthetic document must yield two assignments.'
    Assert-Condition ((@($candidates | Where-Object type -ceq 'exam')).Count -eq 1) `
        'Synthetic document must yield one exam.'

    $assignmentDueTimes = @(
        $candidates |
            Where-Object type -ceq 'assignment' |
            ForEach-Object {
                Get-CanonicalJsonTimestamp -Value $_.due_at `
                    -Message 'Synthetic assignment due time is invalid.'
            } |
            Sort-Object
    )
    Assert-Condition (
        $assignmentDueTimes.Count -eq 2 -and
        $assignmentDueTimes[0] -ceq '2027-01-15T14:59:00.000Z' -and
        $assignmentDueTimes[1] -ceq '2027-01-20T08:00:00.000Z'
    ) 'Synthetic assignment semantic fingerprint mismatch.'

    $exam = @($candidates | Where-Object type -ceq 'exam')[0]
    $examStart = Get-CanonicalJsonTimestamp -Value $exam.start_at `
        -Message 'Synthetic exam start time is invalid.'
    $examEnd = Get-CanonicalJsonTimestamp -Value $exam.end_at `
        -Message 'Synthetic exam end time is invalid.'
    $examLocation = Get-RequiredJsonString -Value $exam.location `
        -Message 'Synthetic exam location must be a string.'
    Assert-Condition (
        $examStart -ceq '2027-01-25T01:00:00.000Z' -and
        $examEnd -ceq '2027-01-25T02:30:00.000Z' -and
        $examLocation -ceq 'Room A101'
    ) 'Synthetic exam semantic fingerprint mismatch.'
    $result = [ordered]@{
        status = 'PASS'
        environment = 'staging'
        schema_version = '1.0'
        assignment_candidates = 2
        exam_candidates = 1
        requires_user_confirmation = $true
        confirmation_rpc_called = $false
    }
}
catch {
    $primaryFailure = $_.Exception.Message
}
finally {
    if ($null -ne $cleanupSourceId) {
        try {
            $deleted = Invoke-BoundedJsonRequest `
                -Stage 'synthetic-cleanup' `
                -Method Post `
                -Uri "$base/rest/v1/rpc/delete_document_source" `
                -Headers $headers `
                -Body @{ p_source_id = $cleanupSourceId }
            Assert-ExactJsonBoolean `
                -Value $deleted.storage_deletion_queued `
                -Expected $true `
                -Message 'Synthetic cleanup queued flag must be the boolean true.'
            $deletedSourceId = Get-RequiredJsonString -Value $deleted.source_id `
                -Message 'Synthetic cleanup source identity must be a string.'
            $deletedStoragePath = Get-RequiredJsonString -Value $deleted.storage_path `
                -Message 'Synthetic cleanup storage path must be a string.'
            Assert-Condition ($deletedSourceId -ceq $cleanupSourceId) `
                'Synthetic cleanup source identity mismatch.'
            Assert-Condition ($deletedStoragePath -ceq $cleanupStoragePath) `
                'Synthetic cleanup storage path mismatch.'
            Assert-ExactJsonBoolean `
                -Value $deleted.schedule_entities_retained `
                -Expected $true `
                -Message 'Synthetic cleanup retention flag must be the boolean true.'
            $cleanupQueued = $true
        }
        catch {
            $cleanupFailure = $_.Exception.Message
        }
    }
}

if ($null -ne $primaryFailure -and $null -ne $cleanupFailure) {
    throw 'Document AI staging smoke failed and synthetic cleanup also failed. ' +
        'Response bodies, identifiers, and paths were suppressed.'
}
if ($null -ne $primaryFailure) {
    throw $primaryFailure
}
if ($null -ne $cleanupFailure -or -not $cleanupQueued) {
    throw ($cleanupFailure ?? 'Synthetic cleanup did not complete safely.')
}
$result.cleanup_queued = $true
$result | ConvertTo-Json -Compress
