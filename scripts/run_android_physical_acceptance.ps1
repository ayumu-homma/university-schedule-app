[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("debug", "staging")]
    [string]$TargetEnvironment,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$BuildSha,

    [Parameter()]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$')]
    [string]$PackageName = "jp.universityschedule.app.staging",

    [Parameter()]
    [string]$AdbPath = "",

    [Parameter()]
    [string]$ApkSignerPath = "",

    [Parameter()]
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) "university-schedule-android-physical-acceptance"
}

function Get-Sha256 {
    param([Parameter(Mandatory)] [string]$Value)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Resolve-AdbCommand {
    if (-not [string]::IsNullOrWhiteSpace($AdbPath)) {
        if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
            throw "The configured adb command was not found."
        }
        return (Resolve-Path -LiteralPath $AdbPath).Path
    }

    $command = Get-Command adb -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "adb was not found on PATH."
    }
    return $command.Source
}

function Resolve-ApkSignerCommand {
    if (-not [string]::IsNullOrWhiteSpace($ApkSignerPath)) {
        if (-not (Test-Path -LiteralPath $ApkSignerPath -PathType Leaf)) {
            throw "The configured apksigner command was not found."
        }
        return (Resolve-Path -LiteralPath $ApkSignerPath).Path
    }

    $command = Get-Command apksigner -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }
    $sdkRoot = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -First 1
    if ($null -ne $sdkRoot) {
        $buildTools = Join-Path $sdkRoot "build-tools"
        if (Test-Path -LiteralPath $buildTools -PathType Container) {
            $candidate = Get-ChildItem -LiteralPath $buildTools -Directory |
                Sort-Object -Property Name -Descending |
                ForEach-Object {
                    @(
                        (Join-Path $_.FullName "apksigner.bat"),
                        (Join-Path $_.FullName "apksigner")
                    )
                } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
            if ($null -ne $candidate) {
                return $candidate
            }
        }
    }
    throw "apksigner was not found on PATH or in the Android SDK."
}

function Invoke-NativeReadOnly {
    param(
        [Parameter(Mandatory)] [string]$Command,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [Parameter(Mandatory)] [string]$Operation
    )

    try {
        $output = @(& $Command @Arguments 2>&1 | ForEach-Object {
                $_.ToString()
            })
    }
    catch {
        throw "The acceptance harness could not read $Operation."
    }
    if ($LASTEXITCODE -ne 0) {
        throw "The acceptance harness failed while reading $Operation."
    }
    return $output
}

