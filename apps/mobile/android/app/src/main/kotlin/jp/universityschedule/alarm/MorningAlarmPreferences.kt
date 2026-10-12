package jp.universityschedule.alarm

import android.content.Context
import android.content.SharedPreferences
import jp.universityschedule.scope.NativeScopeFence

internal class MorningAlarmPreferences(context: Context) {
    private val appContext: Context = context.applicationContext
    private val preferences: SharedPreferences = context.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    @Synchronized
    fun activeOwnerHash(): String? =
        preferences.getString(KEY_ACTIVE_OWNER_HASH, null)
            ?.takeIf { it.matches(Regex("^[a-f0-9]{64}$")) }

    @Synchronized
    fun setActiveOwnerHash(ownerHash: String?) {
        require(ownerHash == null || ownerHash.matches(Regex("^[a-f0-9]{64}$")))
        val editor = preferences.edit()
        if (ownerHash == null) {
            editor.remove(KEY_ACTIVE_OWNER_HASH)
        } else {
            editor.putString(KEY_ACTIVE_OWNER_HASH, ownerHash)
        }
        check(editor.commit()) { "Could not persist the active alarm owner." }
    }

    @Synchronized
    fun read(ownerHash: String): MorningAlarmSettings {
        require(ownerHash.matches(Regex("^[a-f0-9]{64}$")))
        val prefix = ownerPrefix(ownerHash)
        val scope = NativeScopeFence.current(appContext)
        val version = preferences.getInt("${prefix}version", 0)
        if (version != MORNING_ALARM_CONTRACT_VERSION) {
            return MorningAlarmSettings(
                ownerHash = ownerHash,
                regionId = scope.regionId,
                generation = scope.generation,
                activationToken = scope.activationToken,
            )
        }
        return runCatching {
            MorningAlarmSettings(
                ownerHash = ownerHash,
                regionId = scope.regionId,
                generation = scope.generation,
                activationToken = scope.activationToken,
                enabled = preferences.getBoolean("${prefix}enabled", false),
                hour = preferences.getInt("${prefix}hour", 7),
                minute = preferences.getInt("${prefix}minute", 30),
                weekdays = parseWeekdays(
                    preferences.getString("${prefix}weekdays", "1,2,3,4,5"),
                ),
                soundEnabled = preferences.getBoolean("${prefix}sound", true),
                vibrationEnabled = preferences.getBoolean("${prefix}vibration", true),
                snoozeMinutes = preferences.getInt("${prefix}snooze", 10),
                openTodayOnStop = preferences.getBoolean("${prefix}open_today", true),
                lockScreenPrivacy = preferences.getBoolean("${prefix}privacy", true),
            )
        }.getOrElse {
            // Corrupted or downgraded native state fails closed: the default is OFF.
            MorningAlarmSettings(
                ownerHash = ownerHash,
                regionId = scope.regionId,
                generation = scope.generation,
                activationToken = scope.activationToken,
            )
        }
    }

    @Synchronized
    fun readActive(): MorningAlarmSettings? = activeOwnerHash()?.let(::read)

    @Synchronized
    fun save(settings: MorningAlarmSettings) {
        val prefix = ownerPrefix(settings.ownerHash)
        val saved = preferences.edit()
            .putInt("${prefix}version", MORNING_ALARM_CONTRACT_VERSION)
            .putBoolean("${prefix}enabled", settings.enabled)
            .putInt("${prefix}hour", settings.hour)
            .putInt("${prefix}minute", settings.minute)
            .putString("${prefix}weekdays", settings.weekdays.sorted().joinToString(","))
            .putBoolean("${prefix}sound", settings.soundEnabled)
            .putBoolean("${prefix}vibration", settings.vibrationEnabled)
            .putInt("${prefix}snooze", settings.snoozeMinutes)
            .putBoolean("${prefix}open_today", settings.openTodayOnStop)
            .putBoolean("${prefix}privacy", settings.lockScreenPrivacy)
            .commit()
        check(saved) { "Could not persist morning alarm settings." }
    }

    @Synchronized
    fun nextOccurrence(ownerHash: String): Long? {
        val value = preferences.getLong("${ownerPrefix(ownerHash)}next_at", -1L)
        return value.takeIf { it > 0L }
    }

    @Synchronized
    fun setNextOccurrence(ownerHash: String, epochMillis: Long?) {
        val key = "${ownerPrefix(ownerHash)}next_at"
        val editor = preferences.edit()
        if (epochMillis == null) editor.remove(key) else editor.putLong(key, epochMillis)
        check(editor.commit()) { "Could not persist the next alarm occurrence." }
    }

    private fun ownerPrefix(ownerHash: String): String {
        val region = NativeScopeFence.current(appContext).regionId ?: "unprepared"
        return "region_${region}_owner_${ownerHash}_"
    }

    private fun parseWeekdays(value: String?): Set<Int> {
        val parsed = value.orEmpty()
            .split(',')
            .filter { it.isNotBlank() }
            .map { it.toInt() }
            .toSet()
        require(parsed.isNotEmpty() && parsed.all { it in 1..7 })
        return parsed
    }

    companion object {
        internal const val PREFERENCES_NAME = "morning_alarm_v1"
        private const val KEY_ACTIVE_OWNER_HASH = "active_owner_hash"
    }
}
