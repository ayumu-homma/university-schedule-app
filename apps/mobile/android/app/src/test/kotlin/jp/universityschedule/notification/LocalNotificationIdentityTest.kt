package jp.universityschedule.notification

import jp.universityschedule.scope.NativeScope
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalNotificationIdentityTest {
    private val scope = NativeScope(
        regionId = "a".repeat(64),
        ownerHash = "b".repeat(64),
        activationToken = "activation-a",
        generation = 7L,
        active = true,
    )

    @Test
    fun fullIdentitySeparatesSameTimeTargetsAndRulesWithoutIntHashing() {
        val first = LocalNotificationCoordinator.identityForTest(
            scope, "local-a", "assignment", "entity-a", 1_800_000_000_000L, "due_reminder",
        )
        val second = LocalNotificationCoordinator.identityForTest(
            scope, "local-b", "assignment", "entity-b", 1_800_000_000_000L, "due_reminder",
        )
        val third = LocalNotificationCoordinator.identityForTest(
            scope, "local-a", "assignment", "entity-a", 1_800_000_000_000L, "previous_day",
        )
        assertNotEquals(first, second)
        assertNotEquals(first, third)
        assertTrue(first.startsWith("v1|r=${scope.regionId}|o=${scope.ownerHash}|"))
        assertTrue(first.contains("|t=1800000000000|rule="))
    }
}
