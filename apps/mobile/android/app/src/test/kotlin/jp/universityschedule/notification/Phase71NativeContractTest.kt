package jp.universityschedule.notification

import android.Manifest
import android.app.AlarmManager
import android.app.job.JobScheduler
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteException
import jp.universityschedule.scope.NativeScope
import jp.universityschedule.scope.NativeScopeFence
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.shadows.ShadowAlarmManager
import org.robolectric.shadows.ShadowSystemClock
import org.robolectric.Shadows.shadowOf
import java.io.File
import java.nio.file.Files
import java.util.concurrent.Executor

@RunWith(RobolectricTestRunner::class)
class Phase71NativeContractTest {
    private val testReceiver = LocalNotificationReceiver(Executor { it.run() })
    private val context: Context = RuntimeEnvironment.getApplication()
    private val region = "d".repeat(64)
    private val owner = "phase71-owner"
    private lateinit var scope: NativeScope
    private lateinit var databaseFile: File
    private lateinit var databaseDirectory: File
    private val opened = mutableListOf<SQLiteDatabase>()
    private var testWallNowMs: Long = 0L

    @Before
    fun setUp() {
        ShadowSystemClock.reset()
        testWallNowMs = System.currentTimeMillis()
        NotificationTime.nowForTests = { testWallNowMs }
        shadowOf(context as android.app.Application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        context.getSystemService(android.app.NotificationManager::class.java).createNotificationChannel(
            android.app.NotificationChannel(
                LOCAL_NOTIFICATION_CHANNEL,
                "Phase 7.1 test notifications",
                android.app.NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )
        ShadowAlarmManager.setCanScheduleExactAlarms(true)
        NativeScopeFence.prepare(context, region)
        scope = NativeScopeFence.activateOwner(context, region, owner)
        databaseDirectory = Files.createTempDirectory("phase71-").toFile()
        databaseFile = File(databaseDirectory, "app.sqlite").also { check(it.createNewFile()) }
        open().also(::createSchema).close()
        LocalNotificationCoordinator.scopedDatabaseProviderForTests = { _, _ -> open().asCanonicalFixture() }
    }

    @After
    fun tearDown() {
        NotificationTime.nowForTests = null
        LocalNotificationCoordinator.scopedDatabaseProviderForTests = null
        opened.toList().asReversed().forEach { if (it.isOpen) it.close() }
        context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("ordinary_notification_receipts_v1", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("native_scope_v1", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSystemService(JobScheduler::class.java)?.cancelAll()
        databaseFile.delete()
        databaseDirectory.delete()
    }

    @Test
    fun twoHundredOneSameTimeMembersUseOneWakeupAndRemainInRegistry() {
        val trigger = System.currentTimeMillis() + 30_000L
        val occurrence = trigger + 60_000L
        val plans = JSONArray()
        repeat(201) { index ->
            val id = "same-time-$index"
            insertRow(id, trigger, occurrence, "fp-$index")
            plans.put(plan(id, trigger, occurrence, "fp-$index", "logical-$index"))
        }

        val result = LocalNotificationCoordinator.reconcile(context, "ignored", scope, plans)

        assertEquals(1, result.scheduledCount)
        val registry = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        assertEquals(201, registry.length())
        var scheduled = 0
        registry.keys().forEach { if (registry.getJSONObject(it).getString("state") == "scheduled") scheduled++ }
        assertEquals(201, scheduled)
        assertEquals(1, shadowOf(context.getSystemService(AlarmManager::class.java)).scheduledAlarms.size)
    }

    @Test
    fun twoHundredOneDistinctBucketsPromoteTheDeferredBucketAfterAReservationFrees() {
        val firstTrigger = System.currentTimeMillis() + 30_000L
        val plans = JSONArray()
        repeat(201) { index ->
            val trigger = firstTrigger + index * 60_000L
            val occurrence = trigger + 60_000L
            val id = "distinct-$index"
            insertRow(id, trigger, occurrence, "distinct-fp-$index")
            plans.put(plan(id, trigger, occurrence, "distinct-fp-$index", id))
        }

        val initial = LocalNotificationCoordinator.reconcile(context, "ignored", scope, plans)
        assertEquals(200, initial.scheduledCount)
        val before = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        assertEquals("deferred", before.getJSONObject(before.keys().asSequence().first { it.contains("distinct-200") }).getString("state"))

        deleteOccurrence("distinct-0")
        val promoted = LocalNotificationCoordinator.reconcile(context, "ignored", scope, JSONArray())
        assertEquals(200, promoted.scheduledCount)
        val after = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        assertTrue(after.keys().asSequence().any { it.contains("distinct-200") && after.getJSONObject(it).getString("state") == "scheduled" })
    }

    @Test
    fun permanentReceiptSuppressesReplannedTitleAndSurvivesClockRollback() {
        val baseline = testWallNowMs
        assertTrue(LocalNotificationCoordinator.recordReceiptForTest(context, scope, "receipt-plan"))
        assertTrue(LocalNotificationCoordinator.receiptRecordedForTest(context, scope, "receipt-plan"))
        val trigger = System.currentTimeMillis() + 30_000L
        val occurrence = trigger + 60_000L
        val plan = plan("receipt-plan", trigger, occurrence, "receipt-fp", "receipt-plan")
        insertRow("receipt-plan", trigger, occurrence, "receipt-fp")

        val result = LocalNotificationCoordinator.reconcile(context, "ignored", scope, JSONArray().put(plan))

        assertEquals(0, result.scheduledCount)
        val entry = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans").getJSONObject(
            LocalNotificationCoordinator.identityForTest(scope, "receipt-plan", "assignment", "assignment-1", occurrence, "absolute"),
        )
        assertTrue(entry.getBoolean("suppressedByReceipt"))
        testWallNowMs = baseline + 120_000L
        LocalNotificationCoordinator.clearForScope(context, scope.activationToken)
        testWallNowMs = baseline - 120_000L
        val rollbackTrigger = System.currentTimeMillis() + 30_000L
        val rollbackOccurrence = rollbackTrigger + 60_000L
        insertRow("receipt-plan", rollbackTrigger, rollbackOccurrence, "receipt-fp-new")
        val rollback = LocalNotificationCoordinator.reconcile(
            context,
            "ignored",
            scope,
            JSONArray().put(plan("receipt-plan", rollbackTrigger, rollbackOccurrence, "receipt-fp-new", "receipt-plan")),
        )
        assertEquals(0, rollback.scheduledCount)
    }

    @Test
    fun inboxReferencesSurviveSameScopeRegistryRebuild() {
        val trigger = System.currentTimeMillis() + 30_000L
        val occurrence = trigger + 60_000L
        val plan = plan("inbox-plan", trigger, occurrence, "inbox-fp", "inbox-logical")
        insertRow("inbox-plan", trigger, occurrence, "inbox-fp")
        val plans = JSONArray().put(plan)
        LocalNotificationCoordinator.reconcile(context, "ignored", scope, plans)
        val root = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        )
        val identity = root.getJSONObject("plans").keys().next()
        val entry = root.getJSONObject("plans").getJSONObject(identity)
        val intent = LocalNotificationCoordinator.receiverIntentForTest(context, scope, entry)
        LocalNotificationCoordinator.recordInboxReferences(context, listOf(intent), representedInSummary = true)

        LocalNotificationCoordinator.reconcile(context, "ignored", scope, plans)

        val rebuilt = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        )
        assertEquals(1, rebuilt.getJSONArray("inbox").length())
    }

    @Test
    fun twoHundredOneDueMembersDeliverAsSummaryAndInboxSurvivesRecovery() {
        val trigger = System.currentTimeMillis() + 90_000L
        val occurrence = trigger + 120_000L
        val plans = JSONArray()
        repeat(201) { index ->
            val id = "summary-$index"
            insertRow(id, trigger, occurrence, "summary-fp-$index")
            plans.put(plan(id, trigger, occurrence, "summary-fp-$index", id))
        }
        LocalNotificationCoordinator.reconcile(context, "ignored", scope, plans)
        markRowsDueNow((0 until 201).map { "summary-$it" })
        val root = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        )
        val entry = root.getJSONObject("plans").getJSONObject(root.getJSONObject("plans").keys().next())
        testReceiver.onReceive(
            context,
            LocalNotificationCoordinator.receiverIntentForTest(context, scope, entry),
        )

        assertEquals(201, LocalNotificationCoordinator.readInbox(context).size)
        val represented = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        assertEquals(201, represented.length())
        represented.keys().forEach { identity ->
            assertEquals("represented_in_summary", represented.getJSONObject(identity).getString("state"))
        }
        LocalNotificationCoordinator.recover(context, forceReinstall = true)
        assertEquals(201, LocalNotificationCoordinator.readInbox(context).size)
    }

