import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart' as domain;

import 'package:university_schedule_mobile/features/notification/application/local_notification_projection.dart';
import 'package:university_schedule_mobile/features/notification/data/local_notification_readonly_snapshot.dart';
import 'package:university_schedule_mobile/features/notification/domain/local_notification_models.dart';

void main() {
  final now = DateTime.utc(2026, 9, 20, 9);

  test('counts distinct trigger buckets and keeps all same-time members', () {
    final distinct = _snapshot(
      now,
      exams: [
        for (var index = 0; index < 201; index++)
          _exam('distinct-$index', now.add(Duration(days: 1, minutes: index))),
      ],
    );
    final sameTime = _snapshot(
      now,
      exams: [
        for (var index = 0; index < 201; index++)
          _exam('same-$index', now.add(const Duration(days: 1)))
      ],
    );
    final computer = const LocalNotificationProjectionComputer();

    final distinctProjection = computer.compute(distinct, nowUtc: now);
    final sameProjection = computer.compute(sameTime, nowUtc: now);

    expect(distinctProjection.plans, hasLength(201));
    expect(distinctProjection.distinctTriggerBuckets, greaterThan(200));
    expect(distinctProjection.capped, isTrue);
    expect(sameProjection.plans, hasLength(201));
    expect(sameProjection.distinctTriggerBuckets, 1);
    expect(sameProjection.capped, isFalse);
  });

  test('uses an exclusive 45-day trigger cutoff', () {
    final snapshot = _snapshot(
      now,
      exams: const [],
      events: [_event('at-cutoff', now.add(const Duration(days: 45)))],
    );
    final projection = const LocalNotificationProjectionComputer().compute(
      snapshot,
      nowUtc: now,
    );
    expect(projection.plans, isEmpty);
  });

  test('an empty initial window refills a distant event as time advances', () {
    final distant = _event('distant', now.add(const Duration(days: 60)));
    final snapshot = _snapshot(now, exams: const [], events: [distant]);
    const computer = LocalNotificationProjectionComputer();
    expect(computer.compute(snapshot, nowUtc: now).plans, isEmpty);

    final advanced = now.add(const Duration(days: 20));
    final refill = computer.compute(snapshot, nowUtc: advanced);
    expect(refill.plans, hasLength(1));
    expect(refill.plans.single.sourceEntityId, distant.id);
    expect(refill.plans.single.triggerAt, distant.startAt);
    expect(refill.plans.single.eligible, isTrue);
    expect(refill.windowEnd, advanced.add(const Duration(days: 45)));
    expect(
      computer.compute(snapshot, nowUtc: advanced).plans.single.id,
      refill.plans.single.id,
    );
  });

  test(
      'refill expands new recurring instances and applies cancel/move exceptions',
      () {
    final first = now.add(const Duration(days: 46));
    final moved = first.add(const Duration(days: 3, hours: 3));
    final recurring = domain.ScheduleEvent(
      id: 'rolling-series',
      ownerUserId: 'owner',
      calendarId: 'calendar',
      title: 'Series',
      kind: domain.EventKind.normal,
      startAt: first,
      endAt: first.add(const Duration(hours: 1)),
      recurrenceRule: const domain.RecurrenceRule(
        frequency: domain.RecurrenceFrequency.daily,
        count: 4,
      ),
    );
    final snapshot = _snapshot(
      now,
      exams: const [],
      events: [recurring],
      exceptions: [
        domain.EventException(
            id: 'cancel',
            eventId: recurring.id,
            recurrenceId: first.add(const Duration(days: 1)),
            mode: domain.EventExceptionMode.cancelled),
        domain.EventException(
            id: 'move',
            eventId: recurring.id,
            recurrenceId: first.add(const Duration(days: 2)),
            mode: domain.EventExceptionMode.modified,
            overrideStartAt: moved,
            overrideEndAt: moved.add(const Duration(hours: 1))),
      ],
    );
    const computer = LocalNotificationProjectionComputer();
    expect(computer.compute(snapshot, nowUtc: now).plans, isEmpty);
    final refill =
        computer.compute(snapshot, nowUtc: now.add(const Duration(days: 5)));
    expect(
        refill.plans.map((p) => p.occurrenceAt),
        unorderedEquals([
          first,
          first.add(const Duration(days: 3)),
          moved,
        ]));
    expect(refill.plans.map((p) => p.id).toSet(), hasLength(3));
    expect(refill.plans.every((p) => p.eligible), isTrue);
  });

  test('long configured and imported leads expand targets beyond 45 days', () {
    final target = _event('long-lead', now.add(const Duration(days: 50)));
    const computer = LocalNotificationProjectionComputer();
    final configured = _snapshot(now,
        exams: const [],
        events: [target],
        settings:
            const LocalNotificationSettingsValue(eventReminderMinutes: -20160));
    final imported = _snapshot(now, exams: const [], events: [
      target
    ], importedRules: {
      'long-lead': const [-20160]
    });
    for (final snapshot in [configured, imported]) {
      final refill = computer.compute(snapshot, nowUtc: now);
      expect(refill.plans, hasLength(1));
      expect(refill.plans.single.triggerAt, now.add(const Duration(days: 36)));
      expect(refill.plans.single.eligible, isTrue);
    }
  });
}

LocalNotificationReadonlySnapshot _snapshot(
  DateTime now, {
  required List<domain.Exam> exams,
  List<domain.ScheduleEvent> events = const [],
  List<domain.EventException> exceptions = const [],
  LocalNotificationSettingsValue? settings,
  Map<String, List<int>> importedRules = const {},
}) {
  return LocalNotificationReadonlySnapshot(
    context: const LocalNotificationContextTuple(
      ownerUserId: 'owner',
      universityId: 'university',
      termId: 'term',
      academicYear: 2026,
      primaryCalendarId: 'calendar',
      profileOnboardingStatus: 'complete',
      profileActive: true,
      profileDeleted: false,
      termOwnerUserId: 'owner',
      termStatus: 'active',
      termIsTemplate: false,
      termDeleted: false,
      calendarDeleted: false,
    ),
    settings: settings ??
        const LocalNotificationSettingsValue(
          courseEnabled: false,
          assignmentEnabled: false,
          eventEnabled: true,
          routineEnabled: false,
          examReminderMinutes: 0,
          eventReminderMinutes: 0,
        ),
    courses: const [],
    periodSettings: const [],
    assignments: const [],
    assignmentStates: const {},
    exams: exams,
    events: events,
    eventExceptions: exceptions,
    importedReminderRules: {
      for (final exam in exams) exam.id: const [0],
      ...importedRules,
    },
    sourceEpoch: 7,
    previousProjectionEpoch: 4,
    termStart: DateTime.utc(2026, 4, 1),
    termEnd: DateTime.utc(2027, 3, 31),
    instructionStart: null,
    instructionEnd: null,
  );
}

domain.ScheduleEvent _event(String id, DateTime startAt) =>
    domain.ScheduleEvent(
      id: id,
      ownerUserId: 'owner',
      calendarId: 'calendar',
      title: id,
      kind: domain.EventKind.normal,
      startAt: startAt,
      endAt: startAt.add(const Duration(hours: 1)),
    );

domain.Exam _exam(String id, DateTime startAt) => domain.Exam(
      id: id,
      ownerUserId: 'owner',
      title: id,
      startAt: startAt,
      endAt: startAt.add(const Duration(hours: 1)),
    );
