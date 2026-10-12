package jp.universityschedule.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import jp.universityschedule.app.MainActivity
import jp.universityschedule.app.BuildConfig
import jp.universityschedule.app.R
import jp.universityschedule.scope.NativeScopeFence
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

const val WIDGET_PREFERENCES_NAME = "weekly_timetable_widget"
const val WIDGET_SNAPSHOT_KEY = "weekly_timetable_snapshot"
const val WIDGET_REGION_ID_KEY = "weekly_timetable_region_id"
const val WIDGET_OWNER_HASH_KEY = "weekly_timetable_owner_hash"
const val WIDGET_GENERATION_KEY = "weekly_timetable_generation"
const val WIDGET_ACTIVATION_TOKEN_KEY = "weekly_timetable_activation_token"
const val WIDGET_REFRESH_ACTION = "jp.universityschedule.app.action.REFRESH_WIDGET"

data class TimetableCell(
    val weekday: Int,
    val periodNo: Int,
    val title: String,
    val room: String?,
    val deepLink: String,
)

data class TimetablePeriod(
    val periodNo: Int,
    val start: String,
    val end: String,
)

data class TimetableSnapshot(
    val generatedAt: String,
    val weekStart: String,
    val timezone: String,
    val privacyMode: String,
    val periods: List<TimetablePeriod>,
    val cells: Map<Pair<Int, Int>, TimetableCell>,
)

object TimetableSnapshotParser {
    private const val maxPayloadLength = 64 * 1024
    private val safeSegment = Regex("^[A-Za-z0-9._~-]{1,256}$")
    private val safeColorKey = Regex("^[a-z][a-z0-9_]{0,31}$")
    private val utcTimestamp = Regex(
        "^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})\\.(\\d{3}|\\d{6})Z$",
    )
    private val date = Regex("^(\\d{4})-(\\d{2})-(\\d{2})$")
    private val clock = Regex("^(\\d{2}):(\\d{2})$")
    private val weekdayLabels = listOf("月", "火", "水", "木", "金")

    fun parse(payload: String?): TimetableSnapshot? {
        if (payload == null || payload.isEmpty() || payload.length > maxPayloadLength) {
            return null
        }
        return try {
            parseObject(JSONObject(payload))
        } catch (_: JSONException) {
            null
        } catch (_: RuntimeException) {
            null
        }
    }

    private fun parseObject(root: JSONObject): TimetableSnapshot {
        root.requireExactKeys(
            setOf(
                "schemaVersion",
                "mode",
                "generatedAt",
                "weekStart",
                "timezone",
                "privacyMode",
                "days",
                "periods",
                "items",
            ),
        )
        require(root.requireInt("schemaVersion") == 1)
        require(root.requireString("mode") == "timetable_week")
        val generatedAt = root.requireString("generatedAt")
        validateTimestamp(generatedAt)
        val weekStart = root.requireString("weekStart")
        validateWeekStart(weekStart)
        val timezone = root.requireString("timezone")
        require(timezone == "Asia/Tokyo")
        val privacyMode = root.requireString("privacyMode")
        require(privacyMode in setOf("title", "titleAndRoom", "busyOnly"))
        parseDays(root.getJSONArray("days"))
        val periods = parsePeriods(root.getJSONArray("periods"))
        val cells = parseItems(root.getJSONArray("items"), privacyMode)
        return TimetableSnapshot(
            generatedAt = generatedAt,
            weekStart = weekStart,
            timezone = timezone,
            privacyMode = privacyMode,
            periods = periods,
            cells = cells,
        )
    }

    private fun parseDays(days: JSONArray) {
        require(days.length() == 5)
        for (index in 0 until days.length()) {
            val day = days.getJSONObject(index)
            day.requireExactKeys(setOf("dayOfWeek", "label"))
            require(day.requireInt("dayOfWeek") == index + 1)
            require(day.requireString("label") == weekdayLabels[index])
        }
    }

