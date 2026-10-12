package jp.universityschedule.notification

import android.content.Context
import jp.universityschedule.scope.NativeScopeFence
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.runner.RunWith
import org.junit.Test
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LocalNotificationCoordinatorTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val region = "c".repeat(64)
    private val owner = "owner-a"

    @After
    fun tearDown() {
        context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("native_scope_v1", Context.MODE_PRIVATE).edit().clear().commit()
    }

    @Test
    fun arbitrarySuppliedPathIsNeverUsedForScopedDatabase() {
        val scope = activate()
        val error = org.junit.Assert.assertThrows(IllegalStateException::class.java) {
            LocalNotificationCoordinator.openScopedDatabase(context, region)
        }
        assertTrue(error.message.orEmpty().contains("scoped database"))
    }

    private fun activate() = NativeScopeFence.run {
        prepare(context, region)
        activateOwner(context, region, owner)
    }

}