    @Test
    fun recoverRebuildsAnEmptyRegistryFromCommittedProjectionRows() {
        val trigger = System.currentTimeMillis() + 30_000L
        val occurrence = trigger + 90_000L
        insertRow("recovery-plan", trigger, occurrence, "recovery-fp")
        val plan = plan("recovery-plan", trigger, occurrence, "recovery-fp", "recovery-plan")
        LocalNotificationCoordinator.reconcile(context, "ignored", scope, JSONArray().put(plan))
        context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
            .edit().remove("registry").commit()
        context.getSystemService(AlarmManager::class.java)?.let { manager ->
            shadowOf(manager).scheduledAlarms.toList().forEach { it.operation?.let(manager::cancel) }
        }

        LocalNotificationCoordinator.recover(context, forceReinstall = true)

        assertNotNull(shadowOf(context.getSystemService(AlarmManager::class.java)).peekNextScheduledAlarm())
        val rebuilt = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        assertEquals(1, rebuilt.length())
    }

    @Test
    fun threeSameTimeMembersDeliverIndividuallyWithoutPrematureRecovery() {
        val trigger = System.currentTimeMillis() + 90_000L
        val occurrence = trigger + 120_000L
        val plans = JSONArray()
        repeat(3) { index ->
            val id = "individual-$index"
            val fingerprint = "individual-fp-$index"
            insertRow(id, trigger, occurrence, fingerprint)
            plans.put(plan(id, trigger, occurrence, fingerprint, id))
        }
        assertEquals(1, LocalNotificationCoordinator.reconcile(context, "ignored", scope, plans).scheduledCount)
        markRowsDueNow((0 until 3).map { "individual-$it" })
        val root = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        val first = root.getJSONObject(root.keys().next())
        testReceiver.onReceive(context, LocalNotificationCoordinator.receiverIntentForTest(context, scope, first))
        assertEquals(3, shadowOf(context.getSystemService(android.app.NotificationManager::class.java)).allNotifications.size)
        root.keys().forEach { identity ->
            assertEquals("delivered", JSONObject(
                context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                    .getString("registry", "{}")!!,
            ).getJSONObject("plans").getJSONObject(identity).getString("state"))
        }
    }