    private fun parsePeriods(periods: JSONArray): List<TimetablePeriod> {
        require(periods.length() == 5)
        val parsed = mutableListOf<TimetablePeriod>()
        for (index in 0 until periods.length()) {
            val period = periods.getJSONObject(index)
            period.requireExactKeys(setOf("periodNo", "start", "end"))
            val periodNo = period.requireInt("periodNo")
            require(periodNo == index + 1)
            val startText = period.requireString("start")
            val endText = period.requireString("end")
            val start = parseClock(startText)
            val end = parseClock(endText)
            require(end > start)
            parsed += TimetablePeriod(
                periodNo = periodNo,
                start = startText,
                end = endText,
            )
        }
        return parsed
    }

    private fun parseItems(
        items: JSONArray,
        privacyMode: String,
    ): Map<Pair<Int, Int>, TimetableCell> {
        require(items.length() <= 25)
        val cells = mutableMapOf<Pair<Int, Int>, TimetableCell>()
        for (index in 0 until items.length()) {
            val item = items.getJSONObject(index)
            val expectedKeys = mutableSetOf(
                "courseId",
                "dayOfWeek",
                "periodNo",
                "title",
                "colorKey",
                "deepLink",
            )
            if (privacyMode == "titleAndRoom") expectedKeys += "room"
            item.requireExactKeys(expectedKeys)
            val courseId = item.requireString("courseId")
            require(safeSegment.matches(courseId))
            val weekday = item.requireInt("dayOfWeek")
            val periodNo = item.requireInt("periodNo")
            require(weekday in 1..5 && periodNo in 1..5)
            val slot = weekday to periodNo
            require(slot !in cells)
            val title = item.requireString("title")
            require(title.isNotEmpty() && title.length <= 120)
            if (privacyMode == "busyOnly") require(title == "予定あり")
            val room = if (privacyMode == "titleAndRoom" && !item.isNull("room")) {
                item.requireString("room").also {
                    require(it.isNotEmpty() && it.length <= 80)
                }
            } else {
                null
            }
            require(safeColorKey.matches(item.requireString("colorKey")))
            val deepLink = item.requireString("deepLink")
            require(deepLink == "unischedule://course/$courseId")
            cells[slot] = TimetableCell(
                weekday = weekday,
                periodNo = periodNo,
                title = title,
                room = room,
                deepLink = deepLink,
            )
        }
        return cells
    }

    private fun JSONObject.requireExactKeys(expected: Set<String>) {
        val actual = keys().asSequence().toSet()
        require(actual == expected)
    }

    private fun JSONObject.requireInt(key: String): Int {
        val value = get(key)
        require(value is Int)
        return value
    }

    private fun JSONObject.requireString(key: String): String {
        val value = get(key)
        require(value is String)
        return value
    }

    private fun validateTimestamp(value: String) {
        val match = requireNotNull(utcTimestamp.matchEntire(value))
        validateCalendarFields(
            year = match.groupValues[1].toInt(),
            month = match.groupValues[2].toInt(),
            day = match.groupValues[3].toInt(),
            hour = match.groupValues[4].toInt(),
            minute = match.groupValues[5].toInt(),
            second = match.groupValues[6].toInt(),
            timeZone = TimeZone.getTimeZone("UTC"),
        )
    }

    private fun validateWeekStart(value: String) {
        val match = requireNotNull(date.matchEntire(value))
        val calendar = validateCalendarFields(
            year = match.groupValues[1].toInt(),
            month = match.groupValues[2].toInt(),
            day = match.groupValues[3].toInt(),
            hour = 0,
            minute = 0,
            second = 0,
            timeZone = TimeZone.getTimeZone("Asia/Tokyo"),
        )
        require(calendar.get(Calendar.DAY_OF_WEEK) == Calendar.MONDAY)
    }

    private fun validateCalendarFields(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        timeZone: TimeZone,
    ): Calendar {
        val calendar = Calendar.getInstance(timeZone, Locale.ROOT).apply {
            isLenient = false
            clear()
            set(year, month - 1, day, hour, minute, second)
        }
        calendar.timeInMillis
        return calendar
    }

    private fun parseClock(value: String): Int {
        val match = requireNotNull(clock.matchEntire(value))
        val hour = match.groupValues[1].toInt()
        val minute = match.groupValues[2].toInt()
        require(hour in 0..23 && minute in 0..59)
        return hour * 60 + minute
    }
}