function Invoke-AdbReadOnly {
    param(
        [Parameter(Mandatory)] [string]$Command,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [Parameter(Mandatory)] [string]$Operation
    )

    try {
        $output = @(& $Command @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    }
    catch {
        throw "adb could not read $Operation."
    }
    if ($LASTEXITCODE -ne 0) {
        throw "adb failed while reading $Operation."
    }
    return $output
}

function Invoke-AdbOptionalRead {
    param(
        [Parameter(Mandatory)] [string]$Command,
        [Parameter(Mandatory)] [string[]]$Arguments
    )

    try {
        $output = @(& $Command @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        if ($LASTEXITCODE -ne 0) {
            return @()
        }
        return $output
    }
    catch {
        return @()
    }
}

function Get-DeviceEntries {
    param([Parameter(Mandatory)] [string[]]$Lines)

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($line in $Lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or
            $trimmed.StartsWith("List of devices attached") -or
            $trimmed.StartsWith("* daemon")) {
            continue
        }
        if ($trimmed -notmatch '^(?<serial>\S+)\s+(?<details>.+)$') {
            continue
        }
        $serial = $Matches.serial
        $details = $Matches.details
        $state = if ($details -match '^no permissions(?:\s|$)') {
            "no permissions"
        }
        elseif ($details -match '^(?<state>\S+)') {
            $Matches.state
        }
        else {
            "unknown"
        }
        $entries.Add([pscustomobject]@{
            Serial = $serial
            State = $state
        })
    }
    return @($entries)
}

function Get-AppOpObservation {
    param([Parameter()] [AllowEmptyCollection()] [string[]]$Lines = @())

    $joined = $Lines -join "`n"
    if ($joined -match '(?im):\s*(allow|foreground)\b') {
        return "ALLOWED"
    }
    if ($joined -match '(?im):\s*(deny|ignore|errored)\b') {
        return "DENIED"
    }
    return "UNKNOWN"
}

function New-ManualAcceptanceItems {
    $items = @(
        @("environment-marker", "Debugまたはstaging表示と合成データを確認する"),
        @("cold-launch", "コールド起動後にTodayが表示される"),
        @("today-display", "Todayの授業・課題・テストが正しく読める"),
        @("alarm-settings-save", "朝の確認設定を保存して再表示できる"),
        @("alarm-fire", "設定時刻にアラームが1回だけ発火する"),
        @("lock-screen", "ロック画面で予定・授業・アカウント詳細を漏らさない"),
        @("stop", "停止で通知と鳴動が終了する"),
        @("snooze", "スヌーズが1件だけ再登録される"),
        @("today-navigation", "Today操作が通常のToday導線を開く"),
        @("exact-alarm-fallback", "正確なアラーム権限なしで概算時刻へ退避する"),
        @("full-screen-fallback", "全画面不許可で高優先度通知操作を維持する"),
        @("notification-permission", "通知権限の拒否と許可を端末UIで確認する"),
        @("timezone-recalculation", "タイムゾーン変更後に次回予定を再計算する"),
        @("date-recalculation", "日付・時刻変更後に次回予定を再計算する"),
        @("package-update-reschedule", "更新後に次回予定を再登録する"),
        @("reboot-reschedule", "再起動後に次回予定を再登録する"),
        @("battery-optimization-enabled", "通常の電池最適化下でOEM挙動を確認する"),
        @("battery-optimization-exempt", "明示的な最適化除外時のOEM挙動を確認する"),
        @("talkback", "TalkBackの順序・役割・状態・操作を確認する")
    )
    return @($items | ForEach-Object {
        [ordered]@{
            id = $_[0]
            description = $_[1]
            status = "MANUAL REQUIRED"
            evidenceReference = $null
        }
    })
}

function New-Evidence {
    return [ordered]@{
        schemaVersion = 1
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        evidenceMode = "READ_ONLY_INVENTORY"
        targetEnvironment = $TargetEnvironment
        declaredBuildSha = $BuildSha.ToLowerInvariant()
        sourceShaVerified = $false
        packageName = $PackageName
        safety = [ordered]@{
            deviceStateChanged = $false
            appStateChanged = $false
            rawSerialStored = $false
            rawAdbOutputStored = $false
            manualChecksExecuted = $false
        }
        automatedPreconditions = [ordered]@{
            adbAvailable = "NOT_EVALUATED"
            exactlyOneConnectedDevice = "NOT_EVALUATED"
            deviceAuthorized = "NOT_EVALUATED"
            physicalDevice = "NOT_EVALUATED"
            packageInstalled = "NOT_EVALUATED"
            installedArtifact = "NOT_EVALUATED"
            debugBuild = if ($TargetEnvironment -eq "debug") { "NOT_EVALUATED" } else { "NOT_APPLICABLE" }
        }
        device = [ordered]@{
            serialSha256 = $null
            manufacturer = $null
            model = $null
            androidVersion = $null
            apiLevel = $null
            buildFingerprintSha256 = $null
            timezone = $null
            automaticTimezone = $null
        }
        app = [ordered]@{
            installed = $false
            versionName = $null
            versionCode = $null
            debuggable = $null
            baseApkSha256 = $null
            signingCertificateSha256Digests = @()
        }
        capabilityObservations = [ordered]@{
            batteryOptimizationExempt = $null
            scheduleExactAlarm = "UNKNOWN"
            fullScreenIntent = "UNKNOWN"
            postNotifications = "UNKNOWN"
        }
        manualAcceptance = New-ManualAcceptanceItems
        result = "FAIL"
        failureCategory = $null
    }
}

function Write-Evidence {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Evidence,
        [Parameter(Mandatory)] [string]$PathSuffix
    )

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        [void](New-Item -ItemType Directory -Path $OutputDirectory)
    }
    $resolvedOutput = (Resolve-Path -LiteralPath $OutputDirectory).Path
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssfffZ")
    $safeSuffix = $PathSuffix -replace '[^a-zA-Z0-9-]', '-'
    $path = Join-Path $resolvedOutput "android-physical-acceptance-$timestamp-$safeSuffix.json"
    $Evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

$evidence = New-Evidence
$serialHash = $null
$failureCategory = "preflight"

