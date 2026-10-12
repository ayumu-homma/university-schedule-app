package jp.universityschedule.alarm

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.provider.Settings
import jp.universityschedule.app.R

internal class MorningAlarmNotifier(private val context: Context) {
    private val notificationManager: NotificationManager =
        context.getSystemService(NotificationManager::class.java)

    fun show(settings: MorningAlarmSettings, isTest: Boolean) {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val channelId = ensureChannel(settings)
        val stopIntent = if (settings.openTodayOnStop) {
            activityActionPendingIntent(
                requestCode = STOP_ACTION_REQUEST_CODE,
                action = ACTION_ALARM_STOP_AND_OPEN,
                settings = settings,
                isTest = isTest,
            )
        } else {
            broadcastActionPendingIntent(
                requestCode = STOP_ACTION_REQUEST_CODE,
                action = ACTION_ALARM_STOP,
                settings = settings,
                isTest = isTest,
            )
        }
        val snoozeIntent = broadcastActionPendingIntent(
            requestCode = SNOOZE_ACTION_REQUEST_CODE,
            action = ACTION_ALARM_SNOOZE,
            settings = settings,
            isTest = isTest,
        )
        val todayIntent = activityActionPendingIntent(
            requestCode = TODAY_ACTION_REQUEST_CODE,
            action = ACTION_ALARM_OPEN_TODAY,
            settings = settings,
            isTest = isTest,
        )
        val fullScreenIntent = PendingIntent.getActivity(
            context,
            FULL_SCREEN_REQUEST_CODE,
            Intent(context, MorningAlarmRingingActivity::class.java).apply {
                action = ACTION_ALARM_FIRE
                data = Uri.parse(
                    "${morningAlarmTodayUri()}&scope=${settings.activationToken ?: "none"}",
                )
                putExtra(EXTRA_OWNER_HASH, settings.ownerHash)
                putExtra(EXTRA_IS_TEST, isTest)
                putExtra(EXTRA_SCOPE_REGION_ID, settings.regionId)
                putExtra(EXTRA_SCOPE_OWNER_HASH, settings.ownerHash)
                putExtra(EXTRA_SCOPE_GENERATION, settings.generation)
                putExtra(EXTRA_SCOPE_ACTIVATION_TOKEN, settings.activationToken)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        builder
            .setSmallIcon(R.drawable.ic_morning_alarm)
            .setContentTitle(
                if (isTest) {
                    context.getString(R.string.morning_alarm_test_title)
                } else {
                    context.getString(R.string.morning_alarm_title)
                },
            )
            .setContentText(context.getString(R.string.morning_alarm_body))
            .setCategory(Notification.CATEGORY_ALARM)
            .setPriority(Notification.PRIORITY_MAX)
            .setVisibility(
                if (settings.lockScreenPrivacy) {
                    Notification.VISIBILITY_SECRET
                } else {
                    Notification.VISIBILITY_PRIVATE
                },
            )
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(todayIntent)
            .addAction(
                Notification.Action.Builder(
                    R.drawable.ic_morning_alarm,
                    context.getString(R.string.morning_alarm_stop),
                    stopIntent,
                ).build(),
            )
            .addAction(
                Notification.Action.Builder(
                    R.drawable.ic_morning_alarm,
                    context.getString(
                        R.string.morning_alarm_snooze,
                        settings.snoozeMinutes,
                    ),
                    snoozeIntent,
                ).build(),
            )
            .addAction(
                Notification.Action.Builder(
                    R.drawable.ic_morning_alarm,
                    context.getString(R.string.morning_alarm_today),
                    todayIntent,
                ).build(),
            )
        if (MorningAlarmCapabilities.read(context).fullScreenAllowed) {
            builder.setFullScreenIntent(fullScreenIntent, true)
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            if (settings.soundEnabled) {
                builder.setSound(Settings.System.DEFAULT_ALARM_ALERT_URI)
            }
            @Suppress("DEPRECATION")
            if (settings.vibrationEnabled) {
                builder.setVibrate(longArrayOf(0L, 350L, 250L, 350L))
            }
        }
        try {
            notificationManager.notify(MORNING_ALARM_NOTIFICATION_ID, builder.build())
        } catch (_: SecurityException) {
            // Permission can be revoked between the capability check and notify.
            // The next regular occurrence remains scheduled and the UI reports it.
        }
    }

    fun cancel() {
        notificationManager.cancel(MORNING_ALARM_NOTIFICATION_ID)
    }

    private fun ensureChannel(settings: MorningAlarmSettings): String {
        val soundPart = if (settings.soundEnabled) "sound" else "silent"
        val vibrationPart = if (settings.vibrationEnabled) "vibrate" else "still"
        val channelId = "morning_alarm_${soundPart}_$vibrationPart"
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return channelId

        val channel = NotificationChannel(
            channelId,
            context.getString(R.string.morning_alarm_channel_name),
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = context.getString(R.string.morning_alarm_channel_description)
            lockscreenVisibility = if (settings.lockScreenPrivacy) {
                Notification.VISIBILITY_SECRET
            } else {
                Notification.VISIBILITY_PRIVATE
            }
            enableVibration(settings.vibrationEnabled)
            if (settings.vibrationEnabled) {
                vibrationPattern = longArrayOf(0L, 350L, 250L, 350L)
            }
            val alarmSound = if (settings.soundEnabled) {
                Settings.System.DEFAULT_ALARM_ALERT_URI
            } else {
                null
            }
            setSound(
                alarmSound,
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
        }
        notificationManager.createNotificationChannel(channel)
        return channelId
    }

    private fun broadcastActionPendingIntent(
        requestCode: Int,
        action: String,
        settings: MorningAlarmSettings,
        isTest: Boolean,
    ): PendingIntent = PendingIntent.getBroadcast(
        context,
        requestCode,
        Intent(context, MorningAlarmActionReceiver::class.java).apply {
            this.action = action
            data = Uri.parse(
                "${morningAlarmTodayUri()}&scope=${settings.activationToken ?: "none"}",
            )
            putExtra(EXTRA_OWNER_HASH, settings.ownerHash)
            putExtra(EXTRA_IS_TEST, isTest)
            putExtra(EXTRA_SCOPE_REGION_ID, settings.regionId)
            putExtra(EXTRA_SCOPE_OWNER_HASH, settings.ownerHash)
            putExtra(EXTRA_SCOPE_GENERATION, settings.generation)
            putExtra(EXTRA_SCOPE_ACTIVATION_TOKEN, settings.activationToken)
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun activityActionPendingIntent(
        requestCode: Int,
        action: String,
        settings: MorningAlarmSettings,
        isTest: Boolean,
    ): PendingIntent = PendingIntent.getActivity(
        context,
        requestCode,
        Intent(context, MorningAlarmActionActivity::class.java).apply {
            this.action = action
            data = Uri.parse(
                "${morningAlarmTodayUri()}&scope=${settings.activationToken ?: "none"}",
            )
            putExtra(EXTRA_OWNER_HASH, settings.ownerHash)
            putExtra(EXTRA_IS_TEST, isTest)
            putExtra(EXTRA_SCOPE_REGION_ID, settings.regionId)
            putExtra(EXTRA_SCOPE_OWNER_HASH, settings.ownerHash)
            putExtra(EXTRA_SCOPE_GENERATION, settings.generation)
            putExtra(EXTRA_SCOPE_ACTIVATION_TOKEN, settings.activationToken)
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}
