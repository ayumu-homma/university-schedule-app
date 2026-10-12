package jp.universityschedule.alarm

import java.security.MessageDigest
import jp.universityschedule.app.BuildConfig

internal const val MORNING_ALARM_CHANNEL = "jp.universityschedule.app/morning_alarm"
internal const val MORNING_ALARM_CONTRACT_VERSION = 1
internal const val MORNING_ALARM_TIME_ZONE = "Asia/Tokyo"
internal fun morningAlarmTodayUri(): String =
    "${BuildConfig.DEEP_LINK_SCHEME}://today?source=morning-alarm"

internal const val ACTION_ALARM_FIRE =
    "jp.universityschedule.app.action.MORNING_ALARM_FIRE"
internal const val ACTION_ALARM_STOP =
    "jp.universityschedule.app.action.MORNING_ALARM_STOP"
internal const val ACTION_ALARM_SNOOZE =
    "jp.universityschedule.app.action.MORNING_ALARM_SNOOZE"
internal const val ACTION_ALARM_STOP_AND_OPEN =
    "jp.universityschedule.app.action.MORNING_ALARM_STOP_AND_OPEN"
internal const val ACTION_ALARM_OPEN_TODAY =
    "jp.universityschedule.app.action.MORNING_ALARM_OPEN_TODAY"

internal const val EXTRA_OWNER_HASH = "owner_hash"
internal const val EXTRA_ALARM_MODE = "alarm_mode"
internal const val EXTRA_IS_TEST = "is_test"
internal const val EXTRA_SCOPE_REGION_ID = "scope_region_id"
internal const val EXTRA_SCOPE_OWNER_HASH = "scope_owner_hash"
internal const val EXTRA_SCOPE_GENERATION = "scope_generation"
internal const val EXTRA_SCOPE_ACTIVATION_TOKEN = "scope_activation_token"
internal const val ALARM_MODE_REGULAR = "regular"
internal const val ALARM_MODE_SNOOZE = "snooze"
internal const val ALARM_MODE_DEBUG = "debug"

internal const val MORNING_ALARM_NOTIFICATION_ID = 41_051
internal const val REGULAR_ALARM_REQUEST_CODE = 41_052
internal const val SNOOZE_ALARM_REQUEST_CODE = 41_053
internal const val DEBUG_ALARM_REQUEST_CODE = 41_054
internal const val STOP_ACTION_REQUEST_CODE = 41_055
internal const val SNOOZE_ACTION_REQUEST_CODE = 41_056
internal const val TODAY_ACTION_REQUEST_CODE = 41_057
internal const val FULL_SCREEN_REQUEST_CODE = 41_058
internal const val SHOW_ALARM_REQUEST_CODE = 41_059

internal data class MorningAlarmSettings(
    val ownerHash: String,
    val regionId: String? = null,
    val generation: Long = 0L,
    val activationToken: String? = null,
    val enabled: Boolean = false,
    val hour: Int = 7,
    val minute: Int = 30,
    val weekdays: Set<Int> = setOf(1, 2, 3, 4, 5),
    val soundEnabled: Boolean = true,
    val vibrationEnabled: Boolean = true,
    val snoozeMinutes: Int = 10,
    val openTodayOnStop: Boolean = true,
    val lockScreenPrivacy: Boolean = true,
) {
    init {
        require(ownerHash.matches(Regex("^[a-f0-9]{64}$")))
        require(hour in 0..23)
        require(minute in 0..59)
        require(weekdays.isNotEmpty() && weekdays.all { it in 1..7 })
        require(snoozeMinutes in setOf(5, 10, 15))
    }

    fun toPlatformMap(): Map<String, Any?> =
        mapOf(
            "version" to MORNING_ALARM_CONTRACT_VERSION,
            "enabled" to enabled,
            "hour" to hour,
            "minute" to minute,
            "weekdays" to weekdays.sorted(),
            "soundEnabled" to soundEnabled,
            "vibrationEnabled" to vibrationEnabled,
            "snoozeMinutes" to snoozeMinutes,
            "openTodayOnStop" to openTodayOnStop,
            "lockScreenPrivacy" to lockScreenPrivacy,
            "regionId" to regionId,
            "generation" to generation,
            "activationToken" to activationToken,
        )

    companion object {
        fun fromPlatformMap(ownerHash: String, arguments: Map<*, *>): MorningAlarmSettings {
            require(arguments["version"] == MORNING_ALARM_CONTRACT_VERSION)
            val rawWeekdays = arguments["weekdays"] as? List<*>
                ?: throw IllegalArgumentException("weekdays is required")
            return MorningAlarmSettings(
                ownerHash = ownerHash,
                enabled = arguments.requiredBoolean("enabled"),
                hour = arguments.requiredInt("hour"),
                minute = arguments.requiredInt("minute"),
                weekdays = rawWeekdays.map {
                    (it as? Number)?.toInt()
                        ?: throw IllegalArgumentException("weekday is invalid")
                }.toSet(),
                soundEnabled = arguments.requiredBoolean("soundEnabled"),
                vibrationEnabled = arguments.requiredBoolean("vibrationEnabled"),
                snoozeMinutes = arguments.requiredInt("snoozeMinutes"),
                openTodayOnStop = arguments.requiredBoolean("openTodayOnStop"),
                lockScreenPrivacy = arguments.requiredBoolean("lockScreenPrivacy"),
            )
        }
    }
}

internal fun ownerHash(ownerId: String): String {
    val normalized = ownerId.trim()
    require(normalized.isNotEmpty() && normalized.length <= 256)
    val digest = MessageDigest.getInstance("SHA-256")
        .digest(normalized.toByteArray(Charsets.UTF_8))
    return digest.joinToString(separator = "") { byte -> "%02x".format(byte) }
}

private fun Map<*, *>.requiredBoolean(key: String): Boolean =
    this[key] as? Boolean ?: throw IllegalArgumentException("$key is required")

private fun Map<*, *>.requiredInt(key: String): Int =
    (this[key] as? Number)?.toInt()
        ?: throw IllegalArgumentException("$key is required")
