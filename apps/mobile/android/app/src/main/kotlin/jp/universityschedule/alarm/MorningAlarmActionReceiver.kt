package jp.universityschedule.alarm

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import jp.universityschedule.scope.NativeScopeFence

class MorningAlarmActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val coordinator = MorningAlarmCoordinator(context)
        val ownerHash = intent?.getStringExtra(EXTRA_OWNER_HASH)
        val isTest = intent?.getBooleanExtra(EXTRA_IS_TEST, false) ?: false
        if (!NativeScopeFence.matchesIntent(context, intent)) return
        runCatching {
            when (intent?.action) {
                ACTION_ALARM_STOP -> coordinator.handleStop(ownerHash, isTest)
                ACTION_ALARM_SNOOZE -> coordinator.handleSnooze(ownerHash, isTest)
            }
        }
    }
}
