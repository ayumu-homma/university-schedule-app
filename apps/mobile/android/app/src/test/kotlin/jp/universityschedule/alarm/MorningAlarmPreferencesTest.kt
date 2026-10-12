package jp.universityschedule.alarm

import android.content.Context
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MorningAlarmPreferencesTest {
    private val context: Context = RuntimeEnvironment.getApplication()

    @After
    fun tearDown() {
        context.getSharedPreferences(
            MorningAlarmPreferences.PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        ).edit().clear().commit()
        context.getSharedPreferences(
            "native_scope_v1",
            Context.MODE_PRIVATE,
        ).edit().clear().commit()
    }

    @Test
    fun defaultsAreOffAndOwnerIdsAreNeverStoredInPlainText() {
        val rawOwnerId = "student-owner-sensitive-id"
        val hash = ownerHash(rawOwnerId)
        val preferences = MorningAlarmPreferences(context)

        preferences.setActiveOwnerHash(hash)
        val defaults = preferences.read(hash)
        preferences.save(defaults.copy(enabled = true, hour = 8))

        assertFalse(defaults.enabled)
        assertEquals(8, preferences.read(hash).hour)
        val rawPreferences = context.getSharedPreferences(
            MorningAlarmPreferences.PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        ).all
        assertTrue(rawPreferences.isNotEmpty())
        assertFalse(rawPreferences.toString().contains(rawOwnerId))
    }

    @Test
    fun activeOwnerSwitchKeepsNamespacesIsolated() {
        val ownerA = ownerHash("owner-a")
        val ownerB = ownerHash("owner-b")
        val preferences = MorningAlarmPreferences(context)
        preferences.save(
            MorningAlarmSettings(ownerHash = ownerA, enabled = true, hour = 6),
        )
        preferences.save(
            MorningAlarmSettings(ownerHash = ownerB, enabled = false, hour = 9),
        )

        preferences.setActiveOwnerHash(ownerA)
        assertTrue(preferences.readActive()!!.enabled)
        preferences.setActiveOwnerHash(ownerB)
        assertFalse(preferences.readActive()!!.enabled)
        assertEquals(9, preferences.readActive()!!.hour)
        preferences.setActiveOwnerHash(null)
        assertNull(preferences.readActive())
    }
}
