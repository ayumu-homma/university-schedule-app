import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_domain/shared_domain.dart';
import 'package:university_schedule_mobile/features/notification/data/local_notification_store.dart';
import 'package:university_schedule_mobile/features/notification/domain/local_notification_models.dart';
import 'package:university_schedule_mobile/features/notification/domain/local_notification_planner.dart';
import 'package:university_schedule_mobile/features/timetable/data/local_schedule_repository.dart';
import 'package:university_schedule_mobile/local_db/app_database.dart' as local;

void main() {
  test('personal event create, edit, and delete replace reminder projection',
      () async {
    final db = local.AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final owner = demoUserId;
    final store = LocalNotificationStore(db);
    final repository = DriftScheduleRepository(
      db,
      enableDemoData: true,
      createId: () => 'event-notification-lifecycle',
    );
    const planner = LocalNotificationPlanner();
    final now = JapanTime.at(year: 2026, month: 4, day: 1, hour: 9);
    final firstStart = JapanTime.at(year: 2026, month: 4, day: 12, hour: 10);

    List<LocalNotificationPlan> plansFor(
      List<ScheduleEvent> events, {
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
          events: events,
          eventExceptions: const [],
          settings: const LocalNotificationSettingsValue(),
          now: now,
          sourceEpoch: sourceEpoch,
          projectionEpoch: projectionEpoch,
        );

    final beforeCreate = await store.sourceEpoch();
    final eventId = await repository.createEvent(
      ownerUserId: owner,
      input: EventInput(
        title: '個人の予定',
        calendarId: demoScheduleContext.primaryCalendarId,
        kind: EventKind.normal,
        startAt: firstStart,
        endAt: firstStart.add(const Duration(hours: 1)),
        description: '作成時の内容',
      ),
    );
    final afterCreate = await store.sourceEpoch();
    expect(eventId, 'event-notification-lifecycle');
    expect(afterCreate, greaterThan(beforeCreate));
    final created = (await repository.eventsForUser(owner))
        .singleWhere((event) => event.id == eventId);
    final initialPlans = plansFor(
      [created],
      sourceEpoch: afterCreate,
      projectionEpoch: 1,
    );
    expect(initialPlans, hasLength(1));
    expect(initialPlans.single.kind, 'event');
    expect(initialPlans.single.rule, 'event_reminder');
    await store.replaceProjection(
      owner: owner,
      sourceEpoch: afterCreate,
      projectionEpoch: 1,
      capped: false,
      plans: initialPlans,
    );
    final firstRows = await store.desiredRows(owner);
    expect(firstRows, hasLength(1));
    final firstIds = firstRows.map((row) => row['id']).toSet();

    final movedStart = JapanTime.at(year: 2026, month: 4, day: 18, hour: 11);
    await repository.updateEvent(
      eventId: eventId,
      ownerUserId: owner,
      expectedVersion: 1,
      input: EventInput(
        title: '移動後の予定',
        calendarId: demoScheduleContext.primaryCalendarId,
        kind: EventKind.normal,
        startAt: movedStart,
        endAt: movedStart.add(const Duration(hours: 1)),
        description: '更新後の内容',
      ),
    );
    final afterUpdate = await store.sourceEpoch();
    expect(afterUpdate, greaterThan(afterCreate));
    final updated = (await repository.eventsForUser(owner))
        .singleWhere((event) => event.id == eventId);
    expect(updated.version, 2);
    final updatedPlans = plansFor(
      [updated],
      sourceEpoch: afterUpdate,
      projectionEpoch: 2,
    );
    expect(updatedPlans, hasLength(1));
    expect(updatedPlans.single.occurrenceAt, movedStart);
    expect(updatedPlans.single.title, '移動後の予定');
    expect(updatedPlans.single.sourceEpoch, afterUpdate);
    expect(updatedPlans.map((plan) => plan.id).toSet().intersection(firstIds),
        isEmpty);
    await store.replaceProjection(
      owner: owner,
      sourceEpoch: afterUpdate,
      projectionEpoch: 2,
      capped: false,
      plans: updatedPlans,
    );
    final movedRows = await store.desiredRows(owner);
    expect(movedRows, hasLength(1));
    expect(movedRows.single['source_epoch'], afterUpdate);
    expect(movedRows.single['title'], '移動後の予定');
    expect(movedRows.single['id'], isNot(firstRows.single['id']));

    await repository.deleteEvent(
      eventId: eventId,
      ownerUserId: owner,
      expectedVersion: 2,
    );
    final afterDelete = await store.sourceEpoch();
    expect(afterDelete, greaterThan(afterUpdate));
    final remaining = (await repository.eventsForUser(owner))
        .where((event) => event.id == eventId)
        .toList();
    expect(remaining, isEmpty);
    final deletedPlans = plansFor(
      remaining,
      sourceEpoch: afterDelete,
      projectionEpoch: 3,
    );
    expect(deletedPlans, isEmpty);
    await store.replaceProjection(
      owner: owner,
      sourceEpoch: afterDelete,
      projectionEpoch: 3,
      capped: false,
      plans: deletedPlans,
    );
    expect(await store.desiredRows(owner), isEmpty);
    expect(await store.projectionEpoch(owner), 3);
  });
}
