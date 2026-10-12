import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/today/application/today_briefing_provider.dart';
import 'package:university_schedule_mobile/features/today/domain/today_briefing.dart';

DateTime _jst(
  int year,
  int month,
  int day, [
  int hour = 0,
  int minute = 0,
  int second = 0,
  int millisecond = 0,
]) {
  return JapanTime.at(
    year: year,
    month: month,
    day: day,
    hour: hour,
    minute: minute,
    second: second,
    millisecond: millisecond,
  );
}

void main() {
  final service = TodayBriefingService();

  test('JSTの当日項目を全種別から集約し提出済みを除外する', () {
    final now = DateTime.utc(2026, 8, 10, 1); // 2026-08-10 10:00 JST
    final briefing = service.build(
      now: now,
      courses: const [
        UserCourse(
          id: 'course-current',
          ownerUserId: 'owner',
          termId: 'term',
          title: '現在の授業',
          normalizedTitle: '現在の授業',
          dayOfWeek: DateTime.monday,
          periodNo: 1,
          room: 'A101',
        ),
        UserCourse(
          id: 'course-next',
          ownerUserId: 'owner',
          termId: 'term',
          title: '次の授業',
          normalizedTitle: '次の授業',
          dayOfWeek: DateTime.monday,
          periodNo: 2,
        ),
      ],
      periodSettings: const [
        PeriodSetting(
          id: 'period-1',
          ownerUserId: 'owner',
          dayOfWeek: DateTime.monday,
          periodNo: 1,
          startTimeMinutes: 9 * 60,
          endTimeMinutes: 10 * 60 + 30,
        ),
        PeriodSetting(
          id: 'period-2',
          ownerUserId: 'owner',
          dayOfWeek: DateTime.monday,
          periodNo: 2,
          startTimeMinutes: 10 * 60 + 40,
          endTimeMinutes: 12 * 60 + 10,
        ),
      ],
      assignments: [
        _assignment('due', '今日の課題', _jst(2026, 8, 10, 18)),
        _assignment('overdue', '期限超過', _jst(2026, 8, 9, 23, 59)),
        _assignment('overdue-today', '今日中の期限超過', _jst(2026, 8, 10, 9, 59)),
        _assignment('submitted', '提出済み', _jst(2026, 8, 10, 20)),
        _assignment('tomorrow', '明日の課題', _jst(2026, 8, 11, 9)),
      ],
      assignmentStates: {
        'submitted': AssignmentUserState(
          assignmentId: 'submitted',
          userId: 'owner',
          status: AssignmentStatus.submitted,
          submittedAt: _jst(2026, 8, 10, 8),
        ),
      },
      exams: [
        Exam(
          id: 'exam',
          ownerUserId: 'owner',
          title: '今日の試験',
          startAt: _jst(2026, 8, 10, 15),
          endAt: _jst(2026, 8, 10, 16),
        ),
      ],
      events: [
        ScheduleEvent(
          id: 'personal',
          ownerUserId: 'owner',
          calendarId: 'calendar',
          title: '個人予定',
          kind: EventKind.normal,
          startAt: _jst(2026, 8, 10, 12),
          endAt: _jst(2026, 8, 10, 13),
        ),
        ScheduleEvent(
          id: 'all-day',
          ownerUserId: 'owner',
          calendarId: 'calendar',
          title: '終日予定',
          kind: EventKind.normal,
          startAt: _jst(2026, 8, 10),
          endAt: _jst(2026, 8, 11),
          isAllDay: true,
        ),
        ScheduleEvent(
          id: 'routine',
          ownerUserId: 'owner',
          calendarId: 'calendar',
          title: '通常のルーティン名',
          kind: EventKind.routine,
          startAt: _jst(2026, 8, 3, 7),
          endAt: _jst(2026, 8, 3, 8),
          recurrenceRule: const RecurrenceRule(
            frequency: RecurrenceFrequency.weekly,
            byWeekdays: [DateTime.monday],
            count: 4,
          ),
        ),
        ScheduleEvent(
          id: 'cancelled-routine',
          ownerUserId: 'owner',
          calendarId: 'calendar',
          title: '削除対象',
          kind: EventKind.routine,
          startAt: _jst(2026, 8, 3, 8),
          endAt: _jst(2026, 8, 3, 9),
          recurrenceRule: const RecurrenceRule(
            frequency: RecurrenceFrequency.weekly,
            byWeekdays: [DateTime.monday],
            count: 4,
          ),
        ),
        ScheduleEvent(
          id: 'group',
          ownerUserId: 'owner',
          calendarId: 'calendar',
          title: '共有予定',
          kind: EventKind.group,
          startAt: _jst(2026, 8, 10, 19),
          endAt: _jst(2026, 8, 10, 20),
        ),
      ],
      eventExceptions: [
        EventException(
          id: 'override',
          eventId: 'routine',
          recurrenceId: _jst(2026, 8, 10, 7),
          mode: EventExceptionMode.modified,
          overrideStartAt: _jst(2026, 8, 10, 13),
          overrideEndAt: _jst(2026, 8, 10, 14),
          overrideTitle: '変更後ルーティン',
        ),
        EventException(
          id: 'cancel',
          eventId: 'cancelled-routine',
          recurrenceId: _jst(2026, 8, 10, 8),
          mode: EventExceptionMode.cancelled,
        ),
      ],
    );

    expect(JapanTime.civil(briefing.dayStart).day, 10);
    expect(briefing.courses.map((item) => item.sourceId), [
      'course-current',
      'course-next',
    ]);
    expect(briefing.currentCourse?.sourceId, 'course-current');
    expect(briefing.nextCourse?.sourceId, 'course-next');
    expect(
      briefing.dueTodayAssignments.map((item) => item.assignment.id),
      ['due'],
    );
    expect(
      briefing.overdueAssignments.map((item) => item.assignment.id),
      ['overdue', 'overdue-today'],
    );
    expect(
      briefing.overdueAssignments.every(
        (item) => item.effectiveStatus == AssignmentStatus.overdue,
      ),
      isTrue,
    );
    expect(briefing.exams.single.sourceId, 'exam');
    expect(
      briefing.personalEvents.map((item) => item.sourceId),
      ['all-day', 'personal'],
    );
    expect(briefing.personalEvents.first.isAllDay, isTrue);
    expect(briefing.routines.single.title, '変更後ルーティン');
    expect(
      briefing.routines.map((item) => item.sourceId),
      isNot(contains('cancelled-routine')),
    );
    expect(briefing.otherCalendarOccurrences.single.sourceId, 'group');
    expect(
      briefing.calendarOccurrences.map((item) => item.sourceId),
      containsAll(['due', 'exam', 'personal', 'routine', 'group']),
    );
  });

  test('23:59から00:00でJSTの日付と締切グループを切り替える', () {
    final assignments = [
      _assignment('day-one', '初日の課題', _jst(2026, 8, 10, 23, 59)),
      _assignment('day-two', '翌日の課題', _jst(2026, 8, 11, 0, 30)),
    ];

    final beforeMidnight = service.build(
      now: _jst(2026, 8, 10, 23, 59),
      assignments: assignments,
    );
    final afterMidnight = service.build(
      now: _jst(2026, 8, 11),
      assignments: assignments,
    );

    expect(
      beforeMidnight.dueTodayAssignments.map((item) => item.assignment.id),
      ['day-one'],
    );
    expect(
      afterMidnight.dueTodayAssignments.map((item) => item.assignment.id),
      ['day-two'],
    );
    expect(
      afterMidnight.overdueAssignments.map((item) => item.assignment.id),
      ['day-one'],
    );
    expect(JapanTime.civil(afterMidnight.dayStart).day, 11);
  });

  test('授業の開始はinclusive、終了はexclusiveで現在と次を解決する', () {
    const course = UserCourse(
      id: 'course',
      ownerUserId: 'owner',
      termId: 'term',
      title: '境界授業',
      normalizedTitle: '境界授業',
      dayOfWeek: DateTime.monday,
      periodNo: 1,
    );
    const setting = PeriodSetting(
      id: 'period',
      ownerUserId: 'owner',
      dayOfWeek: DateTime.monday,
      periodNo: 1,
      startTimeMinutes: 9 * 60,
      endTimeMinutes: 10 * 60 + 30,
    );

    final atStart = service.build(
      now: _jst(2026, 8, 10, 9),
      courses: const [course],
      periodSettings: const [setting],
    );
    final atEnd = service.build(
      now: _jst(2026, 8, 10, 10, 30),
      courses: const [course],
      periodSettings: const [setting],
    );

    expect(atStart.currentCourse?.sourceId, 'course');
    expect(atStart.nextCourse, isNull);
    expect(atEnd.currentCourse, isNull);
    expect(atEnd.nextCourse, isNull);
  });

  test('次回refreshは分境界、JST 00:00直前でも遅延しない', () {
    expect(
      durationUntilNextTodayRefresh(_jst(2026, 8, 10, 23, 59, 59, 500)),
      const Duration(milliseconds: 500),
    );
  });
}

Assignment _assignment(String id, String title, DateTime dueAt) {
  return Assignment(
    id: id,
    ownerUserId: 'owner',
    title: title,
    dueAt: dueAt,
  );
}
