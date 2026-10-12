import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/spatial_week/application/spatial_week_projection.dart';
import 'package:university_schedule_mobile/features/spatial_week/domain/spatial_week_models.dart';
import 'package:university_schedule_mobile/features/timetable/application/demo_app_controller.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';

void main() {
  const context = ActiveScheduleContext(
    ownerUserId: 'owner',
    universityId: 'uni',
    termId: 'term',
    academicYear: 2026,
    primaryCalendarId: 'personal',
  );

  test('context key preserves every selector without delimiter collisions', () {
    const first = ActiveScheduleContext(
      ownerUserId: 'owner|uni',
      universityId: 'term',
      termId: 'year',
      academicYear: 2026,
      primaryCalendarId: 'calendar',
    );
    const second = ActiveScheduleContext(
      ownerUserId: 'owner',
      universityId: 'uni|term',
      termId: 'year',
      academicYear: 2026,
      primaryCalendarId: 'calendar',
    );

    expect(spatialContextKey(first), isNot(spatialContextKey(second)));
    expect(spatialContextKey(context), contains('personal'));
  });

  test(
      'projects owner-scoped week occurrences, exceptions, and point deadlines',
      () {
    final monday = JapanTime.at(year: 2026, month: 5, day: 4);
    final weekEventStart = JapanTime.at(year: 2026, month: 5, day: 4, hour: 9);
    final routine = ScheduleEvent(
      id: 'routine',
      ownerUserId: 'owner',
      calendarId: 'personal',
      title: 'Study',
      kind: EventKind.routine,
      startAt: JapanTime.at(year: 2026, month: 4, day: 27, hour: 9),
      endAt: JapanTime.at(year: 2026, month: 4, day: 27, hour: 10),
      recurrenceRule:
          const RecurrenceRule(frequency: RecurrenceFrequency.weekly),
    );
    final cancelledRoutine = ScheduleEvent(
      id: 'cancelled-routine',
      ownerUserId: 'owner',
      calendarId: 'personal',
      title: 'Cancelled',
      kind: EventKind.routine,
      startAt: routine.startAt,
      endAt: routine.endAt,
      recurrenceRule:
          const RecurrenceRule(frequency: RecurrenceFrequency.weekly),
    );
    final crossMidnight = ScheduleEvent(
      id: 'overnight',
      ownerUserId: 'owner',
      calendarId: 'personal',
      title: 'Overnight',
      kind: EventKind.normal,
      startAt: JapanTime.at(year: 2026, month: 5, day: 5, hour: 23, minute: 30),
      endAt: JapanTime.at(year: 2026, month: 5, day: 6, minute: 30),
    );
    final allDay = ScheduleEvent(
      id: 'all-day',
      ownerUserId: 'owner',
      calendarId: 'personal',
      title: 'Holiday',
      kind: EventKind.normal,
      startAt: JapanTime.at(year: 2026, month: 5, day: 7),
      endAt: JapanTime.at(year: 2026, month: 5, day: 8),
      isAllDay: true,
    );
    final state = _state(monday).copyWith(
      courses: [
        _course('monday-course', weekday: DateTime.monday, period: 1),
        _course('friday-course', weekday: DateTime.friday, period: 1),
        _course('unknown-day', weekday: 9, period: 1),
        _course('missing-clock', weekday: DateTime.wednesday, period: 8),
        _course('invalid-clock', weekday: DateTime.tuesday, period: 2),
        _course('foreign-course', owner: 'other'),
        _course('old-term-course', term: 'old-term'),
      ],
      periodSettings: [
        _period('mon-1', DateTime.monday, 1, 600, 650),
        _period('fri-1', DateTime.friday, 1, 480, 550),
        _period('bad-clock', DateTime.tuesday, 2, 700, 650),
        _period('other-owner', DateTime.wednesday, 8, 300, 360, owner: 'other'),
      ],
      assignments: [
        _assignment('deadline',
            dueAt: JapanTime.at(
                year: 2026, month: 5, day: 6, hour: 14, minute: 7)),
        _assignment('active-course-deadline',
            courseId: 'monday-course',
            dueAt: JapanTime.at(year: 2026, month: 5, day: 8, hour: 16)),
        _assignment('submitted-deadline',
            dueAt: JapanTime.at(year: 2026, month: 5, day: 7, hour: 12)),
        _assignment('foreign-deadline',
            owner: 'other',
            dueAt: JapanTime.at(year: 2026, month: 5, day: 7, hour: 12)),
        _assignment('inactive-course-deadline',
            courseId: 'old-term-course',
            dueAt: JapanTime.at(year: 2026, month: 5, day: 7, hour: 12)),
      ],
      assignmentStates: {
        'submitted-deadline': const AssignmentUserState(
          assignmentId: 'submitted-deadline',
          userId: 'owner',
          status: AssignmentStatus.submitted,
        ),
        // A stale state from another user cannot hide the owner's deadline.
        'deadline': const AssignmentUserState(
          assignmentId: 'deadline',
          userId: 'other',
          status: AssignmentStatus.submitted,
        ),
      },
      exams: [
        _exam('exam', courseId: 'monday-course'),
        _exam('foreign-exam', owner: 'other'),
        _exam('inactive-course-exam', courseId: 'old-term-course'),
      ],
      events: [
        routine,
        cancelledRoutine,
        crossMidnight,
        allDay,
        _event('other-calendar', calendar: 'shared'),
        _event('group-event', group: 'group'),
        _event('foreign-event', owner: 'other'),
      ],
      eventExceptions: [
        EventException(
          id: 'modify-routine',
          eventId: routine.id,
          recurrenceId: weekEventStart,
          mode: EventExceptionMode.modified,
          overrideStartAt: JapanTime.at(year: 2026, month: 5, day: 5, hour: 11),
          overrideEndAt: JapanTime.at(year: 2026, month: 5, day: 5, hour: 12),
          overrideTitle: 'Moved study',
        ),
        EventException(
          id: 'cancel-routine',
          eventId: cancelledRoutine.id,
          recurrenceId: weekEventStart,
          mode: EventExceptionMode.cancelled,
        ),
        EventException(
          id: 'foreign-exception',
          eventId: 'foreign-event',
          recurrenceId: weekEventStart,
          mode: EventExceptionMode.modified,
          overrideTitle: 'Leak check',
        ),
      ],
    );

    // Sunday 16:00 UTC is Monday 01:00 in Japan. Week identity must follow JST.
    final snapshot = buildSpatialWeekSnapshot(
      state: state,
      context: context,
      now: DateTime.utc(2026, 5, 3, 16),
    );
    final byId = {for (final entry in snapshot.entries) entry.sourceId: entry};

    expect(snapshot.weekStart, DateTime.utc(2026, 5, 3, 15));
    expect(
        byId.keys,
        containsAll([
          'monday-course',
          'friday-course',
          'unknown-day',
          'missing-clock',
          'invalid-clock',
          'deadline',
          'active-course-deadline',
          'exam',
          'routine',
          'overnight',
          'all-day',
        ]));
    expect(byId.keys, isNot(contains('submitted-deadline')));
    expect(byId.keys, isNot(contains('foreign-deadline')));
    expect(byId.keys, isNot(contains('inactive-course-deadline')));
    expect(byId.keys, isNot(contains('foreign-exam')));
    expect(byId.keys, isNot(contains('inactive-course-exam')));
    expect(byId.keys, isNot(contains('cancelled-routine')));
    expect(byId.keys, isNot(contains('other-calendar')));
    expect(byId.keys, isNot(contains('group-event')));
    expect(byId.keys, isNot(contains('foreign-event')));

    expect(byId['monday-course']!.segments.single.startMinute, 600);
    expect(byId['friday-course']!.segments.single.dayIndex, 4);
    expect(byId['friday-course']!.segments.single.startMinute, 480);
    expect(byId['unknown-day']!.startAt, isNull);
    expect(byId['unknown-day']!.unplacedReason, 'unknown_weekday');
    expect(byId['missing-clock']!.segments, isEmpty);
    expect(byId['missing-clock']!.unplacedReason, 'missing_period_time');
    expect(byId['invalid-clock']!.startAt, isNull);
    expect(byId['invalid-clock']!.unplacedReason, 'invalid_period_time');
    expect(byId['routine']!.title, 'Moved study');
    expect(byId['routine']!.kind, SpatialEntryKind.routine);
    expect(byId['routine']!.startAt,
        JapanTime.at(year: 2026, month: 5, day: 5, hour: 11));

    final overnightSegments = byId['overnight']!.segments;
    expect(overnightSegments, hasLength(2));
    expect(overnightSegments[0].dayIndex, 1);
    expect(overnightSegments[0].startMinute, 1410);
    expect(overnightSegments[0].endMinute, 1440);
    expect(overnightSegments[1].dayIndex, 2);
    expect(overnightSegments[1].startMinute, 0);
    expect(overnightSegments[1].endMinute, 30);

    final allDayEntry = byId['all-day']!;
    expect(allDayEntry.isAllDay, isTrue);
    expect(allDayEntry.segments, isEmpty);
    expect(allDayEntry.unplacedReason, 'all_day');
    final deadline = byId['deadline']!;
    expect(deadline.startAt,
        JapanTime.at(year: 2026, month: 5, day: 6, hour: 14, minute: 7));
    expect(deadline.endAt, deadline.startAt);
    expect(deadline.segments.single.startMinute, 847);
    expect(deadline.segments.single.endMinute, 847);
    expect(snapshot.entries, isA<List<SpatialWeekEntry>>());
    expect(() => snapshot.entries.add(deadline), throwsUnsupportedError);
    expect(
        () => deadline.segments.add(const SpatialWeekSegment(
            dayIndex: 0, startMinute: 1, endMinute: 2)),
        throwsUnsupportedError);
  });
}

