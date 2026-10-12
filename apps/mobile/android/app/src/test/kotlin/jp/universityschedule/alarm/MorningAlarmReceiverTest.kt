package jp.universityschedule.alarm

import android.app.AlarmManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import jp.universityschedule.scope.NativeScope
import jp.universityschedule.scope.NativeScopeFence

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [32])
class MorningAlarmReceiverTest {
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
        context.getSystemService(NotificationManager::class.java).cancelAll()
    }

    @Test
    fun enabledOwnerSchedulesAndReceiverRejectsAnotherOwner() {
        val coordinator = MorningAlarmCoordinator(context)
        var scope = activateOwner("owner-a")
        coordinator.synchronizeOwner("owner-a", scope)
        scope = NativeScopeFence.current(context)
        coordinator.save("owner-a", enabledArguments(), scope)
        val alarmManager = context.getSystemService(AlarmManager::class.java)
        val scheduled = shadowOf(alarmManager).nextScheduledAlarm
        assertNotNull(scheduled)
        val scheduledIntent = shadowOf(scheduled!!.operation).savedIntent
        assertEquals(scope.regionId, scheduledIntent.getStringExtra(EXTRA_SCOPE_REGION_ID))
        assertEquals(scope.generation, scheduledIntent.getLongExtra(EXTRA_SCOPE_GENERATION, -1L))
        assertEquals(
            scope.activationToken,
            scheduledIntent.getStringExtra(EXTRA_SCOPE_ACTIVATION_TOKEN),
        )
        assertEquals(ALARM_MODE_REGULAR, scheduledIntent.getStringExtra(EXTRA_ALARM_MODE))

        MorningAlarmReceiver().onReceive(context, scopedIntent(ACTION_ALARM_FIRE, "owner-b"))
        val notificationManager = context.getSystemService(NotificationManager::class.java)
        assertTrue(shadowOf(notificationManager).allNotifications.isEmpty())

        MorningAlarmReceiver().onReceive(context, scheduledIntent)
        assertEquals(1, shadowOf(notificationManager).allNotifications.size)
    }

    @Test
    fun stopAndSnoozeActionsAreIdempotent() {
        val coordinator = MorningAlarmCoordinator(context)
        val scope = activateOwner("owner-a")
        coordinator.synchronizeOwner("owner-a", scope)
        coordinator.save("owner-a", enabledArguments(), NativeScopeFence.current(context))
        coordinator.handleFire(ownerHash("owner-a"), ALARM_MODE_REGULAR, false)
        val receiver = MorningAlarmActionReceiver()
        val stop = scopedIntent(ACTION_ALARM_STOP, "owner-a")

        receiver.onReceive(context, stop)
        receiver.onReceive(context, stop)

        val notificationManager = context.getSystemService(NotificationManager::class.java)
        assertTrue(shadowOf(notificationManager).allNotifications.isEmpty())
        assertNotNull(
            shadowOf(context.getSystemService(AlarmManager::class.java)).nextScheduledAlarm,
        )
    }

    @Test
    fun bootReceiverRecomputesPersistedActiveSchedule() {
        val preferences = MorningAlarmPreferences(context)
        val hash = ownerHash("owner-a")
        activateOwner("owner-a")
        NativeScopeFence.activate(context, REGION_ID, hash)
        preferences.setActiveOwnerHash(hash)
        preferences.save(MorningAlarmSettings(ownerHash = hash, enabled = true))

        MorningAlarmRescheduleReceiver().onReceive(
            context,
            Intent(Intent.ACTION_BOOT_COMPLETED),
        )

        assertNotNull(
            shadowOf(context.getSystemService(AlarmManager::class.java)).nextScheduledAlarm,
        )
        assertNotNull(preferences.nextOccurrence(hash))
    }

    @Test
    fun signOutCancelsTheActiveOwnerScheduleAndNotification() {
        val coordinator = MorningAlarmCoordinator(context)
        val hash = ownerHash("owner-a")
        var scope = activateOwner("owner-a")
        coordinator.synchronizeOwner("owner-a", scope)
        scope = NativeScopeFence.current(context)
        coordinator.save("owner-a", enabledArguments(), scope)
        coordinator.handleFire(hash, ALARM_MODE_DEBUG, true)

        coordinator.synchronizeOwner(null, NativeScopeFence.current(context))

        assertNull(MorningAlarmPreferences(context).activeOwnerHash())
        assertNull(MorningAlarmPreferences(context).nextOccurrence(hash))
        assertNull(
            shadowOf(context.getSystemService(AlarmManager::class.java)).nextScheduledAlarm,
        )
        assertTrue(
            shadowOf(context.getSystemService(NotificationManager::class.java))
                .allNotifications
                .isEmpty(),
        )
    }

    private fun enabledArguments(): Map<String, Any> =
        mapOf(
            "version" to 1,
            "ownerId" to "owner-a",
            "enabled" to true,
            "hour" to 7,
            "minute" to 30,
            "weekdays" to listOf(1, 2, 3, 4, 5),
            "soundEnabled" to false,
            "vibrationEnabled" to false,
            "snoozeMinutes" to 10,
            "openTodayOnStop" to true,
            "lockScreenPrivacy" to true,
        )

    private fun activateOwner(ownerId: String): NativeScope {
        NativeScopeFence.prepare(context, REGION_ID)
        return NativeScopeFence.current(context)
    }

    private fun scopedIntent(action: String, ownerId: String): Intent {
        val scope = NativeScopeFence.current(context)
        return Intent(context, MorningAlarmActionReceiver::class.java).apply {
            this.action = action
            putExtra(EXTRA_OWNER_HASH, ownerHash(ownerId))
            if (action == ACTION_ALARM_FIRE) {
                putExtra(EXTRA_ALARM_MODE, ALARM_MODE_REGULAR)
            }
            putExtra(EXTRA_SCOPE_REGION_ID, scope.regionId)
            putExtra(EXTRA_SCOPE_OWNER_HASH, scope.ownerHash)
            putExtra(EXTRA_SCOPE_GENERATION, scope.generation)
            putExtra(EXTRA_SCOPE_ACTIVATION_TOKEN, scope.activationToken)
        }
    }

    companion object {
        private const val REGION_ID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
}
