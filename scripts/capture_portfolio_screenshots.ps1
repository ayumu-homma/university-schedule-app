[CmdletBinding()]
param(
    [string]$DeviceId = "emulator-5554",
    [string]$PackageName = "jp.universityschedule.app.staging",
    [string]$DeepLinkScheme = "unischedule-staging",
    [string]$OutputDirectory = "",
    [ValidateRange(0, 30)]
    [int]$SettleSeconds = 2,
    [switch]$SyntheticDataConfirmed,
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

function Get-PngDimensions {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $signature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
    if ($bytes.Length -lt 24) {
        throw "PNG is too small: $Path"
    }
    for ($index = 0; $index -lt $signature.Length; $index++) {
        if ($bytes[$index] -ne $signature[$index]) {
            throw "Invalid PNG signature: $Path"
        }
    }
    $width = [System.Net.IPAddress]::NetworkToHostOrder(
        [BitConverter]::ToInt32($bytes, 16)
    )
    $height = [System.Net.IPAddress]::NetworkToHostOrder(
        [BitConverter]::ToInt32($bytes, 20)
    )
    if ($width -le 0 -or $height -le 0) {
        throw "Invalid PNG dimensions: $Path"
    }
    return [pscustomobject]@{ Width = $width; Height = $height }
}

function Save-Screenshot {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Instruction
    )

    $localPath = Join-Path $resolvedOutputDirectory $Name
    if (-not $ValidateExisting) {
        Write-Host ""
        Write-Host "Prepare $Name" -ForegroundColor Cyan
        Write-Host $Instruction
        [void](Read-Host "Press Enter when the synthetic screen is ready")
        if ($SettleSeconds -gt 0) {
            Start-Sleep -Seconds $SettleSeconds
        }

        $remotePath = "/sdcard/$Name"
        try {
            Invoke-Adb -Arguments @("shell", "screencap", "-p", $remotePath)
            Invoke-Adb -Arguments @("pull", $remotePath, $localPath)
        }
        finally {
            & adb -s $DeviceId shell rm -f $remotePath | Out-Null
        }
    }
    elseif (-not (Test-Path -LiteralPath $localPath -PathType Leaf)) {
        throw "Missing required screenshot: $localPath"
    }

    $item = Get-Item -LiteralPath $localPath
    if ($item.Length -le 0 -or $item.Length -gt 2MB) {
        throw "$Name must be non-empty and at most 2 MiB; got $($item.Length) bytes."
    }
    $dimensions = Get-PngDimensions -Path $localPath
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $localPath).Hash.ToLowerInvariant()
    [pscustomobject]@{
        File = $Name
        Width = $dimensions.Width
        Height = $dimensions.Height
        Bytes = $item.Length
        SHA256 = $hash
    }
}

if (-not $SyntheticDataConfirmed) {
    throw "Refusing capture. Re-run with -SyntheticDataConfirmed after verifying local demo data only."
}
if ($PackageName -cne "jp.universityschedule.app.staging" -or
    $DeepLinkScheme -cne "unischedule-staging") {
    throw "Portfolio capture is restricted to the isolated staging Android app."
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot "../docs/assets/screenshots"
}
$resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

if ($ValidateExisting) {
    if (-not (Test-Path -LiteralPath $resolvedOutputDirectory -PathType Container)) {
        throw "Screenshot directory does not exist: $resolvedOutputDirectory"
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

    [void](New-Item -ItemType Directory -Force -Path $resolvedOutputDirectory)
    Invoke-Adb -Arguments @(
        "shell", "am", "start", "-W",
        "-a", "android.intent.action.VIEW",
        "-d", "$DeepLinkScheme`://today",
        $PackageName
    ) | Out-Null
}

$screens = @(
    @{
        Name = "01-today.png"
        Instruction = "Show Today with synthetic next/current class and deadline sections."
    },
    @{
        Name = "02-timetable-week.png"
        Instruction = "Open Timetable, choose week view, and keep period times plus occupied/empty cells visible."
    },
    @{
        Name = "03-assignments.png"
        Instruction = "Open Assignments and show at least two deadline groups and a status action."
    },
    @{
        Name = "04-morning-alarm-settings.png"
        Instruction = "Open Settings > Notifications; show synthetic enabled settings, privacy, and capability state."
    },
    @{
        Name = "05-morning-alarm-ringing.png"
        Instruction = "Trigger the debug test alarm and show Stop/Snooze/Today or its privacy-safe notification."
    },
    @{
        Name = "06-document-upload.png"
        Instruction = "Open Quick Add > document import and show the upload screen before opening the system picker."
    },
    @{
        Name = "07-document-candidates.png"
        Instruction = "Analyze the bundled synthetic fixture; show three candidates with one excluded and one edited/selected."
    },
    @{
        Name = "08-dark-timetable.png"
        Instruction = "Enable Android dark mode or alternate width, reopen Timetable, and show a readable layout."
    }
)

$results = foreach ($screen in $screens) {
    Save-Screenshot -Name $screen.Name -Instruction $screen.Instruction
}

$expectedNames = $screens.Name | Sort-Object
$actualFiles = Get-ChildItem -LiteralPath $resolvedOutputDirectory -Filter "*.png" -File
$actualNames = $actualFiles.Name | Sort-Object
$missing = $expectedNames | Where-Object { $_ -notin $actualNames }
if (@($missing).Count -gt 0) {
    throw "Missing required screenshots: $($missing -join ', ')"
}

Write-Host ""
Write-Host "Portfolio screenshot inventory" -ForegroundColor Green
$results | Format-Table -AutoSize
Write-Host "Output: $resolvedOutputDirectory"
Write-Host "Manual privacy review is still required; inspect every PNG before commit."
