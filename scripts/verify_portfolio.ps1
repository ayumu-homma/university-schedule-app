[CmdletBinding()]
param([switch]$SkipAndroid)
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
function Run([string]$Tool, [string[]]$Arguments) {
    & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Tool failed with exit code $LASTEXITCODE" }
}
Push-Location $workspace
try {
    Run python @('scripts/verify_public_source.py')
    $gitRoot = Split-Path -Parent (Split-Path -Parent (Get-Command git).Source)
    Run (Join-Path $gitRoot 'bin/bash.exe') @('scripts/test_android_e2e_runner_disk_guard.sh')
    Set-Location packages/shared_domain
    Run dart @('pub','get','--enforce-lockfile')
    Run dart @('format','--output=none','--set-exit-if-changed','lib','test')
    Run dart @('analyze')
    Run dart @('test')
    Set-Location ../../apps/mobile
    Run flutter @('pub','get','--enforce-lockfile')
    Run dart @('run','build_runner','build','--delete-conflicting-outputs')
    Run dart @('format','--output=none','--set-exit-if-changed','lib','test','tool_tests','integration_test')
    Run flutter @('analyze','--fatal-infos','--fatal-warnings')
    Run python @('../../scripts/run_flutter_local_tests.py','--coverage')
    if ($SkipAndroid) {
        Write-Host 'NOT_RUN: Android build/JVM explicitly skipped; no Android acceptance.'
    } else {
        Run flutter @('build','apk','--flavor','staging','--debug','--dart-define=APP_ENV=local','--dart-define=APP_DEMO_MODE=true','--dart-define=APP_DEEP_LINK_SCHEME=unischedule-staging')
        Set-Location android
        Run ./gradlew.bat @(':app:testStagingDebugUnitTest','--no-daemon')
        Set-Location ..
    }
    Set-Location ../admin
    Run npm.cmd @('ci')
    Run npm.cmd @('run','lint')
    Run npm.cmd @('run','build')
    Run node @('scripts/run-local-tests.mjs')
    Run npm.cmd @('audit','--audit-level=high')
    Write-Host 'PASS: selected local commands. SQL/Edge/device checks are separate; see docs/TESTING.md.'
} finally { Pop-Location }