DemoAppState _state(DateTime now) => DemoAppState.empty(now: now);

UserCourse _course(
  String id, {
  int weekday = DateTime.monday,
  int? period = 1,
  String owner = 'owner',
  String term = 'term',
}) =>
    UserCourse(
      id: id,
      ownerUserId: owner,
      termId: term,
      title: id,
      normalizedTitle: id,
      dayOfWeek: weekday,
      periodNo: period,
    );

PeriodSetting _period(
  String id,
  int weekday,
  int period,
  int start,
  int end, {
  String owner = 'owner',
}) =>
    PeriodSetting(
      id: id,
      ownerUserId: owner,
      dayOfWeek: weekday,
      periodNo: period,
      startTimeMinutes: start,
      endTimeMinutes: end,
    );

Assignment _assignment(
  String id, {
  required DateTime dueAt,
  String? courseId,
  String owner = 'owner',
}) =>
    Assignment(
      id: id,
      ownerUserId: owner,
      title: id,
      dueAt: dueAt,
      courseId: courseId,
    );

Exam _exam(String id, {String? courseId, String owner = 'owner'}) => Exam(
      id: id,
      ownerUserId: owner,
      title: id,
      startAt: JapanTime.at(year: 2026, month: 5, day: 8, hour: 10),
      endAt: JapanTime.at(year: 2026, month: 5, day: 8, hour: 11),
      courseId: courseId,
    );

ScheduleEvent _event(
  String id, {
  String owner = 'owner',
  String calendar = 'personal',
  String? group,
}) =>
    ScheduleEvent(
      id: id,
      ownerUserId: owner,
      calendarId: calendar,
      title: id,
      kind: EventKind.normal,
      startAt: JapanTime.at(year: 2026, month: 5, day: 8, hour: 13),
      endAt: JapanTime.at(year: 2026, month: 5, day: 8, hour: 14),
      groupId: group,
    );
