package jp.universityschedule.notification

import android.app.job.JobScheduler
import android.app.NotificationManager
import android.content.Context
import java.io.File
import jp.universityschedule.scope.NativeScopeFence
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LocalNotificationBusyTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val region = "9".repeat(64)
    private val owner = "busy-owner"

    @After
    fun tearDown() {
        LocalNotificationCoordinator.scopedDatabaseProviderForTests = null
        context.getSharedPreferences("ordinary_notification_receipts_v1", Context.MODE_PRIVATE)
            .edit().clear().commit()
        context.getSharedPreferences("native_scope_v1", Context.MODE_PRIVATE)
            .edit().clear().commit()
    }

    @Test
    fun busyBeginUnwindsWithoutSchedulingOrReceiptSideEffects() {
        NativeScopeFence.prepare(context, region)
        val scope = NativeScopeFence.activateOwner(context, region, owner)
        val database = BusyBeginDatabase()
        LocalNotificationCoordinator.scopedDatabaseProviderForTests = { _, _ -> database }
        val beforeJobs = context.getSystemService(JobScheduler::class.java).allPendingJobs.map { it.id }
        val beforeReceipts = context.getSharedPreferences(
            "ordinary_notification_receipts_v1",
            Context.MODE_PRIVATE,
        ).all.toMap()

        val error = org.junit.Assert.assertThrows(NativeSqliteException::class.java) {
            LocalNotificationCoordinator.publishFromBackground(
                context,
                scope,
                request(scope),
            )
        }

        assertTrue(error.isBusy)
        assertTrue(database.closed)
        assertEquals(beforeJobs, context.getSystemService(JobScheduler::class.java).allPendingJobs.map { it.id })
        assertTrue(shadowOf(context.getSystemService(NotificationManager::class.java)).allNotifications.isEmpty())
        assertEquals(
            beforeReceipts,
            context.getSharedPreferences("ordinary_notification_receipts_v1", Context.MODE_PRIVATE).all,
        )
    }

    @Test
    fun busyBeginPersistsValidatedRefillContextBeforeOpeningDatabase() {
        NativeScopeFence.prepare(context, region)
        val scope = NativeScopeFence.activateOwner(context, region, owner)
        val canonical = canonicalDatabaseFile()
        canonical.parentFile?.mkdirs()
        canonical.writeText("")
        LocalNotificationCoordinator.scopedDatabaseProviderForTests = { _, _ -> BusyBeginDatabase() }

        val error = org.junit.Assert.assertThrows(NativeSqliteException::class.java) {
            LocalNotificationCoordinator.publishFromBackground(
                context,
                scope,
                request(scope).put("databasePath", canonical.path),
            )
        }

        assertTrue(error.isBusy)
        assertEquals(
            mapOf(
                "databasePath" to canonical.path,
                "ownerUserId" to owner,
            ),
            LocalNotificationCoordinator.refillContextForJob(context),
        )
        canonical.delete()
        canonical.parentFile?.delete()
        canonical.parentFile?.parentFile?.delete()
    }

    @Test
    fun invalidRefillPathDoesNotPersistHeadlessContextOrOpenDatabase() {
        NativeScopeFence.prepare(context, region)
        val scope = NativeScopeFence.activateOwner(context, region, owner)
        var opened = false
        LocalNotificationCoordinator.scopedDatabaseProviderForTests = { _, _ ->
            opened = true
            BusyBeginDatabase()
        }

        assertThrows(IllegalStateException::class.java) {
            LocalNotificationCoordinator.publishFromBackground(
                context,
                scope,
                request(scope).put("databasePath", File(context.filesDir, "outside.sqlite").path),
            )
        }

        assertTrue(!opened)
        assertEquals(null, LocalNotificationCoordinator.refillContextForJob(context))
    }

    @Test
    fun busyDuringPostCommitReconcileRetainsHeadlessContext() {
        NativeScopeFence.prepare(context, region)
        val scope = NativeScopeFence.activateOwner(context, region, owner)
        val canonical = canonicalDatabaseFile()
        canonical.parentFile?.mkdirs()
        canonical.writeText("")
        val publicationDatabase = MinimalPublicationDatabase(ownerUserId = owner)
        val reconcileDatabase = MinimalPublicationDatabase(ownerUserId = owner, failFirstQuery = true)
        var opens = 0
        LocalNotificationCoordinator.scopedDatabaseProviderForTests = { _, _ ->
            if (opens++ == 0) publicationDatabase else reconcileDatabase
        }

        val error = org.junit.Assert.assertThrows(NativeSqliteException::class.java) {
            LocalNotificationCoordinator.publishFromBackground(
                context,
                scope,
                request(scope).put("databasePath", canonical.path),
            )
        }

        assertTrue(error.isBusy)
        assertTrue(publicationDatabase.closed)
        assertTrue(reconcileDatabase.closed)
        assertEquals(
            mapOf(
                "databasePath" to canonical.path,
                "ownerUserId" to owner,
            ),
            LocalNotificationCoordinator.refillContextForJob(context),
        )
        canonical.delete()
        canonical.parentFile?.delete()
        canonical.parentFile?.parentFile?.delete()
    }

    private fun canonicalDatabaseFile(): File = File(
        File(File(context.applicationInfo.dataDir, "app_flutter"), "spaces"),
        "$region/app.sqlite",
    )

    private fun request(scope: jp.universityschedule.scope.NativeScope): JSONObject = JSONObject()
        .put("schemaVersion", 1)
        .put("scope", JSONObject()
            .put("regionId", scope.regionId)
            .put("ownerHash", scope.ownerHash)
            .put("activationToken", scope.activationToken)
            .put("generation", scope.generation))
        .put("sourceEpoch", 1L)
        .put("expectedProjectionEpoch", 0L)
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
            .put("profileActive", true)
            .put("profileDeleted", false)
            .put("termOwnerUserId", owner)
            .put("termStatus", "active")
            .put("termIsTemplate", false)
            .put("termDeleted", false)
            .put("calendarDeleted", false))
        .put("plans", JSONArray())

    private class BusyBeginDatabase : CanonicalSqliteDatabase {
        var closed = false

        override fun rawQuery(sql: String, args: Array<String>?): CanonicalSqliteCursor = error("unused")
        override fun execSQL(sql: String, args: Array<Any?>?) = error("unused")
        override fun delete(table: String, whereClause: String, whereArgs: Array<String>?): Int = error("unused")
        override fun beginTransactionNonExclusive(): Unit = throw NativeSqliteException(5, "database is locked")
        override fun setTransactionSuccessful() = error("unused")
        override fun endTransaction() = error("unused")
        override fun inTransaction(): Boolean = false
        override fun close() { closed = true }
    }

    private class MinimalPublicationDatabase(
        private val ownerUserId: String,
        private val failFirstQuery: Boolean = false,
    ) : CanonicalSqliteDatabase {
        var closed = false
        private var inTransaction = false

        override fun rawQuery(sql: String, args: Array<String>?): CanonicalSqliteCursor {
            if (failFirstQuery) throw NativeSqliteException(5, "database is locked")
            val row = when {
                sql.contains("SELECT epoch FROM local_notification_source_revisions") -> listOf(1L)
                sql.contains("SELECT projection_epoch FROM local_notification_projection_states") -> emptyList()
                sql.contains("FROM sqlite_master") -> listOf(1)
                sql.contains("FROM terms") -> listOf("university", 2026, ownerUserId, "active", 0, null)
                sql.contains("FROM profiles") -> listOf("university", "term", "calendar", "complete")
                sql.contains("FROM calendars") -> listOf(ownerUserId)
                else -> error("unexpected fixture query: $sql")
            }
            return FixtureCursor(row)
        }

        override fun execSQL(sql: String, args: Array<Any?>?) = Unit
        override fun delete(table: String, whereClause: String, whereArgs: Array<String>?): Int = 0
        override fun beginTransactionNonExclusive() { inTransaction = true }
        override fun setTransactionSuccessful() = Unit
        override fun endTransaction() { inTransaction = false }
        override fun inTransaction(): Boolean = inTransaction
        override fun close() { closed = true }
    }

    private class FixtureCursor(private val values: List<Any?>) : CanonicalSqliteCursor {
        private var hasRow = false

        override fun moveToFirst(): Boolean {
            hasRow = values.isNotEmpty()
            return hasRow
        }

        override fun moveToNext(): Boolean {
            hasRow = false
            return false
        }

        private fun value(index: Int): Any? {
            check(hasRow)
            return values[index]
        }
        override fun getString(index: Int): String = value(index) as String
        override fun getLong(index: Int): Long = (value(index) as Number).toLong()
        override fun getDouble(index: Int): Double = (value(index) as Number).toDouble()
        override fun getBlob(index: Int): ByteArray? = value(index) as ByteArray?
        override fun getInt(index: Int): Int = (value(index) as Number).toInt()
        override fun isNull(index: Int): Boolean = value(index) == null
        override fun close() = Unit
    }
}
