package jp.universityschedule.testing

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import jp.universityschedule.app.BuildConfig
import jp.universityschedule.scope.NativeScopeFence
import java.io.File

/** Debug-only ADB transport for the link copied by the normal UI. Never logs it. */
class Phase8ClipboardReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        setResultCode(Activity.RESULT_CANCELED)
        if (!BuildConfig.DEBUG || BuildConfig.FLAVOR != "staging") return
        val scope = NativeScopeFence.current(context)
        // Only the preserved Phase6 local/non-demo test region is permitted.
        if (!scope.active || scope.regionId != LOCAL_TEST_REGION) return
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        runCatching {
            when (intent.action) {
                EXPORT -> {
                    val clip = clipboard.primaryClip ?: return
                    if (clip.itemCount != 1) return
                    val value = clip.getItemAt(0).text?.toString() ?: return
                    if (!isInvite(value)) return
                    File(context.cacheDir, "phase8-invite-link.txt").writeText(value)
                }
                SET_SYNTHETIC -> {
                    val value = intent.getStringExtra("text") ?: return
                    if (!value.startsWith("Phase8-") || value.length > 256 ||
                        value.any { it.isISOControl() } || value.contains("://")) return
                    clipboard.setPrimaryClip(ClipData.newPlainText("Phase8 synthetic", value))
                }
                else -> return
            }
            setResultCode(Activity.RESULT_OK)
        }
    }

    private fun isInvite(value: String): Boolean {
        val uri = Uri.parse(value)
        return uri.scheme == BuildConfig.DEEP_LINK_SCHEME && uri.host == "invite" &&
            uri.userInfo == null && uri.port == -1 && uri.query == null && uri.fragment == null &&
            uri.pathSegments.size == 2 && uri.pathSegments[0] == "friend" &&
            Regex("[A-Za-z0-9_-]{32,128}").matches(uri.pathSegments[1])
    }

    companion object {
        private const val LOCAL_TEST_REGION = "2f509946d2c4720842dddc0c8373f6e4710be87f343c73b13c0bbb2dd3f4a375"
        const val EXPORT = "jp.universityschedule.app.action.PHASE8_EXPORT_COPIED_INVITE"
        const val SET_SYNTHETIC = "jp.universityschedule.app.action.PHASE8_SYNTHETIC_CLIPBOARD"
    }
}
