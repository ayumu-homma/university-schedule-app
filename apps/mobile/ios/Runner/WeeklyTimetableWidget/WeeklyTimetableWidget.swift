// Contract-only WidgetKit source. The iOS host project and extension target
// are intentionally still external handoff work; see docs/IOS_IMPLEMENTATION_HANDOFF.md.

import CoreFoundation
import Foundation
import SwiftUI
import WidgetKit

private enum WidgetSnapshotContractError: Error {
    case invalid
}

private struct TimetableDay: Decodable {
    let dayOfWeek: Int
    let label: String
}

private struct TimetablePeriod: Decodable {
    let periodNo: Int
    let start: String
    let end: String
}

private struct TimetableItem: Decodable, Hashable {
    let courseId: String
    let dayOfWeek: Int
    let periodNo: Int
    let title: String
    let room: String?
    let colorKey: String
    let deepLink: String
}

private struct TimetableSnapshot: Decodable {
    let schemaVersion: Int
    let mode: String
    let generatedAt: String
    let weekStart: String
    let timezone: String
    let privacyMode: String
    let days: [TimetableDay]
    let periods: [TimetablePeriod]
    let items: [TimetableItem]

    static func decodeStrict(from data: Data) throws -> TimetableSnapshot {
        guard !data.isEmpty, data.count <= 64 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WidgetSnapshotContractError.invalid
        }

        try requireExactKeys(root, expected: [
            "schemaVersion", "mode", "generatedAt", "weekStart", "timezone",
            "privacyMode", "days", "periods", "items",
        ])
        guard try integer(root["schemaVersion"]) == 1,
              try string(root["mode"], maxLength: 32) == "timetable_week",
              try string(root["timezone"], maxLength: 32) == "Asia/Tokyo" else {
            throw WidgetSnapshotContractError.invalid
        }

        let generatedAt = try string(root["generatedAt"], maxLength: 40)
        let instantFormatter = ISO8601DateFormatter()
        instantFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard generatedAt.hasSuffix("Z"), instantFormatter.date(from: generatedAt) != nil else {
            throw WidgetSnapshotContractError.invalid
        }

        let weekStart = try string(root["weekStart"], maxLength: 10)
        try requireMonday(weekStart)
        let privacyMode = try string(root["privacyMode"], maxLength: 32)
        guard ["title", "titleAndRoom", "busyOnly"].contains(privacyMode) else {
            throw WidgetSnapshotContractError.invalid
        }

        let days = try array(root["days"])
        guard days.count == 5 else { throw WidgetSnapshotContractError.invalid }
        let expectedLabels = ["月", "火", "水", "木", "金"]
        for (index, rawDay) in days.enumerated() {
            let day = try dictionary(rawDay)
            try requireExactKeys(day, expected: ["dayOfWeek", "label"])
            guard try integer(day["dayOfWeek"]) == index + 1,
                  try string(day["label"], maxLength: 1) == expectedLabels[index] else {
                throw WidgetSnapshotContractError.invalid
            }
        }

        let periods = try array(root["periods"])
        guard periods.count == 5 else { throw WidgetSnapshotContractError.invalid }
        for (index, rawPeriod) in periods.enumerated() {
            let period = try dictionary(rawPeriod)
            try requireExactKeys(period, expected: ["periodNo", "start", "end"])
            let start = try clockMinutes(period["start"])
            let end = try clockMinutes(period["end"])
            guard try integer(period["periodNo"]) == index + 1, end > start else {
                throw WidgetSnapshotContractError.invalid
            }
        }

        let items = try array(root["items"])
        guard items.count <= 25 else { throw WidgetSnapshotContractError.invalid }
        var occupiedSlots = Set<String>()
        for rawItem in items {
            let item = try dictionary(rawItem)
            let commonKeys: Set<String> = [
                "courseId", "dayOfWeek", "periodNo", "title", "colorKey", "deepLink",
            ]
            try requireExactKeys(
                item,
                expected: privacyMode == "titleAndRoom"
                    ? commonKeys.union(["room"])
                    : commonKeys
            )

            let courseId = try string(item["courseId"], maxLength: 256)
            guard matches(courseId, pattern: "^[A-Za-z0-9._~-]{1,256}$") else {
                throw WidgetSnapshotContractError.invalid
            }
            let dayOfWeek = try integer(item["dayOfWeek"])
            let periodNo = try integer(item["periodNo"])
            guard (1...5).contains(dayOfWeek), (1...5).contains(periodNo),
                  occupiedSlots.insert("\(dayOfWeek):\(periodNo)").inserted else {
                throw WidgetSnapshotContractError.invalid
            }

            let title = try string(item["title"], maxLength: 120)
            if privacyMode == "busyOnly", title != "予定あり" {
                throw WidgetSnapshotContractError.invalid
            }
            if privacyMode == "titleAndRoom" {
                try optionalString(item["room"], maxLength: 80)
            }
            let colorKey = try string(item["colorKey"], maxLength: 32)
            guard matches(colorKey, pattern: "^[a-z][a-z0-9_]{0,31}$"),
                  try string(item["deepLink"], maxLength: 512)
                    == "unischedule://course/\(courseId)" else {
                throw WidgetSnapshotContractError.invalid
            }
        }

