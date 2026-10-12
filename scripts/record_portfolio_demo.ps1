[CmdletBinding()]
param(
    [string]$DeviceId = "emulator-5554",
    [string]$PackageName = "jp.universityschedule.app.staging",
    [string]$DeepLinkScheme = "unischedule-staging",
    [string]$OutputPath = "",
    [ValidateRange(60, 90)]
    [int]$DurationSeconds = 75,
    [ValidateRange(500000, 8000000)]
    [int]$BitRate = 2000000,
    [string]$VideoSize = "720x1600",
    [switch]$SyntheticDataConfirmed,
    [switch]$SkipReadyPrompt,
    [switch]$ValidateExisting
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Adb {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & adb -s $DeviceId @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "adb failed: adb -s $DeviceId $($Arguments -join ' ')"
    }
}

function Find-AsciiSequence {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$Value
    )

    # ASCII decoding preserves one character per byte, so IndexOf returns the
    # byte offset while avoiding a multi-million-iteration PowerShell loop.
    return [Text.Encoding]::ASCII.GetString($Bytes).IndexOf(
        $Value,
        [StringComparison]::Ordinal
    )
}

function Get-BigEndianNumber {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$Offset,
        [Parameter(Mandatory)][ValidateSet(4, 8)][int]$Count
    )

    [double]$value = 0
    for ($index = 0; $index -lt $Count; $index++) {
        $value = ($value * 256) + $Bytes[$Offset + $index]
    }
    return $value
}

function Get-Mp4DurationSeconds {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $typeOffset = Find-AsciiSequence -Bytes $Bytes -Value "mvhd"
    if ($typeOffset -lt 4 -or $typeOffset + 32 -ge $Bytes.Length) {
        throw "MP4 movie header (mvhd) is missing or truncated."
    }
    $version = $Bytes[$typeOffset + 4]
    if ($version -eq 0) {
        $timescale = Get-BigEndianNumber -Bytes $Bytes -Offset ($typeOffset + 16) -Count 4
        $duration = Get-BigEndianNumber -Bytes $Bytes -Offset ($typeOffset + 20) -Count 4
    }
    elseif ($version -eq 1) {
        $timescale = Get-BigEndianNumber -Bytes $Bytes -Offset ($typeOffset + 24) -Count 4
        $duration = Get-BigEndianNumber -Bytes $Bytes -Offset ($typeOffset + 28) -Count 8
    }
    else {
        throw "Unsupported MP4 movie-header version: $version"
    }
    if ($timescale -le 0 -or $duration -le 0) {
        throw "MP4 duration metadata is invalid."
    }
    return [double]$duration / [double]$timescale
}

if (-not $SyntheticDataConfirmed) {
    throw "Refusing recording. Re-run with -SyntheticDataConfirmed after verifying local demo data only."
}
if ($PackageName -cne "jp.universityschedule.app.staging" -or
    $DeepLinkScheme -cne "unischedule-staging") {
    throw "Portfolio recording is restricted to the isolated staging Android app."
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot "../docs/assets/demo/university_schedule_app_demo.mp4"
}
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)

if ($ValidateExisting) {
    if (-not (Test-Path -LiteralPath $resolvedOutputPath -PathType Leaf)) {
        throw "Demo MP4 does not exist: $resolvedOutputPath"
    }
}
else {
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
        throw "adb is not available on PATH."
    }
    $deviceState = (& adb -s $DeviceId get-state 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $deviceState -ne "device") {
        throw "Android device '$DeviceId' is not connected and ready."
    }
    $installed = & adb -s $DeviceId shell pm path $PackageName 2>$null
    if ($LASTEXITCODE -ne 0 -or -not ($installed -match '^package:')) {
        throw "Package '$PackageName' is not installed on '$DeviceId'."
    }

    [void](New-Item -ItemType Directory -Force -Path (Split-Path $resolvedOutputPath))
    $remotePath = "/sdcard/university_schedule_app_demo.mp4"

    Invoke-Adb -Arguments @(
        "shell", "am", "start", "-W",
        "-a", "android.intent.action.VIEW",
        "-d", "$DeepLinkScheme`://today",
        $PackageName
    ) | Out-Null

    if (-not $SkipReadyPrompt) {
        Write-Host "Follow docs/PORTFOLIO_DEMO_STORYBOARD.md while recording." -ForegroundColor Cyan
        Write-Host "Close keyboards and unrelated notifications. Keep all content synthetic."
        [void](Read-Host "Press Enter on the ready Today screen")
    }

    try {
        Write-Host "Recording $DurationSeconds seconds from $DeviceId (silent Android screenrecord)..."
        Invoke-Adb -Arguments @(
            "shell", "screenrecord",
            "--size", $VideoSize,
            "--bit-rate", "$BitRate",
            "--time-limit", "$DurationSeconds",
            $remotePath
        )
        Invoke-Adb -Arguments @("pull", $remotePath, $resolvedOutputPath)
    }
    finally {
        & adb -s $DeviceId shell rm -f $remotePath | Out-Null
    }
}

$item = Get-Item -LiteralPath $resolvedOutputPath
if ($item.Length -le 0 -or $item.Length -gt 25MB) {
    throw "Demo MP4 must be non-empty and at most 25 MiB; got $($item.Length) bytes."
}
$bytes = [System.IO.File]::ReadAllBytes($resolvedOutputPath)
if ($bytes.Length -lt 12 -or [Text.Encoding]::ASCII.GetString($bytes, 4, 4) -ne "ftyp") {
    throw "Output does not have an ISO-BMFF/MP4 ftyp signature."
}
$actualDuration = Get-Mp4DurationSeconds -Bytes $bytes
if ($actualDuration -lt 60 -or $actualDuration -gt 90) {
    throw "Demo MP4 duration must be 60-90 seconds; got $([Math]::Round($actualDuration, 2))."
}
if ((Find-AsciiSequence -Bytes $bytes -Value "soun") -ge 0) {
    throw "An audio handler was found; the portfolio demo must be silent."
}
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedOutputPath).Hash.ToLowerInvariant()
Write-Host "Demo video validated." -ForegroundColor Green
Write-Host "Path: $resolvedOutputPath"
Write-Host "DurationSeconds: $([Math]::Round($actualDuration, 2))"
Write-Host "Bytes: $($item.Length)"
Write-Host "SHA256: $hash"
Write-Host "Visually verify duration, playback, synthetic-only content, and absence of host/private UI before commit."
