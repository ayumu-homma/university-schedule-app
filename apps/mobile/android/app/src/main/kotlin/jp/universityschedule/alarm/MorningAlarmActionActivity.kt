package jp.universityschedule.alarm

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import jp.universityschedule.app.MainActivity
import jp.universityschedule.scope.NativeScopeFence

class MorningAlarmActionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val capturedIntent = Intent(intent)
        val ownerHash = capturedIntent.getStringExtra(EXTRA_OWNER_HASH)
        val isTest = intent?.getBooleanExtra(EXTRA_IS_TEST, false) ?: false
        val coordinator = MorningAlarmCoordinator(this)
        if (!NativeScopeFence.matchesIntent(this, capturedIntent) ||
            !coordinator.isActiveOwnerHash(ownerHash)) {
            finish()
            return
        }
        val shouldOpenToday = when (intent?.action) {
            ACTION_ALARM_OPEN_TODAY -> true
            ACTION_ALARM_STOP_AND_OPEN -> true
            else -> false
        }
        runCatching {
            coordinator.handleStop(ownerHash, isTest)
            if (shouldOpenToday &&
                NativeScopeFence.matchesIntent(this, capturedIntent) &&
                coordinator.isActiveOwnerHash(ownerHash)
            ) {
                openToday()
            }
        }
        finish()
    }

    private fun openToday() {
        val scope = NativeScopeFence.current(this)
        if (!scope.active) return
        startActivity(
            Intent(
                Intent.ACTION_VIEW,
                Uri.parse("${morningAlarmTodayUri()}&scope=${scope.activationToken}"),
                this,
                MainActivity::class.java,
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra(EXTRA_SCOPE_REGION_ID, scope.regionId)
                putExtra(EXTRA_SCOPE_OWNER_HASH, scope.ownerHash)
                putExtra(EXTRA_SCOPE_GENERATION, scope.generation)
                putExtra(EXTRA_SCOPE_ACTIVATION_TOKEN, scope.activationToken)
            },
        )
    }
}
