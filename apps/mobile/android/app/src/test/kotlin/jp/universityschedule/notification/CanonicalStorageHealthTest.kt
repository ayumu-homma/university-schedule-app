package jp.universityschedule.notification

import android.content.Context
import org.junit.After
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class CanonicalStorageHealthTest {
    private val context: Context = RuntimeEnvironment.getApplication()
    private val region = "e".repeat(64)
    private val healthDirectory = File(context.noBackupFilesDir, "storage-health")
    private var syncedDirectory: File? = null

    @Before
    fun setUp() {
        CanonicalStorageHealth.clearForTests()
        CanonicalStorageHealth.directorySyncForTests = { syncedDirectory = it }
        healthDirectory.deleteRecursively()
    }

    @After
    fun tearDown() {
        CanonicalStorageHealth.clearForTests()
        CanonicalStorageHealth.directorySyncForTests = null
        healthDirectory.deleteRecursively()
    }

    @Test
    fun rejectsNonCanonicalRegionIds() {
        assertThrows(IllegalArgumentException::class.java) {
            CanonicalStorageHealth.ensureHealthy(context, "scratch")
        }
        assertThrows(IllegalArgumentException::class.java) {
            CanonicalStorageHealth.recordMarker(context, "f".repeat(63), "test")
        }
    }

    @Test
    fun durableMarkerReLatchesAfterMemoryReset() {
        CanonicalStorageHealth.recordMarker(context, region, "test_corruption")
        assertTrue(File(healthDirectory, "$region.corrupt").isFile)
        assertTrue(syncedDirectory == healthDirectory)
        CanonicalStorageHealth.clearForTests()
        assertThrows(IllegalStateException::class.java) {
            CanonicalStorageHealth.ensureHealthy(context, region)
        }
    }

    @Test
    fun markerPersistenceFailureKeepsMemoryLatchAndSurfacesError() {
        check(healthDirectory.mkdirs() || healthDirectory.isDirectory)
        healthDirectory.deleteRecursively()
        check(healthDirectory.parentFile!!.mkdirs() || healthDirectory.parentFile!!.isDirectory)
        check(healthDirectory.createNewFile())
        assertThrows(IllegalStateException::class.java) {
            CanonicalStorageHealth.recordMarker(context, region, "test_persist_failure")
        }
        assertThrows(IllegalStateException::class.java) {
            CanonicalStorageHealth.ensureHealthy(context, region)
        }
    }
}
