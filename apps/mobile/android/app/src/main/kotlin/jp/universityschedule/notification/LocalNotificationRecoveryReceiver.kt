package jp.universityschedule.notification

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Repairs persisted ordinary plans after the OS drops/revokes alarms or a
 * wall-clock/package/boot transition occurs. */
class LocalNotificationRecoveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == LOCAL_NOTIFICATION_RECOVER_ACTION ||
            intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_DATE_CHANGED ||
            intent.action == Intent.ACTION_TIME_CHANGED ||
            intent.action == Intent.ACTION_TIMEZONE_CHANGED ||
            intent.action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            intent.action == "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED" ||
            intent.action == Intent.ACTION_PACKAGE_REPLACED
        ) {
            NotificationRefillScheduler.ensureDaily(context)
            NotificationRefillScheduler.requestRefill(context, "os-recovery:${intent.action}")
            LocalNotificationCoordinator.recover(context)
        }
    }
}
