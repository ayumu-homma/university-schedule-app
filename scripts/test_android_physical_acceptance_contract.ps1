[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$runner = Join-Path $PSScriptRoot "run_android_physical_acceptance.ps1"
$powerShell = (Get-Process -Id $PID).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "university-schedule-android-physical-contract-" + [Guid]::NewGuid().ToString("N")
)
$mockAdb = Join-Path $testRoot "mock-adb.ps1"
$mockApkSigner = Join-Path $testRoot "mock-apksigner.ps1"
$forbiddenSerials = @("SERIAL-SECRET-123", "SECOND-DEVICE", "emulator-5554")
$buildSha = "0123456789abcdef0123456789abcdef01234567"
$passed = 0

function Assert-Contract {
    param(
        [Parameter(Mandatory)] [bool]$Condition,
        [Parameter(Mandatory)] [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-Scenario {
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$MockScenario,
        [Parameter()] [string]$TargetEnvironment = "debug",
        [Parameter()] [string]$AdbCommand = $mockAdb,
        [Parameter()] [string]$PackageName = "jp.universityschedule.app.staging"
    )

    $scenarioDirectory = Join-Path $testRoot $Name
    [void](New-Item -ItemType Directory -Path $scenarioDirectory)
    $previousScenario = $env:ANDROID_ACCEPTANCE_MOCK_SCENARIO
    try {
        $env:ANDROID_ACCEPTANCE_MOCK_SCENARIO = $MockScenario
        $console = @(
            & $powerShell -NoProfile -File $runner `
                -TargetEnvironment $TargetEnvironment `
                -BuildSha $buildSha `
                -PackageName $PackageName `
                -AdbPath $AdbCommand `
                -ApkSignerPath $mockApkSigner `
                -OutputDirectory $scenarioDirectory 2>&1 |
                ForEach-Object { $_.ToString() }
        )
        $exitCode = $LASTEXITCODE
    }
    finally {
        $env:ANDROID_ACCEPTANCE_MOCK_SCENARIO = $previousScenario
    }

    $jsonFiles = @(Get-ChildItem -LiteralPath $scenarioDirectory -Filter "*.json")
    $jsonText = if ($jsonFiles.Count -eq 1) {
        Get-Content -Raw -LiteralPath $jsonFiles[0].FullName
    }
    else {
        ""
    }
    foreach ($forbiddenSerial in $forbiddenSerials) {
        Assert-Contract `
            -Condition (-not (($console -join "`n").Contains($forbiddenSerial))) `
            -Message "$Name leaked a raw serial in console output."
        Assert-Contract `
            -Condition (-not $jsonText.Contains($forbiddenSerial)) `
            -Message "$Name leaked a raw serial in JSON evidence."
        Assert-Contract `
            -Condition (@($jsonFiles | Where-Object { $_.Name.Contains($forbiddenSerial) }).Count -eq 0) `
            -Message "$Name leaked a raw serial in an evidence filename."
    }

    return [pscustomobject]@{
        Name = $Name
        ExitCode = $exitCode
        Console = $console
        JsonFiles = $jsonFiles
        JsonText = $jsonText
        Evidence = if ([string]::IsNullOrWhiteSpace($jsonText)) {
            $null
        }
        else {
            $jsonText | ConvertFrom-Json
        }
    }
}

function Assert-FailedScenario {
    param(
        [Parameter(Mandatory)] [object]$Result,
        [Parameter(Mandatory)] [string]$FailureCategory
    )

    Assert-Contract ($Result.ExitCode -ne 0) "$($Result.Name) unexpectedly passed."
    Assert-Contract ($Result.JsonFiles.Count -eq 1) "$($Result.Name) must write one failure evidence file."
    Assert-Contract ($Result.Evidence.result -eq "FAIL") "$($Result.Name) did not record FAIL."
    Assert-Contract ($Result.Evidence.failureCategory -eq $FailureCategory) "$($Result.Name) recorded the wrong failure category."
    Assert-Contract `
        (@($Result.Evidence.manualAcceptance | Where-Object { $_.status -ne "MANUAL REQUIRED" }).Count -eq 0) `
        "$($Result.Name) converted a manual item into an automated result."
}

try {
    [void](New-Item -ItemType Directory -Path $testRoot)
    $mockSource = @'
$ErrorActionPreference = "Stop"
$scenario = $env:ANDROID_ACCEPTANCE_MOCK_SCENARIO
$adbArguments = @($args)
$serial = "SERIAL-SECRET-123"

if ($adbArguments.Count -ge 1 -and $adbArguments[0] -eq "devices") {
    Write-Output "List of devices attached"
    switch ($scenario) {
        "multiple" {
            Write-Output "$serial device product:pixel model:Pixel_8 transport_id:1"
            Write-Output "SECOND-DEVICE device product:pixel model:Pixel_7 transport_id:2"
        }
        "emulator" {
            Write-Output "emulator-5554 device product:sdk_gphone64_x86_64 model:sdk_gphone64_x86_64 transport_id:1"
        }
        "unauthorized" {
            Write-Output "$serial unauthorized usb:1-1 transport_id:1"
        }
        "none" {}
        default {
            Write-Output "$serial device product:panther model:Pixel_7 transport_id:1"
        }
    }
    exit 0
}

if ($adbArguments.Count -ge 3 -and $adbArguments[2] -eq "get-state") {
    Write-Output "device"
    exit 0
}

if ($adbArguments.Count -eq 5 -and $adbArguments[2] -eq "pull") {
    [IO.File]::WriteAllBytes(
        $adbArguments[4],
        [Text.Encoding]::UTF8.GetBytes("synthetic installed APK bytes")
    )
    Write-Output "1 file pulled"
    exit 0
}

if ($adbArguments.Count -ge 5 -and $adbArguments[2] -eq "shell" -and $adbArguments[3] -eq "getprop") {
    $propertyName = $adbArguments[4]
    switch ($propertyName) {
        "ro.kernel.qemu" { if ($scenario -eq "emulator") { "1" } else { "0" } }
        "ro.boot.qemu" { if ($scenario -eq "emulator") { "1" } else { "0" } }
        "ro.hardware" { if ($scenario -eq "emulator") { "ranchu" } else { "tensor" } }
        "ro.product.manufacturer" { "Google" }
        "ro.product.model" { "Pixel 7" }
        "ro.build.version.release" { "16" }
        "ro.build.version.sdk" { "36" }
        "ro.build.fingerprint" {
            if ($scenario -eq "emulator") {
                "google/sdk_gphone64_x86_64/emu64:16/test:userdebug/test-keys"
            }
            else {
                "google/panther/panther:16/test:user/release-keys"
            }
        }
        "persist.sys.timezone" { "Asia/Tokyo" }
        default { exit 41 }
    }
    exit 0
}

if ($adbArguments.Count -ge 7 -and
    $adbArguments[2] -eq "shell" -and
    $adbArguments[3] -eq "settings" -and
    $adbArguments[4] -eq "get") {
    Write-Output "1"
    exit 0
}

if ($adbArguments.Count -ge 6 -and
    $adbArguments[2] -eq "shell" -and
    $adbArguments[3] -eq "pm" -and
    $adbArguments[4] -eq "path") {
    if ($scenario -eq "package_missing") {
        Write-Output "Error: package was not found"
        exit 42
    }
    else {
        Write-Output "package:/data/app/synthetic/base.apk"
    }
    exit 0
}

if ($adbArguments.Count -ge 6 -and
    $adbArguments[2] -eq "shell" -and
    $adbArguments[3] -eq "dumpsys" -and
    $adbArguments[4] -eq "package") {
    Write-Output "Packages:"
    Write-Output "  versionCode=42 minSdk=24 targetSdk=36"
    Write-Output "  versionName=0.6.0"
    if ($scenario -eq "non_debug") {
        Write-Output "  pkgFlags=[ HAS_CODE ALLOW_BACKUP ]"
    }
    else {
        Write-Output "  pkgFlags=[ DEBUGGABLE HAS_CODE ALLOW_BACKUP ]"
    }
    exit 0
}

if ($adbArguments.Count -ge 6 -and
    $adbArguments[2] -eq "shell" -and
    $adbArguments[3] -eq "dumpsys" -and
    $adbArguments[4] -eq "deviceidle") {
    if ($scenario -eq "capability_unknown") {
        exit 42
    }
    Write-Output "system,jp.universityschedule.app.staging"
    exit 0
}

if ($adbArguments.Count -ge 8 -and
    $adbArguments[2] -eq "shell" -and
    $adbArguments[3] -eq "cmd" -and
    $adbArguments[4] -eq "appops" -and
    $adbArguments[5] -eq "get") {
    if ($scenario -eq "capability_unknown") {
        exit 42
    }
    Write-Output "$($adbArguments[7]): allow"
    exit 0
}

exit 42
'@
    $mockSource | Set-Content -LiteralPath $mockAdb -Encoding utf8
    @'
$ErrorActionPreference = "Stop"
if ($args.Count -ne 3 -or
    $args[0] -ne "verify" -or
    $args[1] -ne "--print-certs" -or
    -not (Test-Path -LiteralPath $args[2] -PathType Leaf)) {
    exit 64
}
Write-Output "Signer #1 certificate SHA-256 digest: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
'@ | Set-Content -LiteralPath $mockApkSigner -Encoding utf8

    $success = Invoke-Scenario -Name "success" -MockScenario "success"
    Assert-Contract `
        ($success.ExitCode -eq 0) `
        "The one-device physical scenario failed: $($success.Console -join ' | ')"
    Assert-Contract ($success.JsonFiles.Count -eq 1) "The success scenario must write one evidence file."
    Assert-Contract ($success.Evidence.result -eq "INVENTORY_READY") "Success did not record INVENTORY_READY."
    Assert-Contract ($success.Evidence.device.serialSha256 -match '^[0-9a-f]{64}$') "The serial hash is missing or invalid."
    Assert-Contract ($success.Evidence.device.buildFingerprintSha256 -match '^[0-9a-f]{64}$') "The build fingerprint must be hashed."
    Assert-Contract ($success.Evidence.app.installed -eq $true) "Installed package was not observed."
    Assert-Contract ($success.Evidence.packageName -eq "jp.universityschedule.app.staging") `
        "Physical acceptance must target the isolated staging package."
    Assert-Contract ($success.Evidence.declaredBuildSha -ceq $buildSha) `
        "Evidence must label an unverified caller SHA as declared only."
    Assert-Contract ($success.Evidence.sourceShaVerified -eq $false) `
        "The harness must not claim source-SHA verification."
    Assert-Contract ($success.Evidence.app.baseApkSha256 -match '^[0-9a-f]{64}$') `
        "Installed base APK hash is missing."
    Assert-Contract (
        @($success.Evidence.app.signingCertificateSha256Digests).Count -eq 1 -and
        $success.Evidence.app.signingCertificateSha256Digests[0] -match '^[0-9a-f]{64}$'
    ) "Installed signing-certificate digest is missing."
    Assert-Contract ($success.Evidence.automatedPreconditions.installedArtifact -eq "PASS") `
        "Installed artifact identity was not inventoried."
    Assert-Contract ($success.Evidence.app.debuggable -eq $true) "Debuggable package was not observed."
    Assert-Contract ($success.Evidence.automatedPreconditions.debugBuild -eq "PASS") "The debug-build precondition did not pass."
    $expectedManualIds = @(
        "environment-marker",
        "cold-launch",
        "today-display",
        "alarm-settings-save",
        "alarm-fire",
        "lock-screen",
        "stop",
        "snooze",
        "today-navigation",
        "exact-alarm-fallback",
        "full-screen-fallback",
        "notification-permission",
        "timezone-recalculation",
        "date-recalculation",
        "package-update-reschedule",
        "reboot-reschedule",
        "battery-optimization-enabled",
        "battery-optimization-exempt",
        "talkback"
    )
    Assert-Contract (@($success.Evidence.manualAcceptance).Count -eq $expectedManualIds.Count) "The manual acceptance inventory has the wrong size."
    Assert-Contract `
        ((@($success.Evidence.manualAcceptance.id) -join ",") -eq ($expectedManualIds -join ",")) `
        "The manual acceptance inventory IDs or order changed."
    Assert-Contract `
        (@($success.Evidence.manualAcceptance | Where-Object { $_.status -ne "MANUAL REQUIRED" }).Count -eq 0) `
        "A manual item was converted into an automated result."
    Assert-Contract `
        ($success.Evidence.safety.deviceStateChanged -eq $false -and
         $success.Evidence.safety.appStateChanged -eq $false -and
         $success.Evidence.safety.rawAdbOutputStored -eq $false) `
        "The evidence does not preserve the read-only safety contract."
    $passed += 1

    $wrongPackage = Invoke-Scenario `
        -Name "wrong-package" `
        -MockScenario "success" `
        -PackageName "jp.universityschedule.app"
    Assert-FailedScenario $wrongPackage "package-target-mismatch"
    $passed += 1

    $multiple = Invoke-Scenario -Name "multiple" -MockScenario "multiple"
    Assert-FailedScenario $multiple "device-count"
    $passed += 1

    $emulator = Invoke-Scenario -Name "emulator" -MockScenario "emulator"
    Assert-FailedScenario $emulator "emulator-rejected"
    $passed += 1

    $unauthorized = Invoke-Scenario -Name "unauthorized" -MockScenario "unauthorized"
    Assert-FailedScenario $unauthorized "device-authorization"
    $passed += 1

    $missingDevice = Invoke-Scenario -Name "missing-device" -MockScenario "none"
    Assert-FailedScenario $missingDevice "device-missing"
    $passed += 1

    $missingPackage = Invoke-Scenario -Name "missing-package" -MockScenario "package_missing"
    Assert-FailedScenario $missingPackage "package-missing"
    Assert-Contract ($missingPackage.Evidence.app.installed -eq $false) "Missing package was recorded as installed."
    $passed += 1

    $nonDebug = Invoke-Scenario -Name "non-debug" -MockScenario "non_debug"
    Assert-FailedScenario $nonDebug "non-debug-package"
    $passed += 1

    $staging = Invoke-Scenario -Name "staging" -MockScenario "non_debug" -TargetEnvironment "staging"
    Assert-Contract ($staging.ExitCode -eq 0) "A non-debuggable staging package should remain eligible for manual acceptance."
    Assert-Contract ($staging.Evidence.automatedPreconditions.debugBuild -eq "NOT_APPLICABLE") "Staging incorrectly claimed a debug-build result."
    $passed += 1

    $capabilityUnknown = Invoke-Scenario -Name "capability-unknown" -MockScenario "capability_unknown"
    Assert-Contract ($capabilityUnknown.ExitCode -eq 0) "Unavailable optional capability inventory must not block manual acceptance."
    Assert-Contract ($null -eq $capabilityUnknown.Evidence.capabilityObservations.batteryOptimizationExempt) "Unavailable battery status must remain null."
    Assert-Contract ($capabilityUnknown.Evidence.capabilityObservations.scheduleExactAlarm -eq "UNKNOWN") "Unavailable exact-alarm app-op must remain UNKNOWN."
    Assert-Contract ($capabilityUnknown.Evidence.capabilityObservations.fullScreenIntent -eq "UNKNOWN") "Unavailable full-screen app-op must remain UNKNOWN."
    Assert-Contract ($capabilityUnknown.Evidence.capabilityObservations.postNotifications -eq "UNKNOWN") "Unavailable notification app-op must remain UNKNOWN."
    $passed += 1

    $missingAdbPath = Join-Path $testRoot "missing-adb.ps1"
    $missingAdb = Invoke-Scenario -Name "missing-adb" -MockScenario "success" -AdbCommand $missingAdbPath
    Assert-FailedScenario $missingAdb "preflight"
    $passed += 1

    $productionDirectory = Join-Path $testRoot "production-rejected"
    [void](New-Item -ItemType Directory -Path $productionDirectory)
    $productionConsole = @(
        & $powerShell -NoProfile -File $runner `
            -TargetEnvironment "production" `
            -BuildSha $buildSha `
            -AdbPath $mockAdb `
            -OutputDirectory $productionDirectory 2>&1 |
            ForEach-Object { $_.ToString() }
    )
    $productionExitCode = $LASTEXITCODE
    Assert-Contract ($productionExitCode -ne 0) "Production target was not rejected."
    Assert-Contract `
        (@(Get-ChildItem -LiteralPath $productionDirectory -Filter "*.json").Count -eq 0) `
        "Rejected production input must not create acceptance evidence."
    foreach ($forbiddenSerial in $forbiddenSerials) {
        Assert-Contract `
            (-not (($productionConsole -join "`n").Contains($forbiddenSerial))) `
            "Production rejection leaked a raw serial."
    }
    $passed += 1

    Write-Host "PASS: Android physical acceptance contract ($passed/12 scenarios)."
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($testRoot)
    $systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $leaf = Split-Path -Leaf $resolvedTemp
    if ($resolvedTemp.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -and
        $leaf.StartsWith("university-schedule-android-physical-contract-", [StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Expected-failure scenarios above intentionally leave a native child process
# with a non-zero exit code. GitHub's PowerShell wrapper propagates
# $LASTEXITCODE after the script returns, so normalize it after all assertions
# have passed instead of reporting a false contract failure on Linux runners.
$global:LASTEXITCODE = 0
