package jp.universityschedule.notification

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.app.Activity
import jp.universityschedule.app.BuildConfig
import jp.universityschedule.scope.NativeScopeFence
import java.security.MessageDigest

/**
 * Staging/debug-only control for the Phase 7.1 device proof. The manifest
 * protects the shell entry point with DUMP; this second gate keeps release,
 * non-staging, inactive-scope, non-exam, and non-Phase71 titles out even when
 * the receiver is invoked by an in-process test.
 */
class Phase71FixtureReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!BuildConfig.DEBUG || BuildConfig.FLAVOR != "staging" ||
            intent.action != NotificationRefillContract.DEBUG_FIXTURE_ACTION
        ) return
        val title = intent.getStringExtra(NotificationRefillContract.DEBUG_FIXTURE_TITLE)
            ?.takeIf { it.startsWith("Phase71-") && it.length <= 256 }
            ?: return
        val scope = NativeScopeFence.current(context)
        val ownerUserId = LocalNotificationCoordinator.refillContextForJob(context)
            ?.get("ownerUserId")
            ?.takeIf { ownerHash(it) == scope.ownerHash }
            ?: return
        if (!scope.active) return
        runCatching {
            LocalNotificationCoordinator.clearPhase71ExamDerived(
                context,
                scope,
                ownerUserId,
                title,
            )
        }.onSuccess { result ->
            val extras = Bundle().apply {
                putString("examId", result["examId"] as String)
                putInt("occurrencesDeleted", result["occurrencesDeleted"] as Int)
                putInt("reservationsDeleted", result["reservationsDeleted"] as Int)
            }
            setResultCode(Activity.RESULT_OK)
            setResultExtras(extras)
            Log.i(
                "Phase71Fixture",
                "derived-only clear exam=${result["examId"]} occurrences=${result["occurrencesDeleted"]} reservations=${result["reservationsDeleted"]}",
            )
        }.onFailure { error ->
            setResultCode(Activity.RESULT_CANCELED)
            Log.w("Phase71Fixture", "derived-only clear rejected: ${error.message}")
        }
    }

    private fun ownerHash(owner: String): String = MessageDigest.getInstance("SHA-256")
        .digest(owner.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
}
