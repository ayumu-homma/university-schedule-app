package jp.universityschedule.alarm

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import jp.universityschedule.scope.NativeScopeFence

class MorningAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ACTION_ALARM_FIRE) return
        if (!NativeScopeFence.matchesIntent(context, intent)) return
        runCatching {
            MorningAlarmCoordinator(context).handleFire(
                ownerHash = intent.getStringExtra(EXTRA_OWNER_HASH),
                mode = intent.getStringExtra(EXTRA_ALARM_MODE),
                isTest = intent.getBooleanExtra(EXTRA_IS_TEST, false),
            )
        }
    }
}
