import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/notification/data/local_notification_store.dart';
import 'package:university_schedule_mobile/features/notification/domain/local_notification_models.dart';
import 'package:university_schedule_mobile/features/notification/domain/local_notification_planner.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  test('routine cancel, move, and restore refresh local reminder projection',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    const owner = demoUserId;
    final store = LocalNotificationStore(db);
    var nextId = 0;
    final repository = DriftScheduleRepository(
      db,
      enableDemoData: true,
      createId: () => 'routine-notification-${nextId++}',
    );
    const planner = LocalNotificationPlanner();
    final now = JapanTime.at(year: 2026, month: 6, day: 20);
    final firstStart = JapanTime.at(year: 2026, month: 6, day: 29, hour: 9);
    final cancelledRecurrence =
        JapanTime.at(year: 2026, month: 7, day: 6, hour: 9);
    final movedStart = JapanTime.at(year: 2026, month: 7, day: 6, hour: 13);

    List<LocalNotificationPlan> plansFor(
      ScheduleEvent routine,
      List<EventException> exceptions, {
      required int sourceEpoch,
      required int projectionEpoch,
    }) =>
        planner.plan(
          ownerUserId: owner,
          projectionService: CalendarProjectionService(),
          courses: const [],
          periodSettings: const [],
          assignments: const [],
          assignmentStates: const {},
          exams: const [],
          events: [routine],
          eventExceptions: exceptions,
          settings: const LocalNotificationSettingsValue(),
          now: now,
          sourceEpoch: sourceEpoch,
          projectionEpoch: projectionEpoch,
        );

    final beforeCreate = await store.sourceEpoch();
    final routineId = await repository.createEvent(
      ownerUserId: owner,
      input: EventInput(
        title: '毎週の復習',
        calendarId: demoScheduleContext.primaryCalendarId,
        kind: EventKind.routine,
        startAt: firstStart,
        endAt: firstStart.add(const Duration(hours: 1)),
        recurrenceRule: const RecurrenceRule(
          frequency: RecurrenceFrequency.weekly,
          byWeekdays: [DateTime.monday],
          count: 4,
        ),
      ),
    );
    final afterCreate = await store.sourceEpoch();
    expect(afterCreate, greaterThan(beforeCreate));
    final routine = (await repository.eventsForUser(owner))
        .singleWhere((event) => event.id == routineId);
    final initialPlans = plansFor(
      routine,
      const [],
      sourceEpoch: afterCreate,
      projectionEpoch: 1,
    );
    expect(initialPlans, hasLength(4));
    expect(initialPlans.map((plan) => plan.occurrenceAt),
        contains(cancelledRecurrence));
    expect(initialPlans.every((plan) => plan.kind == 'routine'), isTrue);
    await store.replaceProjection(
      owner: owner,
      sourceEpoch: afterCreate,
      projectionEpoch: 1,
      capped: false,
      plans: initialPlans,
    );
    final initialRows = await store.desiredRows(owner);
    expect(initialRows, hasLength(4));
    final initialIds = initialRows.map((row) => row['id']).toSet();

    final exceptionId = await repository.createEventException(
      eventId: routineId,
      ownerUserId: owner,
      input: EventExceptionInput(
        recurrenceId: cancelledRecurrence,
        mode: EventExceptionMode.cancelled,
      ),
    );
    final afterCancel = await store.sourceEpoch();
    expect(afterCancel, greaterThan(afterCreate));
    final cancelled = await repository.eventExceptionsForEvent(
      eventId: routineId,
      ownerUserId: owner,
    );
    final cancelledPlans = plansFor(
      routine,
      cancelled,
      sourceEpoch: afterCancel,
      projectionEpoch: 2,
    );
    expect(cancelledPlans, hasLength(3));
    expect(
      cancelledPlans.any((plan) => plan.occurrenceAt == cancelledRecurrence),
      isFalse,
    );
    await store.replaceProjection(
      owner: owner,
      sourceEpoch: afterCancel,
      projectionEpoch: 2,
      capped: false,
      plans: cancelledPlans,
    );
    expect(await store.desiredRows(owner), hasLength(3));

    await repository.updateEventException(
      exceptionId: exceptionId,
      eventId: routineId,
      ownerUserId: owner,
      input: EventExceptionInput(
        recurrenceId: cancelledRecurrence,
        mode: EventExceptionMode.modified,
        overrideStartAt: movedStart,
        overrideEndAt: movedStart.add(const Duration(hours: 1)),
        overrideTitle: '午後に移動した復習',
      ),
    );
    final afterMove = await store.sourceEpoch();
    expect(afterMove, greaterThan(afterCancel));
    final movedExceptions = await repository.eventExceptionsForEvent(
      eventId: routineId,
      ownerUserId: owner,
    );
    final movedPlans = plansFor(
      routine,
      movedExceptions,
      sourceEpoch: afterMove,
      projectionEpoch: 3,
    );
    expect(movedPlans, hasLength(4));
    final movedPlan = movedPlans.singleWhere(
      (plan) => plan.occurrenceAt == movedStart,
    );
    expect(movedPlan.title, '午後に移動した復習');
    expect(movedPlan.sourceEpoch, afterMove);
    expect(
      movedPlans.any((plan) => plan.occurrenceAt == cancelledRecurrence),
      isFalse,
    );
    await store.replaceProjection(
      owner: owner,
      sourceEpoch: afterMove,
      projectionEpoch: 3,
      capped: false,
      plans: movedPlans,
    );
    final movedRows = await store.desiredRows(owner);
    expect(movedRows, hasLength(4));
    expect(movedRows.map((row) => row['id']).toSet(), isNot(initialIds));
    expect(movedRows.every((row) => row['source_epoch'] == afterMove), isTrue);
    expect(
      movedRows.singleWhere((row) => row['title'] == '午後に移動した復習')['trigger_at'],
      movedStart.subtract(const Duration(minutes: 60)).millisecondsSinceEpoch,
    );

    await repository.deleteEventException(
      exceptionId: exceptionId,
      eventId: routineId,
      ownerUserId: owner,
    );
    final afterRestore = await store.sourceEpoch();
    expect(afterRestore, greaterThan(afterMove));
    final restoredExceptions = await repository.eventExceptionsForEvent(
      eventId: routineId,
      ownerUserId: owner,
    );
    expect(restoredExceptions, isEmpty);
    final restoredPlans = plansFor(
      routine,
      restoredExceptions,
      sourceEpoch: afterRestore,
      projectionEpoch: 4,
    );
    expect(restoredPlans, hasLength(4));
    expect(restoredPlans.map((plan) => plan.id).toSet(), initialIds);
    await store.replaceProjection(
      owner: owner,
      sourceEpoch: afterRestore,
      projectionEpoch: 4,
      capped: false,
      plans: restoredPlans,
    );
    final restoredRows = await store.desiredRows(owner);
    expect(restoredRows, hasLength(4));
    expect(restoredRows.map((row) => row['id']).toSet(), initialIds);
    expect(
      restoredRows.every((row) => row['source_epoch'] == afterRestore),
      isTrue,
    );
    expect(await store.projectionEpoch(owner), 4);
  });
}
