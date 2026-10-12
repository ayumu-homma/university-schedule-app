param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,
    [switch]$Build
)

$ErrorActionPreference = 'Stop'
$mobileRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$validator = Join-Path $PSScriptRoot 'validate_android_production_release.mjs'
if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
    [Console]::Error.WriteLine('Release preflight rejected: configuration file is missing.')
    exit 2
}
$configPath = (Resolve-Path -LiteralPath $ConfigFile).Path

Push-Location -LiteralPath $mobileRoot
try {
    & node $validator --config-file $configPath
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    if (-not $Build) {
        exit 0
    }

    & flutter build appbundle --flavor production --release "--dart-define-from-file=$configPath"
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
