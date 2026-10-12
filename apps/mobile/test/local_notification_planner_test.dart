import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/notification/domain/local_notification_models.dart';
import 'package:university_schedule_mobile/features/notification/domain/local_notification_planner.dart';
import 'package:university_schedule_mobile/features/notification/data/local_notification_store.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  final planner = const LocalNotificationPlanner();
  final now = JapanTime.at(year: 2026, month: 4, day: 1, hour: 9);
  final due = JapanTime.at(year: 2026, month: 4, day: 10, hour: 10);

  test('uses JST defaults and stable fingerprints', () {
    final assignment = Assignment(
      id: 'a1',
      ownerUserId: 'u1',
      title: 'Report',
      dueAt: due,
    );
    final plans = planner.plan(
      ownerUserId: 'u1',
      projectionService: CalendarProjectionService(),
      assignments: [assignment],
      assignmentStates: const {},
      courses: const [],
      periodSettings: const [],
      exams: const [],
      events: const [],
      eventExceptions: const [],
      settings: const LocalNotificationSettingsValue(),
      now: now,
      sourceEpoch: 4,
      projectionEpoch: 7,
    );
    expect(plans, hasLength(2));
    expect(
        plans.map((plan) => plan.rule),
        containsAll([
          'assignment_previous_day',
          'assignment_due_reminder',
        ]));
    expect(plans.every((plan) => plan.fingerprint.isNotEmpty), isTrue);
    expect(plans.every((plan) => plan.sourceEpoch == 4), isTrue);
  });

  test('imported reminder rules replace defaults', () {
    final event = ScheduleEvent(
      id: 'e1',
      ownerUserId: 'u1',
      calendarId: 'c1',
      title: 'Imported',
      kind: EventKind.normal,
      startAt: due,
      endAt: due.add(const Duration(hours: 1)),
    );
    final plans = planner.plan(
      ownerUserId: 'u1',
      projectionService: CalendarProjectionService(),
      assignments: const [],
      assignmentStates: const {},
      courses: const [],
      periodSettings: const [],
      exams: const [],
      events: [event],
      eventExceptions: const [],
      settings: const LocalNotificationSettingsValue(),
      importedReminderRules: const {
        'e1': [-15]
      },
      now: now,
      sourceEpoch: 1,
      projectionEpoch: 1,
    );
    expect(plans, hasLength(1));
    expect(plans.single.rule, 'imported_0');
    expect(plans.single.triggerAt, due.subtract(const Duration(minutes: 15)));
  });

  test(
      'positive imported offsets are rejected and recurrence identity is reused',
      () {
    final event = ScheduleEvent(
      id: 'multi-rule',
      ownerUserId: 'u1',
      calendarId: 'c1',
      title: '日本語📚',
      kind: EventKind.routine,
      startAt: due,
      endAt: due.add(const Duration(hours: 1)),
    );
    final plans = planner.plan(
      ownerUserId: 'u1',
      projectionService: CalendarProjectionService(),
      assignments: const [],
      assignmentStates: const {},
      courses: const [],
      periodSettings: const [],
      exams: const [],
      events: [event],
      eventExceptions: const [],
      settings: const LocalNotificationSettingsValue(),
      importedReminderRules: const {
        'multi-rule': [-30, -10, 15]
      },
      now: now,
      sourceEpoch: 2,
      projectionEpoch: 3,
    );
    expect(plans, hasLength(2));
    expect(plans.map((plan) => plan.rule),
        containsAll(['imported_0', 'imported_1']));
    expect(plans.every((plan) => plan.targetPath == '/routine/multi-rule'),
        isTrue);
    final repeated = planner.plan(
      ownerUserId: 'u1',
      projectionService: CalendarProjectionService(),
      assignments: const [],
      assignmentStates: const {},
      courses: const [],
      periodSettings: const [],
      exams: const [],
      events: [event],
      eventExceptions: const [],
      settings: const LocalNotificationSettingsValue(),
      importedReminderRules: const {
        'multi-rule': [-30, -10, 15]
      },
      now: now,
      sourceEpoch: 2,
      projectionEpoch: 3,
    );
    expect(repeated.map((plan) => plan.id), plans.map((plan) => plan.id));
    expect(repeated.map((plan) => plan.fingerprint),
        plans.map((plan) => plan.fingerprint));
  });

  test('exam projection includes seven day, previous evening and morning rules',
      () {
    final examAt = JapanTime.at(year: 2026, month: 4, day: 12, hour: 10);
    final exam = Exam(
      id: 'x1',
      ownerUserId: 'u1',
      title: 'Midterm',
      startAt: examAt,
      endAt: examAt.add(const Duration(hours: 2)),
    );
    final plans = planner.plan(
      ownerUserId: 'u1',
      projectionService: CalendarProjectionService(),
      assignments: const [],
      assignmentStates: const {},
      courses: const [],
      periodSettings: const [],
      exams: [exam],
      events: const [],
      eventExceptions: const [],
      settings: const LocalNotificationSettingsValue(),
      now: now,
      sourceEpoch: 1,
      projectionEpoch: 1,
    );
    expect(
        plans.map((plan) => plan.rule),
        containsAll([
          'exam_week',
          'exam_previous_day',
          'exam_day_morning',
        ]));
    expect(
        plans.map((plan) => plan.triggerAt),
        containsAll([
          examAt.subtract(const Duration(days: 7)),
          JapanTime.at(year: 2026, month: 4, day: 11, hour: 20),
          JapanTime.at(year: 2026, month: 4, day: 12, hour: 8),
        ]));
  });

  test('moved recurring instances retain distinct occurrence identities', () {
    final first = JapanTime.at(year: 2026, month: 4, day: 10, hour: 10);
    final event = ScheduleEvent(
      id: 'recurring',
      ownerUserId: 'u1',
      calendarId: 'c1',
      title: 'Lab',
      kind: EventKind.routine,
      startAt: first,
      endAt: first.add(const Duration(hours: 1)),
      recurrenceRule: const RecurrenceRule(
        frequency: RecurrenceFrequency.daily,
        count: 3,
      ),
    );
    final plans = planner.plan(
      ownerUserId: 'u1',
      projectionService: CalendarProjectionService(),
      assignments: const [],
      assignmentStates: const {},
      courses: const [],
      periodSettings: const [],
      exams: const [],
      events: [event],
      eventExceptions: [
        EventException(
          id: 'move',
          eventId: 'recurring',
          recurrenceId: first.add(const Duration(days: 1)),
          mode: EventExceptionMode.modified,
          overrideStartAt: first.add(const Duration(days: 2)),
        ),
      ],
      settings: const LocalNotificationSettingsValue(),
      now: now,
      sourceEpoch: 1,
      projectionEpoch: 1,
    );
    final routineIds = plans.map((plan) => plan.id).toSet();
    expect(routineIds.length, 3);
  });

  test('routine reminders follow fifth-weekday gaps without rolling months',
      () {
    final first =
        JapanTime.at(year: 2026, month: 7, day: 31, hour: 15, minute: 30);
    final event = ScheduleEvent(
      id: 'fifth-friday-routine',
      ownerUserId: 'u1',
      calendarId: 'c1',
      title: '第5金曜の予定',
      kind: EventKind.routine,
      startAt: first,
      endAt: first.add(const Duration(hours: 1)),
      recurrenceRule: const RecurrenceRule(
        frequency: RecurrenceFrequency.nthWeekday,
        nth: 5,
        weekday: DateTime.friday,
        count: 3,
      ),
    );

    final plans = planner.plan(
      ownerUserId: 'u1',
      projectionService: CalendarProjectionService(),
      assignments: const [],
      assignmentStates: const {},
      courses: const [],
      periodSettings: const [],
      exams: const [],
      events: [event],
      eventExceptions: const [],
      settings: const LocalNotificationSettingsValue(),
      now: JapanTime.at(year: 2026, month: 8, day: 1),
      sourceEpoch: 1,
      projectionEpoch: 1,
    );

    // The next real fifth Friday is October 30, outside the rolling window.
    // August's missing occurrence must not roll into September 4 and create a
    // phantom local reminder inside the window.
    expect(plans, isEmpty);
  });

  test('quiet hours suppress without moving trigger time', () {
    final event = ScheduleEvent(
      id: 'e2',
      ownerUserId: 'u1',
      calendarId: 'c1',
      title: 'Quiet',
      kind: EventKind.normal,
      startAt: due,
      endAt: due.add(const Duration(hours: 1)),
    );
    final settings = const LocalNotificationSettingsValue(
      quietStartMinutes: 9 * 60,
      quietEndMinutes: 22 * 60,
    );
    final plans = planner.plan(
      ownerUserId: 'u1',
      projectionService: CalendarProjectionService(),
      assignments: const [],
      assignmentStates: const {},
      courses: const [],
      periodSettings: const [],
      exams: const [],
      events: [event],
      eventExceptions: const [],
      settings: settings,
      now: now,
      sourceEpoch: 1,
      projectionEpoch: 1,
    );
    expect(plans.single.reason, 'quiet_hours');
    expect(plans.single.triggerAt, due.subtract(const Duration(hours: 1)));
  });

  test('group events are excluded from personal local reminders', () {
    final event = ScheduleEvent(
      id: 'group-event',
      ownerUserId: 'u1',
      calendarId: 'group-calendar',
      title: 'Group event',
      kind: EventKind.group,
      groupId: 'g1',
      startAt: due,
      endAt: due.add(const Duration(hours: 1)),
    );
    final plans = planner.plan(
      ownerUserId: 'u1',
      projectionService: CalendarProjectionService(),
      assignments: const [],
      assignmentStates: const {},
      courses: const [],
      periodSettings: const [],
      exams: const [],
      events: [event],
      eventExceptions: const [],
      settings: const LocalNotificationSettingsValue(),
      now: now,
      sourceEpoch: 1,
      projectionEpoch: 1,
    );
    expect(plans, isEmpty);
  });

  test('settings and projection persist through the additive schema', () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = LocalNotificationStore(db);
    final defaults = await store.settingsFor('u1');
    expect(defaults.enabled, isTrue);
    await store.saveSettings(
      'u1',
      defaults.copyWith(enabled: false, quietStartMinutes: 23 * 60),
    );
    expect((await store.settingsFor('u1')).enabled, isFalse);
    final sourceEpoch = await store.sourceEpoch();
    await store.replaceProjection(
      owner: 'u1',
      sourceEpoch: sourceEpoch,
      projectionEpoch: 1,
      capped: false,
      plans: const [],
    );
    expect(await store.projectionEpoch('u1'), 1);
    expect(await store.desiredRows('u1'), isEmpty);
  });
}
