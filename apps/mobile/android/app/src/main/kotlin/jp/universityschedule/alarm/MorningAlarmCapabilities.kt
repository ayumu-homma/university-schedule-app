package jp.universityschedule.alarm

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.os.Build

internal data class MorningAlarmCapabilities(
    val notificationPermission: String,
    val schedulePrecision: String,
    val fullScreenAllowed: Boolean,
    val debugTestAllowed: Boolean,
) {
    fun toPlatformMap(): Map<String, Any> =
        mapOf(
            "notificationPermission" to notificationPermission,
            "schedulePrecision" to schedulePrecision,
            "fullScreenAllowed" to fullScreenAllowed,
            "debugTestAllowed" to debugTestAllowed,
        )

    companion object {
        fun read(context: Context): MorningAlarmCapabilities {
            val notificationPermission = if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                "notRequired"
            } else if (
                context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
            ) {
                "granted"
            } else {
                "denied"
            }
            val alarmManager = context.getSystemService(AlarmManager::class.java)
            val exactAllowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                alarmManager.canScheduleExactAlarms()
            val notificationManager = context.getSystemService(NotificationManager::class.java)
            val fullScreenAllowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
                notificationManager.canUseFullScreenIntent()
            val debugAllowed =
                (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
            return MorningAlarmCapabilities(
                notificationPermission = notificationPermission,
                schedulePrecision = if (exactAllowed) "exact" else "inexact",
                fullScreenAllowed = fullScreenAllowed,
                debugTestAllowed = debugAllowed,
            )
        }
    }
}
