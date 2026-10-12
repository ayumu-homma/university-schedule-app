package jp.universityschedule.notification

import android.app.job.JobScheduler
import android.content.Context
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.shadows.ShadowSystemClock

@RunWith(RobolectricTestRunner::class)
class NotificationRefillSchedulerTest {
    private lateinit var context: Context

    @Before
    fun setUp() {
        ShadowSystemClock.reset()
        context = RuntimeEnvironment.getApplication()
        context.getSystemService(JobScheduler::class.java)?.cancelAll()
        context.getSharedPreferences(NotificationRefillContract.PREFS, Context.MODE_PRIVATE)
            .edit().clear().commit()
    }

    @After
    fun tearDown() {
        context.getSystemService(JobScheduler::class.java)?.cancelAll()
        context.getSharedPreferences(NotificationRefillContract.PREFS, Context.MODE_PRIVATE)
            .edit().clear().commit()
    }

    @Test
    fun futureCoverageCoalescesToTheEarliestDueAndSourceRequestExpeditesIt() {
        val now = System.currentTimeMillis()
        NotificationRefillScheduler.scheduleCoverage(context, now + 180_000L, "late")
        val late = pendingRefill()
        // The scheduler deliberately suppresses due times at or inside the
        // one-minute safety guard. Keep both fixtures outside that guard so
        // this test exercises ordering rather than the guard itself.
        NotificationRefillScheduler.scheduleCoverage(context, now + 90_000L, "early")
        val early = pendingRefill()

        assertTrue(early.extras.getLong(DUE_AT) < late.extras.getLong(DUE_AT))
        val futureToken = late.extras.getString(NotificationRefillContract.EXTRA_RUN_TOKEN)
        NotificationRefillScheduler.requestRefill(context, "source-change")
        val immediate = pendingRefill()
        assertTrue(immediate.extras.getLong(DUE_AT) <= System.currentTimeMillis())
        assertNotEquals(futureToken, immediate.extras.getString(NotificationRefillContract.EXTRA_RUN_TOKEN))
    }

    @Test
    fun futureCoverageWhileRunningKeepsARealFutureDueTime() {
        val token = NotificationRefillScheduler.begin(
            context,
            NotificationRefillContract.REFILL_JOB_ID,
            "scheduled-token",
        )!!
        val due = System.currentTimeMillis() + 2L * 60L * 60L * 1000L
        NotificationRefillScheduler.scheduleCoverage(context, due, "future-projection")
        val state = NotificationRefillScheduler.stateForTest(context)

        assertTrue(state.getBoolean("coalesced"))
        assertTrue(state.getLong("nextRunAtMs") >= due - 1_000L)
        assertTrue(NotificationRefillScheduler.finish(context, token, false, "test failure"))
        val retained = NotificationRefillScheduler.stateForTest(context)
        assertTrue(retained.getBoolean("coalesced"))
        assertTrue(retained.getLong("nextRunAtMs") >= due - 1_000L)
    }

    @Test
    fun sourceFollowupWinsOverLaterCoverageWhileRunIsFinishing() {
        val token = NotificationRefillScheduler.begin(
            context,
            NotificationRefillContract.REFILL_JOB_ID,
            null,
        )!!

        NotificationRefillScheduler.requestRefill(context, "source-change-during-run")
        NotificationRefillScheduler.scheduleCoverage(
            context,
            System.currentTimeMillis() + 2L * 60L * 60L * 1000L,
            "future-projection-during-run",
        )

        val coalesced = NotificationRefillScheduler.stateForTest(context)
        assertTrue(coalesced.getBoolean("coalesced"))
        assertEquals("source", coalesced.getString("coalescedKind"))

        assertFalse(NotificationRefillScheduler.finish(context, token, true))
        NotificationRefillScheduler.releaseAfterFinish(context, token)

        val released = NotificationRefillScheduler.stateForTest(context)
        assertFalse(released.getBoolean("running"))
        assertFalse(released.getBoolean("coalesced"))
        val followup = pendingRefill()
        assertTrue(followup.extras.getLong(DUE_AT) <= System.currentTimeMillis())
    }

    @Test
    fun pastAndNearCoverageOnlyEnsureDailySafetyJob() {
        NotificationRefillScheduler.scheduleCoverage(context, System.currentTimeMillis() - 1L, "past")
        NotificationRefillScheduler.scheduleCoverage(context, System.currentTimeMillis() + 30_000L, "near")

        val ids = context.getSystemService(JobScheduler::class.java)?.allPendingJobs.orEmpty().map { it.id }.toSet()
        assertEquals(setOf(NotificationRefillContract.DAILY_JOB_ID), ids)
    }

