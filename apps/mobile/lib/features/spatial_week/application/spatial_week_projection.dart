import 'dart:convert';

import 'package:shared_domain/shared_domain.dart';

import '../../timetable/application/demo_app_controller.dart';
import '../../timetable/data/local_schedule_repository.dart';
import '../domain/spatial_week_models.dart';

/// Encodes every schedule selector as a JSON tuple so delimiters inside IDs
/// cannot make two distinct schedule contexts share cached screen state.
String spatialContextKey(ActiveScheduleContext context) => jsonEncode([
      context.ownerUserId,
      context.universityId,
      context.termId,
      context.academicYear,
      context.primaryCalendarId,
    ]);

/// Builds a read-only week snapshot from the currently loaded local models.
/// The event and course recurrence rules are delegated to the application's
/// calendar projection service; deadline markers are built here so their
/// point-in-time semantics are preserved.
SpatialWeekSnapshot buildSpatialWeekSnapshot({
  required DemoAppState state,
  required ActiveScheduleContext context,
  required DateTime now,
}) {
  final weekStart = JapanTime.startOfWeek(now).toUtc();
  final weekEnd = weekStart.add(const Duration(days: 7));
  final contextKey = spatialContextKey(context);
  final entries = <SpatialWeekEntry>[];

  final activeCourses = state.courses
      .where((course) =>
          course.ownerUserId == context.ownerUserId &&
          course.termId == context.termId)
      .toList(growable: false);
  final activeCourseIds = activeCourses.map((course) => course.id).toSet();

  final settingsBySlot = <String, PeriodSetting>{};
  for (final setting in state.periodSettings) {
    if (setting.ownerUserId == context.ownerUserId) {
      settingsBySlot.putIfAbsent(
        _slotKey(setting.dayOfWeek, setting.periodNo),
        () => setting,
      );
    }
  }

  final validCourses = <UserCourse>[];
  for (final course in activeCourses) {
    final weekday = course.dayOfWeek;
    final period = course.periodNo;
    if (weekday == null ||
        weekday < DateTime.monday ||
        weekday > DateTime.sunday) {
      entries.add(_unplacedCourse(course, 'unknown_weekday'));
      continue;
    }
    if (period == null || period < 1) {
      entries.add(_unplacedCourse(course, 'unknown_period'));
      continue;
    }
    final setting = settingsBySlot[_slotKey(weekday, period)];
    if (setting == null) {
      entries.add(_unplacedCourse(course, 'missing_period_time'));
      continue;
    }
    if (!_validClockInterval(
        setting.startTimeMinutes, setting.endTimeMinutes)) {
      entries.add(_unplacedCourse(course, 'invalid_period_time'));
      continue;
    }
    validCourses.add(course);
  }

  final assignments = state.assignments.where((assignment) {
    return assignment.ownerUserId == context.ownerUserId &&
        (assignment.courseId == null ||
            activeCourseIds.contains(assignment.courseId));
  }).toList(growable: false);
  final assignmentIds = assignments.map((assignment) => assignment.id).toSet();
  final validStates = <String, AssignmentUserState>{};
  for (final entry in state.assignmentStates.entries) {
    final value = entry.value;
    if (assignmentIds.contains(entry.key) &&
        value.assignmentId == entry.key &&
        value.userId == context.ownerUserId) {
      validStates[entry.key] = value;
    }
  }

  final exams = state.exams.where((exam) {
    return exam.ownerUserId == context.ownerUserId &&
        (exam.courseId == null || activeCourseIds.contains(exam.courseId));
  }).toList(growable: false);

  final personalEvents = state.events.where((event) {
    return event.ownerUserId == context.ownerUserId &&
        event.calendarId == context.primaryCalendarId &&
        event.groupId == null;
  }).toList(growable: false);
  final allowedEventIds = personalEvents.map((event) => event.id).toSet();
  final exceptions = state.eventExceptions
      .where((exception) => allowedEventIds.contains(exception.eventId))
      .toList(growable: false);

  final projection = CalendarProjectionService().project(
    rangeStart: weekStart,
    rangeEnd: weekEnd,
    courses: validCourses,
    periodSettings: settingsBySlot.values,
    assignments: const [],
    exams: exams.where((exam) => exam.endAt.isAfter(exam.startAt)),
    events: personalEvents.where((event) =>
        event.endAt.isAfter(event.startAt) &&
        JapanTime.isSupportedTimeZone(event.timezone)),
    eventExceptions: exceptions,
  );

  for (final item in projection) {
    final kind = switch (item.kind) {
      EventKind.course => SpatialEntryKind.course,
      EventKind.exam => SpatialEntryKind.exam,
      EventKind.routine => SpatialEntryKind.routine,
      _ => SpatialEntryKind.event,
    };
    final allDay = item.isAllDay;
    final segments = allDay
        ? const <SpatialWeekSegment>[]
        : _segmentsForInterval(item.startAt, item.endAt, weekStart, weekEnd);
    entries.add(SpatialWeekEntry(
      key: _occurrenceKey(kind.name, item.sourceId, item.startAt, item.endAt),
      sourceId: item.sourceId,
      kind: kind,
      title: item.title,
      detailRoute: _routeFor(kind, item.sourceId),
      segments: List.unmodifiable(segments),
      location: item.location,
      startAt: item.startAt.toUtc(),
      endAt: item.endAt.toUtc(),
      isAllDay: allDay,
      unplacedReason: allDay ? 'all_day' : null,
    ));
  }

  final assignmentProjection = AssignmentProjectionService();
  for (final assignment in assignmentProjection.projectDeadlines(
    assignments,
    validStates,
  )) {
    final dueAt = assignments
        .firstWhere((candidate) => candidate.id == assignment.assignmentId)
        .dueAt
        .toUtc();
    if (dueAt.isBefore(weekStart) || !dueAt.isBefore(weekEnd)) continue;
    final day = JapanTime.civil(dueAt);
    final dayIndex = (DateTime.utc(day.year, day.month, day.day)
            .difference(DateTime.utc(
              JapanTime.civil(weekStart).year,
              JapanTime.civil(weekStart).month,
              JapanTime.civil(weekStart).day,
            ))
            .inDays)
        .clamp(0, 6)
        .toInt();
    final minute = day.hour * 60 + day.minute;
    entries.add(SpatialWeekEntry(
      key: 'assignment:${assignment.assignmentId}:${dueAt.toIso8601String()}',
      sourceId: assignment.assignmentId,
      kind: SpatialEntryKind.assignment,
      title: assignment.title,
      detailRoute:
          _routeFor(SpatialEntryKind.assignment, assignment.assignmentId),
      segments: List.unmodifiable([
        SpatialWeekSegment(
          dayIndex: dayIndex,
          startMinute: minute,
          endMinute: minute,
        ),
      ]),
      startAt: dueAt,
      endAt: dueAt,
    ));
  }

  entries.sort((a, b) {
    final byStart = (a.startAt ?? weekStart).compareTo(b.startAt ?? weekStart);
    if (byStart != 0) return byStart;
    return a.key.compareTo(b.key);
  });
  return SpatialWeekSnapshot(
    contextKey: contextKey,
    weekStart: weekStart,
    entries: List.unmodifiable(entries),
  );
}

