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
  test('calendar projection includes expected demo items', () {
    final service = CalendarProjectionService();
    final items = service.project(
      rangeStart: jst(2026, 6, 29),
      rangeEnd: jst(2026, 7, 14),
      courses: DemoData.userCourses,
      periodSettings: DemoData.periodSettings,
      assignments: DemoData.assignments,
      exams: DemoData.exams,
      events: DemoData.events,
    );

    expect(
      items.any(
        (item) =>
            item.kind == EventKind.course &&
            item.title == 'アルゴリズムとデータ構造Ⅰ' &&
            item.startAt == jst(2026, 6, 29, 10, 40),
      ),
      isTrue,
    );
    expect(
      items.any(
        (item) =>
            item.kind == EventKind.assignmentDeadline &&
            item.sourceId == 'assignment-report-1',
      ),
      isTrue,
    );
    expect(items.any((item) => item.kind == EventKind.exam), isTrue);
    expect(
      items.where((item) => item.kind == EventKind.routine),
      hasLength(3),
    );
  });

  test('submitted assignment is hidden from projection but remains in history',
      () {
    final submitted = DemoData.assignments.first;
    final state = AssignmentUserState(
      assignmentId: submitted.id,
      userId: submitted.ownerUserId,
    ).submit(DateTime(2026, 7, 1, 12));

    final items = CalendarProjectionService().project(
      rangeStart: jst(2026, 6, 29),
      rangeEnd: jst(2026, 7, 14),
      assignments: DemoData.assignments,
      assignmentStates: {submitted.id: state},
    );

    expect(
      items.any((item) => item.kind == EventKind.assignmentDeadline),
      isFalse,
    );
    expect(state.status, AssignmentStatus.submitted);
    expect(state.submittedAt, isNotNull);
  });

  test('all-day state survives recurrence projection', () {
    final items = CalendarProjectionService().project(
      rangeStart: jst(2026, 8, 10),
      rangeEnd: jst(2026, 8, 11),
      events: [
        ScheduleEvent(
          id: 'all-day',
          ownerUserId: 'owner',
          calendarId: 'calendar',
          title: '終日予定',
          kind: EventKind.normal,
          startAt: jst(2026, 8, 10),
          endAt: jst(2026, 8, 11),
          isAllDay: true,
        ),
      ],
    );

    expect(items.single.isAllDay, isTrue);
  });
}
