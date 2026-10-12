package jp.universityschedule.app

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Build
import android.os.Bundle
import android.view.WindowInsets
import android.view.inputmethod.InputMethodManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import jp.universityschedule.alarm.MorningAlarmPlatformChannel
import jp.universityschedule.scope.NativeScope
import jp.universityschedule.scope.NativeScopeFence
import jp.universityschedule.notification.LocalNotificationCoordinator
import jp.universityschedule.notification.NativeSqliteException
import jp.universityschedule.notification.NativeScopeSnapshot
import jp.universityschedule.notification.NotificationRefillScheduler
import jp.universityschedule.notification.isBusy
import jp.universityschedule.notification.matches
import jp.universityschedule.widget.TimetableSnapshotParser
import jp.universityschedule.widget.WIDGET_PREFERENCES_NAME
import jp.universityschedule.widget.WIDGET_ACTIVATION_TOKEN_KEY
import jp.universityschedule.widget.WIDGET_GENERATION_KEY
import jp.universityschedule.widget.WIDGET_OWNER_HASH_KEY
import jp.universityschedule.widget.WIDGET_REGION_ID_KEY
import jp.universityschedule.widget.WIDGET_SNAPSHOT_KEY
import jp.universityschedule.widget.WeeklyTimetableWidget

class MainActivity : FlutterActivity() {
    private var morningAlarmPlatformChannel: MorningAlarmPlatformChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        val staleScopedLaunch = intent?.hasExtra("scope_generation") == true &&
            (!NativeScopeFence.matchesIntent(this, intent) ||
                (intent?.hasExtra("ordinary_identity") == true &&
                    !LocalNotificationCoordinator.validateTap(this, intent)))
        if (staleScopedLaunch) {
            // FlutterActivity must receive exactly one super.onCreate call, but
            // the stale URI/extras must not reach app_links or Flutter.
            setIntent(Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_MAIN
            })
        }
        super.onCreate(savedInstanceState)
        if (staleScopedLaunch) finish()
    }

    override fun onNewIntent(intent: Intent) {
        if (intent.hasExtra("scope_generation") &&
            (!NativeScopeFence.matchesIntent(this, intent) ||
                (intent.hasExtra("ordinary_identity") &&
                    !LocalNotificationCoordinator.validateTap(this, intent)))) {
            return
        }
        super.onNewIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        morningAlarmPlatformChannel = MorningAlarmPlatformChannel(
            activity = this,
            messenger = flutterEngine.dartExecutor.binaryMessenger,
        )
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "jp.universityschedule.app/native_scope",
        ).setMethodCallHandler { call, result ->
            try {
                val scope = when (call.method) {
                    "prepareRegion" -> NativeScopeFence.prepare(
                        this,
                        call.argument<String>("regionId") ?: error("regionId is required"),
                    )
                    "activateOwner" -> NativeScopeFence.activateOwner(
                        this,
                        call.argument<String>("regionId") ?: error("regionId is required"),
                        call.argument<String>("ownerId") ?: error("ownerId is required"),
                    )
                    "deactivate" -> NativeScopeFence.deactivate(this)
                    "current" -> NativeScopeFence.current(this)
                    else -> {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                }
                result.success(scope.toMap())
            } catch (error: Throwable) {
                result.error("native_scope_rejected", error.message, null)
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "jp.universityschedule.app/widget_bridge",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveSnapshot" -> {
                    val payload = call.argument<String>("payload")
                    val regionId = call.argument<String>("regionId")
                    val ownerHash = call.argument<String>("ownerHash")
                    val activationToken = call.argument<String>("activationToken")
                    val generation = (call.argument<Number>("generation"))?.toLong()
                    if (regionId == null || ownerHash == null || activationToken == null || generation == null ||
                        !NativeScopeFence.matches(this, regionId, ownerHash, generation, activationToken)
                    ) {
                        result.error(
                            "stale_widget_snapshot",
                            "The widget snapshot scope is no longer active.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    if (TimetableSnapshotParser.parse(payload) == null) {
                        result.error(
                            "invalid_widget_snapshot",
                            "The widget snapshot contract is invalid.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    val saved = getSharedPreferences(
                        WIDGET_PREFERENCES_NAME,
                        Context.MODE_PRIVATE,
                    ).edit()
                        .putString(WIDGET_SNAPSHOT_KEY, payload)
                        .putString(WIDGET_REGION_ID_KEY, regionId)
                        .putString(WIDGET_OWNER_HASH_KEY, ownerHash)
                        .putLong(WIDGET_GENERATION_KEY, generation)
                        .putString(WIDGET_ACTIVATION_TOKEN_KEY, activationToken)
                        .commit()
                    if (!saved) {
                        result.error(
                            "widget_snapshot_write_failed",
                            "The widget snapshot could not be saved.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    WeeklyTimetableWidget.updateAll(this)
                    result.success(null)
                }
                "readSnapshot" -> {
                    val preferences = getSharedPreferences(
                        WIDGET_PREFERENCES_NAME,
                        Context.MODE_PRIVATE,
                    )
                    val scope = NativeScopeFence.current(this)
                    val valid = scope.active &&
                        scope.regionId == preferences.getString(WIDGET_REGION_ID_KEY, null) &&
                        scope.ownerHash == preferences.getString(WIDGET_OWNER_HASH_KEY, null) &&
                        scope.generation == preferences.getLong(WIDGET_GENERATION_KEY, -1L) &&
                        scope.activationToken == preferences.getString(WIDGET_ACTIVATION_TOKEN_KEY, null)
                    result.success(if (valid) preferences.getString(WIDGET_SNAPSHOT_KEY, null) else null)
                }
                else -> result.notImplemented()
            }
        }

        val sqliteIdentityMessenger = flutterEngine.dartExecutor.binaryMessenger
        val sqliteIdentityQueue = sqliteIdentityMessenger.makeBackgroundTaskQueue()
        MethodChannel(
            sqliteIdentityMessenger,
            "jp.universityschedule.app/sqlite_identity",
            StandardMethodCodec.INSTANCE,
            sqliteIdentityQueue,
        ).setMethodCallHandler { call, result ->
            if (call.method == "checkHealth") {
                try {
                    val region = call.argument<String>("region") ?: error("storage region is required")
                    jp.universityschedule.notification.NativeSqliteIdentity.checkHealth(this, region)
                    result.success(null)
                } catch (error: Throwable) {
                    result.error("sqlite_health_unavailable", error.message, null)
                }
                return@setMethodCallHandler
            }
            if (call.method == "recordCorruption") {
                try {
                    val region = call.argument<String>("region") ?: error("storage region is required")
                    val reason = call.argument<String>("reason") ?: "dart_sqlite_corruption"
                    jp.universityschedule.notification.NativeSqliteIdentity.recordCorruption(this, region, reason)
                    result.success(null)
                } catch (error: Throwable) {
                    result.error("sqlite_health_latch_failed", error.message, null)
                }
                return@setMethodCallHandler
            }
            if (call.method != "verify") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val values = call.argument<List<Any?>>("dartAddresses")
                    ?: error("dart SQLite binding addresses are required")
                val addresses = values.map {
                    (it as? Number)?.toLong() ?: error("invalid dart SQLite binding address")
                }.toLongArray()
                    result.success(
                        jp.universityschedule.notification.NativeSqliteIdentity.verify(
                            this,
                            addresses,
                        ),
                )
            } catch (error: Throwable) {
                result.error("sqlite_identity_rejected", error.message, null)
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "jp.universityschedule.app/local_notifications",
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "publishProjection" -> {
                        val raw = call.arguments as? Map<*, *> ?: error("notification payload is required")
                        val root = org.json.JSONObject(raw.mapKeys { it.key.toString() })
                        val scope = NativeScopeFence.current(this)
                        val scopeJson = root.optJSONObject("scope") ?: error("notification scope is required")
                        val expected = NativeScopeSnapshot.fromJson(scopeJson)
                        if (!expected.matches(scope)) {
                            result.error("stale_notification_scope", "The notification scope is no longer active.", null)
                            return@setMethodCallHandler
                        }
                        if (!LocalNotificationCoordinator.publishFromBackground(this, scope, root)) {
                            // A CAS/context race is a normal bounded retry signal for
                            // Dart's publication loop. Keep the method call successful
                            // so the shared runtime can inspect blockedReason instead
                            // of treating a recoverable race as a transport failure.
                            result.success(
                                mapOf(
                                    "permission" to "blocked",
                                    "exactAlarm" to "unknown",
                                    "channel" to "unknown",
                                    "scheduledCount" to 0,
                                    "blockedReason" to "stale_projection",
                                ),
                            )
                            return@setMethodCallHandler
                        }
                        val plans = org.json.JSONArray().also { array ->
                            root.optJSONArray("plans")?.let { source ->
                                for (index in 0 until source.length()) array.put(source.get(index))
                            }
                        }
                        result.success(LocalNotificationCoordinator.reconcile(this, "", scope, plans).toMap())
                        NotificationRefillScheduler.ensureDaily(this)
                        NotificationRefillScheduler.requestRefill(this, "foreground-publication")
                    }
                    "reconcile" -> {
                        val scope = NativeScopeFence.current(this)
                        val regionId = call.argument<String>("regionId")
                        val ownerHash = call.argument<String>("ownerHash")
                        val token = call.argument<String>("activationToken")
                        val generation = call.argument<Number>("generation")?.toLong()
                        if (!NativeScopeFence.matches(this, regionId, ownerHash, generation ?: Long.MIN_VALUE, token)) {
                            result.error("stale_notification_scope", "The notification scope is no longer active.", null)
                            return@setMethodCallHandler
                        }
                        // Flutter's method-channel map is converted explicitly so
                        // malformed payloads cannot reach AlarmManager.
                        val planList = org.json.JSONArray()
                        val rawPlans = call.argument<List<*>>("plans") ?: emptyList<Any>()
                        rawPlans.forEach { raw ->
                            if (raw !is Map<*, *>) error("Invalid notification plan")
                            planList.put(org.json.JSONObject(raw.mapKeys { it.key.toString() }))
                        }
                        // The native side resolves the scoped SQLite path from
                        // the active region fence; the bridge's legacy path
                        // field is intentionally ignored.
                        result.success(LocalNotificationCoordinator.reconcile(this, "", scope, planList).toMap())
                        NotificationRefillScheduler.ensureDaily(this)
                        NotificationRefillScheduler.requestRefill(this, "foreground-reconcile")
                    }
                    "openExactAlarmSettings" -> {
                        LocalNotificationCoordinator.openExactAlarmSettings(this)
                        result.success(null)
                    }
                    "openNotificationSettings" -> {
                        LocalNotificationCoordinator.openNotificationSettings(this)
                        result.success(null)
                    }
                    "readInbox" -> result.success(LocalNotificationCoordinator.readInbox(this))
                    else -> result.notImplemented()
                }
            } catch (error: Throwable) {
                if (error is NativeSqliteException && error.isBusy) {
                    if (call.method == "publishProjection" || call.method == "reconcile") {
                        NotificationRefillScheduler.requestRefill(this, "storage-busy")
                        result.success(
                            mapOf(
                                "permission" to "blocked",
                                "exactAlarm" to "unknown",
                                "channel" to "unknown",
                                "scheduledCount" to 0,
                                "blockedReason" to "storage_busy",
                            ),
                        )
                    } else if (call.method == "readInbox") {
                        // readInbox has a List contract; never return the
                        // publication status map on this channel.
                        result.error("storage_busy", error.message, null)
                    } else {
                        result.error("notification_busy", error.message, null)
                    }
                } else {
                    result.error("notification_rejected", error.message, null)
                }
            }
        }

        if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) == 0) return
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "jp.universityschedule.app/android_e2e",
        ).setMethodCallHandler { call, result ->
            if (call.method != "hideImeAndRefreshInsets") {
                result.notImplemented()
                return@setMethodCallHandler
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val controller = window.insetsController
                if (controller == null) {
                    result.error(
                        "ime_controller_unavailable",
                        "WindowInsetsController is unavailable.",
                        null,
                    )
                    return@setMethodCallHandler
                }
                controller.hide(WindowInsets.Type.ime())
            } else {
                val inputMethodManager =
                    getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                inputMethodManager.hideSoftInputFromWindow(window.decorView.windowToken, 0)
            }
            window.decorView.requestApplyInsets()
            result.success(null)
        }
    }

    private fun NativeScope.toMap(): Map<String, Any?> = mapOf(
        "regionId" to regionId,
        "ownerHash" to ownerHash,
        "activationToken" to activationToken,
        "generation" to generation,
        "active" to active,
        "buildStamp" to BuildConfig.STORAGE_CONFIG_STAMP,
    )

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (
            morningAlarmPlatformChannel?.onRequestPermissionsResult(
                requestCode,
                permissions,
                grantResults,
            ) == true
        ) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        morningAlarmPlatformChannel?.detach()
        morningAlarmPlatformChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
