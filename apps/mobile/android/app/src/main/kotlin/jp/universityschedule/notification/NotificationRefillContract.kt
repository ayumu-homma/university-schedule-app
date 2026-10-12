package jp.universityschedule.notification

import android.content.Context
import android.content.Intent
import org.json.JSONArray
import org.json.JSONObject

/** Native half of the phase 7.1 background refill contract.
 *
 * This file intentionally contains no recurrence or calendar logic. Dart is
 * the canonical planner; Android only validates the scope/freshness tuple,
 * publishes the complete derived projection and reserves OS wakeups.
 */
internal object NotificationRefillContract {
    const val VERSION = 1
    const val CHANNEL = "jp.universityschedule.app/notification_background"
    const val METHOD_REFILL = "refill"
    const val METHOD_READY = "ready"
    const val METHOD_RESULT = "result"
    const val ENTRYPOINT = "phase71HeadlessEntryPoint"

    const val EXTRA_RUN_TOKEN = "notification_refill_run_token"
    const val EXTRA_JOB_ID = "notification_refill_job_id"

    const val DAILY_JOB_ID = 71_001
    const val REFILL_JOB_ID = 71_002

    const val DEBUG_FIXTURE_ACTION = "jp.universityschedule.app.action.PHASE71_CLEAR_EXAM_DERIVED"
    const val DEBUG_FIXTURE_TITLE = "phase71_fixture_title"

    const val PREFS = "ordinary_notifications_v1"
    const val JOB_STATE_KEY = "refillJobState"

    fun request(context: Context, runToken: String, jobId: Int): Intent =
        Intent(context, NotificationRefillJobService::class.java).apply {
            putExtra(EXTRA_RUN_TOKEN, runToken)
            putExtra(EXTRA_JOB_ID, jobId)
        }

    fun parsePlans(value: Any?): JSONArray = when (value) {
        is JSONArray -> value
        is List<*> -> JSONArray().also { array ->
            value.forEach { entry ->
                if (entry is Map<*, *>) {
                    array.put(JSONObject(entry.mapKeys { it.key.toString() }))
                }
            }
        }
        else -> JSONArray()
    }

    fun requiredLong(root: JSONObject, name: String): Long =
        if (root.has(name) && !root.isNull(name)) root.getLong(name)
        else error("notification refill field '$name' is required")

    fun requiredString(root: JSONObject, name: String): String =
        root.optString(name).takeIf { it.isNotBlank() }
            ?: error("notification refill field '$name' is required")
}

internal data class NotificationRefillContext(
    val ownerUserId: String,
    val universityId: String,
    val termId: String,
    val primaryCalendarId: String,
    val academicYear: Int,
    val rawFlags: JSONObject,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("ownerUserId", ownerUserId)
        .put("universityId", universityId)
        .put("termId", termId)
        .put("primaryCalendarId", primaryCalendarId)
        .put("academicYear", academicYear)
        .put("rawFlags", rawFlags)

    companion object {
        fun fromJson(value: JSONObject): NotificationRefillContext = NotificationRefillContext(
            ownerUserId = NotificationRefillContract.requiredString(value, "ownerUserId"),
            universityId = NotificationRefillContract.requiredString(value, "universityId"),
            termId = NotificationRefillContract.requiredString(value, "termId"),
            primaryCalendarId = NotificationRefillContract.requiredString(value, "primaryCalendarId"),
            academicYear = value.optInt("academicYear", Int.MIN_VALUE).also {
                check(it != Int.MIN_VALUE) { "notification refill academicYear is required" }
            },
            rawFlags = value.optJSONObject("rawFlags") ?: JSONObject().also { flags ->
                // Wire v1 carries the persisted profile/term flags directly
                // in context. Keep every non-identity field available to the
                // native validator while accepting the original nested test
                // fixture shape during the rolling upgrade.
                val keys = value.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    if (key !in setOf("ownerUserId", "universityId", "termId", "primaryCalendarId", "academicYear")) {
                        flags.put(key, value.get(key))
                    }
                }
            },
        )
    }
}

internal data class NotificationRefillRequest(
    val scope: NativeScopeSnapshot,
    val sourceEpoch: Long,
    val expectedProjectionEpoch: Long,
    val planningNowMs: Long,
    val windowStartMs: Long,
    val windowEndMs: Long,
    val context: NotificationRefillContext,
    val plans: JSONArray,
) {
    companion object {
        fun fromJson(value: JSONObject): NotificationRefillRequest {
            check(value.optInt("schemaVersion", -1) == NotificationRefillContract.VERSION) {
                "unsupported notification refill schema"
            }
            val scope = NativeScopeSnapshot.fromJson(value.getJSONObject("scope"))
            return NotificationRefillRequest(
                scope = scope,
                sourceEpoch = NotificationRefillContract.requiredLong(value, "sourceEpoch"),
                expectedProjectionEpoch = NotificationRefillContract.requiredLong(value, "expectedProjectionEpoch"),
                planningNowMs = NotificationRefillContract.requiredLong(value, "planningNowMs"),
                windowStartMs = NotificationRefillContract.requiredLong(value, "windowStartMs"),
                windowEndMs = NotificationRefillContract.requiredLong(value, "windowEndMs"),
                context = NotificationRefillContext.fromJson(value.getJSONObject("context")),
                plans = NotificationRefillContract.parsePlans(value.opt("plans")),
            ).also {
                check(it.windowStartMs <= it.planningNowMs && it.planningNowMs <= it.windowEndMs) {
                    "invalid notification refill window"
                }
            }
        }
    }
}

internal data class NativeScopeSnapshot(
    val regionId: String,
    val ownerHash: String,
    val activationToken: String,
    val generation: Long,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("regionId", regionId)
        .put("ownerHash", ownerHash)
        .put("activationToken", activationToken)
        .put("generation", generation)

    companion object {
        fun fromJson(value: JSONObject): NativeScopeSnapshot = NativeScopeSnapshot(
            regionId = NotificationRefillContract.requiredString(value, "regionId"),
            ownerHash = NotificationRefillContract.requiredString(value, "ownerHash"),
            activationToken = NotificationRefillContract.requiredString(value, "activationToken"),
            generation = NotificationRefillContract.requiredLong(value, "generation"),
        )
    }
}

internal fun NativeScopeSnapshot.matches(scope: jp.universityschedule.scope.NativeScope): Boolean =
    scope.active && scope.regionId == regionId && scope.ownerHash == ownerHash &&
        scope.activationToken == activationToken && scope.generation == generation
