import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:shared_domain/shared_domain.dart' as domain;
import 'local_notification_models.dart';

class LocalNotificationPlanner {
  const LocalNotificationPlanner({this.horizon = const Duration(days: 45)});

  final Duration horizon;

  List<LocalNotificationPlan> plan({
    required String ownerUserId,
    required domain.CalendarProjectionService projectionService,
    required Iterable<domain.UserCourse> courses,
    required Iterable<domain.PeriodSetting> periodSettings,
    required Iterable<domain.Assignment> assignments,
    required Map<String, domain.AssignmentUserState> assignmentStates,
    required Iterable<domain.Exam> exams,
    required Iterable<domain.ScheduleEvent> events,
    required Iterable<domain.EventException> eventExceptions,
    required LocalNotificationSettingsValue settings,
    required DateTime now,
    required int sourceEpoch,
    required int projectionEpoch,
    DateTime? termStart,
    DateTime? termEnd,
    DateTime? instructionStart,
    DateTime? instructionEnd,
    Map<String, List<int>> importedReminderRules = const {},
  }) {
    if (!settings.enabled) return const [];
    final start = now.toUtc();
    final end = start.add(horizon);
    // Include future targets just outside the reservation window when their
    // configured lead time still falls inside that window (exam -7d is the
    // current maximum built-in lead).
    // The reservation horizon is measured by trigger time. Expand source
    // occurrences far enough to include every valid configured lead, while
    // keeping the final trigger cutoff exactly [end]. Imported rules are
    // canonical rows too, so a long negative offset must not hide a target
    // that belongs in the rolling window.
    final configuredLeads = <int>[
      7 * 24 * 60,
      -settings.courseReminderMinutes,
      -settings.assignmentReminderMinutes,
      -settings.examReminderMinutes,
      -settings.eventReminderMinutes,
      ...importedReminderRules.values
          .expand((values) => values.map((value) => -value)),
    ].where((value) => value > 0);
    final maxLeadMinutes = configuredLeads.isEmpty
        ? 0
        : configuredLeads.reduce((a, b) => a > b ? a : b);
    final projectionEnd = end.add(Duration(minutes: maxLeadMinutes));
    final eventList = events.toList(growable: false);
    final exceptionList = eventExceptions.toList(growable: false);
    final recurrenceIds = <String, List<String>>{};
    final expander = domain.RecurrenceExpander();
    for (final event in eventList) {
      for (final occurrence in expander.expand(
        event: event,
        rangeStart: start,
        rangeEnd: projectionEnd,
        exceptions: exceptionList,
      )) {
        recurrenceIds
            .putIfAbsent(
              '${event.id}|${occurrence.startAt.toUtc().toIso8601String()}',
              () => <String>[],
            )
            .add(occurrence.recurrenceId.toUtc().toIso8601String());
      }
    }
    final items = projectionService.project(
      rangeStart: start,
      rangeEnd: projectionEnd,
      courses: courses,
      periodSettings: periodSettings,
      assignments: assignments,
      assignmentStates: assignmentStates,
      exams: exams,
      events: eventList,
      eventExceptions: exceptionList,
    );
    final plans = <LocalNotificationPlan>[];
    final identityCounts = <String, int>{};
    for (final item in items) {
      // Group/shared events are not personal local reminders.  Their push
      // policy is handled by the shared/group flow.
      if (item.kind == domain.EventKind.group) continue;
      final kind = item.kind.notificationName;
      if (!_enabled(kind, settings)) continue;
      if (kind == 'course' &&
          !_withinCourseTerm(
            item.startAt,
            termStart: termStart,
            termEnd: termEnd,
            instructionStart: instructionStart,
            instructionEnd: instructionEnd,
          )) {
        continue;
      }
      final recurrenceKey =
          '${item.sourceId}|${item.startAt.toUtc().toIso8601String()}';
      // Resolve the source occurrence once.  A single occurrence may have
      // several reminder rules (including imported rules); consuming the
      // expander result inside the rule loop gives those rules different
      // identities and breaks differential OS reconciliation.
      final recurrence = recurrenceIds[recurrenceKey]?.isNotEmpty == true
          ? recurrenceIds[recurrenceKey]!.removeAt(0)
          : null;
      final imported = importedReminderRules[item.sourceId];
      final rules = <({String name, DateTime at})>[
        if (imported != null)
          ...imported.asMap().entries.map(
                (entry) => (
                  name: 'imported_${entry.key}',
                  at: item.startAt.add(Duration(minutes: entry.value)),
                ),
              )
        else if (kind == 'exam') ...[
          (
            name: 'exam_week',
            at: item.startAt
                .add(Duration(minutes: settings.examReminderMinutes))
          ),
          (
            name: 'exam_previous_day',
            at: _previousDayAt(item.startAt, 20),
          ),
          if (_sameDayMorning(item.startAt, settings) case final morning?)
            (name: 'exam_day_morning', at: morning),
        ] else if (kind == 'assignment') ...[
          (
            name: 'assignment_previous_day',
            at: _previousDayAt(item.startAt, 20)
          ),
          (
            name: 'assignment_due_reminder',
            at: item.startAt
                .add(Duration(minutes: settings.assignmentReminderMinutes))
          ),
        ] else ...[
          (
            name: '${kind}_reminder',
            at: item.startAt.add(Duration(minutes: _minutes(kind, settings)))
          ),
        ],
      ];
      for (final rule in rules) {
        if (!rule.at.isBefore(end)) continue;
        // Reminder offsets are before the target.  Treat malformed or
        // untrusted imported positive offsets as invalid rather than
        // scheduling a notification after the event has started.
        if (rule.at.isAfter(item.startAt)) continue;
        final past = !rule.at.isAfter(start);
        // Keep a future target whose trigger was missed while the app was
        // closed. Native keeps the delivered registry/notification stable;
        // this row is never newly scheduled.
        if (past && !item.startAt.isAfter(start)) continue;
        final quiet = _inQuietHours(rule.at, settings);
        final identity = _identity(
          ownerUserId,
          kind,
          recurrence == null ? item.sourceId : '${item.sourceId}#$recurrence',
          item.startAt,
          rule.name,
        );
        final duplicate = identityCounts.update(
          identity,
          (count) => count + 1,
          ifAbsent: () => 0,
        );
        final stableIdentity =
            duplicate == 0 ? identity : '$identity|$duplicate';
        final targetPath = _targetPath(kind, item.sourceId);
        final body = '${_label(kind)} · ${_jstLabel(item.startAt)}';
        final fingerprint = _fingerprint(
          stableIdentity,
          rule.at,
          item.title,
          body,
          targetPath,
        );
        plans.add(LocalNotificationPlan(
          id: 'local-${sha256.convert(utf8.encode(stableIdentity))}',
          ownerUserId: ownerUserId,
          kind: kind,
          sourceEntityId: item.sourceId,
          occurrenceAt: item.startAt,
          triggerAt: rule.at,
          targetPath: targetPath,
          title: item.title,
          body: body,
          rule: rule.name,
          fingerprint: fingerprint,
          sourceEpoch: sourceEpoch,
          projectionEpoch: projectionEpoch,
          reason: quiet
              ? 'quiet_hours'
              : past
                  ? 'past'
                  : 'eligible',
        ));
      }
    }
    plans.sort((a, b) => a.triggerAt.compareTo(b.triggerAt));
    return plans;
  }

