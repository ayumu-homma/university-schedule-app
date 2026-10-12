package jp.universityschedule.notification

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import jp.universityschedule.scope.NativeScope
import jp.universityschedule.scope.NativeScopeFence
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowAlarmManager
import org.robolectric.shadows.ShadowSystemClock
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * End-to-end native delivery checks against the same scoped SQLite projection
 * used by the app. These tests deliberately do not mock AlarmManager,
 * NotificationManager, or the scope/owner fence.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LocalNotificationDeliveryTest {
    private val testReceiver = LocalNotificationReceiver(Executor { it.run() })
    private val context: Context = RuntimeEnvironment.getApplication()
    private val region = "a".repeat(64)
    private val owner = "owner-a"
    private val ownerB = "owner-b"
    private val planId = "plan-delivery"
    private val fingerprint = "fingerprint-v1"
    private lateinit var scope: NativeScope
    private lateinit var testDatabase: SQLiteDatabase
    private lateinit var databaseDirectory: File
    private lateinit var databaseFile: File
    private var testWallNowMs: Long = 0L
    private val openedDatabases = mutableListOf<SQLiteDatabase>()

    @Before
    fun setUp() {
        ShadowSystemClock.reset()
        testWallNowMs = System.currentTimeMillis()
        NotificationTime.nowForTests = { testWallNowMs }
        ShadowAlarmManager.setCanScheduleExactAlarms(true)
        shadowOf(context as android.app.Application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            android.app.NotificationChannel(
                LOCAL_NOTIFICATION_CHANNEL,
                "Phase 7.1 test notifications",
                NotificationManager.IMPORTANCE_DEFAULT,
            ),
        )
        NativeScopeFence.prepare(context, region)
        scope = NativeScopeFence.activateOwner(context, region, owner)
        databaseDirectory = Files.createTempDirectory("usn-").toFile()
        databaseFile = File(databaseDirectory, "n.db")
        check(databaseFile.createNewFile())
        val schemaDatabase = SQLiteDatabase.openDatabase(
            databaseFile.path,
            null,
            SQLiteDatabase.OPEN_READWRITE,
        )
        createSchema(schemaDatabase)
        schemaDatabase.close()
        testDatabase = openDatabase()
        LocalNotificationCoordinator.scopedDatabaseProviderForTests = { _, _ -> openDatabase().asCanonicalFixture() }
    }

    @After
    fun tearDown() {
        NotificationTime.nowForTests = null
        context.getSystemService(NotificationManager::class.java).cancelAll()
        ShadowAlarmManager.reset()
        context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
            .edit().clear().commit()
        context.getSharedPreferences("native_scope_v1", Context.MODE_PRIVATE)
            .edit().clear().commit()
        LocalNotificationCoordinator.scopedDatabaseProviderForTests = null
        synchronized(openedDatabases) {
            openedDatabases.toList().asReversed().forEach { database ->
                if (database.isOpen) database.close()
            }
            openedDatabases.clear()
        }
        databaseFile.delete()
        databaseDirectory.delete()
    }

    @Test
    fun reconcileRegistersAnExactAlarmAndFiringItPostsARealPrivateNotification() {
        val plan = plan(triggerInMs = 30_000L, occurrenceInMs = 90_000L)
        val intent = reconcileAndReadAlarmIntent(plan)
        val alarm = shadowOf(context.getSystemService(AlarmManager::class.java)).peekNextScheduledAlarm()

        assertNotNull(alarm)
        assertEquals(AlarmManager.RTC_WAKEUP, alarm!!.type)
        assertTrue(alarm.isAllowWhileIdle)
        assertEquals(LOCAL_NOTIFICATION_ACTION, intent.action)
        assertEquals(planId, intent.getStringExtra(EXTRA_PLAN_ID))

        makeRowDueNow()
        testReceiver.onReceive(context, intent)

        val notifications = shadowOf(
            context.getSystemService(NotificationManager::class.java),
        ).allNotifications
        assertEquals(1, notifications.size)
        val notification = notifications.single()
        assertEquals(Notification.VISIBILITY_PRIVATE, notification.visibility)
        assertNotNull(notification.publicVersion)
        assertEquals("予定の通知", notification.publicVersion!!.extras.getCharSequence(Notification.EXTRA_TITLE))
        assertEquals("予定があります", notification.publicVersion!!.extras.getCharSequence(Notification.EXTRA_TEXT))
    }

    @Test
    fun scopeAbaRejectsOldAlarmAfterOwnerChangesAndChangesBack() {
        val intent = reconcileAndReadAlarmIntent(plan(30_000L, 90_000L))

        NativeScopeFence.activateOwner(context, region, ownerB)
        testReceiver.onReceive(context, intent)
        assertTrue(shadowOf(context.getSystemService(NotificationManager::class.java)).allNotifications.isEmpty())

        NativeScopeFence.activateOwner(context, region, owner)
        testReceiver.onReceive(context, intent)
        assertTrue(shadowOf(context.getSystemService(NotificationManager::class.java)).allNotifications.isEmpty())
    }

    @Test
    fun sourceEpochChangedAfterPlanningPreventsContentAtFireTime() {
        val plan = plan(30_000L, 90_000L)
        val intent = reconcileAndReadAlarmIntent(plan)
        testDatabase.execSQL("UPDATE local_notification_source_revisions SET epoch = 2 WHERE id = 1")

        makeRowDueNow()
        testReceiver.onReceive(context, intent)

        assertTrue(shadowOf(context.getSystemService(NotificationManager::class.java)).allNotifications.isEmpty())
        assertFalse(LocalNotificationCoordinator.isDelivered(context, intent.getStringExtra(EXTRA_IDENTITY)!!, fingerprint))
    }

    @Test
    fun sameOwnerTapRejectsStaleFingerprintAndSubmittedDeletion() {
        val intent = reconcileAndReadAlarmIntent(plan(30_000L, 90_000L))
        makeRowDueNow()

        assertTrue(LocalNotificationCoordinator.validateTap(context, intent))

        updateRow("fingerprint = 'fingerprint-v2'")
        assertFalse(LocalNotificationCoordinator.validateTap(context, intent))

        updateRow("fingerprint = '$fingerprint', status = 'deleted'")
        assertFalse(LocalNotificationCoordinator.validateTap(context, intent))
    }

    @Test
    fun bootRecoveryReRegistersAnUndeliveredAlarm() {
        val intent = reconcileAndReadAlarmIntent(plan(30_000L, 90_000L))
        clearScheduledAlarms()
        assertNull(shadowOf(context.getSystemService(AlarmManager::class.java)).peekNextScheduledAlarm())

        LocalNotificationRecoveryReceiver().onReceive(
            context,
            Intent(Intent.ACTION_BOOT_COMPLETED),
        )

        val recovered = shadowOf(context.getSystemService(AlarmManager::class.java)).peekNextScheduledAlarm()
        assertNotNull(recovered)
        assertEquals(intent, shadowOf(recovered!!.operation).savedIntent)
    }

    @Test
    fun duplicateReplayDoesNotPostTheSameDeliveredIdentityTwice() {
        val plan = plan(30_000L, 90_000L)
        val intent = reconcileAndReadAlarmIntent(plan)
        makeRowDueNow()
        testReceiver.onReceive(context, intent)
        assertEquals(1, shadowOf(context.getSystemService(NotificationManager::class.java)).allNotifications.size)

        testReceiver.onReceive(context, intent)
        assertEquals(1, shadowOf(context.getSystemService(NotificationManager::class.java)).allNotifications.size)
        assertTrue(LocalNotificationCoordinator.isDelivered(context, intent.getStringExtra(EXTRA_IDENTITY)!!, fingerprint))
    }

    @Test
    fun delayedOsCallbackStillDeliversWhenPlannerMarksAnAlreadyScheduledRowPast() {
        val intent = reconcileAndReadAlarmIntent(plan(30_000L, 90_000L))
        // The planner can mark a row past after an OS wakeup was already
        // registered. The callback must use the durable scheduled wakeup
        // acknowledgement rather than treating that state as a new catch-up.
        testWallNowMs = intent.getLongExtra(EXTRA_TRIGGER_AT, 0L) + 1L
        updateRow("reason = 'past'")

        testReceiver.onReceive(context, intent)

        assertEquals(1, shadowOf(context.getSystemService(NotificationManager::class.java)).allNotifications.size)
        assertTrue(LocalNotificationCoordinator.isDelivered(context, intent.getStringExtra(EXTRA_IDENTITY)!!, fingerprint))
    }

    @Test
    fun capKeepsEarliestTwoHundredAndDefersTheRestForPromotion() {
        val plans = JSONArray()
        repeat(201) { index ->
            plans.put(plan(30_000L + index * 1_000L, 90_000L + index * 1_000L, "plan-cap-$index"))
        }
        val status = LocalNotificationCoordinator.reconcile(context, "ignored-by-native", scope, plans)
        assertEquals(200, status.scheduledCount)
        val rows = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans")
        var scheduled = 0
        var deferred = 0
        rows.keys().forEach { key ->
            val state = rows.getJSONObject(key).optString("state")
            if (state == "scheduled") scheduled++
            if (state == "deferred") deferred++
        }
        assertEquals(200, scheduled)
        assertEquals(1, deferred)
    }

    @Test
    fun postingFailureRetryRemainsBoundedAfterOriginalTriggerIsPast() {
        val intent = reconcileAndReadAlarmIntent(plan(30_000L, 90_000L))
        val identity = intent.getStringExtra(EXTRA_IDENTITY)!!
        assertTrue(LocalNotificationCoordinator.markPosting(context, identity, fingerprint))
        assertTrue(LocalNotificationCoordinator.retryPosting(context, intent, intent.getLongExtra(EXTRA_OCCURRENCE_AT, 0L)))
        val retry = shadowOf(context.getSystemService(AlarmManager::class.java)).nextScheduledAlarm
        assertNotNull(retry)
        assertTrue(retry!!.triggerAtMs > System.currentTimeMillis())
    }

    @Test
    fun recoveryTurnsPersistedPostingClaimIntoBoundedRetry() {
        val intent = reconcileAndReadAlarmIntent(plan(30_000L, 90_000L))
        val identity = intent.getStringExtra(EXTRA_IDENTITY)!!
        assertTrue(LocalNotificationCoordinator.markPosting(context, identity, fingerprint))
        clearScheduledAlarms()

        LocalNotificationCoordinator.recover(context)

        val retry = shadowOf(context.getSystemService(AlarmManager::class.java)).peekNextScheduledAlarm()
        assertNotNull(retry)
        assertTrue(retry!!.triggerAtMs > System.currentTimeMillis())
        val entry = JSONObject(
            context.getSharedPreferences(LOCAL_NOTIFICATION_PREFS, Context.MODE_PRIVATE)
                .getString("registry", "{}")!!,
        ).getJSONObject("plans").getJSONObject(identity)
        assertEquals("scheduled", entry.getString("state"))
        assertTrue(entry.getInt("retries") > 0)
        assertTrue(entry.getLong("nextAttemptAtMs") < entry.getLong("occurrenceAtMs"))
    }

    @Test
    fun receiverWaitsForWriterReservationThenRejectsTheCommittedSourceChange() {
        val intent = reconcileAndReadAlarmIntent(plan(30_000L, 90_000L))
        val writer = testDatabase
        val started = CountDownLatch(1)
        val finished = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            writer.beginTransactionNonExclusive()
            writer.execSQL("UPDATE local_notification_source_revisions SET epoch = 2 WHERE id = 1")
            executor.execute {
                started.countDown()
                testReceiver.onReceive(context, intent)
                finished.countDown()
            }
            assertTrue(started.await(5, TimeUnit.SECONDS))
            assertTrue(shadowOf(context.getSystemService(NotificationManager::class.java)).allNotifications.isEmpty())
            assertFalse(finished.await(200, TimeUnit.MILLISECONDS))

            writer.setTransactionSuccessful()
            writer.endTransaction()
            assertTrue(finished.await(5, TimeUnit.SECONDS))
            assertTrue(shadowOf(context.getSystemService(NotificationManager::class.java)).allNotifications.isEmpty())
        } finally {
            if (writer.inTransaction()) writer.endTransaction()
            executor.shutdownNow()
        }
    }

    private fun reconcileAndReadAlarmIntent(plan: JSONObject): Intent {
        val status = LocalNotificationCoordinator.reconcile(
            context,
            "ignored-by-native",
            scope,
            JSONArray().put(plan),
        )
        assertEquals(1, status.scheduledCount)
        val alarm = shadowOf(context.getSystemService(AlarmManager::class.java)).peekNextScheduledAlarm()
        assertNotNull(alarm)
        return shadowOf(alarm!!.operation).savedIntent
    }

    private fun plan(triggerInMs: Long, occurrenceInMs: Long, id: String = planId): JSONObject {
        val now = System.currentTimeMillis()
        val triggerAt = now + triggerInMs
        val occurrenceAt = now + occurrenceInMs
        insertRow(triggerAt, occurrenceAt, id)
        return JSONObject()
            .put("id", id)
            .put("ownerUserId", owner)
            .put("kind", "assignment")
            .put("sourceEntityId", "assignment-1")
            .put("rule", "absolute")
            .put("fingerprint", fingerprint)
            .put("reason", "eligible")
            .put("targetPath", "/assignments/$id")
            .put("title", "提出物")
            .put("body", "提出期限が近づいています")
            .put("sourceEpoch", 1L)
            .put("projectionEpoch", 1L)
            .put("triggerAtMs", triggerAt)
            .put("occurrenceAtMs", occurrenceAt)
    }

    private fun insertRow(triggerAt: Long, occurrenceAt: Long, id: String = planId) {
        val db = testDatabase
        db.execSQL(
                "INSERT OR REPLACE INTO local_notification_occurrences " +
                    "(id, owner_user_id, kind, source_entity_id, occurrence_at, trigger_at, target_path, " +
                    "title, body, rule, fingerprint, source_epoch, projection_epoch, status, reason, updated_at) " +
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arrayOf<Any?>(
                    id, owner, "assignment", "assignment-1", occurrenceAt, triggerAt,
                    "/assignments/$id", "提出物", "提出期限が近づいています", "absolute",
                    fingerprint, 1L, 1L, "desired", "eligible", System.currentTimeMillis(),
                ),
            )
        db.execSQL(
                "INSERT OR REPLACE INTO local_notification_projection_states " +
                    "(owner_user_id, source_epoch, projection_epoch, capped, blocked_reason, planned_at) " +
                    "VALUES (?, ?, ?, ?, ?, ?)",
                arrayOf<Any?>(owner, 1L, 1L, 0, null, System.currentTimeMillis()),
        )
    }

    private fun makeRowDueNow() {
        testDatabase.rawQuery(
            "SELECT trigger_at FROM local_notification_occurrences WHERE id = ?",
            arrayOf(planId),
        ).use { cursor ->
            check(cursor.moveToFirst())
            testWallNowMs = maxOf(testWallNowMs, cursor.getLong(0) + 1L)
        }
    }

    private fun updateRow(setClause: String) {
        testDatabase.execSQL("UPDATE local_notification_occurrences SET $setClause WHERE id = ?", arrayOf(planId))
    }

    private fun createSchema(db: SQLiteDatabase) {
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS local_notification_source_revisions " +
                "(id INTEGER PRIMARY KEY CHECK (id = 1), epoch INTEGER NOT NULL, updated_at TEXT)",
        )
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS local_notification_occurrences " +
                "(id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, kind TEXT NOT NULL, " +
                "source_entity_id TEXT NOT NULL, occurrence_at INTEGER NOT NULL, trigger_at INTEGER NOT NULL, " +
                "target_path TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, rule TEXT NOT NULL, " +
                "fingerprint TEXT NOT NULL, source_epoch INTEGER NOT NULL, projection_epoch INTEGER NOT NULL, " +
                "status TEXT NOT NULL, reason TEXT NOT NULL, updated_at INTEGER NOT NULL)",
        )
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS local_notification_projection_states " +
                "(owner_user_id TEXT PRIMARY KEY, source_epoch INTEGER NOT NULL, projection_epoch INTEGER NOT NULL, " +
                "capped INTEGER NOT NULL, blocked_reason TEXT, planned_at INTEGER NOT NULL)",
        )
        // Phase 7.1 publication validation reads the canonical schema18
        // context in the same scoped SQLite transaction as the projection.
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS terms " +
                "(id TEXT PRIMARY KEY, university_id TEXT NOT NULL, academic_year INTEGER NOT NULL, " +
                "owner_user_id TEXT NOT NULL, status TEXT NOT NULL, is_template INTEGER NOT NULL, deleted_at INTEGER NULL)",
        )
        db.execSQL(
            "CREATE TABLE IF NOT EXISTS profiles " +
                "(user_id TEXT PRIMARY KEY, university_id TEXT NOT NULL, active_term_id TEXT NOT NULL, " +
                "primary_calendar_id TEXT NOT NULL, onboarding_status TEXT NOT NULL)",
        )
        db.execSQL("CREATE TABLE IF NOT EXISTS calendars (id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL)")
        db.execSQL(
            "INSERT OR REPLACE INTO terms VALUES ('term', 'university', 2026, ?, 'active', 0, NULL)",
            arrayOf(owner),
        )
        db.execSQL(
            "INSERT OR REPLACE INTO profiles VALUES (?, 'university', 'term', 'calendar', 'complete')",
            arrayOf(owner),
        )
        db.execSQL("INSERT OR REPLACE INTO calendars VALUES ('calendar', ?)", arrayOf(owner))
        db.execSQL("INSERT OR IGNORE INTO local_notification_source_revisions(id, epoch, updated_at) VALUES (1, 1, '')")
    }

    private fun openDatabase(): SQLiteDatabase = SQLiteDatabase.openDatabase(
        databaseFile.path,
        null,
        SQLiteDatabase.OPEN_READWRITE,
    ).also { database -> synchronized(openedDatabases) { openedDatabases += database } }

    private fun clearScheduledAlarms() {
        val alarmManager = context.getSystemService(AlarmManager::class.java)
        shadowOf(alarmManager).scheduledAlarms.toList().forEach { scheduled ->
            scheduled.operation?.let(alarmManager::cancel)
        }
    }

}
