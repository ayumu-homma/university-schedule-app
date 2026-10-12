[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$smokePath = Join-Path $PSScriptRoot 'run_document_ai_staging_smoke.ps1'
if (-not (Test-Path -LiteralPath $smokePath -PathType Leaf)) {
    throw 'Document AI staging smoke script is missing.'
}

$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $smokePath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
    throw "Document AI staging smoke has $($parseErrors.Count) parse error(s)."
}

$content = Get-Content -Raw -LiteralPath $smokePath
$requiredFragments = @(
    "[ValidateSet('staging')]",
    'ConfirmStaging',
    'STAGING_SUPABASE_PUBLISHABLE_KEY',
    'STAGING_DOCUMENT_IMPORT_ACCESS_TOKEN',
    'Test-ServerSideSupabaseKey',
    'Test-AllowedSupabaseClientKey',
    '$roleProperty.Value -is [string]',
    'Get-RequiredJsonString',
    'Assert-ExactJsonBoolean',
    'supabase/deployment/environments.json',
    'productionProjectRef',
    'create_document_source',
    'schedule-documents',
    'mark_document_source_uploaded',
    '/functions/v1/document-import',
    'requires_user_confirmation',
    'delete_document_source',
    'storage_deletion_queued',
    'schedule_entities_retained',
    'confirmation_rpc_called',
    'MaximumRedirection',
    'Response content was suppressed'
)
foreach ($fragment in $requiredFragments) {
    if (-not $content.Contains($fragment, [StringComparison]::Ordinal)) {
        throw "Document AI staging smoke is missing contract fragment: $fragment"
    }
}
if ($content.Contains('confirm_document_candidate', [StringComparison]::Ordinal)) {
    throw 'Staging smoke must not persist candidates into schedule entities.'
}
if ($content.Contains('ExpectedProjectRef', [StringComparison]::Ordinal)) {
    throw 'The staging project ref must come only from the repository deployment manifest.'
}
if ($content.Contains('schedule_entities_persisted', [StringComparison]::Ordinal)) {
    throw 'The staging smoke must not claim an unmeasured persistence result.'
}

function Assert-FailsBeforeNetwork {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Arguments,
        [Parameter(Mandatory = $true)][string]$ExpectedMessage,
        [string]$ScriptPath = $smokePath
    )
    try {
        & $ScriptPath @Arguments *> $null
    }
    catch {
        if (-not $_.Exception.Message.Contains($ExpectedMessage, [StringComparison]::Ordinal)) {
            throw "Unexpected fail-closed message: $($_.Exception.Message)"
        }
        return
    }
    throw "Expected fail-closed result containing: $ExpectedMessage"
}

Assert-FailsBeforeNetwork -Arguments @{
    Environment = 'staging'
    SupabaseUrl = 'https://abcdefghijklmnopqrst.supabase.co'
} -ExpectedMessage 'requires -ConfirmStaging'

