package jp.universityschedule.testing

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Looper
import java.io.File
import jp.universityschedule.app.BuildConfig
import jp.universityschedule.scope.NativeScopeFence
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class Phase8ClipboardReceiverTest {
    private lateinit var context: Context
    private lateinit var output: File

    @Before fun setup() {
        context = RuntimeEnvironment.getApplication()
        context.getSharedPreferences("native_scope_v1", Context.MODE_PRIVATE).edit().clear().commit()
        output = File(context.cacheDir, "phase8-invite-link.txt")
        output.delete()
        NativeScopeFence.prepare(context, region)
        NativeScopeFence.activate(context, region, "a".repeat(64))
    }

    @Test fun copiedInviteIsExportedOnlyIntoPrivateCache() {
        assumeTrue("Clipboard export receiver exists only in staging debug", BuildConfig.FLAVOR == "staging")
        val link = "${BuildConfig.DEEP_LINK_SCHEME}://invite/friend/${"x".repeat(43)}"
        clipboard(link)
        export()
        assertEquals(link, output.readText())
    }

    @Test fun authCallbacksAndForeignLinksAreNeverExported() {
        for (link in listOf(
            "${BuildConfig.DEEP_LINK_SCHEME}://auth-callback/?code=private-code",
            "https://example.test/invite/friend/${"x".repeat(43)}",
            "${BuildConfig.DEEP_LINK_SCHEME}://invite/friend/${"x".repeat(43)}?secret=x",
        )) {
            clipboard(link)
            export()
            assertFalse(output.exists())
        }
    }

    @Test fun inactiveOrDifferentRegionCannotExport() {
        clipboard("${BuildConfig.DEEP_LINK_SCHEME}://invite/friend/${"x".repeat(43)}")
        NativeScopeFence.prepare(context, "b".repeat(64))
        export()
        assertFalse(output.exists())
        NativeScopeFence.activate(context, "b".repeat(64), "a".repeat(64))
        export()
        assertFalse(output.exists())
    }

    private fun clipboard(value: String) {
        context.getSystemService(ClipboardManager::class.java)
            .setPrimaryClip(ClipData.newPlainText("Synthetic", value))
    }
    private fun export() {
        val receiver = Phase8ClipboardReceiver()
        context.registerReceiver(
            receiver, IntentFilter(Phase8ClipboardReceiver.EXPORT),
            Context.RECEIVER_NOT_EXPORTED,
        )
        try {
            context.sendOrderedBroadcast(
                Intent(Phase8ClipboardReceiver.EXPORT).setPackage(context.packageName), null,
            )
            shadowOf(Looper.getMainLooper()).idle()
        } finally {
            context.unregisterReceiver(receiver)
        }
    }
    private val region = "2f509946d2c4720842dddc0c8373f6e4710be87f343c73b13c0bbb2dd3f4a375"
}
