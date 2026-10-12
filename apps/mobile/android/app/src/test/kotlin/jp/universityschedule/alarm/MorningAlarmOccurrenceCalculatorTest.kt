package jp.universityschedule.alarm

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant

class MorningAlarmOccurrenceCalculatorTest {
    @Test
    fun sameTokyoWeekdayBeforeTimeUsesToday() {
        val now = Instant.parse("2026-08-09T22:29:00Z").toEpochMilli()

        val next = MorningAlarmOccurrenceCalculator.nextOccurrence(
            nowEpochMillis = now,
            hour = 7,
            minute = 30,
            weekdays = setOf(1),
        )

        assertEquals(Instant.parse("2026-08-09T22:30:00Z").toEpochMilli(), next)
    }

    @Test
    fun exactTimeAdvancesToNextSelectedWeek() {
        val now = Instant.parse("2026-08-09T22:30:00Z").toEpochMilli()

        val next = MorningAlarmOccurrenceCalculator.nextOccurrence(
            nowEpochMillis = now,
            hour = 7,
            minute = 30,
            weekdays = setOf(1),
        )

        assertEquals(Instant.parse("2026-08-16T22:30:00Z").toEpochMilli(), next)
    }

    @Test
    fun calculationIsFixedToTokyoAcrossDeviceTimezoneChanges() {
        val now = Instant.parse("2026-08-14T13:00:00Z").toEpochMilli()

        val next = MorningAlarmOccurrenceCalculator.nextOccurrence(
            nowEpochMillis = now,
            hour = 7,
            minute = 30,
            weekdays = setOf(1, 2, 3, 4, 5),
        )

        assertEquals(Instant.parse("2026-08-16T22:30:00Z").toEpochMilli(), next)
    }
}
