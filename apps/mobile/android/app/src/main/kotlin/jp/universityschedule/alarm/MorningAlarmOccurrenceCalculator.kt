package jp.universityschedule.alarm

import java.util.Calendar
import java.util.TimeZone

internal object MorningAlarmOccurrenceCalculator {
    private val tokyoTimeZone: TimeZone = TimeZone.getTimeZone(MORNING_ALARM_TIME_ZONE)

    fun nextOccurrence(
        nowEpochMillis: Long,
        hour: Int,
        minute: Int,
        weekdays: Set<Int>,
    ): Long {
        require(hour in 0..23)
        require(minute in 0..59)
        require(weekdays.isNotEmpty() && weekdays.all { it in 1..7 })

        val base = Calendar.getInstance(tokyoTimeZone).apply {
            timeInMillis = nowEpochMillis
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        repeat(8) { dayOffset ->
            val candidate = (base.clone() as Calendar).apply {
                add(Calendar.DAY_OF_MONTH, dayOffset)
                set(Calendar.HOUR_OF_DAY, hour)
                set(Calendar.MINUTE, minute)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            if (
                weekdays.contains(toDartWeekday(candidate.get(Calendar.DAY_OF_WEEK))) &&
                candidate.timeInMillis > nowEpochMillis
            ) {
                return candidate.timeInMillis
            }
        }
        error("No morning alarm occurrence could be calculated.")
    }

    private fun toDartWeekday(calendarWeekday: Int): Int =
        when (calendarWeekday) {
            Calendar.MONDAY -> 1
            Calendar.TUESDAY -> 2
            Calendar.WEDNESDAY -> 3
            Calendar.THURSDAY -> 4
            Calendar.FRIDAY -> 5
            Calendar.SATURDAY -> 6
            Calendar.SUNDAY -> 7
            else -> error("Invalid Calendar weekday.")
        }
}