    @Test
    fun transientSummaryDatabaseOpenFailurePersistsRetryThenDeliversFreshBatch() {
        val trigger = System.currentTimeMillis() + 90_000L
        val occurrence = trigger + 120_000L
        val plans = JSONArray()
        repeat(7) { index ->
            val id = "transient-summary-$index"
            insertRow(id, trigger, occurrence, "transient-fp-$index")
            plans.put(plan(id, trigger, occurrence, "transient-fp-$index", id))
        }
        LocalNotificationCoordinator.reconcile(context, "ignored", scope, plans)
        markRowsDueNow((0 until 7).map { "transient-summary-$it" })
        val root = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        )
        val representative = root.getJSONObject("plans").getJSONObject(root.getJSONObject("plans").keys().next())
        val representativeIntent = LocalNotificationCoordinator.receiverIntentForTest(context, scope, representative)
        val members = LocalNotificationCoordinator.bucketMemberIntents(context, representativeIntent)
        var failOpen = true
        LocalNotificationCoordinator.scopedDatabaseProviderForTests = { _, _ ->
            if (failOpen) throw SQLiteException("transient test open failure") else open().asCanonicalFixture()
        }
        testReceiver.onReceive(context, representativeIntent)
        assertTrue(shadowOf(context.getSystemService(android.app.NotificationManager::class.java)).allNotifications.isEmpty())
        val pending = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        assertTrue(members.all { pending.getJSONObject(it.getStringExtra(EXTRA_IDENTITY)!!).getInt("retries") >= 1 })

