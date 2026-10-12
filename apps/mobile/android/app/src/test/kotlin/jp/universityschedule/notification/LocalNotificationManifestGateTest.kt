package jp.universityschedule.notification

import android.content.Context
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File
import java.nio.file.Files

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class LocalNotificationManifestGateTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val region = "b".repeat(64)
    private lateinit var root: File
    private lateinit var previousDataDir: String
    private val fake = object : CanonicalSqliteDatabase {
        override fun rawQuery(sql: String, args: Array<String>?): CanonicalSqliteCursor = error("unused")
        override fun execSQL(sql: String, args: Array<Any?>?) = error("unused")
        override fun delete(table: String, whereClause: String, whereArgs: Array<String>?): Int = error("unused")
        override fun beginTransactionNonExclusive() = error("unused")
        override fun setTransactionSuccessful() = error("unused")
        override fun endTransaction() = error("unused")
        override fun inTransaction(): Boolean = false
        override fun close() = Unit
    }

    @Before
    fun setUp() {
        previousDataDir = context.applicationInfo.dataDir
        root = Files.createTempDirectory("notification-manifest-").toFile()
        context.applicationInfo.dataDir = root.path
        LocalNotificationCoordinator.scopedDatabaseProviderForTests = null
        LocalNotificationCoordinator.scopedDatabaseFactoryForTests = null
    }

    @After
    fun tearDown() {
        LocalNotificationCoordinator.scopedDatabaseProviderForTests = null
        LocalNotificationCoordinator.scopedDatabaseFactoryForTests = null
        context.applicationInfo.dataDir = previousDataDir
        root.deleteRecursively()
    }

    @Test
    fun malformedManifestRejectsBeforeDatabaseFactory() {
        val canonical = prepareCanonical()
        writeManifest(canonical, phase = "PREPARED")
        var opens = 0
        LocalNotificationCoordinator.scopedDatabaseFactoryForTests = { _, _, _ ->
            opens++
            fake
        }

        assertThrows(IllegalStateException::class.java) {
            LocalNotificationCoordinator.openScopedDatabase(context, region)
        }
        assertEquals(0, opens)
    }

    @Test
    fun missingManifestRejectsBeforeDatabaseFactory() {
        prepareCanonical()
        var opens = 0
        LocalNotificationCoordinator.scopedDatabaseFactoryForTests = { _, _, _ ->
            opens++
            fake
        }

        assertThrows(IllegalStateException::class.java) {
            LocalNotificationCoordinator.openScopedDatabase(context, region)
        }
        assertEquals(0, opens)
    }

    @Test
    fun malformedJsonRejectsBeforeDatabaseFactory() {
        val canonical = prepareCanonical()
        File(canonical.parentFile, "committed-v1.json").writeText("{not-json")
        var opens = 0
        LocalNotificationCoordinator.scopedDatabaseFactoryForTests = { _, _, _ ->
            opens++
            fake
        }

        assertThrows(IllegalStateException::class.java) {
            LocalNotificationCoordinator.openScopedDatabase(context, region)
        }
        assertEquals(0, opens)
    }

    @Test
    fun wrongRegionRejectsBeforeDatabaseFactory() {
        val canonical = prepareCanonical()
        writeManifest(canonical, phase = "COMMITTED", manifestRegion = "c".repeat(64))
        var opens = 0
        LocalNotificationCoordinator.scopedDatabaseFactoryForTests = { _, _, _ ->
            opens++
            fake
        }

        assertThrows(IllegalStateException::class.java) {
            LocalNotificationCoordinator.openScopedDatabase(context, region)
        }
        assertEquals(0, opens)
    }

    @Test
    fun validCommittedManifestReachesOnlyTheNarrowFactory() {
        val canonical = prepareCanonical()
        writeManifest(canonical, phase = "COMMITTED")
        var opens = 0
        LocalNotificationCoordinator.scopedDatabaseFactoryForTests = { _, _, path ->
            opens++
            check(path == canonical)
            fake
        }

        assertSame(fake, LocalNotificationCoordinator.openScopedDatabase(context, region))
        assertEquals(1, opens)
    }

    private fun prepareCanonical(): File {
        val directory = File(root, "app_flutter/spaces/$region")
        check(directory.mkdirs())
        return File(directory, "app.sqlite").also { check(it.createNewFile()) }
    }

    private fun writeManifest(canonical: File, phase: String, manifestRegion: String = region) {
        File(canonical.parentFile, "committed-v1.json").writeText(
            JSONObject()
                .put("format", "storage-publication-v1")
                .put("phase", phase)
                .put("regionId", manifestRegion)
                .put("importedLegacy", false)
                .put("candidateSha256", "a".repeat(64))
                .put("sourceReceiptSha256", JSONObject.NULL)
                .toString(),
        )
    }
}
