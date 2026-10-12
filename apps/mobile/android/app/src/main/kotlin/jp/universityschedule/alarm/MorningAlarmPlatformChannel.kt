package jp.universityschedule.alarm

import android.Manifest
import android.app.AlarmManager
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import jp.universityschedule.scope.NativeScope
import jp.universityschedule.scope.NativeScopeFence

class MorningAlarmPlatformChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, MORNING_ALARM_CHANNEL)
    private val coordinator = MorningAlarmCoordinator(activity)
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingPermissionOwnerId: String? = null
    private var pendingPermissionScope: NativeScope? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "synchronizeOwner" -> synchronizeOwner(call, result)
                "readState" -> withOwner(call, result, reconcile = true)
                "saveSettings" -> saveSettings(call, result)
                "requestNotificationPermission" -> requestNotificationPermission(call, result)
                "openExactAlarmSettings" -> openExactAlarmSettings(call, result)
                "openFullScreenSettings" -> openFullScreenSettings(call, result)
                "scheduleDebugTest" -> scheduleDebugTest(call, result)
                else -> result.notImplemented()
            }
        } catch (_: IllegalArgumentException) {
            result.error(
                "invalid_morning_alarm_arguments",
                "The morning alarm request is invalid.",
                null,
            )
        } catch (_: IllegalStateException) {
            result.error(
                "morning_alarm_state_unavailable",
                "The morning alarm state could not be updated.",
                null,
            )
        } catch (_: SecurityException) {
            result.error(
                "morning_alarm_permission_denied",
                "Android denied the requested alarm operation.",
                null,
            )
        } catch (_: Exception) {
            result.error(
                "morning_alarm_unavailable",
                "The morning alarm operation is unavailable on this device.",
                null,
            )
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST_CODE) return false
        val result = pendingPermissionResult ?: return true
        val ownerId = pendingPermissionOwnerId
        val scope = pendingPermissionScope
        pendingPermissionResult = null
        pendingPermissionOwnerId = null
        pendingPermissionScope = null
        if (
            permissions.none { it == Manifest.permission.POST_NOTIFICATIONS } ||
            grantResults.isEmpty()
        ) {
            result.error(
                "notification_permission_interrupted",
                "The notification permission request did not complete.",
                null,
            )
            return true
        }
        if (ownerId == null) {
            result.error("alarm_owner_changed", "The alarm owner changed.", null)
            return true
        }
        val current = scope
        if (current == null || !NativeScopeFence.matches(
                activity,
                current.regionId,
                current.ownerHash,
                current.generation,
                current.activationToken,
            )) {
            result.error("alarm_owner_changed", "The alarm owner changed.", null)
            return true
        }
        runCatching {
            stateFor(ownerId, reconcile = true, expectedScope = current)
        }
            .onSuccess(result::success)
            .onFailure {
                result.error(
                    "morning_alarm_state_unavailable",
                    "The morning alarm state could not be refreshed.",
                    null,
                )
            }
        return true
    }

    fun detach() {
        pendingPermissionResult?.error(
            "notification_permission_interrupted",
            "The notification permission request was interrupted.",
            null,
        )
        pendingPermissionResult = null
        pendingPermissionOwnerId = null
        pendingPermissionScope = null
        channel.setMethodCallHandler(null)
    }

    private fun synchronizeOwner(call: MethodCall, result: MethodChannel.Result) {
        val rawOwnerId = call.argument<Any?>("ownerId")
        require(rawOwnerId == null || rawOwnerId is String)
        val ownerId = rawOwnerId?.trim()
        val expectedScope = expectedScope(call)
        val postScope = coordinator.synchronizeOwner(ownerId, expectedScope)
        result.success(
            if (ownerId == null) {
                emptyMap<String, Any?>()
            } else {
                stateFor(
                    ownerId,
                    reconcile = false,
                    expectedScope = postScope,
                )
            },
        )
    }

    private fun withOwner(
        call: MethodCall,
        result: MethodChannel.Result,
        reconcile: Boolean,
    ) {
        val ownerId = requiredOwnerId(call)
        val expectedScope = expectedScope(call)
        result.success(stateFor(ownerId, reconcile, expectedScope))
    }

    private fun saveSettings(call: MethodCall, result: MethodChannel.Result) {
        val ownerId = requiredOwnerId(call)
        val arguments = call.arguments as? Map<*, *>
            ?: throw IllegalArgumentException("settings are required")
        val expectedScope = expectedScope(call)
        coordinator.save(ownerId, arguments, expectedScope)
        result.success(
            stateFor(ownerId, reconcile = false, expectedScope = expectedScope),
        )
    }

    private fun requestNotificationPermission(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val ownerId = requiredOwnerId(call)
        val expectedScope = expectedScope(call)
        coordinator.readActive(ownerId, reconcile = false, expectedScope = expectedScope)
        if (
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(
                stateFor(ownerId, reconcile = true, expectedScope = expectedScope),
            )
            return
        }
        if (pendingPermissionResult != null) {
            result.error(
                "notification_permission_in_progress",
                "A notification permission request is already in progress.",
                null,
            )
            return
        }
        pendingPermissionResult = result
        pendingPermissionOwnerId = ownerId
        pendingPermissionScope = expectedScope
        activity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE,
        )
    }

    private fun openExactAlarmSettings(call: MethodCall, result: MethodChannel.Result) {
        val ownerId = requiredOwnerId(call)
        val expectedScope = expectedScope(call)
        coordinator.readActive(ownerId, reconcile = false, expectedScope = expectedScope)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            activity.startActivity(
                Intent(
                    Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                    Uri.parse("package:${activity.packageName}"),
                ),
            )
        }
        result.success(
            stateFor(ownerId, reconcile = true, expectedScope = expectedScope),
        )
    }

    private fun openFullScreenSettings(call: MethodCall, result: MethodChannel.Result) {
        val ownerId = requiredOwnerId(call)
        val expectedScope = expectedScope(call)
        coordinator.readActive(ownerId, reconcile = false, expectedScope = expectedScope)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            activity.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                    Uri.parse("package:${activity.packageName}"),
                ),
            )
        }
        result.success(
            stateFor(ownerId, reconcile = true, expectedScope = expectedScope),
        )
    }

    private fun scheduleDebugTest(call: MethodCall, result: MethodChannel.Result) {
        val ownerId = requiredOwnerId(call)
        val delaySeconds = call.argument<Number>("delaySeconds")?.toInt()
            ?: throw IllegalArgumentException("delaySeconds is required")
        val expectedScope = expectedScope(call)
        coordinator.scheduleDebug(ownerId, delaySeconds, expectedScope)
        result.success(
            stateFor(ownerId, reconcile = false, expectedScope = expectedScope),
        )
    }

    private fun stateFor(
        ownerId: String,
        reconcile: Boolean,
        expectedScope: NativeScope,
    ): Map<String, Any?> {
        val settings = coordinator.readActive(
            ownerId,
            reconcile,
            expectedScope = expectedScope,
        )
        val scope = NativeScopeFence.current(activity)
        return mapOf(
            "settings" to settings.toPlatformMap(),
            "capabilities" to MorningAlarmCapabilities.read(activity).toPlatformMap(),
            "nextOccurrenceEpochMillis" to coordinator.nextOccurrence(settings),
            "scopeRegionId" to scope.regionId,
            "scopeOwnerHash" to scope.ownerHash,
            "scopeGeneration" to scope.generation,
            "scopeActivationToken" to scope.activationToken,
            "scopeActive" to scope.active,
        )
    }

    private fun expectedScope(call: MethodCall): NativeScope {
        val regionId = call.argument<String>("expectedScopeRegionId")
        val ownerHash = call.argument<String>("expectedScopeOwnerHash")
        val token = call.argument<String>("expectedScopeActivationToken")
        val generation = call.argument<Number>("expectedScopeGeneration")
            ?.toLong()
            ?: throw IllegalArgumentException("expected scope generation is required")
        val active = call.argument<Boolean>("expectedScopeActive")
            ?: throw IllegalArgumentException("expected scope activity is required")
        return NativeScope(
            regionId = regionId,
            ownerHash = ownerHash,
            activationToken = token,
            generation = generation,
            active = active,
        )
    }

    private fun requiredOwnerId(call: MethodCall): String {
        val ownerId = call.argument<String>("ownerId")?.trim().orEmpty()
        require(ownerId.isNotEmpty() && ownerId.length <= 256)
        return ownerId
    }

    companion object {
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 41_060
    }
}