$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temporaryRoot = Join-Path $temporaryParent `
    "portfolio-document-smoke-contract-$([guid]::NewGuid().ToString('N'))"
$previousPublishableKey = [Environment]::GetEnvironmentVariable(
    'STAGING_SUPABASE_PUBLISHABLE_KEY'
)
$previousAccessToken = [Environment]::GetEnvironmentVariable(
    'STAGING_DOCUMENT_IMPORT_ACCESS_TOKEN'
)

try {
    [void](New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'scripts'))
    [void](New-Item -ItemType Directory -Path (
            Join-Path $temporaryRoot 'supabase/deployment'
        ))
    $contractSmokePath = Join-Path $temporaryRoot `
        'scripts/run_document_ai_staging_smoke.ps1'
    Copy-Item -LiteralPath $smokePath -Destination $contractSmokePath
    @{
        schemaVersion = 1
        environments = @{
            staging = @{ projectRef = 'SET_STAGING_PROJECT_REF' }
            production = @{ projectRef = 'SET_PRODUCTION_PROJECT_REF' }
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 -NoNewline `
        -LiteralPath (Join-Path $temporaryRoot 'supabase/deployment/environments.json')
    Assert-FailsBeforeNetwork -Arguments @{
        Environment = 'staging'
        SupabaseUrl = 'https://abcdefghijklmnopqrst.supabase.co'
        ConfirmStaging = $true
    } -ExpectedMessage 'staging project ref is not configured' `
        -ScriptPath $contractSmokePath

    @{
        schemaVersion = 1
        environments = @{
            staging = @{ projectRef = 'abcdefghijklmnopqrst' }
            production = @{ projectRef = 'SET_PRODUCTION_PROJECT_REF' }
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 -NoNewline `
        -LiteralPath (Join-Path $temporaryRoot 'supabase/deployment/environments.json')

    Assert-FailsBeforeNetwork -Arguments @{
        Environment = 'staging'
        SupabaseUrl = 'https://uvwxyz0123456789abcd.supabase.co'
        ConfirmStaging = $true
    } -ExpectedMessage 'does not match the manifest staging project ref' `
        -ScriptPath $contractSmokePath

    @{
        schemaVersion = 1
        environments = @{
            staging = @{ projectRef = 'abcdefghijklmnopqrst' }
            production = @{ projectRef = 'abcdefghijklmnopqrst' }
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 -NoNewline `
        -LiteralPath (Join-Path $temporaryRoot 'supabase/deployment/environments.json')
    Assert-FailsBeforeNetwork -Arguments @{
        Environment = 'staging'
        SupabaseUrl = 'https://abcdefghijklmnopqrst.supabase.co'
        ConfirmStaging = $true
    } -ExpectedMessage 'must be distinct' -ScriptPath $contractSmokePath
    @{
        schemaVersion = 1
        environments = @{
            staging = @{ projectRef = 'abcdefghijklmnopqrst' }
            production = @{ projectRef = 'SET_PRODUCTION_PROJECT_REF' }
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 -NoNewline `
        -LiteralPath (Join-Path $temporaryRoot 'supabase/deployment/environments.json')

    [Environment]::SetEnvironmentVariable(
        'STAGING_SUPABASE_PUBLISHABLE_KEY',
        'opaque-client-looking-value'
    )
    [Environment]::SetEnvironmentVariable(
        'STAGING_DOCUMENT_IMPORT_ACCESS_TOKEN',
        'contract.user.token'
    )
    Assert-FailsBeforeNetwork -Arguments @{
        Environment = 'staging'
        SupabaseUrl = 'https://abcdefghijklmnopqrst.supabase.co'
        ConfirmStaging = $true
    } -ExpectedMessage 'requires a publishable or legacy anon-role key' `
        -ScriptPath $contractSmokePath

    $arrayRolePayload = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes('{"role":["anon"]}')
    ).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [Environment]::SetEnvironmentVariable(
        'STAGING_SUPABASE_PUBLISHABLE_KEY',
        "e30.$arrayRolePayload.signature"
    )
    Assert-FailsBeforeNetwork -Arguments @{
        Environment = 'staging'
        SupabaseUrl = 'https://abcdefghijklmnopqrst.supabase.co'
        ConfirmStaging = $true
    } -ExpectedMessage 'requires a publishable or legacy anon-role key' `
        -ScriptPath $contractSmokePath

    $serviceRolePayload = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes('{"role":"service_role"}')
    ).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [Environment]::SetEnvironmentVariable(
        'STAGING_SUPABASE_PUBLISHABLE_KEY',
        'sb_publishable_contract_test'
    )
    [Environment]::SetEnvironmentVariable(
        'STAGING_DOCUMENT_IMPORT_ACCESS_TOKEN',
        "e30.$serviceRolePayload.signature"
    )
    Assert-FailsBeforeNetwork -Arguments @{
        Environment = 'staging'
        SupabaseUrl = 'https://abcdefghijklmnopqrst.supabase.co'
        ConfirmStaging = $true
    } -ExpectedMessage 'cannot be used as the staging user token' `
        -ScriptPath $contractSmokePath

    [Environment]::SetEnvironmentVariable(
        'STAGING_SUPABASE_PUBLISHABLE_KEY',
        'sb_publishable_contract_test'
    )
    [Environment]::SetEnvironmentVariable(
        'STAGING_DOCUMENT_IMPORT_ACCESS_TOKEN',
        'contract.user.token'
    )
    $global:DocumentSmokeContractState = @{
        Calls = [Collections.Generic.List[string]]::new()
        CleanupValid = $true
        ReservationValid = $true
        ProviderValid = $true
        SemanticMismatch = ''
        SourceId = $null
        RequestedSourceId = $null
        DeleteSourceId = $null
        StoragePath = $null
        ContentHash = $null
        MalformedField = ''
    }

    function global:Invoke-WebRequest {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][uri]$Uri,
            [Parameter(Mandatory = $true)][string]$Method,
            [Parameter(Mandatory = $true)][hashtable]$Headers,
            [string]$ContentType,
            [object]$Body,
            [switch]$SkipHttpErrorCheck,
            [Parameter(Mandatory = $true)][int]$MaximumRedirection,
            [int]$TimeoutSec
        )

        if ($MaximumRedirection -ne 0) {
            throw 'The staging smoke must disable HTTP redirects.'
        }
        $path = $Uri.AbsolutePath
        $global:DocumentSmokeContractState.Calls.Add($path)
        $payload = switch ($path) {
            '/auth/v1/user' {
                @{ id = '11111111-1111-4111-8111-111111111111' }
            }
            '/rest/v1/rpc/create_document_source' {
                $request = ConvertFrom-Json -InputObject ([string]$Body)
                $global:DocumentSmokeContractState.RequestedSourceId = `
                    [string]$request.p_source_id
                $returnedSourceId = if (
                    $global:DocumentSmokeContractState.MalformedField -ceq `
                        'reservation_source_id'
                ) {
                    7
                } elseif (
                    $global:DocumentSmokeContractState.ReservationValid
                ) {
                    [string]$request.p_source_id
                } else {
                    '22222222-2222-4222-8222-222222222222'
                }
                $global:DocumentSmokeContractState.SourceId = $returnedSourceId
                $global:DocumentSmokeContractState.StoragePath = `
                    "11111111-1111-4111-8111-111111111111/$returnedSourceId/source.txt"
                $global:DocumentSmokeContractState.ContentHash = `
                    [string]$request.p_content_hash
                @{
                    source_id = $returnedSourceId
                    storage_path = $global:DocumentSmokeContractState.StoragePath
                    replayed = if (
                        $global:DocumentSmokeContractState.MalformedField -ceq `
                            'replayed'
                    ) { 'false' } else { $false }
                }
            }
            { $_ -like '/storage/v1/object/schedule-documents/*' } {
                return [pscustomobject]@{ StatusCode = 200; Content = '' }
            }
            '/rest/v1/rpc/mark_document_source_uploaded' {
                @{ processing_state = 'uploaded' }
            }
            '/functions/v1/document-import' {
                $mockCandidates = if (
                    $global:DocumentSmokeContractState.ProviderValid
                ) {
                    @(
                        @{
                            type = if (
                                $global:DocumentSmokeContractState.MalformedField -ceq `
                                    'candidate_type'
                            ) { 7 } else { 'assignment' }
                            due_at = if (
                                $global:DocumentSmokeContractState.SemanticMismatch -cne `
                                    'assignment'
                            ) { '2027-01-15T14:59:00.000Z' } else {
                                '2028-01-15T14:59:00.000Z'
                            }
                            requires_user_confirmation = if (
                                $global:DocumentSmokeContractState.MalformedField -ceq `
                                    'requires_user_confirmation'
                            ) { 'true' } else { $true }
                        }
                        @{
                            type = 'assignment'
                            due_at = if (
                                $global:DocumentSmokeContractState.SemanticMismatch -cne `
                                    'assignment'
                            ) { '2027-01-20T08:00:00.000Z' } else {
                                '2028-01-20T08:00:00.000Z'
                            }
                            requires_user_confirmation = $true
                        }
                        @{
                            type = 'exam'
                            start_at = if (
                                $global:DocumentSmokeContractState.SemanticMismatch -cne `
                                    'exam'
                            ) { '2027-01-25T01:00:00.000Z' } else {
                                '2028-01-25T01:00:00.000Z'
                            }
                            end_at = if (
                                $global:DocumentSmokeContractState.SemanticMismatch -cne `
                                    'exam'
                            ) { '2027-01-25T02:30:00.000Z' } else {
                                '2028-01-25T02:30:00.000Z'
                            }
                            location = if (
                                $global:DocumentSmokeContractState.SemanticMismatch -cne `
                                    'exam'
                            ) { 'Room A101' } else { 'Room B999' }
                            requires_user_confirmation = $true
                        }
                    )
                } else {
                    @()
                }
                @{
                    schema_version = if (
                        $global:DocumentSmokeContractState.MalformedField -ceq `
                            'schema_version'
                    ) { [double]1.0 } else { '1.0' }
                    source_id = if (
                        $global:DocumentSmokeContractState.MalformedField -ceq `
                            'provider_source_id'
                    ) { 7 } else { $global:DocumentSmokeContractState.SourceId }
                    content_hash = if (
                        $global:DocumentSmokeContractState.MalformedField -ceq `
                            'content_hash'
                    ) { $true } else { $global:DocumentSmokeContractState.ContentHash }
                    timezone = if (
                        $global:DocumentSmokeContractState.MalformedField -ceq `
                            'timezone'
                    ) { @{ value = 'Asia/Tokyo' } } else { 'Asia/Tokyo' }
                    candidates = $mockCandidates
                }
            }
            '/rest/v1/rpc/delete_document_source' {
                $deleteRequest = ConvertFrom-Json -InputObject ([string]$Body)
                $deleteSourceId = [string]$deleteRequest.p_source_id
                $global:DocumentSmokeContractState.DeleteSourceId = $deleteSourceId
                @{
                    source_id = if (
                        $global:DocumentSmokeContractState.MalformedField -ceq `
                            'cleanup_source_id'
                    ) {
                        7
                    } elseif ($global:DocumentSmokeContractState.CleanupValid) {
                        $deleteSourceId
                    } else {
                        '22222222-2222-4222-8222-222222222222'
                    }
                    storage_path = `
                        "11111111-1111-4111-8111-111111111111/$deleteSourceId/source.txt"
                    schedule_entities_retained = if (
                        $global:DocumentSmokeContractState.MalformedField -ceq `
                            'schedule_entities_retained'
                    ) { 'true' } else { $true }
                    storage_deletion_queued = if (
                        $global:DocumentSmokeContractState.MalformedField -ceq `
                            'storage_deletion_queued'
                    ) { 'true' } else { $true }
                }
            }
            default { throw "Unexpected mocked request path: $path" }
        }
        return [pscustomobject]@{
            StatusCode = 200
            Content = ConvertTo-Json -InputObject $payload -Depth 20 -Compress
        }
    }

    $passingResult = & $contractSmokePath `
        -Environment staging `
        -SupabaseUrl 'https://abcdefghijklmnopqrst.supabase.co' `
        -ConfirmStaging | ConvertFrom-Json
    if ($passingResult.status -cne 'PASS' -or
        $passingResult.confirmation_rpc_called -isnot [bool] -or
        $passingResult.confirmation_rpc_called -ne $false -or
        $passingResult.cleanup_queued -isnot [bool] -or
        $passingResult.cleanup_queued -ne $true) {
        throw 'Mocked staging smoke success did not preserve its result contract.'
    }
    if ($global:DocumentSmokeContractState.Calls -contains `
        '/rest/v1/rpc/confirm_document_candidate') {
        throw 'Mocked staging smoke called the confirmation RPC.'
    }

    $malformedCases = @(
        @{ Field = 'replayed'; Message = 'replayed must be the boolean false' }
        @{ Field = 'schema_version'; Message = 'schema version must be a string' }
        @{ Field = 'provider_source_id'; Message = 'source identity must be a string' }
        @{ Field = 'content_hash'; Message = 'content hash must be a string' }
        @{ Field = 'timezone'; Message = 'timezone must be a string' }
        @{ Field = 'candidate_type'; Message = 'candidate type must be a string' }
        @{
            Field = 'requires_user_confirmation'
            Message = 'confirmation flag must be the boolean true'
        }
        @{
            Field = 'storage_deletion_queued'
            Message = 'queued flag must be the boolean true'
        }
        @{
            Field = 'schedule_entities_retained'
            Message = 'retention flag must be the boolean true'
        }
        @{
            Field = 'reservation_source_id'
            Message = 'reserved source identity must be a string'
        }
        @{
            Field = 'cleanup_source_id'
            Message = 'cleanup source identity must be a string'
        }
    )
    foreach ($case in $malformedCases) {
        $global:DocumentSmokeContractState.Calls.Clear()
        $global:DocumentSmokeContractState.MalformedField = $case.Field
        $malformedFailureObserved = $false
        try {
            & $contractSmokePath `
                -Environment staging `
                -SupabaseUrl 'https://abcdefghijklmnopqrst.supabase.co' `
                -ConfirmStaging *> $null
        }
        catch {
            if (-not $_.Exception.Message.Contains(
                    $case.Message,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw "Unexpected malformed $($case.Field) failure: $($_.Exception.Message)"
            }
            $malformedFailureObserved = $true
        }
        if (-not $malformedFailureObserved) {
            throw "Malformed $($case.Field) must fail the staging smoke."
        }
    }
    $global:DocumentSmokeContractState.MalformedField = ''

    $semanticCases = @(
        @{
            Field = 'assignment'
            Message = 'assignment semantic fingerprint mismatch'
        }
        @{
            Field = 'exam'
            Message = 'exam semantic fingerprint mismatch'
        }
    )
    foreach ($case in $semanticCases) {
        $global:DocumentSmokeContractState.Calls.Clear()
        $global:DocumentSmokeContractState.SemanticMismatch = $case.Field
        $semanticFailureObserved = $false
        try {
            & $contractSmokePath `
                -Environment staging `
                -SupabaseUrl 'https://abcdefghijklmnopqrst.supabase.co' `
                -ConfirmStaging *> $null
        }
        catch {
            if (-not $_.Exception.Message.Contains(
                    $case.Message,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw "Unexpected $($case.Field) semantic failure: $($_.Exception.Message)"
            }
            $semanticFailureObserved = $true
        }
        if (-not $semanticFailureObserved) {
            throw "Correct counts with wrong $($case.Field) content must fail."
        }
        if ($global:DocumentSmokeContractState.Calls -notcontains `
            '/rest/v1/rpc/delete_document_source') {
            throw 'A semantic mismatch must still clean up the synthetic source.'
        }
    }
    $global:DocumentSmokeContractState.SemanticMismatch = ''

    $global:DocumentSmokeContractState.Calls.Clear()
    $global:DocumentSmokeContractState.ReservationValid = $false
    $reservationFailureObserved = $false
    try {
        & $contractSmokePath `
            -Environment staging `
            -SupabaseUrl 'https://abcdefghijklmnopqrst.supabase.co' `
            -ConfirmStaging *> $null
    }
    catch {
        if (-not $_.Exception.Message.Contains(
                'does not match the requested identity',
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Unexpected reservation failure: $($_.Exception.Message)"
        }
        $reservationFailureObserved = $true
    }
    if (-not $reservationFailureObserved) {
        throw 'A reservation identity mismatch must fail the staging smoke.'
    }
    if ($global:DocumentSmokeContractState.Calls -like `
        '/storage/v1/object/schedule-documents/*') {
        throw 'A mismatched reservation must fail before synthetic upload.'
    }
    if ($global:DocumentSmokeContractState.Calls -notcontains `
        '/rest/v1/rpc/delete_document_source') {
        throw 'A mismatched reservation must clean up the requested source ID.'
    }
    if ($global:DocumentSmokeContractState.DeleteSourceId -cne `
        $global:DocumentSmokeContractState.RequestedSourceId) {
        throw 'Reservation mismatch cleanup did not use the requested source ID.'
    }

    $global:DocumentSmokeContractState.Calls.Clear()
    $global:DocumentSmokeContractState.ReservationValid = $true
    $global:DocumentSmokeContractState.CleanupValid = $false
    $cleanupFailureObserved = $false
    try {
        & $contractSmokePath `
            -Environment staging `
            -SupabaseUrl 'https://abcdefghijklmnopqrst.supabase.co' `
            -ConfirmStaging *> $null
    }
    catch {
        if (-not $_.Exception.Message.Contains(
                'cleanup source identity mismatch',
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Unexpected cleanup failure: $($_.Exception.Message)"
        }
        $cleanupFailureObserved = $true
    }
    if (-not $cleanupFailureObserved) {
        throw 'A cleanup binding mismatch must fail the staging smoke.'
    }

    $global:DocumentSmokeContractState.Calls.Clear()
    $global:DocumentSmokeContractState.ProviderValid = $false
    $combinedFailureObserved = $false
    try {
        & $contractSmokePath `
            -Environment staging `
            -SupabaseUrl 'https://abcdefghijklmnopqrst.supabase.co' `
            -ConfirmStaging *> $null
    }
    catch {
        if (-not $_.Exception.Message.Contains(
                'staging smoke failed and synthetic cleanup also failed',
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Unexpected combined failure: $($_.Exception.Message)"
        }
        $combinedFailureObserved = $true
    }
    if (-not $combinedFailureObserved) {
        throw 'A combined provider and cleanup failure must be reported.'
    }
}
finally {
    [Environment]::SetEnvironmentVariable(
        'STAGING_SUPABASE_PUBLISHABLE_KEY',
        $previousPublishableKey
    )
    [Environment]::SetEnvironmentVariable(
        'STAGING_DOCUMENT_IMPORT_ACCESS_TOKEN',
        $previousAccessToken
    )
    Remove-Item Function:\global:Invoke-WebRequest -ErrorAction SilentlyContinue
    Remove-Variable -Name DocumentSmokeContractState -Scope Global `
        -ErrorAction SilentlyContinue
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
    if (-not $resolvedTemporaryRoot.StartsWith(
            $temporaryParent,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'Refusing to remove an unexpected contract-test path.'
    }
    if (Test-Path -LiteralPath $resolvedTemporaryRoot -PathType Container) {
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}

$relativePath = [IO.Path]::GetRelativePath($repositoryRoot, $smokePath)
Write-Output "PASS: $relativePath is manifest-bound, secret-redacted, confirmation-preserving, and cleanup-verified."