try {
    if ($PackageName -cne "jp.universityschedule.app.staging") {
        $failureCategory = "package-target-mismatch"
        throw "Physical acceptance is restricted to the isolated staging package."
    }
    $adb = Resolve-AdbCommand
    $apkSigner = Resolve-ApkSignerCommand
    $evidence.automatedPreconditions.adbAvailable = "PASS"

    $deviceLines = Invoke-AdbReadOnly -Command $adb -Arguments @("devices", "-l") -Operation "the connected-device inventory"
    $entries = @(Get-DeviceEntries -Lines $deviceLines)
    if ($entries.Count -ne 1) {
        $evidence.automatedPreconditions.exactlyOneConnectedDevice = "FAIL"
        $failureCategory = if ($entries.Count -eq 0) { "device-missing" } else { "device-count" }
        throw "Exactly one connected Android device is required."
    }
    $evidence.automatedPreconditions.exactlyOneConnectedDevice = "PASS"

    $serial = $entries[0].Serial
    $serialHash = Get-Sha256 -Value $serial
    $evidence.device.serialSha256 = $serialHash
    if ($entries[0].State -ne "device") {
        $evidence.automatedPreconditions.deviceAuthorized = "FAIL"
        $failureCategory = "device-authorization"
        throw "The single Android device must be authorized and online."
    }
    $getState = Invoke-AdbReadOnly -Command $adb -Arguments @("-s", $serial, "get-state") -Operation "device authorization"
    if (($getState -join "").Trim() -ne "device") {
        $evidence.automatedPreconditions.deviceAuthorized = "FAIL"
        $failureCategory = "device-authorization"
        throw "The single Android device must be authorized and online."
    }
    $evidence.automatedPreconditions.deviceAuthorized = "PASS"

    $properties = [ordered]@{}
    foreach ($propertyName in @(
        "ro.kernel.qemu",
        "ro.boot.qemu",
        "ro.hardware",
        "ro.product.manufacturer",
        "ro.product.model",
        "ro.build.version.release",
        "ro.build.version.sdk",
        "ro.build.fingerprint",
        "persist.sys.timezone"
    )) {
        $propertyOutput = Invoke-AdbReadOnly -Command $adb -Arguments @("-s", $serial, "shell", "getprop", $propertyName) -Operation "Android build properties"
        $properties[$propertyName] = ($propertyOutput -join "`n").Trim()
    }
    $fingerprint = [string]$properties["ro.build.fingerprint"]
    $isEmulator = $serial -match '^emulator-' -or
        $properties["ro.kernel.qemu"] -eq "1" -or
        $properties["ro.boot.qemu"] -eq "1" -or
        $properties["ro.hardware"] -match '(?i)goldfish|ranchu' -or
        $fingerprint -match '(?i)^generic(?:/|_)|/generic(?:/|_)|sdk_gphone|emulator'
    if ($isEmulator) {
        $evidence.automatedPreconditions.physicalDevice = "FAIL"
        $failureCategory = "emulator-rejected"
        throw "An Android emulator cannot be used for physical acceptance."
    }
    $evidence.automatedPreconditions.physicalDevice = "PASS"
    $evidence.device.manufacturer = [string]$properties["ro.product.manufacturer"]
    $evidence.device.model = [string]$properties["ro.product.model"]
    $evidence.device.androidVersion = [string]$properties["ro.build.version.release"]
    $evidence.device.apiLevel = [string]$properties["ro.build.version.sdk"]
    if (-not [string]::IsNullOrWhiteSpace($fingerprint)) {
        $evidence.device.buildFingerprintSha256 = Get-Sha256 -Value $fingerprint
    }
    $evidence.device.timezone = [string]$properties["persist.sys.timezone"]

    $autoTimezone = Invoke-AdbReadOnly -Command $adb -Arguments @("-s", $serial, "shell", "settings", "get", "global", "auto_time_zone") -Operation "automatic-timezone status"
    $evidence.device.automaticTimezone = switch (($autoTimezone -join "").Trim()) {
        "1" { $true }
        "0" { $false }
        default { $null }
    }

    $packagePath = @(Invoke-AdbOptionalRead -Command $adb -Arguments @("-s", $serial, "shell", "pm", "path", $PackageName))
    $installed = @($packagePath | Where-Object { $_ -match '^package:' }).Count -gt 0
    $evidence.app.installed = $installed
    if (-not $installed) {
        $evidence.automatedPreconditions.packageInstalled = "FAIL"
        $failureCategory = "package-missing"
        throw "The expected Android package is not installed."
    }
    $evidence.automatedPreconditions.packageInstalled = "PASS"

    $packageDump = Invoke-AdbReadOnly -Command $adb -Arguments @("-s", $serial, "shell", "dumpsys", "package", $PackageName) -Operation "installed-package metadata"
    $packageText = $packageDump -join "`n"
    if ($packageText -match '(?m)^\s*versionName=(?<value>\S+)') {
        $evidence.app.versionName = $Matches.value
    }
    if ($packageText -match '(?m)^\s*versionCode=(?<value>\d+)') {
        $evidence.app.versionCode = $Matches.value
    }
    $debuggable = $packageText -match '(?im)(?:pkgFlags|flags)=\[[^\]]*\bDEBUGGABLE\b'
    $evidence.app.debuggable = $debuggable
    if ($TargetEnvironment -eq "debug") {
        if (-not $debuggable) {
            $evidence.automatedPreconditions.debugBuild = "FAIL"
            $failureCategory = "non-debug-package"
            throw "Debug acceptance requires an installed debuggable package."
        }
        $evidence.automatedPreconditions.debugBuild = "PASS"
    }

    $baseApkEntries = @(
        $packagePath |
            Where-Object { $_ -match '^package:(?<path>/data/app/.+/base\.apk)$' } |
            ForEach-Object { $_.Substring("package:".Length) }
    )
    if ($baseApkEntries.Count -ne 1 -or
        $baseApkEntries[0] -notmatch '^/data/app/[A-Za-z0-9._=+/-]{1,1024}/base\.apk$') {
        $evidence.automatedPreconditions.installedArtifact = "FAIL"
        $failureCategory = "artifact-identity"
        throw "The installed base APK path was not uniquely readable."
    }
    $temporaryApk = Join-Path ([IO.Path]::GetTempPath()) `
        "university-schedule-installed-$([guid]::NewGuid().ToString('N')).apk"
    try {
        $null = Invoke-NativeReadOnly `
            -Command $adb `
            -Arguments @("-s", $serial, "pull", $baseApkEntries[0], $temporaryApk) `
            -Operation "the installed base APK"
        if (-not (Test-Path -LiteralPath $temporaryApk -PathType Leaf)) {
            throw "The installed base APK was not copied for local hashing."
        }
        $evidence.app.baseApkSha256 = (Get-FileHash `
                -Algorithm SHA256 `
                -LiteralPath $temporaryApk
            ).Hash.ToLowerInvariant()
        $signerOutput = Invoke-NativeReadOnly `
            -Command $apkSigner `
            -Arguments @("verify", "--print-certs", $temporaryApk) `
            -Operation "the installed signing certificate"
        $certificateDigests = @(
            $signerOutput |
                ForEach-Object {
                    if ($_ -match '(?i)certificate SHA-256 digest:\s*(?<digest>[0-9a-f]{64})\s*$') {
                        $Matches.digest.ToLowerInvariant()
                    }
                } |
                Sort-Object -Unique
        )
        if ($certificateDigests.Count -lt 1 -or $certificateDigests.Count -gt 5) {
            throw "The installed signing certificate digest was not readable."
        }
        $evidence.app.signingCertificateSha256Digests = $certificateDigests
        $evidence.automatedPreconditions.installedArtifact = "PASS"
    }
    catch {
        $evidence.automatedPreconditions.installedArtifact = "FAIL"
        $failureCategory = "artifact-identity"
        throw
    }
    finally {
        if (Test-Path -LiteralPath $temporaryApk -PathType Leaf) {
            [IO.File]::Delete($temporaryApk)
        }
    }

    $deviceIdle = @(Invoke-AdbOptionalRead -Command $adb -Arguments @("-s", $serial, "shell", "dumpsys", "deviceidle", "whitelist"))
    if ($deviceIdle.Count -gt 0) {
        $evidence.capabilityObservations.batteryOptimizationExempt = ($deviceIdle -join "`n") -match [regex]::Escape($PackageName)
    }

    foreach ($appOp in @(
        @("SCHEDULE_EXACT_ALARM", "scheduleExactAlarm"),
        @("USE_FULL_SCREEN_INTENT", "fullScreenIntent"),
        @("POST_NOTIFICATION", "postNotifications")
    )) {
        $appOpOutput = @(Invoke-AdbOptionalRead -Command $adb -Arguments @("-s", $serial, "shell", "cmd", "appops", "get", $PackageName, $appOp[0]))
        $evidence.capabilityObservations[$appOp[1]] = Get-AppOpObservation -Lines $appOpOutput
    }

    $evidence.result = "INVENTORY_READY"
    $evidence.failureCategory = $null
    $evidencePath = Write-Evidence -Evidence $evidence -PathSuffix $serialHash.Substring(0, 12)
    Write-Host "Physical-device inventory is ready. Manual acceptance remains MANUAL REQUIRED."
    Write-Host "Evidence: $evidencePath"
    exit 0
}
catch {
    $safeFailureMessage = $_.Exception.Message
    $evidence.result = "FAIL"
    $evidence.failureCategory = $failureCategory
    $suffix = if ($null -ne $serialHash) { $serialHash.Substring(0, 12) } else { "no-device" }
    try {
        $evidencePath = Write-Evidence -Evidence $evidence -PathSuffix $suffix
        Write-Host "Failure evidence: $evidencePath"
    }
    catch {
        Write-Host "Failure evidence could not be written safely inside the workspace."
    }
    Write-Error "Physical acceptance preflight failed: $safeFailureMessage"
    exit 1
}