        failOpen = false
        testWallNowMs += 30_000L
        assertTrue(
            LocalNotificationCoordinator.retryProjectionBatch(
                context,
                members.map { it to it.getLongExtra(EXTRA_OCCURRENCE_AT, Long.MIN_VALUE) },
                reallocate = true,
            ),
        )
        // Reallocation moves the bounded retry to its new bucket. Re-read the
        // durable registry instead of replaying the stale pre-retry alarm.
        val retryRoot = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        )
        val retryRepresentative = retryRoot.getJSONObject("plans")
            .getJSONObject(retryRoot.getJSONObject("plans").keys().next())
        val retryIntent = LocalNotificationCoordinator.receiverIntentForTest(context, scope, retryRepresentative)
        assertEquals(7, LocalNotificationCoordinator.bucketMemberIntents(context, retryIntent).size)
        testReceiver.onReceive(context, retryIntent)
        assertEquals(1, shadowOf(context.getSystemService(android.app.NotificationManager::class.java)).allNotifications.size)
        assertEquals(7, LocalNotificationCoordinator.readInbox(context).size)
    }

    @Test
    fun sameTimePostingFailureKeepsOtherDueMemberOnOriginalBucket() {
        val trigger = System.currentTimeMillis() + 90_000L
        val occurrence = trigger + 120_000L
        val plans = JSONArray()
        repeat(2) { index ->
            val id = "partial-posting-$index"
            val fingerprint = "partial-posting-fp-$index"
            insertRow(id, trigger, occurrence, fingerprint)
            plans.put(plan(id, trigger, occurrence, fingerprint, id))
        }
        LocalNotificationCoordinator.reconcile(context, "ignored", scope, plans)
        markRowsDueNow(listOf("partial-posting-0", "partial-posting-1"))

        val initialRoot = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        )
        val initialPlans = initialRoot.getJSONObject("plans")
        val representative = initialPlans.getJSONObject(initialPlans.keys().next())
        val originalIntent = LocalNotificationCoordinator.receiverIntentForTest(context, scope, representative)
        val members = LocalNotificationCoordinator.bucketMemberIntents(context, originalIntent)
        assertEquals(2, members.size)

        val failed = members.first()
        val failedIdentity = failed.getStringExtra(EXTRA_IDENTITY)!!
        val failedFingerprint = failed.getStringExtra(EXTRA_FINGERPRINT)!!
        assertTrue(LocalNotificationCoordinator.markPosting(context, failedIdentity, failedFingerprint))
        assertTrue(
            LocalNotificationCoordinator.retryPosting(
                context,
                failed,
                failed.getLongExtra(EXTRA_OCCURRENCE_AT, Long.MIN_VALUE),
                reallocate = true,
            ),
        )

        val afterRetry = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        val failedEntry = afterRetry.getJSONObject(failedIdentity)
        assertTrue(failedEntry.getInt("retries") >= 1)
        assertFalse(failedEntry.getBoolean("delivered"))
        assertEquals(1, LocalNotificationCoordinator.bucketMemberIntents(context, originalIntent).size)

        testReceiver.onReceive(context, originalIntent)
        assertEquals(1, shadowOf(context.getSystemService(android.app.NotificationManager::class.java)).allNotifications.size)
        val delivered = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        assertTrue(delivered.keys().asSequence().any {
            val entry = delivered.getJSONObject(it)
            entry.getString("planId") != failed.getStringExtra(EXTRA_PLAN_ID) && entry.getBoolean("delivered")
        })
        assertFalse(delivered.getJSONObject(failedIdentity).getBoolean("delivered"))
        assertTrue(delivered.getJSONObject(failedIdentity).getInt("retries") >= 1)
    }

    @Test
    fun staleSourceEpochRetriesWholeSummaryThenFreshPastProjectionDeliversAllMembers() {
        val trigger = System.currentTimeMillis() + 90_000L
        val occurrence = trigger + 3L * 60L * 60L * 1000L
        val ids = (0 until 7).map { "stale-summary-$it" }
        val plans = JSONArray()
        ids.forEachIndexed { index, id ->
            val fingerprint = "stale-summary-fp-$index"
            insertRow(id, trigger, occurrence, fingerprint)
            plans.put(plan(id, trigger, occurrence, fingerprint, id))
        }
        LocalNotificationCoordinator.reconcile(context, "ignored", scope, plans)
        markRowsDueNow(ids)

        // The source changes after scheduling but before the OS wakeup. The
        // old registry remains intact while every member gets one bounded
        // projection retry and no notification is posted.
        open().use { db ->
            db.execSQL("UPDATE local_notification_source_revisions SET epoch=2 WHERE id=1")
        }
        val staleRoot = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        )
        val stalePlans = staleRoot.getJSONObject("plans")
        val staleRepresentative = stalePlans.getJSONObject(stalePlans.keys().next())
        val staleIntent = LocalNotificationCoordinator.receiverIntentForTest(context, scope, staleRepresentative)
        val staleMembers = LocalNotificationCoordinator.bucketMemberIntents(context, staleIntent)
        assertEquals(7, staleMembers.size)
        testReceiver.onReceive(context, staleIntent)
        assertTrue(shadowOf(context.getSystemService(android.app.NotificationManager::class.java)).allNotifications.isEmpty())

        val retried = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        assertTrue(ids.all { id ->
            retried.keys().asSequence().map { retried.getJSONObject(it) }
                .any { it.getString("planId") == id && it.getInt("retries") >= 1 && !it.getBoolean("delivered") }
        })

        // Reconcile the same plan IDs/fingerprints from a fresh source and
        // projection epoch. The planner has crossed the trigger to `past`,
        // but the persisted retry and scheduled wakeup keep this delivery
        // eligible until the occurrence cutoff.
        updateProjectionEpoch(epoch = 2L, reason = "past")
        LocalNotificationCoordinator.reconcile(context, "ignored", scope, JSONArray())
        val freshRoot = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        )
        val freshPlans = freshRoot.getJSONObject("plans")
        val freshRepresentative = freshPlans.getJSONObject(freshPlans.keys().next())
        val retryAt = freshRepresentative.getLong("nextAttemptAtMs")
        testWallNowMs = retryAt + 1L
        val freshIntent = LocalNotificationCoordinator.receiverIntentForTest(context, scope, freshRepresentative)
        assertEquals(7, LocalNotificationCoordinator.bucketMemberIntents(context, freshIntent).size)
        testReceiver.onReceive(context, freshIntent)

        assertEquals(1, shadowOf(context.getSystemService(android.app.NotificationManager::class.java)).allNotifications.size)
        assertEquals(7, LocalNotificationCoordinator.readInbox(context).size)
        val delivered = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        assertTrue(ids.all { id ->
            delivered.keys().asSequence().map { delivered.getJSONObject(it) }
                .any { it.getString("planId") == id && it.getString("state") == "represented_in_summary" }
        })
    }

    @Test
    fun retryWakeupsShareTheTwoHundredBucketBudgetAndPromoteDeferredCoverage() {
        val firstTrigger = System.currentTimeMillis() + 90_000L
        val occurrence = firstTrigger + 3L * 60L * 60L * 1000L
        val plans = JSONArray()
        repeat(201) { index ->
            val trigger = firstTrigger + index * 60_000L
            val id = "retry-budget-$index"
            val fingerprint = "retry-budget-fp-$index"
            insertRow(id, trigger, occurrence + index * 60_000L, fingerprint)
            plans.put(plan(id, trigger, occurrence + index * 60_000L, fingerprint, id))
        }
        assertEquals(200, LocalNotificationCoordinator.reconcile(context, "ignored", scope, plans).scheduledCount)
        markRowsDueNow(listOf("retry-budget-0"))

        val initialRoot = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        val firstIdentity = initialRoot.keys().asSequence()
            .first { initialRoot.getJSONObject(it).getString("planId") == "retry-budget-0" }
        val firstEntry = initialRoot.getJSONObject(firstIdentity)
        val firstIntent = LocalNotificationCoordinator.receiverIntentForTest(context, scope, firstEntry)
        assertTrue(LocalNotificationCoordinator.markPosting(context, firstIdentity, firstEntry.getString("fingerprint")))
        assertTrue(
            LocalNotificationCoordinator.retryPosting(
                context,
                firstIntent,
                firstEntry.getLong("occurrenceAtMs"),
                reallocate = true,
            ),
        )
        assertTrue(shadowOf(context.getSystemService(AlarmManager::class.java)).scheduledAlarms.size <= 200)

        val retryRoot = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        val retryEntry = retryRoot.getJSONObject(firstIdentity)
        testWallNowMs = retryEntry.getLong("nextAttemptAtMs") + 1L
        val retryIntent = LocalNotificationCoordinator.receiverIntentForTest(context, scope, retryEntry)
        testReceiver.onReceive(context, retryIntent)

        assertTrue(shadowOf(context.getSystemService(AlarmManager::class.java)).scheduledAlarms.size <= 200)
        val afterSuccess = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        assertTrue(afterSuccess.keys().asSequence().any {
            val entry = afterSuccess.getJSONObject(it)
            entry.getString("planId") == "retry-budget-200" && entry.getString("state") == "scheduled"
        })
    }

    @Test
    fun permissionAndExactAlarmRecoveryRestoresFutureReservations() {
        val trigger = System.currentTimeMillis() + 90_000L
        val occurrence = trigger + 120_000L
        val id = "capability-recovery"
        val fingerprint = "capability-recovery-fp"
        insertRow(id, trigger, occurrence, fingerprint)
        val plans = JSONArray().put(plan(id, trigger, occurrence, fingerprint, id))
        val application = shadowOf(context as android.app.Application)

        application.denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val blockedByNotifications = LocalNotificationCoordinator.reconcile(context, "ignored", scope, plans)
        assertEquals(0, blockedByNotifications.scheduledCount)
        assertEquals("notification_permission", blockedByNotifications.blockedReason)
        assertTrue(shadowOf(context.getSystemService(AlarmManager::class.java)).scheduledAlarms.isEmpty())

        application.grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val restoredNotifications = LocalNotificationCoordinator.reconcile(context, "ignored", scope, plans)
        assertEquals(1, restoredNotifications.scheduledCount)
        assertEquals(null, restoredNotifications.blockedReason)
        assertEquals(1, shadowOf(context.getSystemService(AlarmManager::class.java)).scheduledAlarms.size)

        ShadowAlarmManager.setCanScheduleExactAlarms(false)
        val blockedByExactAlarm = LocalNotificationCoordinator.reconcile(context, "ignored", scope, plans)
        assertEquals(0, blockedByExactAlarm.scheduledCount)
        assertEquals("exact_alarm_permission", blockedByExactAlarm.blockedReason)
        assertTrue(shadowOf(context.getSystemService(AlarmManager::class.java)).scheduledAlarms.isEmpty())

        ShadowAlarmManager.setCanScheduleExactAlarms(true)
        val restoredExactAlarm = LocalNotificationCoordinator.reconcile(context, "ignored", scope, plans)
        assertEquals(1, restoredExactAlarm.scheduledCount)
        assertEquals(null, restoredExactAlarm.blockedReason)
        assertEquals(1, shadowOf(context.getSystemService(AlarmManager::class.java)).scheduledAlarms.size)
    }

    @Test
    fun mixedAtStartCutoffAndValidRowsRetainBothWithoutRejectingValidReminder() {
        val now = System.currentTimeMillis()
        val cutoff = plan("cutoff-plan", now + 30_000L, now + 30_000L, "cutoff-fp", "cutoff-plan")
        val validTrigger = now + 31_000L
        val valid = plan("valid-plan", validTrigger, validTrigger + 60_000L, "valid-fp", "valid-plan")
        insertRow("cutoff-plan", now + 30_000L, now + 30_000L, "cutoff-fp")
        insertRow("valid-plan", validTrigger, validTrigger + 60_000L, "valid-fp")

        assertEquals(1, LocalNotificationCoordinator.reconcile(context, "ignored", scope, JSONArray().put(cutoff).put(valid)).scheduledCount)
        val rows = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        assertEquals(2, rows.length())
        assertTrue(rows.keys().asSequence().any { rows.getJSONObject(it).getString("planId") == "cutoff-plan" && rows.getJSONObject(it).getString("reason") == "at_start_cutoff" })
        assertTrue(rows.keys().asSequence().any { rows.getJSONObject(it).getString("planId") == "valid-plan" && rows.getJSONObject(it).getString("state") == "scheduled" })
    }

    @Test
    fun dailyAndRefillJobsCoalesceToTheTwoFixedIds() {
        NotificationRefillScheduler.ensureDaily(context)
        NotificationRefillScheduler.requestRefill(context, "test-a")
        NotificationRefillScheduler.requestRefill(context, "test-b")
        val pending = context.getSystemService(JobScheduler::class.java)?.allPendingJobs.orEmpty().map { it.id }.toSet()
        assertEquals(setOf(NotificationRefillContract.DAILY_JOB_ID, NotificationRefillContract.REFILL_JOB_ID), pending)
    }

    @Test
    fun wireContextRetainsFlatProfileAndTermFlags() {
        val root = JSONObject()
            .put("schemaVersion", 1)
            .put("scope", JSONObject()
                .put("regionId", scope.regionId)
                .put("ownerHash", scope.ownerHash)
                .put("activationToken", scope.activationToken)
                .put("generation", scope.generation))
            .put("sourceEpoch", 1)
            .put("expectedProjectionEpoch", 0)
            .put("planningNowMs", 1_000L)
            .put("windowStartMs", 1_000L)
            .put("windowEndMs", 2_000L)
            .put("context", JSONObject()
                .put("ownerUserId", owner)
                .put("universityId", "university")
                .put("termId", "term")
                .put("primaryCalendarId", "calendar")
                .put("academicYear", 2026)
                .put("profileOnboardingStatus", "complete")
                .put("termStatus", "active")
                .put("termIsTemplate", false)
                .put("calendarDeleted", false))
        val parsed = NotificationRefillRequest.fromJson(root)
        assertEquals("complete", parsed.context.rawFlags.getString("profileOnboardingStatus"))
        assertEquals("active", parsed.context.rawFlags.getString("termStatus"))
        assertTrue(!parsed.context.rawFlags.getBoolean("termIsTemplate"))
    }

    @Test
    fun publicationRejectsSourceOrProjectionCasMismatchWithoutChangingDerivedRows() {
        insertRow("cas-plan", System.currentTimeMillis() + 30_000L, System.currentTimeMillis() + 90_000L, "cas-fp")
        val before = open().use { db -> db.rawQuery("SELECT COUNT(*) FROM local_notification_occurrences", null).use { it.moveToFirst(); it.getInt(0) } }
        val raw = publicationRequest(sourceEpoch = 2L, expectedProjectionEpoch = 1L)
        assertTrue(!LocalNotificationCoordinator.publishFromBackground(context, scope, raw))
        val after = open().use { db -> db.rawQuery("SELECT COUNT(*) FROM local_notification_occurrences", null).use { it.moveToFirst(); it.getInt(0) } }
        assertEquals(before, after)
    }

    @Test
    fun publicationRejectsChangedCanonicalContextBeforeDerivedWrite() {
        insertRow("context-plan", System.currentTimeMillis() + 30_000L, System.currentTimeMillis() + 90_000L, "context-fp")
        val before = open().use { db -> db.rawQuery("SELECT COUNT(*) FROM local_notification_occurrences", null).use { it.moveToFirst(); it.getInt(0) } }
        val raw = publicationRequest(sourceEpoch = 1L, expectedProjectionEpoch = 1L, universityId = "wrong-university")
        assertThrows(IllegalStateException::class.java) {
            LocalNotificationCoordinator.publishFromBackground(context, scope, raw)
        }
        val after = open().use { db -> db.rawQuery("SELECT COUNT(*) FROM local_notification_occurrences", null).use { it.moveToFirst(); it.getInt(0) } }
        assertEquals(before, after)
    }

    private fun plan(id: String, trigger: Long, occurrence: Long, fingerprint: String, logicalId: String) = JSONObject()
        .put("id", id).put("logicalId", logicalId).put("ownerUserId", owner)
        .put("kind", "assignment").put("sourceEntityId", "assignment-1")
        .put("rule", "absolute").put("fingerprint", fingerprint).put("reason", "eligible")
        .put("targetPath", "/assignment/$id").put("title", "title")
        .put("body", "body").put("sourceEpoch", 1L).put("projectionEpoch", 1L)
        .put("triggerAtMs", trigger).put("occurrenceAtMs", occurrence)

    private fun insertRow(id: String, trigger: Long, occurrence: Long, fingerprint: String) {
        open().use { db ->
            db.execSQL(
                "INSERT OR REPLACE INTO local_notification_occurrences " +
                    "(id, owner_user_id, kind, source_entity_id, occurrence_at, trigger_at, target_path, title, body, rule, fingerprint, source_epoch, projection_epoch, status, reason, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 1, 'desired', 'eligible', ?)",
                arrayOf<Any?>(id, owner, "assignment", "assignment-1", occurrence, trigger, "/assignment/$id", "title", "body", "absolute", fingerprint, System.currentTimeMillis()),
            )
            db.execSQL("INSERT OR REPLACE INTO local_notification_projection_states(owner_user_id, source_epoch, projection_epoch, capped, blocked_reason, planned_at) VALUES (?, 1, 1, 0, NULL, ?)", arrayOf<Any?>(owner, System.currentTimeMillis()))
        }
    }

    private fun deleteOccurrence(id: String) {
        open().use { db ->
            db.delete("local_notification_occurrences", "id=?", arrayOf(id))
        }
    }

    private fun markRowsDueNow(ids: List<String>) {
        open().use { db ->
            val placeholders = ids.joinToString(",") { "?" }
            db.rawQuery(
                "SELECT MAX(trigger_at) FROM local_notification_occurrences WHERE id IN ($placeholders)",
                ids.toTypedArray(),
            ).use { cursor ->
                check(cursor.moveToFirst())
                testWallNowMs = maxOf(testWallNowMs, cursor.getLong(0) + 1L)
            }
        }
    }

    private fun updateProjectionEpoch(epoch: Long, reason: String) {
        open().use { db ->
            db.execSQL("UPDATE local_notification_source_revisions SET epoch=? WHERE id=1", arrayOf(epoch))
            db.execSQL(
                "UPDATE local_notification_occurrences SET source_epoch=?, projection_epoch=?, reason=?, updated_at=? WHERE owner_user_id=?",
                arrayOf<Any?>(epoch, epoch, reason, System.currentTimeMillis(), owner),
            )
            db.execSQL(
                "UPDATE local_notification_projection_states SET source_epoch=?, projection_epoch=? WHERE owner_user_id=?",
                arrayOf<Any?>(epoch, epoch, owner),
            )
        }
    }

    private fun publicationRequest(sourceEpoch: Long, expectedProjectionEpoch: Long, universityId: String = "university"): JSONObject = JSONObject()
        .put("schemaVersion", 1)
        .put("scope", JSONObject()
            .put("regionId", scope.regionId)
            .put("ownerHash", scope.ownerHash)
            .put("activationToken", scope.activationToken)
            .put("generation", scope.generation))
        .put("sourceEpoch", sourceEpoch)
        .put("expectedProjectionEpoch", expectedProjectionEpoch)
        .put("planningNowMs", System.currentTimeMillis())
        .put("windowStartMs", System.currentTimeMillis())
        .put("windowEndMs", System.currentTimeMillis() + 60_000L)
        .put("context", JSONObject()
            .put("ownerUserId", owner)
            .put("universityId", universityId)
            .put("termId", "term")
            .put("primaryCalendarId", "calendar")
            .put("academicYear", 2026)
            .put("profileOnboardingStatus", "complete")
            .put("profileActive", true)
            .put("profileDeleted", false)
            .put("termOwnerUserId", owner)
            .put("termStatus", "active")
            .put("termIsTemplate", false)
            .put("termDeleted", false)
            .put("calendarDeleted", false))
        .put("plans", JSONArray())

    private fun open() = SQLiteDatabase.openDatabase(databaseFile.path, null, SQLiteDatabase.OPEN_READWRITE).also { opened += it }

    private fun createSchema(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE local_notification_source_revisions (id INTEGER PRIMARY KEY CHECK (id=1), epoch INTEGER NOT NULL, updated_at TEXT)")
        db.execSQL("INSERT INTO local_notification_source_revisions VALUES (1, 1, '')")
        db.execSQL("CREATE TABLE local_notification_occurrences (id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, kind TEXT NOT NULL, source_entity_id TEXT NOT NULL, occurrence_at INTEGER NOT NULL, trigger_at INTEGER NOT NULL, target_path TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, rule TEXT NOT NULL, fingerprint TEXT NOT NULL, source_epoch INTEGER NOT NULL, projection_epoch INTEGER NOT NULL, status TEXT NOT NULL, reason TEXT NOT NULL, updated_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE local_notification_projection_states (owner_user_id TEXT PRIMARY KEY, source_epoch INTEGER NOT NULL, projection_epoch INTEGER NOT NULL, capped INTEGER NOT NULL, blocked_reason TEXT, planned_at INTEGER NOT NULL)")
        db.execSQL("CREATE TABLE terms (id TEXT PRIMARY KEY, university_id TEXT NOT NULL, academic_year INTEGER NOT NULL, owner_user_id TEXT NOT NULL, status TEXT NOT NULL, is_template INTEGER NOT NULL, deleted_at INTEGER NULL)")
        db.execSQL("CREATE TABLE profiles (user_id TEXT PRIMARY KEY, university_id TEXT NOT NULL, active_term_id TEXT NOT NULL, primary_calendar_id TEXT NOT NULL, onboarding_status TEXT NOT NULL)")
        db.execSQL("CREATE TABLE calendars (id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL)")
        db.execSQL("INSERT INTO terms VALUES ('term', 'university', 2026, ?, 'active', 0, NULL)", arrayOf(owner))
        db.execSQL("INSERT INTO profiles VALUES (?, 'university', 'term', 'calendar', 'complete')", arrayOf(owner))
        db.execSQL("INSERT INTO calendars VALUES ('calendar', ?)", arrayOf(owner))
    }
}