  bool _enabled(String kind, LocalNotificationSettingsValue s) {
    switch (kind) {
      case 'course':
        return s.courseEnabled;
      case 'assignment':
        return s.assignmentEnabled;
      case 'exam':
        return s.examEnabled;
      case 'routine':
        return s.routineEnabled;
      case 'event':
        return s.eventEnabled && s.personalEnabled;
      default:
        return false;
    }
  }

  int _minutes(String kind, LocalNotificationSettingsValue s) {
    switch (kind) {
      case 'course':
        return s.courseReminderMinutes;
      case 'assignment':
        return s.assignmentReminderMinutes;
      case 'exam':
        return s.examReminderMinutes;
      default:
        return s.eventReminderMinutes;
    }
  }

  DateTime _previousDayAt(DateTime instant, int hour) {
    final c = domain.JapanTime.civil(instant);
    final previous =
        DateTime.utc(c.year, c.month, c.day).subtract(const Duration(days: 1));
    return domain.JapanTime.at(
        year: previous.year,
        month: previous.month,
        day: previous.day,
        hour: hour);
  }

  DateTime? _sameDayMorning(
    DateTime instant,
    LocalNotificationSettingsValue settings,
  ) {
    final c = domain.JapanTime.civil(instant);
    final target = domain.JapanTime.at(
        year: c.year,
        month: c.month,
        day: c.day,
        hour: settings.examDayHour,
        minute: settings.examDayMinute);
    return target.isBefore(instant) ? target : null;
  }

  bool _inQuietHours(DateTime instant, LocalNotificationSettingsValue s) {
    final start = s.quietStartMinutes;
    final end = s.quietEndMinutes;
    if (start == null || end == null || start == end) return false;
    final c = domain.JapanTime.civil(instant);
    final minute = c.hour * 60 + c.minute;
    return start < end
        ? minute >= start && minute < end
        : minute >= start || minute < end;
  }

  bool _withinCourseTerm(
    DateTime startAt, {
    DateTime? termStart,
    DateTime? termEnd,
    DateTime? instructionStart,
    DateTime? instructionEnd,
  }) {
    final lower = (instructionStart ?? termStart)?.toUtc();
    final upper = (instructionEnd ?? termEnd)?.toUtc();
    if (lower != null && startAt.toUtc().isBefore(lower)) return false;
    // Term dates are date-only in the source model.  Make the end inclusive
    // through the end of that civil day instead of dropping its final class.
    if (upper != null &&
        !startAt.toUtc().isBefore(upper.add(const Duration(days: 1)))) {
      return false;
    }
    return true;
  }

  String _targetPath(String kind, String id) => switch (kind) {
        'course' => '/course/$id',
        'assignment' => '/assignment/$id',
        'exam' => '/exam/$id',
        'routine' => '/routine/$id',
        _ => '/event/$id',
      };

  String _label(String kind) => switch (kind) {
        'course' => '授業',
        'assignment' => '課題',
        'exam' => '試験',
        'routine' => 'ルーティン',
        _ => '予定',
      };

  String _jstLabel(DateTime value) {
    final c = domain.JapanTime.civil(value);
    return '${c.month}/${c.day} ${c.hour.toString().padLeft(2, '0')}:${c.minute.toString().padLeft(2, '0')}';
  }

  String _identity(String owner, String kind, String source,
      DateTime occurrence, String rule) {
    return '$owner|$kind|$source|${occurrence.toUtc().toIso8601String()}|$rule';
  }

  String _fingerprint(String identity, DateTime triggerAt, String title,
      String body, String targetPath) {
    return sha256
        .convert(utf8.encode(
            '$identity|${triggerAt.toUtc().toIso8601String()}|$title|$body|$targetPath'))
        .toString();
  }
}
