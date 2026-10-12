import 'package:shared_domain/shared_domain.dart';

class TodayAssignmentItem {
  const TodayAssignmentItem({
    required this.assignment,
    required this.effectiveStatus,
  });

  final Assignment assignment;
  final AssignmentStatus effectiveStatus;
}

class TodayBriefing {
  const TodayBriefing({
    required this.generatedAt,
    required this.dayStart,
    required this.dayEnd,
    required this.courses,
    required this.currentCourse,
    required this.nextCourse,
    required this.dueTodayAssignments,
    required this.overdueAssignments,
    required this.exams,
    required this.personalEvents,
    required this.routines,
    required this.otherCalendarOccurrences,
    required this.calendarOccurrences,
  });

  final DateTime generatedAt;
  final DateTime dayStart;
  final DateTime dayEnd;
  final List<CalendarProjectionItem> courses;
  final CalendarProjectionItem? currentCourse;
  final CalendarProjectionItem? nextCourse;
  final List<TodayAssignmentItem> dueTodayAssignments;
  final List<TodayAssignmentItem> overdueAssignments;
  final List<CalendarProjectionItem> exams;
  final List<CalendarProjectionItem> personalEvents;
  final List<CalendarProjectionItem> routines;
  final List<CalendarProjectionItem> otherCalendarOccurrences;
  final List<CalendarProjectionItem> calendarOccurrences;

  int get actionableCount =>
      courses.length +
      dueTodayAssignments.length +
      overdueAssignments.length +
      exams.length +
      personalEvents.length +
      routines.length +
      otherCalendarOccurrences.length;
}

/// Builds the one owner-local daily view consumed by Home, `/today`, and alarm
/// navigation. All inputs originate from the reactive Drift schedule snapshot;
/// this service never performs a network read.
class TodayBriefingService {
  TodayBriefingService({
    CalendarProjectionService? calendarProjectionService,
    AssignmentProjectionService? assignmentProjectionService,
    AssignmentStatusResolver? assignmentStatusResolver,
  })  : _calendarProjectionService =
            calendarProjectionService ?? CalendarProjectionService(),
        _assignmentProjectionService =
            assignmentProjectionService ?? AssignmentProjectionService(),
        _assignmentStatusResolver =
            assignmentStatusResolver ?? const AssignmentStatusResolver();

  final CalendarProjectionService _calendarProjectionService;
  final AssignmentProjectionService _assignmentProjectionService;
  final AssignmentStatusResolver _assignmentStatusResolver;

  TodayBriefing build({
    required DateTime now,
    Iterable<UserCourse> courses = const [],
    Iterable<PeriodSetting> periodSettings = const [],
    Iterable<Assignment> assignments = const [],
    Map<String, AssignmentUserState> assignmentStates = const {},
    Iterable<Exam> exams = const [],
    Iterable<ScheduleEvent> events = const [],
    Iterable<EventException> eventExceptions = const [],
  }) {
    final generatedAt = now.toUtc();
    final civil = JapanTime.civil(generatedAt);
    final dayStart = JapanTime.at(
      year: civil.year,
      month: civil.month,
      day: civil.day,
    );
    final dayEnd = JapanTime.at(
      year: civil.year,
      month: civil.month,
      day: civil.day + 1,
    );
    final occurrences = _calendarProjectionService.project(
      rangeStart: dayStart,
      rangeEnd: dayEnd,
      courses: courses,
      periodSettings: periodSettings,
      assignments: assignments,
      assignmentStates: assignmentStates,
      exams: exams,
      events: events,
      eventExceptions: eventExceptions,
    );

    final courseItems = _kind(occurrences, EventKind.course);
    final currentCourse = _firstWhereOrNull(
      courseItems,
      (item) =>
          !generatedAt.isBefore(item.startAt) &&
          generatedAt.isBefore(item.endAt),
    );
    final nextCourse = _firstWhereOrNull(
      courseItems,
      (item) => item.startAt.isAfter(generatedAt),
    );

    final assignmentsById = <String, Assignment>{
      for (final assignment in assignments) assignment.id: assignment,
    };
    final visibleAssignments = _assignmentProjectionService
        .projectDeadlines(assignments, assignmentStates)
        .map((item) => assignmentsById[item.assignmentId])
        .whereType<Assignment>()
        .map(
          (assignment) => TodayAssignmentItem(
            assignment: assignment,
            effectiveStatus: _assignmentStatusResolver.effectiveStatus(
              assignment: assignment,
              now: generatedAt,
              state: assignmentStates[assignment.id],
            ),
          ),
        )
        .toList()
      ..sort(
        (left, right) =>
            left.assignment.dueAt.compareTo(right.assignment.dueAt),
      );
    final dueToday = visibleAssignments
        .where(
          (item) =>
              item.effectiveStatus != AssignmentStatus.overdue &&
              !item.assignment.dueAt.isBefore(dayStart) &&
              item.assignment.dueAt.isBefore(dayEnd),
        )
        .toList(growable: false);
    final overdue = visibleAssignments
        .where(
          (item) => item.effectiveStatus == AssignmentStatus.overdue,
        )
        .toList(growable: false);

    return TodayBriefing(
      generatedAt: generatedAt,
      dayStart: dayStart,
      dayEnd: dayEnd,
      courses: List.unmodifiable(courseItems),
      currentCourse: currentCourse,
      nextCourse: nextCourse,
      dueTodayAssignments: List.unmodifiable(dueToday),
      overdueAssignments: List.unmodifiable(overdue),
      exams: List.unmodifiable(_kind(occurrences, EventKind.exam)),
      personalEvents: List.unmodifiable(_kind(occurrences, EventKind.normal)),
      routines: List.unmodifiable(_kind(occurrences, EventKind.routine)),
      otherCalendarOccurrences: List.unmodifiable(
        occurrences.where((item) => item.kind == EventKind.group),
      ),
      calendarOccurrences: List.unmodifiable(occurrences),
    );
  }

  List<CalendarProjectionItem> _kind(
    Iterable<CalendarProjectionItem> items,
    EventKind kind,
  ) {
    return items.where((item) => item.kind == kind).toList(growable: false);
  }

  T? _firstWhereOrNull<T>(Iterable<T> values, bool Function(T) predicate) {
    for (final value in values) {
      if (predicate(value)) return value;
    }
    return null;
  }
}
