import 'assignment_projection.dart';
import 'enums.dart';
import 'japan_time.dart';
import 'models.dart';
import 'recurrence.dart';

class CalendarProjectionItem {
  const CalendarProjectionItem({
    required this.sourceId,
    required this.kind,
    required this.title,
    required this.startAt,
    required this.endAt,
    this.isAllDay = false,
    this.courseId,
    this.location,
    this.visibilityLevel = VisibilityLevel.private,
  });

  final String sourceId;
  final EventKind kind;
  final String title;
  final DateTime startAt;
  final DateTime endAt;
  final bool isAllDay;
  final String? courseId;
  final String? location;
  final VisibilityLevel? visibilityLevel;
}

class CalendarProjectionService {
  CalendarProjectionService({
    AssignmentProjectionService? assignmentProjectionService,
    RecurrenceExpander? recurrenceExpander,
  })  : _assignmentProjectionService =
            assignmentProjectionService ?? AssignmentProjectionService(),
        _recurrenceExpander = recurrenceExpander ?? RecurrenceExpander();

  final AssignmentProjectionService _assignmentProjectionService;
  final RecurrenceExpander _recurrenceExpander;

  List<CalendarProjectionItem> project({
    required DateTime rangeStart,
    required DateTime rangeEnd,
    Iterable<UserCourse> courses = const [],
    Iterable<PeriodSetting> periodSettings = const [],
    Iterable<Assignment> assignments = const [],
    Map<String, AssignmentUserState> assignmentStates = const {},
    Iterable<Exam> exams = const [],
    Iterable<ScheduleEvent> events = const [],
    Iterable<EventException> eventExceptions = const [],
  }) {
    final normalizedRangeStart = rangeStart.toUtc();
    final normalizedRangeEnd = rangeEnd.toUtc();
    final items = [
      ..._projectCourses(
        courses: courses,
        periodSettings: periodSettings,
        rangeStart: normalizedRangeStart,
        rangeEnd: normalizedRangeEnd,
      ),
      ..._projectAssignments(assignments, assignmentStates),
      ..._projectExams(exams),
      ..._projectEvents(
        events: events,
        eventExceptions: eventExceptions,
        rangeStart: normalizedRangeStart,
        rangeEnd: normalizedRangeEnd,
      ),
    ]
        .where((item) => _overlaps(
              item.startAt,
              item.endAt,
              normalizedRangeStart,
              normalizedRangeEnd,
            ))
        .toList()
      ..sort((a, b) {
        final startCompare = a.startAt.compareTo(b.startAt);
        if (startCompare != 0) return startCompare;
        return a.title.compareTo(b.title);
      });

    return items;
  }

  Iterable<CalendarProjectionItem> _projectCourses({
    required Iterable<UserCourse> courses,
    required Iterable<PeriodSetting> periodSettings,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) sync* {
    final settingsBySlot = {
      for (final setting in periodSettings)
        '${setting.ownerUserId}:${setting.dayOfWeek}:${setting.periodNo}':
            setting,
    };

    for (final course in courses) {
      final weekday = course.dayOfWeek;
      final period = course.periodNo;
      if (weekday == null || period == null) continue;

      final periodSetting =
          settingsBySlot['${course.ownerUserId}:$weekday:$period'];
      if (periodSetting == null) continue;

      final rangeStartCivil = JapanTime.civil(rangeStart);
      final rangeEndCivil = JapanTime.civil(rangeEnd);
      var date = DateTime.utc(
        rangeStartCivil.year,
        rangeStartCivil.month,
        rangeStartCivil.day,
      );
      final rangeEndDate = DateTime.utc(
        rangeEndCivil.year,
        rangeEndCivil.month,
        rangeEndCivil.day,
      );
      final dayOffset = (weekday - date.weekday) % DateTime.daysPerWeek;
      date = date.add(Duration(days: dayOffset));
      while (date.isBefore(rangeEndDate)) {
        final startAt = _atMinutes(date, periodSetting.startTimeMinutes);
        final endAt = _atMinutes(date, periodSetting.endTimeMinutes);
        if (_overlaps(startAt, endAt, rangeStart, rangeEnd)) {
          yield CalendarProjectionItem(
            sourceId: course.id,
            kind: EventKind.course,
            title: course.title,
            startAt: startAt,
            endAt: endAt,
            courseId: course.id,
            location: course.room,
            visibilityLevel: course.visibilityLevel,
            isAllDay: false,
          );
        }
        date = date.add(const Duration(days: DateTime.daysPerWeek));
      }
    }
  }

  Iterable<CalendarProjectionItem> _projectAssignments(
    Iterable<Assignment> assignments,
    Map<String, AssignmentUserState> assignmentStates,
  ) {
    return _assignmentProjectionService
        .projectDeadlines(assignments, assignmentStates)
        .map(
          (assignment) => CalendarProjectionItem(
            sourceId: assignment.assignmentId,
            kind: EventKind.assignmentDeadline,
            title: assignment.title,
            startAt: assignment.dueAt,
            endAt: assignment.dueAt.add(const Duration(minutes: 15)),
            courseId: assignment.courseId,
            isAllDay: false,
          ),
        );
  }

  Iterable<CalendarProjectionItem> _projectExams(Iterable<Exam> exams) {
    return exams.map(
      (exam) => CalendarProjectionItem(
        sourceId: exam.id,
        kind: EventKind.exam,
        title: exam.title,
        startAt: exam.startAt,
        endAt: exam.endAt,
        courseId: exam.courseId,
        location: exam.room,
        visibilityLevel: exam.visibilityLevel,
        isAllDay: false,
      ),
    );
  }

  Iterable<CalendarProjectionItem> _projectEvents({
    required Iterable<ScheduleEvent> events,
    required Iterable<EventException> eventExceptions,
    required DateTime rangeStart,
    required DateTime rangeEnd,
  }) sync* {
    for (final event in events) {
      final occurrences = _recurrenceExpander.expand(
        event: event,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        exceptions: eventExceptions,
      );
      for (final occurrence in occurrences) {
        yield CalendarProjectionItem(
          sourceId: occurrence.eventId,
          kind: event.kind,
          title: occurrence.title,
          startAt: occurrence.startAt,
          endAt: occurrence.endAt,
          isAllDay: occurrence.isAllDay,
          location: occurrence.location,
          visibilityLevel: occurrence.visibilityLevel,
        );
      }
    }
  }

  DateTime _atMinutes(DateTime date, int minutesFromMidnight) {
    return JapanTime.at(
      year: date.year,
      month: date.month,
      day: date.day,
      hour: minutesFromMidnight ~/ 60,
      minute: minutesFromMidnight % 60,
    );
  }

  bool _overlaps(
    DateTime startAt,
    DateTime endAt,
    DateTime rangeStart,
    DateTime rangeEnd,
  ) {
    return startAt.isBefore(rangeEnd) && endAt.isAfter(rangeStart);
  }
}