        return try JSONDecoder().decode(TimetableSnapshot.self, from: data)
    }

    private static func requireExactKeys(
        _ dictionary: [String: Any],
        expected: Set<String>
    ) throws {
        guard Set(dictionary.keys) == expected else {
            throw WidgetSnapshotContractError.invalid
        }
    }

    private static func dictionary(_ value: Any) throws -> [String: Any] {
        guard let result = value as? [String: Any] else {
            throw WidgetSnapshotContractError.invalid
        }
        return result
    }

    private static func array(_ value: Any?) throws -> [Any] {
        guard let result = value as? [Any] else {
            throw WidgetSnapshotContractError.invalid
        }
        return result
    }

    private static func integer(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw WidgetSnapshotContractError.invalid
        }
        let encoding = String(cString: number.objCType)
        guard encoding != "f", encoding != "d" else {
            throw WidgetSnapshotContractError.invalid
        }
        let result = number.intValue
        guard NSNumber(value: result) == number else {
            throw WidgetSnapshotContractError.invalid
        }
        return result
    }

    private static func string(_ value: Any?, maxLength: Int) throws -> String {
        guard let result = value as? String, !result.isEmpty,
              result.utf16.count <= maxLength else {
            throw WidgetSnapshotContractError.invalid
        }
        return result
    }

    private static func optionalString(_ value: Any?, maxLength: Int) throws {
        if value is NSNull { return }
        _ = try string(value, maxLength: maxLength)
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func clockMinutes(_ value: Any?) throws -> Int {
        let clock = try string(value, maxLength: 5)
        guard matches(clock, pattern: "^(?:[01][0-9]|2[0-3]):[0-5][0-9]$") else {
            throw WidgetSnapshotContractError.invalid
        }
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { throw WidgetSnapshotContractError.invalid }
        return parts[0] * 60 + parts[1]
    }

    private static func requireMonday(_ value: String) throws {
        guard matches(value, pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$") else {
            throw WidgetSnapshotContractError.invalid
        }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { throw WidgetSnapshotContractError.invalid }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
              calendar.component(.year, from: date) == parts[0],
              calendar.component(.month, from: date) == parts[1],
              calendar.component(.day, from: date) == parts[2],
              calendar.component(.weekday, from: date) == 2 else {
            throw WidgetSnapshotContractError.invalid
        }
    }
}

private struct WeeklyTimetableEntry: TimelineEntry {
    let date: Date
    let snapshot: TimetableSnapshot?
}

private struct WeeklyTimetableProvider: TimelineProvider {
    func placeholder(in context: Context) -> WeeklyTimetableEntry {
        WeeklyTimetableEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (WeeklyTimetableEntry) -> Void
    ) {
        completion(WeeklyTimetableEntry(date: Date(), snapshot: loadSnapshot()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<WeeklyTimetableEntry>) -> Void
    ) {
        let entry = WeeklyTimetableEntry(date: Date(), snapshot: loadSnapshot())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
    }

    private func loadSnapshot() -> TimetableSnapshot? {
        // Replace this placeholder with the App Group chosen in the Apple
        // Developer account during the external iOS signing handoff.
        let defaults = UserDefaults(suiteName: "group.jp.example.universityschedule")
        guard let json = defaults?.string(forKey: "weekly_timetable_snapshot"),
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? TimetableSnapshot.decodeStrict(from: data)
    }
}

private struct WeeklyTimetableWidgetView: View {
    let entry: WeeklyTimetableEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("今週の時間割")
                .font(.headline)
            if let snapshot = entry.snapshot {
                ForEach(Array(snapshot.items.prefix(5)), id: \.self) { item in
                    Text("\(item.dayOfWeek)曜 \(item.periodNo)限 \(item.title)")
                        .font(.caption)
                        .lineLimit(1)
                }
            } else {
                Text("アプリで時間割を作成")
                    .font(.caption)
            }
        }
        .padding()
    }
}

@main
struct WeeklyTimetableWidget: Widget {
    let kind = "WeeklyTimetableWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WeeklyTimetableProvider()) { entry in
            WeeklyTimetableWidgetView(entry: entry)
        }
        .configurationDisplayName("今週の時間割")
        .description("月〜金の授業を表示します。")
    }
}
