import 'package:shared_domain/shared_domain.dart';
import 'package:test/test.dart';

DateTime jst(int year, int month, int day, [int hour = 0, int minute = 0]) {
  return JapanTime.at(
    year: year,
    month: month,
    day: day,
    hour: hour,
    minute: minute,
  );
}

void main() {
  group('RecurrenceExpander', () {
    final expander = RecurrenceExpander();

    test('expands weekly recurrence with one occurrence delete and override',
        () {
      final event = ScheduleEvent(
        id: 'routine',
        ownerUserId: 'u1',
        calendarId: 'c1',
        title: 'ゼミ',
        kind: EventKind.routine,
        startAt: jst(2026, 6, 29, 10),
        endAt: jst(2026, 6, 29, 11),
        recurrenceRule: const RecurrenceRule(
          frequency: RecurrenceFrequency.weekly,
          byWeekdays: [DateTime.monday],
          count: 4,
        ),
      );

      final occurrences = expander.expand(
        event: event,
        rangeStart: jst(2026, 6, 1),
        rangeEnd: jst(2026, 8, 1),
        exceptions: [
          EventException(
            id: 'delete',
            eventId: 'routine',
            recurrenceId: jst(2026, 7, 6, 10),
            mode: EventExceptionMode.cancelled,
          ),
          EventException(
            id: 'move',
            eventId: 'routine',
            recurrenceId: jst(2026, 7, 13, 10),
            mode: EventExceptionMode.modified,
            overrideStartAt: jst(2026, 7, 13, 13),
            overrideEndAt: jst(2026, 7, 13, 14),
            overrideTitle: 'ゼミ 発表回',
          ),
        ],
      );

      expect(occurrences, hasLength(3));
      expect(occurrences.map((o) => o.startAt), contains(jst(2026, 7, 13, 13)));
      expect(occurrences.any((o) => o.startAt == jst(2026, 7, 6, 10)), isFalse);
      expect(occurrences.first.recurrenceId, equals(jst(2026, 6, 29, 10)));
    });

    test('expands biweekly recurrence', () {
      final event = ScheduleEvent(
        id: 'club',
        ownerUserId: 'u1',
        calendarId: 'c1',
        title: '隔週ミーティング',
        kind: EventKind.routine,
        startAt: jst(2026, 6, 29, 18),
        endAt: jst(2026, 6, 29, 20),
        recurrenceRule: const RecurrenceRule(
          frequency: RecurrenceFrequency.weekly,
          interval: 2,
          byWeekdays: [DateTime.monday],
          count: 3,
        ),
      );

      final starts = expander
          .expand(
            event: event,
            rangeStart: jst(2026, 6, 1),
            rangeEnd: jst(2026, 8, 1),
          )
          .map((o) => o.startAt)
          .toList();

      expect(starts, [
        jst(2026, 6, 29, 18),
        jst(2026, 7, 13, 18),
        jst(2026, 7, 27, 18),
      ]);
    });

    test('expands nth weekday monthly recurrence', () {
      final event = ScheduleEvent(
        id: 'lab',
        ownerUserId: 'u1',
        calendarId: 'c1',
        title: '第2火曜研究会',
        kind: EventKind.routine,
        startAt: jst(2026, 7, 14, 15),
        endAt: jst(2026, 7, 14, 16),
        recurrenceRule: const RecurrenceRule(
          frequency: RecurrenceFrequency.nthWeekday,
          nth: 2,
          weekday: DateTime.tuesday,
          count: 2,
        ),
      );

      final starts = expander
          .expand(
            event: event,
            rangeStart: jst(2026, 7, 1),
            rangeEnd: jst(2026, 9, 1),
          )
          .map((o) => o.startAt)
          .toList();

      expect(starts, [
        jst(2026, 7, 14, 15),
        jst(2026, 8, 11, 15),
      ]);
    });

    test('skips months without the requested fifth weekday', () {
      final event = ScheduleEvent(
        id: 'fifth-friday',
        ownerUserId: 'u1',
        calendarId: 'c1',
        title: '第5金曜',
        kind: EventKind.routine,
        startAt: jst(2026, 7, 31, 15, 30),
        endAt: jst(2026, 7, 31, 16, 30),
        recurrenceRule: const RecurrenceRule(
          frequency: RecurrenceFrequency.nthWeekday,
          nth: 5,
          weekday: DateTime.friday,
          count: 3,
        ),
      );

      final starts = expander
          .expand(
            event: event,
            rangeStart: jst(2026, 7, 1),
            rangeEnd: jst(2027, 2, 1),
          )
          .map((occurrence) => occurrence.startAt)
          .toList();

      // August, September, November, and December have no fifth Friday. They
      // must not roll forward to another month or consume the count.
      expect(starts, [
        jst(2026, 7, 31, 15, 30),
        jst(2026, 10, 30, 15, 30),
        jst(2027, 1, 29, 15, 30),
      ]);
    });

    test('weekday-only count advances over weekends without consuming them',
        () {
      final event = ScheduleEvent(
        id: 'weekday-count',
        ownerUserId: 'u1',
        calendarId: 'c1',
        title: '平日ルーティン',
        kind: EventKind.routine,
        startAt: jst(2026, 7, 3, 9), // Friday
        endAt: jst(2026, 7, 3, 10),
        recurrenceRule: const RecurrenceRule(
          frequency: RecurrenceFrequency.weekdays,
          count: 3,
        ),
      );

      final starts = expander
          .expand(
            event: event,
            rangeStart: jst(2026, 7, 1),
            rangeEnd: jst(2026, 7, 10),
          )
          .map((occurrence) => occurrence.startAt)
          .toList();

      expect(starts, [
        jst(2026, 7, 3, 9),
        jst(2026, 7, 6, 9),
        jst(2026, 7, 7, 9),
      ]);
    });

    test('keeps Japan civil time when the UTC range ends before fake midnight',
        () {
      final event = ScheduleEvent(
        id: 'boundary',
        ownerUserId: 'u1',
        calendarId: 'c1',
        title: '月曜朝会',
        kind: EventKind.routine,
        startAt: jst(2026, 7, 6, 0, 30),
        endAt: jst(2026, 7, 6, 1, 0),
        recurrenceRule: const RecurrenceRule(
          frequency: RecurrenceFrequency.weekly,
          byWeekdays: [DateTime.monday],
        ),
      );

      final occurrences = expander.expand(
        event: event,
        rangeStart: jst(2026, 7, 5, 0),
        rangeEnd: jst(2026, 7, 6, 3),
      );

      expect(occurrences.single.startAt, jst(2026, 7, 6, 0, 30));
      expect(occurrences.single.startAt, DateTime.utc(2026, 7, 5, 15, 30));
    });

    test('fails closed for an unsupported event timezone', () {
      final event = ScheduleEvent(
        id: 'unsupported-zone',
        ownerUserId: 'u1',
        calendarId: 'c1',
        title: 'UTC group routine',
        kind: EventKind.routine,
        startAt: DateTime.utc(2026, 7, 5, 23),
        endAt: DateTime.utc(2026, 7, 6),
        timezone: 'UTC',
        recurrenceRule: const RecurrenceRule(
          frequency: RecurrenceFrequency.weekly,
          byWeekdays: [DateTime.sunday],
        ),
      );

      expect(
        () => expander.expand(
          event: event,
          rangeStart: DateTime.utc(2026, 7, 1),
          rangeEnd: DateTime.utc(2026, 8, 1),
        ),
        throwsArgumentError,
      );
    });
  });
}