class WeeklyTimetableWidget : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        appWidgetIds.forEach { appWidgetId ->
            updateWidget(context, appWidgetManager, appWidgetId)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (
            intent.action == WIDGET_REFRESH_ACTION ||
            intent.action == Intent.ACTION_DATE_CHANGED ||
            intent.action == Intent.ACTION_TIME_CHANGED ||
            intent.action == Intent.ACTION_TIMEZONE_CHANGED
        ) {
            updateAll(context)
        }
    }

    companion object {
        private val dayHeaderIds = intArrayOf(
            R.id.widget_day_1,
            R.id.widget_day_2,
            R.id.widget_day_3,
            R.id.widget_day_4,
            R.id.widget_day_5,
        )
        private val periodHeaderIds = intArrayOf(
            R.id.widget_period_1,
            R.id.widget_period_2,
            R.id.widget_period_3,
            R.id.widget_period_4,
            R.id.widget_period_5,
        )
        private val cellIds = arrayOf(
            intArrayOf(
                R.id.widget_cell_1_1,
                R.id.widget_cell_1_2,
                R.id.widget_cell_1_3,
                R.id.widget_cell_1_4,
                R.id.widget_cell_1_5,
            ),
            intArrayOf(
                R.id.widget_cell_2_1,
                R.id.widget_cell_2_2,
                R.id.widget_cell_2_3,
                R.id.widget_cell_2_4,
                R.id.widget_cell_2_5,
            ),
            intArrayOf(
                R.id.widget_cell_3_1,
                R.id.widget_cell_3_2,
                R.id.widget_cell_3_3,
                R.id.widget_cell_3_4,
                R.id.widget_cell_3_5,
            ),
            intArrayOf(
                R.id.widget_cell_4_1,
                R.id.widget_cell_4_2,
                R.id.widget_cell_4_3,
                R.id.widget_cell_4_4,
                R.id.widget_cell_4_5,
            ),
            intArrayOf(
                R.id.widget_cell_5_1,
                R.id.widget_cell_5_2,
                R.id.widget_cell_5_3,
                R.id.widget_cell_5_4,
                R.id.widget_cell_5_5,
            ),
        )

        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, WeeklyTimetableWidget::class.java)
            manager.getAppWidgetIds(component).forEach { appWidgetId ->
                updateWidget(context, manager, appWidgetId)
            }
        }

        private fun updateWidget(
            context: Context,
            manager: AppWidgetManager,
            appWidgetId: Int,
        ) {
            val preferences = context.getSharedPreferences(
                WIDGET_PREFERENCES_NAME,
                Context.MODE_PRIVATE,
            )
            val scope = NativeScopeFence.current(context)
            val metadataMatches = scope.active &&
                scope.regionId == preferences.getString(WIDGET_REGION_ID_KEY, null) &&
                scope.ownerHash == preferences.getString(WIDGET_OWNER_HASH_KEY, null) &&
                scope.generation == preferences.getLong(WIDGET_GENERATION_KEY, -1L) &&
                scope.activationToken == preferences.getString(WIDGET_ACTIVATION_TOKEN_KEY, null)
            val payload = if (metadataMatches) {
                preferences.getString(WIDGET_SNAPSHOT_KEY, null)
            } else {
                null
            }
            val snapshot = TimetableSnapshotParser.parse(payload)
            val views = RemoteViews(context.packageName, R.layout.weekly_timetable_widget)
            views.setOnClickPendingIntent(
                R.id.widget_header,
                deepLinkIntent(context, "unischedule://timetable", 1),
            )
            if (snapshot == null) {
                renderUnavailable(views, payload == null)
            } else {
                renderSnapshot(context, views, snapshot)
            }
            manager.updateAppWidget(appWidgetId, views)
        }

        private fun renderUnavailable(views: RemoteViews, missing: Boolean) {
            views.setViewVisibility(R.id.widget_grid, View.GONE)
            views.setViewVisibility(R.id.widget_status, View.VISIBLE)
            views.setTextViewText(
                R.id.widget_status,
                if (missing) {
                    "アプリを開いて時間割を同期"
                } else {
                    "時間割を更新できません\nアプリを開いて再同期"
                },
            )
            views.setOnClickPendingIntent(
                R.id.widget_status,
                null,
            )
        }

        private fun renderSnapshot(
            context: Context,
            views: RemoteViews,
            snapshot: TimetableSnapshot,
        ) {
            views.setViewVisibility(R.id.widget_grid, View.VISIBLE)
            views.setViewVisibility(R.id.widget_status, View.GONE)
            val calendar = Calendar.getInstance(
                TimeZone.getTimeZone(snapshot.timezone),
                Locale.ROOT,
            )
            val today = (calendar.get(Calendar.DAY_OF_WEEK) + 5) % 7 + 1
            dayHeaderIds.forEachIndexed { index, viewId ->
                val weekday = index + 1
                val isToday = weekday == today
                views.setInt(
                    viewId,
                    "setBackgroundResource",
                    if (isToday) {
                        R.drawable.widget_day_current_background
                    } else {
                        R.drawable.widget_day_background
                    },
                )
                views.setTextColor(
                    viewId,
                    if (isToday) Color.WHITE else Color.rgb(23, 36, 58),
                )
                views.setOnClickPendingIntent(
                    viewId,
                    deepLinkIntent(context, "unischedule://timetable", 10 + weekday),
                )
            }
            snapshot.periods.forEachIndexed { index, period ->
                views.setTextViewText(
                    periodHeaderIds[index],
                    "${period.periodNo}限\n${period.start}\n${period.end}",
                )
            }
            for (periodIndex in 0 until 5) {
                for (weekdayIndex in 0 until 5) {
                    val weekday = weekdayIndex + 1
                    val periodNo = periodIndex + 1
                    val viewId = cellIds[periodIndex][weekdayIndex]
                    val cell = snapshot.cells[weekday to periodNo]
                    if (cell == null) {
                        views.setTextViewText(viewId, "")
                        views.setContentDescription(
                            viewId,
                            "${weekday}曜${periodNo}限に授業を追加",
                        )
                        views.setInt(
                            viewId,
                            "setBackgroundResource",
                            R.drawable.widget_empty_cell_background,
                        )
                        views.setOnClickPendingIntent(
                            viewId,
                            deepLinkIntent(
                                context,
                                "unischedule://course-new/$weekday/$periodNo",
                                100 + periodNo * 10 + weekday,
                            ),
                        )
                    } else {
                        val text = if (cell.room == null) {
                            cell.title
                        } else {
                            "${cell.title}\n${cell.room}"
                        }
                        views.setTextViewText(viewId, text)
                        views.setContentDescription(
                            viewId,
                            if (cell.room == null) {
                                "${cell.title}、${weekday}曜${periodNo}限"
                            } else {
                                "${cell.title}、${cell.room}、${weekday}曜${periodNo}限"
                            },
                        )
                        views.setInt(
                            viewId,
                            "setBackgroundResource",
                            R.drawable.widget_course_cell_background,
                        )
                        views.setOnClickPendingIntent(
                            viewId,
                            deepLinkIntent(
                                context,
                                cell.deepLink,
                                1000 + periodNo * 10 + weekday,
                            ),
                        )
                    }
                }
            }
        }

        private fun deepLinkIntent(
            context: Context,
            uri: String,
            requestCode: Int,
        ): PendingIntent {
            val intent = Intent(
                Intent.ACTION_VIEW,
                Uri.parse(environmentDeepLink(uri)),
                context,
                MainActivity::class.java,
            ).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                val scope = NativeScopeFence.current(context)
                if (scope.active) {
                    data = Uri.parse(environmentDeepLink(uri)).buildUpon()
                        .fragment("scope=${scope.activationToken}")
                        .build()
                    putExtra("scope_region_id", scope.regionId)
                    putExtra("scope_owner_hash", scope.ownerHash)
                    putExtra("scope_generation", scope.generation)
                    putExtra("scope_activation_token", scope.activationToken)
                }
            }
            return PendingIntent.getActivity(
                context,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun environmentDeepLink(canonicalUri: String): String {
            require(canonicalUri.startsWith("unischedule://"))
            return "${BuildConfig.DEEP_LINK_SCHEME}://" +
                canonicalUri.removePrefix("unischedule://")
        }
    }
}
