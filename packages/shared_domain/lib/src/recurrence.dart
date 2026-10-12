import 'enums.dart';
import 'japan_time.dart';
import 'models.dart';

class EventOccurrence {
  const EventOccurrence({
    required this.eventId,
    required this.recurrenceId,
    required this.startAt,
    required this.endAt,
    required this.title,
    this.isAllDay = false,
    this.location,
    this.description,
    this.visibilityLevel = VisibilityLevel.private,
  });

  final String eventId;
  final DateTime recurrenceId;
  final DateTime startAt;
  final DateTime endAt;
  final String title;
  final bool isAllDay;
  final String? location;
  final String? description;
  final VisibilityLevel? visibilityLevel;
}

class RecurrenceExpander {
  List<EventOccurrence> expand({
    required ScheduleEvent event,
    required DateTime rangeStart,
    required DateTime rangeEnd,
    Iterable<EventException> exceptions = const [],
  }) {
    if (!JapanTime.isSupportedTimeZone(event.timezone)) {
      throw ArgumentError.value(
        event.timezone,
        'event.timezone',
        'Phase 4 recurrence supports only Asia/Tokyo events.',
      );
    }
    final normalizedRangeStart = rangeStart.toUtc();
    final normalizedRangeEnd = rangeEnd.toUtc();
    final rule = event.recurrenceRule;
    final candidates =
        rule == null || rule.frequency == RecurrenceFrequency.none
            ? [event.startAt.toUtc()]
            : _candidateStarts(
                event,
                rule,
                normalizedRangeStart,
                normalizedRangeEnd,
              );

    final exceptionByRecurrenceId = {
      for (final exception in exceptions.where((e) => e.eventId == event.id))
        _key(exception.recurrenceId): exception,
    };

    final occurrences = <EventOccurrence>[];
    for (final recurrenceStart in candidates) {
      final exception = exceptionByRecurrenceId[_key(recurrenceStart)];
      if (exception?.mode == EventExceptionMode.cancelled) continue;

      final startAt = (exception?.overrideStartAt ?? recurrenceStart).toUtc();
      final endAt =
          (exception?.overrideEndAt ?? startAt.add(event.duration)).toUtc();
      if (!startAt.isBefore(normalizedRangeEnd) ||
          !endAt.isAfter(normalizedRangeStart)) {
        continue;
      }

      occurrences.add(
        EventOccurrence(
          eventId: event.id,
          recurrenceId: recurrenceStart,
          startAt: startAt,
          endAt: endAt,
          title: exception?.overrideTitle ?? event.title,
          isAllDay: event.isAllDay,
          location: exception?.overrideLocation ?? event.location,
          description: exception?.overrideDescription ?? event.description,
          visibilityLevel:
              exception?.overrideVisibility ?? event.visibilityLevel,
        ),
      );
    }

    occurrences.sort((a, b) => a.startAt.compareTo(b.startAt));
    return occurrences;
  }

  List<DateTime> _candidateStarts(
    ScheduleEvent event,
    RecurrenceRule rule,
    DateTime rangeStart,
    DateTime rangeEnd,
  ) {
    return switch (rule.frequency) {
      RecurrenceFrequency.daily =>
        _daily(event.startAt.toUtc(), rule, rangeEnd),
      RecurrenceFrequency.weekly =>
        _weekly(event.startAt.toUtc(), rule, rangeEnd),
      RecurrenceFrequency.monthly =>
        _monthly(event.startAt.toUtc(), rule, rangeEnd),
      RecurrenceFrequency.nthWeekday =>
        _nthWeekday(event.startAt.toUtc(), rule, rangeEnd),
      RecurrenceFrequency.weekdays =>
        _weekdays(event.startAt.toUtc(), rule, rangeEnd),
      RecurrenceFrequency.none => [event.startAt.toUtc()],
    }
        .where((start) =>
            start.add(event.duration).isAfter(rangeStart) &&
            start.isBefore(rangeEnd))
        .toList();
  }

  Iterable<DateTime> _daily(
      DateTime start, RecurrenceRule rule, DateTime rangeEnd) sync* {
    var current = start;
    var emitted = 0;
    while (_canEmit(current, rule, rangeEnd, emitted)) {
      yield current;
      emitted++;
      current = current.add(Duration(days: rule.interval));
    }
  }

