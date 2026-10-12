package jp.universityschedule.scope

import android.content.Context
import android.content.Intent
import android.app.NotificationManager
import android.app.Notification
import android.app.job.JobScheduler
import jp.universityschedule.notification.LocalNotificationCoordinator
import jp.universityschedule.notification.LOCAL_NOTIFICATION_SUMMARY_ID
import jp.universityschedule.notification.NotificationRefillContract
import jp.universityschedule.notification.NotificationRefillScheduler
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.Shadows.shadowOf

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class NativeScopeFenceTest {
    private val context: Context = RuntimeEnvironment.getApplication()

    @After
    fun tearDown() {
        context.getSharedPreferences("native_scope_v1", Context.MODE_PRIVATE)
            .edit().clear().commit()
        context.getSharedPreferences("weekly_timetable_widget", Context.MODE_PRIVATE)
            .edit().clear().commit()
        context.getSystemService(NotificationManager::class.java).cancelAll()
    }

    @Test
    fun ownerRegionActivationAndReturnGetFreshTokensAndClearDerivedState() {
        val regionId = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        val ownerA = "a".repeat(64)
        val ownerB = "b".repeat(64)

        NativeScopeFence.prepare(context, regionId)
        val firstA = NativeScopeFence.activate(context, regionId, ownerA)
        val oldIntent = scopedIntent(firstA)
        context.getSharedPreferences("weekly_timetable_widget", Context.MODE_PRIVATE)
            .edit().putString("snapshot", "old-owner-a").commit()
        val notifications = context.getSystemService(NotificationManager::class.java)
        notifications.notify(
            LocalNotificationCoordinator.summaryTag(firstA),
            LOCAL_NOTIFICATION_SUMMARY_ID,
            Notification(),
        )
        assertEquals(1, shadowOf(notifications).allNotifications.size)

        val b = NativeScopeFence.activate(context, regionId, ownerB)
        assertNotEquals(firstA.activationToken, b.activationToken)
        assertFalse(NativeScopeFence.matchesIntent(context, oldIntent))
        assertNull(
            context.getSharedPreferences("weekly_timetable_widget", Context.MODE_PRIVATE)
                .getString("snapshot", null),
        )
        assertTrue(shadowOf(notifications).allNotifications.isEmpty())

        val secondA = NativeScopeFence.activate(context, regionId, ownerA)
        assertNotEquals(firstA.activationToken, secondA.activationToken)
        assertNotEquals(firstA.generation, secondA.generation)
        assertTrue(NativeScopeFence.matchesIntent(context, scopedIntent(secondA)))
        assertFalse(NativeScopeFence.matchesIntent(context, oldIntent))
    }

    @Test
    fun transitionComparesPreviousScopeAndReturnsFreshPostScope() {
        val prepared = NativeScopeFence.prepare(context, "a".repeat(64))
        val firstA = NativeScopeFence.transitionOwner(context, prepared, "b".repeat(64))
        assertEquals(firstA, NativeScopeFence.current(context))
        assertTrue(firstA.active)
        assertThrows(IllegalStateException::class.java) {
            NativeScopeFence.transitionOwner(context, prepared, "c".repeat(64))
        }
        assertEquals(firstA, NativeScopeFence.current(context))
        val b = NativeScopeFence.transitionOwner(context, firstA, "c".repeat(64))
        val finalA = NativeScopeFence.transitionOwner(context, b, "b".repeat(64))
        assertNotEquals(firstA.activationToken, finalA.activationToken)
        assertThrows(IllegalStateException::class.java) {
            NativeScopeFence.transitionOwner(context, firstA, null)
        }
        assertEquals(finalA, NativeScopeFence.current(context))
        val signedOut = NativeScopeFence.transitionOwner(context, finalA, null)
        assertFalse(signedOut.active)
        assertNull(signedOut.activationToken)
        assertEquals(signedOut, NativeScopeFence.current(context))
    }

    @Test
    fun changedBuildStampFailsClosedAndClearsPublishedWidget() {
        val preferences = context.getSharedPreferences(
            "native_scope_v1",
            Context.MODE_PRIVATE,
        )
        context.getSharedPreferences("weekly_timetable_widget", Context.MODE_PRIVATE)
            .edit().putString("snapshot", "old-build").commit()
        preferences.edit()
            .putString("build_stamp", "old-build-stamp")
            .putString("region_id", "a".repeat(64))
            .putString("owner_hash", "b".repeat(64))
            .putString("activation_token", "old-token")
            .putLong("generation", 4L)
            .putBoolean("active", true)
            .commit()

        val current = NativeScopeFence.current(context)

        assertFalse(current.active)
        assertNull(
            context.getSharedPreferences("weekly_timetable_widget", Context.MODE_PRIVATE)
                .getString("snapshot", null),
        )
    }

    @Test
    fun activationKeepsDailySafetyJobButWaitsForForegroundRefillContext() {
        val regionId = "c".repeat(64)
        val ownerHash = "d".repeat(64)
        val jobs = context.getSystemService(JobScheduler::class.java)
        jobs.cancelAll()
        context.getSharedPreferences("native_scope_v1", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences(NotificationRefillContract.PREFS, Context.MODE_PRIVATE).edit().clear().commit()

        NativeScopeFence.prepare(context, regionId)
        NativeScopeFence.activate(context, regionId, ownerHash)

        val afterActivation = jobs.allPendingJobs.map { it.id }.toSet()
        assertTrue(afterActivation.contains(NotificationRefillContract.DAILY_JOB_ID))
        assertFalse(afterActivation.contains(NotificationRefillContract.REFILL_JOB_ID))

        NotificationRefillScheduler.requestRefill(context, "foreground-publication")
        assertTrue(jobs.allPendingJobs.any { it.id == NotificationRefillContract.REFILL_JOB_ID })
    }

    private fun scopedIntent(scope: NativeScope): Intent = Intent().apply {
        putExtra("scope_region_id", scope.regionId)
        putExtra("scope_owner_hash", scope.ownerHash)
        putExtra("scope_generation", scope.generation)
        putExtra("scope_activation_token", scope.activationToken)
    }
}