    @Test
    fun releaseAfterFinishPersistsUntilJobFinishedThenSchedulesDueCoverage() {
        val token = NotificationRefillScheduler.begin(
            context,
            NotificationRefillContract.REFILL_JOB_ID,
            null,
        )!!
        val due = System.currentTimeMillis() + 2L * 60L * 60L * 1000L
        NotificationRefillScheduler.scheduleCoverage(context, due, "future")
        assertFalse(NotificationRefillScheduler.finish(context, token, true))

        val beforeRelease = NotificationRefillScheduler.stateForTest(context)
        assertTrue(beforeRelease.getBoolean("running"))
        assertTrue(beforeRelease.getBoolean("releasePending"))
        assertTrue(context.getSystemService(JobScheduler::class.java)?.allPendingJobs.orEmpty()
            .none { it.id == NotificationRefillContract.REFILL_JOB_ID })

        NotificationRefillScheduler.releaseAfterFinish(context, token)
        val afterRelease = NotificationRefillScheduler.stateForTest(context)
        assertFalse(afterRelease.getBoolean("running"))
        assertFalse(afterRelease.getBoolean("releasePending"))
        assertTrue(pendingRefill().extras.getLong(DUE_AT) >= due - 1_000L)
    }

    @Test
    fun nextSchedulerEntryConsumesAnUnacknowledgedReleaseMarker() {
        val token = NotificationRefillScheduler.begin(
            context,
            NotificationRefillContract.REFILL_JOB_ID,
            null,
        )!!
        assertFalse(NotificationRefillScheduler.finish(context, token, true))
        val interrupted = NotificationRefillScheduler.stateForTest(context)
            .put("pid", -1)
            .put("startedAtMs", 0L)
        context.getSharedPreferences(NotificationRefillContract.PREFS, Context.MODE_PRIVATE)
            .edit().putString(NotificationRefillContract.JOB_STATE_KEY, interrupted.toString()).commit()

        val recovered = NotificationRefillScheduler.begin(
            context,
            NotificationRefillContract.REFILL_JOB_ID,
            null,
        )
        assertTrue(recovered != null)
        assertFalse(NotificationRefillScheduler.stateForTest(context).getBoolean("releasePending"))
    }

    @Test
    fun terminalFailureStopsRetryAfterMaximumAttempts() {
        var terminalRetry = true
        repeat(NotificationRefillScheduler.MAX_ATTEMPTS) {
            val token = NotificationRefillScheduler.begin(
                context,
                NotificationRefillContract.REFILL_JOB_ID,
                null,
            )!!
            terminalRetry = NotificationRefillScheduler.finish(context, token, false, "planner error")
            NotificationRefillScheduler.releaseAfterFinish(context, token)
        }

        val state = NotificationRefillScheduler.stateForTest(context)
        assertFalse(terminalRetry)
        assertFalse(state.getBoolean("running"))
        assertTrue(state.getString("lastError").startsWith("max_attempts:"))
        assertEquals(0L, state.getLong("nextRunAtMs"))
    }

    @Test
    fun onlyTheTwoFixedIdsAreAcceptedAndEachExecutionGetsANewToken() {
        assertEquals(null, NotificationRefillScheduler.begin(context, 71_003, null))
        val first = NotificationRefillScheduler.begin(
            context,
            NotificationRefillContract.DAILY_JOB_ID,
            null,
        )!!
        NotificationRefillScheduler.invalidate(context, first)
        NotificationRefillScheduler.releaseAfterStop(context, first)
        val second = NotificationRefillScheduler.begin(
            context,
            NotificationRefillContract.DAILY_JOB_ID,
            null,
        )!!
        assertNotEquals(first, second)
    }

    @Test
    fun invalidatedRunRejectsPublicationBeforeReleasingItsFixedSlot() {
        val token = NotificationRefillScheduler.begin(
            context,
            NotificationRefillContract.REFILL_JOB_ID,
            null,
        )!!
        NotificationRefillScheduler.invalidate(context, token)

        assertFalse(NotificationRefillScheduler.ownsActiveRun(context, token))
        NotificationRefillScheduler.requestRefill(context, "during-stop")
        assertTrue(NotificationRefillScheduler.stateForTest(context).getBoolean("running"))

        NotificationRefillScheduler.releaseAfterStop(context, token)
        assertFalse(NotificationRefillScheduler.stateForTest(context).getBoolean("running"))
    }

    @Test
    fun commitGateRunsForegroundAndRejectsLateBackgroundWork() {
        assertEquals("foreground", NotificationRefillScheduler.withActiveRun(context, null) { "foreground" })
        val token = NotificationRefillScheduler.begin(
            context,
            NotificationRefillContract.REFILL_JOB_ID,
            null,
        )!!
        assertEquals("background", NotificationRefillScheduler.withActiveRun(context, token) { "background" })

        NotificationRefillScheduler.invalidate(context, token)
        assertEquals(null, NotificationRefillScheduler.withActiveRun(context, token) { "late" })
        NotificationRefillScheduler.releaseAfterStop(context, token)
    }

    private fun pendingRefill() = context.getSystemService(JobScheduler::class.java)
        ?.allPendingJobs.orEmpty()
        .first { it.id == NotificationRefillContract.REFILL_JOB_ID }

    private companion object {
        const val DUE_AT = "notification_refill_due_at_ms"
    }
}