SpatialWeekEntry _unplacedCourse(UserCourse course, String reason) =>
    SpatialWeekEntry(
      key: 'course:${course.id}:unplaced',
      sourceId: course.id,
      kind: SpatialEntryKind.course,
      title: course.title,
      detailRoute: _routeFor(SpatialEntryKind.course, course.id),
      segments: const [],
      location: course.room,
      unplacedReason: reason,
    );

bool _validClockInterval(int start, int end) =>
    start >= 0 && start < 1440 && end > start && end <= 1440;

String _slotKey(int weekday, int period) => '$weekday:$period';

String _occurrenceKey(
  String kind,
  String sourceId,
  DateTime startAt,
  DateTime endAt,
) =>
    '$kind:$sourceId:${startAt.toUtc().toIso8601String()}:${endAt.toUtc().toIso8601String()}';

String _routeFor(SpatialEntryKind kind, String sourceId) {
  final id = Uri.encodeComponent(sourceId);
  return switch (kind) {
    SpatialEntryKind.course => '/course/$id',
    SpatialEntryKind.assignment => '/assignment/$id',
    SpatialEntryKind.exam => '/exam/$id',
    SpatialEntryKind.routine => '/routine/$id',
    SpatialEntryKind.event => '/event/$id',
  };
}

List<SpatialWeekSegment> _segmentsForInterval(
  DateTime startAt,
  DateTime endAt,
  DateTime weekStart,
  DateTime weekEnd,
) {
  final start =
      startAt.toUtc().isBefore(weekStart) ? weekStart : startAt.toUtc();
  final end = endAt.toUtc().isAfter(weekEnd) ? weekEnd : endAt.toUtc();
  if (!start.isBefore(end)) return const [];

  final mondayCivil = JapanTime.civil(weekStart);
  final mondayDate =
      DateTime.utc(mondayCivil.year, mondayCivil.month, mondayCivil.day);
  final segments = <SpatialWeekSegment>[];
  var cursor = start;
  while (cursor.isBefore(end)) {
    final civil = JapanTime.civil(cursor);
    final localMidnightNext = JapanTime.at(
      year: civil.year,
      month: civil.month,
      day: civil.day + 1,
    );
    final segmentEnd =
        localMidnightNext.isBefore(end) ? localMidnightNext : end;
    final segmentEndCivil = JapanTime.civil(segmentEnd);
    final dayDate = DateTime.utc(civil.year, civil.month, civil.day);
    final dayIndex = dayDate.difference(mondayDate).inDays;
    final startMinute = civil.hour * 60 + civil.minute;
    final endMinute = segmentEnd.isAtSameMomentAs(localMidnightNext)
        ? 1440
        : segmentEndCivil.hour * 60 + segmentEndCivil.minute;
    if (dayIndex >= 0 && dayIndex < 7) {
      segments.add(SpatialWeekSegment(
        dayIndex: dayIndex,
        startMinute: startMinute,
        endMinute: endMinute,
      ));
    }
    cursor = segmentEnd;
  }
  return segments;
}
