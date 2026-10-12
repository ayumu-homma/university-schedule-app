package jp.universityschedule.alarm

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import jp.universityschedule.app.MainActivity

internal class MorningAlarmScheduler(
    private val context: Context,
    private val preferences: MorningAlarmPreferences = MorningAlarmPreferences(context),
    private val nowEpochMillis: () -> Long = System::currentTimeMillis,
) {
    private val alarmManager: AlarmManager = context.getSystemService(AlarmManager::class.java)

    fun scheduleNext(settings: MorningAlarmSettings): Long? {
        cancelRegular(settings.activationToken)
        if (!settings.enabled) {
            preferences.setNextOccurrence(settings.ownerHash, null)
            return null
        }
        val triggerAt = MorningAlarmOccurrenceCalculator.nextOccurrence(
            nowEpochMillis = nowEpochMillis(),
            hour = settings.hour,
            minute = settings.minute,
            weekdays = settings.weekdays,
        )
        schedule(
            triggerAt = triggerAt,
            pendingIntent = firePendingIntent(
                requestCode = REGULAR_ALARM_REQUEST_CODE,
                ownerHash = settings.ownerHash,
                mode = ALARM_MODE_REGULAR,
                isTest = false,
                settings = settings,
            ),
        )
        preferences.setNextOccurrence(settings.ownerHash, triggerAt)
        return triggerAt
    }

    fun scheduleSnooze(settings: MorningAlarmSettings, isTest: Boolean): Long {
        cancelSnooze(settings.activationToken)
        val triggerAt = nowEpochMillis() + settings.snoozeMinutes * 60_000L
        schedule(
            triggerAt = triggerAt,
            pendingIntent = firePendingIntent(
                requestCode = SNOOZE_ALARM_REQUEST_CODE,
                ownerHash = settings.ownerHash,
                mode = ALARM_MODE_SNOOZE,
                isTest = isTest,
                settings = settings,
            ),
        )
        return triggerAt
    }

    fun scheduleDebug(settings: MorningAlarmSettings, delaySeconds: Int): Long {
        require(delaySeconds in 5..60)
        cancelDebug(settings.activationToken)
        val triggerAt = nowEpochMillis() + delaySeconds * 1_000L
        schedule(
            triggerAt = triggerAt,
            pendingIntent = firePendingIntent(
                requestCode = DEBUG_ALARM_REQUEST_CODE,
                ownerHash = settings.ownerHash,
                mode = ALARM_MODE_DEBUG,
                isTest = true,
                settings = settings,
            ),
        )
        return triggerAt
    }

    fun cancelAll(scopeToken: String? = null) {
        cancelRegular(scopeToken)
        cancelSnooze(scopeToken)
        cancelDebug(scopeToken)
    }

    fun cancelTransient() {
        val token = runCatching {
            jp.universityschedule.scope.NativeScopeFence.current(context).activationToken
        }.getOrNull()
        cancelSnooze(token)
        cancelDebug(token)
    }

    private fun schedule(triggerAt: Long, pendingIntent: PendingIntent) {
        val exactAllowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            alarmManager.canScheduleExactAlarms()
        if (exactAllowed) {
            val showIntent = PendingIntent.getActivity(
                context,
                SHOW_ALARM_REQUEST_CODE,
                context.packageManager.getLaunchIntentForPackage(context.packageName)
                    ?: Intent(context, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            try {
                alarmManager.setAlarmClock(
                    AlarmManager.AlarmClockInfo(triggerAt, showIntent),
                    pendingIntent,
                )
                return
            } catch (_: SecurityException) {
                // Special access can be revoked between capability check and use.
            }
        }
        // Exact access is user-controlled. This remains policy compliant and
        // usable, but Android may defer delivery while the device is idle.
        alarmManager.setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            triggerAt,
            pendingIntent,
        )
    }

    private fun cancelRegular(scopeToken: String? = null) = alarmManager.cancel(
        firePendingIntent(
            REGULAR_ALARM_REQUEST_CODE,
            ownerHash = "0".repeat(64),
            mode = ALARM_MODE_REGULAR,
            isTest = false,
            scopeToken = scopeToken,
        ),
    )

    private fun cancelSnooze(scopeToken: String? = null) = alarmManager.cancel(
        firePendingIntent(
            SNOOZE_ALARM_REQUEST_CODE,
            ownerHash = "0".repeat(64),
            mode = ALARM_MODE_SNOOZE,
            isTest = false,
            scopeToken = scopeToken,
        ),
    )

    private fun cancelDebug(scopeToken: String? = null) = alarmManager.cancel(
        firePendingIntent(
            DEBUG_ALARM_REQUEST_CODE,
            ownerHash = "0".repeat(64),
            mode = ALARM_MODE_DEBUG,
            isTest = true,
            scopeToken = scopeToken,
        ),
    )

    private fun firePendingIntent(
        requestCode: Int,
        ownerHash: String,
        mode: String,
        isTest: Boolean,
        settings: MorningAlarmSettings? = null,
        scopeToken: String? = null,
    ): PendingIntent = PendingIntent.getBroadcast(
        context,
        requestCode,
        Intent(context, MorningAlarmReceiver::class.java).apply {
            action = ACTION_ALARM_FIRE
            data = Uri.parse(
                "${morningAlarmTodayUri()}&scope=${scopeToken ?: settings?.activationToken ?: "none"}",
            )
            putExtra(EXTRA_OWNER_HASH, ownerHash)
            putExtra(EXTRA_ALARM_MODE, mode)
            putExtra(EXTRA_IS_TEST, isTest)
            putExtra(EXTRA_SCOPE_REGION_ID, settings?.regionId)
            putExtra(EXTRA_SCOPE_OWNER_HASH, settings?.ownerHash)
            putExtra(EXTRA_SCOPE_GENERATION, settings?.generation)
            putExtra(EXTRA_SCOPE_ACTIVATION_TOKEN, settings?.activationToken)
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}