  Iterable<DateTime> _weekly(
      DateTime start, RecurrenceRule rule, DateTime rangeEnd) sync* {
    final startCivil = JapanTime.civil(start);
    final weekdays = [
      ...(rule.byWeekdays.isEmpty ? [startCivil.weekday] : rule.byWeekdays)
    ]..sort();
    var weekStart =
        DateTime.utc(startCivil.year, startCivil.month, startCivil.day)
            .subtract(Duration(days: startCivil.weekday - 1));
    var emitted = 0;
    while (true) {
      for (final weekday in weekdays) {
        final candidate = JapanTime.at(
          year: weekStart.year,
          month: weekStart.month,
          day: weekStart.day + weekday - 1,
          hour: startCivil.hour,
          minute: startCivil.minute,
          second: startCivil.second,
          millisecond: startCivil.millisecond,
          microsecond: startCivil.microsecond,
        );
        if (candidate.isBefore(start)) continue;
        if (!candidate.isBefore(rangeEnd)) return;
        if (!_canEmit(candidate, rule, rangeEnd, emitted)) return;
        yield candidate;
        emitted++;
      }
      weekStart = weekStart.add(Duration(days: 7 * rule.interval));
    }
  }

  Iterable<DateTime> _monthly(
      DateTime start, RecurrenceRule rule, DateTime rangeEnd) sync* {
    final startCivil = JapanTime.civil(start);
    var monthOffset = 0;
    var emitted = 0;
    while (true) {
      final candidate = _addMonths(
        startCivil,
        monthOffset,
        day: rule.monthDay ?? startCivil.day,
      );
      if (!_canEmit(candidate, rule, rangeEnd, emitted)) break;
      if (!candidate.isBefore(start)) {
        yield candidate;
        emitted++;
      }
      monthOffset += rule.interval;
    }
  }

  Iterable<DateTime> _nthWeekday(
      DateTime start, RecurrenceRule rule, DateTime rangeEnd) sync* {
    final startCivil = JapanTime.civil(start);
    final nth = rule.nth ?? ((startCivil.day - 1) ~/ 7 + 1);
    final weekday = rule.weekday ?? startCivil.weekday;
    var monthOffset = 0;
    var emitted = 0;
    while (true) {
      final anchor = DateTime.utc(
        startCivil.year,
        startCivil.month + monthOffset,
        1,
      );
      final monthStart = JapanTime.at(
        year: anchor.year,
        month: anchor.month,
        day: 1,
      );
      if (!monthStart.isBefore(rangeEnd)) return;

      final candidate = _nthWeekdayOfMonth(
          anchor.year, anchor.month, nth, weekday, startCivil);
      if (candidate != null) {
        if (!_canEmit(candidate, rule, rangeEnd, emitted)) return;
        if (!candidate.isBefore(start)) {
          yield candidate;
          emitted++;
        }
      }
      monthOffset += rule.interval;
    }
  }

  Iterable<DateTime> _weekdays(
      DateTime start, RecurrenceRule rule, DateTime rangeEnd) sync* {
    var current = start;
    var emitted = 0;
    while (_canEmit(current, rule, rangeEnd, emitted)) {
      final civil = JapanTime.civil(current);
      if (civil.weekday >= DateTime.monday &&
          civil.weekday <= DateTime.friday) {
        yield current;
        emitted++;
      }
      current = current.add(const Duration(days: 1));
    }
  }

  bool _canEmit(
      DateTime candidate, RecurrenceRule rule, DateTime rangeEnd, int emitted) {
    if (!candidate.isBefore(rangeEnd)) return false;
    if (rule.until != null && candidate.isAfter(rule.until!.toUtc())) {
      return false;
    }
    if (rule.count != null && emitted >= rule.count!) return false;
    return true;
  }

  DateTime _addMonths(
    JapanCivilDateTime start,
    int monthOffset, {
    required int day,
  }) {
    final first = DateTime.utc(
      start.year,
      start.month + monthOffset,
      1,
      start.hour,
      start.minute,
    );
    final lastDay = DateTime.utc(first.year, first.month + 1, 0).day;
    return JapanTime.at(
      year: first.year,
      month: first.month,
      day: day > lastDay ? lastDay : day,
      hour: start.hour,
      minute: start.minute,
      second: start.second,
      millisecond: start.millisecond,
      microsecond: start.microsecond,
    );
  }

  DateTime? _nthWeekdayOfMonth(
      int year, int month, int nth, int weekday, JapanCivilDateTime template) {
    if (nth < 1 ||
        nth > 5 ||
        weekday < DateTime.monday ||
        weekday > DateTime.sunday) {
      return null;
    }
    final first = DateTime.utc(year, month, 1);
    final offset = (weekday - first.weekday + 7) % 7;
    final day = 1 + offset + 7 * (nth - 1);
    if (day > DateTime.utc(year, month + 1, 0).day) return null;
    return JapanTime.at(
      year: year,
      month: month,
      day: day,
      hour: template.hour,
      minute: template.minute,
      second: template.second,
      millisecond: template.millisecond,
      microsecond: template.microsecond,
    );
  }

  String _key(DateTime value) => value.toUtc().toIso8601String();
}
